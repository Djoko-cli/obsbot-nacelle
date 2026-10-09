import Foundation

/// Le début de la dernière phase CoreAudio, et le nombre de phases courtes de suite (`talkd-runs.json`).
public struct StartupRecord: Codable, Equatable, Sendable {
    public var lastCoreAudioStart: Date
    public var shortRuns: Int

    public init(lastCoreAudioStart: Date, shortRuns: Int) {
        self.lastCoreAudioStart = lastCoreAudioStart
        self.shortRuns = shortRuns
    }
}

/// Le frein au démarrage (relecture I4) : contre un talkd qui planterait en boucle **après** ses premiers appels
/// CoreAudio. launchd le relancerait toutes les 10 s (`ThrottleInterval`), soit jusqu'à 360 clients coreaudiod par
/// heure, le motif exact du § 10 de la spec.
///
/// - Une phase CoreAudio est courte quand la suivante commence moins de 60 s après elle.
/// - Dès deux phases courtes de suite, la suivante est différée de `min(30 s × 2^(n−2), 15 min)`.
/// - Un plantage en boucle tombe ainsi à quelques clients par heure, et une reprise normale n'est jamais ralentie.
/// - Le port occupé (code 75) n'est pas concerné : il s'arrête avant toute phase CoreAudio.
///
/// Fonction pure : l'horloge et le fichier sont donnés par l'appelant.
public enum StartupBrake {
    public struct Decision: Equatable, Sendable {
        public var shortRuns: Int
        public var delay: TimeInterval

        public init(shortRuns: Int, delay: TimeInterval) {
            self.shortRuns = shortRuns
            self.delay = delay
        }
    }

    public static let shortPhase: TimeInterval = 60
    public static let baseDelay: TimeInterval = 30
    public static let maxDelay: TimeInterval = 15 * 60

    /// Ce qu'il faut faire à ce démarrage, d'après la phase précédente (nil : aucune).
    public static func decide(previous: StartupRecord?, now: Date) -> Decision {
        guard let previous else { return Decision(shortRuns: 0, delay: 0) }
        // Une horloge revenue en arrière compte comme une phase courte : prudent pour coreaudiod.
        let short = now.timeIntervalSince(previous.lastCoreAudioStart) < shortPhase
        // Un fichier abîmé (négatif) repart de 0 ; Int.max ne déborde pas.
        let runs = short ? (previous.shortRuns == Int.max ? Int.max : max(previous.shortRuns, 0) + 1) : 0
        return Decision(shortRuns: runs, delay: delay(shortRuns: runs))
    }

    /// `min(30 s × 2^(n−2), 15 min)` dès deux phases courtes, 0 avant.
    public static func delay(shortRuns: Int) -> TimeInterval {
        guard shortRuns >= 2 else { return 0 }
        // Au-delà de 2^5, le plafond est atteint : l'exposant est borné, aucun débordement.
        let exponent = min(shortRuns - 2, 10)
        return min(baseDelay * Double(1 << exponent), maxDelay)
    }
}

@MainActor
public protocol StartupRecordStore: AnyObject {
    /// nil : aucun fichier.
    func load() throws -> StartupRecord?
    func save(_ record: StartupRecord) throws
    /// Sans effet si le fichier n'existe pas.
    func clear() throws
}

/// `talkd-runs.json`, écrit de façon atomique.
@MainActor
public final class JSONFileStartupRecordStore: StartupRecordStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> StartupRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try TalkState.decoder.decode(StartupRecord.self, from: Data(contentsOf: url))
    }

    public func save(_ record: StartupRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TalkState.encoder.encode(record).write(to: url, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
