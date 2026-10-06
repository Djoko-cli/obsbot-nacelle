import Foundation
import NacelleProtocol
import Testing
@testable import PTZAuth

@Suite("Fenêtre d'appairage par QR code")
struct PairingWindowTests {
    let clock = TestClock()
    let window: PairingWindow
    let nonce = Data(repeating: 7, count: 32)
    let key = Data([4, 1, 2, 3])

    init() {
        let clock = clock
        window = PairingWindow(now: { clock.now })
    }

    private func proof(_ secret: Data) -> Data {
        NacelleAuth.pairingProof(secret: secret, nonce: nonce, publicKeyX963: key)
    }

    @Test("Ouverture : identifiant de 8 caractères hexadécimaux, secret de 32 octets, 5 min")
    func open() {
        let opened = window.open()
        #expect(opened.pairingID.count == 8 && opened.pairingID.allSatisfy(\.isHexDigit))
        #expect(opened.secret.count == 32)
        #expect(opened.expiresAt == clock.now + PairingWindow.lifetime)
        #expect(window.current?.pairingID == opened.pairingID)
        #expect(window.current?.secret == opened.secret)
    }

    @Test("Bonne preuve : acceptée une seule fois")
    func singleUse() {
        let opened = window.open()
        #expect(window.attempt(pairingID: opened.pairingID, proof: proof(opened.secret), nonce: nonce, publicKeyX963: key) == .accepted)
        #expect(window.attempt(pairingID: opened.pairingID, proof: proof(opened.secret), nonce: nonce, publicKeyX963: key) == .closed)
        #expect(window.current == nil)
    }

    @Test("Trois preuves fausses ferment l'appairage")
    func threeFailures() {
        let opened = window.open()
        let wrong = proof(NacelleTLS.makeKey())
        for _ in 0..<3 {
            #expect(window.attempt(pairingID: opened.pairingID, proof: wrong, nonce: nonce, publicKeyX963: key) == .wrong)
        }
        #expect(window.attempt(pairingID: opened.pairingID, proof: proof(opened.secret), nonce: nonce, publicKeyX963: key) == .closed)
    }

    @Test("Expiré après 5 min")
    func expiry() {
        let opened = window.open()
        clock.advance(PairingWindow.lifetime)
        #expect(window.current == nil)
        #expect(window.attempt(pairingID: opened.pairingID, proof: proof(opened.secret), nonce: nonce, publicKeyX963: key) == .closed)
    }

    @Test("Un nouvel appairage remplace l'ancien ; close ciblé")
    func replaceAndClose() {
        let first = window.open()
        let second = window.open()
        #expect(window.attempt(pairingID: first.pairingID, proof: proof(first.secret), nonce: nonce, publicKeyX963: key) == .closed)
        #expect(!window.close(first.pairingID))
        #expect(window.current?.pairingID == second.pairingID)
        #expect(window.close(second.pairingID))
        #expect(window.current == nil)
    }

    @Test("Fermeture après l'échéance : l'appairage stocké est fermé une fois")
    func closeAfterExpiry() {
        let opened = window.open()
        clock.advance(PairingWindow.lifetime + 1)
        #expect(window.current == nil)
        #expect(window.close(opened.pairingID))
        #expect(!window.close(opened.pairingID))
        let another = window.open()
        #expect(!window.close(opened.pairingID))
        #expect(window.close(another.pairingID))
    }
}
