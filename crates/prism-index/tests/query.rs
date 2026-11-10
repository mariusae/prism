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
    write("notes/ada.md", "---\ntags: [Person, Mathematician]\ncreated: 2026-01-01T00:00:00Z\nmodified: 2026-10-31T10:00:00Z\nbirthday: 1815-12-10\nwiki: true\npinned: 2\n---\n# Ada Lovelace\n\nWrote the first program for the [[Analytical Engine]].\n");
    write("notes/grace.md", "---\ntags: [Person]\ncreated: 2026-02-01T00:00:00Z\nmodified: 2026-11-01T10:00:00Z\ninbox: true\npinned: true\n---\n# Grace Hopper\n\nInvented the compiler. Knew of [[Ada Lovelace]].\n");
    write("notes/charles.md", "---\ntags: [Person, Archived]\ncompany: Analytical Engine\npinned: 1\n---\n# Charles Babbage\n\nDesigned the [[Analytical Engine]] and the difference engine.\n");
    write(
        "notes/engine.md",
        "---\naliases: [The Engine]\ntemplate: yes\n---\n# Analytical Engine\n\nA machine. See [[Ada Lovelace]] and [[Charles Babbage]] #machine\n",
    );
    write("notes/secret.md", "---\ntags: [Person]\nprivate: true\n---\n# Secret Person\n");
    write("daily/2026-10-31.md", "- Read about the [[the engine]] and the compiler\n");
    write("weekly/2026-W44.md", "- A week\n");
    write("notes/work-river-user.md", "# Uses a river\n\nSee [[rivers/Work]] and [[Nobody Yet]].\n");
    let mut indexer = Indexer::in_memory(prism_index::standard()).unwrap();
    indexer.update(&repo, repo.snapshot(&SnapshotOptions::default()).unwrap().tree).unwrap();
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
    assert_eq!(titles(&index, "wiki: yes"), ["Ada Lovelace"]);
    assert_eq!(titles(&index, "wiki: no\ntag: Person"), ["Grace Hopper", "Charles Babbage"]);
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
    let this = QueryOptions { this: Some("Ada Lovelace"), ..QueryOptions::default() };
    let found = run_text(index.connection(), "links to: {this}", &this).unwrap();
    assert_eq!(found.pages.iter().map(|p| p.title.as_str()).collect::<Vec<_>>(), ["Analytical Engine", "Grace Hopper"]);
}

#[test]
fn kinds_and_flags() {
    let (_dir, index) = graph();
    assert_eq!(titles(&index, "is: day"), ["2026-10-31"]);
    assert_eq!(titles(&index, "is: week"), ["2026-W44"]);
    assert_eq!(titles(&index, "is: inbox"), ["Grace Hopper"]);
    assert_eq!(titles(&index, "is: template"), ["Analytical Engine"]);
    assert_eq!(titles(&index, "is: wiki"), ["Ada Lovelace"]);
    // Pinned: those given a place, by it; then those merely pinned.
    assert_eq!(titles(&index, "is: pinned\nsort: pinned"), ["Charles Babbage", "Ada Lovelace", "Grace Hopper"]);
}

#[test]
fn order_limit_and_how_to_show() {
    let (_dir, index) = graph();
    assert_eq!(titles(&index, "tag: Person\nsort: title"), ["Ada Lovelace", "Charles Babbage", "Grace Hopper"]);
    assert_eq!(titles(&index, "tag: Person\nsort: -title"), ["Grace Hopper", "Charles Babbage", "Ada Lovelace"]);
    // Newest first; a page with no time, last either way.
    assert_eq!(titles(&index, "tag: Person\nsort: -modified"), ["Grace Hopper", "Ada Lovelace", "Charles Babbage"]);
    assert_eq!(titles(&index, "tag: Person\nsort: created"), ["Ada Lovelace", "Grace Hopper", "Charles Babbage"]);
    assert_eq!(titles(&index, "listed in: Person"), ["Grace Hopper", "Ada Lovelace"]);

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
    let all = QueryOptions { include_private: true, ..QueryOptions::default() };
    assert_eq!(run_text(index.connection(), "tag: Person", &all).unwrap().total, 4);
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
    assert_eq!(schema, ["birthday", "company"]);
    // A link to a saved river is no page waiting to be written.
    assert_eq!(Links::unresolved(db).unwrap(), [("Nobody Yet".to_owned(), 1)]);
}
