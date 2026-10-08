import Foundation
import Testing
@testable import PTZBotKit

/// Langues appliquées, retenues pour le test.
@MainActor
final class AppliedLanguages {
    private(set) var values: [String] = []

    func add(_ language: String) {
        values.append(language)
    }
}

@MainActor
@Suite("Langue de l'app", .french)
struct AppLanguageTests {
    @Test("Automatique : la règle du système (français sur un Mac en français, anglais sinon) ; les deux autres forcent")
    func resolution() {
        #expect(AppLanguage.automatic.resolved(systemPreferences: ["fr-FR"]) == "fr")
        #expect(AppLanguage.automatic.resolved(systemPreferences: ["de-DE"]) == "en")
        #expect(AppLanguage.automatic.resolved(systemPreferences: ["de-DE", "fr-FR"]) == "fr")
        #expect(AppLanguage.french.resolved(systemPreferences: ["en-US"]) == "fr")
        #expect(AppLanguage.english.resolved(systemPreferences: ["fr-FR"]) == "en")
        #expect(AppLanguage.automatic.appleLanguages == nil)
        #expect(AppLanguage.french.appleLanguages == ["fr"])
        #expect(AppLanguage.english.appleLanguages == ["en"])
    }

    @Test("Choix retenu (appLanguage) et recopié dans AppleLanguages pour Sparkle ; automatique retire la clé")
    func persistence() {
        let settings = FakeSettings()
        let applied = AppliedLanguages()
        let model = AppLanguageModel(settings: settings, systemPreferences: ["fr-FR"], apply: { applied.add($0) })
        #expect(model.selection == .automatic)
        #expect(model.language == "fr")
        model.select(.english)
        #expect(settings.strings["appLanguage"] == "english")
        #expect(settings.arrays["AppleLanguages"] == ["en"])
        #expect(model.language == "en")
        model.select(.french)
        #expect(settings.arrays["AppleLanguages"] == ["fr"])
        model.select(.automatic)
        #expect(settings.strings["appLanguage"] == "automatic")
        #expect(settings.arrays["AppleLanguages"] == nil)
        #expect(applied.values == ["fr", "en", "fr", "fr"])
        // Au lancement suivant, le choix est relu.
        settings.strings["appLanguage"] = "english"
        let relaunched = AppLanguageModel(settings: settings, systemPreferences: ["fr-FR"], apply: { applied.add($0) })
        #expect(relaunched.selection == .english)
        #expect(relaunched.language == "en")
        // Valeur inconnue : automatique.
        settings.strings["appLanguage"] = "klingon"
        #expect(AppLanguageModel(settings: settings, systemPreferences: ["de"], apply: { _ in }).selection == .automatic)
    }

    @Test("Les textes de PTZBotKit suivent la langue de l'app, hors langue imposée à la tâche")
    func appliedToTexts() {
        Localization.$languageOverride.withValue(nil) {
            let before = Localization.language
            defer { Localization.setAppLanguage(before) }
            Localization.setAppLanguage("en")
            #expect(Labels.sdk(.ready) == "Ready")
            Localization.setAppLanguage("fr")
            #expect(Labels.sdk(.ready) == "Prêt")
            Localization.setAppLanguage("de")
            #expect(Localization.language == "en")
        }
    }
}
