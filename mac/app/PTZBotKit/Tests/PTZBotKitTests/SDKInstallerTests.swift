import Foundation
import Synchronization
import Testing
@testable import PTZBotKit

/// Vérificateur simulé : réponse choisie, appels retenus (exécutable, dossier du SDK).
final class FakeVerifier: Sendable {
    let answer: Mutex<Bool>
    let calls = Mutex<[(executable: URL, directory: URL)]>([])

    init(_ answer: Bool) {
        self.answer = Mutex(answer)
    }

    var verifier: SDKVerifier {
        { [self] executable, directory in
            calls.withLock { $0.append((executable, directory)) }
            return answer.withLock { $0 }
        }
    }

    var directories: [URL] {
        calls.withLock { $0.map(\.directory) }
    }
}

/// Outils de développement simulés : disponibles ou non ; une compilation écrit un faux binaire, ou échoue.
final class FakeToolchain: Toolchain {
    struct Call: Equatable {
        var source: URL
        var includeDirectory: URL
        var libraryDirectory: URL
        var output: URL
    }

    let available: Mutex<Bool>
    /// Sortie de clang++ simulée : la compilation échoue avec elle.
    let failure: Mutex<String?>
    let calls = Mutex<[Call]>([])
    let installRequests = Mutex(0)
    /// Appelé pendant la compilation (pour observer l'état à cet instant).
    let during: Mutex<(@Sendable () -> Void)?> = Mutex(nil)

    init(available: Bool = true, failure: String? = nil) {
        self.available = Mutex(available)
        self.failure = Mutex(failure)
    }

    func isAvailable() -> Bool {
        available.withLock { $0 }
    }

    func compile(source: URL, includeDirectory: URL, libraryDirectory: URL, output: URL) throws(ToolchainError) {
        guard isAvailable() else { throw .unavailable }
        calls.withLock { $0.append(Call(source: source, includeDirectory: includeDirectory, libraryDirectory: libraryDirectory, output: output)) }
        during.withLock { $0 }?()
        if let failure = failure.withLock({ $0 }) {
            throw .compileFailed(output: failure)
        }
        let source = (try? Data(contentsOf: source)) ?? Data()
        try? (Data("binaire de ".utf8) + source).write(to: output)
    }

    func requestInstall() {
        installRequests.withLock { $0 += 1 }
    }

    var compiled: [Call] {
        calls.withLock { $0 }
    }
}

/// Synchronisation simulée : retient, pour chaque fichier synchronisé, ce que `observe` relève à cet instant.
final class FlushSpy: Sendable {
    struct Call: Equatable {
        var name: String
        var stagedStillThere: Bool
        var journalExists: Bool
    }

    private let recorded = Mutex<[Call]>([])
    private let observe: @Sendable (URL) -> Call

    init(observe: @escaping @Sendable (URL) -> Call) {
        self.observe = observe
    }

    var flush: @Sendable (URL) throws -> Void {
        { [self] url in
            let call = observe(url)
            recorded.withLock { $0.append(call) }
        }
    }

    var calls: [Call] {
        recorded.withLock { $0 }
    }
}

/// Un dossier d'essai : `support/sdk/`, la source d'obsbot-ai de l'« app » et le journal.
struct SDKWorld {
    let directory: URL
    let sdk: URL
    let source: URL
    let log: URL

    init() throws {
        directory = try FakeSDK.directory()
        sdk = directory.appending(path: "support/sdk")
        source = try FakeSDK.write(Data("int main() { return 3; } // v1\n".utf8), to: directory.appending(path: "PTZBot.app/Contents/Resources/obsbot-ai.cpp"))
        log = directory.appending(path: "logs/obsbot-ai-compilation.log")
    }

    func installer(_ verifier: FakeVerifier = FakeVerifier(true), toolchain: FakeToolchain = FakeToolchain()) -> SDKInstaller {
        SDKInstaller(sdkDirectory: sdk, sourceURL: source, toolchain: toolchain, verifier: verifier.verifier, buildLog: log)
    }

    /// Un SDK choisi : dossier complet, bibliothèque marquée par `filler`, en quarantaine au besoin.
    func candidate(filler: UInt8 = 1, quarantined: Bool = true) throws -> SDKCandidate {
        let root = directory.appending(path: "choix-\(UUID().uuidString)")
        let library = try FakeSDK.folder(root, library: FakeSDK.thin(FakeSDK.arm64, filler: filler))
        if quarantined {
            FakeSDK.setQuarantine(library)
            FakeSDK.setQuarantine(root.appending(path: "include/dev/devs.hpp"))
        }
        return try SDKInspector.inspect(root)
    }

    /// Une installation déjà faite : bibliothèque, en-têtes, obsbot-ai et empreinte (celle de la source, ou `hash`).
    func installed(filler: UInt8 = 7, hash: String? = nil, installer: SDKInstaller) throws {
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: filler), to: installer.libraryURL)
        try FakeSDK.write(Data("// ancien en-tête\n".utf8), to: installer.headersURL.appending(path: "dev/devs.hpp"))
        try FakeSDK.write(Data("ancien binaire".utf8), to: installer.obsbotAIURL)
        try FakeSDK.write(Data(((hash ?? installer.sourceHash()!) + "\n").utf8), to: installer.hashURL)
    }

    func contents(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Ce qui reste dans `sdk/` en plus des quatre éléments : ni `new/`, ni `.old`.
    func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: sdk.path)
            .filter { !["libdev.dylib", "include", "obsbot-ai", "obsbot-ai.sha256"].contains($0) }
            .sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("SDK : installation et compilation d'obsbot-ai", .french)
struct SDKInstallerTests {
    let world: SDKWorld

    init() throws {
        world = try SDKWorld()
    }

    @Test("Installation : bibliothèque, en-têtes et obsbot-ai compilé en place, empreinte écrite, sans quarantaine, rien de laissé")
    func install() throws {
        defer { world.remove() }
        let verifier = FakeVerifier(true)
        let toolchain = FakeToolchain()
        let installer = world.installer(verifier, toolchain: toolchain)
        let chosen = try world.candidate()
        try installer.install(chosen)
        #expect(world.contents(installer.libraryURL) == world.contents(chosen.path))
        #expect(!FakeSDK.isQuarantined(installer.libraryURL))
        #expect(FakeSDK.isQuarantined(chosen.path))
        #expect(world.contents(installer.headersURL.appending(path: "dev/devs.hpp")) == Data("// en-tête inventé\n".utf8))
        #expect(world.contents(installer.headersURL.appending(path: "util/comm.hpp")) != nil)
        #expect(!FakeSDK.isQuarantined(installer.headersURL.appending(path: "dev/devs.hpp")))
        #expect(world.contents(installer.obsbotAIURL)?.starts(with: Data("binaire de ".utf8)) == true)
        #expect(world.contents(installer.hashURL) == Data((installer.sourceHash()! + "\n").utf8))
        // Compilé dans sdk/new/ avec les copies, puis vérifié là, avant l'échange.
        let staging = world.sdk.appending(path: "new")
        #expect(toolchain.compiled == [FakeToolchain.Call(
            source: world.source,
            includeDirectory: staging.appending(path: "include"),
            libraryDirectory: staging,
            output: staging.appending(path: "obsbot-ai")
        )])
        #expect(verifier.calls.withLock { $0.map(\.executable) } == [staging.appending(path: "obsbot-ai")])
        #expect(verifier.directories == [staging])
        #expect(try world.leftovers().isEmpty)
        #expect(installer.status() == .ready)
    }

    @Test("Empreinte : SHA-256 de la source, en hexadécimal ; nil sans source")
    func sourceHash() throws {
        defer { world.remove() }
        let installer = world.installer()
        try FakeSDK.write(Data("abc".utf8), to: world.source)
        // Vecteur de test de la norme FIPS 180-2 pour « abc ».
        #expect(installer.sourceHash() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try FileManager.default.removeItem(at: world.source)
        #expect(installer.sourceHash() == nil)
    }

    @Test("Remplacement : les trois éléments neufs prennent la place des anciens")
    func replace() throws {
        defer { world.remove() }
        let installer = world.installer()
        try world.installed(hash: "ancienne", installer: installer)
        let chosen = try world.candidate(filler: 2)
        try installer.install(chosen)
        #expect(world.contents(installer.libraryURL) == world.contents(chosen.path))
        #expect(world.contents(installer.headersURL.appending(path: "dev/devs.hpp")) == Data("// en-tête inventé\n".utf8))
        #expect(world.contents(installer.obsbotAIURL) != Data("ancien binaire".utf8))
        #expect(world.contents(installer.hashURL) == Data((installer.sourceHash()! + "\n").utf8))
        #expect(try world.leftovers().isEmpty)
    }

    /// L'ancienne installation, intacte.
    private func expectOldKept(_ installer: SDKInstaller) throws {
        #expect(world.contents(installer.libraryURL) == FakeSDK.thin(FakeSDK.arm64, filler: 7))
        #expect(world.contents(installer.headersURL.appending(path: "dev/devs.hpp")) == Data("// ancien en-tête\n".utf8))
        #expect(world.contents(installer.obsbotAIURL) == Data("ancien binaire".utf8))
        #expect(world.contents(installer.hashURL) == Data("ancienne\n".utf8))
        #expect(try world.leftovers().isEmpty)
    }

    @Test("Compilation en échec : l'ancien SDK et l'ancien obsbot-ai restent, sortie de clang++ au journal")
    func compileFailure() throws {
        defer { world.remove() }
        let verifier = FakeVerifier(true)
        let installer = world.installer(verifier, toolchain: FakeToolchain(failure: "main.cpp:3: error: inventée"))
        try world.installed(hash: "ancienne", installer: installer)
        #expect(throws: SDKInstallError.compileFailed) { try installer.install(try world.candidate()) }
        try expectOldKept(installer)
        #expect(verifier.calls.withLock { $0 }.isEmpty)
        let log = try String(contentsOf: world.log, encoding: .utf8)
        #expect(log.contains("compilation d'obsbot-ai en échec"))
        #expect(log.contains("main.cpp:3: error: inventée"))
        #expect(SDKInstallError.compileFailed.message.hasPrefix("La compilation d'obsbot-ai a échoué : l'ancien SDK est conservé."))
    }

    @Test("Outils absents : refus avant toute copie, l'ancien SDK reste")
    func toolsMissing() throws {
        defer { world.remove() }
        let toolchain = FakeToolchain(available: false)
        let installer = world.installer(toolchain: toolchain)
        try world.installed(hash: "ancienne", installer: installer)
        #expect(throws: SDKInstallError.toolsMissing) { try installer.install(try world.candidate()) }
        try expectOldKept(installer)
        #expect(toolchain.compiled.isEmpty)
    }

    @Test("Vérification de chargement en échec : rien n'est échangé, l'ancien SDK reste")
    func loadCheckFailure() throws {
        defer { world.remove() }
        let installer = world.installer(FakeVerifier(false))
        try world.installed(hash: "ancienne", installer: installer)
        #expect(throws: SDKInstallError.unloadable) { try installer.install(try world.candidate()) }
        try expectOldKept(installer)
    }

    @Test("Première installation en échec : sdk/ reste vide")
    func firstInstallFailure() throws {
        defer { world.remove() }
        let installer = world.installer(FakeVerifier(false))
        #expect(throws: SDKInstallError.unloadable) { try installer.install(try world.candidate()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: world.sdk.path).isEmpty)
    }

    @Test("Échange interrompu par une erreur (obsbot-ai en place est un dossier) : tout est remis comme avant")
    func swapRollback() throws {
        defer { world.remove() }
        let installer = world.installer()
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 7), to: installer.libraryURL)
        try FakeSDK.write(Data("// ancien en-tête\n".utf8), to: installer.headersURL.appending(path: "dev/devs.hpp"))
        // Un dossier à la place d'obsbot-ai : le lien dur `.old` échoue après l'échange de la bibliothèque et des en-têtes.
        try FakeSDK.write(Data("x".utf8), to: installer.obsbotAIURL.appending(path: "bloque"))
        #expect(throws: SDKInstallError.self) { try installer.install(try world.candidate()) }
        #expect(world.contents(installer.libraryURL) == FakeSDK.thin(FakeSDK.arm64, filler: 7))
        #expect(world.contents(installer.headersURL.appending(path: "dev/devs.hpp")) == Data("// ancien en-tête\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: installer.hashURL.path))
        #expect(try world.leftovers().isEmpty)
    }

    @Test("Annulation qui échoue (un ancien élément ne se remet pas) : journal et sdk/new/ gardés, la reprise suivante achève")
    func failedRollbackKeepsJournal() throws {
        defer { world.remove() }
        var installer = world.installer()
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 7), to: installer.libraryURL)
        try FakeSDK.write(Data("// ancien en-tête\n".utf8), to: installer.headersURL.appending(path: "dev/devs.hpp"))
        try FakeSDK.write(Data("x".utf8), to: installer.obsbotAIURL.appending(path: "bloque"))
        // Le renommage qui remet les anciens éléments échoue (disque plein, volume démonté…).
        installer.restoreRename = { _, _ in -1 }
        #expect(throws: SDKInstallError.self) { try installer.install(try world.candidate()) }
        #expect(FileManager.default.fileExists(atPath: installer.journalURL.path))
        #expect(FileManager.default.fileExists(atPath: installer.backupURL(.library).path))
        #expect(world.contents(installer.libraryURL) != FakeSDK.thin(FakeSDK.arm64, filler: 7))
        // Plus tard, le renommage remarche : la reprise remet tout comme avant d'après le journal.
        installer.restoreRename = { rename($0, $1) }
        #expect(installer.recoverInterruptedInstall())
        #expect(world.contents(installer.libraryURL) == FakeSDK.thin(FakeSDK.arm64, filler: 7))
        #expect(world.contents(installer.headersURL.appending(path: "dev/devs.hpp")) == Data("// ancien en-tête\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: installer.stagingURL.path))
        #expect(try world.leftovers().isEmpty)
    }

    @Test("Sans en-têtes, sans source, sans arm64 : refus, rien de copié ni compilé")
    func refusals() throws {
        defer { world.remove() }
        let toolchain = FakeToolchain()
        let installer = world.installer(toolchain: toolchain)
        var chosen = try world.candidate()
        chosen.includeDirectory = nil
        #expect(throws: SDKInstallError.headersMissing) { try installer.install(chosen) }
        #expect(SDKInstallError.headersMissing.message == "Choisissez l'archive ou le dossier du SDK : ses en-têtes sont nécessaires.")
        var intel = try world.candidate()
        intel.architectures = ["x86_64"]
        #expect(throws: SDKInstallError.incompatible) { try installer.install(intel) }
        try FileManager.default.removeItem(at: world.source)
        #expect(throws: SDKInstallError.sourceMissing) { try installer.install(try world.candidate()) }
        #expect(toolchain.compiled.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: world.sdk.path))
    }

    @Test("Candidat devenu un lien symbolique entre l'examen et l'installation : refusé, l'ancien gardé")
    func symlinkAtInstall() throws {
        defer { world.remove() }
        let toolchain = FakeToolchain()
        let installer = world.installer(toolchain: toolchain)
        try world.installed(hash: "ancienne", installer: installer)
        let chosen = try world.candidate(quarantined: false)
        let real = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 2), to: world.directory.appending(path: "ailleurs.dylib"))
        try FileManager.default.removeItem(at: chosen.path)
        try FileManager.default.createSymbolicLink(at: chosen.path, withDestinationURL: real)
        #expect(throws: SDKInstallError.copyFailed("la copie n'est pas une bibliothèque arm64 ordinaire.")) { try installer.install(chosen) }
        try expectOldKept(installer)
        #expect(toolchain.compiled.isEmpty)
    }

    @Test("En-têtes changés en lien symbolique entre l'examen et l'installation : refusés, l'ancien gardé")
    func headerSymlinkAtInstall() throws {
        defer { world.remove() }
        let installer = world.installer()
        try world.installed(hash: "ancienne", installer: installer)
        let chosen = try world.candidate(quarantined: false)
        let include = try #require(chosen.includeDirectory)
        try FileManager.default.createSymbolicLink(at: include.appending(path: "dev/lien.hpp"), withDestinationURL: world.source)
        #expect(throws: SDKInstallError.copyFailed(SDKRejection.headersNotPlain.message)) { try installer.install(chosen) }
        try expectOldKept(installer)
    }

    // MARK: - Reprise après un arrêt

    @Test("Arrêt avant la validation (sdk/new/ encore là) : chaque .old est remis, sdk/new/ effacé")
    func recoveryBeforeCommit() throws {
        defer { world.remove() }
        let installer = world.installer()
        try world.installed(hash: "ancienne", installer: installer)
        try writeJournal(installer, elements: [.library, .headers, .binary, .hash], nouveaux: [])
        // Échange à moitié fait : bibliothèque nouvelle (ancienne en .old), en-têtes renommés en .old et pas remplacés.
        try FakeSDK.write(Data("nouveau binaire".utf8), to: world.sdk.appending(path: "new/obsbot-ai"))
        try FileManager.default.linkItem(at: installer.libraryURL, to: installer.backupURL(.library))
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 9), to: world.sdk.appending(path: "nouvelle"))
        #expect(rename(world.sdk.appending(path: "nouvelle").path, installer.libraryURL.path) == 0)
        #expect(rename(installer.headersURL.path, installer.backupURL(.headers).path) == 0)
        _ = installer.status()
        try expectOldKept(installer)
    }

    @Test("Arrêt entre le lien dur et le renommage (.old et l'élément sont un même fichier) : .old retiré")
    func recoverySameInode() throws {
        defer { world.remove() }
        let installer = world.installer()
        try world.installed(hash: "ancienne", installer: installer)
        try writeJournal(installer, elements: [.library, .headers, .binary, .hash], nouveaux: [])
        try FileManager.default.linkItem(at: installer.libraryURL, to: installer.backupURL(.library))
        try FileManager.default.linkItem(at: installer.obsbotAIURL, to: installer.backupURL(.binary))
        #expect(installer.recoverInterruptedInstall())
        try expectOldKept(installer)
    }

    /// Le journal d'un échange en cours, comme `commit` l'écrit.
    private func writeJournal(_ installer: SDKInstaller, elements: [SDKInstaller.Element], nouveaux: [SDKInstaller.Element]) throws {
        let journal = SDKInstaller.Journal(elements: elements.map(\.rawValue), nouveaux: nouveaux.map(\.rawValue))
        try FakeSDK.write(try JSONEncoder().encode(journal), to: installer.journalURL)
    }

    @Test("Arrêt pendant la migration depuis B1 (libdev.dylib seul) : la bibliothèque est remise, les éléments neufs déjà en place retirés")
    func recoveryFromB1State() throws {
        defer { world.remove() }
        let installer = world.installer()
        let b1 = FakeSDK.thin(FakeSDK.arm64, filler: 5)
        try FakeSDK.write(b1, to: installer.libraryURL)
        // Préparés : tout ; journal : en-têtes, obsbot-ai et empreinte sans version précédente.
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 6), to: installer.stagedURL(.library))
        try FakeSDK.write(Data("// en-tête".utf8), to: installer.stagedURL(.headers).appending(path: "dev/devs.hpp"))
        try FakeSDK.write(Data("binaire".utf8), to: installer.stagedURL(.binary))
        try FakeSDK.write(Data("empreinte".utf8), to: installer.stagedURL(.hash))
        try writeJournal(installer, elements: [.library, .headers, .binary, .hash], nouveaux: [.headers, .binary, .hash])
        // Arrêt après l'échange de la bibliothèque et des en-têtes, avant obsbot-ai.
        try FileManager.default.linkItem(at: installer.libraryURL, to: installer.backupURL(.library))
        #expect(rename(installer.stagedURL(.library).path, installer.libraryURL.path) == 0)
        #expect(rename(installer.stagedURL(.headers).path, installer.headersURL.path) == 0)
        #expect(installer.recoverInterruptedInstall())
        #expect(world.contents(installer.libraryURL) == b1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: world.sdk.path) == ["libdev.dylib"])
        #expect(installer.status() == .incomplete)
    }

    @Test("sdk/new/ vide sans journal : l'installation était validée ; les .old et le libdev.dylib.new de B1 sont effacés")
    func emptyStagingIsCommitted() throws {
        defer { world.remove() }
        let installer = world.installer()
        try world.installed(installer: installer)
        try FileManager.default.createDirectory(at: world.sdk.appending(path: "new"), withIntermediateDirectories: true)
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 3), to: installer.backupURL(.library))
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 4), to: installer.legacyStagingURL)
        #expect(installer.recoverInterruptedInstall())
        #expect(world.contents(installer.libraryURL) == FakeSDK.thin(FakeSDK.arm64, filler: 7))
        #expect(try world.leftovers().isEmpty)
    }

    @Test("Préparation sans journal (arrêt avant l'échange) : sdk/new/ effacé, rien d'échangé")
    func stagingWithoutJournal() throws {
        defer { world.remove() }
        let installer = world.installer()
        try world.installed(hash: "ancienne", installer: installer)
        try FakeSDK.write(Data("binaire".utf8), to: installer.stagedURL(.binary))
        _ = installer.status()
        try expectOldKept(installer)
    }

    @Test("Le journal est écrit avant le premier échange et retiré à la validation")
    func journalDuringCommit() throws {
        defer { world.remove() }
        let installer = world.installer()
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 5), to: installer.libraryURL)
        try FakeSDK.write(Data("binaire".utf8), to: installer.stagedURL(.binary))
        try FakeSDK.write(Data("empreinte".utf8), to: installer.stagedURL(.hash))
        try installer.commit([.binary, .hash])
        #expect(!FileManager.default.fileExists(atPath: installer.journalURL.path))
        #expect(!FileManager.default.fileExists(atPath: installer.stagingURL.path))
        #expect(world.contents(installer.obsbotAIURL) == Data("binaire".utf8))
        #expect(try world.leftovers().isEmpty)
    }

    @Test("Durabilité : les fichiers préparés, puis le journal temporaire, puis le journal sont synchronisés avant le premier échange")
    func flushOrder() throws {
        defer { world.remove() }
        var installer = world.installer()
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 5), to: installer.libraryURL)
        try FakeSDK.write(Data("binaire".utf8), to: installer.stagedURL(.binary))
        try FakeSDK.write(Data("empreinte".utf8), to: installer.stagedURL(.hash))
        let staged = installer.stagedURL(.binary)
        let journal = installer.journalURL
        let spy = FlushSpy { url in
            // À chaque synchronisation : le fichier préparé n'a pas encore été échangé, et le journal n'existe
            // qu'une fois le renommage fait.
            FlushSpy.Call(name: url.lastPathComponent,
                          stagedStillThere: FileManager.default.fileExists(atPath: staged.path),
                          journalExists: FileManager.default.fileExists(atPath: journal.path))
        }
        installer.flush = spy.flush
        try installer.commit([.binary, .hash])
        #expect(spy.calls.map(\.name) == ["obsbot-ai", "obsbot-ai.sha256", ".transaction.tmp", ".transaction"])
        #expect(spy.calls.map(\.stagedStillThere) == [true, true, true, true])
        #expect(spy.calls.map(\.journalExists) == [false, false, false, true])
        #expect(world.contents(installer.obsbotAIURL) == Data("binaire".utf8))
        #expect(try world.leftovers().isEmpty)
    }

    @Test("Durabilité : seuls les fichiers de l'échange sont synchronisés (pas le dossier des en-têtes)")
    func flushFilesOnly() throws {
        defer { world.remove() }
        var installer = world.installer()
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 5), to: installer.stagedURL(.library))
        try FakeSDK.write(Data("// en-tête\n".utf8), to: installer.stagedURL(.headers).appending(path: "dev/devs.hpp"))
        try FakeSDK.write(Data("binaire".utf8), to: installer.stagedURL(.binary))
        try FakeSDK.write(Data("empreinte".utf8), to: installer.stagedURL(.hash))
        let spy = FlushSpy { FlushSpy.Call(name: $0.lastPathComponent, stagedStillThere: true, journalExists: false) }
        installer.flush = spy.flush
        try installer.commit([.library, .headers, .binary, .hash])
        #expect(spy.calls.map(\.name) == ["libdev.dylib", "obsbot-ai", "obsbot-ai.sha256", ".transaction.tmp", ".transaction"])
    }

    @Test("Synchronisation en échec (fichier préparé, journal temporaire ou journal) : chemin d'échec normal, l'ancien SDK reste",
          arguments: ["libdev.dylib", "obsbot-ai.sha256", ".transaction.tmp", ".transaction"])
    func flushFailure(failing: String) throws {
        defer { world.remove() }
        var installer = world.installer()
        try world.installed(hash: "ancienne", installer: installer)
        installer.flush = { url in
            if url.lastPathComponent == failing { throw POSIXError(.EIO) }
        }
        #expect(throws: SDKInstallError.self) { try installer.install(try world.candidate()) }
        try expectOldKept(installer)
    }

    @Test("Synchronisation réelle : un fichier est synchronisé, un fichier absent est refusé")
    func realFlush() throws {
        defer { world.remove() }
        let file = try FakeSDK.write(Data("contenu".utf8), to: world.directory.appending(path: "a-synchroniser"))
        try SDKInstaller.flushToDisk(file)
        #expect(throws: POSIXError.self) { try SDKInstaller.flushToDisk(world.directory.appending(path: "absent")) }
    }

    @Test("Arrêt après la validation (sdk/new/ retiré) : les nouveaux éléments restent, les .old sont effacés")
    func recoveryAfterCommit() throws {
        defer { world.remove() }
        let installer = world.installer()
        try world.installed(installer: installer)
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64, filler: 3), to: installer.backupURL(.library))
        try FakeSDK.write(Data("// vieil en-tête".utf8), to: installer.backupURL(.headers).appending(path: "dev/devs.hpp"))
        #expect(installer.status() == .ready)
        #expect(world.contents(installer.libraryURL) == FakeSDK.thin(FakeSDK.arm64, filler: 7))
        #expect(try world.leftovers().isEmpty)
    }

    @Test("status() pendant une installation : sdk/new/ n'est pas repris ; une seconde installation est refusée")
    func statusDuringInstall() throws {
        defer { world.remove() }
        let toolchain = FakeToolchain()
        let installer = world.installer(toolchain: toolchain)
        let next = try world.candidate(filler: 4)
        let seen = Mutex<(installing: Bool, stagingKept: Bool, second: SDKInstallError?)?>(nil)
        let staging = world.sdk.appending(path: "new")
        // Pendant la compilation, sdk/new/ existe : le panneau demande l'état à cet instant.
        toolchain.during.withLock {
            $0 = {
                guard seen.withLock({ $0 }) == nil else { return }
                _ = installer.status()
                _ = installer.needsRecompile()
                var second: SDKInstallError?
                do {
                    try installer.install(next)
                } catch let error as SDKInstallError {
                    second = error
                } catch {}
                seen.withLock { $0 = (installer.isInstalling, FileManager.default.fileExists(atPath: staging.path), second) }
            }
        }
        try installer.install(try world.candidate(filler: 3))
        let observed = try #require(seen.withLock { $0 })
        #expect(observed.installing)
        #expect(observed.stagingKept)
        #expect(observed.second == .copyFailed("une installation est déjà en cours."))
        #expect(!installer.isInstalling)
        #expect(world.contents(installer.libraryURL) == FakeSDK.thin(FakeSDK.arm64, filler: 3))
        #expect(try world.leftovers().isEmpty)
    }

    @Test("Reprise et début d'installation exclusifs : begin() attend la fin de la reprise")
    func recoveryHoldsLock() {
        defer { world.remove() }
        let progress = InstallProgress()
        let order = Mutex<[String]>([])
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            progress.runIfIdle {
                order.withLock { $0.append("reprise") }
                entered.signal()
                release.wait()
                order.withLock { $0.append("reprise terminée") }
            }
            group.leave()
        }
        entered.wait()
        group.enter()
        DispatchQueue.global().async {
            _ = progress.begin()
            order.withLock { $0.append("installation") }
            group.leave()
        }
        // Laisse à `begin()` le temps de passer s'il n'était pas bloqué : l'ordre doit rester celui-ci.
        Thread.sleep(forTimeInterval: 0.2)
        release.signal()
        group.wait()
        #expect(order.withLock { $0 } == ["reprise", "reprise terminée", "installation"])
    }

    // MARK: - Recompilation après une mise à jour de l'app (§ 6.3)

    @Test("Source changée : obsbot-ai recompilé avec sdk/include et sdk/libdev.dylib, empreinte mise à jour")
    func recompile() throws {
        defer { world.remove() }
        let verifier = FakeVerifier(true)
        let toolchain = FakeToolchain()
        let installer = world.installer(verifier, toolchain: toolchain)
        try world.installed(hash: "ancienne", installer: installer)
        #expect(installer.needsRecompile())
        #expect(try installer.recompileIfNeeded())
        let staging = world.sdk.appending(path: "new")
        #expect(toolchain.compiled == [FakeToolchain.Call(
            source: world.source,
            includeDirectory: installer.headersURL,
            libraryDirectory: world.sdk,
            output: staging.appending(path: "obsbot-ai")
        )])
        #expect(verifier.calls.withLock { $0.map(\.executable) } == [staging.appending(path: "obsbot-ai")])
        #expect(verifier.directories == [world.sdk])
        #expect(world.contents(installer.obsbotAIURL)?.starts(with: Data("binaire de ".utf8)) == true)
        #expect(world.contents(installer.hashURL) == Data((installer.sourceHash()! + "\n").utf8))
        #expect(world.contents(installer.libraryURL) == FakeSDK.thin(FakeSDK.arm64, filler: 7))
        #expect(try world.leftovers().isEmpty)
        #expect(!installer.needsRecompile())
        #expect(try !installer.recompileIfNeeded())
        #expect(toolchain.compiled.count == 1)
        #expect(installer.status() == .ready)
    }

    @Test("Même empreinte : rien n'est recompilé ; obsbot-ai absent avec en-têtes : recompilé")
    func recompileOnlyWhenNeeded() throws {
        defer { world.remove() }
        let toolchain = FakeToolchain()
        let installer = world.installer(toolchain: toolchain)
        try world.installed(installer: installer)
        #expect(!installer.needsRecompile())
        #expect(try !installer.recompileIfNeeded())
        try FileManager.default.removeItem(at: installer.obsbotAIURL)
        #expect(installer.needsRecompile())
        #expect(try installer.recompileIfNeeded())
        #expect(toolchain.compiled.count == 1)
    }

    @Test("Recompilation sans outils : l'ancien obsbot-ai reste en service ; « Outils de développement requis »")
    func recompileWithoutTools() throws {
        defer { world.remove() }
        let toolchain = FakeToolchain(available: false)
        let installer = world.installer(toolchain: toolchain)
        try world.installed(hash: "ancienne", installer: installer)
        #expect(throws: SDKInstallError.toolsMissing) { try installer.recompileIfNeeded() }
        try expectOldKept(installer)
        #expect(installer.status() == .toolsRequired(fallback: true))
        toolchain.available.withLock { $0 = true }
        #expect(try installer.recompileIfNeeded())
        #expect(installer.status() == .ready)
    }

    @Test("Recompilation en échec : l'ancien obsbot-ai reste, journal, état « compilation impossible »")
    func recompileFailure() throws {
        defer { world.remove() }
        let installer = world.installer(toolchain: FakeToolchain(failure: "erreur inventée"))
        try world.installed(hash: "ancienne", installer: installer)
        #expect(throws: SDKInstallError.compileFailed) { try installer.recompileIfNeeded() }
        try expectOldKept(installer)
        #expect(try String(contentsOf: world.log, encoding: .utf8).contains("erreur inventée"))
        #expect(installer.status() == .compileFailed(fallback: true))
    }

    @Test("Journal de compilation : seul le dernier échec est gardé")
    func buildLogKeepsLastFailure() throws {
        defer { world.remove() }
        let toolchain = FakeToolchain(failure: "premier échec inventé")
        let installer = world.installer(toolchain: toolchain)
        try world.installed(hash: "ancienne", installer: installer)
        #expect(throws: SDKInstallError.compileFailed) { try installer.recompileIfNeeded() }
        toolchain.failure.withLock { $0 = "second échec inventé" }
        #expect(throws: SDKInstallError.compileFailed) { try installer.recompileIfNeeded() }
        let log = try String(contentsOf: world.log, encoding: .utf8)
        #expect(log.contains("second échec inventé"))
        #expect(!log.contains("premier échec inventé"))
        #expect(log.components(separatedBy: "compilation d'obsbot-ai en échec").count == 2)
    }

    @Test("Nouvel obsbot-ai qui ne charge pas le SDK : l'ancien reste")
    func recompileUnloadable() throws {
        defer { world.remove() }
        let verifier = FakeVerifier(false)
        let installer = world.installer(verifier)
        try world.installed(hash: "ancienne", installer: installer)
        #expect(throws: SDKInstallError.unloadable) { try installer.recompileIfNeeded() }
        try expectOldKept(installer)
    }

    // MARK: - États (§ 6.4)

    @Test("États : absent, incompatible, à compléter, source absente, outils requis, prêt, ne se charge pas, en quarantaine")
    func status() throws {
        defer { world.remove() }
        let loads = FakeVerifier(true)
        let fails = FakeVerifier(false)
        let toolchain = FakeToolchain(available: false)
        let ok = world.installer(loads, toolchain: toolchain)
        let ko = world.installer(fails, toolchain: toolchain)
        #expect(ok.status() == .absent)
        try FakeSDK.write(FakeSDK.thin(FakeSDK.x86_64), to: ok.libraryURL)
        #expect(ok.status() == .incompatible)
        // Le SDK de B1 (libdev.dylib seul) : à compléter depuis l'archive ou le dossier.
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: ok.libraryURL)
        #expect(ok.status() == .incomplete)
        // En-têtes sans obsbot-ai, outils absents : rien ne peut tourner.
        try FakeSDK.write(Data("// en-tête".utf8), to: ok.headersURL.appending(path: "dev/devs.hpp"))
        #expect(ok.status() == .toolsRequired(fallback: false))
        toolchain.available.withLock { $0 = true }
        #expect(ok.status() == .compileFailed(fallback: false))
        try FakeSDK.write(Data("binaire".utf8), to: ok.obsbotAIURL)
        try FakeSDK.write(Data((ok.sourceHash()! + "\n").utf8), to: ok.hashURL)
        #expect(ok.status() == .ready)
        #expect(ko.status() == .unloadable)
        FakeSDK.setQuarantine(ok.libraryURL)
        #expect(ok.status() == .ready)
        #expect(ko.status() == .quarantined)
        try FileManager.default.removeItem(at: world.source)
        #expect(ok.status() == .sourceMissing)
    }

    @Test("Suivi IA utilisable : prêt, ou ancien obsbot-ai encore en service")
    func aiUsable() {
        #expect(SDKStatus.ready.aiUsable)
        #expect(SDKStatus.toolsRequired(fallback: true).aiUsable)
        #expect(SDKStatus.compileFailed(fallback: true).aiUsable)
        #expect(!SDKStatus.toolsRequired(fallback: false).aiUsable)
        #expect(!SDKStatus.incomplete.aiUsable)
        #expect(!SDKStatus.recompiling.aiUsable)
        #expect(!SDKStatus.absent.aiUsable)
        world.remove()
    }

    // MARK: - Processus réels

    @Test("Vérificateur réel : code 3 attendu ; autre code, signal ou délai dépassé : refusé")
    func obsbotAIVerifier() {
        defer { world.remove() }
        let sh = URL(fileURLWithPath: "/bin/sh")
        let sdk = world.sdk
        #expect(SDKInstaller.obsbotAIVerifier(arguments: ["-c", "exit 3"])(sh, sdk))
        #expect(!SDKInstaller.obsbotAIVerifier(arguments: ["-c", "exit 0"])(sh, sdk))
        #expect(!SDKInstaller.obsbotAIVerifier(arguments: ["-c", "kill -ABRT $$"])(sh, sdk))
        #expect(!SDKInstaller.obsbotAIVerifier(arguments: ["-c", "exec sleep 5"], timeout: 0.3)(sh, sdk))
        #expect(!SDKInstaller.obsbotAIVerifier()(URL(fileURLWithPath: "/nonexistent/obsbot-ai"), sdk))
        // L'entrée standard est vide : une lecture sur stdin rend la main aussitôt (sinon le délai de 5 s tombe).
        #expect(SDKInstaller.obsbotAIVerifier(arguments: ["-c", "read ligne; exit 3"], timeout: 5)(sh, sdk))
        // DYLD_LIBRARY_PATH : /bin/sh, protégé par le système, ne le reçoit pas ; voir la compilation réelle.
    }

    @Test("Délai dépassé : tout le groupe de processus est arrêté, petits-enfants compris (clang -cc1, ld)")
    func processGroupKilled() throws {
        defer { world.remove() }
        try FileManager.default.createDirectory(at: world.directory, withIntermediateDirectories: true)
        let pidFile = world.directory.appending(path: "petit-enfant.pid")
        let result = ChildProcess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & echo $! > '\(pidFile.path)'; wait"],
            timeout: 0.5
        )
        #expect(result?.timedOut == true)
        #expect(result?.exited == false)
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchild = try #require(pid_t(text))
        // Le petit-enfant (rattaché à launchd une fois sh arrêté) a reçu le signal du groupe.
        var gone = false
        for _ in 0..<50 {
            if kill(grandchild, 0) != 0, errno == ESRCH {
                gone = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(gone)
        // Code de sortie et sortie recueillie.
        let echo = ChildProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo bonjour; exit 4"], timeout: 5, captureOutput: true)
        #expect(echo?.exited == true)
        #expect(echo?.status == 4)
        #expect(echo?.output == "bonjour\n")
    }

    @Test("Outils réels absents (xcode-select introuvable) : indisponibles, compilation refusée sans lancer xcrun")
    func systemToolchainUnavailable() throws {
        defer { world.remove() }
        let missing = SystemToolchain(
            xcodeSelect: URL(fileURLWithPath: "/nonexistent/xcode-select"),
            xcrun: URL(fileURLWithPath: "/nonexistent/xcrun"),
            timeout: 5
        )
        #expect(!missing.isAvailable())
        #expect(throws: ToolchainError.unavailable) {
            try missing.compile(source: world.source, includeDirectory: world.sdk, libraryDirectory: world.sdk, output: world.sdk.appending(path: "x"))
        }
    }

    /// Les outils d'Apple de ce Mac : `xcode-select -p` réussit.
    static let toolsInstalled = SystemToolchain.system().isAvailable()

    @Test(
        "Compilation réelle : une petite bibliothèque libdev et un main lié par -ldev, sans chemin de recherche ; chargé par DYLD_LIBRARY_PATH",
        .enabled(if: toolsInstalled)
    )
    func realCompile() throws {
        defer { world.remove() }
        let toolchain = SystemToolchain.system()
        let sdk = world.directory.appending(path: "faux-sdk")
        let include = sdk.appending(path: "include")
        try FakeSDK.write(Data("int obsbot_essai();\n".utf8), to: include.appending(path: "dev/devs.hpp"))
        let librarySource = try FakeSDK.write(Data("int obsbot_essai() { return 3; }\n".utf8), to: world.directory.appending(path: "lib.cpp"))
        // La bibliothèque d'essai, nommée @rpath/libdev.dylib comme celle d'OBSBOT.
        let built = ChildProcess.run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["clang++", "-dynamiclib", "-arch", "arm64", "-install_name", "@rpath/libdev.dylib",
                        "-o", sdk.appending(path: "libdev.dylib").path, librarySource.path],
            timeout: 120
        )
        try #require(built?.exited == true && built?.status == 0)
        let main = try FakeSDK.write(
            Data("#include <dev/devs.hpp>\nint main(int argc, char **) { return argc == 1 ? obsbot_essai() : 0; }\n".utf8),
            to: world.directory.appending(path: "main.cpp")
        )
        let output = world.directory.appending(path: "obsbot-ai")
        try toolchain.compile(source: main, includeDirectory: include, libraryDirectory: sdk, output: output)
        #expect(SDKInspector.isRegularFile(output))
        // Sans DYLD_LIBRARY_PATH vers le SDK, dyld ne trouve pas libdev.dylib ; avec, le code 3.
        #expect(!SDKInstaller.obsbotAIVerifier()(output, world.directory.appending(path: "vide")))
        #expect(SDKInstaller.obsbotAIVerifier()(output, sdk))
        // Une source fausse : échec, avec la sortie de clang++.
        let broken = try FakeSDK.write(Data("pas du C++\n".utf8), to: world.directory.appending(path: "faux.cpp"))
        do {
            try toolchain.compile(source: broken, includeDirectory: include, libraryDirectory: sdk, output: world.directory.appending(path: "faux"))
            Issue.record("la compilation aurait dû échouer")
        } catch {
            guard case let .compileFailed(text) = error else {
                Issue.record("motif inattendu : \(error)")
                return
            }
            #expect(text.contains("error"))
        }
    }
}
