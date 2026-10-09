import Foundation

/// Les emplacements de talkd (spec haut-parleur § 5.5 et § 6). `TALKD_SUPPORT_DIR` remplace le dossier de travail pour
/// les essais (comme `PTZD_SUPPORT_DIR` pour ptzd) : réglages et état y vont, le journal dans son sous-dossier `logs`.
public struct TalkPaths: Equatable, Sendable {
    public var support: URL
    public var logs: URL

    public init(environment: [String: String], home: URL) {
        if let override = environment["TALKD_SUPPORT_DIR"], !override.isEmpty {
            support = URL(fileURLWithPath: override, isDirectory: true)
            logs = support.appending(path: "logs", directoryHint: .isDirectory)
        } else {
            support = home.appending(path: "Library/Application Support/ObsbotNacelle", directoryHint: .isDirectory)
            logs = home.appending(path: "Library/Logs/obsbot-nacelle", directoryHint: .isDirectory)
        }
    }

    /// talkd.json : les réglages, hors du dépôt.
    public var settings: URL {
        support.appending(path: "talkd.json")
    }

    /// talkd-state.json : l'état que PTZBot affiche (« En lecture »).
    public var state: URL {
        support.appending(path: "talkd-state.json")
    }

    /// talkd-volume.json : le fichier de reprise du volume, le temps d'une prise de parole.
    public var volumeRecovery: URL {
        support.appending(path: "talkd-volume.json")
    }

    /// talkd-runs.json : le frein au démarrage (début de la dernière phase CoreAudio, phases courtes de suite).
    public var runs: URL {
        support.appending(path: "talkd-runs.json")
    }

    /// talkd.log : le journal.
    public var journal: URL {
        logs.appending(path: "talkd.log")
    }
}

/// Codes de sortie de talkd.
public enum TalkExit {
    /// Option inconnue (EX_USAGE).
    public static let usage: Int32 = 64
    /// Port UDP déjà pris (EX_TEMPFAIL, comme ptzd) : launchd relance talkd au rythme du `ThrottleInterval`.
    public static let busy: Int32 = 75

    public static let usageText = "usage : talkd    (aucune option ; réglages dans talkd.json, voir la spec haut-parleur)"
}
