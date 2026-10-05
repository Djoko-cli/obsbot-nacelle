import Foundation
import Testing
@testable import PTZCore

@Suite("state.json")
struct StateStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ptzd-tests-\(UUID().uuidString)")

    private var url: URL {
        directory.appending(path: "state.json")
    }

    @Test("Aller-retour")
    func roundTrip() throws {
        let store = JSONFileStateStore(url: url, log: { _ in })
        let state = PersistedState(privacy: true, saved: SavedPosition(pan: 30, tilt: -10, zoom: 33))
        try store.save(state)
        #expect(store.load() == state)
    }

    @Test("Fichier absent : pas de vie privée")
    func missingFile() {
        let store = JSONFileStateStore(url: url, log: { _ in })
        #expect(store.load() == PersistedState(privacy: false, saved: nil))
    }

    @Test("Fichier illisible : vie privée par précaution, et journalisé")
    func corruptFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{pas du json".utf8).write(to: url)
        let lines = Lines()
        let store = JSONFileStateStore(url: url, log: { lines.append($0) })
        #expect(store.load() == PersistedState(privacy: true, saved: nil))
        #expect(lines.count == 1)
    }
}

private final class Lines: @unchecked Sendable {
    private var storage: [String] = []

    func append(_ line: String) {
        storage.append(line)
    }

    var count: Int {
        storage.count
    }
}
