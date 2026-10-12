import Foundation

public enum PortTransport: Sendable {
    case tcp
    case udp
}

/// Un port est-il libre ? (Spec B3 § 5 : essai d'ouverture juste avant le lancement.) Derrière un protocole pour les
/// tests.
public protocol PortProbe: Sendable {
    /// `loopbackOnly` : 127.0.0.1 seulement (l'API de go2rtc) ; sinon toutes les adresses, IPv4 et IPv6.
    func isFree(_ port: Int, transport: PortTransport, loopbackOnly: Bool) -> Bool
}

/// Le vrai essai : une socket ouverte sans `SO_REUSEADDR`, refusée si un autre programme tient déjà le port, et
/// refermée aussitôt.
public struct SystemPortProbe: PortProbe {
    public init() {}

    public func isFree(_ port: Int, transport: PortTransport, loopbackOnly: Bool) -> Bool {
        let type = transport == .tcp ? SOCK_STREAM : SOCK_DGRAM
        if loopbackOnly {
            return Self.bindIPv4(port, type: type, address: 0x7F00_0001)
        }
        return Self.bindIPv4(port, type: type, address: 0) && Self.bindIPv6(port, type: type)
    }

    static func bindIPv4(_ port: Int, type: Int32, address: UInt32) -> Bool {
        let descriptor = socket(AF_INET, type, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = in_port_t(UInt16(port).bigEndian)
        socketAddress.sin_addr = in_addr(s_addr: address.bigEndian)
        return withUnsafePointer(to: socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// En IPv6 seul (`IPV6_V6ONLY`) : l'IPv4 est essayé à part. Sans IPv6 sur le Mac, rien à vérifier de ce côté.
    static func bindIPv6(_ port: Int, type: Int32) -> Bool {
        let descriptor = socket(AF_INET6, type, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        var only: Int32 = 1
        _ = setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
        var socketAddress = sockaddr_in6()
        socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        socketAddress.sin6_family = sa_family_t(AF_INET6)
        socketAddress.sin6_port = in_port_t(UInt16(port).bigEndian)
        socketAddress.sin6_addr = in6_addr()
        return withUnsafePointer(to: socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }
}
