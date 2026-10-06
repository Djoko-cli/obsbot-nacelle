import CryptoKit
import Foundation
import NacelleProtocol

/// Issue d'une authentification.
public enum AuthCheck: Equatable, Sendable {
    case accepted(PairedDevice)
    case unknownDevice
    case badSignature
    /// `devices.json` illisible : personne n'entre (spec accès local § 9).
    case registryUnreadable
}

/// Issue d'un appairage.
public enum PairResult: Equatable, Sendable {
    /// Appareil enregistré, avec son secret du réseau local.
    case paired(deviceID: String, lanKey: Data)
    case badCode
    case closed
    /// La clé publique n'est pas une clé P-256 x963.
    case invalidKey
}

/// Décide qui entre : appareils appairés et code d'appairage (spec accès local § 6.3 et § 6.4).
public struct DeviceAuthority: Sendable {
    public let devices: PairedDevices
    public let pairing: PairingCode
    private let now: @Sendable () -> Date

    public init(devices: PairedDevices, pairing: PairingCode, now: @escaping @Sendable () -> Date = { Date() }) {
        self.devices = devices
        self.pairing = pairing
        self.now = now
    }

    /// Les deux fichiers dans le dossier de travail de ptzd.
    public init(directory: URL) {
        self.init(
            devices: PairedDevices(url: directory.appending(path: "devices.json")),
            pairing: PairingCode(url: directory.appending(path: "pairing.json"))
        )
    }

    /// Un défi neuf.
    public static func makeNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<NacelleAuth.nonceLength).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    public func check(deviceID: String, signature: Data, nonce: Data) -> AuthCheck {
        let device: PairedDevice?
        do {
            device = try devices.device(id: deviceID)
        } catch {
            return .registryUnreadable
        }
        guard let device else { return .unknownDevice }
        let valid = NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: device.publicKey)
        return valid ? .accepted(device) : .badSignature
    }

    public func pair(code: String, publicKey: Data, name: String) -> PairResult {
        guard (try? P256.Signing.PublicKey(x963Representation: publicKey)) != nil else { return .invalidKey }
        switch pairing.attempt(code) {
        case .closed:
            return .closed
        case .wrong:
            return .badCode
        case .accepted:
            let deviceID = NacelleAuth.deviceID(publicKeyX963: publicKey)
            let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            let lanKey = NacelleTLS.makeKey()
            let device = PairedDevice(
                deviceID: deviceID, name: cleanName.isEmpty ? "appareil" : cleanName,
                publicKey: publicKey, pairedAt: now(), lanKey: lanKey
            )
            do {
                try devices.add(device)
            } catch {
                return .closed
            }
            return .paired(deviceID: deviceID, lanKey: lanKey)
        }
    }

    /// Les secrets du réseau local, par appareil (fichier illisible : aucun).
    public func lanKeys() -> [String: Data] {
        let all = (try? devices.all()) ?? []
        return all.reduce(into: [:]) { keys, device in
            keys[device.deviceID] = device.lanKey
        }
    }

    /// Le secret d'un appareil encore appairé, relu dans `devices.json`.
    public func lanKey(for deviceID: String) -> Data? {
        (try? devices.device(id: deviceID))?.flatMap(\.lanKey)
    }
}

extension PairResult {
    /// L'appareil enregistré, s'il y en a un.
    public var deviceID: String? {
        if case let .paired(deviceID, _) = self { deviceID } else { nil }
    }
}