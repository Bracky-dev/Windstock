"""
Google Mobile Maps tiles -- http://mobilemaps.clients.google.com/glm/mmap

This is where the roads come from. The client's map is drawn by Niantic's own
tile layer (nia::map::MapTileManager -> MapTileFetcher -> gmm::TileParser),
which fetches vector tiles from Google's "mmap" endpoint and decodes them with
a protobuf schema compiled into the binary as gmm_tile.pb.cc. Niantic's 2016
API key is long dead, so every one of those requests fails and the ground
renders as flat green -- no roads, no water, no buildings.

Until now the request was not even redirected: mobilemaps.clients.google.com
was missing from the launcher's hostname list, so it went to the real Google
and quietly 4xx'd. It lands here instead now.

What this module does TODAY is capture. Serving OSM roads means writing tiles
in Google's format, and that format is not recoverable by inspection:
gmm_tile.pb.cc is built against protobuf-lite, so there is no embedded
FileDescriptorProto to pull the schema out of (checked -- zero hits for
"gmm_tile.proto" in the binary). Working it out means reading what the client
actually asks for and what TileParser does with the answer, and step one of
that is having the requests on disk.

So: log every request, keep the bodies under data/gmm_captures/, and answer in
a way that does not wedge the client. Set GMM_CAPTURE=0 to stop writing files.
"""
import math
import os
import time

import datadir

CAPTURE_DIR = os.path.join(datadir.DATA_DIR, "gmm_captures")
_MAX_CAPTURES = 200
_seen = [0]


def _capture(method, path, query, body):
    """Keep the raw request. Capped, because the client asks constantly and
    this is a debugging aid, not a log we want eating the container."""
    if os.environ.get("GMM_CAPTURE") == "0":
        return None
    if _seen[0] >= _MAX_CAPTURES:
        return None
    try:
        os.makedirs(CAPTURE_DIR, exist_ok=True)
        if _seen[0] == 0:
            # Count what earlier runs left, so the cap is on the FOLDER and a
            # server that restarts often doesn't add 200 more each time.
            _seen[0] = len(os.listdir(CAPTURE_DIR))
            if _seen[0] >= _MAX_CAPTURES:
                return None
        name = f"{int(time.time() * 1000)}-{_seen[0]:03d}.bin"
        with open(os.path.join(CAPTURE_DIR, name), "wb") as fh:
            fh.write(f"{method} {path}?{query}\n".encode("utf-8", "replace"))
            fh.write(b"----\n")
            fh.write(body or b"")
        _seen[0] += 1
        return name
    except OSError:
        return None


# ---------------------------------------------------------------- request

# The body is not protobuf from byte zero: there is a DriveAbout framing header
# first -- a version word, then 16-bit length-prefixed strings (locale, client
# name, client version, platform), then two tagged blocks. The tile request is
# the second one. Rather than parse the framing exactly, find the protobuf by
# the marker that ends the fixed part, which is stable across every capture.
_PROTO_MARK = b"SYSTEM"


def _varint(b, i):
    v = s = 0
    while i < len(b):
        c = b[i]
        i += 1
        v |= (c & 0x7F) << s
        if not c & 0x80:
            return v, i
        s += 7
    raise ValueError("truncated varint")


def parse_request(body):
    """-> [{"x":, "y":, "z":, "kind":}] for every tile asked for.

    TileRequest { kind=1, x=2, y=3, zoom=4 }, repeated in field 9 of the
    payload. Verified against live captures: zoom is always 17 and x/y are
    ordinary Web Mercator tile numbers -- the same scheme any OSM tile server
    uses, which is what makes serving these from OSM data conceivable at all.
    """
    if not body:
        return []
    mark = body.find(_PROTO_MARK)
    if mark < 0:
        return []
    pb = body[mark + len(_PROTO_MARK) + 6:]      # skip the block header too
    i = 0
    tiles = []
    while i < len(pb):
        try:
            key, i = _varint(pb, i)
        except ValueError:
            break
        fn, wt = key >> 3, key & 7
        if wt == 2:
            try:
                ln, i = _varint(pb, i)
            except ValueError:
                break
            sub, i = pb[i:i + ln], i + ln
            if fn == 9:
                j, d = 0, {}
                try:
                    while j < len(sub):
                        k, j = _varint(sub, j)
                        v, j = _varint(sub, j)
                        d[k >> 3] = v
                except ValueError:
                    continue
                if 2 in d and 3 in d:
                    tiles.append({"kind": d.get(1), "x": d[2], "y": d[3],
                                  "z": d.get(4, 17)})
        elif wt == 0:
            try:
                _, i = _varint(pb, i)
            except ValueError:
                break
        elif wt == 5:
            i += 4
        elif wt == 1:
            i += 8
        else:
            break
    return tiles


# ---------------------------------------------------------------- recolour
# Google's tiles carry their own colours: each tile starts with a style table,
# and every area points into it by index. Since ~2023 Google lays a whole-tile
# "vegetation cover" area (#D3F8E2, mint) over built-up places like Santa
# Monica. Modern Google Maps shows it faintly; the 2016 client paints it solid,
# so whole cities look like one park. Parks proper use #C3F1D5 and keep it.
#
# Wire format, verified on 3,100 live tiles (2026-10-12):
#   response  = u16 version, then blocks: u8 tag, u32 BE length, data.
#               Tag 0x6C holds the MapTileResponseProto.
#   proto     = field 9 repeated { 1: {kind, x, y, zoom}, 2: tile blob }
#   blob      = "DRAT" u16 9, u32 session, u64 cookie, RC4(raw deflate(inner))
#   inner     = "DRAT" u8 ver, varint x, varint y, 0x1A 0x00, u8 n, n x
#               (u16 BE len, copyright), varint nstyles, styles...
#   style     = u8 flags; &1: u8 n, n x ARGB fill; &2: u8 n, n x stroke
#               (ARGB, u8 width, u8 ndash, ndash x u16, u8 flags);
#               &4: 14-byte text style; &8: 11 bytes; &0x10: 7 bytes.
RECOLOR = {bytes.fromhex("ffd3f8e2"): bytes.fromhex("fff8f7f7")}


def _style_fills(inner):
    """Offsets of every fill colour in a decoded tile's style table, or None
    if the table doesn't parse -- in which case the tile is left alone."""
    try:
        if inner[:4] != b"DRAT":
            return None
        i = 5
        _, i = _varint(inner, i)
        _, i = _varint(inner, i)
        if inner[i] != 0x1A:
            return None
        i += 2
        n = inner[i]
        i += 1
        for _ in range(n):
            i += 2 + ((inner[i] << 8) | inner[i + 1])
        ns, i = _varint(inner, i)
        out = []
        for _ in range(ns):
            t = inner[i]
            i += 1
            if t & ~0x1F:
                return None
            if t & 1:
                n = inner[i]
                i += 1
                out.extend(range(i, i + 4 * n, 4))
                i += 4 * n
            if t & 2:
                n = inner[i]
                i += 1
                for _ in range(n):
                    i += 5
                    i += 1 + 2 * inner[i] + 1
            if t & 4:
                i += 14
            if t & 8:
                i += 11
            if t & 0x10:
                i += 7
        if i > len(inner):
            return None
        return out
    except IndexError:
        return None


def _recolor_blob(blob, x, y, z):
    """One tile blob, recoloured, or None if there was nothing to change."""
    import struct
    import zlib
    import gmm_crypt
    if blob[:4] != b"DRAT" or len(blob) < 18:
        return None
    session = struct.unpack(">I", blob[6:10])[0] & 0xFFFF
    cookie = struct.unpack(">Q", blob[10:18])[0]
    try:
        inner = bytearray(zlib.decompress(
            gmm_crypt.crypt(blob[18:], x, y, z, session, cookie), -15))
    except zlib.error:
        return None
    hit = False
    for o in _style_fills(inner) or ():
        new = RECOLOR.get(bytes(inner[o:o + 4]))
        if new:
            inner[o:o + 4] = new
            hit = True
    if not hit:
        return None
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = c.compress(bytes(inner)) + c.flush()
    return blob[:18] + gmm_crypt.crypt(packed, x, y, z, session, cookie)


def _pb_fields(b):
    """[(field, wire, raw bytes of the whole field, value)] -- raw kept so
    untouched fields go back byte for byte."""
    out, i = [], 0
    while i < len(b):
        st = i
        key, i = _varint(b, i)
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v, i = _varint(b, i)
        elif wt == 1:
            v, i = b[i:i + 8], i + 8
        elif wt == 5:
            v, i = b[i:i + 4], i + 4
        elif wt == 2:
            n, i = _varint(b, i)
            v, i = b[i:i + n], i + n
        else:
            raise ValueError("wire type %d" % wt)
        if i > len(b):
            raise ValueError("truncated")
        out.append((fn, wt, b[st:i], v))
    return out


def _enc_varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _recolor_proto(pb):
    """MapTileResponseProto with every tile recoloured; (bytes, n changed)."""
    out, changed = bytearray(), 0
    for fn, wt, raw, v in _pb_fields(pb):
        if fn == 9 and wt == 2:
            sub = _pb_fields(v)
            key = {f: val for f, w, _r, val in sub}
            blob = key.get(2)
            try:
                k = {f: val for f, w, _r, val in _pb_fields(key.get(1) or b"")}
                new = _recolor_blob(blob, k[2], k[3], k[4]) if blob else None
            except (KeyError, ValueError):
                new = None
            if new is not None:
                changed += 1
                body = bytearray()
                for f, w, r, val in sub:
                    body += (b"\x12" + _enc_varint(len(new)) + new) if f == 2 and w == 2 else r
                out += b"\x4a" + _enc_varint(len(body)) + body
                continue
        out += raw
    return bytes(out), changed


def recolor(resp):
    """Google's whole /glm/mmap answer with the recolouring applied. Anything
    that doesn't parse exactly as expected comes back untouched: a tile with
    the old colours beats a broken map."""
    import struct
    try:
        if len(resp) < 2:
            return resp, 0
        out, i, changed = bytearray(resp[:2]), 2, 0
        while i < len(resp):
            tag = resp[i]
            ln = struct.unpack(">I", resp[i + 1:i + 5])[0]
            data = resp[i + 5:i + 5 + ln]
            if len(data) != ln:
                return resp, 0
            if tag == 0x6C:
                data, changed = _recolor_proto(data)
            out += bytes([tag]) + struct.pack(">I", len(data)) + data
            i += 5 + ln
        return bytes(out), changed
    except (ValueError, IndexError, struct.error):
        return resp, 0


# Hop-by-hop and framing headers that must not be copied to Google.
_SKIP = {"host", "content-length", "connection", "keep-alive", "accept-encoding",
         "transfer-encoding", "proxy-connection", "x-ws-device", "x-ws-launcher"}


def proxy(path, query, headers, body, log):
    """Fetch the tiles from Google for the client, recolour, hand them back.

    On the phone this is the local server (or the Online tunnel), which the
    launcher points the map's host at. Our own DNS hooks only redirect the
    GAME's lookups for this host, never the server's, so this reaches Google."""
    import http.client
    hdrs = {k: v for k, v in (headers.items() if headers else ())
            if k.lower() not in _SKIP}
    url = path + ("?" + query if query else "")
    try:
        conn = http.client.HTTPConnection("mobilemaps.clients.google.com", 80, timeout=20)
        conn.request("POST" if body else "GET", url, body=body, headers=hdrs)
        r = conn.getresponse()
        data = r.read()
        ctype = r.getheader("Content-Type") or "application/binary"
        conn.close()
    except (OSError, http.client.HTTPException) as e:
        log(f"[gmm] Google unreachable: {e}")
        return 502, {"Content-Type": "text/plain"}, b"map tiles unavailable"
    if r.status != 200:
        log(f"[gmm] Google said {r.status} ({len(data)} B)")
        return r.status, {"Content-Type": ctype}, data
    t0 = time.time()
    data2, changed = recolor(data)
    if changed:
        log(f"[gmm] recoloured {changed} tile(s), {len(data)} -> {len(data2)} B "
            f"in {time.time() - t0:.2f}s")
    return 200, {"Content-Type": ctype}, data2


def tile_to_latlng(x, y, z):
    n = 2.0 ** z
    lng = x / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    return lat, lng


def handle(method, path, query, headers, body, log):
    """Answer a tile request: fetch it from Google and recolour it (proxy).

    GMM_PROXY=0 brings back the old empty 200, which the client accepts and
    caches (a failure it retries forever) -- a flat green map with no roads.
    """
    if os.environ.get("GMM_PROXY") != "0" and path.startswith("/glm/mmap"):
        return proxy(path, query, headers, body, log)
    name = _capture(method, path, query, body)
    tiles = parse_request(body)
    if tiles:
        zs = {t["z"] for t in tiles}
        xs = [t["x"] for t in tiles]
        ys = [t["y"] for t in tiles]
        z = max(zs)
        lat, lng = tile_to_latlng(sum(xs) / len(xs) + 0.5,
                                  sum(ys) / len(ys) + 0.5, z)
        log(f"[gmm] {len(tiles)} tiles z{sorted(zs)} "
            f"x {min(xs)}-{max(xs)} y {min(ys)}-{max(ys)} "
            f"~({lat:.5f},{lng:.5f})"
            + (f"  saved {name}" if name else ""))
    else:
        log(f"[gmm] {method} {path}  body={len(body or b'')}B (unparsed)"
            + (f"  saved {name}" if name else ""))
    return 200, {"Content-Type": "application/binary"}, b""
