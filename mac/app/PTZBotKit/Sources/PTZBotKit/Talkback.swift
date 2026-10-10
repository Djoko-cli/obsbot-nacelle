import Foundation
import Observation
import ServiceManagement

/// Talkback : le retour audio de la caméra vers les haut-parleurs du Mac (spec haut-parleur). Un agent launchd
/// embarqué dans l'app (`Contents/Library/LaunchAgents`) lance `talkd` ; l'interrupteur du panneau l'inscrit ou le
/// désinscrit, et l'agent continue de tourner quand PTZBot est fermé.
public enum Talkback {
    /// Le label de l'agent, celui de sa plist (`mac/app/LaunchAgents`).
    public static let label = "io.github.djoko-cli.obsbot-nacelle.talkd"
    public static var plistName: String {
        "\(label).plist"
    }
}

/// Implémentation réelle de l'inscription de l'agent : `SMAppService.agent(plistName:)`, comme `MainAppLoginItem`
/// pour l'app (même protocole, donc mêmes tests).
@MainActor
public final class TalkbackAgent: LoginItemService {
    private var service: SMAppService {
        SMAppService.agent(plistName: Talkback.plistName)
    }

    public init() {}

    public var status: SMAppService.Status {
        service.status
    }

    public func register() throws {
        try service.register()
    }

    public func unregister() throws {
        try service.unregister()
    }

    public func unregisterAndWait() async throws {
        try await service.unregister()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
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
        /// L'agent n'est pas inscrit.
        case disabled
        /// Une inscription a échoué, par exemple parce que l'agent n'est pas dans l'app (compilation sans agent) :
        /// l'interrupteur reste utilisable pour réessayer. `notFound` seul, avant toute inscription, donne `.disabled`.
        case unavailable
        /// macOS attend l'accord de l'utilisateur dans Réglages › Général › Ouverture.
        case requiresApproval
        /// Inscrit, mais talkd n'a pas (encore) écrit son état : il démarre.
        case starting
        /// Inscrit, talkd tourne et attend.
        case ready
        /// Une prise de parole est en lecture.
        case playing
        /// talkd s'est arrêté sur un échec au démarrage (port occupé…) ; launchd le relance.
        case failed(TalkbackFailure)
        /// Inscrit, mais talkd n'a pas tourné depuis plus de 15 s (agent refusé par launchd, plantage…).
        case notRunning
    }

    /// Pendant que le panneau est ouvert, l'état est relu à cet intervalle (secondes).
    public static let pollInterval: TimeInterval = 1
    /// Au-delà de ce délai en « Démarrage… » (secondes), talkd est dit « ne démarre pas ».
    public static let startupGrace: TimeInterval = 15

    public private(set) var status: Status = .disabled
    public private(set) var lastError: String?
    @ObservationIgnored private let service: any LoginItemService
    @ObservationIgnored private let state: any TalkbackStateSource
    @ObservationIgnored private let process: any ProcessProbe
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private let settings: any SettingsStore
    /// Le numéro de compilation de l'app qui tourne (`CFBundleVersion`) ; nil s'il est inconnu.
    @ObservationIgnored private let bundleVersion: String?
    @ObservationIgnored private var poll: (any Cancellable)?
    @ObservationIgnored private var watching = false
    /// L'instant (horloge du `Scheduler`) du premier « Démarrage… » d'affilée.
    @ObservationIgnored private var startingSince: TimeInterval?
    /// L'agent a été réinscrit par la mise à jour pendant ce lancement, et talkd n'a pas encore tourné depuis.
    @ObservationIgnored private var reregisteredThisLaunch = false
    /// Réinscription automatique en cours (environ une seconde au lancement d'une nouvelle version) : l'interrupteur est
    /// grisé et `setEnabled` sans effet, pour qu'un clic ne la contrarie pas (éteindre puis être rallumé d'office, ou
    /// une erreur « déjà inscrit »).
    public private(set) var isReregistering = false
    /// `lastError` porte l'avis de redémarrage (`Labels.talkbackRestartAdvice`) : il disparaît quand talkd repart.
    @ObservationIgnored private var restartAdviceShown = false

    /// Le numéro de compilation d'une compilation de travail (`CFBundleVersion` du projet, sans numéro de publication).
    public static let workingBuildNumber = "1"
    /// La clé du réglage qui retient le numéro de compilation pour lequel l'agent a été inscrit.
    public static let registeredBuildKey = "talkbackRegisteredBuild"

    public init(
        service: any LoginItemService, state: any TalkbackStateSource, process: any ProcessProbe, scheduler: any Scheduler,
        settings: any SettingsStore, bundleVersion: String?
    ) {
        self.service = service
        self.state = state
        self.process = process
        self.scheduler = scheduler
        self.settings = settings
        self.bundleVersion = bundleVersion
        refresh()
    }

    /// L'interrupteur est allumé : l'agent est inscrit (même s'il attend l'accord de l'utilisateur).
    public var isEnabled: Bool {
        status != .disabled && status != .unavailable
    }

    /// La ligne d'état demande l'attention (orange) : une action ou un coup d'œil au journal.
    public var needsAttention: Bool {
        switch status {
        case .requiresApproval, .failed, .notRunning: true
        case .disabled, .unavailable, .starting, .ready, .playing: false
        }
    }

    public func refresh() {
        let next = currentStatus()
        if next == .starting {
            let since = startingSince ?? scheduler.now
            startingSince = since
            status = scheduler.now - since >= Self.startupGrace ? .notRunning : .starting
        } else {
            startingSince = nil
            status = next
        }
        updateRestartAdvice()
    }

    /// Après une réinscription faite par la mise à jour, un talkd qui ne repart pas (`.notRunning`) reçoit l'avis du
    /// remède trouvé au banc du 09/10 : éteindre puis rallumer Talkback. Pas de nouvelle tentative automatique, qui
    /// risquerait une boucle. L'avis s'efface quand talkd tourne, et il ne remplace jamais une autre erreur.
    private func updateRestartAdvice() {
        switch status {
        case .notRunning:
            if reregisteredThisLaunch, lastError == nil {
                lastError = Labels.talkbackRestartAdvice
                restartAdviceShown = true
            }
        case .ready, .playing:
            reregisteredThisLaunch = false
            clearRestartAdvice()
        case .disabled, .unavailable, .requiresApproval, .starting, .failed:
            clearRestartAdvice()
        }
    }

    private func clearRestartAdvice() {
        guard restartAdviceShown else { return }
        restartAdviceShown = false
        if lastError == Labels.talkbackRestartAdvice { lastError = nil }
    }

    /// La dernière inscription a échoué : avec « introuvable », l'agent est alors vraiment indisponible.
    private var registerFailed = false

    /// Le statut lu, avant le délai de grâce du démarrage.
    private func currentStatus() -> Status {
        switch service.status {
        case .notRegistered:
            return .disabled
        case .notFound:
            // macOS répond « introuvable » pour un agent jamais inscrit, même présent dans l'app : l'interrupteur reste
            // utilisable. Seule une inscription refusée dans cet état dit l'agent vraiment indisponible.
            return registerFailed ? .unavailable : .disabled
        case .requiresApproval:
            return .requiresApproval
        case .enabled:
            guard let current = state.read() else { return .starting }
            // Un échec n'est écrit que juste avant `exit` : vivant ou non, ce talkd s'arrête.
            if let failure = current.failure {
                return .failed(TalkbackFailure(code: failure))
            }
            guard process.isAlive(pid: current.pid) else { return .starting }
            return current.speaking ? .playing : .ready
        @unknown default:
            return .disabled
        }
    }

    public func setEnabled(_ enabled: Bool) {
        guard !isReregistering else { return }
        lastError = nil
        // Éteindre puis rallumer est le remède de l'avis : il n'a plus lieu d'être.
        reregisteredThisLaunch = false
        restartAdviceShown = false
        do {
            if enabled {
                try service.register()
                registerFailed = false
                settings.set(bundleVersion, forKey: Self.registeredBuildKey)
            } else {
                try service.unregister()
                settings.set(nil as String?, forKey: Self.registeredBuildKey)
            }
        } catch {
            if enabled { registerFailed = true }
            lastError = Localization.text("Talkback impossible : \(error.localizedDescription)")
        }
        refresh()
        clearErrorIfApprovalNeeded()
    }

    /// Réinscrit l'agent après une mise à jour de l'app, à appeler une fois au lancement.
    ///
    /// Pourquoi : l'app est signée par un certificat auto-signé, sans Team ID. macOS attache alors à l'agent une
    /// contrainte de lancement qui épingle le binaire `talkd` tel qu'il était à l'inscription. Après une mise à jour
    /// (Sparkle), le nouveau `talkd` viole cette contrainte et launchd le refuse (« Launch Constraint Violation »,
    /// état « spawn failed »). Désinscrire puis réinscrire l'agent depuis la nouvelle app règle le problème.
    ///
    /// Seulement si l'agent est inscrit (`.enabled` ou `.requiresApproval`) et si le numéro de compilation retenu à
    /// l'inscription diffère de celui de l'app, ou manque (agent inscrit par une version qui ne le retenait pas). Une
    /// compilation de travail (numéro 1) ne réinscrit jamais d'elle-même : elle déplacerait l'agent de l'app publiée vers
    /// sa propre copie (même identifiant, autre emplacement : `BTMErrorDomain -95` au banc du 09/10). L'app publiée, mise
    /// à jour sur place par Sparkle, reprend l'agent après une bascule faite depuis une copie de travail.
    /// Une seule tentative par lancement : en cas d'échec l'erreur est montrée, le numéro reste, rien n'est retenté.
    /// La désinscription est attendue avant l'inscription : l'appelant relit l'état (`refresh`) après coup.
    public func reregisterIfUpdated() async {
        guard let bundleVersion, bundleVersion != Self.workingBuildNumber else { return }
        let registered = service.status == .enabled || service.status == .requiresApproval
        guard registered, settings.string(forKey: Self.registeredBuildKey) != bundleVersion else { return }
        isReregistering = true
        defer { isReregistering = false }
        lastError = nil
        do {
            // On attend la fin de la désinscription : launchd démonte encore l'ancien job, et réinscrire avant risque un
            // refus, ou un agent « inscrit » mais pas chargé (`SMAppService.h`).
            try await service.unregisterAndWait()
            try service.register()
            settings.set(bundleVersion, forKey: Self.registeredBuildKey)
            reregisteredThisLaunch = true
        } catch {
            lastError = Localization.text("Talkback impossible : \(error.localizedDescription)")
        }
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

    /// Panneau ouvert : l'état est relu chaque seconde (« En lecture »).
    public func beginWatching() {
        refresh()
        guard !watching else { return }
        watching = true
        scheduleNextPoll()
    }

    /// Panneau fermé : plus rien n'est relu.
    public func endWatching() {
        watching = false
        poll?.cancel()
        poll = nil
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
        case .unavailable: Localization.text("Indisponible")
        case .requiresApproval: Localization.text("Autorisation requise")
        case .starting: Localization.text("Démarrage…")
        case .ready: Localization.text("Prêt")
        case .playing: Localization.text("En lecture")
        case .failed(.portBusy): Localization.text("Arrêté : le port UDP est déjà utilisé (voir le journal)")
        case .failed(.socket): Localization.text("Arrêté : erreur réseau (voir le journal)")
        case .failed(.other): Localization.text("Arrêté (voir le journal)")
        case .notRunning: Localization.text("talkd ne démarre pas (voir le journal)")
        }
    }

    /// L'avis quand talkd ne repart pas après une réinscription faite par la mise à jour : le remède du banc du 09/10.
    public static var talkbackRestartAdvice: String {
        Localization.text("Talkback n'a pas redémarré après la mise à jour : éteignez puis rallumez Talkback.")
    }

    /// Le bouton qui ouvre Réglages › Général › Ouverture quand macOS attend l'accord.
    public static var talkbackApproval: String { Localization.text("Autorisez Talkback dans Réglages › Général › Ouverture") }
}
