//! Indices against a real repository: built, updated incrementally as
//! files change, and checked against a rebuild from nothing.

use prism_index::{rusqlite, Backlink, Catalog, File, Index, Indexer, Links, Resolved, Search, Tasks};
use prism_sync::{Config, Identity, Mode, Oid, Repository, SnapshotOptions, Syncer};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

struct Graph {
    dir: tempfile::TempDir,
    repo: Repository,
}

impl Graph {
    fn new() -> Graph {
        let dir = tempfile::tempdir().unwrap();
        let repo = Repository::init(dir.path(), "main").unwrap();
        let graph = Graph { dir, repo };
        graph.write("notes/project-atlas.md", "---\nid: 01jbxk3t6y8q2zp4m9v7c5r0wd\naliases: [Atlas]\ntags: [Projects]\nstatus: active\nrelated:\n  - Grace Hopper\n---\n# Project Atlas\n\n- Kick-off with [[Ada Lovelace]] on [[2026-10-31]] #planning\n  + [ ] Book a room\n  + [x] Send invites\n");
        graph
            .write("notes/ada-lovelace.md", "---\ntags: [Person]\n---\n# Ada Lovelace\n\nWrote the first program. See [[atlas]] and ![[Analytical Engine]].\n");
        graph.write("notes/grace-hopper.md", "---\ntags: [Person]\nprivate: true\n---\n# Grace Hopper\n\nInvented the compiler.\n");
        graph.write("daily/2026-10-31.md", "- Met [[Ada Lovelace]] about [[Project Atlas]]\n+ [ ] Follow up with Ada\n");
        graph.write("daily/2026-11-01.md", "+ [ ] Write the résumé of the kick-off\n");
        graph.write("assets/diagram.png", b"PNG\0\0");
        graph.write("README.md", "Not a page: [[Ada Lovelace]]\n");
        graph
    }

    fn write(&self, path: &str, content: impl AsRef<[u8]>) {
        let file = self.dir.path().join(path);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, content).unwrap();
    }

    fn delete(&self, path: &str) {
        std::fs::remove_file(self.dir.path().join(path)).unwrap();
    }

    fn snapshot(&self) -> Oid {
        self.repo.snapshot(&SnapshotOptions::default()).unwrap().tree
    }
}

fn sources(links: &[Backlink]) -> Vec<&str> {
    links.iter().map(|l| l.source.as_str()).collect()
}

/// Every row of every table an index owns, in a stable order: two
/// databases with the same dump hold the same index.
fn dump(db: &rusqlite::Connection) -> Vec<String> {
    let mut rows = Vec::new();
    for (table, columns) in [
        ("notes", "path, title, id, kind, private, wiki, created, modified"),
        ("note_names", "key, name, path, rank"),
        ("note_tags", "key, tag, path"),
        ("note_fields", "path, key, position, value"),
        ("links", "source, key, target, embed, block"),
        ("search", "path, title, body"),
        ("tasks", "path, block, text, done"),
    ] {
        let mut statement = db.prepare(&format!("SELECT {columns} FROM {table}")).unwrap();
        let count = statement.column_count();
        let mut found: Vec<String> = statement
            .query_map([], |row| {
                let cells: Vec<String> = (0..count).map(|i| format!("{:?}", row.get_ref(i).unwrap())).collect();
                Ok(format!("{table}: {}", cells.join(" | ")))
            })
            .unwrap()
            .map(Result::unwrap)
            .collect();
        found.sort();
        rows.extend(found);
    }
    rows
}

#[test]
fn the_catalog_knows_every_page_and_resolves_names() {
    let graph = Graph::new();
    let mut indexer = Indexer::in_memory(prism_index::standard()).unwrap();
    let update = indexer.update(&graph.repo, graph.snapshot()).unwrap();
    assert_eq!(update.rebuilt, ["catalog", "links", "search", "tasks"]);
    assert_eq!(update.changed.len(), 5, "only pages are ingested: {:?}", update.changed);
    let db = indexer.connection();

    assert_eq!(Catalog::count(db).unwrap(), 5);
    let atlas = Catalog::get(db, "notes/project-atlas.md").unwrap().unwrap();
    assert_eq!((atlas.title.as_str(), atlas.kind.as_str(), atlas.id.as_deref()), ("Project Atlas", "note", Some("01jbxk3t6y8q2zp4m9v7c5r0wd")));
    assert_eq!(Catalog::by_id(db, "01JBXK3T6Y8Q2ZP4M9V7C5R0WD").unwrap().unwrap().path, "notes/project-atlas.md");
    assert!(Catalog::get(db, "notes/grace-hopper.md").unwrap().unwrap().private);
    assert_eq!(Catalog::get(db, "daily/2026-10-31.md").unwrap().unwrap().kind, "day");
    assert!(Catalog::get(db, "README.md").unwrap().is_none());

    // By title, by alias, case aside; a date always leads somewhere.
    let resolve = |name: &str| Catalog::resolve(db, name).unwrap();
    assert_eq!(resolve("project atlas"), Some(Resolved::Note("notes/project-atlas.md".into())));
    assert_eq!(resolve("ATLAS"), Some(Resolved::Note("notes/project-atlas.md".into())));
    assert_eq!(resolve("2026-10-31"), Some(Resolved::Note("daily/2026-10-31.md".into())));
    assert_eq!(resolve("2026-12-25"), Some(Resolved::Unwritten("daily/2026-12-25.md".into())));
    assert_eq!(resolve("2026-W44"), Some(Resolved::Unwritten("weekly/2026-W44.md".into())));
    assert_eq!(resolve("Analytical Engine"), None);

    assert_eq!(Catalog::names(db, "notes/project-atlas.md").unwrap(), ["Project Atlas", "Atlas"]);
    let titles = |rows: Vec<prism_index::NoteRow>| rows.into_iter().map(|r| r.title).collect::<Vec<_>>();
    assert_eq!(titles(Catalog::tagged(db, "person").unwrap()), ["Ada Lovelace", "Grace Hopper"]);
    assert_eq!(titles(Catalog::tagged(db, "#Planning").unwrap()), ["Project Atlas"]);
    assert_eq!(Catalog::tags(db).unwrap(), [("Person".to_owned(), 2), ("planning".to_owned(), 1), ("Projects".to_owned(), 1)]);
    assert_eq!(Catalog::tags_of(db, "notes/project-atlas.md").unwrap(), ["Projects", "planning"]);
    assert_eq!(titles(Catalog::complete(db, "a", 10).unwrap()), ["Ada Lovelace", "Project Atlas"]);
    assert_eq!(titles(Catalog::complete(db, "love", 10).unwrap()), ["Ada Lovelace"]);
    assert_eq!(titles(Catalog::with_field(db, "status", Some("Active")).unwrap()), ["Project Atlas"]);
    assert_eq!(titles(Catalog::with_field(db, "private", None).unwrap()), ["Grace Hopper"]);
    let fields = Catalog::fields(db, "notes/project-atlas.md").unwrap();
    assert_eq!(fields[1], ("aliases".to_owned(), vec!["Atlas".to_owned()]));
    assert_eq!(fields.last().unwrap(), &("related".to_owned(), vec!["Grace Hopper".to_owned()]));
    assert_eq!(titles(Catalog::all(db).unwrap()), ["2026-10-31", "2026-11-01", "Ada Lovelace", "Grace Hopper", "Project Atlas"]);
}

#[test]
fn backlinks_follow_every_name_a_page_answers_to() {
    let graph = Graph::new();
    let mut indexer = Indexer::in_memory(prism_index::standard()).unwrap();
    indexer.update(&graph.repo, graph.snapshot()).unwrap();
    let db = indexer.connection();

    let names = Catalog::names(db, "notes/project-atlas.md").unwrap();
    let to_atlas = Links::backlinks(db, &names).unwrap();
    // The daily note links by title; Ada's page by alias, lower case.
    assert_eq!(sources(&to_atlas), ["daily/2026-10-31.md", "notes/ada-lovelace.md"]);
    assert_eq!((to_atlas[1].target.as_str(), to_atlas[1].block.as_slice()), ("atlas", &[1][..]));

    let to_ada = Links::backlinks(db, &["Ada Lovelace".into()]).unwrap();
    assert_eq!(sources(&to_ada), ["daily/2026-10-31.md", "notes/project-atlas.md"]);
    // A relation in the frontmatter is a link with no block.
    let to_grace = Links::backlinks(db, &["Grace Hopper".into()]).unwrap();
    assert_eq!((sources(&to_grace), to_grace[0].block.len()), (vec!["notes/project-atlas.md"], 0));
    // A day is linked to by its date.
    assert_eq!(sources(&Links::backlinks(db, &["2026-10-31".into()]).unwrap()), ["notes/project-atlas.md"]);
    assert!(Links::backlinks(db, &[]).unwrap().is_empty());

    let outgoing = Links::outgoing(db, "notes/ada-lovelace.md").unwrap();
    assert_eq!(outgoing.iter().map(|l| (l.target.as_str(), l.embed)).collect::<Vec<_>>(), [("atlas", false), ("Analytical Engine", true)]);
    assert_eq!(Links::unresolved(db).unwrap(), [("Analytical Engine".to_owned(), 1)]);
}

#[test]
fn search_finds_words_as_they_read() {
    let graph = Graph::new();
    let mut indexer = Indexer::in_memory(prism_index::standard()).unwrap();
    indexer.update(&graph.repo, graph.snapshot()).unwrap();
    let db = indexer.connection();
    let paths = |typed: &str| Search::search(db, typed, 10).unwrap().into_iter().map(|h| h.path).collect::<Vec<_>>();

    assert_eq!(paths("compiler"), ["notes/grace-hopper.md"]);
    // A title match comes before a mention.
    assert_eq!(paths("ada"), ["notes/ada-lovelace.md", "daily/2026-10-31.md", "notes/project-atlas.md"]);
    // Every word must be there; the last is a prefix; accents are folded.
    assert_eq!(paths("kick off resu"), ["daily/2026-11-01.md"]);
    assert_eq!(paths("first prog"), ["notes/ada-lovelace.md"]);
    assert!(paths("nonexistent").is_empty());
    assert!(paths("").is_empty() && paths("\"(").is_empty());
    let hit = &Search::search(db, "compiler", 1).unwrap()[0];
    assert_eq!((hit.title.as_str(), hit.snippet.as_str()), ("Grace Hopper", "Grace Hopper\nInvented the [compiler].\n"));
    // Markup is not text: the link's brackets are not searched for.
    assert!(paths("[[Ada").len() == 3);
}

#[test]
fn tasks_are_listed_open_and_done() {
    let graph = Graph::new();
    let mut indexer = Indexer::in_memory(prism_index::standard()).unwrap();
    indexer.update(&graph.repo, graph.snapshot()).unwrap();
    let db = indexer.connection();
    let open: Vec<_> = Tasks::open(db).unwrap().into_iter().map(|t| (t.path, t.text)).collect();
    assert_eq!(
        open,
        [
            ("daily/2026-11-01.md".to_owned(), "Write the résumé of the kick-off".to_owned()),
            ("daily/2026-10-31.md".to_owned(), "Follow up with Ada".to_owned()),
            ("notes/project-atlas.md".to_owned(), "Book a room".to_owned()),
        ]
    );
    let in_atlas = Tasks::in_note(db, "notes/project-atlas.md").unwrap();
    assert_eq!(in_atlas.iter().map(|t| (t.block.clone(), t.done)).collect::<Vec<_>>(), [(vec![1, 0], false), (vec![1, 1], true)]);
    assert_eq!(Tasks::counts(db).unwrap(), (3, 1));
}

#[test]
fn an_update_ingests_only_what_changed() {
    let graph = Graph::new();
    let mut indexer = Indexer::in_memory(prism_index::standard()).unwrap();
    let first = graph.snapshot();
    indexer.update(&graph.repo, first).unwrap();
    assert_eq!(indexer.cursor("links").unwrap(), Some(first));

    // The same tree again costs nothing.
    assert!(indexer.update(&graph.repo, first).unwrap().is_noop());

    graph.write("notes/ada-lovelace.md", "# Ada Lovelace\n\nNo links any more. #mathematician\n");
    graph.write("notes/analytical-engine.md", "# Analytical Engine\n\nDesigned by Babbage; see [[Ada Lovelace]].\n");
    graph.delete("daily/2026-11-01.md");
    graph.write("assets/another.png", b"PNG\0");
    let update = indexer.update(&graph.repo, graph.snapshot()).unwrap();
    assert_eq!(update.changed, ["daily/2026-11-01.md", "notes/ada-lovelace.md", "notes/analytical-engine.md"]);
    assert!(update.rebuilt.is_empty());

    let db = indexer.connection();
    assert_eq!(Catalog::count(db).unwrap(), 5);
    assert_eq!(sources(&Links::backlinks(db, &Catalog::names(db, "notes/project-atlas.md").unwrap()).unwrap()), ["daily/2026-10-31.md"]);
    assert!(Links::unresolved(db).unwrap().is_empty(), "the page linked to now exists");
    assert_eq!(Tasks::counts(db).unwrap(), (2, 1));
    assert!(Search::search(db, "résumé", 5).unwrap().is_empty());
    assert_eq!(Search::search(db, "babbage", 5).unwrap()[0].path, "notes/analytical-engine.md");
    assert!(Catalog::tagged(db, "person").unwrap().iter().all(|n| n.title != "Ada Lovelace"));
    assert_eq!(Catalog::tagged(db, "mathematician").unwrap().len(), 1);

    // Going back to the first tree is an update like any other.
    let back = indexer.update(&graph.repo, first).unwrap();
    assert_eq!(back.changed.len(), 3);
    assert_eq!(Links::unresolved(indexer.connection()).unwrap().len(), 1);
}

/// However an index got to a tree, it holds what a fresh build would.
#[test]
fn incremental_updates_equal_a_rebuild() {
    let graph = Graph::new();
    let mut incremental = Indexer::in_memory(prism_index::standard()).unwrap();
    type Edit = Box<dyn Fn(&Graph)>;
    let edits: Vec<Edit> = vec![
        Box::new(|_| {}),
        Box::new(|g| g.write("notes/ada-lovelace.md", "# Countess of Lovelace\n\n[[Project Atlas]] #person\n")),
        Box::new(|g| g.write("notes/new.md", "---\naliases: [Fresh, Ada Lovelace]\n---\n- [[Fresh]] [[2026-10-31]]\n+ [ ] one\n+ [x] two\n")),
        Box::new(|g| g.delete("notes/grace-hopper.md")),
        Box::new(|g| {
            std::fs::rename(g.dir.path().join("notes/new.md"), g.dir.path().join("notes/renamed.md")).unwrap();
            g.write("daily/2026-10-31.md", "");
        }),
        Box::new(|g| g.write("notes/project-atlas.md", "not even a heading\n")),
        Box::new(|g| {
            g.delete("notes/renamed.md");
            g.delete("daily/2026-10-31.md");
            g.write("weekly/2026-W44.md", "- week [[Countess of Lovelace]]\n");
        }),
    ];
    for (step, edit) in edits.iter().enumerate() {
        edit(&graph);
        let tree = graph.snapshot();
        incremental.update(&graph.repo, tree).unwrap();
        let mut fresh = Indexer::in_memory(prism_index::standard()).unwrap();
        fresh.update(&graph.repo, tree).unwrap();
        assert_eq!(dump(incremental.connection()), dump(fresh.connection()), "after step {step}");
    }
}

/// An index that counts what it is asked to do.
#[derive(Clone, Default)]
struct Counting {
    version: u32,
    puts: Arc<AtomicUsize>,
    removes: Arc<AtomicUsize>,
    clears: Arc<AtomicUsize>,
}

impl Index for Counting {
    fn name(&self) -> &'static str {
        "counting"
    }
    fn version(&self) -> u32 {
        self.version
    }
    fn create(&self, tx: &rusqlite::Transaction<'_>) -> prism_index::Result<()> {
        tx.execute_batch("CREATE TABLE IF NOT EXISTS sizes (path TEXT PRIMARY KEY, bytes INTEGER)")?;
        Ok(())
    }
    fn clear(&self, tx: &rusqlite::Transaction<'_>) -> prism_index::Result<()> {
        self.clears.fetch_add(1, Ordering::SeqCst);
        tx.execute("DELETE FROM sizes", [])?;
        Ok(())
    }
    fn wants(&self, path: &str) -> bool {
        path.starts_with("assets/")
    }
    fn remove(&self, tx: &rusqlite::Transaction<'_>, path: &str) -> prism_index::Result<()> {
        self.removes.fetch_add(1, Ordering::SeqCst);
        tx.execute("DELETE FROM sizes WHERE path = ?1", [path])?;
        Ok(())
    }
    fn put(&self, tx: &rusqlite::Transaction<'_>, file: &File<'_>) -> prism_index::Result<()> {
        self.puts.fetch_add(1, Ordering::SeqCst);
        assert!(file.note().is_none(), "an asset is no note");
        tx.execute("INSERT INTO sizes (path, bytes) VALUES (?1, ?2)", rusqlite::params![file.path, file.bytes().len() as i64])?;
        Ok(())
    }
}

impl Counting {
    fn counts(&self) -> (usize, usize, usize) {
        (self.puts.load(Ordering::SeqCst), self.removes.load(Ordering::SeqCst), self.clears.load(Ordering::SeqCst))
    }
}

fn sizes(indexer: &Indexer) -> Vec<(String, i64)> {
    let mut statement = indexer.connection().prepare("SELECT path, bytes FROM sizes ORDER BY path").unwrap();
    let rows = statement.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().map(Result::unwrap).collect();
    rows
}

#[test]
fn a_custom_index_sees_only_its_files_and_only_their_changes() {
    let graph = Graph::new();
    let counting = Counting::default();
    let mut indexer = Indexer::in_memory(vec![Box::new(counting.clone())]).unwrap();
    indexer.update(&graph.repo, graph.snapshot()).unwrap();
    assert_eq!(counting.counts(), (1, 0, 1), "one asset put; cleared once, for the first build");
    assert_eq!(sizes(&indexer), [("assets/diagram.png".to_owned(), 5)]);

    graph.write("notes/ada-lovelace.md", "changed, but not this index's business\n");
    assert!(indexer.update(&graph.repo, graph.snapshot()).unwrap().changed.is_empty());
    assert_eq!(counting.counts(), (1, 0, 1));

    graph.write("assets/diagram.png", b"PNG\0\0, now larger");
    graph.write("assets/new.pdf", b"%PDF");
    indexer.update(&graph.repo, graph.snapshot()).unwrap();
    // The changed file is removed, then put; the new one only put.
    assert_eq!(counting.counts(), (3, 1, 1));
    assert_eq!(sizes(&indexer), [("assets/diagram.png".to_owned(), 17), ("assets/new.pdf".to_owned(), 4)]);

    graph.delete("assets/new.pdf");
    indexer.update(&graph.repo, graph.snapshot()).unwrap();
    assert_eq!(counting.counts(), (3, 2, 1));
}

#[test]
fn an_index_survives_reopening_and_rebuilds_when_its_version_changes() {
    let graph = Graph::new();
    let database = graph.repo.git_dir().join("prism/index.sqlite");
    let counting = Counting::default();
    let tree = graph.snapshot();
    {
        let mut indexer = Indexer::open(&database, vec![Box::new(counting.clone()), Box::new(Catalog)]).unwrap();
        indexer.update(&graph.repo, tree).unwrap();
    }
    assert!(Path::new(&database).exists());
    {
        // Opened again at the same tree: nothing to do.
        let mut indexer = Indexer::open(&database, vec![Box::new(counting.clone()), Box::new(Catalog)]).unwrap();
        assert_eq!(indexer.cursor("counting").unwrap(), Some(tree));
        assert!(indexer.update(&graph.repo, tree).unwrap().is_noop());
        assert_eq!(counting.counts(), (1, 0, 1));
        // Another thread can read meanwhile.
        let reader = Indexer::reader(&database).unwrap();
        assert_eq!(Catalog::count(&reader).unwrap(), 5);
    }
    {
        // A new version of one index: only that one is rebuilt.
        let newer = Counting { version: 2, ..counting.clone() };
        let mut indexer = Indexer::open(&database, vec![Box::new(newer), Box::new(Catalog)]).unwrap();
        let update = indexer.update(&graph.repo, tree).unwrap();
        assert_eq!(update.rebuilt, ["counting"]);
        assert_eq!(update.changed, ["assets/diagram.png"]);
        assert_eq!(counting.counts(), (2, 0, 2));
        assert_eq!(sizes(&indexer).len(), 1);
    }
    {
        // An index added later builds from nothing; the others stay put.
        let mut indexer = Indexer::open(&database, vec![Box::new(Counting { version: 2, ..counting.clone() }), Box::new(Catalog), Box::new(Tasks)]).unwrap();
        let update = indexer.update(&graph.repo, tree).unwrap();
        assert_eq!(update.rebuilt, ["tasks"]);
        assert_eq!(counting.counts(), (2, 0, 2));
        assert_eq!(Tasks::counts(indexer.connection()).unwrap(), (3, 1));
        indexer.invalidate("tasks").unwrap();
        assert_eq!(indexer.update(&graph.repo, tree).unwrap().rebuilt, ["tasks"]);
        assert_eq!(Tasks::counts(indexer.connection()).unwrap(), (3, 1));
    }
}

#[test]
fn a_cursor_git_no_longer_has_means_a_rebuild() {
    let graph = Graph::new();
    let mut indexer = Indexer::in_memory(prism_index::standard()).unwrap();
    indexer.update(&graph.repo, graph.snapshot()).unwrap();
    let lost = Oid::from_str("1234567890123456789012345678901234567890").unwrap();
    indexer.connection().execute("UPDATE prism_cursors SET tree = ?1 WHERE name = 'links'", [lost.to_string()]).unwrap();
    assert_eq!(indexer.cursor("links").unwrap(), Some(lost));
    let update = indexer.update(&graph.repo, graph.snapshot()).unwrap();
    assert_eq!(update.rebuilt, ["links"]);
    assert_eq!(Links::unresolved(indexer.connection()).unwrap().len(), 1);
}

#[test]
fn indices_follow_commits_and_merges_from_other_devices() {
    let root = tempfile::tempdir().unwrap();
    let remote = root.path().join("remote.git");
    git2_init_bare(&remote);
    let device = |name: &str| {
        let dir = root.path().join(name);
        let repo = if name == "a" {
            let repo = Repository::init(&dir, "main").unwrap();
            repo.set_remote("origin", remote.to_str().unwrap()).unwrap();
            repo
        } else {
            Repository::clone(remote.to_str().unwrap(), &dir, &prism_sync::Auth::Default).unwrap()
        };
        (dir, Syncer::new(repo, Config { identity: Some(Identity::new(name, "x@example.com")), ..Config::default() }))
    };
    let (a_dir, mut a) = device("a");
    std::fs::create_dir_all(a_dir.join("notes")).unwrap();
    std::fs::write(a_dir.join("notes/one.md"), "# One\n\n[[Two]]\n").unwrap();
    a.sync(Mode::Full).unwrap();
    let (b_dir, mut b) = device("b");

    let mut index = Indexer::in_memory(prism_index::standard()).unwrap();
    index.update(b.repository(), b.repository().head_tree().unwrap().unwrap()).unwrap();
    assert_eq!(Links::unresolved(index.connection()).unwrap().len(), 1);

    // `a` writes the page linked to; `b`, meanwhile, something else.
    std::fs::write(a_dir.join("notes/two.md"), "# Two\n").unwrap();
    a.sync(Mode::Full).unwrap();
    std::fs::write(b_dir.join("notes/three.md"), "# Three\n\n[[One]]\n").unwrap();
    let report = b.sync(Mode::Full).unwrap();
    assert_eq!(report.changed, ["notes/two.md"]);

    // The index goes from the old commit's tree to the merge's in one step.
    let update = index.update(b.repository(), b.repository().head_tree().unwrap().unwrap()).unwrap();
    assert_eq!(update.changed, ["notes/three.md", "notes/two.md"]);
    assert!(Links::unresolved(index.connection()).unwrap().is_empty());
    assert_eq!(sources(&Links::backlinks(index.connection(), &["One".into()]).unwrap()), ["notes/three.md"]);
    // And a snapshot of the working tree after a sync is that same tree.
    let snapshot = b.repository().snapshot(&SnapshotOptions::default()).unwrap().tree;
    assert!(index.update(b.repository(), snapshot).unwrap().is_noop());
}

fn git2_init_bare(path: &Path) {
    Repository::init_bare(path, "main").unwrap();
}
