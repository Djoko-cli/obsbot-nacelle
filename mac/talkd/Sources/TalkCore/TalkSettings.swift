import Foundation

/// Contenu de talkd.json (spec haut-parleur § 5.5), hors du dépôt : `~/Library/Application Support/ObsbotNacelle/talkd.json`.
/// Un fichier absent ou invalide n'empêche pas le démarrage : valeurs par défaut, 127.0.0.1 seul, et une ligne de journal.
public struct TalkSettings: Equatable, Sendable {
    /// Port UDP d'écoute. 0 : le système en attribue un libre (talkd de test).
    public var port: Int
    /// Adresses IPv4 dont les paquets sont acceptés ; tout le reste est ignoré et compté.
    public var allowedSources: [String]
    /// Volume minimum garanti le temps de la voix, de 0 à 1.
    public var volumeFloor: Double
    /// Valeur efficace (de 0 à 1, pleine échelle) au-dessus de laquelle un paquet « contient de la voix ».
    public var voiceThreshold: Double

    public init(port: Int = 1986, allowedSources: [String] = ["127.0.0.1"], volumeFloor: Double = 0.30, voiceThreshold: Double = 0.01) {
        self.port = port
        self.allowedSources = allowedSources
        self.volumeFloor = volumeFloor
        self.voiceThreshold = voiceThreshold
    }

    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case outOfRange(String)

        public var description: String {
            switch self {
            case let .unreadable(reason): "illisible (\(reason))"
            case let .outOfRange(key): "valeur hors limites pour \(key)"
            }
        }
    }

    /// Lit talkd.json. Absent, illisible ou invalide : les valeurs par défaut, journalisé.
    @MainActor
    public static func load(from url: URL, log: LogSink) -> TalkSettings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            log("talkd.json absent : valeurs par défaut (127.0.0.1 seul).")
            return TalkSettings()
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            log("talkd.json invalide, \(error) : valeurs par défaut (127.0.0.1 seul).")
            return TalkSettings()
        }
    }

    /// Décode et valide ; les clés absentes prennent leur valeur par défaut, les clés inconnues sont ignorées.
    public static func decode(_ data: Data) throws(Invalid) -> TalkSettings {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw .unreadable(String(describing: error))
        }
        let defaults = TalkSettings()
        let settings = TalkSettings(
            port: file.port ?? defaults.port,
            allowedSources: file.allowedSources ?? defaults.allowedSources,
            volumeFloor: file.volumeFloor ?? defaults.volumeFloor,
            voiceThreshold: file.voiceThreshold ?? defaults.voiceThreshold
        )
        try settings.validate()
        return settings
    }

    /// Port de 0 à 65535, au moins une adresse IPv4 (pas de nom : la source d'un paquet est une adresse), minimum
    /// de volume de 0 à 1, seuil de voix de 0 (exclu : tout paquet serait de la voix) à 1.
    public func validate() throws(Invalid) {
        guard (0...65535).contains(port) else { throw .outOfRange("port") }
        guard !allowedSources.isEmpty, allowedSources.allSatisfy(Self.isIPv4) else { throw .outOfRange("allowedSources") }
        guard (0.0...1.0).contains(volumeFloor) else { throw .outOfRange("volumeFloor") }
        guard voiceThreshold > 0, voiceThreshold <= 1 else { throw .outOfRange("voiceThreshold") }
    }

    static func isIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1
    }

    private struct File: Decodable {
        var port: Int?
        var allowedSources: [String]?
        var volumeFloor: Double?
        var voiceThreshold: Double?
    }
}
