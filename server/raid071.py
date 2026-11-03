"""
Native 0.71 raids: raid eggs and bosses on gyms, the lobby, passes, the battle, the catch.

0.71 shows a raid from the gym's FortData.raidInfo (20) and drives it with
  163 GET_RAID_DETAILS      GetRaidDetailsProto     -> GetRaidDetailsOutProto
  159 JOIN_LOBBY            JoinLobbyProto          -> JoinLobbyOutProto      (uses a pass)
  162 SET_LOBBY_POKEMON     SetLobbyPokemonProto    -> SetLobbyPokemonOutProto
  161 SET_LOBBY_VISIBILITY  SetLobbyVisibilityProto -> SetLobbyVisibilityOutProto
  160 LEAVE_LOBBY           LeaveLobbyProto         -> LeaveLobbyOutProto
  165 START_RAID_BATTLE     StartRaidBattleProto    -> StartRaidBattleOutProto {result, BattleProto}
  166 ATTACK_RAID           AttackRaidBattleProto   -> AttackRaidBattleOutProto {result, BattleUpdateProto}
Field numbers: work/newer-versions/protos-071.md (old project), from 0.71's dump.cs.

Scheduling: every gym rolls once per WINDOW_MS, seeded by (gym, window), so every
trainer and every restart sees the same egg, tier and boss without storing anything.
raids071.json holds forced raids (force()). While the boss is out it IS the gym's
defender (world.RAID_HOOK), so the existing battle engine fights it with its shared
HP pool (world.raid_boss_state / raid_hit). The win's BattleResults get 0.71's raid
rewards and postRaidEncounter; the catch is the normal CATCH_POKEMON on the boss
spawn _raid_drop leaves, with Premier Balls granted for the throws.
"""
import json
import os
import random
import struct
import threading
import time

import pb
import protocol as P
import world

_lock = threading.RLock()
FILE = os.path.join(world.HERE, "raids071.json")

# mid-2017 numbers (work/newer-versions/RAIDS-GYMS-071.md)
TIERS = {1: {"hp": 600, "secs": 180}, 2: {"hp": 1800, "secs": 180},
         3: {"hp": 3000, "secs": 180}, 4: {"hp": 7500, "secs": 180},
         5: {"hp": 12500, "secs": 300}}
POOLS = {1: [129, 1, 4, 7], 2: [89, 103, 110, 125, 126],
         3: [59, 65, 68, 94, 134, 135, 136], 4: [3, 6, 9, 112, 131, 143],
         5: [144, 145, 146]}
# In battle a boss fights at a fixed CP multiplier per tier (2017), not one read from its CP
# 2017 boss HP was sized for a group (a tier 4 took 3-6 trainers); this server is mostly
# played alone, so the boss fights with a quarter of it. The CP shown stays the 2017 one.
SOLO_HP_SCALE = 0.25
# Helper trainers in every lobby (tier -> how many), and the damage each deals per second
BOTS = {1: 1, 2: 2, 3: 2, 4: 3, 5: 4}
BOT_DPS = 7
BOT_NAMES = ["AshKetch", "MistyWaves", "BrockSolid", "GaryOak42", "RedTrainer", "BlueRival",
             "LeafGreen", "ProfElm", "JennyOfficer", "NurseJoy7", "SurgeLt", "SabrinaPsy"]
BOT_TEAMS = [149, 143, 130, 134, 131, 68, 59, 65, 94, 103, 76, 112, 3, 9, 6, 135]
BOSS_CPM = {1: 0.6, 2: 0.67, 3: 0.7300, 4: 0.7900, 5: 0.7900}
TIER_WEIGHTS = [(1, 30), (2, 25), (3, 25), (4, 15), (5, 5)]
WINDOW_MS = 3 * 3_600_000
EGG_MS = 60 * 60_000           # egg on the gym before it hatches
BATTLE_MS = 45 * 60_000        # boss stays this long
CHANCE = 0.30                  # share of gyms with a raid per window
LOBBY_MS = 30_000              # lobby countdown (2017: 120 s; short for solo play)
MIN_LEVEL = 5
ITEM_PREMIER_BALL, ITEM_FREE_PASS, ITEM_PAID_PASS = 5, 1401, 1402
BASE_THROWS = 6

FORCED = {}                    # fort_id -> raid dict
ALL = {"on": False, "pokemon_id": 150, "tier": 5}   # World Manager "Raid: ON": a standing raid in EVERY gym
LOBBIES = {}                   # (username, fort_id, seed) -> lobby dict
DONE = {}                      # (username, seed) -> {"throws": n, "rewards": bool}
_FREE_PASS_DAY = {}            # username -> "YYYY-MM-DD"


def _now():
    return int(time.time() * 1000)


def _user():
    return world.current().username


# ------------------------------------------------------------------ schedule
def load():
    try:
        with open(FILE, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return
    with _lock:
        FORCED.clear()
        FORCED.update({k: v for k, v in (d.get("forced") or {}).items() if isinstance(v, dict)})
        if isinstance(d.get("all"), dict):
            ALL.update(d["all"])


def _save():
    try:
        with open(FILE + ".tmp", "w", encoding="utf-8") as fh:
            json.dump({"forced": FORCED, "all": ALL}, fh, indent=1)
        os.replace(FILE + ".tmp", FILE)
    except OSError:
        pass


def _make(fort_id, seed, tier, pokemon_id, spawn_ms):
    return {"fort": fort_id, "seed": int(seed), "tier": int(tier), "pokemon_id": int(pokemon_id),
            "spawn": int(spawn_ms), "battle": int(spawn_ms) + EGG_MS,
            "end": int(spawn_ms) + EGG_MS + BATTLE_MS}


def _roll(fort_id, window):
    rnd = random.Random(f"raid071:{fort_id}:{window}")
    if rnd.random() >= CHANCE:
        return None
    tier = rnd.choices([t for t, _ in TIER_WEIGHTS], [w for _, w in TIER_WEIGHTS])[0]
    pid = rnd.choice(POOLS[tier])
    spawn = window * WINDOW_MS + rnd.randint(0, WINDOW_MS - EGG_MS - BATTLE_MS)
    seed = rnd.getrandbits(62) | 1
    return _make(fort_id, seed, tier, pid, spawn)


def raid_at(fort_id, now_ms=None):
    """The raid on a gym right now (egg or boss), or None."""
    now = _now() if now_ms is None else now_ms
    with _lock:
        f = FORCED.get(fort_id)
    if f and f["spawn"] <= now < f["end"]:
        return f
    if ALL["on"]:
        block = now // BATTLE_MS               # hatched already; a fresh boss every 45 min
        battle = block * BATTLE_MS
        seed = random.Random(f"raidall:{fort_id}:{block}").getrandbits(62) | 1
        return _make(fort_id, seed, ALL["tier"], ALL["pokemon_id"], battle - EGG_MS)
    w = now // WINDOW_MS
    for win in (w, w - 1):
        r = _roll(fort_id, win)
        if r and r["spawn"] <= now < r["end"]:
            return r
    return None


def force(fort_id, tier=None, pokemon_id=None, hatch_now=True, now_ms=None):
    """Start a raid on a gym (admin / testing). Returns it."""
    now = _now() if now_ms is None else now_ms
    tier = int(tier or 3)
    pid = int(pokemon_id or random.choice(POOLS[tier]))
    spawn = now - EGG_MS if hatch_now else now
    r = _make(fort_id, random.getrandbits(62) | 1, tier, pid, spawn)
    with _lock:
        FORCED[fort_id] = r
        _save()
    return r


def set_all(on, pokemon_id=None):
    """Raid mode: one boss (the given species) hatched in every gym, or off again."""
    with _lock:
        if pokemon_id:
            pid = int(pokemon_id)
            ALL["pokemon_id"] = pid
            ALL["tier"] = next((t for t, pool in sorted(POOLS.items(), reverse=True)
                                if pid in pool), 5)
        ALL["on"] = bool(on)
        if not on:
            FORCED.clear()
        _save()
    return dict(ALL)


def hatched(r, now_ms=None):
    return r is not None and (_now() if now_ms is None else now_ms) >= r["battle"]


# ------------------------------------------------------------------ the boss
def boss_cp(pokemon_id, tier):
    """Raid boss CP: (atk+15) * sqrt(def+15) * sqrt(tier HP) / 10, as in 2017."""
    gd = getattr(P, "_gd", None)
    stats = getattr(gd, "STATS", {}) if gd else {}
    if pokemon_id in stats:
        a, d, _s = stats[pokemon_id]
        return int((a + 15) * (d + 15) ** 0.5 * TIERS[tier]["hp"] ** 0.5 / 10)
    return 1000 * tier


def boss_member(fort_id, now_ms=None):
    """The gym's defender list while a boss is out (world.RAID_HOOK)."""
    r = raid_at(fort_id, now_ms)
    if not hatched(r, now_ms):
        return None
    uid = (r["seed"] & 0x3FFFFFFFFFFFFFFF) | 1
    P.BOSS_CPM[uid] = BOSS_CPM.get(r["tier"], 0.79)
    return {"uid": uid, "pokemon_id": r["pokemon_id"],
            "cp": boss_cp(r["pokemon_id"], r["tier"]), "trainer": "raid", "team": 0,
            "raid": True, "raid_hp": max(1, int(TIERS[r["tier"]]["hp"] * SOLO_HP_SCALE)),
            "deployed_ms": r["battle"]}


def raid_info(r, now_ms=None):
    """RaidInfoProto { raidSeed=1, raidSpawnMs=2, raidBattleMs=3, raidEndMs=4,
    raidPokemon=5 (only once hatched), raidLevel=6, complete=7 }."""
    w = (pb.Writer().int_(1, r["seed"]).int_(2, r["spawn"]).int_(3, r["battle"])
         .int_(4, r["end"]))
    if hatched(r, now_ms):
        m = boss_member(r["fort"], now_ms)
        w.message(5, P.build_pokemon_data(m["pokemon_id"], m["uid"], m["cp"],
                                          extra={"stamina_max": m["raid_hp"]}))
    w.uint(6, r["tier"])
    if (_user(), r["seed"]) in DONE:
        w.bool_(7, True)
    return w.to_bytes()


def fort_raid_bytes(fort_id, now_ms):
    """FortData.raidInfo (20) for build_fort, or b''."""
    r = raid_at(fort_id, now_ms)
    return raid_info(r, now_ms) if r else b""


# ------------------------------------------------------------------ passes
def _today():
    return time.strftime("%Y-%m-%d", time.gmtime())


def daily_pass():
    """One free Raid Pass a day (2017: from spinning a gym; 0.71's gyms here can't
    be spun, so it is simply handed out). Returns True if one was given."""
    u = _user()
    if _FREE_PASS_DAY.get(u) == _today():
        return False
    _FREE_PASS_DAY[u] = _today()
    if dict(world.bag_items()).get(ITEM_FREE_PASS, 0) >= 1:
        return False
    world.add_item(ITEM_FREE_PASS, 1)
    return True


def _use_pass():
    return world.take_item(ITEM_FREE_PASS, 1) or world.take_item(ITEM_PAID_PASS, 1)


# ------------------------------------------------------------------ parsing
def _str(f, n):
    v = pb.get(f, n, pb.WT_LEN)
    return v.decode("utf-8", "replace") if isinstance(v, bytes) else ""


def _ints(f, n, fixed=False):
    out = []
    for v in pb.get_all(f, n):
        if isinstance(v, int):
            out.append(v)
        elif isinstance(v, bytes):                     # packed
            if fixed:
                out += [struct.unpack_from("<Q", v, i)[0] for i in range(0, len(v) - 7, 8)]
            else:
                i = 0
                while i < len(v):
                    n_, s = 0, 0
                    while True:
                        b = v[i]; i += 1
                        n_ |= (b & 0x7F) << s; s += 7
                        if b < 0x80:
                            break
                    out.append(n_)
    return out


def _ids(f, n):
    """Pokemon ids (ulong): fixed64 or varint, packed or not."""
    vals = []
    for v in pb.get_all(f, n):
        if isinstance(v, int):
            vals.append(v)
        elif isinstance(v, bytes) and len(v) % 8 == 0:
            vals += [struct.unpack_from("<Q", v, i)[0] for i in range(0, len(v), 8)]
        elif isinstance(v, bytes):
            vals += _ints([{"field": n, "wire": pb.WT_LEN, "value": v}], n)
    return vals


def parse(msg, gym_field=2, seed_field=1):
    f = pb.decode(msg)
    return f, _str(f, gym_field), pb.get(f, seed_field, pb.WT_VARINT) or 0


# ------------------------------------------------------------------ lobby
def _lobby_key(fort_id, seed):
    return (_user(), fort_id, int(seed))


def _participant(lobby):
    lvl, _xp = world.stats()
    # without the avatar (3) the lobby screen fails before it draws anything: no
    # trainer, no boss name/CP (placeholder "Hitmonchan 9999"), no party, no timer
    prof = (pb.Writer().string(1, P.player_name(_user())).int_(2, lvl)
            .message(3, P.build_player_avatar())
            .uint(4, int(world.my_team() or 0)).to_bytes())
    w = pb.Writer().message(2, prof)
    for uid in lobby.get("team", []):
        c = world.get_caught(uid)
        if not c:
            continue
        hmax = P._hp_for(c["cp"], c["pokemon_id"], c["uid"])
        w.message(5, pb.Writer().int_(1, uid & 0x7FFFFFFFFFFFFFFF).uint(2, c["pokemon_id"])
                  .int_(3, c["cp"]).float_(4, min(1.0, P.current_hp(c) / max(1, hmax)))
                  .to_bytes())
    return w.to_bytes()


def _bots(lobby):
    """The lobby's helper trainers, made once per lobby."""
    if "bots" not in lobby:
        rnd = random.Random(lobby["seed"] ^ lobby["created"])
        tier = (raid_at(lobby["fort"]) or {}).get("tier", 3)
        lobby["bots"] = [{"name": n, "level": rnd.randint(22, 34), "team": rnd.randint(1, 3),
                          "mons": [(rnd.getrandbits(62) | 1, pid, rnd.randint(1500, 2600))
                                   for pid in rnd.sample(BOT_TEAMS, 6)]}
                         for n in rnd.sample(BOT_NAMES, BOTS.get(tier, 2))]
    return lobby["bots"]


def _bot_participant(bot):
    prof = (pb.Writer().string(1, bot["name"]).int_(2, bot["level"])
            .message(3, P.build_player_avatar({}))      # {} = the stock look
            .uint(4, bot["team"]).to_bytes())
    w = pb.Writer().message(2, prof)
    for uid, pid, cp in bot["mons"]:
        w.message(5, pb.Writer().int_(1, uid).uint(2, pid).int_(3, cp).float_(4, 1.0).to_bytes())
    return w.to_bytes()


def bot_actions(b, gid, now):
    """The helpers' part of this battle beat, as BattleActionProto bytes: on the first beat
    each one JOINS (PLAYER_JOIN with its BattleParticipant -- that is what the client counts
    as a player and draws), then each throws its quick move over the next couple of seconds
    (damage only -- see below). The damage is banked in the boss's shared HP now; they
    never land the last blow, so the trainer's hit finishes it and earns the catch."""
    lb = next((l for l in LOBBIES.values() if l.get("battle_id") == b.get("bid")), None)
    bots = lb.get("bots") if lb else None
    if not bots:
        return []
    out = []
    boss_cpm = BOSS_CPM.get(int(b["raid071"].get("tier") or 3))
    # PLAYER_JOIN is not sent either: a joined player's Pokemon never gets a model on
    # this client, and its FX then throw every frame (SpawnPokemonAttackFx), which jams
    # the battle -- the boss never faints on screen. They stay in the lobby list.
    if not b.get("bots_joined"):
        b["bots_joined"] = True
        b["bots_next"] = now + 1500
    if False:
        b["bots_next"] = now + 1500
        for i, bot in enumerate(bots, 1):
            uid, pid, cp = bot["mons"][0]
            hp = P._hp_for(cp, pid, uid)
            reserve = [P._battle_pokemon_info(p2, u2, c2, P._hp_for(c2, p2, u2),
                                              hp_max=P._hp_for(c2, p2, u2))
                       for u2, p2, c2 in bot["mons"][1:]]
            who = P._battle_participant(pid, uid, cp, hp, bot["name"], bot["level"],
                                        hp_max=hp, reserve=reserve, avatar={})
            out.append(pb.Writer().uint(1, 6).int_(2, now).int_(3, 0).int_(6, i).int_(7, -1)
                       .fixed64(8, uid).message(9, who).to_bytes())
    s = world.raid_boss_state(gid, b["def_max"], now,
                              key=(b["defender"], b["def_cp"], b["def_max"]))
    room = max(0, s["hp"] - 1)
    until = now + 2500                        # up to the client's next beat
    t0 = max(now, int(b.get("bots_next") or now))
    nxt = t0
    for i, bot in enumerate(bots, 1):
        uid, pid, cp = bot["mons"][0]
        quick, _charged = P.moves_for(pid, uid)
        dur, dws, dwe, _e = P.move_timing(quick, 1000)
        dmg = P._battle_damage(pid, uid, cp, b["def_pid"], b["defender"], b["def_cp"], quick,
                               P.pokemon_types(pid), P.pokemon_types(b["def_pid"]),
                               def_cpm=boss_cpm) or 5
        t = t0 + i * 137                      # don't all swing on the same frame
        while t + dur <= until:
            # Their swings are NOT put in the log: the client never loads a joined
            # player's model, and an ATTACK from one throws in SpawnPokemonAttackFx every
            # frame, which jams the battle sequence (the boss faints, nothing follows).
            # The bar shows their damage anyway, through the boss's synced HP.
            d = min(room, dmg)
            if d > 0:
                world.raid_hit(gid, bot["name"], d, now, 0)
                room -= d
            t += dur + 150
        nxt = max(nxt, t)
    b["bots_next"] = nxt
    return out


def _add_actions(update_bytes, actions):
    """BattleUpdate.battleLog(1).battleActions(4) += actions."""
    from gym071 import _encode
    upd = []
    for f in pb.decode(update_bytes):
        if f["field"] == 1 and f["wire"] == pb.WT_LEN:
            log = pb.decode(f["value"]) + [{"field": 4, "wire": pb.WT_LEN, "value": a} for a in actions]
            f = dict(f, value=_encode(log))
        upd.append(f)
    return _encode(upd)


def lobby_bytes(lobby):
    """LobbyProto { lobbyId=1*, players=2*, playerJoinEndMs=3, pokemonSelectionEndMs=4,
    raidBattleStartMs=5, raidBattleEndMs=6, raidBattleId=8, ownerNickname=9,
    private=10, creationMs=11 }."""
    w = pb.Writer()
    for i in lobby["id"]:
        w.int_(1, i)
    w.message(2, _participant(lobby))
    for bot in _bots(lobby):
        w.message(2, _bot_participant(bot))
    (w.int_(3, lobby["join_end"]).int_(4, lobby["join_end"])
      .int_(5, lobby["battle_start"]).int_(6, lobby["battle_end"]))
    if lobby.get("battle_id"):
        w.string(8, lobby["battle_id"])
    w.string(9, P.player_name(_user())).bool_(10, bool(lobby.get("private")))
    w.int_(11, lobby["created"])
    return w.to_bytes()


def _default_team():
    """The six strongest healthy Pokemon, until the trainer picks (SET_LOBBY_POKEMON)."""
    mine = [c for c in world.caught() if P.current_hp(c) > 0 and not world.is_deployed(c["uid"])]
    return [c["uid"] for c in sorted(mine, key=lambda c: -c["cp"])[:6]]


def _lobby(fort_id, seed):
    with _lock:
        return LOBBIES.get(_lobby_key(fort_id, seed))


def _new_lobby(r, now):
    # lobbyId doubles as the private group code: each entry indexes RaidState's
    # groupCodePokemon icon list, so a big random int threw IndexOutOfRange in
    # RaidLobbyGuiController.Init (no boss, no party, no battle start)
    lb = {"id": [random.randint(0, 2) for _ in range(3)], "created": now,
          "join_end": now + LOBBY_MS, "battle_start": now + LOBBY_MS,
          "battle_end": now + LOBBY_MS + TIERS[r["tier"]]["secs"] * 1000,
          "team": [], "fort": r["fort"], "seed": r["seed"]}
    with _lock:
        LOBBIES[_lobby_key(r["fort"], r["seed"])] = lb
    return lb


def _raid_for(fort_id, seed, now):
    r = raid_at(fort_id, now)
    if r and (not seed or r["seed"] == seed):
        return r
    return None


def _in_range(msg_f, lat_field, r):
    return True                                   # the client checks distance itself


# ------------------------------------------------------------------ 163 GET_RAID_DETAILS
def get_details(msg):
    """-> GetRaidDetailsOutProto { lobby=1, raidBattle=2, playerCanJoinLobby=3,
    result=4, raidInfo=5, ticketUsed=6, freeTicketAvailable=7, throwsRemaining=8,
    receivedRewards=9, numPlayersInLobby=10 }."""
    f, gid, seed = parse(msg)
    now = _now()
    r = _raid_for(gid, seed, now)
    if not r:
        return gid, 4, pb.Writer().uint(4, 4).to_bytes()          # RAID_UNAVAILABLE
    lvl, _xp = world.stats()
    if lvl < MIN_LEVEL:
        return gid, 5, pb.Writer().uint(4, 5).message(5, raid_info(r, now)).to_bytes()
    daily_pass()
    lb = _lobby(gid, r["seed"])
    done = DONE.get((_user(), r["seed"]))
    w = pb.Writer()
    if lb:
        w.message(1, lobby_bytes(lb))
    w.bool_(3, hatched(r, now) and not done).uint(4, 1).message(5, raid_info(r, now))
    w.bool_(6, bool(lb))
    w.bool_(7, False)
    if done:
        w.int_(8, done["throws"]).bool_(9, done["rewards"])
    w.int_(10, 1 if lb else 0)
    return gid, 1, w.to_bytes()


# ------------------------------------------------------------------ 159 JOIN_LOBBY
def join(msg):
    """JoinLobbyProto { raidSeed=1, gymId=2, lobbyId=3*, private=4, lat=5, lng=6 }
    -> JoinLobbyOutProto { result=1, lobby=2 }. Results: 1 SUCCESS, 3 RAID_UNAVAILABLE,
    4 RAID_COMPLETED, 6 BELOW_MINIMUM_LEVEL, 9 NO_TICKET."""
    f, gid, seed = parse(msg)
    now = _now()
    r = _raid_for(gid, seed, now)
    if not r or not hatched(r, now):
        return gid, 3, pb.Writer().uint(1, 3).to_bytes()
    if (_user(), r["seed"]) in DONE:
        return gid, 4, pb.Writer().uint(1, 4).to_bytes()
    lvl, _xp = world.stats()
    if lvl < MIN_LEVEL:
        return gid, 6, pb.Writer().uint(1, 6).to_bytes()
    lb = _lobby(gid, r["seed"])
    if lb is None or now > lb["battle_end"]:
        # a lobby whose battle never started already paid for this raid
        paid = lb is not None and not lb.get("battle_id")
        if not paid and not _use_pass():
            return gid, 9, pb.Writer().uint(1, 9).to_bytes()
        lb = _new_lobby(r, now)
        lb["private"] = bool(pb.get(f, 4, pb.WT_VARINT))
        lb["team"] = _default_team()
    return gid, 1, pb.Writer().uint(1, 1).message(2, lobby_bytes(lb)).to_bytes()


# ------------------------------------------------------------------ 160/161/162
def leave(msg):
    """LeaveLobbyOutProto { result=1, lobby=2 }: 1 SUCCESS, 3 LOBBY_NOT_FOUND. Leaving
    before the battle starts gives the pass back."""
    f, gid, seed = parse(msg)
    with _lock:
        key = next((k for k in LOBBIES if k[0] == _user() and k[1] == gid
                    and (not seed or k[2] == seed)), None)
        lb = LOBBIES.pop(key, None) if key else None
    if not lb:
        return gid, 3, pb.Writer().uint(1, 3).to_bytes()
    if _now() < lb["battle_start"] and not lb.get("battle_id"):
        world.add_item(ITEM_FREE_PASS, 1)
    return gid, 1, pb.Writer().uint(1, 1).message(2, lobby_bytes(lb)).to_bytes()


def set_visibility(msg):
    f, gid, seed = parse(msg)
    lb = _lobby(gid, seed) if seed else None
    if not lb:
        return gid, 3, pb.Writer().uint(1, 3).to_bytes()
    lb["private"] = False
    return gid, 1, pb.Writer().uint(1, 1).message(2, lobby_bytes(lb)).to_bytes()


def set_pokemon(msg):
    """SetLobbyPokemonProto { raidSeed=1, gymId=2, lobbyId=3*, pokemonId=4* }
    -> { result=1, lobby=2 }: 1 SUCCESS, 2 LOBBY_NOT_FOUND, 4 INVALID_POKEMON."""
    f, gid, seed = parse(msg)
    lb = _lobby(gid, seed)
    if not lb:
        return gid, 2, pb.Writer().uint(1, 2).to_bytes()
    ids = [u for u in _ids(f, 4) if world.get_caught(u)]
    if not ids:
        return gid, 4, pb.Writer().uint(1, 4).to_bytes()
    lb["team"] = ids[:6]
    return gid, 1, pb.Writer().uint(1, 1).message(2, lobby_bytes(lb)).to_bytes()


# ------------------------------------------------------------------ 165 START_RAID_BATTLE
_START_RESULT = {1: 1, 3: 3, 5: 4, 8: 5, 13: 7}


def _begin(gid, r, lb, team, now):
    """Start the lobby's battle: -> (StartRaidBattle result, BattleProto bytes or None)."""
    import gym071
    boss = boss_member(gid, now)
    old = P.build_start_gym_battle_response(gid, team, boss["uid"], now, v071=True)
    out = gym071.start_session(old)
    o = pb.decode(out)
    res = _START_RESULT.get(pb.get(o, 1, pb.WT_VARINT) or 0, 3)
    battle = pb.get(o, 2, pb.WT_LEN)
    if res == 1 and isinstance(battle, bytes):
        lb["battle_id"] = pb.get(pb.decode(battle), 3, pb.WT_LEN).decode()
        b = world.BATTLES.get(lb["battle_id"])
        if b is not None:
            b["raid071"] = {"seed": r["seed"], "tier": r["tier"], "fort": gid}
            b["bid"] = lb["battle_id"]
            b["catch_cp"] = _catch_cp(b, r)
        return res, battle
    return res, None


def start_battle(msg):
    """StartRaidBattleProto { gymId=1, raidSeed=2, lobbyId=4*, attackingPokemonId=5*,
    lat=6, lng=7 } -> StartRaidBattleOutProto { result=1, battle=2 } (BattleProto,
    same as GYM_START_SESSION's)."""
    f = pb.decode(msg)
    gid, seed = _str(f, 1), pb.get(f, 2, pb.WT_VARINT) or 0
    now = _now()
    r = _raid_for(gid, seed, now)
    if not r or not hatched(r, now):
        return gid, 3, pb.Writer().uint(1, 3).to_bytes()
    lb = _lobby(gid, r["seed"])
    if not lb:
        return gid, 9, pb.Writer().uint(1, 9).to_bytes()            # LOBBY_NOT_FOUND
    team = [u for u in _ids(f, 5) if world.get_caught(u)] or lb.get("team") or []
    res, battle = _begin(gid, r, lb, team, now)
    w = pb.Writer().uint(1, res)
    if res == 1:
        w.message(2, battle)
    return gid, res, w.to_bytes()


# ------------------------------------------------------------------ 166 ATTACK_RAID
def _loot(items):
    w = pb.Writer()
    for item, n in items:
        if item == "stardust":
            w.message(1, pb.Writer().int_(2, n).int_(5, n).to_bytes())
        else:
            w.message(1, pb.Writer().uint(1, item).int_(5, n).to_bytes())
    return w.to_bytes()


def _rewards(tier):
    rnd = random.Random()
    items = [(201, rnd.randint(1, 2) + tier // 2),          # Revive
             (701, rnd.randint(1, 3)),                       # Razz Berry
             (103, rnd.randint(1, 2) + tier // 3)]           # Hyper Potion
    return items, [("stardust", 1000 + 500 * tier)]


def _encounter(b, r, eid, throws):
    """RaidEncounterProto { pokemon=1, encounterId=2, spawnpointId=3,
    captureProbabilities=4, throwsRemaining=5, raidLevel=6, fortId=7 }."""
    pokemon = P.build_pokemon_data(b["def_pid"], eid, min(b["def_cp"], _catch_cp(b, r)))
    cap = (pb.Writer().uint(1, ITEM_PREMIER_BALL)
           .float_(2, max(0.02, 0.15 - 0.02 * r["tier"])).double(12, 1.0).to_bytes())
    sp = world.get_spawn(eid) or {}
    return (pb.Writer().message(1, pokemon).uint(2, eid)
            .string(3, str(sp.get("spawn_id") or r["fort"]))
            .message(4, cap).int_(5, throws).uint(6, r["tier"]).string(7, r["fort"])
            .to_bytes())


def _catch_cp(b, r):
    """The catchable boss: level 20 with good IVs, i.e. far below the boss's CP."""
    return max(10, int(b["def_cp"] * 0.06 * (1 + 0.1 * r["tier"])))


def _raid_results(b, now_ms):
    """Rewards + postRaidEncounter for a won raid, once per trainer and raid."""
    meta = b["raid071"]
    key = (_user(), meta["seed"])
    if key in DONE:
        return None
    r = {"fort": meta["fort"], "seed": meta["seed"], "tier": meta["tier"]}
    throws = BASE_THROWS + (2 if world.gym_team(meta["fort"]) == world.my_team() else 0)
    items, dust = _rewards(meta["tier"])
    for item, n in items:
        world.add_item(item, n)
    world.add_stardust(dust[0][1])
    # Premier Balls belong to this one catch: the bag holds exactly its throws (adding
    # them up raid after raid showed 114 next to the 6 the encounter really has)
    have = dict(world.bag_items(include_empty=True)).get(ITEM_PREMIER_BALL, 0)
    world.add_item(ITEM_PREMIER_BALL, throws - have)
    eid = b.get("raid_eid") or P._raid_drop(b, now_ms)
    DONE[key] = {"throws": throws, "rewards": True}
    # ParticipationProto: RaidResolveUIController.Init reads attackers' entry
    # [localPlayerIndex] for the Premier Ball breakdown -- without it, it throws and the
    # victory screen never gets past the catch preview.
    mine = world.my_team() or 1
    team_pct = {1: 0.0, 2: 0.0, 3: 0.0}
    team_pct[mine] = 1.0
    part = (pb.Writer().int_(1, 1).int_(2, 0).int_(3, throws - BASE_THROWS).int_(4, BASE_THROWS - 1)
            .double(5, team_pct[1]).double(6, team_pct[2]).double(7, team_pct[3])
            .float_(8, 1.0).to_bytes())
    import extras071
    extras071.badge_score(meta["fort"], extras071.SCORE_RAID, won=1)
    out = [{"field": 7, "wire": pb.WT_LEN, "value": part},
           {"field": 10, "wire": pb.WT_LEN, "value": extras071.awarded_badge_bytes(meta["fort"])},
           {"field": 8, "wire": pb.WT_LEN, "value": _loot(items)},
           {"field": 11, "wire": pb.WT_LEN, "value": _loot(dust)}]
    if eid:
        out.append({"field": 9, "wire": pb.WT_LEN, "value": _encounter(b, r, eid, throws)})
    return out


def attack(msg):
    """AttackRaidBattleProto { gymId=1, battleId=2, attackerActions=3*,
    lastRetrievedAction=4, timestampMs=5 } (the 0.63 AttackGym layout up to 4)
    -> AttackRaidBattleOutProto { result=1, battleUpdate=2 }."""
    import gym071
    gid, bid, actions, last_seen = P.parse_attack_gym(msg)
    now = _now()
    b = world.BATTLES.get(bid)
    helpers = bot_actions(b, gid, now) if b and b.get("raid071") else []
    old = P.build_attack_gym_response(gid, bid, actions, now, last_seen)
    out = pb.decode(gym071.battle_attack(old, gid))
    upd = pb.get(out, 2, pb.WT_LEN)
    lg = pb.decode(pb.get(pb.decode(old), 2, pb.WT_LEN) or b"")
    state = pb.get(lg, 1, pb.WT_VARINT)
    if b and b.get("raid071") and state == 2 and isinstance(upd, bytes):
        extra = _raid_results(b, now)
        if extra:
            upd = _add_to_results(upd, extra)
    if helpers and state == 1 and isinstance(upd, bytes):
        upd = _add_actions(upd, helpers)
    if b and b.get("raid071"):
        print(f"       raid: boss {b.get('def_hp')}/{b.get('def_max')} hp, "
              f"{len(helpers)} helper action(s)", flush=True)
    w = pb.Writer().uint(1, pb.get(out, 1, pb.WT_VARINT) or 1)
    if isinstance(upd, bytes):
        w.message(2, upd)
    return gid, state, w.to_bytes()


def _add_to_results(update_bytes, extra):
    """BattleUpdate.battleLog(1).battleActions(4).battleResults(10) += extra fields."""
    from gym071 import _encode
    upd = []
    for f in pb.decode(update_bytes):
        if f["field"] == 1 and f["wire"] == pb.WT_LEN:
            log = []
            for lf in pb.decode(f["value"]):
                if lf["field"] == 4 and lf["wire"] == pb.WT_LEN:
                    act = []
                    for a in pb.decode(lf["value"]):
                        if a["field"] == 10 and a["wire"] == pb.WT_LEN:
                            res = [x for x in pb.decode(a["value"]) if x["field"] != 6]
                            a = dict(a, value=_encode(res + extra))
                        act.append(a)
                    lf = dict(lf, value=_encode(act))
                log.append(lf)
            f = dict(f, value=_encode(log))
        upd.append(f)
    return _encode(upd)


load()
world.RAID_HOOK = boss_member
