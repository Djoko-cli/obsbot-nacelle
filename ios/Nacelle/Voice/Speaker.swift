import AVFoundation
import Foundation
import NacelleProtocol
import Observation

/// Accès de l'app au micro, tel que le système le dit.
enum MicAccess: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

/// La permission du micro, derrière un protocole pour les tests.
@MainActor
protocol MicrophonePermission: AnyObject {
    var access: MicAccess { get }
    /// Pose la question du système si besoin ; vrai si l'accès est accordé.
    func request() async -> Bool
}

/// Le côté audio de la parole : session, unité Voice Processing I/O, micro converti en paquets. Derrière un
/// protocole pour que les tests n'ouvrent ni session ni micro.
@MainActor
protocol SpeechAudio: AnyObject {
    /// Les paquets de 640 octets formés depuis le dernier appel, et le niveau du micro (0 à 1).
    var onPackets: (@MainActor (_ packets: [Data], _ level: Float) -> Void)? { get set }
    /// Le système a interrompu l'audio (appel, Siri) ou l'unité a échoué : la parole doit s'arrêter.
    var onInterrupted: (@MainActor () -> Void)? { get set }
    /// Bascule en mode parole et démarre le micro. Faux si le micro n'a pas pu démarrer.
    func begin() async -> Bool
    /// Retour à la lecture seule. Sans effet si la parole n'est pas démarrée.
    func end()
}

/// Là où partent les trames voix : la connexion à ptzd.
@MainActor
protocol VoiceLink: AnyObject {
    func sendVoice(_ frame: Data, completion: @escaping @MainActor () -> Void) -> Bool
}

extension PTZClient: VoiceLink {}

/// Le micro système : permission du micro (iOS 17 et plus).
@MainActor
final class SystemMicrophonePermission: MicrophonePermission {
    var access: MicAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .notDetermined
        }
    }

    func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

/// « Maintenir pour parler » (spec parler § 6) : de l'appui au relâchement, ouvre le micro, envoie les paquets à
/// ptzd un par un, et s'arrête à la moindre raison (relâchement, perte de connexion, arrière-plan, interruption).
///
/// Une file de 10 paquets au plus (200 ms) entre le micro et l'envoi : si l'envoi prend du retard, le plus ancien
/// paquet est jeté, pour que la voix reste en direct. Un seul envoi à la fois, le suivant part à la fin du précédent.
@MainActor
@Observable
final class Speaker {
    nonisolated static let maxQueuedPackets = 10

    enum Phase: Equatable {
        case idle
        /// Permission, bascule de la session audio, démarrage du micro.
        case starting
        case speaking
    }

    /// Pourquoi la parole s'est arrêtée (ou n'a pas commencé).
    enum StopReason: Equatable, Sendable {
        /// Le doigt est levé.
        case release
        /// Connexion à ptzd perdue.
        case connection
        /// Talkback est devenu indisponible sur le Mac.
        case talkbackOff
        /// L'app passe en arrière-plan.
        case background
        /// Appel, Siri, alarme.
        case interruption
        /// Le micro n'a pas pu démarrer.
        case failure
        /// L'accès au micro est refusé.
        case micDenied
    }

    private(set) var phase: Phase = .idle
    /// Niveau du micro, de 0 à 1 ; nul hors parole.
    private(set) var level: Float = 0
    /// Les premières trames du micro sont arrivées : on peut parler. Faux pendant la préparation et hors parole.
    private(set) var isMicLive = false
    /// L'accès au micro est refusé (le bouton est alors atténué mais reste touchable).
    private(set) var micDenied = false
    /// Paquets jetés depuis le début de la prise de parole en cours (file pleine).
    var droppedPackets: Int {
        queue.droppedCount
    }

    /// Appelé quand la parole se termine ou ne commence pas, avec la raison.
    @ObservationIgnored var onStopped: ((StopReason) -> Void)?

    @ObservationIgnored private let audio: any SpeechAudio
    @ObservationIgnored private let link: any VoiceLink
    @ObservationIgnored private let permission: any MicrophonePermission
    @ObservationIgnored private var queue = BoundedQueue<Data>(capacity: Speaker.maxQueuedPackets)
    @ObservationIgnored private var sending = false
    /// Le doigt est sur le bouton.
    @ObservationIgnored private var desired = false
    /// Change à chaque arrêt : un démarrage ou un envoi d'une prise de parole précédente le voit et s'abstient.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var pendingStop: StopReason?

    init(audio: any SpeechAudio, link: any VoiceLink, permission: any MicrophonePermission) {
        self.audio = audio
        self.link = link
        self.permission = permission
        micDenied = permission.access == .denied
        audio.onPackets = { [weak self] packets, level in
            self?.received(packets, level: level)
        }
        audio.onInterrupted = { [weak self] in
            self?.stop(.interruption)
        }
    }

    /// La parole est demandée ou en cours : le micro est ouvert ou en train de l'être.
    var isActive: Bool {
        phase != .idle
    }

    /// L'appui est pris en compte mais le micro ne capte pas encore : permission, bascule de la session, démarrage de
    /// l'unité, attente des premières trames. Le bouton est rouge avec un anneau qui tourne, la jauge ne bouge pas.
    var isPreparing: Bool {
        isActive && !isMicLive
    }

    /// Relit l'accès au micro (l'utilisateur a pu le changer dans Réglages).
    func refreshAccess() {
        micDenied = permission.access == .denied
    }

    /// Le doigt se pose : démarre la parole. Rend la main quand elle a commencé, ou n'a pas pu (ou plus lieu d'être).
    func press() async {
        desired = true
        guard phase == .idle else { return }
        phase = .starting
        let current = epoch
        defer {
            if phase == .starting { phase = .idle }
        }
        if permission.access == .notDetermined {
            _ = await permission.request()
            refreshAccess()
            // La question du système a pris le doigt (le geste est annulé, aucun relâchement n'arrive) : la parole ne
            // commence pas toute seule, il faut un nouvel appui.
            finishStart(because: permission.access == .granted ? .release : .micDenied)
            return
        }
        refreshAccess()
        guard permission.access == .granted else {
            finishStart(because: .micDenied)
            return
        }
        guard canContinue(current) else {
            finishStart(because: pendingStop ?? .release)
            return
        }
        let started = await audio.begin()
        guard started else {
            audio.end()
            finishStart(because: .failure)
            return
        }
        guard canContinue(current) else {
            audio.end()
            finishStart(because: pendingStop ?? .release)
            return
        }
        queue.removeAll()
        sending = false
        pendingStop = nil
        isMicLive = false
        phase = .speaking
    }

    /// Le doigt se lève.
    func release() {
        desired = false
        stop(.release)
    }

    /// Arrête la parole pour cette raison. Sans effet au repos. Pendant le démarrage, le démarrage s'arrête de lui-même
    /// dès qu'il reprend la main.
    func stop(_ reason: StopReason) {
        switch phase {
        case .idle:
            return
        case .starting:
            // Le doigt levé est déjà noté (`desired`) : un nouvel appui avant la fin du démarrage le reprend.
            guard reason != .release else { return }
            // Toute autre raison annule ce démarrage, même si le doigt reste posé ; `press` conclura.
            pendingStop = pendingStop ?? reason
            epoch += 1
        case .speaking:
            epoch += 1
            audio.end()
            queue.removeAll()
            sending = false
            level = 0
            isMicLive = false
            phase = .idle
            onStopped?(reason)
        }
    }

    // MARK: - Démarrage

    private func canContinue(_ startEpoch: Int) -> Bool {
        desired && epoch == startEpoch
    }

    /// Conclut un démarrage qui n'aboutit pas.
    private func finishStart(because reason: StopReason) {
        pendingStop = nil
        level = 0
        isMicLive = false
        phase = .idle
        onStopped?(reason)
    }

    // MARK: - Envoi

    private func received(_ packets: [Data], level: Float) {
        guard phase == .speaking else { return }
        // Première trame captée (un paquet, ou au moins du son dans la jauge) : le micro est en direct.
        if !isMicLive, !packets.isEmpty || level > 0 {
            isMicLive = true
        }
        self.level = level
        for packet in packets {
            queue.push(packet)
            drain()
            guard phase == .speaking else { return }
        }
    }

    /// Envoie le plus ancien paquet en attente, si aucun envoi n'est en cours.
    private func drain() {
        guard !sending, let packet = queue.pop() else { return }
        let current = epoch
        let accepted = link.sendVoice(packet) { [weak self] in
            guard let self, self.epoch == current else { return }
            self.sending = false
            self.drain()
        }
        if accepted {
            sending = true
        } else {
            stop(.connection)
        }
    }
}

/// Tout ce dont `AppModel` a besoin pour parler, injecté pour que les tests n'ouvrent ni session audio ni micro.
struct SpeechServices {
    var audio: any SpeechAudio
    var permission: any MicrophonePermission
}
