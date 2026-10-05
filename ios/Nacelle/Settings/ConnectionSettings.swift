import Foundation

/// Où joindre le Mac (spec § 7.2). Saisi au premier lancement, modifiable ensuite.
struct ConnectionSettings: Codable, Equatable, Sendable {
    /// Nom Tailscale du Mac (par exemple `mon-mac.tailnet.ts.net`) ou son adresse IPv4.
    var host = ""
    var go2rtcPort = 1984
    var streamName = "obsbot"
    var ptzdPort = 1985

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedStream: String {
        streamName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Un hôte nu (ni schéma, ni port, ni chemin, ni espace), un nom de flux, deux ports valides,
    /// et les deux adresses qui en découlent.
    var isComplete: Bool {
        hasValidFields && makeWebRTCURL() != nil && makePtzdURL() != nil
    }

    private var hasValidFields: Bool {
        !trimmedHost.isEmpty && !trimmedStream.isEmpty
            && !trimmedHost.contains { $0 == "/" || $0 == ":" || $0.isWhitespace }
            && (1...65535).contains(go2rtcPort) && (1...65535).contains(ptzdPort)
    }

    /// Port tapé dans un champ texte ; 0 (donc réglages incomplets) si ce n'est pas un nombre.
    static func port(from text: String) -> Int {
        Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// `http://<hôte>:<port go2rtc>/api/webrtc?src=<flux>`
    var webRTCURL: URL? {
        isComplete ? makeWebRTCURL() : nil
    }

    /// `ws://<hôte>:<port ptzd>`
    var ptzdURL: URL? {
        isComplete ? makePtzdURL() : nil
    }

    private func makeWebRTCURL() -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmedHost
        components.port = go2rtcPort
        components.path = "/api/webrtc"
        components.queryItems = [URLQueryItem(name: "src", value: trimmedStream)]
        return components.url
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
