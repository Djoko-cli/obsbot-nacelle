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
}
