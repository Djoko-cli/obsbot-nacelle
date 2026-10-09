import Foundation
import Testing
@testable import TalkCore

@Suite("État écrit pour l'app")
struct TalkStateTests {
    @Test("Format du fichier : speaking, since (ISO 8601) et pid ; le contrat lu par PTZBot")
    func format() throws {
        let state = TalkState(speaking: true, since: Date(timeIntervalSince1970: 1_791_000_000), pid: 4242)
        let data = try TalkState.encoder.encode(state)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(#""speaking" : true"#))
        #expect(text.contains(#""since" : "2026-10-03T04:00:00Z""#))
        #expect(text.contains(#""pid" : 4242"#))
        #expect(try TalkState.decoder.decode(TalkState.self, from: data) == state)
    }

    @Test("Sans échec, aucun champ failure : les fichiers restent ceux que l'app lisait déjà")
    func noFailureKey() throws {
        let data = try TalkState.encoder.encode(TalkState(speaking: false, since: Date(timeIntervalSince1970: 1_791_000_000), pid: 1))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("failure"))
    }

    @Test("Échec au démarrage : failure écrit (portBusy ou socket), et relu")
    func failure() throws {
        let state = TalkState(speaking: false, since: Date(timeIntervalSince1970: 1_791_000_000), pid: 7, failure: TalkState.portBusy)
        let data = try TalkState.encoder.encode(state)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(#""failure" : "portBusy""#))
        #expect(try TalkState.decoder.decode(TalkState.self, from: data) == state)
    }

    @Test("Le code d'échec suit l'erreur de la socket : port occupé, sinon socket")
    func failureCodes() {
        #expect(TalkState.failure(for: .addressInUse(1986)) == "portBusy")
        #expect(TalkState.failure(for: .socket("bind", EACCES)) == "socket")
        #expect(TalkState.failure(for: .alreadyStarted) == "socket")
    }

    @MainActor
    @Test("Le fichier est écrit de façon atomique, dossier créé, et remplacé à chaque écriture")
    func fileStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "sous-dossier/talkd-state.json")
        let store = JSONFileTalkStateStore(url: url)
        try store.save(TalkState(speaking: true, since: Date(timeIntervalSince1970: 1_791_000_000), pid: 1))
        try store.save(TalkState(speaking: false, since: Date(timeIntervalSince1970: 1_791_000_005), pid: 1))
        let read = try TalkState.decoder.decode(TalkState.self, from: Data(contentsOf: url))
        #expect(read == TalkState(speaking: false, since: Date(timeIntervalSince1970: 1_791_000_005), pid: 1))
        // Aucun fichier temporaire ne reste à côté.
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names == ["talkd-state.json"])
    }
}
