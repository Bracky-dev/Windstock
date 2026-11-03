#!/bin/bash
# Build the LiveContainer tweak dylib (redirect + trust) for the 0.73.1 guest.
#
#   ios073/tweak/build.sh [server-ip]      (default: the Mac's en0 address)
#
# Output: ios073/tweak/WSTweak.dylib -- drop it into the game's Tweaks folder in
# LiveContainer (app settings -> Tweaks), or the global Tweaks folder. LiveContainer
# signs it with the app. The server IP is baked in; override on device with env
# WS_SERVER or <guest Documents>/ws_server.txt.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER="${1:-$(ipconfig getifaddr en0)}"
[ -n "$SERVER" ] || { echo "no server IP (pass one)" >&2; exit 1; }
OUT="$HERE/WSTweak.dylib"
MIN=14.0

echo "==> server $SERVER"
SRC="$HERE/.WSTweak.built.m"
sed "s/@SERVER@/$SERVER/g" "$HERE/WSTweak.m" > "$SRC"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -dynamiclib \
    -isysroot "$SDK" -miphoneos-version-min="$MIN" \
    -fobjc-arc -Wall -O2 \
    -framework Foundation -framework Security \
    -install_name @rpath/WSTweak.dylib \
    "$SRC" "$HERE/fishhook.c" "$HERE/il2hook.c" -o "$OUT"
rm -f "$SRC"

# Ad-hoc sign so it loads on a jailed device even before LiveContainer re-signs.
codesign -f -s - "$OUT"
echo "==> $OUT"
lipo -archs "$OUT"; otool -L "$OUT" | grep -iE "security|foundation" | head
echo "done"
