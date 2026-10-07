import Foundation
import Testing
@testable import PTZCore

@MainActor
@Suite("Surveillance du parent (--parent)")
struct ParentWatcherTests {
    /// Attend `condition` au plus `limit`, en laissant tourner la file principale.
    private func wait(_ limit: Duration, until condition: () -> Bool) async throws -> Bool {
        let start = ContinuousClock.now
        while !condition() {
            guard ContinuousClock.now - start < limit else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test("Un vrai processus tué par SIGKILL : rappel en moins de 2 s, une seule fois")
    func killedProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        var calls = 0
        let watcher = ParentWatcher(pid: process.processIdentifier) { calls += 1 }
        watcher.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 0)
        let killedAt = ContinuousClock.now
        kill(process.processIdentifier, SIGKILL)
        #expect(try await wait(.seconds(2)) { calls > 0 })
        #expect(ContinuousClock.now - killedAt < .seconds(2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1)
    }

    @Test("Un PID qui n'existe pas : rappel aussitôt")
    func missingProcess() throws {
        // Un processus lancé puis attendu jusqu'au bout : son PID est libre.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let pid = process.processIdentifier
        #expect(ParentWatcher.isGone(pid))
        var calls = 0
        let watcher = ParentWatcher(pid: pid) { calls += 1 }
        watcher.start()
        #expect(calls == 1)
        watcher.start()
        #expect(calls == 1)
    }

    @Test("Un processus vivant n'est pas déclaré disparu")
    func aliveProcess() {
        #expect(!ParentWatcher.isGone(getpid()))
        // launchd appartient à root : EPERM, pas ESRCH.
        #expect(!ParentWatcher.isGone(1))
    }
}
