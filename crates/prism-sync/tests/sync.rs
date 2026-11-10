//! The sync engine against real repositories: a bare "remote" on disk and
//! two or three "devices" cloned from it, each with its own `Syncer`.

use prism_sync::{conflict, Auth, Config, Error, FileMerge, MergeDriver, MergeKind, Mode, Repository, SnapshotOptions, Syncer};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tempfile::TempDir;

struct World {
    _root: TempDir,
    remote: PathBuf,
    root: PathBuf,
}

struct Device {
    dir: PathBuf,
    syncer: Syncer,
}

impl World {
    fn new() -> World {
        let root = tempfile::tempdir().unwrap();
        let remote = root.path().join("remote.git");
        git2::Repository::init_bare(&remote).unwrap().set_head("refs/heads/main").unwrap();
        World { remote, root: root.path().to_owned(), _root: root }
    }

    /// A device with a new repository pointed at the remote: the first
    /// device a graph is set up on.
    fn first_device(&self, name: &str) -> Device {
        let dir = self.root.join(name);
        let repo = Repository::init(&dir, "main").unwrap();
        repo.set_remote("origin", self.remote.to_str().unwrap()).unwrap();
        Device::new(dir, repo, name)
    }

    /// A device that clones the remote.
    fn clone_device(&self, name: &str) -> Device {
        let dir = self.root.join(name);
        let repo = Repository::clone(self.remote.to_str().unwrap(), &dir, &Auth::Default).unwrap();
        Device::new(dir, repo, name)
    }

    /// Two devices, both holding `files`, in sync.
    fn pair(&self, files: &[(&str, &str)]) -> (Device, Device) {
        let mut a = self.first_device("a");
        for (path, content) in files {
            a.write(path, content);
        }
        a.sync();
        let b = self.clone_device("b");
        (a, b)
    }
}

impl Device {
    fn new(dir: PathBuf, repo: Repository, name: &str) -> Device {
        let config =
            Config { device: Some(name.to_owned()), identity: Some(prism_sync::Identity::new(name, format!("{name}@example.com"))), ..Config::default() };
        Device { dir, syncer: Syncer::new(repo, config) }
    }

    fn write(&self, path: &str, content: impl AsRef<[u8]>) {
        let file = self.dir.join(path);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, content).unwrap();
    }

    fn read(&self, path: &str) -> String {
        std::fs::read_to_string(self.dir.join(path)).unwrap_or_else(|e| panic!("{path}: {e}"))
    }

    fn exists(&self, path: &str) -> bool {
        self.dir.join(path).exists()
    }

    fn delete(&self, path: &str) {
        std::fs::remove_file(self.dir.join(path)).unwrap();
    }

    fn sync(&mut self) -> prism_sync::Report {
        self.syncer.sync(Mode::Full).unwrap()
    }

    fn repo(&self) -> &Repository {
        self.syncer.repository()
    }

    fn head_message(&self) -> String {
        self.repo().recent_commits("HEAD", 1).unwrap().remove(0).message
    }

    /// Every file in HEAD with its content: what the device has committed.
    fn committed(&self) -> Vec<(String, String)> {
        let repo = self.repo();
        let tree = repo.head_tree().unwrap().unwrap();
        repo.files(tree).unwrap().into_iter().map(|(path, entry)| (path, String::from_utf8_lossy(&repo.blob(entry.id).unwrap()).into_owned())).collect()
    }
}

/// Syncs both until neither has anything left to do, and checks they hold
/// the same commit and the same files.
fn converge(a: &mut Device, b: &mut Device) {
    for _ in 0..4 {
        a.sync();
        b.sync();
    }
    assert!(a.sync().is_quiet() && b.sync().is_quiet(), "the devices never settled");
    assert_eq!(a.repo().head(), b.repo().head());
    assert_eq!(a.committed(), b.committed());
    // And each working tree is exactly what was committed.
    for device in [&*a, &*b] {
        let snapshot = device.repo().snapshot(&SnapshotOptions::default()).unwrap();
        assert_eq!(Some(snapshot.tree), device.repo().head_tree().unwrap());
    }
}

#[test]
fn the_first_sync_fills_an_empty_remote_and_a_clone_has_it_all() {
    let world = World::new();
    let mut a = world.first_device("a");
    a.write("daily/2026-10-31.md", "- Kick-off\n");
    a.write("notes/atlas.md", "# Atlas\n");
    let report = a.sync();
    assert_eq!(report.committed.as_deref(), Some("Update 2 files"));
    assert!(report.pushed);
    assert_eq!(a.head_message(), "Update 2 files\n\nDevice: a");
    assert_eq!(prism_sync::sync::device_in(&a.head_message()), Some("a"));

    let mut b = world.clone_device("b");
    assert_eq!(b.read("notes/atlas.md"), "# Atlas\n");
    assert!(b.sync().is_quiet());
    assert!(a.sync().is_quiet());
}

#[test]
fn changes_flow_both_ways() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("notes/one.md", "one\n")]);
    a.write("notes/two.md", "from a\n");
    b.write("notes/three.md", "from b\n");
    a.write("notes/one.md", "one, edited on a\n");

    let report = a.sync();
    assert_eq!((report.pulled, report.merge, report.pushed), (0, MergeKind::UpToDate, true));
    let report = b.sync();
    assert_eq!((report.pulled, report.merge, report.pushed), (1, MergeKind::Merged, true));
    assert_eq!(report.changed, ["notes/one.md", "notes/two.md"]);
    assert!(report.conflicted.is_empty());
    assert!(b.head_message().starts_with("Merge changes from other devices\n"));

    let report = a.sync();
    // Nothing was written on a meanwhile: its branch just moves up.
    assert_eq!((report.pulled, report.merge, report.pushed), (2, MergeKind::FastForward, false));
    assert_eq!(report.changed, ["notes/three.md"]);
    converge(&mut a, &mut b);
    assert_eq!(a.read("notes/one.md"), "one, edited on a\n");
    assert_eq!(a.read("notes/three.md"), "from b\n");
    assert_eq!(b.read("notes/two.md"), "from a\n");
}

#[test]
fn edits_to_different_lines_of_one_file_merge() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("daily/2026-10-31.md", "- one\n- two\n- three\n")]);
    a.write("daily/2026-10-31.md", "- ONE\n- two\n- three\n");
    b.write("daily/2026-10-31.md", "- one\n- two\n- three\n- four\n");
    a.sync();
    let report = b.sync();
    assert_eq!(report.merge, MergeKind::Merged);
    converge(&mut a, &mut b);
    assert_eq!(a.read("daily/2026-10-31.md"), "- ONE\n- two\n- three\n- four\n");
}

#[test]
fn edits_to_the_same_lines_keep_both_and_the_sync_goes_on() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("notes/plan.md", "# Plan\n\n- draft\n"), ("notes/other.md", "x\n")]);
    a.write("notes/plan.md", "# Plan\n\n- a's version\n");
    b.write("notes/plan.md", "# Plan\n\n- b's version\n");
    b.write("notes/other.md", "x\ny\n");
    a.sync();
    let report = b.sync();
    assert_eq!(report.merge, MergeKind::MergedWithConflicts);
    assert_eq!(report.conflicted, ["notes/plan.md"]);
    assert!(report.pushed, "a conflict must not stop the push");
    assert!(b.head_message().starts_with("Merge changes from other devices (conflicts to review)"));
    assert!(report.to_string().contains("1 change pulled with conflicts to review"));
    let merged = b.read("notes/plan.md");
    assert_eq!(merged, "# Plan\n\n<<<<<<< this device\n- b's version\n=======\n- a's version\n>>>>>>> other device\n");
    assert!(b.repo().operation_in_progress().is_none());

    converge(&mut a, &mut b);
    assert_eq!(a.read("notes/plan.md"), merged);
    assert_eq!(a.read("notes/other.md"), "x\ny\n");

    // Settling it is an ordinary edit.
    a.write("notes/plan.md", conflict::resolve(&merged, conflict::Keep::Both));
    converge(&mut a, &mut b);
    assert_eq!(b.read("notes/plan.md"), "# Plan\n\n- b's version\n- a's version\n");
}

#[test]
fn a_file_changed_here_and_deleted_there_is_kept() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("notes/keep.md", "old\n"), ("notes/gone.md", "bye\n")]);
    a.delete("notes/keep.md");
    a.delete("notes/gone.md");
    b.write("notes/keep.md", "old\nand something new\n");
    b.delete("notes/gone.md");
    a.sync();
    let report = b.sync();
    assert_eq!(report.conflicted, ["notes/keep.md"]);
    converge(&mut a, &mut b);
    assert_eq!(a.read("notes/keep.md"), "old\nand something new\n");
    assert!(!a.exists("notes/gone.md") && !b.exists("notes/gone.md"));
    // The emptied directory is not left behind... nor is a full one removed.
    assert!(a.exists("notes"));
}

#[test]
fn a_binary_file_both_changed_keeps_ours_and_theirs_beside_it() {
    let world = World::new();
    let mut a = world.first_device("a");
    a.write("assets/pic.png", b"PNG\0original");
    a.sync();
    let mut b = world.clone_device("b");
    a.write("assets/pic.png", b"PNG\0from a");
    b.write("assets/pic.png", b"PNG\0from b");
    a.sync();
    let report = b.sync();
    assert_eq!(report.conflicted, ["assets/pic (conflict).png", "assets/pic.png"]);
    assert_eq!(std::fs::read(b.dir.join("assets/pic.png")).unwrap(), b"PNG\0from b");
    assert_eq!(std::fs::read(b.dir.join("assets/pic (conflict).png")).unwrap(), b"PNG\0from a");
    converge(&mut a, &mut b);
    assert_eq!(std::fs::read(a.dir.join("assets/pic (conflict).png")).unwrap(), b"PNG\0from a");
}

#[test]
fn both_adding_the_same_file_merges_or_conflicts_by_content() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("README.md", "graph\n")]);
    a.write("daily/2026-11-01.md", "- same\n");
    b.write("daily/2026-11-01.md", "- same\n");
    a.write("daily/2026-11-02.md", "- from a\n");
    b.write("daily/2026-11-02.md", "- from b\n");
    a.sync();
    let report = b.sync();
    assert_eq!(report.conflicted, ["daily/2026-11-02.md"]);
    converge(&mut a, &mut b);
    assert_eq!(a.read("daily/2026-11-01.md"), "- same\n");
    assert_eq!(a.read("daily/2026-11-02.md"), "<<<<<<< this device\n- from b\n=======\n- from a\n>>>>>>> other device\n");
}

#[test]
fn a_push_turned_away_is_met_with_a_merge_and_tried_again() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("notes/one.md", "one\n")]);
    b.write("notes/b.md", "b\n");
    b.sync();
    // `a` does not know the remote moved: a push-only cycle finds out.
    a.write("notes/a.md", "a\n");
    let report = a.syncer.sync(Mode::Push).unwrap();
    assert!(report.pushed);
    assert_eq!((report.pulled, report.merge), (1, MergeKind::Merged));
    assert_eq!(report.changed, ["notes/b.md"]);
    assert_eq!(report.timings.iter().filter(|(step, _)| *step == "pushing").count(), 2);
    converge(&mut a, &mut b);
}

#[test]
fn a_push_cycle_with_nothing_to_push_never_asks_the_remote() {
    let world = World::new();
    let (mut a, _b) = world.pair(&[("notes/one.md", "one\n")]);
    // A remote that cannot be reached: any network use would fail.
    a.repo().set_remote("origin", "/nonexistent/remote.git").unwrap();
    let report = a.syncer.sync(Mode::Push).unwrap();
    assert!(report.is_quiet());
    assert_eq!(report.to_string(), "nothing to do");
    // With something written, the commit is made, and the push fails —
    // leaving the commit for the next cycle.
    a.write("notes/one.md", "edited\n");
    let error = a.syncer.sync(Mode::Push).unwrap_err();
    assert!(matches!(error, Error::Push(_)) && error.is_transient(), "{error:?}");
    assert_eq!(a.head_message(), "Update notes/one.md\n\nDevice: a");
    assert!(matches!(a.syncer.sync(Mode::Full).unwrap_err(), Error::Fetch(_)));
}

#[test]
fn without_a_remote_the_commit_is_the_whole_cycle() {
    let root = tempfile::tempdir().unwrap();
    let repo = Repository::init(root.path(), "main").unwrap();
    let mut syncer = Syncer::new(repo, Config::default());
    assert!(syncer.sync(Mode::Full).unwrap().is_quiet()); // nothing written yet
    std::fs::write(root.path().join("a.md"), "a\n").unwrap();
    let report = syncer.sync(Mode::Full).unwrap();
    assert_eq!(report.committed.as_deref(), Some("Update a.md"));
    assert!(!report.pushed);
    assert_eq!(report.head, syncer.repository().head());
    assert!(syncer.sync(Mode::Full).unwrap().is_quiet());
}

#[test]
fn large_files_are_left_out_and_said_so() {
    let world = World::new();
    let mut a = world.first_device("a");
    a.syncer = Syncer::new(a.repo().reopen().unwrap(), Config { max_file_bytes: 1000, ..Config::default() });
    a.write("notes/small.md", "small\n");
    a.write("assets/video.mov", vec![7u8; 5000]);
    let report = a.sync();
    assert_eq!(report.skipped_large_files, [("assets/video.mov".to_owned(), 5000)]);
    assert_eq!(a.committed().iter().map(|(p, _)| p.as_str()).collect::<Vec<_>>(), ["notes/small.md"]);
    // It is still there, still skipped, and never committed.
    let report = a.sync();
    assert!(report.committed.is_none());
    assert_eq!(report.skipped_large_files.len(), 1);
    assert!(a.exists("assets/video.mov"));
}

#[test]
fn ignored_and_excluded_paths_are_never_committed() {
    let world = World::new();
    let mut a = world.first_device("a");
    a.syncer = Syncer::new(a.repo().reopen().unwrap(), Config { exclude: vec![".reflect/".into(), "local.txt".into()], ..Config::default() });
    a.write(".gitignore", "*.tmp\n");
    a.write("scratch.tmp", "ignored\n");
    a.write(".reflect/index.sqlite", "an index\n");
    a.write("local.txt", "this device only\n");
    a.write("notes/kept.md", "kept\n");
    a.sync();
    assert_eq!(a.committed().iter().map(|(p, _)| p.as_str()).collect::<Vec<_>>(), [".gitignore", "notes/kept.md"]);
}

#[test]
fn a_snapshot_reads_the_working_tree_and_moves_nothing() {
    let world = World::new();
    let (a, _b) = world.pair(&[("notes/one.md", "one\n"), ("notes/two.md", "two\n")]);
    let repo = a.repo();
    let head = repo.head();
    let clean = repo.snapshot(&SnapshotOptions::default()).unwrap();
    assert_eq!(Some(clean.tree), repo.head_tree().unwrap());

    a.write("notes/one.md", "one, edited\n");
    a.write("notes/new/deep.md", "new\n");
    a.delete("notes/two.md");
    let dirty = repo.snapshot(&SnapshotOptions::default()).unwrap();
    assert_ne!(dirty.tree, clean.tree);
    assert_eq!(repo.head(), head, "a snapshot is not a commit");
    let changes = repo.changes(Some(clean.tree), Some(dirty.tree), false).unwrap();
    let summary: Vec<_> = changes.iter().map(|c| (c.path.as_str(), c.kind())).collect();
    use prism_sync::ChangeKind::*;
    assert_eq!(summary, [("notes/new/deep.md", Added), ("notes/one.md", Modified), ("notes/two.md", Deleted)]);
    assert_eq!(repo.read(dirty.tree, "notes/one.md").unwrap().as_deref(), Some(&b"one, edited\n"[..]));
    assert_eq!(repo.read(dirty.tree, "notes/two.md").unwrap(), None);

    // The same files give the same tree; putting them back gives the old one.
    assert_eq!(repo.snapshot(&SnapshotOptions::default()).unwrap().tree, dirty.tree);
    a.write("notes/one.md", "one\n");
    a.write("notes/two.md", "two\n");
    std::fs::remove_dir_all(a.dir.join("notes/new")).unwrap();
    assert_eq!(repo.snapshot(&SnapshotOptions::default()).unwrap().tree, clean.tree);
    // The whole tree, as changes from nothing.
    assert_eq!(repo.changes(None, Some(clean.tree), false).unwrap().len(), 2);
    assert!(repo.changes(Some(clean.tree), Some(clean.tree), false).unwrap().is_empty());
}

#[test]
fn renames_are_found_for_whoever_words_the_commit() {
    let world = World::new();
    let (a, _b) = world.pair(&[("notes/old-name.md", "# A fairly long note\n\nwith enough text in it\nto be recognised again\n")]);
    let before = a.repo().head_tree().unwrap();
    std::fs::rename(a.dir.join("notes/old-name.md"), a.dir.join("notes/new-name.md")).unwrap();
    let after = a.repo().snapshot(&SnapshotOptions::default()).unwrap().tree;
    let changes = a.repo().changes(before, Some(after), true).unwrap();
    assert_eq!(changes.len(), 1);
    assert_eq!(
        (changes[0].path.as_str(), changes[0].renamed_from.as_deref(), changes[0].kind()),
        ("notes/new-name.md", Some("notes/old-name.md"), prism_sync::ChangeKind::Renamed)
    );
    assert_eq!(a.repo().changes(before, Some(after), false).unwrap().len(), 2);
}

#[test]
fn a_file_edited_while_the_sync_ran_is_merged_not_overwritten() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("notes/live.md", "one\ntwo\nthree\n"), ("notes/clash.md", "start\n"), ("notes/doomed.md", "x\n")]);
    b.write("notes/live.md", "one\ntwo\nthree\nfour from b\n");
    b.write("notes/clash.md", "b's line\n");
    b.delete("notes/doomed.md");
    b.sync();

    // `a` has synced nothing yet, and its user types between the commit
    // and the merge — modelled by applying the incoming tree by hand.
    let repo = a.repo();
    repo.fetch("origin", &Auth::Default).unwrap();
    let from = repo.head_tree().unwrap();
    let theirs = repo.resolve("refs/remotes/origin/main").unwrap();
    a.write("notes/live.md", "ONE typed just now\ntwo\nthree\n");
    a.write("notes/clash.md", "a's line, typed just now\n");
    a.write("notes/doomed.md", "x\nbut I was still writing here\n");
    let applied = repo.apply(from, repo.tree_of(theirs).unwrap(), Default::default()).unwrap();

    assert_eq!(a.read("notes/live.md"), "ONE typed just now\ntwo\nthree\nfour from b\n");
    assert_eq!(a.read("notes/clash.md"), "<<<<<<< this device\na's line, typed just now\n=======\nb's line\n>>>>>>> other device\n");
    assert_eq!(a.read("notes/doomed.md"), "x\nbut I was still writing here\n");
    assert_eq!(applied.conflicted, ["notes/clash.md"]);
    assert_eq!(applied.merged_local_edits, ["notes/clash.md", "notes/doomed.md", "notes/live.md"]);

    // The next cycles carry all of it to the other device.
    converge(&mut a, &mut b);
    assert_eq!(b.read("notes/live.md"), "ONE typed just now\ntwo\nthree\nfour from b\n");
    assert_eq!(b.read("notes/doomed.md"), "x\nbut I was still writing here\n");
}

#[test]
fn three_devices_converge() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("notes/shared.md", "1\n2\n3\n4\n5\n6\n7\n8\n9\n")]);
    let mut c = world.clone_device("c");
    a.write("notes/shared.md", "1 a\n2\n3\n4\n5\n6\n7\n8\n9\n");
    b.write("notes/shared.md", "1\n2\n3\n4\n5 b\n6\n7\n8\n9\n");
    c.write("notes/shared.md", "1\n2\n3\n4\n5\n6\n7\n8\n9 c\n");
    c.write("notes/c.md", "c\n");
    for _ in 0..3 {
        a.sync();
        b.sync();
        c.sync();
    }
    assert_eq!(a.read("notes/shared.md"), "1 a\n2\n3\n4\n5 b\n6\n7\n8\n9 c\n");
    converge(&mut a, &mut b);
    converge(&mut b, &mut c);
    assert_eq!(a.repo().head(), c.repo().head());
}

#[test]
fn the_branch_is_backed_up_before_each_merge() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("n.md", "0\n")]);
    a.syncer = Syncer::new(a.repo().reopen().unwrap(), Config { backups_kept: 2, ..Config::default() });
    let mut heads = Vec::new();
    for round in 1..=4 {
        b.write("n.md", format!("{round}\n"));
        b.sync();
        heads.push(a.repo().head().unwrap());
        a.sync();
        std::thread::sleep(Duration::from_millis(3));
    }
    let backups = a.syncer.backups();
    assert_eq!(backups.len(), 2, "only the newest are kept");
    assert!(backups[0].1 >= backups[1].1);
    assert_eq!(a.repo().resolve(&backups[0].0), Some(heads[3]));
    assert_eq!(a.repo().resolve(&backups[1].0), Some(heads[2]));
}

struct KeepLonger;

impl MergeDriver for KeepLonger {
    fn merge(&self, path: &str, _base: Option<&[u8]>, ours: &[u8], theirs: &[u8]) -> Option<FileMerge> {
        path.ends_with(".longest").then(|| FileMerge { content: if ours.len() >= theirs.len() { ours } else { theirs }.to_vec(), conflicted: false })
    }
}

#[test]
fn a_merge_driver_settles_the_files_it_knows() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("x.longest", "base\n"), ("x.md", "base\n")]);
    b.syncer = Syncer::new(b.repo().reopen().unwrap(), Config::default()).with_merge_driver(KeepLonger);
    a.write("x.longest", "short\n");
    a.write("x.md", "short\n");
    b.write("x.longest", "much longer\n");
    b.write("x.md", "much longer\n");
    a.sync();
    let report = b.sync();
    assert_eq!(report.conflicted, ["x.md"], "only the file no driver knew conflicts");
    assert_eq!(b.read("x.longest"), "much longer\n");
}

#[test]
fn trailing_spaces_do_not_make_a_conflict() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("n.md", "- one\n- two\n- three\n")]);
    // One device only left a space at a line's end; the other rewrote the line.
    a.write("n.md", "- one  \n- two\n- three\n");
    b.write("n.md", "- ONE\n- two\n- three\n");
    a.sync();
    // git's own merge calls that a conflict; ours looks again.
    let report = b.sync();
    assert!(report.conflicted.is_empty(), "{report:?}");
    converge(&mut a, &mut b);
    assert_eq!(a.read("n.md"), "- ONE\n- two\n- three\n");
}

#[test]
fn stale_locks_and_a_detached_head_are_put_right() {
    let world = World::new();
    let (mut a, _b) = world.pair(&[("n.md", "0\n")]);
    a.syncer = Syncer::new(a.repo().reopen().unwrap(), Config { stale_lock_age: Duration::ZERO, ..Config::default() });
    let head = a.repo().head().unwrap();
    std::fs::write(a.repo().git_dir().join("index.lock"), "").unwrap();
    std::fs::write(a.repo().git_dir().join("refs/heads/main.lock"), "").unwrap();
    git2::Repository::open(&a.dir).unwrap().set_head_detached(head).unwrap();
    assert_eq!(a.repo().branch().unwrap(), None);
    std::thread::sleep(Duration::from_millis(5));

    a.write("n.md", "1\n");
    let report = a.sync();
    assert_eq!(report.repairs, ["cleared 2 stale locks", "put HEAD back on main"]);
    assert_eq!(a.repo().branch().unwrap().as_deref(), Some("main"));
    assert!(report.pushed);
    assert!(report.to_string().starts_with("cleared 2 stale locks, put HEAD back on main, committed"));
}

#[test]
fn a_detached_head_no_branch_leads_to_is_left_for_a_person() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("n.md", "0\n")]);
    let old = a.repo().head().unwrap();
    b.write("n.md", "1\n");
    b.sync();
    a.sync();
    // HEAD on an older commit: `main` has gone elsewhere.
    git2::Repository::open(&a.dir).unwrap().set_head_detached(old).unwrap();
    assert!(matches!(a.syncer.sync(Mode::Full), Err(Error::State(_))));
}

#[test]
fn an_operation_another_tool_left_is_abandoned_and_nothing_written_is_lost() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("n.md", "0\n")]);
    b.write("n.md", "b\n");
    b.sync();
    a.write("n.md", "a\n");
    a.syncer.sync(Mode::Push).ok();
    // Someone ran `git merge` by hand and walked away mid-conflict.
    let head = a.repo().head().unwrap();
    std::fs::write(a.repo().git_dir().join("MERGE_HEAD"), format!("{head}\n")).unwrap();
    a.write("notes/unsaved.md", "typed during the mess\n");
    assert_eq!(a.repo().operation_in_progress(), Some("a merge"));

    let report = a.sync();
    assert_eq!(report.repairs, ["left a merge that was never finished"]);
    assert!(a.repo().operation_in_progress().is_none());
    assert_eq!(a.read("notes/unsaved.md"), "typed during the mess\n");
    converge(&mut a, &mut b);
    assert_eq!(b.read("notes/unsaved.md"), "typed during the mess\n");
}

#[test]
fn a_cycle_asked_to_stop_stops_at_a_checkpoint_and_keeps_its_commit() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("n.md", "0\n")]);
    a.write("n.md", "1\n");
    // Stop from a describer, which runs mid-cycle, while committing.
    struct StopWhileDescribing(prism_sync::StopHandle);
    impl prism_sync::Describe for StopWhileDescribing {
        fn describe(&self, _: &prism_sync::Pending<'_>) -> String {
            self.0.stop();
            "Committed, then stopped".into()
        }
    }
    let handle = prism_sync::StopHandle::default();
    a.syncer = Syncer::new(a.repo().reopen().unwrap(), Config::default()).with_stop_handle(handle.clone()).with_describer(StopWhileDescribing(handle));
    assert!(matches!(a.syncer.sync(Mode::Full), Err(Error::Stopped)));
    assert_eq!(a.head_message(), "Committed, then stopped");
    assert!(b.sync().is_quiet(), "nothing was pushed");
    // The next cycle goes on from there.
    a.syncer = Syncer::new(a.repo().reopen().unwrap(), Config::default());
    converge(&mut a, &mut b);
    assert_eq!(b.read("n.md"), "1\n");
}

#[test]
fn executable_bits_and_nested_directories_travel() {
    let world = World::new();
    let (mut a, mut b) = world.pair(&[("n.md", "0\n")]);
    a.write("scripts/deep/er/run.sh", "#!/bin/sh\n");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(a.dir.join("scripts/deep/er/run.sh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    converge(&mut a, &mut b);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_ne!(std::fs::metadata(b.dir.join("scripts/deep/er/run.sh")).unwrap().permissions().mode() & 0o111, 0);
    }
    // Deleting the only file removes its emptied directories on the other side.
    a.delete("scripts/deep/er/run.sh");
    converge(&mut a, &mut b);
    assert!(!b.exists("scripts"));
}

#[test]
fn opening_what_is_not_a_working_tree_fails_plainly() {
    let world = World::new();
    assert!(Repository::open(&world.remote).is_err());
    assert!(Repository::open(Path::new("/nonexistent")).is_err());
    assert!(Repository::clone("/nonexistent/remote.git", world.root.join("x"), &Auth::Default).is_err());
}

#[test]
fn a_snapshot_of_the_paths_that_changed_is_the_snapshot_of_everything() {
    let dir = tempfile::tempdir().unwrap();
    let dir = dir.path();
    let repo = Repository::init(dir, "main").unwrap();
    let write = |path: &str, content: &[u8]| {
        std::fs::create_dir_all(dir.join(path).parent().unwrap()).unwrap();
        std::fs::write(dir.join(path), content).unwrap();
    };
    let options = SnapshotOptions { max_file_bytes: Some(1000), exclude: vec!["scratch/".into()], leave_index: false };
    let full = || repo.snapshot(&options).unwrap();
    let paths = |paths: &[&str]| paths.iter().map(|path| (*path).to_owned()).collect::<Vec<_>>();
    // From a tree, with the paths written since: the same tree as looking at every file.
    let step = |base: prism_sync::Oid, changed: &[&str]| {
        let quick = repo.snapshot_paths(base, &paths(changed), &options).unwrap().expect("these paths can be told from alone");
        assert_eq!(quick.tree, full().tree, "after {changed:?}");
        quick.tree
    };

    // Before any commit, from the empty tree.
    write(".gitignore", b"*.tmp\nbuild/\n");
    write("notes/a.md", b"# A\n");
    write("notes/b.md", b"# B\n");
    write("daily/2026-10-31.md", b"- day\n");
    let empty = repo.snapshot_paths(full().tree, &[], &options).unwrap().unwrap().tree;
    assert_eq!(empty, full().tree, "nothing changed: the tree it was");
    let mut tree = full().tree;
    repo.commit(tree, "first", &prism_sync::Identity::new("t", "t@example.com")).unwrap();

    write("notes/a.md", b"# A\n\nmore\n");
    tree = step(tree, &["notes/a.md"]);
    write("notes/deep/er/c.md", b"# C\n");
    write("assets/x.png", b"PNG");
    tree = step(tree, &["notes/deep/er/c.md", "assets/x.png", "notes/deep/er/c.md"]);
    // Deleted; and the last file of a folder, which takes the folder with it.
    std::fs::remove_file(dir.join("notes/b.md")).unwrap();
    std::fs::remove_file(dir.join("notes/deep/er/c.md")).unwrap();
    tree = step(tree, &["notes/b.md", "notes/deep/er/c.md", "notes/never/was.md"]);
    // Ignored, excluded and too large: left out, as a snapshot leaves them — the large one said so.
    write("notes/draft.tmp", b"x");
    write("build/out.md", b"x");
    write("scratch/s.md", b"x");
    write("assets/video.mov", &[0u8; 2000]);
    tree = step(tree, &["notes/draft.tmp", "build/out.md", "scratch/s.md", "assets/video.mov"]);
    assert_eq!(full().skipped, [("assets/video.mov".to_owned(), 2000)]);
    let quick = repo.snapshot_paths(tree, &paths(&["assets/video.mov"]), &options).unwrap().unwrap();
    assert_eq!(quick.skipped, full().skipped, "of the paths given, those left out are said");
    // A file written back as it was: the tree it was.
    write("notes/a.md", b"# A\n");
    write("notes/a.md", b"# A\n\nmore\n");
    assert_eq!(step(tree, &["notes/a.md"]), tree);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir.join("notes/a.md"), std::fs::Permissions::from_mode(0o755)).unwrap();
        tree = step(tree, &["notes/a.md"]);
    }

    // What cannot be told from the paths alone is said to be so.
    write(".gitignore", b"*.md\n");
    assert!(repo.snapshot_paths(tree, &paths(&[".gitignore"]), &options).unwrap().is_none());
    assert!(repo.snapshot_paths(tree, &paths(&["notes"]), &options).unwrap().is_none(), "a directory");
    assert!(repo.snapshot_paths(tree, &paths(&[".git/config"]), &options).unwrap().is_none());
    // Nothing was moved or staged along the way.
    assert_eq!(repo.recent_commits("HEAD", 5).unwrap().len(), 1);
}
