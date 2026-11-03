"""
Friend bots -- pretend trainers for trying the Friends screens on a test server.

Off unless the server is started with WS_FRIEND_BOTS=<how many> (at most len(BOTS)), so the
public VPS never has them. Each bot is a small save in data/saves (name, level, team; nobody
can log in to it -- there is no password) with its own Trainer Code, and a thread that every
few seconds:

  * puts some of them online and the rest "seen a while ago", in turns, like real players;
  * accepts any friend request sent to a bot after a few seconds;
  * has the first few bots send a request to every real trainer who has opened Friends
    (once each), so there is something to Accept;
  * opens any gift sent to a bot (friendship +1 for the day) and sends each of its friends
    a gift once a day;
  * trades in a trade room: picks one of its own Pokemon, says hello in the chat, answers
    what you write, and confirms once you have confirmed (each bot has a few Pokemon of its
    own and plenty of stardust); AshKetchum99 opens a room with each new friend once.

A new friendship with a bot starts at the bot's DEMO_DAYS, so the hearts and every
friendship level can be seen at once instead of after months of play.

The codes are printed in the server log at start ("[friends] bot ...").
"""
import json
import os
import random
import threading
import time

BOTS = [  # name, level, team (1 Mystic, 2 Valor, 3 Instinct), demo friendship days
    ("AshKetchum99", 31, 2, 95),
    ("MistyWaterflower", 24, 1, 34),
    ("RockSolidBrock", 19, 3, 9),
    ("NurseJoy", 27, 1, 2),
    ("GaryOak", 8, 0, 0),
    ("ProfWillowFan", 35, 3, 0),
    ("TeamRocketJess", 15, 2, 0),
    ("BugCatcherRick", 6, 0, 0),
]
# Each bot's look (0.35 option ids; gender 0 = male, 1 = female). The game's own option names
# don't match the textures, so by how they RENDER: shirt M 0 red, 1 orange, 2 yellow / F 0 pink,
# 1 white-blue, 2 yellow; hat M 0 grey, 1 dark, 2 gold trim / F 0 white-red, 1 white-gold,
# 2 black; hair 0 brown, 1 blonde, 2 black, 3 auburn, 4 blue, 5 purple.
LOOKS = {
    "AshKetchum99":     dict(gender=0, skin=1, hair=2, shirt=0, hat=1, eyes=2, backpack=1),
    "MistyWaterflower": dict(gender=1, skin=0, hair=3, shirt=2, hat=1, eyes=0, backpack=0),
    "RockSolidBrock":   dict(gender=0, skin=3, hair=2, shirt=1, hat=0, eyes=3, backpack=0),
    "NurseJoy":         dict(gender=1, skin=1, hair=0, shirt=1, hat=0, eyes=4, backpack=2),
    "GaryOak":          dict(gender=0, skin=0, hair=0, shirt=0, hat=2, eyes=1, backpack=0),
    "ProfWillowFan":    dict(gender=0, skin=2, hair=1, shirt=2, hat=0, eyes=4, backpack=2),
    "TeamRocketJess":   dict(gender=1, skin=0, hair=5, shirt=0, hat=2, eyes=3, backpack=1),
    "BugCatcherRick":   dict(gender=0, skin=2, hair=4, shirt=1, hat=2, eyes=2, backpack=1),
}
TEAMS = {  # each bot's Pokemon (species, cp) -- what you can trade for
    "AshKetchum99": [(25, 620), (1, 410), (4, 388), (7, 402), (143, 1650)],
    "MistyWaterflower": [(120, 520), (121, 1150), (54, 440), (118, 300), (131, 1720)],
    "RockSolidBrock": [(74, 480), (95, 560), (111, 700), (138, 610)],
    "NurseJoy": [(113, 280), (35, 330), (39, 260)],
    "GaryOak": [(133, 520), (58, 610), (16, 120)],
    "ProfWillowFan": [(147, 690), (137, 820), (132, 410), (149, 2400)],
    "TeamRocketJess": [(23, 370), (52, 300), (109, 520)],
    "BugCatcherRick": [(10, 90), (13, 85), (12, 410), (123, 900)],
}
STARDUST = 200000
GIFT_AFTER = 30.0               # a bot sends its daily gift this long after the day starts for it
SENDERS = 3                     # the first three send you a request themselves
ACCEPT_AFTER = 4.0              # seconds before a bot accepts
TICK = 5.0

_started = False
_started_at = 0.0
_gifted = set()                 # (bot, trainer, day) gifts already sent
_asked = set()                  # (bot, trainer) requests already sent
_pending_since = {}             # (bot, from) -> first time the request was seen


def login(name):
    return "wsbot_" + name.lower()


def count():
    try:
        return max(0, min(len(BOTS), int(os.environ.get("WS_FRIEND_BOTS", "0") or 0)))
    except ValueError:
        return 0


def is_bot(user):
    return isinstance(user, str) and user.startswith("wsbot_")


def demo_days(user):
    for name, _lvl, _team, days in BOTS:
        if login(name) == user:
            return days
    return 0


def _make_saves(n, log):
    import world
    import friends
    for name, lvl, team, _days in BOTS[:n]:
        user = login(name)
        path = os.path.join(world.SAVES_DIR, world._safe_name(user) + ".json")
        if not os.path.exists(path):
            os.makedirs(world.SAVES_DIR, exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                json.dump({"username": user, "codename": name, "team": team,
                           "xp": world.xp_for_level(lvl)}, fh)
        prev = getattr(world._current, "player", None)
        try:
            p = world.use(user)
            if p.STARDUST < STARDUST // 2:
                p.STARDUST = STARDUST
            look = dict(pants=0, shoes=1, **LOOKS.get(name, {}))
            if LOOKS.get(name) and p.AVATAR != look:   # a look of their own (Friends pictures)
                p.AVATAR = look
            if not p.CAUGHT:                       # a few Pokemon to trade
                for pid, cp in TEAMS.get(name, []):
                    world.add_caught(world.new_uid(pid), pid, cp)
            p.save()
        finally:
            world._current.player = prev
        log(f"[friends] bot {name}: Trainer Code {friends.code_for(user)}")


def _tick(n):
    import friends
    import rpc
    now = time.time()
    bots = [login(b[0]) for b in BOTS[:n]]
    # online in turns: every 10 minutes a different two-thirds of them are on
    turn = int(now // 600)
    for i, user in enumerate(bots):
        if (i + turn) % 3 != 0:
            rpc._user_seen[user] = now
            friends.seen(user)
        elif user not in rpc._user_seen:
            rpc._user_seen[user] = now - 3600 * (2 + i * 7)      # "seen n h ago"
    with friends._lock:
        st = friends._load()
        # accept what was sent to a bot
        for user in bots:
            for frm in list((st["requests"].get(user) or {})):
                first = _pending_since.setdefault((user, frm), now)
                if now - first >= ACCEPT_AFTER:
                    friends.accept(user, frm)
                    _pending_since.pop((user, frm), None)
        gifts_to_bots = [(user, frm) for user in bots for frm in list((st["gifts"].get(user) or {}))]
        rooms = [(rid, json.loads(json.dumps(r))) for rid, r in st["rooms"].items()
                 if r["state"] == "open" and (r["a"] in bots or r["b"] in bots)]
        friends_of = {user: friends.friends_of(user) for user in bots}
        # the first few ask every real trainer who has a code
        real = [u for u in st["codes"] if not is_bot(u)]
        for user in bots[:SENDERS]:
            for trainer in real:
                if (user, trainer) in _asked:
                    continue
                _asked.add((user, trainer))
                if friends._key(user, trainer) in st["links"] or user in (st["requests"].get(trainer) or {}):
                    continue
                if trainer in (st["requests"].get(user) or {}):
                    continue
                st["requests"].setdefault(trainer, {})[user] = int(now * 1000) - random.randint(0, 600000)
                friends._write()
    # outside the friends lock: these take world's lock too (items, trades)
    for user, frm in gifts_to_bots:                          # open what you sent
        if now - _pending_since.setdefault(("gift", user, frm), now) >= ACCEPT_AFTER:
            friends.open_gift(user, frm)
            _pending_since.pop(("gift", user, frm), None)
    for rid, r in rooms:                                     # trade rooms
        _room_turn(friends, rid, r, set(bots), now)
    ash = bots[0] if bots else None                          # Ash opens a room with each new friend once
    for trainer in (friends_of.get(ash) or []):
        if not is_bot(trainer) and (ash, trainer, "room") not in _asked:
            _asked.add((ash, trainer, "room"))
            friends.trade_start(ash, trainer)
    day_start = time.mktime(time.strptime(time.strftime("%Y-%m-%d", time.gmtime()), "%Y-%m-%d")) - time.timezone
    for i, user in enumerate(bots):                          # a gift to each friend, once a day
        if now - max(day_start, _started_at) < GIFT_AFTER * (1 + i):
            continue
        for trainer in friends_of[user]:
            if not is_bot(trainer) and (user, trainer, friends._today()) not in _gifted:
                _gifted.add((user, trainer, friends._today()))
                friends.send_gift(user, trainer)


HELLO = ["Hi! I'll put up my {mon} -- pick whatever you like!", "Hey! How about my {mon}?",
         "Hello! I've got a {mon} for you."]
REPLIES = ["Sounds good to me!", "Sure, deal!", "Nice pick 😄", "OK! Confirm when you're ready.",
           "Haha, fair enough.", "Let's do it!"]


def _room_turn(friends, rid, r, bots, now):
    """One step of a bot in a trade room: pick, greet, answer chat, confirm after you."""
    bot = r["a"] if r["a"] in bots else r["b"]
    you = r["b"] if bot == r["a"] else r["a"]
    if r["pick"].get(bot) is None:
        if now - _pending_since.setdefault(("pick", rid), now) < ACCEPT_AFTER:
            return
        box = friends.box(bot)
        mons = [m for m in box.get("pokemon") or [] if not m.get("blocked")]
        if not mons:
            friends.trade_chat(bot, rid, "Sorry, I have nothing to trade right now!")
            friends.trade_cancel(bot, rid)
            return
        m = random.choice(mons)
        friends.trade_pick(bot, rid, m["uid"])
        friends.trade_chat(bot, rid, random.choice(HELLO).format(mon=m["name"]))
        return
    chat = r["chat"]
    if chat and chat[-1]["who"] == you:                      # you said something: answer
        if now - _pending_since.setdefault(("chat", rid, len(chat)), now) >= 2.0:
            friends.trade_chat(bot, rid, random.choice(REPLIES))
        return
    if r["ok"].get(you) and not r["ok"].get(bot) and r["pick"].get(you) is not None:
        if now - _pending_since.setdefault(("ok", rid, r["pick"].get(you)), now) >= 2.0:
            res = friends.trade_ok(bot, rid)
            if res.get("error"):
                print(f"[friends] bot trade failed: {res['error']}")


def start(log=print):
    """Called by friends.py on first use. Does nothing unless WS_FRIEND_BOTS is set."""
    global _started, _started_at
    n = count()
    if _started or not n:
        return
    _started = True
    _started_at = time.time()
    try:
        _make_saves(n, log)
    except Exception as e:
        log(f"[friends] bots not made: {e}")
        return

    def loop():
        while True:
            try:
                _tick(n)
            except Exception as e:
                log(f"[friends] bot tick failed: {e}")
            time.sleep(TICK)
    threading.Thread(target=loop, name="friend-bots", daemon=True).start()
    log(f"[friends] {n} friend bots running")
