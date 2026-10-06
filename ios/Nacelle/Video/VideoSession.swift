import Foundation
import Observation
@preconcurrency import WebRTC

/// Vidéo et son en direct de go2rtc, en WebRTC, réception seule (spec § 7.2). L'offre est négociée
/// par `signal`, qui la relaie à go2rtc (spec accès local § 8.4). Le son est toujours reçu ; `playsAudio`
/// décide seulement s'il est joué, pour qu'activer le son soit immédiat. Coupé, il reste décodé et
/// sorti à volume nul : un peu de batterie, sans gêne pour les autres apps (`.mixWithOthers`).
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

    private(set) var phase: Phase = .idle
    /// Le son reçu est joué ; sinon, il est reçu mais muet.
    private(set) var playsAudio = false

    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private var signal: Signal?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var peer: RTCPeerConnection?
    @ObservationIgnored private var observer: PeerObserver?
    @ObservationIgnored private var track: RTCVideoTrack?
    @ObservationIgnored private var audioTrack: RTCAudioTrack?
    @ObservationIgnored private var renderer: RTCMTLVideoView?
    @ObservationIgnored private var retry: (any Cancellable)?
    @ObservationIgnored private var gathering: CheckedContinuation<Void, Never>?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        // Périphérique audio en sortie seule : WebRTC ne demande jamais le micro de l'iPhone.
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory(),
            audioDevice: PlayoutAudioDevice()
        )
    }()

    init(scheduler: any Scheduler) {
        self.scheduler = scheduler
    }

    /// La vue qui affiche l'image, fournie par VideoView.
    func attach(renderer: RTCMTLVideoView) {
        self.renderer = renderer
        track?.add(renderer)
    }

    /// Joue ou coupe le son reçu, tout de suite et pour les connexions suivantes.
    func setPlaysAudio(_ on: Bool) {
        playsAudio = on
        audioTrack?.isEnabled = on
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
        }
        let audio = peer.addTransceiver(of: .audio, init: receiveOnly)
        if let track = audio?.receiver.track as? RTCAudioTrack {
            track.isEnabled = playsAudio
            audioTrack = track
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
