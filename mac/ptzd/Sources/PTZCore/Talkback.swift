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

/// Relit l'état de talkd au démarrage puis toutes les 5 s, et ne signale que les changements de valeur.
@MainActor
public final class TalkbackWatcher {
    public static let interval: TimeInterval = 5

    private let scheduler: any Scheduler
    private let read: @MainActor () -> TalkbackAvailability
    private let onChange: @MainActor (TalkbackAvailability) -> Void
    private var last: TalkbackAvailability = .unavailable
    private var timer: (any Cancellable)?

    public init(
        scheduler: any Scheduler,
        read: @escaping @MainActor () -> TalkbackAvailability,
        onChange: @escaping @MainActor (TalkbackAvailability) -> Void
    ) {
        self.scheduler = scheduler
        self.read = read
        self.onChange = onChange
    }

    public func start() {
        poll()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        let value = read()
        if value != last {
            last = value
            onChange(value)
        }
        timer = scheduler.schedule(after: Self.interval) { [weak self] in
            self?.poll()
        }
    }
}
