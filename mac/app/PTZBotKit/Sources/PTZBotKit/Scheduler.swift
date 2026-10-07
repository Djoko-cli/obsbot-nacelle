import Foundation

/// Une action programmée, annulable.
public protocol Cancellable: AnyObject {
    func cancel()
}

/// Minuteries, injectées pour que les tests maîtrisent le temps.
@MainActor
public protocol Scheduler: AnyObject {
    /// Temps monotone, en secondes.
    var now: TimeInterval { get }
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable
}

/// Implémentation réelle, sur la file principale.
@MainActor
public final class MainScheduler: Scheduler {
    public init() {}

    public var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    @discardableResult
    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
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
