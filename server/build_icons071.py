"""
build_icons071.py -- pokemon_icon_NNN bundles for the 0.71 client, from 8-bit sprites.

0.71 draws Pokemon portraits (battle party, gym defenders, Pokemon list, Pokedex) from
downloaded AssetBundles: PokemonIconBundleName = "pokemon_icon_{0:000}", asset
"pokemon_icon_{0:000}" + "_{0:00}" (form/costume) + "_shiny". We have no 2017 icon bundles,
so this builds one per species from the 8-bit sprites (work/mods/8bit-sprites/sprites,
32x32 PNGs):

  * base = a genuine 2016 bundle (pm0001, Unity 5.3.5 with type trees -- 0.71 loads those
    fine, see port_bundles071.py), emptied
  * Texture2D 32x32 RGBA32, point filtered, + a Sprite that is a full-rect quad on it,
    shaped exactly like the Sprites the 8-bit mod writes into 0.35's sharedassets0
    (whose Sprite type and hash we copy)
  * AssetBundle "pokemon_icon_NNN" listing the sprite under every name 0.71 may ask for
    (plain, _00.._05, each also _shiny -- shinies fall back to the normal sprite)
  * encrypted with a fresh key and added to assets071/asset_digest

Usage: python3 build_icons071.py [--sprites DIR] [--mod-assets FILE] [1 25 ...]
"""
import argparse
import copy
import hashlib
import os
import sys

import UnityPy
from PIL import Image
from UnityPy.helpers.Tpk import get_typetree_node

import port_bundles071 as P  # also puts work/tools (unitypy_fix) on the path

MOD = os.path.expanduser("~/Desktop/Pokemon go private server/work/mods/8bit-sprites")
CID_TEXTURE2D, CID_SPRITE, CID_ASSETBUNDLE = 28, 213, 142
AB, TEX, SPRITE = 1, 2, 3
SIZE = 32
PPU = SIZE / 2.56                 # same on-screen size as the stock 256 px @ 100 px/unit
VARIANTS = [""] + [f"_{i:02d}" for i in range(6)]


def fixed_node(class_id, version):
    node = get_typetree_node(class_id, version)
    for i, n in enumerate(node.traverse()):       # TPK nodes lack the blob-only fields
        n.m_Index = i
        n.m_TypeFlags = n.m_TypeFlags if n.m_TypeFlags is not None else int(n.m_Type == "Array")
        n.m_MetaFlag = n.m_MetaFlag or 0
        n.m_RefTypeHash = n.m_RefTypeHash or 0
        n.m_VariableCount = n.m_VariableCount or 0
    return node


def sprite_template(mod_assets):
    """(Sprite typetree dict, Sprite SerializedType) from the 8-bit mod's sharedassets0."""
    sf = list(UnityPy.load(mod_assets).files.values())[0]
    for o in sf.objects.values():
        if o.type.name == "Sprite":
            d = o.read_typetree()
            if d["m_Name"] == "pokemon_icon_001":
                return d, o.serialized_type
    raise SystemExit("no pokemon_icon_001 sprite in " + mod_assets)


def clone(src, pid, class_id, sf, stype):
    c = copy.copy(src)
    c.path_id, c.class_id, c.type_id, c.assets_file = pid, class_id, class_id, sf
    c.serialized_type = stype
    return c


def build(num, png, base_plain, sprite_tpl, sprite_stype, tmp):
    name = f"pokemon_icon_{num:03d}"
    path = os.path.join(tmp, f"icon.{os.getpid()}.bundle")
    open(path, "wb").write(base_plain)
    try:
        bundle = list(UnityPy.load(path).files.values())[0]
        sf = list(bundle.files.values())[0]
        objs = list(sf.objects.values())
        tex_src = next(o for o in objs if o.type.name == "Texture2D")
        ab_src = next(o for o in objs if o.type.name == "AssetBundle")
        tex_type, ab_type = tex_src.serialized_type, ab_src.serialized_type

        spr_type = copy.copy(tex_type)
        spr_type.class_id = CID_SPRITE
        spr_type.node = fixed_node(CID_SPRITE, sf.version)
        spr_type.old_type_hash = sprite_stype.old_type_hash
        spr_type.script_type_index = -1
        sf.types = [ab_type, tex_type, spr_type]

        img = Image.open(png).convert("RGBA").resize((SIZE, SIZE), Image.NEAREST)
        tex = clone(tex_src, TEX, CID_TEXTURE2D, sf, tex_type)
        t = tex_src.read_typetree()
        t.update({"m_Name": name, "m_Width": SIZE, "m_Height": SIZE,
                  "m_CompleteImageSize": SIZE * SIZE * 4, "m_TextureFormat": 4,  # RGBA32
                  "m_MipCount": 1, "m_IsReadable": False, "m_ImageCount": 1,
                  "image data": img.transpose(Image.FLIP_TOP_BOTTOM).tobytes(),
                  "m_StreamData": {"offset": 0, "size": 0, "path": ""}})
        t["m_TextureSettings"].update({"m_FilterMode": 0, "m_Aniso": 1, "m_MipBias": 0.0,
                                       "m_WrapMode": 1})
        tex.save_typetree(t)

        spr = clone(tex_src, SPRITE, CID_SPRITE, sf, spr_type)
        s = copy.deepcopy(sprite_tpl)
        rect = {"x": 0.0, "y": 0.0, "width": float(SIZE), "height": float(SIZE)}
        s["m_Name"] = name
        s["m_Rect"] = dict(rect)
        s["m_PixelsToUnits"] = PPU
        s["m_RD"]["texture"] = {"m_FileID": 0, "m_PathID": TEX}
        s["m_RD"]["alphaTexture"] = {"m_FileID": 0, "m_PathID": 0}
        s["m_RD"]["textureRect"] = dict(rect)
        s["m_RD"]["textureRectOffset"] = {"x": 0.0, "y": 0.0}
        s["m_RD"]["uvTransform"] = {"x": PPU, "y": SIZE / 2, "z": PPU, "w": SIZE / 2}
        spr.save_typetree(s, nodes=spr_type.node)

        keys = [f"{name}{v}{sh}" for v in VARIANTS for sh in ("", "_shiny")]
        ab = clone(ab_src, AB, CID_ASSETBUNDLE, sf, ab_type)
        m = ab_src.read_typetree()
        m.update({"m_Name": name, "m_AssetBundleName": name, "m_Dependencies": [],
                  "m_PreloadTable": [{"m_FileID": 0, "m_PathID": SPRITE},
                                     {"m_FileID": 0, "m_PathID": TEX}],
                  "m_Container": [[k, {"preloadIndex": 0, "preloadSize": 2,
                                       "asset": {"m_FileID": 0, "m_PathID": SPRITE}}]
                                  for k in keys],
                  "m_MainAsset": {"preloadIndex": 0, "preloadSize": 0,
                                  "asset": {"m_FileID": 0, "m_PathID": 0}}})
        ab.save_typetree(m)

        sf.objects.clear()
        for o in (ab, tex, spr):
            sf.objects[o.path_id] = o
        sf.externals, sf.script_types = [], []
        sf.mark_changed()
        old = next(iter(bundle.files))
        cab = "CAB-" + hashlib.md5(name.encode()).hexdigest()
        bundle.files[cab] = bundle.files.pop(old)
        try:
            bundle.files[cab].name = cab
        except Exception:
            pass
        return name, bundle.save(packer="original")
    finally:
        os.remove(path)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--sprites", default=os.path.join(MOD, "sprites"))
    ap.add_argument("--mod-assets", default=os.path.join(MOD, "Data", "sharedassets0.assets"))
    ap.add_argument("nums", nargs="*", type=int)
    a = ap.parse_args(argv)
    nums = a.nums or range(1, 152)
    os.makedirs(P.OUT_ASSETS, exist_ok=True)
    tmp = os.path.join(P.OUT_ASSETS, ".tmp")
    os.makedirs(tmp, exist_ok=True)
    key = dict(P.genuine_digest())["pm0001"]
    base = P.decrypt(open(os.path.join(P.SRC_ASSETS, "pm0001"), "rb").read(), key)
    tpl, stype = sprite_template(a.mod_assets)
    entries = []
    for num in nums:
        png = os.path.join(a.sprites, f"pokemon_icon_{num:03d}.png")
        name, packed = build(num, png, base, tpl, stype, tmp)
        entries.append(P.encrypt_entry(name, packed))
        print(f"{name}: {len(packed)} B", flush=True)
    os.rmdir(tmp)
    ts = P.merge_digest(entries)
    print(f"added {len(entries)} icon bundles to {P.OUT_ASSETS}/asset_digest (ts {ts})")


if __name__ == "__main__":
    main(sys.argv[1:])
