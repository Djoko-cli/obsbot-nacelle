# Spec : distribution de PTZBot pour Mac (sous-projet B2)

PTZBot pour Mac s'installe depuis une image disque (glisser dans Applications) et se met à jour seul avec Sparkle. Les versions sont publiées sur GitHub. L'app devient bilingue (anglais et français). `obsbot-ai` n'est plus livré : PTZBot le compile sur le Mac de l'utilisateur. Cette spec suit le brief de déploiement de Majid (document privé, hors dépôt), commun à ses apps macOS, et prolonge la [spec B1](2026-10-07-ptzd-dans-app-design.md). Validée par Majid le 2026-10-08, partie par partie.

## 1. Objectif

- **Installer sans Xcode ni Terminal :** un `.dmg` sur la page des versions GitHub, l'app glissée dans Applications.
- **Mises à jour automatiques et sûres,** signées par une clé Ed25519.
- **Aucun binaire lié au SDK OBSBOT dans ce qui est distribué :** le SDK reste fourni par l'utilisateur, et `obsbot-ai` est compilé chez lui.
- **Une app en anglais et en français,** comme le README et les notes de version.

## 2. Périmètre

Dans le périmètre :
- Sparkle dans l'app : réglages, recherche, installation.
- `publication.py` et `publier.sh`, repris de maillage-thread, avec trois adaptations (§ 5.3).
- La compilation locale d'`obsbot-ai` (§ 6).
- Le catalogue de chaînes de l'app Mac et de PTZBotKit (§ 7).
- La traduction des erreurs de `ptzd` par leur code (§ 7.2).
- Le README bilingue (anglais, puis français) et `NOTES-VERSIONS.md`.
- La première publication, 1.0.0.

Hors périmètre :
- La traduction de l'app iOS : une petite étape juste après B2.
- go2rtc dans l'app : c'est B3.
- La notarisation (Developer ID).
- Le journal et la ligne de commande de `ptzd`, qui restent en français.

## 3. Choix de Majid

| Question | Réponse |
|---|---|
| `obsbot-ai` dans le DMG | **Non : compilé sur le Mac de l'utilisateur** avec les en-têtes du SDK qu'il fournit et les outils d'Apple ; seule la source est livrée |
| Langues | **Bilingue partout** (anglais et français) : app Mac, erreurs de `ptzd` vues dans l'app, README, notes de version ; l'app iOS juste après B2 |
| Première version | 1.0.0, étiquette `ptzbot-v1.0.0` |
| Flux | `mac/app/appcast.xml` sur `main` du dépôt public `Djoko-cli/obsbot-nacelle` |
| Clé et certificat | La clé Ed25519 et le certificat « Djoko-cli Code Signing » de Majid, déjà existants |
| Mode de mise à jour | Tout automatique : recherche au lancement puis toutes les 24 h ; installation à la fermeture ou par « Installer et relancer » |

Les autres décisions du brief sont reprises telles quelles :
- Sparkle à une version figée ;
- l'authenticité par Ed25519 ;
- la signature par le certificat pour la seule compilation de publication ;
- le numéro de compilation égal au nombre de commits de `main` ;
- le DMG copié sur le Bureau ;
- la répétition sans GitHub.

## 4. Points à vérifier en tête du plan

1. **Mise à jour sans bac à sable.** Sparkle remplace l'app pendant que `ptzd` tourne en enfant. L'app doit d'abord arrêter `ptzd` (6 s au plus), puis se relancer avec un nouveau `ptzd`.
2. **`ptzd` avec le runtime renforcé et le certificat :** les écoutes, Bonjour, l'accès UVC par IOKit et le verrou marchent, sans aucun droit particulier.
3. **Compilation locale :** `clang++` des outils d'Apple compile `obsbot-ai.cpp` avec les en-têtes de l'archive. Le binaire, signé par l'éditeur de liens, charge le SDK par `DYLD_LIBRARY_PATH`.
4. **Catalogue de chaînes :** avec le français comme langue source et l'anglais traduit, un Mac en français affiche le français, et un Mac dans une autre langue affiche l'anglais (région de développement `en`).

## 5. Distribution

### 5.1 Contenu de PTZBot.app publié

- L'app, Sparkle 2.10.0 dans `Contents/Frameworks` avec ses services, et `Contents/Helpers/ptzd`.
- `Contents/Resources/obsbot-ai.cpp` : la source d'`obsbot-ai`, identique à `mac/ai/main.cpp`.
- **Interdits dans le paquet,** et refusés par `check-bundle.sh` comme par la publication :
  - `libdev*.dylib` ;
  - tout binaire `obsbot-ai` ;
  - les en-têtes du SDK (`devs.hpp`, `dev.hpp`).

### 5.2 Signature

- Elle est réservée à la compilation de publication, avec le certificat « Djoko-cli Code Signing » cherché par son empreinte. Les compilations de travail et les tests restent signés en local (ad hoc).
- L'ordre va de l'intérieur vers l'extérieur : les services et le cadre Sparkle, puis `Contents/Helpers/ptzd`, puis l'app.
- Le runtime renforcé s'applique à l'app et à `ptzd`.
- **Droits de l'app :** ceux de Xcode, plus la levée de la validation des bibliothèques (brief : sans équipe, l'app ne chargerait pas Sparkle).
  - Aucune autre exception `com.apple.security.cs.*`.
  - Pas de `get-task-allow`.
  - Pas de bac à sable.
- Aucun identifiant d'équipe, aucune empreinte ni aucune adresse dans un fichier commité.

### 5.3 `publication.py` et `publier.sh`

Ils sont repris de maillage-thread avec leurs tests, puis adaptés de trois façons seulement, chacune testée :
1. **`--sans-bac-a-sable` :** il remplace l'exigence du bac à sable et des services `<id>-spks` et `<id>-spki` par leur absence exigée.
2. **Utilitaires :** `Contents/Helpers/*` entre dans le code à signer, après les cadres et avant l'app.
3. **Contenu interdit :** les règles du § 5.1 s'ajoutent au contrôle du contenu du DMG.

**Contrôle d'anonymisation.** Celui de maillage-thread est privé. Ici, la vérification de fuite des commits (adresses hors liste autorisée, noms Tailscale, chemins personnels) s'applique au contenu du DMG, aux notes et au flux.

**Le reste est inchangé :**
- vérifications : `main` propre et à jour, version nouvelle, tests verts ;
- DMG avec l'app, un raccourci vers Applications et la licence de Sparkle ;
- `sign_update` ;
- flux `mac/app/appcast.xml`, qui garde toutes les versions ;
- étiquette `ptzbot-vX.Y.Z` et version GitHub ;
- `gestes.txt` pour la reprise ;
- copie sur le Bureau, sauf `--sans-bureau`.

### 5.4 Notes et README

- **`NOTES-VERSIONS.md` :** une section par version, avec un bloc **English** puis un bloc **Français**. Les mêmes notes servent à la version GitHub et à la fenêtre de Sparkle.
- **README :**
  - en anglais, puis en français, avec des liens vers chaque langue en tête ;
  - l'installation par le DMG ;
  - la première ouverture : Gatekeeper, puis « Ouvrir quand même » dans Réglages ;
  - la mise à jour automatique ;
  - l'installation du SDK et des outils d'Apple.

## 6. Compilation locale d'`obsbot-ai`

### 6.1 Prérequis

- **Le SDK :** l'archive ou le dossier choisi doit contenir les en-têtes (`include/dev/devs.hpp`) et `macos/arm64-release/libdev.dylib`. Un `libdev.dylib` seul est refusé : « Choisissez l'archive ou le dossier du SDK : ses en-têtes sont nécessaires. »
- **Les outils de développement d'Apple :** `xcode-select -p` doit réussir. Sinon, le suivi IA est indisponible, et le bouton « Installer les outils de développement… » lance `xcode-select --install`. L'utilisateur accepte lui-même dans la fenêtre d'Apple.

### 6.2 Installation (une seule transaction)

> Le déroulé réel (préparation dans `sdk/new/` avec un journal `.transaction`, quatre éléments échangés : `libdev.dylib`, `include`, `obsbot-ai`, `obsbot-ai.sha256`, ancien fichier gardé par lien dur `.old`) est précisé et corrigé au § 12, qui prime sur les étapes ci-dessous.

1. Le SDK est examiné comme dans B1 : architecture, signature ancrée chez Apple, provenance, quarantaine. L'utilisateur confirme.
2. Les en-têtes sont copiés dans `sdk/include.new/`, et `libdev.dylib` dans `sdk/libdev.dylib.new`, sans quarantaine.
3. `clang++ -std=c++17 -O2 -I <include.new> -L <dossier de .new> -ldev -o sdk/obsbot-ai.new <Resources/obsbot-ai.cpp>`. Le binaire n'a pas de chemin de recherche intégré, et l'éditeur de liens le signe en local.
4. `obsbot-ai.new`, lancé sans argument avec `DYLD_LIBRARY_PATH` vers le nouveau SDK, doit sortir avec le code 3.
5. Échange : les trois éléments (bibliothèque, `obsbot-ai`, en-têtes) sont renommés à leur place, les anciens gardés en `.old` jusqu'à la fin. En cas d'échec, tout revient comme avant.
6. `sdk/obsbot-ai.sha256` retient l'empreinte de la source compilée.

### 6.3 Recompilation après une mise à jour de l'app

Au lancement, si l'empreinte de `Resources/obsbot-ai.cpp` diffère de `sdk/obsbot-ai.sha256`, l'app recompile `obsbot-ai`. Elle utilise `sdk/include/` et `sdk/libdev.dylib`, suit les mêmes étapes 3 à 6, et ne demande rien. Si les outils manquent, le panneau l'indique, et l'ancien `obsbot-ai` reste en service.

### 6.4 Branchement

- `ptzd` reçoit `--ai <support>/sdk/obsbot-ai`, et non plus le chemin dans l'app.
- **« Prêt »** demande trois choses : le SDK, un `obsbot-ai` compilé avec l'empreinte courante, et la vérification de chargement réussie.
- **Nouveaux états :**
  - « Outils de développement requis » ;
  - « À compléter : réinstallez le SDK depuis son archive ou son dossier », pour un SDK sans en-têtes ni `obsbot-ai`, cas de l'installation actuelle de Majid ;
  - « Recompilation… ».

## 7. Bilingue

### 7.1 Catalogue de chaînes

- Tous les textes de l'app Mac et de PTZBotKit sont dans des `Localizable.xcstrings`.
- **Langues :** le français, au vouvoiement, est la langue source, et les textes actuels ne changent pas. L'anglais est traduit. La région de développement est `en`, si bien que toute langue autre que le français affiche l'anglais.
- Un test vérifie que chaque chaîne a sa traduction anglaise.

### 7.2 Erreurs de `ptzd`

- L'app ne montre plus le texte envoyé par `ptzd`. Elle affiche un texte traduit choisi d'après `ErrorCode` (et, pour `uvcFailed` du suivi IA, d'après le motif connu).
- Tous les codes de `NacelleProtocol` ont un texte en français et en anglais.
- `ptzd` garde ses textes français pour le journal et la ligne de commande.

## 8. Interface (panneau et Réglages)

- **Pied du panneau :** « Rechercher les mises à jour… », « Réglages… » et « Quitter ».
- **Fenêtre « Réglages » :**
  - « Rechercher automatiquement » et « Installer automatiquement », deux cases cochées par défaut ;
  - « Ouvrir à la connexion » ;
  - la version, par exemple « PTZBot 1.0.0 (412) ».
- **Démarrage de Sparkle :** au lancement, jamais sous les tests, ni dans une compilation de travail (numéro de compilation 1).
- **Installation d'une mise à jour :** à la fermeture, ou par « Installer et relancer ». `ptzd` est arrêté d'abord, comme pour « Quitter ».

## 9. Erreurs

| Cas | Comportement |
|---|---|
| Outils d'Apple absents | Suivi IA indisponible, bouton « Installer les outils de développement… » |
| Compilation d'`obsbot-ai` échouée | L'ancien SDK et l'ancien `obsbot-ai` restent en service ; le message renvoie au journal |
| Recompilation impossible après une mise à jour | L'ancien `obsbot-ai` reste ; le panneau le signale |
| Flux ou réseau injoignable | Sparkle réessaie au prochain intervalle ; rien n'est montré hors « Rechercher les mises à jour… » |
| Mise à jour mal signée | Refusée par Sparkle |
| Publication interrompue | Reprise depuis `gestes.txt`, jamais en relançant le script |

## 10. Tests

- **PTZBotKit :**
  - la compilation, avec un compilateur injecté (succès, échec, outils absents) ;
  - la transaction à quatre éléments (§ 12) et son retour en arrière ;
  - la recompilation sur une empreinte différente ;
  - les codes d'erreur traduits ;
  - le catalogue complet ;
  - Sparkle jamais démarré sous les tests.
- **`publication.py` :** les tests repris, plus ceux des trois adaptations.
- **App :** compilation Release, puis `check-bundle.sh` : `ptzd` présent, la source d'`obsbot-ai` présente, et rien d'interdit.
- **Répétition sans GitHub,** comme dans le brief :
  - une clé dans un fichier et un certificat dans un trousseau temporaire ;
  - un flux sur 127.0.0.1 et une fausse version supérieure, puis `sparkle-cli` ;
  - un DMG mal signé refusé ;
  - l'ouverture réelle des copies, puis « Rechercher les mises à jour… » et « Installer et relancer » dans l'app.
- **Avec Majid :**
  1. Le premier `codesign` : « Toujours autoriser ».
  2. La fusion.
  3. La publication de 1.0.0, avec son accord à ce moment-là.
  4. L'installation depuis le DMG : Gatekeeper.
  5. La réinstallation du SDK : compilation d'`obsbot-ai`, puis suivi IA.
  6. « Rechercher les mises à jour… » ; plus tard, une 1.0.1 pour éprouver une vraie mise à jour.
  7. Les PID de go2rtc et de coreaudiod restent inchangés.

## 11. Limites connues

- Sans notarisation, la première ouverture demande « Ouvrir quand même » dans Réglages.
- L'app est pour Apple Silicon seulement.
- Le suivi IA demande les outils de développement d'Apple.
- L'app iOS n'est pas distribuée ainsi : elle est signée avec le compte de chacun.
- Le journal et la ligne de commande de `ptzd` restent en français.
- La licence de redistribution du SDK est au backlog. Si OBSBOT l'accorde, `obsbot-ai` et le SDK pourront entrer dans le DMG, et la compilation locale servira de repli.

## 12. Amendements (prototype)

Le prototype (branche `proto/b2`) a été relu par Opus le 08/10. Ces points précisent la spec ou s'en écartent.

### Compilation locale d'`obsbot-ai`

- **Préparation dans `sdk/new/`, sous les noms définitifs** (`libdev.dylib`, `include/`, `obsbot-ai`, `obsbot-ai.sha256`), et non `*.new`. `-ldev` et `DYLD_LIBRARY_PATH` cherchent tous deux le nom `libdev.dylib`.
- **Journal.** Avant le premier échange, `sdk/new/.transaction` liste les éléments échangés et ceux qui n'avaient pas de version précédente.
  - Après un arrêt, la reprise remet chaque `.old` et retire les éléments neufs déjà en place.
  - La validation consiste à retirer le journal, puis `sdk/new/`. Un `sdk/new/` vide sans journal compte comme validé.
  - Un `sdk/new/` non vide sans journal compte comme « échange pas commencé » : il est effacé.
  - Si l'annulation d'un échange échoue, le journal et `sdk/new/` restent, et la reprise suivante l'achève.
  - Le `libdev.dylib.new` laissé par B1 est effacé à la reprise.
- **Groupe de processus.** clang++ est lancé dans son propre groupe : un délai dépassé arrête aussi `clang -cc1` et `ld`.
- **Outils absents.** Le panneau et la fenêtre « SDK OBSBOT » proposent « Installer les outils de développement… » avant tout choix du SDK, pour un SDK absent ou à compléter comme pour une recompilation. `xcode-select --install` n'est lancé que sur le clic de l'utilisateur.
- Les vérifications du SDK sont mises à la file : jamais de fausse « compilation impossible » pendant une recompilation.
- **Ligne SDK du panneau** (banc du 08/10) : à droite, un état court seulement (« Prêt », « Absent », « À compléter », « En quarantaine », « Incompatible », « Ne se charge pas », « Outils requis », « Recompilation… », « Compilation impossible », « obsbot-ai introuvable »).
  - L'explication et le bouton vont sur une petite ligne dessous, sur toute la largeur. Ils remplacent les états longs du § 6.4.
  - Pied du panneau : « Rechercher les mises à jour… » seul sur sa ligne, au-dessus de « Réglages… » et « Quitter ».

### Bilingue

- **Langue choisie explicitement**, au lieu de `Bundle.module` : le français si l'utilisateur le préfère à l'anglais, l'anglais sinon.
  - La règle est `Bundle.preferredLocalizations(from: ["fr", "en"])`, appliquée aux langues préférées.
  - Les textes sont lus dans `fr.lproj` ou `en.lproj` de PTZBotKit.
  - Hors d'une app, `Bundle.module` prend l'anglais même sur un Mac en français.
- **Réglage « Langue »** dans la fenêtre Réglages (banc du 08/10) : Automatique (la règle ci-dessus), Français ou English, appliqué tout de suite et retenu (`appLanguage`). Pour les fenêtres de Sparkle, choisies par macOS au lancement, le choix est recopié dans `AppleLanguages` du domaine de l'app (`["fr"]` ou `["en"]`, retiré en automatique) : elles suivent au prochain lancement.
- **Le motif d'échec du suivi IA** (`uvcFailed`) est composé par `ptzd` et relu par l'app d'après les mêmes textes, `AIFailureText` de NacelleProtocol.

### Mises à jour et publication

- **`SUVerifyUpdateBeforeExtraction`** est à vrai dès 1.0.0 : la signature Ed25519 est toujours exigée, sans repli sur la signature de code. La publication le vérifie dans l'app compilée.
  - `SURequireSignedFeed` n'est pas activé : il faudrait signer tout le flux à chaque publication.
- **`--notes`** : les notes sont à la racine du dépôt, et `publier.sh` se place dans `mac/app`.
- **Contrôle de fuite.** Chaque trouvaille est jugée par son jeton entier : l'adresse ou le nom complet doit être dans la liste autorisée.
  - Dans le DMG seulement, les OID de RSA et d’Apple (arc `1.2.840`, puis `113549` ou `113635`), que porte `Autoupdate` de Sparkle, sont admis comme jetons.
- **Utilitaires.** Après la signature, chaque utilitaire est relu : aucun droit, et le runtime renforcé présent. Un élément de `Contents/Helpers` qui n'est pas un exécutable ordinaire est refusé.
- **Aucun binaire Mach-O** de l'app ne doit dépendre de `libdev` (`otool -L`), ni dans `check-bundle.sh`, ni dans la publication.
- **Révision de Sparkle.** `sign_update` et `generate_keys`, pris dans le paquet résolu, exigent la révision de l'étiquette 2.10.0 (`eef1a539…`), lue dans `workspace-state.json`.
  - xcodegen n'accepte qu'une exigence par paquet : `project.yml` garde `exactVersion`.
- **`strip -S` de `ptzd`** dans une compilation de publication : ses symboles de débogage nommaient `.build` sous le dossier personnel.
- **`sparkle-cli`** n'est pas dans les artefacts du paquet. La répétition le compile depuis la source 2.10.0.
