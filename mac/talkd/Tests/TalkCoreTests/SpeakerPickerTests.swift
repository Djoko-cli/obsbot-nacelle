import Foundation
import Testing
@testable import TalkCore

@Suite("Choix des haut-parleurs intégrés")
struct SpeakerPickerTests {
    @Test("Les haut-parleurs intégrés sont choisis par leur type de transport, même quand la sortie par défaut est ailleurs")
    func defaultElsewhere() {
        let devices: [AudioDeviceInfo] = [.external(id: 60, isDefault: true), .builtInMicrophone(), .builtInSpeakers(id: 41)]
        #expect(SpeakerPicker.builtInSpeakers(in: devices)?.id == 41)
    }

    @Test("Un périphérique intégré sans canal de sortie (le micro) n'est pas un haut-parleur")
    func microphoneIsNotASpeaker() {
        #expect(SpeakerPicker.builtInSpeakers(in: [.builtInMicrophone(), .external()]) == nil)
    }

    @Test("Un périphérique externe n'est jamais choisi, même seul")
    func externalOnly() {
        #expect(SpeakerPicker.builtInSpeakers(in: [.external(id: 60), .external(id: 61, isDefault: false)]) == nil)
        #expect(SpeakerPicker.builtInSpeakers(in: []) == nil)
    }

    @Test("Le choix ne dépend pas du rang dans la liste ; plusieurs intégrés : celui qui est la sortie par défaut, sinon le plus petit numéro")
    func deterministic() {
        let a = AudioDeviceInfo.builtInSpeakers(id: 50)
        let b = AudioDeviceInfo.builtInSpeakers(id: 44)
        #expect(SpeakerPicker.builtInSpeakers(in: [a, b])?.id == 44)
        #expect(SpeakerPicker.builtInSpeakers(in: [b, a])?.id == 44)
        let defaultOne = AudioDeviceInfo.builtInSpeakers(id: 50, isDefault: true)
        #expect(SpeakerPicker.builtInSpeakers(in: [b, defaultOne])?.id == 50)
    }
}
