# Parler depuis l'app iOS vers les haut-parleurs du Mac : conception

Date : 09/10/2026. Choix validés par Majid en conversation, section par section. Voie courte : prototype, relecture,
banc, report sur `main`, relecture finale.

## 1. Objectif

Un bouton « parler » dans l'app iOS PTZBot. Tant qu'on le maintient, la voix de l'iPhone sort par les haut-parleurs
intégrés du Mac, comme le bouton micro de la caméra dans l'app Maison (spec haut-parleur,
`2026-10-08-haut-parleur-design.md`). La lecture côté Mac reste celle de `talkd`, sans changement.

## 2. Choix de Majid

| Question | Choix |
|---|---|
| Chemin de la voix | **Par ptzd** : la connexion WebSocket déjà ouverte avec l'iPhone, puis UDP local vers `talkd` (pas le canal de retour WebRTC de go2rtc, qui demanderait de modifier `go2rtc.yaml` et un ffmpeg de plus) |
| Façon de parler | **Maintenir pour parler** : le relâchement coupe |
| Son reçu pendant la parole | **Conversation** : le son de la caméra continue, avec l'annulation d'écho d'iOS sur le micro |
| Vie privée | **On peut parler en vie privée** : parler ne montre rien et n'écoute rien de la pièce |
| Voix de l'iPhone dans les vidéos du bouton rec | Pas dans cette version ; au backlog |

Les deux chemins, Maison (iPhone → HomeKit → Homebridge sur le NAS → UDP) et PTZBot iOS (iPhone → ptzd → UDP
127.0.0.1), arrivent à `talkd` sous la même forme : PCM 16 bits, 16 kHz, mono. Si les deux parlent en même temps, la
première voix garde le haut-parleur jusqu'à 2 s de silence (spec haut-parleur § 5.2).

## 3. Chemin de la voix

```
iPhone (bouton « parler » maintenu)
   micro → annulation d'écho iOS (Voice Processing) → PCM 16 bits LE, 16 kHz, mono
   → paquets de 20 ms (640 octets), en trames binaires sur la WebSocket ouverte avec ptzd
     (Wi-Fi ou 4G ; appairage, authentification et TLS déjà en place)
ptzd
   trames acceptées d'un iPhone appairé et authentifié seulement, 50 par seconde au plus
   → UDP vers 127.0.0.1:<port de talkd>
talkd (inchangé)
   source 127.0.0.1 autorisée → détection de voix → haut-parleurs intégrés du Mac
```

## 4. Protocole (`Packages/NacelleProtocol`)

- **Trame « voix ».** Une trame WebSocket **binaire** de **640 octets exactement**, sans en-tête : 320 échantillons
  PCM 16 bits little-endian, 16 kHz, mono. Aucun message de début ou de fin : la fin d'une prise de parole est
  détectée par `talkd`. C'est le seul message binaire du protocole : tous les autres restent du JSON en texte.
- **État « Talkback prêt ».** `StateSnapshot` reçoit un champ facultatif `talkback` (`ready` ou `unavailable`).
  Un ptzd plus ancien ne l'envoie pas : l'app le traite comme `unavailable`.
- Les constantes (taille, fréquence, durée) sont partagées par le paquet et testées.

## 5. ptzd

- **Réception.** Une trame binaire n'est acceptée que d'un client **authentifié par sa clé d'appareil** (pas le client
  de confiance 127.0.0.1, pas un client en cours d'appairage). Toute autre trame binaire est ignorée et comptée.
- **Validation.** Taille différente de 640 octets : ignorée et comptée. Au-delà de 50 trames par seconde et par client
  (fenêtre glissante d'une seconde ; 50 + 10 de marge, voir § 11) : l'excédent est ignoré et compté.
- **Relais.** Une seule socket UDP, ouverte au premier relais et gardée pour la vie du process, envoie chaque trame à
  `127.0.0.1:<port>`. Le port est lu dans `talkd.json` (`port`, 1986 par défaut) au démarrage de ptzd. Un envoi qui
  échoue (talkd absent) est ignoré sans erreur pour l'iPhone.
- **Journal.** Une ligne par prise de parole et par appareil (début, durée, trames relayées et refusées), au plus une
  ligne de refus par minute. **Aucun son n'est enregistré.**
- **État « Talkback prêt ».** ptzd lit `talkd-state.json` (écrit par `talkd`) : `ready` si le fichier existe, sans
  `failure`, et si le `pid` noté est vivant ; sinon `unavailable`. Il relit ce fichier toutes les 5 s et diffuse un
  nouvel état seulement quand la valeur change.

## 6. App iOS

### 6.1 Bouton « parler »

- **Place.** Un grand bouton rond (icône micro) en bas au centre, entre le joystick et le zoom. Masqué en mode épuré,
  comme les autres commandes.
- **Maintenu** : fond rouge dès le toucher. Pendant la préparation du micro, un anneau tourne autour du bouton et la
  jauge reste muette ; quand les premières trames sont captées, l'anneau disparaît et la petite jauge de niveau suit le
  micro : c'est le moment de parler (§ 11.5). **Relâché** : la parole s'arrête.
- **Grisé** (désactivé, opacité 0,4) : hors connexion, ou Talkback indisponible sur le Mac. Dans ce cas, un appui court
  affiche « Talkback est éteint sur le Mac » ou « Pas de connexion au Mac ».
- **Micro refusé** : atténué mais touchable ; un appui affiche « L'accès au micro est refusé : autorisez-le dans
  Réglages › PTZBot ». Info.plist : `NSMicrophoneUsageDescription` = « Pour parler par les haut-parleurs du Mac où
  la caméra est branchée. »
- **Accessibilité** : « Maintenir pour parler » ; pendant la préparation, « Préparation du micro » ; ensuite,
  « Parole en cours ».
- Textes au « vous », en français (la traduction de l'app iOS viendra plus tard).

### 6.2 Audio

- **Catégorie préparée à l'avance.** Au premier démarrage de la lecture (et après une réinitialisation des services
  audio d'iOS), la session est mise **une seule fois** en catégorie `.playAndRecord`, mode `.default`, options
  `.defaultToSpeaker`, `.mixWithOthers`, `.allowBluetoothHFP` et `.allowBluetoothA2DP`. Elle n'est plus touchée ensuite.
  - `.defaultToSpeaker` : le son de la caméra reste au haut-parleur (`.playAndRecord` vise l'écouteur par défaut).
  - `.allowBluetoothA2DP` : sans lui, un casque ou une enceinte Bluetooth tomberait au profil téléphone (HFP, mono) pour
    la lecture hors parole.
- **Hors parole** : le module de lecture (`PlayoutAudioDevice`) joue par l'unité RemoteIO **en sortie seule**, sans
  entrée : le micro n'est jamais ouvert, pas de voyant orange. Mode `.default`, jamais `.voiceChat` hors parole.
- **À l'appui** : seuls changent le **mode** de la session (`.voiceChat`) et l'unité, remplacée par **Voice Processing
  I/O**, en entrée et en sortie, pour que l'annulation d'écho connaisse le son joué. La lecture du son de la caméra
  continue par cette même unité. Plus de changement de catégorie, donc plus de reconfiguration complète du circuit audio
  d'iOS à chaque prise de parole. *(Précisé par le § 11.6 : catégorie, mode et options sont reposés ensemble à chaque
  changement, avec la même catégorie et les mêmes options.)*
- **Mode `.voiceChat` : à confirmer au banc.** La VPIO annule l'écho par elle-même ; le mode ajoute les réglages système
  prévus pour la voix. Sans appareil réel, le prototype garde `.voiceChat` (comportement déjà éprouvé). Si le banc montre
  que `.default` suffit à l'écho, il suffit de mettre `.default` dans `SystemPlayoutSession.speakingMode` : l'appui ne
  changera plus que l'unité.
- **Au relâchement** : retour à la RemoteIO en sortie seule et au mode `.default`, **sans changer de catégorie**. Un
  blanc d'environ 0,2 s dans le son reçu est admis à l'appui et au relâchement.
- **Captation** : le micro est converti en 16 kHz mono 16 bits (`AVAudioConverter`), découpé en paquets de 640 octets,
  et envoyé par le client WebSocket existant en trames binaires. Une file bornée (au plus 10 paquets, soit 200 ms)
  jette le plus ancien si l'envoi prend du retard.
- **Arrêts automatiques** : relâchement, perte de connexion, passage en arrière-plan, interruption audio (appel,
  Siri). Après une interruption, la lecture reprend comme aujourd'hui.
- **Bouton rec** : la vidéo enregistrée garde le son de la caméra. La voix de l'iPhone n'y est pas ajoutée à la source
  (backlog).

## 7. Erreurs

| Cas | Comportement |
|---|---|
| Micro refusé | Rien n'est capté ; message vers Réglages |
| Connexion coupée pendant l'appui | La parole s'arrête, le bouton se grise |
| Talkback éteint sur le Mac | Bouton grisé (état `talkback: unavailable`) |
| Vidéo pas connectée (caméra débranchée, connexion en cours, go2rtc en panne) | Bouton grisé ; un appui dit « La vidéo n'est pas connectée : la parole a besoin du son de la caméra. » (voir § 11) |
| talkd tombe pendant la parole | Les paquets se perdent sans erreur ; le bouton se grise au prochain état |
| Appel ou Siri pendant l'appui | La parole s'arrête ; la lecture reprend après |
| Trame binaire refusée par ptzd | Ignorée et comptée dans le journal de ptzd, rien côté iPhone |

## 8. Tests

- **Protocole** : constantes de la trame, champ `talkback` (encodage, absence lue comme `unavailable`).
- **ptzd** : relais vers un faux récepteur UDP sur un port libre ; refus d'un client non authentifié, d'une taille
  fausse et au-delà de 50 trames par seconde ; état `talkback` à partir d'un faux `talkd-state.json` (absent, `failure`,
  pid mort, prêt) ; aucune trace du son dans le journal.
- **iOS** : découpage en paquets de 640 octets à partir d'un faux micro ; file bornée ; bouton grisé selon la
  connexion, `talkback` et l'accès au micro ; arrêts automatiques ; bascule de la session audio avec une fausse session.
- Toutes les attentes ont une limite de temps.

## 9. Banc avec Majid

1. Parler depuis l'iPhone en Wi-Fi, puis en 4G : voix claire, latence correcte.
2. L'écho : ce qu'on entend de soi-même dans l'iPhone pendant la parole.
3. Le blanc à l'appui et au relâchement : acceptable ou non.
4. Talkback éteint sur le Mac : bouton grisé ; rallumé : bouton actif.
5. Maison et PTZBot iOS en même temps : la première voix garde le haut-parleur.
6. Vie privée active : la parole passe.

## 10. Livraison

- **Mac : 1.0.3**, avec le relais dans ptzd, le champ `talkback` et la réinscription automatique de l'agent Talkback
  après une mise à jour (branche `talkback-reinscription`, f4862fd). Cette réinscription sera vérifiée en vrai pendant
  la mise à jour 1.0.2 → 1.0.3. Elle attend la fin de la désinscription, ne se fait jamais depuis une compilation de
  travail (numéro 1), et donne un avis si talkd ne repart pas (§ 11.8).
- **iPhone** : installation depuis Xcode, comme d'habitude.
- Notes de version 1.0.3 : English, puis Français.

## 11. Amendements (prototype)

Écarts constatés ou décidés pendant le prototype (branche `proto/parler`) et sa relecture. Ce qui est écrit ici
l'emporte sur les sections 1 à 10.

### 11.1 Marge de 10 trames sur la limite de 50 par seconde

- **Règle.** ptzd accepte au plus **60 trames** par seconde et par client (fenêtre glissante d'une seconde) : les
  50 de la section 5 plus 10 de marge. La constante est `VoiceRelayer.burstTolerance` ; la mettre à 0 rend la limite
  stricte de la spec.
- **Raison.** Un iPhone qui envoie exactement 50 trames par seconde dépasse 50 dans une fenêtre dès que le Wi-Fi, la 4G
  ou TCP regroupent des trames : la limite stricte jetterait de la voix légitime à chaque grappe. 60 trames par
  seconde font 38 ko/s, ce qui est inoffensif.
- **À savoir.** Après un blocage de la 4G, la limite jette les trames les plus récentes de la rafale, donc la voix la
  plus fraîche. Ce n'est pas grave : talkd plafonne de toute façon son tampon de gigue à 200 ms.

### 11.2 Vidéo non connectée

- **Constat.** La parole passe par le périphérique audio de WebRTC (bascule RemoteIO vers Voice Processing I/O,
  section 6.2) : elle exige que la lecture WebRTC tourne, donc que la vidéo soit en lecture. Sans cela (caméra
  débranchée, vidéo en cours de connexion, go2rtc en panne), le démarrage échouait et l'app affichait à tort « Le micro
  n'a pas pu démarrer. ».
- **Règle.** Cas `noVideo` de la disponibilité de la parole : bouton atténué quand `video.phase` n'est pas `playing`,
  avec l'avis « La vidéo n'est pas connectée : la parole a besoin du son de la caméra. » à l'appui. Ordre des causes :
  pas de connexion à ptzd, puis Talkback éteint, puis vidéo absente. Une vidéo perdue pendant la parole l'arrête
  (même raison que la perte de connexion).
- **Suite possible.** Une unité Voice Processing I/O autonome, qui rendrait du silence quand WebRTC ne joue pas,
  lèverait cette dépendance ; elle n'est pas dans le prototype.

### 11.3 Autres écarts du prototype

- **Nom du champ.** `talkback` de l'état est de type `TalkbackAvailability` (`ready` ou `unavailable`) et non
  `TalkbackState`, nom déjà pris dans PTZBotKit pour le fichier d'état de talkd. Le champ est toujours écrit ; absent à
  la lecture, il vaut `unavailable` (un ptzd plus ancien grise donc le bouton).
- **Pas de bandeau « Parole en cours ».** Le bouton rouge et la jauge suffisent ; seuls les avis de la section 7
  existent, plus « Le micro n'a pas pu démarrer. » quand l'unité audio échoue.
- **Journal de ptzd.** Une seule ligne par prise de parole et par appareil, écrite à la fin (début, durée, trames
  relayées et refusées), aussi à la déconnexion. Une prise de parole se termine après 1 s sans trame (le détecteur de
  voix de talkd garde ses 2 s). Les refus tiennent en une ligne par minute au plus, avec les décomptes cumulés (sans
  authentification, mauvaise taille, trop rapides).
- **Dossier de talkd lu par ptzd.** `TALKD_SUPPORT_DIR` s'il existe, sinon le dossier de travail de ptzd (le même en
  service).
- **UDP.** Socket connectée et non bloquante ; un envoi qui échoue est seulement compté.
- **Envoi côté iPhone.** Un seul envoi WebSocket à la fois : le suivant part à la fin du précédent, pour que la file
  bornée de 10 paquets joue son rôle (elle jette le plus ancien).
- **Premier appui.** Après la question du système sur le micro, la parole ne démarre pas toute seule (le toucher est
  perdu) : il faut un nouvel appui. Le bouton se remet seul au repos quand le système annule le toucher.
- **Arrêts automatiques.** La parole s'arrête aussi quand Talkback s'éteint, quand la connexion ou la vidéo est perdue,
  quand l'app devient inactive (Centre de contrôle, alerte) ou passe en arrière-plan, et sur une interruption audio.
- **Architecture audio.** Le micro est lu à 48 kHz mono 16 bits par Voice Processing I/O, écrit par le rappel d'entrée
  dans un tampon circulaire sans allocation ni verrou, puis converti vers 16 kHz et découpé en paquets de 640 octets
  sur une file à part toutes les 20 ms. Pour WebRTC, le périphérique reste « sans micro » (`isRecording` faux). Après
  chaque bascule d'unité, WebRTC est prévenu (`notifyAudioOutputInterrupted`, puis `notifyAudioOutputParametersChange`).
  Si la bascule échoue, la lecture est réinitialisée au prochain `initializePlayout`.
- **Bouton.** 72 pt, jauge en barre sous l'icône, retour haptique à l'appui, double toucher prolongé sous VoiceOver.
- **Processus.** Côté iOS, les essais du premier jet ont été écrits avec le code ; les corrections d'avant banc, elles,
  ont suivi le cycle rouge puis vert.

### 11.4 Connus et non traités dans le prototype

À voir au banc, ou à reprendre au report sur `main` : démarrage de `Speaker` sans délai de repli, valeur
inconnue du champ `talkback` (reprise au § 11.8), deux iPhones qui parlent en même temps
(talkd ne voit qu'une source : refuser les trames d'un second client tant qu'une prise de parole est ouverte), taille
maximale des messages WebSocket de ptzd, musique des autres apps qui ne reprend pas après la parole.

### 11.5 Réactivité du bouton « parler »

- **Constat du banc.** L'appui n'était pas instantané : chaque prise de parole changeait la catégorie (`.playback` vers
  `.playAndRecord`) et le mode, et remplaçait l'unité, ce qui reconfigurait tout le circuit audio d'iOS.
- **Règle.** Catégorie `.playAndRecord` posée une fois à l'avance, sans entrée (§ 6.2) ; l'appui ne change que le mode
  et l'unité. Retour visuel immédiat : rouge dès le toucher, anneau tournant pendant la préparation, jauge seulement
  quand les premières trames du micro sont captées (`Speaker.isMicLive`), VoiceOver « Préparation du micro ». Ajout par
  rapport à la demande : l'option `.allowBluetoothA2DP`, pour que la lecture hors parole reste en stéréo sur Bluetooth.
- **À vérifier au banc.** Réactivité ressentie ; son de la caméra au haut-parleur et de même qualité hors parole, avec et
  sans casque Bluetooth ; musique des autres apps qui continue ; la question du système sur le micro, qui pourrait
  maintenant venir au démarrage de la lecture et non au premier appui ; mode `.voiceChat` nécessaire ou non à l'écho.

### 11.6 Banc du 10/10 (avec Majid)

- **Validé :** Wi-Fi et 4G (trames complètes, aucune refusée), réactivité après correction, premier mot entendu, pas
  d'écho côté iPhone, son de la caméra au haut-parleur après correction, parole en vie privée.
- **Appui capté par le toucher brut.** Le `DragGesture(minimumDistance: 0)` de SwiftUI n'arrivait à l'app que 0,3 à
  0,7 s après le toucher (mesuré par des repères horodatés : l'app, elle, réagissait en moins d'une milliseconde). Le
  bouton « parler » reçoit maintenant le doigt posé et levé par une petite vue UIKit (`PressSurface`, `touchesBegan` /
  `touchesEnded` / `touchesCancelled`), et devient rouge dès le toucher, avant même la bascule audio (environ 0,3 s,
  sur le fil de WebRTC). Ni la position du bouton ni ses réglages d'accessibilité n'étaient en cause.
- **Sortie au haut-parleur.** Après la parole, `setMode` seul laissait iOS revenir à l'écouteur (son faible). La session
  repose désormais catégorie, mode et options à chaque changement, et force le haut-parleur quand la sortie est
  l'écouteur (`overrideOutputAudioPort(.speaker)`) ; un casque, des AirPods ou une enceinte gardent leur sortie.
- **Talkback depuis une app de banc.** Inscrire l'agent depuis une seconde copie de l'app (même identifiant, autre
  emplacement) a déréglé son rattachement (`BTMErrorDomain -95`, puis réparation tardive par macOS). Au banc, ne pas
  basculer Talkback depuis une copie de travail ; l'essai « Talkback éteint, bouton grisé » se refait sur l'app publiée.

### 11.7 Limite connue : écho de sa propre voix

Pendant la parole, la voix jouée par le Mac est captée par le micro de la caméra et revient dans le son reçu par
l'iPhone, avec le retard du trajet. L'annulation d'écho de l'iPhone ne la retire pas (elle ne concerne que ce que
l'iPhone joue lui-même). Audible surtout son fort, au haut-parleur. Décision de Majid (10/10) : rien à faire pour
l'instant. Parade possible si besoin : baisser fortement le son reçu tant que le bouton est maintenu.

### 11.8 Report sur main (relecture finale)

Quatre correctifs de la relecture finale, reportés avec la branche, chacun écrit test d'abord (rouge, puis vert) :

- **F1. Appui collé (iOS).** `AppModel.pressSpeak` lance `Speaker.press()` par `Task.immediate`, qui pose le doigt et la
  phase `.starting` avant de rendre la main. Avec une `Task` ordinaire, un relâchement traité avant le démarrage de la
  tâche était perdu, et le micro s'ouvrait ensuite sans doigt posé (appui bref, double toucher VoiceOver). Essais :
  appui et relâchement d'affilée, et relâchement pendant le démarrage du micro.
- **F2. Réinscription (Mac).** `LoginItemService.unregisterAndWait()` (forme asynchrone de `SMAppService`) ;
  `reregisterIfUpdated` est `async` et attend la fin de la désinscription avant d'inscrire. L'`AppDelegate` l'appelle
  dans une `Task`, puis relit l'état.
- **F3. Compilation de travail (Mac).** Pas de réinscription automatique quand `CFBundleVersion == "1"` ; l'app publiée
  garde la règle et reprend l'agent après une bascule faite depuis une copie de travail.
- **F4. Avis (Mac).** Après une réinscription faite pendant ce lancement, `notRunning` donne « Talkback n'a pas
  redémarré après la mise à jour : éteignez puis rallumez Talkback. » (entrée anglaise au catalogue de PTZBotKit). Aucune
  nouvelle tentative automatique.

Petites retouches : le champ `talkback` inconnu se lit « indisponible » (§ 11.4, M5) ; commentaires d'`AudioIO.swift`
alignés sur le § 11.6 ; `PressSurface` ignore `touchesMoved`.
