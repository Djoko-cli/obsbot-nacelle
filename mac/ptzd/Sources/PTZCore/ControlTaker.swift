import NacelleProtocol

/// Prise en main : coupe le suivi IA via obsbot-ai-off (spec § 6.4).
@MainActor
public final class ControlTaker {
    public private(set) var state: ControlState = .idle
    /// Appelé quand `state` change.
    public var onChange: (() -> Void)?

    private let runner: any AIOffRunner
    private let isObsbotCenterRunning: @MainActor () -> Bool
    private let log: LogSink

    public init(runner: any AIOffRunner, isObsbotCenterRunning: @escaping @MainActor () -> Bool, log: @escaping LogSink) {
        self.runner = runner
        self.isObsbotCenterRunning = isObsbotCenterRunning
        self.log = log
    }

    /// Lance la coupure. Pendant une exécution, une nouvelle demande attend le même résultat.
    public func take() {
        if isObsbotCenterRunning() {
            log("OBSBOT Center est ouvert : ferme-le, il fausse la relecture du tilt.")
        }
        guard state != .taking else { return }
        state = .taking
        onChange?()
        runner.run { [weak self] result in
            self?.finish(result)
        }
    }

    private func finish(_ result: AIOffResult) {
        if result == .success {
            state = .ready
        } else {
            state = .failed
            log("obsbot-ai-off a échoué : \(result)")
        }
        onChange?()
    }
}
