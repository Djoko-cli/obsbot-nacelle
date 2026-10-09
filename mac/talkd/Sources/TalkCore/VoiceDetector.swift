import Foundation

/// Un paquet « contient de la voix » si sa valeur efficace dépasse le seuil (spec haut-parleur § 5.2).
/// Le PCM est en 16 bits petit-boutiste, mono ; la valeur efficace est rapportée à la pleine échelle (0 à 1).
public enum VoiceDetector {
    public static func rms(_ pcm: some DataProtocol) -> Double {
        var sum = 0.0
        var count = 0
        var low: UInt8?
        for byte in pcm {
            guard let first = low else {
                low = byte
                continue
            }
            low = nil
            let sample = Int16(bitPattern: UInt16(first) | UInt16(byte) << 8)
            let value = Double(sample)
            sum += value * value
            count += 1
        }
        guard count > 0 else { return 0 }
        return (sum / Double(count)).squareRoot() / 32768
    }

    public static func hasVoice(_ pcm: some DataProtocol, threshold: Double) -> Bool {
        rms(pcm) > threshold
    }
}
