import AVFoundation
import AudioToolbox
import Synchronization

/// La session audio de l'app, derrière un protocole pour que les tests n'en ouvrent aucune.
///
/// Spec parler § 6.2 : la catégorie est posée une seule fois, à l'avance (`prepare`) ; l'appui et le relâchement ne
/// changent que le mode (`setSpeakingMode`), ce qui évite de reconfigurer tout le circuit audio d'iOS à chaque prise de
/// parole.
protocol PlayoutSession: AnyObject, Sendable {
    /// Pose la catégorie `.playAndRecord`, mode par défaut, sans ouvrir d'entrée : tant qu'aucune unité ne lit le micro,
    /// iOS n'en capte rien (pas de voyant orange). Faux si le système refuse.
    func prepare() -> Bool
    /// Passe en mode voix (`true`, pendant la parole) ou revient au mode par défaut (`false`), sans toucher à la
    /// catégorie ni aux options. Faux si le système refuse.
    func setSpeakingMode(_ speaking: Bool) -> Bool
    /// Active ; désactive en prévenant les autres apps (leur musique reprend).
    func setActive(_ active: Bool) throws
}

final class SystemPlayoutSession: PlayoutSession {
    /// `.playAndRecord` plutôt que `.playback` : seul moyen de passer à la parole sans changer de catégorie.
    static let category = AVAudioSession.Category.playAndRecord
    /// Hors parole, le mode par défaut : pas de `.voiceChat` (traitement de la voix, qualité de lecture réduite).
    static let defaultMode = AVAudioSession.Mode.default
    /// Pendant la parole. Appliqué avec l'unité Voice Processing I/O, qui fait seule l'annulation d'écho ; le mode
    /// `.voiceChat` y ajoute le réglage système prévu pour la voix (gain, route). Si le banc montre que `.default`
    /// suffit à l'écho, mettre `.default` ici évite même ce changement de mode à l'appui.
    static let speakingMode = AVAudioSession.Mode.voiceChat
    /// - `.defaultToSpeaker` : le son de la caméra sort par le haut-parleur, pas par l'écouteur (`.playAndRecord` vise
    ///   l'écouteur par défaut) ;
    /// - `.mixWithOthers` : la musique des autres apps continue, comme avant ;
    /// - `.allowBluetoothHFP` : un casque Bluetooth peut servir de micro pendant la parole ;
    /// - `.allowBluetoothA2DP` : hors parole, un casque ou une enceinte Bluetooth garde le profil stéréo (A2DP) au lieu
    ///   de tomber au profil téléphone (HFP, mono, voix) que `.playAndRecord` imposerait sans cette option.
    static let categoryOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP]

    func prepare() -> Bool {
        apply(mode: Self.defaultMode)
    }

    /// Catégorie, mode et options reposés ensemble : un `setMode` seul laissait iOS revenir à l'écouteur après la parole
    /// (banc du 10/10 : le son de la caméra ne sortait plus que par l'écouteur, donc faible).
    func setSpeakingMode(_ speaking: Bool) -> Bool {
        apply(mode: speaking ? Self.speakingMode : Self.defaultMode)
    }

    private func apply(mode: AVAudioSession.Mode) -> Bool {
        let session = AVAudioSession.sharedInstance()
        guard (try? session.setCategory(Self.category, mode: mode, options: Self.categoryOptions)) != nil else { return false }
        Self.leaveReceiver(session)
        return true
    }

    /// Si la sortie est l'écouteur du téléphone (`.builtInReceiver`), on force le haut-parleur. Un casque, des AirPods ou
    /// une enceinte branchés gardent leur sortie : la route n'est alors pas l'écouteur.
    static func leaveReceiver(_ session: AVAudioSession) {
        let onReceiver = session.currentRoute.outputs.contains { $0.portType == .builtInReceiver }
        if onReceiver {
            try? session.overrideOutputAudioPort(.speaker)
        }
    }

    func setActive(_ active: Bool) throws {
        if active {
            try AVAudioSession.sharedInstance().setActive(true)
            Self.leaveReceiver(AVAudioSession.sharedInstance())
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Une unité audio démarrable : RemoteIO en lecture seule, ou Voice Processing I/O pendant la parole.
protocol AudioIOUnit: AnyObject, Sendable {
    func start() -> Bool
    func stop()
    /// Libère l'unité. L'unité est arrêtée avant.
    func dispose()
}

/// Fabrique des unités, derrière un protocole : les tests n'ouvrent ni haut-parleur ni micro.
protocol AudioIOUnitFactory: Sendable {
    /// Lecture seule : rappel de rendu `playoutRender`, entrée désactivée.
    func makePlayout(refCon: UnsafeMutableRawPointer) -> (any AudioIOUnit)?
    /// Parole : entrée et sortie, avec annulation d'écho ; `tap` reçoit le micro.
    func makeVoiceChat(refCon: UnsafeMutableRawPointer, tap: MicTap) -> (any AudioIOUnit)?
}

/// Le côté micro du rappel d'entrée temps réel : tout est réservé à l'avance (tampon de lecture du micro, liste de
/// tampons), si bien que `handle` n'alloue rien, ne prend aucun verrou et n'attend pas. Le tampon circulaire du
/// `VoiceCapture` reçoit les échantillons.
///
/// `@unchecked Sendable` : `pull` est posé une fois, à la création de l'unité, avant son démarrage ; `handle` n'est
/// appelé que par le fil audio, seul à toucher `scratch` et `list`.
final class MicTap: @unchecked Sendable {
    /// Taille de la réserve : plus grand que n'importe quel bloc de rendu d'iOS (4096 images au plus).
    static let maxFrames = 4096

    typealias Pull = @Sendable (
        UnsafeMutablePointer<AudioUnitRenderActionFlags>, UnsafePointer<AudioTimeStamp>, UInt32, UInt32, UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus

    private let ring: AudioRingBuffer
    private let scratch: UnsafeMutablePointer<Int16>
    private let list: UnsafeMutablePointer<AudioBufferList>
    /// Va chercher les échantillons du micro dans l'unité (`AudioUnitRender` sur le bus 1).
    var pull: Pull?

    init(ring: AudioRingBuffer) {
        self.ring = ring
        scratch = .allocate(capacity: Self.maxFrames)
        scratch.initialize(repeating: 0, count: Self.maxFrames)
        list = .allocate(capacity: 1)
        list.initialize(to: AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        ))
    }

    deinit {
        scratch.deallocate()
        list.deallocate()
    }

    /// Fil audio : demande `frames` échantillons au micro et les range dans le tampon.
    func handle(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        guard let pull else { return kAudioUnitErr_Uninitialized }
        guard Int(frames) <= Self.maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }
        list.pointee.mNumberBuffers = 1
        list.pointee.mBuffers.mNumberChannels = 1
        list.pointee.mBuffers.mDataByteSize = frames * UInt32(MemoryLayout<Int16>.size)
        list.pointee.mBuffers.mData = UnsafeMutableRawPointer(scratch)
        let status = pull(flags, timestamp, bus, frames, list)
        guard status == noErr else { return status }
        ring.write(scratch, count: Int(frames), time: HostClock.nowNanoseconds())
        return noErr
    }
}

/// Rappel d'entrée du micro (Voice Processing I/O). Fonction globale, hors de tout type isolé : écrit dans une
/// méthode d'un type `@MainActor`, ce rappel hériterait de l'isolation du fil principal, et le compilateur y mettrait un
/// contrôle d'exécuteur qui plante (SIGTRAP) au premier appel du fil audio.
func micInputProc(
    _ refCon: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timestamp: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32,
    _ frames: UInt32,
    _ data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    Unmanaged<MicTap>.fromOpaque(refCon).takeUnretainedValue().handle(flags, timestamp, bus, frames)
}

/// Une vraie unité audio du système.
final class SystemAudioUnit: AudioIOUnit, @unchecked Sendable {
    fileprivate let unit: AudioUnit
    /// Le micro dont le rappel d'entrée tient un pointeur non retenu : il vit au moins autant que l'unité.
    private var tap: MicTap?

    fileprivate init(_ unit: AudioUnit, tap: MicTap? = nil) {
        self.unit = unit
        self.tap = tap
    }

    func start() -> Bool {
        AudioOutputUnitStart(unit) == noErr
    }

    func stop() {
        AudioOutputUnitStop(unit)
    }

    func dispose() {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        tap = nil
    }
}

/// Les vraies unités : RemoteIO pour la lecture, Voice Processing I/O pour la parole. PCM 16 bits mono à 48 kHz des
/// deux côtés (le format que WebRTC attend), le système convertit vers le matériel.
struct SystemAudioUnitFactory: AudioIOUnitFactory {
    private static func format() -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(2 * PlayoutAudioDevice.channels)
        return AudioStreamBasicDescription(
            mSampleRate: PlayoutAudioDevice.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(PlayoutAudioDevice.channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    private static func makeUnit(subType: OSType) -> AudioUnit? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr else { return nil }
        return instance
    }

    func makePlayout(refCon: UnsafeMutableRawPointer) -> (any AudioIOUnit)? {
        guard let unit = Self.makeUnit(subType: kAudioUnitSubType_RemoteIO) else { return nil }
        var format = Self.format()
        var inputOff: UInt32 = 0
        var callback = AURenderCallbackStruct(inputProc: playoutRender, inputProcRefCon: refCon)
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
        return SystemAudioUnit(unit)
    }

    func makeVoiceChat(refCon: UnsafeMutableRawPointer, tap: MicTap) -> (any AudioIOUnit)? {
        guard let unit = Self.makeUnit(subType: kAudioUnitSubType_VoiceProcessingIO) else { return nil }
        var format = Self.format()
        var on: UInt32 = 1
        var render = AURenderCallbackStruct(inputProc: playoutRender, inputProcRefCon: refCon)
        var input = AURenderCallbackStruct(inputProc: micInputProc, inputProcRefCon: Unmanaged.passUnretained(tap).toOpaque())
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let ok = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &on, UInt32(MemoryLayout<UInt32>.size)
        ) == noErr
            && AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &on, UInt32(MemoryLayout<UInt32>.size)
            ) == noErr
            // Ce que la lecture fournit (bus 0, côté entrée) et ce que le micro rend (bus 1, côté sortie).
            && AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, size) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, size) == noErr
            && AudioUnitSetProperty(
                unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &render, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ) == noErr
            && AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &input, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ) == noErr
            && AudioUnitInitialize(unit) == noErr
        guard ok else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        let reference = UnitReference(unit: unit)
        tap.pull = { flags, timestamp, bus, frames, data in
            AudioUnitRender(reference.unit, flags, timestamp, bus, frames, data)
        }
        return SystemAudioUnit(unit, tap: tap)
    }
}

/// Un `AudioUnit` (pointeur opaque) que le rappel d'entrée emporte avec lui : l'unité vit tant que le rappel peut
/// être appelé (elle est détruite après l'arrêt).
private struct UnitReference: @unchecked Sendable {
    let unit: AudioUnit
}
