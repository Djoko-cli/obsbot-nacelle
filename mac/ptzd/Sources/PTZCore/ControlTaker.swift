import Foundation
import NacelleProtocol

/// Suivi IA de la caméra par `obsbot-ai` (spec § 6.4, amendement A3, spec app Mac § 7.5) : la coupure
/// avant de piloter (prise en main), et les ordres explicites. Retient le dernier ordre réussi, l'état réel
/// ne se lisant pas.
@MainActor
public final class ControlTaker {
    /// Délai avant l'unique nouvel essai après un échec : le SDK peut échouer quand la
    /// vidéo démarre au même moment, ce que fait l'app à chaque ouverture (constaté le 2026-10-05).
    public static let retryDelay: TimeInterval = 3

    public private(set) var state: ControlState = .idle
    /// Dernier ordre réussi ; `unknown` au départ et après `forget()`.
    public private(set) var tracking: AITracking = .unknown
    /// Appelé quand `state` ou `tracking` change.
    public var onChange: (() -> Void)?

    private let runner: any AIRunner
    private let scheduler: any Scheduler
    private let isObsbotCenterRunning: @MainActor () -> Bool
    private let log: LogSink
    private var retried = false
    private var explicitOrder = false
    private var cutPending = false

    public init(
        runner: any AIRunner,
        scheduler: any Scheduler,
        isObsbotCenterRunning: @escaping @MainActor () -> Bool,
        log: @escaping LogSink
    ) {
        self.runner = runner
        self.scheduler = scheduler
        self.isObsbotCenterRunning = isObsbotCenterRunning
        self.log = log
    }

    /// Lance la coupure, avec un nouvel essai. Pendant une exécution (nouvel essai compris), une
    /// nouvelle demande attend le même résultat. Une coupure demandée pendant un ordre explicite
    /// est lancée quand cet ordre se termine.
    public func take() {
        if isObsbotCenterRunning() {
            log("OBSBOT Center est ouvert : ferme-le, il fausse la relecture du tilt.")
        }
        guard state != .taking else { if explicitOrder { cutPending = true }; return }
        state = .taking
        retried = false
        onChange?()
        launch()
    }

    /// Ordre explicite (interrupteur des apps), sans nouvel essai : `completion` reçoit le résultat.
    /// Refusé pendant une autre exécution. Réussi : `tracking` suit l'ordre ; échoué : rien ne change.
    public func setTracking(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        guard state != .taking else {
            completion(.launchFailed("suivi IA déjà en cours de changement"))
            return
        }
        let previous = state
        state = .taking
        onChange?()
        explicitOrder = true
        runner.run(on: on) { [weak self] result in
            guard let self else { return }
            if result == .success {
                tracking = on ? .on : .off
                state = on ? .idle : .ready
            } else {
                log("obsbot-ai \(on ? "on" : "off") a échoué : \(result)")
                state = previous
            }
            onChange?()
            explicitOrder = false
            completion(result)
            if cutPending {
                cutPending = false
                if !(result == .success && !on) {
                    take()
                }
            }
        }
    }

    /// L'état réel redevient inconnu (rebranchement de la caméra).
    public func forget() {
        guard tracking != .unknown else { return }
        tracking = .unknown
        onChange?()
    }

    private func launch() {
        runner.run(on: false) { [weak self] result in
            self?.finish(result)
        }
    }

    /// Un échec est retenté une fois après `retryDelay` ; `failed` n'est publié qu'après le second.
    private func finish(_ result: AIResult) {
        if result == .success {
            state = .ready
            tracking = .off
            onChange?()
            return
        }
        guard retried else {
            retried = true
            log("obsbot-ai off a échoué (\(result)) : nouvel essai dans \(Int(Self.retryDelay)) s.")
            scheduler.schedule(after: Self.retryDelay) { [weak self] in
                self?.launch()
            }
            return
        }
        state = .failed
        log("obsbot-ai off a échoué : \(result)")
        onChange?()
    }
}
