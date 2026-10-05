# OBSBOT Nacelle

Piloter à distance la nacelle d'une OBSBOT Tiny 2 depuis l'iPhone.

La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](https://github.com/AlexxIT/go2rtc), et vers HomeKit via Homebridge. HomeKit ne sait pas piloter un pan/tilt/zoom : ce projet ajoute ce qui manque.

> Projet personnel, sans lien avec OBSBOT.

## Statut

**Conception.** Le test de faisabilité est terminé : voir [docs/spike/2026-10-05-faisabilite.md](docs/spike/2026-10-05-faisabilite.md). La spec et le plan suivront dans `docs/`.

## Architecture prévue

```
iPhone : app SwiftUI                         Mac (celui de go2rtc)
┌───────────────────────────┐            ┌──────────────────────────────────┐
│ Vidéo WebRTC  ────────────┼─ offre ───▶│ go2rtc (inchangé)                │
│                           │◀─ images ──│   └─ ffmpeg ◀── Tiny 2 (USB)     │
│ Joystick, zoom,           │            │                                  │
│ vie privée  ──────────────┼─ WebSocket▶│ ptzd                             │
│                           │◀─ état ────│   └─ commandes UVC ──▶ Tiny 2    │
└───────────────────────────┘            └──────────────────────────────────┘
                 tout passe par Tailscale, à la maison comme dehors
```

- **`ptzd`** : un service macOS en Swift, lancé par launchd. C'est le seul à envoyer des commandes de nacelle à la caméra. Il ne touche jamais au flux vidéo.
- **go2rtc** : la vidéo arrive dans l'app directement en WebRTC. Aucun changement de configuration n'est nécessaire.
- **L'app iOS** : la vidéo en plein écran, avec par-dessus un joystick pour le pan et le tilt, le zoom et un mode vie privée.

## Contenu

| Chemin | Rôle |
|---|---|
| `docs/spike/` | Résultats du test de faisabilité |
| `spike/uvc-probe/` | Sonde UVC **jetable** utilisée pour ce test. Ce n'est pas le code du service. |

## Licence

MIT. Voir [LICENSE](LICENSE).
