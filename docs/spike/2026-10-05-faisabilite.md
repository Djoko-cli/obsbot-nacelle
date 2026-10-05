# Test de faisabilité : pilotage UVC et vidéo WebRTC

Date : 2026-10-05. Matériel : OBSBOT Tiny 2 en USB sur un Mac Apple Silicon sous macOS 27.0, diffusée par go2rtc 1.9.14 via ffmpeg (`-f avfoundation`, encodage `h264_videotoolbox`).

Sonde utilisée : [`spike/uvc-probe/uvc-probe.c`](../../spike/uvc-probe/uvc-probe.c). C'est du code **jetable**.

## Questions posées

1. La caméra accepte-t-elle les commandes de nacelle **pendant que ffmpeg capture** ?
2. Accepte-t-elle un pilotage en **vitesse**, ou seulement des positions absolues ?
3. Le tilt descend-il assez bas pour un **mode vie privée** ?
4. La vidéo **WebRTC** de go2rtc passe-t-elle par Tailscale ?

## Méthode

- **Accès USB.** Requêtes de contrôle UVC sur le pipe par défaut, avec `IOUSBDeviceInterface245::DeviceRequestTO` (IOKit). Le périphérique n'est **pas ouvert en exclusivité**, ce qui laisse le pilote vidéo d'Apple et ffmpeg tranquilles.
- **Adressage.** `wIndex = (id de l'entité << 8) | n° de l'interface VideoControl`, et `wValue = sélecteur << 8`.
- **Type de requête.** `0xA1` pour les lectures (`GET_CUR/MIN/MAX/RES/DEF`), `0x21` pour `SET_CUR`.
- **Capture pendant le test.** Un lecteur RTSP temporaire, vidéo seule, garde le producer go2rtc actif.
- **Observation.** Une image est prise avant et après chaque commande, et assemblée en planche. Ces images ne sont pas versionnées.

## Ce que la caméra expose

USB : VID `0x3564`, PID `0xFEF8`. L'interface VideoControl porte le numéro 0.

| Entité | Id | Contenu |
|---|---|---|
| Camera Terminal | 1 | `bmControls = 0x023e3e` : exposition, mise au point, **Zoom abs/rel**, **PanTilt abs/rel**, Roll abs, mise au point auto |
| Processing Unit | 3 | Réglages d'image |
| Extension Unit | 2 | GUID `91721e9a436883466d9239bc7906ee49`, 19 commandes OBSBOT propriétaires |

| Commande | Sélecteur | Plage |
|---|---|---|
| PanTilt absolu | `0x0D` (8 octets, en secondes d'arc) | pan ±130°, tilt ±90°, pas de 1°, défaut 0/0 |
| PanTilt en vitesse | `0x0E` (4 octets : sens, vitesse pan, sens, vitesse tilt) | vitesse pan 1–80, tilt 1–120 |
| Zoom absolu | `0x0B` (2 octets) | 0–100, pas de 1 |
| Zoom en vitesse | `0x0C` (3 octets) | vitesse jusqu'à 100 |
| Privacy | `0x11` | **non pris en charge** |

## Résultats

### Suivi IA actif

| Constat | Détail |
|---|---|
| Les commandes passent | Toutes renvoient `kIOReturnSuccess`. La nacelle **bouge réellement** : l'image change et montre un flou de mouvement. |
| Le suivi annule tout | Il **recentre sur la personne en 1 à 4 s**, après chaque commande absolue comme après chaque commande en vitesse. |
| Lecture faussée | `GET_CUR` ne reflète pas la position réelle. |

### Suivi IA coupé

| Vérification | Résultat |
|---|---|
| Tenue de position | Pan à 30° : l'image reste identique 3 s puis 8 s après. |
| Relecture du pan | Exacte : 30°, puis -48° après un mouvement en vitesse. |
| Relecture du tilt | **Pas fiable** : elle reste figée à -57° alors que la caméra va physiquement de -90° à +90°. |
| Mode vitesse | Vitesse pan 40 pendant environ 1 s, soit à peu près 78° de course. La position tient après l'arrêt (sens 0). |
| Convention de signe | Un pan en vitesse avec le sens +1 fait **baisser** l'angle absolu. Les deux conventions sont à étalonner. |
| Tilt à -90° | Plus qu'un aplat gris flou : rien d'identifiable à l'image. |
| Tilt à +90° | Plafond, aplat clair. |

### Santé du système

Pendant les deux séries, go2rtc, coreaudiod et le producer vidéo ont gardé leur PID, même avec OBSBOT Center ouvert à côté. Aucune erreur n'est apparue.

### WebRTC

- **Réponse de go2rtc.** Il répond `201` à une offre envoyée sur `POST /api/webrtc?src=…` avec `Content-Type: application/sdp`. La vidéo est en H.264, profil **Baseline**, niveau 4.0, que l'iPhone décode sans difficulté.
- **Candidats ICE.** go2rtc propose des candidats `host` sur **toutes** les interfaces du Mac, **y compris l'adresse Tailscale**, en UDP et en TCP sur le port 8555. **Aucune modification de `go2rtc.yaml` n'est nécessaire.**
- **Audio.** Le son du flux est en AAC, que WebRTC ne transporte pas. L'app sera sans son, sauf si go2rtc le transcode en Opus.

## Conclusions pour la conception

1. **Joystick.** Il pilote **en vitesse** (`0x0E`). Relâcher le joystick envoie l'arrêt, et le service arrête aussi le mouvement de lui-même s'il ne reçoit plus de commande.
2. **Zoom.** Commande absolue `0x0B`, de 0 à 100.
3. **Vie privée.** Tilt à -90° par commande absolue, avec mémorisation de la position précédente. **Ce mode ne coupe pas le micro** : HomeKit continue de recevoir le son.
4. **Ne pas se fier à `GET_CUR` pour le tilt.** Le service garde sa propre idée de la position et ne relit la caméra que pour le pan.
5. **Suivi IA.** S'il se réactive, par un geste ou un redémarrage, il annule toutes les commandes. Le couper exige les commandes propriétaires, via l'Extension Unit 2 (`aiSetWorkModeR` dans la bibliothèque OBSBOT). Le SDK officiel s'obtient sur demande : <https://www.obsbot.com/sdk>.

## Questions ouvertes

- Le réglage « suivi IA coupé » survit-il à un débranchement ou à un redémarrage de la caméra ?
- D'où vient le blocage de la relecture du tilt ? Est-il lié à OBSBOT Center ouvert pendant le test ?
- Quelle est la latence de bout en bout, de l'iPhone à la nacelle, via Tailscale ?
