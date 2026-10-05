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
