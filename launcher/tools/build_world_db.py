#!/usr/bin/env python3
"""
Pack the OSM world data into world.sqlite, indexed by S2 cell.

    tools/build_world_db.py <server-data-dir> <out.sqlite>

Reads osm_forts.json and osm_biomes.json and writes one read-only database
that work/server/worlddb.py queries per cell. Done here, on the Mac, because
json.load of those files costs ~1.6 GB of heap -- fine on a desktop, fatal on a
phone that is also running the game. See worlddb.py for the measurements.
"""
import json
import os
import sqlite3
import sys
import time


def s64(cell_id):
    cell_id = int(cell_id)
    return cell_id - (1 << 64) if cell_id >= (1 << 63) else cell_id


def main(data_dir, out, name="", region=""):
    """Everything in <data_dir> -- what stage_server.sh bundles into the app."""
    return build(out, os.path.join(data_dir, "osm_forts.json"),
                 os.path.join(data_dir, "osm_biomes.json"), name, region)


def build(out, forts_path=None, biomes_path=None, name="", region="", forts=None):
    """One pack. `forts` may be passed in directly (a list of fort dicts, as
    fetch_pois_pbf._extract returns) instead of a JSON path. Returns
    {"forts", "gyms", "biome_cells", "bbox"}."""
    import s2sphere

    t0 = time.time()
    tmp = out + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    db.executescript("""
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE forts (cell INTEGER NOT NULL, id TEXT, lat REAL, lng REAL,
                            kind INTEGER, name TEXT, image TEXT);
        CREATE TABLE biome_cells (cell INTEGER PRIMARY KEY, biome TEXT)
            WITHOUT ROWID;
    """)

    n_forts = n_gyms = 0
    bbox = None
    if forts is None and forts_path and os.path.isfile(forts_path):
        with open(forts_path, encoding="utf-8") as fh:
            forts = json.load(fh).get("forts") or []
    if forts:
        rows = []
        for f in forts:
            try:
                lat, lng = float(f["lat"]), float(f["lng"])
                cell = f.get("cell")
                cell = int(cell) if cell else s2sphere.CellId.from_lat_lng(
                    s2sphere.LatLng.from_degrees(lat, lng)).parent(15).id()
                rows.append((s64(cell), str(f["id"]), lat, lng,
                             1 if f.get("kind") == "gym" else 0,
                             str(f.get("name", ""))[:40] or None,
                             str(f.get("image", ""))[:300] or None))
            except (KeyError, TypeError, ValueError):
                continue
        del forts
        db.executemany("INSERT INTO forts VALUES (?,?,?,?,?,?,?)", rows)
        n_forts = len(rows)
        n_gyms = sum(1 for r in rows if r[4])
        if rows:
            bbox = [min(r[2] for r in rows), min(r[3] for r in rows),
                    max(r[2] for r in rows), max(r[3] for r in rows)]
        del rows
        db.execute("CREATE INDEX forts_cell ON forts(cell)")
        print(f"    forts: {n_forts:,} ({n_gyms:,} gyms)")
    else:
        print(f"    no forts ({forts_path or 'none given'})")

    n_cells, level, points = 0, 12, []
    if biomes_path and os.path.isfile(biomes_path):
        with open(biomes_path, encoding="utf-8") as fh:
            d = json.load(fh)
        level = int(d.get("cell_level", 12))
        db.executemany("INSERT INTO biome_cells VALUES (?,?)",
                       ((s64(k), str(v)) for k, v in (d.get("cells") or {}).items()))
        n_cells = db.execute("SELECT COUNT(*) FROM biome_cells").fetchone()[0]
        points = [[float(p["lat"]), float(p["lng"]), str(p["biome"])]
                  for p in (d.get("points") or [])]
        print(f"    biome cells: {n_cells:,} (level {level}), points: {len(points)}")
    else:
        print("    no biome data (biomes fall back to the deterministic hash)")

    db.executemany("INSERT INTO meta VALUES (?,?)", [
        ("name", name),
        ("region", region),
        ("fort_count", str(n_forts)),
        ("biome_count", str(n_cells)),
        ("biome_level", str(level)),
        ("terrain_points", json.dumps(points)),
        ("built", time.strftime("%Y-%m-%d %H:%M:%S")),
    ])
    db.commit()
    db.execute("VACUUM")
    db.close()
    os.replace(tmp, out)
    print(f"    {os.path.getsize(out) / 1e6:.1f} MB in {time.time() - t0:.0f}s -> {out}")
    return {"forts": n_forts, "gyms": n_gyms, "biome_cells": n_cells, "bbox": bbox}


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
