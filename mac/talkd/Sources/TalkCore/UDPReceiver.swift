import Foundation

/// Un datagramme reçu : son contenu, sa taille réelle et l'adresse IPv4 de sa source.
public struct Datagram: Equatable, Sendable {
    /// nil quand il dépasse `UDPReceiver.maxCopiedSize` : il n'est pas copié, le filtre le compte d'après `size`.
    public var payload: Data?
    public var size: Int
    public var source: String

    public init(payload: Data?, size: Int, source: String) {
        self.payload = payload
        self.size = size
        self.source = source
    }

    public init(_ payload: Data, from source: String) {
        self.init(payload: payload, size: payload.count, source: source)
    }
}

/// La réception UDP (spec haut-parleur § 5.2) : une socket IPv4 sur toutes les interfaces, au port donné. Elle remet
/// chaque datagramme avec l'adresse IPv4 de sa source, sur la file `queue` (la file principale dans le daemon), et
/// ne répond jamais.
///
/// Le récepteur ne connaît ni le filtre ni la lecture : le daemon relie `handler` à `TalkController.receive`, et les
/// tests y mettent ce qu'ils veulent. Un port occupé est une erreur claire (`Failure.addressInUse`), jamais une boucle
/// de tentatives.
///
/// Contre un flot continu, d'où qu'il vienne (relecture I5) : au plus `maxPerWake` datagrammes par réveil de la source
/// de lecture, qui se redéclenche tant qu'il reste des données ; la file principale garde la main entre deux réveils
/// (minuteries de fin de parole, volume, SIGTERM). Un datagramme de plus de 4 Ko n'est pas copié.
@MainActor
public final class UDPReceiver {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case addressInUse(UInt16)
        case alreadyStarted
        case socket(String, Int32)

        public var description: String {
            switch self {
            case let .addressInUse(port): "le port UDP \(port) est déjà utilisé"
            case .alreadyStarted: "le récepteur est déjà démarré"
            case let .socket(call, code): "\(call) a échoué : \(String(cString: strerror(code)))"
            }
        }
    }

    /// Un datagramme UDP ne dépasse pas 65 507 octets : aucun n'est tronqué, et sa taille réelle est connue.
    private nonisolated static let receiveSize = 65536
    /// Au plus autant de datagrammes lus par réveil de la source.
    public nonisolated static let maxPerWake = 64
    /// Au-delà, le contenu n'est pas copié (le filtre refuse de toute façon plus de 4 Ko).
    public nonisolated static let maxCopiedSize = PacketFilter.maxPacketSize

    private let queue: DispatchQueue
    private var source: (any DispatchSourceRead)?

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    /// Ouvre le port (0 : le système en attribue un libre) et rend le port effectif.
    public func start(port: UInt16, handler: @escaping @Sendable (Datagram) -> Void) throws(Failure) -> UInt16 {
        guard source == nil else { throw .alreadyStarted }
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw .socket("socket", errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            let code = errno
            close(descriptor)
            throw .socket("fcntl", code)
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw code == EADDRINUSE ? .addressInUse(port) : .socket("bind", code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            let code = errno
            close(descriptor)
            throw .socket("getsockname", code)
        }

        let reader = Self.makeSource(descriptor, queue: queue, handler: handler)
        source = reader
        reader.resume()
        return UInt16(bigEndian: actual.sin_port)
    }

    /// Ferme la socket ; plus aucun datagramme n'est remis ensuite.
    public func stop() {
        source?.cancel()
        source = nil
    }

    /// La source de lecture, construite hors de l'acteur principal : ses blocs tournent sur `queue`, pas sur lui.
    private nonisolated static func makeSource(
        _ descriptor: Int32,
        queue: DispatchQueue,
        handler: @escaping @Sendable (Datagram) -> Void
    ) -> any DispatchSourceRead {
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setEventHandler {
            drain(descriptor, handler)
        }
        reader.setCancelHandler {
            close(descriptor)
        }
        return reader
    }

    /// Lit au plus `limit` datagrammes en attente, et rend le nombre lu. La source de lecture rappelle tant qu'il en
    /// reste.
    @discardableResult
    nonisolated static func drain(
        _ descriptor: Int32,
        limit: Int = maxPerWake,
        _ handler: @Sendable (Datagram) -> Void
    ) -> Int {
        withUnsafeTemporaryAllocation(byteCount: receiveSize, alignment: 1) { buffer in
            var read = 0
            while read < limit {
                var sender = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(descriptor, buffer.baseAddress, receiveSize, 0, $0, &length)
                    }
                }
                guard count >= 0 else { break }
                read += 1
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var network = sender.sin_addr
                guard inet_ntop(AF_INET, &network, &text, socklen_t(text.count)) != nil else { continue }
                let end = text.firstIndex(of: 0) ?? text.endIndex
                let source = String(decoding: text[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let payload = count <= maxCopiedSize ? Data(bytes: buffer.baseAddress!, count: count) : nil
                handler(Datagram(payload: payload, size: count, source: source))
            }
            return read
        }
    }
}
