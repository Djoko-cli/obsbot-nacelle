import Foundation

/// L'état que talkd écrit pour l'app (spec haut-parleur § 6, « En lecture »), dans
/// `~/Library/Application Support/ObsbotNacelle/talkd-state.json`. PTZBot le relit (`TalkbackState`, même format).
///
/// - `speaking` : une prise de parole est en lecture.
/// - `since` : l'instant du dernier changement de `speaking`.
/// - `pid` : le processus qui l'a écrit ; l'app s'en sert pour ignorer l'état d'un talkd qui n'existe plus.
/// - `failure` (relecture I3) : présent seulement quand talkd s'arrête sur un échec au démarrage, écrit juste avant
///   `exit` : `portBusy` (port UDP déjà utilisé) ou `socket` (autre erreur de la socket). Absent sinon, si bien que
///   les fichiers sans ce champ restent valides. Écrire ce fichier ne touche pas CoreAudio.
public struct TalkState: Codable, Equatable, Sendable {
    public static let portBusy = "portBusy"
    public static let socketFailure = "socket"

    public var speaking: Bool
    public var since: Date
    public var pid: Int32
    public var failure: String?

    public init(speaking: Bool, since: Date, pid: Int32, failure: String? = nil) {
        self.speaking = speaking
        self.since = since
        self.pid = pid
        self.failure = failure
    }

    /// Le code d'échec écrit pour l'app quand la socket UDP ne s'ouvre pas.
    public static func failure(for error: UDPReceiver.Failure) -> String {
        if case .addressInUse = error {
            return portBusy
        }
        return socketFailure
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor
public protocol TalkStateStore: AnyObject {
    func save(_ state: TalkState) throws
}

/// talkd-state.json, écrit de façon atomique (l'app ne lit jamais un fichier à moitié écrit).
@MainActor
public final class JSONFileTalkStateStore: TalkStateStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func save(_ state: TalkState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TalkState.encoder.encode(state).write(to: url, options: .atomic)
    }
}
