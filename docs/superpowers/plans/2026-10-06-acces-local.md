# Plan d'implémentation : accès local et appairage

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectif :** à la maison, piloter la nacelle et voir la vidéo depuis l'iPhone sans Tailscale ; partout, n'accepter que les iPhone appairés ; fermer go2rtc au réseau local, sauf RTSP avec mot de passe pour Homebridge.

**Architecture :** `ptzd` écoute en plus sur les interfaces Wi-Fi et Ethernet du Mac et s'y annonce par Bonjour ; chaque connexion reçoit un défi que l'iPhone signe avec sa clé Secure Enclave, enregistrée une fois par un code d'appairage (`ptzd pair`) ; `ptzd` relaie l'offre WebRTC de l'app à l'API de go2rtc, liée à 127.0.0.1. L'app essaie à chaque connexion le service Bonjour et le nom Tailscale ; la première connexion authentifiée l'emporte. La bascule se fait dans un ordre qui laisse toujours un système qui marche.

**Technologies :** Swift 6 strict, Network.framework (`NWListener`, `NWPathMonitor`, `NWBrowser`, `NWConnection` WebSocket), CryptoKit (P-256, Secure Enclave), Security (trousseau), Swift Testing, SwiftUI, xcodegen 2.46, Xcode 27, go2rtc 1.9.14.

**Spec :** [docs/superpowers/specs/2026-10-06-acces-local-design.md](../specs/2026-10-06-acces-local-design.md), à lire avec ce plan. Elle complète la [spec v1](../specs/2026-10-05-nacelle-design.md) (amendement A4).

## Contraintes globales

- **Swift :** Swift 6, concurrence stricte, **aucun avertissement** ; `ptzd` cible macOS 15, l'app iOS 26.
- **Écoute :** jamais `0.0.0.0`. Réseau local : seulement les interfaces Wi-Fi et Ethernet filaire, chacune liée à l'interface ET à son adresse IPv4. Bonjour : service `_nacelle._tcp`, nom `Nacelle`, TXT `v=1`, une seule annonce, jamais sur Tailscale.
- **Authentification :** exigée partout sauf sur les écoutes 127.0.0.1 et ::1. Défi de 32 octets aléatoires, à usage unique ; signature ECDSA P-256 (DER) de `nacelle-auth-v1|<défi en base64>|<deviceID>` ; `deviceID` = 16 premiers octets du SHA-256 de la clé publique x963, en hexadécimal. Sans `authenticated` 10 s après l'acceptation : place libérée. 4 clients au plus.
- **Appairage :** code à 6 chiffres, valable 5 min, 3 essais faux au plus, usage unique ; `pairing.json` (code haché et salé) et `devices.json` (clés publiques), droits 600, dans le dossier de travail de `ptzd`.
- **Vidéo :** `ptzd` relaie `webrtcOffer` à `POST <go2rtcAPI>/api/webrtc?src=<streamName>` (`application/sdp`, 10 s) ; `go2rtcAPI` ne peut viser que la boucle locale.
- **Dépôt public :** aucune adresse IP réelle (seules 127.0.0.1, 0.0.0.0, les adresses de documentation 192.0.2.x et 169.254.x.x dans les tests), aucun nom `*.ts.net` réel (seuls `mac.exemple.ts.net` et `mon-mac.tailnet.ts.net`), aucun chemin `/Users/…`, ni identifiant d'équipe ni UDID ; le SDK n'est jamais versionné. Le contrôle de fuite est donné à chaque commit.
- **Système en service :** ne jamais toucher au `ptzd` installé, à go2rtc, à ffmpeg ni à leur configuration, sauf aux tâches 10, 11 et 12, avec Majid présent. La caméra ne doit pas bouger en dehors de ces tâches ; les essais réseau des tâches de code utilisent le port 0 ou 19870 et une prise en main remplacée par `/usr/bin/true`.
- **Commits :** messages en français, terminés par une ligne `Co-Authored-By:` au nom du modèle qui commite ; pousser la branche à chaque commit.

## Fichiers

| Fichier | Rôle |
|---|---|
| `Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleAuth.swift` | Identifiant d'appareil, charge signée, vérification de signature (Mac et iPhone) |
| `Packages/NacelleProtocol/Sources/NacelleProtocol/{Messages,Codec}.swift` | Nouveaux messages et codes d'erreur |
| `mac/ptzd/Sources/PTZAuth/` | `PairedDevices` (`devices.json`), `PairingCode` (`pairing.json`), `DeviceAuthority`, `AuthCommand` (`ptzd pair/devices/revoke`) |
| `mac/ptzd/Sources/PTZServer/WebSocketServer.swift` | Défi, authentification, appairage, relais vidéo, écoute locale |
| `mac/ptzd/Sources/PTZServer/WebRTCRelay.swift` | Relais de l'offre WebRTC vers l'API locale de go2rtc |
| `mac/ptzd/Sources/PTZServer/LocalNetworkListeners.swift` | Écoutes Wi-Fi et Ethernet, suivi des adresses, annonce Bonjour |
| `mac/ptzd/Sources/PTZCore/PTZConfig.swift` | `go2rtcAPI`, `streamName`, `localNetwork` |
| `ios/Nacelle/Pairing/DeviceKey.swift` | Clé de l'iPhone (Secure Enclave) et trousseau |
| `ios/Nacelle/PTZ/LocalNetwork.swift` | Recherche Bonjour et transport WebSocket sur `NWConnection` |
| `ios/Nacelle/PTZ/PTZClient.swift` | Course des chemins, défi, appairage, négociation vidéo |
| `ios/Nacelle/Settings/SettingsView.swift`, `ios/Nacelle/Control/StatusBanner.swift` | Section « Appairage », messages du bandeau |

## Ordre et présence de Majid

- Tâches 1 à 9 : du code et des tests, sans toucher au système en service.
- Tâche 10 : mise en service de `ptzd` et de l'app, appairage et essais, **avec Majid**.
- Tâche 11 : go2rtc fermé au réseau local, Homebridge mis à jour, **avec Majid**.
- Tâche 12 : retrait du secours vidéo direct, README, réinstallation de l'app, **avec Majid** (iPhone déverrouillé).

---

### Tâche 1 : Protocole : appairage, authentification et vidéo relayée

**But :** Ajouter au paquet `NacelleProtocol` les messages de session (spec accès local § 5) et `NacelleAuth`, la signature partagée par le Mac et l'iPhone. Le contrôleur de `ptzd` et le client iOS reconnaissent ces nouveaux cas sans encore les traiter.

**Fichiers :**
- Modifier : `Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift`
- Modifier : `Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift`
- Créer : `Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleAuth.swift`
- Modifier : `Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift`
- Créer : `Packages/NacelleProtocol/Tests/NacelleProtocolTests/NacelleAuthTests.swift`
- Modifier : `ios/Nacelle/PTZ/PTZClient.swift`
- Modifier : `mac/ptzd/Sources/PTZCore/PTZController.swift`
- Modifier : `mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift`

**Interfaces :**
- Produit :
  - `ClientMessage.pair(code: String, publicKey: Data, name: String)`, `.auth(deviceID: String, signature: Data)`, `.webrtcOffer(id: Int, sdp: String)` ;
  - `ServerMessage.challenge(nonce: Data)`, `.authenticated`, `.paired(deviceID: String)`, `.webrtcAnswer(id: Int, sdp: String)`, `.webrtcError(id: Int, message: String)` ;
  - `ErrorCode.unpaired`, `.authFailed`, `.badCode`, `.pairingClosed`, `.notAuthenticated` ;
  - `NacelleAuth.nonceLength` (32), `NacelleAuth.deviceID(publicKeyX963:) -> String`, `NacelleAuth.signedPayload(nonce:deviceID:) -> Data`, `NacelleAuth.verify(signature:nonce:deviceID:publicKeyX963:) -> Bool`.
- Les octets (`Data`) passent en base64 dans le JSON, comme le fait `JSONEncoder` par défaut.

- [ ] **Étape 1 : Écrire les tests**

Modifier `Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift b/Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift
index 1ff6fe9..b84267f 100644
--- a/Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift
+++ b/Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift
@@ -1,3 +1,4 @@
+import Foundation
 import Testing
 @testable import NacelleProtocol
 
@@ -9,12 +10,21 @@ struct ClientMessageTests {
         .zoom(value: 33),
         .privacy(on: true),
         .privacy(on: false),
+        .pair(code: "042917", publicKey: Data([4, 1, 2, 3]), name: "iPhone"),
+        .auth(deviceID: "00112233445566778899aabbccddeeff", signature: Data([48, 69, 2, 1])),
+        .webrtcOffer(id: 3, sdp: "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n"),
     ])
     func roundTrip(_ message: ClientMessage) throws {
         let text = try NacelleCodec.encode(message)
         #expect(try NacelleCodec.decodeClient(text) == message)
     }
 
+    @Test("Les octets passent en base64, le code reste une chaîne (zéros en tête)")
+    func pairFormat() throws {
+        let text = try NacelleCodec.encode(ClientMessage.pair(code: "007123", publicKey: Data([1, 2, 3]), name: "iPhone"))
+        #expect(text == #"{"code":"007123","name":"iPhone","publicKey":"AQID","type":"pair"}"#)
+    }
+
     @Test("takeControl s'écrit avec son seul type")
     func takeControlFormat() throws {
         #expect(try NacelleCodec.encode(ClientMessage.takeControl) == #"{"type":"takeControl"}"#)
@@ -62,6 +72,12 @@ struct ServerMessageTests {
         ServerMessage.state(known),
         .state(unknown),
         .error(code: .privacyActive, message: "Vie privée active : mouvement refusé."),
+        .error(code: .unpaired, message: "Appareil inconnu."),
+        .challenge(nonce: Data(repeating: 7, count: 32)),
+        .authenticated,
+        .paired(deviceID: "00112233445566778899aabbccddeeff"),
+        .webrtcAnswer(id: 3, sdp: "v=0\r\n"),
+        .webrtcError(id: 3, message: "go2rtc ne répond pas."),
     ])
     func roundTrip(_ message: ServerMessage) throws {
         let text = try NacelleCodec.encode(message)
@@ -74,6 +90,11 @@ struct ServerMessageTests {
         #expect(text == #"{"camera":"absent","control":"idle","moving":false,"pan":null,"privacy":true,"tilt":null,"type":"state","zoom":null}"#)
     }
 
+    @Test("authenticated s'écrit avec son seul type")
+    func authenticatedFormat() throws {
+        #expect(try NacelleCodec.encode(ServerMessage.authenticated) == #"{"type":"authenticated"}"#)
+    }
+
     @Test("Un type inconnu est rejeté")
     func unknownTypeIsRejected() {
         #expect(throws: NacelleProtocolError.unknownType("hello")) {
PATCH
```

Créer `Packages/NacelleProtocol/Tests/NacelleProtocolTests/NacelleAuthTests.swift` :

```swift
import CryptoKit
import Foundation
import Testing
@testable import NacelleProtocol

@Suite("Authentification des appareils")
struct NacelleAuthTests {
    let key = P256.Signing.PrivateKey()
    let nonce = Data((0..<NacelleAuth.nonceLength).map { UInt8($0) })

    var publicKey: Data { key.publicKey.x963Representation }
    var deviceID: String { NacelleAuth.deviceID(publicKeyX963: publicKey) }

    func sign(nonce: Data, deviceID: String) throws -> Data {
        try key.signature(for: NacelleAuth.signedPayload(nonce: nonce, deviceID: deviceID)).derRepresentation
    }

    @Test("deviceID : 32 caractères hexadécimaux, stable pour une même clé")
    func deviceIDFormat() {
        #expect(deviceID.count == 32)
        #expect(deviceID.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(NacelleAuth.deviceID(publicKeyX963: publicKey) == deviceID)
        #expect(NacelleAuth.deviceID(publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation) != deviceID)
    }

    @Test("Charge utile signée")
    func payload() {
        let text = String(decoding: NacelleAuth.signedPayload(nonce: Data([1, 2, 3]), deviceID: "abc"), as: UTF8.self)
        #expect(text == "nacelle-auth-v1|AQID|abc")
    }

    @Test("Signature juste acceptée")
    func validSignature() throws {
        let signature = try sign(nonce: nonce, deviceID: deviceID)
        #expect(NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: publicKey))
    }

    @Test("Autre défi, autre appareil, autre clé ou données illisibles : refus")
    func invalidSignatures() throws {
        let signature = try sign(nonce: nonce, deviceID: deviceID)
        var otherNonce = nonce
        otherNonce[0] ^= 1
        #expect(!NacelleAuth.verify(signature: signature, nonce: otherNonce, deviceID: deviceID, publicKeyX963: publicKey))
        #expect(!NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: "0" + deviceID.dropFirst(), publicKeyX963: publicKey))
        let otherKey = P256.Signing.PrivateKey().publicKey.x963Representation
        #expect(!NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: otherKey))
        #expect(!NacelleAuth.verify(signature: Data([1, 2]), nonce: nonce, deviceID: deviceID, publicKeyX963: publicKey))
        #expect(!NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: Data([4, 1])))
    }
}
```

Modifier `mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift b/mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift
index 78007bd..4695ca1 100644
--- a/mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift
+++ b/mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift
@@ -1,3 +1,4 @@
+import Foundation
 import NacelleProtocol
 import Testing
 @testable import PTZCore
@@ -33,6 +34,15 @@ struct PTZControllerTests {
         #expect(controller.snapshot.control == .idle)
     }
 
+    @Test("Messages de session : refusés sans toucher à la caméra")
+    func sessionMessages() {
+        let controller = makeController()
+        #expect(controller.handle(.auth(deviceID: "x", signature: Data()), from: 1)?.code == .badMessage)
+        #expect(controller.handle(.pair(code: "123456", publicKey: Data(), name: "x"), from: 1)?.code == .badMessage)
+        #expect(controller.handle(.webrtcOffer(id: 1, sdp: "v=0"), from: 1)?.code == .badMessage)
+        #expect(camera.relativeCommands.isEmpty)
+    }
+
     @Test("Caméra absente : move, zoom et privacy sont refusés")
     func cameraAbsent() {
         camera.isPresent = false
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd Packages/NacelleProtocol && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : échec — la compilation des tests échoue : les nouveaux cas (`pair`, `auth`, `challenge`…) et `NacelleAuth` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Modifier `Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift b/Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift
index d66f3b1..c202d17 100644
--- a/Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift
+++ b/Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift
@@ -31,7 +31,7 @@ public enum NacelleCodec {
 
 extension ClientMessage: Codable {
     private enum CodingKeys: String, CodingKey {
-        case type, pan, tilt, value, on
+        case type, pan, tilt, value, on, code, publicKey, name, deviceID, signature, id, sdp
     }
 
     public init(from decoder: any Decoder) throws {
@@ -49,6 +49,19 @@ extension ClientMessage: Codable {
             self = .zoom(value: min(max(try container.decode(Int.self, forKey: .value), 0), 100))
         case "privacy":
             self = .privacy(on: try container.decode(Bool.self, forKey: .on))
+        case "pair":
+            self = .pair(
+                code: try container.decode(String.self, forKey: .code),
+                publicKey: try container.decode(Data.self, forKey: .publicKey),
+                name: try container.decode(String.self, forKey: .name)
+            )
+        case "auth":
+            self = .auth(
+                deviceID: try container.decode(String.self, forKey: .deviceID),
+                signature: try container.decode(Data.self, forKey: .signature)
+            )
+        case "webrtcOffer":
+            self = .webrtcOffer(id: try container.decode(Int.self, forKey: .id), sdp: try container.decode(String.self, forKey: .sdp))
         default:
             throw NacelleProtocolError.unknownType(type)
         }
@@ -69,6 +82,19 @@ extension ClientMessage: Codable {
         case let .privacy(on):
             try container.encode("privacy", forKey: .type)
             try container.encode(on, forKey: .on)
+        case let .pair(code, publicKey, name):
+            try container.encode("pair", forKey: .type)
+            try container.encode(code, forKey: .code)
+            try container.encode(publicKey, forKey: .publicKey)
+            try container.encode(name, forKey: .name)
+        case let .auth(deviceID, signature):
+            try container.encode("auth", forKey: .type)
+            try container.encode(deviceID, forKey: .deviceID)
+            try container.encode(signature, forKey: .signature)
+        case let .webrtcOffer(id, sdp):
+            try container.encode("webrtcOffer", forKey: .type)
+            try container.encode(id, forKey: .id)
+            try container.encode(sdp, forKey: .sdp)
         }
     }
 
@@ -110,7 +136,7 @@ extension StateSnapshot: Codable {
 
 extension ServerMessage: Codable {
     private enum CodingKeys: String, CodingKey {
-        case type, code, message
+        case type, code, message, nonce, deviceID, id, sdp
     }
 
     public init(from decoder: any Decoder) throws {
@@ -124,6 +150,16 @@ extension ServerMessage: Codable {
                 code: try container.decode(ErrorCode.self, forKey: .code),
                 message: try container.decode(String.self, forKey: .message)
             )
+        case "challenge":
+            self = .challenge(nonce: try container.decode(Data.self, forKey: .nonce))
+        case "authenticated":
+            self = .authenticated
+        case "paired":
+            self = .paired(deviceID: try container.decode(String.self, forKey: .deviceID))
+        case "webrtcAnswer":
+            self = .webrtcAnswer(id: try container.decode(Int.self, forKey: .id), sdp: try container.decode(String.self, forKey: .sdp))
+        case "webrtcError":
+            self = .webrtcError(id: try container.decode(Int.self, forKey: .id), message: try container.decode(String.self, forKey: .message))
         default:
             throw NacelleProtocolError.unknownType(type)
         }
@@ -139,6 +175,22 @@ extension ServerMessage: Codable {
             try container.encode("error", forKey: .type)
             try container.encode(code, forKey: .code)
             try container.encode(message, forKey: .message)
+        case let .challenge(nonce):
+            try container.encode("challenge", forKey: .type)
+            try container.encode(nonce, forKey: .nonce)
+        case .authenticated:
+            try container.encode("authenticated", forKey: .type)
+        case let .paired(deviceID):
+            try container.encode("paired", forKey: .type)
+            try container.encode(deviceID, forKey: .deviceID)
+        case let .webrtcAnswer(id, sdp):
+            try container.encode("webrtcAnswer", forKey: .type)
+            try container.encode(id, forKey: .id)
+            try container.encode(sdp, forKey: .sdp)
+        case let .webrtcError(id, message):
+            try container.encode("webrtcError", forKey: .type)
+            try container.encode(id, forKey: .id)
+            try container.encode(message, forKey: .message)
         }
     }
 }
PATCH
```

Modifier `Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift b/Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift
index 970467d..f1ceeb8 100644
--- a/Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift
+++ b/Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift
@@ -1,3 +1,5 @@
+import Foundation
+
 /// Message de l'app vers ptzd (spec § 5).
 public enum ClientMessage: Equatable, Sendable {
     /// Coupe le suivi IA de la caméra (spec § 6.4).
@@ -8,6 +10,12 @@ public enum ClientMessage: Equatable, Sendable {
     case zoom(value: Int)
     /// Entre en vie privée (true) ou en sort (false).
     case privacy(on: Bool)
+    /// Enregistre la clé de l'appareil avec le code affiché par `ptzd pair` (spec accès local § 6.4).
+    case pair(code: String, publicKey: Data, name: String)
+    /// Répond au défi : signature DER de `NacelleAuth.signedPayload` (spec accès local § 6.3).
+    case auth(deviceID: String, signature: Data)
+    /// Offre WebRTC à relayer à go2rtc ; `id` croît à chaque offre (spec accès local § 6.5).
+    case webrtcOffer(id: Int, sdp: String)
 }
 
 /// Présence de la caméra côté Mac.
@@ -30,6 +38,16 @@ public enum ErrorCode: String, Codable, Sendable {
     case cameraAbsent
     case uvcFailed
     case badMessage
+    /// Appareil inconnu de ptzd.
+    case unpaired
+    /// Signature fausse.
+    case authFailed
+    /// Code d'appairage faux.
+    case badCode
+    /// Aucun code d'appairage en cours, ou code expiré.
+    case pairingClosed
+    /// Message refusé avant l'authentification.
+    case notAuthenticated
 }
 
 /// État complet publié par ptzd.
@@ -68,4 +86,14 @@ public struct StateSnapshot: Equatable, Sendable {
 public enum ServerMessage: Equatable, Sendable {
     case state(StateSnapshot)
     case error(code: ErrorCode, message: String)
+    /// Défi envoyé à l'ouverture d'une connexion qui doit s'authentifier.
+    case challenge(nonce: Data)
+    /// Connexion authentifiée ; l'état suit aussitôt.
+    case authenticated
+    /// L'appareil vient d'être enregistré.
+    case paired(deviceID: String)
+    /// Réponse de go2rtc à l'offre `id`.
+    case webrtcAnswer(id: Int, sdp: String)
+    /// go2rtc injoignable ou en erreur pour l'offre `id`.
+    case webrtcError(id: Int, message: String)
 }
PATCH
```

Créer `Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleAuth.swift` :

```swift
import CryptoKit
import Foundation

/// Authentification d'un appareil appairé, partagée par ptzd et l'app (spec accès local § 5).
/// Clé ECDSA P-256 ; la clé publique circule au format x963, la signature au format DER.
public enum NacelleAuth {
    /// Longueur du défi, en octets.
    public static let nonceLength = 32

    /// Les 16 premiers octets du SHA-256 de la clé publique x963, en hexadécimal (32 caractères).
    public static func deviceID(publicKeyX963: Data) -> String {
        SHA256.hash(data: publicKeyX963).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Ce que l'app signe : `nacelle-auth-v1|<défi en base64>|<deviceID>`, en UTF-8.
    public static func signedPayload(nonce: Data, deviceID: String) -> Data {
        Data("nacelle-auth-v1|\(nonce.base64EncodedString())|\(deviceID)".utf8)
    }

    /// Vrai si `signature` (DER) est celle de la clé `publicKeyX963` sur ce défi et cet appareil.
    /// Une clé ou une signature illisible donne faux.
    public static func verify(signature: Data, nonce: Data, deviceID: String, publicKeyX963: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKeyX963),
              let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return key.isValidSignature(ecdsa, for: signedPayload(nonce: nonce, deviceID: deviceID))
    }
}
```

Modifier `ios/Nacelle/PTZ/PTZClient.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/PTZ/PTZClient.swift b/ios/Nacelle/PTZ/PTZClient.swift
index d0c6f56..f6d5a3b 100644
--- a/ios/Nacelle/PTZ/PTZClient.swift
+++ b/ios/Nacelle/PTZ/PTZClient.swift
@@ -118,6 +118,9 @@ final class PTZClient {
                 state = snapshot
             case let .error(code, _):
                 lastError = code
+            case .challenge, .authenticated, .paired, .webrtcAnswer, .webrtcError:
+                // Authentification et vidéo relayée : branchées plus loin dans le plan.
+                break
             }
         case .closed:
             stopRepeating()
PATCH
```

Modifier `mac/ptzd/Sources/PTZCore/PTZController.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZCore/PTZController.swift b/mac/ptzd/Sources/PTZCore/PTZController.swift
index 3fdd50a..d3b03ef 100644
--- a/mac/ptzd/Sources/PTZCore/PTZController.swift
+++ b/mac/ptzd/Sources/PTZCore/PTZController.swift
@@ -95,6 +95,9 @@ public final class PTZController {
                 try privacy.exit()
                 refreshAfterSettling()
             }
+        case .pair, .auth, .webrtcOffer:
+            // Messages de session : le serveur les traite et ne les transmet jamais.
+            return (.badMessage, "Message de session inattendu.")
         }
     }
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd Packages/NacelleProtocol && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : tout passe (protocole : 15 tests, Mac : 94 tests, iOS : 37 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift \
    Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift \
    Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleAuth.swift \
    Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift \
    Packages/NacelleProtocol/Tests/NacelleProtocolTests/NacelleAuthTests.swift \
    ios/Nacelle/PTZ/PTZClient.swift \
    mac/ptzd/Sources/PTZCore/PTZController.swift \
    mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Protocole : appairage, authentification et vidéo relayée

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit.

### Tâche 2 : `PTZAuth` : appareils appairés, code d'appairage, décision d'entrée

**But :** Nouveau module `PTZAuth` dans `mac/ptzd` : `devices.json` (clés publiques des appareils), `pairing.json` (code à 6 chiffres haché, 5 min, 3 essais, usage unique) et `DeviceAuthority`, qui vérifie une signature ou enregistre un appareil (spec accès local § 6.3 et § 6.4).

**Fichiers :**
- Modifier : `mac/ptzd/Package.swift`
- Créer : `mac/ptzd/Sources/PTZAuth/DeviceAuthority.swift`
- Créer : `mac/ptzd/Sources/PTZAuth/PairedDevices.swift`
- Créer : `mac/ptzd/Sources/PTZAuth/PairingCode.swift`
- Créer : `mac/ptzd/Tests/PTZAuthTests/DeviceAuthorityTests.swift`
- Créer : `mac/ptzd/Tests/PTZAuthTests/PairingCodeTests.swift`
- Créer : `mac/ptzd/Tests/PTZAuthTests/TestSupport.swift`

**Interfaces :**
- Consomme : `NacelleAuth` (tâche 1).
- Produit :
  - `PairedDevice` (`deviceID`, `name`, `publicKey`, `pairedAt`) ; `PairedDevices(url:)` avec `all()`, `device(id:)`, `add(_:)`, `remove(prefix:)` ; `PairedDevicesError.noMatch`, `.ambiguous` ;
  - `PairingCode(url:now:)` avec `open() -> String`, `attempt(_:) -> PairingAttempt` (`.accepted`, `.wrong`, `.closed`), `close()` ; `PairingCode.lifetime` (300 s), `PairingCode.maxFailures` (3) ;
  - `DeviceAuthority(directory:)` avec `devices`, `pairing`, `check(deviceID:signature:nonce:) -> AuthCheck` (`.accepted(PairedDevice)`, `.unknownDevice`, `.badSignature`, `.registryUnreadable`), `pair(code:publicKey:name:) -> PairResult` (`.paired(deviceID:)`, `.badCode`, `.closed`, `.invalidKey`), `DeviceAuthority.makeNonce() -> Data`.

- [ ] **Étape 1 : Écrire les tests**

Modifier `mac/ptzd/Package.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Package.swift b/mac/ptzd/Package.swift
index 51fefec..092f156 100644
--- a/mac/ptzd/Package.swift
+++ b/mac/ptzd/Package.swift
@@ -17,6 +17,10 @@ let package = Package(
             dependencies: [.product(name: "NacelleProtocol", package: "NacelleProtocol")]
         ),
         .target(name: "UVCCamera", dependencies: ["CUVC", "PTZCore"]),
+        .target(
+            name: "PTZAuth",
+            dependencies: [.product(name: "NacelleProtocol", package: "NacelleProtocol")]
+        ),
         .target(
             name: "PTZServer",
             dependencies: ["PTZCore", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
@@ -24,6 +28,10 @@ let package = Package(
         .executableTarget(name: "ptzd", dependencies: ["PTZCore", "UVCCamera", "PTZServer"]),
         .testTarget(name: "PTZCoreTests", dependencies: ["PTZCore"]),
         .testTarget(name: "UVCCameraTests", dependencies: ["UVCCamera"]),
+        .testTarget(
+            name: "PTZAuthTests",
+            dependencies: ["PTZAuth", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
+        ),
         .testTarget(
             name: "PTZServerTests",
             dependencies: ["PTZServer", "PTZCore", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
PATCH
```

Créer `mac/ptzd/Tests/PTZAuthTests/DeviceAuthorityTests.swift` :

```swift
import CryptoKit
import Foundation
import NacelleProtocol
import Testing
@testable import PTZAuth

@Suite("Appareils appairés et authentification")
struct DeviceAuthorityTests {
    let directory: URL
    let authority: DeviceAuthority
    let key = P256.Signing.PrivateKey()

    init() throws {
        directory = try makeTemporaryDirectory()
        authority = DeviceAuthority(directory: directory)
    }

    var publicKey: Data { key.publicKey.x963Representation }
    var deviceID: String { NacelleAuth.deviceID(publicKeyX963: publicKey) }

    func signature(_ nonce: Data, deviceID: String? = nil) throws -> Data {
        try key.signature(for: NacelleAuth.signedPayload(nonce: nonce, deviceID: deviceID ?? self.deviceID)).derRepresentation
    }

    func pairDevice(name: String = "iPhone de test") throws {
        let code = try authority.pairing.open()
        #expect(authority.pair(code: code, publicKey: publicKey, name: name) == .paired(deviceID: deviceID))
    }

    @Test("Défi : 32 octets, différent à chaque fois")
    func nonce() {
        let first = DeviceAuthority.makeNonce()
        #expect(first.count == 32)
        #expect(first != DeviceAuthority.makeNonce())
    }

    @Test("Appairage puis authentification")
    func pairThenAuth() throws {
        try pairDevice()
        let nonce = DeviceAuthority.makeNonce()
        guard case let .accepted(device) = authority.check(deviceID: deviceID, signature: try signature(nonce), nonce: nonce) else {
            Issue.record("refusé")
            return
        }
        #expect(device.name == "iPhone de test")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "devices.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test("Appareil inconnu, signature d'un autre défi : refus")
    func refusals() throws {
        let nonce = DeviceAuthority.makeNonce()
        #expect(authority.check(deviceID: deviceID, signature: try signature(nonce), nonce: nonce) == .unknownDevice)
        try pairDevice()
        let replayed = try signature(DeviceAuthority.makeNonce())
        #expect(authority.check(deviceID: deviceID, signature: replayed, nonce: nonce) == .badSignature)
    }

    @Test("devices.json illisible : personne n'entre")
    func unreadableRegistry() throws {
        try Data("pas du json".utf8).write(to: directory.appending(path: "devices.json"))
        let nonce = DeviceAuthority.makeNonce()
        #expect(authority.check(deviceID: deviceID, signature: try signature(nonce), nonce: nonce) == .registryUnreadable)
    }

    @Test("Appairage : code faux, fermé, clé invalide")
    func pairFailures() throws {
        #expect(authority.pair(code: "123456", publicKey: publicKey, name: "x") == .closed)
        let code = try authority.pairing.open()
        let wrong = code == "000000" ? "000001" : "000000"
        #expect(authority.pair(code: wrong, publicKey: publicKey, name: "x") == .badCode)
        #expect(authority.pair(code: code, publicKey: Data([4, 1, 2]), name: "x") == .invalidKey)
        #expect(authority.pair(code: code, publicKey: publicKey, name: "x") == .paired(deviceID: deviceID))
    }

    @Test("Nom nettoyé : espaces retirés, 40 caractères au plus, « appareil » si vide")
    func names() throws {
        try pairDevice(name: "   ")
        #expect(try authority.devices.device(id: deviceID)?.name == "appareil")
        try pairDevice(name: "  " + String(repeating: "a", count: 60))
        #expect(try authority.devices.device(id: deviceID)?.name == String(repeating: "a", count: 40))
    }

    @Test("revoke par début d'identifiant ; trop court, inconnu ou ambigu : erreur")
    func revoke() throws {
        try pairDevice()
        #expect(throws: PairedDevicesError.noMatch("abc")) { try authority.devices.remove(prefix: "abc") }
        #expect(throws: PairedDevicesError.noMatch("zzzz")) { try authority.devices.remove(prefix: "zzzz") }
        let removed = try authority.devices.remove(prefix: String(deviceID.prefix(6)).uppercased())
        #expect(removed.deviceID == deviceID)
        let nonce = DeviceAuthority.makeNonce()
        #expect(authority.check(deviceID: deviceID, signature: try signature(nonce), nonce: nonce) == .unknownDevice)
    }

    @Test("Deux appareils au même début d'identifiant : ambigu")
    func ambiguous() throws {
        let devices = authority.devices
        let date = Date(timeIntervalSince1970: 0)
        try devices.add(PairedDevice(deviceID: "abcd0000", name: "a", publicKey: Data([1]), pairedAt: date))
        try devices.add(PairedDevice(deviceID: "abcd1111", name: "b", publicKey: Data([2]), pairedAt: date))
        #expect(throws: PairedDevicesError.ambiguous("abcd")) { try devices.remove(prefix: "abcd") }
        #expect(try devices.remove(prefix: "abcd1").name == "b")
        #expect(try devices.all().map(\.name) == ["a"])
    }
}
```

Créer `mac/ptzd/Tests/PTZAuthTests/PairingCodeTests.swift` :

```swift
import Foundation
import Testing
@testable import PTZAuth

@Suite("Code d'appairage")
struct PairingCodeTests {
    let directory: URL
    let clock = TestClock()
    let pairing: PairingCode

    init() throws {
        directory = try makeTemporaryDirectory()
        let clock = clock
        pairing = PairingCode(url: directory.appending(path: "pairing.json"), now: { clock.now })
    }

    @Test("Six chiffres, fichier en droits 600 sans le code en clair")
    func open() throws {
        let code = try pairing.open()
        #expect(code.count == 6 && code.allSatisfy(\.isNumber))
        let attributes = try FileManager.default.attributesOfItem(atPath: pairing.url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(!(try String(contentsOf: pairing.url, encoding: .utf8)).contains(code))
    }

    @Test("Le bon code est accepté une seule fois")
    func singleUse() throws {
        let code = try pairing.open()
        #expect(pairing.attempt(code) == .accepted)
        #expect(pairing.attempt(code) == .closed)
        #expect(!FileManager.default.fileExists(atPath: pairing.url.path))
    }

    @Test("Trois essais faux annulent le code")
    func threeFailures() throws {
        let code = try pairing.open()
        let wrong = code == "000000" ? "000001" : "000000"
        #expect(pairing.attempt(wrong) == .wrong)
        #expect(pairing.attempt(wrong) == .wrong)
        #expect(pairing.attempt(wrong) == .wrong)
        #expect(pairing.attempt(code) == .closed)
    }

    @Test("Deux essais faux puis le bon : accepté")
    func failuresThenSuccess() throws {
        let code = try pairing.open()
        let wrong = code == "000000" ? "000001" : "000000"
        #expect(pairing.attempt(wrong) == .wrong)
        #expect(pairing.attempt(wrong) == .wrong)
        #expect(pairing.attempt(code) == .accepted)
    }

    @Test("Expiré après 5 min")
    func expiry() throws {
        let code = try pairing.open()
        clock.advance(PairingCode.lifetime - 1)
        let wrong = code == "000000" ? "000001" : "000000"
        #expect(pairing.attempt(wrong) == .wrong)
        clock.advance(2)
        #expect(pairing.attempt(code) == .closed)
    }

    @Test("Sans code en cours : fermé")
    func noCode() {
        #expect(pairing.attempt("123456") == .closed)
    }

    @Test("Un nouveau code remplace l'ancien")
    func reopen() throws {
        let first = try pairing.open()
        var second = try pairing.open()
        while second == first {
            second = try pairing.open()
        }
        #expect(pairing.attempt(first) == .wrong)
        #expect(pairing.attempt(second) == .accepted)
    }
}
```

Créer `mac/ptzd/Tests/PTZAuthTests/TestSupport.swift` :

```swift
import Foundation

/// Dossier temporaire propre à un test.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ptzauth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Horloge réglable pour les tests d'expiration.
final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        now += seconds
    }
}
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : échec — la compilation échoue : la cible `PTZAuth` n'a pas encore de sources.

- [ ] **Étape 3 : Écrire le code**

Créer `mac/ptzd/Sources/PTZAuth/DeviceAuthority.swift` :

```swift
import CryptoKit
import Foundation
import NacelleProtocol

/// Issue d'une authentification.
public enum AuthCheck: Equatable, Sendable {
    case accepted(PairedDevice)
    case unknownDevice
    case badSignature
    /// `devices.json` illisible : personne n'entre (spec accès local § 9).
    case registryUnreadable
}

/// Issue d'un appairage.
public enum PairResult: Equatable, Sendable {
    case paired(deviceID: String)
    case badCode
    case closed
    /// La clé publique n'est pas une clé P-256 x963.
    case invalidKey
}

/// Décide qui entre : appareils appairés et code d'appairage (spec accès local § 6.3 et § 6.4).
public struct DeviceAuthority: Sendable {
    public let devices: PairedDevices
    public let pairing: PairingCode
    private let now: @Sendable () -> Date

    public init(devices: PairedDevices, pairing: PairingCode, now: @escaping @Sendable () -> Date = { Date() }) {
        self.devices = devices
        self.pairing = pairing
        self.now = now
    }

    /// Les deux fichiers dans le dossier de travail de ptzd.
    public init(directory: URL) {
        self.init(
            devices: PairedDevices(url: directory.appending(path: "devices.json")),
            pairing: PairingCode(url: directory.appending(path: "pairing.json"))
        )
    }

    /// Un défi neuf.
    public static func makeNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<NacelleAuth.nonceLength).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    public func check(deviceID: String, signature: Data, nonce: Data) -> AuthCheck {
        let device: PairedDevice?
        do {
            device = try devices.device(id: deviceID)
        } catch {
            return .registryUnreadable
        }
        guard let device else { return .unknownDevice }
        let valid = NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: device.publicKey)
        return valid ? .accepted(device) : .badSignature
    }

    public func pair(code: String, publicKey: Data, name: String) -> PairResult {
        guard (try? P256.Signing.PublicKey(x963Representation: publicKey)) != nil else { return .invalidKey }
        switch pairing.attempt(code) {
        case .closed:
            return .closed
        case .wrong:
            return .badCode
        case .accepted:
            let deviceID = NacelleAuth.deviceID(publicKeyX963: publicKey)
            let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            let device = PairedDevice(deviceID: deviceID, name: cleanName.isEmpty ? "appareil" : cleanName, publicKey: publicKey, pairedAt: now())
            do {
                try devices.add(device)
            } catch {
                return .closed
            }
            return .paired(deviceID: deviceID)
        }
    }
}
```

Créer `mac/ptzd/Sources/PTZAuth/PairedDevices.swift` :

```swift
import Foundation

/// Un appareil appairé : sa clé publique seulement (spec accès local § 6.4).
public struct PairedDevice: Codable, Equatable, Sendable {
    public var deviceID: String
    public var name: String
    /// Clé publique P-256, format x963.
    public var publicKey: Data
    public var pairedAt: Date

    public init(deviceID: String, name: String, publicKey: Data, pairedAt: Date) {
        self.deviceID = deviceID
        self.name = name
        self.publicKey = publicKey
        self.pairedAt = pairedAt
    }
}

public enum PairedDevicesError: Error, Equatable {
    /// Aucun appareil, ou plusieurs, ne correspond au début d'identifiant donné.
    case noMatch(String)
    case ambiguous(String)
}

/// `devices.json` : relu à chaque appel, pour qu'un `ptzd revoke` lancé à côté du service
/// prenne effet dès la connexion suivante. Écrit avec les droits 600.
public struct PairedDevices: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Fichier absent : aucun appareil. Fichier illisible : erreur.
    public func all() throws -> [PairedDevice] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Self.decoder.decode([PairedDevice].self, from: Data(contentsOf: url))
    }

    public func device(id: String) throws -> PairedDevice? {
        try all().first { $0.deviceID == id }
    }

    /// Ajoute l'appareil, ou remplace celui qui a le même identifiant.
    public func add(_ device: PairedDevice) throws {
        var devices = try all().filter { $0.deviceID != device.deviceID }
        devices.append(device)
        try write(devices)
    }

    /// Retire l'appareil dont l'identifiant commence par `prefix` (au moins 4 caractères).
    @discardableResult
    public func remove(prefix: String) throws -> PairedDevice {
        let devices = try all()
        let matches = prefix.count >= 4 ? devices.filter { $0.deviceID.hasPrefix(prefix.lowercased()) } : []
        guard let match = matches.first else { throw PairedDevicesError.noMatch(prefix) }
        guard matches.count == 1 else { throw PairedDevicesError.ambiguous(prefix) }
        try write(devices.filter { $0.deviceID != match.deviceID })
        return match
    }

    private func write(_ devices: [PairedDevice]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try PrivateFile.write(try encoder.encode(devices), to: url)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Écriture atomique d'un fichier lisible par son seul propriétaire.
enum PrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
```

Créer `mac/ptzd/Sources/PTZAuth/PairingCode.swift` :

```swift
import CryptoKit
import Foundation

/// Résultat d'un essai de code d'appairage.
public enum PairingAttempt: Equatable, Sendable {
    case accepted
    /// Code faux ; le code en cours reste valable s'il reste des essais.
    case wrong
    /// Aucun code en cours, code expiré, ou code annulé après trop d'essais faux.
    case closed
}

/// `pairing.json` : le code en cours, haché avec un sel, son expiration et les essais faux
/// (spec accès local § 6.4). `ptzd pair` l'ouvre ; le service le lit et le supprime.
public struct PairingCode: Sendable {
    public static let lifetime: TimeInterval = 300
    public static let maxFailures = 3

    struct Stored: Codable {
        var salt: Data
        var hash: Data
        var expiresAt: Date
        var failures: Int
    }

    public let url: URL
    private let now: @Sendable () -> Date

    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    /// Ouvre un appairage : nouveau code à 6 chiffres, valable 5 min. Remplace un code en cours.
    public func open() throws -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let stored = Stored(salt: salt, hash: Self.hash(code, salt: salt), expiresAt: now() + Self.lifetime, failures: 0)
        try PrivateFile.write(try Self.encoder.encode(stored), to: url)
        return code
    }

    /// Essaie un code. Le bon code ferme l'appairage (usage unique) ; au 3e essai faux aussi.
    public func attempt(_ code: String) -> PairingAttempt {
        guard let data = try? Data(contentsOf: url), var stored = try? Self.decoder.decode(Stored.self, from: data) else {
            return .closed
        }
        guard now() < stored.expiresAt else {
            close()
            return .closed
        }
        if Self.hash(code, salt: stored.salt) == stored.hash {
            close()
            return .accepted
        }
        stored.failures += 1
        if stored.failures >= Self.maxFailures {
            close()
        } else {
            try? PrivateFile.write(try Self.encoder.encode(stored), to: url)
        }
        return .wrong
    }

    /// Supprime le code en cours, s'il y en a un.
    public func close() {
        try? FileManager.default.removeItem(at: url)
    }

    static func hash(_ code: String, salt: Data) -> Data {
        Data(SHA256.hash(data: salt + Data(code.utf8)))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : tout passe (Mac : 109 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add mac/ptzd/Package.swift \
    mac/ptzd/Sources/PTZAuth/DeviceAuthority.swift \
    mac/ptzd/Sources/PTZAuth/PairedDevices.swift \
    mac/ptzd/Sources/PTZAuth/PairingCode.swift \
    mac/ptzd/Tests/PTZAuthTests/DeviceAuthorityTests.swift \
    mac/ptzd/Tests/PTZAuthTests/PairingCodeTests.swift \
    mac/ptzd/Tests/PTZAuthTests/TestSupport.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
ptzd : module PTZAuth (appareils appairés, code d'appairage)

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit.

### Tâche 3 : Commandes `ptzd pair`, `ptzd devices` et `ptzd revoke`

**But :** Les commandes lancées à la main dans le Terminal du Mac (spec accès local § 6.4). Elles ne passent que par les fichiers : le service en cours d'exécution n'a pas besoin d'être redémarré.

**Fichiers :**
- Modifier : `mac/ptzd/Package.swift`
- Créer : `mac/ptzd/Sources/PTZAuth/AuthCommand.swift`
- Modifier : `mac/ptzd/Sources/ptzd/PTZDaemon.swift`
- Créer : `mac/ptzd/Tests/PTZAuthTests/AuthCommandTests.swift`

**Interfaces :**
- Consomme : `DeviceAuthority`, `PairedDevices`, `PairingCode` (tâche 2).
- Produit : `AuthCommand.names` (`pair`, `devices`, `revoke`), `AuthCommand.usage`, `AuthCommand.run(_ arguments: [String], authority: DeviceAuthority) -> (status: Int32, output: String)`. `PTZDaemon` les appelle avant de lire `config.json`.

- [ ] **Étape 1 : Écrire les tests**

Modifier `mac/ptzd/Package.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Package.swift b/mac/ptzd/Package.swift
index 092f156..6d9dc72 100644
--- a/mac/ptzd/Package.swift
+++ b/mac/ptzd/Package.swift
@@ -25,7 +25,7 @@ let package = Package(
             name: "PTZServer",
             dependencies: ["PTZCore", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
         ),
-        .executableTarget(name: "ptzd", dependencies: ["PTZCore", "UVCCamera", "PTZServer"]),
+        .executableTarget(name: "ptzd", dependencies: ["PTZCore", "UVCCamera", "PTZServer", "PTZAuth"]),
         .testTarget(name: "PTZCoreTests", dependencies: ["PTZCore"]),
         .testTarget(name: "UVCCameraTests", dependencies: ["UVCCamera"]),
         .testTarget(
PATCH
```

Créer `mac/ptzd/Tests/PTZAuthTests/AuthCommandTests.swift` :

```swift
import CryptoKit
import Foundation
import NacelleProtocol
import Testing
@testable import PTZAuth

@Suite("Commandes pair, devices et revoke")
struct AuthCommandTests {
    let authority: DeviceAuthority

    init() throws {
        authority = DeviceAuthority(directory: try makeTemporaryDirectory())
    }

    @Test("pair affiche un code qui marche")
    func pair() throws {
        let result = AuthCommand.run(["pair"], authority: authority)
        #expect(result.status == 0)
        let code = try #require(result.output.split(separator: "\n").first?.split(separator: " ").last.map(String.init))
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        #expect(authority.pair(code: code, publicKey: key, name: "iPhone") == .paired(deviceID: NacelleAuth.deviceID(publicKeyX963: key)))
    }

    @Test("devices : vide, puis une ligne par appareil")
    func devices() throws {
        #expect(AuthCommand.run(["devices"], authority: authority).output == "Aucun appareil appairé.")
        try authority.devices.add(PairedDevice(
            deviceID: "0123456789abcdef0123456789abcdef", name: "iPhone",
            publicKey: Data([4]), pairedAt: Date(timeIntervalSince1970: 1_791_288_000)
        ))
        #expect(AuthCommand.run(["devices"], authority: authority).output == "01234567  2026-10-06  iPhone")
    }

    @Test("revoke : retire, ou explique pourquoi pas")
    func revoke() throws {
        try authority.devices.add(PairedDevice(deviceID: "0123456789abcdef", name: "iPhone", publicKey: Data([4]), pairedAt: Date()))
        #expect(AuthCommand.run(["revoke", "9999"], authority: authority).status == 1)
        let result = AuthCommand.run(["revoke", "0123"], authority: authority)
        #expect(result.status == 0)
        #expect(result.output.hasPrefix("Retiré : 01234567  iPhone."))
        #expect(try authority.devices.all().isEmpty)
    }

    @Test("Arguments en trop ou inconnus : usage, code 2", arguments: [["pair", "x"], ["devices", "x"], ["revoke"], ["dance"]])
    func usage(_ arguments: [String]) {
        let result = AuthCommand.run(arguments, authority: authority)
        #expect(result.status == 2)
        #expect(result.output == AuthCommand.usage)
    }
}
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : échec — la compilation échoue : `AuthCommand` n'existe pas encore.

- [ ] **Étape 3 : Écrire le code**

Créer `mac/ptzd/Sources/PTZAuth/AuthCommand.swift` :

```swift
import Foundation

/// `ptzd pair`, `ptzd devices` et `ptzd revoke` (spec accès local § 6.4), lancés à la main
/// dans le Terminal pendant que le service tourne : ils ne passent que par les fichiers.
public enum AuthCommand {
    public static let names: Set<String> = ["pair", "devices", "revoke"]
    public static let usage = """
    usage : ptzd pair                          affiche un code d'appairage, valable 5 min
            ptzd devices                       liste les appareils appairés
            ptzd revoke <début d'identifiant>  retire un appareil (4 caractères au moins)
    """

    /// Code de sortie et texte à afficher.
    public static func run(_ arguments: [String], authority: DeviceAuthority) -> (status: Int32, output: String) {
        switch (arguments.first, arguments.count) {
        case ("pair", 1):
            do {
                let code = try authority.pairing.open()
                return (0, """
                Code d'appairage : \(code)
                Dans l'app : Réglages › Appairage, avant 5 min. Un seul usage, 3 essais.
                """)
            } catch {
                return (1, "Impossible d'ouvrir l'appairage : \(error)")
            }
        case ("devices", 1):
            do {
                let devices = try authority.devices.all()
                guard !devices.isEmpty else { return (0, "Aucun appareil appairé.") }
                let lines = devices.map { "\($0.deviceID.prefix(8))  \(day($0.pairedAt))  \($0.name)" }
                return (0, lines.joined(separator: "\n"))
            } catch {
                return (1, "devices.json illisible : \(error)")
            }
        case ("revoke", 2):
            do {
                let removed = try authority.devices.remove(prefix: arguments[1])
                return (0, "Retiré : \(removed.deviceID.prefix(8))  \(removed.name). Ses connexions ouvertes durent jusqu'à leur fin ; relancer ptzd pour les couper tout de suite.")
            } catch PairedDevicesError.ambiguous(let prefix) {
                return (1, "Plusieurs appareils commencent par « \(prefix) » : donner plus de caractères.")
            } catch PairedDevicesError.noMatch(let prefix) {
                return (1, "Aucun appareil ne commence par « \(prefix) » (4 caractères au moins).")
            } catch {
                return (1, "devices.json illisible : \(error)")
            }
        default:
            return (2, usage)
        }
    }

    private static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}
```

Modifier `mac/ptzd/Sources/ptzd/PTZDaemon.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/ptzd/PTZDaemon.swift b/mac/ptzd/Sources/ptzd/PTZDaemon.swift
index d27871e..7e0ddbf 100644
--- a/mac/ptzd/Sources/ptzd/PTZDaemon.swift
+++ b/mac/ptzd/Sources/ptzd/PTZDaemon.swift
@@ -1,5 +1,6 @@
 import Foundation
 import os
+import PTZAuth
 import PTZCore
 import PTZServer
 import UVCCamera
@@ -37,6 +38,11 @@ struct PTZDaemon {
         if arguments.first == "uvc" {
             exit(UVCDebugCommand.run(Array(arguments.dropFirst()), log: log))
         }
+        if let command = arguments.first, AuthCommand.names.contains(command) {
+            let result = AuthCommand.run(arguments, authority: DeviceAuthority(directory: supportDirectory))
+            print(result.output)
+            exit(result.status)
+        }
 
         let config: PTZConfig
         do {
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : tout passe (Mac : 113 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Essai à la main, dans un dossier temporaire**

```bash
D=$(mktemp -d); (cd mac/ptzd && swift build -q && PTZD_SUPPORT_DIR=$D .build/debug/ptzd pair && PTZD_SUPPORT_DIR=$D .build/debug/ptzd devices; ls -l $D); rm -rf $D
```

Attendu : « Code d'appairage : » suivi de 6 chiffres, puis « Aucun appareil appairé. », et `pairing.json` en `-rw-------`.

- [ ] **Étape 6 : Commiter et pousser**

```bash
git add mac/ptzd/Package.swift \
    mac/ptzd/Sources/PTZAuth/AuthCommand.swift \
    mac/ptzd/Sources/ptzd/PTZDaemon.swift \
    mac/ptzd/Tests/PTZAuthTests/AuthCommandTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
ptzd : commandes pair, devices et revoke

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit.

### Tâche 4 : Serveur : défi, authentification et appairage

**But :** Chaque connexion au serveur WebSocket reçoit un défi et doit s'authentifier avant toute commande ; l'état n'est diffusé qu'aux clients authentifiés ; 127.0.0.1 est authentifié d'office ; 10 s pour s'authentifier, sinon la place est libérée (spec accès local § 6.3 et § 6.4). Le délai de poignée de main du correctif de fuite devient ce délai d'authentification.

**Fichiers :**
- Modifier : `mac/ptzd/Package.swift`
- Modifier : `mac/ptzd/Sources/PTZServer/WebSocketServer.swift`
- Modifier : `mac/ptzd/Sources/ptzd/PTZDaemon.swift`
- Modifier : `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift`

**Interfaces :**
- Consomme : `DeviceAuthority` (tâche 2), messages de la tâche 1.
- Produit : `WebSocketServer(hosts:port:controller:authority:scheduler:log:trustLoopback:)` ; `WebSocketServer.authTimeout` (10 s) remplace `handshakeTimeout`. `trustLoopback` vaut vrai par défaut ; les tests le mettent à faux pour exercer l'authentification sur 127.0.0.1.
- Journal : « Client N authentifié : <nom> (<début d'identifiant>). », « Client N refusé : <raison> (<adresse>). », « Appareil appairé : … », « Client N : code d'appairage faux (…). », « Client N libéré : pas authentifié en 10 s. »

- [ ] **Étape 1 : Écrire les tests**

Modifier `mac/ptzd/Package.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Package.swift b/mac/ptzd/Package.swift
index 6d9dc72..11067cc 100644
--- a/mac/ptzd/Package.swift
+++ b/mac/ptzd/Package.swift
@@ -23,7 +23,7 @@ let package = Package(
         ),
         .target(
             name: "PTZServer",
-            dependencies: ["PTZCore", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
+            dependencies: ["PTZCore", "PTZAuth", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
         ),
         .executableTarget(name: "ptzd", dependencies: ["PTZCore", "UVCCamera", "PTZServer", "PTZAuth"]),
         .testTarget(name: "PTZCoreTests", dependencies: ["PTZCore"]),
@@ -34,7 +34,7 @@ let package = Package(
         ),
         .testTarget(
             name: "PTZServerTests",
-            dependencies: ["PTZServer", "PTZCore", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
+            dependencies: ["PTZServer", "PTZCore", "PTZAuth", .product(name: "NacelleProtocol", package: "NacelleProtocol")]
         ),
     ]
 )
PATCH
```

Modifier `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift b/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
index 4b30b33..7675561 100644
--- a/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
+++ b/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
@@ -1,6 +1,8 @@
+import CryptoKit
 import Foundation
 import NacelleProtocol
 import Network
+import PTZAuth
 import PTZCore
 import Testing
 @testable import PTZServer
@@ -10,8 +12,14 @@ import Testing
 struct WebSocketServerTests {
     let camera = StubCamera()
     let controller: PTZController
-
-    init() {
+    let authority: DeviceAuthority
+    /// Clé de l'appareil de test, appairée par `pairTestDevice()`.
+    let key = P256.Signing.PrivateKey()
+
+    init() throws {
+        let directory = FileManager.default.temporaryDirectory.appending(path: "ptzserver-\(UUID().uuidString)")
+        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
+        authority = DeviceAuthority(directory: directory)
         controller = PTZController(
             camera: camera,
             scheduler: DispatchScheduler(),
@@ -28,9 +36,13 @@ struct WebSocketServerTests {
     private func startServer(
         on hosts: [String] = ["127.0.0.1"],
         scheduler: any Scheduler = DispatchScheduler(),
-        log: @escaping LogSink = { _ in }
+        log: @escaping LogSink = { _ in },
+        trustLoopback: Bool = true
     ) async -> (WebSocketServer, [String: UInt16]) {
-        let server = WebSocketServer(hosts: hosts, port: 0, controller: controller, scheduler: scheduler, log: log)
+        let server = WebSocketServer(
+            hosts: hosts, port: 0, controller: controller, authority: authority,
+            scheduler: scheduler, log: log, trustLoopback: trustLoopback
+        )
         let ports = await withCheckedContinuation { continuation in
             var ready: [String: UInt16] = [:]
             server.onReady = { host, port in
@@ -80,6 +92,31 @@ struct WebSocketServerTests {
         #expect(condition())
     }
 
+    private var deviceID: String {
+        NacelleAuth.deviceID(publicKeyX963: key.publicKey.x963Representation)
+    }
+
+    private func pairTestDevice() throws {
+        try authority.devices.add(PairedDevice(deviceID: deviceID, name: "iPhone de test", publicKey: key.publicKey.x963Representation, pairedAt: Date()))
+    }
+
+    private func send(_ message: ClientMessage, on task: URLSessionWebSocketTask) async throws {
+        try await task.send(.string(try NacelleCodec.encode(message)))
+    }
+
+    /// Le défi reçu à l'ouverture.
+    private func challenge(_ task: URLSessionWebSocketTask) async throws -> Data {
+        guard case let .challenge(nonce) = try await next(task, where: { _ in true }) else {
+            Issue.record("défi attendu")
+            return Data()
+        }
+        return nonce
+    }
+
+    private func signature(for nonce: Data) throws -> Data {
+        try key.signature(for: NacelleAuth.signedPayload(nonce: nonce, deviceID: deviceID)).derRepresentation
+    }
+
     /// Lit les messages jusqu'au premier qui satisfait la condition.
     private func next(_ task: URLSessionWebSocketTask, where matches: (ServerMessage) -> Bool) async throws -> ServerMessage {
         while true {
@@ -91,15 +128,16 @@ struct WebSocketServerTests {
         }
     }
 
-    @Test("État envoyé à la connexion ; move appliqué ; message illisible signalé")
+    @Test("127.0.0.1 : authentifié d'office, puis l'état ; move appliqué ; message illisible signalé")
     func roundTrip() async throws {
         let (server, ports) = await startServer()
         let task = connect("127.0.0.1", ports["127.0.0.1"]!)
         defer { task.cancel(with: .goingAway, reason: nil) }
 
-        let first = try await next(task) { _ in true }
-        guard case let .state(snapshot) = first else {
-            Issue.record("état attendu, reçu \(first)")
+        #expect(try await next(task) { _ in true } == .authenticated)
+        let second = try await next(task) { _ in true }
+        guard case let .state(snapshot) = second else {
+            Issue.record("état attendu, reçu \(second)")
             return
         }
         #expect(snapshot.camera == .connected)
@@ -132,7 +170,10 @@ struct WebSocketServerTests {
 
     @Test("Une adresse en double n'est écoutée qu'une fois")
     func duplicateHosts() async throws {
-        let server = WebSocketServer(hosts: ["127.0.0.1", "127.0.0.1"], port: 0, controller: controller, scheduler: DispatchScheduler(), log: { _ in })
+        let server = WebSocketServer(
+            hosts: ["127.0.0.1", "127.0.0.1"], port: 0, controller: controller, authority: authority,
+            scheduler: DispatchScheduler(), log: { _ in }
+        )
         var readyCount = 0
         server.onReady = { _, _ in readyCount += 1 }
         server.start()
@@ -190,11 +231,139 @@ struct WebSocketServerTests {
         defer { client.cancel() }
         try await waitUntil { server.clientCount == 1 }
 
-        scheduler.advance(by: WebSocketServer.handshakeTimeout - 0.1)
+        scheduler.advance(by: WebSocketServer.authTimeout - 0.1)
         #expect(server.clientCount == 1)
         scheduler.advance(by: 0.1)
         #expect(server.clientCount == 0)
-        #expect(lines.values.contains("Client 1 libéré : poignée de main non terminée en 10 s."))
+        #expect(lines.values.contains("Client 1 libéré : pas authentifié en 10 s."))
+    }
+
+    @Test("Sans 127.0.0.1 de confiance : défi d'abord, rien d'autre avant l'authentification")
+    func challengeFirst() async throws {
+        let (server, ports) = await startServer(trustLoopback: false)
+        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
+        defer { task.cancel(with: .goingAway, reason: nil) }
+
+        #expect(try await challenge(task).count == NacelleAuth.nonceLength)
+        try await send(.move(pan: 1, tilt: 0), on: task)
+        #expect(try await next(task) { _ in true } == .error(code: .notAuthenticated, message: "Authentification d'abord."))
+        #expect(camera.relativeCommands.isEmpty)
+        withExtendedLifetime(server) {}
+    }
+
+    @Test("Signature juste : authenticated, puis l'état ; les commandes passent")
+    func validAuth() async throws {
+        try pairTestDevice()
+        let lines = LineBox()
+        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false)
+        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
+        defer { task.cancel(with: .goingAway, reason: nil) }
+
+        let nonce = try await challenge(task)
+        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
+        #expect(try await next(task) { _ in true } == .authenticated)
+        guard case .state = try await next(task, where: { _ in true }) else {
+            Issue.record("état attendu")
+            return
+        }
+        try await send(.move(pan: 1, tilt: 0), on: task)
+        _ = try await next(task) { if case let .state(s) = $0 { s.moving } else { false } }
+        #expect(lines.values.contains("Client 1 authentifié : iPhone de test (\(deviceID.prefix(8)))."))
+        withExtendedLifetime(server) {}
+    }
+
+    @Test("Appareil inconnu : unpaired, puis fermeture et place libérée")
+    func unknownDevice() async throws {
+        let lines = LineBox()
+        let (server, ports) = await startServer(log: { lines.values.append($0) }, trustLoopback: false)
+        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
+        defer { task.cancel(with: .goingAway, reason: nil) }
+
+        let nonce = try await challenge(task)
+        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
+        #expect(try await next(task) { _ in true } == .error(code: .unpaired, message: "Appareil inconnu : l'appairer avec ptzd pair."))
+        try await waitUntil { server.clientCount == 0 }
+        #expect(lines.values.contains { $0.hasPrefix("Client 1 refusé : appareil inconnu \(deviceID.prefix(8))") })
+    }
+
+    @Test("Signature d'un autre défi (rejeu) : authFailed, puis fermeture")
+    func replayedSignature() async throws {
+        try pairTestDevice()
+        let (server, ports) = await startServer(trustLoopback: false)
+        let first = connect("127.0.0.1", ports["127.0.0.1"]!)
+        let second = connect("127.0.0.1", ports["127.0.0.1"]!)
+        defer { [first, second].forEach { $0.cancel(with: .goingAway, reason: nil) } }
+
+        let firstNonce = try await challenge(first)
+        _ = try await challenge(second)
+        try await send(.auth(deviceID: deviceID, signature: try signature(for: firstNonce)), on: second)
+        #expect(try await next(second) { _ in true } == .error(code: .authFailed, message: "Signature refusée."))
+        try await waitUntil { server.clientCount == 1 }
+    }
+
+    @Test("Défi sans réponse : place libérée 10 s après l'acceptation")
+    func authTimeout() async throws {
+        let scheduler = FakeScheduler()
+        let lines = LineBox()
+        let (server, ports) = await startServer(scheduler: scheduler, log: { lines.values.append($0) }, trustLoopback: false)
+        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
+        defer { task.cancel(with: .goingAway, reason: nil) }
+        _ = try await challenge(task)
+
+        scheduler.advance(by: WebSocketServer.authTimeout)
+        #expect(server.clientCount == 0)
+        #expect(lines.values.contains("Client 1 libéré : pas authentifié en 10 s."))
+    }
+
+    @Test("Appairage : code faux (connexion gardée), puis bon code, puis auth sur le même défi")
+    func pairing() async throws {
+        let code = try authority.pairing.open()
+        let wrong = code == "000000" ? "000001" : "000000"
+        let (server, ports) = await startServer(trustLoopback: false)
+        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
+        defer { task.cancel(with: .goingAway, reason: nil) }
+        let nonce = try await challenge(task)
+        let publicKey = key.publicKey.x963Representation
+
+        try await send(.pair(code: wrong, publicKey: publicKey, name: "iPhone"), on: task)
+        #expect(try await next(task) { _ in true } == .error(code: .badCode, message: "Code d'appairage faux."))
+        try await send(.pair(code: code, publicKey: publicKey, name: "iPhone"), on: task)
+        #expect(try await next(task) { _ in true } == .paired(deviceID: deviceID))
+        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
+        #expect(try await next(task) { _ in true } == .authenticated)
+        #expect(try authority.devices.device(id: deviceID)?.name == "iPhone")
+        withExtendedLifetime(server) {}
+    }
+
+    @Test("Appairage sans code en cours : pairingClosed")
+    func pairingClosed() async throws {
+        let (server, ports) = await startServer(trustLoopback: false)
+        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
+        defer { task.cancel(with: .goingAway, reason: nil) }
+        _ = try await challenge(task)
+        try await send(.pair(code: "123456", publicKey: key.publicKey.x963Representation, name: "iPhone"), on: task)
+        #expect(try await next(task) { _ in true } == .error(code: .pairingClosed, message: "Aucun appairage en cours : lancer ptzd pair sur le Mac."))
+        withExtendedLifetime(server) {}
+    }
+
+    @Test("L'état n'est diffusé qu'aux clients authentifiés")
+    func broadcastOnlyToAuthenticated() async throws {
+        try pairTestDevice()
+        let (server, ports) = await startServer(trustLoopback: false)
+        let anonymous = connect("127.0.0.1", ports["127.0.0.1"]!)
+        let member = connect("127.0.0.1", ports["127.0.0.1"]!)
+        defer { [anonymous, member].forEach { $0.cancel(with: .goingAway, reason: nil) } }
+        _ = try await challenge(anonymous)
+        let nonce = try await challenge(member)
+        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: member)
+        _ = try await next(member) { if case .state = $0 { true } else { false } }
+
+        try await send(.move(pan: 1, tilt: 0), on: member)
+        _ = try await next(member) { if case let .state(s) = $0 { s.moving } else { false } }
+        // Le client anonyme ne reçoit que la réponse à son propre message.
+        try await send(.zoom(value: 10), on: anonymous)
+        #expect(try await next(anonymous) { _ in true } == .error(code: .notAuthenticated, message: "Authentification d'abord."))
+        withExtendedLifetime(server) {}
     }
 
     @Test("Client qui ne répond pas aux pings : place libérée 25 s après le dernier pong")
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : échec — la compilation des tests échoue : `WebSocketServer` ne prend pas encore `authority:` ni `trustLoopback:`.

- [ ] **Étape 3 : Écrire le code**

Modifier `mac/ptzd/Sources/PTZServer/WebSocketServer.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZServer/WebSocketServer.swift b/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
index a891c3b..d3806b3 100644
--- a/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
+++ b/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
@@ -1,17 +1,19 @@
 import Foundation
 import NacelleProtocol
 import Network
+import PTZAuth
 import PTZCore
 
 /// Serveur WebSocket de ptzd : quelques adresses précises (jamais 0.0.0.0),
-/// 4 clients au plus en tout (spec § 6.1 et § 6.10). Une place n'est jamais gardée par
-/// une connexion morte : délai de poignée de main, connexion en attente, ping toutes les 10 s.
+/// 4 clients au plus en tout (spec § 6.1 et § 6.10). Chaque connexion s'authentifie, sauf sur
+/// 127.0.0.1 (spec accès local § 6.3). Une place n'est jamais gardée par une connexion morte ou
+/// anonyme : 10 s pour s'authentifier, connexion en attente, ping toutes les 10 s.
 @MainActor
 public final class WebSocketServer {
     public static let maxClients = 4
     public static let retryDelay: TimeInterval = 5
-    /// Une connexion acceptée qui n'est pas prête après ce délai libère sa place.
-    public static let handshakeTimeout: TimeInterval = 10
+    /// Une connexion acceptée qui n'est pas authentifiée après ce délai libère sa place.
+    public static let authTimeout: TimeInterval = 10
     /// Intervalle des pings envoyés à chaque client prêt.
     public static let pingInterval: TimeInterval = 10
     /// Un client sans pong depuis ce délai libère sa place.
@@ -28,21 +30,28 @@ public final class WebSocketServer {
     private let hosts: [String]
     private let port: UInt16
     private let controller: PTZController
+    private let authority: DeviceAuthority
     private let scheduler: any Scheduler
     private let log: LogSink
+    private let trustLoopback: Bool
     private var listeners: [String: NWListener] = [:]
     private var clients: [ClientID: Client] = [:]
     private var nextID: ClientID = 1
 
-    /// Une place occupée : la connexion et ses minuteries, toutes annulées par `drop`.
+    /// Une place occupée : la connexion, son authentification et ses minuteries, toutes annulées par `drop`.
     private struct Client {
         let connection: NWConnection
-        var handshake: (any Cancellable)?
+        /// Arrivée par une écoute en boucle locale (127.0.0.1, ::1) : authentifiée d'office.
+        let trusted: Bool
+        var authenticated = false
+        /// Défi en cours ; consommé par le premier `auth`.
+        var nonce: Data?
+        var deadline: (any Cancellable)?
         var ping: (any Cancellable)?
         var pongDeadline: (any Cancellable)?
 
         func cancelTimers() {
-            handshake?.cancel()
+            deadline?.cancel()
             ping?.cancel()
             pongDeadline?.cancel()
         }
@@ -54,7 +63,16 @@ public final class WebSocketServer {
     }
 
     /// Les adresses en double ne sont écoutées qu'une fois (config.json peut déjà contenir 127.0.0.1).
-    public init(hosts: [String], port: UInt16, controller: PTZController, scheduler: any Scheduler, log: @escaping LogSink) {
+    /// `trustLoopback` à faux (tests) impose l'authentification aussi sur 127.0.0.1.
+    public init(
+        hosts: [String],
+        port: UInt16,
+        controller: PTZController,
+        authority: DeviceAuthority,
+        scheduler: any Scheduler,
+        log: @escaping LogSink,
+        trustLoopback: Bool = true
+    ) {
         self.hosts = hosts.reduce(into: []) { unique, host in
             if !unique.contains(host) {
                 unique.append(host)
@@ -62,8 +80,10 @@ public final class WebSocketServer {
         }
         self.port = port
         self.controller = controller
+        self.authority = authority
         self.scheduler = scheduler
         self.log = log
+        self.trustLoopback = trustLoopback
         controller.onStateChange = { [weak self] snapshot in
             self?.broadcast(.state(snapshot))
         }
@@ -110,8 +130,9 @@ public final class WebSocketServer {
         listener.stateUpdateHandler = { [weak self] state in
             MainActor.assumeIsolated { self?.listenerChanged(host, state) }
         }
+        let trusted = trustLoopback && Self.isLoopback(host)
         listener.newConnectionHandler = { [weak self] connection in
-            MainActor.assumeIsolated { self?.accept(connection) }
+            MainActor.assumeIsolated { self?.accept(connection, trusted: trusted) }
         }
         listeners[host] = listener
         listener.start(queue: .main)
@@ -138,7 +159,12 @@ public final class WebSocketServer {
         }
     }
 
-    private func accept(_ connection: NWConnection) {
+    /// Écoute en boucle locale : seuls les programmes du Mac y arrivent.
+    nonisolated static func isLoopback(_ host: String) -> Bool {
+        host == "127.0.0.1" || host == "::1"
+    }
+
+    private func accept(_ connection: NWConnection, trusted: Bool) {
         guard clients.count < Self.maxClients else {
             log("Connexion refusée : déjà \(Self.maxClients) clients.")
             connection.cancel()
@@ -146,9 +172,9 @@ public final class WebSocketServer {
         }
         let id = nextID
         nextID += 1
-        var client = Client(connection: connection)
-        client.handshake = scheduler.schedule(after: Self.handshakeTimeout) { [weak self] in
-            self?.release(id, reason: "poignée de main non terminée en \(Int(Self.handshakeTimeout)) s")
+        var client = Client(connection: connection, trusted: trusted)
+        client.deadline = scheduler.schedule(after: Self.authTimeout) { [weak self] in
+            self?.release(id, reason: "pas authentifié en \(Int(Self.authTimeout)) s")
         }
         clients[id] = client
         connection.stateUpdateHandler = { [weak self] state in
@@ -161,15 +187,20 @@ public final class WebSocketServer {
     func connectionChanged(_ id: ClientID, _ state: NWConnection.State) {
         switch state {
         case .ready:
-            clients[id]?.handshake?.cancel()
-            clients[id]?.handshake = nil
+            guard let client = clients[id] else { return }
             if wasRejected(id) {
                 drop(id)
                 return
             }
-            send(.state(controller.snapshot), to: id)
             armPongDeadline(id)
             schedulePing(id)
+            if client.trusted {
+                authenticate(id)
+            } else {
+                let nonce = DeviceAuthority.makeNonce()
+                clients[id]?.nonce = nonce
+                send(.challenge(nonce: nonce), to: id)
+            }
         case let .waiting(error):
             // Chemin réseau perdu (Wi-Fi/4G, Tailscale coupé) : une connexion entrante
             // n'atteint alors pas toujours .failed et garderait sa place.
@@ -215,11 +246,85 @@ public final class WebSocketServer {
             send(.error(code: .badMessage, message: "Message illisible."), to: id)
             return
         }
-        if let failure = controller.handle(message, from: id) {
-            send(.error(code: failure.code, message: failure.message), to: id)
+        guard let client = clients[id] else { return }
+        switch message {
+        case let .pair(code, publicKey, name):
+            guard !client.authenticated else {
+                send(.error(code: .badMessage, message: "Déjà authentifié."), to: id)
+                return
+            }
+            pair(id, code: code, publicKey: publicKey, name: name)
+        case let .auth(deviceID, signature):
+            guard !client.authenticated else { return }
+            verify(id, deviceID: deviceID, signature: signature)
+        default:
+            guard client.authenticated else {
+                send(.error(code: .notAuthenticated, message: "Authentification d'abord."), to: id)
+                return
+            }
+            if let failure = controller.handle(message, from: id) {
+                send(.error(code: failure.code, message: failure.message), to: id)
+            }
+        }
+    }
+
+    /// Code d'appairage : un code faux laisse la connexion ouverte pour un nouvel essai.
+    private func pair(_ id: ClientID, code: String, publicKey: Data, name: String) {
+        switch authority.pair(code: code, publicKey: publicKey, name: name) {
+        case let .paired(deviceID):
+            log("Appareil appairé : \(deviceID.prefix(8)) (\(name)).")
+            send(.paired(deviceID: deviceID), to: id)
+        case .badCode:
+            log("Client \(id) : code d'appairage faux (\(endpoint(id))).")
+            send(.error(code: .badCode, message: "Code d'appairage faux."), to: id)
+        case .closed:
+            send(.error(code: .pairingClosed, message: "Aucun appairage en cours : lancer ptzd pair sur le Mac."), to: id)
+        case .invalidKey:
+            send(.error(code: .badMessage, message: "Clé publique illisible."), to: id)
         }
     }
 
+    /// Réponse au défi. Le défi ne sert qu'une fois ; un échec ferme la connexion.
+    private func verify(_ id: ClientID, deviceID: String, signature: Data) {
+        guard let nonce = clients[id]?.nonce else { return }
+        clients[id]?.nonce = nil
+        switch authority.check(deviceID: deviceID, signature: signature, nonce: nonce) {
+        case let .accepted(device):
+            log("Client \(id) authentifié : \(device.name) (\(deviceID.prefix(8))).")
+            authenticate(id)
+        case .unknownDevice:
+            refuse(id, .unpaired, "Appareil inconnu : l'appairer avec ptzd pair.", reason: "appareil inconnu \(deviceID.prefix(8))")
+        case .badSignature:
+            refuse(id, .authFailed, "Signature refusée.", reason: "signature refusée pour \(deviceID.prefix(8))")
+        case .registryUnreadable:
+            log("devices.json illisible : aucun appareil accepté.")
+            refuse(id, .unpaired, "Liste des appareils illisible sur le Mac.", reason: "devices.json illisible")
+        }
+    }
+
+    private func authenticate(_ id: ClientID) {
+        clients[id]?.authenticated = true
+        clients[id]?.deadline?.cancel()
+        clients[id]?.deadline = nil
+        send(.authenticated, to: id)
+        send(.state(controller.snapshot), to: id)
+    }
+
+    /// Envoie l'erreur, puis libère la place une fois l'envoi parti.
+    private func refuse(_ id: ClientID, _ code: ErrorCode, _ message: String, reason: String) {
+        guard let connection = clients[id]?.connection, let text = try? NacelleCodec.encode(ServerMessage.error(code: code, message: message)) else { return }
+        log("Client \(id) refusé : \(reason) (\(endpoint(id))).")
+        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
+        let context = NWConnection.ContentContext(identifier: "nacelle", metadata: [metadata])
+        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
+            MainActor.assumeIsolated { self?.drop(id) }
+        })
+    }
+
+    private func endpoint(_ id: ClientID) -> String {
+        clients[id].map { "\($0.connection.endpoint)" } ?? "?"
+    }
+
     private func schedulePing(_ id: ClientID) {
         clients[id]?.ping = scheduler.schedule(after: Self.pingInterval) { [weak self] in
             self?.ping(id)
@@ -264,8 +369,9 @@ public final class WebSocketServer {
         controller.clientDisconnected(id)
     }
 
+    /// Aux seuls clients authentifiés.
     private func broadcast(_ message: ServerMessage) {
-        for id in clients.keys {
+        for (id, client) in clients where client.authenticated {
             send(message, to: id)
         }
     }
PATCH
```

Modifier `mac/ptzd/Sources/ptzd/PTZDaemon.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/ptzd/PTZDaemon.swift b/mac/ptzd/Sources/ptzd/PTZDaemon.swift
index 7e0ddbf..69441b7 100644
--- a/mac/ptzd/Sources/ptzd/PTZDaemon.swift
+++ b/mac/ptzd/Sources/ptzd/PTZDaemon.swift
@@ -74,6 +74,7 @@ struct PTZDaemon {
             hosts: [config.listenAddress, "127.0.0.1"],
             port: UInt16(config.port),
             controller: controller,
+            authority: DeviceAuthority(directory: supportDirectory),
             scheduler: scheduler,
             log: log
         )
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : tout passe (Mac : 121 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add mac/ptzd/Package.swift \
    mac/ptzd/Sources/PTZServer/WebSocketServer.swift \
    mac/ptzd/Sources/ptzd/PTZDaemon.swift \
    mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
ptzd : défi, authentification et appairage sur le serveur WebSocket

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit.

### Tâche 5 : Relais vidéo vers go2rtc, et réglages `go2rtcAPI` et `streamName`

**But :** Après l'authentification, `webrtcOffer` est relayé à l'API locale de go2rtc ; la réponse ou l'erreur revient avec le même identifiant ; une nouvelle offre remplace la précédente (spec accès local § 6.5). `config.json` gagne `go2rtcAPI` (boucle locale seulement) et `streamName`.

**Fichiers :**
- Modifier : `mac/ptzd/Sources/PTZCore/PTZConfig.swift`
- Créer : `mac/ptzd/Sources/PTZServer/WebRTCRelay.swift`
- Modifier : `mac/ptzd/Sources/PTZServer/WebSocketServer.swift`
- Modifier : `mac/ptzd/Sources/ptzd/PTZDaemon.swift`
- Modifier : `mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift`
- Créer : `mac/ptzd/Tests/PTZServerTests/Go2rtcRelayTests.swift`
- Modifier : `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift`

**Interfaces :**
- Consomme : serveur de la tâche 4.
- Produit : protocole `WebRTCRelay` (`answer(offer:) async throws -> String`), `Go2rtcRelay(api:stream:session:)` (nil si l'adresse ne donne pas d'URL), `Go2rtcRelay.timeout` (10 s), `RelayError.badResponse(status:)` ; `WebSocketServer(…, relay:, …)` ; `PTZConfig.go2rtcAPI`, `PTZConfig.streamName`, `ConfigError.invalidGo2rtcAPI`.

- [ ] **Étape 1 : Écrire les tests**

Modifier `mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift b/mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift
index fb46c0d..e088414 100644
--- a/mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift
+++ b/mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift
@@ -51,6 +51,28 @@ struct PTZConfigTests {
         }
     }
 
+    @Test("go2rtc : API locale et flux par défaut, ou donnés")
+    func go2rtc() throws {
+        let defaults = try decode(#"{"listenAddress":"127.0.0.1"}"#)
+        #expect(defaults.go2rtcAPI == "http://127.0.0.1:1984")
+        #expect(defaults.streamName == "obsbot")
+        let custom = try decode(#"{"listenAddress":"127.0.0.1","go2rtcAPI":"http://localhost:2984","streamName":"cam"}"#)
+        #expect(custom.go2rtcAPI == "http://localhost:2984")
+        #expect(custom.streamName == "cam")
+    }
+
+    @Test("go2rtcAPI : boucle locale en http avec un port, sans chemin ; flux non vide")
+    func go2rtcValidation() {
+        for refused in ["http://192.168.1.10:1984", "https://127.0.0.1:1984", "http://127.0.0.1", "http://127.0.0.1:1984/api", "pas une url"] {
+            #expect(throws: ConfigError.invalidGo2rtcAPI(refused)) {
+                try decode(#"{"listenAddress":"127.0.0.1","go2rtcAPI":"\#(refused)"}"#)
+            }
+        }
+        #expect(throws: ConfigError.outOfRange("streamName")) {
+            try decode(#"{"listenAddress":"127.0.0.1","streamName":" "}"#)
+        }
+    }
+
     @Test("Chemin de obsbot-ai-off : relatif au dossier de travail, ou absolu")
     func aiOffURL() {
         let base = URL(fileURLWithPath: "/tmp/ObsbotNacelle")
PATCH
```

Créer `mac/ptzd/Tests/PTZServerTests/Go2rtcRelayTests.swift` :

```swift
import Foundation
import Testing
@testable import PTZServer

/// Réponses HTTP de test, sans réseau.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
        let (status, body) = Self.respond?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Relais vers go2rtc", .serialized)
struct Go2rtcRelayTests {
    private func makeRelay() throws -> Go2rtcRelay {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return try #require(Go2rtcRelay(api: "http://127.0.0.1:1984", stream: "obsbot", session: URLSession(configuration: configuration)))
    }

    @Test("POST /api/webrtc?src=<flux>, en application/sdp, offre dans le corps")
    func request() async throws {
        StubURLProtocol.respond = { _ in (201, Data("v=0\r\nréponse".utf8)) }
        let answer = try await makeRelay().answer(offer: "v=0\r\noffre")
        #expect(answer == "v=0\r\nréponse")
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "http://127.0.0.1:1984/api/webrtc?src=obsbot")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/sdp")
        #expect(StubURLProtocol.lastBody == Data("v=0\r\noffre".utf8))
    }

    @Test("Autre statut que 201, ou corps qui n'est pas un SDP : erreur")
    func badResponses() async throws {
        let relay = try makeRelay()
        StubURLProtocol.respond = { _ in (500, Data("v=0".utf8)) }
        await #expect(throws: RelayError.badResponse(status: 500)) { try await relay.answer(offer: "v=0") }
        StubURLProtocol.respond = { _ in (201, Data("oups".utf8)) }
        await #expect(throws: RelayError.badResponse(status: 201)) { try await relay.answer(offer: "v=0") }
    }
}
```

Modifier `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift b/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
index 7675561..9e9c15e 100644
--- a/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
+++ b/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
@@ -37,10 +37,11 @@ struct WebSocketServerTests {
         on hosts: [String] = ["127.0.0.1"],
         scheduler: any Scheduler = DispatchScheduler(),
         log: @escaping LogSink = { _ in },
-        trustLoopback: Bool = true
+        trustLoopback: Bool = true,
+        relay: any WebRTCRelay = FakeRelay { "v=0 réponse à \($0)" }
     ) async -> (WebSocketServer, [String: UInt16]) {
         let server = WebSocketServer(
-            hosts: hosts, port: 0, controller: controller, authority: authority,
+            hosts: hosts, port: 0, controller: controller, authority: authority, relay: relay,
             scheduler: scheduler, log: log, trustLoopback: trustLoopback
         )
         let ports = await withCheckedContinuation { continuation in
@@ -172,7 +173,7 @@ struct WebSocketServerTests {
     func duplicateHosts() async throws {
         let server = WebSocketServer(
             hosts: ["127.0.0.1", "127.0.0.1"], port: 0, controller: controller, authority: authority,
-            scheduler: DispatchScheduler(), log: { _ in }
+            relay: FakeRelay { $0 }, scheduler: DispatchScheduler(), log: { _ in }
         )
         var readyCount = 0
         server.onReady = { _, _ in readyCount += 1 }
@@ -346,6 +347,70 @@ struct WebSocketServerTests {
         withExtendedLifetime(server) {}
     }
 
+    @Test("Offre WebRTC relayée : réponse avec le même identifiant")
+    func relayAnswer() async throws {
+        let (server, ports) = await startServer()
+        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
+        defer { task.cancel(with: .goingAway, reason: nil) }
+        _ = try await next(task) { if case .state = $0 { true } else { false } }
+
+        try await send(.webrtcOffer(id: 7, sdp: "offre"), on: task)
+        #expect(try await next(task) { if case .webrtcAnswer = $0 { true } else { false } } == .webrtcAnswer(id: 7, sdp: "v=0 réponse à offre"))
+        withExtendedLifetime(server) {}
+    }
+
+    @Test("go2rtc en échec : webrtcError avec le même identifiant, journalisé")
+    func relayError() async throws {
+        let lines = LineBox()
+        let (server, ports) = await startServer(log: { lines.values.append($0) }, relay: FakeRelay { _ in throw RelayError.badResponse(status: 500) })
+        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
+        defer { task.cancel(with: .goingAway, reason: nil) }
+        _ = try await next(task) { if case .state = $0 { true } else { false } }
+
+        try await send(.webrtcOffer(id: 2, sdp: "offre"), on: task)
+        #expect(try await next(task) { if case .webrtcError = $0 { true } else { false } } == .webrtcError(id: 2, message: "go2rtc ne répond pas."))
+        #expect(lines.values.contains { $0.hasPrefix("Relais vidéo du client 1 en échec") })
+        withExtendedLifetime(server) {}
+    }
+
+    @Test("Offre avant l'authentification : refusée, go2rtc pas appelé")
+    func relayRequiresAuth() async throws {
+        let calls = CallCounter()
+        let (server, ports) = await startServer(trustLoopback: false, relay: FakeRelay { calls.increment(); return $0 })
+        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
+        defer { task.cancel(with: .goingAway, reason: nil) }
+        _ = try await challenge(task)
+
+        try await send(.webrtcOffer(id: 1, sdp: "offre"), on: task)
+        #expect(try await next(task) { _ in true } == .error(code: .notAuthenticated, message: "Authentification d'abord."))
+        #expect(calls.value == 0)
+        withExtendedLifetime(server) {}
+    }
+
+    @Test("Une nouvelle offre remplace la précédente : seule la dernière reçoit sa réponse")
+    func newOfferReplaces() async throws {
+        let relay = FakeRelay { offer in
+            if offer == "lente" {
+                try await Task.sleep(for: .seconds(1))
+            }
+            return "v=0 \(offer)"
+        }
+        let (server, ports) = await startServer(relay: relay)
+        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
+        defer { task.cancel(with: .goingAway, reason: nil) }
+        _ = try await next(task) { if case .state = $0 { true } else { false } }
+
+        try await send(.webrtcOffer(id: 1, sdp: "lente"), on: task)
+        try await send(.webrtcOffer(id: 2, sdp: "rapide"), on: task)
+        #expect(try await next(task) { if case .webrtcAnswer = $0 { true } else { false } } == .webrtcAnswer(id: 2, sdp: "v=0 rapide"))
+        try await Task.sleep(for: .milliseconds(1500))
+        try await task.send(.string("pas du json"))
+        // Après 1,5 s, le message suivant est l'erreur de lecture : la réponse à l'offre 1 n'est jamais partie.
+        let following = try await next(task) { if case .state = $0 { false } else { true } }
+        #expect(following == .error(code: .badMessage, message: "Message illisible."))
+        withExtendedLifetime(server) {}
+    }
+
     @Test("L'état n'est diffusé qu'aux clients authentifiés")
     func broadcastOnlyToAuthenticated() async throws {
         try pairTestDevice()
@@ -445,6 +510,33 @@ final class LineBox {
     var values: [String] = []
 }
 
+/// Relais WebRTC de test : la réponse est calculée à partir de l'offre.
+struct FakeRelay: WebRTCRelay {
+    let handler: @Sendable (String) async throws -> String
+
+    init(_ handler: @escaping @Sendable (String) async throws -> String) {
+        self.handler = handler
+    }
+
+    func answer(offer: String) async throws -> String {
+        try await handler(offer)
+    }
+}
+
+/// Compteur partagé avec un relais de test.
+final class CallCounter: @unchecked Sendable {
+    private let lock = NSLock()
+    private var count = 0
+
+    var value: Int {
+        lock.withLock { count }
+    }
+
+    func increment() {
+        lock.withLock { count += 1 }
+    }
+}
+
 @MainActor
 final class StubCamera: CameraDevice {
     var isPresent = true
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : échec — la compilation des tests échoue : `WebRTCRelay`, `Go2rtcRelay` et les nouveaux réglages n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Modifier `mac/ptzd/Sources/PTZCore/PTZConfig.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZCore/PTZConfig.swift b/mac/ptzd/Sources/PTZCore/PTZConfig.swift
index d8fec2a..495650f 100644
--- a/mac/ptzd/Sources/PTZCore/PTZConfig.swift
+++ b/mac/ptzd/Sources/PTZCore/PTZConfig.swift
@@ -3,6 +3,7 @@ import Foundation
 public enum ConfigError: Error, Equatable {
     case missingListenAddress
     case invalidListenAddress(String)
+    case invalidGo2rtcAPI(String)
     case outOfRange(String)
 }
 
@@ -15,9 +16,13 @@ public struct PTZConfig: Codable, Equatable, Sendable {
     public var panDirection: Int
     public var tiltDirection: Int
     public var aiOffPath: String
+    /// API locale de go2rtc, pour relayer les offres WebRTC (spec accès local § 6.5).
+    public var go2rtcAPI: String
+    /// Flux go2rtc relayé.
+    public var streamName: String
 
     private enum CodingKeys: String, CodingKey {
-        case listenAddress, port, panMaxSpeed, tiltMaxSpeed, panDirection, tiltDirection, aiOffPath
+        case listenAddress, port, panMaxSpeed, tiltMaxSpeed, panDirection, tiltDirection, aiOffPath, go2rtcAPI, streamName
     }
 
     public init(
@@ -27,7 +32,9 @@ public struct PTZConfig: Codable, Equatable, Sendable {
         tiltMaxSpeed: Int = 60,
         panDirection: Int = 1,
         tiltDirection: Int = 1,
-        aiOffPath: String = "bin/obsbot-ai-off"
+        aiOffPath: String = "bin/obsbot-ai-off",
+        go2rtcAPI: String = "http://127.0.0.1:1984",
+        streamName: String = "obsbot"
     ) {
         self.listenAddress = listenAddress
         self.port = port
@@ -36,6 +43,8 @@ public struct PTZConfig: Codable, Equatable, Sendable {
         self.panDirection = panDirection
         self.tiltDirection = tiltDirection
         self.aiOffPath = aiOffPath
+        self.go2rtcAPI = go2rtcAPI
+        self.streamName = streamName
     }
 
     public init(from decoder: any Decoder) throws {
@@ -50,7 +59,9 @@ public struct PTZConfig: Codable, Equatable, Sendable {
             tiltMaxSpeed: try c.decodeIfPresent(Int.self, forKey: .tiltMaxSpeed) ?? 60,
             panDirection: try c.decodeIfPresent(Int.self, forKey: .panDirection) ?? 1,
             tiltDirection: try c.decodeIfPresent(Int.self, forKey: .tiltDirection) ?? 1,
-            aiOffPath: try c.decodeIfPresent(String.self, forKey: .aiOffPath) ?? "bin/obsbot-ai-off"
+            aiOffPath: try c.decodeIfPresent(String.self, forKey: .aiOffPath) ?? "bin/obsbot-ai-off",
+            go2rtcAPI: try c.decodeIfPresent(String.self, forKey: .go2rtcAPI) ?? "http://127.0.0.1:1984",
+            streamName: try c.decodeIfPresent(String.self, forKey: .streamName) ?? "obsbot"
         )
     }
 
@@ -73,6 +84,18 @@ public struct PTZConfig: Codable, Equatable, Sendable {
         guard (1...120).contains(tiltMaxSpeed) else { throw ConfigError.outOfRange("tiltMaxSpeed") }
         guard [1, -1].contains(panDirection) else { throw ConfigError.outOfRange("panDirection") }
         guard [1, -1].contains(tiltDirection) else { throw ConfigError.outOfRange("tiltDirection") }
+        guard Self.isLocalHTTP(go2rtcAPI) else { throw ConfigError.invalidGo2rtcAPI(go2rtcAPI) }
+        guard !streamName.trimmingCharacters(in: .whitespaces).isEmpty else { throw ConfigError.outOfRange("streamName") }
+    }
+
+    /// L'API go2rtc n'écoute que sur la boucle locale (spec accès local § 7) : `http://127.0.0.1:<port>`
+    /// ou `http://localhost:<port>`, sans chemin.
+    static func isLocalHTTP(_ text: String) -> Bool {
+        guard let url = URLComponents(string: text), url.scheme == "http", url.port != nil,
+              url.path.isEmpty || url.path == "/", url.query == nil else {
+            return false
+        }
+        return url.host == "127.0.0.1" || url.host == "localhost"
     }
 
     static func isAllowedListenAddress(_ text: String) -> Bool {
PATCH
```

Créer `mac/ptzd/Sources/PTZServer/WebRTCRelay.swift` :

```swift
import Foundation

public enum RelayError: Error, Equatable {
    /// Réponse de go2rtc autre que `201` avec un SDP.
    case badResponse(status: Int)
}

/// Négociation WebRTC relayée à go2rtc pour un client authentifié (spec accès local § 6.5).
public protocol WebRTCRelay: Sendable {
    /// Le SDP de réponse à cette offre.
    func answer(offer: String) async throws -> String
}

/// `POST <api>/api/webrtc?src=<flux>` sur l'API locale de go2rtc, `application/sdp`, 10 s au plus.
public struct Go2rtcRelay: WebRTCRelay {
    public static let timeout: TimeInterval = 10

    let endpoint: URL
    private let session: URLSession

    /// Nil si l'adresse de l'API ne donne pas d'URL.
    public init?(api: String, stream: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        guard var components = URLComponents(string: api) else { return nil }
        components.path = "/api/webrtc"
        components.queryItems = [URLQueryItem(name: "src", value: stream)]
        guard let endpoint = components.url else { return nil }
        self.endpoint = endpoint
        self.session = session
    }

    public func answer(offer: String) async throws -> String {
        var request = URLRequest(url: endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(offer.utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201, let sdp = String(data: data, encoding: .utf8), sdp.hasPrefix("v=0") else {
            throw RelayError.badResponse(status: status)
        }
        return sdp
    }
}
```

Modifier `mac/ptzd/Sources/PTZServer/WebSocketServer.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZServer/WebSocketServer.swift b/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
index d3806b3..ffa3e84 100644
--- a/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
+++ b/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
@@ -31,6 +31,7 @@ public final class WebSocketServer {
     private let port: UInt16
     private let controller: PTZController
     private let authority: DeviceAuthority
+    private let relay: any WebRTCRelay
     private let scheduler: any Scheduler
     private let log: LogSink
     private let trustLoopback: Bool
@@ -49,11 +50,14 @@ public final class WebSocketServer {
         var deadline: (any Cancellable)?
         var ping: (any Cancellable)?
         var pongDeadline: (any Cancellable)?
+        /// Négociation vidéo en cours ; une nouvelle offre la remplace.
+        var negotiation: Task<Void, Never>?
 
         func cancelTimers() {
             deadline?.cancel()
             ping?.cancel()
             pongDeadline?.cancel()
+            negotiation?.cancel()
         }
     }
 
@@ -69,6 +73,7 @@ public final class WebSocketServer {
         port: UInt16,
         controller: PTZController,
         authority: DeviceAuthority,
+        relay: any WebRTCRelay,
         scheduler: any Scheduler,
         log: @escaping LogSink,
         trustLoopback: Bool = true
@@ -81,6 +86,7 @@ public final class WebSocketServer {
         self.port = port
         self.controller = controller
         self.authority = authority
+        self.relay = relay
         self.scheduler = scheduler
         self.log = log
         self.trustLoopback = trustLoopback
@@ -257,6 +263,12 @@ public final class WebSocketServer {
         case let .auth(deviceID, signature):
             guard !client.authenticated else { return }
             verify(id, deviceID: deviceID, signature: signature)
+        case let .webrtcOffer(offerID, sdp):
+            guard client.authenticated else {
+                send(.error(code: .notAuthenticated, message: "Authentification d'abord."), to: id)
+                return
+            }
+            relayOffer(id, offerID: offerID, sdp: sdp)
         default:
             guard client.authenticated else {
                 send(.error(code: .notAuthenticated, message: "Authentification d'abord."), to: id)
@@ -302,6 +314,24 @@ public final class WebSocketServer {
         }
     }
 
+    /// Relaie l'offre à go2rtc ; la réponse ou l'erreur porte l'identifiant de l'offre.
+    private func relayOffer(_ id: ClientID, offerID: Int, sdp: String) {
+        clients[id]?.negotiation?.cancel()
+        let relay = relay
+        clients[id]?.negotiation = Task { [weak self] in
+            let reply: ServerMessage
+            do {
+                reply = .webrtcAnswer(id: offerID, sdp: try await relay.answer(offer: sdp))
+            } catch {
+                guard !Task.isCancelled else { return }
+                self?.log("Relais vidéo du client \(id) en échec : \(error).")
+                reply = .webrtcError(id: offerID, message: "go2rtc ne répond pas.")
+            }
+            guard !Task.isCancelled else { return }
+            self?.send(reply, to: id)
+        }
+    }
+
     private func authenticate(_ id: ClientID) {
         clients[id]?.authenticated = true
         clients[id]?.deadline?.cancel()
PATCH
```

Modifier `mac/ptzd/Sources/ptzd/PTZDaemon.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/ptzd/PTZDaemon.swift b/mac/ptzd/Sources/ptzd/PTZDaemon.swift
index 69441b7..4ca033a 100644
--- a/mac/ptzd/Sources/ptzd/PTZDaemon.swift
+++ b/mac/ptzd/Sources/ptzd/PTZDaemon.swift
@@ -68,6 +68,10 @@ struct PTZDaemon {
             log: log
         )
         camera.onPresenceChange = { controller.cameraPresenceChanged($0) }
+        guard let relay = Go2rtcRelay(api: config.go2rtcAPI, stream: config.streamName) else {
+            log("go2rtcAPI invalide : \(config.go2rtcAPI)")
+            exit(78)
+        }
         // 127.0.0.1 en plus de l'adresse Tailscale : le Mac ne peut pas se joindre
         // lui-même par Tailscale, et les diagnostics locaux en ont besoin.
         let server = WebSocketServer(
@@ -75,6 +79,7 @@ struct PTZDaemon {
             port: UInt16(config.port),
             controller: controller,
             authority: DeviceAuthority(directory: supportDirectory),
+            relay: relay,
             scheduler: scheduler,
             log: log
         )
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : tout passe (Mac : 129 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add mac/ptzd/Sources/PTZCore/PTZConfig.swift \
    mac/ptzd/Sources/PTZServer/WebRTCRelay.swift \
    mac/ptzd/Sources/PTZServer/WebSocketServer.swift \
    mac/ptzd/Sources/ptzd/PTZDaemon.swift \
    mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift \
    mac/ptzd/Tests/PTZServerTests/Go2rtcRelayTests.swift \
    mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
ptzd : relais de la négociation vidéo vers l'API locale de go2rtc

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit.

### Tâche 6 : Écoute sur le réseau local et annonce Bonjour

**But :** `ptzd` écoute aussi sur chaque interface Wi-Fi et Ethernet filaire, liée à l'interface ET à son adresse IPv4, suit les changements d'adresse, et s'annonce une seule fois en `_nacelle._tcp` (spec accès local § 6.1 et § 6.2). Réglage `localNetwork` (vrai par défaut).

**Fichiers :**
- Modifier : `mac/ptzd/Sources/PTZCore/PTZConfig.swift`
- Créer : `mac/ptzd/Sources/PTZServer/LocalNetworkListeners.swift`
- Modifier : `mac/ptzd/Sources/PTZServer/WebSocketServer.swift`
- Modifier : `mac/ptzd/Sources/ptzd/PTZDaemon.swift`
- Modifier : `mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift`
- Créer : `mac/ptzd/Tests/PTZServerTests/LocalNetworkListenersTests.swift`

**Interfaces :**
- Consomme : `WebSocketServer` (tâches 4 et 5).
- Produit : `LocalNetworkListeners` (interne à `PTZServer`) ; `WebSocketServer(…, localNetwork: Bool = false)` ; `PTZConfig.localNetwork`. Les connexions du réseau local ne sont jamais de confiance : elles passent par le défi.
- Faits vérifiés sur ce Mac (macOS 27) et repris dans le code : sans `allowLocalEndpointReuse`, la deuxième écoute sur le même port échoue (EADDRINUSE) ; une écoute liée à l'interface seule ou filtrée par types d'interface s'ouvre aussi sur Tailscale et les ponts de machines virtuelles ; une même adresse ne se relie qu'après `.cancelled`.

- [ ] **Étape 1 : Écrire les tests**

Modifier `mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift b/mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift
index e088414..c768a16 100644
--- a/mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift
+++ b/mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift
@@ -63,7 +63,7 @@ struct PTZConfigTests {
 
     @Test("go2rtcAPI : boucle locale en http avec un port, sans chemin ; flux non vide")
     func go2rtcValidation() {
-        for refused in ["http://192.168.1.10:1984", "https://127.0.0.1:1984", "http://127.0.0.1", "http://127.0.0.1:1984/api", "pas une url"] {
+        for refused in ["http://192.0.2.10:1984", "https://127.0.0.1:1984", "http://127.0.0.1", "http://127.0.0.1:1984/api", "pas une url"] {
             #expect(throws: ConfigError.invalidGo2rtcAPI(refused)) {
                 try decode(#"{"listenAddress":"127.0.0.1","go2rtcAPI":"\#(refused)"}"#)
             }
@@ -73,6 +73,12 @@ struct PTZConfigTests {
         }
     }
 
+    @Test("Réseau local : actif par défaut, coupé par localNetwork false")
+    func localNetwork() throws {
+        #expect(try decode(#"{"listenAddress":"127.0.0.1"}"#).localNetwork)
+        #expect(try !decode(#"{"listenAddress":"127.0.0.1","localNetwork":false}"#).localNetwork)
+    }
+
     @Test("Chemin de obsbot-ai-off : relatif au dossier de travail, ou absolu")
     func aiOffURL() {
         let base = URL(fileURLWithPath: "/tmp/ObsbotNacelle")
PATCH
```

Créer `mac/ptzd/Tests/PTZServerTests/LocalNetworkListenersTests.swift` :

```swift
import Testing
@testable import PTZServer

@Suite("Écoute sur le réseau local : décisions")
struct LocalNetworkListenersTests {
    @Test("Nouvelles interfaces : liées ; adresse changée ou perdue : retirée, reliée au tour suivant")
    func changes() {
        let first = LocalNetworkListeners.changes(bound: [:], wanted: ["en0": "192.0.2.43", "en18": "192.0.2.30"], cancelling: [])
        #expect(first.retire.isEmpty)
        #expect(first.bind == ["en0", "en18"])

        let moved = LocalNetworkListeners.changes(bound: ["en0": "192.0.2.43", "en18": "192.0.2.30"], wanted: ["en0": "192.0.2.44"], cancelling: [])
        #expect(moved.retire == ["en0", "en18"])
        #expect(moved.bind.isEmpty)

        let waiting = LocalNetworkListeners.changes(bound: [:], wanted: ["en0": "192.0.2.44"], cancelling: ["en0"])
        #expect(waiting.bind.isEmpty)

        let stable = LocalNetworkListeners.changes(bound: ["en0": "192.0.2.43"], wanted: ["en0": "192.0.2.43"], cancelling: [])
        #expect(stable.retire.isEmpty && stable.bind.isEmpty)
    }

    @Test("Annonce : garde son interface, sinon une filaire, sinon la première par nom")
    func serviceHolder() {
        #expect(LocalNetworkListeners.serviceHolder(current: nil, bound: [:]) == nil)
        #expect(LocalNetworkListeners.serviceHolder(current: nil, bound: ["en0": false, "en18": true]) == "en18")
        #expect(LocalNetworkListeners.serviceHolder(current: "en0", bound: ["en0": false, "en18": true]) == "en0")
        #expect(LocalNetworkListeners.serviceHolder(current: "en18", bound: ["en0": false]) == "en0")
        #expect(LocalNetworkListeners.serviceHolder(current: nil, bound: ["en1": false, "en0": false]) == "en0")
    }

    @Test("Adresse auto-attribuée 169.254.x.x : pas d'écoute")
    func usable() {
        #expect(LocalNetworkListeners.isUsable("192.0.2.30"))
        #expect(!LocalNetworkListeners.isUsable("169.254.10.2"))
    }
}
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : échec — la compilation des tests échoue : `LocalNetworkListeners` et `localNetwork` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Modifier `mac/ptzd/Sources/PTZCore/PTZConfig.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZCore/PTZConfig.swift b/mac/ptzd/Sources/PTZCore/PTZConfig.swift
index 495650f..5daee5f 100644
--- a/mac/ptzd/Sources/PTZCore/PTZConfig.swift
+++ b/mac/ptzd/Sources/PTZCore/PTZConfig.swift
@@ -20,9 +20,11 @@ public struct PTZConfig: Codable, Equatable, Sendable {
     public var go2rtcAPI: String
     /// Flux go2rtc relayé.
     public var streamName: String
+    /// Écoute et annonce Bonjour sur le réseau local (spec accès local § 6.1).
+    public var localNetwork: Bool
 
     private enum CodingKeys: String, CodingKey {
-        case listenAddress, port, panMaxSpeed, tiltMaxSpeed, panDirection, tiltDirection, aiOffPath, go2rtcAPI, streamName
+        case listenAddress, port, panMaxSpeed, tiltMaxSpeed, panDirection, tiltDirection, aiOffPath, go2rtcAPI, streamName, localNetwork
     }
 
     public init(
@@ -34,7 +36,8 @@ public struct PTZConfig: Codable, Equatable, Sendable {
         tiltDirection: Int = 1,
         aiOffPath: String = "bin/obsbot-ai-off",
         go2rtcAPI: String = "http://127.0.0.1:1984",
-        streamName: String = "obsbot"
+        streamName: String = "obsbot",
+        localNetwork: Bool = true
     ) {
         self.listenAddress = listenAddress
         self.port = port
@@ -45,6 +48,7 @@ public struct PTZConfig: Codable, Equatable, Sendable {
         self.aiOffPath = aiOffPath
         self.go2rtcAPI = go2rtcAPI
         self.streamName = streamName
+        self.localNetwork = localNetwork
     }
 
     public init(from decoder: any Decoder) throws {
@@ -61,7 +65,8 @@ public struct PTZConfig: Codable, Equatable, Sendable {
             tiltDirection: try c.decodeIfPresent(Int.self, forKey: .tiltDirection) ?? 1,
             aiOffPath: try c.decodeIfPresent(String.self, forKey: .aiOffPath) ?? "bin/obsbot-ai-off",
             go2rtcAPI: try c.decodeIfPresent(String.self, forKey: .go2rtcAPI) ?? "http://127.0.0.1:1984",
-            streamName: try c.decodeIfPresent(String.self, forKey: .streamName) ?? "obsbot"
+            streamName: try c.decodeIfPresent(String.self, forKey: .streamName) ?? "obsbot",
+            localNetwork: try c.decodeIfPresent(Bool.self, forKey: .localNetwork) ?? true
         )
     }
 
@@ -73,7 +78,8 @@ public struct PTZConfig: Codable, Equatable, Sendable {
     }
 
     /// Adresse d'écoute : 127.0.0.1 ou une adresse Tailscale (plage CGNAT 100.64.0.0/10),
-    /// jamais 0.0.0.0 ni une adresse du réseau local (spec § 6.10).
+    /// jamais 0.0.0.0 ni une adresse du réseau local : le réseau local passe par `localNetwork`
+    /// (spec accès local § 6.1).
     /// Bornes de la Tiny 2 : vitesse pan 1–80, tilt 1–120 (test de faisabilité).
     public func validate() throws {
         guard Self.isAllowedListenAddress(listenAddress) else {
PATCH
```

Créer `mac/ptzd/Sources/PTZServer/LocalNetworkListeners.swift` :

```swift
import Darwin
import Foundation
import Network
import PTZCore

/// Écoute sur le réseau local (spec accès local § 6.1 et § 6.2) : une écoute par interface Wi-Fi ou
/// Ethernet filaire, liée à l'interface ET à son adresse IPv4 (jamais aux VPN, aux ponts de machines
/// virtuelles ni à la boucle locale), qui suit les changements d'adresse ; une seule annonce Bonjour.
/// Vérifié sur macOS 27 : sans `allowLocalEndpointReuse`, la deuxième écoute sur le même port échoue
/// (EADDRINUSE) ; une écoute liée à l'interface seule ou par types d'interface s'ouvre trop largement.
@MainActor
final class LocalNetworkListeners {
    /// Filet de sécurité : un changement d'adresse DHCP ne déclenche pas toujours le moniteur de chemin.
    static let reconcileInterval: TimeInterval = 30
    static let serviceName = "Nacelle"
    static let serviceType = "_nacelle._tcp"

    private struct Bound {
        let address: String
        let isWired: Bool
        let listener: NWListener
    }

    private let port: NWEndpoint.Port
    private let makeParameters: () -> NWParameters
    private let onConnection: (NWConnection) -> Void
    private let scheduler: any Scheduler
    private let log: LogSink
    private let monitor = NWPathMonitor()
    private var interfaces: [NWInterface] = []
    private var bound: [String: Bound] = [:]
    /// Interfaces dont l'écoute se ferme : la même adresse et le même port ne se relient qu'après `.cancelled`.
    private var cancelling: Set<String> = []
    private var serviceHolder: String?
    private var timer: (any Cancellable)?

    init(port: UInt16, makeParameters: @escaping () -> NWParameters, onConnection: @escaping (NWConnection) -> Void, scheduler: any Scheduler, log: @escaping LogSink) {
        self.port = NWEndpoint.Port(rawValue: port) ?? .any
        self.makeParameters = makeParameters
        self.onConnection = onConnection
        self.scheduler = scheduler
        self.log = log
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self else { return }
                var seen = Set<String>()
                self.interfaces = path.availableInterfaces.filter {
                    ($0.type == .wifi || $0.type == .wiredEthernet) && seen.insert($0.name).inserted
                }
                self.reconcile()
            }
        }
        monitor.start(queue: .main)
        scheduleReconcile()
    }

    private func scheduleReconcile() {
        timer = scheduler.schedule(after: Self.reconcileInterval) { [weak self] in
            self?.reconcile()
            self?.scheduleReconcile()
        }
    }

    private func reconcile() {
        var wanted: [String: String] = [:]
        for interface in interfaces {
            if let address = Self.ipv4(of: interface.name), Self.isUsable(address) {
                wanted[interface.name] = address
            }
        }
        let changes = Self.changes(bound: bound.mapValues(\.address), wanted: wanted, cancelling: cancelling)
        for name in changes.retire {
            log("Écoute locale sur \(name) retirée (adresse changée ou perdue).")
            retire(name)
        }
        for name in changes.bind {
            guard let interface = interfaces.first(where: { $0.name == name }), let address = wanted[name] else { continue }
            bind(interface, address: address)
        }
        assignService()
    }

    /// Ce qu'il faut défaire puis faire pour passer des écoutes actuelles aux interfaces voulues.
    nonisolated static func changes(bound: [String: String], wanted: [String: String], cancelling: Set<String>) -> (retire: [String], bind: [String]) {
        let retire = bound.filter { wanted[$0.key] != $0.value }.keys.sorted()
        // Une interface retirée se relie après `.cancelled`, au tour suivant.
        let bind = wanted.keys.filter { bound[$0] == nil && !cancelling.contains($0) }.sorted()
        return (retire, bind)
    }

    /// L'interface qui porte l'annonce : celle qui la porte déjà si elle écoute encore,
    /// sinon une filaire, sinon la première par nom.
    nonisolated static func serviceHolder(current: String?, bound: [String: Bool]) -> String? {
        if let current, bound[current] != nil {
            return current
        }
        return bound.sorted { ($0.value ? 0 : 1, $0.key) < ($1.value ? 0 : 1, $1.key) }.first?.key
    }

    /// Une adresse IPv4 attribuée par le réseau (pas l'auto-attribution 169.254.0.0/16).
    nonisolated static func isUsable(_ address: String) -> Bool {
        !address.hasPrefix("169.254.")
    }

    private func bind(_ interface: NWInterface, address: String) {
        let parameters = makeParameters()
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterface = interface
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
        let name = interface.name
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            log("Écoute locale sur \(name) impossible (\(error)).")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.onConnection(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.bound[name]?.listener === listener else { return }
                switch state {
                case .ready:
                    self.log("Écoute locale sur \(name) (\(address)):\(self.port).")
                case let .failed(error), let .waiting(error):
                    self.log("Écoute locale sur \(name) en échec (\(error)).")
                    self.retire(name)
                default:
                    break
                }
            }
        }
        bound[name] = Bound(address: address, isWired: interface.type == .wiredEthernet, listener: listener)
        listener.start(queue: .main)
    }

    private func retire(_ name: String) {
        guard let entry = bound.removeValue(forKey: name) else { return }
        if serviceHolder == name {
            entry.listener.service = nil
            serviceHolder = nil
        }
        cancelling.insert(name)
        entry.listener.stateUpdateHandler = { [weak self] state in
            guard case .cancelled = state else { return }
            MainActor.assumeIsolated {
                self?.cancelling.remove(name)
                self?.reconcile()
            }
        }
        entry.listener.cancel()
    }

    private func assignService() {
        let holder = Self.serviceHolder(current: serviceHolder, bound: bound.mapValues(\.isWired))
        guard holder != serviceHolder else { return }
        if let old = serviceHolder {
            bound[old]?.listener.service = nil
        }
        serviceHolder = holder
        guard let holder, let listener = bound[holder]?.listener else { return }
        var txt = NWTXTRecord()
        txt["v"] = "1"
        listener.service = NWListener.Service(name: Self.serviceName, type: Self.serviceType, txtRecord: txt)
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            MainActor.assumeIsolated {
                if case .add = change {
                    self?.log("Annonce Bonjour \(Self.serviceType) sur \(holder).")
                }
            }
        }
    }

    /// Première adresse IPv4 de l'interface, ou nil.
    nonisolated static func ipv4(of name: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(first) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = current {
            let entry = pointer.pointee
            if let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), String(cString: entry.ifa_name) == name {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            current = entry.ifa_next
        }
        return nil
    }
}
```

Modifier `mac/ptzd/Sources/PTZServer/WebSocketServer.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZServer/WebSocketServer.swift b/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
index ffa3e84..d9f92a7 100644
--- a/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
+++ b/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
@@ -35,7 +35,9 @@ public final class WebSocketServer {
     private let scheduler: any Scheduler
     private let log: LogSink
     private let trustLoopback: Bool
+    private let localNetwork: Bool
     private var listeners: [String: NWListener] = [:]
+    private var localListeners: LocalNetworkListeners?
     private var clients: [ClientID: Client] = [:]
     private var nextID: ClientID = 1
 
@@ -76,7 +78,8 @@ public final class WebSocketServer {
         relay: any WebRTCRelay,
         scheduler: any Scheduler,
         log: @escaping LogSink,
-        trustLoopback: Bool = true
+        trustLoopback: Bool = true,
+        localNetwork: Bool = false
     ) {
         self.hosts = hosts.reduce(into: []) { unique, host in
             if !unique.contains(host) {
@@ -90,20 +93,34 @@ public final class WebSocketServer {
         self.scheduler = scheduler
         self.log = log
         self.trustLoopback = trustLoopback
+        self.localNetwork = localNetwork
         controller.onStateChange = { [weak self] snapshot in
             self?.broadcast(.state(snapshot))
         }
     }
 
     /// Ouvre l'écoute sur chaque adresse. En cas d'échec (adresse Tailscale pas
-    /// encore là), réessaie toutes les 5 s pour cette adresse.
+    /// encore là), réessaie toutes les 5 s pour cette adresse. Puis, si demandé, sur le
+    /// réseau local, où chaque connexion doit s'authentifier.
     public func start() {
         for host in hosts {
             listen(on: host)
         }
+        if localNetwork {
+            let local = LocalNetworkListeners(
+                port: port,
+                makeParameters: { [unowned self] in self.makeParameters() },
+                onConnection: { [weak self] connection in self?.accept(connection, trusted: false) },
+                scheduler: scheduler,
+                log: log
+            )
+            localListeners = local
+            local.start()
+        }
     }
 
-    private func listen(on host: String) {
+    /// TCP avec keepalive et WebSocket, sans adresse locale : chaque écoute ajoute la sienne.
+    private func makeParameters() -> NWParameters {
         // Keepalive TCP : une connexion morte (iPhone suspendu, réseau coupé) est fermée
         // après environ 25 s au lieu de garder une des 4 places indéfiniment.
         let tcp = NWProtocolTCP.Options()
@@ -124,6 +141,11 @@ public final class WebSocketServer {
             return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: [Self.rejectionMarker])
         }
         parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
+        return parameters
+    }
+
+    private func listen(on host: String) {
+        let parameters = makeParameters()
         parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
         parameters.allowLocalEndpointReuse = true
         let listener: NWListener
PATCH
```

Modifier `mac/ptzd/Sources/ptzd/PTZDaemon.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/ptzd/PTZDaemon.swift b/mac/ptzd/Sources/ptzd/PTZDaemon.swift
index 4ca033a..94a6c1d 100644
--- a/mac/ptzd/Sources/ptzd/PTZDaemon.swift
+++ b/mac/ptzd/Sources/ptzd/PTZDaemon.swift
@@ -81,7 +81,8 @@ struct PTZDaemon {
             authority: DeviceAuthority(directory: supportDirectory),
             relay: relay,
             scheduler: scheduler,
-            log: log
+            log: log,
+            localNetwork: config.localNetwork
         )
 
         log("ptzd démarre.")
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : tout passe (Mac : 133 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Essai à la main sur un port libre, sans toucher au service installé**

La prise en main est remplacée par `/usr/bin/true` : aucun appel au SDK, et la caméra ne bouge pas tant qu'aucun client ne l'ordonne.

```bash
D=$(mktemp -d); printf '{"listenAddress":"127.0.0.1","port":19870,"aiOffPath":"/usr/bin/true"}' > $D/config.json
(cd mac/ptzd && PTZD_SUPPORT_DIR=$D .build/debug/ptzd > $D/run.log 2>&1 & echo $! > $D/pid); sleep 3; sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g' $D/run.log
(dns-sd -B _nacelle._tcp > $D/dns.log 2>&1 &); sleep 3; pkill -f 'dns-sd -B _nacelle._tcp'; grep -c Nacelle $D/dns.log
kill $(cat $D/pid); rm -rf $D
```

Attendu : « En écoute sur 127.0.0.1:19870. », une ligne « Écoute locale sur <interface> (<ip>):19870. » par interface Wi-Fi ou Ethernet active, « Annonce Bonjour _nacelle._tcp sur <interface>. », puis au moins une ligne `Nacelle` vue par `dns-sd`. Si macOS demande d'autoriser `ptzd` sur le réseau, la réponse importe peu pour cet essai : le noter dans le rapport.

- [ ] **Étape 6 : Commiter et pousser**

```bash
git add mac/ptzd/Sources/PTZCore/PTZConfig.swift \
    mac/ptzd/Sources/PTZServer/LocalNetworkListeners.swift \
    mac/ptzd/Sources/PTZServer/WebSocketServer.swift \
    mac/ptzd/Sources/ptzd/PTZDaemon.swift \
    mac/ptzd/Tests/PTZCoreTests/PTZConfigTests.swift \
    mac/ptzd/Tests/PTZServerTests/LocalNetworkListenersTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
ptzd : écoute sur le réseau local et annonce Bonjour

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit.

### Tâche 7 : iOS : clé de l'appareil

**But :** La clé ECDSA P-256 de l'iPhone, dans la Secure Enclave (logicielle si elle manque), rangée dans le trousseau (spec accès local § 8.2).

**Fichiers :**
- Créer : `ios/Nacelle/Pairing/DeviceKey.swift`
- Créer : `ios/NacelleTests/DeviceKeyTests.swift`

**Interfaces :**
- Consomme : `NacelleAuth` (tâche 1).
- Produit : protocole `DeviceKey` (`publicKeyX963`, `sign(_:)`, et en extension `deviceID`, `signChallenge(_:)`), `SecureEnclaveDeviceKey`, `SoftwareDeviceKey`, protocole `DeviceKeyStoring` (`load()`, `loadOrCreate()`, `delete()`), `KeychainDeviceKeyStore(useSecureEnclave:)`.
- Constaté : le simulateur iOS 27 a une Secure Enclave ; le test qui force la clé logicielle couvre l'autre branche.

- [ ] **Étape 1 : Écrire les tests**

Créer `ios/NacelleTests/DeviceKeyTests.swift` :

```swift
import CryptoKit
import Foundation
import NacelleProtocol
import Testing
@testable import Nacelle

@MainActor
@Suite("Clé de l'appareil", .serialized)
struct DeviceKeyTests {
    let store = KeychainDeviceKeyStore(useSecureEnclave: false)

    init() {
        store.delete()
    }

    @Test("Pas de clé au départ ; créée une fois, puis relue à l'identique")
    func createThenLoad() throws {
        #expect(store.load() == nil)
        let created = try store.loadOrCreate()
        #expect(store.load()?.publicKeyX963 == created.publicKeyX963)
        #expect(try store.loadOrCreate().publicKeyX963 == created.publicKeyX963)
        store.delete()
        #expect(store.load() == nil)
    }

    @Test("La réponse au défi se vérifie comme le fera ptzd")
    func challengeVerifies() throws {
        let key = try store.loadOrCreate()
        let nonce = Data((0..<32).map { UInt8($0) })
        let signature = try key.signChallenge(nonce)
        #expect(NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: key.deviceID, publicKeyX963: key.publicKeyX963))
        store.delete()
    }

    @Test("Secure Enclave : utilisée seulement si disponible (absente du simulateur)")
    func secureEnclaveAvailability() throws {
        let store = KeychainDeviceKeyStore()
        defer { store.delete() }
        let key = try store.loadOrCreate()
        if SecureEnclave.isAvailable {
            #expect(key is SecureEnclaveDeviceKey)
        } else {
            #expect(key is SoftwareDeviceKey)
        }
    }
}
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : échec — la compilation des tests échoue : `KeychainDeviceKeyStore` et `DeviceKey` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Créer `ios/Nacelle/Pairing/DeviceKey.swift` :

```swift
import CryptoKit
import Foundation
import NacelleProtocol
import Security

/// Clé de l'iPhone pour s'authentifier auprès de ptzd (spec accès local § 8.2) : ECDSA P-256,
/// dans la Secure Enclave quand elle existe, logicielle sinon (simulateur).
protocol DeviceKey: Sendable {
    /// Clé publique, format x963.
    var publicKeyX963: Data { get }
    /// Signature DER de `data`.
    func sign(_ data: Data) throws -> Data
}

extension DeviceKey {
    var deviceID: String {
        NacelleAuth.deviceID(publicKeyX963: publicKeyX963)
    }

    /// Réponse au défi de ptzd.
    func signChallenge(_ nonce: Data) throws -> Data {
        try sign(NacelleAuth.signedPayload(nonce: nonce, deviceID: deviceID))
    }
}

struct SecureEnclaveDeviceKey: DeviceKey {
    let key: SecureEnclave.P256.Signing.PrivateKey

    var publicKeyX963: Data {
        key.publicKey.x963Representation
    }

    func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).derRepresentation
    }
}

struct SoftwareDeviceKey: DeviceKey {
    let key: P256.Signing.PrivateKey

    var publicKeyX963: Data {
        key.publicKey.x963Representation
    }

    func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).derRepresentation
    }
}

/// Où l'app garde sa clé. Derrière un protocole pour les tests.
@MainActor
protocol DeviceKeyStoring: AnyObject {
    /// La clé existante, ou nil.
    func load() -> (any DeviceKey)?
    /// La clé existante, ou une nouvelle, enregistrée.
    func loadOrCreate() throws -> any DeviceKey
    /// Oublie la clé.
    func delete()
}

enum DeviceKeyError: Error, Equatable {
    case keychain(OSStatus)
}

/// La clé dans le trousseau : une entrée par sorte de clé, accessible après le premier
/// déverrouillage, jamais sauvegardée hors de cet iPhone. Une clé Secure Enclave n'y laisse
/// qu'une forme chiffrée, inutilisable sur un autre appareil.
@MainActor
final class KeychainDeviceKeyStore: DeviceKeyStoring {
    static let service = "io.github.djoko-cli.nacelle.device-key"
    private static let secureEnclaveAccount = "secure-enclave"
    private static let softwareAccount = "software"

    private let useSecureEnclave: Bool

    init(useSecureEnclave: Bool = SecureEnclave.isAvailable) {
        self.useSecureEnclave = useSecureEnclave
    }

    func load() -> (any DeviceKey)? {
        if useSecureEnclave, let data = Self.read(Self.secureEnclaveAccount),
           let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
            return SecureEnclaveDeviceKey(key: key)
        }
        if !useSecureEnclave, let data = Self.read(Self.softwareAccount),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return SoftwareDeviceKey(key: key)
        }
        return nil
    }

    func loadOrCreate() throws -> any DeviceKey {
        if let key = load() {
            return key
        }
        if useSecureEnclave {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            try Self.write(key.dataRepresentation, account: Self.secureEnclaveAccount)
            return SecureEnclaveDeviceKey(key: key)
        }
        let key = P256.Signing.PrivateKey()
        try Self.write(key.rawRepresentation, account: Self.softwareAccount)
        return SoftwareDeviceKey(key: key)
    }

    func delete() {
        for account in [Self.secureEnclaveAccount, Self.softwareAccount] {
            SecItemDelete(Self.query(account) as CFDictionary)
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data, account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceKeyError.keychain(status) }
    }
}
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : tout passe (iOS : 40 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add ios/Nacelle/Pairing/DeviceKey.swift \
    ios/NacelleTests/DeviceKeyTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
App : clé de l'appareil (Secure Enclave)

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit.

### Tâche 8 : iOS : Bonjour, course des chemins, authentification et vidéo relayée

**But :** `PTZClient` essaie à chaque connexion le nom Tailscale et le service Bonjour du réseau local ; la première connexion authentifiée l'emporte ; il répond au défi, envoie le code d'appairage, et relaie l'offre vidéo par `ptzd` (spec accès local § 8.3 et § 8.4). Pendant la transition (§ 11, étapes 1 à 3), un `webrtcError` fait retenter l'ancien `POST` direct vers go2rtc.

**Fichiers :**
- Modifier : `ios/Nacelle/App/AppModel.swift`
- Créer : `ios/Nacelle/PTZ/LocalNetwork.swift`
- Modifier : `ios/Nacelle/PTZ/PTZClient.swift`
- Modifier : `ios/Nacelle/PTZ/WebSocketTransport.swift`
- Modifier : `ios/Nacelle/Video/VideoSession.swift`
- Modifier : `ios/NacelleTests/AppModelTests.swift`
- Modifier : `ios/NacelleTests/FakeTransport.swift`
- Modifier : `ios/NacelleTests/PTZClientTests.swift`
- Modifier : `ios/project.yml`

**Interfaces :**
- Consomme : messages de la tâche 1, `DeviceKey` et `DeviceKeyStoring` (tâche 7).
- Produit :
  - `WebSocketEndpoint` (`.url(URL)`, `.service(NWEndpoint)`), protocole `ServiceBrowser`, `BonjourServiceBrowser`, `NWWebSocketTransport` ; `WebSocketTransport.open(_ endpoint: WebSocketEndpoint)` ;
  - `PTZClient(makeTransport:browser:keys:pairingRecord:scheduler:deviceName:)` ; `PTZClient.AuthIssue` (`.unpaired`, `.rejected`, `.badCode`), `authIssue`, `isPaired`, `pair(code:)`, `forgetPairing()`, `negotiate(offer:) async throws -> String`, `PTZClient.NegotiationError`, `PTZClient.discoveryWindow` (3 s), `PTZClient.negotiationTimeout` (10 s) ; `PairingRecord` ;
  - `VideoSession.start(signal:)`, où `signal` envoie l'offre et rend la réponse.
- Info.plist : `NSBonjourServices` = `_nacelle._tcp`.
- Faits vérifiés dans le simulateur : `NWConnection` avec WebSocket joint directement un `NWEndpoint.service` ; une `NWConnection` vers un hôte introuvable reste `.waiting` sans jamais passer `.failed`, d'où la fermeture sur `.waiting` et la fenêtre de découverte bornée.

- [ ] **Étape 1 : Écrire les tests**

Modifier `ios/NacelleTests/AppModelTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/NacelleTests/AppModelTests.swift b/ios/NacelleTests/AppModelTests.swift
index ec9a59e..acae631 100644
--- a/ios/NacelleTests/AppModelTests.swift
+++ b/ios/NacelleTests/AppModelTests.swift
@@ -1,3 +1,4 @@
+import CryptoKit
 import Foundation
 import NacelleProtocol
 import Testing
@@ -6,27 +7,41 @@ import Testing
 @MainActor
 @Suite("Modèle de l'app")
 struct AppModelTests {
-    let transport = FakeTransport()
+    let transports = FakeTransports()
     let scheduler = FakeScheduler()
     let defaults = UserDefaults(suiteName: "nacelle-appmodel-\(UUID().uuidString)")!
     let complete = ConnectionSettings(host: "mac.exemple.ts.net")
 
     private func makeModel() -> AppModel {
-        AppModel(
+        let transports = transports
+        let keys = FakeKeyStore()
+        keys.key = SoftwareDeviceKey(key: P256.Signing.PrivateKey())
+        return AppModel(
             store: SettingsStore(defaults: defaults),
-            ptz: PTZClient(transport: transport, scheduler: scheduler),
+            ptz: PTZClient(
+                makeTransport: { _ in transports.make() },
+                browser: FakeBrowser(),
+                keys: keys,
+                pairingRecord: PairingRecord(defaults: defaults),
+                scheduler: scheduler
+            ),
             video: VideoSession(scheduler: scheduler)
         )
     }
 
+    /// Ports des connexions ouvertes vers le nom Tailscale.
+    private var openedPorts: [Int?] {
+        transports.all.flatMap(\.opened).compactMap { if case let .url(url) = $0 { url.port } else { nil } }
+    }
+
     @Test("Premier lancement : les réglages enregistrés au premier plan connectent tout de suite")
     func firstLaunch() {
         let model = makeModel()
         model.activate()
-        #expect(transport.openedURLs.isEmpty)
+        #expect(openedPorts.isEmpty)
         #expect(model.bannerText == nil)
         model.settings = complete
-        #expect(transport.openedURLs.count == 1)
+        #expect(openedPorts.count == 1)
         #expect(model.isActive)
         model.deactivate()
     }
@@ -37,7 +52,7 @@ struct AppModelTests {
         let model = makeModel()
         model.activate()
         model.activate()
-        #expect(transport.openedURLs.count == 1)
+        #expect(openedPorts.count == 1)
         model.deactivate()
     }
 
@@ -47,7 +62,7 @@ struct AppModelTests {
         model.activate()
         model.deactivate()
         model.settings = complete
-        #expect(transport.openedURLs.isEmpty)
+        #expect(openedPorts.isEmpty)
         #expect(SettingsStore(defaults: defaults).load() == complete)
     }
 
@@ -57,16 +72,19 @@ struct AppModelTests {
         let model = makeModel()
         model.activate()
         model.settings = ConnectionSettings(host: "mac.exemple.ts.net", ptzdPort: 1999)
-        #expect(transport.openedURLs.map(\.port) == [1985, 1999])
+        #expect(openedPorts == [1985, 1999])
         model.deactivate()
     }
 
     @Test("Inactif (Centre de contrôle, appel) : la nacelle s'arrête, la connexion reste ouverte")
-    func pauseStopsMovement() {
+    func pauseStopsMovement() throws {
         SettingsStore(defaults: defaults).save(complete)
         let model = makeModel()
         model.activate()
+        let transport = try #require(transports.last)
         transport.emit(.opened)
+        transport.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
+        transport.emit(.message(try NacelleCodec.encode(ServerMessage.authenticated)))
         model.ptz.setJoystick(JoystickVector(pan: 1, tilt: 0))
         model.pause()
         let sentAtPause = transport.sent.count
PATCH
```

Remplacer tout le contenu de `ios/NacelleTests/FakeTransport.swift` par :

```swift
import CryptoKit
import Foundation
import Network
@testable import Nacelle

/// Transport WebSocket simulé : enregistre les ouvertures et les envois ; le test déclenche les événements.
@MainActor
final class FakeTransport: WebSocketTransport {
    var onEvent: ((TransportEvent) -> Void)?
    private(set) var opened: [WebSocketEndpoint] = []
    private(set) var sent: [String] = []
    private(set) var closeCount = 0

    func open(_ endpoint: WebSocketEndpoint) {
        opened.append(endpoint)
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

/// Fabrique de transports simulés : un par connexion ouverte, dans l'ordre.
@MainActor
final class FakeTransports {
    private(set) var all: [FakeTransport] = []

    func make() -> any WebSocketTransport {
        let transport = FakeTransport()
        all.append(transport)
        return transport
    }

    var last: FakeTransport? {
        all.last
    }

    /// Le transport ouvert vers cette destination le plus récemment.
    func to(_ endpoint: WebSocketEndpoint) -> FakeTransport? {
        all.last { $0.opened == [endpoint] }
    }
}

/// Bonjour simulé.
@MainActor
final class FakeBrowser: ServiceBrowser {
    var onFound: ((NWEndpoint) -> Void)?
    private(set) var isRunning = false
    private(set) var startCount = 0

    func start() {
        isRunning = true
        startCount += 1
    }

    func stop() {
        isRunning = false
    }

    func find(_ endpoint: NWEndpoint) {
        onFound?(endpoint)
    }
}

/// Clé logicielle en mémoire.
@MainActor
final class FakeKeyStore: DeviceKeyStoring {
    var key: (any DeviceKey)?
    private(set) var createCount = 0

    func load() -> (any DeviceKey)? {
        key
    }

    func loadOrCreate() throws -> any DeviceKey {
        if let key {
            return key
        }
        createCount += 1
        let created = SoftwareDeviceKey(key: P256.Signing.PrivateKey())
        key = created
        return created
    }

    func delete() {
        key = nil
    }
}
```

Remplacer tout le contenu de `ios/NacelleTests/PTZClientTests.swift` par :

```swift
import CryptoKit
import Foundation
import NacelleProtocol
import Network
import Testing
@testable import Nacelle

@MainActor
@Suite("Client ptzd")
struct PTZClientTests {
    let transports = FakeTransports()
    let browser = FakeBrowser()
    let keys = FakeKeyStore()
    let scheduler = FakeScheduler()
    let record = PairingRecord(defaults: UserDefaults(suiteName: "ptzclient-\(UUID().uuidString)")!)
    let client: PTZClient
    let url = URL(string: "ws://mac.exemple.ts.net:1985")!
    let service = NWEndpoint.service(name: "Nacelle", type: "_nacelle._tcp", domain: "local.", interface: nil)
    let nonce = Data(repeating: 7, count: 32)

    init() {
        let transports = transports
        client = PTZClient(
            makeTransport: { _ in transports.make() },
            browser: browser,
            keys: keys,
            pairingRecord: record,
            scheduler: scheduler
        )
        keys.key = SoftwareDeviceKey(key: P256.Signing.PrivateKey())
    }

    private var tailscale: FakeTransport {
        transports.to(.url(url))!
    }

    private func decoded(_ transport: FakeTransport) -> [ClientMessage] {
        transport.sent.compactMap { try? NacelleCodec.decodeClient($0) }
    }

    private func emit(_ message: ServerMessage, on transport: FakeTransport) throws {
        transport.emit(.message(try NacelleCodec.encode(message)))
    }

    /// Ouverture, défi, signature, authentification, par Tailscale.
    private func connect() throws {
        client.start(url: url)
        tailscale.emit(.opened)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
    }

    /// Messages envoyés après l'authentification.
    private func commands(_ transport: FakeTransport) -> [ClientMessage] {
        decoded(transport).filter { if case .auth = $0 { false } else { true } }
    }

    // MARK: - Authentification

    @Test("Défi : réponse signée, vérifiable par ptzd")
    func answersChallenge() throws {
        client.start(url: url)
        tailscale.emit(.opened)
        #expect(client.link == .connecting)
        try emit(.challenge(nonce: nonce), on: tailscale)
        guard case let .auth(deviceID, signature) = decoded(tailscale).first else {
            Issue.record("auth attendu")
            return
        }
        let key = try #require(keys.key)
        #expect(deviceID == key.deviceID)
        #expect(NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: key.publicKeyX963))
    }

    @Test("Authentifié : connecté, prise en main envoyée, appairage retenu")
    func takeControlAfterAuth() throws {
        try connect()
        #expect(client.link == .connected)
        #expect(commands(tailscale) == [.takeControl])
        #expect(client.isPaired)
        #expect(record.isPaired)
    }

    @Test("Sans clé : « non appairé », plus de reconnexion")
    func noKey() throws {
        keys.key = nil
        client.start(url: url)
        try emit(.challenge(nonce: nonce), on: tailscale)
        #expect(client.authIssue == .unpaired)
        #expect(client.link == .idle)
        scheduler.advance(by: 30)
        #expect(transports.all.count == 1)
    }

    @Test("ptzd ne connaît pas l'iPhone : « non appairé », appairage oublié")
    func unpairedByServer() throws {
        record.isPaired = true
        try connect()
        client.stop()
        client.start(url: url)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .unpaired, message: "x"), on: tailscale)
        #expect(client.authIssue == .unpaired)
        #expect(!client.isPaired)
        #expect(!record.isPaired)
        #expect(client.link == .idle)
    }

    @Test("Signature refusée : « refusé », plus de reconnexion")
    func rejected() throws {
        client.start(url: url)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .authFailed, message: "x"), on: tailscale)
        #expect(client.authIssue == .rejected)
        tailscale.emit(.closed)
        scheduler.advance(by: 30)
        #expect(transports.all.count == 1)
    }

    // MARK: - Appairage

    @Test("Appairage : clé créée, code et clé envoyés, puis auth sur le même défi")
    func pairing() throws {
        keys.key = nil
        client.start(url: url)
        client.pair(code: " 042917 ")
        try emit(.challenge(nonce: nonce), on: tailscale)
        let key = try #require(keys.key)
        #expect(decoded(tailscale) == [.pair(code: "042917", publicKey: key.publicKeyX963, name: "iPhone")])
        try emit(.paired(deviceID: key.deviceID), on: tailscale)
        #expect(client.isPaired)
        guard case .auth = decoded(tailscale).last else {
            Issue.record("auth attendu après paired")
            return
        }
        try emit(.authenticated, on: tailscale)
        #expect(client.link == .connected)
        #expect(client.authIssue == nil)
    }

    @Test("Code refusé : « code refusé », plus de reconnexion, le code n'est pas réessayé")
    func badCode() throws {
        client.start(url: url)
        client.pair(code: "000000")
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .badCode, message: "x"), on: tailscale)
        #expect(client.authIssue == .badCode)
        #expect(tailscale.closeCount >= 1)
        let opened = transports.all.count
        scheduler.advance(by: 30)
        #expect(transports.all.count == opened)
    }

    @Test("Pas d'appairage en cours sur le Mac : « code refusé » aussi")
    func pairingClosed() throws {
        client.start(url: url)
        client.pair(code: "123456")
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .pairingClosed, message: "x"), on: tailscale)
        #expect(client.authIssue == .badCode)
    }

    @Test("Oublier l'appairage : clé supprimée, puis « non appairé »")
    func forget() throws {
        try connect()
        client.forgetPairing()
        #expect(keys.key == nil)
        #expect(!client.isPaired)
        try emit(.challenge(nonce: nonce), on: try #require(transports.last))
        #expect(client.authIssue == .unpaired)
    }

    // MARK: - Choix du chemin

    @Test("Les deux chemins essayés ; le premier authentifié l'emporte, l'autre est fermé")
    func race() throws {
        client.start(url: url)
        #expect(browser.isRunning)
        browser.find(service)
        let local = try #require(transports.to(.service(service)))
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: local)
        #expect(client.link == .connected)
        #expect(commands(local) == [.takeControl])
        #expect(tailscale.closeCount >= 1)
        #expect(!browser.isRunning)
        // Une authentification tardive du perdant est ignorée.
        try emit(.authenticated, on: tailscale)
        #expect(commands(tailscale).isEmpty)
    }

    @Test("Bonjour ne trouve rien : Tailscale seul, sans message")
    func noLocalService() throws {
        client.start(url: url)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(!browser.isRunning)
        tailscale.emit(.opened)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        #expect(client.link == .connected)
        #expect(!client.isUnreachable)
    }

    @Test("Tailscale coupé à la maison : pas d'échec tant que Bonjour cherche")
    func tailscaleDownAtHome() throws {
        client.start(url: url)
        tailscale.emit(.closed)
        #expect(client.link == .connecting)
        #expect(!client.isUnreachable)
        browser.find(service)
        let local = try #require(transports.to(.service(service)))
        local.emit(.opened)
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.authenticated, on: local)
        #expect(client.link == .connected)
    }

    @Test("Un seul service local par tentative")
    func oneLocalCandidate() {
        client.start(url: url)
        browser.find(service)
        browser.find(.service(name: "Nacelle", type: "_nacelle._tcp", domain: "local.", interface: nil))
        #expect(transports.all.count == 2)
    }

    @Test("Appairage avec deux chemins : un seul envoie le code, l'autre s'authentifie après paired")
    func pairingWithTwoPaths() throws {
        keys.key = nil
        client.start(url: url)
        client.pair(code: "042917")
        browser.find(service)
        let local = try #require(transports.to(.service(service)))
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.challenge(nonce: nonce), on: local)
        let pairs = (decoded(tailscale) + decoded(local)).filter { if case .pair = $0 { true } else { false } }
        #expect(pairs.count == 1)
        try emit(.paired(deviceID: try #require(keys.key).deviceID), on: tailscale)
        #expect(decoded(local).contains { if case .auth = $0 { true } else { false } })
        #expect(decoded(tailscale).contains { if case .auth = $0 { true } else { false } })
    }

    // MARK: - Reconnexion

    @Test("Échec des deux chemins : Mac injoignable, nouvel essai après 1, 2, 4 puis 8 s")
    func retryBackoff() {
        client.start(url: url)
        tailscale.emit(.closed)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.isUnreachable)
        #expect(client.link == .waitingToRetry)
        for delay in [1.0, 2, 4, 8, 8] {
            let before = transports.all.count
            scheduler.advance(by: delay - 0.01)
            #expect(transports.all.count == before)
            scheduler.advance(by: 0.01)
            #expect(transports.all.count == before + 1)
            transports.last?.emit(.closed)
            scheduler.advance(by: PTZClient.discoveryWindow)
        }
    }

    @Test("Une connexion réussie efface « injoignable » et remet l'espacement à 1 s")
    func recovery() throws {
        client.start(url: url)
        tailscale.emit(.closed)
        scheduler.advance(by: PTZClient.discoveryWindow + 1)
        let second = try #require(transports.last)
        second.emit(.opened)
        try emit(.challenge(nonce: nonce), on: second)
        try emit(.authenticated, on: second)
        #expect(!client.isUnreachable)
        second.emit(.closed)
        #expect(!client.isUnreachable)
        #expect(client.link == .waitingToRetry)
        let before = transports.all.count
        scheduler.advance(by: 1)
        #expect(transports.all.count == before + 1)
    }

    @Test("Arrêt ou nouveau départ : « injoignable » est effacé jusqu'au prochain échec")
    func unreachableResetOnStopAndStart() {
        client.start(url: url)
        tailscale.emit(.closed)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.isUnreachable)
        client.stop()
        #expect(!client.isUnreachable)
        client.start(url: url)
        #expect(!client.isUnreachable)
        #expect(client.link == .connecting)
    }

    @Test("Coupure : le mouvement s'arrête et l'état est oublié")
    func closeStopsRepeating() throws {
        try connect()
        try emit(.state(StateSnapshot(camera: .connected, control: .ready, privacy: false, pan: 0, tilt: 0, zoom: 0, moving: true)), on: tailscale)
        client.setJoystick(JoystickVector(pan: 1, tilt: 0))
        tailscale.emit(.closed)
        let sentAtClose = tailscale.sent.count
        scheduler.advance(by: 0.5)
        #expect(tailscale.sent.count == sentAtClose)
        #expect(client.state == nil)
    }

    @Test("Arrière-plan : move 0,0 si on pilotait, fermeture, aucune reconnexion")
    func stop() throws {
        try connect()
        client.setJoystick(JoystickVector(pan: 1, tilt: 0))
        client.stop()
        #expect(commands(tailscale).last == .move(pan: 0, tilt: 0))
        #expect(tailscale.closeCount >= 1)
        #expect(client.link == .idle)
        #expect(!browser.isRunning)
        scheduler.advance(by: 30)
        #expect(transports.all.count == 1)
    }

    // MARK: - Commandes

    @Test("Joystick hors du centre : move tout de suite, puis 10 fois par seconde")
    func repeatsMove() throws {
        try connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        scheduler.advance(by: 0.35)
        #expect(commands(tailscale) == [.takeControl] + Array(repeating: .move(pan: 0.5, tilt: 0), count: 4))
    }

    @Test("Relâchement : move 0,0 une fois, puis plus rien")
    func releaseSendsStopOnce() throws {
        try connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        client.setJoystick(.zero)
        client.setJoystick(.zero)
        scheduler.advance(by: 1)
        #expect(commands(tailscale) == [.takeControl, .move(pan: 0.5, tilt: 0), .move(pan: 0, tilt: 0)])
    }

    @Test("Un changement de consigne est envoyé sans attendre le prochain tic")
    func newVectorImmediately() throws {
        try connect()
        client.setJoystick(JoystickVector(pan: 0.5, tilt: 0))
        client.setJoystick(JoystickVector(pan: 0, tilt: -1))
        #expect(commands(tailscale).last == .move(pan: 0, tilt: -1))
    }

    @Test("L'état reçu est publié ; une erreur est retenue")
    func receivesState() throws {
        try connect()
        let snapshot = StateSnapshot(camera: .connected, control: .ready, privacy: false, pan: 2, tilt: -1, zoom: 33, moving: false)
        try emit(.state(snapshot), on: tailscale)
        try emit(.error(code: .privacyActive, message: "x"), on: tailscale)
        tailscale.emit(.message("pas du json"))
        #expect(client.state == snapshot)
        #expect(client.lastError == .privacyActive)
    }

    @Test("Avant l'authentification, rien n'est envoyé")
    func noSendBeforeAuth() {
        client.start(url: url)
        tailscale.emit(.opened)
        client.setZoom(40)
        client.setPrivacy(true)
        #expect(tailscale.sent.isEmpty)
    }

    // MARK: - Vidéo relayée

    /// Laisse les tâches lancées sur le MainActor avancer jusqu'à leur prochaine attente.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    @Test("Négociation : offre envoyée avec un identifiant, réponse rendue")
    func negotiation() async throws {
        try connect()
        let pending = Task { try await client.negotiate(offer: "v=0 offre") }
        await settle()
        #expect(commands(tailscale).last == .webrtcOffer(id: 1, sdp: "v=0 offre"))
        try emit(.webrtcAnswer(id: 1, sdp: "v=0 réponse"), on: tailscale)
        #expect(try await pending.value == "v=0 réponse")
    }

    @Test("Négociation avant la connexion : l'offre part dès l'authentification")
    func negotiationWaitsForLink() async throws {
        client.start(url: url)
        let pending = Task { try await client.negotiate(offer: "v=0 offre") }
        await settle()
        #expect(tailscale.sent.isEmpty)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        await settle()
        #expect(commands(tailscale).last == .webrtcOffer(id: 1, sdp: "v=0 offre"))
        try emit(.webrtcAnswer(id: 1, sdp: "v=0 réponse"), on: tailscale)
        #expect(try await pending.value == "v=0 réponse")
    }

    @Test("webrtcError : erreur de relais ; connexion perdue : connectionLost")
    func negotiationFailures() async throws {
        try connect()
        let first = Task { try await client.negotiate(offer: "a") }
        await settle()
        try emit(.webrtcError(id: 1, message: "go2rtc ne répond pas."), on: tailscale)
        await #expect(throws: PTZClient.NegotiationError.relay("go2rtc ne répond pas.")) { try await first.value }

        let second = Task { try await client.negotiate(offer: "b") }
        await settle()
        tailscale.emit(.closed)
        await #expect(throws: PTZClient.NegotiationError.connectionLost) { try await second.value }
    }

    @Test("Sans connexion ni réponse : échec après 10 s")
    func negotiationTimeouts() async throws {
        client.start(url: url)
        let waiting = Task { try await client.negotiate(offer: "a") }
        await settle()
        scheduler.advance(by: PTZClient.negotiationTimeout)
        await #expect(throws: PTZClient.NegotiationError.notConnected) { try await waiting.value }

        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        let silent = Task { try await client.negotiate(offer: "b") }
        await settle()
        scheduler.advance(by: PTZClient.negotiationTimeout)
        await #expect(throws: PTZClient.NegotiationError.timeout) { try await silent.value }
    }

    @Test("Zoom et vie privée")
    func zoomAndPrivacy() throws {
        try connect()
        client.setZoom(40)
        client.setPrivacy(true)
        #expect(commands(tailscale) == [.takeControl, .zoom(value: 40), .privacy(on: true)])
    }
}
```

Modifier `ios/project.yml` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/project.yml b/ios/project.yml
index 0a10790..947053d 100644
--- a/ios/project.yml
+++ b/ios/project.yml
@@ -37,7 +37,9 @@ targets:
           - UIInterfaceOrientationPortrait
           - UIInterfaceOrientationLandscapeLeft
           - UIInterfaceOrientationLandscapeRight
-        NSLocalNetworkUsageDescription: "À la maison, la vidéo de la caméra peut passer directement par le réseau local."
+        NSLocalNetworkUsageDescription: "À la maison, l'app trouve le Mac et la caméra sur le Wi-Fi, sans Tailscale."
+        NSBonjourServices:
+          - _nacelle._tcp
         NSAppTransportSecurity:
           NSExceptionDomains:
             ts.net:
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : échec — la compilation des tests échoue : `WebSocketEndpoint`, `ServiceBrowser` et le nouvel initialiseur de `PTZClient` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Modifier `ios/Nacelle/App/AppModel.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/App/AppModel.swift b/ios/Nacelle/App/AppModel.swift
index 826ec3b..42c92bb 100644
--- a/ios/Nacelle/App/AppModel.swift
+++ b/ios/Nacelle/App/AppModel.swift
@@ -36,7 +36,20 @@ final class AppModel {
         let scheduler = MainScheduler()
         return AppModel(
             store: SettingsStore(),
-            ptz: PTZClient(transport: URLSessionWebSocketTransport(scheduler: scheduler), scheduler: scheduler),
+            ptz: PTZClient(
+                makeTransport: { endpoint in
+                    switch endpoint {
+                    case .url:
+                        URLSessionWebSocketTransport(scheduler: scheduler)
+                    case .service:
+                        NWWebSocketTransport(scheduler: scheduler)
+                    }
+                },
+                browser: BonjourServiceBrowser(),
+                keys: KeychainDeviceKeyStore(),
+                pairingRecord: PairingRecord(),
+                scheduler: scheduler
+            ),
             video: VideoSession(scheduler: scheduler)
         )
     }
@@ -45,10 +58,25 @@ final class AppModel {
     /// Sans effet si déjà actif : un retour .inactive → .active ne relance rien.
     func activate() {
         isForeground = true
-        guard !isActive, let ptzdURL = settings.ptzdURL, let webRTCURL = settings.webRTCURL else { return }
+        guard !isActive, let ptzdURL = settings.ptzdURL else { return }
         isActive = true
         ptz.start(url: ptzdURL)
-        video.start(url: webRTCURL)
+        video.start { [weak self] offer in
+            guard let self else { throw PTZClient.NegotiationError.connectionLost }
+            return try await self.signal(offer: offer)
+        }
+    }
+
+    /// Offre vidéo relayée par ptzd. Pendant la transition (spec accès local § 11, étapes 1 à 3),
+    /// si go2rtc ne répond pas à ptzd, l'ancien `POST` direct vers go2rtc est retenté.
+    private func signal(offer: String) async throws -> String {
+        do {
+            return try await ptz.negotiate(offer: offer)
+        } catch PTZClient.NegotiationError.relay {
+            guard let url = settings.webRTCURL else { throw PTZClient.NegotiationError.relay("") }
+            let (data, response) = try await URLSession.shared.data(for: Signaling.request(url: url, offerSDP: offer))
+            return try Signaling.answer(data: data, response: response)
+        }
     }
 
     /// Inactif (Centre de contrôle, appel, alerte, sélecteur d'apps) : arrêt de la nacelle, sans
PATCH
```

Créer `ios/Nacelle/PTZ/LocalNetwork.swift` :

```swift
import Foundation
import Network

/// Recherche Bonjour de ptzd sur le réseau local (spec accès local § 8.3).
@MainActor
final class BonjourServiceBrowser: ServiceBrowser {
    static let type = "_nacelle._tcp"

    var onFound: ((NWEndpoint) -> Void)?
    private var browser: NWBrowser?

    func start() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: Self.type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser, let first = results.first else { return }
                self.onFound?(first.endpoint)
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// WebSocket sur NWConnection, pour joindre un service Bonjour (URLSessionWebSocketTask ne prend
/// qu'une URL). Une seule connexion à la fois ; vivacité par `Heartbeat`, comme l'autre transport.
@MainActor
final class NWWebSocketTransport: WebSocketTransport {
    var onEvent: ((TransportEvent) -> Void)?
    private let scheduler: any Scheduler
    private var connection: NWConnection?
    private var heartbeat: Heartbeat?

    init(scheduler: any Scheduler) {
        self.scheduler = scheduler
    }

    func open(_ endpoint: WebSocketEndpoint) {
        close()
        let target: NWEndpoint
        switch endpoint {
        case let .url(url):
            target = .url(url)
        case let .service(service):
            target = service
        }
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let connection = NWConnection(to: target, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, connection === self.connection else { return }
                switch state {
                case .ready:
                    self.startHeartbeat(for: connection)
                    self.onEvent?(.opened)
                case .failed, .cancelled, .waiting:
                    // En attente = pas de chemin : la course passe par Tailscale ou réessaie plus tard.
                    self.finish(connection)
                default:
                    break
                }
            }
        }
        receive(on: connection)
        connection.start(queue: .main)
    }

    func send(_ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "nacelle", metadata: [metadata])
        connection?.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func close() {
        heartbeat?.stop()
        heartbeat = nil
        connection?.cancel()
        connection = nil
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self, connection === self.connection else { return }
                if error != nil || context?.isFinal == true {
                    self.finish(connection)
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close {
                    self.finish(connection)
                    return
                }
                if metadata?.opcode == .text, let content, let text = String(data: content, encoding: .utf8) {
                    self.onEvent?(.message(text))
                }
                self.receive(on: connection)
            }
        }
    }

    /// Signale la fin d'une connexion, une seule fois.
    private func finish(_ connection: NWConnection) {
        guard connection === self.connection else { return }
        heartbeat?.stop()
        heartbeat = nil
        self.connection = nil
        connection.cancel()
        onEvent?(.closed)
    }

    private func startHeartbeat(for connection: NWConnection) {
        let heartbeat = Heartbeat(
            scheduler: scheduler,
            ping: { reply in
                let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
                metadata.setPongHandler(.main) { error in
                    MainActor.assumeIsolated { reply(error == nil) }
                }
                let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
                connection.send(content: Data(), contentContext: context, isComplete: true, completion: .idempotent)
            },
            onLost: { [weak self] in
                self?.finish(connection)
            }
        )
        self.heartbeat = heartbeat
        heartbeat.start()
    }
}
```

Remplacer tout le contenu de `ios/Nacelle/PTZ/PTZClient.swift` par :

```swift
import Foundation
import NacelleProtocol
import Network
import Observation

/// Dialogue avec ptzd (spec § 7.2, spec accès local § 8) : à chaque connexion, le nom Tailscale
/// et le service Bonjour du réseau local sont essayés ensemble ; la première connexion
/// authentifiée l'emporte. Puis prise en main, `move` répété 10 fois par seconde tant que le
/// joystick est hors du centre, reconnexion espacée.
@MainActor
@Observable
final class PTZClient {
    enum Link: Equatable {
        case idle
        case connecting
        case connected
        case waitingToRetry
    }

    /// Ce qui empêche l'authentification ; aucune reconnexion tant que l'utilisateur n'agit pas.
    enum AuthIssue: Equatable {
        /// Pas de clé, ou ptzd ne connaît pas cet iPhone.
        case unpaired
        /// Signature refusée.
        case rejected
        /// Code d'appairage faux, expiré ou déjà utilisé.
        case badCode
    }

    /// Pourquoi une négociation vidéo n'a pas abouti.
    enum NegotiationError: Error, Equatable {
        /// Pas de connexion authentifiée dans le délai.
        case notConnected
        /// Connexion perdue ou fermée pendant la négociation.
        case connectionLost
        /// Pas de réponse de ptzd dans le délai.
        case timeout
        /// go2rtc n'a pas répondu à ptzd (`webrtcError`).
        case relay(String)
    }

    static let repeatInterval: TimeInterval = 0.1
    /// Délai d'une négociation vidéo, attente de la connexion comprise.
    static let negotiationTimeout: TimeInterval = 10
    static let retryDelays: [TimeInterval] = [1, 2, 4, 8]
    /// Temps laissé à Bonjour pour trouver ptzd sur le réseau local, à chaque tentative.
    static let discoveryWindow: TimeInterval = 3

    private(set) var link: Link = .idle
    /// Dernier état reçu de ptzd ; nil hors connexion.
    private(set) var state: StateSnapshot?
    /// Dernière erreur renvoyée par ptzd.
    private(set) var lastError: ErrorCode?
    /// Vrai quand une tentative de connexion a échoué, jusqu'à la prochaine réussite.
    /// Remis à faux par `start(url:)` et `stop()` : le bandeau revient à « Connexion… ».
    private(set) var isUnreachable = false
    private(set) var authIssue: AuthIssue?
    /// Cet iPhone s'est déjà authentifié, ou vient d'être appairé (enregistré).
    private(set) var isPaired: Bool

    @ObservationIgnored private let makeTransport: (WebSocketEndpoint) -> any WebSocketTransport
    @ObservationIgnored private let browser: any ServiceBrowser
    @ObservationIgnored private let keys: any DeviceKeyStoring
    @ObservationIgnored private let pairingRecord: PairingRecord
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var openedThisAttempt = false
    @ObservationIgnored private var candidates: [Candidate] = []
    @ObservationIgnored private var active: Candidate?
    @ObservationIgnored private var nextCandidateID = 0
    @ObservationIgnored private var foundLocal = false
    @ObservationIgnored private var discovery: (any Cancellable)?
    @ObservationIgnored private var retry: (any Cancellable)?
    @ObservationIgnored private var repeater: (any Cancellable)?
    @ObservationIgnored private var currentMove = JoystickVector.zero
    /// Code saisi dans les réglages, envoyé au prochain défi.
    @ObservationIgnored private var pendingCode: String?
    @ObservationIgnored private var pairingCandidate: Candidate?
    @ObservationIgnored private var nextOfferID = 0
    /// Négociations vidéo en attente de `webrtcAnswer`, par identifiant d'offre.
    @ObservationIgnored private var negotiations: [Int: CheckedContinuation<String, any Error>] = [:]
    /// Négociations en attente d'une connexion authentifiée.
    @ObservationIgnored private var waitingForLink: [Int: CheckedContinuation<Void, any Error>] = [:]

    /// Une connexion en cours d'essai ou retenue.
    private final class Candidate {
        let id: Int
        let transport: any WebSocketTransport
        /// Défi reçu, en attente de réponse.
        var nonce: Data?

        init(id: Int, transport: any WebSocketTransport) {
            self.id = id
            self.transport = transport
        }
    }

    init(
        makeTransport: @escaping (WebSocketEndpoint) -> any WebSocketTransport,
        browser: any ServiceBrowser,
        keys: any DeviceKeyStoring,
        pairingRecord: PairingRecord,
        scheduler: any Scheduler,
        deviceName: String = "iPhone"
    ) {
        self.makeTransport = makeTransport
        self.browser = browser
        self.keys = keys
        self.pairingRecord = pairingRecord
        self.scheduler = scheduler
        self.deviceName = deviceName
        isPaired = pairingRecord.isPaired
        browser.onFound = { [weak self] endpoint in
            self?.found(endpoint)
        }
    }

    func start(url: URL) {
        self.url = url
        attempt = 0
        isUnreachable = false
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
        closeAll()
        link = .idle
        state = nil
        isUnreachable = false
        failNegotiations(.connectionLost)
    }

    /// Négociation vidéo relayée par ptzd (spec accès local § 8.4) : attend la connexion
    /// authentifiée si besoin, puis envoie l'offre ; 10 s au plus en tout.
    func negotiate(offer: String) async throws -> String {
        nextOfferID += 1
        let id = nextOfferID
        let deadline = scheduler.schedule(after: Self.negotiationTimeout) { [weak self] in
            self?.expire(id)
        }
        defer { deadline.cancel() }
        if link != .connected {
            try await withCheckedThrowingContinuation { continuation in
                waitingForLink[id] = continuation
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            negotiations[id] = continuation
            send(.webrtcOffer(id: id, sdp: offer))
        }
    }

    private func expire(_ id: Int) {
        waitingForLink.removeValue(forKey: id)?.resume(throwing: NegotiationError.notConnected)
        negotiations.removeValue(forKey: id)?.resume(throwing: NegotiationError.timeout)
    }

    private func failNegotiations(_ error: NegotiationError) {
        let waiting = waitingForLink
        let pending = negotiations
        waitingForLink = [:]
        negotiations = [:]
        waiting.values.forEach { $0.resume(throwing: error) }
        pending.values.forEach { $0.resume(throwing: error) }
    }

    /// Appairage avec le code de `ptzd pair` : envoyé au prochain défi, connexion relancée.
    func pair(code: String) {
        pendingCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        authIssue = nil
        restart()
    }

    /// Oublie la clé et l'appairage ; ptzd refusera cet iPhone jusqu'au prochain appairage.
    func forgetPairing() {
        keys.delete()
        setPaired(false)
        pendingCode = nil
        restart()
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

    // MARK: - Connexions

    private func restart() {
        guard url != nil else { return }
        retry?.cancel()
        retry = nil
        attempt = 0
        connect()
    }

    /// Une tentative : le nom Tailscale tout de suite, le réseau local si Bonjour trouve ptzd.
    private func connect() {
        guard let url else { return }
        closeAll()
        link = .connecting
        openedThisAttempt = false
        foundLocal = false
        open(.url(url))
        browser.start()
        discovery = scheduler.schedule(after: Self.discoveryWindow) { [weak self] in
            self?.discoveryEnded()
        }
    }

    private func found(_ endpoint: NWEndpoint) {
        guard link == .connecting, active == nil, !foundLocal else { return }
        foundLocal = true
        open(.service(endpoint))
    }

    private func discoveryEnded() {
        discovery = nil
        browser.stop()
        if candidates.isEmpty, active == nil {
            attemptFailed()
        }
    }

    private func open(_ endpoint: WebSocketEndpoint) {
        nextCandidateID += 1
        let candidate = Candidate(id: nextCandidateID, transport: makeTransport(endpoint))
        candidates.append(candidate)
        candidate.transport.onEvent = { [weak self, weak candidate] event in
            guard let self, let candidate else { return }
            self.handle(event, from: candidate)
        }
        candidate.transport.open(endpoint)
    }

    private func closeAll() {
        discovery?.cancel()
        discovery = nil
        browser.stop()
        for candidate in candidates {
            candidate.transport.onEvent = nil
            candidate.transport.close()
        }
        candidates = []
        active = nil
        pairingCandidate = nil
    }

    private func close(_ candidate: Candidate) {
        candidate.transport.onEvent = nil
        candidate.transport.close()
        candidates.removeAll { $0 === candidate }
        if pairingCandidate === candidate {
            pairingCandidate = nil
        }
    }

    private func handle(_ event: TransportEvent, from candidate: Candidate) {
        switch event {
        case .opened:
            openedThisAttempt = true
        case let .message(text):
            guard let message = try? NacelleCodec.decodeServer(text) else { return }
            if candidate === active {
                handleActive(message)
            } else {
                handleHandshake(message, from: candidate)
            }
        case .closed:
            candidates.removeAll { $0 === candidate }
            if pairingCandidate === candidate {
                pairingCandidate = nil
            }
            if candidate === active {
                active = nil
                lost()
            } else if active == nil, candidates.isEmpty, discovery == nil, link == .connecting {
                attemptFailed()
            }
        }
    }

    private func handleHandshake(_ message: ServerMessage, from candidate: Candidate) {
        switch message {
        case let .challenge(nonce):
            answer(nonce, on: candidate)
        case .paired:
            pendingCode = nil
            pairingCandidate = nil
            setPaired(true)
            for waiting in candidates where waiting.nonce != nil {
                authenticate(waiting)
            }
        case .authenticated:
            becomeActive(candidate)
        case let .error(code, _):
            switch code {
            case .unpaired:
                setPaired(false)
                giveUp(.unpaired)
            case .authFailed:
                giveUp(.rejected)
            case .badCode, .pairingClosed:
                pendingCode = nil
                giveUp(.badCode)
            default:
                lastError = code
            }
        default:
            break
        }
    }

    private func answer(_ nonce: Data, on candidate: Candidate) {
        candidate.nonce = nonce
        if let code = pendingCode {
            // Un seul appairage à la fois : les autres connexions attendent `paired`.
            guard pairingCandidate == nil else { return }
            guard let key = try? keys.loadOrCreate() else {
                giveUp(.unpaired)
                return
            }
            pairingCandidate = candidate
            send(.pair(code: code, publicKey: key.publicKeyX963, name: deviceName), on: candidate)
        } else if keys.load() != nil {
            authenticate(candidate)
        } else {
            setPaired(false)
            giveUp(.unpaired)
        }
    }

    private func authenticate(_ candidate: Candidate) {
        guard let nonce = candidate.nonce, let key = keys.load(), let signature = try? key.signChallenge(nonce) else { return }
        candidate.nonce = nil
        send(.auth(deviceID: key.deviceID, signature: signature), on: candidate)
    }

    private func becomeActive(_ candidate: Candidate) {
        guard active == nil else {
            close(candidate)
            return
        }
        active = candidate
        for other in candidates where other !== candidate {
            close(other)
        }
        discovery?.cancel()
        discovery = nil
        browser.stop()
        link = .connected
        attempt = 0
        isUnreachable = false
        authIssue = nil
        setPaired(true)
        send(.takeControl)
        let waiting = waitingForLink
        waitingForLink = [:]
        waiting.values.forEach { $0.resume() }
    }

    private func handleActive(_ message: ServerMessage) {
        switch message {
        case let .state(snapshot):
            state = snapshot
        case let .error(code, _):
            lastError = code
        case let .webrtcAnswer(id, sdp):
            negotiations.removeValue(forKey: id)?.resume(returning: sdp)
        case let .webrtcError(id, message):
            negotiations.removeValue(forKey: id)?.resume(throwing: NegotiationError.relay(message))
        case .challenge, .authenticated, .paired:
            break
        }
    }

    /// Plus de reconnexion : l'utilisateur doit appairer l'iPhone (spec accès local § 8.5).
    private func giveUp(_ issue: AuthIssue) {
        authIssue = issue
        retry?.cancel()
        retry = nil
        closeAll()
        link = .idle
        failNegotiations(.notConnected)
    }

    private func lost() {
        stopRepeating()
        currentMove = .zero
        state = nil
        let pending = negotiations
        negotiations = [:]
        pending.values.forEach { $0.resume(throwing: NegotiationError.connectionLost) }
        scheduleRetry()
    }

    private func attemptFailed() {
        closeAll()
        if !openedThisAttempt {
            isUnreachable = true
        }
        state = nil
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard url != nil else {
            link = .idle
            return
        }
        closeAll()
        link = .waitingToRetry
        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
        attempt += 1
        retry = scheduler.schedule(after: delay) { [weak self] in
            self?.retry = nil
            self?.connect()
        }
    }

    private func setPaired(_ paired: Bool) {
        guard isPaired != paired else { return }
        isPaired = paired
        pairingRecord.isPaired = paired
    }

    // MARK: - Envoi

    private func send(_ message: ClientMessage) {
        guard link == .connected, let active else { return }
        send(message, on: active)
    }

    private func send(_ message: ClientMessage, on candidate: Candidate) {
        guard let text = try? NacelleCodec.encode(message) else { return }
        candidate.transport.send(text)
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

/// Mémoire de l'appairage, pour l'afficher dans les réglages.
final class PairingRecord {
    static let key = "paired"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isPaired: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
```

Modifier `ios/Nacelle/PTZ/WebSocketTransport.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/PTZ/WebSocketTransport.swift b/ios/Nacelle/PTZ/WebSocketTransport.swift
index 894d931..0651fb0 100644
--- a/ios/Nacelle/PTZ/WebSocketTransport.swift
+++ b/ios/Nacelle/PTZ/WebSocketTransport.swift
@@ -1,4 +1,21 @@
 import Foundation
+import Network
+
+/// Où ouvrir une connexion vers ptzd.
+enum WebSocketEndpoint: Equatable, Sendable {
+    /// Le nom Tailscale du Mac.
+    case url(URL)
+    /// Le service Bonjour `_nacelle._tcp` trouvé sur le réseau local.
+    case service(NWEndpoint)
+}
+
+/// Découverte de ptzd sur le réseau local (Bonjour). Les résultats arrivent sur le MainActor.
+@MainActor
+protocol ServiceBrowser: AnyObject {
+    var onFound: ((NWEndpoint) -> Void)? { get set }
+    func start()
+    func stop()
+}
 
 /// Ce qui arrive sur la connexion WebSocket.
 enum TransportEvent: Equatable, Sendable {
@@ -12,7 +29,7 @@ enum TransportEvent: Equatable, Sendable {
 @MainActor
 protocol WebSocketTransport: AnyObject {
     var onEvent: ((TransportEvent) -> Void)? { get set }
-    func open(_ url: URL)
+    func open(_ endpoint: WebSocketEndpoint)
     func send(_ text: String)
     func close()
 }
@@ -35,8 +52,13 @@ final class URLSessionWebSocketTransport: NSObject, WebSocketTransport {
         self.scheduler = scheduler
     }
 
-    func open(_ url: URL) {
+    /// Le nom Tailscale ; un service Bonjour passe par `NWWebSocketTransport`.
+    func open(_ endpoint: WebSocketEndpoint) {
         close()
+        guard case let .url(url) = endpoint else {
+            onEvent?(.closed)
+            return
+        }
         let configuration = URLSessionConfiguration.ephemeral
         configuration.timeoutIntervalForRequest = Self.openTimeout
         let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
PATCH
```

Modifier `ios/Nacelle/Video/VideoSession.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/Video/VideoSession.swift b/ios/Nacelle/Video/VideoSession.swift
index db26b30..3755120 100644
--- a/ios/Nacelle/Video/VideoSession.swift
+++ b/ios/Nacelle/Video/VideoSession.swift
@@ -2,10 +2,14 @@ import Foundation
 import Observation
 @preconcurrency import WebRTC
 
-/// Vidéo en direct de go2rtc, en WebRTC, réception seule (spec § 7.2).
+/// Vidéo en direct de go2rtc, en WebRTC, réception seule (spec § 7.2). L'offre est négociée
+/// par `signal`, qui la relaie à go2rtc (spec accès local § 8.4).
 @MainActor
 @Observable
 final class VideoSession {
+    /// Envoie l'offre SDP, renvoie la réponse SDP.
+    typealias Signal = @MainActor (_ offer: String) async throws -> String
+
     enum Phase: Equatable {
         case idle
         case connecting
@@ -19,7 +23,7 @@ final class VideoSession {
     private(set) var phase: Phase = .idle
 
     @ObservationIgnored private let scheduler: any Scheduler
-    @ObservationIgnored private var url: URL?
+    @ObservationIgnored private var signal: Signal?
     @ObservationIgnored private var attempt = 0
     @ObservationIgnored private var generation = 0
     @ObservationIgnored private var peer: RTCPeerConnection?
@@ -47,15 +51,15 @@ final class VideoSession {
         track?.add(renderer)
     }
 
-    func start(url: URL) {
-        self.url = url
+    func start(signal: @escaping Signal) {
+        self.signal = signal
         attempt = 0
         connect()
     }
 
     /// Passage en arrière-plan : fermeture de la connexion vidéo.
     func stop() {
-        url = nil
+        signal = nil
         retry?.cancel()
         retry = nil
         teardown()
@@ -63,7 +67,7 @@ final class VideoSession {
     }
 
     private func connect() {
-        guard let url else { return }
+        guard let signal else { return }
         retry?.cancel()
         retry = nil
         teardown()
@@ -71,11 +75,11 @@ final class VideoSession {
         let current = generation
         phase = .connecting
         Task {
-            await negotiate(url: url, generation: current)
+            await negotiate(signal: signal, generation: current)
         }
     }
 
-    private func negotiate(url: URL, generation current: Int) async {
+    private func negotiate(signal: Signal, generation current: Int) async {
         do {
             let peer = try makePeer(generation: current)
             let offer = try await peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
@@ -84,8 +88,7 @@ final class VideoSession {
             guard current == generation else { return }
             // Sans offre locale, échec : nouvel essai, au lieu de rester à `connecting`.
             guard let sdp = peer.localDescription?.sdp else { throw MissingLocalDescription() }
-            let (data, response) = try await URLSession.shared.data(for: Signaling.request(url: url, offerSDP: sdp))
-            let answer = try Signaling.answer(data: data, response: response)
+            let answer = try await signal(sdp)
             guard current == generation else { return }
             try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer))
         } catch {
@@ -163,7 +166,7 @@ final class VideoSession {
     private func lost() {
         teardown()
         phase = .lost
-        guard url != nil else { return }
+        guard signal != nil else { return }
         let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
         attempt += 1
         retry = scheduler.schedule(after: delay) { [weak self] in
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : tout passe (iOS : 57 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add ios/Nacelle/App/AppModel.swift \
    ios/Nacelle/PTZ/LocalNetwork.swift \
    ios/Nacelle/PTZ/PTZClient.swift \
    ios/Nacelle/PTZ/WebSocketTransport.swift \
    ios/Nacelle/Video/VideoSession.swift \
    ios/NacelleTests/AppModelTests.swift \
    ios/NacelleTests/FakeTransport.swift \
    ios/NacelleTests/PTZClientTests.swift \
    ios/project.yml
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
App : Bonjour, course des chemins, authentification et vidéo relayée

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit.

### Tâche 9 : iOS : réglages d'appairage et bandeau

**But :** Les réglages perdent le port go2rtc et le flux, et gagnent la section « Appairage » ; le bandeau affiche les problèmes d'appairage juste après « Mac injoignable » (spec accès local § 8.1 et § 8.5).

**Fichiers :**
- Modifier : `ios/Nacelle/App/AppModel.swift`
- Modifier : `ios/Nacelle/Control/ControlScreen.swift`
- Modifier : `ios/Nacelle/Control/StatusBanner.swift`
- Modifier : `ios/Nacelle/Settings/SettingsView.swift`
- Modifier : `ios/NacelleTests/ConnectionSettingsTests.swift`
- Modifier : `ios/NacelleTests/StatusBannerTests.swift`

**Interfaces :**
- Consomme : `PTZClient.authIssue`, `isPaired`, `pair(code:)`, `forgetPairing()` (tâche 8).
- Produit : `SettingsView(settings:isPaired:onPair:onForget:)`, `PairingCodeInput.isValid(_:)`, `BannerInputs.authIssue`, `AppModel.pair(code:)`, `AppModel.forgetPairing()`.

- [ ] **Étape 1 : Écrire les tests**

Modifier `ios/NacelleTests/ConnectionSettingsTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/NacelleTests/ConnectionSettingsTests.swift b/ios/NacelleTests/ConnectionSettingsTests.swift
index d48e901..a0c4b00 100644
--- a/ios/NacelleTests/ConnectionSettingsTests.swift
+++ b/ios/NacelleTests/ConnectionSettingsTests.swift
@@ -58,3 +58,16 @@ struct ConnectionSettingsTests {
         #expect(store.load() == settings)
     }
 }
+
+@Suite("Code d'appairage saisi")
+struct PairingCodeInputTests {
+    @Test("Six chiffres, espaces aux bords ignorés", arguments: ["042917", " 042917 "])
+    func valid(_ text: String) {
+        #expect(PairingCodeInput.isValid(text))
+    }
+
+    @Test("Trop court, trop long, lettres ou chiffres non latins : refusé", arguments: ["04291", "0429171", "04291a", "٠٤٢٩١٧", ""])
+    func invalid(_ text: String) {
+        #expect(!PairingCodeInput.isValid(text))
+    }
+}
PATCH
```

Modifier `ios/NacelleTests/StatusBannerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/NacelleTests/StatusBannerTests.swift b/ios/NacelleTests/StatusBannerTests.swift
index 6d5c09d..ea0a887 100644
--- a/ios/NacelleTests/StatusBannerTests.swift
+++ b/ios/NacelleTests/StatusBannerTests.swift
@@ -16,6 +16,17 @@ struct StatusBannerTests {
         StatusBanner.text(for: BannerInputs(macUnreachable: unreachable, connecting: connecting, state: state))
     }
 
+    @Test("Appairage : texte selon le problème, juste après « Mac injoignable »")
+    func pairingTexts() {
+        func text(_ issue: PTZClient.AuthIssue, unreachable: Bool = false) -> String? {
+            StatusBanner.text(for: BannerInputs(macUnreachable: unreachable, authIssue: issue, connecting: true, state: state(camera: .absent)))
+        }
+        #expect(text(.unpaired) == "iPhone non appairé : lance ptzd pair sur le Mac")
+        #expect(text(.badCode) == "Code d'appairage refusé")
+        #expect(text(.rejected) == "Accès refusé par le Mac")
+        #expect(text(.unpaired, unreachable: true) == "Mac injoignable : Tailscale est-il actif ?")
+    }
+
     @Test("Chaque condition a son texte")
     func texts() {
         #expect(text(unreachable: true) == "Mac injoignable : Tailscale est-il actif ?")
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : échec — la compilation des tests échoue : `PairingCodeInput` et `BannerInputs.authIssue` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Modifier `ios/Nacelle/App/AppModel.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/App/AppModel.swift b/ios/Nacelle/App/AppModel.swift
index 42c92bb..a1569ce 100644
--- a/ios/Nacelle/App/AppModel.swift
+++ b/ios/Nacelle/App/AppModel.swift
@@ -85,6 +85,16 @@ final class AppModel {
         ptz.setJoystick(.zero)
     }
 
+    /// Appairage avec le code affiché par `ptzd pair` sur le Mac.
+    func pair(code: String) {
+        ptz.pair(code: code)
+    }
+
+    /// Oublie la clé de cet iPhone.
+    func forgetPairing() {
+        ptz.forgetPairing()
+    }
+
     /// Arrière-plan : arrêt de la nacelle, fermeture du WebSocket et de la vidéo.
     func deactivate() {
         isForeground = false
@@ -102,6 +112,7 @@ final class AppModel {
         guard isActive else { return nil }
         return StatusBanner.text(for: BannerInputs(
             macUnreachable: ptz.isUnreachable,
+            authIssue: ptz.authIssue,
             connecting: ptz.link != .connected || video.phase != .playing,
             state: ptz.state
         ))
PATCH
```

Modifier `ios/Nacelle/Control/ControlScreen.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/Control/ControlScreen.swift b/ios/Nacelle/Control/ControlScreen.swift
index d73478d..f362753 100644
--- a/ios/Nacelle/Control/ControlScreen.swift
+++ b/ios/Nacelle/Control/ControlScreen.swift
@@ -46,7 +46,12 @@ struct ControlScreen: View {
             old != nil && new != nil && old != new
         }
         .sheet(isPresented: $showSettings) {
-            SettingsView(settings: $model.settings)
+            SettingsView(
+                settings: $model.settings,
+                isPaired: model.ptz.isPaired,
+                onPair: { model.pair(code: $0) },
+                onForget: { model.forgetPairing() }
+            )
         }
         .onAppear {
             if !model.settings.isComplete {
PATCH
```

Modifier `ios/Nacelle/Control/StatusBanner.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/Control/StatusBanner.swift b/ios/Nacelle/Control/StatusBanner.swift
index 3f29322..29ba140 100644
--- a/ios/Nacelle/Control/StatusBanner.swift
+++ b/ios/Nacelle/Control/StatusBanner.swift
@@ -3,18 +3,30 @@ import NacelleProtocol
 /// Ce que le bandeau d'état doit connaître.
 struct BannerInputs: Equatable {
     var macUnreachable: Bool
+    /// Ce qui empêche l'authentification auprès de ptzd.
+    var authIssue: PTZClient.AuthIssue? = nil
     /// WebSocket ou vidéo en cours de connexion.
     var connecting: Bool
     var state: StateSnapshot?
 }
 
-/// Texte du bandeau d'état (spec § 7.3). Ordre de priorité : Mac injoignable, caméra
-/// débranchée, vie privée, suivi IA non coupé, prise en main, connexion.
+/// Texte du bandeau d'état (spec § 7.3, spec accès local § 8.5). Ordre de priorité : Mac
+/// injoignable, appairage, caméra débranchée, vie privée, suivi IA non coupé, prise en main, connexion.
 enum StatusBanner {
     static func text(for inputs: BannerInputs) -> String? {
         if inputs.macUnreachable {
             return "Mac injoignable : Tailscale est-il actif ?"
         }
+        switch inputs.authIssue {
+        case .unpaired:
+            return "iPhone non appairé : lance ptzd pair sur le Mac"
+        case .badCode:
+            return "Code d'appairage refusé"
+        case .rejected:
+            return "Accès refusé par le Mac"
+        case nil:
+            break
+        }
         if let state = inputs.state {
             if state.camera == .absent {
                 return "Caméra débranchée"
PATCH
```

Remplacer tout le contenu de `ios/Nacelle/Settings/SettingsView.swift` par :

```swift
import SwiftUI

/// Réglages : le Mac et l'appairage (spec accès local § 8.1). Saisis au premier lancement,
/// modifiables ensuite.
struct SettingsView: View {
    @Binding var settings: ConnectionSettings
    let isPaired: Bool
    let onPair: (String) -> Void
    let onForget: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ConnectionSettings()
    // Port saisi en texte : un champ lié à un Int ne se met à jour qu'à la validation (Retour ou perte
    // du focus), et le pavé numérique n'a pas de Retour ; « Enregistrer » perdrait la dernière saisie.
    @State private var ptzdPortText = ""
    @State private var code = ""
    @State private var confirmForget = false

    /// Les réglages tels que saisis, port compris.
    private var edited: ConnectionSettings {
        var settings = draft
        settings.ptzdPort = ConnectionSettings.port(from: ptzdPortText)
        return settings
    }

    /// Un code d'appairage complet, ou rien.
    private var codeIsValid: Bool {
        code.isEmpty || PairingCodeInput.isValid(code)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("mon-mac.tailnet.ts.net", text: $draft.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    LabeledContent("Port ptzd") {
                        TextField("1985", text: $ptzdPortText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Mac")
                } footer: {
                    Text("Le nom Tailscale du Mac (MagicDNS), pour piloter de partout. À la maison, l'app trouve aussi le Mac sur le Wi-Fi, sans Tailscale.")
                }
                Section {
                    LabeledContent("État", value: isPaired ? "Appairé" : "Non appairé")
                    TextField("Code à 6 chiffres", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    if isPaired {
                        Button("Oublier cet appairage", role: .destructive) {
                            confirmForget = true
                        }
                    }
                } header: {
                    Text("Appairage")
                } footer: {
                    Text("Sur le Mac, lance ptzd pair dans le Terminal, puis saisis le code affiché (valable 5 min) et touche Enregistrer.")
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        settings = edited
                        if !code.isEmpty {
                            onPair(code)
                        }
                        dismiss()
                    }
                    .disabled(!edited.isComplete || !codeIsValid)
                }
            }
            .confirmationDialog("Oublier l'appairage ?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Oublier", role: .destructive) {
                    onForget()
                }
            } message: {
                Text("Le Mac refusera cet iPhone jusqu'au prochain appairage.")
            }
        }
        .onAppear {
            draft = settings
            ptzdPortText = String(settings.ptzdPort)
        }
    }
}

/// Saisie du code d'appairage.
enum PairingCodeInput {
    /// Six chiffres, espaces aux bords ignorés.
    static func isValid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.count == 6 && trimmed.allSatisfy(\.isASCII) && trimmed.allSatisfy(\.isNumber)
    }
}
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : tout passe (iOS : 60 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add ios/Nacelle/App/AppModel.swift \
    ios/Nacelle/Control/ControlScreen.swift \
    ios/Nacelle/Control/StatusBanner.swift \
    ios/Nacelle/Settings/SettingsView.swift \
    ios/NacelleTests/ConnectionSettingsTests.swift \
    ios/NacelleTests/StatusBannerTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
App : réglages d'appairage et bandeau

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit.

### Tâche 10 : Mise en service et essais avec Majid

**But :** installer le nouveau `ptzd` et la nouvelle app ensemble, appairer l'iPhone de Majid, puis vérifier le pilotage et la vidéo en Wi-Fi sans Tailscale et en 4G par Tailscale (spec accès local § 10 et § 11, étapes 1 et 2). La vidéo passe déjà par `ptzd` ; le `POST` direct vers go2rtc reste en secours.

**Fichiers :** aucun dans le dépôt. Réglages locaux seulement (`ios/Config/Local.xcconfig`, déjà présent).

- [ ] **Étape 1 : Prévenir Majid, puis installer le côté Mac**

Prévenir Majid : le service redémarre (l'app actuelle de l'iPhone perd la main jusqu'à l'étape 3), et macOS peut demander d'autoriser `ptzd` à accepter des connexions entrantes ou à accéder au réseau local : il répond **Autoriser**.

```bash
scripts/install-mac.sh
```

```bash
sleep 5; tail -6 ~/Library/Logs/obsbot-nacelle/ptzd.log | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g'
```

Attendu : « ptzd démarre. », l'écoute Tailscale et 127.0.0.1, une ligne « Écoute locale sur … » par interface Wi-Fi ou Ethernet active, et « Annonce Bonjour _nacelle._tcp sur … ».

- [ ] **Étape 2 : Vérifier le diagnostic local et le refus d'un client anonyme**

```bash
swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 wait 2 | head -2
```

Attendu : `{"type":"authenticated"}` puis l'état : 127.0.0.1 reste dispensé.

```bash
L=$(ipconfig getifaddr en0 || ipconfig getifaddr en1); swift mac/tools/nacelle-ws.swift ws://$L:1985 '{"type":"zoom","value":10}' wait 12 | sed -E 's/"nonce":"[^"]*"/"nonce":"…"/'
```

Attendu : un `challenge`, puis l'erreur `notAuthenticated` ; la connexion est fermée après 10 s, et `ptzd.log` contient « Client N libéré : pas authentifié en 10 s. ». Aucune commande n'atteint la caméra.

- [ ] **Étape 3 : Compiler et installer l'app sur l'iPhone (déverrouillé)**

`<UDID>` : l'identifiant de l'iPhone de Majid dans `xcrun devicectl list devices` (attention : un iPad est aussi appairé).

```bash
(cd ios && xcodegen -q) && xcodebuild build -project ios/Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS,id=<UDID>' -derivedDataPath ios/.build -allowProvisioningUpdates | tail -1
```

```bash
xcrun devicectl device install app --device <UDID> ios/.build/Build/Products/Debug-iphoneos/Nacelle.app
```

- [ ] **Étape 4 : Appairer (Majid)**

1. Majid ouvre l'app : le bandeau affiche « iPhone non appairé : lance ptzd pair sur le Mac ».
2. Ouvrir un code et le donner à Majid dans la conversation :

```bash
~/Library/Application\ Support/ObsbotNacelle/bin/ptzd pair
```

3. Majid le saisit dans Réglages › Appairage et touche **Enregistrer** ; iOS demande l'accès au réseau local : **Autoriser**. Prévenir : la caméra peut bouger à la connexion (prise en main).
4. Vérifier :

```bash
~/Library/Application\ Support/ObsbotNacelle/bin/ptzd devices; grep -E "appairé|authentifié" ~/Library/Logs/obsbot-nacelle/ptzd.log | tail -3
```

Attendu : une ligne pour l'iPhone, « Appareil appairé : … » et « Client N authentifié : iPhone (…). »

- [ ] **Étape 5 : Essais (Majid ; la caméra bouge)**

Noter le résultat de chaque point dans le rapport :
1. **Wi-Fi, Tailscale coupé sur l'iPhone** : vidéo en moins de 10 s, joystick, zoom, vie privée.
2. **4G (Wi-Fi coupé), Tailscale actif** : vidéo, joystick, zoom, vie privée.
3. **Arrière-plan 10 s puis retour**, en Wi-Fi puis en 4G : tout revient seul.
4. **Wi-Fi, Tailscale coupé, et accès au réseau local refusé** dans Réglages › Confidentialité › Réseau local : « Mac injoignable » ; puis rétablir l'accès.
5. Pendant les essais : `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log`. À la fin, les PID de go2rtc et de coreaudiod sont inchangés (`pgrep -x go2rtc`, `pgrep -x coreaudiod`).

### Tâche 11 : go2rtc fermé au réseau local, Homebridge avec mot de passe

**But :** API de go2rtc sur 127.0.0.1 seulement, RTSP protégé par un mot de passe, Homebridge mis à jour par Majid (spec accès local § 7). Vérifié d'abord sur une instance de test, puis appliqué au vrai go2rtc avec Majid présent. Retour arrière possible à tout moment.

**Fichiers :** aucun dans le dépôt. Modifié sur le Mac, jamais versionné : `/opt/homebrew/etc/go2rtc.yaml`. Le mot de passe RTSP ne va que dans ce fichier et dans la conversation avec Majid.

Faits déjà vérifiés sur go2rtc 1.9.14 (instance de test, 2026-10-06) : les sources `exec:` publient toujours sur `{output}` quand RTSP demande un mot de passe, car go2rtc dispense les clients locaux (127.0.0.1) ; un client RTSP du réseau sans mot de passe reçoit 401 ; l'API liée à 127.0.0.1 n'est plus joignable par le réseau local ni par Tailscale ; l'offre WebRTC envoyée sur l'API locale renvoie les candidats réseau local et Tailscale. Les scripts de surveillance de go2rtc du Mac (`go2rtc-lib.sh`) interrogent l'API sur 127.0.0.1 : ils continuent de marcher.

- [ ] **Étape 1 : Revérifier sur une instance de test (sans la caméra)**

```bash
T=$(mktemp -d); P=$(openssl rand -hex 8); cat > $T/test.yaml <<EOF
api:
  listen: "127.0.0.1:11984"
rtsp:
  listen: ":18554"
  username: "essai"
  password: "$P"
webrtc:
  listen: ":18555"
streams:
  mire:
    - exec:/opt/homebrew/bin/ffmpeg -hide_banner -re -f lavfi -i testsrc2=size=640x360:rate=15 -c:v libx264 -preset ultrafast -tune zerolatency -g 30 -bf 0 -an -rtsp_transport tcp -f rtsp {output}#timeout=30s#killsignal=15
EOF
/opt/homebrew/bin/go2rtc -config $T/test.yaml > $T/log 2>&1 & echo $! > $T/pid; sleep 2
L=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
ffprobe -v error -rtsp_transport tcp -show_entries stream=codec_name -of csv=p=0 "rtsp://essai:$P@$L:18554/mire"; echo "avec mot de passe : $?"
ffprobe -v error -rtsp_transport tcp "rtsp://$L:18554/mire" 2>&1 | grep -c 401; echo "(1 attendu : 401 sans mot de passe)"
curl -s -o /dev/null -w "API locale : %{http_code}\n" http://127.0.0.1:11984/api/streams
curl -s -m 3 -o /dev/null -w "API par le réseau : %{http_code}\n" http://$L:11984/api/streams
kill $(cat $T/pid); sleep 1; pkill -f "testsrc2=size=640x360"; rm -rf $T
```

Attendu : `h264` et « avec mot de passe : 0 » ; `1` (401 sans mot de passe) ; « API locale : 200 » ; « API par le réseau : 000 ». Vérifier ensuite que le vrai go2rtc a gardé son PID (`pgrep -x go2rtc`). Sinon, s'arrêter et faire un rapport.

- [ ] **Étape 2 : Avec Majid, sauvegarder et modifier la configuration**

Prévenir Majid : go2rtc redémarre une fois, HomeKit est coupé quelques secondes, et la caméra n'apparaîtra plus dans HomeKit tant que Homebridge n'aura pas le mot de passe (étape 4).

```bash
cp /opt/homebrew/etc/go2rtc.yaml /opt/homebrew/etc/go2rtc.yaml.avant-acces-local
```

```bash
P=$(openssl rand -hex 16); echo "Mot de passe RTSP (à donner à Majid, nulle part ailleurs) : $P"
python3 - "$P" <<'PY'
import pathlib, re, sys
p = pathlib.Path("/opt/homebrew/etc/go2rtc.yaml"); lines = p.read_text().splitlines(keepends=True)
api = [i for i, l in enumerate(lines) if l.startswith('  listen: ":1984"')]
rtsp = [i for i, l in enumerate(lines) if l.startswith('  listen: ":8554"')]
assert len(api) == 1 and len(rtsp) == 1, "configuration inattendue : ne rien modifier, faire un rapport"
assert lines[api[0] - 1].startswith("api:") and lines[rtsp[0] - 1].startswith("rtsp:"), "configuration inattendue"
lines[api[0]] = '  listen: "127.0.0.1:1984"   # WebUI + REST API : locale seulement, ptzd relaie l\'app\n'
lines.insert(rtsp[0] + 1, '  username: "homebridge"\n  password: "' + sys.argv[1] + '"\n')
p.write_text("".join(lines))
print("go2rtc.yaml modifié")
PY
```

Si l'une des vérifications échoue, la configuration n'est pas celle attendue : ne rien modifier, faire un rapport.

- [ ] **Étape 3 : Redémarrer go2rtc et vérifier**

```bash
launchctl kickstart -k gui/$(id -u)/com.majid.go2rtc; sleep 4; echo "go2rtc $(pgrep -x go2rtc)"; curl -s -o /dev/null -w "API locale : %{http_code}\n" http://127.0.0.1:1984/api/streams
```

```bash
L=$(ipconfig getifaddr en0 || ipconfig getifaddr en1); curl -s -m 3 -o /dev/null -w "API par le réseau : %{http_code}\n" http://$L:1984/api/streams; ffprobe -v error -rtsp_transport tcp "rtsp://$L:8554/obsbot" 2>&1 | grep -c 401
```

Attendu : un nouveau PID, « API locale : 200 », « API par le réseau : 000 », et `1` (RTSP sans mot de passe refusé).

- [ ] **Étape 4 : Homebridge (Majid)**

Majid remplace, dans la configuration de la caméra de Homebridge sur le NAS, l'adresse du flux par `rtsp://homebridge:<mot de passe>@<adresse du Mac>:8554/obsbot` (ainsi que l'adresse d'image fixe, si elle pointe vers go2rtc), puis redémarre Homebridge.

- [ ] **Étape 5 : Vérifier avec Majid**

1. HomeKit affiche la caméra (vidéo en direct).
2. L'app : vidéo et pilotage en Wi-Fi sans Tailscale, puis en 4G.
3. Sur le Mac : un seul ffmpeg vidéo et un seul ffmpeg audio quand un client regarde (`pgrep -fl ffmpeg | grep -c avfoundation`), PID de coreaudiod inchangé.

**Retour arrière**, si quoi que ce soit ne va pas :

```bash
cp /opt/homebrew/etc/go2rtc.yaml.avant-acces-local /opt/homebrew/etc/go2rtc.yaml && launchctl kickstart -k gui/$(id -u)/com.majid.go2rtc
```

Puis Majid remet l'ancienne adresse dans Homebridge.

### Tâche 12 : Retrait du secours vidéo direct

**But :** Une fois go2rtc fermé au réseau (tâche 11), l'ancien chemin vidéo direct ne sert plus : retrait du secours, de `Signaling` et des réglages port go2rtc et flux (spec accès local § 11, étape 4). Les anciens réglages enregistrés se relisent sans erreur.

**Fichiers :**
- Modifier : `ios/Nacelle/App/AppModel.swift`
- Modifier : `ios/Nacelle/PTZ/WebSocketTransport.swift`
- Modifier : `ios/Nacelle/Settings/ConnectionSettings.swift`
- Supprimer : `ios/Nacelle/Video/Signaling.swift`
- Modifier : `ios/Nacelle/Video/VideoSession.swift`
- Modifier : `ios/NacelleTests/ConnectionSettingsTests.swift`
- Supprimer : `ios/NacelleTests/SignalingTests.swift`

**Interfaces :**
- Consomme : `PTZClient.negotiate(offer:)` (tâche 8).
- Retire : `Signaling`, `SignalingError`, `ConnectionSettings.go2rtcPort`, `.streamName`, `.webRTCURL`.

- [ ] **Étape 1 : Écrire les tests**

Modifier `ios/NacelleTests/ConnectionSettingsTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/NacelleTests/ConnectionSettingsTests.swift b/ios/NacelleTests/ConnectionSettingsTests.swift
index a0c4b00..8b05744 100644
--- a/ios/NacelleTests/ConnectionSettingsTests.swift
+++ b/ios/NacelleTests/ConnectionSettingsTests.swift
@@ -4,23 +4,29 @@ import Testing
 
 @Suite("Réglages de connexion")
 struct ConnectionSettingsTests {
-    @Test("Adresses construites à partir de l'hôte, sans espaces")
+    @Test("Adresse construite à partir de l'hôte, sans espaces")
     func urls() {
-        let settings = ConnectionSettings(host: " mac.exemple.ts.net ", go2rtcPort: 1984, streamName: "obsbot", ptzdPort: 1985)
-        #expect(settings.webRTCURL?.absoluteString == "http://mac.exemple.ts.net:1984/api/webrtc?src=obsbot")
+        let settings = ConnectionSettings(host: " mac.exemple.ts.net ", ptzdPort: 1985)
         #expect(settings.ptzdURL?.absoluteString == "ws://mac.exemple.ts.net:1985")
     }
 
-    @Test("Incomplets : hôte vide, flux vide ou port hors bornes")
+    @Test("Incomplets : hôte vide ou port hors bornes")
     func incomplete() {
         #expect(!ConnectionSettings().isComplete)
-        #expect(ConnectionSettings().webRTCURL == nil)
-        #expect(!ConnectionSettings(host: "mac", streamName: " ").isComplete)
-        #expect(!ConnectionSettings(host: "mac", go2rtcPort: 0).isComplete)
+        #expect(ConnectionSettings().ptzdURL == nil)
+        #expect(!ConnectionSettings(host: "mac", ptzdPort: 0).isComplete)
         #expect(!ConnectionSettings(host: "mac", ptzdPort: 70000).isComplete)
         #expect(ConnectionSettings(host: "mac").isComplete)
     }
 
+    @Test("Anciens réglages (port go2rtc et flux) relus sans erreur")
+    func legacySettings() throws {
+        let defaults = try #require(UserDefaults(suiteName: "nacelle-tests-\(UUID().uuidString)"))
+        let legacy = #"{"host":"mac.exemple.ts.net","go2rtcPort":1984,"streamName":"obsbot","ptzdPort":1999}"#
+        defaults.set(Data(legacy.utf8), forKey: SettingsStore.key)
+        #expect(SettingsStore(defaults: defaults).load() == ConnectionSettings(host: "mac.exemple.ts.net", ptzdPort: 1999))
+    }
+
     @Test("Hôte mal saisi : schéma, port, barre oblique ou espace refusés, sans adresse construite")
     func invalidHost() {
         for host in [
@@ -31,7 +37,6 @@ struct ConnectionSettingsTests {
         ] {
             let settings = ConnectionSettings(host: host)
             #expect(!settings.isComplete, "\(host)")
-            #expect(settings.webRTCURL == nil, "\(host)")
             #expect(settings.ptzdURL == nil, "\(host)")
         }
         #expect(ConnectionSettings(host: "\tmac.exemple.ts.net\n").isComplete)
@@ -53,7 +58,7 @@ struct ConnectionSettingsTests {
         let defaults = try #require(UserDefaults(suiteName: "nacelle-tests-\(UUID().uuidString)"))
         let store = SettingsStore(defaults: defaults)
         #expect(store.load() == ConnectionSettings())
-        let settings = ConnectionSettings(host: "mac.exemple.ts.net", go2rtcPort: 1984, streamName: "cam", ptzdPort: 1999)
+        let settings = ConnectionSettings(host: "mac.exemple.ts.net", ptzdPort: 1999)
         store.save(settings)
         #expect(store.load() == settings)
     }
PATCH
```

Supprimer `ios/NacelleTests/SignalingTests.swift` :

```bash
git rm ios/NacelleTests/SignalingTests.swift
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : les tests passent déjà ou échouent à la compilation selon l'ordre ; c'est un retrait, l'étape sert de point de contrôle.

- [ ] **Étape 3 : Écrire le code**

Modifier `ios/Nacelle/App/AppModel.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/App/AppModel.swift b/ios/Nacelle/App/AppModel.swift
index a1569ce..8ff6f08 100644
--- a/ios/Nacelle/App/AppModel.swift
+++ b/ios/Nacelle/App/AppModel.swift
@@ -61,21 +61,9 @@ final class AppModel {
         guard !isActive, let ptzdURL = settings.ptzdURL else { return }
         isActive = true
         ptz.start(url: ptzdURL)
-        video.start { [weak self] offer in
-            guard let self else { throw PTZClient.NegotiationError.connectionLost }
-            return try await self.signal(offer: offer)
-        }
-    }
-
-    /// Offre vidéo relayée par ptzd. Pendant la transition (spec accès local § 11, étapes 1 à 3),
-    /// si go2rtc ne répond pas à ptzd, l'ancien `POST` direct vers go2rtc est retenté.
-    private func signal(offer: String) async throws -> String {
-        do {
-            return try await ptz.negotiate(offer: offer)
-        } catch PTZClient.NegotiationError.relay {
-            guard let url = settings.webRTCURL else { throw PTZClient.NegotiationError.relay("") }
-            let (data, response) = try await URLSession.shared.data(for: Signaling.request(url: url, offerSDP: offer))
-            return try Signaling.answer(data: data, response: response)
+        // Offre vidéo relayée par ptzd (spec accès local § 8.4).
+        video.start { [ptz] offer in
+            try await ptz.negotiate(offer: offer)
         }
     }
PATCH
```

Modifier `ios/Nacelle/PTZ/WebSocketTransport.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/PTZ/WebSocketTransport.swift b/ios/Nacelle/PTZ/WebSocketTransport.swift
index 0651fb0..841316c 100644
--- a/ios/Nacelle/PTZ/WebSocketTransport.swift
+++ b/ios/Nacelle/PTZ/WebSocketTransport.swift
@@ -38,7 +38,7 @@ protocol WebSocketTransport: AnyObject {
 /// les événements d'une connexion remplacée sont ignorés.
 @MainActor
 final class URLSessionWebSocketTransport: NSObject, WebSocketTransport {
-    /// Délai d'ouverture (60 s par défaut), aligné sur `Signaling.timeout`. Ce réglage ne coupe pas
+    /// Délai d'ouverture (60 s par défaut), aligné sur `PTZClient.negotiationTimeout`. Ce réglage ne coupe pas
     /// une connexion ouverte et silencieuse : c'est le rôle de `Heartbeat`.
     static let openTimeout: TimeInterval = 10
PATCH
```

Remplacer tout le contenu de `ios/Nacelle/Settings/ConnectionSettings.swift` par :

```swift
import Foundation

/// Où joindre le Mac hors de la maison (spec accès local § 8.1). Saisi au premier lancement,
/// modifiable ensuite. La vidéo passe par ptzd ; à la maison, Bonjour trouve le Mac.
struct ConnectionSettings: Codable, Equatable, Sendable {
    /// Nom Tailscale du Mac (par exemple `mon-mac.tailnet.ts.net`) ou son adresse IPv4.
    var host = ""
    var ptzdPort = 1985

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Un hôte nu (ni schéma, ni port, ni chemin, ni espace), un port valide, et l'adresse qui en découle.
    var isComplete: Bool {
        hasValidFields && makePtzdURL() != nil
    }

    private var hasValidFields: Bool {
        !trimmedHost.isEmpty
            && !trimmedHost.contains { $0 == "/" || $0 == ":" || $0.isWhitespace }
            && (1...65535).contains(ptzdPort)
    }

    /// Port tapé dans un champ texte ; 0 (donc réglages incomplets) si ce n'est pas un nombre.
    static func port(from text: String) -> Int {
        Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// `ws://<hôte>:<port ptzd>`
    var ptzdURL: URL? {
        isComplete ? makePtzdURL() : nil
    }

    private func makePtzdURL() -> URL? {
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

Supprimer `ios/Nacelle/Video/Signaling.swift` :

```bash
git rm ios/Nacelle/Video/Signaling.swift
```

Modifier `ios/Nacelle/Video/VideoSession.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/Video/VideoSession.swift b/ios/Nacelle/Video/VideoSession.swift
index 3755120..0cf36a4 100644
--- a/ios/Nacelle/Video/VideoSession.swift
+++ b/ios/Nacelle/Video/VideoSession.swift
@@ -115,7 +115,7 @@ final class VideoSession {
             constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
             delegate: observer
         ) else {
-            throw SignalingError.badResponse(status: 0)
+            throw PeerConnectionUnavailable()
         }
         let receiveOnly = RTCRtpTransceiverInit()
         receiveOnly.direction = .recvOnly
@@ -191,6 +191,9 @@ final class VideoSession {
 /// L'offre locale manque après `setLocalDescription`.
 private struct MissingLocalDescription: Error {}
 
+/// WebRTC n'a pas créé la connexion.
+private struct PeerConnectionUnavailable: Error {}
+
 /// Rappels de WebRTC (sur son propre fil), traduits en événements simples.
 private final class PeerObserver: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
     enum Event: Sendable {
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : tout passe (iOS : 58 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Mettre à jour le README**

Modifier `README.md` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

````bash
git apply <<'PATCH'
diff --git a/README.md b/README.md
index bc830e2..fac4c45 100644
--- a/README.md
+++ b/README.md
@@ -11,26 +11,26 @@ La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](h
 - **Côté Mac** : `ptzd` et `obsbot-ai-off` s'installent avec `scripts/install-mac.sh` (voir plus bas).
 - **App iOS** : s'installe depuis Xcode sur l'iPhone (voir « App iOS » plus bas).
 
-Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).
+Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [spec de l'accès local](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [plan de l'accès local](docs/superpowers/plans/2026-10-06-acces-local.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).
 
 ## Architecture
 
 ```
 iPhone : app SwiftUI                         Mac (celui de go2rtc)
 ┌───────────────────────────┐            ┌──────────────────────────────────┐
-│ Vidéo WebRTC  ────────────┼─ offre ───▶│ go2rtc (inchangé)                │
-│                           │◀─ images ──│   └─ ffmpeg ◀── Tiny 2 (USB)     │
-│ Joystick, zoom,           │            │                                  │
-│ vie privée  ──────────────┼─ WebSocket▶│ ptzd                             │
-│                           │◀─ état ────│   ├─ commandes UVC ──▶ Tiny 2    │
-│                           │            │   └─ lance obsbot-ai-off (SDK)   │
+│ Joystick, zoom,           │            │ ptzd                             │
+│ vie privée, offre vidéo ──┼─ WebSocket▶│   ├─ commandes UVC ──▶ Tiny 2    │
+│                           │  authentifié  ├─ lance obsbot-ai-off (SDK)   │
+│                           │◀─ état ────│   └─ relaie l'offre ──┐          │
+│                           │            │                       ▼          │
+│ Vidéo WebRTC ◀────────────┼─ images ───│ go2rtc (API en local) ◀── ffmpeg │
 └───────────────────────────┘            └──────────────────────────────────┘
-                 tout passe par Tailscale, à la maison comme dehors
+   à la maison : Wi-Fi (Bonjour) ; dehors : Tailscale
 ```
 
-- **`ptzd`** : un service macOS en Swift, lancé par launchd. C'est le seul à envoyer des commandes de nacelle à la caméra, en UVC. Il ne touche jamais au flux vidéo. Il écoute sur l'adresse Tailscale du Mac et sur 127.0.0.1, jamais sur le réseau local.
+- **`ptzd`** : un service macOS en Swift, lancé par launchd. C'est le seul à envoyer des commandes de nacelle à la caméra, en UVC. Il écoute sur l'adresse Tailscale du Mac, sur 127.0.0.1, et sur ses interfaces Wi-Fi et Ethernet, où il s'annonce par Bonjour (`_nacelle._tcp`). Chaque iPhone doit être appairé une fois ; ensuite, il signe un défi à chaque connexion. Seules les connexions venues de 127.0.0.1 en sont dispensées.
 - **`obsbot-ai-off`** : un petit utilitaire qui coupe le suivi IA de la caméra avec le SDK OBSBOT, puis se termine. `ptzd` le lance à chaque prise en main.
-- **go2rtc** : la vidéo arrive dans l'app directement en WebRTC. Aucun changement de configuration n'est nécessaire.
+- **go2rtc** : `ptzd` lui relaie l'offre WebRTC de l'app ; les images vont ensuite directement de go2rtc à l'iPhone. Voir « go2rtc » plus bas pour le fermer au réseau local.
 
 ## Installer le côté Mac
 
@@ -66,6 +66,9 @@ Le script compile `ptzd` et `obsbot-ai-off`, les installe dans `~/Library/Applic
 | `panMaxSpeed`, `tiltMaxSpeed` | Vitesses UVC maximales (pan 1–80, tilt 1–120) | 40, 60 |
 | `panDirection`, `tiltDirection` | Sens de chaque axe, +1 ou -1 | +1, +1 |
 | `aiOffPath` | Chemin de `obsbot-ai-off`, relatif au dossier d'installation | `bin/obsbot-ai-off` |
+| `localNetwork` | Écoute et annonce Bonjour sur le Wi-Fi et l'Ethernet | `true` |
+| `go2rtcAPI` | API locale de go2rtc, pour relayer la vidéo | `http://127.0.0.1:1984` |
+| `streamName` | Flux go2rtc relayé | `obsbot` |
 
 Après une modification, relancer le service :
 
@@ -80,6 +83,8 @@ launchctl kickstart -k gui/$(id -u)/io.github.djoko-cli.obsbot-nacelle.ptzd
 | Journal du service | `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log` |
 | Sortie du SDK | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai-off.log` |
 | Lire la position de la caméra | `~/Library/Application\ Support/ObsbotNacelle/bin/ptzd uvc get` |
+| Appareils appairés | `~/Library/Application\ Support/ObsbotNacelle/bin/ptzd devices` |
+| Voir l'annonce Bonjour | `dns-sd -B _nacelle._tcp` (Ctrl-C pour arrêter) |
 | Dialoguer avec le service | `swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"takeControl"}' wait 6` |
 
 Le Mac ne peut pas se joindre lui-même par son adresse Tailscale : en local, passer par 127.0.0.1.
@@ -113,12 +118,41 @@ Prérequis : Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew ins
    ```
 
 3. Au premier lancement, iOS demande de faire confiance au développeur : Réglages › Général › VPN et gestion de l'appareil.
-4. Dans l'app, saisir le nom Tailscale du Mac (champ `DNSName`, sans le point final, de `tailscale status --self --peers=false --json` sur le Mac). Les ports par défaut (1984 et 1985) et le flux `obsbot` conviennent.
+4. Dans l'app, saisir le nom Tailscale du Mac (champ `DNSName`, sans le point final, de `tailscale status --self --peers=false --json` sur le Mac). Le port par défaut (1985) convient.
+5. Appairer l'iPhone : sur le Mac, afficher un code (valable 5 min, un seul usage, 3 essais) :
+
+   ```bash
+   ~/Library/Application\ Support/ObsbotNacelle/bin/ptzd pair
+   ```
+
+   Puis, dans l'app, le saisir dans Réglages › Appairage et toucher **Enregistrer**. La clé de l'iPhone reste dans sa Secure Enclave ; le Mac ne garde que sa clé publique, dans `devices.json`.
+6. À la maison, l'app trouve le Mac sur le Wi-Fi, sans Tailscale : au premier essai, iOS demande l'accès au réseau local, répondre **Autoriser**.
+
+Retirer un iPhone : `ptzd devices` donne le début de son identifiant, puis `ptzd revoke <début>`. Ses connexions déjà ouvertes durent jusqu'à leur fin ; relancer le service pour les couper tout de suite.
 
 Avec un compte Apple gratuit, l'app expire au bout de 7 jours : refaire l'étape 2.
 
 Tests : `(cd ios && xcodegen && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build)`.
 
+## go2rtc
+
+`ptzd` relaie la négociation vidéo à l'API de go2rtc sur 127.0.0.1 : l'API n'a donc plus besoin d'être ouverte au réseau. Configuration conseillée (dans `go2rtc.yaml`, à adapter) :
+
+```yaml
+api:
+  listen: "127.0.0.1:1984"
+rtsp:
+  listen: ":8554"
+  username: "<identifiant>"
+  password: "<mot de passe>"
+webrtc:
+  listen: ":8555"
+```
+
+- go2rtc dispense les clients locaux (127.0.0.1) du mot de passe RTSP : les sources `exec:` qui publient sur `{output}` continuent de fonctionner sans changement.
+- Un client RTSP du réseau, comme Homebridge, doit alors donner l'identifiant et le mot de passe dans l'adresse du flux : `rtsp://<identifiant>:<mot de passe>@<Mac>:8554/obsbot`.
+- Le port WebRTC 8555 reste ouvert : sans offre négociée par `ptzd`, il ne donne aucune image.
+
 ## Désinstaller
 
 ```bash
@@ -138,7 +172,7 @@ rm -r ~/Library/Application\ Support/ObsbotNacelle ~/Library/Logs/obsbot-nacelle
 | Chemin | Rôle |
 |---|---|
 | `Packages/NacelleProtocol/` | Messages échangés entre l'app et `ptzd`, partagés par les deux |
-| `mac/ptzd/` | Le service : logique (`PTZCore`), accès USB (`CUVC`, `UVCCamera`), serveur WebSocket (`PTZServer`) |
+| `mac/ptzd/` | Le service : logique (`PTZCore`), appairage et authentification (`PTZAuth`), accès USB (`CUVC`, `UVCCamera`), serveur WebSocket et écoute locale (`PTZServer`) |
 | `mac/ai-off/` | L'utilitaire `obsbot-ai-off` (C++, demande le SDK en local) |
 | `mac/launchd/` | Modèle du plist de l'agent launchd |
 | `mac/tools/` | Client WebSocket de test |
PATCH
````

- [ ] **Étape 6 : Réinstaller l'app sur l'iPhone (déverrouillé) et vérifier avec Majid**

```bash
(cd ios && xcodegen -q) && xcodebuild build -project ios/Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS,id=<UDID>' -derivedDataPath ios/.build -allowProvisioningUpdates | tail -1
```

```bash
xcrun devicectl device install app --device <UDID> ios/.build/Build/Products/Debug-iphoneos/Nacelle.app
```

Attendu : l'iPhone reste appairé (la clé est dans le trousseau) ; vidéo et pilotage en Wi-Fi sans Tailscale, puis en 4G.

- [ ] **Étape 7 : Commiter et pousser**

```bash
git add README.md \
    ios/Nacelle/App/AppModel.swift \
    ios/Nacelle/PTZ/WebSocketTransport.swift \
    ios/Nacelle/Settings/ConnectionSettings.swift \
    ios/Nacelle/Video/VideoSession.swift \
    ios/NacelleTests/ConnectionSettingsTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.0|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
App : retrait du secours vidéo direct

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit.
