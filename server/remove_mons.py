"""Remove every Pokemon of the given species numbers from a save. Run with the server STOPPED:

    sudo python3 remove_mons.py 248 [more ids...] [--login Raid]

This build only has models for #1-151; anything above crashes the game when drawn.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
login = "Raid"
if "--login" in args:
    i = args.index("--login")
    login = args[i + 1]
    del args[i:i + 2]
ids = {int(a) for a in args}
path = os.path.join(HERE, "data", "saves", login.lower() + ".json")
if subprocess.run(["pgrep", "-f", "run.py"], capture_output=True).stdout.strip():
    sys.exit("The server is running -- stop it first (Ctrl+C), then run this again.")
if not ids or not os.path.isfile(path):
    sys.exit("usage: sudo python3 remove_mons.py 248 [ids...] [--login Raid]")
d = json.load(open(path))
before = len(d["caught"])
d["caught"] = [c for c in d["caught"] if c["pokemon_id"] not in ids]
for i in ids:
    d["pokedex"].pop(str(i), None)
json.dump(d, open(path, "w"), indent=1)
print(f"{login}: removed {before - len(d['caught'])}, now {len(d['caught'])} Pokemon")
