#!/bin/bash
# Phase de construction de PTZBot (project.yml) : compile ptzd et talkd et les copie dans Contents/Helpers, copie la
# plist de l'agent de talkd dans Contents/Library/LaunchAgents (spec haut-parleur § 7), copie la source d'obsbot-ai
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

# L'agent launchd de talkd, que SMAppService.agent(plistName:) inscrit depuis l'interrupteur « Talkback » : sa plist
# est dans Contents/Library/LaunchAgents, son BundleProgram vise Contents/Helpers/talkd.
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
