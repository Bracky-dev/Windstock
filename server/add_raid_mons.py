"""Give the Raid account 100 strong Pokemon. Run with the server STOPPED:

    sudo python3 add_raid_mons.py [login]     (default: Raid)

The save is root-owned (the server runs as root), so it needs sudo. The server holds
saves in memory and would overwrite this, so it refuses to run while run.py is up.
"""
import json
import os
import random
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
login = sys.argv[1] if len(sys.argv) > 1 else "Raid"
path = os.path.join(HERE, "data", "saves", login.lower() + ".json")

if subprocess.run(["pgrep", "-f", "run.py"], capture_output=True).stdout.strip():
    sys.exit("The server is running -- stop it first (Ctrl+C), then run this again.")
if not os.path.isfile(path):
    sys.exit(f"No save at {path}")

# (pokemon_id, cp) -- strong raid attackers; cycled to make 100
POOL = [(149, 2167), (143, 2048), (130, 2400), (134, 2300), (68, 2200), (59, 2250),
        (65, 2000), (94, 2100), (131, 2150), (112, 2350), (6, 2100), (9, 2050),
        (3, 2000), (103, 2100), (136, 2300), (135, 2250), (76, 2150), (142, 2050),
        (150, 3000), (144, 2800)]

with open(path) as f:
    d = json.load(f)
now = int(time.time() * 1000)
for i in range(100):
    pid, cp = POOL[i % len(POOL)]
    d["caught"].append({"uid": random.getrandbits(62) | 1, "pokemon_id": pid,
                        "cp": cp + random.randint(-80, 80), "caught_ms": now,
                        "pokeball": 1, "gift": "admin"})
    d["pokedex"].setdefault(str(pid), [1, 1])
d["max_pokemon"] = max(d.get("max_pokemon", 250), len(d["caught"]) + 50)

with open(path + ".bak", "w") as f:
    json.dump(json.load(open(path)), f)
with open(path, "w") as f:
    json.dump(d, f, indent=1)
print(f"{login}: now {len(d['caught'])} Pokemon (backup: {path}.bak)")
