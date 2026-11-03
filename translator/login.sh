#!/bin/bash
# drive a fresh 0.71 install through the age gate + PTC login (test trainer; the fork server
# creates the account on first login). Coordinates: 1080x2340 emulator (windstock30).
source ~/android-toolchain/env.sh
t() { adb shell input tap "$@"; }
t 790 1370; sleep 2.5                                       # year field -> list
for i in 1 2; do adb shell input swipe 785 1850 785 800 600; sleep 1.5; done
t 776 770; sleep 1.5                                        # ~1985
t 454 1592; sleep 4                                         # SUBMIT
t 540 1500; sleep 4                                         # POKEMON TRAINER CLUB
t 540 850; sleep 2; adb shell input text "${1:-testtrainer}"; sleep 1; t 1005 2117; sleep 2
t 540 1048; sleep 2; adb shell input text "${2:-test1234}"; sleep 1; t 1005 2117; sleep 2
t 746 1268                                                  # Sign in
