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
            // Au premier plan, de nouveaux réglages (dont ceux du premier lancement) connectent tout de suite.
            if isForeground {
                disconnect()
                activate()
            }
        }
    }

    let ptz: PTZClient
    let video: VideoSession
    /// Connecté (ou en train de se connecter) au contrôle et à la vidéo.
    private(set) var isActive = false
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private let store: SettingsStore

    init(store: SettingsStore, ptz: PTZClient, video: VideoSession) {
        self.store = store
        self.ptz = ptz
        self.video = video
        settings = store.load()
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
                    case .service:
                        NWWebSocketTransport(scheduler: scheduler)
                    }
                },
                browser: BonjourServiceBrowser(),
                keys: KeychainDeviceKeyStore(),
                pairingRecord: PairingRecord(),
                scheduler: scheduler
            ),
            video: VideoSession(scheduler: scheduler)
        )
    }

    /// Premier plan : connexion au contrôle et à la vidéo (le contrôle envoie takeControl à l'ouverture).
    /// Sans effet si déjà actif : un retour .inactive → .active ne relance rien.
    func activate() {
        isForeground = true
        guard !isActive, let ptzdURL = settings.ptzdURL else { return }
        isActive = true
        ptz.start(url: ptzdURL)
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

    /// Appairage avec le code affiché par `ptzd pair` sur le Mac.
    func pair(code: String) {
        ptz.pair(code: code)
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

    /// Rien tant que l'app n'est pas connectée (réglages incomplets : la feuille des réglages est ouverte).
    var bannerText: String? {
        guard isActive else { return nil }
        return StatusBanner.text(for: BannerInputs(
            macUnreachable: ptz.isUnreachable,
            authIssue: ptz.authIssue,
            connecting: ptz.link != .connected || video.phase != .playing,
            state: ptz.state
        ))
    }

    /// Joystick et zoom utilisables : connecté, caméra présente, hors vie privée.
    var controlsEnabled: Bool {
        guard ptz.link == .connected, let state = ptz.state else { return false }
        return state.camera == .connected && !state.privacy
    }

    /// Bouton vie privée utilisable : connecté et caméra présente.
    var privacyToggleEnabled: Bool {
        ptz.link == .connected && ptz.state?.camera == .connected
    }
}
