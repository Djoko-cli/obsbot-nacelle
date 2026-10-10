import Foundation
import NacelleProtocol
import Network

/// Recherche Bonjour de ptzd sur le réseau local (spec accès local § 8.3).
@MainActor
final class BonjourServiceBrowser: ServiceBrowser {
    static let type = "_nacelle._tcp"

    var onFound: ((NWEndpoint) -> Void)?
    private var browser: NWBrowser?

    func start() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: Self.type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser, let first = results.first else { return }
                self.onFound?(first.endpoint)
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// WebSocket sur NWConnection, pour joindre le réseau local en TLS à clé pré-partagée (URLSessionWebSocketTask
/// ne fait pas ce TLS). Une seule connexion à la fois ; vivacité par `Heartbeat`, comme l'autre transport.
@MainActor
final class NWWebSocketTransport: WebSocketTransport {
    /// Délai d'ouverture, comme `URLSessionWebSocketTransport.openTimeout`.
    static let openTimeout: TimeInterval = 10

    var onEvent: ((TransportEvent) -> Void)?
    private(set) var remoteAddress: String?
    private let scheduler: any Scheduler
    private var connection: NWConnection?
    private var heartbeat: Heartbeat?
    private var openDeadline: (any Cancellable)?

    init(scheduler: any Scheduler) {
        self.scheduler = scheduler
    }

    func open(_ endpoint: WebSocketEndpoint) {
        close()
        let target: NWEndpoint
        let tls: NWProtocolTLS.Options?
        switch endpoint {
        case let .url(url):
            target = .url(url)
            tls = nil
        case let .tls(service, credentials):
            target = service
            tls = NacelleTLS.client(identity: credentials.identity, key: credentials.key)
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let connection = NWConnection(to: target, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, connection === self.connection else { return }
                switch state {
                case .ready:
                    self.openDeadline?.cancel()
                    self.openDeadline = nil
                    self.remoteAddress = connection.currentPath?.remoteEndpoint.flatMap(Self.ipv4)
                    self.startHeartbeat(for: connection)
                    self.onEvent?(.opened)
                case .failed, .cancelled, .waiting:
                    // En attente = pas de chemin : la course passe par Tailscale ou réessaie plus tard.
                    self.finish(connection)
                default:
                    break
                }
            }
        }
        receive(on: connection)
        connection.start(queue: .main)
        // Une connexion pas prête à l'échéance (résultat Bonjour périmé) est fermée.
        openDeadline = scheduler.schedule(after: Self.openTimeout) { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.finish(connection)
        }
    }

    func send(_ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "nacelle", metadata: [metadata])
        connection?.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func sendVoice(_ frame: Data, completion: @escaping @MainActor () -> Void) {
        guard let connection else {
            completion()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "voice", metadata: [metadata])
        connection.send(content: frame, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            Task { @MainActor in completion() }
        })
    }

    /// L'adresse IPv4 d'un point d'arrivée résolu, sans zone ; nil pour IPv6 ou un nom.
    nonisolated static func ipv4(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(.ipv4(address), _) = endpoint else { return nil }
        return address.rawValue.map(String.init).joined(separator: ".")
    }

    func close() {
        remoteAddress = nil
        openDeadline?.cancel()
        openDeadline = nil
        heartbeat?.stop()
        heartbeat = nil
        connection?.cancel()
        connection = nil
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self, connection === self.connection else { return }
                if error != nil || context?.isFinal == true {
                    self.finish(connection)
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close {
                    self.finish(connection)
                    return
                }
                if metadata?.opcode == .text, let content, let text = String(data: content, encoding: .utf8) {
                    self.onEvent?(.message(text))
                }
                self.receive(on: connection)
            }
        }
    }

    /// Signale la fin d'une connexion, une seule fois.
    private func finish(_ connection: NWConnection) {
        guard connection === self.connection else { return }
        openDeadline?.cancel()
        openDeadline = nil
        heartbeat?.stop()
        heartbeat = nil
        self.connection = nil
        connection.cancel()
        onEvent?(.closed)
    }

    private func startHeartbeat(for connection: NWConnection) {
        let heartbeat = Heartbeat(
            scheduler: scheduler,
            ping: { reply in
                let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
                metadata.setPongHandler(.main) { error in
                    MainActor.assumeIsolated { reply(error == nil) }
                }
                let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
                connection.send(content: Data(), contentContext: context, isComplete: true, completion: .idempotent)
            },
            onLost: { [weak self] in
                self?.finish(connection)
            }
        )
        self.heartbeat = heartbeat
        heartbeat.start()
    }
}
