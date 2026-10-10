import Foundation
import NacelleProtocol
@testable import Nacelle

/// Accès au micro simulé : le test choisit l'état et la réponse à la demande.
@MainActor
final class FakeMicPermission: MicrophonePermission {
    var access: MicAccess
    /// Réponse à `request()` ; l'état passe alors à `granted` ou `denied`.
    var grants = true
    /// Garde `request()` en suspens jusqu'à `answerRequest()`.
    var holdRequest = false
    private(set) var requestCount = 0
    private var held: CheckedContinuation<Bool, Never>?

    init(_ access: MicAccess = .granted) {
        self.access = access
    }

    func request() async -> Bool {
        requestCount += 1
        if holdRequest {
            let answer = await withCheckedContinuation { held = $0 }
            access = answer ? .granted : .denied
            return answer
        }
        access = grants ? .granted : .denied
        return grants
    }

    func answerRequest(_ granted: Bool) {
        held?.resume(returning: granted)
        held = nil
    }
}

/// Le côté audio de la parole, simulé : pas de session ni de micro.
@MainActor
final class FakeSpeechAudio: SpeechAudio {
    var onPackets: (@MainActor (_ packets: [Data], _ level: Float) -> Void)?
    var onInterrupted: (@MainActor () -> Void)?
    /// Résultat de `begin()`.
    var beginResult = true
    /// Garde `begin()` en suspens jusqu'à `finishBegin()`.
    var holdBegin = false
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private var held: CheckedContinuation<Bool, Never>?

    var isBeginPending: Bool {
        held != nil
    }

    func begin() async -> Bool {
        beginCount += 1
        if holdBegin {
            return await withCheckedContinuation { held = $0 }
        }
        return beginResult
    }

    func finishBegin(_ result: Bool = true) {
        held?.resume(returning: result)
        held = nil
    }

    func end() {
        endCount += 1
    }

    /// Le micro livre ces paquets.
    func deliver(_ packets: [Data], level: Float = 0.5) {
        onPackets?(packets, level)
    }
}

/// Le lien vers ptzd, simulé : garde les trames et leurs fins d'envoi.
@MainActor
final class FakeVoiceLink: VoiceLink {
    private(set) var frames: [Data] = []
    private var completions: [@MainActor () -> Void] = []
    /// Faux : la connexion est tombée.
    var accepts = true

    func sendVoice(_ frame: Data, completion: @escaping @MainActor () -> Void) -> Bool {
        guard accepts else { return false }
        frames.append(frame)
        completions.append(completion)
        return true
    }

    var inFlight: Int {
        completions.count
    }

    /// Signale la fin du plus ancien envoi.
    func complete() {
        guard !completions.isEmpty else { return }
        completions.removeFirst()()
    }
}

/// Un paquet reconnaissable : 640 octets tous égaux à `tag`.
func voicePacket(_ tag: UInt8) -> Data {
    Data(repeating: tag, count: VoiceFrame.byteCount)
}

extension SpeechServices {
    /// Doublures qui n'ouvrent ni session ni micro, pour les bancs d'essai qui ne parlent pas.
    @MainActor
    static func fake(audio: FakeSpeechAudio = FakeSpeechAudio(), permission: FakeMicPermission = FakeMicPermission()) -> SpeechServices {
        SpeechServices(audio: audio, permission: permission)
    }
}
