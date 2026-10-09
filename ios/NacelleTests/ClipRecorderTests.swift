import AVFoundation
import CoreMedia
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import Nacelle

/// Heure de départ des essais : loin de zéro, comme une horloge d'hôte réelle (nanosecondes depuis le démarrage).
private let base = 1_000.0

private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: base + seconds, preferredTimescale: 1_000_000)
}

@Suite("Enregistreur de clip", .timeLimit(.minutes(1)))
struct ClipRecorderTests {
    private let fps = 30.0
    private let rate = 48_000

    /// Injecte `seconds` de vidéo à 30 ips. La luma passe de 30 à 220 à `brightAt`. `onFrame` laisse le
    /// test glisser d'autres appels (du son) entre les images. Chaque image est attendue (`flush`), sans
    /// quoi un essai plus rapide que le temps réel ferait sauter des images.
    private func feedVideo(
        _ recorder: ClipRecorder,
        seconds: Double,
        width: Int = 320,
        height: Int = 240,
        rotation: RTCVideoRotation = ._0,
        brightAt: Double = .infinity,
        i420: Bool = false,
        onFrame: (Int, Double) -> Void = { _, _ in }
    ) async {
        for index in 0..<Int(seconds * fps) {
            let at = Double(index) / fps
            let luma: UInt8 = at >= brightAt ? 220 : 30
            let frame = i420
                ? SyntheticMedia.i420Frame(width: width, height: height, luma: luma)
                : SyntheticMedia.nv12Frame(width: width, height: height, luma: luma, rotation: rotation)
            recorder.append(video: frame, at: time(at))
            onFrame(index, at)
            await recorder.flush()
            await pace()
        }
    }

    /// Un peu plus lent que le temps réel accéléré : l'entrée vidéo « temps réel » refuse des images si on
    /// la nourrit sans pause, ce qui est son rôle mais fausserait les mesures de ces essais.
    private func pace() async {
        try? await Task.sleep(for: .milliseconds(12))
    }

    /// Son de `from` à `to` secondes, en blocs d'au plus 10 ms, sans chevauchement ni trou d'un appel à
    /// l'autre ; le « clac » commence à `loudAt`. Les blocs dont l'heure tombe dans `hole` ne sont pas envoyés.
    private func feedAudio(_ recorder: ClipRecorder, from: Double, to: Double, loudAt: Double = .infinity, skipping hole: ClosedRange<Double>? = nil) {
        var position = Int((from * Double(rate)).rounded())
        let end = Int((to * Double(rate)).rounded())
        let loudFrom = loudAt.isFinite ? Int((loudAt * Double(rate)).rounded()) : Int.max
        while position < end {
            let count = min(rate / 100, end - position)
            let at = Double(position) / Double(rate)
            if hole?.contains(at) != true {
                recorder.append(audio: SyntheticMedia.tone(frames: count, firstFrame: position, loudFrom: loudFrom), at: time(at))
            }
            position += count
        }
    }

    private func recorder(in directory: URL, name: String = "clip.mp4") throws -> (ClipRecorder, URL) {
        let url = directory.appendingPathComponent(name)
        let recorder = ClipRecorder()
        try recorder.start(url: url)
        return (recorder, url)
    }

    @Test("Deux pistes, durée juste, son et image synchrones, son d'avant la première image ignoré")
    func tracksDurationAndSync() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (recorder, url) = try recorder(in: directory)
        // Du son arrive 0,4 s avant la première image : il doit être ignoré. Le « clac » et l'image
        // claire tombent tous deux à 1,0 s après la première image.
        feedAudio(recorder, from: -0.4, to: 0.0)
        await feedVideo(recorder, seconds: 2.0, brightAt: 1.0) { _, at in
            // Le son suit l'image : un bloc de 33 ms de plus à chaque image.
            let from = max(at, 0)
            feedAudio(recorder, from: from, to: from + 1 / fps, loudAt: 1.0)
        }
        let result = try await recorder.finish()
        #expect(result.url == url)
        #expect(abs(result.duration - 2.0) < 0.1)
        let movie = try await SyntheticMedia.inspect(url)
        #expect(movie.videoTrackCount == 1)
        #expect(movie.audioTrackCount == 1)
        #expect(abs(movie.duration - 2.0) < 0.1)
        let bright = try #require(movie.brightFrameTime)
        let loud = try #require(movie.loudSampleTime)
        #expect(abs(bright - 1.0) < 0.1)
        #expect(abs(loud - bright) < 0.05)
        // Pas de son avant la première image : la piste son commence avec la vidéo, à 50 ms près.
        #expect(abs(try #require(movie.audioStart)) < 0.05)
        #expect(abs(try #require(movie.audioEnd) - 2.0) < 0.1)
    }

    @Test("Fragments MP4 : le fichier se lit avant la fin de l'écriture, comme après une coupure ou un arrêt raté")
    func fragmentedFileIsReadableBeforeFinish() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (recorder, url) = try recorder(in: directory)
        // Le son accompagne l'image, comme en vrai : un fragment se ferme quand toutes les pistes ont avancé.
        await feedVideo(recorder, seconds: 3.0) { _, at in
            feedAudio(recorder, from: at, to: at + 1 / fps)
        }
        await recorder.flush()
        // L'écriture des fragments sur disque est asynchrone : on relit jusqu'à 5 s, jamais plus.
        var movie: SyntheticMedia.Movie?
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let read = try? await SyntheticMedia.inspect(url), read.duration >= 1.0 {
                movie = read
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let readable = try #require(movie, "le fichier devrait être lisible avant finish()")
        #expect(readable.videoTrackCount == 1)
        #expect(readable.duration >= 1.0)
        _ = try await recorder.finish()
    }

    @Test("Échec d'écriture : l'écouteur est prévenu une seule fois, les images suivantes sont ignorées")
    func failureCallbackFiresOnce() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Un dossier qui n'existe pas : le rédacteur refuse de démarrer à la première image.
        let url = directory.appendingPathComponent("absent", isDirectory: true).appendingPathComponent("clip.mp4")
        let recorder = ClipRecorder()
        let calls = Locked(0)
        recorder.onFailure = { calls.withLock { $0 += 1 } }
        try recorder.start(url: url)
        await feedVideo(recorder, seconds: 0.5)
        await recorder.flush()
        #expect(recorder.failure != nil)
        #expect(calls.withLock { $0 } == 1)
        await #expect(throws: (any Error).self) {
            try await recorder.finish()
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Rotation de l'image WebRTC : elle devient la transformation de la piste vidéo")
    func rotation() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expectations: [(RTCVideoRotation, CGAffineTransform)] = [
            (._0, .identity),
            (._90, CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)),
            (._180, CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 320, ty: 240)),
            (._270, CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 320)),
        ]
        for (index, (rotation, transform)) in expectations.enumerated() {
            let (recorder, url) = try recorder(in: directory, name: "rotation\(index).mp4")
            await feedVideo(recorder, seconds: 0.5, rotation: rotation)
            _ = try await recorder.finish()
            let movie = try await SyntheticMedia.inspect(url)
            #expect(movie.naturalSize == CGSize(width: 320, height: 240))
            #expect(movie.transform == transform, "rotation \(rotation.rawValue)")
        }
    }

    @Test("Images I420 : converties en NV12 et écrites")
    func i420() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (recorder, url) = try recorder(in: directory)
        await feedVideo(recorder, seconds: 1.0, brightAt: 0.5, i420: true)
        _ = try await recorder.finish()
        let movie = try await SyntheticMedia.inspect(url)
        #expect(movie.naturalSize == CGSize(width: 320, height: 240))
        #expect(movie.videoTimes.count >= 25)
        #expect(abs(try #require(movie.brightFrameTime) - 0.5) < 0.1)
    }

    @Test("Changement de résolution en cours d'enregistrement : même taille de fichier, aucune coupure")
    func resolutionChange() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (recorder, url) = try recorder(in: directory)
        // 1 s à 320 × 240, puis 1 s à 160 × 120 (même cadrage), puis 1 s à 640 × 480.
        for (second, size) in [(0.0, (320, 240)), (1.0, (160, 120)), (2.0, (640, 480))] {
            for index in 0..<30 {
                let frame = SyntheticMedia.nv12Frame(width: size.0, height: size.1)
                recorder.append(video: frame, at: time(second + Double(index) / fps))
                await recorder.flush()
                await pace()
            }
        }
        let result = try await recorder.finish()
        #expect(abs(result.duration - 3.0) < 0.1)
        let movie = try await SyntheticMedia.inspect(url)
        #expect(movie.naturalSize == CGSize(width: 320, height: 240))
        #expect(movie.videoTimes.count >= 80)
        #expect(movie.videoTimes.count == recorder.writtenVideoFrames)
        // Aucune coupure : jamais plus de trois images d'écart entre deux images écrites.
        let gaps = zip(movie.videoTimes, movie.videoTimes.dropFirst()).map { $1 - $0 }
        #expect((gaps.max() ?? 1) < 3 / fps)
        #expect(recorder.failure == nil)
    }

    @Test("Images en retard : sautées et comptées, l'ajout ne bloque jamais, le fichier reste lisible")
    func lateFramesAreSkipped() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (recorder, url) = try recorder(in: directory)
        // 600 images de 1280 × 720 d'un seul coup, bien plus vite que le temps réel : la file en saute.
        let sent = 600
        let frames = (0..<sent).map { _ in SyntheticMedia.nv12Frame(width: 1280, height: 720) }
        let started = DispatchTime.now()
        for (index, frame) in frames.enumerated() {
            recorder.append(video: frame, at: time(Double(index) / fps))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        // Aucune attente : même sur une machine chargée, 600 appels ne prennent pas plusieurs secondes.
        #expect(elapsed < 2.0)
        await recorder.flush()
        let result = try await recorder.finish()
        #expect(recorder.skippedVideoFrames > 0)
        #expect(recorder.writtenVideoFrames > 0)
        #expect(recorder.skippedVideoFrames + recorder.writtenVideoFrames == sent)
        let movie = try await SyntheticMedia.inspect(url)
        #expect(movie.videoTimes.count == recorder.writtenVideoFrames)
        #expect(result.duration > 0)
    }

    @Test("Un trou dans le son est comblé par du silence : le son garde la durée de la vidéo")
    func audioGapIsFilled() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (recorder, url) = try recorder(in: directory)
        await feedVideo(recorder, seconds: 2.0, brightAt: 1.5) { _, at in
            feedAudio(recorder, from: at, to: at + 1 / fps, loudAt: 1.5, skipping: 0.5...0.9)
        }
        _ = try await recorder.finish()
        let movie = try await SyntheticMedia.inspect(url)
        #expect(abs(try #require(movie.audioEnd) - 2.0) < 0.1)
        // Le clac est resté à sa place malgré le trou : le silence a pris la durée perdue.
        #expect(abs(try #require(movie.loudSampleTime) - 1.5) < 0.05)
    }

    /// Une image par seconde de `from` à `to` (secondes d'hôte), pour simuler de longs trous sans y passer
    /// des minutes : l'enregistreur ne regarde que les heures.
    private func feedSparseVideo(_ recorder: ClipRecorder, from: Int, to: Int) async {
        for second in from...to {
            recorder.append(video: SyntheticMedia.nv12Frame(), at: time(Double(second)))
            await recorder.flush()
            await pace()
        }
    }

    /// `length` secondes de son fort, en blocs de 10 ms datés à partir de `seconds`, comme le fait la minuterie
    /// de l'enregistreur. Les blocs que l'entrée refuse pendant un rattrapage sont perdus (le suivant recalcule le
    /// trou) : on laisse donc un instant à l'encodeur entre deux blocs.
    private func feedLoudSound(_ recorder: ClipRecorder, at seconds: Double, length: Double) async {
        let block = rate / 100
        for index in 0..<Int(length * 100) {
            let at = seconds + Double(index) / 100
            recorder.append(audio: SyntheticMedia.tone(frames: block, loudFrom: 0), at: time(at))
            await recorder.flush()
            try? await Task.sleep(for: .milliseconds(3))
        }
    }

    @Test("Trou de son de 20 s : comblé par du silence en morceaux d'au plus 1 s, la suite retombe à sa place")
    func longAudioGapIsFilledInChunks() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (recorder, url) = try recorder(in: directory)
        await feedSparseVideo(recorder, from: 0, to: 0)
        recorder.append(audio: SyntheticMedia.tone(frames: rate), at: time(0))
        await feedSparseVideo(recorder, from: 1, to: 20)
        // Le son revient à 21 s : 20 s de trou, après 1 s de son.
        await feedLoudSound(recorder, at: 21, length: 1.0)
        await feedSparseVideo(recorder, from: 21, to: 22)
        _ = try await recorder.finish()
        // L'ouverture, 20 morceaux de silence et la reprise : jamais un seul bloc géant.
        #expect(recorder.writtenAudioBlocks >= 21)
        let movie = try await SyntheticMedia.inspect(url)
        // Le son est continu depuis le début (pas de trou resserré) et le « clac » reprend à son heure.
        #expect(abs(try #require(movie.audioStart)) < 0.05)
        #expect(abs(try #require(movie.audioEnd) - 22.0) < 0.1)
        let loud = try #require(movie.loudSampleTime)
        #expect(loud >= 20.95 && loud < 21.6, "premier son fort à \(loud) s")
    }

    @Test("Trou de son de 40 s (un appel) : du silence par morceaux aussi, le son ne se décale pas par rapport à l'image")
    func veryLongAudioGapKeepsSync() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (recorder, url) = try recorder(in: directory)
        await feedSparseVideo(recorder, from: 0, to: 0)
        recorder.append(audio: SyntheticMedia.tone(frames: rate), at: time(0))
        await feedSparseVideo(recorder, from: 1, to: 40)
        await feedLoudSound(recorder, at: 41, length: 1.0)
        await feedSparseVideo(recorder, from: 41, to: 42)
        _ = try await recorder.finish()
        #expect(recorder.writtenAudioBlocks >= 41)
        #expect(recorder.failure == nil)
        let movie = try await SyntheticMedia.inspect(url)
        // Un trou laissé vide serait resserré par le MP4 : le son arriverait 40 s trop tôt. Ici il reste à sa place.
        #expect(abs(try #require(movie.audioEnd) - 42.0) < 0.1)
        let loud = try #require(movie.loudSampleTime)
        #expect(loud >= 40.95 && loud < 41.6, "premier son fort à \(loud) s")
    }

    @Test("Le son vient du tampon circulaire quand il est branché")
    func audioFromRing() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ring = AudioRingBuffer(capacity: rate * 2)
        let url = directory.appendingPathComponent("ring.mp4")
        let recorder = ClipRecorder()
        try recorder.start(url: url, audioSource: ring)
        // Du son arrive avant la première image (il reste dans le tampon, puis il est écarté) et après.
        func push(_ from: Double, _ to: Double) {
            var position = Int((from * Double(rate)).rounded())
            let end = Int((to * Double(rate)).rounded())
            while position < end {
                let count = min(480, end - position)
                let samples = SyntheticMedia.tone(frames: count, firstFrame: position, loudFrom: rate)
                samples.withUnsafeBufferPointer {
                    _ = ring.write($0.baseAddress!, count: count, time: UInt64((base + Double(position) / Double(rate)) * 1e9))
                }
                position += count
            }
        }
        push(-0.3, 0)
        await feedVideo(recorder, seconds: 2.0, brightAt: 1.0) { _, at in
            push(max(at, 0), at + 1 / fps)
        }
        // Laisse la minuterie de la file vider le tampon, sans attente sans borne.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, !ring.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ring.isEmpty)
        _ = try await recorder.finish()
        let movie = try await SyntheticMedia.inspect(url)
        #expect(movie.audioTrackCount == 1)
        #expect(abs(try #require(movie.loudSampleTime) - 1.0) < 0.1)
        #expect(abs(try #require(movie.audioEnd) - 2.0) < 0.15)
    }

    @Test("Aucune image reçue : l'arrêt échoue proprement et ne laisse aucun fichier")
    func noVideo() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (recorder, url) = try recorder(in: directory)
        feedAudio(recorder, from: 0, to: 1)
        await #expect(throws: RecordingError.noVideo) {
            try await recorder.finish()
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Annulation : plus de fichier")
    func cancel() async throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (recorder, url) = try recorder(in: directory)
        await feedVideo(recorder, seconds: 0.5)
        recorder.cancel()
        await recorder.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Un deuxième démarrage est refusé")
    func startTwice() throws {
        let directory = try SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (recorder, _) = try recorder(in: directory)
        #expect(throws: RecordingError.alreadyStarted) {
            try recorder.start(url: directory.appendingPathComponent("second.mp4"))
        }
        recorder.cancel()
    }

    @Test("Débit vidéo : proportionnel aux pixels, au moins 2 Mbit/s")
    func bitrate() {
        #expect(ClipRecorder.videoBitrate(width: 1920, height: 1080) == 6_000_000)
        #expect(ClipRecorder.videoBitrate(width: 1280, height: 720) > 2_600_000)
        #expect(ClipRecorder.videoBitrate(width: 1280, height: 720) < 2_700_000)
        #expect(ClipRecorder.videoBitrate(width: 320, height: 240) == 2_000_000)
    }
}
