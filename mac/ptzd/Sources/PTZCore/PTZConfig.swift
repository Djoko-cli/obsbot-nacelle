import Foundation

public enum ConfigError: Error, Equatable {
    case missingListenAddress
    case invalidListenAddress(String)
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
    public var aiOffPath: String

    private enum CodingKeys: String, CodingKey {
        case listenAddress, port, panMaxSpeed, tiltMaxSpeed, panDirection, tiltDirection, aiOffPath
    }

    public init(
        listenAddress: String,
        port: Int = 1985,
        panMaxSpeed: Int = 40,
        tiltMaxSpeed: Int = 60,
        panDirection: Int = 1,
        tiltDirection: Int = 1,
        aiOffPath: String = "bin/obsbot-ai-off"
    ) {
        self.listenAddress = listenAddress
        self.port = port
        self.panMaxSpeed = panMaxSpeed
        self.tiltMaxSpeed = tiltMaxSpeed
        self.panDirection = panDirection
        self.tiltDirection = tiltDirection
        self.aiOffPath = aiOffPath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
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
            aiOffPath: try c.decodeIfPresent(String.self, forKey: .aiOffPath) ?? "bin/obsbot-ai-off"
        )
    }

    /// Lit et valide config.json.
    public static func load(from url: URL) throws -> PTZConfig {
        let config = try JSONDecoder().decode(PTZConfig.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    /// Adresse d'écoute : 127.0.0.1 ou une adresse Tailscale (plage CGNAT 100.64.0.0/10),
    /// jamais 0.0.0.0 ni une adresse du réseau local (spec § 6.10).
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

    /// Chemin absolu de obsbot-ai-off ; un chemin relatif part du dossier de travail.
    public func aiOffURL(relativeTo base: URL) -> URL {
        aiOffPath.hasPrefix("/") ? URL(fileURLWithPath: aiOffPath) : base.appending(path: aiOffPath)
    }
}
