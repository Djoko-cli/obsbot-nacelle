import Foundation
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

/// WebSocket sur NWConnection, pour joindre un service Bonjour (URLSessionWebSocketTask ne prend
/// qu'une URL). Une seule connexion à la fois ; vivacité par `Heartbeat`, comme l'autre transport.
@MainActor
final class NWWebSocketTransport: WebSocketTransport {
    var onEvent: ((TransportEvent) -> Void)?
    private let scheduler: any Scheduler
    private var connection: NWConnection?
    private var heartbeat: Heartbeat?

    init(scheduler: any Scheduler) {
        self.scheduler = scheduler
    }

    func open(_ endpoint: WebSocketEndpoint) {
        close()
        let target: NWEndpoint
        switch endpoint {
        case let .url(url):
            target = .url(url)
        case let .service(service):
            target = service
        }
        let parameters = NWParameters.tcp
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
    }

    func send(_ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "nacelle", metadata: [metadata])
        connection?.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func close() {
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
