@testable import PTZCore

/// obsbot-ai-off simulé : le test décide quand et comment il se termine.
@MainActor
final class FakeAIOffRunner: AIOffRunner {
    private(set) var runCount = 0
    private var completions: [@MainActor @Sendable (AIOffResult) -> Void] = []

    func run(completion: @escaping @MainActor @Sendable (AIOffResult) -> Void) {
        runCount += 1
        completions.append(completion)
    }

    func finish(_ result: AIOffResult) {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0(result) }
    }
}
