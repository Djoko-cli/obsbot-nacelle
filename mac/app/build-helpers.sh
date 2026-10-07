#!/bin/bash
# Phase de construction de PTZBot (project.yml) : compile ptzd et obsbot-ai, les copie dans
# Contents/Helpers, puis refuse le paquet s'il contient un libdev.dylib (spec ptzd dans l'app § 5.1).
# obsbot-ai est lié à @rpath/libdev.dylib sans chemin de recherche intégré : ptzd lui donne
# DYLD_LIBRARY_PATH vers la copie autorisée du SDK.
set -euo pipefail

ROOT="$(cd "$SRCROOT/../.." && pwd)"
SDK="$ROOT/vendor/obsbot-sdk"
HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
WORK="$DERIVED_FILE_DIR/helpers"

if [ ! -f "$SDK/include/dev/devs.hpp" ] || [ ! -f "$SDK/macos/arm64-release/libdev.dylib" ]; then
    echo "error: SDK OBSBOT introuvable dans $SDK : ses en-têtes sont nécessaires pour compiler obsbot-ai." >&2
    exit 1
fi

mkdir -p "$HELPERS" "$WORK"

# swift build hors de l'environnement de Xcode, dont les variables (SDKROOT, ARCHS…) le dérouteraient.
echo "Compilation de ptzd…"
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/ptzd" --product ptzd
BIN="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$ROOT/mac/ptzd" --show-bin-path)"
install -m 755 "$BIN/ptzd" "$HELPERS/ptzd"

echo "Compilation de obsbot-ai…"
/usr/bin/xcrun clang++ -std=c++17 -O2 -Wall -arch arm64 -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -I"$SDK/include" \
    -L"$SDK/macos/arm64-release" -ldev \
    -o "$WORK/obsbot-ai" "$ROOT/mac/ai/main.cpp"
install -m 755 "$WORK/obsbot-ai" "$HELPERS/obsbot-ai"

FOUND="$(find "$TARGET_BUILD_DIR/$WRAPPER_NAME" -name 'libdev*.dylib' -print)"
if [ -n "$FOUND" ]; then
    echo "error: le SDK OBSBOT ne doit jamais être dans le paquet : $FOUND" >&2
    exit 1
fi
