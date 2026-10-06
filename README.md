# OBSBOT Nacelle

Piloter à distance la nacelle d'une OBSBOT Tiny 2 depuis l'iPhone.

La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](https://github.com/AlexxIT/go2rtc), et vers HomeKit via Homebridge. HomeKit ne sait pas piloter un pan/tilt/zoom : ce projet ajoute ce qui manque.

> Projet personnel, sans lien avec OBSBOT.

## Statut

- **Côté Mac** : `ptzd`, `obsbot-ai` et l'app **PTZBot pour Mac** s'installent avec `scripts/install-mac.sh` (voir plus bas).
- **App iOS** (PTZBot) : s'installe depuis Xcode sur l'iPhone (voir « App iOS » plus bas).

Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [spec de l'accès local](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [spec de la découverte et du QR code](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [spec de l'app Mac](docs/superpowers/specs/2026-10-06-app-mac-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [plan de l'accès local](docs/superpowers/plans/2026-10-06-acces-local.md) · [plan de la découverte et du QR code](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [plan de l'app Mac](docs/superpowers/plans/2026-10-06-app-mac.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).

## Architecture

```
iPhone : app SwiftUI                         Mac (celui de go2rtc)
┌───────────────────────────┐            ┌──────────────────────────────────┐
│ Joystick, zoom,           │            │ ptzd                             │
│ vie privée, offre vidéo ──┼─ WebSocket▶│   ├─ commandes UVC ──▶ Tiny 2    │
│                           │ authentifié│   ├─ lance obsbot-ai (SDK)       │
│                           │◀─ état ────│   └─ relaie l'offre ──┐          │
│                           │            │                       ▼          │
│ Vidéo WebRTC ◀────────────┼─ images ───│ go2rtc (API en local) ◀── ffmpeg │
└───────────────────────────┘            └──────────────────────────────────┘
   à la maison : Wi-Fi (Bonjour, adresse locale) ; dehors : la même adresse par Tailscale
```

- **`ptzd`** : un service macOS en Swift, lancé par launchd. C'est le seul à envoyer des commandes de nacelle à la caméra, en UVC. Il écoute sur l'adresse Tailscale du Mac, sur 127.0.0.1, et sur ses interfaces Wi-Fi et Ethernet, où il s'annonce par Bonjour (`_nacelle._tcp`). Chaque iPhone est appairé une fois, sur le réseau local, en scannant le QR code affiché par l'app Mac (ou `ptzd pair`) ; ensuite, il signe un défi à chaque connexion. Sur le réseau local, tout passe en plus dans un canal TLS : pendant l'appairage, sa clé est le secret du QR code ; ensuite, une clé propre à chaque iPhone, remise à l'appairage. Seules les connexions venues de 127.0.0.1 sont dispensées du défi.
- **`obsbot-ai`** : un petit utilitaire qui allume ou coupe le suivi IA de la caméra avec le SDK OBSBOT, puis se termine. `ptzd` le lance au premier mouvement du joystick (le suivi contrerait les mouvements), à l'entrée en vie privée et sur ordre des apps.
- **PTZBot pour Mac** : une app dans la barre des menus, qui parle à `ptzd` par 127.0.0.1 : appairage par QR code, appareils et clients connectés, expulsion, vie privée et suivi IA (voir « App Mac » plus bas).
- **go2rtc** : `ptzd` lui relaie l'offre WebRTC de l'app ; les images vont ensuite directement de go2rtc à l'iPhone. Voir « go2rtc » plus bas pour le fermer au réseau local.

## Installer le côté Mac

Prérequis :

- un Mac Apple Silicon sous macOS 15 ou plus récent, avec Xcode et [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) ;
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

Le script compile `ptzd` et `obsbot-ai`, les installe dans `~/Library/Application Support/ObsbotNacelle/`, crée `config.json` avec l'adresse Tailscale du Mac, puis charge l'agent launchd `io.github.djoko-cli.obsbot-nacelle.ptzd`. Il compile aussi l'app PTZBot pour Mac, l'installe dans `~/Applications/PTZBot.app` et la lance.

À la première connexion de l'iPhone, macOS peut demander s'il faut autoriser `ptzd` à accepter des connexions entrantes : répondre **Autoriser**. La question peut revenir après une réinstallation, car le binaire change.

## Réglages (`config.json`)

| Clé | Rôle | Défaut |
|---|---|---|
| `listenAddress` | Adresse IPv4 Tailscale du Mac | obligatoire |
| `port` | Port WebSocket | 1985 |
| `panMaxSpeed`, `tiltMaxSpeed` | Vitesses UVC maximales (pan 1–80, tilt 1–120) | 40, 60 |
| `panDirection`, `tiltDirection` | Sens de chaque axe, +1 ou -1 | +1, +1 |
| `aiPath` | Chemin de `obsbot-ai`, relatif au dossier d'installation (l'ancienne clé `aiOffPath` est lue si elle manque, sauf si elle nomme `obsbot-ai-off`) | `bin/obsbot-ai` |
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
| Sortie du SDK | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai.log` |
| Lire la position de la caméra | `~/Library/Application\ Support/ObsbotNacelle/bin/ptzd uvc get` |
| Appareils appairés | `~/Library/Application\ Support/ObsbotNacelle/bin/ptzd devices` |
| Voir l'annonce Bonjour | `dns-sd -B _nacelle._tcp` (Ctrl-C pour arrêter) |
| Dialoguer avec le service | `swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"adminWatch"}' wait 2` |

Le Mac ne peut pas se joindre lui-même par son adresse Tailscale : en local, passer par 127.0.0.1.

## App Mac (PTZBot)

Installée par `scripts/install-mac.sh`, elle vit dans la barre des menus (icône de la Tiny 2), sans icône dans le Dock. Son panneau montre :

- l'état de `ptzd` (« Actif », « Démarrage… », « Ne répond pas » avec un lien vers son journal) et de la caméra ;
- les interrupteurs **Vie privée** et **Suivi IA** (le suivi affiche le dernier ordre : l'état réel ne se lit pas, un geste devant la caméra peut le changer) ;
- les clients connectés, avec **Expulser** : la connexion est coupée et l'appareil refusé 10 min (tant que `ptzd` tourne), sans perdre son appairage ;
- **Appairer un iPhone…** : le QR code en image, valable 5 min ; fermer la fenêtre l'annule ;
- **Appareils…** : les appareils appairés, **Débloquer** et **Retirer…** (l'appareil est retiré et ses connexions coupées tout de suite) ;
- **Ouvrir à la connexion** : l'app se lance à l'ouverture de session (macOS peut demander un accord dans Réglages › Général › Ouverture).

L'app passe par la connexion de confiance de `ptzd` (127.0.0.1) : tout programme du Mac peut en faire autant.

Tests : `(cd mac/app/PTZBotKit && swift test)`.

## App iOS

Prérequis : Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), un identifiant Apple (un compte gratuit suffit), le côté Mac installé, et Tailscale sur l'iPhone pour piloter hors de la maison.

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
   ~/Library/Application\ Support/ObsbotNacelle/bin/ptzd pair
   ```

   Puis, dans l'app de l'iPhone, toucher **Scanner le QR code** et viser l'écran du Mac (iOS demande l'accès à l'appareil photo). La clé de l'iPhone reste dans sa Secure Enclave ; le Mac garde sa clé publique et le secret du canal chiffré du réseau local, dans `devices.json` (droits 600). L'app retient l'adresse locale du Mac dans Réglages › Adresse du Mac (repli).

   Mise à jour depuis une version qui demandait le nom Tailscale : le champ « Adresse du Mac (repli) » le garde. Pour passer à l'adresse locale (qui sert aussi en 4G par la route de sous-réseau), vider ce champ et toucher Enregistrer avant de scanner : l'app y retiendra l'adresse locale du Mac.
6. Hors de la maison, l'app joint cette même adresse par Tailscale si un appareil du tailnet publie le réseau local (routage de sous-réseau) et si l'iPhone accepte les routes. Sinon, mettre dans le champ le nom Tailscale du Mac (champ `DNSName`, sans le point final, de `tailscale status --self --peers=false --json` sur le Mac) : l'app le joint par l'écoute Tailscale de `ptzd`, sans TLS.

Retirer un iPhone : dans PTZBot sur le Mac, **Appareils…** › **Retirer…** ; ses connexions sont coupées tout de suite. En ligne de commande, `ptzd devices` donne le début de son identifiant, puis `ptzd revoke <début>` ; ses connexions déjà ouvertes durent alors jusqu'à leur fin. L'iPhone retiré affiche ensuite « Mac injoignable » : sur lui, « Oublier cet appairage », puis scanner un nouveau QR code.

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

## Désinstaller

Dans PTZBot pour Mac, décocher **Ouvrir à la connexion**, puis **Quitter**, et :

```bash
rm -r ~/Applications/PTZBot.app
```

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
| `mac/ai/` | L'utilitaire `obsbot-ai` (C++, demande le SDK en local) |
| `mac/app/` | L'app PTZBot pour Mac : `project.yml` (xcodegen), interface (`PTZBot/`) et logique testée (`PTZBotKit/`) |
| `mac/launchd/` | Modèle du plist de l'agent launchd |
| `mac/tools/` | Client WebSocket de test |
| `ios/` | L'app iOS : `project.yml` (xcodegen), sources et tests |
| `scripts/install-mac.sh` | Installation sur le Mac |
| `docs/` | Spec, plans et tests de faisabilité |
| `spike/` | Sondes **jetables** des tests de faisabilité |

## Licence

MIT. Voir [LICENSE](LICENSE).
