"""
Raid test, no phone and no running server needed (raids.py + raidlobby.py + the
gym battle path in protocol.py).

It copies the server's .py files into a temp folder and runs there, so its data/
(saves, gyms.json, raids.json, settings.json) is a fresh throwaway one and your
real trainers and gyms are never touched.

    python3 test_raids.py

Covers: stable uids across processes, the deterministic schedule, a forced raid
taking over a gym, the lobby (level gate, passes, refund, cap), three trainers
hitting one shared boss through the real START_GYM_BATTLE / ATTACK_GYM builders,
the felling blow paying everyone who did enough, the catchable drop at each
trainer's feet, deploys being refused while a boss holds the gym, and raid
state surviving a restart.
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
    """Re-run this file from a temp copy of the server so data/ is throwaway."""
    tmp = tempfile.mkdtemp(prefix="ws-raidtest-")
    for f in glob.glob(os.path.join(HERE, "*.py")):
        shutil.copy(f, tmp)
    os.makedirs(os.path.join(tmp, "data"))
    with open(os.path.join(tmp, "data", "settings.json"), "w") as fh:
        json.dump({"raids": {"scheduled": True, "chance": 1.0}}, fh)
    env = dict(os.environ, WS_RAID_TEST_CHILD="1")
    try:
        return subprocess.call([sys.executable, os.path.join(tmp, "test_raids.py")],
                               cwd=tmp, env=env)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


FAILS = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        FAILS.append(what)


def main():
    import world
    import raids
    import raidlobby
    import rpc
    import protocol as P

    GYM, LAT, LNG = "testgym.16", 52.2297, 21.0122
    TRAINERS = ["raidA", "raidB", "raidC"]
    logs = []

    print("stable uids")
    code = "import world; print(world._stable_uid('raid', 'x', 1))"
    a = subprocess.check_output([sys.executable, "-c", code], text=True).strip()
    b = subprocess.check_output([sys.executable, "-c", code], text=True,
                                env=dict(os.environ, PYTHONHASHSEED="123")).strip()
    check(a == b and a == str(world._stable_uid("raid", "x", 1)),
          "raid boss uid is the same in every process")

    print("schedule")
    r1 = raids.raid_at(GYM, 10 ** 12)
    raids._ROLLS.clear()
    r2 = raids.raid_at(GYM, 10 ** 12)
    check(r1 is not None and r1 == r2, "a gym's raid is the same after the cache is dropped")
    check(r1 is None or r1["spawn_ms"] <= 10 ** 12 < r1["end_ms"], "raid window contains now")
    check(r1 is None or r1["pokemon_id"] in raids._pool(r1["tier"]), "boss comes from its tier pool")
    eggs = [raids.raid_at(f"g{i}", 10 ** 12) for i in range(200)]
    check(any(e and not raids.hatched(e, 10 ** 12) for e in eggs)
          and any(e and raids.hatched(e, 10 ** 12) for e in eggs),
          "some gyms show eggs and some show bosses")
    import settings
    settings.set_values("raids", {"scheduled": False})
    check(raids.raid_at(GYM) is None, "no scheduled raids while raids.scheduled is off")

    print("trainers")
    for i, name in enumerate(TRAINERS):
        world.use(name)
        world.add_xp(20000)                                 # level 6+
        world.set_player_location(LAT, LNG, name)
        world.add_caught(9_000_000 + i, 68, 2200)           # Machamp
        world.add_caught(9_100_000 + i, 59, 2000)           # Arcanine
    world.use("lowbie")
    world.add_caught(9_200_000, 16, 100)
    P._GYM_POS[GYM] = (LAT, LNG)

    print("forced raid takes the gym")
    r = raids.force(GYM, tier=1, pokemon_id=129)
    m = world.gym_members(GYM)
    check(len(m) == 1 and m[0].get("raid") and m[0]["pokemon_id"] == 129,
          "the boss is the gym's only member")
    check(m[0]["uid"] == r["uid"], "member uid matches the raid")
    world.use("raidA")
    resp = pb_decode(P.build_fort_deploy_response(GYM, 9_100_000, LAT, LNG, now()))
    check(resp.get(1) == 4, "deploying onto a raid gym is refused")
    near = raids.near(LAT, LNG)
    check(any(v["gym"] == GYM and v["hatched"] for v in near), "/raid/map lists the boss")

    print("lobby")
    ips = {f"10.0.0.{i}": n for i, n in enumerate(TRAINERS + ["lowbie"])}
    rpc.user_for_ip = lambda ip: ips.get(ip)

    def call(ip, action, body=None):
        st, _h, out = raidlobby.handle("POST" if body is not None else "GET",
                                       f"/raid/{action}", f"gym={GYM}", {},
                                       json.dumps(body).encode() if body is not None else b"",
                                       logs.append, ip=ip)
        return json.loads(out)

    s = call("10.0.0.3", "join", {})
    check(not s["me"]["in_lobby"] and "level" in s.get("message", ""),
          "a level-1 trainer can't join")
    s = call("10.0.0.0", "join", {})
    check(s["me"]["in_lobby"] and s["me"]["passes"]["free"] == 0,
          "joining spends the free pass")
    s = call("10.0.0.0", "leave", {})
    check(not s["me"]["in_lobby"] and s["me"]["passes"]["free"] == 1,
          "leaving before the fight gives the pass back")
    for ip in ("10.0.0.0", "10.0.0.1", "10.0.0.2"):
        s = call(ip, "join", {})
    check(len(s["lobby"]["members"]) == 3, "three trainers in the lobby")
    s = call("10.0.0.0", "start", {})
    check(s["lobby"]["state"] == "countdown", "start begins the countdown")
    world.use("raidC")
    s = call("10.0.0.2", "join", {})
    check(s["me"]["passes"]["free"] == 0, "no second free pass the same day")
    world.add_coins(500)
    s = call("10.0.0.2", "buy_pass", {})
    check(s["ok"] and s["passes"]["premium"] == 1, "Premium Raid Pass bought with coins")

    print("battle")
    boss_uid = r["uid"]
    battles = {}
    for i, name in enumerate(TRAINERS):
        world.use(name)
        out = pb_decode(P.build_start_gym_battle_response(
            GYM, [9_000_000 + i, 9_100_000 + i], boss_uid, now()))
        check(out.get(1) == 1, f"{name}: START_GYM_BATTLE against the boss succeeds")
        battles[name] = out[4].decode()
    bstate = world.RAID_BOSSES.get(GYM)
    check(bstate and bstate["max"] == 600, "tier-1 boss has the 0.71 HP pool (600)")

    for i, name in enumerate(TRAINERS):
        world.use(name)
        b = world.BATTLES[battles[name]]
        t = b["start"] + 4000
        acts = [{"type": P.BA_ATTACK, "start": t + k * 1200, "duration": 1000,
                 "active": 9_000_000 + i, "target": 0} for k in range(8)]
        P.build_attack_gym_response(GYM, battles[name], acts, t + 10_000)
    hp_after = world.RAID_BOSSES[GYM]["hp"]
    dmg = world.RAID_BOSSES[GYM]["damage"]
    check(hp_after < 600 and len(dmg) == 3, f"all three hits land on ONE pool (hp {hp_after}, {dmg})")

    # Bring the boss to its last HP and let raidA land the final blow for real.
    with world._lock:
        for name in TRAINERS:
            dmg[name] = max(dmg.get(name, 0), 60)
        world.RAID_BOSSES[GYM]["hp"] = 1
    world.use("raidA")
    b = world.BATTLES[battles["raidA"]]
    t = b["last_emit"] + 2000
    P.build_attack_gym_response(GYM, battles["raidA"],
                                [{"type": P.BA_ATTACK, "start": t, "duration": 1000,
                                  "active": 9_000_000, "target": 0}], t + 3000)
    check(world.RAID_BOSSES[GYM]["hp"] == 0, "boss felled")
    check(all(n in raids.PENDING for n in TRAINERS), "every trainer with enough damage has rewards waiting")
    check(all(world.bonus_spawns(n) for n in TRAINERS), "the boss dropped at each trainer's feet")
    res = raids.results_for(GYM, TRAINERS[0])
    rw = (res or {}).get("reward") or {}
    check(rw.get("ball_bonus", {}).get("boss") == 6 and rw.get("balls") == sum(rw["ball_bonus"].values())
          and abs(sum(res["teams"].values()) - 1) < 1e-6 or not any(res["teams"].values()),
          f"0.71 resolve screen: Premier Ball breakdown + team shares ({rw.get('ball_bonus')})")
    drop = world.bonus_spawns("raidB")[0]
    check(drop["cp"] < r["cp"], f"catchable boss is level 20 (CP {drop['cp']} < boss {r['cp']})")

    print("rewards")
    world.use("raidB")
    xp0 = world.stats()[1]
    bag0 = dict(world.bag_items())
    got = raids.collect()
    check(len(got) == 1, "rewards paid once")
    check(world.stats()[1] > xp0, "raid XP paid")
    check(dict(world.bag_items()).get(1, 0) >= bag0.get(1, 0) + 6, "at least 6 balls for the catch")
    check(raids.collect() == [], "nothing paid twice")

    print("restart")
    raids.save()
    saved_hp = dict(world.RAID_BOSSES[GYM])
    raids.FORCED.clear(); raids.PASSES.clear(); raids.PENDING.clear()
    world.RAID_BOSSES.clear()
    raids.load()
    check(GYM in raids.FORCED, "forced raid survives a restart")
    check(raids.passes("raidC")["premium"] == 1, "bought pass survives a restart")
    check(world.RAID_BOSSES.get(GYM, {}).get("hp") == saved_hp["hp"]
          and isinstance(world.RAID_BOSSES[GYM]["key"], tuple), "boss HP survives a restart")
    check("raidA" in raids.PENDING, "unpaid rewards survive a restart")

    print("end")
    raids.clear(GYM)
    check(not world.gym_members(GYM) or not world.gym_members(GYM)[0].get("raid"),
          "clearing the raid gives the gym back")

    print()
    print(f"{len(FAILS)} failure(s)" if FAILS else "ALL PASSED")
    return 1 if FAILS else 0


def now():
    import time
    return int(time.time() * 1000)


def pb_decode(raw):
    """{field: first value} of a top-level message."""
    import pb
    out = {}
    for f in pb.decode(raw):
        out.setdefault(f["field"], f["value"])
    return out


if __name__ == "__main__":
    if os.environ.get("WS_RAID_TEST_CHILD") != "1":
        sys.exit(_isolate())
    sys.exit(main())
