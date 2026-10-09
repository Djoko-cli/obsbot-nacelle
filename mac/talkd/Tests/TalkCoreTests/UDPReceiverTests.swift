import Foundation
import Synchronization
import Testing
@testable import TalkCore

/// Les datagrammes reçus, remplis depuis la file du récepteur.
final class Inbox: Sendable {
    private let packets = Mutex<[Datagram]>([])

    func add(_ datagram: Datagram) {
        packets.withLock { $0.append(datagram) }
    }

    var all: [Datagram] {
        packets.withLock { $0 }
    }
}

/// Une socket UDP non bloquante sur 127.0.0.1, au port attribué par le système, sans source de lecture : les tests
/// appellent `UDPReceiver.drain` eux-mêmes.
func boundLoopbackSocket() throws -> (descriptor: Int32, port: UInt16) {
    let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
    try #require(descriptor >= 0)
    _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(bound == 0)
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    return (descriptor, UInt16(bigEndian: actual.sin_port))
}

/// Envoie un datagramme UDP vers 127.0.0.1:`port` ; rend l'erreur de `sendto`, 0 si tout va bien.
@discardableResult
func sendUDP(_ data: Data, toPort port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return errno }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    let sent = data.withUnsafeBytes { raw in
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    return sent >= 0 ? 0 : errno
}

/// Attend que `condition` devienne vraie, au plus `seconds` : aucune attente sans borne.
@MainActor
func waitUntil(timeout seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@MainActor
@Suite("Réception UDP", .timeLimit(.minutes(1)))
struct UDPReceiverTests {
    @Test("Port 0 : le système attribue un port libre, et les paquets de 127.0.0.1 arrivent avec leur adresse source")
    func receivesFromLoopback() async throws {
        let inbox = Inbox()
        let receiver = UDPReceiver(queue: DispatchQueue(label: "talkd.tests.udp"))
        let port = try receiver.start(port: 0) { inbox.add($0) }
        defer { receiver.stop() }
        #expect(port != 0)
        #expect(sendUDP(pcm(1234), toPort: port) == 0)
        #expect(sendUDP(Data(), toPort: port) == 0)
        #expect(await waitUntil { inbox.all.count == 2 })
        let received = inbox.all
        #expect(received.map(\.source) == ["127.0.0.1", "127.0.0.1"])
        #expect(received.map(\.size).sorted() == [0, 640])
        #expect(received.first { $0.size == 640 }?.payload == pcm(1234))
    }

    @Test("Un gros datagramme (plus de 4 Ko) n'est pas copié : seule sa taille réelle est remise, pour le filtre")
    func largeNotCopied() async throws {
        let inbox = Inbox()
        let receiver = UDPReceiver(queue: DispatchQueue(label: "talkd.tests.udp"))
        let port = try receiver.start(port: 0) { inbox.add($0) }
        defer { receiver.stop() }
        #expect(sendUDP(Data(count: 9000), toPort: port) == 0)
        #expect(sendUDP(Data(count: 4096), toPort: port) == 0)
        #expect(await waitUntil { inbox.all.count == 2 })
        let large = inbox.all.first { $0.size == 9000 }
        #expect(large != nil)
        #expect(large?.payload == nil)
        #expect(inbox.all.first { $0.size == 4096 }?.payload?.count == 4096)
    }

    @Test("Au plus 64 datagrammes par réveil : 200 en attente se lisent en 64, 64, 64 puis 8")
    func limitPerWake() throws {
        let (descriptor, port) = try boundLoopbackSocket()
        defer { close(descriptor) }
        for index in 0..<200 {
            #expect(sendUDP(pcm(Int16(index), samples: 1), toPort: port) == 0)
        }
        let inbox = Inbox()
        var reads: [Int] = []
        for _ in 0..<6 {
            reads.append(UDPReceiver.drain(descriptor) { inbox.add($0) })
        }
        #expect(UDPReceiver.maxPerWake == 64)
        #expect(reads == [64, 64, 64, 8, 0, 0])
        #expect(inbox.all.count == 200)
    }

    @Test("Sous un flot continu, les 200 datagrammes arrivent tous, au fil de plusieurs réveils de la source")
    func floodDelivered() async throws {
        let inbox = Inbox()
        let receiver = UDPReceiver(queue: DispatchQueue(label: "talkd.tests.udp-flood"))
        let port = try receiver.start(port: 0) { inbox.add($0) }
        defer { receiver.stop() }
        for index in 0..<200 {
            sendUDP(pcm(Int16(index), samples: 1), toPort: port)
        }
        #expect(await waitUntil(timeout: 3) { inbox.all.count == 200 })
    }

    @Test("Port déjà occupé : erreur claire, sans rien ouvrir")
    func addressInUse() async throws {
        let first = UDPReceiver(queue: DispatchQueue(label: "talkd.tests.udp1"))
        let port = try first.start(port: 0) { _ in }
        defer { first.stop() }
        let second = UDPReceiver(queue: DispatchQueue(label: "talkd.tests.udp2"))
        #expect(throws: UDPReceiver.Failure.addressInUse(port)) {
            try second.start(port: port) { _ in }
        }
    }

    @Test("Après stop(), plus rien n'est remis, et le port se libère")
    func stops() async throws {
        let inbox = Inbox()
        let receiver = UDPReceiver(queue: DispatchQueue(label: "talkd.tests.udp"))
        let port = try receiver.start(port: 0) { inbox.add($0) }
        receiver.stop()
        sendUDP(pcm(1), toPort: port)
        try await Task.sleep(for: .milliseconds(100))
        #expect(inbox.all.isEmpty)
        // Le port est de nouveau libre.
        let again = UDPReceiver(queue: DispatchQueue(label: "talkd.tests.udp3"))
        _ = try again.start(port: port) { _ in }
        again.stop()
    }

    @Test("Un récepteur démarré deux fois sans arrêt : refusé")
    func startTwice() throws {
        let receiver = UDPReceiver(queue: DispatchQueue(label: "talkd.tests.udp"))
        _ = try receiver.start(port: 0) { _ in }
        defer { receiver.stop() }
        #expect(throws: UDPReceiver.Failure.alreadyStarted) {
            try receiver.start(port: 0) { _ in }
        }
    }

    @Test("De bout en bout, sans son : un paquet UDP de voix depuis 127.0.0.1 ouvre une prise de parole, un paquet d'une source non autorisée est refusé")
    func endToEnd() async throws {
        let rig = Rig(settings: TalkSettings(port: 0, allowedSources: ["192.0.2.10"]))
        // 127.0.0.1 n'est pas dans la liste de ce talkd : son paquet est refusé.
        let receiver = UDPReceiver(queue: DispatchQueue(label: "talkd.tests.udp"))
        let controller = rig.controller
        let port = try receiver.start(port: 0) { datagram in
            Task { @MainActor in controller.receive(datagram) }
        }
        defer { receiver.stop() }
        #expect(sendUDP(voice, toPort: port) == 0)
        #expect(await waitUntil { controller.counters.rejectedSource == 1 })
        #expect(rig.output.startAttempts == 0)

        let open = Rig(settings: TalkSettings(port: 0, allowedSources: ["127.0.0.1"]))
        let openController = open.controller
        let second = UDPReceiver(queue: DispatchQueue(label: "talkd.tests.udp-open"))
        let openPort = try second.start(port: 0) { datagram in
            Task { @MainActor in openController.receive(datagram) }
        }
        defer { second.stop() }
        for _ in 0..<4 { sendUDP(voice, toPort: openPort) }
        #expect(await waitUntil { openController.isSpeaking })
        #expect(open.output.starts == [41])
    }
}
