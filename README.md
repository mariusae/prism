# prism

The engine under Prism and Weft: a graph of Markdown notes kept in a git
repository — read, edited, synced, indexed and watched by one library.

The apps are views. Everything hard lives here, once, in Rust:

- a **git sync engine** that never stops on a conflict and never loses
  what was written, with first-class support for GitHub;
- **indices** — backlinks, search, tasks, the catalog of pages — kept in
  step with a git tree by ingesting only what changed;
- the **note model**: frontmatter, a lossless block tree editors can
  restructure, inline spans, and the Markdown both are written in;
- the **relay** that tells devices the moment another one pushes,
  deployable as a Cloudflare Worker;
- an **engine** that runs all of it in the background and says what it
  did, as events.

## The crates

```text
                        ┌──────────────── prism ────────────────┐
                        │  Engine   one thread: index, sync,    │
       an app  ───────▶ │           events                      │
                        │  Graph    notes as files              │
                        └───┬───────────┬───────────┬───────────┘
                            │           │           │
                 ┌──────────▼──┐  ┌─────▼─────┐  ┌──▼───────────┐
                 │ prism-index │  │ prism-sync│  │ prism-relay  │──▶ prism-relay-worker
                 │ catalog,    │  │ snapshot, │  │ "the remote  │    (Cloudflare)
                 │ backlinks,  │─▶│ commit,   │  │  moved"      │
                 │ search,     │  │ merge,    │  └──┬───────────┘
                 │ tasks       │  │ push      │     │
                 └──────┬──────┘  └───────────┘  ┌──▼───────────┐
                        │                        │ prism-github │
                 ┌──────▼──────┐                 │ sign-in, API,│
                 │ prism-markup│                 │ webhooks     │
                 │ notes as    │                 └──────────────┘
                 │ data        │
                 └─────────────┘
```

| Crate | What it is | Depends on |
|---|---|---|
| [`prism-markup`](crates/prism-markup) | A note as data: frontmatter, the block tree, inline spans, outline editing, Markdown in and out. No I/O, no dependencies. | — |
| [`prism-sync`](crates/prism-sync) | The git engine: snapshot, commit, fetch, merge, push; three-way text merge; the schedule. Knows nothing of notes. | libgit2 |
| [`prism-index`](crates/prism-index) | Incremental indices over git trees, and four of them: catalog, links, search, tasks. | markup, sync, SQLite |
| [`prism-github`](crates/prism-github) | Signing in, the API, webhooks — as request builders and response readers. No I/O. | — |
| [`prism-relay`](crates/prism-relay) | The relay's decisions as pure functions; APNs; the device's listener. | github |
| [`prism-relay-worker`](crates/prism-relay-worker) | The relay hosted on Cloudflare Workers. Plumbing only. | relay |
| [`prism`](crates/prism) | `Graph` and `Engine`: what an app is built on. Re-exports the rest. | all of the above |

Each crate's own documentation (`cargo doc --open`) is the reference;
this page is the map.

## The ideas it is built on

**A tree id is the state of the graph.**
[`Repository::snapshot`](crates/prism-sync/src/repo.rs) hashes the working
tree into a git tree without committing or staging anything. Everything
else follows from having that one content hash: *is there anything to
commit* is a comparison; *what changed* is a tree diff, whose cost is the
size of the change; and anything derived from the files can note the tree
it was built from.

**Indices are cursors over trees.** Each index records the tree it was
last brought up to. Updating it is: diff that tree against the new one,
remove what went, put what came, move the cursor — in one transaction. A
rebuild is the same code, as a diff from the empty tree. Because the tree
can be a snapshot of the working tree, indices follow what is being typed,
not only what was committed; and because trees are content hashes, the
same content reached by typing or by pulling is the same tree, and costs
nothing twice.

**A sync never stops, and never loses.** There is nobody at a terminal to
resolve a conflict on a phone. So merges are computed in memory and every
conflict is settled by rule: lines both devices changed are both kept,
between markers, in the note; a file one changed and the other deleted is
kept; a binary both changed keeps both copies. The conflict travels in
the file, the repository is never left mid-merge, the branch as it was is
kept under `refs/prism/backups/`, and a file edited while the sync ran is
merged with, not overwritten.

**Reading and writing back gives the same bytes.** A note is shared with
other apps, other devices and git's merges. The block tree keeps how each
block was written; whatever would still not write back as read is kept
whole as a raw block, checked at parse time. Every one of the 2,118 notes
of the graph this was built against round-trips, and one block among
22,829 needed the raw fallback.

**Notes are merged as notes.** Two devices that each touch a note both
rewrite its `modified:` line. So frontmatter is merged field by field —
lists as sets, `modified` the later — and only the body by lines; and in
the body, two devices editing neighbouring lines do not conflict.

**Logic without I/O, wherever it must run in two places.** GitHub and the
relay are written as functions from data to data — a request to send, a
response to read, a decision. The same code runs in a native app and in a
Worker, and all of it is tested natively.

**One thread.** The engine does one thing at a time — index, or sync —
in the order asked. No locks around the repository, no index between two
trees. Apps read the indices on their own threads, through SQLite's WAL.

## Using it

```rust
use prism::index::{Catalog, Links, Search};
use prism::sync::{Auth, Config};
use prism::{Engine, EngineConfig, Event};

let engine = Engine::start("/path/to/graph", EngineConfig {
    sync: Config { device: Some("Ada's Mac".into()), ..Config::default() },
    auth: Auth::token("github_pat_…"),
    ..EngineConfig::default()
})?;
let events = engine.subscribe();
engine.sync();                                          // at launch
engine.listen("prism-relay.example.workers.dev").ok();  // hear of pushes

// The editor saves; indexing and syncing follow on their own.
let path = engine.create_note("Project Atlas")?;
let mut note = engine.graph().note(&path)?.unwrap();
note.body.blocks.push(prism::markup::Block::bullet("Kick-off with [[Ada Lovelace]]"));
engine.write(&path, &note.to_markdown())?;

// Views ask the indices, on their own thread.
let db = engine.index()?;
let hits = Search::search(&db, "kick-off", 20)?;
let linking_here = Links::backlinks(&db, &Catalog::names(&db, &path)?)?;

// And redraw when told.
for event in events {
    match event {
        Event::FilesChanged(paths) => { /* reload what is on screen */ }
        Event::IndexUpdated { .. } => { /* refresh backlinks, search, tasks */ }
        Event::SyncFinished(outcome) => { /* show how it went */ }
        _ => {}
    }
}
```

## The graph on disk

| Where | What |
|---|---|
| `daily/YYYY-MM-DD.md` | a day's page |
| `weekly/YYYY-Www.md` | a week's page |
| `notes/**/*.md` | every other page |
| `assets/` | pictures and other files pages show |
| `.git/prism/index.sqlite` | the indices: derived, per clone, never committed |

The Markdown dialect — `[[links]]`, `#tags`, `+ [ ]` tasks, callouts,
query blocks, sized images — is described in
[`prism-markup`](crates/prism-markup/src/lib.rs). The sync follows
Reflect's protocol (commit messages, conflict labels, the rules for
settling conflicts), so a graph can be shared with it.

## Testing

```sh
cargo test                       # everything, natively
PRISM_GRAPH=~/notes cargo test -p prism-markup --test graph -- --nocapture
PRISM_GRAPH=~/notes cargo test --release -p prism --test real_graph -- --nocapture
cd crates/prism-relay-worker && cargo build --target wasm32-unknown-unknown
```

The sync engine is tested against real repositories: a bare remote on
disk and two or three "devices" cloned from it. The indices are tested
for the property that matters — however an index got to a tree, it holds
what a fresh build would. The two `PRISM_GRAPH` tests run a real graph
through the parser and the engine; they only read it (the second copies
its notes into a temporary repository first).

On the graph this was built against — 2,115 pages — a release build
indexes everything from nothing in 1.2 s, commits it in 0.6 s, and has an
edited note written, snapshotted and indexed in under 10 ms.

## Not here yet

- **Running queries.** Query blocks are parsed (`prism_markup::query`);
  the executor over the catalog is to be written.
- **A C ABI.** The apps are Swift; the engine needs a binding layer
  (UniFFI, most likely) before they can be rebuilt on it.
- **SSH remotes and shallow clones.** HTTPS with a token only, and always
  the whole history.
- **Renaming with relinking**, typed fields, rivers: app-level features
  of the old GraphKit that build on the catalog and the block tree.
- **A file watcher.** The engine is told of writes made around it
  (`Engine::note_changed`); it does not watch for them.
