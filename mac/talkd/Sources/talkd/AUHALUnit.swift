import AudioToolbox
import CoreAudio
import Foundation
import TalkCore

/// L'AUHAL réelle (`kAudioUnitSubType_HALOutput`) : chaque méthode est un seul appel à AudioToolbox, l'ordre est
/// tenu par `HALOutput` (TalkCore, testé avec une fausse unité). Cette classe n'est construite que dans le daemon en
/// marche, à la première prise de parole : aucun test ne l'ouvre, donc aucun son.
@MainActor
final class AUHALUnit: OutputUnit {
    private let unit: AudioUnit

    /// `AudioComponentInstanceNew` : appelé une seule fois pour toute la vie du process (par `HALOutput`).
    init() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw HALError(call: "AudioComponentFindNext (HALOutput introuvable)", status: -1)
        }
        var instance: AudioUnit?
        let status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let instance else { throw HALError(call: "AudioComponentInstanceNew", status: status) }
        unit = instance
    }

    func enableOutputOnly() throws {
        // Bus 1 : l'entrée (le micro), coupée. Bus 0 : la sortie.
        try set(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1, UInt32(0), "EnableIO (entrée)")
        try set(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0, UInt32(1), "EnableIO (sortie)")
    }

    func currentDevice() throws -> DeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        guard status == noErr else { throw HALError(call: "CurrentDevice (lecture)", status: status) }
        return device
    }

    func setCurrentDevice(_ id: DeviceID) throws {
        try set(kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: 0, AudioDeviceID(id), "CurrentDevice")
    }

    func setStreamFormat(_ format: PCMFormat) throws {
        let bytes = UInt32(MemoryLayout<Float32>.size * (format.interleaved ? format.channels : 1))
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if !format.interleaved {
            flags |= kAudioFormatFlagIsNonInterleaved
        }
        let description = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytes,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytes,
            mChannelsPerFrame: UInt32(format.channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        // Portée d'entrée du bus 0 : ce que talkd donne à l'unité.
        try set(kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Input, element: 0, description, "StreamFormat")
    }

    func setRenderCallback(refCon: UnsafeMutableRawPointer) throws {
        // Même représentation en mémoire : seul le type du pointeur des drapeaux diffère (UInt32 dans TalkCore, qui
        // n'importe pas AudioToolbox ; AudioUnitRenderActionFlags ici).
        let procedure = unsafeBitCast(TalkRender.callback, to: AURenderCallback.self)
        let callback = AURenderCallbackStruct(inputProc: procedure, inputProcRefCon: refCon)
        try set(kAudioUnitProperty_SetRenderCallback, scope: kAudioUnitScope_Input, element: 0, callback, "SetRenderCallback")
    }

    func initialize() throws {
        let status = AudioUnitInitialize(unit)
        guard status == noErr else { throw HALError(call: "AudioUnitInitialize", status: status) }
    }

    func uninitialize() {
        AudioUnitUninitialize(unit)
    }

    func start() throws {
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw HALError(call: "AudioOutputUnitStart", status: status) }
    }

    func stop() {
        AudioOutputUnitStop(unit)
    }

    var isRunning: Bool {
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
        return status == noErr && running != 0
    }

    private func set<T: BitwiseCopyable>(
        _ property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        _ value: T,
        _ name: String
    ) throws {
        var value = value
        let status = AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size))
        guard status == noErr else { throw HALError(call: name, status: status) }
    }
}
