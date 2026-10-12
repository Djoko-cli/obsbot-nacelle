# Spec : go2rtc dans PTZBot pour Mac (sous-projet B3)

Embarque go2rtc dans PTZBot.app. PTZBot lance go2rtc, le surveille, génère sa configuration et en montre l'état. Fait
suite à la [spec ptzd dans l'app](2026-10-07-ptzd-dans-app-design.md) (B1) et à la
[spec distribution](2026-10-08-distribution-design.md) (B2), qui restent valables pour tout ce qui n'est pas repris ici.
Conçue avec Majid le 12/10/2026, section par section. Elle tient compte de la passation de la session go2rtc
(`~/Dev/go2rtc mac/PASSATION-go2rtc-dans-PTZBot.md`, hors dépôt).

## 1. Objectif

- **PTZBot devient le seul propriétaire de la caméra.** go2rtc ne tourne que pendant que PTZBot est ouvert, comme ptzd.
  La règle « aucun accès à la caméra sans l'app » vaut alors partout.
- **Une fonction de PTZBot pour tout utilisateur**, et pas seulement pour l'installation de Majid. L'app génère la
  configuration, détecte la caméra et ffmpeg, et dit clairement ce qui manque.
- **Les autorisations caméra et micro au nom de PTZBot**, identité stable et signée Developer ID, au lieu du binaire ad
  hoc `a.out` d'aujourd'hui.
- **Aucune régression** sur ce que la session go2rtc a établi du 4 au 8 octobre (§ 9).

## 2. Choix de Majid (12/10/2026)

| Question | Réponse |
|---|---|
| Cycle de vie | **Processus enfant de PTZBot**, comme ptzd. Quitter PTZBot arrête go2rtc, et donc la caméra HomeKit. Renverse le choix du 07/10, où go2rtc devait tourner app fermée. |
| Public | **Tout utilisateur** du dépôt public : configuration générée, README bilingue. |
| ffmpeg | **Celui de Homebrew, détecté**, jamais embarqué : la version Homebrew est GPL. Message clair s'il manque. |
| Configuration | **Générée par PTZBot**, avec un **fichier personnalisé** possible (mode expert) et l'**import** d'une configuration existante. |
| Panneau | Un interrupteur, une ligne d'état avec le nombre de clients, le détail au survol, l'alerte coreaudiod seulement en cas de besoin. |
| Réglages | Un onglet « Caméra », avec les boutons « Ouvrir le journal » et « Ouvrir l'interface web ». |
| Allègement du panneau | **Pastilles vertes** : l'état normal de chaque service est une pastille verte. Une ligne d'état n'apparaît que hors de l'état normal. |
| Ordre | Après le passage au Developer ID (1.0.7, fait). B3 sort en **1.1.0**. |

Hors périmètre : embarquer ffmpeg, réparer coreaudiod automatiquement (il faudrait les droits root, ce qui demande une
conception à part), monter la version de go2rtc, et modifier la configuration de Homebridge.

## 3. Architecture

### 3.1 Le binaire go2rtc

- **Emplacement** : `Contents/Helpers/go2rtc`, à côté de ptzd et talkd.
- **Version figée** : 1.9.14, celle qui tourne aujourd'hui chez Majid. Une montée de version est un changement à part.
- **Provenance** : à la compilation, `build-helpers.sh` télécharge l'archive macOS de la même architecture que l'app
  (arm64) depuis les versions officielles de `AlexxIT/go2rtc` sur GitHub.
  - Il vérifie son **empreinte SHA-256**, écrite dans le dépôt (`mac/app/go2rtc.sha256`), et refuse tout écart.
  - Il garde l'archive en cache dans le dossier de compilation : pas de téléchargement à chaque fois.
- **Licence** : MIT. Le texte va dans `Contents/Resources/go2rtc-LICENSE.txt`.
- **Signature** : la publication le signe comme ptzd et talkd, avec le Developer ID, le runtime renforcé, aucun droit,
  puis l'horodatage. `check-bundle.sh` et la publication le comptent parmi les utilitaires.

### 3.2 Le gardien : go2rtc meurt avec PTZBot

ptzd surveille son parent (`--parent`) et s'arrête si PTZBot disparaît, même en cas de plantage. go2rtc ne sait pas le
faire : après un plantage de PTZBot, il resterait orphelin, la caméra ouverte.

**Choix proposé** : un petit utilitaire `gardien`, en Swift, dans `Contents/Helpers`.
- **Usage** : `gardien --parent <pid> --arret <secondes> -- <programme> <arguments…>`. Il lance le programme en
  processus enfant, transmet SIGTERM et SIGINT, et rend son code de sortie.
- **Si le parent disparaît**, il envoie SIGTERM au programme, attend `--arret` secondes, puis SIGKILL.
- **Surveillance** par `kqueue` (`EVFILT_PROC`, `NOTE_EXIT`) sur le pid du parent. Pas de sondage.
- PTZBot lance donc `gardien --parent <pid de PTZBot> --arret 10 -- go2rtc -config <yaml>`.

L'alternative, rejetée : à son lancement, PTZBot tue un go2rtc orphelin de la session précédente, connu par un fichier
de pid. Elle laisse la caméra ouverte entre le plantage et la relance de l'app.

### 3.3 Le superviseur de go2rtc

`Go2RTCSupervisor` (PTZBotKit), sur le modèle de `ServiceSupervisor` (ptzd), avec les mêmes doublures de processus et
d'horloge pour les tests.
- **États** : désactivé, démarrage, actif, relance (n), échec (raison).
- **Relance** : délais 1, 2, 4, 8, 16 puis 30 s. Au-delà de 5 arrêts inattendus en 120 s, l'état passe à « échec :
  ouvrez le journal ».
- **Arrêt en douceur** : SIGTERM, puis SIGKILL seulement après **10 s** au moins. go2rtc a ainsi le temps d'arrêter ses
  ffmpeg par SIGTERM (`#killsignal=15`). C'est le délai d'arrêt de l'ancienne plist (`ExitTimeOut` ≥ 10 s).
- **Journal** : `go2rtc.log`, dans le dossier des journaux de PTZBot, à côté de `ptzd.log`. Sortie et erreurs y sont
  ajoutées.
- **Interrupteur** : réglage `go2rtcEnabled`, retenu d'un lancement à l'autre, **éteint par défaut**. Il ne doit pas
  prendre la caméra de quelqu'un qui a déjà son go2rtc.
- **Quitter PTZBot** attend la fin de ptzd et de go2rtc. Quand go2rtc est allumé, la confirmation de « Quitter » dit :
  « Quitter PTZBot arrête aussi la caméra HomeKit. »
- **Environnement** : le `PATH` de go2rtc commence par le dossier de ffmpeg, puis `/usr/bin:/bin`. C'est nécessaire à
  la source `ffmpeg:obsbot#audio=opus`.

### 3.4 Autorisations caméra et micro

- go2rtc et ses ffmpeg descendent de PTZBot : macOS attribue leurs accès à **PTZBot**, le processus responsable.
- `Info.plist` reçoit `NSCameraUsageDescription` et `NSMicrophoneUsageDescription`, au vouvoiement, traduits
  (`InfoPlist.xcstrings`) :
  - « PTZBot diffuse l'image de votre caméra OBSBOT vers HomeKit et l'app iPhone. »
  - « PTZBot diffuse le son du micro de votre caméra OBSBOT vers HomeKit et l'app iPhone. »
- **Droits du runtime renforcé, sur l'app seulement** : `com.apple.security.device.camera` et
  `com.apple.security.device.audio-input`.
  - La publication contrôle aujourd'hui que les utilitaires n'ont aucun droit : on garde ce contrôle.
  - Elle accepte désormais ces deux droits sur l'app, et seulement eux, en plus de ceux qu'elle autorise déjà.
- **Effet attendu** : à la première ouverture de la caméra, « PTZBot souhaite accéder à la caméra », puis la même
  demande pour le micro. Un refus est repéré dans le journal (§ 5).

### 3.5 ffmpeg

- **Recherche**, dans l'ordre : le chemin réglé dans l'onglet « Caméra », `/opt/homebrew/bin/ffmpeg`, puis
  `/usr/local/bin/ffmpeg`. Il faut un exécutable, qui répond à `-version`.
- **Absent** : go2rtc n'est pas lancé, et l'état dit « ffmpeg introuvable ». L'onglet « Caméra » donne la commande
  `brew install ffmpeg`.
- **Chemin absolu** écrit dans le yaml (`ffmpeg: bin:` et les sources `exec:`).

### 3.6 Les appareils

- **Détection** par `AVCaptureDevice.DiscoverySession`, qui liste caméras et micros sans demander d'autorisation.
- **Choix par défaut** : la première caméra et le premier micro dont le nom contient « OBSBOT ». Sinon, l'état dit
  « Caméra OBSBOT absente ».
- L'onglet « Caméra » permet un autre choix. Le nom retenu est écrit tel quel dans l'entrée `-i` d'ffmpeg, avec les
  guillemets échappés.

## 4. Configuration générée

- **Fichier** : `~/Library/Application Support/ObsbotNacelle/go2rtc.yaml`, en mode 600, écrit de façon atomique. Il
  contient le mot de passe RTSP : jamais dans le dépôt, jamais dans un journal.
- **Réglages** (`Go2RTCSettings`, hors du yaml) :
  - identifiant et mot de passe RTSP ;
  - ports RTSP (8554) et WebRTC (8555) ;
  - résolution et cadence (1920x1080 à 30 i/s) ;
  - débit (4 Mb/s, plafond 6 Mb/s, tampon 2 Mb) ;
  - noms de la caméra et du micro, chemin de ffmpeg.

  Le mot de passe n'est rangé que dans le yaml (mode 600), puisque go2rtc doit le lire en clair. L'onglet le relit de
  là.
- **Modèle** : le pipeline en service chez Majid, paramétré. Points obligatoires :
  - `api.listen: "127.0.0.1:1984"`, fixe : ptzd relaie la vidéo de l'app iOS par cette API ;
  - `rtsp.listen: ":<port>"`, avec `username` et `password` ; `webrtc.listen: ":<port>"` ;
  - `ffmpeg.bin: <chemin absolu>` ;
  - `preload: obsbot:` : les deux ffmpeg restent ouverts en permanence ;
  - un stream **`obsbot`**, nom dont dépendent ptzd (`streamName`) et Homebridge, en trois entrées :
    1. la vidéo : `exec:` ffmpeg, avfoundation, `-pixel_format nv12`, `h264_videotoolbox -realtime 1 -g <cadence>
       -bf 0`, débit, `-bsf:v dump_extra=freq=keyframe`, `-an`, `-rtsp_transport tcp -f rtsp {output}`, puis
       `#timeout=30s#killsignal=15` ;
    2. le son : `exec:` ffmpeg, avfoundation `":<micro>"`, `aresample=async=1000:first_pts=0`, AAC 48 kHz stéréo
       128 kb/s, `-vn`, puis les mêmes suffixes ;
    3. `ffmpeg:obsbot#audio=opus`, pour le WebRTC de l'app iOS ;
  - les entrées `exec:` en **`- >-`** (bloc replié **sans** saut de ligne final), jamais `- >`. Sinon go2rtc lit le
    signal `15\n`, envoie le signal 0, et le ffmpeg vidéo fuit (correctif du 04/10) ;
  - `log.level: info`.
- **Régénération** : à chaque changement de réglage appliqué, et au lancement si le modèle a changé avec une nouvelle
  version de PTZBot. Un yaml identique n'est pas réécrit.
- **Fichier personnalisé** (mode expert) : un interrupteur et un chemin. PTZBot lance alors go2rtc sur ce fichier, sans
  jamais l'écrire. Les vérifications de ports et d'appareils sont sautées, et l'état le dit : « fichier personnalisé ».
- **Import d'une configuration existante** : PTZBot lit un yaml choisi par l'utilisateur et en reprend l'identifiant, le
  mot de passe RTSP, les ports, et, s'ils sont reconnus, les noms des appareils et le chemin de ffmpeg. Il montre ce
  qu'il a repris avant d'appliquer. Le fichier importé n'est pas modifié.

## 5. Pannes et états

| Situation | Détection | Ligne d'état (hors état normal) |
|---|---|---|
| ffmpeg absent | § 3.5, avant le lancement | « ffmpeg introuvable » |
| Port pris (8554, 8555 ou 1984) | essai d'ouverture du port juste avant le lancement | « Port 8554 déjà utilisé : un autre go2rtc tourne-t-il ? » |
| Caméra OBSBOT absente | § 3.6 ; puis l'API (`/api/streams`) : le stream n'a pas de producteur actif | « Caméra OBSBOT absente » |
| Accès refusé | journal de go2rtc (erreur d'autorisation d'avfoundation) | « Accès à la caméra refusé », avec un bouton qui ouvre Réglages › Confidentialité |
| Arrêts répétés | § 3.3 | « go2rtc s'arrête sans cesse : ouvrez le journal » |
| coreaudiod bloqué | plus d'un ffmpeg vidéo enfant, ou `exec: timeout` dans le journal depuis moins de 2 min | ligne **orange** « coreaudiod ne répond pas : la caméra est bloquée », avec un bouton « Copier la commande de réparation » (`sudo killall -9 coreaudiod`) |

- **État normal** : la pastille verte, et « · N clients » au survol, avec le détail par protocole (par exemple
  « RTSP ×1, WebRTC ×1 »).
- **Clients** : PTZBot lit `GET http://127.0.0.1:1984/api/streams` toutes les 2 s, **seulement pendant que le panneau
  est ouvert**. Il compte les consommateurs du stream `obsbot` par type.
- **coreaudiod** : PTZBot ne le répare jamais lui-même, puisqu'il faudrait les droits root.

## 6. Interface

### 6.1 Panneau

- **Une rangée « go2rtc »** dans la section « Service », juste après ptzd : interrupteur, pastille, et ligne d'état
  hors état normal (§ 5).
- **Pastilles vertes pour tous les services** : ptzd, go2rtc, Talkback, SDK OBSBOT. L'état normal (actif, prêt,
  installé) est une pastille verte, sans ligne. Toute autre situation garde sa ligne d'état actuelle, et l'orange pour
  ce qui demande l'attention.
- Le détail des clients est au survol de la rangée (`help`).

### 6.2 Réglages

La fenêtre passe à deux onglets :
1. **« Général »** : le contenu actuel (mises à jour, ouverture à la connexion, langue).
2. **« Caméra »** :
   - **Diffusion** : identifiant, mot de passe (champ masqué), résolution et cadence, débit ;
   - **Appareils** : caméra et micro, avec les OBSBOT détectés par défaut ;
   - **ffmpeg** : chemin détecté, bouton « Choisir… », et la commande `brew install ffmpeg` s'il manque ;
   - **Avancé** : ports RTSP et WebRTC ; « Utiliser un fichier de configuration personnalisé » et son chemin ;
     « Importer une configuration existante… » ;
   - **Boutons** : « Ouvrir le journal » (Console, sur `go2rtc.log`) et « Ouvrir l'interface web » (le navigateur, sur
     `http://127.0.0.1:1984`).
   - **« Appliquer »** régénère le yaml et relance go2rtc, après l'avertissement « Le flux HomeKit sera coupé quelques
     secondes. » Un réglage qui ne change rien ne relance rien.

Tous les textes sont au vouvoiement et traduits en anglais (catalogues `Localizable.xcstrings`).

## 7. Mise en service chez Majid (migration)

À faire ensemble, Majid présent. La règle « jamais deux go2rtc en même temps » vaut à chaque étape.
1. Installer la 1.1.0. go2rtc est éteint par défaut, et l'ancien agent `com.majid.go2rtc` tourne toujours.
2. Dans l'onglet « Caméra », **importer** `/opt/homebrew/etc/go2rtc.yaml`, vérifier ce qui est repris, puis appliquer.
   Rien n'est lancé tant que l'interrupteur est éteint.
3. **Majid** : `launchctl bootout gui/$(id -u)/com.majid.go2rtc`, puis la plist renommée en `.bak`. C'est un réglage
   système, il le fait lui-même.
4. **Aussitôt**, allumer go2rtc dans PTZBot. Accepter les demandes d'accès à la caméra et au micro pour PTZBot.
5. Vérifier :
   - HomeKit (image et son) ;
   - l'app iOS (vidéo WebRTC et son) ;
   - l'absence de redémarrage en boucle des ffmpeg ;
   - un seul ffmpeg vidéo ;
   - coreaudiod sain.
6. **Prévenir la session go2rtc** :
   - ses scripts de collecte trouvaient go2rtc par le label launchd (`G2W_LABEL`). Ils devront chercher le processus
     `…/PTZBot.app/Contents/Helpers/go2rtc` ;
   - le script `cam` devient obsolète.

Aucun label personnel n'entre dans le code public : la migration est un geste de Majid, guidé par cette procédure.

## 8. Publication et compilation

- **`build-helpers.sh`** : téléchargement et vérification de go2rtc (§ 3.1), compilation du `gardien`, copie dans
  `Contents/Helpers`.
- **`check-bundle.sh`** : go2rtc, `gardien` et la licence de go2rtc sont présents ; le SDK OBSBOT reste absent.
- **Publication** (`outils/publication.py`) :
  - `go2rtc` et `gardien` sont signés comme les autres utilitaires ;
  - les droits caméra et micro sont autorisés sur l'app (§ 3.4) ;
  - le contrôle de fuite et la notarisation s'appliquent au tout.
- **Notes de version 1.1.0**, en anglais puis en français : go2rtc dans PTZBot, ffmpeg à installer avec Homebrew,
  demande d'accès à la caméra et au micro au nom de PTZBot, et « Quitter arrête la caméra HomeKit ».
- **README**, en anglais puis en français : la section go2rtc est réécrite (go2rtc fourni par PTZBot, onglet
  « Caméra », import d'une configuration, ffmpeg). La configuration externe garde un paragraphe, puisque
  l'interrupteur éteint laisse fonctionner un go2rtc à soi.

## 9. Ce qui ne doit pas régresser

| Point | Où c'est tenu |
|---|---|
| go2rtc est le **seul** processus qui ouvre la caméra et le micro | refus si un port est pris (§ 5), interrupteur éteint par défaut |
| `preload: obsbot:` conservé | modèle (§ 4) |
| Entrées en `- >-`, jamais `- >` | modèle, et un test qui compare le yaml généré à un modèle exact |
| Pas de SIGKILL sur un ffmpeg qui capture | arrêt en douceur sur 10 s (§ 3.3), `killsignal=15` |
| Stream `obsbot`, port 8554, mêmes identifiants | modèle et import (§ 4) |
| Mot de passe hors du dépôt | yaml en mode 600 dans Application Support ; aucune valeur réelle dans les tests |
| Priorité de go2rtc | processus enfant d'une app au premier plan. La passation demandait `ProcessType: Interactive` sous launchd : à vérifier au banc (son et vidéo sans saccade) |

## 10. Tests

- **Unitaires** (Swift Testing, attentes bornées, données fictives) :
  - **yaml généré** : comparé à un modèle exact, entrées `- >-`, échappement des noms et du mot de passe ;
  - **import** : yaml complet, partiel, illisible ;
  - **recherche de ffmpeg** : ordre, exécutable absent, chemin réglé ;
  - **détection des appareils** : doublure de la liste AVFoundation ;
  - **superviseur** : lancement, relance, échec, arrêt en douceur (10 s avant SIGKILL), quitter, interrupteur ;
  - **gardien** : parent disparu, puis SIGTERM puis SIGKILL après le délai ; SIGTERM transmis ; code de sortie rendu ;
  - **lecture de l'API** : clients par type, stream sans producteur ;
  - **détecteur coreaudiod** et **ports pris** ;
  - **pastilles** : état normal sans ligne, les autres avec.
- **Banc avec Majid** (§ 7, puis) :
  - quitter et relancer PTZBot : go2rtc et ses ffmpeg s'arrêtent sans SIGKILL ;
  - tuer PTZBot (`kill -9`) : le gardien arrête go2rtc ;
  - débrancher puis rebrancher la caméra ;
  - refuser puis accorder l'accès à la caméra ;
  - fichier personnalisé ;
  - nouvelle demande d'accès après une mise à jour (il ne doit pas y en avoir : identité Developer ID stable).

## 11. Risques

- **Autorisations** : que macOS attribue bien les accès des ffmpeg à PTZBot à travers le gardien et go2rtc. On le
  vérifie en tout premier, par un essai jetable avant le prototype : PTZBot de développement signé Developer ID,
  gardien, go2rtc et ffmpeg sur un autre port, puis la caméra.
- **Priorité** : sans `ProcessType: Interactive`, le son ou l'image pourraient se dégrader. À mesurer au banc. Si c'est
  le cas, le gardien peut demander une priorité plus haute (`setpriority`, QoS) pour go2rtc.
- **coreaudiod** : le va-et-vient de clients CoreAudio reste le déclencheur suspecté. `preload` et l'arrêt en douceur
  le limitent ; le détecteur le signale.

## 12. Résultat de l'essai des autorisations (12/10/2026)

- **Fait.** Le ffmpeg de capture avait bien l'app pour processus responsable, mais **macOS a attribué l'accès à la caméra au programme qui l'ouvre, ffmpeg**, et non à l'app (essai de la tâche 0 du plan). Le § 3.4 ne se vérifie donc pas : la demande porte le nom « ffmpeg », et l'autorisation suit le binaire de Homebrew. Elle est redemandée après chaque `brew upgrade ffmpeg`.
- **Décision de Majid : B3 tel quel.** Les droits caméra et micro de l'app et ses textes d'explication restent : ils préparent l'évolution suivante.
- **Évolution au backlog : un utilitaire de capture signé de PTZBot** (AVFoundation, VideoToolbox et AudioToolbox, flux vers go2rtc par `exec:`). Il remplacerait ffmpeg pour la capture, pour que l'accès soit attribué à PTZBot et survive aux mises à jour. ffmpeg ne servirait plus qu'à l'Opus.
