import Foundation
import Observation
@preconcurrency import WebRTC

/// Vidéo et son en direct de go2rtc, en WebRTC, réception seule (spec § 7.2). L'offre est négociée
/// par `signal`, qui la relaie à go2rtc (spec accès local § 8.4). Le son est toujours reçu ; `playsAudio`
/// décide seulement s'il est joué, pour qu'activer le son soit immédiat. Coupé, il reste décodé et
/// sorti à volume nul : un peu de batterie, sans gêne pour les autres apps (`.mixWithOthers`).
///
/// Enregistrement (spec enregistrement § 4.2) : pendant qu'on enregistre, la piste audio reste active même si
/// le son est coupé dans l'app ; c'est le périphérique audio qui envoie alors du silence au haut-parleur
/// (`setSpeakerMuted`) tout en copiant le vrai son pour le fichier.
@MainActor
@Observable
final class VideoSession {
    /// Envoie l'offre SDP, renvoie la réponse SDP.
    typealias Signal = @MainActor (_ offer: String) async throws -> String

    enum Phase: Equatable {
        case idle
        case connecting
        case playing
        case lost
    }

    static let gatheringTimeout: TimeInterval = 2
    static let retryDelays: [TimeInterval] = [1, 2, 4, 8]

    /// Modifiable de l'extérieur pour les tests seulement, qui n'ouvrent pas de vraie connexion WebRTC.
    var phase: Phase = .idle
    /// Le son reçu est joué ; sinon, il est reçu mais muet.
    private(set) var playsAudio = false
    /// Une image vidéo au moins est arrivée sur la connexion courante.
    private(set) var hasFrame = false
    /// Un enregistrement est en cours : la piste audio reste active, quoi qu'en dise `playsAudio`.
    private(set) var isRecording = false
    /// Appelé quand la session vidéo s'arrête ou se perd (l'enregistrement en cours doit alors se terminer).
    @ObservationIgnored var onEnded: (@MainActor () -> Void)?

    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private var signal: Signal?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var peer: RTCPeerConnection?
    @ObservationIgnored private var observer: PeerObserver?
    @ObservationIgnored private var track: RTCVideoTrack?
    @ObservationIgnored private var audioTrack: RTCAudioTrack?
    @ObservationIgnored private var renderer: RTCMTLVideoView?
    @ObservationIgnored private var recordingRenderer: RecordingRenderer?
    /// Signale la première image de chaque connexion.
    @ObservationIgnored private(set) lazy var probe = FrameProbe { [weak self] in
        Task { @MainActor in self?.frameReceived() }
    }
    @ObservationIgnored private var retry: (any Cancellable)?
    @ObservationIgnored private var gathering: CheckedContinuation<Void, Never>?

    /// Le périphérique audio, unique : il copie aussi le son pour l'enregistrement.
    static let audioDevice = PlayoutAudioDevice()

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        // Périphérique audio en sortie seule : WebRTC ne demande jamais le micro de l'iPhone.
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory(),
            audioDevice: audioDevice
        )
    }()

    /// Le périphérique audio de cette session.
    @ObservationIgnored private let audioDevice: PlayoutAudioDevice

    /// `audioDevice` : celui de l'app par défaut. Les tests en passent un neuf, pour ne pas partager l'état
    /// du périphérique statique (muet, capture) entre des essais qui tournent en parallèle ; WebRTC, lui,
    /// reste branché sur le périphérique statique, et aucun essai ne crée de connexion.
    init(scheduler: any Scheduler, audioDevice: PlayoutAudioDevice = VideoSession.audioDevice) {
        self.scheduler = scheduler
        self.audioDevice = audioDevice
        applyAudioState()
    }

    /// Le tampon où le périphérique audio copie le son joué.
    var audioRing: AudioRingBuffer {
        audioDevice.recordingRing
    }

    /// État voulu de la piste audio : active si le son est joué, ou si on enregistre.
    var audioTrackEnabled: Bool {
        playsAudio || isRecording
    }

    /// Une image vient d'arriver (appelé par `probe`, et par les tests).
    func frameReceived() {
        hasFrame = true
    }

    /// Début d'un enregistrement : le tampon audio est vidé, les images sont transmises à `recorder`, la piste
    /// audio reste active et le haut-parleur ne joue que si le son est voulu.
    func beginRecording(with recorder: any ClipRecording) {
        endRecording()
        isRecording = true
        audioDevice.beginCapture()
        let renderer = RecordingRenderer(recorder: recorder)
        recordingRenderer = renderer
        track?.add(renderer)
        applyAudioState()
    }

    /// Fin de l'enregistrement : la piste audio retrouve l'état du bouton son. Sans effet hors enregistrement.
    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        audioDevice.endCapture()
        if let recordingRenderer {
            track?.remove(recordingRenderer)
        }
        recordingRenderer = nil
        applyAudioState()
    }

    /// La piste audio suit `audioTrackEnabled` ; le haut-parleur, lui, ne suit que le son voulu.
    private func applyAudioState() {
        audioTrack?.isEnabled = audioTrackEnabled
        audioDevice.setSpeakerMuted(!playsAudio)
    }

    /// La vue qui affiche l'image, fournie par VideoView.
    func attach(renderer: RTCMTLVideoView) {
        self.renderer = renderer
        track?.add(renderer)
    }

    /// Joue ou coupe le son reçu, tout de suite et pour les connexions suivantes.
    func setPlaysAudio(_ on: Bool) {
        playsAudio = on
        applyAudioState()
    }

    func start(signal: @escaping Signal) {
        self.signal = signal
        attempt = 0
        connect()
    }

    /// Passage en arrière-plan : fermeture de la connexion vidéo.
    func stop() {
        signal = nil
        retry?.cancel()
        retry = nil
        teardown()
        phase = .idle
        onEnded?()
    }

    private func connect() {
        guard let signal else { return }
        retry?.cancel()
        retry = nil
        teardown()
        generation += 1
        let current = generation
        phase = .connecting
        Task {
            await negotiate(signal: signal, generation: current)
        }
    }

    private func negotiate(signal: Signal, generation current: Int) async {
        do {
            let peer = try makePeer(generation: current)
            let offer = try await peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            try await peer.setLocalDescription(offer)
            await waitForGathering(generation: current)
            guard current == generation else { return }
            // Sans offre locale, échec : nouvel essai, au lieu de rester à `connecting`.
            guard let sdp = peer.localDescription?.sdp else { throw MissingLocalDescription() }
            let answer = try await signal(sdp)
            guard current == generation else { return }
            try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer))
        } catch {
            if current == generation {
                lost()
            }
        }
    }

    private func makePeer(generation current: Int) throws -> RTCPeerConnection {
        let configuration = RTCConfiguration()
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        let observer = PeerObserver { [weak self] event in
            Task { @MainActor in
                self?.handle(event, generation: current)
            }
        }
        guard let peer = Self.factory.peerConnection(
            with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: observer
        ) else {
            throw PeerConnectionUnavailable()
        }
        let receiveOnly = RTCRtpTransceiverInit()
        receiveOnly.direction = .recvOnly
        let transceiver = peer.addTransceiver(of: .video, init: receiveOnly)
        if let track = transceiver?.receiver.track as? RTCVideoTrack {
            self.track = track
            if let renderer {
                track.add(renderer)
            }
            track.add(probe)
            if let recordingRenderer {
                track.add(recordingRenderer)
            }
        }
        let audio = peer.addTransceiver(of: .audio, init: receiveOnly)
        if let track = audio?.receiver.track as? RTCAudioTrack {
            audioTrack = track
            applyAudioState()
        }
        self.peer = peer
        self.observer = observer
        return peer
    }

    /// Attend la fin de la collecte des candidats ICE, 2 s au plus.
    private func waitForGathering(generation current: Int) async {
        // Une négociation périmée n'attend pas : elle écraserait la continuation de la génération courante.
        guard current == generation else { return }
        if peer?.iceGatheringState == .complete { return }
        await withCheckedContinuation { continuation in
            gathering = continuation
            scheduler.schedule(after: Self.gatheringTimeout) { [weak self] in
                guard let self, current == self.generation else { return }
                self.resumeGathering()
            }
        }
    }

    private func resumeGathering() {
        gathering?.resume()
        gathering = nil
    }

    private func handle(_ event: PeerObserver.Event, generation current: Int) {
        guard current == generation else { return }
        switch event {
        case .gatheringComplete:
            resumeGathering()
        case .connected:
            attempt = 0
            phase = .playing
        case .disconnected:
            lost()
        }
    }

    private func lost() {
        teardown()
        phase = .lost
        onEnded?()
        guard signal != nil else { return }
        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
        attempt += 1
        retry = scheduler.schedule(after: delay) { [weak self] in
            self?.retry = nil
            self?.connect()
        }
    }

    private func teardown() {
        generation += 1
        resumeGathering()
        if let renderer {
            track?.remove(renderer)
        }
        track?.remove(probe)
        if let recordingRenderer {
            track?.remove(recordingRenderer)
        }
        probe.reset()
        hasFrame = false
        track = nil
        audioTrack = nil
        peer?.close()
        peer = nil
        observer = nil
    }
}

/// L'offre locale manque après `setLocalDescription`.
private struct MissingLocalDescription: Error {}

/// WebRTC n'a pas créé la connexion.
private struct PeerConnectionUnavailable: Error {}

/// Rappels de WebRTC (sur son propre fil), traduits en événements simples.
private final class PeerObserver: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case gatheringComplete
        case connected
        case disconnected
    }

    private let onEvent: @Sendable (Event) -> Void

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected, .completed:
            onEvent(.connected)
        case .failed, .disconnected, .closed:
            onEvent(.disconnected)
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            onEvent(.gatheringComplete)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
