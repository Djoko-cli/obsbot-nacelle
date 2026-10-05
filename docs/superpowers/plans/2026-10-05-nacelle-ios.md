# Plan d'implémentation : app iOS Nacelle

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectif :** livrer l'app iOS `Nacelle` (spec § 7) : la vidéo de la caméra en direct, un joystick pour la nacelle, le zoom et la vie privée, pilotés à travers `ptzd`, installée sur l'iPhone de Majid et vérifiée de bout en bout en 4G. En préalable, rendre la prise en main de `ptzd` robuste au démarrage simultané de la vidéo (amendement A3).

**Architecture :** SwiftUI, Swift 6 strict, iOS 26. Logique testable sans réseau ni interface : `JoystickMath`, `PTZClient` (derrière un protocole de transport WebSocket et une horloge injectée), `Signaling`, `StatusBanner`, `ConnectionSettings`. Parties branchées au système : `URLSessionWebSocketTransport`, `VideoSession` (WebRTC, réception seule), les vues SwiftUI. `AppModel` relie le tout et suit le cycle de vie. Le projet Xcode est décrit pour xcodegen.

**Technologies :** SwiftUI, Observation, Swift Testing, URLSessionWebSocketTask, WebRTC 154.0.0 (stasel/WebRTC, paquet binaire), xcodegen 2.46, Xcode 27, simulateur iOS 27.

**Spec :** [docs/superpowers/specs/2026-10-05-nacelle-design.md](../specs/2026-10-05-nacelle-design.md), à lire avec ce plan, surtout § 7 et § 8. Le côté Mac est déjà livré et installé : [plan côté Mac](2026-10-05-nacelle-mac.md).

## Contraintes globales

- **Plateforme :** iOS 26.0 minimum, iPhone seulement (`TARGETED_DEVICE_FAMILY = 1`), portrait et paysage ; Xcode 27 ; `SWIFT_VERSION = 6.0`, concurrence stricte (`complete`).
- **Dépendances :** `NacelleProtocol` (paquet local) et une seule dépendance externe, WebRTC `exactVersion: 154.0.0` (`https://github.com/stasel/WebRTC`).
- **Projet :** décrit dans `ios/project.yml`, généré par `xcodegen` ; `ios/Nacelle.xcodeproj/`, `ios/Nacelle/Info.plist` (généré) et `ios/Config/Local.xcconfig` (équipe de signature) ne sont pas versionnés.
- **Tests :** Swift Testing, cible `NacelleTests`, lancés sur le simulateur « iPhone 17 » sous iOS 27.0 (commande donnée à chaque tâche). Le premier lancement télécharge WebRTC (quelques minutes).
- **Langue :** identifiants en anglais ; textes de l'interface et commentaires en français.
- **Dépôt public :** aucune adresse IP (hors 127.0.0.1 et 0.0.0.0), aucun nom `*.ts.net` réel (les tests utilisent `mac.exemple.ts.net`), aucun identifiant d'équipe ni d'appareil, aucune image de la caméra dans un fichier commité. La vérification fait partie de chaque étape de commit.
- **Commits :** commit et push à la fin de chaque tâche (autorisés par Majid pour ce dépôt) ; message en français, terminé par la ligne `Co-Authored-By` du modèle qui commite.
- **Réseau :** exception ATS limitée à `ts.net` (spec § 7.5). Les essais dans le simulateur passent par 127.0.0.1, qui n'a pas besoin d'exception (vérifié).
- **Essais réels :** ils parlent au `ptzd` installé et à go2rtc, donc à la vraie caméra. Prévenir Majid avant tout geste qui fait bouger la nacelle ; OBSBOT Center fermé ; ne jamais toucher à go2rtc ni à sa configuration ; vérifier que les PID de go2rtc et de coreaudiod ne changent pas.
- **Matériel et accords :** l'installation sur l'iPhone et l'essai en 4G (tâche 8) demandent Majid (confiance au développeur, autorisations, gestes) ; les réinstallations du service Mac (tâche 1) aussi doivent lui être annoncées.

## Amendement A3 à la spec, proposé avec ce plan

Constaté le 2026-10-05 en faisant tourner l'app dans le simulateur : l'app ouvre la vidéo et envoie `takeControl` au même instant ; go2rtc démarre alors la capture pendant que le SDK initialise la caméra. Une fois sur trois, l'initialisation a dépassé 5 s : `obsbot-ai-off` a conclu « caméra introuvable », puis a planté (SIGABRT) en refermant le SDK encore occupé. Une seconde prise en main, flux lancé, a réussi à chaque fois.

- **§ 6.9 :** `obsbot-ai-off` attend la caméra **10 s** au plus ; s'il ne la trouve pas, il quitte **sans refermer le SDK** (`_exit(1)`), ce qui supprime le plantage.
- **§ 6.4 :** après un échec, `ptzd` fait **un seul nouvel essai 3 s plus tard** ; `control` reste `taking` pendant ce temps, et ne passe à `failed` qu'après le second échec.

La spec sera mise à jour quand Majid aura validé cet amendement.

## Carte des fichiers

| Fichier | Rôle | Tâche |
|---|---|---|
| `mac/ptzd/Sources/PTZCore/ControlTaker.swift` | Prise en main avec un nouvel essai | 1 |
| `mac/ptzd/Sources/PTZCore/PTZController.swift` | Passe l'horloge à `ControlTaker` (une ligne) | 1 |
| `mac/ai-off/main.cpp` | Attente de 10 s, sortie sans refermer le SDK | 1 |
| `mac/ptzd/Tests/PTZCoreTests/ControlTakerTests.swift`, `PTZControllerTests.swift` | Tests mis à jour | 1 |
| `.gitignore` | Fichiers générés et réglage local de l'app | 2 |
| `ios/project.yml`, `ios/Config/Signing.xcconfig` | Projet (xcodegen) et signature | 2 |
| `ios/Nacelle/App/Scheduler.swift` | Horloge injectable | 2 |
| `ios/Nacelle/Settings/ConnectionSettings.swift` | Réglages de connexion | 2 |
| `ios/Nacelle/Control/JoystickMath.swift` | Géométrie du joystick | 3 |
| `ios/Nacelle/PTZ/WebSocketTransport.swift`, `PTZClient.swift` | Dialogue avec `ptzd` | 4 |
| `ios/Nacelle/Video/Signaling.swift`, `VideoSession.swift`, `VideoView.swift` | Vidéo WebRTC | 5 |
| `ios/Nacelle/Control/StatusBanner.swift` | Texte du bandeau d'état | 6 |
| `ios/Nacelle/App/AppModel.swift`, `NacelleApp.swift` | Assemblage et cycle de vie | 2 (provisoire), 6 |
| `ios/Nacelle/Control/JoystickView.swift`, `ZoomSlider.swift`, `ControlScreen.swift`, `ios/Nacelle/Settings/SettingsView.swift` | Interface | 6 |
| `ios/NacelleTests/*.swift` | Tests et faux objets | 2 à 6 |
| `README.md` | Section « App iOS » | 8 |

## Lire les étapes

- Toutes les commandes partent de la **racine du dépôt** (`~/Dev/obsbot-nacelle`).
- Le code de ce plan a été compilé (aucun avertissement) et testé le 2026-10-05 ; les tâches 2 à 6 ont été rejouées dans un dossier vierge, et l'app assemblée a tourné dans le simulateur contre le vrai `ptzd`, go2rtc et la caméra. **Recopier les fichiers tels quels.**
- « Échec attendu » à l'étape 2 : un test qui référence un type absent ne compile pas ; c'est l'échec recherché.
- Après chaque ajout de fichier dans `ios/`, la commande de test relance `xcodegen` pour que le projet le contienne.

---

### Tâche 1 : Prise en main robuste au démarrage de la vidéo (côté Mac, amendement A3)

Voir « Amendement A3 » plus haut. `ControlTaker` reçoit l'horloge du contrôleur et fait un seul nouvel essai 3 s après un échec ; `obsbot-ai-off` attend 10 s et quitte sans refermer le SDK s'il ne trouve pas la caméra.

**Fichiers :**
- Remplacer : `mac/ptzd/Sources/PTZCore/ControlTaker.swift`
- Modifier : `mac/ptzd/Sources/PTZCore/PTZController.swift` (une ligne)
- Remplacer : `mac/ptzd/Tests/PTZCoreTests/ControlTakerTests.swift`
- Modifier : `mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift` (un bloc)
- Remplacer : `mac/ai-off/main.cpp`

**Interfaces :**
- Utilise : `Scheduler`, `AIOffRunner`, `AIOffResult`, `ControlState` (côté Mac, déjà livrés).
- Produit : `ControlTaker(runner:scheduler:isObsbotCenterRunning:log:)`, `ControlTaker.retryDelay = 3`.

- [ ] **Étape 1 : Écrire les tests**

Remplacer tout le contenu de `mac/ptzd/Tests/PTZCoreTests/ControlTakerTests.swift` :

```swift
import Testing
@testable import PTZCore

@MainActor
@Suite("Prise en main")
struct ControlTakerTests {
    let runner = FakeAIOffRunner()
    let scheduler = FakeScheduler()
    let log = LogRecorder()

    private func makeTaker(centerRunning: Bool = false) -> ControlTaker {
        ControlTaker(runner: runner, scheduler: scheduler, isObsbotCenterRunning: { centerRunning }, log: log.sink)
    }

    @Test("take lance l'utilitaire et passe à taking, puis ready")
    func success() {
        let taker = makeTaker()
        taker.take()
        #expect(taker.state == .taking)
        #expect(runner.runCount == 1)
        runner.finish(.success)
        #expect(taker.state == .ready)
    }

    @Test("Une demande pendant l'exécution n'en lance pas une seconde")
    func coalesces() {
        let taker = makeTaker()
        taker.take()
        taker.take()
        #expect(runner.runCount == 1)
    }

    @Test("Deux échecs : un nouvel essai après 3 s, puis failed, avec une ligne de journal chacun")
    func failure() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.timeout)
        #expect(taker.state == .taking)
        #expect(runner.runCount == 1)
        scheduler.advance(by: ControlTaker.retryDelay)
        #expect(runner.runCount == 2)
        runner.finish(.timeout)
        #expect(taker.state == .failed)
        #expect(log.lines.count == 2)
        scheduler.advance(by: 10)
        #expect(runner.runCount == 2)
    }

    @Test("Un échec suivi d'un succès donne ready")
    func retrySucceeds() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.unexpectedExit(6))
        scheduler.advance(by: ControlTaker.retryDelay)
        runner.finish(.success)
        #expect(taker.state == .ready)
        #expect(runner.runCount == 2)
    }

    @Test("Pendant l'attente du nouvel essai, une demande n'en lance pas d'autre")
    func coalescesDuringRetry() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.cameraNotFound)
        taker.take()
        scheduler.advance(by: ControlTaker.retryDelay)
        #expect(runner.runCount == 2)
    }

    @Test("Une nouvelle prise en main relance l'utilitaire")
    func retake() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.success)
        taker.take()
        #expect(runner.runCount == 2)
        #expect(taker.state == .taking)
    }

    @Test("OBSBOT Center ouvert : avertissement journalisé")
    func obsbotCenterWarning() {
        makeTaker(centerRunning: true).take()
        #expect(log.lines.first?.contains("OBSBOT Center") == true)
    }
}
```

Dans `mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift`, test `controlFinishReenforcesPrivacy`, remplacer :

```swift
        _ = controller.handle(.takeControl, from: 1)
        runner.finish(.sdkError)
        #expect(controller.snapshot.control == .failed)
        #expect(camera.absoluteCommands.count == 3)
```

par :

```swift
        _ = controller.handle(.takeControl, from: 1)
        runner.finish(.sdkError)
        #expect(controller.snapshot.control == .taking)
        scheduler.advance(by: ControlTaker.retryDelay)
        runner.finish(.sdkError)
        #expect(controller.snapshot.control == .failed)
        #expect(camera.absoluteCommands.count == 3)
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd mac/ptzd && swift test --filter "ControlTakerTests|PTZControllerTests"
```

Échec attendu : la compilation échoue (`extra argument 'scheduler' in call`, ou `type 'ControlTaker' has no member 'retryDelay'`).

- [ ] **Étape 3 : Écrire l'implémentation**

Remplacer tout le contenu de `mac/ptzd/Sources/PTZCore/ControlTaker.swift` :

```swift
import Foundation
import NacelleProtocol

/// Prise en main : coupe le suivi IA via obsbot-ai-off (spec § 6.4, amendement A3).
@MainActor
public final class ControlTaker {
    /// Délai avant l'unique nouvel essai après un échec : le SDK peut échouer quand la
    /// vidéo démarre au même moment, ce que fait l'app à chaque ouverture (constaté le 2026-10-05).
    public static let retryDelay: TimeInterval = 3

    public private(set) var state: ControlState = .idle
    /// Appelé quand `state` change.
    public var onChange: (() -> Void)?

    private let runner: any AIOffRunner
    private let scheduler: any Scheduler
    private let isObsbotCenterRunning: @MainActor () -> Bool
    private let log: LogSink
    private var retried = false

    public init(
        runner: any AIOffRunner,
        scheduler: any Scheduler,
        isObsbotCenterRunning: @escaping @MainActor () -> Bool,
        log: @escaping LogSink
    ) {
        self.runner = runner
        self.scheduler = scheduler
        self.isObsbotCenterRunning = isObsbotCenterRunning
        self.log = log
    }

    /// Lance la coupure. Pendant une exécution (nouvel essai compris), une nouvelle
    /// demande attend le même résultat.
    public func take() {
        if isObsbotCenterRunning() {
            log("OBSBOT Center est ouvert : ferme-le, il fausse la relecture du tilt.")
        }
        guard state != .taking else { return }
        state = .taking
        retried = false
        onChange?()
        launch()
    }

    private func launch() {
        runner.run { [weak self] result in
            self?.finish(result)
        }
    }

    /// Un échec est retenté une fois après `retryDelay` ; `failed` n'est publié qu'après le second.
    private func finish(_ result: AIOffResult) {
        if result == .success {
            state = .ready
            onChange?()
            return
        }
        guard retried else {
            retried = true
            log("obsbot-ai-off a échoué (\(result)) : nouvel essai dans \(Int(Self.retryDelay)) s.")
            scheduler.schedule(after: Self.retryDelay) { [weak self] in
                self?.launch()
            }
            return
        }
        state = .failed
        log("obsbot-ai-off a échoué : \(result)")
        onChange?()
    }
}
```

Dans `mac/ptzd/Sources/PTZCore/PTZController.swift`, remplacer la ligne :

```swift
        control = ControlTaker(runner: aiOff, isObsbotCenterRunning: isObsbotCenterRunning, log: log)
```

par :

```swift
        control = ControlTaker(runner: aiOff, scheduler: scheduler, isObsbotCenterRunning: isObsbotCenterRunning, log: log)
```

Remplacer tout le contenu de `mac/ai-off/main.cpp` :

```cpp
// obsbot-ai-off : coupe le suivi IA de la Tiny 2, puis se termine (spec § 6.9).
// Codes de sortie : 0 = suivi coupé, 1 = caméra introuvable, 2 = erreur du SDK.
// Lancé par ptzd à chaque prise en main ; le SDK ne reste jamais chargé en permanence.
#include <chrono>
#include <cstdio>
#include <dev/devs.hpp>
#include <thread>
#include <unistd.h>

int main() {
    Devices::get().setDevChangedCallback([](std::string, bool, void *) {}, nullptr);
    Devices::get().setEnableMdnsScan(false);

    std::shared_ptr<Device> tiny2;
    // 10 s au plus (amendement A3) : quand la vidéo démarre en même temps, l'initialisation
    // de la caméra par le SDK est plus lente (constaté le 2026-10-05).
    for (int attempt = 0; attempt < 100 && !tiny2; ++attempt) {
        for (auto &device : Devices::get().getDevList()) {
            if (device->productType() == ObsbotProdTiny2) {
                tiny2 = device;
            }
        }
        if (!tiny2) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
    if (!tiny2) {
        // Le SDK peut encore initialiser la caméra dans son propre fil : le refermer
        // maintenant provoque un arrêt brutal (libc++abi). On quitte sans destructeurs ;
        // le système libère l'accès USB.
        std::fprintf(stderr, "obsbot-ai-off : Tiny 2 introuvable après 10 s\n");
        std::fflush(stderr);
        _exit(1);
    }

    int32_t result = tiny2->cameraSetAiModeU(Device::AiWorkModeNone, 0);
    Devices::get().close();
    if (result != RM_RET_OK) {
        std::fprintf(stderr, "obsbot-ai-off : cameraSetAiModeU a renvoyé %d\n", result);
        return 2;
    }
    std::printf("obsbot-ai-off : suivi IA coupé\n");
    return 0;
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès ; recompiler l'utilitaire**

```bash
cd mac/ptzd && swift build 2>&1 | grep -c "warning:" ; swift test 2>&1 | grep -E "Test run with|✘"
```

Attendu : `0` avertissement, puis trois lignes `Test run with` : 78 (PTZCore), 5 et 5, soit 88 tests, tous `passed`.

```bash
mac/ai-off/build.sh && otool -l mac/ai-off/build/bin/obsbot-ai-off | grep -A2 LC_RPATH | grep path
```

Attendu : le chemin du binaire, puis `path @executable_path/../lib`.

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

```bash
git add mac/ptzd/Sources/PTZCore/ControlTaker.swift \
    mac/ptzd/Sources/PTZCore/PTZController.swift \
    mac/ptzd/Tests/PTZCoreTests/ControlTakerTests.swift \
    mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift \
    mac/ai-off/main.cpp
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Prise en main : un nouvel essai, et 10 s pour trouver la caméra

Quand l'app ouvre la vidéo et la prise en main ensemble, le SDK peut dépasser
5 s et obsbot-ai-off plantait en le refermant (amendement A3).

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

- [ ] **Étape 6 : Réinstaller le service (annoncer à Majid : `ptzd` redémarre)**

```bash
echo "go2rtc=$(pgrep -x go2rtc) coreaudiod=$(pgrep -x coreaudiod)"; scripts/install-mac.sh
```

Attendu : `state = running` et un nouveau `pid`. Puis, en local :

```bash
for i in 1 2 3; do swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"takeControl"}' wait 9 2>&1 | grep -o '"control":"[a-z]*"' | tail -1; done; echo "go2rtc=$(pgrep -x go2rtc) coreaudiod=$(pgrep -x coreaudiod)"
```

Attendu : trois fois `"control":"ready"`, et les mêmes PID qu'avant.

---

### Tâche 2 : Projet Xcode, réglages de connexion

Crée le projet de l'app, décrit pour xcodegen dans `ios/project.yml` (le `.xcodeproj` n'est pas versionné). Cibles : l'app `Nacelle` (iOS 26, iPhone, Swift 6 strict) et les tests `NacelleTests` (Swift Testing). Dépendances : `NacelleProtocol` (paquet local) et WebRTC 154.0.0 (stasel/WebRTC, paquet binaire), la seule dépendance externe (spec § 7.1). Exception ATS limitée à `ts.net` (spec § 7.5) ; 127.0.0.1 n'en a pas besoin (vérifié dans le simulateur). La signature lit l'équipe dans `ios/Config/Local.xcconfig`, non versionné. Réglages de connexion de la spec § 7.2, enregistrés dans UserDefaults. Le point d'entrée est provisoire : il sera remplacé à la tâche 6.

**Fichiers :**
- Modifier : `.gitignore`
- Créer : `ios/project.yml`
- Créer : `ios/Config/Signing.xcconfig`
- Créer : `ios/Nacelle/App/NacelleApp.swift`
- Créer : `ios/NacelleTests/ConnectionSettingsTests.swift`
- Créer : `ios/Nacelle/App/Scheduler.swift`
- Créer : `ios/Nacelle/Settings/ConnectionSettings.swift`

**Interfaces :**
- Utilise : `NacelleProtocol` (plan côté Mac, tâche 1), par dépendance de paquet locale.
- Produit :
  - `struct ConnectionSettings` : `host`, `go2rtcPort` (1984), `streamName` ("obsbot"), `ptzdPort` (1985), `isComplete`, `webRTCURL`, `ptzdURL`
  - `struct SettingsStore(defaults:)` : `load()`, `save(_:)` (clé `connectionSettings`)
  - `protocol Cancellable`, `@MainActor protocol Scheduler` (`schedule(after:_:)`) et `MainScheduler`

- [ ] **Étape 1 : Écrire les tests et le projet**

Ajouter à la fin de `.gitignore` :

```

# App iOS : projet et Info.plist générés par xcodegen, équipe de signature locale
ios/Nacelle.xcodeproj/
ios/Nacelle/Info.plist
ios/Config/Local.xcconfig
```

`ios/project.yml` :

```yaml
# Projet Xcode de l'app Nacelle, généré par xcodegen (le .xcodeproj n'est pas versionné).
# Générer : cd ios && xcodegen
name: Nacelle
options:
  bundleIdPrefix: io.github.djoko-cli
  deploymentTarget:
    iOS: "26.0"
  createIntermediateGroups: true
configFiles:
  Debug: Config/Signing.xcconfig
  Release: Config/Signing.xcconfig
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    ENABLE_USER_SCRIPT_SANDBOXING: YES
packages:
  NacelleProtocol:
    path: ../Packages/NacelleProtocol
  WebRTC:
    url: https://github.com/stasel/WebRTC
    exactVersion: 154.0.0
targets:
  Nacelle:
    type: application
    platform: iOS
    sources: [Nacelle]
    dependencies:
      - package: NacelleProtocol
      - package: WebRTC
    info:
      path: Nacelle/Info.plist
      properties:
        CFBundleDisplayName: Nacelle
        UILaunchScreen: {}
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        NSLocalNetworkUsageDescription: "À la maison, la vidéo de la caméra peut passer directement par le réseau local."
        NSAppTransportSecurity:
          NSExceptionDomains:
            ts.net:
              NSIncludesSubdomains: true
              NSExceptionAllowsInsecureHTTPLoads: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.github.djoko-cli.nacelle
        TARGETED_DEVICE_FAMILY: "1"
        MARKETING_VERSION: "1.0"
        CURRENT_PROJECT_VERSION: "1"
  NacelleTests:
    type: bundle.unit-test
    platform: iOS
    sources: [NacelleTests]
    dependencies:
      - target: Nacelle
      - package: NacelleProtocol
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
schemes:
  Nacelle:
    build:
      targets:
        Nacelle: all
        NacelleTests: [test]
    test:
      targets: [NacelleTests]
```

`ios/Config/Signing.xcconfig` :

```
// Signature de l'app. L'équipe de développement est propre à chaque installation :
// elle se règle dans Local.xcconfig, à côté de ce fichier, non versionné.
// Contenu attendu de Local.xcconfig : DEVELOPMENT_TEAM = <identifiant de l'équipe>
CODE_SIGN_STYLE = Automatic
#include? "Local.xcconfig"
```

`ios/Nacelle/App/NacelleApp.swift` :

```swift
import SwiftUI

/// Point d'entrée provisoire : remplacé à la tâche 6 par l'écran de pilotage.
@main
struct NacelleApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Nacelle")
        }
    }
}
```

`ios/NacelleTests/ConnectionSettingsTests.swift` :

```swift
import Foundation
import Testing
@testable import Nacelle

@Suite("Réglages de connexion")
struct ConnectionSettingsTests {
    @Test("Adresses construites à partir de l'hôte, sans espaces")
    func urls() {
        let settings = ConnectionSettings(host: " mac.exemple.ts.net ", go2rtcPort: 1984, streamName: "obsbot", ptzdPort: 1985)
        #expect(settings.webRTCURL?.absoluteString == "http://mac.exemple.ts.net:1984/api/webrtc?src=obsbot")
        #expect(settings.ptzdURL?.absoluteString == "ws://mac.exemple.ts.net:1985")
    }

    @Test("Incomplets : hôte vide, flux vide ou port hors bornes")
    func incomplete() {
        #expect(!ConnectionSettings().isComplete)
        #expect(ConnectionSettings().webRTCURL == nil)
        #expect(!ConnectionSettings(host: "mac", streamName: " ").isComplete)
        #expect(!ConnectionSettings(host: "mac", go2rtcPort: 0).isComplete)
        #expect(!ConnectionSettings(host: "mac", ptzdPort: 70000).isComplete)
        #expect(ConnectionSettings(host: "mac").isComplete)
    }

    @Test("Enregistrés puis relus")
    func roundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "nacelle-tests-\(UUID().uuidString)"))
        let store = SettingsStore(defaults: defaults)
        #expect(store.load() == ConnectionSettings())
        let settings = ConnectionSettings(host: "mac.exemple.ts.net", go2rtcPort: 1984, streamName: "cam", ptzdPort: 1999)
        store.save(settings)
        #expect(store.load() == settings)
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E "error:|Test run with|\*\* TEST"
```

Échec attendu : la compilation des tests échoue : `cannot find 'ConnectionSettings' in scope`. Le premier lancement télécharge d'abord WebRTC.

- [ ] **Étape 3 : Écrire l'implémentation**

`ios/Nacelle/App/Scheduler.swift` :

```swift
import Foundation

/// Une action programmée, annulable.
protocol Cancellable: AnyObject {
    func cancel()
}

/// Minuteries, injectées pour que les tests maîtrisent le temps.
@MainActor
protocol Scheduler: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable
}

/// Implémentation réelle, sur la file principale.
@MainActor
final class MainScheduler: Scheduler {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return WorkItemCancellable(item: item)
    }
}

private final class WorkItemCancellable: Cancellable {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}
```

`ios/Nacelle/Settings/ConnectionSettings.swift` :

```swift
import Foundation

/// Où joindre le Mac (spec § 7.2). Saisi au premier lancement, modifiable ensuite.
struct ConnectionSettings: Codable, Equatable, Sendable {
    /// Nom Tailscale du Mac (par exemple `mon-mac.tailnet.ts.net`) ou son adresse IPv4.
    var host = ""
    var go2rtcPort = 1984
    var streamName = "obsbot"
    var ptzdPort = 1985

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedStream: String {
        streamName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Un hôte, un nom de flux et deux ports valides.
    var isComplete: Bool {
        !trimmedHost.isEmpty && !trimmedStream.isEmpty
            && (1...65535).contains(go2rtcPort) && (1...65535).contains(ptzdPort)
    }

    /// `http://<hôte>:<port go2rtc>/api/webrtc?src=<flux>`
    var webRTCURL: URL? {
        guard isComplete else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmedHost
        components.port = go2rtcPort
        components.path = "/api/webrtc"
        components.queryItems = [URLQueryItem(name: "src", value: trimmedStream)]
        return components.url
    }

    /// `ws://<hôte>:<port ptzd>`
    var ptzdURL: URL? {
        guard isComplete else { return nil }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = trimmedHost
        components.port = ptzdPort
        return components.url
    }
}

/// Réglages enregistrés dans UserDefaults.
struct SettingsStore {
    static let key = "connectionSettings"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ConnectionSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(ConnectionSettings.self, from: data) else {
            return ConnectionSettings()
        }
        return settings
    }

    func save(_ settings: ConnectionSettings) {
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.key)
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E "error:|Test run with|\*\* TEST"
```

Attendu : `Test run with 3 tests` … `passed`, puis `** TEST SUCCEEDED **`, sans ligne `error:`. Vérifier aussi qu'il n'y a aucun avertissement Swift : la même commande avec `| grep -c "warning:"` à la place du dernier filtre doit donner `0`.

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

```bash
git add .gitignore \
    ios/project.yml \
    ios/Config/Signing.xcconfig \
    ios/Nacelle/App/NacelleApp.swift \
    ios/NacelleTests/ConnectionSettingsTests.swift \
    ios/Nacelle/App/Scheduler.swift \
    ios/Nacelle/Settings/ConnectionSettings.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute le projet de l'app iOS et ses réglages de connexion

Projet décrit pour xcodegen (iOS 26, Swift 6 strict, WebRTC 154.0.0) ;
exception ATS limitée à ts.net ; équipe de signature dans un réglage local.

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 3 : Géométrie du joystick

Spec § 7.2 : le geste devient un vecteur de -1 à 1, borné au cercle, avec une zone morte de 0,1. Vers la droite = pan positif, vers le haut = tilt positif (l'axe vertical de l'écran est inversé) : c'est la convention que `ptzd` étalonne (sens +1/+1 vérifiés sur la caméra).

**Fichiers :**
- Créer : `ios/NacelleTests/JoystickMathTests.swift`
- Créer : `ios/Nacelle/Control/JoystickMath.swift`

**Interfaces :**
- Utilise : rien.
- Produit :
  - `struct JoystickVector(pan: Double, tilt: Double)`, `JoystickVector.zero`
  - `JoystickMath.deadZone = 0.1`, `JoystickMath.vector(translation:radius:) -> JoystickVector`, `JoystickMath.knobOffset(translation:radius:) -> CGSize`

- [ ] **Étape 1 : Écrire les tests**

`ios/NacelleTests/JoystickMathTests.swift` :

```swift
import CoreGraphics
import Testing
@testable import Nacelle

@Suite("Joystick")
struct JoystickMathTests {
    @Test("À droite : pan positif ; vers le haut : tilt positif")
    func axes() {
        #expect(JoystickMath.vector(translation: CGSize(width: 75, height: 0), radius: 75) == JoystickVector(pan: 1, tilt: 0))
        #expect(JoystickMath.vector(translation: CGSize(width: 0, height: -75), radius: 75) == JoystickVector(pan: 0, tilt: 1))
    }

    @Test("Zone morte : moins de 0,1 du rayon donne l'arrêt")
    func deadZone() {
        #expect(JoystickMath.vector(translation: CGSize(width: 7, height: 0), radius: 75) == .zero)
        #expect(JoystickMath.vector(translation: CGSize(width: 8, height: 0), radius: 75).pan > 0.1)
    }

    @Test("Au-delà du cercle, la consigne reste de longueur 1")
    func clampedToCircle() {
        let vector = JoystickMath.vector(translation: CGSize(width: 300, height: -300), radius: 75)
        #expect(abs(vector.pan - 0.7071) < 0.001)
        #expect(abs(vector.tilt - 0.7071) < 0.001)
    }

    @Test("Le bouton affiché reste dans le cercle")
    func knob() {
        #expect(JoystickMath.knobOffset(translation: CGSize(width: 30, height: 40), radius: 75) == CGSize(width: 30, height: 40))
        #expect(JoystickMath.knobOffset(translation: CGSize(width: 150, height: 0), radius: 75) == CGSize(width: 75, height: 0))
    }

    @Test("Rayon nul : arrêt")
    func zeroRadius() {
        #expect(JoystickMath.vector(translation: CGSize(width: 10, height: 10), radius: 0) == .zero)
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E "error:|Test run with|\*\* TEST"
```

Échec attendu : la compilation des tests échoue : `cannot find 'JoystickMath' in scope`.

- [ ] **Étape 3 : Écrire l'implémentation**

`ios/Nacelle/Control/JoystickMath.swift` :

```swift
import CoreGraphics

/// Consigne du joystick, de -1 à 1 sur chaque axe. Vers la droite = pan positif, vers le haut = tilt positif.
struct JoystickVector: Equatable, Sendable {
    var pan: Double
    var tilt: Double

    static let zero = JoystickVector(pan: 0, tilt: 0)
}

/// Géométrie du joystick (spec § 7.2) : bornée au cercle, avec une zone morte de 0,1.
enum JoystickMath {
    static let deadZone = 0.1

    /// Déplacement du doigt depuis le centre → consigne. L'axe vertical d'écran est inversé.
    static func vector(translation: CGSize, radius: CGFloat) -> JoystickVector {
        guard radius > 0 else { return .zero }
        var pan = Double(translation.width / radius)
        var tilt = Double(-translation.height / radius)
        let length = (pan * pan + tilt * tilt).squareRoot()
        guard length >= deadZone else { return .zero }
        if length > 1 {
            pan /= length
            tilt /= length
        }
        return JoystickVector(pan: pan, tilt: tilt)
    }

    /// Position affichée du bouton : le déplacement du doigt, borné au cercle.
    static func knobOffset(translation: CGSize, radius: CGFloat) -> CGSize {
        let length = (translation.width * translation.width + translation.height * translation.height).squareRoot()
        guard length > radius, length > 0 else { return translation }
        return CGSize(width: translation.width * radius / length, height: translation.height * radius / length)
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E "error:|Test run with|\*\* TEST"
```

Attendu : `Test run with 8 tests` … `passed`, puis `** TEST SUCCEEDED **`, sans ligne `error:`. Vérifier aussi qu'il n'y a aucun avertissement Swift : la même commande avec `| grep -c "warning:"` à la place du dernier filtre doit donner `0`.

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

```bash
git add ios/NacelleTests/JoystickMathTests.swift \
    ios/Nacelle/Control/JoystickMath.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute la géométrie du joystick

Vecteur borné au cercle, zone morte de 0,1, vers le haut = tilt positif
(spec § 7.2).

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 4 : Client ptzd et transport WebSocket

Spec § 7.2. `PTZClient` envoie `takeControl` à chaque connexion ; tant que le joystick est hors du centre, il renvoie le dernier `move` 10 fois par seconde (sous les 300 ms de l'arrêt automatique de `ptzd`) ; au relâchement, `move 0,0` une fois. Il publie le dernier `state`, retient la dernière erreur, se reconnecte après 1, 2, 4 puis 8 s, et signale « injoignable » quand une tentative échoue avant ouverture. Rien n'est envoyé hors connexion. Le transport réel, `URLSessionWebSocketTransport`, n'envoie pas d'en-tête `Origin` : `ptzd` l'accepte (il refuse les navigateurs).

**Fichiers :**
- Créer : `ios/NacelleTests/FakeScheduler.swift`
- Créer : `ios/NacelleTests/FakeTransport.swift`
- Créer : `ios/NacelleTests/PTZClientTests.swift`
- Créer : `ios/Nacelle/PTZ/WebSocketTransport.swift`
- Créer : `ios/Nacelle/PTZ/PTZClient.swift`

**Interfaces :**
- Utilise : `Scheduler`, `Cancellable` (tâche 2), `JoystickVector` (tâche 3), `NacelleCodec`, `ClientMessage`, `ServerMessage`, `StateSnapshot`, `ErrorCode` (`NacelleProtocol`).
- Produit :
  - `enum TransportEvent` (`.opened`, `.message(String)`, `.closed`), `@MainActor protocol WebSocketTransport` (`onEvent`, `open(_:)`, `send(_:)`, `close()`), `URLSessionWebSocketTransport`
  - `@MainActor @Observable final class PTZClient(transport:scheduler:)` : `link` (`.idle`, `.connecting`, `.connected`, `.waitingToRetry`), `state`, `lastError`, `isUnreachable`
  - `start(url:)`, `stop()`, `setJoystick(_:)`, `setZoom(_:)`, `setPrivacy(_:)`, `takeControl()` ; `repeatInterval = 0.1`, `retryDelays = [1, 2, 4, 8]`
  - Faux pour les tests : `FakeScheduler` (`advance(by:)`, `pendingCount`), `FakeTransport` (`openedURLs`, `sent`, `closeCount`, `emit(_:)`)

- [ ] **Étape 1 : Écrire les tests**

`ios/NacelleTests/FakeScheduler.swift` :

```swift
import Foundation
@testable import Nacelle

/// Horloge manuelle : `advance(by:)` exécute les actions arrivées à échéance, dans l'ordre.
@MainActor
final class FakeScheduler: Scheduler {
    private(set) var now: TimeInterval = 0
    private var tasks: [FakeTask] = []
    private var counter = 0

    var pendingCount: Int {
        tasks.filter { !$0.cancelled }.count
    }

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
```

`ios/NacelleTests/FakeTransport.swift` :

```swift
import Foundation
@testable import Nacelle

/// Transport WebSocket simulé : enregistre les ouvertures et les envois ; le test déclenche les événements.
@MainActor
final class FakeTransport: WebSocketTransport {
    var onEvent: ((TransportEvent) -> Void)?
    private(set) var openedURLs: [URL] = []
    private(set) var sent: [String] = []
    private(set) var closeCount = 0

    func open(_ url: URL) {
        openedURLs.append(url)
    }

    func send(_ text: String) {
        sent.append(text)
    }

    func close() {
        closeCount += 1
    }

    func emit(_ event: TransportEvent) {
        onEvent?(event)
    }
}
```

`ios/NacelleTests/PTZClientTests.swift` :

```swift
import Foundation
import NacelleProtocol
import Testing
@testable import Nacelle

@MainActor
@Suite("Client ptzd")
struct PTZClientTests {
    let transport = FakeTransport()
    let scheduler = FakeScheduler()
    let client: PTZClient
    let url = URL(string: "ws://mac.exemple.ts.net:1985")!

    init() {
        client = PTZClient(transport: transport, scheduler: scheduler)
    }

    private func decoded() -> [ClientMessage] {
        transport.sent.compactMap { try? NacelleCodec.decodeClient($0) }
    }

    private func connect() {
        client.start(url: url)
        transport.emit(.opened)
    }

    @Test("À l'ouverture : connecté, et prise en main envoyée")
    func takeControlOnOpen() {
        connect()
        #expect(transport.openedURLs == [url])
        #expect(client.link == .connected)
        #expect(decoded() == [.takeControl])
    }

    @Test("Joystick hors du centre : move tout de suite, puis 10 fois par seconde")
    func repeatsMove() {
        connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        scheduler.advance(by: 0.35)
        #expect(decoded() == [.takeControl] + Array(repeating: .move(pan: 0.5, tilt: 0), count: 4))
    }

    @Test("Relâchement : move 0,0 une fois, puis plus rien")
    func releaseSendsStopOnce() {
        connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        client.setJoystick(.zero)
        client.setJoystick(.zero)
        scheduler.advance(by: 1)
        #expect(decoded() == [.takeControl, .move(pan: 0.5, tilt: 0), .move(pan: 0, tilt: 0)])
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Un changement de consigne est envoyé sans attendre le prochain tic")
    func newVectorImmediately() {
        connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        client.setJoystick(JoystickVector(pan: 0, tilt: -1))
        #expect(decoded().last == .move(pan: 0, tilt: -1))
        scheduler.advance(by: 0.1)
        #expect(decoded().last == .move(pan: 0, tilt: -1))
    }

    @Test("L'état reçu est publié ; une erreur est retenue")
    func receivesState() throws {
        connect()
        let snapshot = StateSnapshot(camera: .connected, control: .ready, privacy: false, pan: 2, tilt: -1, zoom: 33, moving: false)
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.state(snapshot))))
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.error(code: .privacyActive, message: "x"))))
        transport.emit(.message("pas du json"))
        #expect(client.state == snapshot)
        #expect(client.lastError == .privacyActive)
    }

    @Test("Échec de connexion : Mac injoignable, nouvel essai après 1, 2, 4 puis 8 s")
    func retryBackoff() {
        client.start(url: url)
        transport.emit(.closed)
        #expect(client.isUnreachable)
        #expect(client.link == .waitingToRetry)
        for delay in [1.0, 2, 4, 8, 8] {
            let before = transport.openedURLs.count
            scheduler.advance(by: delay - 0.01)
            #expect(transport.openedURLs.count == before)
            scheduler.advance(by: 0.01)
            #expect(transport.openedURLs.count == before + 1)
            transport.emit(.closed)
        }
    }

    @Test("Une connexion réussie efface « injoignable » et remet l'espacement à 1 s")
    func recovery() {
        client.start(url: url)
        transport.emit(.closed)
        scheduler.advance(by: 1)
        transport.emit(.opened)
        #expect(!client.isUnreachable)
        transport.emit(.closed)
        #expect(!client.isUnreachable)
        let before = transport.openedURLs.count
        scheduler.advance(by: 1)
        #expect(transport.openedURLs.count == before + 1)
    }

    @Test("Coupure : le mouvement s'arrête et l'état est oublié")
    func closeStopsRepeating() throws {
        connect()
        transport.emit(.message(try NacelleCodec.encode(ServerMessage.state(
            StateSnapshot(camera: .connected, control: .ready, privacy: false, pan: 0, tilt: 0, zoom: 0, moving: true)
        ))))
        client.setJoystick(JoystickVector(pan: 1, tilt: 0))
        transport.emit(.closed)
        let sentAtClose = transport.sent.count
        scheduler.advance(by: 0.5)
        #expect(transport.sent.count == sentAtClose)
        #expect(client.state == nil)
    }

    @Test("Arrière-plan : move 0,0 si on pilotait, fermeture, aucune reconnexion")
    func stop() {
        connect()
        client.setJoystick(JoystickVector(pan: 1, tilt: 0))
        client.stop()
        #expect(decoded().last == .move(pan: 0, tilt: 0))
        #expect(transport.closeCount >= 1)
        #expect(client.link == .idle)
        transport.emit(.closed)
        scheduler.advance(by: 10)
        #expect(transport.openedURLs.count == 1)
    }

    @Test("Hors connexion, rien n'est envoyé")
    func noSendWhileDisconnected() {
        client.start(url: url)
        client.setZoom(40)
        client.setPrivacy(true)
        #expect(transport.sent.isEmpty)
    }

    @Test("Zoom et vie privée")
    func zoomAndPrivacy() {
        connect()
        client.setZoom(40)
        client.setPrivacy(true)
        #expect(decoded() == [.takeControl, .zoom(value: 40), .privacy(on: true)])
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E "error:|Test run with|\*\* TEST"
```

Échec attendu : la compilation des tests échoue : `cannot find type 'WebSocketTransport' in scope`.

- [ ] **Étape 3 : Écrire l'implémentation**

`ios/Nacelle/PTZ/WebSocketTransport.swift` :

```swift
import Foundation

/// Ce qui arrive sur la connexion WebSocket.
enum TransportEvent: Equatable, Sendable {
    case opened
    case message(String)
    /// Connexion fermée ou impossible à ouvrir.
    case closed
}

/// Le WebSocket vers ptzd, derrière un protocole pour les tests. Les événements arrivent sur le MainActor.
@MainActor
protocol WebSocketTransport: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    func open(_ url: URL)
    func send(_ text: String)
    func close()
}

/// Implémentation réelle, sur URLSessionWebSocketTask. Une seule connexion à la fois ;
/// les événements d'une connexion remplacée sont ignorés.
@MainActor
final class URLSessionWebSocketTransport: NSObject, WebSocketTransport {
    var onEvent: ((TransportEvent) -> Void)?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    func open(_ url: URL) {
        close()
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        receive(on: task)
    }

    func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, task === self.task else { return }
                switch result {
                case let .success(.string(text)):
                    self.onEvent?(.message(text))
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure:
                    self.finish(task)
                }
            }
        }
    }

    /// Signale la fin d'une connexion, une seule fois.
    private func finish(_ task: URLSessionTask) {
        guard task === self.task else { return }
        self.task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        onEvent?(.closed)
    }
}

extension URLSessionWebSocketTransport: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        MainActor.assumeIsolated {
            guard webSocketTask === self.task else { return }
            self.onEvent?(.opened)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            self.finish(task)
        }
    }
}
```

`ios/Nacelle/PTZ/PTZClient.swift` :

```swift
import Foundation
import NacelleProtocol
import Observation

/// Dialogue avec ptzd (spec § 7.2) : prise en main à chaque connexion, `move` répété
/// 10 fois par seconde tant que le joystick est hors du centre, reconnexion espacée.
@MainActor
@Observable
final class PTZClient {
    enum Link: Equatable {
        case idle
        case connecting
        case connected
        case waitingToRetry
    }

    static let repeatInterval: TimeInterval = 0.1
    static let retryDelays: [TimeInterval] = [1, 2, 4, 8]

    private(set) var link: Link = .idle
    /// Dernier état reçu de ptzd ; nil hors connexion.
    private(set) var state: StateSnapshot?
    /// Dernière erreur renvoyée par ptzd.
    private(set) var lastError: ErrorCode?
    /// Vrai quand une tentative de connexion a échoué, jusqu'à la prochaine réussite.
    private(set) var isUnreachable = false

    @ObservationIgnored private let transport: any WebSocketTransport
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var openedThisAttempt = false
    @ObservationIgnored private var retry: (any Cancellable)?
    @ObservationIgnored private var repeater: (any Cancellable)?
    @ObservationIgnored private var currentMove = JoystickVector.zero

    init(transport: any WebSocketTransport, scheduler: any Scheduler) {
        self.transport = transport
        self.scheduler = scheduler
        transport.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    func start(url: URL) {
        self.url = url
        attempt = 0
        retry?.cancel()
        retry = nil
        connect()
    }

    /// Passage en arrière-plan : arrêt de la nacelle, puis fermeture.
    func stop() {
        if currentMove != .zero {
            send(.move(pan: 0, tilt: 0))
        }
        currentMove = .zero
        stopRepeating()
        retry?.cancel()
        retry = nil
        url = nil
        transport.close()
        link = .idle
        state = nil
    }

    func setJoystick(_ vector: JoystickVector) {
        let wasMoving = currentMove != .zero
        currentMove = vector
        guard vector != .zero else {
            stopRepeating()
            if wasMoving {
                send(.move(pan: 0, tilt: 0))
            }
            return
        }
        send(.move(pan: vector.pan, tilt: vector.tilt))
        if repeater == nil {
            scheduleRepeat()
        }
    }

    func setZoom(_ value: Int) {
        send(.zoom(value: value))
    }

    func setPrivacy(_ on: Bool) {
        send(.privacy(on: on))
    }

    func takeControl() {
        send(.takeControl)
    }

    private func connect() {
        guard let url else { return }
        link = .connecting
        openedThisAttempt = false
        transport.open(url)
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .opened:
            link = .connected
            openedThisAttempt = true
            attempt = 0
            isUnreachable = false
            send(.takeControl)
        case let .message(text):
            guard let message = try? NacelleCodec.decodeServer(text) else { return }
            switch message {
            case let .state(snapshot):
                state = snapshot
            case let .error(code, _):
                lastError = code
            }
        case .closed:
            stopRepeating()
            currentMove = .zero
            state = nil
            guard url != nil else {
                link = .idle
                return
            }
            if !openedThisAttempt {
                isUnreachable = true
            }
            link = .waitingToRetry
            let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
            attempt += 1
            retry = scheduler.schedule(after: delay) { [weak self] in
                self?.retry = nil
                self?.connect()
            }
        }
    }

    private func send(_ message: ClientMessage) {
        guard link == .connected, let text = try? NacelleCodec.encode(message) else { return }
        transport.send(text)
    }

    private func scheduleRepeat() {
        repeater = scheduler.schedule(after: Self.repeatInterval) { [weak self] in
            self?.repeatTick()
        }
    }

    private func repeatTick() {
        repeater = nil
        guard currentMove != .zero else { return }
        send(.move(pan: currentMove.pan, tilt: currentMove.tilt))
        scheduleRepeat()
    }

    private func stopRepeating() {
        repeater?.cancel()
        repeater = nil
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E "error:|Test run with|\*\* TEST"
```

Attendu : `Test run with 19 tests` … `passed`, puis `** TEST SUCCEEDED **`, sans ligne `error:`. Vérifier aussi qu'il n'y a aucun avertissement Swift : la même commande avec `| grep -c "warning:"` à la place du dernier filtre doit donner `0`.

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

```bash
git add ios/NacelleTests/FakeScheduler.swift \
    ios/NacelleTests/FakeTransport.swift \
    ios/NacelleTests/PTZClientTests.swift \
    ios/Nacelle/PTZ/WebSocketTransport.swift \
    ios/Nacelle/PTZ/PTZClient.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute le client ptzd et son transport WebSocket

Prise en main à chaque connexion, move répété 10 fois par seconde, move 0,0
au relâchement, reconnexion après 1, 2, 4 puis 8 s (spec § 7.2).

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 5 : Vidéo WebRTC de go2rtc

Spec § 7.2. `Signaling` construit la requête `POST …/api/webrtc?src=<flux>` en `application/sdp` et n'accepte qu'une réponse `201` contenant un SDP (comportement de go2rtc vérifié avec curl). `VideoSession` crée une `RTCPeerConnection` en réception vidéo seule, sans serveur ICE, attend la fin de la collecte des candidats (2 s au plus), échange l'offre et la réponse, puis passe à `playing` quand l'ICE est connecté ; en cas de perte, nouvel essai après 1, 2, 4 puis 8 s. L'image s'affiche sans rognage. Les rappels de WebRTC arrivent sur son propre fil : `PeerObserver` les traduit en événements renvoyés sur le MainActor, et chaque tentative porte un numéro (`generation`) pour ignorer les rappels d'une connexion remplacée. Seule la signalisation a des tests automatiques ; la vidéo est vérifiée dans le simulateur à la tâche 7.

**Fichiers :**
- Créer : `ios/NacelleTests/SignalingTests.swift`
- Créer : `ios/Nacelle/Video/Signaling.swift`
- Créer : `ios/Nacelle/Video/VideoSession.swift`
- Créer : `ios/Nacelle/Video/VideoView.swift`

**Interfaces :**
- Utilise : `Scheduler`, `Cancellable` (tâche 2), WebRTC 154.0.0 (`@preconcurrency import WebRTC`).
- Produit :
  - `Signaling.request(url:offerSDP:) -> URLRequest`, `Signaling.answer(data:response:) throws -> String`, `Signaling.timeout = 10`, `SignalingError.badResponse(status:)`
  - `@MainActor @Observable final class VideoSession(scheduler:)` : `phase` (`.idle`, `.connecting`, `.playing`, `.lost`), `attach(renderer:)`, `start(url:)`, `stop()`
  - `struct VideoView(session:)` (UIViewRepresentable autour de `RTCMTLVideoView`)

- [ ] **Étape 1 : Écrire les tests**

`ios/NacelleTests/SignalingTests.swift` :

```swift
import Foundation
import Testing
@testable import Nacelle

@Suite("Signalisation WebRTC")
struct SignalingTests {
    let url = URL(string: "http://mac.exemple.ts.net:1984/api/webrtc?src=obsbot")!

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    @Test("Requête : POST de l'offre, en application/sdp")
    func request() {
        let request = Signaling.request(url: url, offerSDP: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n")
        #expect(request.httpMethod == "POST")
        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/sdp")
        #expect(request.httpBody == Data("v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n".utf8))
        #expect(request.timeoutInterval == Signaling.timeout)
    }

    @Test("Réponse 201 avec un SDP : acceptée")
    func answer() throws {
        let sdp = "v=0\r\ns=-\r\n"
        #expect(try Signaling.answer(data: Data(sdp.utf8), response: response(201)) == sdp)
    }

    @Test("Autre statut ou corps non SDP : refusé")
    func badAnswer() {
        #expect(throws: SignalingError.badResponse(status: 500)) {
            try Signaling.answer(data: Data("v=0".utf8), response: response(500))
        }
        #expect(throws: SignalingError.badResponse(status: 201)) {
            try Signaling.answer(data: Data("{}".utf8), response: response(201))
        }
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E "error:|Test run with|\*\* TEST"
```

Échec attendu : la compilation des tests échoue : `cannot find 'Signaling' in scope`.

- [ ] **Étape 3 : Écrire l'implémentation**

`ios/Nacelle/Video/Signaling.swift` :

```swift
import Foundation

enum SignalingError: Error, Equatable {
    /// Réponse de go2rtc autre que `201` avec un SDP.
    case badResponse(status: Int)
}

/// Échange d'offre et de réponse avec go2rtc (spec § 7.2) : une seule requête, sans « trickle ».
enum Signaling {
    static let timeout: TimeInterval = 10

    /// `POST <url>` avec l'offre SDP, `Content-Type: application/sdp`.
    static func request(url: URL, offerSDP: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(offerSDP.utf8)
        return request
    }

    /// Le SDP de réponse, si go2rtc a répondu `201` avec un corps SDP.
    static func answer(data: Data, response: URLResponse) throws -> String {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201, let sdp = String(data: data, encoding: .utf8), sdp.hasPrefix("v=0") else {
            throw SignalingError.badResponse(status: status)
        }
        return sdp
    }
}
```

`ios/Nacelle/Video/VideoSession.swift` :

```swift
import Foundation
import Observation
@preconcurrency import WebRTC

/// Vidéo en direct de go2rtc, en WebRTC, réception seule (spec § 7.2).
@MainActor
@Observable
final class VideoSession {
    enum Phase: Equatable {
        case idle
        case connecting
        case playing
        case lost
    }

    static let gatheringTimeout: TimeInterval = 2
    static let retryDelays: [TimeInterval] = [1, 2, 4, 8]

    private(set) var phase: Phase = .idle

    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var peer: RTCPeerConnection?
    @ObservationIgnored private var observer: PeerObserver?
    @ObservationIgnored private var track: RTCVideoTrack?
    @ObservationIgnored private var renderer: RTCMTLVideoView?
    @ObservationIgnored private var retry: (any Cancellable)?
    @ObservationIgnored private var gathering: CheckedContinuation<Void, Never>?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    init(scheduler: any Scheduler) {
        self.scheduler = scheduler
    }

    /// La vue qui affiche l'image, fournie par VideoView.
    func attach(renderer: RTCMTLVideoView) {
        self.renderer = renderer
        track?.add(renderer)
    }

    func start(url: URL) {
        self.url = url
        attempt = 0
        connect()
    }

    /// Passage en arrière-plan : fermeture de la connexion vidéo.
    func stop() {
        url = nil
        retry?.cancel()
        retry = nil
        teardown()
        phase = .idle
    }

    private func connect() {
        guard let url else { return }
        teardown()
        generation += 1
        let current = generation
        phase = .connecting
        Task {
            await negotiate(url: url, generation: current)
        }
    }

    private func negotiate(url: URL, generation current: Int) async {
        do {
            let peer = try makePeer(generation: current)
            let offer = try await peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            try await peer.setLocalDescription(offer)
            await waitForGathering(generation: current)
            guard current == generation, let sdp = peer.localDescription?.sdp else { return }
            let (data, response) = try await URLSession.shared.data(for: Signaling.request(url: url, offerSDP: sdp))
            let answer = try Signaling.answer(data: data, response: response)
            guard current == generation else { return }
            try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer))
        } catch {
            if current == generation {
                lost()
            }
        }
    }

    private func makePeer(generation current: Int) throws -> RTCPeerConnection {
        let configuration = RTCConfiguration()
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        let observer = PeerObserver { [weak self] event in
            Task { @MainActor in
                self?.handle(event, generation: current)
            }
        }
        guard let peer = Self.factory.peerConnection(
            with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: observer
        ) else {
            throw SignalingError.badResponse(status: 0)
        }
        let receiveOnly = RTCRtpTransceiverInit()
        receiveOnly.direction = .recvOnly
        let transceiver = peer.addTransceiver(of: .video, init: receiveOnly)
        if let track = transceiver?.receiver.track as? RTCVideoTrack {
            self.track = track
            if let renderer {
                track.add(renderer)
            }
        }
        self.peer = peer
        self.observer = observer
        return peer
    }

    /// Attend la fin de la collecte des candidats ICE, 2 s au plus.
    private func waitForGathering(generation current: Int) async {
        if peer?.iceGatheringState == .complete { return }
        await withCheckedContinuation { continuation in
            gathering = continuation
            scheduler.schedule(after: Self.gatheringTimeout) { [weak self] in
                guard let self, current == self.generation else { return }
                self.resumeGathering()
            }
        }
    }

    private func resumeGathering() {
        gathering?.resume()
        gathering = nil
    }

    private func handle(_ event: PeerObserver.Event, generation current: Int) {
        guard current == generation else { return }
        switch event {
        case .gatheringComplete:
            resumeGathering()
        case .connected:
            attempt = 0
            phase = .playing
        case .disconnected:
            lost()
        }
    }

    private func lost() {
        teardown()
        phase = .lost
        guard url != nil else { return }
        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
        attempt += 1
        retry = scheduler.schedule(after: delay) { [weak self] in
            self?.retry = nil
            self?.connect()
        }
    }

    private func teardown() {
        generation += 1
        resumeGathering()
        if let renderer {
            track?.remove(renderer)
        }
        track = nil
        peer?.close()
        peer = nil
        observer = nil
    }
}

/// Rappels de WebRTC (sur son propre fil), traduits en événements simples.
private final class PeerObserver: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case gatheringComplete
        case connected
        case disconnected
    }

    private let onEvent: @Sendable (Event) -> Void

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected, .completed:
            onEvent(.connected)
        case .failed, .disconnected, .closed:
            onEvent(.disconnected)
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            onEvent(.gatheringComplete)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
```

`ios/Nacelle/Video/VideoView.swift` :

```swift
import SwiftUI
@preconcurrency import WebRTC

/// L'image de la caméra, sans rognage (spec § 7.2).
struct VideoView: UIViewRepresentable {
    let session: VideoSession

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        view.backgroundColor = .black
        session.attach(renderer: view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E "error:|Test run with|\*\* TEST"
```

Attendu : `Test run with 22 tests` … `passed`, puis `** TEST SUCCEEDED **`, sans ligne `error:`. Vérifier aussi qu'il n'y a aucun avertissement Swift : la même commande avec `| grep -c "warning:"` à la place du dernier filtre doit donner `0`.

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

```bash
git add ios/NacelleTests/SignalingTests.swift \
    ios/Nacelle/Video/Signaling.swift \
    ios/Nacelle/Video/VideoSession.swift \
    ios/Nacelle/Video/VideoView.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute la vidéo WebRTC de go2rtc

Réception vidéo seule, offre et réponse en une requête, attente des
candidats 2 s au plus, nouvel essai après 1, 2, 4 puis 8 s (spec § 7.2).

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 6 : Bandeau d'état, écran de pilotage et cycle de vie

Assemble l'app (spec § 7.2 à 7.4). `StatusBanner` applique l'ordre de priorité de la spec § 7.3. `AppModel` relie réglages, contrôle et vidéo ; joystick et zoom ne sont actifs que connecté, caméra présente et hors vie privée. `ControlScreen` : vidéo plein écran, joystick en bas à gauche, zoom vertical à droite, vie privée en haut à droite, bandeau en haut, réglages en haut à gauche ; les réglages s'ouvrent seuls au premier lancement. Retour haptique : impact léger au contact du joystick, retour « succès » à l'entrée et à la sortie de la vie privée. En arrière-plan : `move 0,0`, fermeture du WebSocket et de la vidéo ; au retour : reconnexion (et donc `takeControl`). Le point d'entrée provisoire de la tâche 2 est remplacé.

**Fichiers :**
- Créer : `ios/NacelleTests/StatusBannerTests.swift`
- Créer : `ios/Nacelle/Control/StatusBanner.swift`
- Créer : `ios/Nacelle/App/AppModel.swift`
- Créer : `ios/Nacelle/Control/JoystickView.swift`
- Créer : `ios/Nacelle/Control/ZoomSlider.swift`
- Créer : `ios/Nacelle/Settings/SettingsView.swift`
- Créer : `ios/Nacelle/Control/ControlScreen.swift`
- Remplacer : `ios/Nacelle/App/NacelleApp.swift`

**Interfaces :**
- Utilise : tout ce qui précède : `ConnectionSettings`, `SettingsStore`, `MainScheduler` (2), `JoystickMath` (3), `PTZClient`, `URLSessionWebSocketTransport` (4), `VideoSession`, `VideoView` (5).
- Produit :
  - `struct BannerInputs(macUnreachable:connecting:state:)`, `StatusBanner.text(for:) -> String?`
  - `@MainActor @Observable final class AppModel(store:ptz:video:)`, `AppModel.live()`, `activate()`, `deactivate()`, `bannerText`, `controlsEnabled`, `privacyToggleEnabled`
  - Vues : `JoystickView`, `ZoomSlider`, `SettingsView`, `ControlScreen` ; point d'entrée final `NacelleApp`

- [ ] **Étape 1 : Écrire les tests**

`ios/NacelleTests/StatusBannerTests.swift` :

```swift
import NacelleProtocol
import Testing
@testable import Nacelle

@Suite("Bandeau d'état")
struct StatusBannerTests {
    private func state(
        camera: CameraPresence = .connected,
        control: ControlState = .ready,
        privacy: Bool = false
    ) -> StateSnapshot {
        StateSnapshot(camera: camera, control: control, privacy: privacy, pan: 0, tilt: 0, zoom: 0, moving: false)
    }

    private func text(unreachable: Bool = false, connecting: Bool = false, _ state: StateSnapshot? = nil) -> String? {
        StatusBanner.text(for: BannerInputs(macUnreachable: unreachable, connecting: connecting, state: state))
    }

    @Test("Chaque condition a son texte")
    func texts() {
        #expect(text(unreachable: true) == "Mac injoignable : Tailscale est-il actif ?")
        #expect(text(state(camera: .absent)) == "Caméra débranchée")
        #expect(text(state(privacy: true)) == "Vie privée")
        #expect(text(state(control: .failed)) == "Suivi IA non coupé : les mouvements peuvent être contrés")
        #expect(text(state(control: .taking)) == "Prise en main…")
        #expect(text(connecting: true) == "Connexion…")
        #expect(text(state()) == nil)
    }

    @Test("Priorité : injoignable, débranchée, vie privée, suivi IA, prise en main, connexion")
    func priority() {
        let everything = state(camera: .absent, control: .taking, privacy: true)
        #expect(text(unreachable: true, connecting: true, everything) == "Mac injoignable : Tailscale est-il actif ?")
        #expect(text(connecting: true, everything) == "Caméra débranchée")
        #expect(text(connecting: true, state(control: .failed, privacy: true)) == "Vie privée")
        #expect(text(connecting: true, state(control: .failed)) == "Suivi IA non coupé : les mouvements peuvent être contrés")
        #expect(text(connecting: true, state(control: .taking)) == "Prise en main…")
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E "error:|Test run with|\*\* TEST"
```

Échec attendu : la compilation des tests échoue : `cannot find 'StatusBanner' in scope`.

- [ ] **Étape 3 : Écrire l'implémentation**

`ios/Nacelle/Control/StatusBanner.swift` :

```swift
import NacelleProtocol

/// Ce que le bandeau d'état doit connaître.
struct BannerInputs: Equatable {
    var macUnreachable: Bool
    /// WebSocket ou vidéo en cours de connexion.
    var connecting: Bool
    var state: StateSnapshot?
}

/// Texte du bandeau d'état (spec § 7.3). Ordre de priorité : Mac injoignable, caméra
/// débranchée, vie privée, suivi IA non coupé, prise en main, connexion.
enum StatusBanner {
    static func text(for inputs: BannerInputs) -> String? {
        if inputs.macUnreachable {
            return "Mac injoignable : Tailscale est-il actif ?"
        }
        if let state = inputs.state {
            if state.camera == .absent {
                return "Caméra débranchée"
            }
            if state.privacy {
                return "Vie privée"
            }
            if state.control == .failed {
                return "Suivi IA non coupé : les mouvements peuvent être contrés"
            }
            if state.control == .taking {
                return "Prise en main…"
            }
        }
        return inputs.connecting ? "Connexion…" : nil
    }
}
```

`ios/Nacelle/App/AppModel.swift` :

```swift
import Foundation
import NacelleProtocol
import Observation

/// L'état de l'app : réglages, contrôle de la nacelle et vidéo.
@MainActor
@Observable
final class AppModel {
    var settings: ConnectionSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            if isActive {
                deactivate()
                activate()
            }
        }
    }

    let ptz: PTZClient
    let video: VideoSession
    private(set) var isActive = false
    @ObservationIgnored private let store: SettingsStore

    init(store: SettingsStore, ptz: PTZClient, video: VideoSession) {
        self.store = store
        self.ptz = ptz
        self.video = video
        settings = store.load()
    }

    static func live() -> AppModel {
        let scheduler = MainScheduler()
        return AppModel(
            store: SettingsStore(),
            ptz: PTZClient(transport: URLSessionWebSocketTransport(), scheduler: scheduler),
            video: VideoSession(scheduler: scheduler)
        )
    }

    /// Premier plan : connexion au contrôle et à la vidéo (le contrôle envoie takeControl à l'ouverture).
    func activate() {
        guard let ptzdURL = settings.ptzdURL, let webRTCURL = settings.webRTCURL else { return }
        isActive = true
        ptz.start(url: ptzdURL)
        video.start(url: webRTCURL)
    }

    /// Arrière-plan : arrêt de la nacelle, fermeture du WebSocket et de la vidéo.
    func deactivate() {
        isActive = false
        ptz.stop()
        video.stop()
    }

    var bannerText: String? {
        StatusBanner.text(for: BannerInputs(
            macUnreachable: ptz.isUnreachable,
            connecting: ptz.link != .connected || video.phase != .playing,
            state: ptz.state
        ))
    }

    /// Joystick et zoom utilisables : connecté, caméra présente, hors vie privée.
    var controlsEnabled: Bool {
        guard ptz.link == .connected, let state = ptz.state else { return false }
        return state.camera == .connected && !state.privacy
    }

    /// Bouton vie privée utilisable : connecté et caméra présente.
    var privacyToggleEnabled: Bool {
        ptz.link == .connected && ptz.state?.camera == .connected
    }
}
```

`ios/Nacelle/Control/JoystickView.swift` :

```swift
import SwiftUI

/// Joystick : on tire le bouton au doigt ; il revient au centre au relâchement (spec § 7.2).
struct JoystickView: View {
    var isEnabled: Bool
    var onChange: (JoystickVector) -> Void
    var onRelease: () -> Void

    @State private var translation: CGSize = .zero
    @State private var isTouching = false
    @State private var touchCount = 0

    private let diameter: CGFloat = 150
    private let knobDiameter: CGFloat = 64

    private var radius: CGFloat {
        diameter / 2
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1.5))
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: knobDiameter, height: knobDiameter)
                .shadow(radius: 4)
                .offset(JoystickMath.knobOffset(translation: translation, radius: radius))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .opacity(isEnabled ? 1 : 0.4)
        .gesture(drag)
        .sensoryFeedback(.impact(weight: .light), trigger: touchCount)
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                release()
            }
        }
        .accessibilityLabel("Joystick de la nacelle")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEnabled else { return }
                if !isTouching {
                    isTouching = true
                    touchCount += 1
                }
                translation = value.translation
                onChange(JoystickMath.vector(translation: value.translation, radius: radius))
            }
            .onEnded { _ in
                release()
            }
    }

    private func release() {
        guard isTouching else { return }
        isTouching = false
        withAnimation(.spring(duration: 0.2)) {
            translation = .zero
        }
        onRelease()
    }
}
```

`ios/Nacelle/Control/ZoomSlider.swift` :

```swift
import SwiftUI

/// Curseur de zoom vertical : 0 en bas, 100 en haut (spec § 7.2). Envoie chaque nouvelle valeur entière.
struct ZoomSlider: View {
    /// Zoom connu de ptzd, affiché quand le doigt n'est pas posé.
    var value: Int?
    var isEnabled: Bool
    var onChange: (Int) -> Void

    @State private var dragValue: Int?

    private let height: CGFloat = 200
    private let width: CGFloat = 44

    private var shown: Int {
        dragValue ?? value ?? 0
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1.5))
            Capsule()
                .fill(.white.opacity(0.85))
                .frame(height: max(width, height * CGFloat(shown) / 100))
        }
        .frame(width: width, height: height)
        .overlay(alignment: .top) {
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.black.opacity(shown > 85 ? 0.7 : 0))
                .padding(.top, 10)
        }
        .contentShape(Capsule())
        .opacity(isEnabled ? 1 : 0.4)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard isEnabled else { return }
                    let fraction = 1 - gesture.location.y / height
                    let next = Int((min(max(fraction, 0), 1) * 100).rounded())
                    if next != dragValue {
                        dragValue = next
                        onChange(next)
                    }
                }
                .onEnded { _ in
                    dragValue = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Zoom")
        .accessibilityValue("\(shown)")
    }
}
```

`ios/Nacelle/Settings/SettingsView.swift` :

```swift
import SwiftUI

/// Réglages de connexion : saisis au premier lancement, modifiables ensuite.
struct SettingsView: View {
    @Binding var settings: ConnectionSettings
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ConnectionSettings()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("mon-mac.tailnet.ts.net", text: $draft.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Mac")
                } footer: {
                    Text("Le nom Tailscale du Mac (MagicDNS) ou son adresse IPv4 Tailscale. Tailscale doit être actif sur l'iPhone.")
                }
                Section("Vidéo (go2rtc)") {
                    LabeledContent("Port") {
                        TextField("1984", value: $draft.go2rtcPort, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Flux") {
                        TextField("obsbot", text: $draft.streamName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section("Nacelle (ptzd)") {
                    LabeledContent("Port") {
                        TextField("1985", value: $draft.ptzdPort, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        settings = draft
                        dismiss()
                    }
                    .disabled(!draft.isComplete)
                }
            }
        }
        .onAppear {
            draft = settings
        }
    }
}
```

`ios/Nacelle/Control/ControlScreen.swift` :

```swift
import SwiftUI

/// L'écran unique : la vidéo en plein écran, les commandes par-dessus (spec § 7.2 et § 7.3).
struct ControlScreen: View {
    @Bindable var model: AppModel
    @State private var showSettings = false

    private var privacyOn: Bool {
        model.ptz.state?.privacy ?? false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoView(session: model.video)
                .ignoresSafeArea()
            VStack {
                HStack(alignment: .top) {
                    settingsButton
                    Spacer(minLength: 12)
                    if let text = model.bannerText {
                        BannerView(text: text)
                    }
                    Spacer(minLength: 12)
                    privacyButton
                }
                Spacer()
                HStack(alignment: .bottom) {
                    JoystickView(
                        isEnabled: model.controlsEnabled,
                        onChange: { model.ptz.setJoystick($0) },
                        onRelease: { model.ptz.setJoystick(.zero) }
                    )
                    Spacer()
                    ZoomSlider(
                        value: model.ptz.state?.zoom,
                        isEnabled: model.controlsEnabled,
                        onChange: { model.ptz.setZoom($0) }
                    )
                }
            }
            .padding(20)
        }
        .sensoryFeedback(.success, trigger: privacyOn)
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: $model.settings)
        }
        .onAppear {
            if !model.settings.isComplete {
                showSettings = true
            }
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Réglages")
    }

    private var privacyButton: some View {
        Button {
            model.ptz.setPrivacy(!privacyOn)
        } label: {
            Image(systemName: privacyOn ? "eye.slash.fill" : "eye.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(privacyOn ? AnyShapeStyle(.red.opacity(0.8)) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
        .foregroundStyle(.white)
        .disabled(!model.privacyToggleEnabled)
        .opacity(model.privacyToggleEnabled ? 1 : 0.4)
        .accessibilityLabel(privacyOn ? "Quitter la vie privée" : "Vie privée")
    }
}

/// Le bandeau d'état, en haut de l'écran.
private struct BannerView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
```

Remplacer tout le contenu de `ios/Nacelle/App/NacelleApp.swift` :

```swift
import SwiftUI

@main
struct NacelleApp: App {
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ControlScreen(model: model)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // Spec § 7.4 : on coupe tout en arrière-plan, on reconnecte au retour.
            switch phase {
            case .active:
                model.activate()
            case .background:
                model.deactivate()
            default:
                break
            }
        }
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E "error:|Test run with|\*\* TEST"
```

Attendu : `Test run with 24 tests` … `passed`, puis `** TEST SUCCEEDED **`, sans ligne `error:`. Vérifier aussi qu'il n'y a aucun avertissement Swift : la même commande avec `| grep -c "warning:"` à la place du dernier filtre doit donner `0`.

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

```bash
git add ios/NacelleTests/StatusBannerTests.swift \
    ios/Nacelle/Control/StatusBanner.swift \
    ios/Nacelle/App/AppModel.swift \
    ios/Nacelle/Control/JoystickView.swift \
    ios/Nacelle/Control/ZoomSlider.swift \
    ios/Nacelle/Settings/SettingsView.swift \
    ios/Nacelle/Control/ControlScreen.swift \
    ios/Nacelle/App/NacelleApp.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Assemble l'app : bandeau d'état, écran de pilotage et cycle de vie

Bandeau selon la priorité de la spec § 7.3, commandes grisées hors connexion
et en vie privée, coupure en arrière-plan et reconnexion au retour (§ 7.4).

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 7 : Vérification dans le simulateur, contre le vrai service

L'app assemblée, dans le simulateur, parle au `ptzd` installé (127.0.0.1:1985) et à go2rtc (127.0.0.1:1984) : vraie vidéo, vraie caméra. Rien à commiter : cette tâche produit un compte rendu.

Les gestes passent par l'outil de contrôle du simulateur (`touch_path`, `tap`, `button HOME`) s'il est disponible ; sinon, demander à Majid de les faire à la souris dans l'app Simulator. Coordonnées en points pour un iPhone 17 (402 × 874) : centre du joystick (95, 745), curseur de zoom x = 360 de y = 812 (bas) à y = 620 (haut), bouton vie privée (360, 104).

- [ ] **Étape 1 : Compiler pour le simulateur et démarrer l'iPhone 17 sous iOS 27**

```bash
cd ios && xcodegen -q && xcodebuild build -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | tail -1
```

```bash
UDID=$(xcrun simctl list devices available -j | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next(x['udid'] for k,v in d.items() if k.endswith('iOS-27-0') for x in v if x['name']=='iPhone 17'))"); echo "$UDID" > ios/.build/simulator-udid; xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b | tail -1
```

Attendu : `** BUILD SUCCEEDED **`, puis le simulateur démarré.

- [ ] **Étape 2 : Installer, précharger les réglages locaux, lancer**

```bash
UDID=$(cat ios/.build/simulator-udid); xcrun simctl install "$UDID" ios/.build/Build/Products/Debug-iphonesimulator/Nacelle.app && HEX=$(printf '%s' '{"host":"127.0.0.1","go2rtcPort":1984,"streamName":"obsbot","ptzdPort":1985}' | xxd -p | tr -d '\n') && xcrun simctl spawn "$UDID" defaults write io.github.djoko-cli.nacelle connectionSettings -data "$HEX" && echo "go2rtc=$(pgrep -x go2rtc) coreaudiod=$(pgrep -x coreaudiod)" && xcrun simctl launch "$UDID" io.github.djoko-cli.nacelle
```

Attendu, au bout de 10 s environ (capture d'écran) : l'image en direct de la caméra, sans rognage ; aucun bandeau, ou « Prise en main… » pendant quelques secondes. `tail -3 ~/Library/Logs/obsbot-nacelle/ptzd.log` ne montre pas d'échec de `obsbot-ai-off` (ou bien un seul échec suivi du nouvel essai réussi).

- [ ] **Étape 3 : Joystick et zoom (prévenir Majid : la caméra bouge 1 à 2 s)**

Glisser le joystick du centre vers la droite (de (95, 745) à (140, 745)), tenir environ 1 s, relâcher. Puis glisser le curseur de zoom de (360, 812) à (360, 730).

```bash
sleep 2; ~/Library/Application\ Support/ObsbotNacelle/bin/ptzd uvc get
```

Attendu : l'image a tourné vers la droite et s'est arrêtée au relâchement (le pan relu a diminué) ; le bouton du joystick est revenu au centre ; le zoom relu vaut environ 45.

- [ ] **Étape 4 : Vie privée (la caméra bouge)**

Toucher le bouton vie privée (360, 104), attendre 4 s, capture d'écran ; puis le toucher de nouveau et attendre 4 s.

Attendu, en vie privée : image réduite à un aplat sans rien d'identifiable, bandeau « Vie privée », bouton rouge, joystick et zoom grisés ; `ptzd uvc get` relit un tilt de -69 ou -70°. Après la sortie : l'image et la position d'avant reviennent, plus de bandeau.

- [ ] **Étape 5 : Arrière-plan puis retour**

Appuyer sur Accueil, attendre 3 s :

```bash
echo "ptzd: $(lsof -nP -iTCP:1985 -sTCP:ESTABLISHED 2>/dev/null | grep -c ptzd) connexion(s)"; echo "go2rtc: $(curl -s 'http://127.0.0.1:1984/api/streams?src=obsbot' | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("consumers") or []))') lecteur(s)"
```

Attendu : `0` et `0`. Puis relancer l'app (`xcrun simctl launch "$(cat ios/.build/simulator-udid)" io.github.djoko-cli.nacelle`), attendre 10 s, relancer la même commande : `1` et `1`, l'image revient.

- [ ] **Étape 6 : Santé et remise en place**

```bash
echo "go2rtc=$(pgrep -x go2rtc) coreaudiod=$(pgrep -x coreaudiod)"
```

Attendu : les mêmes PID qu'à l'étape 2. Remettre la caméra où elle était (`ptzd uvc pt <pan> <tilt>`, `ptzd uvc zoom <zoom>` avec les valeurs relues avant l'étape 3), puis mettre l'app en arrière-plan.

---

### Tâche 8 : Installation sur l'iPhone, essai de bout en bout en 4G, README

Spec § 8, « De bout en bout sur l'iPhone en 4G ». Plusieurs étapes demandent Majid : elles sont marquées.

**Fichiers :**
- Créer (non versionné) : `ios/Config/Local.xcconfig`
- Remplacer : `README.md`

- [ ] **Étape 1 : Régler l'équipe de signature (fichier local, jamais commité)**

```bash
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline | grep organizationalUnitName
```

Puis, avec l'identifiant affiché :

```bash
printf 'DEVELOPMENT_TEAM = %s\n' <identifiant> > ios/Config/Local.xcconfig && git check-ignore -v ios/Config/Local.xcconfig
```

Attendu : la ligne de `.gitignore` qui ignore le fichier.

- [ ] **Étape 2 : Compiler, installer et lancer sur l'iPhone**

`<UDID>` : l'identifiant de l'iPhone de Majid dans `xcrun devicectl list devices` (« iPhone 14 Pro », état `available (paired)`).

```bash
cd ios && xcodegen -q && cd .. && xcodebuild build -project ios/Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS,id=<UDID>' -derivedDataPath ios/.build -allowProvisioningUpdates 2>&1 | tail -2
```

```bash
xcrun devicectl device install app --device <UDID> ios/.build/Build/Products/Debug-iphoneos/Nacelle.app && xcrun devicectl device process launch --device <UDID> io.github.djoko-cli.nacelle
```

Si la compilation se plaint de la signature, ouvrir une fois `ios/Nacelle.xcodeproj` dans Xcode, onglet « Signing & Capabilities », et vérifier l'équipe (Majid). Si le lancement est refusé : **Majid** fait confiance au développeur sur l'iPhone (Réglages › Général › VPN et gestion de l'appareil), puis relancer.

- [ ] **Étape 3 : Premier lancement (Majid)**

Sur l'iPhone, **Majid** : Tailscale actif, **Wi-Fi coupé** (4G/5G). Dans les réglages de l'app, saisir le nom Tailscale du Mac, que donne cette commande sur le Mac (à lui communiquer dans la conversation, jamais dans le dépôt) :

```bash
tailscale status --self --json | python3 -c "import json,sys; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))"
```

À la première connexion, le Mac peut demander s'il faut autoriser `ptzd` à accepter des connexions entrantes : **Majid** répond « Autoriser ». L'iPhone peut demander l'accès au réseau local : réponse au choix de Majid (sans effet en 4G).

- [ ] **Étape 4 : Essai de bout en bout en 4G (Majid, la caméra bouge)**

Cocher avec Majid, en notant le résultat de chaque point :
1. la vidéo s'affiche en moins de 10 s, avec un retard faible ;
2. le joystick tourne la caméra dans le sens du doigt et s'arrête au relâchement ;
3. le zoom suit le curseur ;
4. la vie privée tourne l'objectif vers le bas (aplat sans rien d'identifiable), grise les commandes, puis rétablit la vue ;
5. passer l'app en arrière-plan 10 s puis revenir : la vidéo et les commandes reviennent seules ;
6. couper Tailscale sur l'iPhone : le bandeau affiche « Mac injoignable : Tailscale est-il actif ? » ; le rallumer : tout revient ;
7. tourner l'iPhone en paysage : la vidéo occupe l'écran sans être rognée, et le joystick, le zoom, le bouton vie privée et le bandeau restent accessibles (spec § 7.2).

Pendant l'essai, sur le Mac : `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log` ; à la fin, les PID de go2rtc et de coreaudiod doivent être inchangés.

- [ ] **Étape 5 : README**

Remplacer tout le contenu de `README.md` :

````markdown
# OBSBOT Nacelle

Piloter à distance la nacelle d'une OBSBOT Tiny 2 depuis l'iPhone.

La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](https://github.com/AlexxIT/go2rtc), et vers HomeKit via Homebridge. HomeKit ne sait pas piloter un pan/tilt/zoom : ce projet ajoute ce qui manque.

> Projet personnel, sans lien avec OBSBOT.

## Statut

- **Côté Mac** : `ptzd` et `obsbot-ai-off` s'installent avec `scripts/install-mac.sh` (voir plus bas).
- **App iOS** : s'installe depuis Xcode sur l'iPhone (voir « App iOS » plus bas).

Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).

## Architecture

```
iPhone : app SwiftUI                         Mac (celui de go2rtc)
┌───────────────────────────┐            ┌──────────────────────────────────┐
│ Vidéo WebRTC  ────────────┼─ offre ───▶│ go2rtc (inchangé)                │
│                           │◀─ images ──│   └─ ffmpeg ◀── Tiny 2 (USB)     │
│ Joystick, zoom,           │            │                                  │
│ vie privée  ──────────────┼─ WebSocket▶│ ptzd                             │
│                           │◀─ état ────│   ├─ commandes UVC ──▶ Tiny 2    │
│                           │            │   └─ lance obsbot-ai-off (SDK)   │
└───────────────────────────┘            └──────────────────────────────────┘
                 tout passe par Tailscale, à la maison comme dehors
```

- **`ptzd`** : un service macOS en Swift, lancé par launchd. C'est le seul à envoyer des commandes de nacelle à la caméra, en UVC. Il ne touche jamais au flux vidéo. Il écoute sur l'adresse Tailscale du Mac et sur 127.0.0.1, jamais sur le réseau local.
- **`obsbot-ai-off`** : un petit utilitaire qui coupe le suivi IA de la caméra avec le SDK OBSBOT, puis se termine. `ptzd` le lance à chaque prise en main.
- **go2rtc** : la vidéo arrive dans l'app directement en WebRTC. Aucun changement de configuration n'est nécessaire.

## Installer le côté Mac

Prérequis :

- un Mac Apple Silicon sous macOS 15 ou plus récent, avec Xcode ;
- Tailscale actif sur le Mac ;
- le SDK OBSBOT, à demander sur [obsbot.com/sdk](https://www.obsbot.com/sdk), décompressé dans `vendor/obsbot-sdk/`. Il n'est pas versionné : sa licence n'en autorise pas la redistribution ;
- OBSBOT Center fermé : ouvert, il fausse la relecture du tilt.

Si macOS a mis la bibliothèque du SDK en quarantaine, l'autoriser d'abord, depuis la racine du dépôt :

```bash
xattr -d com.apple.quarantine vendor/obsbot-sdk/macos/arm64-release/libdev.dylib
```

Puis installer :

```bash
scripts/install-mac.sh
```

Le script compile `ptzd` et `obsbot-ai-off`, les installe dans `~/Library/Application Support/ObsbotNacelle/`, crée `config.json` avec l'adresse Tailscale du Mac, puis charge l'agent launchd `io.github.djoko-cli.obsbot-nacelle.ptzd`.

À la première connexion de l'iPhone, macOS peut demander s'il faut autoriser `ptzd` à accepter des connexions entrantes : répondre **Autoriser**. La question peut revenir après une réinstallation, car le binaire change.

## Réglages (`config.json`)

| Clé | Rôle | Défaut |
|---|---|---|
| `listenAddress` | Adresse IPv4 Tailscale du Mac | obligatoire |
| `port` | Port WebSocket | 1985 |
| `panMaxSpeed`, `tiltMaxSpeed` | Vitesses UVC maximales (pan 1–80, tilt 1–120) | 40, 60 |
| `panDirection`, `tiltDirection` | Sens de chaque axe, +1 ou -1 | +1, +1 |
| `aiOffPath` | Chemin de `obsbot-ai-off`, relatif au dossier d'installation | `bin/obsbot-ai-off` |

Après une modification, relancer le service :

```bash
launchctl kickstart -k gui/$(id -u)/io.github.djoko-cli.obsbot-nacelle.ptzd
```

## Diagnostic

| Besoin | Commande |
|---|---|
| Journal du service | `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log` |
| Sortie du SDK | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai-off.log` |
| Lire la position de la caméra | `~/Library/Application\ Support/ObsbotNacelle/bin/ptzd uvc get` |
| Dialoguer avec le service | `swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"takeControl"}' wait 6` |

Le Mac ne peut pas se joindre lui-même par son adresse Tailscale : en local, passer par 127.0.0.1.

## App iOS

Prérequis : Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), un identifiant Apple (un compte gratuit suffit), Tailscale sur l'iPhone, et le côté Mac installé.

1. Indiquer l'équipe de signature dans un réglage local, non versionné. Son identifiant est le champ OU des certificats « Apple Development » du trousseau :

   ```bash
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline | grep organizationalUnitName
   ```

   ```bash
   printf 'DEVELOPMENT_TEAM = %s\n' <identifiant> > ios/Config/Local.xcconfig
   ```

2. Générer le projet, puis compiler et installer sur l'iPhone branché ou appairé. `<UDID>` est son identifiant, donné par `xcrun devicectl list devices` :

   ```bash
   cd ios && xcodegen
   ```

   ```bash
   xcodebuild build -project ios/Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS,id=<UDID>' -derivedDataPath ios/.build -allowProvisioningUpdates
   ```

   ```bash
   xcrun devicectl device install app --device <UDID> ios/.build/Build/Products/Debug-iphoneos/Nacelle.app
   ```

3. Au premier lancement, iOS demande de faire confiance au développeur : Réglages › Général › VPN et gestion de l'appareil.
4. Dans l'app, saisir le nom Tailscale du Mac (`tailscale status --self` sur le Mac). Les ports par défaut (1984 et 1985) et le flux `obsbot` conviennent.

Avec un compte Apple gratuit, l'app expire au bout de 7 jours : refaire l'étape 2.

Tests : `cd ios && xcodegen && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build`.

## Désinstaller

```bash
launchctl bootout gui/$(id -u)/io.github.djoko-cli.obsbot-nacelle.ptzd
```

```bash
rm ~/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.ptzd.plist
```

```bash
rm -r ~/Library/Application\ Support/ObsbotNacelle ~/Library/Logs/obsbot-nacelle
```

## Contenu

| Chemin | Rôle |
|---|---|
| `Packages/NacelleProtocol/` | Messages échangés entre l'app et `ptzd`, partagés par les deux |
| `mac/ptzd/` | Le service : logique (`PTZCore`), accès USB (`CUVC`, `UVCCamera`), serveur WebSocket (`PTZServer`) |
| `mac/ai-off/` | L'utilitaire `obsbot-ai-off` (C++, demande le SDK en local) |
| `mac/launchd/` | Modèle du plist de l'agent launchd |
| `mac/tools/` | Client WebSocket de test |
| `ios/` | L'app iOS : `project.yml` (xcodegen), sources et tests |
| `scripts/install-mac.sh` | Installation sur le Mac |
| `docs/` | Spec, plans et tests de faisabilité |
| `spike/` | Sondes **jetables** des tests de faisabilité |

## Licence

MIT. Voir [LICENSE](LICENSE).
````

- [ ] **Étape 6 : Vérifier l'absence de données locales, commiter, pousser**

```bash
git add README.md
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
README : installer l'app iOS

Projet xcodegen, équipe de signature locale, installation sur l'iPhone,
réinstallation tous les 7 jours avec un compte gratuit.

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

- [ ] **Étape 7 : Rendre compte à Majid**

Le résultat de chaque point de l'étape 4, les éventuelles autorisations accordées, et le rappel : avec un compte gratuit, réinstaller l'app tous les 7 jours (README, « App iOS », étape 2). Proposer de valider l'amendement A3 pour mettre la spec à jour.
