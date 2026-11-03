"""Pull the per-key prose out of settings.py's DEFAULTS.

The comments above each key are the only place the reasoning lives -- that a
setting is experimental, what it breaks, what the genuine 2016 value was. The
app showed only the key name, so `custom_login_page` looked as safe as any
other toggle and turning it on killed login with nothing on screen to say so.
"""
import ast, json, re, sys

src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")

# Find the DEFAULTS assignment and walk it with line numbers.
tree = ast.parse(src)
node = next(n for n in tree.body
            if isinstance(n, ast.Assign)
            and any(getattr(t, "id", "") == "DEFAULTS" for t in n.targets))

def comment_above(lineno):
    """The contiguous # block immediately above this line, cleaned up."""
    out, i = [], lineno - 2          # lineno is 1-based; -1 for the line itself
    while i >= 0:
        stripped = lines[i].strip()
        if stripped.startswith("#"):
            out.append(stripped.lstrip("#").strip())
            i -= 1
        else:
            break
    if not out:
        return ""
    text = " ".join(reversed(out))
    text = re.sub(r"\s+", " ", text).strip()
    return text

help_map = {}
for section_key, section_val in zip(node.value.keys, node.value.values):
    if not isinstance(section_val, ast.Dict):
        continue
    section = section_key.value
    for k, v in zip(section_val.keys, section_val.values):
        if not isinstance(k, ast.Constant):
            continue
        text = comment_above(k.lineno)
        if text:
            help_map[f"{section}.{k.value}"] = text

# Second source: the "_readme" block inside settings.json, which documents
# plenty of keys settings.py leaves bare. Lines look like
#     "   fast_catch ........... true = a catch takes one throw instead of"
# with the continuation indented under it. Keyed by bare name (the readme is
# not section-scoped), used only where the code comment gave us nothing.
readme = {}
if len(sys.argv) > 3:
    try:
        doc = json.load(open(sys.argv[3], encoding="utf-8")).get("_readme") or []
    except (OSError, ValueError):
        doc = []
    current = None
    for raw in doc:
        line = str(raw).rstrip()
        m = re.match(r"^\s{2,}([a-z0-9_]+)\s*\.{3,}\s*(.*)$", line)
        if m:
            current = m.group(1)
            readme[current] = m.group(2).strip()
        elif current and re.match(r"^\s{6,}\S", line) and not re.match(r"^\s*[a-z_]+:", line):
            readme[current] = (readme[current] + " " + line.strip()).strip()
        elif not line.strip():
            current = None
    readme = {k: re.sub(r"\s+", " ", v).strip() for k, v in readme.items() if v.strip()}

filled = 0
for section_key, section_val in zip(node.value.keys, node.value.values):
    if not isinstance(section_val, ast.Dict):
        continue
    section = section_key.value
    for k in section_val.keys:
        if not isinstance(k, ast.Constant):
            continue
        full = f"{section}.{k.value}"
        if full not in help_map and k.value in readme:
            help_map[full] = readme[k.value]
            filled += 1

json.dump(help_map, open(sys.argv[2], "w"), indent=1, sort_keys=True)
print(f"    {len(help_map)} setting descriptions ({filled} from the readme)")
