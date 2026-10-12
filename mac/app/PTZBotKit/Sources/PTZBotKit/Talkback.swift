import Foundation
import Observation

/// Talkback : le retour audio de la caméra vers les haut-parleurs du Mac (spec haut-parleur). Un agent launchd
/// classique (une plist dans `~/Library/LaunchAgents`, que l'app écrit et charge par `launchctl`, voir `ClassicAgent`)
/// lance `talkd` ; l'interrupteur du panneau l'installe ou le retire, et l'agent continue de tourner quand PTZBot est fermé.
public enum Talkback {
    /// Le label de l'agent, celui de sa plist.
    public static let label = "io.github.djoko-cli.obsbot-nacelle.talkd"
    /// La plist embarquée dans l'app (`mac/app/LaunchAgents`, copiée dans `Contents/Library/LaunchAgents`). Depuis la 1.0.5
    /// elle ne sert plus qu'à désinscrire l'ancien agent de la 1.0.4 : `SMAppService.agent(plistName:)` en a besoin.
    public static var plistName: String {
        "\(label).plist"
    }
}

extension TalkbackService {
    /// Allumage par l'interrupteur.
    nonisolated func enable() async throws {
        try await enable(respectingRefusal: false)
    }
}

/// Ce que dit la plist de l'agent classique.
public enum TalkbackAgentState: Equatable, Sendable {
    /// Pas de plist : Talkback est éteint.
    case absent
    /// La plist est en place.
    case installed
    /// La plist est en place, mais l'utilisateur a coupé l'élément dans Réglages › Général › Ouverture.
    case requiresApproval
}

/// L'agent de Talkback tel que le modèle le voit, derrière un protocole pour les tests. Les opérations qui bloquent
/// (launchctl, attentes) sont `nonisolated` : elles ne tournent jamais sur le fil de l'interface.
@MainActor
public protocol TalkbackService: AnyObject, Sendable {
    /// Lecture rapide : la plist existe-t-elle, et l'utilisateur a-t-il coupé l'élément ?
    var agentState: TalkbackAgentState { get }
    /// Ce qui empêche d'allumer Talkback (PTZBot lancé depuis un emplacement temporaire) ; nil : rien. Lecture rapide.
    var installBlocker: (any Error)? { get }
    /// L'ancien agent de la 1.0.4, inscrit par `SMAppService.agent(plistName:)`, existe encore (`.enabled` ou `.requiresApproval`).
    var hasLegacyRegistration: Bool { get }
    /// L'ancien agent de la 1.0.4 attend l'accord de l'utilisateur (`.requiresApproval`) : il a coupé l'élément. À lire
    /// avant `unregisterLegacy()`.
    var legacyRequiresApproval: Bool { get }
    /// Écrit la plist et charge l'agent. Par défaut (l'interrupteur), le service est d'abord réactivé dans launchd
    /// (`launchctl enable`) ; `respectingRefusal` (migration d'un agent « Autorisation requise ») respecte le refus de
    /// l'utilisateur : pas de réactivation, et la plist est gardée si le chargement échoue.
    nonisolated func enable(respectingRefusal: Bool) async throws
    /// Décharge l'agent (attente bornée) et supprime la plist.
    nonisolated func disable() async throws
    /// Désinscrit l'ancien agent de la 1.0.4, en attendant la fin (`unregister()` asynchrone).
    nonisolated func unregisterLegacy() async throws
    /// Met l'agent en ordre au lancement : plist réécrite si elle diffère, `bootstrap` si l'agent n'est pas chargé, sinon
    /// `kickstart -k` si `restart`.
    nonisolated func reconcile(restart: Bool) async throws
    func openSystemSettings()
}

/// L'état que talkd écrit (`talkd-state.json`, même format que `TalkState` dans mac/talkd) : une prise de parole
/// est en lecture, depuis quand, le processus qui l'a écrit, et l'échec qui l'a arrêté au démarrage s'il y en a un
/// (`failure`, absent des anciens fichiers).
public struct TalkbackState: Codable, Equatable, Sendable {
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

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor
public protocol TalkbackStateSource: AnyObject {
    /// nil : fichier absent ou illisible.
    func read() -> TalkbackState?
}

/// Lit `talkd-state.json`.
@MainActor
public final class FileTalkbackStateSource: TalkbackStateSource {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() -> TalkbackState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? TalkbackState.decoder.decode(TalkbackState.self, from: data)
    }
}

/// Pourquoi talkd s'est arrêté au démarrage (champ `failure` de son état).
public enum TalkbackFailure: Equatable, Sendable {
    /// Le port UDP de talkd est déjà utilisé.
    case portBusy
    /// Une autre erreur de la socket.
    case socket
    /// Un code que cette version de l'app ne connaît pas.
    case other

    public init(code: String) {
        switch code {
        case "portBusy": self = .portBusy
        case "socket": self = .socket
        default: self = .other
        }
    }
}

/// Un processus existe-t-il ? (L'état d'un talkd arrêté ou tué reste dans le fichier.)
@MainActor
public protocol ProcessProbe: AnyObject {
    func isAlive(pid: Int32) -> Bool
}

@MainActor
public final class SystemProcessProbe: ProcessProbe {
    public init() {}

    /// `kill(pid, 0)` n'envoie rien : il dit seulement si le processus existe (EPERM : il existe, à un autre utilisateur).
    public func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

/// L'interrupteur « Talkback » et la ligne d'état dessous (spec haut-parleur § 6).
@MainActor
@Observable
public final class TalkbackModel {
    public enum Status: Equatable, Sendable {
        /// L'agent n'est pas installé.
        case disabled
        /// macOS attend l'accord de l'utilisateur dans Réglages › Général › Ouverture.
        case requiresApproval
        /// Installé, mais talkd n'a pas (encore) écrit son état : il démarre.
        case starting
        /// Installé, talkd tourne et attend.
        case ready
        /// Une prise de parole est en lecture.
        case playing
        /// talkd s'est arrêté sur un échec au démarrage (port occupé…) ; launchd le relance.
        case failed(TalkbackFailure)
        /// L'interrupteur vient d'être éteint : le déchargement est en cours (transitoire, symétrique de `.starting`).
        case stopping
        /// Installé, mais talkd n'a pas tourné depuis plus de 15 s (agent refusé par launchd, plantage…).
        case notRunning
    }

    /// Pendant que le panneau est ouvert, l'état est relu à cet intervalle (secondes).
    public static let pollInterval: TimeInterval = 1
    /// Un changement du fichier d'état déclenche une relecture après ce délai (secondes) : les changements rapprochés
    /// (état puis réécriture de talkd) n'en font qu'une.
    public static let changeDebounce: TimeInterval = 0.1
    /// Au-delà de ce délai en « Démarrage… » (secondes), talkd est dit « ne démarre pas ».
    public static let startupGrace: TimeInterval = 15

    public private(set) var status: Status = .disabled
    public private(set) var lastError: String?
    @ObservationIgnored private let service: any TalkbackService
    @ObservationIgnored private let state: any TalkbackStateSource
    @ObservationIgnored private let process: any ProcessProbe
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private let settings: any SettingsStore
    /// Le numéro de compilation de l'app qui tourne (`CFBundleVersion`) ; nil s'il est inconnu.
    @ObservationIgnored private let bundleVersion: String?
    @ObservationIgnored private var poll: (any Cancellable)?
    /// Surveille `talkd-state.json` pendant que le panneau est ouvert (nil : relecture périodique seule).
    @ObservationIgnored private let fileObserver: (any FileChangeObserver)?
    @ObservationIgnored private var observation: (any Cancellable)?
    /// La relecture regroupée qui attend son délai, si un changement du fichier vient d'arriver.
    @ObservationIgnored private var pendingRefresh: (any Cancellable)?
    /// L'opération d'allumage ou d'extinction en cours, pour `waitForOperation()`.
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var watching = false
    /// L'instant (horloge du `Scheduler`) du premier « Démarrage… » d'affilée.
    @ObservationIgnored private var startingSince: TimeInterval?
    /// Préparation de l'agent au lancement de l'app en cours (migration depuis la 1.0.4, ou mise à jour ; une à deux
    /// secondes, parfois plus avec un `launchctl` lent) : l'interrupteur est grisé et `setEnabled` sans effet, pour qu'un
    /// clic ne la contrarie pas (éteindre puis être rallumé d'office).
    public private(set) var isPreparing = false
    /// La migration est en cours : l'ancien agent est désinscrit avant que le nouveau soit installé, d'où « Démarrage… »
    /// plutôt que « Désactivé » entre les deux.
    @ObservationIgnored private var isMigrating = false
    @ObservationIgnored private var prepared = false
    /// Allumage ou extinction lancé par l'interrupteur, en cours hors du fil de l'interface : l'interrupteur est
    /// grisé, `setEnabled` sans effet, et `refresh` laisse l'état transitoire (« Démarrage… », « Arrêt… ») à l'écran.
    public private(set) var isBusy = false

    /// Le numéro de compilation d'une compilation de travail (`CFBundleVersion` du projet, sans numéro de publication).
    public static let workingBuildNumber = "1"
    /// La clé du réglage qui retient le numéro de compilation de l'app qui a, la dernière fois, installé ou mis en ordre
    /// l'agent classique : un autre numéro fait redémarrer talkd au lancement.
    public static let agentBuildKey = "talkbackAgentBuild"
    /// L'ancien réglage de la 1.0.4 (numéro de compilation de l'inscription par `SMAppService`) : plus utilisé, effacé
    /// au lancement.
    public static let obsoleteRegisteredBuildKey = "talkbackRegisteredBuild"
    /// L'installation à retenter au lancement suivant : la migration a désinscrit l'ancien agent mais l'installation du
    /// nouveau a échoué, il ne reste ni l'un ni l'autre. « enable » (Talkback était allumé) ou « respectRefusal »
    /// (l'utilisateur avait coupé l'élément : son refus reste respecté).
    public static let pendingInstallKey = "talkbackPendingInstall"
    private static let pendingEnable = "enable"
    private static let pendingRespectRefusal = "respectRefusal"

    public init(
        service: any TalkbackService, state: any TalkbackStateSource, process: any ProcessProbe, scheduler: any Scheduler,
        settings: any SettingsStore, bundleVersion: String?, fileObserver: (any FileChangeObserver)? = nil
    ) {
        self.service = service
        self.state = state
        self.process = process
        self.scheduler = scheduler
        self.settings = settings
        self.bundleVersion = bundleVersion
        self.fileObserver = fileObserver
        refresh()
    }

    /// L'interrupteur est allumé : l'agent est installé (même s'il attend l'accord de l'utilisateur). Pendant « Arrêt… »,
    /// il est déjà éteint.
    public var isEnabled: Bool {
        status != .disabled && status != .stopping
    }

    /// La ligne d'état demande l'attention (orange) : une action ou un coup d'œil au journal.
    public var needsAttention: Bool {
        switch status {
        case .requiresApproval, .failed, .notRunning: true
        case .disabled, .starting, .stopping, .ready, .playing: false
        }
    }

    public func refresh() {
        // Une opération en cours montre son état transitoire ; elle relit l'état réel en finissant.
        guard !isBusy else { return }
        var next = currentStatus()
        // Pendant la migration, l'agent est un instant désinscrit sans être encore installé : « Démarrage… » plutôt que
        // « Désactivé ».
        if isMigrating, next == .disabled {
            next = .starting
        }
        if next == .starting {
            let since = startingSince ?? scheduler.now
            startingSince = since
            // Pendant la préparation, toujours « Démarrage… » : l'interrupteur grisé dit déjà qu'on agit.
            status = !isPreparing && scheduler.now - since >= Self.startupGrace ? .notRunning : .starting
        } else {
            startingSince = nil
            status = next
        }
    }

    /// Le statut lu, avant le délai de grâce du démarrage.
    private func currentStatus() -> Status {
        switch service.agentState {
        case .absent:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .installed:
            guard let current = state.read() else { return .starting }
            // Un échec n'est écrit que juste avant `exit` : vivant ou non, ce talkd s'arrête.
            if let failure = current.failure {
                return .failed(TalkbackFailure(code: failure))
            }
            guard process.isAlive(pid: current.pid) else { return .starting }
            return current.speaking ? .playing : .ready
        }
    }

    /// Allume ou éteint l'interrupteur. Écrire la plist, charger ou décharger l'agent par `launchctl` peut durer une à
    /// deux secondes (jusqu'à dix pour un déchargement lent) : tout se fait hors du fil de l'interface, l'interrupteur
    /// bascule et « Démarrage… » ou « Arrêt… » s'affiche tout de suite. En cas d'échec, l'état réel est relu et l'erreur
    /// montrée. Sans effet pendant la préparation du lancement ou une autre opération.
    public func setEnabled(_ enabled: Bool) {
        guard !isPreparing, !isBusy else { return }
        lastError = nil
        // Éteindre reste permis ; allumer depuis un emplacement temporaire est refusé, sans rien changer.
        if enabled, let blocker = service.installBlocker {
            lastError = Localization.text("Talkback impossible : \(blocker.localizedDescription)")
            return
        }
        isBusy = true
        startingSince = nil
        status = enabled ? .starting : .stopping
        operation = Task { [weak self] in
            await self?.apply(enabled)
        }
    }

    /// Attend la fin de l'opération lancée par `setEnabled` (tests ; l'interface n'attend rien).
    public func waitForOperation() async {
        await operation?.value
    }

    private func apply(_ enabled: Bool) async {
        do {
            if enabled {
                try await service.enable(respectingRefusal: false)
                settings.set(bundleVersion, forKey: Self.agentBuildKey)
                settings.set(nil as String?, forKey: Self.pendingInstallKey)
            } else {
                try await service.disable()
                settings.set(nil as String?, forKey: Self.agentBuildKey)
                settings.set(nil as String?, forKey: Self.pendingInstallKey)
            }
        } catch {
            lastError = Localization.text("Talkback impossible : \(error.localizedDescription)")
        }
        isBusy = false
        operation = nil
        refresh()
        clearErrorIfApprovalNeeded()
    }

    /// Prépare l'agent au lancement de l'app, une fois par lancement (spec haut-parleur § 15) : l'appelant relit l'état
    /// (`refresh`) après coup. Tout se fait hors du fil de l'interface.
    ///
    /// **Migration depuis la 1.0.4.** La 1.0.4 inscrivait talkd par `SMAppService.agent(plistName:)`. Si cet agent est
    /// encore inscrit, il est désinscrit en attendant la fin, puis l'agent classique est installé : Talkback était
    /// allumé, il le reste. Éteint, rien n'est installé. L'ancien réglage du numéro d'inscription est effacé. Si
    /// l'utilisateur avait coupé l'élément (« Autorisation requise »), son refus est respecté : pas de `launchctl enable`,
    /// la plist est gardée même si le chargement échoue. Si l'installation échoue après la désinscription et que rien
    /// n'est installé, l'intention est retenue (`pendingInstallKey`) et retentée au lancement suivant, une fois par lancement.
    ///
    /// **Mise à jour.** Si la plist de l'agent classique existe, elle est réécrite quand son contenu diffère de celui
    /// attendu (l'app a changé de chemin), sinon l'agent est chargé s'il ne l'est pas, sinon talkd est redémarré (`kickstart -k`) quand le numéro de compilation
    /// de l'app n'est pas celui du dernier passage : le nouveau talkd remplace l'ancien encore en mémoire.
    ///
    /// Depuis un emplacement temporaire (`installBlocker`), rien du tout.
    ///
    /// Une compilation de travail (numéro 1) ne fait ni l'un ni l'autre : l'agent de l'app installée pointerait vers
    /// la copie de travail. Une seule tentative : en cas d'échec l'erreur est montrée, le numéro reste, rien n'est
    /// retenté.
    public func prepareAtLaunch() async {
        guard let bundleVersion, bundleVersion != Self.workingBuildNumber, !isBusy, !prepared else { return }
        prepared = true
        // PTZBot lancé depuis un emplacement temporaire (app translocalisée, image disque) : rien du tout, ni migration, ni
        // réécriture de la plist, ni redémarrage, ni numéro retenu. L'installation en place reste telle qu'elle est.
        guard service.installBlocker == nil else { return }
        settings.set(nil as String?, forKey: Self.obsoleteRegisteredBuildKey)
        let migrating = service.hasLegacyRegistration
        let pending = settings.string(forKey: Self.pendingInstallKey)
        // Une installation retenue ne se retente que si rien n'est installé ; sinon la plist en place passe d'abord.
        let retrying = !migrating && pending != nil && service.agentState == .absent
        guard migrating || retrying || service.agentState != .absent else { return }
        isPreparing = true
        isMigrating = migrating
        lastError = nil
        do {
            if migrating {
                // Lu avant la désinscription : l'ancien agent « Autorisation requise » dit que l'utilisateur l'a coupé.
                let respectRefusal = service.legacyRequiresApproval
                try await service.unregisterLegacy()
                // L'intention tient jusqu'à ce que l'installation réussisse : un échec ou une fermeture de l'app ici ne
                // doit pas la perdre (l'ancien agent n'existe plus).
                settings.set(respectRefusal ? Self.pendingRespectRefusal : Self.pendingEnable, forKey: Self.pendingInstallKey)
                try await service.enable(respectingRefusal: respectRefusal)
            } else if retrying {
                try await service.enable(respectingRefusal: pending == Self.pendingRespectRefusal)
            } else {
                settings.set(nil as String?, forKey: Self.pendingInstallKey)
                try await service.reconcile(restart: settings.string(forKey: Self.agentBuildKey) != bundleVersion)
            }
            settings.set(nil as String?, forKey: Self.pendingInstallKey)
            settings.set(bundleVersion, forKey: Self.agentBuildKey)
        } catch {
            lastError = Localization.text("Talkback impossible : \(error.localizedDescription)")
            // Une plist gardée (refus respecté) sera remise en ordre au lancement suivant : rien à retenir de plus.
            if service.agentState != .absent {
                settings.set(nil as String?, forKey: Self.pendingInstallKey)
            }
        }
        isMigrating = false
        isPreparing = false
        // Le délai de 15 s repart de la fin de la préparation : talkd a besoin d'un instant pour démarrer.
        startingSince = nil
        refresh()
        clearErrorIfApprovalNeeded()
    }

    /// L'invitation à autoriser dit déjà ce qu'il y a à faire.
    private func clearErrorIfApprovalNeeded() {
        if status == .requiresApproval {
            lastError = nil
        }
    }

    public func openSystemSettings() {
        service.openSystemSettings()
    }

    /// Panneau ouvert : l'état est relu dès que talkd réécrit son fichier, et chaque seconde en filet de sécurité
    /// (« En lecture »).
    public func beginWatching() {
        refresh()
        guard !watching else { return }
        watching = true
        scheduleNextPoll()
        observation = fileObserver?.observe { [weak self] in
            self?.stateFileChanged()
        }
    }

    /// Panneau fermé : plus rien n'est relu ni surveillé.
    public func endWatching() {
        watching = false
        poll?.cancel()
        poll = nil
        observation?.cancel()
        observation = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    /// Le fichier d'état a changé : une relecture dans `changeDebounce`, les changements rapprochés n'en font qu'une.
    private func stateFileChanged() {
        guard watching, pendingRefresh == nil else { return }
        pendingRefresh = scheduler.schedule(after: Self.changeDebounce) { [weak self] in
            guard let self else { return }
            pendingRefresh = nil
            guard watching else { return }
            refresh()
        }
    }

    private func scheduleNextPoll() {
        poll = scheduler.schedule(after: Self.pollInterval) { [weak self] in
            guard let self, watching else { return }
            refresh()
            scheduleNextPoll()
        }
    }
}

/// Les textes de Talkback, au vouvoiement, traduits en anglais (spec distribution § 7.1).
extension Labels {
    /// La ligne d'état sous l'interrupteur.
    public static func talkbackStatus(_ status: TalkbackModel.Status) -> String {
        switch status {
        case .disabled: Localization.text("Désactivé")
        case .requiresApproval: Localization.text("Autorisation requise")
        case .starting: Localization.text("Démarrage…")
        case .stopping: Localization.text("Arrêt…")
        case .ready: Localization.text("Prêt")
        case .playing: Localization.text("En lecture")
        case .failed(.portBusy): Localization.text("Arrêté : le port UDP est déjà utilisé (voir le journal)")
        case .failed(.socket): Localization.text("Arrêté : erreur réseau (voir le journal)")
        case .failed(.other): Localization.text("Arrêté (voir le journal)")
        case .notRunning: Localization.text("talkd ne démarre pas (voir le journal)")
        }
    }

    /// Le bouton qui ouvre Réglages › Général › Ouverture quand macOS attend l'accord.
    public static var talkbackApproval: String { Localization.text("Autorisez Talkback dans Réglages › Général › Ouverture") }
}

