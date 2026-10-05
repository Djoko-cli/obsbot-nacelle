import Testing
@testable import PTZCore

@MainActor
@Suite("Prise en main")
struct ControlTakerTests {
    let runner = FakeAIOffRunner()
    let log = LogRecorder()

    private func makeTaker(centerRunning: Bool = false) -> ControlTaker {
        ControlTaker(runner: runner, isObsbotCenterRunning: { centerRunning }, log: log.sink)
    }

    @Test("take lance l'utilitaire et passe à taking, puis ready")
    func success() {
        let taker = makeTaker()
        taker.take()
        #expect(taker.state == .taking)
        #expect(runner.runCount == 1)
        runner.finish(.success)
        #expect(taker.state == .ready)
    }

    @Test("Une demande pendant l'exécution n'en lance pas une seconde")
    func coalesces() {
        let taker = makeTaker()
        taker.take()
        taker.take()
        #expect(runner.runCount == 1)
    }

    @Test("Un échec donne failed et une ligne de journal")
    func failure() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.timeout)
        #expect(taker.state == .failed)
        #expect(log.lines.count == 1)
    }

    @Test("Une nouvelle prise en main relance l'utilitaire")
    func retake() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.success)
        taker.take()
        #expect(runner.runCount == 2)
        #expect(taker.state == .taking)
    }

    @Test("OBSBOT Center ouvert : avertissement journalisé")
    func obsbotCenterWarning() {
        makeTaker(centerRunning: true).take()
        #expect(log.lines.first?.contains("OBSBOT Center") == true)
    }
}
