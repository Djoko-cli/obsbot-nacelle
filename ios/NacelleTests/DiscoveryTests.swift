import Network
import Testing
@testable import Nacelle

/// Liste Bonjour simulée.
@MainActor
final class FakeServiceListing: ServiceListing {
    var onChange: (([String]) -> Void)?
    private(set) var isRunning = false

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func publish(_ names: [String]) {
        onChange?(names)
    }
}

@MainActor
@Suite("Recherche des Mac à proximité")
struct DiscoveryTests {
    @Test("Les Mac trouvés sont publiés ; l'arrêt coupe la recherche et vide la liste")
    func listing() {
        let listing = FakeServiceListing()
        let discovery = Discovery(listing: listing)
        discovery.start()
        #expect(listing.isRunning)
        #expect(discovery.macs.isEmpty)
        listing.publish(["PTZBot sur Mac mini"])
        #expect(discovery.macs == ["PTZBot sur Mac mini"])
        discovery.stop()
        #expect(!listing.isRunning)
        #expect(discovery.macs.isEmpty)
    }

    @Test("Noms des services : sans doublon (plusieurs interfaces), triés, autres points d'arrivée ignorés")
    func names() {
        let endpoints: [NWEndpoint] = [
            .service(name: "PTZBot sur Mac mini", type: "_nacelle._tcp", domain: "local.", interface: nil),
            .service(name: "PTZBot sur iMac", type: "_nacelle._tcp", domain: "local.", interface: nil),
            .service(name: "PTZBot sur Mac mini", type: "_nacelle._tcp", domain: "local.", interface: nil),
            .hostPort(host: "192.0.2.30", port: 1985),
        ]
        #expect(BonjourServiceList.names(endpoints) == ["PTZBot sur Mac mini", "PTZBot sur iMac"].sorted())
    }
}
