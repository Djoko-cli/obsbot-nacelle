import Foundation

public enum ConfigError: Error, Equatable {
    case missingListenAddress
    case invalidListenAddress(String)
    case invalidGo2rtcAPI(String)
    case outOfRange(String)
}

/// Contenu de config.json (spec § 6.7). Seule `listenAddress` est obligatoire.
public struct PTZConfig: Codable, Equatable, Sendable {
    public var listenAddress: String
    public var port: Int
    public var panMaxSpeed: Int
    public var tiltMaxSpeed: Int
    public var panDirection: Int
    public var tiltDirection: Int
    /// Chemin de `obsbot-ai` (spec app Mac § 7.5).
    public var aiPath: String
    /// API locale de go2rtc, pour relayer les offres WebRTC (spec accès local § 6.5).
    public var go2rtcAPI: String
    /// Flux go2rtc relayé.
    public var streamName: String
    /// Écoute et annonce Bonjour sur le réseau local (spec accès local § 6.1).
    public var localNetwork: Bool

    private enum CodingKeys: String, CodingKey {
        case listenAddress, port, panMaxSpeed, tiltMaxSpeed, panDirection, tiltDirection, aiPath, go2rtcAPI, streamName, localNetwork
    }

    /// Clés anciennes, lues seulement.
    private enum LegacyKeys: String, CodingKey {
        case aiOffPath
    }

    public init(
        listenAddress: String,
        port: Int = 1985,
        panMaxSpeed: Int = 40,
        tiltMaxSpeed: Int = 60,
        panDirection: Int = 1,
        tiltDirection: Int = 1,
        aiPath: String = "bin/obsbot-ai",
        go2rtcAPI: String = "http://127.0.0.1:1984",
        streamName: String = "obsbot",
        localNetwork: Bool = true
    ) {
        self.listenAddress = listenAddress
        self.port = port
        self.panMaxSpeed = panMaxSpeed
        self.tiltMaxSpeed = tiltMaxSpeed
        self.panDirection = panDirection
        self.tiltDirection = tiltDirection
        self.aiPath = aiPath
        self.go2rtcAPI = go2rtcAPI
        self.streamName = streamName
        self.localNetwork = localNetwork
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        guard let address = try c.decodeIfPresent(String.self, forKey: .listenAddress), !address.isEmpty else {
            throw ConfigError.missingListenAddress
        }
        self.init(
            listenAddress: address,
            port: try c.decodeIfPresent(Int.self, forKey: .port) ?? 1985,
            panMaxSpeed: try c.decodeIfPresent(Int.self, forKey: .panMaxSpeed) ?? 40,
            tiltMaxSpeed: try c.decodeIfPresent(Int.self, forKey: .tiltMaxSpeed) ?? 60,
            panDirection: try c.decodeIfPresent(Int.self, forKey: .panDirection) ?? 1,
            tiltDirection: try c.decodeIfPresent(Int.self, forKey: .tiltDirection) ?? 1,
            // L'ancienne clé `aiOffPath` reste lue si la nouvelle manque.
            aiPath: try c.decodeIfPresent(String.self, forKey: .aiPath)
                ?? legacy.decodeIfPresent(String.self, forKey: .aiOffPath) ?? "bin/obsbot-ai",
            go2rtcAPI: try c.decodeIfPresent(String.self, forKey: .go2rtcAPI) ?? "http://127.0.0.1:1984",
            streamName: try c.decodeIfPresent(String.self, forKey: .streamName) ?? "obsbot",
            localNetwork: try c.decodeIfPresent(Bool.self, forKey: .localNetwork) ?? true
        )
    }

    /// Lit et valide config.json.
    public static func load(from url: URL) throws -> PTZConfig {
        let config = try JSONDecoder().decode(PTZConfig.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    /// Adresse d'écoute : 127.0.0.1 ou une adresse Tailscale (plage CGNAT 100.64.0.0/10),
    /// jamais 0.0.0.0 ni une adresse du réseau local : le réseau local passe par `localNetwork`
    /// (spec accès local § 6.1).
    /// Bornes de la Tiny 2 : vitesse pan 1–80, tilt 1–120 (test de faisabilité).
    public func validate() throws {
        guard Self.isAllowedListenAddress(listenAddress) else {
            throw ConfigError.invalidListenAddress(listenAddress)
        }
        guard (1...65535).contains(port) else { throw ConfigError.outOfRange("port") }
        guard (1...80).contains(panMaxSpeed) else { throw ConfigError.outOfRange("panMaxSpeed") }
        guard (1...120).contains(tiltMaxSpeed) else { throw ConfigError.outOfRange("tiltMaxSpeed") }
        guard [1, -1].contains(panDirection) else { throw ConfigError.outOfRange("panDirection") }
        guard [1, -1].contains(tiltDirection) else { throw ConfigError.outOfRange("tiltDirection") }
        guard Self.isLocalHTTP(go2rtcAPI) else { throw ConfigError.invalidGo2rtcAPI(go2rtcAPI) }
        guard !streamName.trimmingCharacters(in: .whitespaces).isEmpty else { throw ConfigError.outOfRange("streamName") }
    }

    /// L'API go2rtc n'écoute que sur la boucle locale (spec accès local § 7) : `http://127.0.0.1:<port>`
    /// ou `http://localhost:<port>`, sans chemin.
    static func isLocalHTTP(_ text: String) -> Bool {
        guard let url = URLComponents(string: text), url.scheme == "http", url.port != nil,
              url.path.isEmpty || url.path == "/", url.query == nil else {
            return false
        }
        return url.host == "127.0.0.1" || url.host == "localhost"
    }

    static func isAllowedListenAddress(_ text: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        let loopback: UInt32 = 0x7F00_0001
        // 100.64.0.0/10 : 100 = 0x64, puis les deux bits de poids fort du deuxième octet à 01.
        let tailscale = value & 0xFFC0_0000 == 0x6440_0000
        return value == loopback || tailscale
    }

    public var motion: MotionSettings {
        MotionSettings(
            panMaxSpeed: panMaxSpeed,
            tiltMaxSpeed: tiltMaxSpeed,
            panDirection: panDirection,
            tiltDirection: tiltDirection
        )
    }

    /// Chemin absolu de obsbot-ai ; un chemin relatif part du dossier de travail.
    public func aiURL(relativeTo base: URL) -> URL {
        aiPath.hasPrefix("/") ? URL(fileURLWithPath: aiPath) : base.appending(path: aiPath)
    }
}
