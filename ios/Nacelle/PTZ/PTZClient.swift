import Foundation
import NacelleProtocol
import Observation

/// Dialogue avec ptzd (spec § 7.2) : prise en main à chaque connexion, `move` répété
/// 10 fois par seconde tant que le joystick est hors du centre, reconnexion espacée.
@MainActor
@Observable
final class PTZClient {
    enum Link: Equatable {
        case idle
        case connecting
        case connected
        case waitingToRetry
    }

    static let repeatInterval: TimeInterval = 0.1
    static let retryDelays: [TimeInterval] = [1, 2, 4, 8]

    private(set) var link: Link = .idle
    /// Dernier état reçu de ptzd ; nil hors connexion.
    private(set) var state: StateSnapshot?
    /// Dernière erreur renvoyée par ptzd.
    private(set) var lastError: ErrorCode?
    /// Vrai quand une tentative de connexion a échoué, jusqu'à la prochaine réussite.
    /// Remis à faux par `start(url:)` et `stop()` : le bandeau revient à « Connexion… ».
    private(set) var isUnreachable = false

    @ObservationIgnored private let transport: any WebSocketTransport
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var openedThisAttempt = false
    @ObservationIgnored private var retry: (any Cancellable)?
    @ObservationIgnored private var repeater: (any Cancellable)?
    @ObservationIgnored private var currentMove = JoystickVector.zero

    init(transport: any WebSocketTransport, scheduler: any Scheduler) {
        self.transport = transport
        self.scheduler = scheduler
        transport.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    func start(url: URL) {
        self.url = url
        attempt = 0
        isUnreachable = false
        retry?.cancel()
        retry = nil
        connect()
    }

    /// Passage en arrière-plan : arrêt de la nacelle, puis fermeture.
    func stop() {
        if currentMove != .zero {
            send(.move(pan: 0, tilt: 0))
        }
        currentMove = .zero
        stopRepeating()
        retry?.cancel()
        retry = nil
        url = nil
        transport.close()
        link = .idle
        state = nil
        isUnreachable = false
    }

    func setJoystick(_ vector: JoystickVector) {
        let wasMoving = currentMove != .zero
        currentMove = vector
        guard vector != .zero else {
            stopRepeating()
            if wasMoving {
                send(.move(pan: 0, tilt: 0))
            }
            return
        }
        send(.move(pan: vector.pan, tilt: vector.tilt))
        if repeater == nil {
            scheduleRepeat()
        }
    }

    func setZoom(_ value: Int) {
        send(.zoom(value: value))
    }

    func setPrivacy(_ on: Bool) {
        send(.privacy(on: on))
    }

    func takeControl() {
        send(.takeControl)
    }

    private func connect() {
        guard let url else { return }
        link = .connecting
        openedThisAttempt = false
        transport.open(url)
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .opened:
            link = .connected
            openedThisAttempt = true
            attempt = 0
            isUnreachable = false
            send(.takeControl)
        case let .message(text):
            guard let message = try? NacelleCodec.decodeServer(text) else { return }
            switch message {
            case let .state(snapshot):
                state = snapshot
            case let .error(code, _):
                lastError = code
            }
        case .closed:
            stopRepeating()
            currentMove = .zero
            state = nil
            guard url != nil else {
                link = .idle
                return
            }
            if !openedThisAttempt {
                isUnreachable = true
            }
            link = .waitingToRetry
            let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
            attempt += 1
            retry = scheduler.schedule(after: delay) { [weak self] in
                self?.retry = nil
                self?.connect()
            }
        }
    }

    private func send(_ message: ClientMessage) {
        guard link == .connected, let text = try? NacelleCodec.encode(message) else { return }
        transport.send(text)
    }

    private func scheduleRepeat() {
        repeater = scheduler.schedule(after: Self.repeatInterval) { [weak self] in
            self?.repeatTick()
        }
    }

    private func repeatTick() {
        repeater = nil
        guard currentMove != .zero else { return }
        send(.move(pan: currentMove.pan, tilt: currentMove.tilt))
        scheduleRepeat()
    }

    private func stopRepeating() {
        repeater?.cancel()
        repeater = nil
    }
}
