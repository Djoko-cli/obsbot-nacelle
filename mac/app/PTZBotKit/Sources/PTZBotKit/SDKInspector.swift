import Foundation
import Security

/// D'où vient un fichier, selon macOS : l'adresse notée au téléchargement et la date de la quarantaine.
public struct SDKOrigin: Equatable, Sendable {
    public var url: String?
    public var date: Date?
    /// Vrai quand la valeur vient du fichier extrait et non de l'archive : ditto recopie les attributs du zip,
    /// donc la provenance du fichier extrait peut être forgée. L'app le signale dans la fenêtre.
    public var fromInsideArchive: Bool = false

    public init(url: String?, date: Date?, fromInsideArchive: Bool = false) {
        self.url = url
        self.date = date
        self.fromInsideArchive = fromInsideArchive
    }
}

/// Un `libdev.dylib` choisi par l'utilisateur, avec ce que la fenêtre « SDK OBSBOT » affiche
/// avant de l'autoriser (spec ptzd dans l'app § 6.2).
public struct SDKCandidate: Equatable, Sendable {
    public var path: URL
    /// Architectures des tranches Mach-O (« arm64 », « x86_64 »…).
    public var architectures: [String]
    /// Résumé du certificat du signataire, nil si le fichier n'est pas signé par un certificat.
    public var signer: String?
    public var team: String?
    public var quarantined: Bool
    public var origin: SDKOrigin?
    /// Dossier d'extraction d'une archive, à effacer avec `SDKInspector.discard`.
    public var temporaryDirectory: URL?
    /// Les autres `libdev.dylib` du choix, ignorés (chemins relatifs à la racine du choix ou au dossier décompressé).
    public var otherCopies: [String]
    /// nil si le fichier n'est pas signé ; vrai si la signature est valide ; faux si elle est présente mais invalide
    /// (fichier modifié). `signer` et `team` ne sont renseignés que lorsque la signature est valide.
    public var signatureValid: Bool?
    /// nil si le fichier n'est pas signé ou si sa signature est invalide ; vrai si le certificat remonte à une
    /// racine Apple (`anchor apple generic`) ; faux si la signature est intacte mais d'un certificat inconnu d'Apple
    /// (auto-signé, ad hoc). Ce n'est pas un contrôle Gatekeeper.
    public var appleAnchored: Bool?

    public var isArm64: Bool {
        architectures.contains("arm64")
    }

    public init(
        path: URL,
        architectures: [String],
        signer: String? = nil,
        team: String? = nil,
        quarantined: Bool = false,
        origin: SDKOrigin? = nil,
        temporaryDirectory: URL? = nil,
        otherCopies: [String] = [],
        signatureValid: Bool? = nil,
        appleAnchored: Bool? = nil
    ) {
        self.path = path
        self.architectures = architectures
        self.signer = signer
        self.team = team
        self.quarantined = quarantined
        self.origin = origin
        self.temporaryDirectory = temporaryDirectory
        self.otherCopies = otherCopies
        self.signatureValid = signatureValid
        self.appleAnchored = appleAnchored
    }
}

/// Motif du refus d'un fichier.
public enum SDKRejection: Error, Equatable, Sendable {
    case notFound
    case notRegularFile
    case notMachO
    case noArm64(architectures: [String])
    case extractionFailed(String)
    /// Le chemin de `libdev.dylib` mène hors du choix (un dossier intermédiaire est un lien symbolique).
    case outsideArchive

    public var message: String {
        switch self {
        case .notFound:
            "macos/arm64-release/libdev.dylib est introuvable dans ce choix."
        case .notRegularFile:
            "libdev.dylib n'est pas un fichier ordinaire (lien symbolique, tube ou périphérique) : il est refusé."
        case .notMachO:
            "Ce fichier n'est pas une bibliothèque Mach-O."
        case let .noArm64(architectures):
            "Ce SDK n'a pas de version pour Apple Silicon (\(architectures.joined(separator: ", ")))."
        case let .extractionFailed(reason):
            "L'archive n'a pas pu être décompressée : \(reason)"
        case .outsideArchive:
            "Ce choix contient un lien symbolique qui mène hors du dossier du SDK : il est refusé. Choisissez le SDK décompressé ou l'archive reçue."
        }
    }
}

/// Examine un `.zip` du SDK, son dossier décompressé ou directement un `libdev.dylib`.
public enum SDKInspector {
    /// Chemin du SDK pour Mac Apple Silicon dans l'archive d'OBSBOT.
    public static let libraryPath = "macos/arm64-release/libdev.dylib"
    static let quarantineAttribute = "com.apple.quarantine"
    static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"

    /// Profondeur maximale de la recherche des copies de `libdev.dylib` dans un dossier.
    static let maxSearchDepth = 5
    /// Délai maximal de `ditto` : au-delà, le processus est arrêté et l'examen échoue.
    static let extractionTimeout: TimeInterval = 60
    /// Délai laissé à `ditto` pour sortir après SIGTERM, avant SIGKILL.
    static let terminationGrace: TimeInterval = 2

    /// Bloquant (décompression, lecture des en-têtes et de la signature) : à appeler hors du fil principal.
    public static func inspect(_ url: URL) throws(SDKRejection) -> SDKCandidate {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw .notFound
        }
        if isDirectory.boolValue {
            guard let located = try locate(in: url) else { throw .notFound }
            return try describe(located.library, archive: nil, temporaryDirectory: nil, otherCopies: located.otherCopies)
        }
        if url.pathExtension.lowercased() == "zip" {
            // Le zip lui-même doit être un fichier ordinaire : un lien vers une archive n'est pas décompressé.
            guard isRegularFile(url) else { throw .notRegularFile }
            let directory = try extract(url)
            let located: (library: URL, otherCopies: [String])?
            do {
                located = try locate(in: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            guard let located else {
                try? FileManager.default.removeItem(at: directory)
                throw .notFound
            }
            do {
                return try describe(located.library, archive: url, temporaryDirectory: directory, otherCopies: located.otherCopies)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
        return try describe(url, archive: nil, temporaryDirectory: nil, otherCopies: [])
    }

    /// Efface le dossier d'extraction d'une archive.
    public static func discard(_ candidate: SDKCandidate) {
        if let directory = candidate.temporaryDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Un fichier ordinaire, sans suivre les liens : ni lien symbolique, ni tube, ni périphérique.
    static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }

    /// Existe, sans suivre les liens (un lien cassé existe, et sera refusé comme tel).
    private static func existsWithoutFollowing(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// La bibliothèque au chemin que la compilation lie (`macos/arm64-release/libdev.dylib`), sous le dossier
    /// choisi ou sous un de ses sous-dossiers directs (le dossier de tête de l'archive d'OBSBOT). Les autres
    /// `libdev.dylib` (jusqu'à 5 niveaux, sans dossiers cachés ni paquets) sont seulement listés.
    /// Refuse (`outsideArchive`) un chemin dont le dossier intermédiaire est un lien vers un autre emplacement.
    static func locate(in directory: URL) throws(SDKRejection) -> (library: URL, otherCopies: [String])? {
        let manager = FileManager.default
        let subdirectories = ((try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                 options: [.skipsHiddenFiles])) ?? [])
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let root = ([directory] + subdirectories).first(where: { existsWithoutFollowing($0.appending(path: libraryPath)) }) else {
            return nil
        }
        let library = root.appending(path: libraryPath)
        let rootPath = root.resolvingSymlinksInPath().path + "/"
        let directoryPath = directory.resolvingSymlinksInPath().path + "/"
        let chosen = library.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: library.lastPathComponent).path
        guard chosen.hasPrefix(rootPath) else { throw .outsideArchive }
        var others: [String] = []
        if let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let file as URL in enumerator {
                if enumerator.level >= maxSearchDepth {
                    enumerator.skipDescendants()
                }
                guard enumerator.level <= maxSearchDepth, file.lastPathComponent == "libdev.dylib" else { continue }
                let path = file.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: file.lastPathComponent).path
                guard path != chosen else { continue }
                // Chemins relatifs, jamais absolus : à la racine choisie, sinon au dossier choisi ; le reste est ignoré.
                if path.hasPrefix(rootPath) {
                    others.append(String(path.dropFirst(rootPath.count)))
                } else if path.hasPrefix(directoryPath) {
                    others.append(String(path.dropFirst(directoryPath.count)))
                }
            }
        }
        return (library, others.sorted())
    }

    /// Décompresse l'archive dans un dossier temporaire avec `ditto`. Au-delà de `timeout`, `ditto` est arrêté et
    /// le dossier partiel effacé.
    static func extract(_ archive: URL, timeout: TimeInterval = extractionTimeout) throws(SDKRejection) -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ptzbot-sdk-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw .extractionFailed(error.localizedDescription)
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning {
                process.terminate()
            }
            if finished.wait(timeout: .now() + terminationGrace) == .timedOut {
                // Dernier recours : ditto ignore SIGTERM. C'est le processus que nous venons de lancer.
                Darwin.kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            try? FileManager.default.removeItem(at: directory)
            throw .extractionFailed("ditto n'a pas fini dans le délai imparti.")
        }
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw .extractionFailed("ditto a échoué (code \(process.terminationStatus)).")
        }
        return directory
    }

    private static func describe(_ library: URL, archive: URL?, temporaryDirectory: URL?, otherCopies: [String]) throws(SDKRejection) -> SDKCandidate {
        guard isRegularFile(library) else { throw .notRegularFile }
        guard let architectures = MachO.architectures(of: library) else { throw .notMachO }
        guard architectures.contains("arm64") else { throw .noArm64(architectures: architectures) }
        let signing = signing(of: library)
        // La provenance vient d'abord de l'archive : ditto recopie sur le fichier extrait les attributs du zip
        // (adresse forgeable) et lui donne une quarantaine à l'heure de l'extraction. Le fichier extrait ne sert
        // de repli, et la valeur repliée est marquée.
        let sources = archive.map { [$0, library] } ?? [library]
        let quarantined = sources.contains { quarantineValue($0) != nil }
        let urlSource = sources.first { whereFrom($0) != nil }
        let dateSource = sources.first { quarantineValue($0).flatMap(quarantineDate) != nil }
        let url = urlSource.flatMap(whereFrom)
        let date = dateSource.flatMap { quarantineValue($0).flatMap(quarantineDate) }
        let fromInsideArchive = archive != nil && (urlSource == library || dateSource == library)
        return SDKCandidate(
            path: library,
            architectures: architectures,
            signer: signing.signer,
            team: signing.team,
            quarantined: quarantined,
            origin: url == nil && date == nil ? nil : SDKOrigin(url: url, date: date, fromInsideArchive: fromInsideArchive),
            temporaryDirectory: temporaryDirectory,
            otherCopies: otherCopies,
            signatureValid: signing.valid,
            appleAnchored: signing.appleAnchored
        )
    }

    // MARK: - Signature

    /// Le contrôle d'ancrage : la signature, déjà reconnue intacte, remonte-t-elle à une racine Apple ?
    /// Séparé pour que les tests le pilotent.
    typealias AnchorCheck = @Sendable (SecStaticCode) -> Bool

    static let appleAnchorRequirement = "anchor apple generic"

    static let systemAnchorCheck: AnchorCheck = { code in
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(appleAnchorRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    /// Le résumé du certificat du signataire et l'équipe, lus seulement si la signature est intacte et son
    /// certificat reconnu par Apple. `valid` vaut nil pour un fichier non signé, vrai si la signature est intacte,
    /// faux si elle est présente mais invalide (fichier modifié). `appleAnchored` vaut nil sans signature intacte,
    /// vrai si le certificat remonte à Apple, faux sinon (auto-signé, ad hoc) ; dans les cas autres que vrai,
    /// signataire et équipe sont nil (un certificat auto-signé peut porter n'importe quel nom).
    static func signing(
        of url: URL,
        anchorCheck: AnchorCheck = systemAnchorCheck
    ) -> (signer: String?, team: String?, valid: Bool?, appleAnchored: Bool?) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return (nil, nil, nil, nil) }
        // Sans `kSecCSCheckAllArchitectures`, la vérification statique ne lit pas les pages exécutables : un
        // binaire modifié passerait pour valide (mesuré sur un /bin/ls altéré).
        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        if validity == errSecCSUnsigned {
            return (nil, nil, nil, nil)
        }
        guard validity == errSecSuccess else { return (nil, nil, false, nil) }
        // Sans exigence, n'importe quel certificat (même auto-signé) rend la signature « valide » : on demande
        // en plus qu'il remonte à une racine Apple.
        guard anchorCheck(code) else { return (nil, nil, true, false) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else {
            return (nil, nil, true, true)
        }
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let signer = certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        return (signer, info[kSecCodeInfoTeamIdentifier as String] as? String, true, true)
    }

    // MARK: - Attributs étendus

    static func attribute(_ name: String, of url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read >= 0 ? data.prefix(read) : nil
    }

    static func quarantineValue(_ url: URL) -> String? {
        attribute(quarantineAttribute, of: url).map { String(decoding: $0, as: UTF8.self) }
    }

    /// « 0083;6a000000;Safari;… » : la date est le deuxième champ, en secondes hexadécimales depuis 1970.
    static func quarantineDate(_ value: String) -> Date? {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count > 1, let seconds = UInt64(fields[1], radix: 16) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// La première adresse de `kMDItemWhereFroms` (une liste en plist binaire).
    static func whereFrom(_ url: URL) -> String? {
        guard let data = attribute(whereFromsAttribute, of: url),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return nil
        }
        return list.first { !$0.isEmpty }
    }
}

/// Lecture des en-têtes Mach-O, fins (une architecture) ou universels (plusieurs tranches).
enum MachO {
    static let thinMagic64: UInt32 = 0xFEED_FACF
    static let thinMagic32: UInt32 = 0xFEED_FACE
    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let fatMagic64: UInt32 = 0xCAFE_BABF
    static let dylibFileType: UInt32 = 6
    /// Au-delà, 0xCAFEBABE est plutôt une classe Java qu'un binaire universel.
    static let maxSlices: UInt32 = 32

    /// Les architectures d'une bibliothèque Mach-O, ou nil si ce n'en est pas une.
    static func architectures(of url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = read(handle, at: 0, count: 8), header.count == 8 else { return nil }
        let magicBig = header.uint32(at: 0, bigEndian: true)
        if magicBig == fatMagic || magicBig == fatMagic64 {
            let is64 = magicBig == fatMagic64
            let count = header.uint32(at: 4, bigEndian: true)
            guard count > 0, count <= maxSlices else { return nil }
            let entrySize = is64 ? 32 : 20
            guard let table = read(handle, at: 8, count: Int(count) * entrySize), table.count == Int(count) * entrySize else { return nil }
            var result: [String] = []
            for index in 0..<Int(count) {
                let base = index * entrySize
                let cpu = table.uint32(at: base, bigEndian: true)
                let offset = is64 ? table.uint64(at: base + 8, bigEndian: true) : UInt64(table.uint32(at: base + 8, bigEndian: true))
                guard let slice = thin(handle, at: offset), slice.cpu == cpu, slice.fileType == dylibFileType else { return nil }
                result.append(name(cpu))
            }
            return result
        }
        guard let slice = thin(handle, at: 0), slice.fileType == dylibFileType else { return nil }
        return [name(slice.cpu)]
    }

    /// Type de processeur et type de fichier d'un en-tête Mach-O fin à `offset`.
    private static func thin(_ handle: FileHandle, at offset: UInt64) -> (cpu: UInt32, fileType: UInt32)? {
        guard let header = read(handle, at: offset, count: 16), header.count == 16 else { return nil }
        for bigEndian in [false, true] {
            let magic = header.uint32(at: 0, bigEndian: bigEndian)
            if magic == thinMagic64 || magic == thinMagic32 {
                return (header.uint32(at: 4, bigEndian: bigEndian), header.uint32(at: 12, bigEndian: bigEndian))
            }
        }
        return nil
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }

    static func name(_ cpu: UInt32) -> String {
        switch cpu {
        case 0x0100_000C: "arm64"
        case 0x0200_000C: "arm64_32"
        case 0x0100_0007: "x86_64"
        case 0x0000_000C: "arm"
        case 0x0000_0007: "i386"
        default: "cpu \(cpu)"
        }
    }
}

extension Data {
    func uint32(at offset: Int, bigEndian: Bool) -> UInt32 {
        let value = self[startIndex + offset..<startIndex + offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return bigEndian ? value : value.byteSwapped
    }

    func uint64(at offset: Int, bigEndian: Bool) -> UInt64 {
        let value = self[startIndex + offset..<startIndex + offset + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return bigEndian ? value : value.byteSwapped
    }
}
