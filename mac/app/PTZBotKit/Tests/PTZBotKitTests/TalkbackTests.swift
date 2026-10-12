import Foundation
import ServiceManagement
import Testing
@testable import PTZBotKit

/// Un compteur de signalements, lisible depuis n'importe quel fil.
final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

@MainActor
@Suite("Talkback", .french, .timeLimit(.minutes(1)))
struct TalkbackTests {
    let service = FakeTalkbackService()
    let state = FakeTalkbackState()
    let process = FakeProcessProbe()
    let scheduler = FakeScheduler()
    let settings = FakeSettings()
    let model: TalkbackModel

    init() {
        model = TalkbackModel(
            service: service, state: state, process: process, scheduler: scheduler,
            settings: settings, bundleVersion: "7"
        )
    }

    /// Un modèle sur les mêmes doublures, pour une autre compilation de l'app.
    private func makeModel(bundleVersion: String?) -> TalkbackModel {
        TalkbackModel(
            service: service, state: state, process: process, scheduler: scheduler,
            settings: settings, bundleVersion: bundleVersion
        )
    }

    /// Un clic sur l'interrupteur, puis l'attente de la fin de l'opération (l'agent se charge hors du fil de l'interface).
    private func toggle(_ enabled: Bool) async {
        model.setEnabled(enabled)
        await model.waitForOperation()
    }

    private func speaking(_ speaking: Bool, pid: Int32 = 4242) -> TalkbackState {
        TalkbackState(speaking: speaking, since: Date(timeIntervalSince1970: 1_791_000_000), pid: pid)
    }

    private struct Refused: LocalizedError {
        var errorDescription: String? { "refusé" }
    }

    /// Attend (jusqu'à 5 s) qu'une condition du faux soit vraie.
    private func waitUntil(_ condition: () -> Bool) async {
        var waited = 0
        while !condition(), waited < 500 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
    }

    // MARK: - Contrat

    @Test("Emplacements : talkd dans Contents/Helpers, état dans le dossier de travail")
    func paths() {
        let paths = AppPaths(bundle: URL(fileURLWithPath: "/Applications/PTZBot.app"), home: URL(fileURLWithPath: "/home-test"))
        #expect(paths.talkd.path == "/Applications/PTZBot.app/Contents/Helpers/talkd")
        #expect(paths.talkbackState.path == "/home-test/Library/Application Support/ObsbotNacelle/talkd-state.json")
    }

    @Test("Le fichier d'état de talkd : le format écrit par talkd (speaking, since en ISO 8601, pid) se lit tel quel")
    func stateContract() throws {
        let json = #"{ "pid" : 4242, "since" : "2026-10-03T04:00:00Z", "speaking" : true }"#
        let decoded = try TalkbackState.decoder.decode(TalkbackState.self, from: Data(json.utf8))
        #expect(decoded == speaking(true))
    }

    @Test("Lecteur du fichier : absent ou illisible, nil ; valide, l'état")
    func fileSource() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "talkback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "talkd-state.json")
        let source = FileTalkbackStateSource(url: url)
        #expect(source.read() == nil)
        try Data("pas du json".utf8).write(to: url)
        #expect(source.read() == nil)
        try Data(#"{"pid":7,"since":"2026-10-03T04:00:00Z","speaking":false}"#.utf8).write(to: url)
        #expect(source.read() == speaking(false, pid: 7))
    }

    @Test("Sonde de processus : le nôtre est vivant, un numéro inexistant ne l'est pas")
    func processProbe() {
        let probe = SystemProcessProbe()
        #expect(probe.isAlive(pid: ProcessInfo.processInfo.processIdentifier))
        #expect(!probe.isAlive(pid: 0))
        #expect(!probe.isAlive(pid: -5))
        #expect(!probe.isAlive(pid: Int32.max))
    }


    @Test("La plist embarquée ne sert plus qu'à désinscrire l'ancien agent (1.0.4) : label, BundleProgram, pas de ProgramArguments")
    func embeddedPlistKept() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "LaunchAgents/\(Talkback.plistName)")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        #expect(Talkback.plistName == "io.github.djoko-cli.obsbot-nacelle.talkd.plist")
        #expect(plist["Label"] as? String == Talkback.label)
        #expect(plist["BundleProgram"] as? String == "Contents/Helpers/talkd")
        #expect(plist["ProgramArguments"] == nil)
    }

    // MARK: - Au lancement de l'app : migration depuis la 1.0.4 et mise à jour

    @Test("Migration depuis la 1.0.4, Talkback allumé : l'ancien agent est désinscrit (attendu), l'agent classique installé, le numéro retenu")
    func migrationFromServiceManagement() async {
        service.hasLegacyRegistration = true
        settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] = "6"
        await model.prepareAtLaunch()
        #expect(service.calls == ["unregisterLegacy", "enable"])
        #expect(service.agentState == .installed)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "7")
        #expect(settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] == nil)
        #expect(model.lastError == nil)
        #expect(model.isEnabled)
        #expect(!model.isPreparing)
    }

    @Test("Migration, Talkback éteint (rien d'inscrit, pas de plist) : rien n'est touché, seul l'ancien réglage est effacé")
    func migrationWhenOff() async {
        settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] = "6"
        await model.prepareAtLaunch()
        #expect(service.calls == [])
        #expect(settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] == nil)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == nil)
        #expect(!model.isPreparing)
        #expect(model.status == .disabled)
    }

    @Test("Migration : la désinscription est attendue avant d'installer, et l'interrupteur reste grisé sur « Démarrage… » pendant ce temps")
    func migrationWaitsForUnregister() async {
        service.hasLegacyRegistration = true
        service.unregisterLegacyGate.isHeld = true
        let task = Task { await model.prepareAtLaunch() }
        await waitUntil { service.unregisterLegacyGate.isPending }
        #expect(service.unregisterLegacyGate.isPending)
        #expect(service.count("enable") == 0)
        #expect(model.isPreparing)
        // L'agent est un instant désinscrit : « Démarrage… » plutôt que « Désactivé », et le clic est sans effet.
        model.refresh()
        #expect(model.status == .starting)
        model.setEnabled(false)
        #expect(service.count("disable") == 0)
        service.unregisterLegacyGate.open()
        await task.value
        #expect(service.calls == ["unregisterLegacy", "enable"])
        #expect(!model.isPreparing)
        #expect(model.status == .starting)
        #expect(service.agentState == .installed)
    }

    @Test("Migration, désinscription refusée : erreur affichée, rien d'installé, numéro non retenu")
    func migrationUnregisterRefused() async {
        service.hasLegacyRegistration = true
        service.unregisterLegacyFailure = Refused()
        await model.prepareAtLaunch()
        #expect(service.calls == ["unregisterLegacy"])
        #expect(model.lastError == "Talkback impossible : refusé")
        #expect(settings.strings[TalkbackModel.agentBuildKey] == nil)
        #expect(!model.isPreparing)
        #expect(model.status == .disabled)
    }

    @Test("Migration, installation refusée après la désinscription : erreur affichée, numéro non retenu")
    func migrationInstallRefused() async {
        service.hasLegacyRegistration = true
        service.enableFailure = Refused()
        await model.prepareAtLaunch()
        #expect(service.calls == ["unregisterLegacy", "enable"])
        #expect(model.lastError == "Talkback impossible : refusé")
        #expect(settings.strings[TalkbackModel.agentBuildKey] == nil)
        #expect(!model.isPreparing)
    }

    @Test("Migration d'un agent « Autorisation requise » : désinscrit en attendant la fin, rien n'est installé, Talkback reste éteint")
    func migrationLeavesRefusalOff() async {
        service.hasLegacyRegistration = true
        service.legacyRequiresApproval = true
        await model.prepareAtLaunch()
        #expect(service.calls == ["unregisterLegacy"])
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == nil)
        #expect(model.lastError == nil)
        #expect(!model.isPreparing)
        #expect(model.status == .disabled)
    }

    @Test("Migration d'un agent « Autorisation requise », désinscription refusée : erreur affichée, rien d'installé ni retenu")
    func migrationRefusalUnregisterRefused() async {
        service.hasLegacyRegistration = true
        service.legacyRequiresApproval = true
        service.unregisterLegacyFailure = Refused()
        await model.prepareAtLaunch()
        #expect(service.calls == ["unregisterLegacy"])
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
        #expect(model.lastError == "Talkback impossible : refusé")
    }

    @Test("Migration d'un agent actif : l'intention est retenue avant la désinscription, pas après")
    func migrationRetainsIntentionBeforeUnregister() async {
        service.hasLegacyRegistration = true
        service.unregisterLegacyGate.isHeld = true
        let task = Task { await model.prepareAtLaunch() }
        await waitUntil { service.unregisterLegacyGate.isPending }
        // L'app peut être tuée ici : l'ancien agent n'existera plus, l'intention doit déjà être retenue.
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == "enable")
        service.unregisterLegacyGate.open()
        await task.value
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
    }

    @Test("Migration, installation refusée alors que rien n'est installé : l'intention est retenue, sans numéro")
    func migrationRetainsIntention() async {
        service.hasLegacyRegistration = true
        service.enableFailure = Refused()
        await model.prepareAtLaunch()
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == "enable")
        #expect(settings.strings[TalkbackModel.agentBuildKey] == nil)
        #expect(model.lastError == "Talkback impossible : refusé")
    }

    @Test("Migration, échec mais plist en place malgré tout : rien à retenir, la mise en ordre du lancement suivant s'en charge")
    func migrationKeptPlist() async {
        service.hasLegacyRegistration = true
        service.enableFailure = Refused()
        service.agentState = .installed
        await model.prepareAtLaunch()
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
        #expect(model.lastError == "Talkback impossible : refusé")
    }

    @Test("Intention retenue : retentée au lancement suivant (une fois par lancement), puis oubliée")
    func pendingInstallRetried() async {
        settings.strings[TalkbackModel.pendingInstallKey] = "enable"
        service.enableFailure = Refused()
        await model.prepareAtLaunch()
        #expect(service.calls == ["enable"])
        #expect(model.lastError == "Talkback impossible : refusé")
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == "enable")
        // Une seule tentative par lancement.
        await model.prepareAtLaunch()
        #expect(service.calls == ["enable"])
        // Lancement suivant : l'installation réussit.
        service.enableFailure = nil
        let next = makeModel(bundleVersion: "7")
        await next.prepareAtLaunch()
        #expect(service.calls == ["enable", "enable"])
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "7")
        #expect(next.lastError == nil)
        #expect(next.isEnabled)
        // Rien de plus ensuite.
        await makeModel(bundleVersion: "7").prepareAtLaunch()
        #expect(service.calls.filter { $0.hasPrefix("enable") }.count == 2)
    }

    @Test("Intention retenue mais plist déjà là : pas de nouvelle installation, l'intention est oubliée")
    func pendingInstallWithPlist() async {
        settings.strings[TalkbackModel.pendingInstallKey] = "enable"
        service.agentState = .installed
        await model.prepareAtLaunch()
        #expect(service.calls == ["reconcile(restart: true)"])
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
    }

    @Test("Intention retenue puis l'interrupteur : allumer ou éteindre l'oublie")
    func toggleClearsPendingInstall() async {
        settings.strings[TalkbackModel.pendingInstallKey] = "enable"
        await toggle(true)
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
        settings.strings[TalkbackModel.pendingInstallKey] = "enable"
        await toggle(false)
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
    }

    @Test("Intention retenue puis l'interrupteur échoue : le geste explicite remplace l'intention, allumer ou éteindre")
    func failedToggleClearsPendingInstall() async {
        settings.strings[TalkbackModel.pendingInstallKey] = "enable"
        service.enableFailure = Refused()
        await toggle(true)
        #expect(model.lastError == "Talkback impossible : refusé")
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
        settings.strings[TalkbackModel.pendingInstallKey] = "enable"
        service.disableFailure = Refused()
        await toggle(false)
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
    }

    @Test("Agent classique en place, même numéro qu'au dernier passage : mise en ordre sans redémarrage")
    func updateSameBuild() async {
        service.agentState = .installed
        settings.strings[TalkbackModel.agentBuildKey] = "7"
        await model.prepareAtLaunch()
        #expect(service.calls == ["reconcile(restart: false)"])
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "7")
    }

    @Test("Agent classique en place, nouveau numéro : redémarrage de talkd, nouveau numéro retenu")
    func updateNewBuild() async {
        service.agentState = .installed
        settings.strings[TalkbackModel.agentBuildKey] = "6"
        await model.prepareAtLaunch()
        #expect(service.calls == ["reconcile(restart: true)"])
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "7")
        #expect(model.lastError == nil)
        #expect(!model.isPreparing)
    }

    @Test("Agent classique en place, aucun numéro retenu : redémarrage aussi")
    func updateNoRememberedBuild() async {
        service.agentState = .installed
        await model.prepareAtLaunch()
        #expect(service.calls == ["reconcile(restart: true)"])
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "7")
    }

    @Test("Mise à jour refusée : erreur affichée, numéro inchangé, rien n'est retenté")
    func updateFails() async {
        service.agentState = .installed
        settings.strings[TalkbackModel.agentBuildKey] = "6"
        service.reconcileFailure = Refused()
        await model.prepareAtLaunch()
        #expect(model.lastError == "Talkback impossible : refusé")
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "6")
        await model.prepareAtLaunch()
        #expect(service.calls == ["reconcile(restart: true)"])
    }

    @Test("Autorisation requise (l'utilisateur a coupé l'élément dans Réglages) : pas d'erreur, l'invitation à autoriser suffit")
    func updateWithApprovalNeeded() async {
        service.agentState = .requiresApproval
        service.reconcileFailure = Refused()
        await model.prepareAtLaunch()
        #expect(model.status == .requiresApproval)
        #expect(model.lastError == nil)
    }

    @Test("Emplacement temporaire au lancement : rien du tout (ni migration, ni mise à jour, ni numéro retenu, ni erreur)")
    func launchTransient() async {
        service.installBlocker = ClassicAgentError.transientLocation
        service.hasLegacyRegistration = true
        service.agentState = .installed
        settings.strings[TalkbackModel.agentBuildKey] = "6"
        settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] = "6"
        settings.strings[TalkbackModel.pendingInstallKey] = "enable"
        await model.prepareAtLaunch()
        #expect(service.calls == [])
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == "enable")
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "6")
        #expect(settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] == "6")
        #expect(model.lastError == nil)
        #expect(!model.isPreparing)
    }

    @Test("Compilation de travail (numéro 1) : ni migration ni mise à jour, même avec un ancien agent et une plist")
    func workingBuild() async {
        service.hasLegacyRegistration = true
        service.agentState = .installed
        settings.strings[TalkbackModel.agentBuildKey] = "42"
        settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] = "42"
        await makeModel(bundleVersion: "1").prepareAtLaunch()
        #expect(service.calls == [])
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "42")
        #expect(settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] == "42")
    }

    @Test("Numéro de compilation inconnu : rien")
    func unknownBuild() async {
        service.hasLegacyRegistration = true
        service.agentState = .installed
        await makeModel(bundleVersion: nil).prepareAtLaunch()
        #expect(service.calls == [])
    }

    @Test("Une seule fois par lancement : un second appel est sans effet")
    func preparesOnce() async {
        service.agentState = .installed
        await model.prepareAtLaunch()
        await model.prepareAtLaunch()
        #expect(service.calls == ["reconcile(restart: true)"])
    }

    @Test("Au lancement, tout se fait hors du fil principal")
    func prepareOffMainThread() async {
        service.hasLegacyRegistration = true
        await model.prepareAtLaunch()
        service.agentState = .installed
        await makeModel(bundleVersion: "8").prepareAtLaunch()
        #expect(service.calls.count == 3)
        #expect(service.backgroundCallsOnMainThread == [false, false, false])
    }

    @Test("Pendant la mise à jour, l'interrupteur est grisé et sans effet ; « Démarrage… » reste affiché au-delà de 15 s")
    func updateLocksToggle() async {
        service.agentState = .installed
        service.reconcileGate.isHeld = true
        let task = Task { await model.prepareAtLaunch() }
        await waitUntil { service.reconcileGate.isPending }
        #expect(model.isPreparing)
        model.setEnabled(false)
        #expect(service.count("disable") == 0)
        scheduler.advance(by: 20)
        model.refresh()
        #expect(model.status == .starting)
        service.reconcileGate.open()
        await task.value
        #expect(!model.isPreparing)
        // Le délai de 15 s repart de la fin de la mise à jour.
        model.refresh()
        #expect(model.status == .starting)
        scheduler.advance(by: 14)
        model.refresh()
        #expect(model.status == .starting)
        scheduler.advance(by: 1)
        model.refresh()
        #expect(model.status == .notRunning)
        // Et l'interrupteur répond de nouveau.
        await toggle(false)
        #expect(service.count("disable") == 1)
    }

    // MARK: - États

    @Test("Agent absent : Désactivé, interrupteur éteint")
    func disabled() {
        #expect(model.status == .disabled)
        #expect(!model.isEnabled)
        #expect(Labels.talkbackStatus(model.status) == "Désactivé")
    }

    @Test("Interrupteur allumé : la plist est en place ; talkd n'a pas encore écrit son état : Démarrage…")
    func installedStarting() async {
        await toggle(true)
        #expect(model.isEnabled)
        #expect(model.status == .starting)
        #expect(Labels.talkbackStatus(model.status) == "Démarrage…")
    }

    @Test("Installé et talkd vivant au repos : Prêt")
    func ready() async {
        await toggle(true)
        state.state = speaking(false)
        process.alive = [4242]
        model.refresh()
        #expect(model.status == .ready)
        #expect(Labels.talkbackStatus(.ready) == "Prêt")
    }

    @Test("Installé, talkd vivant et en parole : En lecture")
    func playing() async {
        await toggle(true)
        state.state = speaking(true)
        process.alive = [4242]
        model.refresh()
        #expect(model.status == .playing)
        #expect(Labels.talkbackStatus(.playing) == "En lecture")
    }

    @Test("L'état d'un talkd qui n'existe plus est ignoré, même « en lecture » : Démarrage…")
    func staleState() async {
        await toggle(true)
        state.state = speaking(true)
        process.alive = []
        model.refresh()
        #expect(model.status == .starting)
    }

    @Test("L'utilisateur a coupé l'élément dans Réglages : Autorisation requise, interrupteur allumé, Réglages ouvrables")
    func requiresApproval() async {
        service.stateAfterEnable = .requiresApproval
        await toggle(true)
        #expect(model.status == .requiresApproval)
        #expect(model.isEnabled)
        #expect(Labels.talkbackStatus(.requiresApproval) == "Autorisation requise")
        #expect(Labels.talkbackApproval == "Autorisez Talkback dans Réglages › Général › Ouverture")
        model.openSystemSettings()
        #expect(service.settingsOpened == 1)
        #expect(model.lastError == nil)
    }

    @Test("Interrupteur éteint : l'agent est déchargé et la plist supprimée")
    func disableSwitch() async {
        await toggle(true)
        await toggle(false)
        #expect(service.calls == ["enable", "disable"])
        #expect(model.status == .disabled)
    }

    @Test("Allumage refusé : message d'erreur, interrupteur éteint, et un nouveau clic efface l'erreur")
    func failure() async {
        service.enableFailure = Refused()
        await toggle(true)
        #expect(model.status == .disabled)
        #expect(!model.isEnabled)
        #expect(model.lastError == "Talkback impossible : refusé")
        service.enableFailure = nil
        await toggle(true)
        #expect(model.lastError == nil)
        #expect(model.isEnabled)
    }

    @Test("Emplacement temporaire : allumer est refusé avec le message, sans rien appeler ni changer l'interrupteur")
    func enableBlocked() async {
        service.installBlocker = ClassicAgentError.transientLocation
        await toggle(true)
        #expect(service.calls == [])
        #expect(model.status == .disabled)
        #expect(!model.isEnabled)
        #expect(!model.isBusy)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == nil)
        #expect(
            model.lastError
                == "Talkback impossible : PTZBot est lancé depuis un emplacement temporaire (Téléchargements ou image disque). Déplacez PTZBot dans le dossier Applications, puis rouvrez-le avant d'allumer Talkback.")
        // Plus tard, à sa place : le même clic allume.
        service.installBlocker = nil
        await toggle(true)
        #expect(service.calls == ["enable"])
        #expect(model.lastError == nil)
        #expect(model.isEnabled)
    }

    @Test("Emplacement temporaire : éteindre reste permis")
    func disableAllowedWhenBlocked() async {
        service.agentState = .installed
        service.installBlocker = ClassicAgentError.transientLocation
        model.refresh()
        await toggle(false)
        #expect(service.calls == ["disable"])
        #expect(model.status == .disabled)
        #expect(model.lastError == nil)
    }

    @Test("Emplacement temporaire, en anglais : le message du refus", .english)
    func enableBlockedEnglish() async {
        service.installBlocker = ClassicAgentError.transientLocation
        await toggle(true)
        #expect(
            model.lastError
                == "Talkback failed: PTZBot is running from a temporary location (Downloads or a disk image). Move PTZBot to the Applications folder, then reopen it before turning Talkback on.")
    }

    @Test("Refus parce que l'accord manque : pas d'erreur, l'invitation à autoriser suffit")
    func failureWithApproval() async {
        service.stateAfterEnable = .requiresApproval
        service.agentState = .requiresApproval
        service.enableFailure = Refused()
        await toggle(true)
        #expect(model.status == .requiresApproval)
        #expect(model.lastError == nil)
    }

    // MARK: - talkd arrêté ou absent

    @Test("Le fichier d'état avec un échec (champ failure) se lit ; sans ce champ, failure vaut nil")
    func failureContract() throws {
        let json = #"{ "pid" : 4242, "since" : "2026-10-03T04:00:00Z", "speaking" : false, "failure" : "portBusy" }"#
        let decoded = try TalkbackState.decoder.decode(TalkbackState.self, from: Data(json.utf8))
        #expect(decoded.failure == "portBusy")
        let old = try TalkbackState.decoder.decode(
            TalkbackState.self, from: Data(#"{ "pid" : 4242, "since" : "2026-10-03T04:00:00Z", "speaking" : false }"#.utf8)
        )
        #expect(old.failure == nil)
    }

    @Test("talkd arrêté sur un échec (port occupé), processus disparu : Arrêté, avec la raison")
    func failedPortBusy() async {
        await toggle(true)
        state.state = TalkbackState(speaking: false, since: Date(timeIntervalSince1970: 1_791_000_000), pid: 4242, failure: "portBusy")
        process.alive = []
        model.refresh()
        #expect(model.status == .failed(.portBusy))
        #expect(model.isEnabled)
        #expect(model.needsAttention)
        #expect(Labels.talkbackStatus(model.status) == "Arrêté : le port UDP est déjà utilisé (voir le journal)")
        #expect(Labels.talkbackStatus(.failed(.socket)) == "Arrêté : erreur réseau (voir le journal)")
        #expect(Labels.talkbackStatus(.failed(.other)) == "Arrêté (voir le journal)")
    }

    @Test("Codes d'échec lus : portBusy, socket, et tout autre code")
    func failureCodes() {
        #expect(TalkbackFailure(code: "portBusy") == .portBusy)
        #expect(TalkbackFailure(code: "socket") == .socket)
        #expect(TalkbackFailure(code: "inconnu") == .other)
    }

    @Test("Échec écrit par un talkd qui vit encore (il s'arrête juste après) : déjà Arrêté, jamais Prêt")
    func failedWhileExiting() async {
        await toggle(true)
        state.state = TalkbackState(speaking: false, since: Date(timeIntervalSince1970: 1_791_000_000), pid: 4242, failure: "socket")
        process.alive = [4242]
        model.refresh()
        #expect(model.status == .failed(.socket))
    }

    @Test("Installé mais talkd absent pendant plus de 15 s : talkd ne démarre pas")
    func notRunning() async {
        await toggle(true)
        #expect(model.status == .starting)
        #expect(!model.needsAttention)
        scheduler.advance(by: 14)
        model.refresh()
        #expect(model.status == .starting)
        scheduler.advance(by: 1)
        model.refresh()
        #expect(model.status == .notRunning)
        #expect(model.needsAttention)
        #expect(model.isEnabled)
        #expect(model.lastError == nil)
        #expect(Labels.talkbackStatus(.notRunning) == "talkd ne démarre pas (voir le journal)")
    }

    @Test("talkd réécrit son état : retour à Prêt, et le délai de 15 s repart de zéro la fois suivante")
    func backToReady() async {
        await toggle(true)
        scheduler.advance(by: 20)
        model.refresh()
        #expect(model.status == .notRunning)
        state.state = speaking(false)
        process.alive = [4242]
        model.refresh()
        #expect(model.status == .ready)
        #expect(!model.needsAttention)
        // talkd s'arrête de nouveau : Démarrage…, et non tout de suite « ne démarre pas ».
        process.alive = []
        model.refresh()
        #expect(model.status == .starting)
        scheduler.advance(by: 15)
        model.refresh()
        #expect(model.status == .notRunning)
    }

    @Test("Désactivé puis réactivé : le délai de 15 s repart de zéro")
    func notRunningResetsWhenDisabled() async {
        await toggle(true)
        scheduler.advance(by: 20)
        model.refresh()
        #expect(model.status == .notRunning)
        await toggle(false)
        #expect(model.status == .disabled)
        await toggle(true)
        #expect(model.status == .starting)
    }

    @Test("Panneau ouvert : « ne démarre pas » arrive tout seul au bout de 15 s, par le suivi chaque seconde")
    func notRunningWhileWatching() async {
        await toggle(true)
        model.beginWatching()
        scheduler.advance(by: 16)
        #expect(model.status == .notRunning)
        model.endWatching()
    }

    @Test("Autorisation requise : attire l'attention (orange) ; Prêt et En lecture, non")
    func attention() async {
        service.stateAfterEnable = .requiresApproval
        await toggle(true)
        #expect(model.needsAttention)
        await toggle(false)
        await toggle(true)
        service.agentState = .installed
        state.state = speaking(true)
        process.alive = [4242]
        model.refresh()
        #expect(model.status == .playing)
        #expect(!model.needsAttention)
    }

    // MARK: - Suivi de l'état pendant que le panneau est ouvert

    @Test("Panneau ouvert : l'état est relu chaque seconde ; fermé, plus rien")
    func watching() async {
        await toggle(true)
        process.alive = [4242]
        state.state = speaking(false)
        model.beginWatching()
        #expect(model.status == .ready)
        let reads = state.reads
        state.state = speaking(true)
        scheduler.advance(by: 1)
        #expect(model.status == .playing)
        scheduler.advance(by: 1)
        #expect(state.reads == reads + 2)
        model.endWatching()
        let after = state.reads
        scheduler.advance(by: 5)
        #expect(state.reads == after)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Ouvrir deux fois de suite le panneau ne double pas le suivi")
    func watchingOnce() {
        model.beginWatching()
        model.beginWatching()
        #expect(scheduler.pendingCount == 1)
        model.endWatching()
        model.endWatching()
        #expect(scheduler.pendingCount == 0)
    }

    // MARK: - Allumer et éteindre hors du fil de l'interface

    @Test("Allumer : l'interrupteur bascule et « Démarrage… » s'affiche tout de suite, l'installation se fait ensuite")
    func enableReturnsImmediately() async {
        service.enableGate.isHeld = true
        model.setEnabled(true)
        #expect(model.isEnabled)
        #expect(model.isBusy)
        #expect(model.status == .starting)
        await waitUntil { service.enableGate.isPending }
        #expect(service.enableGate.isPending)
        #expect(model.isBusy)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == nil)
        service.enableGate.open()
        await model.waitForOperation()
        #expect(!model.isBusy)
        #expect(service.count("enable") == 1)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "7")
        #expect(model.status == .starting)
    }

    @Test("Éteindre : l'interrupteur s'éteint et « Arrêt… » s'affiche tout de suite, le déchargement se fait ensuite")
    func disableReturnsImmediately() async {
        await toggle(true)
        process.alive = [4242]
        state.state = speaking(false)
        model.refresh()
        #expect(model.status == .ready)
        service.disableGate.isHeld = true
        model.setEnabled(false)
        #expect(!model.isEnabled)
        #expect(model.isBusy)
        #expect(model.status == .stopping)
        #expect(!model.needsAttention)
        #expect(Labels.talkbackStatus(model.status) == "Arrêt…")
        await waitUntil { service.disableGate.isPending }
        #expect(service.disableGate.isPending)
        // Le suivi chaque seconde ne remplace pas « Arrêt… » par l'état encore installé.
        model.beginWatching()
        scheduler.advance(by: 3)
        #expect(model.status == .stopping)
        service.disableGate.open()
        await model.waitForOperation()
        #expect(model.status == .disabled)
        #expect(!model.isBusy)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == nil)
        model.endWatching()
    }

    @Test("Un second clic pendant l'opération est sans effet")
    func secondClickIgnoredWhileBusy() async {
        service.enableGate.isHeld = true
        model.setEnabled(true)
        await waitUntil { service.enableGate.isPending }
        model.setEnabled(false)
        #expect(model.status == .starting)
        service.enableGate.open()
        await model.waitForOperation()
        #expect(service.count("disable") == 0)
        #expect(service.count("enable") == 1)
        #expect(service.agentState == .installed)
        // L'opération finie, l'interrupteur répond de nouveau.
        await toggle(false)
        #expect(service.count("disable") == 1)
        #expect(model.status == .disabled)
    }

    @Test("Les appels à l'agent (launchctl, attentes) se font hors du fil principal")
    func operationsOffMainThread() async {
        await toggle(true)
        await toggle(false)
        #expect(service.backgroundCallsOnMainThread == [false, false])
    }

    @Test("Interrupteur allumé : le numéro de compilation est retenu ; éteint, il est effacé")
    func switchRemembersBuild() async {
        await toggle(true)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "7")
        await toggle(false)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == nil)
    }

    @Test("Allumage refusé : aucun numéro retenu ; extinction refusée : le numéro reste")
    func failedSwitchKeepsBuild() async {
        service.enableFailure = Refused()
        await toggle(true)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == nil)
        service.enableFailure = nil
        await toggle(true)
        service.disableFailure = Refused()
        await toggle(false)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "7")
    }

    @Test("Extinction refusée : l'interrupteur revient à l'état réel (toujours installé), l'erreur est montrée")
    func asyncDisableFailure() async {
        await toggle(true)
        service.disableFailure = Refused()
        model.setEnabled(false)
        #expect(model.status == .stopping)
        await model.waitForOperation()
        #expect(model.status == .starting)
        #expect(model.isEnabled)
        #expect(!model.isBusy)
        #expect(model.lastError == "Talkback impossible : refusé")
    }

    @Test("L'effacement de l'erreur : un nouveau clic efface l'erreur précédente tout de suite")
    func errorClearedAtOnce() async {
        service.enableFailure = Refused()
        await toggle(true)
        #expect(model.lastError != nil)
        service.enableFailure = nil
        service.enableGate.isHeld = true
        model.setEnabled(true)
        #expect(model.lastError == nil)
        await waitUntil { service.enableGate.isPending }
        service.enableGate.open()
        await model.waitForOperation()
    }

    // MARK: - Surveillance du fichier d'état

    private func makeObservingModel(_ observer: FakeFileObserver) -> TalkbackModel {
        TalkbackModel(
            service: service, state: state, process: process, scheduler: scheduler,
            settings: settings, bundleVersion: "7", fileObserver: observer
        )
    }

    @Test("Panneau ouvert : le fichier d'état est surveillé ; un changement relit l'état à 100 ms près, regroupé")
    func fileChangeRefreshes() async {
        let observer = FakeFileObserver()
        let observing = makeObservingModel(observer)
        service.agentState = .installed
        process.alive = [4242]
        state.state = speaking(false)
        observing.beginWatching()
        #expect(observer.observeCalls == 1)
        #expect(observing.status == .ready)
        let reads = state.reads
        // Trois changements d'affilée : une seule relecture, 100 ms après le premier.
        state.state = speaking(true)
        observer.emit()
        observer.emit()
        observer.emit()
        #expect(observing.status == .ready)
        scheduler.advance(by: 0.09)
        #expect(observing.status == .ready)
        scheduler.advance(by: 0.01)
        #expect(observing.status == .playing)
        #expect(state.reads == reads + 1)
        // Un nouveau changement après coup rouvre une fenêtre.
        state.state = speaking(false)
        observer.emit()
        scheduler.advance(by: 0.1)
        #expect(observing.status == .ready)
        observing.endWatching()
    }

    @Test("La relecture chaque seconde reste le filet de sécurité, avec ou sans surveillance")
    func pollingStaysWithObserver() {
        let observer = FakeFileObserver()
        let observing = makeObservingModel(observer)
        service.agentState = .installed
        process.alive = [4242]
        state.state = speaking(false)
        observing.beginWatching()
        state.state = speaking(true)
        scheduler.advance(by: 1)
        #expect(observing.status == .playing)
        observing.endWatching()
    }

    @Test("Panneau fermé : la surveillance s'arrête, un changement tardif ne relit rien")
    func endWatchingStopsObserver() {
        let observer = FakeFileObserver()
        let observing = makeObservingModel(observer)
        observing.beginWatching()
        observer.emit()
        observing.endWatching()
        #expect(observer.cancelCalls == 1)
        #expect(!observer.isObserving)
        #expect(scheduler.pendingCount == 0)
        let reads = state.reads
        observer.emit()
        scheduler.advance(by: 5)
        #expect(state.reads == reads)
    }

    @Test("Ouvrir deux fois de suite le panneau ne double pas la surveillance")
    func observeOnce() {
        let observer = FakeFileObserver()
        let observing = makeObservingModel(observer)
        observing.beginWatching()
        observing.beginWatching()
        #expect(observer.observeCalls == 1)
        observing.endWatching()
        observing.endWatching()
        #expect(observer.cancelCalls == 1)
        observing.beginWatching()
        #expect(observer.observeCalls == 2)
        observing.endWatching()
    }

    @Test("Observateur réel : un fichier remplacé de façon atomique, créé ou supprimé est signalé (attente bornée à 5 s)")
    func realObserver() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "talkback-obs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "talkd-state.json")
        let counter = ChangeCounter()
        let observer = DispatchFileChangeObserver(url: url)
        let observation = observer.observe { counter.increment() }
        defer { observation.cancel() }

        func waitFor(_ target: Int) async {
            var waited = 0
            while counter.value < target, waited < 500 {
                try? await Task.sleep(for: .milliseconds(10))
                waited += 1
            }
        }

        // Créé.
        try Data("un".utf8).write(to: url, options: .atomic)
        await waitFor(1)
        #expect(counter.value >= 1)
        // Remplacé de façon atomique (écriture dans un fichier temporaire, puis renommage).
        let before = counter.value
        try Data("deux, plus long".utf8).write(to: url, options: .atomic)
        await waitFor(before + 1)
        #expect(counter.value > before)
        // Supprimé.
        let beforeDelete = counter.value
        try FileManager.default.removeItem(at: url)
        await waitFor(beforeDelete + 1)
        #expect(counter.value > beforeDelete)
        // Un autre fichier du même dossier n'est pas signalé.
        let beforeOther = counter.value
        try Data("autre".utf8).write(to: directory.appending(path: "talkd.log"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.value == beforeOther)
        // Annulé : plus rien.
        observation.cancel()
        try Data("trois".utf8).write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.value == beforeOther)
    }

    @Test("Observateur réel : dossier absent, aucune surveillance et aucun plantage")
    func realObserverMissingDirectory() {
        let url = FileManager.default.temporaryDirectory.appending(path: "absent-\(UUID().uuidString)/talkd-state.json")
        let observation = DispatchFileChangeObserver(url: url).observe {}
        observation.cancel()
    }

    // MARK: - Textes

    @Test("Textes en anglais : chaque état et l'invitation à autoriser", .english)
    func english() {
        #expect(Labels.talkbackStatus(.disabled) == "Disabled")
        #expect(Labels.talkbackStatus(.requiresApproval) == "Authorization required")
        #expect(Labels.talkbackStatus(.playing) == "Playing")
        #expect(Labels.talkbackStatus(.ready) == "Ready")
        #expect(Labels.talkbackStatus(.starting) == "Starting…")
        #expect(Labels.talkbackStatus(.stopping) == "Stopping…")
        #expect(Labels.talkbackApproval == "Allow Talkback in System Settings › General › Login Items")
        #expect(Labels.talkbackStatus(.failed(.portBusy)) == "Stopped: the UDP port is already in use (see the log)")
        #expect(Labels.talkbackStatus(.failed(.socket)) == "Stopped: network error (see the log)")
        #expect(Labels.talkbackStatus(.failed(.other)) == "Stopped (see the log)")
        #expect(Labels.talkbackStatus(.notRunning) == "talkd is not starting (see the log)")
    }
}
