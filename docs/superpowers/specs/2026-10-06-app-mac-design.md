# Spec : PTZBot pour Mac (sous-projet A)

Ajoute une app Mac dans la barre des menus pour administrer `ptzd`, le suivi IA (Mac et iPhone) et les durcissements reportés de l'appairage par QR code. Amende la [spec de la découverte et du QR code](2026-10-06-decouverte-qr-design.md), qui reste valable pour tout ce qui n'est pas repris ici. Validée par Majid le 2026-10-06, partie par partie, avec les maquettes.

## 1. Objectif

- **Appairer un iPhone depuis le Mac** sans Terminal : le QR code s'affiche en vraie image dans une fenêtre (le QR en texte de `ptzd pair` se lit mal au banc).
- **Voir et gérer qui accède à la caméra** : appareils appairés, clients connectés, expulsion temporaire, retrait avec coupure immédiate.
- **Piloter la vie privée et le suivi IA depuis le Mac**, et le suivi IA aussi depuis l'iPhone.
- **Durcir l'appairage par QR code** (points reportés de la relecture finale de la découverte).

## 2. Périmètre

Dans le périmètre (sous-projet A) :
- l'app **PTZBot pour Mac**, dans la barre des menus : panneau, fenêtre « Appairer un iPhone », fenêtre « Appareils », ouverture à la connexion ;
- les messages d'administration de `ptzd`, acceptés seulement de 127.0.0.1 ;
- l'expulsion avec blocage de 10 min, le retrait qui coupe tout de suite, l'annulation d'un appairage ;
- le suivi IA : `obsbot-ai on|off`, état partagé, interrupteur dans les deux apps, nouvelles règles de prise en main ;
- dans l'app iOS : bouton du suivi IA, durcissements du QR, port retenu, QR refusé sans coupure, message d'expulsion, **vouvoiement** de tous les textes ;
- une installation provisoire de l'app Mac par `scripts/install-mac.sh`.

Hors périmètre, pour le **sous-projet B** (sa propre spec) :
- `ptzd` embarqué dans PTZBot.app et inscrit comme service de la session (`SMAppService.agent`), avec l'**interrupteur du service** dans le panneau et la migration depuis l'installation actuelle ;
- l'**accompagnement de l'installation du SDK** dans l'app (le SDK est propriétaire et ne peut pas être dans l'image disque) ;
- l'**image disque** (glisser PTZBot dans Applications), **Sparkle** et l'outil de publication, selon le brief de déploiement des apps de Majid (Sparkle 2.10.0, flux `appcast.xml` dans le dépôt, clé Ed25519 et certificat « Djoko-cli Code Signing » existants).

Hors périmètre tout court : les réglages audio de Homebridge, la sensibilité du joystick (backlog).

## 3. Choix de Majid

| Question | Réponse |
|---|---|
| Forme | Barre des menus, sans icône dans le Dock |
| Expulser | Couper et bloquer 10 min (tant que `ptzd` tourne), appairage gardé |
| Canal d'administration | A : la connexion de confiance existante, 127.0.0.1 |
| Style du menu | B : un panneau (comme Wi-Fi ou Son), pas un menu classique |
| Icône | Silhouette simplifiée de la Tiny 2, dessinée (§ 8.2) |
| Textes | **Vouvoiement** dans les apps (Mac et iOS) et dans les sorties de `ptzd` destinées à l'utilisateur |
| Suivi IA | Interrupteur dans les deux apps ; ouvrir PTZBot ne touche plus au suivi ; le premier mouvement de joystick le coupe |
| Installation | À terme, image disque et Sparkle (B) ; `ptzd` embarqué dans l'app, accompagnement manuel du SDK (B) |
| Découpage | A (cette spec) puis B |

## 4. Faits vérifiés et points à vérifier

Vérifiés en préparant cette spec (2026-10-06) :
- Le SDK déclare `AiWorkModeHuman` (suivi d'une personne) et `AiSubModeNormal` ; `obsbot-ai-off` appelle déjà `cameraSetAiModeU(AiWorkModeNone, 0)`.
- `PTZController` accepte déjà `privacy {on}` de n'importe quel client authentifié, connexion de confiance comprise.
- Les connexions de confiance occupent aujourd'hui les mêmes 4 places que les iPhone (`maxClients`).

À vérifier en tête du plan (spikes) :
1. `cameraSetAiModeU(AiWorkModeHuman, AiSubModeNormal)` rallume bien le suivi sur la Tiny 2 (au banc, avec Majid : la caméra bouge).
2. `MenuBarExtra` en style fenêtre (macOS 15) : ouverture d'une `Window` SwiftUI au premier plan depuis une app sans Dock (`LSUIElement`), et sa fermeture.
3. `SMAppService.mainApp` depuis une app signée en local (ad hoc) installée dans `~/Applications` : inscription, état `requiresApproval`, désinscription.

## 5. Architecture

- **PTZBot pour Mac** : app SwiftUI (`MenuBarExtra`), macOS 15, dossier `mac/app/`, projet xcodegen comme l'app iOS, identifiant `io.github.djoko-cli.ptzbot`, **sans bac à sable** (elle lit la configuration de `ptzd` et, dans B, gère son service). Partage le paquet `NacelleProtocol`.
- **Lien avec `ptzd`** : un seul WebSocket gardé ouvert vers `ws://127.0.0.1:<port>` (port lu dans `~/Library/Application Support/ObsbotNacelle/config.json`, 1985 si absent ou illisible), qui reçoit l'état en direct ; reconnexion toutes les 2 s.
- **`ptzd`** gagne l'administration (§ 6 et § 7), garde sa connexion de confiance et ses écoutes.
- **App iOS** : changements du § 9 seulement.
- `ptzd pair`, `ptzd devices` et `ptzd revoke` restent en ligne de commande, comme repli et pour le SSH.

## 6. Protocole (`NacelleProtocol`)

Messages ajoutés (tous en JSON avec un champ `type`, dates en secondes depuis 1970) :

| Sens | Message | Champs | Rôle |
|---|---|---|---|
| Mac → serveur | `adminWatch` | aucun | Demande l'état d'administration, envoyé tout de suite puis à chaque changement |
| Mac → serveur | `revoke` | `deviceID` | Retire l'appareil et coupe ses connexions |
| Mac → serveur | `kick` | `deviceID` | Coupe ses connexions et le bloque 10 min |
| Mac → serveur | `unblock` | `deviceID` | Lève le blocage |
| Mac → serveur | `closePairing` | aucun | Annule l'appairage en cours |
| app ou Mac → serveur | `aiTracking` | `on` | Allume ou coupe le suivi IA |
| serveur → Mac | `adminState` | `state` | L'état d'administration (ci-dessous) |

- `adminWatch`, `revoke`, `kick`, `unblock` et `closePairing` ne sont acceptés que d'une connexion de confiance (127.0.0.1) ; ailleurs : `notLocal`, journalisé, comme `openPairing`.
- `adminState.state` : `devices` (`deviceID`, `name`, `pairedAt`, `blockedUntil` ou `null`), `clients` (`id`, `deviceID` et `name` ou `null` pour un client du Mac, `route` parmi `localNetwork`, `tailscale`, `mac`, `address`, `since`), `pairing` (`pairingID`, `expiresAt`, ou `null` ; jamais le secret). Seuls les clients authentifiés ou de confiance y figurent.
- Nouveau code d'erreur **`blocked`** : appareil expulsé (« Expulsé par le Mac jusqu'à HH:MM. »).
- `StateSnapshot` gagne **`aiTracking`** : `on`, `off` ou `unknown` ; absent du JSON (ancien `ptzd`) : `unknown`.

Exemple :

```json
{"type":"kick","deviceID":"5a3c9e01b7d24f6a8c1e0d93f2a4b6c7"}
{"type":"adminState","state":{"devices":[{"deviceID":"5a3c9e01b7d24f6a8c1e0d93f2a4b6c7","name":"iPhone","pairedAt":1791300000,"blockedUntil":null}],"clients":[{"id":76,"deviceID":"5a3c9e01b7d24f6a8c1e0d93f2a4b6c7","name":"iPhone","route":"localNetwork","address":"192.0.2.89","since":1791301000}],"pairing":null}}
```

## 7. `ptzd`

### 7.1 Clients et places

- Chaque connexion garde l'appareil authentifié (identifiant et nom), son chemin (`mac` pour une écoute de boucle locale, `localNetwork` pour une écoute TLS du réseau local, `tailscale` sinon) et son heure d'authentification.
- **Deux réserves de 4 places** : les iPhone authentifiés d'un côté, les connexions de confiance du Mac de l'autre. L'app Mac, toujours connectée, ne prend jamais la place d'un iPhone. Les réserves des connexions anonymes ne changent pas.

### 7.2 État d'administration

Recalculé et envoyé aux connexions qui ont demandé `adminWatch` après chaque événement : authentification ou départ d'un client authentifié ou de confiance, appairage d'un appareil, retrait, expulsion, déblocage, fin d'un blocage, ouverture, fermeture, expiration ou usage d'un appairage.

### 7.3 Expulser, débloquer, retirer

- **`kick`** : envoie `blocked` à chaque connexion de l'appareil puis les ferme ; note le blocage en mémoire pour 10 min (une minuterie le lève et republie l'état). Un appareil bloqué qui revient est refusé **après** la vérification de sa signature, avec `blocked` : un inconnu n'apprend rien des blocages. Journal : « Appareil 5a3c9e01 (iPhone) expulsé jusqu'à 20:14. », puis « Client N refusé : appareil 5a3c9e01 expulsé jusqu'à 20:14. ».
- **`unblock`** : lève le blocage, republie l'état. Journal : « Appareil 5a3c9e01 (iPhone) débloqué. ».
- **`revoke`** : retire l'appareil de `devices.json`, coupe tout de suite ses connexions, relance les écoutes du réseau local (le veto TLS refusait déjà son secret). Journal : « Appareil 5a3c9e01 (iPhone) retiré depuis le Mac. ». `ptzd revoke` en ligne de commande garde son comportement (connexions ouvertes jusqu'à leur fin).
- Appareil inconnu : erreur `badMessage` « Appareil inconnu. » ; `devices.json` illisible : son message actuel.

### 7.4 Appairage

- **`closePairing`** : ferme l'appairage en cours, annule son échéance, relance les écoutes du réseau local. Journal : « Appairage <id> annulé. ».
- **Nom d'appareil nettoyé à l'enregistrement** : sans caractères de contrôle ni séparateurs de ligne Unicode (U+2028, U+2029), espaces aux bords retirés, 40 caractères au plus, « appareil » s'il est vide. Il ressort propre partout (journal, `ptzd devices`, app Mac).
- L'invitation contient **4 adresses au plus**.

### 7.5 Suivi IA

- L'utilitaire `obsbot-ai-off` devient **`obsbot-ai`** : `obsbot-ai off` (`cameraSetAiModeU(AiWorkModeNone, 0)`) et `obsbot-ai on` (`cameraSetAiModeU(AiWorkModeHuman, AiSubModeNormal)`). Mêmes protections : caméra attendue 10 s au plus, sortie sans refermer le SDK. `config.json` : clé `aiPath` ; l'ancienne clé `aiOffPath` reste lue si la nouvelle manque.
- `ptzd` retient le **dernier ordre** : `unknown` au démarrage et après un rebranchement de la caméra hors vie privée (l'état ne se lit pas).
- Règles :
  1. **`takeControl` ne coupe plus le suivi** ; le message reste accepté pour la compatibilité.
  2. **Le premier mouvement** (`move` non nul) **coupe le suivi** s'il n'est pas `off` ; le mouvement est appliqué quand même ; l'état de contrôle passe à `taking` le temps de la coupure, puis `ready` (ou `failed`, bandeau actuel).
  3. **Entrer en vie privée coupe le suivi** d'abord s'il n'est pas `off`.
  4. **En vie privée, `aiTracking` est refusé** (`privacyActive`).
  5. Au rebranchement de la caméra en vie privée : comportement actuel (vie privée réappliquée, suivi coupé).
- `aiTracking {on}` est accepté d'un iPhone authentifié comme d'une connexion de confiance ; il lance `obsbot-ai on|off` (état `taking` pendant l'appel), puis publie le nouvel état ; en cas d'échec, l'état ne change pas et l'erreur `uvcFailed` porte le message de l'utilitaire.

## 8. L'app PTZBot pour Mac

### 8.1 Panneau (clic sur l'icône)

De haut en bas (maquette B validée) :
- **PTZBot** et l'état du service : « Actif », « Démarrage… » (connexion en cours), « Ne répond pas » (avec « Ouvrir le journal », qui ouvre `~/Library/Logs/obsbot-nacelle/ptzd.log` dans Console) ;
- **Caméra** : branchée ou débranchée ;
- **Vie privée** : interrupteur ;
- **Suivi IA** : interrupteur, « État inconnu » en petit quand c'est le cas ; grisé en vie privée ;
- **Clients connectés · N** : une carte par client authentifié (nom, chemin en clair : « Réseau local », « Tailscale », « Ce Mac », heure de connexion), bouton **« Expulser »** sauf pour les clients du Mac ;
- boutons **« Appairer un iPhone… »** et **« Appareils… »** ;
- **« Ouvrir à la connexion »** (case) et **« Quitter »**.

Tant que `ptzd` ne répond pas, tout est grisé sauf l'état, le journal, la case et « Quitter ». Une action refusée affiche le message de `ptzd` sous l'action.

### 8.2 Icône

Silhouette de la Tiny 2 **dessinée en formes nettes** (pas tirée de la photo, donc versionnée), en image modèle (template) que macOS teinte selon la barre ; estompée (40 %) quand `ptzd` ne répond pas. Repère 300 × 300, origine en haut à gauche, puis cadrage sur la zone utile :
- bras : rectangle arrondi (150, 38, 92 × 76, rayon 36) et tige (186, 100, 36 × 58) ;
- liseré de 9 autour de la tête, évidé ;
- tête : rectangle arrondi (70, 22, 118 × 112, rayon 34) ;
- objectif : anneau évidé de centre (126, 76), rayon extérieur 38, centre plein de rayon 25 ;
- socle : rectangle arrondi (52, 162, 216 × 112, rayon 30).

### 8.3 Fenêtre « Appairer un iPhone »

- Envoie `openPairing` à l'ouverture ; affiche le QR code en image (CoreImage, sans lissage, marge blanche), « Dans PTZBot sur l'iPhone, touchez **Scanner le QR code**. », une barre du temps restant, « Valable encore m:ss · une seule fois », les adresses du Mac, « Ne montrez ce code qu'à l'iPhone à appairer. » et **« Annuler »**.
- **Annuler ou fermer la fenêtre envoie `closePairing`.** Expiration : « QR code expiré » et « Recommencer ».
- Appairage réussi (l'appairage en cours disparaît et un appareil nouveau apparaît dans `adminState`) : « iPhone appairé » avec son identifiant court, fermeture après 3 s.
- Aucune adresse locale dans l'invitation : « Aucune adresse sur le réseau local : reliez le Mac au Wi-Fi ou à l'Ethernet. ».

### 8.4 Fenêtre « Appareils »

Une ligne par appareil appairé : nom, identifiant court, date d'appairage, état (« connecté · Réseau local », « expulsé jusqu'à HH:MM », « hors ligne »), boutons **« Retirer… »** (confirmation : « L'appareil devra être réappairé par QR code. Ses connexions sont coupées tout de suite. ») et **« Débloquer »** s'il est expulsé. Bouton « Appairer un iPhone… ».

### 8.5 Ouverture à la connexion

Case du panneau sur `SMAppService.mainApp` (inscrire, désinscrire). État `requiresApproval` : « Autorisez PTZBot dans Réglages › Général › Ouverture » et bouton qui ouvre ces réglages.

### 8.6 Installation provisoire (jusqu'à B)

`scripts/install-mac.sh` génère le projet (xcodegen), compile l'app en Release, signée ad hoc, la copie dans `~/Applications/PTZBot.app` et la lance, en plus de `ptzd` et de `obsbot-ai`. La désinstallation du README retire aussi l'app.

### 8.7 Textes

Au **vouvoiement**, en français : « Appairer un iPhone… », « Expulser », « Retirer… », « Débloquer », « Ouvrir à la connexion », « Quitter », etc.

## 9. L'app iOS

- **Bouton du suivi IA**, à côté de ceux du son et de la vie privée : icône de cadrage d'une personne, état du dernier ordre, grisé en vie privée et sans état de `ptzd`.
- **QR code** : accepté avec **4 adresses au plus**, toutes des IPv4 locales (10/8, 172.16/12, 192.168/16, 169.254/16) ; sinon « QR code non reconnu ».
- **Port retenu** : quand le champ d'adresse est vide, l'app retient l'adresse **et le port** du Mac qui a appairé l'iPhone.
- **QR refusé alors que l'iPhone est déjà appairé** : « QR code refusé : relancez l'appairage sur le Mac » sans couper la connexion ; les reconnexions normales continuent.
- **Expulsion** (`blocked`) : « Expulsé par le Mac : réessayez plus tard » ; plus de reconnexion automatique jusqu'au prochain retour au premier plan.
- **Vouvoiement de tous les textes**, par exemple « iPhone non appairé : scannez le QR code affiché sur le Mac », « QR code refusé : relancez l'appairage sur le Mac », « Autorisez l'appareil photo pour PTZBot dans les Réglages d'iOS. », « Visez le QR code affiché sur le Mac. », « Sur le Mac, ouvrez PTZBot › Appairer un iPhone… (ou lancez ptzd pair dans le Terminal), puis scannez le QR code. ». Les messages d'erreur de `ptzd` montrés à l'utilisateur passent aussi au « vous » (« relancez », « reliez »).

## 10. Erreurs

| Cas | Comportement |
|---|---|
| `ptzd` injoignable | App Mac grisée, « Ne répond pas », reconnexion toutes les 2 s |
| Action d'administration hors 127.0.0.1 | `notLocal`, journalisé |
| `revoke`, `kick`, `unblock` sur un appareil inconnu | « Appareil inconnu. » |
| Appareil expulsé qui revient | `blocked` après vérification de la signature ; iPhone : « Expulsé par le Mac : réessayez plus tard » |
| `aiTracking` en vie privée | `privacyActive` |
| `obsbot-ai` en échec | État inchangé, message de l'utilitaire ; pour la coupure au mouvement, bandeau « Suivi IA non coupé… » |
| `config.json` illisible | App Mac : port 1985, mention dans le panneau |
| QR expiré dans la fenêtre | « QR code expiré » et « Recommencer » |

## 11. Tests

- **Protocole** : encodage et décodage de chaque nouveau message, de `adminState`, de `blocked`, de `aiTracking` ; ancien état sans `aiTracking` lu `unknown` ; bornes du lien du QR.
- **`ptzd`** (vraies connexions de test, horloge simulée) : administration refusée hors 127.0.0.1 et journalisée ; état publié à chaque événement du § 7.2 ; retrait qui coupe une vraie connexion TLS ; appareil expulsé refusé après signature, réaccepté après déblocage et après l'échéance ; deux réserves de 4 places ; nom nettoyé ; règles du suivi IA avec un faux utilitaire (allumer, couper, premier mouvement, vie privée, refus en vie privée, `takeControl` sans effet, rebranchement).
- **App Mac** (fausse connexion, faux `SMAppService`) : état traduit en panneau ; message envoyé par chaque action ; parcours du QR (ouverture, image relue par Vision, appairage détecté, fermeture après 3 s, annulation qui envoie `closePairing`, expiration) ; reconnexion ; ouverture à la connexion ; dessin de l'icône (dimensions, image modèle).
- **App iOS** : durcissements du QR, port retenu, QR refusé sans coupure, `blocked`, bouton du suivi IA, nouveaux textes.
- **Banc avec Majid** (la caméra bouge) : installation ; panneau et icône ; appairage par la fenêtre de l'app (lecture du QR par l'appareil photo) ; expulsion, refus pendant le blocage, « Débloquer » ; retrait avec coupure immédiate ; suivi IA allumé puis coupé, coupé par le joystick ; vie privée depuis le Mac ; ouverture à la connexion ; textes au « vous » sur l'iPhone ; PID de go2rtc et de coreaudiod inchangés.

## 12. Mise en service

`ptzd`, `obsbot-ai`, l'app Mac et l'app iOS sont installés ensemble. L'iPhone reste appairé : rien n'est à refaire. Le nouvel appairage passe désormais par l'app Mac.

## 13. Limites connues

- Tout programme du Mac peut administrer `ptzd` par 127.0.0.1 (choix A), comme il peut déjà piloter la caméra et ouvrir un appairage.
- Un blocage s'oublie au redémarrage de `ptzd`.
- L'état du suivi IA est le dernier ordre de `ptzd` ; un geste de la main devant la caméra peut le changer.
- L'interrupteur du service, l'image disque, Sparkle et l'accompagnement du SDK arrivent avec le sous-projet B.
- Le QR en texte de `ptzd pair` reste peu lisible : c'est un repli.

## Amendements (07/10/2026, après le banc)

- **`forgetMe` (« Oublier cet appairage »)** : l'iPhone demande d'abord au Mac de le retirer de sa liste, attend la fermeture de la connexion pendant 2 s au plus, puis supprime sa clé. Un `ptzd` plus ancien, qui ne connaît pas `forgetMe`, répond `badMessage` : l'iPhone oublie alors tout de suite. Un `forgetMe` déjà parti s'achève toujours en local, même si l'app passe en arrière-plan avant la réponse.
- **Retrait depuis le Mac** : `ptzd` envoie `unpaired` « Appareil retiré depuis le Mac. » à l'iPhone connecté avant de couper. L'iPhone ne supprime sa clé que sur la route locale en TLS, où le Mac est authentifié ; par Tailscale (WebSocket simple, serveur non authentifié), il garde ses clés, passe à « non appairé » et cesse de se reconnecter. Un oubli demandé par l'iPhone lui-même s'achève sur les deux routes. `ptzd` ne journalise « retiré depuis … » que si un appareil a réellement été retiré de la liste (pas pour un oubli qui suit un retrait concurrent), mais coupe les connexions et rafraîchit l'état dans tous les cas.
- **Interrupteur du suivi IA** : grisé, avec une roue d'attente, tant que `control == taking`.
- **Bandeau « Prise en main… »** : supprimé de l'app iOS ; l'état `taking` n'affiche plus de texte (voir le § 7.3 de la [spec de la nacelle](2026-10-05-nacelle-design.md)).
- **Délai du suivi IA** : les 4,2 s viennent d'une attente interne du SDK OBSBOT à chaque lancement de `obsbot-ai`, pas de `ptzd`. L'utilitaire résident qui les supprimerait est reporté : voir [docs/backlog.md](../../backlog.md).
