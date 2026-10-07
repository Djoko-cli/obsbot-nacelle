# OBSBOT Nacelle

Piloter à distance la nacelle d'une OBSBOT Tiny 2 depuis l'iPhone.

La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](https://github.com/AlexxIT/go2rtc), et vers HomeKit via Homebridge. HomeKit ne sait pas piloter un pan/tilt/zoom : ce projet ajoute ce qui manque.

> Projet personnel, sans lien avec OBSBOT.

## Statut

- **Côté Mac** : l'app **PTZBot pour Mac**, qui contient `ptzd` et `obsbot-ai`, s'installe avec `scripts/install-mac.sh` (voir plus bas). Le SDK OBSBOT s'installe ensuite depuis l'app.
- **App iOS** (PTZBot) : s'installe depuis Xcode sur l'iPhone (voir « App iOS » plus bas).

Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [spec de l'accès local](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [spec de la découverte et du QR code](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [spec de l'app Mac](docs/superpowers/specs/2026-10-06-app-mac-design.md) · [spec de ptzd dans l'app](docs/superpowers/specs/2026-10-07-ptzd-dans-app-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [plan de l'accès local](docs/superpowers/plans/2026-10-06-acces-local.md) · [plan de la découverte et du QR code](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [plan de l'app Mac](docs/superpowers/plans/2026-10-06-app-mac.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).

## Architecture

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
- **`obsbot-ai`** : un petit utilitaire, rangé lui aussi dans l'app, qui allume ou coupe le suivi IA de la caméra avec le SDK OBSBOT, puis se termine. `ptzd` le lance au premier mouvement du joystick (le suivi contrerait les mouvements), à l'entrée en vie privée et sur ordre des apps. Le SDK n'est jamais dans l'app : `ptzd` donne à `obsbot-ai` la copie autorisée par l'utilisateur, `~/Library/Application Support/ObsbotNacelle/sdk/libdev.dylib`.
- **PTZBot pour Mac** : une app dans la barre des menus, qui lance `ptzd` et lui parle par 127.0.0.1 : appairage par QR code, appareils et clients connectés, expulsion, vie privée et suivi IA (voir « App Mac » plus bas).
- **go2rtc** : `ptzd` lui relaie l'offre WebRTC de l'app ; les images vont ensuite directement de go2rtc à l'iPhone. Voir « go2rtc » plus bas pour le fermer au réseau local.

## Installer le côté Mac

Prérequis :

- un Mac Apple Silicon sous macOS 15 ou plus récent, avec Xcode et [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) ;
- Tailscale sur le Mac pour piloter hors de la maison (sans lui, `ptzd` n'écoute que sur 127.0.0.1 et sur le réseau local) ;
- le SDK OBSBOT, à demander sur [obsbot.com/sdk](https://www.obsbot.com/sdk), décompressé dans `vendor/obsbot-sdk/` : ses en-têtes servent à compiler `obsbot-ai`, et `macos/arm64-release/libdev.dylib` à l'édition de liens (il n'est jamais copié dans l'app). Il n'est pas versionné : sa licence n'en autorise pas la redistribution ;
- OBSBOT Center fermé : ouvert, il fausse la relecture du tilt.

Puis installer :

```bash
scripts/install-mac.sh
```

Le script compile l'app, avec `ptzd` et `obsbot-ai` dans `Contents/Helpers`, ferme l'app en cours, l'installe dans `~/Applications/PTZBot.app` et la lance. Il ne touche ni à launchd ni aux fichiers de `~/Library/Application Support/ObsbotNacelle/`.

Au premier lancement :

- **Ancienne installation.** Si l'agent launchd `io.github.djoko-cli.obsbot-nacelle.ptzd` d'une version précédente est là, PTZBot propose de le remplacer. **Remplacer** l'arrête, renomme sa plist en `.plist.bak`, met les anciens binaires de `bin/` à la corbeille et reprend le SDK de `lib/`. Les iPhone appairés et les réglages sont conservés. **Plus tard** garde l'ancien `ptzd` (le panneau affiche « Ancienne installation ») ; la question revient au lancement suivant.
- **`config.json`.** S'il manque, PTZBot le crée avec l'adresse Tailscale du Mac, ou sur 127.0.0.1 seulement sans Tailscale (le panneau le signale).
- **SDK OBSBOT.** Dans le panneau, **SDK OBSBOT** › **Installer le SDK…** : choisir l'archive `.zip` reçue d'OBSBOT, son dossier décompressé ou `libdev.dylib`. PTZBot prend `macos/arm64-release/libdev.dylib`, le chemin que la compilation utilise ; les autres copies de l'archive sont listées et ignorées. La fenêtre montre l'architecture, la signature, la provenance et la quarantaine ; **Autoriser ce SDK** copie le fichier dans `sdk/`, retire la quarantaine de cette copie seulement, puis vérifie qu'`obsbot-ai` le charge. Sans SDK, tout marche sauf le suivi IA.
- **Autorisations.** macOS demande l'accès au réseau local pour PTZBot (`ptzd` en dépend) : répondre **Autoriser**. À la première connexion de l'iPhone, il peut aussi demander s'il faut autoriser `ptzd` à accepter des connexions entrantes : répondre **Autoriser**. La question peut revenir après une réinstallation, car le binaire change.

## Réglages (`config.json`)

| Clé | Rôle | Défaut |
|---|---|---|
| `listenAddress` | Adresse Tailscale du Mac, ou 127.0.0.1 sans Tailscale ; créée par PTZBot au premier lancement | obligatoire |
| `port` | Port WebSocket | 1985 |
| `panMaxSpeed`, `tiltMaxSpeed` | Vitesses UVC maximales (pan 1–80, tilt 1–120) | 40, 60 |
| `panDirection`, `tiltDirection` | Sens de chaque axe, +1 ou -1 | +1, +1 |
| `aiPath` | Chemin de `obsbot-ai`, relatif à `~/Library/Application Support/ObsbotNacelle` (ou absolu) ; quand PTZBot lance `ptzd`, c'est `--ai` qui compte (l'ancienne clé `aiOffPath` est lue si elle manque, sauf si elle nomme `obsbot-ai-off`) | `bin/obsbot-ai` |
| `localNetwork` | Écoute et annonce Bonjour sur le Wi-Fi et l'Ethernet | `true` |
| `go2rtcAPI` | API locale de go2rtc, pour relayer la vidéo | `http://127.0.0.1:1984` |
| `streamName` | Flux go2rtc relayé | `obsbot` |

Après une modification, relancer le service : dans le panneau, éteindre puis rallumer **Service ptzd**.

## Diagnostic

| Besoin | Commande |
|---|---|
| Journal du service | `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log` |
| Sortie du SDK | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai.log` |
| Lire la position de la caméra | `~/Applications/PTZBot.app/Contents/Helpers/ptzd uvc get` |
| Appareils appairés | `~/Applications/PTZBot.app/Contents/Helpers/ptzd devices` |
| Voir l'annonce Bonjour | `dns-sd -B _nacelle._tcp` (Ctrl-C pour arrêter) |
| Dialoguer avec le service | `swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"adminWatch"}' wait 2` |

Le Mac ne peut pas se joindre lui-même par son adresse Tailscale : en local, passer par 127.0.0.1.

`ptzd pair`, `ptzd devices` et `ptzd revoke` restent utilisables en ligne de commande avec le binaire de l'app ; `ptzd pair` demande que le service tourne, donc que PTZBot soit ouvert.

## App Mac (PTZBot)

Installée par `scripts/install-mac.sh`, elle vit dans la barre des menus (icône de la Tiny 2), sans icône dans le Dock. L'iPhone ne pilote la caméra que pendant que PTZBot est ouvert : **Ouvrir à la connexion** en fait l'usage normal. Son panneau montre :

- l'interrupteur **Service ptzd**, retenu d'un lancement à l'autre, et l'état de `ptzd` (« Actif », « Démarrage… », « Arrêté », « Relancé après un arrêt inattendu (n) », « Ne répond pas » avec un lien vers son journal) et de la caméra. Au-delà de 5 arrêts en 2 min, PTZBot cesse de relancer `ptzd` : « ptzd s'arrête sans cesse : ouvrez le journal ». Il ne le relance pas non plus si un autre `ptzd` tourne déjà (verrou `ptzd.lock` ou port de 127.0.0.1 pris : « Le port 1985 est déjà pris… »), si `config.json` est invalide ou si ses arguments sont refusés ;
- la ligne **SDK OBSBOT** (« Prêt », « Absent », « En quarantaine », « Incompatible », « Ne se charge pas », « obsbot-ai introuvable »), **Installer le SDK…** et, quand le SDK est prêt, **Changer…** ; sans SDK prêt, **Suivi IA** est grisé (« SDK OBSBOT requis ») ;
- les interrupteurs **Vie privée** et **Suivi IA** (le suivi affiche le dernier ordre : l'état réel ne se lit pas, un geste devant la caméra peut le changer) ;
- les clients connectés, avec **Expulser** : la connexion est coupée et l'appareil refusé 10 min (tant que `ptzd` tourne), sans perdre son appairage ;
- **Appairer un iPhone…** : le QR code en image, valable 5 min ; fermer la fenêtre l'annule ;
- **Appareils…** : les appareils appairés, **Débloquer** et **Retirer…** (l'appareil est retiré et ses connexions coupées tout de suite) ;
- **Ouvrir à la connexion** : l'app se lance à l'ouverture de session (macOS peut demander un accord dans Réglages › Général › Ouverture) ;
- **Quitter** : arrête `ptzd` (6 s au plus), puis l'app.

Si l'accès au réseau local est refusé à PTZBot, le panneau l'indique, avec un bouton vers les réglages de confidentialité : les iPhone ne trouvent alors le Mac que par Tailscale.

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
   ~/Applications/PTZBot.app/Contents/Helpers/ptzd pair
   ```

   Puis, dans l'app de l'iPhone, toucher **Scanner le QR code** et viser l'écran du Mac (iOS demande l'accès à l'appareil photo). La clé de l'iPhone reste dans sa Secure Enclave ; le Mac garde sa clé publique et le secret du canal chiffré du réseau local, dans `devices.json` (droits 600). L'app retient l'adresse locale du Mac dans Réglages › Adresse du Mac (repli).

   Mise à jour depuis une version qui demandait le nom Tailscale : le champ « Adresse du Mac (repli) » le garde. Pour passer à l'adresse locale (qui sert aussi en 4G par la route de sous-réseau), vider ce champ et toucher Enregistrer avant de scanner : l'app y retiendra l'adresse locale du Mac.
6. Hors de la maison, l'app joint cette même adresse par Tailscale si un appareil du tailnet publie le réseau local (routage de sous-réseau) et si l'iPhone accepte les routes. Sinon, mettre dans le champ le nom Tailscale du Mac (champ `DNSName`, sans le point final, de `tailscale status --self --peers=false --json` sur le Mac) : l'app le joint par l'écoute Tailscale de `ptzd`, sans TLS.

Retirer un iPhone : dans PTZBot sur le Mac, **Appareils…** › **Retirer…** ; ses connexions sont coupées tout de suite, après un message qui l'informe : l'iPhone connecté oublie son appairage et revient à l'écran d'appairage. Un iPhone hors connexion à ce moment l'apprend à sa prochaine connexion par Tailscale ; sur le réseau local, il est simplement refusé et affiche « Mac injoignable » : sur lui, « Oublier cet appairage », puis scanner un nouveau QR code. En ligne de commande, `ptzd devices` donne le début de son identifiant, puis `ptzd revoke <début>` ; ses connexions déjà ouvertes durent alors jusqu'à leur fin. Depuis l'iPhone, « Oublier cet appairage » le retire aussi de la liste du Mac quand il est connecté.

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

Dans PTZBot pour Mac, décocher **Ouvrir à la connexion**, puis **Quitter** (`ptzd` s'arrête avec l'app), et mettre `~/Applications/PTZBot.app` à la corbeille.

Les données restent dans `~/Library/Application Support/ObsbotNacelle/` (réglages, iPhone appairés, SDK) et les journaux dans `~/Library/Logs/obsbot-nacelle/`, tant qu'on ne les supprime pas :

```bash
rm -r ~/Library/Application\ Support/ObsbotNacelle ~/Library/Logs/obsbot-nacelle
```

Après une migration, la plist de l'ancien agent reste en `~/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.ptzd.plist.bak` : elle peut être supprimée.

## Contenu

| Chemin | Rôle |
|---|---|
| `Packages/NacelleProtocol/` | Messages échangés entre l'app et `ptzd`, partagés par les deux |
| `mac/ptzd/` | Le service : logique (`PTZCore`), appairage et authentification (`PTZAuth`), accès USB (`CUVC`, `UVCCamera`), serveur WebSocket et écoute locale (`PTZServer`) |
| `mac/ai/` | L'utilitaire `obsbot-ai` (C++, demande le SDK en local) |
| `mac/app/` | L'app PTZBot pour Mac : `project.yml` (xcodegen), interface (`PTZBot/`), logique testée (`PTZBotKit/`), compilation des utilitaires (`build-helpers.sh`) et vérification du paquet (`check-bundle.sh`) |
| `mac/tools/` | Client WebSocket de test |
| `ios/` | L'app iOS : `project.yml` (xcodegen), sources et tests |
| `scripts/install-mac.sh` | Compilation et installation de l'app sur le Mac |
| `docs/` | Spec, plans et tests de faisabilité |
| `spike/` | Sondes **jetables** des tests de faisabilité |

## Licence

MIT. Voir [LICENSE](LICENSE).
