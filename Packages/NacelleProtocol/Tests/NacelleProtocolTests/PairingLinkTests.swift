import Foundation
import Testing
@testable import NacelleProtocol

@Suite("Lien d'appairage du QR code")
struct PairingLinkTests {
    let link = PairingLink(pairingID: "1a2b3c4d", secret: Data((0..<32).map { UInt8(250 - $0) }), hosts: ["192.168.0.10", "10.0.0.5"], port: 1985)

    @Test("Aller-retour par l'URL, secret en base64url sans remplissage")
    func roundTrip() throws {
        let text = link.url.absoluteString
        #expect(text.hasPrefix("nacelle://pair?v=1&id=1a2b3c4d&k="))
        #expect(text.hasSuffix("&h=192.168.0.10,10.0.0.5&p=1985"))
        #expect(!text.contains("="+"&") && !text.contains("+") && !text.contains("/"+"_"))
        #expect(PairingLink(url: link.url) == link)
        #expect(PairingLink(string: "  \(text)\n") == link)
    }

    @Test("Construit depuis une invitation de ptzd")
    func fromInvitation() {
        let invitation = PairingInvitation(pairingID: link.pairingID, secret: link.secret, expiresAt: Date(), hosts: link.hosts, port: link.port)
        #expect(PairingLink(invitation) == link)
    }

    @Test("Refusés : autre schéma, autre version, champ manquant, secret de mauvaise longueur, port hors bornes, sans adresse",
          arguments: [
              "https://pair?v=1&id=1a2b&k=AAAA&h=192.168.0.10&p=1985",
              "nacelle://pair?v=2&id=1a2b3c4d&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=192.168.0.10&p=1985",
              "nacelle://pair?v=1&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=192.168.0.10&p=1985",
              "nacelle://pair?v=1&id=1a2b3c4d&k=AAAA&h=192.168.0.10&p=1985",
              "nacelle://pair?v=1&id=1a2b3c4d&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=192.168.0.10&p=70000",
              "nacelle://pair?v=1&id=1a2b3c4d&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=&p=1985",
              "nacelle://pair?v=1&id=zz&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=192.168.0.10&p=1985",
              "pas une url",
          ])
    func rejected(_ text: String) {
        #expect(PairingLink(string: text) == nil)
    }

    @Test("Adresses refusées : hors réseau local (documentation, Tailscale, publique), nom, IPv6, plus de 4",
          arguments: [
              "192.0.2.30",
              "100.64.0.1",
              "8.8.8.8",
              "mac-mini.local",
              "fe80::1",
              "192.168.0.10,10.0.0.5,172.16.0.1,169.254.0.1,192.168.0.11",
          ])
    func rejectedHosts(_ hosts: String) {
        let text = "nacelle://pair?v=1&id=1a2b3c4d&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=\(hosts)&p=1985"
        #expect(PairingLink(string: text) == nil)
    }

    @Test("4 adresses locales, auto-attribution comprise, sont acceptées")
    func fourLocalHosts() {
        let text = "nacelle://pair?v=1&id=1a2b3c4d&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=192.168.0.10,10.0.0.5,172.31.255.1,169.254.0.1&p=1985"
        #expect(PairingLink(string: text)?.hosts.count == 4)
    }

    @Test("Un secret de 32 octets en base64url (43 caractères) est accepté")
    func validMinimal() {
        let text = "nacelle://pair?v=1&id=1a2b3c4d&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=192.168.0.10&p=1985"
        #expect(PairingLink(string: text)?.secret == Data(count: 32))
    }

    @Test("Identité TLS de l'appairage")
    func identity() {
        #expect(NacelleTLS.pairingIdentity("1a2b3c4d") == "pair-1a2b3c4d")
    }
}
