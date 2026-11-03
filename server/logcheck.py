"""
logcheck.py -- one look at the last few minutes of BOTH sides, for fixing a reported
issue fast: the server's log (data/server-log.txt) and the phone's logcat (agent,
Unity errors, crashes), merged on one clock, with the problems pulled out on top.

Usage: python3 logcheck.py [minutes=5] [--all]     (--all keeps the [map] / tap noise)
Writes the same report to data/logcheck.txt.
"""
import datetime
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_LOG = os.path.join(HERE, "data", "server-log.txt")
OUT = os.path.join(HERE, "data", "logcheck.txt")
ADB_PATHS = ("/Users/mobra/platform-tools/adb",
             "/Users/mobra/android-toolchain/sdk/platform-tools/adb",
             "/Users/mobra/pgo-tools/android-sdk/platform-tools/adb", "adb")

# What counts as a problem worth reading first.
SERVER_BAD = re.compile(r"Traceback|Error(?!%)|Exception|empty response|refused|couldn't|failed"
                        r"|not handled|unknown request|code \d+\)|mismatch", re.I)
PHONE_BAD = re.compile(r"Exception|NullReference|FATAL|failed|threw|swallowed|abort"
                       r"|could not be found|Invalid|status=(?!2\b)\d+", re.I)
SERVER_NOISE = re.compile(r"redirect_uri|^\s*\[map\]|^\[bridge\]|^\s*$|\[rpc\] dump|answered \(no captcha\)"
                          r"|GET_INVENTORY answered as a delta|^\s*\(\d+ answered in")
PHONE_KEEP = re.compile(r"WindstockAgent|AndroidRuntime|DEBUG\s*:|libc\s*:|"
                        r"(?:^|\s)[EW]/Unity|Unity\s*:.*(?:Exception|Error)")
PHONE_NOISE = re.compile(r"ViewPostIme|GL_EXT|\(Filename:|sched_setscheduler|:\s*$")
STACK = re.compile(r"Unity\s*:\s+at |Unity\s*:\s+\S+[.:]\S+\(")   # a Unity stack frame


def _adb():
    for p in ADB_PATHS:
        if p == "adb" or os.path.exists(p):
            return p
    return None


def server_lines(since):
    """(datetime, text) for server log lines at/after `since`; untimed lines take the
    time of the line before them."""
    out = []
    if not os.path.exists(SERVER_LOG):
        return out
    with open(SERVER_LOG, "rb") as f:
        f.seek(0, 2)
        f.seek(max(0, f.tell() - 3_000_000))
        lines = f.read().decode("utf-8", "replace").splitlines()
    # Lines only carry a time of day: walk back from the newest, stepping a day back
    # each time the clock runs forward (an older day's lines in the same file).
    day = datetime.date.today()
    cur, prev, rev = None, None, []
    for ln in reversed(lines):
        m = re.match(r"(\d\d):(\d\d):(\d\d)\s", ln)
        if m:
            tod = datetime.time(*map(int, m.groups()))
            if prev is not None and tod > prev and \
                    (datetime.datetime.combine(day, tod) - datetime.datetime.combine(day, prev)) \
                    > datetime.timedelta(minutes=30):
                day -= datetime.timedelta(days=1)
            prev = tod
            cur = datetime.datetime.combine(day, tod)
            if cur < since:
                break
        rev.append((cur, ln.rstrip()))
    out = []
    last = None
    for t, ln in reversed(rev):          # untimed lines take the time before them
        last = t or last
        if last and last >= since:
            out.append((last, ln))
    return out


def phone_lines(since):
    adb = _adb()
    if not adb:
        return [], "adb not found"
    try:
        dev = subprocess.run([adb, "devices"], capture_output=True, text=True, timeout=10).stdout
        if not re.search(r"\tdevice$", dev, re.M):
            return [], "phone not connected (adb devices is empty)"
        # phone clock vs this Mac's, so both logs line up
        ph = subprocess.run([adb, "shell", "date +%s"], capture_output=True, text=True,
                            timeout=10).stdout.strip()
        skew = int(time.time()) - int(ph) if ph.isdigit() else 0
        raw = subprocess.run([adb, "logcat", "-d", "-v", "year"], capture_output=True,
                             text=True, timeout=60, errors="replace").stdout
    except Exception as e:
        return [], f"adb failed: {e}"
    out = []
    for ln in raw.splitlines():
        m = re.match(r"(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d+)", ln)
        if not m:
            continue
        t = datetime.datetime(*map(int, m.groups()[:6])) + datetime.timedelta(seconds=skew)
        if t < since:
            continue
        out.append((t, ln.rstrip()))
    return out, (f"clock skew {skew:+d}s" if skew else "")


def _bare(side, l):
    """The line without its own timestamp (the report prints one clock for both)."""
    if side == "PHN":
        l = re.sub(r"^\S+ \S+\s+\d+\s+\d+\s+", "", l)
    else:
        l = re.sub(r"^\d\d:\d\d:\d\d\s+", "", l)
    return l.strip()[:300]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    keep_all = "--all" in sys.argv
    minutes = float(args[0]) if args else 5
    since = datetime.datetime.now() - datetime.timedelta(minutes=minutes)

    srv = server_lines(since)
    ph, note = phone_lines(since)
    # keep agent lines, crashes and Unity errors -- and the stack frames under an error
    ph_kept, frames = [], 0
    for t, l in ph:
        if PHONE_KEEP.search(l) and (keep_all or not PHONE_NOISE.search(l)):
            ph_kept.append((t, l))
            frames = 8 if re.search(r"Exception|Error", l) else 0
        elif frames and STACK.search(l):
            ph_kept.append((t, l))
            frames -= 1

    rep = [f"=== logcheck: last {minutes:g} min (since {since:%H:%M:%S})  "
           f"server {len(srv)} lines, phone {len(ph)} lines {note}".rstrip()]

    # --- problems first
    # #5003 arrives with an empty body once per login; the empty reply is expected.
    probs = [(t, "SRV", l) for t, l in srv if SERVER_BAD.search(l) and "redirect_uri" not in l
             and "(#5003) empty response" not in l]
    probs += [(t, "PHN", l) for t, l in ph_kept if PHONE_BAD.search(l)]
    probs.sort(key=lambda x: x[0])
    rep.append(f"\n--- problems ({len(probs)})")
    seen = {}
    for t, side, l in probs:
        key = re.sub(r"\d+", "#", l[-120:])
        seen[key] = seen.get(key, 0) + 1
        if seen[key] <= 3:                    # the same error every frame: show 3
            rep.append(f"{t:%H:%M:%S} {side} {_bare(side, l)}")
    dup = sum(n - 3 for n in seen.values() if n > 3)
    if dup:
        rep.append(f"   (+{dup} repeats hidden)")

    # --- what the game asked for, last to first screen
    reqs = [l for _, l in srv if re.search(r"\[\w+\]\s+[A-Z_0-9]+,", l)]
    if reqs:
        rep.append("\n--- last requests")
        for l in reqs[-12:]:
            rep.append("  " + l.strip()[:200])

    # --- merged timeline
    rep.append("\n--- timeline (SRV = server, PHN = phone)")
    tl = [(t, "SRV", l) for t, l in srv if keep_all or not SERVER_NOISE.search(l)]
    tl += [(t, "PHN", l) for t, l in ph_kept]
    tl.sort(key=lambda x: x[0])
    for t, side, l in tl[-400:]:
        rep.append(f"{t:%H:%M:%S} {side} {_bare(side, l)}")

    text = "\n".join(rep) + "\n"
    try:
        with open(OUT, "w") as f:
            f.write(text)
    except OSError:
        pass
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
