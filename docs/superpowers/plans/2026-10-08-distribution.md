# Plan d'implémentation : distribution de PTZBot pour Mac (sous-projet B2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectif :** PTZBot pour Mac s'installe depuis une image disque et se met à jour seul avec Sparkle, sur des versions publiées sur GitHub. L'app est en anglais et en français, avec une langue choisie dans l'app. `obsbot-ai` n'est plus distribué : il est compilé chez l'utilisateur, avec le SDK qu'il fournit.

**Architecture :**
- **Signature et paquet.** Sparkle 2.10.0 est intégré par SwiftPM. L'app et `ptzd` sont signés avec le certificat auto-signé « Djoko-cli Code Signing », runtime renforcé, sans bac à sable.
- **Publication.** `publication.py` (repris de maillage-thread, adapté) compile, signe, crée le DMG, signe l'archive (Ed25519), met le flux à jour et publie la version GitHub.
- **Logique.** Elle est dans PTZBotKit et testée : compilation locale, transaction du SDK, langue, erreurs par code, politique de Sparkle. Les vues restent minces.

**Technologies :** Swift 6 strict, SwiftUI, Sparkle 2.10.0, String Catalogs (`.xcstrings`), `posix_spawn` (groupes de processus), Python 3 (`unittest`), `codesign`, `hdiutil`, `sign_update`, `gh`, xcodegen, Xcode 27.

**Spec :** [docs/superpowers/specs/2026-10-08-distribution-design.md](../specs/2026-10-08-distribution-design.md), § 12 compris, à lire avec ce plan. Elle prolonge la [spec B1](../specs/2026-10-07-ptzd-dans-app-design.md).

## Contraintes globales

- **Swift :** Swift 6, concurrence stricte, **aucun avertissement**. macOS 15, Apple Silicon. Aucun initialiseur ne touche le vrai système par défaut : seules les fabriques `system(...)` le font.
- **Mises à jour :** la clé Ed25519 est **obligatoire** (`SUVerifyUpdateBeforeExtraction`). Le flux est servi en HTTPS : `https://raw.githubusercontent.com/Djoko-cli/obsbot-nacelle/main/mac/app/appcast.xml`. Sparkle n'est jamais démarré sous les tests ni pour le numéro de compilation 1.
- **Distribué :** jamais de `libdev*.dylib`, de binaire `obsbot-ai`, d'en-têtes du SDK, ni de Mach-O lié à libdev. Droits de l'app : seulement la levée de la validation des bibliothèques. `ptzd` est signé sans droits, avec le runtime renforcé.
- **Textes :** le français est la langue source, au vouvoiement ; l'anglais est traduit. Toute langue autre que le français affiche l'anglais, sauf choix explicite dans Réglages. Le README et les notes de version sont en anglais d'abord, puis en français.
- **Dépôt public :**
  - aucune adresse IP réelle (seules 127.0.0.1, 0.0.0.0, 192.0.2.x, 169.254.x.x et, dans les tests, 10.0.0.5, 172.16/31/32.x, 192.168.0.x et 100.64.0.1) ;
  - aucun nom `*.ts.net` réel, aucun chemin `/Users/…` ;
  - ni identifiant d'équipe, ni empreinte de certificat, ni identifiant de l'éditeur du SDK.

  La clé publique Ed25519 est publique et peut être commitée. Le contrôle de fuite est donné à chaque commit.
- **Système en service :** pendant les tâches 1 à 5, ne jamais lancer `scripts/install-mac.sh`, `outils/publier.sh` hors des tests, `gh`, `git push --tags`, launchctl, `obsbot-ai on|off`, ni l'app construite. Ne jamais toucher à `~/Applications`, à `~/Library/Application Support/ObsbotNacelle`, ni au trousseau de Majid. Le SDK doit être relié dans la copie de travail (`ln -s <dépôt principal>/vendor vendor`, jamais commité).
- **Disque :** le Mac de Majid a peu de place libre. Supprimer ses propres sorties de compilation régénérables en fin de tâche.
- **Commits :** messages en français, terminés par une ligne `Co-Authored-By:` au nom du modèle qui commite ; pousser la branche à chaque commit. La fusion dans `main` et toute publication attendent l'accord de Majid.

## Fichiers

| Fichier | Rôle |
|---|---|
| `mac/app/PTZBotKit/Sources/PTZBotKit/{Toolchain,SDKInstaller,SDKInspector,SDKWindowModel,AppController,AppPaths}.swift` | Compilation locale d'`obsbot-ai`, transaction du SDK, outils d'Apple |
| `mac/app/PTZBotKit/Sources/PTZBotKit/{Localization,AppLanguage,ErrorTexts,Labels,ServiceLabels}.swift`, `Resources/Localizable.xcstrings` | Textes bilingues, langue choisie, erreurs par code |
| `Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift`, `mac/ptzd/Sources/PTZCore/{AIRunner,PTZController}.swift` | Motifs du suivi IA partagés (`AIFailureText`) |
| `mac/app/PTZBotKit/Sources/PTZBotKit/Updater.swift`, `mac/app/PTZBot/{SparkleUpdater,SettingsView,AppText}.swift`, `*.xcstrings`, `project.yml` | Sparkle, Réglages, app bilingue |
| `mac/app/{build-helpers,check-bundle}.sh` | Source d'`obsbot-ai` dans le paquet, contenu interdit |
| `outils/{publication.py,publier.sh,Sparkle-LICENSE.txt}`, `outils/tests/test_publication.py`, `NOTES-VERSIONS.md` | Publication |
| `README.md`, `scripts/install-mac.sh`, spec B2 § 12 | Documentation |

## Points vérifiés en préparant ce plan

Le plan a été prototypé en entier, relu par Opus puis par Sonnet, puis essayé au banc avec Majid le 08/10. Il a ensuite été rejoué tâche par tâche sur une copie vierge : chaque tâche échoue à l'étape 2 et passe à l'étape 4, sans avertissement, et son texte reproduit exactement le prototype.

1. **Répétition sans GitHub.** Elle a utilisé un trousseau et des clés jetables, et `sparkle-cli` compilé depuis la source 2.10.0, car il n'est pas dans les artefacts. Résultats :
   - la mise à jour 1.0.0 → 1.0.1 passe ;
   - une signature Ed25519 étrangère est refusée (4005) ;
   - une mise à jour qui embarque une autre clé publique et porte le certificat d'essai est **refusée**, grâce à `SUVerifyUpdateBeforeExtraction` ;
   - un DMG altéré est refusé ;
   - un flux sans nouveauté ne change rien.

   L'erreur 1004 rencontrée une fois est un artefact : l'installateur de Sparkle reste un instant en vie après un refus.
2. **Fin de l'app pour une mise à jour.** Dans Sparkle 2.10, la fin passe par un événement « quit » d'Apple, donc par `applicationShouldTerminate`, qui arrête `ptzd`.
3. **Compilation locale.** `obsbot-ai`, compilé avec les vrais en-têtes, charge le SDK : code 3 avec `DYLD_LIBRARY_PATH`, 134 sans.
4. **Banc avec Majid :**
   - SDK complété par la fenêtre, compilation d'`obsbot-ai`, puis suivi IA ;
   - langue changée en direct dans Réglages ;
   - pied du panneau et ligne SDK revus.

## Décisions prises en préparant ce plan

Elles sont reportées dans la spec, § 12 :
- préparation dans `sdk/new/` avec un journal, validation par sa suppression puis `rmdir` ;
- `SUVerifyUpdateBeforeExtraction` ;
- vérification de fuite mot par mot, avec les deux arcs d'OID admis dans le DMG ;
- signature des utilitaires relue ;
- révision de Sparkle vérifiée ;
- `strip -S` de `ptzd` ;
- choix explicite de la langue et réglage « Langue » dans l'app ;
- bouton des outils de développement ;
- `AIFailureText` ;
- états courts dans le panneau.

## Ordre et présence de Majid

- Tâches 1 à 5 : du code et des tests, sans rien publier ni toucher au système en service.
- Tâche 6 : fusion, publication de la 1.0.0 et installation depuis le DMG, **avec Majid et avec son accord à chaque geste public**.

---

### Tâche 1 : PTZBotKit : compilation d'`obsbot-ai` sur le Mac de l'utilisateur

**But :** PTZBot ne livre plus `obsbot-ai` compilé. À l'installation du SDK, il compile `obsbot-ai` chez l'utilisateur, avec les en-têtes de l'archive choisie et les outils d'Apple, puis échange en une seule transaction journalisée trois éléments : la bibliothèque, `obsbot-ai` et les en-têtes. Le retour en arrière est complet. Il recompile seul quand la source livrée change, et propose « Installer les outils de développement… » quand ces outils manquent (spec B2 § 6 et § 12).

**Fichiers :**
- Modifier : `mac/app/PTZBot/PanelView.swift`
- Modifier : `mac/app/PTZBot/SDKView.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/SDKWindowModel.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Toolchain.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift`
- Créer : `mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKInstallerTests.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift`

**Interfaces :**
- Produit (PTZBotKit) :
  - `Toolchain` et `SystemToolchain(xcodeSelect:xcrun:timeout:)` : `isAvailable()`, `compile(source:includeDirectory:libraryDirectory:output:) throws(ToolchainError)`, `system()` ; l'arrêt sur délai vise le groupe de processus ;
  - `SDKInstaller(sdkDirectory:sourceURL:toolchain:verifier:buildLog:…)` : `install(_:)`, `status()`, `recompileIfNeeded()`, `needsRecompile()`, `sourceHash()` ; préparation dans `sdk/new/` avec le journal `.transaction`, validation par la suppression du journal puis `rmdir` ;
  - `SDKStatus` gagne `incomplete`, `toolsRequired(fallback:)`, `compileFailed(fallback:)`, `recompiling` et `sourceMissing` ; `SDKInstallError` gagne `headersMissing`, `headersNotPlain`, `toolsMissing` et `compileFailed(output:)` ;
  - `AppController.checkTools()`, `installDeveloperTools()`, `panelOpened()` ;
  - `SDKWindowModel.installTools()` ;
  - `Labels.sdkDetail(_:toolsAvailable:)`, `sdkAction(_:toolsAvailable:)`, `sdkActionInstallsTools(_:toolsAvailable:)` ;
  - `AppPaths.obsbotAI` vaut `<support>/sdk/obsbot-ai`.
- Vues : la ligne SDK du panneau affiche un état court à droite et le détail dessous ; `SDKView` montre le bouton des outils.

- [ ] **Étape 1 : Écrire les tests**

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift
index 2abc018..c4526ab 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift
@@ -11,12 +11,24 @@ struct AppControllerTests {
     let launcher = FakeLauncher()
     let scheduler = FakeScheduler()
     let launchctl = FakeLaunchctl()
+    let toolchain = FakeToolchain()
     let supervisor: ServiceSupervisor
 
     init() throws {
         root = try FakeSDK.directory()
         paths = AppPaths(bundle: root.appending(path: "PTZBot.app"), home: root)
         supervisor = ServiceSupervisor(paths: paths.service, launcher: launcher, settings: FakeSettings(), scheduler: scheduler, parentPID: 4242)
+        try FakeSDK.write(Data("int main() { return 3; }\n".utf8), to: paths.obsbotAISource)
+    }
+
+    private func installer(sdkLoads: Bool = true) -> SDKInstaller {
+        SDKInstaller(
+            sdkDirectory: paths.sdkDirectory,
+            sourceURL: paths.obsbotAISource,
+            toolchain: toolchain,
+            verifier: FakeVerifier(sdkLoads).verifier,
+            buildLog: paths.obsbotAIBuildLog
+        )
     }
 
     private func controller(
@@ -38,7 +50,7 @@ struct AppControllerTests {
             ),
             configURL: paths.config,
             interfaces: interfaces.map { FakeInterfaces(interfaces: $0) } ?? FakeInterfaces(addresses: addresses),
-            sdkInstaller: SDKInstaller(sdkDirectory: paths.sdkDirectory, verifier: FakeVerifier(sdkLoads).verifier),
+            sdkInstaller: installer(sdkLoads: sdkLoads),
             scheduler: scheduler,
             confirmMigration: {
                 asked.value += 1
@@ -99,7 +111,7 @@ struct AppControllerTests {
         #expect(!ConfigBootstrap.listensOnLoopbackOnly(configURL: root.appending(path: "absent.json")))
     }
 
-    @Test("Ancienne installation, « Remplacer » : migration, puis ptzd de l'app ; SDK repris et prêt")
+    @Test("Ancienne installation, « Remplacer » : migration, puis ptzd de l'app ; SDK repris, à compléter (ni en-têtes ni obsbot-ai)")
     func replace() async throws {
         defer { try? FileManager.default.removeItem(at: root) }
         try installLegacy()
@@ -111,7 +123,7 @@ struct AppControllerTests {
         #expect(app.migrationError == nil)
         #expect(!supervisor.legacyAgentActive)
         #expect(supervisor.state == .running)
-        #expect(app.sdkStatus == .ready)
+        #expect(app.sdkStatus == .incomplete)
         #expect(FileManager.default.fileExists(atPath: paths.sdkDirectory.appending(path: "libdev.dylib").path))
         #expect(!app.tailscaleMissing)
     }
@@ -130,7 +142,7 @@ struct AppControllerTests {
         #expect(!FileManager.default.fileExists(atPath: paths.support.appending(path: "bin/ptzd").path))
         #expect(!FileManager.default.fileExists(atPath: paths.support.appending(path: "bin/obsbot-ai").path))
         #expect(FileManager.default.fileExists(atPath: paths.sdkDirectory.appending(path: "libdev.dylib").path))
-        #expect(app.sdkStatus == .ready)
+        #expect(app.sdkStatus == .incomplete)
         #expect(supervisor.state == .running)
     }
 
@@ -166,7 +178,7 @@ struct AppControllerTests {
         #expect(app.legacy == .none)
         #expect(!app.canReplaceLegacy)
         #expect(supervisor.state == .running)
-        #expect(app.sdkStatus == .ready)
+        #expect(app.sdkStatus == .incomplete)
         await app.offerMigration()
         #expect(asked.value == 3)
     }
@@ -199,6 +211,89 @@ struct AppControllerTests {
         #expect(launcher.launched.isEmpty)
     }
 
+    @Test("Lancement après une mise à jour de l'app : obsbot-ai recompilé sans rien demander, puis prêt")
+    func recompileAtLaunch() async throws {
+        defer { try? FileManager.default.removeItem(at: root) }
+        let sdk = installer()
+        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: sdk.libraryURL)
+        try FakeSDK.write(Data("// en-tête".utf8), to: sdk.headersURL.appending(path: "dev/devs.hpp"))
+        try FakeSDK.write(Data("ancien binaire".utf8), to: sdk.obsbotAIURL)
+        try FakeSDK.write(Data("empreinte de la version précédente\n".utf8), to: sdk.hashURL)
+        let app = controller()
+        await app.launch()
+        #expect(toolchain.compiled.count == 1)
+        #expect(app.sdkStatus == .ready)
+        #expect(!sdk.needsRecompile())
+    }
+
+    @Test("Outils absents : « Outils de développement requis » ; le bouton lance xcode-select --install ; panneau rouvert : état relu")
+    func developerTools() async throws {
+        defer { try? FileManager.default.removeItem(at: root) }
+        let sdk = installer()
+        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: sdk.libraryURL)
+        try FakeSDK.write(Data("// en-tête".utf8), to: sdk.headersURL.appending(path: "dev/devs.hpp"))
+        toolchain.available.withLock { $0 = false }
+        let app = controller()
+        await app.launch()
+        #expect(app.sdkStatus == .toolsRequired(fallback: false))
+        app.installDeveloperTools()
+        for _ in 0..<200 where toolchain.installRequests.withLock({ $0 }) == 0 {
+            try await Task.sleep(for: .milliseconds(10))
+        }
+        #expect(toolchain.installRequests.withLock { $0 } == 1)
+        toolchain.available.withLock { $0 = true }
+        await app.panelOpened()
+        #expect(toolchain.compiled.count == 1)
+        #expect(app.sdkStatus == .ready)
+        // Prêt : rouvrir le panneau ne relit rien.
+        await app.panelOpened()
+        #expect(toolchain.compiled.count == 1)
+    }
+
+    @Test("Mac neuf sans outils d'Apple : le bouton de la ligne SDK installe les outils, avant tout choix du SDK")
+    func toolsMissingOnFreshMac() async throws {
+        defer { try? FileManager.default.removeItem(at: root) }
+        toolchain.available.withLock { $0 = false }
+        let app = controller()
+        await app.launch()
+        #expect(app.sdkStatus == .absent)
+        #expect(app.toolsAvailable == false)
+        let tools = app.toolsAvailable ?? true
+        #expect(Labels.sdkAction(app.sdkStatus, toolsAvailable: tools) == "Installer les outils de développement…")
+        #expect(Labels.sdkActionInstallsTools(app.sdkStatus, toolsAvailable: tools))
+        // Outils installés depuis : le panneau rouvert relit l'état, et le bouton redevient « Installer le SDK… ».
+        toolchain.available.withLock { $0 = true }
+        await app.panelOpened()
+        #expect(app.toolsAvailable == true)
+        #expect(Labels.sdkAction(app.sdkStatus, toolsAvailable: app.toolsAvailable ?? true) == "Installer le SDK…")
+    }
+
+    @Test("Vérifications du SDK simultanées : mises à la file, jamais une fausse « compilation impossible »")
+    func serializedRefresh() async throws {
+        defer { try? FileManager.default.removeItem(at: root) }
+        let sdk = installer()
+        try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: sdk.libraryURL)
+        try FakeSDK.write(Data("// en-tête".utf8), to: sdk.headersURL.appending(path: "dev/devs.hpp"))
+        try FakeSDK.write(Data("ancien binaire".utf8), to: sdk.obsbotAIURL)
+        try FakeSDK.write(Data("autre empreinte\n".utf8), to: sdk.hashURL)
+        // La compilation dure : une seconde vérification arrive pendant ce temps.
+        toolchain.during.withLock { $0 = { Thread.sleep(forTimeInterval: 0.3) } }
+        let app = controller()
+        let seen = StatusLog()
+        async let first: Void = app.refreshSDK()
+        async let second: Void = app.refreshSDK()
+        async let third: Void = { @MainActor in
+            for _ in 0..<40 {
+                seen.add(app.sdkStatus)
+                try? await Task.sleep(for: .milliseconds(10))
+            }
+        }()
+        _ = await (first, second, third)
+        #expect(app.sdkStatus == .ready)
+        #expect(toolchain.compiled.count == 1)
+        #expect(!seen.values.contains { if case .compileFailed = $0 { true } else { false } })
+    }
+
     @Test("ptzd sort avec 75 : « Le port <port de config.json> est déjà pris… », sans relance")
     func portBusy() async throws {
         defer { try? FileManager.default.removeItem(at: root) }
@@ -289,6 +384,16 @@ final class Answers {
     }
 }
 
+/// Les états du SDK vus pendant un essai.
+@MainActor
+final class StatusLog {
+    private(set) var values: [SDKStatus?] = []
+
+    func add(_ status: SDKStatus?) {
+        values.append(status)
+    }
+}
+
 /// Compteur partagé avec une fermeture.
 @MainActor
 final class Counter {
@@ -298,22 +403,37 @@ final class Counter {
 @MainActor
 @Suite("Fenêtre « SDK OBSBOT »")
 struct SDKWindowModelTests {
+    static func installer(_ directory: URL, loads: Bool) -> SDKInstaller {
+        let source = directory.appending(path: "obsbot-ai.cpp")
+        try? Data("int main() { return 3; }\n".utf8).write(to: source)
+        return SDKInstaller(
+            sdkDirectory: directory.appending(path: "sdk"),
+            sourceURL: source,
+            toolchain: FakeToolchain(),
+            verifier: FakeVerifier(loads).verifier,
+            buildLog: directory.appending(path: "compilation.log")
+        )
+    }
+
     @Test("Choix refusé : motif ; choix accepté puis autorisé : installé, dossier d'extraction effacé")
     func flow() async throws {
         let directory = try FakeSDK.directory()
         defer { try? FileManager.default.removeItem(at: directory) }
-        let installer = SDKInstaller(sdkDirectory: directory.appending(path: "sdk"), verifier: FakeVerifier(true).verifier)
+        let installer = Self.installer(directory, loads: true)
         let model = SDKWindowModel(installer: installer)
         var installed = 0
         model.onInstalled = { installed += 1 }
 
-        let text = try FakeSDK.write(Data("texte".utf8), to: directory.appending(path: "texte.dylib"))
-        await model.choose(text)
+        try FakeSDK.folder(directory.appending(path: "texte"), library: Data("texte".utf8))
+        await model.choose(directory.appending(path: "texte"))
         #expect(model.phase == .rejected("Ce fichier n'est pas une bibliothèque Mach-O."))
+        let alone = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "seul/libdev.dylib"))
+        await model.choose(alone)
+        #expect(model.phase == .rejected("Choisissez l'archive ou le dossier du SDK : ses en-têtes sont nécessaires."))
 
-        let library = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "choix/libdev.dylib"))
+        let library = try FakeSDK.folder(directory.appending(path: "choix"))
         FakeSDK.setQuarantine(library)
-        await model.choose(library)
+        await model.choose(directory.appending(path: "choix"))
         guard case let .candidate(candidate) = model.phase else {
             Issue.record("candidat attendu")
             return
@@ -335,7 +455,7 @@ struct SDKWindowModelTests {
         let extraction = directory.appending(path: "extraction")
         let library = try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: extraction.appending(path: "macos/arm64-release/libdev.dylib"))
         let model = SDKWindowModel(
-            installer: SDKInstaller(sdkDirectory: directory.appending(path: "sdk"), verifier: FakeVerifier(true).verifier),
+            installer: Self.installer(directory, loads: true),
             inspect: { _ throws(SDKRejection) in
                 Thread.sleep(forTimeInterval: 0.2)
                 return SDKCandidate(path: library, architectures: ["arm64"], temporaryDirectory: extraction)
@@ -351,13 +471,48 @@ struct SDKWindowModelTests {
         #expect(!FileManager.default.fileExists(atPath: extraction.path))
     }
 
+    @Test("Outils absents : la fenêtre propose de les installer avant le choix ; xcode-select --install sur clic seulement")
+    func toolsFirst() async throws {
+        let directory = try FakeSDK.directory()
+        defer { try? FileManager.default.removeItem(at: directory) }
+        let toolchain = FakeToolchain(available: false)
+        let source = try FakeSDK.write(Data("int main() { return 3; }\n".utf8), to: directory.appending(path: "obsbot-ai.cpp"))
+        let model = SDKWindowModel(installer: SDKInstaller(
+            sdkDirectory: directory.appending(path: "sdk"),
+            sourceURL: source,
+            toolchain: toolchain,
+            verifier: FakeVerifier(true).verifier,
+            buildLog: directory.appending(path: "compilation.log")
+        ))
+        #expect(model.toolsAvailable)
+        await model.checkTools()
+        #expect(!model.toolsAvailable)
+        #expect(toolchain.installRequests.withLock { $0 } == 0)
+        model.installTools()
+        for _ in 0..<200 where toolchain.installRequests.withLock({ $0 }) == 0 {
+            try await Task.sleep(for: .milliseconds(10))
+        }
+        #expect(toolchain.installRequests.withLock { $0 } == 1)
+        toolchain.available.withLock { $0 = true }
+        await model.checkTools()
+        #expect(model.toolsAvailable)
+        // Outils disparus entre la vérification et l'installation : la fenêtre repasse aux outils.
+        try FakeSDK.folder(directory.appending(path: "choix"))
+        await model.choose(directory.appending(path: "choix"))
+        toolchain.available.withLock { $0 = false }
+        await model.authorize()
+        #expect(model.phase == .failed(SDKInstallError.toolsMissing.message))
+        #expect(!model.toolsAvailable)
+    }
+
     @Test("Vérification en échec : message, rien n'est installé")
     func failure() async throws {
         let directory = try FakeSDK.directory()
         defer { try? FileManager.default.removeItem(at: directory) }
-        let installer = SDKInstaller(sdkDirectory: directory.appending(path: "sdk"), verifier: FakeVerifier(false).verifier)
+        let installer = Self.installer(directory, loads: false)
         let model = SDKWindowModel(installer: installer)
-        await model.choose(try FakeSDK.write(FakeSDK.thin(FakeSDK.arm64), to: directory.appending(path: "libdev.dylib")))
+        try FakeSDK.folder(directory.appending(path: "choix"))
+        await model.choose(directory.appending(path: "choix"))
         await model.authorize()
         #expect(model.phase == .failed(SDKInstallError.unloadable.message))
         #expect(!FileManager.default.fileExists(atPath: installer.libraryURL.path))
@@ -398,7 +553,7 @@ struct ServiceLabelsTests {
         #expect(Labels.sdk(.quarantined) == "En quarantaine")
         #expect(Labels.sdk(.incompatible) == "Incompatible")
         #expect(Labels.sdk(.unloadable) == "Ne se charge pas")
-        #expect(Labels.sdk(.verifierMissing) == "obsbot-ai introuvable")
+        #expect(Labels.sdk(.sourceMissing) == "obsbot-ai introuvable")
         #expect(Labels.sdk(nil) == "Vérification…")
         #expect(Labels.aiNeedsSDK(.absent, legacy: false))
         #expect(Labels.aiNeedsSDK(nil, legacy: false))
@@ -409,10 +564,55 @@ struct ServiceLabelsTests {
         #expect(Labels.sdkAction(.absent) == "Installer le SDK…")
         #expect(Labels.sdkAction(.quarantined) == "Installer le SDK…")
         #expect(Labels.sdkAction(nil) == nil)
-        #expect(Labels.sdkAction(.verifierMissing) == nil)
+        #expect(Labels.sdkAction(.sourceMissing) == nil)
         #expect(Labels.replaceLegacy == "Remplacer l'ancienne installation…")
     }
 
+    @Test("SDK : nouveaux états de la compilation locale, boutons et notes (spec distribution § 6.4)")
+    func compileStates() {
+        // États courts, à droite de la ligne (banc du 08/10) ; l'explication va dessous.
+        #expect(Labels.sdk(.toolsRequired(fallback: false)) == "Outils requis")
+        #expect(Labels.sdk(.incomplete) == "À compléter")
+        #expect(Labels.sdk(.recompiling) == "Recompilation…")
+        #expect(Labels.sdk(.compileFailed(fallback: false)) == "Compilation impossible")
+        let everyStatus: [SDKStatus?] = [nil, .ready, .absent, .quarantined, .incompatible, .unloadable, .sourceMissing,
+                                         .toolsRequired(fallback: false), .incomplete, .recompiling, .compileFailed(fallback: true)]
+        #expect(everyStatus.allSatisfy { Labels.sdk($0).count <= 22 })
+        #expect(Labels.sdkDetail(.incomplete) == "Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent.")
+        #expect(Labels.sdkDetail(.incomplete, toolsAvailable: false) == "Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent. Installez d'abord les outils de développement d'Apple.")
+        #expect(Labels.sdkDetail(.absent, toolsAvailable: false) == "Installez d'abord les outils de développement d'Apple.")
+        #expect(Labels.sdkDetail(.absent) == nil)
+        #expect(Labels.sdkDetail(.ready) == nil)
+        #expect(Labels.sdkDetail(.recompiling) == nil)
+        #expect(Labels.sdkDetail(.quarantined) == "Le SDK ne se charge pas : réinstallez-le pour retirer la quarantaine de sa copie.")
+        #expect(Labels.sdkDetail(.incompatible) == "Ce SDK n'a pas de version pour Apple Silicon.")
+        #expect(Labels.sdkDetail(.unloadable) == "obsbot-ai ne charge pas ce SDK : réinstallez-le.")
+        #expect(Labels.sdkDetail(.sourceMissing) == "La source d'obsbot-ai manque dans l'app : réinstallez PTZBot.")
+        #expect(Labels.sdkAction(.toolsRequired(fallback: true)) == "Installer les outils de développement…")
+        #expect(Labels.sdkActionInstallsTools(.toolsRequired(fallback: false)))
+        #expect(!Labels.sdkActionInstallsTools(.absent))
+        #expect(Labels.sdkAction(.incomplete) == "Installer le SDK…")
+        #expect(Labels.sdkAction(.compileFailed(fallback: true)) == "Installer le SDK…")
+        #expect(Labels.sdkAction(.recompiling) == nil)
+        // Outils absents : le bouton installe d'abord les outils, pour un SDK absent, à compléter ou à réinstaller.
+        for status in [SDKStatus.absent, .incomplete, .unloadable, .quarantined] {
+            #expect(Labels.sdkAction(status, toolsAvailable: false) == "Installer les outils de développement…")
+            #expect(Labels.sdkActionInstallsTools(status, toolsAvailable: false))
+            #expect(!Labels.sdkActionInstallsTools(status, toolsAvailable: true))
+        }
+        #expect(Labels.sdkAction(.ready, toolsAvailable: false) == "Changer…")
+        #expect(Labels.sdkAction(.recompiling, toolsAvailable: false) == nil)
+        #expect(Labels.sdkDetail(.toolsRequired(fallback: true)) == "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai. L'ancien obsbot-ai reste en service.")
+        #expect(Labels.sdkDetail(.toolsRequired(fallback: false), toolsAvailable: false) == "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai.")
+        #expect(Labels.sdkDetail(.compileFailed(fallback: false)) == "Le détail est dans le journal obsbot-ai-compilation.log.")
+        #expect(Labels.sdkDetail(.compileFailed(fallback: true)) == "L'ancien obsbot-ai reste en service. Le détail est dans le journal obsbot-ai-compilation.log.")
+        // Ancien obsbot-ai en service : le suivi IA reste disponible.
+        #expect(!Labels.aiNeedsSDK(.toolsRequired(fallback: true), legacy: false))
+        #expect(Labels.aiNeedsSDK(.toolsRequired(fallback: false), legacy: false))
+        #expect(Labels.aiNeedsSDK(.incomplete, legacy: false))
+        #expect(Labels.aiNeedsSDK(.recompiling, legacy: false))
+    }
+
     @Test("Sections du panneau : Service, Caméra avec son état, iPhone connectés, note du suivi IA")
     func sections() {
         #expect(Labels.serviceSection == "Service")
@@ -501,7 +701,11 @@ struct ServiceLabelsTests {
     func paths() {
         let paths = AppPaths(bundle: URL(fileURLWithPath: "/Applications/PTZBot.app"), home: URL(fileURLWithPath: "/maison/exemple"))
         #expect(paths.ptzd.path == "/Applications/PTZBot.app/Contents/Helpers/ptzd")
-        #expect(paths.obsbotAI.path == "/Applications/PTZBot.app/Contents/Helpers/obsbot-ai")
+        // obsbot-ai est compilé chez l'utilisateur, à côté du SDK ; l'app ne livre que sa source.
+        #expect(paths.obsbotAI.path == "/maison/exemple/Library/Application Support/ObsbotNacelle/sdk/obsbot-ai")
+        #expect(paths.obsbotAISource.path == "/Applications/PTZBot.app/Contents/Resources/obsbot-ai.cpp")
+        #expect(paths.obsbotAIBuildLog.path == "/maison/exemple/Library/Logs/obsbot-nacelle/obsbot-ai-compilation.log")
+        #expect(paths.service.ai == paths.obsbotAI)
         #expect(paths.sdkDirectory.path == "/maison/exemple/Library/Application Support/ObsbotNacelle/sdk")
         #expect(paths.config.path == "/maison/exemple/Library/Application Support/ObsbotNacelle/config.json")
         #expect(paths.ptzdLog.path == "/maison/exemple/Library/Logs/obsbot-nacelle/ptzd.log")
PATCH
```

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKInstallerTests.swift` :

```swift
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

@Suite("SDK : installation et compilation d'obsbot-ai")
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
```

Remplacer tout le contenu de `mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift` par :

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

```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' | grep -v appintents && ./check-bundle.sh)
```

Attendu : échec — la compilation des tests échoue : `Toolchain`, les nouveaux états et `recompileIfNeeded` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Modifier `mac/app/PTZBot/PanelView.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBot/PanelView.swift b/mac/app/PTZBot/PanelView.swift
index c0ac1aa..4804621 100644
--- a/mac/app/PTZBot/PanelView.swift
+++ b/mac/app/PTZBot/PanelView.swift
@@ -60,8 +60,10 @@ struct PanelView: View {
         .padding(14)
         .frame(width: 320)
         .onAppear {
-            // Panneau ouvert : l'autorisation « Réseau local » a pu changer dans les Réglages.
+            // Panneau ouvert : l'autorisation « Réseau local » a pu changer dans les Réglages, et les outils de
+            // développement ont pu être installés.
             network.check()
+            Task { await app.panelOpened() }
         }
     }
 
@@ -119,15 +121,28 @@ struct PanelView: View {
                 }
             }
             Divider()
+            // À droite, l'état court seulement ; l'explication et le bouton vont dessous, sur toute la largeur
+            // (banc du 08/10 : un état long débordait sur six lignes et tronquait le bouton).
             PanelRow(icon: "shippingbox", title: "SDK OBSBOT") {
-                HStack(spacing: 6) {
-                    Text(Labels.sdk(app.sdkStatus)).foregroundStyle(.secondary)
-                    if let action = Labels.sdkAction(app.sdkStatus) {
-                        Button(action) {
+                Text(Labels.sdk(app.sdkStatus))
+                    .foregroundStyle(.secondary)
+                    .lineLimit(1)
+                    .fixedSize()
+            } notes: {
+                let tools = app.toolsAvailable ?? true
+                if let detail = Labels.sdkDetail(app.sdkStatus, toolsAvailable: tools) {
+                    PanelNote(detail)
+                }
+                if let action = Labels.sdkAction(app.sdkStatus, toolsAvailable: tools) {
+                    Button(action) {
+                        if Labels.sdkActionInstallsTools(app.sdkStatus, toolsAvailable: tools) {
+                            app.installDeveloperTools()
+                        } else {
                             openWindow.front(WindowID.sdk)
                         }
-                        .buttonStyle(.link)
                     }
+                    .buttonStyle(.link)
+                    .font(.caption)
                 }
             }
         }
PATCH
```

Remplacer tout le contenu de `mac/app/PTZBot/SDKView.swift` par :

```swift
import PTZBotKit
import SwiftUI
import UniformTypeIdentifiers

/// La fenêtre « SDK OBSBOT » (spec ptzd dans l'app § 6.2, spec distribution § 6) : explication, outils de
/// développement s'ils manquent, choix, vérifications, autorisation.
struct SDKView: View {
    let model: SDKWindowModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Labels.sdkExplanation)
                .fixedSize(horizontal: false, vertical: true)
            if model.toolsAvailable {
                choiceButtons
            } else {
                // Sans les outils d'Apple, obsbot-ai ne peut pas être compilé : ils passent avant le choix du SDK.
                Text(Labels.sdkToolsExplanation)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(Labels.installTools) {
                        model.installTools()
                    }
                    .buttonStyle(.borderedProminent)
                    Button(Labels.checkToolsAgain) {
                        Task { await model.checkTools() }
                    }
                }
            }

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
                .disabled(!model.toolsAvailable)
            case let .rejected(message), let .failed(message):
                Text(message).foregroundStyle(.red)
            case .installing:
                ProgressView("Installation du SDK et compilation d'obsbot-ai…")
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
        .task {
            await model.checkTools()
        }
        .onDisappear {
            model.reset()
        }
    }

    private var choiceButtons: some View {
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
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "Choisissez l'archive du SDK OBSBOT (.zip) ou son dossier décompressé : ses en-têtes sont nécessaires."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.choose(url) }
    }
}
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift
index 7c7c79c..7a3dc61 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift
@@ -27,6 +27,8 @@ public final class AppController {
     public private(set) var migrationProblems: [String] = []
     /// nil pendant la vérification.
     public private(set) var sdkStatus: SDKStatus?
+    /// Les outils de développement d'Apple sont installés (`xcode-select -p`) ; nil avant la première vérification.
+    public private(set) var toolsAvailable: Bool?
     public private(set) var tailscaleMissing = false
     public private(set) var configError: String?
     public let supervisor: ServiceSupervisor
@@ -38,6 +40,8 @@ public final class AppController {
     @ObservationIgnored private let scheduler: any Scheduler
     @ObservationIgnored private let confirmMigration: @MainActor () async -> Bool
     @ObservationIgnored private var launched = false
+    /// La vérification du SDK en cours : la suivante l'attend (jamais deux à la fois).
+    @ObservationIgnored private var sdkRefresh: Task<Void, Never>?
     /// `config.json` est prêt (créé au besoin) : l'app relit le port de ptzd.
     @ObservationIgnored public var onConfigReady: (@MainActor () -> Void)?
 
@@ -116,11 +120,46 @@ public final class AppController {
         }
     }
 
+    /// L'état du SDK, après une recompilation d'obsbot-ai si la source de l'app a changé (spec distribution § 6.3) :
+    /// « Recompilation… » pendant ce temps, sans rien demander. Les appels sont mis à la file : une vérification ne
+    /// lit jamais l'état pendant la recompilation d'une autre (elle y verrait une fausse « compilation impossible »).
     public func refreshSDK() async {
+        let previous = sdkRefresh
+        let task = Task { @MainActor in
+            await previous?.value
+            await self.performSDKRefresh()
+        }
+        sdkRefresh = task
+        await task.value
+    }
+
+    private func performSDKRefresh() async {
         let installer = sdkInstaller
+        let toolchain = installer.toolchain
+        toolsAvailable = await Task.detached { toolchain.isAvailable() }.value
+        if await Task.detached(operation: { installer.needsRecompile() }).value {
+            sdkStatus = .recompiling
+            // Un échec laisse l'ancien obsbot-ai en service ; `status()` le dit.
+            _ = await Task.detached { (try? installer.recompileIfNeeded()) ?? false }.value
+        }
         sdkStatus = await Task.detached { installer.status() }.value
     }
 
+    /// Panneau ouvert : si les outils de développement manquaient, ils ont pu être installés depuis.
+    public func panelOpened() async {
+        if case .toolsRequired = sdkStatus {
+            await refreshSDK()
+        } else if toolsAvailable == false {
+            await refreshSDK()
+        }
+    }
+
+    /// « Installer les outils de développement… » : `xcode-select --install`, l'utilisateur accepte chez Apple.
+    public func installDeveloperTools() {
+        let toolchain = sdkInstaller.toolchain
+        Task.detached { toolchain.requestInstall() }
+    }
+
     /// Arrête ptzd (SIGTERM, puis SIGKILL à 5 s), puis `completion`, une seule fois, au plus tard après `quitTimeout`.
     public func quit(completion: @escaping @MainActor () -> Void) {
         let once = Once(completion)
PATCH
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift
index fb19a9a..ab5b5ba 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift
@@ -1,6 +1,7 @@
 import Foundation
 
-/// Les emplacements de l'app, de ses utilitaires et des fichiers de l'utilisateur (spec ptzd dans l'app § 5.1 et § 5.2).
+/// Les emplacements de l'app, de ses utilitaires et des fichiers de l'utilisateur (spec ptzd dans l'app § 5.1 et § 5.2,
+/// spec distribution § 5.1 et § 6).
 public struct AppPaths: Equatable, Sendable {
     /// `~/Library/Application Support/ObsbotNacelle`.
     public var support: URL
@@ -8,11 +9,14 @@ public struct AppPaths: Equatable, Sendable {
     public var logs: URL
     /// `PTZBot.app/Contents/Helpers`.
     public var helpers: URL
+    /// `PTZBot.app/Contents/Resources`.
+    public var resources: URL
 
     public init(bundle: URL, home: URL) {
         support = home.appending(path: "Library/Application Support/ObsbotNacelle")
         logs = home.appending(path: "Library/Logs/obsbot-nacelle")
         helpers = bundle.appending(path: "Contents/Helpers")
+        resources = bundle.appending(path: "Contents/Resources")
     }
 
     /// Les emplacements réels : l'app en cours et le dossier de l'utilisateur. Pour l'app seulement ; les tests
@@ -37,8 +41,19 @@ public struct AppPaths: Equatable, Sendable {
         helpers.appending(path: "ptzd")
     }
 
+    /// obsbot-ai, compilé chez l'utilisateur à côté du SDK (spec distribution § 6.4) : jamais dans l'app.
     public var obsbotAI: URL {
-        helpers.appending(path: "obsbot-ai")
+        sdkDirectory.appending(path: "obsbot-ai")
+    }
+
+    /// La source d'obsbot-ai livrée dans l'app, identique à `mac/ai/main.cpp`.
+    public var obsbotAISource: URL {
+        resources.appending(path: "obsbot-ai.cpp")
+    }
+
+    /// La sortie de clang++ quand la compilation d'obsbot-ai échoue.
+    public var obsbotAIBuildLog: URL {
+        logs.appending(path: "obsbot-ai-compilation.log")
     }
 
     /// Ce que le superviseur donne à ptzd.
@@ -48,13 +63,14 @@ public struct AppPaths: Equatable, Sendable {
 }
 
 extension SDKInstaller {
-    /// L'installateur de l'app : `sdk/` de l'utilisateur, vérifié par l'obsbot-ai du paquet.
+    /// L'installateur de l'app : `sdk/` de l'utilisateur, la source livrée dans l'app, les outils d'Apple.
     public static func system(paths: AppPaths) -> SDKInstaller {
-        let obsbotAI = paths.obsbotAI
-        return SDKInstaller(
+        SDKInstaller(
             sdkDirectory: paths.sdkDirectory,
-            verifier: obsbotAIVerifier(executableURL: obsbotAI),
-            executableAvailable: { FileManager.default.isExecutableFile(atPath: obsbotAI.path) }
+            sourceURL: paths.obsbotAISource,
+            toolchain: SystemToolchain.system(),
+            verifier: obsbotAIVerifier(),
+            buildLog: paths.obsbotAIBuildLog
         )
     }
 }
PATCH
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift
index 82a3290..cffd098 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift
@@ -38,6 +38,9 @@ public struct SDKCandidate: Equatable, Sendable {
     /// racine Apple (`anchor apple generic`) ; faux si la signature est intacte mais d'un certificat inconnu d'Apple
     /// (auto-signé, ad hoc). Ce n'est pas un contrôle Gatekeeper.
     public var appleAnchored: Bool?
+    /// Le dossier `include` du SDK, à côté de `macos/` : les en-têtes avec lesquels obsbot-ai est compilé
+    /// (spec distribution § 6.1). nil : le choix ne peut pas être installé.
+    public var includeDirectory: URL?
 
     public var isArm64: Bool {
         architectures.contains("arm64")
@@ -53,7 +56,8 @@ public struct SDKCandidate: Equatable, Sendable {
         temporaryDirectory: URL? = nil,
         otherCopies: [String] = [],
         signatureValid: Bool? = nil,
-        appleAnchored: Bool? = nil
+        appleAnchored: Bool? = nil,
+        includeDirectory: URL? = nil
     ) {
         self.path = path
         self.architectures = architectures
@@ -65,6 +69,7 @@ public struct SDKCandidate: Equatable, Sendable {
         self.otherCopies = otherCopies
         self.signatureValid = signatureValid
         self.appleAnchored = appleAnchored
+        self.includeDirectory = includeDirectory
     }
 }
 
@@ -77,6 +82,10 @@ public enum SDKRejection: Error, Equatable, Sendable {
     case extractionFailed(String)
     /// Le chemin de `libdev.dylib` mène hors du choix (un dossier intermédiaire est un lien symbolique).
     case outsideArchive
+    /// Ni `include/dev/devs.hpp` à côté de `macos/`, ni archive ou dossier : un `libdev.dylib` seul (spec distribution § 6.1).
+    case headersMissing
+    /// Les en-têtes contiennent un lien symbolique ou un fichier spécial, ou mènent hors du choix.
+    case headersNotPlain
 
     public var message: String {
         switch self {
@@ -92,14 +101,21 @@ public enum SDKRejection: Error, Equatable, Sendable {
             "L'archive n'a pas pu être décompressée : \(reason)"
         case .outsideArchive:
             "Ce choix contient un lien symbolique qui mène hors du dossier du SDK : il est refusé. Choisissez le SDK décompressé ou l'archive reçue."
+        case .headersMissing:
+            "Choisissez l'archive ou le dossier du SDK : ses en-têtes sont nécessaires."
+        case .headersNotPlain:
+            "Les en-têtes du SDK contiennent un lien symbolique ou un fichier spécial : ils sont refusés."
         }
     }
 }
 
-/// Examine un `.zip` du SDK, son dossier décompressé ou directement un `libdev.dylib`.
+/// Examine un `.zip` du SDK ou son dossier décompressé ; un `libdev.dylib` seul est refusé, faute d'en-têtes.
 public enum SDKInspector {
     /// Chemin du SDK pour Mac Apple Silicon dans l'archive d'OBSBOT.
     public static let libraryPath = "macos/arm64-release/libdev.dylib"
+    /// Les en-têtes, à la racine du SDK, et celui qu'obsbot-ai inclut.
+    public static let includePath = "include"
+    public static let mainHeaderPath = "dev/devs.hpp"
     static let quarantineAttribute = "com.apple.quarantine"
     static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"
 
@@ -118,13 +134,14 @@ public enum SDKInspector {
         }
         if isDirectory.boolValue {
             guard let located = try locate(in: url) else { throw .notFound }
-            return try describe(located.library, archive: nil, temporaryDirectory: nil, otherCopies: located.otherCopies)
+            let headers = try headers(of: located.root)
+            return try describe(located.library, archive: nil, temporaryDirectory: nil, otherCopies: located.otherCopies, includeDirectory: headers)
         }
         if url.pathExtension.lowercased() == "zip" {
             // Le zip lui-même doit être un fichier ordinaire : un lien vers une archive n'est pas décompressé.
             guard isRegularFile(url) else { throw .notRegularFile }
             let directory = try extract(url)
-            let located: (library: URL, otherCopies: [String])?
+            let located: (library: URL, root: URL, otherCopies: [String])?
             do {
                 located = try locate(in: directory)
             } catch {
@@ -136,13 +153,46 @@ public enum SDKInspector {
                 throw .notFound
             }
             do {
-                return try describe(located.library, archive: url, temporaryDirectory: directory, otherCopies: located.otherCopies)
+                let headers = try headers(of: located.root)
+                return try describe(located.library, archive: url, temporaryDirectory: directory, otherCopies: located.otherCopies, includeDirectory: headers)
             } catch {
                 try? FileManager.default.removeItem(at: directory)
                 throw error
             }
         }
-        return try describe(url, archive: nil, temporaryDirectory: nil, otherCopies: [])
+        // Un fichier seul (libdev.dylib) : sans en-têtes, obsbot-ai ne peut pas être compilé.
+        throw .headersMissing
+    }
+
+    /// Le dossier `include` à la racine du SDK : `include/dev/devs.hpp` doit être un fichier ordinaire, et tout le
+    /// dossier ne contenir que des dossiers et des fichiers ordinaires, sans quitter la racine (liens refusés).
+    static func headers(of root: URL) throws(SDKRejection) -> URL {
+        let include = root.appending(path: includePath)
+        guard existsWithoutFollowing(include) else { throw .headersMissing }
+        guard isDirectoryWithoutFollowing(include) else { throw .headersNotPlain }
+        let rootPath = root.resolvingSymlinksInPath().path + "/"
+        guard include.resolvingSymlinksInPath().path.hasPrefix(rootPath) else { throw .headersNotPlain }
+        let main = include.appending(path: mainHeaderPath)
+        guard existsWithoutFollowing(main) else { throw .headersMissing }
+        guard isPlainTree(include), isRegularFile(main) else { throw .headersNotPlain }
+        return include
+    }
+
+    /// Un dossier, sans suivre les liens.
+    static func isDirectoryWithoutFollowing(_ url: URL) -> Bool {
+        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
+    }
+
+    /// Le dossier ne contient, à toute profondeur, que des dossiers et des fichiers ordinaires (pas de lien ni de
+    /// fichier spécial), dossiers cachés compris.
+    static func isPlainTree(_ directory: URL) -> Bool {
+        guard isDirectoryWithoutFollowing(directory),
+              let enumerator = FileManager.default.enumerator(atPath: directory.path) else { return false }
+        for case let relative as String in enumerator {
+            let type = (try? FileManager.default.attributesOfItem(atPath: directory.appending(path: relative).path))?[.type] as? FileAttributeType
+            guard type == .typeRegular || type == .typeDirectory else { return false }
+        }
+        return true
     }
 
     /// Efface le dossier d'extraction d'une archive.
@@ -158,7 +208,7 @@ public enum SDKInspector {
     }
 
     /// Existe, sans suivre les liens (un lien cassé existe, et sera refusé comme tel).
-    private static func existsWithoutFollowing(_ url: URL) -> Bool {
+    static func existsWithoutFollowing(_ url: URL) -> Bool {
         (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
     }
 
@@ -166,7 +216,7 @@ public enum SDKInspector {
     /// choisi ou sous un de ses sous-dossiers directs (le dossier de tête de l'archive d'OBSBOT). Les autres
     /// `libdev.dylib` (jusqu'à 5 niveaux, sans dossiers cachés ni paquets) sont seulement listés.
     /// Refuse (`outsideArchive`) un chemin dont le dossier intermédiaire est un lien vers un autre emplacement.
-    static func locate(in directory: URL) throws(SDKRejection) -> (library: URL, otherCopies: [String])? {
+    static func locate(in directory: URL) throws(SDKRejection) -> (library: URL, root: URL, otherCopies: [String])? {
         let manager = FileManager.default
         let subdirectories = ((try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                  options: [.skipsHiddenFiles])) ?? [])
@@ -200,7 +250,7 @@ public enum SDKInspector {
                 }
             }
         }
-        return (library, others.sorted())
+        return (library, root, others.sorted())
     }
 
     /// Décompresse l'archive dans un dossier temporaire avec `ditto`. Au-delà de `timeout`, `ditto` est arrêté et
@@ -239,7 +289,13 @@ public enum SDKInspector {
         return directory
     }
 
-    private static func describe(_ library: URL, archive: URL?, temporaryDirectory: URL?, otherCopies: [String]) throws(SDKRejection) -> SDKCandidate {
+    private static func describe(
+        _ library: URL,
+        archive: URL?,
+        temporaryDirectory: URL?,
+        otherCopies: [String],
+        includeDirectory: URL
+    ) throws(SDKRejection) -> SDKCandidate {
         guard isRegularFile(library) else { throw .notRegularFile }
         guard let architectures = MachO.architectures(of: library) else { throw .notMachO }
         guard architectures.contains("arm64") else { throw .noArm64(architectures: architectures) }
@@ -264,7 +320,8 @@ public enum SDKInspector {
             temporaryDirectory: temporaryDirectory,
             otherCopies: otherCopies,
             signatureValid: signing.valid,
-            appleAnchored: signing.appleAnchored
+            appleAnchored: signing.appleAnchored,
+            includeDirectory: includeDirectory
         )
     }
 
PATCH
```

Remplacer tout le contenu de `mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift` par :

```swift
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
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/SDKWindowModel.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/SDKWindowModel.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/SDKWindowModel.swift
index a82e6ac..bf5f964 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/SDKWindowModel.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/SDKWindowModel.swift
@@ -16,6 +16,9 @@ public final class SDKWindowModel {
     }
 
     public private(set) var phase: Phase = .choosing
+    /// Les outils de développement d'Apple sont installés ; sinon la fenêtre propose de les installer d'abord
+    /// (spec distribution § 6.1).
+    public private(set) var toolsAvailable = true
     @ObservationIgnored private let installer: SDKInstaller
     @ObservationIgnored private let inspect: @Sendable (URL) throws(SDKRejection) -> SDKCandidate
     /// Change à chaque choix et à chaque fermeture : un examen dépassé est jeté avec son dossier d'extraction.
@@ -31,6 +34,18 @@ public final class SDKWindowModel {
         self.inspect = inspect
     }
 
+    /// Vérifie les outils de développement (à l'ouverture de la fenêtre, et sur « Vérifier à nouveau »).
+    public func checkTools() async {
+        let toolchain = installer.toolchain
+        toolsAvailable = await Task.detached { toolchain.isAvailable() }.value
+    }
+
+    /// « Installer les outils de développement… » : `xcode-select --install`, sur le clic de l'utilisateur seulement.
+    public func installTools() {
+        let toolchain = installer.toolchain
+        Task.detached { toolchain.requestInstall() }
+    }
+
     /// Examine le fichier ou le dossier choisi, hors du fil principal.
     public func choose(_ url: URL) async {
         discardCandidate()
@@ -66,6 +81,9 @@ public final class SDKWindowModel {
             phase = .installed
             onInstalled?()
         case let .failure(error):
+            if error == .toolsMissing {
+                toolsAvailable = false
+            }
             phase = .failed(error.message)
         }
     }
PATCH
```

Remplacer tout le contenu de `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift` par :

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

    /// L'état court, à droite de la ligne « SDK OBSBOT » ; l'explication va dessous (`sdkDetail`).
    public static func sdk(_ status: SDKStatus?) -> String {
        switch status {
        case .ready: "Prêt"
        case .absent: "Absent"
        case .quarantined: "En quarantaine"
        case .incompatible: "Incompatible"
        case .unloadable: "Ne se charge pas"
        case .sourceMissing: "obsbot-ai introuvable"
        case .toolsRequired: "Outils requis"
        case .incomplete: "À compléter"
        case .recompiling: "Recompilation…"
        case .compileFailed: "Compilation impossible"
        case nil: "Vérification…"
        }
    }

    /// La petite ligne sous « SDK OBSBOT », sur toute la largeur : ce que l'état veut dire et quoi faire ; nil si
    /// l'état se suffit. Quand les outils manquent et que le bouton les installe, elle le dit aussi.
    public static func sdkDetail(_ status: SDKStatus?, toolsAvailable: Bool = true) -> String? {
        var parts: [String] = []
        switch status {
        case .incomplete:
            parts.append(sdkIncompleteDetail)
        case let .toolsRequired(fallback):
            parts.append(sdkToolsDetail)
            if fallback {
                parts.append(sdkFallback)
            }
        case let .compileFailed(fallback):
            if fallback {
                parts.append(sdkFallback)
            }
            parts.append(compileLogHint)
        case .quarantined:
            parts.append(sdkQuarantinedDetail)
        case .incompatible:
            parts.append(sdkIncompatibleDetail)
        case .unloadable:
            parts.append(sdkUnloadableDetail)
        case .sourceMissing:
            parts.append(sdkSourceMissingDetail)
        case .ready, .absent, .recompiling, nil:
            break
        }
        if case .toolsRequired = status {
            // Déjà dit par sdkToolsDetail.
        } else if sdkActionInstallsTools(status, toolsAvailable: toolsAvailable) {
            parts.append(sdkToolsFirst)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public static let sdkFallback = "L'ancien obsbot-ai reste en service."
    public static let compileLogHint = "Le détail est dans le journal obsbot-ai-compilation.log."
    public static let sdkIncompleteDetail = "Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent."
    public static let sdkToolsDetail = "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai."
    public static let sdkQuarantinedDetail = "Le SDK ne se charge pas : réinstallez-le pour retirer la quarantaine de sa copie."
    public static let sdkIncompatibleDetail = "Ce SDK n'a pas de version pour Apple Silicon."
    public static let sdkUnloadableDetail = "obsbot-ai ne charge pas ce SDK : réinstallez-le."
    public static let sdkSourceMissingDetail = "La source d'obsbot-ai manque dans l'app : réinstallez PTZBot."
    public static let sdkToolsFirst = "Installez d'abord les outils de développement d'Apple."

    /// Le bouton de la ligne SDK : « Changer… » quand il est prêt (la fenêtre reste joignable), « Installer les
    /// outils de développement… » quand ils manquent (obsbot-ai ne pourrait pas être compilé), « Installer le SDK… »
    /// sinon ; aucun pendant la vérification ou la recompilation.
    public static func sdkAction(_ status: SDKStatus?, toolsAvailable: Bool = true) -> String? {
        if sdkActionInstallsTools(status, toolsAvailable: toolsAvailable) {
            return installTools
        }
        switch status {
        case nil, .recompiling, .sourceMissing: return nil
        case .ready: return "Changer…"
        case .toolsRequired: return installTools
        case .absent, .quarantined, .incompatible, .unloadable, .incomplete, .compileFailed: return "Installer le SDK…"
        }
    }

    /// Le bouton de la ligne SDK lance `xcode-select --install` plutôt que d'ouvrir la fenêtre « SDK OBSBOT » :
    /// les outils manquent et le SDK est à installer (ou obsbot-ai à compiler). Sur le clic de l'utilisateur seulement.
    public static func sdkActionInstallsTools(_ status: SDKStatus?, toolsAvailable: Bool = true) -> Bool {
        switch status {
        case .toolsRequired:
            return true
        case .absent, .quarantined, .incompatible, .unloadable, .incomplete, .compileFailed:
            return !toolsAvailable
        case nil, .ready, .recompiling, .sourceMissing:
            return false
        }
    }

    /// La fenêtre « SDK OBSBOT » quand les outils manquent : elle propose de les installer avant de choisir le SDK.
    public static let sdkToolsExplanation = "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai avec le SDK. Installez-les, puis vérifiez à nouveau."
    public static let checkToolsAgain = "Vérifier à nouveau"

    public static let installTools = "Installer les outils de développement…"

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

    /// Le suivi IA a besoin du SDK de l'app et d'un obsbot-ai qui le charge ; l'ancienne installation a le sien
    /// dans `lib/`.
    public static func aiNeedsSDK(_ status: SDKStatus?, legacy: Bool) -> Bool {
        !legacy && status?.aiUsable != true
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

    /// La ligne « Signature » : le signataire (et l'équipe) seulement si la signature est intacte et d'un
    /// certificat reconnu par Apple. Ces contrôles ne remplacent pas Gatekeeper.
    static func signatureText(_ candidate: SDKCandidate) -> String {
        switch candidate.signatureValid {
        case false:
            return "Signature invalide"
        case true:
            guard candidate.appleAnchored == true else { return "Signé, certificat non reconnu par Apple" }
            guard let signer = candidate.signer else { return "Signé" }
            return candidate.team.map { "\(signer) (équipe \($0))" } ?? signer
        case nil:
            return "non signé"
        }
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
        var provenance = origin.isEmpty ? "inconnue" : origin.joined(separator: " · ")
        if !origin.isEmpty, candidate.origin?.fromInsideArchive == true {
            provenance += " (indiquée dans l'archive)"
        }
        let signature = signatureText(candidate)
        var checks = [
            SDKCheck(title: "Architecture", value: architecture),
            SDKCheck(title: "Signature", value: signature),
            SDKCheck(title: "Provenance", value: provenance),
            SDKCheck(title: "Quarantaine", value: candidate.quarantined ? "oui" : "non"),
        ]
        if !candidate.otherCopies.isEmpty {
            checks.append(SDKCheck(title: "Autres copies ignorées", value: candidate.otherCopies.joined(separator: ", ")))
        }
        return checks
    }
}
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Toolchain.swift` :

```swift
import Foundation

/// Échec d'une compilation d'obsbot-ai.
public enum ToolchainError: Error, Equatable, Sendable {
    /// `xcode-select -p` échoue : les outils de développement d'Apple ne sont pas installés.
    case unavailable
    /// clang++ a échoué (ou dépassé son délai) ; sa sortie, pour le journal.
    case compileFailed(output: String)
}

/// Les outils de développement d'Apple (spec distribution § 6.1), derrière un protocole pour les tests.
/// Bloquant (processus lancés et attendus) : à appeler hors du fil principal.
public protocol Toolchain: Sendable {
    /// `xcode-select -p` réussit.
    func isAvailable() -> Bool
    /// `clang++ -std=c++17 -O2 -I <include> -L <bibliothèque> -ldev -o <sortie> <source>`. Le binaire n'a pas de
    /// chemin de recherche intégré : ptzd lui donne `DYLD_LIBRARY_PATH`. L'éditeur de liens le signe en local.
    func compile(source: URL, includeDirectory: URL, libraryDirectory: URL, output: URL) throws(ToolchainError)
    /// Lance `xcode-select --install` sans l'attendre : l'utilisateur accepte lui-même dans la fenêtre d'Apple.
    func requestInstall()
}

/// Les vrais outils : `xcode-select` et `xcrun clang++`.
public struct SystemToolchain: Toolchain {
    public let xcodeSelect: URL
    public let xcrun: URL
    /// Délai maximal d'une compilation ; au-delà, clang++ est arrêté et la compilation échoue.
    public let timeout: TimeInterval

    public init(xcodeSelect: URL, xcrun: URL, timeout: TimeInterval) {
        self.xcodeSelect = xcodeSelect
        self.xcrun = xcrun
        self.timeout = timeout
    }

    /// Les outils du système, à leur place habituelle.
    public static func system() -> SystemToolchain {
        SystemToolchain(
            xcodeSelect: URL(fileURLWithPath: "/usr/bin/xcode-select"),
            xcrun: URL(fileURLWithPath: "/usr/bin/xcrun"),
            timeout: 300
        )
    }

    public func isAvailable() -> Bool {
        let result = ChildProcess.run(xcodeSelect, arguments: ["-p"], timeout: 10)
        return result?.exited == true && result?.status == 0
    }

    public func compile(source: URL, includeDirectory: URL, libraryDirectory: URL, output: URL) throws(ToolchainError) {
        // Sans outils, xcrun ouvrirait de lui-même la fenêtre d'installation d'Apple : la vérification passe avant.
        guard isAvailable() else { throw .unavailable }
        let arguments = [
            "clang++", "-std=c++17", "-O2", "-arch", "arm64",
            "-I", includeDirectory.path,
            "-L", libraryDirectory.path, "-ldev",
            "-o", output.path, source.path,
        ]
        guard let result = ChildProcess.run(xcrun, arguments: arguments, timeout: timeout, captureOutput: true) else {
            throw .compileFailed(output: "clang++ n'a pas pu être lancé.")
        }
        guard result.exited, result.status == 0 else {
            let reason = result.timedOut ? "clang++ n'a pas fini dans le délai imparti.\n" : ""
            throw .compileFailed(output: reason + result.output)
        }
    }

    public func requestInstall() {
        let process = Process()
        process.executableURL = xcodeSelect
        process.arguments = ["--install"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        DispatchQueue.global().async {
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
        }
    }
}

/// Un processus lancé et attendu, avec un délai : SIGTERM au-delà, puis SIGKILL deux secondes plus tard. Il est
/// lancé dans son propre groupe de processus, et les signaux visent tout le groupe : clang++ lance lui-même
/// `clang -cc1` et `ld`, qui ne survivent pas à un délai dépassé.
/// L'entrée standard est vide ; la sortie et les erreurs sont jetées, ou recueillies dans un fichier temporaire.
enum ChildProcess {
    struct Result {
        /// Sorti normalement (pas tué par un signal).
        var exited: Bool
        var status: Int32
        var timedOut: Bool
        /// Sortie et erreurs mêlées, si demandées.
        var output: String
    }

    /// Délai laissé au groupe pour sortir après SIGTERM, avant SIGKILL.
    static let terminationGrace: TimeInterval = 2

    /// nil si le processus n'a pas pu être lancé.
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        captureOutput: Bool = false
    ) -> Result? {
        let outputPath = captureOutput
            ? FileManager.default.temporaryDirectory.appending(path: "ptzbot-sortie-\(UUID().uuidString)").path
            : "/dev/null"
        defer {
            if captureOutput {
                try? FileManager.default.removeItem(atPath: outputPath)
            }
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, outputPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Son propre groupe (pgid = pid) ; les descripteurs de l'app ne passent pas au fils.
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp) == 0 else { return nil }

        // L'attente se fait dans un fil à part, pour pouvoir la borner.
        let done = DispatchSemaphore(value: 0)
        let waited = WaitStatus()
        let child = pid
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0, errno == EINTR {}
            waited.set(status)
            done.signal()
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // C'est le groupe que nous venons de créer : clang++ et ses enfants.
            Darwin.kill(-pid, SIGTERM)
            if done.wait(timeout: .now() + terminationGrace) == .timedOut {
                Darwin.kill(-pid, SIGKILL)
                done.wait()
            }
        }
        // Les restes du groupe (un enfant qui ignorerait SIGTERM) ne survivent pas au délai.
        if timedOut {
            Darwin.kill(-pid, SIGKILL)
        }
        let status = waited.value
        let exitedNormally = (status & 0x7f) == 0
        let output = captureOutput
            ? (FileManager.default.contents(atPath: outputPath).map { String(decoding: $0, as: UTF8.self) } ?? "")
            : ""
        return Result(
            exited: exitedNormally && !timedOut,
            status: exitedNormally ? (status >> 8) & 0xff : status & 0x7f,
            timedOut: timedOut,
            output: output
        )
    }
}

/// Le statut rendu par `waitpid`, transmis du fil d'attente.
private final class WaitStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32 = 0

    var value: Int32 {
        lock.withLock { status }
    }

    func set(_ value: Int32) {
        lock.withLock { status = value }
    }
}
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' | grep -v appintents && ./check-bundle.sh)
```

Attendu : tout passe (PTZBotKit : 145 tests, « ** BUILD SUCCEEDED ** » pour l'app, puis les trois lignes « ok : » de `check-bundle.sh`), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add mac/app/PTZBot/PanelView.swift \
    mac/app/PTZBot/SDKView.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/SDKWindowModel.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/Toolchain.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKInstallerTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|8\.8\.8\.8|256\.0\.0\.1|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
B2 : obsbot-ai compile sur le Mac de l'utilisateur

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés plus haut sont déjà indexés par `git rm`.

### Tâche 2 : PTZBotKit en français et en anglais, erreurs de `ptzd` par code, langue choisie dans l'app

**But :** Tous les textes de PTZBotKit passent dans un catalogue de chaînes : le français est la source, l'anglais est traduit. La langue est choisie par l'app : automatique, Français ou English, retenue et appliquée sans relance, et recopiée dans `AppleLanguages` pour Sparkle. Les erreurs de `ptzd` sont affichées d'après leur code. Les motifs du suivi IA sont partagés par `AIFailureText` (spec B2 § 7 et § 12).

**Fichiers :**
- Modifier : `Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift`
- Modifier : `Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift`
- Modifier : `mac/app/PTZBotKit/Package.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/AppLanguage.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/ErrorTexts.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/Labels.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/LegacyAgent.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Localization.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/LoginItem.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceSupervisor.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/SettingsStore.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift`
- Créer : `mac/app/PTZBotKit/Tests/PTZBotKitTests/AppLanguageTests.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/ConfigAndLoginTests.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/IconAndLabelsTests.swift`
- Créer : `mac/app/PTZBotKit/Tests/PTZBotKitTests/LanguageTrait.swift`
- Créer : `mac/app/PTZBotKit/Tests/PTZBotKitTests/LocalizationTests.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/MigrationTests.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/QRImageTests.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKInstallerTests.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceSupervisorTests.swift`
- Modifier : `mac/ptzd/Sources/PTZCore/AIRunner.swift`
- Modifier : `mac/ptzd/Sources/PTZCore/PTZController.swift`

**Interfaces :**
- Produit :
  - NacelleProtocol : `AIFailureText` (`prefix`, `suffix`, `cameraNotFound`, `sdkError`, `timeout`, `launchFailed`, `unexpectedExitPrefix`, `message(motive:)`, `motive(in:)`), utilisé par `ptzd` (`AIRunner`, `PTZController`) ;
  - PTZBotKit :
    - `Localization` (`text(_:)`, `preferredLanguage(_:)`, `setAppLanguage(_:)`, `languages`) ;
    - `AppLanguage` (`automatic`, `french`, `english`, `resolved(systemPreferences:)`) ;
    - `AppLanguageModel(settings:systemPreferences:apply:)`, avec `select(_:)` et la fabrique `system()` ;
    - `ErrorTexts.text(for:message:)` ;
    - `SettingsStore` reçoit `string(forKey:)`, `set(_ String?:)` et `set(_ [String]?:)`.
- `Package.swift` de PTZBotKit : `defaultLocalization: "fr"` et la ressource `Resources/Localizable.xcstrings`.
- Les tests fixent la langue eux-mêmes (`LanguageTrait`) : ils ne dépendent pas de la langue du Mac.

- [ ] **Étape 1 : Écrire les tests**

Modifier `Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift b/Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift
index e7e5740..3dd1d89 100644
--- a/Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift
+++ b/Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift
@@ -176,3 +176,17 @@ struct ServerMessageTests {
         }
     }
 }
+
+@Suite("Message d'échec du suivi IA")
+struct AIFailureTextTests {
+    @Test("Composé par ptzd, relu par l'app : le motif revient tel quel ; un autre message n'en a pas")
+    func roundTrip() {
+        for motive in [AIFailureText.cameraNotFound, AIFailureText.sdkError, AIFailureText.timeout,
+                       AIFailureText.launchFailed, AIFailureText.unexpectedExitPrefix + "134", "motif nouveau"] {
+            #expect(AIFailureText.motive(in: AIFailureText.message(motive: motive)) == motive)
+        }
+        #expect(AIFailureText.message(motive: "délai dépassé") == "Suivi IA non modifié (délai dépassé).")
+        #expect(AIFailureText.motive(in: "La caméra a refusé la commande (x).") == nil)
+        #expect(AIFailureText.motive(in: "Suivi IA non modifié (") == nil)
+    }
+}
PATCH
```

Modifier `mac/app/PTZBotKit/Package.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Package.swift b/mac/app/PTZBotKit/Package.swift
index a310b34..28c0cc0 100644
--- a/mac/app/PTZBotKit/Package.swift
+++ b/mac/app/PTZBotKit/Package.swift
@@ -4,6 +4,8 @@ import PackageDescription
 /// La logique de PTZBot pour Mac, sans interface : testée par `swift test`, utilisée par l'app (mac/app).
 let package = Package(
     name: "PTZBotKit",
+    // Textes en français (langue source, au vouvoiement) et en anglais : Resources/Localizable.xcstrings.
+    defaultLocalization: "fr",
     platforms: [.macOS(.v15)],
     products: [
         .library(name: "PTZBotKit", targets: ["PTZBotKit"]),
@@ -12,7 +14,11 @@ let package = Package(
         .package(path: "../../../Packages/NacelleProtocol"),
     ],
     targets: [
-        .target(name: "PTZBotKit", dependencies: [.product(name: "NacelleProtocol", package: "NacelleProtocol")]),
+        .target(
+            name: "PTZBotKit",
+            dependencies: [.product(name: "NacelleProtocol", package: "NacelleProtocol")],
+            resources: [.process("Resources")]
+        ),
         .testTarget(name: "PTZBotKitTests", dependencies: ["PTZBotKit", .product(name: "NacelleProtocol", package: "NacelleProtocol")]),
     ]
 )
PATCH
```

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift
index c4526ab..a53544f 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift
@@ -4,7 +4,7 @@ import Testing
 @testable import PTZBotKit
 
 @MainActor
-@Suite("Lancement et arrêt de l'app")
+@Suite("Lancement et arrêt de l'app", .french)
 struct AppControllerTests {
     let root: URL
     let paths: AppPaths
@@ -401,7 +401,7 @@ final class Counter {
 }
 
 @MainActor
-@Suite("Fenêtre « SDK OBSBOT »")
+@Suite("Fenêtre « SDK OBSBOT »", .french)
 struct SDKWindowModelTests {
     static func installer(_ directory: URL, loads: Bool) -> SDKInstaller {
         let source = directory.appending(path: "obsbot-ai.cpp")
@@ -519,7 +519,7 @@ struct SDKWindowModelTests {
     }
 }
 
-@Suite("Textes du service et du SDK")
+@Suite("Textes du service et du SDK", .french)
 struct ServiceLabelsTests {
     @Test("État du service : supervision, puis connexion de confiance ; ancienne installation")
     func service() {
PATCH
```

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/AppLanguageTests.swift` :

```swift
import Foundation
import Testing
@testable import PTZBotKit

/// Langues appliquées, retenues pour le test.
@MainActor
final class AppliedLanguages {
    private(set) var values: [String] = []

    func add(_ language: String) {
        values.append(language)
    }
}

@MainActor
@Suite("Langue de l'app", .french)
struct AppLanguageTests {
    @Test("Automatique : la règle du système (français sur un Mac en français, anglais sinon) ; les deux autres forcent")
    func resolution() {
        #expect(AppLanguage.automatic.resolved(systemPreferences: ["fr-FR"]) == "fr")
        #expect(AppLanguage.automatic.resolved(systemPreferences: ["de-DE"]) == "en")
        #expect(AppLanguage.automatic.resolved(systemPreferences: ["de-DE", "fr-FR"]) == "fr")
        #expect(AppLanguage.french.resolved(systemPreferences: ["en-US"]) == "fr")
        #expect(AppLanguage.english.resolved(systemPreferences: ["fr-FR"]) == "en")
        #expect(AppLanguage.automatic.appleLanguages == nil)
        #expect(AppLanguage.french.appleLanguages == ["fr"])
        #expect(AppLanguage.english.appleLanguages == ["en"])
    }

    @Test("Choix retenu (appLanguage) et recopié dans AppleLanguages pour Sparkle ; automatique retire la clé")
    func persistence() {
        let settings = FakeSettings()
        let applied = AppliedLanguages()
        let model = AppLanguageModel(settings: settings, systemPreferences: ["fr-FR"], apply: { applied.add($0) })
        #expect(model.selection == .automatic)
        #expect(model.language == "fr")
        model.select(.english)
        #expect(settings.strings["appLanguage"] == "english")
        #expect(settings.arrays["AppleLanguages"] == ["en"])
        #expect(model.language == "en")
        model.select(.french)
        #expect(settings.arrays["AppleLanguages"] == ["fr"])
        model.select(.automatic)
        #expect(settings.strings["appLanguage"] == "automatic")
        #expect(settings.arrays["AppleLanguages"] == nil)
        #expect(applied.values == ["fr", "en", "fr", "fr"])
        // Au lancement suivant, le choix est relu.
        settings.strings["appLanguage"] = "english"
        let relaunched = AppLanguageModel(settings: settings, systemPreferences: ["fr-FR"], apply: { applied.add($0) })
        #expect(relaunched.selection == .english)
        #expect(relaunched.language == "en")
        // Valeur inconnue : automatique.
        settings.strings["appLanguage"] = "klingon"
        #expect(AppLanguageModel(settings: settings, systemPreferences: ["de"], apply: { _ in }).selection == .automatic)
    }

    @Test("Les textes de PTZBotKit suivent la langue de l'app, hors langue imposée à la tâche")
    func appliedToTexts() {
        Localization.$languageOverride.withValue(nil) {
            let before = Localization.language
            defer { Localization.setAppLanguage(before) }
            Localization.setAppLanguage("en")
            #expect(Labels.sdk(.ready) == "Ready")
            Localization.setAppLanguage("fr")
            #expect(Labels.sdk(.ready) == "Prêt")
            Localization.setAppLanguage("de")
            #expect(Localization.language == "en")
        }
    }
}
```

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/ConfigAndLoginTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/ConfigAndLoginTests.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/ConfigAndLoginTests.swift
index 926c5f8..271436b 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/ConfigAndLoginTests.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/ConfigAndLoginTests.swift
@@ -3,7 +3,7 @@ import ServiceManagement
 import Testing
 @testable import PTZBotKit
 
-@Suite("Port de ptzd")
+@Suite("Port de ptzd", .french)
 struct PTZDConfigTests {
     private func load(_ json: String?) throws -> PTZDConfig {
         let url = FileManager.default.temporaryDirectory.appending(path: "ptzbot-\(UUID().uuidString).json")
@@ -29,7 +29,7 @@ struct PTZDConfigTests {
 }
 
 @MainActor
-@Suite("Ouverture à la connexion")
+@Suite("Ouverture à la connexion", .french)
 struct LoginItemModelTests {
     struct Failure: LocalizedError {
         var errorDescription: String? { "refusé" }
PATCH
```

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift
index d4dafa1..1c8e7e6 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift
@@ -101,6 +101,8 @@ final class FakeLoginItem: LoginItemService {
 @MainActor
 final class FakeSettings: SettingsStore {
     var values: [String: Bool] = [:]
+    var strings: [String: String] = [:]
+    var arrays: [String: [String]] = [:]
 
     func bool(forKey key: String) -> Bool? {
         values[key]
@@ -109,6 +111,18 @@ final class FakeSettings: SettingsStore {
     func set(_ value: Bool, forKey key: String) {
         values[key] = value
     }
+
+    func string(forKey key: String) -> String? {
+        strings[key]
+    }
+
+    func set(_ value: String?, forKey key: String) {
+        strings[key] = value
+    }
+
+    func set(_ value: [String]?, forKey key: String) {
+        arrays[key] = value
+    }
 }
 
 /// Processus simulé : le test décide de sa fin.
PATCH
```

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/IconAndLabelsTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/IconAndLabelsTests.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/IconAndLabelsTests.swift
index 8cbf07c..d41fa15 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/IconAndLabelsTests.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/IconAndLabelsTests.swift
@@ -4,7 +4,7 @@ import NacelleProtocol
 import Testing
 @testable import PTZBotKit
 
-@Suite("Icône et libellés")
+@Suite("Icône et libellés", .french)
 struct IconAndLabelsTests {
     @Test("Icône : image modèle de 18 points de haut, presque carrée, décrite")
     func icon() throws {
PATCH
```

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/LanguageTrait.swift` :

```swift
import Testing
@testable import PTZBotKit

/// Fixe la langue des textes de PTZBotKit pour tout un test ou toute une suite : les assertions ne dépendent pas
/// de la langue du Mac qui lance les tests.
struct LanguageTrait: TestTrait, SuiteTrait, TestScoping {
    let language: String

    var isRecursive: Bool {
        true
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await Localization.$languageOverride.withValue(language) {
            try await function()
        }
    }
}

extension Trait where Self == LanguageTrait {
    /// Les textes en français, langue source.
    static var french: Self {
        LanguageTrait(language: "fr")
    }

    /// Les textes en anglais.
    static var english: Self {
        LanguageTrait(language: "en")
    }
}
```

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/LocalizationTests.swift` :

```swift
import Foundation
import NacelleProtocol
import Testing
@testable import PTZBotKit

/// Les textes de PTZBotKit en français et en anglais (spec distribution § 7).
@Suite("Textes bilingues", .french)
struct LocalizationTests {
    /// Le texte dans une langue donnée.
    private func inLanguage<T>(_ language: String, _ body: () -> T) -> T {
        Localization.$languageOverride.withValue(language, operation: body)
    }

    /// Le catalogue source, lu dans les sources du paquet.
    private func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/PTZBotKit/Resources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(object?["sourceLanguage"] as? String == "fr")
        return try #require(object?["strings"] as? [String: Any])
    }

    @Test("Catalogue : chaque clé a sa traduction anglaise, non vide et marquée traduite")
    func everyKeyTranslated() throws {
        let strings = try catalog()
        #expect(strings.count > 100)
        for (key, value) in strings {
            let entry = value as? [String: Any]
            let english = (entry?["localizations"] as? [String: Any])?["en"] as? [String: Any]
            let unit = english?["stringUnit"] as? [String: Any]
            #expect(unit?["state"] as? String == "translated", "\(key)")
            #expect((unit?["value"] as? String)?.isEmpty == false, "\(key)")
        }
    }

    @Test("Catalogue compilé : chaque clé se lit en anglais dans en.lproj et en français dans fr.lproj")
    func compiledCatalog() throws {
        let strings = try catalog()
        let english = Localization.bundle(for: "en")
        let french = Localization.bundle(for: "fr")
        #expect(english.bundlePath.hasSuffix("en.lproj"))
        #expect(french.bundlePath.hasSuffix("fr.lproj"))
        for (key, value) in strings {
            let localizations = (value as? [String: Any])?["localizations"] as? [String: Any]
            let expected = ((localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            #expect(english.localizedString(forKey: key, value: "∅", table: nil) == expected, "\(key)")
            #expect(french.localizedString(forKey: key, value: "∅", table: nil) == key, "\(key)")
        }
    }

    @Test("Langue : le français si l'utilisateur le préfère, l'anglais pour toute autre langue")
    func preferredLanguage() {
        #expect(Localization.preferredLanguage(["fr-FR"]) == "fr")
        #expect(Localization.preferredLanguage(["fr-CA", "en"]) == "fr")
        #expect(Localization.preferredLanguage(["de-DE", "fr-FR"]) == "fr")
        #expect(Localization.preferredLanguage(["de-DE"]) == "en")
        #expect(Localization.preferredLanguage(["en-GB", "fr-FR"]) == "en")
        #expect(Localization.preferredLanguage([]) == "en")
    }

    @Test("Erreurs de ptzd : chaque code a un texte en français et en anglais, différents")
    func everyErrorCode() {
        #expect(ErrorCode.allCases.count == 11)
        for code in ErrorCode.allCases {
            let french = inLanguage("fr") { ErrorTexts.text(for: code, message: "message de ptzd") }
            let english = inLanguage("en") { ErrorTexts.text(for: code, message: "message de ptzd") }
            #expect(!french.isEmpty, "\(code)")
            #expect(!english.isEmpty, "\(code)")
            #expect(french != english, "\(code)")
            #expect(french != "message de ptzd", "le texte de ptzd n'est jamais repris : \(code)")
        }
        #expect(inLanguage("fr") { ErrorTexts.text(for: .cameraAbsent, message: "") } == "Caméra débranchée.")
        #expect(inLanguage("en") { ErrorTexts.text(for: .cameraAbsent, message: "") } == "Camera unplugged.")
        #expect(inLanguage("en") { ErrorTexts.text(for: .pairingClosed, message: "") } == "QR code expired or already used: start pairing again on the Mac.")
    }

    @Test("uvcFailed du suivi IA : le motif connu de ptzd est traduit ; sinon le refus de la caméra")
    func aiMotives() {
        let cases: [(String, String, String)] = [
            ("Suivi IA non modifié (caméra introuvable).", "Suivi IA non modifié : caméra introuvable.", "AI tracking unchanged: camera not found."),
            ("Suivi IA non modifié (erreur du SDK OBSBOT).", "Suivi IA non modifié : erreur du SDK OBSBOT.", "AI tracking unchanged: OBSBOT SDK error."),
            ("Suivi IA non modifié (délai dépassé).", "Suivi IA non modifié : délai dépassé.", "AI tracking unchanged: timed out."),
            ("Suivi IA non modifié (l'utilitaire n'a pas pu être lancé).", "Suivi IA non modifié : obsbot-ai n'a pas pu être lancé.", "AI tracking unchanged: obsbot-ai could not be started."),
            ("Suivi IA non modifié (l'utilitaire s'est arrêté avec le code 134).", "Suivi IA non modifié : obsbot-ai s'est arrêté avec le code 134.", "AI tracking unchanged: obsbot-ai stopped with code 134."),
            ("Suivi IA non modifié (motif nouveau).", "Suivi IA non modifié.", "AI tracking unchanged."),
            ("La caméra a refusé la commande (timeout).", "La caméra a refusé la commande.", "The camera refused the command."),
        ]
        for (message, french, english) in cases {
            #expect(inLanguage("fr") { ErrorTexts.text(for: .uvcFailed, message: message) } == french)
            #expect(inLanguage("en") { ErrorTexts.text(for: .uvcFailed, message: message) } == english)
        }
    }

    @Test("Motifs du suivi IA : ceux que ptzd compose (AIFailureText, partagé), traduits ; jamais le texte de ptzd")
    func aiMotivesShared() {
        let motives = [AIFailureText.cameraNotFound, AIFailureText.sdkError, AIFailureText.timeout,
                       AIFailureText.launchFailed, AIFailureText.unexpectedExitPrefix + "7"]
        let french = motives.map { motive in inLanguage("fr") { ErrorTexts.text(for: .uvcFailed, message: AIFailureText.message(motive: motive)) } }
        #expect(french == [
            "Suivi IA non modifié : caméra introuvable.",
            "Suivi IA non modifié : erreur du SDK OBSBOT.",
            "Suivi IA non modifié : délai dépassé.",
            "Suivi IA non modifié : obsbot-ai n'a pas pu être lancé.",
            "Suivi IA non modifié : obsbot-ai s'est arrêté avec le code 7.",
        ])
        let english = motives.map { motive in inLanguage("en") { ErrorTexts.text(for: .uvcFailed, message: AIFailureText.message(motive: motive)) } }
        #expect(Set(english).count == motives.count)
        #expect(english.allSatisfy { $0.hasPrefix("AI tracking unchanged: ") })
    }

    /// Les clés de `Localization.text("…")` dans les sources de PTZBotKit, chaque interpolation devenue `%lld`
    /// (pour `count`) ou `%@`.
    static func sourceKeys() throws -> Set<String> {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/PTZBotKit")
        var keys = Set<String>()
        for name in try FileManager.default.contentsOfDirectory(atPath: sources.path) where name.hasSuffix(".swift") {
            let text = Array(try String(contentsOf: sources.appending(path: name), encoding: .utf8))
            let marker = Array("Localization.text(\"")
            var index = 0
            while index + marker.count <= text.count {
                guard Array(text[index..<index + marker.count]) == marker else {
                    index += 1
                    continue
                }
                var position = index + marker.count
                var key = ""
                while text[position] != "\"" {
                    if text[position] == "\\", text[position + 1] == "(" {
                        // Interpolation : jusqu'à la parenthèse fermante, chaînes imbriquées comprises.
                        var depth = 1
                        var cursor = position + 2
                        var expression = ""
                        while depth > 0 {
                            let character = text[cursor]
                            if character == "\"" {
                                let end = text[(cursor + 1)...].firstIndex(of: "\"")!
                                expression += String(text[cursor...end])
                                cursor = end + 1
                                continue
                            }
                            if character == "(" { depth += 1 }
                            if character == ")" { depth -= 1 }
                            if depth > 0 { expression.append(character) }
                            cursor += 1
                        }
                        key += expression == "count" ? "%lld" : "%@"
                        position = cursor
                    } else if text[position] == "\\" {
                        key.append(text[position + 1] == "n" ? "\n" : text[position + 1])
                        position += 2
                    } else {
                        key.append(text[position])
                        position += 1
                    }
                }
                keys.insert(key)
                index = position + 1
            }
        }
        return keys
    }

    @Test("Chaque texte de PTZBotKit (Localization.text) est dans le catalogue, et le catalogue n'a pas de clé inutile")
    func everySourceKeyInCatalog() throws {
        let keys = try Self.sourceKeys()
        let catalogKeys = Set(try catalog().keys)
        #expect(keys.count > 100)
        #expect(keys.subtracting(catalogKeys).sorted() == [])
        #expect(catalogKeys.subtracting(keys).sorted() == [])
    }

    @Test("Libellés en anglais : états, sections, interpolations, raisons du superviseur, messages du SDK")
    func englishLabels() {
        inLanguage("en") {
            #expect(Labels.sdk(.ready) == "Ready")
            #expect(Labels.sdk(.incomplete) == "Incomplete")
            #expect(Labels.sdk(.toolsRequired(fallback: false)) == "Tools required")
            #expect(Labels.sdk(.compileFailed(fallback: false)) == "Compile failed")
            #expect(Labels.sdk(.sourceMissing) == "obsbot-ai not found")
            #expect(Labels.sdkDetail(.incomplete, toolsAvailable: false) == "Reinstall the SDK from its archive or folder: its headers are missing. Install Apple's developer tools first.")
            #expect(Labels.sdkDetail(.toolsRequired(fallback: true)) == "Apple's developer tools are needed to compile obsbot-ai. The previous obsbot-ai stays in use.")
            #expect(Labels.sdkDetail(.quarantined) == "The SDK does not load: reinstall it to remove the quarantine from its copy.")
            #expect(Labels.sdk(.recompiling) == "Recompiling…")
            #expect(Labels.sdkAction(.toolsRequired(fallback: false)) == "Install Developer Tools…")
            #expect(Labels.service(.restarting(count: 3), connection: .unreachable, legacy: false) == "Restarted after an unexpected stop (3)")
            #expect(Labels.iPhoneSection(count: 2) == "Connected iPhones · 2")
            #expect(Labels.cameraSection(.connected) == "Camera · plugged in")
            #expect(Labels.route(.mac) == "This Mac")
            #expect(Labels.sdkDetail(.compileFailed(fallback: true)) == "The previous obsbot-ai stays in use. Details are in the obsbot-ai-compilation.log log.")
            #expect(ServiceSupervisor.busyReason(port: 1985) == "Port 1985 is already in use: another ptzd may still be running")
            #expect(ServiceSupervisor.crashLoopReason == "ptzd keeps stopping: open the log")
            #expect(SDKRejection.noArm64(architectures: ["x86_64"]).message == "This SDK has no Apple silicon version (x86_64).")
            #expect(SDKInstallError.copyFailed("x").message == "The SDK could not be copied: x")
            #expect(LegacyMigrationError.stillLoaded.message == "The previous installation did not stop in time.")
            let candidate = SDKCandidate(
                path: URL(fileURLWithPath: "/x/libdev.dylib"),
                architectures: ["x86_64"],
                signer: "Developer ID Application: Exemple",
                team: "ABCDE12345",
                origin: SDKOrigin(url: "https://example.com/libdev.zip", date: nil, fromInsideArchive: true),
                signatureValid: true,
                appleAnchored: true
            )
            #expect(Labels.sdkChecks(candidate).map(\.title) == ["Architecture", "Signature", "Origin", "Quarantine"])
            #expect(Labels.sdkChecks(candidate).map(\.value) == [
                "Apple Silicon: ✗ (x86_64)",
                "Developer ID Application: Exemple (team ABCDE12345)",
                "https://example.com/libdev.zip (stated in the archive)",
                "no",
            ])
        }
    }

    @Test("Libellés : français et anglais diffèrent pour chaque texte du panneau qui se traduit")
    func everyLabelTranslated() {
        let labels: [() -> String] = [
            { Labels.service(.connecting) }, { Labels.service(.active) }, { Labels.service(.unreachable) },
            { Labels.route(.localNetwork) }, { Labels.route(.mac) },
            { Labels.service(.stopped, connection: .unreachable, legacy: true) },
            { Labels.service(.stopped, connection: .unreachable, legacy: false) },
            { Labels.sdk(nil) }, { Labels.sdk(.ready) }, { Labels.sdk(.absent) }, { Labels.sdk(.quarantined) },
            { Labels.sdk(.unloadable) }, { Labels.sdk(.sourceMissing) }, { Labels.sdk(.compileFailed(fallback: false)) },
            { Labels.sdk(.incomplete) }, { Labels.sdk(.toolsRequired(fallback: false)) },
            { Labels.sdkDetail(.incomplete) ?? "" }, { Labels.sdkDetail(.unloadable) ?? "" },
            { Labels.sdkDetail(.sourceMissing) ?? "" }, { Labels.sdkDetail(.absent, toolsAvailable: false) ?? "" },
            { Labels.sdkAction(.ready) ?? "" }, { Labels.sdkAction(.absent) ?? "" },
            { Labels.replaceLegacy }, { Labels.noIPhone }, { Labels.cameraSection(nil) },
            { Labels.aiNote(.unknown, needsSDK: false) ?? "" }, { Labels.sdkRequired }, { Labels.tailscaleMissing },
            { Labels.localNetworkDenied }, { Labels.migrationMessage }, { Labels.migrationReplace },
            { Labels.migrationLater }, { Labels.sdkExplanation }, { Labels.sdkConfirmation },
            { ServiceSupervisor.unkillableReason }, { ServiceSupervisor.configReason }, { ServiceSupervisor.usageReason },
            { SDKInstallError.toolsMissing.message }, { SDKInstallError.compileFailed.message }, { SDKRejection.headersMissing.message },
        ]
        for label in labels {
            let french = inLanguage("fr", label)
            let english = inLanguage("en", label)
            #expect(french != english, "\(french)")
        }
    }
}
```

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/MigrationTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/MigrationTests.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/MigrationTests.swift
index 3d030af..54c49b0 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/MigrationTests.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/MigrationTests.swift
@@ -76,7 +76,7 @@ final class FakeSleeper: Sendable {
     let slept = Mutex<TimeInterval>(0)
 }
 
-@Suite("Migration depuis l'ancienne installation")
+@Suite("Migration depuis l'ancienne installation", .french)
 struct LegacyAgentTests {
     let root: URL
     let agents: URL
@@ -295,7 +295,7 @@ struct FakeInterfaces: InterfaceAddressProvider {
     }
 }
 
-@Suite("config.json au premier lancement")
+@Suite("config.json au premier lancement", .french)
 struct ConfigBootstrapTests {
     @Test("Interface Tailscale : config.json écoute sur son adresse")
     func tailscale() throws {
PATCH
```

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift
index 9a438ef..38de412 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift
@@ -4,7 +4,7 @@ import Testing
 @testable import PTZBotKit
 
 @MainActor
-@Suite("Panneau")
+@Suite("Panneau", .french)
 struct PanelModelTests {
     let transport = FakeAdminTransport()
     let scheduler = FakeScheduler()
@@ -100,13 +100,15 @@ struct PanelModelTests {
         ])
     }
 
-    @Test("Refus de ptzd : message affiché, effacé à l'action suivante")
+    @Test("Refus de ptzd : texte de l'app choisi d'après le code (pas celui de ptzd), effacé à l'action suivante")
     func errors() throws {
         try connect()
         try receive(.error(code: .badMessage, message: "Appareil inconnu."))
-        #expect(model.lastError == "Appareil inconnu.")
+        #expect(model.lastError == "ptzd a refusé ce message.")
         model.setPrivacy(false)
         #expect(model.lastError == nil)
+        try receive(.error(code: .uvcFailed, message: "Suivi IA non modifié (délai dépassé)."))
+        #expect(model.lastError == "Suivi IA non modifié : délai dépassé.")
     }
 
     @Test("Appairage : invitation affichée en QR, puis appareil nouveau : « appairé », fenêtre fermée 3 s après")
PATCH
```

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/QRImageTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/QRImageTests.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/QRImageTests.swift
index cd539e6..fb277f3 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/QRImageTests.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/QRImageTests.swift
@@ -3,7 +3,7 @@ import Testing
 import Vision
 @testable import PTZBotKit
 
-@Suite("Image du QR code")
+@Suite("Image du QR code", .french)
 struct QRImageTests {
     let text = "nacelle://pair?v=1&id=1a2b3c4d&k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&h=192.168.0.10,10.0.0.5&p=1985"
 
PATCH
```

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKInstallerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKInstallerTests.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKInstallerTests.swift
index bac74a2..3ddbde9 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKInstallerTests.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKInstallerTests.swift
@@ -123,7 +123,7 @@ struct SDKWorld {
     }
 }
 
-@Suite("SDK : installation et compilation d'obsbot-ai")
+@Suite("SDK : installation et compilation d'obsbot-ai", .french)
 struct SDKInstallerTests {
     let world: SDKWorld
 
PATCH
```

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift
index e960f1b..27c7cc0 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift
@@ -97,7 +97,7 @@ enum FakeSDK {
     }
 }
 
-@Suite("SDK : examen du fichier choisi")
+@Suite("SDK : examen du fichier choisi", .french)
 struct SDKInspectorTests {
     @Test("En-têtes Mach-O : arm64 fin, x86_64 fin, universel, pas une bibliothèque, n'importe quoi")
     func machO() throws {
PATCH
```

Modifier `mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceSupervisorTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceSupervisorTests.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceSupervisorTests.swift
index 28d9649..e1c19bd 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceSupervisorTests.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceSupervisorTests.swift
@@ -3,7 +3,7 @@ import Testing
 @testable import PTZBotKit
 
 @MainActor
-@Suite("Supervision de ptzd")
+@Suite("Supervision de ptzd", .french)
 struct ServiceSupervisorTests {
     let launcher = FakeLauncher()
     let settings = FakeSettings()
@@ -400,7 +400,7 @@ struct ServiceSupervisorTests {
 }
 
 @MainActor
-@Suite("Lanceur de processus réel")
+@Suite("Lanceur de processus réel", .french)
 struct FoundationProcessLauncherTests {
     @Test("Sortie ajoutée au journal ; fin signalée avec le code ; SIGKILL")
     func realProcess() async throws {
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd Packages/NacelleProtocol && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' | grep -v appintents && ./check-bundle.sh)
```

Attendu : échec — les tests ne compilent pas : `Localization`, `AppLanguage`, `ErrorTexts` et `AIFailureText` n'existent pas encore, et le catalogue manque.

- [ ] **Étape 3 : Écrire le code**

Modifier `Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift b/Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift
index a42a8e3..b4ad42f 100644
--- a/Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift
+++ b/Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift
@@ -59,7 +59,7 @@ public enum ControlState: String, Codable, Sendable {
 }
 
 /// Codes d'erreur renvoyés à l'app.
-public enum ErrorCode: String, Codable, Sendable {
+public enum ErrorCode: String, Codable, Sendable, CaseIterable {
     case privacyActive
     case cameraAbsent
     case uvcFailed
@@ -80,6 +80,31 @@ public enum ErrorCode: String, Codable, Sendable {
     case blocked
 }
 
+/// Le message `uvcFailed` de ptzd quand obsbot-ai n'a pas pu changer le suivi IA : « Suivi IA non modifié (<motif>). ».
+/// ptzd le compose, l'app Mac en lit le motif pour afficher son propre texte traduit (spec distribution § 7.2) :
+/// les deux côtés partagent ces textes, en français comme le journal de ptzd.
+public enum AIFailureText {
+    public static let prefix = "Suivi IA non modifié ("
+    public static let suffix = ")."
+    public static let cameraNotFound = "caméra introuvable"
+    public static let sdkError = "erreur du SDK OBSBOT"
+    public static let timeout = "délai dépassé"
+    public static let launchFailed = "l'utilitaire n'a pas pu être lancé"
+    /// Suivi du code de sortie.
+    public static let unexpectedExitPrefix = "l'utilitaire s'est arrêté avec le code "
+
+    public static func message(motive: String) -> String {
+        prefix + motive + suffix
+    }
+
+    /// Le motif d'un message de ce format, nil sinon.
+    public static func motive(in message: String) -> String? {
+        guard message.hasPrefix(prefix), message.hasSuffix(suffix),
+              message.count >= prefix.count + suffix.count else { return nil }
+        return String(message.dropFirst(prefix.count).dropLast(suffix.count))
+    }
+}
+
 /// État complet publié par ptzd.
 public struct StateSnapshot: Equatable, Sendable {
     public var camera: CameraPresence
PATCH
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift
index 7a3dc61..34330a0 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift
@@ -182,7 +182,7 @@ public final class AppController {
             configError = nil
             tailscaleMissing = outcome == .tailscaleMissing || ConfigBootstrap.listensOnLoopbackOnly(configURL: url)
         case let .failure(failure):
-            configError = "config.json n'a pas pu être créé : \(failure.reason)"
+            configError = Localization.text("config.json n'a pas pu être créé : \(failure.reason)")
         }
         onConfigReady?()
         // Pour le message d'un port déjà pris (sortie 75 de ptzd).
PATCH
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/AppLanguage.swift` :

```swift
import Foundation
import Observation

/// La langue de PTZBot, choisie dans ses Réglages (banc du 08/10 : passer par Réglages Système › Langue et région
/// n'est pas commode) : automatique (la règle de macOS pour l'app), français ou anglais.
public enum AppLanguage: String, CaseIterable, Sendable {
    case automatic
    case french
    case english

    /// La langue des textes : « fr » ou « en ». En automatique, d'après les langues préférées du système.
    public func resolved(systemPreferences: [String]) -> String {
        switch self {
        case .automatic: Localization.preferredLanguage(systemPreferences)
        case .french: "fr"
        case .english: "en"
        }
    }

    /// Ce qui est écrit dans `AppleLanguages` du domaine de l'app, pour les fenêtres de Sparkle (choisies par macOS
    /// au lancement) ; nil en automatique : la clé est retirée.
    public var appleLanguages: [String]? {
        switch self {
        case .automatic: nil
        case .french: ["fr"]
        case .english: ["en"]
        }
    }
}

/// Le réglage « Langue » (spec distribution § 12) : retenu dans les préférences de l'app, appliqué tout de suite aux
/// textes de PTZBot. Les vues lisent `language` : elles se redessinent quand il change, sans relancer l'app.
@MainActor
@Observable
public final class AppLanguageModel {
    public static let key = "appLanguage"
    public static let appleLanguagesKey = "AppleLanguages"

    public private(set) var selection: AppLanguage
    /// La langue en vigueur : « fr » ou « en ».
    public private(set) var language: String
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let systemPreferences: [String]
    @ObservationIgnored private let apply: @MainActor (String) -> Void

    /// `systemPreferences` : les langues du système, sans le réglage de l'app ; `apply` reçoit la langue en vigueur.
    public init(settings: any SettingsStore, systemPreferences: [String], apply: @escaping @MainActor (String) -> Void) {
        self.settings = settings
        self.systemPreferences = systemPreferences
        self.apply = apply
        let saved = settings.string(forKey: Self.key).flatMap(AppLanguage.init(rawValue:)) ?? .automatic
        selection = saved
        language = saved.resolved(systemPreferences: systemPreferences)
        apply(language)
    }

    /// Le réglage de l'app : préférences de l'utilisateur, langues du système, `Localization`.
    public static func system() -> AppLanguageModel {
        // Les langues du système, hors du domaine de l'app (où « AppleLanguages » peut porter le réglage de PTZBot).
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let system = global?[appleLanguagesKey] as? [String] ?? Locale.preferredLanguages
        return AppLanguageModel(
            settings: UserDefaultsSettingsStore(defaults: .standard),
            systemPreferences: system,
            apply: { Localization.setAppLanguage($0) }
        )
    }

    /// Le choix de l'utilisateur : retenu, recopié dans `AppleLanguages` pour Sparkle (au prochain lancement),
    /// appliqué tout de suite aux textes.
    public func select(_ choice: AppLanguage) {
        selection = choice
        settings.set(choice.rawValue, forKey: Self.key)
        settings.set(choice.appleLanguages, forKey: Self.appleLanguagesKey)
        language = choice.resolved(systemPreferences: systemPreferences)
        apply(language)
    }
}
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/ErrorTexts.swift` :

```swift
import Foundation
import NacelleProtocol

/// Les refus de ptzd, traduits d'après leur code (spec distribution § 7.2) : l'app ne montre plus le texte
/// français envoyé par ptzd, qui reste celui du journal et de la ligne de commande.
public enum ErrorTexts {
    /// Le texte montré pour un refus de ptzd. Pour `uvcFailed`, le motif connu du suivi IA est repris de `message`.
    public static func text(for code: ErrorCode, message: String) -> String {
        switch code {
        case .privacyActive:
            Localization.text("Vie privée active : commande refusée.")
        case .cameraAbsent:
            Localization.text("Caméra débranchée.")
        case .uvcFailed:
            aiMotive(in: message).map(aiText) ?? Localization.text("La caméra a refusé la commande.")
        case .badMessage:
            Localization.text("ptzd a refusé ce message.")
        case .unpaired:
            Localization.text("Appareil inconnu : appairez-le depuis PTZBot sur le Mac.")
        case .authFailed:
            Localization.text("Signature refusée.")
        case .badCode:
            Localization.text("QR code refusé.")
        case .pairingClosed:
            Localization.text("QR code expiré ou déjà utilisé : relancez l'appairage sur le Mac.")
        case .notAuthenticated:
            Localization.text("Authentification requise.")
        case .notLocal:
            Localization.text("Commande réservée au Mac.")
        case .blocked:
            Localization.text("Appareil expulsé pour quelques minutes.")
        }
    }

    /// Les motifs d'échec du suivi IA que ptzd envoie (`AIResult.userDescription`).
    enum AIMotive: Equatable, Sendable {
        case cameraNotFound
        case sdkError
        case timeout
        case launchFailed
        case unexpectedExit(String)
        /// Un message du suivi IA au motif inconnu (version de ptzd plus récente).
        case other
    }

    /// Le motif du suivi IA dans le message de ptzd, nil si ce n'est pas un échec du suivi IA. Les textes sont ceux
    /// que ptzd compose (`AIFailureText`, partagé par NacelleProtocol), jamais recopiés ici.
    static func aiMotive(in message: String) -> AIMotive? {
        guard let motive = AIFailureText.motive(in: message) else { return nil }
        switch motive {
        case AIFailureText.cameraNotFound: return .cameraNotFound
        case AIFailureText.sdkError: return .sdkError
        case AIFailureText.timeout: return .timeout
        case AIFailureText.launchFailed: return .launchFailed
        default:
            if motive.hasPrefix(AIFailureText.unexpectedExitPrefix) {
                let status = String(motive.dropFirst(AIFailureText.unexpectedExitPrefix.count))
                if Int32(status) != nil {
                    return .unexpectedExit(status)
                }
            }
            return .other
        }
    }

    static func aiText(_ motive: AIMotive) -> String {
        switch motive {
        case .cameraNotFound:
            Localization.text("Suivi IA non modifié : caméra introuvable.")
        case .sdkError:
            Localization.text("Suivi IA non modifié : erreur du SDK OBSBOT.")
        case .timeout:
            Localization.text("Suivi IA non modifié : délai dépassé.")
        case .launchFailed:
            Localization.text("Suivi IA non modifié : obsbot-ai n'a pas pu être lancé.")
        case let .unexpectedExit(code):
            Localization.text("Suivi IA non modifié : obsbot-ai s'est arrêté avec le code \(code).")
        case .other:
            Localization.text("Suivi IA non modifié.")
        }
    }
}
```

Remplacer tout le contenu de `mac/app/PTZBotKit/Sources/PTZBotKit/Labels.swift` par :

```swift
import Foundation
import NacelleProtocol

/// Les textes du panneau et des fenêtres, au vouvoiement (spec app Mac § 8.7), traduits en anglais
/// (spec distribution § 7.1) : voir `Localization`.
public enum Labels {
    public static func route(_ route: ClientRoute) -> String {
        switch route {
        case .localNetwork: Localization.text("Réseau local")
        case .tailscale: Localization.text("Tailscale")
        case .mac: Localization.text("Ce Mac")
        }
    }

    public static func service(_ service: PanelModel.Service) -> String {
        switch service {
        case .connecting: Localization.text("Démarrage…")
        case .active: Localization.text("Actif")
        case .unreachable: Localization.text("Ne répond pas")
        }
    }

    /// « HH:mm », heure locale, sur 24 heures dans les deux langues.
    public static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "fr_FR")))
    }

    /// « m:ss » restant avant `deadline`, jamais négatif.
    public static func remaining(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Une carte de client : nom (ou « PTZBot » pour le Mac), chemin et heure de connexion.
    public static func client(_ client: AdminClient) -> (title: String, detail: String) {
        (client.name ?? "PTZBot", Localization.text("\(route(client.route)) · depuis \(clock(client.since))"))
    }

    /// État d'un appareil dans la fenêtre « Appareils ».
    public static func device(_ device: AdminDevice, clients: [AdminClient], now: Date) -> String {
        if let until = device.blockedUntil, until > now {
            return Localization.text("expulsé jusqu'à \(clock(until))")
        }
        if let client = clients.first(where: { $0.deviceID == device.deviceID }) {
            return Localization.text("connecté · \(route(client.route))")
        }
        return Localization.text("hors ligne")
    }
}
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/LegacyAgent.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/LegacyAgent.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/LegacyAgent.swift
index c27ae23..55697f9 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/LegacyAgent.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/LegacyAgent.swift
@@ -10,7 +10,7 @@ public protocol Launchctl: Sendable {
 public struct SystemLaunchctl: Launchctl {
     public struct Failure: LocalizedError {
         public var status: Int32
-        public var errorDescription: String? { "launchctl bootout a échoué (code \(status))." }
+        public var errorDescription: String? { Localization.text("launchctl bootout a échoué (code \(String(status))).") }
     }
 
     public init() {}
@@ -68,11 +68,11 @@ public enum LegacyMigrationError: Error, Equatable, Sendable {
     public var message: String {
         switch self {
         case let .bootoutFailed(reason):
-            "L'ancienne installation n'a pas pu être arrêtée : \(reason)"
+            Localization.text("L'ancienne installation n'a pas pu être arrêtée : \(reason)")
         case .stillLoaded:
-            "L'ancienne installation ne s'est pas arrêtée à temps."
+            Localization.text("L'ancienne installation ne s'est pas arrêtée à temps.")
         case let .renameFailed(reason):
-            "L'ancienne installation est arrêtée, mais sa plist n'a pas pu être renommée : \(reason)"
+            Localization.text("L'ancienne installation est arrêtée, mais sa plist n'a pas pu être renommée : \(reason)")
         }
     }
 }
@@ -198,7 +198,7 @@ public struct LegacyAgent: Sendable {
                 try trash.trash(url)
                 report.trashed.append(path)
             } catch {
-                report.problems.append("\(path) n'a pas pu être mis à la corbeille : \(error.localizedDescription)")
+                report.problems.append(Localization.text("\(path) n'a pas pu être mis à la corbeille : \(error.localizedDescription)"))
             }
         }
 
@@ -210,7 +210,7 @@ public struct LegacyAgent: Sendable {
                 try manager.moveItem(at: oldSDK, to: newSDK)
                 report.movedSDK = true
             } catch {
-                report.problems.append("Le SDK de lib/ n'a pas pu être repris : \(error.localizedDescription)")
+                report.problems.append(Localization.text("Le SDK de lib/ n'a pas pu être repris : \(error.localizedDescription)"))
             }
         }
         return report
PATCH
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Localization.swift` :

```swift
import Foundation
import Synchronization

/// La langue des textes de PTZBotKit (spec distribution § 7.1) : le français, langue source au vouvoiement, ou
/// l'anglais pour toute autre langue. Les textes sont dans `Resources/Localizable.xcstrings`.
///
/// La langue est celle que l'utilisateur choisit dans les Réglages de PTZBot (`AppLanguageModel`). En automatique,
/// elle est choisie comme macOS la choisit pour l'app (région de développement `en`) : la première des langues
/// préférées de l'utilisateur que PTZBot connaît, sinon l'anglais. `Bundle.module` seul ne suffit pas : hors d'une
/// app qui déclare ses langues (tests, outil en ligne de commande), il prend l'anglais même sur un Mac en français.
public enum Localization {
    public static let languages = ["fr", "en"]

    /// La langue de l'app, réglée par `AppLanguageModel` ; au départ, la règle automatique.
    private static let appLanguage = Mutex(preferredLanguage(Locale.preferredLanguages))

    /// Une langue imposée pour une tâche : les tests la fixent avec `Localization.$languageOverride.withValue("en")`.
    @TaskLocal public static var languageOverride: String?

    /// La langue des textes : celle de la tâche si elle est imposée, sinon celle de l'app.
    public static var language: String {
        languageOverride ?? appLanguage.withLock { $0 }
    }

    /// Change la langue de l'app (« fr » ou « en ») ; les vues se redessinent par `AppLanguageModel`.
    public static func setAppLanguage(_ language: String) {
        appLanguage.withLock { $0 = languages.contains(language) ? language : "en" }
    }

    /// Le français si l'utilisateur le préfère à l'anglais, l'anglais sinon (et pour toute autre langue).
    public static func preferredLanguage(_ preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: languages, forPreferences: preferences).first ?? "en"
    }

    /// Les formats de date et d'heure suivent la langue des textes.
    public static var locale: Locale {
        Locale(identifier: language == "fr" ? "fr_FR" : "en_US")
    }

    /// Le dossier `.lproj` de la langue, dans les ressources de PTZBotKit.
    static func bundle(for language: String) -> Bundle {
        bundles[language] ?? .module
    }

    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: languages.compactMap { language in
        Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)).map { (language, $0) }
    })

    /// Le texte dans la langue courante ; la clé est le texte français.
    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle(for: language))
    }
}
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/LoginItem.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/LoginItem.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/LoginItem.swift
index c8482e1..61b6522 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/LoginItem.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/LoginItem.swift
@@ -62,7 +62,7 @@ public final class LoginItemModel {
                 try service.unregister()
             }
         } catch {
-            lastError = "Ouverture à la connexion impossible : \(error.localizedDescription)"
+            lastError = Localization.text("Ouverture à la connexion impossible : \(error.localizedDescription)")
         }
         refresh()
     }
PATCH
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift
index 6644eea..031ee2b 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift
@@ -22,7 +22,7 @@ public final class PanelModel {
     public private(set) var state: StateSnapshot?
     /// Dernier état d'administration, nil hors connexion.
     public private(set) var admin: AdminState?
-    /// Dernier refus de ptzd, en clair ; effacé à l'action suivante.
+    /// Dernier refus de ptzd, en clair et dans la langue de l'app (`ErrorTexts`) ; effacé à l'action suivante.
     public private(set) var lastError: String?
     /// La fenêtre « Appairer un iPhone » ouverte, s'il y en a une.
     public private(set) var pairing: PairingSession?
@@ -157,11 +157,12 @@ public final class PanelModel {
             pairing?.adminChanged(admin)
         case let .pairingOpened(invitation):
             pairing?.received(invitation)
-        case let .error(_, message):
-            lastError = message
+        case let .error(code, message):
+            // Le texte de ptzd est en français : l'app montre le sien, traduit d'après le code.
+            lastError = ErrorTexts.text(for: code, message: message)
         case .challenge:
             // 127.0.0.1 n'est pas de confiance (ptzd de test) : l'app ne sait pas s'authentifier.
-            lastError = "ptzd demande une authentification : cette app ne passe que par 127.0.0.1."
+            lastError = Localization.text("ptzd demande une authentification : cette app ne passe que par 127.0.0.1.")
         case .paired, .webrtcAnswer, .webrtcError:
             break
         }
PATCH
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings` :

```json
{
  "sourceLanguage": "fr",
  "strings": {
    "%@ (indiquée dans l'archive)": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "%@ (stated in the archive)"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "%@ (indiquée dans l'archive)"
          }
        }
      }
    },
    "%@ (équipe %@)": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "%@ (team %@)"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "%@ (équipe %@)"
          }
        }
      }
    },
    "%@ n'a pas pu être mis à la corbeille : %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "%@ could not be moved to the Trash: %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "%@ n'a pas pu être mis à la corbeille : %@"
          }
        }
      }
    },
    "%@ · depuis %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "%@ · since %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "%@ · depuis %@"
          }
        }
      }
    },
    "Absent": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Missing"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Absent"
          }
        }
      }
    },
    "Actif": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Active"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Actif"
          }
        }
      }
    },
    "Ancienne installation": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Previous installation"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ancienne installation"
          }
        }
      }
    },
    "Appareil expulsé pour quelques minutes.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Device kicked out for a few minutes."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Appareil expulsé pour quelques minutes."
          }
        }
      }
    },
    "Appareil inconnu : appairez-le depuis PTZBot sur le Mac.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Unknown device: pair it from PTZBot on the Mac."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Appareil inconnu : appairez-le depuis PTZBot sur le Mac."
          }
        }
      }
    },
    "Apple Silicon : ✓": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Apple Silicon: ✓"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Apple Silicon : ✓"
          }
        }
      }
    },
    "Apple Silicon : ✗ (%@)": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Apple Silicon: ✗ (%@)"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Apple Silicon : ✗ (%@)"
          }
        }
      }
    },
    "Architecture": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Architecture"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Architecture"
          }
        }
      }
    },
    "Arguments de ptzd refusés": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd arguments refused"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Arguments de ptzd refusés"
          }
        }
      }
    },
    "Arrêté": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Stopped"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Arrêté"
          }
        }
      }
    },
    "Aucun iPhone connecté": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "No iPhone connected"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Aucun iPhone connecté"
          }
        }
      }
    },
    "Authentification requise.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Authentication required."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Authentification requise."
          }
        }
      }
    },
    "Autres copies ignorées": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Other copies ignored"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Autres copies ignorées"
          }
        }
      }
    },
    "Caméra débranchée.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Camera unplugged."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Caméra débranchée."
          }
        }
      }
    },
    "Caméra · branchée": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Camera · plugged in"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Caméra · branchée"
          }
        }
      }
    },
    "Caméra · débranchée": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Camera · unplugged"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Caméra · débranchée"
          }
        }
      }
    },
    "Ce Mac": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "This Mac"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ce Mac"
          }
        }
      }
    },
    "Ce SDK n'a pas de version pour Apple Silicon (%@).": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "This SDK has no Apple silicon version (%@)."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ce SDK n'a pas de version pour Apple Silicon (%@)."
          }
        }
      }
    },
    "Ce SDK n'a pas de version pour Apple Silicon.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "This SDK has no Apple silicon version."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ce SDK n'a pas de version pour Apple Silicon."
          }
        }
      }
    },
    "Ce choix contient un lien symbolique qui mène hors du dossier du SDK : il est refusé. Choisissez le SDK décompressé ou l'archive reçue.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "This selection contains a symbolic link leading outside the SDK folder: it is refused. Choose the unzipped SDK or the archive you received."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ce choix contient un lien symbolique qui mène hors du dossier du SDK : il est refusé. Choisissez le SDK décompressé ou l'archive reçue."
          }
        }
      }
    },
    "Ce fichier n'est pas une bibliothèque Mach-O.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "This file is not a Mach-O library."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ce fichier n'est pas une bibliothèque Mach-O."
          }
        }
      }
    },
    "Changer…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Change…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Changer…"
          }
        }
      }
    },
    "Choisissez l'archive ou le dossier du SDK : ses en-têtes sont nécessaires.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Choose the SDK archive or folder: its headers are needed."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Choisissez l'archive ou le dossier du SDK : ses en-têtes sont nécessaires."
          }
        }
      }
    },
    "Commande réservée au Mac.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Command reserved for the Mac."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Commande réservée au Mac."
          }
        }
      }
    },
    "Compilation impossible": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Compile failed"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Compilation impossible"
          }
        }
      }
    },
    "Copie du SDK impossible : %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The SDK could not be copied: %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Copie du SDK impossible : %@"
          }
        }
      }
    },
    "Démarrage…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Starting…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Démarrage…"
          }
        }
      }
    },
    "En quarantaine": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Quarantined"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "En quarantaine"
          }
        }
      }
    },
    "Incompatible": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Incompatible"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Incompatible"
          }
        }
      }
    },
    "Installer le SDK…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Install SDK…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Installer le SDK…"
          }
        }
      }
    },
    "Installer les outils de développement…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Install Developer Tools…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Installer les outils de développement…"
          }
        }
      }
    },
    "Installez d'abord les outils de développement d'Apple.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Install Apple's developer tools first."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Installez d'abord les outils de développement d'Apple."
          }
        }
      }
    },
    "L'ancien obsbot-ai reste en service.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The previous obsbot-ai stays in use."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "L'ancien obsbot-ai reste en service."
          }
        }
      }
    },
    "L'ancienne installation est arrêtée, mais sa plist n'a pas pu être renommée : %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The previous installation is stopped, but its plist could not be renamed: %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "L'ancienne installation est arrêtée, mais sa plist n'a pas pu être renommée : %@"
          }
        }
      }
    },
    "L'ancienne installation n'a pas pu être arrêtée : %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The previous installation could not be stopped: %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "L'ancienne installation n'a pas pu être arrêtée : %@"
          }
        }
      }
    },
    "L'ancienne installation ne s'est pas arrêtée à temps.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The previous installation did not stop in time."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "L'ancienne installation ne s'est pas arrêtée à temps."
          }
        }
      }
    },
    "L'archive n'a pas pu être décompressée : %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The archive could not be unzipped: %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "L'archive n'a pas pu être décompressée : %@"
          }
        }
      }
    },
    "La caméra a refusé la commande.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The camera refused the command."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "La caméra a refusé la commande."
          }
        }
      }
    },
    "La compilation d'obsbot-ai a échoué : l'ancien SDK est conservé. Le détail est dans le journal obsbot-ai-compilation.log.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "obsbot-ai could not be compiled: the previous SDK is kept. Details are in the obsbot-ai-compilation.log log."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "La compilation d'obsbot-ai a échoué : l'ancien SDK est conservé. Le détail est dans le journal obsbot-ai-compilation.log."
          }
        }
      }
    },
    "La source d'obsbot-ai est introuvable dans l'app.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The obsbot-ai source is missing from the app."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "La source d'obsbot-ai est introuvable dans l'app."
          }
        }
      }
    },
    "La source d'obsbot-ai manque dans l'app : réinstallez PTZBot.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The obsbot-ai source is missing from the app: reinstall PTZBot."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "La source d'obsbot-ai manque dans l'app : réinstallez PTZBot."
          }
        }
      }
    },
    "Le SDK OBSBOT est propriétaire : il ne peut pas être fourni avec PTZBot. Téléchargez-le sur obsbot.com, puis choisissez l'archive reçue (.zip) ou son dossier décompressé.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The OBSBOT SDK is proprietary: it cannot be shipped with PTZBot. Download it from obsbot.com, then choose the archive you received (.zip) or its unzipped folder."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Le SDK OBSBOT est propriétaire : il ne peut pas être fourni avec PTZBot. Téléchargez-le sur obsbot.com, puis choisissez l'archive reçue (.zip) ou son dossier décompressé."
          }
        }
      }
    },
    "Le SDK de lib/ n'a pas pu être repris : %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The SDK in lib/ could not be taken over: %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Le SDK de lib/ n'a pas pu être repris : %@"
          }
        }
      }
    },
    "Le SDK ne se charge pas : réinstallez-le pour retirer la quarantaine de sa copie.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The SDK does not load: reinstall it to remove the quarantine from its copy."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Le SDK ne se charge pas : réinstallez-le pour retirer la quarantaine de sa copie."
          }
        }
      }
    },
    "Le détail est dans le journal obsbot-ai-compilation.log.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Details are in the obsbot-ai-compilation.log log."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Le détail est dans le journal obsbot-ai-compilation.log."
          }
        }
      }
    },
    "Le port %@ est déjà pris : un autre ptzd tourne peut-être encore": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Port %@ is already in use: another ptzd may still be running"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Le port %@ est déjà pris : un autre ptzd tourne peut-être encore"
          }
        }
      }
    },
    "Les en-têtes du SDK contiennent un lien symbolique ou un fichier spécial : ils sont refusés.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The SDK headers contain a symbolic link or a special file: they are refused."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Les en-têtes du SDK contiennent un lien symbolique ou un fichier spécial : ils sont refusés."
          }
        }
      }
    },
    "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai : installez-les, puis recommencez.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Apple's developer tools are needed to compile obsbot-ai: install them, then try again."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai : installez-les, puis recommencez."
          }
        }
      }
    },
    "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai avec le SDK. Installez-les, puis vérifiez à nouveau.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Apple's developer tools are needed to compile obsbot-ai with the SDK. Install them, then check again."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai avec le SDK. Installez-les, puis vérifiez à nouveau."
          }
        }
      }
    },
    "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Apple's developer tools are needed to compile obsbot-ai."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai."
          }
        }
      }
    },
    "Ne répond pas": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Not responding"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ne répond pas"
          }
        }
      }
    },
    "Ne se charge pas": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Does not load"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ne se charge pas"
          }
        }
      }
    },
    "Outils requis": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Tools required"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Outils requis"
          }
        }
      }
    },
    "Ouverture à la connexion impossible : %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Open at login is unavailable: %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ouverture à la connexion impossible : %@"
          }
        }
      }
    },
    "PTZBot n'a pas accès au réseau local : les iPhone ne le trouveront qu'avec Tailscale": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "PTZBot has no access to the local network: iPhones will only find it through Tailscale"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "PTZBot n'a pas accès au réseau local : les iPhone ne le trouveront qu'avec Tailscale"
          }
        }
      }
    },
    "PTZBot va copier ce fichier dans sa bibliothèque et retirer la quarantaine de cette copie. Ne le faites que si vous l'avez téléchargé depuis obsbot.com.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "PTZBot will copy this file into its library and remove the quarantine from that copy. Only do this if you downloaded it from obsbot.com."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "PTZBot va copier ce fichier dans sa bibliothèque et retirer la quarantaine de cette copie. Ne le faites que si vous l'avez téléchargé depuis obsbot.com."
          }
        }
      }
    },
    "Plus tard": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Later"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Plus tard"
          }
        }
      }
    },
    "Provenance": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Origin"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Provenance"
          }
        }
      }
    },
    "Prêt": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Ready"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Prêt"
          }
        }
      }
    },
    "QR code expiré ou déjà utilisé : relancez l'appairage sur le Mac.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "QR code expired or already used: start pairing again on the Mac."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "QR code expiré ou déjà utilisé : relancez l'appairage sur le Mac."
          }
        }
      }
    },
    "QR code refusé.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "QR code refused."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "QR code refusé."
          }
        }
      }
    },
    "Quarantaine": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Quarantine"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Quarantaine"
          }
        }
      }
    },
    "Recompilation…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Recompiling…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Recompilation…"
          }
        }
      }
    },
    "Relancé après un arrêt inattendu (%lld)": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Restarted after an unexpected stop (%lld)"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Relancé après un arrêt inattendu (%lld)"
          }
        }
      }
    },
    "Remplacer": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Replace"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Remplacer"
          }
        }
      }
    },
    "Remplacer l'ancienne installation…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Replace Previous Installation…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Remplacer l'ancienne installation…"
          }
        }
      }
    },
    "Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Reinstall the SDK from its archive or folder: its headers are missing."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent."
          }
        }
      }
    },
    "Réseau local": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Local network"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Réseau local"
          }
        }
      }
    },
    "SDK OBSBOT requis": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "OBSBOT SDK required"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "SDK OBSBOT requis"
          }
        }
      }
    },
    "Service": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Service"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Service"
          }
        }
      }
    },
    "Signature": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Signature"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Signature"
          }
        }
      }
    },
    "Signature invalide": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Invalid signature"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Signature invalide"
          }
        }
      }
    },
    "Signature refusée.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Signature refused."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Signature refusée."
          }
        }
      }
    },
    "Signé": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Signed"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Signé"
          }
        }
      }
    },
    "Signé, certificat non reconnu par Apple": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Signed, certificate not recognized by Apple"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Signé, certificat non reconnu par Apple"
          }
        }
      }
    },
    "Suivi IA non modifié : caméra introuvable.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "AI tracking unchanged: camera not found."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Suivi IA non modifié : caméra introuvable."
          }
        }
      }
    },
    "Suivi IA non modifié : délai dépassé.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "AI tracking unchanged: timed out."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Suivi IA non modifié : délai dépassé."
          }
        }
      }
    },
    "Suivi IA non modifié : erreur du SDK OBSBOT.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "AI tracking unchanged: OBSBOT SDK error."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Suivi IA non modifié : erreur du SDK OBSBOT."
          }
        }
      }
    },
    "Suivi IA non modifié : obsbot-ai n'a pas pu être lancé.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "AI tracking unchanged: obsbot-ai could not be started."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Suivi IA non modifié : obsbot-ai n'a pas pu être lancé."
          }
        }
      }
    },
    "Suivi IA non modifié : obsbot-ai s'est arrêté avec le code %@.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "AI tracking unchanged: obsbot-ai stopped with code %@."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Suivi IA non modifié : obsbot-ai s'est arrêté avec le code %@."
          }
        }
      }
    },
    "Suivi IA non modifié.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "AI tracking unchanged."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Suivi IA non modifié."
          }
        }
      }
    },
    "Tailscale": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Tailscale"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Tailscale"
          }
        }
      }
    },
    "Tailscale introuvable : accès depuis l'extérieur indisponible": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Tailscale not found: no access from outside"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Tailscale introuvable : accès depuis l'extérieur indisponible"
          }
        }
      }
    },
    "Une ancienne installation de ptzd tourne en arrière-plan. PTZBot va la remplacer : le service sera désormais actif seulement quand PTZBot est ouvert. Vos iPhone appairés sont conservés.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "A previous installation of ptzd is running in the background. PTZBot will replace it: from now on, the service will only run while PTZBot is open. Your paired iPhones are kept."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Une ancienne installation de ptzd tourne en arrière-plan. PTZBot va la remplacer : le service sera désormais actif seulement quand PTZBot est ouvert. Vos iPhone appairés sont conservés."
          }
        }
      }
    },
    "Vie privée active : commande refusée.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Privacy mode is on: command refused."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Vie privée active : commande refusée."
          }
        }
      }
    },
    "Vérification…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Checking…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Vérification…"
          }
        }
      }
    },
    "Vérifier à nouveau": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Check Again"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Vérifier à nouveau"
          }
        }
      }
    },
    "config.json est invalide : ouvrez le journal": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "config.json is invalid: open the log"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "config.json est invalide : ouvrez le journal"
          }
        }
      }
    },
    "config.json n'a pas pu être créé : %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "config.json could not be created: %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "config.json n'a pas pu être créé : %@"
          }
        }
      }
    },
    "connecté · %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "connected · %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "connecté · %@"
          }
        }
      }
    },
    "ditto a échoué (code %@).": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "ditto failed (code %@)."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "ditto a échoué (code %@)."
          }
        }
      }
    },
    "ditto n'a pas fini dans le délai imparti.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "ditto did not finish in time."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "ditto n'a pas fini dans le délai imparti."
          }
        }
      }
    },
    "expulsé jusqu'à %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "kicked out until %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "expulsé jusqu'à %@"
          }
        }
      }
    },
    "hors ligne": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "offline"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "hors ligne"
          }
        }
      }
    },
    "iPhone connectés · %lld": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Connected iPhones · %lld"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "iPhone connectés · %lld"
          }
        }
      }
    },
    "inconnue": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "unknown"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "inconnue"
          }
        }
      }
    },
    "l'installation interrompue précédente n'a pas pu être annulée.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "the previous interrupted installation could not be undone."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "l'installation interrompue précédente n'a pas pu être annulée."
          }
        }
      }
    },
    "la copie n'est pas une bibliothèque arm64 ordinaire.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "the copy is not a regular arm64 library."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "la copie n'est pas une bibliothèque arm64 ordinaire."
          }
        }
      }
    },
    "launchctl bootout a échoué (code %@).": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "launchctl bootout failed (code %@)."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "launchctl bootout a échoué (code %@)."
          }
        }
      }
    },
    "le %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "on %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "le %@"
          }
        }
      }
    },
    "les en-têtes copiés ne sont pas des fichiers ordinaires.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "the copied headers are not regular files."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "les en-têtes copiés ne sont pas des fichiers ordinaires."
          }
        }
      }
    },
    "libdev.dylib n'est pas un fichier ordinaire (lien symbolique, tube ou périphérique) : il est refusé.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "libdev.dylib is not a regular file (symbolic link, pipe or device): it is refused."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "libdev.dylib n'est pas un fichier ordinaire (lien symbolique, tube ou périphérique) : il est refusé."
          }
        }
      }
    },
    "macos/arm64-release/libdev.dylib est introuvable dans ce choix.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "macos/arm64-release/libdev.dylib was not found in this selection."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "macos/arm64-release/libdev.dylib est introuvable dans ce choix."
          }
        }
      }
    },
    "non": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "no"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "non"
          }
        }
      }
    },
    "non signé": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "not signed"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "non signé"
          }
        }
      }
    },
    "obsbot-ai introuvable": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "obsbot-ai not found"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "obsbot-ai introuvable"
          }
        }
      }
    },
    "obsbot-ai ne charge pas ce SDK : l'ancien SDK, s'il y en avait un, est conservé.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "obsbot-ai does not load this SDK: the previous SDK, if any, is kept."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "obsbot-ai ne charge pas ce SDK : l'ancien SDK, s'il y en avait un, est conservé."
          }
        }
      }
    },
    "obsbot-ai ne charge pas ce SDK : réinstallez-le.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "obsbot-ai does not load this SDK: reinstall it."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "obsbot-ai ne charge pas ce SDK : réinstallez-le."
          }
        }
      }
    },
    "oui": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "yes"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "oui"
          }
        }
      }
    },
    "ptzd a refusé ce message.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd refused this message."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd a refusé ce message."
          }
        }
      }
    },
    "ptzd demande une authentification : cette app ne passe que par 127.0.0.1.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd asks for authentication: this app only connects through 127.0.0.1."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd demande une authentification : cette app ne passe que par 127.0.0.1."
          }
        }
      }
    },
    "ptzd n'a pas pu être lancé : %@": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd could not be started: %@"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd n'a pas pu être lancé : %@"
          }
        }
      }
    },
    "ptzd ne s'arrête pas : ouvrez le journal": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd does not stop: open the log"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd ne s'arrête pas : ouvrez le journal"
          }
        }
      }
    },
    "ptzd s'arrête sans cesse : ouvrez le journal": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd keeps stopping: open the log"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd s'arrête sans cesse : ouvrez le journal"
          }
        }
      }
    },
    "une installation est déjà en cours.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "an installation is already in progress."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "une installation est déjà en cours."
          }
        }
      }
    },
    "À compléter": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Incomplete"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "À compléter"
          }
        }
      }
    },
    "État inconnu": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Unknown state"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "État inconnu"
          }
        }
      }
    }
  },
  "version": "1.0"
}
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift
index cffd098..1a78a06 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift
@@ -90,21 +90,21 @@ public enum SDKRejection: Error, Equatable, Sendable {
     public var message: String {
         switch self {
         case .notFound:
-            "macos/arm64-release/libdev.dylib est introuvable dans ce choix."
+            Localization.text("macos/arm64-release/libdev.dylib est introuvable dans ce choix.")
         case .notRegularFile:
-            "libdev.dylib n'est pas un fichier ordinaire (lien symbolique, tube ou périphérique) : il est refusé."
+            Localization.text("libdev.dylib n'est pas un fichier ordinaire (lien symbolique, tube ou périphérique) : il est refusé.")
         case .notMachO:
-            "Ce fichier n'est pas une bibliothèque Mach-O."
+            Localization.text("Ce fichier n'est pas une bibliothèque Mach-O.")
         case let .noArm64(architectures):
-            "Ce SDK n'a pas de version pour Apple Silicon (\(architectures.joined(separator: ", ")))."
+            Localization.text("Ce SDK n'a pas de version pour Apple Silicon (\(architectures.joined(separator: ", "))).")
         case let .extractionFailed(reason):
-            "L'archive n'a pas pu être décompressée : \(reason)"
+            Localization.text("L'archive n'a pas pu être décompressée : \(reason)")
         case .outsideArchive:
-            "Ce choix contient un lien symbolique qui mène hors du dossier du SDK : il est refusé. Choisissez le SDK décompressé ou l'archive reçue."
+            Localization.text("Ce choix contient un lien symbolique qui mène hors du dossier du SDK : il est refusé. Choisissez le SDK décompressé ou l'archive reçue.")
         case .headersMissing:
-            "Choisissez l'archive ou le dossier du SDK : ses en-têtes sont nécessaires."
+            Localization.text("Choisissez l'archive ou le dossier du SDK : ses en-têtes sont nécessaires.")
         case .headersNotPlain:
-            "Les en-têtes du SDK contiennent un lien symbolique ou un fichier spécial : ils sont refusés."
+            Localization.text("Les en-têtes du SDK contiennent un lien symbolique ou un fichier spécial : ils sont refusés.")
         }
     }
 }
@@ -280,11 +280,11 @@ public enum SDKInspector {
                 finished.wait()
             }
             try? FileManager.default.removeItem(at: directory)
-            throw .extractionFailed("ditto n'a pas fini dans le délai imparti.")
+            throw .extractionFailed(Localization.text("ditto n'a pas fini dans le délai imparti."))
         }
         guard process.terminationStatus == 0 else {
             try? FileManager.default.removeItem(at: directory)
-            throw .extractionFailed("ditto a échoué (code \(process.terminationStatus)).")
+            throw .extractionFailed(Localization.text("ditto a échoué (code \(String(process.terminationStatus)))."))
         }
         return directory
     }
PATCH
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift
index 8a3a606..b6bda5a 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift
@@ -52,19 +52,19 @@ public enum SDKInstallError: Error, Equatable, Sendable {
     public var message: String {
         switch self {
         case .incompatible:
-            "Ce SDK n'a pas de version pour Apple Silicon."
+            Localization.text("Ce SDK n'a pas de version pour Apple Silicon.")
         case let .copyFailed(reason):
-            "Copie du SDK impossible : \(reason)"
+            Localization.text("Copie du SDK impossible : \(reason)")
         case .unloadable:
-            "obsbot-ai ne charge pas ce SDK : l'ancien SDK, s'il y en avait un, est conservé."
+            Localization.text("obsbot-ai ne charge pas ce SDK : l'ancien SDK, s'il y en avait un, est conservé.")
         case .headersMissing:
             SDKRejection.headersMissing.message
         case .sourceMissing:
-            "La source d'obsbot-ai est introuvable dans l'app."
+            Localization.text("La source d'obsbot-ai est introuvable dans l'app.")
         case .toolsMissing:
-            "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai : installez-les, puis recommencez."
+            Localization.text("Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai : installez-les, puis recommencez.")
         case .compileFailed:
-            "La compilation d'obsbot-ai a échoué : l'ancien SDK est conservé. Le détail est dans le journal obsbot-ai-compilation.log."
+            Localization.text("La compilation d'obsbot-ai a échoué : l'ancien SDK est conservé. Le détail est dans le journal obsbot-ai-compilation.log.")
         }
     }
 }
@@ -198,11 +198,11 @@ public struct SDKInstaller: Sendable {
         guard let sourceHash = sourceHash() else { throw .sourceMissing }
         guard toolchain.isAvailable() else { throw .toolsMissing }
         guard progress.begin() else {
-            throw .copyFailed("une installation est déjà en cours.")
+            throw .copyFailed(Localization.text("une installation est déjà en cours."))
         }
         defer { progress.end() }
         guard recoverInterruptedInstall() else {
-            throw .copyFailed("l'installation interrompue précédente n'a pas pu être annulée.")
+            throw .copyFailed(Localization.text("l'installation interrompue précédente n'a pas pu être annulée."))
         }
         let manager = FileManager.default
         do {
@@ -213,11 +213,11 @@ public struct SDKInstaller: Sendable {
             try Self.copyHeaders(from: headers, to: stagedURL(.headers))
             // Les fichiers ont pu changer depuis leur examen : les copies elles-mêmes sont revérifiées.
             guard SDKInspector.isRegularFile(library), MachO.architectures(of: library)?.contains("arm64") == true else {
-                throw StagingRejected(reason: "la copie n'est pas une bibliothèque arm64 ordinaire.")
+                throw StagingRejected(reason: Localization.text("la copie n'est pas une bibliothèque arm64 ordinaire."))
             }
             guard SDKInspector.isPlainTree(stagedURL(.headers)),
                   SDKInspector.isRegularFile(stagedURL(.headers).appending(path: SDKInspector.mainHeaderPath)) else {
-                throw StagingRejected(reason: "les en-têtes copiés ne sont pas des fichiers ordinaires.")
+                throw StagingRejected(reason: Localization.text("les en-têtes copiés ne sont pas des fichiers ordinaires."))
             }
         } catch {
             discardStaging()
@@ -252,11 +252,11 @@ public struct SDKInstaller: Sendable {
         guard let sourceHash = sourceHash() else { throw .sourceMissing }
         guard toolchain.isAvailable() else { throw .toolsMissing }
         guard progress.begin() else {
-            throw .copyFailed("une installation est déjà en cours.")
+            throw .copyFailed(Localization.text("une installation est déjà en cours."))
         }
         defer { progress.end() }
         guard recoverInterruptedInstall() else {
-            throw .copyFailed("l'installation interrompue précédente n'a pas pu être annulée.")
+            throw .copyFailed(Localization.text("l'installation interrompue précédente n'a pas pu être annulée."))
         }
         do {
             try prepareStaging()
PATCH
```

Remplacer tout le contenu de `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift` par :

```swift
import Foundation
import NacelleProtocol

/// Les textes du service, du SDK et de la migration (spec ptzd dans l'app § 5.6, § 6.1 et § 6.2), au vouvoiement,
/// traduits en anglais (spec distribution § 7.1).
extension Labels {
    /// L'état sous le titre : la supervision de ptzd, puis la connexion de confiance pour « Actif ».
    public static func service(_ state: ServiceSupervisor.State, connection: PanelModel.Service, legacy: Bool) -> String {
        if legacy {
            return Localization.text("Ancienne installation")
        }
        switch state {
        case .stopped, .failed:
            return Localization.text("Arrêté")
        case .starting:
            return Localization.text("Démarrage…")
        case let .restarting(count):
            return Localization.text("Relancé après un arrêt inattendu (\(count))")
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

    /// L'état court, à droite de la ligne « SDK OBSBOT » ; l'explication va dessous (`sdkDetail`).
    public static func sdk(_ status: SDKStatus?) -> String {
        switch status {
        case .ready: Localization.text("Prêt")
        case .absent: Localization.text("Absent")
        case .quarantined: Localization.text("En quarantaine")
        case .incompatible: Localization.text("Incompatible")
        case .unloadable: Localization.text("Ne se charge pas")
        case .sourceMissing: Localization.text("obsbot-ai introuvable")
        case .toolsRequired: Localization.text("Outils requis")
        case .incomplete: Localization.text("À compléter")
        case .recompiling: Localization.text("Recompilation…")
        case .compileFailed: Localization.text("Compilation impossible")
        case nil: Localization.text("Vérification…")
        }
    }

    /// La petite ligne sous « SDK OBSBOT », sur toute la largeur : ce que l'état veut dire et quoi faire ; nil si
    /// l'état se suffit. Quand les outils manquent et que le bouton les installe, elle le dit aussi.
    public static func sdkDetail(_ status: SDKStatus?, toolsAvailable: Bool = true) -> String? {
        var parts: [String] = []
        switch status {
        case .incomplete:
            parts.append(sdkIncompleteDetail)
        case let .toolsRequired(fallback):
            parts.append(sdkToolsDetail)
            if fallback {
                parts.append(sdkFallback)
            }
        case let .compileFailed(fallback):
            if fallback {
                parts.append(sdkFallback)
            }
            parts.append(compileLogHint)
        case .quarantined:
            parts.append(sdkQuarantinedDetail)
        case .incompatible:
            parts.append(sdkIncompatibleDetail)
        case .unloadable:
            parts.append(sdkUnloadableDetail)
        case .sourceMissing:
            parts.append(sdkSourceMissingDetail)
        case .ready, .absent, .recompiling, nil:
            break
        }
        if case .toolsRequired = status {
            // Déjà dit par sdkToolsDetail.
        } else if sdkActionInstallsTools(status, toolsAvailable: toolsAvailable) {
            parts.append(sdkToolsFirst)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public static var sdkFallback: String { Localization.text("L'ancien obsbot-ai reste en service.") }
    public static var compileLogHint: String { Localization.text("Le détail est dans le journal obsbot-ai-compilation.log.") }
    public static var sdkIncompleteDetail: String { Localization.text("Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent.") }
    public static var sdkToolsDetail: String { Localization.text("Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai.") }
    public static var sdkQuarantinedDetail: String { Localization.text("Le SDK ne se charge pas : réinstallez-le pour retirer la quarantaine de sa copie.") }
    public static var sdkIncompatibleDetail: String { Localization.text("Ce SDK n'a pas de version pour Apple Silicon.") }
    public static var sdkUnloadableDetail: String { Localization.text("obsbot-ai ne charge pas ce SDK : réinstallez-le.") }
    public static var sdkSourceMissingDetail: String { Localization.text("La source d'obsbot-ai manque dans l'app : réinstallez PTZBot.") }
    public static var sdkToolsFirst: String { Localization.text("Installez d'abord les outils de développement d'Apple.") }

    /// Le bouton de la ligne SDK : « Changer… » quand il est prêt (la fenêtre reste joignable), « Installer les
    /// outils de développement… » quand ils manquent (obsbot-ai ne pourrait pas être compilé), « Installer le SDK… »
    /// sinon ; aucun pendant la vérification ou la recompilation.
    public static func sdkAction(_ status: SDKStatus?, toolsAvailable: Bool = true) -> String? {
        if sdkActionInstallsTools(status, toolsAvailable: toolsAvailable) {
            return installTools
        }
        switch status {
        case nil, .recompiling, .sourceMissing: return nil
        case .ready: return Localization.text("Changer…")
        case .toolsRequired: return installTools
        case .absent, .quarantined, .incompatible, .unloadable, .incomplete, .compileFailed: return Localization.text("Installer le SDK…")
        }
    }

    /// Le bouton de la ligne SDK lance `xcode-select --install` plutôt que d'ouvrir la fenêtre « SDK OBSBOT » :
    /// les outils manquent et le SDK est à installer (ou obsbot-ai à compiler). Sur le clic de l'utilisateur seulement.
    public static func sdkActionInstallsTools(_ status: SDKStatus?, toolsAvailable: Bool = true) -> Bool {
        switch status {
        case .toolsRequired:
            return true
        case .absent, .quarantined, .incompatible, .unloadable, .incomplete, .compileFailed:
            return !toolsAvailable
        case nil, .ready, .recompiling, .sourceMissing:
            return false
        }
    }

    /// La fenêtre « SDK OBSBOT » quand les outils manquent : elle propose de les installer avant de choisir le SDK.
    public static var sdkToolsExplanation: String { Localization.text("Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai avec le SDK. Installez-les, puis vérifiez à nouveau.") }
    public static var checkToolsAgain: String { Localization.text("Vérifier à nouveau") }

    public static var installTools: String { Localization.text("Installer les outils de développement…") }

    public static var replaceLegacy: String { Localization.text("Remplacer l'ancienne installation…") }

    // MARK: - Sections du panneau

    public static var serviceSection: String { Localization.text("Service") }
    public static var noIPhone: String { Localization.text("Aucun iPhone connecté") }

    /// « Caméra · branchée » ou « Caméra · débranchée » (débranchée aussi hors connexion).
    public static func cameraSection(_ presence: CameraPresence?) -> String {
        presence == .connected ? Localization.text("Caméra · branchée") : Localization.text("Caméra · débranchée")
    }

    /// « iPhone connectés · n ».
    public static func iPhoneSection(count: Int) -> String {
        Localization.text("iPhone connectés · \(count)")
    }

    /// La petite ligne sous « Suivi IA » : le SDK manque, ou l'état ne se lit pas.
    public static func aiNote(_ tracking: AITracking?, needsSDK: Bool) -> String? {
        if needsSDK {
            return sdkRequired
        }
        return tracking == .unknown ? Localization.text("État inconnu") : nil
    }

    /// Le suivi IA a besoin du SDK de l'app et d'un obsbot-ai qui le charge ; l'ancienne installation a le sien
    /// dans `lib/`.
    public static func aiNeedsSDK(_ status: SDKStatus?, legacy: Bool) -> Bool {
        !legacy && status?.aiUsable != true
    }

    public static var sdkRequired: String { Localization.text("SDK OBSBOT requis") }
    public static var tailscaleMissing: String { Localization.text("Tailscale introuvable : accès depuis l'extérieur indisponible") }
    public static var localNetworkDenied: String { Localization.text("PTZBot n'a pas accès au réseau local : les iPhone ne le trouveront qu'avec Tailscale") }

    public static var migrationMessage: String { Localization.text("Une ancienne installation de ptzd tourne en arrière-plan. PTZBot va la remplacer : le service sera désormais actif seulement quand PTZBot est ouvert. Vos iPhone appairés sont conservés.") }
    public static var migrationReplace: String { Localization.text("Remplacer") }
    public static var migrationLater: String { Localization.text("Plus tard") }

    public static var sdkExplanation: String { Localization.text("Le SDK OBSBOT est propriétaire : il ne peut pas être fourni avec PTZBot. Téléchargez-le sur obsbot.com, puis choisissez l'archive reçue (.zip) ou son dossier décompressé.") }
    public static var sdkConfirmation: String { Localization.text("PTZBot va copier ce fichier dans sa bibliothèque et retirer la quarantaine de cette copie. Ne le faites que si vous l'avez téléchargé depuis obsbot.com.") }

    /// Une ligne des vérifications de la fenêtre « SDK OBSBOT ».
    public struct SDKCheck: Equatable, Sendable {
        public var title: String
        public var value: String
    }

    /// La ligne « Signature » : le signataire (et l'équipe) seulement si la signature est intacte et d'un
    /// certificat reconnu par Apple. Ces contrôles ne remplacent pas Gatekeeper.
    static func signatureText(_ candidate: SDKCandidate) -> String {
        switch candidate.signatureValid {
        case false:
            return Localization.text("Signature invalide")
        case true:
            guard candidate.appleAnchored == true else { return Localization.text("Signé, certificat non reconnu par Apple") }
            guard let signer = candidate.signer else { return Localization.text("Signé") }
            return candidate.team.map { Localization.text("\(signer) (équipe \($0))") } ?? signer
        case nil:
            return Localization.text("non signé")
        }
    }

    /// Architecture, signature, provenance et quarantaine (§ 6.2).
    public static func sdkChecks(_ candidate: SDKCandidate) -> [SDKCheck] {
        let architecture = candidate.isArm64
            ? Localization.text("Apple Silicon : ✓")
            : Localization.text("Apple Silicon : ✗ (\(candidate.architectures.joined(separator: ", ")))")
        var origin = [String]()
        if let url = candidate.origin?.url {
            origin.append(url)
        }
        if let date = candidate.origin?.date {
            let formatted = date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(Localization.locale))
            origin.append(Localization.text("le \(formatted)"))
        }
        var provenance = origin.isEmpty ? Localization.text("inconnue") : origin.joined(separator: " · ")
        if !origin.isEmpty, candidate.origin?.fromInsideArchive == true {
            provenance = Localization.text("\(provenance) (indiquée dans l'archive)")
        }
        let signature = signatureText(candidate)
        var checks = [
            SDKCheck(title: Localization.text("Architecture"), value: architecture),
            SDKCheck(title: Localization.text("Signature"), value: signature),
            SDKCheck(title: Localization.text("Provenance"), value: provenance),
            SDKCheck(title: Localization.text("Quarantaine"), value: candidate.quarantined ? Localization.text("oui") : Localization.text("non")),
        ]
        if !candidate.otherCopies.isEmpty {
            checks.append(SDKCheck(title: Localization.text("Autres copies ignorées"), value: candidate.otherCopies.joined(separator: ", ")))
        }
        return checks
    }
}
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceSupervisor.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/ServiceSupervisor.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/ServiceSupervisor.swift
index 61fb420..1a1730a 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/ServiceSupervisor.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/ServiceSupervisor.swift
@@ -41,24 +41,24 @@ public final class ServiceSupervisor {
     /// Délai entre SIGTERM et SIGKILL.
     public static let killDelay: TimeInterval = 5
     public static let enabledKey = "serviceEnabled"
-    public static let crashLoopReason = "ptzd s'arrête sans cesse : ouvrez le journal"
+    public nonisolated static var crashLoopReason: String { Localization.text("ptzd s'arrête sans cesse : ouvrez le journal") }
     /// ptzd ne sort pas même après SIGKILL : l'arrêt est abandonné, ptzd n'est plus relancé par ce chemin.
-    public static let unkillableReason = "ptzd ne s'arrête pas : ouvrez le journal"
+    public nonisolated static var unkillableReason: String { Localization.text("ptzd ne s'arrête pas : ouvrez le journal") }
 
     /// Codes de sortie de ptzd qui ne se corrigent pas en relançant : `failed`, sans relance.
     public static let busyStatus: Int32 = 75
     public static let configStatus: Int32 = 78
     public static let usageStatus: Int32 = 64
-    public static let configReason = "config.json est invalide : ouvrez le journal"
-    public static let usageReason = "Arguments de ptzd refusés"
+    public nonisolated static var configReason: String { Localization.text("config.json est invalide : ouvrez le journal") }
+    public nonisolated static var usageReason: String { Localization.text("Arguments de ptzd refusés") }
 
     /// Un 75 dans les `earlyBusyWindow` secondes du lancement : un ptzd mourant tient peut-être encore le verrou ;
     /// une seule relance, `earlyBusyDelay` secondes plus tard.
     public static let earlyBusyWindow: TimeInterval = 2
     public static let earlyBusyDelay: TimeInterval = 1
 
-    public static func busyReason(port: Int) -> String {
-        "Le port \(port) est déjà pris : un autre ptzd tourne peut-être encore"
+    public nonisolated static func busyReason(port: Int) -> String {
+        Localization.text("Le port \(String(port)) est déjà pris : un autre ptzd tourne peut-être encore")
     }
 
     public private(set) var state: State = .stopped
@@ -215,7 +215,7 @@ public final class ServiceSupervisor {
                 exited(exit)
             }
         } catch {
-            state = .failed(reason: "ptzd n'a pas pu être lancé : \(error.localizedDescription)")
+            state = .failed(reason: Localization.text("ptzd n'a pas pu être lancé : \(error.localizedDescription)"))
             return
         }
         process = launched
PATCH
```

Remplacer tout le contenu de `mac/app/PTZBotKit/Sources/PTZBotKit/SettingsStore.swift` par :

```swift
import Foundation

/// Les préférences de l'app, derrière un protocole pour les tests.
@MainActor
public protocol SettingsStore: AnyObject {
    func bool(forKey key: String) -> Bool?
    func set(_ value: Bool, forKey key: String)
    func string(forKey key: String) -> String?
    /// nil retire la clé.
    func set(_ value: String?, forKey key: String)
    /// nil retire la clé.
    func set(_ value: [String]?, forKey key: String)
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

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func set(_ value: [String]?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
```

Modifier `mac/ptzd/Sources/PTZCore/AIRunner.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZCore/AIRunner.swift b/mac/ptzd/Sources/PTZCore/AIRunner.swift
index 2f74a23..f4c70e9 100644
--- a/mac/ptzd/Sources/PTZCore/AIRunner.swift
+++ b/mac/ptzd/Sources/PTZCore/AIRunner.swift
@@ -1,4 +1,5 @@
 import Foundation
+import NacelleProtocol
 
 /// Issue d'une exécution d'obsbot-ai (spec § 6.9, spec app Mac § 7.5).
 public enum AIResult: Equatable, Sendable {
@@ -13,11 +14,11 @@ public enum AIResult: Equatable, Sendable {
     public var userDescription: String {
         switch self {
         case .success: "réussi"
-        case .cameraNotFound: "caméra introuvable"
-        case .sdkError: "erreur du SDK OBSBOT"
-        case .timeout: "délai dépassé"
-        case .launchFailed: "l'utilitaire n'a pas pu être lancé"
-        case let .unexpectedExit(status): "l'utilitaire s'est arrêté avec le code \(status)"
+        case .cameraNotFound: AIFailureText.cameraNotFound
+        case .sdkError: AIFailureText.sdkError
+        case .timeout: AIFailureText.timeout
+        case .launchFailed: AIFailureText.launchFailed
+        case let .unexpectedExit(status): AIFailureText.unexpectedExitPrefix + String(status)
         }
     }
 }
PATCH
```

Modifier `mac/ptzd/Sources/PTZCore/PTZController.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZCore/PTZController.swift b/mac/ptzd/Sources/PTZCore/PTZController.swift
index 8b8ca7d..d44d62c 100644
--- a/mac/ptzd/Sources/PTZCore/PTZController.swift
+++ b/mac/ptzd/Sources/PTZCore/PTZController.swift
@@ -111,7 +111,7 @@ public final class PTZController {
             }
             control.setTracking(on: on) { [weak self] result in
                 guard result != .success else { return }
-                self?.onClientError?(client, .uvcFailed, "Suivi IA non modifié (\(result.userDescription)).")
+                self?.onClientError?(client, .uvcFailed, AIFailureText.message(motive: result.userDescription))
             }
             return nil
         case .pair, .openPairing, .auth, .webrtcOffer, .adminWatch, .revoke, .kick, .unblock, .closePairing, .forgetMe:
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd Packages/NacelleProtocol && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' | grep -v appintents && ./check-bundle.sh)
```

Attendu : tout passe (protocole : 39 tests, Mac : 204 tests, PTZBotKit : 157 tests, « ** BUILD SUCCEEDED ** » pour l'app, puis les trois lignes « ok : » de `check-bundle.sh`), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift \
    Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift \
    mac/app/PTZBotKit/Package.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/AppLanguage.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/ErrorTexts.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/Labels.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/LegacyAgent.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/Localization.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/LoginItem.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/PanelModel.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings \
    mac/app/PTZBotKit/Sources/PTZBotKit/SDKInspector.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/SDKInstaller.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/ServiceSupervisor.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/SettingsStore.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/AppLanguageTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/ConfigAndLoginTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/IconAndLabelsTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/LanguageTrait.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/LocalizationTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/MigrationTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/PanelModelTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/QRImageTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKInstallerTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/SDKTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceSupervisorTests.swift \
    mac/ptzd/Sources/PTZCore/AIRunner.swift \
    mac/ptzd/Sources/PTZCore/PTZController.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|8\.8\.8\.8|256\.0\.0\.1|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
B2 : PTZBotKit bilingue, erreurs de ptzd par code, langue choisie dans l'app

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés plus haut sont déjà indexés par `git rm`.

### Tâche 3 : L'app : Sparkle, fenêtre Réglages, textes bilingues, paquet sans `obsbot-ai`

**But :** L'app embarque Sparkle 2.10.0. Ed25519 est obligatoire (`SUVerifyUpdateBeforeExtraction`), et Sparkle n'est jamais démarré sous les tests ni dans une compilation de travail. Le pied du panneau propose « Rechercher les mises à jour… », « Réglages… » et « Quitter ». La fenêtre Réglages regroupe les deux cases de Sparkle, « Ouvrir à la connexion », la langue et la version. Les vues sont bilingues. Le paquet contient la source d'`obsbot-ai`, et plus aucun binaire lié au SDK (spec B2 § 5.1, § 7.1, § 8 et § 12).

**Fichiers :**
- Créer : `mac/app/PTZBot/AppText.swift`
- Modifier : `mac/app/PTZBot/DevicesView.swift`
- Créer : `mac/app/PTZBot/InfoPlist.xcstrings`
- Créer : `mac/app/PTZBot/Localizable.xcstrings`
- Modifier : `mac/app/PTZBot/PTZBotApp.swift`
- Modifier : `mac/app/PTZBot/PairingView.swift`
- Modifier : `mac/app/PTZBot/PanelView.swift`
- Modifier : `mac/app/PTZBot/SDKView.swift`
- Créer : `mac/app/PTZBot/SettingsView.swift`
- Créer : `mac/app/PTZBot/SparkleUpdater.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Updater.swift`
- Créer : `mac/app/PTZBotKit/Tests/PTZBotKitTests/AppCatalogTests.swift`
- Créer : `mac/app/PTZBotKit/Tests/PTZBotKitTests/UpdaterTests.swift`
- Modifier : `mac/app/build-helpers.sh`
- Modifier : `mac/app/check-bundle.sh`
- Modifier : `mac/app/project.yml`

**Interfaces :**
- Produit (PTZBotKit) :
  - `Updater` (`checkForUpdates()`, `setAutomaticallyChecks(_:)`, `setAutomaticallyDownloads(_:)`, `observeCanCheck(_:)`) et `NoUpdater` ;
  - `UpdaterPolicy.usesSparkle(bundleVersion:environment:)` et `workBuildVersion` (« 1 ») ;
  - `SettingsModel(updater:updatesEnabled:loginItem:shortVersion:bundleVersion:…)` ;
  - `Labels.version(short:build:)` et `languageChoice(_:)`.
- App : `SparkleUpdater` (`SPUStandardUpdaterController`, rappels discrets), `SettingsView`, `AppText`, `Localizable.xcstrings`, `InfoPlist.xcstrings`.
- `project.yml` :
  - le paquet Sparkle à `exactVersion: 2.10.0` ;
  - `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, `SUScheduledCheckInterval` et `SUVerifyUpdateBeforeExtraction` ;
  - la région de développement `en`.
- `build-helpers.sh` copie `mac/ai/main.cpp` dans `Contents/Resources/obsbot-ai.cpp` et ne compile plus `obsbot-ai`.
- `check-bundle.sh` refuse `libdev*`, tout binaire `obsbot-ai`, les en-têtes du SDK et tout Mach-O lié à libdev (`otool -L`).

- [ ] **Étape 1 : Écrire les tests**

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/AppCatalogTests.swift` :

```swift
import Foundation
import Testing

/// Les catalogues de l'app Mac (mac/app/PTZBot) : chaque texte des vues a sa traduction anglaise (spec
/// distribution § 7.1). Lus dans les sources, à côté de PTZBotKit.
@Suite("Catalogues de l'app", .french)
struct AppCatalogTests {
    static let appDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "PTZBot")

    static func strings(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: appDirectory.appending(path: name))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["sourceLanguage"] as? String == "fr")
        return try #require(object?["strings"] as? [String: Any])
    }

    static func english(_ entry: Any) -> String? {
        let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any]
        let unit = (localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["state"] as? String == "translated" ? unit?["value"] as? String : nil
    }

    @Test("Localizable.xcstrings et InfoPlist.xcstrings : chaque clé a sa traduction anglaise")
    func everyKeyTranslated() throws {
        for name in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let strings = try Self.strings(name)
            #expect(!strings.isEmpty, "\(name)")
            for (key, entry) in strings {
                #expect(Self.english(entry)?.isEmpty == false, "\(name) : \(key)")
            }
        }
        #expect(Self.english(try Self.strings("InfoPlist.xcstrings")["NSLocalNetworkUsageDescription"] as Any) != nil)
    }

    /// Les textes littéraux des vues : `AppText.text("…")`, `AppText.markdown("…")`, les titres de fenêtre, et les
    /// formes de SwiftUI (`Text("…")`, `Button("…")`, `Window("…")`…) ; chaque interpolation devient `%@`.
    static func sourceKeys() throws -> Set<String> {
        let calls = ["Text(\"", "Button(\"", "Toggle(\"", "ProgressView(\"", ".alert(\"", "Window(\"",
                     "String(localized: \"", ".confirmationDialog(\n            \"", "AppText.text(\"", "AppText.markdown(\"",
                     "followsLanguage(delegate.language, title: \""]
        var keys = Set<String>()
        for name in try FileManager.default.contentsOfDirectory(atPath: appDirectory.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: appDirectory.appending(path: name), encoding: .utf8)
            for call in calls {
                var rest = text[...]
                while let range = rest.range(of: call) {
                    var key = ""
                    var index = range.upperBound
                    while rest[index] != "\"" {
                        if rest[index] == "\\", rest[rest.index(after: index)] == "(" {
                            var depth = 0
                            repeat {
                                index = rest.index(after: index)
                                if rest[index] == "(" { depth += 1 }
                                if rest[index] == ")" { depth -= 1 }
                                if rest[index] == "\"" {
                                    index = rest[rest.index(after: index)...].firstIndex(of: "\"")!
                                }
                            } while depth > 0
                            key += "%@"
                        } else {
                            key.append(rest[index])
                        }
                        index = rest.index(after: index)
                    }
                    keys.insert(key)
                    // Depuis le début de la clé : un texte imbriqué dans une interpolation est lu à son tour.
                    rest = rest[range.upperBound...]
                }
            }
        }
        // `Text(verbatim:)` n'est pas traduit ; « PTZBot » reste tel quel.
        return keys.subtracting([""])
    }

    @Test("Chaque texte littéral des vues de l'app est dans son catalogue, et le catalogue n'a pas de clé inutile")
    func everySourceKeyInCatalog() throws {
        let keys = try Self.sourceKeys()
        let catalog = Set(try Self.strings("Localizable.xcstrings").keys)
        #expect(keys.count > 30)
        #expect(keys.subtracting(catalog).sorted() == [])
        #expect(catalog.subtracting(keys).sorted() == [])
    }
}
```

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/UpdaterTests.swift` :

```swift
import Foundation
import Testing
@testable import PTZBotKit

/// Sparkle simulé : réglages retenus, recherches comptées.
@MainActor
final class FakeUpdater: Updater {
    var automaticallyChecks = true
    var automaticallyDownloads = true
    var canCheck = true {
        didSet { canCheckHandler?(canCheck) }
    }
    private(set) var checks = 0
    private var canCheckHandler: (@MainActor (Bool) -> Void)?

    func observeCanCheck(_ handler: @escaping @MainActor (Bool) -> Void) {
        canCheckHandler = handler
        handler(canCheck)
    }

    func checkForUpdates() {
        checks += 1
    }
}

@MainActor
@Suite("Mises à jour et Réglages", .french)
struct UpdaterTests {
    @Test("Sparkle seulement dans une app publiée : numéro de compilation entier supérieur à 1, hors des tests")
    func policy() {
        #expect(UpdaterPolicy.usesSparkle(bundleVersion: "412", environment: [:]))
        #expect(UpdaterPolicy.usesSparkle(bundleVersion: "2", environment: ["HOME": "/maison"]))
        // Compilation de travail : jamais.
        #expect(!UpdaterPolicy.usesSparkle(bundleVersion: "1", environment: [:]))
        #expect(!UpdaterPolicy.usesSparkle(bundleVersion: nil, environment: [:]))
        #expect(!UpdaterPolicy.usesSparkle(bundleVersion: "", environment: [:]))
        #expect(!UpdaterPolicy.usesSparkle(bundleVersion: "1.0", environment: [:]))
        #expect(!UpdaterPolicy.usesSparkle(bundleVersion: "0", environment: [:]))
        // Sous les tests : jamais, même avec un numéro de publication.
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            #expect(!UpdaterPolicy.usesSparkle(bundleVersion: "412", environment: [key: "x"]), "\(key)")
        }
        #expect(UpdaterPolicy.workBuildVersion == "1")
    }

    @Test("Sans Sparkle : aucune recherche, cases décochées et grisées, note affichée")
    func noUpdater() {
        let updater = NoUpdater()
        updater.automaticallyChecks = true
        #expect(!updater.automaticallyChecks)
        #expect(!updater.canCheck)
        let model = SettingsModel(updater: updater, updatesEnabled: false, loginItem: LoginItemModel(service: FakeLoginItem()),
                                  shortVersion: "1.0.0", bundleVersion: "1")
        #expect(!model.automaticallyChecks)
        #expect(!model.canChangeDownloads)
        #expect(!model.canCheckForUpdates)
        model.checkForUpdates()
        #expect(model.versionLine == "PTZBot 1.0.0 (1)")
    }

    @Test("Réglages : cases cochées par défaut, écrites dans Sparkle ; installation grisée sans recherche automatique")
    func settings() {
        let updater = FakeUpdater()
        let model = SettingsModel(updater: updater, updatesEnabled: true, loginItem: LoginItemModel(service: FakeLoginItem()),
                                  shortVersion: "1.0.0", bundleVersion: "412")
        #expect(model.automaticallyChecks)
        #expect(model.automaticallyDownloads)
        #expect(model.canChangeDownloads)
        #expect(model.versionLine == "PTZBot 1.0.0 (412)")
        model.setAutomaticallyDownloads(false)
        #expect(!updater.automaticallyDownloads)
        #expect(!model.automaticallyDownloads)
        model.setAutomaticallyChecks(false)
        #expect(!updater.automaticallyChecks)
        #expect(!model.canChangeDownloads)
        model.setAutomaticallyChecks(true)
        #expect(model.canChangeDownloads)
    }

    @Test("« Rechercher les mises à jour… » : transmis à Sparkle, grisé pendant une recherche")
    func check() {
        let updater = FakeUpdater()
        let model = SettingsModel(updater: updater, updatesEnabled: true, loginItem: LoginItemModel(service: FakeLoginItem()),
                                  shortVersion: "1.0.0", bundleVersion: "412")
        #expect(model.canCheckForUpdates)
        model.checkForUpdates()
        #expect(updater.checks == 1)
        // Une recherche en cours (KVO de Sparkle) : le bouton se grise, puis revient, sans relire l'updater.
        updater.canCheck = false
        #expect(!model.canCheck)
        #expect(!model.canCheckForUpdates)
        updater.canCheck = true
        #expect(model.canCheckForUpdates)
    }

    @Test("« Ouvrir à la connexion » est dans les Réglages")
    func loginItem() {
        let service = FakeLoginItem()
        let model = SettingsModel(updater: NoUpdater(), updatesEnabled: false, loginItem: LoginItemModel(service: service),
                                  shortVersion: nil, bundleVersion: nil)
        model.loginItem.setEnabled(true)
        #expect(service.status == .enabled)
        #expect(model.loginItem.isEnabled)
        #expect(model.versionLine == "PTZBot")
    }

    @Test("Libellés : pied du panneau et Réglages, en français et en anglais ; ligne de version")
    func labels() {
        Localization.$languageOverride.withValue("fr") {
            #expect(Labels.checkForUpdates == "Rechercher les mises à jour…")
            #expect(Labels.settings == "Réglages…")
            #expect(Labels.quit == "Quitter")
            #expect(Labels.automaticallyChecks == "Rechercher automatiquement")
            #expect(Labels.automaticallyInstalls == "Installer automatiquement")
            #expect(Labels.openAtLogin == "Ouvrir à la connexion")
            #expect(Labels.languageTitle == "Langue")
            #expect(Labels.languageChoice(.automatic) == "Automatique (langue du système)")
            #expect(Labels.languageUpdateNote == "Les fenêtres de mise à jour suivront au prochain lancement.")
        }
        Localization.$languageOverride.withValue("en") {
            #expect(Labels.checkForUpdates == "Check for Updates…")
            #expect(Labels.settings == "Settings…")
            #expect(Labels.quit == "Quit")
            #expect(Labels.automaticallyChecks == "Check automatically")
            #expect(Labels.automaticallyInstalls == "Install automatically")
            #expect(Labels.openAtLogin == "Open at login")
            #expect(Labels.updatesDisabled == "Updates are disabled in a development build.")
            #expect(Labels.languageTitle == "Language")
            #expect(Labels.languageChoice(.automatic) == "Automatic (system language)")
            #expect(Labels.languageUpdateNote == "Update windows will follow at the next launch.")
        }
        // « Français » et « English » restent dans leur propre langue, quelle que soit celle de l'app.
        for language in ["fr", "en"] {
            Localization.$languageOverride.withValue(language) {
                #expect(Labels.languageChoice(.french) == "Français")
                #expect(Labels.languageChoice(.english) == "English")
            }
        }
        #expect(Labels.version(short: "1.0.0", build: "412") == "PTZBot 1.0.0 (412)")
        #expect(Labels.version(short: "1.0.0", build: nil) == "PTZBot 1.0.0")
    }
}
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' | grep -v appintents && ./check-bundle.sh)
```

Attendu : échec — la compilation des tests échoue : `Updater`, `SettingsModel` et `UpdaterPolicy` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Créer `mac/app/PTZBot/AppText.swift` :

```swift
import Foundation
import PTZBotKit
import SwiftUI

/// Les textes des vues de l'app, dans la langue choisie dans ses Réglages (`AppLanguageModel`), et non dans celle
/// que macOS a choisie au lancement : ils sont lus dans `fr.lproj` ou `en.lproj` du paquet (catalogue
/// `Localizable.xcstrings`), la clé étant le texte français.
enum AppText {
    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle(for: Localization.language))
    }

    /// Un texte avec du Markdown (gras), traduit de même.
    static func markdown(_ key: String.LocalizationValue) -> AttributedString {
        let translated = text(key)
        return (try? AttributedString(markdown: translated)) ?? AttributedString(translated)
    }

    private static func bundle(for language: String) -> Bundle {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}

extension View {
    /// Suit la langue de l'app : la vue est redessinée dès qu'elle change, sans relancer l'app ; `title` est le
    /// titre de la fenêtre, traduit de même.
    func followsLanguage(_ language: AppLanguageModel, title: String.LocalizationValue? = nil) -> some View {
        let current = language.language
        return environment(\.locale, Locale(identifier: current))
            .navigationTitle(title.map { AppText.text($0) } ?? "")
            .id(current)
    }
}
```

Modifier `mac/app/PTZBot/DevicesView.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBot/DevicesView.swift b/mac/app/PTZBot/DevicesView.swift
index 6618e3a..22b5fa9 100644
--- a/mac/app/PTZBot/DevicesView.swift
+++ b/mac/app/PTZBot/DevicesView.swift
@@ -13,10 +13,10 @@ struct DevicesView: View {
             if let devices = model.admin?.devices, !devices.isEmpty {
                 Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                     GridRow {
-                        Text("Appareil")
-                        Text("Appairé le")
-                        Text("État")
-                        Text("")
+                        Text(AppText.text("Appareil"))
+                        Text(AppText.text("Appairé le"))
+                        Text(AppText.text("État"))
+                        Text(verbatim: "")
                     }
                     .font(.caption).foregroundStyle(.secondary)
                     ForEach(devices, id: \.deviceID) { device in
@@ -31,11 +31,11 @@ struct DevicesView: View {
                             }
                             HStack {
                                 if let until = device.blockedUntil, until > .now {
-                                    Button("Débloquer") {
+                                    Button(AppText.text("Débloquer")) {
                                         model.unblock(device.deviceID)
                                     }
                                 }
-                                Button("Retirer…", role: .destructive) {
+                                Button(AppText.text("Retirer…"), role: .destructive) {
                                     toRevoke = device
                                 }
                             }
@@ -43,7 +43,7 @@ struct DevicesView: View {
                     }
                 }
             } else {
-                Text(model.service == .active ? "Aucun appareil appairé." : "ptzd ne répond pas.")
+                Text(model.service == .active ? AppText.text("Aucun appareil appairé.") : AppText.text("ptzd ne répond pas."))
                     .foregroundStyle(.secondary)
             }
             if let error = model.lastError {
@@ -51,7 +51,7 @@ struct DevicesView: View {
             }
             HStack {
                 Spacer()
-                Button("Appairer un iPhone…") {
+                Button(AppText.text("Appairer un iPhone…")) {
                     model.openPairing()
                     openWindow.front(WindowID.pairing)
                 }
@@ -61,18 +61,18 @@ struct DevicesView: View {
         .padding(20)
         .frame(minWidth: 520)
         .confirmationDialog(
-            "Retirer \(toRevoke?.name ?? "l'appareil") ?",
+            AppText.text("Retirer \(toRevoke?.name ?? AppText.text("l'appareil")) ?"),
             isPresented: Binding(get: { toRevoke != nil }, set: { if !$0 { toRevoke = nil } }),
             titleVisibility: .visible
         ) {
-            Button("Retirer", role: .destructive) {
+            Button(AppText.text("Retirer"), role: .destructive) {
                 if let device = toRevoke {
                     model.revoke(device.deviceID)
                 }
                 toRevoke = nil
             }
         } message: {
-            Text("L'appareil devra être réappairé par QR code. Ses connexions sont coupées tout de suite.")
+            Text(AppText.text("L'appareil devra être réappairé par QR code. Ses connexions sont coupées tout de suite."))
         }
     }
 }
PATCH
```

Créer `mac/app/PTZBot/InfoPlist.xcstrings` :

```json
{
  "sourceLanguage": "fr",
  "strings": {
    "NSLocalNetworkUsageDescription": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "PTZBot accepts connections from paired iPhones on your local network."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "PTZBot accepte les connexions des iPhone appairés sur votre réseau local."
          }
        }
      }
    }
  },
  "version": "1.0"
}
```

Créer `mac/app/PTZBot/Localizable.xcstrings` :

```json
{
  "sourceLanguage": "fr",
  "strings": {
    "%@ appairé": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "%@ paired"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "%@ appairé"
          }
        }
      }
    },
    "Annuler": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Cancel"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Annuler"
          }
        }
      }
    },
    "Appairer un iPhone": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Pair an iPhone"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Appairer un iPhone"
          }
        }
      }
    },
    "Appairer un iPhone…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Pair an iPhone…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Appairer un iPhone…"
          }
        }
      }
    },
    "Appairé le": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Paired on"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Appairé le"
          }
        }
      }
    },
    "Appareil": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Device"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Appareil"
          }
        }
      }
    },
    "Appareils appairés": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Paired Devices"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Appareils appairés"
          }
        }
      }
    },
    "Appareils…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Devices…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Appareils…"
          }
        }
      }
    },
    "Aucun appareil appairé.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "No paired device."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Aucun appareil appairé."
          }
        }
      }
    },
    "Aucune adresse sur le réseau local : reliez le Mac au Wi-Fi ou à l'Ethernet.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "No local network address: connect the Mac to Wi-Fi or Ethernet."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Aucune adresse sur le réseau local : reliez le Mac au Wi-Fi ou à l'Ethernet."
          }
        }
      }
    },
    "Autoriser": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Allow"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Autoriser"
          }
        }
      }
    },
    "Autoriser ce SDK": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Allow This SDK"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Autoriser ce SDK"
          }
        }
      }
    },
    "Autoriser ce SDK ?": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Allow this SDK?"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Autoriser ce SDK ?"
          }
        }
      }
    },
    "Choisir l'archive ou le dossier…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Choose the Archive or Folder…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Choisir l'archive ou le dossier…"
          }
        }
      }
    },
    "Choisissez l'archive du SDK OBSBOT (.zip) ou son dossier décompressé : ses en-têtes sont nécessaires.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Choose the OBSBOT SDK archive (.zip) or its unzipped folder: its headers are needed."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Choisissez l'archive du SDK OBSBOT (.zip) ou son dossier décompressé : ses en-têtes sont nécessaires."
          }
        }
      }
    },
    "Dans PTZBot sur l'iPhone, touchez **Scanner le QR code**.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "In PTZBot on the iPhone, tap **Scanner le QR code**."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Dans PTZBot sur l'iPhone, touchez **Scanner le QR code**."
          }
        }
      }
    },
    "Débloquer": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Unblock"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Débloquer"
          }
        }
      }
    },
    "Expulser": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Kick Out"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Expulser"
          }
        }
      }
    },
    "Installation du SDK et compilation d'obsbot-ai…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Installing the SDK and compiling obsbot-ai…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Installation du SDK et compilation d'obsbot-ai…"
          }
        }
      }
    },
    "L'appareil devra être réappairé par QR code. Ses connexions sont coupées tout de suite.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "The device will have to be paired again with a QR code. Its connections are cut right away."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "L'appareil devra être réappairé par QR code. Ses connexions sont coupées tout de suite."
          }
        }
      }
    },
    "Ne montrez ce code qu'à l'iPhone à appairer.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Only show this code to the iPhone you are pairing."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ne montrez ce code qu'à l'iPhone à appairer."
          }
        }
      }
    },
    "Ouverture de l'appairage…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Opening pairing…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ouverture de l'appairage…"
          }
        }
      }
    },
    "Ouvrir le journal de ptzd": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Open the ptzd Log"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ouvrir le journal de ptzd"
          }
        }
      }
    },
    "Ouvrir les réglages de confidentialité": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Open Privacy Settings"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ouvrir les réglages de confidentialité"
          }
        }
      }
    },
    "Ouvrir obsbot.com/sdk": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Open obsbot.com/sdk"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Ouvrir obsbot.com/sdk"
          }
        }
      }
    },
    "QR code expiré": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "QR code expired"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "QR code expiré"
          }
        }
      }
    },
    "Recommencer": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Start Again"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Recommencer"
          }
        }
      }
    },
    "Retirer": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Remove"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Retirer"
          }
        }
      }
    },
    "Retirer %@ ?": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Remove %@?"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Retirer %@ ?"
          }
        }
      }
    },
    "Retirer…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Remove…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Retirer…"
          }
        }
      }
    },
    "Réglages": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Settings"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Réglages"
          }
        }
      }
    },
    "SDK OBSBOT": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "OBSBOT SDK"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "SDK OBSBOT"
          }
        }
      }
    },
    "SDK installé : le suivi IA est disponible.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "SDK installed: AI tracking is available."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "SDK installé : le suivi IA est disponible."
          }
        }
      }
    },
    "Service ptzd": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd service"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Service ptzd"
          }
        }
      }
    },
    "Suivi IA": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "AI tracking"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Suivi IA"
          }
        }
      }
    },
    "Valable encore %@ · une seule fois": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Valid for %@ more · one use only"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Valable encore %@ · une seule fois"
          }
        }
      }
    },
    "Vie privée": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Privacy"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Vie privée"
          }
        }
      }
    },
    "Vérification du fichier…": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Checking the file…"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "Vérification du fichier…"
          }
        }
      }
    },
    "config.json illisible : port 1985 essayé.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "config.json is unreadable: trying port 1985."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "config.json illisible : port 1985 essayé."
          }
        }
      }
    },
    "l'appareil": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "the device"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "l'appareil"
          }
        }
      }
    },
    "ptzd ne répond pas.": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd is not responding."
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "ptzd ne répond pas."
          }
        }
      }
    },
    "État": {
      "extractionState": "manual",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Status"
          }
        },
        "fr": {
          "stringUnit": {
            "state": "translated",
            "value": "État"
          }
        }
      }
    }
  },
  "version": "1.0"
}
```

Modifier `mac/app/PTZBot/PTZBotApp.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBot/PTZBotApp.swift b/mac/app/PTZBot/PTZBotApp.swift
index b0b6dee..4a3a685 100644
--- a/mac/app/PTZBot/PTZBotApp.swift
+++ b/mac/app/PTZBot/PTZBotApp.swift
@@ -1,15 +1,16 @@
 import PTZBotKit
 import SwiftUI
 
-/// PTZBot pour Mac (spec app Mac, spec ptzd dans l'app) : une icône dans la barre des menus, un panneau,
-/// trois fenêtres, et ptzd lancé comme processus enfant.
+/// PTZBot pour Mac (spec app Mac, spec ptzd dans l'app, spec distribution) : une icône dans la barre des menus,
+/// un panneau, quatre fenêtres, ptzd lancé comme processus enfant, et les mises à jour par Sparkle.
 @main
 struct PTZBotApp: App {
     @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
 
     var body: some Scene {
         MenuBarExtra {
-            PanelView(model: delegate.panel, loginItem: delegate.loginItem, app: delegate.controller, network: delegate.network)
+            PanelView(model: delegate.panel, settings: delegate.settings, app: delegate.controller, network: delegate.network)
+                .followsLanguage(delegate.language)
         } label: {
             Image(nsImage: MenuBarIcon.image())
                 .opacity(delegate.panel.service == .active ? 1 : 0.4)
@@ -19,18 +20,28 @@ struct PTZBotApp: App {
 
         Window("Appairer un iPhone", id: WindowID.pairing) {
             PairingView(model: delegate.panel)
+                .followsLanguage(delegate.language, title: "Appairer un iPhone")
         }
         .windowResizability(.contentSize)
         .defaultLaunchBehavior(.suppressed)
 
         Window("Appareils appairés", id: WindowID.devices) {
             DevicesView(model: delegate.panel)
+                .followsLanguage(delegate.language, title: "Appareils appairés")
         }
         .windowResizability(.contentSize)
         .defaultLaunchBehavior(.suppressed)
 
         Window("SDK OBSBOT", id: WindowID.sdk) {
             SDKView(model: delegate.sdkWindow)
+                .followsLanguage(delegate.language, title: "SDK OBSBOT")
+        }
+        .windowResizability(.contentSize)
+        .defaultLaunchBehavior(.suppressed)
+
+        Window("Réglages", id: WindowID.settings) {
+            SettingsView(model: delegate.settings, language: delegate.language)
+                .followsLanguage(delegate.language, title: "Réglages")
         }
         .windowResizability(.contentSize)
         .defaultLaunchBehavior(.suppressed)
@@ -40,9 +51,11 @@ struct PTZBotApp: App {
 /// Les modèles de l'app, créés une fois ; « Quitter » (et toute fin de l'app) attend l'arrêt de ptzd.
 @MainActor
 final class AppDelegate: NSObject, NSApplicationDelegate {
+    /// La langue choisie dans les Réglages, appliquée avant tout autre texte.
+    let language = AppLanguageModel.system()
     let scheduler = MainScheduler()
     let panel: PanelModel
-    let loginItem = LoginItemModel(service: MainAppLoginItem())
+    let settings: SettingsModel
     let controller: AppController
     let sdkWindow: SDKWindowModel
     let network: LocalNetworkState
@@ -63,6 +76,18 @@ final class AppDelegate: NSObject, NSApplicationDelegate {
         )
         sdkWindow = SDKWindowModel(installer: installer)
         network = LocalNetworkState(scheduler: scheduler)
+        // Sparkle ne démarre que dans une app publiée : jamais sous les tests ni dans une compilation de travail
+        // (numéro de compilation 1).
+        let info = Bundle.main.infoDictionary
+        let bundleVersion = info?["CFBundleVersion"] as? String
+        let usesSparkle = UpdaterPolicy.usesSparkle(bundleVersion: bundleVersion, environment: ProcessInfo.processInfo.environment)
+        settings = SettingsModel(
+            updater: usesSparkle ? SparkleUpdater() : NoUpdater(),
+            updatesEnabled: usesSparkle,
+            loginItem: LoginItemModel(service: MainAppLoginItem()),
+            shortVersion: info?["CFBundleShortVersionString"] as? String,
+            bundleVersion: bundleVersion
+        )
         super.init()
         controller.onConfigReady = { [panel] in
             panel.reloadConfig(.load(from: paths.config))
@@ -81,7 +106,8 @@ final class AppDelegate: NSObject, NSApplicationDelegate {
         Task { await controller.launch() }
     }
 
-    /// Attend l'arrêt de ptzd (6 s au plus), puis répond.
+    /// Attend l'arrêt de ptzd (6 s au plus), puis répond. C'est aussi le chemin d'une mise à jour : Sparkle demande
+    /// à l'app de quitter (événement Apple « quitter ») avant de la remplacer (voir `SparkleUpdater`).
     ///
     /// Ne jamais appeler `NSApp.terminate` depuis un bloc de la file principale (`DispatchQueue.main.async`,
     /// `asyncAfter`, `Task` sur le MainActor) : `.terminateLater` fait tourner la boucle d'exécution à l'intérieur
@@ -143,6 +169,7 @@ enum WindowID {
     static let pairing = "pairing"
     static let devices = "devices"
     static let sdk = "sdk"
+    static let settings = "settings"
 }
 
 extension OpenWindowAction {
PATCH
```

Modifier `mac/app/PTZBot/PairingView.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBot/PairingView.swift b/mac/app/PTZBot/PairingView.swift
index 4dde465..b3192c8 100644
--- a/mac/app/PTZBot/PairingView.swift
+++ b/mac/app/PTZBot/PairingView.swift
@@ -11,13 +11,13 @@ struct PairingView: View {
         VStack(spacing: 12) {
             switch model.pairing?.phase {
             case .waiting, nil:
-                ProgressView("Ouverture de l'appairage…")
+                ProgressView(AppText.text("Ouverture de l'appairage…"))
             case let .showing(invitation):
                 if let link = model.pairing?.link, let image = QRImage.make(link) {
                     Image(decorative: image, scale: 2)
                         .interpolation(.none)
                 }
-                Text("Dans PTZBot sur l'iPhone, touchez **Scanner le QR code**.")
+                Text(AppText.markdown("Dans PTZBot sur l'iPhone, touchez **Scanner le QR code**."))
                     .fixedSize()
                 TimelineView(.periodic(from: .now, by: 1)) { context in
                     let total = invitation.expiresAt.timeIntervalSince(shownAt)
@@ -26,28 +26,28 @@ struct PairingView: View {
                         if total > 0 {
                             ProgressView(value: remaining, total: total)
                         }
-                        Text("Valable encore \(Labels.remaining(until: invitation.expiresAt, now: context.date)) · une seule fois")
+                        Text(AppText.text("Valable encore \(Labels.remaining(until: invitation.expiresAt, now: context.date)) · une seule fois"))
                             .font(.caption).foregroundStyle(.secondary)
                     }
                 }
                 Text(invitation.hosts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
-                Text("Ne montrez ce code qu'à l'iPhone à appairer.").font(.caption).foregroundStyle(.secondary)
-                Button("Annuler") {
+                Text(AppText.text("Ne montrez ce code qu'à l'iPhone à appairer.")).font(.caption).foregroundStyle(.secondary)
+                Button(AppText.text("Annuler")) {
                     model.closePairing()
                     dismiss()
                 }
             case let .paired(name, shortID):
                 Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
-                Text("\(name) appairé").font(.headline)
+                Text(AppText.text("\(name) appairé")).font(.headline)
                 Text(shortID).font(.caption).foregroundStyle(.secondary)
             case .expired:
-                Text("QR code expiré").font(.headline)
-                Button("Recommencer") {
+                Text(AppText.text("QR code expiré")).font(.headline)
+                Button(AppText.text("Recommencer")) {
                     model.openPairing()
                 }
             case .noAddress:
-                Text("Aucune adresse sur le réseau local : reliez le Mac au Wi-Fi ou à l'Ethernet.")
-                Button("Recommencer") {
+                Text(AppText.text("Aucune adresse sur le réseau local : reliez le Mac au Wi-Fi ou à l'Ethernet."))
+                Button(AppText.text("Recommencer")) {
                     model.openPairing()
                 }
             }
PATCH
```

Modifier `mac/app/PTZBot/PanelView.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBot/PanelView.swift b/mac/app/PTZBot/PanelView.swift
index 4804621..0b38bf9 100644
--- a/mac/app/PTZBot/PanelView.swift
+++ b/mac/app/PTZBot/PanelView.swift
@@ -5,7 +5,7 @@ import SwiftUI
 /// Le panneau sous l'icône (spec app Mac § 8.1, maquette B).
 struct PanelView: View {
     let model: PanelModel
-    let loginItem: LoginItemModel
+    let settings: SettingsModel
     let app: AppController
     let network: LocalNetworkState
     @Environment(\.openWindow) private var openWindow
@@ -43,13 +43,13 @@ struct PanelView: View {
                     model.openPairing()
                     openWindow.front(WindowID.pairing)
                 } label: {
-                    Text("Appairer un iPhone…").frame(maxWidth: .infinity)
+                    Text(AppText.text("Appairer un iPhone…")).frame(maxWidth: .infinity)
                 }
                 .buttonStyle(.borderedProminent)
                 Button {
                     openWindow.front(WindowID.devices)
                 } label: {
-                    Text("Appareils…").frame(maxWidth: .infinity)
+                    Text(AppText.text("Appareils…")).frame(maxWidth: .infinity)
                 }
                 .buttonStyle(.bordered)
             }
@@ -71,7 +71,7 @@ struct PanelView: View {
 
     private var header: some View {
         HStack {
-            Text("PTZBot").font(.headline)
+            Text(verbatim: "PTZBot").font(.headline)
             Spacer()
             Text(Labels.service(supervisor.state, connection: model.service, legacy: legacy))
                 .font(.caption)
@@ -86,8 +86,8 @@ struct PanelView: View {
 
     private var serviceSection: some View {
         PanelSection(Labels.serviceSection) {
-            PanelRow(icon: "server.rack", title: "Service ptzd") {
-                Toggle("Service ptzd", isOn: Binding(get: { supervisor.isEnabled }, set: { supervisor.setEnabled($0) }))
+            PanelRow(icon: "server.rack", title: AppText.text("Service ptzd")) {
+                Toggle(AppText.text("Service ptzd"), isOn: Binding(get: { supervisor.isEnabled }, set: { supervisor.setEnabled($0) }))
                     .labelsHidden()
                     .toggleStyle(.switch)
                     .controlSize(.small)
@@ -97,7 +97,7 @@ struct PanelView: View {
                     PanelNote(reason, color: .red)
                 }
                 if Labels.showsLog(supervisor.state, connection: model.service) {
-                    Button("Ouvrir le journal de ptzd") {
+                    Button(AppText.text("Ouvrir le journal de ptzd")) {
                         LogOpener.openPTZDLog()
                     }
                     .buttonStyle(.link)
@@ -117,13 +117,13 @@ struct PanelView: View {
                     PanelNote(problem)
                 }
                 if model.config.isFallback {
-                    PanelNote("config.json illisible : port 1985 essayé.")
+                    PanelNote(AppText.text("config.json illisible : port 1985 essayé."))
                 }
             }
             Divider()
             // À droite, l'état court seulement ; l'explication et le bouton vont dessous, sur toute la largeur
             // (banc du 08/10 : un état long débordait sur six lignes et tronquait le bouton).
-            PanelRow(icon: "shippingbox", title: "SDK OBSBOT") {
+            PanelRow(icon: "shippingbox", title: AppText.text("SDK OBSBOT")) {
                 Text(Labels.sdk(app.sdkStatus))
                     .foregroundStyle(.secondary)
                     .lineLimit(1)
@@ -152,20 +152,20 @@ struct PanelView: View {
 
     private var cameraSection: some View {
         PanelSection(Labels.cameraSection(model.state?.camera)) {
-            PanelRow(icon: "eye.slash", title: "Vie privée") {
-                Toggle("Vie privée", isOn: Binding(get: { model.state?.privacy ?? false }, set: { model.setPrivacy($0) }))
+            PanelRow(icon: "eye.slash", title: AppText.text("Vie privée")) {
+                Toggle(AppText.text("Vie privée"), isOn: Binding(get: { model.state?.privacy ?? false }, set: { model.setPrivacy($0) }))
                     .labelsHidden()
                     .toggleStyle(.switch)
                     .controlSize(.small)
             }
             Divider()
-            PanelRow(icon: "person.crop.square", title: "Suivi IA") {
+            PanelRow(icon: "person.crop.square", title: AppText.text("Suivi IA")) {
                 HStack(spacing: 6) {
                     if aiBusy {
                         // obsbot-ai démarre ou travaille : l'interrupteur attend la fin de l'ordre.
                         ProgressView().controlSize(.small)
                     }
-                    Toggle("Suivi IA", isOn: Binding(get: { model.state?.aiTracking == .on }, set: { model.setAITracking($0) }))
+                    Toggle(AppText.text("Suivi IA"), isOn: Binding(get: { model.state?.aiTracking == .on }, set: { model.setAITracking($0) }))
                         .labelsHidden()
                         .toggleStyle(.switch)
                         .controlSize(.small)
@@ -200,7 +200,7 @@ struct PanelView: View {
                 }
                 let label = Labels.client(client)
                 PanelRow(icon: "iphone", title: label.title, subtitle: label.detail) {
-                    Button("Expulser", role: .destructive) {
+                    Button(AppText.text("Expulser"), role: .destructive) {
                         if let deviceID = client.deviceID {
                             model.kick(deviceID)
                         }
@@ -215,7 +215,7 @@ struct PanelView: View {
             }
             if network.denied {
                 PanelNote(Labels.localNetworkDenied, color: .orange)
-                Button("Ouvrir les réglages de confidentialité") {
+                Button(AppText.text("Ouvrir les réglages de confidentialité")) {
                     network.openSettings()
                 }
                 .buttonStyle(.link)
@@ -226,13 +226,23 @@ struct PanelView: View {
 
     // MARK: - Pied
 
+    /// « Rechercher les mises à jour… », « Réglages… » et « Quitter » (spec distribution § 8) ; « Ouvrir à la
+    /// connexion » est dans les Réglages.
+    /// « Rechercher les mises à jour… » seul sur sa ligne, pour ne pas être tronqué (banc du 08/10), puis
+    /// « Réglages… » et « Quitter ».
     private var footer: some View {
-        VStack(alignment: .leading, spacing: 4) {
-            HStack {
-                Toggle("Ouvrir à la connexion", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
-                    .toggleStyle(.checkbox)
+        VStack(alignment: .leading, spacing: 6) {
+            Button(Labels.checkForUpdates) {
+                settings.checkForUpdates()
+            }
+            .disabled(!settings.canCheckForUpdates)
+            .frame(maxWidth: .infinity, alignment: .leading)
+            HStack(spacing: 12) {
+                Button(Labels.settings) {
+                    openWindow.front(WindowID.settings)
+                }
                 Spacer()
-                Button("Quitter") {
+                Button(Labels.quit) {
                     // Un appairage ouvert est fermé avant de partir ; l'envoi est asynchrone, d'où le court délai.
                     // La fin de l'app attend ensuite l'arrêt de ptzd, 6 s au plus (AppDelegate).
                     // Par la boucle d'exécution, jamais depuis un bloc de la file principale : voir
@@ -240,20 +250,10 @@ struct PanelView: View {
                     model.closePairing()
                     NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.3, inModes: [.common])
                 }
-                .buttonStyle(.plain)
-                .foregroundStyle(.secondary)
-            }
-            if loginItem.needsApproval {
-                Button("Autorisez PTZBot dans Réglages › Général › Ouverture") {
-                    loginItem.openSystemSettings()
-                }
-                .buttonStyle(.link)
-                .font(.caption)
-            }
-            if let error = loginItem.lastError {
-                PanelNote(error, color: .red)
             }
         }
+        .buttonStyle(.plain)
+        .foregroundStyle(.secondary)
     }
 }
 
@@ -283,7 +283,7 @@ private struct PanelSection<Content: View, Notes: View>: View {
 }
 
 /// Une ligne de boîte : icône, titre (et sous-titre), commande alignée à droite ; ses messages dessous,
-/// sans déranger l'alignement.
+/// sans déranger l'alignement. Le titre est déjà traduit (`String(localized:)` ou `Labels`).
 private struct PanelRow<Trailing: View, Notes: View>: View {
     let icon: String
     let title: String
@@ -333,7 +333,7 @@ private struct PanelRow<Trailing: View, Notes: View>: View {
     }
 }
 
-/// Un petit message sous une ligne ou une section.
+/// Un petit message sous une ligne ou une section, déjà traduit.
 private struct PanelNote: View {
     let text: String
     let color: Color?
PATCH
```

Modifier `mac/app/PTZBot/SDKView.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBot/SDKView.swift b/mac/app/PTZBot/SDKView.swift
index f0f55d0..b55a954 100644
--- a/mac/app/PTZBot/SDKView.swift
+++ b/mac/app/PTZBot/SDKView.swift
@@ -33,7 +33,7 @@ struct SDKView: View {
             case .choosing:
                 EmptyView()
             case .inspecting:
-                ProgressView("Vérification du fichier…")
+                ProgressView(AppText.text("Vérification du fichier…"))
             case let .candidate(candidate):
                 Text(candidate.path.lastPathComponent).font(.headline)
                 Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
@@ -44,7 +44,7 @@ struct SDKView: View {
                         }
                     }
                 }
-                Button("Autoriser ce SDK") {
+                Button(AppText.text("Autoriser ce SDK")) {
                     confirming = true
                 }
                 .buttonStyle(.borderedProminent)
@@ -52,18 +52,18 @@ struct SDKView: View {
             case let .rejected(message), let .failed(message):
                 Text(message).foregroundStyle(.red)
             case .installing:
-                ProgressView("Installation du SDK et compilation d'obsbot-ai…")
+                ProgressView(AppText.text("Installation du SDK et compilation d'obsbot-ai…"))
             case .installed:
-                Text("SDK installé : le suivi IA est disponible.").foregroundStyle(.green)
+                Text(AppText.text("SDK installé : le suivi IA est disponible.")).foregroundStyle(.green)
             }
         }
         .padding(20)
         .frame(width: 460)
-        .alert("Autoriser ce SDK ?", isPresented: $confirming) {
-            Button("Autoriser") {
+        .alert(AppText.text("Autoriser ce SDK ?"), isPresented: $confirming) {
+            Button(AppText.text("Autoriser")) {
                 Task { await model.authorize() }
             }
-            Button("Annuler", role: .cancel) {}
+            Button(AppText.text("Annuler"), role: .cancel) {}
         } message: {
             Text(Labels.sdkConfirmation)
         }
@@ -77,12 +77,12 @@ struct SDKView: View {
 
     private var choiceButtons: some View {
         HStack {
-            Button("Ouvrir obsbot.com/sdk") {
+            Button(AppText.text("Ouvrir obsbot.com/sdk")) {
                 if let url = URL(string: "https://www.obsbot.com/sdk") {
                     NSWorkspace.shared.open(url)
                 }
             }
-            Button("Choisir l'archive ou le dossier…", action: choose)
+            Button(AppText.text("Choisir l'archive ou le dossier…"), action: choose)
                 .buttonStyle(.borderedProminent)
         }
         .disabled(model.phase == .inspecting || model.phase == .installing)
@@ -94,7 +94,7 @@ struct SDKView: View {
         panel.canChooseDirectories = true
         panel.allowsMultipleSelection = false
         panel.allowedContentTypes = [.zip, .folder]
-        panel.message = "Choisissez l'archive du SDK OBSBOT (.zip) ou son dossier décompressé : ses en-têtes sont nécessaires."
+        panel.message = AppText.text("Choisissez l'archive du SDK OBSBOT (.zip) ou son dossier décompressé : ses en-têtes sont nécessaires.")
         guard panel.runModal() == .OK, let url = panel.url else { return }
         Task { await model.choose(url) }
     }
PATCH
```

Créer `mac/app/PTZBot/SettingsView.swift` :

```swift
import PTZBotKit
import SwiftUI

/// La fenêtre « Réglages » (spec distribution § 8) : les mises à jour, l'ouverture à la connexion et la version.
struct SettingsView: View {
    let model: SettingsModel
    let language: AppLanguageModel

    private var loginItem: LoginItemModel {
        model.loginItem
    }

    var body: some View {
        Form {
            Section {
                Toggle(Labels.automaticallyChecks, isOn: Binding(get: { model.automaticallyChecks }, set: { model.setAutomaticallyChecks($0) }))
                    .disabled(!model.updatesEnabled)
                Toggle(Labels.automaticallyInstalls, isOn: Binding(get: { model.automaticallyDownloads }, set: { model.setAutomaticallyDownloads($0) }))
                    .disabled(!model.canChangeDownloads)
                if !model.updatesEnabled {
                    Text(Labels.updatesDisabled).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(Labels.openAtLogin, isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                if loginItem.needsApproval {
                    Button(Labels.loginApproval) {
                        loginItem.openSystemSettings()
                    }
                    .buttonStyle(.link)
                }
                if let error = loginItem.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                // « Français » et « English » sont toujours écrits dans leur langue.
                Picker(Labels.languageTitle, selection: Binding(get: { language.selection }, set: { language.select($0) })) {
                    ForEach(AppLanguage.allCases, id: \.self) { choice in
                        Text(Labels.languageChoice(choice)).tag(choice)
                    }
                }
                Text(Labels.languageUpdateNote).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(model.versionLine)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loginItem.refresh()
        }
    }
}
```

Créer `mac/app/PTZBot/SparkleUpdater.swift` :

```swift
import AppKit
import PTZBotKit
import Sparkle

/// Les mises à jour par Sparkle 2 (spec distribution § 8) : flux, clé et rythme dans Info.plist (project.yml).
/// Créé seulement pour une app publiée (`UpdaterPolicy`) : jamais sous les tests ni dans une compilation de travail.
///
/// Installer une mise à jour quitte l'app par le même chemin que « Quitter » : le programme d'installation de
/// Sparkle envoie à l'app l'événement Apple « quitter » (`NSRunningApplication.terminate`, dans
/// `InstallerProgressAppController.sendTerminationSignal`), donc `applicationShouldTerminate`, qui arrête ptzd
/// d'abord ; Sparkle attend la fin de l'app avant de la remplacer, puis la relance.
@MainActor
final class SparkleUpdater: Updater {
    private let controller: SPUStandardUpdaterController
    private let userDriverDelegate = MenuBarUserDriverDelegate()
    private var canCheckObservation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: userDriverDelegate)
    }

    func checkForUpdates() {
        // Sans icône dans le Dock, la fenêtre de Sparkle doit être amenée au premier plan.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    var canCheck: Bool {
        controller.updater.canCheckForUpdates
    }

    /// KVO sur `canCheckForUpdates`, comme l'exemple SwiftUI de Sparkle : le bouton du panneau suit l'état en direct.
    func observeCanCheck(_ handler: @escaping @MainActor (Bool) -> Void) {
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor in handler(canCheck) }
        }
    }
}

/// Une app de la barre des menus, sans icône dans le Dock : les rappels « discrets » de Sparkle. Quand
/// « Installer automatiquement » est décoché, une mise à jour trouvée au fil des recherches est montrée par la
/// fenêtre de Sparkle, amenée au premier plan, au lieu de rester derrière les autres apps.
final class MenuBarUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    // Sparkle appelle son délégué sur le fil principal.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        MainActor.assumeIsolated {
            NSApp.activate()
        }
    }
}
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings b/mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings
index a480c12..1144217 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings
@@ -273,6 +273,40 @@
         }
       }
     },
+    "Automatique (langue du système)": {
+      "extractionState": "manual",
+      "localizations": {
+        "en": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Automatic (system language)"
+          }
+        },
+        "fr": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Automatique (langue du système)"
+          }
+        }
+      }
+    },
+    "Autorisez PTZBot dans Réglages › Général › Ouverture": {
+      "extractionState": "manual",
+      "localizations": {
+        "en": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Allow PTZBot in System Settings › General › Login Items"
+          }
+        },
+        "fr": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Autorisez PTZBot dans Réglages › Général › Ouverture"
+          }
+        }
+      }
+    },
     "Autres copies ignorées": {
       "extractionState": "manual",
       "localizations": {
@@ -562,6 +596,23 @@
         }
       }
     },
+    "Installer automatiquement": {
+      "extractionState": "manual",
+      "localizations": {
+        "en": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Install automatically"
+          }
+        },
+        "fr": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Installer automatiquement"
+          }
+        }
+      }
+    },
     "Installer le SDK…": {
       "extractionState": "manual",
       "localizations": {
@@ -766,6 +817,23 @@
         }
       }
     },
+    "Langue": {
+      "extractionState": "manual",
+      "localizations": {
+        "en": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Language"
+          }
+        },
+        "fr": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Langue"
+          }
+        }
+      }
+    },
     "Le SDK OBSBOT est propriétaire : il ne peut pas être fourni avec PTZBot. Téléchargez-le sur obsbot.com, puis choisissez l'archive reçue (.zip) ou son dossier décompressé.": {
       "extractionState": "manual",
       "localizations": {
@@ -868,6 +936,23 @@
         }
       }
     },
+    "Les fenêtres de mise à jour suivront au prochain lancement.": {
+      "extractionState": "manual",
+      "localizations": {
+        "en": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Update windows will follow at the next launch."
+          }
+        },
+        "fr": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Les fenêtres de mise à jour suivront au prochain lancement."
+          }
+        }
+      }
+    },
     "Les outils de développement d'Apple sont nécessaires pour compiler obsbot-ai : installez-les, puis recommencez.": {
       "extractionState": "manual",
       "localizations": {
@@ -919,6 +1004,23 @@
         }
       }
     },
+    "Mises à jour désactivées dans une compilation de travail.": {
+      "extractionState": "manual",
+      "localizations": {
+        "en": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Updates are disabled in a development build."
+          }
+        },
+        "fr": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Mises à jour désactivées dans une compilation de travail."
+          }
+        }
+      }
+    },
     "Ne répond pas": {
       "extractionState": "manual",
       "localizations": {
@@ -987,6 +1089,23 @@
         }
       }
     },
+    "Ouvrir à la connexion": {
+      "extractionState": "manual",
+      "localizations": {
+        "en": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Open at login"
+          }
+        },
+        "fr": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Ouvrir à la connexion"
+          }
+        }
+      }
+    },
     "PTZBot n'a pas accès au réseau local : les iPhone ne le trouveront qu'avec Tailscale": {
       "extractionState": "manual",
       "localizations": {
@@ -1123,6 +1242,57 @@
         }
       }
     },
+    "Quitter": {
+      "extractionState": "manual",
+      "localizations": {
+        "en": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Quit"
+          }
+        },
+        "fr": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Quitter"
+          }
+        }
+      }
+    },
+    "Rechercher automatiquement": {
+      "extractionState": "manual",
+      "localizations": {
+        "en": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Check automatically"
+          }
+        },
+        "fr": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Rechercher automatiquement"
+          }
+        }
+      }
+    },
+    "Rechercher les mises à jour…": {
+      "extractionState": "manual",
+      "localizations": {
+        "en": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Check for Updates…"
+          }
+        },
+        "fr": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Rechercher les mises à jour…"
+          }
+        }
+      }
+    },
     "Recompilation…": {
       "extractionState": "manual",
       "localizations": {
@@ -1191,6 +1361,23 @@
         }
       }
     },
+    "Réglages…": {
+      "extractionState": "manual",
+      "localizations": {
+        "en": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Settings…"
+          }
+        },
+        "fr": {
+          "stringUnit": {
+            "state": "translated",
+            "value": "Réglages…"
+          }
+        }
+      }
+    },
     "Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent.": {
       "extractionState": "manual",
       "localizations": {
PATCH
```

Modifier `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift
index 76be1b7..94dd536 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift
@@ -232,3 +232,37 @@ extension Labels {
         return checks
     }
 }
+
+/// Le pied du panneau et la fenêtre « Réglages » (spec distribution § 8).
+extension Labels {
+    public static var checkForUpdates: String { Localization.text("Rechercher les mises à jour…") }
+    public static var settings: String { Localization.text("Réglages…") }
+    public static var quit: String { Localization.text("Quitter") }
+    public static var automaticallyChecks: String { Localization.text("Rechercher automatiquement") }
+    public static var automaticallyInstalls: String { Localization.text("Installer automatiquement") }
+    public static var openAtLogin: String { Localization.text("Ouvrir à la connexion") }
+    public static var loginApproval: String { Localization.text("Autorisez PTZBot dans Réglages › Général › Ouverture") }
+    public static var languageTitle: String { Localization.text("Langue") }
+    public static var languageUpdateNote: String { Localization.text("Les fenêtres de mise à jour suivront au prochain lancement.") }
+
+    /// Un choix de la langue : « Automatique (langue du système) », traduit ; « Français » et « English » toujours
+    /// dans leur propre langue.
+    public static func languageChoice(_ language: AppLanguage) -> String {
+        switch language {
+        case .automatic: Localization.text("Automatique (langue du système)")
+        case .french: "Français"
+        case .english: "English"
+        }
+    }
+
+    public static var updatesDisabled: String { Localization.text("Mises à jour désactivées dans une compilation de travail.") }
+
+    /// « PTZBot 1.0.0 (412) » : la version et le numéro de compilation, tels qu'ils sont dans l'app.
+    public static func version(short: String?, build: String?) -> String {
+        switch (short, build) {
+        case let (short?, build?): "PTZBot \(short) (\(build))"
+        case let (short?, nil): "PTZBot \(short)"
+        default: "PTZBot"
+        }
+    }
+}
PATCH
```

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Updater.swift` :

```swift
import Foundation
import Observation

/// Les mises à jour de l'app (spec distribution § 8), derrière un protocole : Sparkle dans l'app, rien ailleurs.
@MainActor
public protocol Updater: AnyObject {
    /// « Rechercher les mises à jour… » : la recherche, avec la fenêtre de Sparkle.
    func checkForUpdates()
    /// « Rechercher automatiquement » : au lancement, puis toutes les 24 h.
    var automaticallyChecks: Bool { get set }
    /// « Installer automatiquement » : téléchargée en silence, installée à la fermeture.
    var automaticallyDownloads: Bool { get set }
    /// Une recherche peut être lancée maintenant (aucune en cours).
    var canCheck: Bool { get }
    /// `handler` reçoit la valeur de `canCheck` tout de suite, puis à chaque changement (KVO de Sparkle).
    func observeCanCheck(_ handler: @escaping @MainActor (Bool) -> Void)
}

/// Pas de mises à jour : sous les tests et dans une compilation de travail (numéro de compilation 1).
@MainActor
public final class NoUpdater: Updater {
    public init() {}

    public func checkForUpdates() {}

    public var automaticallyChecks: Bool {
        get { false }
        set {}
    }

    public var automaticallyDownloads: Bool {
        get { false }
        set {}
    }

    public var canCheck: Bool {
        false
    }

    public func observeCanCheck(_ handler: @escaping @MainActor (Bool) -> Void) {
        handler(false)
    }
}

/// Quand Sparkle démarre (spec distribution § 8) : au lancement d'une app publiée, jamais sous les tests ni dans une
/// compilation de travail.
public enum UpdaterPolicy {
    /// Le numéro de compilation d'une compilation de travail ; la publication donne le nombre de commits de `main`.
    public static let workBuildVersion = "1"

    /// Les variables que pose XCTest dans un processus de tests.
    static let testEnvironmentKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]

    /// Vrai pour une app publiée : un numéro de compilation entier supérieur à 1, hors de tout processus de tests.
    public static func usesSparkle(bundleVersion: String?, environment: [String: String]) -> Bool {
        guard let bundleVersion, let number = Int(bundleVersion), number > 1 else { return false }
        return !testEnvironmentKeys.contains { environment[$0] != nil }
    }
}

/// La fenêtre « Réglages » (spec distribution § 8) : les deux cases de Sparkle, « Ouvrir à la connexion » et la
/// version.
@MainActor
@Observable
public final class SettingsModel {
    public private(set) var automaticallyChecks: Bool
    public private(set) var automaticallyDownloads: Bool
    /// Sparkle peut lancer une recherche maintenant ; suivi en direct (aucune recherche en cours).
    public private(set) var canCheck = false
    /// Les mises à jour sont actives (app publiée) ; sinon les deux cases sont grisées, avec une note.
    public let updatesEnabled: Bool
    /// « PTZBot 1.0.0 (412) ».
    public let versionLine: String
    public let loginItem: LoginItemModel
    @ObservationIgnored private let updater: any Updater

    public init(updater: any Updater, updatesEnabled: Bool, loginItem: LoginItemModel, shortVersion: String?, bundleVersion: String?) {
        self.updater = updater
        self.updatesEnabled = updatesEnabled
        self.loginItem = loginItem
        automaticallyChecks = updater.automaticallyChecks
        automaticallyDownloads = updater.automaticallyDownloads
        versionLine = Labels.version(short: shortVersion, build: bundleVersion)
        updater.observeCanCheck { [weak self] canCheck in
            self?.canCheck = canCheck
        }
    }

    /// « Rechercher automatiquement ». Sans recherche automatique, l'installation automatique n'a plus d'objet :
    /// sa case est grisée (Sparkle garde son réglage).
    public func setAutomaticallyChecks(_ enabled: Bool) {
        updater.automaticallyChecks = enabled
        automaticallyChecks = updater.automaticallyChecks
    }

    /// « Installer automatiquement ».
    public func setAutomaticallyDownloads(_ enabled: Bool) {
        updater.automaticallyDownloads = enabled
        automaticallyDownloads = updater.automaticallyDownloads
    }

    /// La case « Installer automatiquement » est utilisable.
    public var canChangeDownloads: Bool {
        updatesEnabled && automaticallyChecks
    }

    /// « Rechercher les mises à jour… » du panneau : grisé hors d'une app publiée ou pendant une recherche.
    public var canCheckForUpdates: Bool {
        updatesEnabled && canCheck
    }

    public func checkForUpdates() {
        guard updatesEnabled else { return }
        updater.checkForUpdates()
    }
}
```

Remplacer tout le contenu de `mac/app/build-helpers.sh` par :

```bash
#!/bin/bash
# Phase de construction de PTZBot (project.yml) : compile ptzd et le copie dans Contents/Helpers, copie la source
# d'obsbot-ai (mac/ai/main.cpp) dans Contents/Resources/obsbot-ai.cpp, puis refuse le paquet s'il contient le SDK
# OBSBOT, ses en-têtes ou un binaire obsbot-ai (spec distribution § 5.1). obsbot-ai est compilé sur le Mac de
# l'utilisateur, avec le SDK qu'il fournit (spec distribution § 6) : la construction n'a plus besoin du SDK.
set -euo pipefail

ROOT="$(cd "$SRCROOT/../.." && pwd)"
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"

mkdir -p "$HELPERS" "$RESOURCES"

# swift build hors de l'environnement de Xcode, dont les variables (SDKROOT, ARCHS…) le dérouteraient.
echo "Compilation de ptzd…"
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/ptzd" --product ptzd
BIN="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/ptzd" --show-bin-path)"
install -m 755 "$BIN/ptzd" "$HELPERS/ptzd"

echo "Source d'obsbot-ai…"
install -m 644 "$ROOT/mac/ai/main.cpp" "$RESOURCES/obsbot-ai.cpp"

# Un ancien paquet (B1) a pu garder Helpers/obsbot-ai : il est retiré.
rm -f "$HELPERS/obsbot-ai"
FOUND="$(find "$APP" \( -name 'libdev*.dylib' -o -name 'obsbot-ai' -o -name 'devs.hpp' -o -name 'dev.hpp' \) -print)"
if [ -n "$FOUND" ]; then
    echo "error: le SDK OBSBOT, ses en-têtes ou un binaire obsbot-ai ne doivent jamais être dans le paquet : $FOUND" >&2
    exit 1
fi
```

Remplacer tout le contenu de `mac/app/check-bundle.sh` par :

```bash
#!/bin/bash
# Vérifie le paquet Release de PTZBot (spec distribution § 5.1 et § 10) : ptzd dans Contents/Helpers, la source
# d'obsbot-ai dans Contents/Resources, Sparkle dans Contents/Frameworks ; ni le SDK OBSBOT (libdev*.dylib), ni ses
# en-têtes (devs.hpp, dev.hpp), ni aucun binaire obsbot-ai, ni aucun binaire Mach-O qui dépende de libdev (otool -L).
# Usage : mac/app/check-bundle.sh [chemin de PTZBot.app]
set -euo pipefail

APP="${1:-$(cd "$(dirname "$0")" && pwd)/.build/Build/Products/Release/PTZBot.app}"
STATUS=0

if [ ! -d "$APP" ]; then
    echo "Paquet introuvable : $APP" >&2
    exit 1
fi

require() {
    if [ "$1" "$APP/$2" ]; then
        echo "ok : $2"
    else
        echo "manquant : $2" >&2
        STATUS=1
    fi
}
require -x Contents/Helpers/ptzd
require -f Contents/Resources/obsbot-ai.cpp
require -d Contents/Frameworks/Sparkle.framework

refuse() {
    local FOUND
    FOUND="$(find "$APP" "$@" -print)"
    if [ -n "$FOUND" ]; then
        echo "interdit dans le paquet : $FOUND" >&2
        STATUS=1
    fi
}
refuse -name 'libdev*.dylib'
refuse -name 'obsbot-ai'
refuse \( -name 'devs.hpp' -o -name 'dev.hpp' \)
# Aucun binaire Mach-O du paquet ne doit dépendre du SDK (otool -L).
while IFS= read -r -d '' FILE; do
    MAGIC="$(head -c 4 "$FILE" | xxd -p)"
    case "$MAGIC" in
        cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|cafebabf) ;;
        *) continue ;;
    esac
    if /usr/bin/otool -L "$FILE" 2>/dev/null | tail -n +2 | grep -q libdev; then
        echo "dépend du SDK OBSBOT : ${FILE#"$APP"/}" >&2
        STATUS=1
    fi
done < <(find "$APP" -type f -print0)
if [ "$STATUS" -eq 0 ]; then
    echo "ok : ni SDK OBSBOT, ni ses en-têtes, ni binaire obsbot-ai, ni dépendance au SDK dans le paquet"
fi
exit "$STATUS"
```

Remplacer tout le contenu de `mac/app/project.yml` par :

```yaml
# Projet Xcode de PTZBot pour Mac, généré par xcodegen (le .xcodeproj n'est pas versionné).
# Générer : cd mac/app && xcodegen
name: PTZBot
options:
  bundleIdPrefix: io.github.djoko-cli
  deploymentTarget:
    macOS: "15.0"
  # Région de développement anglaise : un Mac dans une autre langue que le français affiche l'anglais
  # (spec distribution § 7.1). Les textes source restent en français, dans les catalogues.
  developmentLanguage: en
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    ENABLE_USER_SCRIPT_SANDBOXING: YES
    # Mac Apple Silicon seulement, comme ptzd.
    ARCHS: arm64
    # Textes : catalogues .xcstrings (français, langue source, et anglais), tenus à la main.
    LOCALIZATION_PREFERS_STRING_CATALOGS: YES
    STRING_CATALOG_GENERATE_SYMBOLS: NO
packages:
  PTZBotKit:
    path: PTZBotKit
  # Sparkle 2 : les mises à jour de l'app, à une version figée (spec distribution § 5.1).
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    exactVersion: 2.10.0
targets:
  PTZBot:
    type: application
    platform: macOS
    sources:
      - PTZBot
    dependencies:
      - package: PTZBotKit
      - package: Sparkle
    info:
      path: PTZBot/Info.plist
      properties:
        CFBundleDisplayName: PTZBot
        CFBundleDevelopmentRegion: en
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        # Dans la barre des menus seulement, sans icône dans le Dock.
        LSUIElement: true
        # ptzd, enfant de l'app, écoute et s'annonce sur le réseau local (spec ptzd dans l'app § 4.2).
        # Traduit dans InfoPlist.xcstrings.
        NSLocalNetworkUsageDescription: PTZBot accepte les connexions des iPhone appairés sur votre réseau local.
        NSBonjourServices:
          - _nacelle._tcp
        # Mises à jour (Sparkle 2) : le flux des versions publiées et la clé publique Ed25519 (réglages
        # ci-dessous) ; recherche au lancement puis toutes les 24 h, téléchargement et installation automatiques.
        # Pas de bac à sable, donc pas de service d'installation de Sparkle (SUEnableInstallerLauncherService).
        SUFeedURL: $(FLUX_MISES_A_JOUR)
        SUPublicEDKey: $(CLE_MISES_A_JOUR)
        SUEnableAutomaticChecks: true
        SUAutomaticallyUpdate: true
        SUScheduledCheckInterval: 86400
        # La signature Ed25519 est exigée avant l'extraction, sans repli sur la signature de code : sans cette clé,
        # Sparkle 2 accepterait aussi une mise à jour dont la signature de code satisfait l'exigence de l'app en
        # place, ce que permet la clé du certificat auto-signé.
        SUVerifyUpdateBeforeExtraction: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.github.djoko-cli.ptzbot
        PRODUCT_NAME: PTZBot
        # La version publiée (outils/publier.sh) ; le numéro de compilation, que compare Sparkle, est donné à la
        # publication : le nombre de commits de main. Une compilation de travail garde 1 : Sparkle n'y démarre pas.
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"
        # Le flux des mises à jour (appcast.xml du dépôt, que publier.sh tient à jour, à son adresse brute) et la clé
        # publique ; la répétition les remplace en ligne de commande.
        FLUX_MISES_A_JOUR: https://raw.githubusercontent.com/Djoko-cli/obsbot-nacelle/main/mac/app/appcast.xml
        CLE_MISES_A_JOUR: nRIVHOXbEktqGduJ4ukxhjZzlUaiE/yqR3sgbW9Ie6E=
        # Pas de bac à sable : l'app lit la configuration de ptzd et le lance.
        ENABLE_APP_SANDBOX: NO
        # Signature locale (ad hoc) ; seule la publication signe avec le certificat, runtime renforcé compris
        # (outils/publier.sh).
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_STYLE: Manual
        # La phase des utilitaires compile mac/ptzd et copie la source d'obsbot-ai.
        ENABLE_USER_SCRIPT_SANDBOXING: NO
    postBuildScripts:
      # ptzd dans Contents/Helpers, la source d'obsbot-ai dans Contents/Resources ; jamais le SDK ni un binaire
      # obsbot-ai dans le paquet (spec distribution § 5.1). Toujours exécutée : swift build sait ce qui a changé
      # dans mac/ptzd.
      - name: Utilitaire ptzd et source d'obsbot-ai
        script: '"$SRCROOT/build-helpers.sh"'
        basedOnDependencyAnalysis: false
        inputFiles:
          - $(SRCROOT)/build-helpers.sh
          - $(SRCROOT)/../ai/main.cpp
        outputFiles:
          - $(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/ptzd
          - $(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/obsbot-ai.cpp
schemes:
  PTZBot:
    build:
      targets:
        PTZBot: all
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/app/PTZBotKit && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' | grep -v appintents && ./check-bundle.sh)
```

Attendu : tout passe (PTZBotKit : 165 tests, « ** BUILD SUCCEEDED ** » pour l'app, puis les trois lignes « ok : » de `check-bundle.sh`), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add mac/app/PTZBot/AppText.swift \
    mac/app/PTZBot/DevicesView.swift \
    mac/app/PTZBot/InfoPlist.xcstrings \
    mac/app/PTZBot/Localizable.xcstrings \
    mac/app/PTZBot/PTZBotApp.swift \
    mac/app/PTZBot/PairingView.swift \
    mac/app/PTZBot/PanelView.swift \
    mac/app/PTZBot/SDKView.swift \
    mac/app/PTZBot/SettingsView.swift \
    mac/app/PTZBot/SparkleUpdater.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings \
    mac/app/PTZBotKit/Sources/PTZBotKit/ServiceLabels.swift \
    mac/app/PTZBotKit/Sources/PTZBotKit/Updater.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/AppCatalogTests.swift \
    mac/app/PTZBotKit/Tests/PTZBotKitTests/UpdaterTests.swift \
    mac/app/build-helpers.sh \
    mac/app/check-bundle.sh \
    mac/app/project.yml
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|8\.8\.8\.8|256\.0\.0\.1|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
B2 : l'app avec Sparkle, la fenetre Reglages et ses textes bilingues

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés plus haut sont déjà indexés par `git rm`.

### Tâche 4 : Outils de publication repris de maillage-thread

**But :** `outils/publication.py` et `outils/publier.sh` sont repris de maillage-thread avec leurs tests, puis adaptés selon la spec : sans bac à sable, utilitaires signés et relus, contenu interdit refusé dans le DMG, vérification de fuite mot par mot, et révision de Sparkle vérifiée. Les deux autres ajouts sont `--notes` et les notes de version bilingues, `NOTES-VERSIONS.md` (spec B2 § 5 et § 12).

**Fichiers :**
- Modifier : `.gitignore`
- Créer : `NOTES-VERSIONS.md`
- Modifier : `mac/app/build-helpers.sh`
- Créer : `outils/Sparkle-LICENSE.txt`
- Créer : `outils/publication.py`
- Créer : `outils/publier.sh`
- Créer : `outils/tests/test_publication.py`

**Interfaces :**
- `outils/publier.sh X.Y.Z [--sans-bureau]` publie, et `--repetition DOSSIER --url-base URL [--cle-privee F --cle-publique C] [--trousseau T]` répète.
- L'identité est « Djoko-cli Code Signing », cherchée par son empreinte. `SPARKLE_BIN` et `DD` sont des variables d'environnement.
- Produits : `mac/app/build/publication/X.Y.Z/`, avec `gestes.txt` pour la reprise.
- Tests : `/usr/bin/python3 -m unittest discover -s outils/tests`.

- [ ] **Étape 1 : Écrire les tests**

Créer `outils/tests/test_publication.py` :

```python
"""Tests de publication.py (repris de maillage-thread, plus ceux des adaptations a PTZBot : sans bac a sable, les
utilitaires signes, le contenu interdit du .dmg, le controle de fuite et la disposition du depot) : les numeros, les
notes, le flux appcast.xml a partir de valeurs inventees (nouveau, ou
une version de plus en tete d'un flux qui les garde toutes, dans l'ordre des versions), les etiquettes propres a l'app,
les controles avant publication et juste avant les gestes publics, leur ordre, le commit du flux et son auteur, la
compilation sans chemin personnel, la signature du code et son certificat, le contenu du .dmg (licence de Sparkle
comprise), la notarisation (desactivee par defaut), sur un faux depot et de fausses commandes (xcodebuild, codesign,
security, openssl, ditto, hdiutil, sign_update, xcrun, gh...). Aucun reseau, aucun trousseau, aucun outil reel hors
git ; HOME est un dossier temporaire, et le nom du compte, invente (USER, LOGNAME) ; le PATH est restreint a /usr/bin et
/bin (ni gh, ni sign_update, ni generate_keys) et git n'accepte que le protocole file (GIT_ALLOW_PROTOCOL).

  /usr/bin/python3 -m unittest discover -s <dossier de ces tests>
"""
import contextlib
import datetime
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import xml.etree.ElementTree as ET
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import publication as P  # noqa: E402

CLE = 'p7jaASHZk/U9YboWWSgw+Z4xEGYXOfUUhTKtZG7uQlE='
IDENTITE = 'Essai Inventee Signing'
EMPREINTE = 'A1B2C3D4E5F60718293A4B5C6D7E8F9012345678'
AUTRE_EMPREINTE = '0F1E2D3C4B5A69788796A5B4C3D2E1F00F1E2D3C'
COMPTE = 'compte-invente'
AUTRE_CLE = 'lkPxEHj5erw+omLlr1AVsIoyhfz4YnoLa/N9147SNgc='
# Aucune vraie commande reseau ne peut partir : git ne parle que le protocole file, et le PATH ne porte ni gh, ni les
# outils de Sparkle, ni xcodegen (les fausses commandes sont donnees par leur chemin, par l'environnement).
PATH_ISOLE = '/usr/bin:/bin'
# Des donnees locales inventees pour le controle de fuite, ecrites en morceaux : ce fichier passe lui-meme le controle
# des commits de ce depot (une adresse hors de la liste autorisee, un nom Tailscale, des chemins personnels).
ADRESSE = '203.0.113' + '.7'
NOM_TAILSCALE = 'ordi.reel.ts' + '.net'
TEMPORAIRE = '/private' + '/tmp/'
AUTRE_COMPTE = '/Us' + 'ers/autre'
OID_RSA = '.'.join(['1', '2', '840', '113549', '1', '1', '11'])
OID_APPLE = 'field.' + '.'.join(['1', '2', '840', '113635', '100', '6', '2', '6'])
GIT_ENV = dict(os.environ, PATH=PATH_ISOLE, GIT_ALLOW_PROTOCOL='file',
               GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null',
               GIT_AUTHOR_NAME='Essai', GIT_AUTHOR_EMAIL='essai@example.invalid',
               GIT_COMMITTER_NAME='Essai', GIT_COMMITTER_EMAIL='essai@example.invalid')


def projet(chemin_flux='appcast.xml', systeme='26.0'):
    return textwrap.dedent('''\
        name: Essai
        options:
          bundleIdPrefix: fr.exemple
          deploymentTarget:
            macOS: "%s"
        targets:
          Compagnon:
            type: application
            settings:
              base:
                MARKETING_VERSION: "1.0"
          Essai:
            type: application
            settings:
              base:
                PRODUCT_NAME: Essai Inventee
                MARKETING_VERSION: "1.2.3"
                CURRENT_PROJECT_VERSION: "1"
                FLUX_MISES_A_JOUR: https://raw.githubusercontent.com/Exemple/essai/main/%s
                CLE_MISES_A_JOUR: %s
        ''' % (systeme, chemin_flux, CLE))


PROJET = projet()

NOTES = textwrap.dedent('''\
    # Notes de version · Release notes

    ## 1.2.3

    **Français**

    - Une `commande` <nouvelle>,
      sur deux lignes.

    **English**

    - A new `command`.

    ## 1.2.2

    - Ancienne.
    ''')

# Les fausses commandes : elles notent leurs arguments dans FAUX_JOURNAL.
FAUX = {
    'xcodegen': 'import sys\n',
    'codesign': textwrap.dedent('''\
        a = sys.argv[1:]
        # Un utilitaire (Contents/Helpers) relu apres la signature : ses droits (aucun, ou FAUX_UTILITAIRE=droits) et
        # ses drapeaux (runtime, ou FAUX_UTILITAIRE=sans-runtime).
        if a and "/Helpers/" in a[-1] and a[:1] == ["-d"]:
            cas = os.environ.get("FAUX_UTILITAIRE", "")
            if a[1:4] == ["--entitlements", "-", "--xml"]:
                import plistlib
                sys.stdout.buffer.write(plistlib.dumps({"com.apple.security.get-task-allow": True}) if cas == "droits" else b"")
            elif a[1:2] == ["-dv"] or a[:1] == ["-dv"]:
                pass
            sys.exit(0)
        if a[:1] == ["-dv"] and "/Helpers/" in a[-1]:
            drapeaux = "0x0(none)" if os.environ.get("FAUX_UTILITAIRE") == "sans-runtime" else "0x10000(runtime)"
            sys.stderr.write("Executable=" + a[-1] + "\\nCodeDirectory v=20500 size=1 flags=" + drapeaux + " hashes=1+0\\n")
            sys.exit(0)
        if a[:2] == ["-d", "-r-"]:
            print('designated => identifier "fr.exemple.essai" and certificate leaf = H"0123abcd"')
        # Une signature par --entitlements : ses droits sont gardes, et rendus a la relecture.
        etat = os.environ["FAUX_JOURNAL"] + ".droits"
        if a[:1] == ["--force"] and "--entitlements" in a:
            open(etat, "wb").write(open(a[a.index("--entitlements") + 1], "rb").read())
        # Les droits de l'app : ceux que Xcode a poses, ou ceux de la signature ; alteres par FAUX_DROITS.
        if a[:4] == ["-d", "--entitlements", "-", "--xml"]:
            import plistlib
            cas = os.environ.get("FAUX_DROITS", "")
            signee = os.path.exists(etat)
            droits = {"com.apple.security.app-sandbox": cas != "bac-a-sable-faux",
                      "com.apple.security.network.client": True,
                      "com.apple.security.temporary-exception.mach-lookup.global-name":
                          {"en-trop": ["fr.exemple.essai-spks", "fr.exemple.essai-spki", "com.exemple.autre"],
                           "manquant": ["fr.exemple.essai-spks"],
                           "autre-identifiant": ["fr.exemple.autre-spks", "fr.exemple.autre-spki"]}.get(
                              cas, ["fr.exemple.essai-spks", "fr.exemple.essai-spki"])}
            if cas == "sans-bac-a-sable":
                del droits["com.apple.security.app-sandbox"]
            # L'app de PTZBot, sans bac a sable : Xcode ne pose aucun droit ; ou un seul des deux restes.
            sans = {"aucun": {}, "bac-a-sable-seul": {"com.apple.security.app-sandbox": True},
                    "mach-lookup-seul": {"com.apple.security.temporary-exception.mach-lookup.global-name":
                                         ["fr.exemple.essai-spks"]},
                    "aucun-get-task-allow": {"com.apple.security.get-task-allow": True},
                    "aucun-dyld": {"com.apple.security.cs.allow-dyld-environment-variables": True}}
            if cas in sans:
                droits = sans[cas]
            if cas == "get-task-allow":
                droits["com.apple.security.get-task-allow"] = True
            if cas == "validation-levee":
                droits["com.apple.security.cs.disable-library-validation"] = True
            if cas == "validation-fausse":
                droits["com.apple.security.cs.disable-library-validation"] = False
            if cas == "variables-dyld":
                droits["com.apple.security.cs.allow-dyld-environment-variables"] = True
            if signee:
                droits = plistlib.load(open(etat, "rb"))
                if cas == "sans-validation":
                    droits.pop("com.apple.security.cs.disable-library-validation", None)
                if cas == "validation-fausse" and "com.apple.security.cs.disable-library-validation" in droits:
                    droits["com.apple.security.cs.disable-library-validation"] = False
            vide = (cas == "illisibles" and signee) or (cas == "aucun" and not signee)
            sys.stdout.buffer.write(b"" if vide else plistlib.dumps(droits))
        extraire = a[:1] == ["-d"] and a[1].startswith("--extract-certificates=")
        if extraire and not os.environ.get("FAUX_SANS_CERTIFICAT"):
            open(a[1].split("=", 1)[1] + "0", "wb").write(b"FEUILLE")
        '''),
    'security': textwrap.dedent('''\
        a = sys.argv[1:]
        nom = os.environ.get("FAUSSE_IDENTITE", "%(identite)s")
        if a[0] == "find-identity":
            ligne = '  1) %(empreinte)s "%%s" (CSSMERR_TP_NOT_TRUSTED)' %% nom
            print("Policy: Code Signing\\n  Matching identities\\n" + ligne)
            if os.environ.get("FAUSSE_IDENTITE_DOUBLE"):
                print('  2) %(autre)s "%%s"' %% nom)
            print("     identities found\\n\\nValid identities only\\n" + ligne + "\\n     1 valid identities found")
        elif a[0] == "find-certificate":
            sha1 = "%(autre)s" if os.environ.get("FAUX_CERTIFICAT_ABSENT") else "%(empreinte)s"
            print("SHA-256 hash: " + "AB" * 32 + "\\nSHA-1 hash: " + sha1)
            print("-----BEGIN CERTIFICATE-----\\nRkFVWA==\\n-----END CERTIFICATE-----")
        ''' % {'identite': IDENTITE, 'empreinte': EMPREINTE, 'autre': AUTRE_EMPREINTE}),
    'openssl': textwrap.dedent('''\
        a = sys.argv[1:]
        feuille = "-in" in a
        sujet = os.environ.get("FAUX_SUJET_FEUILLE" if feuille else "FAUX_SUJET", "C=FR,CN=%(identite)s")
        empreinte = os.environ.get("FAUSSE_EMPREINTE_FEUILLE", "%(empreinte)s") if feuille else "%(empreinte)s"
        if "-text" in a:
            print("Certificate:\\n    Data:\\n        Subject: " + sujet.replace(",", ", "))
            if os.environ.get("FAUX_SAN"):
                print("        X509v3 Subject Alternative Name:\\n            DNS:exemple.invalid")
            if os.environ.get("FAUX_EMETTEUR"):
                print("        Issuer: CN=Autre, emailAddress=x@exemple.invalid")
        else:
            print("subject= " + sujet)
            print("SHA1 Fingerprint=" + ":".join(empreinte[i:i + 2] for i in range(0, 40, 2)))
        ''' % {'identite': IDENTITE, 'empreinte': EMPREINTE}),
    'xcrun': 'import sys\n',
    # otool -L simule : le binaire depend de libdev s'il porte ce mot (FAUX_LIBDEV).
    'otool': textwrap.dedent('''\
        p = sys.argv[-1]
        print(p + ":")
        print("\\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)")
        if b"libdev" in open(p, "rb").read():
            print("\\t@rpath/libdev.dylib (compatibility version 1.0.0)")
        '''),
    'spctl': 'import sys\n',
    'ditto': 'import shutil\nshutil.copytree(sys.argv[1], sys.argv[2], symlinks=True)\n',
    'xcodebuild': textwrap.dedent('''\
        import plistlib, re
        a = sys.argv[1:]
        dd = a[a.index('-derivedDataPath') + 1]
        reglages = dict(x.split('=', 1) for x in a if '=' in x and not x.startswith('-'))
        projet = open('project.yml').read()
        def lu(nom):
            return reglages.get(nom) or re.search(r'  Essai:\\n(?:.*\\n)*?\\s+%s: "?([^"\\n]+)"?' % nom, projet).group(1)
        def fichier(chemin, contenu, mode=0o644):
            os.makedirs(os.path.dirname(chemin), exist_ok=True)
            open(chemin, 'wb').write(contenu)
            os.chmod(chemin, mode)
        app = os.path.join(dd, 'Build', 'Products', 'Release', 'Essai Inventee.app', 'Contents')
        os.makedirs(app, exist_ok=True)
        # Le code imbrique, comme celui de Sparkle : deux services XPC, une app, un executable, puis un autre cadre.
        b = os.path.join(app, 'Frameworks', 'Sparkle.framework', 'Versions', 'B')
        for d in ('XPCServices/Installer.xpc/Contents', 'XPCServices/Downloader.xpc/Contents', 'Updater.app/Contents'):
            os.makedirs(os.path.join(b, d), exist_ok=True)
        # Un chemin personnel injecte (FAUX_CHEMIN = quoi:ou), comme la table OSO ou un #filePath.
        perso = {'home': os.environ['HOME'] + '/Library/Essai/x.o', 'users': os.environ['COMPTE_ETRANGER'] + '/x.o',
                 'compte': 'build-' + os.environ.get('USER', '') + '-x'}
        quoi, _, ou = os.environ.get('FAUX_CHEMIN', ':').partition(':')
        def contenu(ici, base):
            return base + (b'\\0' + perso[quoi].encode() + b'\\0' if ou == ici else b'')
        fichier(os.path.join(b, 'Autoupdate'), contenu('autoupdate', b'autoupdate invente'), 0o755)
        fichier(os.path.join(b, 'Sparkle'), contenu('sparkle', b'sparkle invente'), 0o755)
        if not os.path.lexists(os.path.join(b, '..', 'Current')):
            os.symlink('B', os.path.join(b, '..', 'Current'))
        os.makedirs(os.path.join(app, 'Frameworks', 'Coeur.framework', 'Versions', 'A'), exist_ok=True)
        fichier(os.path.join(app, 'MacOS', 'Essai Inventee'), contenu('app', b'binaire invente'), 0o755)
        # L'utilitaire, comme ptzd : Contents/Helpers, executable ; un fichier non executable a cote n'est pas signe.
        # ptzd simule est un « Mach-O » (ses quatre premiers octets) : otool -L le lit.
        fichier(os.path.join(app, 'Helpers', 'ptzd'), contenu('ptzd', b'\\xcf\\xfa\\xed\\xfe ptzd invente'), 0o755)
        # Un element de trop dans Contents/Helpers (FAUX_UTILITAIRE_EN_TROP = non-executable ou lien).
        en_trop = os.environ.get('FAUX_UTILITAIRE_EN_TROP')
        if en_trop == 'non-executable':
            fichier(os.path.join(app, 'Helpers', 'LISEZMOI'), b'pas du code')
        elif en_trop == 'lien' and not os.path.lexists(os.path.join(app, 'Helpers', 'lien')):
            os.symlink('ptzd', os.path.join(app, 'Helpers', 'lien'))
        # Un binaire Mach-O qui depend du SDK (FAUX_LIBDEV) : refuse au controle du contenu.
        if os.environ.get('FAUX_LIBDEV'):
            fichier(os.path.join(app, 'Resources', 'outil'), b'\\xcf\\xfa\\xed\\xfe @rpath/libdev.dylib', 0o755)
        # Ce que le .dmg ne doit jamais porter (FAUX_INTERDIT = chemin dans Contents).
        if os.environ.get('FAUX_INTERDIT'):
            fichier(os.path.join(app, os.environ['FAUX_INTERDIT']), b'interdit', 0o755)
        fichier(os.path.join(app, 'Resources', 'fr.lproj', 'Localizable.strings'), contenu('ressource', b'"a" = "b";'))
        lien = os.path.join(app, 'Resources', 'lien')
        if os.path.lexists(lien):
            os.remove(lien)
        if os.environ.get('FAUX_LIEN'):
            os.symlink(perso['home'], lien)
        # Un lien dont le nom et la cible ne sont dans aucun contenu de fichier (FAUX_LIEN_NOM_CIBLE = nom:cible).
        nom_lien, _, cible_lien = os.environ.get('FAUX_LIEN_NOM_CIBLE', ':').partition(':')
        if nom_lien:
            autre = os.path.join(app, 'Resources', nom_lien)
            if os.path.lexists(autre):
                os.remove(autre)
            os.symlink(cible_lien, autre)
        # Une donnee locale (FAUX_FUITE = texte:ou), pour le controle de fuite.
        fuite, _, ou_fuite = os.environ.get('FAUX_FUITE', ':').partition(':')
        if fuite:
            cible = {'app': os.path.join('MacOS', 'Essai Inventee'), 'sparkle': os.path.join(b, 'Sparkle'),
                     'ressource': os.path.join('Resources', 'fr.lproj', 'Localizable.strings')}[ou_fuite]
            with open(os.path.join(app, cible), 'ab') as f:
                f.write(b'\\0' + fuite.encode() + b'\\0')
        cle = AUTRE if os.environ.get('FAUX_INFO') == 'cle' else lu('CLE_MISES_A_JOUR')
        plistlib.dump({'CFBundleIdentifier': 'fr.exemple.essai', 'CFBundleShortVersionString': lu('MARKETING_VERSION'),
                       'CFBundleVersion': reglages['CURRENT_PROJECT_VERSION'],
                       'SUFeedURL': lu('FLUX_MISES_A_JOUR'), 'SUPublicEDKey': cle,
                       'SUVerifyUpdateBeforeExtraction': os.environ.get('FAUX_INFO') != 'sans-verification'},
                      open(os.path.join(app, 'Info.plist'), 'wb'))
        ''').replace('AUTRE', repr(AUTRE_CLE)),
    # Le .dmg simule : ses arguments, puis la liste du dossier source (avec la cible des liens).
    'hdiutil': textwrap.dedent('''\
        a = sys.argv[1:]
        src = a[a.index('-srcfolder') + 1]
        lignes = ['dmg invente ' + ' '.join(a)]
        for r, ds, fs in os.walk(src):
            for n in sorted(ds + fs):
                p = os.path.join(r, n)
                lignes.append(os.path.relpath(p, src) + (' -> ' + os.readlink(p) if os.path.islink(p) else ''))
        open(a[-1], 'w').write('\\n'.join(lignes) + '\\n')
        '''),
    'sign_update': 'print("U0lHTkFUVVJFLUlOVkVOVEVF")\n',
    'generate_keys': 'print(os.environ["FAUSSE_CLE"])\n',
    # GitHub simule : release view (« release not found », ou FAUX_VUE, ou publiee), auth status, et release create,
    # qui note l'etat de l'origine a ce moment, puis cree l'etiquette sur la cible, comme GitHub ; FAUX_ECHEC_CREATE=1
    # echoue avant de creer, =apres echoue apres (la version existe, la reponse est perdue).
    'gh': textwrap.dedent('''\
        import subprocess
        a = sys.argv[1:]
        if a[:2] == ['release', 'view']:
            if os.environ.get('FAUX_PUBLIEE'):
                sys.exit(0)
            sys.stderr.write(os.environ.get('FAUX_VUE', 'release not found') + '\\n')
            sys.exit(1)
        if a[:2] == ['auth', 'status']:
            sys.exit(1 if os.environ.get('FAUX_AUTH_ECHEC') else 0)
        if a[:2] == ['release', 'create']:
            origine = os.environ['FAUSSE_ORIGINE']
            main = subprocess.run(['git', '-C', origine, 'rev-parse', 'main'], capture_output=True, text=True)
            open(os.environ['FAUX_JOURNAL'], 'a').write('origine au moment de la publication ' + main.stdout)
            echec = os.environ.get('FAUX_ECHEC_CREATE')
            if echec == '1':
                sys.exit(1)
            subprocess.run(['git', '-C', origine, 'tag', a[2], a[a.index('--target') + 1]], check=True)
            if echec == 'apres':
                sys.stderr.write('connexion perdue apres la creation\\n')
                sys.exit(1)
        '''),
}


def lire(chemin):
    with open(chemin, encoding='utf-8') as f:
        return f.read()


def ecrire(chemin, texte):
    os.makedirs(os.path.dirname(chemin) or '.', exist_ok=True)
    with open(chemin, 'w', encoding='utf-8') as f:
        f.write(texte)


def git(depot, *args):
    return subprocess.run(['git', '-C', depot] + list(args), check=True, capture_output=True, text=True,
                          env=GIT_ENV).stdout.strip()


class Monde:
    """Un faux depot (et son origine), de fausses commandes, un dossier de produits, un dossier personnel. L'app est
    a la racine du depot (sous='.'), ou dans un sous-dossier, comme celle du pont (sous='apps/macos')."""

    def __init__(self, racine, sous='.', systeme='26.0'):
        self.racine = racine
        self.bin = os.path.join(racine, 'bin')
        self.journal = os.path.join(racine, 'journal.txt')
        os.makedirs(self.bin)
        for nom, corps in FAUX.items():
            chemin = os.path.join(self.bin, nom)
            ecrire(chemin, '#!/usr/bin/python3\nimport os, sys\n'
                           'open(os.environ["FAUX_JOURNAL"], "a").write(%r + " " + " ".join(sys.argv[1:]) + "\\n")\n'
                           % nom + corps)
            os.chmod(chemin, 0o755)
        self.maison = os.path.join(racine, 'maison')
        os.makedirs(os.path.join(self.maison, 'Desktop'))
        self.licence = os.path.join(racine, 'licence', 'Sparkle-LICENSE.txt')
        ecrire(self.licence, 'Licence inventee de Sparkle, pour les tests.\n')
        self.origine = os.path.join(racine, 'origine.git')
        self.depot = os.path.join(racine, 'depot')
        self.sous = sous
        self.app = os.path.normpath(os.path.join(self.depot, sous))
        self.chemin_flux = os.path.normpath(os.path.join(sous, 'appcast.xml'))
        subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', self.origine], check=True, env=GIT_ENV)
        subprocess.run(['git', 'clone', '-q', self.origine, self.depot], check=True, env=GIT_ENV,
                       capture_output=True)
        git(self.depot, 'config', 'user.name', 'Essai')
        git(self.depot, 'config', 'user.email', '0+essai@users.noreply.github.com')
        git(self.depot, 'checkout', '-q', '-b', 'main')
        ecrire(os.path.join(self.app, 'project.yml'), projet(self.chemin_flux, systeme))
        ecrire(os.path.join(self.app, 'NOTES-VERSIONS.md'), NOTES)
        ecrire(os.path.join(self.depot, '.gitignore'), 'build/\n')
        for i in range(3):
            ecrire(os.path.join(self.depot, 'f%d.txt' % i), '%d\n' % i)
            git(self.depot, 'add', '-A')
            git(self.depot, 'commit', '-q', '-m', 'commit %d' % i)
        git(self.depot, 'push', '-q', 'origin', 'main')
        self.dd = os.path.join(racine, 'dd')
        self.dit = ''
        self.env = {'GIT': 'git', 'XCODEGEN': self.bin + '/xcodegen', 'XCODEBUILD': self.bin + '/xcodebuild',
                    'HDIUTIL': self.bin + '/hdiutil', 'DITTO': self.bin + '/ditto', 'CODESIGN': self.bin + '/codesign',
                    'GH': self.bin + '/gh', 'SECURITY': self.bin + '/security', 'OPENSSL': self.bin + '/openssl',
                    'XCRUN': self.bin + '/xcrun', 'SPCTL': self.bin + '/spctl', 'SPARKLE_BIN': self.bin,
                    'OTOOL': self.bin + '/otool'}

    def appels(self):
        return lire(self.journal).splitlines() if os.path.exists(self.journal) else []

    def oublier(self):
        """Un journal neuf, pour un cas de plus dans le meme monde."""
        for f in (self.journal, self.journal + '.droits'):
            if os.path.exists(f):
                os.remove(f)

    def arguments(self, *extra, bureau=False):
        return ['publier', '1.2.3', '--nom-app', 'Essai Inventee', '--fichier', 'Essai-Inventee',
                '--depot-github', 'Exemple/essai', '--projet', 'Essai.xcodeproj', '--schema', 'Essai',
                '--cible', 'Essai', '--textes', 'project.yml', '--identite', IDENTITE, '--auteur', 'Essai',
                '--etiquette', 'essai-v', '--flux', 'appcast.xml', '--licence', self.licence] \
            + ([] if bureau else ['--sans-bureau']) + list(extra)

    def environnement(self, env):
        # Sans GIT_AUTHOR_* ni GIT_COMMITTER_* : le commit du flux prend l'auteur de la configuration du depot.
        e = {k: v for k, v in GIT_ENV.items() if not k.startswith(('GIT_AUTHOR', 'GIT_COMMITTER'))}
        e.update(FAUX_JOURNAL=self.journal, FAUSSE_CLE=CLE, DD=self.dd, FAUSSE_ORIGINE=self.origine, COMPTE_ETRANGER=AUTRE_COMPTE,
                 HOME=self.maison, USER=COMPTE, LOGNAME=COMPTE)
        e.update(env or {})
        return e

    def publier(self, *extra, env=None, bureau=False):
        dedans = os.getcwd()
        os.chdir(self.app)
        sortie = io.StringIO()
        try:
            with mock.patch.dict(os.environ, self.environnement(env), clear=True), contextlib.redirect_stdout(sortie):
                return P.publier(P.arguments(self.arguments(*extra, bureau=bureau)), P.Outils(self.env),
                                 maintenant=datetime.datetime(2026, 10, 6, 12, 0, 0))
        finally:
            self.dit = sortie.getvalue()
            os.chdir(dedans)

    def main(self, *extra, env=None):
        """publication.main, les outils lus dans l'environnement : le code de sortie et ce qui va sur stderr."""
        dedans = os.getcwd()
        os.chdir(self.app)
        erreurs = io.StringIO()
        try:
            e = self.environnement(env)
            e.update(self.env)
            e.update(env or {})
            with mock.patch.dict(os.environ, e, clear=True), contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(erreurs):
                code = P.main(self.arguments(*extra))
        finally:
            os.chdir(dedans)
        return code, erreurs.getvalue()


class NumerosTests(unittest.TestCase):
    def test_version_valide(self):
        self.assertTrue(P.version_valide('1.0.0'))
        self.assertTrue(P.version_valide('12.30.4'))
        for v in ('1.0', 'v1.0.0', '1.0.0-beta', '1.0.0 ', ''):
            self.assertFalse(P.version_valide(v), v)

    def test_versions_comparees_en_nombres(self):
        self.assertGreater(P.nombres('1.10.0'), P.nombres('1.2.3'))
        self.assertGreater(P.nombres('2.0.0'), P.nombres('1.99.99'))
        self.assertEqual(P.nombres('1.0.0'), (1, 0, 0))

    def test_reglages_de_la_cible(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, 'project.yml')
            ecrire(p, PROJET)
            self.assertEqual(P.reglage(p, 'Essai', 'MARKETING_VERSION'), '1.2.3')
            self.assertEqual(P.reglage(p, 'Compagnon', 'MARKETING_VERSION'), '1.0', 'chaque cible la sienne')
            self.assertEqual(P.reglage(p, 'Essai', 'CLE_MISES_A_JOUR'), CLE)
            self.assertEqual(P.systeme_minimum(p), '26.0')
            with self.assertRaises(P.Refus):
                P.reglage(p, 'Absente', 'MARKETING_VERSION')
            with self.assertRaises(P.Refus):
                P.reglage(p, 'Compagnon', 'CLE_MISES_A_JOUR')

    def test_numero_de_compilation(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run(['git', 'init', '-q', d], check=True, env=GIT_ENV)
            for i in range(4):
                git(d, 'commit', '-q', '--allow-empty', '-m', str(i))
            self.assertEqual(P.numero_compilation(d), 4)


class NotesEtFluxTests(unittest.TestCase):
    def test_notes_de_la_version(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, 'NOTES-VERSIONS.md')
            ecrire(p, NOTES)
            n = P.notes(p, '1.2.3')
            self.assertTrue(n.startswith('**Français**'))
            self.assertNotIn('Ancienne', n)
            self.assertEqual(P.notes(p, '1.2.2'), '- Ancienne.\n')
            with self.assertRaises(P.Refus):
                P.notes(p, '9.9.9')

    def test_notes_html(self):
        h = P.notes_html('**Français**\n\n- Une `commande` <nouvelle>,\n  sur deux lignes.\n\n**English**\n\n- B\n')
        self.assertEqual(h, '<meta charset="utf-8">\n<p><strong>Français</strong></p>\n'
                            '<ul><li>Une <code>commande</code> &lt;nouvelle&gt;, sur deux lignes.</li></ul>\n'
                            '<p><strong>English</strong></p>\n<ul><li>B</li></ul>')

    def item(self, version='1.2.3', numero=57):
        return P.item_flux(version, numero, 'https://exemple.invalid/essai-v%s/Essai-Inventee-%s.dmg' % (version, version),
                           123456, 'U0lHTkFUVVJF', '26.0', '<p>Notes</p>', datetime.datetime(2026, 10, 6, 12, 0, 0))

    def test_flux_neuf_valeurs_inventees(self):
        xml = P.ajouter_au_flux(None, 'Essai Inventee', '1.2.3', self.item())
        self.assertEqual(xml, textwrap.dedent('''\
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <title>Essai Inventee</title>
                <item>
                  <title>1.2.3</title>
                  <pubDate>Tue, 06 Oct 2026 12:00:00 +0000</pubDate>
                  <sparkle:version>57</sparkle:version>
                  <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
                  <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
                  <description><![CDATA[
            <p>Notes</p>
            ]]></description>
                  <enclosure url="https://exemple.invalid/essai-v1.2.3/Essai-Inventee-1.2.3.dmg" length="123456" type="application/octet-stream" sparkle:edSignature="U0lHTkFUVVJF"/>
                </item>
              </channel>
            </rss>
            '''))
        s = '{%s}' % P.ESPACE_SPARKLE
        item = ET.fromstring(xml).find('channel/item')
        self.assertEqual(item.find(s + 'version').text, '57')
        self.assertEqual(item.find(s + 'shortVersionString').text, '1.2.3')
        self.assertEqual(item.find('enclosure').get(s + 'edSignature'), 'U0lHTkFUVVJF')
        self.assertEqual(item.find('description').text.strip(), '<p>Notes</p>')

    def test_adresse_et_signature_echappees(self):
        """Une adresse avec & et une signature avec " restent du XML valide, lues telles quelles."""
        item = P.item_flux('1.2.3', 57, 'https://exemple.invalid/a?b=1&c=2', 1, 'S"G', '26.0', '',
                           datetime.datetime(2026, 10, 6))
        enc = ET.fromstring(P.ajouter_au_flux(None, 'Essai & Co', '1.2.3', item)).find('channel/item/enclosure')
        self.assertEqual(enc.get('url'), 'https://exemple.invalid/a?b=1&c=2')
        self.assertEqual(enc.get('{%s}edSignature' % P.ESPACE_SPARKLE), 'S"G')

    def test_une_version_de_plus_en_tete(self):
        """Le flux garde toutes les versions publiees, la nouvelle en tete."""
        un = P.ajouter_au_flux(None, 'Essai Inventee', '1.2.2', self.item('1.2.2', 56))
        deux = P.ajouter_au_flux(un, 'Essai Inventee', '1.2.3', self.item('1.2.3', 57), 57)
        s = '{%s}' % P.ESPACE_SPARKLE
        items = ET.fromstring(deux).findall('channel/item')
        self.assertEqual([i.find(s + 'shortVersionString').text for i in items], ['1.2.3', '1.2.2'])
        self.assertEqual([i.find(s + 'version').text for i in items], ['57', '56'])
        self.assertEqual(deux.replace(self.item('1.2.3', 57), ''), un, 'le reste du flux ne change pas')
        with self.assertRaises(P.Refus):
            P.ajouter_au_flux(deux, 'Essai Inventee', '1.2.2', self.item('1.2.2', 58))

    def test_ordre_des_versions_dans_le_flux(self):
        """Une version n'entre que superieure a la tete, comparee en nombres, et avec un numero superieur."""
        tete = P.ajouter_au_flux(None, 'Essai Inventee', '1.10.0', self.item('1.10.0', 40))
        with self.assertRaises(P.Refus) as r:
            P.verifier_flux(tete, '1.2.3', 57)
        self.assertIn('superieure', str(r.exception))
        with self.assertRaises(P.Refus) as r:
            P.verifier_flux(tete, '1.10.1', 40)
        self.assertIn('numero de compilation', str(r.exception))
        P.verifier_flux(tete, '1.10.1', 41)
        P.verifier_flux(tete, '1.11.0')
        self.assertEqual(P.versions_du_flux(tete), [('1.10.0', 40)])

    def test_flux_mal_forme(self):
        for texte in ('<rss><channel><item>', '<autre/>',
                      '<rss xmlns:sparkle="%s"><channel><item><sparkle:version>3</sparkle:version></item></channel>'
                      '</rss>' % P.ESPACE_SPARKLE):
            with self.subTest(texte=texte), self.assertRaises(P.Refus) as r:
                P.verifier_flux(texte, '1.2.3')
            self.assertIn('illisible', str(r.exception))

    def test_flux_produit_relu(self):
        """Un flux existant ou la nouvelle version ne se placerait pas en tete (retrait inattendu) : refus."""
        un = P.ajouter_au_flux(None, 'Essai Inventee', '1.2.2', self.item('1.2.2', 56))
        decale = un.replace('    <item>', '  <item>')
        with self.assertRaises(P.Refus) as r:
            P.ajouter_au_flux(decale, 'Essai Inventee', '1.2.3', self.item('1.2.3', 57), 57)
        self.assertIn('en tete', str(r.exception))


class CheminsPersonnelsTests(unittest.TestCase):
    def test_motifs_injectes_par_l_environnement(self):
        motifs = P.motifs_personnels({'HOME': '/maison/inventee', 'USER': COMPTE, 'LOGNAME': 'autre-compte'})
        valeurs = [m for m, _ in motifs]
        for attendu in (b'/Users/', b'/maison/inventee', COMPTE.encode(), b'autre-compte'):
            self.assertIn(attendu, valeurs)
        for _, quoi in motifs:
            self.assertNotIn(COMPTE, quoi, 'la description ne recopie jamais la valeur')
            self.assertNotIn('/maison', quoi)

    def test_carte_des_chemins(self):
        """La racine du depot, sous ses deux formes (par un lien, comme /tmp et /private/tmp), ramenee a « . »."""
        with tempfile.TemporaryDirectory() as d:
            vrai = os.path.realpath(os.path.join(d, 'vrai'))
            os.makedirs(vrai)
            lien = os.path.join(d, 'lien')
            os.symlink(vrai, lien)
            self.assertEqual(sorted(P.carte_des_chemins(lien + '/')), sorted([(lien, '.'), (vrai, '.')]))
            self.assertEqual(P.carte_des_chemins(vrai), [(vrai, '.')])
            self.assertEqual(P.carte_des_chemins(''), [])
            self.assertEqual(P.carte_des_chemins('/'), [])

    def test_chemins_personnels(self):
        with tempfile.TemporaryDirectory() as d:
            ecrire(os.path.join(d, 'A.app', 'bin'), 'propre')
            ecrire(os.path.join(d, 'A.app', 'res'), 'x/maison/inventee/y')
            os.symlink(AUTRE_COMPTE, os.path.join(d, 'lien'))
            os.symlink('/Applications', os.path.join(d, 'Applications'))
            trouves = P.chemins_personnels(d, P.motifs_personnels({'HOME': '/maison/inventee', 'USER': COMPTE}))
            self.assertEqual(sorted(t[0] for t in trouves), ['A.app/res', 'lien'])


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.dossier = os.path.realpath(tempfile.mkdtemp())
        self.m = Monde(self.dossier)

    def tearDown(self):
        shutil.rmtree(self.dossier)

    def refuse(self, *extra, env=None, motif, etiquette='', etiquette_origine=''):
        with self.assertRaises(P.Refus) as r:
            self.m.publier(*extra, env=env)
        self.assertIn(motif, str(r.exception))
        appels = self.m.appels()
        self.assertFalse([a for a in appels if a.startswith('gh release create')], 'rien de publie')
        self.assertEqual(git(self.m.depot, 'tag', '-l'), etiquette, 'aucune etiquette nouvelle')
        self.assertEqual(git(self.m.origine, 'tag', '-l'), etiquette_origine, 'rien de pousse')
        self.assertEqual(git(self.m.origine, 'rev-list', '--count', 'main'), self.commits_origine, 'main inchange')
        return appels

    @property
    def commits_origine(self):
        return getattr(self, '_commits_origine', '3')

    def commit(self, fichier, texte):
        ecrire(os.path.join(self.m.app, fichier), texte)
        git(self.m.depot, 'add', '-A')
        git(self.m.depot, 'commit', '-q', '-m', 'changement')
        git(self.m.depot, 'push', '-q', 'origin', 'main')
        self._commits_origine = git(self.m.origine, 'rev-list', '--count', 'main')

    def autre_clone(self, *commandes):
        """Un autre clone de l'origine, qui y pousse quelque chose (comme un autre poste, ou GitHub)."""
        autre = os.path.join(self.dossier, 'autre')
        subprocess.run(['git', 'clone', '-q', self.m.origine, autre], check=True, env=GIT_ENV, capture_output=True)
        for c in commandes:
            git(autre, *c)
        return autre

    def rien_compile(self, appels):
        self.assertFalse([a for a in appels if a.startswith('xcodebuild')], 'rien de compile')

    def lignes_gestes(self, sortie=None):
        """Les lignes de gestes.txt, sans l'horodatage (une liste vide s'il n'existe pas)."""
        chemin = os.path.join(sortie or os.path.join(self.m.depot, 'build', 'publication', '1.2.3'), 'gestes.txt')
        return [l.split(' ', 1)[1] for l in lire(chemin).splitlines()] if os.path.exists(chemin) else []

    def gestes(self, sortie=None):
        """Le premier mot de chaque ligne de gestes.txt, avant « : » : tentative, echec, ou le geste fait."""
        return [l.split(' :')[0] for l in self.lignes_gestes(sortie)]

    # --- la repetition et la publication ---------------------------------------------------------------------

    def test_repetition(self):
        sortie = os.path.join(self.dossier, 'repetition')
        self.m.publier('--repetition', sortie, '--url-base', 'http://127.0.0.1:8123', '--cle-privee', 'cle.txt',
                       '--cle-publique', AUTRE_CLE, '--sans-tests')
        flux = os.path.join(self.m.depot, 'appcast.xml')
        item = ET.parse(flux).getroot().find('channel/item')
        s = '{%s}' % P.ESPACE_SPARKLE
        self.assertEqual(item.find(s + 'version').text, '3', 'trois commits')
        enc = item.find('enclosure')
        self.assertEqual(enc.get('url'),
                         'http://127.0.0.1:8123/Exemple/essai/releases/download/essai-v1.2.3/Essai-Inventee-1.2.3.dmg')
        self.assertEqual(git(self.m.depot, 'log', '-1', '--format=%s'),
                         'Publier Essai Inventee 1.2.3 dans le flux des mises a jour', 'commite dans la copie')
        self.assertEqual(git(self.m.depot, 'status', '--porcelain'), '')
        self.assertEqual(git(self.m.origine, 'rev-list', '--count', 'main'), '3', 'rien de pousse')
        self.assertEqual(enc.get(s + 'edSignature'), 'U0lHTkFUVVJFLUlOVkVOVEVF')
        dmg = os.path.join(sortie, 'Essai-Inventee-1.2.3.dmg')
        self.assertEqual(int(enc.get('length')), os.path.getsize(dmg))
        self.assertIn('-volname Essai Inventee 1.2.3', lire(dmg))
        appels = self.m.appels()
        build = [a for a in appels if a.startswith('xcodebuild')][0]
        for r in ('-configuration Release', 'CURRENT_PROJECT_VERSION=3', 'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM= ',
                  'FLUX_MISES_A_JOUR=http://127.0.0.1:8123/Exemple/essai/main/appcast.xml',
                  'CLE_MISES_A_JOUR=' + AUTRE_CLE):
            self.assertIn(r, build)
        self.assertIn('sign_update --ed-key-file cle.txt -p ' + dmg, appels)
        self.assertFalse([a for a in appels if a.startswith(('gh ', 'generate_keys'))], 'ni GitHub ni trousseau')
        self.assertIn('controle de fuite (5 fichiers) : 0 ligne(s) trouvee(s)', self.m.dit,
                      'les notes, le flux, notes.md, le message du commit et project.yml (--textes)')
        self.assertEqual(git(self.m.depot, 'tag', '-l'), '')
        self.assertEqual(self.gestes(sortie), ['tentative', 'flux commite'], 'le commit du flux seul')

    def test_repetition_avec_la_cle_du_trousseau(self):
        """Sans paire d'essai : la cle publique de project.yml, celle du trousseau, et la signature par le trousseau."""
        sortie = os.path.join(self.dossier, 'repetition')
        self.m.publier('--repetition', sortie, '--url-base', 'http://127.0.0.1:8123', '--sans-tests')
        appels = self.m.appels()
        self.assertIn('generate_keys -p', appels)
        self.assertIn('sign_update -p ' + os.path.join(sortie, 'Essai-Inventee-1.2.3.dmg'), appels)
        build = [a for a in appels if a.startswith('xcodebuild')][0]
        self.assertIn('FLUX_MISES_A_JOUR=http://127.0.0.1:8123/Exemple/essai/main/appcast.xml', build)
        self.assertNotIn('CLE_MISES_A_JOUR=', build, 'la cle de project.yml')
        self.assertFalse([a for a in appels if a.startswith('gh ')])
        self.assertEqual(git(self.m.depot, 'tag', '-l'), '')

    def test_publication(self):
        avant = git(self.m.depot, 'rev-parse', 'HEAD')
        self.m.publier()
        appels = self.m.appels()
        self.assertEqual(git(self.m.origine, 'tag', '-l'), 'essai-v1.2.3', 'etiquette de l\'app, creee par GitHub')
        self.assertEqual(git(self.m.origine, 'rev-parse', 'essai-v1.2.3^{commit}'), avant, 'sur le commit verifie')
        self.assertEqual(git(self.m.depot, 'tag', '-l'), '', 'aucune etiquette locale')
        sortie = os.path.join(self.m.depot, 'build', 'publication', '1.2.3')
        dmg = os.path.join(sortie, 'Essai-Inventee-1.2.3.dmg')
        cree = [a for a in appels if a.startswith('gh release create')]
        self.assertEqual(len(cree), 1)
        self.assertIn('essai-v1.2.3 %s -R Exemple/essai --target %s ' % (dmg, avant), cree[0], 'le .dmg seul')
        self.assertNotIn('--verify-tag', cree[0])
        self.assertIn('--title Essai Inventee 1.2.3', cree[0])
        self.assertIn('--notes-file %s/notes.md' % sortie, cree[0])
        self.assertIn('sign_update -p ' + dmg, appels, 'cle du trousseau')
        # GitHub lu deux fois : avant les tests, puis juste avant les gestes publics.
        self.assertEqual(appels.count('gh release view essai-v1.2.3 -R Exemple/essai'), 2)
        self.assertEqual(appels.count('gh auth status --hostname github.com'), 2)
        # Le flux, dans le depot, commite puis pousse sur main, apres la version publiee.
        flux = lire(os.path.join(self.m.depot, 'appcast.xml'))
        self.assertEqual(git(self.m.origine, 'show', 'main:appcast.xml') + '\n', flux)
        self.assertEqual(git(self.m.origine, 'log', '-1', '--format=%an %ae', 'main'),
                         'Essai 0+essai@users.noreply.github.com', 'l\'auteur du depot, adresse noreply')
        message = git(self.m.origine, 'log', '-1', '--format=%B', 'main')
        self.assertEqual(message, 'Publier Essai Inventee 1.2.3 dans le flux des mises a jour\n\n'
                                  'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>')
        self.assertEqual(git(self.m.origine, 'show', '--name-only', '--format=', 'main'), 'appcast.xml')
        self.assertEqual(git(self.m.depot, 'status', '--porcelain'), '')
        self.assertIn('https://github.com/Exemple/essai/releases/download/essai-v1.2.3/Essai-Inventee-1.2.3.dmg', flux)
        self.assertIn('<li>A new <code>command</code>.</li>', flux)
        with open(os.path.join(self.m.dd, 'Build', 'Products', 'Release', 'Essai Inventee.app', 'Contents',
                               'Info.plist'), 'rb') as f:
            info = plistlib.load(f)
        self.assertEqual(info['CFBundleVersion'], '3')

    def test_ordre_des_gestes_publics(self):
        """La version est publiee avant que le flux l'annonce : au moment de gh release create, main sur GitHub est
        encore le commit verifie. Chaque geste fait est note, dans l'ordre."""
        avant = git(self.m.depot, 'rev-parse', 'HEAD')
        self.m.publier()
        self.assertIn('origine au moment de la publication ' + avant, self.m.appels())
        self.assertNotEqual(git(self.m.origine, 'rev-parse', 'main'), avant, 'le flux, pousse ensuite')
        self.assertEqual(self.gestes(), ['tentative', 'version publiee', 'tentative', 'flux commite', 'tentative',
                                         'flux pousse sur main'], 'chaque geste : la tentative, puis sa reussite')
        gestes = self.lignes_gestes()
        self.assertIn('gh release create essai-v1.2.3 sur ' + avant, gestes[0])
        self.assertIn('essai-v1.2.3, etiquette creee sur ' + avant, gestes[1])
        self.assertIn('appcast.xml (%s)' % git(self.m.depot, 'rev-parse', 'HEAD'), gestes[3], 'le commit du flux')

    def test_echec_de_la_version_publiee(self):
        """gh release create en echec, rien cree : le flux n'est ni commite ni pousse ; gestes.txt note la tentative
        (avant le geste) puis l'echec, jamais « version publiee »."""
        with self.assertRaises(subprocess.CalledProcessError):
            self.m.publier(env={'FAUX_ECHEC_CREATE': '1'})
        self.assertFalse(os.path.exists(os.path.join(self.m.depot, 'appcast.xml')), 'le flux du depot ne change pas')
        self.assertEqual(git(self.m.depot, 'rev-list', '--count', 'HEAD'), '3', 'aucun commit')
        self.assertEqual(git(self.m.origine, 'rev-list', '--count', 'main'), '3', 'origine inchangee')
        self.assertEqual(git(self.m.origine, 'tag', '-l'), '', 'aucune etiquette poussee a part')
        self.assertEqual(git(self.m.depot, 'status', '--porcelain'), '')
        self.assertEqual(self.gestes(), ['tentative', 'echec'], 'ni « version publiee », ni « flux commite »')
        self.assertIn('relancer publier.sh', self.lignes_gestes()[1])

    def test_echec_ambigu_de_la_version_publiee(self):
        """gh release create echoue alors que GitHub a cree la version (la reponse est perdue) : l'etiquette est sur
        GitHub, le flux n'est pas commite, et gestes.txt le dit : echec ambigu, lire GitHub avant de reprendre. Une
        relance refuse d'elle-meme."""
        with self.assertRaises(subprocess.CalledProcessError):
            self.m.publier(env={'FAUX_ECHEC_CREATE': 'apres'})
        self.assertEqual(git(self.m.origine, 'tag', '-l'), 'essai-v1.2.3', 'la version existe malgre l\'erreur')
        self.assertFalse(os.path.exists(os.path.join(self.m.depot, 'appcast.xml')))
        self.assertEqual(git(self.m.depot, 'rev-list', '--count', 'HEAD'), '3', 'aucun commit')
        self.assertEqual(self.gestes(), ['tentative', 'echec'], 'le geste ambigu est note, pas comme fait')
        echec = self.lignes_gestes()[1]
        self.assertIn('peut-etre cree la version', echec)
        self.assertIn('gh release view essai-v1.2.3', echec)
        self.assertIn('git ls-remote --tags origin', echec)
        with self.assertRaises(P.Refus) as r:
            self.m.publier()
        self.assertIn('existe deja sur GitHub', str(r.exception))
        self.assertEqual(self.gestes(), ['tentative', 'echec'], 'la relance refusee ne change pas gestes.txt')

    def test_echec_du_commit_du_flux(self):
        """Apres la version publiee, le commit du flux echoue (un crochet pre-commit refuse) : gestes.txt dit que la
        version est publiee, que le flux ne l'est pas, et ou reprendre ; « flux commite » n'y est pas."""
        crochet = os.path.join(self.m.depot, '.git', 'hooks', 'pre-commit')
        ecrire(crochet, '#!/bin/sh\nexit 1\n')
        os.chmod(crochet, 0o755)
        with self.assertRaises(subprocess.CalledProcessError):
            self.m.publier()
        self.assertEqual(git(self.m.origine, 'tag', '-l'), 'essai-v1.2.3', 'la version est publiee')
        self.assertEqual(git(self.m.origine, 'rev-list', '--count', 'main'), '3', 'le flux n\'est pas pousse')
        self.assertEqual(git(self.m.depot, 'rev-list', '--count', 'HEAD'), '3', 'le flux n\'est pas commite')
        self.assertEqual(self.gestes(), ['tentative', 'version publiee', 'tentative', 'echec'])
        echec = self.lignes_gestes()[3]
        self.assertIn('tentative : commit du flux', self.lignes_gestes()[2])
        for attendu in ('commit du flux', "la version est publiee, le flux ne l'est pas", 'git commit -F message-commit.txt',
                        'git push origin HEAD:main'):
            self.assertIn(attendu, echec)

    def test_echec_du_push_du_flux(self):
        """Le push du flux echoue apres le commit (un crochet pre-receive refuse ; le --dry-run, lui, passe) :
        gestes.txt dit que la version est publiee, le flux commite en local, et reprend au push ; « flux pousse » n'y
        est pas."""
        crochet = os.path.join(self.m.origine, 'hooks', 'pre-receive')
        ecrire(crochet, '#!/bin/sh\nexit 1\n')
        os.chmod(crochet, 0o755)
        with self.assertRaises(subprocess.CalledProcessError):
            self.m.publier()
        self.assertEqual(git(self.m.origine, 'tag', '-l'), 'essai-v1.2.3', 'la version est publiee')
        self.assertEqual(git(self.m.origine, 'rev-list', '--count', 'main'), '3', 'le flux n\'est pas pousse')
        self.assertEqual(git(self.m.depot, 'rev-list', '--count', 'HEAD'), '4', 'le flux est commite en local')
        self.assertEqual(self.gestes(), ['tentative', 'version publiee', 'tentative', 'flux commite', 'tentative',
                                         'echec'])
        echec = self.lignes_gestes()[5]
        self.assertIn('push du flux', self.lignes_gestes()[4])
        for attendu in ('push du flux', 'la version est publiee et le flux est commite en local',
                        'git ls-remote origin refs/heads/main', 'git push origin HEAD:main'):
            self.assertIn(attendu, echec)

    def test_push_du_flux_verifie_sur_github(self):
        """Un push qui reussit sans que main de GitHub arrive au commit du flux (ici, il part ailleurs : pushurl) est
        un echec, note comme tel : « flux pousse sur main » ne l'est qu'apres la verification (ls-remote)."""
        miroir = os.path.join(self.dossier, 'miroir.git')
        subprocess.run(['git', 'clone', '-q', '--bare', self.m.origine, miroir], check=True, env=GIT_ENV)
        git(self.m.depot, 'config', 'remote.origin.pushurl', miroir)
        with self.assertRaises(P.Refus) as r:
            self.m.publier()
        self.assertIn("main de GitHub n'est pas au commit du flux", str(r.exception))
        self.assertEqual(git(miroir, 'rev-parse', 'main'), git(self.m.depot, 'rev-parse', 'HEAD'), 'le push est parti')
        self.assertEqual(git(self.m.origine, 'rev-list', '--count', 'main'), '3')
        self.assertEqual(self.gestes(), ['tentative', 'version publiee', 'tentative', 'flux commite', 'tentative',
                                         'echec'])

    def test_push_du_flux_par_head_main(self):
        """HEAD detache pendant les tests, au commit verifie (la relecture le tolere) : le flux est commite sur HEAD,
        et git push origin main ne pousserait rien. Le push par HEAD:main le pousse, et ls-remote le verifie."""
        self.m.publier('--test', 'git checkout -q --detach')
        flux = git(self.m.depot, 'rev-parse', 'HEAD')
        self.assertEqual(git(self.m.origine, 'rev-parse', 'main'), flux, 'le flux est sur main de GitHub')
        self.assertEqual(git(self.m.origine, 'show', '--name-only', '--format=', 'main'), 'appcast.xml')
        self.assertEqual(self.gestes()[-1], 'flux pousse sur main')

    def test_disposition_de_ptzbot(self):
        """Le cas de ce depot : l'app et son flux dans mac/app, publier.sh lance de la, les notes a la racine du
        depot (--notes), l'app sans bac a sable."""
        m = Monde(os.path.join(self.dossier, 'ptzbot'), sous='mac/app', systeme='15.0')
        os.rename(os.path.join(m.app, 'NOTES-VERSIONS.md'), os.path.join(m.depot, 'NOTES-VERSIONS.md'))
        git(m.depot, 'add', '-A')
        git(m.depot, 'commit', '-q', '-m', 'notes a la racine')
        git(m.depot, 'push', '-q', 'origin', 'main')
        m.publier('--notes', '../../NOTES-VERSIONS.md', '--sans-bac-a-sable', env={'FAUX_DROITS': 'aucun'})
        self.assertEqual(git(m.origine, 'show', '--name-only', '--format=', 'main'), 'mac/app/appcast.xml')
        flux = git(m.origine, 'show', 'main:mac/app/appcast.xml')
        self.assertIn('<li>A new <code>command</code>.</li>', flux)
        sortie = os.path.join(m.app, 'build', 'publication', '1.2.3')
        self.assertIn('**English**', lire(os.path.join(sortie, 'notes.md')))

    def test_app_dans_un_sous_dossier(self):
        """Le cas du pont : l'app et son flux dans apps/macos, macOS 15.0 minimum, publier.sh lance de la."""
        m = Monde(os.path.join(self.dossier, 'pont'), sous='apps/macos', systeme='15.0')
        m.publier()
        flux = git(m.origine, 'show', 'main:apps/macos/appcast.xml')
        item = ET.fromstring(flux).find('channel/item')
        s = '{%s}' % P.ESPACE_SPARKLE
        self.assertEqual(item.find(s + 'minimumSystemVersion').text, '15.0')
        self.assertEqual(git(m.origine, 'show', '--name-only', '--format=', 'main'), 'apps/macos/appcast.xml')
        self.assertTrue(os.path.exists(os.path.join(m.app, 'build', 'publication', '1.2.3',
                                                    'Essai-Inventee-1.2.3.dmg')))
        sortie = os.path.join(self.dossier, 'pont-repetition')
        m.oublier()
        git(m.depot, 'reset', '-q', '--hard', 'HEAD~1')
        m.publier('--repetition', sortie, '--url-base', 'http://127.0.0.1:8123', '--sans-tests')
        build = [a for a in m.appels() if a.startswith('xcodebuild')][0]
        self.assertIn('FLUX_MISES_A_JOUR=http://127.0.0.1:8123/Exemple/essai/main/apps/macos/appcast.xml', build)

    # --- la compilation et le contenu du .dmg ----------------------------------------------------------------

    def test_compilation_sans_symboles_ni_chemins_personnels(self):
        self.m.publier()
        build = [a for a in self.m.appels() if a.startswith('xcodebuild')][0]
        for r in ('DEPLOYMENT_POSTPROCESSING=YES', 'STRIP_INSTALLED_PRODUCT=YES',
                  'OTHER_SWIFT_FLAGS=$(inherited) -file-prefix-map "%s=." ' % self.m.depot,
                  'OTHER_CFLAGS=$(inherited) "-ffile-prefix-map=%s=." ' % self.m.depot):
            self.assertIn(r, build)
        self.assertIn('aucun chemin personnel', self.m.dit)

    def test_refus_chemin_personnel_dans_le_contenu_du_dmg(self):
        """Le dossier personnel, /Users/ ou le nom du compte (injectes), dans un binaire de Sparkle, de l'app, une
        ressource ou la cible d'un lien : refus avant hdiutil, rien de publie."""
        cas = [({'FAUX_CHEMIN': 'home:sparkle'}, 'Sparkle.framework/Versions/B/Sparkle'),
               ({'FAUX_CHEMIN': 'home:ressource'}, 'Localizable.strings'),
               ({'FAUX_CHEMIN': 'users:app'}, 'MacOS/Essai Inventee'),
               ({'FAUX_CHEMIN': 'compte:autoupdate'}, 'Versions/B/Autoupdate'),
               ({'FAUX_LIEN': '1'}, 'Resources/lien')]
        for env, fichier in cas:
            with self.subTest(env=env):
                self.m.oublier()
                appels = self.refuse(env=env, motif='chemin personnel')
                self.assertTrue([a for a in appels if a.startswith('codesign --force')], 'apres la signature')
                self.assertFalse([a for a in appels if a.startswith(('hdiutil', 'sign_update'))], 'aucun .dmg')
                self.assertNotIn('controle de fuite', self.m.dit, 'refuse avant le controle de fuite')
        self.m.oublier()
        self.m.publier()
        self.assertTrue([a for a in self.m.appels() if a.startswith('gh release create')], 'l\'app propre passe')

    def test_nom_du_compte_injecte(self):
        """Le nom du compte cherche vient de l'environnement (USER), pas seulement du systeme : le nom invente, ecrit
        dans une ressource, est vu comme le nom du compte."""
        self.refuse(env={'FAUX_CHEMIN': 'compte:ressource'}, motif='(le nom du compte)')

    def test_contenu_du_dmg(self):
        """Le .dmg porte l'app, le raccourci vers Applications et la licence de Sparkle."""
        self.m.publier()
        dmg = lire(os.path.join(self.m.depot, 'build', 'publication', '1.2.3', 'Essai-Inventee-1.2.3.dmg'))
        lignes = dmg.splitlines()
        for attendu in ('Essai Inventee.app/Contents/Info.plist', 'Essai Inventee.app/Contents/MacOS/Essai Inventee',
                        'Essai Inventee.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle',
                        'Applications -> /Applications', 'Sparkle-LICENSE.txt'):
            self.assertIn(attendu, lignes)

    def test_refus_licence_absente(self):
        appels = self.refuse('--licence', os.path.join(self.dossier, 'absente.txt'), motif='licence')
        self.rien_compile(appels)

    def test_controle_du_contenu_du_dmg(self):
        """Le controle de fuite passe sur chaque fichier du .dmg, Sparkle et la licence compris, et sur la liste des
        noms, avant hdiutil : une adresse, un nom Tailscale ou un chemin temporaire dans un binaire de Sparkle, de
        l'app ou une ressource est refuse."""
        cas = [(ADRESSE + ':sparkle', 'Versions/B/Sparkle:'), (NOM_TAILSCALE + ':app', 'MacOS/Essai Inventee:'),
               (TEMPORAIRE + 'essai/x.o:ressource', 'fr.lproj/Localizable.strings:')]
        for fuite, fichier in cas:
            with self.subTest(fuite=fuite):
                self.m.oublier()
                with self.assertRaises(P.Refus) as r:
                    self.m.publier(env={'FAUX_FUITE': fuite})
                self.assertIn('controle de fuite', str(r.exception))
                self.assertIn(fichier, str(r.exception))
                appels = self.m.appels()
                self.assertFalse([a for a in appels if a.startswith(('hdiutil', 'sign_update', 'gh release create'))],
                                 'aucun .dmg')
        self.m.oublier()
        self.m.publier()
        sortie = os.path.join(self.m.depot, 'build', 'publication', '1.2.3')
        liste = lire(os.path.join(sortie, 'contenu-dmg.txt')).splitlines()
        for attendu in ('Applications -> /Applications', 'Sparkle-LICENSE.txt', 'Essai Inventee.app/Contents/Resources',
                        'Essai Inventee.app/Contents/Resources/fr.lproj/Localizable.strings',
                        'Essai Inventee.app/Contents/Helpers/ptzd'):
            self.assertIn(attendu, liste)

    def test_fuite_refusee_avec_son_emplacement(self):
        """Le refus nomme le fichier et la ligne, jamais la donnee trouvee."""
        with self.assertRaises(P.Refus) as r:
            self.m.publier(env={'FAUX_FUITE': ADRESSE + ':sparkle'})
        self.assertIn('Versions/B/Sparkle:', str(r.exception))
        self.assertNotIn(ADRESSE, str(r.exception))

    def test_oid_de_sparkle_admis_dans_le_dmg(self):
        """Les OID de RSA et d'Apple (exigences de signature), que porte le code de Sparkle, ont la forme d'une
        adresse : admis dans le .dmg (l'OID de RSA : voir test_controle_de_fuite)."""
        self.m.publier(env={'FAUX_FUITE': OID_APPLE + ':sparkle'})
        self.assertTrue([a for a in self.m.appels() if a.startswith('gh release create')])

    def test_noms_du_contenu_du_dmg_controles(self):
        """Les noms passent aussi par le controle de fuite, pas seulement les contenus : le nom d'un lien, ou sa
        cible, qui ne sont dans le contenu d'aucun fichier."""
        cas = [NOM_TAILSCALE + ':/Applications', 'lien-banal:' + TEMPORAIRE + 'cible-inventee/x']
        for lien in cas:
            with self.subTest(lien=lien):
                self.m.oublier()
                appels = self.refuse(env={'FAUX_LIEN_NOM_CIBLE': lien}, motif='contenu du .dmg')
                self.assertFalse([a for a in appels if a.startswith(('hdiutil', 'sign_update'))], 'aucun .dmg')

    def test_refus_contenu_interdit_du_dmg(self):
        """Le SDK OBSBOT, un binaire obsbot-ai ou les en-tetes du SDK, ou qu'ils soient dans l'app : refus avant
        hdiutil, rien de publie (spec distribution, section 5.1)."""
        for interdit in ('Frameworks/libdev.dylib', 'Helpers/obsbot-ai', 'Resources/libdev_v2.dylib',
                         'Resources/include/dev/devs.hpp', 'Resources/dev.hpp', 'MacOS/obsbot-ai'):
            with self.subTest(interdit=interdit):
                self.m.oublier()
                appels = self.refuse(env={'FAUX_INTERDIT': interdit}, motif='SDK OBSBOT')
                self.assertFalse([a for a in appels if a.startswith(('hdiutil', 'sign_update'))], 'aucun .dmg')

    def test_contenu_interdit(self):
        """Par le nom : libdev*.dylib, obsbot-ai, devs.hpp et dev.hpp ; la source obsbot-ai.cpp est permise."""
        with tempfile.TemporaryDirectory() as d:
            for f in ('A.app/Contents/Resources/obsbot-ai.cpp', 'A.app/Contents/Helpers/ptzd', 'A.app/x/libdev.txt',
                      'A.app/x/mondev.hpp'):
                ecrire(os.path.join(d, f), 'permis')
            self.assertEqual(P.contenu_interdit(d), [])
            for f in ('A.app/Contents/Helpers/obsbot-ai', 'A.app/lib/libdev.dylib', 'A.app/lib/libdev.1.dylib',
                      'A.app/include/dev/devs.hpp', 'A.app/include/dev/dev.hpp'):
                ecrire(os.path.join(d, f), 'interdit')
            os.symlink('/ailleurs', os.path.join(d, 'A.app', 'obsbot-ai-lien'))
            self.assertEqual(P.contenu_interdit(d), [
                'A.app/Contents/Helpers/obsbot-ai', 'A.app/include/dev/dev.hpp', 'A.app/include/dev/devs.hpp',
                'A.app/lib/libdev.1.dylib', 'A.app/lib/libdev.dylib'])

    def test_refus_sans_verification_avant_extraction(self):
        """SUVerifyUpdateBeforeExtraction absent de l'app compilee : la signature Ed25519 ne serait pas exigee (repli
        sur la signature de code) ; refus avant toute signature."""
        appels = self.refuse(env={'FAUX_INFO': 'sans-verification'}, motif='SUVerifyUpdateBeforeExtraction')
        self.assertFalse([a for a in appels if a.startswith('codesign --force')], 'rien de signe')

    def test_refus_binaire_qui_depend_du_sdk(self):
        """Un binaire Mach-O du .dmg lie a libdev (otool -L) : refus avant hdiutil ; otool lit chaque Mach-O."""
        self.m.publier()
        self.assertTrue([a for a in self.m.appels() if a.startswith('otool -L') and a.endswith('/Helpers/ptzd')])
        self.m.oublier()
        git(self.m.origine, 'tag', '-d', 'essai-v1.2.3')
        git(self.m.depot, 'reset', '-q', '--hard', 'HEAD~1')
        git(self.m.depot, 'push', '-q', '-f', 'origin', 'HEAD:main')
        appels = self.refuse(env={'FAUX_LIBDEV': '1'}, motif='depend de libdev')
        self.assertFalse([a for a in appels if a.startswith(('hdiutil', 'sign_update'))], 'aucun .dmg')

    def test_est_macho(self):
        with tempfile.TemporaryDirectory() as d:
            for nom, debut, attendu in (('fin', b'\xcf\xfa\xed\xfe', True), ('universel', b'\xca\xfe\xba\xbe', True),
                                        ('texte', b'#!/b', False), ('vide', b'', False)):
                p = os.path.join(d, nom)
                with open(p, 'wb') as f:
                    f.write(debut + b'reste')
                self.assertEqual(P.est_macho(p), attendu, nom)

    def test_revision_de_sparkle(self):
        """Les outils de Sparkle pris dans les artefacts du paquet resolu (DD) : la revision resolue doit etre celle de
        2.10.0, sinon refus avant tout ; des outils donnes hors de DD ne sont pas concernes."""
        artefacts = os.path.join(self.m.dd, 'SourcePackages', 'artifacts', 'sparkle', 'Sparkle', 'bin')
        os.makedirs(artefacts)
        for outil in ('sign_update', 'generate_keys'):
            shutil.copy(os.path.join(self.m.bin, outil), artefacts)
        etat = os.path.join(self.m.dd, 'SourcePackages', 'workspace-state.json')

        def ecrire_etat(revision):
            ecrire(etat, json.dumps({'object': {'dependencies': [
                {'packageRef': {'identity': 'nacelleprotocol'}, 'state': {'name': 'fileSystem'}},
                {'packageRef': {'identity': 'sparkle'},
                 'state': {'checkoutState': {'revision': revision, 'version': '2.10.0'}}}]}}))
        self.m.env['SPARKLE_BIN'] = artefacts
        for revision, motif in (('0' * 40, 'revision ' + '0' * 40), (None, 'illisible')):
            with self.subTest(revision=revision):
                self.m.oublier()
                if revision:
                    ecrire_etat(revision)
                elif os.path.exists(etat):
                    os.remove(etat)
                appels = self.refuse(motif=motif)
                self.rien_compile(appels)
                self.assertFalse([a for a in appels if a.startswith(('generate_keys', 'sign_update'))])
        self.m.oublier()
        ecrire_etat(P.REVISION_SPARKLE)
        self.m.publier()
        self.assertTrue([a for a in self.m.appels() if a.startswith('gh release create')])

    def test_refus_info_plist_de_l_app_compilee(self):
        appels = self.refuse(env={'FAUX_INFO': 'cle'}, motif='Info.plist')
        self.assertFalse([a for a in appels if a.startswith('codesign --force')], 'rien de signe')

    # --- la signature et son certificat ----------------------------------------------------------------------

    def signatures(self):
        """Les signatures du code, dans l'ordre : le chemin signe, depuis le dossier des produits."""
        base = os.path.join(self.m.dd, 'Build', 'Products', 'Release') + '/'
        return [a[a.index(base) + len(base):].replace('Essai Inventee.app/Contents/Frameworks/', '')
                for a in self.m.appels() if a.startswith('codesign --force')]

    def test_signature_du_code(self):
        """Le code imbrique d'abord, du plus profond au moins profond, chaque cadre apres son contenu, l'app en
        dernier ; par l'empreinte de l'identite, jamais son nom ; le runtime renforce, les droits gardes (l'app : ceux de
        droits-app.plist) ; puis la
        verification, le certificat feuille relu et l'exigence de signature."""
        self.m.publier()
        self.assertEqual(self.signatures(), [
            'Coeur.framework',
            'Sparkle.framework/Versions/Current/XPCServices/Downloader.xpc',
            'Sparkle.framework/Versions/Current/XPCServices/Installer.xpc',
            'Sparkle.framework/Versions/Current/Autoupdate',
            'Sparkle.framework/Versions/Current/Updater.app',
            'Sparkle.framework',
            'Essai Inventee.app/Contents/Helpers/ptzd',
            'Essai Inventee.app'])
        appels = self.m.appels()
        app = os.path.join(self.m.dd, 'Build', 'Products', 'Release', 'Essai Inventee.app')
        sortie = os.path.join(self.m.depot, 'build', 'publication', '1.2.3')
        signe = [a for a in appels if a.startswith('codesign --force')]
        for a in signe[:-1]:
            self.assertIn('--sign %s --options runtime --preserve-metadata=entitlements --timestamp=none'
                          % EMPREINTE, a)
        self.assertEqual(signe[-1], 'codesign --force --sign %s --options runtime --entitlements %s/droits-app.plist '
                                    '--timestamp=none %s' % (EMPREINTE, sortie, app))
        for a in signe:
            self.assertNotIn(IDENTITE, a)
            self.assertNotIn('--keychain', a)
        self.assertIn('codesign --verify --deep --strict ' + app, appels)
        self.assertIn('codesign -d --extract-certificates=%s/certificat- %s' % (sortie, app), appels)
        self.assertIn('openssl x509 -inform DER -in %s/certificat-0 -noout -subject -nameopt RFC2253 -fingerprint '
                      '-sha1' % sortie, appels)
        self.assertIn('certificate leaf', lire(os.path.join(sortie, 'exigence.txt')))

    def test_droits_de_l_app_signee(self):
        """Les droits attendus (bac a sable, les deux services de Sparkle de l'identifiant) : relus apres la
        signature et la verification, avant le certificat feuille ; la publication continue."""
        self.m.publier()
        app = os.path.join(self.m.dd, 'Build', 'Products', 'Release', 'Essai Inventee.app')
        appels = self.m.appels()
        lectures = [i for i, a in enumerate(appels) if a == 'codesign -d --entitlements - --xml ' + app]
        self.assertEqual(len(lectures), 2, 'avant la signature, puis la relecture')
        self.assertLess(lectures[0], [i for i, a in enumerate(appels) if a.startswith('codesign --force')][0])
        relus = lectures[1]
        self.assertGreater(relus, appels.index('codesign --verify --deep --strict ' + app))
        self.assertLess(relus, [i for i, a in enumerate(appels) if a.startswith('codesign -d --extract')][0])
        self.assertTrue([a for a in appels if a.startswith('hdiutil')], 'le .dmg est fait')

    def refuse_droits(self, cas, motif):
        appels = self.refuse(env={'FAUX_DROITS': cas}, motif=motif)
        self.assertTrue([a for a in appels if a.startswith('codesign --force')], 'apres la signature')
        self.assertFalse([a for a in appels if a.startswith(('hdiutil', 'sign_update'))], 'aucun .dmg')

    def test_refus_droits_sans_bac_a_sable(self):
        for cas in ('sans-bac-a-sable', 'bac-a-sable-faux'):
            with self.subTest(cas=cas):
                self.m.oublier()
                self.refuse_droits(cas, 'bac a sable')

    def test_refus_droits_avec_get_task_allow(self):
        self.refuse_droits('get-task-allow', 'get-task-allow est present')

    def test_droits_signes_levent_la_validation_des_bibliotheques(self):
        """Sans notarisation : l'app est signee avec les droits de Xcode, plus la levee de la validation des
        bibliotheques (sans equipe, l'app ne chargerait pas ses cadres) ; rien d'autre n'est ajoute."""
        self.m.publier()
        with open(os.path.join(self.m.depot, 'build', 'publication', '1.2.3', 'droits-app.plist'), 'rb') as f:
            droits = plistlib.load(f)
        self.assertEqual(droits, {'com.apple.security.app-sandbox': True,
                                  'com.apple.security.network.client': True,
                                  P.MACH_LOOKUP: ['fr.exemple.essai-spks', 'fr.exemple.essai-spki'],
                                  P.VALIDATION_BIBLIOTHEQUES: True})

    def test_refus_droits_sans_levee_de_la_validation(self):
        for cas in ('sans-validation', 'validation-fausse'):
            with self.subTest(cas=cas):
                self.m.oublier()
                self.refuse_droits(cas, 'disable-library-validation manque')

    def test_refus_droits_autre_exception_du_runtime(self):
        """Une autre exception du runtime renforce (ici les variables DYLD_) : refus, la levee seule est admise."""
        self.refuse_droits('variables-dyld', 'exception du runtime renforce '
                                             'com.apple.security.cs.allow-dyld-environment-variables')

    def test_notarisation_sans_levee_de_la_validation(self):
        """NOTARISER=1 (Developer ID, une equipe) : la levee n'est pas ajoutee, et refusee si Xcode l'a posee."""
        env = {'NOTARISER': '1', 'PROFIL_NOTARISATION': 'profil-essai'}
        self.m.publier(env=env)
        with open(os.path.join(self.m.depot, 'build', 'publication', '1.2.3', 'droits-app.plist'), 'rb') as f:
            self.assertNotIn(P.VALIDATION_BIBLIOTHEQUES, plistlib.load(f))

    def test_refus_notarisation_avec_levee_de_la_validation(self):
        """Avec NOTARISER=1, la levee posee par Xcode est refusee, meme a false."""
        for cas in ('validation-levee', 'validation-fausse'):
            with self.subTest(cas=cas):
                self.m.oublier()
                env = {'NOTARISER': '1', 'PROFIL_NOTARISATION': 'profil-essai', 'FAUX_DROITS': cas}
                appels = self.refuse(env=env, motif='disable-library-validation est present')
                self.assertTrue([a for a in appels if a.startswith('codesign --force')], 'apres la signature')
                self.assertFalse([a for a in appels if a.startswith(('hdiutil', 'sign_update'))], 'aucun .dmg')

    def test_refus_droits_mach_lookup_pas_exactement_ceux_de_sparkle(self):
        """Un service de plus, un de moins, ceux d'un autre identifiant, ou des droits illisibles : refus."""
        for cas, motif in (('en-trop', 'doit etre exactement fr.exemple.essai-spks et fr.exemple.essai-spki'),
                           ('manquant', 'doit etre exactement'), ('autre-identifiant', 'doit etre exactement'),
                           ('illisibles', 'illisibles')):
            with self.subTest(cas=cas):
                self.m.oublier()
                self.refuse_droits(cas, motif)

    def test_sans_bac_a_sable(self):
        """--sans-bac-a-sable : Xcode n'a pose aucun droit ; l'app est signee avec la seule levee de la validation des
        bibliotheques, relue sans bac a sable ni mach-lookup, et la publication continue."""
        self.m.publier('--sans-bac-a-sable', env={'FAUX_DROITS': 'aucun'})
        with open(os.path.join(self.m.depot, 'build', 'publication', '1.2.3', 'droits-app.plist'), 'rb') as f:
            self.assertEqual(plistlib.load(f), {P.VALIDATION_BIBLIOTHEQUES: True})
        self.assertTrue([a for a in self.m.appels() if a.startswith('gh release create')])

    def test_refus_sans_bac_a_sable_avec_bac_a_sable_ou_mach_lookup(self):
        """--sans-bac-a-sable : le bac a sable, ou un service en mach-lookup, dans les droits : refus apres la
        signature, aucun .dmg."""
        for cas, motif in (('bac-a-sable-seul', 'bac a sable (com.apple.security.app-sandbox) est present'),
                           ('mach-lookup-seul', 'mach-lookup.global-name est present'),
                           ('', 'bac a sable (com.apple.security.app-sandbox) est present')):
            with self.subTest(cas=cas):
                self.m.oublier()
                appels = self.refuse('--sans-bac-a-sable', env={'FAUX_DROITS': cas}, motif=motif)
                self.assertTrue([a for a in appels if a.startswith('codesign --force')], 'apres la signature')
                self.assertFalse([a for a in appels if a.startswith(('hdiutil', 'sign_update'))], 'aucun .dmg')

    def test_refus_sans_bac_a_sable_garde_les_autres_regles(self):
        """Sans bac a sable aussi : jamais get-task-allow, aucune autre exception du runtime renforce."""
        self.refuse('--sans-bac-a-sable', env={'FAUX_DROITS': 'aucun-get-task-allow'}, motif='get-task-allow est present')
        self.m.oublier()
        self.refuse('--sans-bac-a-sable', env={'FAUX_DROITS': 'aucun-dyld'},
                    motif='exception du runtime renforce com.apple.security.cs.allow-dyld-environment-variables')

    def test_droits_vides_seulement_avant_la_signature(self):
        """Une app sans droits (Xcode n'en pose pas) se lit {} avant la signature ; apres, des droits illisibles
        restent un refus."""
        self.refuse_droits('illisibles', 'illisibles')

    def test_utilitaires(self):
        """Contents/Helpers : chaque fichier ordinaire executable, dans l'ordre ; un lien ou un fichier non executable
        est refuse."""
        with tempfile.TemporaryDirectory() as d:
            aide = os.path.join(d, 'A.app', 'Contents', 'Helpers')
            for nom in ('ptzd', 'autre'):
                ecrire(os.path.join(aide, nom), nom)
                os.chmod(os.path.join(aide, nom), 0o755)
            self.assertEqual(P.utilitaires(os.path.join(d, 'A.app')), [os.path.join(aide, 'autre'), os.path.join(aide, 'ptzd')])
            self.assertEqual(P.utilitaires(os.path.join(d, 'B.app')), [])
            ecrire(os.path.join(aide, 'LISEZMOI'), 'texte')
            with self.assertRaises(P.Refus) as r:
                P.utilitaires(os.path.join(d, 'A.app'))
            self.assertIn('LISEZMOI', str(r.exception))
            os.remove(os.path.join(aide, 'LISEZMOI'))
            os.symlink('ptzd', os.path.join(aide, 'lien'))
            with self.assertRaises(P.Refus):
                P.utilitaires(os.path.join(d, 'A.app'))

    def test_refus_utilitaire_en_trop(self):
        """Un fichier non executable ou un lien dans Contents/Helpers : refus avant toute signature."""
        for cas in ('non-executable', 'lien'):
            with self.subTest(cas=cas):
                self.m.oublier()
                appels = self.refuse(env={'FAUX_UTILITAIRE_EN_TROP': cas}, motif='seuls des executables ordinaires')
                self.assertFalse([a for a in appels if a.startswith('hdiutil')])

    def test_utilitaires_relus_apres_la_signature(self):
        """Chaque utilitaire signe est relu : aucun droit, et le runtime renforce ; sinon refus, aucun .dmg."""
        self.m.publier()
        appels = self.m.appels()
        ptzd = [a for a in appels if a.startswith('codesign -dv ') and a.endswith('/Helpers/ptzd')]
        self.assertEqual(len(ptzd), 1)
        self.assertGreater(appels.index(ptzd[0]), [i for i, a in enumerate(appels) if a.startswith('codesign --verify')][0])
        git(self.m.origine, 'tag', '-d', 'essai-v1.2.3')
        git(self.m.depot, 'reset', '-q', '--hard', 'HEAD~1')
        git(self.m.depot, 'push', '-q', '-f', 'origin', 'HEAD:main')
        for cas, motif in (('droits', 'il porte des droits'), ('sans-runtime', 'le runtime renforce manque')):
            with self.subTest(cas=cas):
                self.m.oublier()
                appels = self.refuse(env={'FAUX_UTILITAIRE': cas}, motif=motif)
                self.assertFalse([a for a in appels if a.startswith(('hdiutil', 'sign_update'))], 'aucun .dmg')

    def test_signature_dans_un_trousseau_a_part(self):
        """En repetition, un certificat d'essai dans un trousseau a part : codesign et security y cherchent."""
        sortie = os.path.join(self.dossier, 'repetition')
        self.m.publier('--repetition', sortie, '--url-base', 'http://127.0.0.1:8123', '--cle-privee', 'cle.txt',
                       '--cle-publique', AUTRE_CLE, '--sans-tests', '--trousseau', '/tmp/essai.keychain-db')
        appels = self.m.appels()
        self.assertIn('security find-identity -p codesigning /tmp/essai.keychain-db', appels)
        self.assertIn('security find-certificate -a -c %s -Z -p /tmp/essai.keychain-db' % IDENTITE, appels)
        signe = [a for a in appels if a.startswith('codesign --force')]
        self.assertEqual(len(signe), 8)
        self.assertTrue(all('--keychain /tmp/essai.keychain-db' in a for a in signe))

    def test_refus_identite_absente(self):
        appels = self.refuse(env={'FAUSSE_IDENTITE': 'Autre Signing'}, motif='identite de signature')
        self.rien_compile(appels)

    def test_refus_deux_identites_du_meme_nom(self):
        """Deux certificats au meme nom : lequel signerait ? Refus (une identite listee deux fois, elle, passe)."""
        appels = self.refuse(env={'FAUSSE_IDENTITE_DOUBLE': '1'}, motif='une seule attendue')
        self.rien_compile(appels)
        sortie = 'Policy\n  1) %s "%s" (x)\n\n  Valid\n  1) %s "%s"\n  2) %s "%s 2"\n' % (
            EMPREINTE, IDENTITE, EMPREINTE, IDENTITE, AUTRE_EMPREINTE, IDENTITE)
        self.assertEqual(P.empreinte_identite(sortie, IDENTITE), EMPREINTE, 'le nom exact, pas un nom plus long')

    def test_sujet_conforme(self):
        """Seulement CN=<nom>, et au plus un code pays de deux lettres, dans un ordre ou l'autre."""
        n = IDENTITE
        for bon in ('CN=' + n, 'C=FR,CN=' + n, 'CN=%s,C=FR' % n):
            self.assertTrue(P.sujet_conforme(bon, n), bon)
        for mauvais in ('C=FR,O=Exemple,CN=' + n, 'C=France,CN=' + n, 'C=fr,CN=' + n, 'C=FR,C=DE,CN=' + n,
                        'C=FR,CN=Autre', 'C=FR', 'CN=%s,emailAddress=x@exemple.invalid' % n, 'O=X,CN=' + n,
                        'CN=%s,CN=%s' % (n, n), 'C=FRA,CN=' + n, 'C=FRANCE,CN=' + n, 'XC=FR,CN=' + n, ''):
            self.assertFalse(P.sujet_conforme(mauvais, n), mauvais)

    def test_refus_sujet_du_certificat(self):
        """Le certificat est public : seulement CN=<nom>, sans adresse, organisation ni autre nom ; et le bon."""
        cas = [({'FAUX_SUJET': 'CN=%s,emailAddress=x@exemple.invalid' % IDENTITE}, 'sujet'),
               ({'FAUX_SUJET': 'O=Exemple,CN=%s' % IDENTITE}, 'sujet'),
               ({'FAUX_SUJET': 'CN=Autre'}, 'sujet'),
               ({'FAUX_SUJET': 'C=FR,O=Exemple,CN=%s' % IDENTITE}, 'sujet'),
               ({'FAUX_SAN': '1'}, 'subjectAltName'),
               ({'FAUX_EMETTEUR': '1'}, 'une adresse'),
               ({'FAUX_CERTIFICAT_ABSENT': '1'}, 'introuvable')]
        for env, motif in cas:
            with self.subTest(env=env):
                self.m.oublier()
                appels = self.refuse(env=env, motif=motif)
                self.rien_compile(appels)

    def test_refus_certificat_feuille_de_l_app(self):
        """Le certificat dans la signature de l'app, relu : refus avant hdiutil s'il n'est pas conforme."""
        cas = [{'FAUX_SUJET_FEUILLE': 'CN=%s,emailAddress=x@exemple.invalid' % IDENTITE},
               {'FAUSSE_EMPREINTE_FEUILLE': AUTRE_EMPREINTE}, {'FAUX_SANS_CERTIFICAT': '1'}]
        for env in cas:
            with self.subTest(env=env):
                self.m.oublier()
                appels = self.refuse(env=env, motif='certificat')
                self.assertTrue([a for a in appels if a.startswith('codesign --force')], 'apres la signature')
                self.assertFalse([a for a in appels if a.startswith('hdiutil')], 'aucun .dmg')

    def test_notarisation_pas_par_defaut(self):
        self.m.publier()
        self.assertFalse([a for a in self.m.appels() if a.startswith(('xcrun', 'spctl'))])

    def test_refus_notarisation_sans_profil(self):
        appels = self.refuse(env={'NOTARISER': '1'}, motif='PROFIL_NOTARISATION')
        self.assertFalse([a for a in appels if a.startswith(('xcodebuild', 'xcrun'))], 'rien de compile ni soumis')

    def test_notarisation(self):
        """NOTARISER=1 : signatures horodatees, le .dmg signe, soumis, agrafe, evalue, puis signe par Sparkle (la
        signature Ed25519 porte sur le .dmg agrafe)."""
        self.m.publier(env={'NOTARISER': '1', 'PROFIL_NOTARISATION': 'profil-essai'})
        appels = self.m.appels()
        dmg = os.path.join(self.m.depot, 'build', 'publication', '1.2.3', 'Essai-Inventee-1.2.3.dmg')
        signe = [a for a in appels if a.startswith('codesign --force')]
        self.assertTrue(all('--timestamp ' in a and '--timestamp=none' not in a for a in signe))
        suite = [a for a in appels if a.startswith(('xcrun', 'spctl', 'sign_update')) or a.endswith(' ' + dmg)
                 and a.startswith('codesign')]
        self.assertEqual(suite, [
            'codesign --force --sign %s --timestamp %s' % (EMPREINTE, dmg),
            'xcrun notarytool submit %s --keychain-profile profil-essai --wait' % dmg,
            'xcrun stapler staple %s' % dmg,
            'spctl --assess --type open --context context:primary-signature --verbose %s' % dmg,
            'sign_update -p %s' % dmg])

    # --- les verifications d'avant les tests -----------------------------------------------------------------

    def test_refus_version_differente(self):
        self.commit('project.yml', PROJET.replace('"1.2.3"', '"1.2.4"'))
        appels = self.refuse(motif='MARKETING_VERSION')
        self.rien_compile(appels)

    def test_refus_arbre_pas_propre(self):
        ecrire(os.path.join(self.m.depot, 'oubli.txt'), 'x\n')
        self.refuse(motif='propre')

    def test_refus_etiquette_existante(self):
        git(self.m.depot, 'tag', 'essai-v1.2.3')
        self.refuse(motif='existe deja', etiquette='essai-v1.2.3')

    def test_refus_etiquette_seulement_sur_github(self):
        """L'etiquette poussee par un autre poste, absente de la copie : refus, sans la rapatrier."""
        self.autre_clone(['tag', 'essai-v1.2.3'], ['push', '-q', 'origin', 'essai-v1.2.3'])
        appels = self.refuse(motif='existe deja sur GitHub', etiquette_origine='essai-v1.2.3')
        self.rien_compile(appels)

    def test_etiquette_d_une_autre_app(self):
        """L'etiquette d'une autre app du meme depot, au meme numero, ne gene pas."""
        git(self.m.depot, 'tag', 'autre-v1.2.3')
        git(self.m.depot, 'push', '-q', 'origin', 'autre-v1.2.3')
        self.m.publier()
        self.assertEqual(git(self.m.origine, 'tag', '-l').split(), ['autre-v1.2.3', 'essai-v1.2.3'])

    def test_ajout_a_un_flux_existant(self):
        """Le flux du depot garde les versions d'avant : la nouvelle s'ajoute en tete."""
        self.commit('appcast.xml', P.ajouter_au_flux(None, 'Essai Inventee', '1.2.2', P.item_flux(
            '1.2.2', 2, 'https://github.com/Exemple/essai/releases/download/essai-v1.2.2/Essai-Inventee-1.2.2.dmg',
            10, 'QU5DSUVOTkU=', '26.0', '<p>Ancienne</p>', datetime.datetime(2026, 10, 1))))
        self.m.publier()
        s = '{%s}' % P.ESPACE_SPARKLE
        items = ET.fromstring(lire(os.path.join(self.m.depot, 'appcast.xml'))).findall('channel/item')
        self.assertEqual([i.find(s + 'shortVersionString').text for i in items], ['1.2.3', '1.2.2'])
        self.assertEqual(items[0].find(s + 'version').text, '4')

    def flux_existant(self, version, numero):
        self.commit('appcast.xml', P.ajouter_au_flux(None, 'Essai Inventee', version, P.item_flux(
            version, numero, 'https://exemple.invalid/x.dmg', 10, 'QQ==', '26.0', '', datetime.datetime(2026, 10, 1))))

    def test_refus_version_deja_dans_le_flux(self):
        self.flux_existant('1.2.3', 2)
        self.rien_compile(self.refuse(motif='deja dans le flux'))

    def test_refus_version_pas_superieure_a_la_tete_du_flux(self):
        """1.2.3 apres 1.10.0 : refus (une comparaison de chaines la laisserait passer)."""
        self.flux_existant('1.10.0', 2)
        self.rien_compile(self.refuse(motif='pas superieure'))

    def test_refus_numero_pas_superieur_a_la_tete_du_flux(self):
        """Un historique reecrit peut faire baisser le nombre de commits : Sparkle ne proposerait pas la version."""
        self.flux_existant('1.2.2', 4)
        self.rien_compile(self.refuse(motif='numero de compilation'))

    def test_refus_flux_existant_mal_forme(self):
        self.commit('appcast.xml', '<rss><channel><item>\n')
        self.rien_compile(self.refuse(motif='illisible'))

    def test_refus_auteur_sans_adresse_noreply(self):
        """Le commit du flux est public : son auteur porte l'adresse noreply de GitHub, jamais une vraie."""
        git(self.m.depot, 'config', 'user.email', 'essai@example.invalid')
        self.rien_compile(self.refuse(motif='noreply'))

    def test_refus_identite_git_par_l_environnement(self):
        """git var : l'environnement l'emporte sur la configuration, pour l'auteur comme pour le committer, et le nom
        compte aussi."""
        cas = [{'GIT_AUTHOR_EMAIL': 'essai@example.invalid'}, {'GIT_COMMITTER_EMAIL': 'essai@example.invalid'},
               {'GIT_AUTHOR_NAME': 'Autre'}, {'GIT_COMMITTER_NAME': 'Autre'}]
        for env in cas:
            with self.subTest(env=env):
                self.m.oublier()
                self.rien_compile(self.refuse(env=env, motif='noreply'))
        with self.subTest('EMAIL sans user.email'):
            self.m.oublier()
            git(self.m.depot, 'config', '--unset', 'user.email')
            self.rien_compile(self.refuse(env={'EMAIL': 'essai@example.invalid'}, motif='noreply'))

    def test_refus_adresse_du_flux(self):
        """L'app doit lire le flux a l'adresse brute du depot, celle ou publier.sh le pousse."""
        self.commit('project.yml', PROJET.replace('raw.githubusercontent.com/Exemple/essai/main/appcast.xml',
                                                  'github.com/Exemple/essai/releases/latest/download/appcast.xml'))
        self.refuse(motif='FLUX_MISES_A_JOUR')

    def test_refus_hors_de_main(self):
        git(self.m.depot, 'checkout', '-q', '-b', 'autre')
        self.refuse(motif='depuis main')

    def test_refus_main_pas_a_jour(self):
        ecrire(os.path.join(self.m.depot, 'f0.txt'), 'local\n')
        git(self.m.depot, 'commit', '-q', '-am', 'pas pousse')
        self.refuse(motif='a jour')

    def test_refus_origine_avancee_par_un_autre_clone(self):
        """main avance sur GitHub, rien en local : seul le fetch le voit."""
        self.autre_clone(['commit', '-q', '--allow-empty', '-m', 'ailleurs'], ['push', '-q', 'origin', 'main'])
        self._commits_origine = '4'
        self.rien_compile(self.refuse(motif='a jour'))

    def test_refus_deja_publiee(self):
        self.refuse(env={'FAUX_PUBLIEE': '1'}, motif='deja publiee')

    def test_refus_gh_release_view_en_erreur(self):
        """Toute reponse de gh release view autre que « release not found » : l'etat de GitHub est inconnu."""
        self.rien_compile(self.refuse(env={'FAUX_VUE': 'HTTP 401: Bad credentials'}, motif='inconnu'))

    def test_refus_gh_sans_session(self):
        self.rien_compile(self.refuse(env={'FAUX_AUTH_ECHEC': '1'}, motif='gh auth status'))

    def test_refus_push_impossible(self):
        git(self.m.depot, 'config', 'remote.origin.pushurl', os.path.join(self.dossier, 'absente.git'))
        self.rien_compile(self.refuse(motif='push --dry-run'))

    def test_refus_notes_absentes(self):
        self.commit('NOTES-VERSIONS.md', NOTES.replace('## 1.2.3', '## 1.2.1'))
        self.refuse(motif='pas de section 1.2.3')

    def test_refus_cle_du_trousseau_differente(self):
        appels = self.refuse(env={'FAUSSE_CLE': AUTRE_CLE}, motif='trousseau')
        self.assertIn('generate_keys -p', appels)

    def test_refus_cle_publique_invalide(self):
        sortie = os.path.join(self.dossier, 'repetition')
        self.rien_compile(self.refuse('--repetition', sortie, '--url-base', 'http://127.0.0.1:8123', '--cle-privee',
                                      'cle.txt', '--cle-publique', 'pas-une-cle', '--sans-tests', motif='invalide'))

    def test_refus_sans_sparkle_bin(self):
        """Hors repetition, sign_update et generate_keys viennent de l'archive de Sparkle 2.10.0, jamais du PATH."""
        self.m.env['SPARKLE_BIN'] = ''
        appels = self.refuse(motif='SPARKLE_BIN (le dossier bin')
        self.assertFalse([a for a in appels if a.startswith(('generate_keys', 'xcodebuild'))])
        self.m.oublier()
        self.m.env['SPARKLE_BIN'] = os.path.join(self.dossier, 'vide')
        self.rien_compile(self.refuse(motif='introuvable dans SPARKLE_BIN'))

    def test_refus_tests_en_echec(self):
        appels = self.refuse('--test', 'exit 3', motif='tests en echec')
        self.rien_compile(appels)

    def test_refus_sans_tests_hors_repetition(self):
        self.refuse('--sans-tests', motif='repetition')

    # --- juste avant les gestes publics ----------------------------------------------------------------------

    def test_refus_origine_avancee_pendant_les_tests(self):
        """Pendant les tests et la compilation, main avance sur GitHub : l'etat relu avant les gestes publics le
        voit, et rien n'est publie."""
        autre = os.path.join(self.dossier, 'autre')
        pousse = ('git clone -q %s %s && git -C %s -c user.name=X -c user.email=x@exemple.invalid commit -q '
                  '--allow-empty -m ailleurs && git -C %s push -q origin main' % (self.m.origine, autre, autre, autre))
        self._commits_origine = '4'
        appels = self.refuse('--test', pousse, motif='a jour')
        self.assertTrue([a for a in appels if a.startswith('sign_update')], 'refuse juste avant les gestes publics')

    def test_refus_commit_local_pendant_les_tests(self):
        """Un commit local pendant les tests (non pousse) : HEAD n'est plus le commit verifie, rien n'est publie."""
        appels = self.refuse('--test', 'git -c user.name=X -c user.email=x@exemple.invalid commit -q --allow-empty '
                             '-m local', motif='HEAD a change')
        self.assertTrue([a for a in appels if a.startswith('sign_update')], 'refuse juste avant les gestes publics')

    def test_refus_fichier_suivi_modifie_pendant_les_tests(self):
        appels = self.refuse('--test', 'echo x >> f0.txt', motif='propre')
        self.assertTrue([a for a in appels if a.startswith('sign_update')], 'refuse juste avant les gestes publics')

    # --- le controle de fuite -------------------------------------------------------------------------------

    def test_controle_de_fuite(self):
        """La regle des commits de ce depot, jugee par jeton : une adresse, un nom Tailscale, un chemin personnel ou
        temporaire ; sauf si le jeton entier est dans la liste autorisee."""
        with tempfile.TemporaryDirectory() as d:
            propre = os.path.join(d, 'propre.txt')
            ecrire(propre, 'ws://127.0.0.1:1985\nhttp://192.0.2.10/x\nmac.exemple.ts.net\nversion 1.2.3\n/Users/\n')
            sale = os.path.join(d, 'sale.txt')
            ecrire(sale, 'ok\n%s\n%s\n%s/x\n%sx\n%s\n' % (ADRESSE, NOM_TAILSCALE, AUTRE_COMPTE, TEMPORAIRE, '100.101' + '.102.103'))
            oid = os.path.join(d, 'oid.bin')
            with open(oid, 'wb') as f:
                f.write(b'\x00\x01 ' + OID_RSA.encode() + b' \xff')
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(P.fuites([propre]), [])
                self.assertEqual(P.fuites([sale]), [(sale, n) for n in (2, 3, 4, 5, 6)])
                self.assertEqual(P.fuites([oid]), [(oid, 1)], "l'OID hors du .dmg : une fuite")
                self.assertEqual(P.fuites([oid], dmg=True), [], 'admis dans le .dmg')
            apple = os.path.join(d, 'apple-oid.bin')
            ecrire(apple, 'certificate leaf[%s]\n' % OID_APPLE)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(P.fuites([apple], dmg=True), [])
            autre = os.path.join(d, 'autre-oid.bin')
            with open(autre, 'wb') as f:
                f.write(('.'.join(['1', '2', '840', '10045', '2', '1'])).encode())
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(P.fuites([autre], dmg=True), [(autre, 1)], 'seuls ces deux OID sont admis')

    def test_fuite_jugee_par_jeton(self):
        """Une adresse admise ne couvre pas sa ligne : 127.0.0.1 et une adresse reelle sur la meme ligne (une longue
        « ligne » de binaire), c'est une fuite. Le jeton entier compte : une adresse plus longue que l'adresse admise,
        ou un nom qui finit par un nom admis, n'est pas admis."""
        with tempfile.TemporaryDirectory() as d:
            cas = {
                'meme-ligne': ('http://127.0.0.1:8123 puis %s\n' % ADRESSE, [1]),
                'oid-dans-la-ligne': ('field.%s 127.0.0.1 %s\n' % (OID_RSA, ADRESSE), [1]),
                'plus-longue': ('127.0.0.12\n', [1]),
                'nom-prolonge': ('autre-mac.exemple.ts' + '.net\n', [1]),
                'admises': ('127.0.0.1, 192.0.2.44, 172.16.3.4, mac.exemple.ts' + '.net et 8.8.8.8.\n', []),
            }
            for nom, (texte, lignes) in cas.items():
                with self.subTest(cas=nom):
                    f = os.path.join(d, nom)
                    ecrire(f, texte)
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(P.fuites([f]), [(f, n) for n in lignes])
            binaire = os.path.join(d, 'binaire')
            with open(binaire, 'wb') as f:
                f.write(b'\x00' + OID_APPLE.encode() + b'\x00127.0.0.1\x00' + ADRESSE.encode() + b'\x00')
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(P.fuites([binaire], dmg=True), [(binaire, 1)], "l'adresse reelle, malgre l'OID et 127.0.0.1")

    def test_refus_fuite_dans_les_notes(self):
        """Une adresse dans les notes : refus apres la signature, le flux du depot ne change pas."""
        self.commit('NOTES-VERSIONS.md', NOTES.replace('- A new `command`.', '- A new `command` on %s.' % ADRESSE))
        appels = self.refuse(motif='controle de fuite')
        self.assertTrue([a for a in appels if a.startswith('sign_update')], 'le controle passe apres la signature')
        self.assertFalse(os.path.exists(os.path.join(self.m.depot, 'appcast.xml')), 'le flux du depot ne change pas')
        self.assertEqual(git(self.m.depot, 'status', '--porcelain'), '')

    def test_fichiers_controles(self):
        """Le controle de fuite lit, avant hdiutil, chaque fichier du .dmg et la liste de ses noms ; puis, apres la
        signature, les notes (NOTES-VERSIONS.md et notes.md), le flux, le message du commit et les textes de l'app."""
        vrai = P.fuites
        lus = []
        with mock.patch.object(P, 'fuites', side_effect=lambda f, *r, **k: (lus.append([os.path.basename(x) for x in f]),
                                                                             vrai(f, *r, **k))[1]):
            self.m.publier()
        self.assertEqual(len(lus), 2)
        for attendu in ('Info.plist', 'Sparkle', 'Essai Inventee', 'ptzd', 'Localizable.strings', 'Sparkle-LICENSE.txt',
                        'contenu-dmg.txt'):
            self.assertIn(attendu, lus[0])
        self.assertEqual(lus[1], ['NOTES-VERSIONS.md', 'appcast.xml', 'notes.md', 'message-commit.txt', 'project.yml'])

    def test_refus_fuite_dans_le_flux(self):
        """Une adresse hors de la liste dans le flux et l'app (ici, le serveur d'une repetition) : refus, aucun
        commit du flux."""
        sortie = os.path.join(self.dossier, 'repetition')
        with self.assertRaises(P.Refus) as r:
            self.m.publier('--repetition', sortie, '--url-base', 'http://%s:8123' % ADRESSE, '--sans-tests')
        self.assertIn('controle de fuite', str(r.exception))
        self.assertEqual(git(self.m.depot, 'rev-list', '--count', 'HEAD'), '3', 'aucun commit du flux')

    # --- la repetition et le Bureau --------------------------------------------------------------------------

    def test_refus_repetition_dans_une_copie_de_github(self):
        """Un flux d'essai commite dans un clone de GitHub pourrait y etre pousse a la main : refus."""
        git(self.m.depot, 'remote', 'set-url', 'origin', 'https://github.com.invalid/Exemple/essai.git')
        appels = self.refuse('--repetition', os.path.join(self.dossier, 'repetition'), '--url-base',
                             'http://127.0.0.1:8123', '--sans-tests', motif='GitHub')
        self.rien_compile(appels)
        self.assertEqual(git(self.m.depot, 'rev-list', '--count', 'HEAD'), '3', 'aucun commit')

    def test_copie_sur_le_bureau(self):
        self.m.publier(bureau=True)
        self.assertEqual(os.listdir(os.path.join(self.m.maison, 'Desktop')), ['Essai-Inventee-1.2.3.dmg'])

    def test_repetition_jamais_sur_le_bureau(self):
        self.m.publier('--repetition', os.path.join(self.dossier, 'repetition'), '--url-base',
                       'http://127.0.0.1:8123', '--sans-tests', bureau=True)
        self.assertEqual(os.listdir(os.path.join(self.m.maison, 'Desktop')), [])

    # --- les arguments, les erreurs, les outils --------------------------------------------------------------

    def test_arguments_de_la_repetition(self):
        base = ['publier', '1.2.3', '--nom-app', 'A', '--fichier', 'A', '--depot-github', 'E/a', '--projet',
                'A.xcodeproj', '--schema', 'A', '--cible', 'A', '--identite', 'I', '--auteur', 'E', '--etiquette',
                'a-v', '--flux', 'appcast.xml', '--licence', 'L']
        P.arguments(base)
        with mock.patch('sys.stderr'):
            for extra in (['--repetition', 'x'], ['--repetition', 'x', '--url-base', 'http://127.0.0.1:1',
                                                   '--cle-privee', 'k'], ['--cle-privee', 'k', '--cle-publique', CLE]):
                with self.subTest(extra=extra), self.assertRaises(SystemExit):
                    P.arguments(base + extra)
            for manque in ('--auteur', '--licence'):
                i = base.index(manque)
                with self.subTest(manque=manque), self.assertRaises(SystemExit):
                    P.arguments(base[:i] + base[i + 2:])

    def test_echec_d_un_outil_sans_trace(self):
        """Un outil introuvable : main rend 1 et un message, sans trace Python."""
        code, erreurs = self.m.main(env={'HDIUTIL': os.path.join(self.dossier, 'absent', 'hdiutil')})
        self.assertEqual(code, 1)
        self.assertIn('echec', erreurs)
        self.assertNotIn('Traceback', erreurs)
        self.assertFalse([a for a in self.m.appels() if a.startswith('gh release create')])

    def test_isolement_des_tests(self):
        """Aucune vraie commande reseau ne peut partir : un PATH restreint (ni gh, ni les outils de Sparkle, ni
        xcodegen), et git ne parle que le protocole file."""
        env = self.m.environnement(None)
        self.assertEqual(env['PATH'], PATH_ISOLE)
        self.assertEqual(PATH_ISOLE, '/usr/bin:/bin')
        self.assertEqual(env['GIT_ALLOW_PROTOCOL'], 'file')
        for outil in ('gh', 'sign_update', 'generate_keys', 'xcodegen'):
            self.assertIsNone(shutil.which(outil, path=env['PATH']), outil)
        r = subprocess.run(['git', 'ls-remote', 'https://github.com.invalid/Exemple/essai.git'], env=env,
                           capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('not allowed', r.stderr, 'git refuse tout protocole autre que file')

    def test_aucun_outil_reel_dans_les_tests(self):
        """Chaque commande externe des tests est une fausse commande, sauf git (sur un faux depot)."""
        o = P.Outils(self.m.env)
        for nom, valeur in vars(o).items():
            if nom != 'git':
                with self.subTest(outil=nom):
                    self.assertTrue(valeur == self.m.bin or valeur.startswith(self.m.bin + '/'), nom)


if __name__ == '__main__':
    unittest.main()
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd outils/tests && /usr/bin/python3 -m unittest discover -s . 2>&1 | tail -4)
(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' | grep -v appintents && ./check-bundle.sh)
```

Attendu : échec — les tests ne se chargent pas : `outils/publication.py` n'existe pas encore.

- [ ] **Étape 3 : Écrire le code**

Modifier `.gitignore` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/.gitignore b/.gitignore
index 7d5f9b0..c4c4b5d 100644
--- a/.gitignore
+++ b/.gitignore
@@ -28,3 +28,6 @@ mac/app/PTZBot.xcodeproj/
 mac/app/PTZBot/Info.plist
 ios/Config/Local.xcconfig
 ios/Local/
+
+# Outils de publication (Python)
+__pycache__/
PATCH
```

Créer `NOTES-VERSIONS.md` :

```markdown
# Release notes · Notes de version

PTZBot for Mac. Each section has an **English** block, then a **Français** block; the same notes go to the GitHub
release and to the update window.

PTZBot pour Mac. Chaque section a un bloc **English**, puis un bloc **Français** ; les mêmes notes servent à la
version GitHub et à la fenêtre de mise à jour.

## 1.0.0

**English**

- PTZBot for Mac now comes as a disk image: drag it into Applications. The first time, macOS asks you to confirm
  with "Open Anyway" in System Settings › Privacy & Security.
- Automatic updates with Sparkle, signed with an Ed25519 key: PTZBot checks at launch and every 24 hours, and
  installs when you quit or with "Install and Relaunch". "Check for Updates…" and "Settings…" are in the panel.
- The app speaks English and French, including the errors reported by ptzd.
- obsbot-ai is no longer shipped: PTZBot compiles it on your Mac from the OBSBOT SDK you provide, with Apple's
  developer tools. If you installed the SDK with an earlier build, reinstall it from its archive or folder.

**Français**

- PTZBot pour Mac s'installe désormais depuis une image disque : glissez-le dans Applications. La première fois,
  macOS demande de confirmer par « Ouvrir quand même » dans Réglages Système › Confidentialité et sécurité.
- Mises à jour automatiques par Sparkle, signées par une clé Ed25519 : PTZBot cherche au lancement puis toutes les
  24 heures, et installe à la fermeture ou par « Installer et relancer ». « Rechercher les mises à jour… » et
  « Réglages… » sont dans le panneau.
- L'app parle français et anglais, erreurs de ptzd comprises.
- obsbot-ai n'est plus livré : PTZBot le compile sur votre Mac à partir du SDK OBSBOT que vous fournissez, avec les
  outils de développement d'Apple. Si vous aviez installé le SDK avec une version précédente, réinstallez-le depuis
  son archive ou son dossier.
```

Modifier `mac/app/build-helpers.sh` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/app/build-helpers.sh b/mac/app/build-helpers.sh
index 8682f9f..ec36671 100755
--- a/mac/app/build-helpers.sh
+++ b/mac/app/build-helpers.sh
@@ -19,6 +19,13 @@ env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}
 BIN="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" \
     /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/ptzd" --show-bin-path)"
 install -m 755 "$BIN/ptzd" "$HELPERS/ptzd"
+# Compilation de publication (DEPLOYMENT_POSTPROCESSING, outils/publier.sh) : ptzd perd ses symboles de débogage,
+# comme l'app (STRIP_INSTALLED_PRODUCT) ; ils nomment les fichiers objets de mac/ptzd/.build, sous le dossier
+# personnel. La publication le signe ensuite avec son certificat ; d'ici là, signature locale.
+if [ "${DEPLOYMENT_POSTPROCESSING:-NO}" = "YES" ]; then
+    /usr/bin/xcrun strip -S "$HELPERS/ptzd"
+    /usr/bin/codesign --force --sign - "$HELPERS/ptzd"
+fi
 
 echo "Source d'obsbot-ai…"
 install -m 644 "$ROOT/mac/ai/main.cpp" "$RESOURCES/obsbot-ai.cpp"
PATCH
```

Créer `outils/Sparkle-LICENSE.txt` :

```text
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

Créer `outils/publication.py` :

```python
#!/usr/bin/env python3
"""Publication d'une version de l'app (spec du deploiement, section 3), appelee par publier.sh.

Reprise de maillage-thread (outils/publication.py), adaptee pour PTZBot (spec distribution, section 5.3) de trois
facons seulement, plus le controle de fuite et les parametres :
  - --sans-bac-a-sable : l'app n'a ni bac a sable, ni services de Sparkle en mach-lookup ; leur absence est exigee ;
  - les utilitaires (Contents/Helpers/*, ptzd) sont signes apres les cadres et avant l'app, runtime renforce ;
  - le contenu du .dmg refuse le SDK OBSBOT (libdev*.dylib), tout binaire obsbot-ai et les en-tetes du SDK ;
  - le controle d'anonymisation prive de maillage-thread est remplace par le controle de fuite des commits de ce
    depot (adresses hors liste autorisee, noms Tailscale, chemins personnels et temporaires), sur le contenu du
    .dmg, les notes et le flux ;
  - --notes : le fichier des notes, quand il n'est pas dans le dossier de l'app (ici a la racine du depot).
Et, apres la relecture du prototype : l'app compilee doit porter SUVerifyUpdateBeforeExtraction (signature Ed25519
toujours exigee) ; chaque utilitaire signe est relu (aucun droit, runtime renforce) ; aucun binaire Mach-O du .dmg ne
depend de libdev (otool -L) ; sign_update et generate_keys pris dans le paquet resolu exigent la revision de Sparkle
2.10.0 ; le controle de fuite juge chaque trouvaille par son jeton entier ; les notes HTML portent leur jeu de
caracteres.

  publication.py publier X.Y.Z --nom-app N --fichier F --depot-github D --projet P --schema S --cible C
                 --identite NOM --auteur NOM --etiquette PREFIXE --flux CHEMIN --licence FICHIER [--test CMD]...
                 [--textes FICHIER]... [--notes FICHIER] [--sans-bac-a-sable] [--sans-bureau]
                 [--repetition DOSSIER --url-base URL [--cle-privee FICHIER --cle-publique CLE] [--trousseau T]
                  [--sans-tests]]

Dans l'ordre :
  1. les verifications, avant tout test et toute compilation : la version est X.Y.Z, celle de MARKETING_VERSION ;
     l'arbre est propre ; l'auteur et le committer du commit du flux (git var) portent le nom --auteur et l'adresse
     noreply de GitHub ; l'etiquette de l'app (PREFIXE suivi de X.Y.Z, par exemple maillage-v1.0.0) n'existe pas ;
     le flux existant s'analyse (ElementTree), la version n'y est pas, elle est superieure a sa tete (en nombres),
     et le numero de compilation aussi ; l'app lit le flux a l'adresse brute du depot
     (https://raw.githubusercontent.com/<depot>/main/<CHEMIN>) ; hors repetition, l'etat de GitHub (voir 7) ;
     NOTES-VERSIONS.md a sa section ; SPARKLE_BIN est donne (hors repetition) ; la cle publique de l'app est celle
     du trousseau ; la licence de Sparkle est la ;
     l'identite de signature est seule a ce nom dans le trousseau, et son certificat n'a pour sujet que CN=<nom>
     (ni adresse, ni organisation, ni autre nom) ; puis les tests passent ;
  2. les numeros : la version, et le numero de compilation, le nombre de commits de main ;
  3. la compilation Release, ad hoc (une equipe de Local.xcconfig n'y entre pas), sans symboles de debogage dans
     les binaires (strip : la table OSO nomme les fichiers objets sous DerivedData ; le dSYM reste a part, jamais
     publie) et avec les chemins des sources ramenes a des noms neutres (-file-prefix-map) ; puis signee par
     l'empreinte de l'identite (un certificat auto-signe stable, plus tard un Developer ID) : le code imbrique
     d'abord, le runtime renforce, les droits gardes ; l'app, avec les droits poses par Xcode et, sans notarisation,
     la levee de la validation des bibliotheques (sans equipe, le runtime renforce refuse de charger les cadres de
     l'app) ; les utilitaires (Contents/Helpers/*) entre les cadres et l'app ; les droits de l'app signee sont relus
     (le bac a sable, les seuls services de Sparkle en mach-lookup, ou, avec --sans-bac-a-sable, ni l'un ni les
     autres ; jamais get-task-allow, la levee de la validation des bibliotheques si et seulement si la publication
     n'est pas notarisee) ; le certificat feuille de la signature est relu ; l'exigence de signature (codesign -d -r-) est ecrite dans exigence.txt ;
  4. le .dmg (hdiutil) : l'app, un raccourci vers Applications et la licence de Sparkle. Avant hdiutil, tout le
     contenu est refuse s'il porte un chemin personnel ($HOME, /Users/, le nom du compte), un element interdit (le SDK
     OBSBOT, un binaire obsbot-ai, les en-tetes du SDK) ou si le controle de fuite y trouve une donnee locale ; la
     liste des noms du contenu (chemins relatifs, cibles des liens), ecrite dans contenu-dmg.txt, passe aussi par ce
     controle. Avec NOTARISER=1 seulement (desactive par defaut), le .dmg signe,
     soumis a Apple (notarytool, profil PROFIL_NOTARISATION du trousseau), agrafe (stapler) et evalue (spctl) ;
  5. la signature Ed25519 du .dmg (sign_update de Sparkle, cle du trousseau), puis le flux : le fichier CHEMIN du
     depot (appcast.xml), qui garde toutes les versions publiees, la nouvelle en tete (relu apres l'ajout) ;
     l'adresse de chaque .dmg est celle de sa version publiee ;
  6. le controle de fuite sur les notes, le flux, le message du commit du flux et les textes de l'app ;
  7. juste avant les gestes publics, l'etat est relu : HEAD est toujours le commit verifie, a jour avec GitHub, et
     l'arbre est propre ; l'etiquette n'existe pas sur GitHub ; gh release view repond « release not found » (toute
     autre reponse est un refus) ; gh a une session ; git push --dry-run origin HEAD:main passe. Puis la version
     publiee (gh release create --target <commit verifie>, qui cree l'etiquette sur GitHub), avec le .dmg ; puis le
     flux, commite (git add de ce seul fichier), et pousse aussitot par HEAD:main, ce qui est verifie (git ls-remote).
     Chaque geste est note dans gestes.txt, dans le dossier des produits : « tentative : ... » AVANT le geste, puis,
     APRES, sa ligne de reussite (« version publiee », « flux commite », « flux pousse sur main ») ou « echec : ... »
     avec la reprise. Une « tentative » sans suite (coupure, Ctrl-C) est un geste ambigu : lire GitHub d'abord ;
  8. le .dmg copie sur le Bureau (sauf --sans-bureau).

Rien n'est publie si une etape de 1 a 6, ou la relecture de l'etape 7, echoue. Un echec au milieu de l'etape 7
laisse les gestes deja faits, notes dans gestes.txt : la reprise part de ce fichier, qui dit ou reprendre, et du
dossier des produits (notes.md, appcast.xml, message-commit.txt, le .dmg). Un echec de gh release create est ambigu
(GitHub a pu creer la version avant que l'erreur arrive) : il est note comme tel.

En repetition (--repetition DOSSIER), ni GitHub, ni etiquette, ni Bureau : la branche peut etre une autre que main,
mais l'origine ne doit pas etre sur GitHub ; --url-base tient lieu des deux adresses de GitHub (le flux :
<URL>/<depot>/main/<CHEMIN> ; un .dmg : <URL>/<depot>/releases/download/<etiquette>/<fichier>), comme les servirait
un serveur local ; le flux est commite dans la copie, sans etre pousse ; les produits vont dans DOSSIER. Avec
--cle-privee et --cle-publique, une paire d'essai,
sans le trousseau : l'app porte cette cle publique, et le .dmg est signe avec la cle privee du fichier. Sans elles,
la cle du trousseau, comme pour la vraie publication. Avec --trousseau, l'identite de signature est cherchee dans ce
trousseau a part (un certificat d'essai), jamais dans celui de la session.

Les commandes externes se remplacent par l'environnement, pour les tests : XCODEGEN, XCODEBUILD, HDIUTIL, DITTO,
CODESIGN, SECURITY, OPENSSL, XCRUN, SPCTL, OTOOL, SPARKLE_BIN (dossier de sign_update et generate_keys), GH et GIT ; le
dossier personnel et le nom du compte cherches dans le .dmg, par
HOME, USER et LOGNAME. Aucun identifiant Apple, Team ID, empreinte ni mot de passe n'est ecrit ici : l'empreinte de
l'identite est lue dans le trousseau au moment de publier, et la notarisation lit le profil que notarytool
store-credentials a range dans le trousseau.
"""
import argparse
import datetime
import html
import json
import os
import plistlib
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from types import SimpleNamespace

VERSION = re.compile(r'^\d+\.\d+\.\d+$')
ESPACE_SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
# Le controle de fuite des commits de ce depot (docs/superpowers/plans, contraintes globales) : une adresse IPv4, un
# nom Tailscale (domaine ts.net), un chemin sous /Users/ ou le dossier temporaire du systeme est une fuite, sauf ce
# que la liste autorisee nomme. Ici, chaque trouvaille est jugee seule, par le jeton entier qui l'entoure (l'adresse
# ou le nom complet) : dans un binaire, une « ligne » peut etre longue et porter a la fois une adresse admise et une
# adresse reelle. Les motifs sont ecrits en morceaux : ce fichier passe lui-meme le controle des commits.
FUITE = re.compile(rb'([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private' rb'/tmp/')
# La liste autorisee des commits, en jetons : les adresses et noms admis tels quels, puis les debuts d'adresse admis.
AUTORISES = {b'127.0.0.1', b'0.0.0.0', b'100.64.0.0', b'100.64.0.1', b'10.0.0.5', b'8.8.8.8', b'256.0.0.1',
             b'mac.exemple.ts.net', b'mon-mac.tailnet.ts.net'}
DEBUTS_AUTORISES = (b'192.0.2.', b'169.254.', b'172.16.', b'172.31.', b'172.32.', b'192.168.0.')
# Dans le contenu du .dmg seulement, en plus : les OID de RSA (PKCS #1) et d'Apple (exigences de signature), que
# porte le code de Sparkle (Autoupdate) ; ils ont la forme d'une adresse, mais ce n'est la donnee de personne.
DEBUTS_AUTORISES_DMG = DEBUTS_AUTORISES + (b'1.2.840.' b'113549.', b'1.2.840.' b'113635.')
CHIFFRES_ET_POINTS = frozenset(b'0123456789.')
CARACTERES_DE_NOM = frozenset(b'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-')
# Ce qui ne doit jamais etre dans le .dmg (spec distribution, section 5.1) : le SDK OBSBOT, un binaire obsbot-ai,
# les en-tetes du SDK.
INTERDITS = (re.compile(r'^libdev.*\.dylib$'), re.compile(r'^obsbot-ai$'), re.compile(r'^devs?\.hpp$'))
# La revision de l'etiquette 2.10.0 de Sparkle, celle que project.yml fixe (exactVersion).
REVISION_SPARKLE = 'eef1a539a373c1f1a320624b1130fc5de7b2e100'
NOREPLY = re.compile(r'^[^@\s<>]+@users\.noreply\.github\.com$')
BAC_A_SABLE = 'com.apple.security.app-sandbox'
MACH_LOOKUP = 'com.apple.security.temporary-exception.mach-lookup.global-name'
GET_TASK_ALLOW = 'com.apple.security.get-task-allow'
VALIDATION_BIBLIOTHEQUES = 'com.apple.security.cs.disable-library-validation'


class Refus(Exception):
    """Une verification qui arrete la publication. Jusqu'a la relecture de l'etape 7 comprise, rien n'est publie ;
    au-dela, les gestes deja faits sont dans gestes.txt."""


def lire(chemin):
    with open(chemin, encoding='utf-8') as f:
        return f.read()


def ecrire(chemin, texte):
    with open(chemin, 'w', encoding='utf-8') as f:
        f.write(texte)


# --- les numeros ---------------------------------------------------------------------------------------------

def version_valide(v):
    return bool(VERSION.match(v))


def nombres(version):
    """X.Y.Z en nombres, pour comparer : 1.10.0 vient apres 1.2.3."""
    return tuple(int(x) for x in version.split('.'))


def bloc_cible(projet_yml, cible):
    """Les lignes de la cible `cible` de project.yml (XcodeGen) : de « targets: », la cible a deux espaces de
    retrait, jusqu'a la suivante."""
    lignes = lire(projet_yml).splitlines()
    try:
        debut = lignes.index('targets:')
        i = lignes.index('  %s:' % cible, debut)
    except ValueError:
        raise Refus('cible %s introuvable dans %s' % (cible, projet_yml))
    bloc = []
    for l in lignes[i + 1:]:
        if re.match(r'^ {0,2}\S', l):
            break
        bloc.append(l)
    return bloc


def reglage(projet_yml, cible, nom):
    """La valeur d'un reglage de la cible (« NOM: valeur », guillemets otes)."""
    for l in bloc_cible(projet_yml, cible):
        m = re.match(r'^\s+%s:\s*(.+?)\s*$' % re.escape(nom), l)
        if m:
            return m.group(1).strip('"')
    raise Refus('%s absent de la cible %s' % (nom, cible))


def systeme_minimum(projet_yml):
    """La version minimale de macOS (options.deploymentTarget.macOS)."""
    m = re.search(r'^options:\n(?:  .*\n)*?  deploymentTarget:\n    macOS: "?([\d.]+)"?', lire(projet_yml), re.M)
    if not m:
        raise Refus('deploymentTarget.macOS absent de ' + projet_yml)
    return m.group(1)


def numero_compilation(depot, git='git'):
    """Le numero de compilation (CFBundleVersion), que compare Sparkle : le nombre de commits jusqu'a HEAD."""
    return int(subprocess.run([git, '-C', depot, 'rev-list', '--count', 'HEAD'], check=True, capture_output=True,
                              text=True).stdout.strip())


# --- les notes et le flux ------------------------------------------------------------------------------------

def notes(chemin, version):
    """La section « ## X.Y.Z » de NOTES-VERSIONS.md, sans son titre."""
    texte = lire(chemin)
    m = re.search(r'^## %s[ \t]*\n(.*?)(?=^## |\Z)' % re.escape(version), texte, re.M | re.S)
    if not m or not m.group(1).strip():
        raise Refus('pas de section %s dans %s' % (version, chemin))
    return m.group(1).strip() + '\n'


def en_ligne(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', t)
    return re.sub(r'`(.+?)`', r'<code>\1</code>', t)


def notes_html(texte):
    """Les notes en HTML simple, pour la fenetre de Sparkle : paragraphes, listes « - », gras et code."""
    sortie, liste, para = [], [], []

    def fermer():
        if para:
            sortie.append('<p>%s</p>' % en_ligne(' '.join(para)))
            para.clear()
        if liste:
            sortie.append('<ul>%s</ul>' % ''.join('<li>%s</li>' % en_ligne(e) for e in liste))
            liste.clear()

    for l in texte.splitlines():
        s = l.strip()
        if not s:
            fermer()
        elif s.startswith('- '):
            if para:
                fermer()
            liste.append(s[2:])
        elif liste and l.startswith('  '):
            liste[-1] += ' ' + s
        else:
            if liste:
                fermer()
            para.append(s)
    fermer()
    # Le jeu de caracteres d'abord : un lecteur qui ne le devine pas (sparkle-cli) lirait les accents de travers.
    return '\n'.join(['<meta charset="utf-8">'] + sortie)


def item_flux(version, numero, url, taille, signature, systeme, notes_html_, date):
    """Une version dans le flux de Sparkle : un <item>, avec son retrait et sa fin de ligne."""
    return '''    <item>
      <title>%s</title>
      <pubDate>%s</pubDate>
      <sparkle:version>%d</sparkle:version>
      <sparkle:shortVersionString>%s</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>
      <description><![CDATA[
%s
]]></description>
      <enclosure url="%s" length="%d" type="application/octet-stream" sparkle:edSignature="%s"/>
    </item>
''' % (html.escape(version), date.strftime('%a, %d %b %Y %H:%M:%S +0000'), numero, html.escape(version),
       html.escape(systeme), notes_html_.replace(']]>', ']]&gt;'), html.escape(url), taille, html.escape(signature))


def versions_du_flux(texte):
    """Les versions d'un flux (appcast.xml), lu par ElementTree : (X.Y.Z, numero de compilation) de chaque <item>,
    la tete d'abord. Refus si le flux ne s'analyse pas, ou si un <item> n'a pas les deux."""
    try:
        racine = ET.fromstring(texte)
    except ET.ParseError as e:
        raise Refus('flux illisible (%s)' % e)
    canal = racine.find('channel')
    if racine.tag != 'rss' or canal is None:
        raise Refus('flux illisible : ni <rss>, ni <channel>')
    s = '{%s}' % ESPACE_SPARKLE
    versions = []
    for item in canal.findall('item'):
        court = (item.findtext(s + 'shortVersionString') or '').strip()
        numero = (item.findtext(s + 'version') or '').strip()
        if not version_valide(court) or not numero.isdigit():
            raise Refus('flux illisible : un <item> sans sparkle:shortVersionString X.Y.Z ni sparkle:version entier')
        versions.append((court, int(numero)))
    return versions


def verifier_flux(existant, version, numero=None):
    """La version peut entrer dans le flux existant : elle n'y est pas, elle est superieure a sa tete (en nombres),
    et son numero de compilation (que compare Sparkle) aussi. Leve Refus."""
    versions = versions_du_flux(existant)
    if version in [v for v, _ in versions]:
        raise Refus('la version %s est deja dans le flux' % version)
    if versions:
        tete, numero_tete = versions[0]
        if nombres(version) <= nombres(tete):
            raise Refus('la version %s n\'est pas superieure a la tete du flux (%s)' % (version, tete))
        if numero is not None and numero <= numero_tete:
            raise Refus('le numero de compilation %d n\'est pas superieur a celui de la tete du flux (%d) : Sparkle '
                        'ne proposerait pas la version' % (numero, numero_tete))


def ajouter_au_flux(existant, titre, version, item, numero=None):
    """Le flux (appcast.xml) avec une version de plus, en tete : il garde toutes les versions publiees. Sans flux
    existant (None), un flux neuf. Refus si la version n'y entre pas (verifier_flux), ou si le flux produit ne
    s'analyse pas avec elle en tete."""
    if existant is None:
        xml = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="%s">
  <channel>
    <title>%s</title>
%s  </channel>
</rss>
''' % (ESPACE_SPARKLE, html.escape(titre), item)
    else:
        verifier_flux(existant, version, numero)
        i = existant.find('    <item>')
        if i < 0:
            i = existant.find('  </channel>')
        if i < 0:
            raise Refus('flux illisible : ni <item>, ni </channel>')
        xml = existant[:i] + item + existant[i:]
    versions = versions_du_flux(xml)
    if not versions or versions[0][0] != version:
        raise Refus('le flux produit n\'a pas la version %s en tete' % version)
    return xml


def message_flux(nom_app, version):
    """Le message du commit du flux, en francais sans accents."""
    return ('Publier %s %s dans le flux des mises a jour\n\n'
            'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n' % (nom_app, version))


# --- les chemins personnels ----------------------------------------------------------------------------------

def guillemets(texte):
    """Un mot d'une liste de reglages de Xcode (OTHER_SWIFT_FLAGS...), entre guillemets : les espaces y restent."""
    return '"%s"' % texte.replace('\\', '\\\\').replace('"', '\\"')


def carte_des_chemins(racine):
    """Le prefixe ramene a « . » dans les binaires : la racine du depot, ou sont les sources (#filePath), sous ses
    deux formes (/tmp et /private/tmp). Le dossier de produits n'y est pas : ses chemins ne vont que dans la table OSO,
    que le strip retire, et dans le dSYM, qui doit les garder pour retrouver les modules precompiles."""
    if not racine or not racine.strip('/'):
        return []
    return sorted({(racine.rstrip('/'), '.'), (os.path.realpath(racine), '.')}, key=lambda p: (-len(p[0]), p))


def reglages_compilation(numero, carte):
    """Les reglages de la compilation de publication, en ligne de commande (ils l'emportent sur project.yml) :
    ad hoc, le numero de compilation, sans symboles de debogage dans les binaires (DEPLOYMENT_POSTPROCESSING et
    STRIP_INSTALLED_PRODUCT : le strip retire la table OSO, qui nomme les fichiers objets ; le dSYM reste a part),
    et les chemins des sources (#filePath, debogage) ramenes a la carte (-file-prefix-map), apres ceux du projet ;
    le controle du contenu du .dmg (chemins_personnels) refuse ce qui resterait."""
    swift = ' '.join('-file-prefix-map %s' % guillemets('%s=%s' % p) for p in carte)
    c = ' '.join(guillemets('-ffile-prefix-map=%s=%s' % p) for p in carte)
    return ['CURRENT_PROJECT_VERSION=%d' % numero, 'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=',
            'CODE_SIGN_STYLE=Manual', 'DEPLOYMENT_POSTPROCESSING=YES', 'STRIP_INSTALLED_PRODUCT=YES',
            'OTHER_SWIFT_FLAGS=$(inherited) ' + swift, 'OTHER_CFLAGS=$(inherited) ' + c]


def motifs_personnels(env=None):
    """Ce qu'aucun fichier publie ne doit porter : tout chemin sous /Users/, le dossier personnel (HOME) et le nom du
    compte macOS (USER, LOGNAME et celui du systeme). Chaque motif avec ce qu'il est, jamais sa valeur."""
    e = os.environ if env is None else env
    motifs = [(b'/Users/', 'un chemin sous /Users/')]
    maison = e.get('HOME', '').rstrip('/')
    if maison:
        motifs.append((maison.encode(), 'le dossier personnel (HOME)'))
    comptes = {e.get('USER', ''), e.get('LOGNAME', '')}
    try:
        comptes.add(pwd.getpwuid(os.getuid()).pw_name)
    except KeyError:
        pass
    motifs += [(c.encode(), 'le nom du compte') for c in sorted(comptes) if c]
    return motifs


def chemins_personnels(dossier, motifs):
    """Ce qui, dans le dossier (le contenu du .dmg), porte un motif personnel : le contenu de chaque fichier
    ordinaire (binaires compris), la cible de chaque lien et chaque nom. Rend [(chemin relatif, motif)] ; le chemin
    relatif est tu s'il porte lui-meme le motif."""
    trouves = []
    for racine, dossiers, fichiers in os.walk(dossier):
        for nom in sorted(dossiers + fichiers):
            p = os.path.join(racine, nom)
            rel = os.path.relpath(p, dossier)
            if os.path.islink(p):
                contenu = os.readlink(p).encode()
            elif os.path.isfile(p):
                with open(p, 'rb') as f:
                    contenu = f.read()
            else:
                contenu = b''
            for motif, quoi in motifs:
                if motif in rel.encode():
                    trouves.append(('(un nom de fichier)', quoi))
                    break
                if motif in contenu:
                    trouves.append((rel, quoi))
                    break
    return trouves


def liste_du_contenu(dossier):
    """Les noms du contenu du .dmg, un par ligne : chaque chemin relatif (dossiers, fichiers et liens) et, pour un
    lien, sa cible. Le controle de fuite ne lit que le contenu des fichiers : il lit aussi cette liste."""
    lignes = []
    for racine, dossiers, fichiers in os.walk(dossier):
        dossiers.sort()
        for nom in sorted(dossiers + fichiers):
            p = os.path.join(racine, nom)
            lignes.append(os.path.relpath(p, dossier) + (' -> ' + os.readlink(p) if os.path.islink(p) else ''))
    return '\n'.join(lignes) + '\n'


def fichiers_ordinaires(dossier):
    """Les fichiers ordinaires du dossier, sans suivre les liens, dans l'ordre."""
    liste = []
    for racine, dossiers, fichiers in os.walk(dossier):
        dossiers.sort()
        for nom in sorted(fichiers):
            p = os.path.join(racine, nom)
            if os.path.isfile(p) and not os.path.islink(p):
                liste.append(p)
    return liste


# --- la publication ------------------------------------------------------------------------------------------

class Outils:
    """Les commandes externes, remplacables par l'environnement (tests)."""

    def __init__(self, env=None):
        e = os.environ if env is None else env
        self.sparkle_bin = e.get('SPARKLE_BIN', '')
        self.git = e.get('GIT', 'git')
        self.xcodegen = e.get('XCODEGEN', 'xcodegen')
        self.xcodebuild = e.get('XCODEBUILD', 'xcodebuild')
        self.hdiutil = e.get('HDIUTIL', 'hdiutil')
        self.ditto = e.get('DITTO', 'ditto')
        self.codesign = e.get('CODESIGN', 'codesign')
        self.security = e.get('SECURITY', 'security')
        self.openssl = e.get('OPENSSL', '/usr/bin/openssl')
        self.xcrun = e.get('XCRUN', 'xcrun')
        self.spctl = e.get('SPCTL', 'spctl')
        self.otool = e.get('OTOOL', 'otool')
        self.gh = e.get('GH', 'gh')
        self.sign_update = os.path.join(self.sparkle_bin, 'sign_update') if self.sparkle_bin else 'sign_update'
        self.generate_keys = os.path.join(self.sparkle_bin, 'generate_keys') if self.sparkle_bin else 'generate_keys'


def lancer(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def dire(texte):
    print(texte, flush=True)


def identite_git(o, variable):
    """Le nom et l'adresse que git mettra dans le commit du flux (git var GIT_AUTHOR_IDENT ou GIT_COMMITTER_IDENT :
    la configuration, mais aussi GIT_AUTHOR_*, GIT_COMMITTER_* et EMAIL)."""
    r = subprocess.run([o.git, 'var', variable], capture_output=True, text=True)
    m = re.match(r'^(.*) <([^<>]*)> \d+ [+-]\d{4}$', r.stdout.strip())
    if r.returncode != 0 or not m:
        raise Refus('%s illisible (git var) : regler user.name et user.email du depot' % variable)
    return m.group(1), m.group(2)


def empreinte_identite(sortie, nom):
    """L'empreinte SHA-1 de la seule identite de signature a ce nom exact, dans la sortie de security find-identity
    (qui peut la lister deux fois : toutes les identites, puis les valides). Leve Refus s'il n'y en a pas, ou plus
    d'une."""
    empreintes = set(re.findall(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"%s"' % re.escape(nom), sortie, re.M))
    if not empreintes:
        raise Refus('identite de signature introuvable dans le trousseau : %s' % nom)
    if len(empreintes) > 1:
        raise Refus('%d identites de signature portent le nom %s : une seule attendue' % (len(empreintes), nom))
    return empreintes.pop()


def certificat_du_trousseau(sortie, empreinte):
    """Le certificat (PEM) d'empreinte SHA-1 donnee, dans la sortie de security find-certificate -a -Z -p."""
    for sha1, pem in re.findall(r'SHA-1 hash: ([0-9A-F]{40})\s*\n(-----BEGIN CERTIFICATE-----.*?'
                                r'-----END CERTIFICATE-----)', sortie, re.S):
        if sha1 == empreinte:
            return pem + '\n'
    raise Refus("le certificat de l'identite de signature est introuvable dans le trousseau")


def sujet_conforme(sujet, nom):
    """Le sujet d'un certificat, en RFC 2253 : CN=<nom>, et au plus un code pays de deux lettres (C=FR, que
    Trousseaux d'acces pose de lui-meme ; decision de Djoko du 06/10). Ni adresse, ni organisation, ni autre champ."""
    parts = sujet.split(',')
    if parts == ['CN=' + nom]:
        return True
    return (len(parts) == 2 and parts.count('CN=' + nom) == 1
            and any(re.fullmatch(r'C=[A-Z]{2}', x) for x in parts))


def verifier_certificat(o, nom, empreinte, pem=None, der=None, quoi='le certificat de signature'):
    """Le certificat est public (il est dans chaque signature) : son sujet doit etre CN=<nom>, avec au plus un code
    pays (sujet_conforme ; ni adresse, ni organisation), sans autre nom (subjectAltName) ni « @ » ; son empreinte, celle de l'identite.
    Le certificat est donne en PEM (pem) ou dans un fichier DER (der). Leve Refus, sans recopier le sujet."""
    base = [o.openssl, 'x509'] + (['-inform', 'DER', '-in', der] if der else []) + ['-noout']
    tete = lancer(base + ['-subject', '-nameopt', 'RFC2253', '-fingerprint', '-sha1'], input=pem)
    texte = lancer(base + ['-text'], input=pem)
    sujet = re.search(r'^subject=\s*(.*?)\s*$', tete, re.M)
    lue = re.search(r'Fingerprint=([0-9A-Fa-f:]+)', tete)
    if not sujet or not sujet_conforme(sujet.group(1), nom):
        raise Refus('%s : son sujet doit etre seulement CN=%s, et au plus un pays (ni adresse, ni organisation)'
                    % (quoi, nom))
    if '@' in tete + texte or 'Subject Alternative Name' in texte:
        raise Refus('%s porte une adresse ou un autre nom (subjectAltName) : rien n\'est publie' % quoi)
    if not lue or lue.group(1).replace(':', '').upper() != empreinte:
        raise Refus("%s n'est pas celui de l'identite choisie (empreinte)" % quoi)


def verifier_github(a, o, etiquette, sha):
    """L'etat de la copie et de GitHub, lu avant les tests puis de nouveau juste avant les gestes publics : HEAD est
    toujours le commit verifie, a jour avec GitHub (apres fetch), et l'arbre est propre ; l'etiquette n'existe pas
    sur GitHub ; gh release view repond « release not found » (publiee, ou toute autre erreur : refus) ; gh a une
    session ; git push --dry-run origin HEAD:main passe. Leve Refus."""
    lancer([o.git, 'fetch', '-q', '--no-tags', 'origin', 'main'])
    if lancer([o.git, 'rev-parse', 'HEAD']).strip() != sha:
        raise Refus('HEAD a change depuis les verifications : rien n\'est publie')
    if lancer([o.git, 'rev-parse', 'origin/main']).strip() != sha:
        raise Refus("main n'est pas a jour avec GitHub (origin/main)")
    if lancer([o.git, 'status', '--porcelain']).strip():
        raise Refus("l'arbre n'est pas propre (git status)")
    if lancer([o.git, 'ls-remote', '--tags', 'origin', 'refs/tags/' + etiquette]).strip():
        raise Refus("l'etiquette %s existe deja sur GitHub" % etiquette)
    vue = subprocess.run([o.gh, 'release', 'view', etiquette, '-R', a.depot_github], capture_output=True, text=True)
    if vue.returncode == 0:
        raise Refus('la version %s est deja publiee sur GitHub' % etiquette)
    if 'release not found' not in vue.stderr + vue.stdout:
        raise Refus('gh release view %s : ni publiee, ni « release not found » (code %d) : etat de GitHub inconnu'
                    % (etiquette, vue.returncode))
    if subprocess.run([o.gh, 'auth', 'status', '--hostname', 'github.com'], capture_output=True).returncode != 0:
        raise Refus("gh n'a pas de session sur github.com (gh auth status)")
    if subprocess.run([o.git, 'push', '--dry-run', '-q', 'origin', 'HEAD:main'], capture_output=True).returncode != 0:
        raise Refus('git push --dry-run origin HEAD:main en echec : le flux ne pourrait pas etre pousse')


def verifier(a, o, racine_git, version):
    """L'etape 1 : tout ce qui doit tenir avant les tests et la compilation. Rend l'etat verifie (numero, commit,
    empreinte de l'identite). Leve Refus."""
    if not version_valide(version):
        raise Refus('version attendue sous la forme X.Y.Z : ' + version)
    marketing = reglage('project.yml', a.cible, 'MARKETING_VERSION')
    if marketing != version:
        raise Refus('MARKETING_VERSION de project.yml : %s, pas %s' % (marketing, version))
    if lancer([o.git, 'status', '--porcelain']).strip():
        raise Refus("l'arbre n'est pas propre (git status)")
    for variable, role in (('GIT_AUTHOR_IDENT', "l'auteur"), ('GIT_COMMITTER_IDENT', 'le committer')):
        nom, adresse = identite_git(o, variable)
        if nom != a.auteur or not NOREPLY.match(adresse):
            raise Refus("le commit du flux est public : %s (git var %s) doit etre %s, a l'adresse noreply de GitHub"
                        % (role, variable, a.auteur))
    etiquette = a.etiquette + version
    if lancer([o.git, 'tag', '-l', etiquette]).strip():
        raise Refus("l'etiquette %s existe deja" % etiquette)
    sha = lancer([o.git, 'rev-parse', 'HEAD']).strip()
    numero = numero_compilation(racine_git, o.git)
    if os.path.exists(a.flux):
        verifier_flux(lire(a.flux), version, numero)
    adresse = 'https://raw.githubusercontent.com/%s/main/%s' % (a.depot_github, chemin_depot(a.flux, racine_git))
    if reglage('project.yml', a.cible, 'FLUX_MISES_A_JOUR') != adresse:
        raise Refus('FLUX_MISES_A_JOUR de project.yml : %s attendu (le flux du depot)' % adresse)
    if a.repetition:
        origine = subprocess.run([o.git, 'remote', 'get-url', 'origin'], capture_output=True, text=True).stdout
        if 'github.com' in origine:
            raise Refus("repetition dans une copie dont l'origine est sur GitHub : son flux d'essai pourrait y etre "
                        'pousse ; cloner le depot dans un dossier a part')
    else:
        branche = lancer([o.git, 'rev-parse', '--abbrev-ref', 'HEAD']).strip()
        if branche != 'main':
            raise Refus('la publication se fait depuis main, pas ' + branche)
        verifier_github(a, o, etiquette, sha)
    notes(a.notes, version)
    verifier_outils_sparkle(o, os.environ.get('DD', ''))
    if not a.repetition:
        if not o.sparkle_bin:
            raise Refus("SPARKLE_BIN (le dossier bin de l'archive de Sparkle) est obligatoire pour publier")
        for outil in (o.sign_update, o.generate_keys):
            if not os.access(outil, os.X_OK):
                raise Refus('outil de Sparkle introuvable dans SPARKLE_BIN : %s' % os.path.basename(outil))
    cle = reglage('project.yml', a.cible, 'CLE_MISES_A_JOUR')
    if a.cle_publique:
        cle_attendue = a.cle_publique
    else:
        cle_attendue = lancer([o.generate_keys, '-p']).strip()
        if cle != cle_attendue:
            raise Refus('la cle publique de project.yml (CLE_MISES_A_JOUR) differe de celle du trousseau')
    if not re.match(r'^[A-Za-z0-9+/]{43}=$', cle_attendue or ''):
        raise Refus('cle publique Ed25519 invalide : %s' % cle_attendue)
    if a.sans_tests and not a.repetition:
        raise Refus('--sans-tests seulement en repetition')
    if not os.path.isfile(a.licence) or not os.path.getsize(a.licence):
        raise Refus('licence de Sparkle absente : %s' % a.licence)
    trousseau = [a.trousseau] if a.trousseau else []
    empreinte = empreinte_identite(lancer([o.security, 'find-identity', '-p', 'codesigning'] + trousseau),
                                   a.identite)
    pem = certificat_du_trousseau(lancer([o.security, 'find-certificate', '-a', '-c', a.identite, '-Z', '-p']
                                         + trousseau), empreinte)
    verifier_certificat(o, a.identite, empreinte, pem=pem)
    if notariser() and not os.environ.get('PROFIL_NOTARISATION'):
        raise Refus('NOTARISER=1 demande PROFIL_NOTARISATION, le profil de notarytool store-credentials')
    return SimpleNamespace(numero=numero, sha=sha, empreinte=empreinte)


def revision_sparkle(dd):
    """La revision de Sparkle resolue par le gestionnaire de paquets dans DD (SourcePackages/workspace-state.json),
    nil si elle ne s'y lit pas."""
    try:
        with open(os.path.join(dd, 'SourcePackages', 'workspace-state.json'), encoding='utf-8') as f:
            etat = json.load(f)
        for dependance in etat['object']['dependencies']:
            if dependance['packageRef']['identity'] == 'sparkle':
                return dependance['state']['checkoutState']['revision']
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return None


def verifier_outils_sparkle(o, dd):
    """sign_update et generate_keys pris dans les artefacts du paquet resolu (SourcePackages/artifacts de DD) : la
    revision resolue doit etre celle de Sparkle 2.10.0 (REVISION_SPARKLE). Leve Refus. Des outils donnes ailleurs
    (SPARKLE_BIN hors de DD) ne sont pas concernes."""
    if not o.sparkle_bin or not dd:
        return
    artefacts = os.path.realpath(os.path.join(dd, 'SourcePackages', 'artifacts'))
    if not os.path.realpath(o.sparkle_bin).startswith(artefacts + os.sep):
        return
    revision = revision_sparkle(dd)
    if revision != REVISION_SPARKLE:
        raise Refus('Sparkle resolu dans %s : revision %s, attendu %s (2.10.0) ; sign_update et generate_keys ne '
                    'sont pas utilises' % (dd, revision or 'illisible', REVISION_SPARKLE))


def chemin_depot(chemin, racine_git):
    """Le chemin d'un fichier depuis la racine du depot (celui de l'adresse brute du flux)."""
    return os.path.relpath(os.path.realpath(chemin), os.path.realpath(racine_git))


def notariser():
    """La notarisation (Developer ID), desactivee par defaut : NOTARISER=1 l'active."""
    return os.environ.get('NOTARISER') == '1'


def code_imbrique(app):
    """Le code a signer avant l'app, dans l'ordre : pour chaque cadre de Contents/Frameworks, ce qu'il contient
    (services XPC, apps, executables), du plus profond au moins profond, puis le cadre lui-meme."""
    cadres = os.path.join(app, 'Contents', 'Frameworks')
    liste = []
    for nom in sorted(os.listdir(cadres)) if os.path.isdir(cadres) else []:
        cadre = os.path.join(cadres, nom)
        if not nom.endswith('.framework'):
            liste.append(cadre)
            continue
        courante = os.path.join(cadre, 'Versions', 'Current')
        dedans = []
        if os.path.isdir(courante):
            for racine, dossiers, fichiers in os.walk(courante):
                for d in list(dossiers):
                    if d.endswith(('.app', '.xpc')):
                        dedans.append(os.path.join(racine, d))
                        dossiers.remove(d)
            for f in sorted(os.listdir(courante)):
                p = os.path.join(courante, f)
                if f != nom[:-len('.framework')] and os.path.isfile(p) and not os.path.islink(p) and os.access(p, os.X_OK):
                    dedans.append(p)
        liste += sorted(dedans, key=lambda p: (-p.count('/'), p))
        liste.append(cadre)
    return liste


def utilitaires(app):
    """Les utilitaires de l'app (Contents/Helpers/*, ptzd), a signer apres les cadres et avant l'app, dans l'ordre.
    Chacun doit etre un fichier ordinaire executable : un lien, un dossier ou un fichier non executable est refuse."""
    dossier = os.path.join(app, 'Contents', 'Helpers')
    liste = []
    for nom in sorted(os.listdir(dossier)) if os.path.isdir(dossier) else []:
        p = os.path.join(dossier, nom)
        if os.path.islink(p) or not os.path.isfile(p) or not os.access(p, os.X_OK):
            raise Refus('Contents/Helpers/%s : seuls des executables ordinaires sont admis' % nom)
        liste.append(p)
    return liste


def verifier_utilitaires(o, app):
    """Les utilitaires signes, relus : aucun droit (codesign -d --entitlements), et le runtime renforce (drapeau
    runtime de codesign -dv). Leve Refus."""
    for p in utilitaires(app):
        nom = os.path.basename(p)
        sortie = subprocess.run([o.codesign, '-d', '--entitlements', '-', '--xml', p], check=True,
                                capture_output=True).stdout
        if sortie.strip():
            try:
                droits = plistlib.loads(sortie)
            except Exception:
                droits = None
            if droits != {}:
                raise Refus("utilitaire signe Contents/Helpers/%s : il porte des droits, il n'en doit avoir aucun" % nom)
        details = subprocess.run([o.codesign, '-dv', p], check=True, capture_output=True, text=True)
        drapeaux = re.search(r'flags=0x[0-9a-f]+\(([^)]*)\)', details.stderr + details.stdout)
        if not drapeaux or 'runtime' not in drapeaux.group(1).split(','):
            raise Refus('utilitaire signe Contents/Helpers/%s : le runtime renforce manque' % nom)


def signer(a, o, empreinte, chemin, droits=True, fichier_droits=None):
    """Signe un code avec l'identite de la publication, par son empreinte (un nom seul prendrait aussi une identite
    dont le nom le contient) : runtime renforce, droits gardes (ou ceux de fichier_droits), horodatage si notarise."""
    cmd = [o.codesign, '--force', '--sign', empreinte]
    if droits:
        cmd += ['--options', 'runtime']
        cmd += ['--entitlements', fichier_droits] if fichier_droits else ['--preserve-metadata=entitlements']
    cmd.append('--timestamp' if notariser() else '--timestamp=none')
    if a.trousseau:
        cmd += ['--keychain', a.trousseau]
    lancer(cmd + [chemin])


def lire_droits(o, app, aucun_permis=False):
    """Les droits d'une app, lus dans sa signature (codesign -d --entitlements - --xml). Leve Refus. Avec
    aucun_permis (les droits poses par Xcode, avant la signature), une signature sans droits rend {} : sans bac a
    sable, Xcode n'en pose aucun."""
    sortie = subprocess.run([o.codesign, '-d', '--entitlements', '-', '--xml', app], check=True,
                            capture_output=True).stdout
    if aucun_permis and not sortie.strip():
        return {}
    try:
        droits = plistlib.loads(sortie)
    except Exception:
        droits = None
    if not isinstance(droits, dict):
        raise Refus("droits de l'app signee illisibles (codesign -d --entitlements)")
    return droits


def droits_pour_signer(o, app, sortie):
    """Les droits avec lesquels l'app est signee : ceux que Xcode a poses, plus, sans notarisation, la levee de la
    validation des bibliotheques. Un certificat auto-signe n'a pas d'equipe : le runtime renforce refuserait alors de
    charger les cadres de l'app (« different Team IDs »), et l'app s'arreterait au lancement. Un Developer ID a une
    equipe : la notarisation s'en passe. Ecrit droits-app.plist dans sortie et rend son chemin."""
    droits = lire_droits(o, app, aucun_permis=True)
    if not notariser():
        droits[VALIDATION_BIBLIOTHEQUES] = True
    chemin = os.path.join(sortie, 'droits-app.plist')
    with open(chemin, 'wb') as f:
        plistlib.dump(droits, f)
    return chemin


def verifier_droits(o, app, identifiant, sans_bac_a_sable=False):
    """Les droits de l'app signee, relus : le bac a sable, en mach-lookup les seuls services de Sparkle
    (<identifiant>-spks et <identifiant>-spki, ni plus ni moins) ; avec sans_bac_a_sable, ni bac a sable ni aucun
    service en mach-lookup (une app sans bac a sable n'en a pas besoin) ; jamais get-task-allow (un debogueur pourrait
    s'attacher a l'app), la levee de la validation des bibliotheques si et seulement si la publication n'est pas
    notarisee (voir droits_pour_signer), et aucune autre exception du runtime renforce (com.apple.security.cs.*) :
    avec la levee, allow-dyld-environment-variables rendrait l'injection de code triviale. Leve Refus."""
    droits = lire_droits(o, app)
    if sans_bac_a_sable:
        if BAC_A_SABLE in droits:
            raise Refus("droits de l'app signee : le bac a sable (%s) est present, l'app n'en a pas" % BAC_A_SABLE)
        if MACH_LOOKUP in droits:
            raise Refus("droits de l'app signee : %s est present, l'app sans bac a sable n'en a pas" % MACH_LOOKUP)
    else:
        if droits.get(BAC_A_SABLE) is not True:
            raise Refus("droits de l'app signee : le bac a sable (%s) manque" % BAC_A_SABLE)
        services = droits.get(MACH_LOOKUP)
        attendus = [identifiant + '-spks', identifiant + '-spki']
        if not isinstance(services, list) or sorted(services) != sorted(attendus):
            raise Refus("droits de l'app signee : %s doit etre exactement %s" % (MACH_LOOKUP, ' et '.join(attendus)))
    if GET_TASK_ALLOW in droits:
        raise Refus("droits de l'app signee : %s est present" % GET_TASK_ALLOW)
    exceptions = sorted(k for k in droits if k.startswith('com.apple.security.cs.') and k != VALIDATION_BIBLIOTHEQUES)
    if exceptions:
        raise Refus("droits de l'app signee : exception du runtime renforce %s" % ', '.join(exceptions))
    if notariser():
        if VALIDATION_BIBLIOTHEQUES in droits:
            raise Refus("droits de l'app signee : %s est present, et la notarisation s'en passe"
                        % VALIDATION_BIBLIOTHEQUES)
    elif droits.get(VALIDATION_BIBLIOTHEQUES) is not True:
        raise Refus("droits de l'app signee : %s manque (sans equipe, l'app ne chargerait pas ses cadres)"
                    % VALIDATION_BIBLIOTHEQUES)


def jeton(contenu, debut, fin, caracteres):
    """Le jeton entier autour de contenu[debut:fin] : etendu des deux cotes tant que les octets sont dans
    `caracteres`, sans point au debut ni a la fin (« field.1.2… », fin de phrase)."""
    while debut > 0 and contenu[debut - 1] in caracteres:
        debut -= 1
    while fin < len(contenu) and contenu[fin] in caracteres:
        fin += 1
    return contenu[debut:fin].strip(b'.')


def trouvaille_admise(contenu, m, debuts):
    """Une trouvaille de FUITE est admise si son jeton entier est dans AUTORISES ou commence par un des `debuts` ;
    un chemin personnel ou temporaire ne l'est jamais."""
    texte = m.group(0)
    if texte.startswith(b'/'):
        return False
    if texte.endswith(b'net'):  # le domaine Tailscale (ts point net)
        t = jeton(contenu, m.start(), m.end(), CARACTERES_DE_NOM)
        return t in AUTORISES
    t = jeton(contenu, m.start(), m.end(), CHIFFRES_ET_POINTS)
    return t in AUTORISES or t.startswith(debuts)


def fuites(fichiers, dmg=False):
    """Le controle de fuite sur des fichiers, binaires compris : chaque trouvaille de FUITE non admise
    (trouvaille_admise ; dans le .dmg, les OID de Sparkle en plus). Rend [(fichier, numero de ligne)], une fois par
    ligne ; n'imprime que le nombre de fichiers et de lignes, jamais ce qui est trouve."""
    debuts = DEBUTS_AUTORISES_DMG if dmg else DEBUTS_AUTORISES
    trouvees = []
    for f in fichiers:
        with open(f, 'rb') as e:
            contenu = e.read()
        lignes = set()
        for m in FUITE.finditer(contenu):
            if not trouvaille_admise(contenu, m, debuts):
                lignes.add(contenu.count(b'\n', 0, m.start()) + 1)
        trouvees += [(f, n) for n in sorted(lignes)]
    dire('controle de fuite (%d fichiers) : %d ligne(s) trouvee(s)' % (len(fichiers), len(trouvees)))
    return trouvees


def est_macho(chemin):
    """Un binaire Mach-O (fin ou universel), d'apres ses quatre premiers octets."""
    with open(chemin, 'rb') as f:
        return f.read(4) in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce',
                             b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf')


def dependances_au_sdk(o, dossier):
    """Les binaires Mach-O du dossier qui dependent du SDK OBSBOT (otool -L : une bibliotheque libdev). Rend leurs
    chemins relatifs."""
    trouves = []
    for p in fichiers_ordinaires(dossier):
        if est_macho(p):
            liens = lancer([o.otool, '-L', p]).splitlines()[1:]
            if any('libdev' in l for l in liens):
                trouves.append(os.path.relpath(p, dossier))
    return trouves


def contenu_interdit(dossier):
    """Ce que le .dmg ne doit jamais porter (INTERDITS : le SDK OBSBOT, un binaire obsbot-ai, les en-tetes du SDK),
    par le nom de chaque element du dossier, liens compris. Rend les chemins relatifs, dans l'ordre."""
    trouves = []
    for racine, dossiers, fichiers in os.walk(dossier):
        dossiers.sort()
        for nom in sorted(dossiers + fichiers):
            if any(m.match(nom) for m in INTERDITS):
                trouves.append(os.path.relpath(os.path.join(racine, nom), dossier))
    return trouves


def noter_geste(sortie, texte):
    """Une ligne horodatee de gestes.txt, dans le dossier des produits : la reprise part de la."""
    with open(os.path.join(sortie, 'gestes.txt'), 'a', encoding='utf-8') as f:
        f.write('%s %s\n' % (datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'), texte))


def geste(sortie, quoi, reprise, action):
    """Un geste de l'etape 7, encadre dans gestes.txt : « tentative : QUOI » est note AVANT, jamais apres. Si l'action
    reussit, elle rend la ligne de sa reussite, notee ensuite ; si elle echoue (ou est interrompue), « echec : QUOI ;
    REPRISE » est note, et l'erreur remonte. Une « tentative » sans suite : le geste est ambigu."""
    noter_geste(sortie, 'tentative : ' + quoi)
    try:
        fait = action()
    except BaseException:
        noter_geste(sortie, 'echec : %s ; %s' % (quoi, reprise))
        raise
    noter_geste(sortie, fait)


def pousser_flux(o):
    """Pousse HEAD (le commit du flux) sur main de GitHub, par HEAD:main (jamais par la branche : si HEAD n'etait pas
    sur main, un push de main ne pousserait rien), puis verifie que main de GitHub est a ce commit (ls-remote)."""
    lancer([o.git, 'push', 'origin', 'HEAD:main'])
    tete = lancer([o.git, 'rev-parse', 'HEAD']).strip()
    distant = lancer([o.git, 'ls-remote', 'origin', 'refs/heads/main']).split()
    if distant[:1] != [tete]:
        raise Refus("apres le push, main de GitHub n'est pas au commit du flux (%s)" % tete)


def publier(a, o=None, maintenant=None):
    o = o or Outils()
    version = a.version
    racine_git = lancer([o.git, 'rev-parse', '--show-toplevel']).strip()
    etat = verifier(a, o, racine_git, version)
    sortie = os.path.abspath(a.repetition or os.path.join('build', 'publication', version))
    os.makedirs(sortie, exist_ok=True)
    dd = os.environ.get('DD', os.path.expanduser('~/Library/Developer/Xcode/DerivedData/%s-publication'
                                                  % a.fichier.lower()))
    if not a.sans_tests:
        for i, t in enumerate(a.test, 1):
            journal = os.path.join(sortie, 'tests-%d.log' % i)
            dire('tests %d/%d : %s (journal : %s)' % (i, len(a.test), t, journal))
            with open(journal, 'w') as j:
                if subprocess.run(t, shell=True, stdout=j, stderr=subprocess.STDOUT,
                                  env=dict(os.environ, DD=dd)).returncode != 0:
                    raise Refus('tests en echec : %s (voir %s)' % (t, journal))

    # 2. les numeros
    numero = etat.numero
    systeme = systeme_minimum('project.yml')
    dire('version %s, numero de compilation %d, macOS %s minimum' % (version, numero, systeme))

    # 3. la compilation Release, ad hoc, sans symboles ni chemins personnels
    etiquette = a.etiquette + version
    chemin_flux_depot = chemin_depot(a.flux, racine_git)
    if a.repetition:
        flux = '%s/%s/main/%s' % (a.url_base, a.depot_github, chemin_flux_depot)
        url_dmg = '%s/%s/releases/download/%s' % (a.url_base, a.depot_github, etiquette)
    else:
        flux = None
        url_dmg = 'https://github.com/%s/releases/download/%s' % (a.depot_github, etiquette)
    reglages = reglages_compilation(numero, carte_des_chemins(racine_git))
    if a.repetition:
        reglages += ['FLUX_MISES_A_JOUR=' + flux]
    if a.cle_publique:
        reglages += ['CLE_MISES_A_JOUR=' + a.cle_publique]
    lancer([o.xcodegen, 'generate', '--quiet'])
    with open(os.path.join(sortie, 'compilation.log'), 'w') as j:
        if subprocess.run([o.xcodebuild, '-project', a.projet, '-scheme', a.schema, '-configuration', 'Release',
                           '-destination', 'generic/platform=macOS', '-derivedDataPath', dd] + reglages + ['build'],
                          stdout=j, stderr=subprocess.STDOUT).returncode != 0:
            raise Refus('compilation en echec (voir %s)' % j.name)
    app = os.path.join(dd, 'Build', 'Products', 'Release', a.nom_app + '.app')
    with open(os.path.join(app, 'Contents', 'Info.plist'), 'rb') as f:
        info = plistlib.load(f)
    # SUVerifyUpdateBeforeExtraction : la signature Ed25519 est exigee, sans repli sur la signature de code (que le
    # detenteur de la cle du certificat auto-signe pourrait reproduire avec sa propre cle Ed25519).
    attendu = {'CFBundleShortVersionString': version, 'CFBundleVersion': str(numero),
               'SUPublicEDKey': a.cle_publique or reglage('project.yml', a.cible, 'CLE_MISES_A_JOUR'),
               'SUFeedURL': flux or reglage('project.yml', a.cible, 'FLUX_MISES_A_JOUR'),
               'SUVerifyUpdateBeforeExtraction': True}
    for cle, valeur in attendu.items():
        if info.get(cle) != valeur:
            raise Refus('Info.plist de l\'app compilee : %s = %r, attendu %r' % (cle, info.get(cle), valeur))
    fichier_droits = droits_pour_signer(o, app, sortie)
    for chemin in code_imbrique(app) + utilitaires(app):
        signer(a, o, etat.empreinte, chemin)
    signer(a, o, etat.empreinte, app, fichier_droits=fichier_droits)
    lancer([o.codesign, '--verify', '--deep', '--strict', app])
    verifier_utilitaires(o, app)
    if not info.get('CFBundleIdentifier'):
        raise Refus("Info.plist de l'app compilee : CFBundleIdentifier manque")
    verifier_droits(o, app, info['CFBundleIdentifier'], a.sans_bac_a_sable)
    # Le certificat feuille de la signature, tel qu'il sera publie.
    prefixe = os.path.join(sortie, 'certificat-')
    for n in os.listdir(sortie):
        if n.startswith('certificat-'):
            os.remove(os.path.join(sortie, n))
    lancer([o.codesign, '-d', '--extract-certificates=' + prefixe, app])
    if not os.path.isfile(prefixe + '0'):
        raise Refus("aucun certificat dans la signature de l'app")
    verifier_certificat(o, a.identite, etat.empreinte, der=prefixe + '0', quoi='le certificat feuille de l\'app')
    exigence = subprocess.run([o.codesign, '-d', '-r-', app], check=True, capture_output=True,
                              text=True).stdout.strip()
    ecrire(os.path.join(sortie, 'exigence.txt'), exigence + '\n')
    dire('exigence de signature : ' + exigence)

    # 4. le .dmg : l'app, le raccourci vers Applications et la licence de Sparkle, controles avant hdiutil
    nom_dmg = '%s-%s.dmg' % (a.fichier, version)
    dmg = os.path.join(sortie, nom_dmg)
    scene = os.path.join(sortie, 'dmg')
    shutil.rmtree(scene, ignore_errors=True)
    os.makedirs(scene)
    lancer([o.ditto, app, os.path.join(scene, a.nom_app + '.app')])
    os.symlink('/Applications', os.path.join(scene, 'Applications'))
    shutil.copyfile(a.licence, os.path.join(scene, os.path.basename(a.licence)))
    trouves = chemins_personnels(scene, motifs_personnels())
    if trouves:
        raise Refus('le contenu du .dmg porte un chemin personnel (%d) : %s ; rien n\'est publie'
                    % (len(trouves), ' ; '.join('%s (%s)' % t for t in trouves[:5])))
    dire('contenu du .dmg : aucun chemin personnel')
    interdits = contenu_interdit(scene) + ['%s (depend de libdev)' % p for p in dependances_au_sdk(o, scene)]
    if interdits:
        raise Refus('le contenu du .dmg porte le SDK OBSBOT, ses en-tetes ou un binaire obsbot-ai (%d) : %s ; rien '
                    "n'est publie" % (len(interdits), ' ; '.join(interdits[:5])))
    liste = os.path.join(sortie, 'contenu-dmg.txt')
    ecrire(liste, liste_du_contenu(scene))
    trouvees = fuites(fichiers_ordinaires(scene) + [liste], dmg=True)
    if trouvees:
        raise Refus("le controle de fuite a trouve des donnees locales dans le contenu du .dmg (%d) : %s ; rien n'est "
                    'publie' % (len(trouvees), ' ; '.join('%s:%d' % (os.path.relpath(f, sortie), n)
                                                         for f, n in trouvees[:5])))
    if os.path.exists(dmg):
        os.remove(dmg)
    lancer([o.hdiutil, 'create', '-quiet', '-volname', '%s %s' % (a.nom_app, version), '-srcfolder', scene,
            '-fs', 'HFS+', '-format', 'UDZO', dmg])
    shutil.rmtree(scene)
    if notariser():
        # Avant la signature Ed25519 : l'agrafe change le .dmg.
        signer(a, o, etat.empreinte, dmg, droits=False)
        lancer([o.xcrun, 'notarytool', 'submit', dmg, '--keychain-profile', os.environ['PROFIL_NOTARISATION'],
                '--wait'])
        lancer([o.xcrun, 'stapler', 'staple', dmg])
        lancer([o.spctl, '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose', dmg])
        dire('notarise et agrafe : ' + dmg)

    # 5. la signature, puis le flux
    signe = [o.sign_update] + (['--ed-key-file', a.cle_privee] if a.cle_privee else []) + ['-p', dmg]
    signature = lancer(signe).strip()
    texte_notes = notes(a.notes, version)
    item = item_flux(version, numero, '%s/%s' % (url_dmg, nom_dmg), os.path.getsize(dmg), signature, systeme,
                     notes_html(texte_notes), maintenant or datetime.datetime.utcnow())
    xml = ajouter_au_flux(lire(a.flux) if os.path.exists(a.flux) else None, a.nom_app, version, item, numero)
    # Le nouveau flux, d'abord a cote : il n'entre dans le depot qu'apres le controle.
    chemin_flux = os.path.join(sortie, 'appcast.xml')
    ecrire(chemin_flux, xml)
    chemin_notes = os.path.join(sortie, 'notes.md')
    ecrire(chemin_notes, texte_notes)
    chemin_message = os.path.join(sortie, 'message-commit.txt')
    ecrire(chemin_message, message_flux(a.nom_app, version))
    dire('signe : %s (%d octets) ; flux : %s' % (dmg, os.path.getsize(dmg), chemin_flux))

    # 6. le controle de fuite sur les textes publies
    trouvees = fuites([a.notes, chemin_flux, chemin_notes, chemin_message] + a.textes)
    if trouvees:
        raise Refus("le controle de fuite a trouve des donnees locales (%d) : %s ; rien n'est publie"
                    % (len(trouvees), ' ; '.join('%s:%d' % t for t in trouvees[:5])))

    # 7. la publication : l'etat relu, puis la version publiee, avec le .dmg (l'etiquette creee par GitHub sur le
    # commit verifie) ; puis le flux, commite et pousse. Chaque geste est note AVANT (tentative), puis APRES.
    if not a.repetition:
        verifier_github(a, o, etiquette, etat.sha)

        def creer_version():
            lancer([o.gh, 'release', 'create', etiquette, dmg, '-R', a.depot_github, '--target', etat.sha,
                    '--title', '%s %s' % (a.nom_app, version), '--notes-file', chemin_notes])
            return 'version publiee : %s, etiquette creee sur %s, avec %s' % (etiquette, etat.sha, nom_dmg)

        geste(sortie, 'gh release create %s sur %s, avec %s' % (etiquette, etat.sha, nom_dmg),
              "GitHub a peut-etre cree la version malgre l'erreur : lire gh release view %s et git ls-remote --tags "
              "origin ; si rien n'y est, relancer publier.sh ; sinon reprendre au commit du flux (appcast.xml et "
              "message-commit.txt de ce dossier)" % etiquette, creer_version)
        dire('publie : https://github.com/%s/releases/tag/%s' % (a.depot_github, etiquette))

    def commiter_flux():
        shutil.copyfile(chemin_flux, a.flux)
        lancer([o.git, 'add', a.flux])
        lancer([o.git, 'commit', '-q', '-F', chemin_message])
        return 'flux commite : %s (%s)' % (chemin_flux_depot, lancer([o.git, 'rev-parse', 'HEAD']).strip())

    geste(sortie, 'commit du flux %s' % chemin_flux_depot,
          "repetition : rien n'est public, relancer" if a.repetition else
          "la version est publiee, le flux ne l'est pas : reprendre ici (git status ; copier appcast.xml de ce "
          "dossier dans le depot, git add, git commit -F message-commit.txt, puis git push origin HEAD:main)",
          commiter_flux)
    if a.repetition:
        dire('repetition : flux commite dans la copie (%s), ni etiquette, ni GitHub, ni Bureau ; produits dans %s'
             % (chemin_flux_depot, sortie))
        return sortie

    def pousser():
        pousser_flux(o)
        return 'flux pousse sur main'

    geste(sortie, 'push du flux (git push origin HEAD:main)',
          "la version est publiee et le flux est commite en local : reprendre au push (lire d'abord git ls-remote "
          "origin refs/heads/main, puis git push origin HEAD:main)", pousser)
    dire('flux commite et pousse sur main : https://raw.githubusercontent.com/%s/main/%s'
         % (a.depot_github, chemin_flux_depot))

    # 8. la remise
    if not a.sans_bureau:
        shutil.copy2(dmg, os.path.expanduser('~/Desktop'))
        dire('copie sur le Bureau : ' + nom_dmg)
    return sortie


def arguments(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sous = p.add_subparsers(dest='commande', required=True)
    q = sous.add_parser('publier')
    q.add_argument('version')
    for nom in ('--nom-app', '--fichier', '--depot-github', '--projet', '--schema', '--cible'):
        q.add_argument(nom, required=True)
    q.add_argument('--test', action='append', default=[], help='commande de tests (shell), dans l\'ordre')
    q.add_argument('--textes', action='append', default=[], help="textes de l'app pour le controle de fuite")
    q.add_argument('--notes', default='NOTES-VERSIONS.md', help='les notes de version (une section par version)')
    q.add_argument('--sans-bac-a-sable', action='store_true',
                   help="l'app n'a pas de bac a sable : ni bac a sable ni services de Sparkle dans ses droits")
    q.add_argument('--identite', required=True, help='nom du certificat de signature, dans le trousseau')
    q.add_argument('--auteur', required=True, help='nom attendu de l\'auteur du commit du flux (git var)')
    q.add_argument('--etiquette', required=True, help="debut de l'etiquette de l'app, suivi de X.Y.Z (maillage-v)")
    q.add_argument('--flux', required=True, help='le flux du depot (appcast.xml), depuis le dossier de publier.sh')
    q.add_argument('--licence', required=True, help='la licence de Sparkle, copiee dans le .dmg')
    q.add_argument('--trousseau', help='en repetition : un trousseau a part, ou chercher l\'identite')
    q.add_argument('--sans-bureau', action='store_true')
    q.add_argument('--repetition', metavar='DOSSIER')
    q.add_argument('--url-base')
    q.add_argument('--cle-privee')
    q.add_argument('--cle-publique')
    q.add_argument('--sans-tests', action='store_true')
    a = p.parse_args(argv)
    if a.repetition and not a.url_base:
        p.error('--repetition demande --url-base')
    if bool(a.cle_privee) != bool(a.cle_publique):
        p.error('--cle-privee et --cle-publique vont ensemble')
    if not a.repetition and (a.url_base or a.cle_privee or a.trousseau):
        p.error('--url-base, --cle-privee, --cle-publique et --trousseau seulement en repetition')
    return a


def main(argv=None):
    a = arguments(sys.argv[1:] if argv is None else argv)
    try:
        publier(a)
    except Refus as e:
        print('refus : %s' % e, file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as e:
        print('echec : %s (code %d)\n%s' % (' '.join(map(shlex.quote, e.cmd)), e.returncode, (e.stderr or '')[-2000:]),
              file=sys.stderr)
        return 1
    except OSError as e:
        print('echec : %s' % e, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
```

Créer `outils/publier.sh` (puis le rendre exécutable : `chmod +x outils/publier.sh`) :

```bash
#!/bin/sh
# Publie une version de PTZBot pour Mac sur GitHub (spec distribution, section 5) : verifications, numeros,
# compilation Release signee par le certificat de Djoko, .dmg signe par Sparkle (cle du trousseau), controle de
# fuite, version publiee (etiquette ptzbot-vX.Y.Z, avec le .dmg), puis le flux des mises a jour
# (mac/app/appcast.xml, qui garde toutes les versions) commite sur main et pousse aussitot, .dmg sur le Bureau.
# Le .dmg porte aussi la licence de Sparkle 2.10.0 (outils/Sparkle-LICENSE.txt, le fichier LICENSE de l'etiquette
# 2.10.0, entier) ; le commit du flux est signe Djoko-cli, a l'adresse noreply de GitHub.
# Repris de maillage-thread ; la logique est dans outils/publication.py, ses tests dans outils/tests.
#   outils/publier.sh X.Y.Z [--sans-bureau]
# La repetition, sans GitHub ni Bureau (spec, section 10), avec la cle du trousseau, ou une paire d'essai :
#   outils/publier.sh X.Y.Z --repetition DOSSIER --url-base URL [--cle-privee FICHIER --cle-publique CLE]
#                           [--trousseau TROUSSEAU] [--sans-tests]
# SPARKLE_BIN : le dossier bin de l'archive de Sparkle 2.10.0 (sign_update, generate_keys) ; par defaut, celui que
# le gestionnaire de paquets de Xcode a resolu dans DD (SourcePackages/artifacts/sparkle/Sparkle/bin).
# NOTARISER=1 (desactive par defaut) : notarisation du .dmg, avec PROFIL_NOTARISATION, le profil que
# notarytool store-credentials a range dans le trousseau ; il faut alors un Developer ID pour IDENTITE_SIGNATURE.
# Produits : mac/app/build/publication/X.Y.Z/ ; compilation dans DD (par defaut DerivedData/ptzbot-publication).
set -eu
cd "$(dirname "$0")/../mac/app"
# L'identite de signature de la version publiee, a ce seul endroit : le certificat auto-signe de Djoko, trouve par
# son nom dans le trousseau (les compilations de travail et les tests restent ad hoc).
IDENTITE_SIGNATURE=${IDENTITE_SIGNATURE:-Djoko-cli Code Signing}
DD=${DD:-$HOME/Library/Developer/Xcode/DerivedData/ptzbot-publication}
export DD
if [ -z "${SPARKLE_BIN:-}" ]; then
  # Les outils de Sparkle viennent du paquet resolu (version figee dans project.yml) : le projet est genere et ses
  # paquets resolus dans DD avant les verifications (le .xcodeproj n'est pas versionne, l'arbre reste propre).
  xcodegen generate --quiet
  xcodebuild -resolvePackageDependencies -project PTZBot.xcodeproj -scheme PTZBot -derivedDataPath "$DD" >/dev/null
  SPARKLE_BIN="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin"
fi
export SPARKLE_BIN
exec /usr/bin/python3 ../../outils/publication.py publier "$@" --identite "$IDENTITE_SIGNATURE" \
  --auteur Djoko-cli --etiquette ptzbot-v --flux appcast.xml --licence ../../outils/Sparkle-LICENSE.txt \
  --notes ../../NOTES-VERSIONS.md --sans-bac-a-sable \
  --nom-app PTZBot --fichier PTZBot --depot-github Djoko-cli/obsbot-nacelle \
  --projet PTZBot.xcodeproj --schema PTZBot --cible PTZBot \
  --test 'cd ../../Packages/NacelleProtocol && swift test' \
  --test 'cd ../ptzd && swift test' \
  --test 'cd PTZBotKit && swift test' \
  --test '/usr/bin/python3 -m unittest discover -s ../../outils/tests' \
  --test 'bash -n ../../scripts/install-mac.sh' \
  --textes PTZBot/Localizable.xcstrings --textes PTZBot/InfoPlist.xcstrings \
  --textes PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd outils/tests && /usr/bin/python3 -m unittest discover -s . 2>&1 | tail -4)
(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' | grep -v appintents && ./check-bundle.sh)
```

Attendu : tout passe (publication : 110 tests, « OK », « ** BUILD SUCCEEDED ** » pour l'app, puis les trois lignes « ok : » de `check-bundle.sh`), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add .gitignore \
    NOTES-VERSIONS.md \
    mac/app/build-helpers.sh \
    outils/Sparkle-LICENSE.txt \
    outils/publication.py \
    outils/publier.sh \
    outils/tests/test_publication.py
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|8\.8\.8\.8|256\.0\.0\.1|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
B2 : outils de publication repris de maillage-thread

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés plus haut sont déjà indexés par `git rm`.

### Tâche 5 : README bilingue, `install-mac.sh` et amendements de la spec

**But :** Le README est écrit en anglais, puis en français, avec des liens vers chaque langue en tête. Il couvre l'installation par le DMG, la première ouverture (Gatekeeper), les mises à jour, le SDK et les outils d'Apple, la langue, et la compilation depuis les sources. `install-mac.sh` ne fournit plus le SDK. La spec B2 reçoit son § 12 (amendements du prototype et du banc).

**Fichiers :**
- Modifier : `README.md`
- Modifier : `docs/superpowers/specs/2026-10-08-distribution-design.md`
- Modifier : `scripts/install-mac.sh`

**Interfaces :**
- Aucune nouvelle interface.

- [ ] **Étape 1 : Écrire les fichiers**

Remplacer tout le contenu de `README.md` par :

````markdown
# OBSBOT Nacelle

[English](#english) · [Français](#francais)

<a id="english"></a>

## English

Remotely control the gimbal of an OBSBOT Tiny 2 from an iPhone.

The camera is plugged over USB into a Mac that already streams it with [go2rtc](https://github.com/AlexxIT/go2rtc), and to HomeKit through Homebridge. HomeKit cannot drive a pan/tilt/zoom: this project adds what is missing.

> Personal project, not affiliated with OBSBOT.

### Status

- **Mac side**: the **PTZBot for Mac** app, which contains `ptzd`, installs from the disk image of the published releases (see "Installing PTZBot for Mac"), then updates itself. It can also be built from source with `scripts/install-mac.sh`. The OBSBOT SDK is then installed from the app, which compiles `obsbot-ai` on the Mac.
- **iOS app** (PTZBot): installs from Xcode onto the iPhone (see "iOS app" below).

Design: [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [local access spec](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [discovery and QR code spec](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [Mac app spec](docs/superpowers/specs/2026-10-06-app-mac-design.md) · [ptzd in the app spec](docs/superpowers/specs/2026-10-07-ptzd-dans-app-design.md) · [distribution spec](docs/superpowers/specs/2026-10-08-distribution-design.md) · [Mac side plan](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [iOS app plan](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [local access plan](docs/superpowers/plans/2026-10-06-acces-local.md) · [discovery and QR code plan](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [Mac app plan](docs/superpowers/plans/2026-10-06-app-mac.md) · [feasibility tests](docs/spike/2026-10-05-faisabilite.md). The design documents are in French.

### Architecture

```
iPhone: SwiftUI app                          Mac (the go2rtc one)
┌───────────────────────────┐            ┌──────────────────────────────────┐
│ Joystick, zoom,           │            │ PTZBot.app ▸ ptzd (child)        │
│ privacy, video offer ─────┼─ WebSocket▶│   ├─ UVC commands ──▶ Tiny 2     │
│                           │ authentic. │   ├─ runs obsbot-ai (SDK)        │
│                           │◀─ state ───│   └─ relays the offer ┐          │
│                           │            │                       ▼          │
│ WebRTC video ◀────────────┼─ frames ───│ go2rtc (local API) ◀── ffmpeg    │
└───────────────────────────┘            └──────────────────────────────────┘
   at home: Wi-Fi (Bonjour, local address); away: the same address through Tailscale
```

- **`ptzd`**: a Swift service, stored inside the app (`PTZBot.app/Contents/Helpers/ptzd`) and started by it: it only runs while PTZBot is open, and stops by itself if the app goes away, even when force-quit. PTZBot restarts it if it stops unexpectedly. It is the only one sending gimbal commands to the camera, over UVC. It listens on the Mac's Tailscale address, on 127.0.0.1, and on its Wi-Fi and Ethernet interfaces, where it advertises itself over Bonjour (`_nacelle._tcp`). Each iPhone is paired once, on the local network, by scanning the QR code shown by the Mac app (or `ptzd pair`); after that, it signs a challenge on every connection. On the local network, everything also goes through a TLS channel: during pairing, its key is the QR code's secret; afterwards, a key specific to each iPhone, handed over at pairing. Only connections from 127.0.0.1 skip the challenge.
- **`obsbot-ai`**: a small helper that turns the camera's AI tracking on or off with the OBSBOT SDK, then exits. `ptzd` runs it at the first joystick move (tracking would fight the moves), when entering privacy mode and on the apps' request. PTZBot compiles it on the user's Mac, from its source shipped in the app (`Contents/Resources/obsbot-ai.cpp`) and the SDK headers, with Apple's developer tools; it lives next to the SDK, in `~/Library/Application Support/ObsbotNacelle/sdk/`, and `ptzd` runs it with `DYLD_LIBRARY_PATH` pointing there. Neither the SDK nor `obsbot-ai` is in the app or the disk image: the SDK license does not allow redistribution.
- **PTZBot for Mac**: a menu bar app that starts `ptzd` and talks to it over 127.0.0.1: QR code pairing, paired devices and connected clients, kicking out, privacy and AI tracking (see "Mac app" below). It updates itself with [Sparkle](https://sparkle-project.org).
- **go2rtc**: `ptzd` relays the app's WebRTC offer to it; the frames then go straight from go2rtc to the iPhone. See "go2rtc" below to close it to the local network.

### Installing PTZBot for Mac

Requirements:

- an Apple silicon Mac running macOS 15 or later;
- Tailscale on the Mac to control the camera away from home (without it, `ptzd` only listens on 127.0.0.1 and on the local network);
- OBSBOT Center closed: when open, it skews the tilt readback;
- for AI tracking only: the OBSBOT SDK, to request at [obsbot.com/sdk](https://www.obsbot.com/sdk), and Apple's developer tools (PTZBot offers to install them).

Then:

1. Download `PTZBot-X.Y.Z.dmg` from the [releases page](https://github.com/Djoko-cli/obsbot-nacelle/releases), open it and drag **PTZBot** into **Applications**.
2. **First launch (Gatekeeper).** PTZBot is signed but not notarized: the first time, macOS refuses to open it. Open **System Settings › Privacy & Security**, click **Open Anyway** next to the message about PTZBot, and confirm. This is needed only once.
3. On first launch:
   - **Previous installation.** If the launchd agent `io.github.djoko-cli.obsbot-nacelle.ptzd` from an earlier version is there, PTZBot offers to replace it. **Replace** stops it, renames its plist to `.plist.bak`, moves the old binaries in `bin/` to the Trash and takes over the SDK in `lib/`. Paired iPhones and settings are kept. **Later** keeps the old `ptzd` (the panel shows "Previous installation"); the question comes back at the next launch.
   - **`config.json`.** If it is missing, PTZBot creates it with the Mac's Tailscale address, or on 127.0.0.1 only without Tailscale (the panel says so).
   - **Permissions.** macOS asks for local network access for PTZBot (`ptzd` depends on it): answer **Allow**. At the iPhone's first connection, it may also ask whether `ptzd` may accept incoming connections: answer **Allow**. The question may come back after an update, because the binary changes.
4. **OBSBOT SDK.** In the panel, **OBSBOT SDK › Install SDK…**: choose the `.zip` archive received from OBSBOT or its unzipped folder. A lone `libdev.dylib` is refused: the headers are needed to compile `obsbot-ai`. PTZBot takes `macos/arm64-release/libdev.dylib` and the `include/` folder next to `macos/`; the other copies of the library in the archive are listed and ignored. The window shows the architecture, the signature, the origin and the quarantine; **Allow This SDK** copies the library and the headers into `sdk/`, removes the quarantine from these copies only, compiles `obsbot-ai` with Apple's developer tools, then checks that it loads the SDK. Everything happens in one go: if any step fails, the previous SDK and `obsbot-ai` are kept, and the compiler output goes to `obsbot-ai-compilation.log`. Without the SDK, everything works except AI tracking.
   - **Developer tools.** Without them, the panel's SDK line and the **OBSBOT SDK** window offer **Install Developer Tools…** before any choice of SDK. The button starts Apple's installation (`xcode-select --install`), only when you click it: accept in Apple's window, then reopen the panel, or click **Check Again** in the window. An SDK already installed whose `obsbot-ai` must be recompiled shows "Tools required", with the same button.
   - **SDK installed by an earlier version.** An SDK copied without its headers (a single `libdev.dylib`) shows "Incomplete", with "Reinstall the SDK from its archive or folder: its headers are missing." under it: reinstall it from the archive.

### Updates

- PTZBot checks for updates at launch and every 24 hours, on the `mac/app/appcast.xml` feed of this repository. Each release is signed with an Ed25519 key, checked before the update is even unpacked (`SUVerifyUpdateBeforeExtraction`): Sparkle refuses a badly signed one, whatever its code signature.
- An update downloads silently and installs when the app quits, or right away with **Install and Relaunch**. PTZBot first stops `ptzd`, as with **Quit**.
- **Check for Updates…** is in the panel; **Settings…** has **Check automatically** and **Install automatically** (both on by default), **Open at login** and the version.
- After an update, if the `obsbot-ai` source changed, PTZBot recompiles it at launch ("Recompiling…") without asking anything. If the tools are missing or the compilation fails, the previous `obsbot-ai` stays in use and the panel says so.
- Builds made from source (build number 1, as with `scripts/install-mac.sh`) never look for updates.

### Building from source

Requirements: Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The OBSBOT SDK is no longer needed to build the app.

```bash
scripts/install-mac.sh
```

The script builds the app (`ptzd` in `Contents/Helpers`, the `obsbot-ai` source in `Contents/Resources`, Sparkle in `Contents/Frameworks`), quits the running app, installs it into `~/Applications/PTZBot.app` and launches it. It touches neither launchd nor the files in `~/Library/Application Support/ObsbotNacelle/`. Such a build keeps build number 1: Sparkle never starts in it. Keep a single copy of PTZBot: to go back to the published releases, move `~/Applications/PTZBot.app` to the Trash and install the disk image.

`mac/app/check-bundle.sh` checks a Release build: `ptzd`, the `obsbot-ai` source and Sparkle are present; the SDK, its headers and any `obsbot-ai` binary are absent.

Publishing a release (maintainer): write its section in `NOTES-VERSIONS.md` (**English**, then **Français**), set `MARKETING_VERSION` in `mac/app/project.yml`, then run `outils/publier.sh X.Y.Z` from a clean, up-to-date `main`. If it stops halfway, resume from `gestes.txt` in the products folder, never by running the script again. `outils/publier.sh X.Y.Z --repetition FOLDER --url-base http://127.0.0.1:PORT …` rehearses everything without GitHub.

### Settings (`config.json`)

| Key | Role | Default |
|---|---|---|
| `listenAddress` | The Mac's Tailscale address, or 127.0.0.1 without Tailscale; created by PTZBot at first launch | required |
| `port` | WebSocket port | 1985 |
| `panMaxSpeed`, `tiltMaxSpeed` | Maximum UVC speeds (pan 1–80, tilt 1–120) | 40, 60 |
| `panDirection`, `tiltDirection` | Direction of each axis, +1 or -1 | +1, +1 |
| `aiPath` | Path of `obsbot-ai`, relative to `~/Library/Application Support/ObsbotNacelle` (or absolute); when PTZBot starts `ptzd`, `--ai` wins (`sdk/obsbot-ai`; the old `aiOffPath` key is read if this one is missing, unless it names `obsbot-ai-off`) | `bin/obsbot-ai` |
| `localNetwork` | Listening and Bonjour advertising on Wi-Fi and Ethernet | `true` |
| `go2rtcAPI` | go2rtc's local API, to relay the video | `http://127.0.0.1:1984` |
| `streamName` | Relayed go2rtc stream | `obsbot` |

After a change, restart the service: in the panel, turn **ptzd service** off and on again.

### Troubleshooting

| Need | Command |
|---|---|
| Service log | `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log` |
| SDK output | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai.log` |
| `obsbot-ai` compilation | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai-compilation.log` |
| Read the camera position | `/Applications/PTZBot.app/Contents/Helpers/ptzd uvc get` |
| Paired devices | `/Applications/PTZBot.app/Contents/Helpers/ptzd devices` |
| See the Bonjour advertisement | `dns-sd -B _nacelle._tcp` (Ctrl-C to stop) |
| Talk to the service | `swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"adminWatch"}' wait 2` |

For a build from source, the app is in `~/Applications/PTZBot.app`.

The Mac cannot reach itself through its Tailscale address: locally, use 127.0.0.1.

`ptzd pair`, `ptzd devices` and `ptzd revoke` remain usable from the command line with the app's binary; `ptzd pair` needs the service running, so PTZBot open. The `ptzd` log and command line stay in French.

### Mac app (PTZBot)

It lives in the menu bar (the Tiny 2 icon), without a Dock icon, in English, or in French on a Mac set to French. **Settings… › Language** chooses Automatic (system language), Français or English right away; Sparkle's update windows follow at the next launch. The iPhone only controls the camera while PTZBot is open: **Open at login** makes that the normal use. Its panel shows:

- the **ptzd service** switch, remembered from one launch to the next, and the state of `ptzd` ("Active", "Starting…", "Stopped", "Restarted after an unexpected stop (n)", "Not responding" with a link to its log) and of the camera. Beyond 5 stops in 2 min, PTZBot stops restarting `ptzd`: "ptzd keeps stopping: open the log". It does not restart it either if another `ptzd` is already running (`ptzd.lock` lock or 127.0.0.1 port taken: "Port 1985 is already in use…"), if `config.json` is invalid or if its arguments are refused;
- the **OBSBOT SDK** line, with a short state on the right ("Ready", "Missing", "Quarantined", "Incompatible", "Does not load", "Tools required", "Incomplete", "Recompiling…", "Compile failed", "obsbot-ai not found"), and under it, on the full width, what it means and **Install SDK…**, **Install Developer Tools…** or, when the SDK is ready, **Change…**; until the SDK is ready, **AI tracking** is greyed out ("OBSBOT SDK required"), unless a previous `obsbot-ai` is still in use;
- the **Privacy** and **AI tracking** switches (tracking shows the last order: the real state cannot be read, a gesture in front of the camera can change it);
- the connected clients, with **Kick Out**: the connection is cut and the device refused for 10 min (while `ptzd` runs), without losing its pairing;
- **Pair an iPhone…**: the QR code as an image, valid for 5 min; closing the window cancels it;
- **Devices…**: the paired devices, **Unblock** and **Remove…** (the device is removed and its connections cut right away);
- **Check for Updates…** on its own line, then **Settings…** (**Check automatically**, **Install automatically**, **Open at login**, the version, for example "PTZBot 1.0.0 (412)"; macOS may ask for approval in System Settings › General › Login Items) and **Quit**: stops `ptzd` (6 s at most), then the app.

If local network access is denied to PTZBot, the panel says so, with a button to the privacy settings: iPhones then only find the Mac through Tailscale.

The app goes through `ptzd`'s trusted connection (127.0.0.1): any program on the Mac can do the same.

Tests: `(cd mac/app/PTZBotKit && swift test)`; publication tools: `python3 -m unittest discover -s outils/tests`.

### iOS app

Requirements: Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), an Apple ID (a free account is enough), the Mac side installed, and Tailscale on the iPhone to control the camera away from home. The iOS app is still in French only.

1. Set the signing team in a local setting, not versioned. Its identifier is the OU field of the "Apple Development" certificates in the keychain:

   ```bash
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline | grep organizationalUnitName
   ```

   ```bash
   printf 'DEVELOPMENT_TEAM = %s\n' <identifier> > ios/Config/Local.xcconfig
   ```

2. Generate the project, then build and install onto the iPhone, plugged in or paired. `<UDID>` is its identifier, given by `xcrun devicectl list devices`:

   ```bash
   (cd ios && xcodegen)
   ```

   ```bash
   xcodebuild build -project ios/Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS,id=<UDID>' -derivedDataPath ios/.build -allowProvisioningUpdates
   ```

   ```bash
   xcrun devicectl device install app --device <UDID> ios/.build/Build/Products/Debug-iphoneos/Nacelle.app
   ```

3. At first launch, iOS asks you to trust the developer: Settings › General › VPN & Device Management.
4. At first launch, PTZBot looks for the Mac on Wi-Fi ("Recherche du Mac à proximité…"): iOS asks for local network access, answer **Allow**.
5. Pair the iPhone, on the same network as the Mac: in PTZBot on the Mac, **Pair an iPhone…** shows a QR code (valid for 5 min, single use, 3 attempts). As a fallback, for example over SSH, `ptzd pair` shows it in the Terminal:

   ```bash
   /Applications/PTZBot.app/Contents/Helpers/ptzd pair
   ```

   Then, in the iPhone app, tap **Scanner le QR code** and aim at the Mac's screen (iOS asks for camera access). The iPhone's key stays in its Secure Enclave; the Mac keeps its public key and the secret of the local network's encrypted channel, in `devices.json` (mode 600). The app remembers the Mac's local address in Réglages › Adresse du Mac (repli).

   Updating from a version that asked for the Tailscale name: the "Adresse du Mac (repli)" field keeps it. To switch to the local address (which also works over 4G through the subnet route), clear this field and tap Enregistrer before scanning: the app will store the Mac's local address there.
6. Away from home, the app reaches that same address through Tailscale if a tailnet device publishes the local network (subnet routing) and if the iPhone accepts routes. Otherwise, put the Mac's Tailscale name in the field (the `DNSName` field, without the final dot, of `tailscale status --self --peers=false --json` on the Mac): the app reaches it through `ptzd`'s Tailscale listener, without TLS.

Removing an iPhone: in PTZBot on the Mac, **Devices…** › **Remove…**; its connections are cut right away, after a message telling it: a connected iPhone forgets its pairing and goes back to the pairing screen. An iPhone offline at that moment learns it at its next connection through Tailscale; on the local network, it is simply refused and shows "Mac injoignable": on it, "Oublier cet appairage", then scan a new QR code. From the command line, `ptzd devices` gives the start of its identifier, then `ptzd revoke <start>`; its already open connections then last until they end. From the iPhone, "Oublier cet appairage" also removes it from the Mac's list when it is connected.

With a free Apple account, the app expires after 7 days: redo step 2.

Icon (optional): put an `ios/Local/Assets.xcassets` catalog holding an `AppIcon` icon set (one 1024 × 1024 image), and add `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` to `ios/Config/Local.xcconfig`. The `ios/Local/` folder is not versioned: without it, the app builds with the default icon.

Tests: `(cd ios && xcodegen && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build)`.

### go2rtc

`ptzd` relays the video negotiation to go2rtc's API on 127.0.0.1: the API therefore no longer needs to be open to the network. Suggested configuration (in `go2rtc.yaml`, to adapt):

```yaml
api:
  listen: "127.0.0.1:1984"
rtsp:
  listen: ":8554"
  username: "<user>"
  password: "<password>"
webrtc:
  listen: ":8555"
ffmpeg:
  bin: /opt/homebrew/bin/ffmpeg   # full path: under launchd, PATH does not contain /opt/homebrew/bin
streams:
  obsbot:
    - exec:…   # camera video (H.264)
    - exec:…   # camera microphone (AAC, for HomeKit)
    - ffmpeg:obsbot#audio=opus   # the same sound in Opus, for PTZBot (WebRTC)
```

- go2rtc lets local clients (127.0.0.1) skip the RTSP password: `exec:` sources that publish to `{output}` keep working unchanged.
- A network RTSP client, such as Homebridge, must then give the user and password in the stream address: `rtsp://<user>:<password>@<Mac>:8554/obsbot`.
- WebRTC port 8555 stays open: without an offer negotiated by `ptzd`, it gives no image.
- Sound in PTZBot: WebRTC does not carry AAC. The `ffmpeg:obsbot#audio=opus` source converts it to Opus as soon as PTZBot is open, even muted (the button only stops playback, so that sound comes back immediately). Without the `ffmpeg: bin:` line, go2rtc started by launchd does not find `ffmpeg` and the audio track stays silent, with no error message.
- `go2rtc.yaml` holds the RTSP password: set it to mode 600 (`chmod 600 go2rtc.yaml`).
- The RTSP stream to Homebridge, credentials included, travels in clear on the local network: a device intercepting this traffic can read them, as well as the images.
- The pairing QR code (PTZBot for Mac window, or `ptzd pair` and the URL shown under it) allows pairing a device for 5 minutes: only show it while scanning.
- Never expose 127.0.0.1:1985 to the network, for example with `tailscale serve` or `ssh -L`: connections from 127.0.0.1 skip authentication, any remote client coming through there would control the camera.

### Uninstalling

In PTZBot for Mac, **Settings…** › uncheck **Open at login**, then **Quit** (`ptzd` stops with the app), and move `/Applications/PTZBot.app` (or `~/Applications/PTZBot.app` for a build from source) to the Trash.

The data stays in `~/Library/Application Support/ObsbotNacelle/` (settings, paired iPhones, SDK, its headers and `obsbot-ai`) and the logs in `~/Library/Logs/obsbot-nacelle/`, until you delete them:

```bash
rm -r ~/Library/Application\ Support/ObsbotNacelle ~/Library/Logs/obsbot-nacelle
```

After a migration, the old agent's plist stays at `~/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.ptzd.plist.bak`: it can be deleted.

### Contents

| Path | Role |
|---|---|
| `Packages/NacelleProtocol/` | Messages exchanged between the apps and `ptzd`, shared by both |
| `mac/ptzd/` | The service: logic (`PTZCore`), pairing and authentication (`PTZAuth`), USB access (`CUVC`, `UVCCamera`), WebSocket server and local listener (`PTZServer`) |
| `mac/ai/` | The `obsbot-ai` helper (C++): its source, shipped in the app and compiled on the user's Mac; `build.sh` builds it locally with the SDK in `vendor/`, for tests |
| `mac/app/` | The PTZBot for Mac app: `project.yml` (xcodegen), interface (`PTZBot/`), tested logic (`PTZBotKit/`), helper build phase (`build-helpers.sh`), bundle check (`check-bundle.sh`) and update feed (`appcast.xml`, written at publication) |
| `mac/tools/` | Test WebSocket client |
| `ios/` | The iOS app: `project.yml` (xcodegen), sources and tests |
| `outils/` | Publication of a release: `publier.sh`, `publication.py` and their tests, Sparkle's license |
| `NOTES-VERSIONS.md` | Release notes, in English then in French |
| `scripts/install-mac.sh` | Building and installing the app from source on the Mac |
| `docs/` | Specs, plans and feasibility tests |
| `spike/` | **Throwaway** probes from the feasibility tests |

### License

MIT. See [LICENSE](LICENSE). The disk image also carries the license of [Sparkle](https://sparkle-project.org) 2.10.0 (`outils/Sparkle-LICENSE.txt`).

<a id="francais"></a>

## Français

Piloter à distance la nacelle d'une OBSBOT Tiny 2 depuis l'iPhone.

La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](https://github.com/AlexxIT/go2rtc), et vers HomeKit via Homebridge. HomeKit ne sait pas piloter un pan/tilt/zoom : ce projet ajoute ce qui manque.

> Projet personnel, sans lien avec OBSBOT.

### Statut

- **Côté Mac** : l'app **PTZBot pour Mac**, qui contient `ptzd`, s'installe depuis l'image disque des versions publiées (voir « Installer PTZBot pour Mac »), puis se met à jour seule. On peut aussi la compiler depuis les sources avec `scripts/install-mac.sh`. Le SDK OBSBOT s'installe ensuite depuis l'app, qui compile `obsbot-ai` sur le Mac.
- **App iOS** (PTZBot) : s'installe depuis Xcode sur l'iPhone (voir « App iOS » plus bas).

Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [spec de l'accès local](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [spec de la découverte et du QR code](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [spec de l'app Mac](docs/superpowers/specs/2026-10-06-app-mac-design.md) · [spec de ptzd dans l'app](docs/superpowers/specs/2026-10-07-ptzd-dans-app-design.md) · [spec de la distribution](docs/superpowers/specs/2026-10-08-distribution-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [plan de l'accès local](docs/superpowers/plans/2026-10-06-acces-local.md) · [plan de la découverte et du QR code](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [plan de l'app Mac](docs/superpowers/plans/2026-10-06-app-mac.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).

### Architecture

```
iPhone : app SwiftUI                         Mac (celui de go2rtc)
┌───────────────────────────┐            ┌──────────────────────────────────┐
│ Joystick, zoom,           │            │ PTZBot.app ▸ ptzd (enfant)       │
│ vie privée, offre vidéo ──┼─ WebSocket▶│   ├─ commandes UVC ──▶ Tiny 2    │
│                           │ authentifié│   ├─ lance obsbot-ai (SDK)       │
│                           │◀─ état ────│   └─ relaie l'offre ──┐          │
│                           │            │                       ▼          │
│ Vidéo WebRTC ◀────────────┼─ images ───│ go2rtc (API en local) ◀── ffmpeg │
└───────────────────────────┘            └──────────────────────────────────┘
   à la maison : Wi-Fi (Bonjour, adresse locale) ; dehors : la même adresse par Tailscale
```

- **`ptzd`** : un service en Swift, rangé dans l'app (`PTZBot.app/Contents/Helpers/ptzd`) et lancé par elle : il ne tourne que pendant que PTZBot est ouvert, et s'arrête de lui-même si l'app disparaît, même tuée de force. PTZBot le relance s'il s'arrête de façon inattendue. C'est le seul à envoyer des commandes de nacelle à la caméra, en UVC. Il écoute sur l'adresse Tailscale du Mac, sur 127.0.0.1, et sur ses interfaces Wi-Fi et Ethernet, où il s'annonce par Bonjour (`_nacelle._tcp`). Chaque iPhone est appairé une fois, sur le réseau local, en scannant le QR code affiché par l'app Mac (ou `ptzd pair`) ; ensuite, il signe un défi à chaque connexion. Sur le réseau local, tout passe en plus dans un canal TLS : pendant l'appairage, sa clé est le secret du QR code ; ensuite, une clé propre à chaque iPhone, remise à l'appairage. Seules les connexions venues de 127.0.0.1 sont dispensées du défi.
- **`obsbot-ai`** : un petit utilitaire qui allume ou coupe le suivi IA de la caméra avec le SDK OBSBOT, puis se termine. `ptzd` le lance au premier mouvement du joystick (le suivi contrerait les mouvements), à l'entrée en vie privée et sur ordre des apps. PTZBot le compile sur le Mac de l'utilisateur, à partir de sa source livrée dans l'app (`Contents/Resources/obsbot-ai.cpp`) et des en-têtes du SDK, avec les outils de développement d'Apple ; il est rangé à côté du SDK, dans `~/Library/Application Support/ObsbotNacelle/sdk/`, et `ptzd` le lance avec `DYLD_LIBRARY_PATH` vers ce dossier. Ni le SDK ni `obsbot-ai` ne sont dans l'app ou l'image disque : la licence du SDK n'en autorise pas la redistribution.
- **PTZBot pour Mac** : une app dans la barre des menus, qui lance `ptzd` et lui parle par 127.0.0.1 : appairage par QR code, appareils et clients connectés, expulsion, vie privée et suivi IA (voir « App Mac » plus bas). Elle se met à jour avec [Sparkle](https://sparkle-project.org).
- **go2rtc** : `ptzd` lui relaie l'offre WebRTC de l'app ; les images vont ensuite directement de go2rtc à l'iPhone. Voir « go2rtc » plus bas pour le fermer au réseau local.

### Installer PTZBot pour Mac

Prérequis :

- un Mac Apple Silicon sous macOS 15 ou plus récent ;
- Tailscale sur le Mac pour piloter hors de la maison (sans lui, `ptzd` n'écoute que sur 127.0.0.1 et sur le réseau local) ;
- OBSBOT Center fermé : ouvert, il fausse la relecture du tilt ;
- pour le suivi IA seulement : le SDK OBSBOT, à demander sur [obsbot.com/sdk](https://www.obsbot.com/sdk), et les outils de développement d'Apple (PTZBot propose de les installer).

Puis :

1. Télécharger `PTZBot-X.Y.Z.dmg` sur la [page des versions](https://github.com/Djoko-cli/obsbot-nacelle/releases), l'ouvrir et glisser **PTZBot** dans **Applications**.
2. **Première ouverture (Gatekeeper).** PTZBot est signé mais pas notarisé : la première fois, macOS refuse de l'ouvrir. Ouvrir **Réglages Système › Confidentialité et sécurité**, cliquer sur **Ouvrir quand même** à côté du message sur PTZBot, puis confirmer. Ce n'est demandé qu'une fois.
3. Au premier lancement :
   - **Ancienne installation.** Si l'agent launchd `io.github.djoko-cli.obsbot-nacelle.ptzd` d'une version précédente est là, PTZBot propose de le remplacer. **Remplacer** l'arrête, renomme sa plist en `.plist.bak`, met les anciens binaires de `bin/` à la corbeille et reprend le SDK de `lib/`. Les iPhone appairés et les réglages sont conservés. **Plus tard** garde l'ancien `ptzd` (le panneau affiche « Ancienne installation ») ; la question revient au lancement suivant.
   - **`config.json`.** S'il manque, PTZBot le crée avec l'adresse Tailscale du Mac, ou sur 127.0.0.1 seulement sans Tailscale (le panneau le signale).
   - **Autorisations.** macOS demande l'accès au réseau local pour PTZBot (`ptzd` en dépend) : répondre **Autoriser**. À la première connexion de l'iPhone, il peut aussi demander s'il faut autoriser `ptzd` à accepter des connexions entrantes : répondre **Autoriser**. La question peut revenir après une mise à jour, car le binaire change.
4. **SDK OBSBOT.** Dans le panneau, **SDK OBSBOT › Installer le SDK…** : choisir l'archive `.zip` reçue d'OBSBOT ou son dossier décompressé. Un `libdev.dylib` seul est refusé : les en-têtes sont nécessaires pour compiler `obsbot-ai`. PTZBot prend `macos/arm64-release/libdev.dylib` et le dossier `include/` à côté de `macos/` ; les autres copies de la bibliothèque dans l'archive sont listées et ignorées. La fenêtre montre l'architecture, la signature, la provenance et la quarantaine ; **Autoriser ce SDK** copie la bibliothèque et les en-têtes dans `sdk/`, retire la quarantaine de ces copies seulement, compile `obsbot-ai` avec les outils de développement d'Apple, puis vérifie qu'il charge le SDK. Tout se fait d'un seul tenant : si une étape échoue, l'ancien SDK et l'ancien `obsbot-ai` restent, et la sortie du compilateur va dans `obsbot-ai-compilation.log`. Sans SDK, tout marche sauf le suivi IA.
   - **Outils de développement.** Sans eux, la ligne SDK du panneau et la fenêtre **SDK OBSBOT** proposent **Installer les outils de développement…** avant tout choix du SDK. Le bouton lance l'installation d'Apple (`xcode-select --install`), seulement quand on clique : accepter dans la fenêtre d'Apple, puis rouvrir le panneau, ou cliquer sur **Vérifier à nouveau** dans la fenêtre. Un SDK déjà installé dont `obsbot-ai` doit être recompilé affiche « Outils requis », avec le même bouton.
   - **SDK installé par une version précédente.** Un SDK copié sans ses en-têtes (un `libdev.dylib` seul) affiche « À compléter », avec dessous « Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent. » : le réinstaller depuis l'archive.

### Mises à jour

- PTZBot cherche les mises à jour au lancement puis toutes les 24 heures, sur le flux `mac/app/appcast.xml` de ce dépôt. Chaque version est signée par une clé Ed25519, vérifiée avant même la décompression (`SUVerifyUpdateBeforeExtraction`) : Sparkle refuse une version mal signée, quelle que soit sa signature de code.
- Une mise à jour se télécharge en silence et s'installe à la fermeture de l'app, ou tout de suite par **Installer et relancer**. PTZBot arrête d'abord `ptzd`, comme avec **Quitter**.
- **Rechercher les mises à jour…** est dans le panneau ; **Réglages…** porte **Rechercher automatiquement** et **Installer automatiquement** (cochées par défaut), **Ouvrir à la connexion** et la version.
- Après une mise à jour, si la source d'`obsbot-ai` a changé, PTZBot le recompile au lancement (« Recompilation… »), sans rien demander. Si les outils manquent ou si la compilation échoue, l'ancien `obsbot-ai` reste en service et le panneau le signale.
- Les compilations faites depuis les sources (numéro de compilation 1, comme avec `scripts/install-mac.sh`) ne cherchent jamais de mise à jour.

### Compiler depuis les sources

Prérequis : Xcode et [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Le SDK OBSBOT n'est plus nécessaire pour compiler l'app.

```bash
scripts/install-mac.sh
```

Le script compile l'app (`ptzd` dans `Contents/Helpers`, la source d'`obsbot-ai` dans `Contents/Resources`, Sparkle dans `Contents/Frameworks`), ferme l'app en cours, l'installe dans `~/Applications/PTZBot.app` et la lance. Il ne touche ni à launchd ni aux fichiers de `~/Library/Application Support/ObsbotNacelle/`. Une telle compilation garde le numéro 1 : Sparkle n'y démarre jamais. Ne garder qu'une copie de PTZBot : pour revenir aux versions publiées, mettre `~/Applications/PTZBot.app` à la corbeille et installer l'image disque.

`mac/app/check-bundle.sh` vérifie une compilation Release : `ptzd`, la source d'`obsbot-ai` et Sparkle sont là ; le SDK, ses en-têtes et tout binaire `obsbot-ai` sont absents.

Publier une version (mainteneur) : écrire sa section dans `NOTES-VERSIONS.md` (**English**, puis **Français**), régler `MARKETING_VERSION` dans `mac/app/project.yml`, puis lancer `outils/publier.sh X.Y.Z` depuis un `main` propre et à jour. Si elle s'arrête en route, la reprendre depuis `gestes.txt`, dans le dossier des produits, jamais en relançant le script. `outils/publier.sh X.Y.Z --repetition DOSSIER --url-base http://127.0.0.1:PORT …` répète tout sans GitHub.

### Réglages (`config.json`)

| Clé | Rôle | Défaut |
|---|---|---|
| `listenAddress` | Adresse Tailscale du Mac, ou 127.0.0.1 sans Tailscale ; créée par PTZBot au premier lancement | obligatoire |
| `port` | Port WebSocket | 1985 |
| `panMaxSpeed`, `tiltMaxSpeed` | Vitesses UVC maximales (pan 1–80, tilt 1–120) | 40, 60 |
| `panDirection`, `tiltDirection` | Sens de chaque axe, +1 ou -1 | +1, +1 |
| `aiPath` | Chemin de `obsbot-ai`, relatif à `~/Library/Application Support/ObsbotNacelle` (ou absolu) ; quand PTZBot lance `ptzd`, c'est `--ai` qui compte (`sdk/obsbot-ai` ; l'ancienne clé `aiOffPath` est lue si elle manque, sauf si elle nomme `obsbot-ai-off`) | `bin/obsbot-ai` |
| `localNetwork` | Écoute et annonce Bonjour sur le Wi-Fi et l'Ethernet | `true` |
| `go2rtcAPI` | API locale de go2rtc, pour relayer la vidéo | `http://127.0.0.1:1984` |
| `streamName` | Flux go2rtc relayé | `obsbot` |

Après une modification, relancer le service : dans le panneau, éteindre puis rallumer **Service ptzd**.

### Diagnostic

| Besoin | Commande |
|---|---|
| Journal du service | `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log` |
| Sortie du SDK | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai.log` |
| Compilation d'`obsbot-ai` | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai-compilation.log` |
| Lire la position de la caméra | `/Applications/PTZBot.app/Contents/Helpers/ptzd uvc get` |
| Appareils appairés | `/Applications/PTZBot.app/Contents/Helpers/ptzd devices` |
| Voir l'annonce Bonjour | `dns-sd -B _nacelle._tcp` (Ctrl-C pour arrêter) |
| Dialoguer avec le service | `swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"adminWatch"}' wait 2` |

Pour une compilation depuis les sources, l'app est dans `~/Applications/PTZBot.app`.

Le Mac ne peut pas se joindre lui-même par son adresse Tailscale : en local, passer par 127.0.0.1.

`ptzd pair`, `ptzd devices` et `ptzd revoke` restent utilisables en ligne de commande avec le binaire de l'app ; `ptzd pair` demande que le service tourne, donc que PTZBot soit ouvert. Le journal et la ligne de commande de `ptzd` restent en français.

### App Mac (PTZBot)

Elle vit dans la barre des menus (icône de la Tiny 2), sans icône dans le Dock, en français sur un Mac en français, en anglais sinon. **Réglages… › Langue** choisit tout de suite Automatique (langue du système), Français ou English ; les fenêtres de mise à jour de Sparkle suivent au prochain lancement. L'iPhone ne pilote la caméra que pendant que PTZBot est ouvert : **Ouvrir à la connexion** en fait l'usage normal. Son panneau montre :

- l'interrupteur **Service ptzd**, retenu d'un lancement à l'autre, et l'état de `ptzd` (« Actif », « Démarrage… », « Arrêté », « Relancé après un arrêt inattendu (n) », « Ne répond pas » avec un lien vers son journal) et de la caméra. Au-delà de 5 arrêts en 2 min, PTZBot cesse de relancer `ptzd` : « ptzd s'arrête sans cesse : ouvrez le journal ». Il ne le relance pas non plus si un autre `ptzd` tourne déjà (verrou `ptzd.lock` ou port de 127.0.0.1 pris : « Le port 1985 est déjà pris… »), si `config.json` est invalide ou si ses arguments sont refusés ;
- la ligne **SDK OBSBOT**, avec un état court à droite (« Prêt », « Absent », « En quarantaine », « Incompatible », « Ne se charge pas », « Outils requis », « À compléter », « Recompilation… », « Compilation impossible », « obsbot-ai introuvable ») et dessous, sur toute la largeur, ce qu'il veut dire et **Installer le SDK…**, **Installer les outils de développement…** ou, quand le SDK est prêt, **Changer…** ; tant que le SDK n'est pas prêt, **Suivi IA** est grisé (« SDK OBSBOT requis »), sauf si un ancien `obsbot-ai` reste en service ;
- les interrupteurs **Vie privée** et **Suivi IA** (le suivi affiche le dernier ordre : l'état réel ne se lit pas, un geste devant la caméra peut le changer) ;
- les clients connectés, avec **Expulser** : la connexion est coupée et l'appareil refusé 10 min (tant que `ptzd` tourne), sans perdre son appairage ;
- **Appairer un iPhone…** : le QR code en image, valable 5 min ; fermer la fenêtre l'annule ;
- **Appareils…** : les appareils appairés, **Débloquer** et **Retirer…** (l'appareil est retiré et ses connexions coupées tout de suite) ;
- **Rechercher les mises à jour…** sur sa propre ligne, puis **Réglages…** (**Rechercher automatiquement**, **Installer automatiquement**, **Ouvrir à la connexion**, la version, par exemple « PTZBot 1.0.0 (412) » ; macOS peut demander un accord dans Réglages › Général › Ouverture) et **Quitter** : arrête `ptzd` (6 s au plus), puis l'app.

Si l'accès au réseau local est refusé à PTZBot, le panneau l'indique, avec un bouton vers les réglages de confidentialité : les iPhone ne trouvent alors le Mac que par Tailscale.

L'app passe par la connexion de confiance de `ptzd` (127.0.0.1) : tout programme du Mac peut en faire autant.

Tests : `(cd mac/app/PTZBotKit && swift test)` ; outils de publication : `python3 -m unittest discover -s outils/tests`.

### App iOS

Prérequis : Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), un identifiant Apple (un compte gratuit suffit), le côté Mac installé, et Tailscale sur l'iPhone pour piloter hors de la maison. L'app iOS n'est encore qu'en français.

1. Indiquer l'équipe de signature dans un réglage local, non versionné. Son identifiant est le champ OU des certificats « Apple Development » du trousseau :

   ```bash
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline | grep organizationalUnitName
   ```

   ```bash
   printf 'DEVELOPMENT_TEAM = %s\n' <identifiant> > ios/Config/Local.xcconfig
   ```

2. Générer le projet, puis compiler et installer sur l'iPhone branché ou appairé. `<UDID>` est son identifiant, donné par `xcrun devicectl list devices` :

   ```bash
   (cd ios && xcodegen)
   ```

   ```bash
   xcodebuild build -project ios/Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS,id=<UDID>' -derivedDataPath ios/.build -allowProvisioningUpdates
   ```

   ```bash
   xcrun devicectl device install app --device <UDID> ios/.build/Build/Products/Debug-iphoneos/Nacelle.app
   ```

3. Au premier lancement, iOS demande de faire confiance au développeur : Réglages › Général › VPN et gestion de l'appareil.
4. Au premier lancement, PTZBot cherche le Mac sur le Wi-Fi (« Recherche du Mac à proximité… ») : iOS demande l'accès au réseau local, répondre **Autoriser**.
5. Appairer l'iPhone, sur le même réseau que le Mac : dans PTZBot sur le Mac, **Appairer un iPhone…** affiche un QR code (valable 5 min, un seul usage, 3 essais). En repli, par exemple en SSH, `ptzd pair` l'affiche dans le Terminal :

   ```bash
   /Applications/PTZBot.app/Contents/Helpers/ptzd pair
   ```

   Puis, dans l'app de l'iPhone, toucher **Scanner le QR code** et viser l'écran du Mac (iOS demande l'accès à l'appareil photo). La clé de l'iPhone reste dans sa Secure Enclave ; le Mac garde sa clé publique et le secret du canal chiffré du réseau local, dans `devices.json` (droits 600). L'app retient l'adresse locale du Mac dans Réglages › Adresse du Mac (repli).

   Mise à jour depuis une version qui demandait le nom Tailscale : le champ « Adresse du Mac (repli) » le garde. Pour passer à l'adresse locale (qui sert aussi en 4G par la route de sous-réseau), vider ce champ et toucher Enregistrer avant de scanner : l'app y retiendra l'adresse locale du Mac.
6. Hors de la maison, l'app joint cette même adresse par Tailscale si un appareil du tailnet publie le réseau local (routage de sous-réseau) et si l'iPhone accepte les routes. Sinon, mettre dans le champ le nom Tailscale du Mac (champ `DNSName`, sans le point final, de `tailscale status --self --peers=false --json` sur le Mac) : l'app le joint par l'écoute Tailscale de `ptzd`, sans TLS.

Retirer un iPhone : dans PTZBot sur le Mac, **Appareils…** › **Retirer…** ; ses connexions sont coupées tout de suite, après un message qui l'informe : l'iPhone connecté oublie son appairage et revient à l'écran d'appairage. Un iPhone hors connexion à ce moment l'apprend à sa prochaine connexion par Tailscale ; sur le réseau local, il est simplement refusé et affiche « Mac injoignable » : sur lui, « Oublier cet appairage », puis scanner un nouveau QR code. En ligne de commande, `ptzd devices` donne le début de son identifiant, puis `ptzd revoke <début>` ; ses connexions déjà ouvertes durent alors jusqu'à leur fin. Depuis l'iPhone, « Oublier cet appairage » le retire aussi de la liste du Mac quand il est connecté.

Avec un compte Apple gratuit, l'app expire au bout de 7 jours : refaire l'étape 2.

Icône (facultative) : déposer un catalogue `ios/Local/Assets.xcassets` contenant un jeu d'icônes `AppIcon` (une image 1024 × 1024), et ajouter `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` à `ios/Config/Local.xcconfig`. Le dossier `ios/Local/` n'est pas versionné : sans lui, l'app se compile avec l'icône par défaut.

Tests : `(cd ios && xcodegen && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build)`.

### go2rtc

`ptzd` relaie la négociation vidéo à l'API de go2rtc sur 127.0.0.1 : l'API n'a donc plus besoin d'être ouverte au réseau. Configuration conseillée (dans `go2rtc.yaml`, à adapter) :

```yaml
api:
  listen: "127.0.0.1:1984"
rtsp:
  listen: ":8554"
  username: "<identifiant>"
  password: "<mot de passe>"
webrtc:
  listen: ":8555"
ffmpeg:
  bin: /opt/homebrew/bin/ffmpeg   # chemin complet : sous launchd, le PATH ne contient pas /opt/homebrew/bin
streams:
  obsbot:
    - exec:…   # vidéo de la caméra (H.264)
    - exec:…   # micro de la caméra (AAC, pour HomeKit)
    - ffmpeg:obsbot#audio=opus   # le même son en Opus, pour PTZBot (WebRTC)
```

- go2rtc dispense les clients locaux (127.0.0.1) du mot de passe RTSP : les sources `exec:` qui publient sur `{output}` continuent de fonctionner sans changement.
- Un client RTSP du réseau, comme Homebridge, doit alors donner l'identifiant et le mot de passe dans l'adresse du flux : `rtsp://<identifiant>:<mot de passe>@<Mac>:8554/obsbot`.
- Le port WebRTC 8555 reste ouvert : sans offre négociée par `ptzd`, il ne donne aucune image.
- Son dans PTZBot : WebRTC ne transporte pas l'AAC. La source `ffmpeg:obsbot#audio=opus` le convertit en Opus dès que PTZBot est ouvert, même son coupé (le bouton ne fait que couper la lecture, pour que le son revienne tout de suite). Sans la ligne `ffmpeg: bin:`, go2rtc lancé par launchd ne trouve pas `ffmpeg` et la piste audio reste muette, sans message d'erreur.
- `go2rtc.yaml` contient le mot de passe RTSP : le passer en droits 600 (`chmod 600 go2rtc.yaml`).
- Le flux RTSP vers Homebridge, identifiants compris, circule en clair sur le réseau local : un appareil qui intercepte ce trafic peut les lire, ainsi que les images.
- Le QR code d'appairage (fenêtre de PTZBot pour Mac, ou `ptzd pair` et l'URL affichée sous lui) permet d'appairer un appareil pendant 5 minutes : ne l'afficher que le temps du scan.
- Ne jamais exposer 127.0.0.1:1985 au réseau, par exemple avec `tailscale serve` ou `ssh -L` : les connexions venues de 127.0.0.1 sont dispensées d'authentification, tout client distant passé par là piloterait la caméra.

### Désinstaller

Dans PTZBot pour Mac, **Réglages…** › décocher **Ouvrir à la connexion**, puis **Quitter** (`ptzd` s'arrête avec l'app), et mettre `/Applications/PTZBot.app` (ou `~/Applications/PTZBot.app` pour une compilation depuis les sources) à la corbeille.

Les données restent dans `~/Library/Application Support/ObsbotNacelle/` (réglages, iPhone appairés, SDK, ses en-têtes et `obsbot-ai`) et les journaux dans `~/Library/Logs/obsbot-nacelle/`, tant qu'on ne les supprime pas :

```bash
rm -r ~/Library/Application\ Support/ObsbotNacelle ~/Library/Logs/obsbot-nacelle
```

Après une migration, la plist de l'ancien agent reste en `~/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.ptzd.plist.bak` : elle peut être supprimée.

### Contenu

| Chemin | Rôle |
|---|---|
| `Packages/NacelleProtocol/` | Messages échangés entre les apps et `ptzd`, partagés par les deux |
| `mac/ptzd/` | Le service : logique (`PTZCore`), appairage et authentification (`PTZAuth`), accès USB (`CUVC`, `UVCCamera`), serveur WebSocket et écoute locale (`PTZServer`) |
| `mac/ai/` | L'utilitaire `obsbot-ai` (C++) : sa source, livrée dans l'app et compilée sur le Mac de l'utilisateur ; `build.sh` le compile en local avec le SDK de `vendor/`, pour les essais |
| `mac/app/` | L'app PTZBot pour Mac : `project.yml` (xcodegen), interface (`PTZBot/`), logique testée (`PTZBotKit/`), phase des utilitaires (`build-helpers.sh`), vérification du paquet (`check-bundle.sh`) et flux des mises à jour (`appcast.xml`, écrit à la publication) |
| `mac/tools/` | Client WebSocket de test |
| `ios/` | L'app iOS : `project.yml` (xcodegen), sources et tests |
| `outils/` | Publication d'une version : `publier.sh`, `publication.py` et leurs tests, licence de Sparkle |
| `NOTES-VERSIONS.md` | Notes de version, en anglais puis en français |
| `scripts/install-mac.sh` | Compilation et installation de l'app depuis les sources sur le Mac |
| `docs/` | Spec, plans et tests de faisabilité |
| `spike/` | Sondes **jetables** des tests de faisabilité |

### Licence

MIT. Voir [LICENSE](LICENSE). L'image disque porte aussi la licence de [Sparkle](https://sparkle-project.org) 2.10.0 (`outils/Sparkle-LICENSE.txt`).
````

Modifier `docs/superpowers/specs/2026-10-08-distribution-design.md` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/docs/superpowers/specs/2026-10-08-distribution-design.md b/docs/superpowers/specs/2026-10-08-distribution-design.md
index 8fefdb2..6056d3d 100644
--- a/docs/superpowers/specs/2026-10-08-distribution-design.md
+++ b/docs/superpowers/specs/2026-10-08-distribution-design.md
@@ -81,7 +81,7 @@ Ils sont repris de maillage-thread avec leurs tests, puis adaptés de trois faç
 2. **Utilitaires :** `Contents/Helpers/*` entre dans le code à signer, après les cadres et avant l'app.
 3. **Contenu interdit :** les règles du § 5.1 s'ajoutent au contrôle du contenu du DMG.
 
-**Contrôle d'anonymisation.** Celui de maillage-thread est privé. Ici, la vérification de fuite des commits (adresses hors liste autorisée, noms `*.ts.net`, chemins `/Users/…`) s'applique au contenu du DMG, aux notes et au flux.
+**Contrôle d'anonymisation.** Celui de maillage-thread est privé. Ici, la vérification de fuite des commits (adresses hors liste autorisée, noms Tailscale, chemins personnels) s'applique au contenu du DMG, aux notes et au flux.
 
 **Le reste est inchangé :**
 - vérifications : `main` propre et à jour, version nouvelle, tests verts ;
@@ -199,3 +199,46 @@ Au lancement, si l'empreinte de `Resources/obsbot-ai.cpp` diffère de `sdk/obsbo
 - L'app iOS n'est pas distribuée ainsi : elle est signée avec le compte de chacun.
 - Le journal et la ligne de commande de `ptzd` restent en français.
 - La licence de redistribution du SDK est au backlog. Si OBSBOT l'accorde, `obsbot-ai` et le SDK pourront entrer dans le DMG, et la compilation locale servira de repli.
+
+## 12. Amendements (prototype)
+
+Le prototype (branche `proto/b2`) a été relu par Opus le 08/10. Ces points précisent la spec ou s'en écartent.
+
+### Compilation locale d'`obsbot-ai`
+
+- **Préparation dans `sdk/new/`, sous les noms définitifs** (`libdev.dylib`, `include/`, `obsbot-ai`, `obsbot-ai.sha256`), et non `*.new`. `-ldev` et `DYLD_LIBRARY_PATH` cherchent tous deux le nom `libdev.dylib`.
+- **Journal.** Avant le premier échange, `sdk/new/.transaction` liste les éléments échangés et ceux qui n'avaient pas de version précédente.
+  - Après un arrêt, la reprise remet chaque `.old` et retire les éléments neufs déjà en place.
+  - La validation consiste à retirer le journal, puis `sdk/new/`. Un `sdk/new/` vide sans journal compte comme validé.
+  - Un `sdk/new/` non vide sans journal compte comme « échange pas commencé » : il est effacé.
+  - Si l'annulation d'un échange échoue, le journal et `sdk/new/` restent, et la reprise suivante l'achève.
+  - Le `libdev.dylib.new` laissé par B1 est effacé à la reprise.
+- **Groupe de processus.** clang++ est lancé dans son propre groupe : un délai dépassé arrête aussi `clang -cc1` et `ld`.
+- **Outils absents.** Le panneau et la fenêtre « SDK OBSBOT » proposent « Installer les outils de développement… » avant tout choix du SDK, pour un SDK absent ou à compléter comme pour une recompilation. `xcode-select --install` n'est lancé que sur le clic de l'utilisateur.
+- Les vérifications du SDK sont mises à la file : jamais de fausse « compilation impossible » pendant une recompilation.
+- **Ligne SDK du panneau** (banc du 08/10) : à droite, un état court seulement (« Prêt », « Absent », « À compléter », « En quarantaine », « Incompatible », « Ne se charge pas », « Outils requis », « Recompilation… », « Compilation impossible », « obsbot-ai introuvable »).
+  - L'explication et le bouton vont sur une petite ligne dessous, sur toute la largeur. Ils remplacent les états longs du § 6.4.
+  - Pied du panneau : « Rechercher les mises à jour… » seul sur sa ligne, au-dessus de « Réglages… » et « Quitter ».
+
+### Bilingue
+
+- **Langue choisie explicitement**, au lieu de `Bundle.module` : le français si l'utilisateur le préfère à l'anglais, l'anglais sinon.
+  - La règle est `Bundle.preferredLocalizations(from: ["fr", "en"])`, appliquée aux langues préférées.
+  - Les textes sont lus dans `fr.lproj` ou `en.lproj` de PTZBotKit.
+  - Hors d'une app, `Bundle.module` prend l'anglais même sur un Mac en français.
+- **Réglage « Langue »** dans la fenêtre Réglages (banc du 08/10) : Automatique (la règle ci-dessus), Français ou English, appliqué tout de suite et retenu (`appLanguage`). Pour les fenêtres de Sparkle, choisies par macOS au lancement, le choix est recopié dans `AppleLanguages` du domaine de l'app (`["fr"]` ou `["en"]`, retiré en automatique) : elles suivent au prochain lancement.
+- **Le motif d'échec du suivi IA** (`uvcFailed`) est composé par `ptzd` et relu par l'app d'après les mêmes textes, `AIFailureText` de NacelleProtocol.
+
+### Mises à jour et publication
+
+- **`SUVerifyUpdateBeforeExtraction`** est à vrai dès 1.0.0 : la signature Ed25519 est toujours exigée, sans repli sur la signature de code. La publication le vérifie dans l'app compilée.
+  - `SURequireSignedFeed` n'est pas activé : il faudrait signer tout le flux à chaque publication.
+- **`--notes`** : les notes sont à la racine du dépôt, et `publier.sh` se place dans `mac/app`.
+- **Contrôle de fuite.** Chaque trouvaille est jugée par son jeton entier : l'adresse ou le nom complet doit être dans la liste autorisée.
+  - Dans le DMG seulement, les OID de RSA et d’Apple (arc `1.2.840`, puis `113549` ou `113635`), que porte `Autoupdate` de Sparkle, sont admis comme jetons.
+- **Utilitaires.** Après la signature, chaque utilitaire est relu : aucun droit, et le runtime renforcé présent. Un élément de `Contents/Helpers` qui n'est pas un exécutable ordinaire est refusé.
+- **Aucun binaire Mach-O** de l'app ne doit dépendre de `libdev` (`otool -L`), ni dans `check-bundle.sh`, ni dans la publication.
+- **Révision de Sparkle.** `sign_update` et `generate_keys`, pris dans le paquet résolu, exigent la révision de l'étiquette 2.10.0 (`eef1a539…`), lue dans `workspace-state.json`.
+  - xcodegen n'accepte qu'une exigence par paquet : `project.yml` garde `exactVersion`.
+- **`strip -S` de `ptzd`** dans une compilation de publication : ses symboles de débogage nommaient `.build` sous le dossier personnel.
+- **`sparkle-cli`** n'est pas dans les artefacts du paquet. La répétition le compile depuis la source 2.10.0.
PATCH
```

Modifier `scripts/install-mac.sh` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/scripts/install-mac.sh b/scripts/install-mac.sh
index 6d1ae6f..85745b1 100755
--- a/scripts/install-mac.sh
+++ b/scripts/install-mac.sh
@@ -1,13 +1,14 @@
 #!/bin/bash
-# Compile PTZBot pour Mac, avec ptzd et obsbot-ai dans Contents/Helpers, l'installe dans
-# ~/Applications/PTZBot.app et la lance (spec ptzd dans l'app § 5.7).
-# Le script ne touche ni à launchd, ni à bin/, ni à lib/ : au premier lancement, l'app propose
-# de remplacer l'ancienne installation, puis accompagne l'installation du SDK OBSBOT.
+# Compile PTZBot pour Mac depuis les sources (compilation de travail), avec ptzd dans Contents/Helpers et la source
+# d'obsbot-ai dans Contents/Resources, l'installe dans ~/Applications/PTZBot.app et la lance (spec ptzd dans l'app
+# § 5.7, spec distribution § 5.4). Les versions publiées s'installent plutôt depuis l'image disque (README).
+# Le script ne touche ni à launchd, ni à bin/, ni à lib/ : au premier lancement, l'app propose de remplacer
+# l'ancienne installation, puis accompagne l'installation du SDK OBSBOT, avec lequel elle compile obsbot-ai.
+# Une compilation de travail garde le numéro de compilation 1 : Sparkle n'y cherche jamais de mise à jour.
 # Usage : scripts/install-mac.sh
 set -euo pipefail
 
 ROOT="$(cd "$(dirname "$0")/.." && pwd)"
-SDK="$ROOT/vendor/obsbot-sdk"
 APP="$HOME/Applications/PTZBot.app"
 APP_ID="io.github.djoko-cli.ptzbot"
 BUILT="$ROOT/mac/app/.build/Build/Products/Release/PTZBot.app"
@@ -17,18 +18,12 @@ if [ "$#" -ne 0 ]; then
     exit 2
 fi
 
-# obsbot-ai se compile avec les en-têtes du SDK ; le SDK lui-même n'entre jamais dans l'app.
-if [ ! -f "$SDK/include/dev/devs.hpp" ] || [ ! -f "$SDK/macos/arm64-release/libdev.dylib" ]; then
-    echo "SDK OBSBOT introuvable dans $SDK : décompressez-y l'archive reçue d'OBSBOT pour compiler obsbot-ai." >&2
-    exit 1
-fi
-
 if ! command -v xcodegen >/dev/null; then
     echo "xcodegen introuvable : brew install xcodegen" >&2
     exit 1
 fi
 
-echo "Compilation de PTZBot pour Mac (avec ptzd et obsbot-ai)…"
+echo "Compilation de PTZBot pour Mac (avec ptzd et la source d'obsbot-ai)…"
 (cd "$ROOT/mac/app" && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot \
     -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build -quiet)
 "$ROOT/mac/app/check-bundle.sh" "$BUILT" >/dev/null
@@ -69,5 +64,6 @@ if [ "$OPENED" = 0 ]; then
 fi
 echo "PTZBot est dans la barre des menus."
 echo "Au premier lancement, il propose de remplacer l'ancienne installation de ptzd s'il en trouve une."
-echo "Le SDK OBSBOT s'installe depuis son panneau : SDK OBSBOT › Installer le SDK…"
+echo "Le SDK OBSBOT s'installe depuis son panneau : SDK OBSBOT › Installer le SDK… ; PTZBot y compile obsbot-ai"
+echo "avec les outils de développement d'Apple (xcode-select --install s'ils manquent)."
 echo "Journal : tail -f \"$HOME/Library/Logs/obsbot-nacelle/ptzd.log\""
PATCH
```

- [ ] **Étape 2 : Vérifier**

```bash
bash -n scripts/install-mac.sh && echo 'Syntaxe du script : OK'
```

Attendu : « Syntaxe du script : OK ».

- [ ] **Étape 3 : Commiter et pousser**

```bash
git add README.md \
    docs/superpowers/specs/2026-10-08-distribution-design.md \
    scripts/install-mac.sh
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|8\.8\.8\.8|256\.0\.0\.1|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
B2 : README bilingue, install-mac.sh sans SDK, amendements de la spec

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés plus haut sont déjà indexés par `git rm`.

### Tâche 6 : Fusion, publication de la 1.0.0 et installation depuis le DMG (avec Majid)

**But :** publier la première version et installer PTZBot comme un utilisateur, puis vérifier ce que seule l'app réelle montre (spec B2 § 10).

**Fichiers :** `mac/app/appcast.xml`, créé et commité par la publication.

- [ ] **Étape 1 : Fusion (accord de Majid)**

Fusionner la branche dans `main`, avec l'accord de Majid, puis pousser.

- [ ] **Étape 2 : Publication de la 1.0.0 (Majid présent ; geste public)**

Depuis un clone neuf de GitHub, hors d'iCloud, le SDK relié :

```bash
outils/publier.sh 1.0.0
```

1. **Trousseau :** au premier `codesign`, puis à `sign_update` et `generate_keys`, Majid répond « Toujours autoriser », et seulement pour ces outils-là.
2. **Arrêt à mi-chemin :** reprendre depuis `mac/app/build/publication/1.0.0/gestes.txt`, jamais en relançant le script.
3. **Attendu :**
   - l'étiquette `ptzbot-v1.0.0` ;
   - la version GitHub avec le DMG ;
   - `mac/app/appcast.xml` commité sur `main` ;
   - le DMG sur le Bureau.

- [ ] **Étape 3 : Installation depuis le DMG (Majid)**

1. Quitter la compilation de travail (`~/Applications/PTZBot.app`), puis la mettre à la corbeille.
2. Ouvrir le DMG du Bureau et glisser PTZBot dans Applications.
3. Première ouverture : Gatekeeper, puis « Ouvrir quand même » dans Réglages › Confidentialité et sécurité.
4. Vérifier :
   - un seul `ptzd`, enfant de `/Applications/PTZBot.app` ;
   - le pare-feu, si macOS le redemande ;
   - « Ouvrir à la connexion », qui pointe vers l'app installée.

```bash
pgrep -lf 'Helpers/ptzd' | sed -E 's#/Users/[^ ]*/#~/#g'; codesign -dv /Applications/PTZBot.app 2>&1 | grep -E 'Authority|flags'
```

- [ ] **Étape 4 : SDK et suivi IA (Majid)**

L'installation existante garde son `sdk/`. Si la source livrée a changé, la recompilation se fait seule (« Recompilation… », puis « Prêt »). Ensuite, le suivi IA : l'allumer, puis le couper.

- [ ] **Étape 5 : Mises à jour (Majid)**

1. « Rechercher les mises à jour… » : la fenêtre de Sparkle dit qu'il n'y a rien de nouveau.
2. **Plus tard, dans une autre session :** publier une 1.0.1, puis éprouver « Installer et relancer » et l'installation à la fermeture. Vérifier que l'ancien `ptzd` disparaît avant le remplacement, que le nouveau `ptzd` vient de la nouvelle app, et que les accents des notes s'affichent bien.

- [ ] **Étape 6 : Bilan**

```bash
pgrep -x go2rtc; pgrep -x coreaudiod
```

Les PID sont inchangés. Noter le résultat de chaque étape. Supprimer les sorties de compilation régénérables, car le disque est presque plein.
