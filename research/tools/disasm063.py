"""
Annotated arm64 disassembly of the 0.63.4 binary using Il2CppDumper's script.json.

    python3 disasm063.py <name-substring | 0xVA> [max_bytes]

Labels: bl targets (method names), adrp+ldr/add globals (TypeInfo / MethodInfo /
string literals). Stops at the first ret after the function body unless max_bytes given.
"""
import json, os, struct, sys, capstone

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BIN = os.path.join(ROOT, "..", "client", "pin", "pokemongo.pinpatched")
SJ = os.path.join(ROOT, "il2cpp-dump-063", "script.json")
BASE = 0x100000000

d = open(BIN, "rb").read()
j = json.load(open(SJ))
methods = {}
for m in j["ScriptMethod"]:
    methods[BASE + m["Address"]] = m["Name"]
glob = {}
for m in j["ScriptMetadata"]:
    glob[BASE + m["Address"]] = m["Name"]
for m in j["ScriptMetadataMethod"]:
    glob[BASE + m["Address"]] = m["Name"]
for m in j["ScriptString"]:
    glob[BASE + m["Address"]] = "str " + repr(m["Value"])[:80]
starts = sorted(methods)

def find(q):
    if q.startswith("0x"):
        return int(q, 16)
    hits = [(a, n) for a, n in methods.items() if q in n]
    for a, n in sorted(hits)[:30]:
        print(f"  {a:#x} {n}")
    return sorted(hits)[0][0] if len(hits) == 1 else None

def name_of(va):
    if va in methods:
        return methods[va]
    import bisect
    i = bisect.bisect_right(starts, va) - 1
    return f"{methods[starts[i]]}+{va - starts[i]:#x}" if i >= 0 else hex(va)

def dis(va, maxb=None):
    import bisect
    i = bisect.bisect_right(starts, va)
    end = starts[i] if i < len(starts) and not maxb else va + (maxb or 0x2000)
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    pages = {}
    print(f"== {name_of(va)}")
    for ins in md.disasm(d[va - BASE:end - BASE], va):
        note = ""
        ops = ins.op_str
        if ins.mnemonic == "adrp":
            r = ops.split(",")[0]; pages[r] = int(ops.split("#")[1], 16)
        elif ins.mnemonic in ("ldr", "add") and "#" in ops:
            parts = [p.strip() for p in ops.replace("[", "").replace("]", "").split(",")]
            if len(parts) >= 3 and parts[1] in pages:
                try:
                    tgt = pages[parts[1]] + int(parts[2].lstrip("#"), 16)
                    if tgt in glob:
                        note = glob[tgt]
                except ValueError:
                    pass
        elif ins.mnemonic in ("bl", "b") and "#" in ops:
            tgt = int(ops.split("#")[1], 16)
            if not (va <= tgt < end):
                note = name_of(tgt)
        print(f"  {ins.address:x}  {ins.mnemonic:6} {ops}" + (f"    ; {note}" if note else ""))

if __name__ == "__main__":
    va = find(sys.argv[1])
    if va:
        dis(va, int(sys.argv[2], 16) if len(sys.argv) > 2 else None)
