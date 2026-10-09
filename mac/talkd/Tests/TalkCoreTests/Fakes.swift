import Foundation
@testable import TalkCore

/// Horloge manuelle : `advance(by:)` exécute les actions arrivées à échéance, dans l'ordre.
@MainActor
final class FakeScheduler: Scheduler {
    private(set) var now: TimeInterval = 0
    private var tasks: [FakeTask] = []
    private var counter = 0

    var pendingCount: Int {
        tasks.filter { !$0.cancelled }.count
    }

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
        counter += 1
        let task = FakeTask(at: now + delay, order: counter, action: action)
        tasks.append(task)
        return task
    }

    func advance(by delta: TimeInterval) {
        let target = now + delta
        while let next = tasks
            .filter({ !$0.cancelled && $0.at <= target + 1e-9 })
            .min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            tasks.removeAll { $0 === next }
            now = max(now, next.at)
            next.action()
        }
        now = target
        tasks.removeAll { $0.cancelled }
    }
}

final class FakeTask: Cancellable {
    let at: TimeInterval
    let order: Int
    let action: @MainActor @Sendable () -> Void
    private(set) var cancelled = false

    init(at: TimeInterval, order: Int, action: @escaping @MainActor @Sendable () -> Void) {
        self.at = at
        self.order = order
        self.action = action
    }

    func cancel() {
        cancelled = true
    }
}

/// Un jeton d'observation annulable.
final class FakeToken: Cancellable {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

/// Liste de périphériques simulée.
@MainActor
final class FakeCatalog: DeviceCatalog {
    var list: [AudioDeviceInfo]
    var failure: (any Error)?
    private var handlers: [@MainActor @Sendable () -> Void] = []
    private(set) var queries = 0

    init(_ list: [AudioDeviceInfo]) {
        self.list = list
    }

    func devices() throws -> [AudioDeviceInfo] {
        queries += 1
        if let failure { throw failure }
        return list
    }

    func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> (any Cancellable)? {
        handlers.append(handler)
        return FakeToken()
    }

    /// Le test change la liste puis prévient, comme CoreAudio.
    func change(to list: [AudioDeviceInfo]) {
        self.list = list
        for handler in handlers { handler() }
    }
}

/// Un faux moteur audio : il compte les démarrages et les arrêts, ne joue rien.
@MainActor
final class FakeOutput: AudioOutput {
    struct Failure: Error, CustomStringConvertible {
        var description: String { "coreaudiod ne répond pas" }
    }

    private(set) var isRunning = false
    private(set) var starts: [DeviceID] = []
    /// Tentatives de démarrage, réussies ou non.
    private(set) var startAttempts = 0
    private(set) var stops = 0
    private(set) var buffer: JitterBuffer?
    var failNextStart = false

    func start(device: DeviceID, feeding buffer: JitterBuffer) throws {
        startAttempts += 1
        if failNextStart {
            failNextStart = false
            throw Failure()
        }
        starts.append(device)
        self.buffer = buffer
        isRunning = true
    }

    func stop() {
        stops += 1
        isRunning = false
    }

    /// Le système arrête l'unité sans que talkd l'ait demandé.
    func stoppedBySystem() {
        isRunning = false
    }

    /// Ce que le moteur tirerait du tampon, en échantillons de 16 bits.
    func drain() -> [Int16] {
        guard let buffer else { return [] }
        let count = buffer.bufferedSamples
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { buffer.pull(into: $0.baseAddress!, count: count) }
        return out.map { Int16($0 * 32768) }
    }
}

/// Volume et sourdine simulés. Comme CoreAudio, il prévient aussi des changements faits par talkd lui-même.
@MainActor
final class FakeVolume: SpeakerVolume {
    struct Failure: Error, CustomStringConvertible {
        var description: String { "propriété indisponible" }
    }

    var states: [DeviceID: SpeakerVolumeState] = [:]
    /// Pas de quantification du volume (certains pilotes n'ont que quelques crans) ; 0 : aucun.
    var step: Float = 0
    var failReads = false
    var failWrites = false
    private(set) var writes: [(device: DeviceID, volume: Float?, muted: Bool?)] = []
    private var observers: [(token: FakeToken, handler: @MainActor @Sendable () -> Void)] = []

    var activeObservers: Int {
        observers.filter { !$0.token.cancelled }.count
    }

    func read(device: DeviceID) throws -> SpeakerVolumeState {
        if failReads { throw Failure() }
        guard let state = states[device] else { throw Failure() }
        return state
    }

    func write(device: DeviceID, volume: Float?, muted: Bool?) throws {
        if failWrites { throw Failure() }
        writes.append((device, volume, muted))
        apply(device: device, volume: volume, muted: muted)
    }

    func observe(device: DeviceID, _ handler: @escaping @MainActor @Sendable () -> Void) -> (any Cancellable)? {
        let token = FakeToken()
        observers.append((token, handler))
        return token
    }

    /// L'utilisateur touche au volume ou à la sourdine : l'écouteur est prévenu.
    func userSets(device: DeviceID, volume: Float? = nil, muted: Bool? = nil) {
        apply(device: device, volume: volume, muted: muted)
    }

    private func apply(device: DeviceID, volume: Float?, muted: Bool?) {
        var state = states[device] ?? SpeakerVolumeState(volume: 0, muted: false)
        if let volume {
            state.volume = step > 0 ? (volume / step).rounded() * step : volume
        }
        if let muted {
            state.muted = muted
        }
        states[device] = state
        for observer in observers where !observer.token.cancelled { observer.handler() }
    }
}

/// État écrit par talkd, gardé en mémoire.
@MainActor
final class MemoryStateStore: TalkStateStore {
    private(set) var saved: [TalkState] = []
    var failure: (any Error)?

    func save(_ state: TalkState) throws {
        if let failure { throw failure }
        saved.append(state)
    }

    var last: TalkState? {
        saved.last
    }
}

extension AudioDeviceInfo {
    static func builtInSpeakers(id: DeviceID = 41, isDefault: Bool = false) -> AudioDeviceInfo {
        AudioDeviceInfo(id: id, name: "Haut-parleurs du Mac", transport: .builtIn, outputChannels: 2, isDefaultOutput: isDefault)
    }

    static func builtInMicrophone(id: DeviceID = 40) -> AudioDeviceInfo {
        AudioDeviceInfo(id: id, name: "Micro du Mac", transport: .builtIn, outputChannels: 0, isDefaultOutput: false)
    }

    static func external(id: DeviceID = 60, isDefault: Bool = true) -> AudioDeviceInfo {
        AudioDeviceInfo(id: id, name: "Casque USB", transport: .other, outputChannels: 2, isDefaultOutput: isDefault)
    }
}
