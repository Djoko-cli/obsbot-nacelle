#!/bin/bash
# Installe ptzd et obsbot-ai-off sur ce Mac, puis charge l'agent launchd (spec § 6.8).
# Usage : scripts/install-mac.sh [--no-load]
#   --no-load : installe les fichiers sans charger l'agent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/ObsbotNacelle"
LOGS="$HOME/Library/Logs/obsbot-nacelle"
LABEL="io.github.djoko-cli.obsbot-nacelle.ptzd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LIB="$ROOT/vendor/obsbot-sdk/macos/arm64-release/libdev.dylib"
LOAD=1
[ "${1:-}" = "--no-load" ] && LOAD=0

if [ ! -f "$LIB" ]; then
    echo "SDK OBSBOT introuvable : $LIB" >&2
    exit 1
fi
# macOS refuse de charger une bibliothèque téléchargée tant qu'elle est en quarantaine.
# Le script ne retire pas l'attribut lui-même : c'est une décision de sécurité à prendre à la main.
if xattr -p com.apple.quarantine "$LIB" >/dev/null 2>&1; then
    echo "libdev.dylib est en quarantaine (téléchargée depuis internet). Pour l'autoriser, lance :" >&2
    echo "  xattr -d com.apple.quarantine \"$LIB\"" >&2
    exit 1
fi

echo "Compilation de ptzd…"
(cd "$ROOT/mac/ptzd" && swift build -c release)
echo "Compilation de obsbot-ai-off…"
"$ROOT/mac/ai-off/build.sh" >/dev/null

mkdir -p "$SUPPORT/bin" "$SUPPORT/lib" "$LOGS" "$HOME/Library/LaunchAgents"
install -m 755 "$ROOT/mac/ptzd/.build/release/ptzd" "$SUPPORT/bin/ptzd"
install -m 755 "$ROOT/mac/ai-off/build/bin/obsbot-ai-off" "$SUPPORT/bin/obsbot-ai-off"
install -m 644 "$LIB" "$SUPPORT/lib/libdev.dylib"

if [ ! -f "$SUPPORT/config.json" ]; then
    ADDRESS="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    if [ -z "$ADDRESS" ]; then
        echo "Adresse Tailscale introuvable : crée $SUPPORT/config.json avec {\"listenAddress\": \"<IPv4 Tailscale du Mac>\"}." >&2
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
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
launchctl print "gui/$(id -u)/$LABEL" | grep -E "^\s+(state|pid) =" || true
echo "Journal : tail -f \"$LOGS/ptzd.log\""
