import Foundation

/// Le journal de talkd (spec haut-parleur § 5.5) : `~/Library/Logs/obsbot-nacelle/talkd.log`, une ligne datée par
/// message. Aucun son n'est enregistré. Au-delà de `maxBytes`, le fichier passe à `talkd.log.1` (le précédent est
/// remplacé). Une erreur d'écriture est ignorée : le journal ne fait jamais tomber le daemon.
@MainActor
public final class JournalFile {
    private let url: URL
    private let maxBytes: Int
    private let now: () -> Date
    private let formatter: ISO8601DateFormatter
    private var size: Int?

    public init(url: URL, maxBytes: Int = 1_000_000, now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.url = url
        self.maxBytes = maxBytes
        self.now = now
        formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
    }

    public func write(_ line: String) {
        let data = Data("\(formatter.string(from: now())) \(line)\n".utf8)
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if size == nil {
                size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            }
            if let current = size, current + data.count > maxBytes, current > 0 {
                let old = url.appendingPathExtension("1")
                try? manager.removeItem(at: old)
                try manager.moveItem(at: url, to: old)
                size = 0
            }
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            size = (size ?? 0) + data.count
        } catch {
            // Ignoré : voir plus haut.
        }
    }
}
