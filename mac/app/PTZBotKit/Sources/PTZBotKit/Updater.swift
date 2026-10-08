import Foundation
import Observation

/// Les mises à jour de l'app (spec distribution § 8), derrière un protocole : Sparkle dans l'app, rien ailleurs.
@MainActor
public protocol Updater: AnyObject {
    /// « Rechercher les mises à jour… » : la recherche, avec la fenêtre de Sparkle.
    func checkForUpdates()
    /// « Rechercher automatiquement » : au lancement, puis toutes les 24 h.
    var automaticallyChecks: Bool { get set }
    /// « Installer automatiquement » : téléchargée en silence, installée à la fermeture.
    var automaticallyDownloads: Bool { get set }
    /// Une recherche peut être lancée maintenant (aucune en cours).
    var canCheck: Bool { get }
    /// `handler` reçoit la valeur de `canCheck` tout de suite, puis à chaque changement (KVO de Sparkle).
    func observeCanCheck(_ handler: @escaping @MainActor (Bool) -> Void)
}

/// Pas de mises à jour : sous les tests et dans une compilation de travail (numéro de compilation 1).
@MainActor
public final class NoUpdater: Updater {
    public init() {}

    public func checkForUpdates() {}

    public var automaticallyChecks: Bool {
        get { false }
        set {}
    }

    public var automaticallyDownloads: Bool {
        get { false }
        set {}
    }

    public var canCheck: Bool {
        false
    }

    public func observeCanCheck(_ handler: @escaping @MainActor (Bool) -> Void) {
        handler(false)
    }
}

/// Quand Sparkle démarre (spec distribution § 8) : au lancement d'une app publiée, jamais sous les tests ni dans une
/// compilation de travail.
public enum UpdaterPolicy {
    /// Le numéro de compilation d'une compilation de travail ; la publication donne le nombre de commits de `main`.
    public static let workBuildVersion = "1"

    /// Les variables que pose XCTest dans un processus de tests.
    static let testEnvironmentKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]

    /// Vrai pour une app publiée : un numéro de compilation entier supérieur à 1, hors de tout processus de tests.
    public static func usesSparkle(bundleVersion: String?, environment: [String: String]) -> Bool {
        guard let bundleVersion, let number = Int(bundleVersion), number > 1 else { return false }
        return !testEnvironmentKeys.contains { environment[$0] != nil }
    }
}

/// La fenêtre « Réglages » (spec distribution § 8) : les deux cases de Sparkle, « Ouvrir à la connexion » et la
/// version.
@MainActor
@Observable
public final class SettingsModel {
    public private(set) var automaticallyChecks: Bool
    public private(set) var automaticallyDownloads: Bool
    /// Sparkle peut lancer une recherche maintenant ; suivi en direct (aucune recherche en cours).
    public private(set) var canCheck = false
    /// Les mises à jour sont actives (app publiée) ; sinon les deux cases sont grisées, avec une note.
    public let updatesEnabled: Bool
    /// « PTZBot 1.0.0 (412) ».
    public let versionLine: String
    public let loginItem: LoginItemModel
    @ObservationIgnored private let updater: any Updater

    public init(updater: any Updater, updatesEnabled: Bool, loginItem: LoginItemModel, shortVersion: String?, bundleVersion: String?) {
        self.updater = updater
        self.updatesEnabled = updatesEnabled
        self.loginItem = loginItem
        automaticallyChecks = updater.automaticallyChecks
        automaticallyDownloads = updater.automaticallyDownloads
        versionLine = Labels.version(short: shortVersion, build: bundleVersion)
        updater.observeCanCheck { [weak self] canCheck in
            self?.canCheck = canCheck
        }
    }

    /// « Rechercher automatiquement ». Sans recherche automatique, l'installation automatique n'a plus d'objet :
    /// sa case est grisée (Sparkle garde son réglage).
    public func setAutomaticallyChecks(_ enabled: Bool) {
        updater.automaticallyChecks = enabled
        automaticallyChecks = updater.automaticallyChecks
    }

    /// « Installer automatiquement ».
    public func setAutomaticallyDownloads(_ enabled: Bool) {
        updater.automaticallyDownloads = enabled
        automaticallyDownloads = updater.automaticallyDownloads
    }

    /// La case « Installer automatiquement » est utilisable.
    public var canChangeDownloads: Bool {
        updatesEnabled && automaticallyChecks
    }

    /// « Rechercher les mises à jour… » du panneau : grisé hors d'une app publiée ou pendant une recherche.
    public var canCheckForUpdates: Bool {
        updatesEnabled && canCheck
    }

    public func checkForUpdates() {
        guard updatesEnabled else { return }
        updater.checkForUpdates()
    }
}
