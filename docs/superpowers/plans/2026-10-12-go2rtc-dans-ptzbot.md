# Plan d'implémentation : go2rtc dans PTZBot (sous-projet B3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectif (Goal) :** PTZBot pour Mac lance go2rtc 1.9.14 comme processus enfant (par un petit `gardien` qui l'arrête même si PTZBot plante), génère sa configuration, détecte ffmpeg et la caméra, montre son état par une pastille, et obtient les accès caméra et micro au nom de PTZBot ; la version 1.1.0 l'embarque et le publie.

**Architecture :**
- **Le gardien** (`mac/gardien`, paquet SwiftPM : `GardienCore` testable et l'exécutable `gardien`) : une boucle `kqueue` synchrone qui lance go2rtc par `posix_spawn`, surveille la fin de PTZBot (`EVFILT_PROC`, `NOTE_EXIT`), transmet SIGTERM et SIGINT, laisse `--arret` secondes avant SIGKILL et rend la fin de go2rtc.
- **La logique dans PTZBotKit**, testée sans matériel : réglages et yaml (`Go2RTCSettings`, `Go2RTCConfig`), import (`Go2RTCConfigReader`), ffmpeg et appareils (`FFmpegLocator`, `CaptureDeviceCatalog`), préparation et supervision (`Go2RTCPreparer`, `Go2RTCSupervisor`, sur le modèle de `ServiceSupervisor`), surveillance (`Go2RTCMonitor` : API, coreaudiod, journal), pastilles (`ServiceIndicator`) et onglet « Caméra » (`Go2RTCSettingsModel`). Les vues restent minces.
- **La compilation et la publication** : `build-helpers.sh` télécharge l'archive officielle, vérifie ses empreintes (`mac/app/go2rtc.sha256`), compile le gardien ; la publication exige les droits caméra et micro sur l'app, et le binaire officiel de go2rtc.

**Technologies (Tech Stack) :** Swift 6 strict, Swift Testing, SwiftUI, Observation, AVFoundation (`DiscoverySession`), `kqueue`/`posix_spawn`, sockets BSD, `URLSession`, String Catalogs (`.xcstrings`), xcodegen, Xcode 27, bash, Python 3 (`unittest`), go2rtc 1.9.14, ffmpeg de Homebrew.

**Spec :** [docs/superpowers/specs/2026-10-12-go2rtc-dans-ptzbot-design.md](../specs/2026-10-12-go2rtc-dans-ptzbot-design.md), validée par Majid, à lire avec ce plan (elle prolonge les specs B1 et B2). La tâche 10 y ajoute un § 12 qui reprend les précisions de ce plan.

## Contraintes globales (Global Constraints)

- **Swift :** Swift 6, concurrence stricte (`SWIFT_VERSION: "6.0"`, `SWIFT_STRICT_CONCURRENCY: complete`, paquets en `swift-tools-version: 6.0`), **aucun avertissement**. macOS 15, Apple Silicon (arm64). Aucun initialiseur ne touche le vrai système par défaut : seules les fabriques `system(...)` le font.
- **Tests :** Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`). Les suites de PTZBotKit portent `.french` ; celles qui lancent des processus, des minuteries ou des tâches portent `.timeLimit(.minutes(1))`. **Toute attente est bornée** : boucles d'attente de 3 à 5 s au plus, `FakeScheduler` pour le temps simulé.
- **Style :** identifiants en anglais, comme le code existant ; commentaires en français, dans le style voisin (`///` qui disent pourquoi). `outils/publication.py` et ses tests restent en ASCII sans accents, comme aujourd'hui.
- **Textes :** au **vouvoiement**, en français (langue source), traduits en anglais. PTZBotKit : `Localization.text("…")` et `Sources/PTZBotKit/Resources/Localizable.xcstrings`. Vues : `AppText.text("…")` et `PTZBot/Localizable.xcstrings`. Info.plist : `PTZBot/InfoPlist.xcstrings`. Une clé tient sur une seule ligne ; un entier interpolé s'écrit `\(String(n))` (clé `%@`), sauf une variable nommée `count` (clé `%lld`) : les tests des catalogues lisent les clés dans les sources et refusent une clé manquante ou inutile.
- **Piège Swift 6 :** une closure écrite dans un type `@MainActor` hérite de son isolation et plante (SIGTRAP) si un autre fil l'appelle (rappels de processus, kqueue, DispatchSource). Ici : les rappels de fin de processus sont typés `@MainActor` et remis sur la file principale par `FoundationProcessLauncher` ; tout ce qui bloque tourne dans `Task.detached` sur des types `Sendable` non isolés (`Go2RTCPreparer`, `FFmpegLocator`, `ProcessListing`) ; le gardien n'a aucune concurrence (une boucle `kqueue` synchrone, sans fil ni file).
- **go2rtc :** version **1.9.14** figée, `go2rtc_mac_arm64.zip` des versions officielles d'`AlexxIT/go2rtc` ; ports 8554 (RTSP) et 8555 (WebRTC), API **`127.0.0.1:1984` fixe** ; stream **`obsbot`** ; entrées `exec:` en **`- >-`**, jamais `- >` ; **`preload: obsbot:`** ; `#killsignal=15` ; arrêt en douceur : **10 s au moins** avant SIGKILL ; interrupteur `go2rtcEnabled` **éteint par défaut** ; ffmpeg de Homebrew détecté, **jamais embarqué**.
- **Secrets :** `go2rtc.yaml` en mode **600**, écrit de façon atomique, jamais dans le dépôt ni dans un journal ; le mot de passe RTSP n'est jamais dans les préférences, ni affiché (l'aperçu d'import dit seulement « repris »).
- **Dépôt public :**
  - aucune adresse IP réelle (permises : 127.0.0.1, 0.0.0.0, 192.0.2.x, 169.254.x.x et, dans les tests, 10.0.0.5, 172.16/31/32.x, 192.168.0.x, 100.64.0.1 ; toute autre adresse s'écrit en morceaux, comme `'203.0.113' + '.7'`) ;
  - aucun chemin `/Users/…` (les tests prennent `/maison/exemple`), aucun nom `*.ts.net` réel (seuls `mac.exemple.ts.net` et `mon-mac.tailnet.ts.net`) ;
  - aucun nom réel de personne, sauf la ligne de copyright d'une licence tierce copiée telle quelle (comme `outils/Sparkle-LICENSE.txt`) ; ni identifiant d'équipe, ni mot de passe réel : mots de passe de test fictifs (`mot-de-passe-de-test`, `secret-de-test`).
- **Système en service :** les agents d'exécution ne lancent jamais l'app, ptzd, talkd, un vrai go2rtc (et surtout pas sur 8554, 1984 ou 8555), `launchctl`, `scripts/install-mac.sh`, `outils/publier.sh` ni `gh`. Ils ne touchent ni à `~/Applications`, ni à `~/Library/Application Support/ObsbotNacelle`, ni à `~/Library/LaunchAgents`, ni à `/opt/homebrew/etc/go2rtc.yaml`, ni au go2rtc, au ffmpeg ou au Homebridge de Majid. **Pas de push.** La tâche 0 et la mise en service (§ 7 de la spec) se font avec Majid.
- **Commits :** messages en français ; la dernière ligne est la ligne `Co-Authored-By:` que le harnais d'exécution donne au modèle qui commite (par exemple `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`), notée `<ligne Co-Authored-By du modèle>` dans les commandes de ce plan ; `git add` des seuls fichiers de la tâche, jamais `git add -A`.
- **Disque :** le Mac de Majid a peu de place libre. En fin de tâche, supprimer ses propres sorties régénérables (`mac/gardien/.build`, `mac/app/PTZBotKit/.build`, `mac/app/.build/Build`, `mac/app/.build/Logs`), jamais le cache `mac/app/.build/go2rtc`.
- **Commandes de vérification** (depuis la racine du dépôt) :
  - `(cd mac/gardien && swift test)`
  - `(cd mac/app/PTZBotKit && swift test)`
  - `(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build && ./check-bundle.sh)`
  - `(cd outils/tests && NOTARISER=1 PROFIL_NOTARISATION=djoko-notarisation /usr/bin/python3 -m unittest test_publication)` (lent : 5 à 7 min)

## Points de vigilance (Review Focus)

Les cinq situations que la spec implique sans les nommer, les plus susceptibles de toucher un utilisateur. Chacune a son test dans la tâche qui porte le code.

1. **Un go2rtc tourne déjà** (celui de l'utilisateur, ou un orphelin) et l'utilisateur allume l'interrupteur : aucun second go2rtc, l'état dit « Port 8554 déjà utilisé… ». Tests : `Go2RTCPreparerTests.portBusy` et `realPorts` (tâche 5).
2. **PTZBot tué** (`kill -9`, plantage) : go2rtc reçoit SIGTERM, puis SIGKILL seulement après le délai ; jamais d'orphelin qui garde la caméra. Tests : `GardienProcessTests.parentGone` et `stubbornChild` (tâche 1).
3. **Des noms et des mots de passe inattendus** (guillemets, `#`, `\`, apostrophe) : le yaml reste valide, go2rtc lit le bon nom d'appareil, ou le réglage est refusé avec un message. Tests : `Go2RTCConfigTests.escaping` et `refusals` (tâche 2), `Go2RTCImportTests.roundTrip` (tâche 3).
4. **L'interrupteur basculé vite** (pendant la préparation, ou pendant l'arrêt en douceur de 10 s) : jamais deux go2rtc, une seule relance à la fin de l'arrêt. Test : `Go2RTCSupervisorTests.toggles` (tâche 5).
5. **Le mot de passe RTSP** ne fuit ni dans les préférences, ni dans l'aperçu d'import, et le yaml reste en 600 même réécrit. Tests : `Go2RTCConfigTests.preferences` et `writeFile` (tâche 2), `Go2RTCSettingsModelTests.importConfig` (tâche 8).

## Fichiers

| Fichier | Rôle |
|---|---|
| `mac/gardien/` (nouveau paquet) | Le gardien : options, boucle `kqueue`, fin du programme ; tests avec de vrais processus |
| `PTZBotKit/…/Go2RTCSettings.swift`, `Go2RTCConfig.swift` | Réglages retenus (sans mot de passe), yaml généré, écriture atomique en 600 |
| `PTZBotKit/…/Go2RTCImport.swift` | Lecteur minimal d'un yaml existant, réglages au lancement |
| `PTZBotKit/…/FFmpegLocator.swift`, `CaptureDevices.swift` | Recherche de ffmpeg, caméras et micros, choix par défaut |
| `PTZBotKit/…/ProcessLauncher.swift`, `PortProbe.swift`, `Go2RTCPreparer.swift`, `Go2RTCSupervisor.swift`, `AppPaths.swift`, `AppController.swift` | Environnement des processus, ports, préparation, supervision, chemins, « Quitter » |
| `PTZBotKit/…/Go2RTCStreams.swift`, `Go2RTCHealth.swift`, `Go2RTCMonitor.swift` | API de go2rtc, détecteur de coreaudiod, journal, surveillance |
| `PTZBotKit/…/ServiceIndicator.swift`, `mac/app/PTZBot/PanelView.swift`, `PTZBotApp.swift` | Pastilles, rangée go2rtc, confirmation de « Quitter » |
| `PTZBotKit/…/Go2RTCSettingsModel.swift`, `mac/app/PTZBot/SettingsView.swift`, `CameraSettingsView.swift` | Réglages à deux onglets, onglet « Caméra » |
| `mac/app/{build-helpers.sh,check-bundle.sh,project.yml,go2rtc.sha256,go2rtc-LICENSE.txt}`, `PTZBot/PTZBot.entitlements`, `PTZBot/InfoPlist.xcstrings` | go2rtc et gardien dans le paquet, droits et textes caméra et micro |
| `outils/{publication.py,publier.sh}`, `outils/tests/test_publication.py` | Droits requis, binaire officiel de go2rtc, contrôle de fuite |
| `README.md`, `NOTES-VERSIONS.md`, la spec B3 (§ 12) | Documentation bilingue, notes 1.1.0, précisions |

## Points vérifiés en préparant ce plan

Le plan a été prototypé en entier sur une copie jetable du dépôt (`git archive` du commit `2966600`), puis **rejoué tâche par tâche** sur une seconde copie vierge : chaque tâche compile sans avertissement et ses tests passent.
- **Gardien :** 12 tests, dont 8 avec de vrais processus (2,4 s en tout) ; `swift test` seul construit aussi l'exécutable.
- **PTZBotKit :** 306 tests au départ, 372 à la fin de la tâche 8 ; les tests des catalogues (`LocalizationTests`, `AppCatalogTests`) passent à chaque tâche.
- **App :** compilation Release et `check-bundle.sh` réussies après les tâches 7, 8 et 9. Pour la tâche 9, avec une **fausse** archive de go2rtc (un exécutable du système, mis en cache, avec ses empreintes) : le vrai téléchargement et les vraies empreintes sont calculés par l'étape prévue, une fois.
- **Publication :** les 156 tests Python passent (une seule correction en cours de route, reprise dans le plan).
- **go2rtc 1.9.14, lu dans ses sources** (étiquette `v1.9.14`) : `shell.QuoteSplit` découpe la commande sans échappement (d'où la règle des guillemets, tâche 2) ; la source s'arrête au premier `#` ; `[exec] timeout` est journalisé en erreur ; une sortie d'ffmpeg avant toute donnée devient l'erreur `exec/rtsp` suivie de sa sortie ; `-config` est l'option du fichier ; `#timeout=` n'existe plus (c'est `starttimeout`, 30 s par défaut) et reste sans effet.
- **API d'un go2rtc en service** (forme seulement, aucune valeur) : les producteurs `exec:` actifs ont `bytes_recv` et `medias`, la source `ffmpeg:…#audio=opus` au repos n'a que `url`, et le préchargement apparaît comme un consommateur `format_name: "preload"`, qui n'est pas un client.
- **Archive officielle :** `go2rtc_mac_arm64.zip` (6 757 845 octets), empreinte annoncée par GitHub `919b78adc759d6b3883d1e1b2ac915ac0985bb903ff1897b4d228527bd64690c`, à confirmer par le calcul de la tâche 9. Licence : `LICENSE` de l'étiquette `v1.9.14` (MIT), empreinte `b0dcf4855af5a72b4dfbd9117c207b330f4cc35658576a0b5351d6e2becac546`.
- **Essai de la tâche 0 :** le script passe `bash -n`, ses deux sources Swift compilent, et le relais rend bien 143 sur SIGTERM et le code de son programme. Il n'a pas été lancé : c'est le geste de Majid.

Non vérifié ici : le comportement de macOS (TCC) à travers le gardien (tâche 0), un vrai go2rtc avec la caméra, et la publication de bout en bout (mise en service avec Majid).

## Écarts à la spec, et pourquoi

Tous sont repris au § 12 de la spec par la tâche 10.
1. **Noms d'appareils** (§ 3.6, « guillemets échappés ») : go2rtc ne connaît aucun échappement. Un nom va entre guillemets doubles, ou simples s'il contient un guillemet double ; les deux à la fois, un `#` ou un caractère de contrôle sont refusés avec un message.
2. **Choix par défaut** (§ 3.6) : l'extension caméra d'OBSBOT Center s'appelle aussi « OBSBOT… » ; une OBSBOT réelle passe avant une virtuelle.
3. **Débit** (§ 4, § 6.2) : un seul réglage ; plafond 1,5 fois, tampon la moitié (4 Mb/s donne exactement 6 et 2, le pipeline en service).
4. **Mot de passe** (§ 4) : sans yaml, un mot de passe neuf de 20 caractères ; identifiant ou mot de passe vide refusé (le flux serait ouvert à tout le réseau local).
5. **Délais** (§ 3.3) : gardien `--arret 10` ; SIGKILL au gardien à 15 s ; « Quitter » attend 16 s au plus avec go2rtc, 6 s sans.
6. **Pastilles** (§ 6.1) : Talkback « En lecture » compte comme état normal ; un fichier personnalisé garde la pastille verte avec sa ligne « Fichier de configuration personnalisé ».
7. **Publication** (§ 8) : le binaire officiel de go2rtc porte des adresses dans son code (multidiffusion, DNS publics) ; le contrôle de fuite du .dmg les admet **dans ce seul fichier**, vérifié par son empreinte avant toute signature. Ses chemins et noms restent contrôlés.
8. **Essai jetable** (§ 11) : il précède tout code, donc le vrai gardien n'existe pas encore ; il utilise un relais de même structure (`posix_spawn`, puis attente), et peut être relancé avec le vrai gardien (`GARDIEN=…`) après la tâche 1.
9. **Découpage** : conforme à celui demandé, avec trois ajustements. `AppPaths` et la fin de « Quitter » (`AppController`) vont dans la tâche 5, avec le superviseur qu'ils servent. La confirmation de « Quitter » va dans la tâche 7, avec le panneau. La version 1.1.0 (`MARKETING_VERSION`) est réglée à la tâche 10, avec ses notes.

## Ordre et présence de Majid

- **Tâche 0** (Majid, avant tout) : l'essai des autorisations. Son résultat conditionne la suite.
- **Tâches 1 à 10** : du code, des tests et de la documentation, sans rien lancer du système en service ni publier.
- **Ensuite, avec Majid** : la relecture finale de la branche, le banc (§ 10 de la spec), la mise en service (§ 7, rappelée en fin de plan), puis la publication de la 1.1.0.

---

### Tâche 0 : essai jetable des autorisations (Majid, avant tout code)

**But :** vérifier le risque n° 1 de la spec (§ 11) avant d'écrire une ligne de produit. Un ffmpeg lancé par un relais (même structure que le gardien : `posix_spawn`, puis attente), lui-même lancé par go2rtc, tous descendants d'une app signée Developer ID avec les droits caméra et micro et le runtime renforcé, doit déclencher la demande d'accès **au nom de l'app**. Ce n'est pas une tâche de code : rien n'entre dans le dépôt.

**Ce que fait le script :**
- il ne touche pas à l'installation en service : ports 18554, 11984 et 18555, app à part (`io.github.djoko-cli.essai-b3`, nom « Essai B3 »), rien dans `~/Applications` ni dans launchd ;
- il télécharge go2rtc 1.9.14 dans son propre dossier, vérifie l'empreinte annoncée par GitHub, et affiche celle du binaire extrait (utile à la tâche 9) ;
- il construit `EssaiB3.app` : le relais et go2rtc dans `Contents/Helpers`, signés comme la publication les signera (runtime renforcé, sans droits), puis l'app avec les deux droits ;
- il lance l'app par `open` : LaunchServices en fait son propre processus responsable, comme PTZBot. Lancée depuis le Terminal, elle serait attribuée au Terminal et l'essai ne prouverait rien ;
- **phase A** : autorisations remises à zéro pour cette app seulement (`tccutil reset`), Majid répond « Autoriser » ; le script lit l'API (port 11984) pour voir si le producteur reçoit des images ;
- **phase B** : de nouveau remises à zéro, Majid répond « Ne pas autoriser » ; le script relève les lignes du journal de go2rtc qui disent le refus (elles servent à la tâche 6) ;
- il nettoie : autorisations de l'essai retirées, processus restants listés.

**Prudence :** par défaut, le micro n'est pas essayé (`MICRO` vide). Ouvrir le micro OBSBOT ajoute un client CoreAudio pendant que le go2rtc en service tourne, et coreaudiod se bloque parfois sous macOS 27. Pour l'essayer : `MICRO="OBSBOT Tiny2 Microphone"` (ou un autre micro), au choix de Majid. La caméra est ouverte au même format que le go2rtc en service (1920 × 1080, 30 i/s, nv12) pour ne pas changer le mode de la caméra.

- [x] **Étape 1 : Enregistrer le script hors du dépôt**

Dans un dossier jetable (par exemple `~/Desktop/essai-b3.sh`), avec ce contenu :

````bash
#!/bin/bash
# Essai jetable B3 (spec § 11), à lancer par Majid avant tout code de produit. Question : un ffmpeg lancé par un
# relais (même structure que le gardien : posix_spawn, puis attente) puis par go2rtc, tous descendants d'une app signée
# Developer ID avec les droits caméra et micro, déclenche-t-il la demande d'accès AU NOM DE L'APP ?
#
# Sans effet sur l'installation en service : ports 18554, 11984 et 18555 (jamais 8554, 1984, 8555), app à part
# (identifiant io.github.djoko-cli.essai-b3), rien dans ~/Applications, ni launchd, ni PTZBot. Tout est dans DOSSIER.
#
# Variables : CAMERA (nom AVFoundation de la caméra), MICRO (vide : pas d'essai du micro), DUREE (secondes par phase),
# GARDIEN (chemin du vrai gardien, tâche 1, à la place du relais), FFMPEG, DOSSIER.
set -euo pipefail

CAMERA="${CAMERA:-OBSBOT Tiny 2 StreamCamera}"
MICRO="${MICRO:-}"
DUREE="${DUREE:-60}"
GARDIEN="${GARDIEN:-}"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
DOSSIER="${DOSSIER:-${TMPDIR:-/tmp}/essai-b3}"
ID=io.github.djoko-cli.essai-b3
APP="$DOSSIER/EssaiB3.app"
VERSION=1.9.14
ARCHIVE=go2rtc_mac_arm64.zip
# L'empreinte que GitHub annonce pour cette archive (api.github.com, champ digest, relevé le 12/10/2026).
EMPREINTE_ARCHIVE=919b78adc759d6b3883d1e1b2ac915ac0985bb903ff1897b4d228527bd64690c

echo "== Vérifications"
[ -x "$FFMPEG" ] || { echo "ffmpeg introuvable : $FFMPEG" >&2; exit 1; }
for PORT in 18554 11984 18555; do
    if /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "le port $PORT est pris : choisir un autre moment" >&2
        exit 1
    fi
done
# L'identité Developer ID, par son empreinte : son nom (qui porte celui de la personne) n'est jamais affiché.
IDENTITE="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Developer ID Application: / { print $2 }')"
if [ "$(printf '%s\n' "$IDENTITE" | /usr/bin/grep -c .)" != 1 ]; then
    echo "il faut exactement une identité « Developer ID Application » dans le trousseau" >&2
    exit 1
fi
if [ -n "$MICRO" ]; then
    echo "Attention : MICRO ouvre un client CoreAudio de plus pendant l'essai (blocages de coreaudiod sous macOS 27)."
fi

echo "== go2rtc $VERSION"
rm -rf "$DOSSIER"
mkdir -p "$DOSSIER/telechargement" "$DOSSIER/sources" "$APP/Contents/MacOS" "$APP/Contents/Helpers"
/usr/bin/curl -fsSL -o "$DOSSIER/telechargement/$ARCHIVE" "https://github.com/AlexxIT/go2rtc/releases/download/v$VERSION/$ARCHIVE"
if [ "$(/usr/bin/shasum -a 256 "$DOSSIER/telechargement/$ARCHIVE" | /usr/bin/awk '{ print $1 }')" != "$EMPREINTE_ARCHIVE" ]; then
    echo "l'archive de go2rtc n'a pas l'empreinte annoncée par GitHub : arrêt" >&2
    exit 1
fi
/usr/bin/unzip -l "$DOSSIER/telechargement/$ARCHIVE"
/usr/bin/unzip -p "$DOSSIER/telechargement/$ARCHIVE" go2rtc > "$APP/Contents/Helpers/go2rtc"
chmod 755 "$APP/Contents/Helpers/go2rtc"
echo "empreinte du binaire go2rtc extrait (à reporter dans mac/app/go2rtc.sha256 à la tâche 9) :"
/usr/bin/shasum -a 256 "$APP/Contents/Helpers/go2rtc"

echo "== Relais (ou vrai gardien) et app d'essai"
if [ -n "$GARDIEN" ]; then
    cp "$GARDIEN" "$APP/Contents/Helpers/gardien"
else
    cat > "$DOSSIER/sources/relais.swift" <<'SWIFT'
import Foundation
// Relais de l'essai B3 : comme le gardien, lance son programme par posix_spawn (ni setsid ni désaveu de
// responsabilité), transmet SIGTERM, attend sa fin et la rend. Mêmes options que le gardien ; --parent est ignoré.
var arguments = Array(CommandLine.arguments.dropFirst())
if let separator = arguments.firstIndex(of: "--") { arguments = Array(arguments[(separator + 1)...]) }
signal(SIGTERM, SIG_IGN)
var defaults = sigset_t()
sigemptyset(&defaults)
sigaddset(&defaults, SIGTERM)
var attributes: posix_spawnattr_t?
posix_spawnattr_init(&attributes)
posix_spawnattr_setsigdefault(&attributes, &defaults)
posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))
let argv = arguments.map { strdup($0) } + [nil]
var pid: pid_t = 0
guard posix_spawn(&pid, arguments[0], nil, &attributes, argv, environ) == 0 else { exit(127) }
let child = pid
let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
source.setEventHandler { kill(child, SIGTERM) }
source.resume()
DispatchQueue.global().async {
    var status: Int32 = 0
    while waitpid(child, &status, 0) < 0, errno == EINTR {}
    exit(status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
}
dispatchMain()
SWIFT
    /usr/bin/xcrun swiftc -swift-version 5 -O -o "$APP/Contents/Helpers/gardien" "$DOSSIER/sources/relais.swift"
fi
cat > "$DOSSIER/sources/main.swift" <<'SWIFT'
import AppKit
// L'app de l'essai : lance le relais comme PTZBot lancera le gardien (Process, sortie vers un journal), puis l'arrête
// en douceur au bout de la durée donnée. Arguments (open --args) : le dossier de l'essai, la durée en secondes.
let dossier = CommandLine.arguments[1]
let duree = Double(CommandLine.arguments[2]) ?? 60
let helpers = Bundle.main.bundleURL.appending(path: "Contents/Helpers")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let process = Process()
process.executableURL = helpers.appending(path: "gardien")
process.arguments = ["--parent", String(getpid()), "--arret", "10", "--", helpers.appending(path: "go2rtc").path,
                     "-config", dossier + "/essai.yaml"]
var environment = ProcessInfo.processInfo.environment
environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin"
process.environment = environment
let journal = FileHandle(forWritingAtPath: dossier + "/essai.log")!
journal.seekToEndOfFile()
process.standardOutput = journal
process.standardError = journal
try! process.run()
DispatchQueue.main.asyncAfter(deadline: .now() + duree) {
    process.terminate()
    DispatchQueue.global().async {
        process.waitUntilExit()
        DispatchQueue.main.async { app.terminate(nil) }
    }
}
app.run()
SWIFT
/usr/bin/xcrun swiftc -swift-version 5 -O -o "$APP/Contents/MacOS/EssaiB3" "$DOSSIER/sources/main.swift"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>EssaiB3</string>
	<key>CFBundleIdentifier</key><string>$ID</string>
	<key>CFBundleName</key><string>Essai B3</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
	<key>LSUIElement</key><true/>
	<key>NSCameraUsageDescription</key><string>Essai B3 : vérifie que macOS demande l'accès à la caméra au nom de l'app.</string>
	<key>NSMicrophoneUsageDescription</key><string>Essai B3 : vérifie que macOS demande l'accès au micro au nom de l'app.</string>
</dict>
</plist>
PLIST
cat > "$DOSSIER/sources/droits.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key><true/>
	<key>com.apple.security.device.camera</key><true/>
</dict>
</plist>
PLIST
# Comme la publication : les utilitaires avec le runtime renforcé et sans droits, puis l'app avec ses deux droits.
for UTILITAIRE in gardien go2rtc; do
    /usr/bin/codesign --force --options runtime --timestamp=none --sign "$IDENTITE" "$APP/Contents/Helpers/$UTILITAIRE"
done
/usr/bin/codesign --force --options runtime --timestamp=none --entitlements "$DOSSIER/sources/droits.plist" --sign "$IDENTITE" "$APP"
/usr/bin/codesign --verify --strict "$APP" && echo "signature : ok"

ENTREE_MICRO=""
if [ -n "$MICRO" ]; then
    ENTREE_MICRO="    - >-
      exec:$FFMPEG -hide_banner -fflags nobuffer -flags low_delay -thread_queue_size 2048
      -f avfoundation -i \":$MICRO\" -c:a aac -ar 48000 -ac 2 -b:a 128k -vn
      -rtsp_transport tcp -f rtsp {output}#killsignal=15"
fi
cat > "$DOSSIER/essai.yaml" <<YAML
api:
  listen: "127.0.0.1:11984"
rtsp:
  listen: "127.0.0.1:18554"
webrtc:
  listen: "127.0.0.1:18555"
ffmpeg:
  bin: "$FFMPEG"
log:
  level: info
preload:
  essai:
streams:
  essai:
    - >-
      exec:$FFMPEG -hide_banner -fflags nobuffer -flags low_delay -thread_queue_size 1024
      -f avfoundation -framerate 30 -video_size 1920x1080 -pixel_format nv12 -probesize 32M
      -i "$CAMERA"
      -c:v h264_videotoolbox -realtime 1 -g 30 -bf 0 -level 4.0 -b:v 4M -maxrate 6M -bufsize 2M
      -bsf:v dump_extra=freq=keyframe -an
      -rtsp_transport tcp -f rtsp {output}#killsignal=15
$ENTREE_MICRO
YAML

# Une phase : autorisations remises à zéro pour cette app seulement, app lancée par LaunchServices (open : elle est
# son propre processus responsable, comme PTZBot), producteur lu dans l'API pendant la durée, puis arrêt.
phase() {
    local NOM="$1"
    /usr/bin/tccutil reset Camera "$ID" >/dev/null 2>&1 || true
    /usr/bin/tccutil reset Microphone "$ID" >/dev/null 2>&1 || true
    : > "$DOSSIER/essai.log"
    echo "== Phase $NOM : $2"
    /usr/bin/open -n -W "$APP" --args "$DOSSIER" "$DUREE" &
    local OUVERTURE=$!
    local ACTIF=non
    for _ in $(seq 1 $((DUREE / 2))); do
        sleep 2
        if /usr/bin/curl -fsS -m 1 http://127.0.0.1:11984/api/streams 2>/dev/null \
            | /usr/bin/python3 -I -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(p.get("bytes_recv",0)>0 for p in d.get("essai",{}).get("producers") or []) else 1)'; then
            ACTIF=oui
        fi
    done
    wait "$OUVERTURE" || true
    sleep 12
    echo "phase $NOM : producteur actif = $ACTIF" | tee -a "$DOSSIER/resultat.txt"
    echo "phase $NOM : lignes du journal (exec, avfoundation, refus) :" >> "$DOSSIER/resultat.txt"
    /usr/bin/grep -i -E 'exec|avfoundation|denied|authoriz|permission' "$DOSSIER/essai.log" >> "$DOSSIER/resultat.txt" || true
}

: > "$DOSSIER/resultat.txt"
{ echo "Essai B3 du $(date '+%d/%m/%Y %H:%M')"; /usr/bin/sw_vers; "$FFMPEG" -version | head -1; } >> "$DOSSIER/resultat.txt"

phase A "à la demande d'accès à la caméra (et au micro), répondez « Autoriser »"
read -r -p "La demande disait-elle « Essai B3 » souhaite accéder à la caméra (pas Terminal, go2rtc ni ffmpeg) ? (o/n) " NOM_A
echo "phase A : demande au nom de l'app = $NOM_A" >> "$DOSSIER/resultat.txt"

phase B "cette fois, répondez « Ne pas autoriser »"
read -r -p "La demande est-elle revenue, au nom d'« Essai B3 » ? (o/n) " NOM_B
echo "phase B : demande au nom de l'app = $NOM_B" >> "$DOSSIER/resultat.txt"

echo "== Nettoyage"
/usr/bin/tccutil reset Camera "$ID" >/dev/null 2>&1 || true
/usr/bin/tccutil reset Microphone "$ID" >/dev/null 2>&1 || true
RESTES="$(/usr/bin/pgrep -f "$APP/Contents/Helpers" || true; /usr/bin/pgrep -f "127.0.0.1:18554" || true)"
echo "processus restants de l'essai : ${RESTES:-aucun}" | tee -a "$DOSSIER/resultat.txt"
echo
echo "Résultat dans $DOSSIER/resultat.txt :"
cat "$DOSSIER/resultat.txt"
````

- [x] **Étape 2 : Le lancer (Majid, dans le Terminal)**

```bash
chmod +x ~/Desktop/essai-b3.sh && ~/Desktop/essai-b3.sh
```

Attendu, phase A : la demande « “Essai B3” souhaite accéder à la caméra » (pas « Terminal », « go2rtc » ni « ffmpeg ») ; après « Autoriser », `phase A : producteur actif = oui`. Phase B : la même demande ; après « Ne pas autoriser », `phase B : producteur actif = non`, et des lignes du journal qui disent le refus. À la fin : `processus restants de l'essai : aucun`.

- [x] **Étape 3 : Décider**

- **Les deux phases comme attendu :** la suite du plan s'applique. Garder `resultat.txt` : la tâche 6 reprend la ligne réelle du refus, et la tâche 9 compare l'empreinte du binaire.
- **Demande au nom d'un autre programme, ou aucune demande et caméra refusée :** arrêter. Le gardien et le superviseur ne suffisent pas ; il faut revoir la conception avec Majid (par exemple un service launchd de l'app) avant d'aller plus loin.
- **Relance facultative après la tâche 1**, avec le vrai gardien : `GARDIEN=<dépôt>/mac/gardien/.build/debug/gardien ~/Desktop/essai-b3.sh`.

---

### Résultat de la tâche 0 (essai du 12/10/2026, avec Majid)

- **Fait.** Le ffmpeg de l'essai avait bien l'app pour processus responsable (`launchctl procinfo` : `responsible path = …/EssaiB3.app/Contents/MacOS/EssaiB3`), et pourtant **macOS a attribué l'accès à la caméra à ffmpeg lui-même**, le programme qui ouvre la caméra. La première demande portait sur « ffmpeg ». Ensuite, ni la remise à zéro des autorisations de l'app, ni un go2rtc renommé (`essai-go2rtc`) n'ont fait revenir de demande.
- **Décision de Majid : B3 tel quel.** L'accès est attribué au ffmpeg de Homebrew, et une nouvelle demande « ffmpeg » vient après chaque `brew upgrade ffmpeg`. Un utilitaire de capture signé, qui ferait attribuer l'accès à PTZBot, va au backlog.
- **Conséquences sur les tâches :**
  - **Tâche 6** : l'essai n'a produit aucun refus réel, donc aucune ligne de refus n'a été relevée dans le journal. Le détecteur de refus reste comme écrit. Au banc, si go2rtc n'écrit rien de reconnaissable, l'état retombe sur « Caméra OBSBOT absente ».
  - **Tâche 9** : les droits caméra et micro de l'app et les textes d'`Info.plist` **restent comme écrits**. Ils ne servent pas à l'attribution actuelle, mais ils préparent l'utilitaire de capture. L'empreinte SHA-256 du binaire `go2rtc` extrait de `go2rtc_mac_arm64.zip` (1.9.14) relevée par l'essai est `6e5039d56d652d2d325cb3ce3f7cc20248a34db42fe8abf9bb13488494ac023e` : l'étape 5 de la tâche 9 doit retrouver exactement celle-là.
  - **Tâche 10** : le README (anglais puis français) dit que la demande d'accès à la caméra et au micro porte le nom « ffmpeg », et qu'elle revient après une mise à jour de ffmpeg par Homebrew.

---

### Tâche 1 : le gardien (`mac/gardien`)

**But :** un petit utilitaire en Swift qui lance go2rtc comme processus enfant et l'arrête quand PTZBot disparaît, même après un plantage (spec § 3.2). Usage : `gardien --parent <pid> --arret <secondes> -- <programme> <arguments…>`. Il transmet SIGTERM et SIGINT au programme ; dès le premier de ces signaux, ou la disparition du parent, le programme a `--arret` secondes pour sortir, puis SIGKILL. Le gardien rend la fin du programme : son code de sortie, ou le même signal. Surveillance par `kqueue` (`EVFILT_PROC`, `NOTE_EXIT`), sans sondage ; pas de fil, pas de file de distribution, donc rien à isoler.

**Fichiers :**
- Créer : `mac/gardien/Package.swift`
- Créer : `mac/gardien/Sources/GardienCore/GardienOptions.swift`
- Créer : `mac/gardien/Sources/GardienCore/ChildEnd.swift`
- Créer : `mac/gardien/Sources/GardienCore/Gardien.swift`
- Créer : `mac/gardien/Sources/gardien/main.swift`
- Tester : `mac/gardien/Tests/GardienCoreTests/GardienOptionsTests.swift`, `mac/gardien/Tests/GardienCoreTests/GardienProcessTests.swift`

**Interfaces :**
- Consomme : rien.
- Produit :
  - l'exécutable `gardien` (construit par `swift build -c release --product gardien`, copié dans `Contents/Helpers` à la tâche 9) ;
  - `GardienOptions(parent: pid_t, stopDelay: TimeInterval, program: String, arguments: [String])`, `GardienOptions.parse(_ arguments: [String]) throws(GardienOptions.ParseError) -> GardienOptions`, `GardienOptions.usage`, `GardienOptions.maximumStopDelay` (300) ;
  - `GardienExit.usage` (64), `.parentGone` (69), `.systemError` (71), `.launchFailed` (127) ;
  - `ChildEnd.exited(Int32)` / `.signaled(Int32)`, `ChildEnd(waitStatus:)` ;
  - `Gardien.run(_ options: GardienOptions, log: (String) -> Void) -> ChildEnd`, `Gardien.isGone(_ pid: pid_t) -> Bool`.
  - Contrat pour la tâche 5 : le superviseur lance `gardien --parent <pid de PTZBot> --arret 10 -- <go2rtc> -config <yaml>` ; le gardien sort avec 127 si go2rtc ne peut pas être lancé ; un go2rtc arrêté par SIGTERM fait sortir le gardien par SIGTERM.

- [x] **Étape 1 : Écrire le paquet et les tests**

Créer `mac/gardien/Package.swift` :

````swift
// swift-tools-version: 6.0
import PackageDescription

/// gardien : lance un programme en processus enfant et l'arrête quand son parent disparaît (spec B3 § 3.2). PTZBot
/// lance go2rtc par lui : après un plantage de PTZBot, go2rtc ne reste pas orphelin, la caméra ouverte.
/// `GardienCore` porte toute la logique ; l'exécutable ne fait que lire les options et rendre la fin du programme.
let package = Package(
    name: "gardien",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "GardienCore"),
        .executableTarget(name: "gardien", dependencies: ["GardienCore"]),
        .testTarget(name: "GardienCoreTests", dependencies: ["GardienCore"]),
    ]
)
````

Créer `mac/gardien/Tests/GardienCoreTests/GardienOptionsTests.swift` :

````swift
import Foundation
import Testing
@testable import GardienCore

@Suite("Options du gardien")
struct GardienOptionsTests {
    @Test("--parent et --arret dans n'importe quel ordre, puis -- et le programme avec ses arguments")
    func valid() throws {
        let options = try GardienOptions.parse(["--parent", "4242", "--arret", "10", "--", "/app/Helpers/go2rtc", "-config", "/support/go2rtc.yaml"])
        #expect(options == GardienOptions(parent: 4242, stopDelay: 10, program: "/app/Helpers/go2rtc", arguments: ["-config", "/support/go2rtc.yaml"]))
        let reordered = try GardienOptions.parse(["--arret", "0.5", "--parent", "7", "--", "/bin/sleep"])
        #expect(reordered == GardienOptions(parent: 7, stopDelay: 0.5, program: "/bin/sleep", arguments: []))
    }

    @Test("Après --, tout est au programme, même ce qui ressemble à une option")
    func passThrough() throws {
        let options = try GardienOptions.parse(["--parent", "1", "--arret", "1", "--", "/bin/echo", "--parent", "--", "-config"])
        #expect(options.arguments == ["--parent", "--", "-config"])
    }

    @Test("Refus : option inconnue, valeur manquante ou mal formée, option en double ou manquante, programme manquant ou relatif")
    func invalid() {
        #expect(throws: GardienOptions.ParseError.unknownOption("--verbose")) { try GardienOptions.parse(["--verbose"]) }
        #expect(throws: GardienOptions.ParseError.missingValue("--parent")) { try GardienOptions.parse(["--parent"]) }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--parent", value: "abc")) {
            try GardienOptions.parse(["--parent", "abc", "--arret", "1", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--parent", value: "0")) {
            try GardienOptions.parse(["--parent", "0", "--arret", "1", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--arret", value: "-1")) {
            try GardienOptions.parse(["--parent", "1", "--arret", "-1", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--arret", value: "nan")) {
            try GardienOptions.parse(["--parent", "1", "--arret", "nan", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--arret", value: "301")) {
            try GardienOptions.parse(["--parent", "1", "--arret", "301", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.duplicate("--parent")) {
            try GardienOptions.parse(["--parent", "1", "--parent", "2", "--arret", "1", "--", "/bin/sleep"])
        }
        #expect(throws: GardienOptions.ParseError.missingOption("--arret")) { try GardienOptions.parse(["--parent", "1", "--", "/bin/sleep"]) }
        #expect(throws: GardienOptions.ParseError.missingOption("--parent")) { try GardienOptions.parse(["--arret", "1", "--", "/bin/sleep"]) }
        #expect(throws: GardienOptions.ParseError.missingProgram) { try GardienOptions.parse(["--parent", "1", "--arret", "1", "--"]) }
        #expect(throws: GardienOptions.ParseError.missingProgram) { try GardienOptions.parse(["--parent", "1", "--arret", "1"]) }
        #expect(throws: GardienOptions.ParseError.invalidValue(option: "--", value: "go2rtc")) {
            try GardienOptions.parse(["--parent", "1", "--arret", "1", "--", "go2rtc"])
        }
    }
}

@Suite("Fin du programme")
struct ChildEndTests {
    @Test("Statut de waitpid : sortie normale avec son code, ou signal (core écrit ou non)")
    func decode() {
        #expect(ChildEnd(waitStatus: 0) == .exited(0))
        #expect(ChildEnd(waitStatus: 7 << 8) == .exited(7))
        #expect(ChildEnd(waitStatus: SIGTERM) == .signaled(SIGTERM))
        #expect(ChildEnd(waitStatus: SIGKILL) == .signaled(SIGKILL))
        #expect(ChildEnd(waitStatus: SIGSEGV | 0x80) == .signaled(SIGSEGV))
    }
}
````

Créer `mac/gardien/Tests/GardienCoreTests/GardienProcessTests.swift` (un `sleep` tient le rôle de PTZBot ; un shell, celui de go2rtc, écrit son pid puis devient `sleep`) :

````swift
import Foundation
import Testing
@testable import GardienCore

/// Le gardien compilé, lancé pour de vrai avec de petits processus (spec B3 § 10) : un `sleep` tient le rôle de
/// PTZBot, un shell celui de go2rtc. Le shell écrit son pid, puis devient `sleep` (en ignorant SIGTERM s'il le faut).
/// Toutes les attentes sont bornées.
@MainActor
@Suite("Gardien : vrais processus", .timeLimit(.minutes(1)))
struct GardienProcessTests {
    /// Construit par `swift build`, que la commande de vérification lance avant `swift test`.
    static let executable = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/debug/gardien")

    static let sleeps = #"echo $$ > "$1"; exec /bin/sleep 60"#
    static let ignoresTerm = #"trap "" TERM; echo $$ > "$1"; exec /bin/sleep 60"#
    static let exitsSeven = #"echo $$ > "$1"; exit 7"#

    private func wait(_ limit: Duration, until condition: () -> Bool) async throws -> Bool {
        let start = ContinuousClock.now
        while !condition() {
            guard ContinuousClock.now - start < limit else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func launch(_ executable: URL, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Le parent : un `sleep` à tuer.
    private func launchParent() throws -> Process {
        try launch(URL(fileURLWithPath: "/bin/sleep"), ["60"])
    }

    /// Le gardien sur un shell qui écrit son pid dans le fichier rendu.
    private func launchGardien(parent: pid_t, stopDelay: String = "10", script: String) throws -> (process: Process, pidFile: URL) {
        try #require(FileManager.default.isExecutableFile(atPath: Self.executable.path), "lancez `swift build` avant `swift test`")
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "gardien-\(UUID().uuidString).pid")
        let process = try launch(Self.executable, ["--parent", String(parent), "--arret", stopDelay, "--", "/bin/sh", "-c", script, "sh", pidFile.path])
        return (process, pidFile)
    }

    /// Le pid écrit par le programme, attendu 5 s au plus.
    private func childPID(_ file: URL) async throws -> pid_t {
        var pid: pid_t?
        _ = try await wait(.seconds(5)) {
            pid = (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return pid != nil
        }
        return try #require(pid, "le programme n'a pas écrit son pid")
    }

    /// Fin de test : tout ce qui vit encore est tué, le fichier du pid retiré.
    private func cleanUp(_ processes: [Process], child: pid_t?, pidFile: URL) {
        for process in processes where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        if let child, !Gardien.isGone(child) {
            kill(child, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    @Test("Parent disparu : SIGTERM au programme, qui s'arrête ; le gardien finit comme lui")
    func parentGone() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.sleeps)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        kill(parent.processIdentifier, SIGKILL)
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationReason == .uncaughtSignal)
        #expect(gardien.terminationStatus == SIGTERM)
    }

    @Test("Parent disparu, programme qui ignore SIGTERM : SIGKILL après --arret, pas avant")
    func stubbornChild() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, stopDelay: "2", script: Self.ignoresTerm)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        kill(parent.processIdentifier, SIGKILL)
        try await Task.sleep(for: .seconds(1))
        #expect(!Gardien.isGone(child), "encore là à 1 s : le délai est de 2 s")
        #expect(gardien.isRunning)
        #expect(try await wait(.seconds(5)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationReason == .uncaughtSignal)
        #expect(gardien.terminationStatus == SIGKILL)
    }

    @Test("SIGTERM au gardien : transmis au programme, qui s'arrête")
    func forwardsTerm() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.sleeps)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        gardien.terminate()
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationReason == .uncaughtSignal)
        #expect(gardien.terminationStatus == SIGTERM)
        #expect(parent.isRunning, "le parent n'est pas touché")
    }

    @Test("SIGINT au gardien : transmis au programme")
    func forwardsInt() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.sleeps)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        gardien.interrupt()
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationReason == .uncaughtSignal)
        #expect(gardien.terminationStatus == SIGINT)
    }

    @Test("SIGTERM ignoré par le programme : SIGKILL après --arret")
    func termThenKill() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, stopDelay: "1", script: Self.ignoresTerm)
        let child = try await childPID(pidFile)
        defer { cleanUp([parent, gardien], child: child, pidFile: pidFile) }
        gardien.terminate()
        #expect(try await wait(.seconds(5)) { !gardien.isRunning })
        #expect(Gardien.isGone(child))
        #expect(gardien.terminationStatus == SIGKILL)
    }

    @Test("Le code de sortie du programme est rendu")
    func exitStatus() async throws {
        let parent = try launchParent()
        let (gardien, pidFile) = try launchGardien(parent: parent.processIdentifier, script: Self.exitsSeven)
        defer { cleanUp([parent, gardien], child: nil, pidFile: pidFile) }
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(gardien.terminationReason == .exit)
        #expect(gardien.terminationStatus == 7)
    }

    @Test("Parent déjà disparu : rien n'est lancé, code 69")
    func parentAlreadyGone() async throws {
        // Un processus lancé puis attendu jusqu'au bout : son PID est libre.
        let finished = try launch(URL(fileURLWithPath: "/usr/bin/true"), [])
        finished.waitUntilExit()
        let (gardien, pidFile) = try launchGardien(parent: finished.processIdentifier, script: Self.sleeps)
        defer { cleanUp([gardien], child: nil, pidFile: pidFile) }
        #expect(try await wait(.seconds(3)) { !gardien.isRunning })
        #expect(gardien.terminationStatus == GardienExit.parentGone)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path), "le programme n'a pas été lancé")
    }

    @Test("Programme introuvable : code 127 ; options refusées : code 64")
    func failures() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.executable.path), "lancez `swift build` avant `swift test`")
        let parent = try launchParent()
        defer { cleanUp([parent], child: nil, pidFile: URL(fileURLWithPath: "/dev/null/x")) }
        let missing = try launch(Self.executable, ["--parent", String(parent.processIdentifier), "--arret", "1", "--", "/chemin/introuvable/go2rtc"])
        let refused = try launch(Self.executable, ["--parent", "abc"])
        #expect(try await wait(.seconds(3)) { !missing.isRunning && !refused.isRunning })
        #expect(missing.terminationStatus == GardienExit.launchFailed)
        #expect(refused.terminationStatus == GardienExit.usage)
    }
}
````

- [x] **Étape 2 : Lancer les tests, constater l'échec**

Run : `(cd mac/gardien && swift test)`
Attendu : échec. Les cibles `GardienCore` et `gardien` n'ont pas encore de sources (« Source files for target GardienCore should be located under 'Sources/GardienCore' »).

- [x] **Étape 3 : Écrire le gardien**

Créer `mac/gardien/Sources/GardienCore/GardienOptions.swift` :

````swift
import Foundation

/// Les options du gardien : `gardien --parent <pid> --arret <secondes> -- <programme> [arguments…]` (spec B3 § 3.2).
public struct GardienOptions: Equatable, Sendable {
    /// Le processus surveillé (PTZBot) : s'il disparaît, le programme est arrêté.
    public var parent: pid_t
    /// Le délai laissé au programme entre SIGTERM et SIGKILL, en secondes.
    public var stopDelay: TimeInterval
    /// Le programme, par son chemin absolu.
    public var program: String
    public var arguments: [String]

    public init(parent: pid_t, stopDelay: TimeInterval, program: String, arguments: [String]) {
        self.parent = parent
        self.stopDelay = stopDelay
        self.program = program
        self.arguments = arguments
    }

    public static let usage = "usage : gardien --parent <pid> --arret <secondes> -- <programme> [arguments…]"
    /// Le plus long délai d'arrêt accepté.
    public static let maximumStopDelay: TimeInterval = 300

    public enum ParseError: Error, Equatable {
        case unknownOption(String)
        case missingValue(String)
        case invalidValue(option: String, value: String)
        case duplicate(String)
        case missingOption(String)
        case missingProgram
    }

    /// Lit `--parent` et `--arret`, chacun une fois, dans n'importe quel ordre, puis `--` : tout ce qui suit est au
    /// programme, même ce qui ressemble à une option. Le PID est un entier strictement positif ; le délai, un nombre de
    /// secondes entre 0 et `maximumStopDelay` ; le programme, un chemin absolu.
    public static func parse(_ arguments: [String]) throws(ParseError) -> GardienOptions {
        var parent: pid_t?
        var stopDelay: TimeInterval?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let option = arguments[index]
            if option == "--" {
                let rest = arguments[arguments.index(after: index)...]
                guard let program = rest.first else { throw .missingProgram }
                guard program.hasPrefix("/") else { throw .invalidValue(option: "--", value: program) }
                guard let parent else { throw .missingOption("--parent") }
                guard let stopDelay else { throw .missingOption("--arret") }
                return GardienOptions(parent: parent, stopDelay: stopDelay, program: program, arguments: Array(rest.dropFirst()))
            }
            guard option == "--parent" || option == "--arret" else { throw .unknownOption(option) }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else { throw .missingValue(option) }
            let value = arguments[next]
            if option == "--parent" {
                guard parent == nil else { throw .duplicate(option) }
                guard let pid = pid_t(value), pid > 0 else { throw .invalidValue(option: option, value: value) }
                parent = pid
            } else {
                guard stopDelay == nil else { throw .duplicate(option) }
                guard let seconds = TimeInterval(value), seconds.isFinite, (0...maximumStopDelay).contains(seconds) else {
                    throw .invalidValue(option: option, value: value)
                }
                stopDelay = seconds
            }
            index = arguments.index(after: next)
        }
        throw .missingProgram
    }
}
````

Créer `mac/gardien/Sources/GardienCore/ChildEnd.swift` :

````swift
import Foundation

/// Les codes de sortie propres au gardien ; ceux du programme sont rendus tels quels.
public enum GardienExit {
    /// Options refusées (EX_USAGE).
    public static let usage: Int32 = 64
    /// Le parent avait déjà disparu : rien n'est lancé (EX_UNAVAILABLE).
    public static let parentGone: Int32 = 69
    /// kqueue refusé par le système, avant tout lancement (EX_OSERR).
    public static let systemError: Int32 = 71
    /// Le programme n'a pas pu être lancé (la convention des shells).
    public static let launchFailed: Int32 = 127
}

/// La fin du programme, lue dans le statut de `waitpid`.
public enum ChildEnd: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    /// WIFEXITED, WEXITSTATUS et WTERMSIG, que Swift n'importe pas (le bit 0x80 dit seulement qu'un core a été écrit).
    public init(waitStatus status: Int32) {
        if status & 0x7f == 0 {
            self = .exited((status >> 8) & 0xff)
        } else {
            self = .signaled(status & 0x7f)
        }
    }
}
````

Créer `mac/gardien/Sources/GardienCore/Gardien.swift` :

````swift
import Foundation

/// Le gardien (spec B3 § 3.2) : une seule boucle `kqueue`, sans fil ni file de distribution. Elle attend la fin du
/// programme et celle du parent (`EVFILT_PROC`, `NOTE_EXIT`), et SIGTERM ou SIGINT (`EVFILT_SIGNAL`), qu'elle transmet
/// au programme. Dès le premier de ces signaux, ou la disparition du parent, le programme a `stopDelay` secondes pour
/// sortir ; puis SIGKILL. Le gardien sort quand le programme est sorti, et rend sa fin.
public enum Gardien {
    /// Le processus n'existe plus (ESRCH). Celui d'un autre utilisateur (EPERM) existe.
    public static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    /// Lance le programme et le garde jusqu'à sa fin. `log` reçoit une ligne par événement (le journal de go2rtc).
    /// À n'appeler qu'une fois : SIGTERM et SIGINT restent ignorés par le processus appelant.
    public static func run(_ options: GardienOptions, log: (String) -> Void) -> ChildEnd {
        guard !isGone(options.parent) else {
            log("le parent \(options.parent) a déjà disparu : \(options.program) n'est pas lancé")
            return .exited(GardienExit.parentGone)
        }
        let queue = kqueue()
        guard queue >= 0 else {
            log("kqueue refusé (errno \(errno))")
            return .exited(GardienExit.systemError)
        }
        defer { close(queue) }
        // Ignorés : ils ne tuent pas le gardien, et kqueue les voit quand même. Inscrits avant le lancement : aucun ne
        // peut se perdre entre les deux.
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            _ = register(queue, ident: UInt(number), filter: EVFILT_SIGNAL)
        }
        let child: pid_t
        do {
            child = try spawn(options)
        } catch {
            log("\(options.program) n'a pas pu être lancé (errno \(error.code))")
            return .exited(GardienExit.launchFailed)
        }
        // ESRCH : le programme est déjà sorti ; il ne reste qu'à lire sa fin.
        guard register(queue, ident: UInt(child), filter: EVFILT_PROC, fflags: UInt32(NOTE_EXIT)) else {
            return reap(child)
        }
        var deadline: UInt64?
        var killed = false
        func beginStop(_ number: Int32) {
            kill(child, number)
            if deadline == nil, !killed {
                deadline = now() + UInt64(options.stopDelay * 1_000_000_000)
            }
        }
        // ESRCH : le parent a disparu entre la vérification et l'inscription.
        if !register(queue, ident: UInt(options.parent), filter: EVFILT_PROC, fflags: UInt32(NOTE_EXIT)) {
            log("le parent \(options.parent) a disparu : SIGTERM à \(child)")
            beginStop(SIGTERM)
        }
        while true {
            var event = kevent()
            let count: Int32
            if let deadline {
                let left = deadline > now() ? deadline - now() : 0
                var limit = timespec(tv_sec: Int(left / 1_000_000_000), tv_nsec: Int(left % 1_000_000_000))
                count = kevent(queue, nil, 0, &event, 1, &limit)
            } else {
                count = kevent(queue, nil, 0, &event, 1, nil)
            }
            if count < 0 {
                if errno == EINTR { continue }
                log("kevent en échec (errno \(errno)) : SIGKILL à \(child)")
                kill(child, SIGKILL)
                return reap(child)
            }
            if count == 0 {
                log("\(child) n'est pas sorti en \(options.stopDelay) s : SIGKILL")
                kill(child, SIGKILL)
                killed = true
                deadline = nil
                continue
            }
            switch Int32(event.filter) {
            case EVFILT_SIGNAL:
                let number = Int32(event.ident)
                log("signal \(number) reçu : transmis à \(child)")
                beginStop(number)
            case EVFILT_PROC where pid_t(event.ident) == child:
                return reap(child)
            case EVFILT_PROC:
                log("le parent \(options.parent) a disparu : SIGTERM à \(child)")
                beginStop(SIGTERM)
            default:
                break
            }
        }
    }

    /// Une erreur de `posix_spawn` (ENOENT : programme introuvable…).
    public struct SpawnError: Error, Equatable {
        public var code: Int32
    }

    /// Lance le programme : il hérite des entrées, des sorties (le journal de go2rtc) et de l'environnement du gardien ;
    /// SIGTERM et SIGINT y reprennent leur effet par défaut (le gardien les ignore, et un signal ignoré le reste après
    /// `exec`).
    static func spawn(_ options: GardienOptions) throws(SpawnError) -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM)
        sigaddset(&defaults, SIGINT)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let argv = ([options.program] + options.arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, options.program, nil, &attributes, argv, envp)
        guard result == 0 else { throw SpawnError(code: result) }
        return pid
    }

    /// Inscrit un événement ; false si le système le refuse (ESRCH : le processus n'existe plus).
    static func register(_ queue: Int32, ident: UInt, filter: Int32, fflags: UInt32 = 0) -> Bool {
        var change = kevent(ident: ident, filter: Int16(filter), flags: UInt16(EV_ADD | EV_ENABLE), fflags: fflags, data: 0, udata: nil)
        return kevent(queue, &change, 1, nil, 0, nil) == 0
    }

    /// Lit la fin du programme (il est sorti : `waitpid` ne bloque pas).
    static func reap(_ child: pid_t) -> ChildEnd {
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0, errno == EINTR {}
        return ChildEnd(waitStatus: status)
    }

    /// Temps monotone, en nanosecondes.
    static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}
````

Créer `mac/gardien/Sources/gardien/main.swift` :

````swift
import Foundation
import GardienCore

// gardien : voir GardienCore.Gardien (spec B3 § 3.2). Ses lignes vont sur la sortie d'erreur, que PTZBot dirige vers
// go2rtc.log, comme celle de go2rtc.

/// Une ligne du gardien dans le journal.
func say(_ text: String) {
    FileHandle.standardError.write(Data("gardien : \(text)\n".utf8))
}

let options: GardienOptions
do {
    options = try GardienOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    say("options refusées (\(error))\n\(GardienOptions.usage)")
    exit(GardienExit.usage)
}
switch Gardien.run(options, log: say) {
case let .exited(status):
    exit(status)
case let .signaled(number):
    // La même fin que le programme : PTZBot voit go2rtc arrêté par ce signal.
    signal(number, SIG_DFL)
    kill(getpid(), number)
    exit(128 + number)
}
````

- [x] **Étape 4 : Lancer les tests, constater la réussite**

Run : `(cd mac/gardien && swift build --build-tests 2>&1 | grep -E "warning|error" ; swift test)`
Attendu : aucune ligne d'avertissement ni d'erreur, puis `Test run with 12 tests in 3 suites passed` (environ 3 s ; `swift test` construit aussi l'exécutable `.build/debug/gardien` que les tests lancent).

- [x] **Étape 5 : Commit**

```bash
rm -rf mac/gardien/.build
git add mac/gardien/Package.swift mac/gardien/Sources mac/gardien/Tests
git commit -F - <<'MSG'
Gardien : lance go2rtc en enfant, transmet SIGTERM et SIGINT, l'arrête si PTZBot disparaît (kqueue)

<ligne Co-Authored-By du modèle>
MSG
```

---

### Tâche 2 : réglages de go2rtc et yaml généré

**But :** `Go2RTCSettings` (les réglages hors du yaml, retenus dans les préférences sans le mot de passe) et le générateur du yaml, modèle exact de la spec § 4 : le pipeline en service, paramétré ; entrées `exec:` en `- >-`, toutes leurs lignes au même retrait ; `preload` ; API fixe ; `ffmpeg.bin` absolu. Les noms d'appareils sont écrits comme go2rtc les découpe (`shell.QuoteSplit`, sans échappement) ; le mot de passe est échappé pour le yaml. L'écriture est atomique, en mode 600 dès la création, et un contenu identique n'est pas réécrit.

**Fichiers :**
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCSettings.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCConfig.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings` (5 textes)
- Tester : `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCTestSupport.swift` (données fictives, `quoteSplit` recopié de go2rtc, `foldedEntries`), `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCConfigTests.swift`

**Interfaces :**
- Consomme : `SettingsStore` (`string(forKey:)`, `set(_:forKey:)`), `Localization.text`.
- Produit :
  - `Go2RTCSettings` (`Codable`, `Equatable`, `Sendable`) : `streamName` (« obsbot »), `apiPort` (1984), `preferencesKey` (« go2rtcSettings »), `resolutions`, `framerates`, `bitrates`, `Resolution(width:height:)` ; champs `username` (« ptzbot »), `password` (jamais codé), `rtspPort` (8554), `webrtcPort` (8555), `resolution` (1920 × 1080), `framerate` (30), `bitrate` (4), `cameraName?`, `microphoneName?`, `ffmpegPath?`, `customConfigEnabled`, `customConfigPath?` ; `videoBitrate`, `videoMaxrate`, `videoBuffer` ; `@MainActor static load(from:)`, `@MainActor save(to:)`, `static randomPassword()`.
  - `Go2RTCConfigError` : `.unsupportedName(String)`, `.missingCredential`, `.unsupportedCredential`, `.invalidPort(Int)`, `.portConflict` (`LocalizedError`).
  - `Go2RTCConfig.fileName` (« go2rtc.yaml »), `Go2RTCConfig.yaml(settings:ffmpeg:camera:microphone:) throws(Go2RTCConfigError) -> String`.
  - `Go2RTCConfigFile.write(_ text: String, to url: URL) throws -> Bool` (true : le fichier a changé).
  - Pour les tests des tâches suivantes : `Go2RTCFixtures` (`ffmpeg`, `camera`, `microphone`, `password`, `settings()`, `directory()`, `permissions(_:)`), `quoteSplit(_:)`, `foldedEntries(_:)`.

- [x] **Étape 1 : Écrire les tests**

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCTestSupport.swift` :

````swift
import Foundation
import Testing
@testable import PTZBotKit

/// Les données fictives des tests de go2rtc : aucun vrai mot de passe, aucun vrai chemin personnel.
enum Go2RTCFixtures {
    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    static let camera = "OBSBOT Tiny 2 StreamCamera"
    static let microphone = "OBSBOT Tiny2 Microphone"
    static let password = "mot-de-passe-de-test"

    /// Les réglages par défaut, avec un identifiant et un mot de passe fictifs.
    static func settings() -> Go2RTCSettings {
        var settings = Go2RTCSettings()
        settings.username = "ptzbot"
        settings.password = password
        return settings
    }

    /// Un dossier temporaire neuf, à retirer par l'appelant.
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ptzbot-go2rtc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Le mode d'un fichier (0o600…).
    static func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }
}

/// `shell.QuoteSplit` de go2rtc 1.9.14 (pkg/shell/shell.go), recopié : c'est ainsi que go2rtc découpe une commande
/// `exec:`. Un guillemet sans fin, ou des guillemets vides, rendent nil (une erreur pour go2rtc).
func quoteSplit(_ text: String) -> [String]? {
    var result: [String] = []
    var rest = Substring(text)
    while let first = rest.first {
        switch first {
        case "\t", "\n", "\r", " ":
            rest = rest.dropFirst()
        case "\"", "'":
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: first), end > body.startIndex else { return nil }
            result.append(String(body[..<end]))
            rest = body[body.index(after: end)...]
        default:
            if let end = rest.firstIndex(where: { "\t\n\r ".contains($0) }) {
                result.append(String(rest[..<end]))
                rest = rest[end...]
            } else {
                result.append(String(rest))
                rest = ""
            }
        }
    }
    return result
}

/// Les entrées `- >-` du yaml, repliées comme les lit un analyseur yaml (lignes au même retrait jointes par une espace,
/// sans saut de ligne final).
func foldedEntries(_ yaml: String) -> [String] {
    var entries: [String] = []
    var current: [String]?
    for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
        if line == "    - >-" {
            if let current { entries.append(current.joined(separator: " ")) }
            current = []
        } else if current != nil, line.hasPrefix("      ") {
            current?.append(String(line.dropFirst(6)))
        } else if let finished = current {
            entries.append(finished.joined(separator: " "))
            current = nil
        }
    }
    if let current { entries.append(current.joined(separator: " ")) }
    return entries
}
````

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCConfigTests.swift` :

````swift
import Foundation
import Testing
@testable import PTZBotKit

@Suite("go2rtc : réglages et yaml généré", .french)
struct Go2RTCConfigTests {
    /// Le modèle exact (spec B3 § 4) : le pipeline en service, paramétré par les réglages par défaut.
    static let expected = [
        "# Écrit par PTZBot (Réglages › Caméra) : ne pas modifier, PTZBot le réécrit.",
        "# Written by PTZBot (Settings › Camera): do not edit, PTZBot rewrites it.",
        "api:",
        "  listen: \"127.0.0.1:1984\"",
        "rtsp:",
        "  listen: \":8554\"",
        "  username: \"ptzbot\"",
        "  password: \"mot-de-passe-de-test\"",
        "webrtc:",
        "  listen: \":8555\"",
        "ffmpeg:",
        "  bin: \"/opt/homebrew/bin/ffmpeg\"",
        "log:",
        "  level: info",
        "preload:",
        "  obsbot:",
        "streams:",
        "  obsbot:",
        "    - >-",
        "      exec:/opt/homebrew/bin/ffmpeg -hide_banner -fflags nobuffer -flags low_delay",
        "      -thread_queue_size 1024",
        "      -f avfoundation -framerate 30 -video_size 1920x1080 -pixel_format nv12 -probesize 32M",
        "      -i \"OBSBOT Tiny 2 StreamCamera\"",
        "      -c:v h264_videotoolbox -realtime 1 -g 30 -bf 0 -level 4.0",
        "      -color_range mpeg -r 30",
        "      -b:v 4M -maxrate 6M -bufsize 2M",
        "      -bsf:v dump_extra=freq=keyframe",
        "      -an",
        "      -rtsp_transport tcp -f rtsp {output}#timeout=30s#killsignal=15",
        "    - >-",
        "      exec:/opt/homebrew/bin/ffmpeg -hide_banner -fflags nobuffer -flags low_delay",
        "      -thread_queue_size 2048",
        "      -f avfoundation -i \":OBSBOT Tiny2 Microphone\"",
        "      -af aresample=async=1000:first_pts=0",
        "      -c:a aac -ar 48000 -ac 2 -b:a 128k",
        "      -vn",
        "      -rtsp_transport tcp -f rtsp {output}#timeout=30s#killsignal=15",
        "    - ffmpeg:obsbot#audio=opus",
    ].joined(separator: "\n") + "\n"

    private func yaml(_ settings: Go2RTCSettings = Go2RTCFixtures.settings(), camera: String = Go2RTCFixtures.camera,
                      microphone: String = Go2RTCFixtures.microphone) throws -> String {
        try Go2RTCConfig.yaml(settings: settings, ffmpeg: Go2RTCFixtures.ffmpeg, camera: camera, microphone: microphone)
    }

    @Test("Modèle exact : les réglages par défaut donnent le pipeline en service")
    func exactModel() throws {
        #expect(try yaml() == Self.expected)
    }

    @Test("Entrées exec en `- >-`, jamais `- >` ; repliées, chacune tient sur une ligne et finit par killsignal=15")
    func foldedBlocks() throws {
        let text = try yaml()
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.filter { $0 == "    - >-" }.count == 2)
        #expect(!lines.contains("    - >"))
        let entries = foldedEntries(text)
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry.hasPrefix("exec:/opt/homebrew/bin/ffmpeg "))
            #expect(entry.hasSuffix("{output}#timeout=30s#killsignal=15"))
            #expect(!entry.contains("\n"))
        }
    }

    @Test("go2rtc découpe les commandes comme prévu : chaque nom d'appareil est un seul argument")
    func quoteSplitArguments() throws {
        let entries = foldedEntries(try yaml())
        let video = try #require(quoteSplit(String(entries[0].split(separator: "#")[0])))
        let audio = try #require(quoteSplit(String(entries[1].split(separator: "#")[0])))
        #expect(video.first == "exec:/opt/homebrew/bin/ffmpeg")
        #expect(video[try #require(video.firstIndex(of: "-i")) + 1] == "OBSBOT Tiny 2 StreamCamera")
        #expect(audio[try #require(audio.firstIndex(of: "-i")) + 1] == ":OBSBOT Tiny2 Microphone")
        #expect(video.last == "{output}")
    }

    @Test("Paramètres : 720p à 25 i/s, 3 Mb/s (plafond 4500k, tampon 1500k), autres ports")
    func parameters() throws {
        var settings = Go2RTCFixtures.settings()
        settings.resolution = Go2RTCSettings.Resolution(width: 1280, height: 720)
        settings.framerate = 25
        settings.bitrate = 3
        settings.rtspPort = 9554
        settings.webrtcPort = 9555
        let text = try yaml(settings)
        #expect(text.contains("-f avfoundation -framerate 25 -video_size 1280x720 -pixel_format nv12"))
        #expect(text.contains("-c:v h264_videotoolbox -realtime 1 -g 25 -bf 0 -level 4.0"))
        #expect(text.contains("-color_range mpeg -r 25"))
        #expect(text.contains("-b:v 3M -maxrate 4500k -bufsize 1500k"))
        #expect(text.contains("  listen: \":9554\""))
        #expect(text.contains("  listen: \":9555\""))
        #expect(text.contains("  listen: \"127.0.0.1:1984\""))
    }

    @Test("Échappements : guillemets dans les noms, \" et \\ dans le mot de passe")
    func escaping() throws {
        var settings = Go2RTCFixtures.settings()
        settings.password = #"a"b\c"#
        let text = try yaml(settings, camera: #"Caméra "A""#, microphone: "Micro d'Anne")
        #expect(text.contains(#"  password: "a\"b\\c""#))
        #expect(text.contains(#"-i 'Caméra "A"'"#))
        #expect(text.contains(#"-i ":Micro d'Anne""#))
        let entries = foldedEntries(text)
        let video = try #require(quoteSplit(String(entries[0].split(separator: "#")[0])))
        let audio = try #require(quoteSplit(String(entries[1].split(separator: "#")[0])))
        #expect(video[try #require(video.firstIndex(of: "-i")) + 1] == #"Caméra "A""#)
        #expect(audio[try #require(audio.firstIndex(of: "-i")) + 1] == ":Micro d'Anne")
    }

    @Test("Refus : # ou les deux guillemets dans un nom, nom vide, saut de ligne, identifiants vides, ports invalides ou en conflit")
    func refusals() {
        let settings = Go2RTCFixtures.settings()
        #expect(throws: Go2RTCConfigError.unsupportedName("Cam #2")) { try yaml(camera: "Cam #2") }
        #expect(throws: Go2RTCConfigError.unsupportedName(#"Cam "l'autre""#)) { try yaml(camera: #"Cam "l'autre""#) }
        #expect(throws: Go2RTCConfigError.unsupportedName("")) { try yaml(camera: "") }
        #expect(throws: Go2RTCConfigError.unsupportedName("Cam\n2")) { try yaml(camera: "Cam\n2") }
        var empty = settings
        empty.password = ""
        #expect(throws: Go2RTCConfigError.missingCredential) { try yaml(empty) }
        var newline = settings
        newline.username = "pt\nzbot"
        #expect(throws: Go2RTCConfigError.unsupportedCredential) { try yaml(newline) }
        var low = settings
        low.rtspPort = 554
        #expect(throws: Go2RTCConfigError.invalidPort(554)) { try yaml(low) }
        var same = settings
        same.webrtcPort = 1984
        #expect(throws: Go2RTCConfigError.portConflict) { try yaml(same) }
    }

    @Test("Débits : 4 Mb/s donne 4M, 6M, 2M ; 5 Mb/s donne 5M, 7500k, 2500k")
    func rates() {
        var settings = Go2RTCSettings()
        #expect([settings.videoBitrate, settings.videoMaxrate, settings.videoBuffer] == ["4M", "6M", "2M"])
        settings.bitrate = 5
        #expect([settings.videoBitrate, settings.videoMaxrate, settings.videoBuffer] == ["5M", "7500k", "2500k"])
    }

    @MainActor
    @Test("Préférences : sans le mot de passe ; une clé absente reprend sa valeur par défaut")
    func preferences() throws {
        let store = FakeSettings()
        var settings = Go2RTCFixtures.settings()
        settings.cameraName = Go2RTCFixtures.camera
        settings.framerate = 25
        settings.save(to: store)
        let saved = try #require(store.strings[Go2RTCSettings.preferencesKey])
        #expect(!saved.contains(Go2RTCFixtures.password))
        var expected = settings
        expected.password = ""
        #expect(Go2RTCSettings.load(from: store) == expected)
        store.strings[Go2RTCSettings.preferencesKey] = #"{"framerate":15}"#
        var partial = Go2RTCSettings()
        partial.framerate = 15
        #expect(Go2RTCSettings.load(from: store) == partial)
        store.strings[Go2RTCSettings.preferencesKey] = "illisible"
        #expect(Go2RTCSettings.load(from: store) == Go2RTCSettings())
    }

    @Test("Mot de passe neuf : 20 lettres et chiffres, différent à chaque tirage")
    func randomPassword() {
        let first = Go2RTCSettings.randomPassword()
        #expect(first.count == 20)
        #expect(first.allSatisfy { $0.isLetter || $0.isNumber })
        #expect(first != Go2RTCSettings.randomPassword())
    }

    @Test("Écriture : mode 600 dès la création ; identique, pas réécrite et mode rétabli ; aucun fichier temporaire laissé")
    func writeFile() throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "sous-dossier/go2rtc.yaml")
        #expect(try Go2RTCConfigFile.write("un\n", to: url))
        #expect(try Go2RTCFixtures.permissions(url) == 0o600)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try !Go2RTCConfigFile.write("un\n", to: url))
        #expect(try Go2RTCFixtures.permissions(url) == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int == inode)
        #expect(try Go2RTCConfigFile.write("deux\n", to: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "deux\n")
        #expect(try Go2RTCFixtures.permissions(url) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["go2rtc.yaml"])
    }

    @Test("Messages d'erreur en français et en anglais")
    func messages() {
        let errors: [Go2RTCConfigError] = [.unsupportedName("x"), .missingCredential, .unsupportedCredential, .invalidPort(1), .portConflict]
        for error in errors {
            let french = Localization.$languageOverride.withValue("fr") { error.localizedDescription }
            let english = Localization.$languageOverride.withValue("en") { error.localizedDescription }
            #expect(french != english, "\(error)")
        }
        #expect(Go2RTCConfigError.invalidPort(80).localizedDescription == "Port 80 invalide : choisissez un port entre 1024 et 65535.")
    }
}
````

- [x] **Étape 2 : Lancer les tests, constater l'échec**

Run : `(cd mac/app/PTZBotKit && swift test)`
Attendu : échec de compilation, « cannot find 'Go2RTCSettings' in scope ».

- [x] **Étape 3 : Écrire les réglages et le générateur**

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCSettings.swift` :

````swift
import Foundation

/// Les réglages de go2rtc dans PTZBot (spec B3 § 4), tenus hors du yaml. Ils sont retenus dans les préférences, sans
/// le mot de passe RTSP : seul le yaml le porte (mode 600), puisque go2rtc doit le lire en clair.
public struct Go2RTCSettings: Codable, Equatable, Sendable {
    /// Le nom du stream, dont dépendent ptzd (`streamName`) et Homebridge.
    public static let streamName = "obsbot"
    /// L'API de go2rtc, fixe : ptzd y relaie la vidéo de l'app iOS.
    public static let apiPort = 1984
    public static let preferencesKey = "go2rtcSettings"
    /// Les résolutions proposées : `-level 4.0` de h264_videotoolbox couvre 1080p à 30 i/s.
    public static let resolutions = [Resolution(width: 1920, height: 1080), Resolution(width: 1280, height: 720)]
    public static let framerates = [30, 25, 15]
    /// Les débits proposés, en Mb/s.
    public static let bitrates = [2, 3, 4, 5, 6, 8]

    public struct Resolution: Codable, Equatable, Hashable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public var username = "ptzbot"
    /// Seulement dans le yaml : jamais codé dans les préférences.
    public var password = ""
    public var rtspPort = 8554
    public var webrtcPort = 8555
    public var resolution = Resolution(width: 1920, height: 1080)
    public var framerate = 30
    /// Le débit vidéo, en Mb/s ; le plafond vaut 1,5 fois, le tampon la moitié (4 Mb/s : plafond 6, tampon 2, comme le
    /// pipeline en service).
    public var bitrate = 4
    /// nil : la première caméra OBSBOT branchée (`CaptureDeviceChoice`).
    public var cameraName: String?
    /// nil : le premier micro OBSBOT branché.
    public var microphoneName: String?
    /// nil : ffmpeg cherché à ses places habituelles (`FFmpegLocator`).
    public var ffmpegPath: String?
    /// Mode expert : go2rtc lancé sur ce fichier, que PTZBot n'écrit jamais.
    public var customConfigEnabled = false
    public var customConfigPath: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case username, rtspPort, webrtcPort, resolution, framerate, bitrate
        case cameraName, microphoneName, ffmpegPath, customConfigEnabled, customConfigPath
    }

    /// Une clé absente garde sa valeur par défaut : les préférences d'une version précédente se relisent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Go2RTCSettings()
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? defaults.username
        rtspPort = try container.decodeIfPresent(Int.self, forKey: .rtspPort) ?? defaults.rtspPort
        webrtcPort = try container.decodeIfPresent(Int.self, forKey: .webrtcPort) ?? defaults.webrtcPort
        resolution = try container.decodeIfPresent(Resolution.self, forKey: .resolution) ?? defaults.resolution
        framerate = try container.decodeIfPresent(Int.self, forKey: .framerate) ?? defaults.framerate
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate) ?? defaults.bitrate
        cameraName = try container.decodeIfPresent(String.self, forKey: .cameraName)
        microphoneName = try container.decodeIfPresent(String.self, forKey: .microphoneName)
        ffmpegPath = try container.decodeIfPresent(String.self, forKey: .ffmpegPath)
        customConfigEnabled = try container.decodeIfPresent(Bool.self, forKey: .customConfigEnabled) ?? defaults.customConfigEnabled
        customConfigPath = try container.decodeIfPresent(String.self, forKey: .customConfigPath)
    }

    /// « 4M » ; « 4500k » quand le compte n'est pas rond.
    static func rate(kilobits: Int) -> String {
        kilobits % 1000 == 0 ? "\(kilobits / 1000)M" : "\(kilobits)k"
    }

    public var videoBitrate: String { Self.rate(kilobits: bitrate * 1000) }
    public var videoMaxrate: String { Self.rate(kilobits: bitrate * 1500) }
    public var videoBuffer: String { Self.rate(kilobits: bitrate * 500) }

    /// Les réglages retenus ; le mot de passe reste vide (voir `restore`).
    @MainActor
    public static func load(from store: any SettingsStore) -> Go2RTCSettings {
        guard let text = store.string(forKey: preferencesKey),
              let decoded = try? JSONDecoder().decode(Go2RTCSettings.self, from: Data(text.utf8)) else {
            return Go2RTCSettings()
        }
        return decoded
    }

    /// Retient les réglages, sans le mot de passe.
    @MainActor
    public func save(to store: any SettingsStore) {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        store.set(String(decoding: data, as: UTF8.self), forKey: Self.preferencesKey)
    }

    /// Un mot de passe RTSP neuf : 20 lettres et chiffres sans ambiguïté, tirés par le générateur du système.
    public static func randomPassword() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<20).map { _ in alphabet[Int(generator.next(upperBound: UInt(alphabet.count)))] })
    }
}
````

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCConfig.swift` :

````swift
import Foundation

/// Pourquoi le yaml de go2rtc ne peut pas être écrit avec ces réglages.
public enum Go2RTCConfigError: LocalizedError, Equatable, Sendable {
    /// go2rtc découpe la commande d'ffmpeg sans échappement (`shell.QuoteSplit`) et coupe la source au premier `#` :
    /// un nom vide, avec `#`, un caractère de contrôle, ou les deux sortes de guillemets à la fois, ne passe pas.
    case unsupportedName(String)
    /// Sans identifiant ou sans mot de passe, le flux RTSP serait ouvert à tout le réseau local.
    case missingCredential
    /// Un caractère de contrôle (saut de ligne, tabulation…) dans l'identifiant ou le mot de passe.
    case unsupportedCredential
    case invalidPort(Int)
    /// RTSP, WebRTC et l'API (1984) ont chacun leur port.
    case portConflict

    public var errorDescription: String? {
        switch self {
        case let .unsupportedName(name): Localization.text("Le nom « \(name) » contient un caractère que go2rtc ne sait pas lire.")
        case .missingCredential: Localization.text("L'identifiant et le mot de passe RTSP sont obligatoires.")
        case .unsupportedCredential: Localization.text("L'identifiant ou le mot de passe contient un caractère interdit (saut de ligne, tabulation…).")
        case let .invalidPort(port): Localization.text("Port \(String(port)) invalide : choisissez un port entre 1024 et 65535.")
        case .portConflict: Localization.text("Les ports RTSP, WebRTC et 1984 doivent être différents.")
        }
    }
}

/// Le yaml de go2rtc écrit par PTZBot (spec B3 § 4) : le pipeline en service chez le premier utilisateur, paramétré.
public enum Go2RTCConfig {
    public static let fileName = "go2rtc.yaml"
    public static let validPorts = 1024...65535

    /// Le texte du yaml. Les entrées `exec:` sont des blocs repliés `- >-` (sans saut de ligne final), toutes leurs
    /// lignes au même retrait : repliées, elles ne font qu'une ligne, et `killsignal=15` n'est jamais suivi d'un saut
    /// de ligne (avec `- >`, go2rtc lirait le signal « 15\n », enverrait le signal 0, et le ffmpeg vidéo fuirait).
    public static func yaml(settings: Go2RTCSettings, ffmpeg: String, camera: String, microphone: String) throws(Go2RTCConfigError) -> String {
        try validate(settings)
        let program = try argument(ffmpeg)
        let rate = settings.framerate
        let size = "\(settings.resolution.width)x\(settings.resolution.height)"
        let output = "-rtsp_transport tcp -f rtsp {output}#timeout=30s#killsignal=15"
        let video = [
            "exec:\(program) -hide_banner -fflags nobuffer -flags low_delay",
            "-thread_queue_size 1024",
            "-f avfoundation -framerate \(rate) -video_size \(size) -pixel_format nv12 -probesize 32M",
            "-i \(try argument(camera))",
            "-c:v h264_videotoolbox -realtime 1 -g \(rate) -bf 0 -level 4.0",
            "-color_range mpeg -r \(rate)",
            "-b:v \(settings.videoBitrate) -maxrate \(settings.videoMaxrate) -bufsize \(settings.videoBuffer)",
            "-bsf:v dump_extra=freq=keyframe",
            "-an",
            output,
        ]
        let audio = [
            "exec:\(program) -hide_banner -fflags nobuffer -flags low_delay",
            "-thread_queue_size 2048",
            "-f avfoundation -i \(try argument(":" + microphone))",
            "-af aresample=async=1000:first_pts=0",
            "-c:a aac -ar 48000 -ac 2 -b:a 128k",
            "-vn",
            output,
        ]
        var lines = [
            "# Écrit par PTZBot (Réglages › Caméra) : ne pas modifier, PTZBot le réécrit.",
            "# Written by PTZBot (Settings › Camera): do not edit, PTZBot rewrites it.",
            "api:",
            "  listen: \"127.0.0.1:\(Go2RTCSettings.apiPort)\"",
            "rtsp:",
            "  listen: \":\(settings.rtspPort)\"",
            "  username: \(quoted(settings.username))",
            "  password: \(quoted(settings.password))",
            "webrtc:",
            "  listen: \":\(settings.webrtcPort)\"",
            "ffmpeg:",
            "  bin: \(quoted(ffmpeg))",
            "log:",
            "  level: info",
            "preload:",
            "  \(Go2RTCSettings.streamName):",
            "streams:",
            "  \(Go2RTCSettings.streamName):",
        ]
        for entry in [video, audio] {
            lines.append("    - >-")
            lines += entry.map { "      " + $0 }
        }
        lines.append("    - ffmpeg:\(Go2RTCSettings.streamName)#audio=opus")
        return lines.joined(separator: "\n") + "\n"
    }

    static func validate(_ settings: Go2RTCSettings) throws(Go2RTCConfigError) {
        guard !settings.username.isEmpty, !settings.password.isEmpty else { throw .missingCredential }
        guard !hasControlCharacters(settings.username), !hasControlCharacters(settings.password) else { throw .unsupportedCredential }
        for port in [settings.rtspPort, settings.webrtcPort] where !validPorts.contains(port) {
            throw .invalidPort(port)
        }
        guard Set([settings.rtspPort, settings.webrtcPort, Go2RTCSettings.apiPort]).count == 3 else { throw .portConflict }
    }

    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Un argument de la commande d'ffmpeg, tel que go2rtc le découpe (`shell.QuoteSplit`) : nu s'il n'a ni espace ni
    /// guillemet ; sinon entre guillemets doubles, ou simples s'il contient un guillemet double. go2rtc ne connaît pas
    /// d'échappement : un nom avec les deux sortes de guillemets, un `#` (fin de la source), un caractère de contrôle
    /// ou rien du tout est refusé.
    static func argument(_ value: String) throws(Go2RTCConfigError) -> String {
        let hasDouble = value.contains("\"")
        let hasSingle = value.contains("'")
        guard !value.isEmpty, !value.contains("#"), !hasControlCharacters(value), !(hasDouble && hasSingle) else {
            throw .unsupportedName(value)
        }
        if !hasDouble, !hasSingle, !value.contains(" ") {
            return value
        }
        return hasDouble ? "'\(value)'" : "\"\(value)\""
    }

    /// Une chaîne yaml entre guillemets doubles : `\` et `"` échappés (les caractères de contrôle sont refusés avant).
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// L'écriture du yaml.
public enum Go2RTCConfigFile {
    /// Écrit `text` dans `url`, de façon atomique (fichier temporaire du même dossier, puis `rename`), en mode 600 dès
    /// la création : le yaml porte le mot de passe RTSP. Un contenu identique n'est pas réécrit (son mode est remis à
    /// 600 au besoin). Rend true si le fichier a changé.
    @discardableResult
    public static func write(_ text: String, to url: URL) throws -> Bool {
        let data = Data(text.utf8)
        if let current = try? Data(contentsOf: url), current == data {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return false
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return true
    }
}
````

Ajouter les textes au catalogue de PTZBotKit, depuis la racine du dépôt :

````bash
/usr/bin/python3 - mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings <<'PY'
import json, sys
chemin = sys.argv[1]
textes = {
    "Le nom « %@ » contient un caractère que go2rtc ne sait pas lire.": "The name “%@” contains a character go2rtc cannot read.",
    "L'identifiant et le mot de passe RTSP sont obligatoires.": "The RTSP user name and password are required.",
    "L'identifiant ou le mot de passe contient un caractère interdit (saut de ligne, tabulation…).": "The user name or password contains a forbidden character (line break, tab…).",
    "Port %@ invalide : choisissez un port entre 1024 et 65535.": "Invalid port %@: choose a port between 1024 and 65535.",
    "Les ports RTSP, WebRTC et 1984 doivent être différents.": "The RTSP, WebRTC and 1984 ports must be different.",
}
d = json.load(open(chemin, encoding='utf-8'))
for fr, en in textes.items():
    d['strings'][fr] = {"extractionState": "manual", "localizations": {
        "en": {"stringUnit": {"state": "translated", "value": en}},
        "fr": {"stringUnit": {"state": "translated", "value": fr}}}}
open(chemin, 'w', encoding='utf-8').write(json.dumps(d, ensure_ascii=False, indent=2) + '\n')
PY
````

- [x] **Étape 4 : Lancer les tests, constater la réussite**

Run : `(cd mac/app/PTZBotKit && swift build --build-tests 2>&1 | grep -E "warning|error" ; swift test)`
Attendu : aucun avertissement ; `Test run with 306 tests in 22 suites passed` (les tests des catalogues compris).

- [x] **Étape 5 : Commit**

```bash
git add mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCSettings.swift mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCConfig.swift \
  mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings \
  mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCTestSupport.swift mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCConfigTests.swift
git commit -F - <<'MSG'
go2rtc : réglages (sans mot de passe dans les préférences) et yaml généré, modèle exact, écrit en 600

<ligne Co-Authored-By du modèle>
MSG
```

---

### Tâche 3 : import d'une configuration existante

**But :** un lecteur minimal du yaml de go2rtc, sans dépendance (spec § 4) : il reprend l'identifiant, le mot de passe RTSP, les ports et, s'ils sont reconnus, les noms des appareils (après `-f avfoundation … -i`) et le chemin de ffmpeg (`ffmpeg: bin:` ou `exec:/…/ffmpeg`). Il ignore les commentaires, comprend les valeurs nues, entre guillemets doubles ou simples, et les blocs `- >` comme `- >-`. Le fichier lu n'est jamais modifié. Au lancement, `Go2RTCSettings.restore` relit le mot de passe dans le yaml de PTZBot, ou en tire un neuf.

**Fichiers :**
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCImport.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings` (2 textes)
- Tester : `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCImportTests.swift`

**Interfaces :**
- Consomme : `Go2RTCSettings`, `Go2RTCConfig.yaml`, `Go2RTCConfigFile.write`, `Go2RTCFixtures` (tâche 2), `FakeSettings`.
- Produit :
  - `Go2RTCImport` (`username?`, `password?`, `rtspPort?`, `webrtcPort?`, `cameraName?`, `microphoneName?`, `ffmpegPath?`), `isEmpty`, `applied(to: Go2RTCSettings) -> Go2RTCSettings` (coupe le fichier personnalisé) ;
  - `Go2RTCImportError` : `.unreadable(String)`, `.nothingRecognized` (`LocalizedError`) ;
  - `Go2RTCConfigReader.read(contentsOf: URL) throws(Go2RTCImportError) -> Go2RTCImport`, `Go2RTCConfigReader.read(_ text: String) -> Go2RTCImport` ;
  - `@MainActor Go2RTCSettings.restore(from: any SettingsStore, config: URL) -> Go2RTCSettings` ;
  - pour les tests suivants : `Go2RTCImportTests.handWritten` (une configuration écrite à la main, identifiants fictifs).

- [x] **Étape 1 : Écrire les tests**

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCImportTests.swift` :

````swift
import Foundation
import Testing
@testable import PTZBotKit

@Suite("go2rtc : import d'une configuration existante", .french)
struct Go2RTCImportTests {
    /// Une configuration écrite à la main, comme celles d'avant PTZBot : blocs `- >` à retrait croissant, commentaires,
    /// valeurs nues ou entre guillemets. Identifiants fictifs.
    static let handWritten = """
    # go2rtc de la maison
    api:
      listen: "127.0.0.1:1984"   # API locale
    rtsp:
      listen: ":8554"
      username: camera
      password: "secret-de-test"
    webrtc:
      listen: ":8555"
    ffmpeg:
      bin: /opt/homebrew/bin/ffmpeg   # chemin complet
    preload:
      obsbot:
    streams:
      obsbot:
        - >
          exec:/opt/homebrew/bin/ffmpeg -hide_banner -fflags nobuffer -flags low_delay
            -thread_queue_size 1024
            -f avfoundation -framerate 30 -video_size 1920x1080 -pixel_format nv12 -probesize 32M
            -i "OBSBOT Tiny 2 StreamCamera"
            -c:v h264_videotoolbox -an
            -rtsp_transport tcp -f rtsp {output}#timeout=30s#killsignal=15
        - >
          exec:/opt/homebrew/bin/ffmpeg -hide_banner
            -f avfoundation -i ":OBSBOT Tiny2 Microphone"
            -c:a aac -vn -rtsp_transport tcp -f rtsp {output}#killsignal=15
        - ffmpeg:obsbot#audio=opus
    """

    @Test("Configuration complète écrite à la main : tout est repris")
    func handWrittenFile() {
        #expect(Go2RTCConfigReader.read(Self.handWritten) == Go2RTCImport(
            username: "camera", password: "secret-de-test", rtspPort: 8554, webrtcPort: 8555,
            cameraName: "OBSBOT Tiny 2 StreamCamera", microphoneName: "OBSBOT Tiny2 Microphone",
            ffmpegPath: "/opt/homebrew/bin/ffmpeg"
        ))
    }

    @Test("Le yaml que PTZBot écrit se relit à l'identique, échappements compris")
    func roundTrip() throws {
        var settings = Go2RTCFixtures.settings()
        settings.password = #"a"b\c d#e"#
        settings.rtspPort = 9554
        let text = try Go2RTCConfig.yaml(settings: settings, ffmpeg: Go2RTCFixtures.ffmpeg, camera: #"Caméra "A""#, microphone: "Micro d'Anne")
        #expect(Go2RTCConfigReader.read(text) == Go2RTCImport(
            username: "ptzbot", password: #"a"b\c d#e"#, rtspPort: 9554, webrtcPort: 8555,
            cameraName: #"Caméra "A""#, microphoneName: "Micro d'Anne", ffmpegPath: Go2RTCFixtures.ffmpeg
        ))
    }

    @Test("Configuration partielle : seul ce qui est là est repris ; ffmpeg lu dans exec: sans section ffmpeg")
    func partial() {
        #expect(Go2RTCConfigReader.read("rtsp:\n  listen: \"0.0.0.0:9554\"\n") == Go2RTCImport(rtspPort: 9554))
        let execOnly = "streams:\n  cam:\n    - exec:/usr/local/bin/ffmpeg -f avfoundation -i 0 -f rtsp {output}\n"
        #expect(Go2RTCConfigReader.read(execOnly) == Go2RTCImport(ffmpegPath: "/usr/local/bin/ffmpeg"))
    }

    @Test("Commentaires et guillemets : # dans une valeur entre guillemets, '' dans des simples, commentaire après une valeur nue")
    func quotingAndComments() {
        let text = """
        rtsp:
        #  password: ancien
          username: 'l''admin'
          password: "a#b\\"c"   # entre guillemets
        webrtc:
          listen: :8555 # nu
        """
        #expect(Go2RTCConfigReader.read(text) == Go2RTCImport(username: "l'admin", password: #"a#b"c"#, webrtcPort: 8555))
    }

    @Test("Appareils : « caméra:micro » d'une seule entrée ; un numéro n'est pas un nom")
    func devices() {
        let combined = "streams:\n  s:\n    - exec:ffmpeg -f avfoundation -i \"Caméra:Micro\" -f rtsp {output}\n"
        #expect(Go2RTCConfigReader.read(combined).cameraName == "Caméra")
        #expect(Go2RTCConfigReader.read(combined).microphoneName == "Micro")
        let indexes = "streams:\n  s:\n    - exec:ffmpeg -f avfoundation -i 0:1 -f rtsp {output}\n"
        #expect(Go2RTCConfigReader.read(indexes).cameraName == nil)
        #expect(Go2RTCConfigReader.read(indexes).microphoneName == nil)
    }

    @Test("Illisible : fichier absent, texte sans rien de reconnu, données binaires")
    func unreadable() throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "absent.yaml")
        #expect(throws: Go2RTCImportError.self) { try Go2RTCConfigReader.read(contentsOf: missing) }
        do {
            _ = try Go2RTCConfigReader.read(contentsOf: missing)
        } catch {
            guard case .unreadable = error else {
                Issue.record("attendu : unreadable, reçu \(error)")
                return
            }
        }
        let text = directory.appending(path: "texte.yaml")
        try Data("bonjour\nle monde: oui\n".utf8).write(to: text)
        #expect(throws: Go2RTCImportError.nothingRecognized) { try Go2RTCConfigReader.read(contentsOf: text) }
        let binary = directory.appending(path: "binaire.yaml")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: binary)
        #expect(throws: Go2RTCImportError.nothingRecognized) { try Go2RTCConfigReader.read(contentsOf: binary) }
    }

    @Test("Appliqué aux réglages : ce qui est repris remplace, le reste est gardé, le fichier personnalisé est coupé")
    func applied() {
        var settings = Go2RTCFixtures.settings()
        settings.framerate = 25
        settings.customConfigEnabled = true
        settings.customConfigPath = "/support/perso.yaml"
        let result = Go2RTCImport(username: "camera", rtspPort: 9554, cameraName: "Autre caméra").applied(to: settings)
        #expect(result.username == "camera")
        #expect(result.password == Go2RTCFixtures.password)
        #expect(result.rtspPort == 9554)
        #expect(result.cameraName == "Autre caméra")
        #expect(result.framerate == 25)
        #expect(!result.customConfigEnabled)
    }

    @MainActor
    @Test("Au lancement : le mot de passe relu du yaml ; sans yaml, un mot de passe neuf")
    func restore() throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appending(path: "go2rtc.yaml")
        let store = FakeSettings()
        var saved = Go2RTCFixtures.settings()
        saved.framerate = 15
        saved.save(to: store)
        let fresh = Go2RTCSettings.restore(from: store, config: config)
        #expect(fresh.password.count == 20)
        #expect(fresh.framerate == 15)
        try Go2RTCConfigFile.write(try Go2RTCConfig.yaml(settings: saved, ffmpeg: Go2RTCFixtures.ffmpeg, camera: Go2RTCFixtures.camera, microphone: Go2RTCFixtures.microphone), to: config)
        #expect(Go2RTCSettings.restore(from: store, config: config) == saved)
    }

    @Test("Messages d'erreur de l'import en français et en anglais")
    func messages() {
        for error in [Go2RTCImportError.unreadable("x"), .nothingRecognized] {
            let french = Localization.$languageOverride.withValue("fr") { error.localizedDescription }
            let english = Localization.$languageOverride.withValue("en") { error.localizedDescription }
            #expect(french != english)
        }
    }
}
````

- [x] **Étape 2 : Lancer les tests, constater l'échec**

Run : `(cd mac/app/PTZBotKit && swift test)`
Attendu : échec de compilation, « cannot find 'Go2RTCConfigReader' in scope ».

- [x] **Étape 3 : Écrire le lecteur**

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCImport.swift` :

````swift
import Foundation

/// Ce que PTZBot reprend d'une configuration go2rtc existante (spec B3 § 4) : l'identifiant, le mot de passe RTSP, les
/// ports et, s'ils sont reconnus, les noms des appareils et le chemin de ffmpeg. Le fichier lu n'est jamais modifié.
public struct Go2RTCImport: Equatable, Sendable {
    public var username: String?
    public var password: String?
    public var rtspPort: Int?
    public var webrtcPort: Int?
    public var cameraName: String?
    public var microphoneName: String?
    public var ffmpegPath: String?

    public init(
        username: String? = nil, password: String? = nil, rtspPort: Int? = nil, webrtcPort: Int? = nil,
        cameraName: String? = nil, microphoneName: String? = nil, ffmpegPath: String? = nil
    ) {
        self.username = username
        self.password = password
        self.rtspPort = rtspPort
        self.webrtcPort = webrtcPort
        self.cameraName = cameraName
        self.microphoneName = microphoneName
        self.ffmpegPath = ffmpegPath
    }

    /// Rien de reconnu.
    public var isEmpty: Bool {
        self == Go2RTCImport()
    }

    /// Les réglages avec ce qui a été repris ; le reste est gardé. Une configuration importée devient celle que PTZBot
    /// écrit : le fichier personnalisé est coupé.
    public func applied(to settings: Go2RTCSettings) -> Go2RTCSettings {
        var result = settings
        if let username { result.username = username }
        if let password { result.password = password }
        if let rtspPort { result.rtspPort = rtspPort }
        if let webrtcPort { result.webrtcPort = webrtcPort }
        if let cameraName { result.cameraName = cameraName }
        if let microphoneName { result.microphoneName = microphoneName }
        if let ffmpegPath { result.ffmpegPath = ffmpegPath }
        result.customConfigEnabled = false
        return result
    }
}

/// Pourquoi une configuration n'a pas pu être importée.
public enum Go2RTCImportError: LocalizedError, Equatable, Sendable {
    case unreadable(String)
    case nothingRecognized

    public var errorDescription: String? {
        switch self {
        case let .unreadable(reason): Localization.text("Ce fichier n'a pas pu être lu : \(reason)")
        case .nothingRecognized: Localization.text("Rien de reconnu dans ce fichier : est-ce une configuration go2rtc ?")
        }
    }
}

/// Un lecteur minimal du yaml de go2rtc, sans dépendance : il ne comprend que ce que PTZBot reprend (sections `rtsp`,
/// `webrtc`, `ffmpeg` et `streams`), ignore les commentaires et tout le reste.
public enum Go2RTCConfigReader {
    public static func read(contentsOf url: URL) throws(Go2RTCImportError) -> Go2RTCImport {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw .nothingRecognized }
        let result = read(text)
        guard !result.isEmpty else { throw .nothingRecognized }
        return result
    }

    public static func read(_ text: String) -> Go2RTCImport {
        var result = Go2RTCImport()
        var section = ""
        var streamLines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let indent = line.prefix { $0 == " " }.count
            let content = line.dropFirst(indent).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, !content.hasPrefix("#") else { continue }
            if indent == 0 {
                section = key(content) ?? ""
                continue
            }
            if section == "streams" {
                streamLines.append(content)
                continue
            }
            guard let key = key(content), let value = value(content) else { continue }
            switch (section, key) {
            case ("rtsp", "username"): result.username = value
            case ("rtsp", "password"): result.password = value
            case ("rtsp", "listen"): result.rtspPort = port(value)
            case ("webrtc", "listen"): result.webrtcPort = port(value)
            case ("ffmpeg", "bin"): result.ffmpegPath = value
            default: break
            }
        }
        let tokens = tokens(streamLines.joined(separator: " "))
        readDevices(tokens, into: &result)
        if result.ffmpegPath == nil {
            result.ffmpegPath = tokens.lazy.compactMap(execProgram).first
        }
        return result
    }

    /// La clé d'une ligne `clé: valeur` ou `clé:` ; nil pour un élément de liste ou du texte.
    static func key(_ content: String) -> String? {
        guard !content.hasPrefix("-"), let colon = content.firstIndex(of: ":") else { return nil }
        let key = content[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        let after = content[content.index(after: colon)...]
        guard after.isEmpty || after.first == " " else { return nil }
        return key
    }

    /// La valeur après `clé:` : entre guillemets doubles (`\"` et `\\` échappés), simples (`''` pour `'`), ou nue
    /// jusqu'à un commentaire (` #`). nil si elle est vide ou si un guillemet ne se ferme pas.
    static func value(_ content: String) -> String? {
        guard let colon = content.firstIndex(of: ":") else { return nil }
        let raw = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard let first = raw.first else { return nil }
        var result = ""
        if first == "\"" {
            var escaped = false
            for character in raw.dropFirst() {
                if escaped {
                    result.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    return result
                } else {
                    result.append(character)
                }
            }
            return nil
        }
        if first == "'" {
            let characters = Array(raw.dropFirst())
            var index = 0
            while index < characters.count {
                if characters[index] == "'" {
                    guard index + 1 < characters.count, characters[index + 1] == "'" else { return result }
                    result.append("'")
                    index += 2
                } else {
                    result.append(characters[index])
                    index += 1
                }
            }
            return nil
        }
        let plain = raw.range(of: " #").map { String(raw[..<$0.lowerBound]) } ?? raw
        let trimmed = plain.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Le port d'une adresse d'écoute (« :8554 », « 0.0.0.0:8554 », « 8554 »).
    static func port(_ listen: String) -> Int? {
        let digits = listen.lastIndex(of: ":").map { listen[listen.index(after: $0)...] } ?? Substring(listen)
        guard let port = Int(digits), (1...65535).contains(port) else { return nil }
        return port
    }

    /// Les mots d'une commande, comme les découpe go2rtc (`shell.QuoteSplit`), en plus tolérant : un guillemet qui ne
    /// se ferme pas prend le reste du texte.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while let first = rest.first {
            if first == " " || first == "\t" {
                rest = rest.dropFirst()
            } else if first == "\"" || first == "'" {
                let body = rest.dropFirst()
                let end = body.firstIndex(of: first) ?? body.endIndex
                result.append(String(body[..<end]))
                rest = end == body.endIndex ? "" : body[body.index(after: end)...]
            } else {
                let end = rest.firstIndex { $0 == " " || $0 == "\t" } ?? rest.endIndex
                result.append(String(rest[..<end]))
                rest = rest[end...]
            }
        }
        return result
    }

    /// Après chaque `-f avfoundation`, l'entrée `-i` : « :micro », « caméra » ou « caméra:micro ». Un numéro (« 0 »),
    /// « none » ou « default » n'est pas un nom : non reconnu. Le premier de chaque sorte est gardé.
    static func readDevices(_ tokens: [String], into result: inout Go2RTCImport) {
        var index = 0
        while index + 1 < tokens.count {
            defer { index += 1 }
            guard tokens[index] == "-f", tokens[index + 1] == "avfoundation",
                  let input = tokens[(index + 2)...].firstIndex(of: "-i"), input + 1 < tokens.count else { continue }
            let parts = tokens[input + 1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if result.cameraName == nil, isName(parts[0]) {
                result.cameraName = parts[0]
            }
            if result.microphoneName == nil, parts.count > 1, isName(parts[1]) {
                result.microphoneName = parts[1]
            }
        }
    }

    static func isName(_ text: String) -> Bool {
        !text.isEmpty && Int(text) == nil && text != "none" && text != "default"
    }

    /// `exec:/chemin/ffmpeg` : le chemin, s'il est absolu et finit par ffmpeg.
    static func execProgram(_ token: String) -> String? {
        guard token.hasPrefix("exec:") else { return nil }
        let program = String(token.dropFirst(5))
        return program.hasPrefix("/") && (program as NSString).lastPathComponent == "ffmpeg" ? program : nil
    }
}

extension Go2RTCSettings {
    /// Les réglages au lancement : les préférences, et le mot de passe relu du yaml de PTZBot (`config`). Sans yaml
    /// lisible, un mot de passe neuf : le premier yaml écrit le retiendra.
    @MainActor
    public static func restore(from store: any SettingsStore, config: URL) -> Go2RTCSettings {
        var settings = load(from: store)
        if let password = (try? Go2RTCConfigReader.read(contentsOf: config))?.password, !password.isEmpty {
            settings.password = password
        } else {
            settings.password = randomPassword()
        }
        return settings
    }
}
````

Ajouter les textes au catalogue de PTZBotKit :

````bash
/usr/bin/python3 - mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings <<'PY'
import json, sys
chemin = sys.argv[1]
textes = {
    "Ce fichier n'a pas pu être lu : %@": "This file could not be read: %@",
    "Rien de reconnu dans ce fichier : est-ce une configuration go2rtc ?": "Nothing recognized in this file: is it a go2rtc configuration?",
}
d = json.load(open(chemin, encoding='utf-8'))
for fr, en in textes.items():
    d['strings'][fr] = {"extractionState": "manual", "localizations": {
        "en": {"stringUnit": {"state": "translated", "value": en}},
        "fr": {"stringUnit": {"state": "translated", "value": fr}}}}
open(chemin, 'w', encoding='utf-8').write(json.dumps(d, ensure_ascii=False, indent=2) + '\n')
PY
````

- [x] **Étape 4 : Lancer les tests, constater la réussite**

Run : `(cd mac/app/PTZBotKit && swift build --build-tests 2>&1 | grep -E "warning|error" ; swift test)`
Attendu : aucun avertissement ; `Test run with 315 tests in 23 suites passed`.

- [x] **Étape 5 : Commit**

```bash
git add mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCImport.swift mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings \
  mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCImportTests.swift
git commit -F - <<'MSG'
go2rtc : import d'une configuration existante (lecteur minimal, commentaires et guillemets) ; mot de passe relu au lancement

<ligne Co-Authored-By du modèle>
MSG
```

---

### Tâche 4 : ffmpeg et appareils

**But :** la recherche de ffmpeg (spec § 3.5 : chemin réglé, puis `/opt/homebrew/bin/ffmpeg`, puis `/usr/local/bin/ffmpeg` ; un exécutable qui répond à `-version`) et le catalogue des caméras et micros (§ 3.6 : `AVCaptureDevice.DiscoverySession`, derrière un protocole), avec le choix par défaut : la première OBSBOT réelle, avant une OBSBOT virtuelle (l'extension caméra d'OBSBOT Center).

**Fichiers :**
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/FFmpegLocator.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/CaptureDevices.swift`
- Tester : `mac/app/PTZBotKit/Tests/PTZBotKitTests/FFmpegAndDevicesTests.swift`

**Interfaces :**
- Consomme : `ChildProcess.run(_:arguments:environment:timeout:captureOutput:)` (interne à PTZBotKit, `Toolchain.swift`).
- Produit :
  - `FFmpegLocator` (`Sendable`) : `candidates`, `installCommand` (« brew install ffmpeg »), `versionTimeout`, `init(isExecutable:respondsToVersion:)`, `locate(configured: String?) -> URL?` (bloquant), `static system()` ;
  - `CaptureDeviceInfo(name:isVirtual:)` ; protocole `CaptureDeviceCatalog: Sendable` (`cameras()`, `microphones()`) ; `AVFoundationDeviceCatalog()` ;
  - `CaptureDeviceChoice.preferred(in:) -> String?`, `CaptureDeviceChoice.resolve(configured:in:) -> String?`.

- [x] **Étape 1 : Écrire les tests**

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/FFmpegAndDevicesTests.swift` :

````swift
import Foundation
import Testing
@testable import PTZBotKit

@Suite("go2rtc : ffmpeg et appareils", .french)
struct FFmpegAndDevicesTests {
    /// Un ffmpeg simulé : `executables` existent, `responding` répondent à -version.
    private func locator(executables: Set<String>, responding: Set<String>? = nil) -> FFmpegLocator {
        let answering = responding ?? executables
        return FFmpegLocator(isExecutable: { executables.contains($0) }, respondsToVersion: { answering.contains($0) })
    }

    @Test("Ordre : le chemin réglé, puis Homebrew Apple Silicon, puis Intel")
    func order() {
        let all: Set = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/outils/ffmpeg"]
        #expect(locator(executables: all).locate(configured: "/outils/ffmpeg")?.path == "/outils/ffmpeg")
        #expect(locator(executables: all).locate(configured: nil)?.path == "/opt/homebrew/bin/ffmpeg")
        #expect(locator(executables: ["/usr/local/bin/ffmpeg"]).locate(configured: nil)?.path == "/usr/local/bin/ffmpeg")
    }

    @Test("Chemin réglé absent, relatif, ou qui ne répond pas à -version : les places habituelles ; rien : nil")
    func fallbacks() {
        let homebrew = locator(executables: ["/opt/homebrew/bin/ffmpeg", "/outils/ffmpeg"], responding: ["/opt/homebrew/bin/ffmpeg"])
        #expect(homebrew.locate(configured: "/outils/ffmpeg")?.path == "/opt/homebrew/bin/ffmpeg")
        #expect(homebrew.locate(configured: "/ailleurs/ffmpeg")?.path == "/opt/homebrew/bin/ffmpeg")
        #expect(homebrew.locate(configured: "ffmpeg")?.path == "/opt/homebrew/bin/ffmpeg")
        #expect(locator(executables: []).locate(configured: "/outils/ffmpeg") == nil)
        #expect(FFmpegLocator.installCommand == "brew install ffmpeg")
    }

    @Test("Vrais processus : /usr/bin/true répond (code 0), /usr/bin/false non")
    func realProbe() {
        let system = FFmpegLocator.system()
        #expect(system.locate(configured: "/usr/bin/true")?.path == "/usr/bin/true")
        #expect(system.locate(configured: "/usr/bin/false")?.path != "/usr/bin/false")
    }

    @Test("Choix par défaut : la première OBSBOT réelle, avant une OBSBOT virtuelle ; sans OBSBOT, rien")
    func preferred() {
        let devices = [
            CaptureDeviceInfo(name: "FaceTime HD Camera", isVirtual: false),
            CaptureDeviceInfo(name: "OBSBOT Virtual Camera", isVirtual: true),
            CaptureDeviceInfo(name: "OBSBOT Tiny 2 StreamCamera", isVirtual: false),
        ]
        #expect(CaptureDeviceChoice.preferred(in: devices) == "OBSBOT Tiny 2 StreamCamera")
        #expect(CaptureDeviceChoice.preferred(in: [devices[1]]) == "OBSBOT Virtual Camera")
        #expect(CaptureDeviceChoice.preferred(in: [devices[0]]) == nil)
        #expect(CaptureDeviceChoice.preferred(in: [CaptureDeviceInfo(name: "obsbot tiny2 microphone", isVirtual: false)]) == "obsbot tiny2 microphone")
    }

    @Test("Nom réglé : gardé s'il est branché, nil sinon ; sans nom réglé, le choix par défaut")
    func resolve() {
        let devices = [CaptureDeviceInfo(name: "OBSBOT Tiny 2 StreamCamera", isVirtual: false), CaptureDeviceInfo(name: "Autre", isVirtual: false)]
        #expect(CaptureDeviceChoice.resolve(configured: "Autre", in: devices) == "Autre")
        #expect(CaptureDeviceChoice.resolve(configured: "Débranchée", in: devices) == nil)
        #expect(CaptureDeviceChoice.resolve(configured: nil, in: devices) == "OBSBOT Tiny 2 StreamCamera")
        #expect(CaptureDeviceChoice.resolve(configured: "", in: devices) == "OBSBOT Tiny 2 StreamCamera")
    }

    @Test("Catalogue réel : la liste se lit sans demander d'autorisation, et sans planter")
    func realCatalog() {
        let catalog = AVFoundationDeviceCatalog()
        #expect(catalog.cameras().allSatisfy { !$0.name.isEmpty })
        #expect(catalog.microphones().allSatisfy { !$0.name.isEmpty })
    }
}
````

- [x] **Étape 2 : Lancer les tests, constater l'échec**

Run : `(cd mac/app/PTZBotKit && swift test)`
Attendu : échec de compilation, « cannot find 'FFmpegLocator' in scope ».

- [x] **Étape 3 : Écrire la recherche et le catalogue**

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/FFmpegLocator.swift` :

````swift
import Foundation

/// La recherche de ffmpeg (spec B3 § 3.5) : le chemin réglé dans l'onglet « Caméra », puis Homebrew sur Apple Silicon,
/// puis sur Intel. Il faut un exécutable qui répond à `-version`. ffmpeg n'est jamais fourni avec PTZBot : la version de
/// Homebrew est sous GPL.
public struct FFmpegLocator: Sendable {
    public static let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    /// La commande donnée quand ffmpeg manque.
    public static let installCommand = "brew install ffmpeg"
    /// Le délai de `ffmpeg -version`.
    public static let versionTimeout: TimeInterval = 5

    private let isExecutable: @Sendable (String) -> Bool
    private let respondsToVersion: @Sendable (String) -> Bool

    public init(isExecutable: @escaping @Sendable (String) -> Bool, respondsToVersion: @escaping @Sendable (String) -> Bool) {
        self.isExecutable = isExecutable
        self.respondsToVersion = respondsToVersion
    }

    /// Le premier candidat exécutable qui répond à `-version` ; un chemin réglé passe en premier s'il est absolu. nil :
    /// introuvable. Bloquant (`ffmpeg -version`) : hors du fil de l'interface.
    public func locate(configured: String?) -> URL? {
        var paths = Self.candidates
        if let configured, configured.hasPrefix("/") {
            paths.insert(configured, at: 0)
        }
        for path in paths where isExecutable(path) && respondsToVersion(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Les vrais fichiers, et un vrai `ffmpeg -version` (5 s au plus).
    public static func system() -> FFmpegLocator {
        FFmpegLocator(
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            respondsToVersion: { path in
                let result = ChildProcess.run(URL(fileURLWithPath: path), arguments: ["-version"], timeout: versionTimeout)
                return result?.exited == true && result?.status == 0
            }
        )
    }
}
````

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/CaptureDevices.swift` :

````swift
import AVFoundation

/// Une caméra ou un micro du Mac.
public struct CaptureDeviceInfo: Equatable, Hashable, Sendable {
    public var name: String
    /// Un appareil virtuel (extension caméra d'OBSBOT Center, d'OBS…) : jamais choisi d'office.
    public var isVirtual: Bool

    public init(name: String, isVirtual: Bool) {
        self.name = name
        self.isVirtual = isVirtual
    }
}

/// Les caméras et micros du Mac, derrière un protocole pour les tests. Les lister ne demande aucune autorisation.
public protocol CaptureDeviceCatalog: Sendable {
    func cameras() -> [CaptureDeviceInfo]
    func microphones() -> [CaptureDeviceInfo]
}

/// Les vrais appareils, par `AVCaptureDevice.DiscoverySession` (spec B3 § 3.6).
public struct AVFoundationDeviceCatalog: CaptureDeviceCatalog {
    /// `kIOAudioDeviceTransportTypeVirtual` (« virt »).
    static let virtualTransport: Int32 = 0x7669_7274

    public init() {}

    public func cameras() -> [CaptureDeviceInfo] {
        Self.list(AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified
        ).devices)
    }

    public func microphones() -> [CaptureDeviceInfo] {
        Self.list(AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices)
    }

    static func list(_ devices: [AVCaptureDevice]) -> [CaptureDeviceInfo] {
        devices.map { device in
            CaptureDeviceInfo(
                name: device.localizedName,
                isVirtual: device.transportType == virtualTransport || device.localizedName.localizedCaseInsensitiveContains("virtual")
            )
        }
    }
}

/// Le choix des appareils (spec B3 § 3.6).
public enum CaptureDeviceChoice {
    public static let brand = "OBSBOT"

    /// Le premier appareil dont le nom contient « OBSBOT », un vrai de préférence à un virtuel ; nil sans OBSBOT.
    public static func preferred(in devices: [CaptureDeviceInfo]) -> String? {
        let obsbot = devices.filter { $0.name.localizedCaseInsensitiveContains(brand) }
        return (obsbot.first { !$0.isVirtual } ?? obsbot.first)?.name
    }

    /// Le nom réglé s'il y en a un, sinon le choix par défaut ; nil si l'appareil n'est pas là.
    public static func resolve(configured: String?, in devices: [CaptureDeviceInfo]) -> String? {
        if let configured, !configured.isEmpty {
            return devices.contains { $0.name == configured } ? configured : nil
        }
        return preferred(in: devices)
    }
}
````

- [x] **Étape 4 : Lancer les tests, constater la réussite**

Run : `(cd mac/app/PTZBotKit && swift build --build-tests 2>&1 | grep -E "warning|error" ; swift test)`
Attendu : aucun avertissement ; `Test run with 321 tests in 24 suites passed`. Le catalogue réel se lit sans demande d'autorisation (lister les appareils n'en demande pas).

- [x] **Étape 5 : Commit**

```bash
git add mac/app/PTZBotKit/Sources/PTZBotKit/FFmpegLocator.swift mac/app/PTZBotKit/Sources/PTZBotKit/CaptureDevices.swift \
  mac/app/PTZBotKit/Tests/PTZBotKitTests/FFmpegAndDevicesTests.swift
git commit -F - <<'MSG'
go2rtc : recherche de ffmpeg (chemin réglé, Homebrew) et catalogue des caméras et micros, OBSBOT réelle par défaut

<ligne Co-Authored-By du modèle>
MSG
```

---

### Tâche 5 : le superviseur de go2rtc

**But :** `Go2RTCSupervisor` (spec § 3.3), sur le modèle de `ServiceSupervisor` : lancement par le gardien (`--parent <PTZBot> --arret 10 -- go2rtc -config <yaml>`), `PATH` qui commence par le dossier de ffmpeg puis `/usr/bin:/bin`, journal `go2rtc.log`, relances 1, 2, 4, 8, 16 puis 30 s, échec au-delà de 5 arrêts en 120 s, arrêt en douceur (SIGTERM au gardien, qui laisse 10 s à go2rtc ; SIGKILL au gardien seulement à 15 s), interrupteur `go2rtcEnabled` éteint par défaut. Avant chaque lancement, une **préparation** hors du fil de l'interface (`Go2RTCPreparer`) : ffmpeg, appareils branchés, yaml réécrit s'il a changé, puis essai d'ouverture des ports (RTSP en TCP, WebRTC en TCP et UDP, l'API sur 127.0.0.1). « Quitter » attend ptzd et go2rtc.

**Fichiers :**
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/ProcessLauncher.swift` (variables d'environnement)
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/PortProbe.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCPreparer.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCSupervisor.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift`
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift` (`FakeLauncher` retient l'environnement)
- Modifier : `mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift`
- Tester : `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCFakes.swift`, `Go2RTCPreparerTests.swift`, `Go2RTCSupervisorTests.swift`

**Interfaces :**
- Consomme : `Go2RTCSettings`, `Go2RTCConfig`, `Go2RTCConfigFile`, `Go2RTCConfigError` (tâche 2) ; `Go2RTCSettings.restore` (tâche 3) ; `FFmpegLocator`, `CaptureDeviceCatalog`, `CaptureDeviceChoice` (tâche 4) ; le contrat du gardien (tâche 1).
- Produit :
  - `ProcessLauncher.launch(executableURL:arguments:environment:outputURL:onExit:)` (l'ancienne forme sans `environment` reste, par une extension) ; `FakeLauncher.environments` ;
  - `PortTransport` (`.tcp`, `.udp`) ; protocole `PortProbe: Sendable` (`isFree(_:transport:loopbackOnly:)`) ; `SystemPortProbe()` ;
  - `Go2RTCBlock` (`.ffmpegMissing`, `.cameraMissing`, `.microphoneMissing`, `.portBusy(Int)`, `.customFileMissing`, `.invalidSettings(String)`, `.writeFailed(String)`) ; `Go2RTCLaunch(config:ffmpegDirectory:custom:)` ; `Go2RTCPreparation` (`.ready`, `.blocked`) ; protocole `Go2RTCPreparing: Sendable` (`prepare(_:) async`, `writeConfig(_:) async -> Go2RTCBlock?`) ; `Go2RTCPreparer(configURL:locator:catalog:ports:)`, `Go2RTCPreparer.system(paths:)` ;
  - `Go2RTCFailure` (`.blocked(Go2RTCBlock)`, `.crashLoop`, `.launch(String)`, `.missingBinary`, `.unkillable`) ;
  - `Go2RTCSupervisor` (`@MainActor @Observable`) : `State` (`.stopped`, `.starting`, `.running`, `.restarting(count:)`, `.failed(Go2RTCFailure)`), `Paths(gardien:go2rtc:log:)`, `restartDelays`, `maxUnexpectedExits`, `failureWindow`, `stopDelay` (10), `killDelay` (15), `enabledKey` (« go2rtcEnabled »), `state`, `isEnabled`, `usesCustomFile`, `gardienPID`, `launchCount`, `logOffsetAtLaunch`, `configuration`, `init(paths:launcher:preparer:settings:scheduler:parentPID:configuration:)`, `system(paths:preparer:scheduler:)`, `arguments(config:)`, `static environment(ffmpegDirectory:)`, `start()`, `stop(forQuit:completion:)`, `setEnabled(_:)`, `restart()`, `waitForPreparation() async` ;
  - `AppPaths.go2rtc`, `.gardien`, `.go2rtcConfig`, `.go2rtcLog`, `.go2rtcService` ;
  - `AppController(supervisor:go2rtc:…)` (`go2rtc` facultatif), `AppController.go2rtc`, `quitStopsCamera`, `quitDelay`, `go2rtcQuitTimeout` (16) ;
  - pour les tests suivants : `FakePreparer` (`result`, `writeResult`, `holds`, `prepared`, `written`, `onMainThread`, `isHeld`, `release()`), `FakePorts` (`busy(_:)`, `probed`), `FakeCatalog`, `FFmpegLocator.homebrew`, `FFmpegLocator.missing`.

- [x] **Étape 1 : Écrire les tests**

Dans `Fakes.swift`, `FakeLauncher` prend le nouveau paramètre et le retient (appliquer depuis la racine du dépôt) :

````bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift
index bc03a0c..34c6cb0 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift
@@ -371,6 +371,8 @@ final class FakeLauncher: ProcessLauncher {
 
     private(set) var launched: [FakeProcess] = []
     private(set) var executables: [URL] = []
+    /// Les variables données à chaque lancement (vide : l'environnement de l'app).
+    private(set) var environments: [[String: String]] = []
     var failure: (any Error)?
 
     var last: FakeProcess? {
@@ -380,6 +382,7 @@ final class FakeLauncher: ProcessLauncher {
     func launch(
         executableURL: URL,
         arguments: [String],
+        environment: [String: String],
         outputURL: URL,
         onExit: @escaping @MainActor (ProcessExit) -> Void
     ) throws -> any LaunchedProcess {
@@ -387,6 +390,7 @@ final class FakeLauncher: ProcessLauncher {
             throw failure
         }
         executables.append(executableURL)
+        environments.append(environment)
         let process = FakeProcess(pid: pid_t(1000 + launched.count), arguments: arguments, outputURL: outputURL, onExit: onExit)
         launched.append(process)
         return process
PATCH
````

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCFakes.swift` :

````swift
import Foundation
@testable import PTZBotKit

/// La préparation de go2rtc simulée : le test choisit le résultat ; `holds` la retient jusqu'à `release()`.
/// Appelée hors du fil principal (Task.detached), d'où le verrou.
final class FakePreparer: Go2RTCPreparing, @unchecked Sendable {
    static let readyLaunch = Go2RTCLaunch(
        config: URL(fileURLWithPath: "/support/go2rtc.yaml"),
        ffmpegDirectory: URL(fileURLWithPath: "/opt/homebrew/bin"),
        custom: false
    )

    private let lock = NSLock()
    private var _result: Go2RTCPreparation = .ready(FakePreparer.readyLaunch)
    private var _writeResult: Go2RTCBlock?
    private var _prepared: [Go2RTCSettings] = []
    private var _written: [Go2RTCSettings] = []
    private var _onMainThread: [Bool] = []
    private var _holds = false
    private var held: CheckedContinuation<Void, Never>?

    var result: Go2RTCPreparation {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    var writeResult: Go2RTCBlock? {
        get { lock.withLock { _writeResult } }
        set { lock.withLock { _writeResult = newValue } }
    }

    var holds: Bool {
        get { lock.withLock { _holds } }
        set { lock.withLock { _holds = newValue } }
    }

    /// Les réglages de chaque préparation, dans l'ordre.
    var prepared: [Go2RTCSettings] { lock.withLock { _prepared } }
    /// Les réglages de chaque `writeConfig`.
    var written: [Go2RTCSettings] { lock.withLock { _written } }
    /// Pour chaque préparation : tournait-elle sur le fil principal ?
    var onMainThread: [Bool] { lock.withLock { _onMainThread } }
    var isHeld: Bool { lock.withLock { held != nil } }

    func prepare(_ settings: Go2RTCSettings) async -> Go2RTCPreparation {
        let onMain = pthread_main_np() != 0
        lock.withLock {
            _prepared.append(settings)
            _onMainThread.append(onMain)
        }
        if holds {
            await withCheckedContinuation { continuation in
                lock.withLock { held = continuation }
            }
        }
        return result
    }

    func writeConfig(_ settings: Go2RTCSettings) async -> Go2RTCBlock? {
        lock.withLock {
            _written.append(settings)
            return _writeResult
        }
    }

    /// Laisse finir la préparation retenue.
    func release() {
        let continuation = lock.withLock {
            let continuation = held
            held = nil
            _holds = false
            return continuation
        }
        continuation?.resume()
    }
}

/// Les ports simulés : chaque essai est noté (« 8554/tcp », « 8555/udp », « 1984/tcp/127.0.0.1 ») ; `busy` les prend.
final class FakePorts: PortProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _busy: Set<String> = []
    private var _probed: [String] = []

    static func key(_ port: Int, _ transport: PortTransport, _ loopbackOnly: Bool) -> String {
        "\(port)/\(transport == .tcp ? "tcp" : "udp")\(loopbackOnly ? "/127.0.0.1" : "")"
    }

    var probed: [String] { lock.withLock { _probed } }

    func busy(_ keys: String...) {
        lock.withLock { _busy.formUnion(keys) }
    }

    func isFree(_ port: Int, transport: PortTransport, loopbackOnly: Bool) -> Bool {
        let key = Self.key(port, transport, loopbackOnly)
        return lock.withLock {
            _probed.append(key)
            return !_busy.contains(key)
        }
    }
}

/// Les appareils simulés : par défaut, une caméra OBSBOT virtuelle avant la vraie, et le micro OBSBOT.
struct FakeCatalog: CaptureDeviceCatalog {
    var cameraList = [
        CaptureDeviceInfo(name: "OBSBOT Virtual Camera", isVirtual: true),
        CaptureDeviceInfo(name: Go2RTCFixtures.camera, isVirtual: false),
    ]
    var microphoneList = [CaptureDeviceInfo(name: Go2RTCFixtures.microphone, isVirtual: false)]

    func cameras() -> [CaptureDeviceInfo] {
        cameraList
    }

    func microphones() -> [CaptureDeviceInfo] {
        microphoneList
    }
}

extension FFmpegLocator {
    /// ffmpeg de Homebrew présent et qui répond.
    static let homebrew = FFmpegLocator(isExecutable: { $0 == Go2RTCFixtures.ffmpeg }, respondsToVersion: { _ in true })
    /// ffmpeg introuvable.
    static let missing = FFmpegLocator(isExecutable: { _ in false }, respondsToVersion: { _ in false })
}
````

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCPreparerTests.swift` :

````swift
import Foundation
import Testing
@testable import PTZBotKit

@Suite("go2rtc : préparation du lancement et ports", .french)
struct Go2RTCPreparerTests {
    private func preparer(_ directory: URL, locator: FFmpegLocator = .homebrew, catalog: FakeCatalog = FakeCatalog(),
                          ports: FakePorts = FakePorts()) -> Go2RTCPreparer {
        Go2RTCPreparer(configURL: directory.appending(path: "go2rtc.yaml"), locator: locator, catalog: catalog, ports: ports)
    }

    @Test("Prêt : yaml écrit en mode 600 (vraie caméra, pas la virtuelle), ports vérifiés, dossier de ffmpeg pour le PATH")
    func ready() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ports = FakePorts()
        let result = await preparer(directory, ports: ports).prepare(Go2RTCFixtures.settings())
        guard case let .ready(launch) = result else {
            Issue.record("attendu : prêt, reçu \(result)")
            return
        }
        let config = directory.appending(path: "go2rtc.yaml")
        #expect(launch.config == config)
        #expect(launch.ffmpegDirectory?.path == "/opt/homebrew/bin")
        #expect(!launch.custom)
        let expected = try Go2RTCConfig.yaml(settings: Go2RTCFixtures.settings(), ffmpeg: Go2RTCFixtures.ffmpeg,
                                             camera: Go2RTCFixtures.camera, microphone: Go2RTCFixtures.microphone)
        #expect(try String(contentsOf: config, encoding: .utf8) == expected)
        #expect(try Go2RTCFixtures.permissions(config) == 0o600)
        #expect(ports.probed == ["8554/tcp", "8555/tcp", "8555/udp", "1984/tcp/127.0.0.1"])
    }

    @Test("Bloqué : ffmpeg introuvable, caméra ou micro absents, nom réglé débranché ; rien n'est écrit")
    func blocked() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = Go2RTCFixtures.settings()
        #expect(await preparer(directory, locator: .missing).prepare(settings) == .blocked(.ffmpegMissing))
        #expect(await preparer(directory, catalog: FakeCatalog(cameraList: [])).prepare(settings) == .blocked(.cameraMissing))
        #expect(await preparer(directory, catalog: FakeCatalog(microphoneList: [])).prepare(settings) == .blocked(.microphoneMissing))
        var unplugged = settings
        unplugged.cameraName = "Caméra débranchée"
        #expect(await preparer(directory).prepare(unplugged) == .blocked(.cameraMissing))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "go2rtc.yaml").path))
    }

    @Test("Port pris (un autre go2rtc) : bloqué sur ce port, en TCP comme en UDP, et pour l'API")
    func portBusy() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (key, port) in [("8554/tcp", 8554), ("8555/udp", 8555), ("1984/tcp/127.0.0.1", 1984)] {
            let ports = FakePorts()
            ports.busy(key)
            #expect(await preparer(directory, ports: ports).prepare(Go2RTCFixtures.settings()) == .blocked(.portBusy(port)))
        }
    }

    @Test("Réglage refusé par le yaml : bloqué, avec le message")
    func invalidSettings() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = Go2RTCFixtures.settings()
        settings.password = ""
        let message = Go2RTCConfigError.missingCredential.localizedDescription
        #expect(await preparer(directory).prepare(settings) == .blocked(.invalidSettings(message)))
    }

    @Test("Fichier personnalisé : lancé tel quel, sans yaml écrit ni port vérifié ; introuvable : bloqué")
    func customFile() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let custom = directory.appending(path: "perso.yaml")
        try Data("api:\n".utf8).write(to: custom)
        var settings = Go2RTCFixtures.settings()
        settings.customConfigEnabled = true
        settings.customConfigPath = custom.path
        let ports = FakePorts()
        let result = await preparer(directory, catalog: FakeCatalog(cameraList: []), ports: ports).prepare(settings)
        #expect(result == .ready(Go2RTCLaunch(config: URL(fileURLWithPath: custom.path), ffmpegDirectory: URL(fileURLWithPath: Go2RTCFixtures.ffmpeg).deletingLastPathComponent(), custom: true)))
        #expect(ports.probed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "go2rtc.yaml").path))
        settings.customConfigPath = directory.appending(path: "absent.yaml").path
        #expect(await preparer(directory).prepare(settings) == .blocked(.customFileMissing))
    }

    @Test("Appliquer go2rtc éteint : yaml écrit avec l'appareil réglé, même débranché ; ffmpeg absent : bloqué")
    func writeConfig() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = Go2RTCFixtures.settings()
        settings.cameraName = "Caméra débranchée"
        #expect(await preparer(directory).writeConfig(settings) == nil)
        let text = try String(contentsOf: directory.appending(path: "go2rtc.yaml"), encoding: .utf8)
        #expect(text.contains("-i \"Caméra débranchée\""))
        #expect(await preparer(directory, locator: .missing).writeConfig(settings) == .ffmpegMissing)
        settings.customConfigEnabled = true
        #expect(await preparer(directory, locator: .missing).writeConfig(settings) == nil)
    }

    @Test("Ports réels : un port tenu par une autre socket est pris, en TCP et en UDP ; refermée, il est libre")
    func realPorts() throws {
        let probe = SystemPortProbe()
        for (type, transport) in [(SOCK_STREAM, PortTransport.tcp), (SOCK_DGRAM, .udp)] {
            let descriptor = socket(AF_INET, type, 0)
            try #require(descriptor >= 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: 0)
            let bound = withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            try #require(bound == 0)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            var assigned = sockaddr_in()
            _ = withUnsafeMutablePointer(to: &assigned) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            let port = Int(UInt16(bigEndian: assigned.sin_port))
            if type == SOCK_STREAM {
                _ = listen(descriptor, 1)
            }
            #expect(!probe.isFree(port, transport: transport, loopbackOnly: false), "\(transport)")
            #expect(!probe.isFree(port, transport: transport, loopbackOnly: true), "\(transport)")
            close(descriptor)
            #expect(probe.isFree(port, transport: transport, loopbackOnly: false), "\(transport)")
        }
    }
}
````

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCSupervisorTests.swift` :

````swift
import Foundation
import Testing
@testable import PTZBotKit

@MainActor
@Suite("Supervision de go2rtc", .french, .timeLimit(.minutes(1)))
struct Go2RTCSupervisorTests {
    let launcher = FakeLauncher()
    let settings = FakeSettings()
    let scheduler = FakeScheduler()
    let preparer = FakePreparer()
    let paths = Go2RTCSupervisor.Paths(
        gardien: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/gardien"),
        go2rtc: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/go2rtc"),
        log: URL(fileURLWithPath: "/logs/go2rtc.log")
    )

    private func makeSupervisor(enabled: Bool = true, log: URL? = nil) -> Go2RTCSupervisor {
        if enabled {
            settings.values[Go2RTCSupervisor.enabledKey] = true
        }
        var paths = paths
        if let log {
            paths.log = log
        }
        return Go2RTCSupervisor(paths: paths, launcher: launcher, preparer: preparer, settings: settings, scheduler: scheduler,
                                parentPID: 4242, configuration: Go2RTCFixtures.settings())
    }

    /// `start()`, puis la préparation attendue.
    private func started(_ supervisor: Go2RTCSupervisor) async {
        supervisor.start()
        await supervisor.waitForPreparation()
    }

    @Test("Éteint par défaut : ni préparation ni lancement")
    func offByDefault() async {
        let supervisor = makeSupervisor(enabled: false)
        #expect(!supervisor.isEnabled)
        await started(supervisor)
        #expect(supervisor.state == .stopped)
        #expect(preparer.prepared.isEmpty)
        #expect(launcher.launched.isEmpty)
    }

    @Test("Allumé : préparation hors du fil principal, puis le gardien : --parent, --arret 10, go2rtc -config, PATH de ffmpeg, journal")
    func launch() async throws {
        let supervisor = makeSupervisor(enabled: false)
        supervisor.setEnabled(true)
        #expect(supervisor.state == .starting)
        #expect(settings.values[Go2RTCSupervisor.enabledKey] == true)
        await supervisor.waitForPreparation()
        #expect(supervisor.state == .running)
        #expect(preparer.prepared == [Go2RTCFixtures.settings()])
        #expect(preparer.onMainThread == [false])
        #expect(launcher.executables == [paths.gardien])
        let process = try #require(launcher.last)
        #expect(process.arguments == ["--parent", "4242", "--arret", "10", "--", paths.go2rtc.path, "-config", "/support/go2rtc.yaml"])
        #expect(launcher.environments == [["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]])
        #expect(process.outputURL == paths.log)
        #expect(supervisor.gardienPID == process.pid)
        #expect(supervisor.launchCount == 1)
        #expect(!supervisor.usesCustomFile)
        supervisor.start()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1)
    }

    @Test("Préparation bloquée (ffmpeg introuvable, port pris) : échec avec la raison, sans lancement ni relance")
    func blocked() async {
        for block in [Go2RTCBlock.ffmpegMissing, .portBusy(8554)] {
            preparer.result = .blocked(block)
            let supervisor = makeSupervisor()
            await started(supervisor)
            #expect(supervisor.state == .failed(.blocked(block)))
            scheduler.advance(by: 60)
            #expect(launcher.launched.isEmpty)
        }
        #expect(preparer.prepared.count == 2)
    }

    @Test("Arrêt : SIGTERM au gardien ; stopped et completion à sa fin ; pas de relance")
    func stop() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        let process = try #require(launcher.last)
        var done = 0
        supervisor.stop { done += 1 }
        #expect(process.terminations == 1)
        #expect(supervisor.state == .stopped)
        #expect(supervisor.gardienPID == nil)
        #expect(done == 1)
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
        #expect(process.kills == 0)
    }

    @Test("Arrêt en douceur : le gardien laisse 10 s à go2rtc ; SIGKILL au gardien seulement à 15 s")
    func gentleStop() async throws {
        #expect(Go2RTCSupervisor.stopDelay >= 10)
        #expect(Go2RTCSupervisor.killDelay > Go2RTCSupervisor.stopDelay)
        let supervisor = makeSupervisor()
        await started(supervisor)
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        var done = 0
        supervisor.stop { done += 1 }
        scheduler.advance(by: Go2RTCSupervisor.stopDelay)
        #expect(process.kills == 0)
        scheduler.advance(by: Go2RTCSupervisor.killDelay - Go2RTCSupervisor.stopDelay - 0.1)
        #expect(process.kills == 0)
        #expect(done == 0)
        #expect(supervisor.state == .running)
        scheduler.advance(by: 0.1)
        #expect(process.kills == 1)
        #expect(done == 1)
        #expect(supervisor.state == .stopped)
    }

    @Test("Gardien qui ne sort pas même après SIGKILL : arrêt abandonné, échec, completion")
    func unkillable() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        process.ignoresKill = true
        var done = 0
        supervisor.stop { done += 1 }
        scheduler.advance(by: Go2RTCSupervisor.killDelay * 2)
        #expect(done == 1)
        #expect(supervisor.state == .failed(.unkillable))
    }

    @Test("Arrêts inattendus : relances après 1, 2, 4, 8 et 16 s ; au-delà de 5 en 120 s, échec sans relance")
    func crashLoop() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        for (index, delay) in [1.0, 2, 4, 8, 16].enumerated() {
            try #require(launcher.last).exit()
            #expect(supervisor.state == .restarting(count: index + 1))
            scheduler.advance(by: delay - 0.1)
            #expect(launcher.launched.count == index + 1)
            scheduler.advance(by: 0.1)
            await supervisor.waitForPreparation()
            #expect(launcher.launched.count == index + 2)
            #expect(supervisor.state == .running)
        }
        try #require(launcher.last).exit()
        #expect(supervisor.state == .failed(.crashLoop))
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 6)
    }

    @Test("Un go2rtc qui a tenu 120 s repart du premier délai")
    func stableResetsDelays() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        try #require(launcher.last).exit()
        scheduler.advance(by: 1)
        await supervisor.waitForPreparation()
        scheduler.advance(by: Go2RTCSupervisor.failureWindow)
        try #require(launcher.last).exit()
        #expect(supervisor.state == .restarting(count: 1))
    }

    @Test("go2rtc absent de l'app (le gardien sort avec 127) : échec sans relance")
    func missingBinary() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        try #require(launcher.last).exit(ProcessExit(status: 127, signaled: false))
        #expect(supervisor.state == .failed(.missingBinary))
        scheduler.advance(by: 60)
        #expect(launcher.launched.count == 1)
    }

    @Test("Éteint pendant la préparation : rien n'est lancé ; rallumé pendant l'arrêt : une seule relance, à la fin")
    func toggles() async throws {
        preparer.holds = true
        let supervisor = makeSupervisor()
        supervisor.start()
        let held = await waitUntil { preparer.isHeld }
        try #require(held)
        supervisor.setEnabled(false)
        #expect(supervisor.state == .stopped)
        preparer.release()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.isEmpty)
        #expect(supervisor.state == .stopped)

        supervisor.setEnabled(true)
        await supervisor.waitForPreparation()
        let process = try #require(launcher.last)
        process.ignoresTerminate = true
        supervisor.setEnabled(false)
        supervisor.setEnabled(true)
        supervisor.setEnabled(true)
        #expect(launcher.launched.count == 1)
        process.exit(ProcessExit(status: SIGTERM, signaled: true))
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
        #expect(supervisor.state == .running)
    }

    @Test("Appliquer : arrêt en douceur, puis relance avec les nouveaux réglages ; éteint, rien")
    func restart() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        var changed = Go2RTCFixtures.settings()
        changed.framerate = 25
        supervisor.configuration = changed
        supervisor.restart()
        #expect(try #require(launcher.launched.first).terminations == 1)
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
        #expect(preparer.prepared.last == changed)
        supervisor.setEnabled(false)
        supervisor.restart()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 2)
    }

    @Test("Quitter : plus de relance ni de lancement, même interrupteur rallumé")
    func quit() async throws {
        let supervisor = makeSupervisor()
        await started(supervisor)
        var done = 0
        supervisor.stop(forQuit: true) { done += 1 }
        #expect(done == 1)
        supervisor.setEnabled(true)
        supervisor.start()
        await supervisor.waitForPreparation()
        #expect(launcher.launched.count == 1)
    }

    @Test("Fichier personnalisé : lancé sur ce fichier, et l'état le sait")
    func customFile() async throws {
        preparer.result = .ready(Go2RTCLaunch(config: URL(fileURLWithPath: "/perso/go2rtc.yaml"), ffmpegDirectory: nil, custom: true))
        let supervisor = makeSupervisor()
        await started(supervisor)
        #expect(supervisor.usesCustomFile)
        #expect(try #require(launcher.last).arguments.suffix(2) == ["-config", "/perso/go2rtc.yaml"])
        #expect(launcher.environments == [["PATH": "/usr/bin:/bin"]])
    }

    @Test("Le journal : sa taille au lancement est retenue, pour n'en lire que la suite")
    func logOffset() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "go2rtc.log")
        try Data("ancien journal\n".utf8).write(to: log)
        let supervisor = makeSupervisor(log: log)
        await started(supervisor)
        #expect(supervisor.logOffsetAtLaunch == 15)
    }

    @Test("Chemins de l'app : gardien et go2rtc dans Helpers, yaml dans le dossier de PTZBot, journal à côté de ptzd.log")
    func appPaths() {
        let paths = AppPaths(bundle: URL(fileURLWithPath: "/Applications/PTZBot.app"), home: URL(fileURLWithPath: "/maison/exemple"))
        #expect(paths.go2rtcService == Go2RTCSupervisor.Paths(
            gardien: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/gardien"),
            go2rtc: URL(fileURLWithPath: "/Applications/PTZBot.app/Contents/Helpers/go2rtc"),
            log: URL(fileURLWithPath: "/maison/exemple/Library/Logs/obsbot-nacelle/go2rtc.log")
        ))
        #expect(paths.go2rtcConfig.path == "/maison/exemple/Library/Application Support/ObsbotNacelle/go2rtc.yaml")
    }

    /// Attend une condition, 5 s au plus, en laissant tourner les tâches.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while !condition() {
            guard ContinuousClock.now - start < .seconds(5) else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

@MainActor
@Suite("Lanceur réel : environnement", .french, .timeLimit(.minutes(1)))
struct ProcessLauncherEnvironmentTests {
    @Test("Les variables données remplacent celles de l'app ; les autres restent")
    func environment() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "sortie.log")
        let exit = try await withCheckedThrowingContinuation { continuation in
            do {
                _ = try FoundationProcessLauncher().launch(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", #"echo "$PATH"; test -n "$HOME" && echo maison"#],
                    environment: ["PATH": "/outils:/usr/bin:/bin"],
                    outputURL: log
                ) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(exit == ProcessExit(status: 0, signaled: false))
        #expect(try String(contentsOf: log, encoding: .utf8) == "/outils:/usr/bin:/bin\nmaison\n")
    }
}
````

Ajouter les tests de « Quitter » avec go2rtc à `AppControllerTests.swift` :

````bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift b/mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift
index db47565..9a5c064 100644
--- a/mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift
+++ b/mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift
@@ -13,6 +13,9 @@ struct AppControllerTests {
     let launchctl = FakeLaunchctl()
     let toolchain = FakeToolchain()
     let supervisor: ServiceSupervisor
+    /// go2rtc a son propre lanceur : les lancements de ptzd restent seuls dans `launcher`.
+    let go2rtcLauncher = FakeLauncher()
+    let go2rtcSettings = FakeSettings()
 
     init() throws {
         root = try FakeSDK.directory()
@@ -37,10 +40,12 @@ struct AppControllerTests {
         sdkLoads: Bool = true,
         confirm: Bool = true,
         asked: Counter = Counter(),
-        answers: Answers? = nil
+        answers: Answers? = nil,
+        go2rtc: Go2RTCSupervisor? = nil
     ) -> AppController {
         AppController(
             supervisor: supervisor,
+            go2rtc: go2rtc,
             legacyAgent: LegacyAgent(
                 launchAgentsDirectory: root.appending(path: "LaunchAgents"),
                 supportDirectory: paths.support,
@@ -370,6 +375,77 @@ struct AppControllerTests {
     }
 }
 
+/// go2rtc dans l'app (spec B3 § 3.3) : lancé au démarrage s'il est allumé, attendu par « Quitter ».
+extension AppControllerTests {
+    private func go2rtc(enabled: Bool) -> Go2RTCSupervisor {
+        go2rtcSettings.values[Go2RTCSupervisor.enabledKey] = enabled
+        return Go2RTCSupervisor(paths: paths.go2rtcService, launcher: go2rtcLauncher, preparer: FakePreparer(), settings: go2rtcSettings,
+                                scheduler: scheduler, parentPID: 4242, configuration: Go2RTCFixtures.settings())
+    }
+
+    @Test("Au lancement : go2rtc allumé démarre, avec ptzd ; éteint, il ne démarre pas")
+    func go2rtcAtLaunch() async throws {
+        defer { try? FileManager.default.removeItem(at: root) }
+        let on = go2rtc(enabled: true)
+        let app = controller(go2rtc: on)
+        await app.launch()
+        await on.waitForPreparation()
+        #expect(on.state == .running)
+        #expect(go2rtcLauncher.executables == [paths.gardien])
+        #expect(launcher.executables == [paths.ptzd])
+        #expect(app.quitStopsCamera)
+        let off = go2rtc(enabled: false)
+        let other = controller(go2rtc: off)
+        await other.launch()
+        await off.waitForPreparation()
+        #expect(off.state == .stopped)
+        #expect(!other.quitStopsCamera)
+    }
+
+    @Test("« Quitter » : ptzd et go2rtc arrêtés ; completion quand les deux sont sortis, une seule fois")
+    func quitWaitsForGo2RTC() async throws {
+        defer { try? FileManager.default.removeItem(at: root) }
+        let camera = go2rtc(enabled: true)
+        let app = controller(go2rtc: camera)
+        await app.launch()
+        await camera.waitForPreparation()
+        let gardien = try #require(go2rtcLauncher.last)
+        gardien.ignoresTerminate = true
+        var done = 0
+        app.quit { done += 1 }
+        #expect(try #require(launcher.last).terminations == 1)
+        #expect(gardien.terminations == 1)
+        #expect(done == 0, "ptzd est sorti, go2rtc pas encore")
+        scheduler.advance(by: Go2RTCSupervisor.stopDelay)
+        #expect(done == 0)
+        gardien.exit(ProcessExit(status: SIGTERM, signaled: true))
+        #expect(done == 1)
+        scheduler.advance(by: AppController.go2rtcQuitTimeout)
+        #expect(done == 1)
+        #expect(go2rtcLauncher.launched.count == 1)
+    }
+
+    @Test("« Quitter » avec un gardien qui ne sort pas : completion au délai de sécurité de go2rtc (16 s)")
+    func quitGo2RTCTimeout() async throws {
+        defer { try? FileManager.default.removeItem(at: root) }
+        let camera = go2rtc(enabled: true)
+        let app = controller(go2rtc: camera)
+        await app.launch()
+        await camera.waitForPreparation()
+        let gardien = try #require(go2rtcLauncher.last)
+        gardien.ignoresTerminate = true
+        gardien.ignoresKill = true
+        var done = 0
+        app.quit { done += 1 }
+        #expect(app.quitDelay == AppController.go2rtcQuitTimeout)
+        scheduler.advance(by: AppController.go2rtcQuitTimeout - 0.1)
+        #expect(gardien.kills == 1)
+        #expect(done == 0)
+        scheduler.advance(by: 0.1)
+        #expect(done == 1)
+    }
+}
+
 /// Réponses successives à l'alerte de migration.
 @MainActor
 final class Answers {
PATCH
````

- [x] **Étape 2 : Lancer les tests, constater l'échec**

Run : `(cd mac/app/PTZBotKit && swift test)`
Attendu : échec de compilation : « type 'FakeLauncher' does not conform to protocol 'ProcessLauncher' », « cannot find 'Go2RTCSupervisor' in scope ».

- [x] **Étape 3 : Écrire le lanceur, les ports, la préparation, le superviseur, les chemins et « Quitter »**

Le lanceur passe des variables d'environnement :

````bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/ProcessLauncher.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/ProcessLauncher.swift
index e8e186f..6fbc802 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/ProcessLauncher.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/ProcessLauncher.swift
@@ -27,15 +27,29 @@ public protocol LaunchedProcess: AnyObject {
 /// Lance un processus, sa sortie et ses erreurs ajoutées à un fichier ; derrière un protocole pour les tests.
 @MainActor
 public protocol ProcessLauncher: AnyObject {
-    /// `onExit` est appelé une fois, sur le MainActor, quand le processus se termine.
+    /// `onExit` est appelé une fois, sur le MainActor, quand le processus se termine. `environment` : les variables
+    /// posées ou remplacées sur celles de l'app (vide : l'environnement de l'app, tel quel).
     func launch(
         executableURL: URL,
         arguments: [String],
+        environment: [String: String],
         outputURL: URL,
         onExit: @escaping @MainActor (ProcessExit) -> Void
     ) throws -> any LaunchedProcess
 }
 
+extension ProcessLauncher {
+    /// Sans variable de plus : l'environnement de l'app (ptzd).
+    public func launch(
+        executableURL: URL,
+        arguments: [String],
+        outputURL: URL,
+        onExit: @escaping @MainActor (ProcessExit) -> Void
+    ) throws -> any LaunchedProcess {
+        try launch(executableURL: executableURL, arguments: arguments, environment: [:], outputURL: outputURL, onExit: onExit)
+    }
+}
+
 /// Implémentation réelle, sur `Process`.
 @MainActor
 public final class FoundationProcessLauncher: ProcessLauncher {
@@ -44,12 +58,16 @@ public final class FoundationProcessLauncher: ProcessLauncher {
     public func launch(
         executableURL: URL,
         arguments: [String],
+        environment: [String: String],
         outputURL: URL,
         onExit: @escaping @MainActor (ProcessExit) -> Void
     ) throws -> any LaunchedProcess {
         let process = Process()
         process.executableURL = executableURL
         process.arguments = arguments
+        if !environment.isEmpty {
+            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
+        }
         let output = try Self.appendingHandle(outputURL)
         // Le processus ne lit jamais l'entrée standard de l'app.
         process.standardInput = FileHandle.nullDevice
PATCH
````

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/PortProbe.swift` :

````swift
import Foundation

public enum PortTransport: Sendable {
    case tcp
    case udp
}

/// Un port est-il libre ? (Spec B3 § 5 : essai d'ouverture juste avant le lancement.) Derrière un protocole pour les
/// tests.
public protocol PortProbe: Sendable {
    /// `loopbackOnly` : 127.0.0.1 seulement (l'API de go2rtc) ; sinon toutes les adresses, IPv4 et IPv6.
    func isFree(_ port: Int, transport: PortTransport, loopbackOnly: Bool) -> Bool
}

/// Le vrai essai : une socket ouverte sans `SO_REUSEADDR`, refusée si un autre programme tient déjà le port, et
/// refermée aussitôt.
public struct SystemPortProbe: PortProbe {
    public init() {}

    public func isFree(_ port: Int, transport: PortTransport, loopbackOnly: Bool) -> Bool {
        let type = transport == .tcp ? SOCK_STREAM : SOCK_DGRAM
        if loopbackOnly {
            return Self.bindIPv4(port, type: type, address: 0x7F00_0001)
        }
        return Self.bindIPv4(port, type: type, address: 0) && Self.bindIPv6(port, type: type)
    }

    static func bindIPv4(_ port: Int, type: Int32, address: UInt32) -> Bool {
        let descriptor = socket(AF_INET, type, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = in_port_t(UInt16(port).bigEndian)
        socketAddress.sin_addr = in_addr(s_addr: address.bigEndian)
        return withUnsafePointer(to: socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// En IPv6 seul (`IPV6_V6ONLY`) : l'IPv4 est essayé à part. Sans IPv6 sur le Mac, rien à vérifier de ce côté.
    static func bindIPv6(_ port: Int, type: Int32) -> Bool {
        let descriptor = socket(AF_INET6, type, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        var only: Int32 = 1
        _ = setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
        var socketAddress = sockaddr_in6()
        socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        socketAddress.sin6_family = sa_family_t(AF_INET6)
        socketAddress.sin6_port = in_port_t(UInt16(port).bigEndian)
        socketAddress.sin6_addr = in6_addr()
        return withUnsafePointer(to: socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }
}
````

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCPreparer.swift` :

````swift
import Foundation

/// Ce qui empêche de lancer go2rtc (spec B3 § 5) ; la ligne d'état le dit.
public enum Go2RTCBlock: Error, Equatable, Sendable {
    case ffmpegMissing
    case cameraMissing
    case microphoneMissing
    /// Le port est déjà tenu : un autre go2rtc tourne sans doute.
    case portBusy(Int)
    case customFileMissing
    /// Un réglage que le yaml refuse (`Go2RTCConfigError`), en clair.
    case invalidSettings(String)
    case writeFailed(String)
}

/// De quoi lancer go2rtc.
public struct Go2RTCLaunch: Equatable, Sendable {
    public var config: URL
    /// Le dossier de ffmpeg, en tête du PATH de go2rtc (nil : fichier personnalisé, ffmpeg introuvable).
    public var ffmpegDirectory: URL?
    /// Un fichier personnalisé : ni ports ni appareils vérifiés.
    public var custom: Bool

    public init(config: URL, ffmpegDirectory: URL?, custom: Bool) {
        self.config = config
        self.ffmpegDirectory = ffmpegDirectory
        self.custom = custom
    }
}

public enum Go2RTCPreparation: Equatable, Sendable {
    case ready(Go2RTCLaunch)
    case blocked(Go2RTCBlock)
}

/// Prépare chaque lancement de go2rtc : ffmpeg, appareils, yaml, ports. Bloquant (`ffmpeg -version`, fichiers,
/// sockets) : le superviseur l'appelle hors du fil de l'interface.
public protocol Go2RTCPreparing: Sendable {
    func prepare(_ settings: Go2RTCSettings) async -> Go2RTCPreparation
    /// Écrit le yaml sans rien lancer (« Appliquer » go2rtc éteint) : les appareils réglés n'ont pas besoin d'être
    /// branchés. nil : c'est fait (ou fichier personnalisé : rien à écrire).
    func writeConfig(_ settings: Go2RTCSettings) async -> Go2RTCBlock?
}

public final class Go2RTCPreparer: Go2RTCPreparing {
    public let configURL: URL
    private let locator: FFmpegLocator
    private let catalog: any CaptureDeviceCatalog
    private let ports: any PortProbe

    public init(configURL: URL, locator: FFmpegLocator, catalog: any CaptureDeviceCatalog, ports: any PortProbe) {
        self.configURL = configURL
        self.locator = locator
        self.catalog = catalog
        self.ports = ports
    }

    /// Le préparateur de l'app : `go2rtc.yaml` de l'utilisateur, vrais appareils, vrai ffmpeg, vrais ports.
    public static func system(paths: AppPaths) -> Go2RTCPreparer {
        Go2RTCPreparer(configURL: paths.go2rtcConfig, locator: .system(), catalog: AVFoundationDeviceCatalog(), ports: SystemPortProbe())
    }

    /// Fichier personnalisé : lancé tel quel s'il se lit. Sinon : ffmpeg, appareils branchés, yaml (réécrit s'il a
    /// changé), puis les ports RTSP (TCP), WebRTC (TCP et UDP) et l'API (127.0.0.1:1984).
    public func prepare(_ settings: Go2RTCSettings) async -> Go2RTCPreparation {
        if settings.customConfigEnabled {
            guard let path = settings.customConfigPath, FileManager.default.isReadableFile(atPath: path) else {
                return .blocked(.customFileMissing)
            }
            let ffmpeg = locator.locate(configured: settings.ffmpegPath)
            return .ready(Go2RTCLaunch(config: URL(fileURLWithPath: path), ffmpegDirectory: ffmpeg?.deletingLastPathComponent(), custom: true))
        }
        let ffmpeg: URL
        switch generate(settings, requirePresence: true) {
        case let .failure(block): return .blocked(block)
        case let .success(found): ffmpeg = found
        }
        let checks: [(Int, PortTransport, Bool)] = [
            (settings.rtspPort, .tcp, false), (settings.webrtcPort, .tcp, false), (settings.webrtcPort, .udp, false),
            (Go2RTCSettings.apiPort, .tcp, true),
        ]
        for (port, transport, loopbackOnly) in checks where !ports.isFree(port, transport: transport, loopbackOnly: loopbackOnly) {
            return .blocked(.portBusy(port))
        }
        return .ready(Go2RTCLaunch(config: configURL, ffmpegDirectory: ffmpeg.deletingLastPathComponent(), custom: false))
    }

    public func writeConfig(_ settings: Go2RTCSettings) async -> Go2RTCBlock? {
        guard !settings.customConfigEnabled else { return nil }
        if case let .failure(block) = generate(settings, requirePresence: false) {
            return block
        }
        return nil
    }

    /// ffmpeg, les noms des appareils, puis le yaml, écrit s'il a changé. Rend le chemin de ffmpeg. Sans
    /// `requirePresence`, un appareil réglé est écrit même débranché.
    private func generate(_ settings: Go2RTCSettings, requirePresence: Bool) -> Result<URL, Go2RTCBlock> {
        guard let ffmpeg = locator.locate(configured: settings.ffmpegPath) else { return .failure(.ffmpegMissing) }
        let cameras = catalog.cameras()
        let microphones = catalog.microphones()
        let camera = requirePresence
            ? CaptureDeviceChoice.resolve(configured: settings.cameraName, in: cameras)
            : settings.cameraName ?? CaptureDeviceChoice.preferred(in: cameras)
        let microphone = requirePresence
            ? CaptureDeviceChoice.resolve(configured: settings.microphoneName, in: microphones)
            : settings.microphoneName ?? CaptureDeviceChoice.preferred(in: microphones)
        guard let camera else { return .failure(.cameraMissing) }
        guard let microphone else { return .failure(.microphoneMissing) }
        let text: String
        do {
            text = try Go2RTCConfig.yaml(settings: settings, ffmpeg: ffmpeg.path, camera: camera, microphone: microphone)
        } catch {
            return .failure(.invalidSettings(error.localizedDescription))
        }
        do {
            try Go2RTCConfigFile.write(text, to: configURL)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
        return .success(ffmpeg)
    }
}
````

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCSupervisor.swift` :

````swift
import Foundation
import Observation

/// Pourquoi go2rtc ne tourne pas (spec B3 § 5).
public enum Go2RTCFailure: Equatable, Sendable {
    /// La préparation l'a empêché : ffmpeg, appareil, port, yaml.
    case blocked(Go2RTCBlock)
    /// Plus de `maxUnexpectedExits` arrêts inattendus en `failureWindow` secondes.
    case crashLoop
    /// Le gardien n'a pas pu être lancé.
    case launch(String)
    /// Le gardien n'a pas trouvé go2rtc dans l'app (code 127).
    case missingBinary
    /// Le gardien ne sort pas, même après SIGKILL.
    case unkillable
}

/// Lance go2rtc, processus enfant de l'app par le gardien (spec B3 § 3.2 et § 3.3), le relance s'il s'arrête et
/// l'arrête en douceur. Sur le modèle de `ServiceSupervisor` (ptzd), avec une préparation avant chaque lancement.
/// Éteint par défaut : il ne doit pas prendre la caméra de quelqu'un qui a déjà son go2rtc.
@MainActor
@Observable
public final class Go2RTCSupervisor {
    public enum State: Equatable, Sendable {
        case stopped
        /// Préparation (ffmpeg, appareils, yaml, ports), puis lancement.
        case starting
        case running
        /// Arrêt inattendu ; relance prévue (n-ième relance de suite).
        case restarting(count: Int)
        case failed(Go2RTCFailure)
    }

    /// Ce que le superviseur lance.
    public struct Paths: Equatable, Sendable {
        public var gardien: URL
        public var go2rtc: URL
        /// Le journal : la sortie et les erreurs du gardien et de go2rtc y sont ajoutées.
        public var log: URL

        public init(gardien: URL, go2rtc: URL, log: URL) {
            self.gardien = gardien
            self.go2rtc = go2rtc
            self.log = log
        }
    }

    /// Délais de relance successifs ; le dernier se répète.
    public static let restartDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    /// Au-delà de `maxUnexpectedExits` arrêts inattendus en `failureWindow` secondes : `failed(.crashLoop)`.
    public static let maxUnexpectedExits = 5
    /// Un go2rtc qui a tenu `failureWindow` secondes repart du premier délai.
    public static let failureWindow: TimeInterval = 120
    /// Le délai que le gardien laisse à go2rtc entre SIGTERM et SIGKILL (`--arret`) : go2rtc arrête ses ffmpeg par
    /// SIGTERM (`killsignal=15`), jamais un ffmpeg qui capture par SIGKILL.
    public static let stopDelay: TimeInterval = 10
    /// Le gardien lui-même ne reçoit SIGKILL qu'après ce délai, une fois son propre arrêt de go2rtc écoulé.
    public static let killDelay: TimeInterval = 15
    public static let enabledKey = "go2rtcEnabled"
    /// Code de sortie du gardien quand go2rtc n'a pas pu être lancé.
    public static let missingBinaryStatus: Int32 = 127

    public private(set) var state: State = .stopped
    /// L'interrupteur « go2rtc », retenu d'un lancement à l'autre ; éteint par défaut.
    public private(set) var isEnabled: Bool
    /// Le go2rtc en cours tourne sur un fichier personnalisé.
    public private(set) var usesCustomFile = false
    /// Le pid du gardien en cours : go2rtc et ses ffmpeg en descendent (détecteur de coreaudiod).
    public private(set) var gardienPID: pid_t?
    /// Le nombre de lancements : la surveillance du journal repart de zéro à chaque nouveau go2rtc.
    public private(set) var launchCount = 0
    /// La taille du journal au dernier lancement : la surveillance n'en lit que la suite.
    public private(set) var logOffsetAtLaunch: UInt64 = 0
    /// Les réglages du prochain lancement ; « Appliquer » les remplace (`Go2RTCSettingsModel`).
    public var configuration: Go2RTCSettings

    @ObservationIgnored private let paths: Paths
    @ObservationIgnored private let launcher: any ProcessLauncher
    @ObservationIgnored private let preparer: any Go2RTCPreparing
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private let parentPID: pid_t
    @ObservationIgnored private var process: (any LaunchedProcess)?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var launchedAt: TimeInterval = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restartCount = 0
    @ObservationIgnored private var unexpectedExits: [TimeInterval] = []
    @ObservationIgnored private var pendingRestart: (any Cancellable)?
    @ObservationIgnored private var pendingKill: (any Cancellable)?
    @ObservationIgnored private var pendingWatchdog: (any Cancellable)?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var restartAfterStop = false
    @ObservationIgnored private var quitting = false
    @ObservationIgnored private var stopCompletions: [@MainActor () -> Void] = []

    public init(
        paths: Paths,
        launcher: any ProcessLauncher,
        preparer: any Go2RTCPreparing,
        settings: any SettingsStore,
        scheduler: any Scheduler,
        parentPID: pid_t,
        configuration: Go2RTCSettings
    ) {
        self.paths = paths
        self.launcher = launcher
        self.preparer = preparer
        self.settings = settings
        self.scheduler = scheduler
        self.parentPID = parentPID
        self.configuration = configuration
        isEnabled = settings.bool(forKey: Self.enabledKey) ?? false
    }

    /// Le superviseur de l'app : vrai lanceur, préférences de l'utilisateur, PID de l'app, réglages retenus.
    public static func system(paths: AppPaths, preparer: any Go2RTCPreparing, scheduler: any Scheduler) -> Go2RTCSupervisor {
        let store = UserDefaultsSettingsStore(defaults: .standard)
        return Go2RTCSupervisor(
            paths: paths.go2rtcService,
            launcher: FoundationProcessLauncher(),
            preparer: preparer,
            settings: store,
            scheduler: scheduler,
            parentPID: getpid(),
            configuration: Go2RTCSettings.restore(from: store, config: paths.go2rtcConfig)
        )
    }

    /// `gardien --parent <PTZBot> --arret 10 -- go2rtc -config <yaml>` (spec B3 § 3.2).
    public func arguments(config: URL) -> [String] {
        ["--parent", String(parentPID), "--arret", String(Int(Self.stopDelay)), "--", paths.go2rtc.path, "-config", config.path]
    }

    /// Le PATH de go2rtc : le dossier de ffmpeg d'abord, puis `/usr/bin:/bin` (la source `ffmpeg:obsbot#audio=opus`
    /// lance `ffmpeg` par son nom).
    public static func environment(ffmpegDirectory: URL?) -> [String: String] {
        ["PATH": ((ffmpegDirectory.map { [$0.path] } ?? []) + ["/usr/bin", "/bin"]).joined(separator: ":")]
    }

    /// Lance go2rtc s'il est autorisé et ne tourne pas déjà. Depuis `failed`, repart de zéro.
    public func start() {
        guard isEnabled, !stopping, !quitting else { return }
        switch state {
        case .stopped, .failed:
            restartCount = 0
            unexpectedExits = []
            launch()
        case .starting, .running, .restarting:
            break
        }
    }

    /// SIGTERM au gardien, qui le transmet à go2rtc et laisse `stopDelay` secondes ; SIGKILL au gardien après
    /// `killDelay` s'il vit encore. `completion` quand il est sorti. Une préparation en cours est abandonnée.
    /// `forQuit` : l'app se termine, go2rtc ne sera plus relancé.
    public func stop(forQuit: Bool = false, completion: @escaping @MainActor () -> Void = {}) {
        if forQuit {
            quitting = true
        }
        restartAfterStop = false
        pendingRestart?.cancel()
        pendingRestart = nil
        guard let process else {
            // Le numéro change : une préparation en cours ne lancera rien.
            generation += 1
            state = .stopped
            completion()
            return
        }
        stopCompletions.append(completion)
        guard !stopping else { return }
        stopping = true
        process.terminate()
        pendingKill = scheduler.schedule(after: Self.killDelay) { [weak self] in
            guard let self, let process = self.process else { return }
            pendingKill = nil
            armWatchdog()
            process.kill()
        }
    }

    /// L'interrupteur « go2rtc » : retenu, puis go2rtc lancé ou arrêté.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        settings.set(enabled, forKey: Self.enabledKey)
        if enabled {
            if stopping {
                restartAfterStop = !quitting
            } else {
                start()
            }
        } else {
            stop()
        }
    }

    /// « Appliquer » : go2rtc s'arrête en douceur, puis repart sur `configuration`.
    public func restart() {
        guard isEnabled, !quitting else { return }
        if stopping {
            restartAfterStop = true
            return
        }
        stop { [weak self] in
            self?.start()
        }
    }

    /// Attend la fin de la préparation en cours (tests).
    public func waitForPreparation() async {
        await preparation?.value
    }

    // MARK: - Processus

    private func launch() {
        state = .starting
        // Chaque lancement a son numéro : une préparation ou une fin d'un lancement déjà remplacé est ignorée.
        generation += 1
        let launchedGeneration = generation
        let settings = configuration
        let preparer = preparer
        preparation = Task { [weak self] in
            let result = await Task.detached { await preparer.prepare(settings) }.value
            self?.prepared(result, generation: launchedGeneration)
        }
    }

    private func prepared(_ result: Go2RTCPreparation, generation launchedGeneration: Int) {
        guard launchedGeneration == generation, state == .starting, isEnabled, !stopping, !quitting else { return }
        switch result {
        case let .blocked(block):
            state = .failed(.blocked(block))
        case let .ready(launch):
            spawn(launch, generation: launchedGeneration)
        }
    }

    private func spawn(_ launch: Go2RTCLaunch, generation launchedGeneration: Int) {
        logOffsetAtLaunch = Self.size(of: paths.log)
        let launched: any LaunchedProcess
        do {
            launched = try launcher.launch(
                executableURL: paths.gardien,
                arguments: arguments(config: launch.config),
                environment: Self.environment(ffmpegDirectory: launch.ffmpegDirectory),
                outputURL: paths.log
            ) { [weak self] exit in
                guard let self, launchedGeneration == generation, process != nil else { return }
                exited(exit)
            }
        } catch {
            state = .failed(.launch(error.localizedDescription))
            return
        }
        process = launched
        gardienPID = launched.pid
        usesCustomFile = launch.custom
        launchCount += 1
        launchedAt = scheduler.now
        state = .running
    }

    private func exited(_ exit: ProcessExit) {
        process = nil
        gardienPID = nil
        pendingKill?.cancel()
        pendingKill = nil
        pendingWatchdog?.cancel()
        pendingWatchdog = nil
        if stopping {
            stopping = false
            state = .stopped
            let completions = stopCompletions
            stopCompletions = []
            completions.forEach { $0() }
            if restartAfterStop {
                restartAfterStop = false
                start()
            }
            return
        }
        if !exit.signaled, exit.status == Self.missingBinaryStatus {
            state = .failed(.missingBinary)
            return
        }
        unexpectedExit()
    }

    private func unexpectedExit() {
        let now = scheduler.now
        if now - launchedAt >= Self.failureWindow {
            // go2rtc a tenu : les délais repartent du premier.
            restartCount = 0
        }
        unexpectedExits = unexpectedExits.filter { now - $0 < Self.failureWindow } + [now]
        guard unexpectedExits.count <= Self.maxUnexpectedExits else {
            state = .failed(.crashLoop)
            return
        }
        restartCount += 1
        state = .restarting(count: restartCount)
        pendingRestart = scheduler.schedule(after: Self.restartDelays[min(restartCount, Self.restartDelays.count) - 1]) { [weak self] in
            guard let self else { return }
            pendingRestart = nil
            guard case .restarting = state else { return }
            guard isEnabled else {
                state = .stopped
                return
            }
            launch()
        }
    }

    /// Après SIGKILL, le gardien doit sortir dans `killDelay` ; sinon l'arrêt est abandonné.
    private func armWatchdog() {
        let killedGeneration = generation
        pendingWatchdog = scheduler.schedule(after: Self.killDelay) { [weak self] in
            guard let self, self.generation == killedGeneration, process != nil else { return }
            pendingWatchdog = nil
            process = nil
            gardienPID = nil
            stopping = false
            restartAfterStop = false
            state = .failed(.unkillable)
            let completions = stopCompletions
            stopCompletions = []
            completions.forEach { $0() }
        }
    }

    /// La taille d'un fichier, 0 s'il n'existe pas.
    static func size(of url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
````

Les chemins de go2rtc :

````bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift
index 2306b77..3bafe3c 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift
@@ -70,6 +70,31 @@ public struct AppPaths: Equatable, Sendable {
     public var service: ServiceSupervisor.Paths {
         ServiceSupervisor.Paths(ptzd: ptzd, ai: obsbotAI, sdkDirectory: sdkDirectory, log: ptzdLog)
     }
+
+    /// go2rtc 1.9.14, le binaire officiel (spec B3 § 3.1).
+    public var go2rtc: URL {
+        helpers.appending(path: "go2rtc")
+    }
+
+    /// Le gardien qui lance go2rtc et l'arrête si PTZBot disparaît (spec B3 § 3.2).
+    public var gardien: URL {
+        helpers.appending(path: "gardien")
+    }
+
+    /// Le yaml que PTZBot écrit pour go2rtc (mode 600 : il porte le mot de passe RTSP).
+    public var go2rtcConfig: URL {
+        support.appending(path: Go2RTCConfig.fileName)
+    }
+
+    /// Le journal de go2rtc et de son gardien, à côté de `ptzd.log`.
+    public var go2rtcLog: URL {
+        logs.appending(path: "go2rtc.log")
+    }
+
+    /// Ce que le superviseur de go2rtc lance.
+    public var go2rtcService: Go2RTCSupervisor.Paths {
+        Go2RTCSupervisor.Paths(gardien: gardien, go2rtc: go2rtc, log: go2rtcLog)
+    }
 }
 
 extension SDKInstaller {
PATCH
````

Le contrôleur lance go2rtc au démarrage et l'attend en quittant :

````bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift b/mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift
index 34330a0..9a6c1f9 100644
--- a/mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift
+++ b/mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift
@@ -1,9 +1,9 @@
 import Foundation
 import Observation
 
-/// Le lancement et l'arrêt de l'app autour de ptzd (spec ptzd dans l'app § 5.3, § 5.5 et § 5.6) :
-/// ancienne installation détectée et remplacée après confirmation, `config.json` créé au besoin,
-/// supervision de ptzd, état du SDK, « Quitter » qui attend ptzd.
+/// Le lancement et l'arrêt de l'app autour de ptzd (spec ptzd dans l'app § 5.3, § 5.5 et § 5.6) et de go2rtc (spec B3
+/// § 3.3) : ancienne installation détectée et remplacée après confirmation, `config.json` créé au besoin,
+/// supervision de ptzd et de go2rtc, état du SDK, « Quitter » qui attend ptzd et go2rtc.
 @MainActor
 @Observable
 public final class AppController {
@@ -18,6 +18,8 @@ public final class AppController {
 
     /// « Quitter » attend ptzd 5 s au plus (le superviseur envoie SIGKILL à 5 s) ; marge de sécurité.
     public static let quitTimeout: TimeInterval = 6
+    /// Avec go2rtc : son gardien reçoit SIGKILL à 15 s au plus tard ; marge de sécurité.
+    public static let go2rtcQuitTimeout: TimeInterval = Go2RTCSupervisor.killDelay + 1
 
     public private(set) var legacy: Legacy = .checking
     public private(set) var migrationError: String?
@@ -32,6 +34,8 @@ public final class AppController {
     public private(set) var tailscaleMissing = false
     public private(set) var configError: String?
     public let supervisor: ServiceSupervisor
+    /// go2rtc, processus enfant de l'app (spec B3) ; nil dans les tests qui ne s'en occupent pas.
+    public let go2rtc: Go2RTCSupervisor?
 
     @ObservationIgnored private let legacyAgent: LegacyAgent
     @ObservationIgnored private let configURL: URL
@@ -47,6 +51,7 @@ public final class AppController {
 
     public init(
         supervisor: ServiceSupervisor,
+        go2rtc: Go2RTCSupervisor? = nil,
         legacyAgent: LegacyAgent,
         configURL: URL,
         interfaces: any InterfaceAddressProvider,
@@ -55,6 +60,7 @@ public final class AppController {
         confirmMigration: @escaping @MainActor () async -> Bool
     ) {
         self.supervisor = supervisor
+        self.go2rtc = go2rtc
         self.legacyAgent = legacyAgent
         self.configURL = configURL
         self.interfaces = interfaces
@@ -68,6 +74,8 @@ public final class AppController {
     public func launch() async {
         guard !launched else { return }
         launched = true
+        // go2rtc ne dépend ni de ptzd ni de l'ancienne installation : il démarre tout de suite s'il est allumé.
+        go2rtc?.start()
         let agent = legacyAgent
         let found = await Task.detached { agent.detect() }.value
         if found {
@@ -160,11 +168,24 @@ public final class AppController {
         Task.detached { toolchain.requestInstall() }
     }
 
-    /// Arrête ptzd (SIGTERM, puis SIGKILL à 5 s), puis `completion`, une seule fois, au plus tard après `quitTimeout`.
+    /// « Quitter » arrête aussi la caméra HomeKit : la confirmation le dit quand go2rtc est allumé (spec B3 § 3.3).
+    public var quitStopsCamera: Bool {
+        go2rtc?.isEnabled == true
+    }
+
+    /// Le délai de sécurité de « Quitter » : celui de ptzd, ou celui de go2rtc quand l'app le supervise.
+    public var quitDelay: TimeInterval {
+        go2rtc == nil ? Self.quitTimeout : Self.go2rtcQuitTimeout
+    }
+
+    /// Arrête ptzd (SIGTERM, puis SIGKILL à 5 s) et go2rtc (SIGTERM, que le gardien transmet ; 10 s pour sortir),
+    /// puis `completion`, une seule fois, quand les deux sont sortis, au plus tard après `quitDelay`.
     public func quit(completion: @escaping @MainActor () -> Void) {
         let once = Once(completion)
-        supervisor.stop(forQuit: true) { once.run() }
-        scheduler.schedule(after: Self.quitTimeout) { once.run() }
+        let remaining = Countdown(go2rtc == nil ? 1 : 2) { once.run() }
+        supervisor.stop(forQuit: true) { remaining.done() }
+        go2rtc?.stop(forQuit: true) { remaining.done() }
+        scheduler.schedule(after: quitDelay) { once.run() }
     }
 
     private func startService() async {
@@ -195,6 +216,25 @@ private struct BootstrapFailure: Error {
     var reason: String
 }
 
+/// Une action exécutée quand `count` tâches ont fini.
+@MainActor
+private final class Countdown {
+    private var count: Int
+    private let action: @MainActor () -> Void
+
+    init(_ count: Int, action: @escaping @MainActor () -> Void) {
+        self.count = count
+        self.action = action
+    }
+
+    func done() {
+        count -= 1
+        if count == 0 {
+            action()
+        }
+    }
+}
+
 /// Une action exécutée une seule fois.
 @MainActor
 private final class Once {
PATCH
````

- [x] **Étape 4 : Lancer les tests, constater la réussite**

Run : `(cd mac/app/PTZBotKit && swift build --build-tests 2>&1 | grep -E "warning|error" ; swift test)`
Attendu : aucun avertissement ; `Test run with 347 tests in 27 suites passed`. Les tests existants de ptzd et de « Quitter » sans go2rtc passent sans changement (`quitTimeout` reste 6 s).

- [x] **Étape 5 : Commit**

```bash
git add mac/app/PTZBotKit/Sources/PTZBotKit/ProcessLauncher.swift mac/app/PTZBotKit/Sources/PTZBotKit/PortProbe.swift \
  mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCPreparer.swift mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCSupervisor.swift \
  mac/app/PTZBotKit/Sources/PTZBotKit/AppPaths.swift mac/app/PTZBotKit/Sources/PTZBotKit/AppController.swift \
  mac/app/PTZBotKit/Tests/PTZBotKitTests/Fakes.swift mac/app/PTZBotKit/Tests/PTZBotKitTests/AppControllerTests.swift \
  mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCFakes.swift mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCPreparerTests.swift \
  mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCSupervisorTests.swift
git commit -F - <<'MSG'
go2rtc : superviseur (gardien, PATH de ffmpeg, relances, arrêt en douceur sur 10 s), préparation et ports ; Quitter l'attend

<ligne Co-Authored-By du modèle>
MSG
```

---

### Tâche 6 : API de go2rtc, coreaudiod et refus d'accès

**But :** ce que le panneau montre de go2rtc (spec § 5). La lecture de `GET http://127.0.0.1:1984/api/streams` : les clients du stream `obsbot` par type (sans le préchargement, qui n'en est pas un) et la présence d'un producteur actif (sinon : caméra absente). Le détecteur de coreaudiod : plus d'un ffmpeg vidéo sous le gardien (`ps`), ou un `exec: timeout` dans le journal depuis moins de 2 min. Le refus d'accès, repéré dans `go2rtc.log`. La surveillance (`Go2RTCMonitor`) relit le journal toutes les 10 s tant que go2rtc tourne, depuis son dernier lancement seulement ; l'API et les processus, toutes les 2 s, **seulement pendant que le panneau est ouvert**.

**Si la tâche 0 a relevé une ligne de refus** (dans `resultat.txt`, phase B) que `Go2RTCLogPatterns.scan` ne reconnaît pas : ajouter à `logPatterns` un `#expect` sur cette ligne réelle (adresses et chemins remplacés par des fictifs), le voir échouer, puis ajouter le motif qui la reconnaît à `Go2RTCLogPatterns.accessDenied`, en minuscules.

**Fichiers :**
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCStreams.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCHealth.swift`
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCMonitor.swift`
- Tester : `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCMonitorTests.swift` (avec `FakeGo2RTCAPI`, `FakeProcessListing` et des réponses de l'API de la forme de go2rtc 1.9.14)

**Interfaces :**
- Consomme : `Go2RTCSupervisor` (`state`, `gardienPID`, `launchCount`, `logOffsetAtLaunch`), `Go2RTCSettings.streamName`, `AppPaths.go2rtcLog`, `ChildProcess.run`, `Scheduler` ; dans les tests : `FakePreparer`, `FakeLauncher`, `FakeScheduler`, `Go2RTCFixtures`.
- Produit :
  - `Go2RTCClients(byType:)`, `total` ; `Go2RTCStreamStatus(clients:hasActiveProducer:)` ; `Go2RTCStreams.status(of:in:) -> Go2RTCStreamStatus?` ;
  - protocole `Go2RTCAPI: Sendable` (`streams() async throws -> Data`) ; `URLSessionGo2RTCAPI` ;
  - `CoreAudioDetector.timeoutWindow` (120), `.repairCommand` (« sudo killall -9 coreaudiod »), `.videoFFmpegCount(psOutput:root:)`, `.isStuck(videoFFmpegs:lastTimeout:now:)` ;
  - `Go2RTCLogScan(sawTimeout:sawAccessDenied:)`, `Go2RTCLogPatterns.scan(_:)`, `Go2RTCLogReader(url:offset:)` (`readNew(maxBytes:)`, `reset(to:)`) ;
  - protocole `ProcessListing: Sendable` (`psOutput()`), `SystemProcessListing` ;
  - `Go2RTCHealth(accessDenied:coreAudioStuck:cameraMissing:)` ;
  - `Go2RTCMonitor` (`@MainActor @Observable`) : `pollInterval` (2), `logScanInterval` (10), `stream`, `health`, `init(supervisor:api:processes:logURL:scheduler:)`, `system(supervisor:paths:scheduler:)`, `start()`, `beginWatching()`, `endWatching()`, `scanLog()`, `refresh() async`, `waitForPoll() async`.

- [x] **Étape 1 : Écrire les tests**

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCMonitorTests.swift` :

````swift
import Foundation
import Testing
@testable import PTZBotKit

/// L'API de go2rtc simulée : le corps rendu, ou une erreur.
final class FakeGo2RTCAPI: Go2RTCAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _body: Data?
    private var _calls = 0

    /// nil : l'API ne répond pas.
    var body: Data? {
        get { lock.withLock { _body } }
        set { lock.withLock { _body = newValue } }
    }

    var calls: Int { lock.withLock { _calls } }

    func streams() async throws -> Data {
        let body = lock.withLock {
            _calls += 1
            return _body
        }
        guard let body else { throw URLError(.cannotConnectToHost) }
        return body
    }
}

/// La liste des processus simulée.
final class FakeProcessListing: ProcessListing, @unchecked Sendable {
    private let lock = NSLock()
    private var _output: String?

    var output: String? {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
    }

    func psOutput() -> String? {
        output
    }
}

/// Des réponses de `GET /api/streams` de la forme de go2rtc 1.9.14 (relevée le 12/10 sur un go2rtc en service, valeurs
/// remplacées par des fictives).
enum StreamsFixtures {
    static let active = Data(#"""
    {"obsbot":{
      "producers":[
        {"id":1,"format_name":"rtsp","protocol":"rtsp+tcp","source":"exec:…","medias":["video, recvonly, H264"],"receivers":[{}],"bytes_recv":1200},
        {"id":2,"format_name":"rtsp","protocol":"rtsp+tcp","source":"exec:…","medias":["audio, recvonly, MPEG4-GENERIC/48000/2"],"receivers":[{}],"bytes_recv":300},
        {"url":"ffmpeg:obsbot#audio=opus"}],
      "consumers":[
        {"id":3,"format_name":"preload","medias":["video, sendonly, ANY"],"senders":[{}],"bytes_send":0},
        {"id":4,"format_name":"rtsp","protocol":"rtsp+tcp","remote_addr":"192.168.0.10:50000","medias":[],"senders":[],"bytes_send":10},
        {"id":5,"format_name":"webrtc","protocol":"udp","medias":[],"senders":[],"bytes_send":10},
        {"id":6,"format_name":"rtsp","protocol":"rtsp+tcp","medias":[],"senders":[],"bytes_send":10}]
    }}
    """#.utf8)

    /// La caméra débranchée : les producteurs exec ne reçoivent plus rien, seul le préchargement reste.
    static let noProducer = Data(#"""
    {"obsbot":{"producers":[{"url":"exec:…"},{"url":"exec:…"},{"url":"ffmpeg:obsbot#audio=opus"}],
     "consumers":[{"id":3,"format_name":"preload","medias":[],"senders":[],"bytes_send":0}]}}
    """#.utf8)
}

@Suite("go2rtc : API, coreaudiod et journal", .french)
struct Go2RTCSignalsTests {
    @Test("Clients par type, sans le préchargement ; producteur actif")
    func clients() throws {
        let status = try #require(Go2RTCStreams.status(of: "obsbot", in: StreamsFixtures.active))
        #expect(status.clients == Go2RTCClients(byType: ["rtsp": 2, "webrtc": 1]))
        #expect(status.clients.total == 3)
        #expect(status.hasActiveProducer)
    }

    @Test("Stream sans producteur actif : la caméra est absente ; stream absent ou réponse illisible : nil")
    func noProducer() throws {
        let status = try #require(Go2RTCStreams.status(of: "obsbot", in: StreamsFixtures.noProducer))
        #expect(!status.hasActiveProducer)
        #expect(status.clients.total == 0)
        #expect(Go2RTCStreams.status(of: "autre", in: StreamsFixtures.active) == nil)
        #expect(Go2RTCStreams.status(of: "obsbot", in: Data("pas du json".utf8)) == nil)
    }

    /// pid, ppid, commande : le gardien 500, son go2rtc 501, deux ffmpeg vidéo, un audio, le transcodeur Opus, et un ffmpeg
    /// vidéo d'un autre programme (900).
    static let ps = """
      1     0 /sbin/launchd
    400     1 /Applications/PTZBot.app/Contents/MacOS/PTZBot
    500   400 /Applications/PTZBot.app/Contents/Helpers/gardien --parent 400 --arret 10 -- /Applications/PTZBot.app/Contents/Helpers/go2rtc -config /support/go2rtc.yaml
    501   500 /Applications/PTZBot.app/Contents/Helpers/go2rtc -config /support/go2rtc.yaml
    502   501 /opt/homebrew/bin/ffmpeg -hide_banner -f avfoundation -framerate 30 -i OBSBOT Tiny 2 StreamCamera -an -f rtsp rtsp://127.0.0.1:8554/a
    503   501 /opt/homebrew/bin/ffmpeg -hide_banner -f avfoundation -i :OBSBOT Tiny2 Microphone -vn -f rtsp rtsp://127.0.0.1:8554/b
    504   501 ffmpeg -hide_banner -i rtsp://127.0.0.1:8554/obsbot -c:a libopus -f rtsp rtsp://127.0.0.1:8554/c
    505   501 /opt/homebrew/bin/ffmpeg -hide_banner -f avfoundation -framerate 30 -i OBSBOT Tiny 2 StreamCamera -an -f rtsp rtsp://127.0.0.1:8554/a
    900     1 /usr/local/bin/ffmpeg -f avfoundation -i 0 sortie.mp4
    """

    @Test("coreaudiod : les ffmpeg vidéo comptés sous le gardien seulement ; plus d'un : bloqué")
    func videoFFmpegs() {
        #expect(CoreAudioDetector.videoFFmpegCount(psOutput: Self.ps, root: 500) == 2)
        let healthy = Self.ps.split(separator: "\n").filter { !$0.hasPrefix("505 ") }.joined(separator: "\n")
        #expect(CoreAudioDetector.videoFFmpegCount(psOutput: healthy, root: 500) == 1)
        #expect(CoreAudioDetector.videoFFmpegCount(psOutput: Self.ps, root: 999) == 0)
        #expect(CoreAudioDetector.isStuck(videoFFmpegs: 2, lastTimeout: nil, now: 0))
        #expect(!CoreAudioDetector.isStuck(videoFFmpegs: 1, lastTimeout: nil, now: 0))
    }

    @Test("coreaudiod : un exec: timeout de moins de 2 min suffit ; plus vieux, non")
    func timeoutWindow() {
        #expect(CoreAudioDetector.isStuck(videoFFmpegs: 1, lastTimeout: 100, now: 219))
        #expect(!CoreAudioDetector.isStuck(videoFFmpegs: 1, lastTimeout: 100, now: 220))
        #expect(CoreAudioDetector.repairCommand == "sudo killall -9 coreaudiod")
    }

    @Test("Journal : exec: timeout et refus d'accès d'avfoundation reconnus ; le reste ignoré")
    func logPatterns() {
        #expect(Go2RTCLogPatterns.scan("12:00:01.000 ERR [exec] timeout source=exec:…\n") == Go2RTCLogScan(sawTimeout: true))
        #expect(Go2RTCLogPatterns.scan(#"WRN [streams] error="exec: timeout""#) == Go2RTCLogScan(sawTimeout: true))
        let denied = #"WRN [streams] error="exec/rtsp\n[avfoundation @ 0x1] Failed to create AV capture input device: Cannot use OBSBOT""#
        #expect(Go2RTCLogPatterns.scan(denied) == Go2RTCLogScan(sawAccessDenied: true))
        #expect(Go2RTCLogPatterns.scan("ERR [rtsp] wrong user/pass denied") == Go2RTCLogScan())
        #expect(Go2RTCLogPatterns.scan("INF [api] listen addr=127.0.0.1:1984\n") == Go2RTCLogScan())
    }

    @Test("Lecteur du journal : seulement la suite ; au plus les derniers octets ; journal raccourci relu du début")
    func logReader() throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "go2rtc.log")
        try Data("ancien\n".utf8).write(to: url)
        var reader = Go2RTCLogReader(url: url, offset: 7)
        #expect(reader.readNew() == "")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("nouveau\n".utf8))
        try handle.close()
        #expect(reader.readNew() == "nouveau\n")
        #expect(reader.readNew() == "")
        try Data("court\n".utf8).write(to: url)
        #expect(reader.readNew() == "court\n")
        try Data("0123456789".utf8).write(to: url)
        reader.reset(to: 0)
        #expect(reader.readNew(maxBytes: 4) == "6789")
        #expect(Go2RTCLogReader(url: directory.appending(path: "absent.log")).offset == 0)
    }
}

@MainActor
@Suite("go2rtc : surveillance pour le panneau", .french, .timeLimit(.minutes(1)))
struct Go2RTCMonitorTests {
    let launcher = FakeLauncher()
    let settings = FakeSettings()
    let scheduler = FakeScheduler()
    let api = FakeGo2RTCAPI()
    let processes = FakeProcessListing()

    /// Un go2rtc qui tourne (gardien simulé de pid 1000), son journal dans `directory`.
    private func running(_ directory: URL) async -> (Go2RTCSupervisor, Go2RTCMonitor, URL) {
        let log = directory.appending(path: "go2rtc.log")
        settings.values[Go2RTCSupervisor.enabledKey] = true
        let supervisor = Go2RTCSupervisor(
            paths: Go2RTCSupervisor.Paths(gardien: URL(fileURLWithPath: "/app/gardien"), go2rtc: URL(fileURLWithPath: "/app/go2rtc"), log: log),
            launcher: launcher, preparer: FakePreparer(), settings: settings, scheduler: scheduler, parentPID: 4242,
            configuration: Go2RTCFixtures.settings()
        )
        supervisor.start()
        await supervisor.waitForPreparation()
        let monitor = Go2RTCMonitor(supervisor: supervisor, api: api, processes: processes, logURL: log, scheduler: scheduler)
        return (supervisor, monitor, log)
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test("Panneau ouvert : clients et producteur lus dans l'API ; un seul ffmpeg vidéo : pas d'alerte")
    func clients() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, _) = await running(directory)
        api.body = StreamsFixtures.active
        processes.output = "1000 1 gardien\n1001 1000 go2rtc\n1002 1001 /opt/homebrew/bin/ffmpeg -f avfoundation -i Cam -an\n"
        monitor.beginWatching()
        await monitor.waitForPoll()
        #expect(monitor.stream?.clients.total == 3)
        #expect(monitor.health == Go2RTCHealth())
    }

    @Test("Deux ffmpeg vidéo : coreaudiod bloqué ; caméra sans producteur : absente")
    func alerts() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, _) = await running(directory)
        api.body = StreamsFixtures.noProducer
        processes.output = "1000 1 g\n1001 1000 go2rtc\n1002 1001 ffmpeg -f avfoundation -an\n1003 1001 ffmpeg -f avfoundation -an\n"
        await monitor.refresh()
        #expect(monitor.health == Go2RTCHealth(coreAudioStuck: true, cameraMissing: true))
    }

    @Test("Journal : un refus d'accès écrit après le lancement est vu ; avant, non ; un nouveau go2rtc l'efface")
    func accessDenied() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "go2rtc.log")
        try append("[avfoundation] not authorized (exec, avant le lancement)\n", to: log)
        let (supervisor, monitor, _) = await running(directory)
        monitor.scanLog()
        #expect(!monitor.health.accessDenied)
        try append(#"WRN error="exec/rtsp [avfoundation @ 0x1] Failed to create AV capture input device""# + "\n", to: log)
        monitor.scanLog()
        #expect(monitor.health.accessDenied)
        supervisor.restart()
        await supervisor.waitForPreparation()
        monitor.scanLog()
        #expect(!monitor.health.accessDenied)
    }

    @Test("exec: timeout : alerte coreaudiod 2 min, puis plus rien ; relu toutes les 10 s sans panneau")
    func timeout() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, monitor, log) = await running(directory)
        monitor.start()
        try append("ERR [exec] timeout source=exec:…\n", to: log)
        scheduler.advance(by: Go2RTCMonitor.logScanInterval)
        #expect(monitor.health.coreAudioStuck)
        scheduler.advance(by: CoreAudioDetector.timeoutWindow)
        #expect(!monitor.health.coreAudioStuck)
    }

    @Test("Panneau fermé : plus de lecture de l'API ; go2rtc arrêté : ni clients ni alerte")
    func endWatching() async throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (supervisor, monitor, _) = await running(directory)
        api.body = StreamsFixtures.active
        monitor.beginWatching()
        await monitor.waitForPoll()
        #expect(api.calls == 1)
        scheduler.advance(by: Go2RTCMonitor.pollInterval)
        await monitor.waitForPoll()
        #expect(api.calls == 2)
        monitor.endWatching()
        scheduler.advance(by: Go2RTCMonitor.pollInterval * 3)
        await monitor.waitForPoll()
        #expect(api.calls == 2)
        supervisor.stop()
        await monitor.refresh()
        #expect(monitor.stream == nil)
        #expect(monitor.health == Go2RTCHealth())
    }
}
````

- [x] **Étape 2 : Lancer les tests, constater l'échec**

Run : `(cd mac/app/PTZBotKit && swift test)`
Attendu : échec de compilation, « cannot find type 'Go2RTCAPI' in scope ».

- [x] **Étape 3 : Écrire la lecture de l'API, les détecteurs et la surveillance**

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCStreams.swift` :

````swift
import Foundation

/// Les clients d'un stream de go2rtc, par type (`format_name` : « rtsp », « webrtc »…), sans le préchargement
/// (« preload »), qui n'est pas un client.
public struct Go2RTCClients: Equatable, Sendable {
    public var byType: [String: Int]

    public init(byType: [String: Int] = [:]) {
        self.byType = byType
    }

    public var total: Int {
        byType.values.reduce(0, +)
    }
}

/// L'état d'un stream lu dans l'API.
public struct Go2RTCStreamStatus: Equatable, Sendable {
    public var clients: Go2RTCClients
    /// Au moins un producteur reçoit des données (un ffmpeg qui capture) ; sinon la caméra est absente ou refusée.
    public var hasActiveProducer: Bool

    public init(clients: Go2RTCClients, hasActiveProducer: Bool) {
        self.clients = clients
        self.hasActiveProducer = hasActiveProducer
    }
}

/// La réponse de `GET /api/streams` de go2rtc 1.9.14 : `{ "<stream>": { "producers": […], "consumers": […] } }`. Un
/// producteur actif porte `bytes_recv` et `medias` ; un producteur au repos (la source `ffmpeg:…#audio=opus` tant que
/// personne ne la demande) n'a que son `url`.
public enum Go2RTCStreams {
    /// nil : réponse illisible, ou stream absent.
    public static func status(of stream: String, in data: Data) -> Go2RTCStreamStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[stream] as? [String: Any] else { return nil }
        var byType: [String: Int] = [:]
        for consumer in entry["consumers"] as? [[String: Any]] ?? [] {
            let type = consumer["format_name"] as? String ?? ""
            guard type != "preload" else { continue }
            byType[type, default: 0] += 1
        }
        let active = (entry["producers"] as? [[String: Any]] ?? []).contains { producer in
            (producer["bytes_recv"] as? Int ?? 0) > 0 || !(producer["medias"] as? [Any] ?? []).isEmpty
        }
        return Go2RTCStreamStatus(clients: Go2RTCClients(byType: byType), hasActiveProducer: active)
    }
}

/// L'API locale de go2rtc, derrière un protocole pour les tests.
public protocol Go2RTCAPI: Sendable {
    /// Le corps de `GET /api/streams`.
    func streams() async throws -> Data
}

/// La vraie API, sur 127.0.0.1:1984 (fixe : spec B3 § 4).
public struct URLSessionGo2RTCAPI: Go2RTCAPI {
    public static let url = URL(string: "http://127.0.0.1:\(Go2RTCSettings.apiPort)/api/streams")!

    public init() {}

    public func streams() async throws -> Data {
        var request = URLRequest(url: Self.url, timeoutInterval: 1.5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
````

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCHealth.swift` :

````swift
import Foundation

/// Le blocage de coreaudiod (spec B3 § 5) : plus d'un ffmpeg vidéo sous go2rtc, ou un `exec: timeout` dans le journal
/// depuis moins de 2 min. PTZBot ne le répare jamais lui-même (il faudrait les droits root) : il donne la commande.
public enum CoreAudioDetector {
    public static let timeoutWindow: TimeInterval = 120
    public static let repairCommand = "sudo killall -9 coreaudiod"

    /// Une ligne de `ps -A -ww -o pid=,ppid=,command=`.
    struct Entry {
        var pid: pid_t
        var parent: pid_t
        var command: String
    }

    static func entries(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { return nil }
            return Entry(pid: pid, parent: parent, command: fields[2].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Les ffmpeg vidéo (avfoundation, sans `-vn`) parmi les descendants de `root`, le gardien : ceux de go2rtc
    /// seulement, pas ceux d'un autre programme.
    public static func videoFFmpegCount(psOutput: String, root: pid_t) -> Int {
        let all = entries(psOutput)
        var descendants: Set<pid_t> = [root]
        var grew = true
        while grew {
            grew = false
            for entry in all where !descendants.contains(entry.pid) && descendants.contains(entry.parent) {
                descendants.insert(entry.pid)
                grew = true
            }
        }
        return all.filter { entry in
            guard entry.pid != root, descendants.contains(entry.pid) else { return false }
            let program = entry.command.split(separator: " ").first.map(String.init) ?? ""
            return (program as NSString).lastPathComponent == "ffmpeg" && entry.command.contains("avfoundation")
                && !entry.command.contains(" -vn")
        }.count
    }

    public static func isStuck(videoFFmpegs: Int, lastTimeout: TimeInterval?, now: TimeInterval) -> Bool {
        if videoFFmpegs > 1 {
            return true
        }
        guard let lastTimeout else { return false }
        return now - lastTimeout < timeoutWindow
    }
}

/// Ce qu'une lecture du journal de go2rtc a trouvé.
public struct Go2RTCLogScan: Equatable, Sendable {
    public var sawTimeout = false
    public var sawAccessDenied = false

    public init(sawTimeout: Bool = false, sawAccessDenied: Bool = false) {
        self.sawTimeout = sawTimeout
        self.sawAccessDenied = sawAccessDenied
    }
}

/// Les lignes du journal de go2rtc que PTZBot reconnaît (spec B3 § 5).
public enum Go2RTCLogPatterns {
    /// go2rtc 1.9.14 : `[exec] timeout` dans le journal, `exec: timeout` dans l'erreur rendue.
    static let timeout = ["[exec] timeout", "exec: timeout"]
    /// ffmpeg refusé par macOS (avfoundation), tel que go2rtc le rapporte : `exec/rtsp` suivi de la sortie d'ffmpeg.
    static let accessDenied = ["not authorized", "denied", "failed to create av capture input device"]

    public static func scan(_ text: String) -> Go2RTCLogScan {
        var result = Go2RTCLogScan()
        for line in text.split(separator: "\n") {
            if timeout.contains(where: { line.contains($0) }) {
                result.sawTimeout = true
            }
            let lowered = line.lowercased()
            if lowered.contains("avfoundation") || lowered.contains("exec"),
               accessDenied.contains(where: { lowered.contains($0) }) {
                result.sawAccessDenied = true
            }
        }
        return result
    }
}

/// Lit la suite d'un journal depuis un point donné, sans jamais tout relire.
public struct Go2RTCLogReader: Sendable {
    public let url: URL
    public private(set) var offset: UInt64

    public init(url: URL, offset: UInt64 = 0) {
        self.url = url
        self.offset = offset
    }

    public mutating func reset(to offset: UInt64) {
        self.offset = offset
    }

    /// Ce qui a été ajouté depuis la dernière lecture : au plus les `maxBytes` derniers octets. Un journal raccourci
    /// (remplacé) se relit du début.
    public mutating func readNew(maxBytes: Int = 256 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < offset {
            offset = 0
        }
        let start = max(offset, end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
        guard (try? handle.seek(toOffset: start)) != nil else { return "" }
        let data = (try? handle.readToEnd()) ?? Data()
        offset = start + UInt64(data.count)
        return String(decoding: data, as: UTF8.self)
    }
}

/// La liste des processus, derrière un protocole pour les tests. Bloquant : hors du fil de l'interface.
public protocol ProcessListing: Sendable {
    /// `ps -A -ww -o pid=,ppid=,command=` ; nil si ps échoue.
    func psOutput() -> String?
}

public struct SystemProcessListing: ProcessListing {
    public init() {}

    public func psOutput() -> String? {
        guard let result = ChildProcess.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-A", "-ww", "-o", "pid=,ppid=,command="],
                                            timeout: 5, captureOutput: true),
              result.exited, result.status == 0 else { return nil }
        return result.output
    }
}

/// Les alertes de go2rtc pour le panneau.
public struct Go2RTCHealth: Equatable, Sendable {
    public var accessDenied = false
    public var coreAudioStuck = false
    public var cameraMissing = false

    public init(accessDenied: Bool = false, coreAudioStuck: Bool = false, cameraMissing: Bool = false) {
        self.accessDenied = accessDenied
        self.coreAudioStuck = coreAudioStuck
        self.cameraMissing = cameraMissing
    }
}
````

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCMonitor.swift` :

````swift
import Foundation
import Observation

/// La surveillance de go2rtc (spec B3 § 5) : le journal, relu toutes les 10 s tant que go2rtc tourne (refus d'accès,
/// `exec: timeout`) ; et, seulement pendant que le panneau est ouvert, l'API (clients, producteur) et les processus
/// (ffmpeg vidéo en trop), toutes les 2 s.
@MainActor
@Observable
public final class Go2RTCMonitor {
    public static let pollInterval: TimeInterval = 2
    public static let logScanInterval: TimeInterval = 10

    /// Le stream `obsbot` lu dans l'API ; nil hors lecture, API muette ou stream absent.
    public private(set) var stream: Go2RTCStreamStatus?
    public private(set) var health = Go2RTCHealth()

    @ObservationIgnored private let supervisor: Go2RTCSupervisor
    @ObservationIgnored private let api: any Go2RTCAPI
    @ObservationIgnored private let processes: any ProcessListing
    @ObservationIgnored private let scheduler: any Scheduler
    @ObservationIgnored private var reader: Go2RTCLogReader
    @ObservationIgnored private var seenLaunch = 0
    @ObservationIgnored private var lastTimeout: TimeInterval?
    @ObservationIgnored private var videoFFmpegs = 0
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var poll: (any Cancellable)?
    @ObservationIgnored private var polling: Task<Void, Never>?

    public init(supervisor: Go2RTCSupervisor, api: any Go2RTCAPI, processes: any ProcessListing, logURL: URL, scheduler: any Scheduler) {
        self.supervisor = supervisor
        self.api = api
        self.processes = processes
        self.scheduler = scheduler
        reader = Go2RTCLogReader(url: logURL)
    }

    public static func system(supervisor: Go2RTCSupervisor, paths: AppPaths, scheduler: any Scheduler) -> Go2RTCMonitor {
        Go2RTCMonitor(supervisor: supervisor, api: URLSessionGo2RTCAPI(), processes: SystemProcessListing(), logURL: paths.go2rtcLog,
                      scheduler: scheduler)
    }

    /// Au lancement de l'app : le journal est relu toutes les 10 s, pour toute la vie de l'app.
    public func start() {
        guard !started else { return }
        started = true
        scheduleLogScan()
    }

    /// Panneau ouvert : une lecture tout de suite, puis toutes les 2 s.
    public func beginWatching() {
        guard !watching else { return }
        watching = true
        polling = Task { [weak self] in
            await self?.refresh()
            self?.scheduleNextPoll()
        }
    }

    /// Panneau fermé : plus de lecture de l'API ni des processus.
    public func endWatching() {
        watching = false
        poll?.cancel()
        poll = nil
    }

    /// Attend la lecture en cours (tests).
    public func waitForPoll() async {
        await polling?.value
    }

    /// Le journal depuis le dernier lancement de go2rtc : un nouveau go2rtc efface les alertes du précédent.
    public func scanLog() {
        guard supervisor.state == .running else {
            update()
            return
        }
        if supervisor.launchCount != seenLaunch {
            seenLaunch = supervisor.launchCount
            reader.reset(to: supervisor.logOffsetAtLaunch)
            health.accessDenied = false
            lastTimeout = nil
        }
        let scan = Go2RTCLogPatterns.scan(reader.readNew())
        if scan.sawTimeout {
            lastTimeout = scheduler.now
        }
        if scan.sawAccessDenied {
            health.accessDenied = true
        }
        update()
    }

    /// Une lecture du journal, de l'API et des processus.
    public func refresh() async {
        scanLog()
        guard supervisor.state == .running, let root = supervisor.gardienPID else {
            stream = nil
            videoFFmpegs = 0
            update()
            return
        }
        let api = api
        let processes = processes
        let body = try? await api.streams()
        let output = await Task.detached { processes.psOutput() }.value
        // go2rtc a pu s'arrêter pendant la lecture.
        guard supervisor.state == .running else { return }
        stream = body.flatMap { Go2RTCStreams.status(of: Go2RTCSettings.streamName, in: $0) }
        videoFFmpegs = output.map { CoreAudioDetector.videoFFmpegCount(psOutput: $0, root: root) } ?? 0
        update()
    }

    private func update() {
        let running = supervisor.state == .running
        health.coreAudioStuck = running && CoreAudioDetector.isStuck(videoFFmpegs: videoFFmpegs, lastTimeout: lastTimeout, now: scheduler.now)
        health.cameraMissing = running && stream?.hasActiveProducer == false
        if !running {
            health.accessDenied = false
            stream = nil
        }
    }

    private func scheduleNextPoll() {
        guard watching else { return }
        poll = scheduler.schedule(after: Self.pollInterval) { [weak self] in
            guard let self, watching else { return }
            polling = Task { [weak self] in
                await self?.refresh()
                self?.scheduleNextPoll()
            }
        }
    }

    private func scheduleLogScan() {
        scheduler.schedule(after: Self.logScanInterval) { [weak self] in
            guard let self else { return }
            scanLog()
            scheduleLogScan()
        }
    }
}
````

- [x] **Étape 4 : Lancer les tests, constater la réussite**

Run : `(cd mac/app/PTZBotKit && swift build --build-tests 2>&1 | grep -E "warning|error" ; swift test)`
Attendu : aucun avertissement ; `Test run with 358 tests in 29 suites passed`.

- [x] **Étape 5 : Commit**

```bash
git add mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCStreams.swift mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCHealth.swift \
  mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCMonitor.swift mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCMonitorTests.swift
git commit -F - <<'MSG'
go2rtc : clients par l'API, détecteur de coreaudiod, refus d'accès dans le journal, surveillance pour le panneau

<ligne Co-Authored-By du modèle>
MSG
```

---

### Tâche 7 : le panneau (rangée go2rtc, pastilles, confirmation de « Quitter »)

**But :** spec § 6.1 et § 5. Dans la section « Service », juste après ptzd, une rangée **go2rtc** : interrupteur, pastille, ligne d'état hors état normal, et le détail des clients au survol (`help`). **Pastilles pour tous les services** (ptzd, go2rtc, Talkback, SDK OBSBOT) : verte à l'état normal, sans ligne ; sinon la ligne d'état, orange pour ce qui demande l'attention, rouge pour un échec. Alerte orange de coreaudiod avec « Copier la commande de réparation » ; refus d'accès avec le bouton des réglages de confidentialité (caméra) ; journal de go2rtc proposé en cas d'échec. « Quitter », go2rtc allumé, demande confirmation : « Quitter PTZBot arrête aussi la caméra HomeKit. » La logique des pastilles est dans PTZBotKit, testée ; les vues restent minces.

**Fichiers :**
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceIndicator.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings` (18 textes)
- Tester : `mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceIndicatorTests.swift`
- Modifier : `mac/app/PTZBot/PanelView.swift`
- Modifier : `mac/app/PTZBot/PTZBotApp.swift`
- Modifier : `mac/app/PTZBot/Localizable.xcstrings` (2 textes)

**Interfaces :**
- Consomme : `Go2RTCSupervisor` et `AppController.go2rtc`, `quitStopsCamera` (tâche 5) ; `Go2RTCMonitor`, `Go2RTCHealth`, `Go2RTCStreamStatus`, `CoreAudioDetector.repairCommand` (tâche 6) ; `Go2RTCBlock`, `Go2RTCFailure` (tâche 5) ; `Labels.service`, `Labels.talkbackStatus`, `Labels.sdk` (existants).
- Produit :
  - `ServiceIndicator(tone:line:)`, `ServiceIndicator.Tone` (`.normal`, `.neutral`, `.attention`, `.failure`), `ServiceIndicator.normal` ;
  - `Labels.ptzdIndicator(_:connection:legacy:)`, `talkbackIndicator(_:)`, `sdkIndicator(_:)`, `go2rtcIndicator(_:isEnabled:usesCustomFile:health:)`, `go2rtcBlock(_:)`, `go2rtcFailure(_:)`, `go2rtcHelp(_:)`, `go2rtcClientsDetail(_:)`, `coreAudioStuck`, `cameraAccessDenied`, `customConfigFile`, `quitStopsCamera` ;
  - dans l'app : `AppDelegate.go2rtc`, `AppDelegate.go2rtcMonitor`, `QuitConfirmation.ask()`, `LogOpener.openGo2RTCLog()`, `PrivacySettings.openCamera()`, `ServiceIndicator.Tone.color`.

- [x] **Étape 1 : Écrire les tests des pastilles**

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceIndicatorTests.swift` :

````swift
import Foundation
import Testing
@testable import PTZBotKit

/// Les pastilles du panneau (spec B3 § 6.1) : l'état normal de chaque service est une pastille verte, sans ligne ; toute
/// autre situation a sa ligne d'état.
@Suite("Pastilles des services", .french)
struct ServiceIndicatorTests {
    @Test("ptzd : actif et connecté, pastille verte sans ligne ; sinon la ligne, la raison d'un échec en rouge")
    func ptzd() {
        #expect(Labels.ptzdIndicator(.running, connection: .active, legacy: false) == .normal)
        #expect(Labels.ptzdIndicator(.running, connection: .unreachable, legacy: false) == ServiceIndicator(tone: .attention, line: "Ne répond pas"))
        #expect(Labels.ptzdIndicator(.running, connection: .connecting, legacy: false) == ServiceIndicator(tone: .neutral, line: "Démarrage…"))
        #expect(Labels.ptzdIndicator(.stopped, connection: .unreachable, legacy: false) == ServiceIndicator(tone: .neutral, line: "Arrêté"))
        #expect(Labels.ptzdIndicator(.restarting(count: 2), connection: .unreachable, legacy: false)
            == ServiceIndicator(tone: .attention, line: "Relancé après un arrêt inattendu (2)"))
        #expect(Labels.ptzdIndicator(.failed(reason: "raison"), connection: .unreachable, legacy: false) == ServiceIndicator(tone: .failure, line: "raison"))
        #expect(Labels.ptzdIndicator(.stopped, connection: .active, legacy: true) == ServiceIndicator(tone: .attention, line: "Ancienne installation"))
    }

    @Test("Talkback : prêt ou en lecture, pastille verte ; éteint, gris ; à autoriser ou arrêté, orange")
    func talkback() {
        #expect(Labels.talkbackIndicator(.ready) == .normal)
        #expect(Labels.talkbackIndicator(.playing) == .normal)
        #expect(Labels.talkbackIndicator(.disabled) == ServiceIndicator(tone: .neutral, line: "Désactivé"))
        #expect(Labels.talkbackIndicator(.requiresApproval) == ServiceIndicator(tone: .attention, line: "Autorisation requise"))
        #expect(Labels.talkbackIndicator(.notRunning).tone == .attention)
    }

    @Test("SDK OBSBOT : prêt, pastille verte ; sinon son état court")
    func sdk() {
        #expect(Labels.sdkIndicator(.ready) == .normal)
        #expect(Labels.sdkIndicator(nil) == ServiceIndicator(tone: .neutral, line: "Vérification…"))
        #expect(Labels.sdkIndicator(.absent) == ServiceIndicator(tone: .attention, line: "Absent"))
    }

    @Test("go2rtc : actif sans alerte, pastille verte sans ligne ; fichier personnalisé : pastille verte et sa ligne")
    func go2rtcNormal() {
        #expect(Labels.go2rtcIndicator(.running, isEnabled: true, usesCustomFile: false, health: Go2RTCHealth()) == .normal)
        #expect(Labels.go2rtcIndicator(.running, isEnabled: true, usesCustomFile: true, health: Go2RTCHealth())
            == ServiceIndicator(tone: .normal, line: "Fichier de configuration personnalisé"))
    }

    @Test("go2rtc : éteint, démarrage, relance, et chaque panne de la spec avec sa ligne")
    func go2rtcStates() {
        func line(_ state: Go2RTCSupervisor.State, enabled: Bool = true, health: Go2RTCHealth = Go2RTCHealth()) -> ServiceIndicator {
            Labels.go2rtcIndicator(state, isEnabled: enabled, usesCustomFile: false, health: health)
        }
        #expect(line(.stopped, enabled: false) == ServiceIndicator(tone: .neutral, line: "Désactivé"))
        #expect(line(.starting) == ServiceIndicator(tone: .neutral, line: "Démarrage…"))
        #expect(line(.restarting(count: 3)) == ServiceIndicator(tone: .attention, line: "Relancé après un arrêt inattendu (3)"))
        #expect(line(.failed(.blocked(.ffmpegMissing))) == ServiceIndicator(tone: .attention, line: "ffmpeg introuvable"))
        #expect(line(.failed(.blocked(.portBusy(8554))))
            == ServiceIndicator(tone: .attention, line: "Port 8554 déjà utilisé : un autre go2rtc tourne-t-il ?"))
        #expect(line(.failed(.blocked(.cameraMissing))) == ServiceIndicator(tone: .attention, line: "Caméra OBSBOT absente"))
        #expect(line(.failed(.crashLoop)) == ServiceIndicator(tone: .failure, line: "go2rtc s'arrête sans cesse : ouvrez le journal"))
        #expect(line(.failed(.missingBinary)).tone == .failure)
        #expect(line(.running, health: Go2RTCHealth(cameraMissing: true)) == ServiceIndicator(tone: .attention, line: "Caméra OBSBOT absente"))
        #expect(line(.running, health: Go2RTCHealth(accessDenied: true, cameraMissing: true))
            == ServiceIndicator(tone: .attention, line: "Accès à la caméra refusé"))
        #expect(line(.running, health: Go2RTCHealth(accessDenied: true, coreAudioStuck: true))
            == ServiceIndicator(tone: .attention, line: "coreaudiod ne répond pas : la caméra est bloquée"))
    }

    @Test("Survol : aucun client, un client, plusieurs avec le détail par protocole ; sans lecture, rien")
    func help() {
        #expect(Labels.go2rtcHelp(nil) == nil)
        #expect(Labels.go2rtcHelp(Go2RTCStreamStatus(clients: Go2RTCClients(), hasActiveProducer: true)) == "Aucun client")
        #expect(Labels.go2rtcHelp(Go2RTCStreamStatus(clients: Go2RTCClients(byType: ["rtsp": 1]), hasActiveProducer: true)) == "1 client · RTSP ×1")
        let mixed = Go2RTCClients(byType: ["webrtc": 1, "rtsp": 2, "zz": 1, "": 1])
        #expect(Labels.go2rtcHelp(Go2RTCStreamStatus(clients: mixed, hasActiveProducer: true)) == "5 clients · RTSP ×2, WebRTC ×1, autre ×1, ZZ ×1")
    }

    @Test("Les textes de go2rtc en anglais")
    func english() {
        Localization.$languageOverride.withValue("en") {
            #expect(Labels.go2rtcBlock(.portBusy(8554)) == "Port 8554 already in use: is another go2rtc running?")
            #expect(Labels.coreAudioStuck == "coreaudiod is not responding: the camera is stuck")
            #expect(Labels.quitStopsCamera == "Quitting PTZBot also stops the HomeKit camera.")
            #expect(Labels.go2rtcHelp(Go2RTCStreamStatus(clients: Go2RTCClients(byType: ["rtsp": 2]), hasActiveProducer: true)) == "2 clients · RTSP ×2")
        }
    }
}
````

- [x] **Étape 2 : Lancer les tests, constater l'échec**

Run : `(cd mac/app/PTZBotKit && swift test)`
Attendu : échec de compilation, « type 'Labels' has no member 'ptzdIndicator' ».

- [x] **Étape 3 : Écrire les pastilles, puis le panneau**

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/ServiceIndicator.swift` :

````swift
import Foundation
import NacelleProtocol

/// La pastille d'un service dans le panneau (spec B3 § 6.1) : verte à l'état normal (actif, prêt, installé), sans
/// ligne ; sinon la ligne d'état, en orange quand il faut agir ou regarder le journal, en rouge pour un échec.
public struct ServiceIndicator: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Pastille verte.
        case normal
        /// Éteint, démarrage, arrêt : pastille grise.
        case neutral
        /// Orange : une action, ou un coup d'œil au journal.
        case attention
        /// Rouge : en échec.
        case failure
    }

    public var tone: Tone
    /// nil à l'état normal : la pastille suffit.
    public var line: String?

    public init(tone: Tone, line: String?) {
        self.tone = tone
        self.line = line
    }

    public static let normal = ServiceIndicator(tone: .normal, line: nil)
}

extension Labels {
    /// ptzd : actif quand la connexion de confiance est établie (spec ptzd dans l'app § 6.1). En échec, la ligne est la
    /// raison.
    public static func ptzdIndicator(_ state: ServiceSupervisor.State, connection: PanelModel.Service, legacy: Bool) -> ServiceIndicator {
        if legacy {
            return connection == .active
                ? ServiceIndicator(tone: .attention, line: service(state, connection: connection, legacy: true))
                : ServiceIndicator(tone: .attention, line: service(connection))
        }
        switch state {
        case .running where connection == .active:
            return .normal
        case .running where connection == .unreachable:
            return ServiceIndicator(tone: .attention, line: service(connection))
        case let .failed(reason):
            return ServiceIndicator(tone: .failure, line: reason)
        case .restarting:
            return ServiceIndicator(tone: .attention, line: service(state, connection: connection, legacy: false))
        case .stopped, .starting, .running:
            return ServiceIndicator(tone: .neutral, line: service(state, connection: connection, legacy: false))
        }
    }

    /// Talkback : prêt ou en lecture, c'est l'état normal.
    public static func talkbackIndicator(_ status: TalkbackModel.Status) -> ServiceIndicator {
        switch status {
        case .ready, .playing:
            .normal
        case .disabled, .starting, .stopping:
            ServiceIndicator(tone: .neutral, line: talkbackStatus(status))
        case .requiresApproval, .failed, .notRunning:
            ServiceIndicator(tone: .attention, line: talkbackStatus(status))
        }
    }

    /// Le SDK OBSBOT : prêt, c'est l'état normal ; sinon son état court, à droite de la ligne.
    public static func sdkIndicator(_ status: SDKStatus?) -> ServiceIndicator {
        switch status {
        case .ready:
            .normal
        case nil, .recompiling:
            ServiceIndicator(tone: .neutral, line: sdk(status))
        case .absent, .quarantined, .incompatible, .unloadable, .sourceMissing, .toolsRequired, .incomplete, .compileFailed:
            ServiceIndicator(tone: .attention, line: sdk(status))
        }
    }

    /// go2rtc (spec B3 § 5) : l'état du superviseur, puis, quand il tourne, les alertes (coreaudiod d'abord). Un
    /// fichier personnalisé le dit, pastille verte.
    public static func go2rtcIndicator(_ state: Go2RTCSupervisor.State, isEnabled: Bool, usesCustomFile: Bool, health: Go2RTCHealth) -> ServiceIndicator {
        guard isEnabled else {
            return ServiceIndicator(tone: .neutral, line: Localization.text("Désactivé"))
        }
        switch state {
        case .stopped:
            return ServiceIndicator(tone: .neutral, line: Localization.text("Arrêté"))
        case .starting:
            return ServiceIndicator(tone: .neutral, line: Localization.text("Démarrage…"))
        case let .restarting(count):
            return ServiceIndicator(tone: .attention, line: Localization.text("Relancé après un arrêt inattendu (\(count))"))
        case let .failed(failure):
            return ServiceIndicator(tone: go2rtcFailureTone(failure), line: go2rtcFailure(failure))
        case .running:
            if health.coreAudioStuck {
                return ServiceIndicator(tone: .attention, line: coreAudioStuck)
            }
            if health.accessDenied {
                return ServiceIndicator(tone: .attention, line: cameraAccessDenied)
            }
            if health.cameraMissing {
                return ServiceIndicator(tone: .attention, line: go2rtcBlock(.cameraMissing))
            }
            return usesCustomFile ? ServiceIndicator(tone: .normal, line: customConfigFile) : .normal
        }
    }

    /// Ce qui a empêché le lancement.
    public static func go2rtcBlock(_ block: Go2RTCBlock) -> String {
        switch block {
        case .ffmpegMissing: Localization.text("ffmpeg introuvable")
        case .cameraMissing: Localization.text("Caméra OBSBOT absente")
        case .microphoneMissing: Localization.text("Micro OBSBOT absent")
        case let .portBusy(port): Localization.text("Port \(String(port)) déjà utilisé : un autre go2rtc tourne-t-il ?")
        case .customFileMissing: Localization.text("Fichier de configuration personnalisé introuvable")
        case let .invalidSettings(message): message
        case let .writeFailed(reason): Localization.text("go2rtc.yaml n'a pas pu être écrit : \(reason)")
        }
    }

    public static func go2rtcFailure(_ failure: Go2RTCFailure) -> String {
        switch failure {
        case let .blocked(block): go2rtcBlock(block)
        case .crashLoop: Localization.text("go2rtc s'arrête sans cesse : ouvrez le journal")
        case let .launch(reason): Localization.text("go2rtc n'a pas pu être lancé : \(reason)")
        case .missingBinary: Localization.text("go2rtc manque dans PTZBot : réinstallez PTZBot")
        case .unkillable: Localization.text("go2rtc ne s'arrête pas : ouvrez le journal")
        }
    }

    /// Orange pour ce qu'on peut corriger soi-même (ffmpeg, appareil, port, réglage) ; rouge pour le reste.
    static func go2rtcFailureTone(_ failure: Go2RTCFailure) -> ServiceIndicator.Tone {
        switch failure {
        case .blocked(.writeFailed), .crashLoop, .launch, .missingBinary, .unkillable: .failure
        case .blocked: .attention
        }
    }

    /// Le survol de la rangée go2rtc : le nombre de clients et le détail par protocole ; nil sans lecture de l'API.
    public static func go2rtcHelp(_ stream: Go2RTCStreamStatus?) -> String? {
        guard let clients = stream?.clients else { return nil }
        let count = clients.total
        switch count {
        case 0: return Localization.text("Aucun client")
        case 1: return Localization.text("1 client · \(go2rtcClientsDetail(clients))")
        default: return Localization.text("\(count) clients · \(go2rtcClientsDetail(clients))")
        }
    }

    /// « RTSP ×1, WebRTC ×1 » : les protocoles connus d'abord, dans cet ordre.
    public static func go2rtcClientsDetail(_ clients: Go2RTCClients) -> String {
        let order = ["rtsp", "webrtc", "mse", "hls", "mjpeg"]
        let names = ["rtsp": "RTSP", "webrtc": "WebRTC", "mse": "MSE", "hls": "HLS", "mjpeg": "MJPEG"]
        let sorted = clients.byType.keys.sorted { left, right in
            (order.firstIndex(of: left) ?? order.count, left) < (order.firstIndex(of: right) ?? order.count, right)
        }
        return sorted.map { type in
            let name = names[type] ?? (type.isEmpty ? Localization.text("autre") : type.uppercased())
            return "\(name) ×\(clients.byType[type] ?? 0)"
        }.joined(separator: ", ")
    }

    public static var coreAudioStuck: String { Localization.text("coreaudiod ne répond pas : la caméra est bloquée") }
    public static var cameraAccessDenied: String { Localization.text("Accès à la caméra refusé") }
    public static var customConfigFile: String { Localization.text("Fichier de configuration personnalisé") }
    /// La confirmation de « Quitter » quand go2rtc est allumé (spec B3 § 3.3).
    public static var quitStopsCamera: String { Localization.text("Quitter PTZBot arrête aussi la caméra HomeKit.") }
}
````

Ajouter les textes au catalogue de PTZBotKit (« Désactivé », « Arrêté », « Démarrage… » et « Relancé après un arrêt inattendu (%lld) » y sont déjà) :

````bash
/usr/bin/python3 - mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings <<'PY'
import json, sys
chemin = sys.argv[1]
textes = {
    "ffmpeg introuvable": "ffmpeg not found",
    "Caméra OBSBOT absente": "OBSBOT camera not found",
    "Micro OBSBOT absent": "OBSBOT microphone not found",
    "Port %@ déjà utilisé : un autre go2rtc tourne-t-il ?": "Port %@ already in use: is another go2rtc running?",
    "Fichier de configuration personnalisé introuvable": "Custom configuration file not found",
    "go2rtc.yaml n'a pas pu être écrit : %@": "go2rtc.yaml could not be written: %@",
    "go2rtc s'arrête sans cesse : ouvrez le journal": "go2rtc keeps stopping: open the log",
    "go2rtc n'a pas pu être lancé : %@": "go2rtc could not be started: %@",
    "go2rtc manque dans PTZBot : réinstallez PTZBot": "go2rtc is missing from PTZBot: reinstall PTZBot",
    "go2rtc ne s'arrête pas : ouvrez le journal": "go2rtc does not stop: open the log",
    "Aucun client": "No clients",
    "1 client · %@": "1 client · %@",
    "%lld clients · %@": "%lld clients · %@",
    "autre": "other",
    "coreaudiod ne répond pas : la caméra est bloquée": "coreaudiod is not responding: the camera is stuck",
    "Accès à la caméra refusé": "Camera access denied",
    "Fichier de configuration personnalisé": "Custom configuration file",
    "Quitter PTZBot arrête aussi la caméra HomeKit.": "Quitting PTZBot also stops the HomeKit camera.",
}
d = json.load(open(chemin, encoding='utf-8'))
for fr, en in textes.items():
    d['strings'][fr] = {"extractionState": "manual", "localizations": {
        "en": {"stringUnit": {"state": "translated", "value": en}},
        "fr": {"stringUnit": {"state": "translated", "value": fr}}}}
open(chemin, 'w', encoding='utf-8').write(json.dumps(d, ensure_ascii=False, indent=2) + '\n')
PY
````

Le panneau : la rangée go2rtc après ptzd, une pastille par service, la ligne d'état seulement hors état normal, la confirmation de « Quitter » ; « Ouvrir le journal de go2rtc » et les réglages de confidentialité de la caméra :

````bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBot/PanelView.swift b/mac/app/PTZBot/PanelView.swift
index c63e4c8..494344f 100644
--- a/mac/app/PTZBot/PanelView.swift
+++ b/mac/app/PTZBot/PanelView.swift
@@ -2,13 +2,15 @@ import NacelleProtocol
 import PTZBotKit
 import SwiftUI
 
-/// Le panneau sous l'icône (spec app Mac § 8.1, maquette B).
+/// Le panneau sous l'icône (spec app Mac § 8.1, maquette B ; spec B3 § 6.1 : go2rtc et les pastilles).
 struct PanelView: View {
     let model: PanelModel
     let talkback: TalkbackModel
     let settings: SettingsModel
     let app: AppController
     let network: LocalNetworkState
+    let go2rtc: Go2RTCSupervisor
+    let go2rtcMonitor: Go2RTCMonitor
     @Environment(\.openWindow) private var openWindow
 
     private var supervisor: ServiceSupervisor {
@@ -68,9 +70,12 @@ struct PanelView: View {
             // L'état de Talkback (« En lecture ») est relu dès que talkd réécrit son fichier, et chaque seconde en secours, tant
             // que le panneau est ouvert.
             talkback.beginWatching()
+            // Les clients de go2rtc et ses alertes, toutes les 2 s, seulement panneau ouvert (spec B3 § 5).
+            go2rtcMonitor.beginWatching()
         }
         .onDisappear {
             talkback.endWatching()
+            go2rtcMonitor.endWatching()
         }
     }
 
@@ -93,15 +98,19 @@ struct PanelView: View {
 
     private var serviceSection: some View {
         PanelSection(Labels.serviceSection) {
+            let ptzd = Labels.ptzdIndicator(supervisor.state, connection: model.service, legacy: legacy)
             PanelRow(icon: "server.rack", title: AppText.text("Service ptzd")) {
-                Toggle(AppText.text("Service ptzd"), isOn: Binding(get: { supervisor.isEnabled }, set: { supervisor.setEnabled($0) }))
-                    .labelsHidden()
-                    .toggleStyle(.switch)
-                    .controlSize(.small)
-                    .disabled(app.legacy != .none)
+                HStack(spacing: 8) {
+                    StatusDot(tone: ptzd.tone)
+                    Toggle(AppText.text("Service ptzd"), isOn: Binding(get: { supervisor.isEnabled }, set: { supervisor.setEnabled($0) }))
+                        .labelsHidden()
+                        .toggleStyle(.switch)
+                        .controlSize(.small)
+                        .disabled(app.legacy != .none)
+                }
             } notes: {
-                if case let .failed(reason) = supervisor.state {
-                    PanelNote(reason, color: .red)
+                if let line = ptzd.line {
+                    PanelNote(line, color: ptzd.tone.color)
                 }
                 if Labels.showsLog(supervisor.state, connection: model.service) {
                     Button(AppText.text("Ouvrir le journal de ptzd")) {
@@ -128,16 +137,24 @@ struct PanelView: View {
                 }
             }
             Divider()
+            go2rtcRow
+            Divider()
             // Talkback : le retour audio de la caméra vers les haut-parleurs du Mac. Indépendant de ptzd : l'agent
             // tourne aussi quand PTZBot est fermé, d'où ni grisé avec le service ni arrêté par « Quitter ».
+            let talkbackIndicator = Labels.talkbackIndicator(talkback.status)
             PanelRow(icon: "speaker.wave.2", title: AppText.text("Talkback")) {
-                Toggle(AppText.text("Talkback"), isOn: Binding(get: { talkback.isEnabled }, set: { talkback.setEnabled($0) }))
-                    .labelsHidden()
-                    .disabled(talkback.isPreparing || talkback.isBusy)
-                    .toggleStyle(.switch)
-                    .controlSize(.small)
+                HStack(spacing: 8) {
+                    StatusDot(tone: talkbackIndicator.tone)
+                    Toggle(AppText.text("Talkback"), isOn: Binding(get: { talkback.isEnabled }, set: { talkback.setEnabled($0) }))
+                        .labelsHidden()
+                        .disabled(talkback.isPreparing || talkback.isBusy)
+                        .toggleStyle(.switch)
+                        .controlSize(.small)
+                }
             } notes: {
-                PanelNote(Labels.talkbackStatus(talkback.status), color: talkback.needsAttention ? .orange : nil)
+                if let line = talkbackIndicator.line {
+                    PanelNote(line, color: talkbackIndicator.tone.color)
+                }
                 if talkback.status == .requiresApproval {
                     Button(Labels.talkbackApproval) {
                         talkback.openSystemSettings()
@@ -152,11 +169,17 @@ struct PanelView: View {
             Divider()
             // À droite, l'état court seulement ; l'explication et le bouton vont dessous, sur toute la largeur
             // (banc du 08/10 : un état long débordait sur six lignes et tronquait le bouton).
+            let sdk = Labels.sdkIndicator(app.sdkStatus)
             PanelRow(icon: "shippingbox", title: AppText.text("SDK OBSBOT")) {
-                Text(Labels.sdk(app.sdkStatus))
-                    .foregroundStyle(.secondary)
-                    .lineLimit(1)
-                    .fixedSize()
+                HStack(spacing: 8) {
+                    if let line = sdk.line {
+                        Text(line)
+                            .foregroundStyle(.secondary)
+                            .lineLimit(1)
+                            .fixedSize()
+                    }
+                    StatusDot(tone: sdk.tone)
+                }
             } notes: {
                 let tools = app.toolsAvailable ?? true
                 if let detail = Labels.sdkDetail(app.sdkStatus, toolsAvailable: tools) {
@@ -177,6 +200,52 @@ struct PanelView: View {
         }
     }
 
+    // MARK: - go2rtc
+
+    /// go2rtc, juste après ptzd (spec B3 § 6.1) : interrupteur, pastille, ligne d'état hors état normal, et le détail
+    /// des clients au survol.
+    private var go2rtcRow: some View {
+        let indicator = Labels.go2rtcIndicator(go2rtc.state, isEnabled: go2rtc.isEnabled, usesCustomFile: go2rtc.usesCustomFile,
+                                               health: go2rtcMonitor.health)
+        return PanelRow(icon: "video", title: "go2rtc") {
+            HStack(spacing: 8) {
+                StatusDot(tone: indicator.tone)
+                Toggle(isOn: Binding(get: { go2rtc.isEnabled }, set: { go2rtc.setEnabled($0) })) {
+                    Text(verbatim: "go2rtc")
+                }
+                    .labelsHidden()
+                    .toggleStyle(.switch)
+                    .controlSize(.small)
+            }
+        } notes: {
+            if let line = indicator.line {
+                PanelNote(line, color: indicator.tone.color)
+            }
+            if go2rtcMonitor.health.coreAudioStuck {
+                Button(AppText.text("Copier la commande de réparation")) {
+                    NSPasteboard.general.clearContents()
+                    NSPasteboard.general.setString(CoreAudioDetector.repairCommand, forType: .string)
+                }
+                .buttonStyle(.link)
+                .font(.caption)
+            } else if go2rtcMonitor.health.accessDenied {
+                Button(AppText.text("Ouvrir les réglages de confidentialité")) {
+                    PrivacySettings.openCamera()
+                }
+                .buttonStyle(.link)
+                .font(.caption)
+            }
+            if case .failed = go2rtc.state {
+                Button(AppText.text("Ouvrir le journal de go2rtc")) {
+                    LogOpener.openGo2RTCLog()
+                }
+                .buttonStyle(.link)
+                .font(.caption)
+            }
+        }
+        .help(Labels.go2rtcHelp(go2rtcMonitor.stream) ?? "")
+    }
+
     // MARK: - Caméra
 
     private var cameraSection: some View {
@@ -270,8 +339,10 @@ struct PanelView: View {
                 }
                 Spacer()
                 Button(Labels.quit) {
+                    // go2rtc allumé : quitter arrête aussi la caméra HomeKit, ce que la confirmation dit (spec B3 § 3.3).
+                    guard !app.quitStopsCamera || QuitConfirmation.ask() else { return }
                     // Un appairage ouvert est fermé avant de partir ; l'envoi est asynchrone, d'où le court délai.
-                    // La fin de l'app attend ensuite l'arrêt de ptzd, 6 s au plus (AppDelegate).
+                    // La fin de l'app attend ensuite l'arrêt de ptzd et de go2rtc, 16 s au plus (AppDelegate).
                     // Par la boucle d'exécution, jamais depuis un bloc de la file principale : voir
                     // AppDelegate.applicationShouldTerminate.
                     model.closePairing()
@@ -360,6 +431,30 @@ private struct PanelRow<Trailing: View, Notes: View>: View {
     }
 }
 
+/// La pastille d'un service : verte à l'état normal, grise, orange ou rouge sinon (spec B3 § 6.1).
+private struct StatusDot: View {
+    let tone: ServiceIndicator.Tone
+
+    var body: some View {
+        Circle()
+            .fill(tone.color ?? .secondary)
+            .frame(width: 8, height: 8)
+            .accessibilityHidden(true)
+    }
+}
+
+extension ServiceIndicator.Tone {
+    /// La couleur de la pastille et de la ligne d'état ; nil : le gris discret des notes.
+    var color: Color? {
+        switch self {
+        case .normal: .green
+        case .neutral: nil
+        case .attention: .orange
+        case .failure: .red
+        }
+    }
+}
+
 /// Un petit message sous une ligne ou une section, déjà traduit.
 private struct PanelNote: View {
     let text: String
@@ -378,13 +473,33 @@ private struct PanelNote: View {
     }
 }
 
-/// Ouvre le journal de ptzd dans Console.
+/// Ouvre le journal de ptzd ou de go2rtc dans Console.
 enum LogOpener {
     static let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/obsbot-nacelle/ptzd.log")
 
     @MainActor
     static func openPTZDLog() {
+        open(logURL)
+    }
+
+    @MainActor
+    static func openGo2RTCLog() {
+        open(AppPaths.system().go2rtcLog)
+    }
+
+    @MainActor
+    private static func open(_ url: URL) {
         let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
-        NSWorkspace.shared.open([logURL], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
+        NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
+    }
+}
+
+/// Réglages › Confidentialité et sécurité › Caméra : un refus d'accès s'y corrige (spec B3 § 5).
+enum PrivacySettings {
+    @MainActor
+    static func openCamera() {
+        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
+            NSWorkspace.shared.open(url)
+        }
     }
 }
PATCH
````

L'app crée le superviseur de go2rtc (donné au contrôleur, qui le lance au démarrage s'il est allumé et l'attend en quittant) et sa surveillance :

````bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBot/PTZBotApp.swift b/mac/app/PTZBot/PTZBotApp.swift
index a21349b..6fecd2b 100644
--- a/mac/app/PTZBot/PTZBotApp.swift
+++ b/mac/app/PTZBot/PTZBotApp.swift
@@ -1,16 +1,17 @@
 import PTZBotKit
 import SwiftUI
 
-/// PTZBot pour Mac (spec app Mac, spec ptzd dans l'app, spec distribution) : une icône dans la barre des menus,
-/// un panneau, quatre fenêtres, ptzd lancé comme processus enfant, Talkback (l'agent talkd, indépendant de l'app) et les
-/// mises à jour par Sparkle.
+/// PTZBot pour Mac (spec app Mac, spec ptzd dans l'app, spec distribution, spec B3) : une icône dans la barre des menus,
+/// un panneau, quatre fenêtres, ptzd et go2rtc lancés comme processus enfants, Talkback (l'agent talkd, indépendant de
+/// l'app) et les mises à jour par Sparkle.
 @main
 struct PTZBotApp: App {
     @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
 
     var body: some Scene {
         MenuBarExtra {
-            PanelView(model: delegate.panel, talkback: delegate.talkback, settings: delegate.settings, app: delegate.controller, network: delegate.network)
+            PanelView(model: delegate.panel, talkback: delegate.talkback, settings: delegate.settings, app: delegate.controller,
+                      network: delegate.network, go2rtc: delegate.go2rtc, go2rtcMonitor: delegate.go2rtcMonitor)
                 .followsLanguage(delegate.language)
         } label: {
             Image(nsImage: MenuBarIcon.image())
@@ -49,7 +50,7 @@ struct PTZBotApp: App {
     }
 }
 
-/// Les modèles de l'app, créés une fois ; « Quitter » (et toute fin de l'app) attend l'arrêt de ptzd.
+/// Les modèles de l'app, créés une fois ; « Quitter » (et toute fin de l'app) attend l'arrêt de ptzd et de go2rtc.
 @MainActor
 final class AppDelegate: NSObject, NSApplicationDelegate {
     /// La langue choisie dans les Réglages, appliquée avant tout autre texte.
@@ -61,6 +62,9 @@ final class AppDelegate: NSObject, NSApplicationDelegate {
     let controller: AppController
     let sdkWindow: SDKWindowModel
     let network: LocalNetworkState
+    /// go2rtc, processus enfant de l'app (spec B3), et sa surveillance.
+    let go2rtc: Go2RTCSupervisor
+    let go2rtcMonitor: Go2RTCMonitor
     private var started = false
 
     override init() {
@@ -76,8 +80,12 @@ final class AppDelegate: NSObject, NSApplicationDelegate {
             fileObserver: DispatchFileChangeObserver(url: paths.talkbackState)
         )
         let installer = SDKInstaller.system(paths: paths)
+        let preparer = Go2RTCPreparer.system(paths: paths)
+        go2rtc = .system(paths: paths, preparer: preparer, scheduler: scheduler)
+        go2rtcMonitor = .system(supervisor: go2rtc, paths: paths, scheduler: scheduler)
         controller = AppController(
             supervisor: .system(paths: paths.service, scheduler: scheduler),
+            go2rtc: go2rtc,
             legacyAgent: .system(supportDirectory: paths.support),
             configURL: paths.config,
             interfaces: SystemInterfaceAddresses(),
@@ -120,10 +128,11 @@ final class AppDelegate: NSObject, NSApplicationDelegate {
             talkback.refresh()
         }
         network.check()
+        go2rtcMonitor.start()
         Task { await controller.launch() }
     }
 
-    /// Attend l'arrêt de ptzd (6 s au plus), puis répond. C'est aussi le chemin d'une mise à jour : Sparkle demande
+    /// Attend l'arrêt de ptzd et de go2rtc (6 s au plus, 16 s avec go2rtc), puis répond. C'est aussi le chemin d'une mise à jour : Sparkle demande
     /// à l'app de quitter (événement Apple « quitter ») avant de la remplacer (voir `SparkleUpdater`).
     ///
     /// Ne jamais appeler `NSApp.terminate` depuis un bloc de la file principale (`DispatchQueue.main.async`,
@@ -182,6 +191,19 @@ enum MigrationAlert {
     }
 }
 
+/// La confirmation de « Quitter » quand go2rtc est allumé (spec B3 § 3.3).
+enum QuitConfirmation {
+    @MainActor
+    static func ask() -> Bool {
+        let alert = NSAlert()
+        alert.messageText = Labels.quitStopsCamera
+        alert.addButton(withTitle: Labels.quit)
+        alert.addButton(withTitle: AppText.text("Annuler"))
+        NSApp.activate()
+        return alert.runModal() == .alertFirstButtonReturn
+    }
+}
+
 enum WindowID {
     static let pairing = "pairing"
     static let devices = "devices"
PATCH
````

Ajouter les textes des vues au catalogue de l'app (« Ouvrir les réglages de confidentialité » et « Annuler » y sont déjà) :

````bash
/usr/bin/python3 - mac/app/PTZBot/Localizable.xcstrings <<'PY'
import json, sys
chemin = sys.argv[1]
textes = {
    "Copier la commande de réparation": "Copy the repair command",
    "Ouvrir le journal de go2rtc": "Open the go2rtc log",
}
d = json.load(open(chemin, encoding='utf-8'))
for fr, en in textes.items():
    d['strings'][fr] = {"extractionState": "manual", "localizations": {
        "en": {"stringUnit": {"state": "translated", "value": en}},
        "fr": {"stringUnit": {"state": "translated", "value": fr}}}}
open(chemin, 'w', encoding='utf-8').write(json.dumps(d, ensure_ascii=False, indent=2) + '\n')
PY
````

- [x] **Étape 4 : Lancer les tests et compiler l'app**

Run : `(cd mac/app/PTZBotKit && swift build --build-tests 2>&1 | grep -E "warning|error" ; swift test)`
Attendu : aucun avertissement ; `Test run with 365 tests in 30 suites passed` (`AppCatalogTests` compris : chaque texte des vues est dans le catalogue de l'app).

Run : `(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E "error:|warning:|BUILD" | grep -v appintents ; ./check-bundle.sh)`
Attendu : `** BUILD SUCCEEDED **`, aucun avertissement de compilation (la ligne d'`appintentsmetadataprocessor` est ancienne), `check-bundle.sh` sort à 0. Ne pas lancer l'app.

- [x] **Étape 5 : Commit**

```bash
rm -rf mac/app/.build/Build mac/app/.build/Logs
git add mac/app/PTZBotKit/Sources/PTZBotKit/ServiceIndicator.swift mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings \
  mac/app/PTZBotKit/Tests/PTZBotKitTests/ServiceIndicatorTests.swift \
  mac/app/PTZBot/PanelView.swift mac/app/PTZBot/PTZBotApp.swift mac/app/PTZBot/Localizable.xcstrings
git commit -F - <<'MSG'
Panneau : rangée go2rtc, pastilles vertes pour tous les services, alerte coreaudiod, confirmation de Quitter

<ligne Co-Authored-By du modèle>
MSG
```

---

### Tâche 8 : Réglages à deux onglets (« Général », « Caméra »)

**But :** spec § 6.2. La fenêtre des Réglages passe à deux onglets. « Général » garde le contenu actuel. « Caméra » : **Diffusion** (identifiant, mot de passe masqué, résolution, cadence, débit), **Appareils** (caméra et micro, OBSBOT détectés par défaut, un nom réglé débranché reste proposé), **ffmpeg** (chemin détecté, « Choisir… », `brew install ffmpeg` s'il manque), **Avancé** (ports RTSP et WebRTC, fichier personnalisé et son chemin, « Importer une configuration existante… » avec l'aperçu de ce qui est repris), « Ouvrir le journal », « Ouvrir l'interface web » et **« Appliquer »** : il régénère le yaml et relance go2rtc, après l'avertissement « Le flux HomeKit sera coupé quelques secondes. » quand go2rtc tourne. Un réglage qui ne change rien ne relance rien. La logique est dans `Go2RTCSettingsModel`, testé.

**Fichiers :**
- Créer : `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCSettingsModel.swift`
- Modifier : `mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings` (8 textes)
- Tester : `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCSettingsModelTests.swift`
- Remplacer : `mac/app/PTZBot/SettingsView.swift` (deux onglets ; l'ancien contenu devient `GeneralSettingsView`)
- Créer : `mac/app/PTZBot/CameraSettingsView.swift`
- Modifier : `mac/app/PTZBot/PTZBotApp.swift`
- Modifier : `mac/app/PTZBot/Localizable.xcstrings` (29 textes)

**Interfaces :**
- Consomme : `Go2RTCSupervisor` (`configuration`, `isEnabled`, `restart()`), `Go2RTCPreparing.writeConfig` (tâche 5) ; `Go2RTCConfigReader`, `Go2RTCImport`, `Go2RTCImportTests.handWritten` (tâche 3) ; `FFmpegLocator`, `CaptureDeviceCatalog` (tâche 4) ; `Labels.go2rtcBlock` (tâche 7) ; `LogOpener.openGo2RTCLog()` (tâche 7).
- Produit :
  - `Go2RTCSettingsModel` (`@MainActor @Observable`) : `draft`, `applied`, `cameras`, `microphones`, `detectedFFmpeg`, `ffmpegChecked`, `importPreview`, `message`, `isApplying`, `hasChanges`, `applyRestartsGo2RTC`, `cameraChoices`, `microphoneChoices`, `init(supervisor:preparer:store:locator:catalog:)`, `system(supervisor:preparer:)`, `refreshDetection() async`, `apply() async`, `revert()`, `previewImport(_:)`, `acceptImport()`, `cancelImport()` ;
  - `Labels.go2rtcImportSummary(_:) -> [String]`, `Labels.go2rtcApplyWarning` ;
  - dans l'app : `SettingsView(model:language:camera:)`, `CameraSettingsView(model:)`, `AppDelegate.cameraSettings`.

- [x] **Étape 1 : Écrire les tests du modèle**

Créer `mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCSettingsModelTests.swift` :

````swift
import Foundation
import Testing
@testable import PTZBotKit

@MainActor
@Suite("go2rtc : onglet Caméra des Réglages", .french, .timeLimit(.minutes(1)))
struct Go2RTCSettingsModelTests {
    let launcher = FakeLauncher()
    let settings = FakeSettings()
    let store = FakeSettings()
    let scheduler = FakeScheduler()
    let preparer = FakePreparer()

    private func make(enabled: Bool = false, catalog: FakeCatalog = FakeCatalog()) -> (Go2RTCSupervisor, Go2RTCSettingsModel) {
        settings.values[Go2RTCSupervisor.enabledKey] = enabled
        let supervisor = Go2RTCSupervisor(
            paths: Go2RTCSupervisor.Paths(gardien: URL(fileURLWithPath: "/app/gardien"), go2rtc: URL(fileURLWithPath: "/app/go2rtc"),
                                          log: URL(fileURLWithPath: "/logs/go2rtc.log")),
            launcher: launcher, preparer: preparer, settings: settings, scheduler: scheduler, parentPID: 4242,
            configuration: Go2RTCFixtures.settings()
        )
        let model = Go2RTCSettingsModel(supervisor: supervisor, preparer: preparer, store: store, locator: .homebrew, catalog: catalog)
        return (supervisor, model)
    }

    @Test("Au départ : les réglages du superviseur, rien à appliquer")
    func initial() {
        let (_, model) = make()
        #expect(model.draft == Go2RTCFixtures.settings())
        #expect(!model.hasChanges)
    }

    @Test("Appliquer go2rtc éteint : yaml écrit, réglages retenus sans le mot de passe, rien n'est lancé")
    func applyWhileOff() async throws {
        let (supervisor, model) = make()
        model.draft.framerate = 25
        #expect(!model.applyRestartsGo2RTC)
        await model.apply()
        #expect(preparer.written.map(\.framerate) == [25])
        #expect(model.applied.framerate == 25)
        #expect(supervisor.configuration.framerate == 25)
        let saved = try #require(store.strings[Go2RTCSettings.preferencesKey])
        #expect(!saved.contains(Go2RTCFixtures.password))
        #expect(Go2RTCSettings.load(from: store).framerate == 25)
        #expect(launcher.launched.isEmpty)
        #expect(!model.hasChanges)
    }

    @Test("Appliquer go2rtc allumé : avertissement demandé, puis relance sur les nouveaux réglages")
    func applyWhileOn() async throws {
        let (supervisor, model) = make(enabled: true)
        supervisor.start()
        await supervisor.waitForPreparation()
        model.draft.bitrate = 6
        #expect(model.applyRestartsGo2RTC)
        await model.apply()
        await supervisor.waitForPreparation()
        #expect(try #require(launcher.launched.first).terminations == 1)
        #expect(launcher.launched.count == 2)
        #expect(preparer.prepared.last?.bitrate == 6)
    }

    @Test("Un réglage qui ne change rien ne relance rien ; un yaml refusé ne retient rien et le dit")
    func noChangeAndFailure() async throws {
        let (supervisor, model) = make(enabled: true)
        supervisor.start()
        await supervisor.waitForPreparation()
        await model.apply()
        #expect(preparer.written.isEmpty)
        #expect(launcher.launched.count == 1)
        preparer.writeResult = .ffmpegMissing
        model.draft.framerate = 15
        await model.apply()
        #expect(model.message == "ffmpeg introuvable")
        #expect(model.applied.framerate == 30)
        #expect(store.strings[Go2RTCSettings.preferencesKey] == nil)
        #expect(launcher.launched.count == 1)
        model.revert()
        #expect(!model.hasChanges)
        #expect(model.message == nil)
    }

    @Test("Détection : appareils et ffmpeg ; un nom réglé débranché reste proposé")
    func detection() async {
        let (_, model) = make()
        model.draft.cameraName = "Caméra débranchée"
        await model.refreshDetection()
        #expect(model.ffmpegChecked)
        #expect(model.detectedFFmpeg?.path == Go2RTCFixtures.ffmpeg)
        #expect(model.cameraChoices == ["OBSBOT Virtual Camera", Go2RTCFixtures.camera, "Caméra débranchée"])
        #expect(model.microphoneChoices == [Go2RTCFixtures.microphone])
    }

    @Test("Import : ce qui serait repris est montré, sans le mot de passe ; « Reprendre » le met dans les réglages ; illisible : le message")
    func importConfig() throws {
        let directory = try Go2RTCFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "go2rtc.yaml")
        try Data(Go2RTCImportTests.handWritten.utf8).write(to: file)
        let before = try Data(contentsOf: file)
        let (_, model) = make()
        model.previewImport(file)
        let preview = try #require(model.importPreview)
        let summary = Labels.go2rtcImportSummary(preview)
        #expect(summary == [
            "Identifiant : camera", "Mot de passe : repris", "Port RTSP : 8554", "Port WebRTC : 8555",
            "Caméra : OBSBOT Tiny 2 StreamCamera", "Micro : OBSBOT Tiny2 Microphone", "ffmpeg : /opt/homebrew/bin/ffmpeg",
        ])
        #expect(!summary.joined().contains("secret-de-test"))
        #expect(!model.hasChanges, "rien n'est repris avant « Reprendre »")
        model.acceptImport()
        #expect(model.draft.username == "camera")
        #expect(model.draft.password == "secret-de-test")
        #expect(model.importPreview == nil)
        #expect(try Data(contentsOf: file) == before, "le fichier importé n'est pas modifié")
        model.previewImport(directory.appending(path: "absent.yaml"))
        #expect(model.importPreview == nil)
        #expect(model.message?.hasPrefix("Ce fichier n'a pas pu être lu") == true)
    }

    @Test("L'avertissement d'« Appliquer » en français et en anglais")
    func warning() {
        #expect(Labels.go2rtcApplyWarning == "Le flux HomeKit sera coupé quelques secondes.")
        #expect(Localization.$languageOverride.withValue("en") { Labels.go2rtcApplyWarning } == "The HomeKit stream will stop for a few seconds.")
    }
}
````

- [x] **Étape 2 : Lancer les tests, constater l'échec**

Run : `(cd mac/app/PTZBotKit && swift test)`
Attendu : échec de compilation, « cannot find 'Go2RTCSettingsModel' in scope ».

- [x] **Étape 3 : Écrire le modèle, puis les vues**

Créer `mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCSettingsModel.swift` :

````swift
import Foundation
import Observation

/// L'onglet « Caméra » des Réglages (spec B3 § 6.2) : les réglages en cours d'édition, les appareils et ffmpeg
/// détectés, l'import d'une configuration existante et « Appliquer ».
@MainActor
@Observable
public final class Go2RTCSettingsModel {
    /// Les réglages en cours d'édition.
    public var draft: Go2RTCSettings
    /// Les derniers réglages appliqués.
    public private(set) var applied: Go2RTCSettings
    public private(set) var cameras: [CaptureDeviceInfo] = []
    public private(set) var microphones: [CaptureDeviceInfo] = []
    /// ffmpeg trouvé ; nil : introuvable, ou pas encore cherché (`ffmpegChecked`).
    public private(set) var detectedFFmpeg: URL?
    public private(set) var ffmpegChecked = false
    /// Ce qu'un import reprendrait, montré avant d'être repris.
    public private(set) var importPreview: Go2RTCImport?
    /// Le résultat du dernier « Appliquer » ou import, en clair, quand il y a quelque chose à dire.
    public private(set) var message: String?
    public private(set) var isApplying = false

    @ObservationIgnored private let supervisor: Go2RTCSupervisor
    @ObservationIgnored private let preparer: any Go2RTCPreparing
    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let locator: FFmpegLocator
    @ObservationIgnored private let catalog: any CaptureDeviceCatalog

    /// Part des réglages du superviseur (préférences et mot de passe du yaml, `Go2RTCSettings.restore`).
    public init(
        supervisor: Go2RTCSupervisor,
        preparer: any Go2RTCPreparing,
        store: any SettingsStore,
        locator: FFmpegLocator,
        catalog: any CaptureDeviceCatalog
    ) {
        self.supervisor = supervisor
        self.preparer = preparer
        self.store = store
        self.locator = locator
        self.catalog = catalog
        draft = supervisor.configuration
        applied = supervisor.configuration
    }

    public static func system(supervisor: Go2RTCSupervisor, preparer: any Go2RTCPreparing) -> Go2RTCSettingsModel {
        Go2RTCSettingsModel(supervisor: supervisor, preparer: preparer, store: UserDefaultsSettingsStore(defaults: .standard),
                            locator: .system(), catalog: AVFoundationDeviceCatalog())
    }

    public var hasChanges: Bool {
        draft != applied
    }

    /// « Appliquer » relancera go2rtc : l'avertissement est montré avant.
    public var applyRestartsGo2RTC: Bool {
        hasChanges && supervisor.isEnabled
    }

    /// Les caméras proposées : celles du Mac, plus le nom réglé s'il est débranché.
    public var cameraChoices: [String] {
        Self.choices(cameras, keeping: draft.cameraName)
    }

    public var microphoneChoices: [String] {
        Self.choices(microphones, keeping: draft.microphoneName)
    }

    static func choices(_ devices: [CaptureDeviceInfo], keeping name: String?) -> [String] {
        let names = devices.map(\.name)
        guard let name, !name.isEmpty, !names.contains(name) else { return names }
        return names + [name]
    }

    /// Les appareils et ffmpeg, relus hors du fil de l'interface (onglet ouvert, « Rechercher à nouveau »).
    public func refreshDetection() async {
        let catalog = catalog
        let locator = locator
        let configured = draft.ffmpegPath
        let found = await Task.detached {
            (catalog.cameras(), catalog.microphones(), locator.locate(configured: configured))
        }.value
        cameras = found.0
        microphones = found.1
        detectedFFmpeg = found.2
        ffmpegChecked = true
    }

    /// « Appliquer » : le yaml régénéré, les réglages retenus (sans le mot de passe), puis go2rtc relancé s'il est
    /// allumé. Un réglage qui ne change rien ne relance rien ; un yaml qui ne s'écrit pas ne retient rien.
    public func apply() async {
        guard hasChanges, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        message = nil
        let settings = draft
        let preparer = preparer
        if let block = await Task.detached(operation: { await preparer.writeConfig(settings) }).value {
            message = Labels.go2rtcBlock(block)
            return
        }
        settings.save(to: store)
        applied = settings
        supervisor.configuration = settings
        if supervisor.isEnabled {
            supervisor.restart()
        }
    }

    /// Revient aux réglages appliqués.
    public func revert() {
        draft = applied
        message = nil
    }

    /// « Importer une configuration existante… » : le fichier est lu et ce qui serait repris montré. Il n'est pas
    /// modifié.
    public func previewImport(_ url: URL) {
        do {
            importPreview = try Go2RTCConfigReader.read(contentsOf: url)
            message = nil
        } catch {
            importPreview = nil
            message = error.localizedDescription
        }
    }

    /// « Reprendre » : l'import passe dans les réglages en cours ; « Appliquer » l'écrira.
    public func acceptImport() {
        guard let importPreview else { return }
        draft = importPreview.applied(to: draft)
        self.importPreview = nil
    }

    public func cancelImport() {
        importPreview = nil
    }
}

extension Labels {
    /// Ce qu'un import reprendrait, une ligne par réglage ; le mot de passe n'est jamais montré.
    public static func go2rtcImportSummary(_ imported: Go2RTCImport) -> [String] {
        var lines: [String] = []
        if let username = imported.username { lines.append(Localization.text("Identifiant : \(username)")) }
        if imported.password != nil { lines.append(Localization.text("Mot de passe : repris")) }
        if let port = imported.rtspPort { lines.append(Localization.text("Port RTSP : \(String(port))")) }
        if let port = imported.webrtcPort { lines.append(Localization.text("Port WebRTC : \(String(port))")) }
        if let camera = imported.cameraName { lines.append(Localization.text("Caméra : \(camera)")) }
        if let microphone = imported.microphoneName { lines.append(Localization.text("Micro : \(microphone)")) }
        if let ffmpeg = imported.ffmpegPath { lines.append(Localization.text("ffmpeg : \(ffmpeg)")) }
        return lines
    }

    /// L'avertissement d'« Appliquer » quand go2rtc tourne (spec B3 § 6.2).
    public static var go2rtcApplyWarning: String { Localization.text("Le flux HomeKit sera coupé quelques secondes.") }
}
````

Ajouter les textes au catalogue de PTZBotKit :

````bash
/usr/bin/python3 - mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings <<'PY'
import json, sys
chemin = sys.argv[1]
textes = {
    "Identifiant : %@": "User name: %@",
    "Mot de passe : repris": "Password: imported",
    "Port RTSP : %@": "RTSP port: %@",
    "Port WebRTC : %@": "WebRTC port: %@",
    "Caméra : %@": "Camera: %@",
    "Micro : %@": "Microphone: %@",
    "ffmpeg : %@": "ffmpeg: %@",
    "Le flux HomeKit sera coupé quelques secondes.": "The HomeKit stream will stop for a few seconds.",
}
d = json.load(open(chemin, encoding='utf-8'))
for fr, en in textes.items():
    d['strings'][fr] = {"extractionState": "manual", "localizations": {
        "en": {"stringUnit": {"state": "translated", "value": en}},
        "fr": {"stringUnit": {"state": "translated", "value": fr}}}}
open(chemin, 'w', encoding='utf-8').write(json.dumps(d, ensure_ascii=False, indent=2) + '\n')
PY
````

Remplacer tout le contenu de `mac/app/PTZBot/SettingsView.swift` par :

````swift
import PTZBotKit
import SwiftUI

/// La fenêtre « Réglages » (spec distribution § 8, spec B3 § 6.2) : deux onglets, « Général » et « Caméra ».
struct SettingsView: View {
    let model: SettingsModel
    let language: AppLanguageModel
    let camera: Go2RTCSettingsModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model, language: language)
                .tabItem { Label(AppText.text("Général"), systemImage: "gearshape") }
            CameraSettingsView(model: camera)
                .tabItem { Label(AppText.text("Caméra"), systemImage: "video") }
        }
        .frame(width: 460)
    }
}

/// L'onglet « Général » : les mises à jour, l'ouverture à la connexion, la langue et la version.
private struct GeneralSettingsView: View {
    let model: SettingsModel
    let language: AppLanguageModel

    private var loginItem: LoginItemModel {
        model.loginItem
    }

    var body: some View {
        Form {
            Section {
                Toggle(Labels.automaticallyChecks, isOn: Binding(get: { model.automaticallyChecks }, set: { model.setAutomaticallyChecks($0) }))
                    .disabled(!model.updatesEnabled)
                Toggle(Labels.automaticallyInstalls, isOn: Binding(get: { model.automaticallyDownloads }, set: { model.setAutomaticallyDownloads($0) }))
                    .disabled(!model.canChangeDownloads)
                if !model.updatesEnabled {
                    Text(Labels.updatesDisabled).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(Labels.openAtLogin, isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                if loginItem.needsApproval {
                    Button(Labels.loginApproval) {
                        loginItem.openSystemSettings()
                    }
                    .buttonStyle(.link)
                }
                if let error = loginItem.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                // « Français » et « English » sont toujours écrits dans leur langue.
                Picker(Labels.languageTitle, selection: Binding(get: { language.selection }, set: { language.select($0) })) {
                    ForEach(AppLanguage.allCases, id: \.self) { choice in
                        Text(Labels.languageChoice(choice)).tag(choice)
                    }
                }
                Text(Labels.languageUpdateNote).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(model.versionLine)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loginItem.refresh()
        }
    }
}
````

Créer `mac/app/PTZBot/CameraSettingsView.swift` :

````swift
import AppKit
import PTZBotKit
import SwiftUI
import UniformTypeIdentifiers

/// L'onglet « Caméra » des Réglages (spec B3 § 6.2) : diffusion, appareils, ffmpeg, réglages avancés, journal,
/// interface web, et « Appliquer ».
struct CameraSettingsView: View {
    @Bindable var model: Go2RTCSettingsModel
    @State private var confirmingApply = false

    var body: some View {
        Form {
            streamSection
            devicesSection
            ffmpegSection
            advancedSection
            if let preview = model.importPreview {
                importSection(preview)
            }
            Section {
                HStack {
                    Button(AppText.text("Ouvrir le journal")) {
                        LogOpener.openGo2RTCLog()
                    }
                    Button(AppText.text("Ouvrir l'interface web")) {
                        if let url = URL(string: "http://127.0.0.1:\(Go2RTCSettings.apiPort)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                    Button(AppText.text("Appliquer")) {
                        if model.applyRestartsGo2RTC {
                            confirmingApply = true
                        } else {
                            Task { await model.apply() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasChanges || model.isApplying)
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await model.refreshDetection()
        }
        .alert(Labels.go2rtcApplyWarning, isPresented: $confirmingApply) {
            Button(AppText.text("Appliquer")) {
                Task { await model.apply() }
            }
            Button(AppText.text("Annuler"), role: .cancel) {}
        }
    }

    private var streamSection: some View {
        Section(AppText.text("Diffusion")) {
            TextField(AppText.text("Identifiant"), text: $model.draft.username)
            SecureField(AppText.text("Mot de passe"), text: $model.draft.password)
            Picker(AppText.text("Résolution"), selection: $model.draft.resolution) {
                ForEach(Go2RTCSettings.resolutions, id: \.self) { resolution in
                    Text(verbatim: "\(resolution.width) × \(resolution.height)").tag(resolution)
                }
            }
            Picker(AppText.text("Cadence"), selection: $model.draft.framerate) {
                ForEach(Go2RTCSettings.framerates, id: \.self) { rate in
                    Text(AppText.text("\(String(rate)) i/s")).tag(rate)
                }
            }
            Picker(AppText.text("Débit"), selection: $model.draft.bitrate) {
                ForEach(Go2RTCSettings.bitrates, id: \.self) { rate in
                    Text(AppText.text("\(String(rate)) Mb/s")).tag(rate)
                }
            }
        }
    }

    private var devicesSection: some View {
        Section(AppText.text("Appareils")) {
            devicePicker(AppText.text("Caméra"), selection: $model.draft.cameraName, choices: model.cameraChoices)
            devicePicker(AppText.text("Micro"), selection: $model.draft.microphoneName, choices: model.microphoneChoices)
            Button(AppText.text("Rechercher à nouveau")) {
                Task { await model.refreshDetection() }
            }
        }
    }

    /// nil : « OBSBOT détectée », le choix par défaut (§ 3.6).
    private func devicePicker(_ title: String, selection: Binding<String?>, choices: [String]) -> some View {
        Picker(title, selection: selection) {
            Text(AppText.text("OBSBOT détecté d'office")).tag(String?.none)
            ForEach(choices, id: \.self) { name in
                Text(verbatim: name).tag(String?.some(name))
            }
        }
    }

    private var ffmpegSection: some View {
        Section(AppText.text("ffmpeg")) {
            LabeledContent(AppText.text("Chemin")) {
                Text(verbatim: model.draft.ffmpegPath ?? model.detectedFFmpeg?.path ?? "—")
                    .textSelection(.enabled)
            }
            HStack {
                Button(AppText.text("Choisir…")) {
                    if let url = Self.choose(directory: false, types: [.unixExecutable]) {
                        model.draft.ffmpegPath = url.path
                    }
                }
                if model.draft.ffmpegPath != nil {
                    Button(AppText.text("Chercher d'office")) {
                        model.draft.ffmpegPath = nil
                    }
                }
            }
            if model.ffmpegChecked, model.detectedFFmpeg == nil {
                Text(AppText.text("ffmpeg est introuvable. Installez-le avec Homebrew :")).font(.caption)
                Text(verbatim: FFmpegLocator.installCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private var advancedSection: some View {
        Section(AppText.text("Avancé")) {
            TextField(AppText.text("Port RTSP"), value: $model.draft.rtspPort, format: .number.grouping(.never))
            TextField(AppText.text("Port WebRTC"), value: $model.draft.webrtcPort, format: .number.grouping(.never))
            Toggle(AppText.text("Utiliser un fichier de configuration personnalisé"), isOn: $model.draft.customConfigEnabled)
            if model.draft.customConfigEnabled {
                HStack {
                    Text(verbatim: model.draft.customConfigPath ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(AppText.text("Choisir…")) {
                        if let url = Self.choose(directory: false, types: [.yaml]) {
                            model.draft.customConfigPath = url.path
                        }
                    }
                }
            }
            Button(AppText.text("Importer une configuration existante…")) {
                if let url = Self.choose(directory: false, types: [.yaml]) {
                    model.previewImport(url)
                }
            }
        }
    }

    private func importSection(_ preview: Go2RTCImport) -> some View {
        Section(AppText.text("Repris de la configuration")) {
            ForEach(Labels.go2rtcImportSummary(preview), id: \.self) { line in
                Text(line).font(.caption)
            }
            HStack {
                Spacer()
                Button(AppText.text("Annuler")) {
                    model.cancelImport()
                }
                Button(AppText.text("Reprendre")) {
                    model.acceptImport()
                }
            }
        }
    }

    /// Un fichier choisi par l'utilisateur ; les dossiers cachés (`/opt/homebrew/etc`) restent atteignables par ⇧⌘G.
    @MainActor
    private static func choose(directory: Bool, types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types
        panel.showsHiddenFiles = true
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}
````

L'app crée le modèle de l'onglet « Caméra » et le donne aux Réglages :

````bash
git apply <<'PATCH'
diff --git a/mac/app/PTZBot/PTZBotApp.swift b/mac/app/PTZBot/PTZBotApp.swift
index 6fecd2b..62909bc 100644
--- a/mac/app/PTZBot/PTZBotApp.swift
+++ b/mac/app/PTZBot/PTZBotApp.swift
@@ -42,7 +42,7 @@ struct PTZBotApp: App {
         .defaultLaunchBehavior(.suppressed)
 
         Window("Réglages", id: WindowID.settings) {
-            SettingsView(model: delegate.settings, language: delegate.language)
+            SettingsView(model: delegate.settings, language: delegate.language, camera: delegate.cameraSettings)
                 .followsLanguage(delegate.language, title: "Réglages")
         }
         .windowResizability(.contentSize)
@@ -62,9 +62,10 @@ final class AppDelegate: NSObject, NSApplicationDelegate {
     let controller: AppController
     let sdkWindow: SDKWindowModel
     let network: LocalNetworkState
-    /// go2rtc, processus enfant de l'app (spec B3), et sa surveillance.
+    /// go2rtc, processus enfant de l'app (spec B3), sa surveillance et l'onglet « Caméra » des Réglages.
     let go2rtc: Go2RTCSupervisor
     let go2rtcMonitor: Go2RTCMonitor
+    let cameraSettings: Go2RTCSettingsModel
     private var started = false
 
     override init() {
@@ -83,6 +84,7 @@ final class AppDelegate: NSObject, NSApplicationDelegate {
         let preparer = Go2RTCPreparer.system(paths: paths)
         go2rtc = .system(paths: paths, preparer: preparer, scheduler: scheduler)
         go2rtcMonitor = .system(supervisor: go2rtc, paths: paths, scheduler: scheduler)
+        cameraSettings = .system(supervisor: go2rtc, preparer: preparer)
         controller = AppController(
             supervisor: .system(paths: paths.service, scheduler: scheduler),
             go2rtc: go2rtc,
PATCH
````

Ajouter les textes des vues au catalogue de l'app :

````bash
/usr/bin/python3 - mac/app/PTZBot/Localizable.xcstrings <<'PY'
import json, sys
chemin = sys.argv[1]
textes = {
    "Général": "General",
    "Caméra": "Camera",
    "Ouvrir le journal": "Open the Log",
    "Ouvrir l'interface web": "Open the Web Interface",
    "Appliquer": "Apply",
    "Diffusion": "Streaming",
    "Identifiant": "User Name",
    "Mot de passe": "Password",
    "Résolution": "Resolution",
    "Cadence": "Frame Rate",
    "%@ i/s": "%@ fps",
    "Débit": "Bitrate",
    "%@ Mb/s": "%@ Mb/s",
    "Appareils": "Devices",
    "Micro": "Microphone",
    "Rechercher à nouveau": "Search Again",
    "OBSBOT détecté d'office": "Detected OBSBOT",
    "ffmpeg": "ffmpeg",
    "Chemin": "Path",
    "Choisir…": "Choose…",
    "Chercher d'office": "Find Automatically",
    "ffmpeg est introuvable. Installez-le avec Homebrew :": "ffmpeg was not found. Install it with Homebrew:",
    "Avancé": "Advanced",
    "Port RTSP": "RTSP Port",
    "Port WebRTC": "WebRTC Port",
    "Utiliser un fichier de configuration personnalisé": "Use a Custom Configuration File",
    "Importer une configuration existante…": "Import an Existing Configuration…",
    "Repris de la configuration": "Taken from the Configuration",
    "Reprendre": "Take Over",
}
d = json.load(open(chemin, encoding='utf-8'))
for fr, en in textes.items():
    d['strings'][fr] = {"extractionState": "manual", "localizations": {
        "en": {"stringUnit": {"state": "translated", "value": en}},
        "fr": {"stringUnit": {"state": "translated", "value": fr}}}}
open(chemin, 'w', encoding='utf-8').write(json.dumps(d, ensure_ascii=False, indent=2) + '\n')
PY
````

- [x] **Étape 4 : Lancer les tests et compiler l'app**

Run : `(cd mac/app/PTZBotKit && swift build --build-tests 2>&1 | grep -E "warning|error" ; swift test)`
Attendu : aucun avertissement ; `Test run with 372 tests in 31 suites passed`.

Run : `(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E "error:|warning:|BUILD" | grep -v appintents ; ./check-bundle.sh)`
Attendu : `** BUILD SUCCEEDED **`, aucun avertissement, `check-bundle.sh` à 0. Ne pas lancer l'app : l'onglet « Caméra » se regarde au banc avec Majid.

- [x] **Étape 5 : Commit**

```bash
rm -rf mac/app/.build/Build mac/app/.build/Logs
git add mac/app/PTZBotKit/Sources/PTZBotKit/Go2RTCSettingsModel.swift mac/app/PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings \
  mac/app/PTZBotKit/Tests/PTZBotKitTests/Go2RTCSettingsModelTests.swift \
  mac/app/PTZBot/SettingsView.swift mac/app/PTZBot/CameraSettingsView.swift mac/app/PTZBot/PTZBotApp.swift mac/app/PTZBot/Localizable.xcstrings
git commit -F - <<'MSG'
Réglages : onglets Général et Caméra (diffusion, appareils, ffmpeg, avancé, import, Appliquer avec avertissement)

<ligne Co-Authored-By du modèle>
MSG
```

---

### Tâche 9 : compilation et publication

**But :** spec § 3.1, § 3.4 et § 8. `build-helpers.sh` télécharge l'archive officielle de go2rtc 1.9.14 pour macOS arm64, vérifie son empreinte et celle du binaire extrait (`mac/app/go2rtc.sha256`), la garde en cache (`mac/app/.build/go2rtc`, hors du dépôt), compile le gardien, et place go2rtc, le gardien et la licence de go2rtc dans le paquet. `check-bundle.sh` vérifie go2rtc (le binaire officiel), le gardien, la licence, les droits caméra et micro de l'app et ses textes d'autorisation. L'app reçoit `NSCameraUsageDescription` et `NSMicrophoneUsageDescription` (au vouvoiement, traduits) et les droits `com.apple.security.device.camera` et `com.apple.security.device.audio-input`. La publication signe go2rtc et le gardien comme les autres utilitaires (déjà le cas pour tout `Contents/Helpers/*`), **exige** ces deux droits sur l'app et **n'en accepte pas d'autre** (sans bac à sable), vérifie que go2rtc est le binaire officiel avant toute signature, et n'admet des adresses au contrôle de fuite du .dmg que dans ce binaire-là.

**Fichiers :**
- Modifier : `outils/tests/test_publication.py`
- Modifier : `outils/publication.py` (`--droit-requis`, `--empreintes-go2rtc`, `verifier_go2rtc`, `empreinte_attendue`, `fuites(adresses_libres=)`)
- Modifier : `outils/publier.sh`
- Créer : `mac/app/go2rtc.sha256` (empreintes calculées une fois, étape 5)
- Créer : `mac/app/go2rtc-LICENSE.txt` (le fichier `LICENSE` de l'étiquette `v1.9.14`, entier)
- Modifier : `mac/app/build-helpers.sh`, `mac/app/check-bundle.sh`, `mac/app/project.yml`
- Créer : `mac/app/PTZBot/PTZBot.entitlements`
- Modifier : `mac/app/PTZBot/InfoPlist.xcstrings`

**Interfaces :**
- Consomme : l'exécutable `gardien` (tâche 1), `AppPaths.go2rtc` et `.gardien` (tâche 5) : `Contents/Helpers/go2rtc` et `Contents/Helpers/gardien`.
- Produit :
  - `publication.py publier … --droit-requis DROIT (répétable) --empreintes-go2rtc FICHIER` ; `P.empreinte_attendue(fichier, nom)`, `P.verifier_go2rtc(app, empreintes)`, `P.fuites(fichiers, dmg=False, adresses_libres=())`, `P.verifier_droits(…, requis=())` ;
  - `mac/app/go2rtc.sha256` : deux lignes au format de `shasum`, `<empreinte>  go2rtc_mac_arm64.zip` et `<empreinte>  go2rtc` ;
  - la variable `GO2RTC_CACHE` de `build-helpers.sh` (par défaut `mac/app/.build/go2rtc`).

- [x] **Étape 1 : Écrire les tests de la publication**

````bash
git apply <<'PATCH'
diff --git a/outils/tests/test_publication.py b/outils/tests/test_publication.py
index c4af4d8..bbea202 100644
--- a/outils/tests/test_publication.py
+++ b/outils/tests/test_publication.py
@@ -13,6 +13,7 @@ git ; HOME est un dossier temporaire, et le nom du compte, invente (USER, LOGNAM
 """
 import contextlib
 import datetime
+import hashlib
 import io
 import json
 import os
@@ -187,7 +188,13 @@ FAUX = {
                     "mach-lookup-seul": {"com.apple.security.temporary-exception.mach-lookup.global-name":
                                          ["fr.exemple.essai-spks"]},
                     "aucun-get-task-allow": {"com.apple.security.get-task-allow": True},
-                    "aucun-dyld": {"com.apple.security.cs.allow-dyld-environment-variables": True}}
+                    "aucun-dyld": {"com.apple.security.cs.allow-dyld-environment-variables": True},
+                    # go2rtc dans PTZBot (spec B3) : la camera et le micro, l'un des deux, ou un droit de plus.
+                    "camera-micro": {"com.apple.security.device.camera": True, "com.apple.security.device.audio-input": True},
+                    "camera-seule": {"com.apple.security.device.camera": True},
+                    "camera-micro-usb": {"com.apple.security.device.camera": True,
+                                         "com.apple.security.device.audio-input": True,
+                                         "com.apple.security.device.usb": True}}
             if cas in sans:
                 droits = sans[cas]
             if cas == "get-task-allow":
@@ -303,6 +310,15 @@ FAUX = {
         # L'utilitaire, comme ptzd : Contents/Helpers, executable ; un fichier non executable a cote n'est pas signe.
         # ptzd simule est un « Mach-O » (ses quatre premiers octets) : otool -L le lit.
         fichier(os.path.join(app, 'Helpers', 'ptzd'), contenu('ptzd', b'\\xcf\\xfa\\xed\\xfe ptzd invente'), 0o755)
+        # go2rtc (FAUX_GO2RTC = officiel ou altere) : un « Mach-O » qui porte une adresse, comme le vrai (multidiffusion,
+        # DNS publics) ; altere, il a quelques octets de plus. L'adresse est ecrite en morceaux (controle de fuite des
+        # commits).
+        go2rtc = os.environ.get('FAUX_GO2RTC')
+        if go2rtc:
+            fichier(os.path.join(app, 'Helpers', 'go2rtc'), b'\\xcf\\xfa\\xed\\xfe go2rtc invente ' b'203.0.113' b'.7'
+                    + (b' altere' if go2rtc == 'altere' else b''), 0o755)
+        elif os.path.exists(os.path.join(app, 'Helpers', 'go2rtc')):
+            os.remove(os.path.join(app, 'Helpers', 'go2rtc'))
         # Un element de trop dans Contents/Helpers (FAUX_UTILITAIRE_EN_TROP = non-executable ou lien).
         en_trop = os.environ.get('FAUX_UTILITAIRE_EN_TROP')
         if en_trop == 'non-executable':
@@ -1457,6 +1473,84 @@ class PublicationTests(unittest.TestCase):
         restent un refus."""
         self.refuse_droits('illisibles', 'illisibles')
 
+    def test_droits_camera_et_micro_requis(self):
+        """--droit-requis (PTZBot : la camera et le micro, spec B3) : l'app signee avec les droits de Xcode, relus ;
+        la publication continue."""
+        requis = ('--droit-requis', 'com.apple.security.device.camera', '--droit-requis', 'com.apple.security.device.audio-input')
+        self.m.publier('--sans-bac-a-sable', *requis, env={'FAUX_DROITS': 'camera-micro'})
+        with open(os.path.join(self.m.depot, 'build', 'publication', '1.2.3', 'droits-app.plist'), 'rb') as f:
+            self.assertEqual(plistlib.load(f), {'com.apple.security.device.camera': True,
+                                                'com.apple.security.device.audio-input': True,
+                                                P.VALIDATION_BIBLIOTHEQUES: True})
+        self.assertTrue([a for a in self.m.appels() if a.startswith('gh release create')])
+
+    def test_refus_droit_requis_manquant_ou_droit_inattendu(self):
+        """Un droit requis qui manque, un droit de plus (sans bac a sable), ou les droits camera et micro sans
+        --droit-requis : refus apres la signature, aucun .dmg."""
+        requis = ('--droit-requis', 'com.apple.security.device.camera', '--droit-requis', 'com.apple.security.device.audio-input')
+        for extra, cas, motif in ((requis, 'camera-seule', 'com.apple.security.device.audio-input manque'),
+                                  (requis, 'camera-micro-usb', 'droit inattendu com.apple.security.device.usb'),
+                                  ((), 'camera-micro', 'droit inattendu com.apple.security.device.audio-input, '
+                                                       'com.apple.security.device.camera')):
+            with self.subTest(cas=cas):
+                self.m.oublier()
+                appels = self.refuse('--sans-bac-a-sable', *extra, env={'FAUX_DROITS': cas}, motif=motif)
+                self.assertTrue([a for a in appels if a.startswith('codesign --force')], 'apres la signature')
+                self.assertFalse([a for a in appels if a.startswith(('hdiutil', 'sign_update'))], 'aucun .dmg')
+
+    def empreintes_go2rtc(self, contenu=b'\xcf\xfa\xed\xfe go2rtc invente ' + ADRESSE.encode()):
+        """Le fichier des empreintes de go2rtc, celle du faux binaire officiel (hors du depot : l'arbre reste propre)."""
+        chemin = os.path.join(self.dossier, 'go2rtc.sha256')
+        ecrire(chemin, '%s  go2rtc_mac_arm64.zip\n%s  go2rtc\n' % ('0' * 64, hashlib.sha256(contenu).hexdigest()))
+        return chemin
+
+    def test_go2rtc_officiel_signe_et_ses_adresses_admises(self):
+        """--empreintes-go2rtc : le binaire officiel est signe comme les autres utilitaires ; l'adresse qu'il porte
+        passe le controle de fuite du .dmg ; la publication continue."""
+        self.m.publier('--empreintes-go2rtc', self.empreintes_go2rtc(), env={'FAUX_GO2RTC': 'officiel'})
+        self.assertIn('Essai Inventee.app/Contents/Helpers/go2rtc', self.signatures())
+        self.assertTrue([a for a in self.m.appels() if a.startswith('gh release create')])
+
+    def test_refus_go2rtc_altere_ou_absent(self):
+        """Un go2rtc qui n'a pas l'empreinte attendue, ou absent : refus avant toute signature."""
+        for env, motif in (({'FAUX_GO2RTC': 'altere'}, "n'est pas le binaire officiel de go2rtc"),
+                           ({}, 'Contents/Helpers/go2rtc manque')):
+            with self.subTest(motif=motif):
+                self.m.oublier()
+                appels = self.refuse('--empreintes-go2rtc', self.empreintes_go2rtc(), env=env, motif=motif)
+                self.assertFalse([a for a in appels if a.startswith('codesign --force')], 'rien de signe')
+
+    def test_adresse_hors_de_go2rtc_toujours_refusee(self):
+        """La meme adresse dans le binaire de l'app : refus au controle de fuite, go2rtc verifie ou non."""
+        appels = self.refuse('--empreintes-go2rtc', self.empreintes_go2rtc(),
+                             env={'FAUX_GO2RTC': 'officiel', 'FAUX_FUITE': ADRESSE + ':app'},
+                             motif='le controle de fuite a trouve des donnees locales')
+        self.assertFalse([a for a in appels if a.startswith('hdiutil')])
+
+    def test_fuites_adresses_libres(self):
+        """fuites : dans un fichier aux adresses libres, une adresse est admise, un chemin personnel ou un nom
+        Tailscale non ; ailleurs, l'adresse reste une fuite."""
+        with tempfile.TemporaryDirectory() as d:
+            libre = os.path.join(d, 'go2rtc')
+            autre = os.path.join(d, 'ptzd')
+            for f in (libre, autre):
+                with open(f, 'wb') as e:
+                    e.write(b'x ' + ADRESSE.encode() + b' y\n')
+            self.assertEqual(P.fuites([libre, autre], dmg=True, adresses_libres={libre}), [(autre, 1)])
+            with open(libre, 'ab') as e:
+                e.write(b'\0' + NOM_TAILSCALE.encode() + b'\0' + AUTRE_COMPTE.encode() + b'\n')
+            self.assertEqual(P.fuites([libre], dmg=True, adresses_libres={libre}), [(libre, 2)])
+
+    def test_empreinte_attendue(self):
+        """Le fichier des empreintes : la ligne du nom demande ; absente ou mal formee, refus."""
+        with tempfile.TemporaryDirectory() as d:
+            chemin = os.path.join(d, 'go2rtc.sha256')
+            ecrire(chemin, '%s  go2rtc_mac_arm64.zip\n%s  go2rtc\n' % ('a' * 64, 'b' * 64))
+            self.assertEqual(P.empreinte_attendue(chemin, 'go2rtc'), 'b' * 64)
+            ecrire(chemin, 'zz  go2rtc\n')
+            with self.assertRaises(P.Refus):
+                P.empreinte_attendue(chemin, 'go2rtc')
+
     def test_utilitaires(self):
         """Contents/Helpers : chaque fichier ordinaire executable, dans l'ordre ; un lien ou un fichier non executable
         est refuse."""
PATCH
````

- [x] **Étape 2 : Lancer les nouveaux tests, constater l'échec**

Run : `(cd outils/tests && NOTARISER=1 PROFIL_NOTARISATION=djoko-notarisation /usr/bin/python3 -m unittest -k go2rtc -k droit -k fuites -k empreinte test_publication)`
Attendu : échecs et erreurs : `unrecognized arguments: --droit-requis`, `module 'publication' has no attribute 'empreinte_attendue'`, `fuites() got an unexpected keyword argument 'adresses_libres'`.

- [x] **Étape 3 : Écrire les contrôles de la publication**

````bash
git apply <<'PATCH'
diff --git a/outils/publication.py b/outils/publication.py
index 32597c9..d9696b5 100644
--- a/outils/publication.py
+++ b/outils/publication.py
@@ -10,6 +10,11 @@ facons seulement, plus le controle de fuite et les parametres :
     depot (adresses hors liste autorisee, noms Tailscale, chemins personnels et temporaires), sur le contenu du
     .dmg, les notes et le flux ;
   - --notes : le fichier des notes, quand il n'est pas dans le dossier de l'app (ici a la racine du depot).
+Puis, pour go2rtc dans PTZBot (spec B3, section 8) : --droit-requis exige un droit sur l'app et, avec
+--sans-bac-a-sable, aucun autre que ceux-la (et la levee de la validation des bibliotheques) n'est accepte ;
+--empreintes-go2rtc exige que Contents/Helpers/go2rtc soit le binaire officiel (son empreinte SHA-256, avant toute
+signature), et seul ce binaire, ainsi verifie, peut porter des adresses au controle de fuite du .dmg (celles de son
+code : multidiffusion, DNS publics...) ; les chemins personnels et les noms Tailscale y restent refuses.
 Et, apres la relecture du prototype : l'app compilee doit porter SUVerifyUpdateBeforeExtraction (signature Ed25519
 toujours exigee) ; chaque utilitaire signe est relu (aucun droit, runtime renforce) ; aucun binaire Mach-O du .dmg ne
 depend de libdev (otool -L) ; sign_update et generate_keys pris dans le paquet resolu exigent la revision de Sparkle
@@ -104,6 +109,7 @@ nulle part ailleurs (ni depot, ni commits, ni notes, ni flux, ni journaux affich
 """
 import argparse
 import datetime
+import hashlib
 import html
 import json
 import os
@@ -1016,7 +1022,31 @@ def droits_pour_signer(o, app, sortie, levee):
     return chemin
 
 
-def verifier_droits(o, app, identifiant, sans_bac_a_sable=False, levee=True):
+def empreinte_attendue(fichier, nom):
+    """L'empreinte SHA-256 de `nom` dans un fichier d'empreintes (une ligne « <64 chiffres hexadecimaux>  <nom> » par
+    fichier, comme shasum). Leve Refus."""
+    for ligne in lire(fichier).splitlines():
+        champs = ligne.split()
+        if len(champs) == 2 and champs[1] == nom and re.fullmatch(r'[0-9a-f]{64}', champs[0]):
+            return champs[0]
+    raise Refus("%s : pas d'empreinte pour %s" % (fichier, nom))
+
+
+def verifier_go2rtc(app, empreintes):
+    """Contents/Helpers/go2rtc est le binaire officiel de go2rtc, a l'octet pres (spec B3, section 3.1) : son
+    empreinte est celle du fichier `empreintes` (mac/app/go2rtc.sha256). A verifier avant toute signature. Leve
+    Refus."""
+    chemin = os.path.join(app, 'Contents', 'Helpers', 'go2rtc')
+    if not os.path.isfile(chemin):
+        raise Refus('Contents/Helpers/go2rtc manque')
+    with open(chemin, 'rb') as f:
+        empreinte = hashlib.sha256(f.read()).hexdigest()
+    if empreinte != empreinte_attendue(empreintes, 'go2rtc'):
+        raise Refus("Contents/Helpers/go2rtc n'est pas le binaire officiel de go2rtc (empreinte differente de %s)"
+                    % empreintes)
+
+
+def verifier_droits(o, app, identifiant, sans_bac_a_sable=False, levee=True, requis=()):
     """Les droits de l'app signee, relus : le bac a sable, en mach-lookup les seuls services de Sparkle
     (<identifiant>-spks et <identifiant>-spki, ni plus ni moins) ; avec sans_bac_a_sable, ni bac a sable ni aucun
     service en mach-lookup (une app sans bac a sable n'en a pas besoin) ; jamais get-task-allow (un debogueur pourrait
@@ -1048,6 +1078,15 @@ def verifier_droits(o, app, identifiant, sans_bac_a_sable=False, levee=True):
     elif droits.get(VALIDATION_BIBLIOTHEQUES) is not True:
         raise Refus("droits de l'app signee : %s manque (sans equipe, l'app ne chargerait pas ses cadres)"
                     % VALIDATION_BIBLIOTHEQUES)
+    for droit in requis:
+        if droits.get(droit) is not True:
+            raise Refus("droits de l'app signee : %s manque" % droit)
+    if sans_bac_a_sable:
+        # Sans bac a sable, les seuls droits admis : la levee de la validation des bibliotheques et les droits requis
+        # (pour PTZBot : la camera et le micro, spec B3, section 3.4).
+        autres = sorted(k for k in droits if k != VALIDATION_BIBLIOTHEQUES and k not in requis)
+        if autres:
+            raise Refus("droits de l'app signee : droit inattendu %s" % ', '.join(autres))
 
 
 def jeton(contenu, debut, fin, caracteres):
@@ -1060,31 +1099,36 @@ def jeton(contenu, debut, fin, caracteres):
     return contenu[debut:fin].strip(b'.')
 
 
-def trouvaille_admise(contenu, m, debuts):
+def trouvaille_admise(contenu, m, debuts, adresses_libres=False):
     """Une trouvaille de FUITE est admise si son jeton entier est dans AUTORISES ou commence par un des `debuts` ;
-    un chemin personnel ou temporaire ne l'est jamais."""
+    un chemin personnel ou temporaire ne l'est jamais. Avec `adresses_libres` (le binaire officiel de go2rtc, verifie
+    par son empreinte), toute adresse est admise ; un chemin ou un nom Tailscale reste juge."""
     texte = m.group(0)
     if texte.startswith(b'/'):
         return False
     if texte.endswith(b'net'):  # le domaine Tailscale (ts point net)
         t = jeton(contenu, m.start(), m.end(), CARACTERES_DE_NOM)
         return t in AUTORISES
+    if adresses_libres:
+        return True
     t = jeton(contenu, m.start(), m.end(), CHIFFRES_ET_POINTS)
     return t in AUTORISES or t.startswith(debuts)
 
 
-def fuites(fichiers, dmg=False):
+def fuites(fichiers, dmg=False, adresses_libres=()):
     """Le controle de fuite sur des fichiers, binaires compris : chaque trouvaille de FUITE non admise
-    (trouvaille_admise ; dans le .dmg, les OID de Sparkle en plus). Rend [(fichier, numero de ligne)], une fois par
-    ligne ; n'imprime que le nombre de fichiers et de lignes, jamais ce qui est trouve."""
+    (trouvaille_admise ; dans le .dmg, les OID de Sparkle en plus ; dans les fichiers de `adresses_libres`, toute
+    adresse). Rend [(fichier, numero de ligne)], une fois par ligne ; n'imprime que le nombre de fichiers et de lignes,
+    jamais ce qui est trouve."""
     debuts = DEBUTS_AUTORISES_DMG if dmg else DEBUTS_AUTORISES
     trouvees = []
     for f in fichiers:
         with open(f, 'rb') as e:
             contenu = e.read()
         lignes = set()
+        libres = f in adresses_libres
         for m in FUITE.finditer(contenu):
-            if not trouvaille_admise(contenu, m, debuts):
+            if not trouvaille_admise(contenu, m, debuts, libres):
                 lignes.add(contenu.count(b'\n', 0, m.start()) + 1)
         trouvees += [(f, n) for n in sorted(lignes)]
     dire('controle de fuite (%d fichiers) : %d ligne(s) trouvee(s)' % (len(fichiers), len(trouvees)))
@@ -1206,6 +1250,8 @@ def publier(a, o=None, maintenant=None):
     for cle, valeur in attendu.items():
         if info.get(cle) != valeur:
             raise Refus('Info.plist de l\'app compilee : %s = %r, attendu %r' % (cle, info.get(cle), valeur))
+    if a.empreintes_go2rtc:
+        verifier_go2rtc(app, a.empreintes_go2rtc)
     levee = validation_levee(a.identite)
     notarise = notariser(a.identite)
     fichier_droits = droits_pour_signer(o, app, sortie, levee)
@@ -1216,7 +1262,7 @@ def publier(a, o=None, maintenant=None):
     verifier_utilitaires(o, app)
     if not info.get('CFBundleIdentifier'):
         raise Refus("Info.plist de l'app compilee : CFBundleIdentifier manque")
-    verifier_droits(o, app, info['CFBundleIdentifier'], a.sans_bac_a_sable, levee)
+    verifier_droits(o, app, info['CFBundleIdentifier'], a.sans_bac_a_sable, levee, a.droit_requis)
     # Le certificat feuille de la signature, tel qu'il sera publie.
     prefixe = os.path.join(sortie, 'certificat-')
     for n in os.listdir(sortie):
@@ -1265,7 +1311,9 @@ def publier(a, o=None, maintenant=None):
         liste = os.path.join(sortie, 'contenu-dmg.txt')
         ecrire(liste, liste_du_contenu(scene))
         controles = fichiers_ordinaires(copie) + [liste, fichier_droits]
-        trouvees = fuites(controles, dmg=True)
+        # Le binaire officiel de go2rtc, verifie par son empreinte avant la signature : ses adresses sont admises.
+        libres = {os.path.join(copie, a.nom_app + '.app', 'Contents', 'Helpers', 'go2rtc')} if a.empreintes_go2rtc else set()
+        trouvees = fuites(controles, dmg=True, adresses_libres=libres)
         if trouvees:
             raise Refus("le controle de fuite a trouve des donnees locales dans le contenu du .dmg (%d) : %s ; rien "
                         "n'est publie" % (len(trouvees), ' ; '.join('%s:%d' % (os.path.relpath(f, sortie), n)
@@ -1398,6 +1446,10 @@ def arguments(argv):
     q.add_argument('--cle-privee')
     q.add_argument('--cle-publique')
     q.add_argument('--sans-tests', action='store_true')
+    q.add_argument('--droit-requis', action='append', default=[],
+                   help="droit exige sur l'app signee (et, sans bac a sable, seul admis avec la levee)")
+    q.add_argument('--empreintes-go2rtc',
+                   help='fichier des empreintes de go2rtc : Contents/Helpers/go2rtc doit etre le binaire officiel')
     a = p.parse_args(argv)
     if a.repetition and not a.url_base:
         p.error('--repetition demande --url-base')
PATCH
````

````bash
git apply <<'PATCH'
diff --git a/outils/publier.sh b/outils/publier.sh
index 7e26fe4..3220eb3 100755
--- a/outils/publier.sh
+++ b/outils/publier.sh
@@ -4,7 +4,9 @@
 # fuite, version publiee (etiquette ptzbot-vX.Y.Z, avec le .dmg), puis le flux des mises a jour
 # (mac/app/appcast.xml, qui garde toutes les versions) commite sur main et pousse aussitot, .dmg sur le Bureau.
 # Le .dmg porte aussi la licence de Sparkle 2.10.0 (outils/Sparkle-LICENSE.txt, le fichier LICENSE de l'etiquette
-# 2.10.0, entier) ; le commit du flux est signe Djoko-cli, a l'adresse noreply de GitHub.
+# 2.10.0, entier) ; le commit du flux est signe Djoko-cli, a l'adresse noreply de GitHub. Depuis la 1.1.0 (spec B3) :
+# l'app porte les droits camera et micro, et eux seuls (--droit-requis) ; Contents/Helpers/go2rtc doit etre le binaire
+# officiel de go2rtc 1.9.14 (--empreintes-go2rtc, mac/app/go2rtc.sha256).
 # Repris de maillage-thread ; la logique est dans outils/publication.py, ses tests dans outils/tests.
 #   outils/publier.sh X.Y.Z [--sans-bureau]
 # La repetition, sans GitHub ni Bureau (spec, section 10), avec la cle du trousseau, ou une paire d'essai :
@@ -58,11 +60,14 @@ export SPARKLE_BIN
 exec /usr/bin/python3 ../../outils/publication.py publier "$@" \
   --auteur Djoko-cli --etiquette ptzbot-v --flux appcast.xml --licence ../../outils/Sparkle-LICENSE.txt \
   --notes ../../NOTES-VERSIONS.md --sans-bac-a-sable \
+  --droit-requis com.apple.security.device.camera --droit-requis com.apple.security.device.audio-input \
+  --empreintes-go2rtc go2rtc.sha256 \
   --nom-app PTZBot --fichier PTZBot --depot-github Djoko-cli/ptzbot \
   --projet PTZBot.xcodeproj --schema PTZBot --cible PTZBot \
   --test 'cd ../../Packages/NacelleProtocol && swift test' \
   --test 'cd ../ptzd && swift test' \
   --test 'cd ../talkd && swift test' \
+  --test 'cd ../gardien && swift test' \
   --test 'cd PTZBotKit && swift test' \
   --test '/usr/bin/python3 -m unittest discover -s ../../outils/tests' \
   --test 'bash -n ../../scripts/install-mac.sh' \
PATCH
````

- [x] **Étape 4 : Lancer les tests de la publication, constater la réussite**

Run : `(cd outils/tests && NOTARISER=1 PROFIL_NOTARISATION=djoko-notarisation /usr/bin/python3 -m unittest -k go2rtc -k droit -k fuites -k empreinte -k utilitaire -k signature test_publication)`
Attendu : `Ran 24 tests` puis `OK` (environ 1 min 30).

Run : `(cd outils/tests && NOTARISER=1 PROFIL_NOTARISATION=djoko-notarisation /usr/bin/python3 -m unittest test_publication)`
Attendu : `Ran 156 tests` puis `OK` (5 à 7 min).

- [x] **Étape 5 : L'archive de go2rtc, ses empreintes et sa licence (une seule fois)**

Les empreintes ne se devinent pas : elles se calculent sur l'archive officielle. Dans un dossier neuf et vide, hors du dépôt (`DEPOT` est la racine du dépôt) :

```bash
DEPOT="$(git rev-parse --show-toplevel)"
ARCHIVES="$(mktemp -d)/go2rtc-1.9.14"
mkdir -p "$ARCHIVES"
/usr/bin/curl -fsSL -o "$ARCHIVES/go2rtc_mac_arm64.zip" \
  https://github.com/AlexxIT/go2rtc/releases/download/v1.9.14/go2rtc_mac_arm64.zip
/usr/bin/shasum -a 256 "$ARCHIVES/go2rtc_mac_arm64.zip"
/usr/bin/unzip -l "$ARCHIVES/go2rtc_mac_arm64.zip"
/usr/bin/unzip -p "$ARCHIVES/go2rtc_mac_arm64.zip" go2rtc > "$ARCHIVES/go2rtc"
/usr/bin/shasum -a 256 "$ARCHIVES/go2rtc"
/usr/bin/lipo -archs "$ARCHIVES/go2rtc"
/usr/bin/codesign -dv "$ARCHIVES/go2rtc" 2>&1 | grep -E "Signature|flags"
```

Attendu :
- l'archive : `919b78adc759d6b3883d1e1b2ac915ac0985bb903ff1897b4d228527bd64690c` (l'empreinte que GitHub annonce pour ce fichier ; une autre valeur : **arrêter** et prévenir Majid) ;
- un seul membre, `go2rtc` (un autre nom : arrêter, `build-helpers.sh` extrait ce nom-là) ;
- `arm64` ;
- `Signature=adhoc` et `linker-signed` dans les drapeaux (le binaire est copié tel quel ; s'il n'est pas signé du tout, arrêter : le paquet ne se signerait pas) ;
- l'empreinte du binaire : la même que celle affichée par l'essai de la tâche 0, s'il a été fait.

Contrôle de fuite du binaire réel, avant de l'accepter : ses adresses sont admises, mais pas un chemin personnel ni un nom Tailscale.

```bash
cd "$DEPOT" && /usr/bin/python3 - "$ARCHIVES/go2rtc" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), 'outils'))
import publication as P
binaire = sys.argv[1]
print('lignes refusees :', len(P.fuites([binaire], dmg=True, adresses_libres={binaire})))
print('termes personnels :', len(P.fichiers_avec_termes([binaire], [os.environ['HOME'], '/Us' + 'ers/', os.environ['USER']])))
PY
```

Attendu : `lignes refusees : 0` et `termes personnels : 0` (sinon arrêter et prévenir Majid : la publication refuserait le .dmg).

Écrire les empreintes, mettre l'archive en cache (la compilation ne la retéléchargera pas) et copier la licence :

```bash
cd "$DEPOT"
printf '%s  go2rtc_mac_arm64.zip\n%s  go2rtc\n' \
  919b78adc759d6b3883d1e1b2ac915ac0985bb903ff1897b4d228527bd64690c \
  "$(/usr/bin/shasum -a 256 "$ARCHIVES/go2rtc" | /usr/bin/awk '{ print $1 }')" > mac/app/go2rtc.sha256
mkdir -p mac/app/.build/go2rtc && cp "$ARCHIVES/go2rtc_mac_arm64.zip" mac/app/.build/go2rtc/
/usr/bin/curl -fsSL -o mac/app/go2rtc-LICENSE.txt https://raw.githubusercontent.com/AlexxIT/go2rtc/v1.9.14/LICENSE
/usr/bin/shasum -a 256 mac/app/go2rtc-LICENSE.txt
cat mac/app/go2rtc.sha256
```

Attendu : la licence a l'empreinte `b0dcf4855af5a72b4dfbd9117c207b330f4cc35658576a0b5351d6e2becac546` et commence par « MIT License » ; `go2rtc.sha256` a deux lignes de 64 chiffres hexadécimaux. La ligne de copyright de la licence nomme son auteur : elle reste telle quelle (comme `outils/Sparkle-LICENSE.txt`), c'est la seule exception à « aucun nom réel ».

- [x] **Étape 6 : go2rtc et le gardien dans le paquet ; droits et textes caméra et micro**

````bash
git apply <<'PATCH'
diff --git a/mac/app/build-helpers.sh b/mac/app/build-helpers.sh
index 4b55717..3e95ad9 100755
--- a/mac/app/build-helpers.sh
+++ b/mac/app/build-helpers.sh
@@ -1,5 +1,7 @@
 #!/bin/bash
-# Phase de construction de PTZBot (project.yml) : compile ptzd et talkd et les copie dans Contents/Helpers, copie la
+# Phase de construction de PTZBot (project.yml) : compile ptzd, talkd et le gardien et les copie dans Contents/Helpers,
+# y place go2rtc 1.9.14, l'archive officielle vérifiée par son empreinte (spec B3 § 3.1), et sa licence dans
+# Contents/Resources, copie la
 # plist embarquée de l'ancien agent de talkd dans Contents/Library/LaunchAgents (spec haut-parleur § 7 et § 15), copie la source d'obsbot-ai
 # (mac/ai/main.cpp) dans Contents/Resources/obsbot-ai.cpp, puis refuse le paquet s'il contient le SDK OBSBOT, ses
 # en-têtes ou un binaire obsbot-ai (spec distribution § 5.1). obsbot-ai est compilé sur le Mac de
@@ -40,6 +42,55 @@ if [ "${DEPLOYMENT_POSTPROCESSING:-NO}" = "YES" ]; then
     /usr/bin/codesign --force --sign - "$HELPERS/talkd"
 fi
 
+# Le gardien (spec B3 § 3.2), qui lance go2rtc et l'arrête si PTZBot disparaît, de la même façon que ptzd.
+echo "Compilation du gardien…"
+env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="$DEVELOPER_DIR" \
+    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/gardien" --product gardien
+GARDIEN_BIN="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" \
+    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/gardien" --show-bin-path)"
+install -m 755 "$GARDIEN_BIN/gardien" "$HELPERS/gardien"
+if [ "${DEPLOYMENT_POSTPROCESSING:-NO}" = "YES" ]; then
+    /usr/bin/xcrun strip -S "$HELPERS/gardien"
+    /usr/bin/codesign --force --sign - "$HELPERS/gardien"
+fi
+
+# go2rtc 1.9.14 (spec B3 § 3.1) : l'archive macOS arm64 des versions officielles d'AlexxIT/go2rtc, gardée en cache
+# (GO2RTC_CACHE, par défaut mac/app/.build/go2rtc, hors du dépôt) et vérifiée par son empreinte à chaque construction ;
+# le binaire extrait l'est aussi. Toute autre empreinte est refusée. Le binaire est copié tel quel, avec la signature
+# ad hoc de son éditeur de liens : la publication vérifie son empreinte avant de le signer.
+GO2RTC_VERSION=1.9.14
+GO2RTC_ARCHIVE=go2rtc_mac_arm64.zip
+GO2RTC_URL="https://github.com/AlexxIT/go2rtc/releases/download/v$GO2RTC_VERSION/$GO2RTC_ARCHIVE"
+EMPREINTES="$ROOT/mac/app/go2rtc.sha256"
+CACHE="${GO2RTC_CACHE:-$ROOT/mac/app/.build/go2rtc}"
+attendue() { /usr/bin/awk -v nom="$1" '$2 == nom { print $1 }' "$EMPREINTES"; }
+empreinte() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'; }
+if [ -z "$(attendue "$GO2RTC_ARCHIVE")" ] || [ -z "$(attendue go2rtc)" ]; then
+    echo "error: $EMPREINTES doit donner l'empreinte de $GO2RTC_ARCHIVE et celle de go2rtc" >&2
+    exit 1
+fi
+mkdir -p "$CACHE"
+if [ ! -f "$CACHE/$GO2RTC_ARCHIVE" ] || [ "$(empreinte "$CACHE/$GO2RTC_ARCHIVE")" != "$(attendue "$GO2RTC_ARCHIVE")" ]; then
+    echo "Téléchargement de go2rtc $GO2RTC_VERSION…"
+    rm -f "$CACHE/$GO2RTC_ARCHIVE" "$CACHE/$GO2RTC_ARCHIVE.part"
+    /usr/bin/curl -fsSL --retry 2 -o "$CACHE/$GO2RTC_ARCHIVE.part" "$GO2RTC_URL"
+    if [ "$(empreinte "$CACHE/$GO2RTC_ARCHIVE.part")" != "$(attendue "$GO2RTC_ARCHIVE")" ]; then
+        rm -f "$CACHE/$GO2RTC_ARCHIVE.part"
+        echo "error: l'archive de go2rtc $GO2RTC_VERSION n'a pas l'empreinte attendue ($EMPREINTES) : refusée" >&2
+        exit 1
+    fi
+    mv "$CACHE/$GO2RTC_ARCHIVE.part" "$CACHE/$GO2RTC_ARCHIVE"
+fi
+/usr/bin/unzip -p "$CACHE/$GO2RTC_ARCHIVE" go2rtc > "$CACHE/go2rtc.part"
+if [ "$(empreinte "$CACHE/go2rtc.part")" != "$(attendue go2rtc)" ]; then
+    rm -f "$CACHE/go2rtc.part"
+    echo "error: le binaire go2rtc extrait n'a pas l'empreinte attendue ($EMPREINTES) : refusé" >&2
+    exit 1
+fi
+install -m 755 "$CACHE/go2rtc.part" "$HELPERS/go2rtc"
+rm -f "$CACHE/go2rtc.part"
+install -m 644 "$ROOT/mac/app/go2rtc-LICENSE.txt" "$RESOURCES/go2rtc-LICENSE.txt"
+
 # La plist embarquée de l'ancien agent de talkd (Contents/Library/LaunchAgents, BundleProgram vers Contents/Helpers/talkd).
 # Depuis la 1.0.5 l'interrupteur « Talkback » n'inscrit plus rien par SMAppService : l'app écrit un agent launchd
 # classique dans ~/Library/LaunchAgents (ClassicAgent, spec haut-parleur § 15). Cette plist ne sert plus qu'à désinscrire
PATCH
````

````bash
git apply <<'PATCH'
diff --git a/mac/app/check-bundle.sh b/mac/app/check-bundle.sh
index 1c49d0d..27203c2 100755
--- a/mac/app/check-bundle.sh
+++ b/mac/app/check-bundle.sh
@@ -1,5 +1,7 @@
 #!/bin/bash
-# Vérifie le paquet Release de PTZBot (spec distribution § 5.1 et § 10) : ptzd et talkd dans Contents/Helpers, la plist
+# Vérifie le paquet Release de PTZBot (spec distribution § 5.1 et § 10, spec B3 § 8) : ptzd, talkd, le gardien et
+# go2rtc (le binaire officiel, à l'octet près) dans Contents/Helpers, sa licence dans Contents/Resources, les droits
+# caméra et micro de l'app et ses textes d'autorisation, la plist
 # embarquée de l'ancien agent de talkd dans Contents/Library/LaunchAgents (spec haut-parleur § 7 et § 15 : elle ne sert
 # plus qu'à désinscrire l'agent de la 1.0.4), la source d'obsbot-ai dans
 # Contents/Resources, Sparkle dans Contents/Frameworks ; ni le SDK OBSBOT (libdev*.dylib), ni ses
@@ -25,6 +27,9 @@ require() {
 }
 require -x Contents/Helpers/ptzd
 require -x Contents/Helpers/talkd
+require -x Contents/Helpers/gardien
+require -x Contents/Helpers/go2rtc
+require -f Contents/Resources/go2rtc-LICENSE.txt
 require -f Contents/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.talkd.plist
 require -f Contents/Resources/obsbot-ai.cpp
 require -d Contents/Frameworks/Sparkle.framework
@@ -49,6 +54,37 @@ if [ -f "$AGENT" ]; then
     fi
 fi
 
+# go2rtc : le binaire officiel de la version 1.9.14, à l'octet près (mac/app/go2rtc.sha256), pour Apple Silicon.
+EMPREINTES="$(cd "$(dirname "$0")" && pwd)/go2rtc.sha256"
+if [ -x "$APP/Contents/Helpers/go2rtc" ]; then
+    ATTENDUE="$(/usr/bin/awk '$2 == "go2rtc" { print $1 }' "$EMPREINTES")"
+    if [ -z "$ATTENDUE" ] || [ "$(/usr/bin/shasum -a 256 "$APP/Contents/Helpers/go2rtc" | /usr/bin/awk '{ print $1 }')" != "$ATTENDUE" ]; then
+        echo "go2rtc n'est pas le binaire officiel attendu ($EMPREINTES)" >&2
+        STATUS=1
+    else
+        echo "ok : go2rtc officiel (empreinte de $EMPREINTES)"
+    fi
+fi
+
+# Les droits caméra et micro de l'app (spec B3 § 3.4) ; ceux des utilitaires sont contrôlés à la publication.
+DROITS="$(/usr/bin/codesign -d --entitlements - --xml "$APP" 2>/dev/null | /usr/bin/plutil -convert json -o - - 2>/dev/null || true)"
+for DROIT in com.apple.security.device.camera com.apple.security.device.audio-input; do
+    if printf '%s' "$DROITS" | grep -q "\"$DROIT\":true"; then
+        echo "ok : droit $DROIT"
+    else
+        echo "droit manquant sur l'app : $DROIT" >&2
+        STATUS=1
+    fi
+done
+for CLE in NSCameraUsageDescription NSMicrophoneUsageDescription; do
+    if [ -n "$(/usr/bin/plutil -extract "$CLE" raw "$APP/Contents/Info.plist" 2>/dev/null)" ]; then
+        echo "ok : $CLE"
+    else
+        echo "Info.plist : $CLE manque" >&2
+        STATUS=1
+    fi
+done
+
 refuse() {
     local FOUND
     FOUND="$(find "$APP" "$@" -print)"
PATCH
````

````bash
git apply <<'PATCH'
diff --git a/mac/app/project.yml b/mac/app/project.yml
index 5c8e40b..187ed3c 100644
--- a/mac/app/project.yml
+++ b/mac/app/project.yml
@@ -48,6 +48,10 @@ targets:
         NSLocalNetworkUsageDescription: PTZBot accepte les connexions des iPhone appairés sur votre réseau local.
         NSBonjourServices:
           - _nacelle._tcp
+        # go2rtc et ses ffmpeg, descendants de PTZBot, ouvrent la caméra et le micro : macOS demande l'accès au nom de
+        # PTZBot (spec B3 § 3.4). Traduit dans InfoPlist.xcstrings.
+        NSCameraUsageDescription: PTZBot diffuse l'image de votre caméra OBSBOT vers HomeKit et l'app iPhone.
+        NSMicrophoneUsageDescription: PTZBot diffuse le son du micro de votre caméra OBSBOT vers HomeKit et l'app iPhone.
         # Mises à jour (Sparkle 2) : le flux des versions publiées et la clé publique Ed25519 (réglages
         # ci-dessous) ; recherche au lancement puis toutes les 24 h, téléchargement et installation automatiques.
         # Pas de bac à sable, donc pas de service d'installation de Sparkle (SUEnableInstallerLauncherService).
@@ -76,28 +80,38 @@ targets:
         CLE_MISES_A_JOUR: nRIVHOXbEktqGduJ4ukxhjZzlUaiE/yqR3sgbW9Ie6E=
         # Pas de bac à sable : l'app lit la configuration de ptzd et le lance.
         ENABLE_APP_SANDBOX: NO
+        # Les droits caméra et micro du runtime renforcé (spec B3 § 3.4), sur l'app seulement : les utilitaires n'en ont
+        # aucun. La publication les exige et n'en accepte pas d'autre (outils/publication.py, --droit-requis).
+        CODE_SIGN_ENTITLEMENTS: PTZBot/PTZBot.entitlements
         # Signature locale (ad hoc) ; seule la publication signe avec le certificat, runtime renforcé compris
         # (outils/publier.sh).
         CODE_SIGN_IDENTITY: "-"
         CODE_SIGN_STYLE: Manual
-        # La phase des utilitaires compile mac/ptzd et copie la source d'obsbot-ai.
+        # La phase des utilitaires compile mac/ptzd, mac/talkd et mac/gardien, télécharge go2rtc et copie la source
+        # d'obsbot-ai.
         ENABLE_USER_SCRIPT_SANDBOXING: NO
     postBuildScripts:
-      # ptzd et talkd dans Contents/Helpers, la plist embarquée de l'ancien agent de talkd dans Contents/Library/LaunchAgents
+      # ptzd, talkd, gardien et go2rtc (vérifié par son empreinte, spec B3 § 3.1) dans Contents/Helpers, la licence de
+      # go2rtc dans Contents/Resources, la plist embarquée de l'ancien agent de talkd dans Contents/Library/LaunchAgents
       # (depuis la 1.0.5 elle ne sert plus qu'à désinscrire l'agent inscrit par la 1.0.4 : l'agent de Talkback est
       # maintenant une plist classique que l'app écrit dans ~/Library/LaunchAgents, spec haut-parleur § 15), la source
       # d'obsbot-ai dans Contents/Resources ; jamais le SDK ni un binaire obsbot-ai dans le paquet (spec distribution
       # § 5.1). Toujours exécutée : swift build sait ce qui a changé dans mac/ptzd et mac/talkd.
-      - name: Utilitaires ptzd et talkd, plist embarquée de l'ancien agent de talkd et source d'obsbot-ai
+      - name: Utilitaires ptzd, talkd, gardien et go2rtc, plist embarquée de l'ancien agent de talkd et source d'obsbot-ai
         script: '"$SRCROOT/build-helpers.sh"'
         basedOnDependencyAnalysis: false
         inputFiles:
           - $(SRCROOT)/build-helpers.sh
           - $(SRCROOT)/../ai/main.cpp
           - $(SRCROOT)/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.talkd.plist
+          - $(SRCROOT)/go2rtc.sha256
+          - $(SRCROOT)/go2rtc-LICENSE.txt
         outputFiles:
           - $(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/ptzd
           - $(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/talkd
+          - $(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/gardien
+          - $(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/go2rtc
+          - $(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/go2rtc-LICENSE.txt
           - $(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.talkd.plist
           - $(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/obsbot-ai.cpp
 schemes:
PATCH
````

Créer `mac/app/PTZBot/PTZBot.entitlements` :

````xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.device.camera</key>
	<true/>
</dict>
</plist>
````

Ajouter les deux textes d'autorisation, traduits, au catalogue de l'Info.plist :

```bash
/usr/bin/python3 - mac/app/PTZBot/InfoPlist.xcstrings <<'PY'
import json, sys
chemin = sys.argv[1]
d = json.load(open(chemin, encoding='utf-8'))
for cle, fr, en in [
    ('NSCameraUsageDescription', "PTZBot diffuse l'image de votre caméra OBSBOT vers HomeKit et l'app iPhone.",
     "PTZBot streams the picture of your OBSBOT camera to HomeKit and the iPhone app."),
    ('NSMicrophoneUsageDescription', "PTZBot diffuse le son du micro de votre caméra OBSBOT vers HomeKit et l'app iPhone.",
     "PTZBot streams the sound of your OBSBOT camera's microphone to HomeKit and the iPhone app."),
]:
    d['strings'][cle] = {"extractionState": "manual", "localizations": {
        "en": {"stringUnit": {"state": "translated", "value": en}},
        "fr": {"stringUnit": {"state": "translated", "value": fr}}}}
open(chemin, 'w', encoding='utf-8').write(json.dumps(d, ensure_ascii=False, indent=2) + '\n')
PY
```

- [x] **Étape 7 : Compiler et vérifier le paquet**

Run : `(cd mac/app/PTZBotKit && swift test)`
Attendu : `Test run with 372 tests in 31 suites passed` (`AppCatalogTests` vérifie les deux nouveaux textes de l'Info.plist).

Run : `(cd mac/app && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build 2>&1 | grep -E "error:|warning:|BUILD" | grep -v appintents ; ./check-bundle.sh)`
Attendu : `** BUILD SUCCEEDED **` sans avertissement (la phase des utilitaires prend l'archive en cache, sans télécharger), puis, entre autres :

```
ok : Contents/Helpers/gardien
ok : Contents/Helpers/go2rtc
ok : Contents/Resources/go2rtc-LICENSE.txt
ok : go2rtc officiel (empreinte de …/mac/app/go2rtc.sha256)
ok : droit com.apple.security.device.camera
ok : droit com.apple.security.device.audio-input
ok : NSCameraUsageDescription
ok : NSMicrophoneUsageDescription
```

et `check-bundle.sh` sort à 0. Ne lancer ni l'app, ni go2rtc, ni le gardien du paquet.

- [x] **Étape 8 : Commit**

```bash
rm -rf mac/app/.build/Build mac/app/.build/Logs
git add outils/publication.py outils/publier.sh outils/tests/test_publication.py \
  mac/app/go2rtc.sha256 mac/app/go2rtc-LICENSE.txt mac/app/build-helpers.sh mac/app/check-bundle.sh mac/app/project.yml \
  mac/app/PTZBot/PTZBot.entitlements mac/app/PTZBot/InfoPlist.xcstrings
git commit -F - <<'MSG'
Paquet : go2rtc 1.9.14 vérifié par ses empreintes et le gardien dans Helpers ; droits caméra et micro ; publication qui les exige

<ligne Co-Authored-By du modèle>
MSG
```

---

### Tâche 10 : documentation, notes 1.1.0 et précisions de la spec

**But :** spec § 8. Le README, en anglais puis en français avec le même contenu : la section go2rtc est réécrite (go2rtc fourni par PTZBot, interrupteur éteint par défaut, ffmpeg de Homebrew, onglet « Caméra », import d'une configuration, autorisations, panneau, et le paragraphe du go2rtc à soi, puisque l'interrupteur éteint le laisse fonctionner) ; les prérequis, le premier lancement, le panneau, « Quitter », la compilation, le diagnostic, la désinstallation, le contenu et la licence suivent. Les notes de version 1.1.0, **English** puis **Français**. La spec reçoit son § 12 (les précisions de ce plan). La version passe à 1.1.0.

**Fichiers :**
- Modifier : `README.md`
- Modifier : `NOTES-VERSIONS.md`
- Modifier : `docs/superpowers/specs/2026-10-12-go2rtc-dans-ptzbot-design.md`
- Modifier : `mac/app/project.yml` (`MARKETING_VERSION: "1.1.0"`)

**Interfaces :**
- Consomme : les textes des tâches 7 et 8 (cités tels quels dans le README, en anglais et en français), les chemins et réglages des tâches 5 et 9.
- Produit : rien pour le code.

- [x] **Étape 1 : Le README**

````bash
git apply <<'PATCH'
diff --git a/README.md b/README.md
index 7ecc920..0bf4d3c 100644
--- a/README.md
+++ b/README.md
@@ -8,7 +8,7 @@
 
 Remotely control the gimbal of an OBSBOT Tiny 2 from an iPhone.
 
-The camera is plugged over USB into a Mac that already streams it with [go2rtc](https://github.com/AlexxIT/go2rtc), and to HomeKit through Homebridge. HomeKit cannot drive a pan/tilt/zoom: this project adds what is missing.
+The camera is plugged over USB into a Mac. PTZBot for Mac streams it with [go2rtc](https://github.com/AlexxIT/go2rtc), to HomeKit through Homebridge and to the iPhone app. HomeKit cannot drive a pan/tilt/zoom: this project adds what is missing.
 
 > Personal project, not affiliated with OBSBOT.
 
@@ -17,7 +17,7 @@ The camera is plugged over USB into a Mac that already streams it with [go2rtc](
 - **Mac side**: the **PTZBot for Mac** app, which contains `ptzd`, installs from the disk image of the published releases (see "Installing PTZBot for Mac"), then updates itself. It can also be built from source with `scripts/install-mac.sh`. The OBSBOT SDK is then installed from the app, which compiles `obsbot-ai` on the Mac.
 - **iOS app** (PTZBot): installs from Xcode onto the iPhone (see "iOS app" below).
 
-Design: [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [local access spec](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [discovery and QR code spec](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [Mac app spec](docs/superpowers/specs/2026-10-06-app-mac-design.md) · [ptzd in the app spec](docs/superpowers/specs/2026-10-07-ptzd-dans-app-design.md) · [distribution spec](docs/superpowers/specs/2026-10-08-distribution-design.md) · [Mac side plan](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [iOS app plan](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [local access plan](docs/superpowers/plans/2026-10-06-acces-local.md) · [discovery and QR code plan](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [Mac app plan](docs/superpowers/plans/2026-10-06-app-mac.md) · [feasibility tests](docs/spike/2026-10-05-faisabilite.md). The design documents are in French.
+Design: [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [local access spec](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [discovery and QR code spec](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [Mac app spec](docs/superpowers/specs/2026-10-06-app-mac-design.md) · [ptzd in the app spec](docs/superpowers/specs/2026-10-07-ptzd-dans-app-design.md) · [distribution spec](docs/superpowers/specs/2026-10-08-distribution-design.md) · [go2rtc in PTZBot spec](docs/superpowers/specs/2026-10-12-go2rtc-dans-ptzbot-design.md) · [Mac side plan](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [iOS app plan](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [local access plan](docs/superpowers/plans/2026-10-06-acces-local.md) · [discovery and QR code plan](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [Mac app plan](docs/superpowers/plans/2026-10-06-app-mac.md) · [feasibility tests](docs/spike/2026-10-05-faisabilite.md). The design documents are in French.
 
 ### Architecture
 
@@ -47,6 +47,7 @@ Requirements:
 - an Apple silicon Mac running macOS 15 or later;
 - Tailscale on the Mac to control the camera away from home (without it, `ptzd` only listens on 127.0.0.1 and on the local network);
 - OBSBOT Center closed: when open, it skews the tilt readback;
+- for the camera stream (go2rtc): ffmpeg from Homebrew (`brew install ffmpeg`);
 - for AI tracking only: the OBSBOT SDK, to request at [obsbot.com/sdk](https://www.obsbot.com/sdk), and Apple's developer tools (PTZBot offers to install them).
 
 Then:
@@ -56,7 +57,7 @@ Then:
 3. On first launch:
    - **Previous installation.** If the launchd agent `io.github.djoko-cli.obsbot-nacelle.ptzd` from an earlier version is there, PTZBot offers to replace it. **Replace** stops it, renames its plist to `.plist.bak`, moves the old binaries in `bin/` to the Trash and takes over the SDK in `lib/`. Paired iPhones and settings are kept. **Later** keeps the old `ptzd` (the panel shows "Previous installation"); the question comes back at the next launch.
    - **`config.json`.** If it is missing, PTZBot creates it with the Mac's Tailscale address, or on 127.0.0.1 only without Tailscale (the panel says so).
-   - **Permissions.** macOS asks for local network access for PTZBot (`ptzd` depends on it): answer **Allow**. At the iPhone's first connection, it may also ask whether `ptzd` may accept incoming connections: answer **Allow**. The question may come back after an update, because the binary changes.
+   - **Permissions.** macOS asks for local network access for PTZBot (`ptzd` depends on it): answer **Allow**. At the iPhone's first connection, it may also ask whether `ptzd` may accept incoming connections: answer **Allow**. The question may come back after an update, because the binary changes. When go2rtc is first turned on, macOS asks for camera access, then microphone access, for PTZBot: answer **Allow**.
 4. **OBSBOT SDK.** In the panel, **OBSBOT SDK › Install SDK…**: choose the `.zip` archive received from OBSBOT or its unzipped folder. A lone `libdev.dylib` is refused: the headers are needed to compile `obsbot-ai`. PTZBot takes `macos/arm64-release/libdev.dylib` and the `include/` folder next to `macos/`; the other copies of the library in the archive are listed and ignored. The window shows the architecture, the signature, the origin and the quarantine; **Allow This SDK** copies the library and the headers into `sdk/`, removes the quarantine from these copies only, compiles `obsbot-ai` with Apple's developer tools, then checks that it loads the SDK. Everything happens in one go: if any step fails, the previous SDK and `obsbot-ai` are kept, and the compiler output goes to `obsbot-ai-compilation.log`. Without the SDK, everything works except AI tracking.
    - **Developer tools.** Without them, the panel's SDK line and the **OBSBOT SDK** window offer **Install Developer Tools…** before any choice of SDK. The button starts Apple's installation (`xcode-select --install`), only when you click it: accept in Apple's window, then reopen the panel, or click **Check Again** in the window. An SDK already installed whose `obsbot-ai` must be recompiled shows "Tools required", with the same button.
    - **SDK installed by an earlier version.** An SDK copied without its headers (a single `libdev.dylib`) shows "Incomplete", with "Reinstall the SDK from its archive or folder: its headers are missing." under it: reinstall it from the archive.
@@ -77,9 +78,9 @@ Requirements: Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew
 scripts/install-mac.sh
 ```
 
-The script builds the app (`ptzd` and `talkd` in `Contents/Helpers`, the embedded plist of the old Talkback agent in `Contents/Library/LaunchAgents`, the `obsbot-ai` source in `Contents/Resources`, Sparkle in `Contents/Frameworks`), quits the running app, installs it into `~/Applications/PTZBot.app` and launches it. It touches neither launchd nor the files in `~/Library/Application Support/ObsbotNacelle/`. Such a build keeps build number 1: Sparkle never starts in it. Keep a single copy of PTZBot: to go back to the published releases, move `~/Applications/PTZBot.app` to the Trash and install the disk image.
+The script builds the app (`ptzd`, `talkd` and `gardien` in `Contents/Helpers`, with go2rtc 1.9.14 downloaded from its official releases and checked against `mac/app/go2rtc.sha256`, the embedded plist of the old Talkback agent in `Contents/Library/LaunchAgents`, the `obsbot-ai` source in `Contents/Resources`, Sparkle in `Contents/Frameworks`), quits the running app, installs it into `~/Applications/PTZBot.app` and launches it. It touches neither launchd nor the files in `~/Library/Application Support/ObsbotNacelle/`. Such a build keeps build number 1: Sparkle never starts in it. Keep a single copy of PTZBot: to go back to the published releases, move `~/Applications/PTZBot.app` to the Trash and install the disk image.
 
-`mac/app/check-bundle.sh` checks a Release build: `ptzd`, `talkd`, the embedded plist of the old Talkback agent, the `obsbot-ai` source and Sparkle are present; the SDK, its headers and any `obsbot-ai` binary are absent.
+`mac/app/check-bundle.sh` checks a Release build: `ptzd`, `talkd`, `gardien`, the official go2rtc binary and its license, the app's camera and microphone entitlements, the embedded plist of the old Talkback agent, the `obsbot-ai` source and Sparkle are present; the SDK, its headers and any `obsbot-ai` binary are absent.
 
 Publishing a release (maintainer): write its section in `NOTES-VERSIONS.md` (**English**, then **Français**), set `MARKETING_VERSION` in `mac/app/project.yml`, then run `outils/publier.sh X.Y.Z` from a clean, up-to-date `main`. If it stops halfway, resume from `gestes.txt` in the products folder, never by running the script again. `outils/publier.sh X.Y.Z --repetition FOLDER --url-base http://127.0.0.1:PORT …` rehearses everything without GitHub.
 
@@ -103,6 +104,7 @@ After a change, restart the service: in the panel, turn **ptzd service** off and
 | Need | Command |
 |---|---|
 | Service log | `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log` |
+| go2rtc log | `tail -f ~/Library/Logs/obsbot-nacelle/go2rtc.log` |
 | SDK output | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai.log` |
 | `obsbot-ai` compilation | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai-compilation.log` |
 | Read the camera position | `/Applications/PTZBot.app/Contents/Helpers/ptzd uvc get` |
@@ -123,11 +125,12 @@ It lives in the menu bar (the Tiny 2 icon), without a Dock icon, in English, or
 - the **ptzd service** switch, remembered from one launch to the next, and the state of `ptzd` ("Active", "Starting…", "Stopped", "Restarted after an unexpected stop (n)", "Not responding" with a link to its log) and of the camera. Beyond 5 stops in 2 min, PTZBot stops restarting `ptzd`: "ptzd keeps stopping: open the log". It does not restart it either if another `ptzd` is already running (`ptzd.lock` lock or 127.0.0.1 port taken: "Port 1985 is already in use…"), if `config.json` is invalid or if its arguments are refused;
 - the **OBSBOT SDK** line, with a short state on the right ("Ready", "Missing", "Quarantined", "Incompatible", "Does not load", "Tools required", "Incomplete", "Recompiling…", "Compile failed", "obsbot-ai not found"), and under it, on the full width, what it means and **Install SDK…**, **Install Developer Tools…** or, when the SDK is ready, **Change…**; until the SDK is ready, **AI tracking** is greyed out ("OBSBOT SDK required"), unless a previous `obsbot-ai` is still in use;
 - the **Privacy** and **AI tracking** switches (tracking shows the last order: the real state cannot be read, a gesture in front of the camera can change it);
-- the **Talkback** switch and, under it, the state of `talkd` ("Ready", "Starting…", "Playing", "Disabled", "Approval required", and the reason when it stops); it installs or removes the background agent (see "Talkback" below);
+- the **go2rtc** switch, off by default, right after `ptzd` (see "go2rtc" below);
+- the **Talkback** switch; it installs or removes the background agent (see "Talkback" below). Each service shows a green dot when everything is normal (`ptzd` active, go2rtc running, Talkback ready or playing, SDK ready); otherwise its status line ("Starting…", "Disabled", "Approval required", the reason when it stops…);
 - the connected clients, with **Kick Out**: the connection is cut and the device refused for 10 min (while `ptzd` runs), without losing its pairing;
 - **Pair an iPhone…**: the QR code as an image, valid for 5 min; closing the window cancels it;
 - **Devices…**: the paired devices, **Unblock** and **Remove…** (the device is removed and its connections cut right away);
-- **Check for Updates…** on its own line, then **Settings…** (**Check automatically**, **Install automatically**, **Open at login**, the version, for example "PTZBot 1.0.0 (412)"; macOS may ask for approval in System Settings › General › Login Items) and **Quit**: stops `ptzd` (6 s at most), then the app.
+- **Check for Updates…** on its own line, then **Settings…** (**Check automatically**, **Install automatically**, **Open at login**, the version, for example "PTZBot 1.0.0 (412)"; macOS may ask for approval in System Settings › General › Login Items) and **Quit**: stops `ptzd` and go2rtc (16 s at most), then the app; when go2rtc is on, a confirmation says that quitting PTZBot also stops the HomeKit camera.
 
 If local network access is denied to PTZBot, the panel says so, with a button to the privacy settings: iPhones then only find the Mac through Tailscale.
 
@@ -216,31 +219,17 @@ While someone speaks, the built-in speakers are raised to at least 30 % (or unmu
 
 ### go2rtc
 
-`ptzd` relays the video negotiation to go2rtc's API on 127.0.0.1: the API therefore no longer needs to be open to the network. Suggested configuration (in `go2rtc.yaml`, to adapt):
-
-```yaml
-api:
-  listen: "127.0.0.1:1984"
-rtsp:
-  listen: ":8554"
-  username: "<user>"
-  password: "<password>"
-webrtc:
-  listen: ":8555"
-ffmpeg:
-  bin: /opt/homebrew/bin/ffmpeg   # full path: under launchd, PATH does not contain /opt/homebrew/bin
-streams:
-  obsbot:
-    - exec:…   # camera video (H.264)
-    - exec:…   # camera microphone (AAC, for HomeKit)
-    - ffmpeg:obsbot#audio=opus   # the same sound in Opus, for PTZBot (WebRTC)
-```
-
-- go2rtc lets local clients (127.0.0.1) skip the RTSP password: `exec:` sources that publish to `{output}` keep working unchanged.
-- A network RTSP client, such as Homebridge, must then give the user and password in the stream address: `rtsp://<user>:<password>@<Mac>:8554/obsbot`.
-- WebRTC port 8555 stays open: without an offer negotiated by `ptzd`, it gives no image.
-- Sound in PTZBot: WebRTC does not carry AAC. The `ffmpeg:obsbot#audio=opus` source converts it to Opus as soon as PTZBot is open, even muted (the button only stops playback, so that sound comes back immediately). Without the `ffmpeg: bin:` line, go2rtc started by launchd does not find `ffmpeg` and the audio track stays silent, with no error message.
-- `go2rtc.yaml` holds the RTSP password: set it to mode 600 (`chmod 600 go2rtc.yaml`).
+PTZBot for Mac includes [go2rtc](https://github.com/AlexxIT/go2rtc) 1.9.14 (MIT license), which streams the camera to HomeKit (through Homebridge, in RTSP) and to the iPhone app (in WebRTC, through `ptzd`). go2rtc only runs while PTZBot is open, as its child process: **Quit** stops it, and the HomeKit camera with it. If PTZBot crashes, its small `gardien` helper stops go2rtc as well.
+
+- **Turning it on.** The **go2rtc** switch in the panel is off by default: it must not take the camera of someone who already runs their own go2rtc. Once on, go2rtc starts with PTZBot and restarts after an unexpected stop; beyond 5 stops in 2 min, PTZBot stops restarting it ("go2rtc keeps stopping: open the log").
+- **ffmpeg.** go2rtc needs Homebrew's ffmpeg, which PTZBot never includes (it is under the GPL): `brew install ffmpeg`. PTZBot looks for it at the path set in **Settings › Camera**, then in `/opt/homebrew/bin/ffmpeg`, then in `/usr/local/bin/ffmpeg`.
+- **Configuration.** PTZBot writes `~/Library/Application Support/ObsbotNacelle/go2rtc.yaml` (mode 600: it holds the RTSP password) from **Settings › Camera**: user name and password, resolution, frame rate and bitrate, camera and microphone (by default, the first OBSBOT ones found), RTSP (8554) and WebRTC (8555) ports. The API stays on `127.0.0.1:1984`, where `ptzd` relays the iPhone's video, and the stream is named `obsbot`. **Apply** rewrites the file and restarts go2rtc: the HomeKit stream stops for a few seconds.
+- **Existing configuration.** **Import an Existing Configuration…** reads a `go2rtc.yaml` (for example `/opt/homebrew/etc/go2rtc.yaml`, reachable with ⇧⌘G) and shows what it takes over: user name, password, ports and, when recognized, the device names and the ffmpeg path. The imported file is never modified. **Use a Custom Configuration File** runs go2rtc on your own file, which PTZBot never writes; ports and devices are then not checked.
+- **Permissions.** go2rtc's ffmpeg processes open the camera and the microphone on behalf of PTZBot: macOS asks once, for PTZBot. A refusal shows "Camera access denied" in the panel, with a button to the privacy settings.
+- **Panel.** A green dot when go2rtc runs normally; hovering over the row shows the clients by protocol ("2 clients · RTSP ×1, WebRTC ×1"). Otherwise a status line: "ffmpeg not found", "Port 8554 already in use: is another go2rtc running?", "OBSBOT camera not found", "Camera access denied", or, in orange, "coreaudiod is not responding: the camera is stuck", with **Copy the repair command** (`sudo killall -9 coreaudiod`, to run yourself in Terminal: PTZBot never runs it).
+- **Your own go2rtc.** With the switch off, PTZBot leaves go2rtc alone: a go2rtc you run yourself keeps working. Its API must then listen on `127.0.0.1:1984` and its stream be named `obsbot` (`go2rtcAPI` and `streamName` in `config.json`). Never two go2rtc at once: PTZBot does not start its own while the ports are taken.
+- A network RTSP client, such as Homebridge, gives the user name and password in the stream address: `rtsp://<user>:<password>@<Mac>:8554/obsbot`. go2rtc lets local clients (127.0.0.1) skip the password.
+- WebRTC port 8555 stays open: without an offer negotiated by `ptzd`, it gives no image. Sound in PTZBot: WebRTC does not carry AAC; the `ffmpeg:obsbot#audio=opus` source converts it to Opus as soon as PTZBot is open, even muted (the button only stops playback, so that sound comes back immediately).
 - The RTSP stream to Homebridge, credentials included, travels in clear on the local network: a device intercepting this traffic can read them, as well as the images.
 - The pairing QR code (PTZBot for Mac window, or `ptzd pair` and the URL shown under it) allows pairing a device for 5 minutes: only show it while scanning.
 - Never expose 127.0.0.1:1985 to the network, for example with `tailscale serve` or `ssh -L`: connections from 127.0.0.1 skip authentication, any remote client coming through there would control the camera.
@@ -249,7 +238,7 @@ streams:
 
 In PTZBot for Mac, turn off **Talkback** (its agent keeps running otherwise), **Settings…** › uncheck **Open at login**, then **Quit** (`ptzd` stops with the app), and move `/Applications/PTZBot.app` (or `~/Applications/PTZBot.app` for a build from source) to the Trash.
 
-The data stays in `~/Library/Application Support/ObsbotNacelle/` (settings, paired iPhones, SDK, its headers and `obsbot-ai`) and the logs in `~/Library/Logs/obsbot-nacelle/`, until you delete them:
+The data stays in `~/Library/Application Support/ObsbotNacelle/` (settings, paired iPhones, SDK, its headers, `obsbot-ai` and `go2rtc.yaml`) and the logs in `~/Library/Logs/obsbot-nacelle/`, until you delete them:
 
 ```bash
 rm -r ~/Library/Application\ Support/ObsbotNacelle ~/Library/Logs/obsbot-nacelle
@@ -263,9 +252,10 @@ After a migration, the old agent's plist stays at `~/Library/LaunchAgents/io.git
 |---|---|
 | `Packages/NacelleProtocol/` | Messages exchanged between the apps and `ptzd`, shared by both |
 | `mac/ptzd/` | The service: logic (`PTZCore`), pairing and authentication (`PTZAuth`), USB access (`CUVC`, `UVCCamera`), WebSocket server and local listener (`PTZServer`) |
+| `mac/gardien/` | The `gardien` helper: starts go2rtc as its child and stops it when PTZBot goes away, even after a crash |
 | `mac/talkd/` | The Talkback agent: `TalkCore` (tested logic, no real sound or network), the `talkd` executable (CoreAudio) and `talkd.example.json` |
 | `mac/ai/` | The `obsbot-ai` helper (C++): its source, shipped in the app and compiled on the user's Mac; `build.sh` builds it locally with the SDK in `vendor/`, for tests |
-| `mac/app/` | The PTZBot for Mac app: `project.yml` (xcodegen), interface (`PTZBot/`), tested logic (`PTZBotKit/`), helper build phase (`build-helpers.sh`), bundle check (`check-bundle.sh`) and update feed (`appcast.xml`, written at publication) |
+| `mac/app/` | The PTZBot for Mac app: `project.yml` (xcodegen), interface (`PTZBot/`), tested logic (`PTZBotKit/`), helper build phase (`build-helpers.sh`), bundle check (`check-bundle.sh`), go2rtc's checksums and license (`go2rtc.sha256`, `go2rtc-LICENSE.txt`) and update feed (`appcast.xml`, written at publication) |
 | `mac/tools/` | Test WebSocket client |
 | `ios/` | The iOS app: `project.yml` (xcodegen), sources and tests |
 | `outils/` | Publication of a release: `publier.sh`, `publication.py` and their tests, Sparkle's license |
@@ -276,7 +266,7 @@ After a migration, the old agent's plist stays at `~/Library/LaunchAgents/io.git
 
 ### License
 
-MIT. See [LICENSE](LICENSE). The disk image also carries the license of [Sparkle](https://sparkle-project.org) 2.10.0 (`outils/Sparkle-LICENSE.txt`).
+MIT. See [LICENSE](LICENSE). The disk image also carries the license of [Sparkle](https://sparkle-project.org) 2.10.0 (`outils/Sparkle-LICENSE.txt`), and the app the license of [go2rtc](https://github.com/AlexxIT/go2rtc) 1.9.14 (`Contents/Resources/go2rtc-LICENSE.txt`, MIT).
 
 <a id="francais"></a>
 
@@ -284,7 +274,7 @@ MIT. See [LICENSE](LICENSE). The disk image also carries the license of [Sparkle
 
 Piloter à distance la nacelle d'une OBSBOT Tiny 2 depuis l'iPhone.
 
-La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](https://github.com/AlexxIT/go2rtc), et vers HomeKit via Homebridge. HomeKit ne sait pas piloter un pan/tilt/zoom : ce projet ajoute ce qui manque.
+La caméra est branchée en USB sur un Mac. PTZBot pour Mac la diffuse avec [go2rtc](https://github.com/AlexxIT/go2rtc), vers HomeKit via Homebridge et vers l'app iPhone. HomeKit ne sait pas piloter un pan/tilt/zoom : ce projet ajoute ce qui manque.
 
 > Projet personnel, sans lien avec OBSBOT.
 
@@ -293,7 +283,7 @@ La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](h
 - **Côté Mac** : l'app **PTZBot pour Mac**, qui contient `ptzd`, s'installe depuis l'image disque des versions publiées (voir « Installer PTZBot pour Mac »), puis se met à jour seule. On peut aussi la compiler depuis les sources avec `scripts/install-mac.sh`. Le SDK OBSBOT s'installe ensuite depuis l'app, qui compile `obsbot-ai` sur le Mac.
 - **App iOS** (PTZBot) : s'installe depuis Xcode sur l'iPhone (voir « App iOS » plus bas).
 
-Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [spec de l'accès local](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [spec de la découverte et du QR code](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [spec de l'app Mac](docs/superpowers/specs/2026-10-06-app-mac-design.md) · [spec de ptzd dans l'app](docs/superpowers/specs/2026-10-07-ptzd-dans-app-design.md) · [spec de la distribution](docs/superpowers/specs/2026-10-08-distribution-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [plan de l'accès local](docs/superpowers/plans/2026-10-06-acces-local.md) · [plan de la découverte et du QR code](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [plan de l'app Mac](docs/superpowers/plans/2026-10-06-app-mac.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).
+Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [spec de l'accès local](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [spec de la découverte et du QR code](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [spec de l'app Mac](docs/superpowers/specs/2026-10-06-app-mac-design.md) · [spec de ptzd dans l'app](docs/superpowers/specs/2026-10-07-ptzd-dans-app-design.md) · [spec de la distribution](docs/superpowers/specs/2026-10-08-distribution-design.md) · [spec de go2rtc dans PTZBot](docs/superpowers/specs/2026-10-12-go2rtc-dans-ptzbot-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [plan de l'accès local](docs/superpowers/plans/2026-10-06-acces-local.md) · [plan de la découverte et du QR code](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [plan de l'app Mac](docs/superpowers/plans/2026-10-06-app-mac.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).
 
 ### Architecture
 
@@ -323,6 +313,7 @@ Prérequis :
 - un Mac Apple Silicon sous macOS 15 ou plus récent ;
 - Tailscale sur le Mac pour piloter hors de la maison (sans lui, `ptzd` n'écoute que sur 127.0.0.1 et sur le réseau local) ;
 - OBSBOT Center fermé : ouvert, il fausse la relecture du tilt ;
+- pour la diffusion de la caméra (go2rtc) : ffmpeg de Homebrew (`brew install ffmpeg`) ;
 - pour le suivi IA seulement : le SDK OBSBOT, à demander sur [obsbot.com/sdk](https://www.obsbot.com/sdk), et les outils de développement d'Apple (PTZBot propose de les installer).
 
 Puis :
@@ -332,7 +323,7 @@ Puis :
 3. Au premier lancement :
    - **Ancienne installation.** Si l'agent launchd `io.github.djoko-cli.obsbot-nacelle.ptzd` d'une version précédente est là, PTZBot propose de le remplacer. **Remplacer** l'arrête, renomme sa plist en `.plist.bak`, met les anciens binaires de `bin/` à la corbeille et reprend le SDK de `lib/`. Les iPhone appairés et les réglages sont conservés. **Plus tard** garde l'ancien `ptzd` (le panneau affiche « Ancienne installation ») ; la question revient au lancement suivant.
    - **`config.json`.** S'il manque, PTZBot le crée avec l'adresse Tailscale du Mac, ou sur 127.0.0.1 seulement sans Tailscale (le panneau le signale).
-   - **Autorisations.** macOS demande l'accès au réseau local pour PTZBot (`ptzd` en dépend) : répondre **Autoriser**. À la première connexion de l'iPhone, il peut aussi demander s'il faut autoriser `ptzd` à accepter des connexions entrantes : répondre **Autoriser**. La question peut revenir après une mise à jour, car le binaire change.
+   - **Autorisations.** macOS demande l'accès au réseau local pour PTZBot (`ptzd` en dépend) : répondre **Autoriser**. À la première connexion de l'iPhone, il peut aussi demander s'il faut autoriser `ptzd` à accepter des connexions entrantes : répondre **Autoriser**. La question peut revenir après une mise à jour, car le binaire change. Au premier allumage de go2rtc, macOS demande l'accès à la caméra, puis au micro, pour PTZBot : répondre **Autoriser**.
 4. **SDK OBSBOT.** Dans le panneau, **SDK OBSBOT › Installer le SDK…** : choisir l'archive `.zip` reçue d'OBSBOT ou son dossier décompressé. Un `libdev.dylib` seul est refusé : les en-têtes sont nécessaires pour compiler `obsbot-ai`. PTZBot prend `macos/arm64-release/libdev.dylib` et le dossier `include/` à côté de `macos/` ; les autres copies de la bibliothèque dans l'archive sont listées et ignorées. La fenêtre montre l'architecture, la signature, la provenance et la quarantaine ; **Autoriser ce SDK** copie la bibliothèque et les en-têtes dans `sdk/`, retire la quarantaine de ces copies seulement, compile `obsbot-ai` avec les outils de développement d'Apple, puis vérifie qu'il charge le SDK. Tout se fait d'un seul tenant : si une étape échoue, l'ancien SDK et l'ancien `obsbot-ai` restent, et la sortie du compilateur va dans `obsbot-ai-compilation.log`. Sans SDK, tout marche sauf le suivi IA.
    - **Outils de développement.** Sans eux, la ligne SDK du panneau et la fenêtre **SDK OBSBOT** proposent **Installer les outils de développement…** avant tout choix du SDK. Le bouton lance l'installation d'Apple (`xcode-select --install`), seulement quand on clique : accepter dans la fenêtre d'Apple, puis rouvrir le panneau, ou cliquer sur **Vérifier à nouveau** dans la fenêtre. Un SDK déjà installé dont `obsbot-ai` doit être recompilé affiche « Outils requis », avec le même bouton.
    - **SDK installé par une version précédente.** Un SDK copié sans ses en-têtes (un `libdev.dylib` seul) affiche « À compléter », avec dessous « Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent. » : le réinstaller depuis l'archive.
@@ -353,9 +344,9 @@ Prérequis : Xcode et [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew i
 scripts/install-mac.sh
 ```
 
-Le script compile l'app (`ptzd` et `talkd` dans `Contents/Helpers`, la plist embarquée de l'ancien agent de Talkback dans `Contents/Library/LaunchAgents`, la source d'`obsbot-ai` dans `Contents/Resources`, Sparkle dans `Contents/Frameworks`), ferme l'app en cours, l'installe dans `~/Applications/PTZBot.app` et la lance. Il ne touche ni à launchd ni aux fichiers de `~/Library/Application Support/ObsbotNacelle/`. Une telle compilation garde le numéro 1 : Sparkle n'y démarre jamais. Ne garder qu'une copie de PTZBot : pour revenir aux versions publiées, mettre `~/Applications/PTZBot.app` à la corbeille et installer l'image disque.
+Le script compile l'app (`ptzd`, `talkd` et `gardien` dans `Contents/Helpers`, avec go2rtc 1.9.14 téléchargé depuis ses versions officielles et vérifié par `mac/app/go2rtc.sha256`, la plist embarquée de l'ancien agent de Talkback dans `Contents/Library/LaunchAgents`, la source d'`obsbot-ai` dans `Contents/Resources`, Sparkle dans `Contents/Frameworks`), ferme l'app en cours, l'installe dans `~/Applications/PTZBot.app` et la lance. Il ne touche ni à launchd ni aux fichiers de `~/Library/Application Support/ObsbotNacelle/`. Une telle compilation garde le numéro 1 : Sparkle n'y démarre jamais. Ne garder qu'une copie de PTZBot : pour revenir aux versions publiées, mettre `~/Applications/PTZBot.app` à la corbeille et installer l'image disque.
 
-`mac/app/check-bundle.sh` vérifie une compilation Release : `ptzd`, `talkd`, la plist embarquée de l'ancien agent de Talkback, la source d'`obsbot-ai` et Sparkle sont là ; le SDK, ses en-têtes et tout binaire `obsbot-ai` sont absents.
+`mac/app/check-bundle.sh` vérifie une compilation Release : `ptzd`, `talkd`, `gardien`, le binaire officiel de go2rtc et sa licence, les droits caméra et micro de l'app, la plist embarquée de l'ancien agent de Talkback, la source d'`obsbot-ai` et Sparkle sont là ; le SDK, ses en-têtes et tout binaire `obsbot-ai` sont absents.
 
 Publier une version (mainteneur) : écrire sa section dans `NOTES-VERSIONS.md` (**English**, puis **Français**), régler `MARKETING_VERSION` dans `mac/app/project.yml`, puis lancer `outils/publier.sh X.Y.Z` depuis un `main` propre et à jour. Si elle s'arrête en route, la reprendre depuis `gestes.txt`, dans le dossier des produits, jamais en relançant le script. `outils/publier.sh X.Y.Z --repetition DOSSIER --url-base http://127.0.0.1:PORT …` répète tout sans GitHub.
 
@@ -379,6 +370,7 @@ Après une modification, relancer le service : dans le panneau, éteindre puis r
 | Besoin | Commande |
 |---|---|
 | Journal du service | `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log` |
+| Journal de go2rtc | `tail -f ~/Library/Logs/obsbot-nacelle/go2rtc.log` |
 | Sortie du SDK | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai.log` |
 | Compilation d'`obsbot-ai` | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai-compilation.log` |
 | Lire la position de la caméra | `/Applications/PTZBot.app/Contents/Helpers/ptzd uvc get` |
@@ -399,11 +391,12 @@ Elle vit dans la barre des menus (icône de la Tiny 2), sans icône dans le Dock
 - l'interrupteur **Service ptzd**, retenu d'un lancement à l'autre, et l'état de `ptzd` (« Actif », « Démarrage… », « Arrêté », « Relancé après un arrêt inattendu (n) », « Ne répond pas » avec un lien vers son journal) et de la caméra. Au-delà de 5 arrêts en 2 min, PTZBot cesse de relancer `ptzd` : « ptzd s'arrête sans cesse : ouvrez le journal ». Il ne le relance pas non plus si un autre `ptzd` tourne déjà (verrou `ptzd.lock` ou port de 127.0.0.1 pris : « Le port 1985 est déjà pris… »), si `config.json` est invalide ou si ses arguments sont refusés ;
 - la ligne **SDK OBSBOT**, avec un état court à droite (« Prêt », « Absent », « En quarantaine », « Incompatible », « Ne se charge pas », « Outils requis », « À compléter », « Recompilation… », « Compilation impossible », « obsbot-ai introuvable ») et dessous, sur toute la largeur, ce qu'il veut dire et **Installer le SDK…**, **Installer les outils de développement…** ou, quand le SDK est prêt, **Changer…** ; tant que le SDK n'est pas prêt, **Suivi IA** est grisé (« SDK OBSBOT requis »), sauf si un ancien `obsbot-ai` reste en service ;
 - les interrupteurs **Vie privée** et **Suivi IA** (le suivi affiche le dernier ordre : l'état réel ne se lit pas, un geste devant la caméra peut le changer) ;
-- l'interrupteur **Talkback** et, dessous, l'état de `talkd` (« Prêt », « Démarrage… », « En lecture », « Désactivé », « Autorisation requise », et la raison quand il s'arrête) ; il installe ou retire l'agent en arrière-plan (voir « Talkback » plus bas) ;
+- l'interrupteur **go2rtc**, éteint par défaut, juste après `ptzd` (voir « go2rtc » plus bas) ;
+- l'interrupteur **Talkback** ; il installe ou retire l'agent en arrière-plan (voir « Talkback » plus bas). Chaque service montre une pastille verte quand tout est normal (`ptzd` actif, go2rtc en marche, Talkback prêt ou en lecture, SDK prêt) ; sinon sa ligne d'état (« Démarrage… », « Désactivé », « Autorisation requise », la raison quand il s'arrête…) ;
 - les clients connectés, avec **Expulser** : la connexion est coupée et l'appareil refusé 10 min (tant que `ptzd` tourne), sans perdre son appairage ;
 - **Appairer un iPhone…** : le QR code en image, valable 5 min ; fermer la fenêtre l'annule ;
 - **Appareils…** : les appareils appairés, **Débloquer** et **Retirer…** (l'appareil est retiré et ses connexions coupées tout de suite) ;
-- **Rechercher les mises à jour…** sur sa propre ligne, puis **Réglages…** (**Rechercher automatiquement**, **Installer automatiquement**, **Ouvrir à la connexion**, la version, par exemple « PTZBot 1.0.0 (412) » ; macOS peut demander un accord dans Réglages › Général › Ouverture) et **Quitter** : arrête `ptzd` (6 s au plus), puis l'app.
+- **Rechercher les mises à jour…** sur sa propre ligne, puis **Réglages…** (**Rechercher automatiquement**, **Installer automatiquement**, **Ouvrir à la connexion**, la version, par exemple « PTZBot 1.0.0 (412) » ; macOS peut demander un accord dans Réglages › Général › Ouverture) et **Quitter** : arrête `ptzd` et go2rtc (16 s au plus), puis l'app ; quand go2rtc est allumé, une confirmation dit que quitter PTZBot arrête aussi la caméra HomeKit.
 
 Si l'accès au réseau local est refusé à PTZBot, le panneau l'indique, avec un bouton vers les réglages de confidentialité : les iPhone ne trouvent alors le Mac que par Tailscale.
 
@@ -492,31 +485,17 @@ Pendant la parole, les haut-parleurs intégrés sont remontés à 30 % au moins
 
 ### go2rtc
 
-`ptzd` relaie la négociation vidéo à l'API de go2rtc sur 127.0.0.1 : l'API n'a donc plus besoin d'être ouverte au réseau. Configuration conseillée (dans `go2rtc.yaml`, à adapter) :
-
-```yaml
-api:
-  listen: "127.0.0.1:1984"
-rtsp:
-  listen: ":8554"
-  username: "<identifiant>"
-  password: "<mot de passe>"
-webrtc:
-  listen: ":8555"
-ffmpeg:
-  bin: /opt/homebrew/bin/ffmpeg   # chemin complet : sous launchd, le PATH ne contient pas /opt/homebrew/bin
-streams:
-  obsbot:
-    - exec:…   # vidéo de la caméra (H.264)
-    - exec:…   # micro de la caméra (AAC, pour HomeKit)
-    - ffmpeg:obsbot#audio=opus   # le même son en Opus, pour PTZBot (WebRTC)
-```
-
-- go2rtc dispense les clients locaux (127.0.0.1) du mot de passe RTSP : les sources `exec:` qui publient sur `{output}` continuent de fonctionner sans changement.
-- Un client RTSP du réseau, comme Homebridge, doit alors donner l'identifiant et le mot de passe dans l'adresse du flux : `rtsp://<identifiant>:<mot de passe>@<Mac>:8554/obsbot`.
-- Le port WebRTC 8555 reste ouvert : sans offre négociée par `ptzd`, il ne donne aucune image.
-- Son dans PTZBot : WebRTC ne transporte pas l'AAC. La source `ffmpeg:obsbot#audio=opus` le convertit en Opus dès que PTZBot est ouvert, même son coupé (le bouton ne fait que couper la lecture, pour que le son revienne tout de suite). Sans la ligne `ffmpeg: bin:`, go2rtc lancé par launchd ne trouve pas `ffmpeg` et la piste audio reste muette, sans message d'erreur.
-- `go2rtc.yaml` contient le mot de passe RTSP : le passer en droits 600 (`chmod 600 go2rtc.yaml`).
+PTZBot pour Mac contient [go2rtc](https://github.com/AlexxIT/go2rtc) 1.9.14 (licence MIT), qui diffuse la caméra vers HomeKit (via Homebridge, en RTSP) et vers l'app iPhone (en WebRTC, par `ptzd`). go2rtc ne tourne que pendant que PTZBot est ouvert, comme processus enfant : **Quitter** l'arrête, et la caméra HomeKit avec lui. Si PTZBot plante, son petit utilitaire `gardien` arrête go2rtc lui aussi.
+
+- **L'allumer.** L'interrupteur **go2rtc** du panneau est éteint par défaut : il ne doit pas prendre la caméra de quelqu'un qui a déjà son go2rtc. Allumé, go2rtc démarre avec PTZBot et repart après un arrêt inattendu ; au-delà de 5 arrêts en 2 min, PTZBot cesse de le relancer (« go2rtc s'arrête sans cesse : ouvrez le journal »).
+- **ffmpeg.** go2rtc a besoin du ffmpeg de Homebrew, que PTZBot ne fournit jamais (il est sous GPL) : `brew install ffmpeg`. PTZBot le cherche au chemin réglé dans **Réglages › Caméra**, puis dans `/opt/homebrew/bin/ffmpeg`, puis dans `/usr/local/bin/ffmpeg`.
+- **Configuration.** PTZBot écrit `~/Library/Application Support/ObsbotNacelle/go2rtc.yaml` (droits 600 : il contient le mot de passe RTSP) d'après **Réglages › Caméra** : identifiant et mot de passe, résolution, cadence et débit, caméra et micro (par défaut, les premiers OBSBOT trouvés), ports RTSP (8554) et WebRTC (8555). L'API reste sur `127.0.0.1:1984`, où `ptzd` relaie la vidéo de l'iPhone, et le flux s'appelle `obsbot`. **Appliquer** réécrit le fichier et relance go2rtc : le flux HomeKit est coupé quelques secondes.
+- **Configuration existante.** **Importer une configuration existante…** lit un `go2rtc.yaml` (par exemple `/opt/homebrew/etc/go2rtc.yaml`, joignable par ⇧⌘G) et montre ce qu'il reprend : identifiant, mot de passe, ports et, s'ils sont reconnus, les noms des appareils et le chemin de ffmpeg. Le fichier importé n'est jamais modifié. **Utiliser un fichier de configuration personnalisé** lance go2rtc sur votre propre fichier, que PTZBot n'écrit jamais ; ports et appareils ne sont alors pas vérifiés.
+- **Autorisations.** Les ffmpeg de go2rtc ouvrent la caméra et le micro au nom de PTZBot : macOS demande une seule fois, pour PTZBot. Un refus affiche « Accès à la caméra refusé » dans le panneau, avec un bouton vers les réglages de confidentialité.
+- **Panneau.** Une pastille verte quand go2rtc tourne normalement ; le survol de la rangée montre les clients par protocole (« 2 clients · RTSP ×1, WebRTC ×1 »). Sinon une ligne d'état : « ffmpeg introuvable », « Port 8554 déjà utilisé : un autre go2rtc tourne-t-il ? », « Caméra OBSBOT absente », « Accès à la caméra refusé », ou, en orange, « coreaudiod ne répond pas : la caméra est bloquée », avec **Copier la commande de réparation** (`sudo killall -9 coreaudiod`, à lancer soi-même dans le Terminal : PTZBot ne la lance jamais).
+- **Son propre go2rtc.** Interrupteur éteint, PTZBot ne touche pas à go2rtc : un go2rtc lancé par ailleurs continue de fonctionner. Son API doit alors écouter sur `127.0.0.1:1984` et son flux s'appeler `obsbot` (`go2rtcAPI` et `streamName` dans `config.json`). Jamais deux go2rtc à la fois : PTZBot ne lance pas le sien tant que les ports sont pris.
+- Un client RTSP du réseau, comme Homebridge, donne l'identifiant et le mot de passe dans l'adresse du flux : `rtsp://<identifiant>:<mot de passe>@<Mac>:8554/obsbot`. go2rtc dispense les clients locaux (127.0.0.1) du mot de passe.
+- Le port WebRTC 8555 reste ouvert : sans offre négociée par `ptzd`, il ne donne aucune image. Son dans PTZBot : WebRTC ne transporte pas l'AAC ; la source `ffmpeg:obsbot#audio=opus` le convertit en Opus dès que PTZBot est ouvert, même son coupé (le bouton ne fait que couper la lecture, pour que le son revienne tout de suite).
 - Le flux RTSP vers Homebridge, identifiants compris, circule en clair sur le réseau local : un appareil qui intercepte ce trafic peut les lire, ainsi que les images.
 - Le QR code d'appairage (fenêtre de PTZBot pour Mac, ou `ptzd pair` et l'URL affichée sous lui) permet d'appairer un appareil pendant 5 minutes : ne l'afficher que le temps du scan.
 - Ne jamais exposer 127.0.0.1:1985 au réseau, par exemple avec `tailscale serve` ou `ssh -L` : les connexions venues de 127.0.0.1 sont dispensées d'authentification, tout client distant passé par là piloterait la caméra.
@@ -525,7 +504,7 @@ streams:
 
 Dans PTZBot pour Mac, éteindre **Talkback** (sinon son agent continue de tourner), **Réglages…** › décocher **Ouvrir à la connexion**, puis **Quitter** (`ptzd` s'arrête avec l'app), et mettre `/Applications/PTZBot.app` (ou `~/Applications/PTZBot.app` pour une compilation depuis les sources) à la corbeille.
 
-Les données restent dans `~/Library/Application Support/ObsbotNacelle/` (réglages, iPhone appairés, SDK, ses en-têtes et `obsbot-ai`) et les journaux dans `~/Library/Logs/obsbot-nacelle/`, tant qu'on ne les supprime pas :
+Les données restent dans `~/Library/Application Support/ObsbotNacelle/` (réglages, iPhone appairés, SDK, ses en-têtes, `obsbot-ai` et `go2rtc.yaml`) et les journaux dans `~/Library/Logs/obsbot-nacelle/`, tant qu'on ne les supprime pas :
 
 ```bash
 rm -r ~/Library/Application\ Support/ObsbotNacelle ~/Library/Logs/obsbot-nacelle
@@ -539,9 +518,10 @@ Après une migration, la plist de l'ancien agent reste en `~/Library/LaunchAgent
 |---|---|
 | `Packages/NacelleProtocol/` | Messages échangés entre les apps et `ptzd`, partagés par les deux |
 | `mac/ptzd/` | Le service : logique (`PTZCore`), appairage et authentification (`PTZAuth`), accès USB (`CUVC`, `UVCCamera`), serveur WebSocket et écoute locale (`PTZServer`) |
+| `mac/gardien/` | L'utilitaire `gardien` : lance go2rtc comme enfant et l'arrête quand PTZBot disparaît, même après un plantage |
 | `mac/talkd/` | L'agent Talkback : `TalkCore` (logique testée, sans son ni réseau réels), l'exécutable `talkd` (CoreAudio) et `talkd.example.json` |
 | `mac/ai/` | L'utilitaire `obsbot-ai` (C++) : sa source, livrée dans l'app et compilée sur le Mac de l'utilisateur ; `build.sh` le compile en local avec le SDK de `vendor/`, pour les essais |
-| `mac/app/` | L'app PTZBot pour Mac : `project.yml` (xcodegen), interface (`PTZBot/`), logique testée (`PTZBotKit/`), phase des utilitaires (`build-helpers.sh`), vérification du paquet (`check-bundle.sh`) et flux des mises à jour (`appcast.xml`, écrit à la publication) |
+| `mac/app/` | L'app PTZBot pour Mac : `project.yml` (xcodegen), interface (`PTZBot/`), logique testée (`PTZBotKit/`), phase des utilitaires (`build-helpers.sh`), vérification du paquet (`check-bundle.sh`), empreintes et licence de go2rtc (`go2rtc.sha256`, `go2rtc-LICENSE.txt`) et flux des mises à jour (`appcast.xml`, écrit à la publication) |
 | `mac/tools/` | Client WebSocket de test |
 | `ios/` | L'app iOS : `project.yml` (xcodegen), sources et tests |
 | `outils/` | Publication d'une version : `publier.sh`, `publication.py` et leurs tests, licence de Sparkle |
@@ -552,4 +532,4 @@ Après une migration, la plist de l'ancien agent reste en `~/Library/LaunchAgent
 
 ### Licence
 
-MIT. Voir [LICENSE](LICENSE). L'image disque porte aussi la licence de [Sparkle](https://sparkle-project.org) 2.10.0 (`outils/Sparkle-LICENSE.txt`).
+MIT. Voir [LICENSE](LICENSE). L'image disque porte aussi la licence de [Sparkle](https://sparkle-project.org) 2.10.0 (`outils/Sparkle-LICENSE.txt`), et l'app celle de [go2rtc](https://github.com/AlexxIT/go2rtc) 1.9.14 (`Contents/Resources/go2rtc-LICENSE.txt`, MIT).
PATCH
````

- [x] **Étape 2 : Les notes de version 1.1.0**

````bash
git apply <<'PATCH'
diff --git a/NOTES-VERSIONS.md b/NOTES-VERSIONS.md
index 8700dad..958ef4d 100644
--- a/NOTES-VERSIONS.md
+++ b/NOTES-VERSIONS.md
@@ -6,6 +6,30 @@ release and to the update window.
 PTZBot pour Mac. Chaque section a un bloc **English**, puis un bloc **Français** ; les mêmes notes servent à la
 version GitHub et à la fenêtre de mise à jour.
 
+## 1.1.0
+
+**English**
+
+- go2rtc is now part of PTZBot: turn on **go2rtc** in the panel (off by default) and PTZBot streams the camera to
+  HomeKit and to the iPhone app while it is open. Its settings are in the new **Settings › Camera** tab, where an
+  existing go2rtc configuration can be imported.
+- go2rtc needs ffmpeg, which PTZBot does not include: install it with Homebrew (`brew install ffmpeg`).
+- The first time, macOS asks for camera access, then microphone access, for PTZBot: choose "Allow".
+- When go2rtc is on, quitting PTZBot also stops the HomeKit camera; PTZBot asks for confirmation first.
+- In the panel, each service shows a green dot when everything is normal; a status line appears only when something
+  needs attention.
+
+**Français**
+
+- go2rtc fait désormais partie de PTZBot : allumez **go2rtc** dans le panneau (éteint par défaut), et PTZBot diffuse
+  la caméra vers HomeKit et vers l'app iPhone tant qu'il est ouvert. Ses réglages sont dans le nouvel onglet
+  **Réglages › Caméra**, où une configuration go2rtc existante peut être importée.
+- go2rtc a besoin de ffmpeg, que PTZBot ne fournit pas : installez-le avec Homebrew (`brew install ffmpeg`).
+- La première fois, macOS demande l'accès à la caméra, puis au micro, pour PTZBot : choisissez « Autoriser ».
+- Quand go2rtc est allumé, quitter PTZBot arrête aussi la caméra HomeKit ; PTZBot demande d'abord confirmation.
+- Dans le panneau, chaque service montre une pastille verte quand tout est normal ; une ligne d'état n'apparaît que
+  quand il faut y prêter attention.
+
 ## 1.0.7
 
 **English**
PATCH
````

- [x] **Étape 3 : Les précisions de la spec (§ 12)**

````bash
git apply <<'PATCH'
diff --git a/docs/superpowers/specs/2026-10-12-go2rtc-dans-ptzbot-design.md b/docs/superpowers/specs/2026-10-12-go2rtc-dans-ptzbot-design.md
index 871afe6..b23c7d5 100644
--- a/docs/superpowers/specs/2026-10-12-go2rtc-dans-ptzbot-design.md
+++ b/docs/superpowers/specs/2026-10-12-go2rtc-dans-ptzbot-design.md
@@ -268,3 +268,31 @@ Aucun label personnel n'entre dans le code public : la migration est un geste de
   le cas, le gardien peut demander une priorité plus haute (`setpriority`, QoS) pour go2rtc.
 - **coreaudiod** : le va-et-vient de clients CoreAudio reste le déclencheur suspecté. `preload` et l'arrêt en douceur
   le limitent ; le détecteur le signale.
+
+## 12. Précisions du plan (12/10/2026)
+
+Le [plan](../plans/2026-10-12-go2rtc-dans-ptzbot.md) précise la spec sur ces points, sans en changer les choix.
+
+- **Délais d'arrêt (§ 3.3).** Le gardien reçoit `--arret 10` : il laisse 10 s à go2rtc entre SIGTERM et SIGKILL. Le
+  superviseur n'envoie SIGKILL au gardien lui-même qu'à 15 s, et « Quitter » attend 16 s au plus (6 s sans go2rtc).
+  Le gardien rend la fin de go2rtc : son code de sortie, ou le même signal.
+- **Noms des appareils (§ 3.6).** go2rtc découpe la commande d'ffmpeg sans échappement (`shell.QuoteSplit`) et coupe
+  la source au premier `#`. Un nom est donc écrit entre guillemets doubles, ou simples s'il contient un guillemet
+  double ; un nom avec les deux sortes de guillemets, un `#` ou un caractère de contrôle est refusé, avec un message.
+  Le choix par défaut préfère une OBSBOT réelle à une caméra virtuelle (l'extension d'OBSBOT Center porte aussi le
+  nom « OBSBOT »).
+- **Réglages (§ 4 et § 6.2).** Un seul réglage de débit : le plafond vaut 1,5 fois le débit, le tampon la moitié
+  (4 Mb/s donne 6 et 2, comme le pipeline en service). Résolutions proposées : 1920 × 1080 et 1280 × 720 ; cadences :
+  30, 25 et 15 i/s. Sans yaml, PTZBot tire un mot de passe RTSP de 20 caractères ; un identifiant ou un mot de passe
+  vide est refusé (le flux serait ouvert à tout le réseau local). Les ports vont de 1024 à 65535, tous différents.
+- **Modèle (§ 4).** `#timeout=30s` est gardé tel quel, comme dans le pipeline en service, bien que go2rtc 1.9.14 lise
+  `starttimeout` (30 s par défaut) : aucun changement de comportement.
+- **Pannes (§ 5).** Les ports vérifiés : RTSP en TCP, WebRTC en TCP et en UDP, l'API sur 127.0.0.1:1984. Le refus
+  d'accès est repéré dans `go2rtc.log` (lignes d'erreur de go2rtc qui citent avfoundation ou exec avec « not
+  authorized », « denied » ou « Failed to create AV capture input device ») ; l'essai jetable de la tâche 0 relève la
+  ligne réelle. Le journal est relu toutes les 10 s tant que go2rtc tourne, l'API et les processus seulement panneau
+  ouvert. Talkback « En lecture » compte comme état normal (pastille verte).
+- **Publication (§ 8).** `outils/publication.py` gagne `--droit-requis` (les droits caméra et micro sont exigés sur
+  l'app, et, sans bac à sable, aucun autre n'est admis) et `--empreintes-go2rtc` : `Contents/Helpers/go2rtc` doit
+  être le binaire officiel, vérifié par son empreinte avant toute signature ; seul ce binaire peut porter des adresses
+  au contrôle de fuite du .dmg. `mac/app/go2rtc.sha256` donne l'empreinte de l'archive et celle du binaire.
PATCH
````

- [x] **Étape 4 : La version 1.1.0**

````bash
git apply <<'PATCH'
diff --git a/mac/app/project.yml b/mac/app/project.yml
index 187ed3c..ccd44b6 100644
--- a/mac/app/project.yml
+++ b/mac/app/project.yml
@@ -72,7 +72,7 @@ targets:
         ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
         # La version publiée (outils/publier.sh) ; le numéro de compilation, que compare Sparkle, est donné à la
         # publication : le nombre de commits de main. Une compilation de travail garde 1 : Sparkle n'y démarre pas.
-        MARKETING_VERSION: "1.0.7"
+        MARKETING_VERSION: "1.1.0"
         CURRENT_PROJECT_VERSION: "1"
         # Le flux des mises à jour (appcast.xml du dépôt, que publier.sh tient à jour, à son adresse brute) et la clé
         # publique ; la répétition les remplace en ligne de commande.
PATCH
````

- [x] **Étape 5 : Vérifier**

Run : `git status --short`
Attendu : seuls les quatre fichiers de la tâche, modifiés.

Contrôle de fuite de toute la branche et du travail en cours (adresses, chemins personnels, noms Tailscale), depuis le commit de ce plan :

```bash
BASE="$(git log --format=%H -1 -- docs/superpowers/plans/2026-10-12-go2rtc-dans-ptzbot.md)"
git diff "$BASE" -- . ':!mac/app/go2rtc-LICENSE.txt' ':!mac/app/go2rtc.sha256' | grep -E '^\+' \
  | grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|/Users/[A-Za-z]|\.ts\.net|/private/tmp' \
  | grep -vE '127\.0\.0\.1|0\.0\.0\.0|192\.168\.0\.|mac\.exemple\.ts\.net|mon-mac\.tailnet\.ts\.net'
```

Attendu : aucune ligne.

Run : les quatre commandes de vérification des contraintes globales.
Attendu : gardien 12 tests, PTZBotKit 372 tests, `** BUILD SUCCEEDED **` et `check-bundle.sh` à 0, publication `Ran 156 tests` `OK`.

- [x] **Étape 6 : Commit**

```bash
rm -rf mac/gardien/.build mac/app/PTZBotKit/.build mac/app/.build/Build mac/app/.build/Logs
git add README.md NOTES-VERSIONS.md docs/superpowers/specs/2026-10-12-go2rtc-dans-ptzbot-design.md mac/app/project.yml
git commit -F - <<'MSG'
go2rtc dans PTZBot : README bilingue, notes 1.1.0, précisions de la spec (§ 12), version 1.1.0

<ligne Co-Authored-By du modèle>
MSG
```

---

## Après les tâches : avec Majid

Rien de ce qui suit n'est fait par un agent d'exécution.

- [x] **Relecture finale de la branche** (Opus), puis fusion dans `main` avec l'accord de Majid. Deux relectures finales (12/10, puis 13/10 après le banc) ; fusion c551e43 le 13/10.
- **Banc** (spec § 10), le 13/10 (builds 248 à 261) :
  - [x] quitter et relancer PTZBot : go2rtc et ses ffmpeg s'arrêtent sans SIGKILL, puis repartent sans « port déjà utilisé » ;
  - [x] `kill -9` de PTZBot : le gardien arrête go2rtc et les ffmpeg, et la relance rapide passe ;
  - [x] priorité de go2rtc : son et image sans saccade (HomeKit, app iOS) ;
  - [x] bouton « Effets vidéo » absent, une fois le gardien lancé par launchd (spec § 14) ;
  - [ ] débrancher puis rebrancher la caméra ;
  - [ ] refuser puis accorder l'accès à la caméra ;
  - [ ] fichier personnalisé ;
  - [x] pas de nouvelle demande d'accès après une mise à jour par Sparkle : 1.0.7 de GitHub vers 1.1.0 (build 269), le 13/10. go2rtc repart, sans demande d'accès ni bouton « Effets vidéo ».
- [x] **Mise en service chez Majid**, le 13/10 (spec § 7, « jamais deux go2rtc en même temps » à chaque étape) :
  1. installer la 1.1.0 : go2rtc est éteint par défaut, l'ancien agent `com.majid.go2rtc` tourne toujours ;
  2. dans **Réglages › Caméra**, importer `/opt/homebrew/etc/go2rtc.yaml`, vérifier ce qui est repris, puis **Appliquer** : rien n'est lancé tant que l'interrupteur est éteint ;
  3. Majid, lui-même (réglage système) : `launchctl bootout gui/$(id -u)/com.majid.go2rtc`, puis la plist renommée en `.bak` ;
  4. aussitôt, allumer go2rtc dans PTZBot et accepter les demandes d'accès à la caméra et au micro ;
  5. vérifier HomeKit (image et son), l'app iOS (vidéo WebRTC et son), l'absence de redémarrage en boucle des ffmpeg, un seul ffmpeg vidéo, coreaudiod sain ;
  6. prévenir la session go2rtc : ses scripts de collecte cherchent go2rtc par le label launchd (`G2W_LABEL`) et devront chercher le processus `…/PTZBot.app/Contents/Helpers/go2rtc` ; le script `cam` devient obsolète.
- [x] **Publication de la 1.1.0** (`outils/publier.sh 1.1.0`), le 13/10 : build 269, version `ptzbot-v1.1.0`, flux af4e90f.

## Questions ouvertes pour Majid

1. **Le pipeline du yaml.** Le modèle (tâche 2) reprend le brief de passation du 04/10 (`-thread_queue_size`, `-level 4.0`, `-color_range mpeg`, `-r 30`, débit 4M/6M/2M, `aresample=async=1000:first_pts=0`, AAC 48 kHz stéréo 128k), avec les correctifs depuis (`- >-`, `preload`, `ffmpeg.bin`). Le yaml en service n'a pas été lu (il contient le mot de passe). Un écart avec le fichier réel se verra à l'étape 2 de la mise en service, où l'import montre ce qu'il reprend, mais pas les options d'ffmpeg : à comparer d'un œil avant d'appliquer.
2. **Le micro dans l'essai de la tâche 0** : ne pas l'essayer (par défaut), essayer un autre micro, ou le micro OBSBOT malgré le risque pour coreaudiod ?
3. **Le refus d'accès** est repéré dans le journal, au niveau `info`. Si l'essai montre que go2rtc n'y écrit rien de reconnaissable, faut-il ajouter `exec: debug` au yaml (plus de lignes dans `go2rtc.log`), ou se contenter de « Caméra OBSBOT absente » (aucun producteur actif) ?
4. **L'identifiant par défaut** d'un nouvel utilisateur est `ptzbot` (le mot de passe est tiré au hasard). Un autre nom ?
