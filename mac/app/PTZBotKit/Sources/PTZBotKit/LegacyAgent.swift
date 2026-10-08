import Foundation

/// `launchctl`, derrière un protocole pour les tests : l'app ne touche à launchd que pour l'ancien agent.
public protocol Launchctl: Sendable {
    func isLoaded(label: String) -> Bool
    func bootout(label: String) throws
}

/// Implémentation réelle : `/bin/launchctl print|bootout gui/<uid>/<label>`.
public struct SystemLaunchctl: Launchctl {
    public struct Failure: LocalizedError {
        public var status: Int32
        public var errorDescription: String? { Localization.text("launchctl bootout a échoué (code \(String(status))).") }
    }

    public init() {}

    private func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func target(_ label: String) -> String {
        "gui/\(getuid())/\(label)"
    }

    public func isLoaded(label: String) -> Bool {
        run(["print", target(label)]) == 0
    }

    public func bootout(label: String) throws {
        let status = run(["bootout", target(label)])
        guard status == 0 else { throw Failure(status: status) }
    }
}

/// La corbeille, derrière un protocole pour les tests : les anciens binaires y vont, jamais effacés.
public protocol Trash: Sendable {
    func trash(_ url: URL) throws
}

/// Implémentation réelle : `FileManager.trashItem`.
public struct FileManagerTrash: Trash {
    public init() {}

    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// Échec de la migration : l'app reste branchée sur l'ancien ptzd (spec ptzd dans l'app § 5.6).
public enum LegacyMigrationError: Error, Equatable, Sendable {
    case bootoutFailed(String)
    /// L'ancien ptzd est encore chargé 10 s après le `bootout`.
    case stillLoaded
    case renameFailed(String)

    public var message: String {
        switch self {
        case let .bootoutFailed(reason):
            Localization.text("L'ancienne installation n'a pas pu être arrêtée : \(reason)")
        case .stillLoaded:
            Localization.text("L'ancienne installation ne s'est pas arrêtée à temps.")
        case let .renameFailed(reason):
            Localization.text("L'ancienne installation est arrêtée, mais sa plist n'a pas pu être renommée : \(reason)")
        }
    }
}

/// L'ancienne installation : l'agent launchd `io.github.djoko-cli.obsbot-nacelle.ptzd` et les binaires
/// de `bin/` (spec ptzd dans l'app § 5.6). Bloquant (launchctl, attente) : à appeler hors du fil principal.
public struct LegacyAgent: Sendable {
    public static let label = "io.github.djoko-cli.obsbot-nacelle.ptzd"
    public static let binaries = ["bin/ptzd", "bin/obsbot-ai", "bin/obsbot-ai-off"]
    /// launchd peut mettre plusieurs secondes à arrêter l'ancien ptzd.
    public static let stopTimeout: TimeInterval = 10
    public static let pollInterval: TimeInterval = 0.25

    /// Ce que la migration n'a pas pu faire sans échouer pour autant (corbeille, reprise du SDK).
    public struct Report: Equatable, Sendable {
        public var trashed: [String] = []
        public var movedSDK = false
        public var problems: [String] = []
    }

    public let launchAgentsDirectory: URL
    public let supportDirectory: URL
    private let launchctl: any Launchctl
    private let trash: any Trash
    private let sleep: @Sendable (TimeInterval) -> Void

    public init(
        launchAgentsDirectory: URL,
        supportDirectory: URL,
        launchctl: any Launchctl,
        trash: any Trash,
        sleep: @escaping @Sendable (TimeInterval) -> Void
    ) {
        self.launchAgentsDirectory = launchAgentsDirectory
        self.supportDirectory = supportDirectory
        self.launchctl = launchctl
        self.trash = trash
        self.sleep = sleep
    }

    /// L'ancienne installation du Mac : vrai `~/Library/LaunchAgents`, vrai launchctl, vraie corbeille.
    public static func system(supportDirectory: URL) -> LegacyAgent {
        LegacyAgent(
            launchAgentsDirectory: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents"),
            supportDirectory: supportDirectory,
            launchctl: SystemLaunchctl(),
            trash: FileManagerTrash(),
            sleep: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    public var plistURL: URL {
        launchAgentsDirectory.appending(path: "\(Self.label).plist")
    }

    public var backupURL: URL {
        launchAgentsDirectory.appending(path: "\(Self.label).plist.bak")
    }

    /// `<label>.plist.<date>.bak`, quand l'ancienne sauvegarde ne peut pas aller à la corbeille.
    func datedBackupURL(_ date: Date) -> URL {
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted))
        return launchAgentsDirectory.appending(path: "\(Self.label).plist.\(stamp).bak")
    }

    /// La plist existe ou l'agent est chargé.
    public func detect() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path) || launchctl.isLoaded(label: Self.label)
    }

    /// « Remplacer » : `bootout`, attente de l'arrêt (10 s au plus), plist renommée en `.plist.bak`, anciens
    /// binaires à la corbeille, SDK de `lib/` repris dans `sdk/` s'il n'y en a pas. Un `bootout` en échec
    /// ne change rien d'autre.
    public func migrate() throws(LegacyMigrationError) -> Report {
        if launchctl.isLoaded(label: Self.label) {
            do {
                try launchctl.bootout(label: Self.label)
            } catch {
                // bootout peut échouer alors que l'agent est bien parti (déjà en cours d'arrêt) : seul compte
                // qu'il ne soit plus chargé.
                guard !launchctl.isLoaded(label: Self.label) else {
                    throw .bootoutFailed(error.localizedDescription)
                }
            }
            var waited: TimeInterval = 0
            while launchctl.isLoaded(label: Self.label) {
                guard waited < Self.stopTimeout else { throw .stillLoaded }
                sleep(Self.pollInterval)
                waited += Self.pollInterval
            }
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: plistURL.path) {
            do {
                var backup = backupURL
                if manager.fileExists(atPath: backup.path) {
                    // Une sauvegarde plus ancienne va à la corbeille, jamais effacée ; sinon la nouvelle est datée.
                    do {
                        try trash.trash(backup)
                    } catch {
                        backup = datedBackupURL(Date())
                    }
                }
                try manager.moveItem(at: plistURL, to: backup)
            } catch {
                throw .renameFailed(error.localizedDescription)
            }
        }

        return completeLeftovers()
    }

    /// Ce qui reste d'une migration interrompue (plist déjà renommée, mais app quittée avant la corbeille ou la
    /// reprise du SDK) : anciens binaires à la corbeille, SDK de `lib/` repris dans `sdk/` seulement s'il n'y en
    /// a pas. Sans effet et silencieux quand il n'y a plus rien ; sans lien avec launchd.
    public func completeLeftovers() -> Report {
        let manager = FileManager.default
        var report = Report()
        for path in Self.binaries {
            let url = supportDirectory.appending(path: path)
            guard manager.fileExists(atPath: url.path) else { continue }
            do {
                try trash.trash(url)
                report.trashed.append(path)
            } catch {
                report.problems.append(Localization.text("\(path) n'a pas pu être mis à la corbeille : \(error.localizedDescription)"))
            }
        }

        let oldSDK = supportDirectory.appending(path: "lib/libdev.dylib")
        let newSDK = supportDirectory.appending(path: "sdk/libdev.dylib")
        if manager.fileExists(atPath: oldSDK.path), !manager.fileExists(atPath: newSDK.path) {
            do {
                try manager.createDirectory(at: newSDK.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: oldSDK, to: newSDK)
                report.movedSDK = true
            } catch {
                report.problems.append(Localization.text("Le SDK de lib/ n'a pas pu être repris : \(error.localizedDescription)"))
            }
        }
        return report
    }
}
