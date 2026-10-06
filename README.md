# OBSBOT Nacelle

Piloter à distance la nacelle d'une OBSBOT Tiny 2 depuis l'iPhone.

La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](https://github.com/AlexxIT/go2rtc), et vers HomeKit via Homebridge. HomeKit ne sait pas piloter un pan/tilt/zoom : ce projet ajoute ce qui manque.

> Projet personnel, sans lien avec OBSBOT.

## Statut

- **Côté Mac** : `ptzd` et `obsbot-ai-off` s'installent avec `scripts/install-mac.sh` (voir plus bas).
- **App iOS** : s'installe depuis Xcode sur l'iPhone (voir « App iOS » plus bas).

Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [spec de l'accès local](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [plan de l'accès local](docs/superpowers/plans/2026-10-06-acces-local.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).

## Architecture

```
iPhone : app SwiftUI                         Mac (celui de go2rtc)
┌───────────────────────────┐            ┌──────────────────────────────────┐
│ Joystick, zoom,           │            │ ptzd                             │
│ vie privée, offre vidéo ──┼─ WebSocket▶│   ├─ commandes UVC ──▶ Tiny 2    │
│                           │ authentifié│   ├─ lance obsbot-ai-off (SDK)   │
│                           │◀─ état ────│   └─ relaie l'offre ──┐          │
│                           │            │                       ▼          │
│ Vidéo WebRTC ◀────────────┼─ images ───│ go2rtc (API en local) ◀── ffmpeg │
└───────────────────────────┘            └──────────────────────────────────┘
   à la maison : Wi-Fi (Bonjour) ; dehors : Tailscale
```

- **`ptzd`** : un service macOS en Swift, lancé par launchd. C'est le seul à envoyer des commandes de nacelle à la caméra, en UVC. Il écoute sur l'adresse Tailscale du Mac, sur 127.0.0.1, et sur ses interfaces Wi-Fi et Ethernet, où il s'annonce par Bonjour (`_nacelle._tcp`). Chaque iPhone doit être appairé une fois, par Tailscale ; ensuite, il signe un défi à chaque connexion. Sur le réseau local, tout passe en plus dans un canal TLS dont la clé, propre à chaque iPhone, est remise à l'appairage. Seules les connexions venues de 127.0.0.1 sont dispensées du défi.
- **`obsbot-ai-off`** : un petit utilitaire qui coupe le suivi IA de la caméra avec le SDK OBSBOT, puis se termine. `ptzd` le lance à chaque prise en main.
- **go2rtc** : `ptzd` lui relaie l'offre WebRTC de l'app ; les images vont ensuite directement de go2rtc à l'iPhone. Voir « go2rtc » plus bas pour le fermer au réseau local.

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
| `localNetwork` | Écoute et annonce Bonjour sur le Wi-Fi et l'Ethernet | `true` |
| `go2rtcAPI` | API locale de go2rtc, pour relayer la vidéo | `http://127.0.0.1:1984` |
| `streamName` | Flux go2rtc relayé | `obsbot` |

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
| Appareils appairés | `~/Library/Application\ Support/ObsbotNacelle/bin/ptzd devices` |
| Voir l'annonce Bonjour | `dns-sd -B _nacelle._tcp` (Ctrl-C pour arrêter) |
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
   (cd ios && xcodegen)
   ```

   ```bash
   xcodebuild build -project ios/Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS,id=<UDID>' -derivedDataPath ios/.build -allowProvisioningUpdates
   ```

   ```bash
   xcrun devicectl device install app --device <UDID> ios/.build/Build/Products/Debug-iphoneos/Nacelle.app
   ```

3. Au premier lancement, iOS demande de faire confiance au développeur : Réglages › Général › VPN et gestion de l'appareil.
4. Dans l'app, saisir le nom Tailscale du Mac (champ `DNSName`, sans le point final, de `tailscale status --self --peers=false --json` sur le Mac). Le port par défaut (1985) convient.
5. Appairer l'iPhone : sur le Mac, afficher un code (valable 5 min, un seul usage, 3 essais) :

   ```bash
   ~/Library/Application\ Support/ObsbotNacelle/bin/ptzd pair
   ```

   Puis, avec Tailscale actif sur l'iPhone (l'appairage ne passe que par Tailscale), le saisir dans Réglages › Appairage et toucher **Enregistrer**. La clé de l'iPhone reste dans sa Secure Enclave ; le Mac garde sa clé publique et le secret du canal chiffré du réseau local, dans `devices.json` (droits 600).
6. À la maison, l'app trouve le Mac sur le Wi-Fi, sans Tailscale : au premier essai, iOS demande l'accès au réseau local, répondre **Autoriser**.

Retirer un iPhone : `ptzd devices` donne le début de son identifiant, puis `ptzd revoke <début>`. Ses connexions déjà ouvertes durent jusqu'à leur fin ; relancer le service pour les couper tout de suite.

Avec un compte Apple gratuit, l'app expire au bout de 7 jours : refaire l'étape 2.

Icône (facultative) : déposer un catalogue `ios/Local/Assets.xcassets` contenant un jeu d'icônes `AppIcon` (une image 1024 × 1024), et ajouter `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` à `ios/Config/Local.xcconfig`. Le dossier `ios/Local/` n'est pas versionné : sans lui, l'app se compile avec l'icône par défaut.

Tests : `(cd ios && xcodegen && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build)`.

## go2rtc

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
```

- go2rtc dispense les clients locaux (127.0.0.1) du mot de passe RTSP : les sources `exec:` qui publient sur `{output}` continuent de fonctionner sans changement.
- Un client RTSP du réseau, comme Homebridge, doit alors donner l'identifiant et le mot de passe dans l'adresse du flux : `rtsp://<identifiant>:<mot de passe>@<Mac>:8554/obsbot`.
- Le port WebRTC 8555 reste ouvert : sans offre négociée par `ptzd`, il ne donne aucune image.
- `go2rtc.yaml` contient le mot de passe RTSP : le passer en droits 600 (`chmod 600 go2rtc.yaml`).
- Le flux RTSP vers Homebridge, identifiants compris, circule en clair sur le réseau local : un appareil qui intercepte ce trafic peut les lire, ainsi que les images.
- Ne jamais exposer 127.0.0.1:1985 au réseau, par exemple avec `tailscale serve` ou `ssh -L` : les connexions venues de 127.0.0.1 sont dispensées d'authentification, tout client distant passé par là piloterait la caméra.

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
| `mac/ptzd/` | Le service : logique (`PTZCore`), appairage et authentification (`PTZAuth`), accès USB (`CUVC`, `UVCCamera`), serveur WebSocket et écoute locale (`PTZServer`) |
| `mac/ai-off/` | L'utilitaire `obsbot-ai-off` (C++, demande le SDK en local) |
| `mac/launchd/` | Modèle du plist de l'agent launchd |
| `mac/tools/` | Client WebSocket de test |
| `ios/` | L'app iOS : `project.yml` (xcodegen), sources et tests |
| `scripts/install-mac.sh` | Installation sur le Mac |
| `docs/` | Spec, plans et tests de faisabilité |
| `spike/` | Sondes **jetables** des tests de faisabilité |

## Licence

MIT. Voir [LICENSE](LICENSE).
