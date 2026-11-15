"""Drive Weft's editor as bike.py drives Bike: same probes, same report."""
import json, os, re, subprocess, time, uuid
from bike import keystroke_script, osa, clip, set_clip, SENTINEL

HERE = os.path.dirname(os.path.abspath(__file__))
PROCESS = "WeftMac"

def markdown(outline):
    """The probe's outline as a note: list items, folded marks, tasks."""
    lines = []
    for line in outline.split("\n"):
        depth = len(line) - len(line.lstrip("\t"))
        words = line.strip()
        folded = words.endswith(" [c]")
        if folded:
            words = words[:-4]
        m = re.search(r" \{(\w+)\}$", words)
        kind = None
        if m:
            words, kind = words[:m.start()], m.group(1)
        if words == "∅":
            words = ""
        marker = {"task": "- [ ] ", "quote": "> ", "ordered": "1. ", "unordered": "* ", "heading": "# "}.get(kind, "- ")
        if kind == "code":
            lines.append("  " * depth + "```")
            lines.append("  " * depth + words)
            lines.append("  " * depth + "```")
            continue
        # An empty item cannot follow words straight away: a blank line holds it apart, as Weft writes it.
        if not words and lines:
            lines.append("")
        lines.append("  " * depth + marker + words + (" <!-- folded -->" if folded else ""))
    return "\n".join(lines) + "\n"

def shown_names(outline):
    """The rows' words as the editor shows them: those under a folded row are not shown."""
    names, hidden_under = [], None
    for line in outline.split("\n"):
        depth = len(line) - len(line.lstrip("\t"))
        if hidden_under is not None and depth > hidden_under:
            continue
        hidden_under = None
        words = line.strip()
        if words.endswith(" [c]"):
            words = words[:-4]
            hidden_under = depth
        words = re.sub(r" \{\w+\}$", "", words)
        names.append("" if words == "∅" else words)
    return names

class Weft:
    def ask(self, request):
        out = os.path.join(HERE, f"answer-{uuid.uuid4().hex}.json")
        request = dict(request, out=out)
        ask = os.path.join(HERE, "ask.json")
        json.dump(request, open(ask, "w"))
        post(ask)
        for _ in range(200):
            if os.path.exists(out) and os.path.getsize(out) > 0:
                time.sleep(0.05)
                answer = json.load(open(out))
                os.remove(out)
                return answer
            time.sleep(0.05)
        raise RuntimeError("no answer")

    def front(self):
        pass

    def load(self, outline, row, at):
        answer = self.ask(dict(cmd="load", markdown=markdown(outline), names=shown_names(outline), row=row, **({} if at == "end" else {"offset": at})))
        if "error" in answer:
            raise RuntimeError(json.dumps(answer)[:400])

    def keys(self, *keys, pause=0.08):
        """Pressed inside Weft, in its own window: never through the system's keyboard."""
        if keys:
            self.ask(dict(cmd="keys", keys=list(keys)))

    def dump(self):
        return self.ask(dict(cmd="dump"))

def post(ask):
    """A distributed notification naming the request, as the app listens for."""
    tool = os.path.join(HERE, "post")
    if not os.path.exists(tool):
        src = os.path.join(HERE, "post.swift")
        open(src, "w").write('import Foundation\nDistributedNotificationCenter.default().postNotificationName(.init("org.mutable.weft.probe"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)\n')
        subprocess.run(["swiftc", "-O", src, "-o", tool], check=True)
    subprocess.run([tool, ask], check=True)

def show(d):
    rows = d.get("rows", [])
    chosen = d.get("chosen")
    sel = d.get("selection", [0, 0])
    lines = []
    for i, r in enumerate(rows):
        inside = chosen and chosen[0] <= i <= chosen[1]
        if not chosen:
            inside = r["start"] <= sel[0] <= r["end"] or (sel[1] and sel[0] < r["end"] and sel[0] + sel[1] > r["start"])
        flag = (" [" + r["type"] + "]" if r["type"] != "body" else "") + (" (collapsed)" if r["folded"] else "")
        lines.append(f"{'*' if inside else ' '} {'    ' * (r['depth'] - 1)}{r['name'] or '∅'}{flag}")
    return "\n".join(lines)

def state(w):
    d = w.dump()
    rows, (at, length) = d.get("rows", []), d.get("selection", [0, 0])
    if d.get("chosen"):
        mode, detail = "block", [rows[i]["name"] for i in range(d["chosen"][0], d["chosen"][1] + 1)]
    elif length == 0:
        row = next((r for r in rows if r["start"] <= at <= r["end"]), None)
        mode = "caret"
        detail = row and (row["name"][: at - row["content"]] + "|" + row["name"][at - row["content"]:])
    else:
        mode = "text"
        detail = d.get("selectedText")
    return dict(outline=show(d), mode=mode, detail=detail, raw=d)
