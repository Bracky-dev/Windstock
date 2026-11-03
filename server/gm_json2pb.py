"""
gm_json2pb.py -- turn a 2017 GAME_MASTER.json (pokemongo-game-master format, field names
from AeonLucid POGOProtos) into DownloadItemTemplatesResponse bytes, with no protoc and no
google.protobuf: a small .proto reader resolves message/enum names and numbers.

0.71 needs its own game master: the 2016 one has no 2017 move sequences, forms, avatar
items or encounter tuning, so the client's catch screen came up with no balls and the
camera in the Pokemon's face, and some attack effects had nothing to play.

Usage: python3 gm_json2pb.py GAME_MASTER.json <POGOProtos src dir> out.bin
"""
import json
import os
import re
import struct
import sys

import pb

SCALAR_WIRE = {"double": 1, "float": 5, "int32": 0, "int64": 0, "uint32": 0, "uint64": 0,
               "sint32": 0, "sint64": 0, "fixed32": 5, "fixed64": 1, "sfixed32": 5,
               "sfixed64": 1, "bool": 0, "string": 2, "bytes": 2}


def load_protos(src):
    """{full message name: {field name: (num, type ref, repeated, scope)}},
    {full enum name: {value name: number}}."""
    msgs, enums = {}, {}
    for root, _, files in os.walk(src):
        for fn in files:
            if not fn.endswith(".proto"):
                continue
            txt = re.sub(r"//[^\n]*", "", open(os.path.join(root, fn), encoding="utf-8").read())
            pkg = re.search(r"package\s+([\w.]+)\s*;", txt)
            stack = [pkg.group(1)] if pkg else []
            kinds = []
            for tok in re.finditer(
                    r"(message|enum|oneof)\s+(\w+)\s*\{|\}"
                    r"|(?:(repeated)\s+)?([\w.]+)\s+(\w+)\s*=\s*(-?\d+)\s*(?:\[[^\]]*\])?\s*;"
                    r"|(\w+)\s*=\s*(-?\d+)\s*(?:\[[^\]]*\])?\s*;", txt):
                if tok.group(1):
                    kinds.append(tok.group(1))
                    if tok.group(1) != "oneof":
                        stack.append(tok.group(2))
                        full = ".".join(stack)
                        (msgs if tok.group(1) == "message" else enums).setdefault(full, {})
                elif tok.group(0) == "}":
                    if kinds and kinds.pop() != "oneof":
                        stack.pop()
                elif tok.group(5) and kinds and kinds[-1] in ("message", "oneof"):
                    scope = ".".join(stack)
                    msgs[scope][tok.group(5)] = (int(tok.group(6)), tok.group(4),
                                                 bool(tok.group(3)), scope)
                elif tok.group(7) and kinds and kinds[-1] == "enum":
                    enums[".".join(stack)][tok.group(7)] = int(tok.group(8))
    return msgs, enums


def resolve(ref, scope, msgs, enums):
    if ref.startswith("."):
        n = ref[1:]
        return n if (n in msgs or n in enums) else None
    parts = scope.split(".")
    while parts:
        n = ".".join(parts + [ref])
        if n in msgs or n in enums:
            return n
        parts.pop()
    return ref if (ref in msgs or ref in enums) else None


def camel(name):
    return re.sub(r"_([a-z0-9])", lambda m: m.group(1).upper(), name)


class Encoder:
    def __init__(self, msgs, enums):
        self.msgs, self.enums = msgs, enums
        self.unknown = {}

    def message(self, full, obj):
        fields = self.msgs[full]
        by_json = {}
        for name, spec in fields.items():
            by_json[name] = spec
            by_json[camel(name)] = spec
        w = pb.Writer()
        for k, v in obj.items():
            spec = by_json.get(k)
            if spec is None:
                self.unknown[f"{full}.{k}"] = self.unknown.get(f"{full}.{k}", 0) + 1
                continue
            num, ref, rep, scope = spec
            for item in (v if rep and isinstance(v, list) else [v]):
                self.value(w, num, ref, scope, item)
        return w.to_bytes()

    def value(self, w, num, ref, scope, v):
        if ref in SCALAR_WIRE:
            if ref == "string":
                w.string(num, str(v))
            elif ref == "bytes":
                w.bytes_(num, v.encode() if isinstance(v, str) else v)
            elif ref == "bool":
                w.bool_(num, bool(v))
            elif ref in ("float", "fixed32", "sfixed32"):
                if ref == "float":
                    w.float_(num, float(v))
                else:
                    w.fixed32(num, int(v))
            elif ref in ("double", "fixed64", "sfixed64"):
                if ref == "double":
                    w.double(num, float(v))
                else:
                    w.fixed64(num, int(v))
            else:
                n = int(v)
                w.int_(num, n) if n < 0 else w.uint(num, n)
            return
        full = resolve(ref, scope, self.msgs, self.enums)
        if full in self.enums:
            n = v if isinstance(v, int) else self.enums[full].get(v)
            if n is None:
                self.unknown[f"{full}={v}"] = self.unknown.get(f"{full}={v}", 0) + 1
                return
            w.int_(num, n) if n < 0 else w.uint(num, n)
        elif full in self.msgs:
            w.message(num, self.message(full, v))
        else:
            self.unknown[f"type {ref} in {scope}"] = 1


def convert(json_path, proto_src):
    msgs, enums = load_protos(proto_src)
    enc = Encoder(msgs, enums)
    d = json.load(open(json_path, encoding="utf-8"))
    top = "POGOProtos.Networking.Responses.DownloadItemTemplatesResponse"
    w = pb.Writer().uint(1, 1)
    for t in d["itemTemplates"]:
        w.message(2, enc.message(top + ".ItemTemplate", t))
    return w.to_bytes(), int(d.get("timestampMs") or 0), enc.unknown


if __name__ == "__main__":
    raw, ts, unknown = convert(sys.argv[1], sys.argv[2])
    open(sys.argv[3], "wb").write(raw)
    print(f"{len(raw)} bytes, timestamp {ts}; unmapped: {len(unknown)}")
    for k, n in sorted(unknown.items(), key=lambda x: -x[1])[:30]:
        print(f"  {n:5d}  {k}")
