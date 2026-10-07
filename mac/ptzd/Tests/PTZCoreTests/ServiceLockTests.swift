import Foundation
import Testing
@testable import PTZCore

@Suite("Verrou de service (ptzd.lock)")
struct ServiceLockTests {
    @Test("Un seul détenteur ; libéré à la fin du premier ; descripteur fermé à l'exec")
    func exclusive() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ptzd-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "ptzd.lock")
        try holdOnce(url)
        // Le premier verrou est libéré à la fin de holdOnce : le suivant le prend. Un processus lancé au même
        // moment par un autre test peut tenir un instant une copie du descripteur, le temps de son exec :
        // nouvel essai pendant 2 s au plus.
        let deadline = Date() + 2
        while true {
            do {
                _ = try ServiceLock.acquire(at: url)
                return
            } catch .held where Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    /// Prend le verrou, vérifie qu'il est exclusif, puis le rend en sortant. Les valeurs vérifiées sont
    /// calculées hors de #expect, qui retiendrait sinon le verrou pour son diagnostic.
    private func holdOnce(_ url: URL) throws {
        let first = try ServiceLock.acquire(at: url)
        let flags = fcntl(first.descriptor, F_GETFD)
        #expect(flags & FD_CLOEXEC != 0)
        #expect(throws: ServiceLock.Failure.held) { try ServiceLock.acquire(at: url) }
    }
}

/// ptzd lui-même, lancé comme le ferait PTZBot, sur un dossier de travail temporaire.
@Suite("ptzd de bout en bout", .serialized)
struct DaemonEndToEndTests {
    /// Le binaire compilé par `swift test` à côté des tests.
    private static let binary = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/debug/ptzd")

    private func run(_ arguments: [String], support: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PTZD_SUPPORT_DIR": support.path]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date() + 10
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            Issue.record("ptzd ne s'est pas arrêté")
        }
        return process.terminationStatus
    }

    private func support() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ptzd-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("--parent d'un processus disparu : sortie 0 aussitôt")
    func deadParent() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path))
        let directory = try support()
        defer { try? FileManager.default.removeItem(at: directory) }
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        #expect(try run(["--parent", String(finished.processIdentifier)], support: directory) == 0)
    }

    @Test("Verrou ptzd.lock déjà tenu : sortie 75, avant de lire config.json")
    func lockHeld() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path))
        let directory = try support()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = try ServiceLock.acquire(at: directory.appending(path: "ptzd.lock"))
        #expect(try run(["--parent", String(getpid())], support: directory) == DaemonOptions.busyStatus)
        withExtendedLifetime(lock) {}
    }

    @Test("Option inconnue : sortie 64")
    func badOption() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path))
        let directory = try support()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try run(["--inconnue"], support: directory) == DaemonOptions.usageStatus)
    }
}
