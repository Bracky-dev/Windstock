#!/bin/bash
# The game on its own: an unsigned .ipa with Pokémon GO 0.35, the windstock tweak
# and a native link to the public Windstock server -- no launcher, no embedded
# Python, nothing else. For phones the launcher cannot run on (it needs iOS 16):
# this one is built for iOS 9 and up (arm64, so iPhone 5s and newer).
#
#   tools/make_game_ipa.sh [output.ipa]
#
# What goes in, and where it comes from:
#   the game          RELEASE/pokemon-go-0.35-windstock.ipa (same source as embed_guest.sh),
#                     with the same custom medals and night music the launcher ships
#   windstock.dylib   work/mods/ios-tweak-035, rebuilt here for iOS 9 (Compat.inc.h)
#   WSLink.dylib      work/mods/ios-link -- does what the launcher's redirect + Python
#                     tunnel do: Niantic hostnames -> 2.29.24.78:8888 over pinned TLS
# Both dylibs are named by LC_LOAD_DYLIB in the game binary (insert_dylib.py), so they
# load before the game's own code runs, the way the tweak needs.
#
# Unsigned on purpose, like make_ipa.sh: the sideload signer re-signs everything.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HERE/build/Windstock-Game.ipa}"
GAME_IPA="${GAME_IPA:-$ROOT/RELEASE/pokemon-go-0.35-windstock.ipa}"
TWEAK_SRC="$ROOT/work/mods/ios-tweak-035"
MIN_IOS="${MIN_IOS:-9.0}"
BUNDLE_ID="${BUNDLE_ID:-com.windstock.game}"
BUILD="${BUILD:-$(date +%Y%m%d.%H%M)}"

[ -f "$GAME_IPA" ] || { echo "no game IPA at $GAME_IPA" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> windstock tweak for iOS $MIN_IOS"
# Theos refuses paths with spaces, and the repo has one -- build in a copy.
mkdir -p "$WORK/tweak"
cp "$TWEAK_SRC"/Makefile "$TWEAK_SRC"/control "$TWEAK_SRC"/windstock.plist \
   "$TWEAK_SRC"/*.mm "$TWEAK_SRC"/*.h "$WORK/tweak/"
# ldid is not installed on this Mac; codesign -s - does the same ad-hoc job.
# The 16.5 SDK from Theos, not Xcode's: the iOS 27 SDK's libc++ headers refuse
# deployment targets below iOS 12. -Wunguarded-availability makes any API newer
# than MIN_IOS without a Compat.inc.h fallback an error here.
(cd "$WORK/tweak" && THEOS="${THEOS:-$HOME/theos}" make -s FINALPACKAGE=1 \
    TARGET="iphone:clang:16.5:$MIN_IOS" \
    ADDITIONAL_CFLAGS="-Wunguarded-availability" \
    TARGET_CODESIGN=codesign TARGET_CODESIGN_FLAGS="-f -s -" >/dev/null)
TWEAK="$WORK/tweak/.theos/obj/windstock.dylib"
[ -f "$TWEAK" ] || { echo "tweak build failed" >&2; exit 1; }
install_name_tool -id "@executable_path/Frameworks/windstock.dylib" "$TWEAK" 2>/dev/null
codesign -f -s - "$TWEAK" >/dev/null 2>&1
echo "    v$(sed -n 's/^#define WS_TWEAK_VERSION \([0-9]*\).*/\1/p' "$TWEAK_SRC/Tweak.mm")"

echo "==> WSLink (server connection) for iOS $MIN_IOS"
MIN_IOS="$MIN_IOS" "$ROOT/work/mods/ios-link/build.sh" | sed 's/^/    /'

echo "==> unpacking $(basename "$GAME_IPA")"
unzip -q "$GAME_IPA" -d "$WORK/x"
APP="$(find "$WORK/x/Payload" -maxdepth 1 -name "*.app" | head -1)"
EXEC="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Info.plist")"
BIN="$APP/$EXEC"
if [ "$(lipo -archs "$BIN" | wc -w)" -gt 1 ]; then lipo -thin arm64 "$BIN" -output "$BIN.thin" && mv "$BIN.thin" "$BIN"; fi
rm -rf "$APP/_CodeSignature" "$APP/embedded.mobileprovision" "$APP/archived-expanded-entitlements.xcent"

# Same game data the launcher embeds (embed_guest.sh): custom medals + night music.
BADGES="$ROOT/work/tools/patch_badges.py"
if python3 -c "import UnityPy, Crypto, numpy" 2>/dev/null; then
    echo "==> custom medals"
    python3 "$BADGES" "$APP" | sed 's/^/    /'
else
    echo "    (no UnityPy/pycryptodome/numpy -- custom medals left unpatched)"
fi
NIGHT="$TWEAK_SRC/night"
if ls "$NIGHT"/windstock_*night.* >/dev/null 2>&1; then
    cp "$NIGHT"/windstock_*night.* "$APP/"
    cp "$NIGHT"/windstock_*_halloween.* "$APP/" 2>/dev/null || true
    echo "==> night music"
fi

echo "==> Frameworks/"
mkdir -p "$APP/Frameworks"
cp "$ROOT/work/mods/ios-link/WSLink.dylib" "$APP/Frameworks/WSLink.dylib"
cp "$TWEAK" "$APP/Frameworks/windstock.dylib"
# WSLink first: its hooks must be in place before anything the tweak or the game sends.
python3 "$HERE/tools/insert_dylib.py" "$BIN" \
    "@executable_path/Frameworks/WSLink.dylib" \
    "@executable_path/Frameworks/windstock.dylib"
chmod 755 "$BIN" "$APP"/Frameworks/*.dylib

echo "==> Info.plist"
python3 - "$APP/Info.plist" "$MIN_IOS" "$BUNDLE_ID" "$BUILD" <<'PY'
import plistlib, sys
path, min_ios, bundle_id, build = sys.argv[1:5]
p = plistlib.load(open(path, "rb"))
# 64-bit only (the dylibs are arm64); "armv7" alone makes a 64-bit-only phone refuse it
p["UIRequiredDeviceCapabilities"] = ["arm64"]
p["MinimumOSVersion"] = min_ios
p["CFBundleIdentifier"] = bundle_id
p["CFBundleVersion"] = build
p["CFBundleDisplayName"] = p["CFBundleName"] = "Windstock"
# The tweak's web views load http://127.0.0.1:8080 (WSLink's relay), and the relay
# itself talks https to an IP address. NEVER NSAllowsLocalNetworking alongside:
# iOS then ignores NSAllowsArbitraryLoads (see the launcher's Info.plist history).
p["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
# Since iOS 10 touching a protected resource without a usage string is an instant kill.
privacy = {
    "NSCameraUsageDescription": "To see Pokémon in the world around you.",
    "NSMotionUsageDescription": "To tell which way you are facing.",
    "NSLocationWhenInUseUsageDescription": "In order to play the game.",
    "NSLocationAlwaysUsageDescription": "In order to play the game.",
    "NSLocationAlwaysAndWhenInUseUsageDescription": "In order to play the game.",
    "NSPhotoLibraryUsageDescription": "To save your snapshots.",
    "NSPhotoLibraryAddUsageDescription": "To save your snapshots.",
    "NSMicrophoneUsageDescription": "Used by the game's camera mode.",
    "NSBluetoothAlwaysUsageDescription": "For Pokémon GO Plus.",
    "NSBluetoothPeripheralUsageDescription": "For Pokémon GO Plus.",
}
for k, v in privacy.items():
    p.setdefault(k, v)
# Files app access to Documents/ (windstock_log.txt, Windstock/link.log, sound packs)
p["UIFileSharingEnabled"] = True
p["LSSupportsOpeningDocumentsInPlace"] = True
plistlib.dump(p, open(path, "wb"), fmt=plistlib.FMT_BINARY)
print(f"    {bundle_id}  build {build}  iOS {min_ios}+  arm64")
PY

echo "==> packaging"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
(cd "$WORK/x" && zip -qry "$OUT" Payload)
echo
echo "$OUT ($(du -h "$OUT" | cut -f1))"
echo "Unsigned -- sideload with Sideloadly / AltStore / SideStore, which sign it."
