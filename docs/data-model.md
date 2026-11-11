# The data model

What a graph is, what is in it, and everything the engine derives from it.

The model has three layers, and only the first is the truth:

| Layer | What | Where | Lifetime |
|---|---|---|---|
| **Files** | Markdown notes, saved rivers, assets | the working tree of a git repository | synced; the only thing that is |
| **In memory** | a file read into a `Note`, a `River`, a `Query` | `prism-markup` types | as long as an editor holds it |
| **Indices** | catalog, links, search, tasks, assets, times | SQLite at `.git/prism/index.sqlite` | derived per clone; disposable |

Nothing is stored that cannot be rebuilt from the files and their git
history. Delete the index and the engine rebuilds it; open the folder in
another editor and everything is there to read.

## The model in one page

A graph has very few kinds of thing.

- **A page** is a Markdown file. Its **path** is its identity, and its
  file's name — `ada` for `notes/ada.md` — is its **own name**: what a
  link to it is written with. Its **title** is its first heading: what
  it is shown as called. Two pages may have one title. It may have
  **aliases**.
- **A link** is one page pointing at another. `[[ada]]`, `![[ada]]`,
  `#person`, `tags: [Person]`, `related: [ada]` and
  `company: "[[acme]]"` are all links. One table holds them; one rule
  resolves them — a page's own name first, then a title, then an alias;
  what a link shows is its page's title, computed.
- **A field** is a frontmatter key with a text or list value. Fields
  carry no built-in meaning except `aliases`, `tags`, `private`, and the
  two lists of names, `related` and `list`. Anything that *marks* a page —
  pinned, inbox, wiki — is just a field, asked about with `is:`.
- **An order set by hand** is a list of links: a page's `list` field, or
  a river's cards. Any other order is `sort:` on a field.
- **Time** is git's. No page says when it was made or changed.
- **`private`** hides a page from every question unless the asker opted
  in.

And one rule about cost: **every question is answered from an index,
and costs what it finds, not what the graph holds.** Section
[21](#21-what-each-operation-costs) lists each operation with what backs
it.

Everything below is detail on those sentences.

Contents:

1. [The graph on disk](#1-the-graph-on-disk)
2. [Identity and names](#2-identity-and-names)
3. [A note](#3-a-note)
4. [Frontmatter](#4-frontmatter)
5. [Fields the engine reads](#5-fields-the-engine-reads)
6. [Links](#6-links)
7. [Typed fields](#7-typed-fields)
8. [The body: blocks](#8-the-body-blocks)
9. [Inline spans](#9-inline-spans)
10. [Queries](#10-queries)
11. [Saved rivers](#11-saved-rivers)
12. [Dates and times](#12-dates-and-times)
13. [Trees: the state of a graph](#13-trees-the-state-of-a-graph)
14. [Indices: how they are built and updated](#14-indices-how-they-are-built-and-updated)
15. [The index schema](#15-the-index-schema)
16. [Private pages](#16-private-pages)
17. [How writes flow](#17-how-writes-flow)
18. [Merging: the model under two writers](#18-merging-the-model-under-two-writers)
19. [Renaming](#19-renaming)
20. [What the model does not do](#20-what-the-model-does-not-do)
21. [What each operation costs](#21-what-each-operation-costs)

---

## 1. The graph on disk

A graph is a folder that is a git repository's working tree.

| Path | What it is | Indexed as |
|---|---|---|
| `daily/YYYY-MM-DD.md` | a day's page | a page |
| `weekly/YYYY-Www.md` | an ISO week's page | a page |
| `notes/**/*.md` | every other page, at any depth | a page |
| `rivers/<Name>.md` | a saved river ([§11](#11-saved-rivers)) | a source of links only |
| `assets/*` | pictures and other files pages show | a file that is there, and where it is shown |
| anything else | carried and synced, but no part of the model | — |
| `.git/prism/index.sqlite` | the indices; never committed | — |
| `refs/prism/backups/<ms>` | the branch as it was before each merge; never pushed | — |

**A page's kind is its path**, not its content
(`NoteKind::of`, [note.rs](../crates/prism-markup/src/note.rs)):

- `daily/2026-10-31.md` is `Day(2026-10-31)` — only if the name is a real
  date. `daily/notes.md` and `daily/2026-13-01.md` are not pages at all.
- `weekly/2026-W44.md` is `Week(2026-W44)` — only if that year has that
  week.
- `notes/….md` is `Note`.
- Everything else is not a page.

Paths are graph-relative, `/`-separated, and never contain an empty part,
`.`, `..`, `.git` or a backslash (`Graph::locate` refuses them).

A new page goes to its day's or week's file if its title is a date, else
to `notes/<slug>.md` — or `-2`, `-3`, … if taken. The slug is the title
NFC-normalised and lowercased, letters and digits of any script kept, runs
of spaces/`_`/`-` made one dash, at most 60 characters, never empty
(`untitled`), never a Windows-reserved name. It is written as `# Title`
and nothing else: no frontmatter is made that says nothing. Assets are
named the same way and never written over.

## 2. Identity and names

| | Example | What it is for |
|---|---|---|
| **path** | `notes/project-atlas.md` | the page's identity: the key in every index, what the engine's API takes. A rename keeps it. |
| **own name** | `project-atlas` | the file's name (`NoteKind::link_name`): what a link to the page is written with. No other page has it, and no rename changes it. A day's or a week's is its date. |
| **title** | `Project Atlas` | what the page is shown as called, and what a link to it shows. Pages may share one. |
| **aliases** | `Atlas` | other names it can be found and linked by |

There is no other identifier. A legacy `id:` line in a note is an
ordinary field.

**The title** (`Note::title(path)`), first that applies:

1. a day's or week's page is titled by its date, whatever it says;
2. the first block, if it is a non-empty `# Heading` — its text with
   inline markup taken out;
3. the file's name without `.md` — or `Untitled` if that name is a ULID.

`Note::set_title` rewrites that heading, making one if there is none.

**Names are compared by key**: `name_key` collapses runs of whitespace
and lowercases. Tags are names and use the same key.

**Resolving a name** (`Catalog::resolve`), in order:

1. a date — `2026-10-31` or `2026-W44` — always leads to that day's or
   week's path, whether the page is written yet (`Resolved::Note`) or not
   (`Resolved::Unwritten`);
2. the page whose **own name** it is, written exactly: `[[atlas]]` is
   `notes/atlas.md`, whatever else is called Atlas;
3. a page whose **title** has that key;
4. a page with that **alias**;
5. a page whose own name has that key, written some other way (`Atlas`
   for `atlas.md`, where nothing is titled so);
6. otherwise nothing: a page waiting to be written.

Of two pages that answer equally — two with one title — the one made
first is led to, so a page made later takes no link from one that was
there.

Step 2 before step 3 is what makes a page's own name its own. Step 3
before step 5 is what keeps a graph written before own names were what
links say: its links are written with titles, and go on leading where
they led — `[[Atlas]]` to the page titled Atlas, though another's file
is `atlas.md`.

**Apps write own names.** A link an app makes — completed, mentioned, a
river's card — is `[[project-atlas]]`, and shows as *Project Atlas*. A
link written by hand with a title, or by an earlier app, resolves by
step 3 and is left as it is until its title comes to mean something
else; then it is **pinned** ([§19](#19-renaming)).

**Titles are not unique, and nothing needs them to be.**
`Engine::create_note` always makes a new file: a second *Manifold* is
`notes/manifold-2.md`, titled Manifold. A new file never takes a name
that is another page's own name, title or alias
(`Engine::path_for_title`), so no link already written leads to it.
`Catalog::duplicates` lists the titles and aliases more than one page
has, for an app that wants to show them.

### Untitled notes and labels

A note is **untitled** when it has no first `# Heading` and its file's
name says nothing: only an id, or `untitled`, or `untitled-` and a stamp
(`notes/untitled-2026-11-10-135831-jmgs.md`). Its *title* is then its
own name — which is what a link to any page says — but nothing shows it.

**Its first words are its name.** Everywhere a titled note goes by its
title, an untitled one goes by its label (`Note::names`): it is what the
catalog lists and orders it by, what completion and `title:` find it
by, what a link written by hand — `[[Ads paper]]` — resolves to, at a
title's rank, and what search ranks it by and shows it under. Its
first words changed, its name is changed. A note with no title and
nothing written has no name: "Untitled" is what many are shown as, not
what one is called.

What a note is shown as called is its **label** (`note::label`,
`Note::label`, `Session::label`): a titled note's title; an untitled
one's first words — the first line of its body that says anything, markup
taken out, cut to 80 characters — or "Untitled" when nothing is written.
The catalog keeps `label` and `untitled` beside `title`, so a list of any
length shows labels without reading a note.

## 3. A note

```text
Note
├── frontmatter: Option<Frontmatter>     the `---` header, when there is one
└── body: Document
    ├── blocks: Vec<Block>               a tree
    ├── trailing_blank, final_newline    how the file ends
    └── line_ending                      LF or CRLF
```

`Note::parse` never fails, and `Note::to_markdown` on an unchanged note
gives back the bytes it was read from — for every input. An edit rewrites
only the lines edited. The rest of the model leans on this: git merges by
line, other apps read the same files, and neither forgives an editor that
reformats what it did not touch.

Two things are derived from a note on demand; neither is stored in it:

| | Holds |
|---|---|
| `Meta` | `title`, `aliases`, `tags`, `private` — and nothing else |
| `References` | `links` ([§6](#6-links)), `web_links`, `images`, `tasks` |

`Meta` is small on purpose. Times are git's; marks are fields.

## 4. Frontmatter

The header between `---` fences
([frontmatter.rs](../crates/prism-markup/src/frontmatter.rs)).

**Every value is text or a list of text.** No numbers, booleans or
nesting at this level; meaning is given by whoever reads a key.

| Written | Read as |
|---|---|
| `key: value` | text; a trailing ` # comment` dropped |
| `key: "quoted"` / `'quoted'` | text, unquoted, escapes resolved |
| `key: [a, "b, c"]` | a list |
| `key:` then `- item` lines | a list |
| `key: \|` or `>` then indented lines | text, kept or folded |
| a blank line, a `# comment` | kept, as no entry |

- **Lossless.** Each entry keeps the lines it was read from; writing back
  emits them untouched. Only an entry `set` to a *different* value is
  rewritten, in place. A new key goes at the end.
- **Text and a list of one are the same** when a list is asked for.
- **A list written an item a line stays that way** when rewritten, so two
  devices adding items change different lines.
- The header is recognised only when the first line is `---`, a later
  line is `---` or `...`, that fence ends in a line break, and line
  endings agree. Otherwise the whole file is body.

**One reading of yes and no** (`frontmatter::truth`): `true`, `yes`,
`on`, `1`, `y` are yes; `false`, `no`, `off`, `0`, `n` are no; anything
else is neither. Everything that asks a yes/no question uses it.

**A field marks its page** (`is_set`, `Frontmatter::flag`) when it is
there with a value that does not say no. `private: true`, `pinned: 3` and
`topic: Maths` all mark; `inbox: no` and a bare `inbox:` do not.

## 5. Fields the engine reads

Five keys have meaning to the engine. Every other key is the user's:
kept, indexed, queryable, and typed if a tag says so.

| Key | Shape | Meaning |
|---|---|---|
| `aliases` | list | other names the page answers to |
| `tags` | list | tags — links of kind tag ([§6](#6-links)); a leading `#` is dropped |
| `private` | mark | hidden unless asked for ([§16](#16-private-pages)) |
| `related` | list of names | links to other pages, plain or as `[[links]]` |
| `list` | list of names | pages in an order set by hand ([§10](#10-queries)) |

And one on a tag's page:

| Key | Shape | Meaning |
|---|---|---|
| `fields` | list | the typed fields of pages with the tag ([§7](#7-typed-fields)) |

Everything else people use — `pinned`, `inbox`, `topic`, `template`,
`wiki`, `cover`, `snoozed_until`, `river` — is a plain field. The engine
gives none of them special treatment; a query asks about any of them the
same way (`is: pinned`, `has: cover`, `sort: pinned`).

A saved river's frontmatter has keys of its own
([§11](#11-saved-rivers)).

## 6. Links

**There is one kind of pointer from a page to a page**
(`NoteLink`, [note.rs](../crates/prism-markup/src/note.rs)):

```text
NoteLink
├── target   the name pointed at, as written
├── label    what it shows, when not its target
├── kind     Link | Embed | Tag
├── field    the frontmatter key it is under; None in the body
└── block    where in the body: the block's path; empty in frontmatter
```

| Written | kind | field |
|---|---|---|
| `[[Ada]]`, `[[Ada\|shown]]` in a line | Link | — |
| `![[Ada]]` in a line | Embed | — |
| `#person` in a line | Tag | — |
| `tags: [Person]` | Tag | `tags` |
| `related: [Ada]`, `list: [Ada]` — plain or `[[Ada]]` | Link | `related`, `list` |
| any other field whose value is written `[[Ada]]` | Link | that key |

Not links: `aliases` (what a page calls itself), and a plain value in any
field other than `related` and `list`.

Because they are one thing:

- **One index** holds them ([`links`](#15-the-index-schema)).
- **Backlinks are all of them.** The pages tagged `#person` are among
  the backlinks of the page Person, with `kind = Tag`. `tag: Person` and
  `links to: Person` differ only in which kinds they count.
- **One rename rewrites them** ([§19](#19-renaming)).
- **A typed `link` field is a real link**: `company: "[[Acme]]"` shows up
  in Acme's backlinks.

**Links hold names, and are resolved when asked.** Nothing is resolved
when a link is indexed, so a page created later is linked to by links
written before it. The name an app writes is the page's own
([§2](#2-identity-and-names)); a page's backlinks are the links that
*lead to it* (`Links::leading_to`) — not every link that says a name it
has. Of two pages titled Manifold, a link written `[[Manifold]]` is one
page's only, and a link written `[[manifold-2]]` is the other's.

**What a link shows is computed.** `[[project-atlas]]` shows the page's
label — its title, or an untitled note's first words — wherever an
editor draws it; `[[project-atlas|the project]]` shows the words given.
What is written is not changed by it.

**A tag is a word, not a pointer.** `#person` and `tags: [Person]` match
by key, as they always did, and lead to the page that name resolves to.
They are never rewritten to a file's name.

`Note::references()` also gathers, in the same pass and never from code:

| | Fields | From |
|---|---|---|
| `WebLink` | `url`, `block` | `[…](url)`, `<url>`, bare URLs |
| `ImageRef` | `source`, `alt`, `width`, `height`, `block` | `![…](…)` |
| `TaskRef` | `block`, `text`, `done` | every list item with a checkbox |

## 7. Typed fields

A tag gives the pages tagged with it a schema. The tag's **own page** —
the page the tag's name resolves to — lists the fields
([fields.rs](../crates/prism-markup/src/fields.rs)):

```yaml
# notes/person.md
fields:
  - birthday (date)
  - company (link)
  - status (active | paused | done)
  - rating (number)
  - website (url)
  - met (yes/no)
  - notes
```

| Spec | `FieldKind` | A value reads as | Valid when |
|---|---|---|---|
| `name` | `Text` | the text | always |
| `name (number)` | `Number` | `f64` | a finite number |
| `name (date)` / `(day)` | `Date` | a `Day` | `YYYY-MM-DD`, bare or in `[[ ]]` |
| `name (link)` / `(page)` | `Link` | a page's title | not empty; `[[Title\|shown]]` reads as `Title` |
| `name (url)` / `(web)` | `Url` | the address | starts `http://` or `https://` |
| `name (yes/no)` / `(flag)` / `(bool)` | `Flag` | `bool` | [yes or no](#4-frontmatter) |
| `name (a \| b \| c)` | `Choice([..])` | the option, as the spec spells it | one of the options, case aside |

- **Values stay frontmatter text.** Typing is a reading:
  `FieldKind::read` returns `None` for text that is not a value of the
  kind, and an app shows that text as it is.
- **An unknown kind is text**, so a newer app's kinds degrade.
- **A page's schema** (`Catalog::schema(path)`) is the specs of each of
  its tags, in the order of its tags, each field name once. `tags`,
  `aliases` and `private` cannot be redefined.

## 8. The body: blocks

A `Document` is a tree of `Block`s
([block.rs](../crates/prism-markup/src/block.rs)).

```text
Block
├── kind       what it is
├── text       its content as Markdown, without its marker
├── children   blocks nested in it — only a list item has any
└── layout     how it was written: blank lines before, spacing, indentation
```

| `BlockKind` | Written | `text` holds |
|---|---|---|
| `Paragraph` | plain lines | the lines |
| `Heading(1–6)` | `## text` | what follows the hashes |
| `Item { marker, task }` | `- text`, `1. text`, `+ [ ] text` | the item's text |
| `Quote` | `> text` | the lines without `>`; a callout if the first is `[!KIND]` |
| `Code` | a fenced block | all of it, fences included |
| `Table` | a pipe table | its lines (`Table::parse` gives cells) |
| `Rule` | `---`, `***`, `___` | the rule as written |
| `Raw` | anything else | the lines exactly |

An item's `marker` is `Bullet('-' | '*' | '+')` or
`Ordered { number, delimiter }`; its `task` is `None`, `Open`, or
`Done('x' | 'X')`. **Any item with a checkbox is a task**; which bullet it
uses is how it was written, not what it is.

**Nesting is Markdown's lists and nothing else.** A heading does not own
what follows it; a section is computed (`outline::section_len`).

**One tree, two editors.** An outline editor walks `Document::rows()` and
restructures with [`outline`](../crates/prism-markup/src/outline.rs):
`indent`, `outdent`, `move_up`, `move_down`, `remove`, `insert`,
`duplicate`, `split`, `join_with_previous`, `toggle_task`, `set_kind`,
`renumber`. A prose editor walks the top-level blocks.

**A block's address is its path**: an index at each level — `[1, 0]` is
the first child of the second top-level block. Paths are positions, not
identities. Blocks have no ids, and none are written into the file.

**A block is known again by its text.** Whatever hands out a path that
may go stale hands out the block's text with it. `Document::locate(hint,
text)` finds the block as the document is now: at the path if it still
has that text, else the block with that text nearest to where the path
would stand, one at the same depth first. `Engine::set_task(path, block,
text, done)` is built on it.

**A fold is not part of the note.** An outline can show a block without
what is under it; which blocks are folded is kept by whoever shows the
note — a river keeps it per card ([§11](#11-saved-rivers)) — and handed
to the editing `Session`, which holds it on the tree while the note is
open (`Block::folded`, never written, never set by reading) so that a
block moved takes its fold with it. `Session::folded_rows` and
`set_folded_rows` give and take folds as a river keeps them: a row's
index among all the body's rows, and its text.

**A time block is a list item that starts with a time**: `9:00–10:30
Deep work`, `11am Standup`. A list whose every item starts so — two or
more, or one that says when it ends — is a timeline (`time::find`), and
an outline draws it as one. Nothing but the words says so.

**Losslessness** rests on two things: `Layout` records what the writer
needs to give back the same bytes; and any top-level chunk that would
still not write back as read is kept whole as a `Raw` block, checked at
parse time. On the 2,118-note graph this was built against, one block in
22,829 is raw.

## 9. Inline spans

Inline markup is **not** part of the tree. A block's `text` stays the
Markdown it was written in; `inline::parse(text)` finds what it means, as
`Span`s ([inline.rs](../crates/prism-markup/src/inline.rs)) — each a
`kind`, the byte `range` of the whole span, the `content` it shows, and
`children`.

| `SpanKind` | Written |
|---|---|
| `Strong`, `Emphasis`, `Strikethrough`, `Highlight` | `**…**`, `*…*`, `~~…~~`, `==…==` |
| `Code` | `` `…` `` |
| `Link { target, title }` | `[text](url "title")` |
| `Autolink { url }`, `Url` | `<https://…>`, a bare `https://…` |
| `WikiLink { target, label, embed }` | `[[Title]]`, `[[Title\|shown]]`, `![[Title]]` |
| `Image { source, alt, width, height }` | `![alt](src)` and, straight after, `<!-- {"width":425,"height":270} -->` |
| `Tag(name)` | `#tag` — starting a word; `#work/deep-focus` is one tag, `a#b` and `#1` are none |
| `Comment`, `Escape` | `<!-- … -->`, `\*` |

Spans are computed, never stored, so they cannot disagree with the file.
Ranges are UTF-8 byte offsets in Rust; the Swift bindings convert them to
UTF-16 offsets, ready for `NSRange`.

## 10. Queries

A fenced code block with the info string `query` is a live list of pages
([query.rs](../crates/prism-markup/src/query.rs) parses,
[prism-index/query.rs](../crates/prism-index/src/query.rs) runs).

````markdown
```query
tag: Person
is not: archived
sort: -modified
limit: 10
```
````

A clause a line. `{this}` in a value stands for the title of the page the
query is written in.

| Clause | Keeps the pages … |
|---|---|
| `tag: X` / `not tag: X` | tagged X, or not |
| `title: words` | whose title contains every word, case aside |
| `text: words` | that the search index matches for every word |
| `links to: X` | that point at X by any of its names, by any kind of link |
| `linked from: X` | that X links to |
| `listed in: X` | in the hand-set order X names (below) |
| `has: a, b` | whose frontmatter has every one of the keys |
| `is: day` / `week` / `note` | of that kind |
| `is: conflicted` / `blank` | left holding a conflict; with nothing written in them |
| `is: <field>` | [marked](#4-frontmatter) by that field: `is: pinned`, `is: inbox` |
| `is not: …` | that `is:` would leave out |

| Clause | Sets |
|---|---|
| `sort: key` / `sort: -key` | the order (below) |
| `limit: n` | how many are returned (`total` still counts them all) |
| `show: list` / `inline` / `table` / `cards` / `count` / `tree` | how an app should show them |
| `columns: a, b` | a table's fields |

### Order

There are two ways to order pages, and only two.

**By a key** — `sort:` with `title`, `created`, `modified`, or *any
field*. A field's numbers sort by size and come before its words; pages
without the field come last, whichever way. So `sort: pinned` puts
`pinned: 1` before `pinned: 2` before `pinned: true`, with no rule of its
own.

**By hand** — a list of links, wherever it is written:

| `listed in:` | reads |
|---|---|
| a page's name | that page's `list` field |
| `rivers/Work` | that river's cards |

Without a `sort:` line a query uses a hand-set order if it names one: the
`listed in:` list, else the `list` of the first tag's page (those pages
first), else title.

**A query is one SQL statement.** Its conditions are the `WHERE`, its
order the `ORDER BY`, its limit the `LIMIT`; SQLite runs it over the
indices. No page is loaded to be filtered out or sorted away, and
`sort: -modified` with `limit: 10` walks an index of when pages changed
and stops at ten. `total` — how many there were before the limit — is a
`count(*)` over the same conditions, run only when the limit was reached.

- **Default columns** — the typed fields of the first tag asked for.
- **A line not understood is kept** as `Clause::Unknown` and written back
  as it was. It filters nothing.

## 11. Saved rivers

A river is a named run of cards. One worth keeping is a file,
`rivers/<Name>.md` ([river.rs](../crates/prism-markup/src/river.rs)):

````markdown
---
folded:
  - Beta
---
- [[Pinned]]
  - 4: Projects

```query
sort: -modified
```
- [[Kept Here]] @ 1000 2026-11-03T10:00:00.000Z
````

```text
River
├── cards: Vec<Card>      held by hand, in order
├── query: Option<Query>  what it finds, for a query river
├── placed: Vec<Card>     cards put by hand among what the query finds
├── folded, opened, hidden: Vec<String>   titles
├── icon, color, place    how and where it shows among the rivers
└── source                the file it was read from

Card { title, folded_rows: [(index, text)], place: Option<(rank, sort key)> }
```

**A river's file is Markdown, and its cards are links.** That is the
whole of how it fits the model:

- The links index reads rivers as sources of links. A river holding a
  page is among that page's backlinks, and `listed in: rivers/Work`
  orders a query by its cards.
- A river's cards and its `folded`/`opened`/`hidden` lists say pages'
  own names, as links do. One written with titles is read by resolving
  them, and pinned as a page is ([§19](#19-renaming)), with no code of
  its own.
- A folded row is remembered by its index and its text, the same way any
  block is [known again](#8-the-body-blocks).

**A river is not a page.** It is not in the catalog, search or tasks; no
title resolves to it. A link to one is written to its file —
`[[rivers/Work]]`.

**Unchanged, it writes back the bytes it was read from.** Changed, it is
written in the one canonical form, keeping the frontmatter it was read
with, so a key a newer app added survives. Body lines that are no card,
row or query do not survive a change. A river made from nothing and saved
over an existing file keeps that file's unread frontmatter too.

## 12. Dates and times

[date.rs](../crates/prism-markup/src/date.rs).

| Type | Written | Notes |
|---|---|---|
| `Day` | `2026-10-31` | exactly `YYYY-MM-DD`, a real calendar day |
| `Week` | `2026-W44` | exactly `YYYY-Www`, an ISO week that year has |
| `Timestamp` | `2026-10-31T10:34:00Z` | ISO 8601, kept as seconds since the Unix epoch |

A day's name is both its page's title and a valid link target, so
`[[2026-10-31]]` always leads somewhere.

**No page says when it was made or changed.** That is read off git
([§14](#times)). A `created:` or `modified:` line in a note is an
ordinary field.

## 13. Trees: the state of a graph

The model's notion of "a version of the graph" is a **git tree id**.

`Repository::snapshot` ([repo.rs](../crates/prism-sync/src/repo.rs))
hashes the working tree into a tree object — HEAD's tree with every file
added, changed or deleted since — without touching the index or HEAD.
Left out: what `.gitignore` ignores, `Config::exclude`, and files at or
over `Config::max_file_bytes` (95 MB by default).

`Repository::snapshot_paths(base, paths)` gives the same tree for one who
knows what changed: `base` with each of `paths` as it is now on disk. It
hashes those files and rewrites only the directories along their paths,
each once — the cost is the files written, not the files there are. It
answers `None` where the paths alone cannot say (a directory, a link,
`.gitignore`), and a full snapshot is taken instead.

- **"Is there anything to commit?"** is `snapshot.tree != HEAD's tree`.
- **"What changed?"** is a tree diff, whose cost is the size of the
  change.
- **Anything derived** records the tree it was derived from.

## 14. Indices: how they are built and updated

[prism-index/lib.rs](../crates/prism-index/src/lib.rs).

### The contract

```rust
trait Index {
    fn name(&self) -> &'static str;   // its key among the cursors
    fn version(&self) -> u32;         // bump to force a rebuild
    fn create(&self, tx);             // make the tables, if absent
    fn clear(&self, tx);              // empty them
    fn wants(&self, path) -> bool;    // default: pages only
    fn remove(&self, tx, path);       // undo everything put wrote for path
    fn put(&self, tx, file);          // add one file
}
```

**After any sequence of calls, the tables hold exactly what `put` would
have written for the files of the cursor's tree.**

### The cursor

```sql
CREATE TABLE prism_cursors (name TEXT PRIMARY KEY, version INTEGER NOT NULL, tree TEXT) WITHOUT ROWID;
```

### An update

`Indexer::update(repo, tree)`:

1. Find where each index starts: its cursor's tree — or nothing (a
   rebuild) when it has no cursor, its version changed, or git no longer
   has that tree.
2. Nothing to do if every index is already at `tree`.
3. Open one transaction; `clear` each index that is rebuilding.
4. Diff once per distinct starting tree. A rebuild is the same code: a
   diff from the empty tree.
5. For each changed path an index `wants`: `remove` if the file existed,
   `put` if it exists now.
6. Move every cursor to `tree`, and commit.

An index is always exactly some tree's, never between two; the cost of an
update is the size of the change. A `File` handed to `put` is read and
parsed at most once, however many indices look at it.

### Times

[times.rs](../crates/prism-index/src/times.rs) keeps, for each page, the
time of the first commit that has it and of the last that changed it.
**Its cursor is a commit**, not a tree, because a time is a fact about
history. `Indexer::update_times(repo, head)`:

1. If the commit last seen is `head`: nothing to do.
2. If it is an ancestor of `head`: walk only the commits since, oldest
   first. Otherwise clear and walk them all.
3. For each commit, a page added or changed takes the commit's time; a
   page deleted is forgotten.
4. **A merge dates only what it settled**: a page counts as changed by a
   merge only where it differs from *every* parent.

Pages written but **not yet committed** are listed after each snapshot
with their files' modification times (`Indexer::set_unsaved`).

| A `NoteRow`'s | is the first of |
|---|---|
| `created` | first commit · file time, if never committed |
| `modified` | file time, while uncommitted · last commit that changed it |

Three tables: `prism_times` is what history says, `prism_unsaved` what
the working tree adds, and `prism_dates` the two put together — the time
that applies — kept in step with them and **indexed on `created` and on
`modified`**. It is what a `NoteRow` and `sort: modified` read.

**A whole history is read apart.** `Times::history(repo, head)` walks
every commit without touching the database; `Indexer::set_history` then
writes what it found in one short transaction. The engine runs the walk
on a thread of its own, so a first launch goes on indexing what is typed
while 5,079 commits are read (2.8 s on the real graph, once per clone).
After that only new commits are read, on the indexing thread, in
microseconds.

### What triggers an update, and what it looks at

The engine's indexing thread ([§17](#17-how-writes-flow)) brings the
indices up to the working tree:

| When | It looks at |
|---|---|
| at start | every file (what was written while no engine ran) |
| after a write through the engine | the files written, and no others |
| told `paths_changed`, or by the watcher | those files |
| after a sync cycle | what the sync committed — which looked at every file itself — plus the files not yet committed and those written since |
| told `note_changed`, with no paths | every file |

Ten saves queued together are indexed once.

### Storage

One SQLite database, WAL mode, inside `.git/` so it is never committed.
The engine's thread is the only writer. Apps read on their own threads
through read-only connections, never blocking or blocked by an update.

On the 2,115-page graph: a full build takes 1.3 s; an edited note is
written, snapshotted and indexed in about 4 ms (release build).

## 15. The index schema

### `catalog` — pages, names, fields (version 6)

```sql
notes       (path PRIMARY KEY, title, kind, private, conflicted, blank, label, untitled)
            -- indexed on (label, path); on path where conflicted
note_names  (key, name, path, rank)                 -- indexed on key, on path
name_words  (suffix, path, score)                   -- indexed on suffix, on path
note_fields (path, key, position, value, number)    -- indexed on (path, key), on (key, value)
```

| Column | Holds |
|---|---|
| `notes.kind` | `day`, `week` or `note` |
| `notes.conflicted` | the file holds a whole conflict block ([§18](#18-merging-the-model-under-two-writers)) |
| `notes.blank` | nothing is written in it: no blocks, or only empty bullets |
| `note_names.rank` | `-1` the page's own name (its file's); `0` the title, or an untitled note's first words; `1` an alias |
| `name_words.suffix` | a name's key from one of its words on: `ada lovelace` gives `ada lovelace` and `lovelace` |
| `name_words.score` | for a title or an alias, `rank × 2`, plus 1 for a suffix that is not the whole name: lower is a better find |
| `note_fields` | every frontmatter key, a row a value: a list is a row an item, in order. A key written twice is read as its first |
| `note_fields.number` | the value as a number, where it is one: what `sort:` by a field goes by first |

Tags are in `links`; times are in the times tables; marks are rows of
`note_fields`. Any key can be asked about without a schema change.

**Completion is a range of an index.** What is typed is looked up as a
prefix of `name_words.suffix` — `suffix >= 'love' AND suffix < 'love…'` —
so it finds a name by its start or by any word in it, and costs what it
finds.

Asks: `get`, `all`, `count`, `resolve`, `answering`, `called`,
`own_name`, `duplicates`, `names`, `complete`, `conflicted`, `tagged`, `tags`, `tags_of`, `fields`,
`with_field`, `field_specs`, `schema`.

### `links` — every pointer (version 3)

```sql
links (source, key, target, kind, field, block, context)  -- indexed on key, on source
```

| Column | Holds |
|---|---|
| `source` | the file the link is in: a page, or a saved river |
| `target`, `key` | the name as written; its `name_key` |
| `kind` | `link`, `embed` or `tag` |
| `field` | the frontmatter key it is under; empty in the body |
| `block` | the block's path as dotted indices (`1.0`); empty in frontmatter |
| `context` | that block's text as Markdown |

Asks: `backlinks` (given every name a page answers to), `outgoing`,
`linked_pages` (the pages a file links to, in order — what a hand-set
order is read from), `unresolved` (names no page answers to; dates, tags
and rivers left out).

### `search` — full text (version 2)

```sql
CREATE VIRTUAL TABLE search USING fts5(path UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2');
```

`body` is the note as it reads, Markdown taken out. Frontmatter is not in
it. Every word typed must match, the last as a prefix; a title match
counts eight times a body match.

### `tasks` — every checkbox (version 1)

```sql
tasks (path, block, text, done)            -- indexed on path, on done
```

### `assets` — files, and where they are shown (version 1)

```sql
asset_files (path PRIMARY KEY)             -- every file in assets/
asset_uses  (asset, path, block)           -- indexed on asset, on path
```

A row in `asset_files` for each file in `assets/` (that it is there; its
bytes are never read), and a row in `asset_uses` for each picture a page
shows from there. Pictures on the web are not assets.

Asks: `all`, `used_in` (the pages showing an asset), `shown_in` (the
assets a page shows), `unused` (files nothing shows — private pages
counted, whoever asks: a file only a private page shows is not one to
clear out), `missing` (pictures shown that are not there).

### `times`

```sql
prism_times   (path PRIMARY KEY, created, modified)   -- from commits
prism_unsaved (path PRIMARY KEY, modified)            -- written, not yet committed
prism_dates   (path PRIMARY KEY, created, modified)   -- what applies; indexed on created, on modified
```

## 16. Private pages

**A page marked `private` is seen only where it is asked for outright.**

The choice belongs to the *connection* asking, so it is made once, where
a view is set up, and cannot be forgotten at one call among many:

| Connection | Sees private pages |
|---|---|
| `Engine::index()` | no |
| `Engine::index_showing_private()` | yes |
| `prism_index::show_private(&db, bool)` | switches a connection |

Hidden means hidden from **every** question: catalog listings and
lookups, name resolution and completion, tags and their counts,
backlinks from the page, tasks in it, search, unresolved links it wants,
and queries. A link *to* a hidden page simply does not resolve.

Two things always see everything, because they act on the graph rather
than show it: the engine's own operations (a rename rewrites a private
page's links too; a new note's file avoids a private page's names), and
commit messages, which never name a private page.

## 17. How writes flow

```text
 app ──write──▶ Graph ──▶ file on disk (atomic; only if different)
                  │
                  └─ the path ─▶ INDEXING THREAD
                                   │ snapshot_paths(last tree, [path]) ──▶ tree id
                                   │ Indexer::update(tree)  ──▶ Event::IndexUpdated { tree, changed }
                                   │ times: new commits; what differs from HEAD
                                   │ tree ≠ HEAD's? ──▶ tell the syncing thread
                                   ▲                               │
                    "look again"   │                               ▼
                                   │                        SYNCING THREAD
                                   │        (30 s after writing pauses, 5 min at most)
                                   │          commit ─ fetch ─ merge ─ apply ─ push
                                   └────────── "I wrote the tree" ◀─┘
                                                                    ▼
                              Event::FilesChanged(paths), Event::SyncFinished
```

**Two threads, each doing one thing at a time.**

- The **indexing thread** is the only writer of the indices. Of the
  repository it reads the working tree and writes objects, and nothing
  else: never git's index file, never a branch.
- The **syncing thread** is the only one that commits, moves branches
  and writes the working tree.

They share the repository's object store, which git lets any number
write to, and two channels. So **indexing never waits for the network**:
while a sync is talking to a remote, what is typed is indexed as it is
written, and making or renaming a page — which ask the index — answer at
once. The syncing thread does wait for the indexing thread, once per
cycle, so that what a sync wrote is indexed before anyone is told it
changed.

A note from the indexing thread that "there is something to commit" is
dated by how many sync cycles had run when it was observed. One that
arrives after a later cycle is not trusted; the indexing thread is asked
to look again.

**Two surfaces, split by what they need.** `Graph` does what needs only
the files: read, write, save a draft, delete, add an asset, read and save
a river, tick a task. `Engine` does what needs the index: make a note
(which file names are free?), rename a page or an alias (what points at it?),
run a query. There is one way to do each.

- **Files are written whole or not at all**, and only when the content
  differs.
- **The engine never stamps a note.**
- **Events carry paths and a tree, not content.**
- **`settle()` waits for indexing only** — and, on a first run, for the
  history read. It does not wait for a sync.
- **A push is scheduled only when the working tree differs from HEAD.**

## 18. Merging: the model under two writers

**A note with frontmatter on both sides is merged as a note**
([note_merge.rs](../crates/prism/src/note_merge.rs)):

| Part | Rule |
|---|---|
| a list field, on both sides | merged as a set: what either added is kept, what either removed is gone |
| any other field | the side that changed it; if both did, this device's — the one doing the merge. The other's value is still in history. |
| the body | three-way by lines; neighbouring lines edited by different devices do not conflict |

The merged frontmatter is written over this device's, so its comments,
order and spacing stay. A note where either side has no frontmatter is
merged by lines throughout.

**Where both changed the same lines**, both are kept in the file between
markers, and the file is committed like any other:

```text
<<<<<<< this device
…
=======
…
>>>>>>> other device
```

A conflict is *data in a note*, found by `conflict::detect` and settled
by editing the note. Nothing waits on it.

**Other files:** one side changed and the other deleted — the file is
kept. A binary both changed — both are kept, the other as
`name (conflict).ext`.

**An editor's draft is merged the same way** by `Graph::save_merging`.

## 19. Renaming

A link written with a page's own name needs nothing when the page is
renamed: the file stays where it is, the link leads to it, and shows the
new title. So a rename is one line changed in one file.

What needs care is a link written with a **title** or an **alias** — by
hand, by another tool, or before own names were what links say. It
leads where it does because of what pages are called, and that can
change. So before a name comes to mean something else, the links
written with it are **pinned**: rewritten with the own name of the page
they lead to (`Note::pin`, matching by name key, never inside code):

- `[[old]]`, `[[old|shown]]`, `![[old]]`, including `[[old\|x]]` in
  tables;
- in query blocks, the value of `links to:`, `linked from:` and
  `listed in:`;
- in frontmatter, any list item or whole text value equal to the name,
  plain or as a `[[link]]` — except under `aliases`, `caption` and
  `tags`.

Left as they are: tags (`#old`, `tags:`, `tag:` in a query), which are
words; and a link written exactly as another file's own name, which is
that file's.

A name is pinned when:

| What happens | Pinned first |
|---|---|
| `Engine::create_note(title)`, and the title is already a page's | links written with the title, to the page that had it |
| `Engine::rename_note(path, new)` | links written with the old title, to this page; and links written with the new title — if it is another page's — to that page |
| `Engine::rename_alias(path, alias, new)` | links written with the old alias; and with the new one, if another page is called by it |
| `Engine::remove_alias(path, alias)` | links written with the alias |

After that no link has moved: each leads where it led.

`rename_note` is refused for a title that is a date (`TitleTaken`: it
would name a day's page) and for a day's or week's page
(`NotRenamable`). A title another page has is not refused.

**Nothing is rewritten that does not have to be.** A graph of title
links is not converted at once: a link is pinned when its title is
about to change meaning, and not before.

## 20. What the model does not do

- **Blocks have no stable ids.** Two blocks with the same text at the
  same depth, both moved, can be mistaken for each other. There are no
  block references.
- **No index of web links.**
- **Assets are not dated**, and their contents are never read.
- **A tag does not follow a rename.** `#person` goes on saying person
  when the page it leads to is retitled People; it still leads there,
  by the page's own name where that is `person`.
- **Two devices can each change what a title means before they sync** —
  one renames a page while the other writes a link with its old title.
  Each pins what it can see; a link written meanwhile with the title
  resolves as any title does, to the page made first.
- **What a link shows is computed where an editor draws it, and not in
  an index.** A folded note's first words, a search snippet and a
  backlink's context show what is written: a link's own name.
- **Aliases edited by hand are not relinked.** Only `rename_alias` and
  `remove_alias` rewrite links.
- **Nested tags are not a hierarchy.** `#work/deep` is one tag;
  `tag: work` does not match it.
- **Typed fields are not enforced.**
- **Frontmatter is flat.** Nested YAML is read as text.
- **Times follow a path.** A file moved by hand is a new page made then.
- **A field both devices changed keeps the merging device's value**,
  silently.
- **Sorting folds case for ASCII only** where SQLite does the comparing.

## 21. What each operation costs

Every question an app asks is answered from an index. "Costs" below is
what the work grows with. Times are on the real graph — 2,115 pages,
22,829 blocks, 5,079 commits — in a release build on a laptop.

| Operation | Backed by | Costs | Measured |
|---|---|---|---|
| Save a note and have it indexed | `snapshot_paths`; a tree diff; one transaction | the files written | 4 ms |
| Resolve a link's name | `note_names (key)` | one lookup | — |
| Complete a title as it is typed | `name_words (suffix)`, a range | what it finds | 56 µs |
| Backlinks of a page | `links (key)`, each checked against `note_names (key)` | the links written with its names | 261 µs for 494 |
| Pages with a tag | `links (key)` | the pages tagged | 207 µs for 172 |
| Pages a field marks (`is: inbox`) | `note_fields (key, value)` | the pages with the field | 96 µs for 62 |
| First 20 pages by title | `notes (title, path)` | the limit | 58 µs |
| The 10 pages changed last | `prism_dates (modified)` | the limit | about 1 ms¹ |
| A tag's pages, the 10 changed last | `links (key)`, then `prism_dates` | the pages tagged | 178 µs |
| Days with something written, newest 30 | `notes (title, path)` | the days scanned to find 30 | 270 µs |
| Full-text search, 20 hits | FTS5 | the matches | 156 µs |
| Pages left in conflict | `notes (path) WHERE conflicted` | the conflicted pages | 7 µs |
| Where an asset is shown; unused assets | `asset_uses (asset)` | the uses; the files | — |
| Open tasks | `tasks (done)` | the open tasks | — |
| Rename a page | `links (key)` to find what points at it | the files that point at it | — |
| Make a note (is the name taken?) | `note_names (key)` | one lookup | — |
| Index after a sync | the tree the sync committed + files not committed | what the sync changed | — |
| Page times after a commit | commits since the cursor | the new commits | 77 µs with none |
| Build every index from nothing | — | the graph | 1.3 s, once |
| Read a whole history for times | — | the history; off the indexing thread | 2.8 s, once |

¹ In this measurement every page had been committed in one commit, so
all 2,115 share a time and are ordered among themselves by title. The
query plan walks the index of `modified`; with distinct times it should
stop after ten rows, which this measurement does not show.

**What still costs the whole graph**, and when it is paid:

- **Looking at every file** — at start, and when told something changed
  without being told what (6 ms warm). A sync does this itself, once a
  cycle.
- **`title:` with a word from the middle of a title** scans the titles of
  the pages the other conditions leave. Completion, which matches words
  from their start, does not.
- **A first build**, and a rebuild when an index's version changes.
