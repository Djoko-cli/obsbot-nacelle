import Foundation
import Network

/// Vérifie, côté app, que macOS autorise PTZBot (et donc ptzd, son enfant) sur le réseau local
/// (spec ptzd dans l'app § 4.2 et § 6.1) : un `NWBrowser` de courte durée sur `_nacelle._tcp`
/// signale un refus par l'erreur DNS « PolicyDenied ».
@MainActor
public final class LocalNetworkProbe {
    public nonisolated static let serviceType = "_nacelle._tcp"
    /// kDNSServiceErr_PolicyDenied.
    nonisolated static let policyDenied: Int32 = -65570
    public static let duration: TimeInterval = 2

    private var run: ProbeRun?

    public init() {}

    /// Refus si l'état du navigateur porte l'erreur « PolicyDenied » ; nil si l'état ne dit rien.
    public nonisolated static func isDenied(_ state: NWBrowser.State) -> Bool? {
        switch state {
        case let .failed(error), let .waiting(error):
            if case let .dns(code) = error {
                return code == policyDenied
            }
            return nil
        case .ready:
            return false
        case .setup, .cancelled:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Ouvre un navigateur pendant `duration` secondes ; `completion(true)` dès qu'un refus est vu,
    /// sinon `completion(false)` à la fin. Un appel en cours est remplacé (sans réponse).
    public func check(scheduler: any Scheduler, completion: @escaping @MainActor (Bool) -> Void) {
        run?.finish(nil)
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: .tcp)
        let run = ProbeRun(browser: browser, completion: completion)
        self.run = run
        browser.stateUpdateHandler = { [weak run] state in
            guard Self.isDenied(state) == true else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { run?.finish(true) }
            }
        }
        browser.start(queue: .main)
        scheduler.schedule(after: Self.duration) { [weak run] in
            run?.finish(false)
        }
    }
}

/// Une vérification : une seule réponse, puis le navigateur est fermé.
@MainActor
private final class ProbeRun {
    private var browser: NWBrowser?
    private var completion: (@MainActor (Bool) -> Void)?

    init(browser: NWBrowser, completion: @escaping @MainActor (Bool) -> Void) {
        self.browser = browser
        self.completion = completion
    }

    /// `nil` : remplacée, sans réponse.
    func finish(_ denied: Bool?) {
        browser?.cancel()
        browser = nil
        let completion = completion
        self.completion = nil
        if let denied {
            completion?(denied)
        }
    }
}
