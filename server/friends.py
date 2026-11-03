"""
Friends -- the modern game's friend list, for the 0.35 client.

0.35 has no friends at all, so the windstock tweak draws the screens: a FRIENDS
tab on the trainer profile (ME | FRIENDS, like the newer game), the Add Friend
page with your Trainer Code and its QR code, friend requests and a friend's page.
This module is their backend.

Everyone gets a random 12-digit Trainer Code. Entering someone's code sends them a
request; when they accept, you are friends. If they had already asked you, entering
their code makes you friends straight away.

Friendship grows like the real game's, Good -> Great -> Ultra -> Best Friend, by
days you both played: each UTC day on which both of you were in the game counts
once (1, 7, 30 and 90 days, the real thresholds). rpc.py calls seen() on every
verified request; it only does work the first time each trainer is seen in a day.

Tweak API (game host, trainer recognised like the Research screens, rpc.user_for_ip):
  GET  /friends/state                  -> me, friends, incoming and outgoing requests
  POST /friends/add      {code}        -> send a request (or accept theirs)
  POST /friends/accept   {id}          -> id = the other trainer's login
  POST /friends/decline  {id}
  POST /friends/cancel   {id}          -> take back a request you sent
  POST /friends/remove   {id}
  GET  /friends/art/<file>.png         -> the game's friend icons (friends_art/)
Every POST answers with the new state, plus "message" or "error" for the screen.

Kept in data/friends.json:
  {"codes": {login: code}, "requests": {to: {from: ms}},
   "links": {"a|b": {"since": ms, "days": n, "last": "YYYY-MM-DD"}}, "played": {login: day}}
"""
import json
import os
import secrets
import threading
import time

import datadir

HERE = os.path.dirname(os.path.abspath(__file__))
ART_DIR = os.path.join(HERE, "friends_art")
FILE = os.path.join(datadir.ensure(), "friends.json")
MAX_FRIENDS = 200
MAX_PENDING = 50                    # requests waiting on one trainer
ADD_LIMIT = 30                      # codes tried per trainer per hour (codes can't be guessed)
LEVELS = [(0, "Friend"), (1, "Good Friend"), (7, "Great Friend"),
          (30, "Ultra Friend"), (90, "Best Friend")]

_lock = threading.RLock()
_state = None
_dirty = False
_last_write = 0.0
_tries = {}                         # login -> [times of recent add attempts]


# ------------------------------------------------------------------ storage
def _load():
    global _state
    if _state is None:
        try:
            with open(FILE, encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            d = {}
        d = d if isinstance(d, dict) else {}
        _state = {k: dict(d.get(k) or {}) for k in ("codes", "requests", "links", "played")}
    return _state


def _write(force=True):
    """Save now (force) or at most every 30 s (the daily played marks)."""
    global _dirty, _last_write
    _dirty = True
    now = time.time()
    if not force and now - _last_write < 30:
        return
    tmp = FILE + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(_state, fh, indent=1)
        os.replace(tmp, FILE)
        _dirty, _last_write = False, now
    except OSError:
        pass


def _today():
    return time.strftime("%Y-%m-%d", time.gmtime())


def _key(a, b):
    return "|".join(sorted((a, b)))


def _other(key, me):
    a, _, b = key.partition("|")
    return b if a == me else a


def code_for(login):
    """This trainer's Trainer Code, made the first time it is asked for."""
    with _lock:
        st = _load()
        c = st["codes"].get(login)
        if not c:
            taken = set(st["codes"].values())
            while True:
                c = "".join(secrets.choice("0123456789") for _ in range(12))
                if c[0] != "0" and c not in taken:
                    break
            st["codes"][login] = c
            _write()
        return c


def _login_for_code(code):
    for login, c in _load()["codes"].items():
        if c == code:
            return login
    return None


def friends_of(login):
    with _lock:
        return [_other(k, login) for k in _load()["links"] if login in k.split("|")]


# ------------------------------------------------------------- friendship
def friendship(days):
    """(level 0-4, its name, days needed for the next level or None)."""
    lvl = 0
    for i, (need, _) in enumerate(LEVELS):
        if days >= need:
            lvl = i
    nxt = LEVELS[lvl + 1][0] if lvl + 1 < len(LEVELS) else None
    return lvl, LEVELS[lvl][1], nxt


def seen(login):
    """The trainer is playing. The first time today, every friend who also
    played today gets a friendship day with them."""
    if not login:
        return
    day = _today()
    with _lock:
        st = _load()
        if st["played"].get(login) == day:
            return
        st["played"][login] = day
        for k, link in st["links"].items():
            if login in k.split("|") and link.get("last") != day \
                    and st["played"].get(_other(k, login)) == day:
                link["days"] = int(link.get("days") or 0) + 1
                link["last"] = day
        _write(force=False)


# ------------------------------------------------------------ who they are
def _info(login):
    """Name, level and team of a trainer, from memory or their save."""
    import world
    d = None
    p = getattr(world, "_players", {}).get(login)
    if p is not None:
        d = {"codename": p.CODENAME, "xp": p.XP, "team": p.TEAM}
    else:
        try:
            with open(os.path.join(world.SAVES_DIR, world._safe_name(login) + ".json"),
                      encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            d = None
    if not isinstance(d, dict):
        return None
    name = str(d.get("codename") or "") or login
    try:
        import colortags
        name = colortags.visible(name) or login
    except Exception:
        pass
    return {"name": name[:30], "level": world.level_for_xp(int(d.get("xp") or 0)),
            "team": int(d.get("team") or 0)}


def _seen_ms(login):
    try:
        import rpc
        t = rpc._user_seen.get(login)
        return int(t * 1000) if t else 0
    except Exception:
        return 0


def _row(login, now_ms):
    info = _info(login) or {"name": login, "level": 1, "team": 0}
    seen_ms = _seen_ms(login)
    return dict(info, id=login, seen_ms=seen_ms,
                online=bool(seen_ms) and now_ms - seen_ms <= 5 * 60 * 1000)


def state(login):
    now = int(time.time() * 1000)
    with _lock:
        st = _load()
        me = _info(login) or {"name": login, "level": 1, "team": 0}
        me["code"] = code_for(login)
        friends = []
        for k, link in st["links"].items():
            if login not in k.split("|"):
                continue
            days = int(link.get("days") or 0)
            lvl, name, nxt = friendship(days)
            friends.append(dict(_row(_other(k, login), now), since=int(link.get("since") or 0),
                                days=days, friendship=lvl, friendship_name=name,
                                next_days=nxt, today=link.get("last") == _today()))
        incoming = [dict(_row(f, now), sent=ms)
                    for f, ms in sorted((st["requests"].get(login) or {}).items(),
                                        key=lambda kv: -kv[1])]
        outgoing = [dict(_row(to, now), sent=reqs[login])
                    for to, reqs in st["requests"].items() if login in reqs]
    # best friends first, then who played most recently -- the game's default sort
    friends.sort(key=lambda f: (-f["friendship"], -f["days"], -f["seen_ms"], f["name"].lower()))
    return {"me": me, "friends": friends, "incoming": incoming, "outgoing": outgoing,
            "max": MAX_FRIENDS, "levels": [n for _, n in LEVELS]}


def pending_count(login):
    with _lock:
        return len(_load()["requests"].get(login) or {})


# ----------------------------------------------------------------- actions
def _befriend(a, b):
    st = _load()
    st["links"][_key(a, b)] = {"since": int(time.time() * 1000), "days": 0, "last": ""}
    for x, y in ((a, b), (b, a)):
        reqs = st["requests"].get(x)
        if reqs:
            reqs.pop(y, None)
            if not reqs:
                st["requests"].pop(x, None)


def add(login, code):
    code = "".join(ch for ch in str(code or "") if ch.isdigit())
    if len(code) != 12:
        return {"error": "A Trainer Code has 12 digits."}
    now = time.time()
    recent = [t for t in _tries.get(login, []) if now - t < 3600]
    if len(recent) >= ADD_LIMIT:
        return {"error": "Too many tries. Try again in a while."}
    recent.append(now)
    _tries[login] = recent
    with _lock:
        st = _load()
        other = _login_for_code(code)
        if not other:
            return {"error": "No trainer has that code."}
        if other == login:
            return {"error": "That's your own Trainer Code."}
        if _key(login, other) in st["links"]:
            return {"error": "You're already friends."}
        name = (_info(other) or {}).get("name", "that trainer")
        if len(friends_of(login)) >= MAX_FRIENDS:
            return {"error": f"Your friend list is full ({MAX_FRIENDS})."}
        if login in (st["requests"].get(other) or {}):
            return {"error": f"You already sent {name} a request."}
        if other in (st["requests"].get(login) or {}):       # they asked first: done
            if len(friends_of(other)) >= MAX_FRIENDS:
                return {"error": f"{name}'s friend list is full."}
            _befriend(login, other)
            _write()
            return {"message": f"You and {name} are now friends!", "friend": other}
        reqs = st["requests"].setdefault(other, {})
        if len(reqs) >= MAX_PENDING:
            return {"error": f"{name} has too many requests waiting."}
        reqs[login] = int(now * 1000)
        _write()
        return {"message": f"Friend request sent to {name}."}


def accept(login, other):
    with _lock:
        st = _load()
        if other not in (st["requests"].get(login) or {}):
            return {"error": "That request is gone."}
        name = (_info(other) or {}).get("name", "that trainer")
        if len(friends_of(login)) >= MAX_FRIENDS:
            return {"error": f"Your friend list is full ({MAX_FRIENDS})."}
        if len(friends_of(other)) >= MAX_FRIENDS:
            return {"error": f"{name}'s friend list is full."}
        _befriend(login, other)
        _write()
        return {"message": f"You and {name} are now friends!", "friend": other}


def _drop_request(to, frm):
    st = _load()
    reqs = st["requests"].get(to) or {}
    if frm not in reqs:
        return False
    reqs.pop(frm)
    if not reqs:
        st["requests"].pop(to, None)
    _write()
    return True


def decline(login, other):
    with _lock:
        _drop_request(login, other)
    return {}


def cancel(login, other):
    with _lock:
        _drop_request(other, login)
    return {}


def remove(login, other):
    with _lock:
        st = _load()
        if st["links"].pop(_key(login, other), None) is None:
            return {"error": "You're not friends."}
        _write()
    return {"message": "Friend removed."}


def forget(login):
    """A trainer's account is gone: drop their code, friends and requests."""
    with _lock:
        st = _load()
        st["codes"].pop(login, None)
        st["played"].pop(login, None)
        st["requests"].pop(login, None)
        for reqs in st["requests"].values():
            reqs.pop(login, None)
        for k in [k for k in st["links"] if login in k.split("|")]:
            st["links"].pop(k)
        _write()


# --------------------------------------------------------------------- HTTP
def _json(obj, status=200):
    return status, {"Content-Type": "application/json", "Cache-Control": "no-store"}, \
        json.dumps(obj).encode("utf-8")


ACTIONS = {"add": lambda u, d: add(u, d.get("code")),
           "accept": lambda u, d: accept(u, str(d.get("id") or "")),
           "decline": lambda u, d: decline(u, str(d.get("id") or "")),
           "cancel": lambda u, d: cancel(u, str(d.get("id") or "")),
           "remove": lambda u, d: remove(u, str(d.get("id") or ""))}


def handle(method, path, query, headers, body, log, ip=None):
    rest = path[len("/friends"):].strip("/")
    if rest.startswith("art/"):
        f = os.path.join(ART_DIR, os.path.basename(rest[4:]))
        if not f.endswith(".png") or not os.path.exists(f):
            return 404, {"Content-Type": "text/plain"}, b"?"
        with open(f, "rb") as fh:
            return 200, {"Content-Type": "image/png", "Cache-Control": "max-age=86400"}, fh.read()
    import rpc
    user = rpc.user_for_ip(ip)
    if not user:
        return _json({"error": "unknown trainer -- open the game first"}, 403)
    if rest in ("", "state"):
        return _json(state(user))
    if method == "POST" and rest in ACTIONS:
        try:
            data = json.loads((body or b"{}").decode("utf-8")) or {}
        except (ValueError, UnicodeDecodeError):
            data = {}
        out = ACTIONS[rest](user, data if isinstance(data, dict) else {})
        if log and (out.get("message") or out.get("error")):
            log(f"[friends] {user} {rest}: {out.get('message') or out.get('error')}")
        return _json(dict(state(user), **out))
    return _json({"error": "not found"}, 404)
