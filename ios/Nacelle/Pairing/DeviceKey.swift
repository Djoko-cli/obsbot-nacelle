import CryptoKit
import Foundation
import NacelleProtocol
import Security

/// Clé de l'iPhone pour s'authentifier auprès de ptzd (spec accès local § 8.2) : ECDSA P-256,
/// dans la Secure Enclave quand elle existe, logicielle sinon (simulateur).
protocol DeviceKey: Sendable {
    /// Clé publique, format x963.
    var publicKeyX963: Data { get }
    /// Signature DER de `data`.
    func sign(_ data: Data) throws -> Data
}

extension DeviceKey {
    var deviceID: String {
        NacelleAuth.deviceID(publicKeyX963: publicKeyX963)
    }

    /// Réponse au défi de ptzd.
    func signChallenge(_ nonce: Data) throws -> Data {
        try sign(NacelleAuth.signedPayload(nonce: nonce, deviceID: deviceID))
    }
}

struct SecureEnclaveDeviceKey: DeviceKey {
    let key: SecureEnclave.P256.Signing.PrivateKey

    var publicKeyX963: Data {
        key.publicKey.x963Representation
    }

    func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).derRepresentation
    }
}

struct SoftwareDeviceKey: DeviceKey {
    let key: P256.Signing.PrivateKey

    var publicKeyX963: Data {
        key.publicKey.x963Representation
    }

    func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).derRepresentation
    }
}

/// Où l'app garde sa clé. Derrière un protocole pour les tests.
@MainActor
protocol DeviceKeyStoring: AnyObject {
    /// La clé existante, ou nil.
    func load() -> (any DeviceKey)?
    /// La clé existante, ou une nouvelle, enregistrée.
    func loadOrCreate() throws -> any DeviceKey
    /// Oublie la clé.
    func delete()
}

enum DeviceKeyError: Error, Equatable {
    case keychain(OSStatus)
}

/// La clé dans le trousseau : une entrée par sorte de clé, accessible après le premier
/// déverrouillage, jamais sauvegardée hors de cet iPhone. Une clé Secure Enclave n'y laisse
/// qu'une forme chiffrée, inutilisable sur un autre appareil.
@MainActor
final class KeychainDeviceKeyStore: DeviceKeyStoring {
    static let service = "io.github.djoko-cli.nacelle.device-key"
    private static let secureEnclaveAccount = "secure-enclave"
    private static let softwareAccount = "software"

    private let useSecureEnclave: Bool

    init(useSecureEnclave: Bool = SecureEnclave.isAvailable) {
        self.useSecureEnclave = useSecureEnclave
    }

    func load() -> (any DeviceKey)? {
        try? existingKey()
    }

    func loadOrCreate() throws -> any DeviceKey {
        if let key = try existingKey() {
            return key
        }
        if useSecureEnclave {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            try Self.write(key.dataRepresentation, account: Self.secureEnclaveAccount)
            return SecureEnclaveDeviceKey(key: key)
        }
        let key = P256.Signing.PrivateKey()
        try Self.write(key.rawRepresentation, account: Self.softwareAccount)
        return SoftwareDeviceKey(key: key)
    }

    private func existingKey() throws -> (any DeviceKey)? {
        if useSecureEnclave, let data = try Self.read(Self.secureEnclaveAccount),
           let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
            return SecureEnclaveDeviceKey(key: key)
        }
        if !useSecureEnclave, let data = try Self.read(Self.softwareAccount),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return SoftwareDeviceKey(key: key)
        }
        return nil
    }

    func delete() {
        for account in [Self.secureEnclaveAccount, Self.softwareAccount] {
            SecItemDelete(Self.query(account) as CFDictionary)
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw DeviceKeyError.keychain(status)
        }
    }

    private static func write(_ data: Data, account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
    }
}
