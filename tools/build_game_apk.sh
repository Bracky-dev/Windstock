#!/bin/bash
# Build the game the launcher installs: the Windstock 0.35 APK plus the windstock agent.
#
#   tools/build_game_apk.sh [base.apk]      (default: RELEASE/pokemon-go-0.35-windstock.apk)
#
# What goes in, and why:
#   * frida-gadget (arm, 16.7.19 -- 17.x crashes at startup on a Galaxy S9 / Android 10) as
#     lib/armeabi-v7a/libfrida-gadget.so, in "script" mode: it runs the agent bundled next
#     to it as libfrida-gadget.script.so, no computer or root involved;
#   * the agent, work/mods/windstock-android.js (npm run build in work/mods/android-035),
#     which asks the launcher for its config, redirects the network to the server and
#     applies the mods -- the job the tweak + WSNetRedirect do inside the iOS launcher;
#   * a static initializer on UnityPlayerNativeActivity that calls WSBoot.boot() (game-boot/,
#     compiled into classes2.dex), which reports why the last game process died to the
#     launcher's log and then loads the gadget, so the agent is in before Unity opens a
#     connection (same hook as the 0.29 mods APK);
#   * assets/windstock-game.json, a build stamp the launcher compares to spot updates;
#   * assets/windstock/: the night and Halloween music and the night sky picture the agent's
#     Halloween look paints its haze into (the iOS IPA ships the same files).
#
#   * a NEW APP ID, com.windstock.pokemongo ("Windstock GO"), so it installs next to the
#     real Pokemon GO from the Play Store instead of fighting it for
#     com.nianticlabs.pokemongo -- the recipe the 0.29 "PoGO Classic" build used: the
#     package, its C2D_MESSAGE permission, the GCM category and the Upsight authority.
#     GAME_PACKAGE=com.nianticlabs.pokemongo keeps the original ID (and skips the full
#     resource decode that renaming needs).
#
# Signed with work/tools/pogo.keystore -- the key the released Windstock APKs carry -- so
# with the original ID it installs as an UPDATE over a Windstock 0.35 already on the phone.
#
# Output: Staging/assets/game/pokemongo.apk (+ windstock-game.json), which the launcher
# build packs into its assets.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BASE="${1:-$REPO/RELEASE/pokemon-go-0.35-windstock.apk}"
AGENT="${AGENT:-$REPO/work/mods/windstock-android.js}"
APKTOOL="$REPO/work/tools/apktool.jar"
KEYSTORE="$REPO/work/tools/pogo.keystore"
ORIG_PACKAGE=com.nianticlabs.pokemongo
GAME_PACKAGE="${GAME_PACKAGE:-com.windstock.pokemongo}"
GAME_LABEL="${GAME_LABEL:-Windstock GO}"
GADGET_VERSION="${GADGET_VERSION:-16.7.19}"
GADGET_CACHE="$HERE/tools/cache/frida-gadget-$GADGET_VERSION-android-arm.so"
GADGET_DONOR="$REPO/APK&IPA/stuff/pogo-0.29-windstock-mods.apk"
OUT_DIR="$HERE/Staging/assets/game"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ws-game.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[ -f "$HOME/android-toolchain/env.sh" ] && source "$HOME/android-toolchain/env.sh"
command -v java >/dev/null || { echo "java not found (source ~/android-toolchain/env.sh)" >&2; exit 1; }
command -v apksigner >/dev/null || { echo "apksigner not found (Android build-tools)" >&2; exit 1; }
[ -f "$BASE" ] || { echo "no base APK at $BASE" >&2; exit 1; }
[ -f "$AGENT" ] || { echo "no agent -- cd work/mods/android-035 && npm run build" >&2; exit 1; }

echo "==> gadget $GADGET_VERSION"
if [ ! -f "$GADGET_CACHE" ]; then
    mkdir -p "$(dirname "$GADGET_CACHE")"
    if [ -f "$GADGET_DONOR" ] && [ "$GADGET_VERSION" = "17.17.0" ]; then
        unzip -p "$GADGET_DONOR" lib/armeabi-v7a/libfrida-gadget.so > "$GADGET_CACHE"
        echo "    taken from $(basename "$GADGET_DONOR")"
    else
        curl -fsSL "https://github.com/frida/frida/releases/download/$GADGET_VERSION/frida-gadget-$GADGET_VERSION-android-arm.so.xz" \
            | python3 -c 'import lzma, sys; sys.stdout.buffer.write(lzma.decompress(sys.stdin.buffer.read()))' \
            > "$GADGET_CACHE.part"
        mv "$GADGET_CACHE.part" "$GADGET_CACHE"
        echo "    downloaded from github.com/frida"
    fi
fi
strings "$GADGET_CACHE" | grep -F "$GADGET_VERSION" >/dev/null || { echo "gadget cache is not $GADGET_VERSION" >&2; exit 1; }

echo "==> decode $(basename "$BASE")"
if [ "$GAME_PACKAGE" = "$ORIG_PACKAGE" ]; then
    # Resources untouched: -r keeps the original resources.arsc byte for byte.
    java -jar "$APKTOOL" d -r -f -o "$WORK/src" "$BASE" >/dev/null
else
    java -jar "$APKTOOL" d -f -o "$WORK/src" "$BASE" >/dev/null
    echo "==> app id $ORIG_PACKAGE -> $GAME_PACKAGE (\"$GAME_LABEL\")"
    python3 - "$WORK/src" "$ORIG_PACKAGE" "$GAME_PACKAGE" "$GAME_LABEL" <<'PY'
import glob, os, re, sys
root, old, new, label = sys.argv[1:]
m = os.path.join(root, "AndroidManifest.xml")
s = open(m, encoding="utf-8").read()
n0 = s.count(old)
# Only identifiers that must be unique per app. Class names (com.nianticlabs.nia.*)
# are not the package and stay; every name in this manifest is absolute.
s = s.replace(f'package="{old}"', f'package="{new}"')
s = s.replace(f'"{old}.permission.C2D_MESSAGE"', f'"{new}.permission.C2D_MESSAGE"')
s = s.replace(f'<category android:name="{old}"/>', f'<category android:name="{new}"/>')
s = s.replace(f'android:authorities="{old}.upsight"', f'android:authorities="{new}.upsight"')
s = s.replace(f'android:value="{old}.848232511240"', f'android:value="{new}.848232511240"')
left = [l.strip() for l in s.splitlines() if old in l]
if left:
    sys.exit("unhandled package references left in the manifest:\n  " + "\n  ".join(left))
open(m, "w", encoding="utf-8").write(s)
# Generated Manifest$permission constants carry the permission name too.
fixed = 0
for f in glob.glob(os.path.join(root, "smali*", "**", "Manifest$permission.smali"), recursive=True):
    t = open(f, encoding="utf-8").read()
    if f"{old}.permission" in t:
        open(f, "w", encoding="utf-8").write(t.replace(f"{old}.permission", f"{new}.permission"))
        fixed += 1
# The home-screen name, in every language that has one.
labels = 0
for f in glob.glob(os.path.join(root, "res", "values*", "strings.xml")):
    t = open(f, encoding="utf-8").read()
    t2 = re.sub(r'(<string name="app_name">)[^<]*(</string>)', lambda mm: mm.group(1) + label + mm.group(2), t)
    if t2 != t:
        open(f, "w", encoding="utf-8").write(t2)
        labels += 1
print(f"    manifest: {n0} references renamed; {fixed} permission constants; {labels} label(s)")
PY
fi

echo "==> full screen on tall phones"
# 0.35 targets API 23 with no max aspect, so Android letterboxes it to 16:9-ish (1.86)
# with black bars on any 18:9+ phone. Declare 2.4 (covers 20:9) and let the game draw
# into the notch area too -- Unity 5 sizes itself from the surface it gets.
python3 - "$WORK/src/AndroidManifest.xml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="strict").read() if open(p, "rb").read(5) == b"<?xml" else None
if s is None:
    print("    manifest kept binary (GAME_PACKAGE unchanged) -- skipped")
    sys.exit(0)
if 'android.max_aspect' not in s:
    i = s.index(">", s.index("<application")) + 1
    s = s[:i] + '\n        <meta-data android:name="android.max_aspect" android:value="2.4"/>' + s[i:]
act = 'android:name="com.unity3d.player.UnityPlayerNativeActivity"'
if 'android:maxAspectRatio' not in s:
    s = s.replace(act, act + ' android:maxAspectRatio="2.4" android:resizeableActivity="false"', 1)
open(p, "w", encoding="utf-8").write(s)
print("    max aspect 2.4")
PY

echo "==> Poke Ball wobbles"
# The stock animator cut a 3-wobble break-out short after one rock, so every Pokemon
# broke out on the first wobble; the iOS guest gets the same fix from embed_guest.sh.
python3 "$REPO/work/tools/patch_badges.py" --shakes-only "$WORK/src/assets/bin/Data"

echo "==> gadget loader"
SMALI="$(grep -rl '^\.class public Lcom/unity3d/player/UnityPlayerNativeActivity;' "$WORK/src"/smali* | head -1)"
[ -n "$SMALI" ] || { echo "UnityPlayerNativeActivity not found" >&2; exit 1; }
python3 - "$SMALI" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if 'WSBoot;->boot' in s:
    print("    already loads the gadget")
    sys.exit(0)
# WSBoot.boot() (classes2.dex) loads the gadget itself, after its crash reporting is up.
load = '    invoke-static {}, Lcom/windstock/boot/WSBoot;->boot()V\n\n'

m = re.search(r'\.method static constructor <clinit>\(\)V\n(\s*\.(?:locals|registers) (\d+)\n)', s)
if m:
    # An existing initializer: make sure it has a register, then load first.
    n = int(m.group(2))
    head = m.group(1)
    if n < 1:
        head = head.replace(m.group(2), "1")
    s = s[:m.start(1)] + head + "\n" + load + s[m.end(1):]
    print("    prepended to the existing <clinit>")
else:
    clinit = ('.method static constructor <clinit>()V\n    .locals 1\n\n' + load +
              '    return-void\n.end method\n\n')
    i = s.index("# direct methods\n") + len("# direct methods\n") if "# direct methods\n" in s else s.index(".method")
    s = s[:i] + clinit + s[i:]
    print("    added a <clinit>")
open(p, "w", encoding="utf-8").write(s)
PY

echo "==> agent + config"
LIB="$WORK/src/lib/armeabi-v7a"
mkdir -p "$LIB"
cp "$GADGET_CACHE" "$LIB/libfrida-gadget.so"
cp "$AGENT" "$LIB/libfrida-gadget.script.so"
cat > "$LIB/libfrida-gadget.config.so" <<'JSON'
{
  "interaction": {
    "type": "script",
    "path": "libfrida-gadget.script.so",
    "on_change": "ignore"
  }
}
JSON
echo "==> night + Halloween music, night sky"
# Same files the iOS IPA embeds (embed_guest.sh): windstock_night = the night map theme,
# windstock_<clip>_night (102_encounter_night = night catch), windstock_walk_halloween, the
# sky picture. The prefix goes: assets/windstock/<name>.mp3 is what the agent looks up.
NIGHT="$REPO/work/mods/ios-tweak-035/night"
mkdir -p "$WORK/src/assets/windstock"
for f in "$NIGHT"/windstock_*; do
    cp "$f" "$WORK/src/assets/windstock/$(basename "$f" | sed 's/^windstock_//')"
done
ls "$WORK/src/assets/windstock" | tr '\n' ' '; echo
echo "==> research sounds"
# The modern game's Research sounds (se_go_quests_*), shared with the iOS IPA: windstock_sfx_<clip>
# -> assets/windstock/sfx_<clip>; the agent plays them (research.js modernSfx).
for f in "$REPO"/work/mods/ios-tweak-035/sounds/windstock_sfx_*.*; do
    cp "$f" "$WORK/src/assets/windstock/$(basename "$f" | sed 's/^windstock_//')"
done
ls "$WORK/src/assets/windstock" | grep '^sfx_' | tr '\n' ' '; echo
# Friends trade-room music (agent v194, halloween.js extraMusic): windstock_music_<clip> -> music_<clip>
for f in "$REPO"/work/mods/ios-tweak-035/sounds/windstock_music_*.*; do
    [ -f "$f" ] && cp "$f" "$WORK/src/assets/windstock/$(basename "$f" | sed 's/^windstock_//')"
done

STAMP="$(date -u +%Y%m%d.%H%M)"
AGENT_SHA="$(shasum -a 256 "$AGENT" | cut -c1-16)"
mkdir -p "$WORK/src/assets"
cat > "$WORK/src/assets/windstock-game.json" <<JSON
{"version": "0.35.0", "stamp": "$STAMP", "agent": "$AGENT_SHA", "gadget": "$GADGET_VERSION", "package": "$GAME_PACKAGE"}
JSON

echo "==> build + sign"
java -jar "$APKTOOL" b -o "$WORK/unsigned.apk" "$WORK/src" >/dev/null
# WSBoot goes in its own dex: classes.dex is already big, and ART loads classes2.dex natively.
if unzip -l "$WORK/unsigned.apk" | grep -q ' classes2\.dex$'; then
    echo "base APK already has a classes2.dex -- pick another name for WSBoot" >&2; exit 1
fi
ANDROID_JAR="$(ls -d "$ANDROID_HOME"/platforms/android-*/android.jar | tail -1)"
mkdir -p "$WORK/boot/classes" "$WORK/boot/dex"
javac --release 8 -nowarn -classpath "$ANDROID_JAR" -d "$WORK/boot/classes" "$HERE/game-boot/WSBoot.java"
d8 --min-api 24 --lib "$ANDROID_JAR" --output "$WORK/boot/dex" "$WORK/boot/classes"/com/windstock/boot/*.class
mv "$WORK/boot/dex/classes.dex" "$WORK/boot/dex/classes2.dex"
(cd "$WORK/boot/dex" && zip -q "$WORK/unsigned.apk" classes2.dex)
zipalign -f -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
apksigner sign --ks "$KEYSTORE" --ks-pass pass:android --ks-key-alias pogo \
    --out "$WORK/signed.apk" "$WORK/aligned.apk"
apksigner verify "$WORK/signed.apk"

mkdir -p "$OUT_DIR"
cp "$WORK/signed.apk" "$OUT_DIR/pokemongo.apk"
cp "$WORK/src/assets/windstock-game.json" "$OUT_DIR/windstock-game.json"
rm -f "$OUT_DIR/pokemongo.apk.idsig"
echo "done: $OUT_DIR/pokemongo.apk ($(du -h "$OUT_DIR/pokemongo.apk" | cut -f1), build $STAMP)"
