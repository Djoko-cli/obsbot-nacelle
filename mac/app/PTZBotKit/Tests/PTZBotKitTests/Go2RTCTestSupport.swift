import Foundation
import Testing
@testable import PTZBotKit

/// Les données fictives des tests de go2rtc : aucun vrai mot de passe, aucun vrai chemin personnel.
enum Go2RTCFixtures {
    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    static let camera = "OBSBOT Tiny 2 StreamCamera"
    static let microphone = "OBSBOT Tiny2 Microphone"
    static let password = "mot-de-passe-de-test"

    /// Les réglages par défaut, avec un identifiant et un mot de passe fictifs.
    static func settings() -> Go2RTCSettings {
        var settings = Go2RTCSettings()
        settings.username = "ptzbot"
        settings.password = password
        return settings
    }

    /// Un dossier temporaire neuf, à retirer par l'appelant.
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ptzbot-go2rtc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Le mode d'un fichier (0o600…).
    static func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }
}

/// `shell.QuoteSplit` de go2rtc 1.9.14 (pkg/shell/shell.go), recopié : c'est ainsi que go2rtc découpe une commande
/// `exec:`. Un guillemet sans fin, ou des guillemets vides, rendent nil (une erreur pour go2rtc).
func quoteSplit(_ text: String) -> [String]? {
    var result: [String] = []
    var rest = Substring(text)
    while let first = rest.first {
        switch first {
        case "\t", "\n", "\r", " ":
            rest = rest.dropFirst()
        case "\"", "'":
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: first), end > body.startIndex else { return nil }
            result.append(String(body[..<end]))
            rest = body[body.index(after: end)...]
        default:
            if let end = rest.firstIndex(where: { "\t\n\r ".contains($0) }) {
                result.append(String(rest[..<end]))
                rest = rest[end...]
            } else {
                result.append(String(rest))
                rest = ""
            }
        }
    }
    return result
}

/// Les entrées `- >-` du yaml, repliées comme les lit un analyseur yaml (lignes au même retrait jointes par une espace,
/// sans saut de ligne final).
func foldedEntries(_ yaml: String) -> [String] {
    var entries: [String] = []
    var current: [String]?
    for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
        if line == "    - >-" {
            if let current { entries.append(current.joined(separator: " ")) }
            current = []
        } else if current != nil, line.hasPrefix("      ") {
            current?.append(String(line.dropFirst(6)))
        } else if let finished = current {
            entries.append(finished.joined(separator: " "))
            current = nil
        }
    }
    if let current { entries.append(current.joined(separator: " ")) }
    return entries
}
