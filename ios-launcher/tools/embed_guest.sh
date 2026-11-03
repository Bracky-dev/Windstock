#!/bin/bash
# Put the game inside the launcher.
#
#   tools/embed_guest.sh ../RELEASE/pokemon-go-0.35-windstock.ipa [tweak.dylib]
#
# The split is deliberate:
#
#   Staging/Frameworks/pokemongo.framework/pokemongo   the Mach-O, as a dylib
#   Staging/Guest/game/                                everything else
#
# Guest/game is deliberately NOT a .app: a nested .app with no main executable
# makes Sideloadly refuse the IPA ("bundle_main_missing").
#
# The binary has to live in a framework because a free-developer sideload only
# signs Mach-O files it finds in Frameworks/, and an unsigned one is killed the
# instant dlopen touches it. It has to be named exactly "pokemongo" because the
# windstock tweak finds the game by looking for a loaded image whose path ends
# in "/pokemongo".
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
IPA="${1:-}"
TWEAK="${2:-}"
STAGING="$HERE/Staging"

[ -n "$IPA" ] && [ -f "$IPA" ] || { echo "usage: $0 <ipa> [tweak.dylib]" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> unpacking $(basename "$IPA")"
unzip -q "$IPA" -d "$WORK"
APP="$(find "$WORK/Payload" -maxdepth 1 -name "*.app" | head -1)"
[ -n "$APP" ] || { echo "no Payload/*.app in the IPA" >&2; exit 1; }

EXEC_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Info.plist")"
BIN="$APP/$EXEC_NAME"
[ -f "$BIN" ] || { echo "no executable $EXEC_NAME in $APP" >&2; exit 1; }
echo "    $(basename "$APP") / $EXEC_NAME"

ARCHS="$(lipo -archs "$BIN" 2>/dev/null || echo "?")"
echo "    architectures: $ARCHS"
if [ "$(echo "$ARCHS" | wc -w)" -gt 1 ]; then
    echo "    thinning to arm64"
    lipo -thin arm64 "$BIN" -output "$WORK/thin" && mv "$WORK/thin" "$BIN"
fi

echo "==> Frameworks/pokemongo.framework"
FW="$STAGING/Frameworks/pokemongo.framework"
rm -rf "$FW"
mkdir -p "$FW"
python3 "$HERE/tools/patch_macho.py" "$BIN" "$FW/pokemongo" \
    --install-name "@rpath/pokemongo.framework/pokemongo"
chmod +x "$FW/pokemongo"
cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>pokemongo</string>
	<key>CFBundleIdentifier</key><string>com.windstock.guest.pokemongo</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>pokemongo</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>0.35.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

echo "==> Guest/game (from $(basename "$APP"))"
GUEST="$STAGING/Guest/game"
rm -rf "$STAGING/Guest"
mkdir -p "$GUEST"
(cd "$APP" && tar cf - .) | (cd "$GUEST" && tar xf -)
# The executable now lives in Frameworks/; a second 100 MB copy here would be
# dead weight, and the old signature and profile are about to be invalid anyway.
rm -f "$GUEST/$EXEC_NAME"
rm -rf "$GUEST/_CodeSignature" "$GUEST/embedded.mobileprovision" \
       "$GUEST/archived-expanded-entitlements.xcent"

# Windstock's custom medals (Shiny Hunter, Night Owl, Shinydex) are game DATA:
# art in sharedassets0.assets, text in resources.assets. Needs UnityPy; without
# it the medals still work, just with the generic art and raw text keys.
BADGES="$(cd "$HERE/.." && pwd)/work/tools/patch_badges.py"
if python3 -c "import UnityPy, Crypto, numpy" 2>/dev/null; then
    echo "==> custom medals"
    python3 "$BADGES" "$GUEST"
else
    echo "    (no UnityPy/pycryptodome/numpy -- custom medals left unpatched; see $BADGES)"
fi

# Night music shipped with the game: windstock_night.* (map) and
# windstock_<clip>_night.* (102_encounter_night = night catch theme). The tweak
# plays them 7 PM-6 AM when the sound pack has no night version of its own.
NIGHT="${NIGHT_MUSIC_DIR:-$(cd "$HERE/.." && pwd)/work/mods/ios-tweak-035/night}"
if ls "$NIGHT"/windstock_*night.* >/dev/null 2>&1; then
    cp "$NIGHT"/windstock_*night.* "$GUEST/"
    # Halloween nights (tweak v147): windstock_walk_halloween.* etc., when present
    cp "$NIGHT"/windstock_*_halloween.* "$GUEST/" 2>/dev/null || true
    # Weather tint (tweak v200): the game's ground / sky / catch pictures to repaint
    cp "$NIGHT"/windstock_tint_*.png "$GUEST/" 2>/dev/null || true
    echo "==> night music: $(cd "$NIGHT" && ls windstock_*night.* | tr '\n' ' ')"
else
    echo "    (no night music in $NIGHT -- only sound packs can supply it)"
fi

# Sounds from the modern game that 0.35 doesn't have (tweak v179: the Research screen's
# se_go_quests_monitor_on/off, from the 0.111 client): windstock_sfx_<clip>.wav
SFX="$(cd "$HERE/.." && pwd)/work/mods/ios-tweak-035/sounds"
if ls "$SFX"/windstock_sfx_*.* >/dev/null 2>&1; then
    cp "$SFX"/windstock_sfx_*.* "$GUEST/"
    echo "==> extra sounds: $(cd "$SFX" && ls windstock_sfx_*.* | tr '\n' ' ')"
fi
# Tweak v194: the modern game's trade-room music (windstock_music_124_trade_standby, 125_trade)
if ls "$SFX"/windstock_music_*.* >/dev/null 2>&1; then
    cp "$SFX"/windstock_music_*.* "$GUEST/"
    echo "==> extra music: $(cd "$SFX" && ls windstock_music_*.* | tr '\n' ' ')"
fi
rm -f "$GUEST"/windstock_sfx_se_ws_*.*      # v194: the old synthesized friend sounds

if [ -n "$TWEAK" ]; then
    [ -f "$TWEAK" ] || { echo "no tweak at $TWEAK" >&2; exit 1; }
    cp "$TWEAK" "$STAGING/Frameworks/windstock.dylib"
    echo "==> Frameworks/windstock.dylib ($(basename "$TWEAK"))"
fi

# Location spoofing, built by work/mods/ios-gps/build.sh. Its own dylib and its
# own switch in the launcher, so a build without it is a perfectly good build.
GPS="${GPS_TWEAK:-$(cd "$HERE/.." && pwd)/work/mods/ios-gps/windstockgps.dylib}"
if [ -f "$GPS" ]; then
    cp "$GPS" "$STAGING/Frameworks/windstockgps.dylib"
    echo "==> Frameworks/windstockgps.dylib"
else
    echo "    (no windstockgps.dylib -- run work/mods/ios-gps/build.sh to include spoofing)"
fi

echo
echo "The guest's own Info.plist wants these; check them against"
echo "WindstockLauncher/Support/Info.plist, because iOS reads the HOST's:"
for key in UISupportedInterfaceOrientations UIStatusBarHidden UIRequiresFullScreen \
           NSLocationWhenInUseUsageDescription UIBackgroundModes; do
    printf '    %-38s ' "$key"
    /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Info.plist" 2>/dev/null \
        | tr '\n' ' ' || echo "(absent)"
    echo
done

echo
echo "staged $(du -sh "$STAGING/Guest" | cut -f1) of resources"
echo "next: build for a device, then tools/make_ipa.sh"
