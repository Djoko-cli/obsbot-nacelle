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
