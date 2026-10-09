import AudioToolbox
import CoreAudio
import Foundation
import TalkCore

/// Le volume principal et la sourdine réels des haut-parleurs (spec haut-parleur § 4.3) : `VirtualMainVolume` et
/// `Mute`, portée sortie, lus et écrits sans droits root. Seul le daemon en marche y touche, jamais les tests.
@MainActor
final class CoreAudioVolume: SpeakerVolume {
    private let volumeAddress = HAL.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    private let muteAddress = HAL.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)

    func read(device: DeviceID) throws -> SpeakerVolumeState {
        let volume = try HAL.get(device, volumeAddress, initial: Float32(0))
        // Un périphérique sans sourdine générale n'est jamais en sourdine.
        let muted = HAL.has(device, muteAddress) ? try HAL.get(device, muteAddress, initial: UInt32(0)) != 0 : false
        return SpeakerVolumeState(volume: volume, muted: muted)
    }

    func write(device: DeviceID, volume: Float?, muted: Bool?) throws {
        // Le volume d'abord : une sourdine levée ne laisse pas passer un volume fort d'un coup.
        if let volume {
            try HAL.set(device, volumeAddress, to: Float32(min(max(volume, 0), 1)))
        }
        if let muted, HAL.has(device, muteAddress) {
            try HAL.set(device, muteAddress, to: UInt32(muted ? 1 : 0))
        }
    }

    func observe(device: DeviceID, _ handler: @escaping @MainActor @Sendable () -> Void) -> (any Cancellable)? {
        let listeners = [volumeAddress, muteAddress].compactMap { address in
            HAL.has(device, address) ? HALListener(object: device, address: address, handler: handler) : nil
        }
        return listeners.isEmpty ? nil : CompositeCancellable(listeners)
    }
}
