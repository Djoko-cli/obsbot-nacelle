import Foundation
import Network
import Testing
@testable import PTZBotKit

@MainActor
@Suite("Lancement et arrêt de l'app")
struct AppControllerTests {
    let root: URL
    let paths: AppPaths
    let launcher = FakeLauncher()
    let scheduler = FakeScheduler()
    let launchctl = FakeLaunchctl()
    let supervisor: ServiceSupervisor

    init() throws {
        root = try FakeSDK.directory()
        paths = AppPaths(bundle: root.appending(path: "PTZBot.app"), home: root)
        supervisor = ServiceSupervisor(paths: paths.service, launcher: launcher, settings: FakeSettings(), scheduler: scheduler, parentPID: 4242)
    }

    private func controller(
        addresses: [String] = ["127.0.0.1"],
        sdkLoads: Bool = true,
        confirm: Bool = true,
        asked: Counter = Counter(),
        answers: Answers? = nil
    ) -> AppController {
        AppController(
            supervisor: supervisor,
            legacyAgent: LegacyAgent(
                launchAgentsDirectory: root.appending(path: "LaunchAgents"),
                supportDirectory: paths.support,
                launchctl: launchctl,
                trash: FakeTrash(directory: root.appending(path: "Trash")),
                sleep: { _ in }
            ),
            configURL: paths.config,
            interfaces: FakeInterfaces(addresses: addresses),
            sdkInstaller: SDKInstaller(sdkDirectory: paths.sdkDirectory, verifier: FakeVerifier(sdkLoads).verifier),
            scheduler: scheduler,
            confirmMigration: {
                asked.value += 1
                return answers?.next() ?? confirm
            }
        )
    }

    /// L'installation actuelle : agent chargé, plist, SDK dans lib/.
    private func installLegacy() throws {
        try FakeSDK.write(Data("<plist/>".utf8), to: root.appending(path: "LaunchAgents/\(LegacyAgent.label).plist"))
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: paths.support.appending(path: "lib/libdev.dylib"))
        try FakeSDK.write(Data(#"{"listenAddress":"100.64.0.1"}"#.utf8), to: paths.config)
        launchctl.state.withLock { $0.loaded = true }
    }

    @Test("Mac neuf : config.json créé, ptzd lancé, SDK absent, Tailscale signalé manquant")
    func freshMac() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = Counter()
        let app = controller(asked: asked)
        var configReady = 0
        app.onConfigReady = { configReady += 1 }
        await app.launch()
        #expect(asked.value == 0)
        #expect(app.legacy == .none)
        #expect(FileManager.default.fileExists(atPath: paths.config.path))
        #expect(app.tailscaleMissing)
        #expect(configReady == 1)
        #expect(supervisor.state == .running)
        #expect(launcher.executables == [paths.ptzd])
        #expect(try #require(launcher.last).arguments == ["--parent", "4242", "--ai", paths.obsbotAI.path, "--sdk", paths.sdkDirectory.path])
        #expect(app.sdkStatus == .absent)
        await app.launch()
        #expect(launcher.launched.count == 1)
    }

    @Test("Interface Tailscale : pas de message")
    func tailscale() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller(addresses: ["127.0.0.1", "100.64.0.1"])
        await app.launch()
        #expect(!app.tailscaleMissing)
    }

    @Test("config.json existant sur 127.0.0.1 : Tailscale signalé manquant, fichier inchangé")
    func existingLoopback() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let json = Data(#"{"listenAddress":"127.0.0.1","port":19870}"#.utf8)
        try FakeSDK.write(json, to: paths.config)
        let app = controller(addresses: ["100.64.0.1"])
        await app.launch()
        #expect(app.tailscaleMissing)
        #expect(try Data(contentsOf: paths.config) == json)
        #expect(!ConfigBootstrap.listensOnLoopbackOnly(configURL: root.appending(path: "absent.json")))
    }

    @Test("Ancienne installation, « Remplacer » : migration, puis ptzd de l'app ; SDK repris et prêt")
    func replace() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        let asked = Counter()
        let app = controller(asked: asked)
        await app.launch()
        #expect(asked.value == 1)
        #expect(app.legacy == .none)
        #expect(app.migrationError == nil)
        #expect(!supervisor.legacyAgentActive)
        #expect(supervisor.state == .running)
        #expect(app.sdkStatus == .ready)
        #expect(FileManager.default.fileExists(atPath: paths.sdkDirectory.appending(path: "libdev.dylib").path))
        #expect(!app.tailscaleMissing)
    }

    @Test("Ancienne installation, « Plus tard » : aucun ptzd lancé, ancienne installation gardée")
    func later() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        let app = controller(confirm: false)
        await app.launch()
        #expect(app.legacy == .kept)
        #expect(supervisor.legacyAgentActive)
        supervisor.start()
        #expect(launcher.launched.isEmpty)
        #expect(supervisor.state == .stopped)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "LaunchAgents/\(LegacyAgent.label).plist").path))
    }

    @Test("« Plus tard », puis « Remplacer l'ancienne installation… » : même alerte, puis migration et ptzd")
    func replaceLater() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        let asked = Counter()
        let answers = Answers([false, false, true])
        let app = controller(asked: asked, answers: answers)
        await app.launch()
        #expect(app.canReplaceLegacy)
        await app.offerMigration()
        #expect(asked.value == 2)
        #expect(app.legacy == .kept)
        #expect(launcher.launched.isEmpty)
        await app.offerMigration()
        #expect(asked.value == 3)
        #expect(app.legacy == .none)
        #expect(!app.canReplaceLegacy)
        #expect(supervisor.state == .running)
        #expect(app.sdkStatus == .ready)
        await app.offerMigration()
        #expect(asked.value == 3)
    }

    @Test("bootout en échec puis réussi : le bouton relance la migration")
    func retryAfterFailure() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        launchctl.state.withLock { $0.bootoutFails = true }
        let app = controller()
        await app.launch()
        #expect(app.migrationError != nil)
        #expect(app.canReplaceLegacy)
        launchctl.state.withLock { $0.bootoutFails = false }
        await app.offerMigration()
        #expect(app.migrationError == nil)
        #expect(app.legacy == .none)
        #expect(launcher.launched.count == 1)
    }

    @Test("Échec du bootout : message, ancienne installation gardée, aucun ptzd")
    func migrationFailure() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        launchctl.state.withLock { $0.bootoutFails = true }
        let app = controller()
        await app.launch()
        #expect(app.legacy == .kept)
        #expect(app.migrationError == "L'ancienne installation n'a pas pu être arrêtée : code 5")
        #expect(launcher.launched.isEmpty)
    }

    @Test("ptzd sort avec 75 : « Le port <port de config.json> est déjà pris… », sans relance")
    func portBusy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FakeSDK.write(Data(#"{"listenAddress":"127.0.0.1","port":19870}"#.utf8), to: paths.config)
        let app = controller()
        await app.launch()
        try #require(launcher.last).exit(ProcessExit(status: 75, signaled: false))
        #expect(supervisor.state == .failed(reason: "Le port 19870 est déjà pris : un autre ptzd tourne peut-être encore"))
        #expect(Labels.service(supervisor.state, connection: .unreachable, legacy: false) == "Arrêté")
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
    }

    @Test("« Quitter » : interrupteur rallumé ensuite, ptzd n'est pas relancé")
    func quitIsFinal() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        await app.launch()
        try #require(launcher.last).ignoresTerminate = true
        var done = 0
        app.quit { done += 1 }
        supervisor.setEnabled(true)
        scheduler.advance(by: ServiceSupervisor.killDelay)
        #expect(done == 1)
        #expect(launcher.launched.count == 1)
    }

    @Test("« Quitter » : ptzd arrêté, puis completion une seule fois")
    func quit() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        await app.launch()
        var done = 0
        app.quit { done += 1 }
        #expect(try #require(launcher.last).terminations == 1)
        #expect(done == 1)
        scheduler.advance(by: AppController.quitTimeout)
        #expect(done == 1)
    }

    @Test("« Quitter » avec un ptzd dont la fin n'arrive jamais : completion au délai de sécurité, une seule fois")
    func quitTimeout() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        await app.launch()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        process.ignoresKill = true
        var done = 0
        app.quit { done += 1 }
        scheduler.advance(by: AppController.quitTimeout - 0.1)
        #expect(process.kills == 1)
        #expect(done == 0)
        scheduler.advance(by: 0.1)
        #expect(done == 1)
        scheduler.advance(by: 60)
        #expect(done == 1)
    }

    @Test("« Quitter » avec un ptzd bloqué : SIGKILL à 5 s, completion aussitôt après")
    func quitStubborn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        await app.launch()
        try #require(launcher.last).ignoresTerminate = true
        var done = 0
        app.quit { done += 1 }
        scheduler.advance(by: ServiceSupervisor.killDelay - 0.1)
        #expect(done == 0)
        scheduler.advance(by: 0.1)
        #expect(done == 1)
        #expect(try #require(launcher.last).kills == 1)
    }
}

/// Réponses successives à l'alerte de migration.
@MainActor
final class Answers {
    private var queue: [Bool]

    init(_ queue: [Bool]) {
        self.queue = queue
    }

    func next() -> Bool? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
}

/// Compteur partagé avec une fermeture.
@MainActor
final class Counter {
    var value = 0
}

@MainActor
@Suite("Fenêtre « SDK OBSBOT »")
struct SDKWindowModelTests {
    @Test("Choix refusé : motif ; choix accepté puis autorisé : installé, dossier d'extraction effacé")
    func flow() async throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = SDKInstaller(sdkDirectory: directory.appending(path: "sdk"), verifier: FakeVerifier(true).verifier)
        let model = SDKWindowModel(installer: installer)
        var installed = 0
        model.onInstalled = { installed += 1 }

        let text = try FakeSDK.write(Data("texte".utf8), to: directory.appending(path: "texte.dylib"))
        await model.choose(text)
        #expect(model.phase == .rejected("Ce fichier n'est pas une bibliothèque Mach-O."))

        let library = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "choix/libdev.dylib"))
        FakeSDK.setQuarantine(library)
        await model.choose(library)
        guard case let .candidate(candidate) = model.phase else {
            Issue.record("candidat attendu")
            return
        }
        #expect(candidate.quarantined)
        await model.authorize()
        #expect(model.phase == .installed)
        #expect(installed == 1)
        #expect(!FakeSDK.isQuarantined(installer.libraryURL))
        #expect(FakeSDK.isQuarantined(library))
        model.reset()
        #expect(model.phase == .choosing)
    }

    @Test("Fenêtre fermée pendant l'examen : dossier d'extraction effacé, choix oublié")
    func closedDuringInspection() async throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let extraction = directory.appending(path: "extraction")
        let library = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: extraction.appending(path: "macos/arm64-release/libdev.dylib"))
        let model = SDKWindowModel(
            installer: SDKInstaller(sdkDirectory: directory.appending(path: "sdk"), verifier: FakeVerifier(true).verifier),
            inspect: { _ throws(SDKRejection) in
                Thread.sleep(forTimeInterval: 0.2)
                return SDKCandidate(path: library, architectures: ["arm64"], temporaryDirectory: extraction)
            }
        )
        let choice = Task { await model.choose(URL(fileURLWithPath: "/archive.zip")) }
        while model.phase != .inspecting {
            await Task.yield()
        }
        model.reset()
        await choice.value
        #expect(model.phase == .choosing)
        #expect(!FileManager.default.fileExists(atPath: extraction.path))
    }

    @Test("Vérification en échec : message, rien n'est installé")
    func failure() async throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = SDKInstaller(sdkDirectory: directory.appending(path: "sdk"), verifier: FakeVerifier(false).verifier)
        let model = SDKWindowModel(installer: installer)
        await model.choose(try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "libdev.dylib")))
        await model.authorize()
        #expect(model.phase == .failed(SDKInstallError.unloadable.message))
        #expect(!FileManager.default.fileExists(atPath: installer.libraryURL.path))
    }
}

@Suite("Textes du service et du SDK")
struct ServiceLabelsTests {
    @Test("État du service : supervision, puis connexion de confiance ; ancienne installation")
    func service() {
        #expect(Labels.service(.running, connection: .active, legacy: false) == "Actif")
        #expect(Labels.service(.running, connection: .connecting, legacy: false) == "Démarrage…")
        #expect(Labels.service(.running, connection: .unreachable, legacy: false) == "Ne répond pas")
        #expect(Labels.service(.starting, connection: .unreachable, legacy: false) == "Démarrage…")
        #expect(Labels.service(.stopped, connection: .unreachable, legacy: false) == "Arrêté")
        #expect(Labels.service(.failed(reason: "x"), connection: .unreachable, legacy: false) == "Arrêté")
        #expect(Labels.service(.restarting(count: 3), connection: .unreachable, legacy: false) == "Relancé après un arrêt inattendu (3)")
        #expect(Labels.service(.stopped, connection: .active, legacy: true) == "Ancienne installation")
    }

    @Test("Commandes grisées sauf service actif et connecté ; journal en cas d'échec ou sans réponse")
    func availability() {
        #expect(Labels.controlsEnabled(.running, connection: .active, legacy: false))
        #expect(!Labels.controlsEnabled(.running, connection: .unreachable, legacy: false))
        #expect(!Labels.controlsEnabled(.stopped, connection: .active, legacy: false))
        #expect(!Labels.controlsEnabled(.failed(reason: "x"), connection: .active, legacy: false))
        #expect(Labels.controlsEnabled(.stopped, connection: .active, legacy: true))
        #expect(Labels.showsLog(.failed(reason: "x"), connection: .unreachable))
        #expect(Labels.showsLog(.running, connection: .unreachable))
        #expect(!Labels.showsLog(.running, connection: .active))
        #expect(!Labels.showsLog(.stopped, connection: .unreachable))
    }

    @Test("SDK : états, suivi IA grisé tant qu'il n'est pas prêt (sauf ancienne installation)")
    func sdk() {
        #expect(Labels.sdk(.ready) == "Prêt")
        #expect(Labels.sdk(.absent) == "Absent")
        #expect(Labels.sdk(.quarantined) == "En quarantaine")
        #expect(Labels.sdk(.incompatible) == "Incompatible")
        #expect(Labels.sdk(.unloadable) == "Ne se charge pas")
        #expect(Labels.sdk(nil) == "Vérification…")
        #expect(Labels.aiNeedsSDK(.absent, legacy: false))
        #expect(Labels.aiNeedsSDK(nil, legacy: false))
        #expect(!Labels.aiNeedsSDK(.ready, legacy: false))
        #expect(!Labels.aiNeedsSDK(.absent, legacy: true))
        #expect(Labels.sdkRequired == "SDK OBSBOT requis")
        #expect(Labels.sdkAction(.ready) == "Changer…")
        #expect(Labels.sdkAction(.absent) == "Installer le SDK…")
        #expect(Labels.sdkAction(.quarantined) == "Installer le SDK…")
        #expect(Labels.sdkAction(nil) == nil)
        #expect(Labels.replaceLegacy == "Remplacer l'ancienne installation…")
    }

    @Test("Sections du panneau : Service, Caméra avec son état, iPhone connectés, note du suivi IA")
    func sections() {
        #expect(Labels.serviceSection == "Service")
        #expect(Labels.cameraSection(.connected) == "Caméra · branchée")
        #expect(Labels.cameraSection(.absent) == "Caméra · débranchée")
        #expect(Labels.cameraSection(nil) == "Caméra · débranchée")
        #expect(Labels.iPhoneSection(count: 0) == "iPhone connectés · 0")
        #expect(Labels.noIPhone == "Aucun iPhone connecté")
        #expect(Labels.aiNote(.unknown, needsSDK: true) == "SDK OBSBOT requis")
        #expect(Labels.aiNote(.unknown, needsSDK: false) == "État inconnu")
        #expect(Labels.aiNote(.on, needsSDK: false) == nil)
        #expect(Labels.aiNote(nil, needsSDK: false) == nil)
    }

    @Test("Textes exacts de la spec : alerte de migration, confirmation du SDK")
    func specTexts() {
        #expect(Labels.migrationMessage == "Une ancienne installation de ptzd tourne en arrière-plan. PTZBot va la remplacer : le service sera désormais actif seulement quand PTZBot est ouvert. Vos iPhone appairés sont conservés.")
        #expect(Labels.sdkConfirmation == "PTZBot va copier ce fichier dans sa bibliothèque et retirer la quarantaine de cette copie. Ne le faites que si vous l'avez téléchargé depuis obsbot.com.")
        #expect(Labels.localNetworkDenied == "PTZBot n'a pas accès au réseau local : les iPhone ne le trouveront qu'avec Tailscale")
        #expect(Labels.tailscaleMissing == "Tailscale introuvable : accès depuis l'extérieur indisponible")
    }

    @Test("Vérifications du SDK : architecture, signature, provenance, quarantaine")
    func checks() {
        let signed = SDKCandidate(
            path: URL(fileURLWithPath: "/x/libdev.dylib"),
            architectures: ["arm64"],
            signer: "Developer ID Application: Exemple (ABCDE12345)",
            team: "ABCDE12345",
            quarantined: true,
            origin: SDKOrigin(url: "https://example.com/libdev.zip", date: nil)
        )
        #expect(Labels.sdkChecks(signed).map(\.value) == [
            "Apple Silicon : ✓",
            "Developer ID Application: Exemple (ABCDE12345)",
            "https://example.com/libdev.zip",
            "oui",
        ])
        var others = signed
        others.otherCopies = ["macos/macos/arm64-release/libdev.dylib", "macos/x86_64-release/libdev.dylib"]
        #expect(Labels.sdkChecks(others).last == Labels.SDKCheck(
            title: "Autres copies ignorées",
            value: "macos/macos/arm64-release/libdev.dylib, macos/x86_64-release/libdev.dylib"
        ))
        let bare = SDKCandidate(path: URL(fileURLWithPath: "/x/libdev.dylib"), architectures: ["x86_64"])
        #expect(Labels.sdkChecks(bare).map(\.value) == ["Apple Silicon : ✗ (x86_64)", "non signé", "inconnue", "non"])
        #expect(Labels.sdkChecks(bare).map(\.title) == ["Architecture", "Signature", "Provenance", "Quarantaine"])
        let dated = SDKCandidate(path: bare.path, architectures: ["arm64"], origin: SDKOrigin(url: nil, date: Date(timeIntervalSince1970: 0x6A00_0000)))
        #expect(Labels.sdkChecks(dated)[2].value.hasPrefix("le "))
    }

    @Test("Emplacements : utilitaires dans Contents/Helpers, SDK et journal de l'utilisateur")
    func paths() {
        let paths = AppPaths(bundle: URL(fileURLWithPath: "/Applications/PTZBot.app"), home: URL(fileURLWithPath: "/maison/exemple"))
        #expect(paths.ptzd.path == "/Applications/PTZBot.app/Contents/Helpers/ptzd")
        #expect(paths.obsbotAI.path == "/Applications/PTZBot.app/Contents/Helpers/obsbot-ai")
        #expect(paths.sdkDirectory.path == "/maison/exemple/Library/Application Support/ObsbotNacelle/sdk")
        #expect(paths.config.path == "/maison/exemple/Library/Application Support/ObsbotNacelle/config.json")
        #expect(paths.ptzdLog.path == "/maison/exemple/Library/Logs/obsbot-nacelle/ptzd.log")
    }

    @Test("Réseau local : refus reconnu à l'erreur PolicyDenied")
    func localNetwork() {
        #expect(LocalNetworkProbe.isDenied(.waiting(.dns(-65570))) == true)
        #expect(LocalNetworkProbe.isDenied(.failed(.dns(-65570))) == true)
        #expect(LocalNetworkProbe.isDenied(.failed(.dns(-65537))) == false)
        #expect(LocalNetworkProbe.isDenied(.ready) == false)
        #expect(LocalNetworkProbe.isDenied(.setup) == nil)
        #expect(LocalNetworkProbe.isDenied(.waiting(.posix(.ENETDOWN))) == nil)
    }
}
