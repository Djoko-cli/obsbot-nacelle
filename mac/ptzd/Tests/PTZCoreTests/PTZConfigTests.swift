import Foundation
import Testing
@testable import PTZCore

@Suite("config.json")
struct PTZConfigTests {
    private func decode(_ json: String) throws -> PTZConfig {
        let config = try JSONDecoder().decode(PTZConfig.self, from: Data(json.utf8))
        try config.validate()
        return config
    }

    @Test("Seule listenAddress est obligatoire ; le reste a ses valeurs par défaut")
    func defaults() throws {
        let config = try decode(#"{"listenAddress":"127.0.0.1"}"#)
        #expect(config == PTZConfig(listenAddress: "127.0.0.1"))
        #expect(config.port == 1985)
        #expect(config.motion == MotionSettings(panMaxSpeed: 40, tiltMaxSpeed: 60, panDirection: 1, tiltDirection: 1))
    }

    @Test("listenAddress absente ou invalide")
    func listenAddress() {
        #expect(throws: ConfigError.missingListenAddress) { try decode("{}") }
        #expect(throws: ConfigError.invalidListenAddress("mac.local")) {
            try decode(#"{"listenAddress":"mac.local"}"#)
        }
    }

    @Test("listenAddress : 127.0.0.1 ou plage Tailscale 100.64.0.0/10 seulement")
    func listenAddressRange() throws {
        for refused in ["0.0.0.0", "192.168.1.10", "100.128.0.1", "100.63.255.255", "127.0.0.2"] {
            #expect(throws: ConfigError.invalidListenAddress(refused)) {
                try decode(#"{"listenAddress":"\#(refused)"}"#)
            }
        }
        for accepted in ["127.0.0.1", "100.64.0.1", "100.127.255.254"] {
            #expect(try decode(#"{"listenAddress":"\#(accepted)"}"#).listenAddress == accepted)
        }
    }

    @Test("Bornes des vitesses et des sens")
    func ranges() {
        #expect(throws: ConfigError.outOfRange("panMaxSpeed")) {
            try decode(#"{"listenAddress":"127.0.0.1","panMaxSpeed":81}"#)
        }
        #expect(throws: ConfigError.outOfRange("tiltMaxSpeed")) {
            try decode(#"{"listenAddress":"127.0.0.1","tiltMaxSpeed":0}"#)
        }
        #expect(throws: ConfigError.outOfRange("tiltDirection")) {
            try decode(#"{"listenAddress":"127.0.0.1","tiltDirection":0}"#)
        }
    }

    @Test("go2rtc : API locale et flux par défaut, ou donnés")
    func go2rtc() throws {
        let defaults = try decode(#"{"listenAddress":"127.0.0.1"}"#)
        #expect(defaults.go2rtcAPI == "http://127.0.0.1:1984")
        #expect(defaults.streamName == "obsbot")
        let custom = try decode(#"{"listenAddress":"127.0.0.1","go2rtcAPI":"http://localhost:2984","streamName":"cam"}"#)
        #expect(custom.go2rtcAPI == "http://localhost:2984")
        #expect(custom.streamName == "cam")
    }

    @Test("go2rtcAPI : boucle locale en http avec un port, sans chemin ; flux non vide")
    func go2rtcValidation() {
        for refused in ["http://192.168.1.10:1984", "https://127.0.0.1:1984", "http://127.0.0.1", "http://127.0.0.1:1984/api", "pas une url"] {
            #expect(throws: ConfigError.invalidGo2rtcAPI(refused)) {
                try decode(#"{"listenAddress":"127.0.0.1","go2rtcAPI":"\#(refused)"}"#)
            }
        }
        #expect(throws: ConfigError.outOfRange("streamName")) {
            try decode(#"{"listenAddress":"127.0.0.1","streamName":" "}"#)
        }
    }

    @Test("Chemin de obsbot-ai-off : relatif au dossier de travail, ou absolu")
    func aiOffURL() {
        let base = URL(fileURLWithPath: "/tmp/ObsbotNacelle")
        #expect(PTZConfig(listenAddress: "127.0.0.1").aiOffURL(relativeTo: base).path == "/tmp/ObsbotNacelle/bin/obsbot-ai-off")
        #expect(PTZConfig(listenAddress: "127.0.0.1", aiOffPath: "/opt/x").aiOffURL(relativeTo: base).path == "/opt/x")
    }
}
