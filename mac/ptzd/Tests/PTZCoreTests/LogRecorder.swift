@testable import PTZCore

/// Journal capturé pour les assertions.
@MainActor
final class LogRecorder {
    private(set) var lines: [String] = []

    var sink: LogSink {
        { [weak self] line in self?.lines.append(line) }
    }
}
