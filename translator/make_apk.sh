#!/bin/bash
# Build the PoGO 0.71 translator app (com.windstock.translator071): the Windstock
# translator64 host (shared libwst64.so) running the stock 0.71 armeabi-v7a libs on
# 64-bit-only Android. Login URLs are the http-patched metadata (2017/build_071_http.sh).
# Needs: source ~/android-toolchain/env.sh
set -euo pipefail
cd "$(dirname "$0")"; HERE=$PWD
REPO="$HOME/Desktop/Pokemon go private server"
T64="$REPO/work/translator64"
APK071="$REPO/2017/pogo-0.71-http.signed.apk"
BT=$ANDROID_HOME/build-tools/35.0.0
PLATFORM=$ANDROID_HOME/platforms/android-35/android.jar
JKS="$REPO/android-launcher/tools/windstock-launcher.jks"
OUT=build
rm -rf "$OUT"; mkdir -p "$OUT/lib/arm64-v8a" "$OUT/dex" "$OUT/obj"

# guest libs + matching metadata (assets/guest is staged from $APK071)
want=$(shasum < assets/guest/Data/Managed/Metadata/global-metadata.dat | cut -c1-40)
got=$(unzip -p "$APK071" assets/bin/Data/Managed/Metadata/global-metadata.dat | shasum | cut -c1-40)
[ "$want" = "$got" ] || { echo "assets/guest metadata != $APK071 -- restage" >&2; exit 1; }

cp "$T64/build/app/libwst64.so" "$OUT/lib/arm64-v8a/libwst64.so"
CLANG=$(ls $ANDROID_HOME/ndk/27.2.12479018/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android26-clang | head -1)
"$CLANG" -shared -o "$OUT/lib/arm64-v8a/libmain.so" libmain_shim.c

find java -name '*.java' > "$OUT/sources.txt"
"$JAVA_HOME/bin/javac" -d "$OUT/obj" -classpath "$PLATFORM" -source 11 -target 11 @"$OUT/sources.txt" 2>&1 | grep -v "^warning\|^1 warning" || true
"$BT/d8" --release --lib "$PLATFORM" --output "$OUT/dex" $(find "$OUT/obj" -name '*.class')

"$BT/aapt2" link -o "$OUT/base.apk" -I "$PLATFORM" \
  --manifest AndroidManifest.xml -A assets --min-sdk-version 26 --target-sdk-version 30

unzip -o -q "$APK071" classes.dex -d "$OUT/gamedex"
cp "$OUT/gamedex/classes.dex" "$OUT/classes2.dex"
( cd "$OUT" && cp base.apk app.apk && cp dex/classes.dex classes.dex \
  && zip -q -X app.apk classes.dex classes2.dex \
  && zip -q -X app.apk lib/arm64-v8a/libwst64.so lib/arm64-v8a/libmain.so )

# Unity data, stored (Unity mmaps it), straight from the 0.71 APK
DATA_CACHE=cache/unity-data
if [ ! -f "$DATA_CACHE/.stamp" ] || [ "$APK071" -nt "$DATA_CACHE/.stamp" ]; then
  rm -rf "$DATA_CACHE"; mkdir -p "$DATA_CACHE"
  ( cd "$DATA_CACHE" && unzip -q "$APK071" "assets/bin/*" ); touch "$DATA_CACHE/.stamp"
fi
( cd "$DATA_CACHE" && zip -0 -q -X -r "$HERE/$OUT/app.apk" assets )

# the game's resources (its Java uses them by id)
rm -rf "$OUT/gameres"; mkdir -p "$OUT/gameres"
( cd "$OUT/gameres" && unzip -q "$APK071" resources.arsc "res/*" )
zip -q -d "$OUT/app.apk" resources.arsc || true
( cd "$OUT/gameres" && zip -0 -q -X "$HERE/$OUT/app.apk" resources.arsc && zip -q -X -r "$HERE/$OUT/app.apk" res )
"$BT/zipalign" -f -p 4 "$OUT/app.apk" "$OUT/app-aligned.apk" && mv "$OUT/app-aligned.apk" "$OUT/app.apk"

"$BT/apksigner" sign --ks "$JKS" --ks-pass pass:windstock --key-pass pass:windstock \
  --ks-key-alias windstock --min-sdk-version 26 --out "$OUT/pogo071-t64.apk" "$OUT/app.apk"
"$BT/apksigner" verify "$OUT/pogo071-t64.apk" && ls -la "$OUT/pogo071-t64.apk"
