import Foundation
import Testing
@testable import TalkCore

@MainActor
@Suite("Réglages de talkd")
struct TalkSettingsTests {
    private func load(_ json: String?, log: LogRecorder = LogRecorder()) throws -> TalkSettings {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "talkd.json")
        if let json {
            try Data(json.utf8).write(to: url)
        }
        return TalkSettings.load(from: url, log: log.sink)
    }

    @Test("Valeurs par défaut : port 1986, 127.0.0.1 seul, minimum 30 %, seuil de voix 0,01")
    func defaults() {
        let settings = TalkSettings()
        #expect(settings.port == 1986)
        #expect(settings.allowedSources == ["127.0.0.1"])
        #expect(settings.volumeFloor == 0.30)
        #expect(settings.voiceThreshold == 0.01)
    }

    @Test("Fichier complet : toutes les valeurs sont lues, sans rien journaliser")
    func fullFile() throws {
        let log = LogRecorder()
        let json = #"{ "port": 19860, "allowedSources": ["127.0.0.1", "192.0.2.10"], "volumeFloor": 0.5, "voiceThreshold": 0.02 }"#
        let settings = try load(json, log: log)
        #expect(settings == TalkSettings(port: 19860, allowedSources: ["127.0.0.1", "192.0.2.10"], volumeFloor: 0.5, voiceThreshold: 0.02))
        #expect(log.lines.isEmpty)
    }

    @Test("Clés absentes : les valeurs par défaut de chaque clé ; clés inconnues ignorées")
    func partialFile() throws {
        let settings = try load(#"{ "volumeFloor": 0.4, "autre": 1 }"#)
        #expect(settings == TalkSettings(volumeFloor: 0.4))
    }

    @Test("Fichier absent : valeurs par défaut, journalisé")
    func missingFile() throws {
        let log = LogRecorder()
        #expect(try load(nil, log: log) == TalkSettings())
        #expect(log.contains("absent"))
    }

    @Test("Fichier illisible ou invalide : valeurs par défaut (127.0.0.1 seul), journalisé")
    func invalidFile() throws {
        let invalid = [
            "pas du json",
            #"{ "port": 70000 }"#,
            #"{ "port": -1 }"#,
            #"{ "port": "1986" }"#,
            #"{ "allowedSources": [] }"#,
            #"{ "allowedSources": ["pas une adresse"] }"#,
            #"{ "allowedSources": ["192.0.2.10", "nas.example"] }"#,
            #"{ "volumeFloor": 1.5 }"#,
            #"{ "volumeFloor": -0.1 }"#,
            #"{ "voiceThreshold": 0 }"#,
            #"{ "voiceThreshold": 2 }"#,
        ]
        for json in invalid {
            let log = LogRecorder()
            #expect(try load(json, log: log) == TalkSettings(), "\(json)")
            #expect(log.contains("invalide"), "\(json)")
        }
    }

    @Test("Port 0 accepté : le système attribue un port libre (talkd de test)")
    func portZero() throws {
        #expect(try load(#"{ "port": 0 }"#).port == 0)
    }

    @Test("L'exemple du dépôt se lit tel quel, avec une adresse de documentation pour le NAS")
    func example() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "talkd.example.json")
        let log = LogRecorder()
        let settings = TalkSettings.load(from: url, log: log.sink)
        #expect(log.lines.isEmpty)
        #expect(settings.allowedSources == ["127.0.0.1", "192.0.2.10"])
        #expect(settings.port == 1986)
    }
}
