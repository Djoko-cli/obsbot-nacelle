# Spec : découverte du Mac et appairage par QR code

Amende la spec de l'accès local ([2026-10-06-acces-local-design.md](2026-10-06-acces-local-design.md)), qui reste valable pour tout ce qui n'est pas repris ici. Validée par Majid le 2026-10-06, partie par partie.

## 1. Objectif

- **Aucune adresse à saisir.** L'app découvre le Mac par Bonjour (« Recherche de la Nacelle à proximité… ») et retient son adresse locale.
- **Une seule adresse partout.** Cette adresse locale sert à la maison, directement, et en 4G, par la route de sous-réseau que le NAS publie déjà dans le tailnet.
- **Appairage par QR code seulement**, possible sur le réseau local, et sûr même face à un faux service sur le Wi-Fi.
- Un champ d'adresse reste disponible **en repli**.

## 2. Périmètre

Dans le périmètre :
- découverte Bonjour dans l'app, avec la liste des Mac trouvés ;
- adresse retenue, utilisée en TLS sur le réseau local et à travers la route du NAS ;
- appairage par QR code : `ptzd pair` affiche le QR ; l'app le scanne ;
- champ « Adresse du Mac (repli) » ;
- retrait du code à 6 chiffres et de la règle « appairage par Tailscale seulement ».

Hors périmètre :
- la route de sous-réseau elle-même : le NAS publie déjà tout le réseau local dans le tailnet, réglage de Majid ;
- la réservation DHCP de l'adresse du Mac : déjà faite par Majid ;
- la sensibilité du joystick (backlog).

## 3. Choix de Majid

| Question | Réponse |
|---|---|
| Besoin | Taper l'IP locale, et qu'elle marche aussi en 4G ; puis : aucune IP à saisir, découverte Bonjour visible |
| Chemin en 4G | Routage de sous-réseau (celui du NAS) |
| Appairage | Possible sur le réseau local, par QR code seulement |
| Repli | Un champ d'adresse visible dans les réglages |

## 4. Faits vérifiés (2026-10-06)

- L'iPhone en 4G, Tailscale actif, joint l'adresse locale du Mac par la route du réseau local que publie le NAS ; la connexion arrive au Mac par l'Ethernet, avec l'adresse source du NAS (traduction d'adresse du routeur de sous-réseau).
- Une route `/32` publiée par le Mac lui-même passe devant celle du NAS et fait arriver le trafic en local depuis l'adresse du Mac : elle a été retirée et ne doit pas être utilisée.
- L'écoute locale de `ptzd` (Ethernet et Wi-Fi, TLS à clé pré-partagée) reçoit donc l'iPhone à la maison comme en 4G, sans changement d'écoute.

## 5. Architecture

```
À la maison          iPhone ──Bonjour / adresse retenue── TLS ──► ptzd (écoute locale)
En 4G                iPhone ──Tailscale──► NAS (route du réseau local) ──► ptzd (écoute locale, TLS)
Appairage            Terminal du Mac : ptzd pair ──127.0.0.1──► ptzd : ouvre l'appairage, renvoie le secret
                     iPhone scanne le QR ──TLS (clé = secret du QR)──► ptzd : pair + preuve ► paired + secret de l'iPhone
```

## 6. Protocole (`NacelleProtocol`)

Messages ajoutés ou modifiés :

| Sens | Message | Champs | Rôle |
|---|---|---|---|
| app ou CLI → serveur | `openPairing` | aucun | Ouvre un appairage ; accepté **seulement depuis 127.0.0.1** |
| serveur → CLI | `pairingOpened` | `pairingID`, `secret` (32 octets, base64), `expiresAt` (secondes depuis 1970), `hosts` (adresses IPv4 locales), `port` | Ce qu'il faut pour le QR |
| app → serveur | `pair` | `pairingID`, `publicKey` (x963, base64), `name`, `proof` (base64) | **Remplace** l'ancien `pair {code, …}` |

- `proof` = HMAC-SHA256, clé = secret de l'appairage, sur la chaîne UTF-8 `nacelle-pair-v1|<défi en base64>|<clé publique en base64>`. Le défi est celui reçu à l'ouverture de la connexion.
- Codes d'erreur : `badCode` signifie désormais « preuve fausse » ; `pairingClosed` « aucun appairage en cours, expiré, déjà utilisé, ou autre identifiant ». Ajout de `notLocal` : `openPairing` reçu d'ailleurs que de 127.0.0.1, ou `pair` reçu ailleurs que sur l'écoute du réseau local.
- `paired {deviceID, lanKey}`, `challenge`, `auth`, `authenticated` : inchangés.

**Contenu du QR code** : l'URL `nacelle://pair?v=1&id=<pairingID>&k=<secret en base64url>&h=<adresse>[,<adresse>…]&p=<port>`.

## 7. `ptzd`

### 7.1 Appairage

- `openPairing` (depuis 127.0.0.1) crée un appairage **en mémoire** : identifiant aléatoire (8 caractères hexadécimaux), secret de 32 octets, expiration à 5 min. Un nouvel `openPairing` remplace l'appairage en cours. `pairing.json` disparaît.
- Les écoutes du réseau local sont relancées pour connaître l'identité TLS `pair-<pairingID>`, avec le secret pour clé, en plus des secrets des appareils. À l'expiration ou après usage, l'identité est retirée (veto immédiat) et les écoutes sont relancées.
- `pair` n'est accepté que sur l'écoute du réseau local, dans une connexion pas encore authentifiée, avec un `pairingID` en cours et une preuve juste. Succès : l'appareil est ajouté (clé publique et secret de l'iPhone, comme aujourd'hui), l'appairage est consommé, `paired` est envoyé, l'app enchaîne avec `auth` sur le même défi. Preuve fausse : `badCode` ; au 3e échec, l'appairage est annulé.
- Sur l'écoute Tailscale et sur 127.0.0.1, `pair` est refusé (`notLocal`).
- Journal : « Appairage ouvert (<pairingID>), valable 5 min. », « Appareil appairé : … », « Appairage <pairingID> : preuve fausse (<adresse>). », « Appairage <pairingID> expiré. ».

### 7.2 `ptzd pair`

- Se connecte en WebSocket à `ws://127.0.0.1:<port>` (port de `config.json`), envoie `openPairing`, attend `pairingOpened` (5 s au plus).
- Affiche le QR code dans le Terminal (caractères demi-blocs, généré avec CoreImage), puis l'URL en texte et l'heure d'expiration.
- Service injoignable : « ptzd ne répond pas : le service est-il lancé ? », code de sortie 1.

### 7.3 Annonce Bonjour

Le nom du service devient « Nacelle sur <nom de l'ordinateur> » (nom de partage de macOS), pour distinguer plusieurs Mac. Type et TXT inchangés.

## 8. L'app iOS

### 8.1 Réglages et premier lancement

- **Non appairé** : écran « Recherche de la Nacelle à proximité… » (indicateur d'activité) avec la liste des services `_nacelle._tcp` trouvés, et le bouton **« Scanner le QR code »**. La demande d'accès au réseau local d'iOS apparaît à ce moment.
- **Scanner** : lecteur de QR code plein écran (caméra). `NSCameraUsageDescription` : « Pour scanner le QR code affiché par ptzd pair sur le Mac. » Caméra refusée : message avec renvoi vers les Réglages d'iOS.
- **Champ « Adresse du Mac (repli) »**, toujours visible dans les réglages : pré-rempli par l'adresse du QR (première de `h`) ou par celle du service Bonjour choisi ; modifiable à la main.
- Section appairage : état « Appairé » ou « Non appairé », boutons « Scanner le QR code » et « Oublier cet appairage ». Le champ du code à 6 chiffres disparaît.

### 8.2 Connexion

- Candidates, en parallèle, comme aujourd'hui : le service Bonjour (TLS) et l'**adresse du champ** :
  - adresse IPv4 privée (10/8, 172.16/12, 192.168/16) ou nom en `.local` : TLS à clé pré-partagée avec le secret de l'iPhone ;
  - adresse Tailscale (100.64.0.0/10) ou nom en `.ts.net` : WebSocket simple, vers l'écoute Tailscale (appareil déjà appairé seulement).
- La première connexion authentifiée l'emporte ; reconnexion et délais inchangés.
- En 4G, l'adresse IPv4 privée passe par la route du NAS : Tailscale doit être actif sur l'iPhone, et les routes de sous-réseau acceptées.

### 8.3 Appairage

1. Le scan donne `pairingID`, le secret, les adresses et le port. Un QR mal formé ou d'une autre version est refusé tout de suite (« QR code non reconnu »).
2. L'app essaie, en parallèle, chaque adresse du QR et le service Bonjour, en TLS avec l'identité `pair-<pairingID>` et le secret du QR pour clé.
3. Au défi, elle crée sa clé si besoin et envoie `pair {pairingID, publicKey, name, proof}`.
4. Sur `paired`, elle range le secret de l'iPhone, retient l'adresse qui a répondu (dans le champ, s'il était vide), puis envoie `auth` sur le même défi.
5. Le secret du QR n'est jamais rangé : il ne sert qu'à cette connexion.

### 8.4 Bandeau d'état

« iPhone non appairé : scanne le QR code de ptzd pair » remplace l'ancien message ; « QR code refusé : relance ptzd pair » remplace « Code d'appairage refusé ». « Appairage : active Tailscale » disparaît.

## 9. Erreurs

| Cas | Comportement |
|---|---|
| QR expiré, déjà utilisé ou d'un autre Mac | `pairingClosed` ; « QR code refusé : relance ptzd pair » |
| Preuve fausse (secret altéré) | `badCode` ; au 3e échec, appairage annulé |
| Poignée de main TLS de l'appairage échoue (mauvais secret, appairage retiré) | Aucune réponse ; délai d'ouverture de 10 s ; « QR code refusé » |
| `openPairing` hors 127.0.0.1, `pair` hors réseau local | `notLocal`, journalisé |
| `ptzd pair` sans service | Message et code de sortie 1 |
| Aucun Mac trouvé | La recherche continue ; le champ de repli reste disponible |
| Caméra refusée | Message avec renvoi vers les Réglages d'iOS |
| 4G sans Tailscale ou sans route du NAS | « Mac injoignable » |

## 10. Tests

- **Protocole** : `openPairing`, `pairingOpened`, nouveau `pair` ; calcul de la preuve (vecteur connu) ; analyse de l'URL du QR (valide, version inconnue, champs manquants, secret de mauvaise longueur).
- **`ptzd`** : `openPairing` depuis 127.0.0.1 seulement ; appairage complet par TLS sur l'écoute locale de test avec le secret du QR ; preuve fausse, 3 échecs, expiration, usage unique, nouvel `openPairing` qui remplace l'ancien ; `pair` refusé sur Tailscale et 127.0.0.1 ; écoutes relancées après ouverture, usage et expiration ; rendu du QR (taille, lisibilité vérifiée en décodant l'image produite).
- **App** : analyse du QR ; course des candidates d'appairage ; preuve envoyée ; secret de l'iPhone rangé, adresse retenue ; choix TLS ou non selon l'adresse du champ ; écran de découverte avec un faux navigateur Bonjour.
- **Essai réel avec Majid** : `ptzd pair`, scan, appairage en Wi-Fi ; pilotage et vidéo en Wi-Fi, puis en 4G par la route du NAS ; noter si la vidéo en 4G passe par le NAS plutôt que par le relais Tailscale.

## 11. Bascule

1. `ptzd` et l'app mis à jour ensemble. L'iPhone déjà appairé le reste : `devices.json` et les secrets ne changent pas.
2. Essai d'un nouvel appairage par QR : « Oublier cet appairage » sur l'iPhone, `ptzd revoke` de l'ancien appareil, puis scan.

## 12. Limites connues

- Qui voit le QR code à l'écran du Mac pendant ses 5 minutes peut appairer un appareil : il ne faut l'afficher que le temps du scan.
- Tout programme du Mac peut ouvrir un appairage par 127.0.0.1, comme il peut déjà piloter la caméra (spec de l'accès local § 6.3).
- En 4G, le chemin dépend de la route de sous-réseau du NAS et de l'acceptation des routes sur l'iPhone.
- Le secret du QR passe dans l'URL affichée en texte par `ptzd pair` : même règle que le QR.

## 13. Points à vérifier en tête du plan

1. Génération d'un QR code dans le Terminal (CoreImage `CIQRCodeGenerator`, demi-blocs Unicode) et lecture fiable par l'appareil photo de l'iPhone.
2. Lecteur de QR dans l'app : VisionKit (`DataScannerViewController`) ou AVFoundation ; comportement dans le simulateur (sans caméra).
3. Ajout d'une identité TLS à clé pré-partagée pour l'appairage dans les écoutes du réseau local, et retrait par veto.
4. Adresse d'un service Bonjour à retenir côté app (IPv4, sans zone), après résolution.
