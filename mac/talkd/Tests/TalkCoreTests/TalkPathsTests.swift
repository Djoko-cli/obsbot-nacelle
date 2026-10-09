import Foundation
import Testing
@testable import TalkCore

@Suite("Emplacements de talkd")
struct TalkPathsTests {
    private let home = URL(fileURLWithPath: "/home-test", isDirectory: true)

    @Test("Par défaut : Application Support/ObsbotNacelle pour les réglages et l'état, Logs/obsbot-nacelle pour le journal")
    func defaults() {
        let paths = TalkPaths(environment: [:], home: home)
        #expect(paths.support.path == "/home-test/Library/Application Support/ObsbotNacelle")
        #expect(paths.settings.path == "/home-test/Library/Application Support/ObsbotNacelle/talkd.json")
        #expect(paths.state.path == "/home-test/Library/Application Support/ObsbotNacelle/talkd-state.json")
        #expect(paths.journal.path == "/home-test/Library/Logs/obsbot-nacelle/talkd.log")
    }

    @Test("TALKD_SUPPORT_DIR remplace le dossier de travail, et le journal va dans son sous-dossier logs (comme PTZD_SUPPORT_DIR)")
    func override() {
        let paths = TalkPaths(environment: ["TALKD_SUPPORT_DIR": "/tmp-test/talkd"], home: home)
        #expect(paths.settings.path == "/tmp-test/talkd/talkd.json")
        #expect(paths.state.path == "/tmp-test/talkd/talkd-state.json")
        #expect(paths.volumeRecovery.path == "/tmp-test/talkd/talkd-volume.json")
        #expect(paths.journal.path == "/tmp-test/talkd/logs/talkd.log")
    }

    @Test("Variable vide : ignorée")
    func emptyOverride() {
        let paths = TalkPaths(environment: ["TALKD_SUPPORT_DIR": ""], home: home)
        #expect(paths.support.path == "/home-test/Library/Application Support/ObsbotNacelle")
    }

    @Test("Codes de sortie : port occupé 75 (comme ptzd), option inconnue 64")
    func exitCodes() {
        #expect(TalkExit.busy == 75)
        #expect(TalkExit.usage == 64)
        #expect(TalkExit.usageText.contains("talkd"))
    }
}
