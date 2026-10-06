import Foundation

/// Où joindre le Mac hors de la maison (spec accès local § 8.1). Saisi au premier lancement,
/// modifiable ensuite. La vidéo passe par ptzd ; à la maison, Bonjour trouve le Mac.
struct ConnectionSettings: Codable, Equatable, Sendable {
    /// Nom Tailscale du Mac (par exemple `mon-mac.tailnet.ts.net`) ou son adresse IPv4.
    var host = ""
    var ptzdPort = 1985

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Un hôte nu (ni schéma, ni port, ni chemin, ni espace), un port valide, et l'adresse qui en découle.
    var isComplete: Bool {
        hasValidFields && makePtzdURL() != nil
    }

    private var hasValidFields: Bool {
        !trimmedHost.isEmpty
            && !trimmedHost.contains { $0 == "/" || $0 == ":" || $0.isWhitespace }
            && (1...65535).contains(ptzdPort)
    }

    /// Port tapé dans un champ texte ; 0 (donc réglages incomplets) si ce n'est pas un nombre.
    static func port(from text: String) -> Int {
        Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// `ws://<hôte>:<port ptzd>`
    var ptzdURL: URL? {
        isComplete ? makePtzdURL() : nil
    }

    private func makePtzdURL() -> URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = trimmedHost
        components.port = ptzdPort
        return components.url
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
