import AVFoundation
import AudioToolbox
import Synchronization
@preconcurrency import WebRTC

/// Périphérique audio de WebRTC en sortie seule (audio dans PTZBot) : il joue le son reçu et ne touche
/// jamais au micro de l'iPhone, contrairement au module par défaut (unité de traitement de la voix, entrée
/// toujours active). Session mélangée aux autres apps : le son joue même en mode silencieux,
/// sans couper la musique. Un appel, Siri ou une alarme interrompent la lecture : elle reprend ensuite.
///
/// `@unchecked Sendable` : WebRTC appelle les méthodes sur un seul fil, celui du module audio ; les
/// notifications du système y sont renvoyées par `dispatchAsync` (seule la lecture de `delegate` pour
/// ce renvoi se fait sur leur fil ; la fabrique est statique, `terminateDevice` n'arrive pas en pratique). `getPlayoutData` ne change que quand
/// l'unité est arrêtée, et le fil audio ne fait que le lire.
///
/// Session (spec parler § 6.2) : la catégorie `.playAndRecord` est posée une seule fois, au premier démarrage de la
/// lecture, avec l'unité RemoteIO en sortie seule (aucune entrée : pas de micro ouvert, pas de voyant orange). Elle
/// ne change plus ensuite, sauf si iOS réinitialise ses services audio.
///
/// Parole (spec parler § 6.2) : sur demande (`beginSpeaking`), la session passe seulement en mode `.voiceChat` et
/// l'unité RemoteIO est remplacée par Voice Processing I/O, en entrée et en sortie, pour que l'annulation d'écho
/// connaisse le son joué. La lecture continue par cette unité ; le micro va dans le `MicTap`. WebRTC, lui, ne sait rien
/// du micro : `isRecording` reste faux. `endSpeaking` revient à la lecture seule. Les bascules s'exécutent sur le fil
/// de WebRTC (`dispatchAsync`), comme les interruptions.
///
/// Enregistrement (spec enregistrement § 4.2) : le fil audio copie le PCM qu'il vient de recevoir de WebRTC
/// dans `recordingRing`, puis, si le haut-parleur est muet, remplace la sortie par du silence. Sur ce fil :
/// ni allocation, ni verrou, ni attente. Le tampon est réservé à la création, les deux commandes
/// (`capturing`, `speakerMuted`) sont des atomiques, et la lecture de l'horloge n'appelle pas le noyau.
final class PlayoutAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let channels = 1

    private let session: any PlayoutSession
    private let units: any AudioIOUnitFactory
    private var unit: (any AudioIOUnit)?
    /// Écrit sur le fil de WebRTC, mais lu aussi par les observateurs de notifications (fils quelconques) et par
    /// `perform` (fil principal) : sous verrou. On ne l'appelle jamais verrou tenu.
    private let delegateBox = Mutex(DelegateRef(nil))
    private var delegate: (any RTCAudioDeviceDelegate)? {
        get { delegateBox.withLock { $0.value } }
        set { delegateBox.withLock { $0 = DelegateRef(newValue) } }
    }

    /// Le délégué de WebRTC, qui n'est pas `Sendable` : il est conçu pour être appelé de n'importe quel fil.
    private struct DelegateRef: @unchecked Sendable {
        let value: (any RTCAudioDeviceDelegate)?

        init(_ value: (any RTCAudioDeviceDelegate)?) {
            self.value = value
        }
    }
    /// Le micro de la parole en cours ; nil hors parole.
    private var speakingTap: MicTap?
    /// Une interruption du système (appel, Siri) est en cours : rien ne démarre avant sa fin.
    private var interrupted = false
    /// La catégorie de la session est posée (une fois par vie de la session audio d'iOS). Fil de WebRTC.
    private var sessionPrepared = false
    /// La parole a été coupée par le système ou par WebRTC (interruption, arrêt de la lecture, réinitialisation).
    /// Appelé sur le fil de WebRTC. Posé et retiré par le fil principal, lu par celui de WebRTC : sous verrou, et copié
    /// avant l'appel, pour qu'un retrait concurrent ne libère pas la closure en cours d'exécution.
    var onSpeakingInterrupted: (@Sendable () -> Void)? {
        get { speakingInterruptedBox.withLock { $0 } }
        set { speakingInterruptedBox.withLock { $0 = newValue } }
    }
    private let speakingInterruptedBox = Mutex<(@Sendable () -> Void)?>(nil)
    /// Fourni par WebRTC à l'initialisation ; lu sur le fil audio pendant la lecture.
    private var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock?
    private var observers: [any NSObjectProtocol] = []

    /// Le son joué, copié pour le `ClipRecorder` : 2 s au plus de retard toléré.
    let recordingRing = AudioRingBuffer(capacity: Int(sampleRate) * channels * 2)
    /// La copie dans `recordingRing` est en marche.
    private let capturing = Atomic<Bool>(false)
    /// La sortie envoie du silence au haut-parleur ; la copie, elle, garde le vrai son.
    private let speakerMuted = Atomic<Bool>(false)

    init(session: any PlayoutSession = SystemPlayoutSession(), units: any AudioIOUnitFactory = SystemAudioUnitFactory()) {
        self.session = session
        self.units = units
        super.init()
    }

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

    /// La parole est en cours : l'unité en place est Voice Processing I/O.
    var isSpeaking: Bool {
        speakingTap != nil
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

    func interruptionBegan() {
        interrupted = true
        // La parole ne survit pas à une interruption ; l'unité de lecture est refaite, sans démarrer.
        endSpeakingBecauseOfSystem()
        // Le rendu reprendra sur un autre fil d'entrées-sorties (contrat de RTCAudioDevice).
        delegate?.notifyAudioOutputInterrupted()
    }

    func resumeAfterInterruption() {
        interrupted = false
        guard isPlaying, let unit else { return }
        try? session.setActive(true)
        _ = unit.start()
    }

    func rebuildAfterReset() {
        let wasPlayoutInitialized = isPlayoutInitialized
        let wasPlaying = isPlaying
        let wasSpeaking = speakingTap != nil
        speakingTap = nil
        isPlaying = false
        disposeUnit()
        if wasSpeaking {
            onSpeakingInterrupted?()
        }
        // iOS a remis la session aux réglages par défaut : catégorie et unité sont refaites.
        sessionPrepared = false
        guard isInitialized, wasPlayoutInitialized, prepareSession(), let unit = makeUnit() else { return }
        self.unit = unit
        isPlayoutInitialized = true
        if wasPlaying {
            delegate?.notifyAudioOutputInterrupted()
            _ = startPlayout()
        }
    }

    /// Fin de parole imposée (interruption) : retour à la lecture, signalé à l'appelant.
    private func endSpeakingBecauseOfSystem() {
        guard speakingTap != nil else { return }
        finishSpeaking()
        onSpeakingInterrupted?()
    }

    // MARK: Parole

    /// Passe en mode parole : session `.playAndRecord`, unité Voice Processing I/O. `completion` reçoit vrai si le micro
    /// tourne ; sinon la lecture seule est rétablie. Refusé si la lecture n'est pas en cours.
    func beginSpeaking(tap: MicTap, completion: @escaping @Sendable (Bool) -> Void) {
        perform { [self] in
            completion(startSpeaking(tap))
        }
    }

    /// Retour à la lecture seule. Sans effet hors parole.
    func endSpeaking() {
        perform { [self] in
            finishSpeaking()
        }
    }

    private func startSpeaking(_ tap: MicTap) -> Bool {
        guard isPlaying, speakingTap == nil, !interrupted else { return false }
        speakingTap = tap
        if swapUnit() {
            return true
        }
        speakingTap = nil
        if !swapUnit() {
            // Plus d'unité : la prochaine `initializePlayout` doit en refaire une.
            isPlaying = false
            isPlayoutInitialized = false
        }
        return false
    }

    private func finishSpeaking() {
        guard speakingTap != nil else { return }
        speakingTap = nil
        if isPlaying, !swapUnit() {
            isPlaying = false
            isPlayoutInitialized = false
        }
    }

    /// Remplace l'unité par celle du mode voulu (`speakingTap` ou non), session comprise, et la démarre, sauf pendant
    /// une interruption : `resumeAfterInterruption` s'en chargera.
    private func swapUnit() -> Bool {
        if let unit {
            unit.stop()
            unit.dispose()
            self.unit = nil
        }
        guard session.setSpeakingMode(speakingTap != nil) else { return false }
        let startNow = !interrupted
        if startNow {
            guard (try? session.setActive(true)) != nil else { return false }
        }
        guard let next = makeUnit() else { return false }
        if startNow, !next.start() {
            next.dispose()
            return false
        }
        unit = next
        // Autre unité, autre fil de rendu, souvent autre durée de tampon : on est sur le fil de WebRTC, comme son contrat l'exige.
        delegate?.notifyAudioOutputInterrupted()
        delegate?.notifyAudioOutputParametersChange()
        return true
    }

    /// Exécute sur le fil de WebRTC s'il y en a un, sinon tout de suite.
    private func perform(_ work: @escaping @Sendable () -> Void) {
        if let delegate {
            delegate.dispatchAsync(work)
        } else {
            work()
        }
    }

    func initializePlayout() -> Bool {
        guard !isPlayoutInitialized else { return true }
        guard prepareSession(), let unit = makeUnit() else { return false }
        self.unit = unit
        isPlayoutInitialized = true
        return true
    }

    /// Pose la catégorie de la session si elle ne l'est pas déjà : une seule fois, pas à chaque prise de parole.
    private func prepareSession() -> Bool {
        if !sessionPrepared {
            sessionPrepared = session.prepare()
        }
        return sessionPrepared
    }

    func startPlayout() -> Bool {
        guard let unit, isPlayoutInitialized else { return false }
        guard !isPlaying else { return true }
        // Retour au premier plan : la catégorie tient déjà (ce n'est qu'un test), sauf si elle n'a jamais pu être posée.
        guard prepareSession() else { return false }
        do {
            try session.setActive(true)
        } catch {
            return false
        }
        guard unit.start() else {
            try? session.setActive(false)
            return false
        }
        isPlaying = true
        return true
    }

    func stopPlayout() -> Bool {
        guard isPlaying, let unit else { return true }
        unit.stop()
        isPlaying = false
        if speakingTap != nil {
            // La lecture s'arrête : le micro aussi. L'unité de lecture seule est refaite pour un prochain démarrage.
            speakingTap = nil
            unit.dispose()
            self.unit = nil
            isPlayoutInitialized = false
            if session.setSpeakingMode(false), let fresh = makeUnit() {
                self.unit = fresh
                isPlayoutInitialized = true
            }
            onSpeakingInterrupted?()
        }
        try? session.setActive(false)
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

    /// L'unité du mode en cours : RemoteIO en lecture seule, Voice Processing I/O pendant la parole.
    private func makeUnit() -> (any AudioIOUnit)? {
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        if let speakingTap {
            return units.makeVoiceChat(refCon: refCon, tap: speakingTap)
        }
        return units.makePlayout(refCon: refCon)
    }

    private func disposeUnit() {
        guard let unit else { return }
        unit.dispose()
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

func playoutRender(
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
