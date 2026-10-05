import Foundation
import Testing
@testable import PTZCore

@MainActor
@Suite("Lancement de obsbot-ai-off")
struct AIOffRunnerTests {
    private func run(_ path: String, _ arguments: [String] = [], timeout: TimeInterval = 5) async -> AIOffResult {
        let runner = ProcessAIOffRunner(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            timeout: timeout,
            scheduler: DispatchScheduler()
        )
        return await withCheckedContinuation { continuation in
            runner.run { continuation.resume(returning: $0) }
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

    @Test("Délai dépassé : le processus est arrêté")
    func timeout() async {
        #expect(await run("/bin/sleep", ["5"], timeout: 0.3) == .timeout)
    }

    @Test("La sortie de l'utilitaire est ajoutée au fichier choisi")
    func outputFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ai-off-\(UUID().uuidString)/out.log")
        for word in ["un", "deux"] {
            let runner = ProcessAIOffRunner(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: [word],
                outputURL: url,
                scheduler: DispatchScheduler()
            )
            let result = await withCheckedContinuation { continuation in
                runner.run { continuation.resume(returning: $0) }
            }
            #expect(result == .success)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "un\ndeux\n")
    }

    @Test("Exécutable absent")
    func launchFailure() async {
        guard case .launchFailed = await run("/nonexistent/obsbot-ai-off") else {
            Issue.record("launchFailed attendu")
            return
        }
    }
}
