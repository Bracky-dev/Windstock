"""
extras071.py -- the 0.71 requests the 0.29-0.63 server never had to answer.

Message layouts are 0.71's own (from its dump.cs; research/protos-071 + the August 2017
game master). Everything here runs as the current trainer (world.current()); per-trainer
state lives in the save's "v071" dict:

    buddy        {"uid", "pokemon_id", "start_km", "last_km"}
    gym_badges   {fort_id: {"points", "won", "lost", "fed", "deploys", "defended_ms", "updated"}}
    viewed       [avatar template ids the trainer has looked at]

  8   REGISTER_BACKGROUND_DEVICE   152 SET_BUDDY_POKEMON        153 GET_BUDDY_WALKED
  154 USE_ITEM_ENCOUNTER (berries) 601 VERIFY_CHALLENGE         807 LIST_AVATAR_CUSTOMIZATIONS
  808 SET_AVATAR_ITEM_AS_VIEWED    809 GET_INBOX                811 LIST_GYM_BADGES
  812 GET_GYM_BADGE_DETAILS        813 USE_ITEM_MOVE_REROLL     814 USE_ITEM_RARE_CANDY
  815 AWARD_FREE_RAID_TICKET
(800-806 SFIDA_* are GO Plus calls from its native plugin; 0.71's C# has no messages for
them, so they keep the empty answer.)
"""
import hashlib
import os
import time

import pb
import protocol as P
import world

GM_071 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "game_master_071.bin")

# GYM_BADGE_SETTINGS, August 2017
BADGE_TARGETS = (500, 4000, 30000)          # bronze, silver, gold
SCORE_BATTLE_PER_CP = 0.01
SCORE_FEED = 10
SCORE_DEPLOY = 100
SCORE_RAID = 1000

ITEM_RAZZ, ITEM_NANAB, ITEM_PINAP = 701, 703, 705
ITEM_GOLDEN_RAZZ, ITEM_GOLDEN_NANAB, ITEM_GOLDEN_PINAP = 706, 707, 708
BERRY_CAPTURE = {ITEM_RAZZ: 1.5, ITEM_GOLDEN_RAZZ: 2.5, ITEM_NANAB: 1.0, ITEM_PINAP: 1.0,
                 ITEM_GOLDEN_NANAB: 1.0, ITEM_GOLDEN_PINAP: 1.0}
ITEM_TM_FAST, ITEM_TM_CHARGED, ITEM_RARE_CANDY = 1201, 1202, 1301
ITEM_FREE_RAID_TICKET = 1401


def _now():
    return int(time.time() * 1000)


def _state():
    return world.current().V071


def _save():
    world.current().save()


def _gm():
    """{pokemon_id: km_buddy_distance}, [(template_id, avatarCustomization dict)] from the
    0.71 game master (read once)."""
    if _gm.cache is None:
        buddy, avatars = {}, []
        try:
            d = pb.decode(open(GM_071, "rb").read())
        except OSError:
            d = []
        for t in pb.get_all(d, 2) or []:
            f = pb.decode(t)
            tid = (pb.get(f, 1, pb.WT_LEN) or b"").decode("utf-8", "replace")
            ps = pb.get(f, 2, pb.WT_LEN)
            if isinstance(ps, bytes):
                s = pb.decode(ps)
                km = pb.get(s, 23, pb.WT_32)
                if km is not None:
                    buddy[pb.get(s, 1, pb.WT_VARINT) or 0] = _f32(km)
            ac = pb.get(f, 21, pb.WT_LEN)
            if isinstance(ac, bytes):
                a = pb.decode(ac)
                slots = []
                for x in pb.get_all(a, 3) or []:
                    slots.extend(_varints(x) if isinstance(x, bytes) else [x])
                avatars.append((tid, {"type": pb.get(a, 2, pb.WT_VARINT) or 0, "slots": slots,
                                      "unlock": pb.get(a, 8, pb.WT_VARINT) or 0}))
        _gm.cache = (buddy, avatars)
    return _gm.cache


_gm.cache = None


def _f32(v):
    import struct
    if isinstance(v, (bytes, bytearray)):
        return struct.unpack("<f", bytes(v))[0]
    return struct.unpack("<f", struct.pack("<I", int(v)))[0]


def _varints(b):
    out, i = [], 0
    while i < len(b):
        n, s = 0, 0
        while True:
            x = b[i]; i += 1
            n |= (x & 0x7F) << s; s += 7
            if not x & 0x80:
                break
        out.append(n)
    return out


def _u64(f, n):
    return pb.get(f, n, pb.WT_64) or pb.get(f, n, pb.WT_VARINT) or 0


# ------------------------------------------------------------------ 8 REGISTER_BACKGROUND_DEVICE
def register_background_device(msg, username):
    """RegisterBackgroundDeviceActionProto { deviceType=1, deviceId=2 } ->
    RegisterBackgroundDeviceResponseProto { status=1 SUCCESS, token=2 BackgroundToken
    { token=1, expiration_time=2, iv=3 } }."""
    tok = hashlib.sha256(f"bg:{username}".encode()).digest()[:16]
    return (pb.Writer().uint(1, 1).message(
        2, pb.Writer().bytes_(1, tok).int_(2, _now() + 86_400_000)
        .bytes_(3, hashlib.md5(tok).digest()).to_bytes()).to_bytes())


# ------------------------------------------------------------------ buddy
def _buddy_km(pokemon_id):
    return _gm()[0].get(pokemon_id) or 3.0


def buddy_bytes():
    """BuddyPokemonProto { buddyPokemonId=1, startKmWalked=2, lastKmAwarded=3 }, or b''."""
    b = _state().get("buddy")
    if not b or not world.get_caught(b["uid"]):
        return b""
    return (pb.Writer().fixed64(1, b["uid"]).double(2, b["start_km"])
            .double(3, b["last_km"]).to_bytes())


def set_buddy(msg):
    """SetBuddyPokemonProto { pokemonId=1 } -> SetBuddyPokemonOutProto { result=1,
    updatedBuddy=2 }. 1 SUCCESS, 2 DEPLOYED, 3 NOT_OWNED, 4 IS_EGG, 5 INVALID."""
    uid = _u64(pb.decode(msg), 1)
    c = world.get_caught(uid)
    if not c:
        return pb.Writer().uint(1, 3).to_bytes(), None
    if world.is_deployed(uid):
        return pb.Writer().uint(1, 2).to_bytes(), None
    km = world.km_walked()
    _state()["buddy"] = {"uid": uid, "pokemon_id": c["pokemon_id"], "start_km": km, "last_km": km}
    _save()
    return pb.Writer().uint(1, 1).message(2, buddy_bytes()).to_bytes(), c["pokemon_id"]


def buddy_walked():
    """GetBuddyWalkedOutProto { success=1, familyCandyId=2, candyEarnedCount=3 }: one candy
    for every buddy distance walked since the last award (sent with every request)."""
    b = _state().get("buddy")
    if not b or not world.get_caught(b["uid"]):
        return pb.Writer().bool_(1, False).to_bytes(), 0
    per = _buddy_km(b["pokemon_id"])
    walked = world.km_walked()
    n = int(max(0.0, walked - b["last_km"]) // per)
    fam = P.pokemon_family(b["pokemon_id"])
    if n > 0:
        b["last_km"] += n * per
        world.add_candy(fam, n)
        _save()
    return pb.Writer().bool_(1, True).uint(2, fam).int_(3, n).to_bytes(), n


# ------------------------------------------------------------------ 154 USE_ITEM_ENCOUNTER
def use_item_encounter(msg):
    """UseItemEncounterProto { item=1, encounterId=2, spawnPointGuid=3 } ->
    UseItemEncounterOutProto { status=1 (0 SUCCESS, 1 ALREADY_COMPLETED,
    2 ACTIVE_ITEM_EXISTS, 3 NO_ITEM_IN_INVENTORY, 4 INVALID_ITEM_CATEGORY),
    captureProbability=2, activeItem=3 }. 0.71's berries (razz, nanab, pinap, golden)."""
    f = pb.decode(msg)
    item, eid = pb.get(f, 1, pb.WT_VARINT) or 0, _u64(f, 2)
    if item not in BERRY_CAPTURE:
        return pb.Writer().uint(1, 4).to_bytes(), item, "not a berry"
    s = world.get_spawn(eid)
    if not s:
        return pb.Writer().uint(1, 1).to_bytes(), item, "encounter gone"
    if not world.take_item(item, 1):
        return pb.Writer().uint(1, 3).to_bytes(), item, "none left"
    world.use_berry(eid, BERRY_CAPTURE[item])
    return (pb.Writer().uint(1, 0)
            .message(2, P.build_capture_probability(s["pokemon_id"], s["cp"]))
            .uint(3, item).to_bytes(), item, "used")


# ------------------------------------------------------------------ avatar wardrobe
def list_avatar_customizations(msg):
    """ListAvatarCustomizationsProto { avatarType=1, slot=2*, filters=3*, start=4, limit=5 }
    -> ListAvatarCustomizationsOutProto { result=1, avatarCustomizations=2*
    { avatarTemplateId=1, labels=2* } }. Every item is owned here: no shop for clothes."""
    f = pb.decode(msg)
    atype = pb.get(f, 1, pb.WT_VARINT) or 0
    want = []
    for x in pb.get_all(f, 2) or []:
        want.extend(_varints(x) if isinstance(x, bytes) else [x])
    start = pb.get(f, 4, pb.WT_VARINT) or 0
    limit = pb.get(f, 5, pb.WT_VARINT) or 0
    viewed = set(_state().get("viewed") or [])
    rows = [tid for tid, a in _gm()[1]
            if a["type"] == atype and (not want or set(a["slots"]) & set(want))]
    rows = rows[start:start + limit] if limit else rows[start:]
    w = pb.Writer().uint(1, 1)
    for tid in rows:
        labels = [2, 8] if tid in viewed else [2]            # OWNED (+ VIEWED)
        e = pb.Writer().string(1, tid)
        for lb in labels:
            e.uint(2, lb)
        w.message(2, e.to_bytes())
    return w.to_bytes(), len(rows)


def set_avatar_item_viewed(msg):
    """SetAvatarItemAsViewedProto { avatarTemplateId=1* } -> { result=1 SUCCESS }."""
    ids = [x.decode("utf-8", "replace") for x in pb.get_all(pb.decode(msg), 1) or []
           if isinstance(x, bytes)]
    seen = set(_state().get("viewed") or [])
    seen.update(ids)
    _state()["viewed"] = sorted(seen)
    _save()
    return pb.Writer().uint(1, 1).to_bytes()


# ------------------------------------------------------------------ inbox / challenge
def get_inbox():
    """GetInboxOutProto { result=1 SUCCESS, inbox=2 ClientInbox {} } -- nothing in it."""
    return pb.Writer().uint(1, 1).message(2, b"").to_bytes()


def verify_challenge():
    """VerifyChallengeOutProto { success=1 }: there is never a captcha here."""
    return pb.Writer().bool_(1, True).to_bytes()


# ------------------------------------------------------------------ gym badges
def _badge(fort_id, create=True):
    badges = _state().setdefault("gym_badges", {})
    b = badges.get(fort_id)
    if b is None and create:
        b = badges[fort_id] = {"points": 0, "won": 0, "lost": 0, "fed": 0, "deploys": 0,
                               "defended_ms": 0, "updated": _now()}
    return b


def badge_score(fort_id, points, **counts):
    """Add gym badge points (and counters) for the current trainer at one gym."""
    try:
        b = _badge(fort_id)
        b["points"] = int(b["points"] + points)
        for k, v in counts.items():
            b[k] = int(b.get(k, 0) + v)
        b["updated"] = _now()
        _save()
    except Exception:
        pass                      # a badge must never break a battle or a deploy


def _badge_type(points):
    return 1 + sum(1 for t in BADGE_TARGETS if points >= t)       # VANILLA..GOLD


def awarded_badge_bytes(fort_id):
    """AwardedGymBadge { fortId=1, gymBadgeType=2, score=3, gymBadgeStats=4,
    lastUpdateTimestampMs=5, lastCheckTimestampMs=11, earnedPoints=12 }."""
    b = _badge(fort_id, create=False) or {"points": 0, "won": 0, "lost": 0, "fed": 0,
                                          "deploys": 0, "defended_ms": 0, "updated": 0}
    stats = (pb.Writer().uint(1, b["defended_ms"]).uint(2, b["won"]).uint(3, b["fed"])
             .uint(4, b["deploys"]).uint(5, b["lost"]).to_bytes())
    return (pb.Writer().string(1, fort_id).uint(2, _badge_type(b["points"]))
            .uint(3, b["points"]).message(4, stats).uint(5, b["updated"])
            .uint(11, _now()).uint(12, b["points"]).to_bytes())


def list_gym_badges():
    """ListGymBadgesOutProto { gymBadge=1* }."""
    w = pb.Writer()
    for fid in sorted(_state().get("gym_badges") or {}):
        w.message(1, awarded_badge_bytes(fid))
    return w.to_bytes()


def gym_badge_details(msg):
    """GetGymBadgeDetailsProto { fortId=1, lat=2, lng=3 } -> GetGymBadgeDetailsOutProto
    { gymBadge=1, gymDefender=2, success=3 }."""
    fid = (pb.get(pb.decode(msg), 1, pb.WT_LEN) or b"").decode("utf-8", "replace")
    return pb.Writer().message(1, awarded_badge_bytes(fid)).bool_(3, True).to_bytes(), fid


# ------------------------------------------------------------------ TMs / rare candy
def use_move_reroll(msg):
    """UseItemMoveRerollProto { item=1, pokemonId=2 } -> UseItemMoveRerollOutProto
    { result=1 (1 SUCCESS, 2 NO_POKEMON, 3 NO_OTHER_MOVES, 5 WRONG_ITEM_TYPE,
    6 ITEM_NOT_IN_INVENTORY), updatedPokemon=2 }."""
    import random
    f = pb.decode(msg)
    item, uid = pb.get(f, 1, pb.WT_VARINT) or 0, _u64(f, 2)
    if item not in (ITEM_TM_FAST, ITEM_TM_CHARGED):
        return pb.Writer().uint(1, 5).to_bytes(), "wrong item"
    c = world.get_caught(uid)
    if not c:
        return pb.Writer().uint(1, 2).to_bytes(), "no such Pokemon"
    pid = c["pokemon_id"]
    quick, charged = P.moves_for(pid, uid)
    gd = P._gd
    pool = list((gd.QUICK if item == ITEM_TM_FAST else gd.CHARGED).get(pid) or []) if gd else []
    cur = quick if item == ITEM_TM_FAST else charged
    others = [m for m in pool if m != cur]
    if not others:
        return pb.Writer().uint(1, 3).to_bytes(), "no other moves"
    if not world.take_item(item, 1):
        return pb.Writer().uint(1, 6).to_bytes(), "no TM left"
    new = random.choice(others)
    if item == ITEM_TM_FAST:
        quick = new
    else:
        charged = new
    P.pick_moves(pid, uid, quick, charged)
    return (pb.Writer().uint(1, 1)
            .message(2, P.build_pokemon_data(pid, uid, c["cp"])).to_bytes(),
            f"#{pid} now {quick}/{charged}")


def use_rare_candy(msg):
    """UseItemRareCandyProto { item=1, pokemonId=2 (species) } -> UseItemRareCandyOutProto
    { result=1 (1 SUCCESS, 2 INVALID_POKEMON_ID, 4 WRONG_ITEM_TYPE, 5 ITEM_NOT_IN_INVENTORY),
    pokemonId=2, updatedCandyCount=3 }."""
    f = pb.decode(msg)
    item, pid = pb.get(f, 1, pb.WT_VARINT) or 0, pb.get(f, 2, pb.WT_VARINT) or 0
    if item != ITEM_RARE_CANDY:
        return pb.Writer().uint(1, 4).to_bytes(), "wrong item"
    if not 1 <= pid <= 251:
        return pb.Writer().uint(1, 2).to_bytes(), "unknown species"
    if not world.take_item(item, 1):
        return pb.Writer().uint(1, 5).to_bytes(), "none left"
    total = world.add_candy(P.pokemon_family(pid), 1)
    return pb.Writer().uint(1, 1).uint(2, pid).int_(3, total).to_bytes(), f"#{pid} candy {total}"


# ------------------------------------------------------------------ 815 AWARD_FREE_RAID_TICKET
def award_free_raid_ticket():
    """AwardFreeRaidTicketOutProto { result=1 (1 SUCCESS, 2 MIN_LEVEL,
    3 DAILY_TICKET_ALREADY_AWARDED) }. Same once-a-day pass raid071 hands out."""
    import raid071
    lvl, _xp = world.stats()
    if lvl < raid071.MIN_LEVEL:
        return pb.Writer().uint(1, 2).to_bytes()
    return pb.Writer().uint(1, 1 if raid071.daily_pass() else 3).to_bytes()


# ------------------------------------------------------------------ shop (Windstock's own)
# 0.71's shop runs through the native IAP plugin (IapManager), which talks to Niantic's
# store, not the game RPC. The phone agent replaces IapManager and asks for the list and
# purchases with two Windstock-only request numbers through the normal RPC envelope.
SHOP_LIST, SHOP_BUY = 9071, 9072


def shop_list():
    """{ item=1* { sku=1, price=2, itemName=3, count=4, category=5, sort=6 },
    coins=7, stardust=8 }."""
    import shop
    import world
    w = pb.Writer()
    entries = [e for e in shop.CATALOGUE if e[0] not in shop.WEB_ONLY]
    for sort, (sku, _label, iid, cnt, price, _icon, _was) in enumerate(entries, 1):
        upgrade = sku in shop._STORAGE_ITEM
        item = shop._STORAGE_ITEM.get(sku) or shop._DISPLAY_ITEM.get(sku, iid)
        w.message(1, pb.Writer().string(1, "pgorelease." + sku).uint(2, shop.shop_price(price))
                  .string(3, shop._ITEM_TYPE_NAME.get(int(item), "ITEM_UNKNOWN"))
                  .uint(4, 1 if upgrade else cnt)
                  .string(5, "UPGRADES" if upgrade else "ITEMS").uint(6, sort).to_bytes())
    p = world.current()
    return w.uint(7, int(p.COINS)).uint(8, int(p.STARDUST)).to_bytes(), len(entries)


def shop_buy(msg):
    """{ sku=1 } -> { ok=1, message=2, coins=3 }."""
    import shop
    import world
    sku = pb.get(pb.decode(msg), 1, pb.WT_LEN) or b""
    sku = sku.decode("utf-8", "replace")
    ok, why = shop.purchase(sku)
    world.save()
    return (pb.Writer().bool_(1, ok).string(2, why).uint(3, int(world.current().COINS))
            .to_bytes(), sku, ok, why)


HANDLED = {8, 152, 153, 154, 601, 807, 808, 809, 811, 812, 813, 814, 815, SHOP_LIST, SHOP_BUY}
