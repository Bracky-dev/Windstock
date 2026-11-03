"""
gm071.py -- the battle numbers out of the 2017 game master 0.71 is served
(game_master_071.bin), for damage the 0.71 client agrees with.

The client works out every hit itself from ITS game master: 2017 move power, the
1.2x same-type bonus and the 2017 type chart (1.4 / 0.714 / 0.51). The server used
the 2016 numbers, so the rival's bar dropped by the client's hit and then jumped
back up to the server's smaller one.
"""
import os
import struct

import pb

GM_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "game_master_071.bin")
_DATA = None


def _f32(fields, n, default=0.0):
    for f in fields:
        if f["field"] == n and f["wire"] == 5:
            v = f["value"]
            return struct.unpack("<f", v)[0] if isinstance(v, (bytes, bytearray)) \
                else struct.unpack("<f", struct.pack("<I", v))[0]
    return default


def _floats(fields, n):
    out = []
    for f in fields:
        if f["field"] != n:
            continue
        v = f["value"]
        if f["wire"] == 2:                                   # packed
            out += [x[0] for x in struct.iter_unpack("<f", v)]
        elif f["wire"] == 5:
            out.append(struct.unpack("<f", v)[0] if isinstance(v, (bytes, bytearray))
                       else struct.unpack("<f", struct.pack("<I", v))[0])
    return out


def _load():
    global _DATA
    if _DATA is not None:
        return _DATA
    d = {"moves": {}, "stats": {}, "types": {}, "eff": {}, "stab": 1.2}
    try:
        raw = open(GM_FILE, "rb").read()
    except OSError:
        _DATA = d
        return d
    for t in pb.get_all(pb.decode(raw), 2):
        it = pb.decode(t)
        mv = pb.get(it, 4, pb.WT_LEN)
        if mv:
            m = pb.decode(mv)
            mid = pb.get(m, 1, pb.WT_VARINT) or 0
            d["moves"][mid] = {"power": _f32(m, 4), "type": pb.get(m, 3, pb.WT_VARINT) or 0}
            continue
        ps = pb.get(it, 2, pb.WT_LEN)
        if ps:
            p = pb.decode(ps)
            pid = pb.get(p, 1, pb.WT_VARINT) or 0
            st = pb.decode(pb.get(p, 8, pb.WT_LEN) or b"")
            d["stats"][pid] = (pb.get(st, 2, pb.WT_VARINT) or 0, pb.get(st, 3, pb.WT_VARINT) or 0,
                               pb.get(st, 1, pb.WT_VARINT) or 0)
            d["types"][pid] = tuple(x for x in (pb.get(p, 4, pb.WT_VARINT),
                                                pb.get(p, 5, pb.WT_VARINT)) if x)
            continue
        te = pb.get(it, 8, pb.WT_LEN)
        if te:
            e = pb.decode(te)
            d["eff"][pb.get(e, 2, pb.WT_VARINT) or 0] = _floats(e, 1)
            continue
        bs = pb.get(it, 14, pb.WT_LEN)
        if bs:
            d["stab"] = _f32(pb.decode(bs), 9, 1.2) or 1.2
    _DATA = d
    return d


def damage(atk_pid, atk_stat_iv, atk_cpm, def_pid, def_stat_iv, def_cpm, move_id):
    """One hit by the 0.71 client's formula, or None when the game master lacks the
    move or a species. *_stat_iv = the attacker's attack IV / defender's defense IV."""
    d = _load()
    m = d["moves"].get(move_id)
    sa, sd = d["stats"].get(atk_pid), d["stats"].get(def_pid)
    if not (m and sa and sd):
        return None
    if not m["power"]:
        return 1
    atk = (sa[0] + atk_stat_iv) * atk_cpm
    dfn = (sd[1] + def_stat_iv) * def_cpm
    if dfn <= 0:
        return None
    stab = d["stab"] if m["type"] in d["types"].get(atk_pid, ()) else 1.0
    eff = 1.0
    chart = d["eff"].get(m["type"]) or []
    for t in d["types"].get(def_pid, ()):
        if 0 < t <= len(chart):
            eff *= chart[t - 1]
    return int(0.5 * m["power"] * (atk / dfn) * stab * eff) + 1
