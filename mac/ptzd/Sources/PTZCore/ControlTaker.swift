import Foundation
import NacelleProtocol

/// Prise en main : coupe le suivi IA via obsbot-ai-off (spec § 6.4, amendement A3).
@MainActor
public final class ControlTaker {
    /// Délai avant l'unique nouvel essai après un échec : le SDK peut échouer quand la
    /// vidéo démarre au même moment, ce que fait l'app à chaque ouverture (constaté le 2026-10-05).
    public static let retryDelay: TimeInterval = 3

    public private(set) var state: ControlState = .idle
    /// Appelé quand `state` change.
    public var onChange: (() -> Void)?

    private let runner: any AIOffRunner
    private let scheduler: any Scheduler
    private let isObsbotCenterRunning: @MainActor () -> Bool
    private let log: LogSink
    private var retried = false

    public init(
        runner: any AIOffRunner,
        scheduler: any Scheduler,
        isObsbotCenterRunning: @escaping @MainActor () -> Bool,
        log: @escaping LogSink
    ) {
        self.runner = runner
        self.scheduler = scheduler
        self.isObsbotCenterRunning = isObsbotCenterRunning
        self.log = log
    }

    /// Lance la coupure. Pendant une exécution (nouvel essai compris), une nouvelle
    /// demande attend le même résultat.
    public func take() {
        if isObsbotCenterRunning() {
            log("OBSBOT Center est ouvert : ferme-le, il fausse la relecture du tilt.")
        }
        guard state != .taking else { return }
        state = .taking
        retried = false
        onChange?()
        launch()
    }

    private func launch() {
        runner.run { [weak self] result in
            self?.finish(result)
        }
    }

    /// Un échec est retenté une fois après `retryDelay` ; `failed` n'est publié qu'après le second.
    private func finish(_ result: AIOffResult) {
        if result == .success {
            state = .ready
            onChange?()
            return
        }
        guard retried else {
            retried = true
            log("obsbot-ai-off a échoué (\(result)) : nouvel essai dans \(Int(Self.retryDelay)) s.")
            scheduler.schedule(after: Self.retryDelay) { [weak self] in
                self?.launch()
            }
            return
        }
        state = .failed
        log("obsbot-ai-off a échoué : \(result)")
        onChange?()
    }
}
