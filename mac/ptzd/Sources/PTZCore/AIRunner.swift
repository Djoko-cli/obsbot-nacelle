import Foundation
import NacelleProtocol

/// Issue d'une exécution d'obsbot-ai (spec § 6.9, spec app Mac § 7.5).
public enum AIResult: Equatable, Sendable {
    case success
    case cameraNotFound
    case sdkError
    case timeout
    case launchFailed(String)
    case unexpectedExit(Int32)

    /// Le motif, en français, pour les messages montrés à l'utilisateur (le journal garde la forme brute).
    public var userDescription: String {
        switch self {
        case .success: "réussi"
        case .cameraNotFound: AIFailureText.cameraNotFound
        case .sdkError: AIFailureText.sdkError
        case .timeout: AIFailureText.timeout
        case .launchFailed: AIFailureText.launchFailed
        case let .unexpectedExit(status): AIFailureText.unexpectedExitPrefix + String(status)
        }
    }
}

/// Allume (`on`) ou coupe le suivi IA de la caméra.
@MainActor
public protocol AIRunner: AnyObject {
    func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void)
}

/// Lance `obsbot-ai on|off` dans un processus séparé, avec un délai maximal.
/// Le SDK est très bavard : sa sortie va dans un fichier à part, pas dans le journal de ptzd.
@MainActor
public final class ProcessAIRunner: AIRunner {
    private let executableURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let outputURL: URL?
    /// Variables ajoutées à l'environnement hérité (`DYLD_LIBRARY_PATH` du SDK, spec ptzd dans l'app § 5.4).
    private let environment: [String: String]
    private let scheduler: any Scheduler
    /// Dernier utilitaire lancé : retenu jusqu'au suivant, pour refuser un chevauchement.
    private(set) var current: Process?

    /// Délai entre SIGTERM et SIGKILL quand le délai maximal est dépassé.
    static let killDelay: TimeInterval = 2

    public init(
        executableURL: URL,
        arguments: [String] = [],
        timeout: TimeInterval = 15,
        outputURL: URL? = nil,
        environment: [String: String] = [:],
        scheduler: any Scheduler
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.outputURL = outputURL
        self.environment = environment
        self.scheduler = scheduler
    }

    /// Lance l'utilitaire avec `arguments`, puis `on` ou `off`.
    public func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        // Un utilitaire expiré peut vivre encore jusqu'au SIGKILL : pas de second en parallèle.
        if let previous = current, previous.isRunning {
            completion(.launchFailed("obsbot-ai précédent encore en cours"))
            return
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments + [on ? "on" : "off"]
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let output = appendingHandle()
        if let output {
            process.standardOutput = output
            process.standardError = output
        }
        let run = Run(process: process)

        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            let exited = finished.terminationReason == .exit
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard run.finish() else { return }
                    completion(Self.result(status: status, exited: exited))
                }
            }
        }

        do {
            try process.run()
        } catch {
            try? output?.close()
            run.finish()
            completion(.launchFailed(error.localizedDescription))
            return
        }
        // Le fils a sa propre copie du descripteur : celle du parent fuirait à chaque exécution.
        try? output?.close()
        current = process

        // Capture faible : tant que le processus tourne, son gestionnaire de fin retient `run`.
        run.timeoutTask = scheduler.schedule(after: timeout) { [weak self, weak run] in
            guard let run, run.finish() else { return }
            self?.stop(run.process)
            completion(.timeout)
        }
    }

    /// SIGTERM, puis SIGKILL si l'utilitaire vit encore 2 s plus tard.
    private func stop(_ process: Process) {
        process.terminate()
        let pid = process.processIdentifier
        scheduler.schedule(after: Self.killDelay) { [weak process] in
            guard let process, process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    /// Fichier de sortie ouvert en ajout, créé au besoin ; nil si aucun n'est configuré.
    private func appendingHandle() -> FileHandle? {
        guard let outputURL else { return nil }
        let manager = FileManager.default
        try? manager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: outputURL.path) {
            manager.createFile(atPath: outputURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: outputURL) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    /// Codes de sortie de obsbot-ai : 0 succès, 1 caméra introuvable, 2 erreur du SDK.
    public static func result(status: Int32, exited: Bool) -> AIResult {
        guard exited else { return .unexpectedExit(status) }
        switch status {
        case 0: return .success
        case 1: return .cameraNotFound
        case 2: return .sdkError
        default: return .unexpectedExit(status)
        }
    }
}

/// État d'une exécution, partagé entre le gestionnaire de fin et la minuterie.
@MainActor
private final class Run {
    let process: Process
    var done = false
    var timeoutTask: (any Cancellable)?

    init(process: Process) {
        self.process = process
    }

    /// Marque l'exécution terminée, une seule fois, et rompt les cycles de rétention
    /// (processus → gestionnaire de fin → run, run → minuterie → run).
    /// Renvoie false si elle l'était déjà.
    @discardableResult
    func finish() -> Bool {
        guard !done else { return false }
        done = true
        process.terminationHandler = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        return true
    }
}
