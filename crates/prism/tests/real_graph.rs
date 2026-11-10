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
    engine.note_changed();
    engine.settle();
    println!("nothing changed: checked in {:.2?}", started.elapsed());

    let started = Instant::now();
    let hits = Search::search(&db, "the", 20).unwrap().len();
    let all = Catalog::all(&db).unwrap().len();
    println!("a search ({hits} hits) and a full listing ({all}) in {:.2?}", started.elapsed());
    assert_eq!(pages, notes);
    assert!(incremental < built, "an edit should cost less than a rebuild");
}
