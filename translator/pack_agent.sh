#!/bin/bash
# Repack the already-built 0.63 translator APK with the Frida gadget + agent.js (script mode),
# sign it with the launcher keystore make_apk.sh already uses, and install it on the emulator.
# Needs: build/pogo071-t64.apk (from make_apk.sh) and agent.js (agent/ -> frida-compile).
set -euo pipefail
source ~/android-toolchain/env.sh
cd "$(dirname "$0")"
REPO="$HOME/Desktop/Pokemon go private server"
BT=$ANDROID_HOME/build-tools/35.0.0
JKS="$REPO/android-launcher/tools/windstock-launcher.jks"
GADGET="$REPO/android-launcher/tools/cache/frida-gadget-16.7.19-android-arm64.so"
W=build/agent-pack
rm -rf "$W"; mkdir -p "$W/lib/arm64-v8a"
cp build/pogo071-t64.apk "$W/in.apk"
# the translator: rebuilt (default) or the one already in the APK (KEEP_LIB=1)
if [ "${KEEP_LIB:-0}" != 1 ]; then cp "$REPO/work/translator64/build/app/libwst64.so" "$W/lib/arm64-v8a/libwst64.so"; fi
cp "$GADGET" "$W/lib/arm64-v8a/libfrida-gadget.so"
cp agent.js "$W/lib/arm64-v8a/libfrida-gadget.script.so"
printf '{\n  "interaction": {\n    "type": "script",\n    "path": "libfrida-gadget.script.so"\n  }\n}\n' \
  > "$W/lib/arm64-v8a/libfrida-gadget.config.so"
( cd "$W"
  zip -q -d in.apk 'META-INF/*' || true
  [ -f lib/arm64-v8a/libwst64.so ] && zip -q -X in.apk lib/arm64-v8a/libwst64.so
  zip -q -X in.apk lib/arm64-v8a/libfrida-gadget.so lib/arm64-v8a/libfrida-gadget.script.so lib/arm64-v8a/libfrida-gadget.config.so
  "$BT/zipalign" -f -p 4 in.apk aligned.apk
  "$BT/apksigner" sign --ks "$JKS" --ks-pass pass:windstock --key-pass pass:windstock \
    --ks-key-alias windstock --min-sdk-version 26 --out out.apk aligned.apk )
adb install -r -g "$W/out.apk" | tail -2
echo "installed. Run: adb logcat -s WindstockAgent wst64 | grep rpc063"
