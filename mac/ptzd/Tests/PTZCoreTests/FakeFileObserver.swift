import Foundation
@testable import PTZCore

/// L'observation du fichier d'état, simulée : le test déclenche les changements.
@MainActor
final class FakeFileObserver: FileChangeObserver {
    private(set) var observeCalls = 0
    private(set) var cancelCalls = 0
    private var handlers: [@MainActor @Sendable () -> Void] = []
    private(set) var isObserving = false

    func observe(_ onChange: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
        observeCalls += 1
        isObserving = true
        handlers.append(onChange)
        return FakeObservation { [self] in
            MainActor.assumeIsolated {
                cancelCalls += 1
                isObserving = false
            }
        }
    }

    /// Le fichier a changé.
    func emit() {
        guard isObserving else { return }
        for handler in handlers { handler() }
    }
}

final class FakeObservation: Cancellable {
    private let onCancel: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel()
    }
}

/// Un compteur de signalements, lisible depuis n'importe quel fil.
final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
