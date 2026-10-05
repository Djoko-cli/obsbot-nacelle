import Foundation

/// Une action programmée, annulable.
protocol Cancellable: AnyObject {
    func cancel()
}

/// Minuteries, injectées pour que les tests maîtrisent le temps.
@MainActor
protocol Scheduler: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable
}

/// Implémentation réelle, sur la file principale.
@MainActor
final class MainScheduler: Scheduler {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return WorkItemCancellable(item: item)
    }
}

private final class WorkItemCancellable: Cancellable {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}
