# Weft: the look, in numbers

Taken from the app this one replaces (`~/src/weft`), so the rewrite
looks like it. S is the text size setting (Mac default 14, range 11–22;
iOS default 17, range 14–24). Face: system, or New York (serif).

## Colours (light / dark)

| Token | Light | Dark | Alpha | Use |
|---|---|---|---|---|
| page | #F0ECE5 | #161412 | 1 | behind the river |
| paper | #FAF7F2 | #1D1B18 | 1 | folded card, Quick Open panel, link cards |
| card | #FDFCF9 | #23201D | 1 | open card, side panel |
| shelf | #F2EDE5 | #262320 | 1 | back faces of the backlink fan |
| text | #2B2724 | #ECE6DC | 1 | ink |
| secondary | #6F665D | #A79E92 | 1 | secondary text and icons |
| faint | #2B2724 | #ECE6DC | 0.32 | markup, placeholders, hints |
| rule | #2B2724 | #ECE6DC | 0.10 | card border, separators |
| hover | #2B2724 | #ECE6DC | 0.06 | hovered / chosen row; code background |
| accent | #265CD1 | #85ADFF | 1 | accent, tint |
| drawer | #6189E0 | #4B6BB5 | 1 | phone card drawer |

Derived: chosen card border accent@0.85, 1.5 pt; pill fill tint@0.12
(missing page: secondary tint, @0.10, italic); tag pill accent@0.12.

## Measures

Spacing scale 4 / 8 / 12 / 16 / 20. Card radius 12 (Mac) / 14 (iOS);
control radius 6.

Mac card: margin 24 | gutter 24 | content — text starts at x = 48;
trailing 20; top 7 (titled) / 10 (untitled) / 12 (folded); bottom 14
(12 folded); 8 between parts; 12 between cards, 6 after a folded one.
iOS card: sides 16 (compact) / 28; top 16 / 22; bottom 16 / 24; 14
between parts; 22 between cards, 11 folded.

River: Mac padding 20 × 16, cards at most 780 wide, centred, 22 more
each side for the rail; iOS 10 × 12 compact, else 28 × 22. Background
`page`.

Card: open fill `card`, folded fill `paper`; border `rule` 1 pt; shadow
black@0.07 r10 y3 open, @0.03 r4 y1 folded. Title round(S × 1.35)
semibold (iOS 22); to-do ring round(S × 1.3) (iOS 21). Folded: title
bold + two spaces + summary in `secondary`, 2 lines (3 on iOS).

Handle (Mac): 24 × (mark + 8), icon at mark × 0.92 in `secondary`@0.65
(1 on hover), hover fill text@0.08 r6. Mark size round((S + 1) × 0.95).
Icon: the page's own, else `calendar` (day), `checklist` (to-do),
`note.text`. Click: menu; double-click: fold; drag: move.

Card controls (Mac): 12 pt semibold symbols in 26 × 24, hover
primary@0.08 r6; shown when the card is chosen or hovered and not while
typing; fade easeOut 0.15. Day cards: `chevron.left`, `chevron.right`,
then `xmark`.

## Text

Body S, line spacing 3. Headings × [1.45, 1.25, 1.12, 1.05, 1, 1]
semibold. Code mono S × 0.92 on `hover`. Bold is semibold. Markup is
`faint` on the caret's lines and hidden elsewhere. Quote: indent 14,
`secondary`, bar 3 wide r1.5 `faint`. Lists: 20 per level, bullet
`faint`; a task's box round(S × 0.95), room ceil(S × 1.5): `secondary`
ring open, white tick on accent done, done text struck in `secondary`.

Pills: radius 5; height ascender + descender + 4; pad 1 with an icon,
3 without; icon side round(S × 0.72) drawn at × 0.9, lead room
4 + side + 3. Symbols: page `doc.text`, day `calendar`, web `link`,
river `square.stack`, tag none. Web addresses: scheme, `www.`, query,
fragment and trailing slashes hidden; three or more path parts keep the
first and last with `…` between. Not on the caret's line.

## Mac window

Default 1240 × 860, min 760 × 480. Sidebar 220–400 (ideal 270).
Inspector 280–480 (ideal 340); reading 360–900 (ideal 520).

Toolbar: river tabs after the sidebar toggle; then (conflicts only)
"N to Review" `exclamationmark.triangle` orange; New `plus` (hold: New
To-Do, New from Pasteboard); side panel `sidebar.trailing` (Related,
Read, Inspector).

Tabs: capsules, min height 26, 12 pt (semibold current, italic unsaved),
current fill text@0.09, hover text@0.05; equal widths while ≥ 112 each,
else current ≥ 150 and the rest bunch to icons (34 → 24); close `xmark`
9 pt in an 18 circle on hover.

Sidebar: search field (`magnifyingglass`, quaternary@0.5 r8, pad 8);
lens bar of six icon chips — Rivers `square.stack.3d.up`, Recent
`clock`, Inbox+Pinned `tray`, Reading `eyeglasses`, Tasks `checklist`,
Wiki `book.closed` — 13 pt, chosen accent on accent@0.14; rows: icon
`.caption` width 16, spacing 7, min height 24; footer "<graph> · N
pages" and the sync button `arrow.triangle.2.circlepath`.

Rail (more than one card): right edge, 8 in; ticks 3 high, 6 apart, 11
wide (18 current / hovered), accent current, faint@0.7 otherwise; on
hover a material panel r14 listing titles, right-aligned.

Quick Open: top, 12 down, max width 600, `paper` r14 continuous, shadow
0.18 r15 y8; field row 60 high, 21 pt, "Go to a page or a day", hint
"↩ Open   ⌘↩ New Tab" 11.5 pt faint; 9 rows × 40, name 15.5 pt, detail
12.5 pt faint, chosen row `hover` r8; always ends with New page “X” and
Search all text for “X”.

Backlink fan: 26 × 26 faces r7, 12 pt symbols, 3 stacked 5 apart +
"N links here" `.caption` secondary; on hover fanned 32 apart (up to
8, then "+N"), "Open All"; a face's summary card (280 wide) after
0.15 s.

Start page (empty river): column 640, Quick Open field on top, river
tiles 58 × 58 r14, Pinned (8) and Recent (10) rows 34 high.

## Keys (Mac)

File: New ⌘N · New To-Do ⇧⌘N · New from Pasteboard ⌥⌘N · New Tab ⌘T ·
Reopen Closed Tab ⇧⌘T · New Window ⌥⇧⌘N · Quick Open ⌘O · Open Folder
⇧⌘O · Close Tab ⌘W · Close Window ⌥⌘W · Sync Now ⌘R.
Edit: Find ⌘F · Find Page ⌥⌘F. Format: Checklist Item ⌘↩ · Task ⇧⌘↩.
Story: Today ⇧⌘D · Close All Cards ⇧⌘W · Fold ⌃⌘↑ · Unfold ⌃⌘↓ ·
Fold All ⌃⌥⌘↑ · Unfold All ⌃⌥⌘↓ · To-Do ⌃⌘K · Inbox ⌃⌘I · Pin ⌃⌘P ·
Home River ⌃⌘H · Read ⌃⌘R · Related ⌥⌘R · Inspector ⌥⌘I · Close Card
⌃⌘W · Delete ⌃⌘⌫ · Back ⌘[ · Forward ⌘] · Previous / Next Day ⌥⌘[ ⌥⌘]
· Previous / Next Card ⌥⌘↑ ⌥⌘↓ · Saved Rivers ⇧⌘R.
Window: Previous / Next Tab ⇧⌘[ ⇧⌘] · Tab 1–9 ⌘1…⌘9.
River, not typing: ↑ ↓ card · Space fold · Return write · ⌘⌫ delete.

Card menu: Fold · Make a To-Do / Mark Done · Home River ▸ · Pin · Add
to Inbox | Rename… · Choose Icon… · Read · Copy Link · More ▸ (Add Tag,
Add Field, Relate To…, Add to Wiki, Close Others, Find in It, Insert
Query…, Copy Contents, Show in Finder) | Close · Delete.

## Motion

Open a card, list changes: snappy 0.28 (insert opacity; remove opacity
easeOut 0.12). Scroll to a card: snappy 0.24, anchor top. Fold: snappy
0.22. Tabs: snappy 0.2. Hover fades: easeOut 0.12–0.15. Quick Open:
easeOut 0.12 opacity. Undo / sync notices: snappy 0.25 from the bottom.
Swipe settle: spring(0.32, 0.86). Phone drawer: spring(0.34, 0.82).
