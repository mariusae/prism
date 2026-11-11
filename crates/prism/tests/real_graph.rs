//! The engine on a real graph's notes: `PRISM_GRAPH=~/notes cargo test
//! --release -p prism --test real_graph -- --nocapture`.
//!
//! The graph is only read: its notes are copied into a repository made
//! for the test, and everything happens there. Without `PRISM_GRAPH` the
//! test does nothing.

use prism::index::{Catalog, Links, Search, Tasks};
use prism::sync::{Mode, Repository};
use prism::{Engine, EngineConfig};
use std::path::Path;
use std::time::Instant;

fn copy_notes(from: &Path, to: &Path, count: &mut usize) {
    let Ok(entries) = std::fs::read_dir(from) else { return };
    for entry in entries.flatten() {
        let (path, name) = (entry.path(), entry.file_name());
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        if path.is_dir() {
            copy_notes(&path, &to.join(&name), count);
        } else if path.extension().is_some_and(|e| e == "md") {
            std::fs::create_dir_all(to).unwrap();
            std::fs::copy(&path, to.join(&name)).unwrap();
            *count += 1;
        }
    }
}

#[test]
fn a_real_graph_is_indexed_and_committed() {
    let Some(source) = std::env::var_os("PRISM_GRAPH") else { return };
    let dir = tempfile::tempdir().unwrap();
    let mut notes = 0;
    for folder in ["daily", "weekly", "notes"] {
        copy_notes(&Path::new(&source).join(folder), &dir.path().join(folder), &mut notes);
    }
    Repository::init(dir.path(), "main").unwrap();

    let started = Instant::now();
    let engine = Engine::start(dir.path(), EngineConfig::default()).unwrap();
    engine.settle();
    let built = started.elapsed();
    let db = engine.index().unwrap();
    let pages = Catalog::count(&db).unwrap();
    println!("{notes} notes copied; {pages} pages indexed from nothing in {built:.2?}");
    println!(
        "  {} tags, {} unresolved links, tasks open/done {:?}",
        Catalog::tags(&db).unwrap().len(),
        Links::unresolved(&db).unwrap().len(),
        Tasks::counts(&db).unwrap()
    );

    let started = Instant::now();
    let report = engine.sync_blocking(Mode::Full).unwrap();
    println!("first commit ({}) in {:.2?}", report.committed.unwrap_or_default(), started.elapsed());

    // One note edited: how long until the indices have it?
    let path = engine.graph().note_paths().into_iter().next_back().unwrap();
    let text = engine.graph().read(&path).unwrap().unwrap();
    let started = Instant::now();
    engine.write(&path, &format!("{text}\n- zzzuniquewordzzz [[A Brand New Page]]\n")).unwrap();
    engine.settle();
    let incremental = started.elapsed();
    assert_eq!(Search::search(&db, "zzzuniquewordzzz", 5).unwrap().len(), 1);
    println!("one note edited: written and indexed in {incremental:.2?}");

    let started = Instant::now();
    let report = engine.sync_blocking(Mode::Full).unwrap();
    println!("that edit committed ({}), and the tree indexed after, in {:.2?}", report.committed.unwrap_or_default(), started.elapsed());

    let started = Instant::now();
    engine.note_changed();
    engine.settle();
    println!("told something changed, not what: every file looked at in {:.2?}", started.elapsed());

    let started = Instant::now();
    let hits = Search::search(&db, "the", 20).unwrap().len();
    let all = Catalog::all(&db).unwrap().len();
    println!("a search ({hits} hits) and a full listing ({all}) in {:.2?}", started.elapsed());

    // What an app asks as it draws: each timed alone, on a warm connection.
    let timed = |what: &str, ask: &dyn Fn() -> usize| {
        ask();
        let started = Instant::now();
        let found = ask();
        println!("  {what}: {found} in {:.2?}", started.elapsed());
    };
    let db = &db;
    let query = |body: &'static str| move || prism::index::query::run_text(db, body, &Default::default()).unwrap().pages.len();
    timed("the 10 pages changed last", &query("sort: -modified\nlimit: 10"));
    timed("the first 20 pages by title", &query("limit: 20"));
    timed("pages tagged #book", &query("tag: book"));
    timed("pages tagged #book, the 10 changed last", &query("tag: book\nsort: -modified\nlimit: 10"));
    timed("pages marked inbox", &query("is: inbox"));
    timed("days that are not blank, newest 30", &query("is: day\nis not: blank\nsort: -title\nlimit: 30"));
    timed("pages whose text says \"meeting\"", &query("text: meeting\nlimit: 20"));
    timed("completing \"pro\"", &|| Catalog::complete(db, "pro", 10).unwrap().len());
    timed("backlinks of today's most linked name", &|| Links::backlinks(db, &["link".into()]).unwrap().len());
    timed("pages in conflict", &|| Catalog::conflicted(db).unwrap().len());
    assert_eq!(pages, notes);
    assert!(incremental < built, "an edit should cost less than a rebuild");
}

/// How long a real history takes to read for pages' times. The graph is
/// cloned — which only reads it — and the clone is what is walked.
#[test]
fn a_real_history_dates_its_pages() {
    let Some(source) = std::env::var_os("PRISM_GRAPH") else { return };
    let dir = tempfile::tempdir().unwrap();
    let cloned = std::process::Command::new("git").args(["clone", "-q", "--no-checkout"]).arg(&source).arg(dir.path()).status().unwrap();
    assert!(cloned.success());
    let repo = Repository::open(dir.path()).unwrap();
    let mut indexer = prism::index::Indexer::in_memory(prism::index::standard()).unwrap();
    let started = Instant::now();
    let commits = indexer.update_times(&repo, repo.head()).unwrap();
    let dated: i64 = indexer.connection().query_row("SELECT count(*) FROM prism_times", [], |r| r.get(0)).unwrap();
    println!("{commits} commits read in {:.2?}; {dated} pages dated", started.elapsed());
    let started = Instant::now();
    assert_eq!(indexer.update_times(&repo, repo.head()).unwrap(), 0);
    println!("asked again: {:.2?}", started.elapsed());
}

/// Where a real graph's links lead, now that a page's own name is what
/// leads to it first: how many lead elsewhere than they did when titles
/// led, then aliases, the lower path first. The graph is cloned — which
/// only reads it — and the clone is what is indexed; nothing is synced.
#[test]
fn a_real_graphs_links_lead_where_they_led() {
    let Some(source) = std::env::var_os("PRISM_GRAPH") else { return };
    let dir = tempfile::tempdir().unwrap();
    let cloned = std::process::Command::new("git").args(["clone", "-q"]).arg(&source).arg(dir.path()).status().unwrap();
    assert!(cloned.success());
    let engine = Engine::start(dir.path(), EngineConfig::default()).unwrap();
    engine.settle();
    let db = engine.index_showing_private().unwrap();
    let before = "(SELECT path FROM note_names WHERE note_names.key = links.key AND rank >= 0 ORDER BY rank, path LIMIT 1)";
    let now = "(SELECT substr(min(printf('%d|%020d|',
         CASE WHEN rank = -1 AND name = links.target THEN 0 WHEN rank = -1 THEN 3 ELSE rank + 1 END,
         coalesce((SELECT created FROM prism_dates WHERE prism_dates.path = note_names.path), 9223372036854775807)) || path), 24)
     FROM note_names WHERE note_names.key = links.key)";
    let count = |sql: &str| -> i64 { db.query_row(sql, [], |r| r.get(0)).unwrap() };
    let links = count("SELECT count(*) FROM links");
    let moved = count(&format!("SELECT count(*) FROM links WHERE {before} IS NOT NULL AND {before} IS NOT {now}"));
    let found = count(&format!("SELECT count(*) FROM links WHERE {before} IS NULL AND {now} IS NOT NULL AND kind != 'tag'"));
    println!("{links} links; {moved} lead elsewhere than they did; {found} that led nowhere now lead to a file of that name");
    let mut statement = db
        .prepare(&format!("SELECT target, kind, count(*), {before}, {now} FROM links WHERE {before} IS NOT NULL AND {before} IS NOT {now} GROUP BY key, kind"))
        .unwrap();
    let rows = statement
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?, r.get::<_, String>(3)?, r.get::<_, Option<String>>(4)?)))
        .unwrap();
    for row in rows.flatten() {
        println!("  {} × {} [[{}]]: {} → {}", row.2, row.1, row.0, row.3, row.4.unwrap_or_default());
    }
    println!("{} titles or aliases are more than one page's", Catalog::duplicates(&db).unwrap().len());
}
