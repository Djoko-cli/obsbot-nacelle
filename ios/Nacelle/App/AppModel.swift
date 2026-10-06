import Foundation
import NacelleProtocol
import Observation

/// L'état de l'app : réglages, contrôle de la nacelle et vidéo.
@MainActor
@Observable
final class AppModel {
    var settings: ConnectionSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            // Au premier plan, de nouveaux réglages reconnectent tout de suite, sauf l'adresse retenue
            // à l'appairage : la connexion en cours la vaut déjà.
            if isForeground, !rememberingAddress {
                disconnect()
                activate()
            }
        }
    }

    /// Son voulu (bouton haut-parleur), retenu d'un lancement à l'autre.
    var soundWanted: Bool {
        didSet {
            guard soundWanted != oldValue else { return }
            store.soundOn = soundWanted
            syncSound()
        }
    }

    let ptz: PTZClient
    let video: VideoSession
    /// Connecté (ou en train de se connecter) au contrôle et à la vidéo.
    private(set) var isActive = false
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var rememberingAddress = false
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let scheduler: any Scheduler
    /// Avis bref affiché à la place du bandeau (QR refusé sur un iPhone déjà appairé).
    private(set) var notice: String?
    @ObservationIgnored private var noticeTimer: (any Cancellable)?
    static let noticeDuration: TimeInterval = 5

    init(store: SettingsStore, ptz: PTZClient, video: VideoSession, scheduler: any Scheduler) {
        self.store = store
        self.ptz = ptz
        self.video = video
        self.scheduler = scheduler
        settings = store.load()
        soundWanted = store.soundOn
        ptz.onAddressLearned = { [weak self] address, port in
            self?.remember(address, port: port)
        }
        ptz.onPairingRefused = { [weak self] in
            self?.show(StatusBanner.qrRefused)
        }
        // La vie privée coupe le son, sa sortie le rétablit, et un état perdu le coupe aussi.
        ptz.onStateChange = { [weak self] in
            self?.syncSound()
        }
    }

    static func live() -> AppModel {
        let scheduler = MainScheduler()
        return AppModel(
            store: SettingsStore(),
            ptz: PTZClient(
                makeTransport: { endpoint in
                    switch endpoint {
                    case .url:
                        URLSessionWebSocketTransport(scheduler: scheduler)
                    case .tls:
                        NWWebSocketTransport(scheduler: scheduler)
                    }
                },
                browser: BonjourServiceBrowser(),
                keys: KeychainDeviceKeyStore(),
                pairingRecord: PairingRecord(),
                scheduler: scheduler
            ),
            video: VideoSession(scheduler: scheduler),
            scheduler: scheduler
        )
    }

    /// Premier plan : connexion au contrôle et à la vidéo (le contrôle envoie takeControl à l'ouverture).
    /// Sans effet si déjà actif : un retour .inactive → .active ne relance rien.
    func activate() {
        isForeground = true
        guard !isActive else { return }
        isActive = true
        syncSound()
        ptz.start(settings: settings)
        // Offre vidéo relayée par ptzd (spec accès local § 8.4).
        video.start { [ptz] offer in
            try await ptz.negotiate(offer: offer)
        }
    }

    /// Inactif (Centre de contrôle, appel, alerte, sélecteur d'apps) : arrêt de la nacelle, sans
    /// déconnecter. Le système peut annuler le glissé du joystick sans qu'aucun relâchement n'arrive.
    func pause() {
        ptz.setJoystick(.zero)
    }

    /// Appairage avec le QR code affiché par `ptzd pair` sur le Mac.
    func pair(with link: PairingLink) {
        ptz.pair(with: link)
    }

    /// L'adresse et le port du Mac qui vient d'appairer l'iPhone vont dans le champ s'il est vide
    /// (spec découverte et QR § 8.3, spec app Mac § 9).
    private func remember(_ address: String, port: Int) {
        guard settings.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rememberingAddress = true
        settings.host = address
        settings.ptzdPort = port
        rememberingAddress = false
        ptz.update(settings)
    }

    /// Avis affiché `noticeDuration` à la place du bandeau.
    private func show(_ text: String) {
        notice = text
        noticeTimer?.cancel()
        noticeTimer = scheduler.schedule(after: Self.noticeDuration) { [weak self] in
            self?.notice = nil
        }
    }

    /// Oublie la clé de cet iPhone.
    func forgetPairing() {
        ptz.forgetPairing()
    }

    /// Arrière-plan : arrêt de la nacelle, fermeture du WebSocket et de la vidéo.
    func deactivate() {
        isForeground = false
        disconnect()
    }

    private func disconnect() {
        isActive = false
        ptz.stop()
        video.stop()
    }

    /// Rien tant que l'app n'est pas au premier plan.
    var bannerText: String? {
        guard isActive else { return nil }
        if let notice {
            return notice
        }
        return StatusBanner.text(for: BannerInputs(
            macUnreachable: ptz.isUnreachable,
            authIssue: ptz.authIssue,
            connecting: ptz.link != .connected || video.phase != .playing,
            state: ptz.state
        ))
    }

    /// L'écran d'appairage remplace les commandes tant que l'iPhone n'est pas appairé (spec découverte et QR § 8.1).
    var needsPairing: Bool {
        !ptz.isPaired
    }

    /// Où en est l'appairage, sur l'écran d'appairage.
    var pairingStatus: String? {
        if ptz.isPairing {
            return "Appairage…"
        }
        return ptz.authIssue == .badCode ? StatusBanner.qrRefused : nil
    }

    /// Joystick et zoom utilisables : connecté, caméra présente, hors vie privée.
    var controlsEnabled: Bool {
        guard ptz.link == .connected, let state = ptz.state else { return false }
        return state.camera == .connected && !state.privacy
    }

    /// Son joué : voulu, et seulement si ptzd dit que la vie privée est inactive (le micro de la caméra
    /// capte la pièce). État inconnu (connexion en cours ou perdue) : coupé, car la vidéo, elle, continue.
    var soundPlaying: Bool {
        soundWanted && ptz.state?.privacy == false
    }

    /// Bouton son utilisable : hors vie privée, état connu.
    var soundToggleEnabled: Bool {
        ptz.state?.privacy == false
    }

    /// Applique `soundPlaying` à la vidéo : au départ, au bouton et à chaque changement d'état de ptzd.
    func syncSound() {
        video.setPlaysAudio(soundPlaying)
    }

    /// Le dernier ordre de suivi IA est « allumé ».
    var aiTrackingOn: Bool {
        ptz.state?.aiTracking == .on
    }

    /// Bouton du suivi IA utilisable : connecté, caméra présente, hors vie privée.
    var aiToggleEnabled: Bool {
        ptz.link == .connected && ptz.state?.camera == .connected && ptz.state?.privacy == false
    }

    /// Allume le suivi s'il n'est pas allumé (coupé ou inconnu), le coupe sinon.
    func toggleAITracking() {
        ptz.setAITracking(!aiTrackingOn)
    }

    /// Bouton vie privée utilisable : connecté et caméra présente.
    var privacyToggleEnabled: Bool {
        ptz.link == .connected && ptz.state?.camera == .connected
    }
}
