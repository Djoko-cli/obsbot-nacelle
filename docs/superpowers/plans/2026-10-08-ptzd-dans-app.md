# Plan d'implémentation : ptzd dans PTZBot pour Mac (sous-projet B1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectif :** `ptzd` et `obsbot-ai` sont dans PTZBot.app. `ptzd` ne tourne que tant que l'app est ouverte, et s'arrête même si elle plante. L'app migre l'ancienne installation launchd, crée `config.json` sur un Mac neuf et installe le SDK OBSBOT après confirmation.

**Architecture :**
- L'app lance `ptzd` comme processus enfant depuis `Contents/Helpers`, avec `--parent <pid> --ai <chemin> --sdk <dossier>`.
- Un `ServiceSupervisor` le relance avec un délai croissant et l'arrête proprement.
- `ptzd` surveille son parent par le noyau et prend un verrou de fichier.
- Le SDK reste hors de l'app, dans `~/Library/Application Support/ObsbotNacelle/sdk/`, et `obsbot-ai` le charge par `DYLD_LIBRARY_PATH`.
- Toute la logique est dans PTZBotKit et testée ; les vues SwiftUI restent minces.

**Technologies :** Swift 6 strict, SwiftUI, AppKit (`NSApplicationDelegate`, `NSOpenPanel`), Dispatch (sources de processus), `flock`, Security (`SecStaticCode`), en-têtes Mach-O, Network (`NWBrowser` pour l'autorisation « Réseau local »), `launchctl`, `ditto`, xcodegen, Swift Testing, Xcode 27.

**Spec :** [docs/superpowers/specs/2026-10-07-ptzd-dans-app-design.md](../specs/2026-10-07-ptzd-dans-app-design.md), amendements du § 11 compris, à lire avec ce plan. Elle prolonge la [spec de l'app Mac](../specs/2026-10-06-app-mac-design.md).

## Contraintes globales

- **Swift :** Swift 6, concurrence stricte, **aucun avertissement**. macOS 15, Apple Silicon (`ARCHS: arm64`), app signée en local, sans bac à sable.
- **Système réel :** **aucun initialiseur ne touche le vrai système par défaut** (launchctl, corbeille, `~/Library`, préférences) : seules les fabriques `system(...)` le font, et seule l'app les appelle. Les tests injectent tout et travaillent dans des dossiers temporaires.
- **Cycle de vie :** `ptzd` est un enfant de l'app, jamais un agent launchd. Il ne tourne jamais deux fois sur le même dossier de travail (verrou `ptzd.lock`). Il sort avec 64 (arguments), 75 (verrou ou port pris) ou 78 (`config.json`) sans être relancé.
- **SDK :** jamais dans le dépôt, ni dans l'app. La construction échoue si un `libdev.dylib` se trouve dans le paquet. La quarantaine n'est retirée que de la copie de l'app, après confirmation.
- **Migration :** rien n'est effacé. Les binaires vont à la corbeille, la plist est renommée en `.plist.bak`, et une ancienne `.bak` va à la corbeille. `devices.json`, `config.json` et `state.json` ne sont jamais réécrits.
- **Textes :** en français, **au vouvoiement**. Les textes exacts sont dans le code des tâches.
- **Dépôt public :** aucune adresse IP réelle (seules 127.0.0.1, 0.0.0.0, 192.0.2.x, 169.254.x.x et, dans les tests, 10.0.0.5, 172.16/31/32.x, 192.168.0.x et 100.64.0.1), aucun nom `*.ts.net` réel, aucun chemin `/Users/…`, ni identifiant d'équipe, ni UDID, ni identifiant réel d'appareil. Le contrôle de fuite est donné à chaque commit.
- **Système en service :** pendant les tâches 1 à 6, ne jamais lancer `scripts/install-mac.sh`, `launchctl`, `obsbot-ai on|off`, `ptzd uvc`, ni l'app construite. Ne jamais toucher à `~/Library/Application Support/ObsbotNacelle`, à `~/Library/LaunchAgents`, à go2rtc ni à ffmpeg. Ne jamais arrêter un processus qu'on n'a pas lancé. Le SDK doit être relié dans la copie de travail (`ln -s <dépôt principal>/vendor vendor`, jamais commité) pour compiler l'app.
- **Commits :** messages en français, terminés par une ligne `Co-Authored-By:` au nom du modèle qui commite ; pousser la branche à chaque commit. La fusion dans `main` attend l'accord de Majid.

## Fichiers

| Fichier | Rôle |
|---|---|
| `mac/ptzd/Sources/PTZCore/{DaemonOptions,ParentWatcher,ServiceLock}.swift` | Options du mode service, surveillance du parent, verrou |
| `mac/ptzd/Sources/PTZCore/AIRunner.swift`, `mac/ptzd/Sources/PTZServer/WebSocketServer.swift`, `mac/ptzd/Sources/ptzd/PTZDaemon.swift` | Environnement d'`obsbot-ai`, port pris, branchement des options |
| `mac/app/PTZBotKit/Sources/PTZBotKit/{ProcessLauncher,ServiceSupervisor,SettingsStore}.swift` | Lancement et supervision de `ptzd`, interrupteur retenu |
| `mac/app/PTZBotKit/Sources/PTZBotKit/{SDKInspector,SDKInstaller}.swift` | Examen et installation du SDK |
| `mac/app/PTZBotKit/Sources/PTZBotKit/{LegacyAgent,ConfigBootstrap}.swift` | Migration, `config.json` au premier lancement |
| `mac/app/PTZBotKit/Sources/PTZBotKit/{AppController,AppPaths,SDKWindowModel,LocalNetworkProbe,ServiceLabels}.swift` | Logique de l'app, chemins, fenêtre du SDK, réseau local, libellés |
| `mac/app/PTZBot/{PTZBotApp,PanelView,SDKView}.swift`, `mac/app/project.yml`, `mac/app/{build-helpers,check-bundle}.sh` | App, panneau, fenêtre du SDK, construction des utilitaires |
| `scripts/install-mac.sh`, `README.md` | Installation réduite, documentation |

## Points vérifiés en préparant ce plan

Le plan a été prototypé en entier, relu deux fois (Opus, puis Sonnet), puis essayé au banc avec Majid le 07/10, migration réelle comprise. Il a ensuite été rejoué tâche par tâche sur une copie vierge : chaque tâche échoue à l'étape 2 et passe à l'étape 4, sans avertissement, et son texte reproduit exactement le prototype.

1. **Chargement du SDK :** sans aide, `obsbot-ai` s'arrête (code 134). Avec `DYLD_LIBRARY_PATH` vers le dossier du SDK, il le charge, et sort avec le code 3 quand il n'a pas d'argument. Une copie en quarantaine se charge quand même : la vérification de chargement décide.
2. **Réseau local et pare-feu :** une fois les autorisations données par Majid, `ptzd`, enfant de l'app, écoute et s'annonce ; l'iPhone marche en Wi-Fi et en 4G.
3. **Surveillance du parent :** l'app tuée par SIGKILL, `ptzd` s'arrête en environ 200 ms.
4. **Banc :**
   - migration réelle depuis l'agent launchd ;
   - interrupteur du service, suivi IA et installation du SDK par la fenêtre ;
   - « Quitter » : un interblocage, corrigé dans la tâche 5 ;
   - l'erreur -600 du script, corrigée dans la tâche 6 ;
   - le panneau réorganisé, validé par Majid.

## Décisions prises en préparant ce plan

Elles sont toutes reportées dans la spec, § 11 :
- les codes 64, 75 et 78, et le verrou ;
- le statut « Ne se charge pas » ;
- le choix du SDK par le chemin lié à la construction ;
- l'échange atomique avec `.old` ;
- « Changer… » ;
- « Remplacer l'ancienne installation… » ;
- la liste des iPhone seulement ;
- le panneau en sections ;
- « Quitter » par la boucle d'événements ;
- l'attente de l'ancienne app dans le script ;
- l'interface `utun*` préférée.

## Ordre et présence de Majid

- Tâches 1 à 6 : du code et des tests, sans toucher au système en service.
- Tâche 7 : installation de la version finale et banc court **avec Majid**. Le prototype est déjà installé et la migration déjà faite : le banc vérifie la version issue du plan.

---

### Tâche 1 : `ptzd` : `--parent`, `--ai`, `--sdk`, verrou et codes de sortie

**But :** Lancé par l'app, `ptzd` reçoit le PID de l'app, le chemin d'`obsbot-ai` et le dossier du SDK. Il s'arrête dès que l'app disparaît, même tuée. Il prend un verrou pour qu'il n'y ait jamais deux `ptzd` sur le même dossier, et sort avec un code dédié quand il ne peut pas servir. Il lance `obsbot-ai` avec `DYLD_LIBRARY_PATH` vers le SDK (spec B1 § 5.4 et § 11).

**Fichiers :**
- Modifier : `mac/ptzd/Sources/PTZCore/AIRunner.swift`
- Créer : `mac/ptzd/Sources/PTZCore/DaemonOptions.swift`
- Créer : `mac/ptzd/Sources/PTZCore/ParentWatcher.swift`
- Créer : `mac/ptzd/Sources/PTZCore/ServiceLock.swift`
- Modifier : `mac/ptzd/Sources/PTZServer/WebSocketServer.swift`
- Modifier : `mac/ptzd/Sources/ptzd/PTZDaemon.swift`
- Modifier : `mac/ptzd/Tests/PTZCoreTests/AIRunnerTests.swift`
- Créer : `mac/ptzd/Tests/PTZCoreTests/DaemonOptionsTests.swift`
- Créer : `mac/ptzd/Tests/PTZCoreTests/ParentWatcherTests.swift`
- Créer : `mac/ptzd/Tests/PTZCoreTests/ServiceLockTests.swift`
- Modifier : `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift`

**Interfaces :**
- Produit (module PTZCore) :
  - `DaemonOptions` (`parent`, `aiPath`, `sdkDirectory`) avec `parse(_:) throws(ParseError)`, `usage`, `usageStatus` (64), `busyStatus` (75), `aiEnvironment` et `aiURL(config:relativeTo:)` ;
  - `ParentWatcher(pid:onExit:)` avec `start()`, `stop()` et `isGone(_:)` ;
  - `ServiceLock.acquire(at:) throws(Failure)`.
- Modifie :
  - `ProcessAIRunner` reçoit le paramètre `environment` ;
  - `WebSocketServer` gagne `onAddressInUse` ;
  - `PTZDaemon` analyse les options du mode service, prend le verrou et surveille le parent.
- Sorties : 0 quand le parent est parti, 64 pour des arguments refusés, 75 si le verrou ou le port est pris, 78 si `config.json` est invalide (inchangé).
- Journal : « PTZBot s'est arrêté : ptzd s'arrête. ».

- [ ] **Étape 1 : Écrire les tests**

Modifier `mac/ptzd/Tests/PTZCoreTests/AIRunnerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZCoreTests/AIRunnerTests.swift b/mac/ptzd/Tests/PTZCoreTests/AIRunnerTests.swift
index 1f0769b..47b4149 100644
--- a/mac/ptzd/Tests/PTZCoreTests/AIRunnerTests.swift
+++ b/mac/ptzd/Tests/PTZCoreTests/AIRunnerTests.swift
@@ -65,6 +65,34 @@ struct AIRunnerTests {
         #expect(try String(contentsOf: url, encoding: .utf8) == "un on\ndeux off\n")
     }
 
+    @Test("environment s'ajoute à l'environnement hérité : DYLD_LIBRARY_PATH est donné à l'utilitaire")
+    func environment() async throws {
+        let directory = FileManager.default.temporaryDirectory.appending(path: "ai-env-\(UUID().uuidString)")
+        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
+        defer { try? FileManager.default.removeItem(at: directory) }
+        let output = directory.appending(path: "env.txt")
+        // /bin/sh est protégé par SIP : dyld lui retire les variables DYLD_*. La transmission est donc
+        // vérifiée par une variable ordinaire, et DYLD_LIBRARY_PATH sur l'environnement du processus lancé.
+        let runner = ProcessAIRunner(
+            executableURL: URL(fileURLWithPath: "/bin/sh"),
+            arguments: ["-c", "printf '%s|%s' \"$PTZD_ESSAI\" \"${HOME:+hérité}\" > \"$1\"", "sh", output.path],
+            environment: ["DYLD_LIBRARY_PATH": "/sdk/dossier", "PTZD_ESSAI": "transmis"],
+            scheduler: DispatchScheduler()
+        )
+        #expect(await runOnce(runner) == .success)
+        #expect(try String(contentsOf: output, encoding: .utf8) == "transmis|hérité")
+        let environment = try #require(runner.current?.environment)
+        #expect(environment["DYLD_LIBRARY_PATH"] == "/sdk/dossier")
+        #expect(environment["HOME"] == ProcessInfo.processInfo.environment["HOME"])
+    }
+
+    @Test("Sans environment : l'environnement hérité tel quel")
+    func inheritedEnvironment() async throws {
+        let runner = ProcessAIRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), scheduler: DispatchScheduler())
+        #expect(await runOnce(runner) == .success)
+        #expect(runner.current?.environment == nil)
+    }
+
     @Test("Exécutable absent")
     func launchFailure() async {
         guard case .launchFailed = await run("/nonexistent/obsbot-ai") else {
@@ -113,9 +141,10 @@ struct AIRunnerTests {
         }
         let after = Self.openDescriptors()
         // Le compte exact sur le fichier de sortie ne dépend pas des autres tests ;
-        // le compte global tolère le bruit des suites lancées en parallèle (la fuite en ajoutait 30).
+        // le compte global tolère le bruit des suites lancées en parallèle, qui lancent elles aussi des processus
+        // (ptzd de bout en bout, verrou de service) ; la fuite en ajoutait 30.
         #expect(Self.descriptors(on: url) == 0)
-        #expect(abs(after - before) <= 5, "descripteurs : \(before) avant, \(after) après")
+        #expect(abs(after - before) <= 12, "descripteurs : \(before) avant, \(after) après")
     }
 
     @Test("Les processus terminés sont libérés")
PATCH
```

Créer `mac/ptzd/Tests/PTZCoreTests/DaemonOptionsTests.swift` :

```swift
import Foundation
import Testing
@testable import PTZCore

@Suite("Options du service (--parent, --ai, --sdk)")
struct DaemonOptionsTests {
    @Test("Sans option : fonctionnement en ligne de commande inchangé")
    func absent() throws {
        let options = try DaemonOptions.parse([])
        #expect(options == DaemonOptions())
        #expect(options.aiEnvironment.isEmpty)
        let config = PTZConfig(listenAddress: "127.0.0.1")
        let base = URL(fileURLWithPath: "/support")
        #expect(options.aiURL(config: config, relativeTo: base).path == "/support/bin/obsbot-ai")
    }

    @Test("Les trois options, dans n'importe quel ordre")
    func valid() throws {
        let options = try DaemonOptions.parse(["--sdk", "/sdk", "--parent", "4242", "--ai", "/app/Helpers/obsbot-ai"])
        #expect(options == DaemonOptions(parent: 4242, aiPath: "/app/Helpers/obsbot-ai", sdkDirectory: "/sdk"))
        #expect(options.aiEnvironment == ["DYLD_LIBRARY_PATH": "/sdk"])
        let config = PTZConfig(listenAddress: "127.0.0.1", aiPath: "/ailleurs/obsbot-ai")
        #expect(options.aiURL(config: config, relativeTo: URL(fileURLWithPath: "/support")).path == "/app/Helpers/obsbot-ai")
    }

    @Test("Option inconnue, valeur manquante, mal formée ou en double : refusées")
    func invalid() {
        #expect(throws: DaemonOptions.ParseError.unknownOption("--verbose")) { try DaemonOptions.parse(["--verbose"]) }
        #expect(throws: DaemonOptions.ParseError.unknownOption("devicez")) { try DaemonOptions.parse(["devicez"]) }
        #expect(throws: DaemonOptions.ParseError.missingValue("--parent")) { try DaemonOptions.parse(["--parent"]) }
        #expect(throws: DaemonOptions.ParseError.invalidValue(option: "--parent", value: "abc")) {
            try DaemonOptions.parse(["--parent", "abc"])
        }
        #expect(throws: DaemonOptions.ParseError.invalidValue(option: "--parent", value: "0")) {
            try DaemonOptions.parse(["--parent", "0"])
        }
        #expect(throws: DaemonOptions.ParseError.invalidValue(option: "--parent", value: "-3")) {
            try DaemonOptions.parse(["--parent", "-3"])
        }
        #expect(throws: DaemonOptions.ParseError.invalidValue(option: "--ai", value: "bin/obsbot-ai")) {
            try DaemonOptions.parse(["--ai", "bin/obsbot-ai"])
        }
        #expect(throws: DaemonOptions.ParseError.invalidValue(option: "--sdk", value: "")) {
            try DaemonOptions.parse(["--sdk", ""])
        }
        #expect(throws: DaemonOptions.ParseError.duplicate("--ai")) {
            try DaemonOptions.parse(["--ai", "/a", "--ai", "/b"])
        }
    }

    @Test("Usage et code de sortie 64")
    func usage() {
        #expect(DaemonOptions.usageStatus == 64)
        #expect(DaemonOptions.usage.hasPrefix("usage : ptzd [--parent <pid>]"))
        #expect("\(DaemonOptions.ParseError.missingValue("--sdk"))" == "valeur manquante après --sdk")
    }
}
```

Créer `mac/ptzd/Tests/PTZCoreTests/ParentWatcherTests.swift` :

```swift
import Foundation
import Testing
@testable import PTZCore

@MainActor
@Suite("Surveillance du parent (--parent)")
struct ParentWatcherTests {
    /// Attend `condition` au plus `limit`, en laissant tourner la file principale.
    private func wait(_ limit: Duration, until condition: () -> Bool) async throws -> Bool {
        let start = ContinuousClock.now
        while !condition() {
            guard ContinuousClock.now - start < limit else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test("Un vrai processus tué par SIGKILL : rappel en moins de 2 s, une seule fois")
    func killedProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        var calls = 0
        let watcher = ParentWatcher(pid: process.processIdentifier) { calls += 1 }
        watcher.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 0)
        let killedAt = ContinuousClock.now
        kill(process.processIdentifier, SIGKILL)
        #expect(try await wait(.seconds(2)) { calls > 0 })
        #expect(ContinuousClock.now - killedAt < .seconds(2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1)
    }

    @Test("Un PID qui n'existe pas : rappel aussitôt")
    func missingProcess() throws {
        // Un processus lancé puis attendu jusqu'au bout : son PID est libre.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let pid = process.processIdentifier
        #expect(ParentWatcher.isGone(pid))
        var calls = 0
        let watcher = ParentWatcher(pid: pid) { calls += 1 }
        watcher.start()
        #expect(calls == 1)
        watcher.start()
        #expect(calls == 1)
    }

    @Test("Un processus vivant n'est pas déclaré disparu")
    func aliveProcess() {
        #expect(!ParentWatcher.isGone(getpid()))
        // launchd appartient à root : EPERM, pas ESRCH.
        #expect(!ParentWatcher.isGone(1))
    }
}
```

Créer `mac/ptzd/Tests/PTZCoreTests/ServiceLockTests.swift` :

```swift
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
```

Modifier `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift b/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
index 1ecc0df..dc8606a 100644
--- a/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
+++ b/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
@@ -205,6 +205,37 @@ struct WebSocketServerTests {
         withExtendedLifetime(server) {}
     }
 
+    @Test("Port de 127.0.0.1 déjà pris (EADDRINUSE) : signalé par onAddressInUse")
+    func addressInUse() async throws {
+        // Un socket ordinaire, sans SO_REUSEPORT, tient un port choisi par le système (port 0).
+        let holder = socket(AF_INET, SOCK_STREAM, 0)
+        try #require(holder >= 0)
+        defer { close(holder) }
+        var address = sockaddr_in()
+        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
+        address.sin_family = sa_family_t(AF_INET)
+        address.sin_addr.s_addr = inet_addr("127.0.0.1")
+        address.sin_port = 0
+        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
+        let bound = withUnsafeMutablePointer(to: &address) {
+            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
+                bind(holder, pointer, length) == 0 && listen(holder, 1) == 0 && getsockname(holder, pointer, &length) == 0
+            }
+        }
+        try #require(bound)
+        let port = UInt16(bigEndian: address.sin_port)
+        let server = WebSocketServer(
+            hosts: ["127.0.0.1"], port: port, controller: controller, authority: authority,
+            relay: FakeRelay { $0 }, scheduler: DispatchScheduler(), log: { _ in }
+        )
+        var inUse: [String] = []
+        server.onAddressInUse = { inUse.append($0) }
+        server.start()
+        try await waitUntil { !inUse.isEmpty }
+        #expect(inUse.first == "127.0.0.1")
+        withExtendedLifetime(server) {}
+    }
+
     @Test("Au-delà de 4 clients, la connexion est refusée")
     func maxClients() async throws {
         let (server, ports) = await startServer()
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : échec — la compilation des tests échoue : `DaemonOptions`, `ParentWatcher`, `ServiceLock` et le paramètre `environment` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Modifier `mac/ptzd/Sources/PTZCore/AIRunner.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZCore/AIRunner.swift b/mac/ptzd/Sources/PTZCore/AIRunner.swift
index 7402778..2f74a23 100644
--- a/mac/ptzd/Sources/PTZCore/AIRunner.swift
+++ b/mac/ptzd/Sources/PTZCore/AIRunner.swift
@@ -36,6 +36,8 @@ public final class ProcessAIRunner: AIRunner {
     private let arguments: [String]
     private let timeout: TimeInterval
     private let outputURL: URL?
+    /// Variables ajoutées à l'environnement hérité (`DYLD_LIBRARY_PATH` du SDK, spec ptzd dans l'app § 5.4).
+    private let environment: [String: String]
     private let scheduler: any Scheduler
     /// Dernier utilitaire lancé : retenu jusqu'au suivant, pour refuser un chevauchement.
     private(set) var current: Process?
@@ -48,12 +50,14 @@ public final class ProcessAIRunner: AIRunner {
         arguments: [String] = [],
         timeout: TimeInterval = 15,
         outputURL: URL? = nil,
+        environment: [String: String] = [:],
         scheduler: any Scheduler
     ) {
         self.executableURL = executableURL
         self.arguments = arguments
         self.timeout = timeout
         self.outputURL = outputURL
+        self.environment = environment
         self.scheduler = scheduler
     }
 
@@ -67,6 +71,9 @@ public final class ProcessAIRunner: AIRunner {
         let process = Process()
         process.executableURL = executableURL
         process.arguments = arguments + [on ? "on" : "off"]
+        if !environment.isEmpty {
+            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
+        }
         let output = appendingHandle()
         if let output {
             process.standardOutput = output
PATCH
```

Créer `mac/ptzd/Sources/PTZCore/DaemonOptions.swift` :

```swift
import Foundation

/// Options du service (la commande par défaut de ptzd), données par PTZBot (spec ptzd dans l'app § 5.4).
/// Sans elles, ptzd garde son fonctionnement en ligne de commande.
public struct DaemonOptions: Equatable, Sendable {
    /// Processus à surveiller : ptzd s'arrête quand il disparaît.
    public var parent: pid_t?
    /// Chemin d'obsbot-ai ; remplace `aiPath` de config.json.
    public var aiPath: String?
    /// Dossier contenant `libdev.dylib`, passé à obsbot-ai par `DYLD_LIBRARY_PATH`.
    public var sdkDirectory: String?

    public init(parent: pid_t? = nil, aiPath: String? = nil, sdkDirectory: String? = nil) {
        self.parent = parent
        self.aiPath = aiPath
        self.sdkDirectory = sdkDirectory
    }

    public static let usage = "usage : ptzd [--parent <pid>] [--ai <chemin d'obsbot-ai>] [--sdk <dossier du SDK>]"

    /// Code de sortie d'une option inconnue ou mal formée (EX_USAGE).
    public static let usageStatus: Int32 = 64
    /// Code de sortie quand un autre ptzd tourne déjà : verrou de service tenu, ou port de 127.0.0.1
    /// déjà pris sous `--parent` (EX_TEMPFAIL). PTZBot ne relance pas ptzd sur ce code.
    public static let busyStatus: Int32 = 75

    public enum ParseError: Error, Equatable {
        case unknownOption(String)
        case missingValue(String)
        case invalidValue(option: String, value: String)
        case duplicate(String)
    }

    /// Lit `--parent <pid>`, `--ai <chemin>` et `--sdk <dossier>`, chacun au plus une fois.
    /// Les chemins sont absolus ; le PID est un entier strictement positif.
    public static func parse(_ arguments: [String]) throws(ParseError) -> DaemonOptions {
        var options = DaemonOptions()
        var seen: Set<String> = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let option = arguments[index]
            guard ["--parent", "--ai", "--sdk"].contains(option) else {
                throw .unknownOption(option)
            }
            guard seen.insert(option).inserted else {
                throw .duplicate(option)
            }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else {
                throw .missingValue(option)
            }
            let value = arguments[next]
            switch option {
            case "--parent":
                guard let pid = pid_t(value), pid > 0 else {
                    throw .invalidValue(option: option, value: value)
                }
                options.parent = pid
            case "--ai":
                guard value.hasPrefix("/") else {
                    throw .invalidValue(option: option, value: value)
                }
                options.aiPath = value
            default:
                guard value.hasPrefix("/") else {
                    throw .invalidValue(option: option, value: value)
                }
                options.sdkDirectory = value
            }
            index = arguments.index(after: next)
        }
        return options
    }

    /// L'environnement ajouté à celui de ptzd pour lancer obsbot-ai.
    public var aiEnvironment: [String: String] {
        guard let sdkDirectory else { return [:] }
        return ["DYLD_LIBRARY_PATH": sdkDirectory]
    }

    /// Le chemin d'obsbot-ai : `--ai`, sinon celui de config.json.
    public func aiURL(config: PTZConfig, relativeTo base: URL) -> URL {
        aiPath.map { URL(fileURLWithPath: $0) } ?? config.aiURL(relativeTo: base)
    }
}

extension DaemonOptions.ParseError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .unknownOption(option): "option inconnue : \(option)"
        case let .missingValue(option): "valeur manquante après \(option)"
        case let .invalidValue(option, value): "valeur invalide pour \(option) : \(value)"
        case let .duplicate(option): "option donnée deux fois : \(option)"
        }
    }
}
```

Créer `mac/ptzd/Sources/PTZCore/ParentWatcher.swift` :

```swift
import Foundation

/// Surveille la fin d'un processus (PTZBot, le parent de ptzd ; spec ptzd dans l'app § 5.4).
/// La source de distribution `.exit` se déclenche aussi quand le parent est tué par SIGKILL.
@MainActor
public final class ParentWatcher {
    public let pid: pid_t
    private let onExit: @MainActor () -> Void
    private var source: (any DispatchSourceProcess)?
    private var fired = false

    public init(pid: pid_t, onExit: @escaping @MainActor () -> Void) {
        self.pid = pid
        self.onExit = onExit
    }

    /// Le processus n'existe plus (ESRCH). Un processus d'un autre utilisateur (EPERM) existe.
    public nonisolated static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    /// Commence la surveillance. Un parent déjà disparu appelle `onExit` aussitôt.
    public func start() {
        guard source == nil, !fired else { return }
        if Self.isGone(pid) {
            fire()
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
        self.source = source
        source.resume()
        // Le parent a pu disparaître entre la vérification et l'inscription de la source.
        if Self.isGone(pid) {
            fire()
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func fire() {
        guard !fired else { return }
        fired = true
        stop()
        onExit()
    }
}
```

Créer `mac/ptzd/Sources/PTZCore/ServiceLock.swift` :

```swift
import Foundation

/// Verrou de service : un seul ptzd par dossier de travail (`<support>/ptzd.lock`, `flock` exclusif).
/// Le descripteur est ouvert avec `O_CLOEXEC` : obsbot-ai, lancé par ptzd, n'en hérite pas.
/// Le verrou tombe avec le processus, même tué par SIGKILL.
public final class ServiceLock: Sendable {
    public enum Failure: Error, Equatable {
        /// Un autre ptzd tient déjà le verrou.
        case held
        case unavailable(Int32)
    }

    let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Prend le verrou sans attendre ; crée le fichier (et son dossier) au besoin.
    public static func acquire(at url: URL) throws(Failure) -> ServiceLock {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw .unavailable(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            throw code == EWOULDBLOCK ? .held : .unavailable(code)
        }
        return ServiceLock(descriptor: descriptor)
    }
}
```

Modifier `mac/ptzd/Sources/PTZServer/WebSocketServer.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZServer/WebSocketServer.swift b/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
index 76aa243..bf825a2 100644
--- a/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
+++ b/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
@@ -43,6 +43,10 @@ public final class WebSocketServer {
     /// ouvert (utile quand on demande le port 0).
     public var onReady: ((_ host: String, _ port: UInt16) -> Void)?
 
+    /// Appelé quand l'écoute sur une adresse échoue parce que le port y est déjà pris (EADDRINUSE).
+    /// L'écoute est réessayée quand même ; ptzd lancé par PTZBot s'arrête (code 75).
+    public var onAddressInUse: ((_ host: String) -> Void)?
+
     private let hosts: [String]
     private let port: UInt16
     private let controller: PTZController
@@ -226,6 +230,7 @@ public final class WebSocketServer {
         do {
             listener = try NWListener(using: parameters)
         } catch {
+            reportAddressInUse(host, error)
             retryLater(host, after: error)
             return
         }
@@ -253,12 +258,19 @@ public final class WebSocketServer {
             onReady?(host, actual)
         case let .failed(error), let .waiting(error):
             listeners.removeValue(forKey: host)?.cancel()
+            reportAddressInUse(host, error)
             retryLater(host, after: error)
         default:
             break
         }
     }
 
+    private func reportAddressInUse(_ host: String, _ error: any Error) {
+        if case .posix(.EADDRINUSE) = error as? NWError {
+            onAddressInUse?(host)
+        }
+    }
+
     private func retryLater(_ host: String, after error: any Error) {
         log("Écoute sur \(host):\(port) impossible (\(error)). Nouvel essai dans 5 s.")
         scheduler.schedule(after: Self.retryDelay) { [weak self] in
PATCH
```

Modifier `mac/ptzd/Sources/ptzd/PTZDaemon.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/ptzd/PTZDaemon.swift b/mac/ptzd/Sources/ptzd/PTZDaemon.swift
index 6852004..f450039 100644
--- a/mac/ptzd/Sources/ptzd/PTZDaemon.swift
+++ b/mac/ptzd/Sources/ptzd/PTZDaemon.swift
@@ -44,6 +44,45 @@ struct PTZDaemon {
             exit(result.status)
         }
 
+        // Mode service (la commande par défaut) : options données par PTZBot (spec ptzd dans l'app § 5.4).
+        let options: DaemonOptions
+        if arguments.first == "pair" {
+            options = DaemonOptions()
+        } else {
+            do {
+                options = try DaemonOptions.parse(arguments)
+            } catch {
+                FileHandle.standardError.write(Data("ptzd : \(error)\n\(DaemonOptions.usage)\n".utf8))
+                exit(DaemonOptions.usageStatus)
+            }
+        }
+        // PTZBot disparu, même tué par SIGKILL : ptzd s'arrête avec lui ; déjà disparu : tout de suite.
+        // Un parent qui n'est pas le nôtre (PID déjà réattribué) compte comme disparu.
+        if let parent = options.parent, getppid() != parent {
+            log("PTZBot s'est arrêté : ptzd s'arrête.")
+            exit(0)
+        }
+        let parentWatcher = options.parent.map { pid in
+            ParentWatcher(pid: pid) {
+                log("PTZBot s'est arrêté : ptzd s'arrête.")
+                exit(0)
+            }
+        }
+        parentWatcher?.start()
+
+        // Un seul service par dossier de travail : un autre ptzd tient le verrou, celui-ci s'arrête.
+        var serviceLock: ServiceLock?
+        if arguments.first != "pair" {
+            do {
+                serviceLock = try ServiceLock.acquire(at: supportDirectory.appending(path: "ptzd.lock"))
+            } catch .held {
+                log("Un autre ptzd tourne déjà (verrou ptzd.lock) : ptzd s'arrête.")
+                exit(DaemonOptions.busyStatus)
+            } catch {
+                log("Verrou ptzd.lock indisponible (\(error)) : ptzd continue sans.")
+            }
+        }
+
         let config: PTZConfig
         do {
             config = try PTZConfig.load(from: supportDirectory.appending(path: "config.json"))
@@ -70,8 +109,9 @@ struct PTZDaemon {
             camera: camera,
             scheduler: scheduler,
             ai: ProcessAIRunner(
-                executableURL: config.aiURL(relativeTo: supportDirectory),
+                executableURL: options.aiURL(config: config, relativeTo: supportDirectory),
                 outputURL: logsDirectory.appending(path: "obsbot-ai.log"),
+                environment: options.aiEnvironment,
                 scheduler: scheduler
             ),
             store: JSONFileStateStore(url: supportDirectory.appending(path: "state.json"), log: { write($0) }),
@@ -97,10 +137,19 @@ struct PTZDaemon {
             localNetwork: config.localNetwork
         )
 
+        if options.parent != nil {
+            // Lancé par PTZBot : un port de 127.0.0.1 déjà pris veut dire qu'un autre ptzd tourne encore.
+            server.onAddressInUse = { host in
+                guard host == "127.0.0.1" else { return }
+                log("Le port \(config.port) est déjà pris : un autre ptzd tourne peut-être encore. ptzd s'arrête.")
+                exit(DaemonOptions.busyStatus)
+            }
+        }
+
         log("ptzd démarre.")
         camera.startWatching()
         server.start()
-        withExtendedLifetime((camera, controller, server)) {
+        withExtendedLifetime((camera, controller, server, parentWatcher, serviceLock)) {
             dispatchMain()
         }
     }
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : tout passe (Mac : 201 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add mac/ptzd/Sources/PTZCore/AIRunner.swift \
    mac/ptzd/Sources/PTZCore/DaemonOptions.swift \
    mac/ptzd/Sources/PTZCore/ParentWatcher.swift \
    mac/ptzd/Sources/PTZCore/ServiceLock.swift \
    mac/ptzd/Sources/PTZServer/WebSocketServer.swift \
    mac/ptzd/Sources/ptzd/PTZDaemon.swift \
    mac/ptzd/Tests/PTZCoreTests/AIRunnerTests.swift \
    mac/ptzd/Tests/PTZCoreTests/DaemonOptionsTests.swift \
    mac/ptzd/Tests/PTZCoreTests/ParentWatcherTests.swift \
    mac/ptzd/Tests/PTZCoreTests/ServiceLockTests.swift \
    mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|8\.8\.8\.8|256\.0\.0\.1|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
B1 : ptzd --parent, --ai, --sdk, verrou et codes de sortie

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés plus haut sont déjà indexés par `git rm`.

### Tâche 2 : PTZBotKit : `ServiceSupervisor`

**But :** L'app lance `ptzd` comme processus enfant et le supervise. Elle le relance après un arrêt inattendu, avec un délai croissant de 1 à 30 s, et abandonne au-delà de 5 arrêts en 2 min ou sur les codes 64, 75 et 78. Elle l'arrête par SIGTERM, puis par SIGKILL après 5 s. L'état de l'interrupteur est retenu (spec B1 § 5.3 et § 11).

**Fichiers :**
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/ProcessLauncher.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/Scheduler.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceSupervisor.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/SettingsStore.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift`
- Créer : `mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceSupervisorTests.swift`

**Interfaces :**
- Produit (module PTZBotKit) :
  - `ProcessExit` ;
  - `LaunchedProcess` et `ProcessLauncher`, avec `FoundationProcessLauncher` (journal ouvert en `O_APPEND`) ;
  - `SettingsStore` et `UserDefaultsSettingsStore(defaults:)` ;
  - `ServiceSupervisor` :
    - `State` : `stopped`, `starting`, `running`, `restarting(count:)`, `failed(reason:)` ;
    - `Paths(ptzd:ai:sdkDirectory:log:)` ;
    - `start()`, `stop(forQuit:completion:)`, `setEnabled(_:)` ;
    - propriétés : `isEnabled`, `legacyAgentActive`, `port`, `arguments` ;
    - fabrique `system(paths:scheduler:)` ;
    - constantes : `restartDelays`, `maxUnexpectedExits` (5), `failureWindow` (120), `killDelay` (5) et les textes d'échec.
- `Scheduler` gagne `now`.
- Aucun initialiseur n'a de valeur par défaut qui touche le vrai système : seules les fabriques `system(...)` le font.

- [ ] **Étape 1 : Écrire les tests**

Remplacer tout le contenu de `mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift` par :

```swift
import Foundation
import ServiceManagement
@testable import PTZBotKit

/// Horloge manuelle : `advance(by:)` exécute les actions arrivées à échéance, dans l'ordre.
@MainActor
final class FakeScheduler: Scheduler {
    private(set) var now: TimeInterval = 0
    private var tasks: [FakeTask] = []
    private var counter = 0

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
        counter += 1
        let task = FakeTask(at: now + delay, order: counter, action: action)
        tasks.append(task)
        return task
    }

    func advance(by delta: TimeInterval) {
        let target = now + delta
        while let next = tasks
            .filter({ !$0.cancelled && $0.at <= target + 1e-9 })
            .min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            tasks.removeAll { $0 === next }
            now = max(now, next.at)
            next.action()
        }
        now = target
        tasks.removeAll { $0.cancelled }
    }
}

final class FakeTask: Cancellable {
    let at: TimeInterval
    let order: Int
    let action: @MainActor @Sendable () -> Void
    private(set) var cancelled = false

    init(at: TimeInterval, order: Int, action: @escaping @MainActor @Sendable () -> Void) {
        self.at = at
        self.order = order
        self.action = action
    }

    func cancel() {
        cancelled = true
    }
}

/// Connexion simulée : enregistre les ouvertures et les envois ; le test déclenche les événements.
@MainActor
final class FakeAdminTransport: AdminTransport {
    var onEvent: ((AdminTransportEvent) -> Void)?
    private(set) var opened: [URL] = []
    private(set) var sent: [String] = []

    func open(_ url: URL) {
        opened.append(url)
    }

    func send(_ text: String) {
        sent.append(text)
    }

    func close() {}

    func emit(_ event: AdminTransportEvent) {
        onEvent?(event)
    }
}

/// `SMAppService` simulé.
@MainActor
final class FakeLoginItem: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var failure: (any Error)?
    private(set) var settingsOpened = 0
    var statusAfterRegister: SMAppService.Status = .enabled

    func register() throws {
        if let failure {
            throw failure
        }
        status = statusAfterRegister
    }

    func unregister() throws {
        if let failure {
            throw failure
        }
        status = .notRegistered
    }

    func openSystemSettings() {
        settingsOpened += 1
    }
}

/// Préférences en mémoire.
@MainActor
final class FakeSettings: SettingsStore {
    var values: [String: Bool] = [:]

    func bool(forKey key: String) -> Bool? {
        values[key]
    }

    func set(_ value: Bool, forKey key: String) {
        values[key] = value
    }
}

/// Processus simulé : le test décide de sa fin.
@MainActor
final class FakeProcess: LaunchedProcess {
    let pid: pid_t
    let arguments: [String]
    let outputURL: URL
    private let onExit: @MainActor (ProcessExit) -> Void
    private(set) var isRunning = true
    private(set) var terminations = 0
    private(set) var kills = 0
    /// SIGTERM ignoré (ptzd bloqué) : seul SIGKILL l'arrête.
    var ignoresTerminate = false

    init(pid: pid_t, arguments: [String], outputURL: URL, onExit: @escaping @MainActor (ProcessExit) -> Void) {
        self.pid = pid
        self.arguments = arguments
        self.outputURL = outputURL
        self.onExit = onExit
    }

    func terminate() {
        terminations += 1
        if !ignoresTerminate {
            exit(ProcessExit(status: SIGTERM, signaled: true))
        }
    }

    func kill() {
        kills += 1
        exit(ProcessExit(status: SIGKILL, signaled: true))
    }

    /// Fin du processus ; `onExit` arrive comme avec `Process`, plus tard sur la file principale : ici, tout de suite.
    func exit(_ exit: ProcessExit = ProcessExit(status: 1, signaled: false)) {
        guard isRunning else { return }
        isRunning = false
        onExit(exit)
    }
}

/// Lanceur simulé : retient chaque processus lancé.
@MainActor
final class FakeLauncher: ProcessLauncher {
    struct Failure: LocalizedError {
        var errorDescription: String? { "fichier introuvable" }
    }

    private(set) var launched: [FakeProcess] = []
    private(set) var executables: [URL] = []
    var failure: (any Error)?

    var last: FakeProcess? {
        launched.last
    }

    func launch(
        executableURL: URL,
        arguments: [String],
        outputURL: URL,
        onExit: @escaping @MainActor (ProcessExit) -> Void
    ) throws -> any LaunchedProcess {
        if let failure {
            throw failure
        }
        executables.append(executableURL)
        let process = FakeProcess(pid: pid_t(1000 + launched.count), arguments: arguments, outputURL: outputURL, onExit: onExit)
        launched.append(process)
        return process
    }
}
```

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceSupervisorTests.swift` :

```swift
import Foundation
import Testing
@testable import PTZBotKit

@MainActor
@Suite("Supervision de ptzd")
struct ServiceSupervisorTests {
    let launcher = FakeLauncher()
    let settings = FakeSettings()
    let scheduler = FakeScheduler()
    let paths = ServiceSupervisor.Paths(
        ptzd: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/ptzd"),
        ai: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/obsbot-ai"),
        sdkDirectory: URL(fileURLWithPath: "/support/sdk"),
        log: URL(fileURLWithPath: "/logs/ptzd.log")
    )

    private func makeSupervisor() -> ServiceSupervisor {
        ServiceSupervisor(paths: paths, launcher: launcher, settings: settings, scheduler: scheduler, parentPID: 4242)
    }

    @Test("Démarrage : ptzd lancé avec --parent, --ai et --sdk, sortie vers le journal")
    func start() throws {
        let supervisor = makeSupervisor()
        #expect(supervisor.state == .stopped)
        supervisor.start()
        #expect(supervisor.state == .running)
        let process = try #require(launcher.last)
        #expect(launcher.executables == [paths.ptzd])
        #expect(process.arguments == ["--parent", "4242", "--ai", paths.ai.path, "--sdk", "/support/sdk"])
        #expect(process.outputURL == paths.log)
        supervisor.start()
        #expect(launcher.launched.count == 1)
    }

    @Test("Binaire introuvable : failed avec le motif, sans relance")
    func launchFailure() {
        launcher.failure = FakeLauncher.Failure()
        let supervisor = makeSupervisor()
        supervisor.start()
        #expect(supervisor.state == .failed(reason: "ptzd n'a pas pu être lancé : fichier introuvable"))
        scheduler.advance(by: 60)
        #expect(launcher.launched.isEmpty)
    }

    @Test("Arrêt : SIGTERM, puis stopped et completion à la fin du processus, sans relance")
    func stop() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        let process = try #require(launcher.last)
        var done = 0
        supervisor.stop { done += 1 }
        #expect(process.terminations == 1)
        #expect(process.kills == 0)
        #expect(supervisor.state == .stopped)
        #expect(done == 1)
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
        #expect(process.kills == 0)
    }

    @Test("SIGTERM ignoré : SIGKILL 5 s plus tard ; completion seulement à la fin du processus")
    func killAfterDelay() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        var done = 0
        supervisor.stop { done += 1 }
        supervisor.stop { done += 1 }
        #expect(process.terminations == 1)
        scheduler.advance(by: ServiceSupervisor.killDelay - 0.1)
        #expect(process.kills == 0)
        #expect(done == 0)
        #expect(supervisor.state == .running)
        scheduler.advance(by: 0.1)
        #expect(process.kills == 1)
        #expect(done == 2)
        #expect(supervisor.state == .stopped)
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
    }

    @Test("Arrêt sans processus : completion tout de suite")
    func stopWhenStopped() {
        let supervisor = makeSupervisor()
        var done = false
        supervisor.stop { done = true }
        #expect(done)
        #expect(supervisor.state == .stopped)
    }

    @Test("Arrêt inattendu : relance après 1, 2, 4, 8, 16 puis 30 s")
    func restartDelays() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        // Chaque ptzd tient 25 s : jamais plus de 5 arrêts en 2 min, jamais 2 min d'affilée.
        for (index, delay) in [1.0, 2, 4, 8, 16, 30, 30].enumerated() {
            scheduler.advance(by: 25)
            try #require(launcher.last).exit()
            #expect(supervisor.state == .restarting(count: index + 1))
            scheduler.advance(by: delay - 0.1)
            #expect(launcher.launched.count == index + 1)
            scheduler.advance(by: 0.1)
            #expect(launcher.launched.count == index + 2)
            #expect(supervisor.state == .running)
        }
    }

    @Test("Plus de 5 arrêts inattendus en 2 min : failed, sans relance")
    func crashLoop() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        for delay in [1.0, 2, 4, 8, 16] {
            try #require(launcher.last).exit()
            scheduler.advance(by: delay)
        }
        #expect(launcher.launched.count == 6)
        try #require(launcher.last).exit()
        #expect(supervisor.state == .failed(reason: "ptzd s'arrête sans cesse : ouvrez le journal"))
        scheduler.advance(by: 300)
        #expect(launcher.launched.count == 6)
        // L'interrupteur, éteint puis rallumé, repart de zéro.
        supervisor.setEnabled(false)
        #expect(supervisor.state == .stopped)
        supervisor.setEnabled(true)
        #expect(supervisor.state == .running)
        #expect(launcher.launched.count == 7)
        try #require(launcher.last).exit()
        #expect(supervisor.state == .restarting(count: 1))
    }

    @Test("Un ptzd qui a tenu 2 min repart du premier délai")
    func stableRunResetsDelay() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        try #require(launcher.last).exit()
        scheduler.advance(by: 1)
        try #require(launcher.last).exit()
        #expect(supervisor.state == .restarting(count: 2))
        scheduler.advance(by: 2)
        scheduler.advance(by: ServiceSupervisor.failureWindow)
        try #require(launcher.last).exit()
        #expect(supervisor.state == .restarting(count: 1))
        scheduler.advance(by: 1)
        #expect(launcher.launched.count == 4)
    }

    @Test("Arrêt pendant le délai de relance : pas de relance")
    func stopDuringRestart() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        try #require(launcher.last).exit()
        var done = false
        supervisor.stop { done = true }
        #expect(done)
        #expect(supervisor.state == .stopped)
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
    }

    @Test("Interrupteur : allumé par défaut, retenu, lance ou arrête ptzd")
    func toggle() throws {
        let supervisor = makeSupervisor()
        #expect(supervisor.isEnabled)
        supervisor.start()
        supervisor.setEnabled(false)
        #expect(settings.values[ServiceSupervisor.enabledKey] == false)
        #expect(try #require(launcher.last).terminations == 1)
        #expect(supervisor.state == .stopped)
        supervisor.start()
        #expect(launcher.launched.count == 1)

        let next = makeSupervisor()
        #expect(!next.isEnabled)
        next.start()
        #expect(launcher.launched.count == 1)
        next.setEnabled(true)
        #expect(settings.values[ServiceSupervisor.enabledKey] == true)
        #expect(launcher.launched.count == 2)
        #expect(makeSupervisor().isEnabled)
    }

    @Test("Ancien agent actif : aucun lancement ; levé : lancement possible")
    func legacyAgent() {
        let supervisor = makeSupervisor()
        supervisor.legacyAgentActive = true
        supervisor.start()
        supervisor.setEnabled(true)
        #expect(launcher.launched.isEmpty)
        #expect(supervisor.state == .stopped)
        supervisor.legacyAgentActive = false
        supervisor.start()
        #expect(launcher.launched.count == 1)
    }

    @Test("Sortie 75 (port ou verrou pris) : failed avec le port, sans relance")
    func busy() throws {
        let supervisor = makeSupervisor()
        supervisor.port = 19870
        supervisor.start()
        try #require(launcher.last).exit(ProcessExit(status: 75, signaled: false))
        #expect(supervisor.state == .failed(reason: "Le port 19870 est déjà pris : un autre ptzd tourne peut-être encore"))
        scheduler.advance(by: 300)
        #expect(launcher.launched.count == 1)
    }

    @Test("Sortie 78 (config.json) ou 64 (arguments) : failed, sans relance ; signal 75 : arrêt inattendu ordinaire")
    func permanentFailures() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        try #require(launcher.last).exit(ProcessExit(status: 78, signaled: false))
        #expect(supervisor.state == .failed(reason: "config.json est invalide : ouvrez le journal"))
        supervisor.setEnabled(false)
        supervisor.setEnabled(true)
        try #require(launcher.last).exit(ProcessExit(status: 64, signaled: false))
        #expect(supervisor.state == .failed(reason: "Arguments de ptzd refusés"))
        scheduler.advance(by: 300)
        #expect(launcher.launched.count == 2)
        supervisor.setEnabled(false)
        supervisor.setEnabled(true)
        try #require(launcher.last).exit(ProcessExit(status: 75, signaled: true))
        #expect(supervisor.state == .restarting(count: 1))
    }

    @Test("Interrupteur rallumé pendant l'arrêt : ptzd repart à la fin de l'arrêt")
    func reenableDuringStop() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        let first = try #require(launcher.last)
        first.ignoresTerminate = true
        supervisor.setEnabled(false)
        supervisor.setEnabled(true)
        #expect(launcher.launched.count == 1)
        scheduler.advance(by: ServiceSupervisor.killDelay)
        #expect(first.kills == 1)
        #expect(launcher.launched.count == 2)
        #expect(supervisor.state == .running)
    }

    @Test("Arrêt pour quitter : jamais de relance, même interrupteur rallumé")
    func quitStop() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        let first = try #require(launcher.last)
        first.ignoresTerminate = true
        var done = false
        supervisor.stop(forQuit: true) { done = true }
        supervisor.setEnabled(true)
        scheduler.advance(by: ServiceSupervisor.killDelay)
        #expect(done)
        #expect(supervisor.state == .stopped)
        supervisor.start()
        #expect(launcher.launched.count == 1)
    }

    @Test("Fin d'un ancien processus après relance : ignorée")
    func staleExit() throws {
        let supervisor = makeSupervisor()
        supervisor.start()
        let first = try #require(launcher.last)
        first.exit()
        scheduler.advance(by: 1)
        #expect(supervisor.state == .running)
        first.exit()
        #expect(supervisor.state == .running)
    }
}

@MainActor
@Suite("Lanceur de processus réel")
struct FoundationProcessLauncherTests {
    @Test("Sortie ajoutée au journal ; fin signalée avec le code ; SIGKILL")
    func realProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ptzbot-launcher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "logs/ptzd.log")
        let launcher = FoundationProcessLauncher()
        for word in ["un", "deux"] {
            let exit = try await withCheckedThrowingContinuation { continuation in
                do {
                    _ = try launcher.launch(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo \(word); echo erreur >&2; exit 3"], outputURL: log) {
                        continuation.resume(returning: $0)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            #expect(exit == ProcessExit(status: 3, signaled: false))
        }
        #expect(try String(contentsOf: log, encoding: .utf8) == "un\nerreur\ndeux\nerreur\n")
        let handle = try FoundationProcessLauncher.appendingHandle(log)
        #expect(fcntl(handle.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(handle.fileDescriptor, F_GETFL) & O_APPEND != 0)
        try handle.close()

        var ended: ProcessExit?
        let sleeper = try launcher.launch(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], outputURL: log) { ended = $0 }
        #expect(sleeper.isRunning)
        sleeper.kill()
        for _ in 0..<100 where ended == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ended == ProcessExit(status: SIGKILL, signaled: true))
        #expect(!sleeper.isRunning)
    }
}
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : échec — la compilation des tests échoue : `ServiceSupervisor`, `ProcessLauncher` et `SettingsStore` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/ProcessLauncher.swift` :

```swift
import Foundation

/// La fin d'un processus lancé.
public struct ProcessExit: Equatable, Sendable {
    /// Code de sortie, ou numéro du signal.
    public var status: Int32
    /// Arrêté par un signal (SIGTERM, SIGKILL, plantage).
    public var signaled: Bool

    public init(status: Int32, signaled: Bool) {
        self.status = status
        self.signaled = signaled
    }
}

/// Un processus lancé par `ProcessLauncher`.
@MainActor
public protocol LaunchedProcess: AnyObject {
    var pid: pid_t { get }
    var isRunning: Bool { get }
    /// SIGTERM.
    func terminate()
    /// SIGKILL.
    func kill()
}

/// Lance un processus, sa sortie et ses erreurs ajoutées à un fichier ; derrière un protocole pour les tests.
@MainActor
public protocol ProcessLauncher: AnyObject {
    /// `onExit` est appelé une fois, sur le MainActor, quand le processus se termine.
    func launch(
        executableURL: URL,
        arguments: [String],
        outputURL: URL,
        onExit: @escaping @MainActor (ProcessExit) -> Void
    ) throws -> any LaunchedProcess
}

/// Implémentation réelle, sur `Process`.
@MainActor
public final class FoundationProcessLauncher: ProcessLauncher {
    public init() {}

    public func launch(
        executableURL: URL,
        arguments: [String],
        outputURL: URL,
        onExit: @escaping @MainActor (ProcessExit) -> Void
    ) throws -> any LaunchedProcess {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let output = try Self.appendingHandle(outputURL)
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { finished in
            let exit = ProcessExit(status: finished.terminationStatus, signaled: finished.terminationReason == .uncaughtSignal)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onExit(exit) }
            }
        }
        defer {
            // Le fils a sa propre copie du descripteur : celle de l'app fuirait à chaque lancement.
            try? output.close()
        }
        try process.run()
        return FoundationLaunchedProcess(process: process)
    }

    /// Le fichier ouvert en ajout (`O_APPEND`), créé avec son dossier au besoin. `O_CLOEXEC` : seul le processus
    /// lancé en hérite, par sa sortie standard, pas les autres enfants de l'app.
    static func appendingHandle(_ url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

@MainActor
private final class FoundationLaunchedProcess: LaunchedProcess {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var pid: pid_t {
        process.processIdentifier
    }

    var isRunning: Bool {
        process.isRunning
    }

    func terminate() {
        process.terminate()
    }

    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/Scheduler.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/Scheduler.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/Scheduler.swift
index f1546fe..0626c57 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/Scheduler.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/Scheduler.swift
@@ -8,6 +8,8 @@ public protocol Cancellable: AnyObject {
 /// Minuteries, injectées pour que les tests maîtrisent le temps.
 @MainActor
 public protocol Scheduler: AnyObject {
+    /// Temps monotone, en secondes.
+    var now: TimeInterval { get }
     @discardableResult
     func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable
 }
@@ -17,6 +19,10 @@ public protocol Scheduler: AnyObject {
 public final class MainScheduler: Scheduler {
     public init() {}
 
+    public var now: TimeInterval {
+        ProcessInfo.processInfo.systemUptime
+    }
+
     @discardableResult
     public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
         let item = DispatchWorkItem {
PATCH
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceSupervisor.swift` :

```swift
import Foundation
import Observation

/// Lance `ptzd`, processus enfant de l'app, le relance s'il s'arrête et l'arrête à la demande
/// (spec ptzd dans l'app § 5.3). « Actif » dans le panneau vient de la connexion de confiance (PanelModel) :
/// `running` veut seulement dire que le processus vit.
@MainActor
@Observable
public final class ServiceSupervisor {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running
        /// Arrêt inattendu ; relance prévue (n-ième relance de suite).
        case restarting(count: Int)
        case failed(reason: String)
    }

    /// Les chemins donnés à ptzd.
    public struct Paths: Equatable, Sendable {
        public var ptzd: URL
        public var ai: URL
        public var sdkDirectory: URL
        /// Journal de ptzd : sa sortie et ses erreurs y sont ajoutées.
        public var log: URL

        public init(ptzd: URL, ai: URL, sdkDirectory: URL, log: URL) {
            self.ptzd = ptzd
            self.ai = ai
            self.sdkDirectory = sdkDirectory
            self.log = log
        }
    }

    /// Délais de relance successifs ; le dernier se répète.
    public static let restartDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    /// Au-delà de `maxUnexpectedExits` arrêts inattendus en `failureWindow` secondes : `failed`.
    public static let maxUnexpectedExits = 5
    /// Un ptzd qui a tenu `failureWindow` secondes repart du premier délai.
    public static let failureWindow: TimeInterval = 120
    /// Délai entre SIGTERM et SIGKILL.
    public static let killDelay: TimeInterval = 5
    public static let enabledKey = "serviceEnabled"
    public static let crashLoopReason = "ptzd s'arrête sans cesse : ouvrez le journal"

    /// Codes de sortie de ptzd qui ne se corrigent pas en relançant : `failed`, sans relance.
    public static let busyStatus: Int32 = 75
    public static let configStatus: Int32 = 78
    public static let usageStatus: Int32 = 64
    public static let configReason = "config.json est invalide : ouvrez le journal"
    public static let usageReason = "Arguments de ptzd refusés"

    public static func busyReason(port: Int) -> String {
        "Le port \(port) est déjà pris : un autre ptzd tourne peut-être encore"
    }

    public private(set) var state: State = .stopped
    /// L'interrupteur « Service ptzd », retenu d'un lancement à l'autre ; allumé au premier lancement.
    public private(set) var isEnabled: Bool
    /// Une ancienne installation (agent launchd) est active : aucun ptzd n'est lancé (§ 5.6).
    public var legacyAgentActive = false
    /// Port de ptzd (config.json), pour le message d'un port déjà pris.
    public var port = PTZDConfig.defaultPort

    @ObservationIgnored private let paths: Paths
    @ObservationIgnored private let launcher: any ProcessLauncher
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private let parentPID: pid_t
    @ObservationIgnored private var process: (any LaunchedProcess)?
    @ObservationIgnored private var launchedAt: TimeInterval = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restartCount = 0
    @ObservationIgnored private var unexpectedExits: [TimeInterval] = []
    @ObservationIgnored private var pendingRestart: (any Cancellable)?
    @ObservationIgnored private var pendingKill: (any Cancellable)?
    @ObservationIgnored private var stopping = false
    /// L'interrupteur a été rallumé pendant un arrêt : ptzd repart à la fin de l'arrêt.
    @ObservationIgnored private var restartAfterStop = false
    /// L'app se termine : plus aucun lancement.
    @ObservationIgnored private var quitting = false
    @ObservationIgnored private var stopCompletions: [@MainActor () -> Void] = []

    public init(
        paths: Paths,
        launcher: any ProcessLauncher,
        settings: any SettingsStore,
        scheduler: any Scheduler,
        parentPID: pid_t
    ) {
        self.paths = paths
        self.launcher = launcher
        self.settings = settings
        self.scheduler = scheduler
        self.parentPID = parentPID
        isEnabled = settings.bool(forKey: Self.enabledKey) ?? true
    }

    /// Le superviseur de l'app : vrai lanceur de processus, préférences de l'utilisateur, PID de l'app.
    public static func system(paths: Paths, scheduler: any Scheduler) -> ServiceSupervisor {
        ServiceSupervisor(
            paths: paths,
            launcher: FoundationProcessLauncher(),
            settings: UserDefaultsSettingsStore(defaults: .standard),
            scheduler: scheduler,
            parentPID: getpid()
        )
    }

    /// Les arguments de ptzd (§ 5.4).
    public var arguments: [String] {
        ["--parent", String(parentPID), "--ai", paths.ai.path, "--sdk", paths.sdkDirectory.path]
    }

    /// Lance ptzd s'il est autorisé, qu'aucun ancien agent n'est actif et qu'il ne tourne pas déjà.
    /// Depuis `failed`, repart de zéro.
    public func start() {
        guard isEnabled, !legacyAgentActive, !stopping, !quitting else { return }
        switch state {
        case .stopped, .failed:
            restartCount = 0
            unexpectedExits = []
            launch()
        case .starting, .running, .restarting:
            break
        }
    }

    /// SIGTERM, puis SIGKILL 5 s plus tard s'il vit encore ; `completion` quand ptzd est terminé.
    /// `forQuit` : l'app se termine, ptzd ne sera plus relancé, même si l'interrupteur est rallumé.
    public func stop(forQuit: Bool = false, completion: @escaping @MainActor () -> Void = {}) {
        if forQuit {
            quitting = true
        }
        restartAfterStop = false
        pendingRestart?.cancel()
        pendingRestart = nil
        guard let process else {
            state = .stopped
            completion()
            return
        }
        stopCompletions.append(completion)
        guard !stopping else { return }
        stopping = true
        process.terminate()
        pendingKill = scheduler.schedule(after: Self.killDelay) { [weak self] in
            guard let self, let process = self.process else { return }
            pendingKill = nil
            process.kill()
        }
    }

    /// L'interrupteur « Service ptzd » : retenu, puis ptzd lancé ou arrêté.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        settings.set(enabled, forKey: Self.enabledKey)
        if enabled {
            if stopping {
                restartAfterStop = !quitting
            } else {
                start()
            }
        } else {
            stop()
        }
    }

    // MARK: - Processus

    private func launch() {
        state = .starting
        // Chaque lancement a son numéro : la fin d'un processus déjà remplacé est ignorée.
        generation += 1
        let launchedGeneration = generation
        let launched: any LaunchedProcess
        do {
            launched = try launcher.launch(executableURL: paths.ptzd, arguments: arguments, outputURL: paths.log) { [weak self] exit in
                guard let self, launchedGeneration == generation, process != nil else { return }
                exited(exit)
            }
        } catch {
            state = .failed(reason: "ptzd n'a pas pu être lancé : \(error.localizedDescription)")
            return
        }
        process = launched
        launchedAt = scheduler.now
        state = .running
    }

    private func exited(_ exit: ProcessExit) {
        process = nil
        pendingKill?.cancel()
        pendingKill = nil
        if stopping {
            stopping = false
            state = .stopped
            let completions = stopCompletions
            stopCompletions = []
            completions.forEach { $0() }
            if restartAfterStop {
                restartAfterStop = false
                start()
            }
            return
        }
        if !exit.signaled, let reason = permanentFailure(exit.status) {
            state = .failed(reason: reason)
            return
        }
        unexpectedExit()
    }

    /// Une sortie qu'une relance ne corrigerait pas : port ou verrou pris, config.json invalide, arguments refusés.
    private func permanentFailure(_ status: Int32) -> String? {
        switch status {
        case Self.busyStatus: Self.busyReason(port: port)
        case Self.configStatus: Self.configReason
        case Self.usageStatus: Self.usageReason
        default: nil
        }
    }

    private func unexpectedExit() {
        let now = scheduler.now
        if now - launchedAt >= Self.failureWindow {
            // ptzd a tenu : les délais repartent du premier.
            restartCount = 0
        }
        unexpectedExits = unexpectedExits.filter { now - $0 < Self.failureWindow } + [now]
        guard unexpectedExits.count <= Self.maxUnexpectedExits else {
            state = .failed(reason: Self.crashLoopReason)
            return
        }
        restartCount += 1
        state = .restarting(count: restartCount)
        let delay = Self.restartDelays[min(restartCount, Self.restartDelays.count) - 1]
        pendingRestart = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            pendingRestart = nil
            guard isEnabled, !legacyAgentActive, case .restarting = state else { return }
            launch()
        }
    }
}
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/SettingsStore.swift` :

```swift
import Foundation

/// Les préférences de l'app, derrière un protocole pour les tests.
@MainActor
public protocol SettingsStore: AnyObject {
    func bool(forKey key: String) -> Bool?
    func set(_ value: Bool, forKey key: String)
}

/// Implémentation réelle : `UserDefaults`.
@MainActor
public final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func bool(forKey key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    public func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : tout passe (PTZBotKit : 38 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add mac/app/PTZBotKit/Sources/PTZBotKit/ProcessLauncher.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/Scheduler.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/ServiceSupervisor.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/SettingsStore.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceSupervisorTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|8\.8\.8\.8|256\.0\.0\.1|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
B1 : PTZBotKit ServiceSupervisor

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés plus haut sont déjà indexés par `git rm`.

### Tâche 3 : PTZBotKit : examen et installation du SDK

**But :** L'app examine un `.zip`, un dossier ou un `.dylib` du SDK OBSBOT. Elle en lit l'architecture (en-têtes Mach-O), la signature, la provenance et la quarantaine, et refuse tout ce qui n'est pas un fichier ordinaire avec une tranche arm64. L'installation copie le fichier, retire la quarantaine de la copie, échange atomiquement en gardant l'ancien jusqu'à la vérification de chargement, et revient en arrière en cas d'échec (spec B1 § 6.2 et § 11).

**Fichiers :**
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift`
- Créer : `mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift`

**Interfaces :**
- Produit (module PTZBotKit) :
  - `SDKCandidate` (`path`, `architectures`, `signer`, `team`, `quarantined`, `origin`, `temporaryDirectory`, `otherCopies`, `isArm64`) et `SDKOrigin` ;
  - `SDKRejection` (`message`) ;
  - `SDKInspector.inspect(_:) throws(SDKRejection)`, `discard(_:)`, `libraryPath` (`macos/arm64-release/libdev.dylib`) ;
  - `SDKStatus` : `ready`, `absent`, `quarantined`, `incompatible`, `unloadable` ;
  - `SDKInstallError` ;
  - `SDKInstaller(sdkDirectory:verifier:)` : `install(_:) throws(SDKInstallError)`, `status()`, `isInstalling`, `libraryURL`, `obsbotAIVerifier(...)` (sortie 3 d'`obsbot-ai` sans argument, avec `DYLD_LIBRARY_PATH`).

- [ ] **Étape 1 : Écrire les tests**

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift` :

```swift
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
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : échec — la compilation des tests échoue : `SDKInspector`, `SDKInstaller` et `SDKCandidate` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift` :

```swift
import Foundation
import Security

/// D'où vient un fichier, selon macOS : l'adresse notée au téléchargement et la date de la quarantaine.
public struct SDKOrigin: Equatable, Sendable {
    public var url: String?
    public var date: Date?

    public init(url: String?, date: Date?) {
        self.url = url
        self.date = date
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
    /// Les autres `libdev.dylib` du choix, ignorés (chemins relatifs à la racine du SDK).
    public var otherCopies: [String]

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
        otherCopies: [String] = []
    ) {
        self.path = path
        self.architectures = architectures
        self.signer = signer
        self.team = team
        self.quarantined = quarantined
        self.origin = origin
        self.temporaryDirectory = temporaryDirectory
        self.otherCopies = otherCopies
    }
}

/// Motif du refus d'un fichier.
public enum SDKRejection: Error, Equatable, Sendable {
    case notFound
    case notRegularFile
    case notMachO
    case noArm64(architectures: [String])
    case extractionFailed(String)

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

    /// Bloquant (décompression, lecture des en-têtes et de la signature) : à appeler hors du fil principal.
    public static func inspect(_ url: URL) throws(SDKRejection) -> SDKCandidate {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw .notFound
        }
        if isDirectory.boolValue {
            guard let located = locate(in: url) else { throw .notFound }
            return try describe(located.library, archive: nil, temporaryDirectory: nil, otherCopies: located.otherCopies)
        }
        if url.pathExtension.lowercased() == "zip" {
            let directory = try extract(url)
            guard let located = locate(in: directory) else {
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
    static func locate(in directory: URL) -> (library: URL, otherCopies: [String])? {
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
        let chosen = library.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: library.lastPathComponent).path
        var others: [String] = []
        if let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let file as URL in enumerator {
                if enumerator.level >= maxSearchDepth {
                    enumerator.skipDescendants()
                }
                guard enumerator.level <= maxSearchDepth, file.lastPathComponent == "libdev.dylib" else { continue }
                let path = file.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: file.lastPathComponent).path
                guard path != chosen else { continue }
                others.append(path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path)
            }
        }
        return (library, others.sorted())
    }

    /// Décompresse l'archive dans un dossier temporaire avec `ditto`.
    static func extract(_ archive: URL) throws(SDKRejection) -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ptzbot-sdk-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw .extractionFailed(error.localizedDescription)
        }
        process.waitUntilExit()
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
        // La provenance d'une archive est sur l'archive : ditto ne la recopie pas sur ce qu'il décompresse.
        let sources = [library] + (archive.map { [$0] } ?? [])
        let quarantine = sources.lazy.compactMap(quarantineValue).first
        let whereFrom = sources.lazy.compactMap(whereFrom).first
        let date = quarantine.flatMap(quarantineDate)
        return SDKCandidate(
            path: library,
            architectures: architectures,
            signer: signing.signer,
            team: signing.team,
            quarantined: quarantine != nil,
            origin: whereFrom == nil && date == nil ? nil : SDKOrigin(url: whereFrom, date: date),
            temporaryDirectory: temporaryDirectory,
            otherCopies: otherCopies
        )
    }

    // MARK: - Signature

    /// Le résumé du certificat du signataire et l'équipe ; nil pour un fichier non signé ou signé ad hoc.
    static func signing(of url: URL) -> (signer: String?, team: String?) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return (nil, nil) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else {
            return (nil, nil)
        }
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let signer = certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        return (signer, info[kSecCodeInfoTeamIdentifier as String] as? String)
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
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift` :

```swift
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
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : tout passe (PTZBotKit : 56 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|8\.8\.8\.8|256\.0\.0\.1|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
B1 : PTZBotKit examen et installation du SDK

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés plus haut sont déjà indexés par `git rm`.

### Tâche 4 : PTZBotKit : migration et `config.json` au premier lancement

**But :** L'app détecte l'ancien agent launchd. Elle le retire (`bootout`, attente de 10 s), renomme sa plist en `.plist.bak`, met les anciens binaires à la corbeille et reprend le SDK de `lib/` dans `sdk/` : tout est injecté et rien n'est jamais effacé. Elle crée `config.json` quand il manque, avec l'adresse Tailscale d'une interface `utun*` (spec B1 § 5.5, § 5.6 et § 11).

**Fichiers :**
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/ConfigBootstrap.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/LegacyAgent.swift`
- Créer : `mac/app/PTZBotKit/Tests/PTZBotKitTests/MigrationTests.swift`

**Interfaces :**
- Produit (module PTZBotKit) :
  - `InterfaceAddress`, `InterfaceAddressProvider` et `SystemInterfaceAddresses` ;
  - `ConfigBootstrap.run(configURL:addresses:)`, qui rend `Outcome` (`existing`, `created(listenAddress:)`, `tailscaleMissing`), ainsi que `tailscaleAddress(in:)`, `isTailscale(_:)` et `loopback` ;
  - `Launchctl` / `SystemLaunchctl` et `Trash` / `FileManagerTrash` ;
  - `LegacyMigrationError` ;
  - `LegacyAgent` :
    - constantes `label`, `binaries`, `stopTimeout` (10), `pollInterval` ;
    - `Report` ;
    - `init(...)` sans valeur par défaut, et fabrique `system(supportDirectory:)` ;
    - `detect()`, `migrate()`, `plistURL`, `backupURL`.

- [ ] **Étape 1 : Écrire les tests**

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/MigrationTests.swift` :

```swift
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

@Suite("Migration depuis l'ancienne installation")
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

@Suite("config.json au premier lancement")
struct ConfigBootstrapTests {
    @Test("Interface Tailscale : config.json écoute sur son adresse")
    func tailscale() throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "ObsbotNacelle/config.json")
        let outcome = try ConfigBootstrap.run(configURL: url, addresses: FakeInterfaces(addresses: ["127.0.0.1", "100.64.0.1"]))
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

    @Test("Interface utun préférée ; une autre interface en 100.64/10 seulement à défaut")
    func prefersUtun() throws {
        let other = InterfaceAddress(interface: "en5", address: "100.64.0.0")
        let utun = InterfaceAddress(interface: "utun4", address: "100.64.0.1")
        #expect(ConfigBootstrap.tailscaleAddress(in: [other, utun]) == "100.64.0.1")
        #expect(ConfigBootstrap.tailscaleAddress(in: [other]) == "100.64.0.0")
        #expect(ConfigBootstrap.tailscaleAddress(in: [InterfaceAddress(interface: "lo0", address: "127.0.0.1")]) == nil)
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        #expect(try ConfigBootstrap.run(configURL: url, addresses: FakeInterfaces(interfaces: [other, utun])) == .created(listenAddress: "100.64.0.1"))
    }

    @Test("Interfaces réelles : au moins la boucle locale, sur lo0")
    func realInterfaces() {
        #expect(SystemInterfaceAddresses().ipv4Addresses().contains(InterfaceAddress(interface: "lo0", address: "127.0.0.1")))
    }
}
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : échec — la compilation des tests échoue : `LegacyAgent`, `ConfigBootstrap` et `Launchctl` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/ConfigBootstrap.swift` :

```swift
import Foundation

/// Une adresse IPv4 et son interface (« utun4 », « en0 »…).
public struct InterfaceAddress: Equatable, Sendable {
    public var interface: String
    public var address: String

    public init(interface: String, address: String) {
        self.interface = interface
        self.address = address
    }
}

/// Les adresses IPv4 des interfaces du Mac, derrière un protocole pour les tests.
public protocol InterfaceAddressProvider: Sendable {
    func ipv4Addresses() -> [InterfaceAddress]
}

/// Implémentation réelle : `getifaddrs`.
public struct SystemInterfaceAddresses: InterfaceAddressProvider {
    public init() {}

    public func ipv4Addresses() -> [InterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [InterfaceAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append(InterfaceAddress(interface: String(cString: entry.pointee.ifa_name), address: text))
        }
        return result
    }
}

/// Premier lancement sur un Mac neuf : crée `config.json` s'il manque (spec ptzd dans l'app § 5.5).
public enum ConfigBootstrap {
    public enum Outcome: Equatable, Sendable {
        /// `config.json` existait : rien n'est changé.
        case existing
        /// Créé avec l'adresse Tailscale.
        case created(listenAddress: String)
        /// Créé sur 127.0.0.1 seulement : pas d'interface Tailscale.
        case tailscaleMissing
    }

    public static let loopback = "127.0.0.1"

    /// 100.64.0.0/10, la plage de Tailscale.
    public static func isTailscale(_ text: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return false }
        return UInt32(bigEndian: address.s_addr) & 0xFFC0_0000 == 0x6440_0000
    }

    /// L'adresse 100.64/10 d'une interface `utun*` (Tailscale), sinon celle d'une autre interface.
    public static func tailscaleAddress(in interfaces: [InterfaceAddress]) -> String? {
        let candidates = interfaces.filter { isTailscale($0.address) }
        return (candidates.first { $0.interface.hasPrefix("utun") } ?? candidates.first)?.address
    }

    public static func run(configURL: URL, addresses: any InterfaceAddressProvider) throws -> Outcome {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: configURL.path) else { return .existing }
        let tailscale = tailscaleAddress(in: addresses.ipv4Addresses())
        let listenAddress = tailscale ?? loopback
        try manager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\n  \"listenAddress\": \"\(listenAddress)\"\n}\n".utf8).write(to: configURL, options: .withoutOverwriting)
        return tailscale.map { .created(listenAddress: $0) } ?? .tailscaleMissing
    }
}
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/LegacyAgent.swift` :

```swift
import Foundation

/// `launchctl`, derrière un protocole pour les tests : l'app ne touche à launchd que pour l'ancien agent.
public protocol Launchctl: Sendable {
    func isLoaded(label: String) -> Bool
    func bootout(label: String) throws
}

/// Implémentation réelle : `/bin/launchctl print|bootout gui/<uid>/<label>`.
public struct SystemLaunchctl: Launchctl {
    public struct Failure: LocalizedError {
        public var status: Int32
        public var errorDescription: String? { "launchctl bootout a échoué (code \(status))." }
    }

    public init() {}

    private func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func target(_ label: String) -> String {
        "gui/\(getuid())/\(label)"
    }

    public func isLoaded(label: String) -> Bool {
        run(["print", target(label)]) == 0
    }

    public func bootout(label: String) throws {
        let status = run(["bootout", target(label)])
        guard status == 0 else { throw Failure(status: status) }
    }
}

/// La corbeille, derrière un protocole pour les tests : les anciens binaires y vont, jamais effacés.
public protocol Trash: Sendable {
    func trash(_ url: URL) throws
}

/// Implémentation réelle : `FileManager.trashItem`.
public struct FileManagerTrash: Trash {
    public init() {}

    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// Échec de la migration : l'app reste branchée sur l'ancien ptzd (spec ptzd dans l'app § 5.6).
public enum LegacyMigrationError: Error, Equatable, Sendable {
    case bootoutFailed(String)
    /// L'ancien ptzd est encore chargé 5 s après le `bootout`.
    case stillLoaded
    case renameFailed(String)

    public var message: String {
        switch self {
        case let .bootoutFailed(reason):
            "L'ancienne installation n'a pas pu être arrêtée : \(reason)"
        case .stillLoaded:
            "L'ancienne installation ne s'est pas arrêtée à temps."
        case let .renameFailed(reason):
            "L'ancienne installation est arrêtée, mais sa plist n'a pas pu être renommée : \(reason)"
        }
    }
}

/// L'ancienne installation : l'agent launchd `io.github.djoko-cli.obsbot-nacelle.ptzd` et les binaires
/// de `bin/` (spec ptzd dans l'app § 5.6). Bloquant (launchctl, attente) : à appeler hors du fil principal.
public struct LegacyAgent: Sendable {
    public static let label = "io.github.djoko-cli.obsbot-nacelle.ptzd"
    public static let binaries = ["bin/ptzd", "bin/obsbot-ai", "bin/obsbot-ai-off"]
    /// launchd peut mettre plusieurs secondes à arrêter l'ancien ptzd.
    public static let stopTimeout: TimeInterval = 10
    public static let pollInterval: TimeInterval = 0.25

    /// Ce que la migration n'a pas pu faire sans échouer pour autant (corbeille, reprise du SDK).
    public struct Report: Equatable, Sendable {
        public var trashed: [String] = []
        public var movedSDK = false
        public var problems: [String] = []
    }

    public let launchAgentsDirectory: URL
    public let supportDirectory: URL
    private let launchctl: any Launchctl
    private let trash: any Trash
    private let sleep: @Sendable (TimeInterval) -> Void

    public init(
        launchAgentsDirectory: URL,
        supportDirectory: URL,
        launchctl: any Launchctl,
        trash: any Trash,
        sleep: @escaping @Sendable (TimeInterval) -> Void
    ) {
        self.launchAgentsDirectory = launchAgentsDirectory
        self.supportDirectory = supportDirectory
        self.launchctl = launchctl
        self.trash = trash
        self.sleep = sleep
    }

    /// L'ancienne installation du Mac : vrai `~/Library/LaunchAgents`, vrai launchctl, vraie corbeille.
    public static func system(supportDirectory: URL) -> LegacyAgent {
        LegacyAgent(
            launchAgentsDirectory: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents"),
            supportDirectory: supportDirectory,
            launchctl: SystemLaunchctl(),
            trash: FileManagerTrash(),
            sleep: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    public var plistURL: URL {
        launchAgentsDirectory.appending(path: "\(Self.label).plist")
    }

    public var backupURL: URL {
        launchAgentsDirectory.appending(path: "\(Self.label).plist.bak")
    }

    /// `<label>.plist.<date>.bak`, quand l'ancienne sauvegarde ne peut pas aller à la corbeille.
    func datedBackupURL(_ date: Date) -> URL {
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted))
        return launchAgentsDirectory.appending(path: "\(Self.label).plist.\(stamp).bak")
    }

    /// La plist existe ou l'agent est chargé.
    public func detect() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path) || launchctl.isLoaded(label: Self.label)
    }

    /// « Remplacer » : `bootout`, attente de l'arrêt (10 s au plus), plist renommée en `.plist.bak`, anciens
    /// binaires à la corbeille, SDK de `lib/` repris dans `sdk/` s'il n'y en a pas. Un `bootout` en échec
    /// ne change rien d'autre.
    public func migrate() throws(LegacyMigrationError) -> Report {
        if launchctl.isLoaded(label: Self.label) {
            do {
                try launchctl.bootout(label: Self.label)
            } catch {
                // bootout peut échouer alors que l'agent est bien parti (déjà en cours d'arrêt) : seul compte
                // qu'il ne soit plus chargé.
                guard !launchctl.isLoaded(label: Self.label) else {
                    throw .bootoutFailed(error.localizedDescription)
                }
            }
            var waited: TimeInterval = 0
            while launchctl.isLoaded(label: Self.label) {
                guard waited < Self.stopTimeout else { throw .stillLoaded }
                sleep(Self.pollInterval)
                waited += Self.pollInterval
            }
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: plistURL.path) {
            do {
                var backup = backupURL
                if manager.fileExists(atPath: backup.path) {
                    // Une sauvegarde plus ancienne va à la corbeille, jamais effacée ; sinon la nouvelle est datée.
                    do {
                        try trash.trash(backup)
                    } catch {
                        backup = datedBackupURL(Date())
                    }
                }
                try manager.moveItem(at: plistURL, to: backup)
            } catch {
                throw .renameFailed(error.localizedDescription)
            }
        }

        var report = Report()
        for path in Self.binaries {
            let url = supportDirectory.appending(path: path)
            guard manager.fileExists(atPath: url.path) else { continue }
            do {
                try trash.trash(url)
                report.trashed.append(path)
            } catch {
                report.problems.append("\(path) n'a pas pu être mis à la corbeille : \(error.localizedDescription)")
            }
        }

        let oldSDK = supportDirectory.appending(path: "lib/libdev.dylib")
        let newSDK = supportDirectory.appending(path: "sdk/libdev.dylib")
        if manager.fileExists(atPath: oldSDK.path), !manager.fileExists(atPath: newSDK.path) {
            do {
                try manager.createDirectory(at: newSDK.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: oldSDK, to: newSDK)
                report.movedSDK = true
            } catch {
                report.problems.append("Le SDK de lib/ n'a pas pu être repris : \(error.localizedDescription)")
            }
        }
        return report
    }
}
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : tout passe (PTZBotKit : 69 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add mac/app/PTZBotKit/Sources/PTZBotKit/ConfigBootstrap.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/LegacyAgent.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/MigrationTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|8\.8\.8\.8|256\.0\.0\.1|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
B1 : PTZBotKit migration et config.json au premier lancement

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés plus haut sont déjà indexés par `git rm`.

### Tâche 5 : L'app : utilitaires dans le paquet, panneau, fenêtre du SDK, réseau local

**But :** La construction compile `ptzd` et `obsbot-ai` dans `Contents/Helpers`, et refuse un paquet qui contiendrait le SDK. L'app déclare le réseau local et Bonjour. Au lancement, elle fait la migration ou démarre le service, et « Quitter » attend `ptzd`. Le panneau est réorganisé en sections, ne liste plus que les iPhone et propose la fenêtre « SDK OBSBOT » (spec B1 § 5.1, § 5.3, § 6 et § 11).

**Fichiers :**
- Modifier : `mac/app/PTZBot/PTZBotApp.swift`
- Modifier : `mac/app/PTZBot/PanelView.swift`
- Créer : `mac/app/PTZBot/SDKView.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/ConfigBootstrap.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/LocalNetworkProbe.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/SDKWindowModel.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift`
- Créer : `mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift`
- Créer : `mac/app/build-helpers.sh`
- Créer : `mac/app/check-bundle.sh`
- Modifier : `mac/app/project.yml`

**Interfaces :**
- Consomme : tâches 2, 3 et 4.
- Produit (module PTZBotKit) :
  - `AppPaths(bundle:home:)`, fabrique `system()` ;
  - `AppController` :
    - `Legacy` ;
    - `launch()`, `offerMigration()`, `replaceLegacy()`, `refreshSDK()`, `quit(completion:)`, `quitTimeout` (6) ;
    - propriétés `canReplaceLegacy`, `sdkStatus`, `tailscaleMissing`, `configError`, `migrationError` ;
  - `SDKWindowModel` (`Phase`) ;
  - `LocalNetworkProbe` ;
  - `ServiceLabels` ;
  - `PanelModel` : `iPhoneClients`, `reloadConfig(_:)`.
- App :
  - `build-helpers.sh`, phase de construction ;
  - `check-bundle.sh` ;
  - `project.yml` : `NSLocalNetworkUsageDescription`, `NSBonjourServices` et la phase des utilitaires ;
  - `PTZBotApp` : délégué qui répond à la fin de l'app par la boucle d'événements ;
  - `PanelView` en sections ;
  - `SDKView`.
- Prérequis de construction : le SDK dans `vendor/obsbot-sdk/` (en-têtes) ; il n'est jamais copié dans l'app.

- [ ] **Étape 1 : Écrire les tests**

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift` :

```swift
import Foundation
import Network
import Testing
@testable import PTZBotKit

@MainActor
@Suite("Lancement et arrêt de l'app")
struct AppControllerTests {
    let root: URL
    let paths: AppPaths
    let launcher = FakeLauncher()
    let scheduler = FakeScheduler()
    let launchctl = FakeLaunchctl()
    let supervisor: ServiceSupervisor

    init() throws {
        root = try FakeSDK.directory()
        paths = AppPaths(bundle: root.appending(path: "PTZBot.app"), home: root)
        supervisor = ServiceSupervisor(paths: paths.service, launcher: launcher, settings: FakeSettings(), scheduler: scheduler, parentPID: 4242)
    }

    private func controller(
        addresses: [String] = ["127.0.0.1"],
        sdkLoads: Bool = true,
        confirm: Bool = true,
        asked: Counter = Counter(),
        answers: Answers? = nil
    ) -> AppController {
        AppController(
            supervisor: supervisor,
            legacyAgent: LegacyAgent(
                launchAgentsDirectory: root.appending(path: "LaunchAgents"),
                supportDirectory: paths.support,
                launchctl: launchctl,
                trash: FakeTrash(directory: root.appending(path: "Trash")),
                sleep: { _ in }
            ),
            configURL: paths.config,
            interfaces: FakeInterfaces(addresses: addresses),
            sdkInstaller: SDKInstaller(sdkDirectory: paths.sdkDirectory, verifier: FakeVerifier(sdkLoads).verifier),
            scheduler: scheduler,
            confirmMigration: {
                asked.value += 1
                return answers?.next() ?? confirm
            }
        )
    }

    /// L'installation actuelle : agent chargé, plist, SDK dans lib/.
    private func installLegacy() throws {
        try FakeSDK.write(Data("<plist/>".utf8), to: root.appending(path: "LaunchAgents/\(LegacyAgent.label).plist"))
        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: paths.support.appending(path: "lib/libdev.dylib"))
        try FakeSDK.write(Data(#"{"listenAddress":"100.64.0.1"}"#.utf8), to: paths.config)
        launchctl.state.withLock { $0.loaded = true }
    }

    @Test("Mac neuf : config.json créé, ptzd lancé, SDK absent, Tailscale signalé manquant")
    func freshMac() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let asked = Counter()
        let app = controller(asked: asked)
        var configReady = 0
        app.onConfigReady = { configReady += 1 }
        await app.launch()
        #expect(asked.value == 0)
        #expect(app.legacy == .none)
        #expect(FileManager.default.fileExists(atPath: paths.config.path))
        #expect(app.tailscaleMissing)
        #expect(configReady == 1)
        #expect(supervisor.state == .running)
        #expect(launcher.executables == [paths.ptzd])
        #expect(try #require(launcher.last).arguments == ["--parent", "4242", "--ai", paths.obsbotAI.path, "--sdk", paths.sdkDirectory.path])
        #expect(app.sdkStatus == .absent)
        await app.launch()
        #expect(launcher.launched.count == 1)
    }

    @Test("Interface Tailscale : pas de message")
    func tailscale() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller(addresses: ["127.0.0.1", "100.64.0.1"])
        await app.launch()
        #expect(!app.tailscaleMissing)
    }

    @Test("config.json existant sur 127.0.0.1 : Tailscale signalé manquant, fichier inchangé")
    func existingLoopback() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let json = Data(#"{"listenAddress":"127.0.0.1","port":19870}"#.utf8)
        try FakeSDK.write(json, to: paths.config)
        let app = controller(addresses: ["100.64.0.1"])
        await app.launch()
        #expect(app.tailscaleMissing)
        #expect(try Data(contentsOf: paths.config) == json)
        #expect(!ConfigBootstrap.listensOnLoopbackOnly(configURL: root.appending(path: "absent.json")))
    }

    @Test("Ancienne installation, « Remplacer » : migration, puis ptzd de l'app ; SDK repris et prêt")
    func replace() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        let asked = Counter()
        let app = controller(asked: asked)
        await app.launch()
        #expect(asked.value == 1)
        #expect(app.legacy == .none)
        #expect(app.migrationError == nil)
        #expect(!supervisor.legacyAgentActive)
        #expect(supervisor.state == .running)
        #expect(app.sdkStatus == .ready)
        #expect(FileManager.default.fileExists(atPath: paths.sdkDirectory.appending(path: "libdev.dylib").path))
        #expect(!app.tailscaleMissing)
    }

    @Test("Ancienne installation, « Plus tard » : aucun ptzd lancé, ancienne installation gardée")
    func later() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        let app = controller(confirm: false)
        await app.launch()
        #expect(app.legacy == .kept)
        #expect(supervisor.legacyAgentActive)
        supervisor.start()
        #expect(launcher.launched.isEmpty)
        #expect(supervisor.state == .stopped)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "LaunchAgents/\(LegacyAgent.label).plist").path))
    }

    @Test("« Plus tard », puis « Remplacer l'ancienne installation… » : même alerte, puis migration et ptzd")
    func replaceLater() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        let asked = Counter()
        let answers = Answers([false, false, true])
        let app = controller(asked: asked, answers: answers)
        await app.launch()
        #expect(app.canReplaceLegacy)
        await app.offerMigration()
        #expect(asked.value == 2)
        #expect(app.legacy == .kept)
        #expect(launcher.launched.isEmpty)
        await app.offerMigration()
        #expect(asked.value == 3)
        #expect(app.legacy == .none)
        #expect(!app.canReplaceLegacy)
        #expect(supervisor.state == .running)
        #expect(app.sdkStatus == .ready)
        await app.offerMigration()
        #expect(asked.value == 3)
    }

    @Test("bootout en échec puis réussi : le bouton relance la migration")
    func retryAfterFailure() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        launchctl.state.withLock { $0.bootoutFails = true }
        let app = controller()
        await app.launch()
        #expect(app.migrationError != nil)
        #expect(app.canReplaceLegacy)
        launchctl.state.withLock { $0.bootoutFails = false }
        await app.offerMigration()
        #expect(app.migrationError == nil)
        #expect(app.legacy == .none)
        #expect(launcher.launched.count == 1)
    }

    @Test("Échec du bootout : message, ancienne installation gardée, aucun ptzd")
    func migrationFailure() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try installLegacy()
        launchctl.state.withLock { $0.bootoutFails = true }
        let app = controller()
        await app.launch()
        #expect(app.legacy == .kept)
        #expect(app.migrationError == "L'ancienne installation n'a pas pu être arrêtée : code 5")
        #expect(launcher.launched.isEmpty)
    }

    @Test("ptzd sort avec 75 : « Le port <port de config.json> est déjà pris… », sans relance")
    func portBusy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FakeSDK.write(Data(#"{"listenAddress":"127.0.0.1","port":19870}"#.utf8), to: paths.config)
        let app = controller()
        await app.launch()
        try #require(launcher.last).exit(ProcessExit(status: 75, signaled: false))
        #expect(supervisor.state == .failed(reason: "Le port 19870 est déjà pris : un autre ptzd tourne peut-être encore"))
        #expect(Labels.service(supervisor.state, connection: .unreachable, legacy: false) == "Arrêté")
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
    }

    @Test("« Quitter » : interrupteur rallumé ensuite, ptzd n'est pas relancé")
    func quitIsFinal() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        await app.launch()
        try #require(launcher.last).ignoresTerminate = true
        var done = 0
        app.quit { done += 1 }
        supervisor.setEnabled(true)
        scheduler.advance(by: ServiceSupervisor.killDelay)
        #expect(done == 1)
        #expect(launcher.launched.count == 1)
    }

    @Test("« Quitter » : ptzd arrêté, puis completion une seule fois")
    func quit() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        await app.launch()
        var done = 0
        app.quit { done += 1 }
        #expect(try #require(launcher.last).terminations == 1)
        #expect(done == 1)
        scheduler.advance(by: AppController.quitTimeout)
        #expect(done == 1)
    }

    @Test("« Quitter » avec un ptzd dont la fin n'arrive jamais : completion au délai de sécurité, une seule fois")
    func quitTimeout() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        await app.launch()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        process.ignoresKill = true
        var done = 0
        app.quit { done += 1 }
        scheduler.advance(by: AppController.quitTimeout - 0.1)
        #expect(process.kills == 1)
        #expect(done == 0)
        scheduler.advance(by: 0.1)
        #expect(done == 1)
        scheduler.advance(by: 60)
        #expect(done == 1)
    }

    @Test("« Quitter » avec un ptzd bloqué : SIGKILL à 5 s, completion aussitôt après")
    func quitStubborn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = controller()
        await app.launch()
        try #require(launcher.last).ignoresTerminate = true
        var done = 0
        app.quit { done += 1 }
        scheduler.advance(by: ServiceSupervisor.killDelay - 0.1)
        #expect(done == 0)
        scheduler.advance(by: 0.1)
        #expect(done == 1)
        #expect(try #require(launcher.last).kills == 1)
    }
}

/// Réponses successives à l'alerte de migration.
@MainActor
final class Answers {
    private var queue: [Bool]

    init(_ queue: [Bool]) {
        self.queue = queue
    }

    func next() -> Bool? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
}

/// Compteur partagé avec une fermeture.
@MainActor
final class Counter {
    var value = 0
}

@MainActor
@Suite("Fenêtre « SDK OBSBOT »")
struct SDKWindowModelTests {
    @Test("Choix refusé : motif ; choix accepté puis autorisé : installé, dossier d'extraction effacé")
    func flow() async throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = SDKInstaller(sdkDirectory: directory.appending(path: "sdk"), verifier: FakeVerifier(true).verifier)
        let model = SDKWindowModel(installer: installer)
        var installed = 0
        model.onInstalled = { installed += 1 }

        let text = try FakeSDK.write(Data("texte".utf8), to: directory.appending(path: "texte.dylib"))
        await model.choose(text)
        #expect(model.phase == .rejected("Ce fichier n'est pas une bibliothèque Mach-O."))

        let library = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "choix/libdev.dylib"))
        FakeSDK.setQuarantine(library)
        await model.choose(library)
        guard case let .candidate(candidate) = model.phase else {
            Issue.record("candidat attendu")
            return
        }
        #expect(candidate.quarantined)
        await model.authorize()
        #expect(model.phase == .installed)
        #expect(installed == 1)
        #expect(!FakeSDK.isQuarantined(installer.libraryURL))
        #expect(FakeSDK.isQuarantined(library))
        model.reset()
        #expect(model.phase == .choosing)
    }

    @Test("Fenêtre fermée pendant l'examen : dossier d'extraction effacé, choix oublié")
    func closedDuringInspection() async throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let extraction = directory.appending(path: "extraction")
        let library = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: extraction.appending(path: "macos/arm64-release/libdev.dylib"))
        let model = SDKWindowModel(
            installer: SDKInstaller(sdkDirectory: directory.appending(path: "sdk"), verifier: FakeVerifier(true).verifier),
            inspect: { _ throws(SDKRejection) in
                Thread.sleep(forTimeInterval: 0.2)
                return SDKCandidate(path: library, architectures: ["arm64"], temporaryDirectory: extraction)
            }
        )
        let choice = Task { await model.choose(URL(fileURLWithPath: "/archive.zip")) }
        while model.phase != .inspecting {
            await Task.yield()
        }
        model.reset()
        await choice.value
        #expect(model.phase == .choosing)
        #expect(!FileManager.default.fileExists(atPath: extraction.path))
    }

    @Test("Vérification en échec : message, rien n'est installé")
    func failure() async throws {
        let directory = try FakeSDK.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = SDKInstaller(sdkDirectory: directory.appending(path: "sdk"), verifier: FakeVerifier(false).verifier)
        let model = SDKWindowModel(installer: installer)
        await model.choose(try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "libdev.dylib")))
        await model.authorize()
        #expect(model.phase == .failed(SDKInstallError.unloadable.message))
        #expect(!FileManager.default.fileExists(atPath: installer.libraryURL.path))
    }
}

@Suite("Textes du service et du SDK")
struct ServiceLabelsTests {
    @Test("État du service : supervision, puis connexion de confiance ; ancienne installation")
    func service() {
        #expect(Labels.service(.running, connection: .active, legacy: false) == "Actif")
        #expect(Labels.service(.running, connection: .connecting, legacy: false) == "Démarrage…")
        #expect(Labels.service(.running, connection: .unreachable, legacy: false) == "Ne répond pas")
        #expect(Labels.service(.starting, connection: .unreachable, legacy: false) == "Démarrage…")
        #expect(Labels.service(.stopped, connection: .unreachable, legacy: false) == "Arrêté")
        #expect(Labels.service(.failed(reason: "x"), connection: .unreachable, legacy: false) == "Arrêté")
        #expect(Labels.service(.restarting(count: 3), connection: .unreachable, legacy: false) == "Relancé après un arrêt inattendu (3)")
        #expect(Labels.service(.stopped, connection: .active, legacy: true) == "Ancienne installation")
    }

    @Test("Commandes grisées sauf service actif et connecté ; journal en cas d'échec ou sans réponse")
    func availability() {
        #expect(Labels.controlsEnabled(.running, connection: .active, legacy: false))
        #expect(!Labels.controlsEnabled(.running, connection: .unreachable, legacy: false))
        #expect(!Labels.controlsEnabled(.stopped, connection: .active, legacy: false))
        #expect(!Labels.controlsEnabled(.failed(reason: "x"), connection: .active, legacy: false))
        #expect(Labels.controlsEnabled(.stopped, connection: .active, legacy: true))
        #expect(Labels.showsLog(.failed(reason: "x"), connection: .unreachable))
        #expect(Labels.showsLog(.running, connection: .unreachable))
        #expect(!Labels.showsLog(.running, connection: .active))
        #expect(!Labels.showsLog(.stopped, connection: .unreachable))
    }

    @Test("SDK : états, suivi IA grisé tant qu'il n'est pas prêt (sauf ancienne installation)")
    func sdk() {
        #expect(Labels.sdk(.ready) == "Prêt")
        #expect(Labels.sdk(.absent) == "Absent")
        #expect(Labels.sdk(.quarantined) == "En quarantaine")
        #expect(Labels.sdk(.incompatible) == "Incompatible")
        #expect(Labels.sdk(.unloadable) == "Ne se charge pas")
        #expect(Labels.sdk(nil) == "Vérification…")
        #expect(Labels.aiNeedsSDK(.absent, legacy: false))
        #expect(Labels.aiNeedsSDK(nil, legacy: false))
        #expect(!Labels.aiNeedsSDK(.ready, legacy: false))
        #expect(!Labels.aiNeedsSDK(.absent, legacy: true))
        #expect(Labels.sdkRequired == "SDK OBSBOT requis")
        #expect(Labels.sdkAction(.ready) == "Changer…")
        #expect(Labels.sdkAction(.absent) == "Installer le SDK…")
        #expect(Labels.sdkAction(.quarantined) == "Installer le SDK…")
        #expect(Labels.sdkAction(nil) == nil)
        #expect(Labels.replaceLegacy == "Remplacer l'ancienne installation…")
    }

    @Test("Sections du panneau : Service, Caméra avec son état, iPhone connectés, note du suivi IA")
    func sections() {
        #expect(Labels.serviceSection == "Service")
        #expect(Labels.cameraSection(.connected) == "Caméra · branchée")
        #expect(Labels.cameraSection(.absent) == "Caméra · débranchée")
        #expect(Labels.cameraSection(nil) == "Caméra · débranchée")
        #expect(Labels.iPhoneSection(count: 0) == "iPhone connectés · 0")
        #expect(Labels.noIPhone == "Aucun iPhone connecté")
        #expect(Labels.aiNote(.unknown, needsSDK: true) == "SDK OBSBOT requis")
        #expect(Labels.aiNote(.unknown, needsSDK: false) == "État inconnu")
        #expect(Labels.aiNote(.on, needsSDK: false) == nil)
        #expect(Labels.aiNote(nil, needsSDK: false) == nil)
    }

    @Test("Textes exacts de la spec : alerte de migration, confirmation du SDK")
    func specTexts() {
        #expect(Labels.migrationMessage == "Une ancienne installation de ptzd tourne en arrière-plan. PTZBot va la remplacer : le service sera désormais actif seulement quand PTZBot est ouvert. Vos iPhone appairés sont conservés.")
        #expect(Labels.sdkConfirmation == "PTZBot va copier ce fichier dans sa bibliothèque et retirer la quarantaine de cette copie. Ne le faites que si vous l'avez téléchargé depuis obsbot.com.")
        #expect(Labels.localNetworkDenied == "PTZBot n'a pas accès au réseau local : les iPhone ne le trouveront qu'avec Tailscale")
        #expect(Labels.tailscaleMissing == "Tailscale introuvable : accès depuis l'extérieur indisponible")
    }

    @Test("Vérifications du SDK : architecture, signature, provenance, quarantaine")
    func checks() {
        let signed = SDKCandidate(
            path: URL(fileURLWithPath: "/x/libdev.dylib"),
            architectures: ["arm64"],
            signer: "Developer ID Application: Exemple (ABCDE12345)",
            team: "ABCDE12345",
            quarantined: true,
            origin: SDKOrigin(url: "https://example.com/libdev.zip", date: nil)
        )
        #expect(Labels.sdkChecks(signed).map(\.value) == [
            "Apple Silicon : ✓",
            "Developer ID Application: Exemple (ABCDE12345)",
            "https://example.com/libdev.zip",
            "oui",
        ])
        var others = signed
        others.otherCopies = ["macos/macos/arm64-release/libdev.dylib", "macos/x86_64-release/libdev.dylib"]
        #expect(Labels.sdkChecks(others).last == Labels.SDKCheck(
            title: "Autres copies ignorées",
            value: "macos/macos/arm64-release/libdev.dylib, macos/x86_64-release/libdev.dylib"
        ))
        let bare = SDKCandidate(path: URL(fileURLWithPath: "/x/libdev.dylib"), architectures: ["x86_64"])
        #expect(Labels.sdkChecks(bare).map(\.value) == ["Apple Silicon : ✗ (x86_64)", "non signé", "inconnue", "non"])
        #expect(Labels.sdkChecks(bare).map(\.title) == ["Architecture", "Signature", "Provenance", "Quarantaine"])
        let dated = SDKCandidate(path: bare.path, architectures: ["arm64"], origin: SDKOrigin(url: nil, date: Date(timeIntervalSince1970: 0x6A00_0000)))
        #expect(Labels.sdkChecks(dated)[2].value.hasPrefix("le "))
    }

    @Test("Emplacements : utilitaires dans Contents/Helpers, SDK et journal de l'utilisateur")
    func paths() {
        let paths = AppPaths(bundle: URL(fileURLWithPath: "/Applications/PTZBot.app"), home: URL(fileURLWithPath: "/maison/exemple"))
        #expect(paths.ptzd.path == "/Applications/PTZBot.app/Contents/Helpers/ptzd")
        #expect(paths.obsbotAI.path == "/Applications/PTZBot.app/Contents/Helpers/obsbot-ai")
        #expect(paths.sdkDirectory.path == "/maison/exemple/Library/Application Support/ObsbotNacelle/sdk")
        #expect(paths.config.path == "/maison/exemple/Library/Application Support/ObsbotNacelle/config.json")
        #expect(paths.ptzdLog.path == "/maison/exemple/Library/Logs/obsbot-nacelle/ptzd.log")
    }

    @Test("Réseau local : refus reconnu à l'erreur PolicyDenied")
    func localNetwork() {
        #expect(LocalNetworkProbe.isDenied(.waiting(.dns(-65570))) == true)
        #expect(LocalNetworkProbe.isDenied(.failed(.dns(-65570))) == true)
        #expect(LocalNetworkProbe.isDenied(.failed(.dns(-65537))) == false)
        #expect(LocalNetworkProbe.isDenied(.ready) == false)
        #expect(LocalNetworkProbe.isDenied(.setup) == nil)
        #expect(LocalNetworkProbe.isDenied(.waiting(.posix(.ENETDOWN))) == nil)
    }
}
```

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift
index fb871d2..783fe26 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift
@@ -123,6 +123,8 @@ final class FakeProcess: LaunchedProcess {
     private(set) var kills = 0
     /// SIGTERM ignoré (ptzd bloqué) : seul SIGKILL l'arrête.
     var ignoresTerminate = false
+    /// Fin jamais signalée, même après SIGKILL (processus bloqué dans le noyau).
+    var ignoresKill = false
 
     init(pid: pid_t, arguments: [String], outputURL: URL, onExit: @escaping @MainActor (ProcessExit) -> Void) {
         self.pid = pid
@@ -140,6 +142,7 @@ final class FakeProcess: LaunchedProcess {
 
     func kill() {
         kills += 1
+        guard !ignoresKill else { return }
         exit(ProcessExit(status: SIGKILL, signaled: true))
     }
 
PATCH
```

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift
index f608fd4..9a438ef 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift
@@ -43,6 +43,31 @@ struct PanelModelTests {
         #expect(model.admin?.devices == [device])
     }
 
+    @Test("iPhone connectés : la connexion de confiance du Mac n'est pas un client")
+    func iPhoneClients() throws {
+        try connect()
+        #expect(model.iPhoneClients.isEmpty)
+        let since = Date(timeIntervalSince1970: 1_791_301_000)
+        let mac = AdminClient(id: 1, deviceID: nil, name: nil, route: .mac, address: "127.0.0.1", since: since)
+        let phone = AdminClient(id: 2, deviceID: device.deviceID, name: "iPhone", route: .localNetwork, address: "192.0.2.89", since: since)
+        let remote = AdminClient(id: 3, deviceID: device.deviceID, name: "iPhone", route: .tailscale, address: "100.64.0.1", since: since)
+        try receive(.adminState(AdminState(devices: [device], clients: [mac, phone, remote], pairing: nil)))
+        #expect(model.iPhoneClients.map(\.id) == [2, 3])
+        #expect(Labels.iPhoneSection(count: model.iPhoneClients.count) == "iPhone connectés · 2")
+        transport.emit(.closed)
+        #expect(model.iPhoneClients.isEmpty)
+    }
+
+    @Test("config.json relu : la reconnexion suivante prend le nouveau port")
+    func reloadConfig() throws {
+        try connect()
+        model.reloadConfig(PTZDConfig(port: 19870, isFallback: false))
+        #expect(!model.config.isFallback)
+        transport.emit(.closed)
+        scheduler.advance(by: PanelModel.retryDelay)
+        #expect(transport.opened.last == URL(string: "ws://127.0.0.1:19870")!)
+    }
+
     @Test("ptzd ne répond pas : état effacé, nouvel essai toutes les 2 s")
     func reconnects() throws {
         try connect()
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' | grep -v appintents && ./check-bundle.sh)
```

Attendu : échec — la compilation des tests échoue : `AppController`, `AppPaths` et `PanelModel.iPhoneClients` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Remplacer tout le contenu de `mac/app/PTZBot/PTZBotApp.swift` par :

```swift
import PTZBotKit
import SwiftUI

/// PTZBot pour Mac (spec app Mac, spec ptzd dans l'app) : une icône dans la barre des menus, un panneau,
/// trois fenêtres, et ptzd lancé comme processus enfant.
@main
struct PTZBotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: delegate.panel, loginItem: delegate.loginItem, app: delegate.controller, network: delegate.network)
        } label: {
            Image(nsImage: MenuBarIcon.image())
                .opacity(delegate.panel.service == .active ? 1 : 0.4)
                .onAppear { delegate.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Appairer un iPhone", id: WindowID.pairing) {
            PairingView(model: delegate.panel)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Appareils appairés", id: WindowID.devices) {
            DevicesView(model: delegate.panel)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("SDK OBSBOT", id: WindowID.sdk) {
            SDKView(model: delegate.sdkWindow)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Les modèles de l'app, créés une fois ; « Quitter » (et toute fin de l'app) attend l'arrêt de ptzd.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let scheduler = MainScheduler()
    let panel: PanelModel
    let loginItem = LoginItemModel(service: MainAppLoginItem())
    let controller: AppController
    let sdkWindow: SDKWindowModel
    let network: LocalNetworkState
    private var started = false

    override init() {
        let paths = AppPaths.system()
        panel = PanelModel(config: .load(from: paths.config), transport: URLSessionAdminTransport(), scheduler: scheduler)
        let installer = SDKInstaller.system(paths: paths)
        controller = AppController(
            supervisor: .system(paths: paths.service, scheduler: scheduler),
            legacyAgent: .system(supportDirectory: paths.support),
            configURL: paths.config,
            interfaces: SystemInterfaceAddresses(),
            sdkInstaller: installer,
            scheduler: scheduler,
            confirmMigration: { MigrationAlert.ask() }
        )
        sdkWindow = SDKWindowModel(installer: installer)
        network = LocalNetworkState(scheduler: scheduler)
        super.init()
        controller.onConfigReady = { [panel] in
            panel.reloadConfig(.load(from: paths.config))
        }
        sdkWindow.onInstalled = { [controller] in
            Task { await controller.refreshSDK() }
        }
    }

    /// À la première apparition de l'icône : connexion à ptzd, ancienne installation, service, SDK, réseau local.
    func start() {
        guard !started else { return }
        started = true
        panel.start()
        network.check()
        Task { await controller.launch() }
    }

    /// Attend l'arrêt de ptzd (5 s au plus), puis répond.
    ///
    /// Ne jamais appeler `NSApp.terminate` depuis un bloc de la file principale (`DispatchQueue.main.async`,
    /// `asyncAfter`, `Task` sur le MainActor) : `.terminateLater` fait tourner la boucle d'exécution à l'intérieur
    /// de ce bloc, et la file principale, qui n'est pas réentrante, ne livre plus rien. Or la fin de ptzd
    /// (`FoundationProcessLauncher`) et le délai de sécurité (`MainScheduler`) passent par elle : l'app
    /// attendrait sans fin. « Quitter » passe donc par la boucle d'exécution (`perform(_:with:afterDelay:inModes:)`),
    /// et la réponse aussi.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.quit {
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }
}

/// L'autorisation « Réseau local » de PTZBot, vérifiée au lancement et à chaque ouverture du panneau.
@MainActor
@Observable
final class LocalNetworkState {
    private(set) var denied = false
    @ObservationIgnored private let probe = LocalNetworkProbe()
    @ObservationIgnored private let scheduler: any Scheduler

    init(scheduler: any Scheduler) {
        self.scheduler = scheduler
    }

    func check() {
        probe.check(scheduler: scheduler) { [weak self] denied in
            self?.denied = denied
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// L'alerte de migration (spec ptzd dans l'app § 5.6).
enum MigrationAlert {
    @MainActor
    static func ask() -> Bool {
        let alert = NSAlert()
        alert.messageText = Labels.migrationMessage
        alert.addButton(withTitle: Labels.migrationReplace)
        alert.addButton(withTitle: Labels.migrationLater)
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum WindowID {
    static let pairing = "pairing"
    static let devices = "devices"
    static let sdk = "sdk"
}

extension OpenWindowAction {
    /// Ouvre la fenêtre au premier plan : l'app n'a pas d'icône dans le Dock pour l'y amener.
    @MainActor
    func front(_ id: String) {
        self(id: id)
        NSApp.activate()
    }
}
```

Remplacer tout le contenu de `mac/app/PTZBot/PanelView.swift` par :

```swift
import NacelleProtocol
import PTZBotKit
import SwiftUI

/// Le panneau sous l'icône (spec app Mac § 8.1, maquette B).
struct PanelView: View {
    let model: PanelModel
    let loginItem: LoginItemModel
    let app: AppController
    let network: LocalNetworkState
    @Environment(\.openWindow) private var openWindow

    private var supervisor: ServiceSupervisor {
        app.supervisor
    }

    private var legacy: Bool {
        app.legacy == .kept
    }

    /// Service actif et connexion de confiance établie (spec ptzd dans l'app § 6.1).
    private var active: Bool {
        Labels.controlsEnabled(supervisor.state, connection: model.service, legacy: legacy)
    }

    /// Un ordre de suivi IA est en cours (`control == .taking`).
    private var aiBusy: Bool {
        model.state?.control == .taking
    }

    private var aiNeedsSDK: Bool {
        Labels.aiNeedsSDK(app.sdkStatus, legacy: legacy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            serviceSection
            cameraSection
            iPhoneSection
            HStack(spacing: 8) {
                Button {
                    model.openPairing()
                    openWindow.front(WindowID.pairing)
                } label: {
                    Text("Appairer un iPhone…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    openWindow.front(WindowID.devices)
                } label: {
                    Text("Appareils…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(!active)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            // Panneau ouvert : l'autorisation « Réseau local » a pu changer dans les Réglages.
            network.check()
        }
    }

    // MARK: - En-tête

    private var header: some View {
        HStack {
            Text("PTZBot").font(.headline)
            Spacer()
            Text(Labels.service(supervisor.state, connection: model.service, legacy: legacy))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(active ? Color.green : Color.secondary)
                .background(active ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15), in: Capsule())
        }
    }

    // MARK: - Service

    private var serviceSection: some View {
        PanelSection(Labels.serviceSection) {
            PanelRow(icon: "server.rack", title: "Service ptzd") {
                Toggle("Service ptzd", isOn: Binding(get: { supervisor.isEnabled }, set: { supervisor.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(app.legacy != .none)
            } notes: {
                if case let .failed(reason) = supervisor.state {
                    PanelNote(reason, color: .red)
                }
                if Labels.showsLog(supervisor.state, connection: model.service) {
                    Button("Ouvrir le journal de ptzd") {
                        LogOpener.openPTZDLog()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if let error = app.migrationError {
                    PanelNote(error, color: .red)
                }
                if app.canReplaceLegacy {
                    Button(Labels.replaceLegacy) {
                        Task { await app.offerMigration() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                ForEach(app.migrationProblems + (app.configError.map { [$0] } ?? []), id: \.self) { problem in
                    PanelNote(problem)
                }
                if model.config.isFallback {
                    PanelNote("config.json illisible : port 1985 essayé.")
                }
            }
            Divider()
            PanelRow(icon: "shippingbox", title: "SDK OBSBOT") {
                HStack(spacing: 6) {
                    Text(Labels.sdk(app.sdkStatus)).foregroundStyle(.secondary)
                    if let action = Labels.sdkAction(app.sdkStatus) {
                        Button(action) {
                            openWindow.front(WindowID.sdk)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    // MARK: - Caméra

    private var cameraSection: some View {
        PanelSection(Labels.cameraSection(model.state?.camera)) {
            PanelRow(icon: "eye.slash", title: "Vie privée") {
                Toggle("Vie privée", isOn: Binding(get: { model.state?.privacy ?? false }, set: { model.setPrivacy($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Divider()
            PanelRow(icon: "person.crop.square", title: "Suivi IA") {
                HStack(spacing: 6) {
                    if aiBusy {
                        // obsbot-ai démarre ou travaille : l'interrupteur attend la fin de l'ordre.
                        ProgressView().controlSize(.small)
                    }
                    Toggle("Suivi IA", isOn: Binding(get: { model.state?.aiTracking == .on }, set: { model.setAITracking($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(model.state?.privacy != false || aiBusy || aiNeedsSDK)
                }
            } notes: {
                if let note = Labels.aiNote(model.state?.aiTracking, needsSDK: aiNeedsSDK) {
                    PanelNote(note)
                }
            }
        } notes: {
            if let error = model.lastError {
                PanelNote(error, color: .red)
            }
        }
        .disabled(!active)
    }

    // MARK: - iPhone

    private var iPhoneSection: some View {
        let clients = model.iPhoneClients
        return PanelSection(Labels.iPhoneSection(count: clients.count)) {
            if clients.isEmpty {
                PanelRow(icon: "iphone", title: Labels.noIPhone, secondaryTitle: true) {
                    EmptyView()
                }
            }
            ForEach(Array(clients.enumerated()), id: \.element.id) { index, client in
                if index > 0 {
                    Divider()
                }
                let label = Labels.client(client)
                PanelRow(icon: "iphone", title: label.title, subtitle: label.detail) {
                    Button("Expulser", role: .destructive) {
                        if let deviceID = client.deviceID {
                            model.kick(deviceID)
                        }
                    }
                    .controlSize(.small)
                    .disabled(!active)
                }
            }
        } notes: {
            if app.tailscaleMissing {
                PanelNote(Labels.tailscaleMissing)
            }
            if network.denied {
                PanelNote(Labels.localNetworkDenied, color: .orange)
                Button("Ouvrir les réglages de confidentialité") {
                    network.openSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    // MARK: - Pied

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Ouvrir à la connexion", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quitter") {
                    // Un appairage ouvert est fermé avant de partir ; l'envoi est asynchrone, d'où le court délai.
                    // La fin de l'app attend ensuite l'arrêt de ptzd, 5 s au plus (AppDelegate).
                    // Par la boucle d'exécution, jamais depuis un bloc de la file principale : voir
                    // AppDelegate.applicationShouldTerminate.
                    model.closePairing()
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.3, inModes: [.common])
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if loginItem.needsApproval {
                Button("Autorisez PTZBot dans Réglages › Général › Ouverture") {
                    loginItem.openSystemSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if let error = loginItem.lastError {
                PanelNote(error, color: .red)
            }
        }
    }
}

/// Une section du panneau : légende discrète, boîte arrondie, puis ses messages.
private struct PanelSection<Content: View, Notes: View>: View {
    let caption: String
    @ViewBuilder let content: Content
    @ViewBuilder let notes: Notes

    init(_ caption: String, @ViewBuilder content: () -> Content, @ViewBuilder notes: () -> Notes = { EmptyView() }) {
        self.caption = caption
        self.content = content()
        self.notes = notes()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                content
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            notes
        }
    }
}

/// Une ligne de boîte : icône, titre (et sous-titre), commande alignée à droite ; ses messages dessous,
/// sans déranger l'alignement.
private struct PanelRow<Trailing: View, Notes: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var secondaryTitle = false
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let notes: Notes

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        secondaryTitle: Bool = false,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder notes: () -> Notes = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.secondaryTitle = secondaryTitle
        self.trailing = trailing()
        self.notes = notes()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(secondaryTitle ? .secondary : .primary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            VStack(alignment: .leading, spacing: 2) {
                notes
            }
            .padding(.leading, 26)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// Un petit message sous une ligne ou une section.
private struct PanelNote: View {
    let text: String
    let color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Ouvre le journal de ptzd dans Console.
enum LogOpener {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/obsbot-nacelle/ptzd.log")

    @MainActor
    static func openPTZDLog() {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([logURL], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }
}
```

Créer `mac/app/PTZBot/SDKView.swift` :

```swift
import PTZBotKit
import SwiftUI
import UniformTypeIdentifiers

/// La fenêtre « SDK OBSBOT » (spec ptzd dans l'app § 6.2) : explication, choix, vérifications, autorisation.
struct SDKView: View {
    let model: SDKWindowModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Labels.sdkExplanation)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Ouvrir obsbot.com/sdk") {
                    if let url = URL(string: "https://www.obsbot.com/sdk") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Choisir l'archive ou le dossier…", action: choose)
                    .buttonStyle(.borderedProminent)
            }
            .disabled(model.phase == .inspecting || model.phase == .installing)

            switch model.phase {
            case .choosing:
                EmptyView()
            case .inspecting:
                ProgressView("Vérification du fichier…")
            case let .candidate(candidate):
                Text(candidate.path.lastPathComponent).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Labels.sdkChecks(candidate), id: \.title) { check in
                        GridRow {
                            Text(check.title).foregroundStyle(.secondary)
                            Text(check.value).textSelection(.enabled)
                        }
                    }
                }
                Button("Autoriser ce SDK") {
                    confirming = true
                }
                .buttonStyle(.borderedProminent)
            case let .rejected(message), let .failed(message):
                Text(message).foregroundStyle(.red)
            case .installing:
                ProgressView("Installation du SDK…")
            case .installed:
                Text("SDK installé : le suivi IA est disponible.").foregroundStyle(.green)
            }
        }
        .padding(20)
        .frame(width: 460)
        .alert("Autoriser ce SDK ?", isPresented: $confirming) {
            Button("Autoriser") {
                Task { await model.authorize() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(Labels.sdkConfirmation)
        }
        .onDisappear {
            model.reset()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "dylib") ?? .data]
        panel.message = "Choisissez l'archive du SDK OBSBOT (.zip), son dossier décompressé ou libdev.dylib."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.choose(url) }
    }
}
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift` :

```swift
import Foundation
import Observation

/// Le lancement et l'arrêt de l'app autour de ptzd (spec ptzd dans l'app § 5.3, § 5.5 et § 5.6) :
/// ancienne installation détectée et remplacée après confirmation, `config.json` créé au besoin,
/// supervision de ptzd, état du SDK, « Quitter » qui attend ptzd.
@MainActor
@Observable
public final class AppController {
    public enum Legacy: Equatable, Sendable {
        /// Détection en cours.
        case checking
        /// Aucune ancienne installation, ou remplacée.
        case none
        /// Gardée (« Plus tard » ou échec de la migration) : l'app se branche sur l'ancien ptzd.
        case kept
    }

    /// « Quitter » attend ptzd 5 s au plus (le superviseur envoie SIGKILL à 5 s) ; marge de sécurité.
    public static let quitTimeout: TimeInterval = 6

    public private(set) var legacy: Legacy = .checking
    public private(set) var migrationError: String?
    /// Alerte de migration affichée ou migration en cours.
    public private(set) var migrating = false
    /// Ce que la migration n'a pas pu faire (corbeille, reprise du SDK), sans échouer pour autant.
    public private(set) var migrationProblems: [String] = []
    /// nil pendant la vérification.
    public private(set) var sdkStatus: SDKStatus?
    public private(set) var tailscaleMissing = false
    public private(set) var configError: String?
    public let supervisor: ServiceSupervisor

    @ObservationIgnored private let legacyAgent: LegacyAgent
    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let interfaces: any InterfaceAddressProvider
    @ObservationIgnored public let sdkInstaller: SDKInstaller
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private let confirmMigration: @MainActor () async -> Bool
    @ObservationIgnored private var launched = false
    /// `config.json` est prêt (créé au besoin) : l'app relit le port de ptzd.
    @ObservationIgnored public var onConfigReady: (@MainActor () -> Void)?

    public init(
        supervisor: ServiceSupervisor,
        legacyAgent: LegacyAgent,
        configURL: URL,
        interfaces: any InterfaceAddressProvider,
        sdkInstaller: SDKInstaller,
        scheduler: any Scheduler,
        confirmMigration: @escaping @MainActor () async -> Bool
    ) {
        self.supervisor = supervisor
        self.legacyAgent = legacyAgent
        self.configURL = configURL
        self.interfaces = interfaces
        self.sdkInstaller = sdkInstaller
        self.scheduler = scheduler
        self.confirmMigration = confirmMigration
    }

    /// Au lancement : ancienne installation ? alerte « Remplacer » / « Plus tard » ; sinon, `config.json`
    /// et ptzd. Puis l'état du SDK.
    public func launch() async {
        guard !launched else { return }
        launched = true
        let agent = legacyAgent
        let found = await Task.detached { agent.detect() }.value
        if found {
            legacy = .kept
            supervisor.legacyAgentActive = true
            await offerMigration()
        } else {
            legacy = .none
            await startService()
        }
        await refreshSDK()
    }

    /// L'ancienne installation est gardée (« Plus tard » ou échec) : le panneau propose
    /// « Remplacer l'ancienne installation… ».
    public var canReplaceLegacy: Bool {
        legacy == .kept && !migrating
    }

    /// « Remplacer l'ancienne installation… » : la même alerte qu'au lancement, puis la même migration.
    public func offerMigration() async {
        guard legacy == .kept, !migrating else { return }
        migrating = true
        defer { migrating = false }
        if await confirmMigration() {
            await replaceLegacy()
            if legacy == .none, launched {
                // Le SDK de lib/ a pu être repris dans sdk/.
                await refreshSDK()
            }
        }
    }

    /// « Remplacer » : en cas d'échec, message, et l'app reste sur l'ancien ptzd (jamais deux à la fois).
    public func replaceLegacy() async {
        let agent = legacyAgent
        let result = await Task.detached { Result { () throws(LegacyMigrationError) in try agent.migrate() } }.value
        switch result {
        case let .success(report):
            migrationError = nil
            migrationProblems = report.problems
            legacy = .none
            supervisor.legacyAgentActive = false
            await startService()
        case let .failure(error):
            migrationError = error.message
        }
    }

    public func refreshSDK() async {
        let installer = sdkInstaller
        sdkStatus = await Task.detached { installer.status() }.value
    }

    /// Arrête ptzd (SIGTERM, puis SIGKILL à 5 s), puis `completion`, une seule fois, au plus tard après `quitTimeout`.
    public func quit(completion: @escaping @MainActor () -> Void) {
        let once = Once(completion)
        supervisor.stop(forQuit: true) { once.run() }
        scheduler.schedule(after: Self.quitTimeout) { once.run() }
    }

    private func startService() async {
        let url = configURL
        let interfaces = interfaces
        let result: Result<ConfigBootstrap.Outcome, BootstrapFailure> = await Task.detached {
            do {
                return .success(try ConfigBootstrap.run(configURL: url, addresses: interfaces))
            } catch {
                return .failure(BootstrapFailure(reason: error.localizedDescription))
            }
        }.value
        switch result {
        case let .success(outcome):
            configError = nil
            tailscaleMissing = outcome == .tailscaleMissing || ConfigBootstrap.listensOnLoopbackOnly(configURL: url)
        case let .failure(failure):
            configError = "config.json n'a pas pu être créé : \(failure.reason)"
        }
        onConfigReady?()
        // Pour le message d'un port déjà pris (sortie 75 de ptzd).
        supervisor.port = PTZDConfig.load(from: url).port
        supervisor.start()
    }
}

private struct BootstrapFailure: Error {
    var reason: String
}

/// Une action exécutée une seule fois.
@MainActor
private final class Once {
    private var action: (@MainActor () -> Void)?

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func run() {
        let action = action
        self.action = nil
        action?()
    }
}
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift` :

```swift
import Foundation

/// Les emplacements de l'app, de ses utilitaires et des fichiers de l'utilisateur (spec ptzd dans l'app § 5.1 et § 5.2).
public struct AppPaths: Equatable, Sendable {
    /// `~/Library/Application Support/ObsbotNacelle`.
    public var support: URL
    /// `~/Library/Logs/obsbot-nacelle`.
    public var logs: URL
    /// `PTZBot.app/Contents/Helpers`.
    public var helpers: URL

    public init(bundle: URL, home: URL) {
        support = home.appending(path: "Library/Application Support/ObsbotNacelle")
        logs = home.appending(path: "Library/Logs/obsbot-nacelle")
        helpers = bundle.appending(path: "Contents/Helpers")
    }

    /// Les emplacements réels : l'app en cours et le dossier de l'utilisateur. Pour l'app seulement ; les tests
    /// passent des dossiers temporaires.
    public static func system() -> AppPaths {
        AppPaths(bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public var config: URL {
        support.appending(path: "config.json")
    }

    public var sdkDirectory: URL {
        support.appending(path: "sdk")
    }

    public var ptzdLog: URL {
        logs.appending(path: "ptzd.log")
    }

    public var ptzd: URL {
        helpers.appending(path: "ptzd")
    }

    public var obsbotAI: URL {
        helpers.appending(path: "obsbot-ai")
    }

    /// Ce que le superviseur donne à ptzd.
    public var service: ServiceSupervisor.Paths {
        ServiceSupervisor.Paths(ptzd: ptzd, ai: obsbotAI, sdkDirectory: sdkDirectory, log: ptzdLog)
    }
}

extension SDKInstaller {
    /// L'installateur de l'app : `sdk/` de l'utilisateur, vérifié par l'obsbot-ai du paquet.
    public static func system(paths: AppPaths) -> SDKInstaller {
        SDKInstaller(sdkDirectory: paths.sdkDirectory, verifier: obsbotAIVerifier(executableURL: paths.obsbotAI))
    }
}
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/ConfigBootstrap.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/ConfigBootstrap.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/ConfigBootstrap.swift
index 4989643..37f776e 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/ConfigBootstrap.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/ConfigBootstrap.swift
@@ -64,6 +64,15 @@ public enum ConfigBootstrap {
         return (candidates.first { $0.interface.hasPrefix("utun") } ?? candidates.first)?.address
     }
 
+    /// `config.json` écoute sur 127.0.0.1 seulement : le panneau signale l'absence de Tailscale.
+    public static func listensOnLoopbackOnly(configURL: URL) -> Bool {
+        guard let data = try? Data(contentsOf: configURL),
+              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
+            return false
+        }
+        return object["listenAddress"] as? String == loopback
+    }
+
     public static func run(configURL: URL, addresses: any InterfaceAddressProvider) throws -> Outcome {
         let manager = FileManager.default
         guard !manager.fileExists(atPath: configURL.path) else { return .existing }
PATCH
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/LocalNetworkProbe.swift` :

```swift
import Foundation
import Network

/// Vérifie, côté app, que macOS autorise PTZBot (et donc ptzd, son enfant) sur le réseau local
/// (spec ptzd dans l'app § 4.2 et § 6.1) : un `NWBrowser` de courte durée sur `_nacelle._tcp`
/// signale un refus par l'erreur DNS « PolicyDenied ».
@MainActor
public final class LocalNetworkProbe {
    public nonisolated static let serviceType = "_nacelle._tcp"
    /// kDNSServiceErr_PolicyDenied.
    nonisolated static let policyDenied: Int32 = -65570
    public static let duration: TimeInterval = 2

    private var run: ProbeRun?

    public init() {}

    /// Refus si l'état du navigateur porte l'erreur « PolicyDenied » ; nil si l'état ne dit rien.
    public nonisolated static func isDenied(_ state: NWBrowser.State) -> Bool? {
        switch state {
        case let .failed(error), let .waiting(error):
            if case let .dns(code) = error {
                return code == policyDenied
            }
            return nil
        case .ready:
            return false
        case .setup, .cancelled:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Ouvre un navigateur pendant `duration` secondes ; `completion(true)` dès qu'un refus est vu,
    /// sinon `completion(false)` à la fin. Un appel en cours est remplacé (sans réponse).
    public func check(scheduler: any Scheduler, completion: @escaping @MainActor (Bool) -> Void) {
        run?.finish(nil)
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: .tcp)
        let run = ProbeRun(browser: browser, completion: completion)
        self.run = run
        browser.stateUpdateHandler = { [weak run] state in
            guard Self.isDenied(state) == true else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { run?.finish(true) }
            }
        }
        browser.start(queue: .main)
        scheduler.schedule(after: Self.duration) { [weak run] in
            run?.finish(false)
        }
    }
}

/// Une vérification : une seule réponse, puis le navigateur est fermé.
@MainActor
private final class ProbeRun {
    private var browser: NWBrowser?
    private var completion: (@MainActor (Bool) -> Void)?

    init(browser: NWBrowser, completion: @escaping @MainActor (Bool) -> Void) {
        self.browser = browser
        self.completion = completion
    }

    /// `nil` : remplacée, sans réponse.
    func finish(_ denied: Bool?) {
        browser?.cancel()
        browser = nil
        let completion = completion
        self.completion = nil
        if let denied {
            completion?(denied)
        }
    }
}
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift
index f75a20c..6644eea 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift
@@ -26,7 +26,8 @@ public final class PanelModel {
     public private(set) var lastError: String?
     /// La fenêtre « Appairer un iPhone » ouverte, s'il y en a une.
     public private(set) var pairing: PairingSession?
-    public let config: PTZDConfig
+    /// Relu quand l'app crée `config.json` au premier lancement (`reloadConfig`).
+    public private(set) var config: PTZDConfig
 
     @ObservationIgnored private let transport: any AdminTransport
     @ObservationIgnored private let scheduler: any Scheduler
@@ -48,6 +49,17 @@ public final class PanelModel {
         transport.open(config.url)
     }
 
+    /// Les iPhone connectés : les clients non fiables. La connexion de confiance de l'app elle-même
+    /// (127.0.0.1, `route == .mac`) est le côté serveur, pas un client à montrer.
+    public var iPhoneClients: [AdminClient] {
+        (admin?.clients ?? []).filter { $0.route != .mac }
+    }
+
+    /// `config.json` relu (créé au premier lancement) : la prochaine connexion prend son port.
+    public func reloadConfig(_ config: PTZDConfig) {
+        self.config = config
+    }
+
     // MARK: - Actions
 
     public func setPrivacy(_ on: Bool) {
PATCH
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/SDKWindowModel.swift` :

```swift
import Foundation
import Observation

/// La fenêtre « SDK OBSBOT » (spec ptzd dans l'app § 6.2) : choix, vérifications, autorisation.
@MainActor
@Observable
public final class SDKWindowModel {
    public enum Phase: Equatable, Sendable {
        case choosing
        case inspecting
        case candidate(SDKCandidate)
        case rejected(String)
        case installing
        case installed
        case failed(String)
    }

    public private(set) var phase: Phase = .choosing
    @ObservationIgnored private let installer: SDKInstaller
    @ObservationIgnored private let inspect: @Sendable (URL) throws(SDKRejection) -> SDKCandidate
    /// Change à chaque choix et à chaque fermeture : un examen dépassé est jeté avec son dossier d'extraction.
    @ObservationIgnored private var generation = 0
    /// Appelé après une installation réussie (l'app relit l'état du SDK).
    @ObservationIgnored public var onInstalled: (@MainActor () -> Void)?

    public init(
        installer: SDKInstaller,
        inspect: @escaping @Sendable (URL) throws(SDKRejection) -> SDKCandidate = { url throws(SDKRejection) in try SDKInspector.inspect(url) }
    ) {
        self.installer = installer
        self.inspect = inspect
    }

    /// Examine le fichier ou le dossier choisi, hors du fil principal.
    public func choose(_ url: URL) async {
        discardCandidate()
        generation += 1
        let current = generation
        phase = .inspecting
        let inspect = inspect
        let result = await Task.detached { Result { () throws(SDKRejection) in try inspect(url) } }.value
        guard current == generation else {
            // Fenêtre fermée (ou autre choix) pendant l'examen : l'extraction ne sert plus.
            if case let .success(candidate) = result {
                SDKInspector.discard(candidate)
            }
            return
        }
        switch result {
        case let .success(candidate):
            phase = .candidate(candidate)
        case let .failure(rejection):
            phase = .rejected(rejection.message)
        }
    }

    /// « Autoriser ce SDK », après la confirmation : copie, quarantaine retirée de la copie, vérification.
    public func authorize() async {
        guard case let .candidate(candidate) = phase else { return }
        phase = .installing
        let installer = installer
        let result = await Task.detached { Result { () throws(SDKInstallError) in try installer.install(candidate) } }.value
        SDKInspector.discard(candidate)
        switch result {
        case .success:
            phase = .installed
            onInstalled?()
        case let .failure(error):
            phase = .failed(error.message)
        }
    }

    /// Fenêtre fermée ou nouveau choix : le dossier d'extraction est effacé.
    public func reset() {
        generation += 1
        discardCandidate()
        phase = .choosing
    }

    private func discardCandidate() {
        if case let .candidate(candidate) = phase {
            SDKInspector.discard(candidate)
        }
    }
}
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift` :

```swift
import Foundation
import NacelleProtocol

/// Les textes du service, du SDK et de la migration (spec ptzd dans l'app § 5.6, § 6.1 et § 6.2), au vouvoiement.
extension Labels {
    /// L'état sous le titre : la supervision de ptzd, puis la connexion de confiance pour « Actif ».
    public static func service(_ state: ServiceSupervisor.State, connection: PanelModel.Service, legacy: Bool) -> String {
        if legacy {
            return "Ancienne installation"
        }
        switch state {
        case .stopped, .failed:
            return "Arrêté"
        case .starting:
            return "Démarrage…"
        case let .restarting(count):
            return "Relancé après un arrêt inattendu (\(count))"
        case .running:
            return service(connection)
        }
    }

    /// Service éteint ou en échec : tout est grisé sauf l'interrupteur, le SDK, « Ouvrir à la connexion »
    /// et « Quitter ». Ancienne installation : seule la connexion décide.
    public static func controlsEnabled(_ state: ServiceSupervisor.State, connection: PanelModel.Service, legacy: Bool) -> Bool {
        guard connection == .active else { return false }
        if legacy {
            return true
        }
        switch state {
        case .running: return true
        case .stopped, .starting, .restarting, .failed: return false
        }
    }

    /// Le journal est proposé quand ptzd ne répond pas ou s'arrête sans cesse.
    public static func showsLog(_ state: ServiceSupervisor.State, connection: PanelModel.Service) -> Bool {
        if case .failed = state {
            return true
        }
        return state == .running && connection == .unreachable
    }

    public static func sdk(_ status: SDKStatus?) -> String {
        switch status {
        case .ready: "Prêt"
        case .absent: "Absent"
        case .quarantined: "En quarantaine"
        case .incompatible: "Incompatible"
        case .unloadable: "Ne se charge pas"
        case nil: "Vérification…"
        }
    }

    /// Le bouton de la ligne SDK : « Changer… » quand il est prêt (la fenêtre reste joignable),
    /// « Installer le SDK… » sinon ; aucun pendant la vérification.
    public static func sdkAction(_ status: SDKStatus?) -> String? {
        switch status {
        case nil: nil
        case .ready: "Changer…"
        case .absent, .quarantined, .incompatible, .unloadable: "Installer le SDK…"
        }
    }

    public static let replaceLegacy = "Remplacer l'ancienne installation…"

    // MARK: - Sections du panneau

    public static let serviceSection = "Service"
    public static let noIPhone = "Aucun iPhone connecté"

    /// « Caméra · branchée » ou « Caméra · débranchée » (débranchée aussi hors connexion).
    public static func cameraSection(_ presence: CameraPresence?) -> String {
        "Caméra · \(presence == .connected ? "branchée" : "débranchée")"
    }

    /// « iPhone connectés · n ».
    public static func iPhoneSection(count: Int) -> String {
        "iPhone connectés · \(count)"
    }

    /// La petite ligne sous « Suivi IA » : le SDK manque, ou l'état ne se lit pas.
    public static func aiNote(_ tracking: AITracking?, needsSDK: Bool) -> String? {
        if needsSDK {
            return sdkRequired
        }
        return tracking == .unknown ? "État inconnu" : nil
    }

    /// Le suivi IA a besoin du SDK de l'app ; l'ancienne installation a le sien dans `lib/`.
    public static func aiNeedsSDK(_ status: SDKStatus?, legacy: Bool) -> Bool {
        !legacy && status != .ready
    }

    public static let sdkRequired = "SDK OBSBOT requis"
    public static let tailscaleMissing = "Tailscale introuvable : accès depuis l'extérieur indisponible"
    public static let localNetworkDenied = "PTZBot n'a pas accès au réseau local : les iPhone ne le trouveront qu'avec Tailscale"

    public static let migrationMessage = "Une ancienne installation de ptzd tourne en arrière-plan. PTZBot va la remplacer : le service sera désormais actif seulement quand PTZBot est ouvert. Vos iPhone appairés sont conservés."
    public static let migrationReplace = "Remplacer"
    public static let migrationLater = "Plus tard"

    public static let sdkExplanation = "Le SDK OBSBOT est propriétaire : il ne peut pas être fourni avec PTZBot. Téléchargez-le sur obsbot.com, puis choisissez l'archive reçue (.zip) ou son dossier décompressé."
    public static let sdkConfirmation = "PTZBot va copier ce fichier dans sa bibliothèque et retirer la quarantaine de cette copie. Ne le faites que si vous l'avez téléchargé depuis obsbot.com."

    /// Une ligne des vérifications de la fenêtre « SDK OBSBOT ».
    public struct SDKCheck: Equatable, Sendable {
        public var title: String
        public var value: String
    }

    /// Architecture, signature, provenance et quarantaine (§ 6.2).
    public static func sdkChecks(_ candidate: SDKCandidate) -> [SDKCheck] {
        let architecture = candidate.isArm64
            ? "Apple Silicon : ✓"
            : "Apple Silicon : ✗ (\(candidate.architectures.joined(separator: ", ")))"
        var origin = [String]()
        if let url = candidate.origin?.url {
            origin.append(url)
        }
        if let date = candidate.origin?.date {
            origin.append("le \(date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(Locale(identifier: "fr_FR"))))")
        }
        var checks = [
            SDKCheck(title: "Architecture", value: architecture),
            SDKCheck(title: "Signature", value: candidate.signer ?? "non signé"),
            SDKCheck(title: "Provenance", value: origin.isEmpty ? "inconnue" : origin.joined(separator: " · ")),
            SDKCheck(title: "Quarantaine", value: candidate.quarantined ? "oui" : "non"),
        ]
        if !candidate.otherCopies.isEmpty {
            checks.append(SDKCheck(title: "Autres copies ignorées", value: candidate.otherCopies.joined(separator: ", ")))
        }
        return checks
    }
}
```

Créer `mac/app/build-helpers.sh` (puis le rendre exécutable : `chmod +x mac/app/build-helpers.sh`) :

```bash
#!/bin/bash
# Phase de construction de PTZBot (project.yml) : compile ptzd et obsbot-ai, les copie dans
# Contents/Helpers, puis refuse le paquet s'il contient un libdev.dylib (spec ptzd dans l'app § 5.1).
# obsbot-ai est lié à @rpath/libdev.dylib sans chemin de recherche intégré : ptzd lui donne
# DYLD_LIBRARY_PATH vers la copie autorisée du SDK.
set -euo pipefail

ROOT="$(cd "$SRCROOT/../.." && pwd)"
SDK="$ROOT/vendor/obsbot-sdk"
HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
WORK="$DERIVED_FILE_DIR/helpers"

if [ ! -f "$SDK/include/dev/devs.hpp" ] || [ ! -f "$SDK/macos/arm64-release/libdev.dylib" ]; then
    echo "error: SDK OBSBOT introuvable dans $SDK : ses en-têtes sont nécessaires pour compiler obsbot-ai." >&2
    exit 1
fi

mkdir -p "$HELPERS" "$WORK"

# swift build hors de l'environnement de Xcode, dont les variables (SDKROOT, ARCHS…) le dérouteraient.
echo "Compilation de ptzd…"
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/ptzd" --product ptzd
BIN="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/ptzd" --show-bin-path)"
install -m 755 "$BIN/ptzd" "$HELPERS/ptzd"

echo "Compilation de obsbot-ai…"
/usr/bin/xcrun clang++ -std=c++17 -O2 -Wall -arch arm64 -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -I"$SDK/include" \
    -L"$SDK/macos/arm64-release" -ldev \
    -o "$WORK/obsbot-ai" "$ROOT/mac/ai/main.cpp"
install -m 755 "$WORK/obsbot-ai" "$HELPERS/obsbot-ai"

FOUND="$(find "$TARGET_BUILD_DIR/$WRAPPER_NAME" -name 'libdev*.dylib' -print)"
if [ -n "$FOUND" ]; then
    echo "error: le SDK OBSBOT ne doit jamais être dans le paquet : $FOUND" >&2
    exit 1
fi
```

Créer `mac/app/check-bundle.sh` (puis le rendre exécutable : `chmod +x mac/app/check-bundle.sh`) :

```bash
#!/bin/bash
# Vérifie le paquet Release de PTZBot (spec ptzd dans l'app § 8) : ptzd et obsbot-ai dans
# Contents/Helpers, et aucun libdev.dylib nulle part.
# Usage : mac/app/check-bundle.sh [chemin de PTZBot.app]
set -euo pipefail

APP="${1:-$(cd "$(dirname "$0")" && pwd)/.build/Build/Products/Release/PTZBot.app}"
STATUS=0

if [ ! -d "$APP" ]; then
    echo "Paquet introuvable : $APP" >&2
    exit 1
fi
for HELPER in ptzd obsbot-ai; do
    if [ -x "$APP/Contents/Helpers/$HELPER" ]; then
        echo "ok : Contents/Helpers/$HELPER"
    else
        echo "manquant : Contents/Helpers/$HELPER" >&2
        STATUS=1
    fi
done
FOUND="$(find "$APP" -name 'libdev*.dylib' -print)"
if [ -n "$FOUND" ]; then
    echo "SDK OBSBOT dans le paquet : $FOUND" >&2
    STATUS=1
else
    echo "ok : aucun libdev.dylib dans le paquet"
fi
exit "$STATUS"
```

Modifier `mac/app/project.yml` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/project.yml b/mac/app/project.yml
index 6ab4874..3b7d460 100644
--- a/mac/app/project.yml
+++ b/mac/app/project.yml
@@ -29,6 +29,10 @@ targets:
         CFBundleDisplayName: PTZBot
         # Dans la barre des menus seulement, sans icône dans le Dock.
         LSUIElement: true
+        # ptzd, enfant de l'app, écoute et s'annonce sur le réseau local (spec ptzd dans l'app § 4.2).
+        NSLocalNetworkUsageDescription: PTZBot accepte les connexions des iPhone appairés sur votre réseau local.
+        NSBonjourServices:
+          - _nacelle._tcp
     settings:
       base:
         PRODUCT_BUNDLE_IDENTIFIER: io.github.djoko-cli.ptzbot
@@ -40,6 +44,20 @@ targets:
         # Signature locale (ad hoc) jusqu'au sous-projet B.
         CODE_SIGN_IDENTITY: "-"
         CODE_SIGN_STYLE: Manual
+        # La phase des utilitaires compile mac/ptzd et lit les en-têtes du SDK dans vendor/.
+        ENABLE_USER_SCRIPT_SANDBOXING: NO
+    postBuildScripts:
+      # ptzd et obsbot-ai dans Contents/Helpers ; jamais de libdev.dylib dans le paquet (spec ptzd dans l'app § 5.1).
+      # Toujours exécutée : swift build sait ce qui a changé dans mac/ptzd.
+      - name: Utilitaires ptzd et obsbot-ai
+        script: '"$SRCROOT/build-helpers.sh"'
+        basedOnDependencyAnalysis: false
+        inputFiles:
+          - $(SRCROOT)/build-helpers.sh
+          - $(SRCROOT)/../ai/main.cpp
+        outputFiles:
+          - $(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/ptzd
+          - $(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/obsbot-ai
 schemes:
   PTZBot:
     build:
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' | grep -v appintents && ./check-bundle.sh)
```

Attendu : tout passe (PTZBotKit : 95 tests, « ** BUILD SUCCEEDED ** » pour l'app, puis les trois lignes « ok : » de `check-bundle.sh`), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add mac/app/PTZBot/PTZBotApp.swift \
    mac/app/PTZBot/PanelView.swift \
    mac/app/PTZBot/SDKView.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/ConfigBootstrap.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/LocalNetworkProbe.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/SDKWindowModel.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift \
    mac/app/build-helpers.sh \
    mac/app/check-bundle.sh \
    mac/app/project.yml
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|8\.8\.8\.8|256\.0\.0\.1|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
B1 : l'app avec ptzd et obsbot-ai, panneau, fenetre du SDK, reseau local

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés plus haut sont déjà indexés par `git rm`.

### Tâche 6 : `install-mac.sh` et README : `ptzd` dans l'app

**But :** `scripts/install-mac.sh` compile l'app avec ses utilitaires. Il ferme l'ancienne app, attend sa fin, la remplace dans `~/Applications` et la lance. Il ne touche plus à launchd ni aux anciens dossiers, et le modèle de plist est retiré. Le README décrit la nouvelle architecture, l'installation du SDK par l'app et la désinstallation (spec B1 § 5.7).

**Fichiers :**
- Modifier : `README.md`
- Supprimer : `mac/launchd/io.github.djoko-cli.obsbot-nacelle.ptzd.plist`
- Modifier : `scripts/install-mac.sh`

**Interfaces :**
- Consomme : la tâche 5.
- Le script exige les en-têtes du SDK (`vendor/`) et `xcodegen`. Il ne lance plus `launchctl`, et la migration est faite par l'app.

- [ ] **Étape 1 : Écrire les fichiers**

Modifier `README.md` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

````bash
git apply <<'PATCH'
diff --git a/README.md b/README.md
index 4909ad8..03af43e 100644
--- a/README.md
+++ b/README.md
@@ -8,17 +8,17 @@ La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](h
 
 ## Statut
 
-- **Côté Mac** : `ptzd`, `obsbot-ai` et l'app **PTZBot pour Mac** s'installent avec `scripts/install-mac.sh` (voir plus bas).
+- **Côté Mac** : l'app **PTZBot pour Mac**, qui contient `ptzd` et `obsbot-ai`, s'installe avec `scripts/install-mac.sh` (voir plus bas). Le SDK OBSBOT s'installe ensuite depuis l'app.
 - **App iOS** (PTZBot) : s'installe depuis Xcode sur l'iPhone (voir « App iOS » plus bas).
 
-Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [spec de l'accès local](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [spec de la découverte et du QR code](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [spec de l'app Mac](docs/superpowers/specs/2026-10-06-app-mac-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [plan de l'accès local](docs/superpowers/plans/2026-10-06-acces-local.md) · [plan de la découverte et du QR code](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [plan de l'app Mac](docs/superpowers/plans/2026-10-06-app-mac.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).
+Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [spec de l'accès local](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [spec de la découverte et du QR code](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [spec de l'app Mac](docs/superpowers/specs/2026-10-06-app-mac-design.md) · [spec de ptzd dans l'app](docs/superpowers/specs/2026-10-07-ptzd-dans-app-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [plan de l'accès local](docs/superpowers/plans/2026-10-06-acces-local.md) · [plan de la découverte et du QR code](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [plan de l'app Mac](docs/superpowers/plans/2026-10-06-app-mac.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).
 
 ## Architecture
 
 ```
 iPhone : app SwiftUI                         Mac (celui de go2rtc)
 ┌───────────────────────────┐            ┌──────────────────────────────────┐
-│ Joystick, zoom,           │            │ ptzd                             │
+│ Joystick, zoom,           │            │ PTZBot.app ▸ ptzd (enfant)       │
 │ vie privée, offre vidéo ──┼─ WebSocket▶│   ├─ commandes UVC ──▶ Tiny 2    │
 │                           │ authentifié│   ├─ lance obsbot-ai (SDK)       │
 │                           │◀─ état ────│   └─ relaie l'offre ──┐          │
@@ -28,9 +28,9 @@ iPhone : app SwiftUI                         Mac (celui de go2rtc)
    à la maison : Wi-Fi (Bonjour, adresse locale) ; dehors : la même adresse par Tailscale
 ```
 
-- **`ptzd`** : un service macOS en Swift, lancé par launchd. C'est le seul à envoyer des commandes de nacelle à la caméra, en UVC. Il écoute sur l'adresse Tailscale du Mac, sur 127.0.0.1, et sur ses interfaces Wi-Fi et Ethernet, où il s'annonce par Bonjour (`_nacelle._tcp`). Chaque iPhone est appairé une fois, sur le réseau local, en scannant le QR code affiché par l'app Mac (ou `ptzd pair`) ; ensuite, il signe un défi à chaque connexion. Sur le réseau local, tout passe en plus dans un canal TLS : pendant l'appairage, sa clé est le secret du QR code ; ensuite, une clé propre à chaque iPhone, remise à l'appairage. Seules les connexions venues de 127.0.0.1 sont dispensées du défi.
-- **`obsbot-ai`** : un petit utilitaire qui allume ou coupe le suivi IA de la caméra avec le SDK OBSBOT, puis se termine. `ptzd` le lance au premier mouvement du joystick (le suivi contrerait les mouvements), à l'entrée en vie privée et sur ordre des apps.
-- **PTZBot pour Mac** : une app dans la barre des menus, qui parle à `ptzd` par 127.0.0.1 : appairage par QR code, appareils et clients connectés, expulsion, vie privée et suivi IA (voir « App Mac » plus bas).
+- **`ptzd`** : un service en Swift, rangé dans l'app (`PTZBot.app/Contents/Helpers/ptzd`) et lancé par elle : il ne tourne que pendant que PTZBot est ouvert, et s'arrête de lui-même si l'app disparaît, même tuée de force. PTZBot le relance s'il s'arrête de façon inattendue. C'est le seul à envoyer des commandes de nacelle à la caméra, en UVC. Il écoute sur l'adresse Tailscale du Mac, sur 127.0.0.1, et sur ses interfaces Wi-Fi et Ethernet, où il s'annonce par Bonjour (`_nacelle._tcp`). Chaque iPhone est appairé une fois, sur le réseau local, en scannant le QR code affiché par l'app Mac (ou `ptzd pair`) ; ensuite, il signe un défi à chaque connexion. Sur le réseau local, tout passe en plus dans un canal TLS : pendant l'appairage, sa clé est le secret du QR code ; ensuite, une clé propre à chaque iPhone, remise à l'appairage. Seules les connexions venues de 127.0.0.1 sont dispensées du défi.
+- **`obsbot-ai`** : un petit utilitaire, rangé lui aussi dans l'app, qui allume ou coupe le suivi IA de la caméra avec le SDK OBSBOT, puis se termine. `ptzd` le lance au premier mouvement du joystick (le suivi contrerait les mouvements), à l'entrée en vie privée et sur ordre des apps. Le SDK n'est jamais dans l'app : `ptzd` donne à `obsbot-ai` la copie autorisée par l'utilisateur, `~/Library/Application Support/ObsbotNacelle/sdk/libdev.dylib`.
+- **PTZBot pour Mac** : une app dans la barre des menus, qui lance `ptzd` et lui parle par 127.0.0.1 : appairage par QR code, appareils et clients connectés, expulsion, vie privée et suivi IA (voir « App Mac » plus bas).
 - **go2rtc** : `ptzd` lui relaie l'offre WebRTC de l'app ; les images vont ensuite directement de go2rtc à l'iPhone. Voir « go2rtc » plus bas pour le fermer au réseau local.
 
 ## Installer le côté Mac
@@ -38,25 +38,24 @@ iPhone : app SwiftUI                         Mac (celui de go2rtc)
 Prérequis :
 
 - un Mac Apple Silicon sous macOS 15 ou plus récent, avec Xcode et [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) ;
-- Tailscale actif sur le Mac ;
-- le SDK OBSBOT, à demander sur [obsbot.com/sdk](https://www.obsbot.com/sdk), décompressé dans `vendor/obsbot-sdk/`. Il n'est pas versionné : sa licence n'en autorise pas la redistribution ;
+- Tailscale sur le Mac pour piloter hors de la maison (sans lui, `ptzd` n'écoute que sur 127.0.0.1 et sur le réseau local) ;
+- le SDK OBSBOT, à demander sur [obsbot.com/sdk](https://www.obsbot.com/sdk), décompressé dans `vendor/obsbot-sdk/` : ses en-têtes servent à compiler `obsbot-ai`. Il n'est pas versionné : sa licence n'en autorise pas la redistribution ;
 - OBSBOT Center fermé : ouvert, il fausse la relecture du tilt.
 
-Si macOS a mis la bibliothèque du SDK en quarantaine, l'autoriser d'abord, depuis la racine du dépôt :
-
-```bash
-xattr -d com.apple.quarantine vendor/obsbot-sdk/macos/arm64-release/libdev.dylib
-```
-
 Puis installer :
 
 ```bash
 scripts/install-mac.sh
 ```
 
-Le script compile `ptzd` et `obsbot-ai`, les installe dans `~/Library/Application Support/ObsbotNacelle/`, crée `config.json` avec l'adresse Tailscale du Mac, puis charge l'agent launchd `io.github.djoko-cli.obsbot-nacelle.ptzd`. Il compile aussi l'app PTZBot pour Mac, l'installe dans `~/Applications/PTZBot.app` et la lance.
+Le script compile l'app, avec `ptzd` et `obsbot-ai` dans `Contents/Helpers`, ferme l'app en cours, l'installe dans `~/Applications/PTZBot.app` et la lance. Il ne touche ni à launchd ni aux fichiers de `~/Library/Application Support/ObsbotNacelle/`.
+
+Au premier lancement :
 
-À la première connexion de l'iPhone, macOS peut demander s'il faut autoriser `ptzd` à accepter des connexions entrantes : répondre **Autoriser**. La question peut revenir après une réinstallation, car le binaire change.
+- **Ancienne installation.** Si l'agent launchd `io.github.djoko-cli.obsbot-nacelle.ptzd` d'une version précédente est là, PTZBot propose de le remplacer. **Remplacer** l'arrête, renomme sa plist en `.plist.bak`, met les anciens binaires de `bin/` à la corbeille et reprend le SDK de `lib/`. Les iPhone appairés et les réglages sont conservés. **Plus tard** garde l'ancien `ptzd` (le panneau affiche « Ancienne installation ») ; la question revient au lancement suivant.
+- **`config.json`.** S'il manque, PTZBot le crée avec l'adresse Tailscale du Mac, ou sur 127.0.0.1 seulement sans Tailscale (le panneau le signale).
+- **SDK OBSBOT.** Dans le panneau, **SDK OBSBOT** › **Installer le SDK…** : choisir l'archive `.zip` reçue d'OBSBOT, son dossier décompressé ou `libdev.dylib`. PTZBot prend `macos/arm64-release/libdev.dylib`, le chemin que la compilation utilise ; les autres copies de l'archive sont listées et ignorées. La fenêtre montre l'architecture, la signature, la provenance et la quarantaine ; **Autoriser ce SDK** copie le fichier dans `sdk/`, retire la quarantaine de cette copie seulement, puis vérifie qu'`obsbot-ai` le charge. Sans SDK, tout marche sauf le suivi IA.
+- **Autorisations.** macOS demande l'accès au réseau local pour PTZBot (`ptzd` en dépend) : répondre **Autoriser**. À la première connexion de l'iPhone, il peut aussi demander s'il faut autoriser `ptzd` à accepter des connexions entrantes : répondre **Autoriser**. La question peut revenir après une réinstallation, car le binaire change.
 
 ## Réglages (`config.json`)
 
@@ -66,16 +65,12 @@ Le script compile `ptzd` et `obsbot-ai`, les installe dans `~/Library/Applicatio
 | `port` | Port WebSocket | 1985 |
 | `panMaxSpeed`, `tiltMaxSpeed` | Vitesses UVC maximales (pan 1–80, tilt 1–120) | 40, 60 |
 | `panDirection`, `tiltDirection` | Sens de chaque axe, +1 ou -1 | +1, +1 |
-| `aiPath` | Chemin de `obsbot-ai`, relatif au dossier d'installation (l'ancienne clé `aiOffPath` est lue si elle manque, sauf si elle nomme `obsbot-ai-off`) | `bin/obsbot-ai` |
+| `aiPath` | Chemin de `obsbot-ai` pour un `ptzd` lancé à la main, relatif au dossier de travail ; ignoré quand PTZBot lance `ptzd` (l'ancienne clé `aiOffPath` est lue si elle manque, sauf si elle nomme `obsbot-ai-off`) | `bin/obsbot-ai` |
 | `localNetwork` | Écoute et annonce Bonjour sur le Wi-Fi et l'Ethernet | `true` |
 | `go2rtcAPI` | API locale de go2rtc, pour relayer la vidéo | `http://127.0.0.1:1984` |
 | `streamName` | Flux go2rtc relayé | `obsbot` |
 
-Après une modification, relancer le service :
-
-```bash
-launchctl kickstart -k gui/$(id -u)/io.github.djoko-cli.obsbot-nacelle.ptzd
-```
+Après une modification, relancer le service : dans le panneau, éteindre puis rallumer **Service ptzd**.
 
 ## Diagnostic
 
@@ -83,23 +78,29 @@ launchctl kickstart -k gui/$(id -u)/io.github.djoko-cli.obsbot-nacelle.ptzd
 |---|---|
 | Journal du service | `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log` |
 | Sortie du SDK | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai.log` |
-| Lire la position de la caméra | `~/Library/Application\ Support/ObsbotNacelle/bin/ptzd uvc get` |
-| Appareils appairés | `~/Library/Application\ Support/ObsbotNacelle/bin/ptzd devices` |
+| Lire la position de la caméra | `~/Applications/PTZBot.app/Contents/Helpers/ptzd uvc get` |
+| Appareils appairés | `~/Applications/PTZBot.app/Contents/Helpers/ptzd devices` |
 | Voir l'annonce Bonjour | `dns-sd -B _nacelle._tcp` (Ctrl-C pour arrêter) |
 | Dialoguer avec le service | `swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"adminWatch"}' wait 2` |
 
 Le Mac ne peut pas se joindre lui-même par son adresse Tailscale : en local, passer par 127.0.0.1.
 
+`ptzd pair`, `ptzd devices` et `ptzd revoke` restent utilisables en ligne de commande avec le binaire de l'app ; `ptzd pair` demande que le service tourne, donc que PTZBot soit ouvert.
+
 ## App Mac (PTZBot)
 
-Installée par `scripts/install-mac.sh`, elle vit dans la barre des menus (icône de la Tiny 2), sans icône dans le Dock. Son panneau montre :
+Installée par `scripts/install-mac.sh`, elle vit dans la barre des menus (icône de la Tiny 2), sans icône dans le Dock. L'iPhone ne pilote la caméra que pendant que PTZBot est ouvert : **Ouvrir à la connexion** en fait l'usage normal. Son panneau montre :
 
-- l'état de `ptzd` (« Actif », « Démarrage… », « Ne répond pas » avec un lien vers son journal) et de la caméra ;
+- l'interrupteur **Service ptzd**, retenu d'un lancement à l'autre, et l'état de `ptzd` (« Actif », « Démarrage… », « Arrêté », « Relancé après un arrêt inattendu (n) », « Ne répond pas » avec un lien vers son journal) et de la caméra. Au-delà de 5 arrêts en 2 min, PTZBot cesse de relancer `ptzd` : « ptzd s'arrête sans cesse : ouvrez le journal ». Il ne le relance pas non plus si un autre `ptzd` tourne déjà (verrou `ptzd.lock` ou port de 127.0.0.1 pris : « Le port 1985 est déjà pris… »), si `config.json` est invalide ou si ses arguments sont refusés ;
+- la ligne **SDK OBSBOT** (« Prêt », « Absent », « En quarantaine », « Incompatible ») et **Installer le SDK…** ; sans SDK prêt, **Suivi IA** est grisé (« SDK OBSBOT requis ») ;
 - les interrupteurs **Vie privée** et **Suivi IA** (le suivi affiche le dernier ordre : l'état réel ne se lit pas, un geste devant la caméra peut le changer) ;
 - les clients connectés, avec **Expulser** : la connexion est coupée et l'appareil refusé 10 min (tant que `ptzd` tourne), sans perdre son appairage ;
 - **Appairer un iPhone…** : le QR code en image, valable 5 min ; fermer la fenêtre l'annule ;
 - **Appareils…** : les appareils appairés, **Débloquer** et **Retirer…** (l'appareil est retiré et ses connexions coupées tout de suite) ;
-- **Ouvrir à la connexion** : l'app se lance à l'ouverture de session (macOS peut demander un accord dans Réglages › Général › Ouverture).
+- **Ouvrir à la connexion** : l'app se lance à l'ouverture de session (macOS peut demander un accord dans Réglages › Général › Ouverture) ;
+- **Quitter** : arrête `ptzd` (5 s au plus), puis l'app.
+
+Si l'accès au réseau local est refusé à PTZBot, le panneau l'indique, avec un bouton vers les réglages de confidentialité : les iPhone ne trouvent alors le Mac que par Tailscale.
 
 L'app passe par la connexion de confiance de `ptzd` (127.0.0.1) : tout programme du Mac peut en faire autant.
 
@@ -138,7 +139,7 @@ Prérequis : Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew ins
 5. Appairer l'iPhone, sur le même réseau que le Mac : dans PTZBot sur le Mac, **Appairer un iPhone…** affiche un QR code (valable 5 min, un seul usage, 3 essais). En repli, par exemple en SSH, `ptzd pair` l'affiche dans le Terminal :
 
    ```bash
-   ~/Library/Application\ Support/ObsbotNacelle/bin/ptzd pair
+   ~/Applications/PTZBot.app/Contents/Helpers/ptzd pair
    ```
 
    Puis, dans l'app de l'iPhone, toucher **Scanner le QR code** et viser l'écran du Mac (iOS demande l'accès à l'appareil photo). La clé de l'iPhone reste dans sa Secure Enclave ; le Mac garde sa clé publique et le secret du canal chiffré du réseau local, dans `devices.json` (droits 600). L'app retient l'adresse locale du Mac dans Réglages › Adresse du Mac (repli).
@@ -187,24 +188,16 @@ streams:
 
 ## Désinstaller
 
-Dans PTZBot pour Mac, décocher **Ouvrir à la connexion**, puis **Quitter**, et :
+Dans PTZBot pour Mac, décocher **Ouvrir à la connexion**, puis **Quitter** (`ptzd` s'arrête avec l'app), et mettre `~/Applications/PTZBot.app` à la corbeille.
 
-```bash
-rm -r ~/Applications/PTZBot.app
-```
-
-```bash
-launchctl bootout gui/$(id -u)/io.github.djoko-cli.obsbot-nacelle.ptzd
-```
-
-```bash
-rm ~/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.ptzd.plist
-```
+Les données restent dans `~/Library/Application Support/ObsbotNacelle/` (réglages, iPhone appairés, SDK) et les journaux dans `~/Library/Logs/obsbot-nacelle/`, tant qu'on ne les supprime pas :
 
 ```bash
 rm -r ~/Library/Application\ Support/ObsbotNacelle ~/Library/Logs/obsbot-nacelle
 ```
 
+Après une migration, la plist de l'ancien agent reste en `~/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.ptzd.plist.bak` : elle peut être supprimée.
+
 ## Contenu
 
 | Chemin | Rôle |
@@ -212,11 +205,10 @@ rm -r ~/Library/Application\ Support/ObsbotNacelle ~/Library/Logs/obsbot-nacelle
 | `Packages/NacelleProtocol/` | Messages échangés entre l'app et `ptzd`, partagés par les deux |
 | `mac/ptzd/` | Le service : logique (`PTZCore`), appairage et authentification (`PTZAuth`), accès USB (`CUVC`, `UVCCamera`), serveur WebSocket et écoute locale (`PTZServer`) |
 | `mac/ai/` | L'utilitaire `obsbot-ai` (C++, demande le SDK en local) |
-| `mac/app/` | L'app PTZBot pour Mac : `project.yml` (xcodegen), interface (`PTZBot/`) et logique testée (`PTZBotKit/`) |
-| `mac/launchd/` | Modèle du plist de l'agent launchd |
+| `mac/app/` | L'app PTZBot pour Mac : `project.yml` (xcodegen), interface (`PTZBot/`), logique testée (`PTZBotKit/`), compilation des utilitaires (`build-helpers.sh`) et vérification du paquet (`check-bundle.sh`) |
 | `mac/tools/` | Client WebSocket de test |
 | `ios/` | L'app iOS : `project.yml` (xcodegen), sources et tests |
-| `scripts/install-mac.sh` | Installation sur le Mac |
+| `scripts/install-mac.sh` | Compilation et installation de l'app sur le Mac |
 | `docs/` | Spec, plans et tests de faisabilité |
 | `spike/` | Sondes **jetables** des tests de faisabilité |
 
PATCH
````

Supprimer `mac/launchd/io.github.djoko-cli.obsbot-nacelle.ptzd.plist` :

```bash
git rm mac/launchd/io.github.djoko-cli.obsbot-nacelle.ptzd.plist
```

Remplacer tout le contenu de `scripts/install-mac.sh` par :

```bash
#!/bin/bash
# Compile PTZBot pour Mac, avec ptzd et obsbot-ai dans Contents/Helpers, l'installe dans
# ~/Applications/PTZBot.app et la lance (spec ptzd dans l'app § 5.7).
# Le script ne touche ni à launchd, ni à bin/, ni à lib/ : au premier lancement, l'app propose
# de remplacer l'ancienne installation, puis accompagne l'installation du SDK OBSBOT.
# Usage : scripts/install-mac.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$ROOT/vendor/obsbot-sdk"
APP="$HOME/Applications/PTZBot.app"
APP_ID="io.github.djoko-cli.ptzbot"
BUILT="$ROOT/mac/app/.build/Build/Products/Release/PTZBot.app"

if [ "$#" -ne 0 ]; then
    echo "usage : scripts/install-mac.sh" >&2
    exit 2
fi

# obsbot-ai se compile avec les en-têtes du SDK ; le SDK lui-même n'entre jamais dans l'app.
if [ ! -f "$SDK/include/dev/devs.hpp" ] || [ ! -f "$SDK/macos/arm64-release/libdev.dylib" ]; then
    echo "SDK OBSBOT introuvable dans $SDK : décompressez-y l'archive reçue d'OBSBOT pour compiler obsbot-ai." >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null; then
    echo "xcodegen introuvable : brew install xcodegen" >&2
    exit 1
fi

echo "Compilation de PTZBot pour Mac (avec ptzd et obsbot-ai)…"
(cd "$ROOT/mac/app" && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot \
    -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build -quiet)
"$ROOT/mac/app/check-bundle.sh" "$BUILT" >/dev/null

# L'app en cours est fermée avant d'être remplacée ; elle arrête son ptzd en partant (5 s au plus).
# On attend qu'aucun processus de ~/Applications/PTZBot.app ne reste (15 s au plus), et que
# LaunchServices l'ait vu partir : sinon `open` échoue (erreur -600).
EXE="$APP/Contents/MacOS/PTZBot"
still_running() {
    pgrep -f "$EXE" >/dev/null && return 0
    [ "$(osascript -e "application id \"$APP_ID\" is running" 2>/dev/null)" = "true" ]
}
osascript -e "tell application id \"$APP_ID\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
    still_running || break
    sleep 0.5
done
if still_running; then
    echo "PTZBot est encore ouvert après 15 s : quittez-le depuis la barre des menus (Quitter), puis relancez ce script. L'app n'a pas été remplacée." >&2
    exit 1
fi

mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$BUILT" "$APP"
# Dernier filet : `open` réessayé deux fois si LaunchServices n'a pas encore oublié l'ancienne app.
OPENED=0
for ATTEMPT in 1 2 3; do
    if open "$APP"; then
        OPENED=1
        break
    fi
    [ "$ATTEMPT" -lt 3 ] && sleep 1
done
if [ "$OPENED" = 0 ]; then
    echo "PTZBot est installé, mais n'a pas pu être lancé : ouvrez ~/Applications/PTZBot.app." >&2
    exit 1
fi
echo "PTZBot est dans la barre des menus."
echo "Au premier lancement, il propose de remplacer l'ancienne installation de ptzd s'il en trouve une."
echo "Le SDK OBSBOT s'installe depuis son panneau : SDK OBSBOT › Installer le SDK…"
echo "Journal : tail -f \"$HOME/Library/Logs/obsbot-nacelle/ptzd.log\""
```

- [ ] **Étape 2 : Vérifier**

```bash
bash -n scripts/install-mac.sh && echo 'Syntaxe du script : OK'
```

Attendu : « Syntaxe du script : OK ».

- [ ] **Étape 3 : Commiter et pousser**

```bash
git add README.md \
    scripts/install-mac.sh
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|8\.8\.8\.8|256\.0\.0\.1|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
B1 : install-mac.sh et README, ptzd dans l'app

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés plus haut sont déjà indexés par `git rm`.

### Tâche 7 : Installation et banc avec Majid

**But :** remplacer le prototype installé par la version issue du plan, puis vérifier au banc ce que les tests ne couvrent pas (spec B1 § 8).

**Fichiers :** aucun dans le dépôt.

- [ ] **Étape 1 : Prévenir Majid, noter les PID, installer**

Prévenir Majid : PTZBot et `ptzd` redémarrent, et l'iPhone perd la main quelques secondes.

```bash
pgrep -x go2rtc; pgrep -x coreaudiod
```

Depuis la copie de travail de la branche, le SDK relié :

```bash
scripts/install-mac.sh
```

```bash
sleep 5; pgrep -lf 'Helpers/ptzd' | sed -E 's#/Users/[^ ]*/#~/#g'; tail -6 ~/Library/Logs/obsbot-nacelle/ptzd.log | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g'
```

Attendu :
- l'installation se fait d'une traite, sans l'erreur -600 ;
- un seul `ptzd`, enfant de PTZBot, avec `--parent`, `--ai` et `--sdk` ;
- les écoutes et l'annonce Bonjour dans le journal.

Si macOS redemande le pare-feu pour le nouveau `ptzd`, c'est Majid qui accepte.

- [ ] **Étape 2 : Panneau et iPhone (Majid)**

1. Le panneau en sections montre :
   - « Actif » ;
   - « Service ptzd » allumé ;
   - « SDK OBSBOT : Prêt » avec « Changer… » ;
   - « Caméra · branchée » ;
   - « iPhone connectés » sans le Mac.
2. L'iPhone en Wi-Fi : vidéo, joystick et son ; puis en 4G.
3. Le suivi IA, allumé puis coupé depuis le panneau.

- [ ] **Étape 3 : Cycle de vie (Majid ; l'iPhone perd la main)**

1. Éteindre « Service ptzd » : l'iPhone affiche « Mac injoignable ». Le rallumer.
2. « Quitter » : l'icône disparaît en quelques secondes et `ptzd` s'arrête. Relancer PTZBot.
3. Tuer l'app de force (instance d'essai) et vérifier que `ptzd` s'arrête :

```bash
A=$(pgrep -x PTZBot); D=$(pgrep -f 'Helpers/ptzd'); kill -9 $A; sleep 1; kill -0 $D 2>/dev/null && echo "ptzd ENCORE vivant" || echo "ptzd arrêté"; open ~/Applications/PTZBot.app
```

- [ ] **Étape 4 : Bilan**

```bash
pgrep -x go2rtc; pgrep -x coreaudiod
```

Attendu : les mêmes PID qu'à l'étape 1. Noter le résultat de chaque étape dans le rapport, puis demander à Majid son accord pour fusionner dans `main`.
