@testable import PTZCore

/// obsbot-ai simulé : le test décide quand et comment il se termine.
@MainActor
final class FakeAIRunner: AIRunner {
    private(set) var runCount = 0
    /// Ordres reçus, dans l'ordre (true : on).
    private(set) var orders: [Bool] = []
    /// Nombre de préparations demandées.
    private(set) var prewarms = 0
    /// Réinitialisations demandées (branchement ou débranchement de la caméra).
    private(set) var resets = 0
    private var completions: [@MainActor @Sendable (AIResult) -> Void] = []

    func run(on: Bool, completion: @escaping @MainActor @Sendable (AIResult) -> Void) {
        runCount += 1
        orders.append(on)
        completions.append(completion)
    }

    func prewarm() {
        prewarms += 1
    }

    func reset() {
        resets += 1
    }

    func finish(_ result: AIResult) {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0(result) }
    }
}
