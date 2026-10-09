import Foundation
import Testing
@testable import Nacelle

@Suite("Fichiers et textes de l'enregistrement")
struct RecordingFilesTests {
    @Test("Chronomètre du badge : mm:ss, puis h:mm:ss au-delà d'une heure")
    func clock() {
        #expect(RecordingFormat.clock(seconds: 0) == "00:00")
        #expect(RecordingFormat.clock(seconds: 42) == "00:42")
        #expect(RecordingFormat.clock(seconds: 600) == "10:00")
        #expect(RecordingFormat.clock(seconds: 3_599) == "59:59")
        #expect(RecordingFormat.clock(seconds: 3_723) == "1:02:03")
        #expect(RecordingFormat.clock(seconds: -3) == "00:00")
    }

    @Test("Durée d'une vidéo rangée : m:ss arrondi à la seconde")
    func duration() {
        #expect(RecordingFormat.duration(42) == "0:42")
        #expect(RecordingFormat.duration(41.6) == "0:42")
        #expect(RecordingFormat.duration(725) == "12:05")
        #expect(RecordingFormat.duration(3_723) == "1:02:03")
    }

    @Test("Phrase de VoiceOver : singulier à 0 et 1 seconde")
    func spoken() {
        #expect(RecordingFormat.spoken(seconds: 42) == "Enregistrement en cours, 42 secondes")
        #expect(RecordingFormat.spoken(seconds: 1) == "Enregistrement en cours, 1 seconde")
        #expect(RecordingFormat.spoken(seconds: 0) == "Enregistrement en cours, 0 seconde")
    }

    @Test("Nom de fichier : PTZBot-<date>.mp4, avec un suffixe si le nom existe déjà")
    func fileNames() throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RecordingFiles(directory: directory) { _ in false }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = files.newFileURL(now: now)
        #expect(first.lastPathComponent.hasPrefix("PTZBot-20"))
        #expect(first.pathExtension == "mp4")
        try Data("x".utf8).write(to: first)
        let second = files.newFileURL(now: now)
        #expect(second != first)
        #expect(second.lastPathComponent.hasSuffix("-2.mp4"))
    }

    @Test("Restes : seulement nos fichiers, du plus récent au plus ancien ; purge au-delà de 7 jours")
    func leftoversAndPurge() throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RecordingFiles(directory: directory) { _ in false }
        let now = Date()
        func make(_ name: String, daysOld: Double) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
            return url
        }
        let recent = try make("PTZBot-a.mp4", daysOld: 1)
        let older = try make("PTZBot-b.mp4", daysOld: 6.9)
        let expired = try make("PTZBot-c.mp4", daysOld: 7.1)
        let foreign = try make("autre.mp4", daysOld: 30)
        let notVideo = try make("PTZBot-d.txt", daysOld: 30)
        #expect(files.leftoverFiles() == [recent, older, expired])
        files.purgeOldFiles(now: now)
        #expect(files.leftoverFiles() == [recent, older])
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(FileManager.default.fileExists(atPath: notVideo.path))
        #expect(!FileManager.default.fileExists(atPath: expired.path))
    }

    @Test("Avis d'une vidéo rangée : avec la durée, ou sans quand on la ignore")
    func savedText() {
        #expect(StatusBanner.saved(duration: 42) == "Vidéo enregistrée dans Photos (0:42)")
        #expect(StatusBanner.saved(duration: nil) == "Vidéo enregistrée dans Photos")
    }
}
