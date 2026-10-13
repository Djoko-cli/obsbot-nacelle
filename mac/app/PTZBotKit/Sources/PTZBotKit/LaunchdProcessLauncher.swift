import Foundation

/// Pourquoi launchd n'a pas pu lancer le gardien de go2rtc (spec B3 § 14).
public enum LaunchdLaunchError: LocalizedError, Equatable, Sendable {
    /// Le travail d'une session précédente n'a pas pu être déchargé.
    case bootoutFailed(String)
    /// Le travail d'une session précédente est encore chargé 20 s après le `bootout`.
    case stillLoaded
    /// launchd n'a donné aucun PID au gardien dans les 2 s qui suivent le `bootstrap`.
    case noPID

    public var errorDescription: String? {
        switch self {
        case let .bootoutFailed(reason): Localization.text("Le gardien de go2rtc d'une session précédente n'a pas pu être arrêté : \(reason)")
        case .stillLoaded: Localization.text("Le gardien de go2rtc d'une session précédente ne s'est pas arrêté à temps.")
        case .noPID: Localization.text("launchd n'a pas lancé le gardien de go2rtc.")
        }
    }
}

/// Lance le gardien de go2rtc par launchd, et non comme enfant de l'app (spec B3 § 14).
///
/// Pourquoi : un processus qui filme la caméra dans la coalition de l'app fait afficher à macOS le bouton « Effets
/// vidéo » dans la barre des menus, au nom de PTZBot. Un travail launchd forme sa propre coalition : pas de bouton.
///
/// Le travail est décrit par une plist de travail, à côté du yaml dans le dossier de support de l'app, **jamais** dans
/// `~/Library/LaunchAgents` : elle est chargée par `launchctl bootstrap gui/<uid>`, sans `KeepAlive`. Le travail ne
/// redémarre jamais tout seul ; c'est `Go2RTCSupervisor` qui relance. L'exigence « go2rtc meurt avec PTZBot » reste tenue
/// par `gardien --parent <PID de PTZBot>`.
///
/// Fils d'exécution : `ProcessLauncher` est `@MainActor` et synchrone. `launch` attend donc le PID du gardien sur le
/// MainActor, 2 s au plus, et seulement au démarrage de go2rtc (le plus souvent, un ou deux sondages). Si un travail d'une
/// session précédente est encore chargé (relance rapide après une app tuée : le vieux gardien finit d'arrêter go2rtc), son
/// déchargement attend de même, 20 s au plus. Cette attente reste sur le MainActor : la sortir de là demanderait de
/// décharger le travail pendant la préparation de go2rtc, hors du MainActor, ce qui n'est pas fait (cas rare, au pire
/// l'interface attend 20 s). La fin du processus, elle, est suivie et traitée hors du MainActor (`launchctl print`,
/// `bootout`, suppression de la plist), puis `onExit` revient sur le MainActor.
@MainActor
public final class LaunchdProcessLauncher: ProcessLauncher {
    /// Le label du travail launchd de go2rtc.
    public nonisolated static let label = "io.github.djoko-cli.obsbot-nacelle.go2rtc"
    /// La plist de travail, dans le dossier de support de l'app.
    public nonisolated static let plistFileName = "go2rtc-launchd.plist"
    /// Un travail resté d'une session précédente : attente de son déchargement (comme `ClassicAgent`). Au moins le
    /// `ExitTimeOut` de la plist : `bootout` attend la sortie du vieux gardien jusque-là, et le gardien lui-même peut
    /// prendre 15 s (go2rtc 10 s, puis les ffmpeg qui restent 5 s).
    public nonisolated static let stopTimeout: TimeInterval = TimeInterval(exitTimeOut)
    public nonisolated static let stopPollInterval: TimeInterval = LegacyAgent.pollInterval
    /// Le PID du gardien : un sondage toutes les 50 ms, 2 s au plus.
    public nonisolated static let pidTimeout: TimeInterval = 2
    public nonisolated static let pidPollInterval: TimeInterval = 0.05
    /// `ExitTimeOut` de la plist : le délai de launchd entre SIGTERM et SIGKILL à un `bootout`. Le gardien laisse déjà
    /// `Go2RTCSupervisor.stopDelay` (10 s) à go2rtc.
    public nonisolated static let exitTimeOut = 20
    /// Après la sortie du processus, launchd peut mettre un instant à enregistrer son code : la lecture de `print` est
    /// reprise (toutes les 50 ms) tant qu'il montre encore le PID ou n'a pas de code.
    nonisolated static let exitReadAttempts = 20

    /// La file des travaux qui bloquent (`launchctl print`, `bootout`, suppression de la plist) et des sources de
    /// surveillance des processus. Une seule, en série : `launch` attend qu'elle soit vide avant d'écrire une nouvelle
    /// plist, pour qu'un nettoyage en retard n'emporte pas le travail suivant.
    public nonisolated static let sharedQueue = DispatchQueue(label: "io.github.djoko-cli.ptzbot.launchd", qos: .utility)

    /// La plist de travail écrite par `launch`.
    public let plistURL: URL
    private let launchctl: any Launchctl
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) -> Void
    private let queue: DispatchQueue

    /// `now` et `sleep` sont injectés pour que les tests maîtrisent l'attente du PID.
    public init(
        supportDirectory: URL,
        launchctl: any Launchctl,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        queue: DispatchQueue = LaunchdProcessLauncher.sharedQueue
    ) {
        plistURL = supportDirectory.appending(path: Self.plistFileName)
        self.launchctl = launchctl
        self.now = now
        self.sleep = sleep
        self.queue = queue
    }

    /// Le lanceur de l'app : vrai `launchctl`, plist dans le dossier de support de l'utilisateur.
    public static func system(supportDirectory: URL) -> LaunchdProcessLauncher {
        LaunchdProcessLauncher(supportDirectory: supportDirectory, launchctl: SystemLaunchctl())
    }

    /// Au lancement de l'app, go2rtc éteint : décharge sans bruit un travail resté d'une session précédente (app tuée), hors
    /// du fil principal. Allumé, `launch` s'en charge lui-même.
    public nonisolated static func removeLeftoverInBackground(
        supportDirectory: URL,
        launchctl: any Launchctl = SystemLaunchctl(),
        queue: DispatchQueue = LaunchdProcessLauncher.sharedQueue
    ) {
        JobContext(launchctl: launchctl, plistURL: supportDirectory.appending(path: plistFileName), queue: queue, sleep: { _ in })
            .cleanUpInBackground(bootout: true)
    }

    // MARK: - La plist

    /// Le contenu de la plist de travail. Pas de `KeepAlive`. `Interactive` : Standard dégradait le son des enfants de
    /// go2rtc, Background faisait saccader la vidéo (leçon de talkd, voir `ClassicAgent`).
    static func plistContents(executableURL: URL, arguments: [String], environment: [String: String], outputURL: URL) -> NSDictionary {
        var contents: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path] + arguments,
            // launchd ajoute à la fin du fichier, comme `FoundationProcessLauncher`.
            "StandardOutPath": outputURL.path,
            "StandardErrorPath": outputURL.path,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "ExitTimeOut": exitTimeOut,
            // launchd ne doit jamais signaler les processus restés dans le groupe du travail, en particulier un ffmpeg qui
            // capture : le gardien leur a déjà envoyé SIGTERM, jamais SIGKILL (risque de bloquer CMIO), comme avant le
            // passage à launchd.
            "AbandonProcessGroup": true,
        ]
        if !environment.isEmpty {
            contents["EnvironmentVariables"] = environment
        }
        return contents as NSDictionary
    }

    /// Écrit la plist (XML, de façon atomique, en 0600) ; le dossier de support est créé au besoin.
    private func writePlist(_ contents: NSDictionary) throws {
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
    }

    // MARK: - launchd

    private var context: JobContext {
        JobContext(launchctl: launchctl, plistURL: plistURL, queue: queue, sleep: sleep)
    }

    /// Décharge un travail resté chargé (d'une session précédente, ou d'une app tuée) et attend que launchd ait fini
    /// (20 s au plus) : un `bootstrap` échoue sur un label chargé. Un `bootout` en échec ne lève rien : launchd peut
    /// encore démonter le travail (« Operation now in progress »). Seul compte qu'il ne soit plus chargé, et l'erreur
    /// n'est levée que s'il l'est toujours au bout du délai (comme `ClassicAgent`).
    private func unloadLeftover() throws {
        guard launchctl.isLoaded(label: Self.label) else { return }
        var bootoutError: (any Error)?
        do {
            try launchctl.bootout(label: Self.label)
        } catch {
            bootoutError = error
        }
        var waited: TimeInterval = 0
        while launchctl.isLoaded(label: Self.label) {
            guard waited < Self.stopTimeout else {
                if let bootoutError {
                    throw LaunchdLaunchError.bootoutFailed(bootoutError.localizedDescription)
                }
                throw LaunchdLaunchError.stillLoaded
            }
            sleep(Self.stopPollInterval)
            waited += Self.stopPollInterval
        }
    }

    /// Ce que `launchctl print` montre juste après le `bootstrap`.
    private enum Start {
        /// Le gardien tourne, avec ce PID.
        case running(pid_t)
        /// Le gardien est déjà sorti (go2rtc manquant : code 127) avant qu'on ait vu son PID.
        case finished(ProcessExit)
    }

    /// Lit le PID du gardien : un sondage toutes les 50 ms, 2 s au plus (l'horloge et l'attente sont injectées). `nil` :
    /// ni PID ni fin dans le délai.
    private func waitForGardien() -> Start? {
        let started = now()
        while true {
            if let text = launchctl.printOutput(label: Self.label) {
                if let pid = SystemLaunchctl.pid(fromPrint: text) {
                    return .running(pid)
                }
                // Sorti avant le premier sondage : le travail est neuf, un code lisible est celui de ce lancement.
                if let exit = SystemLaunchctl.lastExit(fromPrint: text) {
                    return .finished(exit)
                }
            }
            guard now() - started < Self.pidTimeout else { return nil }
            sleep(Self.pidPollInterval)
        }
    }

    // MARK: - ProcessLauncher

    /// `environment` s'ajoute à l'environnement que launchd donne aux travaux de l'utilisateur (`EnvironmentVariables`),
    /// et non à celui de l'app. Le processus rendu est le gardien (PID donné par launchd).
    public func launch(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        outputURL: URL,
        onExit: @escaping @MainActor (ProcessExit) -> Void
    ) throws -> any LaunchedProcess {
        // Les nettoyages du travail précédent (bootout, suppression de la plist) sont finis avant d'écrire la nouvelle.
        queue.sync {}
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePlist(Self.plistContents(executableURL: executableURL, arguments: arguments, environment: environment, outputURL: outputURL))
        do {
            try unloadLeftover()
            // Un travail que l'utilisateur a coupé dans « Ouverture » (ou un `launchctl disable`) ferait échouer chaque
            // `bootstrap` : on le réactive d'abord, comme `ClassicAgent`. Un échec ici n'empêche rien, le `bootstrap` le dira.
            try? launchctl.enable(label: Self.label)
            try launchctl.bootstrap(plist: plistURL)
        } catch {
            // Rien de chargé par nous : seule la plist est à retirer.
            context.cleanUpInBackground(bootout: false)
            throw error
        }
        guard let start = waitForGardien() else {
            context.cleanUpInBackground(bootout: true)
            throw LaunchdLaunchError.noPID
        }
        switch start {
        case let .running(pid):
            let job = LaunchdJob(pid: pid, context: context, onExit: onExit)
            job.watchExit()
            return job
        case let .finished(exit):
            // Le superviseur n'a pas encore le processus : la fin lui est livrée après le retour de `launch`.
            let job = LaunchdJob(pid: 0, context: context, onExit: onExit)
            job.processGone(knownExit: exit)
            return job
        }
    }
}

// MARK: - Travail en cours

/// Ce dont les travaux de fond ont besoin, sans rien d'isolé au MainActor.
private struct JobContext: Sendable {
    var launchctl: any Launchctl
    var plistURL: URL
    var queue: DispatchQueue
    var sleep: @Sendable (TimeInterval) -> Void

    /// Le code de sortie du gardien d'après `launchctl print`, repris tant que launchd montre encore le PID ou n'a pas de
    /// code. Illisible (travail disparu, code absent) : `status: -1, signaled: true`. Bloquant : hors du MainActor.
    func readExit() -> ProcessExit {
        for attempt in 0..<LaunchdProcessLauncher.exitReadAttempts {
            if attempt > 0 {
                sleep(LaunchdProcessLauncher.pidPollInterval)
            }
            guard let text = launchctl.printOutput(label: LaunchdProcessLauncher.label) else { break }
            if SystemLaunchctl.pid(fromPrint: text) == nil, let exit = SystemLaunchctl.lastExit(fromPrint: text) {
                return exit
            }
        }
        return ProcessExit(status: -1, signaled: true)
    }

    /// `bootout` (erreurs ignorées : le travail est peut-être déjà parti) puis suppression de la plist. Bloquant.
    func cleanUp(bootout: Bool) {
        if bootout {
            try? launchctl.bootout(label: LaunchdProcessLauncher.label)
        }
        try? FileManager.default.removeItem(at: plistURL)
    }

    func cleanUpInBackground(bootout: Bool) {
        let context = self
        queue.async { context.cleanUp(bootout: bootout) }
    }
}

/// La surveillance d'un processus qui n'est pas notre enfant (`DispatchSource.makeProcessSource`). Hors de tout acteur :
/// le gestionnaire tourne sur la file de fond, et le saut vers le MainActor est explicite (une closure formée dans un type
/// `@MainActor` et appelée d'un autre fil plante en Swift 6).
private final class ExitWatch: @unchecked Sendable {
    private let source: any DispatchSourceProcess

    init(pid: pid_t, queue: DispatchQueue, onExit: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler(handler: onExit)
        source.resume()
    }

    func cancel() {
        source.cancel()
    }
}

/// Le gardien lancé par launchd, vu comme un `LaunchedProcess`. `onExit` n'est appelé qu'une fois, sur le MainActor.
@MainActor
private final class LaunchdJob: LaunchedProcess {
    /// Le PID du gardien ; 0 quand il était déjà sorti avant qu'on l'ait vu (jamais signalé).
    let pid: pid_t
    private let context: JobContext
    private var onExit: (@MainActor (ProcessExit) -> Void)?
    private var watch: ExitWatch?
    /// La sortie est constatée (par la source, ou par le contrôle qui ferme la course).
    private var gone = false

    /// Vrai jusqu'à la sortie constatée.
    var isRunning: Bool {
        !gone
    }

    init(pid: pid_t, context: JobContext, onExit: @escaping @MainActor (ProcessExit) -> Void) {
        self.pid = pid
        self.context = context
        self.onExit = onExit
    }

    /// Arme la source, puis ferme la course : si le processus est sorti avant qu'elle soit armée, aucun événement ne
    /// viendra, et `kill(pid, 0)` échoue avec `ESRCH`. La sortie est traitée tout de suite.
    func watchExit() {
        watch = ExitWatch(pid: pid, queue: context.queue) { [self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.processGone() }
            }
        }
        if Darwin.kill(pid, 0) != 0, errno == ESRCH {
            processGone()
        }
    }

    /// Le processus est sorti (une seule fois, quelle que soit la voie qui le constate). Hors du MainActor : le code de
    /// sortie (`launchctl print`), puis le `bootout` du travail et la suppression de la plist ; `onExit` revient sur le
    /// MainActor ensuite, plist déjà retirée. `knownExit` : le code a déjà été lu.
    func processGone(knownExit: ProcessExit? = nil) {
        guard !gone else { return }
        gone = true
        watch?.cancel()
        watch = nil
        let context = context
        context.queue.async { [self] in
            let exit = knownExit ?? context.readExit()
            context.cleanUp(bootout: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.deliver(exit) }
            }
        }
    }

    private func deliver(_ exit: ProcessExit) {
        guard let onExit else { return }
        self.onExit = nil
        onExit(exit)
    }

    /// SIGTERM au gardien, qui le transmet à go2rtc puis aux ffmpeg qui restent, jamais SIGKILL. Sans effet une fois la
    /// sortie constatée (le PID peut déjà être celui d'un autre processus).
    func terminate() {
        guard isRunning, pid > 0 else { return }
        Darwin.kill(pid, SIGTERM)
    }

    func kill() {
        guard isRunning, pid > 0 else { return }
        Darwin.kill(pid, SIGKILL)
    }
}
