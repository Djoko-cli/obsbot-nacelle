import Foundation
import Testing
@testable import PTZBotKit

@MainActor
@Suite("go2rtc : onglet Caméra des Réglages", .french, .timeLimit(.minutes(1)))
struct Go2RTCSettingsModelTests {
    let launcher = FakeLauncher()
    let settings = FakeSettings()
    let store = FakeSettings()
    let scheduler = FakeScheduler()
    let preparer = FakePreparer()

    private func make(enabled: Bool = false, catalog: FakeCatalog = FakeCatalog()) -> (Go2RTCSupervisor, Go2RTCSettingsModel) {
        settings.values[Go2RTCSupervisor.enabledKey] = enabled
        let supervisor = Go2RTCSupervisor(
            paths: Go2RTCSupervisor.Paths(gardien: URL(fileURLWithPath: "/app/gardien"), go2rtc: URL(fileURLWithPath: "/app/go2rtc"),
                                          log: URL(fileURLWithPath: "/logs/go2rtc.log")),
            launcher: launcher, preparer: preparer, settings: settings, scheduler: scheduler, parentPID: 4242,
            configuration: Go2RTCFixtures.settings()
        )
        let model = Go2RTCSettingsModel(supervisor: supervisor, preparer: preparer, store: store, locator: .homebrew, catalog: catalog)
        return (supervisor, model)
    }

    @Test("Au départ : les réglages du superviseur, rien à appliquer")
    func initial() {
        let (_, model) = make()
        #expect(model.draft == Go2RTCFixtures.settings())
        #expect(!model.hasChanges)
    }

    @Test("Appliquer go2rtc éteint : yaml écrit, réglages retenus sans le mot de passe, rien n'est lancé")
    func applyWhileOff() async throws {
        let (supervisor, model) = make()
        model.draft.framerate = 25
        #expect(!model.applyRestartsGo2RTC)
        await model.apply()
        #expect(preparer.written.map(\.framerate) == [25])
        #expect(model.applied.framerate == 25)
        #expect(supervisor.configuration.framerate == 25)
        let saved = try #require(store.strings[Go2RTCSettings.preferencesKey])
        #expect(!saved.contains(Go2RTCFixtures.password))
        #expect(Go2RTCSettings.load(from: store).framerate == 25)
        #expect(launcher.launched.isEmpty)
        #expect(!model.hasChanges)
    }

    @Test("Appliquer go2rtc allumé : avertissement demandé, puis relance sur les nouveaux réglages")
    func applyWhileOn() async throws {
        let (supervisor, model) = make(enabled: true)
        supervisor.start()
        await supervisor.waitForPreparation()
        model.draft.bitrate = 6
        #expect(model.applyRestartsGo2RTC)
        await model.apply()
        await supervisor.waitForPreparation()
        #expect(try #require(launcher.launched.first).terminations == 1)
        #expect(launcher.launched.count == 2)
        #expect(preparer.prepared.last?.bitrate == 6)
    }

    @Test("Un réglage qui ne change rien ne relance rien ; un yaml refusé ne retient rien et le dit")
    func noChangeAndFailure() async throws {
        let (supervisor, model) = make(enabled: true)
        supervisor.start()
        await supervisor.waitForPreparation()
        await model.apply()
        #expect(preparer.written.isEmpty)
        #expect(launcher.launched.count == 1)
        preparer.writeResult = .ffmpegMissing
        model.draft.framerate = 15
        await model.apply()
        #expect(model.message == "ffmpeg introuvable")
        #expect(model.applied.framerate == 30)
        #expect(store.strings[Go2RTCSettings.preferencesKey] == nil)
        #expect(launcher.launched.count == 1)
        model.revert()
        #expect(!model.hasChanges)
        #expect(model.message == nil)
    }

    @Test("Détection : appareils et ffmpeg ; un nom réglé débranché reste proposé")
    func detection() async {
        let (_, model) = make()
        model.draft.cameraName = "Caméra débranchée"
        await model.refreshDetection()
        #expect(model.ffmpegChecked)
        #expect(model.detectedFFmpeg?.path == Go2RTCFixtures.ffmpeg)
        #expect(model.cameraChoices == ["OBSBOT Virtual Camera", Go2RTCFixtures.camera, "Caméra débranchée"])
        #expect(model.microphoneChoices == [Go2RTCFixtures.microphone])
    }

    @Test("Import : ce qui serait repris est montré, sans le mot de passe ; « Reprendre » le met dans les réglages ; illisible : le message")
    func importConfig() throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "go2rtc.yaml")
        try Data(Go2RTCImportTests.handWritten.utf8).write(to: file)
        let before = try Data(contentsOf: file)
        let (_, model) = make()
        model.previewImport(file)
        let preview = try #require(model.importPreview)
        let summary = Labels.go2rtcImportSummary(preview)
        #expect(summary == [
            "Identifiant : camera", "Mot de passe : repris", "Port RTSP : 8554", "Port WebRTC : 8555",
            "Caméra : OBSBOT Tiny 2 StreamCamera", "Micro : OBSBOT Tiny2 Microphone", "ffmpeg : /opt/homebrew/bin/ffmpeg",
        ])
        #expect(!summary.joined().contains("secret-de-test"))
        #expect(!model.hasChanges, "rien n'est repris avant « Reprendre »")
        model.acceptImport()
        #expect(model.draft.username == "camera")
        #expect(model.draft.password == "secret-de-test")
        #expect(model.importPreview == nil)
        #expect(try Data(contentsOf: file) == before, "le fichier importé n'est pas modifié")
        model.previewImport(directory.appending(path: "absent.yaml"))
        #expect(model.importPreview == nil)
        #expect(model.message?.hasPrefix("Ce fichier n'a pas pu être lu") == true)
    }

    @Test("L'avertissement d'« Appliquer » en français et en anglais")
    func warning() {
        #expect(Labels.go2rtcApplyWarning == "Le flux HomeKit sera coupé quelques secondes.")
        #expect(Localization.$languageOverride.withValue("en") { Labels.go2rtcApplyWarning } == "The HomeKit stream will stop for a few seconds.")
    }
}
