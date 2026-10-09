import AudioToolbox
import CoreAudio
import Foundation
import TalkCore

/// La liste réelle des périphériques audio (CoreAudio) : lecture seule, aucun son.
@MainActor
final class CoreAudioCatalog: DeviceCatalog {
    private let system = AudioObjectID(kAudioObjectSystemObject)

    func devices() throws -> [AudioDeviceInfo] {
        var devicesAddress = HAL.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size)
        guard status == noErr else { throw HALError(call: "liste des périphériques (taille)", status: status) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &size, &ids)
        guard status == noErr else { throw HALError(call: "liste des périphériques", status: status) }
        let defaultOutput = (try? HAL.get(system, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioObjectID(0))) ?? 0
        return ids.map { id in
            AudioDeviceInfo(
                id: id,
                name: name(of: id),
                transport: transport(of: id),
                outputChannels: outputChannels(of: id),
                isDefaultOutput: id == defaultOutput
            )
        }
    }

    func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> (any Cancellable)? {
        let listeners = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice].compactMap {
            HALListener(object: system, address: HAL.address($0), handler: handler)
        }
        return listeners.isEmpty ? nil : CompositeCancellable(listeners)
    }

    private func name(of id: AudioObjectID) -> String {
        let name = try? HAL.get(id, HAL.address(kAudioObjectPropertyName), initial: Unmanaged<CFString>?.none)
        return (name ?? nil)?.takeRetainedValue() as String? ?? "périphérique \(id)"
    }

    private func transport(of id: AudioObjectID) -> AudioTransport {
        let type = try? HAL.get(id, HAL.address(kAudioDevicePropertyTransportType), initial: UInt32(0))
        return type == kAudioDeviceTransportTypeBuiltIn ? .builtIn : .other
    }

    /// Somme des canaux de sortie (zéro pour un micro).
    private func outputChannels(of id: AudioObjectID) -> Int {
        var address = HAL.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Plusieurs écouteurs annulés ensemble.
final class CompositeCancellable: Cancellable {
    private let members: [any Cancellable]

    init(_ members: [any Cancellable]) {
        self.members = members
    }

    func cancel() {
        members.forEach { $0.cancel() }
    }
}
