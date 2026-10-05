/// Mode vie privée : objectif tourné vers le bas, position mémorisée (spec § 6.5).
@MainActor
public final class PrivacyKeeper {
    /// Objectif vers le bas. -70° est obéi exactement ; la caméra ignore -90° (mesuré le 2026-10-05).
    public static let privacyTilt: Double = -70

    public private(set) var isActive: Bool
    /// Appelé quand `isActive` change.
    public var onChange: (() -> Void)?
    /// Dernier ordre absolu envoyé (entrée, sortie ou réapplication), pour vérifier qu'il a été suivi.
    public private(set) var lastTarget: PanTiltPosition?

    private let camera: any CameraDevice
    private let store: any StateStore
    private let log: LogSink
    private var saved: SavedPosition?

    public init(camera: any CameraDevice, store: any StateStore, log: @escaping LogSink) {
        self.camera = camera
        self.store = store
        self.log = log
        let persisted = store.load()
        isActive = persisted.privacy
        saved = persisted.saved
    }

    /// Mémorise la position (nil si inconnue), enregistre, puis tourne l'objectif vers le bas.
    /// Si la caméra refuse, l'enregistrement est annulé et l'erreur remonte.
    public func enter(currentPosition: PanTiltPosition?, currentZoom: Int?) throws {
        guard !isActive else { return }
        let savedNow = currentPosition.map { SavedPosition(pan: $0.pan, tilt: $0.tilt, zoom: currentZoom) }
        persist(PersistedState(privacy: true, saved: savedNow))
        do {
            try camera.setPanTiltAbsolute(panDegrees: currentPosition?.pan ?? 0, tiltDegrees: Self.privacyTilt)
        } catch {
            persist(PersistedState(privacy: false, saved: nil))
            throw error
        }
        lastTarget = PanTiltPosition(pan: currentPosition?.pan ?? 0, tilt: Self.privacyTilt)
        saved = savedNow
        isActive = true
        onChange?()
    }

    /// Rétablit la position mémorisée, ou 0°/0° si elle est inconnue.
    /// Si la caméra refuse, on reste en vie privée.
    public func exit() throws {
        guard isActive else { return }
        let target = saved ?? SavedPosition(pan: 0, tilt: 0, zoom: nil)
        // Zoom d'abord : si la caméra refuse, l'objectif est encore tourné vers le bas.
        if let zoom = target.zoom {
            try camera.setZoom(zoom)
        }
        try camera.setPanTiltAbsolute(panDegrees: target.pan, tiltDegrees: target.tilt)
        lastTarget = PanTiltPosition(pan: target.pan, tilt: target.tilt)
        persist(PersistedState(privacy: false, saved: nil))
        saved = nil
        isActive = false
        onChange?()
    }

    /// Renvoie l'objectif vers le bas si la vie privée est active (démarrage, rebranchement).
    public func enforce() throws {
        guard isActive else { return }
        try camera.setPanTiltAbsolute(panDegrees: saved?.pan ?? 0, tiltDegrees: Self.privacyTilt)
        lastTarget = PanTiltPosition(pan: saved?.pan ?? 0, tilt: Self.privacyTilt)
    }

    /// Renvoie le dernier ordre absolu : la caméra en ignore parfois un en renvoyant
    /// pourtant un succès (constaté le 2026-10-05).
    public func resendLastTarget() throws {
        guard let target = lastTarget else { return }
        try camera.setPanTiltAbsolute(panDegrees: target.pan, tiltDegrees: target.tilt)
    }

    /// Une erreur d'écriture n'empêche pas de protéger l'image : on la journalise.
    private func persist(_ state: PersistedState) {
        do {
            try store.save(state)
        } catch {
            log("Enregistrement de state.json impossible : \(error)")
        }
    }
}
