import Testing
@testable import PTZCore

@MainActor
@Suite("Zoom")
struct ZoomDriverTests {
    let camera = FakeCamera()
    let scheduler = FakeScheduler()
    let log = LogRecorder()
    let driver: ZoomDriver

    init() {
        driver = ZoomDriver(camera: camera, scheduler: scheduler, log: log.sink)
    }

    @Test("Envoi immédiat, borné à 0…100")
    func clamps() throws {
        try driver.set(150)
        #expect(camera.zoomCommands == [100])
        #expect(driver.value == 100)
    }

    @Test("Au plus 10 envois par seconde : seule la dernière valeur en attente part")
    func coalesces() throws {
        try driver.set(10)
        scheduler.advance(by: 0.02)
        try driver.set(20)
        try driver.set(30)
        #expect(camera.zoomCommands == [10])
        scheduler.advance(by: 0.08)
        #expect(camera.zoomCommands == [10, 30])
        #expect(driver.value == 30)
    }

    @Test("Après le délai, l'envoi est de nouveau immédiat")
    func immediateAfterInterval() throws {
        try driver.set(10)
        scheduler.advance(by: 0.1)
        try driver.set(20)
        #expect(camera.zoomCommands == [10, 20])
    }

    @Test("Un envoi différé refusé est journalisé")
    func deferredFailureIsLogged() throws {
        try driver.set(10)
        try driver.set(20)
        camera.failNextWrite = .ioKit(-536870212)
        scheduler.advance(by: 0.1)
        #expect(camera.zoomCommands == [10])
        #expect(log.lines.count == 1)
    }

    @Test("refresh relit la caméra ; reset oublie")
    func refreshAndReset() {
        driver.refresh()
        #expect(driver.value == 33)
        driver.reset()
        #expect(driver.value == nil)
    }
}
