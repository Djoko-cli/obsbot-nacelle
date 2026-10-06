import CryptoKit
import Foundation
import Network
@testable import Nacelle

/// Transport WebSocket simulé : enregistre les ouvertures et les envois ; le test déclenche les événements.
@MainActor
final class FakeTransport: WebSocketTransport {
    var onEvent: ((TransportEvent) -> Void)?
    private(set) var opened: [WebSocketEndpoint] = []
    private(set) var sent: [String] = []
    private(set) var closeCount = 0

    func open(_ endpoint: WebSocketEndpoint) {
        opened.append(endpoint)
    }

    func send(_ text: String) {
        sent.append(text)
    }

    func close() {
        closeCount += 1
    }

    func emit(_ event: TransportEvent) {
        onEvent?(event)
    }
}

/// Fabrique de transports simulés : un par connexion ouverte, dans l'ordre.
@MainActor
final class FakeTransports {
    private(set) var all: [FakeTransport] = []

    func make() -> any WebSocketTransport {
        let transport = FakeTransport()
        all.append(transport)
        return transport
    }

    var last: FakeTransport? {
        all.last
    }

    /// Le transport ouvert vers cette destination le plus récemment.
    func to(_ endpoint: WebSocketEndpoint) -> FakeTransport? {
        all.last { $0.opened == [endpoint] }
    }

    /// Le dernier transport ouvert vers un service du réseau local.
    var local: FakeTransport? {
        all.last { transport in
            transport.opened.contains { if case .service = $0 { true } else { false } }
        }
    }
}

/// Bonjour simulé.
@MainActor
final class FakeBrowser: ServiceBrowser {
    var onFound: ((NWEndpoint) -> Void)?
    private(set) var isRunning = false
    private(set) var startCount = 0

    func start() {
        isRunning = true
        startCount += 1
    }

    func stop() {
        isRunning = false
    }

    func find(_ endpoint: NWEndpoint) {
        onFound?(endpoint)
    }
}

/// Clé logicielle en mémoire.
@MainActor
final class FakeKeyStore: DeviceKeyStoring {
    var key: (any DeviceKey)?
    private(set) var createCount = 0

    func load() -> (any DeviceKey)? {
        key
    }

    func loadOrCreate() throws -> any DeviceKey {
        if let key {
            return key
        }
        createCount += 1
        let created = SoftwareDeviceKey(key: P256.Signing.PrivateKey())
        key = created
        return created
    }

    var storedLANKey: Data?

    func delete() {
        key = nil
        storedLANKey = nil
    }

    func lanKey() -> Data? {
        storedLANKey
    }

    func saveLANKey(_ key: Data) throws {
        storedLANKey = key
    }
}
