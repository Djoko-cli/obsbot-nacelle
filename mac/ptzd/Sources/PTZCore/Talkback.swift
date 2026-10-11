import Darwin
import Foundation
import NacelleProtocol

/// Lit l'état de talkd pour dire si le retour audio est prêt (spec parler § 5). ptzd ne dépend pas de talkd :
/// il lit seulement les champs `pid` et `failure` de `talkd-state.json` (format de `TalkState`, spec haut-parleur § 6),
/// les autres sont ignorés.
public enum TalkbackProbe {
    private struct StateFile: Decodable {
        var pid: Int32
        var failure: String?
    }

    /// `ready` si le fichier existe, se lit, ne note aucun échec et si le processus noté est vivant ; sinon `unavailable`.
    public static func availability(stateFile: Data?, isAlive: (Int32) -> Bool) -> TalkbackAvailability {
        guard let stateFile, let state = try? JSONDecoder().decode(StateFile.self, from: stateFile) else {
            return .unavailable
        }
        guard state.failure == nil, isAlive(state.pid) else { return .unavailable }
        return .ready
    }

    /// La même lecture, sur le fichier lui-même (absent : `unavailable`).
    public static func availability(stateFileAt url: URL, isAlive: (Int32) -> Bool = isProcessAlive) -> TalkbackAvailability {
        availability(stateFile: try? Data(contentsOf: url), isAlive: isAlive)
    }

    /// Un processus existe si `kill(pid, 0)` aboutit, ou refuse faute de droits (`EPERM`).
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Le port UDP de talkd, lu dans `talkd.json` au démarrage de ptzd (1986 par défaut, spec parler § 5).
public enum TalkPort {
    public static let defaultPort = 1986

    private struct Settings: Decodable {
        var port: Int?
    }

    /// Fichier absent, illisible, sans port ou avec un port hors de 1…65535 : le port par défaut.
    public static func load(from url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let port = (try? JSONDecoder().decode(Settings.self, from: data))?.port,
              (1...65_535).contains(port) else { return defaultPort }
        return port
    }
}

/// Prévient quand un fichier change (créé, remplacé, supprimé), derrière un protocole pour les tests.
@MainActor
public protocol FileChangeObserver: AnyObject {
    /// `onChange` est appelé sur le MainActor à chaque changement, jusqu'à l'annulation de la surveillance rendue.
    func observe(_ onChange: @escaping @MainActor @Sendable () -> Void) -> any Cancellable
}

/// Implémentation réelle : une source de dispatch sur le **dossier** du fichier. Un fichier écrit de façon atomique
/// (talkd : écriture dans un temporaire puis renommage) remplace son inode : une surveillance posée sur le fichier
/// lui-même perdrait la trace, alors que le dossier reçoit toujours l'événement (ajout, renommage, suppression).
/// Le dossier bouge aussi pour ses autres fichiers (journaux…) : un événement n'est transmis que si le fichier suivi a
/// vraiment changé (inode, taille ou date de modification).
/// Dossier absent : aucune surveillance, la relecture périodique reste le filet de sécurité.
@MainActor
public final class DispatchFileChangeObserver: FileChangeObserver {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func observe(_ onChange: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
        FileWatch(url: url, onChange: onChange)
    }
}

/// La surveillance en cours. Hors de tout acteur : les rappels de dispatch tournent sur sa file privée, et le saut vers
/// le MainActor est explicite (une closure formée dans un type `@MainActor` et appelée d'un autre fil plante en Swift 6).
private final class FileWatch: Cancellable, @unchecked Sendable {
    /// Ce qui identifie une version du fichier.
    private struct Signature: Equatable {
        var inode: UInt64
        var size: Int64
        var seconds: Int
        var nanoseconds: Int
    }

    private let path: String
    private let onChange: @MainActor @Sendable () -> Void
    private let queue = DispatchQueue(label: "io.github.djoko-cli.ptzd.file-watch")
    private var source: (any DispatchSourceFileSystemObject)?
    /// Touchée seulement par la file privée (et par l'init, avant le démarrage de la source).
    private var signature: Signature?

    init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        path = url.path
        self.onChange = onChange
        signature = Self.signature(of: path)
        let descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: queue
        )
        source.setEventHandler { [weak self] in self?.directoryChanged() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    deinit {
        source?.cancel()
    }

    func cancel() {
        source?.cancel()
    }

    /// Sur la file privée.
    private func directoryChanged() {
        let current = Self.signature(of: path)
        guard current != signature else { return }
        signature = current
        let onChange = onChange
        Task { @MainActor in onChange() }
    }

    private static func signature(of path: String) -> Signature? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Signature(
            inode: UInt64(info.st_ino), size: Int64(info.st_size),
            seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec
        )
    }
}

/// Relit l'état de talkd au démarrage puis toutes les 5 s (le secours), et dès que le fichier change quand un
/// observateur est donné (regroupé à 100 ms près). Ne signale que les changements de valeur.
@MainActor
public final class TalkbackWatcher {
    public static let interval: TimeInterval = 5
    /// Un changement du fichier déclenche une relecture après ce délai (secondes) : les changements rapprochés n'en font qu'une.
    public static let changeDebounce: TimeInterval = 0.1

    private let scheduler: any Scheduler
    private let read: @MainActor () -> TalkbackAvailability
    private let onChange: @MainActor (TalkbackAvailability) -> Void
    private let observer: (any FileChangeObserver)?
    private var last: TalkbackAvailability = .unavailable
    private var timer: (any Cancellable)?
    private var observation: (any Cancellable)?
    private var pendingCheck: (any Cancellable)?

    public init(
        scheduler: any Scheduler,
        read: @escaping @MainActor () -> TalkbackAvailability,
        onChange: @escaping @MainActor (TalkbackAvailability) -> Void,
        observer: (any FileChangeObserver)? = nil
    ) {
        self.scheduler = scheduler
        self.read = read
        self.onChange = onChange
        self.observer = observer
    }

    public func start() {
        poll()
        observation?.cancel()
        observation = observer?.observe { [weak self] in
            self?.fileChanged()
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        observation?.cancel()
        observation = nil
        pendingCheck?.cancel()
        pendingCheck = nil
    }

    private func poll() {
        check()
        timer = scheduler.schedule(after: Self.interval) { [weak self] in
            self?.poll()
        }
    }

    private func check() {
        let value = read()
        if value != last {
            last = value
            onChange(value)
        }
    }

    /// Le fichier d'état a changé : une relecture dans `changeDebounce`, sans toucher au rythme de la relecture périodique.
    private func fileChanged() {
        guard observation != nil, pendingCheck == nil else { return }
        pendingCheck = scheduler.schedule(after: Self.changeDebounce) { [weak self] in
            guard let self else { return }
            pendingCheck = nil
            guard observation != nil else { return }
            check()
        }
    }
}
