import Foundation
import Observation
import ServiceManagement

/// L'inscription de l'app à l'ouverture de session (spec app Mac § 8.5), derrière un protocole pour les tests.
@MainActor
public protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// Implémentation réelle : `SMAppService.mainApp`.
@MainActor
public final class MainAppLoginItem: LoginItemService {
    public init() {}

    public var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// La case « Ouvrir à la connexion ».
@MainActor
@Observable
public final class LoginItemModel {
    public private(set) var isEnabled = false
    /// macOS attend l'accord de l'utilisateur dans Réglages › Général › Ouverture.
    public private(set) var needsApproval = false
    public private(set) var lastError: String?
    @ObservationIgnored private let service: any LoginItemService

    public init(service: any LoginItemService) {
        self.service = service
        refresh()
    }

    public func refresh() {
        isEnabled = service.status == .enabled || service.status == .requiresApproval
        needsApproval = service.status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            lastError = Localization.text("Ouverture à la connexion impossible : \(error.localizedDescription)")
        }
        refresh()
    }

    public func openSystemSettings() {
        service.openSystemSettings()
    }
}
