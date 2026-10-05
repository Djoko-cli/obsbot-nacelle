import Testing
@testable import PTZCore

@MainActor
@Suite("Mouvement en vitesse")
struct MotionDriverTests {
    let camera = FakeCamera()
    let scheduler = FakeScheduler()
    let log = LogRecorder()
    let driver: MotionDriver

    init() {
        driver = MotionDriver(camera: camera, scheduler: scheduler, settings: MotionSettings(), log: log.sink)
    }

    private var right: PanTiltRelative {
        PanTiltRelative(panDirection: 1, panSpeed: 40, tiltDirection: 0, tiltSpeed: 1)
    }

    @Test("Une consigne envoie la commande et passe en mouvement")
    func moveSendsCommand() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        #expect(camera.relativeCommands == [right])
        #expect(driver.isMoving)
    }

    @Test("La même consigne répétée n'est envoyée qu'une fois")
    func noDuplicates() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        try driver.move(pan: 1, tilt: 0, from: 1)
        #expect(camera.relativeCommands == [right])
    }

    @Test("Arrêt automatique 300 ms après la dernière consigne")
    func deadMan() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        scheduler.advance(by: 0.29)
        #expect(driver.isMoving)
        scheduler.advance(by: 0.02)
        #expect(!driver.isMoving)
        #expect(camera.relativeCommands == [right, .stop])
    }

    @Test("Des consignes toutes les 100 ms maintiennent le mouvement")
    func steadyStream() throws {
        for _ in 0..<10 {
            try driver.move(pan: 1, tilt: 0, from: 1)
            scheduler.advance(by: 0.1)
        }
        #expect(driver.isMoving)
        #expect(camera.relativeCommands == [right])
    }

    @Test("0,0 arrête tout de suite")
    func zeroStops() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        try driver.move(pan: 0, tilt: 0, from: 1)
        #expect(!driver.isMoving)
        #expect(camera.relativeCommands == [right, .stop])
        #expect(scheduler.pendingCount == 0)
    }

    @Test("0,0 à l'arrêt n'envoie rien")
    func zeroWhenIdle() throws {
        try driver.move(pan: 0, tilt: 0, from: 1)
        #expect(camera.relativeCommands.isEmpty)
    }

    @Test("La déconnexion du dernier pilote arrête ; celle d'un autre client non")
    func disconnect() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        driver.clientDisconnected(2)
        #expect(driver.isMoving)
        driver.clientDisconnected(1)
        #expect(!driver.isMoving)
        #expect(camera.relativeCommands == [right, .stop])
    }

    @Test("Un arrêt automatique refusé est retenté 300 ms plus tard")
    func stopRetry() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        camera.failNextWrite = .ioKit(-536870212)
        scheduler.advance(by: 0.31)
        #expect(driver.isMoving)
        #expect(camera.relativeCommands == [right])
        #expect(log.lines.count == 1)
        scheduler.advance(by: 0.31)
        #expect(camera.relativeCommands == [right, .stop])
        #expect(!driver.isMoving)
    }

    @Test("Un arrêt explicite refusé est retenté, et le mouvement reste signalé jusque-là")
    func explicitStopRetry() throws {
        var changes = 0
        try driver.move(pan: 1, tilt: 0, from: 1)
        driver.onChange = { changes += 1 }
        camera.failNextWrite = .ioKit(-536870212)
        #expect(throws: CameraError.ioKit(-536870212)) { try driver.move(pan: 0, tilt: 0, from: 1) }
        #expect(driver.isMoving)
        scheduler.advance(by: 0.31)
        #expect(camera.relativeCommands == [right, .stop])
        #expect(!driver.isMoving)
        #expect(changes >= 1)
    }

    @Test("Position relue chaque seconde pendant le mouvement, puis à l'arrêt")
    func polling() throws {
        var changes = 0
        driver.onChange = { changes += 1 }
        try driver.move(pan: 1, tilt: 0, from: 1)
        camera.position = PanTiltPosition(pan: 20, tilt: -1)
        for _ in 0..<10 {
            scheduler.advance(by: 0.1)
            try driver.move(pan: 1, tilt: 0, from: 1)
        }
        #expect(driver.position == PanTiltPosition(pan: 20, tilt: -1))
        camera.position = PanTiltPosition(pan: 30, tilt: -1)
        try driver.move(pan: 0, tilt: 0, from: 1)
        #expect(driver.position == PanTiltPosition(pan: 30, tilt: -1))
        #expect(changes == 4)
    }

    @Test("reset oublie mouvement et position")
    func reset() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        driver.refreshPosition()
        driver.reset()
        #expect(!driver.isMoving)
        #expect(driver.position == nil)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Relecture ratée : position inconnue, publiée, jamais une valeur périmée")
    func failedReadForgetsPosition() {
        var changes = 0
        driver.onChange = { changes += 1 }
        driver.refreshPosition()
        #expect(driver.position == camera.position)
        camera.failReads = true
        driver.refreshPosition()
        #expect(driver.position == nil)
        #expect(changes == 2)
    }
}
