#!/bin/bash
# errwatch.sh -- live error catcher: prints server and phone errors the moment they
# happen (logcheck.py is the after-the-fact look). Ctrl+C to stop.
HERE="$(cd "$(dirname "$0")" && pwd)"
ADB=/Users/mobra/platform-tools/adb

tail -n 0 -F "$HERE/data/server-log.txt" 2>/dev/null |
  grep --line-buffered -E 'Traceback|Error|Exception|empty response|refused|couldn.t|failed|REFUSED|mismatch' |
  grep --line-buffered -vE 'redirect_uri|#5003' |
  sed -u 's/^/SRV /' &

# Only the game's own lines: Unity, the agent, and a crash of the game process (other
# apps on the phone log plenty of harmless exceptions of their own).
"$ADB" logcat -T 1 -v time 2>/dev/null |
  grep --line-buffered -E '(Unity|WindstockAgent).*(Exception|fail|threw|swallowed|error)|F/libc.*pokemongo071|F/DEBUG.*(pokemongo071|#0[0-3] )|AndroidRuntime.*pokemongo071' |
  sed -u 's/^/PHN /' &

wait
