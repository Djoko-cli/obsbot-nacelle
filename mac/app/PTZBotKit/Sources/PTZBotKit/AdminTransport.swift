import Foundation

/// Ce qui arrive sur la connexion à ptzd.
public enum AdminTransportEvent: Equatable, Sendable {
    case opened
    case message(String)
    /// Connexion fermée ou impossible à ouvrir.
    case closed
}

/// Le WebSocket vers ptzd, derrière un protocole pour les tests. Les événements arrivent sur le MainActor.
@MainActor
public protocol AdminTransport: AnyObject {
    var onEvent: ((AdminTransportEvent) -> Void)? { get set }
    func open(_ url: URL)
    func send(_ text: String)
    func close()
}

/// Implémentation réelle, sur URLSessionWebSocketTask. Une connexion à la fois ; les événements d'une
/// connexion remplacée sont ignorés.
@MainActor
public final class URLSessionAdminTransport: NSObject, AdminTransport {
    public var onEvent: ((AdminTransportEvent) -> Void)?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    override public init() {}

    public func open(_ url: URL) {
        close()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        receive(on: task)
    }

    public func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    public func close() {
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

    private func finish(_ task: URLSessionTask) {
        guard task === self.task else { return }
        self.task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        onEvent?(.closed)
    }
}

extension URLSessionAdminTransport: URLSessionWebSocketDelegate {
    nonisolated public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated {
            guard webSocketTask === self.task else { return }
            self.onEvent?(.opened)
        }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            self.finish(task)
        }
    }
}
