import Foundation
import NacelleProtocol
import Network

enum TLSClientError: Error {
    /// Pas de canal : poignée de main TLS refusée, ou connexion fermée.
    case noChannel
}

/// Client WebSocket en TLS à clé pré-partagée, comme l'app sur le réseau local (tests).
@MainActor
final class TLSClient {
    let connection: NWConnection

    init(host: String, port: UInt16, identity: String, key: Data) {
        let parameters = NWParameters(tls: NacelleTLS.client(identity: identity, key: key), tcp: NWProtocolTCP.Options())
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let authority = host.contains(":") ? "[\(host)]" : host
        connection = NWConnection(to: .url(URL(string: "ws://\(authority):\(port)")!), using: parameters)
    }

    /// Ouvre le canal ; échoue si la poignée de main TLS n'aboutit pas en 3 s.
    func open() async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.finish(nil)
                case .waiting, .failed, .cancelled:
                    once.finish(TLSClientError.noChannel)
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { once.finish(TLSClientError.noChannel) }
        }
    }

    /// Reprend une attente une seule fois (rappels de Network et minuterie, tous sur la file principale).
    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, any Error>?

        init(_ continuation: CheckedContinuation<Void, any Error>) {
            self.continuation = continuation
        }

        func finish(_ error: (any Error)?) {
            guard let continuation else { return }
            self.continuation = nil
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    func send(_ message: ClientMessage) throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "test", metadata: [metadata])
        connection.send(content: Data(try NacelleCodec.encode(message).utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Le message suivant du serveur.
    func receive() async throws -> ServerMessage {
        let connection = connection
        let text: String = try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { content, _, _, error in
                if error == nil, let content, let text = String(data: content, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: TLSClientError.noChannel)
                }
            }
        }
        return try NacelleCodec.decodeServer(text)
    }

    /// Le premier message du serveur qui satisfait la condition.
    func receive(where matches: (ServerMessage) -> Bool) async throws -> ServerMessage {
        while true {
            let message = try await receive()
            if matches(message) {
                return message
            }
        }
    }

    func close() {
        connection.cancel()
    }
}
