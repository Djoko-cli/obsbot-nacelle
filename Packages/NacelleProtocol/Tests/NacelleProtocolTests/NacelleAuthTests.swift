import CryptoKit
import Foundation
import Testing
@testable import NacelleProtocol

@Suite("Authentification des appareils")
struct NacelleAuthTests {
    let key = P256.Signing.PrivateKey()
    let nonce = Data((0..<NacelleAuth.nonceLength).map { UInt8($0) })

    var publicKey: Data { key.publicKey.x963Representation }
    var deviceID: String { NacelleAuth.deviceID(publicKeyX963: publicKey) }

    func sign(nonce: Data, deviceID: String) throws -> Data {
        try key.signature(for: NacelleAuth.signedPayload(nonce: nonce, deviceID: deviceID)).derRepresentation
    }

    @Test("deviceID : 32 caractères hexadécimaux, stable pour une même clé")
    func deviceIDFormat() {
        #expect(deviceID.count == 32)
        #expect(deviceID.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(NacelleAuth.deviceID(publicKeyX963: publicKey) == deviceID)
        #expect(NacelleAuth.deviceID(publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation) != deviceID)
    }

    @Test("Preuve d'appairage : vecteur de référence (HMAC-SHA256 calculé indépendamment)")
    func pairingProofVector() {
        let proof = NacelleAuth.pairingProof(secret: Data(0..<32), nonce: Data(repeating: 7, count: 32), publicKeyX963: Data([4, 1, 2, 3]))
        #expect(proof.map { String(format: "%02x", $0) }.joined() == "0bce16e8c37b0ea2fa995642a3216cd945ae6ce5ef5bc8391b74855b9574b17b")
    }

    @Test("Preuve d'appairage : juste acceptée ; autre secret, défi ou clé refusés")
    func pairingProofVerify() {
        let secret = Data(0..<32), nonce = Data(repeating: 7, count: 32), key = Data([4, 1, 2, 3])
        let proof = NacelleAuth.pairingProof(secret: secret, nonce: nonce, publicKeyX963: key)
        #expect(NacelleAuth.verifyPairingProof(proof, secret: secret, nonce: nonce, publicKeyX963: key))
        #expect(!NacelleAuth.verifyPairingProof(proof, secret: Data(repeating: 1, count: 32), nonce: nonce, publicKeyX963: key))
        #expect(!NacelleAuth.verifyPairingProof(proof, secret: secret, nonce: Data(repeating: 8, count: 32), publicKeyX963: key))
        #expect(!NacelleAuth.verifyPairingProof(proof, secret: secret, nonce: nonce, publicKeyX963: Data([4, 1, 2, 4])))
        #expect(!NacelleAuth.verifyPairingProof(Data([1, 2]), secret: secret, nonce: nonce, publicKeyX963: key))
    }

    @Test("Charge utile signée")
    func payload() {
        let text = String(decoding: NacelleAuth.signedPayload(nonce: Data([1, 2, 3]), deviceID: "abc"), as: UTF8.self)
        #expect(text == "nacelle-auth-v1|AQID|abc")
    }

    @Test("Signature juste acceptée")
    func validSignature() throws {
        let signature = try sign(nonce: nonce, deviceID: deviceID)
        #expect(NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: publicKey))
    }

    @Test("Autre défi, autre appareil, autre clé ou données illisibles : refus")
    func invalidSignatures() throws {
        let signature = try sign(nonce: nonce, deviceID: deviceID)
        var otherNonce = nonce
        otherNonce[0] ^= 1
        #expect(!NacelleAuth.verify(signature: signature, nonce: otherNonce, deviceID: deviceID, publicKeyX963: publicKey))
        #expect(!NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: (deviceID.first == "0" ? "1" : "0") + deviceID.dropFirst(), publicKeyX963: publicKey))
        let otherKey = P256.Signing.PrivateKey().publicKey.x963Representation
        #expect(!NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: otherKey))
        #expect(!NacelleAuth.verify(signature: Data([1, 2]), nonce: nonce, deviceID: deviceID, publicKeyX963: publicKey))
        #expect(!NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: Data([4, 1])))
    }
}
