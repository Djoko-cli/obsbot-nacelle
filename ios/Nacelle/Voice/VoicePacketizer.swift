import AVFoundation
import NacelleProtocol

/// Du micro aux paquets : convertit le PCM 16 bits mono du micro vers 16 kHz (`AVAudioConverter`), puis le découpe
/// en paquets de `VoiceFrame.byteCount` octets, petit-boutistes (spec parler § 6.2). Les échantillons qui ne font pas
/// un paquet entier attendent le prochain appel. Alloue : jamais sur le fil audio temps réel, seulement sur la file
/// de la pompe. Un seul fil à la fois.
final class VoicePacketizer {
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private var pending: [Int16] = []

    /// Nil si la fréquence est inutilisable.
    init?(sourceRate: Double) {
        guard sourceRate > 0,
              let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sourceRate, channels: 1, interleaved: true),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(VoiceFrame.sampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { return nil }
        sourceFormat = source
        targetFormat = target
        self.converter = converter
        pending.reserveCapacity(VoiceFrame.samplesPerFrame * 4)
    }

    /// Échantillons à 16 kHz reçus mais pas encore rendus (moins d'un paquet).
    var pendingSamples: Int {
        pending.count
    }

    /// Convertit ce bloc du micro et rend les paquets complets qu'il permet de former.
    func append(_ samples: [Int16]) -> [Data] {
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.int16ChannelData?[0] else { return [] }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        input.frameLength = AVAudioFrameCount(samples.count)

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, failure == nil, let converted = output.int16ChannelData?[0] else { return [] }
        pending.append(contentsOf: UnsafeBufferPointer(start: converted, count: Int(output.frameLength)))
        return takePackets()
    }

    /// Oublie ce qui attend, et l'état interne du convertisseur.
    func reset() {
        pending.removeAll(keepingCapacity: true)
        converter.reset()
    }

    private func takePackets() -> [Data] {
        var packets: [Data] = []
        let size = VoiceFrame.samplesPerFrame
        var start = 0
        while pending.count - start >= size {
            let slice = pending[start..<start + size]
            // Sur iOS (petit-boutiste), la mémoire des Int16 est déjà dans l'ordre du réseau voulu.
            packets.append(slice.withUnsafeBytes { Data($0) })
            start += size
        }
        if start > 0 {
            pending.removeFirst(start)
        }
        return packets
    }
}
