import Foundation

/// La fin d'un processus lancé.
public struct ProcessExit: Equatable, Sendable {
    /// Code de sortie, ou numéro du signal.
    public var status: Int32
    /// Arrêté par un signal (SIGTERM, SIGKILL, plantage).
    public var signaled: Bool

    public init(status: Int32, signaled: Bool) {
        self.status = status
        self.signaled = signaled
    }
}

/// Un processus lancé par `ProcessLauncher`.
@MainActor
public protocol LaunchedProcess: AnyObject {
    var pid: pid_t { get }
    var isRunning: Bool { get }
    /// SIGTERM.
    func terminate()
    /// SIGKILL.
    func kill()
}

/// Lance un processus, sa sortie et ses erreurs ajoutées à un fichier ; derrière un protocole pour les tests.
@MainActor
public protocol ProcessLauncher: AnyObject {
    /// `onExit` est appelé une fois, sur le MainActor, quand le processus se termine.
    func launch(
        executableURL: URL,
        arguments: [String],
        outputURL: URL,
        onExit: @escaping @MainActor (ProcessExit) -> Void
    ) throws -> any LaunchedProcess
}

/// Implémentation réelle, sur `Process`.
@MainActor
public final class FoundationProcessLauncher: ProcessLauncher {
    public init() {}

    public func launch(
        executableURL: URL,
        arguments: [String],
        outputURL: URL,
        onExit: @escaping @MainActor (ProcessExit) -> Void
    ) throws -> any LaunchedProcess {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let output = try Self.appendingHandle(outputURL)
        // Le processus ne lit jamais l'entrée standard de l'app.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { finished in
            let exit = ProcessExit(status: finished.terminationStatus, signaled: finished.terminationReason == .uncaughtSignal)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onExit(exit) }
            }
        }
        defer {
            // Le fils a sa propre copie du descripteur : celle de l'app fuirait à chaque lancement.
            try? output.close()
        }
        try process.run()
        return FoundationLaunchedProcess(process: process)
    }

    /// Le fichier ouvert en ajout (`O_APPEND`), créé avec son dossier au besoin. `O_CLOEXEC` : seul le processus
    /// lancé en hérite, par sa sortie standard, pas les autres enfants de l'app.
    static func appendingHandle(_ url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

@MainActor
private final class FoundationLaunchedProcess: LaunchedProcess {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var pid: pid_t {
        process.processIdentifier
    }

    var isRunning: Bool {
        process.isRunning
    }

    func terminate() {
        process.terminate()
    }

    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}
