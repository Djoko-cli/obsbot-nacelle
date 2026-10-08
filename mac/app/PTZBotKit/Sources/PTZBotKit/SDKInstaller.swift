import CryptoKit
import Foundation
import Synchronization

/// État du SDK installé, pour la ligne « SDK OBSBOT » du panneau (spec ptzd dans l'app § 6.1, spec distribution § 6.4).
public enum SDKStatus: Equatable, Sendable {
    /// Le SDK, un obsbot-ai compilé avec l'empreinte courante, et la vérification de chargement réussie.
    case ready
    case absent
    /// Ne se charge pas, et porte l'attribut de quarantaine.
    case quarantined
    /// Pas une bibliothèque Mach-O, ou sans tranche arm64.
    case incompatible
    /// Ne se charge pas, sans quarantaine.
    case unloadable
    /// La source d'obsbot-ai (`Contents/Resources/obsbot-ai.cpp`) manque dans l'app : rien ne peut être compilé.
    case sourceMissing
    /// obsbot-ai est à compiler (absent ou d'une autre source) et les outils de développement manquent.
    /// `fallback` : l'ancien obsbot-ai est là et charge le SDK ; il reste en service.
    case toolsRequired(fallback: Bool)
    /// SDK sans en-têtes ni obsbot-ai (installation de B1) : à réinstaller depuis l'archive ou le dossier.
    case incomplete
    /// obsbot-ai est en train d'être recompilé (§ 6.3).
    case recompiling
    /// obsbot-ai n'est pas à jour alors que les outils sont là : la dernière compilation a échoué.
    case compileFailed(fallback: Bool)

    /// Le suivi IA peut servir : SDK prêt, ou ancien obsbot-ai encore en service.
    public var aiUsable: Bool {
        switch self {
        case .ready: true
        case let .toolsRequired(fallback), let .compileFailed(fallback): fallback
        case .absent, .quarantined, .incompatible, .unloadable, .sourceMissing, .incomplete, .recompiling: false
        }
    }
}

/// Échec de l'installation : l'ancien SDK, s'il existe, est conservé.
public enum SDKInstallError: Error, Equatable, Sendable {
    case incompatible
    case copyFailed(String)
    case unloadable
    /// Le choix n'a pas d'en-têtes : obsbot-ai ne peut pas être compilé.
    case headersMissing
    /// La source d'obsbot-ai manque dans l'app : rien n'est copié.
    case sourceMissing
    /// Les outils de développement d'Apple manquent : rien n'est copié.
    case toolsMissing
    /// clang++ a échoué ; sa sortie est dans le journal de compilation.
    case compileFailed

    public var message: String {
        switch self {
        case .incompatible:
            "Ce SDK n'a pas de version pour Apple Silicon."
        case let .copyFailed(reason):
            "Copie du SDK impossible : \(reason)"
        case .unloadable:
            "obsbot-ai ne charge pas ce SDK : l'ancien SDK, s'il y en avait un, est conservé."
        case .headersMissing:
            SDKRejection.headersMissing.message
        case .sourceMissing:
            "La source d'obsbot-ai est introuvable dans l'app."
        case .toolsMissing:
            "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai : installez-les, puis recommencez."
        case .compileFailed:
            "La compilation d'obsbot-ai a échoué : l'ancien SDK est conservé. Le détail est dans le journal obsbot-ai-compilation.log."
        }
    }
}

/// L'état « installation en cours », partagé entre les copies d'un `SDKInstaller`.
final class InstallProgress: Sendable {
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

    /// Exécute `body` avec le verrou tenu, seulement si aucune installation n'est en cours (nil sinon). `begin()`
    /// attend la fin de `body` : la reprise et le début d'une installation ne peuvent pas se chevaucher.
    @discardableResult
    func runIfIdle<Output>(_ body: () -> Output) -> Output? {
        active.withLock { value in
            value ? nil : body()
        }
    }
}

/// Une copie préparée n'est plus ce qu'elle était à l'examen.
private struct StagingRejected: LocalizedError {
    var reason: String
    var errorDescription: String? { reason }
}

/// Vérifie que l'obsbot-ai donné, lancé sans argument avec `DYLD_LIBRARY_PATH` sur le dossier donné, charge le SDK.
public typealias SDKVerifier = @Sendable (_ executable: URL, _ sdkDirectory: URL) -> Bool

/// Le SDK autorisé et l'obsbot-ai compilé chez l'utilisateur, dans `<support>/sdk/` (spec distribution § 6) :
/// `libdev.dylib`, `include/`, `obsbot-ai` et `obsbot-ai.sha256`, l'empreinte de la source compilée.
/// Bloquant (copie, compilation, lancement d'obsbot-ai) : à appeler hors du fil principal.
public struct SDKInstaller: Sendable {
    /// Les éléments d'une installation, sous leur nom final dans `sdk/` comme dans `sdk/new/` : l'éditeur de liens
    /// (`-ldev`) et dyld (`DYLD_LIBRARY_PATH`) cherchent `libdev.dylib` sous ce nom.
    enum Element: String, CaseIterable, Sendable {
        case library = "libdev.dylib"
        case headers = "include"
        case binary = "obsbot-ai"
        case hash = "obsbot-ai.sha256"

        var isDirectory: Bool {
            self == .headers
        }
    }

    public let sdkDirectory: URL
    /// La source d'obsbot-ai livrée dans l'app (`Contents/Resources/obsbot-ai.cpp`).
    public let sourceURL: URL
    public let toolchain: any Toolchain
    /// La sortie de clang++ y est ajoutée quand une compilation échoue.
    public let buildLog: URL
    private let verifier: SDKVerifier
    /// Partagé par les copies de l'installateur (panneau et fenêtre « SDK OBSBOT ») : une installation en cours.
    private let progress = InstallProgress()
    /// Le renommage qui remet un ancien élément en place, remplaçable par les tests pour simuler un échec.
    var restoreRename: @Sendable (_ from: String, _ to: String) -> Int32 = { Darwin.rename($0, $1) }

    public init(sdkDirectory: URL, sourceURL: URL, toolchain: any Toolchain, verifier: @escaping SDKVerifier, buildLog: URL) {
        self.sdkDirectory = sdkDirectory
        self.sourceURL = sourceURL
        self.toolchain = toolchain
        self.verifier = verifier
        self.buildLog = buildLog
    }

    public var libraryURL: URL {
        url(.library)
    }

    public var headersURL: URL {
        url(.headers)
    }

    /// L'obsbot-ai que ptzd lance (`--ai`).
    public var obsbotAIURL: URL {
        url(.binary)
    }

    public var hashURL: URL {
        url(.hash)
    }

    /// Les éléments préparés, sous leur nom final. Sa présence marque une installation pas encore validée.
    var stagingURL: URL {
        sdkDirectory.appending(path: "new")
    }

    func url(_ element: Element) -> URL {
        sdkDirectory.appending(path: element.rawValue)
    }

    func stagedURL(_ element: Element) -> URL {
        stagingURL.appending(path: element.rawValue)
    }

    func backupURL(_ element: Element) -> URL {
        sdkDirectory.appending(path: element.rawValue + ".old")
    }

    /// Une installation est en cours : `status()` ne touche alors ni à `sdk/new/` ni aux `.old`.
    public var isInstalling: Bool {
        progress.isActive
    }

    // MARK: - Installation (§ 6.2)

    /// Une seule transaction : la bibliothèque et les en-têtes copiés dans `sdk/new/` sans quarantaine et revérifiés,
    /// obsbot-ai compilé avec eux, puis lancé sans argument (code 3 attendu) avec `DYLD_LIBRARY_PATH` sur `sdk/new/`.
    /// Ensuite seulement, les trois éléments et l'empreinte prennent leur place, les anciens gardés en `.old` jusqu'à
    /// la fin. En cas d'échec, tout revient comme avant. L'original choisi par l'utilisateur n'est jamais modifié.
    public func install(_ candidate: SDKCandidate) throws(SDKInstallError) {
        guard candidate.isArm64 else { throw .incompatible }
        guard let headers = candidate.includeDirectory else { throw .headersMissing }
        // Sans source ni outils, rien ne peut être compilé : rien n'est copié.
        guard let sourceHash = sourceHash() else { throw .sourceMissing }
        guard toolchain.isAvailable() else { throw .toolsMissing }
        guard progress.begin() else {
            throw .copyFailed("une installation est déjà en cours.")
        }
        defer { progress.end() }
        guard recoverInterruptedInstall() else {
            throw .copyFailed("l'installation interrompue précédente n'a pas pu être annulée.")
        }
        let manager = FileManager.default
        do {
            try prepareStaging()
            let library = stagedURL(.library)
            try manager.copyItem(at: candidate.path, to: library)
            try removeQuarantine(library)
            try Self.copyHeaders(from: headers, to: stagedURL(.headers))
            // Les fichiers ont pu changer depuis leur examen : les copies elles-mêmes sont revérifiées.
            guard SDKInspector.isRegularFile(library), MachO.architectures(of: library)?.contains("arm64") == true else {
                throw StagingRejected(reason: "la copie n'est pas une bibliothèque arm64 ordinaire.")
            }
            guard SDKInspector.isPlainTree(stagedURL(.headers)),
                  SDKInspector.isRegularFile(stagedURL(.headers).appending(path: SDKInspector.mainHeaderPath)) else {
                throw StagingRejected(reason: "les en-têtes copiés ne sont pas des fichiers ordinaires.")
            }
        } catch {
            discardStaging()
            throw .copyFailed(error.localizedDescription)
        }
        try compileAndCheck(includeDirectory: stagedURL(.headers), libraryDirectory: stagingURL, sourceHash: sourceHash)
        do {
            try commit([.library, .headers, .binary, .hash])
        } catch {
            throw .copyFailed(error.localizedDescription)
        }
    }

    // MARK: - Recompilation (§ 6.3)

    /// Faux tant que l'empreinte de la source de l'app est celle de `sdk/obsbot-ai.sha256` et qu'obsbot-ai est là,
    /// ou si rien ne peut être recompilé (pas de SDK, pas d'en-têtes, pas de source).
    public func needsRecompile() -> Bool {
        progress.runIfIdle { recoverInterruptedInstall() }
        guard let current = sourceHash(),
              FileManager.default.fileExists(atPath: libraryURL.path),
              hasHeaders else { return false }
        return !isCompiled(sourceHash: current)
    }

    /// Recompile obsbot-ai avec `sdk/include/` et `sdk/libdev.dylib`, sans rien demander, quand la source de l'app a
    /// changé (mise à jour de l'app). Mêmes étapes que l'installation, sauf la copie ; en cas d'échec, l'ancien
    /// obsbot-ai reste en service. Vrai si obsbot-ai a été recompilé.
    @discardableResult
    public func recompileIfNeeded() throws(SDKInstallError) -> Bool {
        guard needsRecompile() else { return false }
        guard let sourceHash = sourceHash() else { throw .sourceMissing }
        guard toolchain.isAvailable() else { throw .toolsMissing }
        guard progress.begin() else {
            throw .copyFailed("une installation est déjà en cours.")
        }
        defer { progress.end() }
        guard recoverInterruptedInstall() else {
            throw .copyFailed("l'installation interrompue précédente n'a pas pu être annulée.")
        }
        do {
            try prepareStaging()
        } catch {
            discardStaging()
            throw .copyFailed(error.localizedDescription)
        }
        try compileAndCheck(includeDirectory: headersURL, libraryDirectory: sdkDirectory, sourceHash: sourceHash)
        do {
            try commit([.binary, .hash])
        } catch {
            throw .copyFailed(error.localizedDescription)
        }
        return true
    }

    // MARK: - État (§ 6.4)

    /// Absent, incompatible, incomplet, à compiler, puis le chargement par obsbot-ai décide de « Prêt » ; la
    /// quarantaine n'explique qu'un échec de chargement. Ne compile jamais (voir `recompileIfNeeded()`).
    public func status() -> SDKStatus {
        // La reprise se fait sous le verrou de l'installation : elle ne peut pas chevaucher `begin()`. Pendant une
        // installation, `sdk/new/` et les `.old` sont légitimes : pas de reprise.
        progress.runIfIdle { recoverInterruptedInstall() }
        let manager = FileManager.default
        guard manager.fileExists(atPath: libraryURL.path) else { return .absent }
        guard let architectures = MachO.architectures(of: libraryURL), architectures.contains("arm64") else {
            return .incompatible
        }
        let hasBinary = SDKInspector.isRegularFile(obsbotAIURL)
        guard hasHeaders || hasBinary else { return .incomplete }
        guard let current = sourceHash() else { return .sourceMissing }
        guard isCompiled(sourceHash: current) else {
            guard hasHeaders else { return .incomplete }
            let fallback = hasBinary && verifier(obsbotAIURL, sdkDirectory)
            return toolchain.isAvailable() ? .compileFailed(fallback: fallback) : .toolsRequired(fallback: fallback)
        }
        if verifier(obsbotAIURL, sdkDirectory) {
            return .ready
        }
        return SDKInspector.quarantineValue(libraryURL) != nil ? .quarantined : .unloadable
    }

    // MARK: - Étapes communes

    private var hasHeaders: Bool {
        SDKInspector.isDirectoryWithoutFollowing(headersURL)
            && SDKInspector.isRegularFile(headersURL.appending(path: SDKInspector.mainHeaderPath))
    }

    /// obsbot-ai est là, et `obsbot-ai.sha256` porte l'empreinte donnée.
    private func isCompiled(sourceHash: String) -> Bool {
        guard SDKInspector.isRegularFile(obsbotAIURL),
              let data = try? Data(contentsOf: hashURL) else { return false }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == sourceHash
    }

    /// L'empreinte SHA-256 de la source d'obsbot-ai livrée dans l'app, en hexadécimal ; nil si elle manque.
    public func sourceHash() -> String? {
        guard SDKInspector.isRegularFile(sourceURL), let data = try? Data(contentsOf: sourceURL) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `sdk/new/` neuf et vide.
    private func prepareStaging() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: sdkDirectory, withIntermediateDirectories: true)
        if SDKInspector.existsWithoutFollowing(stagingURL) {
            try manager.removeItem(at: stagingURL)
        }
        try manager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
    }

    private func discardStaging() {
        try? FileManager.default.removeItem(at: stagingURL)
    }

    /// Compile `sdk/new/obsbot-ai`, vérifie qu'il charge le SDK du dossier de la bibliothèque, puis écrit
    /// l'empreinte dans `sdk/new/`. En cas d'échec, `sdk/new/` est effacé.
    private func compileAndCheck(includeDirectory: URL, libraryDirectory: URL, sourceHash: String) throws(SDKInstallError) {
        let binary = stagedURL(.binary)
        do {
            try toolchain.compile(source: sourceURL, includeDirectory: includeDirectory, libraryDirectory: libraryDirectory, output: binary)
        } catch {
            discardStaging()
            switch error {
            case .unavailable:
                throw .toolsMissing
            case let .compileFailed(output):
                appendToBuildLog(output)
                throw .compileFailed
            }
        }
        guard SDKInspector.isRegularFile(binary), verifier(binary, libraryDirectory) else {
            discardStaging()
            throw .unloadable
        }
        do {
            try Data((sourceHash + "\n").utf8).write(to: stagedURL(.hash))
        } catch {
            discardStaging()
            throw .copyFailed(error.localizedDescription)
        }
    }

    /// Le journal de l'échange en cours, dans `sdk/new/` : les éléments échangés, et ceux qui n'avaient pas de
    /// version précédente. Il est écrit avant le premier échange ; le retirer est la validation.
    var journalURL: URL {
        stagingURL.appending(path: ".transaction")
    }

    /// Le reste d'une installation de B1 interrompue avant son renommage.
    var legacyStagingURL: URL {
        sdkDirectory.appending(path: "libdev.dylib.new")
    }

    /// Le contenu du journal.
    struct Journal: Codable, Equatable {
        var elements: [String]
        /// Les éléments sans version précédente : à retirer s'ils sont déjà en place quand l'échange est annulé.
        var nouveaux: [String]
    }

    /// Les éléments préparés prennent leur place (spec distribution § 6.2, étape 5) :
    /// 1. le journal est écrit dans `sdk/new/` (fichier temporaire, puis renommage) ;
    /// 2. un fichier en place reste joignable par un lien dur `.old`, puis le nouveau le remplace d'un seul
    ///    renommage (ptzd peut lancer obsbot-ai à tout moment) ; le dossier des en-têtes est renommé en `.old` ;
    /// 3. le journal est retiré : c'est la validation ; puis `sdk/new/`, vide, et les `.old`.
    /// Au moindre échec avant la validation, tout est remis comme avant ; après un arrêt de l'app, la reprise
    /// (`recoverInterruptedInstall`) le fait d'après le journal.
    func commit(_ elements: [Element]) throws {
        let nouveaux = elements.filter { !SDKInspector.existsWithoutFollowing(url($0)) }
        do {
            try writeJournal(Journal(elements: elements.map(\.rawValue), nouveaux: nouveaux.map(\.rawValue)))
            for element in elements {
                try swap(element)
            }
            try posix(unlink(journalURL.path))
        } catch {
            var restored = true
            for element in elements.reversed() {
                restored = rollBack(element, isNew: nouveaux.contains(element)) && restored
            }
            // Un ancien élément pas remis : le journal et `sdk/new/` restent, la prochaine reprise achèvera
            // l'annulation (`recoverInterruptedInstall`).
            if restored {
                discardStaging()
            }
            throw error
        }
        rmdir(stagingURL.path)
        for element in elements {
            try? FileManager.default.removeItem(at: backupURL(element))
        }
    }

    private func writeJournal(_ journal: Journal) throws {
        let temporary = stagingURL.appending(path: ".transaction.tmp")
        try JSONEncoder().encode(journal).write(to: temporary)
        try posix(rename(temporary.path, journalURL.path))
    }

    private func swap(_ element: Element) throws {
        let manager = FileManager.default
        let target = url(element)
        let staged = stagedURL(element)
        let backup = backupURL(element)
        if SDKInspector.existsWithoutFollowing(backup) {
            try manager.removeItem(at: backup)
        }
        if element.isDirectory {
            if SDKInspector.existsWithoutFollowing(target) {
                try posix(rename(target.path, backup.path))
            }
            try posix(rename(staged.path, target.path))
        } else {
            if SDKInspector.existsWithoutFollowing(target) {
                try posix(link(target.path, backup.path))
            }
            try posix(rename(staged.path, target.path))
        }
    }

    /// Annule l'échange d'un élément. Son `.old` est remis à sa place ; si `.old` et l'élément sont deux noms du même
    /// fichier (arrêt entre le lien dur et le renommage), `.old` est seulement retiré : un renommage entre deux noms
    /// d'un même fichier ne change rien. Un élément sans version précédente (`isNew`) déjà en place (plus dans
    /// `sdk/new/`) est retiré. Faux si un renommage échoue.
    @discardableResult
    private func rollBack(_ element: Element, isNew: Bool) -> Bool {
        let manager = FileManager.default
        let target = url(element)
        let backup = backupURL(element)
        guard SDKInspector.existsWithoutFollowing(backup) else {
            if isNew, !SDKInspector.existsWithoutFollowing(stagedURL(element)) {
                try? manager.removeItem(at: target)
            }
            return true
        }
        if element.isDirectory {
            if SDKInspector.existsWithoutFollowing(target) {
                try? manager.removeItem(at: target)
            }
            return restoreRename(backup.path, target.path) == 0
        }
        if Self.sameFile(backup, target) {
            return (try? manager.removeItem(at: backup)) != nil
        }
        return restoreRename(backup.path, target.path) == 0
    }

    /// Reprise d'une installation interrompue (arrêt de l'app, plantage) :
    /// - journal présent : rien n'a été validé ; chaque élément du journal est remis comme avant (`.old` remis,
    ///   élément sans version précédente retiré s'il était déjà en place), puis `sdk/new/` est effacé ;
    /// - `sdk/new/` sans journal : vide, l'installation était validée ; sinon l'échange n'avait pas commencé.
    ///   Dans les deux cas, `sdk/new/` et les `.old` restants sont effacés ;
    /// - le `libdev.dylib.new` laissé par une installation de B1 est effacé.
    /// Faux si un ancien élément n'a pas pu être remis.
    @discardableResult
    func recoverInterruptedInstall() -> Bool {
        let manager = FileManager.default
        if SDKInspector.existsWithoutFollowing(legacyStagingURL) {
            try? manager.removeItem(at: legacyStagingURL)
        }
        if SDKInspector.existsWithoutFollowing(journalURL) {
            let journal = (try? Data(contentsOf: journalURL)).flatMap { try? JSONDecoder().decode(Journal.self, from: $0) }
            let elements = journal.map { $0.elements.compactMap(Element.init(rawValue:)) } ?? Element.allCases
            let nouveaux = journal.map { $0.nouveaux.compactMap(Element.init(rawValue:)) } ?? []
            var restored = true
            for element in elements.reversed() {
                restored = rollBack(element, isNew: nouveaux.contains(element)) && restored
            }
            guard restored else { return false }
            return (try? manager.removeItem(at: stagingURL)) != nil
        }
        if SDKInspector.existsWithoutFollowing(stagingURL) {
            try? manager.removeItem(at: stagingURL)
        }
        for element in Element.allCases where SDKInspector.existsWithoutFollowing(backupURL(element)) {
            // Un `.old` qui est un autre nom du fichier en place est retiré de même.
            try? manager.removeItem(at: backupURL(element))
        }
        return true
    }

    /// Même périphérique et même inode, sans suivre les liens.
    static func sameFile(_ first: URL, _ second: URL) -> Bool {
        var firstInfo = stat()
        var secondInfo = stat()
        guard lstat(first.path, &firstInfo) == 0, lstat(second.path, &secondInfo) == 0 else { return false }
        return firstInfo.st_dev == secondInfo.st_dev && firstInfo.st_ino == secondInfo.st_ino
    }

    private func posix(_ result: Int32) throws {
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func removeQuarantine(_ url: URL) throws {
        if removexattr(url.path, SDKInspector.quarantineAttribute, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// Copie les en-têtes : seulement des dossiers et des fichiers ordinaires (le reste est refusé), sans quarantaine.
    static func copyHeaders(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard SDKInspector.isPlainTree(source), let enumerator = manager.enumerator(atPath: source.path) else {
            throw StagingRejected(reason: SDKRejection.headersNotPlain.message)
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        for case let relative as String in enumerator {
            let from = source.appending(path: relative)
            let to = destination.appending(path: relative)
            let type = (try? manager.attributesOfItem(atPath: from.path))?[.type] as? FileAttributeType
            switch type {
            case .typeDirectory?:
                try manager.createDirectory(at: to, withIntermediateDirectories: false)
            case .typeRegular?:
                try manager.copyItem(at: from, to: to)
                if removexattr(to.path, SDKInspector.quarantineAttribute, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
                    throw CocoaError(.fileWriteNoPermission)
                }
            default:
                throw StagingRejected(reason: SDKRejection.headersNotPlain.message)
            }
        }
    }

    /// Ajoute la sortie de clang++ au journal de compilation, avec la date.
    private func appendToBuildLog(_ output: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: buildLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(buildLog.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let header = "\(Date().formatted(.iso8601)) — compilation d'obsbot-ai en échec\n"
        try? handle.write(contentsOf: Data((header + output + (output.hasSuffix("\n") ? "" : "\n")).utf8))
        try? handle.close()
    }

    /// Le vérificateur réel : obsbot-ai lancé sans argument, avec `DYLD_LIBRARY_PATH` sur le dossier du SDK,
    /// doit afficher son aide et sortir avec le code 3 ; sans SDK chargeable, dyld l'arrête avant (code 134).
    /// L'entrée standard est vide. Au-delà de `timeout`, le processus reçoit SIGTERM ; s'il ne s'arrête pas en
    /// deux secondes, il reçoit SIGKILL.
    public static func obsbotAIVerifier(arguments: [String] = [], timeout: TimeInterval = 10) -> SDKVerifier {
        { executable, sdkDirectory in
            let environment = ProcessInfo.processInfo.environment.merging(["DYLD_LIBRARY_PATH": sdkDirectory.path]) { _, new in new }
            guard let result = ChildProcess.run(executable, arguments: arguments, environment: environment, timeout: timeout) else {
                return false
            }
            return result.exited && result.status == 3
        }
    }
}
