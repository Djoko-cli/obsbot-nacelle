import Foundation
import Testing
@testable import TalkCore

@Suite("Détection de voix")
struct VoiceDetectorTests {
    @Test("Valeur efficace d'un paquet constant : amplitude / 32768")
    func rms() {
        #expect(VoiceDetector.rms(pcm(0)) == 0)
        #expect(abs(VoiceDetector.rms(pcm(8192)) - 0.25) < 1e-9)
        #expect(abs(VoiceDetector.rms(pcm(-8192)) - 0.25) < 1e-9)
        #expect(abs(VoiceDetector.rms(pcm(Int16.min)) - 1) < 1e-9)
        #expect(VoiceDetector.rms(Data()) == 0)
    }

    @Test("Voix : la valeur efficace dépasse strictement le seuil")
    func threshold() {
        // 0,01 × 32768 = 327,68 : 327 est dessous, 328 dessus.
        #expect(!VoiceDetector.hasVoice(pcm(327), threshold: 0.01))
        #expect(VoiceDetector.hasVoice(pcm(328), threshold: 0.01))
        #expect(!VoiceDetector.hasVoice(silence, threshold: 0.01))
        #expect(VoiceDetector.hasVoice(voice, threshold: 0.01))
    }

    @Test("Un seuil plus haut écarte un bruit de fond")
    func noiseFloor() {
        #expect(VoiceDetector.hasVoice(pcm(1000), threshold: 0.01))
        #expect(!VoiceDetector.hasVoice(pcm(1000), threshold: 0.05))
    }

    @Test("Échantillons lus en petit-boutiste, sur un Data découpé (index non nul)")
    func littleEndianAndSlices() {
        // 0x0100 = 256 en petit-boutiste : octets [0x00, 0x01].
        var data = Data([0xFF])
        data.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        let slice = data.dropFirst()
        #expect(abs(VoiceDetector.rms(Data(slice)) - 256.0 / 32768.0) < 1e-9)
        #expect(abs(VoiceDetector.rms(slice) - 256.0 / 32768.0) < 1e-9)
    }
}
