import Foundation
import Testing
@testable import TalkCore

@Suite("Frein au démarrage de la phase CoreAudio")
struct StartupBrakeTests {
    static let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func decide(_ previous: StartupRecord?) -> StartupBrake.Decision {
        StartupBrake.decide(previous: previous, now: Self.now)
    }

    private func record(secondsAgo: TimeInterval, shortRuns: Int) -> StartupRecord {
        StartupRecord(lastCoreAudioStart: Self.now.addingTimeInterval(-secondsAgo), shortRuns: shortRuns)
    }

    @Test("Premier démarrage (aucun fichier) : aucun délai")
    func firstStart() {
        #expect(decide(nil) == StartupBrake.Decision(shortRuns: 0, delay: 0))
    }

    @Test("Phase précédente commencée il y a moins de 60 s : une phase courte de plus ; la première ne freine pas")
    func oneShortRun() {
        #expect(decide(record(secondsAgo: 30, shortRuns: 0)) == StartupBrake.Decision(shortRuns: 1, delay: 0))
    }

    @Test("Dès deux phases courtes de suite : 30 s, puis le double à chaque fois")
    func doubling() {
        #expect(decide(record(secondsAgo: 11, shortRuns: 1)).delay == 30)
        #expect(decide(record(secondsAgo: 11, shortRuns: 2)).delay == 60)
        #expect(decide(record(secondsAgo: 11, shortRuns: 3)).delay == 120)
        #expect(decide(record(secondsAgo: 11, shortRuns: 4)).delay == 240)
        #expect(decide(record(secondsAgo: 11, shortRuns: 5)).delay == 480)
    }

    @Test("Le délai plafonne à 15 min, même après un très grand nombre de phases courtes")
    func cap() {
        #expect(decide(record(secondsAgo: 11, shortRuns: 6)).delay == 900)
        #expect(decide(record(secondsAgo: 11, shortRuns: 40)).delay == 900)
        #expect(StartupBrake.delay(shortRuns: Int.max) == 900)
        #expect(decide(record(secondsAgo: 11, shortRuns: Int.max)).shortRuns == Int.max)
    }

    @Test("Phase précédente commencée il y a 60 s ou plus : le compte revient à 0, aucun délai")
    func reset() {
        #expect(decide(record(secondsAgo: 60, shortRuns: 5)) == StartupBrake.Decision(shortRuns: 0, delay: 0))
        #expect(decide(record(secondsAgo: 3600, shortRuns: 9)) == StartupBrake.Decision(shortRuns: 0, delay: 0))
    }

    @Test("Horloge revenue en arrière : compté comme une phase courte (prudent pour coreaudiod)")
    func clockBackwards() {
        #expect(decide(record(secondsAgo: -500, shortRuns: 1)).shortRuns == 2)
    }

    @Test("Effet : un plantage en boucle (relance toutes les 10 s) tombe à quelques phases CoreAudio par heure")
    func crashLoopPerHour() {
        var clock = Self.now
        var previous: StartupRecord?
        var phases = 0
        let end = clock.addingTimeInterval(3600)
        while clock < end {
            let decision = StartupBrake.decide(previous: previous, now: clock)
            clock = clock.addingTimeInterval(decision.delay)
            guard clock < end else { break }
            // La phase CoreAudio commence, puis talkd plante aussitôt ; launchd le relance 10 s plus tard.
            phases += 1
            previous = StartupRecord(lastCoreAudioStart: clock, shortRuns: decision.shortRuns)
            clock = clock.addingTimeInterval(10)
        }
        #expect(phases <= 12)
    }

    @MainActor
    @Test("Le fichier talkd-runs.json : écrit de façon atomique, relu, effacé ; absent, rien")
    func fileStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "support/talkd-runs.json")
        let store = JSONFileStartupRecordStore(url: url)
        #expect(try store.load() == nil)
        let saved = StartupRecord(lastCoreAudioStart: Self.now, shortRuns: 3)
        try store.save(saved)
        #expect(try store.load() == saved)
        try store.clear()
        #expect(try store.load() == nil)
        try store.clear()
    }

    @Test("Emplacement : talkd-runs.json dans le dossier de travail")
    func path() {
        let paths = TalkPaths(environment: ["TALKD_SUPPORT_DIR": "/tmp-test/talkd"], home: URL(fileURLWithPath: "/home-test"))
        #expect(paths.runs.path == "/tmp-test/talkd/talkd-runs.json")
    }
}

@MainActor
@Suite("Frein au démarrage dans le contrôleur")
struct ControllerBrakeTests {
    @Test("Sans frein : la phase CoreAudio commence aussitôt, et elle est notée")
    func noBrake() {
        let rig = Rig(autoStart: false)
        var phases = 0
        rig.controller.start(braking: StartupBrake.Decision(shortRuns: 1, delay: 0)) { phases += 1 }
        #expect(phases == 1)
        #expect(rig.log.contains("talkd démarre"))
        #expect(rig.catalog.queries == 1)
    }

    @Test("Freiné : état « au repos » écrit tout de suite, aucun appel CoreAudio, paquets ignorés et comptés ; puis démarrage à l'échéance")
    func braked() {
        let rig = Rig(autoStart: false)
        var phases = 0
        rig.controller.start(braking: StartupBrake.Decision(shortRuns: 3, delay: 60)) { phases += 1 }
        #expect(rig.log.contains("Frein au démarrage"))
        #expect(rig.log.contains("60 s"))
        #expect(rig.state.last?.speaking == false)
        #expect(rig.catalog.queries == 0)
        #expect(phases == 0)
        rig.send(voice, count: 10)
        #expect(rig.controller.counters.ignoredBraked == 10)
        #expect(rig.output.startAttempts == 0)
        #expect(rig.volume.writes.isEmpty)
        rig.wait(60)
        #expect(phases == 1)
        #expect(rig.catalog.queries == 1)
        rig.send(voice, count: 2)
        #expect(rig.output.starts == [41])
    }

    @Test("Arrêt du daemon pendant le frein : la phase CoreAudio n'a jamais lieu")
    func shutdownWhileBraked() {
        let rig = Rig(autoStart: false)
        var phases = 0
        rig.controller.start(braking: StartupBrake.Decision(shortRuns: 2, delay: 30)) { phases += 1 }
        rig.controller.shutdown()
        rig.wait(60)
        #expect(phases == 0)
        #expect(rig.catalog.queries == 0)
        #expect(rig.scheduler.pendingCount == 0)
    }
}
