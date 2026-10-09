import Foundation
import Testing
@testable import TalkCore

@Suite("Tampon de lecture")
struct JitterBufferTests {
    /// Tire `count` échantillons et les rend.
    private func pull(_ buffer: JitterBuffer, _ count: Int) -> [Float] {
        var out = [Float](repeating: 99, count: count)
        out.withUnsafeMutableBufferPointer { buffer.pull(into: $0.baseAddress!, count: count) }
        return out
    }

    @Test("Mesures à 16 kHz : 60 ms = 960 échantillons visés, 200 ms = 3200 au plus")
    func sizes() {
        let buffer = JitterBuffer()
        #expect(buffer.targetSamples == 960)
        #expect(buffer.maxSamples == 3200)
    }

    @Test("Avant 60 ms accumulées, la lecture reçoit du silence : le tampon se remplit")
    func prefill() {
        let buffer = JitterBuffer()
        buffer.push(pcm(16384)) // 20 ms
        buffer.push(pcm(16384)) // 40 ms
        #expect(pull(buffer, 160).allSatisfy { $0 == 0 })
        #expect(buffer.bufferedSamples == 640)
        buffer.push(pcm(16384)) // 60 ms : 960 échantillons
        let out = pull(buffer, 160)
        #expect(out.allSatisfy { $0 == 0.5 })
        #expect(buffer.bufferedSamples == 800)
    }

    @Test("Échantillons convertis en flottants dans [-1, 1[ ")
    func conversion() {
        let buffer = JitterBuffer(targetMilliseconds: 0)
        buffer.push(pcm(Int16.min, samples: 2))
        buffer.push(pcm(8192, samples: 2))
        #expect(pull(buffer, 4) == [-1, -1, 0.25, 0.25])
    }

    @Test("Tampon vide en cours de lecture : le reste est complété de silence, puis il se remplit de nouveau")
    func underrun() {
        let buffer = JitterBuffer()
        for _ in 0..<3 { buffer.push(pcm(16384)) }
        _ = pull(buffer, 800)
        #expect(buffer.underruns == 0)
        // Il reste 160 échantillons ; on en demande 320.
        let out = pull(buffer, 320)
        #expect(out.prefix(160).allSatisfy { $0 == 0.5 })
        #expect(out.suffix(160).allSatisfy { $0 == 0 })
        #expect(buffer.underruns == 1)
        // Un paquet de 20 ms ne suffit plus : il faut de nouveau 60 ms.
        buffer.push(pcm(16384))
        #expect(pull(buffer, 160).allSatisfy { $0 == 0 })
        // Le silence qui suit une fin de parole ne compte pas comme une nouvelle coupure.
        _ = pull(buffer, 160)
        #expect(buffer.underruns == 1)
    }

    @Test("Au-delà de 200 ms d'avance, le plus ancien est jeté et compté")
    func dropsOldest() {
        let buffer = JitterBuffer()
        // 10 paquets de 20 ms = 200 ms : rien de jeté.
        for _ in 0..<10 { buffer.push(pcm(1000)) }
        #expect(buffer.bufferedSamples == 3200)
        #expect(buffer.droppedSamples == 0)
        // Un onzième, plus fort : le premier (le plus ancien) part.
        buffer.push(pcm(2000))
        #expect(buffer.bufferedSamples == 3200)
        #expect(buffer.droppedSamples == 320)
        // Le plus récent est bien gardé : il est le dernier à sortir.
        let out = pull(buffer, 3200)
        #expect(out.last == Float(2000) / 32768)
        #expect(out.first == Float(1000) / 32768)
    }

    @Test("Un paquet plus grand que la limite : seule la fin est gardée")
    func hugePacket() {
        let buffer = JitterBuffer()
        buffer.push(pcm(1000, samples: 2048)) // 4096 octets
        buffer.push(pcm(1000, samples: 2048))
        #expect(buffer.bufferedSamples == 3200)
        #expect(buffer.droppedSamples == 4096 - 3200)
    }

    @Test("reset() vide le tampon, remet la pré-charge, garde les compteurs")
    func reset() {
        let buffer = JitterBuffer()
        for _ in 0..<12 { buffer.push(pcm(1000)) }
        let dropped = buffer.droppedSamples
        #expect(dropped > 0)
        buffer.reset()
        #expect(buffer.bufferedSamples == 0)
        #expect(buffer.droppedSamples == dropped)
        buffer.push(pcm(16384))
        #expect(pull(buffer, 160).allSatisfy { $0 == 0 })
    }

    @Test("Un octet de trop à la fin d'un paquet est ignoré")
    func oddByte() {
        let buffer = JitterBuffer(targetMilliseconds: 0)
        var data = pcm(16384, samples: 2)
        data.append(0x7F)
        buffer.push(data)
        #expect(buffer.bufferedSamples == 2)
    }

    @Test("Tampon tiré depuis un autre fil pendant que des paquets arrivent : aucun échantillon perdu ni inventé")
    func concurrentAccess() async {
        let buffer = JitterBuffer(targetMilliseconds: 0, maxMilliseconds: 10_000)
        let total = 500
        let producer = Task.detached {
            for _ in 0..<total {
                buffer.push(pcm(16384, samples: 80))
            }
        }
        let consumer = Task.detached { () -> Int in
            var got = 0
            let deadline = Date().addingTimeInterval(5)
            var scratch = [Float](repeating: 0, count: 64)
            while got < total * 80, Date() < deadline {
                let available = min(buffer.bufferedSamples, 64)
                if available == 0 {
                    await Task.yield()
                    continue
                }
                scratch.withUnsafeMutableBufferPointer { buffer.pull(into: $0.baseAddress!, count: available) }
                got += scratch.prefix(available).filter { $0 == 0.5 }.count
            }
            return got
        }
        await producer.value
        let got = await consumer.value
        #expect(got == total * 80)
        #expect(buffer.droppedSamples == 0)
    }
}
