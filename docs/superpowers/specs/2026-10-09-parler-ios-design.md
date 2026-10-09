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
  (fenêtre glissante d'une seconde) : l'excédent est ignoré et compté.
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
- **Maintenu** : fond rouge et petite jauge de niveau du micro. **Relâché** : la parole s'arrête.
- **Grisé** (désactivé, opacité 0,4) : hors connexion, ou Talkback indisponible sur le Mac. Dans ce cas, un appui court
  affiche « Talkback est éteint sur le Mac » ou « Pas de connexion au Mac ».
- **Micro refusé** : atténué mais touchable ; un appui affiche « L'accès au micro est refusé : autorisez-le dans
  Réglages › PTZBot ». Info.plist : `NSMicrophoneUsageDescription` = « Pour parler par les haut-parleurs du Mac où
  la caméra est branchée. »
- **Accessibilité** : « Maintenir pour parler » ; pendant la parole, « Parole en cours ».
- Textes au « vous », en français (la traduction de l'app iOS viendra plus tard).

### 6.2 Audio

- **Hors parole (inchangé)** : le module de lecture (`PlayoutAudioDevice`, RemoteIO en sortie seule, catégorie
  `.playback`, mode `.moviePlayback`, `.mixWithOthers`) n'ouvre jamais le micro.
- **Pendant la parole** : la session passe en catégorie `.playAndRecord`, mode `.voiceChat`, options
  `.defaultToSpeaker` et `.allowBluetoothHFP`. L'unité audio devient **Voice Processing I/O**, en entrée et en sortie,
  pour que l'annulation d'écho connaisse le son joué. La lecture du son de la caméra continue par cette même unité.
- **Au relâchement** : retour à l'état hors parole. Un blanc d'environ 0,2 s dans le son reçu est admis à l'appui et au
  relâchement.
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
  la mise à jour 1.0.2 → 1.0.3.
- **iPhone** : installation depuis Xcode, comme d'habitude.
- Notes de version 1.0.3 : English, puis Français.
