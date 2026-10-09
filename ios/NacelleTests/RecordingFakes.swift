import CoreMedia
import Foundation
@preconcurrency import WebRTC
@testable import Nacelle

/// Enregistreur simulé : écrit un petit fichier à `start`, compte ce qu'il reçoit, et rend la durée voulue.
/// `holdFinish` garde `finish()` en suspens jusqu'à `releaseFinish()` (pour voir l'état « enregistrement en cours de sauvegarde »).
final class FakeClipRecorder: ClipRecording, @unchecked Sendable {
    struct State {
        var url: URL?
        var audioSource: AudioRingBuffer?
        var frames = 0
        var finishCount = 0
        var cancelCount = 0
        var startError: (any Error)?
        var finishResult: Result<TimeInterval, any Error> = .success(42)
        var holdFinish = false
        var held: CheckedContinuation<Void, Never>?
        var onFailure: (@Sendable () -> Void)?
    }

    let state = Locked(State())

    var url: URL? { state.withLock { $0.url } }
    var frames: Int { state.withLock { $0.frames } }
    var finishCount: Int { state.withLock { $0.finishCount } }
    var cancelCount: Int { state.withLock { $0.cancelCount } }

    var onFailure: (@Sendable () -> Void)? {
        get { state.withLock { $0.onFailure } }
        set { state.withLock { $0.onFailure = newValue } }
    }

    /// Simule un échec d'écriture en cours de route : l'enregistreur prévient son écouteur.
    func triggerFailure() {
        onFailure?()
    }

    func start(url: URL, audioSource: AudioRingBuffer?) throws {
        if let error = state.withLock({ $0.startError }) {
            throw error
        }
        try Data("vidéo de synthèse".utf8).write(to: url)
        state.withLock {
            $0.url = url
            $0.audioSource = audioSource
        }
    }

    func append(video frame: RTCVideoFrame, at time: CMTime) {
        state.withLock { $0.frames += 1 }
    }

    func finish() async throws -> RecordingResult {
        state.withLock { $0.finishCount += 1 }
        if state.withLock({ $0.holdFinish }) {
            await withCheckedContinuation { continuation in
                state.withLock { $0.held = continuation }
            }
        }
        let (url, result) = state.withLock { ($0.url, $0.finishResult) }
        switch result {
        case let .success(duration):
            return RecordingResult(url: url ?? URL(fileURLWithPath: "/dev/null"), duration: duration)
        case let .failure(error):
            throw error
        }
    }

    func releaseFinish() {
        let held = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.holdFinish = false
            defer { state.held = nil }
            return state.held
        }
        held?.resume()
    }

    func cancel() {
        state.withLock { $0.cancelCount += 1 }
    }
}

/// Accès à Photos simulé.
final class FakePhotoSaver: PhotoLibrarySaving, @unchecked Sendable {
    struct State {
        var access = PhotoAccess.notDetermined
        /// Réponse à la demande d'accès.
        var answer = PhotoAccess.granted
        var requestCount = 0
        var saveError: (any Error)?
        var saved: [URL] = []
        /// Le fichier existait-il quand on l'a ajouté ?
        var existedAtSave: [Bool] = []
    }

    let state = Locked(State())

    var access: PhotoAccess { state.withLock { $0.access } }
    var requestCount: Int { state.withLock { $0.requestCount } }
    var saved: [URL] { state.withLock { $0.saved } }

    func requestAccess() async -> PhotoAccess {
        state.withLock {
            $0.requestCount += 1
            if $0.access == .notDetermined { $0.access = $0.answer }
            return $0.access
        }
    }

    func save(videoAt url: URL) async throws {
        let error = state.withLock { state -> (any Error)? in
            state.existedAtSave.append(FileManager.default.fileExists(atPath: url.path))
            if state.saveError == nil { state.saved.append(url) }
            return state.saveError
        }
        if let error { throw error }
    }
}

struct FakeFailure: Error, Equatable {}

/// Tâches de fond simulées : compte les débuts et les fins, et garde le rappel d'expiration.
@MainActor
final class FakeBackgroundTasks: BackgroundTasking {
    private(set) var begun = 0
    private(set) var ended: [Int] = []
    private(set) var expiry: (@MainActor () -> Void)?
    var refuses = false

    func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> Int? {
        guard !refuses else { return nil }
        begun += 1
        expiry = onExpiry
        return begun
    }

    func end(_ id: Int) {
        ended.append(id)
    }
}
