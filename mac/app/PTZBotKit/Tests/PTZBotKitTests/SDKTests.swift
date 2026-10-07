import Foundation
import Synchronization
import Testing
@testable import PTZBotKit

/// Faux fichiers Mach-O et dossiers temporaires pour les tests du SDK.
enum FakeSDK {
    static let arm64: UInt32 = 0x0100_000C
    static let x86_64: UInt32 = 0x0100_0007

    /// En-tête Mach-O 64 bits fin, petit-boutiste ; `fileType` 6 : bibliothèque dynamique.
    static func thin(_ cpu: UInt32, fileType: UInt32 = 6, filler: UInt8 = 0) -> Data {
        var data = Data()
        for value in [0xFEED_FACF, cpu, 0, fileType, 0, 0, 0, 0] as [UInt32] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data + Data(repeating: filler, count: 32)
    }

    /// Binaire universel : en-tête gros-boutiste, tranches alignées sur 4096.
    static func fat(_ cpus: [UInt32]) -> Data {
        var data = Data()
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        append(0xCAFE_BABE)
        append(UInt32(cpus.count))
        let slices = cpus.map { thin($0) }
        for (index, cpu) in cpus.enumerated() {
            append(cpu)
            append(0)
            append(UInt32(4096 * (index + 1)))
            append(UInt32(slices[index].count))
            append(12)
        }
        for (index, slice) in slices.enumerated() {
            data.append(Data(repeating: 0, count: 4096 * (index + 1) - data.count))
            data.append(slice)
        }
        return data
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ptzbot-sdk-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func write(_ data: Data, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    static let quarantine = "0083;6a000000;Safari;00000000-0000-4000-8000-000000000000"

    static func setQuarantine(_ url: URL) {
        _ = quarantine.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }

    static func setWhereFroms(_ url: URL, _ list: [String]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        _ = data.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, data.count, 0, 0) }
    }

    static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }
}

@Suite("SDK : examen du fichier choisi")
struct SDKInspectorTests {
    @Test("En-têtes Mach-O : arm64 fin, x86_64 fin, universel, pas une bibliothèque, n'importe quoi")
    func machO() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func architectures(_ data: Data) throws -> [String]? {
            MachO.architectures(of: try FakeSDK.write(data, to: directory.appending(path: UUID().uuidString)))
        }
        #expect(try architectures(FakeSDK.thin(FakeSDK.arm64)) == ["arm64"])
        #expect(try architectures(FakeSDK.thin(FakeSDK.x86_64)) == ["x86_64"])
        #expect(try architectures(FakeSDK.fat([FakeSDK.x86_64, FakeSDK.arm64])) == ["x86_64", "arm64"])
        #expect(try architectures(FakeSDK.thin(FakeSDK.arm64, fileType: 2)) == nil)
        #expect(try architectures(Data("pas une bibliothèque, vraiment pas".utf8)) == nil)
        #expect(try architectures(Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52])) == nil)
        #expect(try architectures(Data()) == nil)
    }

    @Test("Bibliothèque directe : architectures, non signée, sans quarantaine ni provenance")
    func directLibrary() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try FakeSDK.write(FakeSDK.fat([FakeSDK.arm64, FakeSDK.x86_64]), to: directory.appending(path: "libdev.dylib"))
        let candidate = try SDKInspector.inspect(library)
        #expect(candidate.path == library)
        #expect(candidate.architectures == ["arm64", "x86_64"])
        #expect(candidate.isArm64)
        #expect(candidate.signer == nil)
        #expect(candidate.team == nil)
        #expect(!candidate.quarantined)
        #expect(candidate.origin == nil)
        #expect(candidate.temporaryDirectory == nil)
    }

    @Test("Refus : introuvable, pas Mach-O, sans tranche arm64 ; motifs en clair")
    func rejections() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: SDKRejection.notFound) { try SDKInspector.inspect(directory.appending(path: "absent.dylib")) }
        #expect(throws: SDKRejection.notFound) { try SDKInspector.inspect(directory) }
        let text = try FakeSDK.write(Data("texte".utf8), to: directory.appending(path: "libdev.dylib"))
        #expect(throws: SDKRejection.notMachO) { try SDKInspector.inspect(text) }
        let intel = try FakeSDK.write(FakeSDK.thin(FakeSDK.x86_64), to: directory.appending(path: "intel.dylib"))
        #expect(throws: SDKRejection.noArm64(architectures: ["x86_64"])) { try SDKInspector.inspect(intel) }
        #expect(SDKRejection.notMachO.message == "Ce fichier n'est pas une bibliothèque Mach-O.")
        #expect(SDKRejection.notRegularFile.message.hasPrefix("libdev.dylib n'est pas un fichier ordinaire"))
        #expect(SDKRejection.noArm64(architectures: ["x86_64"]).message == "Ce SDK n'a pas de version pour Apple Silicon (x86_64).")
    }

    @Test("Dossier décompressé : macos/arm64-release/libdev.dylib le moins profond, quarantaine et provenance lues")
    func folder() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "libdev_v9")
        let library = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: root.appending(path: "macos/arm64-release/libdev.dylib"))
        // Leurre plus profond, sans arm64 : choisi par erreur, il serait refusé.
        try FakeSDK.write(FakeSDK.thin(FakeSDK.x86_64), to: root.appending(path: "macos/macos/arm64-release/libdev.dylib"))
        FakeSDK.setQuarantine(library)
        try FakeSDK.setWhereFroms(library, ["https://example.com/libdev_v9.zip", "https://example.com/"])
        let candidate = try SDKInspector.inspect(directory)
        #expect(candidate.path.resolvingSymlinksInPath() == library.resolvingSymlinksInPath())
        #expect(candidate.quarantined)
        #expect(candidate.origin == SDKOrigin(url: "https://example.com/libdev_v9.zip", date: Date(timeIntervalSince1970: 0x6A00_0000)))
        #expect(candidate.otherCopies == ["macos/macos/arm64-release/libdev.dylib"])
        #expect(try SDKInspector.inspect(root).path.resolvingSymlinksInPath() == library.resolvingSymlinksInPath())
    }

    @Test("Choix : seulement macos/arm64-release/libdev.dylib, sous le dossier ou son dossier de tête ; recherche des copies bornée")
    func selectionRule() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Seule une copie plus profonde : ce n'est pas le chemin que la compilation lie.
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "libdev_v9/macos/macos/arm64-release/libdev.dylib"))
        #expect(throws: SDKRejection.notFound) { try SDKInspector.inspect(directory) }
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "libdev_v9/macos/arm64-release/libdev.dylib"))
        try FakeSDK.write(FakeSDK.thin(FakeSDK.x86_64), to: directory.appending(path: "libdev_v9/macos/x86_64-release/libdev.dylib"))
        // Ignorées : dossier caché, paquet, au-delà de 5 niveaux.
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "libdev_v9/.cache/libdev.dylib"))
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "libdev_v9/Exemple.app/Contents/libdev.dylib"))
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "libdev_v9/a/b/c/d/e/libdev.dylib"))
        let candidate = try SDKInspector.inspect(directory)
        #expect(candidate.path.path.hasSuffix("libdev_v9/macos/arm64-release/libdev.dylib"))
        #expect(candidate.otherCopies == ["macos/macos/arm64-release/libdev.dylib", "macos/x86_64-release/libdev.dylib"])
    }

    @Test("Lien symbolique vers une bibliothèque, dans un dossier ou dans une archive : refusé")
    func symlinkRejected() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "libdev_v9")
        let real = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: root.appending(path: "vraie.dylib"))
        let link = root.appending(path: "macos/arm64-release/libdev.dylib")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../vraie.dylib")
        #expect(throws: SDKRejection.notRegularFile) { try SDKInspector.inspect(directory) }
        #expect(throws: SDKRejection.notRegularFile) { try SDKInspector.inspect(link) }
        #expect(try SDKInspector.inspect(real).isArm64)

        let archive = directory.appending(path: "lien.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", root.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        try #require(ditto.terminationStatus == 0)
        #expect(throws: SDKRejection.notRegularFile) { try SDKInspector.inspect(archive) }
    }

    @Test("Archive .zip : décompressée par ditto, provenance de l'archive, dossier temporaire effacé ensuite")
    func zip() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "libdev_v9")
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: root.appending(path: "macos/arm64-release/libdev.dylib"))
        try FakeSDK.write(Data("en-tête".utf8), to: root.appending(path: "include/dev/devs.hpp"))
        let archive = directory.appending(path: "libdev_v9.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", root.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        try #require(ditto.terminationStatus == 0)
        FakeSDK.setQuarantine(archive)
        try FakeSDK.setWhereFroms(archive, ["https://example.com/libdev_v9.zip"])

        let candidate = try SDKInspector.inspect(archive)
        let temporary = try #require(candidate.temporaryDirectory)
        #expect(candidate.path.path.hasSuffix("libdev_v9/macos/arm64-release/libdev.dylib"))
        #expect(candidate.path.resolvingSymlinksInPath().path.hasPrefix(temporary.resolvingSymlinksInPath().path))
        #expect(candidate.architectures == ["arm64"])
        #expect(candidate.quarantined)
        #expect(candidate.origin?.url == "https://example.com/libdev_v9.zip")
        #expect(FakeSDK.isQuarantined(archive))
        SDKInspector.discard(candidate)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))

        let empty = directory.appending(path: "vide.zip")
        try FakeSDK.write(Data("PK pas une archive".utf8), to: empty)
        #expect(throws: SDKRejection.self) { try SDKInspector.inspect(empty) }
    }

    @Test("Signature : signataire et équipe d'un binaire signé ; date de quarantaine")
    func signing() {
        #expect(SDKInspector.signing(of: URL(fileURLWithPath: "/bin/ls")).signer != nil)
        #expect(SDKInspector.quarantineDate("0083;6a000000;Safari;x") == Date(timeIntervalSince1970: 0x6A00_0000))
        #expect(SDKInspector.quarantineDate("0083") == nil)
    }
}

/// Vérificateur simulé : réponse choisie, appels retenus.
final class FakeVerifier: Sendable {
    let answer: Mutex<Bool>
    let calls = Mutex<[URL]>([])

    init(_ answer: Bool) {
        self.answer = Mutex(answer)
    }

    var verifier: SDKVerifier {
        { [self] directory in
            calls.withLock { $0.append(directory) }
            return answer.withLock { $0 }
        }
    }
}

@Suite("SDK : installation")
struct SDKInstallerTests {
    let directory: URL
    let sdk: URL

    init() throws {
        directory = try FakeSDK.directory()
        sdk = directory.appending(path: "support/sdk")
    }

    private func candidate(_ data: Data = FakeSDK.thin(FakeSDK.arm64, filler: 1), quarantined: Bool = true) throws -> SDKCandidate {
        let url = try FakeSDK.write(data, to: directory.appending(path: "choix-\(UUID().uuidString)/libdev.dylib"))
        if quarantined {
            FakeSDK.setQuarantine(url)
        }
        return try SDKInspector.inspect(url)
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: sdk.path).filter { $0 != "libdev.dylib" }.sorted()
    }

    @Test("Copie autorisée : quarantaine retirée de la copie seulement, vérifiée par obsbot-ai, rien de laissé")
    func install() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let verifier = FakeVerifier(true)
        let installer = SDKInstaller(sdkDirectory: sdk, verifier: verifier.verifier)
        let chosen = try candidate()
        try installer.install(chosen)
        #expect(try Data(contentsOf: installer.libraryURL) == Data(contentsOf: chosen.path))
        #expect(!FakeSDK.isQuarantined(installer.libraryURL))
        #expect(FakeSDK.isQuarantined(chosen.path))
        #expect(verifier.calls.withLock { $0 } == [sdk])
        #expect(try leftovers().isEmpty)
        #expect(installer.status() == .ready)
    }

    @Test("Remplacement : le nouveau SDK prend la place de l'ancien")
    func replace() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = SDKInstaller(sdkDirectory: sdk, verifier: FakeVerifier(true).verifier)
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 7), to: installer.libraryURL)
        let chosen = try candidate()
        try installer.install(chosen)
        #expect(try Data(contentsOf: installer.libraryURL) == Data(contentsOf: chosen.path))
        #expect(try leftovers().isEmpty)
    }

    @Test("Vérification en échec : l'ancien SDK est remis, .new et la sauvegarde effacés")
    func keepsOldOnFailure() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = SDKInstaller(sdkDirectory: sdk, verifier: FakeVerifier(false).verifier)
        let old = FakeSDK.thin(FakeSDK.arm64, filler: 7)
        try FakeSDK.write(old, to: installer.libraryURL)
        #expect(throws: SDKInstallError.unloadable) { try installer.install(try candidate()) }
        #expect(try Data(contentsOf: installer.libraryURL) == old)
        #expect(try leftovers().isEmpty)
    }

    @Test("Vérification en échec sans ancien SDK : rien n'est laissé")
    func failureWithoutOld() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = SDKInstaller(sdkDirectory: sdk, verifier: FakeVerifier(false).verifier)
        #expect(throws: SDKInstallError.unloadable) { try installer.install(try candidate()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: sdk.path).isEmpty)
    }

    @Test("Copie impossible ou SDK sans arm64 : l'ancien est conservé")
    func copyFailure() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let verifier = FakeVerifier(true)
        let installer = SDKInstaller(sdkDirectory: sdk, verifier: verifier.verifier)
        let old = FakeSDK.thin(FakeSDK.arm64, filler: 7)
        try FakeSDK.write(old, to: installer.libraryURL)
        var vanished = try candidate()
        try FileManager.default.removeItem(at: vanished.path)
        #expect(throws: SDKInstallError.self) { try installer.install(vanished) }
        vanished.architectures = ["x86_64"]
        #expect(throws: SDKInstallError.incompatible) { try installer.install(vanished) }
        #expect(try Data(contentsOf: installer.libraryURL) == old)
        #expect(try leftovers().isEmpty)
        #expect(verifier.calls.withLock { $0 }.isEmpty)
    }

    @Test("Candidat devenu un lien symbolique entre l'examen et l'installation : refusé, l'ancien gardé")
    func symlinkAtInstall() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let verifier = FakeVerifier(true)
        let installer = SDKInstaller(sdkDirectory: sdk, verifier: verifier.verifier)
        let old = FakeSDK.thin(FakeSDK.arm64, filler: 7)
        try FakeSDK.write(old, to: installer.libraryURL)
        let chosen = try candidate(quarantined: false)
        let real = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 2), to: directory.appending(path: "ailleurs.dylib"))
        try FileManager.default.removeItem(at: chosen.path)
        try FileManager.default.createSymbolicLink(at: chosen.path, withDestinationURL: real)
        #expect(throws: SDKInstallError.copyFailed("la copie n'est pas une bibliothèque arm64 ordinaire.")) { try installer.install(chosen) }
        #expect(try Data(contentsOf: installer.libraryURL) == old)
        #expect(try leftovers().isEmpty)
        #expect(verifier.calls.withLock { $0 }.isEmpty)
    }

    @Test("Installation interrompue (libdev.dylib.old restant) : l'ancien SDK est remis par status() et par install()")
    func staleBackup() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = SDKInstaller(sdkDirectory: sdk, verifier: FakeVerifier(false).verifier)
        let old = FakeSDK.thin(FakeSDK.arm64, filler: 7)
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 9), to: installer.libraryURL)
        try FakeSDK.write(old, to: installer.backupURL)
        _ = installer.status()
        #expect(try Data(contentsOf: installer.libraryURL) == old)
        #expect(try leftovers().isEmpty)

        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 9), to: installer.libraryURL)
        try FakeSDK.write(old, to: installer.backupURL)
        #expect(throws: SDKInstallError.unloadable) { try installer.install(try candidate()) }
        #expect(try Data(contentsOf: installer.libraryURL) == old)
        #expect(try leftovers().isEmpty)
    }

    @Test("status() pendant une installation : la sauvegarde .old n'est pas reprise ; une seconde installation est refusée")
    func statusDuringInstall() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = Mutex<SDKInstaller?>(nil)
        let seen = Mutex<(installing: Bool, backupKept: Bool, second: SDKInstallError?)?>(nil)
        let old = FakeSDK.thin(FakeSDK.arm64, filler: 7)
        let next = try candidate()
        // La vérification d'obsbot-ai est le moment où `.old` existe : le panneau demande l'état à cet instant.
        let installer = SDKInstaller(sdkDirectory: sdk) { _ in
            guard let installer = box.withLock({ $0 }), seen.withLock({ $0 }) == nil else { return true }
            seen.withLock { $0 = (installer.isInstalling, false, nil) }
            _ = installer.status()
            var second: SDKInstallError?
            do {
                try installer.install(next)
            } catch let error as SDKInstallError {
                second = error
            } catch {}
            let kept = FileManager.default.fileExists(atPath: installer.backupURL.path)
            seen.withLock { $0 = ($0?.installing ?? false, kept, second) }
            return true
        }
        box.withLock { $0 = installer }
        try FakeSDK.write(old, to: installer.libraryURL)
        try installer.install(try candidate(FakeSDK.thin(FakeSDK.arm64, filler: 3)))
        let observed = try #require(seen.withLock { $0 })
        #expect(observed.installing)
        #expect(observed.backupKept)
        #expect(observed.second == .copyFailed("une installation est déjà en cours."))
        #expect(!installer.isInstalling)
        #expect(try Data(contentsOf: installer.libraryURL) == FakeSDK.thin(FakeSDK.arm64, filler: 3))
        #expect(try leftovers().isEmpty)
    }

    @Test("État : absent, incompatible, prêt (même en quarantaine), en quarantaine, ne se charge pas")
    func status() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let loads = FakeVerifier(true)
        let fails = FakeVerifier(false)
        let ok = SDKInstaller(sdkDirectory: sdk, verifier: loads.verifier)
        let ko = SDKInstaller(sdkDirectory: sdk, verifier: fails.verifier)
        #expect(ok.status() == .absent)
        try FakeSDK.write(FakeSDK.thin(FakeSDK.x86_64), to: ok.libraryURL)
        #expect(ok.status() == .incompatible)
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: ok.libraryURL)
        #expect(ko.status() == .unloadable)
        FakeSDK.setQuarantine(ok.libraryURL)
        #expect(ok.status() == .ready)
        #expect(ko.status() == .quarantined)
    }

    @Test("Vérificateur réel : code 3 attendu ; autre code, signal ou délai dépassé : refusé")
    func obsbotAIVerifier() {
        let sh = URL(fileURLWithPath: "/bin/sh")
        #expect(SDKInstaller.obsbotAIVerifier(executableURL: sh, arguments: ["-c", "exit 3"])(sdk))
        #expect(!SDKInstaller.obsbotAIVerifier(executableURL: sh, arguments: ["-c", "exit 0"])(sdk))
        #expect(!SDKInstaller.obsbotAIVerifier(executableURL: sh, arguments: ["-c", "kill -ABRT $$"])(sdk))
        #expect(!SDKInstaller.obsbotAIVerifier(executableURL: sh, arguments: ["-c", "exec sleep 5"], timeout: 0.3)(sdk))
        #expect(!SDKInstaller.obsbotAIVerifier(executableURL: URL(fileURLWithPath: "/nonexistent/obsbot-ai"))(sdk))
        try? FileManager.default.removeItem(at: directory)
    }
}
