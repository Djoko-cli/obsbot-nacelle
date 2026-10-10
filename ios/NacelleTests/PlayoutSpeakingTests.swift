import AVFoundation
import AudioToolbox
import Foundation
import Synchronization
import Testing
@preconcurrency import WebRTC
@testable import Nacelle

/// Session audio simulée : note les bascules, n'ouvre rien.
final class FakeSession: PlayoutSession, @unchecked Sendable {
    private let lock = Mutex<[String]>([])
    var failSpeaking = false
    var failPrepare = false

    var calls: [String] {
        lock.withLock { $0 }
    }

    func prepare() -> Bool {
        lock.withLock { $0.append("prepare") }
        return !failPrepare
    }

    func setSpeakingMode(_ speaking: Bool) -> Bool {
        lock.withLock { $0.append(speaking ? "mode:speaking" : "mode:default") }
        return !(speaking && failSpeaking)
    }

    func setActive(_ active: Bool) throws {
        lock.withLock { $0.append("active:\(active)") }
    }
}

/// Unité audio simulée : aucun matériel.
final class FakeUnit: AudioIOUnit, @unchecked Sendable {
    let kind: String
    private let lock = Mutex<[String]>([])
    var startResult = true

    init(kind: String) {
        self.kind = kind
    }

    var events: [String] {
        lock.withLock { $0 }
    }

    func start() -> Bool {
        lock.withLock { $0.append("start") }
        return startResult
    }

    func stop() {
        lock.withLock { $0.append("stop") }
    }

    func dispose() {
        lock.withLock { $0.append("dispose") }
    }
}

/// Fabrique d'unités simulées : jamais de RemoteIO ni de Voice Processing I/O réels.
final class FakeUnits: AudioIOUnitFactory, @unchecked Sendable {
    private let lock = Mutex<[FakeUnit]>([])
    var failVoiceChat = false
    var failPlayout = false
    var voiceUnitStartResult = true

    var units: [FakeUnit] {
        lock.withLock { $0 }
    }

    var kinds: [String] {
        units.map(\.kind)
    }

    func makePlayout(refCon: UnsafeMutableRawPointer) -> (any AudioIOUnit)? {
        guard !failPlayout else { return nil }
        let unit = FakeUnit(kind: "playout")
        lock.withLock { $0.append(unit) }
        return unit
    }

    func makeVoiceChat(refCon: UnsafeMutableRawPointer, tap: MicTap) -> (any AudioIOUnit)? {
        guard !failVoiceChat else { return nil }
        let unit = FakeUnit(kind: "voiceChat")
        unit.startResult = voiceUnitStartResult
        lock.withLock { $0.append(unit) }
        return unit
    }
}

/// Délégué WebRTC minimal : exécute tout de suite ce qu'on lui confie.
final class QuietDelegate: NSObject, RTCAudioDeviceDelegate, @unchecked Sendable {
    let interruptedOutputs = Mutex(0)
    let changedOutputParameters = Mutex(0)
    var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock { { _, _, _, _, _, _, _ in noErr } }
    var preferredInputSampleRate: Double { 48_000 }
    var preferredInputIOBufferDuration: TimeInterval { 0.01 }
    var preferredOutputSampleRate: Double { 48_000 }
    var preferredOutputIOBufferDuration: TimeInterval { 0.01 }
    var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock { { _, _, _, _, _ in noErr } }
    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() { changedOutputParameters.withLock { $0 += 1 } }
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() { interruptedOutputs.withLock { $0 += 1 } }
    func dispatchAsync(_ block: @escaping () -> Void) { block() }
    func dispatchSync(_ block: @escaping () -> Void) { block() }
}

/// Drapeau d'arrêt partagé avec un fil d'essai.
final class StopFlag: Sendable {
    private let flag = Atomic<Bool>(false)

    var isSet: Bool {
        flag.load(ordering: .acquiring)
    }

    func set() {
        flag.store(true, ordering: .releasing)
    }
}

@Suite("Périphérique audio : bascule en mode parole", .timeLimit(.minutes(1)))
struct PlayoutSpeakingTests {
    let session = FakeSession()
    let units = FakeUnits()
    let delegate = QuietDelegate()
    let device: PlayoutAudioDevice
    let tap = MicTap(ring: AudioRingBuffer(capacity: 48_000))

    init() {
        device = PlayoutAudioDevice(session: session, units: units)
        _ = device.initialize(with: delegate)
    }

    private func startPlayout() {
        #expect(device.initializePlayout())
        #expect(device.startPlayout())
    }

    /// Lance `beginSpeaking` et rend son verdict.
    private func beginSpeaking() async -> Bool {
        await withCheckedContinuation { continuation in
            device.beginSpeaking(tap: tap) { continuation.resume(returning: $0) }
        }
    }

    @Test("Hors parole : lecture seule, l'unité du micro n'est jamais créée")
    func playbackNeverOpensMic() {
        startPlayout()
        #expect(units.kinds == ["playout"])
        #expect(session.calls == ["prepare", "active:true"])
        #expect(!device.isSpeaking)
        _ = device.stopPlayout()
        #expect(units.kinds == ["playout"])
    }

    @Test("Parole demandée sans lecture en cours : refusée, rien ne change")
    func needsPlayout() async {
        #expect(!(await beginSpeaking()))
        #expect(units.kinds.isEmpty)
        #expect(session.calls.isEmpty)
        #expect(!device.isSpeaking)
    }

    @Test("Début de parole : session en mode parole, unité de lecture remplacée par Voice Processing I/O")
    func switchesToSpeaking() async {
        startPlayout()
        #expect(await beginSpeaking())
        #expect(device.isSpeaking)
        #expect(units.kinds == ["playout", "voiceChat"])
        // L'ancienne unité est arrêtée puis détruite, la nouvelle démarrée.
        #expect(units.units[0].events == ["start", "stop", "dispose"])
        #expect(units.units[1].events == ["start"])
        #expect(session.calls == ["prepare", "active:true", "mode:speaking", "active:true"])
        // WebRTC n'est pas prévenu d'un micro : il reste en lecture seule pour lui.
        #expect(!device.isRecording)
        #expect(device.inputNumberOfChannels == 0)
    }

    @Test("Fin de parole : retour à la lecture seule")
    func endSpeaking() async {
        startPlayout()
        #expect(await beginSpeaking())
        device.endSpeaking()
        #expect(!device.isSpeaking)
        #expect(units.kinds == ["playout", "voiceChat", "playout"])
        #expect(units.units[1].events == ["start", "stop", "dispose"])
        #expect(units.units[2].events == ["start"])
        #expect(session.calls.suffix(2) == ["mode:default", "active:true"])
        // La lecture, elle, reste en marche pour WebRTC.
        #expect(device.isPlaying)
    }

    @Test("Fin de parole sans parole en cours : sans effet")
    func endWhenIdle() {
        startPlayout()
        device.endSpeaking()
        #expect(units.kinds == ["playout"])
    }

    @Test("Session refusée en mode parole : la parole échoue, la lecture est rétablie")
    func sessionRefused() async {
        startPlayout()
        session.failSpeaking = true
        #expect(!(await beginSpeaking()))
        #expect(!device.isSpeaking)
        #expect(units.kinds.last == "playout")
        #expect(units.units.last?.events.contains("start") == true)
        #expect(device.isPlaying)
    }

    @Test("Unité Voice Processing impossible à créer : la parole échoue, la lecture est rétablie")
    func voiceUnitUnavailable() async {
        startPlayout()
        units.failVoiceChat = true
        #expect(!(await beginSpeaking()))
        #expect(!device.isSpeaking)
        #expect(units.kinds == ["playout", "playout"])
        #expect(device.isPlaying)
    }

    @Test("Unité Voice Processing qui ne démarre pas : la parole échoue, la lecture est rétablie")
    func voiceUnitWontStart() async {
        startPlayout()
        units.voiceUnitStartResult = false
        #expect(!(await beginSpeaking()))
        #expect(units.kinds == ["playout", "voiceChat", "playout"])
        #expect(units.units[1].events.last == "dispose")
        #expect(device.isPlaying)
    }

    @Test("Interruption (appel, Siri) pendant la parole : la parole est signalée interrompue, la lecture reprend à la fin")
    func interruption() async {
        startPlayout()
        let interrupted = Mutex(0)
        device.onSpeakingInterrupted = { interrupted.withLock { $0 += 1 } }
        #expect(await beginSpeaking())
        device.interruptionBegan()
        #expect(interrupted.withLock { $0 } == 1)
        #expect(!device.isSpeaking)
        // Le système a repris la main : l'unité du micro est détruite, rien n'est démarré avant la fin de l'interruption.
        #expect(units.units[1].events.contains("dispose"))
        let startsBefore = units.units.filter { $0.kind == "playout" }.flatMap(\.events).filter { $0 == "start" }.count
        #expect(startsBefore == 1)
        device.resumeAfterInterruption()
        #expect(units.units.last?.kind == "playout")
        #expect(units.units.last?.events.contains("start") == true)
    }

    @Test("WebRTC arrête la lecture pendant la parole : la parole est signalée interrompue")
    func stopPlayoutWhileSpeaking() async {
        startPlayout()
        let interrupted = Mutex(0)
        device.onSpeakingInterrupted = { interrupted.withLock { $0 += 1 } }
        #expect(await beginSpeaking())
        #expect(device.stopPlayout())
        #expect(interrupted.withLock { $0 } == 1)
        #expect(!device.isSpeaking)
        #expect(!device.isPlaying)
    }

    @Test("Services audio réinitialisés pendant la parole : elle s'arrête, la lecture est refaite")
    func mediaServicesReset() async {
        startPlayout()
        let interrupted = Mutex(0)
        device.onSpeakingInterrupted = { interrupted.withLock { $0 += 1 } }
        #expect(await beginSpeaking())
        device.rebuildAfterReset()
        #expect(interrupted.withLock { $0 } == 1)
        #expect(!device.isSpeaking)
        #expect(units.units.last?.kind == "playout")
        #expect(device.isPlaying)
    }

    @Test("Une deuxième parole après la première refait la bascule")
    func twice() async {
        startPlayout()
        #expect(await beginSpeaking())
        device.endSpeaking()
        #expect(await beginSpeaking())
        #expect(units.kinds == ["playout", "voiceChat", "playout", "voiceChat"])
        device.endSpeaking()
    }

    // MARK: Catégorie préparée à l'avance (spec parler § 6.2)

    @Test("La catégorie est posée une seule fois, au démarrage de la lecture, sans aucune entrée ouverte")
    func categoryPreparedOnce() {
        startPlayout()
        #expect(session.calls == ["prepare", "active:true"])
        #expect(units.kinds == ["playout"])
        // Arrêt puis reprise de la lecture (arrière-plan, premier plan) : la catégorie tient, rien à refaire.
        #expect(device.stopPlayout())
        #expect(device.initializePlayout())
        #expect(device.startPlayout())
        #expect(session.calls.filter { $0 == "prepare" }.count == 1)
    }

    @Test("Appui : seul le mode change, la catégorie n'est pas touchée")
    func pressChangesOnlyTheMode() async {
        startPlayout()
        let before = session.calls.count
        #expect(await beginSpeaking())
        #expect(Array(session.calls.dropFirst(before)) == ["mode:speaking", "active:true"])
    }

    @Test("Relâchement : retour au mode par défaut, la catégorie n'est pas touchée")
    func releaseChangesOnlyTheMode() async {
        startPlayout()
        #expect(await beginSpeaking())
        let before = session.calls.count
        device.endSpeaking()
        #expect(Array(session.calls.dropFirst(before)) == ["mode:default", "active:true"])
        #expect(units.kinds == ["playout", "voiceChat", "playout"])
    }

    @Test("Plusieurs prises de parole : toujours une seule pose de catégorie, jamais de mode parole hors parole")
    func neverSpeakingModeOutsideSpeech() async {
        startPlayout()
        for _ in 0..<3 {
            #expect(await beginSpeaking())
            device.endSpeaking()
        }
        let calls = session.calls
        #expect(calls.filter { $0 == "prepare" }.count == 1)
        // Les modes alternent : parole, défaut, parole, défaut... et finissent par le défaut.
        let modes = calls.filter { $0.hasPrefix("mode:") }
        #expect(modes == ["mode:speaking", "mode:default", "mode:speaking", "mode:default", "mode:speaking", "mode:default"])
    }

    @Test("Mode parole refusé : la lecture revient au mode par défaut")
    func speakingModeRefusedRestoresDefault() async {
        startPlayout()
        session.failSpeaking = true
        #expect(!(await beginSpeaking()))
        #expect(session.calls.suffix(2) == ["mode:default", "active:true"])
        #expect(session.calls.filter { $0 == "prepare" }.count == 1)
    }

    @Test("Catégorie refusée au démarrage : la lecture n'est pas initialisée")
    func prepareRefused() {
        session.failPrepare = true
        #expect(!device.initializePlayout())
        #expect(units.kinds.isEmpty)
    }

    @Test("Services audio réinitialisés : iOS a perdu la catégorie, elle est reposée une fois")
    func categoryRestoredAfterReset() {
        startPlayout()
        device.rebuildAfterReset()
        #expect(session.calls.filter { $0 == "prepare" }.count == 2)
        #expect(device.isPlaying)
    }

    @Test("Réglages de la session préparée : haut-parleur par défaut, mélange avec les autres apps, Bluetooth, jamais de mode voix hors parole")
    func preparedSessionSettings() {
        let options = SystemPlayoutSession.categoryOptions
        #expect(SystemPlayoutSession.category == .playAndRecord)
        #expect(SystemPlayoutSession.defaultMode == .default)
        #expect(options.contains(.defaultToSpeaker))
        #expect(options.contains(.mixWithOthers))
        #expect(options.contains(.allowBluetoothHFP))
        #expect(SystemPlayoutSession.speakingMode == .voiceChat)
    }

    // MARK: Corrections d'avant banc (relecture du prototype)

    @Test("I3 : bascule en parole ratée, puis retour en lecture seule raté aussi : la lecture se relance ensuite")
    func recoversAfterDoubleSwapFailure() async {
        startPlayout()
        units.failVoiceChat = true
        units.failPlayout = true
        #expect(!(await beginSpeaking()))
        #expect(!device.isPlaying)
        // Le matériel revient : WebRTC arrête, puis réinitialise et relance la lecture.
        units.failPlayout = false
        #expect(device.stopPlayout())
        #expect(device.initializePlayout())
        #expect(device.startPlayout())
        #expect(device.isPlaying)
        #expect(units.units.last?.kind == "playout")
        #expect(units.units.last?.events == ["start"])
    }

    @Test("I3 : retour en lecture seule raté à la fin de la parole : la lecture se relance ensuite")
    func recoversAfterFailedReturnToPlayback() async {
        startPlayout()
        #expect(await beginSpeaking())
        units.failPlayout = true
        device.endSpeaking()
        #expect(!device.isSpeaking)
        #expect(!device.isPlaying)
        units.failPlayout = false
        #expect(device.stopPlayout())
        #expect(device.initializePlayout())
        #expect(device.startPlayout())
        #expect(device.isPlaying)
        #expect(units.units.last?.kind == "playout")
    }

    @Test("M1 : après chaque bascule réussie, WebRTC est prévenu que la sortie et ses paramètres ont changé")
    func notifiesWebRTCAfterSwap() async {
        startPlayout()
        let interruptedBefore = delegate.interruptedOutputs.withLock { $0 }
        let parametersBefore = delegate.changedOutputParameters.withLock { $0 }
        #expect(await beginSpeaking())
        #expect(delegate.interruptedOutputs.withLock { $0 } == interruptedBefore + 1)
        #expect(delegate.changedOutputParameters.withLock { $0 } == parametersBefore + 1)
        device.endSpeaking()
        #expect(delegate.interruptedOutputs.withLock { $0 } == interruptedBefore + 2)
        #expect(delegate.changedOutputParameters.withLock { $0 } == parametersBefore + 2)
    }

    @Test("M1 : une bascule ratée ne prévient pas WebRTC")
    func noNotificationOnFailedSwap() async {
        startPlayout()
        units.failVoiceChat = true
        let parametersBefore = delegate.changedOutputParameters.withLock { $0 }
        #expect(!(await beginSpeaking()))
        // Seul le retour en lecture seule (réussi) prévient.
        #expect(delegate.changedOutputParameters.withLock { $0 } == parametersBefore + 1)
    }

    @Test("I1 : le gestionnaire d'interruption est posé et retiré pendant que d'autres fils interrompent la parole")
    func handlerRaceStress() async {
        startPlayout()
        let device = device
        let tap = tap
        let calls = Mutex(0)
        let stop = StopFlag()
        let finished = StopFlag()
        // Le fil principal pose et retire le gestionnaire (comme `DeviceSpeechAudio.begin` et `end`)...
        let writer = Thread {
            while !stop.isSet {
                device.onSpeakingInterrupted = { calls.withLock { $0 += 1 } }
                device.onSpeakingInterrupted = nil
            }
            finished.set()
        }
        writer.start()
        // ... pendant que le fil de WebRTC démarre la parole puis l'interrompt, et la reprend.
        for _ in 0..<300 {
            await withCheckedContinuation { continuation in
                device.beginSpeaking(tap: tap) { _ in continuation.resume() }
            }
            device.interruptionBegan()
            device.resumeAfterInterruption()
        }
        stop.set()
        let deadline = ContinuousClock.now + .seconds(5)
        while !finished.isSet, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(finished.isSet)
    }
}

/// Pointeur de contexte d'un rappel audio, passé au fil de l'essai.
private struct RefCon: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer

    init(_ object: AnyObject) {
        pointer = Unmanaged.passUnretained(object).toOpaque()
    }
}

/// Le piège du 09/10 (voir la fiche) : un rappel audio écrit dans un type `@MainActor` plante au premier appel
/// depuis le fil audio. Ces essais appellent les rappels depuis d'autres fils que le fil principal.
@Suite("Rappels audio temps réel appelés hors du fil principal", .timeLimit(.minutes(1)))
struct RealtimeCallbackTests {
    /// Exécute `body` sur un vrai fil Foundation (pas le fil principal), rend `nil` si le fil était le principal,
    /// ou si `body` n'a pas fini en 5 s ; sinon ce que `body` a rendu.
    private func onOtherThread<Result: Sendable>(_ body: @escaping @Sendable () -> Result) -> Result? {
        let done = DispatchSemaphore(value: 0)
        let box = Mutex<Result?>(nil)
        let thread = Thread {
            if !Thread.isMainThread {
                box.withLock { $0 = body() }
            }
            done.signal()
        }
        thread.start()
        guard done.wait(timeout: .now() + 5) == .success else { return nil }
        return box.withLock { $0 }
    }

    @Test("Rappel d'entrée du micro : les échantillons arrivent dans le tampon, appelé depuis un autre fil")
    func micCallbackFromOtherThread() {
        let ring = AudioRingBuffer(capacity: 48_000)
        let tap = MicTap(ring: ring)
        tap.pull = { _, _, _, frames, data in
            let buffer = UnsafeMutableAudioBufferListPointer(data)[0]
            let samples = buffer.mData!.assumingMemoryBound(to: Int16.self)
            for index in 0..<Int(frames) { samples[index] = Int16(index + 1) }
            return noErr
        }
        let refCon = RefCon(tap)
        let statuses = onOtherThread { () -> [OSStatus] in
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            return (0..<3).map { _ in micInputProc(refCon.pointer, &flags, &timestamp, 1, 480, nil) }
        }
        #expect(statuses == [noErr, noErr, noErr])
        var total = 0
        while let block = ring.pop() {
            #expect(block.samples.count == 480)
            #expect(block.samples.first == 1 && block.samples.last == 480)
            total += block.samples.count
        }
        #expect(total == 1440)
        withExtendedLifetime(tap) {}
    }

    @Test("Rappel d'entrée : un échec du système est rendu tel quel et rien n'est écrit")
    func micCallbackFailure() {
        let ring = AudioRingBuffer(capacity: 48_000)
        let tap = MicTap(ring: ring)
        tap.pull = { _, _, _, _, _ in -1 }
        let refCon = RefCon(tap)
        let status = onOtherThread { () -> OSStatus in
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            return micInputProc(refCon.pointer, &flags, &timestamp, 1, 480, nil)
        }
        #expect(status == -1)
        #expect(ring.pop() == nil)
        withExtendedLifetime(tap) {}
    }

    @Test("Rappel d'entrée : un bloc plus grand que la réserve est refusé sans écrire hors tampon")
    func micCallbackOversize() {
        let ring = AudioRingBuffer(capacity: 48_000)
        let tap = MicTap(ring: ring)
        tap.pull = { _, _, _, _, _ in noErr }
        let refCon = RefCon(tap)
        let status = onOtherThread { () -> OSStatus in
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            return micInputProc(refCon.pointer, &flags, &timestamp, 1, UInt32(MicTap.maxFrames + 1), nil)
        }
        #expect(status != nil && status != noErr)
        #expect(ring.pop() == nil)
        withExtendedLifetime(tap) {}
    }

    @Test("Rappel d'entrée avant que l'unité n'ait posé son micro : erreur, pas de plantage")
    func micCallbackWithoutPull() {
        let tap = MicTap(ring: AudioRingBuffer(capacity: 48_000))
        let refCon = RefCon(tap)
        let status = onOtherThread { () -> OSStatus in
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            return micInputProc(refCon.pointer, &flags, &timestamp, 1, 480, nil)
        }
        #expect(status != nil && status != noErr)
        withExtendedLifetime(tap) {}
    }

    @Test("Rappel de rendu de la lecture : appelé depuis un autre fil, il remplit la sortie")
    func playoutCallbackFromOtherThread() {
        let delegate = FillingDelegate()
        let device = PlayoutAudioDevice(session: FakeSession(), units: FakeUnits())
        _ = device.initialize(with: delegate)
        let refCon = RefCon(device)
        let output = onOtherThread { () -> [Int16] in
            var samples = [Int16](repeating: 0, count: 480)
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            let status = samples.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
                )
                return playoutRender(refCon: refCon.pointer, flags: &flags, timestamp: &timestamp, bus: 0, frames: 480, data: &list)
            }
            return status == noErr ? samples : []
        }
        #expect(output == (0..<480).map { Int16($0 + 1) })
        _ = device.terminateDevice()
    }
}

/// Délégué qui livre une rampe de synthèse.
final class FillingDelegate: NSObject, RTCAudioDeviceDelegate, @unchecked Sendable {
    var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock { { _, _, _, _, _, _, _ in noErr } }
    var preferredInputSampleRate: Double { 48_000 }
    var preferredInputIOBufferDuration: TimeInterval { 0.01 }
    var preferredOutputSampleRate: Double { 48_000 }
    var preferredOutputIOBufferDuration: TimeInterval { 0.01 }
    var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock {
        { _, _, _, frames, data in
            let buffer = UnsafeMutableAudioBufferListPointer(data)[0]
            let samples = buffer.mData!.assumingMemoryBound(to: Int16.self)
            for index in 0..<Int(frames) { samples[index] = Int16(index + 1) }
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
