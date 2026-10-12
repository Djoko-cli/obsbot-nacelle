import Foundation

/// Le gardien (spec B3 § 3.2) : une seule boucle `kqueue`, sans fil ni file de distribution. Elle attend la fin du
/// programme et celle du parent (`EVFILT_PROC`, `NOTE_EXIT`), et SIGTERM ou SIGINT (`EVFILT_SIGNAL`), qu'elle transmet
/// au programme. Dès le premier de ces signaux, ou la disparition du parent, le programme a `stopDelay` secondes pour
/// sortir ; puis SIGKILL. Le gardien sort quand le programme est sorti, et rend sa fin.
///
/// Le programme est lancé dans son propre groupe de processus. Quand il est sorti, ses enfants encore vivants (les ffmpeg
/// de go2rtc, que go2rtc ne referme pas toujours) reçoivent SIGTERM, jamais SIGKILL : un ffmpeg qui capture ne doit pas
/// être coupé brutalement. Ce sont les membres du groupe, et les enfants que le programme avait juste avant son
/// premier signal d'arrêt (ceux qui ont quitté son groupe). Le gardien les attend `orphanWait` secondes au plus.
public enum Gardien {
    /// Le temps laissé aux enfants du programme pour s'arrêter sur SIGTERM, une fois le programme sorti.
    public static let orphanWait: TimeInterval = 5

    /// Le processus n'existe plus (ESRCH). Celui d'un autre utilisateur (EPERM) existe.
    public static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    /// Lance le programme et le garde jusqu'à sa fin. `log` reçoit une ligne par événement (le journal de go2rtc).
    /// À n'appeler qu'une fois : SIGTERM et SIGINT restent ignorés par le processus appelant.
    public static func run(_ options: GardienOptions, log: (String) -> Void) -> ChildEnd {
        guard !isGone(options.parent) else {
            log("le parent \(options.parent) a déjà disparu : \(options.program) n'est pas lancé")
            return .exited(GardienExit.parentGone)
        }
        let queue = kqueue()
        guard queue >= 0 else {
            log("kqueue refusé (errno \(errno))")
            return .exited(GardienExit.systemError)
        }
        defer { close(queue) }
        // Ignorés : ils ne tuent pas le gardien, et kqueue les voit quand même. Inscrits avant le lancement : aucun ne
        // peut se perdre entre les deux.
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            _ = register(queue, ident: UInt(number), filter: EVFILT_SIGNAL)
        }
        let child: pid_t
        do {
            child = try spawn(options)
        } catch {
            log("\(options.program) n'a pas pu être lancé (errno \(error.code))")
            return .exited(GardienExit.launchFailed)
        }
        // Ses enfants, relevés juste avant chaque signal qui lui est transmis.
        var watched: [ProcessIdentity] = []
        func noteChildren() {
            for identity in ProcessTable.children(of: child) where !watched.contains(identity) {
                watched.append(identity)
            }
        }
        // ESRCH : le programme est déjà sorti ; il ne reste qu'à lire sa fin.
        guard register(queue, ident: UInt(child), filter: EVFILT_PROC, fflags: UInt32(NOTE_EXIT)) else {
            return finish(child, watched: watched, log: log)
        }
        var deadline: UInt64?
        var killed = false
        func beginStop(_ number: Int32) {
            noteChildren()
            kill(child, number)
            if deadline == nil, !killed {
                deadline = now() + UInt64(options.stopDelay * 1_000_000_000)
            }
        }
        // ESRCH : le parent a disparu entre la vérification et l'inscription.
        if !register(queue, ident: UInt(options.parent), filter: EVFILT_PROC, fflags: UInt32(NOTE_EXIT)) {
            log("le parent \(options.parent) a disparu : SIGTERM à \(child)")
            beginStop(SIGTERM)
        }
        while true {
            var event = kevent()
            let count: Int32
            if let deadline {
                let left = deadline > now() ? deadline - now() : 0
                var limit = timespec(tv_sec: Int(left / 1_000_000_000), tv_nsec: Int(left % 1_000_000_000))
                count = kevent(queue, nil, 0, &event, 1, &limit)
            } else {
                count = kevent(queue, nil, 0, &event, 1, nil)
            }
            if count < 0 {
                if errno == EINTR { continue }
                log("kevent en échec (errno \(errno)) : SIGKILL à \(child)")
                noteChildren()
                kill(child, SIGKILL)
                return finish(child, watched: watched, log: log)
            }
            if count == 0 {
                log("\(child) n'est pas sorti en \(options.stopDelay) s : SIGKILL")
                noteChildren()
                kill(child, SIGKILL)
                killed = true
                deadline = nil
                continue
            }
            switch Int32(event.filter) {
            case EVFILT_SIGNAL:
                let number = Int32(event.ident)
                log("signal \(number) reçu : transmis à \(child)")
                beginStop(number)
            case EVFILT_PROC where pid_t(event.ident) == child:
                return finish(child, watched: watched, log: log)
            case EVFILT_PROC:
                log("le parent \(options.parent) a disparu : SIGTERM à \(child)")
                beginStop(SIGTERM)
            default:
                break
            }
        }
    }

    /// Une erreur de `posix_spawn` (ENOENT : programme introuvable…).
    public struct SpawnError: Error, Equatable {
        public var code: Int32
    }

    /// Lance le programme, dans son propre groupe de processus (dont il est le chef : pgid = son pid). Il hérite des
    /// entrées, des sorties (le journal de go2rtc) et de l'environnement du gardien ; SIGTERM et SIGINT y reprennent leur
    /// effet par défaut (le gardien les ignore, et un signal ignoré le reste après `exec`).
    static func spawn(_ options: GardienOptions) throws(SpawnError) -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM)
        sigaddset(&defaults, SIGINT)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP))
        let argv = ([options.program] + options.arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, options.program, nil, &attributes, argv, envp)
        guard result == 0 else { throw SpawnError(code: result) }
        return pid
    }

    /// Inscrit un événement ; false si le système le refuse (ESRCH : le processus n'existe plus).
    static func register(_ queue: Int32, ident: UInt, filter: Int32, fflags: UInt32 = 0) -> Bool {
        var change = kevent(ident: ident, filter: Int16(filter), flags: UInt16(EV_ADD | EV_ENABLE), fflags: fflags, data: 0, udata: nil)
        return kevent(queue, &change, 1, nil, 0, nil) == 0
    }

    /// Le programme est sorti : SIGTERM à ce qui reste de son groupe et à ses enfants relevés qui ont quitté le groupe,
    /// puis attente bornée de leur fin, puis la fin du programme. Jamais SIGKILL. Le signal au groupe part avant
    /// `waitpid` : tant que le chef de groupe n'est pas lu, son pid ne peut pas être réutilisé.
    static func finish(_ child: pid_t, watched: [ProcessIdentity], log: (String) -> Void) -> ChildEnd {
        let group = child
        var signaled: [ProcessIdentity] = []
        for member in ProcessTable.liveMembers(ofGroup: group) where member.pid != child {
            log("\(member.name) (\(member.pid)) vit encore, dans le groupe de \(child) : SIGTERM")
            signaled.append(member)
        }
        if !signaled.isEmpty {
            kill(-group, SIGTERM)
        }
        for identity in watched where identity.groupID != group && ProcessTable.isAlive(identity) {
            log("\(identity.name) (\(identity.pid)), enfant de \(child), vit encore : SIGTERM")
            kill(identity.pid, SIGTERM)
            signaled.append(identity)
        }
        let end = reap(child)
        guard !signaled.isEmpty else { return end }
        let limit = now() + UInt64(orphanWait * 1_000_000_000)
        func survivors() -> [ProcessIdentity] {
            signaled.filter { ProcessTable.isAlive($0) }
        }
        while !survivors().isEmpty, now() < limit {
            usleep(50_000)
        }
        for identity in survivors() {
            log("\(identity.name) (\(identity.pid)) vit encore après \(Int(orphanWait)) s : laissé en vie (SIGTERM seulement)")
        }
        return end
    }

    /// Lit la fin du programme (il est sorti : `waitpid` ne bloque pas).
    static func reap(_ child: pid_t) -> ChildEnd {
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0, errno == EINTR {}
        return ChildEnd(waitStatus: status)
    }

    /// Temps monotone, en nanosecondes.
    static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}
