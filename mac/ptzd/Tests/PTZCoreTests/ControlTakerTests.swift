import Testing
@testable import PTZCore

@MainActor
@Suite("Prise en main")
struct ControlTakerTests {
    let runner = FakeAIOffRunner()
    let scheduler = FakeScheduler()
    let log = LogRecorder()

    private func makeTaker(centerRunning: Bool = false) -> ControlTaker {
        ControlTaker(runner: runner, scheduler: scheduler, isObsbotCenterRunning: { centerRunning }, log: log.sink)
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

    @Test("Deux échecs : un nouvel essai après 3 s, puis failed, avec une ligne de journal chacun")
    func failure() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.timeout)
        #expect(taker.state == .taking)
        #expect(runner.runCount == 1)
        scheduler.advance(by: ControlTaker.retryDelay)
        #expect(runner.runCount == 2)
        runner.finish(.timeout)
        #expect(taker.state == .failed)
        #expect(log.lines.count == 2)
        scheduler.advance(by: 10)
        #expect(runner.runCount == 2)
    }

    @Test("Un échec suivi d'un succès donne ready")
    func retrySucceeds() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.unexpectedExit(6))
        scheduler.advance(by: ControlTaker.retryDelay)
        runner.finish(.success)
        #expect(taker.state == .ready)
        #expect(runner.runCount == 2)
    }

    @Test("Pendant l'attente du nouvel essai, une demande n'en lance pas d'autre")
    func coalescesDuringRetry() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.cameraNotFound)
        taker.take()
        scheduler.advance(by: ControlTaker.retryDelay)
        #expect(runner.runCount == 2)
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
