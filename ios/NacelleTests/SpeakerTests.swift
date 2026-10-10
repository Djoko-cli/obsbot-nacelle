import Foundation
import NacelleProtocol
import Testing
@testable import Nacelle

@MainActor
@Suite("Parole : maintenir pour parler", .timeLimit(.minutes(1)))
struct SpeakerTests {
    let audio = FakeSpeechAudio()
    let link = FakeVoiceLink()
    let permission = FakeMicPermission(.granted)
    let speaker: Speaker
    let box = StopBox()

    @MainActor
    final class StopBox {
        var reasons: [Speaker.StopReason] = []
    }

    init() {
        speaker = Speaker(audio: audio, link: link, permission: permission)
        let box = box
        speaker.onStopped = { box.reasons.append($0) }
    }

    /// Attend (5 s au plus) qu'une condition soit vraie.
    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    /// Appuie et attend que la parole soit en cours.
    private func startSpeaking() async {
        let task = Task { await speaker.press() }
        #expect(await until { speaker.phase == .speaking })
        await task.value
    }

    @Test("Appui : le micro démarre, la parole est en cours ; relâchement : le micro s'arrête")
    func pressAndRelease() async {
        #expect(speaker.phase == .idle)
        await startSpeaking()
        #expect(audio.beginCount == 1)
        #expect(speaker.isActive)
        speaker.release()
        #expect(speaker.phase == .idle)
        #expect(audio.endCount == 1)
        #expect(box.reasons == [.release])
        #expect(speaker.level == 0)
    }

    @Test("Les paquets du micro partent dans l'ordre, un seul envoi à la fois")
    func sendsInOrderOneAtATime() async {
        await startSpeaking()
        audio.deliver([voicePacket(1), voicePacket(2), voicePacket(3)])
        #expect(link.frames == [voicePacket(1)])
        #expect(link.inFlight == 1)
        link.complete()
        #expect(link.frames == [voicePacket(1), voicePacket(2)])
        link.complete()
        #expect(link.frames == [voicePacket(1), voicePacket(2), voicePacket(3)])
        #expect(link.inFlight == 1)
        link.complete()
        #expect(link.inFlight == 0)
    }

    @Test("File bornée : au plus 10 paquets en attente, le plus ancien est jeté si l'envoi prend du retard")
    func boundedQueue() async {
        await startSpeaking()
        // Le premier part (et reste en vol), les 14 suivants se disputent 10 places.
        audio.deliver((1...15).map { voicePacket(UInt8($0)) })
        #expect(link.frames == [voicePacket(1)])
        #expect(speaker.droppedPackets == 4)
        for _ in 0..<11 {
            link.complete()
        }
        // Parti : le 1er, puis les 10 plus récents (6 à 15) ; 2 à 5 ont été jetés.
        #expect(link.frames == [voicePacket(1)] + (6...15).map { voicePacket(UInt8($0)) })
    }

    @Test("Le niveau du micro est exposé pendant la parole")
    func level() async {
        await startSpeaking()
        audio.deliver([], level: 0.7)
        #expect(speaker.level == 0.7)
    }

    @Test("Préparation : actif dès l'appui, micro « en direct » seulement à la première trame captée")
    func preparingUntilFirstFrame() async {
        audio.holdBegin = true
        let task = Task { await speaker.press() }
        #expect(await until { audio.isBeginPending })
        // Le doigt est posé, le micro n'est pas encore ouvert : retour visuel immédiat, jauge muette.
        #expect(speaker.isActive)
        #expect(speaker.isPreparing)
        #expect(!speaker.isMicLive)
        audio.finishBegin(true)
        await task.value
        #expect(speaker.phase == .speaking)
        // Micro ouvert mais aucune trame encore : toujours en préparation.
        #expect(speaker.isPreparing)
        audio.deliver([], level: 0)
        #expect(speaker.isPreparing)
        audio.deliver([voicePacket(1)], level: 0.4)
        #expect(!speaker.isPreparing)
        #expect(speaker.isMicLive)
        #expect(speaker.level == 0.4)
        // Relâchement : tout retombe, la prochaine prise de parole repasse par la préparation.
        speaker.release()
        #expect(!speaker.isMicLive)
        #expect(!speaker.isPreparing)
        audio.holdBegin = false
        await startSpeaking()
        #expect(speaker.isPreparing)
    }

    @Test("Le niveau seul, sans paquet complet, suffit à dire que le micro est en direct")
    func levelAloneMeansLive() async {
        await startSpeaking()
        audio.deliver([], level: 0.2)
        #expect(speaker.isMicLive)
    }

    @Test("Relâché pendant le démarrage du micro : il ne parle jamais, le micro est refermé")
    func releasedWhileStarting() async {
        audio.holdBegin = true
        let task = Task { await speaker.press() }
        #expect(await until { audio.isBeginPending })
        #expect(speaker.phase == .starting)
        speaker.release()
        audio.finishBegin(true)
        await task.value
        #expect(speaker.phase == .idle)
        #expect(audio.endCount == 1)
        audio.deliver([voicePacket(1)])
        #expect(link.frames.isEmpty)
    }

    @Test("Appui, relâchement et nouvel appui pendant le démarrage : une seule ouverture, et la parole continue")
    func pressAgainWhileStarting() async {
        audio.holdBegin = true
        let first = Task { await speaker.press() }
        #expect(await until { audio.isBeginPending })
        speaker.release()
        let second = Task { await speaker.press() }
        await second.value
        audio.finishBegin(true)
        await first.value
        #expect(speaker.phase == .speaking)
        #expect(audio.beginCount == 1)
        #expect(audio.endCount == 0)
    }

    @Test("Micro jamais demandé : la question du système, puis aucune parole toute seule ; le nouvel appui parle")
    func asksPermission() async {
        permission.access = .notDetermined
        permission.grants = true
        await speaker.press()
        #expect(permission.requestCount == 1)
        #expect(!speaker.micDenied)
        #expect(speaker.phase == .idle)
        #expect(audio.beginCount == 0)
        speaker.release()
        await startSpeaking()
        #expect(permission.requestCount == 1)
        #expect(audio.beginCount == 1)
    }

    @Test("Micro refusé à la question : rien n'est ouvert, l'accès est marqué refusé")
    func permissionDenied() async {
        permission.access = .notDetermined
        permission.grants = false
        await speaker.press()
        #expect(speaker.phase == .idle)
        #expect(audio.beginCount == 0)
        #expect(speaker.micDenied)
        #expect(box.reasons == [.micDenied])
    }

    @Test("Micro déjà refusé : aucune question, aucune ouverture")
    func alreadyDenied() async {
        permission.access = .denied
        speaker.refreshAccess()
        #expect(speaker.micDenied)
        await speaker.press()
        #expect(permission.requestCount == 0)
        #expect(audio.beginCount == 0)
        #expect(box.reasons == [.micDenied])
    }

    @Test("Relâché pendant la question du système : le micro ne s'ouvre pas")
    func releasedWhileAsking() async {
        permission.access = .notDetermined
        permission.holdRequest = true
        let task = Task { await speaker.press() }
        #expect(await until { permission.requestCount == 1 })
        speaker.release()
        permission.answerRequest(true)
        await task.value
        #expect(speaker.phase == .idle)
        #expect(audio.beginCount == 0)
    }

    @Test("Le micro ne démarre pas : la parole ne commence pas, avec l'échec en raison")
    func beginFails() async {
        audio.beginResult = false
        await speaker.press()
        #expect(speaker.phase == .idle)
        #expect(box.reasons == [.failure])
        #expect(audio.endCount == 1)
    }

    @Test("Arrêts automatiques : chaque raison coupe le micro et le dit", arguments: [
        Speaker.StopReason.connection, .talkbackOff, .background,
    ])
    func automaticStops(reason: Speaker.StopReason) async {
        await startSpeaking()
        speaker.stop(reason)
        #expect(speaker.phase == .idle)
        #expect(audio.endCount == 1)
        #expect(box.reasons == [reason])
        // Plus rien ne part ensuite.
        audio.deliver([voicePacket(9)])
        #expect(link.frames.isEmpty)
    }

    @Test("Interruption audio (appel, Siri) : la parole s'arrête")
    func interruption() async {
        await startSpeaking()
        audio.onInterrupted?()
        #expect(speaker.phase == .idle)
        #expect(audio.endCount == 1)
        #expect(box.reasons == [.interruption])
    }

    @Test("Connexion tombée au premier envoi : la parole s'arrête")
    func sendRefused() async {
        await startSpeaking()
        link.accepts = false
        audio.deliver([voicePacket(1)])
        #expect(speaker.phase == .idle)
        #expect(box.reasons == [.connection])
    }

    @Test("Arrêt sans parole en cours : sans effet")
    func stopWhenIdle() {
        speaker.stop(.background)
        speaker.release()
        #expect(box.reasons.isEmpty)
        #expect(audio.endCount == 0)
    }

    @Test("Arrêt pendant le démarrage : la parole ne commence pas même si le doigt reste appuyé")
    func stopWhileStarting() async {
        audio.holdBegin = true
        let task = Task { await speaker.press() }
        #expect(await until { audio.isBeginPending })
        speaker.stop(.connection)
        audio.finishBegin(true)
        await task.value
        #expect(speaker.phase == .idle)
        #expect(audio.endCount == 1)
        #expect(box.reasons == [.connection])
    }

    @Test("Une fin d'envoi tardive d'une prise de parole précédente ne perturbe pas la suivante")
    func staleCompletion() async {
        await startSpeaking()
        audio.deliver([voicePacket(1)])
        speaker.release()
        await startSpeaking()
        audio.deliver([voicePacket(2), voicePacket(3)])
        #expect(link.frames == [voicePacket(1), voicePacket(2)])
        // La fin de l'envoi du paquet 1 (ancienne prise) arrive : elle ne libère pas l'envoi du paquet 2.
        link.complete()
        #expect(link.frames == [voicePacket(1), voicePacket(2)])
        link.complete()
        #expect(link.frames == [voicePacket(1), voicePacket(2), voicePacket(3)])
    }

    @Test("Nouvel appui après un arrêt : la parole repart")
    func pressAfterStop() async {
        await startSpeaking()
        speaker.stop(.connection)
        await startSpeaking()
        #expect(audio.beginCount == 2)
    }
}
