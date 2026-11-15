# The editor, as Bike 2's

Weft's note editor is to work as Bike 2's outline editor does — on the Mac
and on the iPhone — deviating only where we decide to. Decided so far:
**Bike 2 throughout**: every note is rows; no Markdown is ever seen in the
editor (it stays the file format underneath); Bike 2's look; Bike 2's keys
win inside the editor.

Deviations chosen, where Weft's own design stays:

- **Pictures** stay Weft's: large, resizable, side by side in carousels
  (Bike 2's are ~64pt thumbnails within the words).
- **Two task kinds** stay: checklist items (`- [ ]`) and tasks (`+ [ ]`),
  which Weft's queries read — both drawn and toggled as Bike's tasks.
- **Code blocks** stay multi-line (fenced), and **headings** keep three
  levels — both drawn in Bike's style. (Bike 2: one-line code rows, one
  heading level.)

How it was found: a harness builds an outline in a scratch Bike document,
puts the caret, presses keys, and reads back the rows (level, type, fold)
and what is chosen — a caret (and where), words, or rows. The same probes
run on Weft's editor through a debug-only hook (`EditorProbe`, in debug
builds, on a `-GraphPath` graph). Bike 2.0 (build 312) is the reference;
Bike 1.22 was probed too, and differs in ~40 cases. Bike 2's default key
bindings and its whole row style come from its built-in extension
(`bike.bkext`: `app/main.ts`, `style/*.ts`) and its menus.

190 probes (`tools/bike-probe`). Before this work 67 of 165 matched; now 162 of 190 do — the rest are chosen deviations (fenced code, no note type), the harness's limits, and navigation.

## The model

- **Everything is rows**, each with rich words (bold, italic, code,
  highlight, strikethrough, link, super/subscript) and a type: body,
  heading, quote, code, note, task, ordered, unordered, rule.
- **Three selections**: a caret; words — *within one row only*; and rows
  ("block mode"), whole rows, drawn as such, no caret.
- **A row always takes its children** when indented, outdented, moved,
  duplicated or deleted. "Rows Only" commands are the exceptions, asked
  for by name.

## Keys (Bike 2's defaults)

Text and block mode alike unless noted.

| Keys | Command |
|---|---|
| Return | split the row (text); new row after (block) |
| ⇧Return, ⌥Return | split, as Return |
| ⌘Return | new row below, not splitting |
| ⇧⌘Return | new row above |
| ⌥⌘Return | new child row |
| Tab / ⇧Tab, ⌃⌘→ / ⌃⌘← | indent / outdent, with children |
| ⌃⌥→ / ⌃⌥← | indent / outdent the row alone |
| ⌃⌥⇧← | promote children (they become the row's following siblings) |
| ⌃⌥⇧→ | demote siblings (the following siblings become its children) |
| ⌃⌘↑ / ⌃⌘↓ | move up / down past the next visible row, taking its level |
| ⌃⌥⌘↑ / ⌃⌥⌘↓ | move up / down, keeping the level |
| ⌃⌥↑ / ⌃⌥↓ | move the row alone |
| ⌘D | duplicate (the copy chosen, as rows) |
| ⇧⌘K | delete the rows, with children (the next row chosen) |
| ⌃⌥K | delete the row alone (children move up) |
| ⌃⌘⌫ | join the next row into this, with a space |
| ⌥⌘G | group: a new parent row for the rows, writing in it |
| ⌘0 / ⌘9 | expand / collapse the row |
| ⌥⌘0 / ⌥⌘9 | expand / collapse the row by one level |
| ⌃⌘0 / ⌃⌘9 | expand / collapse all |
| ⌃⌥⌘0 / ⌃⌥⌘9 | expand / collapse all by one level |
| ⌃⇧⌘→ / ⌃⇧⌘← | expand / contract selection |
| ⌘A | every row, as rows |
| ⌃W / ⌃S | select word / sentence |
| Esc | text ⇄ block mode |
| Space (block) | toggle done |
| ⌥⌘→ / ⌥⌘← / ⌃⌥⌘← | focus in / out / home |
| ⌘B ⌘I ⇧⌘C ⇧⌘H ⇧⌘- | bold, italic, code, highlight, strikethrough |
| ⌃⇧⌘= / ⌃⌘- | superscript / subscript |
| ⌘K / ⌥⌘K | add link / link to row |
| ⌥⌘⌫ | clear formatting |
| ⌘E | show formatting |
| ⇧⌘A, ⌘→ at a row's text end | row attributes |
| ⌘L | copy row link |
| ⌘\ ⌃⌘\ ⌥⌘\ | move to… / send to… / move to row… |
| ⌘P ⌥⌘P ⇧⌘P | go to… / go to row… / commands |
| ⌘[ ⌘] | back / forward |
| ⇧⌘F | filter |
| ⌘Y | pin row |
| ' [ " { ( with words chosen | wrap them |

## Behaviour found

### Return
- Middle: split; the second half below. On a parent, the second half
  becomes its **first child**; the children stay with the first half.
- Start: an empty row above; the caret stays with the words.
- End of a leaf: an empty row below. End of an expanded parent: a new first
  child. End of a collapsed parent: a row after its branch.
- An empty row, at any depth: a new empty row (no outdent).
- An empty task (and any empty typed row): turned body, in place.
- End of a task: a new task. End of a heading: a body row.
- Block mode: a new row after the chosen (a first child under an expanded
  parent; after the branch under a collapsed one), writing in it.

### Delete
- At a row's start: joins it to the row above (into a collapsed row too,
  which stays collapsed); its children go under the joined row.
- An empty row: goes; the caret to the end of the row above.
- First row: nothing. Typed row: the type goes first, then a join.
- Forward delete at a row's end: joins the next row in.

### Tab, outdent
- A row with no row before it at its level: nothing.
- Outdent: the row (with its children) goes after its parent's whole
  branch; the siblings after it stay under the parent.
- Into a collapsed row: it expands.

### Moving
- ⌃⌘↑ on a first child: out of its parent, above it, at the parent's
  level. ⌃⌘↓ on a last child: past the next row, at its level.
- A row moves past the neighbouring visible row (a collapsed branch whole).

### Selecting
- ⇧↓ from a caret: to the row's end; again, the row as rows; again, the
  next row too. ⇧↑ likewise toward the row's start.
- ⇧← at a row's start, ⇧→ at its end: nothing beyond the row.
- Expand selection: word → sentence → the row's words → the row → its
  branch → its parent's branch. Contract steps back.
- ⌘A: every row, as rows, however often pressed.

### Block mode
- ↑ ↓ move; ⇧↑ ⇧↓ extend; ⌘↑ ⌘↓ to the first / last row; ⇧⌘↓ extends to
  the last.
- ← → ⌥← ⌥→ ⌥↓: back to writing, at the row's start / end.
- Esc: back to writing where the caret was.
- Space: toggles done. Typing a letter: nothing.
- Delete, ⇧⌘K: the rows go, the next chosen. Tab: indents them.

### Folding
- ⌘9 on a leaf: nothing (Bike 1 collapsed the parent; Bike 2 does not).
- ⌥⌘9 / ⌥⌘0: collapse the deepest expanded level / expand one level,
  within the row.

### Typed row types
At a row's start, followed by a space — in an empty row or before words:
`-` `*` `+` unordered, `#` heading, `[]` `[ ]` task, `>` quote, `1.`
ordered, `:` note, ` ``` ` code, `---` rule. Delete or Undo right after
gives the typed characters back as words.

### Typed rows
- Return at the end of a quote, code, note, numbered, bullet or task row:
  a new row of the same type (the next number). In the middle: split, both
  halves of the type.
- Return on an empty typed row: made body, in place.
- ⇧Return in a code row: a new code row, as Return. ⌥Return: a new
  *body* row.
- Delete at a typed row's start: made body. Again: joined to the row
  above, which keeps its own type.
- Tab indents a typed row as any other.
- A code row is one line: a block of code is a run of code rows.

### Typing
- `'` and `"` are made curly; `[`, `(`, `{` are not closed for you.
- With words chosen, `' [ " { (` wrap them.

## Row types, tasks, media (Bike 2's style, `style/layer-formatting.ts`)

Every row has a handle — a triangle half an indent before its words,
dim on a leaf, turned down when expanded — and an expanded parent a
guide line down its branch. An empty, childless body row hides its
handle unless chosen. A parent has a focus arrow (↘) after its words.

| Type | Drawn | Bike Markdown |
|---|---|---|
| body | plain | `- words` |
| heading | bold; a badge of its tasks done (½) | `- # words` |
| quote | italic; a 4pt bar half an indent before, and a faint rounded box; quotes in a row merge into one block | `- > words` |
| code | monospaced | ``- `words` `` |
| note | italic, dimmer | `- words {type=note}` |
| task | a square box in the gutter (clicked: done) | `- [ ] words` |
| done task | ☑, a thick strikethrough, a "Done" badge | `- [x] words` |
| ordered | its number in the gutter, counted along the run | `1. words` |
| unordered | a small filled circle in the gutter | `+ words` |
| rule | a hairline across | `- ---` |

The gutter marks (box, number, circle, bar) sit half an indent before
the words, whose margin is two indents.

- **Done**: any row can be done (closed): struck through. Space with rows
  chosen, or a click on a task's box, toggles it.
- **Inline**: bold, italic, code (monospaced, no background), highlight
  (a rounded mark behind the words), strikethrough, super / subscript,
  links — blue, with an ↗ button after the link that opens it; a click on
  the words just puts the caret there.
- **Pictures** are characters in the words: thumbnails on the baseline,
  about 64pt tall, beside words or alone on a row; the caret is as tall as
  the line beside one. Pasting a picture into a plain `.bike` document
  asks to make it a text bundle (`.biked`: `text.md` and `assets/`).
- **Files** attached are chips — the name in a light rounded box; a file
  linked is a link with its ↗ button.
- **Selection**: rows chosen are a rounded band from the words' leading
  edge to the row's end; their descendants that go with them a fainter
  band. Words chosen: a rounded band; a chosen line break a ¶ sliver;
  chosen spaces a faint dot. Dragging rows fades them; the drop is a 3pt
  accent line, or an outline on the row dropped onto.
- **iPhone** (Bike 2 runs there too): a 22pt accent circle at the
  selection's first and last corners — of rows or of words — to drag.
- While typing, handles, guides and badges may fade (a setting).

## Weft today, against this

Done (Mac; the engine is shared with the iPhone): Return and its ⌘ ⇧ ⌥
variants; outdent, move past the shown row, promote, demote, join, group,
duplicate, the "rows only" indent, outdent and delete; one-row text
selections, ⇧↑ ⇧↓ into rows, ⌘A, expand and contract selection, ⌃W ⌃S;
block mode's arrows, ⌘↑ ⌘↓, Space, Return, typing, and Esc back to the
caret where it was. Bike 2's keys are the editor's, and Weft's Format menu
is Bike's Format and Outline menus.

Also done: every note opens as rows (the Outline / Text choice is gone);
Markdown is never shown — a row's marks stay hidden while it is written
in, the caret steps over them (one press at a formatting's edge is the
caret's side, Bike's typing affinity, shown by a tail on the caret),
Delete steps over them and takes a link shown by its title whole; Bike
2's look — a handle on every row (dark when folded), guide lines, typed
rows' marks in a step of their own, row selection as bands from the
words, quotes boxed, done rows struck thick, code in words without a
background, no pill on folded rows; the iPhone has the same rules, look,
hidden Markdown and Bike's keys on a keyboard.

Left, by area:

- **Links**: a link shown by its page's title is one unit; Bike edits a
  link's words as words. Needs a way to edit them (as Bike's link editor).
- **Badges**: a heading's tasks done (½), a done row's "Done".
- **Words chosen**: Bike's ¶ sliver for a chosen line break, dots for
  chosen spaces.
- **iPhone**: Bike's round handles at a selection's corners; the caret's
  tail.
- **Navigation**: ⌘[ ⌘] back / forward, ⌥⌘→ ⌥⌘← focus in / out, ⌘P go to,
  and ⌘→ at a row's end for its attributes — Weft has its own ways.
- **Note** rows: Weft has no such type.

The earlier list, kept for the record:

Done since: folding by level and all by level (⌥⌘9 ⌥⌘0 ⌃⌥⌘9 ⌃⌥⌘0),
⌥-click to fold completely; maintain-level and rows-only moves; typed
row types with Delete and Undo giving the typing back; `- ` and `* `
making a bulleted row (written `*`; a `-` row is a body row); empty
typed rows turning plain; rows of any kind nested a level deeper;
joining a row into a code block inside its fence; wrapping chosen words
in ' " [ { (; curled quotes.

Note: 389 rows across 126 notes of the graph are written `*`; they will
draw as bulleted rows.
6. **Typing**: typed row types; wrapping; smart quotes.
7. **Rich text everywhere**: no Markdown in the view — not inline marks,
   not row markers — and every note as rows.
8. **Look**: Bike 2's handles, guides, no bullets on body rows, block
   selection, the caret's formatting cues, focus arrows; type styles.
9. **iPhone**: the same model, with touch.

Weft's own commands on these keys move: ⌃⌘↑ ⌃⌘↓ (Fold Card), ⌘Return
(checklist), ⇧⌘Return (task), ⌥⌘9 / ⌥⌘0 (fold all), ⌘P, ⌘D, ⌘L, ⌘Y,
⇧⌘A, ⇧⌘C, ⌘E.

## Found along the way

- An empty indented row written `  - ` reads back as part of the row
  above (`one - `): the row is lost.

## Not yet studied

- The caret's cues at a link's or a formatted run's edges, and ← → there.
- Selection drawing, row spacing, type styles (`style/*.ts` has them).
- Paste of several rows, drag and drop, find, filter.
