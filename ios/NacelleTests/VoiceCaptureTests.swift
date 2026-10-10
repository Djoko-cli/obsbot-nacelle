import Foundation
import NacelleProtocol
import Testing
@testable import Nacelle

/// Un signal de synthèse, en blocs, comme le ferait le micro.
private enum FakeMic {
    static func sine(rate: Double, hertz: Double = 440, amplitude: Double = 10_000, seconds: Double, from start: Int = 0) -> [Int16] {
        (0..<Int(rate * seconds)).map { index in
            Int16(amplitude * sin(2 * .pi * hertz * Double(index + start) / rate))
        }
    }

    static func blocks(_ samples: [Int16], size: Int) -> [[Int16]] {
        stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
    }

    static func rms(_ packet: Data) -> Double {
        let values = packet.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
        return (values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count)).squareRoot()
    }
}

@Suite("File bornée de paquets", .timeLimit(.minutes(1)))
struct BoundedQueueTests {
    @Test("Dix paquets au plus : le plus ancien est jeté, les autres restent dans l'ordre")
    func dropsOldest() {
        var queue = BoundedQueue<Int>(capacity: 10)
        for value in 1...10 {
            let dropped = queue.push(value)
            #expect(!dropped)
        }
        #expect(queue.count == 10)
        let first = queue.push(11)
        let second = queue.push(12)
        #expect(first && second)
        #expect(queue.count == 10)
        #expect(queue.droppedCount == 2)
        var popped: [Int] = []
        while let value = queue.pop() { popped.append(value) }
        #expect(popped == Array(3...12))
    }

    @Test("Vider la file la remet à zéro, compteur compris")
    func clear() {
        var queue = BoundedQueue<Int>(capacity: 2)
        _ = queue.push(1); _ = queue.push(2); _ = queue.push(3)
        queue.removeAll()
        #expect(queue.count == 0)
        #expect(queue.droppedCount == 0)
        let value = queue.pop()
        #expect(value == nil)
    }

    @Test("La capacité des paquets vocaux est de 10 (200 ms)")
    func voiceCapacity() {
        #expect(Speaker.maxQueuedPackets == 10)
        #expect(Speaker.maxQueuedPackets * VoiceFrame.durationMilliseconds == 200)
    }
}

@Suite("Découpage du micro en paquets de 640 octets", .timeLimit(.minutes(1)))
struct VoicePacketizerTests {
    @Test("1 s à 48 kHz en blocs de 10 ms : une cinquantaine de paquets, tous de 640 octets exactement")
    func packetSizes() throws {
        let packetizer = try #require(VoicePacketizer(sourceRate: 48_000))
        var packets: [Data] = []
        for block in FakeMic.blocks(FakeMic.sine(rate: 48_000, seconds: 1), size: 480) {
            packets += packetizer.append(block)
        }
        #expect(packets.allSatisfy { $0.count == VoiceFrame.byteCount })
        // 1 s = 50 paquets, moins la latence de la conversion (quelques millisecondes).
        #expect((47...50).contains(packets.count), "\(packets.count) paquets")
    }

    @Test("Blocs de tailles quelconques (441, 1, 1023, 4096) : aucun échantillon perdu, paquets toujours de 640 octets")
    func oddBlockSizes() throws {
        let packetizer = try #require(VoicePacketizer(sourceRate: 48_000))
        let samples = FakeMic.sine(rate: 48_000, seconds: 2)
        var packets: [Data] = []
        var offset = 0
        var sizes = [441, 1, 1023, 4096].makeIterator()
        while offset < samples.count {
            let size = sizes.next() ?? { sizes = [441, 1, 1023, 4096].makeIterator(); return sizes.next()! }()
            let end = min(offset + size, samples.count)
            packets += packetizer.append(Array(samples[offset..<end]))
            offset = end
        }
        #expect(packets.allSatisfy { $0.count == VoiceFrame.byteCount })
        // 2 s = 100 paquets, à la latence de la conversion près.
        #expect((95...100).contains(packets.count), "\(packets.count) paquets")
        // Ce qui n'a pas fait un paquet entier attend le suivant.
        #expect(packetizer.pendingSamples < VoiceFrame.samplesPerFrame)
    }

    @Test("Le niveau du signal est conservé (conversion 48 kHz vers 16 kHz sans gain)")
    func levelPreserved() throws {
        let packetizer = try #require(VoicePacketizer(sourceRate: 48_000))
        var packets: [Data] = []
        for block in FakeMic.blocks(FakeMic.sine(rate: 48_000, amplitude: 10_000, seconds: 1), size: 480) {
            packets += packetizer.append(block)
        }
        let expected = 10_000 / 2.0.squareRoot()
        // Le premier paquet contient l'amorçage du filtre : on le laisse de côté.
        for packet in packets.dropFirst() {
            let rms = FakeMic.rms(packet)
            #expect(abs(rms - expected) / expected < 0.15, "RMS \(rms)")
        }
    }

    @Test("PCM 16 bits petit-boutiste : une valeur continue sort avec ses octets dans l'ordre")
    func littleEndian() throws {
        let packetizer = try #require(VoicePacketizer(sourceRate: 48_000))
        var packets: [Data] = []
        for _ in 0..<30 {
            packets += packetizer.append([Int16](repeating: 0x1234, count: 480))
        }
        let packet = try #require(packets.last)
        let sample = Int16(packet[300]) | Int16(packet[301]) << 8
        #expect(abs(Int(sample) - 0x1234) < 200, "échantillon \(sample)")
    }

    @Test("Silence en entrée : silence en sortie")
    func silence() throws {
        let packetizer = try #require(VoicePacketizer(sourceRate: 48_000))
        var packets: [Data] = []
        for _ in 0..<20 {
            packets += packetizer.append([Int16](repeating: 0, count: 480))
        }
        #expect(!packets.isEmpty)
        #expect(packets.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test("Source déjà à 16 kHz : les paquets sont découpés sans perte")
    func sameRate() throws {
        let packetizer = try #require(VoicePacketizer(sourceRate: 16_000))
        let samples = FakeMic.sine(rate: 16_000, seconds: 1)
        var packets: [Data] = []
        for block in FakeMic.blocks(samples, size: 160) {
            packets += packetizer.append(block)
        }
        #expect(packets.allSatisfy { $0.count == VoiceFrame.byteCount })
        #expect((49...50).contains(packets.count))
    }

    @Test("Fréquence d'échantillonnage absurde : pas de convertisseur")
    func invalidRate() {
        #expect(VoicePacketizer(sourceRate: 0) == nil)
        #expect(VoicePacketizer(sourceRate: -48_000) == nil)
    }

    @Test("reset() oublie les échantillons en attente")
    func reset() throws {
        let packetizer = try #require(VoicePacketizer(sourceRate: 48_000))
        _ = packetizer.append([Int16](repeating: 5, count: 300))
        packetizer.reset()
        #expect(packetizer.pendingSamples == 0)
    }
}

@Suite("Capture : du fil audio aux paquets", .timeLimit(.minutes(1)))
struct VoiceCaptureTests {
    @Test("Un faux micro écrit dans le tampon depuis un autre fil ; pump() rend des paquets de 640 octets et un niveau")
    func pumpsFromAnotherThread() async throws {
        let capture = try #require(VoiceCapture(sourceRate: 48_000))
        let ring = capture.ring
        let samples = FakeMic.sine(rate: 48_000, seconds: 1)
        // Le « fil audio » : écrit des blocs de 10 ms, comme le rappel d'entrée.
        await Task.detached {
            for block in FakeMic.blocks(samples, size: 480) {
                block.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: block.count, time: HostClock.nowNanoseconds()) }
            }
        }.value
        let result = capture.pump()
        #expect(!result.packets.isEmpty)
        #expect(result.packets.allSatisfy { $0.count == VoiceFrame.byteCount })
        #expect(result.level > 0.1 && result.level <= 1)
        // Le tampon est vidé, rien ne revient.
        #expect(capture.pump().packets.isEmpty)
    }

    @Test("Tampon vide : aucun paquet, niveau nul")
    func emptyRing() throws {
        let capture = try #require(VoiceCapture(sourceRate: 48_000))
        let result = capture.pump()
        #expect(result.packets.isEmpty)
        #expect(result.level == 0)
    }

    @Test("Silence du micro : niveau nul")
    func silentLevel() throws {
        let capture = try #require(VoiceCapture(sourceRate: 48_000))
        let silence = [Int16](repeating: 0, count: 4800)
        silence.withUnsafeBufferPointer { _ = capture.ring.write($0.baseAddress!, count: silence.count, time: 0) }
        #expect(capture.pump().level == 0)
    }

    @Test("reset() vide le tampon et le découpeur")
    func reset() throws {
        let capture = try #require(VoiceCapture(sourceRate: 48_000))
        let block = FakeMic.sine(rate: 48_000, seconds: 0.5)
        block.withUnsafeBufferPointer { _ = capture.ring.write($0.baseAddress!, count: block.count, time: 0) }
        capture.reset()
        #expect(capture.pump().packets.isEmpty)
    }
}
