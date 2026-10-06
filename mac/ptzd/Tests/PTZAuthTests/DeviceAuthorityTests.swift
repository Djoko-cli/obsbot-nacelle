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

    func pairDevice(name: String = "iPhone de test") throws {
        let code = try authority.pairing.open()
        #expect(authority.pair(code: code, publicKey: publicKey, name: name).deviceID == deviceID)
    }

    @Test("Secret du réseau local : 32 octets, gardé avec l'appareil, oublié au retrait")
    func lanKey() throws {
        let code = try authority.pairing.open()
        guard case let .paired(_, lanKey) = authority.pair(code: code, publicKey: publicKey, name: "iPhone") else {
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

    @Test("Défi : 32 octets, différent à chaque fois")
    func nonce() {
        let first = DeviceAuthority.makeNonce()
        #expect(first.count == 32)
        #expect(first != DeviceAuthority.makeNonce())
    }

    @Test("Appairage puis authentification")
    func pairThenAuth() throws {
        try pairDevice()
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
        try pairDevice()
        let replayed = try signature(DeviceAuthority.makeNonce())
        #expect(authority.check(deviceID: deviceID, signature: replayed, nonce: nonce) == .badSignature)
    }

    @Test("devices.json illisible : personne n'entre")
    func unreadableRegistry() throws {
        try Data("pas du json".utf8).write(to: directory.appending(path: "devices.json"))
        let nonce = DeviceAuthority.makeNonce()
        #expect(authority.check(deviceID: deviceID, signature: try signature(nonce), nonce: nonce) == .registryUnreadable)
    }

    @Test("Appairage : code faux, fermé, clé invalide")
    func pairFailures() throws {
        #expect(authority.pair(code: "123456", publicKey: publicKey, name: "x") == .closed)
        let code = try authority.pairing.open()
        let wrong = code == "000000" ? "000001" : "000000"
        #expect(authority.pair(code: wrong, publicKey: publicKey, name: "x") == .badCode)
        #expect(authority.pair(code: code, publicKey: Data([4, 1, 2]), name: "x") == .invalidKey)
        #expect(authority.pair(code: code, publicKey: publicKey, name: "x").deviceID == deviceID)
    }

    @Test("Nom nettoyé : espaces retirés, 40 caractères au plus, « appareil » si vide")
    func names() throws {
        try pairDevice(name: "   ")
        #expect(try authority.devices.device(id: deviceID)?.name == "appareil")
        try pairDevice(name: "  " + String(repeating: "a", count: 60))
        #expect(try authority.devices.device(id: deviceID)?.name == String(repeating: "a", count: 40))
    }

    @Test("revoke par début d'identifiant ; trop court, inconnu ou ambigu : erreur")
    func revoke() throws {
        try pairDevice()
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