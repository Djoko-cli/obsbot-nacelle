import Foundation
import Network
import Observation

/// Les services `_nacelle._tcp` du réseau local, par nom, pour l'écran d'appairage. Les résultats
/// arrivent sur le MainActor.
@MainActor
protocol ServiceListing: AnyObject {
    var onChange: (([String]) -> Void)? { get set }
    func start()
    func stop()
}

/// Recherche des Mac à proximité (spec découverte et QR § 8.1). La première recherche déclenche la
/// demande d'accès au réseau local d'iOS.
@MainActor
@Observable
final class Discovery {
    /// Noms des services trouvés (« PTZBot sur <nom du Mac> »), triés.
    private(set) var macs: [String] = []
    @ObservationIgnored private let listing: any ServiceListing

    init(listing: any ServiceListing) {
        self.listing = listing
        listing.onChange = { [weak self] names in
            self?.macs = names
        }
    }

    func start() {
        listing.start()
    }

    func stop() {
        listing.stop()
        macs = []
    }
}

/// `ServiceListing` sur NWBrowser.
@MainActor
final class BonjourServiceList: ServiceListing {
    var onChange: (([String]) -> Void)?
    private var browser: NWBrowser?

    func start() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: BonjourServiceBrowser.type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                self.onChange?(Self.names(results.map(\.endpoint)))
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Noms des services, sans doublon (un même Mac annoncé sur plusieurs interfaces), triés.
    nonisolated static func names(_ endpoints: [NWEndpoint]) -> [String] {
        Set(endpoints.compactMap { endpoint in
            if case let .service(name, _, _, _) = endpoint { name } else { nil }
        }).sorted()
    }
}
