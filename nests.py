"""
Nests and nest migration -- the part players can SEE.

biomes.park_nest_species already makes parks spawn mostly one species and
rotates it every `spawns.nest_rotation_days`. This module answers the questions
a 2016 player asked the Silph Road: where are the nests near me, what is in
them, and when do they migrate?

Where a park pack covers the map (parks.py, built from real OSM park outlines
by tools/fetch_parks.py), a nest is one real park: every spawn inside its
outline rolls the park's species, and parks smaller than
spawns.nest_min_area_m2 aren't nests. Elsewhere the old guess stands: a nest is
every park-NAMED stop in one level-14 S2 cell (~600 m), plus spawns within
spawns.nest_radius_m of one.

Rotation periods count from the Unix epoch, which was a Thursday, so with the
default 14 days (or 7) migrations land on Thursdays at 00:00 UTC -- the same
day the real game migrated its nests.
"""

import math
import time

import biomes
import settings as _cfg

DAY_MS = 86_400_000


def _rotation_days():
    try:
        return max(1, int(_cfg.get("spawns", "nest_rotation_days", cast=int)))
    except Exception:
        return 14


def enabled():
    try:
        return bool(_cfg.get("spawns", "nests", cast=bool))
    except Exception:
        return False


def period(now_ms=None):
    """Which rotation we are in. Changes exactly when the nests migrate."""
    now_ms = int(time.time() * 1000) if now_ms is None else int(now_ms)
    return int(now_ms // (_rotation_days() * DAY_MS))


def migration(now_ms=None):
    """{"period", "last_ms", "next_ms", "rotation_days"} for the current cycle."""
    now_ms = int(time.time() * 1000) if now_ms is None else int(now_ms)
    days = _rotation_days()
    p = int(now_ms // (days * DAY_MS))
    return {"period": p, "last_ms": p * days * DAY_MS,
            "next_ms": (p + 1) * days * DAY_MS, "rotation_days": days}


def _dist_m(lat1, lng1, lat2, lng2):
    cosl = max(0.2, math.cos(math.radians((lat1 + lat2) / 2)))
    return math.hypot((lat2 - lat1) * 111320.0, (lng2 - lng1) * 111320.0 * cosl)


def _park_forts(lat, lng, radius_m):
    """Park forts within radius_m, via the level-15 cell index (never a scan of
    the whole fort list, which is ~1 GB on the phone)."""
    import s2sphere
    import pois
    # a square cap is plenty: we filter by real distance afterwards
    dlat = radius_m / 111320.0
    dlng = radius_m / (111320.0 * max(0.2, math.cos(math.radians(lat))))
    rect = s2sphere.LatLngRect.from_point_pair(
        s2sphere.LatLng.from_degrees(lat - dlat, lng - dlng),
        s2sphere.LatLng.from_degrees(lat + dlat, lng + dlng))
    cov = s2sphere.RegionCoverer()
    cov.min_level = cov.max_level = 15
    cov.max_cells = 2000
    idx = pois.forts_by_cell()
    out = []
    for c in cov.get_covering(rect):
        for f in idx.get(c.id()) or []:
            if f.get("park") and _dist_m(lat, lng, f["lat"], f["lng"]) <= radius_m:
                out.append(f)
    return out


def _best_name(names):
    """The park's name: the one most of its stops share, else the shortest."""
    counts = {}
    for n in names:
        if n:
            counts[n] = counts.get(n, 0) + 1
    if not counts:
        return "Park"
    return sorted(counts, key=lambda n: (-counts[n], len(n)))[0]


def near(lat, lng, radius_m=3000.0, limit=20, now_ms=None):
    """The nests around (lat, lng), nearest first:
    [{"species", "name", "lat", "lng", "distance_m", "stops"}]."""
    if not enabled():
        return []
    now_ms = int(time.time() * 1000) if now_ms is None else int(now_ms)
    days = _rotation_days()
    try:
        import parks
        if parks.covered(lat, lng):
            out = []
            for p in parks.near(lat, lng, radius_m, _min_area(), limit=200):
                sp = park_species(p["id"], now_ms)
                if sp:
                    out.append({"species": int(sp), "name": p["name"],
                                "lat": round(p["lat"], 6), "lng": round(p["lng"], 6),
                                "distance_m": p["distance_m"], "stops": 0})
                if len(out) >= max(1, int(limit)):
                    break
            return out
    except Exception:
        pass
    try:
        share = float(_cfg.get("spawns", "park_nest_share", cast=float))
    except Exception:
        share = 0.67
    try:
        import s2sphere
        forts = _park_forts(lat, lng, radius_m)
    except Exception:
        return []
    groups = {}
    for f in forts:
        cid = s2sphere.CellId.from_lat_lng(
            s2sphere.LatLng.from_degrees(f["lat"], f["lng"])).parent(14).id()
        groups.setdefault(cid, []).append(f)
    out = []
    for cid, fs in groups.items():
        sp = biomes.park_nest_species(fs[0]["lat"], fs[0]["lng"], now_ms, days, share)
        if not sp:
            continue
        clat = sum(f["lat"] for f in fs) / len(fs)
        clng = sum(f["lng"] for f in fs) / len(fs)
        # distance to the NEAREST stop of the park, not its middle: that's
        # how far you actually have to walk
        d = min(_dist_m(lat, lng, f["lat"], f["lng"]) for f in fs)
        out.append({"species": int(sp), "name": _best_name(f.get("name", "") for f in fs),
                    "lat": round(clat, 6), "lng": round(clng, 6),
                    "distance_m": int(d), "stops": len(fs)})
    out.sort(key=lambda n: n["distance_m"])
    return out[:max(1, int(limit))]


# ---- which park a spawn belongs to ------------------------------------------
# Only spawn points of park-NAMED stops used to roll the nest species, but most
# stops inside a park are named after a statue, fountain or bench, and the
# random field + the cluster around the trainer never looked at parks at all --
# so standing in a nest you mostly saw random Pokemon. Now any spawn within
# nest_radius_m of a park stop belongs to that park's nest. Cached per level-17
# cell (~75 m): a map refresh asks for dozens of spawns in the same few cells.
_anchor_cache = {}
_anchor_key = [None]


def _nest_radius():
    try:
        return max(0.0, float(_cfg.get("spawns", "nest_radius_m", cast=float)))
    except Exception:
        return 150.0


def anchor(lat, lng):
    """(lat, lng) of the nearest park stop within spawns.nest_radius_m, or None.
    Keying the nest species on that stop keeps the spawns and the Hub's NESTS
    list (which groups the same stops) in agreement."""
    radius = _nest_radius()
    if radius <= 0:
        return None
    try:
        import s2sphere
        cid = s2sphere.CellId.from_lat_lng(
            s2sphere.LatLng.from_degrees(lat, lng)).parent(17).id()
        try:
            import worlddb
            key = (tuple(worlddb.paths()), radius)
        except Exception:
            key = (None, radius)
        if _anchor_key[0] != key or len(_anchor_cache) > 200_000:
            _anchor_cache.clear()
            _anchor_key[0] = key
        if cid in _anchor_cache:
            return _anchor_cache[cid]
        # measured from the level-17 cell's centre, so every spawn in it agrees
        c = s2sphere.CellId(cid).to_lat_lng()
        clat, clng = c.lat().degrees, c.lng().degrees
        best, bestd = None, None
        for f in _park_forts(clat, clng, radius):
            d = _dist_m(clat, clng, f["lat"], f["lng"])
            if bestd is None or d < bestd:
                best, bestd = (f["lat"], f["lng"]), d
        _anchor_cache[cid] = best
        return best
    except Exception:
        return None


# ---- real park outlines (parks.py) ------------------------------------------
def _min_area():
    try:
        return max(0.0, float(_cfg.get("spawns", "nest_min_area_m2", cast=float)))
    except Exception:
        return 10_000.0


def _share():
    try:
        return float(_cfg.get("spawns", "park_nest_share", cast=float))
    except Exception:
        return 0.67


def park_species(park_id, now_ms=None):
    """The nest species of real park `park_id` this cycle, or 0 if it isn't
    nesting. Same rolls as biomes.park_nest_species, keyed on the park."""
    now_ms = int(time.time() * 1000) if now_ms is None else int(now_ms)
    key = int(park_id) & ((1 << 64) - 1)
    p = period(now_ms)
    roll = biomes._mix(key ^ (p * 0xD6E8FEB86659FD93) ^ 0x5041524B)
    if (roll % 1000) >= int(max(0.0, min(1.0, _share())) * 1000):
        return 0
    pool = biomes.nest_pool() if hasattr(biomes, "nest_pool") else biomes.NEST_SPECIES
    return pool[biomes._mix(key ^ (p * 0x9E3779B97F4A7C15) ^ 0x4E455354) % len(pool)]


def species_at(lat, lng, stop=None, now_ms=None):
    """The nest species a spawn at (lat, lng) may roll, or 0 if it isn't in a
    nest. stop: the (lat, lng) of the park-named stop it belongs to, if any --
    only used where no park pack covers the map."""
    now_ms = int(time.time() * 1000) if now_ms is None else int(now_ms)
    try:
        import parks
        if parks.covered(lat, lng):
            p = parks.park_at(lat, lng)
            if not p or p["area_m2"] < _min_area():
                return 0
            return park_species(p["id"], now_ms)
    except Exception:
        pass
    anc = stop or anchor(lat, lng)
    if not anc:
        return 0
    return biomes.park_nest_species(anc[0], anc[1], now_ms, _rotation_days(), _share())
