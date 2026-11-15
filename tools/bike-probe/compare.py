"""Bike against Weft, probe by probe: the outline after, and what is chosen."""
import json, os, re, sys
here = os.path.dirname(os.path.abspath(__file__))
bike = json.load(open(os.path.join(here, os.environ.get("BIKE_RESULTS", "bike2-results.json"))))
weft = json.load(open(os.path.join(here, "weft-results.json")))

def norm_outline(text):
    # Case aside (Bike capitalises as the probe's marker is typed), and the hidden rows Weft does not list.
    lines = [l for l in text.split("\n") if "(hidden)" not in l]
    return "\n".join(lines).lower().replace(" [unordered]", "")

def norm_detail(mode, detail):
    if mode == "caret" and isinstance(detail, str):
        return detail.lower()
    if mode == "text" and isinstance(detail, str):
        return re.sub(r"\s+", " ", detail.replace("\t", "")).strip().lower()
    return json.dumps(detail).lower()

def dedent(text):
    # The run began before Weft's report was put a level out: done here.
    return "\n".join(l[:2] + l[6:] if l[2:6] == "    " else l for l in text.split("\n"))

for w in weft.values():
    if w["outline"].split("\n")[0][2:6] == "    " or all(l[2:6] == "    " for l in w["outline"].split("\n") if l):
        w["outline"] = dedent(w["outline"])

same, differ = [], []
for label, b in bike.items():
    w = weft.get(label)
    if not w:
        continue
    ok = norm_outline(b["outline"]) == norm_outline(w["outline"]) and b["mode"] == w["mode"] and norm_detail(b["mode"], b["detail"]) == norm_detail(w["mode"], w["detail"])
    (same if ok else differ).append(label)
    if not ok:
        print(f"### {label}   keys {b['keys']}   caret {b['caret']}")
        bl = (b["outline"] + f"\n→ {b['mode']}: {b['detail']!r}").split("\n")
        wl = (w["outline"] + f"\n→ {w['mode']}: {w['detail']!r}").split("\n")
        width = max(len(l) for l in bl) + 4
        print(f"{'BIKE':<{width}}WEFT")
        for i in range(max(len(bl), len(wl))):
            print(f"{(bl[i] if i < len(bl) else ''):<{width}}{wl[i] if i < len(wl) else ''}")
        print()
print(f"same: {len(same)}   differ: {len(differ)}")
print("same:", ", ".join(same))
