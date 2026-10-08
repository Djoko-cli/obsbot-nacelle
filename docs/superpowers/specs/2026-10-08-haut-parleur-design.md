# Spec : haut-parleur du Mac (`talkd`), retour audio de la caméra

Ajoute le **retour audio** : une voix envoyée depuis l'app Maison (bouton micro de la caméra) sort par les haut-parleurs du Mac où la caméra est branchée. Un daemon sans interface, `talkd`, reçoit la voix par le réseau local et la joue. Son interrupteur vit dans le panneau de PTZBot pour Mac. Validée par Majid le 2026-10-08, section par section.

Conçue dans la session « go2rtc macOS + coreaudiod », qui connaît Homebridge et les blocages de coreaudiod. **Réalisée par la session PTZBot**, au moment qui convient à son calendrier.

## 1. Objectif

- **Parler par la caméra depuis Maison.** Le bouton micro de la caméra, dans l'app Maison, fait sortir la voix par les haut-parleurs du Mac. C'est une **exigence** de Majid, pas une option.
- **Une expérience transparente.** Aucune fenêtre, aucune action côté Mac : le daemon attend, joue la voix quand elle arrive, puis se tait.
- **Ne pas fragiliser coreaudiod.** Il s'est figé deux fois sous macOS 27 (voir § 10). Le daemon reste un seul client CoreAudio, permanent, et n'ajoute aucun va-et-vient.

## 2. Périmètre

Dans cette spec :
- `talkd`, le daemon : réception, filtrage, détection de voix, lecture, volume minimum, journal ;
- son agent launchd embarqué dans PTZBot.app et son **interrupteur** dans le panneau ;
- la ligne à ajouter dans la config Homebridge (sur le NAS) ;
- les tests et la mise en service mesurée.

Hors périmètre, pour plus tard :
- **la voix depuis PTZBot iOS** (bouton « parler », WebRTC vers go2rtc, puis relais vers `talkd` depuis 127.0.0.1). Elle reste possible sans changer `talkd` (§ 5.6) ;
- **l'atténuation des autres apps** pendant la voix, comme le fait Maison sur Mac. C'est au backlog, avec un test préalable pour savoir comment Maison s'y prend.

## 3. Choix de Majid

| Sujet | Choix |
|---|---|
| Sortie | **Haut-parleurs intégrés du Mac**, quelle que soit la sortie par défaut de Réglages (« pour l'instant ») |
| Volume | **Volume actuel, avec un minimum garanti** : sous le seuil (30 % par défaut) ou en sourdine, il est remonté le temps de la voix, puis rétabli |
| Sources autorisées | **Le NAS (Homebridge) et 127.0.0.1**, rien d'autre |
| Forme | **Daemon sans interface**, et un **interrupteur** dans le panneau de PTZBot |
| Où vit l'interrupteur | **Dans PTZBot**, pas dans une app à part |
| Partage du travail | La session go2rtc conçoit ; **la session PTZBot réalise** |
| Atténuation des autres apps | **Pas dans la v1** |

## 4. Points à vérifier en tête du plan (essais courts)

1. **Sortie sur un périphérique précis.** Lire avec `AVAudioEngine` (ou une `AudioUnit` HAL) sur les haut-parleurs intégrés, choisis par leur type de transport (`kAudioDeviceTransportTypeBuiltIn`) et non par leur rang, alors que la sortie par défaut est ailleurs.
2. **Arrêter puis redémarrer la lecture ne crée pas de nouveau client coreaudiod.** Il faut le mesurer, par exemple en comptant les `AddClient` de coreaudiod dans `log show` sur une dizaine de cycles. Si un cycle crée un client, la lecture reste ouverte en permanence, en silence (§ 5.3).
3. **Volume des haut-parleurs intégrés.** Lire et écrire le volume principal et la sourdine sans droits root, puis être prévenu d'un changement fait par l'utilisateur.
4. **Agent `SMAppService.agent`** depuis PTZBot.app, signé comme B1 le fait. L'agent doit tourner **quand PTZBot est fermé** et redémarrer avec la session.
5. **Pare-feu macOS.** L'agent reçoit de l'UDP entrant sur le port 1986. On note ce que macOS demande, et à quel moment.
6. **Côté NAS (au banc, avec Majid).**
   - Le ffmpeg de Homebridge décode bien l'AAC-ELD de HomeKit.
   - Il faut savoir si les paquets arrivent **en continu pendant toute la session live**, silence compris, ou **seulement pendant l'appui** sur le bouton micro. La détection de voix (§ 5.2) couvre les deux cas.

## 5. Architecture

### 5.1 Circulation du son

```
iPhone, app Maison (bouton micro)
   │  SRTP, AAC-ELD 16 kHz mono (HomeKit)
   ▼
NAS : Homebridge, ffmpeg de retour lancé par homebridge-camera-ffmpeg à chaque session live
   │  décodage libfdk_aac, puis PCM 16 bits little-endian, 16 kHz, mono
   │  UDP vers le Mac, port 1986, paquets de 20 ms (640 octets)
   ▼
Mac : talkd
   filtre des sources → détection de voix → une source à la fois
   → tampon court → volume minimum → haut-parleurs intégrés
```

### 5.2 `talkd`

Une cible Swift à part (`mac/talkd/`), sur le modèle de `ptzd` : sans AppKit, et testable sans son réel.

- **Réception.** Une socket UDP sur le port configuré (1986 par défaut), sur toutes les interfaces. Le daemon ne répond jamais.
- **Filtre.** Tout paquet dont l'adresse source n'est pas dans `allowedSources` est ignoré et compté. Tout paquet de taille impaire, vide ou supérieure à 4 Ko est ignoré aussi.
- **Détection de voix.** Un paquet « contient de la voix » si son énergie (RMS) dépasse un seuil bas, réglable. Une **prise de parole** commence au premier paquet avec voix, et finit après **2 s sans voix**.
- **Une source à la fois.** La source qui ouvre une prise de parole garde le haut-parleur jusqu'à sa fin. Les paquets des autres sources sont ignorés et comptés.
- **Tampon.** Il vise environ 60 ms. Au-delà d'environ 200 ms d'avance, le daemon jette le plus ancien, pour garder une voix en direct. Aucun rééchantillonnage maison : le moteur audio convertit 16 kHz vers la fréquence du périphérique.
- **Silence.** Pendant une prise de parole, les paquets sans voix sont joués tels quels, pour ne pas hacher la voix. Hors prise de parole, les paquets reçus ne sont pas joués.

### 5.3 Sortie audio et coreaudiod

- **Un seul client CoreAudio, pour toute la vie du process.** La lecture démarre à la première prise de parole. Elle s'arrête après **10 s** sans voix, pour ne pas garder les haut-parleurs occupés en permanence. Ce choix dépend du point 2 du § 4 : si l'arrêt et le redémarrage recréent un client, la lecture reste ouverte en permanence.
- **Haut-parleurs intégrés** : le périphérique de type `BuiltIn` qui a des flux de sortie. Le daemon le retrouve quand la liste des périphériques change.
- **Échec de la sortie**, par exemple quand coreaudiod ne répond pas. Le daemon journalise l'erreur, **n'insiste pas en boucle**, et réessaie à la prochaine prise de parole. Il ne se relance jamais lui-même : c'est launchd qui le relance s'il s'arrête.

### 5.4 Volume minimum

- **Au début d'une prise de parole**, le daemon lit le volume et la sourdine des haut-parleurs intégrés. S'ils sont en sourdine ou sous `volumeFloor` (0,30 par défaut), il les règle à `volumeFloor` et les remet en route, en mémorisant l'état d'origine.
- **À la fin de la prise de parole**, il rétablit l'état d'origine.
- **Si l'utilisateur change le volume ou la sourdine pendant la parole**, le daemon le détecte et ne rétablit rien : le réglage de l'utilisateur l'emporte.
- Si les haut-parleurs sont déjà au-dessus du seuil, le daemon n'y touche pas.

### 5.5 Réglages et journal

- **Réglages** : `~/Library/Application Support/ObsbotNacelle/talkd.json`, hors du dépôt.
  ```json
  { "port": 1986, "allowedSources": ["127.0.0.1", "<IP du NAS>"], "volumeFloor": 0.30, "voiceThreshold": 0.01 }
  ```
  - Un fichier absent ou invalide n'empêche pas le démarrage : le daemon prend les valeurs par défaut, avec 127.0.0.1 seul, et le journalise.
  - Un fichier modifié est relu au prochain démarrage du daemon.
- **Journal** : `~/Library/Logs/obsbot-nacelle/talkd.log`. Il contient :
  - le démarrage du daemon et ses réglages ;
  - chaque prise de parole (source, début, durée) ;
  - les changements de volume et leur rétablissement ;
  - le nombre de paquets rejetés (source refusée, taille anormale, source concurrente) et jetés (tampon) ;
  - les erreurs de sortie.

  **Aucun son n'est enregistré.**

### 5.6 Voix depuis PTZBot iOS (plus tard, sans changer `talkd`)

go2rtc 1.9.14 accepte un canal de retour sur une source `exec` (`#backchannel=1`). La commande reçoit alors l'audio du client sur son entrée standard. Un `exec:` ffmpeg qui renvoie ce son en PCM 16 kHz vers `udp://127.0.0.1:1986` suffira. Ce ffmpeg ne touche pas au son du Mac : il ne crée aucun client CoreAudio. Ce sera une spec à part.

## 6. Interface (panneau de PTZBot pour Mac)

- Un interrupteur **« Haut-parleur »**, avec une ligne d'état sous l'interrupteur :
  - « Prêt » : l'agent est inscrit et tourne ;
  - « Désactivé » ;
  - « Autorisation requise », avec un bouton qui ouvre Réglages › Général › Ouverture, comme pour `SMAppService.mainApp` en A ;
  - « En lecture » pendant une prise de parole, si l'état se lit simplement : un fichier d'état écrit par `talkd`. Sinon, cette ligne est omise.
- L'interrupteur inscrit ou désinscrit l'agent (`SMAppService.agent`). **L'agent continue de tourner quand PTZBot est fermé.**
- Les textes sont au « vous ».

## 7. Agent launchd

- La plist est dans `Contents/Library/LaunchAgents/`, avec le label `io.github.djoko-cli.obsbot-nacelle.talkd` et `BundleProgram` vers le binaire `talkd` de l'app.
- `RunAtLoad`, `KeepAlive`, et `ThrottleInterval` d'au moins 10 s. Une relance en rafale créerait une rafale de clients CoreAudio.
- **`ProcessType: Interactive`.** Avec `Standard`, le son des enfants de go2rtc s'était dégradé sous launchd, et avec `Background`, la vidéo saccadait.

## 8. Côté Homebridge (NAS)

- Dans la config de la caméra (`homebridge-camera-ffmpeg` 4.1.0), ajouter :
  ```
  "returnAudioTarget": "-f s16le -ar 16000 -ac 1 udp://<IP du Mac>:1986?pkt_size=640"
  ```
  - Cette option active l'audio bidirectionnel annoncé à HomeKit : le bouton micro apparaît dans Maison.
  - Le plugin la marque « EXPERIMENTAL - WIP ».
  - Il découpe la commande sur les espaces, sans gérer les guillemets. Celle-ci ne contient aucun argument avec espace.
- Le conteneur Homebridge doit être en réseau `host`, pour que l'iPhone joigne le port de retour choisi par le plugin. À vérifier au banc.
- **La config Homebridge ne se modifie qu'avec l'accord de Majid, diff en main**, au moment du banc.

## 9. Erreurs

| Situation | Comportement |
|---|---|
| Paquet d'une source non autorisée | Ignoré et compté. Journalisé une fois par minute au plus, par source. |
| Paquet de taille anormale | Ignoré et compté. |
| Deux sources parlent en même temps | La première garde le haut-parleur, la seconde est ignorée et comptée. |
| Haut-parleurs intégrés introuvables | Rien n'est joué. L'erreur est journalisée, et le daemon réessaie à la prochaine prise de parole. |
| Échec de démarrage de la sortie (coreaudiod qui ne répond pas) | Erreur journalisée, pas de boucle de tentatives, nouvel essai à la prochaine prise de parole. |
| Port 1986 occupé | Le daemon s'arrête avec un code d'erreur et un message clair. launchd le relance au rythme du `ThrottleInterval`. |
| Réglages absents ou invalides | Valeurs par défaut (127.0.0.1 seul), journalisées. |

## 10. Contexte coreaudiod (à lire avant de coder)

Coreaudiod s'est figé deux fois sous macOS 27.0, le 4/10 et le 7/10. Le verrou global `HALS_System` était interbloqué, et tout nouveau client restait suspendu dans `HALC_ProxySystem()`. Ni SoundSource ni ARK ne sont nécessaires pour que ça arrive. Le déclencheur suspecté est **le va-et-vient rapide de clients CoreAudio** : Homebridge lançait deux ffmpeg de capture par snapshot, jusqu'à 400 par heure.

Depuis le 7/10 à 15:42, go2rtc garde ses producers ouverts en permanence (`preload`), et il n'y a eu aucun blocage pendant ce test. D'où les règles de `talkd` :
- un seul client, permanent ;
- aucune relance en rafale ;
- aucune boucle de tentatives ;
- mise en service mesurée seule.

Si coreaudiod se fige malgré tout, la réparation est `sudo killall -9 coreaudiod`. Il faut faire `sudo sample coreaudiod 5 -file …` avant, pour garder le relevé.

## 11. Tests

- **Unitaires**, sans son réel, avec un faux périphérique et une fausse liste de périphériques :
  - filtre des sources et validation des paquets ;
  - détection de voix (seuil, fin après 2 s) ;
  - une source à la fois ;
  - tampon qui jette l'excédent au-delà de 200 ms ;
  - volume minimum : en sourdine, sous le seuil, au-dessus du seuil, et changement par l'utilisateur pendant la parole (pas de rétablissement) ;
  - choix des haut-parleurs intégrés quand la sortie par défaut est ailleurs, puis quand la liste change ;
  - réglages absents ou invalides.
- **Intégration sur le Mac** :
  - un ffmpeg local envoie une voix enregistrée depuis 127.0.0.1, et on l'entend sur les haut-parleurs intégrés pendant que la sortie par défaut est ailleurs ;
  - on mesure la latence ;
  - un envoi depuis l'adresse réseau du Mac, qui n'est pas dans la liste, est ignoré ;
  - dix cycles parole puis silence ne créent aucun client coreaudiod de plus (point 2 du § 4).
- **Banc avec Majid** :
  - le bouton micro de Maison, sur l'iPhone, fait parler le Mac ;
  - on mesure la latence, et on vérifie que le relâchement du bouton coupe la voix ;
  - le volume minimum fonctionne, Mac en sourdine puis à 10 % ;
  - un live sans parole ne déclenche rien ;
  - PTZBot fermé, la voix passe toujours.

## 12. Mise en service

1. **Après la conclusion du test `preload`** (coreaudiod stable), suivie par la session go2rtc.
2. **`talkd` seul, sans toucher à Homebridge, pendant 24 à 48 h.** La collecte de la session go2rtc suit coreaudiod. La session go2rtc y ajoute l'état de `talkd` : PID et durée de vie.
3. **La ligne Homebridge**, avec l'accord de Majid, puis le banc.

## 13. Limites connues

- Avec un casque branché sur la prise jack, la sortie intégrée du Mac bascule sur le casque, et la voix aussi. C'est le comportement de macOS.
- L'option `returnAudioTarget` est expérimentale dans le plugin : une mise à jour de `homebridge-camera-ffmpeg` peut la casser.
- Le filtrage se fait par adresse source, sans authentification. C'est suffisant sur le réseau local, puisque Majid a choisi « NAS et 127.0.0.1 ». Si l'IP du NAS change, il faut mettre `talkd.json` à jour.
- Pas d'atténuation des autres apps dans la v1.
