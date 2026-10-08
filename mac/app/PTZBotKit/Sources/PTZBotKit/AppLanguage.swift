import Foundation
import Observation

/// La langue de PTZBot, choisie dans ses Réglages (banc du 08/10 : passer par Réglages Système › Langue et région
/// n'est pas commode) : automatique (la règle de macOS pour l'app), français ou anglais.
public enum AppLanguage: String, CaseIterable, Sendable {
    case automatic
    case french
    case english

    /// La langue des textes : « fr » ou « en ». En automatique, d'après les langues préférées du système.
    public func resolved(systemPreferences: [String]) -> String {
        switch self {
        case .automatic: Localization.preferredLanguage(systemPreferences)
        case .french: "fr"
        case .english: "en"
        }
    }

    /// Ce qui est écrit dans `AppleLanguages` du domaine de l'app, pour les fenêtres de Sparkle (choisies par macOS
    /// au lancement) ; nil en automatique : la clé est retirée.
    public var appleLanguages: [String]? {
        switch self {
        case .automatic: nil
        case .french: ["fr"]
        case .english: ["en"]
        }
    }
}

/// Le réglage « Langue » (spec distribution § 12) : retenu dans les préférences de l'app, appliqué tout de suite aux
/// textes de PTZBot. Les vues lisent `language` : elles se redessinent quand il change, sans relancer l'app.
@MainActor
@Observable
public final class AppLanguageModel {
    public static let key = "appLanguage"
    public static let appleLanguagesKey = "AppleLanguages"

    public private(set) var selection: AppLanguage
    /// La langue en vigueur : « fr » ou « en ».
    public private(set) var language: String
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let systemPreferences: [String]
    @ObservationIgnored private let apply: @MainActor (String) -> Void

    /// `systemPreferences` : les langues du système, sans le réglage de l'app ; `apply` reçoit la langue en vigueur.
    public init(settings: any SettingsStore, systemPreferences: [String], apply: @escaping @MainActor (String) -> Void) {
        self.settings = settings
        self.systemPreferences = systemPreferences
        self.apply = apply
        let saved = settings.string(forKey: Self.key).flatMap(AppLanguage.init(rawValue:)) ?? .automatic
        selection = saved
        language = saved.resolved(systemPreferences: systemPreferences)
        apply(language)
    }

    /// Le réglage de l'app : préférences de l'utilisateur, langues du système, `Localization`.
    public static func system() -> AppLanguageModel {
        // Les langues du système, hors du domaine de l'app (où « AppleLanguages » peut porter le réglage de PTZBot).
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let system = global?[appleLanguagesKey] as? [String] ?? Locale.preferredLanguages
        return AppLanguageModel(
            settings: UserDefaultsSettingsStore(defaults: .standard),
            systemPreferences: system,
            apply: { Localization.setAppLanguage($0) }
        )
    }

    /// Le choix de l'utilisateur : retenu, recopié dans `AppleLanguages` pour Sparkle (au prochain lancement),
    /// appliqué tout de suite aux textes.
    public func select(_ choice: AppLanguage) {
        selection = choice
        settings.set(choice.rawValue, forKey: Self.key)
        settings.set(choice.appleLanguages, forKey: Self.appleLanguagesKey)
        language = choice.resolved(systemPreferences: systemPreferences)
        apply(language)
    }
}
