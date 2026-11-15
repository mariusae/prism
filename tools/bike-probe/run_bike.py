import json, os, sys, time
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
from bike import Bike, state, report, clip, set_clip
from probes import PROBES

only = sys.argv[1:]  # labels to run, or all
saved = clip()
results = {}
out = os.path.join(here, "bike-results.json")
if os.path.exists(out) and only:
    results = json.load(open(out))
try:
    b = Bike()
    for label, outline, (row, at), keys in PROBES:
        if only and label not in only:
            continue
        try:
            b.load(outline)
            b.caret(row, None if at == "end" else at)
            b.keys(*keys, pause=0.2)
            time.sleep(0.2)
            s = state(b)
        except Exception as error:
            s = dict(outline="", mode="error", detail=str(error))
        results[label] = dict(given=outline, caret=[row, at], keys=keys, **s)
        print("##", label, keys); print(report(s), flush=True)
        json.dump(results, open(out, "w"), indent=1, ensure_ascii=False)
finally:
    set_clip(saved)
