import Foundation
import ServiceManagement
import Synchronization
import Testing
@testable import PTZBotKit

/// `ServiceManagement` simulé : l'ancien agent de la 1.0.4 et l'état de la plist classique dans Réglages › Ouverture.
final class FakeSMRegistry: SMAgentRegistry {
    struct Failure: LocalizedError {
        var errorDescription: String? { "refusé" }
    }

    struct State {
        var registered: SMAppService.Status = .notFound
        var plistStatus: SMAppService.Status = .notRegistered
        var unregisterFails = false
        /// Une erreur précise à lever à la désinscription (code de launchd).
        var unregisterError: NSError?
        var unregisters = 0
    }

    let state = Mutex(State())

    func registeredStatus() -> SMAppService.Status {
        state.withLock { $0.registered }
    }

    func unregisterAndWait() async throws {
        try state.withLock { state in
            state.unregisters += 1
            if state.unregisterFails { throw Failure() }
            if let error = state.unregisterError { throw error }
            state.registered = .notRegistered
        }
    }

    func plistStatus(at url: URL) -> SMAppService.Status {
        state.withLock { $0.plistStatus }
    }
}

/// Le service réel de l'app (`ClassicTalkbackService`), sur un dossier temporaire, un `launchctl` et un `ServiceManagement`
/// simulés : jamais le vrai `~/Library/LaunchAgents`, jamais le vrai `launchctl`.
@MainActor
@Suite("Service de Talkback (agent classique)", .french, .timeLimit(.minutes(1)))
struct ClassicTalkbackServiceTests {
    let root: URL
    let launchctl = FakeLaunchctl()
    let registry = FakeSMRegistry()
    let service: ClassicTalkbackService
    let plistURL: URL
    let settings = FakeSettings()
    let scheduler = FakeScheduler()

    init() throws {
        root = try FakeSDK.directory()
        let agent = ClassicAgent(
            label: Talkback.label,
            launchAgentsDirectory: root.appending(path: "LaunchAgents"),
            program: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/talkd"),
            launchctl: launchctl,
            sleep: { _ in }
        )
        plistURL = agent.plistURL
        service = ClassicTalkbackService(agent: agent, registry: registry)
    }

    private func model(bundleVersion: String) -> TalkbackModel {
        TalkbackModel(
            service: service, state: FakeTalkbackState(), process: FakeProcessProbe(), scheduler: scheduler,
            settings: settings, bundleVersion: bundleVersion
        )
    }

    private func calls() -> [String] {
        launchctl.state.withLock { $0.calls }
    }

    @Test("État de l'agent : absent sans plist, installé avec, autorisation requise si l'utilisateur a coupé l'élément")
    func agentState() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        registry.state.withLock { $0.plistStatus = .requiresApproval }
        // Sans plist, ce que dit ServiceManagement ne compte pas.
        #expect(service.agentState == .absent)
        try await service.enable()
        #expect(service.agentState == .requiresApproval)
        registry.state.withLock { $0.plistStatus = .enabled }
        #expect(service.agentState == .installed)
        registry.state.withLock { $0.plistStatus = .notFound }
        #expect(service.agentState == .installed)
    }

    @Test("Ancien agent de la 1.0.4 : présent s'il est actif ou en attente d'accord, absent sinon")
    func legacyRegistration() {
        defer { try? FileManager.default.removeItem(at: root) }
        for (status, expected) in [
            (SMAppService.Status.enabled, true), (.requiresApproval, true), (.notRegistered, false), (.notFound, false),
        ] {
            registry.state.withLock { $0.registered = status }
            #expect(service.hasLegacyRegistration == expected)
        }
    }

    @Test("Allumer écrit la plist et charge l'agent ; éteindre le décharge et supprime la plist")
    func enableDisable() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.enable()
        #expect(FileManager.default.fileExists(atPath: plistURL.path))
        #expect(calls() == ["enable", "bootstrap"])
        try await service.disable()
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
        #expect(calls() == ["enable", "bootstrap", "bootout"])
        #expect(service.agentState == .absent)
    }

    @Test("Emplacement temporaire : l'allumage est bloqué (installBlocker), rien n'est écrit ; sinon aucun blocage")
    func transientBlocker() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.installBlocker == nil)
        let transient = ClassicAgent(
            label: Talkback.label,
            launchAgentsDirectory: root.appending(path: "LaunchAgents"),
            program: URL(fileURLWithPath: "/private/var/folders/ab/xyz/T/AppTranslocation/ABCD/d/PTZBot.app/Contents/Helpers/talkd"),
            launchctl: launchctl,
            sleep: { _ in }
        )
        let blocked = ClassicTalkbackService(agent: transient, registry: registry)
        #expect(blocked.installBlocker as? ClassicAgentError == .transientLocation)
        await #expect(throws: ClassicAgentError.transientLocation) { try await blocked.enable() }
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
        #expect(calls() == [])
    }

    @Test("Désinscrire l'ancien agent : l'erreur 144 de launchd (job chargé par launchctl, pas par SMAppService) dit la migration déjà faite")
    func unregisterLegacyForeignJob() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        registry.state.withLock { $0.registered = .requiresApproval; $0.unregisterError = NSError(domain: "SMAppServiceErrorDomain", code: 144) }
        await #expect(throws: LegacyAlreadyMigrated.self) { try await service.unregisterLegacy() }
        registry.state.withLock { $0.unregisterError = NSError(domain: "SMAppServiceErrorDomain", code: 1) }
        await #expect(throws: NSError.self) { try await service.unregisterLegacy() }
    }

    @Test("Désinscrire l'ancien agent passe par ServiceManagement ; un refus remonte")
    func unregisterLegacy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        registry.state.withLock { $0.registered = .enabled }
        try await service.unregisterLegacy()
        #expect(registry.state.withLock { $0.unregisters } == 1)
        #expect(!service.hasLegacyRegistration)
        registry.state.withLock { $0.registered = .enabled; $0.unregisterFails = true }
        await #expect(throws: FakeSMRegistry.Failure.self) { try await service.unregisterLegacy() }
        #expect(service.hasLegacyRegistration)
    }

    @Test("De bout en bout, migration depuis la 1.0.4 : désinscription, plist écrite, agent chargé, numéro retenu")
    func fullMigration() async {
        defer { try? FileManager.default.removeItem(at: root) }
        registry.state.withLock { $0.registered = .enabled }
        settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] = "8"
        let model = model(bundleVersion: "9")
        await model.prepareAtLaunch()
        #expect(registry.state.withLock { $0.unregisters } == 1)
        #expect(calls() == ["enable", "bootstrap"])
        #expect(FileManager.default.fileExists(atPath: plistURL.path))
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "9")
        #expect(model.lastError == nil)
        #expect(model.status == .starting)
    }

    @Test("De bout en bout, migration d'un agent « Autorisation requise » : désinscrit, rien d'écrit, aucun appel à launchctl")
    func fullMigrationLeavesRefusalOff() async {
        defer { try? FileManager.default.removeItem(at: root) }
        registry.state.withLock { $0.registered = .requiresApproval }
        settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] = "8"
        launchctl.state.withLock { $0.disabled = true }
        let model = model(bundleVersion: "9")
        await model.prepareAtLaunch()
        #expect(registry.state.withLock { $0.unregisters } == 1)
        #expect(calls() == [])
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
        #expect(model.status == .disabled)
        #expect(model.lastError == nil)
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
        #expect(launchctl.state.withLock { $0.disabled && !$0.loaded })
    }

    @Test("De bout en bout, migration d'un agent actif dont le service est désactivé dans launchd : enable puis bootstrap")
    func fullMigrationEnabledButDisabledService() async {
        defer { try? FileManager.default.removeItem(at: root) }
        registry.state.withLock { $0.registered = .enabled }
        settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] = "8"
        launchctl.state.withLock { $0.disabled = true }
        let model = model(bundleVersion: "9")
        await model.prepareAtLaunch()
        #expect(calls() == ["enable", "bootstrap"])
        #expect(launchctl.state.withLock { $0.loaded })
        #expect(model.lastError == nil)
    }

    @Test("De bout en bout, installation en échec après la désinscription : l'intention est retenue et retentée au lancement suivant")
    func fullMigrationRetried() async {
        defer { try? FileManager.default.removeItem(at: root) }
        registry.state.withLock { $0.registered = .enabled }
        settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] = "8"
        launchctl.state.withLock { $0.bootstrapFails = true }
        await model(bundleVersion: "9").prepareAtLaunch()
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == "enable")
        #expect(settings.strings[TalkbackModel.agentBuildKey] == nil)
        launchctl.state.withLock { $0.bootstrapFails = false; $0.calls = [] }
        let next = model(bundleVersion: "9")
        await next.prepareAtLaunch()
        #expect(calls() == ["enable", "bootstrap"])
        #expect(FileManager.default.fileExists(atPath: plistURL.path))
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "9")
        #expect(next.lastError == nil)
    }

    @Test("De bout en bout, migration : désinscription refusée, rien n'est installé ni chargé")
    func fullMigrationRefused() async {
        defer { try? FileManager.default.removeItem(at: root) }
        registry.state.withLock { $0.registered = .enabled; $0.unregisterFails = true }
        settings.strings[TalkbackModel.obsoleteRegisteredBuildKey] = "8"
        let model = model(bundleVersion: "9")
        await model.prepareAtLaunch()
        #expect(calls() == [])
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
        #expect(model.lastError == "Talkback impossible : refusé")
    }

    @Test("De bout en bout, sans le réglage de la 1.0.4 et SMAppService qui répond « inscrit » (banc du 12/10) : rien n'est désinscrit, installé ni chargé")
    func fullNoMigrationWithoutOldSetting() async {
        defer { try? FileManager.default.removeItem(at: root) }
        registry.state.withLock { $0.registered = .enabled }
        let model = model(bundleVersion: "9")
        await model.prepareAtLaunch()
        #expect(registry.state.withLock { $0.unregisters } == 0)
        #expect(calls() == [])
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
        #expect(settings.strings[TalkbackModel.pendingInstallKey] == nil)
        #expect(model.lastError == nil)
        #expect(model.status == .disabled)
    }

    @Test("De bout en bout, migration avec Talkback éteint : aucune plist, aucun appel à launchctl")
    func fullMigrationOff() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(bundleVersion: "9")
        await model.prepareAtLaunch()
        #expect(calls() == [])
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
        #expect(model.status == .disabled)
    }

    @Test("De bout en bout, mise à jour : même numéro, rien ; nouveau numéro, kickstart")
    func fullUpdate() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.enable()
        launchctl.state.withLock { $0.calls = [] }
        settings.strings[TalkbackModel.agentBuildKey] = "9"
        await model(bundleVersion: "9").prepareAtLaunch()
        #expect(calls() == [])
        await model(bundleVersion: "10").prepareAtLaunch()
        #expect(calls() == ["kickstart"])
        #expect(settings.strings[TalkbackModel.agentBuildKey] == "10")
    }

    @Test("De bout en bout, mise à jour : l'app a changé de chemin, la plist est réécrite et rechargée")
    func fullUpdateMovedApp() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.enable()
        launchctl.state.withLock { $0.calls = [] }
        let moved = ClassicAgent(
            label: Talkback.label,
            launchAgentsDirectory: root.appending(path: "LaunchAgents"),
            program: URL(fileURLWithPath: "/Applications/Ailleurs/PTZBot.app/Contents/Helpers/talkd"),
            launchctl: launchctl,
            sleep: { _ in }
        )
        let movedModel = TalkbackModel(
            service: ClassicTalkbackService(agent: moved, registry: registry), state: FakeTalkbackState(),
            process: FakeProcessProbe(), scheduler: scheduler, settings: settings, bundleVersion: "9"
        )
        settings.strings[TalkbackModel.agentBuildKey] = "9"
        await movedModel.prepareAtLaunch()
        #expect(calls() == ["bootout", "bootstrap"])
    }
}
