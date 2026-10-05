import Foundation
@testable import PTZCore

/// state.json en mémoire.
final class MemoryStateStore: StateStore {
    var state: PersistedState
    var failSaves = false
    private(set) var saveCount = 0

    init(_ state: PersistedState = PersistedState(privacy: false, saved: nil)) {
        self.state = state
    }

    func load() -> PersistedState {
        state
    }

    func save(_ state: PersistedState) throws {
        saveCount += 1
        if failSaves {
            throw CocoaError(.fileWriteNoPermission)
        }
        self.state = state
    }
}
