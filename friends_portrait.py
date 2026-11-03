"""Head-and-shoulders pictures of a trainer as they REALLY look, for the Friends screens.

friends_art/trainer/ holds layers rendered offline from the 0.35 client's own avatar
mesh and outfit textures (work/tools/trainer_portraits.py): one premultiplied RGBA
layer per gender, slot and option, already lit. The mesh never changes with the
outfit, so a look is just the sum of one layer per slot -- done here in pure
Python (the phone's embedded server has no numpy/PIL) and cached per look.

  key(look)  -> "m.1.1.1.0.1.1" style id for a saved look (world.owner_avatar)
  png(key)   -> the PNG bytes, or None for a malformed key
"""
import json
import os
import struct
import threading
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.join(HERE, "friends_art", "trainer")

# What a never-customised trainer looks like (protocol.build_player_avatar).
DEFAULT = {"gender": 0, "skin": 1, "hair": 1, "shirt": 1, "pants": 1, "hat": 0,
           "shoes": 1, "eyes": 1, "backpack": 1}
# key order; only the slots that show in a head-and-shoulders picture
KEY_SLOTS = ("skin", "hair", "shirt", "pants", "hat", "eyes", "backpack")

_lock = threading.Lock()
_index = None
_layers = {}
_cache = {}
CACHE_MAX = 400


def _load_index():
    global _index
    if _index is None:
        try:
            with open(os.path.join(DIR, "index.json"), encoding="utf-8") as fh:
                _index = json.load(fh)
        except (OSError, ValueError):
            _index = {}
    return _index


def available():
    return bool(_load_index())


def key(look):
    """Stable id of the picture for a saved look ({} = the default trainer).
    0.35 sends the avatar type as 0 = male, 1 = female."""
    look = look or {}
    def v(name):
        try:
            return max(0, int(look.get(name, DEFAULT[name])))
        except (TypeError, ValueError):
            return DEFAULT[name]
    g = "f" if look and v("gender") == 1 else "m"
    return g + "." + ".".join(str(v(s)) for s in KEY_SLOTS)


def _layer(g, slot, opt):
    k = (g, slot, opt)
    if k not in _layers:
        try:
            with open(os.path.join(DIR, f"{g}_{slot}_{opt}.bin"), "rb") as fh:
                _layers[k] = zlib.decompress(fh.read())
        except (OSError, zlib.error):
            _layers[k] = None
    return _layers[k]


def _png(size, rgba):
    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    row = size * 4
    raw = b"".join(b"\x00" + rgba[y * row:(y + 1) * row] for y in range(size))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def png(k):
    idx = _load_index()
    if not idx:
        return None
    parts = str(k or "").split(".")
    if len(parts) != 1 + len(KEY_SLOTS) or parts[0] not in ("m", "f") \
            or not all(p.isdigit() and len(p) < 3 for p in parts[1:]):
        return None
    k = ".".join(parts)
    with _lock:
        if k in _cache:
            return _cache[k]
        g = parts[0]
        opts = dict(zip(KEY_SLOTS, (int(p) for p in parts[1:])))
        size = int(idx["size"])
        acc = None
        for slot in idx["slots"]:
            s = slot.lower()
            have = idx[g].get(slot) or []
            if not have:
                continue                     # out of frame (shoes)
            opt = opts.get(s, 0)
            if opt not in have:
                opt = have[0]                 # an index the client has no art for: first one
            lay = _layer(g, s, opt)
            if lay is None:
                continue
            if acc is None:
                acc = list(lay)
            else:
                acc = [a + b for a, b in zip(acc, lay)]
        if acc is None:
            return None
        # layers are premultiplied; un-premultiply for the PNG
        out = bytearray(len(acc))
        for i in range(0, len(acc), 4):
            a = acc[i + 3]
            if a <= 0:
                continue
            if a >= 255:
                out[i:i + 4] = bytes((min(255, acc[i]), min(255, acc[i + 1]), min(255, acc[i + 2]), 255))
            else:
                out[i] = min(255, acc[i] * 255 // a)
                out[i + 1] = min(255, acc[i + 1] * 255 // a)
                out[i + 2] = min(255, acc[i + 2] * 255 // a)
                out[i + 3] = a
        data = _png(size, bytes(out))
        if len(_cache) >= CACHE_MAX:
            _cache.clear()
        _cache[k] = data
        return data


def url_for(look):
    """/friends/trainer/<key>.png for a saved look (a save's "avatar"), None without the art."""
    if not available():
        return None
    # the art version is in the path: phones cache these pictures on disk by path
    idx = _load_index()
    return f"/friends/trainer/{idx.get('version') or idx.get('size', 0)}/" + key(look if isinstance(look, dict) else {}) + ".png"
