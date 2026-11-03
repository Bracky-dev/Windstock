#!/bin/bash
# Build WSLog.dylib (captures the game's log and sends it to the server).
#
#   tweak-livecontainer/build_log.sh [server-ip]      (default: the Mac's en0 address)
#
# Add it in LiveContainer next to WSTweak.dylib (app settings -> Tweaks). Output goes to
# the guest's Documents/wslog.txt, and interesting lines show in the server log as
# "[bridge] GET /wslog?m=...".
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER="${1:-$(ipconfig getifaddr en0)}"
[ -n "$SERVER" ] || { echo "no server IP (pass one)" >&2; exit 1; }
OUT="$HERE/WSLog.dylib"

echo "==> server $SERVER"
SRC="$HERE/.WSLog.built.m"
sed "s/@SERVER@/$SERVER/g" "$HERE/WSLog.m" > "$SRC"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -dynamiclib \
    -isysroot "$SDK" -miphoneos-version-min=14.0 \
    -fobjc-arc -Wall -O2 -framework Foundation \
    -install_name @rpath/WSLog.dylib \
    "$SRC" "$HERE/fishhook.c" -o "$OUT"
rm -f "$SRC"
codesign -f -s - "$OUT"
echo "==> $OUT"
lipo -archs "$OUT"
