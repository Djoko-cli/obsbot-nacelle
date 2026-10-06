import Foundation
import Network
import Testing
@testable import Nacelle

@Suite("Réglages de connexion")
struct ConnectionSettingsTests {
    let credentials = LANCredentials(identity: "abcd", key: Data(repeating: 9, count: 32))

    @Test("Nom Tailscale : WebSocket simple vers ws://<hôte>:<port>, sans espaces")
    func tailscaleEndpoint() {
        let settings = ConnectionSettings(host: " mac.exemple.ts.net ", ptzdPort: 1985)
        #expect(settings.endpoint(credentials: nil) == .url(URL(string: "ws://mac.exemple.ts.net:1985")!))
        #expect(settings.endpoint(credentials: credentials) == .url(URL(string: "ws://mac.exemple.ts.net:1985")!))
    }

    @Test("Adresse locale : TLS avec les secrets de l'iPhone, rien sans eux")
    func localEndpoint() {
        let settings = ConnectionSettings(host: "192.168.0.10", ptzdPort: 1985)
        #expect(settings.endpoint(credentials: credentials) == .tls(.hostPort(host: "192.168.0.10", port: 1985), credentials))
        #expect(settings.endpoint(credentials: nil) == nil)
    }

    @Test(
        "Route : IPv4 privée ou nom en .local, réseau local ; le reste, Tailscale",
        arguments: [
            ("10.0.0.5", ConnectionSettings.Route.local),
            ("172.16.0.1", .local),
            ("172.31.255.1", .local),
            ("192.168.0.10", .local),
            ("Mac-mini.LOCAL", .local),
            ("172.32.0.1", .tailscale),
            ("100.64.0.1", .tailscale),
            ("192.0.2.30", .tailscale),
            ("192.168.0.300", .tailscale),
            ("192.168.0", .tailscale),
            ("mac.exemple.ts.net", .tailscale),
        ]
    )
    func routes(_ host: String, _ route: ConnectionSettings.Route) {
        #expect(ConnectionSettings.route(for: host) == route)
    }

    @Test("Champ vide : valide, aucune adresse ; port hors bornes : invalide")
    func validity() {
        #expect(ConnectionSettings().isValid)
        #expect(ConnectionSettings().fallbackHost == nil)
        #expect(ConnectionSettings().endpoint(credentials: credentials) == nil)
        #expect(!ConnectionSettings(host: "mac", ptzdPort: 0).isValid)
        #expect(!ConnectionSettings(host: "mac", ptzdPort: 70000).isValid)
        #expect(ConnectionSettings(host: "mac").isValid)
    }

    @Test("Anciens réglages (port go2rtc et flux) relus sans erreur")
    func legacySettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "nacelle-tests-\(UUID().uuidString)"))
        let legacy = #"{"host":"mac.exemple.ts.net","go2rtcPort":1984,"streamName":"obsbot","ptzdPort":1999}"#
        defaults.set(Data(legacy.utf8), forKey: SettingsStore.key)
        #expect(SettingsStore(defaults: defaults).load() == ConnectionSettings(host: "mac.exemple.ts.net", ptzdPort: 1999))
    }

    @Test("Hôte mal saisi : schéma, port, barre oblique ou espace refusés, sans adresse")
    func invalidHost() {
        for host in [
            "http://mac.exemple.ts.net",
            "mac.exemple.ts.net:1984",
            "mac.exemple.ts.net/",
            "mac.exemple.ts.net 1985",
        ] {
            let settings = ConnectionSettings(host: host)
            #expect(!settings.isValid, "\(host)")
            #expect(settings.endpoint(credentials: credentials) == nil, "\(host)")
        }
        #expect(ConnectionSettings(host: "\tmac.exemple.ts.net\n").fallbackHost == "mac.exemple.ts.net")
        #expect(ConnectionSettings(host: "127.0.0.1").isValid)
    }

    @Test("Port saisi au clavier : chiffres seuls, sinon 0 (donc invalide)")
    func portFromText() {
        #expect(ConnectionSettings.port(from: "1999") == 1999)
        #expect(ConnectionSettings.port(from: " 1985 ") == 1985)
        #expect(ConnectionSettings.port(from: "") == 0)
        #expect(ConnectionSettings.port(from: "19a5") == 0)
        #expect(ConnectionSettings.port(from: "99999999999999999999999") == 0)
        #expect(!ConnectionSettings(host: "mac", ptzdPort: ConnectionSettings.port(from: "")).isValid)
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

    @Test("Adresse IPv4 d'un point d'arrivée résolu ; rien pour IPv6 ou un nom")
    func resolvedAddress() {
        #expect(NWWebSocketTransport.ipv4(.hostPort(host: .ipv4(IPv4Address("192.0.2.30")!), port: 1985)) == "192.0.2.30")
        #expect(NWWebSocketTransport.ipv4(.hostPort(host: .ipv6(IPv6Address("::1")!), port: 1985)) == nil)
        #expect(NWWebSocketTransport.ipv4(.hostPort(host: "mac-mini.local", port: 1985)) == nil)
    }
}
