import CoreMedia
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import Nacelle

@MainActor
@Suite("Session vidéo : prises pour l'enregistrement", .timeLimit(.minutes(1)))
struct VideoSessionRecordingTests {
    let scheduler = FakeScheduler()

    /// Une session avec son propre périphérique audio : les essais s'entrelacent à chaque attente, et le
    /// périphérique statique de l'app serait partagé entre eux.
    private func makeSession(device: PlayoutAudioDevice = PlayoutAudioDevice()) -> VideoSession {
        VideoSession(scheduler: scheduler, audioDevice: device)
    }

    /// Attend une condition au plus `timeout` ; jamais d'attente sans fin.
    private func wait(timeout: Duration = .seconds(5), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @Test("Première image reçue : signalée une fois, remise à zéro quand la connexion se ferme")
    func firstFrame() async {
        let session = makeSession()
        #expect(!session.hasFrame)
        session.probe.renderFrame(SyntheticMedia.nv12Frame())
        #expect(await wait { session.hasFrame })
        session.stop()
        #expect(!session.hasFrame)
        // Une nouvelle connexion signale de nouveau sa première image.
        session.probe.renderFrame(SyntheticMedia.nv12Frame())
        #expect(await wait { session.hasFrame })
        session.stop()
    }

    @Test("Le rendu d'enregistrement transmet chaque image à l'enregistreur")
    func recordingRendererForwards() {
        let recorder = FakeClipRecorder()
        let renderer = RecordingRenderer(recorder: recorder)
        renderer.renderFrame(SyntheticMedia.nv12Frame())
        renderer.renderFrame(SyntheticMedia.nv12Frame())
        renderer.renderFrame(nil)
        #expect(recorder.frames == 2)
    }

    @Test("Son : la piste reste active pendant l'enregistrement, le haut-parleur suit le bouton son, et tout revient à la fin")
    func audioState() {
        let device = PlayoutAudioDevice()
        let session = makeSession(device: device)
        #expect(!session.audioTrackEnabled)
        #expect(device.isSpeakerMuted)
        let recorder = FakeClipRecorder()
        session.beginRecording(with: recorder)
        #expect(session.isRecording)
        #expect(device.isCapturing)
        // Son coupé dans l'app : la piste vit (pour le fichier), le haut-parleur est muet.
        #expect(session.audioTrackEnabled)
        #expect(device.isSpeakerMuted)
        session.setPlaysAudio(true)
        #expect(!device.isSpeakerMuted)
        session.setPlaysAudio(false)
        #expect(device.isSpeakerMuted)
        session.endRecording()
        #expect(!session.isRecording)
        #expect(!device.isCapturing)
        #expect(!session.audioTrackEnabled)
        #expect(device.isSpeakerMuted)
        // Son voulu : la piste suit le bouton, avec ou sans enregistrement.
        session.setPlaysAudio(true)
        #expect(session.audioTrackEnabled)
        session.beginRecording(with: recorder)
        session.endRecording()
        #expect(session.audioTrackEnabled)
        #expect(!device.isSpeakerMuted)
        session.setPlaysAudio(false)
    }

    @Test("Chaque session garde son périphérique audio : l'une n'agit pas sur celui de l'autre")
    func devicesAreIndependent() {
        let deviceA = PlayoutAudioDevice()
        let deviceB = PlayoutAudioDevice()
        let a = makeSession(device: deviceA)
        let b = makeSession(device: deviceB)
        #expect(a.audioRing === deviceA.recordingRing)
        #expect(b.audioRing === deviceB.recordingRing)
        a.setPlaysAudio(true)
        a.beginRecording(with: FakeClipRecorder())
        #expect(deviceA.isCapturing)
        #expect(!deviceA.isSpeakerMuted)
        #expect(!deviceB.isCapturing)
        #expect(deviceB.isSpeakerMuted)
        a.endRecording()
        a.setPlaysAudio(false)
    }

    @Test("Début d'enregistrement : le tampon audio est vidé d'abord")
    func ringIsClearedAtStart() {
        let session = makeSession()
        let samples = [Int16](repeating: 1, count: 100)
        samples.withUnsafeBufferPointer { _ = session.audioRing.write($0.baseAddress!, count: 100, time: 1) }
        session.beginRecording(with: FakeClipRecorder())
        #expect(session.audioRing.pop() == nil)
        session.endRecording()
    }

    @Test("Fin de la session vidéo : l'écouteur est prévenu, une fois par arrêt")
    func endedCallback() {
        let session = makeSession()
        var ended = 0
        session.onEnded = { ended += 1 }
        session.stop()
        #expect(ended == 1)
        session.stop()
        #expect(ended == 2)
    }
}
