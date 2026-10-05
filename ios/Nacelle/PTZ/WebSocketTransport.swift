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
    var onEvent: ((TransportEvent) -> Void)?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    func open(_ url: URL) {
        close()
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
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
        self.task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        onEvent?(.closed)
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
            self.onEvent?(.opened)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            self.finish(task)
        }
    }
}
