import Foundation
import ServiceManagement
@testable import PTZBotKit

/// Horloge manuelle : `advance(by:)` exécute les actions arrivées à échéance, dans l'ordre.
@MainActor
final class FakeScheduler: Scheduler {
    private(set) var now: TimeInterval = 0
    private var tasks: [FakeTask] = []
    private var counter = 0

    /// Actions programmées et pas annulées.
    var pendingCount: Int {
        tasks.filter { !$0.cancelled }.count
    }

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
        counter += 1
        let task = FakeTask(at: now + delay, order: counter, action: action)
        tasks.append(task)
        return task
    }

    func advance(by delta: TimeInterval) {
        let target = now + delta
        while let next = tasks
            .filter({ !$0.cancelled && $0.at <= target + 1e-9 })
            .min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            tasks.removeAll { $0 === next }
            now = max(now, next.at)
            next.action()
        }
        now = target
        tasks.removeAll { $0.cancelled }
    }
}

final class FakeTask: Cancellable {
    let at: TimeInterval
    let order: Int
    let action: @MainActor @Sendable () -> Void
    private(set) var cancelled = false

    init(at: TimeInterval, order: Int, action: @escaping @MainActor @Sendable () -> Void) {
        self.at = at
        self.order = order
        self.action = action
    }

    func cancel() {
        cancelled = true
    }
}

/// Connexion simulée : enregistre les ouvertures et les envois ; le test déclenche les événements.
@MainActor
final class FakeAdminTransport: AdminTransport {
    var onEvent: ((AdminTransportEvent) -> Void)?
    private(set) var opened: [URL] = []
    private(set) var sent: [String] = []

    func open(_ url: URL) {
        opened.append(url)
    }

    func send(_ text: String) {
        sent.append(text)
    }

    func close() {}

    func emit(_ event: AdminTransportEvent) {
        onEvent?(event)
    }
}

/// `SMAppService` simulé.
@MainActor
final class FakeLoginItem: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var failure: (any Error)?
    private(set) var settingsOpened = 0
    var statusAfterRegister: SMAppService.Status = .enabled
    /// Un échec réservé à `register()` (`unregister()` réussit alors).
    var registerFailure: (any Error)?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    func register() throws {
        registerCalls += 1
        if let error = failure ?? registerFailure {
            throw error
        }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if let failure {
            throw failure
        }
        status = .notRegistered
    }

    /// Garde `unregisterAndWait()` en suspens jusqu'à `finishUnregister()`.
    var holdUnregister = false
    private var heldUnregister: CheckedContinuation<Void, Never>?

    var isUnregisterPending: Bool {
        heldUnregister != nil
    }

    func unregisterAndWait() async throws {
        unregisterCalls += 1
        if let failure {
            throw failure
        }
        if holdUnregister {
            await withCheckedContinuation { heldUnregister = $0 }
        }
        status = .notRegistered
    }

    func finishUnregister() {
        heldUnregister?.resume()
        heldUnregister = nil
    }

    func openSystemSettings() {
        settingsOpened += 1
    }
}

/// Préférences en mémoire.
@MainActor
final class FakeSettings: SettingsStore {
    var values: [String: Bool] = [:]
    var strings: [String: String] = [:]
    var arrays: [String: [String]] = [:]

    func bool(forKey key: String) -> Bool? {
        values[key]
    }

    func set(_ value: Bool, forKey key: String) {
        values[key] = value
    }

    func string(forKey key: String) -> String? {
        strings[key]
    }

    func set(_ value: String?, forKey key: String) {
        strings[key] = value
    }

    func set(_ value: [String]?, forKey key: String) {
        arrays[key] = value
    }
}

/// Processus simulé : le test décide de sa fin.
@MainActor
final class FakeProcess: LaunchedProcess {
    let pid: pid_t
    let arguments: [String]
    let outputURL: URL
    private let onExit: @MainActor (ProcessExit) -> Void
    private(set) var isRunning = true
    private(set) var terminations = 0
    private(set) var kills = 0
    /// SIGTERM ignoré (ptzd bloqué) : seul SIGKILL l'arrête.
    var ignoresTerminate = false
    /// Fin jamais signalée, même après SIGKILL (processus bloqué dans le noyau).
    var ignoresKill = false

    init(pid: pid_t, arguments: [String], outputURL: URL, onExit: @escaping @MainActor (ProcessExit) -> Void) {
        self.pid = pid
        self.arguments = arguments
        self.outputURL = outputURL
        self.onExit = onExit
    }

    func terminate() {
        terminations += 1
        if !ignoresTerminate {
            exit(ProcessExit(status: SIGTERM, signaled: true))
        }
    }

    func kill() {
        kills += 1
        guard !ignoresKill else { return }
        exit(ProcessExit(status: SIGKILL, signaled: true))
    }

    /// Fin du processus ; `onExit` arrive comme avec `Process`, plus tard sur la file principale : ici, tout de suite.
    func exit(_ exit: ProcessExit = ProcessExit(status: 1, signaled: false)) {
        guard isRunning else { return }
        isRunning = false
        onExit(exit)
    }

    /// Fin reçue une seconde fois, comme une fin tardive après relance : `onExit` est rappelé sans le garde `isRunning`.
    func fireLateExit(_ exit: ProcessExit = ProcessExit(status: 1, signaled: false)) {
        onExit(exit)
    }
}

/// Lanceur simulé : retient chaque processus lancé.
@MainActor
final class FakeLauncher: ProcessLauncher {
    struct Failure: LocalizedError {
        var errorDescription: String? { "fichier introuvable" }
    }

    private(set) var launched: [FakeProcess] = []
    private(set) var executables: [URL] = []
    var failure: (any Error)?

    var last: FakeProcess? {
        launched.last
    }

    func launch(
        executableURL: URL,
        arguments: [String],
        outputURL: URL,
        onExit: @escaping @MainActor (ProcessExit) -> Void
    ) throws -> any LaunchedProcess {
        if let failure {
            throw failure
        }
        executables.append(executableURL)
        let process = FakeProcess(pid: pid_t(1000 + launched.count), arguments: arguments, outputURL: outputURL, onExit: onExit)
        launched.append(process)
        return process
    }
}

/// L'état écrit par talkd, simulé.
@MainActor
final class FakeTalkbackState: TalkbackStateSource {
    var state: TalkbackState?
    private(set) var reads = 0

    func read() -> TalkbackState? {
        reads += 1
        return state
    }
}

/// Les processus vivants, simulés.
@MainActor
final class FakeProcessProbe: ProcessProbe {
    var alive: Set<Int32> = []

    func isAlive(pid: Int32) -> Bool {
        alive.contains(pid)
    }
}
