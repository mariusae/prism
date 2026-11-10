# The data model

What a graph is, what is in it, and everything the engine derives from it.

The model has three layers, and only the first is the truth:

| Layer | What | Where | Lifetime |
|---|---|---|---|
| **Files** | Markdown notes, saved rivers, assets | the working tree of a git repository | synced; the only thing that is |
| **In memory** | a file read into a `Note`, a `River`, a `Query` | `prism-markup` types | as long as an editor holds it |
| **Indices** | catalog, links, search, tasks | SQLite at `.git/prism/index.sqlite` | derived per clone; disposable |

Nothing is stored that cannot be rebuilt from the files. There is no
database of notes, no sidecar metadata, no hidden state: delete the index
and the engine rebuilds it; open the folder in another editor and
everything is there to read.

Contents:

1. [The graph on disk](#1-the-graph-on-disk)
2. [Identity: path, id, title, names](#2-identity-path-id-title-names)
3. [A note](#3-a-note)
4. [Frontmatter](#4-frontmatter)
5. [First-class fields](#5-first-class-fields)
6. [Typed fields](#6-typed-fields)
7. [The body: blocks](#7-the-body-blocks)
8. [Inline spans](#8-inline-spans)
9. [References: links, tags, pictures, tasks](#9-references-links-tags-pictures-tasks)
10. [Queries](#10-queries)
11. [Saved rivers](#11-saved-rivers)
12. [Dates and times](#12-dates-and-times)
13. [Trees: the state of a graph](#13-trees-the-state-of-a-graph)
14. [Indices: how they are built and updated](#14-indices-how-they-are-built-and-updated)
15. [The index schema](#15-the-index-schema)
16. [How writes flow](#16-how-writes-flow)
17. [Merging: the model under two writers](#17-merging-the-model-under-two-writers)
18. [Renaming](#18-renaming)
19. [What the model does not do](#19-what-the-model-does-not-do)

---

## 1. The graph on disk

A graph is a folder that is a git repository's working tree.

| Path | What it is | Indexed |
|---|---|---|
| `daily/YYYY-MM-DD.md` | a day's page | yes |
| `weekly/YYYY-Www.md` | an ISO week's page | yes |
| `notes/**/*.md` | every other page, at any depth | yes |
| `rivers/<Name>.md` | a saved river ([§11](#11-saved-rivers)) | no |
| `assets/*` | pictures and other files pages show | no |
| anything else | carried and synced, but no part of the model | no |
| `.git/prism/index.sqlite` | the indices; never committed | — |
| `refs/prism/backups/<ms>` | the branch as it was before each merge; never pushed | — |

**A page's kind is its path**, not its content
(`NoteKind::of`, [note.rs](../crates/prism-markup/src/note.rs)):

- `daily/2026-10-31.md` is `Day(2026-10-31)` — only if the name is a real date.
  `daily/notes.md` and `daily/2026-13-01.md` are not pages at all.
- `weekly/2026-W44.md` is `Week(2026-W44)` — only if that year has that week.
- `notes/….md` is `Note`.
- Everything else — `README.md`, `notes/a.txt`, `rivers/Work.md`,
  `assets/cat.png` — is not a page: never parsed as a note, never indexed.

Paths are graph-relative, `/`-separated, and never contain an empty part,
`.`, `..`, `.git` or a backslash (`Graph::locate` refuses them).

New pages are placed by `Graph::path_for_title`: a title that is a date
goes to that day's file, a week to that week's, anything else to
`notes/<slug>.md` — or `-2`, `-3`, … if taken. The slug is the title
NFC-normalised and lowercased, letters and digits of any script kept, runs
of spaces/`_`/`-` made one dash, at most 60 characters, never empty
(`untitled`) and never a Windows-reserved name (`con` → `con-note`).
Assets are named the same way, extension lowercased
(`Q3 Report (final).PDF` → `assets/q3-report-final.pdf`), and never
written over an existing file.

## 2. Identity: path, id, title, names

A page has three identities. Each answers a different question.

| Identity | Example | Stable across | Used for |
|---|---|---|---|
| **path** | `notes/project-atlas.md` | retitling (a rename keeps the file) | the key in every index; what the engine's API takes |
| **id** | `01jbxk3t6y8q2zp4m9v7c5r0wd` | moving the file, retitling | finding a page wherever it has gone (`Catalog::by_id`) |
| **title** and other **names** | `Project Atlas`, `Atlas` | — | what links are written with |

**Links hold names, not paths or ids.** `[[Project Atlas]]` is text; it is
resolved when asked about, against the catalog's names. This is why a link
written before its page exists starts working when the page is made, and
why a rename has to rewrite links ([§18](#18-renaming)).

**Names are compared by key**: `name_key` collapses runs of whitespace and
lowercases. `[[project  ATLAS]]` finds `Project Atlas`.

**Every name a page answers to** (`Meta::names`), each once by key:

1. its title;
2. each of its `aliases`;
3. each part of a title written `Project // Topic` — both `Project` and
   `Topic`.

**Resolving a name** (`Catalog::resolve`), in order:

1. a date — `2026-10-31` or `2026-W44` — always leads to that day's or
   week's path, whether the page is written yet (`Resolved::Note`) or not
   (`Resolved::Unwritten`);
2. a page whose **title** has that key;
3. a page with that **alias**;
4. a page with that **title part**;
5. otherwise nothing: a page waiting to be written.

Ties within a rank go to the lower path.

**The id** is a ULID — 26 characters of Crockford base 32, lowercase when
the engine makes one, compared without regard to case. `Graph::create_note`
gives every new `notes/` page one. Day and week pages get none: their
file name is their identity.

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
only the lines edited. This is the promise the rest of the model leans on:
git merges by line, other apps read the same files, and neither forgives
an editor that reformats what it did not touch.

Two things are derived from a note on demand; neither is stored in it:

- **`Meta`** — what it says about itself ([§5](#5-first-class-fields));
- **`References`** — what it points at ([§9](#9-references-links-tags-pictures-tasks)).

### The title

`Note::title(path)`, first that applies:

1. a day's or week's page is titled by its date, whatever it says;
2. the frontmatter's `title`, if not blank;
3. the first block, if it is a non-empty `# Heading` — its text with
   inline markup taken out;
4. the file's name without `.md` — or `Untitled` if that name is a ULID.

`Note::set_title` writes it back where it was read from: the frontmatter
`title` if there is one, else the first `#` heading, which is made if
there is neither.

## 4. Frontmatter

The header between `---` fences
([frontmatter.rs](../crates/prism-markup/src/frontmatter.rs)).

**Every value is text or a list of text** (`Value::Text` /
`Value::List`). There are no numbers, booleans or nesting at this level;
meaning is given by whoever reads a key ([§5](#5-first-class-fields),
[§6](#6-typed-fields)).

What is read, of YAML:

| Written | Read as |
|---|---|
| `key: value` | text; a trailing ` # comment` dropped |
| `key: "quoted"` / `'quoted'` | text, unquoted, escapes resolved |
| `key: [a, "b, c"]` | a list |
| `key:` then `- item` lines | a list |
| `key: \|` or `>` then indented lines | text, kept or folded |
| a blank line, a `# comment` | kept, as no entry |

Rules that matter:

- **Lossless.** Each entry keeps the lines it was read from; writing back
  emits them untouched. Comments, key order, quoting and spacing survive.
  Only an entry that is `set` to a *different* value is rewritten, in
  place. A new key goes at the end.
- **Text and a list of one are the same** when a list is asked for:
  `tags: Work` and `tags: [Work]` both give `["Work"]`.
- **A flag is true** for `true`, `yes`, `on`, `1`, case aside.
- **A list written an item a line stays that way** when rewritten, and
  `set_list_by_line` forces it — so two devices adding items change
  different lines.
- A key written twice: `get` reads the first; both are kept in the file,
  and both are indexed.
- The header is recognised only when the first line is `---`, a later
  line is `---` or `...`, and that fence ends in a line break; and when
  its line endings agree. Otherwise the whole file is body — never a
  half-read header.

## 5. First-class fields

The frontmatter keys the engine itself gives meaning to. Any other key is
the user's: kept, indexed ([`note_fields`](#15-the-index-schema)),
queryable with `has:`, and typed if a tag says so
([§6](#6-typed-fields)).

### On a page

| Key | Shape | Meaning | Read by |
|---|---|---|---|
| `title` | text | the page's title, over its first heading | `Note::title` |
| `id` | text (ULID) | lasting identity | `Meta.id`, `Catalog::by_id` |
| `aliases` | list | other names the page answers to | `Meta.aliases`, name resolution |
| `tags` | list | tags; a leading `#` is dropped | `Meta.tags` |
| `created` | timestamp | when it was made | `Meta.created`, `sort: created` |
| `modified` | timestamp | when it was last changed | `Meta.modified`, `sort: modified`, merging |
| `private` | flag | never named in a commit message; left out of queries unless asked for | `Meta.private` |
| `wiki` | flag | part of the wiki: canonical, kept up | `Meta.wiki`, `wiki:` / `is: wiki` |
| `related` | list | links to other pages, plain or as `[[links]]` | `References.links` (with an empty block path) |
| `fields` | list | on a tag's page: the typed fields of pages with the tag | [§6](#6-typed-fields) |
| `list` | list | on a tag's or list page: titles in a hand-set order | `listed in:`, a tag query's default order |
| `pinned` | flag or number | pinned; a number is its place | `is: pinned`, `sort: pinned` |
| `inbox`, `topic`, `template` | flag | marks read by `is:` | `is: inbox` … |
| `river` | text | the page's home river, by name | Weft (`river::HOME_KEY`) |
| `caption` | text | never treated as a link when relinking | `Note::relink` |

`is: <anything>` reads the frontmatter key of that name as a flag (true,
or a non-zero number), so the last row's keys are a convention and not a
closed set.

### `Meta`: the page's own account of itself

`Note::meta(path)` gathers:

| Field | From |
|---|---|
| `title` | [the title rules](#the-title) |
| `id` | frontmatter `id`, if not blank |
| `aliases` | frontmatter `aliases` |
| `tags` | frontmatter `tags`, then the body's inline `#tags`, each once, case aside, as first written |
| `created`, `modified` | frontmatter, parsed as timestamps ([§12](#12-dates-and-times)); `None` if unreadable |
| `private`, `wiki` | frontmatter flags |

A tag is the same thing whether written `tags: [Projects]` or `#projects`
in the body; the first spelling wins for display, the lowercase form is
the key.

### On a saved river

| Key | Shape | Meaning |
|---|---|---|
| `folded` | list | cards showing only their titles |
| `opened` | list | of a query's cards: those opened out of their peek |
| `hidden` | list | of a query's cards: those taken out |
| `icon`, `color` | text | how the river shows among the rivers |
| `place` | number | its position among the rivers, lower first |

## 6. Typed fields

A tag gives the pages tagged with it a schema. The tag's **own page** —
the page the tag's name resolves to — lists the fields in its
frontmatter ([fields.rs](../crates/prism-markup/src/fields.rs)):

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
| `name (yes/no)` / `(flag)` / `(bool)` | `Flag` | `bool` | yes/true/on/1/y or no/false/off/0/n |
| `name (a \| b \| c)` | `Choice([..])` | the option, spelled as the spec spells it | one of the options, case aside |

- **Values stay frontmatter text.** Typing is a reading: `FieldKind::read`
  returns `None` for text that is not a value of the kind, and an app
  shows that text as it is. Nothing is rejected or rewritten on the way
  in. `FieldValue::to_text` writes one back (`4.0` → `4`, a flag →
  `yes`/`no`).
- **An unknown kind is text**, so a newer app's kinds degrade rather than
  vanish.
- **A page's schema** (`Catalog::schema(path)`) is the specs of each of
  its tags, in the order of its tags, each field name once — the first
  tag to name a field types it. `title`, `id`, `tags`, `created` and
  `modified` cannot be redefined.
- A tag with no page gives no fields.

## 7. The body: blocks

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
| `Code` | a fenced block | all of it, fences included (`code_parts` gives info and body) |
| `Table` | a pipe table | its lines (`Table::parse` gives cells) |
| `Rule` | `---`, `***`, `___` | the rule as written |
| `Raw` | anything else | the lines exactly, blank ones included |

An item's `marker` is `Bullet('-' | '*' | '+')` or
`Ordered { number, delimiter }`; its `task` is `None`, `Open`, or
`Done('x' | 'X')`. By convention Prism writes a **task** as `+ [ ]` and a
checklist item as `- [ ]`; both are tasks to the model.

**Nesting is Markdown's lists and nothing else.** A list item's sublist, a
paragraph after a blank line inside it, a code block inside it — these
are its children. A heading does not own what follows it; a section is
computed (`outline::section_len`), not stored.

**One tree, two editors.** An outline editor walks `Document::rows()` —
every block in reading order with its `path` and `depth` — and
restructures with [`outline`](../crates/prism-markup/src/outline.rs):
`indent`, `outdent`, `move_up`, `move_down`, `remove`, `insert`,
`duplicate`, `split`, `join_with_previous`, `toggle_task`, `set_kind`,
`renumber`. A prose editor walks the top-level blocks.

**A block's address is its path**: an index at each level, outermost
first — `[1, 0]` is the first child of the second top-level block. Paths
are positions, not identities: they change when blocks above move.
Blocks have no ids.

**Losslessness** rests on two things:

1. `Layout` records what the writer needs to give back the same bytes:
   the blank lines before the block (`gap`), the spaces after the marker
   (`spacing`), indentation beyond what depth asks (`extra_indent`), and
   unusual continuation-line indents. A new block has the default layout
   and is written canonically.
2. **`Raw` is the safety net.** Each top-level chunk is checked at parse
   time: if writing it back would not give the same bytes (tabs as
   indentation, a shape the reader does not know), the chunk is kept
   whole as a `Raw` block. One odd construct costs only itself, and no
   input is ever lost. On the 2,118-note graph this was built against,
   one block in 22,829 is raw.

## 8. Inline spans

Inline markup is **not** part of the tree. A block's `text` stays the
Markdown it was written in; `inline::parse(text)` finds what it means, as
`Span`s ([inline.rs](../crates/prism-markup/src/inline.rs)):

```text
Span
├── kind       what it is
├── range      the whole span in the text, markup included (bytes)
├── content    the part it shows (bytes)
└── children   spans inside the content
```

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

An editor draws the content, hides `span.markup()`, and edits the text
itself. Spans are computed, never stored, and so can never disagree with
the file. Only blocks with inline content are parsed: paragraphs,
headings, items, quotes and tables — never code, rules or raw blocks.

Ranges are UTF-8 byte offsets in Rust; the Swift bindings convert them to
UTF-16 offsets, ready for `NSRange`.

## 9. References: links, tags, pictures, tasks

`Note::references()` gathers, in one pass over the body, everything a
note points at. Code is never searched.

| | Type | Fields | From |
|---|---|---|---|
| links | `NoteLink` | `target`, `label`, `embed`, `block` | `[[…]]`, `![[…]]`, then each `related:` entry (with `block` empty) |
| web links | `WebLink` | `url`, `block` | `[…](url)`, `<url>`, bare URLs |
| tags | `String` | | inline `#tags`, without the `#`, in order |
| pictures | `ImageRef` | `source`, `alt`, `width`, `height`, `block` | `![…](…)`; `source` is `assets/…` or a web address |
| tasks | `TaskRef` | `block`, `text`, `done` | every list item with a checkbox |

`block` is the path of the block the reference is in ([§7](#7-the-body-blocks)).
A task's `text` is Markdown, not plain text.

## 10. Queries

A fenced code block with the info string `query` is a live list of pages
([query.rs](../crates/prism-markup/src/query.rs) parses,
[prism-index/query.rs](../crates/prism-index/src/query.rs) runs).

````markdown
```query
tag: Person
not tag: Archived
sort: -modified
limit: 10
```
````

A query is its clauses, a line each, in order. `{this}` in a value stands
for the title of the page the query is written in.

| Clause | Keeps the pages … |
|---|---|
| `tag: X` | tagged X (every `tag:` line must hold) |
| `not tag: X` | not tagged X |
| `title: words` | whose title contains every word, case aside |
| `text: words` | that the search index matches for every word |
| `links to: X` | that link to X, by any of X's names; works for a page not written yet |
| `linked from: X` | that X links to |
| `listed in: X` | named in X's `list` field |
| `has: a, b` | whose frontmatter has every one of the keys |
| `wiki: yes` / `no` | by the `wiki` flag |
| `is: day` / `week` / `note` | by kind |
| `is: wiki` / `<flag>` | with that frontmatter flag set |

| Clause | Sets |
|---|---|
| `sort: key` / `sort: -key` | the order: `title`, `created`, `modified`, `pinned`; pages without a time sort last either way |
| `limit: n` | how many are returned (`total` still counts them all) |
| `show: list` / `inline` / `table` / `cards` / `count` / `tree` | how an app should show them |
| `columns: a, b` | a table's fields |

- **Default order**, without `sort:` — the order of the list a
  `listed in:` names; else the order in the first tag's page's `list`,
  those pages first; else by title.
- **Default columns**, without `columns:` — the typed fields of the first
  tag asked for.
- **Private pages are left out** unless the caller asks
  (`QueryOptions::include_private`); `Engine::query` does not.
- **A line not understood is kept** as `Clause::Unknown` and written back
  as it was, so a newer app's conditions survive an older one. It filters
  nothing.

## 11. Saved rivers

A river is a named run of cards (Weft's view of pages). One worth keeping
is a file, `rivers/<Name>.md`
([river.rs](../crates/prism-markup/src/river.rs)):

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
├── cards: Vec<Card>      held by hand, in order (all of a plain river; the top of a query river)
├── query: Option<Query>  what it finds, for a query river
├── placed: Vec<Card>     cards put by hand among what the query finds
├── folded, opened, hidden: Vec<String>   titles; see §5
└── icon, color, place

Card
├── title                 the page's title — a link by name, like any other
├── folded_rows           rows folded in the card: (index among its rows, text)
└── place                 for a placed card: (rank, the sort key it stood at)
```

- A card is `- [[Title]]`. Indented under it, `  - <index>: <text>` is a
  folded row; the text is how the row is found again after the page
  changes.
- Cards **before** the query block are pinned to its top; cards **after**
  it are placed among its results, each with ` @ <rank> <sort key>`.
- **A river is not a page.** It has no kind, is not indexed, and no title
  resolves to it. A link to one is written to its file —
  `[[rivers/Work]]` — and such links are not counted as pages waiting to
  be written.
- The frontmatter lists are always written an item a line, so two devices
  folding different cards merge.
- Unlike a note, a river is **not** round-tripped byte for byte: it is
  read into the structure above and written canonically. Lines that are
  no card, row or query are dropped on the next save.

## 12. Dates and times

[date.rs](../crates/prism-markup/src/date.rs). Parsed strictly, printed
canonically, ordered chronologically.

| Type | Written | Notes |
|---|---|---|
| `Day` | `2026-10-31` | exactly `YYYY-MM-DD`, years 1–9999, a real calendar day |
| `Week` | `2026-W44` | exactly `YYYY-Www`, an ISO 8601 week that year has; Monday first |
| `Timestamp` | `2026-10-31T10:34:00Z` | ISO 8601: `Z` or an offset, fractional seconds ignored, or a bare date as its midnight UTC |

A `Timestamp` is kept as **seconds since the Unix epoch**, so two stamps
written in different zones compare by when they were. That integer is
what the catalog stores.

A day's name is both its page's title and a valid link target, so
`[[2026-10-31]]` always leads somewhere.

## 13. Trees: the state of a graph

The model's notion of "a version of the graph" is a **git tree id**.

`Repository::snapshot` ([repo.rs](../crates/prism-sync/src/repo.rs))
hashes the working tree into a tree object: HEAD's tree, with every file
added, changed or deleted since. It writes the changed blobs to the
object store and touches neither the index nor HEAD — so it can run on
every save.

What is left out of a snapshot: whatever `.gitignore` ignores; paths in
`Config::exclude`; and files at or over `Config::max_file_bytes` (95 MB
by default), which stay as they were in HEAD and are reported rather than
blocking everything else.

Three things follow from one content hash:

- **"Is there anything to commit?"** is `snapshot.tree != HEAD's tree`.
- **"What changed?"** is a tree diff (`Repository::changes`), whose cost
  is the size of the change: subtrees with equal hashes are never opened.
- **Anything derived** can record the tree it was derived from — which is
  all an index's cursor is.

A commit is a snapshot plus a commit object; the working tree already
matches and is left alone.

## 14. Indices: how they are built and updated

[prism-index/lib.rs](../crates/prism-index/src/lib.rs).

### The contract

An index is tables of its own plus two operations:

```rust
trait Index {
    fn name(&self) -> &'static str;   // its key among the cursors
    fn version(&self) -> u32;         // bump to force a rebuild
    fn create(&self, tx) ;            // make the tables, if absent
    fn clear(&self, tx);              // empty them
    fn wants(&self, path) -> bool;    // default: pages only
    fn remove(&self, tx, path);       // undo everything put wrote for path
    fn put(&self, tx, file);          // add one file
}
```

The invariant: **after any sequence of calls, the tables hold exactly
what `put` would have written for the files of the cursor's tree.**
`put` is only called for a path not currently in the index.

### The cursor

```sql
CREATE TABLE prism_cursors (name TEXT PRIMARY KEY, version INTEGER NOT NULL, tree TEXT) WITHOUT ROWID;
```

One row an index: the tree it was last brought up to, and the version of
the code that built it.

### An update

`Indexer::update(repo, tree)`:

1. **Find where each index starts.** Its cursor's tree — or nothing (a
   rebuild) when it has no cursor, its stored version differs from
   `version()`, or git no longer has that tree.
2. **Nothing to do** if every index is already at `tree`: no transaction
   is opened.
3. **Open one transaction.** `clear` each index that is rebuilding.
4. **Diff once per distinct starting tree.** Indices at the same tree
   share the diff. A rebuild is the same code path: a diff from the empty
   tree, which lists every file as added.
5. **For each changed path** an index `wants`: if the file existed
   before, `remove(path)`; if it exists now, `put(file)`. A modified file
   is a remove then a put.
6. **Move every cursor** to `tree`, and commit.

So an index is always exactly some tree's, never between two, whatever
interrupts it; and the cost of an update is the size of the change, not
of the graph.

A `File` handed to `put` is read from the object store at most once and
parsed as a `Note` at most once, however many indices look at it.

### What triggers one

The engine's single thread ([§16](#16-how-writes-flow)) snapshots the
working tree and updates the indices:

- at start, catching up on whatever was written while no engine ran;
- after any write through the engine, or one a file watcher reports —
  ten saves queued together are indexed once;
- after every sync cycle, whatever it managed.

Because the tree is a snapshot of the *working* tree, the indices follow
what is being typed, not only what was committed. Because trees are
content hashes, the same content reached by typing here or pulling from
another device is the same tree, and costs nothing the second time.

### Storage

One SQLite database, WAL mode, at `.git/prism/index.sqlite` — inside the
repository, so it is never committed and every clone builds its own. The
engine's thread is the only writer. Apps read on their own threads
through read-only connections (`Engine::index`), never blocking or
blocked by an update.

On the 2,115-page graph: a full build from nothing takes 1.2 s; an edited
note is written, snapshotted and indexed in under 10 ms (release build).

## 15. The index schema

All four standard indices want pages only (`daily/`, `weekly/`,
`notes/`), and are at version 1.

### `catalog` — every page and what it says of itself

```sql
notes       (path PRIMARY KEY, title, id, kind, private, wiki, created, modified)
note_names  (key, name, path, rank)        -- indexed on key, on path
note_tags   (key, tag, path)               -- indexed on key, on path
note_fields (path, key, position, value)   -- indexed on path, on (key, value)
```

| Column | Holds |
|---|---|
| `notes.kind` | `day`, `week` or `note` |
| `notes.created`, `modified` | seconds since the epoch, from the frontmatter; `NULL` if absent or unreadable |
| `note_names.key` | `name_key(name)` |
| `note_names.rank` | `0` the title, `1` an alias, `2` a part of a `A // B` title |
| `note_tags.key` | the tag lowercased; `tag` is it as written |
| `note_fields` | **every** frontmatter key, a row a value: text is one row at `position` 0, a list a row an item in order |

`note_fields.key` is as written (case matters); values compare case
aside. Because all frontmatter lands here, any key — first-class or the
user's — can be asked about without a schema change.

Asks: `get`, `by_id`, `all`, `count`, `resolve`, `names`, `complete`
(prefix of a name or of a word in it, titles first), `tagged`, `tags`
(with counts), `tags_of`, `fields`, `with_field`, `field_specs`,
`schema`.

### `links` — who links where

```sql
links (source, key, target, embed, block)  -- indexed on key, on source
```

A row for every `[[link]]`, `![[embed]]` and `related:` entry. `source`
is the path the link is written in; `target` the name as written; `key`
its `name_key`; `block` the block's path as dotted indices (`1.0`), empty
for `related`.

**The target is a name, never a path.** Nothing here is resolved at index
time, so a page created or retitled later needs no re-index of the pages
that link to it. Backlinks are found by asking for every name a page
answers to: `Links::backlinks(db, &Catalog::names(db, path)?)`.

Asks: `backlinks`, `outgoing`, `unresolved` (names no page answers to,
most wanted first — dates and `rivers/…` links left out).

### `search` — full text

```sql
CREATE VIRTUAL TABLE search USING fts5(path UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2');
```

`body` is `Note::plain_text()`: the note as it reads, a block a line,
Markdown taken out — links by their text, code by its body, rules,
pictures and comments left out. Frontmatter is not in it.

`Search::search` requires every word typed, treats the last as a prefix,
quotes each so nothing typed is FTS syntax, and ranks a title match eight
times a body match. Private pages are indexed like any other; hiding them
is the asker's decision.

### `tasks` — every checkbox

```sql
tasks (path, block, text, done)            -- indexed on path, on done
```

`block` is the dotted block path; `text` is Markdown. `Tasks::open` lists
open tasks from the newest day's page back, then other pages.

## 16. How writes flow

```text
 app ──write──▶ Graph ──▶ file on disk (atomic; only if different)
                  │
                  └─ note_changed ─▶ engine thread
                                       │ snapshot working tree ──▶ tree id
                                       │ Indexer::update(tree)  ──▶ Event::IndexUpdated { tree, changed }
                                       │ tree ≠ HEAD's? ──▶ schedule a push
                                       ▼
                         (30 s after writing pauses, 5 min at most)
                                       │ commit ─ fetch ─ merge ─ apply ─ push
                                       │ snapshot + update again
                                       ▼
                              Event::FilesChanged(paths), Event::SyncFinished
```

- **Files are written whole or not at all** — to a temporary beside the
  file, then renamed over it — and only when the content differs, so a
  save that changed nothing touches nothing.
- **The engine never stamps a note.** Nothing in the core sets `created`
  or `modified`; they are read when present and maintained by whoever
  edits. `create_note` writes only `id` and the title heading.
- **Events carry paths and a tree, not content.** An app re-reads what it
  is showing and re-asks the indices.
- **A push is scheduled only when the working tree differs from HEAD**, so
  a file touched and left as it was, or a watcher seeing a sync's own
  writes, asks nothing of the remote.

## 17. Merging: the model under two writers

Two devices edit the same graph; neither can be asked to resolve
anything. The model is shaped so that most concurrent edits do not
conflict, and those that do are carried in the file.

**A note with frontmatter on both sides is merged as a note**
([note_merge.rs](../crates/prism/src/note_merge.rs)):

| Part | Rule |
|---|---|
| a list field, on both sides | merged as a set: what either added is kept, what either removed is gone; this device's order, the other's additions after |
| `modified` | the later of the two |
| any other field | the side that changed it; if both did, the side with the later `modified` |
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

A conflict is therefore *data in a note*, found by `conflict::detect`,
and settled by editing the note (`conflict::resolve`). Nothing waits on
it and no repository is ever left mid-merge.

**Other files:** one side changed and the other deleted — the file is
kept. A binary both changed — both are kept, the other as
`name (conflict).ext`.

**An editor's draft is merged the same way.** `Graph::save_merging(path,
draft, base)` writes the draft if the file is still as the editor saw it;
otherwise it merges the draft and the file from `base` by the rules
above, the draft's side first.

## 18. Renaming

Because links are names, retitling a page must rewrite them.
`Engine::rename_note(path, new_title)`:

1. refuses if the new title already resolves to a different page
   (`TitleTaken`), or the page is a day's or week's (`NotRenamable`);
2. finds the pages linking to the old title from the `links` index;
3. sets the title where it is written ([§3](#the-title));
4. in each linking page, and in the page itself, `Note::relink(old, new)`
   rewrites — matching by name key, never inside code:
   - `[[old]]`, `[[old|shown]]`, `![[old]]`, including `[[old\|x]]` in
     tables;
   - in query blocks, the value of `tag:`, `not tag:`, `links to:`,
     `linked from:` and `listed in:`;
   - in frontmatter, any list item or whole text value equal to the old
     title, plain or as a `[[link]]` — except under `title`, `aliases`,
     `id` and `caption`;
5. in every saved river, the card of that title and its entries in
   `folded`, `opened` and `hidden`.

**The file stays where it is.** The path and the `id` do not change, so
the indices, open editors and git history all keep following the same
page. Only the lines that named it change.

## 19. What the model does not do

Stated plainly, so nobody builds on an assumption:

- **Blocks have no stable ids.** A block is addressed by its position.
  `links.block` and `tasks.block` are correct for the tree they were
  indexed at and stale after an edit above them; re-ask after
  `IndexUpdated`. There are no block references or block embeds.
- **No index of web links or pictures.** Both are in `References`, neither
  is stored; which notes use an asset is found by reading notes.
- **Rivers and assets are not indexed.** Rivers are listed from the
  folder (`Graph::river_names`).
- **Links to a part of a `Project // Topic` title are not rewritten** by a
  rename; only links to the whole title are.
- **Aliases are not relinked.** Changing an alias leaves links written
  with the old one pointing at nothing.
- **Typed fields are not enforced.** A value that does not read as its
  kind is kept and shown as text.
- **`created` and `modified` are not maintained by the engine.**
- **Frontmatter is flat.** Nested YAML is read as text and written back
  as it was, but has no structure in the model.
- **Duplicate titles are allowed.** Two pages with one title both exist;
  a link resolves to the one with the lower path. Only a rename checks.
