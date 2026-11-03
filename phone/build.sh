#!/bin/bash
# The 0.71 client for a real Android phone (32-bit capable), talking to this project's server
# on the Mac over Wi-Fi -- no translator.
#
#   phone071/build.sh [server-ip]        (default: the Mac's en0 address)
#   adb install -r phone071/build/windstock071.apk
#
# Base: the http-SSO 0.71 APK ("Pokemon go private server"/2017/pogo-0.71-http.signed.apk: PTC
# login on http://pgorelease.nianticlabs.com/sso, which the agent points at the Mac's :80).
# Adds frida-gadget 16.7.19 (17.x dies at start-up on a Galaxy S9 / Android 10) in script
# mode with agent/ (see agent/index.js), loaded from UnityMainActivity's static
# initializer; renames the app to com.windstock.pokemongo071 ("Windstock 0.71") so it sits
# next to the Play Store game and Windstock 0.35.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HOME/Desktop/Pokemon go private server"
SERVER="${1:-$(ipconfig getifaddr en0)}"
BASE="${BASE:-$REPO/2017/pogo-0.71-http.signed.apk}"
APKTOOL="$REPO/work/tools/apktool.jar"
JKS="$REPO/android-launcher/tools/windstock-launcher.jks"
GADGET="$REPO/android-launcher/tools/cache/frida-gadget-16.7.19-android-arm.so"
CA="$HERE/../server/certs/ca.crt"
ORIG_PACKAGE=com.nianticlabs.pokemongo
GAME_PACKAGE="${GAME_PACKAGE:-com.windstock.pokemongo071}"
GAME_LABEL="${GAME_LABEL:-Windstock 0.71}"
OUT="$HERE/build/windstock071.apk"
WORK="$HERE/build/work"

source "$HOME/android-toolchain/env.sh"
BT="$ANDROID_HOME/build-tools/35.0.0"
[ -n "$SERVER" ] || { echo "no server IP (pass one)" >&2; exit 1; }

echo "==> agent (server $SERVER)"
rm -rf "$WORK"; mkdir -p "$WORK"
python3 - "$HERE/agent/index.js" "$HERE/agent/.index.built.js" "$SERVER" "$CA" <<'PY2'
import json, sys
src, dst, server, ca = sys.argv[1:]
s = open(src).read()
s = s.replace('"@SERVER@"', json.dumps(server)).replace('"@CA_PEM@"', json.dumps(open(ca).read()))
open(dst, "w").write(s)
PY2
(cd "$HERE/agent" && node_modules/.bin/frida-compile .index.built.js -o "$WORK/agent.js" -c)
rm -f "$HERE/agent/.index.built.js"

echo "==> decode $(basename "$BASE")"
java -jar "$APKTOOL" d -f -o "$WORK/src" "$BASE" >/dev/null

echo "==> app id $ORIG_PACKAGE -> $GAME_PACKAGE (\"$GAME_LABEL\")"
python3 - "$WORK/src" "$ORIG_PACKAGE" "$GAME_PACKAGE" "$GAME_LABEL" <<'PY'
import glob, os, re, sys
root, old, new, label = sys.argv[1:]
m = os.path.join(root, "AndroidManifest.xml")
s = open(m, encoding="utf-8").read()
# Identifiers that must be unique per app; class names (com.nianticlabs.nia.*) stay.
s = s.replace(f'package="{old}"', f'package="{new}"')
s = re.sub(rf'"{re.escape(old)}(\.[A-Za-z0-9_.]+)?"',
           lambda mm: f'"{new}{mm.group(1) or ""}"', s)
open(m, "w", encoding="utf-8").write(s)
for f in glob.glob(os.path.join(root, "smali*", "**", "Manifest$permission.smali"), recursive=True):
    t = open(f, encoding="utf-8").read()
    open(f, "w", encoding="utf-8").write(t.replace(f"{old}.permission", f"{new}.permission"))
n = 0
for f in glob.glob(os.path.join(root, "res", "values*", "strings.xml")):
    t = open(f, encoding="utf-8").read()
    t2 = re.sub(r'(<string name="app_name">)[^<]*(</string>)', lambda mm: mm.group(1) + label + mm.group(2), t)
    if t2 != t:
        open(f, "w", encoding="utf-8").write(t2); n += 1
left = [l.strip() for l in s.splitlines() if f'"{old}' in l]
print(f"    {n} label(s); manifest refs left: {left or 'none'}")
PY

echo "==> gadget loader"
SMALI="$(grep -rl '^\.class public Lcom/nianticproject/holoholo/libholoholo/unity/UnityMainActivity;' "$WORK/src"/smali* | head -1)"
[ -n "$SMALI" ] || { echo "UnityMainActivity not found" >&2; exit 1; }
python3 - "$SMALI" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
load = ('    const-string v0, "frida-gadget"\n\n'
        '    invoke-static {v0}, Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V\n\n')
m = re.search(r'\.method static constructor <clinit>\(\)V\n(\s*\.(?:locals|registers) (\d+)\n)', s)
if m:
    head = m.group(1) if int(m.group(2)) >= 1 else m.group(1).replace(m.group(2), "1")
    s = s[:m.start(1)] + head + "\n" + load + s[m.end(1):]
else:
    clinit = '.method static constructor <clinit>()V\n    .locals 1\n\n' + load + '    return-void\n.end method\n\n'
    i = s.index("# direct methods\n") + len("# direct methods\n") if "# direct methods\n" in s else s.index(".method")
    s = s[:i] + clinit + s[i:]
open(p, "w", encoding="utf-8").write(s)
print("    loadLibrary(frida-gadget) in <clinit>")
PY

LIB="$WORK/src/lib/armeabi-v7a"
cp "$GADGET" "$LIB/libfrida-gadget.so"
cp "$WORK/agent.js" "$LIB/libfrida-gadget.script.so"
printf '{\n  "interaction": {\n    "type": "script",\n    "path": "libfrida-gadget.script.so",\n    "on_change": "ignore"\n  }\n}\n' \
    > "$LIB/libfrida-gadget.config.so"

echo "==> build + sign"
java -jar "$APKTOOL" b -o "$WORK/unsigned.apk" "$WORK/src" >/dev/null
"$BT/zipalign" -f -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
mkdir -p "$(dirname "$OUT")"
"$BT/apksigner" sign --ks "$JKS" --ks-pass pass:windstock --key-pass pass:windstock \
    --ks-key-alias windstock --out "$OUT" "$WORK/aligned.apk"
rm -rf "$WORK" "$OUT.idsig"
echo "done: $OUT ($(du -h "$OUT" | cut -f1)) -> server $SERVER"
