import NacelleProtocol
import Testing
@testable import PTZCore

@MainActor
@Suite("Contrôleur")
struct PTZControllerTests {
    let camera = FakeCamera()
    let scheduler = FakeScheduler()
    let runner = FakeAIOffRunner()
    let store = MemoryStateStore()
    let log = LogRecorder()

    private func makeController() -> PTZController {
        PTZController(
            camera: camera,
            scheduler: scheduler,
            aiOff: runner,
            store: store,
            settings: MotionSettings(),
            isObsbotCenterRunning: { false },
            log: log.sink
        )
    }

    @Test("L'état initial reflète la caméra et state.json")
    func initialSnapshot() {
        camera.isPresent = false
        store.state = PersistedState(privacy: true, saved: nil)
        let controller = makeController()
        #expect(controller.snapshot.camera == .absent)
        #expect(controller.snapshot.privacy)
        #expect(controller.snapshot.control == .idle)
    }

    @Test("Caméra absente : move, zoom et privacy sont refusés")
    func cameraAbsent() {
        camera.isPresent = false
        let controller = makeController()
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1)?.code == .cameraAbsent)
        #expect(controller.handle(.zoom(value: 10), from: 1)?.code == .cameraAbsent)
        #expect(controller.handle(.privacy(on: true), from: 1)?.code == .cameraAbsent)
    }

    @Test("Un mouvement publie moving, puis l'arrêt automatique le retire")
    func movePublishes() {
        let controller = makeController()
        var published: [StateSnapshot] = []
        controller.onStateChange = { published.append($0) }
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1) == nil)
        #expect(controller.snapshot.moving)
        scheduler.advance(by: 0.31)
        #expect(!controller.snapshot.moving)
        #expect(published.contains { $0.moving })
    }

    @Test("Vie privée : arrêt, objectif vers le bas, puis refus des commandes")
    func privacyOn() {
        let controller = makeController()
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        #expect(controller.snapshot.privacy)
        #expect(!controller.snapshot.moving)
        #expect(camera.absoluteCommands.last?.tilt == PrivacyKeeper.privacyTilt)
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.zoom(value: 10), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.move(pan: 0, tilt: 0), from: 1) == nil)
    }

    @Test("La position n'est relue que 2 s après le déplacement absolu")
    func settleBeforeReading() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(controller.snapshot.tilt == -1)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyKeeper.privacyTilt)
    }

    @Test("Sortie de vie privée : position et zoom relus")
    func privacyOff() {
        let controller = makeController()
        camera.position = PanTiltPosition(pan: 20, tilt: 5)
        _ = controller.handle(.zoom(value: 40), from: 1)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(controller.handle(.privacy(on: false), from: 1) == nil)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(!controller.snapshot.privacy)
        #expect(controller.snapshot.pan == 20)
        #expect(controller.snapshot.tilt == 5)
        #expect(controller.snapshot.zoom == 40)
    }

    @Test("Commande refusée par la caméra : uvcFailed")
    func uvcFailure() {
        let controller = makeController()
        camera.failNextWrite = .ioKit(-536870212)
        #expect(controller.handle(.zoom(value: 10), from: 1)?.code == .uvcFailed)
    }

    @Test("takeControl : taking, puis ready quand l'utilitaire réussit")
    func takeControl() {
        let controller = makeController()
        _ = controller.handle(.takeControl, from: 1)
        #expect(controller.snapshot.control == .taking)
        runner.finish(.success)
        #expect(controller.snapshot.control == .ready)
    }

    @Test("Débranchement : caméra absente, mouvement oublié")
    func unplug() {
        let controller = makeController()
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        #expect(controller.snapshot.camera == .absent)
        #expect(!controller.snapshot.moving)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Rebranchement en vie privée : objectif renvoyé vers le bas et suivi IA recoupé")
    func replugInPrivacy() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        camera.isPresent = false
        let controller = makeController()
        camera.isPresent = true
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyKeeper.privacyTilt)])
        #expect(runner.runCount == 1)
        #expect(controller.snapshot.camera == .connected)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyKeeper.privacyTilt)
    }

    @Test("La déconnexion du pilote arrête la nacelle")
    func disconnectStops() {
        let controller = makeController()
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 7)
        controller.clientDisconnected(7)
        #expect(!controller.snapshot.moving)
        #expect(camera.relativeCommands.last == .stop)
    }

    @Test("Ordre de vie privée ignoré par la caméra : renvoyé après relecture")
    func ignoredPrivacyCommandIsResent() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        camera.ignoreAbsoluteCommands = 1
        _ = controller.handle(.privacy(on: true), from: 1)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(camera.absoluteCommands.count == 2)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyKeeper.privacyTilt)
        #expect(log.lines.contains { $0.contains("ignoré") })
    }

    @Test("Hors vie privée, ordre de sortie toujours ignoré : deux renvois au plus, puis une erreur")
    func exitResendsAreBounded() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        camera.position = PanTiltPosition(pan: 20, tilt: 5)
        _ = controller.handle(.privacy(on: true), from: 1)
        scheduler.advance(by: PTZController.settleDelay)
        let sent = camera.absoluteCommands.count
        camera.ignoreAbsoluteCommands = 10
        _ = controller.handle(.privacy(on: false), from: 1)
        for _ in 0..<10 {
            scheduler.advance(by: 30)
        }
        #expect(camera.absoluteCommands.count == sent + 1 + PTZController.maxResends)
        #expect(log.lines.filter { $0.contains("non atteinte") }.count == 1)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Vie privée : la vérification ne s'arrête pas après maxResends et finit par atteindre le tilt")
    func privacyNeverGivesUp() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        camera.ignoreAbsoluteCommands = 6
        _ = controller.handle(.privacy(on: true), from: 1)
        // Vérifications à 2 s, puis renvois suivis de 2, 5, 10, 30, 30, 30 s.
        let checks: [Double] = [PTZController.settleDelay] + PTZController.privacyBackoff + [30, 30]
        for (index, delay) in checks.enumerated() {
            #expect(camera.absoluteCommands.count == 1 + index)
            scheduler.advance(by: delay)
        }
        #expect(camera.absoluteCommands.count == 7)
        #expect(camera.absoluteCommands.allSatisfy { $0.tilt == PrivacyKeeper.privacyTilt })
        #expect(controller.snapshot.tilt == PrivacyKeeper.privacyTilt)
        // Un premier raté, puis une ligne par palier (2, 5, 10, 30 s) : pas à chaque essai de 30 s.
        #expect(log.lines.filter { $0.contains("ignoré") }.count == PTZController.privacyBackoff.count)
        scheduler.advance(by: 300)
        #expect(camera.absoluteCommands.count == 7)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Vie privée et relecture impossible : renvoi quand même, jusqu'à relire le tilt")
    func privacyUnreadablePositionRetries() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        camera.failReads = true
        scheduler.advance(by: PTZController.settleDelay)
        #expect(camera.absoluteCommands.count == 2)
        camera.failReads = false
        scheduler.advance(by: PTZController.privacyBackoff[0])
        #expect(controller.snapshot.tilt == PrivacyKeeper.privacyTilt)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Rebranchement en vie privée, ordres ignorés au démarrage : renvoyés jusqu'au tilt")
    func replugIgnoredEnforceIsResent() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        camera.isPresent = false
        let controller = makeController()
        camera.isPresent = true
        camera.ignoreAbsoluteCommands = 1 + PTZController.maxResends
        controller.cameraPresenceChanged(true)
        scheduler.advance(by: PTZController.settleDelay)
        for delay in PTZController.privacyBackoff {
            scheduler.advance(by: delay)
        }
        #expect(camera.absoluteCommands.count == 2 + PTZController.maxResends)
        #expect(controller.snapshot.tilt == PrivacyKeeper.privacyTilt)
    }

    @Test("Fin de la coupure du suivi IA en vie privée : ordre de vie privée renvoyé et revérifié")
    func controlFinishReenforcesPrivacy() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands.count == 1)
        #expect(controller.snapshot.control == .taking)
        scheduler.advance(by: PTZController.settleDelay)
        // Le suivi IA a remonté l'objectif pendant la coupure.
        camera.position = PanTiltPosition(pan: 12, tilt: 10)
        runner.finish(.success)
        #expect(controller.snapshot.control == .ready)
        #expect(camera.absoluteCommands == Array(repeating: PanTiltPosition(pan: 12, tilt: PrivacyKeeper.privacyTilt), count: 2))
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyKeeper.privacyTilt)
        // Un échec de l'utilitaire réapplique aussi.
        _ = controller.handle(.takeControl, from: 1)
        runner.finish(.sdkError)
        #expect(controller.snapshot.control == .taking)
        scheduler.advance(by: ControlTaker.retryDelay)
        runner.finish(.sdkError)
        #expect(controller.snapshot.control == .failed)
        #expect(camera.absoluteCommands.count == 3)
    }

    @Test("Fin de la coupure hors vie privée : aucun ordre absolu")
    func controlFinishOutsidePrivacy() {
        let controller = makeController()
        _ = controller.handle(.takeControl, from: 1)
        runner.finish(.success)
        #expect(camera.absoluteCommands.isEmpty)
    }

    @Test("Un mouvement du joystick après la sortie annule la vérification")
    func userMoveCancelsVerification() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        scheduler.advance(by: PTZController.settleDelay)
        _ = controller.handle(.privacy(on: false), from: 1)
        let sent = camera.absoluteCommands.count
        camera.position = PanTiltPosition(pan: 40, tilt: 10)
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(camera.absoluteCommands.count == sent)
    }

    @Test("En vie privée, un pan relu décalé ne déclenche pas de renvoi")
    func privacyChecksTiltOnly() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        camera.position = PanTiltPosition(pan: camera.position.pan + 10, tilt: PrivacyKeeper.privacyTilt)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(camera.absoluteCommands.count == 1)
        #expect(!log.lines.contains { $0.contains("ignoré") })
    }
}
