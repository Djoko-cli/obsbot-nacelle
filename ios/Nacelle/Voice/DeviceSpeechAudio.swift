import Foundation
import NacelleProtocol

/// Cadence les `VoiceCapture.pump()` sur une file à part, hors du fil principal et du fil audio. La minuterie est
/// créée ici, dans un type qui n'est isolé à aucun acteur : écrite dans une méthode d'un type `@MainActor`, la
/// closure de la minuterie hériterait de l'isolation du fil principal, et le compilateur y insérerait un contrôle
/// d'exécuteur qui plante (SIGTRAP) au premier appel hors de ce fil.
final class VoicePump: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.djoko-cli.nacelle.voice-pump", qos: .userInteractive)
    private var timer: (any DispatchSourceTimer)?

    func start(interval: TimeInterval, capture: VoiceCapture, deliver: @escaping @Sendable (_ packets: [Data], _ level: Float) -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler {
            let result = capture.pump()
            deliver(result.packets, result.level)
        }
        timer.resume()
        self.timer = timer
    }

    var isRunning: Bool {
        timer != nil
    }

    /// Arrête la minuterie et attend la fin du pompage en cours : après le retour, plus rien ne se livre.
    func stop() {
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        queue.sync {}
    }
}

/// Le côté audio réel de la parole : bascule le périphérique de WebRTC en mode parole, lui donne un `MicTap`, et
/// livre sur le fil principal les paquets que la pompe tire du micro.
@MainActor
final class DeviceSpeechAudio: SpeechAudio {
    var onPackets: (@MainActor (_ packets: [Data], _ level: Float) -> Void)?
    var onInterrupted: (@MainActor () -> Void)?

    private let device: PlayoutAudioDevice
    private let pump = VoicePump()
    private let pumpInterval: TimeInterval
    /// La capture de la prise de parole en cours ; nil hors parole.
    private(set) var capture: VoiceCapture?

    /// `pumpInterval` : 20 ms, soit un paquet par tour.
    init(device: PlayoutAudioDevice, pumpInterval: TimeInterval = TimeInterval(VoiceFrame.durationMilliseconds) / 1000) {
        self.device = device
        self.pumpInterval = pumpInterval
    }

    /// La pompe tourne (essais).
    var isPumpRunning: Bool {
        pump.isRunning
    }

    func begin() async -> Bool {
        guard capture == nil, let capture = VoiceCapture(sourceRate: PlayoutAudioDevice.sampleRate) else { return false }
        self.capture = capture
        let tap = MicTap(ring: capture.ring)
        device.onSpeakingInterrupted = Self.interruptionHandler(self)
        let started = await withCheckedContinuation { continuation in
            device.beginSpeaking(tap: tap) { continuation.resume(returning: $0) }
        }
        guard started else {
            device.onSpeakingInterrupted = nil
            self.capture = nil
            return false
        }
        // Une interruption est passée pendant l'attente : la parole est déjà finie côté appelant. Le périphérique, lui,
        // a pu démarrer : on le ramène à la lecture, et la pompe ne démarre pas (elle tournerait pour rien).
        guard self.capture === capture else {
            device.endSpeaking()
            return false
        }
        pump.start(interval: pumpInterval, capture: capture, deliver: Self.deliveryHandler(self))
        return true
    }

    func end() {
        guard capture != nil else { return }
        pump.stop()
        device.onSpeakingInterrupted = nil
        device.endSpeaking()
        capture = nil
    }

    private func deliver(_ packets: [Data], _ level: Float) {
        // Une livraison postée avant l'arrêt arrive après : elle est ignorée.
        guard capture != nil else { return }
        onPackets?(packets, level)
    }

    private func interrupted() {
        guard capture != nil else { return }
        pump.stop()
        device.onSpeakingInterrupted = nil
        capture = nil
        onInterrupted?()
    }

    // Les rappels vers le fil principal sont fabriqués ici, hors de tout contexte isolé : voir `VoicePump`.

    nonisolated private static func deliveryHandler(_ target: DeviceSpeechAudio) -> @Sendable ([Data], Float) -> Void {
        { [weak target] packets, level in
            Task { @MainActor in target?.deliver(packets, level) }
        }
    }

    nonisolated private static func interruptionHandler(_ target: DeviceSpeechAudio) -> @Sendable () -> Void {
        { [weak target] in
            Task { @MainActor in target?.interrupted() }
        }
    }
}

extension SpeechServices {
    /// Le micro et la session réels : le périphérique audio unique de l'app.
    @MainActor
    static func live() -> SpeechServices {
        SpeechServices(audio: DeviceSpeechAudio(device: VideoSession.audioDevice), permission: SystemMicrophonePermission())
    }
}
