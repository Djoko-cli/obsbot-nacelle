import Foundation
import Testing
@testable import Nacelle

@Suite("Réglages de connexion")
struct ConnectionSettingsTests {
    @Test("Adresses construites à partir de l'hôte, sans espaces")
    func urls() {
        let settings = ConnectionSettings(host: " mac.exemple.ts.net ", go2rtcPort: 1984, streamName: "obsbot", ptzdPort: 1985)
        #expect(settings.webRTCURL?.absoluteString == "http://mac.exemple.ts.net:1984/api/webrtc?src=obsbot")
        #expect(settings.ptzdURL?.absoluteString == "ws://mac.exemple.ts.net:1985")
    }

    @Test("Incomplets : hôte vide, flux vide ou port hors bornes")
    func incomplete() {
        #expect(!ConnectionSettings().isComplete)
        #expect(ConnectionSettings().webRTCURL == nil)
        #expect(!ConnectionSettings(host: "mac", streamName: " ").isComplete)
        #expect(!ConnectionSettings(host: "mac", go2rtcPort: 0).isComplete)
        #expect(!ConnectionSettings(host: "mac", ptzdPort: 70000).isComplete)
        #expect(ConnectionSettings(host: "mac").isComplete)
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
            #expect(settings.webRTCURL == nil, "\(host)")
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
        let settings = ConnectionSettings(host: "mac.exemple.ts.net", go2rtcPort: 1984, streamName: "cam", ptzdPort: 1999)
        store.save(settings)
        #expect(store.load() == settings)
    }
}
