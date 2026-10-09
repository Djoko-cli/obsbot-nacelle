import Foundation
import ServiceManagement
import Testing
@testable import PTZBotKit

@MainActor
@Suite("Talkback", .french)
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
    func switchRemembersBuild() {
        model.setEnabled(true)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
        model.setEnabled(false)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == nil)
    }

    @Test("Inscription refusée par l'interrupteur : aucun numéro retenu")
    func failedSwitchKeepsNoBuild() {
        service.failure = Refused()
        model.setEnabled(true)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == nil)
    }

    @Test("Désinscription refusée par l'interrupteur : le numéro retenu reste")
    func failedUnregisterKeepsBuild() {
        model.setEnabled(true)
        service.failure = Refused()
        model.setEnabled(false)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
    }

    @Test("Même numéro de compilation qu'à l'inscription : rien n'est touché")
    func sameBuild() {
        model.setEnabled(true)
        let before = (service.registerCalls, service.unregisterCalls)
        makeModel(bundleVersion: "7").reregisterIfUpdated()
        #expect(service.registerCalls == before.0)
        #expect(service.unregisterCalls == before.1)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
    }

    @Test("Autre numéro de compilation : désinscription, réinscription, nouveau numéro retenu")
    func newBuild() {
        model.setEnabled(true)
        let before = (service.registerCalls, service.unregisterCalls)
        let updated = makeModel(bundleVersion: "8")
        updated.reregisterIfUpdated()
        #expect(service.unregisterCalls == before.1 + 1)
        #expect(service.registerCalls == before.0 + 1)
        #expect(service.status == .enabled)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "8")
        #expect(updated.lastError == nil)
        #expect(updated.isEnabled)
    }

    @Test("Agent inscrit par une version qui ne retenait rien (la 1.0.2) : réinscription")
    func noRememberedBuild() {
        service.status = .enabled
        model.reregisterIfUpdated()
        #expect(service.unregisterCalls == 1)
        #expect(service.registerCalls == 1)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
    }

    @Test("Agent en attente d'accord : réinscrit aussi")
    func requiresApprovalIsRegistered() {
        service.status = .requiresApproval
        service.statusAfterRegister = .requiresApproval
        model.reregisterIfUpdated()
        #expect(service.unregisterCalls == 1)
        #expect(service.registerCalls == 1)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "7")
        #expect(model.status == .requiresApproval)
        #expect(model.lastError == nil)
    }

    @Test("Agent non inscrit : rien, même sans numéro retenu")
    func notRegistered() {
        model.reregisterIfUpdated()
        #expect(service.unregisterCalls == 0)
        #expect(service.registerCalls == 0)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == nil)
        #expect(model.status == .disabled)
    }

    @Test("Agent introuvable (jamais inscrit) : rien")
    func notFound() {
        service.status = .notFound
        model.reregisterIfUpdated()
        #expect(service.unregisterCalls == 0)
        #expect(service.registerCalls == 0)
    }

    @Test("Compilation de travail (numéro 1) : rien si 1 est déjà retenu ; réinscrit en venant d'une version publiée, et inversement")
    func workingBuild() {
        settings.strings[TalkbackModel.registeredBuildKey] = "1"
        service.status = .enabled
        makeModel(bundleVersion: "1").reregisterIfUpdated()
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)

        settings.strings[TalkbackModel.registeredBuildKey] = "42"
        makeModel(bundleVersion: "1").reregisterIfUpdated()
        #expect(service.registerCalls == 1)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "1")

        makeModel(bundleVersion: "42").reregisterIfUpdated()
        #expect(service.registerCalls == 2)
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "42")
    }

    @Test("Désinscription refusée : erreur affichée, numéro inchangé, une seule tentative")
    func unregisterFails() {
        service.status = .enabled
        settings.strings[TalkbackModel.registeredBuildKey] = "6"
        service.failure = Refused()
        model.reregisterIfUpdated()
        #expect(model.lastError == "Talkback impossible : refusé")
        #expect(settings.strings[TalkbackModel.registeredBuildKey] == "6")
        #expect(service.unregisterCalls == 1)
        #expect(service.registerCalls == 0)
    }

    @Test("Réinscription refusée : erreur affichée, numéro inchangé, une seule tentative")
    func registerFails() {
        service.status = .enabled
        settings.strings[TalkbackModel.registeredBuildKey] = "6"
        service.registerFailure = Refused()
        model.reregisterIfUpdated()
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
    func unknownBuild() {
        service.status = .enabled
        makeModel(bundleVersion: nil).reregisterIfUpdated()
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
    func registeredStarting() {
        model.setEnabled(true)
        #expect(model.isEnabled)
        #expect(model.status == .starting)
        #expect(Labels.talkbackStatus(model.status) == "Démarrage…")
    }

    @Test("Inscrit et talkd vivant au repos : Prêt")
    func ready() {
        model.setEnabled(true)
        state.state = speaking(false)
        process.alive = [4242]
        model.refresh()
        #expect(model.status == .ready)
        #expect(Labels.talkbackStatus(.ready) == "Prêt")
    }

    @Test("Inscrit, talkd vivant et en parole : En lecture")
    func playing() {
        model.setEnabled(true)
        state.state = speaking(true)
        process.alive = [4242]
        model.refresh()
        #expect(model.status == .playing)
        #expect(Labels.talkbackStatus(.playing) == "En lecture")
    }

    @Test("L'état d'un talkd qui n'existe plus est ignoré, même « en lecture » : Démarrage…")
    func staleState() {
        model.setEnabled(true)
        state.state = speaking(true)
        process.alive = []
        model.refresh()
        #expect(model.status == .starting)
    }

    @Test("macOS demande l'accord de l'utilisateur : Autorisation requise, interrupteur allumé, Réglages ouvrables")
    func requiresApproval() {
        service.statusAfterRegister = .requiresApproval
        model.setEnabled(true)
        #expect(model.status == .requiresApproval)
        #expect(model.isEnabled)
        #expect(Labels.talkbackStatus(.requiresApproval) == "Autorisation requise")
        #expect(Labels.talkbackApproval == "Autorisez Talkback dans Réglages › Général › Ouverture")
        model.openSystemSettings()
        #expect(service.settingsOpened == 1)
        #expect(model.lastError == nil)
    }

    @Test("« Introuvable » avant toute inscription (réponse habituelle de macOS pour un agent jamais inscrit) : Désactivé, interrupteur utilisable")
    func notFoundBeforeRegister() {
        service.status = .notFound
        model.refresh()
        #expect(model.status == .disabled)
        #expect(!model.isEnabled)
        service.statusAfterRegister = .enabled
        model.setEnabled(true)
        #expect(service.status == .enabled)
    }

    @Test("Inscription refusée alors que macOS ne trouve pas l'agent : Indisponible")
    func unavailable() {
        struct Missing: LocalizedError {
            var errorDescription: String? { "introuvable" }
        }
        service.status = .notFound
        service.failure = Missing()
        model.setEnabled(true)
        #expect(model.status == .unavailable)
        #expect(!model.isEnabled)
        #expect(Labels.talkbackStatus(.unavailable) == "Indisponible")
    }

    @Test("Interrupteur éteint : l'agent est désinscrit")
    func unregister() {
        model.setEnabled(true)
        model.setEnabled(false)
        #expect(service.status == .notRegistered)
        #expect(model.status == .disabled)
    }

    @Test("Inscription refusée : message d'erreur, interrupteur inchangé")
    func failure() {
        struct Refused: LocalizedError {
            var errorDescription: String? { "refusé" }
        }
        service.failure = Refused()
        model.setEnabled(true)
        #expect(model.status == .disabled)
        #expect(model.lastError == "Talkback impossible : refusé")
        service.failure = nil
        model.setEnabled(true)
        #expect(model.lastError == nil)
    }

    @Test("Refus parce que l'accord manque : pas d'erreur, l'invitation à autoriser suffit")
    func failureWithApproval() {
        struct Refused: LocalizedError {
            var errorDescription: String? { "Operation not permitted" }
        }
        service.statusAfterRegister = .requiresApproval
        service.failure = Refused()
        service.status = .requiresApproval
        model.setEnabled(true)
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
    func failedPortBusy() {
        model.setEnabled(true)
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
    func failedWhileExiting() {
        model.setEnabled(true)
        state.state = TalkbackState(speaking: false, since: Date(timeIntervalSince1970: 1_791_000_000), pid: 4242, failure: "socket")
        process.alive = [4242]
        model.refresh()
        #expect(model.status == .failed(.socket))
    }

    @Test("Inscrit mais talkd absent pendant plus de 15 s (depuis le premier Démarrage…) : talkd ne démarre pas")
    func notRunning() {
        model.setEnabled(true)
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

    @Test("talkd réécrit son état : retour à Prêt, et le délai de 15 s repart de zéro la fois suivante")
    func backToReady() {
        model.setEnabled(true)
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
    func notRunningResetsWhenDisabled() {
        model.setEnabled(true)
        scheduler.advance(by: 20)
        model.setEnabled(false)
        #expect(model.status == .disabled)
        model.setEnabled(true)
        #expect(model.status == .starting)
    }

    @Test("Panneau ouvert : « ne démarre pas » arrive tout seul au bout de 15 s, par le suivi chaque seconde")
    func notRunningWhileWatching() {
        model.setEnabled(true)
        model.beginWatching()
        scheduler.advance(by: 16)
        #expect(model.status == .notRunning)
        model.endWatching()
    }

    @Test("Autorisation requise : attire l'attention (orange) ; Prêt et En lecture, non")
    func attention() {
        service.statusAfterRegister = .requiresApproval
        model.setEnabled(true)
        #expect(model.needsAttention)
    }

    // MARK: - Suivi de l'état pendant que le panneau est ouvert

    @Test("Panneau ouvert : l'état est relu chaque seconde ; fermé, plus rien")
    func watching() {
        model.setEnabled(true)
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

    // MARK: - Textes

    @Test("Textes en anglais : chaque état et l'invitation à autoriser", .english)
    func english() {
        #expect(Labels.talkbackStatus(.disabled) == "Disabled")
        #expect(Labels.talkbackStatus(.requiresApproval) == "Authorization required")
        #expect(Labels.talkbackStatus(.playing) == "Playing")
        #expect(Labels.talkbackStatus(.ready) == "Ready")
        #expect(Labels.talkbackStatus(.starting) == "Starting…")
        #expect(Labels.talkbackStatus(.unavailable) == "Unavailable")
        #expect(Labels.talkbackApproval == "Allow Talkback in System Settings › General › Login Items")
        #expect(Labels.talkbackStatus(.failed(.portBusy)) == "Stopped: the UDP port is already in use (see the log)")
        #expect(Labels.talkbackStatus(.failed(.socket)) == "Stopped: network error (see the log)")
        #expect(Labels.talkbackStatus(.failed(.other)) == "Stopped (see the log)")
        #expect(Labels.talkbackStatus(.notRunning) == "talkd is not starting (see the log)")
    }
}
