import Foundation
import Testing
@testable import Nacelle

@Suite("Réglages de connexion")
struct ConnectionSettingsTests {
    @Test("Adresse construite à partir de l'hôte, sans espaces")
    func urls() {
        let settings = ConnectionSettings(host: " mac.exemple.ts.net ", ptzdPort: 1985)
        #expect(settings.ptzdURL?.absoluteString == "ws://mac.exemple.ts.net:1985")
    }

    @Test("Incomplets : hôte vide ou port hors bornes")
    func incomplete() {
        #expect(!ConnectionSettings().isComplete)
        #expect(ConnectionSettings().ptzdURL == nil)
        #expect(!ConnectionSettings(host: "mac", ptzdPort: 0).isComplete)
        #expect(!ConnectionSettings(host: "mac", ptzdPort: 70000).isComplete)
        #expect(ConnectionSettings(host: "mac").isComplete)
    }

    @Test("Anciens réglages (port go2rtc et flux) relus sans erreur")
    func legacySettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "nacelle-tests-\(UUID().uuidString)"))
        let legacy = #"{"host":"mac.exemple.ts.net","go2rtcPort":1984,"streamName":"obsbot","ptzdPort":1999}"#
        defaults.set(Data(legacy.utf8), forKey: SettingsStore.key)
        #expect(SettingsStore(defaults: defaults).load() == ConnectionSettings(host: "mac.exemple.ts.net", ptzdPort: 1999))
    }

    @Test("Hôte mal saisi : schéma, port, barre oblique ou espace refusés, sans adresse construite")
    func invalidHost() {
        for host in [
            "http://mac.exemple.ts.net",
            "mac.exemple.ts.net:1984",
            "mac.exemple.ts.net/",
            "mac.exemple.ts.net 1985",
        ] {
            let settings = ConnectionSettings(host: host)
            #expect(!settings.isComplete, "\(host)")
            #expect(settings.ptzdURL == nil, "\(host)")
        }
        #expect(ConnectionSettings(host: "\tmac.exemple.ts.net\n").isComplete)
        #expect(ConnectionSettings(host: "127.0.0.1").isComplete)
    }

    @Test("Port saisi au clavier : chiffres seuls, sinon 0 (donc incomplet)")
    func portFromText() {
        #expect(ConnectionSettings.port(from: "1999") == 1999)
        #expect(ConnectionSettings.port(from: " 1985 ") == 1985)
        #expect(ConnectionSettings.port(from: "") == 0)
        #expect(ConnectionSettings.port(from: "19a5") == 0)
        #expect(ConnectionSettings.port(from: "99999999999999999999999") == 0)
        #expect(!ConnectionSettings(host: "mac", ptzdPort: ConnectionSettings.port(from: "")).isComplete)
    }

    @Test("Enregistrés puis relus")
    func roundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "nacelle-tests-\(UUID().uuidString)"))
        let store = SettingsStore(defaults: defaults)
        #expect(store.load() == ConnectionSettings())
        let settings = ConnectionSettings(host: "mac.exemple.ts.net", ptzdPort: 1999)
        store.save(settings)
        #expect(store.load() == settings)
    }
}

@Suite("Code d'appairage saisi")
struct PairingCodeInputTests {
    @Test("Six chiffres, espaces aux bords ignorés", arguments: ["042917", " 042917 "])
    func valid(_ text: String) {
        #expect(PairingCodeInput.isValid(text))
    }

    @Test("Trop court, trop long, lettres ou chiffres non latins : refusé", arguments: ["04291", "0429171", "04291a", "٠٤٢٩١٧", ""])
    func invalid(_ text: String) {
        #expect(!PairingCodeInput.isValid(text))
    }
}
