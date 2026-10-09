import Foundation

/// Volume principal (de 0 à 1) et sourdine d'un périphérique de sortie.
public struct SpeakerVolumeState: Codable, Equatable, Sendable {
    public var volume: Float
    public var muted: Bool

    public init(volume: Float, muted: Bool) {
        self.volume = volume
        self.muted = muted
    }
}

/// Le volume des haut-parleurs, derrière un protocole : CoreAudio dans l'exécutable (`VirtualMainVolume` et `Mute`,
/// sans droits root), un faux dans les tests. Le volume réel n'est jamais touché par les tests.
@MainActor
public protocol SpeakerVolume: AnyObject {
    func read(device: DeviceID) throws -> SpeakerVolumeState
    /// Écrit ce qui est donné ; le volume avant la sourdine, pour ne pas lâcher un volume fort d'un coup.
    func write(device: DeviceID, volume: Float?, muted: Bool?) throws
    /// `handler` est appelé à chaque changement de volume ou de sourdine, y compris ceux de talkd lui-même
    /// (spec § 4.3).
    func observe(device: DeviceID, _ handler: @escaping @MainActor @Sendable () -> Void) -> (any Cancellable)?
}

/// Le volume minimum le temps d'une prise de parole (spec haut-parleur § 5.4).
///
/// - `begin()` : en sourdine ou sous le minimum, les haut-parleurs sont remis en route à `floor`, l'état d'origine
///   mémorisé. Au-dessus du minimum, rien n'est touché.
/// - `end()` : l'état d'origine est rétabli, sauf si l'utilisateur a changé le volume ou la sourdine entre-temps.
///
/// L'écouteur de CoreAudio rapporte aussi les écritures de talkd : un changement est celui de l'utilisateur quand
/// la valeur lue s'écarte de la dernière valeur de talkd, de plus de 0,005. Cette valeur est relue après l'écriture :
/// un pilote qui n'a que quelques crans ne passe pas pour un utilisateur.
///
/// Reprise (relecture I2) : ce qui a été changé est enregistré dans le fichier de reprise après la relecture, et
/// effacé par `end()` quelle qu'en soit l'issue. Si talkd tombe entre les deux, `recover(from:…)` le rejoue au
/// démarrage suivant.
@MainActor
public final class VolumeGuard {
    public static let tolerance: Float = 0.005

    private let device: DeviceID
    private let deviceName: String
    private let floor: Float
    private let volume: any SpeakerVolume
    private let recovery: (any VolumeRecoveryStore)?
    private let now: () -> Date
    private let log: LogSink
    private var original: SpeakerVolumeState?
    private var raisedVolume = false
    private var unmuted = false
    private var written: SpeakerVolumeState?
    private var overridden = false
    private var observation: (any Cancellable)?

    public init(
        device: DeviceID,
        deviceName: String = "",
        floor: Double,
        volume: any SpeakerVolume,
        recovery: (any VolumeRecoveryStore)? = nil,
        now: @escaping () -> Date = Date.init,
        log: @escaping LogSink
    ) {
        self.device = device
        self.deviceName = deviceName
        self.floor = Float(floor)
        self.volume = volume
        self.recovery = recovery
        self.now = now
        self.log = log
    }

    public func begin() {
        guard original == nil else { return }
        let state: SpeakerVolumeState
        do {
            state = try volume.read(device: device)
        } catch {
            log("Volume des haut-parleurs illisible (\(error)) : la voix passe au volume actuel.")
            return
        }
        let low = state.volume < floor - Self.tolerance
        guard low || state.muted else { return }
        do {
            try volume.write(device: device, volume: low ? floor : nil, muted: state.muted ? false : nil)
        } catch {
            log("Le volume n'a pas pu être relevé (\(error)) : la voix passe au volume actuel.")
            return
        }
        original = state
        raisedVolume = low
        unmuted = state.muted
        // La valeur que le pilote retient vraiment, pour comparer ensuite.
        let reread = (try? volume.read(device: device)) ?? SpeakerVolumeState(volume: low ? floor : state.volume, muted: false)
        written = reread
        overridden = false
        // Après la relecture, pas avant l'écriture : la valeur visée (0,30) ne vaut pas toujours celle du pilote.
        do {
            try recovery?.save(VolumeRecovery(
                device: device, deviceName: deviceName, original: state, raisedVolume: low, unmuted: state.muted,
                written: reread, at: now()
            ))
        } catch {
            log("Le fichier de reprise du volume n'a pas pu être écrit (\(error)) : la voix passe quand même.")
        }
        observation = volume.observe(device: device) { [weak self] in self?.deviceChanged() }
        log("Volume des haut-parleurs relevé\(state.muted ? " et remis en route" : "") pour la voix : "
            + "\(Self.percent(state.volume)) %\(state.muted ? " (sourdine)" : "") → \(Self.percent(written?.volume ?? floor)) %.")
    }

    public func end() {
        guard let original else { return }
        observation?.cancel()
        observation = nil
        self.original = nil
        deviceChanged()
        // Le fichier est effacé quelle que soit l'issue : rétabli, changé par l'utilisateur ou écriture refusée.
        defer { clearRecovery(recovery, log: log) }
        if overridden {
            log("Volume modifié par l'utilisateur pendant la parole : rien n'est rétabli.")
            return
        }
        do {
            try Self.restore(device: device, original: original, raisedVolume: raisedVolume, unmuted: unmuted, volume: volume)
            log("Volume des haut-parleurs rétabli : \(Self.percent(original.volume)) %\(original.muted ? " (sourdine)" : "").")
        } catch {
            log("Le volume n'a pas pu être rétabli (\(error)).")
        }
    }

    /// Au démarrage de talkd : rejoue le fichier de reprise laissé par un talkd tombé en pleine parole.
    ///
    /// - Aucun fichier : rien.
    /// - Fichier illisible, haut-parleurs introuvables ou d'un autre nom : rien n'est touché.
    /// - Volume et sourdine qui valent toujours ce que talkd avait écrit (à 0,005 près) : l'état d'origine est rétabli,
    ///   sur le numéro actuel des haut-parleurs. Sinon, l'utilisateur l'a changé depuis : rien n'est rétabli.
    ///
    /// Le fichier est effacé dans tous les cas : relancée en boucle, la reprise ne rejoue rien deux fois.
    public static func recover(
        from store: any VolumeRecoveryStore,
        speaker: AudioDeviceInfo?,
        volume: any SpeakerVolume,
        log: LogSink
    ) {
        let record: VolumeRecovery
        do {
            guard let loaded = try store.load() else { return }
            record = loaded
        } catch {
            log("Fichier de reprise du volume illisible (\(error)) : effacé, rien n'est rétabli.")
            clearRecovery(store, log: log)
            return
        }
        defer { clearRecovery(store, log: log) }
        guard let speaker, speaker.name == record.deviceName else {
            log("Reprise du volume : les haut-parleurs « \(record.deviceName) » sont introuvables (autre périphérique) ; "
                + "rien n'est rétabli.")
            return
        }
        let current: SpeakerVolumeState
        do {
            current = try volume.read(device: speaker.id)
        } catch {
            log("Reprise du volume : volume illisible (\(error)) ; rien n'est rétabli.")
            return
        }
        guard abs(current.volume - record.written.volume) <= tolerance, current.muted == record.written.muted else {
            log("Reprise du volume après un arrêt anormal : modifié depuis, rien n'est rétabli.")
            return
        }
        do {
            try restore(
                device: speaker.id, original: record.original, raisedVolume: record.raisedVolume,
                unmuted: record.unmuted, volume: volume
            )
            log("Volume rétabli après un arrêt anormal : \(percent(record.original.volume)) %"
                + "\(record.original.muted ? " (sourdine)" : "").")
        } catch {
            log("Reprise du volume : le volume n'a pas pu être rétabli (\(error)).")
        }
    }

    /// Les écritures qui défont celles de `begin()` : le volume s'il a été relevé, puis la sourdine si elle a été levée.
    private static func restore(
        device: DeviceID, original: SpeakerVolumeState, raisedVolume: Bool, unmuted: Bool, volume: any SpeakerVolume
    ) throws {
        try volume.write(device: device, volume: raisedVolume ? original.volume : nil, muted: unmuted ? true : nil)
    }

    /// Notification de l'écouteur, ou relecture finale : un écart avec la dernière valeur de talkd est celui de l'utilisateur.
    private func deviceChanged() {
        guard let written, !overridden, let current = try? volume.read(device: device) else { return }
        if abs(current.volume - written.volume) > Self.tolerance || current.muted != written.muted {
            overridden = true
        }
    }

    private static func percent(_ value: Float) -> Int {
        Int((value * 100).rounded())
    }
}

@MainActor
private func clearRecovery(_ store: (any VolumeRecoveryStore)?, log: LogSink) {
    do {
        try store?.clear()
    } catch {
        log("Le fichier de reprise du volume n'a pas pu être effacé (\(error)).")
    }
}
