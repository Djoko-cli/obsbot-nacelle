import Foundation
import Testing
@testable import PTZAuth

@Suite("Code d'appairage")
struct PairingCodeTests {
    let directory: URL
    let clock = TestClock()
    let pairing: PairingCode

    init() throws {
        directory = try makeTemporaryDirectory()
        let clock = clock
        pairing = PairingCode(url: directory.appending(path: "pairing.json"), now: { clock.now })
    }

    @Test("Six chiffres, fichier en droits 600 sans le code en clair")
    func open() throws {
        let code = try pairing.open()
        #expect(code.count == 6 && code.allSatisfy(\.isNumber))
        let attributes = try FileManager.default.attributesOfItem(atPath: pairing.url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(!(try String(contentsOf: pairing.url, encoding: .utf8)).contains(code))
    }

    @Test("Le bon code est accepté une seule fois")
    func singleUse() throws {
        let code = try pairing.open()
        #expect(pairing.attempt(code) == .accepted)
        #expect(pairing.attempt(code) == .closed)
        #expect(!FileManager.default.fileExists(atPath: pairing.url.path))
    }

    @Test("Trois essais faux annulent le code")
    func threeFailures() throws {
        let code = try pairing.open()
        let wrong = code == "000000" ? "000001" : "000000"
        #expect(pairing.attempt(wrong) == .wrong)
        #expect(pairing.attempt(wrong) == .wrong)
        #expect(pairing.attempt(wrong) == .wrong)
        #expect(pairing.attempt(code) == .closed)
    }

    @Test("Deux essais faux puis le bon : accepté")
    func failuresThenSuccess() throws {
        let code = try pairing.open()
        let wrong = code == "000000" ? "000001" : "000000"
        #expect(pairing.attempt(wrong) == .wrong)
        #expect(pairing.attempt(wrong) == .wrong)
        #expect(pairing.attempt(code) == .accepted)
    }

    @Test("Expiré après 5 min")
    func expiry() throws {
        let code = try pairing.open()
        clock.advance(PairingCode.lifetime - 1)
        let wrong = code == "000000" ? "000001" : "000000"
        #expect(pairing.attempt(wrong) == .wrong)
        clock.advance(2)
        #expect(pairing.attempt(code) == .closed)
    }

    @Test("Bon code mais fichier impossible à effacer : refusé (usage unique)")
    func acceptedOnlyIfErased() throws {
        let code = try pairing.open()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        #expect(pairing.attempt(code) == .closed)
    }

    @Test("Sans code en cours : fermé")
    func noCode() {
        #expect(pairing.attempt("123456") == .closed)
    }

    @Test("Un nouveau code remplace l'ancien")
    func reopen() throws {
        let first = try pairing.open()
        var second = try pairing.open()
        while second == first {
            second = try pairing.open()
        }
        #expect(pairing.attempt(first) == .wrong)
        #expect(pairing.attempt(second) == .accepted)
    }
}