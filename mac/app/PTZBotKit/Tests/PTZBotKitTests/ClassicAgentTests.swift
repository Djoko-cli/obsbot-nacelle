import Foundation
import Testing
@testable import PTZBotKit

/// L'agent launchd classique de talkd : plist dans un dossier temporaire, `launchctl` simulé. Jamais le vrai
/// `~/Library/LaunchAgents`, jamais le vrai `launchctl`.
@Suite("Agent launchd classique de talkd", .french, .timeLimit(.minutes(1)))
struct ClassicAgentTests {
    let root: URL
    let agents: URL
    let launchctl = FakeLaunchctl()
    let sleeper = FakeSleeper()
    let program = URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/talkd")

    init() throws {
        root = try FakeSDK.directory()
        // Le dossier n'existe pas encore : l'agent le crée.
        agents = root.appending(path: "LaunchAgents")
    }

    private func agent(program: URL? = nil) -> ClassicAgent {
        let sleeper = sleeper
        return ClassicAgent(
            label: Talkback.label,
            launchAgentsDirectory: agents,
            program: program ?? self.program,
            launchctl: launchctl,
            sleep: { delay in sleeper.slept.withLock { $0 += delay } }
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func calls() -> [String] {
        launchctl.state.withLock { $0.calls }
    }

    private func readPlist(_ url: URL) throws -> NSDictionary {
        try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? NSDictionary)
    }

    /// Une plist déjà en place, chargée dans launchd : l'état d'une app installée avec Talkback allumé.
    private func installed() throws -> ClassicAgent {
        let agent = agent()
        try agent.install()
        launchctl.state.withLock { $0.calls = []; $0.labels = []; $0.bootouts = 0; $0.plistPresentAtBootstrap = [] }
        return agent
    }

    // MARK: - La plist

    @Test("Le contenu exact : label, chemin absolu de talkd, RunAtLoad, KeepAlive, 10 s, Interactive, et rien d'autre")
    func plistContent() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = agent()
        try agent.install()
        let plist = try readPlist(agent.plistURL)
        let expected: NSDictionary = [
            "Label": "io.github.djoko-cli.obsbot-nacelle.talkd",
            "ProgramArguments": ["/Applications/PTZBot.app/Contents/Helpers/talkd"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
        ]
        #expect(plist == expected)
        #expect(agent.plistURL.lastPathComponent == "io.github.djoko-cli.obsbot-nacelle.talkd.plist")
        #expect(agent.plistURL.deletingLastPathComponent().standardizedFileURL == agents.standardizedFileURL)
    }

    @Test("La plist est écrite en XML, en 0644")
    func plistFormatAndPermissions() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = agent()
        try agent.install()
        let data = try Data(contentsOf: agent.plistURL)
        #expect(String(decoding: data.prefix(5), as: UTF8.self) == "<?xml")
        let attributes = try FileManager.default.attributesOfItem(atPath: agent.plistURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o644)
    }

    // MARK: - Allumer

    @Test("Allumer : le dossier est créé, la plist écrite, puis enable et bootstrap ; pas de bootout si rien n'est chargé")
    func installFresh() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = agent()
        try agent.install()
        #expect(calls() == ["enable", "bootstrap"])
        #expect(launchctl.state.withLock { $0.enabledLabels } == [Talkback.label])
        #expect(launchctl.state.withLock { $0.plistPresentAtBootstrap } == [true])
        #expect(exists(agent.plistURL))
        #expect(sleeper.slept.withLock { $0 } == 0)
    }

    @Test("Déjà chargé : bootout d'abord, attente du déchargement, puis enable et bootstrap")
    func installAlreadyLoaded() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        launchctl.state.withLock { $0.loaded = true; $0.pollsBeforeUnload = 3 }
        let agent = agent()
        try agent.install()
        #expect(calls() == ["bootout", "enable", "bootstrap"])
        #expect(launchctl.state.withLock { $0.labels } == [Talkback.label])
        #expect(sleeper.slept.withLock { $0 } == 3 * ClassicAgent.pollInterval)
        #expect(launchctl.state.withLock { $0.loaded })
    }

    @Test("Échec du bootout alors que l'agent est toujours chargé : erreur, pas de bootstrap")
    func installBootoutFails() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        launchctl.state.withLock { $0.loaded = true; $0.bootoutFails = true }
        let agent = agent()
        #expect(throws: ClassicAgentError.bootoutFailed("code 5")) { try agent.install() }
        #expect(calls() == ["bootout"])
    }

    @Test("bootout en échec mais agent parti : on continue jusqu'au bootstrap")
    func installBootoutFailsButGone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        launchctl.state.withLock { $0.loaded = true; $0.bootoutFails = true; $0.unloadsDespiteFailure = true }
        let agent = agent()
        try agent.install()
        #expect(calls() == ["bootout", "enable", "bootstrap"])
    }

    @Test("Encore chargé après 10 s : erreur « pas arrêté à temps », attente bornée, pas de bootstrap")
    func installNeverUnloads() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        launchctl.state.withLock { $0.loaded = true; $0.pollsBeforeUnload = 100_000 }
        let agent = agent()
        #expect(throws: ClassicAgentError.stillLoaded) { try agent.install() }
        #expect(calls() == ["bootout"])
        let waited = sleeper.slept.withLock { $0 }
        #expect(waited >= ClassicAgent.stopTimeout)
        #expect(waited <= ClassicAgent.stopTimeout + ClassicAgent.pollInterval)
    }

    @Test("Échec du bootstrap : l'erreur remonte et la plist écrite est retirée")
    func installBootstrapFails() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        launchctl.state.withLock { $0.bootstrapFails = true }
        let agent = agent()
        #expect(throws: (any Error).self) { try agent.install() }
        #expect(!exists(agent.plistURL))
        #expect(calls() == ["enable", "bootstrap"])
    }

    @Test("Service désactivé dans launchd (élément coupé dans Réglages) : l'interrupteur le réactive (enable) avant le bootstrap")
    func installDisabledService() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        launchctl.state.withLock { $0.disabled = true }
        let agent = agent()
        try agent.install()
        #expect(calls() == ["enable", "bootstrap"])
        #expect(launchctl.state.withLock { $0.loaded && !$0.disabled })
        #expect(exists(agent.plistURL))
    }

    @Test("enable refusé : l'erreur remonte, la plist écrite est retirée, pas de bootstrap")
    func installEnableFails() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        launchctl.state.withLock { $0.enableFails = true }
        let agent = agent()
        #expect(throws: (any Error).self) { try agent.install() }
        #expect(!exists(agent.plistURL))
        #expect(calls() == ["enable"])
    }

    @Test("Refus respecté (migration d'un agent « Autorisation requise ») : pas d'enable ; bootstrap refusé, la plist est gardée")
    func installRespectingRefusal() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        launchctl.state.withLock { $0.disabled = true }
        let agent = agent()
        #expect(throws: (any Error).self) { try agent.install(respectingRefusal: true) }
        #expect(calls() == ["bootstrap"])
        #expect(exists(agent.plistURL))
        #expect(launchctl.state.withLock { $0.disabled && !$0.loaded })
    }

    @Test("Refus respecté mais service non désactivé : l'agent est simplement chargé, sans enable")
    func installRespectingRefusalNotDisabled() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = agent()
        try agent.install(respectingRefusal: true)
        #expect(calls() == ["bootstrap"])
        #expect(launchctl.state.withLock { $0.loaded })
    }

    @Test("Écriture impossible (le dossier est un fichier) : erreur, aucun appel à launchctl")
    func installWriteFails() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fichier".utf8).write(to: agents)
        let agent = agent()
        #expect(throws: (any Error).self) { try agent.install() }
        #expect(calls() == [])
    }

    // MARK: - Éteindre

    @Test("Éteindre : bootout, attente du déchargement, puis la plist est supprimée")
    func uninstall() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try installed()
        launchctl.state.withLock { $0.pollsBeforeUnload = 2 }
        try agent.uninstall()
        #expect(calls() == ["bootout"])
        #expect(launchctl.state.withLock { $0.labels } == [Talkback.label])
        #expect(sleeper.slept.withLock { $0 } == 2 * ClassicAgent.pollInterval)
        #expect(!exists(agent.plistURL))
    }

    @Test("Éteindre un agent qui n'est pas chargé : pas de bootout, la plist est supprimée")
    func uninstallNotLoaded() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try installed()
        launchctl.state.withLock { $0.loaded = false }
        try agent.uninstall()
        #expect(calls() == [])
        #expect(!exists(agent.plistURL))
    }

    @Test("Éteindre sans plist ni agent : sans effet, sans erreur")
    func uninstallNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try agent().uninstall()
        #expect(calls() == [])
    }

    @Test("Échec du bootout : erreur, la plist reste (l'agent est toujours chargé)")
    func uninstallBootoutFails() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try installed()
        launchctl.state.withLock { $0.bootoutFails = true }
        #expect(throws: ClassicAgentError.bootoutFailed("code 5")) { try agent.uninstall() }
        #expect(exists(agent.plistURL))
    }

    @Test("Toujours chargé après 10 s : erreur, la plist reste, attente bornée")
    func uninstallNeverUnloads() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try installed()
        launchctl.state.withLock { $0.pollsBeforeUnload = 100_000 }
        #expect(throws: ClassicAgentError.stillLoaded) { try agent.uninstall() }
        #expect(exists(agent.plistURL))
        #expect(sleeper.slept.withLock { $0 } <= ClassicAgent.stopTimeout + ClassicAgent.pollInterval)
    }

    // MARK: - Au lancement de l'app

    @Test("Sans plist : rien du tout, ni fichier ni launchctl, même pour un nouveau numéro")
    func reconcileWithoutPlist() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = agent()
        try agent.reconcile(restart: true)
        #expect(calls() == [])
        #expect(!exists(agent.plistURL))
    }

    @Test("Plist identique, même numéro : rien")
    func reconcileSame() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try installed()
        let before = try Data(contentsOf: agent.plistURL)
        try agent.reconcile(restart: false)
        #expect(calls() == [])
        #expect(try Data(contentsOf: agent.plistURL) == before)
    }

    @Test("Plist identique, nouveau numéro : kickstart -k seulement, plist intacte")
    func reconcileNewBuild() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try installed()
        let before = try Data(contentsOf: agent.plistURL)
        try agent.reconcile(restart: true)
        #expect(calls() == ["kickstart"])
        #expect(launchctl.state.withLock { $0.labels } == [Talkback.label])
        #expect(try Data(contentsOf: agent.plistURL) == before)
    }

    @Test("Kickstart refusé : l'erreur remonte")
    func reconcileKickstartFails() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try installed()
        launchctl.state.withLock { $0.kickstartFails = true }
        #expect(throws: (any Error).self) { try agent.reconcile(restart: true) }
    }

    @Test("L'app a changé de chemin : plist réécrite, puis bootout et bootstrap (pas de kickstart)")
    func reconcileMovedApp() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try installed()
        let moved = URL(fileURLWithPath: "/Applications/Autre/PTZBot.app/Contents/Helpers/talkd")
        let updated = self.agent(program: moved)
        try updated.reconcile(restart: true)
        #expect(calls() == ["bootout", "bootstrap"])
        let plist = try readPlist(agent.plistURL)
        #expect(plist["ProgramArguments"] as? [String] == [moved.path])
    }

    @Test("Les clés ont changé (délai différent) : plist réécrite et rechargée, même sans nouveau numéro")
    func reconcileChangedKeys() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try installed()
        try Data(
            PropertyListSerialization.data(
                fromPropertyList: ["Label": Talkback.label, "ThrottleInterval": 30] as NSDictionary, format: .xml, options: 0
            )
        ).write(to: agent.plistURL)
        try agent.reconcile(restart: false)
        #expect(calls() == ["bootout", "bootstrap"])
        let plist = try readPlist(agent.plistURL)
        #expect(plist["ThrottleInterval"] as? Int == 10)
    }

    @Test("Plist illisible : réécrite et rechargée")
    func reconcileCorruptPlist() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try installed()
        try Data("pas une plist".utf8).write(to: agent.plistURL)
        try agent.reconcile(restart: false)
        #expect(calls() == ["bootout", "bootstrap"])
        #expect(try readPlist(agent.plistURL)["Label"] as? String == Talkback.label)
    }

    @Test("Plist différente et agent pas chargé : bootstrap seul")
    func reconcileMovedAppNotLoaded() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installed()
        launchctl.state.withLock { $0.loaded = false }
        let moved = URL(fileURLWithPath: "/Applications/Autre.app/Contents/Helpers/talkd")
        try agent(program: moved).reconcile(restart: false)
        #expect(calls() == ["bootstrap"])
    }

    @Test("Plist à jour mais agent pas chargé : bootstrap (jamais kickstart), avec ou sans nouveau numéro")
    func reconcileUpToDateNotLoaded() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try installed()
        let before = try Data(contentsOf: agent.plistURL)
        for restart in [true, false] {
            launchctl.state.withLock { $0.loaded = false; $0.calls = [] }
            try agent.reconcile(restart: restart)
            #expect(calls() == ["bootstrap"])
            #expect(launchctl.state.withLock { $0.loaded })
        }
        #expect(try Data(contentsOf: agent.plistURL) == before)
    }

    @Test("Plist à jour, agent pas chargé et bootstrap refusé : l'erreur remonte, la plist est gardée")
    func reconcileUpToDateBootstrapFails() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try installed()
        launchctl.state.withLock { $0.loaded = false; $0.bootstrapFails = true }
        #expect(throws: (any Error).self) { try agent.reconcile(restart: true) }
        #expect(exists(agent.plistURL))
        #expect(calls() == ["bootstrap"])
    }

    // MARK: - Emplacement temporaire (app translocalisée ou lancée depuis une image disque)

    private let transient = URL(
        fileURLWithPath: "/private/var/folders/ab/xyz/T/AppTranslocation/ABCD-1234/d/PTZBot.app/Contents/Helpers/talkd")

    @Test("Emplacement temporaire : AppTranslocation, ou volume en lecture seule ; une app à sa place ne l'est pas")
    func transientLocation() {
        #expect(ClassicAgent.isTransientLocation(transient))
        #expect(agent(program: transient).isTransient)
        #expect(!ClassicAgent.isTransientLocation(program))
        #expect(!agent().isTransient)
        // Un fichier réel sur un volume modifiable (le dossier temporaire du test) n'est pas temporaire.
        #expect(!ClassicAgent.isTransientLocation(root.appending(path: "PTZBot.app/Contents/Helpers/talkd")))
        defer { try? FileManager.default.removeItem(at: root) }
        // Image disque : volume en lecture seule (la lecture réelle est faite par `resourceValues`).
        #expect(ClassicAgent.isTransientLocation(program) { _ in true })
        #expect(!ClassicAgent.isTransientLocation(program) { _ in false })
    }

    @Test("Allumer depuis un emplacement temporaire : refusé, ni dossier, ni plist, ni launchctl")
    func installTransient() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = agent(program: transient)
        #expect(throws: ClassicAgentError.transientLocation) { try agent.install() }
        #expect(!exists(agent.plistURL))
        #expect(!exists(agents))
        #expect(calls() == [])
    }

    @Test("Au lancement, depuis un emplacement temporaire : rien du tout, plist saine intacte, même avec un nouveau numéro")
    func reconcileTransient() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let healthy = try installed()
        let before = try Data(contentsOf: healthy.plistURL)
        let moved = agent(program: transient)
        try moved.reconcile(restart: true)
        try moved.reconcile(restart: false)
        #expect(calls() == [])
        #expect(try Data(contentsOf: healthy.plistURL) == before)
    }

    @Test("Éteindre reste permis depuis un emplacement temporaire")
    func uninstallTransient() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let healthy = try installed()
        try agent(program: transient).uninstall()
        #expect(calls() == ["bootout"])
        #expect(!exists(healthy.plistURL))
    }

    // MARK: - launchctl réel : les arguments (sans l'exécuter)

    @Test("Les arguments de launchctl : bootstrap gui/<uid> <plist>, enable gui/<uid>/<label>, kickstart -k gui/<uid>/<label>, bootout gui/<uid>/<label>")
    func launchctlArguments() {
        let plist = URL(fileURLWithPath: "/tmp/essai.plist")
        #expect(SystemLaunchctl.arguments(.bootstrap(plist), uid: 501) == ["bootstrap", "gui/501", "/tmp/essai.plist"])
        #expect(SystemLaunchctl.arguments(.kickstart("a.b"), uid: 501) == ["kickstart", "-k", "gui/501/a.b"])
        #expect(SystemLaunchctl.arguments(.enable("a.b"), uid: 501) == ["enable", "gui/501/a.b"])
        #expect(SystemLaunchctl.arguments(.bootout("a.b"), uid: 501) == ["bootout", "gui/501/a.b"])
        #expect(SystemLaunchctl.arguments(.print("a.b"), uid: 501) == ["print", "gui/501/a.b"])
        #expect(SystemLaunchctl.Failure(command: "bootstrap", status: 5).errorDescription == "launchctl bootstrap a échoué (code 5).")
    }

    @Test("Messages d'erreur de l'agent")
    func errorMessages() {
        #expect(ClassicAgentError.stillLoaded.errorDescription == "talkd ne s'est pas arrêté à temps.")
        #expect(ClassicAgentError.bootoutFailed("code 5").errorDescription == "talkd n'a pas pu être arrêté : code 5")
        #expect(
            ClassicAgentError.transientLocation.errorDescription
                == "PTZBot est lancé depuis un emplacement temporaire (Téléchargements ou image disque). Déplacez PTZBot dans le dossier Applications, puis rouvrez-le avant d'allumer Talkback.")
    }

    @Test("Messages d'erreur de l'agent, en anglais", .english)
    func errorMessagesEnglish() {
        #expect(ClassicAgentError.stillLoaded.errorDescription == "talkd did not stop in time.")
        #expect(ClassicAgentError.bootoutFailed("code 5").errorDescription == "talkd could not be stopped: code 5")
        #expect(SystemLaunchctl.Failure(command: "kickstart", status: 3).errorDescription == "launchctl kickstart failed (code 3).")
        #expect(
            ClassicAgentError.transientLocation.errorDescription
                == "PTZBot is running from a temporary location (Downloads or a disk image). Move PTZBot to the Applications folder, then reopen it before turning Talkback on.")
    }
}
