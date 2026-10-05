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

    @Test("Chemin de obsbot-ai-off : relatif au dossier de travail, ou absolu")
    func aiOffURL() {
        let base = URL(fileURLWithPath: "/tmp/ObsbotNacelle")
        #expect(PTZConfig(listenAddress: "127.0.0.1").aiOffURL(relativeTo: base).path == "/tmp/ObsbotNacelle/bin/obsbot-ai-off")
        #expect(PTZConfig(listenAddress: "127.0.0.1", aiOffPath: "/opt/x").aiOffURL(relativeTo: base).path == "/opt/x")
    }
}
