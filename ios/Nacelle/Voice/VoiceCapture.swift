import Foundation
import NacelleProtocol

/// Du fil audio aux paquets. Le rappel d'entrée du micro écrit dans `ring` (sans allocation ni verrou, voir
/// `AudioRingBuffer`) ; `pump()`, appelée toutes les 20 ms sur une file ordinaire, convertit et découpe.
///
/// `@unchecked Sendable` : `ring` a un seul producteur (le fil audio) et un seul consommateur (`pump`) ; le
/// découpeur n'est touché que par `pump` et `reset`, qui ne s'exécutent jamais en même temps (même file, ou micro
/// arrêté).
final class VoiceCapture: @unchecked Sendable {
    /// Ce que `pump()` rend : les paquets formés, et le niveau sonore du bloc (0 à 1).
    struct Pumped {
        var packets: [Data]
        var level: Float
    }

    /// Une seconde de micro : bien plus que les 20 ms entre deux pompages.
    let ring: AudioRingBuffer
    private let packetizer: VoicePacketizer

    init?(sourceRate: Double) {
        guard let packetizer = VoicePacketizer(sourceRate: sourceRate) else { return nil }
        self.packetizer = packetizer
        ring = AudioRingBuffer(capacity: Int(sourceRate), maxBlocks: 512)
    }

    /// Reprend tout ce que le micro a écrit depuis le dernier appel.
    func pump() -> Pumped {
        var packets: [Data] = []
        var energy = 0.0
        var count = 0
        while let block = ring.pop() {
            for sample in block.samples {
                energy += Double(sample) * Double(sample)
            }
            count += block.samples.count
            packets += packetizer.append(block.samples)
        }
        guard count > 0 else { return Pumped(packets: packets, level: 0) }
        let rms = (energy / Double(count)).squareRoot() / 32_768
        // La parole normale occupe peu de l'échelle : on étire pour que la jauge bouge.
        return Pumped(packets: packets, level: Float(min(1, rms * Self.levelGain)))
    }

    static let levelGain = 6.0

    /// À n'appeler que le micro arrêté.
    func reset() {
        ring.reset()
        packetizer.reset()
    }
}
