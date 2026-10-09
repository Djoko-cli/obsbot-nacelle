import Dispatch
import Foundation
import Testing
@testable import Nacelle

@Suite("Tampon audio circulaire", .timeLimit(.minutes(1)))
struct AudioRingBufferTests {
    /// Écrit `count` échantillons qui valent `first`, `first + 1`, … (reconnaissables à la lecture).
    @discardableResult
    private func write(_ ring: AudioRingBuffer, first: Int16, count: Int, time: UInt64) -> Bool {
        let samples = (0..<count).map { first &+ Int16($0) }
        return samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: count, time: time) }
    }

    @Test("Ordre préservé : les blocs ressortent dans l'ordre, avec leur heure")
    func order() throws {
        let ring = AudioRingBuffer(capacity: 1_000)
        write(ring, first: 0, count: 100, time: 10)
        write(ring, first: 100, count: 50, time: 20)
        write(ring, first: 150, count: 100, time: 30)
        let a = try #require(ring.pop())
        let b = try #require(ring.pop())
        let c = try #require(ring.pop())
        #expect(ring.pop() == nil)
        #expect([a.time, b.time, c.time] == [10, 20, 30])
        #expect(a.samples + b.samples + c.samples == (0..<250).map { Int16($0) })
        #expect(ring.droppedSamples == 0)
    }

    @Test("Aucune perte tant que le tampon n'est pas plein, même pile à la capacité, y compris en bouclant")
    func noLossUntilFull() throws {
        let ring = AudioRingBuffer(capacity: 300)
        // Plusieurs tours du tampon, par blocs de 100 : le dernier échantillon tombe toujours sur la fin.
        for round in 0..<10 {
            for index in 0..<3 {
                #expect(write(ring, first: Int16(round * 300 + index * 100), count: 100, time: UInt64(round * 3 + index)))
            }
            for index in 0..<3 {
                let block = try #require(ring.pop())
                #expect(block.samples == (0..<100).map { Int16(round * 300 + index * 100 + $0) })
            }
        }
        #expect(ring.droppedSamples == 0)
        // Un bloc qui déborde la fin du tampon (écriture en deux morceaux) revient intact.
        write(ring, first: 0, count: 250, time: 1)
        _ = ring.pop()
        write(ring, first: 1_000, count: 250, time: 2)
        #expect(ring.pop()?.samples == (0..<250).map { Int16(1_000 + $0) })
    }

    @Test("Débordement : l'écriture ne rend jamais la main tard, les échantillons perdus sont comptés, le reste est intact")
    func overflow() throws {
        let ring = AudioRingBuffer(capacity: 300)
        #expect(write(ring, first: 0, count: 100, time: 1))
        #expect(write(ring, first: 100, count: 100, time: 2))
        #expect(write(ring, first: 200, count: 100, time: 3))
        // Plein : les blocs suivants sont refusés tout de suite et comptés.
        #expect(!write(ring, first: 300, count: 100, time: 4))
        #expect(!write(ring, first: 400, count: 40, time: 5))
        #expect(ring.droppedSamples == 140)
        #expect(ring.pop()?.samples == (0..<100).map { Int16($0) })
        // Une place s'est libérée : l'écriture reprend, le bloc perdu laisse un trou dans les heures.
        #expect(write(ring, first: 500, count: 100, time: 6))
        let times = [ring.pop()?.time, ring.pop()?.time, ring.pop()?.time]
        #expect(times == [2, 3, 6])
        #expect(ring.pop() == nil)
    }

    @Test("Un bloc plus grand que le tampon est refusé et compté")
    func oversized() {
        let ring = AudioRingBuffer(capacity: 100)
        #expect(!write(ring, first: 0, count: 101, time: 1))
        #expect(ring.droppedSamples == 101)
        #expect(ring.pop() == nil)
    }

    @Test("Silence : des zéros, avec l'heure donnée")
    func silence() throws {
        let ring = AudioRingBuffer(capacity: 100)
        #expect(ring.writeSilence(count: 40, time: 7))
        let block = try #require(ring.pop())
        #expect(block.time == 7)
        #expect(block.samples == [Int16](repeating: 0, count: 40))
    }

    @Test("Remise à zéro : le contenu est vidé, le compteur aussi")
    func reset() {
        let ring = AudioRingBuffer(capacity: 100)
        write(ring, first: 0, count: 60, time: 1)
        write(ring, first: 0, count: 60, time: 2)
        #expect(ring.droppedSamples == 60)
        ring.reset()
        #expect(ring.pop() == nil)
        #expect(ring.droppedSamples == 0)
        #expect(write(ring, first: 0, count: 100, time: 3))
    }

    @Test("Un producteur et un consommateur sur deux fils : ordre conservé, rien ne se perd sans être compté")
    func concurrent() throws {
        let ring = AudioRingBuffer(capacity: 2_000)
        let blocks = 20_000
        let size = 48
        let consumed = Locked(Consumed())
        let done = DispatchGroup()
        done.enter()
        Thread.detachNewThread {
            // Producteur : va aussi vite qu'il peut, sans jamais attendre le consommateur.
            for index in 0..<blocks {
                let value = Int16(truncatingIfNeeded: index)
                let samples = [Int16](repeating: value, count: size)
                samples.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: size, time: UInt64(index)) }
            }
            done.leave()
        }
        // Consommateur : borné par une échéance, jamais d'attente sans fin.
        let deadline = DispatchTime.now() + .seconds(20)
        var producerDone = false
        while DispatchTime.now() < deadline {
            if let block = ring.pop() {
                consumed.withLock { state in
                    state.count += 1
                    if block.time <= state.lastTime && state.count > 1 { state.outOfOrder += 1 }
                    state.lastTime = block.time
                    if block.samples.contains(where: { $0 != Int16(truncatingIfNeeded: block.time) }) { state.corrupted += 1 }
                }
            } else if producerDone {
                break
            } else {
                producerDone = done.wait(timeout: .now()) == .success
            }
        }
        #expect(producerDone)
        let state = consumed.withLock { $0 }
        #expect(state.outOfOrder == 0)
        #expect(state.corrupted == 0)
        #expect(state.count > 0)
        #expect(state.count * size + ring.droppedSamples == blocks * size)
    }
}

private struct Consumed {
    var count = 0
    var lastTime: UInt64 = 0
    var outOfOrder = 0
    var corrupted = 0
}

/// Valeur protégée par un verrou, pour les tests à deux fils.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
