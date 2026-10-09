import Foundation
import Synchronization

/// Le tampon entre les paquets reçus et le moteur audio (spec haut-parleur § 5.2) : PCM 16 bits, 16 kHz, mono.
///
/// - Il vise environ 60 ms : tant qu'elles ne sont pas accumulées, la lecture reçoit du silence.
/// - Au-delà de 200 ms d'avance, le plus ancien est jeté, pour garder une voix en direct.
/// - Vide en cours de lecture, il complète de silence et se remplit de nouveau avant de reprendre.
///
/// Écrit par la file du réseau, lu par le fil de rendu audio : un verrou court, aucune allocation en lecture.
public final class JitterBuffer: Sendable {
    public static let sampleRate = 16_000

    public let targetSamples: Int
    public let maxSamples: Int

    private struct State {
        var ring: [Int16]
        var head = 0
        var count = 0
        var primed = false
        var dropped = 0
        var underruns = 0
    }

    private let state: Mutex<State>

    public init(targetMilliseconds: Int = 60, maxMilliseconds: Int = 200) {
        targetSamples = Self.sampleRate * targetMilliseconds / 1000
        maxSamples = Self.sampleRate * maxMilliseconds / 1000
        state = Mutex(State(ring: [Int16](repeating: 0, count: maxSamples)))
    }

    /// Ajoute un paquet PCM (petit-boutiste) ; un octet de trop à la fin est ignoré.
    public func push(_ pcm: some DataProtocol) {
        let bytes = Array(pcm)
        let incoming = bytes.count / 2
        guard incoming > 0 else { return }
        state.withLock { state in
            // Un paquet plus grand que la limite : seule sa fin compte.
            let skipped = max(0, incoming - maxSamples)
            state.dropped += skipped
            // Le plus ancien part pour faire de la place.
            let overflow = max(0, state.count + (incoming - skipped) - maxSamples)
            state.dropped += overflow
            state.head = (state.head + overflow) % maxSamples
            state.count -= overflow
            for index in skipped..<incoming {
                let sample = Int16(bitPattern: UInt16(bytes[2 * index]) | UInt16(bytes[2 * index + 1]) << 8)
                state.ring[(state.head + state.count) % maxSamples] = sample
                state.count += 1
            }
        }
    }

    /// Remplit `count` échantillons flottants (de -1 à 1) pour le moteur audio ; du silence tant que le tampon se remplit.
    public func pull(into output: UnsafeMutablePointer<Float>, count: Int) {
        state.withLock { state in
            if !state.primed, state.count >= targetSamples, state.count > 0 {
                state.primed = true
            }
            var written = 0
            if state.primed {
                written = min(count, state.count)
                for index in 0..<written {
                    output[index] = Float(state.ring[(state.head + index) % maxSamples]) / 32768
                }
                state.head = (state.head + written) % maxSamples
                state.count -= written
                if written < count {
                    state.primed = false
                    state.underruns += 1
                }
            }
            for index in written..<count {
                output[index] = 0
            }
        }
    }

    /// Vide le tampon et remet la pré-charge (début d'une prise de parole) ; les compteurs restent.
    public func reset() {
        state.withLock { state in
            state.head = 0
            state.count = 0
            state.primed = false
        }
    }

    public var bufferedSamples: Int {
        state.withLock { $0.count }
    }

    /// Échantillons jetés depuis le début parce que l'avance dépassait la limite.
    public var droppedSamples: Int {
        state.withLock { $0.dropped }
    }

    /// Fois où la lecture a trouvé le tampon vide en pleine parole.
    public var underruns: Int {
        state.withLock { $0.underruns }
    }
}
