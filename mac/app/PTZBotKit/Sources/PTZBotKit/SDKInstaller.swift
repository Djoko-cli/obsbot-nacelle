import Foundation
import Synchronization

/// État du SDK installé, pour la ligne « SDK OBSBOT » du panneau (spec ptzd dans l'app § 6.1).
public enum SDKStatus: Equatable, Sendable {
    case ready
    case absent
    /// Ne se charge pas, et porte l'attribut de quarantaine.
    case quarantined
    /// Pas une bibliothèque Mach-O, ou sans tranche arm64.
    case incompatible
    /// Ne se charge pas, sans quarantaine.
    case unloadable
}

/// Échec de l'installation : l'ancien SDK, s'il existe, est conservé.
public enum SDKInstallError: Error, Equatable, Sendable {
    case incompatible
    case copyFailed(String)
    case unloadable

    public var message: String {
        switch self {
        case .incompatible:
            "Ce SDK n'a pas de version pour Apple Silicon."
        case let .copyFailed(reason):
            "Copie du SDK impossible : \(reason)"
        case .unloadable:
            "obsbot-ai ne charge pas ce SDK : l'ancien SDK, s'il y en avait un, est conservé."
        }
    }
}

/// L'état « installation en cours », partagé entre les copies d'un `SDKInstaller`.
private final class InstallProgress: Sendable {
    private let active = Mutex(false)

    var isActive: Bool {
        active.withLock { $0 }
    }

    /// Faux si une installation est déjà en cours.
    func begin() -> Bool {
        active.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
    }

    func end() {
        active.withLock { $0 = false }
    }
}

/// La copie n'est plus une bibliothèque arm64 ordinaire.
private struct StagingRejected: LocalizedError {
    var errorDescription: String? { "la copie n'est pas une bibliothèque arm64 ordinaire." }
}

/// Vérifie qu'obsbot-ai charge le SDK du dossier donné.
public typealias SDKVerifier = @Sendable (_ sdkDirectory: URL) -> Bool

/// La copie autorisée du SDK, `<support>/sdk/libdev.dylib` (spec ptzd dans l'app § 5.2 et § 6.2).
/// Bloquant (copie, lancement d'obsbot-ai) : à appeler hors du fil principal.
public struct SDKInstaller: Sendable {
    public let sdkDirectory: URL
    private let verifier: SDKVerifier
    /// Partagé par les copies de l'installateur (panneau et fenêtre « SDK OBSBOT ») : une installation en cours.
    private let progress = InstallProgress()

    public init(sdkDirectory: URL, verifier: @escaping SDKVerifier) {
        self.sdkDirectory = sdkDirectory
        self.verifier = verifier
    }

    public var libraryURL: URL {
        sdkDirectory.appending(path: "libdev.dylib")
    }

    var stagingURL: URL {
        sdkDirectory.appending(path: "libdev.dylib.new")
    }

    var backupURL: URL {
        sdkDirectory.appending(path: "libdev.dylib.old")
    }

    /// Copie vers `libdev.dylib.new`, retire la quarantaine de cette copie, revérifie qu'elle est une bibliothèque
    /// arm64 ordinaire, la renomme sur `libdev.dylib` (l'ancien reste joignable par un lien dur `.old` jusqu'à la
    /// vérification), puis vérifie qu'obsbot-ai la charge. En cas d'échec, l'ancien SDK est remis et les fichiers
    /// intermédiaires sont effacés. L'original choisi par l'utilisateur n'est jamais modifié.
    public func install(_ candidate: SDKCandidate) throws(SDKInstallError) {
        guard candidate.isArm64 else { throw .incompatible }
        guard progress.begin() else {
            throw .copyFailed("une installation est déjà en cours.")
        }
        defer { progress.end() }
        let manager = FileManager.default
        // Une installation interrompue (plantage) a laissé l'ancien SDK en `.old` : il est remis d'abord.
        guard recoverInterruptedInstall() else {
            throw .copyFailed("l'ancien SDK (libdev.dylib.old) n'a pas pu être remis en place.")
        }
        try? manager.removeItem(at: stagingURL)
        do {
            try manager.createDirectory(at: sdkDirectory, withIntermediateDirectories: true)
            try manager.copyItem(at: candidate.path, to: stagingURL)
            if removexattr(stagingURL.path, SDKInspector.quarantineAttribute, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
                throw CocoaError(.fileWriteNoPermission)
            }
            // Le fichier a pu changer depuis son examen : la copie elle-même est revérifiée.
            guard SDKInspector.isRegularFile(stagingURL), MachO.architectures(of: stagingURL)?.contains("arm64") == true else {
                throw StagingRejected()
            }
            if manager.fileExists(atPath: libraryURL.path) {
                try manager.linkItem(at: libraryURL, to: backupURL)
            }
            guard rename(stagingURL.path, libraryURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? manager.removeItem(at: stagingURL)
            try? manager.removeItem(at: backupURL)
            throw .copyFailed(error.localizedDescription)
        }
        guard verifier(sdkDirectory) else {
            if manager.fileExists(atPath: backupURL.path) {
                guard rename(backupURL.path, libraryURL.path) == 0 else {
                    // `.old` reste : il sera remis au prochain examen.
                    throw .copyFailed("l'ancien SDK n'a pas pu être remis en place ; il le sera au prochain essai.")
                }
            } else {
                try? manager.removeItem(at: libraryURL)
            }
            throw .unloadable
        }
        try? manager.removeItem(at: backupURL)
    }

    /// Remet `libdev.dylib.old` en place s'il existe ; faux si le renommage échoue.
    @discardableResult
    func recoverInterruptedInstall() -> Bool {
        guard (try? FileManager.default.attributesOfItem(atPath: backupURL.path)) != nil else { return true }
        return rename(backupURL.path, libraryURL.path) == 0
    }

    /// Absent, incompatible, puis le chargement par obsbot-ai décide de « Prêt » ; la quarantaine
    /// n'explique qu'un échec de chargement.
    /// Une installation est en cours : `status()` ne touche alors pas à `libdev.dylib.old`.
    public var isInstalling: Bool {
        progress.isActive
    }

    public func status() -> SDKStatus {
        // Pendant une installation, `.old` est la sauvegarde légitime de l'ancien SDK : pas de reprise.
        if !progress.isActive {
            recoverInterruptedInstall()
        }
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return .absent }
        guard let architectures = MachO.architectures(of: libraryURL), architectures.contains("arm64") else {
            return .incompatible
        }
        if verifier(sdkDirectory) {
            return .ready
        }
        return SDKInspector.quarantineValue(libraryURL) != nil ? .quarantined : .unloadable
    }

    /// Le vérificateur réel : obsbot-ai lancé sans argument, avec `DYLD_LIBRARY_PATH` sur le dossier du SDK,
    /// doit afficher son aide et sortir avec le code 3 ; sans SDK chargeable, dyld l'arrête avant (code 134).
    public static func obsbotAIVerifier(
        executableURL: URL,
        arguments: [String] = [],
        timeout: TimeInterval = 10
    ) -> SDKVerifier {
        { sdkDirectory in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["DYLD_LIBRARY_PATH": sdkDirectory.path]) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            do {
                try process.run()
            } catch {
                return false
            }
            guard done.wait(timeout: .now() + timeout) == .success else {
                Darwin.kill(process.processIdentifier, SIGKILL)
                done.wait()
                return false
            }
            return process.terminationReason == .exit && process.terminationStatus == 3
        }
    }
}
