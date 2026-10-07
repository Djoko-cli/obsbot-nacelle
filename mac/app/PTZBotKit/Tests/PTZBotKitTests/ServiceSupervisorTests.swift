import Foundation
import Testing
@testable import PTZBotKit

@MainActor
@Suite("Supervision de ptzd")
struct ServiceSupervisorTests {
    let launcher = FakeLauncher()
    let settings = FakeSettings()
    let scheduler = FakeScheduler()
    let paths = ServiceSupervisor.Paths(
        ptzd: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/ptzd"),
        ai: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/obsbot-ai"),
        sdkDirectory: URL(fileURLWithPath: "/support/sdk"),
        log: URL(fileURLWithPath: "/logs/ptzd.log")
    )

    private func makeSupervisor() -> ServiceSupervisor {
        ServiceSupervisor(paths: paths, launcher: launcher, settings: settings, scheduler: scheduler, parentPID: 4242)
    }

    @Test("Démarrage : ptzd lancé avec --parent, --ai et --sdk, sortie vers le journal")
    func start() throws {
        let supervisor = makeSupervisor()
        #expect(supervisor.state == .stopped)
        supervisor.start()
        #expect(supervisor.state == .running)
        let process = try #require(launcher.last)
        #expect(launcher.executables == [paths.ptzd])
        #expect(process.arguments == ["--parent", "4242", "--ai", paths.ai.path, "--sdk", "/support/sdk"])
        #expect(process.outputURL == paths.log)
        supervisor.start()
        #expect(launcher.launched.count == 1)
    }

    @Test("Binaire introuvable : failed avec le motif, sans relance")
    func launchFailure() {
        launcher.failure = FakeLauncher.Failure()
        let supervisor = makeSupervisor()
        supervisor.start()
        #expect(supervisor.state == .failed(reason: "ptzd n'a pas pu être lancé : fichier introuvable"))
        scheduler.advance(by: 60)
        #expect(launcher.launched.isEmpty)
    }

    @Test("Arrêt : SIGTERM, puis stopped et completion à la fin du processus, sans relance")
    func stop() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        let process = try #require(launcher.last)
        var done = 0
        supervisor.stop { done += 1 }
        #expect(process.terminations == 1)
        #expect(process.kills == 0)
        #expect(supervisor.state == .stopped)
        #expect(done == 1)
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
        #expect(process.kills == 0)
    }

    @Test("SIGTERM ignoré : SIGKILL 5 s plus tard ; completion seulement à la fin du processus")
    func killAfterDelay() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        var done = 0
        supervisor.stop { done += 1 }
        supervisor.stop { done += 1 }
        #expect(process.terminations == 1)
        scheduler.advance(by: ServiceSupervisor.killDelay - 0.1)
        #expect(process.kills == 0)
        #expect(done == 0)
        #expect(supervisor.state == .running)
        scheduler.advance(by: 0.1)
        #expect(process.kills == 1)
        #expect(done == 2)
        #expect(supervisor.state == .stopped)
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
    }

    @Test("Arrêt sans processus : completion tout de suite")
    func stopWhenStopped() {
        let supervisor = makeSupervisor()
        var done = false
        supervisor.stop { done = true }
        #expect(done)
        #expect(supervisor.state == .stopped)
    }

    @Test("Arrêt inattendu : relance après 1, 2, 4, 8, 16 puis 30 s")
    func restartDelays() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        // Chaque ptzd tient 25 s : jamais plus de 5 arrêts en 2 min, jamais 2 min d'affilée.
        for (index, delay) in [1.0, 2, 4, 8, 16, 30, 30].enumerated() {
            scheduler.advance(by: 25)
            try #require(launcher.last).exit()
            #expect(supervisor.state == .restarting(count: index + 1))
            scheduler.advance(by: delay - 0.1)
            #expect(launcher.launched.count == index + 1)
            scheduler.advance(by: 0.1)
            #expect(launcher.launched.count == index + 2)
            #expect(supervisor.state == .running)
        }
    }

    @Test("Plus de 5 arrêts inattendus en 2 min : failed, sans relance")
    func crashLoop() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        for delay in [1.0, 2, 4, 8, 16] {
            try #require(launcher.last).exit()
            scheduler.advance(by: delay)
        }
        #expect(launcher.launched.count == 6)
        try #require(launcher.last).exit()
        #expect(supervisor.state == .failed(reason: "ptzd s'arrête sans cesse : ouvrez le journal"))
        scheduler.advance(by: 300)
        #expect(launcher.launched.count == 6)
        // L'interrupteur, éteint puis rallumé, repart de zéro.
        supervisor.setEnabled(false)
        #expect(supervisor.state == .stopped)
        supervisor.setEnabled(true)
        #expect(supervisor.state == .running)
        #expect(launcher.launched.count == 7)
        try #require(launcher.last).exit()
        #expect(supervisor.state == .restarting(count: 1))
    }

    @Test("Un ptzd qui a tenu 2 min repart du premier délai")
    func stableRunResetsDelay() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        try #require(launcher.last).exit()
        scheduler.advance(by: 1)
        try #require(launcher.last).exit()
        #expect(supervisor.state == .restarting(count: 2))
        scheduler.advance(by: 2)
        scheduler.advance(by: ServiceSupervisor.failureWindow)
        try #require(launcher.last).exit()
        #expect(supervisor.state == .restarting(count: 1))
        scheduler.advance(by: 1)
        #expect(launcher.launched.count == 4)
    }

    @Test("Arrêt pendant le délai de relance : pas de relance")
    func stopDuringRestart() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        try #require(launcher.last).exit()
        var done = false
        supervisor.stop { done = true }
        #expect(done)
        #expect(supervisor.state == .stopped)
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
    }

    @Test("Interrupteur : allumé par défaut, retenu, lance ou arrête ptzd")
    func toggle() throws {
        let supervisor = makeSupervisor()
        #expect(supervisor.isEnabled)
        supervisor.start()
        supervisor.setEnabled(false)
        #expect(settings.values[ServiceSupervisor.enabledKey] == false)
        #expect(try #require(launcher.last).terminations == 1)
        #expect(supervisor.state == .stopped)
        supervisor.start()
        #expect(launcher.launched.count == 1)

        let next = makeSupervisor()
        #expect(!next.isEnabled)
        next.start()
        #expect(launcher.launched.count == 1)
        next.setEnabled(true)
        #expect(settings.values[ServiceSupervisor.enabledKey] == true)
        #expect(launcher.launched.count == 2)
        #expect(makeSupervisor().isEnabled)
    }

    @Test("Ancien agent actif : aucun lancement ; levé : lancement possible")
    func legacyAgent() {
        let supervisor = makeSupervisor()
        supervisor.legacyAgentActive = true
        supervisor.start()
        supervisor.setEnabled(true)
        #expect(launcher.launched.isEmpty)
        #expect(supervisor.state == .stopped)
        supervisor.legacyAgentActive = false
        supervisor.start()
        #expect(launcher.launched.count == 1)
    }

    @Test("Sortie 75 (port ou verrou pris) : failed avec le port, sans relance")
    func busy() throws {
        let supervisor = makeSupervisor()
        supervisor.port = 19870
        supervisor.start()
        try #require(launcher.last).exit(ProcessExit(status: 75, signaled: false))
        #expect(supervisor.state == .failed(reason: "Le port 19870 est déjà pris : un autre ptzd tourne peut-être encore"))
        scheduler.advance(by: 300)
        #expect(launcher.launched.count == 1)
    }

    @Test("Sortie 78 (config.json) ou 64 (arguments) : failed, sans relance ; signal 75 : arrêt inattendu ordinaire")
    func permanentFailures() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        try #require(launcher.last).exit(ProcessExit(status: 78, signaled: false))
        #expect(supervisor.state == .failed(reason: "config.json est invalide : ouvrez le journal"))
        supervisor.setEnabled(false)
        supervisor.setEnabled(true)
        try #require(launcher.last).exit(ProcessExit(status: 64, signaled: false))
        #expect(supervisor.state == .failed(reason: "Arguments de ptzd refusés"))
        scheduler.advance(by: 300)
        #expect(launcher.launched.count == 2)
        supervisor.setEnabled(false)
        supervisor.setEnabled(true)
        try #require(launcher.last).exit(ProcessExit(status: 75, signaled: true))
        #expect(supervisor.state == .restarting(count: 1))
    }

    @Test("Interrupteur rallumé pendant l'arrêt : ptzd repart à la fin de l'arrêt")
    func reenableDuringStop() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        let first = try #require(launcher.last)
        first.ignoresTerminate = true
        supervisor.setEnabled(false)
        supervisor.setEnabled(true)
        #expect(launcher.launched.count == 1)
        scheduler.advance(by: ServiceSupervisor.killDelay)
        #expect(first.kills == 1)
        #expect(launcher.launched.count == 2)
        #expect(supervisor.state == .running)
    }

    @Test("Arrêt pour quitter : jamais de relance, même interrupteur rallumé")
    func quitStop() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        let first = try #require(launcher.last)
        first.ignoresTerminate = true
        var done = false
        supervisor.stop(forQuit: true) { done = true }
        supervisor.setEnabled(true)
        scheduler.advance(by: ServiceSupervisor.killDelay)
        #expect(done)
        #expect(supervisor.state == .stopped)
        supervisor.start()
        #expect(launcher.launched.count == 1)
    }

    @Test("Fin d'un ancien processus après relance : ignorée")
    func staleExit() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        let first = try #require(launcher.last)
        first.exit()
        scheduler.advance(by: 1)
        #expect(supervisor.state == .running)
        first.exit()
        #expect(supervisor.state == .running)
    }
}

@MainActor
@Suite("Lanceur de processus réel")
struct FoundationProcessLauncherTests {
    @Test("Sortie ajoutée au journal ; fin signalée avec le code ; SIGKILL")
    func realProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ptzbot-launcher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "logs/ptzd.log")
        let launcher = FoundationProcessLauncher()
        for word in ["un", "deux"] {
            let exit = try await withCheckedThrowingContinuation { continuation in
                do {
                    _ = try launcher.launch(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo \(word); echo erreur >&2; exit 3"], outputURL: log) {
                        continuation.resume(returning: $0)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            #expect(exit == ProcessExit(status: 3, signaled: false))
        }
        #expect(try String(contentsOf: log, encoding: .utf8) == "un\nerreur\ndeux\nerreur\n")
        let handle = try FoundationProcessLauncher.appendingHandle(log)
        #expect(fcntl(handle.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(handle.fileDescriptor, F_GETFL) & O_APPEND != 0)
        try handle.close()

        var ended: ProcessExit?
        let sleeper = try launcher.launch(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], outputURL: log) { ended = $0 }
        #expect(sleeper.isRunning)
        sleeper.kill()
        for _ in 0..<100 where ended == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ended == ProcessExit(status: SIGKILL, signaled: true))
        #expect(!sleeper.isRunning)
    }
}
