//! Pages' times, read off history made with git itself — at times the
//! test chooses.

use prism_index::{Catalog, Indexer, Times};
use prism_markup::Timestamp;
use prism_sync::{Repository, SnapshotOptions};
use std::path::Path;
use std::process::Command;

fn at(time: &str) -> i64 {
    Timestamp::parse(time).unwrap().0
}

fn git(dir: &Path, time: &str, args: &[&str]) {
    let output = Command::new("git")
        .current_dir(dir)
        .args(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"])
        .args(args)
        .env("GIT_AUTHOR_DATE", time)
        .env("GIT_COMMITTER_DATE", time)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
}

fn write(dir: &Path, path: &str, content: &str) {
    std::fs::create_dir_all(dir.join(path).parent().unwrap()).unwrap();
    std::fs::write(dir.join(path), content).unwrap();
}

fn commit(dir: &Path, time: &str) {
    git(dir, time, &["add", "-A"]);
    git(dir, time, &["commit", "-q", "-m", "a commit"]);
}

fn times(indexer: &Indexer) -> Vec<(String, i64, i64)> {
    let mut statement = indexer.connection().prepare("SELECT path, created, modified FROM prism_times ORDER BY path").unwrap();
    let rows = statement.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().collect::<Result<_, _>>().unwrap();
    rows
}

const T1: &str = "2026-01-01T10:00:00Z";
const T2: &str = "2026-01-02T10:00:00Z";
const T3: &str = "2026-01-03T10:00:00Z";
const T4: &str = "2026-01-04T10:00:00Z";
const T5: &str = "2026-01-05T10:00:00Z";
const T6: &str = "2026-01-06T10:00:00Z";

#[test]
fn times_follow_history_a_commit_at_a_time() {
    let dir = tempfile::tempdir().unwrap();
    let dir = dir.path();
    let repo = Repository::init(dir, "main").unwrap();
    let mut index = Indexer::in_memory(prism_index::standard()).unwrap();
    assert_eq!(index.update_times(&repo, repo.head()).unwrap(), 0, "no commits, nothing dated");

    write(dir, "notes/a.md", "# A\n");
    write(dir, "README.md", "not a page\n");
    commit(dir, T1);
    assert_eq!(index.update_times(&repo, repo.head()).unwrap(), 1);
    assert_eq!(times(&index), [("notes/a.md".into(), at(T1), at(T1))]);

    write(dir, "notes/a.md", "# A\n\nmore\n");
    write(dir, "notes/b.md", "# B\n");
    commit(dir, T2);
    // Only the new commit is read; and none, when asked again.
    assert_eq!(index.update_times(&repo, repo.head()).unwrap(), 1);
    assert_eq!(index.update_times(&repo, repo.head()).unwrap(), 0);
    assert_eq!(times(&index), [("notes/a.md".into(), at(T1), at(T2)), ("notes/b.md".into(), at(T2), at(T2))]);
    assert_eq!(Times::committed(index.connection(), "notes/b.md").unwrap(), Some((at(T2), at(T2))));
    assert_eq!(Times::committed(index.connection(), "README.md").unwrap(), None);
    assert_eq!(index.times_cursor().unwrap(), repo.head());
}

#[test]
fn a_merge_dates_only_what_it_settled() {
    let dir = tempfile::tempdir().unwrap();
    let dir = dir.path();
    let repo = Repository::init(dir, "main").unwrap();
    write(dir, "notes/a.md", "# A\n\none\n\ntwo\n\nthree\n");
    write(dir, "notes/b.md", "# B\n");
    write(dir, "notes/c.md", "# C\n\none\n");
    commit(dir, T1);
    // Another device: b, and c's line.
    git(dir, T1, &["checkout", "-q", "-b", "other"]);
    write(dir, "notes/b.md", "# B\n\ntheirs\n");
    write(dir, "notes/c.md", "# C\n\ntheirs\n");
    commit(dir, T2);
    // This one: a, and c's line too.
    git(dir, T1, &["checkout", "-q", "main"]);
    write(dir, "notes/a.md", "# A\n\nONE\n\ntwo\n\nthree\n");
    write(dir, "notes/c.md", "# C\n\nours\n");
    commit(dir, T3);
    // The merge settles c by hand.
    let merged = Command::new("git").current_dir(dir).args(["merge", "-q", "other"]).output().unwrap();
    assert!(!merged.status.success(), "c conflicts");
    write(dir, "notes/c.md", "# C\n\nboth\n");
    commit(dir, T4);

    let mut index = Indexer::in_memory(prism_index::standard()).unwrap();
    assert_eq!(index.update_times(&repo, repo.head()).unwrap(), 4);
    assert_eq!(
        times(&index),
        [
            ("notes/a.md".into(), at(T1), at(T3)), // ours, when we wrote it
            ("notes/b.md".into(), at(T1), at(T2)), // theirs, when they did — not when it was merged
            ("notes/c.md".into(), at(T1), at(T4)), // settled by the merge
        ]
    );

    // A deletion takes the page out; a page made again is made then.
    std::fs::remove_file(dir.join("notes/b.md")).unwrap();
    commit(dir, T5);
    write(dir, "notes/b.md", "# B again\n");
    commit(dir, T6);
    assert_eq!(index.update_times(&repo, repo.head()).unwrap(), 2);
    assert_eq!(Times::committed(index.connection(), "notes/b.md").unwrap(), Some((at(T6), at(T6))));

    // Read a commit at a time, or all at once: the same.
    let mut fresh = Indexer::in_memory(prism_index::standard()).unwrap();
    fresh.update_times(&repo, repo.head()).unwrap();
    assert_eq!(times(&fresh), times(&index));

    // History rewritten underneath: everything is read again.
    git(dir, T6, &["reset", "-q", "--hard", "HEAD~2"]);
    assert_eq!(index.update_times(&repo, repo.head()).unwrap(), 4);
    assert_eq!(Times::committed(index.connection(), "notes/b.md").unwrap(), Some((at(T1), at(T2))));
}

#[test]
fn a_page_is_dated_by_what_is_unsaved_then_history_and_never_by_itself() {
    let dir = tempfile::tempdir().unwrap();
    let dir = dir.path();
    let repo = Repository::init(dir, "main").unwrap();
    write(dir, "notes/plain.md", "# Plain\n");
    write(dir, "notes/stamped.md", "---\ncreated: 2020-01-01T00:00:00Z\nmodified: 2020-02-02T00:00:00Z\n---\n# Stamped\n");
    commit(dir, T1);
    write(dir, "notes/plain.md", "# Plain\n\nmore\n");
    commit(dir, T2);
    write(dir, "notes/new.md", "# New\n");

    let mut index = Indexer::in_memory(prism_index::standard()).unwrap();
    index.update(&repo, repo.snapshot(&SnapshotOptions::default()).unwrap().tree).unwrap();
    index.update_times(&repo, repo.head()).unwrap();
    let dated = |index: &Indexer, path: &str| {
        let row = Catalog::get(index.connection(), path).unwrap().unwrap();
        (row.created, row.modified)
    };
    assert_eq!(dated(&index, "notes/plain.md"), (Some(at(T1)), Some(at(T2))));
    // What a page says of its own times is a field like any other.
    assert_eq!(dated(&index, "notes/stamped.md"), (Some(at(T1)), Some(at(T1))));
    assert_eq!(dated(&index, "notes/new.md"), (None, None), "not committed, and nobody has said when it was written");

    // Written since the last commit: the file's time, until it is committed.
    index.set_unsaved(&[("notes/new.md".into(), at(T5)), ("notes/plain.md".into(), at(T6)), ("notes/stamped.md".into(), at(T6))]).unwrap();
    assert_eq!(dated(&index, "notes/new.md"), (Some(at(T5)), Some(at(T5))));
    assert_eq!(dated(&index, "notes/plain.md"), (Some(at(T1)), Some(at(T6))));
    assert_eq!(dated(&index, "notes/stamped.md"), (Some(at(T1)), Some(at(T6))));
    assert_eq!(Times::unsaved(index.connection()).unwrap().len(), 3);
    index.set_unsaved(&[]).unwrap();
    assert_eq!(dated(&index, "notes/plain.md"), (Some(at(T1)), Some(at(T2))));

    // And a query sorts by them.
    let newest = prism_index::query::run_text(index.connection(), "sort: -modified", &Default::default()).unwrap();
    assert_eq!(newest.pages.iter().map(|page| page.title.as_str()).collect::<Vec<_>>(), ["Plain", "Stamped", "New"]);
}
