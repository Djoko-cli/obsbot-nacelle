import Foundation
import Testing
@testable import TalkCore

/// Tout ce qu'il faut pour faire parler un `TalkController` sans son, sans réseau et sans horloge réelle.
@MainActor
final class Rig {
    static let start = Date(timeIntervalSince1970: 1_791_000_000)
    static let nas = "192.0.2.10"

    let scheduler = FakeScheduler()
    let catalog: FakeCatalog
    let output = FakeOutput()
    let volume = FakeVolume()
    let state = MemoryStateStore()
    let recovery: MemoryRecoveryStore
    let log = LogRecorder()
    let controller: TalkController
    let speaker: DeviceID = 41

    init(
        devices: [AudioDeviceInfo] = [.external(id: 60), .builtInMicrophone(), .builtInSpeakers(id: 41)],
        settings: TalkSettings = TalkSettings(allowedSources: ["127.0.0.1", Rig.nas]),
        volumeState: SpeakerVolumeState = SpeakerVolumeState(volume: 0.8, muted: false),
        recovery: MemoryRecoveryStore = MemoryRecoveryStore(),
        autoStart: Bool = true
    ) {
        catalog = FakeCatalog(devices)
        self.recovery = recovery
        volume.states[41] = volumeState
        let scheduler = scheduler
        controller = TalkController(
            settings: settings,
            catalog: catalog,
            output: output,
            volume: volume,
            stateStore: state,
            recovery: recovery,
            scheduler: scheduler,
            now: { Rig.start.addingTimeInterval(scheduler.now) },
            processID: 4242,
            log: log.sink
        )
        if autoStart {
            controller.start()
        }
    }

    /// `count` paquets de 20 ms, le temps avançant d'autant après chacun.
    func send(_ packet: Data = voice, from source: String = "127.0.0.1", count: Int = 1) {
        for _ in 0..<count {
            controller.receive(packet, from: source)
            scheduler.advance(by: 0.02)
        }
    }

    func wait(_ seconds: TimeInterval) {
        scheduler.advance(by: seconds)
    }
}

@MainActor
@Suite("Contrôleur de talkd")
struct TalkControllerTests {
    @Test("Au démarrage : réglages et haut-parleurs journalisés, état « au repos » écrit")
    func startup() {
        let rig = Rig()
        #expect(rig.log.contains("talkd démarre"))
        #expect(rig.log.contains("1986"))
        #expect(rig.log.contains("192.0.2.10"))
        #expect(rig.log.contains("Haut-parleurs du Mac"))
        #expect(rig.state.saved == [TalkState(speaking: false, since: Rig.start, pid: 4242)])
        #expect(rig.output.startAttempts == 0)
    }

    @Test("Le premier paquet de voix ouvre une prise de parole : sortie sur les haut-parleurs intégrés (et non sur la sortie par défaut), état « en lecture »")
    func speechStarts() {
        let rig = Rig()
        rig.send(count: 1)
        #expect(rig.output.starts == [41])
        #expect(rig.output.isRunning)
        #expect(rig.state.last?.speaking == true)
        #expect(rig.log.contains("Prise de parole de 127.0.0.1"))
        #expect(rig.controller.isSpeaking)
    }

    @Test("Hors prise de parole, le silence n'est pas joué : rien ne démarre")
    func idleSilenceIgnored() {
        let rig = Rig()
        rig.send(silence, count: 50)
        #expect(rig.output.startAttempts == 0)
        #expect(!rig.controller.isSpeaking)
        #expect(rig.controller.counters.ignoredIdle == 50)
        #expect(rig.volume.writes.isEmpty)
    }

    @Test("Les paquets sans voix d'une prise de parole sont joués tels quels, pour ne pas hacher la voix")
    func silenceInsideSpeechIsPlayed() throws {
        let rig = Rig()
        rig.send(voice, count: 2)
        rig.send(silence, count: 4)
        let played = try #require(rig.output.buffer)
        #expect(played.bufferedSamples == 6 * 320)
    }

    @Test("La prise de parole finit 2 s après le dernier paquet de voix ; le silence entre-temps ne la prolonge pas")
    func speechEnds() {
        let rig = Rig()
        rig.send(voice, count: 5) // 100 ms
        rig.send(silence, count: 98) // 1,98 s depuis la dernière voix à l'instant du dernier paquet
        #expect(rig.controller.isSpeaking)
        rig.send(silence, count: 2)
        #expect(!rig.controller.isSpeaking)
        #expect(rig.state.last?.speaking == false)
        #expect(rig.log.contains("Fin de la prise de parole de 127.0.0.1"))
    }

    @Test("Une voix qui reprend avant 2 s prolonge la même prise de parole")
    func speechContinues() {
        let rig = Rig()
        rig.send(voice, count: 5)
        rig.wait(1.5)
        rig.send(voice, count: 5)
        rig.wait(1.5)
        #expect(rig.controller.isSpeaking)
        #expect(rig.controller.counters.speeches == 1)
        #expect(rig.log.lines.filter { $0.contains("Prise de parole de") }.count == 1)
        rig.wait(1)
        #expect(!rig.controller.isSpeaking)
    }

    @Test("La lecture s'arrête 10 s après la dernière voix (pas 10 s après la fin de la prise de parole), sans autre client CoreAudio")
    func outputStopsAfterTenSeconds() {
        let rig = Rig()
        rig.send(voice, count: 5)
        rig.wait(2.5)
        #expect(!rig.controller.isSpeaking)
        #expect(rig.output.isRunning)
        rig.wait(7)
        #expect(rig.output.isRunning)
        rig.wait(0.5)
        #expect(!rig.output.isRunning)
        #expect(rig.output.stops == 1)
        #expect(rig.log.contains("Lecture arrêtée"))
    }

    @Test("Dix cycles parole puis silence : dix démarrages et dix arrêts de la même sortie, jamais deux sorties à la fois")
    func tenCycles() {
        let rig = Rig()
        for _ in 0..<10 {
            rig.send(voice, count: 5)
            rig.wait(12)
        }
        #expect(rig.output.starts == Array(repeating: 41, count: 10))
        #expect(rig.output.stops == 10)
        #expect(!rig.output.isRunning)
        #expect(rig.controller.counters.speeches == 10)
        #expect(rig.scheduler.pendingCount == 0)
    }

    @Test("Sortie arrêtée d'elle-même (par le système) : journalisé à la prise de parole suivante, puis redémarrée sur les haut-parleurs")
    func outputStoppedBySystem() {
        let rig = Rig()
        rig.send(voice, count: 5)
        rig.wait(3)
        // Pendant les 10 s d'attente, le système arrête l'unité (changement de configuration audio).
        rig.output.stoppedBySystem()
        rig.send(voice, count: 2)
        #expect(rig.log.contains("La sortie s'était arrêtée d'elle-même"))
        #expect(rig.output.starts == [41, 41])
        #expect(rig.output.isRunning)
        // Un arrêt programmé par talkd, lui, n'est pas signalé.
        rig.wait(12)
        let lines = rig.log.lines.filter { $0.contains("d'elle-même") }.count
        rig.send(voice, count: 2)
        #expect(rig.log.lines.filter { $0.contains("d'elle-même") }.count == lines)
    }

    @Test("Une nouvelle prise de parole pendant les 10 s annule l'arrêt : la sortie reste ouverte, sans redémarrage")
    func speechCancelsIdleStop() {
        let rig = Rig()
        rig.send(voice, count: 5)
        rig.wait(5)
        rig.send(voice, count: 5)
        rig.wait(8)
        #expect(rig.output.isRunning)
        #expect(rig.output.starts == [41])
        #expect(rig.output.stops == 0)
        rig.wait(3)
        #expect(!rig.output.isRunning)
    }

    @Test("Une autre source qui parle pendant la prise de parole est ignorée et comptée ; la première garde le haut-parleur")
    func oneSourceAtATime() throws {
        let rig = Rig()
        rig.send(voice, from: "127.0.0.1", count: 3)
        let before = try #require(rig.output.buffer).bufferedSamples
        rig.send(voice, from: Rig.nas, count: 4)
        #expect(rig.controller.counters.rejectedConcurrent == 4)
        #expect(try #require(rig.output.buffer).bufferedSamples == before)
        rig.send(voice, from: "127.0.0.1", count: 1)
        #expect(rig.controller.counters.speeches == 1)
        rig.wait(2.5)
        #expect(rig.log.contains("Fin de la prise de parole de 127.0.0.1"))
        #expect(rig.log.contains("4 paquets d'une autre source ignorés"))
        // La parole finie, l'autre source peut prendre la main.
        rig.send(voice, from: Rig.nas, count: 2)
        #expect(rig.controller.isSpeaking)
        #expect(rig.log.contains("Prise de parole de 192.0.2.10"))
    }

    @Test("Source non autorisée : ignorée et comptée, jamais jouée, journalisée une fois par minute au plus")
    func unauthorizedSource() {
        let rig = Rig()
        rig.send(voice, from: "192.0.2.99", count: 150) // 3 s
        #expect(rig.controller.counters.rejectedSource == 150)
        #expect(rig.output.startAttempts == 0)
        #expect(!rig.controller.isSpeaking)
        #expect(rig.log.lines.filter { $0.contains("192.0.2.99") }.count == 1)
        rig.wait(61)
        rig.send(voice, from: "192.0.2.99", count: 2)
        #expect(rig.log.lines.filter { $0.contains("192.0.2.99") }.count == 2)
        #expect(rig.log.lines.last(where: { $0.contains("192.0.2.99") })?.contains("150") == true)
        // Une autre source refusée a sa propre ligne.
        rig.send(voice, from: "10.0.0.5", count: 1)
        #expect(rig.log.lines.filter { $0.contains("10.0.0.5") }.count == 1)
    }

    @Test("Des adresses sources en grand nombre (usurpées) ne remplissent pas le journal : au plus 10 lignes de refus par minute, toutes sources confondues, tous les refus restant comptés")
    func rejectionFlood() {
        let rig = Rig()
        for index in 0..<500 {
            rig.controller.receive(voice, from: "192.168.0.\(index % 250 + 1)")
        }
        #expect(rig.controller.counters.rejectedSource == 500)
        #expect(rig.log.lines.filter { $0.contains("non autorisée") }.count == 10)
        // La minute suivante, le journal reprend et dit combien de lignes ont été tues.
        rig.wait(61)
        rig.controller.receive(voice, from: "192.168.0.77")
        #expect(rig.log.lines.filter { $0.contains("non autorisée") }.count == 11)
        #expect(rig.log.contains("lignes de refus tues"))
    }

    @Test("Taille anormale (vide, impaire, plus de 4 Ko) : ignorée et comptée ; une source déjà en parole n'en est pas dérangée")
    func badSizes() {
        let rig = Rig()
        rig.send(voice, count: 2)
        rig.controller.receive(Data(), from: "127.0.0.1")
        rig.controller.receive(Data(count: 641), from: "127.0.0.1")
        rig.controller.receive(Data(count: 4098), from: "127.0.0.1")
        #expect(rig.controller.counters.rejectedSize == 3)
        #expect(rig.controller.isSpeaking)
        #expect(rig.log.contains("taille"))
    }

    @Test("Datagramme trop gros, non copié par le récepteur : compté en taille anormale d'après sa taille réelle ; la source reste jugée d'abord")
    func uncopiedDatagram() {
        let rig = Rig()
        rig.controller.receive(Datagram(payload: nil, size: 9000, source: "127.0.0.1"))
        #expect(rig.controller.counters.rejectedSize == 1)
        rig.controller.receive(Datagram(payload: nil, size: 9000, source: "192.0.2.99"))
        #expect(rig.controller.counters.rejectedSource == 1)
        #expect(rig.output.startAttempts == 0)
    }

    @Test("Échec de la sortie (coreaudiod ne répond pas) : erreur journalisée, une seule tentative par prise de parole, nouvel essai à la suivante")
    func outputFailure() {
        let rig = Rig(volumeState: SpeakerVolumeState(volume: 0.1, muted: true))
        rig.output.failNextStart = true
        rig.send(voice, count: 100) // 2 s de voix
        #expect(rig.output.startAttempts == 1)
        #expect(rig.log.contains("coreaudiod ne répond pas"))
        #expect(rig.state.saved.allSatisfy { !$0.speaking })
        #expect(rig.volume.writes.isEmpty)
        #expect(rig.output.buffer == nil)
        rig.wait(15)
        // La prise de parole suivante réessaie, et réussit.
        rig.send(voice, count: 3)
        #expect(rig.output.startAttempts == 2)
        #expect(rig.output.isRunning)
        #expect(rig.state.last?.speaking == true)
    }

    @Test("Haut-parleurs intégrés introuvables : rien n'est joué, erreur journalisée, nouvel essai à la prise de parole suivante")
    func noSpeakers() {
        let rig = Rig(devices: [.external(id: 60), .builtInMicrophone()])
        #expect(rig.log.contains("introuvables"))
        rig.send(voice, count: 100)
        #expect(rig.output.startAttempts == 0)
        #expect(rig.state.saved.allSatisfy { !$0.speaking })
        rig.wait(15)
        rig.catalog.list = [.external(id: 60), .builtInSpeakers(id: 41)]
        rig.send(voice, count: 3)
        #expect(rig.output.starts == [41])
        #expect(rig.state.last?.speaking == true)
    }

    @Test("Liste de périphériques qui change : les haut-parleurs sont retrouvés, la sortie rouverte sur le nouveau numéro")
    func deviceListChanges() {
        let rig = Rig()
        rig.send(voice, count: 3)
        rig.wait(2.5)
        #expect(rig.output.starts == [41])
        // La liste change (les haut-parleurs reviennent sous un autre numéro) avant la fin des 10 s.
        rig.catalog.change(to: [.external(id: 60), .builtInSpeakers(id: 77)])
        #expect(rig.log.contains("77"))
        rig.send(voice, count: 3)
        #expect(rig.output.starts == [41, 77])
        #expect(rig.output.stops == 1)
        #expect(rig.output.isRunning)
    }

    @Test("Haut-parleurs qui disparaissent de la liste : journalisé, rien n'est joué à la prise de parole suivante")
    func speakersDisappear() {
        let rig = Rig()
        rig.catalog.change(to: [.external(id: 60)])
        #expect(rig.log.lines.filter { $0.contains("introuvables") }.count == 1)
        rig.send(voice, count: 3)
        #expect(rig.output.startAttempts == 0)
    }

    @Test("Liste des périphériques illisible : journalisé, rien n'est joué")
    func catalogFailure() {
        struct Boom: Error {}
        let rig = Rig()
        rig.catalog.failure = Boom()
        rig.catalog.change(to: [])
        rig.send(voice, count: 3)
        #expect(rig.output.startAttempts == 0)
        #expect(rig.log.contains("illisible"))
    }

    @Test("Volume minimum : Mac en sourdine, relevé à 30 % pendant la parole puis rétabli à la fin de la prise de parole")
    func volumeFloorAroundSpeech() {
        let rig = Rig(volumeState: SpeakerVolumeState(volume: 0.1, muted: true))
        rig.send(voice, count: 5)
        #expect(rig.volume.states[41] == SpeakerVolumeState(volume: 0.3, muted: false))
        rig.wait(2.5)
        #expect(rig.volume.states[41] == SpeakerVolumeState(volume: 0.1, muted: true))
    }

    @Test("Volume au-dessus du seuil : jamais touché")
    func volumeAboveFloor() {
        let rig = Rig(volumeState: SpeakerVolumeState(volume: 0.8, muted: false))
        rig.send(voice, count: 5)
        rig.wait(15)
        #expect(rig.volume.writes.isEmpty)
    }

    @Test("L'utilisateur change le volume pendant la parole : rien n'est rétabli")
    func userVolumeWins() {
        let rig = Rig(volumeState: SpeakerVolumeState(volume: 0.1, muted: false))
        rig.send(voice, count: 5)
        rig.volume.userSets(device: 41, volume: 0.7)
        rig.send(voice, count: 5)
        rig.wait(2.5)
        #expect(rig.volume.states[41]?.volume == 0.7)
    }

    @Test("Volume illisible : la voix passe quand même, au volume actuel")
    func unreadableVolumeStillPlays() {
        let rig = Rig(volumeState: SpeakerVolumeState(volume: 0.1, muted: false))
        rig.volume.failReads = true
        rig.send(voice, count: 5)
        #expect(rig.output.isRunning)
        #expect(rig.state.last?.speaking == true)
    }

    @Test("Fin de la prise de parole : la ligne résume la durée de voix, les paquets d'une autre source et les ms jetés par le tampon")
    func summaryLine() {
        let rig = Rig()
        // 15 paquets (300 ms) sans que le moteur ne tire rien : 100 ms de trop sont jetés.
        rig.send(voice, count: 15)
        rig.wait(2.5)
        let line = rig.log.lines.last { $0.contains("Fin de la prise de parole") }
        #expect(line?.contains("100 ms jetés par le tampon") == true)
        #expect(line?.contains("0,3 s de voix") == true)
    }

    @Test("Arrêt du daemon pendant une prise de parole : volume rétabli, état « au repos », sortie arrêtée, plus aucune minuterie")
    func shutdown() {
        let rig = Rig(volumeState: SpeakerVolumeState(volume: 0.1, muted: true))
        rig.send(voice, count: 5)
        rig.controller.shutdown()
        #expect(rig.volume.states[41] == SpeakerVolumeState(volume: 0.1, muted: true))
        #expect(rig.state.last?.speaking == false)
        #expect(!rig.output.isRunning)
        #expect(rig.scheduler.pendingCount == 0)
        #expect(rig.log.contains("talkd s'arrête"))
    }

    @Test("Échec d'écriture de l'état : journalisé, la voix passe quand même")
    func stateFailure() {
        struct Boom: Error {}
        let rig = Rig()
        rig.state.failure = Boom()
        rig.send(voice, count: 3)
        #expect(rig.output.isRunning)
        #expect(rig.log.contains("état"))
    }

    @Test("Le journal ne contient jamais de son : seulement des phrases")
    func noAudioInLog() {
        let rig = Rig()
        rig.send(voice, count: 10)
        rig.wait(15)
        #expect(rig.log.lines.allSatisfy { $0.utf8.count < 400 })
    }
}
