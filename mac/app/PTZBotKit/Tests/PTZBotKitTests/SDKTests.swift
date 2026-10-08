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

    /// Les en-têtes du SDK, à côté de `macos/` : `include/dev/devs.hpp` (celui qu'obsbot-ai inclut) et un autre.
    @discardableResult
    static func headers(in root: URL) throws -> URL {
        let include = root.appending(path: "include")
        try write(Data("// en-tête inventé\n".utf8), to: include.appending(path: "dev/devs.hpp"))
        try write(Data("// autre en-tête\n".utf8), to: include.appending(path: "util/comm.hpp"))
        return include
    }

    /// Un SDK décompressé complet : bibliothèque et en-têtes.
    @discardableResult
    static func folder(_ root: URL, library: Data = thin(arm64)) throws -> URL {
        try headers(in: root)
        return try write(library, to: root.appending(path: "macos/arm64-release/libdev.dylib"))
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

    /// Archive `ditto` du dossier, comme l'archive d'OBSBOT (les attributs étendus des fichiers vont avec).
    @discardableResult
    static func zip(_ folder: URL, to archive: URL) throws -> URL {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        try #require(ditto.terminationStatus == 0)
        return archive
    }
}

@Suite("SDK : examen du fichier choisi", .french)
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

    @Test("Dossier complet : architectures, non signée, sans quarantaine ni provenance, en-têtes trouvés")
    func folderWithHeaders() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try FakeSDK.folder(directory, library: FakeSDK.fat([FakeSDK.arm64, FakeSDK.x86_64]))
        let candidate = try SDKInspector.inspect(directory)
        #expect(candidate.path.resolvingSymlinksInPath() == library.resolvingSymlinksInPath())
        #expect(candidate.architectures == ["arm64", "x86_64"])
        #expect(candidate.isArm64)
        #expect(candidate.signer == nil)
        #expect(candidate.team == nil)
        #expect(!candidate.quarantined)
        #expect(candidate.origin == nil)
        #expect(candidate.temporaryDirectory == nil)
        #expect(candidate.includeDirectory?.resolvingSymlinksInPath() == directory.appending(path: "include").resolvingSymlinksInPath())
    }

    @Test("Sans en-têtes : un libdev.dylib seul, ou un dossier sans include/dev/devs.hpp, est refusé")
    func headersMissing() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "libdev_v9/macos/arm64-release/libdev.dylib"))
        #expect(throws: SDKRejection.headersMissing) { try SDKInspector.inspect(library) }
        #expect(throws: SDKRejection.headersMissing) { try SDKInspector.inspect(directory) }
        try FakeSDK.write(Data("// autre".utf8), to: directory.appending(path: "libdev_v9/include/util/comm.hpp"))
        #expect(throws: SDKRejection.headersMissing) { try SDKInspector.inspect(directory) }
        #expect(SDKRejection.headersMissing.message == "Choisissez l'archive ou le dossier du SDK : ses en-têtes sont nécessaires.")
        try FakeSDK.headers(in: directory.appending(path: "libdev_v9"))
        #expect(try SDKInspector.inspect(directory).includeDirectory != nil)
    }

    @Test("En-têtes avec un lien symbolique, ou dossier include lié ailleurs : refusés")
    func headersNotPlain() throws {
        let directory = try FakeSDK.directory()
        let elsewhere = try FakeSDK.directory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let root = directory.appending(path: "libdev_v9")
        try FakeSDK.folder(root)
        let secret = try FakeSDK.write(Data("secret".utf8), to: elsewhere.appending(path: "secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "include/dev/lien.hpp"), withDestinationURL: secret)
        #expect(throws: SDKRejection.headersNotPlain) { try SDKInspector.inspect(directory) }
        try FileManager.default.removeItem(at: root.appending(path: "include"))
        let outside = try FakeSDK.headers(in: elsewhere)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "include"), withDestinationURL: outside)
        #expect(throws: SDKRejection.headersNotPlain) { try SDKInspector.inspect(directory) }
    }

    @Test("Refus : introuvable, pas Mach-O, sans tranche arm64 ; motifs en clair")
    func rejections() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: SDKRejection.notFound) { try SDKInspector.inspect(directory.appending(path: "absent.dylib")) }
        #expect(throws: SDKRejection.notFound) { try SDKInspector.inspect(directory) }
        try FakeSDK.folder(directory.appending(path: "texte"), library: Data("texte".utf8))
        #expect(throws: SDKRejection.notMachO) { try SDKInspector.inspect(directory.appending(path: "texte")) }
        try FakeSDK.folder(directory.appending(path: "intel"), library: FakeSDK.thin(FakeSDK.x86_64))
        #expect(throws: SDKRejection.noArm64(architectures: ["x86_64"])) { try SDKInspector.inspect(directory.appending(path: "intel")) }
        #expect(SDKRejection.notMachO.message == "Ce fichier n'est pas une bibliothèque Mach-O.")
        #expect(SDKRejection.notRegularFile.message.hasPrefix("libdev.dylib n'est pas un fichier ordinaire"))
        #expect(SDKRejection.noArm64(architectures: ["x86_64"]).message == "Ce SDK n'a pas de version pour Apple Silicon (x86_64).")
    }

    @Test("Dossier décompressé : macos/arm64-release/libdev.dylib le moins profond, quarantaine et provenance lues")
    func folder() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "libdev_v9")
        let library = try FakeSDK.folder(root)
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
        try FakeSDK.folder(directory.appending(path: "libdev_v9"))
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
        try FakeSDK.headers(in: root)
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: root.appending(path: "vraie.dylib"))
        let link = root.appending(path: "macos/arm64-release/libdev.dylib")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../vraie.dylib")
        #expect(throws: SDKRejection.notRegularFile) { try SDKInspector.inspect(directory) }
        // Un fichier seul, lien ou non, n'a pas d'en-têtes.
        #expect(throws: SDKRejection.headersMissing) { try SDKInspector.inspect(link) }

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
        try FakeSDK.folder(root)
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
        #expect(candidate.includeDirectory?.resolvingSymlinksInPath().path.hasPrefix(temporary.resolvingSymlinksInPath().path) == true)
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

    @Test("Signature validée : valide pour /bin/ls, nil si non signé, invalide et sans signataire après modification")
    func signatureValidity() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let signed = SDKInspector.signing(of: URL(fileURLWithPath: "/bin/ls"))
        #expect(signed.valid == true)
        #expect(signed.signer != nil)
        // Un fichier sans signature : Security répond « not signed at all » (errSecCSUnsigned), donc nil.
        let plain = try FakeSDK.write(Data("texte sans signature".utf8), to: directory.appending(path: "plain.dylib"))
        #expect(SDKInspector.signing(of: plain).valid == nil)
        // Un octet modifié au milieu du fichier, loin des en-têtes : la signature ne tient plus.
        let copy = directory.appending(path: "ls-copie")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: copy)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int)
        let handle = try FileHandle(forUpdating: copy)
        try handle.seek(toOffset: UInt64(size / 2))
        let byte = try #require(try handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: UInt64(size / 2))
        try handle.write(contentsOf: Data([byte ^ 0xFF]))
        try handle.close()
        let altered = SDKInspector.signing(of: copy)
        #expect(altered.valid == false)
        #expect(altered.signer == nil)
        #expect(altered.team == nil)
        #expect(altered.appleAnchored == nil)
    }

    @Test("Ancrage Apple : /bin/ls oui ; copie signée ad hoc intacte mais non reconnue, sans signataire ; non signé : nil")
    func appleAnchor() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = SDKInspector.signing(of: URL(fileURLWithPath: "/bin/ls"))
        #expect(system.valid == true)
        #expect(system.appleAnchored == true)

        // Seule la copie temporaire est re-signée.
        let copy = directory.appending(path: "ls-adhoc")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: copy)
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["-f", "-s", "-", copy.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        try #require(codesign.terminationStatus == 0)
        let adHoc = SDKInspector.signing(of: copy)
        #expect(adHoc.valid == true)
        #expect(adHoc.appleAnchored == false)
        #expect(adHoc.signer == nil)
        #expect(adHoc.team == nil)

        // Le contrôle d'ancrage est injectable : refusé, même /bin/ls perd signataire et équipe.
        let refused = SDKInspector.signing(of: URL(fileURLWithPath: "/bin/ls"), anchorCheck: { _ in false })
        #expect(refused.valid == true)
        #expect(refused.appleAnchored == false)
        #expect(refused.signer == nil)
        let plain = try FakeSDK.write(Data("texte sans signature".utf8), to: directory.appending(path: "plain.dylib"))
        #expect(SDKInspector.signing(of: plain).appleAnchored == nil)
    }

    @Test("Provenance forgée : l'adresse de l'archive l'emporte sur celle que ditto recopie du fichier extrait")
    func forgedProvenance() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "libdev_v9")
        let library = try FakeSDK.folder(root)
        try FakeSDK.setWhereFroms(library, ["https://forge.example.com/libdev.dylib"])
        let archive = try FakeSDK.zip(root, to: directory.appending(path: "libdev_v9.zip"))
        FakeSDK.setQuarantine(archive)
        try FakeSDK.setWhereFroms(archive, ["https://example.com/libdev_v9.zip"])

        let candidate = try SDKInspector.inspect(archive)
        defer { SDKInspector.discard(candidate) }
        // L'attribut forgé est bien arrivé sur le fichier extrait : le test prouve que l'archive l'emporte.
        #expect(SDKInspector.whereFrom(candidate.path) == "https://forge.example.com/libdev.dylib")
        #expect(candidate.origin == SDKOrigin(url: "https://example.com/libdev_v9.zip", date: Date(timeIntervalSince1970: 0x6A00_0000)))
        #expect(candidate.origin?.fromInsideArchive == false)
        #expect(candidate.quarantined)
    }

    @Test("Provenance de repli : sans adresse dans l'archive, celle du fichier extrait est prise et marquée")
    func fallbackProvenanceMarked() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "libdev_v9")
        let library = try FakeSDK.folder(root)
        try FakeSDK.setWhereFroms(library, ["https://example.com/depuis-le-fichier.dylib"])
        let archive = try FakeSDK.zip(root, to: directory.appending(path: "libdev_v9.zip"))

        let candidate = try SDKInspector.inspect(archive)
        defer { SDKInspector.discard(candidate) }
        #expect(candidate.origin?.url == "https://example.com/depuis-le-fichier.dylib")
        #expect(candidate.origin?.fromInsideArchive == true)
        #expect(!candidate.quarantined)
    }

    @Test("Dossier intermédiaire lié hors du choix : refusé, même pour un dossier décompressé")
    func intermediateSymlinkOutside() throws {
        let directory = try FakeSDK.directory()
        let elsewhere = try FakeSDK.directory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let root = directory.appending(path: "libdev_v9")
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: elsewhere.appending(path: "macos/arm64-release/libdev.dylib"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "macos"), withDestinationURL: elsewhere.appending(path: "macos"))
        #expect(throws: SDKRejection.outsideArchive) { try SDKInspector.inspect(directory) }
        #expect(throws: SDKRejection.outsideArchive) { try SDKInspector.inspect(root) }
        #expect(SDKRejection.outsideArchive.message.hasSuffix("Choisissez le SDK décompressé ou l'archive reçue."))
    }

    @Test("Autres copies : chemins relatifs au choix, jamais absolus")
    func otherCopiesRelative() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FakeSDK.folder(directory.appending(path: "libdev_v9"))
        // Hors de la racine libdev_v9, mais dans le choix : relatif au choix.
        try FakeSDK.write(FakeSDK.thin(FakeSDK.x86_64), to: directory.appending(path: "autre/libdev.dylib"))
        let candidate = try SDKInspector.inspect(directory)
        #expect(candidate.otherCopies == ["autre/libdev.dylib"])
        #expect(candidate.otherCopies.allSatisfy { !$0.hasPrefix("/") })
    }

    @Test("Le .zip doit être un fichier ordinaire : un lien vers une archive est refusé sans décompression")
    func zipSymlinkRejected() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "libdev_v9")
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: root.appending(path: "macos/arm64-release/libdev.dylib"))
        let archive = try FakeSDK.zip(root, to: directory.appending(path: "vrai.zip"))
        let link = directory.appending(path: "lien.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archive)
        #expect(throws: SDKRejection.notRegularFile) { try SDKInspector.inspect(link) }
    }

    @Test("ditto qui dépasse le délai : arrêté, extraction en échec")
    func extractionTimeout() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "libdev_v9")
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: root.appending(path: "macos/arm64-release/libdev.dylib"))
        let archive = try FakeSDK.zip(root, to: directory.appending(path: "libdev_v9.zip"))
        do {
            _ = try SDKInspector.extract(archive, timeout: 0)
            Issue.record("ditto aurait dû dépasser un délai nul")
        } catch {
            guard case .extractionFailed = error else {
                Issue.record("Motif inattendu : \(error)")
                return
            }
        }
    }
}

