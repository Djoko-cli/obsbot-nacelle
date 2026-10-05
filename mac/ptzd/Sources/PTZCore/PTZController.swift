import Foundation
import NacelleProtocol

/// Point d'entrée de la logique : traite les messages de l'app, suit la
/// présence de la caméra et publie l'état (spec § 5 et § 6).
@MainActor
public final class PTZController {
    /// Délai avant de relire la position après un déplacement absolu : relue
    /// trop tôt, la caméra renvoie une valeur fausse (spec § 10, question 1).
    public static let settleDelay: TimeInterval = 2
    /// Écart toléré entre l'ordre absolu et la position relue (la relecture peut différer d'1°).
    public static let positionTolerance: Double = 3
    /// Renvois au plus d'un ordre absolu ignoré par la caméra, hors vie privée.
    public static let maxResends = 2
    /// En vie privée, la vérification ne s'arrête jamais : délais avant chaque nouvelle
    /// vérification après un renvoi, le dernier se répétant indéfiniment.
    public static let privacyBackoff: [TimeInterval] = [2, 5, 10, 30]

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
    private var verifyTarget = false
    private var lastControl: ControlState = .idle

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
        control = ControlTaker(runner: aiOff, scheduler: scheduler, isObsbotCenterRunning: isObsbotCenterRunning, log: log)
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
        control.onChange = { [weak self] in self?.controlChanged() }
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
            verifyTarget = false
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
            verifyTarget = false
            motion.reset()
            zoom.reset()
        }
        publish()
    }

    /// Fin de la coupure du suivi IA en vie privée : sur une caméra qui démarre,
    /// obsbot-ai-off a pu tourner en même temps que la première réapplication.
    private func controlChanged() {
        let previous = lastControl
        lastControl = control.state
        if previous == .taking, control.state != .taking, privacy.isActive, camera.isPresent {
            do {
                try privacy.enforce()
                refreshAfterSettling()
            } catch {
                log("Vie privée non réappliquée après la coupure du suivi IA : \(error)")
            }
        }
        publish()
    }

    /// Relit la position après `delay`, puis la compare à la cible. `resends` compte
    /// les renvois déjà faits pour cette cible.
    private func refreshAfterSettling(resends: Int = 0, delay: TimeInterval = PTZController.settleDelay) {
        verifyTarget = true
        settle?.cancel()
        settle = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.settle = nil
            self.motion.refreshPosition()
            self.zoom.refresh()
            self.checkTargetReached(resends: resends)
        }
    }

    /// La caméra ignore parfois un ordre absolu en renvoyant un succès : on compare la
    /// position relue à la cible et on renvoie l'ordre. Hors vie privée, au plus
    /// maxResends fois ; en vie privée, jusqu'à ce que le tilt soit atteint.
    private func checkTargetReached(resends: Int) {
        guard verifyTarget, let target = privacy.lastTarget else { return }
        let position = motion.position
        if let position {
            // En vie privée, seul le tilt protège l'image ; à -70° la caméra relit d'ailleurs
            // un pan décalé (constaté le 2026-10-05). Hors vie privée, les deux axes comptent.
            let panReached = privacy.isActive || abs(position.pan - target.pan) <= Self.positionTolerance
            if panReached && abs(position.tilt - target.tilt) <= Self.positionTolerance {
                verifyTarget = false
                if resends > Self.maxResends {
                    log("Position atteinte après \(resends) renvois : relue \(position).")
                }
                return
            }
        } else if !privacy.isActive {
            // Position illisible hors vie privée : rien à comparer.
            verifyTarget = false
            return
        }
        let seen = position.map { "\($0)" } ?? "illisible"
        if privacy.isActive {
            retryPrivacy(target: target, seen: seen, resends: resends)
            return
        }
        guard resends < Self.maxResends else {
            verifyTarget = false
            log("Position non atteinte après \(Self.maxResends) renvois : cible \(target), relue \(seen).")
            return
        }
        log("Ordre absolu ignoré par la caméra (cible \(target), relue \(seen)) : nouvel envoi.")
        do {
            try privacy.resendLastTarget()
            refreshAfterSettling(resends: resends + 1)
        } catch {
            verifyTarget = false
            log("Nouvel envoi refusé : \(error)")
        }
    }

    /// Vie privée : renvoi puis nouvelle vérification après 2, 5, 10, puis toutes les 30 s,
    /// sans jamais abandonner. Une ligne de journal par palier au plus.
    private func retryPrivacy(target: PanTiltPosition, seen: String, resends: Int) {
        let stage = min(resends, Self.privacyBackoff.count - 1)
        let delay = Self.privacyBackoff[stage]
        let logged = resends < Self.privacyBackoff.count
        if logged {
            let next = stage == Self.privacyBackoff.count - 1 ? "toutes les \(Int(delay)) s" : "dans \(Int(delay)) s"
            log("Ordre de vie privée ignoré par la caméra (cible \(target), relue \(seen)) : nouvel envoi, vérification \(next).")
        }
        do {
            try privacy.resendLastTarget()
        } catch CameraError.absent {
            // Le débranchement est traité par cameraPresenceChanged ; le rebranchement réapplique.
            verifyTarget = false
            return
        } catch {
            if logged {
                log("Nouvel envoi refusé : \(error). Nouvel essai quand même.")
            }
        }
        refreshAfterSettling(resends: resends + 1, delay: delay)
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
