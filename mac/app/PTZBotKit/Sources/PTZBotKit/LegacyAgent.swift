import Foundation

/// `launchctl`, derrière un protocole pour les tests : l'app ne touche à launchd que pour l'ancien agent de ptzd et pour
/// l'agent de talkd (`ClassicAgent`).
public protocol Launchctl: Sendable {
    func isLoaded(label: String) -> Bool
    /// `launchctl print gui/<uid>/<label>` : le texte que launchd donne du service (PID, dernier code de sortie), `nil` si
    /// le service n'est pas chargé ou si `launchctl` n'a pas pu être lancé. Lu par `SystemLaunchctl.pid(fromPrint:)` et
    /// `SystemLaunchctl.lastExit(fromPrint:)` (spec B3 § 14).
    func printOutput(label: String) -> String?
    func bootout(label: String) throws
    /// `launchctl bootstrap gui/<uid> <plist>` : charge l'agent de cette plist. Échoue s'il est déjà chargé.
    func bootstrap(plist: URL) throws
    /// `launchctl enable gui/<uid>/<label>` : retire le service de la liste des services désactivés de launchd (où le met
    /// l'utilisateur quand il coupe l'élément dans Réglages › Général › Ouverture). Sans effet s'il n'y est pas.
    func enable(label: String) throws
    /// `launchctl kickstart -k gui/<uid>/<label>` : tue l'agent chargé puis le relance, depuis le programme que sa plist
    /// désigne (le nouveau talkd remplace l'ancien encore en mémoire).
    func kickstart(label: String) throws
}

/// Implémentation réelle : `/bin/launchctl print|bootout|bootstrap|enable|kickstart` sur le domaine `gui/<uid>`.
public struct SystemLaunchctl: Launchctl {
    public struct Failure: LocalizedError {
        public var command: String
        public var status: Int32
        public var errorDescription: String? { Localization.text("launchctl \(command) a échoué (code \(String(status))).") }
    }

    /// Les appels à `launchctl` que l'app fait.
    public enum Command: Equatable, Sendable {
        case print(String)
        case bootout(String)
        case bootstrap(URL)
        case enable(String)
        case kickstart(String)

        var name: String {
            switch self {
            case .print: "print"
            case .bootout: "bootout"
            case .bootstrap: "bootstrap"
            case .enable: "enable"
            case .kickstart: "kickstart"
            }
        }
    }

    /// Le programme lancé : `/bin/launchctl`. Les tests en passent un autre (jamais le vrai `launchctl`).
    private let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/bin/launchctl")) {
        self.executableURL = executableURL
    }

    /// Les arguments de `launchctl`, pour l'utilisateur `uid`. Séparés de l'exécution pour être testés sans lancer le
    /// vrai `launchctl`.
    public static func arguments(_ command: Command, uid: uid_t) -> [String] {
        switch command {
        case let .print(label): ["print", "gui/\(uid)/\(label)"]
        case let .bootout(label): ["bootout", "gui/\(uid)/\(label)"]
        case let .bootstrap(plist): ["bootstrap", "gui/\(uid)", plist.path]
        case let .enable(label): ["enable", "gui/\(uid)/\(label)"]
        case let .kickstart(label): ["kickstart", "-k", "gui/\(uid)/\(label)"]
        }
    }

    /// Lance le programme (sortie standard vers `output`, erreurs jetées) ; `finished` est signalé à sa fin. L'attente passe
    /// par ce sémaphore et non par `waitUntilExit`, qui fait tourner la boucle d'exécution : sur le fil principal (le
    /// lancement de go2rtc), elle livrerait des événements au milieu d'une opération en cours.
    private func start(_ command: Command, output: Any) -> (process: Process, finished: DispatchSemaphore)? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = Self.arguments(command, uid: getuid())
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        return (process, finished)
    }

    private func run(_ command: Command) -> Int32 {
        guard let (process, finished) = start(command, output: FileHandle.nullDevice) else { return -1 }
        finished.wait()
        return process.terminationStatus
    }

    /// Comme `run`, mais la sortie standard est lue : (code de sortie, texte). Lue jusqu'à la fin avant d'attendre le
    /// processus, pour qu'une sortie plus grosse que le tampon du tube ne le bloque pas.
    private func runCapturing(_ command: Command) -> (status: Int32, output: String)? {
        let pipe = Pipe()
        guard let (process, finished) = start(command, output: pipe) else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        finished.wait()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func check(_ command: Command) throws {
        let status = run(command)
        guard status == 0 else { throw Failure(command: command.name, status: status) }
    }

    public func isLoaded(label: String) -> Bool {
        run(.print(label)) == 0
    }

    public func printOutput(label: String) -> String? {
        guard let result = runCapturing(.print(label)), result.status == 0 else { return nil }
        return result.output
    }

    public func bootout(label: String) throws {
        try check(.bootout(label))
    }

    public func bootstrap(plist: URL) throws {
        try check(.bootstrap(plist))
    }

    public func enable(label: String) throws {
        try check(.enable(label))
    }

    public func kickstart(label: String) throws {
        try check(.kickstart(label))
    }
}

/// La lecture de `launchctl print` (spec B3 § 14). Le service s'y décrit par des lignes à **une** tabulation de retrait
/// (`\tpid = 4242`) ; les sous-blocs (`\t\tstate = active`, files d'attente, domaines) en ont deux ou plus et peuvent
/// répéter les mêmes mots : seules les lignes à une tabulation comptent.
extension SystemLaunchctl {
    /// Les lignes du service, sans leur tabulation.
    private static func serviceLines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("\t") && !$0.hasPrefix("\t\t") }
            .map { $0.dropFirst() }
    }

    /// La valeur de la ligne `<clé> = <valeur>` du service, sans espaces autour.
    private static func value(of key: String, in lines: [Substring]) -> String? {
        let prefix = "\(key) = "
        return lines.first { $0.hasPrefix(prefix) }.map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
    }

    /// Le PID de la ligne `pid = N`. Absente quand le processus ne tourne pas : `nil`.
    public static func pid(fromPrint text: String) -> pid_t? {
        guard let value = value(of: "pid", in: serviceLines(text)), let pid = pid_t(value), pid > 0 else { return nil }
        return pid
    }

    /// La fin du dernier lancement :
    /// - `last exit code = N` : sortie avec le code N. Les launchctl récents font suivre un code non nul d'un libellé
    ///   (`127: Unknown error: 127`, `78: EX_CONFIG`) : seul l'entier en tête compte ;
    /// - `last terminating signal = Terminated: 15` : arrêt par le signal 15 ;
    /// - `last exit code = (never exited)`, ou aucune des deux lignes : illisible, `nil`.
    ///
    /// Le code passe avant le signal quand les deux lignes sont là. Un travail lancé une seule fois (le cas de go2rtc :
    /// un `bootout` après chaque sortie) n'en a jamais qu'une.
    public static func lastExit(fromPrint text: String) -> ProcessExit? {
        let lines = serviceLines(text)
        if let code = value(of: "last exit code", in: lines), let status = Int32(code.prefix { $0 == "-" || ("0"..."9").contains($0) }) {
            return ProcessExit(status: status, signaled: false)
        }
        if let signal = value(of: "last terminating signal", in: lines),
            let number = signal.split(separator: ":").last.flatMap({ Int32($0.trimmingCharacters(in: .whitespaces)) }) {
            return ProcessExit(status: number, signaled: true)
        }
        return nil
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
