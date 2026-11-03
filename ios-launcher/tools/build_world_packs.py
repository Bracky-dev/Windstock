#!/usr/bin/env python3
"""
Build downloadable world packs -- one per country -- and the catalog the
launcher's World Data screen reads.

    tools/build_world_packs.py [--out DIR] SPEC [SPEC ...]

SPEC is one of

    "Austria=europe/austria:path/to/osm_forts.austria.json"
        pack forts you already have as JSON (optionally ":biomes.json" too);

    "Germany=europe/germany"
        download the Geofabrik extract and pull the forts out of it with the
        same code the desktop World Manager uses (fetch_pois_pbf.py). Needs
        pyosmium on this Mac: `pip3 install osmium`. Extracts are big --
        Germany is ~4 GB -- and cached, so a rebuild does not re-download.

Writes DIR/<id>.sqlite for each, and DIR/catalog.json listing them with size
and SHA-256. Upload the whole directory to any static host (GitHub Releases
takes files up to 2 GB) and put catalog.json's URL in the launcher under
Settings > World Data. Pack URLs in the catalog are relative, so the files
just have to sit next to it.

Why packs are built here and not on the phone: the parser is osmium, which has
no iOS build, and the source extracts are gigabytes. The phone only ever
downloads the finished, cell-indexed file.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.abspath(os.path.join(HERE, "..", "..", "work", "server"))


def _builder():
    spec = importlib.util.spec_from_file_location(
        "build_world_db", os.path.join(HERE, "build_world_db.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _from_geofabrik(region):
    sys.path[:0] = [SERVER, os.path.join(SERVER, "vendor")]
    try:
        import fetch_pois_pbf as pf
    except ImportError as exc:
        sys.exit(f"cannot build {region} from Geofabrik: {exc}\n"
                 f"install the parser first:  pip3 install osmium")
    print(f"    downloading / reading {region} extract")
    forts, scanned = pf._extract(pf._download(region))
    print(f"    {scanned:,} OSM objects scanned")
    return forts


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", default=os.path.join(HERE, "..", "build", "world-packs"))
    ap.add_argument("specs", nargs="+", metavar="SPEC")
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    catalog_path = os.path.join(out, "catalog.json")
    try:
        with open(catalog_path, encoding="utf-8") as fh:
            catalog = json.load(fh)
    except (OSError, ValueError):
        catalog = {"version": 1, "packs": []}
    by_id = {p["id"]: p for p in catalog.get("packs", [])}

    build = _builder().build
    for spec in args.specs:
        if "=" not in spec:
            sys.exit(f"bad SPEC {spec!r}: expected Name=region[:forts.json[:biomes.json]]")
        name, rest = spec.split("=", 1)
        region, *files = rest.split(":")
        pid = _slug(name)
        print(f"==> {name} ({region})")
        dest = os.path.join(out, pid + ".sqlite")
        if files:
            stats = build(dest, files[0], files[1] if len(files) > 1 else None,
                          name, region)
        else:
            stats = build(dest, None, None, name, region,
                          forts=_from_geofabrik(region))
        if not stats["forts"]:
            print(f"    no forts for {name}; not adding it to the catalog")
            os.remove(dest)
            continue
        by_id[pid] = {
            "id": pid,
            "name": name,
            "region": region,
            "file": pid + ".sqlite",                 # relative to catalog.json
            "bytes": os.path.getsize(dest),
            "sha256": _sha256(dest),
            "forts": stats["forts"],
            "gyms": stats["gyms"],
            "biomes": stats["biome_cells"] > 0,
            "bbox": stats["bbox"],                   # [south, west, north, east]
            "built": time.strftime("%Y-%m-%d"),
        }

    catalog["version"] = 1
    catalog["built"] = time.strftime("%Y-%m-%d %H:%M:%S")
    catalog["packs"] = sorted(by_id.values(), key=lambda p: p["name"])
    with open(catalog_path, "w", encoding="utf-8") as fh:
        json.dump(catalog, fh, indent=1)
    print(f"\ncatalog: {len(catalog['packs'])} pack(s) -> {catalog_path}")
    for p in catalog["packs"]:
        print(f"  {p['name']:<16} {p['forts']:>9,} forts  {p['bytes'] / 1e6:7.1f} MB")


if __name__ == "__main__":
    main()
