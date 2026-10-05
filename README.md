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
