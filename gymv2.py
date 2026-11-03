"""
The new gym system (0.67-0.71, "gym rework") on the 0.35 client -- settings gyms.v2.

What 0.71 changed, from its protos (work/il2cpp/v071/out/dump.cs):
  MotivatedPokemonProto { pokemon, deploy_ms, cp_when_deployed, motivation_now, cp_now,
                          berry_value, feed_cooldown_duration_millis, food_value }
  GymLevelSettingsProto { trainer_slots }          -> 6 slots, one Pokemon per trainer
  GymFeedPokemonProto   { item, gym_id, pokemon_id } -> berries restore motivation
  GymBadgeGmtSettingsProto { target, battle_winning_score_per_defender_cp,
      gym_defending_score_per_minute, berry_feeding_score, pokemon_deploy_score,
      raid_battle_winning_score }                  -> VANILLA/BRONZE/SILVER/GOLD badges
  FortSearchOutProto { awarded_gym_badge, team_bonus_loot } -> gyms can be spun

The 0.35 client has none of those messages, so:
  * the rules live here and in world.py's gym functions (deploy, battles, returns);
  * a defender's CP in every 0.35 gym message is its CURRENT CP (cp_now), so the
    old client draws and fights the weakened Pokemon with no change;
  * the tweak's gym screen (Gyms071.inc.mm) draws hearts, the Feed and Spin buttons
    and the badge from GET /gym/status, and posts /gym/feed and /gym/spin.

Motivation is never ticked: it is worked out from the last stored value and the time
since (mot, mot_ms on the gym member), so nothing runs in the background.
Saved here (gymv2.json): badges and the daily coin tally. Defenders stay in gyms.json.

Routes (on the game host, like /raid):
  GET  /gym/status?gym=ID   defenders with motivation, your badge, spin cooldown
  POST /gym/feed  {gym, uid}  one Razz Berry into a defender of your team
  POST /gym/spin  {gym}       spin the gym's photo disc
"""
import datetime
import json
import os
import threading
import time
from urllib.parse import parse_qs

import settings as _cfg
import world

_lock = threading.RLock()
FILE = os.path.join(world.HERE, "gymv2.json")
BADGES = {}        # username -> {fort_id: {score, won, lost, berries, deploys, defended_ms, raids}}
COIN_DAYS = {}     # username -> {"day": "YYYY-MM-DD", "coins": n}
FEEDS = {}         # (username, fort_id) -> [feed timestamps ms]   (memory only)
FEED_CD = {}       # (username, fort_id, uid) -> ms of the last berry (memory only)

ITEM_RAZZ = 701
BADGE_NAMES = ("none", "vanilla", "bronze", "silver", "gold")


def on():
    return bool(_cfg.get("gyms", "v2", cast=bool))


def _s(key, cast=float):
    return _cfg.get("gyms", "v2_" + key, cast=cast)


def _now():
    return int(time.time() * 1000)


def _today():
    return datetime.datetime.utcnow().strftime("%Y-%m-%d")


# ------------------------------------------------------------------ persistence
def load():
    try:
        with open(FILE, "r", encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return False
    with _lock:
        BADGES.clear()
        BADGES.update({u: v for u, v in (d.get("badges") or {}).items() if isinstance(v, dict)})
        COIN_DAYS.clear()
        COIN_DAYS.update({u: v for u, v in (d.get("coin_days") or {}).items() if isinstance(v, dict)})
    return True


def save():
    with _lock:
        d = {"badges": BADGES, "coin_days": COIN_DAYS}
        try:
            tmp = FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(d, fh, indent=1)
            os.replace(tmp, FILE)
        except OSError:
            pass


# ------------------------------------------------------------------ motivation
def motivation(m, now_ms=None):
    """A defender's motivation now (0..1): the stored value, decayed since it was set.
    A member from before gym v2 (no mot_ms) starts full from its deploy time."""
    now = _now() if now_ms is None else now_ms
    base = float(m.get("mot", 1.0))
    since = int(m.get("mot_ms") or m.get("deployed_ms") or now)
    hours = max(0.0, (now - since) / 3_600_000.0)
    return max(0.0, min(1.0, base - _s("motivation_decay_per_hour") * hours))


def cp_full(m):
    return int(m.get("cp_full") or m.get("cp") or 10)


def cp_now(m, now_ms=None):
    """CpNow from CpWhenDeployed: falls linearly to min_cp_fraction at 0 motivation."""
    lo = _s("min_cp_fraction")
    return max(10, int(round(cp_full(m) * (lo + (1.0 - lo) * motivation(m, now_ms)))))


def view_member(m, now_ms=None):
    """The member as every 0.35 message should see it: today's CP."""
    if m.get("raid") or not on():
        return m
    return dict(m, cp=cp_now(m, now_ms), cp_full=cp_full(m), mot=motivation(m, now_ms))


def _set_motivation(m, value, now_ms):
    m["cp_full"] = cp_full(m)
    m["mot"] = max(0.0, min(1.0, float(value)))
    m["mot_ms"] = int(now_ms)


# ------------------------------------------------------------------ deploy
def check_deploy(fort_id, members, c, username):
    """Gym-v2 deploy rules, called by world.deploy under world._lock. Returns the
    refusal reason, or None. 6 slots; one Pokemon per trainer per gym; no species
    twice; at most v2_max_gyms_per_trainer gyms at once."""
    if len(members) >= _s("slots", int):
        return "gym full"
    if any(m.get("owner") == username for m in members):
        return "already deployed"            # FortDeploy 2 = ALREADY_HAS_POKEMON_ON_FORT
    if any(int(m.get("pokemon_id", 0)) == int(c["pokemon_id"]) for m in members):
        return "same species"
    held = sum(1 for ms in world.GYMS.values() if any(m.get("owner") == username for m in ms))
    if held >= _s("max_gyms_per_trainer", int):
        return "too many gyms"
    return None


def on_deploy(fort_id, member, username, now_ms=None):
    now = _now() if now_ms is None else now_ms
    member["cp_full"] = int(member.get("cp") or 10)
    member["mot"], member["mot_ms"] = 1.0, now
    badge_add(username, fort_id, _s("badge_deploy"), "deploys")


# ------------------------------------------------------------------ battles
def on_defender_beaten(fort_id, uid, attacker, now_ms=None):
    """An attacker beat this defender. 0.71: it loses motivation; if it was already
    at 0 it is sent home. Returns True when it left the gym. Badge points for the
    attacker scale with the CP they were up against."""
    now = _now() if now_ms is None else now_ms
    gone, member = False, None
    with world._lock:
        members = world.GYMS.get(fort_id, [])
        for m in members:
            if m["uid"] == uid:
                member = m
                break
        if member is not None:
            mot = motivation(member, now)
            if mot <= 0.0:
                members.remove(member)
                gone = True
                if not members:
                    world.GYMS.pop(fort_id, None)
                    world.PRESTIGE.pop(fort_id, None)
                    if member.get("npc"):
                        world.NPC_CLEARED[fort_id] = now
            else:
                _set_motivation(member, mot - _s("defeat_motivation_loss"), now)
    if member is None:
        return False
    if attacker:
        badge_add(attacker, fort_id, _s("badge_battle_per_cp") * cp_now(member, now), "won")
    if member.get("owner"):
        badge_add(member["owner"], fort_id, 0, "lost")
    if gone:
        send_home(fort_id, member, now)
    world.save_gyms()
    return gone


def send_home(fort_id, member, now_ms):
    """A defender leaves the gym: its coins (1 per v2_coin_minutes held) and defending
    badge points go to the owner, through world.RETURNS so it is paid on their next
    request even when someone else knocked it out."""
    owner = member.get("owner")
    if not owner:
        return
    held_ms = max(0, now_ms - int(member.get("deployed_ms") or now_ms))
    coins = int(held_ms // (_s("coin_minutes") * 60_000))
    badge_add(owner, fort_id, _s("badge_defend_per_minute") * held_ms / 60_000, "defended_ms",
              amount=held_ms)
    with world._lock:
        world.RETURNS.setdefault(owner, []).append(
            [fort_id, member["pokemon_id"], coins, owner, member["uid"]])


def cap_coins(username, coins):
    """Defender coins are capped per day (0.71: 50)."""
    if coins <= 0:
        return 0
    with _lock:
        row = COIN_DAYS.get(username)
        if not row or row.get("day") != _today():
            row = COIN_DAYS[username] = {"day": _today(), "coins": 0}
        pay = max(0, min(coins, _s("coins_daily_cap", int) - int(row["coins"])))
        row["coins"] = int(row["coins"]) + pay
    save()
    return pay


# ------------------------------------------------------------------ berries
def feed(username, fort_id, uid, now_ms=None):
    """One Razz Berry into a defender of your own team (GymFeedPokemonProto).
    Returns (ok, message, stardust)."""
    now = _now() if now_ms is None else now_ms
    my_team = world.team_of(username)
    with world._lock:
        member = next((m for m in world.GYMS.get(fort_id, []) if str(m["uid"]) == str(uid)), None)
    if member is None:
        return False, "That Pokémon isn't in this gym any more.", 0
    if not my_team or int(member.get("team", 0)) != my_team:
        return False, "You can only feed Pokémon on your team.", 0
    if motivation(member, now) >= 0.999:
        return False, f"{_name(member)} is full of motivation.", 0
    key = (username, fort_id)
    window = _s("feed_window_minutes") * 60_000
    with _lock:
        recent = [t for t in FEEDS.get(key, []) if now - t < window]
        FEEDS[key] = recent
        if len(recent) >= _s("feed_limit", int):
            return False, "This gym's Pokémon have had enough berries for now.", 0
        last = FEED_CD.get((username, fort_id, member["uid"]), 0)
        if now - last < _s("feed_cooldown_seconds") * 1000:
            return False, f"{_name(member)} is still eating.", 0
    prev = world.current()
    try:
        world.use(username)
        if not world.take_item(ITEM_RAZZ, 1):
            return False, "You have no Razz Berries.", 0
        dust = _s("berry_stardust", int)
        world.add_stardust(dust)
        world.save()
    finally:
        world._current.player = prev
    with world._lock:
        _set_motivation(member, motivation(member, now) + _s("berry_motivation"), now)
    with _lock:
        FEEDS[key].append(now)
        FEED_CD[(username, fort_id, member["uid"])] = now
    badge_add(username, fort_id, _s("badge_berry"), "berries")
    world.save_gyms()
    return True, f"{_name(member)} ate the Razz Berry! +{dust} Stardust", dust


def _name(m):
    try:
        import raidlobby
        return raidlobby._name(m["pokemon_id"])
    except Exception:
        return "The Pokémon"


# ------------------------------------------------------------------ badges
def badge_add(username, fort_id, points, stat=None, amount=1):
    if not username or not fort_id:
        return
    with _lock:
        b = BADGES.setdefault(username, {}).setdefault(fort_id, {"score": 0.0})
        b["score"] = float(b.get("score", 0)) + max(0.0, float(points))
        if stat:
            b[stat] = int(b.get(stat, 0)) + int(amount)
        b["t"] = _now()
    save()


def badge(username, fort_id):
    """{type 1-4 (VANILLA..GOLD, 0 = never touched), score, next, stats}."""
    with _lock:
        b = dict((BADGES.get(username) or {}).get(fort_id) or {})
    if not b:
        return {"type": 0, "name": "none", "score": 0, "next": None}
    score = float(b.get("score", 0))
    targets = list(_cfg.get("gyms", "v2_badge_targets") or [500, 4000, 30000])
    t = 1
    for i, need in enumerate(targets[:3]):
        if score >= float(need):
            t = 2 + i
    nxt = float(targets[t - 1]) if t - 1 < len(targets[:3]) else None
    return {"type": t, "name": BADGE_NAMES[t], "score": int(score),
            "next": int(nxt) if nxt is not None else None,
            "stats": {k: v for k, v in b.items() if k not in ("score", "t")}}


def spin_bonus(username, fort_id):
    """Extra items for a gym spin: +1/+2/+3 for a bronze/silver/gold badge, plus the
    team bonus when your team holds the gym (FortSearchOutProto.team_bonus_loot)."""
    t = badge(username, fort_id)["type"]
    extra = max(0, t - 1)
    team = world.team_of(username)
    if team and world.gym_holder_team(fort_id) == team:
        extra += _s("spin_team_bonus", int)
    return extra


def spin(username, fort_id, now_ms=None):
    """Spin a gym like a PokeStop (the 0.35 server's own loot table), with the badge
    and team bonus items on top. Returns (ok, message, items, xp)."""
    import protocol as P
    import pb
    import random
    now = _now() if now_ms is None else now_ms
    prev = world.current()
    try:
        world.use(username)
        cd = world.spin_cooldown(fort_id)
        if cd and cd > now:
            return False, "Come back in a few minutes.", [], 0
        raw = P.build_fort_search_response(fort_id, now)
        f = pb.decode(raw)
        if (pb.get(f, 1, pb.WT_VARINT) or 0) != 1:
            return False, "Your bag is full.", [], 0
        items = {}
        for a in (x["value"] for x in f if x["field"] == 2 and x["wire"] == pb.WT_LEN):
            af = pb.decode(a)
            iid = pb.get(af, 1, pb.WT_VARINT) or 0
            items[iid] = items.get(iid, 0) + (pb.get(af, 2, pb.WT_VARINT) or 1)
        extra = spin_bonus(username, fort_id)
        if extra:
            rnd = random.Random(f"{fort_id}:{username}:{now // 300000}")
            for _ in range(extra):
                iid = rnd.choice([1, 1, 1, 101, 701, 201, 2])
                if world.room_in_bag() <= 0:
                    break
                world.add_item(iid, 1)
                items[iid] = items.get(iid, 0) + 1
        world.save()
        xp = int(_cfg.get("pokestops", "xp_per_spin", cast=int))
    finally:
        world._current.player = prev
    return True, "", [{"item": int(k), "count": int(v)} for k, v in items.items() if k], xp


# ------------------------------------------------------------------ the tweak's view
def status(username, fort_id, now_ms=None):
    now = _now() if now_ms is None else now_ms
    mine = world.team_of(username)
    members = []
    for m in world.gym_members(fort_id):
        if m.get("raid"):
            continue
        last = FEED_CD.get((username, fort_id, m["uid"]), 0)
        members.append({
            "uid": str(m["uid"]), "pokemon_id": int(m["pokemon_id"]),
            "name": _name(m), "trainer": m.get("trainer", ""), "team": int(m.get("team", 0)),
            "cp": cp_now(m, now), "cp_full": cp_full(m), "motivation": round(motivation(m, now), 3),
            "mine": m.get("owner") == username,
            "feed_in_ms": max(0, int(last + _s("feed_cooldown_seconds") * 1000 - now))})
    cd = 0
    prev = world.current()
    try:
        world.use(username)
        cd = max(0, int(world.spin_cooldown(fort_id) or 0) - now)
        berries = dict(world.bag_items()).get(ITEM_RAZZ, 0)
    finally:
        world._current.player = prev
    return {"on": True, "gym": fort_id, "server_ms": now, "team": world.gym_holder_team(fort_id),
            "my_team": mine, "slots": _s("slots", int), "members": members,
            "badge": badge(username, fort_id), "spin_in_ms": cd, "berries": berries}


def _json(obj, status=200):
    return status, {"Content-Type": "application/json", "Cache-Control": "no-store"}, \
        json.dumps(obj).encode("utf-8")


def handle(method, path, query, headers, body, log, ip=None):
    import rpc
    if not on():
        return _json({"on": False})
    q = {k: v[0] for k, v in parse_qs(query or "").items()}
    data = {}
    if body:
        try:
            data = json.loads(body.decode("utf-8")) or {}
        except (ValueError, UnicodeDecodeError):
            data = {}
    user = rpc.user_for_ip(ip)
    if not user:
        return _json({"error": "unknown trainer -- open the game first"}, 403)
    fort = str(data.get("gym") or q.get("gym") or rpc.gym_for_user(user) or "")
    if not fort:
        return _json({"error": "no gym"}, 400)
    action = path[len("/gym"):].strip("/") or "status"
    out = {}
    if action == "feed":
        ok, msg, dust = feed(user, fort, data.get("uid"))
        log(f"[gym] {user} fed a berry at {fort}: {msg}")
        out = {"ok": ok, "message": msg, "stardust": dust}
    elif action == "spin":
        ok, msg, items, xp = spin(user, fort)
        log(f"[gym] {user} spun {fort}: {items or msg}")
        out = {"ok": ok, "message": msg, "items": items, "xp": xp}
    elif action != "status":
        return _json({"error": f"unknown action {action!r}"}, 404)
    out.update(status(user, fort))
    return _json(out)


load()
