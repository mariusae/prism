#!/usr/bin/env python3
"""Drive Bike: build an outline, press keys, read back rows and selection.

Usage as a library:
    b = Bike()
    b.load("a\n\tb\n\tc\nd")     # tab-indented plain text
    b.caret("b", 1)               # caret in row "b" after 1 char
    b.keys("return")              # see KEYS
    print(b.state())

Only ever touches a document named BIKE-PROBE that it makes itself.
"""
import os, subprocess, sys, time

NAME = "BIKE-PROBE"
APP = os.environ.get("BIKE_APP", "/Applications/Bike.app")

def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.rstrip("\n")

# System Events key codes.
CODES = {"return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "fdelete": 117,
         "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119,
         "pageup": 116, "pagedown": 121}
MODS = {"cmd": "command down", "shift": "shift down", "opt": "option down", "ctrl": "control down"}

def keystroke_script(key):
    """'cmd+shift+left', 'return', 'a', 'type:hello'"""
    if key.startswith("type:"):
        text = key[5:].replace("\\", "\\\\").replace('"', '\\"')
        return f'keystroke "{text}"'
    parts = key.split("+")
    base, mods = parts[-1], [MODS[m] for m in parts[:-1]]
    using = f" using {{{', '.join(mods)}}}" if mods else ""
    if base in CODES:
        return f"key code {CODES[base]}{using}"
    return f'keystroke "{base}"{using}'

class Bike:
    def __init__(self):
        osa(f'tell application "{APP}" to activate')
        import os
        kept = os.path.join(os.path.dirname(__file__), "doc-id")
        known = osa(f'tell application "{APP}" to get id of every document').split(", ")
        self.doc = open(kept).read().strip() if os.path.exists(kept) else None
        if self.doc not in known:
            self.doc = osa(f'tell application "{APP}" to get id of (make new document)')
            open(kept, "w").write(self.doc)

    def tell(self, body):
        return osa(f'tell application "{APP}" to tell (first document whose id is "{self.doc}")\n{body}\nend tell')

    def front(self):
        osa(f'''tell application "{APP}"
            activate
            repeat with w in windows
                try
                    if id of (document of (contents of w)) is "{self.doc}" then set index of (contents of w) to 1
                end try
            end repeat
            end tell''')

    def load(self, text):
        """Replace the outline with tab-indented lines. '[c]' at a line's end: collapsed."""
        import re
        collapsed, typed = [], []
        lines = []
        for line in text.split("\n"):
            if line.endswith(" [c]"):
                line = line[:-4]
                collapsed.append(line.strip())
            m = re.search(r" \{(\w+)\}$", line)
            if m:
                line = line[:m.start()]
                typed.append((line.strip(), m.group(1)))
            lines.append(line)
        body = "\n".join(lines).replace("\\", "\\\\").replace('"', '\\"')
        self.tell('delete every row')
        self.tell(f'import from "{body}" as plain text format')
        # The row an emptied outline keeps, after what was imported: gone, unless asked for.
        if not text.endswith("\n"):
            self.tell('if (count of rows) > 0 and name of last row is "" and (count of rows of last row) is 0 then delete last row')
        # A fresh document keeps one empty row of its own: drop empty rows not asked for.
        # Rows written ∅: empty, as an import cannot make them where they are indented.
        self.tell('repeat with r in (rows whose name is "∅")\nset name of (contents of r) to ""\nend repeat')
        for name, kind in typed:
            n = name.replace('"', '\\"')
            code = {"body": "Brtb", "heading": "Brth", "quote": "Brtq", "code": "Brtc", "note": "Brtn", "unordered": "Brtu", "ordered": "Brto", "task": "Brtt", "hr": "Brtr"}[kind]
            self.tell(f'set type of (first row whose name is "{n}") to «constant ****{code}»')
        for name in collapsed:
            n = name.replace('"', '\\"')
            self.tell(f'collapse (first row whose name is "{n}")')

    def select_row(self, name):
        n = name.replace('"', '\\"')
        self.tell(f'select at (first row whose name is "{n}")')

    def caret(self, name, offset=None):
        """Caret in a row's text: at `offset` chars from its start, or its end."""
        self.front()
        self.select_row(name)
        time.sleep(0.15)
        # From a row chosen whole, if that is what selecting it does, to its words.
        moves = ["cmd+left"] + (["cmd+right"] if offset is None else ["right"] * offset)
        self.keys(*moves, pause=0.03)

    def keys(self, *keys, pause=0.08):
        """Keys pressed in turn, in one go: the window brought forward first."""
        if not keys:
            return
        self.front()
        # Every key only while Bike is in front: else nothing at all, rather than keys in another app.
        guard = 'if name of (first process whose frontmost is true) is not "Bike" then error "Bike is not in front"'
        steps = "\n".join(f"{guard}\n{keystroke_script(k)}\ndelay {pause}" for k in keys)
        osa(f'tell application "System Events"\n{steps}\nend tell')

    def rows(self):
        out = self.tell('''set out to ""
            set rs to entire contents
            repeat with item_ in rs
                set r to contents of item_
                set out to out & ((level of r) as text) & tab & (name of r) & tab & ((type of r) as text) & tab & ((collapsed of r) as text) & tab & ((selected of r) as text) & linefeed
            end repeat
            return out''')
        rows = []
        for line in out.split("\n"):
            if not line:
                continue
            level, name, kind, collapsed, selected = line.split("\t")
            rows.append(dict(level=int(level), name=name, type=kind, collapsed=collapsed == "true",
                             selected=selected == "true", visible=True))
        # Hidden: under a collapsed row.
        hiding = None
        for r in rows:
            if hiding is not None and r["level"] > hiding:
                r["visible"] = False
                continue
            hiding = r["level"] if r["collapsed"] else None
        return rows

    def selected_text(self):
        return self.tell('return selection text')

    def mode(self):
        """'text' — a caret or a run of characters — or 'block' — whole rows chosen."""
        # Bike shows a block selection by selecting rows with no text range: probe with selected text vs rows.
        rows = [r for r in self.rows() if r["selected"]]
        text = self.selected_text()
        if len(rows) > 1:
            joined = "\n".join(r["name"] for r in rows)
            return "block" if text.strip() == joined.strip() or text == "" else "text"
        return "text"

    def caret_mark(self):
        """Where the caret is: typed as | and read back, then undone."""
        self.keys("type:|")
        rows = self.rows()
        self.keys("cmd+z")
        for r in rows:
            if "|" in r["name"]:
                return r["name"]
        return None

    def show(self, rows=None):
        rows = rows or self.rows()
        lines = []
        for r in rows:
            mark = "*" if r["selected"] else " "
            flag = (" [" + r["type"] + "]" if r["type"] not in ("body",) else "") + (" (collapsed)" if r["collapsed"] else "") + ("" if r["visible"] else " (hidden)")
            lines.append(f"{mark} {'    ' * (r['level'] - 1)}{r['name'] or '∅'}{flag}")
        return "\n".join(lines)

if __name__ == "__main__":
    b = Bike()
    b.load(sys.argv[1] if len(sys.argv) > 1 else "one\n\ttwo\n\tthree\nfour")
    print(b.show())


SENTINEL = "«bike-probe-nothing-copied»"

def clip():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout

def set_clip(text):
    subprocess.run(["pbcopy"], input=text, text=True)

def state(b):
    """Rows, which are chosen, and how: a caret (where), words chosen (which), or rows chosen."""
    rows = b.rows()
    chosen = [r["name"] for r in rows if r["selected"]]
    text = b.selected_text()
    # Bike 2: rows chosen read as their words after a line break; a caret as nothing; words as themselves.
    if text.startswith("\n"):
        mode, detail = "block", chosen
    elif text == "":
        mode, detail = "caret", b.caret_mark()
    else:
        mode, detail = "text", text
    return dict(outline=b.show(rows), mode=mode, detail=detail)

def report(s):
    return s["outline"] + f"\n  → {s['mode']}: {s['detail']!r}"
