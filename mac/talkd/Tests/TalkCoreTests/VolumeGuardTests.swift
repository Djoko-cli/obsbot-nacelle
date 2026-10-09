import Foundation
import Testing
@testable import TalkCore

@MainActor
@Suite("Volume minimum")
struct VolumeGuardTests {
    let device: DeviceID = 41
    let volume = FakeVolume()
    let log = LogRecorder()

    private func guardian(floor: Double = 0.30) -> VolumeGuard {
        VolumeGuard(device: device, floor: floor, volume: volume, log: log.sink)
    }

    @Test("Au-dessus du seuil : talkd n'y touche pas")
    func aboveFloor() {
        volume.states[device] = SpeakerVolumeState(volume: 0.6, muted: false)
        let guardian = guardian()
        guardian.begin()
        guardian.end()
        #expect(volume.writes.isEmpty)
        #expect(volume.activeObservers == 0)
    }

    @Test("Sous le seuil : remonté à 30 % le temps de la voix, puis rétabli")
    func belowFloor() {
        volume.states[device] = SpeakerVolumeState(volume: 0.1, muted: false)
        let guardian = guardian()
        guardian.begin()
        #expect(volume.states[device] == SpeakerVolumeState(volume: 0.30, muted: false))
        guardian.end()
        #expect(volume.states[device] == SpeakerVolumeState(volume: 0.1, muted: false))
        #expect(volume.activeObservers == 0)
    }

    @Test("En sourdine au-dessus du seuil : remis en route, volume intact, puis remis en sourdine")
    func mutedAboveFloor() {
        volume.states[device] = SpeakerVolumeState(volume: 0.6, muted: true)
        let guardian = guardian()
        guardian.begin()
        #expect(volume.states[device] == SpeakerVolumeState(volume: 0.6, muted: false))
        #expect(volume.writes.allSatisfy { $0.volume == nil })
        guardian.end()
        #expect(volume.states[device] == SpeakerVolumeState(volume: 0.6, muted: true))
    }

    @Test("En sourdine et sous le seuil : les deux sont réglés, puis les deux rétablis")
    func mutedBelowFloor() {
        volume.states[device] = SpeakerVolumeState(volume: 0.05, muted: true)
        let guardian = guardian()
        guardian.begin()
        #expect(volume.states[device] == SpeakerVolumeState(volume: 0.30, muted: false))
        guardian.end()
        #expect(volume.states[device] == SpeakerVolumeState(volume: 0.05, muted: true))
    }

    @Test("Le seuil est réglable (volumeFloor)")
    func customFloor() {
        volume.states[device] = SpeakerVolumeState(volume: 0.4, muted: false)
        let guardian = guardian(floor: 0.5)
        guardian.begin()
        #expect(volume.states[device]?.volume == 0.5)
        guardian.end()
        #expect(volume.states[device]?.volume == 0.4)
    }

    @Test("Volume pile au seuil, ou à la tolérance près : pas touché")
    func atFloor() {
        volume.states[device] = SpeakerVolumeState(volume: 0.30, muted: false)
        let guardian = guardian()
        guardian.begin()
        #expect(volume.writes.isEmpty)
        volume.states[device] = SpeakerVolumeState(volume: 0.2999, muted: false)
        guardian.begin()
        #expect(volume.writes.isEmpty)
    }

    @Test("Les changements faits par talkd lui-même, que l'écouteur rapporte aussi, ne comptent pas comme ceux de l'utilisateur")
    func ownChangesIgnored() {
        volume.states[device] = SpeakerVolumeState(volume: 0.1, muted: true)
        let guardian = guardian()
        guardian.begin()
        // L'écouteur a été prévenu des écritures de talkd : rien d'autre ne s'est passé.
        guardian.end()
        #expect(volume.states[device] == SpeakerVolumeState(volume: 0.1, muted: true))
        #expect(!log.contains("utilisateur"))
    }

    @Test("Volume quantifié par le pilote (0,30 devient 0,3125) : la valeur relue sert de référence, pas de faux changement")
    func quantizedDriver() {
        volume.step = 0.0625
        volume.states[device] = SpeakerVolumeState(volume: 0.0625, muted: false)
        let guardian = guardian()
        guardian.begin()
        let raised = volume.states[device]?.volume
        #expect(raised == 0.3125)
        guardian.end()
        #expect(volume.states[device]?.volume == 0.0625)
        #expect(!log.contains("utilisateur"))
    }

    @Test("L'utilisateur change le volume pendant la parole : rien n'est rétabli, son réglage l'emporte")
    func userChangesVolume() {
        volume.states[device] = SpeakerVolumeState(volume: 0.1, muted: false)
        let guardian = guardian()
        guardian.begin()
        volume.userSets(device: device, volume: 0.8)
        guardian.end()
        #expect(volume.states[device]?.volume == 0.8)
        #expect(log.contains("utilisateur"))
    }

    @Test("L'utilisateur remet la sourdine pendant la parole : rien n'est rétabli")
    func userMutes() {
        volume.states[device] = SpeakerVolumeState(volume: 0.1, muted: false)
        let guardian = guardian()
        guardian.begin()
        volume.userSets(device: device, muted: true)
        guardian.end()
        #expect(volume.states[device] == SpeakerVolumeState(volume: 0.30, muted: true))
    }

    @Test("Un changement de l'utilisateur est vu à la fin même sans notification de l'écouteur")
    func userChangeWithoutNotification() {
        volume.states[device] = SpeakerVolumeState(volume: 0.1, muted: false)
        let guardian = guardian()
        guardian.begin()
        volume.states[device] = SpeakerVolumeState(volume: 0.9, muted: false)
        guardian.end()
        #expect(volume.states[device]?.volume == 0.9)
    }

    @Test("Volume lu et écrit à 0,005 près : un écart plus petit n'est pas un changement de l'utilisateur")
    func tolerance() {
        volume.states[device] = SpeakerVolumeState(volume: 0.1, muted: false)
        let guardian = guardian()
        guardian.begin()
        volume.userSets(device: device, volume: 0.303)
        guardian.end()
        #expect(volume.states[device]?.volume == 0.1)
        volume.states[device] = SpeakerVolumeState(volume: 0.1, muted: false)
        let second = self.guardian()
        second.begin()
        volume.userSets(device: device, volume: 0.31)
        second.end()
        #expect(volume.states[device]?.volume == 0.31)
    }

    @Test("Volume illisible : journalisé, la parole continue sans toucher à rien")
    func unreadable() {
        volume.failReads = true
        let guardian = guardian()
        guardian.begin()
        guardian.end()
        #expect(volume.writes.isEmpty)
        #expect(log.contains("illisible"))
    }

    @Test("Écriture refusée : journalisé, rien à rétablir")
    func unwritable() {
        volume.states[device] = SpeakerVolumeState(volume: 0.1, muted: false)
        volume.failWrites = true
        let guardian = guardian()
        guardian.begin()
        volume.failWrites = false
        guardian.end()
        #expect(volume.writes.isEmpty)
        #expect(log.contains("n'a pas pu être relevé"))
    }

    @Test("end() sans begin(), ou deux fois : sans effet")
    func idempotent() {
        volume.states[device] = SpeakerVolumeState(volume: 0.1, muted: false)
        let guardian = guardian()
        guardian.end()
        guardian.begin()
        guardian.end()
        let writes = volume.writes.count
        guardian.end()
        #expect(volume.writes.count == writes)
    }
}
