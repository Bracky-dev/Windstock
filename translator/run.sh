#!/bin/bash
# rebuild translator (if src changed) + APK, install on the emulator, launch, collect logcat
# usage: ./run.sh [seconds]   -> log in ./last-run.txt
source ~/android-toolchain/env.sh
set -e; cd "$(dirname "$0")"
( cd "$HOME/Desktop/Pokemon go private server/work/translator64/build/app" && cmake --build . -j8 | tail -1 )
./make_apk.sh | tail -1
adb install -r -g build/pogo071-t64.apk | tail -1
adb shell am force-stop com.windstock.translator063; adb logcat -c
adb logcat -v time > last-run.txt 2>&1 & LP=$!
adb shell am start -n com.windstock.translator063/com.windstock.translator64.MainActivity >/dev/null
sleep "${1:-60}"; kill $LP
grep -E "wst64|FATAL|F/DEBUG" last-run.txt | grep -v "\[sig\]\|\[samp\]" | grep -E "FATAL|unimplemented|SIGSEGV|fault|\[net\]|\[dl\]|\[app\]|backtrace|#0[0-5]|login|rpc" | tail -40
