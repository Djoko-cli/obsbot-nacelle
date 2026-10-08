import Foundation
import Synchronization
import Testing
@testable import PTZBotKit

/// `launchctl` simulé : l'agent reste chargé `pollsBeforeUnload` vérifications après le `bootout`.
final class FakeLaunchctl: Launchctl {
    struct Failure: LocalizedError {
        var errorDescription: String? { "code 5" }
    }

    struct State {
        var loaded = false
        var pollsBeforeUnload = 0
        var bootoutFails = false
        /// bootout échoue, mais l'agent s'arrête quand même.
        var unloadsDespiteFailure = false
        var bootouts = 0
    }

    let state = Mutex(State())

    func isLoaded(label: String) -> Bool {
        state.withLock { state in
            guard state.loaded else { return false }
            if state.bootouts > 0 {
                if state.pollsBeforeUnload == 0 {
                    state.loaded = false
                    return false
                }
                state.pollsBeforeUnload -= 1
            }
            return true
        }
    }

    func bootout(label: String) throws {
        try state.withLock { state in
            #expect(label == LegacyAgent.label)
            if state.bootoutFails {
                if state.unloadsDespiteFailure {
                    state.loaded = false
                }
                throw Failure()
            }
            state.bootouts += 1
        }
    }
}

/// Corbeille simulée : déplace dans un dossier du test, ou échoue pour les chemins choisis.
final class FakeTrash: Trash {
    struct Failure: LocalizedError {
        var errorDescription: String? { "refusé" }
    }

    let directory: URL
    let failing: Set<String>
    let trashed = Mutex<[String]>([])

    init(directory: URL, failing: Set<String> = []) {
        self.directory = directory
        self.failing = failing
    }

    func trash(_ url: URL) throws {
        guard !failing.contains(url.lastPathComponent) else { throw Failure() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: directory.appending(path: url.lastPathComponent))
        trashed.withLock { $0.append(url.lastPathComponent) }
    }
}

/// Attente simulée : le temps attendu est seulement compté.
final class FakeSleeper: Sendable {
    let slept = Mutex<TimeInterval>(0)
}

@Suite("Migration depuis l'ancienne installation", .french)
struct LegacyAgentTests {
    let root: URL
    let agents: URL
    let support: URL
    let launchctl = FakeLaunchctl()
    let sleeper = FakeSleeper()

    init() throws {
        root = try FakeSDK.directory()
        agents = root.appending(path: "LaunchAgents")
        support = root.appending(path: "ObsbotNacelle")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    }

    private func agent(trash: FakeTrash? = nil) -> LegacyAgent {
        // Jamais la fabrique system() : vrais LaunchAgents, launchctl et corbeille.
        let sleeper = sleeper
        return LegacyAgent(
            launchAgentsDirectory: agents,
            supportDirectory: support,
            launchctl: launchctl,
            trash: trash ?? FakeTrash(directory: root.appending(path: "Trash")),
            sleep: { delay in sleeper.slept.withLock { $0 += delay } }
        )
    }

    /// L'installation actuelle : plist, binaires, SDK dans lib/, données.
    private func installLegacy() throws {
        try FakeSDK.write(Data("<plist/>".utf8), to: agent().plistURL)
        for path in LegacyAgent.binaries {
            try FakeSDK.write(Data(path.utf8), to: support.appending(path: path))
        }
        try FakeSDK.write(Data("sdk de lib".utf8), to: support.appending(path: "lib/libdev.dylib"))
        try FakeSDK.write(Data("{}".utf8), to: support.appending(path: "devices.json"))
        launchctl.state.withLock { $0.loaded = true }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("Détection : plist présente ou agent chargé ; ni l'un ni l'autre : rien")
    func detect() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!agent().detect())
        launchctl.state.withLock { $0.loaded = true }
        #expect(agent().detect())
        launchctl.state.withLock { $0.loaded = false }
        try FakeSDK.write(Data("<plist/>".utf8), to: agent().plistURL)
        #expect(agent().detect())
    }

    @Test("« Remplacer » : bootout, attente, plist en .bak, binaires à la corbeille, SDK repris, données gardées")
    func migrate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        launchctl.state.withLock { $0.pollsBeforeUnload = 3 }
        let trash = FakeTrash(directory: root.appending(path: "Trash"))
        let legacy = agent(trash: trash)
        let report = try legacy.migrate()
        #expect(launchctl.state.withLock { $0.bootouts } == 1)
        #expect(sleeper.slept.withLock { $0 } == 3 * LegacyAgent.pollInterval)
        #expect(!exists(legacy.plistURL))
        #expect(try Data(contentsOf: legacy.backupURL) == Data("<plist/>".utf8))
        #expect(report.trashed == LegacyAgent.binaries)
        #expect(trash.trashed.withLock { $0 } == ["ptzd", "obsbot-ai", "obsbot-ai-off"])
        #expect(try Data(contentsOf: root.appending(path: "Trash/ptzd")) == Data("bin/ptzd".utf8))
        #expect(report.movedSDK)
        #expect(try Data(contentsOf: support.appending(path: "sdk/libdev.dylib")) == Data("sdk de lib".utf8))
        #expect(!exists(support.appending(path: "lib/libdev.dylib")))
        #expect(exists(support.appending(path: "devices.json")))
        #expect(report.problems.isEmpty)
        #expect(!legacy.detect())
    }

    @Test("Échec du bootout : erreur, rien d'autre ne change")
    func bootoutFailure() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        launchctl.state.withLock { $0.bootoutFails = true }
        let legacy = agent()
        #expect(throws: LegacyMigrationError.bootoutFailed("code 5")) { try legacy.migrate() }
        #expect(exists(legacy.plistURL))
        #expect(!exists(legacy.backupURL))
        for path in LegacyAgent.binaries + ["lib/libdev.dylib"] {
            #expect(exists(support.appending(path: path)))
        }
        #expect(!exists(support.appending(path: "sdk")))
        #expect(LegacyMigrationError.bootoutFailed("code 5").message == "L'ancienne installation n'a pas pu être arrêtée : code 5")
    }

    @Test("bootout en échec mais agent parti : la migration continue")
    func bootoutFailedButGone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        launchctl.state.withLock {
            $0.bootoutFails = true
            $0.unloadsDespiteFailure = true
        }
        let legacy = agent()
        let report = try legacy.migrate()
        #expect(!exists(legacy.plistURL))
        #expect(exists(legacy.backupURL))
        #expect(report.trashed == LegacyAgent.binaries)
        #expect(report.movedSDK)
    }

    @Test("Sauvegarde .plist.bak déjà là : mise à la corbeille, jamais effacée ; corbeille refusée : sauvegarde datée")
    func existingBackup() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        let legacy = agent()
        try FakeSDK.write(Data("ancienne sauvegarde".utf8), to: legacy.backupURL)
        _ = try legacy.migrate()
        #expect(try Data(contentsOf: root.appending(path: "Trash/\(LegacyAgent.label).plist.bak")) == Data("ancienne sauvegarde".utf8))
        #expect(try Data(contentsOf: legacy.backupURL) == Data("<plist/>".utf8))

        try FakeSDK.write(Data("<plist/>".utf8), to: legacy.plistURL)
        let refusing = agent(trash: FakeTrash(directory: root.appending(path: "Trash"), failing: ["\(LegacyAgent.label).plist.bak"]))
        _ = try refusing.migrate()
        #expect(try Data(contentsOf: legacy.backupURL) == Data("<plist/>".utf8))
        let dated = try FileManager.default.contentsOfDirectory(atPath: agents.path).filter { $0.hasSuffix(".bak") && $0 != legacy.backupURL.lastPathComponent }
        #expect(dated.count == 1)
        #expect(dated.first?.hasPrefix("\(LegacyAgent.label).plist.") == true)
    }

    @Test("Ancien ptzd encore chargé après 10 s : erreur, plist et binaires gardés")
    func stillLoaded() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        launchctl.state.withLock { $0.pollsBeforeUnload = 1000 }
        let legacy = agent()
        #expect(throws: LegacyMigrationError.stillLoaded) { try legacy.migrate() }
        #expect(sleeper.slept.withLock { $0 } == LegacyAgent.stopTimeout)
        #expect(LegacyAgent.stopTimeout == 10)
        #expect(exists(legacy.plistURL))
        #expect(exists(support.appending(path: "bin/ptzd")))
    }

    @Test("Agent non chargé : pas de bootout ; SDK déjà dans sdk/ : lib/ laissé ; corbeille refusée : signalée")
    func partial() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        launchctl.state.withLock { $0.loaded = false }
        try FakeSDK.write(Data("sdk autorisé".utf8), to: support.appending(path: "sdk/libdev.dylib"))
        try FileManager.default.removeItem(at: support.appending(path: "bin/obsbot-ai-off"))
        let report = try agent(trash: FakeTrash(directory: root.appending(path: "Trash"), failing: ["obsbot-ai"])).migrate()
        #expect(launchctl.state.withLock { $0.bootouts } == 0)
        #expect(report.trashed == ["bin/ptzd"])
        #expect(report.problems == ["bin/obsbot-ai n'a pas pu être mis à la corbeille : refusé"])
        #expect(!report.movedSDK)
        #expect(try Data(contentsOf: support.appending(path: "sdk/libdev.dylib")) == Data("sdk autorisé".utf8))
        #expect(exists(support.appending(path: "lib/libdev.dylib")))
        #expect(exists(support.appending(path: "bin/obsbot-ai")))
    }
}

extension LegacyAgentTests {
    @Test("Migration interrompue : binaires à la corbeille et SDK de lib/ repris, sans toucher à launchd")
    func leftovers() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        // La plist est déjà renommée et l'agent parti : il reste les binaires et lib/.
        try FileManager.default.removeItem(at: agent().plistURL)
        launchctl.state.withLock { $0.loaded = false }
        let trash = FakeTrash(directory: root.appending(path: "Trash"))
        let legacy = agent(trash: trash)
        #expect(!legacy.detect())
        let report = legacy.completeLeftovers()
        #expect(report.trashed == LegacyAgent.binaries)
        #expect(trash.trashed.withLock { $0 } == ["ptzd", "obsbot-ai", "obsbot-ai-off"])
        #expect(report.movedSDK)
        #expect(report.problems.isEmpty)
        #expect(try Data(contentsOf: support.appending(path: "sdk/libdev.dylib")) == Data("sdk de lib".utf8))
        #expect(!exists(support.appending(path: "lib/libdev.dylib")))
        #expect(exists(support.appending(path: "devices.json")))
        #expect(launchctl.state.withLock { $0.bootouts } == 0)
        #expect(sleeper.slept.withLock { $0 } == 0)
    }

    @Test("Reprise des restes : idempotente et silencieuse quand il n'y a rien ; sdk/ déjà garni : lib/ laissé ; corbeille refusée : signalée")
    func leftoversIdempotent() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(agent().completeLeftovers() == LegacyAgent.Report())
        try installLegacy()
        try FakeSDK.write(Data("sdk autorisé".utf8), to: support.appending(path: "sdk/libdev.dylib"))
        let refusing = agent(trash: FakeTrash(directory: root.appending(path: "Trash"), failing: ["obsbot-ai"]))
        let first = refusing.completeLeftovers()
        #expect(first.trashed == ["bin/ptzd", "bin/obsbot-ai-off"])
        #expect(first.problems == ["bin/obsbot-ai n'a pas pu être mis à la corbeille : refusé"])
        #expect(!first.movedSDK)
        #expect(try Data(contentsOf: support.appending(path: "sdk/libdev.dylib")) == Data("sdk autorisé".utf8))
        #expect(exists(support.appending(path: "lib/libdev.dylib")))
        // Une seconde passe, la corbeille répondant : il ne reste que le binaire refusé.
        let second = agent().completeLeftovers()
        #expect(second.trashed == ["bin/obsbot-ai"])
        #expect(second.problems.isEmpty)
        #expect(agent().completeLeftovers() == LegacyAgent.Report())
    }
}

/// Interfaces simulées ; `addresses` seules : sur en0, en1…
struct FakeInterfaces: InterfaceAddressProvider {
    var interfaces: [InterfaceAddress]

    init(interfaces: [InterfaceAddress]) {
        self.interfaces = interfaces
    }

    init(addresses: [String]) {
        interfaces = addresses.enumerated().map { InterfaceAddress(interface: "en\($0.offset)", address: $0.element) }
    }

    func ipv4Addresses() -> [InterfaceAddress] {
        interfaces
    }
}

@Suite("config.json au premier lancement", .french)
struct ConfigBootstrapTests {
    @Test("Interface Tailscale : config.json écoute sur son adresse")
    func tailscale() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "ObsbotNacelle/config.json")
        let outcome = try ConfigBootstrap.run(configURL: url, addresses: FakeInterfaces(interfaces: [
            InterfaceAddress(interface: "lo0", address: "127.0.0.1"),
            InterfaceAddress(interface: "utun4", address: "100.64.0.1"),
        ]))
        #expect(outcome == .created(listenAddress: "100.64.0.1"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
        #expect(object == ["listenAddress": "100.64.0.1"])
    }

    @Test("Sans Tailscale : 127.0.0.1 seulement, signalé")
    func noTailscale() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        #expect(try ConfigBootstrap.run(configURL: url, addresses: FakeInterfaces(addresses: ["127.0.0.1"])) == .tailscaleMissing)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
        #expect(object == ["listenAddress": "127.0.0.1"])
        #expect(PTZDConfig.load(from: url) == PTZDConfig(port: 1985, isFallback: false))
    }

    @Test("config.json existant : jamais réécrit")
    func existing() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try FakeSDK.write(Data(#"{"listenAddress":"127.0.0.1","port":19870}"#.utf8), to: directory.appending(path: "config.json"))
        #expect(try ConfigBootstrap.run(configURL: url, addresses: FakeInterfaces(addresses: ["100.64.0.1"])) == .existing)
        #expect(try Data(contentsOf: url) == Data(#"{"listenAddress":"127.0.0.1","port":19870}"#.utf8))
    }

    @Test("Plage Tailscale : 100.64.0.0/10")
    func range() {
        #expect(ConfigBootstrap.isTailscale("100.64.0.1"))
        #expect(!ConfigBootstrap.isTailscale("127.0.0.1"))
        #expect(!ConfigBootstrap.isTailscale("pas une adresse"))
    }

    @Test("Seule une interface utun en 100.64/10 compte : en0 en 100.64/10 (CGNAT) est ignorée")
    func utunOnly() throws {
        let other = InterfaceAddress(interface: "en0", address: "100.64.0.1")
        let utun = InterfaceAddress(interface: "utun4", address: "100.64.0.1")
        let utunOutside = InterfaceAddress(interface: "utun2", address: "10.0.0.5")
        #expect(ConfigBootstrap.tailscaleAddress(in: [other, utun]) == "100.64.0.1")
        #expect(ConfigBootstrap.tailscaleAddress(in: [other]) == nil)
        #expect(ConfigBootstrap.tailscaleAddress(in: [other, utunOutside]) == nil)
        #expect(ConfigBootstrap.tailscaleAddress(in: [InterfaceAddress(interface: "lo0", address: "127.0.0.1")]) == nil)
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        #expect(try ConfigBootstrap.run(configURL: url, addresses: FakeInterfaces(interfaces: [other, utun])) == .created(listenAddress: "100.64.0.1"))
    }

    @Test("Sans utun, 100.64/10 sur en0 : 127.0.0.1 et Tailscale signalé absent")
    func cgnatIgnored() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        let outcome = try ConfigBootstrap.run(configURL: url, addresses: FakeInterfaces(interfaces: [InterfaceAddress(interface: "en0", address: "100.64.0.1")]))
        #expect(outcome == .tailscaleMissing)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
        #expect(object == ["listenAddress": "127.0.0.1"])
    }

    @Test("Interfaces réelles : au moins la boucle locale, sur lo0")
    func realInterfaces() {
        #expect(SystemInterfaceAddresses().ipv4Addresses().contains(InterfaceAddress(interface: "lo0", address: "127.0.0.1")))
    }
}
