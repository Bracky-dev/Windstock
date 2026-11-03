"""Raids for the iOS 0.67 client (platform "ios067"), kept apart from the 0.71 flow.

Every raid RPC goes through here. Any other platform is passed straight to raid071, so
Android is untouched. For ios067 the 0.67 app's lobby never sends START_RAID_BATTLE when
the countdown ends (it sits at 0), so this tries variants of what the server sends. They
are read from data/raid067.json on every request -- no restart to change them:

  lobby_secs      lobby countdown in seconds (default: raid071's)
  transition_secs gap between pokemonSelectionEndMs and raidBattleStartMs (default 8). The
                    0.67 client's CheckLobbyTimer only calls StartRaidBattle while
                    selectionEnd <= now < battleStart; with both equal that window is empty
                    and the lobby sits at 0 forever.
  start_in_details  once the countdown is over, start the battle on the server and put it
                    in the GET_RAID_DETAILS reply (field 2) as well as the lobby's battle id
  start_on_join   start the battle at join time (the lobby carries its battle id from the
                    first reply)

Each start writes "[raid067] ..." to the server log.
"""
import json
import os

import pb
import raid071

_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "raid067.json")
_DEFAULT = {"lobby_secs": None, "start_in_details": False, "start_on_join": False,
            "transition_secs": 8}


def conf():
    try:
        with open(_PATH) as f:
            return {**_DEFAULT, **json.load(f)}
    except (OSError, ValueError):
        return dict(_DEFAULT)


def _ios067():
    import rpc
    return rpc.USER_ASSET_PLATFORM.get(raid071._user()) == "ios067"


def _log(msg):
    print(f"      [raid067] {msg}", flush=True)


def _start(gid, lb, now):
    r = raid071._raid_for(gid, lb["seed"], now)
    if not r:
        return None
    res, battle = raid071._begin(gid, r, lb, lb.get("team") or [], now)
    _log(f"started battle for {gid[:12]}... result {res}")
    return battle


def get_details(msg):
    gid, res, out = raid071.get_details(msg)
    if not _ios067() or res != 1:
        return gid, res, out
    c = conf()
    now = raid071._now()
    f, _g, seed = raid071.parse(msg)
    r = raid071._raid_for(gid, seed, now)
    lb = raid071._lobby(gid, r["seed"]) if r else None
    if c["start_in_details"] and lb and now >= lb["battle_start"] and not lb.get("battle_id"):
        battle = _start(gid, lb, now)
        if battle:
            gid, res, out = raid071.get_details(msg)         # the lobby now has its battle id
            out += pb.Writer().message(2, battle).to_bytes()
    return gid, res, out


def join(msg):
    gid, res, out = raid071.join(msg)
    if not _ios067() or res != 1:
        return gid, res, out
    c = conf()
    now = raid071._now()
    f, _g, seed = raid071.parse(msg)
    r = raid071._raid_for(gid, seed, now)
    lb = raid071._lobby(gid, r["seed"]) if r else None
    if not lb:
        return gid, res, out
    if not lb.get("battle_id") and not lb.get("ios067_timing"):
        lb["ios067_timing"] = True
        end = lb["created"] + (int(c["lobby_secs"]) * 1000 if c["lobby_secs"]
                               else lb["join_end"] - lb["created"])
        lb["join_end"] = end                                  # join + pokemon selection end
        lb["battle_start"] = end + int(c["transition_secs"]) * 1000
        lb["battle_end"] = lb["battle_start"] + raid071.TIERS[r["tier"]]["secs"] * 1000
    if c["start_on_join"] and not lb.get("battle_id"):
        _start(gid, lb, now)
    return gid, res, raid071.pb.Writer().uint(1, 1).message(2, raid071.lobby_bytes(lb)).to_bytes()


leave = raid071.leave
set_visibility = raid071.set_visibility
set_pokemon = raid071.set_pokemon
start_battle = raid071.start_battle
attack = raid071.attack
