import Foundation
import Testing
@testable import PTZBotKit

@Suite("go2rtc : import d'une configuration existante", .french)
struct Go2RTCImportTests {
    /// Une configuration écrite à la main, comme celles d'avant PTZBot : blocs `- >` à retrait croissant, commentaires,
    /// valeurs nues ou entre guillemets. Identifiants fictifs.
    static let handWritten = """
    # go2rtc de la maison
    api:
      listen: "127.0.0.1:1984"   # API locale
    rtsp:
      listen: ":8554"
      username: camera
      password: "secret-de-test"
    webrtc:
      listen: ":8555"
    ffmpeg:
      bin: /opt/homebrew/bin/ffmpeg   # chemin complet
    preload:
      obsbot:
    streams:
      obsbot:
        - >
          exec:/opt/homebrew/bin/ffmpeg -hide_banner -fflags nobuffer -flags low_delay
            -thread_queue_size 1024
            -f avfoundation -framerate 30 -video_size 1920x1080 -pixel_format nv12 -probesize 32M
            -i "OBSBOT Tiny 2 StreamCamera"
            -c:v h264_videotoolbox -an
            -rtsp_transport tcp -f rtsp {output}#timeout=30s#killsignal=15
        - >
          exec:/opt/homebrew/bin/ffmpeg -hide_banner
            -f avfoundation -i ":OBSBOT Tiny2 Microphone"
            -c:a aac -vn -rtsp_transport tcp -f rtsp {output}#killsignal=15
        - ffmpeg:obsbot#audio=opus
    """

    @Test("Configuration complète écrite à la main : tout est repris")
    func handWrittenFile() {
        #expect(Go2RTCConfigReader.read(Self.handWritten) == Go2RTCImport(
            username: "camera", password: "secret-de-test", rtspPort: 8554, webrtcPort: 8555,
            cameraName: "OBSBOT Tiny 2 StreamCamera", microphoneName: "OBSBOT Tiny2 Microphone",
            ffmpegPath: "/opt/homebrew/bin/ffmpeg"
        ))
    }

    @Test("Le yaml que PTZBot écrit se relit à l'identique, échappements compris")
    func roundTrip() throws {
        var settings = Go2RTCFixtures.settings()
        settings.password = #"a"b\c d#e"#
        settings.rtspPort = 9554
        let text = try Go2RTCConfig.yaml(settings: settings, ffmpeg: Go2RTCFixtures.ffmpeg, camera: #"Caméra "A""#, microphone: "Micro d'Anne")
        #expect(Go2RTCConfigReader.read(text) == Go2RTCImport(
            username: "ptzbot", password: #"a"b\c d#e"#, rtspPort: 9554, webrtcPort: 8555,
            cameraName: #"Caméra "A""#, microphoneName: "Micro d'Anne", ffmpegPath: Go2RTCFixtures.ffmpeg
        ))
    }

    @Test("Configuration partielle : seul ce qui est là est repris ; ffmpeg lu dans exec: sans section ffmpeg")
    func partial() {
        #expect(Go2RTCConfigReader.read("rtsp:\n  listen: \"0.0.0.0:9554\"\n") == Go2RTCImport(rtspPort: 9554))
        let execOnly = "streams:\n  cam:\n    - exec:/usr/local/bin/ffmpeg -f avfoundation -i 0 -f rtsp {output}\n"
        #expect(Go2RTCConfigReader.read(execOnly) == Go2RTCImport(ffmpegPath: "/usr/local/bin/ffmpeg"))
    }

    @Test("Commentaires et guillemets : # dans une valeur entre guillemets, '' dans des simples, commentaire après une valeur nue")
    func quotingAndComments() {
        let text = """
        rtsp:
        #  password: ancien
          username: 'l''admin'
          password: "a#b\\"c"   # entre guillemets
        webrtc:
          listen: :8555 # nu
        """
        #expect(Go2RTCConfigReader.read(text) == Go2RTCImport(username: "l'admin", password: #"a#b"c"#, webrtcPort: 8555))
    }

    @Test("Appareils : « caméra:micro » d'une seule entrée ; un numéro n'est pas un nom")
    func devices() {
        let combined = "streams:\n  s:\n    - exec:ffmpeg -f avfoundation -i \"Caméra:Micro\" -f rtsp {output}\n"
        #expect(Go2RTCConfigReader.read(combined).cameraName == "Caméra")
        #expect(Go2RTCConfigReader.read(combined).microphoneName == "Micro")
        let indexes = "streams:\n  s:\n    - exec:ffmpeg -f avfoundation -i 0:1 -f rtsp {output}\n"
        #expect(Go2RTCConfigReader.read(indexes).cameraName == nil)
        #expect(Go2RTCConfigReader.read(indexes).microphoneName == nil)
    }

    @Test("Illisible : fichier absent, texte sans rien de reconnu, données binaires")
    func unreadable() throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "absent.yaml")
        #expect(throws: Go2RTCImportError.self) { try Go2RTCConfigReader.read(contentsOf: missing) }
        do {
            _ = try Go2RTCConfigReader.read(contentsOf: missing)
        } catch {
            guard case .unreadable = error else {
                Issue.record("attendu : unreadable, reçu \(error)")
                return
            }
        }
        let text = directory.appending(path: "texte.yaml")
        try Data("bonjour\nle monde: oui\n".utf8).write(to: text)
        #expect(throws: Go2RTCImportError.nothingRecognized) { try Go2RTCConfigReader.read(contentsOf: text) }
        let binary = directory.appending(path: "binaire.yaml")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: binary)
        #expect(throws: Go2RTCImportError.nothingRecognized) { try Go2RTCConfigReader.read(contentsOf: binary) }
    }

    @Test("Appliqué aux réglages : ce qui est repris remplace, le reste est gardé, le fichier personnalisé est coupé")
    func applied() {
        var settings = Go2RTCFixtures.settings()
        settings.framerate = 25
        settings.customConfigEnabled = true
        settings.customConfigPath = "/support/perso.yaml"
        let result = Go2RTCImport(username: "camera", rtspPort: 9554, cameraName: "Autre caméra").applied(to: settings)
        #expect(result.username == "camera")
        #expect(result.password == Go2RTCFixtures.password)
        #expect(result.rtspPort == 9554)
        #expect(result.cameraName == "Autre caméra")
        #expect(result.framerate == 25)
        #expect(!result.customConfigEnabled)
    }

    @MainActor
    @Test("Au lancement : le mot de passe relu du yaml ; sans yaml, un mot de passe neuf")
    func restore() throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appending(path: "go2rtc.yaml")
        let store = FakeSettings()
        var saved = Go2RTCFixtures.settings()
        saved.framerate = 15
        saved.save(to: store)
        let fresh = Go2RTCSettings.restore(from: store, config: config)
        #expect(fresh.password.count == 20)
        #expect(fresh.framerate == 15)
        try Go2RTCConfigFile.write(try Go2RTCConfig.yaml(settings: saved, ffmpeg: Go2RTCFixtures.ffmpeg, camera: Go2RTCFixtures.camera, microphone: Go2RTCFixtures.microphone), to: config)
        #expect(Go2RTCSettings.restore(from: store, config: config) == saved)
    }

    @Test("Messages d'erreur de l'import en français et en anglais")
    func messages() {
        for error in [Go2RTCImportError.unreadable("x"), .nothingRecognized] {
            let french = Localization.$languageOverride.withValue("fr") { error.localizedDescription }
            let english = Localization.$languageOverride.withValue("en") { error.localizedDescription }
            #expect(french != english)
        }
    }
}
