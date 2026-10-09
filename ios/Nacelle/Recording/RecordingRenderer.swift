import CoreMedia
import Synchronization
@preconcurrency import WebRTC

/// Branché sur la piste vidéo à côté de la vue, seulement pendant un enregistrement : passe chaque image
/// de WebRTC au `ClipRecorder`, horodatée à son arrivée (spec enregistrement § 4.2). Appelé sur le fil de
/// rendu de WebRTC : il ne fait que transmettre, l'enregistreur ne bloque jamais.
final class RecordingRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let recorder: any ClipRecording

    init(recorder: any ClipRecording) {
        self.recorder = recorder
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        recorder.append(video: frame, at: HostClock.time(nanoseconds: HostClock.nowNanoseconds()))
    }
}

/// Toujours branché sur la piste vidéo : dit à l'app que des images arrivent (le bouton rec reste grisé
/// tant qu'il n'en est venu aucune). Ne signale que la première image de chaque connexion.
final class FrameProbe: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let seen = Atomic<Bool>(false)
    private let onFirstFrame: @Sendable () -> Void

    init(onFirstFrame: @escaping @Sendable () -> Void) {
        self.onFirstFrame = onFirstFrame
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil, !seen.exchange(true, ordering: .relaxed) else { return }
        onFirstFrame()
    }

    /// Nouvelle connexion : la prochaine image sera de nouveau la première.
    func reset() {
        seen.store(false, ordering: .relaxed)
    }
}
