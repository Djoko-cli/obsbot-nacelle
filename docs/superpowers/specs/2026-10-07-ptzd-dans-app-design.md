# Spec : ptzd dans PTZBot pour Mac (sous-projet B1)

Embarque `ptzd` et `obsbot-ai` dans PTZBot.app : le service ne tourne que pendant que l'app est ouverte. L'app accompagne aussi l'installation manuelle du SDK OBSBOT. Fait suite à la [spec de l'app Mac](2026-10-06-app-mac-design.md) (sous-projet A), qui reste valable pour tout ce qui n'est pas repris ici. Validée par Majid le 2026-10-07, partie par partie.

## 1. Objectif

- **Aucun accès à la caméra sans l'app visible.** `ptzd` démarre avec PTZBot et s'arrête avec lui, même si l'app plante (exigence de Majid au banc du 07/10).
- **Une seule chose à installer.** `ptzd` et `obsbot-ai` sont dans l'app. L'agent launchd et les binaires de `~/Library/Application Support/ObsbotNacelle/bin/` disparaissent.
- **Le SDK installé depuis l'app,** sans Terminal, avec une confirmation explicite avant de retirer la quarantaine.

## 2. Périmètre

Le sous-projet B est découpé en trois, chacun avec sa spec et son plan :
- **B1, cette spec :** `ptzd` dans l'app, son cycle de vie, la migration et l'accompagnement du SDK.
- **B2 :** la distribution, avec image disque, Sparkle, `publier.sh` et les notes de version, selon le brief de déploiement de Majid.
- **B3 :** go2rtc dans l'app. go2rtc tourne même app fermée ; son interrupteur et ses réglages sont dans PTZBot, avec un indicateur « coreaudiod ne répond pas ». B3 attend la conclusion du test `preload` sur les blocages de coreaudiod.

L'ordre décidé est B1, puis B2, puis le suivi IA instantané (branche `proto/ai-resident`, à activer dès la fin du test `preload` et à mesurer seul), puis B3. Voir `docs/backlog.md`.

Hors périmètre de B1 : le mode résident d'`obsbot-ai` et toute modification de go2rtc.

## 3. Choix de Majid

| Question | Réponse |
|---|---|
| Cycle de vie de `ptzd` | **Processus enfant de l'app** (pas `SMAppService.agent`) : il démarre avec l'app, s'arrête à « Quitter », est relancé s'il plante, et s'arrête seul si l'app disparaît |
| Interrupteur « Service ptzd » | Gardé dans le panneau. **Son état est retenu** d'un lancement à l'autre ; il est allumé au tout premier lancement |
| Quarantaine du SDK | **L'app la retire de sa propre copie, après confirmation explicite**, et seulement après avoir montré l'architecture, la signature et la provenance |
| Migration | Automatique au premier lancement, **après confirmation** ; données conservées ; anciens binaires mis à la corbeille |
| go2rtc (pour B3) | Peut tourner même PTZBot fermé ; PTZBot porte son interrupteur et ses réglages |

## 4. Points à vérifier en tête du plan (essais courts)

1. **Chargement du SDK.** `obsbot-ai`, placé dans `Contents/Helpers`, doit charger `libdev.dylib` depuis `~/Library/Application Support/ObsbotNacelle/sdk/`, par le chemin que lui donne `ptzd` (`DYLD_LIBRARY_PATH` sur un binaire sans runtime renforcé). À revérifier pour la version signée, dans B2.
2. **Réseau local.** Depuis macOS 15, `ptzd`, enfant de l'app, dépend de l'autorisation « Réseau local » de PTZBot. L'app déclare `NSLocalNetworkUsageDescription` et `NSBonjourServices` (`_nacelle._tcp`). Il faut vérifier que les écoutes et l'annonce Bonjour de `ptzd` marchent une fois l'autorisation donnée, et ce qui se passe si elle est refusée.
3. **Pare-feu.** `ptzd` change d'emplacement : macOS redemande une fois d'autoriser ses connexions entrantes. C'est Majid qui répond, pendant le banc.
4. **Surveillance du parent.** Avec un kqueue `EVFILT_PROC`/`NOTE_EXIT` sur le PID de l'app, `ptzd` s'arrête en moins d'une seconde, y compris quand l'app est tuée par SIGKILL.

## 5. Architecture

### 5.1 Contenu de l'app

- `PTZBot.app/Contents/MacOS/PTZBot` : l'app.
- `PTZBot.app/Contents/Helpers/ptzd` : compilé pendant la construction de l'app par une étape de script (`swift build -c release` sur `mac/ptzd`), puis copié dans l'app.
- `PTZBot.app/Contents/Helpers/obsbot-ai` : compilé par la même étape (`mac/ai/build.sh`), avec les en-têtes du SDK présents sur la machine de compilation. Il est lié à `@rpath/libdev.dylib`, sans chemin de recherche intégré.
- **Le SDK n'est jamais dans l'app.** La construction vérifie que `libdev.dylib` n'apparaît nulle part dans le paquet.

### 5.2 Fichiers de l'utilisateur (inchangés, sauf `sdk/`)

`~/Library/Application Support/ObsbotNacelle/` garde `config.json`, `devices.json` et l'état. Il gagne `sdk/libdev.dylib`, la copie autorisée du SDK. `aiPath` et l'emplacement des binaires ne servent plus quand `ptzd` est lancé par l'app : l'app donne à `ptzd` le chemin d'`obsbot-ai` et celui du SDK. Le journal reste `~/Library/Logs/obsbot-nacelle/ptzd.log`, avec `obsbot-ai.log`.

### 5.3 Supervision par l'app (`ServiceSupervisor`, dans PTZBotKit)

- Lance `ptzd` avec les arguments `--parent <pid de l'app>`, `--ai <chemin d'obsbot-ai>` et `--sdk <dossier du SDK>`. Sa sortie va dans le journal habituel.
- **États :** `stopped`, `starting`, `running`, `restarting(count)` et `failed(reason)`. « Actif » veut dire que la connexion de confiance à `ptzd` est établie (PanelModel).
- **Relance** après un arrêt inattendu, avec un délai de 1, 2, 4, 8, 16, puis 30 s. Au-delà de 5 arrêts en 2 min, `failed`, avec le message « ptzd s'arrête sans cesse : ouvrez le journal ».
- **Arrêt** (interrupteur éteint, « Quitter ») : SIGTERM, puis SIGKILL si `ptzd` vit encore 5 s plus tard. « Quitter » attend la fin de `ptzd`, 5 s au plus, puis se termine.
- **Interrupteur « Service ptzd »** : son état est enregistré dans les préférences de l'app, allumé par défaut.
- Aucun `ptzd` n'est lancé tant qu'un ancien agent est actif (§ 5.6).

### 5.4 `ptzd` surveille son parent

- **`--parent <pid>`** : `ptzd` observe la fin de ce processus (kqueue `EVFILT_PROC`, `NOTE_EXIT`). Si le processus n'existe déjà plus au démarrage, `ptzd` s'arrête aussitôt. À la fin du parent, `ptzd` journalise « PTZBot s'est arrêté : ptzd s'arrête. », ferme ses écoutes et sort avec le code 0.
- **`--ai <chemin>`** et **`--sdk <dossier>`** : ils remplacent `aiPath` et le dossier du SDK. `ptzd` lance `obsbot-ai` avec `DYLD_LIBRARY_PATH=<dossier du SDK>`.
- Sans ces arguments, `ptzd` garde son fonctionnement actuel, pour les essais et le repli en ligne de commande.

### 5.5 Premier lancement sur un Mac neuf

Si `config.json` manque, l'app le crée. Elle y met l'adresse IPv4 de l'interface Tailscale (100.64/10) quand il y en a une. Sinon, `ptzd` écoute seulement sur 127.0.0.1 et sur le réseau local, et le panneau affiche « Tailscale introuvable : accès depuis l'extérieur indisponible ».

### 5.6 Migration depuis l'installation actuelle

- **Détection.** Au lancement, l'app vérifie si la plist `~/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.ptzd.plist` existe ou si l'agent est chargé.
- **Alerte.** Elle affiche alors : « Une ancienne installation de ptzd tourne en arrière-plan. PTZBot va la remplacer : le service sera désormais actif seulement quand PTZBot est ouvert. Vos iPhone appairés sont conservés. », avec les boutons « Remplacer » et « Plus tard ».
- **« Remplacer ».** L'app exécute `launchctl bootout gui/<uid>/<label>`, attend que l'ancien `ptzd` soit arrêté, puis renomme la plist en `.plist.bak`. Elle met à la corbeille `bin/ptzd`, `bin/obsbot-ai` et `bin/obsbot-ai-off` sans les effacer, puis lance son propre `ptzd`.
- **Reprise du SDK.** Le SDK de `lib/libdev.dylib` (installation actuelle, déjà autorisé par Majid) est déplacé vers `sdk/libdev.dylib` sans autre demande.
- **« Plus tard ».** L'app ne lance pas son `ptzd`. Elle se branche sur l'ancien par 127.0.0.1, et le panneau affiche « Ancienne installation ». L'alerte revient au lancement suivant.
- **Échec du `bootout`.** Message, puis même comportement qu'avec « Plus tard ».

### 5.7 `install-mac.sh`

Le script se réduit à :
1. compiler l'app, `ptzd` et `obsbot-ai` compris ;
2. fermer l'app en cours ;
3. la copier dans `~/Applications/PTZBot.app` ;
4. la lancer.

Il ne touche plus à launchd, à `bin/` ni à `lib/`. Le README est mis à jour, désinstallation comprise : quitter l'app, la mettre à la corbeille ; les données restent dans `Application Support` tant qu'on ne les supprime pas.

## 6. Interface

### 6.1 Panneau (maquette B, avec ces ajouts)

- **Service ptzd**, sous le titre : l'interrupteur, et l'état « Actif », « Démarrage… », « Arrêté », « Relancé après un arrêt inattendu (n) », « Ne répond pas » (avec « Ouvrir le journal ») ou « Ancienne installation ».
- **Service éteint ou en échec :** tout est grisé sauf l'interrupteur, la ligne SDK, « Ouvrir à la connexion » et « Quitter ».
- **SDK OBSBOT**, une nouvelle ligne : « Prêt », « Absent », « En quarantaine » ou « Incompatible ». Tant qu'il n'est pas prêt, elle affiche le bouton « Installer le SDK… », et l'interrupteur Suivi IA est grisé avec la mention « SDK OBSBOT requis ». Le pilotage, la vie privée et l'appairage marchent sans le SDK.
- **Réseau local refusé :** « PTZBot n'a pas accès au réseau local : les iPhone ne le trouveront qu'avec Tailscale », avec un bouton qui ouvre les réglages de confidentialité.

### 6.2 Fenêtre « SDK OBSBOT »

1. **Explication et choix.** Le texte dit que le SDK est propriétaire et ne peut pas être fourni avec l'app. Deux boutons : « Ouvrir obsbot.com/sdk » et « Choisir l'archive ou le dossier… ». Le second accepte le `.zip` reçu ou le dossier décompressé ; l'app y cherche `macos/arm64-release/libdev.dylib`.
2. **Vérifications affichées :**
   - l'architecture (Apple Silicon : ✓ ou ✗) ;
   - la signature (le nom du signataire, ou « non signé ») ;
   - la provenance (l'adresse d'origine notée par macOS et la date, si elles existent) ;
   - la quarantaine (oui ou non).

   Un fichier sans tranche arm64, ou qui n'est pas une bibliothèque Mach-O, est refusé avec son motif.
3. **« Autoriser ce SDK ».** Une confirmation s'affiche : « PTZBot va copier ce fichier dans sa bibliothèque et retirer la quarantaine de cette copie. Ne le faites que si vous l'avez téléchargé depuis obsbot.com. » Si l'utilisateur confirme, l'app :
   - copie le fichier vers `sdk/libdev.dylib.new`, puis le renomme en `sdk/libdev.dylib` ;
   - retire `com.apple.quarantine` de la copie ;
   - vérifie que `obsbot-ai`, lancé sans argument, charge bien le SDK (code de sortie 3, celui de l'aide) ;
   - passe la ligne à « Prêt ».

   L'archive d'origine n'est jamais modifiée.

### 6.3 Textes

Au vouvoiement, en français, comme le reste de l'app (spec app Mac § 8.7).

## 7. Erreurs

| Cas | Comportement |
|---|---|
| `ptzd` plante | Relance avec délai croissant ; « Relancé (n) » ; au-delà de 5 arrêts en 2 min, « Arrêté » avec message et lien vers le journal |
| `ptzd` ne démarre pas (binaire absent, port occupé) | « Arrêté » avec le motif ; pour un port occupé : « Le port <port> est déjà pris : un autre ptzd tourne peut-être encore » |
| L'app plante ou est tuée | `ptzd` s'arrête en moins d'une seconde (§ 5.4) |
| SDK absent, en quarantaine ou incompatible | Suivi IA grisé, « SDK OBSBOT requis » ; le reste marche |
| Copie du SDK impossible | Message dans la fenêtre ; l'ancien SDK, s'il existe, est conservé |
| Échec de la migration | Message ; branchement sur l'ancien `ptzd`, jamais deux en même temps |
| Réseau local refusé | Message dans le panneau ; Tailscale continue de marcher |

## 8. Tests

- **PTZBotKit**, avec un faux lanceur de processus et une fausse horloge :
  - `ServiceSupervisor` : démarrage, arrêt (SIGTERM puis SIGKILL), relance avec délai croissant, abandon après 5 arrêts en 2 min, état de l'interrupteur retenu, aucun lancement si un ancien agent est actif ;
  - SDK : détection et vérifications sur de faux fichiers (Mach-O arm64, x86_64 seul, pas un binaire), recherche dans un `.zip` et dans un dossier, copie et retrait de la quarantaine sur une copie temporaire, remplacement atomique ;
  - migration : détection de l'ancien agent, enchaînement « Remplacer » avec un faux `launchctl` et une fausse corbeille, reprise du SDK de `lib/`, comportement de « Plus tard » ;
  - `config.json` : création avec et sans interface Tailscale.
- **`ptzd`** :
  - `--parent` : `ptzd` s'arrête quand un vrai processus de test se termine, y compris par SIGKILL, et s'arrête aussitôt si le parent n'existe déjà plus ;
  - `--ai` et `--sdk` : les chemins sont bien utilisés, et `DYLD_LIBRARY_PATH` est passé à l'utilitaire, vérifié avec un faux utilitaire qui écrit son environnement.
- **App** : compilation Release, `ptzd` et `obsbot-ai` présents dans `Contents/Helpers`, aucun `libdev.dylib` dans le paquet.
- **Banc avec Majid** :
  - migration depuis l'installation actuelle ;
  - demandes « Réseau local » et pare-feu ;
  - iPhone en Wi-Fi et en 4G ;
  - interrupteur du service ;
  - « Quitter », puis « Mac injoignable » sur l'iPhone ;
  - app tuée de force, puis `ptzd` arrêté ;
  - SDK réinstallé par la fenêtre, depuis une copie de l'archive ;
  - suivi IA ;
  - PID de go2rtc et de coreaudiod inchangés.

## 9. Mise en service

Compilation et installation par `install-mac.sh`, premier lancement, migration confirmée par Majid, puis autorisations « Réseau local » et pare-feu données par Majid. Les iPhone appairés restent appairés.

## 10. Limites connues

- L'iPhone ne pilote que si PTZBot est ouvert sur le Mac : « Ouvrir à la connexion » devient l'usage normal.
- `obsbot-ai` est compilé avec les en-têtes du SDK. Pouvoir livrer ce binaire dans une image disque publique est une question de licence, à trancher dans la spec de B2.
- go2rtc reste l'agent indépendant `com.majid.go2rtc` jusqu'à B3.
- `ptzd pair`, `ptzd devices` et `ptzd revoke` restent utilisables en ligne de commande avec le binaire de l'app (`PTZBot.app/Contents/Helpers/ptzd`) ; `ptzd pair` demande que le service tourne.
- Les contrôles d'intégrité et d'ancrage Apple de la fenêtre « SDK OBSBOT » ne remplacent pas Gatekeeper : ils renseignent l'utilisateur, ils ne prouvent pas que le fichier est celui d'OBSBOT.

## 11. Amendements (08/10/2026, après le prototype et le banc)

Le prototype a été relu deux fois et essayé au banc avec Majid le 07/10, migration réelle comprise. Les quatre points du § 4 sont vérifiés : chargement du SDK par `DYLD_LIBRARY_PATH`, réseau local, pare-feu et surveillance du parent (arrêt en environ 200 ms après un SIGKILL de l'app).

### Codes de sortie et verrou

- `ptzd` sort avec **64** si ses arguments sont refusés. Il sort avec **75** si un autre `ptzd` tient le verrou `<support>/ptzd.lock` (`flock`, pris dans tout le mode service sauf `pair`) ou si, sous `--parent`, le port de 127.0.0.1 est déjà pris. Il sort avec **78** si `config.json` est invalide.
- Le superviseur ne relance pas après 64, 75 ou 78. Il passe en échec avec « Arguments de ptzd refusés », « Le port <port> est déjà pris : un autre ptzd tourne peut-être encore » ou « config.json est invalide : ouvrez le journal ».
- Au démarrage, `ptzd` s'arrête aussi si `getppid()` n'est pas le PID donné par `--parent`.
- À la fin du parent, `ptzd` sort avec le code 0 sans fermer ses écoutes une à une. Le noyau ferme les sockets, et l'annonce Bonjour disparaît avec le processus.

### SDK

- **Statuts.** Le statut « Ne se charge pas » s'ajoute aux statuts du § 6.1. C'est le test de chargement par `obsbot-ai` qui décide de « Prêt » ; la quarantaine n'est qu'une information.
- **Choix de la bibliothèque.** L'app choisit la bibliothèque au même chemin relatif que celle avec laquelle la construction lie `obsbot-ai` : `macos/arm64-release/libdev.dylib`. Les autres copies trouvées sont signalées (« Autres copies ignorées »), sans qu'on demande de choisir.
- **Fichiers refusés.** Seuls les fichiers ordinaires sont acceptés : pas de lien symbolique ni de fichier spécial. La copie préparée est revérifiée avant l'échange.
- **Échange.** L'ancien SDK est gardé par un lien dur `.old` jusqu'à la vérification, puis remis en place si elle échoue. Une installation interrompue est reprise au lancement suivant, mais jamais pendant une installation en cours.
- **Recherche dans un dossier.** Elle est limitée à 5 niveaux, sans les dossiers cachés ni les paquets.
- **Ligne SDK du panneau.** Le bouton « Changer… » rouvre la fenêtre quand le SDK est prêt.

### Migration

- Après le `bootout`, l'app attend jusqu'à 10 s. Une erreur de `bootout` est tolérée si l'agent n'est plus chargé.
- Une ancienne `.plist.bak` est mise à la corbeille, jamais effacée.
- Après « Plus tard » ou un échec, le panneau propose « Remplacer l'ancienne installation… ».

### Panneau

Validé par Majid sur maquette puis au banc.
- **Trois sections titrées.** « Service » regroupe Service ptzd et SDK OBSBOT. « Caméra · branchée », ou « débranchée », regroupe la vie privée et le suivi IA. « iPhone connectés · n » regroupe les iPhone.
- **Alignement.** Les interrupteurs et les valeurs sont alignés à droite. Les messages s'affichent en petites lignes sous ce qu'ils concernent.
- **Liste des clients.** La connexion de confiance de l'app elle-même n'est **pas** un client et n'est pas listée. La section ne montre que les iPhone, ou « Aucun iPhone connecté ».

### Divers

- **« Quitter ».** Il passe par la boucle d'événements de l'app, jamais par un bloc de la file principale, sinon il y a interblocage (constaté au banc). Il attend `ptzd` 6 s au plus.
- **`install-mac.sh`.** Il attend la fin de l'ancienne app, jusqu'à 15 s, avant de la remplacer et de la lancer. Le modèle de plist `mac/launchd/` est retiré.
- **Création de `config.json`.** Elle prend l'adresse d'une interface `utun*` en 100.64/10 (voir plus bas : plus de repli sur une autre interface).

### Après la relecture finale (08/10)

- **Garde-fou du superviseur.** Si `ptzd` vit encore 5 s après le SIGKILL, l'arrêt est abandonné : état « failed » avec « ptzd ne s'arrête pas : ouvrez le journal », completions appelées, aucune relance par ce chemin.
- **Signature.** La fenêtre « SDK OBSBOT » distingue « Signature invalide » (fichier modifié) de « Signé, certificat non reconnu par Apple ». Après le contrôle d'intégrité, l'app évalue l'exigence `anchor apple generic` ; sans ancrage, signataire et équipe ne sont pas affichés (un certificat auto-signé peut porter n'importe quel nom). Avec ancrage, la ligne montre le signataire suivi de « (équipe XXXXXXXXXX) », l'identifiant lu dans le fichier à l'exécution.
- **Provenance.** Elle est lue d'abord sur l'archive reçue ; le fichier extrait ne sert que de repli, et la valeur est alors marquée « (indiquée dans l'archive) », car `ditto` recopie les attributs du zip.
- **« obsbot-ai introuvable ».** Statut du SDK quand le vérificateur lui-même manque dans l'app : aucune installation n'est possible, le bouton est absent.
- **Plus de repli CGNAT.** `config.json` ne prend que l'adresse d'une interface `utun*` en 100.64/10. La même plage sert aux opérateurs mobiles sur d'autres interfaces : sans `utun`, `config.json` écoute sur 127.0.0.1 et le panneau signale Tailscale absent.
- **Migration interrompue.** Si l'app est quittée entre la plist renommée et le reste, le lancement suivant (aucune ancienne installation détectée) met les anciens binaires de `bin/` à la corbeille et reprend `lib/libdev.dylib` dans `sdk/` s'il n'y en a pas. Sans effet et silencieux s'il n'y a rien à faire ; les échecs vont dans les problèmes de migration.
- **Sortie 75 précoce.** Si `ptzd` sort avec 75 moins de 2 s après son lancement (un ptzd mourant tient encore le verrou), le superviseur le relance une seule fois, 1 s plus tard. Un second 75 passe en échec comme avant.
