import Foundation
import Synchronization
import Testing
@preconcurrency import WebRTC
@testable import Nacelle

/// Le côté audio réel de la parole, branché sur un périphérique à session et unités simulées : ni micro, ni haut-parleur.
@MainActor
@Suite("Parole : micro, pompe et périphérique", .timeLimit(.minutes(1)))
struct DeviceSpeechAudioTests {
    let session = FakeSession()
    let units = FakeUnits()
    let device: PlayoutAudioDevice
    let audio: DeviceSpeechAudio
    private let delegate = SilentDelegate()

    init() {
        device = PlayoutAudioDevice(session: session, units: units)
        _ = device.initialize(with: delegate)
        audio = DeviceSpeechAudio(device: device, pumpInterval: 0.01)
    }

    private func startPlayout() {
        #expect(device.initializePlayout())
        #expect(device.startPlayout())
    }

    /// Attend (5 s au plus) qu'une condition soit vraie, sans bloquer le fil principal.
    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    @Test("Sans lecture en cours, le micro ne démarre pas")
    func needsPlayout() async {
        #expect(!(await audio.begin()))
        #expect(!device.isSpeaking)
        #expect(units.kinds.isEmpty)
    }

    @Test("Le micro démarre, la session bascule ; la fin rétablit la lecture seule")
    func beginEnd() async {
        startPlayout()
        #expect(await audio.begin())
        #expect(device.isSpeaking)
        #expect(units.kinds == ["playout", "voiceChat"])
        audio.end()
        #expect(!device.isSpeaking)
        #expect(units.kinds == ["playout", "voiceChat", "playout"])
        // Une fin de plus ne fait rien.
        audio.end()
        #expect(units.kinds.count == 3)
    }

    @Test("Les échantillons écrits par le fil audio ressortent en paquets de 640 octets, livrés sur le fil principal")
    func packetsFlow() async throws {
        startPlayout()
        let received = Mutex<[Data]>([])
        let levels = Mutex<[Float]>([])
        audio.onPackets = { packets, level in
            #expect(Thread.isMainThread)
            received.withLock { $0 += packets }
            levels.withLock { $0.append(level) }
        }
        #expect(await audio.begin())
        let ring = try #require(audio.capture?.ring)
        // Le « fil audio » : un autre fil écrit 10 ms de signal à la fois.
        let writer = Thread {
            for block in 0..<100 {
                let samples = (0..<480).map { Int16(10_000 * sin(2 * .pi * 440 * Double(block * 480 + $0) / 48_000)) }
                samples.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: 480, time: HostClock.nowNanoseconds()) }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        writer.start()
        #expect(await until { received.withLock { $0.count } >= 30 })
        #expect(received.withLock { $0.allSatisfy { $0.count == 640 } })
        #expect(levels.withLock { $0.contains { $0 > 0.1 } })
        audio.end()
    }

    @Test("Après la fin, plus aucun paquet n'est livré")
    func nothingAfterEnd() async throws {
        startPlayout()
        let count = Mutex(0)
        audio.onPackets = { _, _ in count.withLock { $0 += 1 } }
        #expect(await audio.begin())
        #expect(await until { count.withLock { $0 } > 0 })
        audio.end()
        // Les livraisons déjà postées sur le fil principal se vident, puis le compte ne bouge plus.
        try await Task.sleep(for: .milliseconds(100))
        let settled = count.withLock { $0 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(count.withLock { $0 } == settled)
    }

    @Test("Interruption signalée depuis un autre fil : onInterrupted arrive sur le fil principal")
    func interruptionFromAudioThread() async {
        startPlayout()
        let calls = Mutex(0)
        audio.onInterrupted = {
            #expect(Thread.isMainThread)
            calls.withLock { $0 += 1 }
        }
        #expect(await audio.begin())
        let device = device
        let thread = Thread {
            device.interruptionBegan()
        }
        thread.start()
        #expect(await until { calls.withLock { $0 } == 1 })
        #expect(!device.isSpeaking)
    }

    @Test("Périphérique dont le fil WebRTC est un autre fil : début et fin de parole sans plantage ni blocage")
    func beginAndEndOnAnotherThread() async {
        let queue = DispatchQueue(label: "essai.webrtc.audio")
        let device = PlayoutAudioDevice(session: session, units: units)
        _ = device.initialize(with: QueueDelegate(queue: queue))
        #expect(device.initializePlayout())
        #expect(device.startPlayout())
        let speech = DeviceSpeechAudio(device: device, pumpInterval: 0.01)
        #expect(await speech.begin())
        #expect(device.isSpeaking)
        speech.end()
        // L'arrêt est exécuté sur le fil de WebRTC : on attend qu'il ait fini, 5 s au plus.
        #expect(await until { !device.isSpeaking })
        queue.sync {}
        #expect(units.kinds == ["playout", "voiceChat", "playout"])
    }

    @Test("M2 : interruption pendant le démarrage — le démarrage échoue, la pompe ne tourne pas et le périphérique revient à la lecture")
    func interruptedWhileStarting() async {
        let gate = GateDelegate()
        let device = PlayoutAudioDevice(session: session, units: units)
        _ = device.initialize(with: gate)
        #expect(device.initializePlayout())
        #expect(device.startPlayout())
        let speech = DeviceSpeechAudio(device: device, pumpInterval: 0.01)
        let begin = Task { await speech.begin() }
        // Le démarrage attend le fil de WebRTC (retenu par la porte).
        #expect(await until { gate.pending == 1 })
        // Le système interrompt la parole pendant cette attente.
        device.onSpeakingInterrupted?()
        #expect(await until { speech.capture == nil })
        gate.releaseAll()
        #expect(await begin.value == false)
        #expect(!speech.isPumpRunning)
        // Le périphérique, lui, avait démarré la parole : sa fin est demandée au fil de WebRTC.
        gate.releaseAll()
        #expect(!device.isSpeaking)
    }

    @Test("Deux démarrages sans fin entre eux : le second est refusé")
    func doubleBegin() async {
        startPlayout()
        #expect(await audio.begin())
        #expect(!(await audio.begin()))
        audio.end()
    }
}

/// Comme `SilentDelegate`, mais `dispatchAsync` retient le travail jusqu'à `releaseAll()` : l'essai décide du moment où
/// le fil de WebRTC « passe ».
final class GateDelegate: NSObject, RTCAudioDeviceDelegate, @unchecked Sendable {
    private let held = Mutex<[@Sendable () -> Void]>([])

    var pending: Int {
        held.withLock { $0.count }
    }

    /// Exécute, dans l'ordre et sur le fil appelant, tout ce qui a été retenu.
    func releaseAll() {
        let work = held.withLock { blocks in
            defer { blocks = [] }
            return blocks
        }
        work.forEach { $0() }
    }

    var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock { { _, _, _, _, _, _, _ in noErr } }
    var preferredInputSampleRate: Double { 48_000 }
    var preferredInputIOBufferDuration: TimeInterval { 0.01 }
    var preferredOutputSampleRate: Double { 48_000 }
    var preferredOutputIOBufferDuration: TimeInterval { 0.01 }
    var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock { { _, _, _, _, _ in noErr } }
    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}
    func dispatchAsync(_ block: @escaping () -> Void) {
        nonisolated(unsafe) let block = block
        held.withLock { $0.append { block() } }
    }
    func dispatchSync(_ block: @escaping () -> Void) { block() }
}

final class SilentDelegate: NSObject, RTCAudioDeviceDelegate, @unchecked Sendable {
    var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock { { _, _, _, _, _, _, _ in noErr } }
    var preferredInputSampleRate: Double { 48_000 }
    var preferredInputIOBufferDuration: TimeInterval { 0.01 }
    var preferredOutputSampleRate: Double { 48_000 }
    var preferredOutputIOBufferDuration: TimeInterval { 0.01 }
    var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock { { _, _, _, _, _ in noErr } }
    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}
    func dispatchAsync(_ block: @escaping () -> Void) { block() }
    func dispatchSync(_ block: @escaping () -> Void) { block() }
}

/// Comme `SilentDelegate`, mais `dispatchAsync` s'exécute sur une autre file : le fil de WebRTC.
final class QueueDelegate: NSObject, RTCAudioDeviceDelegate, @unchecked Sendable {
    let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock { { _, _, _, _, _, _, _ in noErr } }
    var preferredInputSampleRate: Double { 48_000 }
    var preferredInputIOBufferDuration: TimeInterval { 0.01 }
    var preferredOutputSampleRate: Double { 48_000 }
    var preferredOutputIOBufferDuration: TimeInterval { 0.01 }
    var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock { { _, _, _, _, _ in noErr } }
    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}
    func dispatchAsync(_ block: @escaping () -> Void) { queue.async(execute: block) }
    func dispatchSync(_ block: @escaping () -> Void) { queue.sync(execute: block) }
}
