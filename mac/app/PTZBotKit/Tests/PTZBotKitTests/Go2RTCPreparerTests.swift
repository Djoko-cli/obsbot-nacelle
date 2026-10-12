import Foundation
import Testing
@testable import PTZBotKit

@Suite("go2rtc : préparation du lancement et ports", .french)
struct Go2RTCPreparerTests {
    private func preparer(_ directory: URL, locator: FFmpegLocator = .homebrew, catalog: FakeCatalog = FakeCatalog(),
                          ports: FakePorts = FakePorts()) -> Go2RTCPreparer {
        Go2RTCPreparer(configURL: directory.appending(path: "go2rtc.yaml"), locator: locator, catalog: catalog, ports: ports)
    }

    @Test("Prêt : yaml écrit en mode 600 (vraie caméra, pas la virtuelle), ports vérifiés, dossier de ffmpeg pour le PATH")
    func ready() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ports = FakePorts()
        let result = await preparer(directory, ports: ports).prepare(Go2RTCFixtures.settings())
        guard case let .ready(launch) = result else {
            Issue.record("attendu : prêt, reçu \(result)")
            return
        }
        let config = directory.appending(path: "go2rtc.yaml")
        #expect(launch.config == config)
        #expect(launch.ffmpegDirectory?.path == "/opt/homebrew/bin")
        #expect(!launch.custom)
        let expected = try Go2RTCConfig.yaml(settings: Go2RTCFixtures.settings(), ffmpeg: Go2RTCFixtures.ffmpeg,
                                             camera: Go2RTCFixtures.camera, microphone: Go2RTCFixtures.microphone)
        #expect(try String(contentsOf: config, encoding: .utf8) == expected)
        #expect(try Go2RTCFixtures.permissions(config) == 0o600)
        #expect(ports.probed == ["8554/tcp", "8555/tcp", "8555/udp", "1984/tcp/127.0.0.1"])
    }

    @Test("Bloqué : ffmpeg introuvable, caméra ou micro absents, nom réglé débranché ; rien n'est écrit")
    func blocked() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = Go2RTCFixtures.settings()
        #expect(await preparer(directory, locator: .missing).prepare(settings) == .blocked(.ffmpegMissing))
        #expect(await preparer(directory, catalog: FakeCatalog(cameraList: [])).prepare(settings) == .blocked(.cameraMissing))
        #expect(await preparer(directory, catalog: FakeCatalog(microphoneList: [])).prepare(settings) == .blocked(.microphoneMissing))
        var unplugged = settings
        unplugged.cameraName = "Caméra débranchée"
        #expect(await preparer(directory).prepare(unplugged) == .blocked(.cameraMissing))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "go2rtc.yaml").path))
    }

    @Test("Port pris (un autre go2rtc) : bloqué sur ce port, en TCP comme en UDP, et pour l'API")
    func portBusy() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (key, port) in [("8554/tcp", 8554), ("8555/udp", 8555), ("1984/tcp/127.0.0.1", 1984)] {
            let ports = FakePorts()
            ports.busy(key)
            #expect(await preparer(directory, ports: ports).prepare(Go2RTCFixtures.settings()) == .blocked(.portBusy(port)))
        }
    }

    @Test("Réglage refusé par le yaml : bloqué, avec le message")
    func invalidSettings() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = Go2RTCFixtures.settings()
        settings.password = ""
        let message = Go2RTCConfigError.missingCredential.localizedDescription
        #expect(await preparer(directory).prepare(settings) == .blocked(.invalidSettings(message)))
    }

    @Test("Fichier personnalisé : lancé tel quel, sans yaml écrit ni port vérifié ; introuvable : bloqué")
    func customFile() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let custom = directory.appending(path: "perso.yaml")
        try Data("api:\n".utf8).write(to: custom)
        var settings = Go2RTCFixtures.settings()
        settings.customConfigEnabled = true
        settings.customConfigPath = custom.path
        let ports = FakePorts()
        let result = await preparer(directory, catalog: FakeCatalog(cameraList: []), ports: ports).prepare(settings)
        #expect(result == .ready(Go2RTCLaunch(config: URL(fileURLWithPath: custom.path), ffmpegDirectory: URL(fileURLWithPath: Go2RTCFixtures.ffmpeg).deletingLastPathComponent(), custom: true)))
        #expect(ports.probed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "go2rtc.yaml").path))
        settings.customConfigPath = directory.appending(path: "absent.yaml").path
        #expect(await preparer(directory).prepare(settings) == .blocked(.customFileMissing))
    }

    @Test("Appliquer go2rtc éteint : yaml écrit avec l'appareil réglé, même débranché ; ffmpeg absent : bloqué")
    func writeConfig() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = Go2RTCFixtures.settings()
        settings.cameraName = "Caméra débranchée"
        #expect(await preparer(directory).writeConfig(settings) == nil)
        let text = try String(contentsOf: directory.appending(path: "go2rtc.yaml"), encoding: .utf8)
        #expect(text.contains("-i \"Caméra débranchée\""))
        #expect(await preparer(directory, locator: .missing).writeConfig(settings) == .ffmpegMissing)
        settings.customConfigEnabled = true
        #expect(await preparer(directory, locator: .missing).writeConfig(settings) == nil)
    }

    @Test("Ports réels : un port tenu par une autre socket est pris, en TCP et en UDP ; refermée, il est libre")
    func realPorts() throws {
        let probe = SystemPortProbe()
        for (type, transport) in [(SOCK_STREAM, PortTransport.tcp), (SOCK_DGRAM, .udp)] {
            let descriptor = socket(AF_INET, type, 0)
            try #require(descriptor >= 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: 0)
            let bound = withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            try #require(bound == 0)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            var assigned = sockaddr_in()
            _ = withUnsafeMutablePointer(to: &assigned) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            let port = Int(UInt16(bigEndian: assigned.sin_port))
            if type == SOCK_STREAM {
                _ = listen(descriptor, 1)
            }
            #expect(!probe.isFree(port, transport: transport, loopbackOnly: false), "\(transport)")
            #expect(!probe.isFree(port, transport: transport, loopbackOnly: true), "\(transport)")
            close(descriptor)
            #expect(probe.isFree(port, transport: transport, loopbackOnly: false), "\(transport)")
        }
    }
}
