import Testing
@testable import PTZServer

@Suite("Écoute sur le réseau local : décisions")
struct LocalNetworkListenersTests {
    @Test("Nouvelles interfaces : liées ; adresse changée ou perdue : retirée, reliée au tour suivant")
    func changes() {
        let first = LocalNetworkListeners.changes(bound: [:], wanted: ["en0": "192.0.2.43", "en18": "192.0.2.30"], cancelling: [])
        #expect(first.retire.isEmpty)
        #expect(first.bind == ["en0", "en18"])

        let moved = LocalNetworkListeners.changes(bound: ["en0": "192.0.2.43", "en18": "192.0.2.30"], wanted: ["en0": "192.0.2.44"], cancelling: [])
        #expect(moved.retire == ["en0", "en18"])
        #expect(moved.bind.isEmpty)

        let waiting = LocalNetworkListeners.changes(bound: [:], wanted: ["en0": "192.0.2.44"], cancelling: ["en0"])
        #expect(waiting.bind.isEmpty)

        let stable = LocalNetworkListeners.changes(bound: ["en0": "192.0.2.43"], wanted: ["en0": "192.0.2.43"], cancelling: [])
        #expect(stable.retire.isEmpty && stable.bind.isEmpty)

        // Une interface en échec récent est exclue comme une écoute en cours de fermeture.
        let cooling = LocalNetworkListeners.changes(bound: [:], wanted: ["en0": "192.0.2.43", "en18": "192.0.2.30"], cancelling: ["en18"])
        #expect(cooling.bind == ["en0"])
    }

    @Test("Annonce : garde son interface, sinon une filaire, sinon la première par nom")
    func serviceHolder() {
        #expect(LocalNetworkListeners.serviceHolder(current: nil, bound: [:]) == nil)
        #expect(LocalNetworkListeners.serviceHolder(current: nil, bound: ["en0": false, "en18": true]) == "en18")
        #expect(LocalNetworkListeners.serviceHolder(current: "en0", bound: ["en0": false, "en18": true]) == "en0")
        #expect(LocalNetworkListeners.serviceHolder(current: "en18", bound: ["en0": false]) == "en0")
        #expect(LocalNetworkListeners.serviceHolder(current: nil, bound: ["en1": false, "en0": false]) == "en0")
    }

    @Test("Adresse auto-attribuée 169.254.x.x : pas d'écoute")
    func usable() {
        #expect(LocalNetworkListeners.isUsable("192.0.2.30"))
        #expect(!LocalNetworkListeners.isUsable("169.254.10.2"))
    }
}
