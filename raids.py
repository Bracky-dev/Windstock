"""
Scheduled raids -- the 0.71 raid rules on the 0.35 client.

0.71 put a raid on a gym as RaidInfoProto { raid_seed, raid_spawn_ms (egg shows),
raid_battle_ms (egg hatches), raid_end_ms (boss leaves), raid_pokemon, raid_level }.
The 0.35 client has none of that, so here a raid is worked out from the gym id and
the time window alone: every gym rolls once per window, seeded by (gym, window), so
every trainer -- and every server restart -- sees the same egg, tier and boss without
anything being stored. Only the things people DO are saved (raids.json): forced
raids from the World Manager, raid passes, and rewards waiting to be paid.

While a raid's boss is out it IS the gym's defender list (world.gym_members), so the
game's own gym screen shows it and the gym battle fights it. Real defenders stay in
gyms.json and are back when the raid ends. The lobby / countdown / HUD are the
tweak's screens over raidlobby.py. Numbers: work/newer-versions/RAIDS-GYMS-071.md.
"""
import datetime
import json
import math
import os
import random
import threading
import time

import settings as _cfg
import world

_lock = threading.RLock()
RAIDS_FILE = os.path.join(world.HERE, "raids.json")

FORCED = {}            # fort_id -> raid dict (World Manager "start a raid here")
PASSES = {}            # username -> {"day": "YYYY-MM-DD", "free_used": bool, "premium": n}
PENDING = {}           # username -> [reward dict], paid on that trainer's next request
_ROLLS = {}            # (fort_id, window) -> raid dict or None (cache, rebuilt freely)

ITEM_POKE_BALL, ITEM_RAZZ, ITEM_REVIVE, ITEM_POTION = 1, 701, 201, 101


def _now():
    return int(time.time() * 1000)


def _s(key, cast=float):
    return _cfg.get("raids", key, cast=cast)


def _list(key):
    v = _cfg.get("raids", key)
    return list(v) if isinstance(v, (list, tuple)) else []


# ------------------------------------------------------------------ persistence
def load():
    try:
        with open(RAIDS_FILE, "r", encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return False
    with _lock:
        FORCED.clear()
        FORCED.update({k: v for k, v in (d.get("forced") or {}).items()
                       if isinstance(v, dict)})
        PASSES.clear()
        PASSES.update({k: v for k, v in (d.get("passes") or {}).items()
                       if isinstance(v, dict)})
        PENDING.clear()
        PENDING.update({k: v for k, v in (d.get("pending") or {}).items()
                        if isinstance(v, list)})
    # Boss HP pools, so a restart mid-raid doesn't heal the boss. The key is a tuple
    # in memory and a list in JSON.
    with world._lock:
        for fid, s in (d.get("bosses") or {}).items():
            if isinstance(s, dict) and isinstance(s.get("key"), list):
                s["key"] = tuple(s["key"])
                world.RAID_BOSSES[fid] = s
    return True


def save():
    now = _now()
    with _lock:
        forced = {k: v for k, v in FORCED.items() if v["end_ms"] > now}
        FORCED.clear()
        FORCED.update(forced)
        d = {"forced": forced, "passes": PASSES, "pending": PENDING}
    with world._lock:
        d["bosses"] = {k: dict(v, key=list(v["key"])) for k, v in world.RAID_BOSSES.items()}
    try:
        tmp = RAIDS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(d, fh, indent=1)
        os.replace(tmp, RAIDS_FILE)
    except OSError:
        pass


# ------------------------------------------------------------------ the schedule
def _pool(tier):
    pools = _cfg.get("raids", "pools") or {}
    got = pools.get(str(tier)) or pools.get(tier) or []
    return [int(p) for p in got if 1 <= int(p) <= 151] or [129]


def _tier_value(key, tier, default):
    vals = _list(key)
    return vals[tier - 1] if 0 < tier <= len(vals) else default


def boss_cp(pokemon_id, tier):
    """Battle CP of a boss: perfect IVs at its tier's CP multiplier (0.61..0.79), so
    the real damage formula makes it as tough as the 0.71 boss was."""
    st = _stats(pokemon_id)
    if not st:
        return 1000
    a, d, s = st
    cpm = float(_tier_value("tier_cpm", tier, 0.79))
    return max(10, int((a + 15) * math.sqrt(d + 15) * math.sqrt(s + 15) * cpm * cpm / 10))


def catch_cp(pokemon_id, seed):
    """The CP of the boss you get to catch: level 20, IVs 10-15 (the 0.71 rule)."""
    st = _stats(pokemon_id)
    if not st:
        return 500
    r = random.Random(seed)
    a, d, s = (v + r.randint(10, 15) for v in st)
    cpm = 0.5974                                       # level 20
    return max(10, int(a * math.sqrt(d) * math.sqrt(s) * cpm * cpm / 10))


def _stats(pokemon_id):
    try:
        import gamedata
        return gamedata.STATS.get(int(pokemon_id))
    except Exception:
        return None


def _make(fort_id, seed, tier, pokemon_id, spawn_ms, forced=False):
    egg = int(_s("egg_minutes") * 60_000)
    battle = int(_s("battle_minutes") * 60_000)
    return {"fort": fort_id, "seed": seed, "tier": int(tier),
            "pokemon_id": int(pokemon_id), "cp": boss_cp(pokemon_id, tier),
            "spawn_ms": int(spawn_ms), "hatch_ms": int(spawn_ms) + egg,
            "end_ms": int(spawn_ms) + egg + battle, "forced": forced,
            "uid": world._stable_uid("raid", fort_id, seed)}


def _roll(fort_id, window):
    # The schedule settings are part of the key: changing them in settings.json
    # (hot-reloaded) must not keep serving rolls made under the old numbers.
    key = (fort_id, window, _s("window_minutes"), _s("chance"), _s("egg_minutes"),
           _s("battle_minutes"))
    if key in _ROLLS:
        return _ROLLS[key]
    if len(_ROLLS) > 20000:
        _ROLLS.clear()
    win_ms = int(_s("window_minutes") * 60_000)
    r = random.Random(f"raid:{fort_id}:{window}")
    out = None
    if r.random() < _s("chance"):
        weights = [max(0.0, float(w)) for w in _list("tier_weights")] or [1.0]
        tier = r.choices(range(1, len(weights) + 1), weights=weights)[0]
        pid = r.choice(_pool(tier))
        length = int((_s("egg_minutes") + _s("battle_minutes")) * 60_000)
        offset = r.randint(0, max(0, win_ms - length))
        out = _make(fort_id, f"{window}", tier, pid, window * win_ms + offset)
    _ROLLS[key] = out
    return out


def raid_at(fort_id, now_ms=None):
    """This gym's raid right now -- egg or boss -- or None."""
    if not fort_id:
        return None
    now = _now() if now_ms is None else int(now_ms)
    with _lock:
        f = FORCED.get(fort_id)
    if f and f["spawn_ms"] <= now < f["end_ms"]:
        return dict(f)
    if not _s("scheduled", cast=bool):
        return None
    win_ms = int(_s("window_minutes") * 60_000)
    if win_ms <= 0:
        return None
    w = now // win_ms
    for window in (w, w - 1):                 # a long raid may run past its window
        r = _roll(fort_id, window)
        if r and r["spawn_ms"] <= now < r["end_ms"]:
            return dict(r)
    return None


def hatched(r, now_ms=None):
    now = _now() if now_ms is None else now_ms
    return bool(r) and r["hatch_ms"] <= now < r["end_ms"]


def boss_member(fort_id, now_ms=None):
    """The boss as a gym member (what world.gym_members hands the battle code), or
    None while there is no raid or it is still an egg."""
    r = raid_at(fort_id, now_ms)
    if not hatched(r, now_ms):
        return None
    return {"uid": r["uid"], "pokemon_id": r["pokemon_id"], "cp": r["cp"],
            "trainer": "Raid Boss", "team": 0, "raid": True, "tier": r["tier"],
            "raid_end_ms": r["end_ms"], "deployed_ms": r["hatch_ms"]}


def boss_max_hp(member, base_hp):
    """The boss's shared HP pool. A scheduled boss has its tier's 0.71 HP; the old
    World Manager raid mode keeps scaling the defender's own HP."""
    tier = int(member.get("tier") or 0)
    if tier:
        return max(1, int(_tier_value("tier_hp", tier, 3000)))
    return max(1, int(base_hp * _s("boss_hp_multiplier")))


def battle_seconds(member):
    tier = int(member.get("tier") or 0)
    if tier:
        return float(_tier_value("tier_seconds", tier, 180))
    return _s("raid_seconds")


def respawn_ms(member):
    """How long a beaten boss stays down. A scheduled raid gives the next group a
    fresh boss as soon as the last group's results are up."""
    if member.get("tier"):
        return int(_s("next_group_seconds") * 1000)
    return int(_s("respawn_minutes") * 60_000)


def force(fort_id, tier=None, pokemon_id=None, hatch_now=True):
    """World Manager: start a raid at this gym now (egg skipped unless hatch_now=False)."""
    tier = max(1, min(5, int(tier or 1)))
    pid = int(pokemon_id) if pokemon_id else random.choice(_pool(tier))
    now = _now()
    spawn = now - int(_s("egg_minutes") * 60_000) if hatch_now else now
    r = _make(fort_id, f"f{now}", tier, pid, spawn, forced=True)
    with _lock:
        FORCED[fort_id] = r
    with world._lock:
        world.RAID_BOSSES.pop(fort_id, None)
    save()
    return dict(r)


def clear(fort_id):
    with _lock:
        had = FORCED.pop(fort_id, None) is not None
    with world._lock:
        world.RAID_BOSSES.pop(fort_id, None)
    save()
    return had


def near(lat, lng, radius_m=None, now_ms=None):
    """Raids (eggs and bosses) at the gyms this server has drawn near a point."""
    import protocol as P
    now = _now() if now_ms is None else now_ms
    rad = float(radius_m if radius_m is not None else _s("map_radius_m"))
    out = []
    for fid, (glat, glng), dist in gyms_around(lat, lng):
        if dist > rad:
            continue
        r = raid_at(fid, now)
        if r:
            out.append(view(r, now, dist=dist, lat=glat, lng=glng))
    out.sort(key=lambda v: v["distance_m"])
    return out[:40]


def known_gyms(lat=None, lng=None):
    """{gym_id: (lat, lng)}. Gyms come from three places, because the 0.35 game sends
    no map request while you stand still: ones the map drew since the restart, World
    Manager-placed gyms, and (given a point) the world-pack / OSM gyms in the ~1.5 km
    of level-15 cells around it."""
    import protocol as P
    gyms = dict(P._GYM_POS)
    try:
        import places
        for f in places.get().get("forts", []):
            if f.get("kind") == "gym":
                gyms.setdefault(f["id"], (f["lat"], f["lng"]))
    except Exception:
        pass
    if lat is not None:
        try:
            import pois
            for f in pois.near(lat, lng):
                if f.get("kind") == "gym" or f.get("gym"):
                    gyms.setdefault(f["id"], (f["lat"], f["lng"]))
        except Exception:
            pass
    return gyms


def gyms_around(lat, lng):
    """[(gym_id, (lat, lng), metres)] nearest first."""
    out = [(fid, pos, _metres(lat, lng, pos[0], pos[1]))
           for fid, pos in known_gyms(lat, lng).items()]
    out.sort(key=lambda t: t[2])
    return out


def view(r, now, **extra):
    out = {"gym": r["fort"], "tier": r["tier"], "hatched": hatched(r, now),
           "hatch_ms": r["hatch_ms"], "end_ms": r["end_ms"],
           "hatch_in_ms": max(0, r["hatch_ms"] - now),
           "ends_in_ms": max(0, r["end_ms"] - now)}
    if out["hatched"]:
        out.update(pokemon_id=r["pokemon_id"], cp=r["cp"])
    if "dist" in extra:
        out.update(distance_m=int(extra["dist"]), lat=extra["lat"], lng=extra["lng"])
    return out


def _metres(lat1, lng1, lat2, lng2):
    p = math.pi / 180
    x = (lng2 - lng1) * p * math.cos((lat1 + lat2) * p / 2)
    y = (lat2 - lat1) * p
    return 6371000 * math.hypot(x, y)


# ------------------------------------------------------------------ raid passes
def _today():
    return datetime.datetime.utcnow().strftime("%Y-%m-%d")


def _pass_row(user):
    row = PASSES.setdefault(user, {"day": _today(), "free_used": False, "premium": 0})
    if row.get("day") != _today():
        row["day"], row["free_used"] = _today(), False
    return row


def passes(user):
    with _lock:
        row = _pass_row(user)
        return {"free": 0 if row["free_used"] else max(0, _s("free_passes_per_day", int)),
                "premium": int(row.get("premium", 0)),
                "premium_price": _s("premium_pass_coins", int)}


def use_pass(user):
    """Spend a pass to join a lobby: today's free one first. Returns which kind was
    used ("free"/"premium"), or None when the trainer has none."""
    with _lock:
        row = _pass_row(user)
        if not row["free_used"] and _s("free_passes_per_day", int) > 0:
            row["free_used"] = True
            kind = "free"
        elif row.get("premium", 0) > 0:
            row["premium"] -= 1
            kind = "premium"
        else:
            return None
    save()
    return kind


def refund_pass(user, kind):
    with _lock:
        row = _pass_row(user)
        if kind == "free":
            row["free_used"] = False
        elif kind == "premium":
            row["premium"] = int(row.get("premium", 0)) + 1
    save()


def buy_pass(user):
    """Premium Raid Pass for PokeCoins. Returns (ok, message)."""
    price = _s("premium_pass_coins", int)
    world.use(user)
    if not world.spend_coins(price):
        return False, f"A Premium Raid Pass costs {price} PokeCoins."
    with _lock:
        row = _pass_row(user)
        row["premium"] = int(row.get("premium", 0)) + 1
    save()
    return True, "Premium Raid Pass bought."


# ------------------------------------------------------------------ rewards
def rewards_for(member, damage, max_hp, seed, bonus=None):
    """One trainer's rewards for a beaten boss. 0.71 gave Rare Candy, Golden Razz,
    TMs, Revives and Premier Balls; 0.35 has none of those but Revives, so: candy
    of the boss, Razz Berries, Revives, and plain Poke Balls for the catch.
    The ball count is 0.71's RaidResolveUIController breakdown: defeat-boss bonus +
    damage bonus + gym-ownership bonus + team-contribution bonus."""
    tier = int(member.get("tier") or 3)
    r = random.Random(seed)
    share = min(1.0, damage / float(max(1, max_hp)))
    bonus = bonus or {}
    breakdown = {"boss": _s("catch_balls", int),
                 "damage": int(round(_s("catch_bonus_balls", int) * share)),
                 "gym": int(bonus.get("gym", 0)),
                 "team": int(bonus.get("team", 0))}
    balls = sum(breakdown.values())
    items = {ITEM_POKE_BALL: balls,
             ITEM_RAZZ: r.randint(1, 1 + tier // 2),
             ITEM_REVIVE: r.randint(1, 1 + tier // 2)}
    if r.random() < 0.5:
        items[ITEM_POTION] = r.randint(1, 3)
    return {"xp": _cfg.get("battles", "raid_xp", cast=int),
            "candy": int(_s("candy_base", int) + tier),
            "pokemon_id": int(member["pokemon_id"]),
            "items": {str(k): v for k, v in items.items()},
            "balls": balls, "ball_bonus": breakdown, "tier": tier}


def grant(user, reward):
    with _lock:
        PENDING.setdefault(user, []).append(reward)
        del PENDING[user][:-20]
    save()


def collect():
    """Pay the current trainer anything a raid left them (rpc.py, every request)."""
    import protocol as P
    user = world.current().username
    with _lock:
        got = PENDING.pop(user, None)
    if not got:
        return []
    for rw in got:
        if rw.get("xp"):
            world.add_xp(int(rw["xp"]))
        if rw.get("candy"):
            world.add_candy(P.pokemon_family(int(rw["pokemon_id"])), int(rw["candy"]))
        for item, n in (rw.get("items") or {}).items():
            world.add_item(int(item), int(n))
        world.bump("raid_won")
    save()
    return got


def on_felled(b, group, now_ms):
    """The boss's shared HP hit 0: reward everyone who did enough, and drop the boss
    at each of their feet to catch. Runs once per boss (raid_hit says who felled it)."""
    import protocol as P
    member = {"pokemon_id": b["def_pid"], "cp": b["def_cp"], "tier": b.get("tier"),
              "uid": b["defender"]}
    need = b["def_max"] * _s("min_damage_percent") / 100.0
    fort = b.get("gym") or ""
    holder = world.gym_holder_team(fort) if fort else 0
    teams = {u: world.team_of(u) for u in group}
    team_dmg = {1: 0, 2: 0, 3: 0}
    for u, dmg in group.items():
        if teams[u] in team_dmg:
            team_dmg[teams[u]] += dmg
    total = float(sum(team_dmg.values()) or 1)
    winners, by_user = [], {}
    for user, dmg in group.items():
        if dmg < need:
            continue
        seed = f"{b['defender']}:{user}:{now_ms}"
        t = teams[user]
        bonus = {"gym": _s("gym_control_balls", int) if t and t == holder else 0,
                 "team": int(round(_s("team_bonus_balls", int) * team_dmg.get(t, 0) / total))}
        rw = rewards_for(member, dmg, b["def_max"], seed, bonus)
        by_user[user] = rw
        grant(user, rw)
        import gymv2
        if gymv2.on() and fort:
            gymv2.badge_add(user, fort, gymv2._s("badge_raid"), "raids")
        cp = catch_cp(b["def_pid"], seed) if b.get("tier") else b["def_cp"]
        P._raid_drop(b, now_ms, user, cp=cp)
        winners.append(user)
    if fort:
        with _lock:
            RESULTS[fort] = {"at": now_ms, "teams": {str(k): v / total for k, v in team_dmg.items()},
                             "holder": holder, "by_user": by_user}
    return winners


RESULTS = {}     # fort -> the last beaten boss's resolve-screen data (memory only)


def results_for(fort, user):
    """0.71 RaidResolveUIController data for one trainer: team participation bars,
    their Premier-Ball breakdown, XP and items. None if they earned nothing."""
    with _lock:
        r = RESULTS.get(fort)
    if not r:
        return None
    return {"teams": r["teams"], "holder": r["holder"], "reward": r["by_user"].get(user)}


load()
