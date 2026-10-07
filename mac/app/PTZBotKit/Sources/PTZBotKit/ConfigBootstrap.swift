import Foundation

/// Une adresse IPv4 et son interface (« utun4 », « en0 »…).
public struct InterfaceAddress: Equatable, Sendable {
    public var interface: String
    public var address: String

    public init(interface: String, address: String) {
        self.interface = interface
        self.address = address
    }
}

/// Les adresses IPv4 des interfaces du Mac, derrière un protocole pour les tests.
public protocol InterfaceAddressProvider: Sendable {
    func ipv4Addresses() -> [InterfaceAddress]
}

/// Implémentation réelle : `getifaddrs`.
public struct SystemInterfaceAddresses: InterfaceAddressProvider {
    public init() {}

    public func ipv4Addresses() -> [InterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [InterfaceAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append(InterfaceAddress(interface: String(cString: entry.pointee.ifa_name), address: text))
        }
        return result
    }
}

/// Premier lancement sur un Mac neuf : crée `config.json` s'il manque (spec ptzd dans l'app § 5.5).
public enum ConfigBootstrap {
    public enum Outcome: Equatable, Sendable {
        /// `config.json` existait : rien n'est changé.
        case existing
        /// Créé avec l'adresse Tailscale.
        case created(listenAddress: String)
        /// Créé sur 127.0.0.1 seulement : pas d'interface Tailscale.
        case tailscaleMissing
    }

    public static let loopback = "127.0.0.1"

    /// 100.64.0.0/10, la plage de Tailscale.
    public static func isTailscale(_ text: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return false }
        return UInt32(bigEndian: address.s_addr) & 0xFFC0_0000 == 0x6440_0000
    }

    /// L'adresse 100.64/10 d'une interface `utun*` (Tailscale), sinon celle d'une autre interface.
    public static func tailscaleAddress(in interfaces: [InterfaceAddress]) -> String? {
        let candidates = interfaces.filter { isTailscale($0.address) }
        return (candidates.first { $0.interface.hasPrefix("utun") } ?? candidates.first)?.address
    }

    public static func run(configURL: URL, addresses: any InterfaceAddressProvider) throws -> Outcome {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: configURL.path) else { return .existing }
        let tailscale = tailscaleAddress(in: addresses.ipv4Addresses())
        let listenAddress = tailscale ?? loopback
        try manager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\n  \"listenAddress\": \"\(listenAddress)\"\n}\n".utf8).write(to: configURL, options: .withoutOverwriting)
        return tailscale.map { .created(listenAddress: $0) } ?? .tailscaleMissing
    }
}
