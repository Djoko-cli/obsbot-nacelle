import Foundation
import Testing
@testable import TalkCore

@Suite("Filtre des paquets")
struct PacketFilterTests {
    private let filter = PacketFilter(allowedSources: ["127.0.0.1", "192.0.2.10"])

    @Test("Source autorisée, taille paire de 1 octet à 4 Ko : accepté")
    func accepted() {
        #expect(filter.verdict(size: 640, from: "127.0.0.1") == .accepted)
        #expect(filter.verdict(size: 640, from: "192.0.2.10") == .accepted)
        #expect(filter.verdict(size: 2, from: "127.0.0.1") == .accepted)
        #expect(filter.verdict(size: 4096, from: "127.0.0.1") == .accepted)
    }

    @Test("Source absente de la liste : refusée")
    func unauthorized() {
        #expect(filter.verdict(size: 640, from: "192.0.2.99") == .unauthorizedSource)
        #expect(filter.verdict(size: 640, from: "10.0.0.5") == .unauthorizedSource)
    }

    @Test("Paquet vide, de taille impaire ou de plus de 4 Ko : refusé")
    func badSize() {
        #expect(filter.verdict(size: 0, from: "127.0.0.1") == .badSize)
        #expect(filter.verdict(size: 641, from: "127.0.0.1") == .badSize)
        #expect(filter.verdict(size: 1, from: "127.0.0.1") == .badSize)
        #expect(filter.verdict(size: 4098, from: "127.0.0.1") == .badSize)
    }

    @Test("La source est jugée avant la taille")
    func sourceFirst() {
        #expect(filter.verdict(size: 0, from: "192.0.2.99") == .unauthorizedSource)
    }
}
