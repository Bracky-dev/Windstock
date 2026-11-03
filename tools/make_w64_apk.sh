#!/bin/bash
# Build "Windstock 64" (com.windstock.windstock64): the launcher with the game built in, for
# 64-bit-only phones. The game (32-bit Pokemon GO 0.35) runs inside the app under translator64
# (work/translator64), in the app's ":game" process -- see app/src/w64/.
#
#   tools/make_w64_apk.sh            -> build/Windstock64.apk
#
# Needs, already built:
#   $UPSTREAM/build-arm64/core/libzbridge.so + libzbproxy.so   (Chucny's runtime + our hooks, built with
#                                                     cmake from a clone of his repo; UPSTREAM defaults
#                                                     to ~/Desktop/chucny-translator-src/src)
#   work/mods/windstock-t64.js                        (cd work/mods/android-035 && npm run build:t64)
#   Staging/assets/PythonServer                       (tools/stage_server.sh, shared with the launcher)
#   ~/Desktop/project-windstock-site/assets/windstock-android-game.apk   (the game: dex, res, plugin)
# and the guest libs + metadata in work/translator64/android-app/assets/guest (its make_apk.sh
# stages them). The Unity data is the same patched set translator64 ships (patch_badges + wobble).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
[ -f "$HOME/android-toolchain/env.sh" ] && source "$HOME/android-toolchain/env.sh"
BT=$ANDROID_HOME/build-tools/35.0.0
T64="$REPO/work/translator64/android-app"      # guest libs + Unity data cache
UP="${UPSTREAM:-$HOME/Desktop/chucny-translator-src/src}"
GAMEAPK="$HOME/Desktop/project-windstock-site/assets/windstock-android-game.apk"
[ -f "$GAMEAPK" ] || GAMEAPK="$REPO/RELEASE/pokemon-go-0.35-windstock.apk"      # same game classes + resources
STAGE="$HERE/Staging/w64"
OUT="$HERE/build/w64"

for f in "$UP/build-arm64/core/libzbridge.so" "$UP/build-arm64/core/libzbproxy.so" "$REPO/work/mods/windstock-t64.js" "$GAMEAPK" \
         "$T64/assets/guest/libil2cpp.so" "$T64/assets/guest/Data/Managed/Metadata/global-metadata.dat"; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
[ -d "$HERE/Staging/assets/PythonServer" ] || "$HERE/tools/stage_server.sh" --with-world | tail -1

echo "==> staging the translator"
rm -rf "$STAGE" "$OUT"; mkdir -p "$STAGE/jniLibs/arm64-v8a" "$STAGE/assets/w64" "$OUT"
LIBS="$STAGE/jniLibs/arm64-v8a"
cp "$UP/build-arm64/core/libzbridge.so" "$LIBS/"
# the runtime the guest needs (zb/): AOSP sysroot, zbhost + guest shim libs, the arm64 proxy
mkdir -p "$STAGE/assets/zbrt"
cp -R "$UP/translator/sysroot" "$STAGE/assets/zbrt/sysroot"
cp -R "$UP/runtime/guest" "$STAGE/assets/zbrt/guest"
mkdir -p "$STAGE/assets/zbrt/host"; cp "$UP/build-arm64/core/libzbproxy.so" "$STAGE/assets/zbrt/host/"
cp "$REPO/work/translator64/NOTICE" "$STAGE/assets/NOTICE.txt"
cp "$REPO/work/translator64/zb-app/LICENSE-AGPL-3.0" "$STAGE/assets/LICENSE-AGPL-3.0.txt"
# the game's own Java, loaded by its own class loader (so System.loadLibrary reaches the proxies)
mkdir -p "$OUT/gamedex0"; unzip -p "$GAMEAPK" classes.dex > "$OUT/gamedex0/classes.dex"
( cd "$OUT/gamedex0" && zip -q -X "$STAGE/assets/game-classes.zip" classes.dex )
# the Windstock agent: arm64 Frida gadget in script mode + the t64 bundle
cp "$HERE/tools/cache/frida-gadget-16.7.19-android-arm64.so" "$LIBS/libfrida-gadget.so"
cp "$REPO/work/mods/windstock-t64.js" "$LIBS/libfrida-gadget.script.so"
printf '{\n  "interaction": {\n    "type": "script",\n    "path": "libfrida-gadget.script.so"\n  }\n}\n' \
    > "$LIBS/libfrida-gadget.config.so"
# the game's arm32 libraries (copied to files/t64/plugins/<pkg>/lib on first start)
mkdir -p "$STAGE/assets/guest"; cp "$T64"/assets/guest/*.so "$STAGE/assets/guest/"
# the agent's sounds + look (assets/windstock/*), as translator64's make_apk.sh adds them
TWEAK="$REPO/work/mods/ios-tweak-035"
mkdir -p "$STAGE/assets/windstock"
for f in "$TWEAK"/night/windstock_* "$TWEAK"/sounds/windstock_sfx_*.* "$TWEAK"/sounds/windstock_music_*.*; do
    [ -f "$f" ] && cp "$f" "$STAGE/assets/windstock/$(basename "$f" | sed 's/^windstock_//')"
done
# the game's own Android resources, as an APK of their own (GameResources.kt)
rm -rf "$OUT/gameres"; mkdir -p "$OUT/gameres"
( cd "$OUT/gameres" && unzip -q "$GAMEAPK" AndroidManifest.xml resources.arsc "res/*" \
  && zip -q -X -r "$STAGE/assets/w64/game-res.apk" AndroidManifest.xml resources.arsc res )

echo "==> Unity data"
# assets/bin/Data/** from the patch_badges base + the Poke Ball wobble fix (shared caches with
# tools/make_apk.sh and translator64's make_apk.sh), stored: Unity mmaps it out of the APK.
RELEASE_APK="$REPO/RELEASE/pokemon-go-0.35-windstock.apk"
BADGES_BASE="$HERE/tools/cache/base-badges.apk"
STALE=""
for f in "$REPO"/work/tools/{patch_badges,badge_art,research_buttons,profile_friends,loading_screen,splash_screen}.py \
         "$REPO"/work/mods/loading-screen/*; do
    [ -f "$f" ] && [ "$f" -nt "$BADGES_BASE" ] && STALE=1
done
if [ ! -f "$BADGES_BASE" ] || [ "$RELEASE_APK" -nt "$BADGES_BASE" ] || [ -n "$STALE" ]; then
    mkdir -p "$(dirname "$BADGES_BASE")"
    python3 "$REPO/work/tools/patch_badges.py" "$RELEASE_APK" -o "$BADGES_BASE" | tail -1
fi
want=$(shasum < "$T64/assets/guest/Data/Managed/Metadata/global-metadata.dat" | cut -c1-40)
got=$(unzip -p "$BADGES_BASE" assets/bin/Data/Managed/Metadata/global-metadata.dat | shasum | cut -c1-40)
[ "$want" = "$got" ] || { echo "global-metadata.dat in $BADGES_BASE does not match the guest libil2cpp.so -- stop" >&2; exit 1; }
DATA_CACHE="$T64/cache/unity-data"
if [ ! -f "$DATA_CACHE/.stamp" ] || [ "$BADGES_BASE" -nt "$DATA_CACHE/.stamp" ] \
   || [ "$REPO/work/tools/patch_badges.py" -nt "$DATA_CACHE/.stamp" ]; then
    rm -rf "$DATA_CACHE"; mkdir -p "$DATA_CACHE"
    ( cd "$DATA_CACHE" && unzip -q "$BADGES_BASE" "assets/bin/*" )
    python3 "$REPO/work/tools/patch_badges.py" --shakes-only "$DATA_CACHE/assets/bin/Data" | tail -1
    touch "$DATA_CACHE/.stamp"
fi

echo "==> gradle (w64)"
( cd "$HERE" && ./gradlew assembleW64Release --no-daemon -q )
APK="$HERE/app/build/outputs/apk/w64/release/app-w64-release.apk"

echo "==> adding the game"
cp "$APK" "$OUT/app.apk"
# the 32-bit game APK the launcher installs: not here, the game is built in
zip -q -d "$OUT/app.apk" "assets/game/*" 2>/dev/null || true
# the game's Java classes (com.unity3d.player.*, Niantic, Upsight) as the next classesN.dex
n=1; while unzip -l "$OUT/app.apk" "classes$([ $n = 1 ] || echo $n).dex" >/dev/null 2>&1; do n=$((n+1)); done
mkdir -p "$OUT/gamedex"
unzip -p "$GAMEAPK" classes.dex > "$OUT/gamedex/classes$n.dex"
( cd "$OUT/gamedex" && zip -q -X "$OUT/app.apk" "classes$n.dex" )
( cd "$DATA_CACHE" && zip -0 -q -X -r "$OUT/app.apk" assets )
"$BT/zipalign" -f -p 4 "$OUT/app.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign --ks "$HERE/tools/windstock-launcher.jks" --ks-pass pass:windstock --key-pass pass:windstock \
    --ks-key-alias windstock --out "$HERE/build/Windstock64.apk" "$OUT/aligned.apk"
"$BT/apksigner" verify "$HERE/build/Windstock64.apk"
rm -f "$OUT/app.apk" "$OUT/aligned.apk"
echo "done: $HERE/build/Windstock64.apk ($(du -h "$HERE/build/Windstock64.apk" | cut -f1), game dex = classes$n.dex)"
