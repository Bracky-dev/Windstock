"""
Gym v2 test (gymv2.py + the gym paths in world.py / protocol.py), no phone and no
running server needed. Like test_raids.py it runs from a temp copy of the server,
so its data/ is throwaway and your real trainers and gyms are never touched.

    python3 test_gymv2.py

Covers: 6 slots / one per trainer / no duplicate species / other team refused,
level-6 gym reported to the 0.35 client, motivation decay lowering CP, no training
at your own gym, a real ATTACK_GYM knock-out costing motivation, kick-out at 0
motivation with coins paid on return (daily cap), Razz Berry feeding (cooldown,
other team refused), gym spins with the team bonus, badges, no recall, no Shop
shield, and the /gym/status route the tweak polls.
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def _isolate():
    tmp = tempfile.mkdtemp(prefix="ws-gymv2test-")
    for f in glob.glob(os.path.join(HERE, "*.py")):
        shutil.copy(f, tmp)
    os.makedirs(os.path.join(tmp, "data"))
    with open(os.path.join(tmp, "data", "settings.json"), "w") as fh:
        json.dump({"gyms": {"v2": True, "npc_defenders": 0},
                   "raids": {"scheduled": False}}, fh)
    env = dict(os.environ, WS_GYMV2_TEST_CHILD="1")
    try:
        return subprocess.call([sys.executable, os.path.join(tmp, "test_gymv2.py")],
                               cwd=tmp, env=env)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


FAILS = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        FAILS.append(what)


def now():
    import time
    return int(time.time() * 1000)


def pb_decode(raw):
    import pb
    out = {}
    for f in pb.decode(raw):
        out.setdefault(f["field"], f["value"])
    return out


def main():
    import world
    import gymv2
    import rpc
    import protocol as P

    GYM, LAT, LNG = "v2gym.16", 52.2297, 21.0122
    check(gymv2.on(), "gyms.v2 is on in this test's settings")

    print("trainers")
    teams = {"blue1": 1, "blue2": 1, "red1": 2}
    for i, (name, team) in enumerate(teams.items()):
        world.use(name)
        world.add_xp(20000)
        world.set_team(team)
        world.set_player_location(LAT, LNG, name)
        world.add_caught(8_000_000 + i, 68, 2200)        # Machamp
        world.add_caught(8_100_000 + i, 59, 2000)        # Arcanine
        world.add_caught(8_200_000 + i, 143, 2500)       # Snorlax
        world.add_item(gymv2.ITEM_RAZZ, 5)
        world.save()
    P._GYM_POS[GYM] = (LAT, LNG)

    print("deploy")
    world.use("blue1")
    ok, why = world.deploy(GYM, 8_000_000)
    check(ok, f"blue1 deploys Machamp ({why})")
    ok, why = world.deploy(GYM, 8_100_000)
    check(not ok and why == "already deployed", f"one Pokemon per trainer ({why})")
    world.use("blue2")
    ok, why = world.deploy(GYM, 8_000_001)
    check(not ok and why == "same species", f"no species twice ({why})")
    ok, why = world.deploy(GYM, 8_100_001)
    check(ok, f"blue2 deploys Arcanine ({why})")
    world.use("red1")
    ok, why = world.deploy(GYM, 8_000_002)
    check(not ok and why == "held by another team", f"red can't join a blue gym ({why})")
    check(world.gym_prestige(GYM) == world.GYM_LEVELS[5] and world.gym_level(GYM) == 6,
          "the 0.35 client sees a level-6 gym (6 slots)")
    resp = pb_decode(P.build_fort_deploy_response(GYM, 8_200_002, LAT, LNG, now()))
    check(resp.get(1) == 3, "deploy response: OPPOSING_TEAM_OWNS_FORT")

    print("motivation")
    with world._lock:
        m = next(x for x in world.GYMS[GYM] if x["owner"] == "blue1")
        m["mot_ms"] = now() - 5 * 3_600_000                # 5 hours untouched
    seen = next(x for x in world.gym_members(GYM) if x["owner"] == "blue1")
    check(0.55 < seen["mot"] < 0.7, f"motivation decayed over 5 h ({seen['mot']:.2f})")
    check(seen["cp"] < seen["cp_full"] == 2200, f"CP fell with it ({seen['cp']} < 2200)")

    print("no training")
    world.use("blue1")
    out = pb_decode(P.build_start_gym_battle_response(GYM, [8_200_000], 8_100_001, now()))
    check(out.get(1) == 4, "battling your own team's gym is refused (fed, not trained)")

    print("attack")
    world.use("red1")
    defenders = [x["uid"] for x in world.gym_members(GYM)]
    target = defenders[0]
    out = pb_decode(P.build_start_gym_battle_response(GYM, [8_200_002, 8_000_002], target, now()))
    check(out.get(1) == 1, "red1 starts a battle against the blue gym")
    bid = out[4].decode()
    b = world.BATTLES[bid]
    before = gymv2.motivation(next(x for x in world.GYMS[GYM] if x["uid"] == b["defender"]))
    with world._lock:
        b["def_hp"] = 1
    t = b["start"] + 4000
    P.build_attack_gym_response(GYM, bid, [{"type": P.BA_ATTACK, "start": t, "duration": 1000,
                                            "active": 8_200_002, "target": 0}], t + 3000)
    still = next((x for x in world.GYMS.get(GYM, []) if x["uid"] == b["defender"]), None)
    check(still is not None and gymv2.motivation(still) < before - 0.3,
          f"a knock-out costs motivation ({before:.2f} -> "
          f"{gymv2.motivation(still) if still else 0:.2f})")

    print("kick-out at 0 motivation")
    with world._lock:
        m = next(x for x in world.GYMS[GYM] if x["owner"] == "blue1")
        m["mot"], m["mot_ms"] = 0.0, now()
        m["deployed_ms"] = now() - 100 * 60_000           # held for 100 minutes
    gone = gymv2.on_defender_beaten(GYM, 8_000_000, "red1")
    check(gone and not any(x["owner"] == "blue1" for x in world.GYMS.get(GYM, [])),
          "beaten at 0 motivation: sent home")
    check(any(r[4] == 8_000_000 and r[2] == 10 for r in world.RETURNS.get("blue1", [])),
          "10 coins queued for 100 minutes held")
    world.use("blue1")
    c0 = world.current().COINS
    world.collect_gym_returns()
    check(world.current().COINS == c0 + 10, "coins paid when it comes home")
    check(gymv2.cap_coins("capper", 60) == 50 and gymv2.cap_coins("capper", 5) == 0,
          "defender coins capped at 50 a day")

    print("berries")
    world.use("blue2")
    arc = next(x for x in world.GYMS[GYM] if x["owner"] == "blue2")
    with world._lock:
        arc["mot"], arc["mot_ms"] = 0.2, now()
    _rz0 = dict(world.bag_items()).get(gymv2.ITEM_RAZZ)
    ok, msg, dust = gymv2.feed("blue2", GYM, arc["uid"])
    check(ok and dust == 20, f"Razz Berry fed ({msg})")
    check(gymv2.motivation(arc) > 0.45, f"motivation restored ({gymv2.motivation(arc):.2f})")
    ok, msg, _ = gymv2.feed("blue2", GYM, arc["uid"])
    check(not ok and "eating" in msg, f"feed cooldown ({msg})")
    ok, msg, _ = gymv2.feed("red1", GYM, arc["uid"])
    check(not ok and "team" in msg, f"other team can't feed ({msg})")
    world.use("blue2")
    _rz = dict(world.bag_items()).get(gymv2.ITEM_RAZZ)
    check(_rz == _rz0 - 1, f"the berry came out of the bag ({_rz0} -> {_rz})")

    print("spins")
    ok, msg, items, xp = gymv2.spin("red1", GYM)
    check(ok and items, f"gyms can be spun ({items})")
    ok2, msg2, _, _ = gymv2.spin("red1", GYM)
    check(not ok2, f"spin cooldown ({msg2})")
    check(gymv2.spin_bonus("blue2", GYM) >= 1 and gymv2.spin_bonus("red1", GYM) == 0,
          "team bonus item only at your team's gym")

    print("badges")
    bb = gymv2.badge("blue2", GYM)
    check(bb["type"] == 1 and bb["score"] >= 100, f"deploying earns a vanilla badge ({bb})")
    gymv2.badge_add("blue2", GYM, 1000)
    check(gymv2.badge("blue2", GYM)["type"] == 2, "500+ points: bronze")
    check(gymv2.spin_bonus("blue2", GYM) == 2, "bronze badge adds a spin item")

    print("old 2016 paths are off")
    world.use("blue2")
    check(world.recall(GYM, arc["uid"]) is False, "no recall in gym v2")
    check(world.collect_defender_bonus()[0] == 4, "no Shop defender bonus in gym v2")

    print("tweak route")
    rpc.user_for_ip = lambda ip: {"10.0.0.1": "blue2"}.get(ip)
    st, _h, out = gymv2.handle("GET", "/gym/status", f"gym={GYM}", {}, b"", print, ip="10.0.0.1")
    s = json.loads(out)
    check(st == 200 and s["members"] and "motivation" in s["members"][0]
          and s["badge"]["type"] == 2 and s["slots"] == 6, "/gym/status has what the tweak draws")
    st, _h, out = gymv2.handle("POST", "/gym/feed", "", {},
                               json.dumps({"gym": GYM, "uid": arc["uid"]}).encode(), print,
                               ip="10.0.0.1")
    check(st == 200 and "message" in json.loads(out), "/gym/feed answers")

    print()
    print(f"{len(FAILS)} failure(s)" if FAILS else "ALL PASSED")
    return 1 if FAILS else 0


if __name__ == "__main__":
    if os.environ.get("WS_GYMV2_TEST_CHILD") != "1":
        sys.exit(_isolate())
    sys.exit(main())
