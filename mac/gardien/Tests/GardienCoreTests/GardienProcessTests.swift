import Foundation
import Testing
@testable import GardienCore

/// Le gardien compilé, lancé pour de vrai avec de petits processus (spec B3 § 10) : un `sleep` tient le rôle de
/// PTZBot, un shell celui de go2rtc. Le shell écrit son pid, puis devient `sleep` (en ignorant SIGTERM s'il le faut).
/// Toutes les attentes sont bornées.
@MainActor
@Suite("Gardien : vrais processus", .timeLimit(.minutes(1)))
struct GardienProcessTests {
    /// Construit par `swift build`, que la commande de vérification lance avant `swift test`. Il est à côté du paquet de
    /// tests (`<dossier de construction>/debug/gardien`, `--scratch-path` compris) ; `GARDIEN_EXECUTABLE` le remplace.
    static let executable: URL = {
        if let path = ProcessInfo.processInfo.environment["GARDIEN_EXECUTABLE"] {
            return URL(fileURLWithPath: path)
        }
        return Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent().appending(path: "gardien")
    }()

    static let sleeps = #"echo $$ > "$1"; exec /bin/sleep 60"#
    static let ignoresTerm = #"trap "" TERM; echo $$ > "$1"; exec /bin/sleep 60"#
    static let exitsSeven = #"echo $$ > "$1"; exit 7"#

    private func wait(_ limit: Duration, until condition: () -> Bool) async throws -> Bool {
        let start = ContinuousClock.now
        while !condition() {
            guard ContinuousClock.now - start < limit else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func launch(_ executable: URL, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Le parent : un `sleep` à tuer.
    private func launchParent() throws -> Process {
        try launch(URL(fileURLWithPath: "/bin/sleep"), ["60"])
    }

    /// Le gardien sur un shell qui écrit son pid dans le fichier rendu.
    /// `extra` : d'autres arguments pour le script, après le fichier du pid.
    private func launchGardien(parent: pid_t, stopDelay: String = "10", script: String, extra: [String] = []) throws -> (process: Process, pidFile: URL) {
        try #require(FileManager.default.isExecutableFile(atPath: Self.executable.path), "lancez `swift build` avant `swift test`")
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "gardien-\(UUID().uuidString).pid")
        let process = try launch(Self.executable, ["--parent", String(parent), "--arret", stopDelay, "--", "/bin/sh", "-c", script, "sh", pidFile.path] + extra)
        return (process, pidFile)
    }

    /// Le pid écrit par le programme, attendu 5 s au plus.
    private func childPID(_ file: URL) async throws -> pid_t {
        var pid: pid_t?
        _ = try await wait(.seconds(5)) {
            pid = (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return pid != nil
        }
        return try #require(pid, "le programme n'a pas écrit son pid")
    }

    /// Fin de test : tout ce qui vit encore est tué, le fichier du pid retiré.
    private func cleanUp(_ processes: [Process], child: pid_t?, pidFile: URL) {
        for process in processes where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        if let child, !Gardien.isGone(child) {
            kill(child, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    @Test("Parent disparu : SIGTERM au programme, qui s'arrête ; le gardien finit comme lui")
    func parentGone() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.sleeps)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        kill(parent.processIdentifier, SIGKILL)
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationReason == .uncaughtSignal)
        #expect(gardien.terminationStatus == SIGTERM)
    }

    @Test("Parent disparu, programme qui ignore SIGTERM : SIGKILL après --arret, pas avant")
    func stubbornChild() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, stopDelay: "2", script: Self.ignoresTerm)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        kill(parent.processIdentifier, SIGKILL)
        try await Task.sleep(for: .seconds(1))
        #expect(!Gardien.isGone(child), "encore là à 1 s : le délai est de 2 s")
        #expect(gardien.isRunning)
        #expect(try await wait(.seconds(5)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationReason == .uncaughtSignal)
        #expect(gardien.terminationStatus == SIGKILL)
    }

    @Test("SIGTERM au gardien : transmis au programme, qui s'arrête")
    func forwardsTerm() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.sleeps)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        gardien.terminate()
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationReason == .uncaughtSignal)
        #expect(gardien.terminationStatus == SIGTERM)
        #expect(parent.isRunning, "le parent n'est pas touché")
    }

    @Test("SIGINT au gardien : transmis au programme")
    func forwardsInt() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.sleeps)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        gardien.interrupt()
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationReason == .uncaughtSignal)
        #expect(gardien.terminationStatus == SIGINT)
    }

    @Test("SIGTERM ignoré par le programme : SIGKILL après --arret")
    func termThenKill() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, stopDelay: "1", script: Self.ignoresTerm)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        gardien.terminate()
        #expect(try await wait(.seconds(5)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationStatus == SIGKILL)
    }

    @Test("Le code de sortie du programme est rendu")
    func exitStatus() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.exitsSeven)
        defer { cleanUp([parent, gardien], child: nil, pidFile: pidFile) }
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(gardien.terminationReason == .exit)
        #expect(gardien.terminationStatus == 7)
    }

    @Test("Parent déjà disparu : rien n'est lancé, code 69")
    func parentAlreadyGone() async throws {
        // Un processus lancé puis attendu jusqu'au bout : son PID est libre.
        let finished = try launch(URL(fileURLWithPath: "/usr/bin/true"), [])
        finished.waitUntilExit()
        let (gardien, pidFile) = try launchGardien(parent: finished.processIdentifier, script: Self.sleeps)
        defer { cleanUp([gardien], child: nil, pidFile: pidFile) }
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(gardien.terminationStatus == GardienExit.parentGone)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path), "le programme n'a pas été lancé")
    }

    @Test("Programme introuvable : code 127 ; options refusées : code 64")
    func failures() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.executable.path), "lancez `swift build` avant `swift test`")
        let parent = try launchParent()
        defer { cleanUp([parent], child: nil, pidFile: URL(fileURLWithPath: "/dev/null/x")) }
        let missing = try launch(Self.executable, ["--parent", String(parent.processIdentifier), "--arret", "1", "--", "/chemin/introuvable/go2rtc"])
        let refused = try launch(Self.executable, ["--parent", "abc"])
        #expect(try await wait(.seconds(3)) { !missing.isRunning && !refused.isRunning })
        #expect(missing.terminationStatus == GardienExit.launchFailed)
        #expect(refused.terminationStatus == GardienExit.usage)
    }

    // MARK: - Enfants du programme (les ffmpeg de go2rtc)

    /// L'enfant du faux go2rtc : un shell qui note SIGTERM dans un fichier (`$1`), écrit son pid (`$2`) et continue
    /// (`$3` = "oui") ou s'arrête (autre valeur) ; un SIGKILL ne laisserait pas de note.
    static let notingChild = #"trap 'echo term > "$1"; [ "$3" = oui ] || exit 0' TERM; echo $$ > "$2"; while :; do /bin/sleep 0.2; done"#
    /// Le faux go2rtc : `$1` son pid, `$2` le pid de l'enfant, `$3` la note, `$4` le script de l'enfant, `$5` "oui" pour
    /// que l'enfant survive à SIGTERM. L'enfant est lancé par un sous-shell qui sort (il passe sous launchd, en restant
    /// dans le groupe du faux go2rtc), puis le faux go2rtc sort sur SIGTERM sans l'arrêter.
    static let sameGroupOrphan = #"""
    echo $$ > "$1"; ( /bin/sh -c "$4" sh "$3" "$2" "$5" & ); trap 'exit 0' TERM; while :; do /bin/sleep 0.2; done
    """#
    /// Comme `sameGroupOrphan`, mais l'enfant passe dans un autre groupe (go2rtc le permet) : seul le relevé de ses
    /// enfants, avant SIGTERM, le retrouve.
    static let otherGroupOrphan = #"""
    echo $$ > "$1"; /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV' /bin/sh -c "$4" sh "$3" "$2" "$5" & trap 'exit 0' TERM; while :; do /bin/sleep 0.2; done
    """#
    /// Le faux go2rtc sort de lui-même, sans signal, en laissant son enfant (dans son groupe).
    static let exitsAlone = #"""
    echo $$ > "$1"; ( /bin/sh -c "$4" sh "$3" "$2" "$5" & ); /bin/sleep 1; exit 0
    """#

    private struct Orphan {
        let gardien: Process
        let parent: Process
        let goPID: URL
        let childPID: URL
        let note: URL

        func cleanUp() {
            for process in [gardien, parent] where process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            for file in [goPID, childPID] {
                if let pid = (try? String(contentsOf: file, encoding: .utf8)).flatMap({ pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                    kill(pid, SIGKILL)
                }
                try? FileManager.default.removeItem(at: file)
            }
            try? FileManager.default.removeItem(at: note)
        }
    }

    /// Lance le gardien sur un faux go2rtc et attend que l'enfant ait écrit son pid.
    private func launchOrphan(script: String, childSurvives: Bool = false, stopDelay: String = "10") async throws -> (Orphan, childPID: pid_t) {
        let parent = try launchParent()
        let directory = FileManager.default.temporaryDirectory
        let childPIDFile = directory.appending(path: "gardien-\(UUID().uuidString).child")
        let note = directory.appending(path: "gardien-\(UUID().uuidString).note")
        let (gardien, goPID) = try launchGardien(parent: parent.processIdentifier, stopDelay: stopDelay, script: script,
                                                 extra: [childPIDFile.path, note.path, Self.notingChild, childSurvives ? "oui" : "non"])
        let orphan = Orphan(gardien: gardien, parent: parent, goPID: goPID, childPID: childPIDFile, note: note)
        let child = try await childPID(childPIDFile)
        return (orphan, child)
    }

    @Test("Le programme sort sur SIGTERM sans arrêter son enfant (même groupe) : l'enfant reçoit SIGTERM, pas SIGKILL")
    func sameGroupChildGetsTerm() async throws {
        let (orphan, child) = try await launchOrphan(script: Self.sameGroupOrphan, childSurvives: true)
        defer { orphan.cleanUp() }
        kill(orphan.gardien.processIdentifier, SIGTERM) // pas `terminate()` : il vise peut-être tout le groupe
        #expect(try await wait(.seconds(10)) { !orphan.gardien.isRunning })
        #expect(orphan.gardien.terminationReason == .exit)
        #expect(orphan.gardien.terminationStatus == 0, "la fin du programme est rendue")
        #expect(FileManager.default.fileExists(atPath: orphan.note.path), "l'enfant a reçu SIGTERM")
        #expect(!Gardien.isGone(child), "et pas SIGKILL : il a continué")
    }

    @Test("Enfant dans un autre groupe : retrouvé par le relevé fait avant SIGTERM, qui lui est transmis")
    func otherGroupChildGetsTerm() async throws {
        let (orphan, child) = try await launchOrphan(script: Self.otherGroupOrphan)
        defer { orphan.cleanUp() }
        let go = try await childPID(orphan.goPID)
        #expect(ProcessTable.identity(of: child)?.groupID == child, "l'enfant a son propre groupe")
        #expect(ProcessTable.identity(of: child)?.groupID != ProcessTable.identity(of: go)?.groupID)
        kill(orphan.gardien.processIdentifier, SIGTERM) // pas `terminate()` : il vise peut-être tout le groupe
        #expect(try await wait(.seconds(10)) { !orphan.gardien.isRunning })
        #expect(orphan.gardien.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: orphan.note.path), "l'enfant a reçu SIGTERM")
        #expect(try await wait(.seconds(3)) { Gardien.isGone(child) }, "et il s'est arrêté sur ce signal")
    }

    @Test("Le programme sort de lui-même en laissant son enfant dans son groupe : SIGTERM au groupe")
    func exitedAloneChildGetsTerm() async throws {
        let (orphan, child) = try await launchOrphan(script: Self.exitsAlone)
        defer { orphan.cleanUp() }
        #expect(try await wait(.seconds(10)) { !orphan.gardien.isRunning })
        #expect(orphan.gardien.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: orphan.note.path), "l'enfant a reçu SIGTERM")
        #expect(try await wait(.seconds(3)) { Gardien.isGone(child) })
    }

    @Test("Enfant qui ignore SIGTERM : jamais de SIGKILL, le gardien rend la main après 5 s environ")
    func stubbornChildKeepsLiving() async throws {
        let (orphan, child) = try await launchOrphan(script: Self.sameGroupOrphan, childSurvives: true)
        defer { orphan.cleanUp() }
        let start = ContinuousClock.now
        kill(orphan.gardien.processIdentifier, SIGTERM) // pas `terminate()` : il vise peut-être tout le groupe
        #expect(try await wait(.seconds(15)) { !orphan.gardien.isRunning })
        let elapsed = ContinuousClock.now - start
        #expect(elapsed > .seconds(4) && elapsed < .seconds(9), "attente bornée : \(elapsed)")
        #expect(orphan.gardien.terminationStatus == 0)
        #expect(!Gardien.isGone(child), "pas de SIGKILL")
    }

    @Test("Un faux go2rtc sans enfant : le gardien ne s'attarde pas")
    func noChildNoWait() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.sleeps)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        let start = ContinuousClock.now
        gardien.terminate()
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}

/// Pour retrouver le paquet de tests (`Bundle(for:)` veut une classe).
private final class BundleToken {}
