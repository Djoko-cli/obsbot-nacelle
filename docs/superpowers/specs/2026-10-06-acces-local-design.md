# Spec : accès local et appairage

Complète la spec v1 ([2026-10-05-nacelle-design.md](2026-10-05-nacelle-design.md)), qui reste valable pour tout ce qui n'est pas repris ici. Elle y est référencée par l'amendement **A4**. Validée par Majid le 2026-10-06, partie par partie.

## 1. Objectif

À la maison, piloter la nacelle et voir la vidéo depuis l'iPhone **sans activer Tailscale**. Dehors, rien ne change : Tailscale reste le chemin.

Ouvrir le réseau local supprime la frontière de la v1, qui était le seul réseau Tailscale. Elle est remplacée par un **appairage** : seul un iPhone enregistré auprès de `ptzd` peut piloter, et la vidéo de l'app ne s'obtient plus que par `ptzd`.

## 2. Périmètre

Dans le périmètre :
- `ptzd` écoute aussi sur le réseau local et s'y annonce par Bonjour ;
- authentification de chaque connexion par une clé de l'iPhone, enregistrée une fois par un code d'appairage, quel que soit le chemin (réseau local ou Tailscale) ;
- la négociation vidéo de l'app passe par `ptzd`, qui la relaie à go2rtc ;
- go2rtc : API en local seulement, RTSP protégé par un mot de passe ; Homebridge mis à jour par Majid ;
- l'app choisit seule entre le réseau local et Tailscale.

Hors périmètre :
- la sensibilité du joystick (docs/backlog.md) ;
- le pare-feu macOS et les autorisations système, que Majid gère lui-même ;
- le port WebRTC 8555 de go2rtc, qui reste ouvert (voir § 12) ;
- Face ID à chaque connexion.

## 3. Choix de Majid

| Question | Réponse |
|---|---|
| Pourquoi l'accès local ? | Se passer de Tailscale à la maison |
| Quelle protection ? | Appairage exigé partout, réseau local comme Tailscale |
| Comment choisir le chemin ? | Automatiquement, par découverte Bonjour |
| Jusqu'où protéger la vidéo ? | Les trois étapes : relais par `ptzd`, API go2rtc en local, RTSP avec mot de passe |

## 4. Architecture

```
iPhone (Nacelle)
  │  WebSocket authentifié (ws://…:1985)
  │    ├─ à la maison : service Bonjour _nacelle._tcp, réseau local
  │    └─ dehors : nom Tailscale du Mac
  ▼
ptzd ── relaie l'offre WebRTC ──► go2rtc, API sur 127.0.0.1:1984
  │
  └─ commandes UVC ──► Tiny 2

go2rtc ── médias WebRTC (port 8555, réseau local ou Tailscale) ──► iPhone
go2rtc ── RTSP avec mot de passe (port 8554) ──► Homebridge (NAS)
```

Seule la négociation vidéo passe par `ptzd`. Les images vont toujours directement de go2rtc à l'iPhone.

## 5. Protocole (`NacelleProtocol`)

Messages ajoutés, en JSON comme les autres, avec un champ `type` :

| Sens | Message | Champs | Rôle |
|---|---|---|---|
| serveur → app | `challenge` | `nonce` (32 octets aléatoires, base64) | Envoyé dès l'ouverture d'une connexion qui doit s'authentifier |
| serveur → app | `authenticated` | aucun | La connexion est authentifiée ; l'état suit aussitôt |
| serveur → app | `paired` | `deviceID` | L'appareil vient d'être enregistré |
| serveur → app | `webrtcAnswer` | `id`, `sdp` | Réponse de go2rtc à l'offre `id` |
| serveur → app | `webrtcError` | `id`, `message` | go2rtc injoignable ou en erreur pour l'offre `id` |
| app → serveur | `pair` | `code`, `publicKey` (base64, format x963), `name` | Enregistre la clé de l'iPhone |
| app → serveur | `auth` | `deviceID`, `signature` (base64, DER) | Répond au défi |
| app → serveur | `webrtcOffer` | `id` (entier croissant), `sdp` | Demande de connexion vidéo |

Codes d'erreur ajoutés à `error` : `unpaired`, `authFailed`, `badCode`, `pairingClosed`, `notAuthenticated`.

- `deviceID` : les 16 premiers octets du SHA-256 de la clé publique x963, en hexadécimal.
- La signature ECDSA P-256 porte sur la chaîne UTF-8 `nacelle-auth-v1|<nonce en base64>|<deviceID>`.
- Un nonce ne sert qu'une fois et meurt avec sa connexion.
- Avant `authenticated`, seuls `pair` et `auth` sont acceptés. Tout autre message reçoit `notAuthenticated`, et `ptzd` n'envoie pas l'état.
- Une ancienne version de l'app est refusée, ce qui est acceptable : le Mac et l'iPhone sont mis à jour ensemble.

## 6. `ptzd`

### 6.1 Écoute

- **Comme avant** : sur l'adresse Tailscale (`listenAddress`) et sur 127.0.0.1 (A1).
- **En plus** : sur les interfaces Wi-Fi et Ethernet filaire du Mac, et seulement celles-là. Les interfaces VPN, les ponts de machines virtuelles, le cellulaire et la boucle locale sont exclus.
  - Ce Mac en a deux sur le même réseau domestique : l'Ethernet USB et le Wi-Fi.
  - L'écoute suit les interfaces, pas leurs adresses : un changement d'IP par DHCP ne demande rien.
  - Jamais `0.0.0.0`.
  - La manière exacte de se lier ainsi avec `NWListener` est à vérifier en tête du plan (§ 13).
- La clé `localNetwork` de `config.json` (défaut `true`) permet de couper l'écoute locale sans toucher au reste.

### 6.2 Annonce Bonjour

Service `_nacelle._tcp`, nommé `Nacelle`, enregistrement TXT `v=1`, annoncé seulement sur l'écoute du réseau local. Il n'y a pas d'annonce sur Tailscale.

### 6.3 Authentification

- À l'ouverture d'une connexion, `ptzd` envoie `challenge`. L'app répond par `auth`. `ptzd` vérifie que l'appareil figure dans `devices.json` et que la signature est bonne, puis envoie `authenticated` et l'état.
- **Délai** : sans `authenticated` 10 s après l'acceptation, la connexion est coupée et journalisée. Un appareil du Wi-Fi ne peut donc pas occuper les 4 places. Ce délai remplace celui de la poignée de main du correctif de fuite, qui reste couvert.
- **Échec** : `unpaired` (appareil inconnu) ou `authFailed` (signature fausse), puis fermeture. Chaque échec est journalisé avec l'adresse de l'appelant.
- **Exception** : une connexion arrivée sur 127.0.0.1 est authentifiée d'office. `ptzd` envoie directement `authenticated`. Un programme qui tourne sur le Mac a de toute façon accès à la caméra en USB, et `nacelle-ws` reste utilisable tel quel.
- `devices.json` est relu à chaque authentification. Un appareil retiré est donc refusé dès sa prochaine connexion. Une connexion déjà ouverte reste ouverte jusqu'à sa fin (§ 12).

### 6.4 Appairage

- `ptzd pair`, lancé à la main dans le Terminal du Mac, affiche un code à 6 chiffres valable 5 min. Il l'enregistre haché, avec son sel et son heure d'expiration, dans `pairing.json` (droits 600). Le service en cours d'exécution n'a pas besoin d'être redémarré : il lit ce fichier.
- Le message `pair` n'est accepté que si `pairing.json` existe et n'a pas expiré. Sinon, `pairingClosed`.
- Code juste : la clé publique est ajoutée à `devices.json` (`deviceID`, `name`, `publicKey`, date), le code est supprimé, et `ptzd` envoie `paired`. L'app enchaîne avec `auth` sur le même défi.
- Code faux : `badCode`. Au 3e essai faux, `pairing.json` est supprimé. Le code ne sert qu'une fois.
- `ptzd devices` liste les appareils (`deviceID` abrégé, nom, date). `ptzd revoke <deviceID ou début du deviceID>` en retire un.

### 6.5 Relais vidéo

- Après `authenticated`, `webrtcOffer` est transmis par `POST <go2rtcAPI>/api/webrtc?src=<streamName>`, avec le type `application/sdp` et un délai de 10 s.
  - Code 201 : `webrtcAnswer` avec le SDP de go2rtc.
  - Sinon : `webrtcError`.
- Un client a au plus une négociation en cours. Une nouvelle offre annule la précédente.

### 6.6 Fichiers et configuration

Ajouts sous `~/Library/Application Support/ObsbotNacelle/`, jamais versionnés :

| Chemin | Contenu |
|---|---|
| `devices.json` | Les appareils appairés (clés publiques seulement), droits 600 |
| `pairing.json` | Le code d'appairage en cours, haché ; absent hors appairage |

Clés ajoutées à `config.json` :

| Clé | Rôle | Défaut |
|---|---|---|
| `localNetwork` | Écoute et annonce sur le réseau local | `true` |
| `go2rtcAPI` | Adresse de l'API go2rtc | `http://127.0.0.1:1984` |
| `streamName` | Flux go2rtc à relayer | `obsbot` |

### 6.7 macOS

Écouter et s'annoncer sur le réseau local peut déclencher une demande d'accès au réseau local pour `ptzd`, et peut-être une demande du pare-feu. Majid y répond. Le service journalise un échec d'écoute ou d'annonce sans s'arrêter : Tailscale et 127.0.0.1 continuent de marcher.

## 7. go2rtc

Le fichier de configuration est `/opt/homebrew/etc/go2rtc.yaml`, sur le Mac de Majid, jamais versionné.

| Réglage | Avant | Après |
|---|---|---|
| `api.listen` | `":1984"` | `"127.0.0.1:1984"` |
| `rtsp.username`, `rtsp.password` | absents | un identifiant et un mot de passe aléatoire, donnés à Majid dans la conversation, jamais dans le dépôt |
| `webrtc.listen` | `":8555"` | inchangé |
| `streams` | — | inchangé |

- **Vérification préalable** (§ 13) : une seconde instance de go2rtc 1.9.14, avec une configuration de test, sur d'autres ports et une mire `ffmpeg -f lavfi`, sans la caméra. Elle confirme que :
  - les sources `exec:` publient toujours sur `{output}` quand RTSP demande un mot de passe ;
  - un client RTSP sans mot de passe est refusé, et accepté avec ;
  - l'offre WebRTC envoyée sur l'API locale renvoie toujours les candidats réseau local et Tailscale.
- **Bascule**, avec Majid présent :
  1. copie de sauvegarde `go2rtc.yaml.avant-acces-local` ;
  2. modification des réglages ;
  3. un redémarrage de go2rtc par launchd, qui coupe HomeKit quelques secondes ;
  4. Majid met à jour la source de la caméra dans Homebridge (`rtsp://<identifiant>:<mot de passe>@<Mac>:8554/obsbot`) ;
  5. vérification : HomeKit affiche la caméra, un seul ffmpeg vidéo et un seul ffmpeg audio tournent, et le PID de coreaudiod n'a pas changé.
- **Retour arrière** : remettre la copie et redémarrer go2rtc.

## 8. L'app iOS

### 8.1 Réglages

- Restent : le nom Tailscale du Mac et le port de `ptzd` (1985).
- Disparaissent : le port de go2rtc et le nom du flux, désormais côté `ptzd`.
- Section « Appairage » :
  - un champ pour le code à 6 chiffres et un bouton « Appairer » ;
  - l'état « Appairé » ou « Non appairé » ;
  - un bouton « Oublier cet appairage », qui supprime la clé locale.

### 8.2 Clé

- `SecureEnclave.P256.Signing.PrivateKey`, créée au premier appairage. Sa forme exportable, qui ne fonctionne que sur cet iPhone, est rangée dans le trousseau avec l'accès `AfterFirstUnlockThisDeviceOnly`.
- Pas de Face ID à chaque connexion. Le code de l'iPhone protège déjà son trousseau.
- Dans le simulateur, qui n'a pas de Secure Enclave, une clé P-256 logicielle la remplace, derrière la même interface.

### 8.3 Choix du chemin

- Au premier plan, l'app lance en parallèle :
  - une recherche Bonjour de `_nacelle._tcp`, puis une connexion au service trouvé ;
  - une connexion au nom Tailscale.
- La première connexion qui reçoit `authenticated` l'emporte. L'autre est fermée.
- Quand la liaison est perdue (départ de la maison, Wi-Fi coupé), la reconnexion relance les deux.
- Si Bonjour ne trouve rien, ou si l'accès au réseau local est refusé, Tailscale seul, sans message.
- L'appairage (`pair`) ne passe que par Tailscale : la candidate locale attend `paired`. Il faut donc Tailscale actif une fois, au moment d'appairer ; sinon le bandeau l'indique.
- Une erreur d'authentification reçue d'un service du réseau local ne ferme que cette connexion : un faux service ne peut ni voler le code ni bloquer l'app.
- `Info.plist` : ajouter `NSBonjourServices` (`_nacelle._tcp`). `NSLocalNetworkUsageDescription` existe déjà.

### 8.4 Vidéo

- `VideoSession` envoie son offre par `webrtcOffer` sur la connexion `ptzd` retenue, au lieu du `POST` direct à go2rtc.
- Pendant la transition (§ 11, étapes 1 à 3), un `webrtcError` fait retenter l'ancien `POST` direct vers go2rtc, sur le même hôte. Ce secours disparaît à l'étape 4.

### 8.5 Bandeau d'état

Messages ajoutés, par ordre de priorité, juste après « Mac injoignable » :
- « iPhone non appairé : lance ptzd pair sur le Mac » (`unpaired`, ou aucune clé locale) ;
- « Code d'appairage refusé » (`badCode` ou `pairingClosed`, affiché jusqu'au prochain essai) ;
- « Appairage : active Tailscale sur l'iPhone » (un code attend, mais Tailscale n'a pas répondu ; les reconnexions continuent).

## 9. Erreurs

| Cas | Comportement |
|---|---|
| Pas d'`authenticated` 10 s après l'acceptation | Connexion coupée, journalisée |
| Appareil inconnu, signature fausse | `unpaired` ou `authFailed`, puis fermeture ; journalisé |
| Code faux | `badCode` ; au 3e essai faux, le code est annulé |
| Pas de code en cours, ou code expiré | `pairingClosed` |
| Message avant authentification | `notAuthenticated`, message ignoré |
| go2rtc ne répond pas au relais | `webrtcError` ; l'app réessaie comme aujourd'hui (pendant la transition : `POST` direct) |
| Bonjour ne trouve rien, accès local refusé | Tailscale seul, sans message |
| Écoute locale ou annonce Bonjour impossible | Journalisé ; Tailscale et 127.0.0.1 continuent |
| `devices.json` illisible | Aucun appareil accepté, journalisé ; 127.0.0.1 continue |

## 10. Tests

- **Protocole** : encodage et décodage de chaque nouveau message, rejet des champs manquants.
- **`ptzd`** (avec horloge et planificateur factices) :
  - signature juste, fausse, appareil inconnu ;
  - nonce rejoué sur une autre connexion ;
  - délai de 10 s ;
  - dispense de 127.0.0.1 ;
  - messages refusés avant authentification ;
  - appairage : code juste, faux trois fois, expiré, utilisé deux fois, absent ;
  - `revoke` ;
  - relais vers un faux go2rtc local : 201, erreur, délai dépassé, offre remplacée.
- **App** : signature avec la clé logicielle ; choix du chemin (Bonjour premier, Tailscale premier, Bonjour absent) avec des transports factices ; bandeau ; repli de transition.
- **Essai réel avec Majid** :
  1. `ptzd pair`, puis appairage depuis l'app ;
  2. Wi-Fi seul, Tailscale coupé : pilotage et vidéo ;
  3. 4G par Tailscale : pilotage et vidéo ;
  4. depuis un autre appareil du Wi-Fi : `http://<Mac>:1984` ne répond plus, une connexion WebSocket à `ptzd` sans appairage est refusée, le RTSP sans mot de passe est refusé ;
  5. HomeKit affiche toujours la caméra.

## 11. Ordre de bascule

Chaque étape laisse un système qui marche.

1. `ptzd` (écoute locale, Bonjour, authentification, appairage, relais) et l'app (clé, appairage, choix du chemin, vidéo relayée avec le secours direct), installés ensemble.
2. Appairage de l'iPhone de Majid, puis essai.
3. go2rtc : vérification préalable sur l'instance de test, puis bascule avec Majid (§ 7), puis Homebridge.
4. Retrait du secours direct dans l'app, puis réinstallation sur l'iPhone.

## 12. Limites connues

- Le port WebRTC 8555 reste ouvert. Sans offre négociée par `ptzd`, il ne donne aucune image : les identifiants ICE s'échangent dans la négociation.
- L'annonce Bonjour révèle l'existence d'un service `Nacelle` aux appareils du réseau où se trouve le Mac.
- Un appareil retiré garde une connexion déjà ouverte jusqu'à sa fin. Pour la couper tout de suite, redémarrer `ptzd`.
- Un iPhone déverrouillé et volé pilote la caméra jusqu'à `ptzd revoke`.
- Sur le réseau local, l'identifiant de l'appareil (`deviceID`) passe en clair dans la poignée de main TLS (identité de la clé pré-partagée) ; tout le reste est chiffré (§ 14).
- Le port go2rtc 8555 (médias WebRTC) et RTSP (avec mot de passe) restent sur le réseau local ; les médias WebRTC sont chiffrés par WebRTC lui-même (DTLS-SRTP).
- Le flux RTSP vers Homebridge circule en clair sur le réseau local, identifiants compris : qui intercepte ce trafic lit les identifiants et les images.
- L'écoute Tailscale de `ptzd` n'accepte que les adresses Tailscale (100.64.0.0/10 et fd7a:115c:a1e0::/48) ; toute autre adresse source est refusée et journalisée.
- Quand Tailscale est coupé sur l'iPhone, l'app fait confiance au nom configuré, résolu par le DNS du réseau : un appareil hostile capable de répondre à ce nom recevrait la connexion en clair, et pendant un appairage le code. Appairer avec Tailscale actif.
- La réserve des connexions anonymes est commune au réseau local et à Tailscale : un appareil hostile à plusieurs adresses peut retarder une connexion, sans jamais prendre une place authentifiée (§ 6.3).

## 13. Points à vérifier en tête du plan

1. Comment lier `NWListener` aux seules interfaces Wi-Fi et Ethernet en suivant leurs changements : une écoute par interface (`requiredInterface`) relancée par `NWPathMonitor`, ou une seule écoute qui exclut les autres types d'interface. Et comment annoncer Bonjour une seule fois.
2. Le comportement de go2rtc 1.9.14 avec RTSP protégé, sur l'instance de test (§ 7).
3. La disponibilité de `SecureEnclave` dans le simulateur iOS 27.
4. La connexion de l'app à un service Bonjour : URL résolue pour `URLSessionWebSocketTask`, ou transport `NWConnection` WebSocket.

## 14. Amendement : canal chiffré sur le réseau local

Décidé par Majid le 2026-10-06, après la relecture de sécurité de la tâche 8 du plan.

**Raison.** La signature du défi ne lie ni le serveur ni la connexion. Sans canal protégé, un faux service `_nacelle._tcp` sur le Wi-Fi pouvait relayer le défi du vrai `ptzd`, le faire signer par l'iPhone et obtenir une session authentifiée sur le vrai `ptzd` (pilotage, vie privée, vidéo). Par Tailscale, ce relais est impossible : WireGuard authentifie les pairs.

**Principe.** Toute connexion par le réseau local passe en TLS avec une clé pré-partagée propre à chaque iPhone, remise à l'appairage, qui ne passe que par Tailscale. Un relais sans la clé échoue dès la poignée de main ; un relais passif ne voit que du chiffré.

| Point | Règle |
|---|---|
| Secret | 32 octets aléatoires par appareil, créés par `ptzd` à l'appairage, gardés dans `devices.json` (droits 600) avec la clé publique, remis dans `paired {deviceID, lanKey}` |
| Appairage | `pair` est refusé sur l'écoute du réseau local (`pairingClosed`, « Appairage par Tailscale seulement ») ; l'app ne l'envoie que par Tailscale (§ 8.3) |
| TLS | TLS 1.2 (TLS 1.3 n'accepte pas les clés pré-partagées sur macOS 27), suite `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (confidentialité persistante), identité TLS = `deviceID`, reprise de session et tickets coupés des deux côtés (sinon une mauvaise clé ou un appareil retiré pourrait reprendre une session) |
| Clés côté `ptzd` | La liste des clés d'une écoute est figée à son lancement : `ptzd` relance ses écoutes du réseau local après chaque appairage ; une clé factice garde TLS-PSK actif quand aucun appareil n'est appairé ; à chaque poignée de main, `devices.json` est relu et un appareil retiré est refusé tout de suite |
| Défi | Le défi et la signature restent exigés à l'intérieur du canal chiffré (§ 6.3) |
| Tailscale et 127.0.0.1 | Inchangés : WebSocket simple (WireGuard protège Tailscale) |
| App | Le secret est rangé dans le trousseau avec la clé de l'appareil ; « Oublier cet appairage » efface les deux ; sans secret, l'app n'essaie pas le réseau local ; délai d'ouverture de 10 s (un échec TLS sur un service Bonjour ne se signale jamais) |
| Réglages partagés | Les réglages TLS (version, suite, reprise) sont dans `NacelleProtocol`, communs au Mac et à l'iPhone |

Vérifié en amont (macOS 27, simulateur iOS 27) : échanges dans les deux sens, mauvaise clé refusée en quelques millisecondes, identité inconnue refusée, relais sans clé refusé, API non dépréciées, aucun avertissement en Swift 6 strict.

## 15. Amendement : découverte et appairage par QR code

Décidé par Majid le 2026-10-06 : l'app découvre le Mac par Bonjour et retient son adresse locale, utilisée aussi en 4G par la route de sous-réseau du NAS ; l'appairage se fait par QR code seulement, sur le réseau local, et remplace le code à 6 chiffres et la règle « appairage par Tailscale seulement » (§ 6.4, § 8.1, § 8.3, § 8.5, § 14). Détails : [2026-10-06-decouverte-qr-design.md](2026-10-06-decouverte-qr-design.md).
