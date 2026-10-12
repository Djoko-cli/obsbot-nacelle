import Foundation
import Testing
@testable import GardienCore

@Suite("Options du gardien")
struct GardienOptionsTests {
    @Test("--parent et --arret dans n'importe quel ordre, puis -- et le programme avec ses arguments")
    func valid() throws {
        let options = try GardienOptions.parse(["--parent", "4242", "--arret", "10", "--", "/app/Helpers/go2rtc", "-config", "/support/go2rtc.yaml"])
        #expect(options == GardienOptions(parent: 4242, stopDelay: 10, program: "/app/Helpers/go2rtc", arguments: ["-config", "/support/go2rtc.yaml"]))
        let reordered = try GardienOptions.parse(["--arret", "0.5", "--parent", "7", "--", "/bin/sleep"])
        #expect(reordered == GardienOptions(parent: 7, stopDelay: 0.5, program: "/bin/sleep", arguments: []))
    }

    @Test("Après --, tout est au programme, même ce qui ressemble à une option")
    func passThrough() throws {
        let options = try GardienOptions.parse(["--parent", "1", "--arret", "1", "--", "/bin/echo", "--parent", "--", "-config"])
        #expect(options.arguments == ["--parent", "--", "-config"])
    }

    @Test("Refus : option inconnue, valeur manquante ou mal formée, option en double ou manquante, programme manquant ou relatif")
    func invalid() {
        #expect(throws: GardienOptions.ParseError.unknownOption("--verbose")) { try GardienOptions.parse(["--verbose"]) }
        #expect(throws: GardienOptions.ParseError.missingValue("--parent")) { try GardienOptions.parse(["--parent"]) }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--parent", value: "abc")) {
            try GardienOptions.parse(["--parent", "abc", "--arret", "1", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--parent", value: "0")) {
            try GardienOptions.parse(["--parent", "0", "--arret", "1", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--arret", value: "-1")) {
            try GardienOptions.parse(["--parent", "1", "--arret", "-1", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--arret", value: "nan")) {
            try GardienOptions.parse(["--parent", "1", "--arret", "nan", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--arret", value: "301")) {
            try GardienOptions.parse(["--parent", "1", "--arret", "301", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.duplicate("--parent")) {
            try GardienOptions.parse(["--parent", "1", "--parent", "2", "--arret", "1", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.missingOption("--arret")) { try GardienOptions.parse(["--parent", "1", "--", "/bin/sleep"]) }
        #expect(throws: GardienOptions.ParseError.missingOption("--parent")) { try GardienOptions.parse(["--arret", "1", "--", "/bin/sleep"]) }
        #expect(throws: GardienOptions.ParseError.missingProgram) { try GardienOptions.parse(["--parent", "1", "--arret", "1", "--"]) }
        #expect(throws: GardienOptions.ParseError.missingProgram) { try GardienOptions.parse(["--parent", "1", "--arret", "1"]) }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--", value: "go2rtc")) {
            try GardienOptions.parse(["--parent", "1", "--arret", "1", "--", "go2rtc"])
        }
    }
}

@Suite("Fin du programme")
struct ChildEndTests {
    @Test("Statut de waitpid : sortie normale avec son code, ou signal (core écrit ou non)")
    func decode() {
        #expect(ChildEnd(waitStatus: 0) == .exited(0))
        #expect(ChildEnd(waitStatus: 7 << 8) == .exited(7))
        #expect(ChildEnd(waitStatus: SIGTERM) == .signaled(SIGTERM))
        #expect(ChildEnd(waitStatus: SIGKILL) == .signaled(SIGKILL))
        #expect(ChildEnd(waitStatus: SIGSEGV | 0x80) == .signaled(SIGSEGV))
    }
}
