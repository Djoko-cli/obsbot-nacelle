import Foundation
import Testing
@testable import PTZBotKit

/// Sparkle simulé : réglages retenus, recherches comptées.
@MainActor
final class FakeUpdater: Updater {
    var automaticallyChecks = true
    var automaticallyDownloads = true
    var canCheck = true {
        didSet { canCheckHandler?(canCheck) }
    }
    private(set) var checks = 0
    private var canCheckHandler: (@MainActor (Bool) -> Void)?

    func observeCanCheck(_ handler: @escaping @MainActor (Bool) -> Void) {
        canCheckHandler = handler
        handler(canCheck)
    }

    func checkForUpdates() {
        checks += 1
    }
}

@MainActor
@Suite("Mises à jour et Réglages", .french)
struct UpdaterTests {
    @Test("Sparkle seulement dans une app publiée : numéro de compilation entier supérieur à 1, hors des tests")
    func policy() {
        #expect(UpdaterPolicy.usesSparkle(bundleVersion: "412", environment: [:]))
        #expect(UpdaterPolicy.usesSparkle(bundleVersion: "2", environment: ["HOME": "/maison"]))
        // Compilation de travail : jamais.
        #expect(!UpdaterPolicy.usesSparkle(bundleVersion: "1", environment: [:]))
        #expect(!UpdaterPolicy.usesSparkle(bundleVersion: nil, environment: [:]))
        #expect(!UpdaterPolicy.usesSparkle(bundleVersion: "", environment: [:]))
        #expect(!UpdaterPolicy.usesSparkle(bundleVersion: "1.0", environment: [:]))
        #expect(!UpdaterPolicy.usesSparkle(bundleVersion: "0", environment: [:]))
        // Sous les tests : jamais, même avec un numéro de publication.
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            #expect(!UpdaterPolicy.usesSparkle(bundleVersion: "412", environment: [key: "x"]), "\(key)")
        }
        #expect(UpdaterPolicy.workBuildVersion == "1")
    }

    @Test("Sans Sparkle : aucune recherche, cases décochées et grisées, note affichée")
    func noUpdater() {
        let updater = NoUpdater()
        updater.automaticallyChecks = true
        #expect(!updater.automaticallyChecks)
        #expect(!updater.canCheck)
        let model = SettingsModel(updater: updater, updatesEnabled: false, loginItem: LoginItemModel(service: FakeLoginItem()),
                                  shortVersion: "1.0.0", bundleVersion: "1")
        #expect(!model.automaticallyChecks)
        #expect(!model.canChangeDownloads)
        #expect(!model.canCheckForUpdates)
        model.checkForUpdates()
        #expect(model.versionLine == "PTZBot 1.0.0 (1)")
    }

    @Test("Réglages : cases cochées par défaut, écrites dans Sparkle ; installation grisée sans recherche automatique")
    func settings() {
        let updater = FakeUpdater()
        let model = SettingsModel(updater: updater, updatesEnabled: true, loginItem: LoginItemModel(service: FakeLoginItem()),
                                  shortVersion: "1.0.0", bundleVersion: "412")
        #expect(model.automaticallyChecks)
        #expect(model.automaticallyDownloads)
        #expect(model.canChangeDownloads)
        #expect(model.versionLine == "PTZBot 1.0.0 (412)")
        model.setAutomaticallyDownloads(false)
        #expect(!updater.automaticallyDownloads)
        #expect(!model.automaticallyDownloads)
        model.setAutomaticallyChecks(false)
        #expect(!updater.automaticallyChecks)
        #expect(!model.canChangeDownloads)
        model.setAutomaticallyChecks(true)
        #expect(model.canChangeDownloads)
    }

    @Test("« Rechercher les mises à jour… » : transmis à Sparkle, grisé pendant une recherche")
    func check() {
        let updater = FakeUpdater()
        let model = SettingsModel(updater: updater, updatesEnabled: true, loginItem: LoginItemModel(service: FakeLoginItem()),
                                  shortVersion: "1.0.0", bundleVersion: "412")
        #expect(model.canCheckForUpdates)
        model.checkForUpdates()
        #expect(updater.checks == 1)
        // Une recherche en cours (KVO de Sparkle) : le bouton se grise, puis revient, sans relire l'updater.
        updater.canCheck = false
        #expect(!model.canCheck)
        #expect(!model.canCheckForUpdates)
        updater.canCheck = true
        #expect(model.canCheckForUpdates)
    }

    @Test("« Ouvrir à la connexion » est dans les Réglages")
    func loginItem() {
        let service = FakeLoginItem()
        let model = SettingsModel(updater: NoUpdater(), updatesEnabled: false, loginItem: LoginItemModel(service: service),
                                  shortVersion: nil, bundleVersion: nil)
        model.loginItem.setEnabled(true)
        #expect(service.status == .enabled)
        #expect(model.loginItem.isEnabled)
        #expect(model.versionLine == "PTZBot")
    }

    @Test("Libellés : pied du panneau et Réglages, en français et en anglais ; ligne de version")
    func labels() {
        Localization.$languageOverride.withValue("fr") {
            #expect(Labels.checkForUpdates == "Rechercher les mises à jour…")
            #expect(Labels.settings == "Réglages…")
            #expect(Labels.quit == "Quitter")
            #expect(Labels.automaticallyChecks == "Rechercher automatiquement")
            #expect(Labels.automaticallyInstalls == "Installer automatiquement")
            #expect(Labels.openAtLogin == "Ouvrir à la connexion")
            #expect(Labels.languageTitle == "Langue")
            #expect(Labels.languageChoice(.automatic) == "Automatique (langue du système)")
            #expect(Labels.languageUpdateNote == "Les fenêtres de mise à jour suivront au prochain lancement.")
        }
        Localization.$languageOverride.withValue("en") {
            #expect(Labels.checkForUpdates == "Check for Updates…")
            #expect(Labels.settings == "Settings…")
            #expect(Labels.quit == "Quit")
            #expect(Labels.automaticallyChecks == "Check automatically")
            #expect(Labels.automaticallyInstalls == "Install automatically")
            #expect(Labels.openAtLogin == "Open at login")
            #expect(Labels.updatesDisabled == "Updates are disabled in a development build.")
            #expect(Labels.languageTitle == "Language")
            #expect(Labels.languageChoice(.automatic) == "Automatic (system language)")
            #expect(Labels.languageUpdateNote == "Update windows will follow at the next launch.")
        }
        // « Français » et « English » restent dans leur propre langue, quelle que soit celle de l'app.
        for language in ["fr", "en"] {
            Localization.$languageOverride.withValue(language) {
                #expect(Labels.languageChoice(.french) == "Français")
                #expect(Labels.languageChoice(.english) == "English")
            }
        }
        #expect(Labels.version(short: "1.0.0", build: "412") == "PTZBot 1.0.0 (412)")
        #expect(Labels.version(short: "1.0.0", build: nil) == "PTZBot 1.0.0")
    }
}
