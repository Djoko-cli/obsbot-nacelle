import AVFoundation
import CoreMedia
import CoreVideo
import Synchronization
import VideoToolbox
@preconcurrency import WebRTC

/// Ce que `finish()` rend : le fichier MP4 et sa durée.
struct RecordingResult: Equatable, Sendable {
    let url: URL
    let duration: TimeInterval
}

enum RecordingError: Error, Equatable {
    case alreadyStarted
    /// Aucune image n'est arrivée : il n'y a rien à ranger.
    case noVideo
    case writerFailed(String)
}

/// Ce que `AppModel` et `RecordingRenderer` demandent à l'enregistreur (simulé dans les tests).
protocol ClipRecording: AnyObject, Sendable {
    func start(url: URL, audioSource: AudioRingBuffer?) throws
    /// Appelé sur le fil de rendu de WebRTC : ne bloque jamais, saute l'image si l'enregistreur est en retard.
    func append(video frame: RTCVideoFrame, at time: CMTime)
    func finish() async throws -> RecordingResult
    /// Appelé une seule fois, depuis un autre fil, à la première erreur d'écriture : l'enregistreur ignore
    /// ensuite les images, c'est à l'appelant d'arrêter l'enregistrement.
    var onFailure: (@Sendable () -> Void)? { get set }
    /// Abandonne l'enregistrement et efface le fichier.
    func cancel()
}

/// Écrit un MP4 (H.264 et AAC) avec `AVAssetWriter` (spec enregistrement § 4.1). Vidéo et son sont horodatés
/// à leur arrivée sur l'horloge de l'hôte ; la session commence à la première image vidéo, le son reçu avant
/// est ignoré.
///
/// `@unchecked Sendable` : tout l'état modifiable est confiné à `queue` (file série privée). Les seuls
/// accès venant d'ailleurs sont des atomiques (compteurs, images en attente) et `failure` (sous `Mutex`).
final class ClipRecorder: ClipRecording, @unchecked Sendable {
    /// Images vidéo en attente dans la file au plus : au-delà, l'image est sautée plutôt que de retenir
    /// les tampons du décodeur ou de bloquer le fil de rendu.
    static let maxPendingFrames = 4
    /// Écart toléré entre l'heure d'un bloc de son et la fin du précédent ; au-delà, on comble par du
    /// silence (trou) ou on saute des échantillons (chevauchement), pour garder le son calé sur l'image.
    static let audioGapTolerance = 0.08
    /// Le silence qui comble un trou est écrit par morceaux d'au plus 1 s, jamais en un seul bloc : après un appel
    /// de 10 min, un bloc unique ferait 115 Mo d'un coup pour l'encodeur AAC. Le trou reste comblé en entier, même
    /// très long : un MP4 resserre une piste son laissée vide, et le son arriverait alors en avance sur l'image.
    static let silenceChunk = 1.0
    static let pumpInterval: DispatchTimeInterval = .milliseconds(20)
    /// Débit visé en 1080p, et plancher.
    static let referenceBitrate = 6_000_000
    static let minimumBitrate = 2_000_000
    static let audioBitrate = 128_000

    private enum Phase {
        case idle, waitingForFrame, writing, done
    }

    private struct PoolKey: Hashable {
        let width: Int
        let height: Int
    }

    private let queue = DispatchQueue(label: "ptzbot.clip-recorder", qos: .userInitiated)
    private let sampleRate: Int
    private let channels: Int

    private let pendingFrames = Atomic<Int>(0)
    private let skipped = Atomic<Int>(0)
    private let written = Atomic<Int>(0)
    private let writtenAudio = Atomic<Int>(0)
    private let lastFailure = Mutex<(any Error)?>(nil)
    private let failureListener = Mutex<(@Sendable () -> Void)?>(nil)

    // État de la file.
    private var phase = Phase.idle
    private var url: URL?
    private var audioSource: AudioRingBuffer?
    private var pump: (any DispatchSourceTimer)?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var targetWidth = 0
    private var targetHeight = 0
    private var sessionStart = CMTime.invalid
    private var lastVideoOffered = CMTime.invalid
    /// Écart entre les deux dernières images reçues : la dernière image écrite dure autant.
    private var frameInterval = 1.0 / 30
    private var audioAnchor = CMTime.invalid
    private var audioFrames: Int64 = 0
    private var videoFormat: CMVideoFormatDescription?
    private var transfer: VTPixelTransferSession?
    private var pools: [PoolKey: CVPixelBufferPool] = [:]
    private lazy var audioFormat: CMAudioFormatDescription? = makeAudioFormat()

    init(sampleRate: Int = Int(PlayoutAudioDevice.sampleRate), channels: Int = PlayoutAudioDevice.channels) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Images vidéo sautées (enregistreur en retard) et images écrites.
    var skippedVideoFrames: Int { skipped.load(ordering: .relaxed) }
    var writtenVideoFrames: Int { written.load(ordering: .relaxed) }
    /// Blocs de son écrits (son joué, ou silence de comblement).
    var writtenAudioBlocks: Int { writtenAudio.load(ordering: .relaxed) }
    /// La première erreur d'écriture, s'il y en a eu une.
    var failure: (any Error)? { lastFailure.withLock { $0 } }

    var onFailure: (@Sendable () -> Void)? {
        get { failureListener.withLock { $0 } }
        set { failureListener.withLock { $0 = newValue } }
    }

    /// Débit moyen H.264 : 6 Mbit/s pour du 1080p, proportionnel aux pixels, 2 Mbit/s au minimum.
    static func videoBitrate(width: Int, height: Int) -> Int {
        let scaled = Double(referenceBitrate) * Double(width * height) / Double(1920 * 1080)
        return max(minimumBitrate, Int(scaled))
    }

    /// Rotation de l'image WebRTC (à appliquer dans le sens horaire pour l'afficher droite) en
    /// transformation de la piste, avec la translation qui garde l'image dans le cadre.
    static func transform(for rotation: RTCVideoRotation, width: Int, height: Int) -> CGAffineTransform {
        let w = CGFloat(width)
        let h = CGFloat(height)
        switch rotation {
        case ._90: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case ._180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case ._270: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: return .identity
        }
    }

    // MARK: Interface

    /// Prépare l'enregistrement dans `url`. Le fichier n'est créé qu'à la première image (sa taille n'est
    /// connue qu'alors). `audioSource` : le tampon du périphérique audio, vidé par une minuterie de la file.
    func start(url: URL, audioSource: AudioRingBuffer? = nil) throws {
        try queue.sync {
            guard phase == .idle else { throw RecordingError.alreadyStarted }
            try? FileManager.default.removeItem(at: url)
            self.url = url
            self.audioSource = audioSource
            phase = .waitingForFrame
            if audioSource != nil {
                startPump()
            }
        }
    }

    func append(video frame: RTCVideoFrame, at time: CMTime) {
        // Trop d'images en attente : on saute celle-ci, sans attendre.
        guard pendingFrames.add(1, ordering: .relaxed).newValue <= Self.maxPendingFrames else {
            pendingFrames.subtract(1, ordering: .relaxed)
            skipped.add(1, ordering: .relaxed)
            return
        }
        queue.async {
            self.pendingFrames.subtract(1, ordering: .relaxed)
            self.writeVideo(frame, at: time)
        }
    }

    /// `samples` : PCM 16 bits entrelacé, `time` : heure d'arrivée du premier échantillon.
    func append(audio samples: [Int16], at time: CMTime) {
        queue.async {
            self.writeAudio(samples, at: time)
        }
    }

    func finish() async throws -> RecordingResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.finishOnQueue(continuation)
            }
        }
    }

    func cancel() {
        queue.async {
            guard self.phase != .done else { return }
            self.stopPump()
            self.writer?.cancelWriting()
            if let url = self.url {
                try? FileManager.default.removeItem(at: url)
            }
            self.release()
        }
    }

    /// Rend la main quand tout ce qui a été confié à la file avant l'appel est traité (tests).
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    // MARK: Démarrage du fichier

    private func beginWriting(for frame: RTCVideoFrame, at time: CMTime) -> Bool {
        guard let url else { return false }
        // H.264 en 4:2:0 veut des dimensions paires.
        targetWidth = Int(frame.width) & ~1
        targetHeight = Int(frame.height) & ~1
        guard targetWidth > 0, targetHeight > 0 else { return false }
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            // MP4 fragmenté : un fragment complet est écrit toutes les 2 s. Si la finalisation échoue (iOS peut
            // invalider l'encodeur en arrière-plan) ou si l'app meurt, le fichier reste lisible jusqu'au
            // dernier fragment, au lieu d'être sans `moov` et perdu en entier.
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: targetWidth,
                AVVideoHeightKey: targetHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.videoBitrate(width: targetWidth, height: targetHeight),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    // Pas d'images B : l'horodatage vient d'une horloge qui tremble, et l'ordre des
                    // images doit rester celui de l'arrivée.
                    AVVideoAllowFrameReorderingKey: false,
                ] as [String: Any],
            ])
            video.expectsMediaDataInRealTime = true
            // La rotation de la première image vaut pour tout le fichier.
            video.transform = Self.transform(for: frame.rotation, width: targetWidth, height: targetHeight)
            guard writer.canAdd(video) else { throw RecordingError.writerFailed("entrée vidéo refusée") }
            writer.add(video)
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: Self.audioBitrate,
            ], sourceFormatHint: audioFormat)
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(audio) else { throw RecordingError.writerFailed("entrée son refusée") }
            writer.add(audio)
            guard writer.startWriting() else {
                throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "démarrage refusé")
            }
            writer.startSession(atSourceTime: time)
            self.writer = writer
            videoInput = video
            audioInput = audio
            sessionStart = time
            phase = .writing
            return true
        } catch {
            fail(error)
            phase = .done
            return false
        }
    }

    // MARK: Vidéo (file)

    private func writeVideo(_ frame: RTCVideoFrame, at time: CMTime) {
        if phase == .waitingForFrame {
            guard beginWriting(for: frame, at: time) else { return }
        }
        guard phase == .writing, failure == nil else { return }
        // Horloge qui recule ou image en double : sautée.
        guard !lastVideoOffered.isValid || CMTimeCompare(time, lastVideoOffered) > 0 else {
            skipped.add(1, ordering: .relaxed)
            return
        }
        if lastVideoOffered.isValid {
            frameInterval = min(max((time - lastVideoOffered).seconds, 0.005), 0.25)
        }
        lastVideoOffered = time
        guard let input = videoInput, input.isReadyForMoreMediaData,
              let pixels = pixelBuffer(for: frame),
              let sample = makeSampleBuffer(pixels, at: time) else {
            skipped.add(1, ordering: .relaxed)
            return
        }
        if input.append(sample) {
            written.add(1, ordering: .relaxed)
        } else {
            fail(writer?.error ?? RecordingError.writerFailed("écriture vidéo refusée"))
        }
    }

    /// Un tampon NV12 de la taille du fichier : l'image elle-même, ou sa version convertie ou remise à l'échelle.
    private func pixelBuffer(for frame: RTCVideoFrame) -> CVPixelBuffer? {
        if let native = frame.buffer as? RTCCVPixelBuffer {
            if native.requiresCropping() {
                return cropAndScale(native)
            }
            return fitted(native.pixelBuffer)
        }
        // Image logicielle (I420) : conversion en NV12.
        guard let converted = nv12(from: frame.buffer.toI420()) else { return nil }
        return fitted(converted)
    }

    private func fitted(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(source) == targetWidth, CVPixelBufferGetHeight(source) == targetHeight {
            return source
        }
        guard let output = makeBuffer(width: targetWidth, height: targetHeight), let session = transferSession() else {
            return nil
        }
        return VTPixelTransferSessionTransferImage(session, from: source, to: output) == noErr ? output : nil
    }

    private func cropAndScale(_ native: RTCCVPixelBuffer) -> CVPixelBuffer? {
        guard let output = makeBuffer(width: targetWidth, height: targetHeight) else { return nil }
        let size = Int(native.bufferSizeForCroppingAndScaling(toWidth: Int32(targetWidth), height: Int32(targetHeight)))
        var scratch = [UInt8](repeating: 0, count: size)
        let done = scratch.withUnsafeMutableBufferPointer {
            native.cropAndScale(to: output, withTempBuffer: $0.baseAddress)
        }
        return done ? output : nil
    }

    private func nv12(from source: any RTCI420BufferProtocol) -> CVPixelBuffer? {
        let width = Int(source.width)
        let height = Int(source.height)
        guard let output = makeBuffer(width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(output, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(output, 1) else { return nil }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
        for row in 0..<height {
            memcpy(luma + row * lumaStride, source.dataY + row * Int(source.strideY), width)
        }
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
        for row in 0..<Int(source.chromaHeight) {
            let destination = (chroma + row * chromaStride).assumingMemoryBound(to: UInt8.self)
            let u = source.dataU + row * Int(source.strideU)
            let v = source.dataV + row * Int(source.strideV)
            for column in 0..<Int(source.chromaWidth) {
                destination[2 * column] = u[column]
                destination[2 * column + 1] = v[column]
            }
        }
        return output
    }

    private func transferSession() -> VTPixelTransferSession? {
        if transfer == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
            if let session {
                // Garde les proportions (bandes noires) si la nouvelle image n'a pas le même cadrage.
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            }
            transfer = session
        }
        return transfer
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let key = PoolKey(width: width, height: height)
        if pools[key] == nil {
            // Peu de tailles différentes en pratique : on repart de zéro si la liste enfle.
            if pools.count > 4 { pools.removeAll() }
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            pools[key] = pool
        }
        guard let pool = pools[key] else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private func makeSampleBuffer(_ pixels: CVPixelBuffer, at time: CMTime) -> CMSampleBuffer? {
        if let format = videoFormat, CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: pixels) {
            // Format déjà décrit.
        } else {
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
            videoFormat = format
        }
        guard let format = videoFormat else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample
        )
        return sample
    }

    // MARK: Son (file)

    private func makeAudioFormat() -> CMAudioFormatDescription? {
        let bytes = UInt32(2 * channels)
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytes,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytes,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        return format
    }

    private func startPump() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pumpInterval, repeating: Self.pumpInterval)
        timer.setEventHandler { [weak self] in
            self?.drainRing(limit: 200)
        }
        timer.resume()
        pump = timer
    }

    private func stopPump() {
        pump?.cancel()
        pump = nil
    }

    /// Reprend les blocs du tampon circulaire. Tant que le fichier n'est pas commencé, ils y restent : ceux
    /// d'avant la première image seront écartés à ce moment-là.
    private func drainRing(limit: Int) {
        guard phase == .writing, let ring = audioSource else { return }
        var count = 0
        while count < limit, let block = ring.pop() {
            writeAudio(block.samples, at: HostClock.time(nanoseconds: block.time))
            count += 1
        }
    }

    /// Écrit un bloc de son, en le gardant contigu : écarté avant la session, comblé par du silence s'il
    /// arrive après un trou, amputé s'il chevauche le précédent.
    private func writeAudio(_ samples: [Int16], at time: CMTime) {
        guard phase == .writing, failure == nil, channels > 0 else { return }
        var data = samples
        var start = time
        let rate = Double(sampleRate)
        let frames = data.count / channels
        guard frames > 0 else { return }
        // Avant la première image : écarté (ou amputé si le bloc la chevauche).
        let lead = (sessionStart - start).seconds
        if lead > 0 {
            let skippedFrames = Int((lead * rate).rounded(.up))
            guard skippedFrames < frames else { return }
            data.removeFirst(skippedFrames * channels)
            start = start + CMTime(value: CMTimeValue(skippedFrames), timescale: CMTimeScale(sampleRate))
        }
        if !audioAnchor.isValid {
            audioAnchor = start
            audioFrames = 0
        }
        let expected = audioAnchor + CMTime(value: audioFrames, timescale: CMTimeScale(sampleRate))
        let gap = (start - expected).seconds
        if gap > Self.audioGapTolerance {
            // Trou : du silence, par morceaux, pour que la suite retombe à sa place. Si l'entrée n'est pas prête,
            // on s'arrête là et ce bloc est perdu : le suivant recalculera le trou restant (rattrapage en
            // quelques tours de minuterie, l'encodeur écrivant du silence bien plus vite que le temps réel).
            var remaining = Int((gap * rate).rounded())
            let chunk = max(1, Int(Self.silenceChunk * rate))
            while remaining > 0 {
                let count = min(remaining, chunk)
                guard appendAudio([Int16](repeating: 0, count: count * channels)) else { return }
                remaining -= count
            }
        } else if gap < -Self.audioGapTolerance {
            // Chevauchement (le son a pris de l'avance sur l'horloge) : on saute ce qui est déjà couvert.
            let overlap = Int((-gap * rate).rounded())
            guard overlap * channels < data.count else { return }
            data.removeFirst(overlap * channels)
        }
        _ = appendAudio(data)
    }

    /// Un bloc de PCM tout de suite après le précédent. Faux si l'entrée n'est pas prête : le bloc est perdu
    /// et le suivant sera précédé de silence.
    private func appendAudio(_ data: [Int16]) -> Bool {
        guard let input = audioInput, input.isReadyForMoreMediaData, let format = audioFormat else { return false }
        let frames = data.count / channels
        let bytes = data.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return false }
        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == noErr else { return false }
        let presentation = audioAnchor + CMTime(value: audioFrames, timescale: CMTimeScale(sampleRate))
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: presentation, packetDescriptions: nil, sampleBufferOut: &sample
        ) == noErr, let sample else { return false }
        guard input.append(sample) else {
            fail(writer?.error ?? RecordingError.writerFailed("écriture du son refusée"))
            return false
        }
        audioFrames += Int64(frames)
        writtenAudio.add(1, ordering: .relaxed)
        return true
    }

    // MARK: Fin

    private func finishOnQueue(_ continuation: CheckedContinuation<RecordingResult, any Error>) {
        stopPump()
        drainRing(limit: .max)
        guard let url, let writer, phase == .writing else {
            let wasWaiting = phase == .waitingForFrame
            let error = failure ?? (wasWaiting ? RecordingError.noVideo : RecordingError.writerFailed("aucun enregistrement en cours"))
            release()
            continuation.resume(throwing: error)
            return
        }
        if let error = failure {
            release()
            continuation.resume(throwing: error)
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        // La fin couvre la dernière image reçue (écrite ou sautée) avec sa durée, et le son écrit : une
        // image dont l'heure serait celle de la fin serait coupée.
        var end = lastVideoOffered + CMTime(seconds: frameInterval, preferredTimescale: 1_000_000)
        if audioAnchor.isValid {
            end = CMTimeMaximum(end, audioAnchor + CMTime(value: audioFrames, timescale: CMTimeScale(sampleRate)))
        }
        writer.endSession(atSourceTime: end)
        let duration = (end - sessionStart).seconds
        phase = .done
        // Le rappel de `finishWriting` arrive sur un autre fil ; le rédacteur n'est plus touché ailleurs.
        nonisolated(unsafe) let finishing = writer
        finishing.finishWriting { [self] in
            if finishing.status == .completed {
                continuation.resume(returning: RecordingResult(url: url, duration: duration))
            } else {
                continuation.resume(throwing: RecordingError.writerFailed(finishing.error?.localizedDescription ?? "inconnue"))
            }
            queue.async { self.release() }
        }
    }

    /// Retient la première erreur et la signale une seule fois (hors verrou : l'écouteur peut rappeler l'enregistreur).
    private func fail(_ error: any Error) {
        let isFirst = lastFailure.withLock { stored -> Bool in
            guard stored == nil else { return false }
            stored = error
            return true
        }
        if isFirst {
            onFailure?()
        }
    }

    /// Libère le matériel d'écriture ; l'enregistreur ne sert qu'une fois.
    private func release() {
        stopPump()
        phase = .done
        writer = nil
        videoInput = nil
        audioInput = nil
        audioSource = nil
        if let transfer {
            VTPixelTransferSessionInvalidate(transfer)
        }
        transfer = nil
        pools.removeAll()
        videoFormat = nil
    }
}
