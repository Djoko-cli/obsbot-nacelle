import Darwin
import Foundation
import Network
import PTZCore

/// Écoute sur le réseau local (spec accès local § 6.1 et § 6.2) : une écoute par interface Wi-Fi ou
/// Ethernet filaire, liée à l'interface ET à son adresse IPv4 (jamais aux VPN, aux ponts de machines
/// virtuelles ni à la boucle locale), qui suit les changements d'adresse ; une seule annonce Bonjour.
/// Vérifié sur macOS 27 : sans `allowLocalEndpointReuse`, la deuxième écoute sur le même port échoue
/// (EADDRINUSE) ; une écoute liée à l'interface seule ou par types d'interface s'ouvre trop largement.
@MainActor
final class LocalNetworkListeners {
    /// Filet de sécurité : un changement d'adresse DHCP ne déclenche pas toujours le moniteur de chemin.
    static let reconcileInterval: TimeInterval = 30
    static let serviceName = "Nacelle"
    static let serviceType = "_nacelle._tcp"

    private struct Bound {
        let address: String
        let isWired: Bool
        let listener: NWListener
    }

    private let port: NWEndpoint.Port
    private let makeParameters: () -> NWParameters
    private let onConnection: (NWConnection) -> Void
    private let scheduler: any Scheduler
    private let log: LogSink
    private let monitor = NWPathMonitor()
    private var interfaces: [NWInterface] = []
    private var bound: [String: Bound] = [:]
    /// Interfaces dont l'écoute se ferme : la même adresse et le même port ne se relient qu'après `.cancelled`.
    private var cancelling: Set<String> = []
    private var serviceHolder: String?
    private var timer: (any Cancellable)?

    init(port: UInt16, makeParameters: @escaping () -> NWParameters, onConnection: @escaping (NWConnection) -> Void, scheduler: any Scheduler, log: @escaping LogSink) {
        self.port = NWEndpoint.Port(rawValue: port) ?? .any
        self.makeParameters = makeParameters
        self.onConnection = onConnection
        self.scheduler = scheduler
        self.log = log
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self else { return }
                var seen = Set<String>()
                self.interfaces = path.availableInterfaces.filter {
                    ($0.type == .wifi || $0.type == .wiredEthernet) && seen.insert($0.name).inserted
                }
                self.reconcile()
            }
        }
        monitor.start(queue: .main)
        scheduleReconcile()
    }

    private func scheduleReconcile() {
        timer = scheduler.schedule(after: Self.reconcileInterval) { [weak self] in
            self?.reconcile()
            self?.scheduleReconcile()
        }
    }

    private func reconcile() {
        var wanted: [String: String] = [:]
        for interface in interfaces {
            if let address = Self.ipv4(of: interface.name), Self.isUsable(address) {
                wanted[interface.name] = address
            }
        }
        let changes = Self.changes(bound: bound.mapValues(\.address), wanted: wanted, cancelling: cancelling)
        for name in changes.retire {
            log("Écoute locale sur \(name) retirée (adresse changée ou perdue).")
            retire(name)
        }
        for name in changes.bind {
            guard let interface = interfaces.first(where: { $0.name == name }), let address = wanted[name] else { continue }
            bind(interface, address: address)
        }
        assignService()
    }

    /// Ce qu'il faut défaire puis faire pour passer des écoutes actuelles aux interfaces voulues.
    nonisolated static func changes(bound: [String: String], wanted: [String: String], cancelling: Set<String>) -> (retire: [String], bind: [String]) {
        let retire = bound.filter { wanted[$0.key] != $0.value }.keys.sorted()
        // Une interface retirée se relie après `.cancelled`, au tour suivant.
        let bind = wanted.keys.filter { bound[$0] == nil && !cancelling.contains($0) }.sorted()
        return (retire, bind)
    }

    /// L'interface qui porte l'annonce : celle qui la porte déjà si elle écoute encore,
    /// sinon une filaire, sinon la première par nom.
    nonisolated static func serviceHolder(current: String?, bound: [String: Bool]) -> String? {
        if let current, bound[current] != nil {
            return current
        }
        return bound.sorted { ($0.value ? 0 : 1, $0.key) < ($1.value ? 0 : 1, $1.key) }.first?.key
    }

    /// Une adresse IPv4 attribuée par le réseau (pas l'auto-attribution 169.254.0.0/16).
    nonisolated static func isUsable(_ address: String) -> Bool {
        !address.hasPrefix("169.254.")
    }

    private func bind(_ interface: NWInterface, address: String) {
        let parameters = makeParameters()
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterface = interface
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
        let name = interface.name
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            log("Écoute locale sur \(name) impossible (\(error)).")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.onConnection(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.bound[name]?.listener === listener else { return }
                switch state {
                case .ready:
                    self.log("Écoute locale sur \(name) (\(address)):\(self.port).")
                case let .failed(error), let .waiting(error):
                    self.log("Écoute locale sur \(name) en échec (\(error)).")
                    self.retire(name)
                default:
                    break
                }
            }
        }
        bound[name] = Bound(address: address, isWired: interface.type == .wiredEthernet, listener: listener)
        listener.start(queue: .main)
    }

    private func retire(_ name: String) {
        guard let entry = bound.removeValue(forKey: name) else { return }
        if serviceHolder == name {
            entry.listener.service = nil
            serviceHolder = nil
        }
        cancelling.insert(name)
        entry.listener.stateUpdateHandler = { [weak self] state in
            guard case .cancelled = state else { return }
            MainActor.assumeIsolated {
                self?.cancelling.remove(name)
                self?.reconcile()
            }
        }
        entry.listener.cancel()
    }

    private func assignService() {
        let holder = Self.serviceHolder(current: serviceHolder, bound: bound.mapValues(\.isWired))
        guard holder != serviceHolder else { return }
        if let old = serviceHolder {
            bound[old]?.listener.service = nil
        }
        serviceHolder = holder
        guard let holder, let listener = bound[holder]?.listener else { return }
        var txt = NWTXTRecord()
        txt["v"] = "1"
        listener.service = NWListener.Service(name: Self.serviceName, type: Self.serviceType, txtRecord: txt)
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            MainActor.assumeIsolated {
                if case .add = change {
                    self?.log("Annonce Bonjour \(Self.serviceType) sur \(holder).")
                }
            }
        }
    }

    /// Première adresse IPv4 de l'interface, ou nil.
    nonisolated static func ipv4(of name: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(first) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = current {
            let entry = pointer.pointee
            if let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), String(cString: entry.ifa_name) == name {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            current = entry.ifa_next
        }
        return nil
    }
}
