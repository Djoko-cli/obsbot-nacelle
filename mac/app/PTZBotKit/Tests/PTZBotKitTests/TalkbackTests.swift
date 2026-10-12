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
    let service = FakeLoginItem()
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

    /// Un clic sur l'interrupteur, puis l'attente de la fin de l'opération (l'inscription se fait hors du fil de l'interface).
    private func toggle(_ enabled: Bool) async {
        model.setEnabled(enabled)
        await model.waitForOperation()
    }

    private func speaking(_ speaking: Bool, pid: Int32 = 4242) -> TalkbackState {
        TalkbackState(speaking: speaking, since: Date(timeIntervalSince1970: 1_791_000_000), pid: pid)
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

    @Test("La plist de l'agent embarqué : label, programme dans l'app, démarrage à l'ouverture, relance, 10 s, Interactive")
    func agentPlist() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "LaunchAgents/\(Talkback.plistName)")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        #expect(Talkback.plistName == "io.github.djoko-cli.obsbot-nacelle.talkd.plist")
        #expect(plist["Label"] as? String == Talkback.label)
        #expect(plist["BundleProgram"] as? String == "Contents/Helpers/talkd")
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect((plist["ThrottleInterval"] as? Int ?? 0) >= 10)
        #expect(plist["ProcessType"] as? String == "Interactive")
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["io.github.djoko-cli.ptzbot"])
        #expect(plist["ProgramArguments"] == nil)
    }

    // MARK: - Réinscription après une mise à jour

    private struct Refused: LocalizedError {
        var errorDescription: String? { "refusé" }
    }

    @Test("Interrupteur allumé : le numéro de compilation est retenu ; éteint, il est effacé")
    func switchRemembersBuild() async {
        await toggle(true)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
        await toggle(false)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == nil)
    }

    @Test("Inscription refusée par l'interrupteur : aucun numéro retenu")
    func failedSwitchKeepsNoBuild() async {
        service.failure = Refused()
        await toggle(true)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == nil)
    }

    @Test("Désinscription refusée par l'interrupteur : le numéro retenu reste")
    func failedUnregisterKeepsBuild() async {
        await toggle(true)
        service.failure = Refused()
        await toggle(false)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
    }

    @Test("Même numéro de compilation qu'à l'inscription : rien n'est touché")
    func sameBuild() async {
        await toggle(true)
        let before = (service.registerCalls, service.unregisterCalls)
        await makeModel(bundleVersion: "7").reregisterIfUpdated()
        #expect(service.registerCalls == before.0)
        #expect(service.unregisterCalls == before.1)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
    }

    @Test("Autre numéro de compilation : désinscription, réinscription, nouveau numéro retenu")
    func newBuild() async {
        await toggle(true)
        let before = (service.registerCalls, service.unregisterCalls)
        let updated = makeModel(bundleVersion: "8")
        await updated.reregisterIfUpdated()
        #expect(service.unregisterCalls == before.1 + 1)
        #expect(service.registerCalls == before.0 + 1)
        #expect(service.status == .enabled)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "8")
        #expect(updated.lastError == nil)
        #expect(updated.isEnabled)
    }

    @Test("F2 : la réinscription attend la fin de la désinscription (launchd démonte encore l'ancien job) avant d'inscrire")
    func registerWaitsForUnregister() async {
        service.status = .enabled
        settings.strings[TalkbackModel.registeredBuildKey] = "6"
        service.holdUnregister = true
        let task = Task { await model.reregisterIfUpdated() }
        var waited = 0
        while !service.isUnregisterPending, waited < 500 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(service.isUnregisterPending)
        #expect(service.registerCalls == 0)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "6")
        service.finishUnregister()
        await task.value
        #expect(service.unregisterCalls == 1)
        #expect(service.registerCalls == 1)
        #expect(service.status == .enabled)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
    }

    @Test("Pendant la réinscription, l'interrupteur est sans effet : un clic ne la contrarie pas")
    func toggleIgnoredWhileReregistering() async {
        service.status = .enabled
        settings.strings[TalkbackModel.registeredBuildKey] = "6"
        service.holdUnregister = true
        let task = Task { await model.reregisterIfUpdated() }
        var waited = 0
        while !service.isUnregisterPending, waited < 500 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(model.isReregistering)
        model.setEnabled(false)
        #expect(service.unregisterCalls == 1)
        service.finishUnregister()
        await task.value
        #expect(!model.isReregistering)
        #expect(service.status == .enabled)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
        service.holdUnregister = false
        await toggle(false)
        #expect(service.status == .notRegistered)
    }

    @Test("Agent inscrit par une version qui ne retenait rien (la 1.0.2) : réinscription")
    func noRememberedBuild() async {
        service.status = .enabled
        await model.reregisterIfUpdated()
        #expect(service.unregisterCalls == 1)
        #expect(service.registerCalls == 1)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
    }

    @Test("Agent en attente d'accord : réinscrit aussi")
    func requiresApprovalIsRegistered() async {
        service.status = .requiresApproval
        service.statusAfterRegister = .requiresApproval
        await model.reregisterIfUpdated()
        #expect(service.unregisterCalls == 1)
        #expect(service.registerCalls == 1)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
        #expect(model.status == .requiresApproval)
        #expect(model.lastError == nil)
    }

    @Test("Agent non inscrit : rien, même sans numéro retenu")
    func notRegistered() async {
        await model.reregisterIfUpdated()
        #expect(service.unregisterCalls == 0)
        #expect(service.registerCalls == 0)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == nil)
        #expect(model.status == .disabled)
    }

    @Test("Agent introuvable (jamais inscrit) : rien")
    func notFound() async {
        service.status = .notFound
        await model.reregisterIfUpdated()
        #expect(service.unregisterCalls == 0)
        #expect(service.registerCalls == 0)
    }

    @Test("F3 : compilation de travail (numéro 1) : jamais de réinscription, ni depuis une version publiée ni sans numéro retenu")
    func workingBuild() async {
        service.status = .enabled
        settings.strings[TalkbackModel.registeredBuildKey] = "42"
        await makeModel(bundleVersion: "1").reregisterIfUpdated()
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "42")

        settings.strings[TalkbackModel.registeredBuildKey] = nil
        await makeModel(bundleVersion: "1").reregisterIfUpdated()
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == nil)
    }

    @Test("F3 : l'app publiée reprend l'agent qu'une compilation de travail avait inscrit (numéro 1 retenu)")
    func publishedBuildTakesOverFromWorkingBuild() async {
        service.status = .enabled
        settings.strings[TalkbackModel.registeredBuildKey] = "1"
        await makeModel(bundleVersion: "42").reregisterIfUpdated()
        #expect(service.unregisterCalls == 1)
        #expect(service.registerCalls == 1)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "42")
    }

    @Test("Désinscription refusée : erreur affichée, numéro inchangé, une seule tentative")
    func unregisterFails() async {
        service.status = .enabled
        settings.strings[TalkbackModel.registeredBuildKey] = "6"
        service.failure = Refused()
        await model.reregisterIfUpdated()
        #expect(model.lastError == "Talkback impossible : refusé")
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "6")
        #expect(service.unregisterCalls == 1)
        #expect(service.registerCalls == 0)
    }

    @Test("Réinscription refusée : erreur affichée, numéro inchangé, une seule tentative")
    func registerFails() async {
        service.status = .enabled
        settings.strings[TalkbackModel.registeredBuildKey] = "6"
        service.registerFailure = Refused()
        await model.reregisterIfUpdated()
        #expect(model.lastError == "Talkback impossible : refusé")
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "6")
        #expect(service.unregisterCalls == 1)
        #expect(service.registerCalls == 1)
        // Rien n'est retenté ni par le suivi ni par un relevé d'état.
        model.beginWatching()
        scheduler.advance(by: 5)
        #expect(service.unregisterCalls == 1)
        #expect(service.registerCalls == 1)
    }

    @Test("Numéro de compilation inconnu : rien")
    func unknownBuild() async {
        service.status = .enabled
        await makeModel(bundleVersion: nil).reregisterIfUpdated()
        #expect(service.unregisterCalls == 0)
        #expect(service.registerCalls == 0)
    }

    // MARK: - États

    @Test("Agent non inscrit : Désactivé, interrupteur éteint")
    func disabled() {
        #expect(model.status == .disabled)
        #expect(!model.isEnabled)
        #expect(Labels.talkbackStatus(model.status) == "Désactivé")
    }

    @Test("Interrupteur allumé : l'agent est inscrit ; talkd pas encore écrit son état : Démarrage…")
    func registeredStarting() async {
        await toggle(true)
        #expect(model.isEnabled)
        #expect(model.status == .starting)
        #expect(Labels.talkbackStatus(model.status) == "Démarrage…")
    }

    @Test("Inscrit et talkd vivant au repos : Prêt")
    func ready() async {
        await toggle(true)
        state.state = speaking(false)
        process.alive = [4242]
        model.refresh()
        #expect(model.status == .ready)
        #expect(Labels.talkbackStatus(.ready) == "Prêt")
    }

    @Test("Inscrit, talkd vivant et en parole : En lecture")
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

    @Test("macOS demande l'accord de l'utilisateur : Autorisation requise, interrupteur allumé, Réglages ouvrables")
    func requiresApproval() async {
        service.statusAfterRegister = .requiresApproval
        await toggle(true)
        #expect(model.status == .requiresApproval)
        #expect(model.isEnabled)
        #expect(Labels.talkbackStatus(.requiresApproval) == "Autorisation requise")
        #expect(Labels.talkbackApproval == "Autorisez Talkback dans Réglages › Général › Ouverture")
        model.openSystemSettings()
        #expect(service.settingsOpened == 1)
        #expect(model.lastError == nil)
    }

    @Test("« Introuvable » avant toute inscription (réponse habituelle de macOS pour un agent jamais inscrit) : Désactivé, interrupteur utilisable")
    func notFoundBeforeRegister() async {
        service.status = .notFound
        model.refresh()
        #expect(model.status == .disabled)
        #expect(!model.isEnabled)
        service.statusAfterRegister = .enabled
        await toggle(true)
        #expect(service.status == .enabled)
    }

    @Test("Inscription refusée alors que macOS ne trouve pas l'agent : Indisponible")
    func unavailable() async {
        struct Missing: LocalizedError {
            var errorDescription: String? { "introuvable" }
        }
        service.status = .notFound
        service.failure = Missing()
        await toggle(true)
        #expect(model.status == .unavailable)
        #expect(!model.isEnabled)
        #expect(Labels.talkbackStatus(.unavailable) == "Indisponible")
    }

    @Test("Interrupteur éteint : l'agent est désinscrit")
    func unregister() async {
        await toggle(true)
        await toggle(false)
        #expect(service.status == .notRegistered)
        #expect(model.status == .disabled)
    }

    @Test("Inscription refusée : message d'erreur, interrupteur inchangé")
    func failure() async {
        struct Refused: LocalizedError {
            var errorDescription: String? { "refusé" }
        }
        service.failure = Refused()
        await toggle(true)
        #expect(model.status == .disabled)
        #expect(model.lastError == "Talkback impossible : refusé")
        service.failure = nil
        await toggle(true)
        #expect(model.lastError == nil)
    }

    @Test("Refus parce que l'accord manque : pas d'erreur, l'invitation à autoriser suffit")
    func failureWithApproval() async {
        struct Refused: LocalizedError {
            var errorDescription: String? { "Operation not permitted" }
        }
        service.statusAfterRegister = .requiresApproval
        service.failure = Refused()
        service.status = .requiresApproval
        await toggle(true)
        #expect(model.status == .requiresApproval)
        #expect(model.lastError == nil)
    }

    // MARK: - talkd arrêté ou absent

    @Test("Le fichier d'état avec un échec (champ failure) se lit ; sans ce champ, failure vaut nil")
    func failureContract() throws {
        let json = #"{ "failure" : "portBusy", "pid" : 4242, "since" : "2026-10-03T04:00:00Z", "speaking" : false }"#
        let decoded = try TalkbackState.decoder.decode(TalkbackState.self, from: Data(json.utf8))
        #expect(decoded.failure == "portBusy")
        #expect(speaking(false).failure == nil)
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

    @Test("Inscrit mais talkd absent pendant plus de 15 s (depuis le premier Démarrage…) : talkd ne démarre pas")
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
        #expect(Labels.talkbackStatus(.notRunning) == "talkd ne démarre pas (voir le journal)")
    }

    @Test("F4 : réinscrit pendant ce lancement, puis talkd absent au bout de 15 s : l'avis dit d'éteindre puis rallumer Talkback")
    func adviceWhenNotRestartedAfterReregistration() async {
        service.status = .enabled
        settings.strings[TalkbackModel.registeredBuildKey] = "6"
        await model.reregisterIfUpdated()
        #expect(model.lastError == nil)
        model.beginWatching()
        scheduler.advance(by: 14)
        #expect(model.status == .starting)
        #expect(model.lastError == nil)
        scheduler.advance(by: 1)
        #expect(model.status == .notRunning)
        #expect(model.lastError == "Talkback n'a pas redémarré après la mise à jour : éteignez puis rallumez Talkback.")
        model.endWatching()
    }

    @Test("F4 : pas de réinscription dans ce lancement : talkd absent donne « ne démarre pas », sans l'avis")
    func noAdviceWithoutReregistration() async {
        await toggle(true)
        model.beginWatching()
        scheduler.advance(by: 16)
        #expect(model.status == .notRunning)
        #expect(model.lastError == nil)
        model.endWatching()
    }

    @Test("F4 : talkd repart après la réinscription : l'avis n'apparaît pas, ou disparaît s'il était affiché")
    func adviceGoesAwayWhenTalkdRuns() async {
        service.status = .enabled
        settings.strings[TalkbackModel.registeredBuildKey] = "6"
        await model.reregisterIfUpdated()
        scheduler.advance(by: 16)
        model.refresh()
        #expect(model.status == .notRunning)
        #expect(model.lastError != nil)
        state.state = speaking(false)
        process.alive = [4242]
        model.refresh()
        #expect(model.status == .ready)
        #expect(model.lastError == nil)
    }

    @Test("F4 : réinscription refusée : l'erreur du refus reste, l'avis ne la remplace pas")
    func adviceDoesNotReplaceRegisterError() async {
        service.status = .enabled
        settings.strings[TalkbackModel.registeredBuildKey] = "6"
        service.registerFailure = Refused()
        await model.reregisterIfUpdated()
        scheduler.advance(by: 16)
        model.refresh()
        #expect(model.lastError == "Talkback impossible : refusé")
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
        // La relance automatique (au bout de 4 s) grise l'interrupteur jusqu'à sa fin.
        await model.waitForOperation()
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
        service.statusAfterRegister = .requiresApproval
        await toggle(true)
        #expect(model.needsAttention)
    }

    // MARK: - Suivi de l'état pendant que le panneau est ouvert

    @Test("Panneau ouvert : l'état est relu chaque seconde ; fermé, plus rien")
    func watching() async {
        await toggle(true)
        process.alive = [4242]
        state.state = speaking(false)
        // La vérification du démarrage, qui lit aussi l'état, est passée.
        scheduler.advance(by: TalkbackModel.launchCheckDelay)
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

    // MARK: - Inscription hors du fil de l'interface

    /// Attend (jusqu'à 5 s) qu'une condition du faux soit vraie.
    private func waitUntil(_ condition: () -> Bool) async {
        var waited = 0
        while !condition(), waited < 500 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
    }

    @Test("Allumer : l'interrupteur bascule et « Démarrage… » s'affiche tout de suite, l'inscription se fait ensuite")
    func enableReturnsImmediately() async {
        service.holdRegister = true
        model.setEnabled(true)
        #expect(model.isEnabled)
        #expect(model.isBusy)
        #expect(model.status == .starting)
        await waitUntil { service.isRegisterPending }
        #expect(service.isRegisterPending)
        #expect(model.isBusy)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == nil)
        service.finishRegister()
        await model.waitForOperation()
        #expect(!model.isBusy)
        #expect(service.registerCalls == 1)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
        #expect(model.status == .starting)
    }

    @Test("Éteindre : l'interrupteur s'éteint et « Arrêt… » s'affiche tout de suite, la désinscription se fait ensuite")
    func disableReturnsImmediately() async {
        await toggle(true)
        process.alive = [4242]
        state.state = speaking(false)
        model.refresh()
        #expect(model.status == .ready)
        service.holdUnregister = true
        model.setEnabled(false)
        #expect(!model.isEnabled)
        #expect(model.isBusy)
        #expect(model.status == .stopping)
        #expect(!model.needsAttention)
        #expect(Labels.talkbackStatus(model.status) == "Arrêt…")
        await waitUntil { service.isUnregisterPending }
        #expect(service.isUnregisterPending)
        // Le suivi chaque seconde ne remplace pas « Arrêt… » par l'état encore inscrit.
        model.beginWatching()
        scheduler.advance(by: 3)
        #expect(model.status == .stopping)
        service.finishUnregister()
        await model.waitForOperation()
        #expect(model.status == .disabled)
        #expect(!model.isBusy)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == nil)
        model.endWatching()
    }

    @Test("Un second clic pendant l'opération est sans effet")
    func secondClickIgnoredWhileBusy() async {
        service.holdRegister = true
        model.setEnabled(true)
        await waitUntil { service.isRegisterPending }
        model.setEnabled(false)
        #expect(model.status == .starting)
        service.finishRegister()
        await model.waitForOperation()
        #expect(service.unregisterCalls == 0)
        #expect(service.registerCalls == 1)
        #expect(service.status == .enabled)
        // L'opération finie, l'interrupteur répond de nouveau.
        await toggle(false)
        #expect(service.unregisterCalls == 1)
        #expect(model.status == .disabled)
    }

    @Test("Les appels à SMAppService se font hors du fil principal")
    func registrationOffMainThread() async {
        await toggle(true)
        await toggle(false)
        #expect(service.backgroundCallsOnMainThread == [false, false])
    }

    @Test("Inscription refusée : l'interrupteur revient à l'état réel, l'erreur est montrée, le bouton se libère")
    func asyncRegisterFailure() async {
        service.failure = Refused()
        model.setEnabled(true)
        #expect(model.status == .starting)
        await model.waitForOperation()
        #expect(model.status == .disabled)
        #expect(!model.isEnabled)
        #expect(!model.isBusy)
        #expect(model.lastError == "Talkback impossible : refusé")
    }

    @Test("Désinscription refusée : l'interrupteur revient à l'état réel (toujours inscrit), l'erreur est montrée")
    func asyncUnregisterFailure() async {
        await toggle(true)
        service.failure = Refused()
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
        service.failure = Refused()
        await toggle(true)
        #expect(model.lastError != nil)
        service.failure = nil
        service.holdRegister = true
        model.setEnabled(true)
        #expect(model.lastError == nil)
        await waitUntil { service.isRegisterPending }
        service.finishRegister()
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
        service.status = .enabled
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
        service.status = .enabled
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

    // MARK: - Relance quand talkd ne démarre pas après une inscription

    // Banc du 12/10 : après tout changement du binaire talkd, la première inscription reprend l'ancienne fiche de BTM
    // et launchd refuse talkd (« Launch Constraint Violation ») ; désinscrire puis réinscrire le fait démarrer.

    @Test("talkd démarré à temps : aucune relance")
    func noRetryWhenTalkdStarts() async {
        await toggle(true)
        process.alive = [4242]
        state.state = speaking(false)
        scheduler.advance(by: TalkbackModel.launchCheckDelay + 1)
        await model.waitForOperation()
        #expect(service.registerCalls == 1)
        #expect(service.unregisterCalls == 0)
        #expect(!model.isReregistering)
    }

    @Test("talkd absent 4 s après l'inscription : désinscription puis réinscription, une seule fois")
    func retryOnceWhenTalkdDoesNotStart() async {
        await toggle(true)
        #expect(TalkbackModel.launchCheckDelay == 4)
        scheduler.advance(by: 3.9)
        #expect(!model.isReregistering)
        #expect(service.unregisterCalls == 0)
        scheduler.advance(by: 0.1)
        #expect(model.isReregistering)
        await model.waitForOperation()
        #expect(service.unregisterCalls == 1)
        #expect(service.registerCalls == 2)
        #expect(service.status == .enabled)
        #expect(!model.isReregistering)
        #expect(model.status == .starting)
        #expect(model.lastError == nil)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
        // La relance ne s'arme pas elle-même : pas de boucle.
        scheduler.advance(by: 20)
        await model.waitForOperation()
        #expect(service.registerCalls == 2)
        #expect(service.unregisterCalls == 1)
    }

    @Test("Pendant la relance : « Démarrage… » (jamais « Désactivé »), interrupteur grisé et sans effet")
    func retryShowsStartingAndLocksToggle() async {
        await toggle(true)
        service.holdRegister = true
        scheduler.advance(by: TalkbackModel.launchCheckDelay)
        await waitUntil { service.isRegisterPending }
        #expect(service.status == .notRegistered)
        model.refresh()
        #expect(model.status == .starting)
        #expect(model.isEnabled)
        #expect(model.isReregistering)
        model.setEnabled(false)
        #expect(service.unregisterCalls == 1)
        service.finishRegister()
        await model.waitForOperation()
        #expect(service.registerCalls == 2)
        #expect(service.status == .enabled)
    }

    @Test("Éteint avant 4 s : aucune relance")
    func noRetryAfterDisable() async {
        await toggle(true)
        scheduler.advance(by: 1)
        await toggle(false)
        scheduler.advance(by: TalkbackModel.launchCheckDelay + 1)
        await model.waitForOperation()
        #expect(service.registerCalls == 1)
        #expect(service.unregisterCalls == 1)
        #expect(service.status == .notRegistered)
    }

    @Test("Rallumé avant 4 s : une seule vérification, comptée depuis la dernière inscription")
    func checkRestartsOnNewToggle() async {
        await toggle(true)
        scheduler.advance(by: 2)
        await toggle(false)
        await toggle(true)
        scheduler.advance(by: 3)
        await model.waitForOperation()
        #expect(service.registerCalls == 2)
        scheduler.advance(by: 1)
        await model.waitForOperation()
        #expect(service.registerCalls == 3)
        #expect(service.unregisterCalls == 2)
    }

    @Test("Après la réinscription d'une mise à jour : même relance si talkd ne démarre pas")
    func retryAfterUpdateReregistration() async {
        service.status = .enabled
        settings.strings[TalkbackModel.registeredBuildKey] = "6"
        await model.reregisterIfUpdated()
        #expect(service.registerCalls == 1)
        scheduler.advance(by: TalkbackModel.launchCheckDelay)
        await model.waitForOperation()
        #expect(service.unregisterCalls == 2)
        #expect(service.registerCalls == 2)
        #expect(service.status == .enabled)
        #expect(!model.isReregistering)
    }

    @Test("Relance refusée : l'erreur est montrée, l'état réel relu, rien n'est retenté")
    func retryRefused() async {
        await toggle(true)
        service.registerFailure = Refused()
        scheduler.advance(by: TalkbackModel.launchCheckDelay)
        await model.waitForOperation()
        #expect(service.registerCalls == 2)
        #expect(model.lastError == "Talkback impossible : refusé")
        #expect(model.status == .disabled)
        #expect(!model.isReregistering)
        scheduler.advance(by: 20)
        await model.waitForOperation()
        #expect(service.registerCalls == 2)
    }

    @Test("Autorisation requise ou talkd arrêté sur un échec : pas de relance")
    func noRetryWhenApprovalOrFailure() async {
        service.statusAfterRegister = .requiresApproval
        await toggle(true)
        scheduler.advance(by: TalkbackModel.launchCheckDelay + 1)
        await model.waitForOperation()
        #expect(service.registerCalls == 1)
        await toggle(false)
        service.statusAfterRegister = .enabled
        await toggle(true)
        state.state = TalkbackState(speaking: false, since: Date(), pid: 4242, failure: "portBusy")
        scheduler.advance(by: TalkbackModel.launchCheckDelay + 1)
        await model.waitForOperation()
        #expect(service.registerCalls == 2)
        #expect(service.unregisterCalls == 1)
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
        #expect(Labels.talkbackStatus(.unavailable) == "Unavailable")
        #expect(Labels.talkbackApproval == "Allow Talkback in System Settings › General › Login Items")
        #expect(Labels.talkbackStatus(.failed(.portBusy)) == "Stopped: the UDP port is already in use (see the log)")
        #expect(Labels.talkbackStatus(.failed(.socket)) == "Stopped: network error (see the log)")
        #expect(Labels.talkbackStatus(.failed(.other)) == "Stopped (see the log)")
        #expect(Labels.talkbackStatus(.notRunning) == "talkd is not starting (see the log)")
        #expect(Labels.talkbackRestartAdvice == "Talkback did not restart after the update: turn Talkback off and on again.")
    }
}
