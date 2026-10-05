# Plan d'implémentation : côté Mac (protocole, ptzd, obsbot-ai-off)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectif :** livrer le service macOS `ptzd`, qui pilote la nacelle de la Tiny 2 en UVC et dialogue en WebSocket avec l'app, et l'utilitaire `obsbot-ai-off`, qui coupe le suivi IA, installés et vérifiés sur le Mac de Majid.

**Architecture :** un paquet Swift partagé (`NacelleProtocol`) définit les messages. Le paquet `ptzd` sépare la logique testable sans matériel (`PTZCore`, derrière des protocoles caméra, horloge, stockage et lanceur), l'accès USB (`CUVC` en C, `UVCCamera`), le serveur (`PTZServer`, Network.framework) et l'exécutable. `obsbot-ai-off` est un petit programme C++ lié au SDK OBSBOT, lancé à la demande dans un processus séparé.

**Technologies :** Swift 6 (concurrence stricte), Swift Testing, SwiftPM, IOKit, Network.framework, C, C++17, SDK OBSBOT libdev 2.1.0_8, launchd.

**Spec :** [docs/superpowers/specs/2026-10-05-nacelle-design.md](../specs/2026-10-05-nacelle-design.md), à lire avec ce plan. Résultats des tests de faisabilité : [docs/spike/2026-10-05-faisabilite.md](../../spike/2026-10-05-faisabilite.md).

Un second plan couvrira l'app iOS ; il s'appuiera sur `NacelleProtocol` et sur le service installé ici.

## Contraintes globales

- **Plateformes :** paquets en `.macOS(.v15)` (plus `.iOS(.v18)` pour `NacelleProtocol`) ; Mac Apple Silicon sous macOS 27 ; Xcode 27 (Swift 6.4).
- **Swift :** `swift-tools-version: 6.0`, mode de langage Swift 6 (concurrence stricte), aucune dépendance Swift externe.
- **Tests :** Swift Testing (`import Testing`, `@Test`, `#expect`), lancés par `swift test`.
- **Langue :** identifiants en anglais ; commentaires, journaux et messages d'erreur en français.
- **SDK OBSBOT :** uniquement dans `vendor/obsbot-sdk/`, ignoré par git, jamais commité (pas de licence de redistribution). Majid a déjà retiré l'attribut de quarantaine de `libdev.dylib` (constaté le 2026-10-05).
- **Dépôt public :** aucune adresse IP (hors 127.0.0.1 et 0.0.0.0), aucun nom `*.ts.net`, aucun chemin personnel, aucune image de la caméra dans un fichier commité. La vérification fait partie de chaque étape de commit.
- **Commits :** commit et push à la fin de chaque tâche (autorisés par Majid pour ce dépôt) ; message en français, terminé par la ligne `Co-Authored-By`.
- **go2rtc :** `ptzd` n'utilise jamais AVFoundation ni CoreAudio, et ne touche ni au processus go2rtc ni à sa configuration.
- **Essais sur la caméra :** OBSBOT Center fermé. Prévenir Majid avant toute commande qui fait bouger la caméra : HomeKit la montre en direct.
- **Course de la nacelle :** la Tiny 2 ignore en silence un ordre absolu hors de sa course réelle (tilt à -90° ou +89°), en renvoyant un succès. Ne jamais envoyer d'ordre absolu sans passer par les bornes de `UVCPayload` (pan ±130°, tilt de -80° à +70°).
- **Essais réseau en local :** le Mac ne peut pas joindre un `NWListener` par sa propre adresse Tailscale (constaté le 2026-10-05 ; l'iPhone, lui, y arrive). En local, toujours passer par 127.0.0.1.
- **Installation réelle (tâche 14) :** uniquement après l'accord explicite de Majid, donné dans la conversation.

## Amendements à la spec, proposés avec ce plan

La spec sera mise à jour quand Majid aura validé ces deux amendements, tous deux issus de vérifications faites en écrivant ce plan.

**A1 : écoute aussi sur 127.0.0.1.** La spec (§ 6.1 et § 6.10) prévoit une écoute sur la seule adresse Tailscale. Or le Mac ne peut pas joindre `ptzd` par cette adresse : le service installé ne pourrait être vérifié que depuis l'iPhone. `ptzd` écoute donc aussi sur 127.0.0.1, jamais sur 0.0.0.0 ni sur l'adresse du réseau local. Aucune exposition nouvelle : un programme local a de toute façon accès à l'USB.

**A2 : vie privée à -70°, ordres bornés à la course réelle.** La spec (§ 2 et § 6.5) prévoit un tilt à -90°. Mesuré le 2026-10-05 au soir : la caméra **ignore** un ordre à -90° (et à +89°), en renvoyant un succès ; elle obéit exactement à -70°. Le mode vie privée tel que spécifié n'aurait donc rien fait. Il passe à -70°, vérifié à l'image (aplat gris, y compris pendant une prise en main et après un redémarrage du service), et tous les ordres absolus sont bornés à pan ±130°, tilt de -80° à +70°. Détails : section « Correctif » de [docs/spike/2026-10-05-faisabilite.md](../../spike/2026-10-05-faisabilite.md).

## Carte des fichiers

| Fichier | Rôle | Tâche |
|---|---|---|
| `Packages/NacelleProtocol/Package.swift` | Manifeste du paquet partagé | 1 |
| `Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift` | Types des messages et de l'état | 1 |
| `Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift` | JSON avec champ `type`, bornes, `null` | 1 |
| `mac/ptzd/Package.swift` | Manifeste de `ptzd`, complété aux tâches 9, 10 et 11 | 2 |
| `mac/ptzd/Sources/PTZCore/CameraDevice.swift` | Protocole caméra, commandes, erreurs, `ClientID`, `LogSink` | 2 |
| `mac/ptzd/Sources/PTZCore/Scheduler.swift` | Horloge et minuteries injectables | 2 |
| `mac/ptzd/Sources/PTZCore/SpeedCurve.swift` | Joystick → vitesse UVC | 2 |
| `mac/ptzd/Sources/PTZCore/MotionDriver.swift` | Mouvement en vitesse, arrêt automatique | 3 |
| `mac/ptzd/Sources/PTZCore/ZoomDriver.swift` | Zoom borné et regroupé | 4 |
| `mac/ptzd/Sources/PTZCore/StateStore.swift` | `state.json` | 5 |
| `mac/ptzd/Sources/PTZCore/PrivacyKeeper.swift` | Vie privée | 5 |
| `mac/ptzd/Sources/PTZCore/AIOffRunner.swift` | Lancement de `obsbot-ai-off` | 6 |
| `mac/ptzd/Sources/PTZCore/ControlTaker.swift` | Prise en main | 6 |
| `mac/ptzd/Sources/PTZCore/PTZController.swift` | Point d'entrée de la logique | 7 |
| `mac/ptzd/Sources/PTZCore/PTZConfig.swift` | `config.json` | 8 |
| `mac/ptzd/Sources/CUVC/include/cuvc.h`, `cuvc.c` | Requêtes UVC en C (IOKit) | 9 |
| `mac/ptzd/Sources/UVCCamera/*.swift` | Caméra réelle, branchements, encodage | 9 |
| `mac/ptzd/Sources/PTZServer/WebSocketServer.swift` | Serveur WebSocket | 10 |
| `mac/ptzd/Sources/ptzd/PTZDaemon.swift` | Point d'entrée du service | 11 |
| `mac/ptzd/Sources/ptzd/UVCDebugCommand.swift` | `ptzd uvc …` pour l'étalonnage | 11 |
| `mac/ptzd/Tests/…` | Tests et faux objets, un fichier par sujet | 2 à 10 |
| `mac/ai-off/main.cpp`, `build.sh` | Utilitaire SDK et sa compilation | 12 |
| `mac/tools/nacelle-ws.swift` | Client WebSocket de test | 13 |
| `mac/launchd/io.github.djoko-cli.obsbot-nacelle.ptzd.plist` | Modèle de l'agent launchd | 14 |
| `scripts/install-mac.sh` | Installation | 14 |
| `README.md` | Mise à jour : installation, réglages, diagnostic | 14 |

## Lire les étapes

- Toutes les commandes partent de la **racine du dépôt** (`~/Dev/obsbot-nacelle`).
- Le code de ce plan a été compilé et testé dans un prototype le 2026-10-05 (Swift 6.4, Xcode 27, macOS 27, vraie caméra), et les tâches 1 à 10 ont été rejouées dans un dossier vierge : **recopier les fichiers tels quels**.
- « Échec attendu » à l'étape 2 : en Swift, un test qui référence un type absent ne compile pas ; c'est l'échec recherché.
- Le compte de tests attendu se lit sur les lignes `Test run with N tests` (une par cible de tests).

---

### Tâche 1 : Paquet partagé NacelleProtocol

Les messages de la spec § 5, définis une seule fois et partagés par `ptzd` et l'app. JSON avec un champ `type`, valeurs bornées au décodage, valeurs inconnues écrites `null`.

**Fichiers :**
- Créer : `Packages/NacelleProtocol/Package.swift`
- Créer : `Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift`
- Créer : `Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift`
- Créer : `Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift`

**Interfaces :**
- Utilise : rien.
- Produit :
  - `ClientMessage` : `.takeControl`, `.move(pan: Double, tilt: Double)`, `.zoom(value: Int)`, `.privacy(on: Bool)`
  - `ServerMessage` : `.state(StateSnapshot)`, `.error(code: ErrorCode, message: String)`
  - `StateSnapshot(camera: CameraPresence, control: ControlState, privacy: Bool, pan: Double?, tilt: Double?, zoom: Int?, moving: Bool)`
  - `CameraPresence` (`.connected`, `.absent`), `ControlState` (`.idle`, `.taking`, `.ready`, `.failed`), `ErrorCode` (`.privacyActive`, `.cameraAbsent`, `.uvcFailed`, `.badMessage`)
  - `NacelleCodec.encode(_: ClientMessage) throws -> String`, `NacelleCodec.encode(_: ServerMessage) throws -> String`, `NacelleCodec.decodeClient(_: String) throws -> ClientMessage`, `NacelleCodec.decodeServer(_: String) throws -> ServerMessage`
  - `NacelleProtocolError.unknownType(String)`

- [ ] **Étape 1 : Écrire les tests**

`Packages/NacelleProtocol/Package.swift` :

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NacelleProtocol",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "NacelleProtocol", targets: ["NacelleProtocol"]),
    ],
    targets: [
        .target(name: "NacelleProtocol"),
        .testTarget(name: "NacelleProtocolTests", dependencies: ["NacelleProtocol"]),
    ]
)
```

`Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift` :

```swift
import Testing
@testable import NacelleProtocol

@Suite("Messages de l'app vers ptzd")
struct ClientMessageTests {
    @Test("Aller-retour de chaque message", arguments: [
        ClientMessage.takeControl,
        .move(pan: 0.5, tilt: -0.25),
        .zoom(value: 33),
        .privacy(on: true),
        .privacy(on: false),
    ])
    func roundTrip(_ message: ClientMessage) throws {
        let text = try NacelleCodec.encode(message)
        #expect(try NacelleCodec.decodeClient(text) == message)
    }

    @Test("takeControl s'écrit avec son seul type")
    func takeControlFormat() throws {
        #expect(try NacelleCodec.encode(ClientMessage.takeControl) == #"{"type":"takeControl"}"#)
    }

    @Test("move est borné à -1…1")
    func moveIsClamped() throws {
        let message = try NacelleCodec.decodeClient(#"{"type":"move","pan":3,"tilt":-7}"#)
        #expect(message == .move(pan: 1, tilt: -1))
    }

    @Test("zoom est borné à 0…100")
    func zoomIsClamped() throws {
        #expect(try NacelleCodec.decodeClient(#"{"type":"zoom","value":250}"#) == .zoom(value: 100))
        #expect(try NacelleCodec.decodeClient(#"{"type":"zoom","value":-5}"#) == .zoom(value: 0))
    }

    @Test("Un type inconnu est rejeté")
    func unknownTypeIsRejected() {
        #expect(throws: NacelleProtocolError.unknownType("dance")) {
            try NacelleCodec.decodeClient(#"{"type":"dance"}"#)
        }
    }

    @Test("Un message mal formé est rejeté")
    func malformedIsRejected() {
        #expect(throws: (any Error).self) { try NacelleCodec.decodeClient("pas du json") }
        #expect(throws: (any Error).self) { try NacelleCodec.decodeClient(#"{"type":"move","pan":0.5}"#) }
        #expect(throws: (any Error).self) { try NacelleCodec.decodeClient(#"{"type":"zoom","value":"fort"}"#) }
    }
}

@Suite("Messages de ptzd vers l'app")
struct ServerMessageTests {
    static let known = StateSnapshot(
        camera: .connected, control: .ready, privacy: false,
        pan: 2, tilt: -1, zoom: 33, moving: true
    )
    static let unknown = StateSnapshot(
        camera: .absent, control: .idle, privacy: true,
        pan: nil, tilt: nil, zoom: nil, moving: false
    )

    @Test("Aller-retour de chaque message", arguments: [
        ServerMessage.state(known),
        .state(unknown),
        .error(code: .privacyActive, message: "Vie privée active : mouvement refusé."),
    ])
    func roundTrip(_ message: ServerMessage) throws {
        let text = try NacelleCodec.encode(message)
        #expect(try NacelleCodec.decodeServer(text) == message)
    }

    @Test("Les valeurs inconnues sont écrites null")
    func unknownValuesAreNull() throws {
        let text = try NacelleCodec.encode(ServerMessage.state(Self.unknown))
        #expect(text == #"{"camera":"absent","control":"idle","moving":false,"pan":null,"privacy":true,"tilt":null,"type":"state","zoom":null}"#)
    }

    @Test("Un type inconnu est rejeté")
    func unknownTypeIsRejected() {
        #expect(throws: NacelleProtocolError.unknownType("hello")) {
            try NacelleCodec.decodeServer(#"{"type":"hello"}"#)
        }
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd Packages/NacelleProtocol && swift test
```

Échec attendu : la compilation échoue : la cible `NacelleProtocol` n'a pas encore de sources (`Source files for target NacelleProtocol should be located under…`).

- [ ] **Étape 3 : Écrire l'implémentation**

`Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift` :

```swift
/// Message de l'app vers ptzd (spec § 5).
public enum ClientMessage: Equatable, Sendable {
    /// Coupe le suivi IA de la caméra (spec § 6.4).
    case takeControl
    /// Consigne de vitesse, de -1 à 1 sur chaque axe. 0,0 arrête le mouvement.
    case move(pan: Double, tilt: Double)
    /// Zoom absolu, de 0 à 100.
    case zoom(value: Int)
    /// Entre en vie privée (true) ou en sort (false).
    case privacy(on: Bool)
}

/// Présence de la caméra côté Mac.
public enum CameraPresence: String, Codable, Sendable {
    case connected
    case absent
}

/// Avancement de la prise en main, c'est-à-dire de la coupure du suivi IA.
public enum ControlState: String, Codable, Sendable {
    case idle
    case taking
    case ready
    case failed
}

/// Codes d'erreur renvoyés à l'app.
public enum ErrorCode: String, Codable, Sendable {
    case privacyActive
    case cameraAbsent
    case uvcFailed
    case badMessage
}

/// État complet publié par ptzd.
public struct StateSnapshot: Equatable, Sendable {
    public var camera: CameraPresence
    public var control: ControlState
    public var privacy: Bool
    /// Degrés, ou nil si inconnus.
    public var pan: Double?
    /// Degrés, ou nil si inconnus.
    public var tilt: Double?
    /// De 0 à 100, ou nil si inconnu.
    public var zoom: Int?
    public var moving: Bool

    public init(
        camera: CameraPresence,
        control: ControlState,
        privacy: Bool,
        pan: Double?,
        tilt: Double?,
        zoom: Int?,
        moving: Bool
    ) {
        self.camera = camera
        self.control = control
        self.privacy = privacy
        self.pan = pan
        self.tilt = tilt
        self.zoom = zoom
        self.moving = moving
    }
}

/// Message de ptzd vers l'app.
public enum ServerMessage: Equatable, Sendable {
    case state(StateSnapshot)
    case error(code: ErrorCode, message: String)
}
```

`Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift` :

```swift
import Foundation

public enum NacelleProtocolError: Error, Equatable {
    case unknownType(String)
}

/// Encodage JSON des messages : un objet par trame WebSocket texte, avec un champ `type`.
public enum NacelleCodec {
    public static func encode(_ message: ClientMessage) throws -> String {
        try string(from: message)
    }

    public static func encode(_ message: ServerMessage) throws -> String {
        try string(from: message)
    }

    public static func decodeClient(_ text: String) throws -> ClientMessage {
        try JSONDecoder().decode(ClientMessage.self, from: Data(text.utf8))
    }

    public static func decodeServer(_ text: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8))
    }

    private static func string(from value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

extension ClientMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, pan, tilt, value, on
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "takeControl":
            self = .takeControl
        case "move":
            self = .move(
                pan: Self.unit(try container.decode(Double.self, forKey: .pan)),
                tilt: Self.unit(try container.decode(Double.self, forKey: .tilt))
            )
        case "zoom":
            self = .zoom(value: min(max(try container.decode(Int.self, forKey: .value), 0), 100))
        case "privacy":
            self = .privacy(on: try container.decode(Bool.self, forKey: .on))
        default:
            throw NacelleProtocolError.unknownType(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .takeControl:
            try container.encode("takeControl", forKey: .type)
        case let .move(pan, tilt):
            try container.encode("move", forKey: .type)
            try container.encode(pan, forKey: .pan)
            try container.encode(tilt, forKey: .tilt)
        case let .zoom(value):
            try container.encode("zoom", forKey: .type)
            try container.encode(value, forKey: .value)
        case let .privacy(on):
            try container.encode("privacy", forKey: .type)
            try container.encode(on, forKey: .on)
        }
    }

    private static func unit(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }
}

extension StateSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case camera, control, privacy, pan, tilt, zoom, moving
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            camera: try container.decode(CameraPresence.self, forKey: .camera),
            control: try container.decode(ControlState.self, forKey: .control),
            privacy: try container.decode(Bool.self, forKey: .privacy),
            pan: try container.decodeIfPresent(Double.self, forKey: .pan),
            tilt: try container.decodeIfPresent(Double.self, forKey: .tilt),
            zoom: try container.decodeIfPresent(Int.self, forKey: .zoom),
            moving: try container.decode(Bool.self, forKey: .moving)
        )
    }

    /// Les valeurs inconnues sont écrites `null` (spec § 5), pas omises.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(camera, forKey: .camera)
        try container.encode(control, forKey: .control)
        try container.encode(privacy, forKey: .privacy)
        try container.encode(pan, forKey: .pan)
        try container.encode(tilt, forKey: .tilt)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(moving, forKey: .moving)
    }
}

extension ServerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, code, message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "state":
            self = .state(try StateSnapshot(from: decoder))
        case "error":
            self = .error(
                code: try container.decode(ErrorCode.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        default:
            throw NacelleProtocolError.unknownType(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .state(snapshot):
            try container.encode("state", forKey: .type)
            try snapshot.encode(to: encoder)
        case let .error(code, message):
            try container.encode("error", forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd Packages/NacelleProtocol && swift test
```

Attendu : `Test run with 9 tests` … `passed`.

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

La vérification doit afficher `Aucune donnée locale.` ; sinon, retirer la donnée avant de commiter.

```bash
git add Packages/NacelleProtocol/Package.swift \
    Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift \
    Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift \
    Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute le paquet NacelleProtocol : messages de l'app et de ptzd

Messages de la spec § 5 en JSON avec un champ type, bornés au décodage ;
les valeurs inconnues de l'état sont écrites null.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 2 : Paquet ptzd, types de base de PTZCore et courbe de vitesse

Crée le paquet du service avec sa seule cible logique, `PTZCore`, testable sans caméra. Pose les types que toutes les tâches suivantes utilisent (caméra, horloge, journal) et la conversion joystick → vitesse UVC de la spec § 6.2 : `vitesse = round(|x|² × max)`, au moins 1.

**Fichiers :**
- Créer : `mac/ptzd/Package.swift`
- Créer : `mac/ptzd/Tests/PTZCoreTests/FakeCamera.swift`
- Créer : `mac/ptzd/Tests/PTZCoreTests/FakeScheduler.swift`
- Créer : `mac/ptzd/Tests/PTZCoreTests/LogRecorder.swift`
- Créer : `mac/ptzd/Tests/PTZCoreTests/SpeedCurveTests.swift`
- Créer : `mac/ptzd/Sources/PTZCore/CameraDevice.swift`
- Créer : `mac/ptzd/Sources/PTZCore/Scheduler.swift`
- Créer : `mac/ptzd/Sources/PTZCore/SpeedCurve.swift`

**Interfaces :**
- Utilise : `NacelleProtocol` (tâche 1), par dépendance de paquet locale.
- Produit :
  - `typealias ClientID = Int`, `typealias LogSink = @MainActor (String) -> Void`
  - `PanTiltRelative(panDirection: Int8, panSpeed: UInt8, tiltDirection: Int8, tiltSpeed: UInt8)` et `PanTiltRelative.stop`
  - `PanTiltPosition(pan: Double, tilt: Double)`, `CameraError` (`.absent`, `.ioKit(Int32)`)
  - `@MainActor protocol CameraDevice` : `isPresent`, `setPanTiltRelative(_:)`, `setPanTiltAbsolute(panDegrees:tiltDegrees:)`, `setZoom(_:)`, `readPanTilt() -> PanTiltPosition`, `readZoom() -> Int` (toutes `throws` sauf `isPresent`)
  - `protocol Cancellable { func cancel() }`, `@MainActor protocol Scheduler` : `now`, `schedule(after: TimeInterval, _: @escaping @MainActor @Sendable () -> Void) -> any Cancellable` ; implémentation réelle `DispatchScheduler`
  - `MotionSettings(panMaxSpeed: 40, tiltMaxSpeed: 60, panDirection: 1, tiltDirection: 1)`
  - `SpeedCurve.axis(_:maxSpeed:direction:) -> (direction: Int8, speed: UInt8)`, `SpeedCurve.command(pan:tilt:settings:) -> PanTiltRelative`
  - Faux pour les tests : `FakeCamera`, `FakeScheduler` (avec `advance(by:)` et `pendingCount`), `LogRecorder`

- [ ] **Étape 1 : Écrire le manifeste et les tests**

Créer `mac/ptzd/Package.swift` :

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ptzd",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/NacelleProtocol"),
    ],
    targets: [
        .target(
            name: "PTZCore",
            dependencies: [.product(name: "NacelleProtocol", package: "NacelleProtocol")]
        ),
        .testTarget(name: "PTZCoreTests", dependencies: ["PTZCore"]),
    ]
)
```

`mac/ptzd/Tests/PTZCoreTests/FakeCamera.swift` :

```swift
@testable import PTZCore

/// Caméra simulée : enregistre les commandes, peut échouer sur demande.
@MainActor
final class FakeCamera: CameraDevice {
    var isPresent = true
    var position = PanTiltPosition(pan: 2, tilt: -1)
    var zoomValue = 33
    /// La prochaine écriture échoue avec cette erreur.
    var failNextWrite: CameraError?
    private(set) var relativeCommands: [PanTiltRelative] = []
    private(set) var absoluteCommands: [PanTiltPosition] = []
    private(set) var zoomCommands: [Int] = []

    func setPanTiltRelative(_ command: PanTiltRelative) throws {
        try checkWrite()
        relativeCommands.append(command)
    }

    func setPanTiltAbsolute(panDegrees: Double, tiltDegrees: Double) throws {
        try checkWrite()
        let target = PanTiltPosition(pan: panDegrees, tilt: tiltDegrees)
        absoluteCommands.append(target)
        position = target
    }

    func setZoom(_ value: Int) throws {
        try checkWrite()
        zoomCommands.append(value)
        zoomValue = value
    }

    func readPanTilt() throws -> PanTiltPosition {
        guard isPresent else { throw CameraError.absent }
        return position
    }

    func readZoom() throws -> Int {
        guard isPresent else { throw CameraError.absent }
        return zoomValue
    }

    private func checkWrite() throws {
        guard isPresent else { throw CameraError.absent }
        if let failure = failNextWrite {
            failNextWrite = nil
            throw failure
        }
    }
}
```

`mac/ptzd/Tests/PTZCoreTests/FakeScheduler.swift` :

```swift
import Foundation
@testable import PTZCore

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

`mac/ptzd/Tests/PTZCoreTests/LogRecorder.swift` :

```swift
@testable import PTZCore

/// Journal capturé pour les assertions.
@MainActor
final class LogRecorder {
    private(set) var lines: [String] = []

    var sink: LogSink {
        { [weak self] line in self?.lines.append(line) }
    }
}
```

`mac/ptzd/Tests/PTZCoreTests/SpeedCurveTests.swift` :

```swift
import Testing
@testable import PTZCore

@Suite("Courbe de vitesse")
struct SpeedCurveTests {
    @Test("0 donne l'arrêt")
    func zeroStops() {
        #expect(SpeedCurve.axis(0, maxSpeed: 40, direction: 1) == (0, 1))
    }

    @Test("Plein débattement : vitesse maximale, dans le sens du signe")
    func fullDeflection() {
        #expect(SpeedCurve.axis(1, maxSpeed: 40, direction: 1) == (1, 40))
        #expect(SpeedCurve.axis(-1, maxSpeed: 40, direction: 1) == (-1, 40))
    }

    @Test("Courbe quadratique : 0,5 donne un quart du maximum")
    func quadratic() {
        #expect(SpeedCurve.axis(0.5, maxSpeed: 40, direction: 1) == (1, 10))
    }

    @Test("Une petite consigne donne au moins la vitesse 1")
    func minimumSpeed() {
        #expect(SpeedCurve.axis(0.05, maxSpeed: 40, direction: 1) == (1, 1))
    }

    @Test("direction -1 inverse le sens")
    func directionFlips() {
        #expect(SpeedCurve.axis(1, maxSpeed: 40, direction: -1) == (-1, 40))
    }

    @Test("Hors bornes ou non fini")
    func outOfRange() {
        #expect(SpeedCurve.axis(3, maxSpeed: 40, direction: 1) == (1, 40))
        #expect(SpeedCurve.axis(.nan, maxSpeed: 40, direction: 1) == (0, 1))
    }

    @Test("Commande combinée ; 0,0 vaut stop")
    func command() {
        let settings = MotionSettings(panMaxSpeed: 40, tiltMaxSpeed: 60, panDirection: 1, tiltDirection: -1)
        #expect(SpeedCurve.command(pan: 1, tilt: 1, settings: settings)
            == PanTiltRelative(panDirection: 1, panSpeed: 40, tiltDirection: -1, tiltSpeed: 60))
        #expect(SpeedCurve.command(pan: 0, tilt: 0, settings: settings) == .stop)
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd mac/ptzd && swift test --filter SpeedCurveTests
```

Échec attendu : la compilation échoue : la cible `PTZCore` n'a pas encore de sources.

- [ ] **Étape 3 : Écrire l'implémentation**

`mac/ptzd/Sources/PTZCore/CameraDevice.swift` :

```swift
/// Identifiant d'une connexion cliente, attribué par le serveur.
public typealias ClientID = Int

/// Destination des lignes de journal.
public typealias LogSink = @MainActor (String) -> Void

/// Commande PanTilt en vitesse (UVC CT_PANTILT_RELATIVE_CONTROL, sélecteur 0x0E).
public struct PanTiltRelative: Equatable, Sendable {
    /// -1, 0 (arrêt) ou 1.
    public var panDirection: Int8
    public var panSpeed: UInt8
    /// -1, 0 (arrêt) ou 1.
    public var tiltDirection: Int8
    public var tiltSpeed: UInt8

    public init(panDirection: Int8, panSpeed: UInt8, tiltDirection: Int8, tiltSpeed: UInt8) {
        self.panDirection = panDirection
        self.panSpeed = panSpeed
        self.tiltDirection = tiltDirection
        self.tiltSpeed = tiltSpeed
    }

    /// Arrêt : sens 0 sur les deux axes, avec la vitesse minimale valide (1).
    public static let stop = PanTiltRelative(panDirection: 0, panSpeed: 1, tiltDirection: 0, tiltSpeed: 1)
}

/// Position absolue de la nacelle, en degrés.
public struct PanTiltPosition: Equatable, Sendable {
    public var pan: Double
    public var tilt: Double

    public init(pan: Double, tilt: Double) {
        self.pan = pan
        self.tilt = tilt
    }
}

public enum CameraError: Error, Equatable {
    /// La caméra n'est pas branchée.
    case absent
    /// Requête USB refusée, avec le code IOKit.
    case ioKit(Int32)
}

/// Ce que PTZCore attend de la caméra. Les appels sont synchrones et courts
/// (une requête de contrôle USB prend quelques millisecondes).
@MainActor
public protocol CameraDevice: AnyObject {
    var isPresent: Bool { get }
    func setPanTiltRelative(_ command: PanTiltRelative) throws
    func setPanTiltAbsolute(panDegrees: Double, tiltDegrees: Double) throws
    func setZoom(_ value: Int) throws
    func readPanTilt() throws -> PanTiltPosition
    func readZoom() throws -> Int
}
```

`mac/ptzd/Sources/PTZCore/Scheduler.swift` :

```swift
import Foundation

/// Une action programmée, annulable.
public protocol Cancellable: AnyObject {
    func cancel()
}

/// Horloge et minuteries. Injectée pour que les tests maîtrisent le temps.
@MainActor
public protocol Scheduler: AnyObject {
    /// Temps monotone, en secondes.
    var now: TimeInterval { get }
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable
}

/// Implémentation réelle, sur la file principale.
@MainActor
public final class DispatchScheduler: Scheduler {
    public init() {}

    public var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    @discardableResult
    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> any Cancellable {
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

`mac/ptzd/Sources/PTZCore/SpeedCurve.swift` :

```swift
/// Réglages du mouvement, issus de config.json (spec § 6.7).
public struct MotionSettings: Equatable, Sendable {
    public var panMaxSpeed: Int
    public var tiltMaxSpeed: Int
    /// +1 ou -1 : sens UVC correspondant à une consigne positive.
    public var panDirection: Int
    public var tiltDirection: Int

    public init(panMaxSpeed: Int = 40, tiltMaxSpeed: Int = 60, panDirection: Int = 1, tiltDirection: Int = 1) {
        self.panMaxSpeed = panMaxSpeed
        self.tiltMaxSpeed = tiltMaxSpeed
        self.panDirection = panDirection
        self.tiltDirection = tiltDirection
    }
}

/// Conversion d'une consigne de joystick en commande UVC (spec § 6.2).
public enum SpeedCurve {
    /// vitesse = round(|x|² × max), au moins 1 dès que x ≠ 0 ; sens = signe(x) × direction.
    public static func axis(_ value: Double, maxSpeed: Int, direction: Int) -> (direction: Int8, speed: UInt8) {
        guard value.isFinite else { return (0, 1) }
        let clamped = min(max(value, -1), 1)
        guard clamped != 0 else { return (0, 1) }
        let raw = Int((clamped * clamped * Double(maxSpeed)).rounded())
        let speed = min(max(raw, 1), Int(UInt8.max))
        let sign: Int8 = clamped > 0 ? 1 : -1
        let flip: Int8 = direction < 0 ? -1 : 1
        return (sign * flip, UInt8(speed))
    }

    public static func command(pan: Double, tilt: Double, settings: MotionSettings) -> PanTiltRelative {
        let p = axis(pan, maxSpeed: settings.panMaxSpeed, direction: settings.panDirection)
        let t = axis(tilt, maxSpeed: settings.tiltMaxSpeed, direction: settings.tiltDirection)
        return PanTiltRelative(panDirection: p.direction, panSpeed: p.speed, tiltDirection: t.direction, tiltSpeed: t.speed)
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd mac/ptzd && swift test --filter SpeedCurveTests
```

Attendu : `Test run with 7 tests` … `passed`.

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

La vérification doit afficher `Aucune donnée locale.` ; sinon, retirer la donnée avant de commiter.

```bash
git add mac/ptzd/Package.swift \
    mac/ptzd/Tests/PTZCoreTests/FakeCamera.swift \
    mac/ptzd/Tests/PTZCoreTests/FakeScheduler.swift \
    mac/ptzd/Tests/PTZCoreTests/LogRecorder.swift \
    mac/ptzd/Tests/PTZCoreTests/SpeedCurveTests.swift \
    mac/ptzd/Sources/PTZCore/CameraDevice.swift \
    mac/ptzd/Sources/PTZCore/Scheduler.swift \
    mac/ptzd/Sources/PTZCore/SpeedCurve.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Crée le paquet ptzd : types de base de PTZCore et courbe de vitesse

Caméra, horloge et journal derrière des protocoles pour les tests ;
vitesse UVC = round(|x|² × max), au moins 1 (spec § 6.2).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 3 : Mouvement en vitesse avec arrêt automatique (MotionDriver)

Spec § 6.2 : une commande UVC n'est envoyée que si elle change ; sans `move` depuis 300 ms, ou à la déconnexion du dernier client qui pilotait, le mouvement s'arrête. Un arrêt refusé par la caméra est retenté toutes les 300 ms. La position est relue chaque seconde pendant le mouvement et juste après l'arrêt.

**Fichiers :**
- Créer : `mac/ptzd/Tests/PTZCoreTests/MotionDriverTests.swift`
- Créer : `mac/ptzd/Sources/PTZCore/MotionDriver.swift`

**Interfaces :**
- Utilise : `CameraDevice`, `Scheduler`, `Cancellable`, `MotionSettings`, `SpeedCurve`, `PanTiltRelative`, `PanTiltPosition`, `ClientID`, `LogSink` (tâche 2).
- Produit :
  - `@MainActor final class MotionDriver(camera:scheduler:settings:log:)`
  - `MotionDriver.deadManDelay = 0.3`, `MotionDriver.pollInterval = 1.0`
  - `isMoving: Bool`, `position: PanTiltPosition?`, `onChange: (() -> Void)?`
  - `move(pan:tilt:from: ClientID) throws`, `stop() throws`, `clientDisconnected(_: ClientID)`, `refreshPosition()`, `reset()`

- [ ] **Étape 1 : Écrire les tests**

`mac/ptzd/Tests/PTZCoreTests/MotionDriverTests.swift` :

```swift
import Testing
@testable import PTZCore

@MainActor
@Suite("Mouvement en vitesse")
struct MotionDriverTests {
    let camera = FakeCamera()
    let scheduler = FakeScheduler()
    let log = LogRecorder()
    let driver: MotionDriver

    init() {
        driver = MotionDriver(camera: camera, scheduler: scheduler, settings: MotionSettings(), log: log.sink)
    }

    private var right: PanTiltRelative {
        PanTiltRelative(panDirection: 1, panSpeed: 40, tiltDirection: 0, tiltSpeed: 1)
    }

    @Test("Une consigne envoie la commande et passe en mouvement")
    func moveSendsCommand() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        #expect(camera.relativeCommands == [right])
        #expect(driver.isMoving)
    }

    @Test("La même consigne répétée n'est envoyée qu'une fois")
    func noDuplicates() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        try driver.move(pan: 1, tilt: 0, from: 1)
        #expect(camera.relativeCommands == [right])
    }

    @Test("Arrêt automatique 300 ms après la dernière consigne")
    func deadMan() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        scheduler.advance(by: 0.29)
        #expect(driver.isMoving)
        scheduler.advance(by: 0.02)
        #expect(!driver.isMoving)
        #expect(camera.relativeCommands == [right, .stop])
    }

    @Test("Des consignes toutes les 100 ms maintiennent le mouvement")
    func steadyStream() throws {
        for _ in 0..<10 {
            try driver.move(pan: 1, tilt: 0, from: 1)
            scheduler.advance(by: 0.1)
        }
        #expect(driver.isMoving)
        #expect(camera.relativeCommands == [right])
    }

    @Test("0,0 arrête tout de suite")
    func zeroStops() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        try driver.move(pan: 0, tilt: 0, from: 1)
        #expect(!driver.isMoving)
        #expect(camera.relativeCommands == [right, .stop])
        #expect(scheduler.pendingCount == 0)
    }

    @Test("0,0 à l'arrêt n'envoie rien")
    func zeroWhenIdle() throws {
        try driver.move(pan: 0, tilt: 0, from: 1)
        #expect(camera.relativeCommands.isEmpty)
    }

    @Test("La déconnexion du dernier pilote arrête ; celle d'un autre client non")
    func disconnect() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        driver.clientDisconnected(2)
        #expect(driver.isMoving)
        driver.clientDisconnected(1)
        #expect(!driver.isMoving)
        #expect(camera.relativeCommands == [right, .stop])
    }

    @Test("Un arrêt automatique refusé est retenté 300 ms plus tard")
    func stopRetry() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        camera.failNextWrite = .ioKit(-536870212)
        scheduler.advance(by: 0.31)
        #expect(camera.relativeCommands == [right])
        #expect(log.lines.count == 1)
        scheduler.advance(by: 0.31)
        #expect(camera.relativeCommands == [right, .stop])
    }

    @Test("Position relue chaque seconde pendant le mouvement, puis à l'arrêt")
    func polling() throws {
        var changes = 0
        driver.onChange = { changes += 1 }
        try driver.move(pan: 1, tilt: 0, from: 1)
        camera.position = PanTiltPosition(pan: 20, tilt: -1)
        for _ in 0..<10 {
            scheduler.advance(by: 0.1)
            try driver.move(pan: 1, tilt: 0, from: 1)
        }
        #expect(driver.position == PanTiltPosition(pan: 20, tilt: -1))
        camera.position = PanTiltPosition(pan: 30, tilt: -1)
        try driver.move(pan: 0, tilt: 0, from: 1)
        #expect(driver.position == PanTiltPosition(pan: 30, tilt: -1))
        #expect(changes == 4)
    }

    @Test("reset oublie mouvement et position")
    func reset() throws {
        try driver.move(pan: 1, tilt: 0, from: 1)
        driver.refreshPosition()
        driver.reset()
        #expect(!driver.isMoving)
        #expect(driver.position == nil)
        #expect(scheduler.pendingCount == 0)
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd mac/ptzd && swift test --filter MotionDriverTests
```

Échec attendu : la compilation échoue : `cannot find 'MotionDriver' in scope`.

- [ ] **Étape 3 : Écrire l'implémentation**

`mac/ptzd/Sources/PTZCore/MotionDriver.swift` :

```swift
import Foundation

/// Mouvement en vitesse, avec arrêt automatique et relecture de la position (spec § 6.2).
@MainActor
public final class MotionDriver {
    /// Délai sans message `move` au bout duquel le mouvement s'arrête.
    public static let deadManDelay: TimeInterval = 0.3
    /// Période de relecture de la position pendant un mouvement.
    public static let pollInterval: TimeInterval = 1.0

    public private(set) var isMoving = false
    public private(set) var position: PanTiltPosition?
    /// Appelé quand `isMoving` ou `position` change.
    public var onChange: (() -> Void)?

    private let camera: any CameraDevice
    private let scheduler: any Scheduler
    private let settings: MotionSettings
    private let log: LogSink
    private var lastSent = PanTiltRelative.stop
    private var lastMover: ClientID?
    private var deadMan: (any Cancellable)?
    private var poll: (any Cancellable)?

    public init(camera: any CameraDevice, scheduler: any Scheduler, settings: MotionSettings, log: @escaping LogSink) {
        self.camera = camera
        self.scheduler = scheduler
        self.settings = settings
        self.log = log
    }

    /// Applique une consigne de vitesse. `0,0` arrête tout de suite.
    public func move(pan: Double, tilt: Double, from client: ClientID) throws {
        lastMover = client
        let command = SpeedCurve.command(pan: pan, tilt: tilt, settings: settings)
        guard command != .stop else {
            try stop()
            return
        }
        if command != lastSent {
            try camera.setPanTiltRelative(command)
            lastSent = command
        }
        deadMan?.cancel()
        deadMan = scheduler.schedule(after: Self.deadManDelay) { [weak self] in
            self?.deadManFired()
        }
        if !isMoving {
            isMoving = true
            schedulePoll()
            onChange?()
        }
    }

    /// Arrête le mouvement puis relit la position. Si l'arrêt échoue, la
    /// commande en cours reste mémorisée : le prochain arrêt la renverra.
    public func stop() throws {
        deadMan?.cancel()
        deadMan = nil
        poll?.cancel()
        poll = nil
        let wasMoving = isMoving
        isMoving = false
        if lastSent != .stop {
            try camera.setPanTiltRelative(.stop)
            lastSent = .stop
        }
        refreshPosition()
        if wasMoving {
            onChange?()
        }
    }

    /// Arrête le mouvement si ce client était le dernier à piloter.
    public func clientDisconnected(_ client: ClientID) {
        guard client == lastMover else { return }
        lastMover = nil
        do {
            try stop()
        } catch {
            log("Arrêt à la déconnexion impossible : \(error). Nouvel essai dans 0,3 s.")
            scheduleStopRetry()
        }
    }

    /// Relit la position ; publie si elle a changé.
    public func refreshPosition() {
        guard let read = try? camera.readPanTilt(), read != position else { return }
        position = read
        onChange?()
    }

    /// Oublie tout (caméra débranchée).
    public func reset() {
        deadMan?.cancel()
        deadMan = nil
        poll?.cancel()
        poll = nil
        lastSent = .stop
        lastMover = nil
        let changed = isMoving || position != nil
        isMoving = false
        position = nil
        if changed {
            onChange?()
        }
    }

    private func deadManFired() {
        deadMan = nil
        do {
            try stop()
        } catch {
            log("Arrêt automatique impossible : \(error). Nouvel essai dans 0,3 s.")
            scheduleStopRetry()
        }
    }

    private func scheduleStopRetry() {
        deadMan = scheduler.schedule(after: Self.deadManDelay) { [weak self] in
            self?.deadManFired()
        }
    }

    private func schedulePoll() {
        poll = scheduler.schedule(after: Self.pollInterval) { [weak self] in
            self?.pollTick()
        }
    }

    private func pollTick() {
        guard isMoving else { return }
        refreshPosition()
        schedulePoll()
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd mac/ptzd && swift test --filter MotionDriverTests
```

Attendu : `Test run with 10 tests` … `passed`.

Puis la suite complète, pour vérifier qu'aucune tâche précédente n'est cassée :

```bash
cd mac/ptzd && swift test
```

Attendu : 17 tests au total, tous `passed` (somme des lignes `Test run with N tests`).

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

La vérification doit afficher `Aucune donnée locale.` ; sinon, retirer la donnée avant de commiter.

```bash
git add mac/ptzd/Tests/PTZCoreTests/MotionDriverTests.swift \
    mac/ptzd/Sources/PTZCore/MotionDriver.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute MotionDriver : mouvement en vitesse et arrêt automatique

Pas de commande UVC en double ; arrêt 300 ms après le dernier move ou à la
déconnexion du pilote, retenté s'il échoue ; position relue chaque seconde.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 4 : Zoom absolu (ZoomDriver)

Spec § 6.3 : zoom borné à 0…100, au plus 10 envois par seconde ; si les messages arrivent plus vite, seule la dernière valeur part. Un envoi différé qui échoue ne peut plus être signalé au client : il est journalisé.

**Fichiers :**
- Créer : `mac/ptzd/Tests/PTZCoreTests/ZoomDriverTests.swift`
- Créer : `mac/ptzd/Sources/PTZCore/ZoomDriver.swift`

**Interfaces :**
- Utilise : `CameraDevice`, `Scheduler`, `Cancellable`, `LogSink` (tâche 2).
- Produit :
  - `@MainActor final class ZoomDriver(camera:scheduler:log:)`, `ZoomDriver.minInterval = 0.1`
  - `value: Int?`, `onChange: (() -> Void)?`, `set(_: Int) throws`, `refresh()`, `reset()`

- [ ] **Étape 1 : Écrire les tests**

`mac/ptzd/Tests/PTZCoreTests/ZoomDriverTests.swift` :

```swift
import Testing
@testable import PTZCore

@MainActor
@Suite("Zoom")
struct ZoomDriverTests {
    let camera = FakeCamera()
    let scheduler = FakeScheduler()
    let log = LogRecorder()
    let driver: ZoomDriver

    init() {
        driver = ZoomDriver(camera: camera, scheduler: scheduler, log: log.sink)
    }

    @Test("Envoi immédiat, borné à 0…100")
    func clamps() throws {
        try driver.set(150)
        #expect(camera.zoomCommands == [100])
        #expect(driver.value == 100)
    }

    @Test("Au plus 10 envois par seconde : seule la dernière valeur en attente part")
    func coalesces() throws {
        try driver.set(10)
        scheduler.advance(by: 0.02)
        try driver.set(20)
        try driver.set(30)
        #expect(camera.zoomCommands == [10])
        scheduler.advance(by: 0.08)
        #expect(camera.zoomCommands == [10, 30])
        #expect(driver.value == 30)
    }

    @Test("Après le délai, l'envoi est de nouveau immédiat")
    func immediateAfterInterval() throws {
        try driver.set(10)
        scheduler.advance(by: 0.1)
        try driver.set(20)
        #expect(camera.zoomCommands == [10, 20])
    }

    @Test("Un envoi différé refusé est journalisé")
    func deferredFailureIsLogged() throws {
        try driver.set(10)
        try driver.set(20)
        camera.failNextWrite = .ioKit(-536870212)
        scheduler.advance(by: 0.1)
        #expect(camera.zoomCommands == [10])
        #expect(log.lines.count == 1)
    }

    @Test("refresh relit la caméra ; reset oublie")
    func refreshAndReset() {
        driver.refresh()
        #expect(driver.value == 33)
        driver.reset()
        #expect(driver.value == nil)
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd mac/ptzd && swift test --filter ZoomDriverTests
```

Échec attendu : la compilation échoue : `cannot find 'ZoomDriver' in scope`.

- [ ] **Étape 3 : Écrire l'implémentation**

`mac/ptzd/Sources/PTZCore/ZoomDriver.swift` :

```swift
import Foundation

/// Zoom absolu, borné à 0…100, au plus 10 envois par seconde (spec § 6.3).
@MainActor
public final class ZoomDriver {
    public static let minInterval: TimeInterval = 0.1

    public private(set) var value: Int?
    /// Appelé quand `value` change.
    public var onChange: (() -> Void)?

    private let camera: any CameraDevice
    private let scheduler: any Scheduler
    private let log: LogSink
    private var lastSentAt = -TimeInterval.infinity
    private var pending: Int?
    private var flush: (any Cancellable)?

    public init(camera: any CameraDevice, scheduler: any Scheduler, log: @escaping LogSink) {
        self.camera = camera
        self.scheduler = scheduler
        self.log = log
    }

    /// Envoie tout de suite, ou garde la valeur pour le prochain créneau.
    /// Seule la dernière valeur en attente est envoyée.
    public func set(_ requested: Int) throws {
        let clamped = min(max(requested, 0), 100)
        let elapsed = scheduler.now - lastSentAt
        if flush == nil, elapsed >= Self.minInterval {
            try send(clamped)
            return
        }
        pending = clamped
        if flush == nil {
            flush = scheduler.schedule(after: Self.minInterval - elapsed) { [weak self] in
                self?.flushPending()
            }
        }
    }

    /// Relit le zoom ; publie s'il a changé.
    public func refresh() {
        guard let read = try? camera.readZoom(), read != value else { return }
        value = read
        onChange?()
    }

    /// Oublie tout (caméra débranchée).
    public func reset() {
        flush?.cancel()
        flush = nil
        pending = nil
        lastSentAt = -TimeInterval.infinity
        if value != nil {
            value = nil
            onChange?()
        }
    }

    private func send(_ newValue: Int) throws {
        try camera.setZoom(newValue)
        lastSentAt = scheduler.now
        if value != newValue {
            value = newValue
            onChange?()
        }
    }

    private func flushPending() {
        flush = nil
        guard let next = pending else { return }
        pending = nil
        do {
            try send(next)
        } catch {
            log("Zoom à \(next) impossible : \(error)")
        }
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd mac/ptzd && swift test --filter ZoomDriverTests
```

Attendu : `Test run with 5 tests` … `passed`.

Puis la suite complète, pour vérifier qu'aucune tâche précédente n'est cassée :

```bash
cd mac/ptzd && swift test
```

Attendu : 22 tests au total, tous `passed` (somme des lignes `Test run with N tests`).

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

La vérification doit afficher `Aucune donnée locale.` ; sinon, retirer la donnée avant de commiter.

```bash
git add mac/ptzd/Tests/PTZCoreTests/ZoomDriverTests.swift \
    mac/ptzd/Sources/PTZCore/ZoomDriver.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute ZoomDriver : zoom borné, au plus 10 envois par seconde

Seule la dernière valeur en attente est envoyée (spec § 6.3).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 5 : Vie privée et state.json (PrivacyKeeper, JSONFileStateStore)

Spec § 6.5, avec l'amendement A2 : à l'entrée, la position est mémorisée et enregistrée, puis l'objectif part à -70° (la caméra ignore un ordre à -90°) ; à la sortie, la position est rétablie (0°/0° si elle était inconnue). L'état survit aux redémarrages. Choix de sûreté : un `state.json` illisible est lu comme « vie privée active » ; un échec d'écriture est journalisé sans empêcher de protéger l'image ; si la caméra refuse l'entrée, l'enregistrement est annulé.

**Fichiers :**
- Créer : `mac/ptzd/Tests/PTZCoreTests/MemoryStateStore.swift`
- Créer : `mac/ptzd/Tests/PTZCoreTests/StateStoreTests.swift`
- Créer : `mac/ptzd/Tests/PTZCoreTests/PrivacyKeeperTests.swift`
- Créer : `mac/ptzd/Sources/PTZCore/StateStore.swift`
- Créer : `mac/ptzd/Sources/PTZCore/PrivacyKeeper.swift`

**Interfaces :**
- Utilise : `CameraDevice`, `PanTiltPosition`, `LogSink` (tâche 2).
- Produit :
  - `SavedPosition(pan:tilt:zoom:)`, `PersistedState(privacy: Bool, saved: SavedPosition?)`
  - `protocol StateStore: AnyObject { func load() -> PersistedState; func save(_: PersistedState) throws }`
  - `final class JSONFileStateStore(url: URL, log: @escaping (String) -> Void)`
  - `@MainActor final class PrivacyKeeper(camera:store:log:)`, `PrivacyKeeper.privacyTilt = -70`
  - `isActive: Bool`, `onChange`, `enter(currentPosition: PanTiltPosition?, currentZoom: Int?) throws`, `exit() throws`, `enforce() throws`
  - Faux pour les tests : `MemoryStateStore` (avec `failSaves`)

- [ ] **Étape 1 : Écrire les tests**

`mac/ptzd/Tests/PTZCoreTests/MemoryStateStore.swift` :

```swift
import Foundation
@testable import PTZCore

/// state.json en mémoire.
final class MemoryStateStore: StateStore {
    var state: PersistedState
    var failSaves = false
    private(set) var saveCount = 0

    init(_ state: PersistedState = PersistedState(privacy: false, saved: nil)) {
        self.state = state
    }

    func load() -> PersistedState {
        state
    }

    func save(_ state: PersistedState) throws {
        saveCount += 1
        if failSaves {
            throw CocoaError(.fileWriteNoPermission)
        }
        self.state = state
    }
}
```

`mac/ptzd/Tests/PTZCoreTests/StateStoreTests.swift` :

```swift
import Foundation
import Testing
@testable import PTZCore

@Suite("state.json")
struct StateStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ptzd-tests-\(UUID().uuidString)")

    private var url: URL {
        directory.appending(path: "state.json")
    }

    @Test("Aller-retour")
    func roundTrip() throws {
        let store = JSONFileStateStore(url: url, log: { _ in })
        let state = PersistedState(privacy: true, saved: SavedPosition(pan: 30, tilt: -10, zoom: 33))
        try store.save(state)
        #expect(store.load() == state)
    }

    @Test("Fichier absent : pas de vie privée")
    func missingFile() {
        let store = JSONFileStateStore(url: url, log: { _ in })
        #expect(store.load() == PersistedState(privacy: false, saved: nil))
    }

    @Test("Fichier illisible : vie privée par précaution, et journalisé")
    func corruptFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{pas du json".utf8).write(to: url)
        let lines = Lines()
        let store = JSONFileStateStore(url: url, log: { lines.append($0) })
        #expect(store.load() == PersistedState(privacy: true, saved: nil))
        #expect(lines.count == 1)
    }
}

private final class Lines: @unchecked Sendable {
    private var storage: [String] = []

    func append(_ line: String) {
        storage.append(line)
    }

    var count: Int {
        storage.count
    }
}
```

`mac/ptzd/Tests/PTZCoreTests/PrivacyKeeperTests.swift` :

```swift
import Testing
@testable import PTZCore

@MainActor
@Suite("Vie privée")
struct PrivacyKeeperTests {
    let camera = FakeCamera()
    let store = MemoryStateStore()
    let log = LogRecorder()

    private func makeKeeper() -> PrivacyKeeper {
        PrivacyKeeper(camera: camera, store: store, log: log.sink)
    }

    @Test("Entrée : position mémorisée et enregistrée, objectif vers le bas")
    func enter() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50)
        #expect(keeper.isActive)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 30, tilt: PrivacyKeeper.privacyTilt)])
        #expect(store.state == PersistedState(privacy: true, saved: SavedPosition(pan: 30, tilt: -10, zoom: 50)))
    }

    @Test("Entrée refusée par la caméra : rien n'est activé, l'enregistrement est annulé")
    func enterFailure() {
        let keeper = makeKeeper()
        camera.failNextWrite = .ioKit(-536870212)
        #expect(throws: CameraError.ioKit(-536870212)) {
            try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50)
        }
        #expect(!keeper.isActive)
        #expect(store.state == PersistedState(privacy: false, saved: nil))
    }

    @Test("Sortie : position et zoom rétablis, état effacé")
    func exit() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50)
        try keeper.exit()
        #expect(!keeper.isActive)
        #expect(camera.absoluteCommands.last == PanTiltPosition(pan: 30, tilt: -10))
        #expect(camera.zoomCommands == [50])
        #expect(store.state == PersistedState(privacy: false, saved: nil))
    }

    @Test("Sortie refusée : on reste en vie privée")
    func exitFailure() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50)
        camera.failNextWrite = .ioKit(-536870212)
        #expect(throws: CameraError.ioKit(-536870212)) { try keeper.exit() }
        #expect(keeper.isActive)
        #expect(store.state.privacy)
    }

    @Test("Position inconnue : pan 0 à l'entrée, 0°/0° à la sortie, zoom inchangé")
    func unknownPosition() throws {
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: nil, currentZoom: nil)
        try keeper.exit()
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 0, tilt: PrivacyKeeper.privacyTilt), PanTiltPosition(pan: 0, tilt: 0)])
        #expect(camera.zoomCommands.isEmpty)
    }

    @Test("Au démarrage, l'état enregistré est repris et réappliqué")
    func restoreAndEnforce() throws {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        let keeper = makeKeeper()
        #expect(keeper.isActive)
        try keeper.enforce()
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyKeeper.privacyTilt)])
    }

    @Test("enforce ne fait rien hors vie privée")
    func enforceIdle() throws {
        try makeKeeper().enforce()
        #expect(camera.absoluteCommands.isEmpty)
    }

    @Test("Un échec d'écriture du fichier n'empêche pas de protéger l'image")
    func storeFailure() throws {
        store.failSaves = true
        let keeper = makeKeeper()
        try keeper.enter(currentPosition: PanTiltPosition(pan: 30, tilt: -10), currentZoom: 50)
        #expect(keeper.isActive)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 30, tilt: PrivacyKeeper.privacyTilt)])
        #expect(log.lines.count == 1)
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd mac/ptzd && swift test --filter "StateStoreTests|PrivacyKeeperTests"
```

Échec attendu : la compilation échoue : `cannot find type 'StateStore' in scope`.

- [ ] **Étape 3 : Écrire l'implémentation**

`mac/ptzd/Sources/PTZCore/StateStore.swift` :

```swift
import Foundation

/// Position mémorisée à l'entrée en vie privée.
public struct SavedPosition: Codable, Equatable, Sendable {
    public var pan: Double
    public var tilt: Double
    public var zoom: Int?

    public init(pan: Double, tilt: Double, zoom: Int?) {
        self.pan = pan
        self.tilt = tilt
        self.zoom = zoom
    }
}

/// Contenu de state.json (spec § 6.5).
public struct PersistedState: Codable, Equatable, Sendable {
    public var privacy: Bool
    public var saved: SavedPosition?

    public init(privacy: Bool, saved: SavedPosition?) {
        self.privacy = privacy
        self.saved = saved
    }
}

public protocol StateStore: AnyObject {
    func load() -> PersistedState
    func save(_ state: PersistedState) throws
}

/// state.json, écrit de façon atomique.
public final class JSONFileStateStore: StateStore {
    private let url: URL
    private let log: (String) -> Void

    public init(url: URL, log: @escaping (String) -> Void) {
        self.url = url
        self.log = log
    }

    /// Fichier absent : pas de vie privée. Fichier illisible : vie privée,
    /// par précaution (mieux vaut une caméra tournée vers le bas qu'une fuite).
    public func load() -> PersistedState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersistedState(privacy: false, saved: nil)
        }
        do {
            return try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: url))
        } catch {
            log("state.json illisible (\(error)) : vie privée activée par précaution.")
            return PersistedState(privacy: true, saved: nil)
        }
    }

    public func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
```

`mac/ptzd/Sources/PTZCore/PrivacyKeeper.swift` :

```swift
/// Mode vie privée : objectif tourné vers le bas, position mémorisée (spec § 6.5).
@MainActor
public final class PrivacyKeeper {
    /// Objectif vers le bas. -70° est obéi exactement ; la caméra ignore -90° (mesuré le 2026-10-05).
    public static let privacyTilt: Double = -70

    public private(set) var isActive: Bool
    /// Appelé quand `isActive` change.
    public var onChange: (() -> Void)?

    private let camera: any CameraDevice
    private let store: any StateStore
    private let log: LogSink
    private var saved: SavedPosition?

    public init(camera: any CameraDevice, store: any StateStore, log: @escaping LogSink) {
        self.camera = camera
        self.store = store
        self.log = log
        let persisted = store.load()
        isActive = persisted.privacy
        saved = persisted.saved
    }

    /// Mémorise la position (nil si inconnue), enregistre, puis tourne l'objectif vers le bas.
    /// Si la caméra refuse, l'enregistrement est annulé et l'erreur remonte.
    public func enter(currentPosition: PanTiltPosition?, currentZoom: Int?) throws {
        guard !isActive else { return }
        let savedNow = currentPosition.map { SavedPosition(pan: $0.pan, tilt: $0.tilt, zoom: currentZoom) }
        persist(PersistedState(privacy: true, saved: savedNow))
        do {
            try camera.setPanTiltAbsolute(panDegrees: currentPosition?.pan ?? 0, tiltDegrees: Self.privacyTilt)
        } catch {
            persist(PersistedState(privacy: false, saved: nil))
            throw error
        }
        saved = savedNow
        isActive = true
        onChange?()
    }

    /// Rétablit la position mémorisée, ou 0°/0° si elle est inconnue.
    /// Si la caméra refuse, on reste en vie privée.
    public func exit() throws {
        guard isActive else { return }
        let target = saved ?? SavedPosition(pan: 0, tilt: 0, zoom: nil)
        try camera.setPanTiltAbsolute(panDegrees: target.pan, tiltDegrees: target.tilt)
        if let zoom = target.zoom {
            try camera.setZoom(zoom)
        }
        persist(PersistedState(privacy: false, saved: nil))
        saved = nil
        isActive = false
        onChange?()
    }

    /// Renvoie l'objectif vers le bas si la vie privée est active (démarrage, rebranchement).
    public func enforce() throws {
        guard isActive else { return }
        try camera.setPanTiltAbsolute(panDegrees: saved?.pan ?? 0, tiltDegrees: Self.privacyTilt)
    }

    /// Une erreur d'écriture n'empêche pas de protéger l'image : on la journalise.
    private func persist(_ state: PersistedState) {
        do {
            try store.save(state)
        } catch {
            log("Enregistrement de state.json impossible : \(error)")
        }
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd mac/ptzd && swift test --filter "StateStoreTests|PrivacyKeeperTests"
```

Attendu : `Test run with 11 tests` … `passed`.

Puis la suite complète, pour vérifier qu'aucune tâche précédente n'est cassée :

```bash
cd mac/ptzd && swift test
```

Attendu : 33 tests au total, tous `passed` (somme des lignes `Test run with N tests`).

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

La vérification doit afficher `Aucune donnée locale.` ; sinon, retirer la donnée avant de commiter.

```bash
git add mac/ptzd/Tests/PTZCoreTests/MemoryStateStore.swift \
    mac/ptzd/Tests/PTZCoreTests/StateStoreTests.swift \
    mac/ptzd/Tests/PTZCoreTests/PrivacyKeeperTests.swift \
    mac/ptzd/Sources/PTZCore/StateStore.swift \
    mac/ptzd/Sources/PTZCore/PrivacyKeeper.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute la vie privée : objectif vers le bas et state.json

Position mémorisée et rétablie ; état repris au démarrage ; fichier
illisible lu comme vie privée active, par précaution (spec § 6.5).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 6 : Prise en main : lancement de obsbot-ai-off (ProcessAIOffRunner, ControlTaker)

Spec § 6.4 et § 6.9 : `takeControl` lance l'utilitaire dans un processus séparé, arrêté (SIGTERM) au-delà de 15 s ; codes de sortie 0 = succès, 1 = caméra introuvable, 2 = erreur du SDK. Pendant une exécution, une nouvelle demande attend le même résultat. Le SDK est très bavard (numéro de série, adresses du Mac) : sa sortie va dans un fichier à part. Si OBSBOT Center est ouvert, un avertissement est journalisé.

**Fichiers :**
- Créer : `mac/ptzd/Tests/PTZCoreTests/FakeAIOffRunner.swift`
- Créer : `mac/ptzd/Tests/PTZCoreTests/AIOffRunnerTests.swift`
- Créer : `mac/ptzd/Tests/PTZCoreTests/ControlTakerTests.swift`
- Créer : `mac/ptzd/Sources/PTZCore/AIOffRunner.swift`
- Créer : `mac/ptzd/Sources/PTZCore/ControlTaker.swift`

**Interfaces :**
- Utilise : `Scheduler`, `Cancellable`, `DispatchScheduler`, `LogSink` (tâche 2) ; `ControlState` (tâche 1).
- Produit :
  - `AIOffResult` : `.success`, `.cameraNotFound`, `.sdkError`, `.timeout`, `.launchFailed(String)`, `.unexpectedExit(Int32)`
  - `@MainActor protocol AIOffRunner { func run(completion: @escaping @MainActor @Sendable (AIOffResult) -> Void) }`
  - `ProcessAIOffRunner(executableURL:arguments: = [],timeout: = 15,outputURL: = nil,scheduler:)`, `ProcessAIOffRunner.result(status:exited:) -> AIOffResult`
  - `@MainActor final class ControlTaker(runner:isObsbotCenterRunning:log:)` : `state: ControlState`, `onChange`, `take()`
  - Faux pour les tests : `FakeAIOffRunner` (avec `runCount` et `finish(_:)`)

- [ ] **Étape 1 : Écrire les tests**

`mac/ptzd/Tests/PTZCoreTests/FakeAIOffRunner.swift` :

```swift
@testable import PTZCore

/// obsbot-ai-off simulé : le test décide quand et comment il se termine.
@MainActor
final class FakeAIOffRunner: AIOffRunner {
    private(set) var runCount = 0
    private var completions: [@MainActor @Sendable (AIOffResult) -> Void] = []

    func run(completion: @escaping @MainActor @Sendable (AIOffResult) -> Void) {
        runCount += 1
        completions.append(completion)
    }

    func finish(_ result: AIOffResult) {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0(result) }
    }
}
```

`mac/ptzd/Tests/PTZCoreTests/AIOffRunnerTests.swift` :

```swift
import Foundation
import Testing
@testable import PTZCore

@MainActor
@Suite("Lancement de obsbot-ai-off")
struct AIOffRunnerTests {
    private func run(_ path: String, _ arguments: [String] = [], timeout: TimeInterval = 5) async -> AIOffResult {
        let runner = ProcessAIOffRunner(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            timeout: timeout,
            scheduler: DispatchScheduler()
        )
        return await withCheckedContinuation { continuation in
            runner.run { continuation.resume(returning: $0) }
        }
    }

    @Test("Code 0 : succès")
    func success() async {
        #expect(await run("/usr/bin/true") == .success)
    }

    @Test("Code 1 : caméra introuvable")
    func cameraNotFound() async {
        #expect(await run("/usr/bin/false") == .cameraNotFound)
    }

    @Test("Code 2 : erreur du SDK ; autre code : sortie inattendue")
    func otherCodes() async {
        #expect(await run("/bin/sh", ["-c", "exit 2"]) == .sdkError)
        #expect(await run("/bin/sh", ["-c", "exit 7"]) == .unexpectedExit(7))
    }

    @Test("Délai dépassé : le processus est arrêté")
    func timeout() async {
        #expect(await run("/bin/sleep", ["5"], timeout: 0.3) == .timeout)
    }

    @Test("La sortie de l'utilitaire est ajoutée au fichier choisi")
    func outputFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ai-off-\(UUID().uuidString)/out.log")
        for word in ["un", "deux"] {
            let runner = ProcessAIOffRunner(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: [word],
                outputURL: url,
                scheduler: DispatchScheduler()
            )
            let result = await withCheckedContinuation { continuation in
                runner.run { continuation.resume(returning: $0) }
            }
            #expect(result == .success)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "un\ndeux\n")
    }

    @Test("Exécutable absent")
    func launchFailure() async {
        guard case .launchFailed = await run("/nonexistent/obsbot-ai-off") else {
            Issue.record("launchFailed attendu")
            return
        }
    }
}
```

`mac/ptzd/Tests/PTZCoreTests/ControlTakerTests.swift` :

```swift
import Testing
@testable import PTZCore

@MainActor
@Suite("Prise en main")
struct ControlTakerTests {
    let runner = FakeAIOffRunner()
    let log = LogRecorder()

    private func makeTaker(centerRunning: Bool = false) -> ControlTaker {
        ControlTaker(runner: runner, isObsbotCenterRunning: { centerRunning }, log: log.sink)
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

    @Test("Un échec donne failed et une ligne de journal")
    func failure() {
        let taker = makeTaker()
        taker.take()
        runner.finish(.timeout)
        #expect(taker.state == .failed)
        #expect(log.lines.count == 1)
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

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd mac/ptzd && swift test --filter "AIOffRunnerTests|ControlTakerTests"
```

Échec attendu : la compilation échoue : `cannot find type 'AIOffRunner' in scope`.

- [ ] **Étape 3 : Écrire l'implémentation**

`mac/ptzd/Sources/PTZCore/AIOffRunner.swift` :

```swift
import Foundation

/// Issue d'une exécution d'obsbot-ai-off (spec § 6.9).
public enum AIOffResult: Equatable, Sendable {
    case success
    case cameraNotFound
    case sdkError
    case timeout
    case launchFailed(String)
    case unexpectedExit(Int32)
}

@MainActor
public protocol AIOffRunner: AnyObject {
    func run(completion: @escaping @MainActor @Sendable (AIOffResult) -> Void)
}

/// Lance obsbot-ai-off dans un processus séparé, avec un délai maximal.
/// Le SDK est très bavard : sa sortie va dans un fichier à part, pas dans le journal de ptzd.
@MainActor
public final class ProcessAIOffRunner: AIOffRunner {
    private let executableURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let outputURL: URL?
    private let scheduler: any Scheduler

    public init(
        executableURL: URL,
        arguments: [String] = [],
        timeout: TimeInterval = 15,
        outputURL: URL? = nil,
        scheduler: any Scheduler
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.outputURL = outputURL
        self.scheduler = scheduler
    }

    public func run(completion: @escaping @MainActor @Sendable (AIOffResult) -> Void) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let output = appendingHandle() {
            process.standardOutput = output
            process.standardError = output
        }
        let run = Run(process: process)

        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            let exited = finished.terminationReason == .exit
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !run.done else { return }
                    run.done = true
                    run.timeoutTask?.cancel()
                    completion(Self.result(status: status, exited: exited))
                }
            }
        }

        do {
            try process.run()
        } catch {
            run.done = true
            completion(.launchFailed(error.localizedDescription))
            return
        }

        run.timeoutTask = scheduler.schedule(after: timeout) {
            guard !run.done else { return }
            run.done = true
            run.process.terminate()
            completion(.timeout)
        }
    }

    /// Fichier de sortie ouvert en ajout, créé au besoin ; nil si aucun n'est configuré.
    private func appendingHandle() -> FileHandle? {
        guard let outputURL else { return nil }
        let manager = FileManager.default
        try? manager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: outputURL.path) {
            manager.createFile(atPath: outputURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: outputURL) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    /// Codes de sortie de obsbot-ai-off : 0 succès, 1 caméra introuvable, 2 erreur du SDK.
    public static func result(status: Int32, exited: Bool) -> AIOffResult {
        guard exited else { return .unexpectedExit(status) }
        switch status {
        case 0: return .success
        case 1: return .cameraNotFound
        case 2: return .sdkError
        default: return .unexpectedExit(status)
        }
    }
}

/// État d'une exécution, partagé entre le gestionnaire de fin et la minuterie.
@MainActor
private final class Run {
    let process: Process
    var done = false
    var timeoutTask: (any Cancellable)?

    init(process: Process) {
        self.process = process
    }
}
```

`mac/ptzd/Sources/PTZCore/ControlTaker.swift` :

```swift
import NacelleProtocol

/// Prise en main : coupe le suivi IA via obsbot-ai-off (spec § 6.4).
@MainActor
public final class ControlTaker {
    public private(set) var state: ControlState = .idle
    /// Appelé quand `state` change.
    public var onChange: (() -> Void)?

    private let runner: any AIOffRunner
    private let isObsbotCenterRunning: @MainActor () -> Bool
    private let log: LogSink

    public init(runner: any AIOffRunner, isObsbotCenterRunning: @escaping @MainActor () -> Bool, log: @escaping LogSink) {
        self.runner = runner
        self.isObsbotCenterRunning = isObsbotCenterRunning
        self.log = log
    }

    /// Lance la coupure. Pendant une exécution, une nouvelle demande attend le même résultat.
    public func take() {
        if isObsbotCenterRunning() {
            log("OBSBOT Center est ouvert : ferme-le, il fausse la relecture du tilt.")
        }
        guard state != .taking else { return }
        state = .taking
        onChange?()
        runner.run { [weak self] result in
            self?.finish(result)
        }
    }

    private func finish(_ result: AIOffResult) {
        if result == .success {
            state = .ready
        } else {
            state = .failed
            log("obsbot-ai-off a échoué : \(result)")
        }
        onChange?()
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd mac/ptzd && swift test --filter "AIOffRunnerTests|ControlTakerTests"
```

Attendu : `Test run with 11 tests` … `passed`.

Puis la suite complète, pour vérifier qu'aucune tâche précédente n'est cassée :

```bash
cd mac/ptzd && swift test
```

Attendu : 44 tests au total, tous `passed` (somme des lignes `Test run with N tests`).

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

La vérification doit afficher `Aucune donnée locale.` ; sinon, retirer la donnée avant de commiter.

```bash
git add mac/ptzd/Tests/PTZCoreTests/FakeAIOffRunner.swift \
    mac/ptzd/Tests/PTZCoreTests/AIOffRunnerTests.swift \
    mac/ptzd/Tests/PTZCoreTests/ControlTakerTests.swift \
    mac/ptzd/Sources/PTZCore/AIOffRunner.swift \
    mac/ptzd/Sources/PTZCore/ControlTaker.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute la prise en main : lancement de obsbot-ai-off

Processus séparé, arrêté au-delà de 15 s ; une seule exécution à la fois ;
sortie du SDK dans un fichier à part (spec § 6.4 et § 6.9).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 7 : Contrôleur : messages, présence de la caméra, état publié (PTZController)

Le point d'entrée de la logique (spec § 5 et § 6). Il refuse `move`, `zoom` et `privacy` quand la caméra est absente, et `move` (sauf l'arrêt 0,0) et `zoom` pendant la vie privée. Au rebranchement en vie privée, l'objectif repart vers le bas et le suivi IA est recoupé. Il publie un `StateSnapshot` à chaque changement. Les tests de faisabilité ont montré qu'une position relue juste après un déplacement absolu est fausse : après l'entrée et la sortie de vie privée, la position n'est relue qu'au bout de 2 s (`settleDelay`).

**Fichiers :**
- Créer : `mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift`
- Créer : `mac/ptzd/Sources/PTZCore/PTZController.swift`

**Interfaces :**
- Utilise : `MotionDriver` (tâche 3), `ZoomDriver` (tâche 4), `PrivacyKeeper` et `StateStore` (tâche 5), `ControlTaker` et `AIOffRunner` (tâche 6), `ClientMessage`, `StateSnapshot`, `ErrorCode` (tâche 1).
- Produit :
  - `@MainActor final class PTZController(camera:scheduler:aiOff:store:settings:isObsbotCenterRunning:log:)`
  - `PTZController.settleDelay = 2`
  - `snapshot: StateSnapshot`, `onStateChange: ((StateSnapshot) -> Void)?`
  - `handle(_: ClientMessage, from: ClientID) -> (code: ErrorCode, message: String)?` (nil = pas d'erreur)
  - `clientDisconnected(_: ClientID)`, `cameraPresenceChanged(_: Bool)`

- [ ] **Étape 1 : Écrire les tests**

`mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift` :

```swift
import NacelleProtocol
import Testing
@testable import PTZCore

@MainActor
@Suite("Contrôleur")
struct PTZControllerTests {
    let camera = FakeCamera()
    let scheduler = FakeScheduler()
    let runner = FakeAIOffRunner()
    let store = MemoryStateStore()
    let log = LogRecorder()

    private func makeController() -> PTZController {
        PTZController(
            camera: camera,
            scheduler: scheduler,
            aiOff: runner,
            store: store,
            settings: MotionSettings(),
            isObsbotCenterRunning: { false },
            log: log.sink
        )
    }

    @Test("L'état initial reflète la caméra et state.json")
    func initialSnapshot() {
        camera.isPresent = false
        store.state = PersistedState(privacy: true, saved: nil)
        let controller = makeController()
        #expect(controller.snapshot.camera == .absent)
        #expect(controller.snapshot.privacy)
        #expect(controller.snapshot.control == .idle)
    }

    @Test("Caméra absente : move, zoom et privacy sont refusés")
    func cameraAbsent() {
        camera.isPresent = false
        let controller = makeController()
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1)?.code == .cameraAbsent)
        #expect(controller.handle(.zoom(value: 10), from: 1)?.code == .cameraAbsent)
        #expect(controller.handle(.privacy(on: true), from: 1)?.code == .cameraAbsent)
    }

    @Test("Un mouvement publie moving, puis l'arrêt automatique le retire")
    func movePublishes() {
        let controller = makeController()
        var published: [StateSnapshot] = []
        controller.onStateChange = { published.append($0) }
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1) == nil)
        #expect(controller.snapshot.moving)
        scheduler.advance(by: 0.31)
        #expect(!controller.snapshot.moving)
        #expect(published.contains { $0.moving })
    }

    @Test("Vie privée : arrêt, objectif vers le bas, puis refus des commandes")
    func privacyOn() {
        let controller = makeController()
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        #expect(controller.handle(.privacy(on: true), from: 1) == nil)
        #expect(controller.snapshot.privacy)
        #expect(!controller.snapshot.moving)
        #expect(camera.absoluteCommands.last?.tilt == PrivacyKeeper.privacyTilt)
        #expect(controller.handle(.move(pan: 1, tilt: 0), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.zoom(value: 10), from: 1)?.code == .privacyActive)
        #expect(controller.handle(.move(pan: 0, tilt: 0), from: 1) == nil)
    }

    @Test("La position n'est relue que 2 s après le déplacement absolu")
    func settleBeforeReading() {
        let controller = makeController()
        controller.cameraPresenceChanged(true)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(controller.snapshot.tilt == -1)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyKeeper.privacyTilt)
    }

    @Test("Sortie de vie privée : position et zoom relus")
    func privacyOff() {
        let controller = makeController()
        camera.position = PanTiltPosition(pan: 20, tilt: 5)
        _ = controller.handle(.zoom(value: 40), from: 1)
        _ = controller.handle(.privacy(on: true), from: 1)
        #expect(controller.handle(.privacy(on: false), from: 1) == nil)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(!controller.snapshot.privacy)
        #expect(controller.snapshot.pan == 20)
        #expect(controller.snapshot.tilt == 5)
        #expect(controller.snapshot.zoom == 40)
    }

    @Test("Commande refusée par la caméra : uvcFailed")
    func uvcFailure() {
        let controller = makeController()
        camera.failNextWrite = .ioKit(-536870212)
        #expect(controller.handle(.zoom(value: 10), from: 1)?.code == .uvcFailed)
    }

    @Test("takeControl : taking, puis ready quand l'utilitaire réussit")
    func takeControl() {
        let controller = makeController()
        _ = controller.handle(.takeControl, from: 1)
        #expect(controller.snapshot.control == .taking)
        runner.finish(.success)
        #expect(controller.snapshot.control == .ready)
    }

    @Test("Débranchement : caméra absente, mouvement oublié")
    func unplug() {
        let controller = makeController()
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 1)
        camera.isPresent = false
        controller.cameraPresenceChanged(false)
        #expect(controller.snapshot.camera == .absent)
        #expect(!controller.snapshot.moving)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Rebranchement en vie privée : objectif renvoyé vers le bas et suivi IA recoupé")
    func replugInPrivacy() {
        store.state = PersistedState(privacy: true, saved: SavedPosition(pan: 12, tilt: 3, zoom: nil))
        camera.isPresent = false
        let controller = makeController()
        camera.isPresent = true
        controller.cameraPresenceChanged(true)
        #expect(camera.absoluteCommands == [PanTiltPosition(pan: 12, tilt: PrivacyKeeper.privacyTilt)])
        #expect(runner.runCount == 1)
        #expect(controller.snapshot.camera == .connected)
        scheduler.advance(by: PTZController.settleDelay)
        #expect(controller.snapshot.tilt == PrivacyKeeper.privacyTilt)
    }

    @Test("La déconnexion du pilote arrête la nacelle")
    func disconnectStops() {
        let controller = makeController()
        _ = controller.handle(.move(pan: 1, tilt: 0), from: 7)
        controller.clientDisconnected(7)
        #expect(!controller.snapshot.moving)
        #expect(camera.relativeCommands.last == .stop)
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd mac/ptzd && swift test --filter PTZControllerTests
```

Échec attendu : la compilation échoue : `cannot find 'PTZController' in scope`.

- [ ] **Étape 3 : Écrire l'implémentation**

`mac/ptzd/Sources/PTZCore/PTZController.swift` :

```swift
import Foundation
import NacelleProtocol

/// Point d'entrée de la logique : traite les messages de l'app, suit la
/// présence de la caméra et publie l'état (spec § 5 et § 6).
@MainActor
public final class PTZController {
    /// Délai avant de relire la position après un déplacement absolu : relue
    /// trop tôt, la caméra renvoie une valeur fausse (spec § 10, question 1).
    public static let settleDelay: TimeInterval = 2

    public private(set) var snapshot: StateSnapshot
    /// Appelé à chaque changement d'état, pour diffusion à tous les clients.
    public var onStateChange: ((StateSnapshot) -> Void)?

    private let camera: any CameraDevice
    private let scheduler: any Scheduler
    private let motion: MotionDriver
    private let zoom: ZoomDriver
    private let privacy: PrivacyKeeper
    private let control: ControlTaker
    private let log: LogSink
    private var settle: (any Cancellable)?

    public init(
        camera: any CameraDevice,
        scheduler: any Scheduler,
        aiOff: any AIOffRunner,
        store: any StateStore,
        settings: MotionSettings,
        isObsbotCenterRunning: @escaping @MainActor () -> Bool,
        log: @escaping LogSink
    ) {
        self.camera = camera
        self.scheduler = scheduler
        self.log = log
        motion = MotionDriver(camera: camera, scheduler: scheduler, settings: settings, log: log)
        zoom = ZoomDriver(camera: camera, scheduler: scheduler, log: log)
        privacy = PrivacyKeeper(camera: camera, store: store, log: log)
        control = ControlTaker(runner: aiOff, isObsbotCenterRunning: isObsbotCenterRunning, log: log)
        snapshot = StateSnapshot(
            camera: camera.isPresent ? .connected : .absent,
            control: .idle,
            privacy: privacy.isActive,
            pan: nil, tilt: nil, zoom: nil,
            moving: false
        )
        motion.onChange = { [weak self] in self?.publish() }
        zoom.onChange = { [weak self] in self?.publish() }
        privacy.onChange = { [weak self] in self?.publish() }
        control.onChange = { [weak self] in self?.publish() }
    }

    /// Traite un message. Renvoie l'erreur à transmettre à ce client, ou nil.
    public func handle(_ message: ClientMessage, from client: ClientID) -> (code: ErrorCode, message: String)? {
        switch message {
        case .takeControl:
            control.take()
            return nil
        case let .move(pan, tilt):
            if privacy.isActive, pan == 0, tilt == 0 {
                return nil
            }
            if let refusal = refusal() {
                return refusal
            }
            return attempt { try motion.move(pan: pan, tilt: tilt, from: client) }
        case let .zoom(value):
            if let refusal = refusal() {
                return refusal
            }
            return attempt { try zoom.set(value) }
        case let .privacy(on):
            guard camera.isPresent else {
                return (.cameraAbsent, "Caméra débranchée.")
            }
            if on {
                return attempt {
                    try? motion.stop()
                    try privacy.enter(currentPosition: motion.position, currentZoom: zoom.value)
                    refreshAfterSettling()
                }
            }
            return attempt {
                try privacy.exit()
                refreshAfterSettling()
            }
        }
    }

    public func clientDisconnected(_ client: ClientID) {
        motion.clientDisconnected(client)
    }

    /// Branchement ou débranchement de la caméra. Au branchement, la vie privée
    /// est réappliquée et le suivi IA recoupé, au cas où la caméra aurait redémarré.
    public func cameraPresenceChanged(_ present: Bool) {
        if present {
            log("Caméra branchée.")
            motion.refreshPosition()
            zoom.refresh()
            if privacy.isActive {
                do {
                    try privacy.enforce()
                    refreshAfterSettling()
                } catch {
                    log("Vie privée non réappliquée : \(error)")
                }
                control.take()
            }
        } else {
            log("Caméra débranchée.")
            settle?.cancel()
            settle = nil
            motion.reset()
            zoom.reset()
        }
        publish()
    }

    private func refreshAfterSettling() {
        settle?.cancel()
        settle = scheduler.schedule(after: Self.settleDelay) { [weak self] in
            guard let self else { return }
            self.settle = nil
            self.motion.refreshPosition()
            self.zoom.refresh()
        }
    }

    private func refusal() -> (code: ErrorCode, message: String)? {
        if !camera.isPresent {
            return (.cameraAbsent, "Caméra débranchée.")
        }
        if privacy.isActive {
            return (.privacyActive, "Vie privée active : commande refusée.")
        }
        return nil
    }

    private func attempt(_ body: () throws -> Void) -> (code: ErrorCode, message: String)? {
        do {
            try body()
            return nil
        } catch CameraError.absent {
            return (.cameraAbsent, "Caméra débranchée.")
        } catch {
            log("Commande UVC refusée : \(error)")
            return (.uvcFailed, "La caméra a refusé la commande (\(error)).")
        }
    }

    private func publish() {
        let next = StateSnapshot(
            camera: camera.isPresent ? .connected : .absent,
            control: control.state,
            privacy: privacy.isActive,
            pan: motion.position?.pan,
            tilt: motion.position?.tilt,
            zoom: zoom.value,
            moving: motion.isMoving
        )
        guard next != snapshot else { return }
        snapshot = next
        onStateChange?(next)
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd mac/ptzd && swift test --filter PTZControllerTests
```

Attendu : `Test run with 11 tests` … `passed`.

Puis la suite complète, pour vérifier qu'aucune tâche précédente n'est cassée :

```bash
cd mac/ptzd && swift test
```

Attendu : 55 tests au total, tous `passed` (somme des lignes `Test run with N tests`).

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

La vérification doit afficher `Aucune donnée locale.` ; sinon, retirer la donnée avant de commiter.

```bash
git add mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift \
    mac/ptzd/Sources/PTZCore/PTZController.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute PTZController : messages, présence de la caméra et état publié

Refus en vie privée ou caméra absente, vie privée réappliquée au
rebranchement, position relue 2 s après un déplacement absolu.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 8 : Lecture et validation de config.json (PTZConfig)

Spec § 6.7. Seule `listenAddress` est obligatoire et doit être une IPv4. Bornes vérifiées : vitesse pan 1–80, tilt 1–120 (limites de la Tiny 2 relevées pendant les tests de faisabilité), sens +1 ou -1.

**Fichiers :**
- Créer : `mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift`
- Créer : `mac/ptzd/Sources/PTZCore/PTZConfig.swift`

**Interfaces :**
- Utilise : `MotionSettings` (tâche 2).
- Produit :
  - `PTZConfig(listenAddress:port: = 1985,panMaxSpeed: = 40,tiltMaxSpeed: = 60,panDirection: = 1,tiltDirection: = 1,aiOffPath: = "bin/obsbot-ai-off")`
  - `PTZConfig.load(from: URL) throws -> PTZConfig`, `validate() throws`, `motion: MotionSettings`, `aiOffURL(relativeTo: URL) -> URL`
  - `ConfigError` : `.missingListenAddress`, `.invalidListenAddress(String)`, `.outOfRange(String)`

- [ ] **Étape 1 : Écrire les tests**

`mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift` :

```swift
import Foundation
import Testing
@testable import PTZCore

@Suite("config.json")
struct PTZConfigTests {
    private func decode(_ json: String) throws -> PTZConfig {
        let config = try JSONDecoder().decode(PTZConfig.self, from: Data(json.utf8))
        try config.validate()
        return config
    }

    @Test("Seule listenAddress est obligatoire ; le reste a ses valeurs par défaut")
    func defaults() throws {
        let config = try decode(#"{"listenAddress":"127.0.0.1"}"#)
        #expect(config == PTZConfig(listenAddress: "127.0.0.1"))
        #expect(config.port == 1985)
        #expect(config.motion == MotionSettings(panMaxSpeed: 40, tiltMaxSpeed: 60, panDirection: 1, tiltDirection: 1))
    }

    @Test("listenAddress absente ou invalide")
    func listenAddress() {
        #expect(throws: ConfigError.missingListenAddress) { try decode("{}") }
        #expect(throws: ConfigError.invalidListenAddress("mac.local")) {
            try decode(#"{"listenAddress":"mac.local"}"#)
        }
    }

    @Test("Bornes des vitesses et des sens")
    func ranges() {
        #expect(throws: ConfigError.outOfRange("panMaxSpeed")) {
            try decode(#"{"listenAddress":"127.0.0.1","panMaxSpeed":81}"#)
        }
        #expect(throws: ConfigError.outOfRange("tiltMaxSpeed")) {
            try decode(#"{"listenAddress":"127.0.0.1","tiltMaxSpeed":0}"#)
        }
        #expect(throws: ConfigError.outOfRange("tiltDirection")) {
            try decode(#"{"listenAddress":"127.0.0.1","tiltDirection":0}"#)
        }
    }

    @Test("Chemin de obsbot-ai-off : relatif au dossier de travail, ou absolu")
    func aiOffURL() {
        let base = URL(fileURLWithPath: "/tmp/ObsbotNacelle")
        #expect(PTZConfig(listenAddress: "127.0.0.1").aiOffURL(relativeTo: base).path == "/tmp/ObsbotNacelle/bin/obsbot-ai-off")
        #expect(PTZConfig(listenAddress: "127.0.0.1", aiOffPath: "/opt/x").aiOffURL(relativeTo: base).path == "/opt/x")
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd mac/ptzd && swift test --filter PTZConfigTests
```

Échec attendu : la compilation échoue : `cannot find 'PTZConfig' in scope`.

- [ ] **Étape 3 : Écrire l'implémentation**

`mac/ptzd/Sources/PTZCore/PTZConfig.swift` :

```swift
import Foundation

public enum ConfigError: Error, Equatable {
    case missingListenAddress
    case invalidListenAddress(String)
    case outOfRange(String)
}

/// Contenu de config.json (spec § 6.7). Seule `listenAddress` est obligatoire.
public struct PTZConfig: Codable, Equatable, Sendable {
    public var listenAddress: String
    public var port: Int
    public var panMaxSpeed: Int
    public var tiltMaxSpeed: Int
    public var panDirection: Int
    public var tiltDirection: Int
    public var aiOffPath: String

    private enum CodingKeys: String, CodingKey {
        case listenAddress, port, panMaxSpeed, tiltMaxSpeed, panDirection, tiltDirection, aiOffPath
    }

    public init(
        listenAddress: String,
        port: Int = 1985,
        panMaxSpeed: Int = 40,
        tiltMaxSpeed: Int = 60,
        panDirection: Int = 1,
        tiltDirection: Int = 1,
        aiOffPath: String = "bin/obsbot-ai-off"
    ) {
        self.listenAddress = listenAddress
        self.port = port
        self.panMaxSpeed = panMaxSpeed
        self.tiltMaxSpeed = tiltMaxSpeed
        self.panDirection = panDirection
        self.tiltDirection = tiltDirection
        self.aiOffPath = aiOffPath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let address = try c.decodeIfPresent(String.self, forKey: .listenAddress), !address.isEmpty else {
            throw ConfigError.missingListenAddress
        }
        self.init(
            listenAddress: address,
            port: try c.decodeIfPresent(Int.self, forKey: .port) ?? 1985,
            panMaxSpeed: try c.decodeIfPresent(Int.self, forKey: .panMaxSpeed) ?? 40,
            tiltMaxSpeed: try c.decodeIfPresent(Int.self, forKey: .tiltMaxSpeed) ?? 60,
            panDirection: try c.decodeIfPresent(Int.self, forKey: .panDirection) ?? 1,
            tiltDirection: try c.decodeIfPresent(Int.self, forKey: .tiltDirection) ?? 1,
            aiOffPath: try c.decodeIfPresent(String.self, forKey: .aiOffPath) ?? "bin/obsbot-ai-off"
        )
    }

    /// Lit et valide config.json.
    public static func load(from url: URL) throws -> PTZConfig {
        let config = try JSONDecoder().decode(PTZConfig.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    /// Bornes de la Tiny 2 : vitesse pan 1–80, tilt 1–120 (test de faisabilité).
    public func validate() throws {
        var address = in_addr()
        guard inet_pton(AF_INET, listenAddress, &address) == 1 else {
            throw ConfigError.invalidListenAddress(listenAddress)
        }
        guard (1...65535).contains(port) else { throw ConfigError.outOfRange("port") }
        guard (1...80).contains(panMaxSpeed) else { throw ConfigError.outOfRange("panMaxSpeed") }
        guard (1...120).contains(tiltMaxSpeed) else { throw ConfigError.outOfRange("tiltMaxSpeed") }
        guard [1, -1].contains(panDirection) else { throw ConfigError.outOfRange("panDirection") }
        guard [1, -1].contains(tiltDirection) else { throw ConfigError.outOfRange("tiltDirection") }
    }

    public var motion: MotionSettings {
        MotionSettings(
            panMaxSpeed: panMaxSpeed,
            tiltMaxSpeed: tiltMaxSpeed,
            panDirection: panDirection,
            tiltDirection: tiltDirection
        )
    }

    /// Chemin absolu de obsbot-ai-off ; un chemin relatif part du dossier de travail.
    public func aiOffURL(relativeTo base: URL) -> URL {
        aiOffPath.hasPrefix("/") ? URL(fileURLWithPath: aiOffPath) : base.appending(path: aiOffPath)
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd mac/ptzd && swift test --filter PTZConfigTests
```

Attendu : `Test run with 4 tests` … `passed`.

Puis la suite complète, pour vérifier qu'aucune tâche précédente n'est cassée :

```bash
cd mac/ptzd && swift test
```

Attendu : 59 tests au total, tous `passed` (somme des lignes `Test run with N tests`).

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

La vérification doit afficher `Aucune donnée locale.` ; sinon, retirer la donnée avant de commiter.

```bash
git add mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift \
    mac/ptzd/Sources/PTZCore/PTZConfig.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute PTZConfig : lecture et validation de config.json

Seule listenAddress est obligatoire ; bornes de vitesse de la Tiny 2.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 9 : Accès USB à la caméra (CUVC, UVCCamera)

Spec § 6.1. Une petite cible C reprend la sonde des tests de faisabilité : requêtes UVC par `DeviceRequestTO`, **sans ouvrir la caméra en exclusivité**, pour que ffmpeg continue de capturer. Elle repère seule l'interface VideoControl et le Camera Terminal dans le descripteur de configuration. L'enveloppe Swift implémente `CameraDevice`, suit les branchements par notifications IOKit et réessaie l'ouverture 5 fois, une fois par seconde, juste après un branchement. Amendement A2 : les ordres absolus sont bornés à la course réellement acceptée (pan ±130°, tilt de -80° à +70°), car la caméra ignore en silence un ordre hors course, pan compris. Seul l'encodage des commandes est testé automatiquement ; l'accès réel est vérifié à la tâche 11.

**Fichiers :**
- Remplacer : `mac/ptzd/Package.swift`
- Créer : `mac/ptzd/Tests/UVCCameraTests/UVCPayloadTests.swift`
- Créer : `mac/ptzd/Sources/CUVC/include/cuvc.h`
- Créer : `mac/ptzd/Sources/CUVC/cuvc.c`
- Créer : `mac/ptzd/Sources/UVCCamera/UVCPayload.swift`
- Créer : `mac/ptzd/Sources/UVCCamera/USBPresenceWatcher.swift`
- Créer : `mac/ptzd/Sources/UVCCamera/UVCCamera.swift`

**Interfaces :**
- Utilise : `CameraDevice`, `PanTiltRelative`, `PanTiltPosition`, `CameraError`, `LogSink` (tâche 2).
- Produit :
  - C : `cuvc_open(vendor_id, product_id, &error) -> cuvc_device *`, `cuvc_close(device)`, `cuvc_camera_control(device, request, selector, data, length) -> int32_t`
  - `@MainActor public final class UVCCamera: CameraDevice` : `init(vendorID: = 0x3564, productID: = 0xFEF8, log:)`, `onPresenceChange: ((Bool) -> Void)?`, `startWatching()`
  - `UVCPayload` (interne) : encodage et décodage PanTilt absolu, PanTilt en vitesse, zoom

- [ ] **Étape 1 : Mettre à jour le manifeste et écrire les tests**

Remplacer tout le contenu de `mac/ptzd/Package.swift` :

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ptzd",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/NacelleProtocol"),
    ],
    targets: [
        .target(
            name: "CUVC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "PTZCore",
            dependencies: [.product(name: "NacelleProtocol", package: "NacelleProtocol")]
        ),
        .target(name: "UVCCamera", dependencies: ["CUVC", "PTZCore"]),
        .testTarget(name: "PTZCoreTests", dependencies: ["PTZCore"]),
        .testTarget(name: "UVCCameraTests", dependencies: ["UVCCamera"]),
    ]
)
```

`mac/ptzd/Tests/UVCCameraTests/UVCPayloadTests.swift` :

```swift
import PTZCore
import Testing
@testable import UVCCamera

@Suite("Encodage UVC")
struct UVCPayloadTests {
    @Test("PanTilt absolu : secondes d'arc, int32 petit-boutiste")
    func panTiltAbsolute() {
        // 30° = 108000 = 0x0001A5E0 ; -20° = -72000 = 0xFFFEE6C0
        #expect(UVCPayload.panTiltAbsolute(panDegrees: 30, tiltDegrees: -20)
            == [0xE0, 0xA5, 0x01, 0x00, 0xC0, 0xE6, 0xFE, 0xFF])
    }

    @Test("PanTilt absolu : borné à la course réellement acceptée, arrondi au degré")
    func panTiltAbsoluteClamped() {
        let low = UVCPayload.panTiltAbsolute(panDegrees: 500, tiltDegrees: -90)
        #expect(UVCPayload.decodePanTiltAbsolute(low) == PanTiltPosition(pan: 130, tilt: -80))
        let high = UVCPayload.panTiltAbsolute(panDegrees: -500, tiltDegrees: 89)
        #expect(UVCPayload.decodePanTiltAbsolute(high) == PanTiltPosition(pan: -130, tilt: 70))
        #expect(UVCPayload.decodePanTiltAbsolute(UVCPayload.panTiltAbsolute(panDegrees: 12.4, tiltDegrees: -69.6))
            == PanTiltPosition(pan: 12, tilt: -70))
        #expect(UVCPayload.decodePanTiltAbsolute(UVCPayload.panTiltAbsolute(panDegrees: .nan, tiltDegrees: 0))
            == PanTiltPosition(pan: 0, tilt: 0))
    }

    @Test("PanTilt absolu : décodage")
    func decodePanTilt() {
        #expect(UVCPayload.decodePanTiltAbsolute([0x20, 0x1C, 0x00, 0x00, 0xF0, 0xF1, 0xFF, 0xFF])
            == PanTiltPosition(pan: 2, tilt: -1))
    }

    @Test("PanTilt en vitesse : sens signés sur un octet")
    func panTiltRelative() {
        let command = PanTiltRelative(panDirection: -1, panSpeed: 40, tiltDirection: 1, tiltSpeed: 60)
        #expect(UVCPayload.panTiltRelative(command) == [0xFF, 40, 0x01, 60])
        #expect(UVCPayload.panTiltRelative(.stop) == [0, 1, 0, 1])
    }

    @Test("Zoom : 2 octets, borné à 0…100")
    func zoom() {
        #expect(UVCPayload.zoomAbsolute(33) == [33, 0])
        #expect(UVCPayload.zoomAbsolute(250) == [100, 0])
        #expect(UVCPayload.zoomAbsolute(-3) == [0, 0])
        #expect(UVCPayload.decodeZoom([0x64, 0x00]) == 100)
    }
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd mac/ptzd && swift test --filter UVCPayloadTests
```

Échec attendu : la compilation échoue : les cibles `CUVC` et `UVCCamera` n'ont pas encore de sources.

- [ ] **Étape 3 : Écrire l'implémentation**

`mac/ptzd/Sources/CUVC/include/cuvc.h` :

```c
#ifndef CUVC_H
#define CUVC_H

#include <stdint.h>

/// Accès aux commandes UVC d'une caméra USB, sans ouverture exclusive :
/// le pilote vidéo d'Apple et ffmpeg continuent de capturer.
typedef struct cuvc_device cuvc_device;

/// Ouvre la caméra (VID/PID) et repère son Camera Terminal.
/// Renvoie NULL si elle est absente ; *error reçoit alors le code IOKit.
cuvc_device *cuvc_open(uint16_t vendor_id, uint16_t product_id, int32_t *error);

void cuvc_close(cuvc_device *device);

/// Requête de classe sur le Camera Terminal. request vaut 0x01 (SET_CUR)
/// ou 0x81…0x87 (GET_CUR…GET_DEF). Renvoie le code IOKit, 0 en cas de succès.
int32_t cuvc_camera_control(cuvc_device *device, uint8_t request, uint8_t selector,
                            void *data, uint16_t length);

#endif
```

`mac/ptzd/Sources/CUVC/cuvc.c` :

```c
#include "cuvc.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>

struct cuvc_device {
    IOUSBDeviceInterface245 **interface;
    uint8_t video_control_interface;
    uint8_t camera_terminal;
};

static IOReturn device_request(IOUSBDeviceInterface245 **interface, uint8_t type, uint8_t request,
                               uint16_t value, uint16_t index, void *data, uint16_t length,
                               uint32_t *transferred) {
    IOUSBDevRequestTO rq = {0};
    rq.bmRequestType = type;
    rq.bRequest = request;
    rq.wValue = value;
    rq.wIndex = index;
    rq.wLength = length;
    rq.pData = data;
    rq.noDataTimeout = 1000;
    rq.completionTimeout = 1000;
    IOReturn result = (*interface)->DeviceRequestTO(interface, &rq);
    if (transferred) {
        *transferred = rq.wLenDone;
    }
    return result;
}

/// Lit le descripteur de configuration ; repère l'interface VideoControl
/// (classe 0x0E, sous-classe 1) et son Camera Terminal (type 0x0201).
static IOReturn find_camera_terminal(cuvc_device *device) {
    uint8_t header[9];
    uint32_t transferred = 0;
    IOReturn result = device_request(device->interface, 0x80, 6, 0x0200, 0, header, sizeof header, &transferred);
    if (result != kIOReturnSuccess) {
        return result;
    }
    uint16_t total = (uint16_t)(header[2] | header[3] << 8);
    uint8_t *buffer = malloc(total);
    if (!buffer) {
        return kIOReturnNoMemory;
    }
    result = device_request(device->interface, 0x80, 6, 0x0200, 0, buffer, total, &transferred);
    if (result != kIOReturnSuccess) {
        free(buffer);
        return result;
    }
    int found = 0;
    int interface_number = -1, interface_class = -1, interface_subclass = -1;
    for (uint32_t i = 0; i + 2 <= transferred && buffer[i] > 0; i += buffer[i]) {
        uint8_t type = buffer[i + 1];
        if (type == 4 && i + 7 <= transferred) {
            interface_number = buffer[i + 2];
            interface_class = buffer[i + 5];
            interface_subclass = buffer[i + 6];
        } else if (type == 0x24 && interface_class == 0x0E && interface_subclass == 1 && i + 6 <= transferred
                   && buffer[i + 2] == 2 && (buffer[i + 4] | buffer[i + 5] << 8) == 0x0201) {
            device->video_control_interface = (uint8_t)interface_number;
            device->camera_terminal = buffer[i + 3];
            found = 1;
            break;
        }
    }
    free(buffer);
    return found ? kIOReturnSuccess : kIOReturnNotFound;
}

cuvc_device *cuvc_open(uint16_t vendor_id, uint16_t product_id, int32_t *error) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    int vendor = vendor_id, product = product_id;
    CFNumberRef vendor_number = CFNumberCreate(NULL, kCFNumberIntType, &vendor);
    CFNumberRef product_number = CFNumberCreate(NULL, kCFNumberIntType, &product);
    CFDictionarySetValue(matching, CFSTR("idVendor"), vendor_number);
    CFDictionarySetValue(matching, CFSTR("idProduct"), product_number);
    CFRelease(vendor_number);
    CFRelease(product_number);

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) {
        if (error) *error = kIOReturnNotFound;
        return NULL;
    }
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                        kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (result != kIOReturnSuccess || !plugin) {
        if (error) *error = result != kIOReturnSuccess ? result : kIOReturnError;
        return NULL;
    }
    IOUSBDeviceInterface245 **interface = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID245), (LPVOID *)&interface);
    IODestroyPlugInInterface(plugin);
    if (!interface) {
        if (error) *error = kIOReturnUnsupported;
        return NULL;
    }
    cuvc_device *device = calloc(1, sizeof *device);
    if (!device) {
        (*interface)->Release(interface);
        if (error) *error = kIOReturnNoMemory;
        return NULL;
    }
    device->interface = interface;
    result = find_camera_terminal(device);
    if (result != kIOReturnSuccess) {
        cuvc_close(device);
        if (error) *error = result;
        return NULL;
    }
    if (error) *error = kIOReturnSuccess;
    return device;
}

void cuvc_close(cuvc_device *device) {
    if (!device) {
        return;
    }
    if (device->interface) {
        (*device->interface)->Release(device->interface);
    }
    free(device);
}

int32_t cuvc_camera_control(cuvc_device *device, uint8_t request, uint8_t selector,
                            void *data, uint16_t length) {
    if (!device) {
        return kIOReturnNotAttached;
    }
    uint8_t type = (request & 0x80) ? 0xA1 : 0x21;
    uint16_t index = (uint16_t)(device->camera_terminal << 8 | device->video_control_interface);
    return device_request(device->interface, type, request, (uint16_t)(selector << 8), index, data, length, NULL);
}
```

`mac/ptzd/Sources/UVCCamera/UVCPayload.swift` :

```swift
import PTZCore

/// Encodage des commandes du Camera Terminal (norme UVC 1.5).
enum UVCPayload {
    static let getCurrent: UInt8 = 0x81
    static let setCurrent: UInt8 = 0x01
    static let selectorZoomAbsolute: UInt8 = 0x0B
    static let selectorPanTiltAbsolute: UInt8 = 0x0D
    static let selectorPanTiltRelative: UInt8 = 0x0E

    /// Course réellement acceptée par la Tiny 2 (mesurée le 2026-10-05) : pan ±130°,
    /// tilt de -80° à +70°. Elle annonce ±90° en UVC, mais ignore en silence un ordre
    /// à -90° ou +89°, pan compris : on borne donc avant d'envoyer.
    static let panRange: ClosedRange<Double> = -130...130
    static let tiltRange: ClosedRange<Double> = -80...70

    /// 8 octets : pan puis tilt, en secondes d'arc, int32 petit-boutiste, par pas de 1°.
    static func panTiltAbsolute(panDegrees: Double, tiltDegrees: Double) -> [UInt8] {
        littleEndian(arcSeconds(panDegrees, range: panRange)) + littleEndian(arcSeconds(tiltDegrees, range: tiltRange))
    }

    static func decodePanTiltAbsolute(_ bytes: [UInt8]) -> PanTiltPosition {
        PanTiltPosition(pan: Double(int32(bytes, at: 0)) / 3600, tilt: Double(int32(bytes, at: 4)) / 3600)
    }

    /// 4 octets : sens pan, vitesse pan, sens tilt, vitesse tilt.
    static func panTiltRelative(_ command: PanTiltRelative) -> [UInt8] {
        [
            UInt8(bitPattern: command.panDirection), command.panSpeed,
            UInt8(bitPattern: command.tiltDirection), command.tiltSpeed,
        ]
    }

    /// 2 octets petit-boutistes, borné à 0…100.
    static func zoomAbsolute(_ value: Int) -> [UInt8] {
        let clamped = UInt16(min(max(value, 0), 100))
        return [UInt8(clamped & 0xFF), UInt8(clamped >> 8)]
    }

    static func decodeZoom(_ bytes: [UInt8]) -> Int {
        Int(UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
    }

    private static func arcSeconds(_ degrees: Double, range: ClosedRange<Double>) -> Int32 {
        guard degrees.isFinite else { return 0 }
        return Int32(min(max(degrees, range.lowerBound), range.upperBound).rounded()) * 3600
    }

    private static func littleEndian(_ value: Int32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private static func int32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        let raw = UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
        return Int32(bitPattern: raw)
    }
}
```

`mac/ptzd/Sources/UVCCamera/USBPresenceWatcher.swift` :

```swift
import Foundation
import IOKit

/// Suit l'arrivée et le départ d'un périphérique USB, par notifications IOKit
/// sur la file principale.
@MainActor
final class USBPresenceWatcher {
    private let vendorID: Int
    private let productID: Int
    private let onChange: @MainActor (Bool) -> Void
    private var port: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0

    init(vendorID: Int, productID: Int, onChange: @escaping @MainActor (Bool) -> Void) {
        self.vendorID = vendorID
        self.productID = productID
        self.onChange = onChange
    }

    /// Arme les notifications puis signale tout de suite la présence actuelle.
    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching(), { context, iterator in
            guard let context else { return }
            let watcher = Unmanaged<USBPresenceWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.drain(iterator, attached: true) }
        }, context, &matchedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching(), { context, iterator in
            guard let context else { return }
            let watcher = Unmanaged<USBPresenceWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.drain(iterator, attached: false) }
        }, context, &terminatedIterator)
        drain(terminatedIterator, attached: false)
        drain(matchedIterator, attached: true)
    }

    private func matching() -> CFDictionary {
        let dictionary = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        dictionary["idVendor"] = vendorID
        dictionary["idProduct"] = productID
        return dictionary
    }

    /// Vide l'itérateur (ce qui réarme la notification) et signale s'il contenait quelque chose.
    private func drain(_ iterator: io_iterator_t, attached: Bool) {
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            found = true
        }
        if found {
            onChange(attached)
        }
    }
}
```

`mac/ptzd/Sources/UVCCamera/UVCCamera.swift` :

```swift
import CUVC
import Foundation
import PTZCore

/// La Tiny 2 vue à travers ses commandes UVC, sans ouverture exclusive.
@MainActor
public final class UVCCamera: CameraDevice {
    public static let tiny2VendorID: UInt16 = 0x3564
    public static let tiny2ProductID: UInt16 = 0xFEF8
    static let openRetries = 5
    static let openRetryDelay: TimeInterval = 1

    /// Appelé quand la caméra devient utilisable ou cesse de l'être.
    public var onPresenceChange: ((Bool) -> Void)?

    private let vendorID: UInt16
    private let productID: UInt16
    private let log: LogSink
    private var device: OpaquePointer?
    private var watcher: USBPresenceWatcher?
    private var attached = false

    public init(
        vendorID: UInt16 = UVCCamera.tiny2VendorID,
        productID: UInt16 = UVCCamera.tiny2ProductID,
        log: @escaping LogSink
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.log = log
    }

    public var isPresent: Bool {
        device != nil
    }

    /// Ouvre la caméra si elle est branchée, puis suit ses branchements.
    public func startWatching() {
        let watcher = USBPresenceWatcher(vendorID: Int(vendorID), productID: Int(productID)) { [weak self] attached in
            self?.attachmentChanged(attached)
        }
        self.watcher = watcher
        watcher.start()
    }

    public func setPanTiltRelative(_ command: PanTiltRelative) throws {
        try set(UVCPayload.selectorPanTiltRelative, UVCPayload.panTiltRelative(command))
    }

    public func setPanTiltAbsolute(panDegrees: Double, tiltDegrees: Double) throws {
        try set(UVCPayload.selectorPanTiltAbsolute, UVCPayload.panTiltAbsolute(panDegrees: panDegrees, tiltDegrees: tiltDegrees))
    }

    public func setZoom(_ value: Int) throws {
        try set(UVCPayload.selectorZoomAbsolute, UVCPayload.zoomAbsolute(value))
    }

    public func readPanTilt() throws -> PanTiltPosition {
        UVCPayload.decodePanTiltAbsolute(try get(UVCPayload.selectorPanTiltAbsolute, length: 8))
    }

    public func readZoom() throws -> Int {
        UVCPayload.decodeZoom(try get(UVCPayload.selectorZoomAbsolute, length: 2))
    }

    private func attachmentChanged(_ nowAttached: Bool) {
        attached = nowAttached
        if nowAttached {
            open(retriesLeft: Self.openRetries)
        } else if device != nil {
            cuvc_close(device)
            device = nil
            onPresenceChange?(false)
        }
    }

    /// Juste après le branchement, la caméra peut ne pas répondre encore : on réessaie.
    private func open(retriesLeft: Int) {
        guard attached, device == nil else { return }
        var error: Int32 = 0
        if let opened = cuvc_open(vendorID, productID, &error) {
            device = opened
            onPresenceChange?(true)
            return
        }
        guard retriesLeft > 0 else {
            log("Caméra branchée mais commandes UVC inaccessibles (code \(Self.hex(error))).")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openRetryDelay) { [weak self] in
            MainActor.assumeIsolated { self?.open(retriesLeft: retriesLeft - 1) }
        }
    }

    private func set(_ selector: UInt8, _ payload: [UInt8]) throws {
        guard let device else { throw CameraError.absent }
        var bytes = payload
        let result = bytes.withUnsafeMutableBytes { buffer in
            cuvc_camera_control(device, UVCPayload.setCurrent, selector, buffer.baseAddress, UInt16(buffer.count))
        }
        guard result == 0 else { throw CameraError.ioKit(result) }
    }

    private func get(_ selector: UInt8, length: Int) throws -> [UInt8] {
        guard let device else { throw CameraError.absent }
        var bytes = [UInt8](repeating: 0, count: length)
        let result = bytes.withUnsafeMutableBytes { buffer in
            cuvc_camera_control(device, UVCPayload.getCurrent, selector, buffer.baseAddress, UInt16(buffer.count))
        }
        guard result == 0 else { throw CameraError.ioKit(result) }
        return bytes
    }

    static func hex(_ code: Int32) -> String {
        String(format: "0x%08x", UInt32(bitPattern: code))
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd mac/ptzd && swift test --filter UVCPayloadTests
```

Attendu : `Test run with 5 tests` … `passed`.

Puis la suite complète, pour vérifier qu'aucune tâche précédente n'est cassée :

```bash
cd mac/ptzd && swift test
```

Attendu : 64 tests au total, tous `passed` (somme des lignes `Test run with N tests`).

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

La vérification doit afficher `Aucune donnée locale.` ; sinon, retirer la donnée avant de commiter.

```bash
git add mac/ptzd/Package.swift \
    mac/ptzd/Tests/UVCCameraTests/UVCPayloadTests.swift \
    mac/ptzd/Sources/CUVC/include/cuvc.h \
    mac/ptzd/Sources/CUVC/cuvc.c \
    mac/ptzd/Sources/UVCCamera/UVCPayload.swift \
    mac/ptzd/Sources/UVCCamera/USBPresenceWatcher.swift \
    mac/ptzd/Sources/UVCCamera/UVCCamera.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute l'accès USB : commandes UVC sans ouverture exclusive

Cible C reprise de la sonde des tests de faisabilité ; UVCCamera suit les
branchements par notifications IOKit.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 10 : Serveur WebSocket (PTZServer)

Spec § 6.1 et § 6.10, avec l'amendement A1 : une écoute `NWListener` par adresse précise (l'adresse Tailscale et 127.0.0.1, jamais 0.0.0.0 ; une adresse en double n'est écoutée qu'une fois), 4 clients au plus en tout, état complet envoyé à chaque connexion puis diffusé à chaque changement. Une adresse absente (Tailscale pas encore démarré) est réessayée toutes les 5 s. Vérifié le 2026-10-05 : un `NWListener` lié à l'adresse Tailscale est joignable depuis l'iPhone, mais pas depuis le Mac lui-même ; d'où 127.0.0.1 pour les essais locaux.

**Fichiers :**
- Remplacer : `mac/ptzd/Package.swift`
- Créer : `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift`
- Créer : `mac/ptzd/Sources/PTZServer/WebSocketServer.swift`

**Interfaces :**
- Utilise : `PTZController` (tâche 7), `Scheduler`, `LogSink` (tâche 2), `NacelleCodec`, `ClientMessage`, `ServerMessage` (tâche 1).
- Produit :
  - `@MainActor public final class WebSocketServer(hosts: [String], port: UInt16, controller:scheduler:log:)`
  - `WebSocketServer.maxClients = 4`, `WebSocketServer.retryDelay = 5`
  - `onReady: ((_ host: String, _ port: UInt16) -> Void)?`, `start()`

- [ ] **Étape 1 : Mettre à jour le manifeste et écrire les tests**

Remplacer tout le contenu de `mac/ptzd/Package.swift` :

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ptzd",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/NacelleProtocol"),
    ],
    targets: [
        .target(
            name: "CUVC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "PTZCore",
            dependencies: [.product(name: "NacelleProtocol", package: "NacelleProtocol")]
        ),
        .target(name: "UVCCamera", dependencies: ["CUVC", "PTZCore"]),
        .target(
            name: "PTZServer",
            dependencies: ["PTZCore", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
        ),
        .testTarget(name: "PTZCoreTests", dependencies: ["PTZCore"]),
        .testTarget(name: "UVCCameraTests", dependencies: ["UVCCamera"]),
        .testTarget(
            name: "PTZServerTests",
            dependencies: ["PTZServer", "PTZCore", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
        ),
    ]
)
```

`mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift` :

```swift
import Foundation
import NacelleProtocol
import PTZCore
import Testing
@testable import PTZServer

@MainActor
@Suite("Serveur WebSocket", .serialized, .timeLimit(.minutes(1)))
struct WebSocketServerTests {
    let camera = StubCamera()
    let controller: PTZController

    init() {
        controller = PTZController(
            camera: camera,
            scheduler: DispatchScheduler(),
            aiOff: StubAIOff(),
            store: StubStore(),
            settings: MotionSettings(),
            isObsbotCenterRunning: { false },
            log: { _ in }
        )
    }

    /// Démarre un serveur sur ces adresses (port 0 : choisi par le système) et
    /// renvoie le port ouvert sur chacune.
    private func startServer(on hosts: [String] = ["127.0.0.1"]) async -> (WebSocketServer, [String: UInt16]) {
        let server = WebSocketServer(hosts: hosts, port: 0, controller: controller, scheduler: DispatchScheduler(), log: { _ in })
        let ports = await withCheckedContinuation { continuation in
            var ready: [String: UInt16] = [:]
            server.onReady = { host, port in
                ready[host] = port
                if ready.count == hosts.count {
                    continuation.resume(returning: ready)
                }
            }
            server.start()
        }
        return (server, ports)
    }

    private func connect(_ host: String, _ port: UInt16) -> URLSessionWebSocketTask {
        let authority = host.contains(":") ? "[\(host)]" : host
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://\(authority):\(port)")!)
        task.resume()
        return task
    }

    /// Lit les messages jusqu'au premier qui satisfait la condition.
    private func next(_ task: URLSessionWebSocketTask, where matches: (ServerMessage) -> Bool) async throws -> ServerMessage {
        while true {
            guard case let .string(text) = try await task.receive() else { continue }
            let message = try NacelleCodec.decodeServer(text)
            if matches(message) {
                return message
            }
        }
    }

    @Test("État envoyé à la connexion ; move appliqué ; message illisible signalé")
    func roundTrip() async throws {
        let (server, ports) = await startServer()
        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let first = try await next(task) { _ in true }
        guard case let .state(snapshot) = first else {
            Issue.record("état attendu, reçu \(first)")
            return
        }
        #expect(snapshot.camera == .connected)

        try await task.send(.string(try NacelleCodec.encode(ClientMessage.move(pan: 1, tilt: 0))))
        _ = try await next(task) { if case let .state(s) = $0 { s.moving } else { false } }
        #expect(camera.relativeCommands.first?.panDirection == 1)

        try await task.send(.string("pas du json"))
        let error = try await next(task) { if case .error = $0 { true } else { false } }
        #expect(error == .error(code: .badMessage, message: "Message illisible."))
        withExtendedLifetime(server) {}
    }

    @Test("Deux adresses, un seul contrôleur : l'état est diffusé aux clients des deux")
    func twoHosts() async throws {
        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"])
        let first = connect("127.0.0.1", ports["127.0.0.1"]!)
        let second = connect("::1", ports["::1"]!)
        defer { [first, second].forEach { $0.cancel(with: .goingAway, reason: nil) } }
        _ = try await next(first) { _ in true }
        _ = try await next(second) { _ in true }

        try await first.send(.string(try NacelleCodec.encode(ClientMessage.move(pan: 1, tilt: 0))))
        let seen = try await next(second) { if case let .state(s) = $0 { s.moving } else { false } }
        guard case let .state(snapshot) = seen else { return }
        #expect(snapshot.moving)
        withExtendedLifetime(server) {}
    }

    @Test("Une adresse en double n'est écoutée qu'une fois")
    func duplicateHosts() async throws {
        let server = WebSocketServer(hosts: ["127.0.0.1", "127.0.0.1"], port: 0, controller: controller, scheduler: DispatchScheduler(), log: { _ in })
        var readyCount = 0
        server.onReady = { _, _ in readyCount += 1 }
        server.start()
        try await Task.sleep(for: .milliseconds(500))
        #expect(readyCount == 1)
        withExtendedLifetime(server) {}
    }

    @Test("Au-delà de 4 clients, la connexion est refusée")
    func maxClients() async throws {
        let (server, ports) = await startServer()
        let port = ports["127.0.0.1"]!
        var tasks: [URLSessionWebSocketTask] = []
        for _ in 0..<WebSocketServer.maxClients {
            let task = connect("127.0.0.1", port)
            _ = try await next(task) { _ in true }
            tasks.append(task)
        }
        let extra = connect("127.0.0.1", port)
        await #expect(throws: (any Error).self) {
            _ = try await extra.receive()
        }
        (tasks + [extra]).forEach { $0.cancel(with: .goingAway, reason: nil) }
        withExtendedLifetime(server) {}
    }
}

@MainActor
final class StubCamera: CameraDevice {
    var isPresent = true
    private(set) var relativeCommands: [PanTiltRelative] = []

    func setPanTiltRelative(_ command: PanTiltRelative) throws {
        relativeCommands.append(command)
    }

    func setPanTiltAbsolute(panDegrees: Double, tiltDegrees: Double) throws {}
    func setZoom(_ value: Int) throws {}

    func readPanTilt() throws -> PanTiltPosition {
        PanTiltPosition(pan: 0, tilt: 0)
    }

    func readZoom() throws -> Int {
        0
    }
}

@MainActor
final class StubAIOff: AIOffRunner {
    func run(completion: @escaping @MainActor @Sendable (AIOffResult) -> Void) {
        completion(.success)
    }
}

final class StubStore: StateStore {
    func load() -> PersistedState {
        PersistedState(privacy: false, saved: nil)
    }

    func save(_ state: PersistedState) throws {}
}
```

- [ ] **Étape 2 : Lancer les tests, constater l'échec**

```bash
cd mac/ptzd && swift test --filter WebSocketServerTests
```

Échec attendu : la compilation échoue : la cible `PTZServer` n'a pas encore de sources.

- [ ] **Étape 3 : Écrire l'implémentation**

`mac/ptzd/Sources/PTZServer/WebSocketServer.swift` :

```swift
import Foundation
import NacelleProtocol
import Network
import PTZCore

/// Serveur WebSocket de ptzd : quelques adresses précises (jamais 0.0.0.0),
/// 4 clients au plus en tout (spec § 6.1 et § 6.10).
@MainActor
public final class WebSocketServer {
    public static let maxClients = 4
    public static let retryDelay: TimeInterval = 5

    /// Appelé quand l'écoute sur une adresse est prête, avec le port réellement
    /// ouvert (utile quand on demande le port 0).
    public var onReady: ((_ host: String, _ port: UInt16) -> Void)?

    private let hosts: [String]
    private let port: UInt16
    private let controller: PTZController
    private let scheduler: any Scheduler
    private let log: LogSink
    private var listeners: [String: NWListener] = [:]
    private var connections: [ClientID: NWConnection] = [:]
    private var nextID: ClientID = 1

    /// Les adresses en double ne sont écoutées qu'une fois (config.json peut déjà contenir 127.0.0.1).
    public init(hosts: [String], port: UInt16, controller: PTZController, scheduler: any Scheduler, log: @escaping LogSink) {
        self.hosts = hosts.reduce(into: []) { unique, host in
            if !unique.contains(host) {
                unique.append(host)
            }
        }
        self.port = port
        self.controller = controller
        self.scheduler = scheduler
        self.log = log
        controller.onStateChange = { [weak self] snapshot in
            self?.broadcast(.state(snapshot))
        }
    }

    /// Ouvre l'écoute sur chaque adresse. En cas d'échec (adresse Tailscale pas
    /// encore là), réessaie toutes les 5 s pour cette adresse.
    public func start() {
        for host in hosts {
            listen(on: host)
        }
    }

    private func listen(on host: String) {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            retryLater(host, after: error)
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(host, state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listeners[host] = listener
        listener.start(queue: .main)
    }

    private func listenerChanged(_ host: String, _ state: NWListener.State) {
        switch state {
        case .ready:
            let actual = listeners[host]?.port?.rawValue ?? port
            log("En écoute sur \(host):\(actual).")
            onReady?(host, actual)
        case let .failed(error), let .waiting(error):
            listeners.removeValue(forKey: host)?.cancel()
            retryLater(host, after: error)
        default:
            break
        }
    }

    private func retryLater(_ host: String, after error: any Error) {
        log("Écoute sur \(host):\(port) impossible (\(error)). Nouvel essai dans 5 s.")
        scheduler.schedule(after: Self.retryDelay) { [weak self] in
            self?.listen(on: host)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxClients else {
            log("Connexion refusée : déjà \(Self.maxClients) clients.")
            connection.cancel()
            return
        }
        let id = nextID
        nextID += 1
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connectionChanged(id, state) }
        }
        connection.start(queue: .main)
        receive(on: connection, id: id)
    }

    private func connectionChanged(_ id: ClientID, _ state: NWConnection.State) {
        switch state {
        case .ready:
            send(.state(controller.snapshot), to: id)
        case .failed, .cancelled:
            drop(id)
        default:
            break
        }
    }

    private func receive(on connection: NWConnection, id: ClientID) {
        connection.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self, self.connections[id] != nil else { return }
                if error != nil || context?.isFinal == true {
                    self.drop(id)
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close {
                    self.drop(id)
                    return
                }
                if metadata?.opcode == .text, let content, let text = String(data: content, encoding: .utf8) {
                    self.process(text, from: id)
                }
                self.receive(on: connection, id: id)
            }
        }
    }

    private func process(_ text: String, from id: ClientID) {
        let message: ClientMessage
        do {
            message = try NacelleCodec.decodeClient(text)
        } catch {
            send(.error(code: .badMessage, message: "Message illisible."), to: id)
            return
        }
        if let failure = controller.handle(message, from: id) {
            send(.error(code: failure.code, message: failure.message), to: id)
        }
    }

    private func drop(_ id: ClientID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.cancel()
        controller.clientDisconnected(id)
    }

    private func broadcast(_ message: ServerMessage) {
        for id in connections.keys {
            send(message, to: id)
        }
    }

    private func send(_ message: ServerMessage, to id: ClientID) {
        guard let connection = connections[id], let text = try? NacelleCodec.encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "nacelle", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}
```

- [ ] **Étape 4 : Lancer les tests, constater le succès**

```bash
cd mac/ptzd && swift test --filter WebSocketServerTests
```

Attendu : `Test run with 4 tests` … `passed`.

Puis la suite complète, pour vérifier qu'aucune tâche précédente n'est cassée :

```bash
cd mac/ptzd && swift test
```

Attendu : 68 tests au total, tous `passed` (somme des lignes `Test run with N tests`).

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

La vérification doit afficher `Aucune donnée locale.` ; sinon, retirer la donnée avant de commiter.

```bash
git add mac/ptzd/Package.swift \
    mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift \
    mac/ptzd/Sources/PTZServer/WebSocketServer.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute le serveur WebSocket de ptzd

Une écoute par adresse précise (Tailscale et 127.0.0.1), 4 clients au plus,
état diffusé à chaque changement, nouvel essai toutes les 5 s.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 11 : Exécutable ptzd et commandes d'étalonnage

Le point d'entrée assemble les modules : lit `config.json`, ouvre la caméra, démarre le serveur sur l'adresse Tailscale **et 127.0.0.1** (amendement A1), puis rend la main à `dispatchMain()`. Le journal va à la fois dans le journal système (`os.Logger`, sous-système `io.github.djoko-cli.obsbot-nacelle`) et sur la sortie standard, que launchd redirige. `PTZD_SUPPORT_DIR` remplace le dossier de travail pour les essais (tâche 13). La sous-commande `ptzd uvc …` envoie des commandes directes à la caméra, pour l'étalonnage et le diagnostic.

**Fichiers :**
- Remplacer : `mac/ptzd/Package.swift`
- Créer : `mac/ptzd/Sources/ptzd/PTZDaemon.swift`
- Créer : `mac/ptzd/Sources/ptzd/UVCDebugCommand.swift`

**Interfaces :**
- Utilise : `PTZConfig` (tâche 8), `PTZController`, `DispatchScheduler`, `ProcessAIOffRunner`, `JSONFileStateStore` (tâches 2 à 7), `UVCCamera` (tâche 9), `WebSocketServer` (tâche 10).
- Produit : l'exécutable `ptzd` ; `ptzd uvc get | pt <pan°> <tilt°> | rel <sens pan> <vitesse pan> <sens tilt> <vitesse tilt> | zoom <0-100>` ; code de sortie 78 si `config.json` est absent ou invalide.

Pas de test automatique pour cette tâche : elle ne fait qu'assembler des modules testés. Les vérifications se font sur la vraie caméra (étapes 4 et 5).

- [ ] **Étape 1 : Mettre à jour le manifeste**

Remplacer tout le contenu de `mac/ptzd/Package.swift` :

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ptzd",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/NacelleProtocol"),
    ],
    targets: [
        .target(
            name: "CUVC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "PTZCore",
            dependencies: [.product(name: "NacelleProtocol", package: "NacelleProtocol")]
        ),
        .target(name: "UVCCamera", dependencies: ["CUVC", "PTZCore"]),
        .target(
            name: "PTZServer",
            dependencies: ["PTZCore", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
        ),
        .executableTarget(name: "ptzd", dependencies: ["PTZCore", "UVCCamera", "PTZServer"]),
        .testTarget(name: "PTZCoreTests", dependencies: ["PTZCore"]),
        .testTarget(name: "UVCCameraTests", dependencies: ["UVCCamera"]),
        .testTarget(
            name: "PTZServerTests",
            dependencies: ["PTZServer", "PTZCore", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
        ),
    ]
)
```

- [ ] **Étape 2 : Écrire l'exécutable**

`mac/ptzd/Sources/ptzd/PTZDaemon.swift` :

```swift
import AppKit
import Foundation
import os
import PTZCore
import PTZServer
import UVCCamera

@main
struct PTZDaemon {
    /// Dossier de travail (spec § 6.7). PTZD_SUPPORT_DIR le remplace pour les essais.
    static let supportDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["PTZD_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ObsbotNacelle")
    }()

    /// Journaux (spec § 6.7) ; sous PTZD_SUPPORT_DIR pendant les essais.
    static let logsDirectory: URL = {
        if ProcessInfo.processInfo.environment["PTZD_SUPPORT_DIR"] != nil {
            return supportDirectory.appending(path: "logs")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/obsbot-nacelle")
    }()
    static let logger = Logger(subsystem: "io.github.djoko-cli.obsbot-nacelle", category: "ptzd")

    /// Une ligne dans le journal système et sur la sortie standard (redirigée par launchd).
    nonisolated static func write(_ line: String) {
        logger.log("\(line, privacy: .public)")
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    @MainActor
    static func main() {
        let log: LogSink = { write($0) }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "uvc" {
            exit(UVCDebugCommand.run(Array(arguments.dropFirst()), log: log))
        }

        let config: PTZConfig
        do {
            config = try PTZConfig.load(from: supportDirectory.appending(path: "config.json"))
        } catch {
            log("config.json absent ou invalide : \(error)")
            exit(78)
        }

        let scheduler = DispatchScheduler()
        let camera = UVCCamera(log: log)
        let controller = PTZController(
            camera: camera,
            scheduler: scheduler,
            aiOff: ProcessAIOffRunner(
                executableURL: config.aiOffURL(relativeTo: supportDirectory),
                outputURL: logsDirectory.appending(path: "obsbot-ai-off.log"),
                scheduler: scheduler
            ),
            store: JSONFileStateStore(url: supportDirectory.appending(path: "state.json"), log: { write($0) }),
            settings: config.motion,
            isObsbotCenterRunning: {
                !NSRunningApplication.runningApplications(withBundleIdentifier: "com.obsbot.OBSBOT_Center").isEmpty
            },
            log: log
        )
        camera.onPresenceChange = { controller.cameraPresenceChanged($0) }
        // 127.0.0.1 en plus de l'adresse Tailscale : le Mac ne peut pas se joindre
        // lui-même par Tailscale, et les diagnostics locaux en ont besoin.
        let server = WebSocketServer(
            hosts: [config.listenAddress, "127.0.0.1"],
            port: UInt16(config.port),
            controller: controller,
            scheduler: scheduler,
            log: log
        )

        log("ptzd démarre.")
        camera.startWatching()
        server.start()
        withExtendedLifetime((camera, controller, server)) {
            dispatchMain()
        }
    }
}
```

`mac/ptzd/Sources/ptzd/UVCDebugCommand.swift` :

```swift
import Foundation
import PTZCore
import UVCCamera

/// `ptzd uvc …` : commandes manuelles, pour l'étalonnage et les vérifications sur la vraie caméra.
@MainActor
enum UVCDebugCommand {
    static let usage = """
    usage : ptzd uvc get
            ptzd uvc pt <pan°> <tilt°>
            ptzd uvc rel <sens pan> <vitesse pan> <sens tilt> <vitesse tilt>   (rel 0 1 0 1 = arrêt)
            ptzd uvc zoom <0-100>
    """
    static let arity = ["get": 0, "pt": 2, "rel": 4, "zoom": 1]

    static func run(_ arguments: [String], log: @escaping LogSink) -> Int32 {
        let values = arguments.dropFirst().compactMap(Double.init)
        guard let command = arguments.first,
              let expected = arity[command],
              values.count == expected,
              arguments.count == expected + 1 else {
            log(usage)
            return 2
        }
        let camera = UVCCamera(log: log)
        camera.startWatching()
        guard camera.isPresent else {
            log("Tiny 2 introuvable ou inaccessible.")
            return 1
        }
        do {
            switch command {
            case "get":
                let position = try camera.readPanTilt()
                log("pan=\(position.pan)° tilt=\(position.tilt)° zoom=\(try camera.readZoom())")
            case "pt":
                try camera.setPanTiltAbsolute(panDegrees: values[0], tiltDegrees: values[1])
                log("PanTilt absolu envoyé : pan=\(values[0])° tilt=\(values[1])°")
            case "rel":
                let relative = PanTiltRelative(
                    panDirection: Int8(clamping: Int(values[0])),
                    panSpeed: UInt8(clamping: Int(values[1])),
                    tiltDirection: Int8(clamping: Int(values[2])),
                    tiltSpeed: UInt8(clamping: Int(values[3]))
                )
                try camera.setPanTiltRelative(relative)
                log("PanTilt en vitesse envoyé : \(relative)")
            default:
                try camera.setZoom(Int(values[0]))
                log("Zoom envoyé : \(Int(values[0]))")
            }
            return 0
        } catch {
            log("Commande refusée : \(error)")
            return 1
        }
    }
}
```

- [ ] **Étape 3 : Compiler et lancer toute la suite**

```bash
cd mac/ptzd && swift build && swift test
```

Attendu : `Build complete!`, aucun avertissement, puis 68 tests au total, tous `passed`.

- [ ] **Étape 4 : Lire la caméra (lecture seule, OBSBOT Center fermé)**

```bash
mac/ptzd/.build/debug/ptzd uvc get
```

Attendu : une ligne `pan=…° tilt=…° zoom=…`. Noter ces trois valeurs : la position sera rétablie à l'étape 5.

```bash
mac/ptzd/.build/debug/ptzd uvc; echo "code=$?"
```

Attendu : l'aide (`usage : ptzd uvc get` …) puis `code=2`.

- [ ] **Étape 5 : Étalonner les sens (prévenir Majid : la caméra bouge environ 2 s)**

Repères des tests de faisabilité : un **pan absolu positif regarde vers la gauche** de l'image d'origine, un **tilt absolu positif vers le haut**. Le joystick vers la droite envoie le sens UVC `panDirection × (+1)` ; vers le haut, `tiltDirection × (+1)`.

```bash
P=mac/ptzd/.build/debug/ptzd
$P uvc get
$P uvc rel 1 20 0 1; sleep 1; $P uvc rel 0 1 0 1; sleep 1; $P uvc get
$P uvc rel 0 1 1 30; sleep 1; $P uvc rel 0 1 0 1; sleep 1; $P uvc get
```

Attendu, avec les valeurs par défaut (`panDirection` = +1, `tiltDirection` = +1) :
- après `rel 1 …`, l'angle **pan a diminué** : la nacelle a tourné vers la droite ;
- après `rel 0 1 1 …`, l'angle **tilt a augmenté** : la nacelle a levé l'objectif.

Si un axe va dans l'autre sens, noter qu'il faudra mettre `-1` pour cet axe dans `config.json` à la tâche 14 (étape 7). Rétablir ensuite la position notée à l'étape 4 :

```bash
mac/ptzd/.build/debug/ptzd uvc pt <pan noté> <tilt noté>
```

- [ ] **Étape 6 : Vérifier l'absence de données locales, commiter, pousser**

```bash
git add mac/ptzd/Package.swift \
    mac/ptzd/Sources/ptzd/PTZDaemon.swift \
    mac/ptzd/Sources/ptzd/UVCDebugCommand.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute l'exécutable ptzd et ses commandes d'étalonnage

Écoute sur l'adresse Tailscale et 127.0.0.1 (amendement A1) ; journal
système et sortie standard ; ptzd uvc … pour les essais sur la caméra.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 12 : Utilitaire obsbot-ai-off

Spec § 6.9. Trente lignes de C++ autour du SDK : trouver la Tiny 2 (5 s au plus), `cameraSetAiModeU(AiWorkModeNone, 0)`, fermer le SDK. Codes de sortie 0, 1 ou 2. L'`rpath` `@executable_path/../lib` correspond à l'installation (`bin/` et `lib/` côte à côte) ; pour les essais, `build.sh` crée `build/lib/libdev.dylib` comme lien vers le SDK.

**Fichiers :**
- Créer : `mac/ai-off/main.cpp`
- Créer : `mac/ai-off/build.sh` (exécutable)

**Interfaces :**
- Utilise : le SDK dans `vendor/obsbot-sdk/` (`Devices::get()`, `Device::cameraSetAiModeU`, `ObsbotProdTiny2`).
- Produit : `mac/ai-off/build/bin/obsbot-ai-off`, attendu par `PTZConfig.aiOffPath` (tâche 8) et `ProcessAIOffRunner` (tâche 6).

Pas de test automatique : le contrat (codes de sortie, délai, sortie redirigée) est déjà testé à la tâche 6 avec des programmes de substitution ; ici on vérifie l'appel réel au SDK.

- [ ] **Étape 1 : Écrire l'utilitaire et son script de compilation**

`mac/ai-off/main.cpp` :

```cpp
// obsbot-ai-off : coupe le suivi IA de la Tiny 2, puis se termine (spec § 6.9).
// Codes de sortie : 0 = suivi coupé, 1 = caméra introuvable, 2 = erreur du SDK.
// Lancé par ptzd à chaque prise en main ; le SDK ne reste jamais chargé en permanence.
#include <chrono>
#include <cstdio>
#include <dev/devs.hpp>
#include <thread>

int main() {
    Devices::get().setDevChangedCallback([](std::string, bool, void *) {}, nullptr);
    Devices::get().setEnableMdnsScan(false);

    std::shared_ptr<Device> tiny2;
    for (int attempt = 0; attempt < 50 && !tiny2; ++attempt) {
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
        std::fprintf(stderr, "obsbot-ai-off : Tiny 2 introuvable après 5 s\n");
        Devices::get().close();
        return 1;
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

`mac/ai-off/build.sh` :

```bash
#!/bin/bash
# Compile obsbot-ai-off avec le SDK OBSBOT local (vendor/obsbot-sdk/, non versionné).
# Sortie : mac/ai-off/build/bin/obsbot-ai-off, qui cherche libdev.dylib dans ../lib.
# build/lib/libdev.dylib est un lien vers le SDK : pratique pour tester sans installer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="$ROOT/vendor/obsbot-sdk"
OUT="$ROOT/mac/ai-off/build"

if [ ! -f "$SDK/include/dev/devs.hpp" ] || [ ! -f "$SDK/macos/arm64-release/libdev.dylib" ]; then
    echo "SDK OBSBOT introuvable dans $SDK (voir docs/spike/2026-10-05-faisabilite.md)." >&2
    exit 1
fi

mkdir -p "$OUT/bin" "$OUT/lib"
clang++ -std=c++17 -O2 -Wall \
    -I"$SDK/include" \
    -L"$SDK/macos/arm64-release" -ldev \
    -Wl,-rpath,@executable_path/../lib \
    -o "$OUT/bin/obsbot-ai-off" "$ROOT/mac/ai-off/main.cpp"
ln -sf "$SDK/macos/arm64-release/libdev.dylib" "$OUT/lib/libdev.dylib"
echo "$OUT/bin/obsbot-ai-off"
```

```bash
chmod +x mac/ai-off/build.sh
```

- [ ] **Étape 2 : Compiler et vérifier l'`rpath`**

```bash
mac/ai-off/build.sh && otool -l mac/ai-off/build/bin/obsbot-ai-off | grep -A2 LC_RPATH | grep path
```

Attendu : le chemin du binaire, puis `path @executable_path/../lib`.

- [ ] **Étape 3 : Couper le suivi IA pour de vrai (OBSBOT Center fermé)**

```bash
mac/ai-off/build/bin/obsbot-ai-off; echo "code=$?"
```

Attendu, en 4 à 6 s : des lignes `d-d:` / `d-i:` du SDK (normal), `d-d: cameraSetAiModeU 22 successfully`, `obsbot-ai-off : suivi IA coupé`, puis `code=0`.

- [ ] **Étape 4 : Vérifier que rien du SDK ni de la compilation n'entre dans git**

```bash
git status --short
```

Attendu : seulement `?? mac/ai-off/` (le dossier `build/` et `vendor/` sont ignorés). Vérifier avec `git status --short --untracked-files=all mac/ai-off` : seuls `main.cpp` et `build.sh` apparaissent.

- [ ] **Étape 5 : Vérifier l'absence de données locales, commiter, pousser**

```bash
git add mac/ai-off/main.cpp \
    mac/ai-off/build.sh
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute obsbot-ai-off : coupe le suivi IA avec le SDK OBSBOT

Codes de sortie 0, 1 ou 2 (spec § 6.9) ; rpath vers ../lib pour
l'installation. Le SDK reste hors du dépôt.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 13 : Client de test et essai de bout en bout en local

Un petit client WebSocket en script Swift, pour dialoguer avec `ptzd` sans l'app : envoyer des messages, maintenir un `move`, afficher chaque réponse horodatée. Puis un essai complet sur la vraie caméra, avec un dossier de travail temporaire et une écoute sur 127.0.0.1, **sans rien installer**.

**Fichiers :**
- Créer : `mac/tools/nacelle-ws.swift`

**Interfaces :**
- Utilise : l'exécutable `ptzd` (tâche 11), `obsbot-ai-off` (tâche 12), le protocole de la spec § 5.
- Produit : `swift mac/tools/nacelle-ws.swift ws://<adresse>:<port> ['<json>' | wait <s> | hold <s> <pan> <tilt>]…`

- [ ] **Étape 1 : Écrire le client**

`mac/tools/nacelle-ws.swift` :

```swift
// Client WebSocket de test pour ptzd : envoie des messages, affiche les réponses.
//
// Usage : swift mac/tools/nacelle-ws.swift ws://<adresse>:<port> [étape]…
//   '<json>'                 envoie ce message
//   wait <s>                 attend <s> secondes
//   hold <s> <pan> <tilt>    envoie move toutes les 100 ms pendant <s> secondes, puis move 0,0
//
// Exemple : swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"takeControl"}' wait 6 hold 1 0.5 0
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first, let url = URL(string: first), url.scheme == "ws" else {
    print("usage : swift nacelle-ws.swift ws://<adresse>:<port> ['<json>' | wait <s> | hold <s> <pan> <tilt>]…")
    exit(2)
}

func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

let task = URLSession.shared.webSocketTask(with: url)
task.resume()

Task {
    while true {
        do {
            if case let .string(text) = try await task.receive() {
                print("← \(stamp()) \(text)")
            }
        } catch {
            print("Connexion fermée : \(error.localizedDescription)")
            exit(1)
        }
    }
}

func send(_ text: String, quiet: Bool = false) async throws {
    if !quiet {
        print("→ \(stamp()) \(text)")
    }
    try await task.send(.string(text))
}

var steps = arguments.dropFirst()[...]
while let step = steps.popFirst() {
    switch step {
    case "wait":
        let seconds = Double(steps.popFirst() ?? "") ?? 1
        try await Task.sleep(for: .seconds(seconds))
    case "hold":
        let seconds = Double(steps.popFirst() ?? "") ?? 1
        let pan = Double(steps.popFirst() ?? "") ?? 0
        let tilt = Double(steps.popFirst() ?? "") ?? 0
        print("→ \(stamp()) move \(pan),\(tilt) pendant \(seconds) s")
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try await send(#"{"type":"move","pan":\#(pan),"tilt":\#(tilt)}"#, quiet: true)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await send(#"{"type":"move","pan":0,"tilt":0}"#)
    default:
        try await send(step)
    }
}
try await Task.sleep(for: .seconds(1))
task.cancel(with: .normalClosure, reason: nil)
```

- [ ] **Étape 2 : Démarrer ptzd en essai, sur 127.0.0.1**

```bash
(cd mac/ptzd && swift build)
mac/ptzd/.build/debug/ptzd uvc get
echo "go2rtc=$(pgrep -x go2rtc) coreaudiod=$(pgrep -x coreaudiod)"
SUP=$(mktemp -d)
printf '{"listenAddress":"127.0.0.1","port":19850,"aiOffPath":"%s"}\n' "$PWD/mac/ai-off/build/bin/obsbot-ai-off" > "$SUP/config.json"
PTZD_SUPPORT_DIR="$SUP" mac/ptzd/.build/debug/ptzd > "$SUP/ptzd.log" 2>&1 &
PTZD_PID=$!
sleep 2 && cat "$SUP/ptzd.log"
```

Noter la position (`uvc get`) et les deux PID. Attendu dans le journal : `ptzd démarre.`, `Caméra branchée.`, `En écoute sur 127.0.0.1:19850.` (une seule fois : l'adresse de la config est ici déjà 127.0.0.1, et le serveur ne l'écoute qu'une fois).

- [ ] **Étape 3 : Dérouler le scénario (prévenir Majid : la caméra bouge environ 6 s)**

```bash
swift mac/tools/nacelle-ws.swift ws://127.0.0.1:19850 '{"type":"takeControl"}' wait 7 hold 0.6 0.5 0 wait 1 '{"type":"zoom","value":60}' wait 1 '{"type":"privacy","on":true}' wait 3 '{"type":"move","pan":1,"tilt":0}' '{"type":"privacy","on":false}' wait 3 'nimporte'
```

Attendu, dans l'ordre (les valeurs de pan et tilt varient) :
1. un `state` avec `"control":"idle"`, puis `"control":"taking"`, puis `"control":"ready"` 4 à 6 s plus tard ;
2. `"moving":true` pendant le `hold`, puis `"moving":false` après le `move 0,0` ;
3. `"zoom":60` après la demande de zoom ;
4. `"privacy":true` après la demande de vie privée, puis 2 s plus tard un `state` avec `"tilt":-69` ou `"tilt":-70` ;
5. `{"code":"privacyActive",…,"type":"error"}` en réponse au `move` ;
6. `"privacy":false` après la sortie, puis un `state` avec la position relue 2 s plus tard (et `"zoom":60`, rétabli) ;
7. `{"code":"badMessage","message":"Message illisible.","type":"error"}` en réponse à `nimporte`.

- [ ] **Étape 4 : Vie privée après un redémarrage de ptzd (la caméra bouge)**

On entre en vie privée, on arrête `ptzd`, on simule une caméra revenue à sa position d'origine (`uvc pt 0 0`), puis on relance `ptzd` : il doit renvoyer l'objectif vers le bas et recouper le suivi IA de lui-même (spec § 6.5).

```bash
swift mac/tools/nacelle-ws.swift ws://127.0.0.1:19850 '{"type":"privacy","on":true}' wait 3
kill $PTZD_PID; sleep 1
mac/ptzd/.build/debug/ptzd uvc pt 0 0; sleep 3
PTZD_SUPPORT_DIR="$SUP" mac/ptzd/.build/debug/ptzd >> "$SUP/ptzd.log" 2>&1 &
PTZD_PID=$!
sleep 9 && mac/ptzd/.build/debug/ptzd uvc get
swift mac/tools/nacelle-ws.swift ws://127.0.0.1:19850 wait 1 '{"type":"privacy","on":false}' wait 3
grep -c "destroy devices object successfully" "$SUP/logs/obsbot-ai-off.log"
```

Attendu : `uvc get` affiche un tilt de `-69.0°` ou `-70.0°` ; le premier `state` reçu contient `"privacy":true`, `"control":"ready"` et le même tilt ; après la sortie, `"privacy":false` ; le compteur vaut `2` (une prise en main à l'étape 3, une au redémarrage).

- [ ] **Étape 5 (facultative, avec l'accord de Majid) : Vie privée après un débranchement de la caméra**

Débrancher la caméra fait disparaître un périphérique audio : coreaudiod est sollicité, et il s'est déjà bloqué sur ce Mac. Ne faire ce test que si Majid l'accepte, et seulement quand go2rtc ne diffuse pas (aucun spectateur) :

```bash
pgrep -fl "avfoundation" || echo "aucune capture en cours"
swift mac/tools/nacelle-ws.swift ws://127.0.0.1:19850 '{"type":"privacy","on":true}' wait 3
```

Si une capture est en cours, attendre qu'elle s'arrête. Puis demander à Majid de débrancher la caméra 5 s et de la rebrancher, et lire :

```bash
sleep 15 && tail -4 "$SUP/ptzd.log" && mac/ptzd/.build/debug/ptzd uvc get
echo "go2rtc=$(pgrep -x go2rtc) coreaudiod=$(pgrep -x coreaudiod)"
swift mac/tools/nacelle-ws.swift ws://127.0.0.1:19850 '{"type":"privacy","on":false}' wait 3
```

Attendu : `Caméra débranchée.` puis `Caméra branchée.` dans le journal, un tilt de `-69.0°` ou `-70.0°`, les mêmes PID qu'à l'étape 2, puis `"privacy":false`.

- [ ] **Étape 6 : Arrêter ptzd et lire ses traces**

```bash
kill $PTZD_PID
cat "$SUP/ptzd.log"; echo "---"; cat "$SUP/state.json"; echo "---"; tail -1 "$SUP/logs/obsbot-ai-off.log"
```

Attendu : le journal de `ptzd` ne contient que ses propres lignes (aucune ligne `d-d:` du SDK) ; `state.json` contient `"privacy" : false` ; la dernière ligne de `obsbot-ai-off.log` est `d-i: destroy devices object successfully`.

- [ ] **Étape 7 : Rétablir la position et le zoom, vérifier la santé du système**

```bash
mac/ptzd/.build/debug/ptzd uvc pt <pan noté> <tilt noté>
mac/ptzd/.build/debug/ptzd uvc zoom <zoom noté>
echo "go2rtc=$(pgrep -x go2rtc) coreaudiod=$(pgrep -x coreaudiod)"
```

Attendu : les mêmes PID qu'à l'étape 2. Si l'un a changé, s'arrêter et prévenir Majid (voir les incidents coreaudiod dans les notes du projet).

- [ ] **Étape 8 : Vérifier l'absence de données locales, commiter, pousser**

```bash
git add mac/tools/nacelle-ws.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute le client WebSocket de test nacelle-ws

Envoie des messages, maintient un move, affiche chaque réponse horodatée.
Essai de bout en bout validé sur la vraie caméra, en local : mouvement,
zoom, vie privée, y compris après un redémarrage de ptzd.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

---

### Tâche 14 : Installation launchd, README et vérification sur le Mac

Spec § 6.7 et § 6.8. Le script compile, installe dans `~/Library/Application Support/ObsbotNacelle/` (`bin/`, `lib/`, `config.json`), écrit le plist depuis le modèle et charge l'agent. **Il refuse de continuer si `libdev.dylib` est en quarantaine** et affiche la commande `xattr`, sans la lancer : c'est une décision de sécurité pour Majid. `--no-load` installe sans charger l'agent, pour l'essai à blanc.

**Fichiers :**
- Créer : `mac/launchd/io.github.djoko-cli.obsbot-nacelle.ptzd.plist`
- Créer : `scripts/install-mac.sh` (exécutable)
- Remplacer : `README.md`

**Interfaces :**
- Utilise : `mac/ptzd` (tâches 2 à 11), `mac/ai-off/build.sh` (tâche 12), `mac/tools/nacelle-ws.swift` (tâche 13).
- Produit : l'agent launchd `io.github.djoko-cli.obsbot-nacelle.ptzd` ; journaux dans `~/Library/Logs/obsbot-nacelle/` (`ptzd.log`, `obsbot-ai-off.log`).

- [ ] **Étape 1 : Écrire le modèle de plist, le script et le README**

`mac/launchd/io.github.djoko-cli.obsbot-nacelle.ptzd.plist` :

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Modèle : scripts/install-mac.sh remplace __SUPPORT__ et __LOGS__. -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.djoko-cli.obsbot-nacelle.ptzd</string>
    <key>ProgramArguments</key>
    <array>
        <string>__SUPPORT__/bin/ptzd</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>__LOGS__/ptzd.log</string>
    <key>StandardErrorPath</key>
    <string>__LOGS__/ptzd.log</string>
</dict>
</plist>
```

`scripts/install-mac.sh` :

```bash
#!/bin/bash
# Installe ptzd et obsbot-ai-off sur ce Mac, puis charge l'agent launchd (spec § 6.8).
# Usage : scripts/install-mac.sh [--no-load]
#   --no-load : installe les fichiers sans charger l'agent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/ObsbotNacelle"
LOGS="$HOME/Library/Logs/obsbot-nacelle"
LABEL="io.github.djoko-cli.obsbot-nacelle.ptzd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LIB="$ROOT/vendor/obsbot-sdk/macos/arm64-release/libdev.dylib"
LOAD=1
[ "${1:-}" = "--no-load" ] && LOAD=0

if [ ! -f "$LIB" ]; then
    echo "SDK OBSBOT introuvable : $LIB" >&2
    exit 1
fi
# macOS refuse de charger une bibliothèque téléchargée tant qu'elle est en quarantaine.
# Le script ne retire pas l'attribut lui-même : c'est une décision de sécurité à prendre à la main.
if xattr -p com.apple.quarantine "$LIB" >/dev/null 2>&1; then
    echo "libdev.dylib est en quarantaine (téléchargée depuis internet). Pour l'autoriser, lance :" >&2
    echo "  xattr -d com.apple.quarantine \"$LIB\"" >&2
    exit 1
fi

echo "Compilation de ptzd…"
(cd "$ROOT/mac/ptzd" && swift build -c release)
echo "Compilation de obsbot-ai-off…"
"$ROOT/mac/ai-off/build.sh" >/dev/null

mkdir -p "$SUPPORT/bin" "$SUPPORT/lib" "$LOGS" "$HOME/Library/LaunchAgents"
install -m 755 "$ROOT/mac/ptzd/.build/release/ptzd" "$SUPPORT/bin/ptzd"
install -m 755 "$ROOT/mac/ai-off/build/bin/obsbot-ai-off" "$SUPPORT/bin/obsbot-ai-off"
install -m 644 "$LIB" "$SUPPORT/lib/libdev.dylib"

if [ ! -f "$SUPPORT/config.json" ]; then
    ADDRESS="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    if [ -z "$ADDRESS" ]; then
        echo "Adresse Tailscale introuvable : crée $SUPPORT/config.json avec {\"listenAddress\": \"<IPv4 Tailscale du Mac>\"}." >&2
        exit 1
    fi
    printf '{\n  "listenAddress": "%s"\n}\n' "$ADDRESS" > "$SUPPORT/config.json"
    echo "config.json créé (écoute sur l'adresse Tailscale du Mac, port 1985)."
fi

sed -e "s#__SUPPORT__#$SUPPORT#g" -e "s#__LOGS__#$LOGS#g" \
    "$ROOT/mac/launchd/$LABEL.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

if [ "$LOAD" = 0 ]; then
    echo "Fichiers installés ; agent non chargé (--no-load)."
    exit 0
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
launchctl print "gui/$(id -u)/$LABEL" | grep -E "^\s+(state|pid) =" || true
echo "Journal : tail -f \"$LOGS/ptzd.log\""
```

```bash
chmod +x scripts/install-mac.sh
```

Remplacer tout le contenu de `README.md` :

````markdown
# OBSBOT Nacelle

Piloter à distance la nacelle d'une OBSBOT Tiny 2 depuis l'iPhone.

La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](https://github.com/AlexxIT/go2rtc), et vers HomeKit via Homebridge. HomeKit ne sait pas piloter un pan/tilt/zoom : ce projet ajoute ce qui manque.

> Projet personnel, sans lien avec OBSBOT.

## Statut

- **Côté Mac** : `ptzd` et `obsbot-ai-off` s'installent avec `scripts/install-mac.sh` (voir plus bas).
- **App iOS** : à venir.

Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).

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

Si macOS a mis la bibliothèque du SDK en quarantaine, l'autoriser d'abord :

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
| `scripts/install-mac.sh` | Installation sur le Mac |
| `docs/` | Spec, plans et tests de faisabilité |
| `spike/` | Sondes **jetables** des tests de faisabilité |

## Licence

MIT. Voir [LICENSE](LICENSE).
````

- [ ] **Étape 2 : Vérifier la syntaxe**

```bash
bash -n scripts/install-mac.sh && echo "script OK"
sed -e 's#__SUPPORT__#/tmp/a#' -e 's#__LOGS__#/tmp/b#' mac/launchd/io.github.djoko-cli.obsbot-nacelle.ptzd.plist > "$TMPDIR/ptzd-test.plist" && plutil -lint "$TMPDIR/ptzd-test.plist"
```

Attendu : `script OK`, puis `…/ptzd-test.plist: OK`.

- [ ] **Étape 3 : Installer à blanc, dans un dossier personnel factice**

```bash
FAKE=$(mktemp -d) && HOME="$FAKE" scripts/install-mac.sh --no-load && ls -R "$FAKE/Library" | head -30
```

Attendu : `Fichiers installés ; agent non chargé (--no-load).`, et dans l'arborescence `bin/ptzd`, `bin/obsbot-ai-off`, `lib/libdev.dylib`, `config.json` et le plist dans `LaunchAgents/`. Rien n'est chargé ni installé dans le vrai dossier personnel.

- [ ] **Étape 4 : Vérifier l'absence de données locales, commiter, pousser**

```bash
git add mac/launchd/io.github.djoko-cli.obsbot-nacelle.ptzd.plist \
    scripts/install-mac.sh \
    README.md
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Ajoute l'installation launchd de ptzd et met à jour le README

Le script refuse un SDK en quarantaine sans retirer l'attribut lui-même ;
--no-load pour un essai à blanc. README : installation, réglages, diagnostic.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git push
```

- [ ] **Étape 5 : S'arrêter et demander l'accord de Majid**

L'installation réelle crée un agent launchd qui démarre à chaque ouverture de session : c'est une configuration persistante. Présenter à Majid ce qui va être installé (les chemins de l'étape 3) et la commande de désinstallation du README, puis **attendre son accord explicite** dans la conversation.

- [ ] **Étape 6 : Installer (après accord)**

```bash
scripts/install-mac.sh
```

Attendu : `config.json créé (écoute sur l'adresse Tailscale du Mac, port 1985).`, puis `state = running` et une ligne `pid = …`.

- [ ] **Étape 7 : Appliquer l'étalonnage, si la tâche 11 l'a demandé**

Seulement si un axe allait dans l'autre sens à la tâche 11 (étape 5) : ajouter `"panDirection": -1` ou `"tiltDirection": -1` dans `~/Library/Application Support/ObsbotNacelle/config.json`, puis :

```bash
launchctl kickstart -k gui/$(id -u)/io.github.djoko-cli.obsbot-nacelle.ptzd
```

- [ ] **Étape 8 : Vérifier le service installé**

```bash
tail -5 ~/Library/Logs/obsbot-nacelle/ptzd.log
```

Attendu : `ptzd démarre.`, `Caméra branchée.`, `En écoute sur <adresse Tailscale>:1985.` et `En écoute sur 127.0.0.1:1985.`

Puis la prise en main sous launchd, qui vérifie que le SDK fonctionne aussi hors du terminal :

```bash
swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"takeControl"}' wait 8
```

Attendu : `"control":"taking"` puis `"control":"ready"`. Si `"control":"failed"` : lire `tail -20 ~/Library/Logs/obsbot-nacelle/obsbot-ai-off.log` et chercher un refus d'autorisation (`log show --last 5m --predicate 'subsystem == "com.apple.TCC"' | grep -i -E "obsbot|ptzd"`) ; le SDK ouvre un fil Bluetooth et des sockets mDNS, qu'un agent launchd peut se voir refuser. Rapporter à Majid sans contourner.

- [ ] **Étape 9 : Vérifier la santé du système**

```bash
echo "go2rtc=$(pgrep -x go2rtc) coreaudiod=$(pgrep -x coreaudiod)"
log show --last 10m --predicate 'process == "arkaudiod" AND eventMessage CONTAINS "locking failed"' 2>/dev/null | grep -c "locking failed"
```

Attendu : les mêmes PID qu'avant l'installation, et `0` erreur `locking failed`.

- [ ] **Étape 10 : Rendre compte à Majid**

Lui indiquer : le service tourne ; à la première connexion de l'iPhone (plan de l'app iOS), macOS pourra demander d'autoriser `ptzd` à accepter des connexions entrantes, à accepter ; la question peut revenir après une réinstallation. Rappeler la désinstallation (README). Proposer de valider les amendements A1 et A2 pour mettre la spec à jour.
