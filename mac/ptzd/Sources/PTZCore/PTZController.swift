import Foundation
import NacelleProtocol

/// Point d'entrée de la logique : traite les messages de l'app, suit la
/// présence de la caméra et publie l'état (spec § 5 et § 6).
@MainActor
public final class PTZController {
    /// Délai avant de relire la position après un déplacement absolu : relue
    /// trop tôt, la caméra renvoie une valeur fausse (spec § 10, question 1).
    public static let settleDelay: TimeInterval = 2

    public private(set) var snapshot: StateSnapshot
    /// Appelé à chaque changement d'état, pour diffusion à tous les clients.
    public var onStateChange: ((StateSnapshot) -> Void)?

    private let camera: any CameraDevice
    private let scheduler: any Scheduler
    private let motion: MotionDriver
    private let zoom: ZoomDriver
    private let privacy: PrivacyKeeper
    private let control: ControlTaker
    private let log: LogSink
    private var settle: (any Cancellable)?

    public init(
        camera: any CameraDevice,
        scheduler: any Scheduler,
        aiOff: any AIOffRunner,
        store: any StateStore,
        settings: MotionSettings,
        isObsbotCenterRunning: @escaping @MainActor () -> Bool,
        log: @escaping LogSink
    ) {
        self.camera = camera
        self.scheduler = scheduler
        self.log = log
        motion = MotionDriver(camera: camera, scheduler: scheduler, settings: settings, log: log)
        zoom = ZoomDriver(camera: camera, scheduler: scheduler, log: log)
        privacy = PrivacyKeeper(camera: camera, store: store, log: log)
        control = ControlTaker(runner: aiOff, isObsbotCenterRunning: isObsbotCenterRunning, log: log)
        snapshot = StateSnapshot(
            camera: camera.isPresent ? .connected : .absent,
            control: .idle,
            privacy: privacy.isActive,
            pan: nil, tilt: nil, zoom: nil,
            moving: false
        )
        motion.onChange = { [weak self] in self?.publish() }
        zoom.onChange = { [weak self] in self?.publish() }
        privacy.onChange = { [weak self] in self?.publish() }
        control.onChange = { [weak self] in self?.publish() }
    }

    /// Traite un message. Renvoie l'erreur à transmettre à ce client, ou nil.
    public func handle(_ message: ClientMessage, from client: ClientID) -> (code: ErrorCode, message: String)? {
        switch message {
        case .takeControl:
            control.take()
            return nil
        case let .move(pan, tilt):
            if privacy.isActive, pan == 0, tilt == 0 {
                return nil
            }
            if let refusal = refusal() {
                return refusal
            }
            return attempt { try motion.move(pan: pan, tilt: tilt, from: client) }
        case let .zoom(value):
            if let refusal = refusal() {
                return refusal
            }
            return attempt { try zoom.set(value) }
        case let .privacy(on):
            guard camera.isPresent else {
                return (.cameraAbsent, "Caméra débranchée.")
            }
            if on {
                return attempt {
                    try? motion.stop()
                    try privacy.enter(currentPosition: motion.position, currentZoom: zoom.value)
                    refreshAfterSettling()
                }
            }
            return attempt {
                try privacy.exit()
                refreshAfterSettling()
            }
        }
    }

    public func clientDisconnected(_ client: ClientID) {
        motion.clientDisconnected(client)
    }

    /// Branchement ou débranchement de la caméra. Au branchement, la vie privée
    /// est réappliquée et le suivi IA recoupé, au cas où la caméra aurait redémarré.
    public func cameraPresenceChanged(_ present: Bool) {
        if present {
            log("Caméra branchée.")
            motion.refreshPosition()
            zoom.refresh()
            if privacy.isActive {
                do {
                    try privacy.enforce()
                    refreshAfterSettling()
                } catch {
                    log("Vie privée non réappliquée : \(error)")
                }
                control.take()
            }
        } else {
            log("Caméra débranchée.")
            settle?.cancel()
            settle = nil
            motion.reset()
            zoom.reset()
        }
        publish()
    }

    private func refreshAfterSettling() {
        settle?.cancel()
        settle = scheduler.schedule(after: Self.settleDelay) { [weak self] in
            guard let self else { return }
            self.settle = nil
            self.motion.refreshPosition()
            self.zoom.refresh()
        }
    }

    private func refusal() -> (code: ErrorCode, message: String)? {
        if !camera.isPresent {
            return (.cameraAbsent, "Caméra débranchée.")
        }
        if privacy.isActive {
            return (.privacyActive, "Vie privée active : commande refusée.")
        }
        return nil
    }

    private func attempt(_ body: () throws -> Void) -> (code: ErrorCode, message: String)? {
        do {
            try body()
            return nil
        } catch CameraError.absent {
            return (.cameraAbsent, "Caméra débranchée.")
        } catch {
            log("Commande UVC refusée : \(error)")
            return (.uvcFailed, "La caméra a refusé la commande (\(error)).")
        }
    }

    private func publish() {
        let next = StateSnapshot(
            camera: camera.isPresent ? .connected : .absent,
            control: control.state,
            privacy: privacy.isActive,
            pan: motion.position?.pan,
            tilt: motion.position?.tilt,
            zoom: zoom.value,
            moving: motion.isMoving
        )
        guard next != snapshot else { return }
        snapshot = next
        onStateChange?(next)
    }
}
