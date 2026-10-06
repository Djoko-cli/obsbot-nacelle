import Foundation
import Network

/// L'adresse du Mac en repli (spec découverte et QR § 8.1) : retenue à l'appairage, modifiable à la main.
/// Vide, l'app ne compte que sur Bonjour. La vidéo passe par ptzd.
struct ConnectionSettings: Codable, Equatable, Sendable {
    /// Comment joindre l'adresse du champ (spec découverte et QR § 8.2).
    enum Route: Equatable, Sendable {
        /// IPv4 privée ou nom en `.local` : TLS à clé pré-partagée, à la maison ou en 4G par la route du NAS.
        case local
        /// Tout le reste (nom MagicDNS ou adresse Tailscale) : WebSocket simple vers l'écoute Tailscale.
        case tailscale
    }

    /// Adresse IPv4 locale du Mac, nom en `.local`, ou nom ou adresse Tailscale ; vide : Bonjour seul.
    var host = ""
    var ptzdPort = 1985

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Champ vide ou hôte nu (ni schéma, ni port, ni chemin, ni espace), et port valide : enregistrable.
    var isValid: Bool {
        (1...65535).contains(ptzdPort) && (trimmedHost.isEmpty || hostIsBare)
    }

    private var hostIsBare: Bool {
        !trimmedHost.contains { $0 == "/" || $0 == ":" || $0.isWhitespace } && makePtzdURL() != nil
    }

    /// L'adresse du champ, renseignée et valide.
    var fallbackHost: String? {
        isValid && !trimmedHost.isEmpty ? trimmedHost : nil
    }

    /// Port tapé dans un champ texte ; 0 (donc réglages invalides) si ce n'est pas un nombre.
    static func port(from text: String) -> Int {
        Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// IPv4 privée (10/8, 172.16/12, 192.168/16) ou nom en `.local` : réseau local ; sinon Tailscale.
    static func route(for host: String) -> Route {
        if host.lowercased().hasSuffix(".local") {
            return .local
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { part in
            part.allSatisfy { $0.isASCII && $0.isNumber } ? UInt8(part) : nil
        }
        guard parts.count == 4, octets.count == 4 else { return .tailscale }
        switch (octets[0], octets[1]) {
        case (10, _), (172, 16...31), (192, 168):
            return .local
        default:
            return .tailscale
        }
    }

    /// Où joindre l'adresse du champ : en TLS avec ces secrets pour une adresse locale (aucune sans
    /// secret), en WebSocket simple pour Tailscale ; nil si le champ est vide.
    func endpoint(credentials: LANCredentials?) -> WebSocketEndpoint? {
        guard let host = fallbackHost, let url = makePtzdURL() else { return nil }
        switch Self.route(for: host) {
        case .local:
            return credentials.map { .tls(.url(url), $0) }
        case .tailscale:
            return .url(url)
        }
    }

    /// `ws://<hôte>:<port>`. Le WebSocket de Network.framework a besoin d'une URL : vers un simple
    /// `NWEndpoint.hostPort`, la connexion est abandonnée avant la poignée de main (vérifié sur macOS 27).
    static func webSocketURL(host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        return components.url
    }

    private func makePtzdURL() -> URL? {
        Self.webSocketURL(host: trimmedHost, port: ptzdPort)
    }
}

/// Réglages enregistrés dans UserDefaults.
struct SettingsStore {
    static let key = "connectionSettings"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ConnectionSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(ConnectionSettings.self, from: data) else {
            return ConnectionSettings()
        }
        return settings
    }

    func save(_ settings: ConnectionSettings) {
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.key)
    }
}
