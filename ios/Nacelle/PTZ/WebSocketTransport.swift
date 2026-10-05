import Foundation

/// Ce qui arrive sur la connexion WebSocket.
enum TransportEvent: Equatable, Sendable {
    case opened
    case message(String)
    /// Connexion fermée ou impossible à ouvrir.
    case closed
}

/// Le WebSocket vers ptzd, derrière un protocole pour les tests. Les événements arrivent sur le MainActor.
@MainActor
protocol WebSocketTransport: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    func open(_ url: URL)
    func send(_ text: String)
    func close()
}

/// Implémentation réelle, sur URLSessionWebSocketTask. Une seule connexion à la fois ;
/// les événements d'une connexion remplacée sont ignorés.
@MainActor
final class URLSessionWebSocketTransport: NSObject, WebSocketTransport {
    /// Délai d'ouverture (60 s par défaut), aligné sur `Signaling.timeout`. Ce réglage ne coupe pas
    /// une connexion ouverte et silencieuse : c'est le rôle de `Heartbeat`.
    static let openTimeout: TimeInterval = 10

    var onEvent: ((TransportEvent) -> Void)?
    private let scheduler: any Scheduler
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var heartbeat: Heartbeat?

    init(scheduler: any Scheduler) {
        self.scheduler = scheduler
    }

    func open(_ url: URL) {
        close()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.openTimeout
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        receive(on: task)
    }

    func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    func close() {
        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, task === self.task else { return }
                switch result {
                case let .success(.string(text)):
                    self.onEvent?(.message(text))
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure:
                    self.finish(task)
                }
            }
        }
    }

    /// Signale la fin d'une connexion, une seule fois.
    private func finish(_ task: URLSessionTask) {
        guard task === self.task else { return }
        stopHeartbeat()
        self.task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        onEvent?(.closed)
    }

    /// Un Mac devenu muet (veille, Tailscale arrêté, coupure) ne ferme rien : sans pong, la connexion
    /// est abandonnée comme un échec de réception, d'où la reconnexion.
    private func startHeartbeat(for task: URLSessionWebSocketTask) {
        let heartbeat = Heartbeat(
            scheduler: scheduler,
            ping: { reply in
                task.sendPing { error in
                    Task { @MainActor in
                        reply(error == nil)
                    }
                }
            },
            onLost: { [weak self] in
                task.cancel(with: .goingAway, reason: nil)
                self?.finish(task)
            }
        )
        self.heartbeat = heartbeat
        heartbeat.start()
    }

    private func stopHeartbeat() {
        heartbeat?.stop()
        heartbeat = nil
    }
}

/// Vivacité d'une connexion : `URLSessionWebSocketTask` n'envoie aucun ping de lui-même, et ptzd ne
/// parle qu'aux changements d'état. Un ping toutes les 5 s ; sans pong avant le suivant, ou si le
/// ping échoue, la connexion est perdue. Une instance par connexion ouverte.
@MainActor
final class Heartbeat {
    typealias Pong = @MainActor @Sendable (_ received: Bool) -> Void

    static let interval: TimeInterval = 5

    private let scheduler: any Scheduler
    private let ping: (@escaping Pong) -> Void
    private let onLost: () -> Void
    private var timer: (any Cancellable)?
    private var awaitingPong = false
    private var isRunning = false

    init(scheduler: any Scheduler, ping: @escaping (@escaping Pong) -> Void, onLost: @escaping () -> Void) {
        self.scheduler = scheduler
        self.ping = ping
        self.onLost = onLost
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleTick()
    }

    /// Plus de ping ; une réponse tardive est ignorée.
    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    private func scheduleTick() {
        timer = scheduler.schedule(after: Self.interval) { [weak self] in
            self?.tick()
        }
    }

    private func tick() {
        timer = nil
        guard isRunning else { return }
        guard !awaitingPong else {
            lose()
            return
        }
        awaitingPong = true
        scheduleTick()
        ping { [weak self] received in
            guard let self, self.isRunning else { return }
            if received {
                self.awaitingPong = false
            } else {
                self.lose()
            }
        }
    }

    private func lose() {
        stop()
        onLost()
    }
}

extension URLSessionWebSocketTransport: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        MainActor.assumeIsolated {
            guard webSocketTask === self.task else { return }
            self.startHeartbeat(for: webSocketTask)
            self.onEvent?(.opened)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            self.finish(task)
        }
    }
}
