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
| Forme | **Daemon sans interface**, et un **interrupteur « Talkback »** dans le panneau de PTZBot |
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

- Un interrupteur **« Talkback »** (nom choisi par Majid), avec une ligne d'état sous l'interrupteur :
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
- **Mac capot fermé** (banc du 09/10) : les haut-parleurs intégrés jouent normalement, mais le curseur et les touches de volume de macOS ne les règlent plus. talkd, lui, règle le volume par CoreAudio : le volume minimum marche.
- **Paquets du NAS en rafales** (banc du 09/10) : sur 9,8 s de voix venue de Maison, le tampon a jeté 600 ms d'avance pour garder la voix en direct, sans gêne audible. Si des coupures s'entendent un jour, relever le plafond du tampon (200 ms).

## 14. Amendements (essais et prototype)

Ajoutés le 2026-10-09, après les essais sur le Mac de Majid et pendant le prototype, puis complétés après la relecture du prototype (correctifs d'avant banc). En cas de différence, cette section prime sur le reste de la spec.

### 14.1 Résultats des essais et décisions de Majid

1. **§ 4.1, validé.**
   - Les haut-parleurs intégrés se trouvent par `kAudioDevicePropertyTransportType == kAudioDeviceTransportTypeBuiltIn`, avec des canaux de sortie. Le micro intégré est aussi `BuiltIn` mais n'a aucun canal de sortie.
   - `AVAudioEngine` joue dessus en réglant `kAudioOutputUnitProperty_CurrentDevice` sur l'`audioUnit` de `outputNode`, alors que la sortie par défaut est ailleurs.
   - Une source PCM à 16 kHz mono branchée au mixeur est convertie par le moteur.
   - Le prototype n'utilise plus `AVAudioEngine` mais une AUHAL en sortie pure, réglée de la même façon (§ 14.2, « Sortie audio »).
2. **§ 4.2, validé.** `engine.stop()` puis `engine.start()`, dix fois dans le même process, gardent **un seul client coreaudiod** et le même contexte d'E/S. Seuls `_StartIO` et `_StopIO` se répètent. La lecture peut donc s'arrêter après 10 s sans voix, comme le dit le § 5.3. L'interdit reste : jamais de relance du process en rafale.
3. **§ 4.3, validé.**
   - `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` et `kAudioDevicePropertyMute` (portée sortie) se lisent et s'écrivent sans droits root.
   - Un écouteur (`AudioObjectAddPropertyListenerBlock`) reçoit aussi **les changements faits par talkd lui-même**. Pour savoir si l'utilisateur a changé le volume pendant la parole (§ 5.4), on compare la valeur lue à la dernière valeur écrite par talkd, avec une tolérance de 0,005.
4. **§ 12, décision de Majid.** Pas de phase d'observation de 24 à 48 h. L'enchaînement est : essais, prototype, banc, ligne Homebridge avec son accord, banc Maison.
5. **§ 4, points 4, 5 et 6.** Ils se font au banc avec Majid, pas dans le prototype : l'agent `SMAppService`, le pare-feu, le NAS.

### 14.2 Écarts du prototype (`mac/talkd` et PTZBot)

- **Fichier d'état.** `~/Library/Application Support/ObsbotNacelle/talkd-state.json` contient `speaking`, `since` (ISO 8601, l'instant du dernier changement) et, en plus de ce que prévoyait le § 6, **`pid`**. L'état d'un talkd tué en pleine parole reste dans le fichier : PTZBot l'ignore si ce processus n'existe plus (`kill(pid, 0)`). Écrit de façon atomique : au démarrage (`speaking: false`), au début et à la fin de chaque prise de parole, à l'arrêt.
  - Un champ facultatif **`failure`** est écrit juste avant `exit` quand la socket UDP ne s'ouvre pas : `portBusy` (port déjà utilisé) ou `socket` (autre erreur). Sans échec, le champ est absent : les fichiers d'avant restent valides. Écrire ce fichier ne touche pas CoreAudio.
- **Statuts du panneau.** En plus de « Prêt », « Désactivé », « Autorisation requise » et « En lecture » :
  - « Démarrage… » quand l'agent est inscrit mais que talkd n'a pas écrit son état (ou que son processus n'existe plus) ;
  - « Indisponible » quand la plist de l'agent manque dans l'app (compilation sans agent, `SMAppService.Status.notFound`) ; l'interrupteur est alors grisé.
  - « Arrêté : le port UDP est déjà utilisé (voir le journal) », « Arrêté : erreur réseau (voir le journal) » ou « Arrêté (voir le journal) » dès qu'un `failure` est écrit ;
  - « talkd ne démarre pas (voir le journal) » quand l'agent est inscrit mais que talkd n'a pas tourné depuis plus de 15 s, comptées depuis le premier « Démarrage… ». Cela couvre aussi un agent refusé par launchd (plist en quarantaine, par exemple).
  - Ces deux statuts et « Autorisation requise » s'affichent en orange.
  - L'état est relu chaque seconde pendant que le panneau est ouvert, jamais autrement.
- **Plist de l'agent.** `AssociatedBundleIdentifiers` (`io.github.djoko-cli.ptzbot`) est ajouté aux clés du § 7, pour que l'agent apparaisse sous PTZBot dans Réglages › Général › Ouverture. Le fichier source est `mac/app/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.talkd.plist`.
- **Arrêt de la lecture.** Elle s'arrête **10 s après le dernier paquet de voix**, donc 8 s après la fin de la prise de parole (qui est à 2 s). Une nouvelle prise de parole pendant ce délai le annule : la sortie reste ouverte, sans redémarrage.
- **Sortie audio : une AUHAL en sortie pure, et non `AVAudioEngine`** (relecture du prototype, défauts C1 et I1).
  - Le premier prototype utilisait une `AVAudioSourceNode`. Son bloc de rendu, formé dans une classe `@MainActor`, héritait de cette isolation : Swift 6 y insère un contrôle d'exécuteur, et talkd se serait arrêté en SIGTRAP au premier rappel audio. De plus, `AVAudioEngine` partage une seule AUHAL entre entrée et sortie, et son unité peut revenir à la sortie par défaut après un changement de configuration.
  - `HALOutput` (TalkCore) crée **une seule** AUHAL (`kAudioUnitSubType_HALOutput`) à la première prise de parole, et la garde pour toute la vie du process. Avant `AudioUnitInitialize` : `EnableIO` à 0 en entrée (bus 1) et à 1 en sortie (bus 0), `CurrentDevice` sur les haut-parleurs intégrés, le format, puis le rappel. Le micro n'est jamais ouvert, par construction.
  - Format : Float32, 16 kHz, **deux canaux non entrelacés** ; l'AUHAL convertit vers la fréquence du périphérique. En mono, elle ne jouerait que sur le canal gauche. Non entrelacé, chaque canal a sa mémoire contiguë : le gauche est rempli directement depuis le tampon, puis recopié d'un bloc dans le droit, sans tampon intermédiaire.
  - Le rappel de rendu est une **fonction C globale** de TalkCore (`TalkRender.callback`), hors de tout acteur : sans allocation ni appel isolé, elle lit le `JitterBuffer` (son verrou interne, `os_unfair_lock`, est tenu le temps d'une copie). Elle est testée depuis un autre fil, et une sonde en processus à part montre qu'elle ne porte pas l'isolation du MainActor.
  - `CurrentDevice` est **relu sur l'unité** à chaque démarrage : s'il a changé (par le système ou par la liste des périphériques), l'unité est arrêtée, désinitialisée, réglée de nouveau puis réinitialisée. `isRunning` est lu sur l'unité ; une sortie arrêtée par le système est journalisée à la prise de parole suivante, puis redémarrée.
  - Le tampon garde son comportement (§ 5.2) : pré-charge de 60 ms, au-delà de 200 ms le plus ancien est jeté, tampon vide en pleine parole = silence puis nouvelle pré-charge.
- **Volume.**
  - La valeur de référence pour détecter un changement de l'utilisateur est celle **relue après l'écriture**, et non celle qu'on a écrite : un pilote qui n'a que quelques crans (0,30 devenu 0,3125) ne passe pas pour un utilisateur.
  - Une dernière relecture a lieu à la fin de la prise de parole, au cas où l'écouteur n'aurait rien notifié.
  - En sourdine mais au-dessus du seuil, seule la sourdine est levée (puis remise) ; le volume n'est pas touché.
  - Volume illisible ou refusé : journalisé, la voix passe au volume actuel.
  - Un utilisateur qui règle exactement la valeur de talkd, à 0,005 près, pendant la parole n'est pas vu : son réglage est remplacé par l'état d'origine à la fin. C'est accepté.
  - **Fichier de reprise** (`talkd-volume.json`, dans le dossier de travail). Il contient le périphérique et son nom, l'état d'origine, ce qui a été changé et l'état relu après l'écriture de talkd. Il est enregistré après cette relecture, et effacé à la fin de la prise de parole quelle qu'en soit l'issue. Au démarrage, si le fichier existe : l'état d'origine est rétabli seulement si les haut-parleurs ont le même nom et que le volume et la sourdine valent toujours ce que talkd avait écrit, à 0,005 près ; sinon rien n'est touché. Le fichier est effacé dans tous les cas, donc des relances en boucle ne rejouent rien deux fois.
- **Journal.**
  - Le journal est rédigé en français, une ligne datée par message (heure locale, ISO 8601), dans `talkd.log` ; au-delà de 1 Mo il passe à `talkd.log.1`.
  - Les refus sont limités à une ligne par minute et par source, et à **10 lignes par minute toutes sources confondues** : des adresses usurpées en nombre ne remplissent pas le journal. Les refus restent comptés.
  - La fin de chaque prise de parole est résumée en une ligne (durée de voix, paquets d'une autre source ignorés, millisecondes jetées par le tampon).
- **Réglages.**
  - `talkd.json` est validé en entier : une seule valeur hors limites remplace tout le fichier par les valeurs par défaut (127.0.0.1 seul), journalisé.
  - `allowedSources` ne contient que des adresses IPv4, pas de noms, et au moins une.
  - Le port 0 (port libre attribué par le système) est accepté, pour les talkd de test.
  - `TALKD_SUPPORT_DIR` remplace le dossier de travail pour les essais (comme `PTZD_SUPPORT_DIR`) : réglages et état y vont, le journal dans son sous-dossier `logs`.
  - Un exemple est dans `mac/talkd/talkd.example.json`, avec `192.0.2.10` pour le NAS.
- **Port occupé.** talkd s'arrête avec le code 75 (`EX_TEMPFAIL`, comme ptzd), un message au journal et l'état `failure: portBusy` ; launchd le relance au rythme du `ThrottleInterval`. Une autre erreur de la socket donne le code 1 et `failure: socket`. Une option inconnue donne le code 64.
- **Frein au démarrage** (relecture I4). `ThrottleInterval` suffit pour le port occupé, qui s'arrête avant tout appel CoreAudio, mais pas pour un plantage après les premiers appels CoreAudio : jusqu'à 360 clients coreaudiod par heure.
  - `talkd-runs.json` garde le début de la dernière phase CoreAudio et le nombre de phases courtes de suite. Une phase est courte quand la suivante commence moins de 60 s après elle (une horloge revenue en arrière compte comme courte).
  - Dès deux phases courtes de suite, la phase suivante attend `min(30 s × 2^(n−2), 15 min)`, par le `Scheduler`, sans `sleep`. Pendant ce délai, l'état « au repos » est écrit et les paquets sont ignorés et comptés. Un plantage en boucle tombe ainsi à quelques clients par heure.
  - Un arrêt propre (SIGTERM, SIGINT) efface le fichier : ce n'est pas un plantage.
- **Réception sous un flot continu** (relecture I5). Au plus 64 datagrammes par réveil de la source de lecture, qui se redéclenche tant qu'il reste des données : la file principale garde la main pour les minuteries, le volume et SIGTERM. Un datagramme de plus de 4096 octets n'est pas copié ; sa taille réelle est passée au filtre, qui le compte en « taille anormale ».
- **Arrêt propre.** À SIGTERM ou SIGINT, la prise de parole en cours est finie (volume rétabli), la lecture arrêtée, l'état remis à `speaking: false`. Si talkd est tué (SIGKILL) ou plante en pleine parole, le volume relevé est rétabli au démarrage suivant par le fichier de reprise (voir « Volume »).
- **Structure testable.**
  - Le contrôleur ne dépend pas de la socket UDP : il reçoit les paquets par `receive(_:from:)`. Le récepteur UDP (`UDPReceiver`) est un module à part, testé sur 127.0.0.1 avec un port attribué par le système.
  - La sortie audio, la liste des périphériques, le volume, l'état, les fichiers de reprise et du frein, l'horloge et le journal sont derrière des protocoles. Leurs implémentations réelles (CoreAudio et l'AUHAL d'AudioToolbox, dans `AUHALUnit`) ne sont construites que dans l'exécutable `talkd`. L'ordre des appels à l'AUHAL est tenu par `HALOutput`, dans TalkCore, et testé avec une fausse unité.
  - TalkCore n'importe ni CoreAudio, ni AudioToolbox, ni AVFoundation ; `TalkRender` n'importe que `CoreAudioTypes`, pour les structures `AudioBufferList` et `AudioTimeStamp`.

### 14.3 À vérifier au banc

- **Les trois essais restants du § 4** : points 4, 5 et 6 (agent `SMAppService`, pare-feu, NAS).
- **Les essais d'intégration du § 11** : voix locale depuis 127.0.0.1 sur les haut-parleurs intégrés pendant que la sortie par défaut est ailleurs, latence, envoi depuis l'adresse réseau du Mac refusé, dix cycles sans client coreaudiod de plus.
- **Aucune demande d'accès au micro** au premier démarrage de la sortie : l'essai du 09/10 a laissé voir des demandes TCC du micro pendant le démarrage d'`AVAudioEngine`. L'AUHAL a maintenant son entrée coupée avant l'initialisation, et l'exécutable est signé avec le runtime renforcé, sans droit audio-input.
- **La voix sur les deux canaux** des haut-parleurs intégrés, et toujours sur eux quand la sortie par défaut change pendant la parole.
- **La reprise du volume** après un `kill -9` de talkd en pleine parole, au redémarrage par launchd.
- **Le frein et les nouveaux statuts** : aucun client coreaudiod de plus pendant une boucle « port occupé » ; « Arrêté : … » et « talkd ne démarre pas » dans le panneau.
- **Le panneau** : la ligne d'état « En lecture » en direct, et l'arrêt du suivi quand le panneau se ferme.

### Banc du 09/10 (avec Majid)

- talkd lancé à la main : voix claire sur les deux canaux des haut-parleurs du MacBook, capot fermé, sortie par défaut sur une interface USB ; dix prises de parole sur un seul contexte d'E/S et sans nouveau client coreaudiod ; volume minimum (sourdine, 10 %, 50 %) ; reprise du volume après `kill -9` ; port occupé (code 75, `failure` écrit).
- Micro : au démarrage, coreaudiod fait une **consultation** TCC du micro (`preflight=yes`) pour tout nouveau client HAL, sans fenêtre ni voyant. talkd n'ouvre jamais d'entrée.
- Agent : `SMAppService.agent` répond `notFound` avant la première inscription alors que la plist est dans l'app. L'interrupteur reste donc utilisable dans cet état ; seule une inscription refusée donne « Indisponible ». Inscription sans aucune demande de macOS, talkd vivant PTZBot fermé.
- Pare-feu : aucune question pour l'UDP entrant venu du NAS (app signée).
- Maison : le bouton micro de la caméra fait parler le Mac ; relâchement, silence et latence jugés parfaits par Majid. coreaudiod inchangé toute la journée.
