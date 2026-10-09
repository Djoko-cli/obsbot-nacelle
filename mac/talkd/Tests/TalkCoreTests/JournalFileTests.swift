import Foundation
import Testing
@testable import TalkCore

@MainActor
@Suite("Journal de talkd")
struct JournalFileTests {
    @Test("Une ligne par message, datée, ajoutée au fichier ; dossier créé")
    func appends() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "logs/talkd.log")
        let journal = JournalFile(url: url, now: { Date(timeIntervalSince1970: 1_791_000_000) }, timeZone: .gmt)
        journal.write("talkd démarre.")
        journal.write("Prise de parole.")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == ["2026-10-03T04:00:00Z talkd démarre.", "2026-10-03T04:00:00Z Prise de parole."])
    }

    @Test("Un journal trop gros est mis de côté (talkd.log.1) avant la ligne suivante")
    func rotates() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "talkd.log")
        let journal = JournalFile(url: url, maxBytes: 100, now: { Date(timeIntervalSince1970: 0) }, timeZone: .gmt)
        for index in 0..<10 {
            journal.write("ligne \(index) avec un peu de texte pour grossir")
        }
        let old = directory.appending(path: "talkd.log.1")
        #expect(FileManager.default.fileExists(atPath: old.path))
        let size = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 200)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("ligne 9"))
    }

    @Test("Un chemin inutilisable ne fait pas tomber le daemon")
    func unusablePath() {
        let journal = JournalFile(url: URL(fileURLWithPath: "/dev/null/impossible/talkd.log"), now: Date.init, timeZone: .gmt)
        journal.write("sans effet")
    }
}
