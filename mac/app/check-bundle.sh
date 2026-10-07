#!/bin/bash
# Vérifie le paquet Release de PTZBot (spec ptzd dans l'app § 8) : ptzd et obsbot-ai dans
# Contents/Helpers, et aucun libdev.dylib nulle part.
# Usage : mac/app/check-bundle.sh [chemin de PTZBot.app]
set -euo pipefail

APP="${1:-$(cd "$(dirname "$0")" && pwd)/.build/Build/Products/Release/PTZBot.app}"
STATUS=0

if [ ! -d "$APP" ]; then
    echo "Paquet introuvable : $APP" >&2
    exit 1
fi
for HELPER in ptzd obsbot-ai; do
    if [ -x "$APP/Contents/Helpers/$HELPER" ]; then
        echo "ok : Contents/Helpers/$HELPER"
    else
        echo "manquant : Contents/Helpers/$HELPER" >&2
        STATUS=1
    fi
done
FOUND="$(find "$APP" -name 'libdev*.dylib' -print)"
if [ -n "$FOUND" ]; then
    echo "SDK OBSBOT dans le paquet : $FOUND" >&2
    STATUS=1
else
    echo "ok : aucun libdev.dylib dans le paquet"
fi
exit "$STATUS"
