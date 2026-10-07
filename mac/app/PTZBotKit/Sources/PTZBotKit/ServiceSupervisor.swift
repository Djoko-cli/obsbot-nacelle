import Foundation
import Observation

/// Lance `ptzd`, processus enfant de l'app, le relance s'il s'arrête et l'arrête à la demande
/// (spec ptzd dans l'app § 5.3). « Actif » dans le panneau vient de la connexion de confiance (PanelModel) :
/// `running` veut seulement dire que le processus vit.
@MainActor
@Observable
public final class ServiceSupervisor {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running
        /// Arrêt inattendu ; relance prévue (n-ième relance de suite).
        case restarting(count: Int)
        case failed(reason: String)
    }

    /// Les chemins donnés à ptzd.
    public struct Paths: Equatable, Sendable {
        public var ptzd: URL
        public var ai: URL
        public var sdkDirectory: URL
        /// Journal de ptzd : sa sortie et ses erreurs y sont ajoutées.
        public var log: URL

        public init(ptzd: URL, ai: URL, sdkDirectory: URL, log: URL) {
            self.ptzd = ptzd
            self.ai = ai
            self.sdkDirectory = sdkDirectory
            self.log = log
        }
    }

    /// Délais de relance successifs ; le dernier se répète.
    public static let restartDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    /// Au-delà de `maxUnexpectedExits` arrêts inattendus en `failureWindow` secondes : `failed`.
    public static let maxUnexpectedExits = 5
    /// Un ptzd qui a tenu `failureWindow` secondes repart du premier délai.
    public static let failureWindow: TimeInterval = 120
    /// Délai entre SIGTERM et SIGKILL.
    public static let killDelay: TimeInterval = 5
    public static let enabledKey = "serviceEnabled"
    public static let crashLoopReason = "ptzd s'arrête sans cesse : ouvrez le journal"
    /// ptzd ne sort pas même après SIGKILL : l'arrêt est abandonné, ptzd n'est plus relancé par ce chemin.
    public static let unkillableReason = "ptzd ne s'arrête pas : ouvrez le journal"

    /// Codes de sortie de ptzd qui ne se corrigent pas en relançant : `failed`, sans relance.
    public static let busyStatus: Int32 = 75
    public static let configStatus: Int32 = 78
    public static let usageStatus: Int32 = 64
    public static let configReason = "config.json est invalide : ouvrez le journal"
    public static let usageReason = "Arguments de ptzd refusés"

    public static func busyReason(port: Int) -> String {
        "Le port \(port) est déjà pris : un autre ptzd tourne peut-être encore"
    }

    public private(set) var state: State = .stopped
    /// L'interrupteur « Service ptzd », retenu d'un lancement à l'autre ; allumé au premier lancement.
    public private(set) var isEnabled: Bool
    /// Une ancienne installation (agent launchd) est active : aucun ptzd n'est lancé (§ 5.6).
    public var legacyAgentActive = false
    /// Port de ptzd (config.json), pour le message d'un port déjà pris.
    public var port = PTZDConfig.defaultPort

    @ObservationIgnored private let paths: Paths
    @ObservationIgnored private let launcher: any ProcessLauncher
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private let parentPID: pid_t
    @ObservationIgnored private var process: (any LaunchedProcess)?
    @ObservationIgnored private var launchedAt: TimeInterval = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restartCount = 0
    @ObservationIgnored private var unexpectedExits: [TimeInterval] = []
    @ObservationIgnored private var pendingRestart: (any Cancellable)?
    @ObservationIgnored private var pendingKill: (any Cancellable)?
    /// Délai après SIGKILL : si ptzd vit encore, l'arrêt est abandonné (`unkillableReason`).
    @ObservationIgnored private var pendingWatchdog: (any Cancellable)?
    @ObservationIgnored private var stopping = false
    /// L'interrupteur a été rallumé pendant un arrêt : ptzd repart à la fin de l'arrêt.
    @ObservationIgnored private var restartAfterStop = false
    /// L'app se termine : plus aucun lancement.
    @ObservationIgnored private var quitting = false
    @ObservationIgnored private var stopCompletions: [@MainActor () -> Void] = []

    public init(
        paths: Paths,
        launcher: any ProcessLauncher,
        settings: any SettingsStore,
        scheduler: any Scheduler,
        parentPID: pid_t
    ) {
        self.paths = paths
        self.launcher = launcher
        self.settings = settings
        self.scheduler = scheduler
        self.parentPID = parentPID
        isEnabled = settings.bool(forKey: Self.enabledKey) ?? true
    }

    /// Le superviseur de l'app : vrai lanceur de processus, préférences de l'utilisateur, PID de l'app.
    public static func system(paths: Paths, scheduler: any Scheduler) -> ServiceSupervisor {
        ServiceSupervisor(
            paths: paths,
            launcher: FoundationProcessLauncher(),
            settings: UserDefaultsSettingsStore(defaults: .standard),
            scheduler: scheduler,
            parentPID: getpid()
        )
    }

    /// Les arguments de ptzd (§ 5.4).
    public var arguments: [String] {
        ["--parent", String(parentPID), "--ai", paths.ai.path, "--sdk", paths.sdkDirectory.path]
    }

    /// Lance ptzd s'il est autorisé, qu'aucun ancien agent n'est actif et qu'il ne tourne pas déjà.
    /// Depuis `failed`, repart de zéro.
    public func start() {
        guard isEnabled, !legacyAgentActive, !stopping, !quitting else { return }
        switch state {
        case .stopped, .failed:
            restartCount = 0
            unexpectedExits = []
            launch()
        case .starting, .running, .restarting:
            break
        }
    }

    /// SIGTERM, puis SIGKILL 5 s plus tard s'il vit encore ; `completion` quand ptzd est terminé.
    /// `forQuit` : l'app se termine, ptzd ne sera plus relancé, même si l'interrupteur est rallumé.
    public func stop(forQuit: Bool = false, completion: @escaping @MainActor () -> Void = {}) {
        if forQuit {
            quitting = true
        }
        restartAfterStop = false
        pendingRestart?.cancel()
        pendingRestart = nil
        guard let process else {
            state = .stopped
            completion()
            return
        }
        stopCompletions.append(completion)
        guard !stopping else { return }
        stopping = true
        process.terminate()
        pendingKill = scheduler.schedule(after: Self.killDelay) { [weak self] in
            guard let self, let process = self.process else { return }
            pendingKill = nil
            armWatchdog()
            process.kill()
        }
    }

    /// Après SIGKILL, ptzd doit sortir dans `killDelay` ; sinon l'arrêt est abandonné.
    /// Armé avant le SIGKILL : une fin synchrone l'annule dans `exited`.
    private func armWatchdog() {
        let killedGeneration = generation
        pendingWatchdog = scheduler.schedule(after: Self.killDelay) { [weak self] in
            guard let self, self.generation == killedGeneration, process != nil else { return }
            abandonStop()
        }
    }

    /// ptzd vit encore après SIGKILL : `failed`, arrêt signalé, aucune relance par ce chemin.
    private func abandonStop() {
        pendingWatchdog = nil
        process = nil
        stopping = false
        restartAfterStop = false
        state = .failed(reason: Self.unkillableReason)
        let completions = stopCompletions
        stopCompletions = []
        completions.forEach { $0() }
    }

    /// L'interrupteur « Service ptzd » : retenu, puis ptzd lancé ou arrêté.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        settings.set(enabled, forKey: Self.enabledKey)
        if enabled {
            if stopping {
                restartAfterStop = !quitting
            } else {
                start()
            }
        } else {
            stop()
        }
    }

    // MARK: - Processus

    private func launch() {
        state = .starting
        // Chaque lancement a son numéro : la fin d'un processus déjà remplacé est ignorée.
        generation += 1
        let launchedGeneration = generation
        let launched: any LaunchedProcess
        do {
            launched = try launcher.launch(executableURL: paths.ptzd, arguments: arguments, outputURL: paths.log) { [weak self] exit in
                guard let self, launchedGeneration == generation, process != nil else { return }
                exited(exit)
            }
        } catch {
            state = .failed(reason: "ptzd n'a pas pu être lancé : \(error.localizedDescription)")
            return
        }
        process = launched
        launchedAt = scheduler.now
        state = .running
    }

    private func exited(_ exit: ProcessExit) {
        process = nil
        pendingKill?.cancel()
        pendingKill = nil
        pendingWatchdog?.cancel()
        pendingWatchdog = nil
        if stopping {
            stopping = false
            state = .stopped
            let completions = stopCompletions
            stopCompletions = []
            completions.forEach { $0() }
            if restartAfterStop {
                restartAfterStop = false
                start()
            }
            return
        }
        if !exit.signaled, let reason = permanentFailure(exit.status) {
            state = .failed(reason: reason)
            return
        }
        unexpectedExit()
    }

    /// Une sortie qu'une relance ne corrigerait pas : port ou verrou pris, config.json invalide, arguments refusés.
    private func permanentFailure(_ status: Int32) -> String? {
        switch status {
        case Self.busyStatus: Self.busyReason(port: port)
        case Self.configStatus: Self.configReason
        case Self.usageStatus: Self.usageReason
        default: nil
        }
    }

    private func unexpectedExit() {
        let now = scheduler.now
        if now - launchedAt >= Self.failureWindow {
            // ptzd a tenu : les délais repartent du premier.
            restartCount = 0
        }
        unexpectedExits = unexpectedExits.filter { now - $0 < Self.failureWindow } + [now]
        guard unexpectedExits.count <= Self.maxUnexpectedExits else {
            state = .failed(reason: Self.crashLoopReason)
            return
        }
        restartCount += 1
        state = .restarting(count: restartCount)
        let delay = Self.restartDelays[min(restartCount, Self.restartDelays.count) - 1]
        pendingRestart = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            pendingRestart = nil
            guard case .restarting = state else { return }
            // Un ancien agent revenu pendant le délai : pas de lancement, et l'état le dit.
            guard isEnabled, !legacyAgentActive else {
                state = .stopped
                return
            }
            launch()
        }
    }
}
