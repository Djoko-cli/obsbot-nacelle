import Foundation
import Testing
@testable import GardienCore

/// Le gardien compilé, lancé pour de vrai avec de petits processus (spec B3 § 10) : un `sleep` tient le rôle de
/// PTZBot, un shell celui de go2rtc. Le shell écrit son pid, puis devient `sleep` (en ignorant SIGTERM s'il le faut).
/// Toutes les attentes sont bornées.
@MainActor
@Suite("Gardien : vrais processus", .timeLimit(.minutes(1)))
struct GardienProcessTests {
    /// Construit par `swift build`, que la commande de vérification lance avant `swift test`.
    static let executable = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/debug/gardien")

    static let sleeps = #"echo $$ > "$1"; exec /bin/sleep 60"#
    static let ignoresTerm = #"trap "" TERM; echo $$ > "$1"; exec /bin/sleep 60"#
    static let exitsSeven = #"echo $$ > "$1"; exit 7"#

    private func wait(_ limit: Duration, until condition: () -> Bool) async throws -> Bool {
        let start = ContinuousClock.now
        while !condition() {
            guard ContinuousClock.now - start < limit else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func launch(_ executable: URL, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Le parent : un `sleep` à tuer.
    private func launchParent() throws -> Process {
        try launch(URL(fileURLWithPath: "/bin/sleep"), ["60"])
    }

    /// Le gardien sur un shell qui écrit son pid dans le fichier rendu.
    private func launchGardien(parent: pid_t, stopDelay: String = "10", script: String) throws -> (process: Process, pidFile: URL) {
        try #require(FileManager.default.isExecutableFile(atPath: Self.executable.path), "lancez `swift build` avant `swift test`")
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "gardien-\(UUID().uuidString).pid")
        let process = try launch(Self.executable, ["--parent", String(parent), "--arret", stopDelay, "--", "/bin/sh", "-c", script, "sh", pidFile.path])
        return (process, pidFile)
    }

    /// Le pid écrit par le programme, attendu 5 s au plus.
    private func childPID(_ file: URL) async throws -> pid_t {
        var pid: pid_t?
        _ = try await wait(.seconds(5)) {
            pid = (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return pid != nil
        }
        return try #require(pid, "le programme n'a pas écrit son pid")
    }

    /// Fin de test : tout ce qui vit encore est tué, le fichier du pid retiré.
    private func cleanUp(_ processes: [Process], child: pid_t?, pidFile: URL) {
        for process in processes where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        if let child, !Gardien.isGone(child) {
            kill(child, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    @Test("Parent disparu : SIGTERM au programme, qui s'arrête ; le gardien finit comme lui")
    func parentGone() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.sleeps)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        kill(parent.processIdentifier, SIGKILL)
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationReason == .uncaughtSignal)
        #expect(gardien.terminationStatus == SIGTERM)
    }

    @Test("Parent disparu, programme qui ignore SIGTERM : SIGKILL après --arret, pas avant")
    func stubbornChild() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, stopDelay: "2", script: Self.ignoresTerm)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        kill(parent.processIdentifier, SIGKILL)
        try await Task.sleep(for: .seconds(1))
        #expect(!Gardien.isGone(child), "encore là à 1 s : le délai est de 2 s")
        #expect(gardien.isRunning)
        #expect(try await wait(.seconds(5)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationReason == .uncaughtSignal)
        #expect(gardien.terminationStatus == SIGKILL)
    }

    @Test("SIGTERM au gardien : transmis au programme, qui s'arrête")
    func forwardsTerm() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.sleeps)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        gardien.terminate()
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationReason == .uncaughtSignal)
        #expect(gardien.terminationStatus == SIGTERM)
        #expect(parent.isRunning, "le parent n'est pas touché")
    }

    @Test("SIGINT au gardien : transmis au programme")
    func forwardsInt() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.sleeps)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        gardien.interrupt()
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationReason == .uncaughtSignal)
        #expect(gardien.terminationStatus == SIGINT)
    }

    @Test("SIGTERM ignoré par le programme : SIGKILL après --arret")
    func termThenKill() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, stopDelay: "1", script: Self.ignoresTerm)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        gardien.terminate()
        #expect(try await wait(.seconds(5)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationStatus == SIGKILL)
    }

    @Test("Le code de sortie du programme est rendu")
    func exitStatus() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.exitsSeven)
        defer { cleanUp([parent, gardien], child: nil, pidFile: pidFile) }
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(gardien.terminationReason == .exit)
        #expect(gardien.terminationStatus == 7)
    }

    @Test("Parent déjà disparu : rien n'est lancé, code 69")
    func parentAlreadyGone() async throws {
        // Un processus lancé puis attendu jusqu'au bout : son PID est libre.
        let finished = try launch(URL(fileURLWithPath: "/usr/bin/true"), [])
        finished.waitUntilExit()
        let (gardien, pidFile) = try launchGardien(parent: finished.processIdentifier, script: Self.sleeps)
        defer { cleanUp([gardien], child: nil, pidFile: pidFile) }
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(gardien.terminationStatus == GardienExit.parentGone)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path), "le programme n'a pas été lancé")
    }

    @Test("Programme introuvable : code 127 ; options refusées : code 64")
    func failures() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.executable.path), "lancez `swift build` avant `swift test`")
        let parent = try launchParent()
        defer { cleanUp([parent], child: nil, pidFile: URL(fileURLWithPath: "/dev/null/x")) }
        let missing = try launch(Self.executable, ["--parent", String(parent.processIdentifier), "--arret", "1", "--", "/chemin/introuvable/go2rtc"])
        let refused = try launch(Self.executable, ["--parent", "abc"])
        #expect(try await wait(.seconds(3)) { !missing.isRunning && !refused.isRunning })
        #expect(missing.terminationStatus == GardienExit.launchFailed)
        #expect(refused.terminationStatus == GardienExit.usage)
    }
}
