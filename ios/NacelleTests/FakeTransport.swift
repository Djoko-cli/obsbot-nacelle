import Foundation
@testable import Nacelle

/// Transport WebSocket simulé : enregistre les ouvertures et les envois ; le test déclenche les événements.
@MainActor
final class FakeTransport: WebSocketTransport {
    var onEvent: ((TransportEvent) -> Void)?
    private(set) var openedURLs: [URL] = []
    private(set) var sent: [String] = []
    private(set) var closeCount = 0

    func open(_ url: URL) {
        openedURLs.append(url)
    }

    func send(_ text: String) {
        sent.append(text)
    }

    func close() {
        closeCount += 1
    }

    func emit(_ event: TransportEvent) {
        onEvent?(event)
    }
}
