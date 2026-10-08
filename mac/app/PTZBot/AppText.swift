import Foundation
import PTZBotKit
import SwiftUI

/// Les textes des vues de l'app, dans la langue choisie dans ses Réglages (`AppLanguageModel`), et non dans celle
/// que macOS a choisie au lancement : ils sont lus dans `fr.lproj` ou `en.lproj` du paquet (catalogue
/// `Localizable.xcstrings`), la clé étant le texte français.
enum AppText {
    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle(for: Localization.language))
    }

    /// Un texte avec du Markdown (gras), traduit de même.
    static func markdown(_ key: String.LocalizationValue) -> AttributedString {
        let translated = text(key)
        return (try? AttributedString(markdown: translated)) ?? AttributedString(translated)
    }

    private static func bundle(for language: String) -> Bundle {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}

extension View {
    /// Suit la langue de l'app : la vue est redessinée dès qu'elle change, sans relancer l'app ; `title` est le
    /// titre de la fenêtre, traduit de même.
    func followsLanguage(_ language: AppLanguageModel, title: String.LocalizationValue? = nil) -> some View {
        let current = language.language
        return environment(\.locale, Locale(identifier: current))
            .navigationTitle(title.map { AppText.text($0) } ?? "")
            .id(current)
    }
}
