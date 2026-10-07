#!/bin/bash
# Installe ptzd, obsbot-ai et l'app PTZBot pour Mac sur ce Mac, puis charge l'agent launchd et lance
# l'app (spec § 6.8, spec app Mac § 8.6).
# Usage : scripts/install-mac.sh [--no-load]
#   --no-load : installe les fichiers sans charger l'agent ni lancer l'app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/ObsbotNacelle"
LOGS="$HOME/Library/Logs/obsbot-nacelle"
LABEL="io.github.djoko-cli.obsbot-nacelle.ptzd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LIB="$ROOT/vendor/obsbot-sdk/macos/arm64-release/libdev.dylib"
APP="$HOME/Applications/PTZBot.app"
APP_ID="io.github.djoko-cli.ptzbot"
LOAD=1
case "$#:${1:-}" in
    0:) ;;
    1:--no-load) LOAD=0 ;;
    *)
        echo "usage : scripts/install-mac.sh [--no-load]" >&2
        exit 2
        ;;
esac

if [ ! -f "$LIB" ]; then
    echo "SDK OBSBOT introuvable : $LIB" >&2
    exit 1
fi
# macOS refuse de charger une bibliothèque téléchargée tant qu'elle est en quarantaine.
# Le script ne retire pas l'attribut lui-même : c'est une décision de sécurité à prendre à la main.
if xattr -p com.apple.quarantine "$LIB" >/dev/null 2>&1; then
    echo "libdev.dylib est en quarantaine (téléchargée depuis internet). Pour l'autoriser, lancez :" >&2
    echo "  xattr -d com.apple.quarantine \"$LIB\"" >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null; then
    echo "xcodegen introuvable : brew install xcodegen" >&2
    exit 1
fi

# Tout est compilé avant la première installation : une compilation en échec ne laisse
# pas un système à moitié installé.
echo "Compilation de ptzd…"
(cd "$ROOT/mac/ptzd" && swift build -c release)
echo "Compilation de obsbot-ai…"
"$ROOT/mac/ai/build.sh" >/dev/null
echo "Compilation de PTZBot pour Mac…"
(cd "$ROOT/mac/app" && xcodegen -q && xcodebuild build -project PTZBot.xcodeproj -scheme PTZBot \
    -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build -quiet)

mkdir -p "$SUPPORT/bin" "$SUPPORT/lib" "$LOGS" "$HOME/Library/LaunchAgents"
install -m 755 "$ROOT/mac/ptzd/.build/release/ptzd" "$SUPPORT/bin/ptzd"
install -m 755 "$ROOT/mac/ai/build/bin/obsbot-ai" "$SUPPORT/bin/obsbot-ai"
# L'ancien utilitaire (coupure seule) ne sert plus.
rm -f "$SUPPORT/bin/obsbot-ai-off"
install -m 644 "$LIB" "$SUPPORT/lib/libdev.dylib"
# L'app en cours est fermée avant d'être remplacée.
osascript -e "tell application id \"$APP_ID\" to quit" >/dev/null 2>&1 || true
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$ROOT/mac/app/.build/Build/Products/Release/PTZBot.app" "$APP"

if [ ! -f "$SUPPORT/config.json" ]; then
    ADDRESS="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    if [ -z "$ADDRESS" ]; then
        echo "Adresse Tailscale introuvable : créez $SUPPORT/config.json avec {\"listenAddress\": \"<IPv4 Tailscale du Mac>\"}." >&2
        exit 1
    fi
    printf '{\n  "listenAddress": "%s"\n}\n' "$ADDRESS" > "$SUPPORT/config.json"
    echo "config.json créé (écoute sur l'adresse Tailscale du Mac, port 1985)."
fi

sed -e "s#__SUPPORT__#$SUPPORT#g" -e "s#__LOGS__#$LOGS#g" \
    "$ROOT/mac/launchd/$LABEL.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

if [ "$LOAD" = 0 ]; then
    echo "Fichiers installés ; agent non chargé (--no-load)."
    exit 0
fi
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout rend la main avant que l'agent ait disparu ; un bootstrap trop tôt échoue
# (erreur 5). On attend sa disparition, 10 s au plus.
for _ in $(seq 1 20); do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
done
# Puis jusqu'à 3 nouveaux essais, à 1 s d'intervalle.
LOADED=0
for ATTEMPT in 1 2 3 4; do
    if launchctl bootstrap "$DOMAIN" "$PLIST"; then
        LOADED=1
        break
    fi
    [ "$ATTEMPT" -lt 4 ] && sleep 1
done
if [ "$LOADED" = 0 ]; then
    echo "Chargement de l'agent impossible : launchctl bootstrap a échoué 4 fois." >&2
    exit 1
fi
sleep 2
launchctl print "$DOMAIN/$LABEL" | grep -E "^\s+(state|pid) =" || true
open "$APP"
echo "PTZBot est dans la barre des menus."
echo "Journal : tail -f \"$LOGS/ptzd.log\""
