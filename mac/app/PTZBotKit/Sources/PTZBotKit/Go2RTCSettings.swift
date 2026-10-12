import Foundation

/// Les réglages de go2rtc dans PTZBot (spec B3 § 4), tenus hors du yaml. Ils sont retenus dans les préférences, sans
/// le mot de passe RTSP : seul le yaml le porte (mode 600), puisque go2rtc doit le lire en clair.
public struct Go2RTCSettings: Codable, Equatable, Sendable {
    /// Le nom du stream, dont dépendent ptzd (`streamName`) et Homebridge.
    public static let streamName = "obsbot"
    /// L'API de go2rtc, fixe : ptzd y relaie la vidéo de l'app iOS.
    public static let apiPort = 1984
    public static let preferencesKey = "go2rtcSettings"
    /// Les résolutions proposées : `-level 4.0` de h264_videotoolbox couvre 1080p à 30 i/s.
    public static let resolutions = [Resolution(width: 1920, height: 1080), Resolution(width: 1280, height: 720)]
    public static let framerates = [30, 25, 15]
    /// Les débits proposés, en Mb/s.
    public static let bitrates = [2, 3, 4, 5, 6, 8]

    public struct Resolution: Codable, Equatable, Hashable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public var username = "ptzbot"
    /// Seulement dans le yaml : jamais codé dans les préférences.
    public var password = ""
    public var rtspPort = 8554
    public var webrtcPort = 8555
    public var resolution = Resolution(width: 1920, height: 1080)
    public var framerate = 30
    /// Le débit vidéo, en Mb/s ; le plafond vaut 1,5 fois, le tampon la moitié (4 Mb/s : plafond 6, tampon 2, comme le
    /// pipeline en service).
    public var bitrate = 4
    /// nil : la première caméra OBSBOT branchée (`CaptureDeviceChoice`).
    public var cameraName: String?
    /// nil : le premier micro OBSBOT branché.
    public var microphoneName: String?
    /// nil : ffmpeg cherché à ses places habituelles (`FFmpegLocator`).
    public var ffmpegPath: String?
    /// Mode expert : go2rtc lancé sur ce fichier, que PTZBot n'écrit jamais.
    public var customConfigEnabled = false
    public var customConfigPath: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case username, rtspPort, webrtcPort, resolution, framerate, bitrate
        case cameraName, microphoneName, ffmpegPath, customConfigEnabled, customConfigPath
    }

    /// Une clé absente garde sa valeur par défaut : les préférences d'une version précédente se relisent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Go2RTCSettings()
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? defaults.username
        rtspPort = try container.decodeIfPresent(Int.self, forKey: .rtspPort) ?? defaults.rtspPort
        webrtcPort = try container.decodeIfPresent(Int.self, forKey: .webrtcPort) ?? defaults.webrtcPort
        resolution = try container.decodeIfPresent(Resolution.self, forKey: .resolution) ?? defaults.resolution
        framerate = try container.decodeIfPresent(Int.self, forKey: .framerate) ?? defaults.framerate
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate) ?? defaults.bitrate
        cameraName = try container.decodeIfPresent(String.self, forKey: .cameraName)
        microphoneName = try container.decodeIfPresent(String.self, forKey: .microphoneName)
        ffmpegPath = try container.decodeIfPresent(String.self, forKey: .ffmpegPath)
        customConfigEnabled = try container.decodeIfPresent(Bool.self, forKey: .customConfigEnabled) ?? defaults.customConfigEnabled
        customConfigPath = try container.decodeIfPresent(String.self, forKey: .customConfigPath)
    }

    /// « 4M » ; « 4500k » quand le compte n'est pas rond.
    static func rate(kilobits: Int) -> String {
        kilobits % 1000 == 0 ? "\(kilobits / 1000)M" : "\(kilobits)k"
    }

    public var videoBitrate: String { Self.rate(kilobits: bitrate * 1000) }
    public var videoMaxrate: String { Self.rate(kilobits: bitrate * 1500) }
    public var videoBuffer: String { Self.rate(kilobits: bitrate * 500) }

    /// Les réglages retenus ; le mot de passe reste vide (voir `restore`).
    @MainActor
    public static func load(from store: any SettingsStore) -> Go2RTCSettings {
        guard let text = store.string(forKey: preferencesKey),
              let decoded = try? JSONDecoder().decode(Go2RTCSettings.self, from: Data(text.utf8)) else {
            return Go2RTCSettings()
        }
        return decoded
    }

    /// Retient les réglages, sans le mot de passe.
    @MainActor
    public func save(to store: any SettingsStore) {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        store.set(String(decoding: data, as: UTF8.self), forKey: Self.preferencesKey)
    }

    /// Un mot de passe RTSP neuf : 20 lettres et chiffres sans ambiguïté, tirés par le générateur du système.
    public static func randomPassword() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<20).map { _ in alphabet[Int(generator.next(upperBound: UInt(alphabet.count)))] })
    }
}
