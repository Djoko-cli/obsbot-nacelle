import Testing
@testable import PTZBotKit

/// Fixe la langue des textes de PTZBotKit pour tout un test ou toute une suite : les assertions ne dépendent pas
/// de la langue du Mac qui lance les tests.
struct LanguageTrait: TestTrait, SuiteTrait, TestScoping {
    let language: String

    var isRecursive: Bool {
        true
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await Localization.$languageOverride.withValue(language) {
            try await function()
        }
    }
}

extension Trait where Self == LanguageTrait {
    /// Les textes en français, langue source.
    static var french: Self {
        LanguageTrait(language: "fr")
    }

    /// Les textes en anglais.
    static var english: Self {
        LanguageTrait(language: "en")
    }
}
