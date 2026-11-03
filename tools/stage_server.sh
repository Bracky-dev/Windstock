#!/bin/bash
# Copy the Windstock server into Staging/assets/PythonServer, from where the
# launcher unpacks it on the phone (ServerAssets.kt).
#
# The Android twin of ios-launcher/tools/stage_server.sh, and deliberately the
# same selection -- see the comments there for why each piece is in or out.
# Differences:
#   * assets/ (the ANDROID asset bundles, UnityFS target 13) instead of
#     assets_ios/ -- the two sets are not interchangeable;
#   * ws_boot.py is the SAME file the iOS launcher ships (it is entirely
#     environment-driven), taken from ios-launcher/WindstockLauncher/Server;
#   * a MANIFEST.txt listing every file with its size, which is what the app
#     walks to unpack (AssetManager.list() over thousands of files is slow).
#
#   tools/stage_server.sh [--with-world] [--no-models]
#
# --no-models leaves out assets/ (172 MB of 3D Pokemon bundles) for phones short on
# space: the server then sends an empty asset digest and the game draws its built-in
# 2D icons instead of models (shinies need the models, so they will not show).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SERVER="$REPO/work/server"
IOS="$REPO/ios-launcher"
OUT="$HERE/Staging/assets/PythonServer"
WITH_WORLD=0
MODELS=1
for arg in "$@"; do
    case "$arg" in
        --with-world) WITH_WORLD=1 ;;
        --no-models) MODELS=0 ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done

[ -f "$SERVER/research.py" ] || { echo "$SERVER has no research.py -- that is the stale copy" >&2; exit 1; }

echo "==> python sources"
rm -rf "$OUT"
mkdir -p "$OUT"
for f in "$SERVER"/*.py; do
    name="$(basename "$f")"
    case "$name" in
        # desktop-only: frida tooling, the tkinter window, cert generation
        frida_*.py|probe_run.py|dupe_test.py|setup_*.py|gen_certs.py|server_gui.py) continue ;;
    esac
    cp "$f" "$OUT/"
done
cp "$IOS/WindstockLauncher/Server/ws_boot.py" "$OUT/"
echo "    $(ls "$OUT"/*.py | wc -l | tr -d ' ') modules"

echo "==> vendored packages"
mkdir -p "$OUT/vendor"
python3 - "$OUT/vendor" "$IOS/Staging/PythonServer/vendor" <<'PY'
import importlib.util, os, shutil, sys
dest, fallback = sys.argv[1], sys.argv[2]
for name in ("s2sphere", "future", "past", "libfuturize", "libpasteurize"):
    spec = importlib.util.find_spec(name)
    src = list(spec.submodule_search_locations)[0] if spec and spec.submodule_search_locations else None
    if src is None and os.path.isdir(os.path.join(fallback, name)):
        src = os.path.join(fallback, name)
    if src is None:
        print(f"    {name}: not installed, skipped")
        continue
    shutil.copytree(src, os.path.join(dest, name),
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "tests", "test"))
    print(f"    {name}: ok")
PY

echo "==> certificates"
cp -R "$SERVER/certs" "$OUT/certs"
# The CA private key has no business on a phone; the leaf key does.
rm -f "$OUT/certs/ca.key" "$OUT/certs/ca.srl" "$OUT/certs/server.csr" "$OUT/certs/server.crt.oldbak"

if [ "$MODELS" = "1" ]; then
    echo "==> assets (Android bundle set only)"
    mkdir -p "$OUT/assets"
    # The *.orig digest is a backup from an earlier conversion, not served.
    find "$SERVER/assets" -maxdepth 1 -type f ! -name '*.orig' -exec cp {} "$OUT/assets/" \;
else
    echo "==> assets: left out (--no-models) -- the game shows 2D icons"
fi
cp -R "$SERVER/shopicons" "$OUT/shopicons"
cp -R "$SERVER/webassets" "$OUT/webassets"
cp "$SERVER/game_master.bin" "$OUT/" 2>/dev/null || true

echo "==> settings help"
python3 "$IOS/tools/extract_settings_help.py" "$SERVER/settings.py" \
        "$OUT/settings_help.json" "$SERVER/data/settings.json"

echo "==> research art + data tables"
cp -R "$SERVER/research_art" "$OUT/research_art"
cp -R "$SERVER/friends_art" "$OUT/friends_art"          # the Friends screens' icons
for f in soundpack_catalogue.json spawn_rates_2016.json gen2_sizes.json; do
    [ -f "$SERVER/$f" ] && cp "$SERVER/$f" "$OUT/"
done

echo "==> seed data"
mkdir -p "$OUT/seed-data"
for f in settings.json places.json events.json gyms.json lures.json raid.json nominations.json; do
    [ -f "$SERVER/data/$f" ] && cp "$SERVER/data/$f" "$OUT/seed-data/"
done
# Hand-placed stops sit wherever YOU stood when you made them; ship the
# switches but not the places. KEEP_PLACES=1 ships them anyway.
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
    mkdir -p "$OUT/world"
    if [ -f "$IOS/Staging/PythonServer/world/world.sqlite" ] && [ "${REBUILD_WORLD:-0}" != "1" ]; then
        # Same data, already built for the iOS app; REBUILD_WORLD=1 rebuilds.
        cp "$IOS/Staging/PythonServer/world/world.sqlite" "$OUT/world/"
        echo "    reused the iOS build's world.sqlite"
    else
        python3 "$IOS/tools/build_world_db.py" "$SERVER/data" "$OUT/world/world.sqlite"
    fi
else
    echo "    skipped the OSM world data (pass --with-world for real stops/gyms)"
fi

find "$OUT" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "$OUT" -name ".DS_Store" -delete 2>/dev/null || true

# aapt silently leaves out dot-files and directories starting with "_" from
# assets; a server file with such a name would vanish from the APK unnoticed.
dropped="$(cd "$OUT" && { find . -name '.*' -type f; find . -type d -name '_*'; })"
[ -z "$dropped" ] || { echo "aapt would drop these from the APK:" >&2; echo "$dropped" >&2; exit 1; }

echo "==> manifest"
# "<bytes> <sha1> <path>": the hash lets an update keep files that did not change
# instead of copying all of them out of the APK again (ServerAssets.ensure).
python3 - "$OUT" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
rows = []
for d, _, files in os.walk(root):
    for name in files:
        rel = os.path.relpath(os.path.join(d, name), root)
        if rel == "MANIFEST.txt":
            continue
        h = hashlib.sha1()
        with open(os.path.join(root, rel), "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        rows.append((rel, os.path.getsize(os.path.join(root, rel)), h.hexdigest()))
with open(os.path.join(root, "MANIFEST.txt"), "w") as out:
    for rel, size, digest in sorted(rows):
        out.write(f"{size} {digest} {rel}\n")
PY
echo "done: $(wc -l < "$OUT/MANIFEST.txt" | tr -d ' ') files, $(du -sh "$OUT" | cut -f1) in $OUT"
