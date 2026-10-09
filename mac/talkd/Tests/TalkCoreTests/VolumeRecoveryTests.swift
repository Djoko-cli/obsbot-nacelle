import Foundation
import Testing
@testable import TalkCore

/// Le fichier de reprise, gardé en mémoire.
@MainActor
final class MemoryRecoveryStore: VolumeRecoveryStore {
    struct Failure: Error, CustomStringConvertible {
        var description: String { "disque plein" }
    }

    var record: VolumeRecovery?
    /// Le fichier existe mais ne se lit pas.
    var unreadable = false
    var failSaves = false
    private(set) var saves = 0
    private(set) var clears = 0

    func save(_ record: VolumeRecovery) throws {
        if failSaves { throw Failure() }
        saves += 1
        self.record = record
        unreadable = false
    }

    func load() throws -> VolumeRecovery? {
        if unreadable { throw Failure() }
        return record
    }

    func clear() throws {
        clears += 1
        record = nil
        unreadable = false
    }
}

@MainActor
@Suite("Reprise du volume après un arrêt anormal")
struct VolumeRecoveryTests {
    static let at = Date(timeIntervalSince1970: 1_791_000_000)
    let device: DeviceID = 41
    let volume = FakeVolume()
    let store = MemoryRecoveryStore()
    let log = LogRecorder()

    private func guardian() -> VolumeGuard {
        VolumeGuard(
            device: device, deviceName: "Haut-parleurs du Mac", floor: 0.30, volume: volume, recovery: store,
            now: { Self.at }, log: log.sink
        )
    }

    private var speaker: AudioDeviceInfo {
        .builtInSpeakers(id: 52)
    }

    /// Ce que talkd aurait laissé en tombant : 10 % en sourdine, relevé à 30 % et remis en route.
    private func leftBehind(written: SpeakerVolumeState = SpeakerVolumeState(volume: 0.30, muted: false)) -> VolumeRecovery {
        VolumeRecovery(
            device: 41, deviceName: "Haut-parleurs du Mac", original: SpeakerVolumeState(volume: 0.1, muted: true),
            raisedVolume: true, unmuted: true, written: written, at: Self.at
        )
    }

    private func recover(speaker: AudioDeviceInfo?) {
        VolumeGuard.recover(from: store, speaker: speaker, volume: volume, log: log.sink)
    }

    // MARK: - Enregistrement et effacement

    @Test("begin() enregistre le fichier après la relecture : la valeur retenue par le pilote, pas la valeur visée")
    func beginSaves() throws {
        volume.step = 0.0625
        volume.states[device] = SpeakerVolumeState(volume: 0.0625, muted: true)
        guardian().begin()
        let record = try #require(store.record)
        #expect(record.device == device)
        #expect(record.deviceName == "Haut-parleurs du Mac")
        #expect(record.original == SpeakerVolumeState(volume: 0.0625, muted: true))
        #expect(record.raisedVolume)
        #expect(record.unmuted)
        #expect(record.written == SpeakerVolumeState(volume: 0.3125, muted: false))
        #expect(record.at == Self.at)
    }

    @Test("Au-dessus du seuil, rien n'est touché : aucun fichier")
    func nothingToSave() {
        volume.states[device] = SpeakerVolumeState(volume: 0.6, muted: false)
        let guardian = guardian()
        guardian.begin()
        guardian.end()
        #expect(store.saves == 0)
    }

    @Test("Enregistrement refusé : journalisé, la voix passe quand même au volume relevé")
    func saveFails() {
        store.failSaves = true
        volume.states[device] = SpeakerVolumeState(volume: 0.1, muted: false)
        guardian().begin()
        #expect(volume.states[device]?.volume == 0.30)
        #expect(log.contains("fichier de reprise"))
    }

    @Test("end() efface le fichier dans les trois cas : rétabli, changé par l'utilisateur, écriture refusée")
    func endClears() {
        volume.states[device] = SpeakerVolumeState(volume: 0.1, muted: false)
        let restored = guardian()
        restored.begin()
        restored.end()
        #expect(store.record == nil)
        #expect(volume.states[device]?.volume == 0.1)

        let overridden = guardian()
        overridden.begin()
        #expect(store.record != nil)
        volume.userSets(device: device, volume: 0.8)
        overridden.end()
        #expect(store.record == nil)

        volume.states[device] = SpeakerVolumeState(volume: 0.1, muted: false)
        let refused = guardian()
        refused.begin()
        #expect(store.record != nil)
        volume.failWrites = true
        refused.end()
        #expect(store.record == nil)
        #expect(log.contains("n'a pas pu être rétabli"))
    }

    // MARK: - Reprise au démarrage

    @Test("Reprise : le volume vaut toujours celui que talkd avait écrit, l'état d'origine est rétabli sur le numéro actuel")
    func recoverRestores() {
        store.record = leftBehind()
        volume.states[52] = SpeakerVolumeState(volume: 0.302, muted: false)
        recover(speaker: speaker)
        #expect(volume.states[52] == SpeakerVolumeState(volume: 0.1, muted: true))
        #expect(log.contains("Volume rétabli après un arrêt anormal"))
        #expect(store.record == nil)
    }

    @Test("Reprise : le volume a changé depuis, rien n'est rétabli")
    func recoverChanged() {
        store.record = leftBehind()
        volume.states[52] = SpeakerVolumeState(volume: 0.55, muted: false)
        recover(speaker: speaker)
        #expect(volume.writes.isEmpty)
        #expect(volume.states[52]?.volume == 0.55)
        #expect(log.contains("modifié depuis, rien n'est rétabli"))
        #expect(store.record == nil)

        // La sourdine compte aussi.
        store.record = leftBehind()
        volume.states[52] = SpeakerVolumeState(volume: 0.30, muted: true)
        recover(speaker: speaker)
        #expect(volume.writes.isEmpty)
    }

    @Test("Reprise : autres haut-parleurs (nom différent) ou aucun, le fichier est effacé sans rien toucher")
    func recoverOtherDevice() {
        store.record = leftBehind()
        volume.states[52] = SpeakerVolumeState(volume: 0.30, muted: false)
        recover(speaker: AudioDeviceInfo(id: 52, name: "Autre sortie", transport: .builtIn, outputChannels: 2, isDefaultOutput: false))
        #expect(volume.writes.isEmpty)
        #expect(store.record == nil)
        #expect(log.contains("autre périphérique"))

        store.record = leftBehind()
        recover(speaker: nil)
        #expect(volume.writes.isEmpty)
        #expect(store.record == nil)
    }

    @Test("Reprise : fichier illisible, effacé et journalisé")
    func recoverUnreadable() {
        store.unreadable = true
        recover(speaker: speaker)
        #expect(store.clears == 1)
        #expect(volume.writes.isEmpty)
        #expect(log.contains("illisible"))
    }

    @Test("Reprise : aucun fichier, rien n'est fait ni journalisé")
    func recoverNothing() {
        recover(speaker: speaker)
        #expect(volume.writes.isEmpty)
        #expect(log.lines.isEmpty)
        #expect(store.clears == 0)
    }

    @Test("Reprise répétée (relances en boucle) : idempotente, le volume n'est rétabli qu'une fois")
    func recoverIdempotent() {
        store.record = leftBehind()
        volume.states[52] = SpeakerVolumeState(volume: 0.30, muted: false)
        recover(speaker: speaker)
        let writes = volume.writes.count
        recover(speaker: speaker)
        #expect(volume.writes.count == writes)
    }

    // MARK: - Fichier et contrôleur

    @Test("Le fichier JSON : écrit de façon atomique, relu tel quel, effacé ; absent, rien ; illisible, une erreur")
    func fileStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "support/talkd-volume.json")
        let store = JSONFileVolumeRecoveryStore(url: url)
        #expect(try store.load() == nil)
        try store.clear()
        try store.save(leftBehind())
        #expect(try store.load() == leftBehind())
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["talkd-volume.json"])
        try store.clear()
        #expect(try store.load() == nil)
        try Data("pas du json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test("Au démarrage du contrôleur, la reprise est faite sur les haut-parleurs trouvés")
    func controllerRecoversAtStart() {
        let store = MemoryRecoveryStore()
        store.record = leftBehind()
        let rig = Rig(volumeState: SpeakerVolumeState(volume: 0.30, muted: false), recovery: store)
        #expect(rig.volume.states[41] == SpeakerVolumeState(volume: 0.1, muted: true))
        #expect(rig.log.contains("Volume rétabli après un arrêt anormal"))
        #expect(store.record == nil)
    }

    @Test("Prise de parole dans le contrôleur : fichier enregistré au début, effacé à la fin")
    func controllerSpeech() {
        let rig = Rig(volumeState: SpeakerVolumeState(volume: 0.1, muted: false))
        rig.send(voice, count: 3)
        #expect(rig.recovery.record?.deviceName == "Haut-parleurs du Mac")
        rig.wait(3)
        #expect(rig.recovery.record == nil)
    }
}
