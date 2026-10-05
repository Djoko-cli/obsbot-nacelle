import Foundation
@testable import Nacelle

/// Horloge manuelle : `advance(by:)` exécute les actions arrivées à échéance, dans l'ordre.
@MainActor
final class FakeScheduler: Scheduler {
    private(set) var now: TimeInterval = 0
    private var tasks: [FakeTask] = []
    private var counter = 0

    var pendingCount: Int {
        tasks.filter { !$0.cancelled }.count
    }

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
        counter += 1
        let task = FakeTask(at: now + delay, order: counter, action: action)
        tasks.append(task)
        return task
    }

    func advance(by delta: TimeInterval) {
        let target = now + delta
        while let next = tasks
            .filter({ !$0.cancelled && $0.at <= target + 1e-9 })
            .min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            tasks.removeAll { $0 === next }
            now = max(now, next.at)
            next.action()
        }
        now = target
        tasks.removeAll { $0.cancelled }
    }
}

final class FakeTask: Cancellable {
    let at: TimeInterval
    let order: Int
    let action: @MainActor @Sendable () -> Void
    private(set) var cancelled = false

    init(at: TimeInterval, order: Int, action: @escaping @MainActor @Sendable () -> Void) {
        self.at = at
        self.order = order
        self.action = action
    }

    func cancel() {
        cancelled = true
    }
}
