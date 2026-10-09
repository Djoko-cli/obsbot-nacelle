import Foundation

/// Les durées de la spec haut-parleur (§ 5.2 et § 5.3), en secondes.
public enum TalkTiming {
    /// Une prise de parole finit après 2 s sans voix.
    public static let speechEnd: TimeInterval = 2
    /// La lecture s'arrête après 10 s sans voix, pour ne pas garder les haut-parleurs occupés.
    public static let outputIdle: TimeInterval = 10
    /// Un paquet refusé est journalisé une fois par minute au plus, par source.
    public static let rejectionLogInterval: TimeInterval = 60
    /// Et au plus 10 lignes de refus par minute, toutes sources confondues : des adresses usurpées en nombre ne
    /// remplissent pas le journal. Les refus restent comptés.
    public static let rejectionLogBudget = 10
}

/// Le cœur de talkd (spec haut-parleur § 5) : filtre, détection de voix, une source à la fois, tampon, volume
/// minimum, lecture, état pour l'app et journal. Tout ce qui touche le monde (réseau, moteur audio, volume, liste des
/// périphériques, horloge, disque) passe par un protocole : rien ici ne fait de bruit.
///
/// Les paquets arrivent par `receive(_:from:)`, sur la file principale. Un seul client CoreAudio, permanent : la
/// lecture est démarrée à la première voix et arrêtée 10 s après la dernière (`AudioOutputUnitStop` puis `Start` gardent
/// le même client, spec § 4.2) ; un échec de la sortie n'est jamais retenté en boucle, seulement à la prise de parole
/// suivante.
@MainActor
public final class TalkController {
    /// Totaux depuis le démarrage.
    public struct Counters: Equatable, Sendable {
        public var speeches = 0
        public var rejectedSource = 0
        public var rejectedSize = 0
        /// Paquets d'une autre source pendant une prise de parole.
        public var rejectedConcurrent = 0
        /// Paquets sans voix reçus hors prise de parole (non joués).
        public var ignoredIdle = 0
        /// Paquets reçus pendant le frein au démarrage (non joués).
        public var ignoredBraked = 0
    }

    /// Une prise de parole en cours.
    private struct Speech {
        var source: String
        var startedAt: TimeInterval
        var lastVoiceAt: TimeInterval
        var playing = false
        var concurrent = 0
        var droppedAtStart: Int
        var volume: VolumeGuard?
    }

    private struct RejectionLimiter {
        var lastLog: TimeInterval?
        var pending = 0
    }

    public private(set) var counters = Counters()
    public var isSpeaking: Bool {
        speech != nil
    }

    private let settings: TalkSettings
    private let filter: PacketFilter
    private let catalog: any DeviceCatalog
    private let output: any AudioOutput
    private let volume: any SpeakerVolume
    private let stateStore: any TalkStateStore
    private let recovery: any VolumeRecoveryStore
    private let scheduler: any Scheduler
    private let now: () -> Date
    private let processID: Int32
    private let log: LogSink
    private let buffer = JitterBuffer()

    private var speaker: AudioDeviceInfo?
    private var outputDevice: DeviceID?
    private var speech: Speech?
    private var endCheck: (any Cancellable)?
    private var idleStop: (any Cancellable)?
    private var catalogObservation: (any Cancellable)?
    /// Le démarrage différé par le frein ; nil quand la phase CoreAudio a commencé (ou sans frein).
    private var brakeRelease: (any Cancellable)?
    private var braked = false
    private var rejections: [String: RejectionLimiter] = [:]
    private var rejectionWindowStart: TimeInterval?
    private var rejectionLinesInWindow = 0
    private var rejectionLinesSuppressed = 0

    public init(
        settings: TalkSettings,
        catalog: any DeviceCatalog,
        output: any AudioOutput,
        volume: any SpeakerVolume,
        stateStore: any TalkStateStore,
        recovery: any VolumeRecoveryStore,
        scheduler: any Scheduler,
        now: @escaping () -> Date = Date.init,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        log: @escaping LogSink
    ) {
        self.settings = settings
        filter = PacketFilter(allowedSources: settings.allowedSources)
        self.catalog = catalog
        self.output = output
        self.volume = volume
        self.stateStore = stateStore
        self.recovery = recovery
        self.scheduler = scheduler
        self.now = now
        self.processID = processID
        self.log = log
    }

    /// Au démarrage du daemon, après la liaison du port : la phase CoreAudio (`start()`) commence aussitôt, ou après le
    /// délai du frein (relecture I4). Pendant ce délai, l'état « au repos » est écrit (rien de CoreAudio), et les
    /// paquets sont ignorés et comptés. `onCoreAudioPhase` est appelé juste avant la phase, pour la noter.
    public func start(braking decision: StartupBrake.Decision, onCoreAudioPhase: @escaping @MainActor () -> Void) {
        guard decision.delay > 0 else {
            onCoreAudioPhase()
            start()
            return
        }
        braked = true
        log("Frein au démarrage : \(decision.shortRuns) démarrages rapides de suite ; la lecture commence dans "
            + "\(Int(decision.delay)) s, les paquets reçus d'ici là sont ignorés.")
        writeState(speaking: false)
        brakeRelease = scheduler.schedule(after: decision.delay) { [weak self] in
            guard let self, braked else { return }
            brakeRelease = nil
            braked = false
            if counters.ignoredBraked > 0 {
                log("Fin du frein au démarrage : \(counters.ignoredBraked) paquets ignorés pendant le délai.")
            }
            onCoreAudioPhase()
            start()
        }
    }

    /// Au démarrage du daemon : réglages journalisés, haut-parleurs cherchés, volume rétabli si un talkd précédent est
    /// tombé en pleine parole (fichier de reprise), état « au repos » écrit.
    public func start() {
        log("talkd démarre : port \(settings.port), sources autorisées \(settings.allowedSources.joined(separator: ", ")), "
            + "volume minimum \(Int((settings.volumeFloor * 100).rounded())) %, seuil de voix \(settings.voiceThreshold).")
        catalogObservation = catalog.observeChanges { [weak self] in self?.devicesChanged() }
        locateSpeaker(announce: true)
        VolumeGuard.recover(from: recovery, speaker: speaker, volume: volume, log: log)
        writeState(speaking: false)
    }

    /// À l'arrêt du daemon (SIGTERM) : la prise de parole en cours est finie (volume rétabli), la lecture arrêtée.
    public func shutdown() {
        brakeRelease?.cancel()
        brakeRelease = nil
        braked = false
        catalogObservation?.cancel()
        catalogObservation = nil
        if speech != nil {
            endSpeech()
        }
        endCheck?.cancel()
        endCheck = nil
        idleStop?.cancel()
        idleStop = nil
        if output.isRunning {
            output.stop()
        }
        outputDevice = nil
        writeState(speaking: false)
        log("talkd s'arrête.")
    }

    // MARK: - Paquets

    /// Un paquet UDP reçu de `source` (adresse IPv4).
    public func receive(_ packet: Data, from source: String) {
        receive(Datagram(packet, from: source))
    }

    /// Un datagramme remis par `UDPReceiver` ; un datagramme trop gros n'a pas été copié (`payload` nil) : il est
    /// jugé sur sa taille réelle.
    public func receive(_ datagram: Datagram) {
        guard !braked else {
            counters.ignoredBraked += 1
            return
        }
        let source = datagram.source
        switch filter.verdict(size: datagram.size, from: source) {
        case .unauthorizedSource:
            counters.rejectedSource += 1
            noteRejection(key: "source:\(source)") { "Paquets ignorés : source \(source) non autorisée (\($0))." }
            return
        case .badSize:
            counters.rejectedSize += 1
            noteRejection(key: "size:\(source)") { "Paquets ignorés : taille anormale venant de \(source) (\($0))." }
            return
        case .accepted:
            break
        }
        guard let packet = datagram.payload else {
            // Impossible avec le filtre actuel (plus de 4 Ko = taille anormale) : refusé par prudence.
            counters.rejectedSize += 1
            return
        }
        let hasVoice = VoiceDetector.hasVoice(packet, threshold: settings.voiceThreshold)
        if var current = speech {
            guard current.source == source else {
                counters.rejectedConcurrent += 1
                current.concurrent += 1
                speech = current
                return
            }
            if hasVoice {
                current.lastVoiceAt = scheduler.now
                speech = current
            }
            if current.playing {
                buffer.push(packet)
            }
        } else if hasVoice {
            beginSpeech(source: source)
            if speech?.playing == true {
                buffer.push(packet)
            }
        } else {
            counters.ignoredIdle += 1
        }
    }

    /// Journalise un refus une fois par minute au plus, par source, avec le nombre de paquets depuis la ligne précédente.
    private func noteRejection(key: String, line: (Int) -> String) {
        if rejections[key] == nil, rejections.count >= 256 {
            rejections.removeAll()
        }
        var limiter = rejections[key] ?? RejectionLimiter()
        limiter.pending += 1
        if limiter.lastLog.map({ scheduler.now - $0 >= TalkTiming.rejectionLogInterval }) ?? true {
            if withinRejectionBudget() {
                log(line(limiter.pending))
            }
            limiter.lastLog = scheduler.now
            limiter.pending = 0
        }
        rejections[key] = limiter
    }

    /// Reste-t-il une ligne de refus à écrire dans la minute en cours ? À la minute suivante, le nombre de lignes tues est dit.
    private func withinRejectionBudget() -> Bool {
        let at = scheduler.now
        if rejectionWindowStart.map({ at - $0 >= TalkTiming.rejectionLogInterval }) ?? true {
            if rejectionLinesSuppressed > 0 {
                log("\(rejectionLinesSuppressed) lignes de refus tues la minute précédente (trop de sources différentes).")
                rejectionLinesSuppressed = 0
            }
            rejectionWindowStart = at
            rejectionLinesInWindow = 0
        }
        guard rejectionLinesInWindow < TalkTiming.rejectionLogBudget else {
            rejectionLinesSuppressed += 1
            return false
        }
        rejectionLinesInWindow += 1
        return true
    }

    // MARK: - Prise de parole

    private func beginSpeech(source: String) {
        idleStop?.cancel()
        idleStop = nil
        let at = scheduler.now
        counters.speeches += 1
        speech = Speech(source: source, startedAt: at, lastVoiceAt: at, droppedAtStart: buffer.droppedSamples)
        log("Prise de parole de \(source).")
        scheduleEndCheck(after: TalkTiming.speechEnd)

        if speaker == nil {
            locateSpeaker(announce: false)
        }
        guard let speaker else {
            log("Haut-parleurs intégrés introuvables : rien n'est joué (nouvel essai à la prochaine prise de parole).")
            return
        }
        buffer.reset()
        // Ouverte par talkd et jamais arrêtée par lui : le système l'a arrêtée (changement de configuration audio).
        if outputDevice != nil, !output.isRunning {
            log("La sortie s'était arrêtée d'elle-même (changement de configuration audio ?) : elle est redémarrée.")
            outputDevice = nil
        }
        // La liste a changé depuis l'ouverture de la sortie : elle est rouverte sur le nouveau périphérique.
        if output.isRunning, outputDevice != speaker.id {
            output.stop()
            outputDevice = nil
        }
        if !output.isRunning {
            do {
                try output.start(device: speaker.id, feeding: buffer)
                outputDevice = speaker.id
            } catch {
                log("La sortie audio n'a pas démarré (\(error)) : rien n'est joué (nouvel essai à la prochaine prise de parole).")
                return
            }
        }
        let guardian = VolumeGuard(
            device: speaker.id, deviceName: speaker.name, floor: settings.volumeFloor, volume: volume, recovery: recovery,
            now: now, log: log
        )
        guardian.begin()
        speech?.volume = guardian
        speech?.playing = true
        writeState(speaking: true)
    }

    private func scheduleEndCheck(after delay: TimeInterval) {
        endCheck?.cancel()
        endCheck = scheduler.schedule(after: delay) { [weak self] in self?.checkSpeechEnd() }
    }

    /// 2 s après la dernière voix, la prise de parole finit ; sinon la vérification est reportée à l'échéance.
    private func checkSpeechEnd() {
        endCheck = nil
        guard let current = speech else { return }
        let remaining = TalkTiming.speechEnd - (scheduler.now - current.lastVoiceAt)
        if remaining > 1e-9 {
            scheduleEndCheck(after: remaining)
        } else {
            endSpeech()
        }
    }

    private func endSpeech() {
        guard let finished = speech else { return }
        speech = nil
        endCheck?.cancel()
        endCheck = nil
        finished.volume?.end()
        var summary = "\(Self.seconds(finished.lastVoiceAt - finished.startedAt)) s de voix"
        if finished.concurrent > 0 {
            summary += ", \(finished.concurrent) paquet\(finished.concurrent > 1 ? "s" : "") d'une autre source "
                + "ignoré\(finished.concurrent > 1 ? "s" : "")"
        }
        let dropped = buffer.droppedSamples - finished.droppedAtStart
        if dropped > 0 {
            summary += ", \(dropped * 1000 / JitterBuffer.sampleRate) ms jetés par le tampon"
        }
        log("Fin de la prise de parole de \(finished.source) : \(summary).")
        if finished.playing {
            writeState(speaking: false)
            // 10 s après la dernière voix, et non après la fin de la prise de parole.
            let delay = max(0, finished.lastVoiceAt + TalkTiming.outputIdle - scheduler.now)
            idleStop?.cancel()
            idleStop = scheduler.schedule(after: delay) { [weak self] in self?.stopOutput() }
        }
    }

    private func stopOutput() {
        idleStop = nil
        guard speech == nil, output.isRunning else { return }
        output.stop()
        outputDevice = nil
        log("Lecture arrêtée après \(Int(TalkTiming.outputIdle)) s sans voix.")
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Périphériques et état

    private func devicesChanged() {
        locateSpeaker(announce: true)
    }

    /// Retrouve les haut-parleurs intégrés ; journalise un changement, ou toujours avec `announce` au démarrage.
    private func locateSpeaker(announce: Bool) {
        let found: AudioDeviceInfo?
        do {
            found = SpeakerPicker.builtInSpeakers(in: try catalog.devices())
        } catch {
            log("Liste des périphériques audio illisible (\(error)).")
            speaker = nil
            return
        }
        let changed = found != speaker
        speaker = found
        guard changed || announce else { return }
        if let found {
            log("Haut-parleurs intégrés : \(found.name) (\(found.id)).")
        } else {
            log("Haut-parleurs intégrés introuvables.")
        }
    }

    private func writeState(speaking: Bool) {
        do {
            try stateStore.save(TalkState(speaking: speaking, since: now(), pid: processID))
        } catch {
            log("L'état de talkd n'a pas pu être écrit (\(error)).")
        }
    }
}
