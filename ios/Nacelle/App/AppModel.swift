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
            if isActive {
                deactivate()
                activate()
            }
        }
    }

    let ptz: PTZClient
    let video: VideoSession
    private(set) var isActive = false
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
            ptz: PTZClient(transport: URLSessionWebSocketTransport(), scheduler: scheduler),
            video: VideoSession(scheduler: scheduler)
        )
    }

    /// Premier plan : connexion au contrôle et à la vidéo (le contrôle envoie takeControl à l'ouverture).
    /// Sans effet si déjà actif : un retour .inactive → .active ne relance rien.
    func activate() {
        guard !isActive, let ptzdURL = settings.ptzdURL, let webRTCURL = settings.webRTCURL else { return }
        isActive = true
        ptz.start(url: ptzdURL)
        video.start(url: webRTCURL)
    }

    /// Arrière-plan : arrêt de la nacelle, fermeture du WebSocket et de la vidéo.
    func deactivate() {
        isActive = false
        ptz.stop()
        video.stop()
    }

    var bannerText: String? {
        StatusBanner.text(for: BannerInputs(
            macUnreachable: ptz.isUnreachable,
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
