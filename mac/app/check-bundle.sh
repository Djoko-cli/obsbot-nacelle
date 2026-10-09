#!/bin/bash
# Vérifie le paquet Release de PTZBot (spec distribution § 5.1 et § 10) : ptzd et talkd dans Contents/Helpers, la plist
# de l'agent de talkd dans Contents/Library/LaunchAgents (spec haut-parleur § 7), la source d'obsbot-ai dans
# Contents/Resources, Sparkle dans Contents/Frameworks ; ni le SDK OBSBOT (libdev*.dylib), ni ses
# en-têtes (devs.hpp, dev.hpp), ni aucun binaire obsbot-ai, ni aucun binaire Mach-O qui dépende de libdev (otool -L).
# Usage : mac/app/check-bundle.sh [chemin de PTZBot.app]
set -euo pipefail

APP="${1:-$(cd "$(dirname "$0")" && pwd)/.build/Build/Products/Release/PTZBot.app}"
STATUS=0

if [ ! -d "$APP" ]; then
    echo "Paquet introuvable : $APP" >&2
    exit 1
fi

require() {
    if [ "$1" "$APP/$2" ]; then
        echo "ok : $2"
    else
        echo "manquant : $2" >&2
        STATUS=1
    fi
}
require -x Contents/Helpers/ptzd
require -x Contents/Helpers/talkd
require -f Contents/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.talkd.plist
require -f Contents/Resources/obsbot-ai.cpp
require -d Contents/Frameworks/Sparkle.framework

# La plist de l'agent est valide, son label est celui que l'app inscrit, son programme est celui du paquet.
AGENT="$APP/Contents/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.talkd.plist"
if [ -f "$AGENT" ]; then
    if ! /usr/bin/plutil -lint "$AGENT" >/dev/null; then
        echo "plist de l'agent de talkd invalide : $AGENT" >&2
        STATUS=1
    elif [ "$(/usr/bin/plutil -extract Label raw "$AGENT")" != "io.github.djoko-cli.obsbot-nacelle.talkd" ]; then
        echo "label inattendu dans la plist de l'agent de talkd" >&2
        STATUS=1
    else
        PROGRAM="$(/usr/bin/plutil -extract BundleProgram raw "$AGENT")"
        if [ "$PROGRAM" != "Contents/Helpers/talkd" ] || [ ! -x "$APP/$PROGRAM" ]; then
            echo "BundleProgram de l'agent de talkd ne vise pas Contents/Helpers/talkd : $PROGRAM" >&2
            STATUS=1
        else
            echo "ok : l'agent de talkd vise $PROGRAM"
        fi
    fi
fi

refuse() {
    local FOUND
    FOUND="$(find "$APP" "$@" -print)"
    if [ -n "$FOUND" ]; then
        echo "interdit dans le paquet : $FOUND" >&2
        STATUS=1
    fi
}
refuse -name 'libdev*.dylib'
refuse -name 'obsbot-ai'
refuse \( -name 'devs.hpp' -o -name 'dev.hpp' \)
# Aucun binaire Mach-O du paquet ne doit dépendre du SDK (otool -L).
while IFS= read -r -d '' FILE; do
    MAGIC="$(head -c 4 "$FILE" | xxd -p)"
    case "$MAGIC" in
        cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|cafebabf) ;;
        *) continue ;;
    esac
    if /usr/bin/otool -L "$FILE" 2>/dev/null | tail -n +2 | grep -q libdev; then
        echo "dépend du SDK OBSBOT : ${FILE#"$APP"/}" >&2
        STATUS=1
    fi
done < <(find "$APP" -type f -print0)
if [ "$STATUS" -eq 0 ]; then
    echo "ok : ni SDK OBSBOT, ni ses en-têtes, ni binaire obsbot-ai, ni dépendance au SDK dans le paquet"
fi
exit "$STATUS"
