"""
Trade-room chat logs and player reports, for the website's admin page.

friends.py's trade rooms keep only their last CHAT_KEEP lines and vanish a few minutes
after they close, so every line said in a room is ALSO written here, with the room's
events (opened, traded, cancelled), and kept KEEP_DAYS. A trainer in a room can report
the other one (the REPORT button in the trade room): the report keeps its own copy of
the conversation, so it survives the room's log being trimmed.

    data/trade_chats.json
      {"rooms": {rid: {a, b, a_name, b_name, ms, last, state, filtered, lines: [{who, text, raw?, ms}]}},
       "reports": [{id, ms, by, by_name, against, against_name, trade, reason, note, lines, done}]}

who = a login, or "" for the room's own events. The admin page reads this through
trainer_admin.py (/windstock/admin/trade_chats, /trade_reports, /trade_report/done).
"""
import json
import os
import secrets
import threading
import time

import datadir

FILE = os.path.join(datadir.ensure(), "trade_chats.json")
KEEP_DAYS = 90
MAX_ROOMS = 3000
MAX_LINES = 500                     # per room (a room's chat is capped far lower in friends.py)
MAX_REPORTS = 1000
REASONS = {"harassment": "Harassment or bullying", "scam": "Scam or unfair trade",
           "inappropriate": "Inappropriate messages", "other": "Something else"}

_lock = threading.RLock()
_state = None


def _now():
    return int(time.time() * 1000)


def _load():
    global _state
    if _state is None:
        try:
            with open(FILE, encoding="utf-8") as fh:
                _state = json.load(fh)
        except (OSError, ValueError):
            _state = {}
        _state.setdefault("rooms", {})
        _state.setdefault("reports", [])
    return _state


def _save():
    st = _load()
    cut = _now() - KEEP_DAYS * 86400 * 1000
    rooms = st["rooms"]
    for rid in [k for k, r in rooms.items() if r.get("last", r.get("ms", 0)) < cut]:
        rooms.pop(rid)
    if len(rooms) > MAX_ROOMS:
        for rid in sorted(rooms, key=lambda k: rooms[k].get("last", 0))[:len(rooms) - MAX_ROOMS]:
            rooms.pop(rid)
    del st["reports"][:-MAX_REPORTS]
    tmp = FILE + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(st, fh, indent=1, ensure_ascii=False)
        os.replace(tmp, FILE)
    except OSError:
        pass


def _name(login, info):
    try:
        return (info(login) or {}).get("name") or login
    except Exception:
        return login


def opened(rid, a, b, info):
    """A new trade room (friends.trade_start). `info(login)` -> {"name": ...}."""
    with _lock:
        st = _load()
        now = _now()
        st["rooms"][rid] = {"a": a, "b": b, "a_name": _name(a, info), "b_name": _name(b, info),
                            "ms": now, "last": now, "state": "open",
                            "lines": [{"who": "", "text": f"{_name(a, info)} opened the trade.", "ms": now}]}
        _save()


def line(rid, who, text, state=None, raw=None):
    """Something said (who = a login) or done (who = "") in a room. `raw` = what was really
    typed when chat_filter starred some of it out (the admin page shows both)."""
    with _lock:
        r = _load()["rooms"].get(rid)
        if r is None:
            return
        now = _now()
        entry = {"who": who, "text": str(text), "ms": now}
        if raw:
            entry["raw"] = str(raw)
            r["filtered"] = r.get("filtered", 0) + 1
        r["lines"].append(entry)
        del r["lines"][:-MAX_LINES]
        r["last"] = now
        if state:
            r["state"] = state
        _save()


def report(rid, by, reason, note, info):
    """`by` reports the other trainer in room `rid`. -> {"message"} or {"error"}."""
    reason = str(reason or "").strip().lower()
    if reason not in REASONS:
        reason = "other"
    note = " ".join(str(note or "").split())[:300]
    with _lock:
        st = _load()
        r = st["rooms"].get(rid)
        if r is None or by not in (r["a"], r["b"]):
            return {"error": "That trade can't be reported any more."}
        against = r["b"] if r["a"] == by else r["a"]
        if any(x["trade"] == rid and x["by"] == by for x in st["reports"]):
            return {"message": "You already reported this trade. Thanks, we'll take a look."}
        mine = [x for x in st["reports"] if x["by"] == by and _now() - x["ms"] < 3600 * 1000]
        if len(mine) >= 5:
            return {"error": "Too many reports in a short time. Try again later."}
        names = {r["a"]: r["a_name"], r["b"]: r["b_name"]}
        st["reports"].append({
            "id": secrets.token_hex(6), "ms": _now(), "trade": rid,
            "by": by, "by_name": _name(by, info) or names.get(by, by),
            "against": against, "against_name": _name(against, info) or names.get(against, against),
            "reason": reason, "note": note, "done": False,
            "lines": [dict(x, name=names.get(x["who"], "") if x["who"] else "") for x in r["lines"]]})
        r["lines"].append({"who": "", "text": f"{names.get(by, by)} reported this trade.", "ms": _now()})
        _save()
    return {"message": "Thanks. The report went to the Windstock team with this trade's chat."}


# --------------------------------------------------------------- the admin page
def _room_out(rid, r):
    names = {r["a"]: r["a_name"], r["b"]: r["b_name"]}
    return {"trade": rid, "a": r["a"], "b": r["b"], "a_name": r["a_name"], "b_name": r["b_name"],
            "ms": r["ms"], "last": r.get("last", r["ms"]), "state": r.get("state", "open"),
            "filtered": r.get("filtered", 0),
            "lines": [dict(x, name=names.get(x["who"], "") if x["who"] else "") for x in r["lines"]]}


def rooms(login="", limit=50):
    """The newest rooms, or one trainer's (login or display name, any case)."""
    q = str(login or "").strip().lower()
    with _lock:
        st = _load()
        out = []
        for rid, r in sorted(st["rooms"].items(), key=lambda kv: -kv[1].get("last", 0)):
            if q and q not in (r["a"].lower(), r["b"].lower(), r["a_name"].lower(), r["b_name"].lower()):
                continue
            out.append(_room_out(rid, r))
            if len(out) >= limit:
                break
        return {"ok": True, "rooms": out, "total": len(st["rooms"])}


def reports():
    with _lock:
        st = _load()
        items = sorted(st["reports"], key=lambda x: (x["done"], -x["ms"]))
        return {"ok": True, "reports": [dict(x, reason_text=REASONS.get(x["reason"], x["reason"])) for x in items],
                "open": sum(1 for x in items if not x["done"])}


def set_done(rid, done):
    with _lock:
        for x in _load()["reports"]:
            if x["id"] == rid:
                x["done"] = bool(done)
                _save()
                return {"ok": True, "report": x["id"], "done": x["done"], "against": x["against_name"]}
    return {"ok": False, "error": "No such report."}
