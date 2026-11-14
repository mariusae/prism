//! Queries, run against a small graph.

use prism_index::query::{run_text, QueryOptions, Show};
use prism_index::{Catalog, Indexer, Links};
use prism_sync::{Repository, SnapshotOptions};

fn graph() -> (tempfile::TempDir, Indexer) {
    let dir = tempfile::tempdir().unwrap();
    let repo = Repository::init(dir.path(), "main").unwrap();
    let write = |path: &str, content: &str| {
        let file = dir.path().join(path);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, content).unwrap();
    };
    write(
        "notes/person.md",
        "---\nfields:\n  - birthday (date)\n  - company (link)\n  - modified (date)\nlist:\n  - Grace Hopper\n  - \"[[Ada Lovelace]]\"\n---\n# Person\n",
    );
    write("notes/ada.md", "---\ntags: [Person, Mathematician]\nbirthday: 1815-12-10\nwiki: true\npinned: 2\n---\n# Ada Lovelace\n\nWrote the first program for the [[Analytical Engine]].\n");
    write("notes/grace.md", "---\ntags: [Person]\ninbox: true\npinned: true\n---\n# Grace Hopper\n\nInvented the compiler. Knew of [[Ada Lovelace]].\n");
    write("notes/charles.md", "---\ntags: [Person, Archived]\ncompany: Analytical Engine\npinned: 1\n---\n# Charles Babbage\n\nDesigned the [[Analytical Engine]] and the difference engine.\n");
    write(
        "notes/engine.md",
        "---\naliases: [The Engine]\ntemplate: yes\n---\n# Analytical Engine\n\nA machine. See [[Ada Lovelace]] and [[Charles Babbage]] #machine\n",
    );
    write("notes/secret.md", "---\ntags: [Person]\nprivate: true\n---\n# Secret Person\n");
    write("daily/2026-10-31.md", "- Read about the [[the engine]] and the compiler\n");
    write("weekly/2026-W44.md", "- A week\n");
    write("notes/work-river-user.md", "# Uses a river\n\nSee [[rivers/Work]] and [[Nobody Yet]].\n");
    write("rivers/Work.md", "- [[Charles Babbage]]\n- [[ada lovelace]]\n  - 2: a folded row\n");
    let mut indexer = Indexer::in_memory(prism_index::standard()).unwrap();
    indexer.update(&repo, repo.snapshot(&SnapshotOptions::default()).unwrap().tree).unwrap();
    // When each was last written: nothing in the pages says.
    indexer.set_unsaved(&[("notes/ada.md".into(), 100), ("notes/grace.md".into(), 200)]).unwrap();
    // As an app's view is: private pages hidden.
    prism_index::show_private(indexer.connection(), false).unwrap();
    (dir, indexer)
}

fn titles(indexer: &Indexer, body: &str) -> Vec<String> {
    run_text(indexer.connection(), body, &QueryOptions::default()).unwrap().pages.into_iter().map(|p| p.title).collect()
}

#[test]
fn conditions_narrow_and_every_one_must_hold() {
    let (_dir, index) = graph();
    // A tag's pages come in the tag's own order: its page's `list`, then title.
    assert_eq!(titles(&index, "tag: Person"), ["Grace Hopper", "Ada Lovelace", "Charles Babbage"]);
    assert_eq!(titles(&index, "tag: person\ntag: mathematician"), ["Ada Lovelace"]);
    assert_eq!(titles(&index, "tag: Person\nnot tag: Archived"), ["Grace Hopper", "Ada Lovelace"]);
    assert_eq!(titles(&index, "title: LOVE ada"), ["Ada Lovelace"]);
    assert_eq!(titles(&index, "text: compiler"), ["2026-10-31", "Grace Hopper"]);
    assert_eq!(titles(&index, "text: compiler\nis: note"), ["Grace Hopper"]);
    assert_eq!(titles(&index, "has: birthday"), ["Ada Lovelace"]);
    assert_eq!(titles(&index, "has: pinned, company"), ["Charles Babbage"]);
    assert_eq!(titles(&index, "is: wiki"), ["Ada Lovelace"]);
    assert_eq!(titles(&index, "is not: wiki\ntag: Person"), ["Grace Hopper", "Charles Babbage"]);
    // A tag is a link: the pages tagged Person point at the page Person.
    assert_eq!(titles(&index, "links to: Person"), ["Ada Lovelace", "Charles Babbage", "Grace Hopper"]);
    assert!(titles(&index, "tag: Nobody").is_empty());
}

#[test]
fn links_are_followed_both_ways_by_any_name() {
    let (_dir, index) = graph();
    // By title, by alias: the same page, and every way it is linked to.
    assert_eq!(titles(&index, "links to: Analytical Engine"), ["2026-10-31", "Ada Lovelace", "Charles Babbage"]);
    assert_eq!(titles(&index, "links to: the engine"), ["2026-10-31", "Ada Lovelace", "Charles Babbage"]);
    assert_eq!(titles(&index, "linked from: Analytical Engine"), ["Ada Lovelace", "Charles Babbage"]);
    // A page not written yet is still linked to.
    assert_eq!(titles(&index, "links to: Nobody Yet"), ["Uses a river"]);
    assert!(titles(&index, "linked from: Nobody Yet").is_empty());
    // `{this}` is the page the query is in.
    let this = QueryOptions { this: Some("Ada Lovelace") };
    let found = run_text(index.connection(), "links to: {this}", &this).unwrap();
    assert_eq!(found.pages.iter().map(|p| p.title.as_str()).collect::<Vec<_>>(), ["Analytical Engine", "Grace Hopper", "Person"], "Person lists her");
}

#[test]
fn kinds_and_flags() {
    let (_dir, index) = graph();
    assert_eq!(titles(&index, "is: day"), ["2026-10-31"]);
    assert_eq!(titles(&index, "is: week"), ["2026-W44"]);
    assert_eq!(titles(&index, "is: inbox"), ["Grace Hopper"]);
    assert_eq!(titles(&index, "is: template"), ["Analytical Engine"]);
    assert_eq!(titles(&index, "is not: note"), ["2026-10-31", "2026-W44"]);
    // A mark is any field that does not say no; sorted by, numbers come
    // first: those given a place, by it, then those merely pinned.
    assert_eq!(titles(&index, "is: pinned\nsort: pinned"), ["Charles Babbage", "Ada Lovelace", "Grace Hopper"]);
    assert_eq!(titles(&index, "tag: Person\nsort: -birthday"), ["Ada Lovelace", "Charles Babbage", "Grace Hopper"], "pages without the field, last");
}

#[test]
fn order_limit_and_how_to_show() {
    let (_dir, index) = graph();
    assert_eq!(titles(&index, "tag: Person\nsort: title"), ["Ada Lovelace", "Charles Babbage", "Grace Hopper"]);
    assert_eq!(titles(&index, "tag: Person\nsort: -title"), ["Grace Hopper", "Charles Babbage", "Ada Lovelace"]);
    // Newest first; a page with no time, last either way.
    assert_eq!(titles(&index, "tag: Person\nsort: -modified"), ["Grace Hopper", "Ada Lovelace", "Charles Babbage"]);
    assert_eq!(titles(&index, "tag: Person\nsort: created"), ["Ada Lovelace", "Grace Hopper", "Charles Babbage"]);
    // An order set by hand is a list of links: a page's `list`, a river's cards.
    assert_eq!(titles(&index, "listed in: Person"), ["Grace Hopper", "Ada Lovelace"]);
    assert_eq!(titles(&index, "listed in: rivers/Work"), ["Charles Babbage", "Ada Lovelace"]);
    assert_eq!(titles(&index, "listed in: rivers/Work\nsort: title"), ["Ada Lovelace", "Charles Babbage"]);

    let found = run_text(index.connection(), "tag: Person\nsort: title\nlimit: 2\nshow: table\nsome future: clause", &QueryOptions::default()).unwrap();
    assert_eq!((found.pages.len(), found.total, found.show), (2, 3, Show::Table));
    // A table's columns: the tag's typed fields, unless the query says.
    assert_eq!(found.columns, ["birthday", "company", "modified"]);
    let found = run_text(index.connection(), "tag: Person\ncolumns: company\nshow: count", &QueryOptions::default()).unwrap();
    assert_eq!((found.columns, found.show), (vec!["company".to_owned()], Show::Count));
    assert_eq!(run_text(index.connection(), "", &QueryOptions::default()).unwrap().total, 8, "no condition: every page but the private one");
}

#[test]
fn private_pages_are_found_only_when_asked_for() {
    let (_dir, index) = graph();
    assert!(!titles(&index, "tag: Person").contains(&"Secret Person".to_owned()));
    // Asked for outright — of the connection, so of every question on it.
    prism_index::show_private(index.connection(), true).unwrap();
    assert_eq!(run_text(index.connection(), "tag: Person", &QueryOptions::default()).unwrap().total, 4);
}

#[test]
fn typed_fields_come_from_a_pages_tags() {
    let (_dir, index) = graph();
    let db = index.connection();
    let specs: Vec<String> = Catalog::field_specs(db, "#person").unwrap().iter().map(|s| s.to_string()).collect();
    assert_eq!(specs, ["birthday (date)", "company (link)", "modified (date)"]);
    assert!(Catalog::field_specs(db, "Mathematician").unwrap().is_empty(), "a tag with no page gives none");
    // A page's form: its tags' fields, without the page's own.
    let schema: Vec<String> = Catalog::schema(db, "notes/ada.md").unwrap().iter().map(|s| s.name.clone()).collect();
    assert_eq!(schema, ["birthday", "company", "modified"]);
    // A link to a saved river is no page waiting to be written.
    assert_eq!(Links::unresolved(db).unwrap(), [("Nobody Yet".to_owned(), 1)]);
}

#[test]
fn the_pages_changed_last_are_read_off_an_index() {
    let (_dir, mut index) = graph();
    prism_index::show_private(index.connection(), true).unwrap();
    index
        .set_unsaved(&[("notes/ada.md".into(), 100), ("notes/grace.md".into(), 200), ("notes/charles.md".into(), 300), ("notes/secret.md".into(), 400)])
        .unwrap();
    prism_index::show_private(index.connection(), false).unwrap();
    let found = run_text(index.connection(), "sort: -modified\nlimit: 2", &QueryOptions::default()).unwrap();
    assert_eq!(found.pages.iter().map(|p| p.title.as_str()).collect::<Vec<_>>(), ["Charles Babbage", "Grace Hopper"], "the private one is passed over");
    assert_eq!(found.total, 8, "all there are, counted without being loaded");
    // Past the dated, the undated follow, by title, either way.
    let found = run_text(index.connection(), "is: note\nsort: modified\nlimit: 5", &QueryOptions::default()).unwrap();
    assert_eq!(
        found.pages.iter().map(|p| p.title.as_str()).collect::<Vec<_>>(),
        ["Ada Lovelace", "Grace Hopper", "Charles Babbage", "Analytical Engine", "Person"]
    );
    assert_eq!(found.total, 6);
    // What SQLite does for it: walks the index of when pages changed.
    let plan = prism_index::query::plan(
        index.connection(),
        "SELECT notes.path FROM notes JOIN prism_dates AS dated ON dated.path = notes.path WHERE dated.modified IS NOT NULL ORDER BY dated.modified DESC, notes.title COLLATE NOCASE, notes.path LIMIT 10",
    )
    .unwrap();
    assert!(plan.contains("prism_dates_modified"), "{plan}");
    // And for a tag: the links' index, not every page.
    let plan = prism_index::query::plan(
        index.connection(),
        "SELECT path FROM notes WHERE notes.path IN (SELECT source FROM links WHERE kind = 'tag' AND key = 'person')",
    )
    .unwrap();
    assert!(plan.contains("links_key"), "{plan}");
}

#[test]
fn a_query_asks_what_it_always_did() {
    let (_dir, index) = graph();
    // Words of a title are matched as names are: case and spacing aside, in any script.
    assert_eq!(titles(&index, "title: ANALYT  engine"), ["Analytical Engine"]);
    assert!(titles(&index, "text: (\"-)").is_empty() && titles(&index, "linked from: Nobody").is_empty() && titles(&index, "listed in: Nobody").is_empty());
    // A limit of none at all, and one past the end.
    assert_eq!(run_text(index.connection(), "tag: Person\nlimit: 0", &QueryOptions::default()).unwrap().total, 3);
    let found = run_text(index.connection(), "tag: Person\nlimit: 10", &QueryOptions::default()).unwrap();
    assert_eq!((found.pages.len(), found.total), (3, 3));
    // Descending by a field: words before numbers, pages without it still last.
    assert_eq!(titles(&index, "tag: Person\nsort: -pinned"), ["Grace Hopper", "Ada Lovelace", "Charles Babbage"]);
    assert_eq!(titles(&index, "sort: -pinned\nlimit: 4"), ["Grace Hopper", "Ada Lovelace", "Charles Babbage", "2026-10-31"]);
}

#[test]
fn archived_pages_are_left_out_unless_asked_for_and_found_last() {
    let (dir, mut index) = graph();
    // Grace archived: out of every query that does not ask about archiving.
    std::fs::write(dir.path().join("notes/grace.md"), "---\ntags: [Person]\narchived: true\n---\n# Grace Hopper\n\nInvented the compiler.\n").unwrap();
    let repo = Repository::open(dir.path()).unwrap();
    index.update(&repo, repo.snapshot(&SnapshotOptions::default()).unwrap().tree).unwrap();
    assert_eq!(titles(&index, "tag: Person"), ["Ada Lovelace", "Charles Babbage"]);
    assert_eq!(titles(&index, "tag: Person\ninclude: archived"), ["Grace Hopper", "Ada Lovelace", "Charles Babbage"]);
    assert_eq!(titles(&index, "is: archived"), ["Grace Hopper"]);
    // `in: Work` is the saved river's notes.
    assert_eq!(titles(&index, "in: Work"), ["Charles Babbage", "Ada Lovelace"]);
    // Found by name and by words, but after the rest.
    let compiler = prism_index::Search::search(index.connection(), "compiler", 10).unwrap();
    assert_eq!(compiler.last().map(|hit| hit.title.as_str()), Some("Grace Hopper"));
    let named = Catalog::complete(index.connection(), "", 20).unwrap();
    assert_eq!(named.last().map(|row| row.title.as_str()), Some("Grace Hopper"));
}
