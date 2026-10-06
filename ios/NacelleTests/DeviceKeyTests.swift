import CryptoKit
import Foundation
import NacelleProtocol
import Testing
@testable import Nacelle

@MainActor
@Suite("Clé de l'appareil", .serialized)
struct DeviceKeyTests {
    let store = KeychainDeviceKeyStore(useSecureEnclave: false)

    init() {
        store.delete()
    }

    @Test("Pas de clé au départ ; créée une fois, puis relue à l'identique")
    func createThenLoad() throws {
        #expect(store.load() == nil)
        let created = try store.loadOrCreate()
        #expect(store.load()?.publicKeyX963 == created.publicKeyX963)
        #expect(try store.loadOrCreate().publicKeyX963 == created.publicKeyX963)
        store.delete()
        #expect(store.load() == nil)
    }

    @Test("La réponse au défi se vérifie comme le fera ptzd")
    func challengeVerifies() throws {
        let key = try store.loadOrCreate()
        let nonce = Data((0..<32).map { UInt8($0) })
        let signature = try key.signChallenge(nonce)
        #expect(NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: key.deviceID, publicKeyX963: key.publicKeyX963))
        store.delete()
    }

    @Test("Secure Enclave : utilisée seulement si disponible (absente du simulateur)")
    func secureEnclaveAvailability() throws {
        let store = KeychainDeviceKeyStore()
        defer { store.delete() }
        let key = try store.loadOrCreate()
        if SecureEnclave.isAvailable {
            #expect(key is SecureEnclaveDeviceKey)
        } else {
            #expect(key is SoftwareDeviceKey)
        }
    }
}
