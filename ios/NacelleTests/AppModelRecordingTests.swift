import CryptoKit
import Foundation
import NacelleProtocol
import Testing
@testable import Nacelle

/// Un `AppModel` branché sur des doublures : transport, enregistreur, Photos, disque et tâches de fond.
@MainActor
final class RecordingHarness {
    /// Réglages que le test change en cours de route.
    final class Knobs: @unchecked Sendable {
        var freeSpace: Int64 = 50_000_000_000
        var playable = false
        var now = Date()
    }

    let transports = FakeTransports()
    let scheduler = FakeScheduler()
    let defaults = UserDefaults(suiteName: "nacelle-rec-\(UUID().uuidString)")!
    let recorder = FakeClipRecorder()
    /// Le périphérique audio de ce banc d'essai seulement : les suites tournent en parallèle.
    let audioDevice = PlayoutAudioDevice()
    let photos = FakePhotoSaver()
    let background = FakeBackgroundTasks()
    let knobs = Knobs()
    let directory: URL
    let model: AppModel

    init(files: (URL) throws -> Void = { _ in }) throws {
        directory = try SyntheticMedia.temporaryDirectory()
        try files(directory)
        SettingsStore(defaults: defaults).save(ConnectionSettings(host: "mac.exemple.ts.net"))
        let keys = FakeKeyStore()
        keys.key = SoftwareDeviceKey(key: P256.Signing.PrivateKey())
        let transports = transports
        let knobs = knobs
        let recorder = recorder
        let directory = directory
        model = AppModel(
            store: SettingsStore(defaults: defaults),
            ptz: PTZClient(
                makeTransport: { _ in transports.make() },
                browser: FakeBrowser(),
                keys: keys,
                pairingRecord: PairingRecord(defaults: defaults),
                scheduler: scheduler
            ),
            video: VideoSession(scheduler: scheduler, audioDevice: audioDevice),
            scheduler: scheduler,
            recording: RecordingServices(
                makeRecorder: { recorder },
                photos: photos,
                files: RecordingFiles(directory: directory) { _ in knobs.playable },
                freeSpace: { knobs.freeSpace },
                background: background,
                now: { knobs.now }
            )
        )
    }

    /// Connexion authentifiée, puis l'état de ptzd.
    @discardableResult
    func connect(privacy: Bool = false) throws -> FakeTransport {
        model.activate()
        let transport = try #require(transports.last)
        transport.emit(.opened)
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.authenticated)))
        try send(privacy: privacy, on: transport)
        return transport
    }

    func send(privacy: Bool, camera: CameraPresence = .connected, on transport: FakeTransport) throws {
        let snapshot = StateSnapshot(camera: camera, control: .ready, privacy: privacy, pan: 0, tilt: 0, zoom: 0, moving: false)
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.state(snapshot))))
    }

    /// La vidéo joue et une image est arrivée (la connexion WebRTC n'est pas ouverte dans les essais).
    func playVideo() {
        model.video.phase = .playing
        model.video.frameReceived()
    }

    /// Prêt à enregistrer : connecté, hors vie privée, une image reçue, accès à Photos accordé.
    func ready() throws -> FakeTransport {
        photos.state.withLock { $0.access = .granted }
        let transport = try connect()
        playVideo()
        return transport
    }

    /// Attend que l'enregistrement revienne au repos, au plus 5 s.
    func settle() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.recording != .idle {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Attend qu'une condition soit vraie, au plus 5 s.
    func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func cleanup() {
        model.deactivate()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite("Enregistrement dans le modèle de l'app", .timeLimit(.minutes(1)))
struct AppModelRecordingTests {
    // MARK: Bouton

    @Test("Bouton rec : grisé tant que l'état de ptzd n'est pas connu et qu'aucune image n'est arrivée, ou en vie privée")
    func buttonEnabled() throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        h.photos.state.withLock { $0.access = .granted }
        #expect(!h.model.recordToggleEnabled)
        let transport = try h.connect()
        // État connu, mais aucune image encore.
        #expect(!h.model.recordToggleEnabled)
        // Une image en vol arrivée après la fermeture de la connexion ne suffit pas : la vidéo doit jouer.
        h.model.video.frameReceived()
        #expect(!h.model.recordToggleEnabled)
        h.playVideo()
        #expect(h.model.recordToggleEnabled)
        h.model.video.phase = .lost
        #expect(!h.model.recordToggleEnabled)
        h.model.video.phase = .playing
        #expect(h.model.recordToggleEnabled)
        try h.send(privacy: true, on: transport)
        #expect(!h.model.recordToggleEnabled)
        try h.send(privacy: false, on: transport)
        #expect(h.model.recordToggleEnabled)
    }

    @Test("Accès à Photos refusé : le bouton reste touchable, mais atténué")
    func buttonWhenDenied() throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        h.photos.state.withLock { $0.access = .denied }
        _ = try h.connect()
        h.playVideo()
        h.model.refreshPhotoAccess()
        #expect(h.model.photoAccessDenied)
        #expect(h.model.recordToggleEnabled)
    }

    // MARK: Démarrage et arrêt

    @Test("Premier appui : accès demandé, enregistrement lancé ; arrêt : vidéo rangée dans Photos, fichier effacé, avis et vibration")
    func startAndStop() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.connect()
        h.playVideo()
        #expect(h.photos.access == .notDetermined)
        await h.model.toggleRecording()
        #expect(h.photos.requestCount == 1)
        guard case .recording = h.model.recording else {
            Issue.record("l'enregistrement aurait dû démarrer : \(h.model.recording)")
            return
        }
        let url = try #require(h.recorder.url)
        #expect(url.lastPathComponent.hasPrefix("PTZBot-"))
        #expect(url.pathExtension == "mp4")
        #expect(url.deletingLastPathComponent().standardizedFileURL == h.directory.standardizedFileURL)
        #expect(h.model.video.isRecording)
        #expect(h.model.video.audioRing === h.recorder.state.withLock { $0.audioSource })
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(h.recorder.finishCount == 1)
        #expect(h.photos.saved == [url])
        #expect(h.photos.state.withLock { $0.existedAtSave } == [true])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(h.model.bannerText == "Vidéo enregistrée dans Photos (0:42)")
        #expect(h.model.savedCount == 1)
        #expect(!h.model.video.isRecording)
        #expect(h.background.begun == 1)
        #expect(h.background.ended == [1])
        // L'avis disparaît au bout de 5 s.
        h.scheduler.advance(by: AppModel.noticeDuration)
        #expect(h.model.bannerText != "Vidéo enregistrée dans Photos (0:42)")
    }

    @Test("Pendant la sauvegarde, le bouton est inactif et un deuxième appui ne fait rien")
    func savingState() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        h.recorder.state.withLock { $0.holdFinish = true }
        await h.model.toggleRecording()
        #expect(h.model.recording == .saving)
        #expect(!h.model.recordToggleEnabled)
        #expect(await h.until { h.recorder.finishCount == 1 })
        await h.model.toggleRecording()
        #expect(h.recorder.finishCount == 1)
        h.recorder.releaseFinish()
        #expect(await h.settle())
        #expect(h.photos.saved.count == 1)
    }

    @Test("Accès à Photos refusé à la demande : rien ne démarre, un avis dit où l'autoriser")
    func deniedAtRequest() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        h.photos.state.withLock { $0.answer = .denied }
        _ = try h.connect()
        h.playVideo()
        await h.model.toggleRecording()
        #expect(h.model.recording == .idle)
        #expect(h.recorder.url == nil)
        #expect(h.model.photoAccessDenied)
        #expect(h.model.bannerText == "L'accès à Photos est refusé : autorisez-le dans Réglages › PTZBot › Photos.")
        // Le bouton reste touchable : un nouvel appui redonne l'explication, sans nouvelle demande.
        h.scheduler.advance(by: AppModel.noticeDuration)
        await h.model.toggleRecording()
        #expect(h.photos.requestCount == 1)
        #expect(h.model.bannerText == "L'accès à Photos est refusé : autorisez-le dans Réglages › PTZBot › Photos.")
    }

    @Test("Moins de 500 Mo libres : rien ne démarre")
    func lowSpaceAtStart() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        h.knobs.freeSpace = AppModel.minimumFreeSpaceToStart - 1
        await h.model.toggleRecording()
        #expect(h.model.recording == .idle)
        #expect(h.recorder.url == nil)
        #expect(h.model.bannerText == "Espace insuffisant sur l'iPhone pour enregistrer.")
        h.scheduler.advance(by: AppModel.noticeDuration)
        h.knobs.freeSpace = AppModel.minimumFreeSpaceToStart
        await h.model.toggleRecording()
        guard case .recording = h.model.recording else {
            Issue.record("500 Mo pile suffisent")
            return
        }
    }

    @Test("L'enregistreur refuse de démarrer : avis d'échec, rien ne tourne")
    func recorderRefuses() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        h.recorder.state.withLock { $0.startError = FakeFailure() }
        await h.model.toggleRecording()
        #expect(h.model.recording == .idle)
        #expect(!h.model.video.isRecording)
        #expect(h.model.bannerText == "L'enregistrement a échoué.")
    }

    // MARK: Son

    @Test("Son coupé dans l'app : la piste audio est enregistrée, le haut-parleur reste muet, la piste revient à l'état du bouton à la fin")
    func soundStaysRecordedWhenMuted() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        h.model.soundWanted = false
        _ = try h.ready()
        #expect(!h.model.video.audioTrackEnabled)
        await h.model.toggleRecording()
        #expect(h.model.video.audioTrackEnabled)
        #expect(h.audioDevice.isSpeakerMuted)
        #expect(h.audioDevice.isCapturing)
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(!h.model.video.audioTrackEnabled)
        #expect(h.audioDevice.isSpeakerMuted)
        #expect(!h.audioDevice.isCapturing)
    }

    @Test("Son voulu : le haut-parleur joue pendant l'enregistrement et la piste reste active après")
    func soundPlayedWhenWanted() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        h.model.soundWanted = true
        _ = try h.ready()
        await h.model.toggleRecording()
        #expect(h.model.video.audioTrackEnabled)
        #expect(!h.audioDevice.isSpeakerMuted)
        // Couper le son en cours d'enregistrement ne touche qu'au haut-parleur.
        h.model.soundWanted = false
        #expect(h.model.video.audioTrackEnabled)
        #expect(h.audioDevice.isSpeakerMuted)
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(!h.model.video.audioTrackEnabled)
        h.model.soundWanted = false
    }

    // MARK: Arrêts automatiques

    @Test("Entrée en vie privée : l'enregistrement s'arrête et est sauvé ; le bouton reste grisé, rien ne reprend à la sortie")
    func privacyStops() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        let transport = try h.ready()
        await h.model.toggleRecording()
        try h.send(privacy: true, on: transport)
        #expect(await h.settle())
        #expect(h.photos.saved.count == 1)
        #expect(!h.model.recordToggleEnabled)
        try h.send(privacy: false, on: transport)
        #expect(h.model.recording == .idle)
        #expect(h.recorder.finishCount == 1)
    }

    @Test("Connexion à ptzd perdue : arrêt et sauvegarde")
    func ptzdLinkLostStops() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        let transport = try h.ready()
        await h.model.toggleRecording()
        transport.emit(.closed)
        #expect(await h.settle())
        #expect(h.photos.saved.count == 1)
    }

    @Test("Session vidéo perdue ou fermée : arrêt et sauvegarde")
    func videoEndedStops() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        h.model.video.stop()
        #expect(await h.settle())
        #expect(h.photos.saved.count == 1)
    }

    @Test("Arrière-plan (ou verrouillage) : arrêt et sauvegarde sous couvert d'une tâche de fond")
    func backgroundStops() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        h.model.deactivate()
        // La tâche de fond est demandée tout de suite, avant que l'app ne soit suspendue.
        #expect(h.background.begun == 1)
        #expect(await h.settle())
        #expect(h.photos.saved.count == 1)
        #expect(h.background.ended == [1])
        // Le retour au premier plan ne relance rien.
        h.model.activate()
        #expect(h.model.recording == .idle)
        #expect(h.recorder.finishCount == 1)
    }

    @Test("Inactif (Centre de contrôle, appel) : l'enregistrement continue")
    func inactiveKeepsRecording() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        h.model.pause()
        guard case .recording = h.model.recording else {
            Issue.record("inactif ne doit pas arrêter")
            return
        }
    }

    @Test("Espace disque : vérifié toutes les 10 s ; sous 200 Mo, arrêt, sauvegarde et deux avis")
    func lowSpaceStops() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        // Assez d'espace : ça continue, et la vérification se réarme.
        h.scheduler.advance(by: AppModel.spaceCheckInterval)
        h.scheduler.advance(by: AppModel.spaceCheckInterval)
        guard case .recording = h.model.recording else {
            Issue.record("assez d'espace : on continue")
            return
        }
        h.recorder.state.withLock { $0.holdFinish = true }
        h.knobs.freeSpace = AppModel.minimumFreeSpaceWhileRecording - 1
        h.scheduler.advance(by: AppModel.spaceCheckInterval)
        #expect(h.model.recording == .saving)
        #expect(h.model.bannerText == "Enregistrement arrêté : espace insuffisant.")
        h.recorder.releaseFinish()
        #expect(await h.settle())
        #expect(h.photos.saved.count == 1)
        #expect(h.model.bannerText == "Enregistrement arrêté : espace insuffisant. Vidéo enregistrée dans Photos (0:42)")
        // Plus de vérification une fois arrêté : le temps qui passe ne change rien.
        h.scheduler.advance(by: 3 * AppModel.spaceCheckInterval)
        #expect(h.recorder.finishCount == 1)
    }

    // MARK: Échecs

    @Test("Échec d'écriture du MP4, fichier illisible : arrêt, avis, fichier effacé")
    func writeFailureUnreadable() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        let url = try #require(h.recorder.url)
        h.recorder.state.withLock { $0.finishResult = .failure(RecordingError.writerFailed("disque")) }
        h.knobs.playable = false
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(h.model.bannerText == "L'enregistrement a échoué.")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(h.photos.saved.isEmpty)
        #expect(h.model.unsavedClip == nil)
    }

    @Test("Échec d'écriture en cours de route : l'enregistrement s'arrête tout seul, avec l'avis d'échec")
    func writeFailureMidwayStops() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        let url = try #require(h.recorder.url)
        h.recorder.state.withLock { $0.finishResult = .failure(RecordingError.writerFailed("disque")) }
        h.knobs.playable = false
        h.recorder.triggerFailure()
        #expect(await h.settle())
        #expect(h.recorder.finishCount == 1)
        #expect(!h.model.video.isRecording)
        #expect(h.model.bannerText == "L'enregistrement a échoué.")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(h.photos.saved.isEmpty)
        // Un échec tardif après l'arrêt ne fait rien de plus.
        h.recorder.triggerFailure()
        #expect(h.recorder.finishCount == 1)
    }

    @Test("Finalisation en échec mais fichier lisible : ajouté directement à Photos, avec le bandeau de réussite")
    func writeFailureReadableIsSalvaged() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        let url = try #require(h.recorder.url)
        h.recorder.state.withLock { $0.finishResult = .failure(RecordingError.writerFailed("disque")) }
        h.knobs.playable = true
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(h.photos.saved == [url])
        #expect(h.photos.state.withLock { $0.existedAtSave } == [true])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(h.model.unsavedClip == nil)
        #expect(!h.model.showsRetry)
        #expect(h.model.savedCount == 1)
        // Durée inconnue : pas de parenthèses, et aucun bandeau d'échec.
        #expect(h.model.bannerText == "Vidéo enregistrée dans Photos")
    }

    @Test("Erreur d'écriture en cours de route, fichier lisible : sauvé dans Photos, l'avis d'échec précède celui de réussite")
    func writeFailureMidwayReadableIsSalvaged() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        let url = try #require(h.recorder.url)
        h.recorder.state.withLock { $0.finishResult = .failure(RecordingError.writerFailed("disque")) }
        h.knobs.playable = true
        h.recorder.triggerFailure()
        #expect(await h.settle())
        #expect(h.photos.saved == [url])
        #expect(h.model.bannerText == "L'enregistrement a échoué. Vidéo enregistrée dans Photos")
    }

    @Test("Finalisation en échec, fichier lisible, mais Photos refuse : le fichier est gardé avec « Réessayer »")
    func writeFailureReadablePhotosFails() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        let url = try #require(h.recorder.url)
        h.recorder.state.withLock { $0.finishResult = .failure(RecordingError.writerFailed("disque")) }
        h.knobs.playable = true
        h.photos.state.withLock { $0.saveError = FakeFailure() }
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(h.model.unsavedClip == url)
        #expect(h.model.showsRetry)
        #expect(h.model.bannerText == "La vidéo n'a pas pu être ajoutée à Photos.")
        #expect(h.model.savedCount == 0)
    }

    @Test("Fermer le bandeau d'échec d'ajout : il disparaît, le fichier reste, l'état de connexion reprend sa place ; un nouvel échec le ramène")
    func dismissPhotosFailedBanner() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        let first = try #require(h.recorder.url)
        h.photos.state.withLock { $0.saveError = FakeFailure() }
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(h.model.bannerText == "La vidéo n'a pas pu être ajoutée à Photos.")
        h.model.dismissUnsavedClipBanner()
        #expect(h.model.bannerText != "La vidéo n'a pas pu être ajoutée à Photos.")
        #expect(!h.model.showsRetry)
        #expect(h.model.unsavedClip == first)
        #expect(FileManager.default.fileExists(atPath: first.path))
        // Un autre enregistrement dont l'ajout échoue aussi : le bandeau revient pour ce nouveau fichier.
        h.knobs.now = h.knobs.now.addingTimeInterval(60)
        await h.model.toggleRecording()
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(h.model.unsavedClip != first)
        #expect(h.model.bannerText == "La vidéo n'a pas pu être ajoutée à Photos.")
        #expect(h.model.showsRetry)
    }

    @Test("Échec de l'ajout à Photos : fichier gardé, avis et « Réessayer » ; le réessai réussit puis efface le fichier")
    func photosFailureThenRetry() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        let url = try #require(h.recorder.url)
        h.photos.state.withLock { $0.saveError = FakeFailure() }
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(h.model.unsavedClip == url)
        #expect(h.model.savedCount == 0)
        #expect(h.model.bannerText == "La vidéo n'a pas pu être ajoutée à Photos.")
        #expect(h.model.showsRetry)
        // L'avis tient tant qu'on ne réessaie pas.
        h.scheduler.advance(by: 60)
        #expect(h.model.bannerText == "La vidéo n'a pas pu être ajoutée à Photos.")
        // Un réessai qui échoue encore garde tout.
        await h.model.retrySave()
        #expect(h.model.unsavedClip == url)
        #expect(h.model.showsRetry)
        // Puis un réessai qui réussit.
        h.photos.state.withLock { $0.saveError = nil }
        await h.model.retrySave()
        #expect(h.model.unsavedClip == nil)
        #expect(!h.model.showsRetry)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(h.photos.saved == [url])
        #expect(h.model.savedCount == 1)
        #expect(h.model.bannerText == "Vidéo enregistrée dans Photos (0:42)")
    }

    @Test("« Réessayer » s'exécute sous une tâche de fond, rendue à la fin du réessai")
    func retryRunsInBackgroundTask() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        h.photos.state.withLock { $0.saveError = FakeFailure() }
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(h.background.begun == 1)
        #expect(h.background.ended == [1])
        h.photos.state.withLock { $0.saveError = nil }
        await h.model.retrySave()
        #expect(h.background.begun == 2)
        #expect(h.background.ended == [1, 2])
        #expect(h.model.unsavedClip == nil)
    }

    @Test("Une vidéo qui attend son réessai n'empêche pas d'en enregistrer une autre, et elle reste proposée")
    func recordingWhileUnsavedClipWaits() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        await h.model.toggleRecording()
        let first = try #require(h.recorder.url)
        h.photos.state.withLock { $0.saveError = FakeFailure() }
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(h.model.unsavedClip == first)
        h.knobs.now = h.knobs.now.addingTimeInterval(60)
        await h.model.toggleRecording()
        guard case .recording = h.model.recording else {
            Issue.record("on doit pouvoir enregistrer à nouveau")
            return
        }
        let second = try #require(h.recorder.url)
        #expect(second != first)
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test("Tâche de fond refusée ou expirée : le travail continue, le fichier reste si Photos n'a pas répondu")
    func backgroundExpiry() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        h.background.refuses = true
        await h.model.toggleRecording()
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(h.photos.saved.count == 1)
        #expect(h.background.ended.isEmpty)
        // Expiration en cours de travail : la tâche est rendue à iOS.
        h.background.refuses = false
        await h.model.toggleRecording()
        h.recorder.state.withLock { $0.holdFinish = true }
        await h.model.toggleRecording()
        h.background.expiry?()
        #expect(h.background.ended == [1])
        h.recorder.releaseFinish()
        #expect(await h.settle())
        // Rendue une seule fois.
        #expect(h.background.ended == [1])
    }

    // MARK: Fichiers restés

    @Test("Au lancement, les enregistrements de plus de 7 jours sont effacés, les récents gardés")
    func purgeAtLaunch() throws {
        var old: URL?
        var recent: URL?
        var other: URL?
        let h = try RecordingHarness { directory in
            let old_ = directory.appendingPathComponent("PTZBot-2020-01-01-000000.mp4")
            let recent_ = directory.appendingPathComponent("PTZBot-2027-01-14-000000.mp4")
            let other_ = directory.appendingPathComponent("autre.mp4")
            for url in [old_, recent_, other_] { try Data("x".utf8).write(to: url) }
            // L'âge se lit sur la date de modification : 8 jours, 1 jour, et un fichier qui n'est pas à nous.
            let now = Date()
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: old_.path)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: recent_.path)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: other_.path)
            old = old_; recent = recent_; other = other_
        }
        defer { h.cleanup() }
        #expect(!FileManager.default.fileExists(atPath: try #require(old).path))
        #expect(FileManager.default.fileExists(atPath: try #require(recent).path))
        #expect(FileManager.default.fileExists(atPath: try #require(other).path))
    }

    @Test("Retour au premier plan : une vidéo restée dans le dossier temporaire et lisible est proposée avec « Réessayer »")
    func leftoverProposed() async throws {
        var leftover: URL?
        let h = try RecordingHarness { directory in
            let url = directory.appendingPathComponent("PTZBot-2027-01-15-075900.mp4")
            try Data("x".utf8).write(to: url)
            leftover = url
        }
        defer { h.cleanup() }
        h.knobs.playable = true
        h.photos.state.withLock { $0.access = .granted }
        h.model.activate()
        let deadline = ContinuousClock.now + .seconds(5)
        while h.model.unsavedClip == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(h.model.unsavedClip == leftover)
        #expect(h.model.showsRetry)
        await h.model.retrySave()
        #expect(h.photos.saved == [leftover].compactMap { $0 })
        #expect(h.model.unsavedClip == nil)
    }

    @Test("Un fichier resté mais illisible (enregistrement interrompu en plein vol) n'est pas proposé, et il est effacé")
    func leftoverUnreadable() async throws {
        var leftover: URL?
        let h = try RecordingHarness { directory in
            let url = directory.appendingPathComponent("PTZBot-2027-01-15-075900.mp4")
            try Data("x".utf8).write(to: url)
            leftover = url
        }
        defer { h.cleanup() }
        h.knobs.playable = false
        h.model.activate()
        let deadline = ContinuousClock.now + .seconds(5)
        while FileManager.default.fileExists(atPath: try #require(leftover).path), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(h.model.unsavedClip == nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(leftover).path))
    }

    // MARK: Mode épuré

    @Test("Mode épuré : un tap le bascule ; il ne vaut que connecté, la vidéo jouant")
    func cleanFeed() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        h.model.toggleCleanFeed()
        // Pas encore connecté : l'interface reste visible (le bandeau d'état compte).
        #expect(!h.model.cleanFeed)
        let transport = try h.ready()
        #expect(h.model.cleanFeed)
        // Caméra débranchée, connexion intacte : l'interface revient avec « Caméra débranchée ».
        try h.send(privacy: false, camera: .absent, on: transport)
        #expect(!h.model.cleanFeed)
        try h.send(privacy: false, on: transport)
        #expect(h.model.cleanFeed)
        h.model.video.phase = .lost
        #expect(!h.model.cleanFeed)
        h.model.video.phase = .playing
        #expect(h.model.cleanFeed)
        h.model.toggleCleanFeed()
        #expect(!h.model.cleanFeed)
    }

    @Test("Mode épuré : seuls les bandeaux de l'enregistrement restent")
    func cleanFeedBanner() async throws {
        let h = try RecordingHarness()
        defer { h.cleanup() }
        _ = try h.ready()
        h.model.toggleCleanFeed()
        #expect(h.model.cleanFeedBannerText == nil)
        await h.model.toggleRecording()
        await h.model.toggleRecording()
        #expect(await h.settle())
        #expect(h.model.cleanFeedBannerText != nil)
        #expect(h.model.cleanFeedBannerText == h.model.bannerText)
    }
}
