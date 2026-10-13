import Foundation
import Synchronization
import Testing
@testable import PTZBotKit

/// Le texte de `launchctl print gui/<uid>/<label>` pour un service, tel que macOS 27 le donne : les lignes du service
/// ont une tabulation de retrait, les sous-blocs deux. Données fictives : aucun vrai chemin, aucun vrai PID.
enum LaunchdPrintFixtures {
    private static func text(_ lines: [String]) -> String {
        (["gui/501/\(LaunchdProcessLauncher.label) = {"] + lines + ["}"]).joined(separator: "\n") + "\n"
    }

    /// Le gardien tourne avec ce PID.
    static func running(_ pid: pid_t) -> String {
        text([
            "\tactive count = 1",
            "\tstate = running",
            "\tprogram = /Applications/PTZBot.app/Contents/Helpers/gardien",
            "\truns = 1",
            "\tpid = \(pid)",
            "\tlast exit code = (never exited)",
            "\t\tstate = active",
            "\tjob state = running",
        ])
    }

    /// Le gardien est sorti avec ce code (plus de ligne `pid`). `reason` : le libellé que les launchctl récents font suivre
    /// d'un code non nul (`127: Unknown error: 127`, `78: EX_CONFIG`).
    static func exited(code: Int32, reason: String? = nil) -> String {
        text([
            "\tstate = not running",
            "\tprogram = /Applications/PTZBot.app/Contents/Helpers/gardien",
            "\truns = 1",
            "\tlast exit code = \(code)" + (reason.map { ": \($0)" } ?? ""),
            "\t\tstate = active",
            "\tjob state = exited",
        ])
    }

    /// Le gardien est mort d'un signal (`Terminated: 15`, `Killed: 9`).
    static func signaled(_ name: String, _ number: Int32) -> String {
        text([
            "\tstate = not running",
            "\truns = 1",
            "\tlast exit code = (never exited)",
            "\tjob state = exited",
            "\tlast terminating signal = \(name): \(number)",
        ])
    }

    /// Chargé, pas encore lancé.
    static let waiting = text(["\tstate = waiting", "\truns = 0", "\tlast exit code = (never exited)", "\tjob state = waiting"])
}

@Suite("Lecture de launchctl print", .french)
struct LaunchctlPrintParserTests {
    @Test("PID : la ligne pid = N du service ; absente quand le processus ne tourne pas")
    func pid() {
        #expect(SystemLaunchctl.pid(fromPrint: LaunchdPrintFixtures.running(4242)) == 4242)
        #expect(SystemLaunchctl.pid(fromPrint: LaunchdPrintFixtures.exited(code: 0)) == nil)
        #expect(SystemLaunchctl.pid(fromPrint: LaunchdPrintFixtures.waiting) == nil)
        #expect(SystemLaunchctl.pid(fromPrint: "") == nil)
        #expect(SystemLaunchctl.pid(fromPrint: "\tpid = abc\n") == nil)
        #expect(SystemLaunchctl.pid(fromPrint: "\tpid = 0\n") == nil)
    }

    @Test("PID : les lignes des sous-blocs (deux tabulations ou plus) ne comptent pas")
    func pidIgnoresSubBlocks() {
        let text = "gui/501/a.b = {\n\tstate = waiting\n\tendpoints = {\n\t\tpid = 999\n\t}\n\t\t\tpid = 998\n}\n"
        #expect(SystemLaunchctl.pid(fromPrint: text) == nil)
        #expect(SystemLaunchctl.pid(fromPrint: text + "\tpid = 77\n") == 77)
    }

    @Test("Fin : le code de sortie, N")
    func exitCode() {
        #expect(SystemLaunchctl.lastExit(fromPrint: "\tlast exit code = 0\n") == ProcessExit(status: 0, signaled: false))
        #expect(SystemLaunchctl.lastExit(fromPrint: LaunchdPrintFixtures.exited(code: 3)) == ProcessExit(status: 3, signaled: false))
        #expect(SystemLaunchctl.lastExit(fromPrint: LaunchdPrintFixtures.exited(code: 127)) == ProcessExit(status: 127, signaled: false))
    }

    @Test("Fin : l'entier en tête du code, même suivi d'un libellé (127: …, 78: EX_CONFIG)")
    func exitCodeWithLabel() {
        #expect(SystemLaunchctl.lastExit(fromPrint: "\tlast exit code = 127: Unknown error: 127\n") == ProcessExit(status: 127, signaled: false))
        #expect(SystemLaunchctl.lastExit(fromPrint: "\tlast exit code = 78: EX_CONFIG\n") == ProcessExit(status: 78, signaled: false))
        #expect(SystemLaunchctl.lastExit(fromPrint: "\tlast exit code = 1: Operation not permitted\n") == ProcessExit(status: 1, signaled: false))
        #expect(SystemLaunchctl.lastExit(fromPrint: LaunchdPrintFixtures.exited(code: 127, reason: "Unknown error: 127"))
            == ProcessExit(status: 127, signaled: false))
        #expect(SystemLaunchctl.lastExit(fromPrint: LaunchdPrintFixtures.exited(code: 78, reason: "EX_CONFIG")) == ProcessExit(status: 78, signaled: false))
        // Le libellé est un texte libre : seul l'entier en tête compte.
        #expect(SystemLaunchctl.lastExit(fromPrint: "\tlast exit code = 3:12\n") == ProcessExit(status: 3, signaled: false))
    }

    @Test("Fin : le signal, nom et numéro")
    func terminatingSignal() {
        #expect(SystemLaunchctl.lastExit(fromPrint: "\tlast terminating signal = Terminated: 15\n") == ProcessExit(status: 15, signaled: true))
        #expect(SystemLaunchctl.lastExit(fromPrint: LaunchdPrintFixtures.signaled("Killed", 9)) == ProcessExit(status: 9, signaled: true))
    }

    @Test("Fin : jamais sorti, absente ou dans un sous-bloc : illisible")
    func unreadable() {
        #expect(SystemLaunchctl.lastExit(fromPrint: "\tlast exit code = (never exited)\n") == nil)
        #expect(SystemLaunchctl.lastExit(fromPrint: "\tlast exit code = : sans entier\n") == nil)
        #expect(SystemLaunchctl.lastExit(fromPrint: "\tlast exit code = EX_CONFIG\n") == nil)
        #expect(SystemLaunchctl.lastExit(fromPrint: LaunchdPrintFixtures.running(4242)) == nil)
        #expect(SystemLaunchctl.lastExit(fromPrint: LaunchdPrintFixtures.waiting) == nil)
        #expect(SystemLaunchctl.lastExit(fromPrint: "") == nil)
        #expect(SystemLaunchctl.lastExit(fromPrint: "\t\tlast exit code = 7\n\t\tlast terminating signal = Killed: 9\n") == nil)
        #expect(SystemLaunchctl.lastExit(fromPrint: "\tlast terminating signal = n'importe quoi\n") == nil)
    }

    @Test("Les deux lignes : le code passe avant le signal")
    func codeBeforeSignal() {
        let text = "\tlast exit code = 0\n\tlast terminating signal = Terminated: 15\n"
        #expect(SystemLaunchctl.lastExit(fromPrint: text) == ProcessExit(status: 0, signaled: false))
    }

    /// Jamais le vrai `launchctl` : un autre programme prend sa place, pour vérifier que la sortie est lue.
    @Test("printOutput lit la sortie du programme lancé ; un échec ou un programme absent : nil")
    func printOutput() {
        let echoed = SystemLaunchctl(executableURL: URL(fileURLWithPath: "/bin/echo")).printOutput(label: "a.b")
        #expect(echoed == "print gui/\(getuid())/a.b\n")
        #expect(SystemLaunchctl(executableURL: URL(fileURLWithPath: "/usr/bin/false")).printOutput(label: "a.b") == nil)
        #expect(SystemLaunchctl(executableURL: URL(fileURLWithPath: "/nonexistent/launchctl")).printOutput(label: "a.b") == nil)
    }

    /// Même principe : `/usr/bin/true` et `/usr/bin/false` tiennent la place de `launchctl`, pour la lecture du code de
    /// sortie sans boucle d'exécution (attente par sémaphore).
    @Test("isLoaded et bootout lisent le code de sortie du programme lancé")
    func exitStatus() {
        let succeeding = SystemLaunchctl(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        let failing = SystemLaunchctl(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let missing = SystemLaunchctl(executableURL: URL(fileURLWithPath: "/nonexistent/launchctl"))
        #expect(succeeding.isLoaded(label: "a.b"))
        #expect(!failing.isLoaded(label: "a.b"))
        #expect(!missing.isLoaded(label: "a.b"))
        #expect((try? succeeding.bootout(label: "a.b")) != nil)
        #expect(throws: SystemLaunchctl.Failure.self) { try failing.bootout(label: "a.b") }
        #expect(throws: SystemLaunchctl.Failure.self) { try missing.bootout(label: "a.b") }
    }
}

/// Horloge simulée : `sleep` fait avancer le temps sans attendre.
final class LaunchdClock: Sendable {
    private let time = Mutex<TimeInterval>(0)

    var now: TimeInterval {
        time.withLock { $0 }
    }

    func sleep(_ delay: TimeInterval) {
        time.withLock { $0 += delay }
    }
}

/// Un vrai petit processus (`/bin/sleep 30`) dont le PID joue celui du gardien.
@MainActor
final class SleepingProcess {
    private let process = Process()

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var pid: pid_t {
        process.processIdentifier
    }

    /// Ne laisse jamais un `sleep` derrière le test.
    func stop() {
        if process.isRunning {
            process.terminate()
        }
    }
}

@MainActor
@Suite("Lancement de go2rtc par launchd", .french, .timeLimit(.minutes(1)))
final class LaunchdProcessLauncherTests {
    let root: URL
    let support: URL
    let outputURL: URL
    let launchctl = FakeLaunchctl()
    let clock = LaunchdClock()
    let queue = DispatchQueue(label: "io.github.djoko-cli.ptzbot.tests.launchd")
    private(set) var exits: [ProcessExit] = []
    private var sleepers: [SleepingProcess] = []

    let gardien = URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/gardien")
    let arguments = ["--parent", "4242", "--arret", "10", "--", "/Applications/PTZBot.app/Contents/Helpers/go2rtc", "-config", "/support/go2rtc.yaml"]
    let environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]

    init() throws {
        root = try Go2RTCFixtures.directory()
        support = root.appending(path: "support")
        outputURL = root.appending(path: "logs/obsbot-nacelle/go2rtc.log")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var plistURL: URL {
        support.appending(path: "go2rtc-launchd.plist")
    }

    var plistExists: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    var calls: [String] {
        launchctl.state.withLock { $0.calls }
    }

    private func makeLauncher() -> LaunchdProcessLauncher {
        let clock = clock
        return LaunchdProcessLauncher(
            supportDirectory: support,
            launchctl: launchctl,
            now: { clock.now },
            sleep: { clock.sleep($0) },
            queue: queue
        )
    }

    /// Un `sleep 30` qui joue le gardien, arrêté à la fin du test quoi qu'il arrive.
    private func startSleeper() throws -> SleepingProcess {
        let sleeper = try SleepingProcess()
        sleepers.append(sleeper)
        return sleeper
    }

    private func respond(_ responses: [String?]) {
        launchctl.state.withLock { $0.printResponses = responses }
    }

    private func launch(environment: [String: String]? = nil) throws -> any LaunchedProcess {
        try makeLauncher().launch(
            executableURL: gardien,
            arguments: arguments,
            environment: environment ?? self.environment,
            outputURL: outputURL
        ) { [self] exit in
            exits.append(exit)
        }
    }

    /// Attente bornée : la condition vraie, ou faux après `timeout` secondes.
    private func eventually(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Les travaux de fond en attente sont finis.
    private func drain() {
        queue.sync {}
    }

    /// Arrête les `sleep` lancés par le test (un lancement chacun), attend leurs sorties signalées et la fin des
    /// nettoyages de fond.
    private func cleanUp() async {
        sleepers.forEach { $0.stop() }
        #expect(await eventually { exits.count == sleepers.count })
        drain()
    }

    // MARK: - La plist

    @Test("La plist de travail : clés et valeurs exactes, XML, 0600, à côté du yaml, aucune KeepAlive")
    func plistContents() async throws {
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.signaled("Terminated", 15)])
        let process = try launch()
        defer { sleepers.forEach { $0.stop() } }

        #expect(plistURL == support.appending(path: "go2rtc-launchd.plist"))
        #expect(plistExists)
        let data = try Data(contentsOf: plistURL)
        #expect(String(decoding: data.prefix(5), as: UTF8.self) == "<?xml")
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary)
        let expected: NSDictionary = [
            "Label": "io.github.djoko-cli.obsbot-nacelle.go2rtc",
            "ProgramArguments": [gardien.path] + arguments,
            "EnvironmentVariables": environment,
            "StandardOutPath": outputURL.path,
            "StandardErrorPath": outputURL.path,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "ExitTimeOut": 20,
            "AbandonProcessGroup": true,
        ]
        #expect(plist == expected)
        #expect(plist["KeepAlive"] == nil)
        #expect(LaunchdProcessLauncher.label == "io.github.djoko-cli.obsbot-nacelle.go2rtc")
        #expect(try Go2RTCFixtures.permissions(plistURL) == 0o600)
        // Le dossier du journal est créé au besoin.
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: outputURL.deletingLastPathComponent().path, isDirectory: &isDirectory) && isDirectory.boolValue)

        sleeper.stop()
        #expect(await eventually { !process.isRunning })
        #expect(await eventually { exits.count == 1 })
        drain()
    }

    @Test("Sans variable d'environnement, la plist n'a pas de clé EnvironmentVariables")
    func plistWithoutEnvironment() async throws {
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.signaled("Terminated", 15)])
        _ = try launch(environment: [:])
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary)
        #expect(plist["EnvironmentVariables"] == nil)
        #expect(plist["KeepAlive"] == nil)
        #expect(plist.count == 8)
        await cleanUp()
    }

    // MARK: - L'ordre des appels

    @Test("Label absent : enable puis bootstrap, la plist déjà écrite")
    func bootstrapOnly() async throws {
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.signaled("Terminated", 15)])
        _ = try launch()
        #expect(calls == ["enable", "bootstrap"])
        #expect(launchctl.state.withLock { $0.enabledLabels } == [LaunchdProcessLauncher.label])
        #expect(launchctl.state.withLock { $0.plistPresentAtBootstrap } == [true])
        #expect(launchctl.state.withLock { $0.labels }.isEmpty)
        await cleanUp()
    }

    @Test("Label déjà chargé (travail d'une session précédente) : bootout, attente du déchargement, enable, puis bootstrap")
    func bootoutThenBootstrap() async throws {
        launchctl.state.withLock {
            $0.loaded = true
            $0.pollsBeforeUnload = 2
        }
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.signaled("Terminated", 15)])
        _ = try launch()
        #expect(calls == ["bootout", "enable", "bootstrap"])
        #expect(launchctl.state.withLock { $0.labels } == [LaunchdProcessLauncher.label])
        // Deux sondages de plus avant le déchargement : 2 × 0,25 s d'attente (simulée).
        #expect(clock.now == 0.5)
        await cleanUp()
    }

    @Test("Travail d'une session précédente qui ne se décharge pas : erreur, pas de bootstrap, plist retirée")
    func stillLoaded() async throws {
        launchctl.state.withLock {
            $0.loaded = true
            $0.pollsBeforeUnload = 1000
        }
        #expect(throws: LaunchdLaunchError.stillLoaded) { try launch() }
        #expect(calls == ["bootout"])
        // 20 s d'attente simulée (le `ExitTimeOut` de la plist), jamais réelle.
        #expect(LaunchdProcessLauncher.stopTimeout == 20)
        #expect(clock.now >= LaunchdProcessLauncher.stopTimeout)
        drain()
        #expect(!plistExists)
        #expect(exits.isEmpty)
    }

    @Test("bootout en échec, travail toujours chargé au bout des 20 s : erreur, pas de bootstrap")
    func bootoutFails() {
        launchctl.state.withLock {
            $0.loaded = true
            $0.bootoutFails = true
        }
        #expect(throws: LaunchdLaunchError.bootoutFailed("code 5")) { try launch() }
        #expect(calls == ["bootout"])
        // L'erreur ne part pas tout de suite : launchd peut démonter le travail malgré le code d'erreur.
        #expect(clock.now >= LaunchdProcessLauncher.stopTimeout)
        drain()
        #expect(!plistExists)
    }

    @Test("bootout en échec (« Operation now in progress »), travail déchargé un peu plus tard : le lancement réussit")
    func bootoutFailsThenUnloads() async throws {
        launchctl.state.withLock {
            $0.loaded = true
            $0.bootoutFails = true
            $0.unloadsDespiteFailure = true
            $0.pollsBeforeUnload = 8
        }
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.signaled("Terminated", 15)])
        let process = try launch()
        #expect(process.pid == sleeper.pid)
        #expect(calls == ["bootout", "enable", "bootstrap"])
        // Huit sondages de plus avant le déchargement : 8 × 0,25 s d'attente (simulée), bien moins que le délai.
        #expect(clock.now == 2)
        await cleanUp()
    }

    @Test("bootout en échec, travail déjà déchargé : aucune attente, le lancement réussit")
    func bootoutFailsAlreadyUnloaded() async throws {
        launchctl.state.withLock {
            $0.loaded = true
            $0.bootoutFails = true
            $0.unloadsDespiteFailure = true
        }
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.signaled("Terminated", 15)])
        _ = try launch()
        #expect(calls == ["bootout", "enable", "bootstrap"])
        #expect(clock.now == 0)
        await cleanUp()
    }

    @Test("Travail désactivé dans launchd (l'utilisateur l'a coupé dans Ouverture) : enable avant bootstrap, le lancement réussit")
    func disabledJobIsEnabled() async throws {
        launchctl.state.withLock { $0.disabled = true }
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.signaled("Terminated", 15)])
        _ = try launch()
        #expect(calls == ["enable", "bootstrap"])
        #expect(launchctl.state.withLock { $0.loaded && !$0.disabled })
        await cleanUp()
    }

    @Test("enable en échec : sans effet sur le lancement, le bootstrap est tenté quand même")
    func enableFailureIsIgnored() async throws {
        launchctl.state.withLock { $0.enableFails = true }
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.signaled("Terminated", 15)])
        let process = try launch()
        #expect(process.pid == sleeper.pid)
        #expect(calls == ["enable", "bootstrap"])
        await cleanUp()
    }

    @Test("bootstrap en échec : l'erreur est rendue, la plist retirée, aucune sortie signalée")
    func bootstrapFails() async {
        launchctl.state.withLock { $0.bootstrapFails = true }
        #expect(throws: FakeLaunchctl.Failure.self) { try launch() }
        #expect(calls == ["enable", "bootstrap"])
        drain()
        #expect(!plistExists)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(exits.isEmpty)
    }

    // MARK: - Le PID du gardien

    @Test("PID présent tout de suite : un seul sondage, aucune attente")
    func pidImmediately() async throws {
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.signaled("Terminated", 15)])
        let process = try launch()
        #expect(process.pid == sleeper.pid)
        #expect(process.isRunning)
        #expect(launchctl.state.withLock { $0.printCalls } == 1)
        #expect(clock.now == 0)
        await cleanUp()
    }

    @Test("PID présent après quelques essais : un sondage toutes les 50 ms")
    func pidAfterSeveralAttempts() async throws {
        let sleeper = try startSleeper()
        respond([nil, LaunchdPrintFixtures.waiting, LaunchdPrintFixtures.waiting, LaunchdPrintFixtures.running(sleeper.pid),
                 LaunchdPrintFixtures.signaled("Terminated", 15)])
        let process = try launch()
        #expect(process.pid == sleeper.pid)
        #expect(launchctl.state.withLock { $0.printCalls } == 4)
        #expect(abs(clock.now - 0.15) < 1e-9)
        #expect(calls == ["enable", "bootstrap"])
        await cleanUp()
    }

    @Test("PID jamais présent en 2 s : bootout, plist retirée, erreur, aucune sortie signalée")
    func pidNeverAppears() async {
        respond([LaunchdPrintFixtures.waiting])
        #expect(throws: LaunchdLaunchError.noPID) { try launch() }
        // Un sondage toutes les 50 ms pendant 2 s (une attente simulée de plus ou de moins selon l'arrondi des flottants).
        #expect(clock.now >= LaunchdProcessLauncher.pidTimeout && clock.now < LaunchdProcessLauncher.pidTimeout + 0.1)
        #expect((40...42).contains(launchctl.state.withLock { $0.printCalls }))
        drain()
        #expect(calls == ["enable", "bootstrap", "bootout"])
        #expect(!plistExists)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(exits.isEmpty)
    }

    @Test("Gardien sorti avant le premier sondage (go2rtc manquant) : processus rendu à l'arrêt, sortie 127 signalée une fois, après le retour")
    func exitedBeforeFirstProbe() async throws {
        respond([LaunchdPrintFixtures.exited(code: 127)])
        let process = try launch()
        #expect(!process.isRunning)
        // Pas de PID à signaler : aucun signal ne part sur ce numéro.
        process.terminate()
        process.kill()
        #expect(exits.isEmpty)
        #expect(await eventually { exits.count == 1 })
        #expect(exits == [ProcessExit(status: 127, signaled: false)])
        #expect(!plistExists)
        #expect(calls == ["enable", "bootstrap", "bootout"])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(exits.count == 1)
    }

    @Test("Gardien sorti avant le premier sondage, code suivi d'un libellé (127: …) : sortie 127, go2rtc manquant")
    func exitedBeforeFirstProbeWithLabel() async throws {
        respond([LaunchdPrintFixtures.exited(code: 127, reason: "Unknown error: 127")])
        let process = try launch()
        #expect(!process.isRunning)
        #expect(await eventually { exits.count == 1 })
        #expect(exits == [ProcessExit(status: Go2RTCSupervisor.missingBinaryStatus, signaled: false)])
        drain()
    }

    // MARK: - La sortie

    @Test("terminate() : SIGTERM au vrai processus ; onExit une fois, avec le signal lu dans launchctl print ; bootout et plist retirée")
    func terminateReportsExitOnce() async throws {
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.signaled("Terminated", 15)])
        let process = try launch()
        #expect(process.isRunning)
        #expect(plistExists)
        process.terminate()
        #expect(await eventually { exits.count == 1 })
        #expect(exits == [ProcessExit(status: 15, signaled: true)])
        #expect(!process.isRunning)
        // La plist est retirée et le travail déchargé avant que onExit soit appelé.
        #expect(!plistExists)
        #expect(calls == ["enable", "bootstrap", "bootout"])
        // Après la sortie : ni signal ni seconde sortie.
        process.terminate()
        process.kill()
        try await Task.sleep(for: .milliseconds(100))
        #expect(exits.count == 1)
        drain()
    }

    @Test("kill() : SIGKILL ; la fin lue est le signal 9")
    func killReportsSignal() async throws {
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.signaled("Killed", 9)])
        let process = try launch()
        process.kill()
        #expect(await eventually { exits.count == 1 })
        #expect(exits == [ProcessExit(status: 9, signaled: true)])
        drain()
    }

    @Test("Code de sortie lu : le code rendu par le gardien (go2rtc manquant : 127) n'est pas signalé comme un signal")
    func exitCodeIsReported() async throws {
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.exited(code: 127)])
        let process = try launch()
        process.terminate()
        #expect(await eventually { exits.count == 1 })
        #expect(exits == [ProcessExit(status: Go2RTCSupervisor.missingBinaryStatus, signaled: false)])
        drain()
    }

    @Test("Code de sortie suivi d'un libellé (127: …), gardien vu en marche : 127 reconnu, pas un arrêt par signal inconnu")
    func exitCodeWithLabelIsReported() async throws {
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.exited(code: 127, reason: "Unknown error: 127")])
        let process = try launch()
        process.terminate()
        #expect(await eventually { exits.count == 1 })
        #expect(exits == [ProcessExit(status: Go2RTCSupervisor.missingBinaryStatus, signaled: false)])
        drain()
    }

    @Test("launchd n'a pas encore enregistré la fin (le PID est encore montré) : la lecture est reprise")
    func exitReadIsRetried() async throws {
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.running(sleeper.pid),
                 LaunchdPrintFixtures.waiting, LaunchdPrintFixtures.exited(code: 3)])
        let process = try launch()
        process.terminate()
        #expect(await eventually { exits.count == 1 })
        #expect(exits == [ProcessExit(status: 3, signaled: false)])
        drain()
    }

    @Test("Code illisible : status -1, signaled")
    func unreadableExit() async throws {
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), LaunchdPrintFixtures.waiting])
        let process = try launch()
        process.terminate()
        #expect(await eventually { exits.count == 1 })
        #expect(exits == [ProcessExit(status: -1, signaled: true)])
        drain()
    }

    @Test("Travail disparu de launchd pendant la lecture : status -1, signaled")
    func jobVanished() async throws {
        let sleeper = try startSleeper()
        respond([LaunchdPrintFixtures.running(sleeper.pid), nil])
        let process = try launch()
        process.terminate()
        #expect(await eventually { exits.count == 1 })
        #expect(exits == [ProcessExit(status: -1, signaled: true)])
        drain()
    }

    @Test("Processus déjà mort au moment d'armer la source : la sortie est traitée tout de suite, une seule fois")
    func alreadyDeadWhenArming() async throws {
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try dead.run()
        let pid = dead.processIdentifier
        dead.waitUntilExit()
        // Le processus doit être parti pour de bon (reçu et enterré) : bornée, jamais sans fin.
        var gone = false
        for _ in 0..<400 {
            if Darwin.kill(pid, 0) != 0, errno == ESRCH {
                gone = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(gone)

        respond([LaunchdPrintFixtures.running(pid), LaunchdPrintFixtures.exited(code: 3)])
        let process = try launch()
        #expect(!process.isRunning)
        #expect(await eventually { exits.count == 1 })
        #expect(exits == [ProcessExit(status: 3, signaled: false)])
        #expect(!plistExists)
        // Aucun signal sur un PID qui n'est plus le nôtre.
        process.terminate()
        process.kill()
        try await Task.sleep(for: .milliseconds(100))
        #expect(exits.count == 1)
        drain()
    }

    @Test("Après une sortie, un nouveau lancement réécrit la plist et se charge de nouveau")
    func relaunchAfterExit() async throws {
        let first = try startSleeper()
        respond([LaunchdPrintFixtures.running(first.pid), LaunchdPrintFixtures.signaled("Terminated", 15)])
        let firstProcess = try launch()
        firstProcess.terminate()
        #expect(await eventually { exits.count == 1 })
        #expect(!plistExists)

        let second = try startSleeper()
        launchctl.state.withLock { $0.printCalls = 0 }
        respond([LaunchdPrintFixtures.running(second.pid), LaunchdPrintFixtures.signaled("Terminated", 15)])
        let secondProcess = try launch()
        #expect(secondProcess.pid == second.pid)
        #expect(plistExists)
        #expect(calls == ["enable", "bootstrap", "bootout", "enable", "bootstrap"])
        secondProcess.terminate()
        #expect(await eventually { exits.count == 2 })
        #expect(!plistExists)
        drain()
    }

    // MARK: - Au lancement de l'app

    @Test("Travail orphelin au lancement de l'app, go2rtc éteint : bootout en fond et plist retirée")
    func removeLeftover() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: plistURL)
        LaunchdProcessLauncher.removeLeftoverInBackground(supportDirectory: support, launchctl: launchctl, queue: queue)
        drain()
        #expect(calls == ["bootout"])
        #expect(launchctl.state.withLock { $0.labels } == [LaunchdProcessLauncher.label])
        #expect(!plistExists)
    }

    @Test("Aucun travail orphelin : le bootout en échec ne dit rien")
    func removeLeftoverSilently() {
        launchctl.state.withLock {
            $0.loaded = true
            $0.bootoutFails = true
        }
        LaunchdProcessLauncher.removeLeftoverInBackground(supportDirectory: support, launchctl: launchctl, queue: queue)
        drain()
        #expect(calls == ["bootout"])
    }

    // MARK: - Les erreurs

    @Test("Messages des erreurs, en français et en anglais")
    func errorTexts() {
        #expect(LaunchdLaunchError.noPID.errorDescription == "launchd n'a pas lancé le gardien de go2rtc.")
        #expect(LaunchdLaunchError.stillLoaded.errorDescription == "Le gardien de go2rtc d'une session précédente ne s'est pas arrêté à temps.")
        #expect(LaunchdLaunchError.bootoutFailed("code 5").errorDescription
            == "Le gardien de go2rtc d'une session précédente n'a pas pu être arrêté : code 5")
        Localization.$languageOverride.withValue("en") {
            #expect(LaunchdLaunchError.noPID.errorDescription == "launchd did not start the go2rtc guardian.")
            #expect(LaunchdLaunchError.bootoutFailed("code 5").errorDescription
                == "The go2rtc guardian from a previous session could not be stopped: code 5")
        }
    }
}
