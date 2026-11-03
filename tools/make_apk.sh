#!/bin/bash
# Build the Windstock launcher APK for other people, end to end:
#
#   1. the Android agent      (work/mods/android-035 -> work/mods/windstock-android.js)
#   2. the game APK           (tools/build_game_apk.sh -> Staging/assets/game/)
#   3. the server             (tools/stage_server.sh --with-world -> Staging/assets/PythonServer/)
#   4. the launcher           (gradle assembleRelease -> build/WindstockLauncher.apk)
#
#   tools/make_apk.sh [--no-world] [--no-models] [--skip-agent] [--skip-game]
#
# The Android twin of ios-launcher/tools/make_ipa.sh. Needs the toolchain from
# ~/android-toolchain (JDK 17, Android SDK, build-tools) and node for the agent.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORLD="--with-world"
MODELS=""
AGENT=1
GAME=1
for arg in "$@"; do
    case "$arg" in
        --no-world) WORLD="" ;;
        --no-models) MODELS="--no-models" ;;
        --skip-agent) AGENT=0 ;;
        --skip-game) GAME=0 ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done

[ -f "$HOME/android-toolchain/env.sh" ] && source "$HOME/android-toolchain/env.sh"
[ -f "$HERE/local.properties" ] || echo "sdk.dir=$ANDROID_HOME" > "$HERE/local.properties"
[ -f "$HERE/tools/windstock-launcher.jks" ] || "$HERE/tools/make_keystore.sh"

if [ "$AGENT" = "1" ]; then
    echo "==> agent"
    ( cd "$REPO/work/mods/android-035" && npm test >/dev/null && npm run build >/dev/null )
    echo "    $(head -2 "$REPO/work/mods/windstock-android.js" | tail -1)"
fi
if [ "$GAME" = "1" ]; then
    echo "==> game"
    # The RELEASE APK has none of patch_badges' art (medals, store sprites, the
    # XP-bonus W); building straight from it silently drops them. Patch once,
    # keep the result in tools/cache, rebuild it only when RELEASE changes.
    RELEASE_APK="$REPO/RELEASE/pokemon-go-0.35-windstock.apk"
    BADGES_BASE="$HERE/tools/cache/base-badges.apk"
    # ...or when the patcher / its art changed (loading screen, medals, buttons)
    STALE=""
    for f in "$REPO"/work/tools/{patch_badges,badge_art,research_buttons,profile_friends,loading_screen,splash_screen}.py \
             "$REPO"/work/mods/loading-screen/*; do
        [ -f "$f" ] && [ "$f" -nt "$BADGES_BASE" ] && STALE=1
    done
    if [ ! -f "$BADGES_BASE" ] || [ "$RELEASE_APK" -nt "$BADGES_BASE" ] || [ -n "$STALE" ]; then
        mkdir -p "$HERE/tools/cache"
        python3 "$REPO/work/tools/patch_badges.py" "$RELEASE_APK" -o "$BADGES_BASE" | tail -1
    fi
    "$HERE/tools/build_game_apk.sh" "$BADGES_BASE" | tail -1
fi
echo "==> server"
"$HERE/tools/stage_server.sh" $WORLD $MODELS | tail -1

echo "==> launcher"
( cd "$HERE" && ./gradlew assembleLauncherRelease --no-daemon -q )
mkdir -p "$HERE/build"
cp "$HERE/app/build/outputs/apk/launcher/release/app-launcher-release.apk" "$HERE/build/WindstockLauncher.apk"
apksigner verify "$HERE/build/WindstockLauncher.apk"
echo "done: $HERE/build/WindstockLauncher.apk ($(du -h "$HERE/build/WindstockLauncher.apk" | cut -f1))"
