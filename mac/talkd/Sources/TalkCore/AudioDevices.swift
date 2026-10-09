import Foundation

/// L'identifiant d'un périphérique audio (`AudioObjectID` de CoreAudio).
public typealias DeviceID = UInt32

public enum AudioTransport: Equatable, Sendable {
    /// `kAudioDeviceTransportTypeBuiltIn` : les haut-parleurs et le micro du Mac.
    case builtIn
    case other
}

/// Ce que talkd sait d'un périphérique audio pour choisir le sien.
public struct AudioDeviceInfo: Equatable, Sendable {
    public var id: DeviceID
    public var name: String
    public var transport: AudioTransport
    /// Nombre de canaux de sortie ; 0 pour un micro.
    public var outputChannels: Int
    public var isDefaultOutput: Bool

    public init(id: DeviceID, name: String, transport: AudioTransport, outputChannels: Int, isDefaultOutput: Bool) {
        self.id = id
        self.name = name
        self.transport = transport
        self.outputChannels = outputChannels
        self.isDefaultOutput = isDefaultOutput
    }
}

/// La liste des périphériques, derrière un protocole : CoreAudio dans l'exécutable, une liste simulée dans les tests.
@MainActor
public protocol DeviceCatalog: AnyObject {
    func devices() throws -> [AudioDeviceInfo]
    /// `handler` est appelé quand la liste des périphériques ou la sortie par défaut change.
    func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> (any Cancellable)?
}

/// Les haut-parleurs intégrés (spec haut-parleur § 4.1 et § 5.3) : un périphérique de transport `BuiltIn` qui a des
/// canaux de sortie, choisi par son type et non par son rang, quelle que soit la sortie par défaut de Réglages.
public enum SpeakerPicker {
    /// Plusieurs candidats : celui qui est la sortie par défaut, sinon le plus petit numéro (le choix ne dépend pas
    /// de l'ordre de la liste).
    public static func builtInSpeakers(in devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        devices
            .filter { $0.transport == .builtIn && $0.outputChannels > 0 }
            .min { ($0.isDefaultOutput ? 0 : 1, $0.id) < ($1.isDefaultOutput ? 0 : 1, $1.id) }
    }
}
