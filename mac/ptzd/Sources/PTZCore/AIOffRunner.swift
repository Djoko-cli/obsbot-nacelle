import Foundation

/// Issue d'une exécution d'obsbot-ai-off (spec § 6.9).
public enum AIOffResult: Equatable, Sendable {
    case success
    case cameraNotFound
    case sdkError
    case timeout
    case launchFailed(String)
    case unexpectedExit(Int32)
}

@MainActor
public protocol AIOffRunner: AnyObject {
    func run(completion: @escaping @MainActor @Sendable (AIOffResult) -> Void)
}

/// Lance obsbot-ai-off dans un processus séparé, avec un délai maximal.
/// Le SDK est très bavard : sa sortie va dans un fichier à part, pas dans le journal de ptzd.
@MainActor
public final class ProcessAIOffRunner: AIOffRunner {
    private let executableURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let outputURL: URL?
    private let scheduler: any Scheduler

    public init(
        executableURL: URL,
        arguments: [String] = [],
        timeout: TimeInterval = 15,
        outputURL: URL? = nil,
        scheduler: any Scheduler
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.outputURL = outputURL
        self.scheduler = scheduler
    }

    public func run(completion: @escaping @MainActor @Sendable (AIOffResult) -> Void) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let output = appendingHandle() {
            process.standardOutput = output
            process.standardError = output
        }
        let run = Run(process: process)

        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            let exited = finished.terminationReason == .exit
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !run.done else { return }
                    run.done = true
                    run.timeoutTask?.cancel()
                    completion(Self.result(status: status, exited: exited))
                }
            }
        }

        do {
            try process.run()
        } catch {
            run.done = true
            completion(.launchFailed(error.localizedDescription))
            return
        }

        run.timeoutTask = scheduler.schedule(after: timeout) {
            guard !run.done else { return }
            run.done = true
            run.process.terminate()
            completion(.timeout)
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

    /// Codes de sortie de obsbot-ai-off : 0 succès, 1 caméra introuvable, 2 erreur du SDK.
    public static func result(status: Int32, exited: Bool) -> AIOffResult {
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
}
