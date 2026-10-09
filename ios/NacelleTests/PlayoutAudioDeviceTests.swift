import AudioToolbox
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import Nacelle

@Suite("Périphérique audio en sortie seule")
struct PlayoutAudioDeviceTests {
    @Test("Sortie mono 48 kHz, aucune entrée : l'enregistrement est refusé")
    func outputOnly() {
        let device = PlayoutAudioDevice()
        #expect(device.deviceOutputSampleRate == 48_000)
        #expect(device.outputNumberOfChannels == 1)
        #expect(device.inputNumberOfChannels == 0)
        #expect(!device.initializeRecording())
        #expect(!device.startRecording())
        #expect(!device.isRecordingInitialized)
        #expect(!device.isRecording)
        #expect(!device.isInitialized)
        #expect(device.stopPlayout())
    }
}

/// Le fil de rendu sans matériel : un faux délégué WebRTC qui fournit du PCM de synthèse.
@Suite("Périphérique audio : copie pour l'enregistrement et sortie muette", .timeLimit(.minutes(1)))
struct PlayoutCaptureTests {
    /// Délégué WebRTC de test : `getPlayoutData` remplit le tampon avec `fill`.
    private final class FakeDelegate: NSObject, RTCAudioDeviceDelegate, @unchecked Sendable {
        var fill: @Sendable (UnsafeMutablePointer<Int16>, Int) -> AudioUnitRenderActionFlags = { samples, count in
            for index in 0..<count { samples[index] = Int16(index + 1) }
            return []
        }

        var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock { { _, _, _, _, _, _, _ in noErr } }
        var preferredInputSampleRate: Double { 48_000 }
        var preferredInputIOBufferDuration: TimeInterval { 0.01 }
        var preferredOutputSampleRate: Double { 48_000 }
        var preferredOutputIOBufferDuration: TimeInterval { 0.01 }

        var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock {
            { [weak self] flags, _, _, frames, data in
                let buffer = UnsafeMutableAudioBufferListPointer(data)[0]
                let samples = buffer.mData!.assumingMemoryBound(to: Int16.self)
                if let produced = self?.fill(samples, Int(frames)) {
                    flags.pointee.formUnion(produced)
                }
                return noErr
            }
        }

        func notifyAudioInputParametersChange() {}
        func notifyAudioOutputParametersChange() {}
        func notifyAudioInputInterrupted() {}
        func notifyAudioOutputInterrupted() {}
        func dispatchAsync(_ block: @escaping () -> Void) { block() }
        func dispatchSync(_ block: @escaping () -> Void) { block() }
    }

    /// Un appel de rendu de `frames` échantillons ; rend ce que le haut-parleur recevrait.
    private func render(_ device: PlayoutAudioDevice, frames: Int = 480) -> (samples: [Int16], silent: Bool) {
        var output = [Int16](repeating: 0x7777, count: frames)
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        let status = output.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            )
            return device.render(&flags, &timestamp, 0, UInt32(frames), &list)
        }
        #expect(status == noErr)
        return (output, flags.contains(.unitRenderAction_OutputIsSilence))
    }

    private func makeDevice(_ delegate: FakeDelegate) -> PlayoutAudioDevice {
        let device = PlayoutAudioDevice()
        _ = device.initialize(with: delegate)
        return device
    }

    private let expected = (0..<480).map { Int16($0 + 1) }

    @Test("Copie arrêtée : le haut-parleur reçoit le son et rien n'est copié")
    func idle() {
        let delegate = FakeDelegate()
        let device = makeDevice(delegate)
        let played = render(device)
        #expect(played.samples == expected)
        #expect(device.recordingRing.pop() == nil)
        _ = device.terminateDevice()
    }

    @Test("Copie en cours : le haut-parleur reçoit le même son, la copie le garde, avec une heure")
    func capturing() throws {
        let delegate = FakeDelegate()
        let device = makeDevice(delegate)
        device.beginCapture()
        let before = HostClock.nowNanoseconds()
        let played = render(device)
        let after = HostClock.nowNanoseconds()
        #expect(played.samples == expected)
        let block = try #require(device.recordingRing.pop())
        #expect(block.samples == expected)
        #expect(block.time >= before && block.time <= after)
        device.endCapture()
        _ = render(device)
        #expect(device.recordingRing.pop() == nil)
        _ = device.terminateDevice()
    }

    @Test("Haut-parleur muet pendant la copie : sortie à zéro, mais le vrai son est copié")
    func mutedWhileCapturing() throws {
        let delegate = FakeDelegate()
        let device = makeDevice(delegate)
        device.setSpeakerMuted(true)
        device.beginCapture()
        let played = render(device)
        #expect(played.samples == [Int16](repeating: 0, count: 480))
        #expect(played.silent)
        #expect(device.recordingRing.pop()?.samples == expected)
        // Le son revient d'un coup quand on le rétablit, sans toucher à la copie.
        device.setSpeakerMuted(false)
        #expect(render(device).samples == expected)
        #expect(device.recordingRing.pop()?.samples == expected)
        _ = device.terminateDevice()
    }

    @Test("Haut-parleur muet sans copie : sortie à zéro")
    func mutedWithoutCapture() {
        let delegate = FakeDelegate()
        let device = makeDevice(delegate)
        device.setSpeakerMuted(true)
        #expect(render(device).samples == [Int16](repeating: 0, count: 480))
        #expect(device.recordingRing.pop() == nil)
        _ = device.terminateDevice()
    }

    @Test("Sortie signalée silencieuse par WebRTC : la copie reçoit des zéros, pas le contenu du tampon")
    func silentOutputIsCopiedAsSilence() throws {
        let delegate = FakeDelegate()
        delegate.fill = { _, _ in .unitRenderAction_OutputIsSilence }
        let device = makeDevice(delegate)
        device.beginCapture()
        _ = render(device)
        #expect(device.recordingRing.pop()?.samples == [Int16](repeating: 0, count: 480))
        _ = device.terminateDevice()
    }

    @Test("Début de copie : le contenu resté dans le tampon d'une copie précédente est écarté")
    func beginClearsPreviousCapture() {
        let delegate = FakeDelegate()
        let device = makeDevice(delegate)
        device.beginCapture()
        _ = render(device)
        device.endCapture()
        device.beginCapture()
        #expect(device.recordingRing.pop() == nil)
        #expect(device.recordingRing.droppedSamples == 0)
        _ = device.terminateDevice()
    }
}
