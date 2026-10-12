import Foundation

public enum PortTransport: Sendable {
    case tcp
    case udp
}

/// Un port est-il libre ? (Spec B3 § 5 : essai d'ouverture juste avant le lancement.) Derrière un protocole pour les
/// tests.
public protocol PortProbe: Sendable {
    /// `loopbackOnly` : l'API de go2rtc, qui n'écoute qu'en 127.0.0.1 ; sinon toutes les adresses, IPv4 et IPv6.
    func isFree(_ port: Int, transport: PortTransport, loopbackOnly: Bool) -> Bool
}

/// Le vrai essai : une socket ouverte avec `SO_REUSEADDR`, comme celles de go2rtc (Go), refusée si un autre programme
/// tient déjà le port, et refermée aussitôt. Avec `SO_REUSEADDR`, les connexions en TIME_WAIT que go2rtc laisse sur ses
/// ports à sa sortie (30 s) ne comptent pas : sans lui, un relancement rapide, après « Quitter » ou « Appliquer »,
/// verrait à tort le port pris. En revanche, le joker (0.0.0.0) ne voit plus un serveur qui n'écoute qu'en 127.0.0.1 :
/// cette adresse est essayée à part.
public struct SystemPortProbe: PortProbe {
    public init() {}

    public func isFree(_ port: Int, transport: PortTransport, loopbackOnly: Bool) -> Bool {
        let type = transport == .tcp ? SOCK_STREAM : SOCK_DGRAM
        let ipv4Free = Self.bindIPv4(port, type: type, address: 0x7F00_0001) && Self.bindIPv4(port, type: type, address: 0)
        if loopbackOnly {
            return ipv4Free
        }
        return ipv4Free && Self.bindIPv6(port, type: type)
    }

    /// `SO_REUSEADDR` : un port qui n'a plus que des connexions en TIME_WAIT est libre.
    private static func allowReuse(_ descriptor: Int32) {
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func bindIPv4(_ port: Int, type: Int32, address: UInt32) -> Bool {
        let descriptor = socket(AF_INET, type, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        allowReuse(descriptor)
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
        allowReuse(descriptor)
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
