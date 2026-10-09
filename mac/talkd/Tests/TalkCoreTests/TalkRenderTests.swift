import CoreAudioTypes
import Foundation
import Synchronization
import Testing
@testable import TalkCore

/// Un `AudioBufferList` de deux canaux non entrelacés (Float32), fait à la main : ce que l'AUHAL donne au rappel.
/// Aucune unité audio, aucun périphérique.
final class StereoBlock: @unchecked Sendable {
    let frames: Int
    let list: UnsafeMutablePointer<AudioBufferList>
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>

    init(frames: Int, fill: Float = 7) {
        self.frames = frames
        left = .allocate(capacity: frames)
        right = .allocate(capacity: frames)
        left.initialize(repeating: fill, count: frames)
        right.initialize(repeating: fill, count: frames)
        // Une liste de deux tampons : l'en-tête puis deux AudioBuffer à la suite.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.pointee.mNumberBuffers = 2
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        let buffers = TalkRender.buffersPointer(list)
        buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(left))
        buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(right))
    }

    deinit {
        left.deallocate()
        right.deallocate()
        UnsafeMutableRawPointer(list).deallocate()
    }

    /// Le canal `index` de la liste, pour le modifier.
    func setChannel(_ index: Int, data: UnsafeMutableRawPointer?) {
        TalkRender.buffersPointer(list)[index].mData = data
    }

    var leftSamples: [Float] {
        Array(UnsafeBufferPointer(start: left, count: frames))
    }

    var rightSamples: [Float] {
        Array(UnsafeBufferPointer(start: right, count: frames))
    }

    /// Appelle le rappel comme le fil d'E/S de l'AUHAL : refCon, drapeaux, horodatage, bus 0, nombre d'images.
    func render(_ callback: TalkRender.Callback, refCon: UnsafeMutableRawPointer) -> OSStatus {
        var flags: UInt32 = 0
        var time = AudioTimeStamp()
        return callback(refCon, &flags, &time, 0, UInt32(frames), list)
    }
}

/// Un tampon pré-chargé : `samples` échantillons de valeur `amplitude` (au-delà des 60 ms de pré-charge).
func primedBuffer(amplitude: Int16 = 16384, samples: Int = 1600) -> JitterBuffer {
    let buffer = JitterBuffer()
    buffer.push(pcm(amplitude, samples: samples))
    return buffer
}

@Suite("Rendu temps réel (fonction C de l'AUHAL)", .timeLimit(.minutes(1)))
struct TalkRenderTests {
    @Test("Format de la sortie : Float32, 16 kHz, deux canaux non entrelacés")
    func format() {
        #expect(TalkRender.format == PCMFormat(sampleRate: 16_000, channels: 2, interleaved: false))
    }

    @Test("fill : le canal gauche est lu dans le tampon, puis recopié tel quel dans le droit")
    func fillCopiesLeftToRight() {
        let buffer = primedBuffer()
        let block = StereoBlock(frames: 256)
        TalkRender.fill(block.list, frames: block.frames, from: buffer)
        #expect(block.leftSamples == [Float](repeating: 0.5, count: 256))
        #expect(block.rightSamples == block.leftSamples)
        #expect(buffer.bufferedSamples == 1600 - 256)
    }

    @Test("fill : tampon pas encore pré-chargé, les deux canaux reçoivent du silence")
    func fillSilenceBeforePriming() {
        let buffer = JitterBuffer()
        buffer.push(pcm(16384, samples: 100))
        let block = StereoBlock(frames: 128)
        TalkRender.fill(block.list, frames: block.frames, from: buffer)
        #expect(block.leftSamples.allSatisfy { $0 == 0 })
        #expect(block.rightSamples.allSatisfy { $0 == 0 })
    }

    @Test("fill : jamais plus d'images que la place de chaque canal (mDataByteSize)")
    func fillBoundedByCapacity() {
        let buffer = primedBuffer()
        let block = StereoBlock(frames: 64)
        // L'AUHAL annoncerait plus d'images que la place réelle : seules 64 sont écrites et lues.
        TalkRender.fill(block.list, frames: 4096, from: buffer)
        #expect(block.leftSamples == [Float](repeating: 0.5, count: 64))
        #expect(block.rightSamples == block.leftSamples)
        #expect(buffer.bufferedSamples == 1600 - 64)
    }

    @Test("fill : un canal sans mémoire (mData nul) est ignoré, sans plantage")
    func fillNullChannel() {
        let buffer = primedBuffer()
        let block = StereoBlock(frames: 32)
        block.setChannel(1, data: nil)
        TalkRender.fill(block.list, frames: 32, from: buffer)
        #expect(block.leftSamples == [Float](repeating: 0.5, count: 32))
    }

    @Test("Le rappel C, appelé depuis un autre fil que le principal, remplit les deux canaux et rend noErr")
    func callbackFromAnotherThread() async {
        let buffer = primedBuffer()
        let block = StereoBlock(frames: 512)
        let refCon = Unmanaged.passUnretained(buffer).toOpaque()
        let result = Mutex<(status: OSStatus, mainThread: Bool)?>(nil)
        let callback = TalkRender.callback
        // Le pointeur est passé en nombre : un Thread ne peut emporter qu'un état Sendable.
        let address = UInt(bitPattern: refCon)
        let thread = Thread {
            let status = block.render(callback, refCon: UnsafeMutableRawPointer(bitPattern: address)!)
            result.withLock { $0 = (status, Thread.isMainThread) }
        }
        thread.start()
        let done = await waitUntil(timeout: 3) { result.withLock { $0 != nil } }
        #expect(done)
        let outcome = result.withLock { $0 }
        #expect(outcome?.status == 0)
        #expect(outcome?.mainThread == false)
        #expect(block.leftSamples == [Float](repeating: 0.5, count: 512))
        #expect(block.rightSamples == block.leftSamples)
        withExtendedLifetime(buffer) {}
    }

    @Test("Le rappel sans liste de tampons (ioData nul) rend noErr sans rien toucher")
    func callbackWithoutList() {
        let buffer = primedBuffer()
        var flags: UInt32 = 0
        var time = AudioTimeStamp()
        let status = TalkRender.callback(Unmanaged.passUnretained(buffer).toOpaque(), &flags, &time, 0, 128, nil)
        #expect(status == 0)
        #expect(buffer.bufferedSamples == 1600)
    }

    // MARK: - Sonde : le rappel n'hérite pas de l'isolation du MainActor (défaut C1 de la relecture)
    //
    // Le défaut C1 : un bloc non Sendable formé dans une méthode @MainActor hérite de son isolation ; Swift 6 y insère
    // un contrôle d'exécuteur, et l'appel depuis le fil audio s'arrête en SIGTRAP. La sonde le montre dans un processus
    // à part (test de sortie) : le mauvais motif s'arrête bien en SIGTRAP, alors que le rappel de talkd, obtenu dans
    // une méthode @MainActor comme le fait `HALOutput`, puis appelé sur d'autres fils, finit normalement.

    @Test("Sonde, témoin : un bloc formé dans une méthode @MainActor et appelé sur d'autres fils s'arrête en SIGTRAP")
    func probeMainActorBlockTraps() async {
        await #expect(processExitsWith: .signal(SIGTRAP)) {
            await IsolationProbe.mainActorBlockOnWorkerThreads()
        }
    }

    @Test("Sonde : le rappel de talkd, obtenu dans une méthode @MainActor, s'exécute sur d'autres fils sans contrôle du MainActor")
    func probeRenderCallbackHasNoMainActorCheck() async {
        await #expect(processExitsWith: .success) {
            await IsolationProbe.renderCallbackOnWorkerThreads()
        }
    }
}

/// Les deux motifs de la sonde. Chacun tourne dans un processus enfant, jamais dans celui des tests.
enum IsolationProbe {
    /// Le mauvais motif (C1) : le bloc hérite du MainActor, et ses appels sur les fils de travail s'arrêtent.
    @MainActor
    static func mainActorBlockOnWorkerThreads() {
        let items = NSArray(array: Array(0..<64))
        items.enumerateObjects(options: .concurrent) { _, _, _ in
            usleep(1000)
        }
    }

    /// Le motif de talkd : le pointeur de fonction est pris dans le MainActor (comme `HALOutput.start`), puis appelé
    /// ailleurs, comme le fait le fil d'E/S de l'AUHAL.
    @MainActor
    static func renderCallbackOnWorkerThreads() {
        let callback = TalkRender.callback
        let buffer = primedBuffer(samples: 4000)
        callConcurrently(callback, refCon: Unmanaged.passUnretained(buffer).toOpaque())
        withExtendedLifetime(buffer) {}
    }

    /// Le relais hors de tout acteur : il fait ce que fait coreaudiod, appeler un pointeur C sur ses propres fils.
    nonisolated static func callConcurrently(_ callback: TalkRender.Callback, refCon: UnsafeMutableRawPointer) {
        let address = UInt(bitPattern: refCon)
        let items = NSArray(array: Array(0..<64))
        items.enumerateObjects(options: .concurrent) { _, _, _ in
            let block = StereoBlock(frames: 16)
            _ = block.render(callback, refCon: UnsafeMutableRawPointer(bitPattern: address)!)
            usleep(1000)
        }
    }
}
