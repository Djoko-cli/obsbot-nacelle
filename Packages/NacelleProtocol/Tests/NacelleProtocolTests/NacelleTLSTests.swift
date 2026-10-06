import Foundation
import Network
import Testing
@testable import NacelleProtocol

/// Échanges réels sur 127.0.0.1 : écoute TLS-PSK + WebSocket, client TLS-PSK + WebSocket.
@Suite("Canal TLS à clé pré-partagée", .serialized, .timeLimit(.minutes(1)))
struct NacelleTLSTests {
    final class Keys: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String: Data]

        init(_ keys: [String: Data]) {
            self.keys = keys
        }

        func key(for identity: String) -> Data? {
            lock.withLock { keys[identity] }
        }

        func remove(_ identity: String) {
            lock.withLock { _ = keys.removeValue(forKey: identity) }
        }

        func set(_ identity: String, _ key: Data) {
            lock.withLock { keys[identity] = key }
        }
    }

    final class Box<Value>: @unchecked Sendable {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    static let alice = "0123456789abcdef0123456789abcdef"

    private func webSocket(_ tls: NWProtocolTLS.Options) -> NWParameters {
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(.main) { _, _ in NWProtocolWebSocket.Response(status: .accept, subprotocol: nil) }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return parameters
    }

    /// Écoute d'écho ; renvoie l'écoute et son port.
    private func startEchoServer(_ keys: Keys) async throws -> (NWListener, UInt16) {
        let tls = NacelleTLS.server(identities: [Self.alice]) { keys.key(for: $0) }
        let parameters = webSocket(tls)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            @Sendable func echo() {
                connection.receiveMessage { content, context, _, error in
                    guard error == nil, let content, let context else { return }
                    connection.send(content: content, contentContext: context, isComplete: true, completion: .idempotent)
                    echo()
                }
            }
            echo()
        }
        let port: UInt16 = await withCheckedContinuation { continuation in
            let resumed = Box(false)
            listener.stateUpdateHandler = { state in
                if case .ready = state, !resumed.value {
                    resumed.value = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                }
            }
            listener.start(queue: .main)
        }
        return (listener, port)
    }

    /// Envoie « bonjour » et attend l'écho, 3 s au plus ; vrai si l'écho revient.
    private func roundTrip(port: UInt16, identity: String, key: Data) async -> Bool {
        let parameters = webSocket(NacelleTLS.client(identity: identity, key: key))
        let connection = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)")!), using: parameters)
        defer { connection.cancel() }
        return await withCheckedContinuation { continuation in
            let done = Box(false)
            @Sendable func finish(_ result: Bool) {
                guard !done.value else { return }
                done.value = true
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                    let context = NWConnection.ContentContext(identifier: "essai", metadata: [metadata])
                    connection.send(content: Data("bonjour".utf8), contentContext: context, isComplete: true, completion: .idempotent)
                    connection.receiveMessage { content, _, _, _ in
                        finish(content == Data("bonjour".utf8))
                    }
                case .failed, .waiting, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(false) }
        }
    }

    @Test("Secret de 32 octets, différent à chaque fois")
    func makeKey() {
        #expect(NacelleTLS.makeKey().count == 32)
        #expect(NacelleTLS.makeKey() != NacelleTLS.makeKey())
    }

    @Test("Bonne clé : échange ; mauvaise clé, même juste après un succès : refus")
    func rightAndWrongKey() async throws {
        let key = NacelleTLS.makeKey()
        let (listener, port) = try await startEchoServer(Keys([Self.alice: key]))
        defer { listener.cancel() }
        #expect(await roundTrip(port: port, identity: Self.alice, key: key))
        #expect(await !roundTrip(port: port, identity: Self.alice, key: NacelleTLS.makeKey()))
    }

    @Test("Identité inconnue : refus")
    func unknownIdentity() async throws {
        let (listener, port) = try await startEchoServer(Keys([Self.alice: NacelleTLS.makeKey()]))
        defer { listener.cancel() }
        #expect(await !roundTrip(port: port, identity: "ffffffffffffffffffffffffffffffff", key: NacelleTLS.makeKey()))
    }

    @Test("Appareil retiré : refusé dès la poignée de main suivante, sans relancer l'écoute")
    func revocation() async throws {
        let key = NacelleTLS.makeKey()
        let keys = Keys([Self.alice: key])
        let (listener, port) = try await startEchoServer(keys)
        defer { listener.cancel() }
        #expect(await roundTrip(port: port, identity: Self.alice, key: key))
        keys.remove(Self.alice)
        #expect(await !roundTrip(port: port, identity: Self.alice, key: key))
    }

    @Test("Clé remplacée sans relancer l'écoute (réappairage) : l'ancienne et la nouvelle sont refusées")
    func replacedKey() async throws {
        let old = NacelleTLS.makeKey()
        let keys = Keys([Self.alice: old])
        let (listener, port) = try await startEchoServer(keys)
        defer { listener.cancel() }
        #expect(await roundTrip(port: port, identity: Self.alice, key: old))
        let new = NacelleTLS.makeKey()
        keys.set(Self.alice, new)
        #expect(await !roundTrip(port: port, identity: Self.alice, key: old))
        #expect(await !roundTrip(port: port, identity: Self.alice, key: new))
    }
}
