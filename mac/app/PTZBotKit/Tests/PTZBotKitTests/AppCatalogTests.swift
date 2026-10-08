import Foundation
import Testing

/// Les catalogues de l'app Mac (mac/app/PTZBot) : chaque texte des vues a sa traduction anglaise (spec
/// distribution § 7.1). Lus dans les sources, à côté de PTZBotKit.
@Suite("Catalogues de l'app", .french)
struct AppCatalogTests {
    static let appDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "PTZBot")

    static func strings(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: appDirectory.appending(path: name))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["sourceLanguage"] as? String == "fr")
        return try #require(object?["strings"] as? [String: Any])
    }

    static func english(_ entry: Any) -> String? {
        let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any]
        let unit = (localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["state"] as? String == "translated" ? unit?["value"] as? String : nil
    }

    @Test("Localizable.xcstrings et InfoPlist.xcstrings : chaque clé a sa traduction anglaise")
    func everyKeyTranslated() throws {
        for name in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let strings = try Self.strings(name)
            #expect(!strings.isEmpty, "\(name)")
            for (key, entry) in strings {
                #expect(Self.english(entry)?.isEmpty == false, "\(name) : \(key)")
            }
        }
        #expect(Self.english(try Self.strings("InfoPlist.xcstrings")["NSLocalNetworkUsageDescription"] as Any) != nil)
    }

    /// Les textes littéraux des vues : `AppText.text("…")`, `AppText.markdown("…")`, les titres de fenêtre, et les
    /// formes de SwiftUI (`Text("…")`, `Button("…")`, `Window("…")`…) ; chaque interpolation devient `%@`.
    static func sourceKeys() throws -> Set<String> {
        let calls = ["Text(\"", "Button(\"", "Toggle(\"", "ProgressView(\"", ".alert(\"", "Window(\"",
                     "String(localized: \"", ".confirmationDialog(\n            \"", "AppText.text(\"", "AppText.markdown(\"",
                     "followsLanguage(delegate.language, title: \""]
        var keys = Set<String>()
        for name in try FileManager.default.contentsOfDirectory(atPath: appDirectory.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: appDirectory.appending(path: name), encoding: .utf8)
            for call in calls {
                var rest = text[...]
                while let range = rest.range(of: call) {
                    var key = ""
                    var index = range.upperBound
                    while rest[index] != "\"" {
                        if rest[index] == "\\", rest[rest.index(after: index)] == "(" {
                            var depth = 0
                            repeat {
                                index = rest.index(after: index)
                                if rest[index] == "(" { depth += 1 }
                                if rest[index] == ")" { depth -= 1 }
                                if rest[index] == "\"" {
                                    index = rest[rest.index(after: index)...].firstIndex(of: "\"")!
                                }
                            } while depth > 0
                            key += "%@"
                        } else {
                            key.append(rest[index])
                        }
                        index = rest.index(after: index)
                    }
                    keys.insert(key)
                    // Depuis le début de la clé : un texte imbriqué dans une interpolation est lu à son tour.
                    rest = rest[range.upperBound...]
                }
            }
        }
        // `Text(verbatim:)` n'est pas traduit ; « PTZBot » reste tel quel.
        return keys.subtracting([""])
    }

    @Test("Chaque texte littéral des vues de l'app est dans son catalogue, et le catalogue n'a pas de clé inutile")
    func everySourceKeyInCatalog() throws {
        let keys = try Self.sourceKeys()
        let catalog = Set(try Self.strings("Localizable.xcstrings").keys)
        #expect(keys.count > 30)
        #expect(keys.subtracting(catalog).sorted() == [])
        #expect(catalog.subtracting(keys).sorted() == [])
    }
}
