#!/bin/bash
# Vérifie le paquet Release de PTZBot (spec distribution § 5.1 et § 10, spec B3 § 8) : ptzd, talkd, le gardien et
# go2rtc (le binaire officiel, à l'octet près) dans Contents/Helpers, sa licence dans Contents/Resources, les droits
# caméra et micro de l'app et ses textes d'autorisation, la plist
# embarquée de l'ancien agent de talkd dans Contents/Library/LaunchAgents (spec haut-parleur § 7 et § 15 : elle ne sert
# plus qu'à désinscrire l'agent de la 1.0.4), la source d'obsbot-ai dans
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
require -x Contents/Helpers/gardien
require -x Contents/Helpers/go2rtc
require -f Contents/Resources/go2rtc-LICENSE.txt
require -f Contents/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.talkd.plist
require -f Contents/Resources/obsbot-ai.cpp
require -d Contents/Frameworks/Sparkle.framework

# La plist embarquée est valide, son label est celui de l'agent de l'app, son programme est celui du paquet.
AGENT="$APP/Contents/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.talkd.plist"
if [ -f "$AGENT" ]; then
    if ! /usr/bin/plutil -lint "$AGENT" >/dev/null; then
        echo "plist embarquée de l'agent de talkd invalide : $AGENT" >&2
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

# go2rtc : le binaire officiel de la version 1.9.14, à l'octet près (mac/app/go2rtc.sha256), pour Apple Silicon.
EMPREINTES="$(cd "$(dirname "$0")" && pwd)/go2rtc.sha256"
if [ -x "$APP/Contents/Helpers/go2rtc" ]; then
    ATTENDUE="$(/usr/bin/awk '$2 == "go2rtc" { print $1 }' "$EMPREINTES")"
    if [ -z "$ATTENDUE" ] || [ "$(/usr/bin/shasum -a 256 "$APP/Contents/Helpers/go2rtc" | /usr/bin/awk '{ print $1 }')" != "$ATTENDUE" ]; then
        echo "go2rtc n'est pas le binaire officiel attendu ($EMPREINTES)" >&2
        STATUS=1
    else
        echo "ok : go2rtc officiel (empreinte de $EMPREINTES)"
    fi
fi

# Les droits caméra et micro de l'app (spec B3 § 3.4) ; ceux des utilitaires sont contrôlés à la publication.
DROITS="$(/usr/bin/codesign -d --entitlements - --xml "$APP" 2>/dev/null | /usr/bin/plutil -convert json -o - - 2>/dev/null || true)"
for DROIT in com.apple.security.device.camera com.apple.security.device.audio-input; do
    if printf '%s' "$DROITS" | grep -q "\"$DROIT\":true"; then
        echo "ok : droit $DROIT"
    else
        echo "droit manquant sur l'app : $DROIT" >&2
        STATUS=1
    fi
done
for CLE in NSCameraUsageDescription NSMicrophoneUsageDescription; do
    if [ -n "$(/usr/bin/plutil -extract "$CLE" raw "$APP/Contents/Info.plist" 2>/dev/null)" ]; then
        echo "ok : $CLE"
    else
        echo "Info.plist : $CLE manque" >&2
        STATUS=1
    fi
done

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
