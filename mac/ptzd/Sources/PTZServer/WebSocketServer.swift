import Foundation
import NacelleProtocol
import Network
import PTZCore

/// Serveur WebSocket de ptzd : quelques adresses précises (jamais 0.0.0.0),
/// 4 clients au plus en tout (spec § 6.1 et § 6.10).
@MainActor
public final class WebSocketServer {
    public static let maxClients = 4
    public static let retryDelay: TimeInterval = 5
    /// Marque une poignée de main refusée. Network n'envoie alors aucune réponse, garde la
    /// connexion ouverte et la signale même prête (constaté avec le SDK de macOS 27) : on
    /// retrouve la marque dans ses métadonnées pour la fermer nous-mêmes.
    nonisolated static let rejectionMarker = (name: "X-Nacelle-Refus", value: "origin")

    /// Appelé quand l'écoute sur une adresse est prête, avec le port réellement
    /// ouvert (utile quand on demande le port 0).
    public var onReady: ((_ host: String, _ port: UInt16) -> Void)?

    private let hosts: [String]
    private let port: UInt16
    private let controller: PTZController
    private let scheduler: any Scheduler
    private let log: LogSink
    private var listeners: [String: NWListener] = [:]
    private var connections: [ClientID: NWConnection] = [:]
    private var nextID: ClientID = 1

    /// Les adresses en double ne sont écoutées qu'une fois (config.json peut déjà contenir 127.0.0.1).
    public init(hosts: [String], port: UInt16, controller: PTZController, scheduler: any Scheduler, log: @escaping LogSink) {
        self.hosts = hosts.reduce(into: []) { unique, host in
            if !unique.contains(host) {
                unique.append(host)
            }
        }
        self.port = port
        self.controller = controller
        self.scheduler = scheduler
        self.log = log
        controller.onStateChange = { [weak self] snapshot in
            self?.broadcast(.state(snapshot))
        }
    }

    /// Ouvre l'écoute sur chaque adresse. En cas d'échec (adresse Tailscale pas
    /// encore là), réessaie toutes les 5 s pour cette adresse.
    public func start() {
        for host in hosts {
            listen(on: host)
        }
    }

    private func listen(on host: String) {
        // Keepalive TCP : une connexion morte (iPhone suspendu, réseau coupé) est fermée
        // après environ 25 s au lieu de garder une des 4 places indéfiniment.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        // Un navigateur envoie toujours Origin, nos clients (app iOS, nacelle-ws) jamais :
        // une page web ouverte sur le Mac ou le tailnet ne peut donc pas piloter la caméra.
        webSocket.setClientRequestHandler(.main) { [weak self] _, headers in
            guard headers.contains(where: { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }) else {
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
            MainActor.assumeIsolated { self?.log("Connexion refusée : en-tête Origin (navigateur).") }
            return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: [Self.rejectionMarker])
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            retryLater(host, after: error)
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(host, state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listeners[host] = listener
        listener.start(queue: .main)
    }

    private func listenerChanged(_ host: String, _ state: NWListener.State) {
        switch state {
        case .ready:
            let actual = listeners[host]?.port?.rawValue ?? port
            log("En écoute sur \(host):\(actual).")
            onReady?(host, actual)
        case let .failed(error), let .waiting(error):
            listeners.removeValue(forKey: host)?.cancel()
            retryLater(host, after: error)
        default:
            break
        }
    }

    private func retryLater(_ host: String, after error: any Error) {
        log("Écoute sur \(host):\(port) impossible (\(error)). Nouvel essai dans 5 s.")
        scheduler.schedule(after: Self.retryDelay) { [weak self] in
            self?.listen(on: host)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxClients else {
            log("Connexion refusée : déjà \(Self.maxClients) clients.")
            connection.cancel()
            return
        }
        let id = nextID
        nextID += 1
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connectionChanged(id, state) }
        }
        connection.start(queue: .main)
        receive(on: connection, id: id)
    }

    private func connectionChanged(_ id: ClientID, _ state: NWConnection.State) {
        switch state {
        case .ready:
            if wasRejected(id) {
                drop(id)
                return
            }
            send(.state(controller.snapshot), to: id)
        case .failed, .cancelled:
            drop(id)
        default:
            break
        }
    }

    private func wasRejected(_ id: ClientID) -> Bool {
        let metadata = connections[id]?.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
        return metadata?.additionalServerHeaders?.contains { $0 == Self.rejectionMarker } ?? false
    }

    private func receive(on connection: NWConnection, id: ClientID) {
        connection.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self, self.connections[id] != nil else { return }
                if error != nil || context?.isFinal == true {
                    self.drop(id)
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close {
                    self.drop(id)
                    return
                }
                if metadata?.opcode == .text, let content, let text = String(data: content, encoding: .utf8) {
                    self.process(text, from: id)
                }
                self.receive(on: connection, id: id)
            }
        }
    }

    private func process(_ text: String, from id: ClientID) {
        let message: ClientMessage
        do {
            message = try NacelleCodec.decodeClient(text)
        } catch {
            send(.error(code: .badMessage, message: "Message illisible."), to: id)
            return
        }
        if let failure = controller.handle(message, from: id) {
            send(.error(code: failure.code, message: failure.message), to: id)
        }
    }

    private func drop(_ id: ClientID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.cancel()
        controller.clientDisconnected(id)
    }

    private func broadcast(_ message: ServerMessage) {
        for id in connections.keys {
            send(message, to: id)
        }
    }

    private func send(_ message: ServerMessage, to id: ClientID) {
        guard let connection = connections[id], let text = try? NacelleCodec.encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "nacelle", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}
