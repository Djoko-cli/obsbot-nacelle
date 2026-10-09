import AVFoundation
import Foundation

/// Les fichiers temporaires des enregistrements : `PTZBot-<date>.mp4` dans le dossier temporaire de l'app
/// (spec enregistrement § 4.1 et § 4.3). Un fichier y reste tant que la vidéo n'est pas dans Photos.
struct RecordingFiles: Sendable {
    static let prefix = "PTZBot-"
    static let fileExtension = "mp4"
    /// Au lancement, les fichiers plus vieux que cela sont effacés.
    static let maximumAge: TimeInterval = 7 * 24 * 3600

    var directory: URL
    /// Le fichier est-il un MP4 lisible ? (Un enregistrement interrompu n'a pas de fin : illisible.)
    var isPlayable: @Sendable (URL) async -> Bool

    static func live() -> RecordingFiles {
        RecordingFiles(directory: FileManager.default.temporaryDirectory) { url in
            let asset = AVURLAsset(url: url)
            guard let playable = try? await asset.load(.isPlayable), playable,
                  let duration = try? await asset.load(.duration) else { return false }
            return duration.seconds > 0
        }
    }

    /// Un nom neuf, d'après l'heure : `PTZBot-2026-10-09-143015.mp4` (suffixe `-2`, `-3`… si le nom existe déjà).
    func newFileURL(now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = Self.prefix + formatter.string(from: now)
        var url = directory.appendingPathComponent(stem).appendingPathExtension(Self.fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem)-\(counter)").appendingPathExtension(Self.fileExtension)
            counter += 1
        }
        return url
    }

    /// Les enregistrements qui traînent, du plus récent au plus ancien.
    func leftoverFiles() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix(Self.prefix) && $0.pathExtension == Self.fileExtension }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Efface les enregistrements de plus de `maximumAge`.
    func purgeOldFiles(now: Date) {
        for url in leftoverFiles() {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) > Self.maximumAge {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Les textes de durée de l'enregistrement.
enum RecordingFormat {
    /// Chronomètre du badge : `00:42`, ou `1:02:03` au-delà d'une heure.
    static func clock(seconds: Int) -> String {
        let total = max(seconds, 0)
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%02d:%02d", minutes, rest)
    }

    /// Durée d'une vidéo rangée : `0:42`, `12:05`, ou `1:02:03`.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// Phrase lue par VoiceOver pour le badge.
    static func spoken(seconds: Int) -> String {
        "Enregistrement en cours, \(max(seconds, 0)) seconde\(seconds >= 2 ? "s" : "")"
    }
}
