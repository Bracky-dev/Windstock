#!/bin/bash
# The raids launcher: a SEPARATE app ("Windstock Raids", com.windstock.launcher.raids)
# that installs next to the normal launcher. Differences from tools/make_ipa.sh:
#
#   * the tweak is built with RAIDS=1 (lobby, egg card, Raid Passes, NEARBY RAIDS)
#   * the embedded server is today's work/server, with a raid boss at EVERY gym and
#     the 0.71 gym system (gyms.v2)
#     (raids.scheduled defaults to true in this app's copy of settings.py)
#
# Staging/ is shared with the normal launcher build, so the tweak and PythonServer
# it holds are put back exactly as they were when this finishes (or fails).
#
#   tools/make_raids_ipa.sh [output.ipa]    -> build/WindstockLauncher-Raids.ipa
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HERE/build/WindstockLauncher-Raids.ipa}"
STAGING="$HERE/Staging"
TWEAK_SRC="$ROOT/work/mods/ios-tweak-035"

[ -d "$STAGING/PythonServer" ] && [ -f "$STAGING/Frameworks/windstock.dylib" ] ||
    { echo "Staging/ isn't set up -- run a normal launcher build first" >&2; exit 1; }

SAVE="$(mktemp -d)"
WORK="$(mktemp -d)"
mv "$STAGING/PythonServer" "$SAVE/PythonServer"
cp "$STAGING/Frameworks/windstock.dylib" "$SAVE/windstock.dylib"
GDATA="$STAGING/Guest/game/Data"
cp "$GDATA/sharedassets0.assets" "$GDATA/resources.assets" "$SAVE/"
restore() {
    rm -rf "$STAGING/PythonServer"
    mv "$SAVE/PythonServer" "$STAGING/PythonServer"
    cp "$SAVE/windstock.dylib" "$STAGING/Frameworks/windstock.dylib"
    cp "$SAVE/sharedassets0.assets" "$SAVE/resources.assets" "$GDATA/"
    rm -f "$STAGING"/Guest/game/windstock_raid_* "$STAGING"/Guest/game/windstock_music_*raid* \
          "$STAGING"/Guest/game/windstock_music_gym_my_team.m4a
    rm -rf "$SAVE" "$WORK"
    echo "==> Staging/ restored for the normal launcher"
}
trap restore EXIT

echo "==> windstock tweak, RAIDS=1"
# Theos refuses paths with spaces, and the repo has one -- build in a copy.
mkdir -p "$WORK/tweak"
cp "$TWEAK_SRC"/Makefile "$TWEAK_SRC"/control "$TWEAK_SRC"/windstock.plist \
   "$TWEAK_SRC"/*.mm "$TWEAK_SRC"/*.h "$ROOT/work/port071/tweak"/*.mm "$WORK/tweak/"
(cd "$WORK/tweak" && THEOS="${THEOS:-$HOME/theos}" make -s RAIDS=1 FINALPACKAGE=1 \
    TARGET_CODESIGN=codesign TARGET_CODESIGN_FLAGS="-f -s -" 2>&1 | grep -v "ld: warning" || true)
[ -f "$WORK/tweak/.theos/obj/windstock.dylib" ] || { echo "tweak build failed" >&2; exit 1; }
cp "$WORK/tweak/.theos/obj/windstock.dylib" "$STAGING/Frameworks/windstock.dylib"

echo "==> 0.71 raid music + art into the game (removed again on exit)"
cp "$ROOT/work/port071/assets/"windstock_* "$STAGING/Guest/game/"

echo "==> game data: medals etc. + 0.71's gym screens (transplant_071.py; put back on exit)"
WS_GYMS071=1 python3 "$ROOT/work/tools/patch_badges.py" "$STAGING/Guest/game" | sed 's/^/    /'

echo "==> embedded server (work/server, raids on)"
"$HERE/tools/stage_server.sh" | sed 's/^/    /'
# Bring back anything the old staging had that this run didn't make (seed-data etc.).
for extra in "$SAVE/PythonServer"/*; do
    name="$(basename "$extra")"
    [ -e "$STAGING/PythonServer/$name" ] || cp -R "$extra" "$STAGING/PythonServer/$name"
done
python3 - "$STAGING/PythonServer/settings.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
# Every gym holds a boss all the time (no egg wait, a new boss every 45 minutes),
# and gyms run the 0.71 rules.
for old, new in (('"scheduled": False,', '"scheduled": True,   # raids launcher build'),
                 ('"window_minutes": 180.0,', '"window_minutes": 45.0,'),
                 ('"chance": 0.15,', '"chance": 1.0,'),
                 ('"egg_minutes": 60.0,', '"egg_minutes": 0.0,'),
                 # ...and the 0.71 gym system (gymv2.py) instead of 2016 prestige
                 ('"v2": False,', '"v2": True,   # raids launcher build')):
    assert old in s, f"settings.py: {old} not found"
    s = s.replace(old, new, 1)
open(p, "w", encoding="utf-8").write(s)
PY

BUNDLE_ID=com.windstock.launcher.raids DISPLAY_NAME="Windstock Raids" \
    "$HERE/tools/make_ipa.sh" "$OUT"
