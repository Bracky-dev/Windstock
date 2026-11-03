#!/bin/bash
# Build WSShop.dylib -- the in-game shop for the 0.67 iOS guest, a tweak of its own.
#   ios073/tweak/build_shop.sh [server-ip]      (default: the Mac's en0 address)
# Add it in LiveContainer's Tweaks next to (or without) WSTweak.dylib.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER="${1:-$(ipconfig getifaddr en0)}"
[ -n "$SERVER" ] || { echo "no server IP (pass one)" >&2; exit 1; }
OUT="$HERE/WSShop.dylib"
SRC="$HERE/.WSShop.built.m"
sed "s/@SERVER@/$SERVER/g" "$HERE/WSShop.m" > "$SRC"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -dynamiclib -isysroot "$SDK" -miphoneos-version-min=14.0 \
    -fobjc-arc -Wall -O2 -framework Foundation \
    -install_name @rpath/WSShop.dylib "$SRC" -o "$OUT"
rm -f "$SRC"
codesign -f -s - "$OUT"
echo "==> $OUT"; lipo -archs "$OUT"
