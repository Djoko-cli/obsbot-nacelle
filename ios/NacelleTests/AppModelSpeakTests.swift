import CryptoKit
import Foundation
import NacelleProtocol
import Testing
@testable import Nacelle

/// Un `AppModel` branché sur des doublures, pour le bouton « parler ».
@MainActor
final class SpeakHarness {
    let transports = FakeTransports()
    let scheduler = FakeScheduler()
    let defaults = UserDefaults(suiteName: "nacelle-speak-\(UUID().uuidString)")!
    let audio = FakeSpeechAudio()
    let permission = FakeMicPermission(.granted)
    let model: AppModel

    init() {
        SettingsStore(defaults: defaults).save(ConnectionSettings(host: "mac.exemple.ts.net"))
        let keys = FakeKeyStore()
        keys.key = SoftwareDeviceKey(key: P256.Signing.PrivateKey())
        let transports = transports
        model = AppModel(
            store: SettingsStore(defaults: defaults),
            ptz: PTZClient(
                makeTransport: { _ in transports.make() },
                browser: FakeBrowser(),
                keys: keys,
                pairingRecord: PairingRecord(defaults: defaults),
                scheduler: scheduler
            ),
            video: VideoSession(scheduler: scheduler, audioDevice: PlayoutAudioDevice()),
            scheduler: scheduler,
            recording: RecordingServices(
                makeRecorder: { FakeClipRecorder() },
                photos: FakePhotoSaver(),
                files: RecordingFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent("nacelle-none-\(UUID().uuidString)")) { _ in false },
                freeSpace: { .max },
                background: FakeBackgroundTasks(),
                now: { Date() }
            ),
            speech: .fake(audio: audio, permission: permission)
        )
    }

    /// Connexion authentifiée, puis l'état de ptzd avec ce `talkback` ; la vidéo est en lecture sauf `videoPlaying: false`.
    @discardableResult
    func connect(talkback: TalkbackAvailability = .ready, privacy: Bool = false, videoPlaying: Bool = true) throws -> FakeTransport {
        model.activate()
        // La parole passe par le son de la caméra : la vidéo doit être en lecture (sans vraie connexion WebRTC ici).
        model.video.phase = videoPlaying ? .playing : .connecting
        let transport = try #require(transports.last)
        transport.emit(.opened)
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.authenticated)))
        try send(talkback: talkback, privacy: privacy, on: transport)
        return transport
    }

    func send(talkback: TalkbackAvailability, privacy: Bool = false, on transport: FakeTransport) throws {
        let snapshot = StateSnapshot(
            camera: .connected, control: .ready, privacy: privacy, pan: 0, tilt: 0, zoom: 0, moving: false, talkback: talkback
        )
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.state(snapshot))))
    }

    /// Attend qu'une condition soit vraie, au plus 5 s.
    func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    /// Appuie et attend que la parole soit en cours.
    func speak() async throws {
        model.pressSpeak()
        #expect(await until { model.speaker.phase == .speaking })
    }
}

@MainActor
@Suite("Bouton parler dans le modèle de l'app", .timeLimit(.minutes(1)))
struct AppModelSpeakTests {
    let h = SpeakHarness()

    @Test("Hors connexion : bouton grisé, et un appui dit « Pas de connexion au Mac »")
    func offline() async {
        h.model.activate()
        #expect(h.model.speakAvailability == .noConnection)
        #expect(h.model.speakDimmed)
        h.model.pressSpeak()
        #expect(h.model.bannerText == "Pas de connexion au Mac")
        #expect(h.audio.beginCount == 0)
        h.model.releaseSpeak()
        h.model.deactivate()
    }

    @Test("Talkback éteint sur le Mac : bouton grisé, et un appui dit « Talkback est éteint sur le Mac »")
    func talkbackOff() throws {
        try h.connect(talkback: .unavailable)
        #expect(h.model.speakAvailability == .talkbackOff)
        #expect(h.model.speakDimmed)
        h.model.pressSpeak()
        #expect(h.model.bannerText == "Talkback est éteint sur le Mac")
        #expect(h.audio.beginCount == 0)
        h.model.deactivate()
    }

    @Test("Un ptzd plus ancien (sans champ talkback) : traité comme éteint")
    func legacyDaemon() throws {
        let transport = try h.connect(talkback: .ready)
        let legacy = #"{"aiTracking":"off","camera":"connected","control":"ready","moving":false,"pan":0,"privacy":false,"tilt":0,"type":"state","zoom":0}"#
        transport.emit(.message(legacy))
        #expect(h.model.speakAvailability == .talkbackOff)
        h.model.deactivate()
    }

    @Test("Talkback prêt : bouton actif ; appui : le micro s'ouvre ; relâchement : il se ferme")
    func ready() async throws {
        try h.connect()
        #expect(h.model.speakAvailability == .ready)
        #expect(!h.model.speakDimmed)
        try await h.speak()
        #expect(h.model.isSpeaking)
        #expect(h.audio.beginCount == 1)
        h.model.releaseSpeak()
        #expect(!h.model.isSpeaking)
        #expect(h.audio.endCount == 1)
        h.model.deactivate()
    }

    @Test("Retour visuel : actif et « en préparation » dès l'appui, jauge seulement à la première trame du micro")
    func preparingThenLive() async throws {
        try h.connect()
        h.audio.holdBegin = true
        h.model.pressSpeak()
        #expect(await h.until { h.audio.isBeginPending })
        #expect(h.model.isSpeaking)
        #expect(h.model.isPreparingSpeak)
        h.audio.finishBegin(true)
        #expect(await h.until { h.model.speaker.phase == .speaking })
        #expect(h.model.isPreparingSpeak)
        h.audio.deliver([voicePacket(1)], level: 0.5)
        #expect(h.model.isSpeaking)
        #expect(!h.model.isPreparingSpeak)
        #expect(h.model.micLevel == 0.5)
        h.model.releaseSpeak()
        #expect(!h.model.isSpeaking)
        #expect(!h.model.isPreparingSpeak)
        h.model.deactivate()
    }

    @Test("Vie privée active : on peut parler")
    func privacyAllowsSpeech() async throws {
        try h.connect(privacy: true)
        #expect(h.model.speakAvailability == .ready)
        try await h.speak()
        #expect(h.model.isSpeaking)
        h.model.deactivate()
    }

    @Test("Micro refusé : bouton atténué mais touchable ; un appui renvoie vers Réglages, sans ouvrir le micro")
    func micDenied() async throws {
        h.permission.access = .denied
        try h.connect()
        h.model.speaker.refreshAccess()
        #expect(h.model.speakDimmed)
        h.model.pressSpeak()
        #expect(await h.until { h.model.bannerText == "L'accès au micro est refusé : autorisez-le dans Réglages › PTZBot" })
        #expect(h.audio.beginCount == 0)
        h.model.deactivate()
    }

    @Test("Le micro ne démarre pas : un avis, pas de parole")
    func micFailure() async throws {
        h.audio.beginResult = false
        try h.connect()
        h.model.pressSpeak()
        #expect(await h.until { h.model.bannerText == "Le micro n'a pas pu démarrer." })
        #expect(!h.model.isSpeaking)
        h.model.deactivate()
    }

    @Test("Talkback s'éteint pendant la parole : elle s'arrête et le bouton se grise")
    func talkbackDropsWhileSpeaking() async throws {
        let transport = try h.connect()
        try await h.speak()
        try h.send(talkback: .unavailable, on: transport)
        #expect(!h.model.isSpeaking)
        #expect(h.audio.endCount == 1)
        #expect(h.model.speakDimmed)
        h.model.deactivate()
    }

    @Test("Connexion perdue pendant la parole : elle s'arrête")
    func connectionLostWhileSpeaking() async throws {
        let transport = try h.connect()
        try await h.speak()
        transport.emit(.closed)
        #expect(!h.model.isSpeaking)
        #expect(h.audio.endCount == 1)
        #expect(h.model.speakAvailability == .noConnection)
        h.model.deactivate()
    }

    @Test("Arrière-plan : la parole s'arrête")
    func backgroundStops() async throws {
        try h.connect()
        try await h.speak()
        h.model.deactivate()
        #expect(!h.model.isSpeaking)
        #expect(h.audio.endCount == 1)
    }

    @Test("App inactive (Centre de contrôle, alerte) : le doigt est perdu, la parole s'arrête")
    func pauseStops() async throws {
        try h.connect()
        try await h.speak()
        h.model.pause()
        #expect(!h.model.isSpeaking)
        #expect(h.audio.endCount == 1)
        h.model.deactivate()
    }

    @Test("Interruption audio (appel, Siri) : la parole s'arrête")
    func interruptionStops() async throws {
        try h.connect()
        try await h.speak()
        h.audio.onInterrupted?()
        #expect(!h.model.isSpeaking)
        h.model.deactivate()
    }

    @Test("I4 : vidéo pas connectée : bouton atténué, un appui dit pourquoi, le micro ne s'ouvre pas")
    func noVideo() throws {
        try h.connect(videoPlaying: false)
        #expect(h.model.speakAvailability == .noVideo)
        #expect(h.model.speakDimmed)
        h.model.pressSpeak()
        #expect(h.model.bannerText == "La vidéo n'est pas connectée : la parole a besoin du son de la caméra.")
        #expect(h.audio.beginCount == 0)
        #expect(h.permission.requestCount == 0)
        h.model.deactivate()
    }

    @Test("I4 : Talkback éteint prime sur la vidéo absente (le Mac est la première chose à régler)")
    func talkbackOffBeforeNoVideo() throws {
        try h.connect(talkback: .unavailable, videoPlaying: false)
        #expect(h.model.speakAvailability == .talkbackOff)
        h.model.deactivate()
    }

    @Test("I4 : la vidéo arrive : le bouton redevient actif")
    func videoArrives() throws {
        try h.connect(videoPlaying: false)
        #expect(h.model.speakAvailability == .noVideo)
        h.model.video.phase = .playing
        #expect(h.model.speakAvailability == .ready)
        #expect(!h.model.speakDimmed)
        h.model.deactivate()
    }

    @Test("I4 : vidéo perdue pendant la parole : elle s'arrête")
    func videoLostWhileSpeaking() async throws {
        try h.connect()
        try await h.speak()
        h.model.video.phase = .lost
        h.model.video.onEnded?()
        #expect(!h.model.isSpeaking)
        #expect(h.audio.endCount == 1)
        h.model.deactivate()
    }

    @Test("Un appui bref sur le bouton grisé ne démarre rien, même répété")
    func repeatedPressWhenBlocked() throws {
        try h.connect(talkback: .unavailable)
        for _ in 0..<3 {
            h.model.pressSpeak()
            h.model.releaseSpeak()
        }
        #expect(h.audio.beginCount == 0)
        #expect(h.permission.requestCount == 0)
        h.model.deactivate()
    }

    @Test("Le niveau du micro est visible dans le modèle pendant la parole")
    func levelVisible() async throws {
        try h.connect()
        try await h.speak()
        h.audio.deliver([], level: 0.4)
        #expect(h.model.micLevel == 0.4)
        h.model.releaseSpeak()
        #expect(h.model.micLevel == 0)
        h.model.deactivate()
    }
}
