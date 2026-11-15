import json, os, sys, time
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
from weft import Weft, state
from probes import PROBES

only = sys.argv[1:]
out = os.path.join(here, "weft-results.json")
results = json.load(open(out)) if os.path.exists(out) and only else {}
w = Weft()
for label, outline, (row, at), keys in PROBES:
    if only and label not in only:
        continue
    try:
        w.load(outline, row, at)
        time.sleep(0.15)
        w.keys(*keys, pause=0.15)
        time.sleep(0.25)
        s = state(w)
    except Exception as error:
        s = dict(outline="", mode="error", detail=str(error), raw={})
    results[label] = dict(given=outline, caret=[row, at], keys=keys, **{k: v for k, v in s.items() if k != "raw"}, markdown=s.get("raw", {}).get("markdown"))
    print("##", label, keys); print(s["outline"] + f"\n  → {s['mode']}: {s['detail']!r}", flush=True)
    json.dump(results, open(out, "w"), indent=1, ensure_ascii=False)
