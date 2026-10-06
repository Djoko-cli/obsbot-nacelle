import Foundation
import NacelleProtocol
import Network
import PTZCore
import Testing
@testable import PTZServer

@MainActor
@Suite("Serveur WebSocket", .serialized, .timeLimit(.minutes(1)))
struct WebSocketServerTests {
    let camera = StubCamera()
    let controller: PTZController

    init() {
        controller = PTZController(
            camera: camera,
            scheduler: DispatchScheduler(),
            aiOff: StubAIOff(),
            store: StubStore(),
            settings: MotionSettings(),
            isObsbotCenterRunning: { false },
            log: { _ in }
        )
    }

    /// Démarre un serveur sur ces adresses (port 0 : choisi par le système) et
    /// renvoie le port ouvert sur chacune.
    private func startServer(
        on hosts: [String] = ["127.0.0.1"],
        scheduler: any Scheduler = DispatchScheduler(),
        log: @escaping LogSink = { _ in }
    ) async -> (WebSocketServer, [String: UInt16]) {
        let server = WebSocketServer(hosts: hosts, port: 0, controller: controller, scheduler: scheduler, log: log)
        let ports = await withCheckedContinuation { continuation in
            var ready: [String: UInt16] = [:]
            server.onReady = { host, port in
                ready[host] = port
                if ready.count == hosts.count {
                    continuation.resume(returning: ready)
                }
            }
            server.start()
        }
        return (server, ports)
    }

    private func connect(_ host: String, _ port: UInt16, origin: String? = nil) -> URLSessionWebSocketTask {
        let authority = host.contains(":") ? "[\(host)]" : host
        var request = URLRequest(url: URL(string: "ws://\(authority):\(port)")!)
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return task
    }

    /// Client WebSocket qui ne répond pas aux pings (`autoReplyPing = false`), ou simple
    /// connexion TCP qui n'envoie jamais de poignée de main (`webSocket: false`).
    private func rawClient(_ port: UInt16, webSocket: Bool) -> NWConnection {
        let parameters = NWParameters.tcp
        if webSocket {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = false
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        let endpoint: NWEndpoint = webSocket
            ? .url(URL(string: "ws://127.0.0.1:\(port)")!)
            : .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: .main)
        return connection
    }

    /// Attend (5 s au plus) que la condition devienne vraie.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    /// Lit les messages jusqu'au premier qui satisfait la condition.
    private func next(_ task: URLSessionWebSocketTask, where matches: (ServerMessage) -> Bool) async throws -> ServerMessage {
        while true {
            guard case let .string(text) = try await task.receive() else { continue }
            let message = try NacelleCodec.decodeServer(text)
            if matches(message) {
                return message
            }
        }
    }

    @Test("État envoyé à la connexion ; move appliqué ; message illisible signalé")
    func roundTrip() async throws {
        let (server, ports) = await startServer()
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let first = try await next(task) { _ in true }
        guard case let .state(snapshot) = first else {
            Issue.record("état attendu, reçu \(first)")
            return
        }
        #expect(snapshot.camera == .connected)

        try await task.send(.string(try NacelleCodec.encode(ClientMessage.move(pan: 1, tilt: 0))))
        _ = try await next(task) { if case let .state(s) = $0 { s.moving } else { false } }
        #expect(camera.relativeCommands.first?.panDirection == 1)

        try await task.send(.string("pas du json"))
        let error = try await next(task) { if case .error = $0 { true } else { false } }
        #expect(error == .error(code: .badMessage, message: "Message illisible."))
        withExtendedLifetime(server) {}
    }

    @Test("Deux adresses, un seul contrôleur : l'état est diffusé aux clients des deux")
    func twoHosts() async throws {
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"])
        let first = connect("127.0.0.1", ports["127.0.0.1"]!)
        let second = connect("::1", ports["::1"]!)
        defer { [first, second].forEach { $0.cancel(with: .goingAway, reason: nil) } }
        _ = try await next(first) { _ in true }
        _ = try await next(second) { _ in true }

        try await first.send(.string(try NacelleCodec.encode(ClientMessage.move(pan: 1, tilt: 0))))
        let seen = try await next(second) { if case let .state(s) = $0 { s.moving } else { false } }
        guard case let .state(snapshot) = seen else { return }
        #expect(snapshot.moving)
        withExtendedLifetime(server) {}
    }

    @Test("Une adresse en double n'est écoutée qu'une fois")
    func duplicateHosts() async throws {
        let server = WebSocketServer(hosts: ["127.0.0.1", "127.0.0.1"], port: 0, controller: controller, scheduler: DispatchScheduler(), log: { _ in })
        var readyCount = 0
        server.onReady = { _, _ in readyCount += 1 }
        server.start()
        try await Task.sleep(for: .milliseconds(500))
        #expect(readyCount == 1)
        withExtendedLifetime(server) {}
    }

    @Test("Au-delà de 4 clients, la connexion est refusée")
    func maxClients() async throws {
        let (server, ports) = await startServer()
        let port = ports["127.0.0.1"]!
        var tasks: [URLSessionWebSocketTask] = []
        for _ in 0..<WebSocketServer.maxClients {
            let task = connect("127.0.0.1", port)
            _ = try await next(task) { _ in true }
            tasks.append(task)
        }
        let extra = connect("127.0.0.1", port)
        await #expect(throws: (any Error).self) {
            _ = try await extra.receive()
        }
        (tasks + [extra]).forEach { $0.cancel(with: .goingAway, reason: nil) }
        withExtendedLifetime(server) {}
    }

    @Test("Poignée de main avec en-tête Origin (navigateur) : refusée, journalisée, place libérée")
    func browserOriginRejected() async throws {
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) })
        let port = ports["127.0.0.1"]!
        let browser = connect("127.0.0.1", port, origin: "https://exemple.invalid")
        await #expect(throws: (any Error).self) {
            _ = try await browser.receive()
        }
        #expect(lines.values.contains("Connexion refusée : en-tête Origin (navigateur)."))
        // La connexion refusée est fermée côté serveur : les 4 places restent libres
        // pour les clients sans Origin (app iOS, nacelle-ws).
        var clients: [URLSessionWebSocketTask] = []
        for _ in 0..<WebSocketServer.maxClients {
            let task = connect("127.0.0.1", port)
            _ = try await next(task) { _ in true }
            clients.append(task)
        }
        (clients + [browser]).forEach { $0.cancel(with: .goingAway, reason: nil) }
        withExtendedLifetime(server) {}
    }

    @Test("Connexion jamais prête : place libérée 10 s après l'acceptation, avec une ligne de journal")
    func handshakeTimeout() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) })
        let client = rawClient(ports["127.0.0.1"]!, webSocket: false)
        defer { client.cancel() }
        try await waitUntil { server.clientCount == 1 }

        scheduler.advance(by: WebSocketServer.handshakeTimeout - 0.1)
        #expect(server.clientCount == 1)
        scheduler.advance(by: 0.1)
        #expect(server.clientCount == 0)
        #expect(lines.values.contains("Client 1 libéré : poignée de main non terminée en 10 s."))
    }

    @Test("Client qui ne répond pas aux pings : place libérée 25 s après le dernier pong")
    func missingPong() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) })
        let client = rawClient(ports["127.0.0.1"]!, webSocket: true)
        defer { client.cancel() }
        // Prêt : le délai de poignée de main est annulé, restent le ping et l'échéance du pong.
        try await waitUntil { server.clientCount == 1 && scheduler.pendingCount == 2 }

        scheduler.advance(by: WebSocketServer.pingInterval)
        try await Task.sleep(for: .milliseconds(300))
        scheduler.advance(by: WebSocketServer.pingInterval)
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.clientCount == 1)
        scheduler.advance(by: WebSocketServer.pongTimeout - 2 * WebSocketServer.pingInterval)
        #expect(server.clientCount == 0)
        #expect(lines.values.contains("Client 1 libéré : pas de pong depuis 25 s."))
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Client qui répond aux pings (URLSessionWebSocketTask) : gardé au-delà de 25 s")
    func pongKeepsClient() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) })
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await next(task) { _ in true }
        try await waitUntil { scheduler.pendingCount == 2 }

        // URLSessionWebSocketTask ne répond aux pings que si une réception est en attente :
        // comme l'app iOS et nacelle-ws, on lit en continu.
        let reader = Task { while true { _ = try await task.receive() } }
        defer { reader.cancel() }
        for _ in 0..<4 {
            scheduler.advance(by: WebSocketServer.pingInterval)
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(server.clientCount == 1)
        #expect(!lines.values.contains { $0.contains("libéré") })
    }

    @Test("Connexion en attente (chemin réseau perdu) : place libérée, avec une ligne de journal")
    func waitingReleases() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) })
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await next(task) { _ in true }

        server.connectionChanged(1, .waiting(.posix(.ENETDOWN)))
        #expect(server.clientCount == 0)
        #expect(lines.values.contains { $0.hasPrefix("Client 1 libéré : connexion en attente") })
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Fermeture normale : minuteries du client annulées, rien de plus au journal")
    func normalCloseCancelsTimers() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) })
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        _ = try await next(task) { _ in true }
        try await waitUntil { scheduler.pendingCount == 2 }

        task.cancel(with: .goingAway, reason: nil)
        try await waitUntil { server.clientCount == 0 }
        #expect(scheduler.pendingCount == 0)
        #expect(!lines.values.contains { $0.contains("libéré") })
    }
}

@MainActor
final class LineBox {
    var values: [String] = []
}

@MainActor
final class StubCamera: CameraDevice {
    var isPresent = true
    private(set) var relativeCommands: [PanTiltRelative] = []

    func setPanTiltRelative(_ command: PanTiltRelative) throws {
        relativeCommands.append(command)
    }

    func setPanTiltAbsolute(panDegrees: Double, tiltDegrees: Double) throws {}
    func setZoom(_ value: Int) throws {}

    func readPanTilt() throws -> PanTiltPosition {
        PanTiltPosition(pan: 0, tilt: 0)
    }

    func readZoom() throws -> Int {
        0
    }
}

@MainActor
final class StubAIOff: AIOffRunner {
    func run(completion: @escaping @MainActor @Sendable (AIOffResult) -> Void) {
        completion(.success)
    }
}

final class StubStore: StateStore {
    func load() -> PersistedState {
        PersistedState(privacy: false, saved: nil)
    }

    func save(_ state: PersistedState) throws {}
}
