import Foundation

/// Ce que talkd a changé au volume, le temps d'une prise de parole (relecture I2) : `talkd-volume.json`. Si talkd
/// plante ou est tué (SIGKILL) en pleine parole, le démarrage suivant rétablit l'état d'origine, à condition que le
/// volume n'ait pas changé depuis.
public struct VolumeRecovery: Codable, Equatable, Sendable {
    /// Le numéro du périphérique au moment de l'écriture ; il peut changer après un redémarrage de coreaudiod.
    public var device: DeviceID
    /// Le nom du périphérique : c'est lui qui est comparé à la reprise.
    public var deviceName: String
    public var original: SpeakerVolumeState
    public var raisedVolume: Bool
    public var unmuted: Bool
    /// L'état relu après l'écriture de talkd.
    public var written: SpeakerVolumeState
    public var at: Date

    public init(
        device: DeviceID, deviceName: String, original: SpeakerVolumeState, raisedVolume: Bool, unmuted: Bool,
        written: SpeakerVolumeState, at: Date
    ) {
        self.device = device
        self.deviceName = deviceName
        self.original = original
        self.raisedVolume = raisedVolume
        self.unmuted = unmuted
        self.written = written
        self.at = at
    }
}

@MainActor
public protocol VolumeRecoveryStore: AnyObject {
    func save(_ record: VolumeRecovery) throws
    /// nil : aucun fichier. Lève si le fichier existe mais ne se lit pas.
    func load() throws -> VolumeRecovery?
    /// Sans effet si le fichier n'existe pas.
    func clear() throws
}

/// `talkd-volume.json`, écrit de façon atomique.
@MainActor
public final class JSONFileVolumeRecoveryStore: VolumeRecoveryStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func save(_ record: VolumeRecovery) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TalkState.encoder.encode(record).write(to: url, options: .atomic)
    }

    public func load() throws -> VolumeRecovery? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try TalkState.decoder.decode(VolumeRecovery.self, from: Data(contentsOf: url))
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
