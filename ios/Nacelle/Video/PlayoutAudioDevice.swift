import AVFoundation
import AudioToolbox
import Synchronization
@preconcurrency import WebRTC

/// Périphérique audio de WebRTC en sortie seule (audio dans PTZBot) : il joue le son reçu et ne touche
/// jamais au micro de l'iPhone, contrairement au module par défaut (unité de traitement de la voix, entrée
/// toujours active). Session `.playback` mélangée aux autres apps : le son joue même en mode silencieux,
/// sans couper la musique. Un appel, Siri ou une alarme interrompent la lecture : elle reprend ensuite.
///
/// `@unchecked Sendable` : WebRTC appelle les méthodes sur un seul fil, celui du module audio ; les
/// notifications du système y sont renvoyées par `dispatchAsync` (seule la lecture de `delegate` pour
/// ce renvoi se fait sur leur fil ; la fabrique est statique, `terminateDevice` n'arrive pas en pratique). `getPlayoutData` ne change que quand
/// l'unité est arrêtée, et le fil audio ne fait que le lire.
///
/// Enregistrement (spec enregistrement § 4.2) : le fil audio copie le PCM qu'il vient de recevoir de WebRTC
/// dans `recordingRing`, puis, si le haut-parleur est muet, remplace la sortie par du silence. Sur ce fil :
/// ni allocation, ni verrou, ni attente. Le tampon est réservé à la création, les deux commandes
/// (`capturing`, `speakerMuted`) sont des atomiques, et la lecture de l'horloge n'appelle pas le noyau.
final class PlayoutAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let channels = 1

    private var unit: AudioUnit?
    private var delegate: (any RTCAudioDeviceDelegate)?
    /// Fourni par WebRTC à l'initialisation ; lu sur le fil audio pendant la lecture.
    private var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock?
    private var observers: [any NSObjectProtocol] = []

    /// Le son joué, copié pour le `ClipRecorder` : 2 s au plus de retard toléré.
    let recordingRing = AudioRingBuffer(capacity: Int(sampleRate) * channels * 2)
    /// La copie dans `recordingRing` est en marche.
    private let capturing = Atomic<Bool>(false)
    /// La sortie envoie du silence au haut-parleur ; la copie, elle, garde le vrai son.
    private let speakerMuted = Atomic<Bool>(false)

    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false

    // Lecture seule : aucune entrée.
    let deviceInputSampleRate = PlayoutAudioDevice.sampleRate
    let inputIOBufferDuration: TimeInterval = 0.01
    let inputNumberOfChannels = 0
    let inputLatency: TimeInterval = 0
    let isRecordingInitialized = false
    let isRecording = false

    var deviceOutputSampleRate: Double {
        Self.sampleRate
    }

    var outputIOBufferDuration: TimeInterval {
        AVAudioSession.sharedInstance().ioBufferDuration
    }

    var outputNumberOfChannels: Int {
        Self.channels
    }

    var outputLatency: TimeInterval {
        AVAudioSession.sharedInstance().outputLatency
    }

    var isCapturing: Bool {
        capturing.load(ordering: .acquiring)
    }

    var isSpeakerMuted: Bool {
        speakerMuted.load(ordering: .acquiring)
    }

    /// Début d'une copie : le tampon est vidé d'abord (le consommateur est à l'arrêt, le producteur n'écrit pas encore).
    func beginCapture() {
        recordingRing.reset()
        capturing.store(true, ordering: .releasing)
    }

    /// Fin de la copie. Ce qui reste dans le tampon peut encore être repris.
    func endCapture() {
        capturing.store(false, ordering: .releasing)
    }

    /// Muet : le haut-parleur reçoit du silence, mais WebRTC continue de livrer le son (copie comprise).
    func setSpeakerMuted(_ muted: Bool) {
        speakerMuted.store(muted, ordering: .releasing)
    }

    func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate
        getPlayoutData = delegate.getPlayoutData
        observeAudioSession()
        isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        _ = stopPlayout()
        disposeUnit()
        getPlayoutData = nil
        delegate = nil
        isInitialized = false
        return true
    }

    /// Interruption (appel, Siri, alarme) : RemoteIO s'arrête ; à la fin, la lecture reprend.
    /// Services audio réinitialisés : l'unité est recréée.
    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
                self?.delegate?.dispatchAsync { [weak self] in
                    began ? self?.interruptionBegan() : self?.resumeAfterInterruption()
                }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
                self?.delegate?.dispatchAsync { [weak self] in
                    self?.rebuildAfterReset()
                }
            },
        ]
    }

    private func interruptionBegan() {
        // Le rendu reprendra sur un autre fil d'entrées-sorties (contrat de RTCAudioDevice).
        delegate?.notifyAudioOutputInterrupted()
    }

    private func resumeAfterInterruption() {
        guard isPlaying, let unit else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        AudioOutputUnitStart(unit)
    }

    private func rebuildAfterReset() {
        let wasPlayoutInitialized = isPlayoutInitialized
        let wasPlaying = isPlaying
        isPlaying = false
        disposeUnit()
        // iOS a remis la session aux réglages par défaut : catégorie et unité sont refaites.
        guard isInitialized, wasPlayoutInitialized, configureSession(), let unit = makeUnit() else { return }
        self.unit = unit
        isPlayoutInitialized = true
        if wasPlaying {
            delegate?.notifyAudioOutputInterrupted()
            _ = startPlayout()
        }
    }

    /// Lecture seule, mélangée aux autres apps, et jouée même en mode silencieux.
    private func configureSession() -> Bool {
        (try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])) != nil
    }

    func initializePlayout() -> Bool {
        guard !isPlayoutInitialized else { return true }
        guard configureSession(), let unit = makeUnit() else { return false }
        self.unit = unit
        isPlayoutInitialized = true
        return true
    }

    func startPlayout() -> Bool {
        guard let unit, isPlayoutInitialized else { return false }
        guard !isPlaying else { return true }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            return false
        }
        guard AudioOutputUnitStart(unit) == noErr else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return false
        }
        isPlaying = true
        return true
    }

    func stopPlayout() -> Bool {
        guard isPlaying, let unit else { return true }
        AudioOutputUnitStop(unit)
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return true
    }

    func initializeRecording() -> Bool {
        false
    }

    func startRecording() -> Bool {
        false
    }

    func stopRecording() -> Bool {
        true
    }

    /// RemoteIO en sortie seule (entrée désactivée explicitement), PCM 16 bits entrelacé à 48 kHz.
    private func makeUnit() -> AudioUnit? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else { return nil }
        let bytesPerFrame = UInt32(2 * Self.channels)
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var inputOff: UInt32 = 0
        var callback = AURenderCallbackStruct(
            inputProc: playoutRender,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let ok = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &inputOff, UInt32(MemoryLayout<UInt32>.size)
        ) == noErr
            && AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ) == noErr
            && AudioUnitSetProperty(
                unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ) == noErr
            && AudioUnitInitialize(unit) == noErr
        guard ok else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        return unit
    }

    private func disposeUnit() {
        guard let unit else { return }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        isPlayoutInitialized = false
    }

    /// Fil audio : demande à WebRTC les échantillons à jouer ; silence s'il n'y en a pas. Puis copie pour
    /// l'enregistrement, et silence au haut-parleur s'il est muet.
    func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32,
        _ data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        guard let getPlayoutData else {
            flags.pointee.insert(.unitRenderAction_OutputIsSilence)
            silence(data)
            return noErr
        }
        let status = getPlayoutData(flags, timestamp, Int(bus), frames, data)
        guard status == noErr else { return status }
        if capturing.load(ordering: .acquiring) {
            capture(data, silent: flags.pointee.contains(.unitRenderAction_OutputIsSilence))
        }
        if speakerMuted.load(ordering: .acquiring) {
            flags.pointee.insert(.unitRenderAction_OutputIsSilence)
            silence(data)
        }
        return noErr
    }

    /// Copie le premier tampon (mono entrelacé) dans le tampon circulaire. Une sortie signalée silencieuse
    /// peut contenir n'importe quoi : elle est copiée comme des zéros.
    private func capture(_ data: UnsafeMutablePointer<AudioBufferList>, silent: Bool) {
        guard let buffer = UnsafeMutableAudioBufferListPointer(data).first, let bytes = buffer.mData else { return }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
        let time = HostClock.nowNanoseconds()
        if silent {
            recordingRing.writeSilence(count: count, time: time)
        } else {
            recordingRing.write(bytes.assumingMemoryBound(to: Int16.self), count: count, time: time)
        }
    }

    private func silence(_ data: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(data) {
            if let bytes = buffer.mData {
                memset(bytes, 0, Int(buffer.mDataByteSize))
            }
        }
    }
}

private func playoutRender(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    bus: UInt32,
    frames: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let data else { return noErr }
    let device = Unmanaged<PlayoutAudioDevice>.fromOpaque(refCon).takeUnretainedValue()
    return device.render(flags, timestamp, bus, frames, data)
}
