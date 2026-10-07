#!/bin/bash
# Compile PTZBot pour Mac, avec ptzd et obsbot-ai dans Contents/Helpers, l'installe dans
# ~/Applications/PTZBot.app et la lance (spec ptzd dans l'app § 5.7).
# Le script ne touche ni à launchd, ni à bin/, ni à lib/ : au premier lancement, l'app propose
# de remplacer l'ancienne installation, puis accompagne l'installation du SDK OBSBOT.
# Usage : scripts/install-mac.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$ROOT/vendor/obsbot-sdk"
APP="$HOME/Applications/PTZBot.app"
APP_ID="io.github.djoko-cli.ptzbot"
BUILT="$ROOT/mac/app/.build/Build/Products/Release/PTZBot.app"

if [ "$#" -ne 0 ]; then
    echo "usage : scripts/install-mac.sh" >&2
    exit 2
fi

# obsbot-ai se compile avec les en-têtes du SDK ; le SDK lui-même n'entre jamais dans l'app.
if [ ! -f "$SDK/include/dev/devs.hpp" ] || [ ! -f "$SDK/macos/arm64-release/libdev.dylib" ]; then
    echo "SDK OBSBOT introuvable dans $SDK : décompressez-y l'archive reçue d'OBSBOT pour compiler obsbot-ai." >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null; then
    echo "xcodegen introuvable : brew install xcodegen" >&2
    exit 1
fi

echo "Compilation de PTZBot pour Mac (avec ptzd et obsbot-ai)…"
(cd "$ROOT/mac/app" && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot \
    -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build -quiet)
"$ROOT/mac/app/check-bundle.sh" "$BUILT" >/dev/null

# L'app en cours est fermée avant d'être remplacée ; elle arrête son ptzd en partant (5 s au plus).
# On attend qu'aucun processus de ~/Applications/PTZBot.app ne reste (15 s au plus), et que
# LaunchServices l'ait vu partir : sinon `open` échoue (erreur -600).
EXE="$APP/Contents/MacOS/PTZBot"
still_running() {
    pgrep -f "$EXE" >/dev/null && return 0
    [ "$(osascript -e "application id \"$APP_ID\" is running" 2>/dev/null)" = "true" ]
}
osascript -e "tell application id \"$APP_ID\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
    still_running || break
    sleep 0.5
done
if still_running; then
    echo "PTZBot est encore ouvert après 15 s : quittez-le depuis la barre des menus (Quitter), puis relancez ce script. L'app n'a pas été remplacée." >&2
    exit 1
fi

mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$BUILT" "$APP"
# Dernier filet : `open` réessayé deux fois si LaunchServices n'a pas encore oublié l'ancienne app.
OPENED=0
for ATTEMPT in 1 2 3; do
    if open "$APP"; then
        OPENED=1
        break
    fi
    [ "$ATTEMPT" -lt 3 ] && sleep 1
done
if [ "$OPENED" = 0 ]; then
    echo "PTZBot est installé, mais n'a pas pu être lancé : ouvrez ~/Applications/PTZBot.app." >&2
    exit 1
fi
echo "PTZBot est dans la barre des menus."
echo "Au premier lancement, il propose de remplacer l'ancienne installation de ptzd s'il en trouve une."
echo "Le SDK OBSBOT s'installe depuis son panneau : SDK OBSBOT › Installer le SDK…"
echo "Journal : tail -f \"$HOME/Library/Logs/obsbot-nacelle/ptzd.log\""
