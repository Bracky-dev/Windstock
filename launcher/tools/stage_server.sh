#!/bin/bash
# Copy the Windstock server into Staging/PythonServer.
#
# The server lives in work/server, NOT the stale top-level server/ copy. That
# copy is a Sep-14 release snapshot missing research.py, shiny.py, weather.py,
# leveling.py, raidlobby.py, soundpacks.py and biomes.py, and its protocol.py
# is half the size. Staging it is what shipped a launcher with no Field
# Research, no calendar, no shiny, no onboarding and the wrong spawn tables --
# the tweak polls /research/ping and /shiny/state, and the old server answers
# 405 to both because it has no route for them.
#
# Only what the iOS client actually needs: the Android asset bundles are a
# separate 64 MB set with disjoint asset ids (see protocol.py), the frida
# tooling cannot run on a phone, and data/ holds a 184 MB old log.
#
#   tools/stage_server.sh [--with-world]
#
# --with-world also copies data/osm_forts.json and data/osm_biomes.json (about
# 200 MB), which is what puts real stops and gyms on the map. Without it the
# server still runs and you place your own in the World Manager.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$(cd "$HERE/.." && pwd)/work/server"
OUT="$HERE/Staging/PythonServer"
WITH_WORLD=0
[ "${1:-}" = "--with-world" ] && WITH_WORLD=1

[ -d "$SERVER" ] || { echo "No work/server (looked in $SERVER)" >&2; exit 1; }
[ -f "$SERVER/research.py" ] || { echo "$SERVER has no research.py -- that is the stale copy" >&2; exit 1; }

echo "==> python sources"
rm -rf "$OUT"
mkdir -p "$OUT"
for f in "$SERVER"/*.py; do
    name="$(basename "$f")"
    # frida_*.py and probe_run.py import frida, which has no iOS wheel; they are
    # desktop debugging tools and nothing in the server imports them.
    case "$name" in
        frida_*.py|probe_run.py|dupe_test.py|setup_*.py|gen_certs.py) continue ;;
        # server_gui.py is the desktop tkinter window and imports tkinter.
        # poidownload.py and the fetch_* helpers DO ship: downloads_ui imports
        # poidownload at module scope, so leaving it out made the editor's
        # "World Data" tab raise ImportError and the link do nothing. The
        # actual region download needs osmium, which has no iOS wheel -- that
        # path reports its own error in the page rather than breaking the tab.
        server_gui.py) continue ;;
    esac
    cp "$f" "$OUT/"
done
cp "$HERE/WindstockLauncher/Server/ws_boot.py" "$OUT/"
echo "    $(ls "$OUT"/*.py | wc -l | tr -d ' ') modules"

echo "==> vendored packages"
mkdir -p "$OUT/vendor"
python3 - "$OUT/vendor" <<'PY'
import importlib.util, os, shutil, sys
dest = sys.argv[1]
# s2sphere does the cell-id maths the protocol is built on; `future` is its one
# dependency and is pure Python, so both travel with us rather than being
# reimplemented.
for name in ("s2sphere", "future", "past", "libfuturize", "libpasteurize"):
    spec = importlib.util.find_spec(name)
    if spec is None or not spec.submodule_search_locations:
        print(f"    {name}: not installed, skipped")
        continue
    src = list(spec.submodule_search_locations)[0]
    out = os.path.join(dest, name)
    shutil.rmtree(out, ignore_errors=True)
    shutil.copytree(src, out, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "tests", "test"))
    print(f"    {name}: ok")
PY

echo "==> certificates"
cp -R "$SERVER/certs" "$OUT/certs"
# The CA private key has no business on a phone; the leaf key does, because the
# server presents it.
rm -f "$OUT/certs/ca.key" "$OUT/certs/ca.srl" "$OUT/certs/server.csr" \
      "$OUT/certs/server.crt.oldbak"

echo "==> assets (iOS bundle set only)"
cp -R "$SERVER/assets_ios" "$OUT/assets_ios"
cp -R "$SERVER/shopicons" "$OUT/shopicons"
# Leaflet, vendored. The World Manager used to pull it from unpkg.com, so on a
# phone with no internet the map library never arrived, the first L.map() threw,
# and every control below it on the page stopped working.
cp -R "$SERVER/webassets" "$OUT/webassets"
cp "$SERVER/game_master.bin" "$OUT/" 2>/dev/null || true

echo "==> settings help"
# Per-setting prose for the app's native settings screen. Without it the UI
# shows bare key names, and something like server.custom_login_page -- an
# experiment that breaks login outright -- looks as harmless as any other
# toggle. Sources: the comments in settings.py, then the _readme in
# settings.json for the keys those leave bare.
python3 "$HERE/tools/extract_settings_help.py" "$SERVER/settings.py" \
        "$OUT/settings_help.json" "$SERVER/data/settings.json"

echo "==> research art + data tables"
# research.py serves these over /research/art/ and /research/font/, and the
# tweak's screens are blank without them.
cp -R "$SERVER/research_art" "$OUT/research_art"
for f in soundpack_catalogue.json spawn_rates_2016.json; do
    [ -f "$SERVER/$f" ] && cp "$SERVER/$f" "$OUT/"
done

echo "==> seed data"
mkdir -p "$OUT/seed-data"
for f in settings.json places.json events.json gyms.json lures.json raid.json \
         nominations.json; do
    [ -f "$SERVER/data/$f" ] && cp "$SERVER/data/$f" "$OUT/seed-data/"
done
# Hand-placed stops and spawns sit wherever YOU were standing when you made
# them, and seed-data goes to everyone who installs this IPA. Ship the switches
# but not the places. Existing installs keep theirs: _seed never overwrites.
# KEEP_PLACES=1 ships them anyway (e.g. a build for your own phone only).
if [ "${KEEP_PLACES:-0}" != "1" ] && [ -f "$OUT/seed-data/places.json" ]; then
    python3 - "$OUT/seed-data/places.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
n = len(d.get("forts") or []) + len(d.get("spawns") or [])
d["forts"], d["spawns"] = [], []
json.dump(d, open(p, "w"), indent=1)
print(f"    stripped {n} hand-placed fort(s)/spawn(s) from the shipped places.json")
PYEOF
fi
if [ "$WITH_WORLD" = "1" ]; then
    # NOT the raw JSON, and NOT in seed-data. json.load of osm_forts.json +
    # osm_biomes.json costs ~1.6 GB of heap, which gets the app killed while
    # the game runs beside it; and everything in seed-data is copied into
    # Documents on first launch, doubling 200 MB on the phone. Instead: one
    # cell-indexed SQLite file, read in place from the bundle (worlddb.py).
    # Measured: same answers as the JSON, 20 MB peak instead of 1040 MB.
    mkdir -p "$OUT/world"
    python3 "$HERE/tools/build_world_db.py" "$SERVER/data" "$OUT/world/world.sqlite"
    echo "    included the OSM world data (world/world.sqlite)"
else
    echo "    skipped the OSM world data (pass --with-world for real stops/gyms)"
fi

find "$OUT" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
echo "done: $(du -sh "$OUT" | cut -f1) in $OUT"
