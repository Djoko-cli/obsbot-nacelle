import Foundation
import Testing
@testable import PTZCore

@MainActor
@Suite("Lancement de obsbot-ai")
struct AIRunnerTests {
    private func run(_ path: String, _ arguments: [String] = [], timeout: TimeInterval = 5) async -> AIResult {
        let runner = ProcessAIRunner(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            timeout: timeout,
            scheduler: DispatchScheduler()
        )
        return await withCheckedContinuation { continuation in
            runner.run(on: false) { continuation.resume(returning: $0) }
        }
    }

    @Test("Code 0 : succès")
    func success() async {
        #expect(await run("/usr/bin/true") == .success)
    }

    @Test("Code 1 : caméra introuvable")
    func cameraNotFound() async {
        #expect(await run("/usr/bin/false") == .cameraNotFound)
    }

    @Test("Code 2 : erreur du SDK ; autre code : sortie inattendue")
    func otherCodes() async {
        #expect(await run("/bin/sh", ["-c", "exit 2"]) == .sdkError)
        #expect(await run("/bin/sh", ["-c", "exit 7"]) == .unexpectedExit(7))
    }

    @Test("Motifs en français pour l'utilisateur : aucune forme brute de l'énumération")
    func userDescriptions() {
        #expect(AIResult.cameraNotFound.userDescription == "caméra introuvable")
        #expect(AIResult.sdkError.userDescription == "erreur du SDK OBSBOT")
        #expect(AIResult.timeout.userDescription == "délai dépassé")
        #expect(AIResult.launchFailed("/x : introuvable").userDescription == "l'utilitaire n'a pas pu être lancé")
        #expect(AIResult.unexpectedExit(7).userDescription == "l'utilitaire s'est arrêté avec le code 7")
    }

    @Test("Délai dépassé : le processus est arrêté")
    func timeout() async {
        #expect(await run("/bin/sh", ["-c", "sleep 5"], timeout: 0.3) == .timeout)
    }

    @Test("La sortie de l'utilitaire est ajoutée au fichier choisi ; le mode (on ou off) vient en dernier argument")
    func outputFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ai-\(UUID().uuidString)/out.log")
        for (word, on) in [("un", true), ("deux", false)] {
            let runner = ProcessAIRunner(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: [word],
                outputURL: url,
                scheduler: DispatchScheduler()
            )
            let result = await withCheckedContinuation { continuation in
                runner.run(on: on) { continuation.resume(returning: $0) }
            }
            #expect(result == .success)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "un on\ndeux off\n")
    }

    @Test("environment s'ajoute à l'environnement hérité : DYLD_LIBRARY_PATH est donné à l'utilitaire")
    func environment() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ai-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "env.txt")
        // /bin/sh est protégé par SIP : dyld lui retire les variables DYLD_*. La transmission est donc
        // vérifiée par une variable ordinaire, et DYLD_LIBRARY_PATH sur l'environnement du processus lancé.
        let runner = ProcessAIRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s|%s' \"$PTZD_ESSAI\" \"${HOME:+hérité}\" > \"$1\"", "sh", output.path],
            environment: ["DYLD_LIBRARY_PATH": "/sdk/dossier", "PTZD_ESSAI": "transmis"],
            scheduler: DispatchScheduler()
        )
        #expect(await runOnce(runner) == .success)
        #expect(try String(contentsOf: output, encoding: .utf8) == "transmis|hérité")
        let environment = try #require(runner.current?.environment)
        #expect(environment["DYLD_LIBRARY_PATH"] == "/sdk/dossier")
        #expect(environment["HOME"] == ProcessInfo.processInfo.environment["HOME"])
    }

    @Test("Sans environment : l'environnement hérité tel quel")
    func inheritedEnvironment() async throws {
        let runner = ProcessAIRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), scheduler: DispatchScheduler())
        #expect(await runOnce(runner) == .success)
        #expect(runner.current?.environment == nil)
    }

    @Test("Exécutable absent")
    func launchFailure() async {
        guard case .launchFailed = await run("/nonexistent/obsbot-ai") else {
            Issue.record("launchFailed attendu")
            return
        }
    }

    private func runOnce(_ runner: ProcessAIRunner) async -> AIResult {
        await withCheckedContinuation { continuation in
            runner.run(on: false) { continuation.resume(returning: $0) }
        }
    }

    private static func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// Descripteurs ouverts sur ce fichier (F_GETPATH), insensible aux tests parallèles.
    private static func descriptors(on url: URL) -> Int {
        let wanted = url.resolvingSymlinksInPath().path
        var count = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? [] {
            guard let fd = Int32(name) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &buffer) == 0 else { continue }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if URL(fileURLWithPath: path).resolvingSymlinksInPath().path == wanted {
                count += 1
            }
        }
        return count
    }

    @Test("30 exécutions avec fichier de sortie : aucun descripteur ne fuit")
    func noDescriptorLeak() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "ai-off-\(UUID().uuidString)/out.log")
        let runner = ProcessAIRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            outputURL: url,
            scheduler: DispatchScheduler()
        )
        let before = Self.openDescriptors()
        for _ in 0..<30 {
            #expect(await runOnce(runner) == .success)
        }
        let after = Self.openDescriptors()
        // Le compte exact sur le fichier de sortie ne dépend pas des autres tests ;
        // le compte global tolère le bruit des suites lancées en parallèle, qui lancent elles aussi des processus
        // (ptzd de bout en bout, verrou de service) ; la fuite en ajoutait 30.
        #expect(Self.descriptors(on: url) == 0)
        #expect(abs(after - before) <= 12, "descripteurs : \(before) avant, \(after) après")
    }

    @Test("Les processus terminés sont libérés")
    func processReleased() async throws {
        let runner = ProcessAIRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), scheduler: DispatchScheduler())
        #expect(await runOnce(runner) == .success)
        weak let first = runner.current
        #expect(first != nil)
        #expect(await runOnce(runner) == .success)
        for _ in 0..<20 where first != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(first == nil)
    }

    @Test("SIGTERM ignoré : SIGKILL 2 s plus tard, puis un nouveau lancement est possible")
    func killAfterTimeout() async throws {
        // exec : sleep hérite du SIGTERM ignoré, et le SIGKILL ne laisse pas d'orphelin.
        let stubborn = ProcessAIRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; exec sleep 30"],
            timeout: 0.3,
            scheduler: DispatchScheduler()
        )
        #expect(await runOnce(stubborn) == .timeout)
        let process = try #require(stubborn.current)
        #expect(process.isRunning)
        let start = ContinuousClock.now
        var result = await runOnce(stubborn)
        while case .launchFailed = result, ContinuousClock.now - start < .seconds(4) {
            try await Task.sleep(for: .milliseconds(100))
            result = await runOnce(stubborn)
        }
        // Le SIGKILL est parti, le processus a disparu : le runner relance (et réexpire).
        #expect(result == .timeout)
        #expect(ContinuousClock.now - start < .seconds(3.5))
        #expect(!process.isRunning)
    }

    @Test("Exécution précédente encore en cours : launchFailed, rien n'est lancé")
    func noOverlap() async {
        let runner = ProcessAIRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 0.5"],
            scheduler: DispatchScheduler()
        )
        let first = Task { await runOnce(runner) }
        while runner.current == nil {
            await Task.yield()
        }
        let running = runner.current
        #expect(await runOnce(runner) == .launchFailed("obsbot-ai précédent encore en cours"))
        #expect(runner.current === running)
        #expect(await first.value == .success)
        #expect(await runOnce(runner) == .success)
    }
}
