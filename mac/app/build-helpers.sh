#!/bin/bash
# Phase de construction de PTZBot (project.yml) : compile ptzd, talkd et le gardien et les copie dans Contents/Helpers,
# y place go2rtc 1.9.14, l'archive officielle vérifiée par son empreinte (spec B3 § 3.1), et sa licence dans
# Contents/Resources, copie la
# plist embarquée de l'ancien agent de talkd dans Contents/Library/LaunchAgents (spec haut-parleur § 7 et § 15), copie la source d'obsbot-ai
# (mac/ai/main.cpp) dans Contents/Resources/obsbot-ai.cpp, puis refuse le paquet s'il contient le SDK OBSBOT, ses
# en-têtes ou un binaire obsbot-ai (spec distribution § 5.1). obsbot-ai est compilé sur le Mac de
# l'utilisateur, avec le SDK qu'il fournit (spec distribution § 6) : la construction n'a plus besoin du SDK.
set -euo pipefail

ROOT="$(cd "$SRCROOT/../.." && pwd)"
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"

mkdir -p "$HELPERS" "$RESOURCES"

# swift build hors de l'environnement de Xcode, dont les variables (SDKROOT, ARCHS…) le dérouteraient.
echo "Compilation de ptzd…"
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/ptzd" --product ptzd
BIN="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/ptzd" --show-bin-path)"
install -m 755 "$BIN/ptzd" "$HELPERS/ptzd"
# Compilation de publication (DEPLOYMENT_POSTPROCESSING, outils/publier.sh) : ptzd perd ses symboles de débogage,
# comme l'app (STRIP_INSTALLED_PRODUCT) ; ils nomment les fichiers objets de mac/ptzd/.build, sous le dossier
# personnel. La publication le signe ensuite avec son certificat ; d'ici là, signature locale.
if [ "${DEPLOYMENT_POSTPROCESSING:-NO}" = "YES" ]; then
    /usr/bin/xcrun strip -S "$HELPERS/ptzd"
    /usr/bin/codesign --force --sign - "$HELPERS/ptzd"
fi

# talkd (retour audio de la caméra, spec haut-parleur), de la même façon que ptzd.
echo "Compilation de talkd…"
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/talkd" --product talkd
TALKD_BIN="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/talkd" --show-bin-path)"
install -m 755 "$TALKD_BIN/talkd" "$HELPERS/talkd"
if [ "${DEPLOYMENT_POSTPROCESSING:-NO}" = "YES" ]; then
    /usr/bin/xcrun strip -S "$HELPERS/talkd"
    /usr/bin/codesign --force --sign - "$HELPERS/talkd"
fi

# Le gardien (spec B3 § 3.2), qui lance go2rtc et l'arrête si PTZBot disparaît, de la même façon que ptzd.
echo "Compilation du gardien…"
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/gardien" --product gardien
GARDIEN_BIN="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/gardien" --show-bin-path)"
install -m 755 "$GARDIEN_BIN/gardien" "$HELPERS/gardien"
if [ "${DEPLOYMENT_POSTPROCESSING:-NO}" = "YES" ]; then
    /usr/bin/xcrun strip -S "$HELPERS/gardien"
    /usr/bin/codesign --force --sign - "$HELPERS/gardien"
fi

# go2rtc 1.9.14 (spec B3 § 3.1) : l'archive macOS arm64 des versions officielles d'AlexxIT/go2rtc, gardée en cache
# (GO2RTC_CACHE, par défaut mac/app/.build/go2rtc, hors du dépôt) et vérifiée par son empreinte à chaque construction ;
# le binaire extrait l'est aussi. Toute autre empreinte est refusée. Le binaire est copié tel quel, avec la signature
# ad hoc de son éditeur de liens : la publication vérifie son empreinte avant de le signer.
GO2RTC_VERSION=1.9.14
GO2RTC_ARCHIVE=go2rtc_mac_arm64.zip
GO2RTC_URL="https://github.com/AlexxIT/go2rtc/releases/download/v$GO2RTC_VERSION/$GO2RTC_ARCHIVE"
EMPREINTES="$ROOT/mac/app/go2rtc.sha256"
CACHE="${GO2RTC_CACHE:-$ROOT/mac/app/.build/go2rtc}"
attendue() { /usr/bin/awk -v nom="$1" '$2 == nom { print $1 }' "$EMPREINTES"; }
empreinte() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'; }
if [ -z "$(attendue "$GO2RTC_ARCHIVE")" ] || [ -z "$(attendue go2rtc)" ]; then
    echo "error: $EMPREINTES doit donner l'empreinte de $GO2RTC_ARCHIVE et celle de go2rtc" >&2
    exit 1
fi
mkdir -p "$CACHE"
if [ ! -f "$CACHE/$GO2RTC_ARCHIVE" ] || [ "$(empreinte "$CACHE/$GO2RTC_ARCHIVE")" != "$(attendue "$GO2RTC_ARCHIVE")" ]; then
    echo "Téléchargement de go2rtc ${GO2RTC_VERSION}…"
    rm -f "$CACHE/$GO2RTC_ARCHIVE" "$CACHE/$GO2RTC_ARCHIVE.part"
    /usr/bin/curl -fsSL --retry 2 -o "$CACHE/$GO2RTC_ARCHIVE.part" "$GO2RTC_URL"
    if [ "$(empreinte "$CACHE/$GO2RTC_ARCHIVE.part")" != "$(attendue "$GO2RTC_ARCHIVE")" ]; then
        rm -f "$CACHE/$GO2RTC_ARCHIVE.part"
        echo "error: l'archive de go2rtc $GO2RTC_VERSION n'a pas l'empreinte attendue ($EMPREINTES) : refusée" >&2
        exit 1
    fi
    mv "$CACHE/$GO2RTC_ARCHIVE.part" "$CACHE/$GO2RTC_ARCHIVE"
fi
/usr/bin/unzip -p "$CACHE/$GO2RTC_ARCHIVE" go2rtc > "$CACHE/go2rtc.part"
if [ "$(empreinte "$CACHE/go2rtc.part")" != "$(attendue go2rtc)" ]; then
    rm -f "$CACHE/go2rtc.part"
    echo "error: le binaire go2rtc extrait n'a pas l'empreinte attendue ($EMPREINTES) : refusé" >&2
    exit 1
fi
install -m 755 "$CACHE/go2rtc.part" "$HELPERS/go2rtc"
rm -f "$CACHE/go2rtc.part"
install -m 644 "$ROOT/mac/app/go2rtc-LICENSE.txt" "$RESOURCES/go2rtc-LICENSE.txt"

# La plist embarquée de l'ancien agent de talkd (Contents/Library/LaunchAgents, BundleProgram vers Contents/Helpers/talkd).
# Depuis la 1.0.5 l'interrupteur « Talkback » n'inscrit plus rien par SMAppService : l'app écrit un agent launchd
# classique dans ~/Library/LaunchAgents (ClassicAgent, spec haut-parleur § 15). Cette plist ne sert plus qu'à désinscrire
# l'agent inscrit par la 1.0.4 au premier lancement (SMAppService.agent(plistName:) en a besoin) : elle reste donc dans
# le paquet, sans être inscrite.
LAUNCH_AGENTS="$APP/Contents/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS"
install -m 644 "$ROOT/mac/app/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.talkd.plist" "$LAUNCH_AGENTS/"

echo "Source d'obsbot-ai…"
install -m 644 "$ROOT/mac/ai/main.cpp" "$RESOURCES/obsbot-ai.cpp"

# Un ancien paquet (B1) a pu garder Helpers/obsbot-ai : il est retiré.
rm -f "$HELPERS/obsbot-ai"
FOUND="$(find "$APP" \( -name 'libdev*.dylib' -o -name 'obsbot-ai' -o -name 'devs.hpp' -o -name 'dev.hpp' \) -print)"
if [ -n "$FOUND" ]; then
    echo "error: le SDK OBSBOT, ses en-têtes ou un binaire obsbot-ai ne doivent jamais être dans le paquet : $FOUND" >&2
    exit 1
fi
