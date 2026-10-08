import Foundation
import Synchronization

/// La langue des textes de PTZBotKit (spec distribution § 7.1) : le français, langue source au vouvoiement, ou
/// l'anglais pour toute autre langue. Les textes sont dans `Resources/Localizable.xcstrings`.
///
/// La langue est celle que l'utilisateur choisit dans les Réglages de PTZBot (`AppLanguageModel`). En automatique,
/// elle est choisie comme macOS la choisit pour l'app (région de développement `en`) : la première des langues
/// préférées de l'utilisateur que PTZBot connaît, sinon l'anglais. `Bundle.module` seul ne suffit pas : hors d'une
/// app qui déclare ses langues (tests, outil en ligne de commande), il prend l'anglais même sur un Mac en français.
public enum Localization {
    public static let languages = ["fr", "en"]

    /// La langue de l'app, réglée par `AppLanguageModel` ; au départ, la règle automatique.
    private static let appLanguage = Mutex(preferredLanguage(Locale.preferredLanguages))

    /// Une langue imposée pour une tâche : les tests la fixent avec `Localization.$languageOverride.withValue("en")`.
    @TaskLocal public static var languageOverride: String?

    /// La langue des textes : celle de la tâche si elle est imposée, sinon celle de l'app.
    public static var language: String {
        languageOverride ?? appLanguage.withLock { $0 }
    }

    /// Change la langue de l'app (« fr » ou « en ») ; les vues se redessinent par `AppLanguageModel`.
    public static func setAppLanguage(_ language: String) {
        appLanguage.withLock { $0 = languages.contains(language) ? language : "en" }
    }

    /// La première des langues préférées que PTZBot connaît (français ou anglais), l'anglais si aucune. Le repli est
    /// explicite : il ne dépend pas de la région de développement du bundle principal.
    public static func preferredLanguage(_ preferences: [String]) -> String {
        for preference in preferences {
            if let code = Locale(identifier: preference).language.languageCode?.identifier, languages.contains(code) {
                return code
            }
        }
        return "en"
    }

    /// Les formats de date et d'heure suivent la langue des textes.
    public static var locale: Locale {
        Locale(identifier: language == "fr" ? "fr_FR" : "en_US")
    }

    /// Le dossier `.lproj` de la langue, dans les ressources de PTZBotKit.
    static func bundle(for language: String) -> Bundle {
        bundles[language] ?? .module
    }

    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: languages.compactMap { language in
        Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)).map { (language, $0) }
    })

    /// Le texte dans la langue courante ; la clé est le texte français.
    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle(for: language))
    }
}
