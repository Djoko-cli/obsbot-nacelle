import CryptoKit
import Foundation
import NacelleProtocol
import Network
import PTZAuth
import PTZCore
import Testing
@testable import PTZServer

@MainActor
@Suite("Serveur WebSocket", .serialized, .timeLimit(.minutes(1)))
struct WebSocketServerTests {
    let camera = StubCamera()
    let controller: PTZController
    let authority: DeviceAuthority
    /// Clé de l'appareil de test, appairée par `pairTestDevice()`.
    let key = P256.Signing.PrivateKey()

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ptzserver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        authority = DeviceAuthority(directory: directory)
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
        log: @escaping LogSink = { _ in },
        trustLoopback: Bool = true,
        relay: any WebRTCRelay = FakeRelay { "v=0 réponse à \($0)" }
    ) async -> (WebSocketServer, [String: UInt16]) {
        let server = WebSocketServer(
            hosts: hosts, port: 0, controller: controller, authority: authority, relay: relay,
            scheduler: scheduler, log: log, trustLoopback: trustLoopback
        )
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

    private var deviceID: String {
        NacelleAuth.deviceID(publicKeyX963: key.publicKey.x963Representation)
    }

    private func pairTestDevice() throws {
        try authority.devices.add(PairedDevice(deviceID: deviceID, name: "iPhone de test", publicKey: key.publicKey.x963Representation, pairedAt: Date()))
    }

    private func send(_ message: ClientMessage, on task: URLSessionWebSocketTask) async throws {
        try await task.send(.string(try NacelleCodec.encode(message)))
    }

    /// Le défi reçu à l'ouverture.
    private func challenge(_ task: URLSessionWebSocketTask) async throws -> Data {
        guard case let .challenge(nonce) = try await next(task, where: { _ in true }) else {
            Issue.record("défi attendu")
            return Data()
        }
        return nonce
    }

    private func signature(for nonce: Data) throws -> Data {
        try key.signature(for: NacelleAuth.signedPayload(nonce: nonce, deviceID: deviceID)).derRepresentation
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

    @Test("127.0.0.1 : authentifié d'office, puis l'état ; move appliqué ; message illisible signalé")
    func roundTrip() async throws {
        let (server, ports) = await startServer()
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        #expect(try await next(task) { _ in true } == .authenticated)
        let second = try await next(task) { _ in true }
        guard case let .state(snapshot) = second else {
            Issue.record("état attendu, reçu \(second)")
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
        let server = WebSocketServer(
            hosts: ["127.0.0.1", "127.0.0.1"], port: 0, controller: controller, authority: authority,
            relay: FakeRelay { $0 }, scheduler: DispatchScheduler(), log: { _ in }
        )
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

        scheduler.advance(by: WebSocketServer.authTimeout - 0.1)
        #expect(server.clientCount == 1)
        scheduler.advance(by: 0.1)
        #expect(server.clientCount == 0)
        #expect(lines.values.contains("Client 1 libéré : pas authentifié en 10 s."))
    }

    @Test("Sans 127.0.0.1 de confiance : défi d'abord, rien d'autre avant l'authentification")
    func challengeFirst() async throws {
        let (server, ports) = await startServer(trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        #expect(try await challenge(task).count == NacelleAuth.nonceLength)
        try await send(.move(pan: 1, tilt: 0), on: task)
        #expect(try await next(task) { _ in true } == .error(code: .notAuthenticated, message: "Authentification d'abord."))
        #expect(camera.relativeCommands.isEmpty)
        withExtendedLifetime(server) {}
    }

    @Test("Signature juste : authenticated, puis l'état ; les commandes passent")
    func validAuth() async throws {
        try pairTestDevice()
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let nonce = try await challenge(task)
        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
        #expect(try await next(task) { _ in true } == .authenticated)
        guard case .state = try await next(task, where: { _ in true }) else {
            Issue.record("état attendu")
            return
        }
        try await send(.move(pan: 1, tilt: 0), on: task)
        _ = try await next(task) { if case let .state(s) = $0 { s.moving } else { false } }
        #expect(lines.values.contains("Client 1 authentifié : iPhone de test (\(deviceID.prefix(8)))."))
        withExtendedLifetime(server) {}
    }

    @Test("Appareil inconnu : unpaired, puis fermeture et place libérée")
    func unknownDevice() async throws {
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let nonce = try await challenge(task)
        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
        #expect(try await next(task) { _ in true } == .error(code: .unpaired, message: "Appareil inconnu : l'appairer avec ptzd pair."))
        try await waitUntil { server.clientCount == 0 }
        #expect(lines.values.contains { $0.hasPrefix("Client 1 refusé : appareil inconnu \(deviceID.prefix(8))") })
    }

    @Test("Signature d'un autre défi (rejeu) : authFailed, puis fermeture")
    func replayedSignature() async throws {
        try pairTestDevice()
        let (server, ports) = await startServer(trustLoopback: false)
        let first = connect("127.0.0.1", ports["127.0.0.1"]!)
        let second = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { [first, second].forEach { $0.cancel(with: .goingAway, reason: nil) } }

        let firstNonce = try await challenge(first)
        _ = try await challenge(second)
        try await send(.auth(deviceID: deviceID, signature: try signature(for: firstNonce)), on: second)
        #expect(try await next(second) { _ in true } == .error(code: .authFailed, message: "Signature refusée."))
        try await waitUntil { server.clientCount == 1 }
    }

    @Test("Défi sans réponse : place libérée 10 s après l'acceptation")
    func authTimeout() async throws {
        let scheduler = FakeScheduler()
        let lines = LineBox()
        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) }, trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await challenge(task)

        scheduler.advance(by: WebSocketServer.authTimeout)
        #expect(server.clientCount == 0)
        #expect(lines.values.contains("Client 1 libéré : pas authentifié en 10 s."))
    }

    @Test("Appairage : code faux (connexion gardée), puis bon code, puis auth sur le même défi")
    func pairing() async throws {
        let code = try authority.pairing.open()
        let wrong = code == "000000" ? "000001" : "000000"
        let (server, ports) = await startServer(trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        let nonce = try await challenge(task)
        let publicKey = key.publicKey.x963Representation

        try await send(.pair(code: wrong, publicKey: publicKey, name: "iPhone"), on: task)
        #expect(try await next(task) { _ in true } == .error(code: .badCode, message: "Code d'appairage faux."))
        try await send(.pair(code: code, publicKey: publicKey, name: "iPhone"), on: task)
        #expect(try await next(task) { _ in true } == .paired(deviceID: deviceID))
        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
        #expect(try await next(task) { _ in true } == .authenticated)
        #expect(try authority.devices.device(id: deviceID)?.name == "iPhone")
        withExtendedLifetime(server) {}
    }

    @Test("Appairage sans code en cours : pairingClosed")
    func pairingClosed() async throws {
        let (server, ports) = await startServer(trustLoopback: false)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await challenge(task)
        try await send(.pair(code: "123456", publicKey: key.publicKey.x963Representation, name: "iPhone"), on: task)
        #expect(try await next(task) { _ in true } == .error(code: .pairingClosed, message: "Aucun appairage en cours : lancer ptzd pair sur le Mac."))
        withExtendedLifetime(server) {}
    }

    @Test("Offre WebRTC relayée : réponse avec le même identifiant")
    func relayAnswer() async throws {
        let (server, ports) = await startServer()
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await next(task) { if case .state = $0 { true } else { false } }

        try await send(.webrtcOffer(id: 7, sdp: "offre"), on: task)
        #expect(try await next(task) { if case .webrtcAnswer = $0 { true } else { false } } == .webrtcAnswer(id: 7, sdp: "v=0 réponse à offre"))
        withExtendedLifetime(server) {}
    }

    @Test("go2rtc en échec : webrtcError avec le même identifiant, journalisé")
    func relayError() async throws {
        let lines = LineBox()
        let (server, ports) = await startServer(log: { lines.values.append($0) }, relay: FakeRelay { _ in throw RelayError.badResponse(status: 500) })
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await next(task) { if case .state = $0 { true } else { false } }

        try await send(.webrtcOffer(id: 2, sdp: "offre"), on: task)
        #expect(try await next(task) { if case .webrtcError = $0 { true } else { false } } == .webrtcError(id: 2, message: "go2rtc ne répond pas."))
        #expect(lines.values.contains { $0.hasPrefix("Relais vidéo du client 1 en échec") })
        withExtendedLifetime(server) {}
    }

    @Test("Offre avant l'authentification : refusée, go2rtc pas appelé")
    func relayRequiresAuth() async throws {
        let calls = CallCounter()
        let (server, ports) = await startServer(trustLoopback: false, relay: FakeRelay { calls.increment(); return $0 })
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await challenge(task)

        try await send(.webrtcOffer(id: 1, sdp: "offre"), on: task)
        #expect(try await next(task) { _ in true } == .error(code: .notAuthenticated, message: "Authentification d'abord."))
        #expect(calls.value == 0)
        withExtendedLifetime(server) {}
    }

    @Test("Une nouvelle offre remplace la précédente : seule la dernière reçoit sa réponse")
    func newOfferReplaces() async throws {
        let relay = FakeRelay { offer in
            if offer == "lente" {
                try await Task.sleep(for: .seconds(1))
            }
            return "v=0 \(offer)"
        }
        let (server, ports) = await startServer(relay: relay)
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await next(task) { if case .state = $0 { true } else { false } }

        try await send(.webrtcOffer(id: 1, sdp: "lente"), on: task)
        try await send(.webrtcOffer(id: 2, sdp: "rapide"), on: task)
        #expect(try await next(task) { if case .webrtcAnswer = $0 { true } else { false } } == .webrtcAnswer(id: 2, sdp: "v=0 rapide"))
        try await Task.sleep(for: .milliseconds(1500))
        try await task.send(.string("pas du json"))
        // Après 1,5 s, le message suivant est l'erreur de lecture : la réponse à l'offre 1 n'est jamais partie.
        let following = try await next(task) { if case .state = $0 { false } else { true } }
        #expect(following == .error(code: .badMessage, message: "Message illisible."))
        withExtendedLifetime(server) {}
    }

    @Test("L'état n'est diffusé qu'aux clients authentifiés")
    func broadcastOnlyToAuthenticated() async throws {
        try pairTestDevice()
        let (server, ports) = await startServer(trustLoopback: false)
        let anonymous = connect("127.0.0.1", ports["127.0.0.1"]!)
        let member = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { [anonymous, member].forEach { $0.cancel(with: .goingAway, reason: nil) } }
        _ = try await challenge(anonymous)
        let nonce = try await challenge(member)
        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: member)
        _ = try await next(member) { if case .state = $0 { true } else { false } }

        try await send(.move(pan: 1, tilt: 0), on: member)
        _ = try await next(member) { if case let .state(s) = $0 { s.moving } else { false } }
        // Le client anonyme ne reçoit que la réponse à son propre message.
        try await send(.zoom(value: 10), on: anonymous)
        #expect(try await next(anonymous) { _ in true } == .error(code: .notAuthenticated, message: "Authentification d'abord."))
        withExtendedLifetime(server) {}
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

/// Relais WebRTC de test : la réponse est calculée à partir de l'offre.
struct FakeRelay: WebRTCRelay {
    let handler: @Sendable (String) async throws -> String

    init(_ handler: @escaping @Sendable (String) async throws -> String) {
        self.handler = handler
    }

    func answer(offer: String) async throws -> String {
        try await handler(offer)
    }
}

/// Compteur partagé avec un relais de test.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
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
