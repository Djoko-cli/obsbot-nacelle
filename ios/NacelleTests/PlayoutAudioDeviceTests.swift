import Testing
@testable import Nacelle

@Suite("Périphérique audio en sortie seule")
struct PlayoutAudioDeviceTests {
    @Test("Sortie mono 48 kHz, aucune entrée : l'enregistrement est refusé")
    func outputOnly() {
        let device = PlayoutAudioDevice()
        #expect(device.deviceOutputSampleRate == 48_000)
        #expect(device.outputNumberOfChannels == 1)
        #expect(device.inputNumberOfChannels == 0)
        #expect(!device.initializeRecording())
        #expect(!device.startRecording())
        #expect(!device.isRecordingInitialized)
        #expect(!device.isRecording)
        #expect(!device.isInitialized)
        #expect(device.stopPlayout())
    }
}
