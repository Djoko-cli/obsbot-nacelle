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

/// Décide qui entre : appareils appairés et appairage par QR code en cours (spec accès local § 6.3,
/// spec découverte et QR § 7.1).
public struct DeviceAuthority: Sendable {
    public let devices: PairedDevices
    public let pairing: PairingWindow
    private let now: @Sendable () -> Date

    public init(devices: PairedDevices, pairing: PairingWindow, now: @escaping @Sendable () -> Date = { Date() }) {
        self.devices = devices
        self.pairing = pairing
        self.now = now
    }

    /// `devices.json` dans le dossier de travail de ptzd ; l'appairage en cours vit en mémoire.
    public init(directory: URL) {
        self.init(devices: PairedDevices(url: directory.appending(path: "devices.json")), pairing: PairingWindow())
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

    /// Appairage par QR code : la preuve porte sur le défi `nonce` de la connexion.
    public func pair(pairingID: String, publicKey: Data, name: String, proof: Data, nonce: Data) -> PairResult {
        guard (try? P256.Signing.PublicKey(x963Representation: publicKey)) != nil else { return .invalidKey }
        switch pairing.attempt(pairingID: pairingID, proof: proof, nonce: nonce, publicKeyX963: publicKey) {
        case .closed:
            return .closed
        case .wrong:
            return .badCode
        case .accepted:
            let deviceID = NacelleAuth.deviceID(publicKeyX963: publicKey)
            let lanKey = NacelleTLS.makeKey()
            let device = PairedDevice(
                deviceID: deviceID, name: PairedDevice.cleanName(name),
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

    /// Les secrets du réseau local, par appareil (fichier absent : aucun) ; erreur si `devices.json` est illisible.
    public func readLANKeys() throws -> [String: Data] {
        try devices.all().reduce(into: [:]) { keys, device in
            keys[device.deviceID] = device.lanKey
        }
    }

    /// Les secrets du réseau local, par appareil (fichier illisible : aucun).
    public func lanKeys() -> [String: Data] {
        (try? readLANKeys()) ?? [:]
    }

    /// Le secret d'un appareil encore appairé, relu dans `devices.json`.
    public func lanKey(for deviceID: String) -> Data? {
        (try? devices.device(id: deviceID))?.flatMap(\.lanKey)
    }

    /// Identités TLS du réseau local : les appareils, et l'appairage en cours ; erreur si `devices.json` est illisible.
    public func tlsIdentities() throws -> [String] {
        var identities = Array(try readLANKeys().keys)
        if let current = pairing.current {
            identities.append(NacelleTLS.pairingIdentity(current.pairingID))
        }
        return identities
    }

    /// Clé TLS d'une identité : le secret du QR pour l'appairage en cours, sinon celui de l'appareil.
    public func tlsKey(for identity: String) -> Data? {
        if let current = pairing.current, identity == NacelleTLS.pairingIdentity(current.pairingID) {
            return current.secret
        }
        return lanKey(for: identity)
    }
}

extension PairResult {
    /// L'appareil enregistré, s'il y en a un.
    public var deviceID: String? {
        if case let .paired(deviceID, _) = self { deviceID } else { nil }
    }
}