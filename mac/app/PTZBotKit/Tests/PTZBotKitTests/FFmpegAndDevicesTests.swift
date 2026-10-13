import Foundation
import Testing
@testable import PTZBotKit

@Suite("go2rtc : ffmpeg et appareils", .french)
struct FFmpegAndDevicesTests {
    /// Un ffmpeg simulé : `executables` existent, `responding` répondent à -version.
    private func locator(executables: Set<String>, responding: Set<String>? = nil) -> FFmpegLocator {
        let answering = responding ?? executables
        return FFmpegLocator(isExecutable: { executables.contains($0) }, respondsToVersion: { answering.contains($0) })
    }

    @Test("Ordre : le chemin réglé, puis Homebrew Apple Silicon, puis Intel")
    func order() {
        let all: Set = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/outils/ffmpeg"]
        #expect(locator(executables: all).locate(configured: "/outils/ffmpeg")?.path == "/outils/ffmpeg")
        #expect(locator(executables: all).locate(configured: nil)?.path == "/opt/homebrew/bin/ffmpeg")
        #expect(locator(executables: ["/usr/local/bin/ffmpeg"]).locate(configured: nil)?.path == "/usr/local/bin/ffmpeg")
    }

    @Test("Chemin réglé absent, relatif, ou qui ne répond pas à -version : les places habituelles ; rien : nil")
    func fallbacks() {
        let homebrew = locator(executables: ["/opt/homebrew/bin/ffmpeg", "/outils/ffmpeg"], responding: ["/opt/homebrew/bin/ffmpeg"])
        #expect(homebrew.locate(configured: "/outils/ffmpeg")?.path == "/opt/homebrew/bin/ffmpeg")
        #expect(homebrew.locate(configured: "/ailleurs/ffmpeg")?.path == "/opt/homebrew/bin/ffmpeg")
        #expect(homebrew.locate(configured: "ffmpeg")?.path == "/opt/homebrew/bin/ffmpeg")
        #expect(locator(executables: []).locate(configured: "/outils/ffmpeg") == nil)
        #expect(FFmpegLocator.installCommand == "brew install ffmpeg")
    }

    @Test("Vrais processus : /usr/bin/true répond (code 0), /usr/bin/false non")
    func realProbe() {
        let system = FFmpegLocator.system()
        #expect(system.locate(configured: "/usr/bin/true")?.path == "/usr/bin/true")
        #expect(system.locate(configured: "/usr/bin/false")?.path != "/usr/bin/false")
    }

    @Test("Choix par défaut : la première OBSBOT réelle, avant une OBSBOT virtuelle ; sans OBSBOT, rien")
    func preferred() {
        let devices = [
            CaptureDeviceInfo(name: "FaceTime HD Camera", isVirtual: false),
            CaptureDeviceInfo(name: "OBSBOT Virtual Camera", isVirtual: true),
            CaptureDeviceInfo(name: "OBSBOT Tiny 2 StreamCamera", isVirtual: false),
        ]
        #expect(CaptureDeviceChoice.preferred(in: devices) == "OBSBOT Tiny 2 StreamCamera")
        #expect(CaptureDeviceChoice.preferred(in: [devices[1]]) == "OBSBOT Virtual Camera")
        #expect(CaptureDeviceChoice.preferred(in: [devices[0]]) == nil)
        #expect(CaptureDeviceChoice.preferred(in: [CaptureDeviceInfo(name: "obsbot tiny2 microphone", isVirtual: false)]) == "obsbot tiny2 microphone")
    }

    @Test("Nom réglé : gardé s'il est branché, nil sinon ; sans nom réglé, le choix par défaut")
    func resolve() {
        let devices = [CaptureDeviceInfo(name: "OBSBOT Tiny 2 StreamCamera", isVirtual: false), CaptureDeviceInfo(name: "Autre", isVirtual: false)]
        #expect(CaptureDeviceChoice.resolve(configured: "Autre", in: devices) == "Autre")
        #expect(CaptureDeviceChoice.resolve(configured: "Débranchée", in: devices) == nil)
        #expect(CaptureDeviceChoice.resolve(configured: nil, in: devices) == "OBSBOT Tiny 2 StreamCamera")
        #expect(CaptureDeviceChoice.resolve(configured: "", in: devices) == "OBSBOT Tiny 2 StreamCamera")
    }

    @Test("Catalogue réel : la liste se lit sans demander d'autorisation, et sans planter")
    func realCatalog() {
        let catalog = AVFoundationDeviceCatalog()
        #expect(catalog.cameras().allSatisfy { !$0.name.isEmpty })
        #expect(catalog.microphones().allSatisfy { !$0.name.isEmpty })
    }
}
