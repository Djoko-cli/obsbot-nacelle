import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import WebRTC

/// Images et sons de synthèse, et relecture des fichiers produits. Tout vit dans un dossier temporaire
/// effacé à la fin du test : jamais d'image de la caméra, jamais de fichier dans le dépôt.
enum SyntheticMedia {
    /// Un dossier neuf dans le dossier temporaire.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nacelle-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Un tampon NV12 uni : `luma` partout, chrominance neutre.
    static func pixelBuffer(width: Int, height: Int, luma: UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!
            let rows = CVPixelBufferGetHeightOfPlane(pixels, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
            memset(base, plane == 0 ? Int32(luma) : 128, rows * stride)
        }
        return pixels
    }

    static func nv12Frame(width: Int = 320, height: Int = 240, luma: UInt8 = 100, rotation: RTCVideoRotation = ._0) -> RTCVideoFrame {
        RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer(width: width, height: height, luma: luma)),
            rotation: rotation,
            timeStampNs: 0
        )
    }

    static func i420Frame(width: Int = 320, height: Int = 240, luma: UInt8 = 100) -> RTCVideoFrame {
        let buffer = RTCMutableI420Buffer(width: Int32(width), height: Int32(height))
        memset(buffer.mutableDataY, Int32(luma), Int(buffer.strideY) * height)
        memset(buffer.mutableDataU, 128, Int(buffer.strideU) * Int(buffer.chromaHeight))
        memset(buffer.mutableDataV, 128, Int(buffer.strideV) * Int(buffer.chromaHeight))
        return RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 0)
    }

    /// `frames` échantillons mono : zéros, sauf une onde carrée forte pour les images dont le rang est
    /// au moins `loudFrom` (le « clac » qui sert à mesurer le décalage avec l'image).
    static func tone(frames: Int, firstFrame: Int = 0, loudFrom: Int = .max) -> [Int16] {
        (0..<frames).map { index in
            let position = firstFrame + index
            guard position >= loudFrom else { return 0 }
            return (position / 24) % 2 == 0 ? 12_000 : -12_000
        }
    }

    // MARK: Relecture

    struct Movie {
        var videoTrackCount = 0
        var audioTrackCount = 0
        var duration = 0.0
        var naturalSize = CGSize.zero
        var transform = CGAffineTransform.identity
        /// Heure de chaque image vidéo, dans la ligne de temps du fichier.
        var videoTimes: [Double] = []
        /// Heure de la première image claire (luma > 128).
        var brightFrameTime: Double?
        /// Heure du premier échantillon fort (> 3000) du son décodé.
        var loudSampleTime: Double?
        var audioStart: Double?
        var audioEnd: Double?
        var audioSamples: [(time: Double, value: Int16)] = []
    }

    static func inspect(_ url: URL) async throws -> Movie {
        let asset = AVURLAsset(url: url)
        var movie = Movie()
        movie.duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        movie.videoTrackCount = videoTracks.count
        movie.audioTrackCount = audioTracks.count
        if let video = videoTracks.first {
            movie.naturalSize = try await video.load(.naturalSize)
            movie.transform = try await video.load(.preferredTransform)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            reader.add(output)
            reader.startReading()
            while let sample = output.copyNextSampleBuffer() {
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                movie.videoTimes.append(time)
                if movie.brightFrameTime == nil, let pixels = CMSampleBufferGetImageBuffer(sample), centerLuma(pixels) > 128 {
                    movie.brightFrameTime = time
                }
            }
        }
        if let audio = audioTracks.first {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 48_000,
            ])
            reader.add(output)
            reader.startReading()
            while let sample = output.copyNextSampleBuffer() {
                let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                let count = length / 2
                pointer?.withMemoryRebound(to: Int16.self, capacity: count) { samples in
                    for index in 0..<count {
                        movie.audioSamples.append((start + Double(index) / 48_000, samples[index]))
                    }
                }
            }
            movie.audioStart = movie.audioSamples.first?.time
            movie.audioEnd = movie.audioSamples.last.map { $0.time + 1.0 / 48_000 }
            movie.loudSampleTime = movie.audioSamples.first { abs(Int($0.value)) > 3_000 }?.time
        }
        return movie
    }

    private static func centerLuma(_ pixels: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let row = CVPixelBufferGetHeight(pixels) / 2
        let column = CVPixelBufferGetWidth(pixels) / 2
        return Int(base[row * stride + column * 4 + 1])
    }
}
