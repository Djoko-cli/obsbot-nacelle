# Plan d'implémentation : découverte du Mac et appairage par QR code

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectif :** aucune adresse à saisir — l'app trouve le Mac par Bonjour, s'appaire en scannant le QR code de `ptzd pair` sur le réseau local, et retient l'adresse locale du Mac, qui sert à la maison et en 4G par la route de sous-réseau du NAS ; l'app s'appelle PTZBot.

**Architecture :** `ptzd pair` demande à `ptzd`, par 127.0.0.1, un appairage en mémoire (identifiant, secret de 32 octets, 5 min) et l'affiche en QR code ; les écoutes du réseau local acceptent alors l'identité TLS `pair-<id>` avec ce secret pour clé. L'app joint les adresses du QR et le service Bonjour dans ce canal TLS, prouve la connaissance du secret par un HMAC sur le défi, reçoit le secret propre à l'iPhone (`paired`), puis s'authentifie comme avant. Ensuite, elle essaie l'adresse retenue (TLS si elle est locale, WebSocket simple si elle est Tailscale) et Bonjour, en parallèle.

**Technologies :** Swift 6 strict, Network.framework (`NWListener`, `NWBrowser`, `NWConnection`, TLS 1.2 à clé pré-partagée), CryptoKit (HMAC-SHA256, P-256), CoreImage (`CIQRCodeGenerator`), Vision (tests), VisionKit (`DataScannerViewController`), SwiftUI, Swift Testing, xcodegen, Xcode 27.

**Spec :** [docs/superpowers/specs/2026-10-06-decouverte-qr-design.md](../specs/2026-10-06-decouverte-qr-design.md), à lire avec ce plan. Elle amende la [spec de l'accès local](../specs/2026-10-06-acces-local-design.md), qui reste valable pour le reste.

## Contraintes globales

- **Swift :** Swift 6, concurrence stricte, **aucun avertissement** ; `ptzd` cible macOS 15, l'app iOS 26.
- **Appairage :** QR code seulement, sur le réseau local seulement. `openPairing` accepté de 127.0.0.1 (connexion de confiance) seulement ; appairage en mémoire, identifiant de 8 caractères hexadécimaux, secret de 32 octets, 5 min, usage unique, 3 preuves fausses au plus ; preuve = HMAC-SHA256(secret, `nacelle-pair-v1|<défi base64>|<clé publique base64>`) ; identité TLS `pair-<pairingID>`. Le secret du QR n'est jamais rangé par l'app.
- **QR code :** `nacelle://pair?v=1&id=<pairingID>&k=<secret base64url>&h=<adresse>[,<adresse>…]&p=<port>`.
- **Adresse du champ :** IPv4 privée (10/8, 172.16/12, 192.168/16) ou nom en `.local` : TLS avec le secret de l'iPhone ; tout le reste : WebSocket simple vers l'écoute Tailscale.
- **Noms :** l'app s'affiche « PTZBot » ; le service Bonjour s'appelle « PTZBot sur <nom de l'ordinateur> ». Cible et schéma `Nacelle`, identifiant `io.github.djoko-cli.nacelle`, paquet `NacelleProtocol`, type `_nacelle._tcp` : inchangés.
- **Dépôt public :** aucune adresse IP réelle (seules 127.0.0.1, 0.0.0.0, les adresses de documentation 192.0.2.x, 169.254.x.x, et dans les tests de route les adresses privées d'exemple 10.0.0.5, 172.16/31/32.x, 192.168.0.x et 100.64.0.1), aucun nom `*.ts.net` réel (seuls `mac.exemple.ts.net` et `mon-mac.tailnet.ts.net`), aucun chemin `/Users/…`, ni identifiant d'équipe ni UDID. Le contrôle de fuite est donné à chaque commit.
- **Système en service :** ne jamais toucher au `ptzd` installé, à go2rtc, à ffmpeg ni à leur configuration, sauf à la tâche 6, avec Majid présent. La caméra ne doit pas bouger en dehors de la tâche 6 ; les essais réseau des tâches de code utilisent le port 0 et une prise en main remplacée par `/usr/bin/true`. Aucun réglage de sécurité ou du système (pare-feu, TCC, Tailscale) : Majid les fait lui-même.
- **Commits :** messages en français, terminés par une ligne `Co-Authored-By:` au nom du modèle qui commite ; pousser la branche à chaque commit.

## Fichiers

| Fichier | Rôle |
|---|---|
| `Packages/NacelleProtocol/Sources/NacelleProtocol/{Messages,Codec,NacelleAuth,NacelleTLS}.swift` | Messages `openPairing`, `pairingOpened`, `pair` ; preuve HMAC ; identité TLS de l'appairage |
| `Packages/NacelleProtocol/Sources/NacelleProtocol/PairingLink.swift` | Lien `nacelle://pair` du QR code |
| `mac/ptzd/Sources/PTZAuth/PairingWindow.swift` | Appairage en cours, en mémoire (remplace `PairingCode`) |
| `mac/ptzd/Sources/PTZAuth/DeviceAuthority.swift` | Appairage par preuve, identités et clés TLS du réseau local |
| `mac/ptzd/Sources/PTZServer/WebSocketServer.swift` | `openPairing`, `pair`, expiration, relance des écoutes |
| `mac/ptzd/Sources/PTZServer/LocalNetworkListeners.swift` | Adresses locales de l'invitation, nom Bonjour |
| `mac/ptzd/Sources/PTZServer/{QRCodeText,PairCommand}.swift`, `mac/ptzd/Sources/ptzd/PTZDaemon.swift` | `ptzd pair` |
| `ios/Nacelle/Settings/ConnectionSettings.swift` | Adresse de repli, route TLS ou Tailscale |
| `ios/Nacelle/PTZ/{PTZClient,WebSocketTransport,LocalNetwork}.swift` | Candidates, appairage par QR, adresse retenue |
| `ios/Nacelle/Pairing/{Discovery,PairingScreen,QRScannerView}.swift` | Écran d'appairage, recherche Bonjour, lecteur de QR code |
| `ios/Nacelle/{App/AppModel,Control/ControlScreen,Control/StatusBanner,Settings/SettingsView}.swift`, `ios/project.yml` | Branchements, textes, nom PTZBot, permission de l'appareil photo |

## Points vérifiés en préparant ce plan (spec § 13)

1. **QR code dans le Terminal :** `CIQRCodeGenerator` (correction M) rend 41 modules pour un lien typique, plus une marge d'un module, retirée et remplacée par 2 modules blancs ; les demi-blocs `▀ ▄ █` et les codes ANSI noir sur blanc (`30;107`) gardent le code lisible quel que soit le thème. Le texte, redessiné en image, est relu par Vision (test de la tâche 3). La lecture par l'appareil photo de l'iPhone est vérifiée à la tâche 6.
2. **Lecteur de QR :** VisionKit `DataScannerViewController`, QR seulement. Dans le simulateur iOS 27, `isSupported` est faux : l'app affiche « Lecteur indisponible » sans demander l'appareil photo. La demande d'accès nomme bien « PTZBot ».
3. **Identité TLS de l'appairage :** `NacelleTLS.server(identities:keyFor:)` accepte l'identité `pair-<id>` en plus des appareils ; après usage ou expiration, `keyFor` la refuse aussitôt (veto) et les écoutes sont relancées. Vérifié par un vrai canal TLS sur ::1 (tâche 2).
4. **Adresse à retenir :** une fois la connexion TLS prête, `NWConnection.currentPath.remoteEndpoint` donne l'IPv4 du Mac, sans zone (`IPv4Address.rawValue`), pour une adresse du QR comme pour un service Bonjour résolu. À confirmer sur l'iPhone à la tâche 6.

## Décisions prises en préparant ce plan

- **Nom PTZBot** (demande de Majid pendant la préparation) : nom affiché et nom Bonjour seulement ; la spec § 8.1 est amendée en conséquence.
- **Échec d'un appairage** (preuve refusée, appairage fermé, `notLocal`, ou aucune réponse avec le secret du QR) : l'app s'arrête sur « QR code refusé : relance ptzd pair », sans reconnexion, et oublie le QR.
- **Verdicts d'un service local hors appairage** : inchangés, ils ne ferment que leur connexion.
- **Port de l'invitation** : celui de `config.json`, commun à toutes les écoutes.
- **Adresse retenue** : celle de la connexion qui a reçu `paired`, si le transport la connaît ; un champ déjà rempli n'est jamais remplacé, et la connexion en cours n'est pas coupée.

## Ordre et présence de Majid

- Tâches 1 à 5 : du code et des tests, sans toucher au système en service.
- Tâche 6 : mise en service de `ptzd` et de PTZBot, nouvel appairage par QR code et essais en Wi-Fi et en 4G, **avec Majid** (iPhone déverrouillé, en Wi-Fi).

---

### Tâche 1 : Protocole : `openPairing`, `pairingOpened`, nouveau `pair`, preuve et lien du QR code

**But :** Le paquet `NacelleProtocol` porte les messages de l'appairage par QR code (spec découverte et QR § 6), la preuve HMAC et le lien `nacelle://pair`. Le serveur et l'app reconnaissent les nouveaux cas sans encore les traiter : le code à 6 chiffres voyage provisoirement dans `pairingID`, sans preuve (passages marqués « Transition », remplacés aux tâches 2 et 4).

**Fichiers :**
- Modifier : `Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift`
- Modifier : `Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift`
- Modifier : `Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleAuth.swift`
- Modifier : `Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleTLS.swift`
- Créer : `Packages/NacelleProtocol/Sources/NacelleProtocol/PairingLink.swift`
- Modifier : `Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift`
- Modifier : `Packages/NacelleProtocol/Tests/NacelleProtocolTests/NacelleAuthTests.swift`
- Créer : `Packages/NacelleProtocol/Tests/NacelleProtocolTests/PairingLinkTests.swift`
- Modifier : `ios/Nacelle/PTZ/PTZClient.swift`
- Modifier : `ios/NacelleTests/PTZClientTests.swift`
- Modifier : `mac/ptzd/Sources/PTZCore/PTZController.swift`
- Modifier : `mac/ptzd/Sources/PTZServer/WebSocketServer.swift`
- Modifier : `mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift`
- Modifier : `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift`

**Interfaces :**
- Produit :
  - `ClientMessage.pair(pairingID: String, publicKey: Data, name: String, proof: Data)` (remplace `pair(code:publicKey:name:)`), `ClientMessage.openPairing` ;
  - `ServerMessage.pairingOpened(PairingInvitation)` ; `PairingInvitation(pairingID: String, secret: Data, expiresAt: Date, hosts: [String], port: Int)`, `expiresAt` en secondes depuis 1970 dans le JSON ;
  - `ErrorCode.notLocal` ;
  - `NacelleAuth.pairingProof(secret:nonce:publicKeyX963:) -> Data` (HMAC-SHA256 de `nacelle-pair-v1|<défi base64>|<clé base64>`) et `NacelleAuth.verifyPairingProof(_:secret:nonce:publicKeyX963:) -> Bool` ;
  - `NacelleTLS.pairingIdentity(_ pairingID: String) -> String` (`pair-<pairingID>`) ;
  - `PairingLink(pairingID:secret:hosts:port:)`, `PairingLink(_ invitation:)`, `PairingLink.url`, `PairingLink(url:)` et `PairingLink(string:)` (nil si ce n'est pas un lien `v=1` complet : identifiant hexadécimal, secret de 32 octets en base64url, au moins une adresse, port 1 à 65535).

- [ ] **Étape 1 : Écrire les tests**

Modifier `Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift b/Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift
index 3521ac0..7f0b76f 100644
--- a/Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift
+++ b/Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift
@@ -10,7 +10,8 @@ struct ClientMessageTests {
         .zoom(value: 33),
         .privacy(on: true),
         .privacy(on: false),
-        .pair(code: "042917", publicKey: Data([4, 1, 2, 3]), name: "iPhone"),
+        .pair(pairingID: "1a2b3c4d", publicKey: Data([4, 1, 2, 3]), name: "iPhone", proof: Data(repeating: 5, count: 32)),
+        .openPairing,
         .auth(deviceID: "00112233445566778899aabbccddeeff", signature: Data([48, 69, 2, 1])),
         .webrtcOffer(id: 3, sdp: "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n"),
     ])
@@ -19,10 +20,10 @@ struct ClientMessageTests {
         #expect(try NacelleCodec.decodeClient(text) == message)
     }
 
-    @Test("Les octets passent en base64, le code reste une chaîne (zéros en tête)")
+    @Test("pair : identifiant, clé publique et preuve en base64")
     func pairFormat() throws {
-        let text = try NacelleCodec.encode(ClientMessage.pair(code: "007123", publicKey: Data([1, 2, 3]), name: "iPhone"))
-        #expect(text == #"{"code":"007123","name":"iPhone","publicKey":"AQID","type":"pair"}"#)
+        let text = try NacelleCodec.encode(ClientMessage.pair(pairingID: "1a2b3c4d", publicKey: Data([1, 2, 3]), name: "iPhone", proof: Data([9])))
+        #expect(text == #"{"name":"iPhone","pairingID":"1a2b3c4d","proof":"CQ==","publicKey":"AQID","type":"pair"}"#)
     }
 
     @Test("takeControl s'écrit avec son seul type")
@@ -73,6 +74,11 @@ struct ServerMessageTests {
         .state(unknown),
         .error(code: .privacyActive, message: "Vie privée active : mouvement refusé."),
         .error(code: .unpaired, message: "Appareil inconnu."),
+        .error(code: .notLocal, message: "Réseau local seulement."),
+        .pairingOpened(PairingInvitation(
+            pairingID: "1a2b3c4d", secret: Data(repeating: 1, count: 32),
+            expiresAt: Date(timeIntervalSince1970: 1_791_300_000), hosts: ["192.0.2.30", "192.0.2.43"], port: 1985
+        )),
         .challenge(nonce: Data(repeating: 7, count: 32)),
         .authenticated,
         .paired(deviceID: "00112233445566778899aabbccddeeff", lanKey: Data(repeating: 9, count: 32)),
@@ -90,6 +96,13 @@ struct ServerMessageTests {
         #expect(text == #"{"camera":"absent","control":"idle","moving":false,"pan":null,"privacy":true,"tilt":null,"type":"state","zoom":null}"#)
     }
 
+    @Test("pairingOpened : échéance en secondes depuis 1970")
+    func pairingOpenedFormat() throws {
+        let invitation = PairingInvitation(pairingID: "1a2b3c4d", secret: Data([1]), expiresAt: Date(timeIntervalSince1970: 1_791_300_000), hosts: ["192.0.2.30"], port: 1985)
+        let text = try NacelleCodec.encode(ServerMessage.pairingOpened(invitation))
+        #expect(text.contains(#""expiresAt":1791300000"#))
+    }
+
     @Test("authenticated s'écrit avec son seul type")
     func authenticatedFormat() throws {
         #expect(try NacelleCodec.encode(ServerMessage.authenticated) == #"{"type":"authenticated"}"#)
PATCH
```

Modifier `Packages/NacelleProtocol/Tests/NacelleProtocolTests/NacelleAuthTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/Packages/NacelleProtocol/Tests/NacelleProtocolTests/NacelleAuthTests.swift b/Packages/NacelleProtocol/Tests/NacelleProtocolTests/NacelleAuthTests.swift
index cc9eff9..a006bca 100644
--- a/Packages/NacelleProtocol/Tests/NacelleProtocolTests/NacelleAuthTests.swift
+++ b/Packages/NacelleProtocol/Tests/NacelleProtocolTests/NacelleAuthTests.swift
@@ -23,6 +23,23 @@ struct NacelleAuthTests {
         #expect(NacelleAuth.deviceID(publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation) != deviceID)
     }
 
+    @Test("Preuve d'appairage : vecteur de référence (HMAC-SHA256 calculé indépendamment)")
+    func pairingProofVector() {
+        let proof = NacelleAuth.pairingProof(secret: Data(0..<32), nonce: Data(repeating: 7, count: 32), publicKeyX963: Data([4, 1, 2, 3]))
+        #expect(proof.map { String(format: "%02x", $0) }.joined() == "0bce16e8c37b0ea2fa995642a3216cd945ae6ce5ef5bc8391b74855b9574b17b")
+    }
+
+    @Test("Preuve d'appairage : juste acceptée ; autre secret, défi ou clé refusés")
+    func pairingProofVerify() {
+        let secret = Data(0..<32), nonce = Data(repeating: 7, count: 32), key = Data([4, 1, 2, 3])
+        let proof = NacelleAuth.pairingProof(secret: secret, nonce: nonce, publicKeyX963: key)
+        #expect(NacelleAuth.verifyPairingProof(proof, secret: secret, nonce: nonce, publicKeyX963: key))
+        #expect(!NacelleAuth.verifyPairingProof(proof, secret: Data(repeating: 1, count: 32), nonce: nonce, publicKeyX963: key))
+        #expect(!NacelleAuth.verifyPairingProof(proof, secret: secret, nonce: Data(repeating: 8, count: 32), publicKeyX963: key))
+        #expect(!NacelleAuth.verifyPairingProof(proof, secret: secret, nonce: nonce, publicKeyX963: Data([4, 1, 2, 4])))
+        #expect(!NacelleAuth.verifyPairingProof(Data([1, 2]), secret: secret, nonce: nonce, publicKeyX963: key))
+    }
+
     @Test("Charge utile signée")
     func payload() {
         let text = String(decoding: NacelleAuth.signedPayload(nonce: Data([1, 2, 3]), deviceID: "abc"), as: UTF8.self)
PATCH
```

Créer `Packages/NacelleProtocol/Tests/NacelleProtocolTests/PairingLinkTests.swift` :

```swift
import Foundation
import Testing
@testable import NacelleProtocol

@Suite("Lien d'appairage du QR code")
struct PairingLinkTests {
    let link = PairingLink(pairingID: "1a2b3c4d", secret: Data((0..<32).map { UInt8(250 - $0) }), hosts: ["192.0.2.30", "192.0.2.43"], port: 1985)

    @Test("Aller-retour par l'URL, secret en base64url sans remplissage")
    func roundTrip() throws {
        let text = link.url.absoluteString
        #expect(text.hasPrefix("nacelle://pair?v=1&id=1a2b3c4d&k="))
        #expect(text.hasSuffix("&h=192.0.2.30,192.0.2.43&p=1985"))
        #expect(!text.contains("="+"&") && !text.contains("+") && !text.contains("/"+"_"))
        #expect(PairingLink(url: link.url) == link)
        #expect(PairingLink(string: "  \(text)\n") == link)
    }

    @Test("Construit depuis une invitation de ptzd")
    func fromInvitation() {
        let invitation = PairingInvitation(pairingID: link.pairingID, secret: link.secret, expiresAt: Date(), hosts: link.hosts, port: link.port)
        #expect(PairingLink(invitation) == link)
    }

    @Test("Refusés : autre schéma, autre version, champ manquant, secret de mauvaise longueur, port hors bornes, sans adresse",
          arguments: [
              "https://pair?v=1&id=1a2b&k=AAAA&h=192.0.2.30&p=1985",
              "nacelle://pair?v=2&id=1a2b3c4d&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=192.0.2.30&p=1985",
              "nacelle://pair?v=1&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=192.0.2.30&p=1985",
              "nacelle://pair?v=1&id=1a2b3c4d&k=AAAA&h=192.0.2.30&p=1985",
              "nacelle://pair?v=1&id=1a2b3c4d&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=192.0.2.30&p=70000",
              "nacelle://pair?v=1&id=1a2b3c4d&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=&p=1985",
              "nacelle://pair?v=1&id=zz&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=192.0.2.30&p=1985",
              "pas une url",
          ])
    func rejected(_ text: String) {
        #expect(PairingLink(string: text) == nil)
    }

    @Test("Un secret de 32 octets en base64url (43 caractères) est accepté")
    func validMinimal() {
        let text = "nacelle://pair?v=1&id=1a2b3c4d&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=192.0.2.30&p=1985"
        #expect(PairingLink(string: text)?.secret == Data(count: 32))
    }

    @Test("Identité TLS de l'appairage")
    func identity() {
        #expect(NacelleTLS.pairingIdentity("1a2b3c4d") == "pair-1a2b3c4d")
    }
}
```

Modifier `ios/NacelleTests/PTZClientTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/NacelleTests/PTZClientTests.swift b/ios/NacelleTests/PTZClientTests.swift
index 5755cf2..15d9043 100644
--- a/ios/NacelleTests/PTZClientTests.swift
+++ b/ios/NacelleTests/PTZClientTests.swift
@@ -128,7 +128,7 @@ struct PTZClientTests {
         client.pair(code: " 042917 ")
         try emit(.challenge(nonce: nonce), on: tailscale)
         let key = try #require(keys.key)
-        #expect(decoded(tailscale) == [.pair(code: "042917", publicKey: key.publicKeyX963, name: "iPhone")])
+        #expect(decoded(tailscale) == [.pair(pairingID: "042917", publicKey: key.publicKeyX963, name: "iPhone", proof: Data())])
         try emit(.paired(deviceID: key.deviceID, lanKey: lanKey), on: tailscale)
         #expect(client.isPaired)
         guard case .auth = decoded(tailscale).last else {
@@ -236,7 +236,7 @@ struct PTZClientTests {
         #expect(decoded(local).isEmpty)
         try emit(.challenge(nonce: nonce), on: tailscale)
         let key = try #require(keys.key)
-        #expect(decoded(tailscale) == [.pair(code: "042917", publicKey: key.publicKeyX963, name: "iPhone")])
+        #expect(decoded(tailscale) == [.pair(pairingID: "042917", publicKey: key.publicKeyX963, name: "iPhone", proof: Data())])
         #expect(decoded(local).isEmpty)
         // Un faux « paired » venu du réseau local ne compte pas.
         try emit(.paired(deviceID: key.deviceID, lanKey: lanKey), on: local)
@@ -304,7 +304,7 @@ struct PTZClientTests {
         tailscale.emit(.opened)
         try emit(.challenge(nonce: nonce), on: tailscale)
         let key = try #require(keys.key)
-        #expect(decoded(tailscale) == [.pair(code: "042917", publicKey: key.publicKeyX963, name: "iPhone")])
+        #expect(decoded(tailscale) == [.pair(pairingID: "042917", publicKey: key.publicKeyX963, name: "iPhone", proof: Data())])
         try emit(.paired(deviceID: key.deviceID, lanKey: lanKey), on: tailscale)
         try emit(.authenticated, on: tailscale)
         #expect(client.link == .connected)
PATCH
```

Modifier `mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift b/mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift
index 4695ca1..e3eec51 100644
--- a/mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift
+++ b/mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift
@@ -38,7 +38,7 @@ struct PTZControllerTests {
     func sessionMessages() {
         let controller = makeController()
         #expect(controller.handle(.auth(deviceID: "x", signature: Data()), from: 1)?.code == .badMessage)
-        #expect(controller.handle(.pair(code: "123456", publicKey: Data(), name: "x"), from: 1)?.code == .badMessage)
+        #expect(controller.handle(.pair(pairingID: "123456", publicKey: Data(), name: "x", proof: Data()), from: 1)?.code == .badMessage)
         #expect(controller.handle(.webrtcOffer(id: 1, sdp: "v=0"), from: 1)?.code == .badMessage)
         #expect(camera.relativeCommands.isEmpty)
     }
PATCH
```

Modifier `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift b/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
index 7c241df..fd8e339 100644
--- a/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
+++ b/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
@@ -343,9 +343,9 @@ struct WebSocketServerTests {
         let nonce = try await challenge(task)
         let publicKey = key.publicKey.x963Representation
 
-        try await send(.pair(code: wrong, publicKey: publicKey, name: "iPhone"), on: task)
+        try await send(.pair(pairingID: wrong, publicKey: publicKey, name: "iPhone", proof: Data()), on: task)
         #expect(try await next(task) { _ in true } == .error(code: .badCode, message: "Code d'appairage faux."))
-        try await send(.pair(code: code, publicKey: publicKey, name: "iPhone"), on: task)
+        try await send(.pair(pairingID: code, publicKey: publicKey, name: "iPhone", proof: Data()), on: task)
         guard case let .paired(pairedID, lanKey) = try await next(task, where: { _ in true }) else {
             Issue.record("paired attendu")
             return
@@ -365,7 +365,7 @@ struct WebSocketServerTests {
         let task = connect("127.0.0.1", ports["127.0.0.1"]!)
         defer { task.cancel(with: .goingAway, reason: nil) }
         _ = try await challenge(task)
-        try await send(.pair(code: "123456", publicKey: key.publicKey.x963Representation, name: "iPhone"), on: task)
+        try await send(.pair(pairingID: "123456", publicKey: key.publicKey.x963Representation, name: "iPhone", proof: Data()), on: task)
         #expect(try await next(task) { _ in true } == .error(code: .pairingClosed, message: "Aucun appairage en cours : lancer ptzd pair sur le Mac."))
         withExtendedLifetime(server) {}
     }
@@ -477,7 +477,7 @@ struct WebSocketServerTests {
         defer { client.close() }
         try await client.open()
         _ = try await client.receive()
-        try client.send(.pair(code: "123456", publicKey: key.publicKey.x963Representation, name: "iPhone"))
+        try client.send(.pair(pairingID: "123456", publicKey: key.publicKey.x963Representation, name: "iPhone", proof: Data()))
         #expect(try await client.receive() == .error(code: .pairingClosed, message: "Appairage par Tailscale seulement."))
         withExtendedLifetime(server) {}
     }
@@ -495,7 +495,7 @@ struct WebSocketServerTests {
         let task = connect("127.0.0.1", ports["127.0.0.1"]!)
         defer { task.cancel(with: .goingAway, reason: nil) }
         _ = try await challenge(task)
-        try await send(.pair(code: code, publicKey: key.publicKey.x963Representation, name: "iPhone"), on: task)
+        try await send(.pair(pairingID: code, publicKey: key.publicKey.x963Representation, name: "iPhone", proof: Data()), on: task)
         guard case let .paired(_, lanKey) = try await next(task, where: { _ in true }) else {
             Issue.record("paired attendu")
             return
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd Packages/NacelleProtocol && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : échec — la compilation des tests échoue : `openPairing`, `pairingOpened`, `PairingLink` et la preuve n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Modifier `Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift b/Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift
index c26e5e3..e7af32e 100644
--- a/Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift
+++ b/Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift
@@ -31,7 +31,7 @@ public enum NacelleCodec {
 
 extension ClientMessage: Codable {
     private enum CodingKeys: String, CodingKey {
-        case type, pan, tilt, value, on, code, publicKey, name, deviceID, signature, id, sdp
+        case type, pan, tilt, value, on, pairingID, publicKey, name, proof, deviceID, signature, id, sdp
     }
 
     public init(from decoder: any Decoder) throws {
@@ -51,10 +51,13 @@ extension ClientMessage: Codable {
             self = .privacy(on: try container.decode(Bool.self, forKey: .on))
         case "pair":
             self = .pair(
-                code: try container.decode(String.self, forKey: .code),
+                pairingID: try container.decode(String.self, forKey: .pairingID),
                 publicKey: try container.decode(Data.self, forKey: .publicKey),
-                name: try container.decode(String.self, forKey: .name)
+                name: try container.decode(String.self, forKey: .name),
+                proof: try container.decode(Data.self, forKey: .proof)
             )
+        case "openPairing":
+            self = .openPairing
         case "auth":
             self = .auth(
                 deviceID: try container.decode(String.self, forKey: .deviceID),
@@ -82,11 +85,14 @@ extension ClientMessage: Codable {
         case let .privacy(on):
             try container.encode("privacy", forKey: .type)
             try container.encode(on, forKey: .on)
-        case let .pair(code, publicKey, name):
+        case let .pair(pairingID, publicKey, name, proof):
             try container.encode("pair", forKey: .type)
-            try container.encode(code, forKey: .code)
+            try container.encode(pairingID, forKey: .pairingID)
             try container.encode(publicKey, forKey: .publicKey)
             try container.encode(name, forKey: .name)
+            try container.encode(proof, forKey: .proof)
+        case .openPairing:
+            try container.encode("openPairing", forKey: .type)
         case let .auth(deviceID, signature):
             try container.encode("auth", forKey: .type)
             try container.encode(deviceID, forKey: .deviceID)
@@ -136,7 +142,7 @@ extension StateSnapshot: Codable {
 
 extension ServerMessage: Codable {
     private enum CodingKeys: String, CodingKey {
-        case type, code, message, nonce, deviceID, id, sdp, lanKey
+        case type, code, message, nonce, deviceID, id, sdp, lanKey, invitation
     }
 
     public init(from decoder: any Decoder) throws {
@@ -154,6 +160,8 @@ extension ServerMessage: Codable {
             self = .challenge(nonce: try container.decode(Data.self, forKey: .nonce))
         case "authenticated":
             self = .authenticated
+        case "pairingOpened":
+            self = .pairingOpened(try container.decode(PairingInvitation.self, forKey: .invitation))
         case "paired":
             self = .paired(deviceID: try container.decode(String.self, forKey: .deviceID), lanKey: try container.decode(Data.self, forKey: .lanKey))
         case "webrtcAnswer":
@@ -180,6 +188,9 @@ extension ServerMessage: Codable {
             try container.encode(nonce, forKey: .nonce)
         case .authenticated:
             try container.encode("authenticated", forKey: .type)
+        case let .pairingOpened(invitation):
+            try container.encode("pairingOpened", forKey: .type)
+            try container.encode(invitation, forKey: .invitation)
         case let .paired(deviceID, lanKey):
             try container.encode("paired", forKey: .type)
             try container.encode(deviceID, forKey: .deviceID)
PATCH
```

Modifier `Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift b/Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift
index 3b56b1f..8e20b60 100644
--- a/Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift
+++ b/Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift
@@ -10,8 +10,11 @@ public enum ClientMessage: Equatable, Sendable {
     case zoom(value: Int)
     /// Entre en vie privée (true) ou en sort (false).
     case privacy(on: Bool)
-    /// Enregistre la clé de l'appareil avec le code affiché par `ptzd pair` (spec accès local § 6.4).
-    case pair(code: String, publicKey: Data, name: String)
+    /// Enregistre la clé de l'appareil pour l'appairage `pairingID` du QR code ; `proof` prouve que
+    /// l'app connaît le secret du QR (spec découverte et QR § 6).
+    case pair(pairingID: String, publicKey: Data, name: String, proof: Data)
+    /// Ouvre un appairage ; accepté seulement depuis 127.0.0.1 (`ptzd pair`).
+    case openPairing
     /// Répond au défi : signature DER de `NacelleAuth.signedPayload` (spec accès local § 6.3).
     case auth(deviceID: String, signature: Data)
     /// Offre WebRTC à relayer à go2rtc ; `id` croît à chaque offre (spec accès local § 6.5).
@@ -48,6 +51,8 @@ public enum ErrorCode: String, Codable, Sendable {
     case pairingClosed
     /// Message refusé avant l'authentification.
     case notAuthenticated
+    /// `openPairing` hors de 127.0.0.1, ou `pair` hors de l'écoute du réseau local.
+    case notLocal
 }
 
 /// État complet publié par ptzd.
@@ -90,6 +95,8 @@ public enum ServerMessage: Equatable, Sendable {
     case challenge(nonce: Data)
     /// Connexion authentifiée ; l'état suit aussitôt.
     case authenticated
+    /// Appairage ouvert : ce que `ptzd pair` met dans le QR code.
+    case pairingOpened(PairingInvitation)
     /// L'appareil vient d'être enregistré ; `lanKey` est son secret du canal chiffré du réseau local
     /// (spec accès local § 14), remis seulement par Tailscale.
     case paired(deviceID: String, lanKey: Data)
@@ -98,3 +105,47 @@ public enum ServerMessage: Equatable, Sendable {
     /// go2rtc injoignable ou en erreur pour l'offre `id`.
     case webrtcError(id: Int, message: String)
 }
+
+/// Un appairage ouvert par ptzd : identifiant, secret, échéance, et où joindre le Mac.
+public struct PairingInvitation: Codable, Equatable, Sendable {
+    public var pairingID: String
+    /// 32 octets aléatoires ; clé TLS de l'appairage et clé de la preuve.
+    public var secret: Data
+    public var expiresAt: Date
+    /// Adresses IPv4 du Mac sur le réseau local.
+    public var hosts: [String]
+    public var port: Int
+
+    public init(pairingID: String, secret: Data, expiresAt: Date, hosts: [String], port: Int) {
+        self.pairingID = pairingID
+        self.secret = secret
+        self.expiresAt = expiresAt
+        self.hosts = hosts
+        self.port = port
+    }
+
+    private enum CodingKeys: String, CodingKey {
+        case pairingID, secret, expiresAt, hosts, port
+    }
+
+    /// `expiresAt` s'écrit en secondes depuis 1970 (spec découverte et QR § 6).
+    public init(from decoder: any Decoder) throws {
+        let c = try decoder.container(keyedBy: CodingKeys.self)
+        self.init(
+            pairingID: try c.decode(String.self, forKey: .pairingID),
+            secret: try c.decode(Data.self, forKey: .secret),
+            expiresAt: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .expiresAt)),
+            hosts: try c.decode([String].self, forKey: .hosts),
+            port: try c.decode(Int.self, forKey: .port)
+        )
+    }
+
+    public func encode(to encoder: any Encoder) throws {
+        var c = encoder.container(keyedBy: CodingKeys.self)
+        try c.encode(pairingID, forKey: .pairingID)
+        try c.encode(secret, forKey: .secret)
+        try c.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAt)
+        try c.encode(hosts, forKey: .hosts)
+        try c.encode(port, forKey: .port)
+    }
+}
PATCH
```

Modifier `Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleAuth.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleAuth.swift b/Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleAuth.swift
index 90cc354..bebfde3 100644
--- a/Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleAuth.swift
+++ b/Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleAuth.swift
@@ -17,6 +17,19 @@ public enum NacelleAuth {
         Data("nacelle-auth-v1|\(nonce.base64EncodedString())|\(deviceID)".utf8)
     }
 
+    /// Preuve d'appairage : HMAC-SHA256 avec le secret du QR, sur
+    /// `nacelle-pair-v1|<défi en base64>|<clé publique en base64>` (spec découverte et QR § 6).
+    public static func pairingProof(secret: Data, nonce: Data, publicKeyX963: Data) -> Data {
+        let message = Data("nacelle-pair-v1|\(nonce.base64EncodedString())|\(publicKeyX963.base64EncodedString())".utf8)
+        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
+    }
+
+    /// Vérifie une preuve d'appairage en temps constant.
+    public static func verifyPairingProof(_ proof: Data, secret: Data, nonce: Data, publicKeyX963: Data) -> Bool {
+        let message = Data("nacelle-pair-v1|\(nonce.base64EncodedString())|\(publicKeyX963.base64EncodedString())".utf8)
+        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: secret))
+    }
+
     /// Vrai si `signature` (DER) est celle de la clé `publicKeyX963` sur ce défi et cet appareil.
     /// Une clé ou une signature illisible donne faux.
     public static func verify(signature: Data, nonce: Data, deviceID: String, publicKeyX963: Data) -> Bool {
PATCH
```

Modifier `Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleTLS.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleTLS.swift b/Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleTLS.swift
index 567b47c..89f973d 100644
--- a/Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleTLS.swift
+++ b/Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleTLS.swift
@@ -12,6 +12,11 @@ public enum NacelleTLS {
     /// Longueur du secret remis à l'appairage, en octets.
     public static let keyLength = 32
 
+    /// Identité TLS d'un appairage en cours : `pair-<pairingID>` (spec découverte et QR § 7.1).
+    public static func pairingIdentity(_ pairingID: String) -> String {
+        "pair-\(pairingID)"
+    }
+
     /// Un secret neuf.
     public static func makeKey() -> Data {
         var generator = SystemRandomNumberGenerator()
PATCH
```

Créer `Packages/NacelleProtocol/Sources/NacelleProtocol/PairingLink.swift` :

```swift
import Foundation

/// Le contenu du QR code : `nacelle://pair?v=1&id=<pairingID>&k=<secret base64url>&h=<adresse>[,…]&p=<port>`
/// (spec découverte et QR § 6).
public struct PairingLink: Equatable, Sendable {
    public static let version = "1"

    public var pairingID: String
    public var secret: Data
    public var hosts: [String]
    public var port: Int

    public init(pairingID: String, secret: Data, hosts: [String], port: Int) {
        self.pairingID = pairingID
        self.secret = secret
        self.hosts = hosts
        self.port = port
    }

    public init(_ invitation: PairingInvitation) {
        self.init(pairingID: invitation.pairingID, secret: invitation.secret, hosts: invitation.hosts, port: invitation.port)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "nacelle"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.version),
            URLQueryItem(name: "id", value: pairingID),
            URLQueryItem(name: "k", value: Self.base64URL(secret)),
            URLQueryItem(name: "h", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "p", value: String(port)),
        ]
        return components.url!
    }

    /// Nil pour un QR qui n'est pas un appairage Nacelle de cette version, ou incomplet.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "nacelle", components.host == "pair" else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value
        }
        guard values["v"] == Self.version,
              let id = values["id"], !id.isEmpty, id.allSatisfy(\.isHexDigit),
              let key = values["k"].flatMap(Self.data(base64URL:)), key.count == 32,
              let hostList = values["h"], let portText = values["p"], let port = Int(portText),
              (1...65535).contains(port) else { return nil }
        let hosts = hostList.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }
        self.init(pairingID: id, secret: key, hosts: hosts, port: port)
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
```

Modifier `ios/Nacelle/PTZ/PTZClient.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/PTZ/PTZClient.swift b/ios/Nacelle/PTZ/PTZClient.swift
index ad11f78..3e75d34 100644
--- a/ios/Nacelle/PTZ/PTZClient.swift
+++ b/ios/Nacelle/PTZ/PTZClient.swift
@@ -451,7 +451,9 @@ final class PTZClient {
                 return
             }
             pairingCandidate = candidate
-            send(.pair(code: code, publicKey: key.publicKeyX963, name: deviceName), on: candidate)
+            // Transition (plan découverte et QR, tâche 1) : le code voyage dans `pairingID`, sans preuve ;
+            // la tâche 4 remplace ce passage par l'appairage du QR code.
+            send(.pair(pairingID: code, publicKey: key.publicKeyX963, name: deviceName, proof: Data()), on: candidate)
         } else if keys.load() != nil {
             authenticate(candidate)
         } else {
@@ -503,7 +505,7 @@ final class PTZClient {
             negotiations.removeValue(forKey: id)?.resume(returning: sdp)
         case let .webrtcError(id, message):
             negotiations.removeValue(forKey: id)?.resume(throwing: NegotiationError.relay(message))
-        case .challenge, .authenticated, .paired:
+        case .challenge, .authenticated, .paired, .pairingOpened:
             break
         }
     }
PATCH
```

Modifier `mac/ptzd/Sources/PTZCore/PTZController.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZCore/PTZController.swift b/mac/ptzd/Sources/PTZCore/PTZController.swift
index d3b03ef..339f58d 100644
--- a/mac/ptzd/Sources/PTZCore/PTZController.swift
+++ b/mac/ptzd/Sources/PTZCore/PTZController.swift
@@ -95,7 +95,7 @@ public final class PTZController {
                 try privacy.exit()
                 refreshAfterSettling()
             }
-        case .pair, .auth, .webrtcOffer:
+        case .pair, .openPairing, .auth, .webrtcOffer:
             // Messages de session : le serveur les traite et ne les transmet jamais.
             return (.badMessage, "Message de session inattendu.")
         }
PATCH
```

Modifier `mac/ptzd/Sources/PTZServer/WebSocketServer.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZServer/WebSocketServer.swift b/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
index b3572bf..4f5633e 100644
--- a/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
+++ b/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
@@ -387,7 +387,9 @@ public final class WebSocketServer {
         }
         guard let client = clients[id] else { return }
         switch message {
-        case let .pair(code, publicKey, name):
+        // Transition (plan découverte et QR, tâche 1) : l'identifiant porte encore le code à 6 chiffres ;
+        // la tâche 2 remplace ce passage par l'appairage du QR code.
+        case let .pair(code, publicKey, name, _):
             guard !client.authenticated else {
                 send(.error(code: .badMessage, message: "Déjà authentifié."), to: id)
                 return
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd Packages/NacelleProtocol && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : tout passe (protocole : 28 tests, Mac : 148 tests, iOS : 71 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add Packages/NacelleProtocol/Sources/NacelleProtocol/Codec.swift \
    Packages/NacelleProtocol/Sources/NacelleProtocol/Messages.swift \
    Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleAuth.swift \
    Packages/NacelleProtocol/Sources/NacelleProtocol/NacelleTLS.swift \
    Packages/NacelleProtocol/Sources/NacelleProtocol/PairingLink.swift \
    Packages/NacelleProtocol/Tests/NacelleProtocolTests/CodecTests.swift \
    Packages/NacelleProtocol/Tests/NacelleProtocolTests/NacelleAuthTests.swift \
    Packages/NacelleProtocol/Tests/NacelleProtocolTests/PairingLinkTests.swift \
    ios/Nacelle/PTZ/PTZClient.swift \
    ios/NacelleTests/PTZClientTests.swift \
    mac/ptzd/Sources/PTZCore/PTZController.swift \
    mac/ptzd/Sources/PTZServer/WebSocketServer.swift \
    mac/ptzd/Tests/PTZCoreTests/PTZControllerTests.swift \
    mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
Protocole : appairage par QR code (messages, preuve, lien)

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés à l'étape 1 ou 3 sont déjà indexés par `git rm`.

### Tâche 2 : `ptzd` : appairage par QR code sur le réseau local

**But :** `openPairing`, accepté de 127.0.0.1 seulement, ouvre un appairage en mémoire (5 min, usage unique, 3 essais) et renvoie l'invitation ; les écoutes du réseau local sont relancées pour connaître l'identité TLS `pair-<id>`, puis de nouveau après usage ou expiration ; `pair` n'est accepté que sur le réseau local, avec une preuve juste sur le défi de la connexion. Le code à 6 chiffres (`PairingCode`, `pairing.json`) disparaît ; le service Bonjour s'appelle « PTZBot sur <nom du Mac> » (spec découverte et QR § 7.1 et § 7.3).

**Fichiers :**
- Modifier : `mac/ptzd/Sources/PTZAuth/AuthCommand.swift`
- Modifier : `mac/ptzd/Sources/PTZAuth/DeviceAuthority.swift`
- Supprimer : `mac/ptzd/Sources/PTZAuth/PairingCode.swift`
- Créer : `mac/ptzd/Sources/PTZAuth/PairingWindow.swift`
- Modifier : `mac/ptzd/Sources/PTZServer/LocalNetworkListeners.swift`
- Modifier : `mac/ptzd/Sources/PTZServer/WebSocketServer.swift`
- Modifier : `mac/ptzd/Tests/PTZAuthTests/AuthCommandTests.swift`
- Modifier : `mac/ptzd/Tests/PTZAuthTests/DeviceAuthorityTests.swift`
- Supprimer : `mac/ptzd/Tests/PTZAuthTests/PairingCodeTests.swift`
- Créer : `mac/ptzd/Tests/PTZAuthTests/PairingWindowTests.swift`
- Modifier : `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift`

**Interfaces :**
- Consomme : tâche 1.
- Produit :
  - `PairingWindow` (`lifetime` 300 s, `maxFailures` 3) : `open() -> (pairingID: String, secret: Data, expiresAt: Date)`, `current: (pairingID: String, secret: Data)?`, `attempt(pairingID:proof:nonce:publicKeyX963:) -> PairingAttempt` (`.accepted`, `.wrong`, `.closed`), `close(_ pairingID: String? = nil)` ;
  - `DeviceAuthority(devices:pairing:now:)`, `DeviceAuthority.pairing`, `pair(pairingID:publicKey:name:proof:nonce:) -> PairResult`, `tlsIdentities() throws -> [String]`, `tlsKey(for:) -> Data?` ;
  - `AuthCommand.names` = `devices`, `revoke` (`ptzd pair` passe à la tâche 3) ;
  - `LocalNetworkListeners.addresses: [String]` (IPv4 écoutées, l'Ethernet d'abord), `LocalNetworkListeners.serviceName` = « PTZBot sur <nom de l'ordinateur> » ;
  - `WebSocketServer.logName(_:)` (nom d'appareil sans caractère de contrôle, 40 caractères au plus, pour le journal).
- Messages : `notLocal` « Ouverture d'appairage depuis le Mac seulement. » et « Appairage par QR code sur le réseau local seulement. » ; `badCode` « QR code refusé. » ; `pairingClosed` « QR code expiré ou déjà utilisé : relancer ptzd pair. ».
- Journal : « Appairage ouvert (<id>), valable 5 min. », « Appairage <id> : preuve fausse (<adresse>). », « Appairage <id> expiré. ».

- [ ] **Étape 1 : Écrire les tests**

Modifier `mac/ptzd/Tests/PTZAuthTests/AuthCommandTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZAuthTests/AuthCommandTests.swift b/mac/ptzd/Tests/PTZAuthTests/AuthCommandTests.swift
index fa0fee7..8e2e686 100644
--- a/mac/ptzd/Tests/PTZAuthTests/AuthCommandTests.swift
+++ b/mac/ptzd/Tests/PTZAuthTests/AuthCommandTests.swift
@@ -4,7 +4,7 @@ import NacelleProtocol
 import Testing
 @testable import PTZAuth
 
-@Suite("Commandes pair, devices et revoke")
+@Suite("Commandes devices et revoke")
 struct AuthCommandTests {
     let authority: DeviceAuthority
 
@@ -12,15 +12,6 @@ struct AuthCommandTests {
         authority = DeviceAuthority(directory: try makeTemporaryDirectory())
     }
 
-    @Test("pair affiche un code qui marche")
-    func pair() throws {
-        let result = AuthCommand.run(["pair"], authority: authority)
-        #expect(result.status == 0)
-        let code = try #require(result.output.split(separator: "\n").first?.split(separator: " ").last.map(String.init))
-        let key = P256.Signing.PrivateKey().publicKey.x963Representation
-        #expect(authority.pair(code: code, publicKey: key, name: "iPhone").deviceID == NacelleAuth.deviceID(publicKeyX963: key))
-    }
-
     @Test("devices : vide, puis une ligne par appareil")
     func devices() throws {
         #expect(AuthCommand.run(["devices"], authority: authority).output == "Aucun appareil appairé.")
@@ -41,7 +32,7 @@ struct AuthCommandTests {
         #expect(try authority.devices.all().isEmpty)
     }
 
-    @Test("Arguments en trop ou inconnus : usage, code 2", arguments: [["pair", "x"], ["devices", "x"], ["revoke"], ["dance"]])
+    @Test("Arguments en trop ou inconnus : usage, code 2", arguments: [["devices", "x"], ["revoke"], ["dance"]])
     func usage(_ arguments: [String]) {
         let result = AuthCommand.run(arguments, authority: authority)
         #expect(result.status == 2)
PATCH
```

Modifier `mac/ptzd/Tests/PTZAuthTests/DeviceAuthorityTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZAuthTests/DeviceAuthorityTests.swift b/mac/ptzd/Tests/PTZAuthTests/DeviceAuthorityTests.swift
index e978c54..2238b1c 100644
--- a/mac/ptzd/Tests/PTZAuthTests/DeviceAuthorityTests.swift
+++ b/mac/ptzd/Tests/PTZAuthTests/DeviceAuthorityTests.swift
@@ -22,15 +22,20 @@ struct DeviceAuthorityTests {
         try key.signature(for: NacelleAuth.signedPayload(nonce: nonce, deviceID: deviceID ?? self.deviceID)).derRepresentation
     }
 
-    func pairDevice(name: String = "iPhone de test") throws {
-        let code = try authority.pairing.open()
-        #expect(authority.pair(code: code, publicKey: publicKey, name: name).deviceID == deviceID)
+    /// Appairage par QR code complet : ouverture, preuve sur un défi, enregistrement.
+    @discardableResult
+    func pairDevice(name: String = "iPhone de test") -> PairResult {
+        let opened = authority.pairing.open()
+        let nonce = DeviceAuthority.makeNonce()
+        let proof = NacelleAuth.pairingProof(secret: opened.secret, nonce: nonce, publicKeyX963: publicKey)
+        let result = authority.pair(pairingID: opened.pairingID, publicKey: publicKey, name: name, proof: proof, nonce: nonce)
+        #expect(result.deviceID == deviceID)
+        return result
     }
 
     @Test("Secret du réseau local : 32 octets, gardé avec l'appareil, oublié au retrait")
     func lanKey() throws {
-        let code = try authority.pairing.open()
-        guard case let .paired(_, lanKey) = authority.pair(code: code, publicKey: publicKey, name: "iPhone") else {
+        guard case let .paired(_, lanKey) = pairDevice(name: "iPhone") else {
             Issue.record("appairage attendu")
             return
         }
@@ -66,7 +71,7 @@ struct DeviceAuthorityTests {
 
     @Test("Appairage puis authentification")
     func pairThenAuth() throws {
-        try pairDevice()
+        pairDevice()
         let nonce = DeviceAuthority.makeNonce()
         guard case let .accepted(device) = authority.check(deviceID: deviceID, signature: try signature(nonce), nonce: nonce) else {
             Issue.record("refusé")
@@ -81,7 +86,7 @@ struct DeviceAuthorityTests {
     func refusals() throws {
         let nonce = DeviceAuthority.makeNonce()
         #expect(authority.check(deviceID: deviceID, signature: try signature(nonce), nonce: nonce) == .unknownDevice)
-        try pairDevice()
+        pairDevice()
         let replayed = try signature(DeviceAuthority.makeNonce())
         #expect(authority.check(deviceID: deviceID, signature: replayed, nonce: nonce) == .badSignature)
     }
@@ -93,27 +98,44 @@ struct DeviceAuthorityTests {
         #expect(authority.check(deviceID: deviceID, signature: try signature(nonce), nonce: nonce) == .registryUnreadable)
     }
 
-    @Test("Appairage : code faux, fermé, clé invalide")
+    @Test("Appairage : aucun en cours, preuve fausse, autre identifiant, clé invalide")
     func pairFailures() throws {
-        #expect(authority.pair(code: "123456", publicKey: publicKey, name: "x") == .closed)
-        let code = try authority.pairing.open()
-        let wrong = code == "000000" ? "000001" : "000000"
-        #expect(authority.pair(code: wrong, publicKey: publicKey, name: "x") == .badCode)
-        #expect(authority.pair(code: code, publicKey: Data([4, 1, 2]), name: "x") == .invalidKey)
-        #expect(authority.pair(code: code, publicKey: publicKey, name: "x").deviceID == deviceID)
+        let nonce = DeviceAuthority.makeNonce()
+        #expect(authority.pair(pairingID: "00000000", publicKey: publicKey, name: "x", proof: Data(), nonce: nonce) == .closed)
+        let opened = authority.pairing.open()
+        let proof = NacelleAuth.pairingProof(secret: opened.secret, nonce: nonce, publicKeyX963: publicKey)
+        let other = NacelleAuth.pairingProof(secret: NacelleTLS.makeKey(), nonce: nonce, publicKeyX963: publicKey)
+        #expect(authority.pair(pairingID: opened.pairingID, publicKey: publicKey, name: "x", proof: other, nonce: nonce) == .badCode)
+        #expect(authority.pair(pairingID: "ffffffff", publicKey: publicKey, name: "x", proof: proof, nonce: nonce) == .closed)
+        #expect(authority.pair(pairingID: opened.pairingID, publicKey: Data([4, 1, 2]), name: "x", proof: proof, nonce: nonce) == .invalidKey)
+        #expect(authority.pair(pairingID: opened.pairingID, publicKey: publicKey, name: "x", proof: proof, nonce: nonce).deviceID == deviceID)
+    }
+
+    @Test("Identités TLS : les appareils, plus l'appairage en cours ; clé de chacune")
+    func tlsIdentities() throws {
+        pairDevice()
+        #expect(try authority.tlsIdentities() == [deviceID])
+        let opened = authority.pairing.open()
+        let identity = NacelleTLS.pairingIdentity(opened.pairingID)
+        #expect(Set(try authority.tlsIdentities()) == [deviceID, identity])
+        #expect(authority.tlsKey(for: identity) == opened.secret)
+        #expect(authority.tlsKey(for: deviceID) == authority.lanKey(for: deviceID))
+        authority.pairing.close()
+        #expect(authority.tlsKey(for: identity) == nil)
+        #expect(try authority.tlsIdentities() == [deviceID])
     }
 
     @Test("Nom nettoyé : espaces retirés, 40 caractères au plus, « appareil » si vide")
     func names() throws {
-        try pairDevice(name: "   ")
+        pairDevice(name: "   ")
         #expect(try authority.devices.device(id: deviceID)?.name == "appareil")
-        try pairDevice(name: "  " + String(repeating: "a", count: 60))
+        pairDevice(name: "  " + String(repeating: "a", count: 60))
         #expect(try authority.devices.device(id: deviceID)?.name == String(repeating: "a", count: 40))
     }
 
     @Test("revoke par début d'identifiant ; trop court, inconnu ou ambigu : erreur")
     func revoke() throws {
-        try pairDevice()
+        pairDevice()
         #expect(throws: PairedDevicesError.noMatch("abc")) { try authority.devices.remove(prefix: "abc") }
         #expect(throws: PairedDevicesError.noMatch("zzzz")) { try authority.devices.remove(prefix: "zzzz") }
         let removed = try authority.devices.remove(prefix: String(deviceID.prefix(6)).uppercased())
PATCH
```

Supprimer `mac/ptzd/Tests/PTZAuthTests/PairingCodeTests.swift` :

```bash
git rm mac/ptzd/Tests/PTZAuthTests/PairingCodeTests.swift
```

Créer `mac/ptzd/Tests/PTZAuthTests/PairingWindowTests.swift` :

```swift
import Foundation
import NacelleProtocol
import Testing
@testable import PTZAuth

@Suite("Fenêtre d'appairage par QR code")
struct PairingWindowTests {
    let clock = TestClock()
    let window: PairingWindow
    let nonce = Data(repeating: 7, count: 32)
    let key = Data([4, 1, 2, 3])

    init() {
        let clock = clock
        window = PairingWindow(now: { clock.now })
    }

    private func proof(_ secret: Data) -> Data {
        NacelleAuth.pairingProof(secret: secret, nonce: nonce, publicKeyX963: key)
    }

    @Test("Ouverture : identifiant de 8 caractères hexadécimaux, secret de 32 octets, 5 min")
    func open() {
        let opened = window.open()
        #expect(opened.pairingID.count == 8 && opened.pairingID.allSatisfy(\.isHexDigit))
        #expect(opened.secret.count == 32)
        #expect(opened.expiresAt == clock.now + PairingWindow.lifetime)
        #expect(window.current?.pairingID == opened.pairingID)
        #expect(window.current?.secret == opened.secret)
    }

    @Test("Bonne preuve : acceptée une seule fois")
    func singleUse() {
        let opened = window.open()
        #expect(window.attempt(pairingID: opened.pairingID, proof: proof(opened.secret), nonce: nonce, publicKeyX963: key) == .accepted)
        #expect(window.attempt(pairingID: opened.pairingID, proof: proof(opened.secret), nonce: nonce, publicKeyX963: key) == .closed)
        #expect(window.current == nil)
    }

    @Test("Trois preuves fausses ferment l'appairage")
    func threeFailures() {
        let opened = window.open()
        let wrong = proof(NacelleTLS.makeKey())
        for _ in 0..<3 {
            #expect(window.attempt(pairingID: opened.pairingID, proof: wrong, nonce: nonce, publicKeyX963: key) == .wrong)
        }
        #expect(window.attempt(pairingID: opened.pairingID, proof: proof(opened.secret), nonce: nonce, publicKeyX963: key) == .closed)
    }

    @Test("Expiré après 5 min")
    func expiry() {
        let opened = window.open()
        clock.advance(PairingWindow.lifetime)
        #expect(window.current == nil)
        #expect(window.attempt(pairingID: opened.pairingID, proof: proof(opened.secret), nonce: nonce, publicKeyX963: key) == .closed)
    }

    @Test("Un nouvel appairage remplace l'ancien ; close ciblé")
    func replaceAndClose() {
        let first = window.open()
        let second = window.open()
        #expect(window.attempt(pairingID: first.pairingID, proof: proof(first.secret), nonce: nonce, publicKeyX963: key) == .closed)
        window.close(first.pairingID)
        #expect(window.current?.pairingID == second.pairingID)
        window.close(second.pairingID)
        #expect(window.current == nil)
    }
}
```

Modifier `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift b/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
index fd8e339..b64e310 100644
--- a/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
+++ b/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
@@ -47,9 +47,12 @@ struct WebSocketServerTests {
         )
         let ports = await withCheckedContinuation { continuation in
             var ready: [String: UInt16] = [:]
+            var resumed = false
+            // Une écoute relancée (appairage) rappelle onReady : l'attente ne reprend qu'une fois.
             server.onReady = { host, port in
                 ready[host] = port
-                if ready.count == hosts.count {
+                if !resumed, ready.count == hosts.count {
+                    resumed = true
                     continuation.resume(returning: ready)
                 }
             }
@@ -333,40 +336,63 @@ struct WebSocketServerTests {
         #expect(lines.values.contains("Client 1 libéré : pas authentifié en 10 s (127.0.0.1)."))
     }
 
-    @Test("Appairage : code faux (connexion gardée), puis bon code, puis auth sur le même défi")
-    func pairing() async throws {
-        let code = try authority.pairing.open()
-        let wrong = code == "000000" ? "000001" : "000000"
+    /// Ouvre un appairage depuis 127.0.0.1 de confiance (comme `ptzd pair`) et renvoie l'invitation.
+    private func openPairing(port: UInt16) async throws -> (URLSessionWebSocketTask, PairingInvitation?) {
+        let task = connect("127.0.0.1", port)
+        try await send(.openPairing, on: task)
+        let reply = try await next(task) { message in
+            if case .pairingOpened = message { true } else { false }
+        }
+        guard case let .pairingOpened(invitation) = reply else { return (task, nil) }
+        return (task, invitation)
+    }
+
+    /// Preuve du QR code pour la clé de test sur ce défi.
+    private func proof(secret: Data, nonce: Data) -> Data {
+        NacelleAuth.pairingProof(secret: secret, nonce: nonce, publicKeyX963: key.publicKey.x963Representation)
+    }
+
+    @Test("openPairing depuis 127.0.0.1 de confiance : invitation (identifiant, secret, 5 min, adresses locales), journalisée")
+    func openPairingFromMac() async throws {
+        let lines = LineBox()
+        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], log: { lines.values.append($0) }, localHosts: ["::1"])
+        let (task, invitation) = try await openPairing(port: ports["127.0.0.1"]!)
+        defer { task.cancel(with: .goingAway, reason: nil) }
+        let opened = try #require(invitation)
+        #expect(authority.pairing.current?.pairingID == opened.pairingID)
+        #expect(authority.pairing.current?.secret == opened.secret)
+        #expect(opened.hosts == ["::1"])
+        #expect(abs(opened.expiresAt.timeIntervalSinceNow - PairingWindow.lifetime) < 5)
+        #expect(lines.values.contains("Appairage ouvert (\(opened.pairingID)), valable 5 min."))
+        withExtendedLifetime(server) {}
+    }
+
+    @Test("openPairing sans la confiance de 127.0.0.1 : notLocal, aucun appairage ouvert")
+    func openPairingRefused() async throws {
         let (server, ports) = await startServer(trustLoopback: false)
         let task = connect("127.0.0.1", ports["127.0.0.1"]!)
         defer { task.cancel(with: .goingAway, reason: nil) }
-        let nonce = try await challenge(task)
-        let publicKey = key.publicKey.x963Representation
-
-        try await send(.pair(pairingID: wrong, publicKey: publicKey, name: "iPhone", proof: Data()), on: task)
-        #expect(try await next(task) { _ in true } == .error(code: .badCode, message: "Code d'appairage faux."))
-        try await send(.pair(pairingID: code, publicKey: publicKey, name: "iPhone", proof: Data()), on: task)
-        guard case let .paired(pairedID, lanKey) = try await next(task, where: { _ in true }) else {
-            Issue.record("paired attendu")
-            return
-        }
-        #expect(pairedID == deviceID)
-        #expect(lanKey.count == NacelleTLS.keyLength)
-        #expect(authority.lanKey(for: deviceID) == lanKey)
-        try await send(.auth(deviceID: deviceID, signature: try signature(for: nonce)), on: task)
-        #expect(try await next(task) { _ in true } == .authenticated)
-        #expect(try authority.devices.device(id: deviceID)?.name == "iPhone")
+        _ = try await challenge(task)
+        try await send(.openPairing, on: task)
+        #expect(try await next(task) { _ in true } == .error(code: .notLocal, message: "Ouverture d'appairage depuis le Mac seulement."))
+        #expect(authority.pairing.current == nil)
         withExtendedLifetime(server) {}
     }
 
-    @Test("Appairage sans code en cours : pairingClosed")
-    func pairingClosed() async throws {
+    @Test("Appairage hors du réseau local (Tailscale) : notLocal, même avec la bonne preuve")
+    func pairOnlyOnLocalNetwork() async throws {
+        let opened = authority.pairing.open()
         let (server, ports) = await startServer(trustLoopback: false)
         let task = connect("127.0.0.1", ports["127.0.0.1"]!)
         defer { task.cancel(with: .goingAway, reason: nil) }
-        _ = try await challenge(task)
-        try await send(.pair(pairingID: "123456", publicKey: key.publicKey.x963Representation, name: "iPhone", proof: Data()), on: task)
-        #expect(try await next(task) { _ in true } == .error(code: .pairingClosed, message: "Aucun appairage en cours : lancer ptzd pair sur le Mac."))
+        let nonce = try await challenge(task)
+        let pair = ClientMessage.pair(
+            pairingID: opened.pairingID, publicKey: key.publicKey.x963Representation, name: "iPhone",
+            proof: proof(secret: opened.secret, nonce: nonce)
+        )
+        try await send(pair, on: task)
+        #expect(try await next(task) { _ in true } == .error(code: .notLocal, message: "Appairage par QR code sur le réseau local seulement."))
+        #expect(authority.pairing.current?.pairingID == opened.pairingID)
         withExtendedLifetime(server) {}
     }
 
@@ -467,43 +493,95 @@ struct WebSocketServerTests {
         withExtendedLifetime(server) {}
     }
 
-    @Test("Réseau local : appairage refusé, même pour un appareil appairé")
-    func noPairingOnLocalNetwork() async throws {
+    @Test("QR code sur le réseau local : preuve fausse (connexion gardée), bonne preuve, auth sur le même défi, écoute relancée")
+    func qrPairing() async throws {
+        let opened = authority.pairing.open()
+        let lines = LineBox()
+        let (server, ports) = await startServer(
+            on: ["127.0.0.1", "::1"], log: { lines.values.append($0) }, trustLoopback: false, localHosts: ["::1"]
+        )
+        let rebuilt = PortBox()
+        server.onReady = { host, port in
+            if host == "::1" {
+                rebuilt.port = port
+            }
+        }
+        let client = TLSClient(host: "::1", port: ports["::1"]!, identity: NacelleTLS.pairingIdentity(opened.pairingID), key: opened.secret)
+        defer { client.close() }
+        try await client.open()
+        guard case let .challenge(nonce) = try await client.receive() else {
+            Issue.record("défi attendu")
+            return
+        }
+        let publicKey = key.publicKey.x963Representation
+
+        try client.send(.pair(pairingID: opened.pairingID, publicKey: publicKey, name: "iPhone\n", proof: proof(secret: NacelleTLS.makeKey(), nonce: nonce)))
+        #expect(try await client.receive() == .error(code: .badCode, message: "QR code refusé."))
+        #expect(lines.values.contains("Appairage \(opened.pairingID) : preuve fausse (::1)."))
+        try client.send(.pair(pairingID: opened.pairingID, publicKey: publicKey, name: "iPhone\n", proof: proof(secret: opened.secret, nonce: nonce)))
+        guard case let .paired(pairedID, lanKey) = try await client.receive() else {
+            Issue.record("paired attendu")
+            return
+        }
+        #expect(pairedID == deviceID)
+        #expect(lanKey.count == NacelleTLS.keyLength)
+        #expect(authority.lanKey(for: deviceID) == lanKey)
+        #expect(authority.pairing.current == nil)
+        #expect(lines.values.contains("Appareil appairé : \(deviceID.prefix(8)) (iPhone)."))
+        try client.send(.auth(deviceID: deviceID, signature: try signature(for: nonce)))
+        #expect(try await client.receive() == .authenticated)
+
+        try await waitUntil { rebuilt.port != nil }
+        let (again, reply) = try await authenticateOverTLS(port: rebuilt.port!, lanKey: lanKey)
+        defer { again.close() }
+        #expect(reply == .authenticated)
+        let reused = TLSClient(host: "::1", port: rebuilt.port!, identity: NacelleTLS.pairingIdentity(opened.pairingID), key: opened.secret)
+        defer { reused.close() }
+        await #expect(throws: TLSClientError.noChannel) { try await reused.open() }
+    }
+
+    @Test("Réseau local, appairage déjà utilisé ou inconnu : pairingClosed")
+    func pairingClosedOnLocalNetwork() async throws {
         let lanKey = NacelleTLS.makeKey()
         try pairTestDevice(lanKey: lanKey)
-        _ = try authority.pairing.open()
         let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], trustLoopback: false, localHosts: ["::1"])
         let client = TLSClient(host: "::1", port: ports["::1"]!, identity: deviceID, key: lanKey)
         defer { client.close() }
         try await client.open()
         _ = try await client.receive()
-        try client.send(.pair(pairingID: "123456", publicKey: key.publicKey.x963Representation, name: "iPhone", proof: Data()))
-        #expect(try await client.receive() == .error(code: .pairingClosed, message: "Appairage par Tailscale seulement."))
+        try client.send(.pair(pairingID: "1a2b3c4d", publicKey: key.publicKey.x963Representation, name: "iPhone", proof: Data(count: 32)))
+        #expect(try await client.receive() == .error(code: .pairingClosed, message: "QR code expiré ou déjà utilisé : relancer ptzd pair."))
         withExtendedLifetime(server) {}
     }
 
-    @Test("Appairage par Tailscale : l'écoute locale est relancée et accepte le nouveau secret")
-    func rebuildAfterPairing() async throws {
-        let code = try authority.pairing.open()
-        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], trustLoopback: false, localHosts: ["::1"])
+    @Test("Appairage ouvert : expiré au bout de 5 min, journalisé, écoute locale relancée")
+    func pairingExpiry() async throws {
+        let scheduler = FakeScheduler()
+        let lines = LineBox()
+        let (server, ports) = await startServer(
+            on: ["127.0.0.1", "::1"], scheduler: scheduler, log: { lines.values.append($0) }, localHosts: ["::1"]
+        )
+        let (task, invitation) = try await openPairing(port: ports["127.0.0.1"]!)
+        defer { task.cancel(with: .goingAway, reason: nil) }
+        let opened = try #require(invitation)
         let rebuilt = PortBox()
         server.onReady = { host, port in
             if host == "::1" {
                 rebuilt.port = port
             }
         }
-        let task = connect("127.0.0.1", ports["127.0.0.1"]!)
-        defer { task.cancel(with: .goingAway, reason: nil) }
-        _ = try await challenge(task)
-        try await send(.pair(pairingID: code, publicKey: key.publicKey.x963Representation, name: "iPhone", proof: Data()), on: task)
-        guard case let .paired(_, lanKey) = try await next(task, where: { _ in true }) else {
-            Issue.record("paired attendu")
-            return
-        }
+        scheduler.advance(by: PairingWindow.lifetime - 1)
+        #expect(authority.pairing.current?.pairingID == opened.pairingID)
+        scheduler.advance(by: 1)
+        #expect(authority.pairing.current == nil)
+        #expect(lines.values.contains("Appairage \(opened.pairingID) expiré."))
         try await waitUntil { rebuilt.port != nil }
-        let (client, reply) = try await authenticateOverTLS(port: rebuilt.port!, lanKey: lanKey)
-        defer { client.close() }
-        #expect(reply == .authenticated)
+    }
+
+    @Test("Journal : nom d'appareil sans caractère de contrôle, 40 caractères au plus")
+    func logName() {
+        #expect(WebSocketServer.logName("iPhone\n\u{1B}[2Jde test") == "iPhone[2Jde test")
+        #expect(WebSocketServer.logName(String(repeating: "a", count: 60)) == String(repeating: "a", count: 40))
     }
 
     @Test("Appareil retiré : refusé dès la poignée de main TLS suivante")
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : échec — la compilation des tests échoue : `PairingWindow`, la nouvelle signature de `DeviceAuthority.pair` et `tlsIdentities` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Remplacer tout le contenu de `mac/ptzd/Sources/PTZAuth/AuthCommand.swift` par :

```swift
import Foundation

/// `ptzd devices` et `ptzd revoke` (spec accès local § 6.4), lancés à la main dans le Terminal pendant
/// que le service tourne : ils ne passent que par `devices.json`. `ptzd pair` parle au service (`PairCommand`).
public enum AuthCommand {
    public static let names: Set<String> = ["devices", "revoke"]
    public static let usage = """
    usage : ptzd devices                       liste les appareils appairés
            ptzd revoke <début d'identifiant>  retire un appareil (4 caractères au moins)
    """

    /// Code de sortie et texte à afficher.
    public static func run(_ arguments: [String], authority: DeviceAuthority) -> (status: Int32, output: String) {
        switch (arguments.first, arguments.count) {
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

Modifier `mac/ptzd/Sources/PTZAuth/DeviceAuthority.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZAuth/DeviceAuthority.swift b/mac/ptzd/Sources/PTZAuth/DeviceAuthority.swift
index fc91cf7..5b1611a 100644
--- a/mac/ptzd/Sources/PTZAuth/DeviceAuthority.swift
+++ b/mac/ptzd/Sources/PTZAuth/DeviceAuthority.swift
@@ -21,24 +21,22 @@ public enum PairResult: Equatable, Sendable {
     case invalidKey
 }
 
-/// Décide qui entre : appareils appairés et code d'appairage (spec accès local § 6.3 et § 6.4).
+/// Décide qui entre : appareils appairés et appairage par QR code en cours (spec accès local § 6.3,
+/// spec découverte et QR § 7.1).
 public struct DeviceAuthority: Sendable {
     public let devices: PairedDevices
-    public let pairing: PairingCode
+    public let pairing: PairingWindow
     private let now: @Sendable () -> Date
 
-    public init(devices: PairedDevices, pairing: PairingCode, now: @escaping @Sendable () -> Date = { Date() }) {
+    public init(devices: PairedDevices, pairing: PairingWindow, now: @escaping @Sendable () -> Date = { Date() }) {
         self.devices = devices
         self.pairing = pairing
         self.now = now
     }
 
-    /// Les deux fichiers dans le dossier de travail de ptzd.
+    /// `devices.json` dans le dossier de travail de ptzd ; l'appairage en cours vit en mémoire.
     public init(directory: URL) {
-        self.init(
-            devices: PairedDevices(url: directory.appending(path: "devices.json")),
-            pairing: PairingCode(url: directory.appending(path: "pairing.json"))
-        )
+        self.init(devices: PairedDevices(url: directory.appending(path: "devices.json")), pairing: PairingWindow())
     }
 
     /// Un défi neuf.
@@ -59,9 +57,10 @@ public struct DeviceAuthority: Sendable {
         return valid ? .accepted(device) : .badSignature
     }
 
-    public func pair(code: String, publicKey: Data, name: String) -> PairResult {
+    /// Appairage par QR code : la preuve porte sur le défi `nonce` de la connexion.
+    public func pair(pairingID: String, publicKey: Data, name: String, proof: Data, nonce: Data) -> PairResult {
         guard (try? P256.Signing.PublicKey(x963Representation: publicKey)) != nil else { return .invalidKey }
-        switch pairing.attempt(code) {
+        switch pairing.attempt(pairingID: pairingID, proof: proof, nonce: nonce, publicKeyX963: publicKey) {
         case .closed:
             return .closed
         case .wrong:
@@ -99,6 +98,23 @@ public struct DeviceAuthority: Sendable {
     public func lanKey(for deviceID: String) -> Data? {
         (try? devices.device(id: deviceID))?.flatMap(\.lanKey)
     }
+
+    /// Identités TLS du réseau local : les appareils, et l'appairage en cours ; erreur si `devices.json` est illisible.
+    public func tlsIdentities() throws -> [String] {
+        var identities = Array(try readLANKeys().keys)
+        if let current = pairing.current {
+            identities.append(NacelleTLS.pairingIdentity(current.pairingID))
+        }
+        return identities
+    }
+
+    /// Clé TLS d'une identité : le secret du QR pour l'appairage en cours, sinon celui de l'appareil.
+    public func tlsKey(for identity: String) -> Data? {
+        if let current = pairing.current, identity == NacelleTLS.pairingIdentity(current.pairingID) {
+            return current.secret
+        }
+        return lanKey(for: identity)
+    }
 }
 
 extension PairResult {
PATCH
```

Supprimer `mac/ptzd/Sources/PTZAuth/PairingCode.swift` :

```bash
git rm mac/ptzd/Sources/PTZAuth/PairingCode.swift
```

Créer `mac/ptzd/Sources/PTZAuth/PairingWindow.swift` :

```swift
import Foundation
import NacelleProtocol
import Synchronization

/// Résultat d'un essai d'appairage.
public enum PairingAttempt: Equatable, Sendable {
    case accepted
    /// Preuve fausse ; l'appairage reste ouvert s'il reste des essais.
    case wrong
    /// Aucun appairage en cours, expiré, déjà utilisé, ou autre identifiant.
    case closed
}

/// L'appairage en cours, en mémoire (spec découverte et QR § 7.1) : identifiant, secret du QR code,
/// échéance et essais faux. Lu aussi par la file TLS des écoutes du réseau local, d'où le verrou.
public final class PairingWindow: Sendable {
    public static let lifetime: TimeInterval = 300
    public static let maxFailures = 3

    struct Open {
        var pairingID: String
        var secret: Data
        var expiresAt: Date
        var failures: Int
    }

    private let state = Mutex<Open?>(nil)
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Ouvre un appairage neuf (remplace celui en cours) : identifiant de 8 caractères hexadécimaux,
    /// secret de 32 octets, valable 5 min.
    public func open() -> (pairingID: String, secret: Data, expiresAt: Date) {
        var generator = SystemRandomNumberGenerator()
        let pairingID = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
        let secret = NacelleTLS.makeKey()
        let expiresAt = now() + Self.lifetime
        state.withLock { $0 = Open(pairingID: pairingID, secret: secret, expiresAt: expiresAt, failures: 0) }
        return (pairingID, secret, expiresAt)
    }

    /// L'appairage en cours et non expiré, ou nil.
    public var current: (pairingID: String, secret: Data)? {
        state.withLock { open in
            guard let open, now() < open.expiresAt else { return nil }
            return (open.pairingID, open.secret)
        }
    }

    /// Vérifie la preuve. Juste : l'appairage est consommé. Fausse : un essai de moins ; au 3e, fermé.
    public func attempt(pairingID: String, proof: Data, nonce: Data, publicKeyX963: Data) -> PairingAttempt {
        state.withLock { open in
            guard let current = open, current.pairingID == pairingID, now() < current.expiresAt else {
                return .closed
            }
            if NacelleAuth.verifyPairingProof(proof, secret: current.secret, nonce: nonce, publicKeyX963: publicKeyX963) {
                open = nil
                return .accepted
            }
            open?.failures += 1
            if (open?.failures ?? 0) >= Self.maxFailures {
                open = nil
            }
            return .wrong
        }
    }

    /// Ferme l'appairage en cours, s'il y en a un et s'il porte cet identifiant (nil : n'importe lequel).
    public func close(_ pairingID: String? = nil) {
        state.withLock { open in
            if pairingID == nil || open?.pairingID == pairingID {
                open = nil
            }
        }
    }
}
```

Modifier `mac/ptzd/Sources/PTZServer/LocalNetworkListeners.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZServer/LocalNetworkListeners.swift b/mac/ptzd/Sources/PTZServer/LocalNetworkListeners.swift
index 3112729..8c03692 100644
--- a/mac/ptzd/Sources/PTZServer/LocalNetworkListeners.swift
+++ b/mac/ptzd/Sources/PTZServer/LocalNetworkListeners.swift
@@ -12,7 +12,8 @@ import PTZCore
 final class LocalNetworkListeners {
     /// Filet de sécurité : un changement d'adresse DHCP ne déclenche pas toujours le moniteur de chemin.
     static let reconcileInterval: TimeInterval = 30
-    static let serviceName = "Nacelle"
+    /// « PTZBot sur <nom de l'ordinateur> », pour distinguer plusieurs Mac (spec découverte et QR § 7.3).
+    static let serviceName = "PTZBot sur \(Host.current().localizedName ?? "Mac")"
     static let serviceType = "_nacelle._tcp"
 
     private struct Bound {
@@ -60,6 +61,11 @@ final class LocalNetworkListeners {
     }
 
     /// Relance toutes les écoutes (nouveaux réglages TLS) : chacune se relie après `.cancelled`.
+    /// Adresses IPv4 écoutées, l'Ethernet d'abord.
+    var addresses: [String] {
+        bound.sorted { ($0.value.isWired ? 0 : 1, $0.key) < ($1.value.isWired ? 0 : 1, $1.key) }.map(\.value.address)
+    }
+
     func rebuild() {
         let names = Array(bound.keys)
         guard !names.isEmpty else { return }
PATCH
```

Modifier `mac/ptzd/Sources/PTZServer/WebSocketServer.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/PTZServer/WebSocketServer.swift b/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
index 4f5633e..8c90f93 100644
--- a/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
+++ b/mac/ptzd/Sources/PTZServer/WebSocketServer.swift
@@ -49,6 +49,8 @@ public final class WebSocketServer {
     private let localHosts: Set<String>
     private var listeners: [String: NWListener] = [:]
     private var localListeners: LocalNetworkListeners?
+    /// Échéance de l'appairage en cours.
+    private var expiry: (any Cancellable)?
     private var clients: [ClientID: Client] = [:]
     private var nextID: ClientID = 1
 
@@ -140,19 +142,19 @@ public final class WebSocketServer {
         }
     }
 
-    /// TLS à clé pré-partagée du réseau local : les secrets des appareils appairés à cet instant,
+    /// TLS à clé pré-partagée du réseau local : les secrets des appareils appairés et de l'appairage en cours,
     /// et le veto d'un appareil retiré depuis, relu à chaque poignée de main. `devices.json` illisible :
     /// aucun appareil, et une ligne de journal (spec accès local § 9).
     private func localTLS() -> NWProtocolTLS.Options {
         let authority = authority
-        let keys: [String: Data]
+        let identities: [String]
         do {
-            keys = try authority.readLANKeys()
+            identities = try authority.tlsIdentities()
         } catch {
             log("devices.json illisible : aucun appareil sur le réseau local.")
-            keys = [:]
+            identities = []
         }
-        return NacelleTLS.server(identities: Array(keys.keys)) { authority.lanKey(for: $0) }
+        return NacelleTLS.server(identities: identities) { authority.tlsKey(for: $0) }
     }
 
     /// Relance les écoutes du réseau local, pour qu'elles connaissent le secret d'un nouvel appareil.
@@ -387,19 +389,24 @@ public final class WebSocketServer {
         }
         guard let client = clients[id] else { return }
         switch message {
-        // Transition (plan découverte et QR, tâche 1) : l'identifiant porte encore le code à 6 chiffres ;
-        // la tâche 2 remplace ce passage par l'appairage du QR code.
-        case let .pair(code, publicKey, name, _):
+        case .openPairing:
+            // Seul un programme du Mac (ptzd pair) ouvre un appairage (spec découverte et QR § 7.1).
+            guard client.trusted else {
+                send(.error(code: .notLocal, message: "Ouverture d'appairage depuis le Mac seulement."), to: id)
+                return
+            }
+            openPairing(id)
+        case let .pair(pairingID, publicKey, name, proof):
             guard !client.authenticated else {
                 send(.error(code: .badMessage, message: "Déjà authentifié."), to: id)
                 return
             }
-            // Le secret du canal chiffré ne doit jamais partir sur le réseau local (spec accès local § 14).
-            guard !client.local else {
-                send(.error(code: .pairingClosed, message: "Appairage par Tailscale seulement."), to: id)
+            // Le QR code ne sert que sur le réseau local, dans le canal TLS ouvert avec son secret.
+            guard client.local else {
+                send(.error(code: .notLocal, message: "Appairage par QR code sur le réseau local seulement."), to: id)
                 return
             }
-            pair(id, code: code, publicKey: publicKey, name: name)
+            pair(id, pairingID: pairingID, publicKey: publicKey, name: name, proof: proof)
         case let .auth(deviceID, signature):
             guard !client.authenticated else { return }
             verify(id, deviceID: deviceID, signature: signature)
@@ -420,23 +427,59 @@ public final class WebSocketServer {
         }
     }
 
-    /// Code d'appairage : un code faux laisse la connexion ouverte pour un nouvel essai.
-    private func pair(_ id: ClientID, code: String, publicKey: Data, name: String) {
-        switch authority.pair(code: code, publicKey: publicKey, name: name) {
+    /// Ouvre un appairage, l'annonce aux écoutes du réseau local et renvoie de quoi faire le QR code.
+    private func openPairing(_ id: ClientID) {
+        let opened = authority.pairing.open()
+        expiry?.cancel()
+        expiry = scheduler.schedule(after: PairingWindow.lifetime) { [weak self] in
+            self?.pairingExpired(opened.pairingID)
+        }
+        log("Appairage ouvert (\(opened.pairingID)), valable \(Int(PairingWindow.lifetime / 60)) min.")
+        let invitation = PairingInvitation(
+            pairingID: opened.pairingID, secret: opened.secret, expiresAt: opened.expiresAt,
+            hosts: (localListeners?.addresses ?? []) + localHosts.sorted(), port: Int(port)
+        )
+        send(.pairingOpened(invitation), to: id)
+        rebuildLocalListeners()
+    }
+
+    private func pairingExpired(_ pairingID: String) {
+        expiry = nil
+        guard authority.pairing.current?.pairingID == pairingID else { return }
+        authority.pairing.close(pairingID)
+        log("Appairage \(pairingID) expiré.")
+        rebuildLocalListeners()
+    }
+
+    /// Preuve du QR code sur le défi de la connexion : une preuve fausse laisse la connexion ouverte.
+    private func pair(_ id: ClientID, pairingID: String, publicKey: Data, name: String, proof: Data) {
+        guard let nonce = clients[id]?.nonce else { return }
+        let wasOpen = authority.pairing.current?.pairingID == pairingID
+        switch authority.pair(pairingID: pairingID, publicKey: publicKey, name: name, proof: proof, nonce: nonce) {
         case let .paired(deviceID, lanKey):
-            log("Appareil appairé : \(deviceID.prefix(8)) (\(name)).")
+            expiry?.cancel()
+            expiry = nil
+            log("Appareil appairé : \(deviceID.prefix(8)) (\(Self.logName(name))).")
             send(.paired(deviceID: deviceID, lanKey: lanKey), to: id)
             rebuildLocalListeners()
         case .badCode:
-            log("Client \(id) : code d'appairage faux (\(endpoint(id))).")
-            send(.error(code: .badCode, message: "Code d'appairage faux."), to: id)
+            log("Appairage \(Self.logID(pairingID)) : preuve fausse (\(clients[id]?.address ?? "?")).")
+            send(.error(code: .badCode, message: "QR code refusé."), to: id)
+            if wasOpen, authority.pairing.current == nil {
+                rebuildLocalListeners()
+            }
         case .closed:
-            send(.error(code: .pairingClosed, message: "Aucun appairage en cours : lancer ptzd pair sur le Mac."), to: id)
+            send(.error(code: .pairingClosed, message: "QR code expiré ou déjà utilisé : relancer ptzd pair."), to: id)
         case .invalidKey:
             send(.error(code: .badMessage, message: "Clé publique illisible."), to: id)
         }
     }
 
+    /// Un nom d'appareil n'entre dans le journal que sans caractère de contrôle, 40 caractères au plus.
+    nonisolated static func logName(_ name: String) -> String {
+        String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(40))
+    }
+
     /// Réponse au défi. Le défi ne sert qu'une fois ; un échec ferme la connexion.
     private func verify(_ id: ClientID, deviceID: String, signature: Data) {
         guard let nonce = clients[id]?.nonce else { return }
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : tout passe (Mac : 148 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add mac/ptzd/Sources/PTZAuth/AuthCommand.swift \
    mac/ptzd/Sources/PTZAuth/DeviceAuthority.swift \
    mac/ptzd/Sources/PTZAuth/PairingWindow.swift \
    mac/ptzd/Sources/PTZServer/LocalNetworkListeners.swift \
    mac/ptzd/Sources/PTZServer/WebSocketServer.swift \
    mac/ptzd/Tests/PTZAuthTests/AuthCommandTests.swift \
    mac/ptzd/Tests/PTZAuthTests/DeviceAuthorityTests.swift \
    mac/ptzd/Tests/PTZAuthTests/PairingWindowTests.swift \
    mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
ptzd : appairage par QR code sur le réseau local

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés à l'étape 1 ou 3 sont déjà indexés par `git rm`.

### Tâche 3 : `ptzd pair` : QR code dans le Terminal

**But :** `ptzd pair` demande un appairage au service par 127.0.0.1 (WebSocket, 5 s au plus) et affiche le QR code en demi-blocs noir sur blanc, l'URL et l'heure d'expiration (spec découverte et QR § 7.2).

**Fichiers :**
- Créer : `mac/ptzd/Sources/PTZServer/PairCommand.swift`
- Créer : `mac/ptzd/Sources/PTZServer/QRCodeText.swift`
- Modifier : `mac/ptzd/Sources/ptzd/PTZDaemon.swift`
- Créer : `mac/ptzd/Tests/PTZServerTests/QRCodeTextTests.swift`
- Modifier : `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift`

**Interfaces :**
- Consomme : `openPairing` et `pairingOpened` (tâches 1 et 2), `PairingLink`.
- Produit : `QRCodeText.modules(for:) -> [[Bool]]?` (marge blanche de 2 modules) et `QRCodeText.render(_:) -> String` ; `PairCommand.run(port:timeout:) async -> (status: Int32, output: String)`.
- Sorties : service absent, « ptzd ne répond pas : le service est-il lancé ? » ; refus, « ptzd refuse l'appairage : <message> » ; aucune adresse locale, « Aucune adresse sur le réseau local : relier le Mac au Wi-Fi ou à l'Ethernet, puis relancer ptzd pair. » ; code de sortie 1 dans ces trois cas, 2 pour un argument en trop.
- Fait vérifié : le texte produit, redessiné en image, est relu par Vision (test).

- [ ] **Étape 1 : Écrire les tests**

Créer `mac/ptzd/Tests/PTZServerTests/QRCodeTextTests.swift` :

```swift
import CoreGraphics
import Foundation
import Testing
import Vision
@testable import PTZServer

@Suite("QR code dans le Terminal")
struct QRCodeTextTests {
    let url = "nacelle://pair?v=1&id=1a2b3c4d&k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&h=192.0.2.30,192.0.2.31&p=1985"

    /// Motif de repérage de 7 modules dont le coin haut gauche est en (ligne, colonne).
    private func isFinder(_ modules: [[Bool]], _ row: Int, _ column: Int) -> Bool {
        (0..<7).allSatisfy { i in
            (0..<7).allSatisfy { j in
                let dark = i == 0 || i == 6 || j == 0 || j == 6 || ((2...4).contains(i) && (2...4).contains(j))
                return modules[row + i][column + j] == dark
            }
        }
    }

    @Test("Modules : carré, marge blanche de 2, repères en haut à gauche, en haut à droite et en bas à gauche")
    func modules() throws {
        let modules = try #require(QRCodeText.modules(for: url))
        let size = modules.count
        let margin = QRCodeText.margin
        #expect(modules.allSatisfy { $0.count == size })
        #expect((size - 2 * margin - 21) % 4 == 0)
        #expect(modules.prefix(margin).allSatisfy { $0.allSatisfy { !$0 } })
        #expect(modules.suffix(margin).allSatisfy { $0.allSatisfy { !$0 } })
        #expect(modules.allSatisfy { !$0.prefix(margin).contains(true) && !$0.suffix(margin).contains(true) })
        let far = size - margin - 7
        #expect(isFinder(modules, margin, margin))
        #expect(isFinder(modules, margin, far))
        #expect(isFinder(modules, far, margin))
        #expect(!isFinder(modules, far, far))
    }

    @Test("Texte : demi-blocs noir sur blanc, une ligne pour deux rangées ; relu par Vision, il redonne l'URL")
    func readable() throws {
        let modules = try #require(QRCodeText.modules(for: url))
        let lines = QRCodeText.render(modules).components(separatedBy: "\n")
        #expect(lines.count == (modules.count + 1) / 2)
        #expect(lines.allSatisfy { $0.hasPrefix("\u{1B}[30;107m") && $0.hasSuffix("\u{1B}[0m") })
        #expect(try decode(lines) == url)
    }

    /// Redessine le texte en image (10 pixels par module) et la fait lire par Vision.
    private func decode(_ lines: [String]) throws -> String? {
        var rows: [[Bool]] = []
        for line in lines {
            let body = line.dropFirst("\u{1B}[30;107m".count).dropLast("\u{1B}[0m".count)
            rows.append(body.map { $0 == "█" || $0 == "▀" })
            rows.append(body.map { $0 == "█" || $0 == "▄" })
        }
        let scale = 10
        let width = rows[0].count * scale
        let height = rows.count * scale
        var pixels = [UInt8](repeating: 255, count: width * height)
        for (y, row) in rows.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        pixels[(y * scale + dy) * width + x * scale + dx] = 0
                    }
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first?.payloadStringValue
    }
}
```

Modifier `mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift b/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
index b64e310..15229e2 100644
--- a/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
+++ b/mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
@@ -578,6 +578,37 @@ struct WebSocketServerTests {
         try await waitUntil { rebuilt.port != nil }
     }
 
+    @Test("ptzd pair : QR code et URL de l'appairage ouvert par 127.0.0.1")
+    func pairCommand() async throws {
+        let (server, ports) = await startServer(on: ["127.0.0.1", "::1"], localHosts: ["::1"])
+        let result = await PairCommand.run(port: Int(ports["127.0.0.1"]!))
+        let current = try #require(authority.pairing.current)
+        let link = PairingLink(pairingID: current.pairingID, secret: current.secret, hosts: ["::1"], port: 0)
+        #expect(result.status == 0)
+        #expect(result.output.contains("\u{1B}[30;107m"))
+        #expect(result.output.contains(link.url.absoluteString))
+        #expect(result.output.contains("Dans PTZBot, touche « Scanner le QR code » et vise ce code."))
+        withExtendedLifetime(server) {}
+    }
+
+    @Test("ptzd pair : refus du service affiché, sans adresse locale, ou service absent : code 1")
+    func pairCommandFailures() async throws {
+        let (untrusted, refusing) = await startServer(trustLoopback: false)
+        let refused = await PairCommand.run(port: Int(refusing["127.0.0.1"]!))
+        #expect(refused.status == 1)
+        #expect(refused.output == "ptzd refuse l'appairage : Ouverture d'appairage depuis le Mac seulement.")
+        withExtendedLifetime(untrusted) {}
+
+        let (lonely, ports) = await startServer()
+        let noAddress = await PairCommand.run(port: Int(ports["127.0.0.1"]!))
+        #expect(noAddress.status == 1)
+        #expect(noAddress.output == "Aucune adresse sur le réseau local : relier le Mac au Wi-Fi ou à l'Ethernet, puis relancer ptzd pair.")
+        withExtendedLifetime(lonely) {}
+
+        let absent = await PairCommand.run(port: 1, timeout: 2)
+        #expect(absent == (1, "ptzd ne répond pas : le service est-il lancé ?"))
+    }
+
     @Test("Journal : nom d'appareil sans caractère de contrôle, 40 caractères au plus")
     func logName() {
         #expect(WebSocketServer.logName("iPhone\n\u{1B}[2Jde test") == "iPhone[2Jde test")
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : échec — la compilation des tests échoue : `QRCodeText` et `PairCommand` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Créer `mac/ptzd/Sources/PTZServer/PairCommand.swift` :

```swift
import Foundation
import NacelleProtocol

/// `ptzd pair` (spec découverte et QR § 7.2) : demande un appairage au service par 127.0.0.1,
/// puis affiche le QR code, l'URL en texte et l'heure d'expiration.
public enum PairCommand {
    public static let timeout: TimeInterval = 5

    enum Outcome: Sendable {
        case opened(PairingInvitation)
        case refused(String)
        case noReply
    }

    /// Code de sortie et texte à afficher.
    public static func run(port: Int, timeout: TimeInterval = timeout) async -> (status: Int32, output: String) {
        switch await openPairing(port: port, timeout: timeout) {
        case .noReply:
            return (1, "ptzd ne répond pas : le service est-il lancé ?")
        case let .refused(message):
            return (1, "ptzd refuse l'appairage : \(message)")
        case let .opened(invitation):
            guard !invitation.hosts.isEmpty else {
                return (1, "Aucune adresse sur le réseau local : relier le Mac au Wi-Fi ou à l'Ethernet, puis relancer ptzd pair.")
            }
            let url = PairingLink(invitation).url.absoluteString
            guard let modules = QRCodeText.modules(for: url) else {
                return (1, "QR code impossible à produire pour \(url)")
            }
            let time = DateFormatter()
            time.dateFormat = "HH:mm:ss"
            return (0, """
            \(QRCodeText.render(modules))

            Dans PTZBot, touche « Scanner le QR code » et vise ce code.
            \(url)
            Valable jusqu'à \(time.string(from: invitation.expiresAt)), une seule fois. Ne l'affiche que le temps du scan.
            """)
        }
    }

    /// `openPairing` par 127.0.0.1, puis attente de `pairingOpened` ou d'une erreur, `timeout` secondes au plus.
    static func openPairing(port: Int, timeout: TimeInterval) async -> Outcome {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask { await exchange(task) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .noReply
            }
            let first = await group.next() ?? .noReply
            // Débloque l'attente de réception restée en cours.
            task.cancel(with: .normalClosure, reason: nil)
            group.cancelAll()
            return first
        }
    }

    private static func exchange(_ task: URLSessionWebSocketTask) async -> Outcome {
        do {
            try await task.send(.string(try NacelleCodec.encode(.openPairing)))
            while true {
                guard case let .string(text) = try await task.receive() else { continue }
                switch try NacelleCodec.decodeServer(text) {
                case let .pairingOpened(invitation):
                    return .opened(invitation)
                case let .error(_, message):
                    return .refused(message)
                default:
                    continue
                }
            }
        } catch {
            return .noReply
        }
    }
}
```

Créer `mac/ptzd/Sources/PTZServer/QRCodeText.swift` :

```swift
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// QR code pour le Terminal (spec découverte et QR § 7.2) : deux rangées de modules par ligne de caractères
/// demi-blocs, noir sur blanc imposé par des codes ANSI quel que soit le thème du Terminal.
public enum QRCodeText {
    /// Marge blanche autour du code, en modules.
    public static let margin = 2

    /// Modules du QR code (true : noir), marge comprise ; nil si le texte ne tient pas dans un QR code.
    public static func modules(for text: String) -> [[Bool]]? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        // CoreImage entoure le code d'un module blanc, retiré ici pour poser notre marge.
        let size = Int(image.extent.width)
        var pixels = [UInt8](repeating: 0, count: size * size)
        CIContext().render(image, toBitmap: &pixels, rowBytes: size, bounds: image.extent, format: .L8, colorSpace: nil)
        let inner = (1..<(size - 1)).map { y in (1..<(size - 1)).map { x in pixels[y * size + x] < 128 } }
        let width = inner.count + 2 * margin
        let blank = [[Bool]](repeating: [Bool](repeating: false, count: width), count: margin)
        let padding = [Bool](repeating: false, count: margin)
        return blank + inner.map { padding + $0 + padding } + blank
    }

    /// Le texte à afficher : une ligne pour deux rangées de modules.
    public static func render(_ modules: [[Bool]]) -> String {
        var rows = modules
        if rows.count % 2 == 1, let first = rows.first {
            rows.append([Bool](repeating: false, count: first.count))
        }
        return stride(from: 0, to: rows.count, by: 2).map { y in
            let line = zip(rows[y], rows[y + 1]).map { top, bottom in
                switch (top, bottom) {
                case (true, true): "█"
                case (true, false): "▀"
                case (false, true): "▄"
                case (false, false): " "
                }
            }.joined()
            return "\u{1B}[30;107m" + line + "\u{1B}[0m"
        }.joined(separator: "\n")
    }
}
```

Modifier `mac/ptzd/Sources/ptzd/PTZDaemon.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/mac/ptzd/Sources/ptzd/PTZDaemon.swift b/mac/ptzd/Sources/ptzd/PTZDaemon.swift
index 94a6c1d..d9f7729 100644
--- a/mac/ptzd/Sources/ptzd/PTZDaemon.swift
+++ b/mac/ptzd/Sources/ptzd/PTZDaemon.swift
@@ -51,6 +51,18 @@ struct PTZDaemon {
             log("config.json absent ou invalide : \(error)")
             exit(78)
         }
+        if arguments.first == "pair" {
+            guard arguments.count == 1 else {
+                print("usage : ptzd pair    affiche le QR code d'un appairage valable 5 min")
+                exit(2)
+            }
+            Task {
+                let result = await PairCommand.run(port: config.port)
+                print(result.output)
+                exit(result.status)
+            }
+            dispatchMain()
+        }
 
         let scheduler = DispatchScheduler()
         let camera = UVCCamera(log: log)
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd mac/ptzd && swift test 2>&1 | grep -E 'error:|warning:|Test run with|✘')
```

Attendu : tout passe (Mac : 152 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add mac/ptzd/Sources/PTZServer/PairCommand.swift \
    mac/ptzd/Sources/PTZServer/QRCodeText.swift \
    mac/ptzd/Sources/ptzd/PTZDaemon.swift \
    mac/ptzd/Tests/PTZServerTests/QRCodeTextTests.swift \
    mac/ptzd/Tests/PTZServerTests/WebSocketServerTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
ptzd pair : QR code d'appairage dans le Terminal

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés à l'étape 1 ou 3 sont déjà indexés par `git rm`.

### Tâche 4 : App : appairage par QR code, adresse retenue, TLS selon l'adresse

**But :** Le client essaie l'adresse du champ (TLS pour une IPv4 privée ou un nom en `.local`, WebSocket simple sinon) et Bonjour ; un QR code scanné remplace ces candidates par ses adresses et Bonjour, en TLS avec le secret du QR, et envoie la preuve ; l'adresse du Mac qui a appairé l'iPhone va dans le champ s'il est vide. Le code à 6 chiffres et « active Tailscale » disparaissent (spec découverte et QR § 8.2 à § 8.4).

**Fichiers :**
- Modifier : `ios/Nacelle/App/AppModel.swift`
- Modifier : `ios/Nacelle/Control/ControlScreen.swift`
- Modifier : `ios/Nacelle/Control/StatusBanner.swift`
- Modifier : `ios/Nacelle/PTZ/LocalNetwork.swift`
- Modifier : `ios/Nacelle/PTZ/PTZClient.swift`
- Modifier : `ios/Nacelle/PTZ/WebSocketTransport.swift`
- Modifier : `ios/Nacelle/Settings/ConnectionSettings.swift`
- Modifier : `ios/Nacelle/Settings/SettingsView.swift`
- Modifier : `ios/NacelleTests/AppModelTests.swift`
- Modifier : `ios/NacelleTests/ConnectionSettingsTests.swift`
- Modifier : `ios/NacelleTests/FakeTransport.swift`
- Modifier : `ios/NacelleTests/PTZClientTests.swift`
- Modifier : `ios/NacelleTests/StatusBannerTests.swift`

**Interfaces :**
- Consomme : tâche 1 (`PairingLink`, `pairingProof`, `pairingIdentity`).
- Produit :
  - `WebSocketEndpoint.tls(NWEndpoint, LANCredentials)` (remplace `.service`) ; `WebSocketTransport.remoteAddress: String?` ; `NWWebSocketTransport.ipv4(_:) -> String?` ;
  - `ConnectionSettings.Route` (`.local`, `.tailscale`), `ConnectionSettings.route(for:)`, `isValid` (remplace `isComplete` ; champ vide permis), `fallbackHost`, `endpoint(credentials:) -> WebSocketEndpoint?` ;
  - `PTZClient.start(settings:)` (remplace `start(url:)`), `pair(with: PairingLink)` (remplace `pair(code:)`), `update(_:)`, `onAddressLearned` ; `AuthIssue` sans `needsTailscale` ;
  - `AppModel.pair(with:)` ; `SettingsView` sans le champ du code.
- Textes : « iPhone non appairé : scanne le QR code de ptzd pair », « QR code refusé : relance ptzd pair ».

- [ ] **Étape 1 : Écrire les tests**

Modifier `ios/NacelleTests/AppModelTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/NacelleTests/AppModelTests.swift b/ios/NacelleTests/AppModelTests.swift
index acae631..2dd18ad 100644
--- a/ios/NacelleTests/AppModelTests.swift
+++ b/ios/NacelleTests/AppModelTests.swift
@@ -34,15 +34,47 @@ struct AppModelTests {
         transports.all.flatMap(\.opened).compactMap { if case let .url(url) = $0 { url.port } else { nil } }
     }
 
-    @Test("Premier lancement : les réglages enregistrés au premier plan connectent tout de suite")
-    func firstLaunch() {
+    @Test("Champ vide : connexion lancée quand même (Bonjour) ; une adresse saisie reconnecte tout de suite")
+    func emptyField() {
         let model = makeModel()
         model.activate()
+        #expect(model.isActive)
         #expect(openedPorts.isEmpty)
-        #expect(model.bannerText == nil)
+        #expect(model.bannerText == "Connexion…")
         model.settings = complete
         #expect(openedPorts.count == 1)
-        #expect(model.isActive)
+        model.deactivate()
+    }
+
+    @Test("Appairage par QR : l'adresse du Mac va dans le champ vide, sans reconnexion")
+    func addressRemembered() throws {
+        let model = makeModel()
+        model.activate()
+        let link = try #require(PairingLink(string: "nacelle://pair?v=1&id=1a2b3c4d&k=BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU&h=192.0.2.30&p=1985"))
+        model.pair(with: link)
+        let transport = try #require(transports.last)
+        transport.remoteAddress = "192.0.2.30"
+        transport.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
+        transport.emit(.message(try NacelleCodec.encode(ServerMessage.paired(deviceID: "x", lanKey: Data(count: 32)))))
+        #expect(model.settings.host == "192.0.2.30")
+        #expect(SettingsStore(defaults: defaults).load().host == "192.0.2.30")
+        #expect(transport.closeCount == 0)
+        #expect(transports.all.count == 1)
+        model.deactivate()
+    }
+
+    @Test("Appairage par QR : un champ déjà rempli n'est pas modifié")
+    func addressKept() throws {
+        SettingsStore(defaults: defaults).save(complete)
+        let model = makeModel()
+        model.activate()
+        let link = try #require(PairingLink(string: "nacelle://pair?v=1&id=1a2b3c4d&k=BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU&h=192.0.2.30&p=1985"))
+        model.pair(with: link)
+        let transport = try #require(transports.last)
+        transport.remoteAddress = "192.0.2.30"
+        transport.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
+        transport.emit(.message(try NacelleCodec.encode(ServerMessage.paired(deviceID: "x", lanKey: Data(count: 32)))))
+        #expect(model.settings == complete)
         model.deactivate()
     }
 
PATCH
```

Remplacer tout le contenu de `ios/NacelleTests/ConnectionSettingsTests.swift` par :

```swift
import Foundation
import Network
import Testing
@testable import Nacelle

@Suite("Réglages de connexion")
struct ConnectionSettingsTests {
    let credentials = LANCredentials(identity: "abcd", key: Data(repeating: 9, count: 32))

    @Test("Nom Tailscale : WebSocket simple vers ws://<hôte>:<port>, sans espaces")
    func tailscaleEndpoint() {
        let settings = ConnectionSettings(host: " mac.exemple.ts.net ", ptzdPort: 1985)
        #expect(settings.endpoint(credentials: nil) == .url(URL(string: "ws://mac.exemple.ts.net:1985")!))
        #expect(settings.endpoint(credentials: credentials) == .url(URL(string: "ws://mac.exemple.ts.net:1985")!))
    }

    @Test("Adresse locale : TLS avec les secrets de l'iPhone, rien sans eux")
    func localEndpoint() {
        let settings = ConnectionSettings(host: "192.168.0.10", ptzdPort: 1985)
        #expect(settings.endpoint(credentials: credentials) == .tls(.hostPort(host: "192.168.0.10", port: 1985), credentials))
        #expect(settings.endpoint(credentials: nil) == nil)
    }

    @Test(
        "Route : IPv4 privée ou nom en .local, réseau local ; le reste, Tailscale",
        arguments: [
            ("10.0.0.5", ConnectionSettings.Route.local),
            ("172.16.0.1", .local),
            ("172.31.255.1", .local),
            ("192.168.0.10", .local),
            ("Mac-mini.LOCAL", .local),
            ("172.32.0.1", .tailscale),
            ("100.64.0.1", .tailscale),
            ("192.0.2.30", .tailscale),
            ("192.168.0.300", .tailscale),
            ("192.168.0", .tailscale),
            ("mac.exemple.ts.net", .tailscale),
        ]
    )
    func routes(_ host: String, _ route: ConnectionSettings.Route) {
        #expect(ConnectionSettings.route(for: host) == route)
    }

    @Test("Champ vide : valide, aucune adresse ; port hors bornes : invalide")
    func validity() {
        #expect(ConnectionSettings().isValid)
        #expect(ConnectionSettings().fallbackHost == nil)
        #expect(ConnectionSettings().endpoint(credentials: credentials) == nil)
        #expect(!ConnectionSettings(host: "mac", ptzdPort: 0).isValid)
        #expect(!ConnectionSettings(host: "mac", ptzdPort: 70000).isValid)
        #expect(ConnectionSettings(host: "mac").isValid)
    }

    @Test("Anciens réglages (port go2rtc et flux) relus sans erreur")
    func legacySettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "nacelle-tests-\(UUID().uuidString)"))
        let legacy = #"{"host":"mac.exemple.ts.net","go2rtcPort":1984,"streamName":"obsbot","ptzdPort":1999}"#
        defaults.set(Data(legacy.utf8), forKey: SettingsStore.key)
        #expect(SettingsStore(defaults: defaults).load() == ConnectionSettings(host: "mac.exemple.ts.net", ptzdPort: 1999))
    }

    @Test("Hôte mal saisi : schéma, port, barre oblique ou espace refusés, sans adresse")
    func invalidHost() {
        for host in [
            "http://mac.exemple.ts.net",
            "mac.exemple.ts.net:1984",
            "mac.exemple.ts.net/",
            "mac.exemple.ts.net 1985",
        ] {
            let settings = ConnectionSettings(host: host)
            #expect(!settings.isValid, "\(host)")
            #expect(settings.endpoint(credentials: credentials) == nil, "\(host)")
        }
        #expect(ConnectionSettings(host: "\tmac.exemple.ts.net\n").fallbackHost == "mac.exemple.ts.net")
        #expect(ConnectionSettings(host: "127.0.0.1").isValid)
    }

    @Test("Port saisi au clavier : chiffres seuls, sinon 0 (donc invalide)")
    func portFromText() {
        #expect(ConnectionSettings.port(from: "1999") == 1999)
        #expect(ConnectionSettings.port(from: " 1985 ") == 1985)
        #expect(ConnectionSettings.port(from: "") == 0)
        #expect(ConnectionSettings.port(from: "19a5") == 0)
        #expect(ConnectionSettings.port(from: "99999999999999999999999") == 0)
        #expect(!ConnectionSettings(host: "mac", ptzdPort: ConnectionSettings.port(from: "")).isValid)
    }

    @Test("Enregistrés puis relus")
    func roundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "nacelle-tests-\(UUID().uuidString)"))
        let store = SettingsStore(defaults: defaults)
        #expect(store.load() == ConnectionSettings())
        let settings = ConnectionSettings(host: "mac.exemple.ts.net", ptzdPort: 1999)
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test("Adresse IPv4 d'un point d'arrivée résolu ; rien pour IPv6 ou un nom")
    func resolvedAddress() {
        #expect(NWWebSocketTransport.ipv4(.hostPort(host: .ipv4(IPv4Address("192.0.2.30")!), port: 1985)) == "192.0.2.30")
        #expect(NWWebSocketTransport.ipv4(.hostPort(host: .ipv6(IPv6Address("::1")!), port: 1985)) == nil)
        #expect(NWWebSocketTransport.ipv4(.hostPort(host: "mac-mini.local", port: 1985)) == nil)
    }
}
```

Modifier `ios/NacelleTests/FakeTransport.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/NacelleTests/FakeTransport.swift b/ios/NacelleTests/FakeTransport.swift
index ea9788f..867cd9d 100644
--- a/ios/NacelleTests/FakeTransport.swift
+++ b/ios/NacelleTests/FakeTransport.swift
@@ -7,6 +7,8 @@ import Network
 @MainActor
 final class FakeTransport: WebSocketTransport {
     var onEvent: ((TransportEvent) -> Void)?
+    /// Adresse du Mac que le test fait connaître.
+    var remoteAddress: String?
     private(set) var opened: [WebSocketEndpoint] = []
     private(set) var sent: [String] = []
     private(set) var closeCount = 0
@@ -48,10 +50,10 @@ final class FakeTransports {
         all.last { $0.opened == [endpoint] }
     }
 
-    /// Le dernier transport ouvert vers un service du réseau local.
+    /// Le dernier transport ouvert vers un service Bonjour.
     var local: FakeTransport? {
         all.last { transport in
-            transport.opened.contains { if case .service = $0 { true } else { false } }
+            transport.opened.contains { if case .tls(.service, _) = $0 { true } else { false } }
         }
     }
 }
PATCH
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
    /// Le champ porte le nom Tailscale : la connexion part en WebSocket simple vers `url`.
    let settings = ConnectionSettings(host: "mac.exemple.ts.net")
    let service = NWEndpoint.service(name: "PTZBot sur Mac", type: "_nacelle._tcp", domain: "local.", interface: nil)
    /// QR code de `ptzd pair`.
    let link = PairingLink(pairingID: "1a2b3c4d", secret: Data(repeating: 5, count: 32), hosts: ["192.0.2.30", "192.0.2.31"], port: 1985)
    let nonce = Data(repeating: 7, count: 32)
    let lanKey = Data(repeating: 9, count: 32)

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
        keys.storedLANKey = lanKey
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

    /// Identité TLS et secret du QR code.
    private var pairingCredentials: LANCredentials {
        LANCredentials(identity: "pair-1a2b3c4d", key: link.secret)
    }

    /// La connexion vers une adresse du QR code.
    private func qr(_ host: String) -> FakeTransport? {
        transports.to(.tls(.hostPort(host: NWEndpoint.Host(host), port: 1985), pairingCredentials))
    }

    /// Ouverture, défi, signature, authentification, par Tailscale.
    private func connect() throws {
        client.start(settings: settings)
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
        client.start(settings: settings)
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

    @Test("Sans clé : « non appairé » sans rien ouvrir, plus de reconnexion")
    func noKey() throws {
        keys.key = nil
        client.start(settings: settings)
        #expect(client.authIssue == .unpaired)
        #expect(client.link == .idle)
        #expect(!browser.isRunning)
        scheduler.advance(by: 30)
        #expect(transports.all.isEmpty)
    }

    @Test("ptzd ne connaît pas l'iPhone : « non appairé », appairage oublié")
    func unpairedByServer() throws {
        record.isPaired = true
        try connect()
        client.stop()
        client.start(settings: settings)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .unpaired, message: "x"), on: tailscale)
        #expect(client.authIssue == .unpaired)
        #expect(!client.isPaired)
        #expect(!record.isPaired)
        #expect(client.link == .idle)
    }

    @Test("Signature refusée : « refusé », plus de reconnexion")
    func rejected() throws {
        client.start(settings: settings)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .authFailed, message: "x"), on: tailscale)
        #expect(client.authIssue == .rejected)
        tailscale.emit(.closed)
        scheduler.advance(by: 30)
        #expect(transports.all.count == 1)
    }

    // MARK: - Appairage par QR code

    @Test("QR code : chaque adresse du QR et Bonjour, en TLS avec le secret du QR ; pas l'adresse du champ")
    func pairingCandidates() throws {
        keys.key = nil
        keys.storedLANKey = nil
        client.start(settings: settings)
        client.pair(with: link)
        #expect(qr("192.0.2.30") != nil)
        #expect(qr("192.0.2.31") != nil)
        #expect(transports.to(.url(url)) == nil)
        #expect(browser.isRunning)
        browser.find(service)
        #expect(transports.local?.opened == [.tls(service, pairingCredentials)])
        #expect(transports.all.count == 3)
    }

    @Test("QR code : clé créée, preuve sur le défi ; paired : secret rangé, adresse retenue, auth sur le même défi")
    func pairing() throws {
        keys.key = nil
        keys.storedLANKey = nil
        var learned: [String] = []
        client.onAddressLearned = { learned.append($0) }
        client.start(settings: settings)
        client.pair(with: link)
        let first = try #require(qr("192.0.2.30"))
        first.remoteAddress = "192.0.2.30"
        first.emit(.opened)
        try emit(.challenge(nonce: nonce), on: first)
        let key = try #require(keys.key)
        let proof = NacelleAuth.pairingProof(secret: link.secret, nonce: nonce, publicKeyX963: key.publicKeyX963)
        #expect(decoded(first) == [.pair(pairingID: "1a2b3c4d", publicKey: key.publicKeyX963, name: "iPhone", proof: proof)])
        let newKey = Data(repeating: 3, count: 32)
        try emit(.paired(deviceID: key.deviceID, lanKey: newKey), on: first)
        #expect(keys.storedLANKey == newKey)
        #expect(client.isPaired)
        #expect(learned == ["192.0.2.30"])
        guard case let .auth(deviceID, signature) = decoded(first).last else {
            Issue.record("auth attendu après paired")
            return
        }
        #expect(NacelleAuth.verify(signature: signature, nonce: nonce, deviceID: deviceID, publicKeyX963: key.publicKeyX963))
        try emit(.authenticated, on: first)
        #expect(client.link == .connected)
        #expect(client.authIssue == nil)
        // Le QR ne sert qu'une fois : la connexion suivante revient au champ et à Bonjour.
        client.stop()
        let before = transports.all.count
        client.start(settings: settings)
        #expect(transports.all.count == before + 1)
        #expect(transports.last?.opened == [.url(url)])
    }

    @Test("QR code, deux connexions au défi : une seule envoie la preuve, l'autre s'authentifie après paired")
    func pairingWithTwoPaths() throws {
        keys.key = nil
        var learned: [String] = []
        client.onAddressLearned = { learned.append($0) }
        client.start(settings: settings)
        client.pair(with: link)
        browser.find(service)
        let local = try #require(transports.local)
        let first = try #require(qr("192.0.2.30"))
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.challenge(nonce: nonce), on: first)
        #expect(decoded(local).count == 1)
        #expect(decoded(first).isEmpty)
        let key = try #require(keys.key)
        // Un « paired » d'une connexion qui n'a pas envoyé la preuve ne compte pas.
        try emit(.paired(deviceID: key.deviceID, lanKey: lanKey), on: first)
        #expect(decoded(first).isEmpty)
        try emit(.paired(deviceID: key.deviceID, lanKey: lanKey), on: local)
        #expect(decoded(local).contains { if case .auth = $0 { true } else { false } })
        #expect(decoded(first).contains { if case .auth = $0 { true } else { false } })
        // Service Bonjour sans adresse résolue : rien à retenir.
        #expect(learned.isEmpty)
    }

    @Test("QR code refusé par ptzd : « QR code refusé », plus de reconnexion, QR oublié", arguments: [ErrorCode.badCode, .pairingClosed, .notLocal])
    func pairingRefused(_ code: ErrorCode) throws {
        keys.key = nil
        client.start(settings: settings)
        client.pair(with: link)
        let first = try #require(qr("192.0.2.30"))
        try emit(.challenge(nonce: nonce), on: first)
        try emit(.error(code: code, message: "x"), on: first)
        #expect(client.authIssue == .badCode)
        #expect(client.link == .idle)
        #expect(first.closeCount >= 1)
        let opened = transports.all.count
        scheduler.advance(by: 30)
        #expect(transports.all.count == opened)
        client.stop()
        client.start(settings: settings)
        #expect(transports.last?.opened == [.url(url)])
    }

    @Test("Aucun Mac ne répond avec le QR (secret refusé en TLS, Mac injoignable) : « QR code refusé », sans reconnexion")
    func pairingUnanswered() throws {
        keys.key = nil
        client.start(settings: settings)
        client.pair(with: link)
        try #require(qr("192.0.2.30")).emit(.closed)
        try #require(qr("192.0.2.31")).emit(.closed)
        #expect(client.link == .connecting)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.authIssue == .badCode)
        #expect(client.link == .idle)
        let opened = transports.all.count
        scheduler.advance(by: 30)
        #expect(transports.all.count == opened)
    }

    @Test("Oublier l'appairage : clé et secret supprimés, puis « non appairé »")
    func forget() throws {
        try connect()
        client.forgetPairing()
        #expect(keys.key == nil)
        #expect(keys.storedLANKey == nil)
        #expect(!client.isPaired)
        #expect(client.authIssue == .unpaired)
    }

    // MARK: - Adresse du champ

    @Test("Adresse locale dans le champ : jointe en TLS avec le secret de l'iPhone, en plus de Bonjour")
    func localFallback() throws {
        client.start(settings: ConnectionSettings(host: "mac-mini.local"))
        let key = try #require(keys.key)
        let credentials = LANCredentials(identity: key.deviceID, key: lanKey)
        #expect(transports.all.map(\.opened) == [[.tls(.hostPort(host: "mac-mini.local", port: 1985), credentials)]])
        #expect(browser.isRunning)
    }

    @Test("Adresse locale sans secret du réseau local : rien à tenter, Mac injoignable")
    func localFallbackWithoutLANKey() {
        keys.storedLANKey = nil
        client.start(settings: ConnectionSettings(host: "mac-mini.local"))
        #expect(transports.all.isEmpty)
        #expect(!browser.isRunning)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.isUnreachable)
        #expect(client.link == .waitingToRetry)
    }

    @Test("Adresse retenue en cours de route : prise en compte à la tentative suivante, sans couper")
    func updateSettings() throws {
        client.start(settings: ConnectionSettings())
        #expect(transports.all.isEmpty)
        client.update(settings)
        #expect(client.link == .connecting)
        scheduler.advance(by: PTZClient.discoveryWindow)
        scheduler.advance(by: 1)
        #expect(transports.last?.opened == [.url(url)])
    }

    // MARK: - Choix du chemin

    @Test("Les deux chemins essayés ; le premier authentifié l'emporte, l'autre est fermé")
    func race() throws {
        client.start(settings: settings)
        #expect(browser.isRunning)
        browser.find(service)
        let local = try #require(transports.local)
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
        client.start(settings: settings)
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
        client.start(settings: settings)
        tailscale.emit(.closed)
        #expect(client.link == .connecting)
        #expect(!client.isUnreachable)
        browser.find(service)
        let local = try #require(transports.local)
        local.emit(.opened)
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.authenticated, on: local)
        #expect(client.link == .connected)
    }

    @Test("Un seul service local par tentative")
    func oneLocalCandidate() {
        client.start(settings: settings)
        browser.find(service)
        browser.find(.service(name: "PTZBot sur Mac", type: "_nacelle._tcp", domain: "local.", interface: nil))
        #expect(transports.all.count == 2)
    }

    @Test("Erreur « non appairé » d'un service local : seule sa connexion est fermée, Tailscale s'authentifie")
    func localErrorClosesOnlyLocal() throws {
        try connect()
        client.stop()
        client.start(settings: settings)
        browser.find(service)
        let local = try #require(transports.local)
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.error(code: .unpaired, message: "x"), on: local)
        #expect(local.closeCount >= 1)
        #expect(tailscale.closeCount == 0)
        #expect(client.isPaired)
        #expect(record.isPaired)
        #expect(client.link == .connecting)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        #expect(client.link == .connected)
        #expect(client.authIssue == nil)
        #expect(client.isPaired)
    }

    @Test("Erreur d'un service local seul : problème affiché, reconnexions espacées maintenues")
    func localErrorOnlyCandidate() throws {
        client.start(settings: settings)
        browser.find(service)
        let local = try #require(transports.local)
        tailscale.emit(.closed)
        try emit(.challenge(nonce: nonce), on: local)
        try emit(.error(code: .unpaired, message: "x"), on: local)
        #expect(client.authIssue == nil)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.authIssue == .unpaired)
        #expect(client.link == .waitingToRetry)
        let before = transports.all.count
        scheduler.advance(by: 1)
        #expect(transports.all.count == before + 1)
        #expect(client.link == .connecting)
        #expect(client.authIssue == nil)
    }

    @Test("« authenticated » d'une connexion qui n'a pas envoyé auth : fermée, Tailscale peut encore gagner")
    func unsolicitedAuthenticated() throws {
        client.start(settings: settings)
        browser.find(service)
        let local = try #require(transports.local)
        try emit(.authenticated, on: local)
        #expect(local.closeCount >= 1)
        #expect(client.link == .connecting)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.authenticated, on: tailscale)
        #expect(client.link == .connected)
        #expect(tailscale.closeCount == 0)
        #expect(commands(local).isEmpty)
    }

    @Test("Service local muet : fermé après 10 s, la tentative échoue et une nouvelle est planifiée")
    func silentLocalService() throws {
        client.start(settings: settings)
        browser.find(service)
        let local = try #require(transports.local)
        tailscale.emit(.closed)
        local.emit(.opened)
        try emit(.challenge(nonce: nonce), on: local)
        scheduler.advance(by: PTZClient.authTimeout - 0.01)
        #expect(local.closeCount == 0)
        #expect(client.link == .connecting)
        scheduler.advance(by: 0.01)
        #expect(local.closeCount >= 1)
        #expect(client.link == .waitingToRetry)
        let before = transports.all.count
        scheduler.advance(by: 1)
        #expect(transports.all.count == before + 1)
    }

    @Test("Le délai d'authentification est annulé quand la connexion gagne")
    func deadlineCancelledOnSuccess() throws {
        try connect()
        scheduler.advance(by: PTZClient.authTimeout * 2)
        #expect(client.link == .connected)
        #expect(tailscale.closeCount == 0)
    }

    @Test("Sans secret du réseau local : pas de recherche Bonjour, Tailscale seul")
    func noLocalPathWithoutLANKey() throws {
        keys.storedLANKey = nil
        client.start(settings: settings)
        #expect(browser.startCount == 0)
        browser.find(service)
        #expect(transports.local == nil)
    }

    @Test("Avec un secret : le service local est joint en TLS, identité = deviceID")
    func localPathUsesTLSCredentials() throws {
        client.start(settings: settings)
        #expect(browser.isRunning)
        browser.find(service)
        let key = try #require(keys.key)
        #expect(transports.local?.opened == [.tls(service, LANCredentials(identity: key.deviceID, key: lanKey))])
    }

    @Test("Secret du réseau local non enregistré (trousseau) : l'appairage reste valable, auth sur la même connexion")
    func lanKeySaveFailure() throws {
        keys.key = nil
        keys.storedLANKey = nil
        keys.saveLANKeyError = CocoaError(.fileWriteUnknown)
        client.start(settings: settings)
        client.pair(with: link)
        let first = try #require(qr("192.0.2.30"))
        try emit(.challenge(nonce: nonce), on: first)
        try emit(.paired(deviceID: try #require(keys.key).deviceID, lanKey: lanKey), on: first)
        #expect(client.isPaired)
        #expect(keys.storedLANKey == nil)
        try emit(.authenticated, on: first)
        #expect(client.link == .connected)
    }

    @Test("Problème qui arrête les reconnexions : conservé quand l'app relance une tentative")
    func blockingIssueKept() throws {
        client.start(settings: settings)
        try emit(.challenge(nonce: nonce), on: tailscale)
        try emit(.error(code: .authFailed, message: "x"), on: tailscale)
        #expect(client.authIssue == .rejected)
        client.start(settings: settings)
        #expect(client.authIssue == .rejected)
    }

    // MARK: - Reconnexion

    @Test("Échec des deux chemins : Mac injoignable, nouvel essai après 1, 2, 4 puis 8 s")
    func retryBackoff() {
        client.start(settings: settings)
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
        client.start(settings: settings)
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
        client.start(settings: settings)
        tailscale.emit(.closed)
        scheduler.advance(by: PTZClient.discoveryWindow)
        #expect(client.isUnreachable)
        client.stop()
        #expect(!client.isUnreachable)
        client.start(settings: settings)
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
        client.start(settings: settings)
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
        client.start(settings: settings)
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
        client.start(settings: settings)
        let waiting = Task { try await client.negotiate(offer: "a") }
        await settle()
        scheduler.advance(by: PTZClient.negotiationTimeout)
        await #expect(throws: PTZClient.NegotiationError.notConnected) { try await waiting.value }
        // Le délai d'authentification (10 s) a aussi fermé la connexion muette : nouvelle tentative.
        scheduler.advance(by: 1)

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

Modifier `ios/NacelleTests/StatusBannerTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/NacelleTests/StatusBannerTests.swift b/ios/NacelleTests/StatusBannerTests.swift
index c1806e4..3cc6fa6 100644
--- a/ios/NacelleTests/StatusBannerTests.swift
+++ b/ios/NacelleTests/StatusBannerTests.swift
@@ -21,10 +21,9 @@ struct StatusBannerTests {
         func text(_ issue: PTZClient.AuthIssue, unreachable: Bool = false) -> String? {
             StatusBanner.text(for: BannerInputs(macUnreachable: unreachable, authIssue: issue, connecting: true, state: state(camera: .absent)))
         }
-        #expect(text(.unpaired) == "iPhone non appairé : lance ptzd pair sur le Mac")
-        #expect(text(.badCode) == "Code d'appairage refusé")
+        #expect(text(.unpaired) == "iPhone non appairé : scanne le QR code de ptzd pair")
+        #expect(text(.badCode) == "QR code refusé : relance ptzd pair")
         #expect(text(.rejected) == "Accès refusé par le Mac")
-        #expect(text(.needsTailscale) == "Appairage : active Tailscale sur l'iPhone")
         #expect(text(.unpaired, unreachable: true) == "Mac injoignable : Tailscale est-il actif ?")
     }
 
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : échec — la compilation des tests échoue : `start(settings:)`, `pair(with:)`, `.tls` et `remoteAddress` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Modifier `ios/Nacelle/App/AppModel.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/App/AppModel.swift b/ios/Nacelle/App/AppModel.swift
index 8ff6f08..a263206 100644
--- a/ios/Nacelle/App/AppModel.swift
+++ b/ios/Nacelle/App/AppModel.swift
@@ -10,8 +10,9 @@ final class AppModel {
         didSet {
             guard settings != oldValue else { return }
             store.save(settings)
-            // Au premier plan, de nouveaux réglages (dont ceux du premier lancement) connectent tout de suite.
-            if isForeground {
+            // Au premier plan, de nouveaux réglages reconnectent tout de suite, sauf l'adresse retenue
+            // à l'appairage : la connexion en cours la vaut déjà.
+            if isForeground, !rememberingAddress {
                 disconnect()
                 activate()
             }
@@ -23,6 +24,7 @@ final class AppModel {
     /// Connecté (ou en train de se connecter) au contrôle et à la vidéo.
     private(set) var isActive = false
     @ObservationIgnored private var isForeground = false
+    @ObservationIgnored private var rememberingAddress = false
     @ObservationIgnored private let store: SettingsStore
 
     init(store: SettingsStore, ptz: PTZClient, video: VideoSession) {
@@ -30,6 +32,9 @@ final class AppModel {
         self.ptz = ptz
         self.video = video
         settings = store.load()
+        ptz.onAddressLearned = { [weak self] address in
+            self?.remember(address)
+        }
     }
 
     static func live() -> AppModel {
@@ -41,7 +46,7 @@ final class AppModel {
                     switch endpoint {
                     case .url:
                         URLSessionWebSocketTransport(scheduler: scheduler)
-                    case .service:
+                    case .tls:
                         NWWebSocketTransport(scheduler: scheduler)
                     }
                 },
@@ -58,9 +63,9 @@ final class AppModel {
     /// Sans effet si déjà actif : un retour .inactive → .active ne relance rien.
     func activate() {
         isForeground = true
-        guard !isActive, let ptzdURL = settings.ptzdURL else { return }
+        guard !isActive else { return }
         isActive = true
-        ptz.start(url: ptzdURL)
+        ptz.start(settings: settings)
         // Offre vidéo relayée par ptzd (spec accès local § 8.4).
         video.start { [ptz] offer in
             try await ptz.negotiate(offer: offer)
@@ -73,9 +78,18 @@ final class AppModel {
         ptz.setJoystick(.zero)
     }
 
-    /// Appairage avec le code affiché par `ptzd pair` sur le Mac.
-    func pair(code: String) {
-        ptz.pair(code: code)
+    /// Appairage avec le QR code affiché par `ptzd pair` sur le Mac.
+    func pair(with link: PairingLink) {
+        ptz.pair(with: link)
+    }
+
+    /// L'adresse du Mac qui vient d'appairer l'iPhone va dans le champ s'il est vide (spec découverte et QR § 8.3).
+    private func remember(_ address: String) {
+        guard settings.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
+        rememberingAddress = true
+        settings.host = address
+        rememberingAddress = false
+        ptz.update(settings)
     }
 
     /// Oublie la clé de cet iPhone.
@@ -95,7 +109,7 @@ final class AppModel {
         video.stop()
     }
 
-    /// Rien tant que l'app n'est pas connectée (réglages incomplets : la feuille des réglages est ouverte).
+    /// Rien tant que l'app n'est pas au premier plan.
     var bannerText: String? {
         guard isActive else { return nil }
         return StatusBanner.text(for: BannerInputs(
PATCH
```

Modifier `ios/Nacelle/Control/ControlScreen.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/Control/ControlScreen.swift b/ios/Nacelle/Control/ControlScreen.swift
index f362753..f3845db 100644
--- a/ios/Nacelle/Control/ControlScreen.swift
+++ b/ios/Nacelle/Control/ControlScreen.swift
@@ -49,15 +49,9 @@ struct ControlScreen: View {
             SettingsView(
                 settings: $model.settings,
                 isPaired: model.ptz.isPaired,
-                onPair: { model.pair(code: $0) },
                 onForget: { model.forgetPairing() }
             )
         }
-        .onAppear {
-            if !model.settings.isComplete {
-                showSettings = true
-            }
-        }
     }
 
     private var settingsButton: some View {
PATCH
```

Modifier `ios/Nacelle/Control/StatusBanner.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/Control/StatusBanner.swift b/ios/Nacelle/Control/StatusBanner.swift
index 78f17b5..4382950 100644
--- a/ios/Nacelle/Control/StatusBanner.swift
+++ b/ios/Nacelle/Control/StatusBanner.swift
@@ -10,8 +10,9 @@ struct BannerInputs: Equatable {
     var state: StateSnapshot?
 }
 
-/// Texte du bandeau d'état (spec § 7.3, spec accès local § 8.5). Ordre de priorité : Mac
-/// injoignable, appairage, caméra débranchée, vie privée, suivi IA non coupé, prise en main, connexion.
+/// Texte du bandeau d'état (spec § 7.3, spec accès local § 8.5, spec découverte et QR § 8.4). Ordre de
+/// priorité : Mac injoignable, appairage, caméra débranchée, vie privée, suivi IA non coupé, prise en main,
+/// connexion.
 enum StatusBanner {
     static func text(for inputs: BannerInputs) -> String? {
         if inputs.macUnreachable {
@@ -19,13 +20,11 @@ enum StatusBanner {
         }
         switch inputs.authIssue {
         case .unpaired:
-            return "iPhone non appairé : lance ptzd pair sur le Mac"
+            return "iPhone non appairé : scanne le QR code de ptzd pair"
         case .badCode:
-            return "Code d'appairage refusé"
+            return "QR code refusé : relance ptzd pair"
         case .rejected:
             return "Accès refusé par le Mac"
-        case .needsTailscale:
-            return "Appairage : active Tailscale sur l'iPhone"
         case nil:
             break
         }
PATCH
```

Modifier `ios/Nacelle/PTZ/LocalNetwork.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/PTZ/LocalNetwork.swift b/ios/Nacelle/PTZ/LocalNetwork.swift
index c92e4fb..145e766 100644
--- a/ios/Nacelle/PTZ/LocalNetwork.swift
+++ b/ios/Nacelle/PTZ/LocalNetwork.swift
@@ -29,14 +29,15 @@ final class BonjourServiceBrowser: ServiceBrowser {
     }
 }
 
-/// WebSocket sur NWConnection, pour joindre un service Bonjour (URLSessionWebSocketTask ne prend
-/// qu'une URL). Une seule connexion à la fois ; vivacité par `Heartbeat`, comme l'autre transport.
+/// WebSocket sur NWConnection, pour joindre le réseau local en TLS à clé pré-partagée (URLSessionWebSocketTask
+/// ne fait pas ce TLS). Une seule connexion à la fois ; vivacité par `Heartbeat`, comme l'autre transport.
 @MainActor
 final class NWWebSocketTransport: WebSocketTransport {
     /// Délai d'ouverture, comme `URLSessionWebSocketTransport.openTimeout`.
     static let openTimeout: TimeInterval = 10
 
     var onEvent: ((TransportEvent) -> Void)?
+    private(set) var remoteAddress: String?
     private let scheduler: any Scheduler
     private var connection: NWConnection?
     private var heartbeat: Heartbeat?
@@ -54,7 +55,7 @@ final class NWWebSocketTransport: WebSocketTransport {
         case let .url(url):
             target = .url(url)
             tls = nil
-        case let .service(service, credentials):
+        case let .tls(service, credentials):
             target = service
             tls = NacelleTLS.client(identity: credentials.identity, key: credentials.key)
         }
@@ -71,6 +72,7 @@ final class NWWebSocketTransport: WebSocketTransport {
                 case .ready:
                     self.openDeadline?.cancel()
                     self.openDeadline = nil
+                    self.remoteAddress = connection.currentPath?.remoteEndpoint.flatMap(Self.ipv4)
                     self.startHeartbeat(for: connection)
                     self.onEvent?(.opened)
                 case .failed, .cancelled, .waiting:
@@ -96,7 +98,14 @@ final class NWWebSocketTransport: WebSocketTransport {
         connection?.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
     }
 
+    /// L'adresse IPv4 d'un point d'arrivée résolu, sans zone ; nil pour IPv6 ou un nom.
+    nonisolated static func ipv4(_ endpoint: NWEndpoint) -> String? {
+        guard case let .hostPort(.ipv4(address), _) = endpoint else { return nil }
+        return address.rawValue.map(String.init).joined(separator: ".")
+    }
+
     func close() {
+        remoteAddress = nil
         openDeadline?.cancel()
         openDeadline = nil
         heartbeat?.stop()
PATCH
```

Modifier `ios/Nacelle/PTZ/PTZClient.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/PTZ/PTZClient.swift b/ios/Nacelle/PTZ/PTZClient.swift
index 3e75d34..203bd29 100644
--- a/ios/Nacelle/PTZ/PTZClient.swift
+++ b/ios/Nacelle/PTZ/PTZClient.swift
@@ -4,10 +4,11 @@ import Network
 import Observation
 import os
 
-/// Dialogue avec ptzd (spec § 7.2, spec accès local § 8) : à chaque connexion, le nom Tailscale
-/// et le service Bonjour du réseau local sont essayés ensemble ; la première connexion
-/// authentifiée l'emporte. Puis prise en main, `move` répété 10 fois par seconde tant que le
-/// joystick est hors du centre, reconnexion espacée.
+/// Dialogue avec ptzd (spec § 7.2, spec accès local § 8, spec découverte et QR § 8) : à chaque
+/// connexion, l'adresse du champ et le service Bonjour du réseau local sont essayés ensemble ; la
+/// première connexion authentifiée l'emporte. Puis prise en main, `move` répété 10 fois par seconde
+/// tant que le joystick est hors du centre, reconnexion espacée. Un QR code scanné remplace ces
+/// candidates par ses adresses et Bonjour, en TLS avec le secret du QR, le temps de l'appairage.
 @MainActor
 @Observable
 final class PTZClient {
@@ -18,19 +19,18 @@ final class PTZClient {
         case waitingToRetry
     }
 
-    /// Ce qui empêche l'authentification. Un verdict de ptzd par Tailscale (`unpaired`, `rejected`,
-    /// `badCode`) arrête les reconnexions jusqu'à ce que l'utilisateur agisse. `needsTailscale` et les
-    /// verdicts reçus d'un service du réseau local les laissent continuer ; effacés à chaque nouvelle tentative.
+    /// Ce qui empêche l'authentification. Un verdict de ptzd par Tailscale (`unpaired`, `rejected`),
+    /// l'absence de clé et l'échec d'un appairage arrêtent les reconnexions jusqu'à ce que l'utilisateur
+    /// agisse. Les autres verdicts d'un service du réseau local les laissent continuer ; effacés à chaque
+    /// nouvelle tentative.
     enum AuthIssue: Equatable {
         /// Pas de clé, ou ptzd ne connaît pas cet iPhone.
         case unpaired
         /// Signature refusée.
         case rejected
-        /// Code d'appairage faux, expiré ou déjà utilisé.
+        /// QR code refusé : preuve fausse, appairage expiré ou déjà utilisé, ou aucun Mac n'a répondu
+        /// avec le secret du QR (spec découverte et QR § 9).
         case badCode
-        /// Un code attend, mais Tailscale n'a pas répondu : l'appairage ne passe que par Tailscale
-        /// (spec accès local § 8.3). Les reconnexions continuent.
-        case needsTailscale
     }
 
     /// Pourquoi une négociation vidéo n'a pas abouti.
@@ -61,7 +61,7 @@ final class PTZClient {
     /// Dernière erreur renvoyée par ptzd.
     private(set) var lastError: ErrorCode?
     /// Vrai quand une tentative de connexion a échoué, jusqu'à la prochaine réussite.
-    /// Remis à faux par `start(url:)` et `stop()` : le bandeau revient à « Connexion… ».
+    /// Remis à faux par `start(settings:)` et `stop()` : le bandeau revient à « Connexion… ».
     private(set) var isUnreachable = false
     private(set) var authIssue: AuthIssue?
     /// Cet iPhone s'est déjà authentifié, ou vient d'être appairé (enregistré).
@@ -73,15 +73,16 @@ final class PTZClient {
     @ObservationIgnored private let pairingRecord: PairingRecord
     @ObservationIgnored private let scheduler: any Scheduler
     @ObservationIgnored private let deviceName: String
-    @ObservationIgnored private var url: URL?
+    /// Adresse IPv4 du Mac qui vient d'appairer cet iPhone, à retenir dans le champ (spec découverte et QR § 8.3).
+    @ObservationIgnored var onAddressLearned: ((String) -> Void)?
+    /// Réglages du dernier `start` ; nil à l'arrêt.
+    @ObservationIgnored private var settings: ConnectionSettings?
     @ObservationIgnored private var attempt = 0
     @ObservationIgnored private var openedThisAttempt = false
     @ObservationIgnored private var candidates: [Candidate] = []
     @ObservationIgnored private var active: Candidate?
     @ObservationIgnored private var nextCandidateID = 0
     @ObservationIgnored private var foundLocal = false
-    /// La connexion Tailscale de la tentative en cours s'est ouverte.
-    @ObservationIgnored private var tailscaleOpened = false
     /// Verdict d'un service du réseau local pour la tentative en cours : affiché si la tentative
     /// échoue sans autre verdict, sans arrêter les reconnexions.
     @ObservationIgnored private var localIssue: AuthIssue?
@@ -91,8 +92,8 @@ final class PTZClient {
     @ObservationIgnored private var retry: (any Cancellable)?
     @ObservationIgnored private var repeater: (any Cancellable)?
     @ObservationIgnored private var currentMove = JoystickVector.zero
-    /// Code saisi dans les réglages, envoyé au prochain défi.
-    @ObservationIgnored private var pendingCode: String?
+    /// QR code scanné, en attente d'appairage. Son secret n'est jamais rangé (spec découverte et QR § 8.3).
+    @ObservationIgnored private var pendingPairing: PairingLink?
     @ObservationIgnored private var pairingCandidate: Candidate?
     @ObservationIgnored private var nextOfferID = 0
     /// Négociations vidéo en attente de `webrtcAnswer`, par identifiant d'offre.
@@ -104,7 +105,7 @@ final class PTZClient {
     private final class Candidate {
         let id: Int
         let transport: any WebSocketTransport
-        /// Ouverte vers un service Bonjour du réseau local (pas le nom Tailscale).
+        /// Ouverte en TLS vers le réseau local (service Bonjour ou adresse locale), pas vers Tailscale.
         let isLocal: Bool
         /// Défi reçu, en attente de réponse.
         var nonce: Data?
@@ -140,8 +141,8 @@ final class PTZClient {
         }
     }
 
-    func start(url: URL) {
-        self.url = url
+    func start(settings: ConnectionSettings) {
+        self.settings = settings
         attempt = 0
         isUnreachable = false
         retry?.cancel()
@@ -158,7 +159,7 @@ final class PTZClient {
         stopRepeating()
         retry?.cancel()
         retry = nil
-        url = nil
+        settings = nil
         closeAll()
         link = .idle
         state = nil
@@ -200,9 +201,16 @@ final class PTZClient {
         pending.values.forEach { $0.resume(throwing: error) }
     }
 
-    /// Appairage avec le code de `ptzd pair` : envoyé au prochain défi, connexion relancée.
-    func pair(code: String) {
-        pendingCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
+    /// Nouveaux réglages pris en compte à la tentative suivante, sans couper la connexion
+    /// (adresse retenue après un appairage).
+    func update(_ settings: ConnectionSettings) {
+        guard self.settings != nil else { return }
+        self.settings = settings
+    }
+
+    /// Appairage avec le QR code de `ptzd pair` : connexion relancée vers ses adresses et Bonjour.
+    func pair(with link: PairingLink) {
+        pendingPairing = link
         authIssue = nil
         authIssueBlocks = false
         restart()
@@ -212,7 +220,7 @@ final class PTZClient {
     func forgetPairing() {
         keys.delete()
         setPaired(false)
-        pendingCode = nil
+        pendingPairing = nil
         restart()
     }
 
@@ -247,28 +255,43 @@ final class PTZClient {
     // MARK: - Connexions
 
     private func restart() {
-        guard url != nil else { return }
+        guard settings != nil else { return }
         retry?.cancel()
         retry = nil
         attempt = 0
         connect()
     }
 
-    /// Une tentative : le nom Tailscale tout de suite, le réseau local si Bonjour trouve ptzd.
+    /// Une tentative. Appairage : chaque adresse du QR et Bonjour, avec le secret du QR. Sinon : l'adresse
+    /// du champ tout de suite, et Bonjour si l'iPhone a son secret du réseau local. Sans clé, rien à tenter.
     private func connect() {
-        guard let url else { return }
+        guard let settings else { return }
         closeAll()
         link = .connecting
         openedThisAttempt = false
-        tailscaleOpened = false
         foundLocal = false
         localIssue = nil
         if !authIssueBlocks {
             authIssue = nil
         }
-        open(.url(url))
-        // Le réseau local passe en TLS : sans secret remis à l'appairage, pas d'essai local.
-        if keys.load() != nil, keys.lanKey() != nil {
+        if let pairing = pendingPairing {
+            let credentials = Self.credentials(for: pairing)
+            for host in pairing.hosts {
+                if let port = NWEndpoint.Port(rawValue: UInt16(pairing.port)) {
+                    open(.tls(.hostPort(host: NWEndpoint.Host(host), port: port), credentials))
+                }
+            }
+        } else {
+            guard keys.load() != nil else {
+                setPaired(false)
+                giveUp(.unpaired)
+                return
+            }
+            if let endpoint = settings.endpoint(credentials: deviceCredentials()) {
+                open(endpoint)
+            }
+        }
+        if lanCredentials() != nil {
             browser.start()
         }
         discovery = scheduler.schedule(after: Self.discoveryWindow) { [weak self] in
@@ -276,11 +299,26 @@ final class PTZClient {
         }
     }
 
+    /// Identité TLS `pair-<pairingID>` et secret du QR code.
+    private static func credentials(for pairing: PairingLink) -> LANCredentials {
+        LANCredentials(identity: NacelleTLS.pairingIdentity(pairing.pairingID), key: pairing.secret)
+    }
+
+    /// Identité (`deviceID`) et secret remis à l'appairage, si l'iPhone a les deux.
+    private func deviceCredentials() -> LANCredentials? {
+        guard let key = keys.load(), let lanKey = keys.lanKey() else { return nil }
+        return LANCredentials(identity: key.deviceID, key: lanKey)
+    }
+
+    /// De quoi ouvrir le TLS du réseau local pour la tentative en cours.
+    private func lanCredentials() -> LANCredentials? {
+        pendingPairing.map(Self.credentials(for:)) ?? deviceCredentials()
+    }
+
     private func found(_ endpoint: NWEndpoint) {
-        guard link == .connecting, active == nil, !foundLocal,
-              let key = keys.load(), let lanKey = keys.lanKey() else { return }
+        guard link == .connecting, active == nil, !foundLocal, let credentials = lanCredentials() else { return }
         foundLocal = true
-        open(.service(endpoint, LANCredentials(identity: key.deviceID, key: lanKey)))
+        open(.tls(endpoint, credentials))
     }
 
     private func discoveryEnded() {
@@ -294,7 +332,7 @@ final class PTZClient {
     private func open(_ endpoint: WebSocketEndpoint) {
         nextCandidateID += 1
         let isLocal: Bool
-        if case .service = endpoint {
+        if case .tls = endpoint {
             isLocal = true
         } else {
             isLocal = false
@@ -341,9 +379,6 @@ final class PTZClient {
         switch event {
         case .opened:
             openedThisAttempt = true
-            if !candidate.isLocal {
-                tailscaleOpened = true
-            }
         case let .message(text):
             guard let message = try? NacelleCodec.decodeServer(text) else { return }
             if candidate === active {
@@ -378,7 +413,7 @@ final class PTZClient {
         case let .challenge(nonce):
             answer(nonce, on: candidate)
         case let .paired(_, lanKey):
-            // Seule la connexion qui a envoyé le code (Tailscale) peut confirmer l'appairage.
+            // Seule la connexion qui a envoyé la preuve peut confirmer l'appairage.
             guard candidate === pairingCandidate else { return }
             // Sans le secret, seul Tailscale reste : l'appairage est valable quand même.
             do {
@@ -386,9 +421,12 @@ final class PTZClient {
             } catch {
                 Self.logger.error("Secret du réseau local non enregistré : \(String(describing: error), privacy: .public)")
             }
-            pendingCode = nil
+            pendingPairing = nil
             pairingCandidate = nil
             setPaired(true)
+            if let address = candidate.transport.remoteAddress {
+                onAddressLearned?(address)
+            }
             for waiting in candidates where waiting.nonce != nil {
                 authenticate(waiting)
             }
@@ -407,8 +445,8 @@ final class PTZClient {
         }
     }
 
-    /// Un service du réseau local n'est pas authentifié : son verdict ne ferme que sa connexion
-    /// et ne touche ni l'appairage ni le code. Seule la connexion Tailscale peut tout arrêter.
+    /// Un refus de la preuve arrête l'appairage. Hors appairage, le verdict d'un service du réseau local
+    /// ne ferme que sa connexion et ne touche pas à l'appairage ; seule la connexion Tailscale peut tout arrêter.
     private func handleHandshakeError(_ code: ErrorCode, from candidate: Candidate) {
         let issue: AuthIssue
         switch code {
@@ -416,34 +454,32 @@ final class PTZClient {
             issue = .unpaired
         case .authFailed:
             issue = .rejected
-        case .badCode, .pairingClosed:
+        case .badCode, .pairingClosed, .notLocal:
             issue = .badCode
         default:
             lastError = code
             return
         }
+        if candidate === pairingCandidate {
+            pendingPairing = nil
+            giveUp(.badCode)
+            return
+        }
         if candidate.isLocal {
             localIssue = issue
             close(candidate)
             failAttemptIfOver()
             return
         }
-        switch issue {
-        case .unpaired:
+        if issue == .unpaired {
             setPaired(false)
-        case .badCode:
-            pendingCode = nil
-        default:
-            break
         }
         giveUp(issue)
     }
 
     private func answer(_ nonce: Data, on candidate: Candidate) {
         candidate.nonce = nonce
-        if let code = pendingCode {
-            // Le code ne part que par Tailscale ; la connexion locale attend `paired`.
-            guard !candidate.isLocal else { return }
+        if let pairing = pendingPairing {
             // Un seul appairage à la fois : les autres connexions attendent `paired`.
             guard pairingCandidate == nil else { return }
             guard let key = try? keys.loadOrCreate() else {
@@ -451,9 +487,8 @@ final class PTZClient {
                 return
             }
             pairingCandidate = candidate
-            // Transition (plan découverte et QR, tâche 1) : le code voyage dans `pairingID`, sans preuve ;
-            // la tâche 4 remplace ce passage par l'appairage du QR code.
-            send(.pair(pairingID: code, publicKey: key.publicKeyX963, name: deviceName, proof: Data()), on: candidate)
+            let proof = NacelleAuth.pairingProof(secret: pairing.secret, nonce: nonce, publicKeyX963: key.publicKeyX963)
+            send(.pair(pairingID: pairing.pairingID, publicKey: key.publicKeyX963, name: deviceName, proof: proof), on: candidate)
         } else if keys.load() != nil {
             authenticate(candidate)
         } else {
@@ -532,13 +567,17 @@ final class PTZClient {
     }
 
     private func attemptFailed() {
+        // Appairage sans réponse : le QR est refusé (mauvais secret, expiré) ou aucun Mac n'est joignable.
+        if pendingPairing != nil {
+            pendingPairing = nil
+            giveUp(.badCode)
+            return
+        }
         closeAll()
         if !openedThisAttempt {
             isUnreachable = true
         }
-        if pendingCode != nil, !tailscaleOpened {
-            authIssue = .needsTailscale
-        } else if let localIssue {
+        if let localIssue {
             authIssue = localIssue
         }
         state = nil
@@ -546,7 +585,7 @@ final class PTZClient {
     }
 
     private func scheduleRetry() {
-        guard url != nil else {
+        guard settings != nil else {
             link = .idle
             return
         }
PATCH
```

Modifier `ios/Nacelle/PTZ/WebSocketTransport.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/PTZ/WebSocketTransport.swift b/ios/Nacelle/PTZ/WebSocketTransport.swift
index a87d3d4..c224ccc 100644
--- a/ios/Nacelle/PTZ/WebSocketTransport.swift
+++ b/ios/Nacelle/PTZ/WebSocketTransport.swift
@@ -3,16 +3,17 @@ import Network
 
 /// Où ouvrir une connexion vers ptzd.
 enum WebSocketEndpoint: Equatable, Sendable {
-    /// Le nom Tailscale du Mac.
+    /// L'écoute Tailscale du Mac, en WebSocket simple.
     case url(URL)
-    /// Le service Bonjour `_nacelle._tcp` trouvé sur le réseau local, joint en TLS avec ce secret
-    /// (spec accès local § 14).
-    case service(NWEndpoint, LANCredentials)
+    /// Le réseau local (service Bonjour `_nacelle._tcp`, adresse du QR code ou du champ), en TLS
+    /// avec ce secret (spec accès local § 14, spec découverte et QR § 8.2).
+    case tls(NWEndpoint, LANCredentials)
 }
 
-/// Identité et secret du canal chiffré du réseau local, remis à l'appairage.
+/// Identité et secret du canal chiffré du réseau local : ceux remis à l'appairage, ou ceux du QR code
+/// pendant l'appairage.
 struct LANCredentials: Equatable, Sendable {
-    /// Le `deviceID` de l'iPhone, identité TLS.
+    /// Le `deviceID` de l'iPhone, ou `pair-<pairingID>` pendant l'appairage.
     var identity: String
     var key: Data
 }
@@ -37,6 +38,8 @@ enum TransportEvent: Equatable, Sendable {
 @MainActor
 protocol WebSocketTransport: AnyObject {
     var onEvent: ((TransportEvent) -> Void)? { get set }
+    /// Adresse IPv4 du Mac une fois la connexion ouverte, si le transport la connaît.
+    var remoteAddress: String? { get }
     func open(_ endpoint: WebSocketEndpoint)
     func send(_ text: String)
     func close()
@@ -51,6 +54,8 @@ final class URLSessionWebSocketTransport: NSObject, WebSocketTransport {
     static let openTimeout: TimeInterval = 10
 
     var onEvent: ((TransportEvent) -> Void)?
+    /// Le nom Tailscale suffit : rien à retenir.
+    let remoteAddress: String? = nil
     private let scheduler: any Scheduler
     private var session: URLSession?
     private var task: URLSessionWebSocketTask?
@@ -60,7 +65,7 @@ final class URLSessionWebSocketTransport: NSObject, WebSocketTransport {
         self.scheduler = scheduler
     }
 
-    /// Le nom Tailscale ; un service Bonjour passe par `NWWebSocketTransport`.
+    /// Le nom Tailscale ; le réseau local passe par `NWWebSocketTransport`.
     func open(_ endpoint: WebSocketEndpoint) {
         close()
         guard case let .url(url) = endpoint else {
PATCH
```

Remplacer tout le contenu de `ios/Nacelle/Settings/ConnectionSettings.swift` par :

```swift
import Foundation
import Network

/// L'adresse du Mac en repli (spec découverte et QR § 8.1) : retenue à l'appairage, modifiable à la main.
/// Vide, l'app ne compte que sur Bonjour. La vidéo passe par ptzd.
struct ConnectionSettings: Codable, Equatable, Sendable {
    /// Comment joindre l'adresse du champ (spec découverte et QR § 8.2).
    enum Route: Equatable, Sendable {
        /// IPv4 privée ou nom en `.local` : TLS à clé pré-partagée, à la maison ou en 4G par la route du NAS.
        case local
        /// Tout le reste (nom MagicDNS ou adresse Tailscale) : WebSocket simple vers l'écoute Tailscale.
        case tailscale
    }

    /// Adresse IPv4 locale du Mac, nom en `.local`, ou nom ou adresse Tailscale ; vide : Bonjour seul.
    var host = ""
    var ptzdPort = 1985

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Champ vide ou hôte nu (ni schéma, ni port, ni chemin, ni espace), et port valide : enregistrable.
    var isValid: Bool {
        (1...65535).contains(ptzdPort) && (trimmedHost.isEmpty || hostIsBare)
    }

    private var hostIsBare: Bool {
        !trimmedHost.contains { $0 == "/" || $0 == ":" || $0.isWhitespace } && makePtzdURL() != nil
    }

    /// L'adresse du champ, renseignée et valide.
    var fallbackHost: String? {
        isValid && !trimmedHost.isEmpty ? trimmedHost : nil
    }

    /// Port tapé dans un champ texte ; 0 (donc réglages invalides) si ce n'est pas un nombre.
    static func port(from text: String) -> Int {
        Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// IPv4 privée (10/8, 172.16/12, 192.168/16) ou nom en `.local` : réseau local ; sinon Tailscale.
    static func route(for host: String) -> Route {
        if host.lowercased().hasSuffix(".local") {
            return .local
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { part in
            part.allSatisfy { $0.isASCII && $0.isNumber } ? UInt8(part) : nil
        }
        guard parts.count == 4, octets.count == 4 else { return .tailscale }
        switch (octets[0], octets[1]) {
        case (10, _), (172, 16...31), (192, 168):
            return .local
        default:
            return .tailscale
        }
    }

    /// Où joindre l'adresse du champ : en TLS avec ces secrets pour une adresse locale (aucune sans
    /// secret), en WebSocket simple pour Tailscale ; nil si le champ est vide.
    func endpoint(credentials: LANCredentials?) -> WebSocketEndpoint? {
        guard let host = fallbackHost, let url = makePtzdURL(), let port = NWEndpoint.Port(rawValue: UInt16(ptzdPort)) else {
            return nil
        }
        switch Self.route(for: host) {
        case .local:
            return credentials.map { .tls(.hostPort(host: NWEndpoint.Host(host), port: port), $0) }
        case .tailscale:
            return .url(url)
        }
    }

    /// `ws://<hôte>:<port ptzd>`
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

Remplacer tout le contenu de `ios/Nacelle/Settings/SettingsView.swift` par :

```swift
import SwiftUI

/// Réglages : l'adresse du Mac en repli et l'appairage (spec découverte et QR § 8.1).
struct SettingsView: View {
    @Binding var settings: ConnectionSettings
    let isPaired: Bool
    let onForget: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ConnectionSettings()
    // Port saisi en texte : un champ lié à un Int ne se met à jour qu'à la validation (Retour ou perte
    // du focus), et le pavé numérique n'a pas de Retour ; « Enregistrer » perdrait la dernière saisie.
    @State private var ptzdPortText = ""
    @State private var confirmForget = false

    /// Les réglages tels que saisis, port compris.
    private var edited: ConnectionSettings {
        var settings = draft
        settings.ptzdPort = ConnectionSettings.port(from: ptzdPortText)
        return settings
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Adresse du Mac (repli)", text: $draft.host)
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
                    Text("Retenue à l'appairage. Une adresse locale sert à la maison, et en 4G par la route de sous-réseau du NAS (Tailscale actif sur l'iPhone). Vide : l'app cherche le Mac sur le Wi-Fi.")
                }
                Section {
                    LabeledContent("État", value: isPaired ? "Appairé" : "Non appairé")
                    if isPaired {
                        Button("Oublier cet appairage", role: .destructive) {
                            confirmForget = true
                        }
                    }
                } header: {
                    Text("Appairage")
                } footer: {
                    Text("Sur le Mac, lance ptzd pair dans le Terminal pour afficher un QR code, valable 5 min.")
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        settings = edited
                        dismiss()
                    }
                    .disabled(!edited.isValid)
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
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : tout passe (iOS : 75 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add ios/Nacelle/App/AppModel.swift \
    ios/Nacelle/Control/ControlScreen.swift \
    ios/Nacelle/Control/StatusBanner.swift \
    ios/Nacelle/PTZ/LocalNetwork.swift \
    ios/Nacelle/PTZ/PTZClient.swift \
    ios/Nacelle/PTZ/WebSocketTransport.swift \
    ios/Nacelle/Settings/ConnectionSettings.swift \
    ios/Nacelle/Settings/SettingsView.swift \
    ios/NacelleTests/AppModelTests.swift \
    ios/NacelleTests/ConnectionSettingsTests.swift \
    ios/NacelleTests/FakeTransport.swift \
    ios/NacelleTests/PTZClientTests.swift \
    ios/NacelleTests/StatusBannerTests.swift
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
App : appairage par QR code, adresse retenue, TLS selon l'adresse

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés à l'étape 1 ou 3 sont déjà indexés par `git rm`.

### Tâche 5 : App PTZBot : écran d'appairage, lecteur de QR code, README

**But :** L'app s'appelle PTZBot sur l'écran d'accueil ; tant qu'elle n'est pas appairée, un écran plein « Recherche du Mac à proximité… » liste les services Bonjour et propose « Scanner le QR code » (VisionKit) ; les réglages gardent le champ « Adresse du Mac (repli) » et le lecteur ; le README décrit le nouvel appairage (spec découverte et QR § 8.1).

**Fichiers :**
- Modifier : `README.md`
- Modifier : `ios/Nacelle/App/AppModel.swift`
- Modifier : `ios/Nacelle/Control/ControlScreen.swift`
- Modifier : `ios/Nacelle/Control/StatusBanner.swift`
- Modifier : `ios/Nacelle/PTZ/PTZClient.swift`
- Créer : `ios/Nacelle/Pairing/Discovery.swift`
- Créer : `ios/Nacelle/Pairing/PairingScreen.swift`
- Créer : `ios/Nacelle/Pairing/QRScannerView.swift`
- Modifier : `ios/Nacelle/Settings/SettingsView.swift`
- Modifier : `ios/NacelleTests/AppModelTests.swift`
- Créer : `ios/NacelleTests/DiscoveryTests.swift`
- Modifier : `ios/NacelleTests/PTZClientTests.swift`
- Modifier : `ios/project.yml`

**Interfaces :**
- Consomme : `AppModel.pair(with:)`, `PTZClient` (tâche 4).
- Produit : `ServiceListing`, `Discovery` (`macs`, `start()`, `stop()`), `BonjourServiceList` (`names(_:)`) ; `PTZClient.isPairing` ; `AppModel.needsPairing`, `AppModel.pairingStatus` (« Appairage… », « QR code refusé : relance ptzd pair ») ; `StatusBanner.qrRefused` ; `QRScannerView(onLink:)`, `PairingScreen(model:)` ; `SettingsView(settings:isPaired:onPair:onForget:)`.
- `project.yml` : `CFBundleDisplayName` PTZBot, `NSCameraUsageDescription` « Pour scanner le QR code affiché par ptzd pair sur le Mac. ».
- Faits vérifiés dans le simulateur iOS 27 : l'écran liste le `ptzd` du Mac ; la demande d'accès à l'appareil photo nomme « PTZBot » ; `DataScannerViewController.isSupported` est faux dans le simulateur, d'où « Lecteur indisponible ».

- [ ] **Étape 1 : Écrire les tests**

Modifier `ios/NacelleTests/AppModelTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/NacelleTests/AppModelTests.swift b/ios/NacelleTests/AppModelTests.swift
index 2dd18ad..387e96e 100644
--- a/ios/NacelleTests/AppModelTests.swift
+++ b/ios/NacelleTests/AppModelTests.swift
@@ -63,6 +63,29 @@ struct AppModelTests {
         model.deactivate()
     }
 
+    @Test("Écran d'appairage : tant que l'iPhone n'est pas appairé ; « Appairage… », puis « QR code refusé »")
+    func pairingScreen() throws {
+        let model = makeModel()
+        model.activate()
+        #expect(model.needsPairing)
+        #expect(model.pairingStatus == nil)
+        let link = try #require(PairingLink(string: "nacelle://pair?v=1&id=1a2b3c4d&k=BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU&h=192.0.2.30&p=1985"))
+        model.pair(with: link)
+        #expect(model.pairingStatus == "Appairage…")
+        let transport = try #require(transports.last)
+        transport.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
+        transport.emit(.message(try NacelleCodec.encode(ServerMessage.error(code: .pairingClosed, message: "x"))))
+        #expect(model.pairingStatus == "QR code refusé : relance ptzd pair")
+        #expect(model.needsPairing)
+        model.pair(with: link)
+        let second = try #require(transports.last)
+        second.emit(.message(try NacelleCodec.encode(ServerMessage.challenge(nonce: Data(count: 32)))))
+        second.emit(.message(try NacelleCodec.encode(ServerMessage.paired(deviceID: "x", lanKey: Data(count: 32)))))
+        #expect(!model.needsPairing)
+        #expect(model.pairingStatus == nil)
+        model.deactivate()
+    }
+
     @Test("Appairage par QR : un champ déjà rempli n'est pas modifié")
     func addressKept() throws {
         SettingsStore(defaults: defaults).save(complete)
PATCH
```

Créer `ios/NacelleTests/DiscoveryTests.swift` :

```swift
import Network
import Testing
@testable import Nacelle

/// Liste Bonjour simulée.
@MainActor
final class FakeServiceListing: ServiceListing {
    var onChange: (([String]) -> Void)?
    private(set) var isRunning = false

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func publish(_ names: [String]) {
        onChange?(names)
    }
}

@MainActor
@Suite("Recherche des Mac à proximité")
struct DiscoveryTests {
    @Test("Les Mac trouvés sont publiés ; l'arrêt coupe la recherche et vide la liste")
    func listing() {
        let listing = FakeServiceListing()
        let discovery = Discovery(listing: listing)
        discovery.start()
        #expect(listing.isRunning)
        #expect(discovery.macs.isEmpty)
        listing.publish(["PTZBot sur Mac mini"])
        #expect(discovery.macs == ["PTZBot sur Mac mini"])
        discovery.stop()
        #expect(!listing.isRunning)
        #expect(discovery.macs.isEmpty)
    }

    @Test("Noms des services : sans doublon (plusieurs interfaces), triés, autres points d'arrivée ignorés")
    func names() {
        let endpoints: [NWEndpoint] = [
            .service(name: "PTZBot sur Mac mini", type: "_nacelle._tcp", domain: "local.", interface: nil),
            .service(name: "PTZBot sur iMac", type: "_nacelle._tcp", domain: "local.", interface: nil),
            .service(name: "PTZBot sur Mac mini", type: "_nacelle._tcp", domain: "local.", interface: nil),
            .hostPort(host: "192.0.2.30", port: 1985),
        ]
        #expect(BonjourServiceList.names(endpoints) == ["PTZBot sur Mac mini", "PTZBot sur iMac"].sorted())
    }
}
```

Modifier `ios/NacelleTests/PTZClientTests.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/NacelleTests/PTZClientTests.swift b/ios/NacelleTests/PTZClientTests.swift
index e036386..aa9df87 100644
--- a/ios/NacelleTests/PTZClientTests.swift
+++ b/ios/NacelleTests/PTZClientTests.swift
@@ -157,7 +157,9 @@ struct PTZClientTests {
         var learned: [String] = []
         client.onAddressLearned = { learned.append($0) }
         client.start(settings: settings)
+        #expect(!client.isPairing)
         client.pair(with: link)
+        #expect(client.isPairing)
         let first = try #require(qr("192.0.2.30"))
         first.remoteAddress = "192.0.2.30"
         first.emit(.opened)
@@ -169,6 +171,7 @@ struct PTZClientTests {
         try emit(.paired(deviceID: key.deviceID, lanKey: newKey), on: first)
         #expect(keys.storedLANKey == newKey)
         #expect(client.isPaired)
+        #expect(!client.isPairing)
         #expect(learned == ["192.0.2.30"])
         guard case let .auth(deviceID, signature) = decoded(first).last else {
             Issue.record("auth attendu après paired")
@@ -220,6 +223,7 @@ struct PTZClientTests {
         try emit(.challenge(nonce: nonce), on: first)
         try emit(.error(code: code, message: "x"), on: first)
         #expect(client.authIssue == .badCode)
+        #expect(!client.isPairing)
         #expect(client.link == .idle)
         #expect(first.closeCount >= 1)
         let opened = transports.all.count
PATCH
```

Modifier `ios/project.yml` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/project.yml b/ios/project.yml
index 21d857f..34aa83a 100644
--- a/ios/project.yml
+++ b/ios/project.yml
@@ -1,4 +1,4 @@
-# Projet Xcode de l'app Nacelle, généré par xcodegen (le .xcodeproj n'est pas versionné).
+# Projet Xcode de l'app PTZBot (cible Nacelle), généré par xcodegen (le .xcodeproj n'est pas versionné).
 # Générer : cd ios && xcodegen
 name: Nacelle
 options:
@@ -35,13 +35,14 @@ targets:
     info:
       path: Nacelle/Info.plist
       properties:
-        CFBundleDisplayName: Nacelle
+        CFBundleDisplayName: PTZBot
         UILaunchScreen: {}
         UISupportedInterfaceOrientations:
           - UIInterfaceOrientationPortrait
           - UIInterfaceOrientationLandscapeLeft
           - UIInterfaceOrientationLandscapeRight
         NSLocalNetworkUsageDescription: "À la maison, l'app trouve le Mac et la caméra sur le Wi-Fi, sans Tailscale."
+        NSCameraUsageDescription: "Pour scanner le QR code affiché par ptzd pair sur le Mac."
         NSBonjourServices:
           - _nacelle._tcp
         NSAppTransportSecurity:
PATCH
```

- [ ] **Étape 2 : Lancer les tests**

```bash
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : échec — la compilation des tests échoue : `Discovery`, `ServiceListing`, `isPairing` et `pairingStatus` n'existent pas encore.

- [ ] **Étape 3 : Écrire le code**

Modifier `README.md` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

````bash
git apply <<'PATCH'
diff --git a/README.md b/README.md
index e078566..56caa3b 100644
--- a/README.md
+++ b/README.md
@@ -9,9 +9,9 @@ La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](h
 ## Statut
 
 - **Côté Mac** : `ptzd` et `obsbot-ai-off` s'installent avec `scripts/install-mac.sh` (voir plus bas).
-- **App iOS** : s'installe depuis Xcode sur l'iPhone (voir « App iOS » plus bas).
+- **App iOS** (PTZBot) : s'installe depuis Xcode sur l'iPhone (voir « App iOS » plus bas).
 
-Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [spec de l'accès local](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [plan de l'accès local](docs/superpowers/plans/2026-10-06-acces-local.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).
+Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [spec de l'accès local](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [spec de la découverte et du QR code](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [plan de l'accès local](docs/superpowers/plans/2026-10-06-acces-local.md) · [plan de la découverte et du QR code](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).
 
 ## Architecture
 
@@ -25,10 +25,10 @@ iPhone : app SwiftUI                         Mac (celui de go2rtc)
 │                           │            │                       ▼          │
 │ Vidéo WebRTC ◀────────────┼─ images ───│ go2rtc (API en local) ◀── ffmpeg │
 └───────────────────────────┘            └──────────────────────────────────┘
-   à la maison : Wi-Fi (Bonjour) ; dehors : Tailscale
+   à la maison : Wi-Fi (Bonjour, adresse locale) ; dehors : la même adresse par Tailscale
 ```
 
-- **`ptzd`** : un service macOS en Swift, lancé par launchd. C'est le seul à envoyer des commandes de nacelle à la caméra, en UVC. Il écoute sur l'adresse Tailscale du Mac, sur 127.0.0.1, et sur ses interfaces Wi-Fi et Ethernet, où il s'annonce par Bonjour (`_nacelle._tcp`). Chaque iPhone doit être appairé une fois, par Tailscale ; ensuite, il signe un défi à chaque connexion. Sur le réseau local, tout passe en plus dans un canal TLS dont la clé, propre à chaque iPhone, est remise à l'appairage. Seules les connexions venues de 127.0.0.1 sont dispensées du défi.
+- **`ptzd`** : un service macOS en Swift, lancé par launchd. C'est le seul à envoyer des commandes de nacelle à la caméra, en UVC. Il écoute sur l'adresse Tailscale du Mac, sur 127.0.0.1, et sur ses interfaces Wi-Fi et Ethernet, où il s'annonce par Bonjour (`_nacelle._tcp`). Chaque iPhone est appairé une fois, sur le réseau local, en scannant le QR code affiché par `ptzd pair` ; ensuite, il signe un défi à chaque connexion. Sur le réseau local, tout passe en plus dans un canal TLS : pendant l'appairage, sa clé est le secret du QR code ; ensuite, une clé propre à chaque iPhone, remise à l'appairage. Seules les connexions venues de 127.0.0.1 sont dispensées du défi.
 - **`obsbot-ai-off`** : un petit utilitaire qui coupe le suivi IA de la caméra avec le SDK OBSBOT, puis se termine. `ptzd` le lance à chaque prise en main.
 - **go2rtc** : `ptzd` lui relaie l'offre WebRTC de l'app ; les images vont ensuite directement de go2rtc à l'iPhone. Voir « go2rtc » plus bas pour le fermer au réseau local.
 
@@ -91,7 +91,7 @@ Le Mac ne peut pas se joindre lui-même par son adresse Tailscale : en local, pa
 
 ## App iOS
 
-Prérequis : Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), un identifiant Apple (un compte gratuit suffit), Tailscale sur l'iPhone, et le côté Mac installé.
+Prérequis : Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), un identifiant Apple (un compte gratuit suffit), le côté Mac installé, et Tailscale sur l'iPhone pour piloter hors de la maison.
 
 1. Indiquer l'équipe de signature dans un réglage local, non versionné. Son identifiant est le champ OU des certificats « Apple Development » du trousseau :
 
@@ -118,15 +118,15 @@ Prérequis : Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew ins
    ```
 
 3. Au premier lancement, iOS demande de faire confiance au développeur : Réglages › Général › VPN et gestion de l'appareil.
-4. Dans l'app, saisir le nom Tailscale du Mac (champ `DNSName`, sans le point final, de `tailscale status --self --peers=false --json` sur le Mac). Le port par défaut (1985) convient.
-5. Appairer l'iPhone : sur le Mac, afficher un code (valable 5 min, un seul usage, 3 essais) :
+4. Au premier lancement, PTZBot cherche le Mac sur le Wi-Fi (« Recherche du Mac à proximité… ») : iOS demande l'accès au réseau local, répondre **Autoriser**.
+5. Appairer l'iPhone, sur le même réseau que le Mac : afficher un QR code (valable 5 min, un seul usage, 3 essais) :
 
    ```bash
    ~/Library/Application\ Support/ObsbotNacelle/bin/ptzd pair
    ```
 
-   Puis, avec Tailscale actif sur l'iPhone (l'appairage ne passe que par Tailscale), le saisir dans Réglages › Appairage et toucher **Enregistrer**. La clé de l'iPhone reste dans sa Secure Enclave ; le Mac garde sa clé publique et le secret du canal chiffré du réseau local, dans `devices.json` (droits 600).
-6. À la maison, l'app trouve le Mac sur le Wi-Fi, sans Tailscale : au premier essai, iOS demande l'accès au réseau local, répondre **Autoriser**.
+   Puis, dans l'app, toucher **Scanner le QR code** et viser l'écran du Mac (iOS demande l'accès à l'appareil photo). La clé de l'iPhone reste dans sa Secure Enclave ; le Mac garde sa clé publique et le secret du canal chiffré du réseau local, dans `devices.json` (droits 600). L'app retient l'adresse locale du Mac dans Réglages › Adresse du Mac (repli).
+6. Hors de la maison, l'app joint cette même adresse par Tailscale si un appareil du tailnet publie le réseau local (routage de sous-réseau) et si l'iPhone accepte les routes. Sinon, mettre dans le champ le nom Tailscale du Mac (champ `DNSName`, sans le point final, de `tailscale status --self --peers=false --json` sur le Mac) : l'app le joint par l'écoute Tailscale de `ptzd`, sans TLS.
 
 Retirer un iPhone : `ptzd devices` donne le début de son identifiant, puis `ptzd revoke <début>`. Ses connexions déjà ouvertes durent jusqu'à leur fin ; relancer le service pour les couper tout de suite.
 
@@ -156,6 +156,7 @@ webrtc:
 - Le port WebRTC 8555 reste ouvert : sans offre négociée par `ptzd`, il ne donne aucune image.
 - `go2rtc.yaml` contient le mot de passe RTSP : le passer en droits 600 (`chmod 600 go2rtc.yaml`).
 - Le flux RTSP vers Homebridge, identifiants compris, circule en clair sur le réseau local : un appareil qui intercepte ce trafic peut les lire, ainsi que les images.
+- Le QR code de `ptzd pair`, et l'URL affichée sous lui, permettent d'appairer un appareil pendant 5 minutes : ne les afficher que le temps du scan.
 - Ne jamais exposer 127.0.0.1:1985 au réseau, par exemple avec `tailscale serve` ou `ssh -L` : les connexions venues de 127.0.0.1 sont dispensées d'authentification, tout client distant passé par là piloterait la caméra.
 
 ## Désinstaller
PATCH
````

Modifier `ios/Nacelle/App/AppModel.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/App/AppModel.swift b/ios/Nacelle/App/AppModel.swift
index a263206..22cd21e 100644
--- a/ios/Nacelle/App/AppModel.swift
+++ b/ios/Nacelle/App/AppModel.swift
@@ -120,6 +120,19 @@ final class AppModel {
         ))
     }
 
+    /// L'écran d'appairage remplace les commandes tant que l'iPhone n'est pas appairé (spec découverte et QR § 8.1).
+    var needsPairing: Bool {
+        !ptz.isPaired
+    }
+
+    /// Où en est l'appairage, sur l'écran d'appairage.
+    var pairingStatus: String? {
+        if ptz.isPairing {
+            return "Appairage…"
+        }
+        return ptz.authIssue == .badCode ? StatusBanner.qrRefused : nil
+    }
+
     /// Joystick et zoom utilisables : connecté, caméra présente, hors vie privée.
     var controlsEnabled: Bool {
         guard ptz.link == .connected, let state = ptz.state else { return false }
PATCH
```

Modifier `ios/Nacelle/Control/ControlScreen.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/Control/ControlScreen.swift b/ios/Nacelle/Control/ControlScreen.swift
index f3845db..ec79a11 100644
--- a/ios/Nacelle/Control/ControlScreen.swift
+++ b/ios/Nacelle/Control/ControlScreen.swift
@@ -49,9 +49,13 @@ struct ControlScreen: View {
             SettingsView(
                 settings: $model.settings,
                 isPaired: model.ptz.isPaired,
+                onPair: { model.pair(with: $0) },
                 onForget: { model.forgetPairing() }
             )
         }
+        .fullScreenCover(isPresented: Binding(get: { model.needsPairing }, set: { _ in })) {
+            PairingScreen(model: model)
+        }
     }
 
     private var settingsButton: some View {
PATCH
```

Modifier `ios/Nacelle/Control/StatusBanner.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/Control/StatusBanner.swift b/ios/Nacelle/Control/StatusBanner.swift
index 4382950..52524f8 100644
--- a/ios/Nacelle/Control/StatusBanner.swift
+++ b/ios/Nacelle/Control/StatusBanner.swift
@@ -14,6 +14,8 @@ struct BannerInputs: Equatable {
 /// priorité : Mac injoignable, appairage, caméra débranchée, vie privée, suivi IA non coupé, prise en main,
 /// connexion.
 enum StatusBanner {
+    static let qrRefused = "QR code refusé : relance ptzd pair"
+
     static func text(for inputs: BannerInputs) -> String? {
         if inputs.macUnreachable {
             return "Mac injoignable : Tailscale est-il actif ?"
@@ -22,7 +24,7 @@ enum StatusBanner {
         case .unpaired:
             return "iPhone non appairé : scanne le QR code de ptzd pair"
         case .badCode:
-            return "QR code refusé : relance ptzd pair"
+            return qrRefused
         case .rejected:
             return "Accès refusé par le Mac"
         case nil:
PATCH
```

Modifier `ios/Nacelle/PTZ/PTZClient.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/PTZ/PTZClient.swift b/ios/Nacelle/PTZ/PTZClient.swift
index 203bd29..96c4c2e 100644
--- a/ios/Nacelle/PTZ/PTZClient.swift
+++ b/ios/Nacelle/PTZ/PTZClient.swift
@@ -66,6 +66,10 @@ final class PTZClient {
     private(set) var authIssue: AuthIssue?
     /// Cet iPhone s'est déjà authentifié, ou vient d'être appairé (enregistré).
     private(set) var isPaired: Bool
+    /// Un QR code scanné attend la réponse du Mac.
+    var isPairing: Bool {
+        pendingPairing != nil
+    }
 
     @ObservationIgnored private let makeTransport: (WebSocketEndpoint) -> any WebSocketTransport
     @ObservationIgnored private let browser: any ServiceBrowser
@@ -93,7 +97,7 @@ final class PTZClient {
     @ObservationIgnored private var repeater: (any Cancellable)?
     @ObservationIgnored private var currentMove = JoystickVector.zero
     /// QR code scanné, en attente d'appairage. Son secret n'est jamais rangé (spec découverte et QR § 8.3).
-    @ObservationIgnored private var pendingPairing: PairingLink?
+    private var pendingPairing: PairingLink?
     @ObservationIgnored private var pairingCandidate: Candidate?
     @ObservationIgnored private var nextOfferID = 0
     /// Négociations vidéo en attente de `webrtcAnswer`, par identifiant d'offre.
PATCH
```

Créer `ios/Nacelle/Pairing/Discovery.swift` :

```swift
import Foundation
import Network
import Observation

/// Les services `_nacelle._tcp` du réseau local, par nom, pour l'écran d'appairage. Les résultats
/// arrivent sur le MainActor.
@MainActor
protocol ServiceListing: AnyObject {
    var onChange: (([String]) -> Void)? { get set }
    func start()
    func stop()
}

/// Recherche des Mac à proximité (spec découverte et QR § 8.1). La première recherche déclenche la
/// demande d'accès au réseau local d'iOS.
@MainActor
@Observable
final class Discovery {
    /// Noms des services trouvés (« PTZBot sur <nom du Mac> »), triés.
    private(set) var macs: [String] = []
    @ObservationIgnored private let listing: any ServiceListing

    init(listing: any ServiceListing) {
        self.listing = listing
        listing.onChange = { [weak self] names in
            self?.macs = names
        }
    }

    func start() {
        listing.start()
    }

    func stop() {
        listing.stop()
        macs = []
    }
}

/// `ServiceListing` sur NWBrowser.
@MainActor
final class BonjourServiceList: ServiceListing {
    var onChange: (([String]) -> Void)?
    private var browser: NWBrowser?

    func start() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: BonjourServiceBrowser.type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                self.onChange?(Self.names(results.map(\.endpoint)))
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Noms des services, sans doublon (un même Mac annoncé sur plusieurs interfaces), triés.
    nonisolated static func names(_ endpoints: [NWEndpoint]) -> [String] {
        Set(endpoints.compactMap { endpoint in
            if case let .service(name, _, _, _) = endpoint { name } else { nil }
        }).sorted()
    }
}
```

Créer `ios/Nacelle/Pairing/PairingScreen.swift` :

```swift
import NacelleProtocol
import SwiftUI

/// Tant que l'iPhone n'est pas appairé (spec découverte et QR § 8.1) : les Mac trouvés sur le Wi-Fi,
/// le lecteur de QR code et l'accès aux réglages (adresse de repli).
struct PairingScreen: View {
    @Bindable var model: AppModel
    @State private var discovery = Discovery(listing: BonjourServiceList())
    @State private var showScanner = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(discovery.macs, id: \.self) { name in
                        Label(name, systemImage: "desktopcomputer")
                    }
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Recherche du Mac à proximité…")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Sur le Wi-Fi")
                } footer: {
                    Text("Sur le Mac, lance ptzd pair dans le Terminal, puis scanne le QR code affiché.")
                }
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scanner le QR code", systemImage: "qrcode.viewfinder")
                    }
                    if let status = model.pairingStatus {
                        Text(status)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("PTZBot")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Réglages")
                }
            }
        }
        .onAppear {
            discovery.start()
        }
        .onDisappear {
            discovery.stop()
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { link in
                showScanner = false
                model.pair(with: link)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                settings: $model.settings,
                isPaired: model.ptz.isPaired,
                onPair: { model.pair(with: $0) },
                onForget: { model.forgetPairing() }
            )
        }
    }
}
```

Créer `ios/Nacelle/Pairing/QRScannerView.swift` :

```swift
import AVFoundation
import NacelleProtocol
import SwiftUI
import VisionKit

/// Lecteur de QR code plein écran (spec découverte et QR § 8.1 et § 8.3) : le premier QR d'appairage
/// reconnu est rendu une fois ; un autre QR affiche « QR code non reconnu » et la lecture continue.
struct QRScannerView: View {
    let onLink: (PairingLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var access = CameraAccess.current
    @State private var message: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scanner le QR code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annuler") {
                            dismiss()
                        }
                    }
                }
        }
        .task {
            if DataScannerViewController.isSupported, access == .undetermined {
                access = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !DataScannerViewController.isSupported {
            ContentUnavailableView(
                "Lecteur indisponible",
                systemImage: "qrcode.viewfinder",
                description: Text("Cet appareil ne lit pas les QR codes avec l'appareil photo.")
            )
        } else {
            scanner
        }
    }

    @ViewBuilder
    private var scanner: some View {
        switch access {
        case .granted:
            ZStack(alignment: .bottom) {
                DataScanner { payload in
                    guard !done else { return }
                    if let link = PairingLink(string: payload) {
                        done = true
                        onLink(link)
                    } else {
                        message = "QR code non reconnu"
                    }
                }
                .ignoresSafeArea()
                Text(message ?? "Vise le QR code affiché par ptzd pair sur le Mac.")
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 32)
            }
        case .denied:
            ContentUnavailableView {
                Label("Appareil photo refusé", systemImage: "camera.fill")
            } description: {
                Text("Autorise l'appareil photo pour PTZBot dans les Réglages d'iOS.")
            } actions: {
                Button("Ouvrir les Réglages") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        case .undetermined:
            ProgressView()
        }
    }
}

/// Accès à l'appareil photo.
enum CameraAccess {
    case granted
    case denied
    case undetermined

    static var current: CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            .granted
        case .notDetermined:
            .undetermined
        default:
            .denied
        }
    }
}

/// `DataScannerViewController` limité aux QR codes : rend le texte de chaque QR reconnu.
private struct DataScanner: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: (String) -> Void

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(barcode) in addedItems {
                if let payload = barcode.payloadStringValue {
                    onPayload(payload)
                }
            }
        }
    }
}
```

Modifier `ios/Nacelle/Settings/SettingsView.swift` en appliquant ce correctif depuis la racine du dépôt (il échoue si le fichier ne correspond pas : ne pas forcer, comparer avec le contexte du correctif) :

```bash
git apply <<'PATCH'
diff --git a/ios/Nacelle/Settings/SettingsView.swift b/ios/Nacelle/Settings/SettingsView.swift
index 4ae6b65..6f0506c 100644
--- a/ios/Nacelle/Settings/SettingsView.swift
+++ b/ios/Nacelle/Settings/SettingsView.swift
@@ -1,9 +1,11 @@
+import NacelleProtocol
 import SwiftUI
 
 /// Réglages : l'adresse du Mac en repli et l'appairage (spec découverte et QR § 8.1).
 struct SettingsView: View {
     @Binding var settings: ConnectionSettings
     let isPaired: Bool
+    let onPair: (PairingLink) -> Void
     let onForget: () -> Void
     @Environment(\.dismiss) private var dismiss
     @State private var draft = ConnectionSettings()
@@ -11,6 +13,7 @@ struct SettingsView: View {
     // du focus), et le pavé numérique n'a pas de Retour ; « Enregistrer » perdrait la dernière saisie.
     @State private var ptzdPortText = ""
     @State private var confirmForget = false
+    @State private var showScanner = false
 
     /// Les réglages tels que saisis, port compris.
     private var edited: ConnectionSettings {
@@ -39,6 +42,9 @@ struct SettingsView: View {
                 }
                 Section {
                     LabeledContent("État", value: isPaired ? "Appairé" : "Non appairé")
+                    Button("Scanner le QR code") {
+                        showScanner = true
+                    }
                     if isPaired {
                         Button("Oublier cet appairage", role: .destructive) {
                             confirmForget = true
@@ -61,6 +67,13 @@ struct SettingsView: View {
                     .disabled(!edited.isValid)
                 }
             }
+            .sheet(isPresented: $showScanner) {
+                QRScannerView { link in
+                    showScanner = false
+                    onPair(link)
+                    dismiss()
+                }
+            }
             .confirmationDialog("Oublier l'appairage ?", isPresented: $confirmForget, titleVisibility: .visible) {
                 Button("Oublier", role: .destructive) {
                     onForget()
PATCH
```

- [ ] **Étape 4 : Relancer les tests**

```bash
(cd ios && xcodegen -q && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build 2>&1 | grep -E 'error:|warning:|Test run with|TEST (SUCCEEDED|FAILED)' | grep -v -E 'ld: warning|appintents')
```

Attendu : tout passe (iOS : 78 tests), aucun avertissement ni erreur.

- [ ] **Étape 5 : Commiter et pousser**

```bash
git add README.md \
    ios/Nacelle/App/AppModel.swift \
    ios/Nacelle/Control/ControlScreen.swift \
    ios/Nacelle/Control/StatusBanner.swift \
    ios/Nacelle/PTZ/PTZClient.swift \
    ios/Nacelle/Pairing/Discovery.swift \
    ios/Nacelle/Pairing/PairingScreen.swift \
    ios/Nacelle/Pairing/QRScannerView.swift \
    ios/Nacelle/Settings/SettingsView.swift \
    ios/NacelleTests/AppModelTests.swift \
    ios/NacelleTests/DiscoveryTests.swift \
    ios/NacelleTests/PTZClientTests.swift \
    ios/project.yml
git diff --cached --name-only -z | xargs -0 grep -n -E '([0-9]{1,3}\.){3}[0-9]{1,3}|\.ts\.net|/Users/[A-Za-z]|/private/tmp/' | grep -v -E '127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.|169\.254\.|100\.64\.0\.[01]|10\.0\.0\.5|172\.(16|31|32)\.|192\.168\.0\.|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net' || echo "Aucune donnée locale."
git commit -F - <<'EOF'
App PTZBot : écran d'appairage et lecteur de QR code

Co-Authored-By: <modèle qui commite> <noreply@anthropic.com>
EOF
git push
```

Attendu : « Aucune donnée locale. » avant le commit. Les fichiers supprimés à l'étape 1 ou 3 sont déjà indexés par `git rm`.

### Tâche 6 : Mise en service et essais avec Majid

**But :** installer le nouveau `ptzd` et PTZBot ensemble, refaire l'appairage de l'iPhone de Majid par QR code, puis vérifier le pilotage et la vidéo en Wi-Fi et en 4G par la route du NAS (spec découverte et QR § 10 et § 11).

**Fichiers :** aucun dans le dépôt.

- [ ] **Étape 1 : Prévenir Majid, puis installer le côté Mac**

Prévenir Majid : le service redémarre, l'app actuelle perd la main jusqu'à l'étape 3.

```bash
scripts/install-mac.sh
```

```bash
sleep 5; tail -6 ~/Library/Logs/obsbot-nacelle/ptzd.log | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g'
```

```bash
dns-sd -B _nacelle._tcp & sleep 3; kill $!
```

Attendu : « ptzd démarre. », les écoutes, l'annonce Bonjour, et un service « PTZBot sur <nom du Mac> ».

L'ancien code à 6 chiffres n'existe plus : retirer son fichier, devenu inutile.

```bash
rm -f ~/Library/Application\ Support/ObsbotNacelle/pairing.json
```

- [ ] **Étape 2 : Compiler et installer PTZBot sur l'iPhone (déverrouillé, en Wi-Fi)**

`<UDID>` : l'identifiant de l'iPhone de Majid dans `xcrun devicectl list devices`.

```bash
(cd ios && xcodegen -q) && xcodebuild build -project ios/Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS,id=<UDID>' -derivedDataPath ios/.build -allowProvisioningUpdates | tail -1
```

```bash
xcrun devicectl device install app --device <UDID> ios/.build/Build/Products/Debug-iphoneos/Nacelle.app
```

- [ ] **Étape 3 : L'appairage existant tient (Majid ; la caméra peut bouger à la prise en main)**

Majid ouvre PTZBot (nouveau nom sur l'écran d'accueil) : l'écran de pilotage s'affiche directement, avec la vidéo et le joystick en Wi-Fi.

- [ ] **Étape 4 : Nouvel appairage par QR code (Majid)**

1. Majid touche Réglages › **Oublier cet appairage** : l'écran « Recherche du Mac à proximité… » apparaît et liste « PTZBot sur <nom du Mac> ».
2. Retirer l'ancienne entrée de l'iPhone :

```bash
~/Library/Application\ Support/ObsbotNacelle/bin/ptzd devices
```

```bash
~/Library/Application\ Support/ObsbotNacelle/bin/ptzd revoke <début de l'identifiant de l'iPhone>
```

3. Majid lance lui-même, dans le Terminal du Mac (le QR code doit s'afficher sur son écran), `~/Library/Application\ Support/ObsbotNacelle/bin/ptzd pair`, puis touche **Scanner le QR code** dans PTZBot, autorise l'appareil photo et vise le QR. Prévenir : la caméra peut bouger à la connexion.
4. Vérifier :

```bash
~/Library/Application\ Support/ObsbotNacelle/bin/ptzd devices; grep -E "Appairage|appairé|authentifié" ~/Library/Logs/obsbot-nacelle/ptzd.log | tail -4 | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g'
```

Attendu : une seule ligne pour l'iPhone ; « Appairage ouvert (…) », « Appareil appairé : … », « Client N authentifié : … ». Dans PTZBot, Réglages › Adresse du Mac (repli) contient l'adresse locale du Mac si le champ était vide.

- [ ] **Étape 5 : Essais (Majid ; la caméra bouge)**

Noter le résultat de chaque point dans le rapport :
1. **QR déjà utilisé** : Majid scanne de nouveau le même QR depuis Réglages : « QR code refusé : relance ptzd pair » ; un passage en arrière-plan puis le retour rétablissent la connexion.
2. **Wi-Fi, Tailscale coupé sur l'iPhone** : vidéo en moins de 10 s, joystick, zoom, vie privée.
3. **4G (Wi-Fi coupé), Tailscale actif, routes du NAS acceptées** : vidéo, joystick, zoom, vie privée, avec l'adresse locale dans le champ.
4. **Arrière-plan 10 s puis retour**, en Wi-Fi puis en 4G : tout revient seul.
5. **Chemin de la vidéo en 4G** : pendant la lecture, regarder l'adresse distante du client WebRTC dans l'API locale de go2rtc ; noter si elle est celle du NAS (route de sous-réseau) ou une adresse Tailscale (100.64.0.0/10, relais Tailscale) :

```bash
curl -s http://127.0.0.1:1984/api/streams | python3 -m json.tool | grep -i -E 'remote|addr'
```

6. Pendant les essais : `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log`. À la fin, les PID de go2rtc et de coreaudiod sont inchangés (`pgrep -x go2rtc`, `pgrep -x coreaudiod`).
