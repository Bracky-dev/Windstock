"""
The 0.71 gym RPCs (the 2017 "gym rework") on top of the server's existing gym rules.

0.71 stopped sending GET_GYM_DETAILS / FORT_DEPLOY_POKEMON / START_GYM_BATTLE /
ATTACK_GYM (134/110/135/136) and sends these instead:

  155 GYM_DEPLOY         GymDeployProto        -> GymDeployOutProto
  156 GYM_GET_INFO       GymGetInfoProto       -> GymGetInfoOutProto
  157 GYM_START_SESSION  GymStartSessionProto  -> GymStartSessionOutProto
  158 GYM_BATTLE_ATTACK  GymBattleAttackProto  -> GymBattleAttackOutProto
  164 GYM_FEED_POKEMON   GymFeedPokemonProto   -> GymFeedPokemonOutProto

Field numbers: work/newer-versions/protos-071.md in the old project (from 0.71's
dump.cs). The requests keep the 0.63 layouts, so the 0.63 parsers read them. The
replies are mostly the 0.63 messages re-wrapped:
  BattleProto       = StartGymBattleResponse fields 2..7, each one number lower
  BattleUpdateProto = AttackGymResponse      fields 2..5, each one number lower
What is new is the defender view: GymStatusAndDefenders { fort, GymDefender* } with
GymDefender { MotivatedPokemon, DeploymentTotals, trainer profile }.

Motivation (hearts) is worked out from the stored value and the time since it was
set (mot, mot_ms on the gym member), so nothing ticks in the background.
"""
import struct
import time

import pb
import protocol as P

SLOTS = 6                       # GymLevelSettings.trainerSlots after the rework
DECAY_PER_HOUR = 0.10           # community-measured, not in any client file
MIN_CP_FRACTION = 0.35          # a defender at 0 motivation fights at ~1/3 CP
DEFEAT_LOSS = 0.30              # motivation lost each time a defender is beaten
FEED_COOLDOWN_MS = 30_000
BERRY_MOTIVATION = {701: 0.25, 703: 0.3125, 705: 0.25, 706: 1.0}   # razz/nanab/pinap/golden
BERRY_STARDUST = 20


def _now():
    return int(time.time() * 1000)


# ------------------------------------------------------------------ wire helpers
def _varint(n):
    out = bytearray()
    n &= (1 << 64) - 1
    while n > 0x7F:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def _encode(fields):
    """Re-encode pb.decode() output (list of {field, wire, value})."""
    out = bytearray()
    for f in fields:
        num, wire, v = f["field"], f["wire"], f["value"]
        out += _varint((num << 3) | wire)
        if wire == pb.WT_VARINT:
            out += _varint(v)
        elif wire == pb.WT_64:
            out += struct.pack("<Q", v)
        elif wire == pb.WT_32:
            out += struct.pack("<I", v)
        else:
            out += _varint(len(v)) + v
    return bytes(out)


def _shift(fields, lo, hi, by=-1):
    """Fields numbered lo..hi, renumbered by `by`, others dropped."""
    return [dict(f, field=f["field"] + by) for f in fields if lo <= f["field"] <= hi]


# ------------------------------------------------------------------ motivation
# 0.71 polls GYM_GET_INFO every ~15 s and drops a battle in progress when the gym it
# gets back looks changed. So everything time-based moves in QUANT_MS steps, and the
# fort's lastModifiedMs only moves when something actually happens at the gym.
QUANT_MS = 30 * 60_000
_MODIFIED = {}                  # fort_id -> ms of the last deploy / battle / berry


def _q(now_ms):
    return now_ms - now_ms % QUANT_MS


def touch(fort_id, now_ms=None):
    _MODIFIED[fort_id] = _now() if now_ms is None else now_ms


def _modified(fort_id):
    import world
    t = _MODIFIED.get(fort_id, 0)
    for m in world.gym_members(fort_id, raid=False):
        t = max(t, int(m.get("deployed_ms") or 0), int(m.get("mot_ms") or 0), int(m.get("fed_ms") or 0))
    return t or 1_500_000_000_000


def motivation(m, now_ms=None):
    now = _q(_now() if now_ms is None else now_ms)
    base = float(m.get("mot", 1.0))
    since = int(m.get("mot_ms") or m.get("deployed_ms") or now)
    return max(0.0, min(1.0, base - DECAY_PER_HOUR * max(0.0, (now - since) / 3_600_000.0)))


def cp_full(m):
    return int(m.get("cp_full") or m.get("cp") or 10)


def cp_now(m, now_ms=None):
    f = MIN_CP_FRACTION + (1.0 - MIN_CP_FRACTION) * motivation(m, now_ms)
    return max(10, int(round(cp_full(m) * f)))


def _set_motivation(m, value, now_ms):
    m["cp_full"] = cp_full(m)
    m["mot"] = max(0.0, min(1.0, float(value)))
    m["mot_ms"] = int(now_ms)


# ------------------------------------------------------------------ messages
def _gym_display(fort_id, now_ms):
    """GymDisplayProto { totalGymCp=2, lowestPokemonMotivation=3, slotsAvailable=4,
    occupiedMillis=5 } -- the map tower's slot count and the gym screen's header."""
    import world
    ms = world.gym_members(fort_id, raid=False)
    w = pb.Writer()
    if ms:
        first = min(int(m.get("deployed_ms") or now_ms) for m in ms)
        (w.int_(2, sum(cp_now(m, now_ms) for m in ms))
          .double(3, min(motivation(m, now_ms) for m in ms))
          .int_(4, max(0, SLOTS - len(ms)))
          .int_(5, max(0, _q(now_ms) - first)))
    else:
        w.int_(4, SLOTS)
    return w.to_bytes()


def fort_bytes(fort_id, lat, lng, now_ms):
    """The 0.63 gym FortData plus the 0.71 gymDisplay (21)."""
    fort = [dict(f, value=_modified(fort_id)) if f["field"] == 2 else f
            for f in pb.decode(P.build_fort(fort_id, lat, lng, now_ms, is_gym=True))]
    return _encode(fort) + pb.Writer().message(21, _gym_display(fort_id, now_ms)).to_bytes()


def _defender(m, fort_id, now_ms):
    """GymDefenderProto { motivatedPokemon=1, deploymentTotals=2, trainerPublicProfile=3 }."""
    memb = pb.decode(P.build_gym_membership(m, fort_id))     # {1 pokemon, 2 profile}
    pokemon = pb.get(memb, 1, pb.WT_LEN) or b""
    profile = pb.get(memb, 2, pb.WT_LEN) or b""
    # The Pokemon's CP is today's (motivation) CP; cp_when_deployed keeps the full one.
    pokemon = _encode([f for f in pb.decode(pokemon) if f["field"] != 3]) + \
        pb.Writer().int_(3, cp_now(m, now_ms)).to_bytes()
    # Your own defender under your EXACT name: 0.63's invisible mark (to let a trainer
    # fill a gym) made 0.71 offer a second slot that GYM_DEPLOY then refused.
    prof = pb.decode(profile)
    for f in prof:
        if f["field"] == 1 and f["wire"] == pb.WT_LEN:
            f["value"] = f["value"].replace(P._OWN_DEFENDER_MARK.encode(), b"")
    profile = _encode(prof)
    team = int(m.get("team") or 0)
    if team:
        profile += pb.Writer().uint(4, team).to_bytes()
    deployed = int(m.get("deployed_ms") or now_ms)
    mot = (pb.Writer()
           .message(1, pokemon)
           .int_(2, deployed)
           .int_(3, cp_full(m))
           .double(4, motivation(m, now_ms))
           .int_(5, cp_now(m, now_ms))
           .float_(6, 0.25)
           .int_(7, FEED_COOLDOWN_MS))
    for item, inc in sorted(BERRY_MOTIVATION.items()):
        mot.message(8, pb.Writer().float_(1, inc).int_(2, max(1, int(cp_full(m) * inc * 0.5)))
                    .uint(3, item).to_bytes())
    totals = (pb.Writer()
              .int_(1, int(m.get("fed") or 0))
              .int_(2, int(m.get("won") or 0))
              .int_(3, int(m.get("lost") or 0))
              .int_(4, max(0, _q(now_ms) - deployed)))
    return (pb.Writer()
            .message(1, mot.to_bytes())
            .message(2, totals.to_bytes())
            .message(3, profile)
            .to_bytes())


def status_and_defenders(fort_id, now_ms, lat=None, lng=None):
    """GymStatusAndDefendersProto { pokemonFortProto=1, gymDefender=2 }."""
    import world
    if lat is None:
        lat, lng = P._GYM_POS.get(fort_id, (0.0, 0.0))
    w = pb.Writer().message(1, fort_bytes(fort_id, lat, lng, now_ms))
    for m in world.gym_members(fort_id, raid=False):
        w.message(2, _defender(m, fort_id, now_ms))
    return w.to_bytes()


# ------------------------------------------------------------------ 156 GYM_GET_INFO
def get_info(msg, here):
    """GymGetInfoProto { gymId=1, player lat/lng=2/3, gym lat/lng=4/5 } (same layout
    as 0.63's GetGymDetailsMessage) -> GymGetInfoOutProto { gymStatusAndDefenders=1,
    name=2, url=3, result=4 }."""
    import world
    import colortags
    fid, glat, glng = P.parse_gym_details(msg)
    now = _now()
    lat, lng = glat or here[0], glng or here[1]
    if lat or lng:
        P._GYM_POS[fid] = (lat, lng)
    name = P._PLACED_NAMES.get(fid) or P.GYM_NAMES[abs(hash(fid)) % len(P.GYM_NAMES)]
    return fid, (pb.Writer()
                 .message(1, status_and_defenders(fid, now, lat, lng))
                 .string(2, colortags.fort(name, True, world.gym_team(fid)))
                 .string(3, P._fort_image_url(fid))
                 .uint(4, 1)                                  # SUCCESS
                 .to_bytes())


# ------------------------------------------------------------------ 155 GYM_DEPLOY
def deploy(msg, here):
    """GymDeployProto { fortId=1, pokemonId=2, lat/lng=3/4 } -> GymDeployOutProto
    { result=1, gymStatusAndDefenders=2 }. Rework rules: 6 slots, one Pokemon per
    trainer per gym. Result codes match 0.63's FortDeployPokemon ones."""
    import world
    fid, uid = P.parse_deploy(msg)
    now = _now()
    me = world.current().username
    ms = world.gym_members(fid, raid=False)
    if len(ms) >= SLOTS:
        return fid, uid, 4, pb.Writer().uint(1, 4).to_bytes()          # ERROR_FORT_IS_FULL
    if any(m.get("owner") == me for m in ms):
        return fid, uid, 2, pb.Writer().uint(1, 2).to_bytes()          # ALREADY_HAS_POKEMON
    old = pb.decode(P.build_fort_deploy_response(fid, uid, here[0], here[1], now,
                                                 slots=SLOTS))
    res = pb.get(old, 1, pb.WT_VARINT) or 0
    if res != 1:
        return fid, uid, res, pb.Writer().uint(1, res).to_bytes()
    with world._lock:
        for m in world.GYMS.get(fid, []):
            if m["uid"] == uid:
                _set_motivation(m, 1.0, now)
                m["cp_full"] = int(m.get("cp") or 10)
    world.save_gyms()
    return fid, uid, 1, (pb.Writer()
                         .uint(1, 1)
                         .message(2, status_and_defenders(fid, now))
                         .to_bytes())


# ------------------------------------------------------------------ 157 GYM_START_SESSION
def start_session(old_response):
    """GymStartSessionOutProto { result=1, battle=2 }: the 0.63 StartGymBattleResponse
    with fields 2..7 moved into BattleProto (each one number lower)."""
    f = pb.decode(old_response)
    res = pb.get(f, 1, pb.WT_VARINT) or 0
    w = pb.Writer().uint(1, res)
    battle = _shift(f, 2, 7)
    if battle:
        w.message(2, _encode(battle))
    return w.to_bytes()


# ------------------------------------------------------------------ 158 GYM_BATTLE_ATTACK
def _with_gym_status(log_bytes, gym_id, now_ms, badge=None):
    """Give every BattleResults in the log 0.71's gymStatus (6), which the victory
    screen reads for the gym's new defenders and motivation, and the gym badge (10)."""
    out = []
    for f in pb.decode(log_bytes):
        if f["field"] == 4 and f["wire"] == pb.WT_LEN:              # battleActions
            act = pb.decode(f["value"])
            new = []
            for a in act:
                if a["field"] == 10 and a["wire"] == pb.WT_LEN:     # battleResults
                    r = [x for x in pb.decode(a["value"]) if x["field"] != 6]
                    r.append({"field": 6, "wire": pb.WT_LEN,
                              "value": status_and_defenders(gym_id, now_ms)})
                    if badge:
                        r = [x for x in r if x["field"] != 10]
                        r.append({"field": 10, "wire": pb.WT_LEN, "value": badge})
                    a = dict(a, value=_encode(r))
                new.append(a)
            f = dict(f, value=_encode(new))
        out.append(f)
    return _encode(out)


def battle_attack(old_response, gym_id, badge=None):
    """GymBattleAttackOutProto { result=1, battleUpdate=2, gymBadge=3 }: the 0.63
    AttackGymResponse fields 2..5 become BattleUpdateProto { battleLog=1, battleId=2,
    activeDefender=3, activeAttacker=4 }. `badge` (AwardedGymBadge) goes with a finished
    battle: the win screen's badge-progress toast reads it without a null check, and
    the error that threw ended the battle instead of showing Continue."""
    f = pb.decode(old_response)
    res = pb.get(f, 1, pb.WT_VARINT) or 0
    upd = _shift(f, 2, 5)
    for u in upd:
        if u["field"] == 1 and u["wire"] == pb.WT_LEN:
            u["value"] = _with_gym_status(u["value"], gym_id, _now(), badge)
    w = pb.Writer().uint(1, res)
    if upd:
        w.message(2, _encode(upd))
    if badge:
        w.message(3, badge)
    return w.to_bytes()


def on_defender_beaten(gym_id, uid, now_ms=None):
    """A defender lost a battle (called once, when it faints): it loses motivation,
    and one beaten with an empty heart goes home. The last one out leaves the gym
    neutral. Returns True if it left."""
    import world
    now = _now() if now_ms is None else now_ms
    left = False
    with world._lock:
        ms = world.GYMS.get(gym_id, [])
        for m in ms:
            if m["uid"] == uid:
                if motivation(m, now) <= 0.001:
                    ms.remove(m)
                    left = True
                else:
                    _set_motivation(m, motivation(m, now) - DEFEAT_LOSS, now)
                    m["lost"] = int(m.get("lost") or 0) + 1
                break
        if not ms:
            world.GYMS.pop(gym_id, None)
            world.PRESTIGE.pop(gym_id, None)
            # Rivals stay beaten for gyms.npc_respawn_minutes (as on 0.63): without
            # this the emptied gym had a fresh rival team on the very next look.
            if left:
                world.NPC_CLEARED[gym_id] = int(now)
    touch(gym_id, now)
    world.save_gyms()
    return left


# ------------------------------------------------------------------ 164 GYM_FEED_POKEMON
def parse_feed(msg):
    """GymFeedPokemonProto { item=1, startingQuantity=2, gymId=3, pokemonId=4 (fixed64) }."""
    f = pb.decode(msg)
    gid = pb.get(f, 3, pb.WT_LEN)
    pid = pb.get(f, 4, pb.WT_64) or pb.get(f, 4, pb.WT_VARINT) or 0
    return (pb.get(f, 1, pb.WT_VARINT) or 0,
            gid.decode("utf-8", "replace") if isinstance(gid, bytes) else "", pid)


BERRY_XP = 20


def feed(msg):
    """-> GymFeedPokemonOutProto { result=1, gymStatusAndDefenders=2, stardustAwarded=4,
    xpAwarded=5, cooldownComplete=8 }. Results: 1 SUCCESS, 4 POKEMON_NOT_THERE,
    5 POKEMON_FULL, 6 NO_BERRIES_LEFT, 7 WRONG_TEAM, 9 TOO_FAST."""
    import world
    item, gid, pid = parse_feed(msg)
    now = _now()
    with world._lock:
        m = next((m for m in world.GYMS.get(gid, []) if int(m["uid"]) == int(pid)), None)
    if m is None:
        return item, gid, pid, 4, pb.Writer().uint(1, 4).to_bytes()
    if int(m.get("team") or 0) != int(world.my_team() or 0):
        return item, gid, pid, 7, pb.Writer().uint(1, 7).to_bytes()
    # A full defender can still be fed (stardust + XP, motivation stays topped up):
    # refusing it read as "berries don't work" right after deploying.
    if now - int(m.get("fed_ms") or 0) < FEED_COOLDOWN_MS:
        return item, gid, pid, 9, pb.Writer().uint(1, 9).to_bytes()
    if not world.take_item(item, 1):
        return item, gid, pid, 6, pb.Writer().uint(1, 6).to_bytes()
    world.add_stardust(BERRY_STARDUST)
    world.add_xp(BERRY_XP)
    world.bump("berries_fed")                      # 0.71 Berry Master medal
    world.save()
    with world._lock:
        _set_motivation(m, motivation(m, now) + BERRY_MOTIVATION.get(item, 0.25), now)
        m["fed"] = int(m.get("fed") or 0) + 1
        m["fed_ms"] = now
    world.save_gyms()
    return item, gid, pid, 1, (pb.Writer()
                               .uint(1, 1)
                               .message(2, status_and_defenders(gid, now))
                               .int_(4, BERRY_STARDUST)
                               .int_(5, BERRY_XP)
                               .int_(8, now + FEED_COOLDOWN_MS)
                               .to_bytes())
