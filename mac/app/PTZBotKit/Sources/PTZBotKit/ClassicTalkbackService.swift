import Foundation
import ServiceManagement

/// Ce que l'app demande à `ServiceManagement`, derrière un protocole pour les tests : l'ancien agent de la 1.0.4 (à
/// désinscrire) et l'état de la plist classique dans Réglages › Général › Ouverture. Hors du MainActor, comme les
/// appels bloquants qui s'en servent.
public protocol SMAgentRegistry: Sendable {
    /// L'état de l'agent inscrit par la 1.0.4 : `SMAppService.agent(plistName:)`.
    func registeredStatus() -> SMAppService.Status
    /// Le désinscrit en attendant que launchd ait fini de le démonter (`unregister()` asynchrone, `SMAppService.h`).
    func unregisterAndWait() async throws
    /// L'état d'une plist classique de `~/Library/LaunchAgents` : `.requiresApproval` si l'utilisateur a coupé l'élément
    /// dans Réglages › Général › Ouverture.
    func plistStatus(at url: URL) -> SMAppService.Status
}

/// Implémentation réelle : `SMAppService`.
public struct SystemSMAgentRegistry: SMAgentRegistry {
    public init() {}

    public func registeredStatus() -> SMAppService.Status {
        SMAppService.agent(plistName: Talkback.plistName).status
    }

    public func unregisterAndWait() async throws {
        try await SMAppService.agent(plistName: Talkback.plistName).unregister()
    }

    public func plistStatus(at url: URL) -> SMAppService.Status {
        SMAppService.statusForLegacyPlist(at: url)
    }
}

/// L'agent de Talkback pour l'app : un `ClassicAgent` (plist et `launchctl`) et, pour la migration depuis la 1.0.4,
/// `ServiceManagement`. Les opérations qui bloquent tournent sur une file de fond (`Blocking`), jamais sur le fil de
/// l'interface ; le travail lui-même est dans les types non isolés `ClassicAgent` et `SMAgentRegistry`.
@MainActor
public final class ClassicTalkbackService: TalkbackService {
    private let agent: ClassicAgent
    private let registry: any SMAgentRegistry

    public init(agent: ClassicAgent, registry: any SMAgentRegistry) {
        self.agent = agent
        self.registry = registry
    }

    /// Le service de l'app : l'agent de talkd (`Contents/Helpers/talkd` de l'app qui tourne) dans le vrai
    /// `~/Library/LaunchAgents`. Pour l'app seulement ; les tests passent leurs doublures.
    public static func system(program: URL) -> ClassicTalkbackService {
        ClassicTalkbackService(agent: .system(program: program), registry: SystemSMAgentRegistry())
    }

    public var agentState: TalkbackAgentState {
        guard agent.plistExists else { return .absent }
        return registry.plistStatus(at: agent.plistURL) == .requiresApproval ? .requiresApproval : .installed
    }

    public var installBlocker: (any Error)? {
        agent.isTransient ? ClassicAgentError.transientLocation : nil
    }

    public var hasLegacyRegistration: Bool {
        let status = registry.registeredStatus()
        return status == .enabled || status == .requiresApproval
    }

    public var legacyRequiresApproval: Bool {
        registry.registeredStatus() == .requiresApproval
    }

    public nonisolated func enable() async throws {
        let agent = agent
        try await Blocking.run { try agent.install() }
    }

    public nonisolated func disable() async throws {
        let agent = agent
        try await Blocking.run { try agent.uninstall() }
    }

    public nonisolated func unregisterLegacy() async throws {
        do {
            try await registry.unregisterAndWait()
        } catch let error as NSError where error.code == Self.foreignJobErrorCode {
            // Le job de ce label a été chargé par `launchctl` (l'agent classique), pas par SMAppService : il n'y a plus
            // d'ancien agent à désinscrire (banc du 12/10).
        }
    }

    /// launchd refuse à SMAppService de retirer un job qu'il n'a pas créé : « Requestor lacks required entitlement ».
    nonisolated static let foreignJobErrorCode = 144

    public nonisolated func reconcile(restart: Bool) async throws {
        let agent = agent
        try await Blocking.run { try agent.reconcile(restart: restart) }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
