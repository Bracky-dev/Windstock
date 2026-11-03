"""
Real park outlines -- "which park is (lat, lng) in?"

Park packs are built on the Mac by tools/fetch_parks.py (one per region, from
the same Geofabrik extracts as the world packs) and live in <data dir>/parks/.
They are kept apart from data/world/ so the fort/biome packs, and every phone
that downloads them, are untouched.

Each pack rasterises OSM park polygons onto S2 cells: level 17 (~75 m) for
normal parks, 15 / 13 for big ones. A lookup checks the point's level-17 cell,
then its level-15 and level-13 parents -- one indexed query each, per pack --
and the answer is cached per level-17 cell.

covered(lat, lng) says whether ANY park pack covers the point. Where none does,
callers fall back to the old guess from stop names.
"""
import glob
import json
import os
import sqlite3
import threading
from urllib.request import pathname2url

import datadir

_HERE = os.path.dirname(os.path.abspath(__file__))
_local = threading.local()
_lock = threading.Lock()
_meta = {}               # (path, mtime) -> {"bbox": [[s, w, n, e], ...]}
_cache = {}              # level-17 cell id -> park dict or None
_cache_key = [None]
LEVELS = (17, 15, 13)


def _dirs():
    return [os.path.join(datadir.ensure(), "parks"), os.path.join(_HERE, "parks")]


def paths():
    out, seen = [], set()
    for d in _dirs():
        for p in sorted(glob.glob(os.path.join(d, "*.sqlite"))):
            real = os.path.realpath(p)
            if real not in seen:
                seen.add(real)
                out.append(p)
    return out


def _mtime(p):
    try:
        return os.path.getmtime(p)
    except OSError:
        return None


def _conn(p):
    conns = getattr(_local, "conns", None)
    if conns is None:
        conns = _local.conns = {}
    key = (p, _mtime(p))
    c = conns.get(key)
    if c is None:
        for k in [k for k in conns if k[0] == p]:
            try:
                conns.pop(k).close()
            except sqlite3.Error:
                pass
        c = sqlite3.connect(f"file:{pathname2url(p)}?mode=ro&immutable=1",
                            uri=True, check_same_thread=False)
        conns[key] = c
    return c


def _s64(cell_id):
    cell_id = int(cell_id)
    return cell_id - (1 << 64) if cell_id >= (1 << 63) else cell_id


def _boxes(p):
    key = (p, _mtime(p))
    with _lock:
        hit = _meta.get(key)
    if hit is not None:
        return hit
    try:
        row = _conn(p).execute("SELECT value FROM meta WHERE key = 'bbox'").fetchone()
        boxes = json.loads(row[0]) if row else []
    except (sqlite3.Error, ValueError):
        boxes = []
    with _lock:
        _meta[key] = boxes
    return boxes


def available():
    return bool(paths())


def covered(lat, lng):
    """True when some park pack's extract contains (lat, lng) -- there, a point
    in no park really is outside every park."""
    for p in paths():
        for s, w, n, e in _boxes(p):
            if s <= lat <= n and w <= lng <= e:
                return True
    return False


def _row(c, pid):
    r = c.execute("SELECT id, name, lat, lng, area_m2 FROM parks WHERE id = ?",
                  (pid,)).fetchone()
    if not r:
        return None
    return {"id": int(r[0]), "name": r[1] or "Unnamed park", "lat": r[2], "lng": r[3],
            "area_m2": int(r[4] or 0)}


def park_at(lat, lng):
    """{"id", "name", "lat", "lng", "area_m2"} of the park at (lat, lng), or None."""
    ps = paths()
    if not ps:
        return None
    try:
        import s2sphere
        leaf = s2sphere.CellId.from_lat_lng(s2sphere.LatLng.from_degrees(lat, lng))
    except Exception:
        return None
    c17 = leaf.parent(17)
    key = tuple((p, _mtime(p)) for p in ps)
    with _lock:
        if _cache_key[0] != key or len(_cache) > 300_000:
            _cache.clear()
            _cache_key[0] = key
        if c17.id() in _cache:
            return _cache[c17.id()]
    found = None
    for lvl in LEVELS:                       # finest first: a city park beats a reserve
        cid = _s64(leaf.parent(lvl).id())
        best = None                          # packs overlap at borders: lowest rank wins
        for p in ps:
            try:
                c = _conn(p)
                r = c.execute("SELECT park, rank FROM park_cells WHERE cell = ?",
                              (cid,)).fetchone()
            except sqlite3.Error:
                continue
            if r and (best is None or r[1] < best[1]):
                best = (r[0], r[1], c)
        if best:
            found = _row(best[2], best[0])
            if found:
                break
    with _lock:
        _cache[c17.id()] = found
    return found


def near(lat, lng, radius_m, min_area_m2=0, limit=50):
    """Parks whose middle is within radius_m: [{id, name, lat, lng, area_m2,
    distance_m}], nearest first."""
    import math
    dlat = radius_m / 111_320.0
    cosl = max(0.2, math.cos(math.radians(lat)))
    dlng = radius_m / (111_320.0 * cosl)
    out, seen = [], set()
    for p in paths():
        try:
            rows = _conn(p).execute(
                "SELECT id, name, lat, lng, area_m2 FROM parks WHERE lat BETWEEN ? AND ? "
                "AND lng BETWEEN ? AND ? AND area_m2 >= ?",
                (lat - dlat, lat + dlat, lng - dlng, lng + dlng, int(min_area_m2))).fetchall()
        except sqlite3.Error:
            continue
        for r in rows:
            if r[0] in seen:
                continue
            seen.add(r[0])
            d = math.hypot((r[2] - lat) * 111_320.0, (r[3] - lng) * 111_320.0 * cosl)
            if d <= radius_m:
                out.append({"id": int(r[0]), "name": r[1] or "Unnamed park", "lat": r[2],
                            "lng": r[3], "area_m2": int(r[4] or 0), "distance_m": int(d)})
    out.sort(key=lambda x: x["distance_m"])
    return out[:limit]
