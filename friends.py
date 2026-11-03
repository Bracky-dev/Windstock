"""
Friends -- the modern game's friend list, for the 0.35 client.

0.35 has no friends at all, so the windstock tweak draws the screens: a FRIENDS
tab on the trainer profile (ME | FRIENDS, like the newer game), the Add Friend
page with your Trainer Code and its QR code, friend requests and a friend's page.
This module is their backend.

Everyone gets a random 12-digit Trainer Code. Entering someone's code sends them a
request; when they accept, you are friends. If they had already asked you, entering
their code makes you friends straight away.

Friendship grows like the real game's, Good -> Great -> Ultra -> Best Friend (1, 7, 30
and 90 days, the real thresholds), by INTERACTING: opening a friend's gift or trading
with them counts, at most once per friend per UTC day.

Gifts: one gift to each friend a day (GIFT_SEND_LIMIT a day in all); it waits on their
friend list until they open it (one waiting from each friend at a time), and opening one
puts a few items in their bag (GIFT_OPEN_LIMIT opened a day).
Trades happen in a TRADE ROOM, like the newer game: one friend opens it, both see it,
each picks ONLY their own Pokemon (the other side shows what the friend picked), a chat box
lets them agree on it, and when both have confirmed the same two Pokemon trading.py makes
the swap with its usual rules (stardust cost, daily limit, level 5, favourites/defenders).
Changing a pick takes back both confirmations. A room nobody touches closes after ROOM_IDLE_MS.

Tweak API (game host, trainer recognised like the Research screens, rpc.user_for_ip):
  GET  /friends/state                  -> me, friends, incoming and outgoing requests
  POST /friends/add      {code}        -> send a request (or accept theirs)
  POST /friends/accept   {id}          -> id = the other trainer's login
  POST /friends/decline  {id}
  POST /friends/cancel   {id}          -> take back a request you sent
  POST /friends/remove   {id}
  POST /friends/gift     {id}          -> send today's gift
  POST /friends/open     {id}          -> open their gift: "items" = what you got
  GET  /friends/box                    -> my tradeable Pokemon (trading.box)
  POST /friends/trade_start {id}       -> open (or rejoin) the trade room with a friend
  GET  /friends/trade?t=<room>         -> the room: both picks, confirmations, chat, cost
  POST /friends/trade_pick  {trade, uid} / trade_ok {trade} / trade_chat {trade, text}
  POST /friends/trade_cancel {trade}
  POST /friends/trade_report {trade, reason, note?} -> report the other trainer (trade_chats.py)
  GET  /friends/art/<file>.png         -> the game's friend icons (friends_art/)
  GET  /friends/trainer/<size>/<look>.png -> a trainer's real look, head and shoulders
                                          (friends_portrait.py; "avatar" in every row)
Every POST answers with the new state, plus "message" or "error" for the screen.

Kept in data/friends.json:
  {"codes": {login: code}, "requests": {to: {from: ms}},
   "links": {"a|b": {"since": ms, "days": n, "last": "YYYY-MM-DD"}}, "played": {login: day},
   "gifts": {to: {from: ms}}, "sent": {"from|to": day}, "counts": {login: {day, sent, opened}},
   "rooms": {id: {a, b, pick: {login: uid}, ok: {login: bool}, chat: [{who, text, ms}], ms, touched,
                  state: open|done|cancelled, result}}, "notes": {login: [{ms, text}]}}

Notes are what the map toasts say ("X sent you a Gift!", "X accepted your trade!"): the
newest few per trainer, handed to the phone in /research/ping as friend_notes.
"""
import json
import os
import secrets
import threading
import time

import datadir
import friends_portrait            # the trainer pictures ("avatar" urls)
import trade_chats                 # every chat line + reports, for the admin page

HERE = os.path.dirname(os.path.abspath(__file__))
ART_DIR = os.path.join(HERE, "friends_art")
FILE = os.path.join(datadir.ensure(), "friends.json")
MAX_FRIENDS = 200
MAX_PENDING = 50                    # requests waiting on one trainer
ADD_LIMIT = 30                      # codes tried per trainer per hour (codes can't be guessed)
LEVELS = [(0, "Friend"), (1, "Good Friend"), (7, "Great Friend"),
          (30, "Ultra Friend"), (90, "Best Friend")]
GIFT_SEND_LIMIT = 20
GIFT_OPEN_LIMIT = 20
ROOM_IDLE_MS = 2 * 3600 * 1000      # a trade room nobody touches closes after two hours
ROOM_SHOW_MS = 10 * 60 * 1000       # a finished/cancelled room is still shown this long
CHAT_KEEP = 60
CHAT_MAX = 200                      # characters per message

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
        _state = {k: dict(d.get(k) or {}) for k in ("codes", "requests", "links", "played",
                                                        "gifts", "sent", "counts", "rooms", "notes")}
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
    """The trainer is playing (kept for rpc.py; friendship now grows by interacting)."""
    if not login:
        return
    day = _today()
    with _lock:
        st = _load()
        if st["played"].get(login) != day:
            st["played"][login] = day
            _write(force=False)


def interact(a, b):
    """A gift opened or a trade made: one friendship day, at most once a day per pair.
    True when it counted."""
    day = _today()
    with _lock:
        link = _load()["links"].get(_key(a, b))
        if link is None or link.get("last") == day:
            return False
        link["days"] = int(link.get("days") or 0) + 1
        link["last"] = day
        _write()
        return True


# ------------------------------------------------------------ who they are
def _info(login):
    """Name, level and team of a trainer, from memory or their save."""
    import world
    d = None
    p = getattr(world, "_players", {}).get(login)
    if p is not None:
        d = {"codename": p.CODENAME, "xp": p.XP, "team": p.TEAM, "avatar": dict(p.AVATAR)}
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
            "team": int(d.get("team") or 0), "avatar": friends_portrait.url_for(d.get("avatar"))}


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
            other = _other(k, login)
            friends.append(dict(_row(other, now), since=int(link.get("since") or 0),
                                days=days, friendship=lvl, friendship_name=name,
                                next_days=nxt, today=link.get("last") == _today(),
                                gift=other in (st["gifts"].get(login) or {}),           # theirs, unopened
                                gift_sent=st["sent"].get(f"{login}|{other}") == _today()))
        incoming = [dict(_row(f, now), sent=ms)
                    for f, ms in sorted((st["requests"].get(login) or {}).items(),
                                        key=lambda kv: -kv[1])]
        outgoing = [dict(_row(to, now), sent=reqs[login])
                    for to, reqs in st["requests"].items() if login in reqs]
        _expire_rooms(st, now)
        rooms = [_room_brief(rid, r, login) for rid, r in sorted(st["rooms"].items(), key=lambda kv: -kv[1]["ms"])
                 if login in (r["a"], r["b"]) and r["state"] == "open"]
        counts = _counts(st, login)
    # best friends first, then who played most recently -- the game's default sort
    friends.sort(key=lambda f: (not f["gift"], -f["friendship"], -f["days"], -f["seen_ms"], f["name"].lower()))
    return {"me": me, "friends": friends, "incoming": incoming, "outgoing": outgoing,
            "trades": rooms,
            "gifts_left": max(0, GIFT_SEND_LIMIT - counts["sent"]),
            "opens_left": max(0, GIFT_OPEN_LIMIT - counts["opened"]),
            "max": MAX_FRIENDS, "levels": [n for _, n in LEVELS]}


# ------------------------------------------------------------------- gifts
def _counts(st, login):
    c = st["counts"].get(login) or {}
    if c.get("day") != _today():
        c = {"day": _today(), "sent": 0, "opened": 0}
        st["counts"][login] = c
    return c


GIFT_ITEMS = [  # (item id, min level, max per gift, weight) -- what the newer game's gifts hold
    (1, 1, 6, 10), (2, 12, 4, 6), (3, 20, 3, 3), (101, 1, 4, 6), (102, 10, 3, 4), (103, 15, 2, 3),
    (201, 5, 3, 4), (701, 8, 3, 5)]


def _gift_contents(level):
    import random
    pool = [(i, n, w) for i, lvl, n, w in GIFT_ITEMS if level >= lvl]
    picks = {}
    for _ in range(random.randint(2, 3)):
        i, n, _w = random.choices(pool, weights=[w for *_x, w in pool])[0]
        picks[i] = picks.get(i, 0) + random.randint(1, n)
    return [{"kind": "item", "item": i, "count": c} for i, c in picks.items()]


def send_gift(login, other):
    with _lock:
        st = _load()
        if _key(login, other) not in st["links"]:
            return {"error": "You're not friends."}
        name = (_info(other) or {}).get("name", "your friend")
        if st["sent"].get(f"{login}|{other}") == _today():
            return {"error": f"You already sent {name} a gift today."}
        c = _counts(st, login)
        if c["sent"] >= GIFT_SEND_LIMIT:
            return {"error": f"You've sent {GIFT_SEND_LIMIT} gifts today. More tomorrow."}
        if login in (st["gifts"].get(other) or {}):
            return {"error": f"{name} hasn't opened your last gift yet."}
        st["gifts"].setdefault(other, {})[login] = int(time.time() * 1000)
        _note(other, f"{(_info(login) or {}).get('name', 'A friend')} sent you a Gift!")
        st["sent"][f"{login}|{other}"] = _today()
        st["sent"] = {k: v for k, v in st["sent"].items() if v == _today()}
        c["sent"] += 1
        _write()
        return {"message": f"Gift sent to {name}!"}


def open_gift(login, other, log=None):
    with _lock:
        st = _load()
        if other not in (st["gifts"].get(login) or {}):
            return {"error": "That gift is gone."}
        c = _counts(st, login)
        if c["opened"] >= GIFT_OPEN_LIMIT:
            return {"error": f"You've opened {GIFT_OPEN_LIMIT} gifts today. More tomorrow."}
        name = (_info(other) or {}).get("name", "your friend")
        level = (_info(login) or {}).get("level", 1)
        st["gifts"][login].pop(other)
        if not st["gifts"][login]:
            st["gifts"].pop(login)
        c["opened"] += 1
        _write()
    items = []
    try:
        import friend_bots
        bot = friend_bots.is_bot(login)
    except ImportError:
        bot = False
    if not bot:
        import research
        for r in _gift_contents(level):
            items.append(research._grant(login, r, log))
    up = interact(login, other)
    return {"message": f"You opened {name}'s gift!" + (" Friendship +1" if up else ""), "items": items}


# ------------------------------------------------------------------ trade rooms
def _mon(login, uid):
    try:
        import trading
        p = trading._player(login)
        if p is None or uid is None:
            return None
        c = trading._find(p, int(uid))
        return trading._row(p, c) if c else None
    except Exception:
        return None


def _room_brief(rid, r, login):
    other = r["b"] if r["a"] == login else r["a"]
    return {"trade": rid, "friend": other, "friend_name": (_info(other) or {}).get("name", other),
            "started_by_me": r["a"] == login, "ms": r["ms"],
            "chat_n": len(r["chat"]), "their_pick": r["pick"].get(other) is not None}


def _expire_rooms(st, now):
    for rid, r in list(st["rooms"].items()):
        if r["state"] == "open" and now - r["touched"] > ROOM_IDLE_MS:
            r["state"] = "cancelled"
            r["why"] = "The trade closed after two hours without a move."
            trade_chats.line(rid, "", r["why"], "cancelled")
        if r["state"] != "open" and now - r["touched"] > ROOM_SHOW_MS:
            st["rooms"].pop(rid)


def room_view(login, rid):
    """The room from `login`'s side: my pick, their pick, both confirmations, chat, cost."""
    import trading
    with _lock:
        st = _load()
        _expire_rooms(st, int(time.time() * 1000))
        r = st["rooms"].get(rid)
        if r is None or login not in (r["a"], r["b"]):
            return {"error": "That trade is over."}
        r = json.loads(json.dumps(r))                         # a copy to read outside the lock
    other = r["b"] if r["a"] == login else r["a"]
    mine, theirs = r["pick"].get(login), r["pick"].get(other)
    out = {"trade": rid, "state": r["state"], "friend": other,
           "friend_name": (_info(other) or {}).get("name", other),
           "mine": _mon(login, mine), "theirs": _mon(other, theirs),
           "my_ok": bool(r["ok"].get(login)), "their_ok": bool(r["ok"].get(other)),
           "chat": [{"me": m["who"] == login, "text": m["text"], "ms": m["ms"]} for m in r["chat"][-CHAT_KEEP:]],
           "why": r.get("why"),
           "result": {"got": r["result"].get(login), "gave": r["result"].get(other)} if r.get("result") else None}
    if mine and theirs and r["state"] == "open":
        q = trading.quote(login, other, mine, theirs)
        out["cost"] = q.get("cost") if q.get("ok") else None
        out["problem"] = None if q.get("ok") else q.get("error")
    return out


def _touch(r):
    r["touched"] = int(time.time() * 1000)


def _room_for(login, rid):
    r = _load()["rooms"].get(rid)
    if r is None or login not in (r["a"], r["b"]) or r["state"] != "open":
        return None
    return r


def box(login, who="me"):
    """My own tradeable Pokemon (each side picks only their own)."""
    import trading
    return trading.box(login)


def trade_start(login, other):
    with _lock:
        st = _load()
        if _key(login, other) not in st["links"]:
            return {"error": "You're not friends."}
        for rid, r in st["rooms"].items():
            if r["state"] == "open" and {r["a"], r["b"]} == {login, other}:
                return {"trade": rid}
        now = int(time.time() * 1000)
        rid = secrets.token_hex(6)
        st["rooms"][rid] = {"a": login, "b": other, "pick": {}, "ok": {}, "chat": [], "ms": now,
                            "touched": now, "state": "open"}
        _note(other, f"{(_info(login) or {}).get('name', 'A friend')} wants to trade! Profile menu > Friends")
        trade_chats.opened(rid, login, other, _info)
        _write()
        return {"trade": rid}


def trade_pick(login, rid, uid):
    import trading
    p = trading._player(login)
    try:
        c = trading._find(p, int(uid)) if p is not None else None
    except (TypeError, ValueError):
        c = None
    if c is None:
        return {"error": "Pick one of your Pokémon."}
    why = trading._blocked(p, c)
    if why:
        return {"error": f"That one can't be traded: {why}."}
    with _lock:
        r = _room_for(login, rid)
        if r is None:
            return {"error": "That trade is over."}
        r["pick"][login] = str(uid)
        r["ok"] = {}                                       # a new pick: both confirm again
        _touch(r)
        _write()
    m = trading._row(p, c) or {}
    trade_chats.line(rid, "", f"{(_info(login) or {}).get('name', login)} chose {m.get('name', '?')}"
                              f"{' (shiny)' if m.get('shiny') else ''} CP {m.get('cp', '?')}.")
    return {}


def trade_chat(login, rid, text):
    raw = " ".join(text.split())[:CHAT_MAX] if isinstance(text, str) else ""
    if not raw:
        return {}
    import chat_filter
    text, filtered = chat_filter.clean(raw)               # swearing / slurs starred out for the friend
    with _lock:
        r = _room_for(login, rid)
        if r is None:
            return {"error": "That trade is over."}
        r["chat"].append({"who": login, "text": text, "ms": int(time.time() * 1000)})
        del r["chat"][:-CHAT_KEEP]
        _touch(r)
        _write()
    trade_chats.line(rid, login, text, raw=raw if filtered else None)   # the admin page sees what was typed
    return {"message": "Some words were hidden."} if filtered else {}


def trade_ok(login, rid, log=None):
    """Confirm. When both have confirmed the same two Pokemon, the trade is made."""
    import trading
    with _lock:
        r = _room_for(login, rid)
        if r is None:
            return {"error": "That trade is over."}
        other = r["b"] if r["a"] == login else r["a"]
        if r["pick"].get(login) is None or r["pick"].get(other) is None:
            return {"error": "You both need to choose a Pokémon first."}
        r["ok"][login] = True
        _touch(r)
        both = bool(r["ok"].get(other))
        a, b = r["a"], r["b"]
        pa, pb = r["pick"].get(a), r["pick"].get(b)
        _write()
    trade_chats.line(rid, "", f"{(_info(login) or {}).get('name', login)} confirmed.")
    if not both:
        return {}
    res = trading.do(a, b, pa, pb)
    with _lock:
        r = _load()["rooms"].get(rid)
        if r is None:
            return {"error": "That trade is over."}
        if not res.get("ok"):
            r["ok"] = {}
            r["chat"].append({"who": "", "text": "Trade failed: " + (res.get("error") or "unknown"), "ms": int(time.time() * 1000)})
            _write()
            trade_chats.line(rid, "", "Trade failed: " + (res.get("error") or "unknown"))
            return {"error": res.get("error") or "The trade didn't go through."}
        r["state"] = "done"
        r["result"] = {a: res["b_mon"], b: res["a_mon"]}           # what each one got
        _touch(r)
        _write()
    trade_chats.line(rid, "", f"Traded: {(_info(a) or {}).get('name', a)} gave {res['a_mon']['name']}, "
                              f"{(_info(b) or {}).get('name', b)} gave {res['b_mon']['name']}.", "done")
    up = interact(a, b)
    with _lock:
        for who, got_from, got in ((a, b, res["b_mon"]), (b, a, res["a_mon"])):
            if who != login:
                _note(who, f"Trade with {(_info(got_from) or {}).get('name', got_from)} complete! You got {got['name']}.")
        _write()
    if log:
        log(f"[friends] trade {a} {res['a_mon']['name']} <-> {b} {res['b_mon']['name']}")
    return {"message": "Trade complete!" + (" Friendship +1" if up else "")}


def trade_cancel(login, rid):
    with _lock:
        r = _room_for(login, rid)
        if r is None:
            return {}
        other = r["b"] if r["a"] == login else r["a"]
        r["state"] = "cancelled"
        r["why"] = f"{(_info(login) or {}).get('name', 'Your friend')} left the trade."
        _touch(r)
        trade_chats.line(rid, "", r["why"], "cancelled")
        _note(other, f"{(_info(login) or {}).get('name', 'Your friend')} cancelled the trade.")
        _write()
    return {}


NOTE_KEEP = 10
NOTE_TTL_MS = 48 * 3600 * 1000


def _note(login, text):
    """Something to toast on `login`'s map (call with _lock held)."""
    try:
        import friend_bots
        if friend_bots.is_bot(login):
            return
    except ImportError:
        pass
    st = _load()
    now = int(time.time() * 1000)
    notes = [n for n in st["notes"].get(login) or [] if now - n["ms"] < NOTE_TTL_MS]
    ms = max([now] + [n["ms"] + 1 for n in notes])          # strictly increasing: the phone keeps the last one seen
    notes.append({"ms": ms, "text": text})
    st["notes"][login] = notes[-NOTE_KEEP:]


def notes_for(login):
    """The recent toasts for /research/ping."""
    now = int(time.time() * 1000)
    with _lock:
        return [n for n in _load()["notes"].get(login) or [] if now - n["ms"] < NOTE_TTL_MS]


def pending_count(login):
    with _lock:
        return len(_load()["requests"].get(login) or {})


# ----------------------------------------------------------------- actions
def _befriend(a, b):
    st = _load()
    days = 0
    try:
        import friend_bots                       # test bots start part-way up the hearts
        days = friend_bots.demo_days(a) or friend_bots.demo_days(b)
    except ImportError:
        pass
    st["links"][_key(a, b)] = {"since": int(time.time() * 1000), "days": days, "last": ""}
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
        _note(other, f"{(_info(login) or {}).get('name', 'A trainer')} accepted your friend request!")
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
        for a, b in ((login, other), (other, login)):
            (st["gifts"].get(a) or {}).pop(b, None)
        for rid, r in st["rooms"].items():
            if {r["a"], r["b"]} == {login, other} and r["state"] == "open":
                r["state"], r["why"] = "cancelled", "You're not friends any more."
                trade_chats.line(rid, "", f"{(_info(login) or {}).get('name', login)} removed the friend.", "cancelled")
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
        st["gifts"].pop(login, None)
        for g in st["gifts"].values():
            g.pop(login, None)
        for rid in [k for k, r in st["rooms"].items() if login in (r["a"], r["b"])]:
            st["rooms"].pop(rid)
        _write()


# --------------------------------------------------------------------- HTTP
def _json(obj, status=200):
    return status, {"Content-Type": "application/json", "Cache-Control": "no-store"}, \
        json.dumps(obj).encode("utf-8")


ACTIONS = {"add": lambda u, d: add(u, d.get("code")),
           "accept": lambda u, d: accept(u, str(d.get("id") or "")),
           "decline": lambda u, d: decline(u, str(d.get("id") or "")),
           "cancel": lambda u, d: cancel(u, str(d.get("id") or "")),
           "remove": lambda u, d: remove(u, str(d.get("id") or "")),
           "gift": lambda u, d: send_gift(u, str(d.get("id") or "")),
           "trade_start": lambda u, d: trade_start(u, str(d.get("id") or "")),
           "trade_pick": lambda u, d: trade_pick(u, str(d.get("trade") or ""), d.get("uid")),
           "trade_chat": lambda u, d: trade_chat(u, str(d.get("trade") or ""), d.get("text")),
           "trade_cancel": lambda u, d: trade_cancel(u, str(d.get("trade") or "")),
           "trade_report": lambda u, d: trade_chats.report(str(d.get("trade") or ""), u, d.get("reason"),
                                                           d.get("note"), _info)}
LOGGED = {"open": lambda u, d, log: open_gift(u, str(d.get("id") or ""), log),
          "trade_ok": lambda u, d, log: trade_ok(u, str(d.get("trade") or ""), log)}
ROOM_ACTIONS = {"trade_pick", "trade_chat", "trade_ok", "trade_cancel"}   # these answer with the room


def handle(method, path, query, headers, body, log, ip=None):
    rest = path[len("/friends"):].strip("/")
    if rest.startswith("art/"):
        f = os.path.join(ART_DIR, os.path.basename(rest[4:]))
        if not f.endswith(".png") or not os.path.exists(f):
            return 404, {"Content-Type": "text/plain"}, b"?"
        with open(f, "rb") as fh:
            return 200, {"Content-Type": "image/png", "Cache-Control": "max-age=86400"}, fh.read()
    if rest.startswith("trainer/") and rest.endswith(".png"):
        data = friends_portrait.png(rest[:-4].rsplit("/", 1)[-1])   # trainer/[<size>/]<look>.png
        if data is None:
            return 404, {"Content-Type": "text/plain"}, b"?"
        return 200, {"Content-Type": "image/png", "Cache-Control": "max-age=604800"}, data
    import rpc
    try:
        import friend_bots                       # only with WS_FRIEND_BOTS set (test servers)
        friend_bots.start(log or print)
    except ImportError:
        pass
    user = rpc.user_for_ip(ip)
    if not user:
        return _json({"error": "unknown trainer -- open the game first"}, 403)
    if rest in ("", "state"):
        return _json(state(user))
    if rest == "box":
        return _json(box(user))
    if rest == "trade":
        from urllib.parse import parse_qs
        return _json(room_view(user, (parse_qs(query or "").get("t") or [""])[0]))
    if method == "POST" and rest in LOGGED:
        try:
            data = json.loads((body or b"{}").decode("utf-8")) or {}
        except (ValueError, UnicodeDecodeError):
            data = {}
        out = LOGGED[rest](user, data if isinstance(data, dict) else {}, log)
        if rest in ROOM_ACTIONS:
            return _json(dict(room_view(user, str(data.get("trade") or "")), **out))
        return _json(dict(state(user), **out))
    if method == "POST" and rest in ACTIONS:
        try:
            data = json.loads((body or b"{}").decode("utf-8")) or {}
        except (ValueError, UnicodeDecodeError):
            data = {}
        out = ACTIONS[rest](user, data if isinstance(data, dict) else {})
        if log and (out.get("message") or out.get("error")) and rest != "trade_chat":
            log(f"[friends] {user} {rest}: {out.get('message') or out.get('error')}")
        if rest in ROOM_ACTIONS:
            return _json(dict(room_view(user, str(data.get("trade") or "")), **out))
        return _json(dict(state(user), **out))
    return _json({"error": "not found"}, 404)
