"""
port_bundles071.py -- make the 2016 Pokemon model bundles render in the 0.71 client.

The genuine pm#### bundles were built with Unity 5.3.5 and carry their shaders inside
(Niantic/BRDF/UBER, the Holo particle shaders, Mobile/* fallbacks) in 5.3's serialized
shader format. 0.71 runs Unity 5.5.1, which can't use them, so every model renders
magenta. 0.71 ships the same shaders, already in 5.5 form, in its own
sharedassets0.assets. This swaps each bundle's shaders for those:

  1. decrypt assets/pm#### with its genuine digest key
  2. replace the Shader type in the bundle's type list with the 5.5.1 one (UnityPy's
     type database + the hash from 0.71's file) and each Shader object's data with the
     0.71 shader of the same name (Mobile/VertexLit and Mobile/Diffuse are fallbacks
     only and not in 0.71: they become Niantic/BRDF/Basic). Shader dependencies
     (fallback pointers into the 0.71 file) are dropped.
  3. pack (same compression as the original), encrypt with a fresh key in the client's container format
       [0x01][IV][AES-128-CBC(PKCS7)][HMAC-SHA1]   key = digest key XOR KEY_MASK
     checksum = CRC-32C(encrypted file)
  4. write assets071/pm#### and merge them into assets071/asset_digest, which the server
     serves to clients >= 0.70 (protocol.asset_platform). 0.29-0.63 keep the originals.

Usage:
  python3 port_bundles071.py [--data <0.71 assets/bin/Data>] [pm0001 pm0025 ...]
Requires: UnityPy, pycryptodome, crcmod. Uses work/tools/unitypy_fix.py from the
private-server project (WS_TOOLS overrides its location).
"""
import argparse
import copy
import glob
import hashlib
import hmac
import os
import re
import sys
import time
import uuid

import crcmod.predefined
import UnityPy
from Crypto.Cipher import AES
from UnityPy.helpers.Tpk import get_typetree_node

import pb

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.environ.get("WS_TOOLS", os.path.expanduser(
    "~/Desktop/Pokemon go private server/work/tools"))
sys.path.insert(0, TOOLS)
import unitypy_fix  # noqa: E402,F401  -- keep per-object script indices on save

SRC_ASSETS = os.path.join(HERE, "assets")
OUT_ASSETS = os.path.join(HERE, "assets071")
DATA071 = os.path.join(HERE, "..", "translator071", "cache", "unity-data",
                       "assets", "bin", "Data")
KEY_MASK = b"\x50\x46\x41\x69\x24\x3B\x5D\x47\x37\x52\x67\x3E\x6B\x7A\x34\x77"
FALLBACK = {"Mobile/VertexLit": "Niantic/BRDF/Basic", "Mobile/Diffuse": "Niantic/BRDF/Basic"}
CID_SHADER = 48
_crc32c = crcmod.predefined.mkCrcFun("crc-32c")


def aes_key(key16):
    return bytes(a ^ b for a, b in zip(key16, KEY_MASK))


def decrypt(enc, key16):
    pt = AES.new(aes_key(key16), AES.MODE_CBC, enc[1:17]).decrypt(enc[17:-20])
    return pt[:-pt[-1]]


def encrypt(plain, key16):
    iv = os.urandom(16)
    pad = 16 - len(plain) % 16
    body = b"\x01" + iv + AES.new(aes_key(key16), AES.MODE_CBC, iv).encrypt(
        plain + bytes([pad]) * pad)
    return body + hmac.new(aes_key(key16), body, hashlib.sha1).digest()


def genuine_digest():
    """[(name, key16)] from assets/asset_digest, in digest order."""
    data = open(os.path.join(SRC_ASSETS, "asset_digest"), "rb").read()
    out = []
    for raw in pb.get_all(pb.decode(data), 1):
        e = pb.decode(raw)
        out.append((pb.get(e, 2, pb.WT_LEN).decode(), pb.get(e, 6, pb.WT_LEN)))
    return out


def load_shaders071(data_dir, tmp):
    """{shader name: typetree dict}, type hash, 5.5.1 Shader node from 0.71's
    sharedassets0.assets (shipped as .split0..N)."""
    splits = sorted(glob.glob(os.path.join(data_dir, "sharedassets0.assets.split*")),
                    key=lambda p: int(p.rsplit("split", 1)[1]))
    path = os.path.join(tmp, "sharedassets0.assets")
    with open(path, "wb") as fh:
        for p in splits:
            fh.write(open(p, "rb").read())
    sf = list(UnityPy.load(path).files.values())[0]
    shaders, type_hash = {}, None
    for o in sf.objects.values():
        if o.type.name == "Shader":
            d = o.read_typetree()
            shaders.setdefault(d["m_ParsedForm"]["m_Name"], d)
            type_hash = o.serialized_type.old_type_hash
    node = get_typetree_node(CID_SHADER, sf.version)
    for i, n in enumerate(node.traverse()):       # TPK nodes lack the blob-only fields
        n.m_Index = i
        n.m_TypeFlags = n.m_TypeFlags if n.m_TypeFlags is not None else int(n.m_Type == "Array")
        n.m_MetaFlag = n.m_MetaFlag or 0
        n.m_RefTypeHash = n.m_RefTypeHash or 0
        n.m_VariableCount = n.m_VariableCount or 0
    os.remove(path)
    return shaders, type_hash, node


def old_shader_name(obj):
    s = obj.read_typetree()["m_Script"]
    s = s.decode("latin1") if isinstance(s, (bytes, bytearray)) else s
    m = re.search(r'Shader\s+"([^"]+)"', s)
    return m.group(1) if m else None


def port(plain, shaders, type_hash, node, tmp):
    path = os.path.join(tmp, f"port.{os.getpid()}.bundle")
    open(path, "wb").write(plain)
    try:
        bundle = list(UnityPy.load(path).files.values())[0]
        sf = list(bundle.files.values())[0]
        objs = [o for o in sf.objects.values() if o.type.name == "Shader"]
        names = {o.path_id: old_shader_name(o) for o in objs}
        types = {id(t): t for t in [o.serialized_type for o in objs]
                 + [t for t in sf.types if t.class_id == CID_SHADER]}
        for t in types.values():
            t.node, t.old_type_hash = node, type_hash
        swapped = []
        for o in objs:
            name = FALLBACK.get(names[o.path_id], names[o.path_id])
            if name not in shaders:
                name = "Niantic/BRDF/Basic"
            d = copy.deepcopy(shaders[name])
            d["m_Dependencies"] = []
            o.save_typetree(d, nodes=node)
            swapped.append(name)
        return bundle.save(packer="original"), swapped
    finally:
        os.remove(path)


def encrypt_entry(name, packed):
    """Encrypt a packed bundle with a fresh key into assets071/<name>; its digest entry."""
    key = os.urandom(16)
    enc = encrypt(packed, key)
    assert decrypt(enc, key) == packed
    open(os.path.join(OUT_ASSETS, name), "wb").write(enc)
    ts = int(time.time() * 1_000_000)
    return {"asset_id": f"{uuid.uuid4()}/{ts}", "name": name, "version": ts,
            "checksum": _crc32c(enc) & 0xFFFFFFFF, "size": len(enc), "key": key}


def read_digest():
    """{name: entry} from assets071/asset_digest ({} if none yet)."""
    path = os.path.join(OUT_ASSETS, "asset_digest")
    if not os.path.isfile(path):
        return {}
    out = {}
    for raw in pb.get_all(pb.decode(open(path, "rb").read()), 1):
        e = pb.decode(raw)
        name = pb.get(e, 2, pb.WT_LEN).decode()
        out[name] = {"asset_id": pb.get(e, 1, pb.WT_LEN).decode(), "name": name,
                     "version": pb.get(e, 3, pb.WT_VARINT), "checksum": pb.get(e, 4, pb.WT_32),
                     "size": pb.get(e, 5, pb.WT_VARINT), "key": pb.get(e, 6, pb.WT_LEN)}
    return out


def merge_digest(entries):
    """Write assets071/asset_digest = existing entries with these replaced/added, under a
    new timestamp (so clients re-fetch it). Returns the timestamp."""
    digest = read_digest()
    digest.update({e["name"]: e for e in entries})
    ts = int(time.time() * 1_000_000)
    w = pb.Writer()
    for e in digest.values():
        w.message(1, pb.Writer().string(1, e["asset_id"]).string(2, e["name"])
                  .uint(3, e["version"]).fixed32(4, e["checksum"]).uint(5, e["size"])
                  .bytes_(6, e["key"]))
    w.uint(2, ts)
    open(os.path.join(OUT_ASSETS, "asset_digest"), "wb").write(w.to_bytes())
    return ts


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=DATA071)
    ap.add_argument("names", nargs="*")
    a = ap.parse_args(argv)
    os.makedirs(OUT_ASSETS, exist_ok=True)
    tmp = os.path.join(OUT_ASSETS, ".tmp")
    os.makedirs(tmp, exist_ok=True)
    shaders, type_hash, node = load_shaders071(a.data, tmp)
    print(f"{len(shaders)} shaders from 0.71")
    entries = []
    for name, key in genuine_digest():
        if a.names and name not in a.names:
            continue
        plain = decrypt(open(os.path.join(SRC_ASSETS, name), "rb").read(), key)
        packed, swapped = port(plain, shaders, type_hash, node, tmp)
        entries.append(encrypt_entry(name, packed))
        print(f"{name}: {len(plain)} -> {entries[-1]['size']} B, "
              f"shaders {sorted(set(swapped))}", flush=True)
    ts = merge_digest(entries)
    os.rmdir(tmp)
    print(f"wrote {len(entries)} bundles + asset_digest (ts {ts}) to {OUT_ASSETS}")


if __name__ == "__main__":
    main(sys.argv[1:])
