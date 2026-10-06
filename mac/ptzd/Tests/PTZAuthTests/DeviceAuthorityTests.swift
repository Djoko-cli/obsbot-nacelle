import CryptoKit
import Foundation
import NacelleProtocol
import Testing
@testable import PTZAuth

@Suite("Appareils appairés et authentification")
struct DeviceAuthorityTests {
    let directory: URL
    let authority: DeviceAuthority
    let key = P256.Signing.PrivateKey()

    init() throws {
        directory = try makeTemporaryDirectory()
        authority = DeviceAuthority(directory: directory)
    }

    var publicKey: Data { key.publicKey.x963Representation }
    var deviceID: String { NacelleAuth.deviceID(publicKeyX963: publicKey) }

    func signature(_ nonce: Data, deviceID: String? = nil) throws -> Data {
        try key.signature(for: NacelleAuth.signedPayload(nonce: nonce, deviceID: deviceID ?? self.deviceID)).derRepresentation
    }

    /// Appairage par QR code complet : ouverture, preuve sur un défi, enregistrement.
    @discardableResult
    func pairDevice(name: String = "iPhone de test") -> PairResult {
        let opened = authority.pairing.open()
        let nonce = DeviceAuthority.makeNonce()
        let proof = NacelleAuth.pairingProof(secret: opened.secret, nonce: nonce, publicKeyX963: publicKey)
        let result = authority.pair(pairingID: opened.pairingID, publicKey: publicKey, name: name, proof: proof, nonce: nonce)
        #expect(result.deviceID == deviceID)
        return result
    }

    @Test("Secret du réseau local : 32 octets, gardé avec l'appareil, oublié au retrait")
    func lanKey() throws {
        guard case let .paired(_, lanKey) = pairDevice(name: "iPhone") else {
            Issue.record("appairage attendu")
            return
        }
        #expect(lanKey.count == 32)
        #expect(authority.lanKey(for: deviceID) == lanKey)
        #expect(authority.lanKeys() == [deviceID: lanKey])
        try authority.devices.remove(prefix: String(deviceID.prefix(8)))
        #expect(authority.lanKey(for: deviceID) == nil)
        #expect(authority.lanKeys().isEmpty)
    }

    @Test("Appareil appairé avant le canal chiffré : relu sans secret")
    func legacyDevice() throws {
        try authority.devices.add(PairedDevice(deviceID: "abcd0000", name: "ancien", publicKey: Data([4]), pairedAt: Date(timeIntervalSince1970: 0)))
        #expect(authority.lanKey(for: "abcd0000") == nil)
        #expect(authority.lanKeys().isEmpty)
    }

    @Test("Secrets du réseau local : fichier absent, aucun ; fichier illisible, une erreur")
    func readLANKeys() throws {
        #expect(try authority.readLANKeys().isEmpty)
        try Data("pas du json".utf8).write(to: directory.appending(path: "devices.json"))
        #expect(throws: (any Error).self) { try authority.readLANKeys() }
        #expect(authority.lanKeys().isEmpty)
    }

    @Test("Défi : 32 octets, différent à chaque fois")
    func nonce() {
        let first = DeviceAuthority.makeNonce()
        #expect(first.count == 32)
        #expect(first != DeviceAuthority.makeNonce())
    }

    @Test("Appairage puis authentification")
    func pairThenAuth() throws {
        pairDevice()
        let nonce = DeviceAuthority.makeNonce()
        guard case let .accepted(device) = authority.check(deviceID: deviceID, signature: try signature(nonce), nonce: nonce) else {
            Issue.record("refusé")
            return
        }
        #expect(device.name == "iPhone de test")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "devices.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test("Appareil inconnu, signature d'un autre défi : refus")
    func refusals() throws {
        let nonce = DeviceAuthority.makeNonce()
        #expect(authority.check(deviceID: deviceID, signature: try signature(nonce), nonce: nonce) == .unknownDevice)
        pairDevice()
        let replayed = try signature(DeviceAuthority.makeNonce())
        #expect(authority.check(deviceID: deviceID, signature: replayed, nonce: nonce) == .badSignature)
    }

    @Test("devices.json illisible : personne n'entre")
    func unreadableRegistry() throws {
        try Data("pas du json".utf8).write(to: directory.appending(path: "devices.json"))
        let nonce = DeviceAuthority.makeNonce()
        #expect(authority.check(deviceID: deviceID, signature: try signature(nonce), nonce: nonce) == .registryUnreadable)
    }

    @Test("Appairage : aucun en cours, preuve fausse, autre identifiant, clé invalide")
    func pairFailures() throws {
        let nonce = DeviceAuthority.makeNonce()
        #expect(authority.pair(pairingID: "00000000", publicKey: publicKey, name: "x", proof: Data(), nonce: nonce) == .closed)
        let opened = authority.pairing.open()
        let proof = NacelleAuth.pairingProof(secret: opened.secret, nonce: nonce, publicKeyX963: publicKey)
        let other = NacelleAuth.pairingProof(secret: NacelleTLS.makeKey(), nonce: nonce, publicKeyX963: publicKey)
        #expect(authority.pair(pairingID: opened.pairingID, publicKey: publicKey, name: "x", proof: other, nonce: nonce) == .badCode)
        #expect(authority.pair(pairingID: "ffffffff", publicKey: publicKey, name: "x", proof: proof, nonce: nonce) == .closed)
        #expect(authority.pair(pairingID: opened.pairingID, publicKey: Data([4, 1, 2]), name: "x", proof: proof, nonce: nonce) == .invalidKey)
        #expect(authority.pair(pairingID: opened.pairingID, publicKey: publicKey, name: "x", proof: proof, nonce: nonce).deviceID == deviceID)
    }

    @Test("Identités TLS : les appareils, plus l'appairage en cours ; clé de chacune")
    func tlsIdentities() throws {
        pairDevice()
        #expect(try authority.tlsIdentities() == [deviceID])
        let opened = authority.pairing.open()
        let identity = NacelleTLS.pairingIdentity(opened.pairingID)
        #expect(Set(try authority.tlsIdentities()) == [deviceID, identity])
        #expect(authority.tlsKey(for: identity) == opened.secret)
        #expect(authority.tlsKey(for: deviceID) == authority.lanKey(for: deviceID))
        authority.pairing.close()
        #expect(authority.tlsKey(for: identity) == nil)
        #expect(try authority.tlsIdentities() == [deviceID])
    }

    @Test("Nom nettoyé : espaces retirés, 40 caractères au plus, « appareil » si vide")
    func names() throws {
        pairDevice(name: "   ")
        #expect(try authority.devices.device(id: deviceID)?.name == "appareil")
        pairDevice(name: "  " + String(repeating: "a", count: 60))
        #expect(try authority.devices.device(id: deviceID)?.name == String(repeating: "a", count: 40))
    }

    @Test("revoke par début d'identifiant ; trop court, inconnu ou ambigu : erreur")
    func revoke() throws {
        pairDevice()
        #expect(throws: PairedDevicesError.noMatch("abc")) { try authority.devices.remove(prefix: "abc") }
        #expect(throws: PairedDevicesError.noMatch("zzzz")) { try authority.devices.remove(prefix: "zzzz") }
        let removed = try authority.devices.remove(prefix: String(deviceID.prefix(6)).uppercased())
        #expect(removed.deviceID == deviceID)
        let nonce = DeviceAuthority.makeNonce()
        #expect(authority.check(deviceID: deviceID, signature: try signature(nonce), nonce: nonce) == .unknownDevice)
    }

    @Test("Deux appareils au même début d'identifiant : ambigu")
    func ambiguous() throws {
        let devices = authority.devices
        let date = Date(timeIntervalSince1970: 0)
        try devices.add(PairedDevice(deviceID: "abcd0000", name: "a", publicKey: Data([1]), pairedAt: date))
        try devices.add(PairedDevice(deviceID: "abcd1111", name: "b", publicKey: Data([2]), pairedAt: date))
        #expect(throws: PairedDevicesError.ambiguous("abcd")) { try devices.remove(prefix: "abcd") }
        #expect(try devices.remove(prefix: "abcd1").name == "b")
        #expect(try devices.all().map(\.name) == ["a"])
    }
}