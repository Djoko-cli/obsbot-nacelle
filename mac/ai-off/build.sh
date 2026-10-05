#!/bin/bash
# Compile obsbot-ai-off avec le SDK OBSBOT local (vendor/obsbot-sdk/, non versionné).
# Sortie : mac/ai-off/build/bin/obsbot-ai-off, qui cherche libdev.dylib dans ../lib.
# build/lib/libdev.dylib est un lien vers le SDK : pratique pour tester sans installer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="$ROOT/vendor/obsbot-sdk"
OUT="$ROOT/mac/ai-off/build"

if [ ! -f "$SDK/include/dev/devs.hpp" ] || [ ! -f "$SDK/macos/arm64-release/libdev.dylib" ]; then
    echo "SDK OBSBOT introuvable dans $SDK (voir docs/spike/2026-10-05-faisabilite.md)." >&2
    exit 1
fi

mkdir -p "$OUT/bin" "$OUT/lib"
clang++ -std=c++17 -O2 -Wall \
    -I"$SDK/include" \
    -L"$SDK/macos/arm64-release" -ldev \
    -Wl,-rpath,@executable_path/../lib \
    -o "$OUT/bin/obsbot-ai-off" "$ROOT/mac/ai-off/main.cpp"
ln -sf "$SDK/macos/arm64-release/libdev.dylib" "$OUT/lib/libdev.dylib"
echo "$OUT/bin/obsbot-ai-off"
