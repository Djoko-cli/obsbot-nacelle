import Foundation

/// Pourquoi l'agent de talkd n'a pas pu être arrêté avant d'être rechargé ou supprimé.
public enum ClassicAgentError: LocalizedError, Equatable, Sendable {
    case bootoutFailed(String)
    /// L'agent est encore chargé 10 s après le `bootout`.
    case stillLoaded

    public var errorDescription: String? {
        switch self {
        case let .bootoutFailed(reason): Localization.text("talkd n'a pas pu être arrêté : \(reason)")
        case .stillLoaded: Localization.text("talkd ne s'est pas arrêté à temps.")
        }
    }
}

/// L'agent launchd de talkd, installé par l'app : une plist dans `~/Library/LaunchAgents`, chargée par `launchctl`
/// (spec haut-parleur § 15).
///
/// Pourquoi pas `SMAppService.agent(plistName:)` : l'app est signée par un certificat auto-signé, sans Team ID. macOS
/// épingle alors à l'agent inscrit le binaire `talkd` d'alors, puis launchd refuse le nouveau après toute mise à jour
/// (« Launch Constraint Violation »). Un agent classique, au `ProgramArguments` absolu, n'a aucune contrainte de
/// lancement : BTM le range parmi les « legacy agents ». Il continue de tourner quand PTZBot est fermé.
///
/// Bloquant (launchctl, attente) : à appeler hors du fil de l'interface (`ClassicTalkbackService`).
public struct ClassicAgent: Sendable {
    /// launchd peut mettre plusieurs secondes à décharger un agent.
    public static let stopTimeout: TimeInterval = LegacyAgent.stopTimeout
    public static let pollInterval: TimeInterval = LegacyAgent.pollInterval

    public let label: String
    public let launchAgentsDirectory: URL
    /// Le chemin absolu de `Contents/Helpers/talkd` de l'app qui tourne.
    public let program: URL
    private let launchctl: any Launchctl
    private let sleep: @Sendable (TimeInterval) -> Void

    public init(
        label: String,
        launchAgentsDirectory: URL,
        program: URL,
        launchctl: any Launchctl,
        sleep: @escaping @Sendable (TimeInterval) -> Void
    ) {
        self.label = label
        self.launchAgentsDirectory = launchAgentsDirectory
        self.program = program
        self.launchctl = launchctl
        self.sleep = sleep
    }

    /// L'agent du Mac : vrai `~/Library/LaunchAgents`, vrai launchctl. Pour l'app seulement ; les tests passent un
    /// dossier temporaire et un `launchctl` simulé.
    public static func system(program: URL) -> ClassicAgent {
        ClassicAgent(
            label: Talkback.label,
            launchAgentsDirectory: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents"),
            program: program,
            launchctl: SystemLaunchctl(),
            sleep: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    public var plistURL: URL {
        launchAgentsDirectory.appending(path: "\(label).plist")
    }

    public var plistExists: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    // MARK: - La plist

    /// Le contenu attendu de la plist.
    var expectedPlist: NSDictionary {
        [
            "Label": label,
            // Chemin absolu : l'agent classique n'a pas de `BundleProgram` relatif à l'app.
            "ProgramArguments": [program.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            // Au moins 10 s entre deux lancements : une relance en rafale créerait une rafale de clients CoreAudio
            // (spec haut-parleur § 10).
            "ThrottleInterval": 10,
            // Standard dégradait le son des enfants de go2rtc sous launchd, Background faisait saccader la vidéo.
            "ProcessType": "Interactive",
        ]
    }

    /// La plist en place est-elle celle qu'on écrirait aujourd'hui ? (Même chemin d'app, mêmes clés.) Illisible : non.
    func plistMatches() -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
            let current = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
        else { return false }
        return current == expectedPlist
    }

    /// Écrit la plist (XML, de façon atomique, en 0644) ; le dossier est créé au besoin.
    private func writePlist() throws {
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: expectedPlist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
    }

    // MARK: - launchd

    /// Décharge l'agent s'il est chargé, et attend que launchd ait fini (10 s au plus). Un `bootout` en échec ne compte
    /// pas si l'agent est bien parti (déjà en cours d'arrêt) : seul compte qu'il ne soit plus chargé.
    private func unload() throws {
        guard launchctl.isLoaded(label: label) else { return }
        do {
            try launchctl.bootout(label: label)
        } catch {
            guard !launchctl.isLoaded(label: label) else {
                throw ClassicAgentError.bootoutFailed(error.localizedDescription)
            }
        }
        var waited: TimeInterval = 0
        while launchctl.isLoaded(label: label) {
            guard waited < Self.stopTimeout else { throw ClassicAgentError.stillLoaded }
            sleep(Self.pollInterval)
            waited += Self.pollInterval
        }
    }

    /// Allume : écrit la plist, décharge un agent déjà chargé (un `bootstrap` échoue sur un agent chargé), puis le
    /// charge. Si le `bootstrap` échoue, la plist est retirée : l'interrupteur revient à « Désactivé » avec l'erreur,
    /// et non à un agent « installé » qui ne tourne pas.
    public func install() throws {
        try writePlist()
        try unload()
        do {
            try launchctl.bootstrap(plist: plistURL)
        } catch {
            try? FileManager.default.removeItem(at: plistURL)
            throw error
        }
    }

    /// Éteint : décharge l'agent, attend, puis supprime la plist. Si l'agent ne se décharge pas, la plist reste : il
    /// est toujours là, et l'état le dit.
    public func uninstall() throws {
        try unload()
        if plistExists {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    /// Au lancement de l'app (spec haut-parleur § 15), si la plist existe :
    /// - elle diffère de celle qu'on écrirait aujourd'hui (l'app a changé de chemin, ou les clés ont changé) : elle est
    ///   réécrite, puis l'agent est déchargé et rechargé ;
    /// - sinon, si `restart` (le numéro de compilation de l'app a changé) : `kickstart -k`, pour que le nouveau talkd
    ///   remplace l'ancien encore en mémoire. Un binaire remplacé sur place ne demande rien d'autre.
    ///
    /// Sans plist, rien : Talkback est éteint.
    public func reconcile(restart: Bool) throws {
        guard plistExists else { return }
        if !plistMatches() {
            try writePlist()
            try unload()
            try launchctl.bootstrap(plist: plistURL)
        } else if restart {
            try launchctl.kickstart(label: label)
        }
    }
}
