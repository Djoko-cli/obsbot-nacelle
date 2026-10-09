import AudioToolbox
import CoreAudio
import Foundation
import TalkCore

/// Une erreur de CoreAudio : l'appel et son code (souvent un code de quatre lettres).
struct HALError: Error, CustomStringConvertible {
    var call: String
    var status: OSStatus

    var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: UInt32(bitPattern: status) >> $0) }
        let code = bytes.allSatisfy { (32..<127).contains($0) } ? " '\(String(decoding: bytes, as: UTF8.self))'" : ""
        return "\(call) a échoué (\(status)\(code))"
    }
}

/// Accès à l'objet-propriété de CoreAudio (HAL), sans droits particuliers.
enum HAL {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) throws -> T {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw HALError(call: "AudioObjectGetPropertyData", status: status) }
        return value
    }

    static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, to value: T) throws {
        var address = address
        var value = value
        let status = AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
        guard status == noErr else { throw HALError(call: "AudioObjectSetPropertyData", status: status) }
    }
}

/// Un écouteur de propriété de CoreAudio, retiré par `cancel()`. Les notifications arrivent sur la file principale.
final class HALListener: Cancellable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    /// nil si CoreAudio refuse l'écouteur.
    init?(object: AudioObjectID, address: AudioObjectPropertyAddress, handler: @escaping @MainActor @Sendable () -> Void) {
        self.object = object
        self.address = address
        block = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &self.address, DispatchQueue.main, block) == noErr else {
            return nil
        }
    }

    func cancel() {
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }
}
