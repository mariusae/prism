//! The repository: the few git operations a sync is made of.
//!
//! [`Repository`] wraps libgit2 and narrows it to what the engine needs,
//! each operation whole and safe on its own:
//!
//! - **[`snapshot`](Repository::snapshot)** — the working tree, as a git
//!   tree, without touching the index or HEAD. A snapshot is a content
//!   hash of everything in the graph: commits are made from snapshots, and
//!   indices are keyed by them (see `prism-index`).
//! - **[`changes`](Repository::changes)** — what differs between two
//!   trees, in time proportional to the difference.
//! - **[`commit`](Repository::commit)** — a snapshot made a commit.
//! - **[`apply`](Repository::apply)** — the working tree moved from one
//!   tree to another, merging rather than overwriting anything edited
//!   since the snapshot.
//! - **[`fetch`](Repository::fetch)** and **[`push`](Repository::push)**.
//!
//! Nothing here leaves the repository in the middle of an operation:
//! merges are computed in memory ([`crate::merge`]) and written as
//! finished commits.
//!
//! A `Repository` is `Send` but not `Sync`; open one handle per thread
//! with [`reopen`](Repository::reopen). libgit2 and git's own locking make
//! several handles on one repository safe.

use crate::auth::Auth;
use crate::error::{Error, Result};
use crate::textmerge::{self, Labels};
use git2::{ErrorCode, IndexEntry, IndexTime, ObjectType, StatusOptions};
use std::path::{Path, PathBuf};

pub use git2::Oid;

const MODE_FILE: u32 = 0o100644;
const MODE_EXECUTABLE: u32 = 0o100755;
const MODE_LINK: u32 = 0o120000;
const MODE_COMMIT: u32 = 0o160000;

/// A git repository with a working tree.
pub struct Repository {
    git: git2::Repository,
}

/// A file as a tree holds it: its content's hash, and its mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    pub id: Oid,
    pub mode: u32,
}

/// One path that differs between two trees.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Change {
    /// The path, from the repository's top, `/`-separated.
    pub path: String,
    /// The file before; `None` when it was added.
    pub old: Option<Entry>,
    /// The file after; `None` when it was deleted.
    pub new: Option<Entry>,
    /// Where the file was, when it was found to be a rename.
    pub renamed_from: Option<String>,
}

/// What happened to a path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
}

impl Change {
    pub fn kind(&self) -> ChangeKind {
        match (&self.old, &self.new, &self.renamed_from) {
            (_, _, Some(_)) => ChangeKind::Renamed,
            (None, _, _) => ChangeKind::Added,
            (_, None, _) => ChangeKind::Deleted,
            _ => ChangeKind::Modified,
        }
    }
}

/// How [`Repository::snapshot`] reads the working tree.
#[derive(Debug, Clone, Default)]
pub struct SnapshotOptions {
    /// Files at least this large are left out — a remote like GitHub
    /// refuses them, and one video must not stop everything else from
    /// syncing. `None`: no limit.
    pub max_file_bytes: Option<u64>,
    /// Paths (a file, or a directory with its `/`) never snapshotted, on
    /// top of what `.gitignore` leaves out.
    pub exclude: Vec<String>,
    /// Leave git's own index file as it is. A snapshot ordinarily
    /// refreshes the index's record of which files are unchanged, which
    /// makes the next one quicker. One taken while another handle may be
    /// committing must not: two writers of that file would contend.
    pub leave_index: bool,
}

/// The working tree at a moment, as a git tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    /// The tree: equal trees are equal working trees.
    pub tree: Oid,
    /// Files left out for their size, with their sizes. Each stays as it
    /// was in HEAD — absent, when it was never committed.
    pub skipped: Vec<(String, u64)>,
}

/// How a push ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PushOutcome {
    Pushed,
    /// The remote has commits this repository lacks: fetch, merge, retry.
    Behind,
    /// The remote said no for another reason.
    Rejected(String),
}

/// What [`Repository::apply`] did to the working tree.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Applied {
    /// Every path whose file changed on disk.
    pub written: Vec<String>,
    /// Paths that had been edited since the snapshot, where the edit and
    /// the incoming change were merged in the file.
    pub merged_local_edits: Vec<String>,
    /// Of those, the ones left with conflict markers (or, for a binary
    /// file, a conflict copy beside them).
    pub conflicted: Vec<String>,
}

/// A commit, as a history lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitSummary {
    pub id: Oid,
    /// Seconds since the Unix epoch.
    pub time: i64,
    pub message: String,
}

/// One path of a tree to set to a file — its content and mode — or to
/// take out: the path as its parts, from the tree it is asked of.
type Edit<'a> = (&'a [&'a str], Option<(Oid, u32)>);

/// A commit as a walk of history meets it: when it was made, its tree,
/// and the trees of its parents.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitNode {
    pub id: Oid,
    /// Seconds since the Unix epoch.
    pub time: i64,
    pub tree: Oid,
    /// The parents' trees: none for a first commit, two for a merge.
    pub parent_trees: Vec<Oid>,
}

impl Repository {
    // --- Opening -----------------------------------------------------------

    /// Opens the repository whose working tree is at `path`.
    pub fn open(path: impl AsRef<Path>) -> Result<Repository> {
        let git = git2::Repository::open(path.as_ref())?;
        if git.is_bare() {
            return Err(Error::State("the repository has no working tree".into()));
        }
        Ok(Repository { git })
    }

    /// Makes a new repository at `path`, its first branch named `branch`.
    pub fn init(path: impl AsRef<Path>, branch: &str) -> Result<Repository> {
        let mut options = git2::RepositoryInitOptions::new();
        options.initial_head(branch).mkpath(true);
        Ok(Repository { git: git2::Repository::init_opts(path.as_ref(), &options)? })
    }

    /// Makes a bare repository at `path` — one with no working tree, to
    /// be pushed to: a remote on a disk, or a test's stand-in for GitHub.
    pub fn init_bare(path: impl AsRef<Path>, branch: &str) -> Result<()> {
        let mut options = git2::RepositoryInitOptions::new();
        options.initial_head(branch).mkpath(true).bare(true);
        git2::Repository::init_opts(path.as_ref(), &options)?;
        Ok(())
    }

    /// Clones `url` into `path`, with all of its history.
    pub fn clone(url: &str, path: impl AsRef<Path>, auth: &Auth) -> Result<Repository> {
        let mut fetch = git2::FetchOptions::new();
        fetch.remote_callbacks(auth.callbacks());
        let git = git2::build::RepoBuilder::new().fetch_options(fetch).clone(url, path.as_ref()).map_err(|e| auth.explain(e, Error::Fetch))?;
        Ok(Repository { git })
    }

    /// Another handle on the same repository, for another thread.
    pub fn reopen(&self) -> Result<Repository> {
        Repository::open(self.workdir())
    }

    /// The top of the working tree.
    pub fn workdir(&self) -> &Path {
        // Checked at open: never bare.
        self.git.workdir().unwrap_or_else(|| self.git.path())
    }

    /// The repository's own directory: `.git`.
    pub fn git_dir(&self) -> &Path {
        self.git.path()
    }

    // --- Where things stand ------------------------------------------------

    /// The commit HEAD is at, or `None` before the first.
    pub fn head(&self) -> Option<Oid> {
        self.git.head().ok()?.target()
    }

    /// The tree of the commit HEAD is at.
    pub fn head_tree(&self) -> Result<Option<Oid>> {
        self.head().map(|id| self.tree_of(id)).transpose()
    }

    /// The branch checked out, or `None` on a detached HEAD. Before the
    /// first commit, the branch the first commit will make.
    pub fn branch(&self) -> Result<Option<String>> {
        let head = self.git.find_reference("HEAD")?;
        Ok(head.symbolic_target().and_then(|target| target.strip_prefix("refs/heads/")).map(str::to_owned))
    }

    /// A commit's tree.
    pub fn tree_of(&self, commit: Oid) -> Result<Oid> {
        Ok(self.git.find_commit(commit)?.tree_id())
    }

    /// The commit a reference names, if it names one.
    pub fn resolve(&self, reference: &str) -> Option<Oid> {
        self.git.refname_to_id(reference).ok()
    }

    /// Whether an object is in the repository.
    pub fn contains(&self, id: Oid) -> bool {
        self.git.odb().map(|odb| odb.exists(id)).unwrap_or(false)
    }

    /// What another tool left the repository in the middle of — "a merge",
    /// "a rebase" — or `None` when it is in the middle of nothing.
    pub fn operation_in_progress(&self) -> Option<&'static str> {
        use git2::RepositoryState::*;
        match self.git.state() {
            Clean => None,
            Merge => Some("a merge"),
            Revert | RevertSequence => Some("a revert"),
            CherryPick | CherryPickSequence => Some("a cherry-pick"),
            Bisect => Some("a bisect"),
            Rebase | RebaseInteractive | RebaseMerge => Some("a rebase"),
            ApplyMailbox | ApplyMailboxOrRebase => Some("applying patches"),
        }
    }

    /// The newest commits a reference leads to, newest first.
    pub fn recent_commits(&self, reference: &str, limit: usize) -> Result<Vec<CommitSummary>> {
        let Some(start) = self.resolve(reference) else { return Ok(Vec::new()) };
        let mut walk = self.git.revwalk()?;
        walk.push(start)?;
        let mut commits = Vec::new();
        for id in walk.take(limit) {
            let commit = self.git.find_commit(id?)?;
            commits.push(CommitSummary { id: commit.id(), time: commit.time().seconds(), message: commit.message().unwrap_or("").to_owned() });
        }
        Ok(commits)
    }

    /// The commits `head` leads to that `since` does not — all of them,
    /// for `None` — oldest first, each after its parents. What something
    /// that follows history ingests to catch up.
    pub fn commits_since(&self, head: Oid, since: Option<Oid>) -> Result<Vec<CommitNode>> {
        let mut walk = self.git.revwalk()?;
        walk.set_sorting(git2::Sort::TOPOLOGICAL | git2::Sort::REVERSE)?;
        walk.push(head)?;
        if let Some(since) = since {
            walk.hide(since)?;
        }
        let mut commits = Vec::new();
        for id in walk {
            let commit = self.git.find_commit(id?)?;
            let parent_trees = commit.parents().map(|parent| parent.tree_id()).collect();
            commits.push(CommitNode { id: commit.id(), time: commit.time().seconds(), tree: commit.tree_id(), parent_trees });
        }
        Ok(commits)
    }

    /// How many commits `local` has that `other` lacks, and the reverse.
    pub fn ahead_behind(&self, local: Oid, other: Oid) -> Result<(usize, usize)> {
        Ok(self.git.graph_ahead_behind(local, other)?)
    }

    /// Whether a commit is the other, or one of its ancestors.
    pub fn is_ancestor(&self, ancestor: Oid, descendant: Oid) -> bool {
        ancestor == descendant || self.git.graph_descendant_of(descendant, ancestor).unwrap_or(false)
    }

    // --- Trees and blobs ---------------------------------------------------

    /// A blob's bytes.
    pub fn blob(&self, id: Oid) -> Result<Vec<u8>> {
        Ok(self.git.find_blob(id)?.content().to_vec())
    }

    /// The entry at a path in a tree, if there is a file there.
    pub fn entry(&self, tree: Oid, path: &str) -> Result<Option<Entry>> {
        match self.git.find_tree(tree)?.get_path(Path::new(path)) {
            Ok(entry) if entry.kind() == Some(ObjectType::Blob) => Ok(Some(Entry { id: entry.id(), mode: entry.filemode() as u32 })),
            Ok(_) => Ok(None),
            Err(e) if e.code() == ErrorCode::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// The bytes of the file at a path in a tree.
    pub fn read(&self, tree: Oid, path: &str) -> Result<Option<Vec<u8>>> {
        self.entry(tree, path)?.map(|entry| self.blob(entry.id)).transpose()
    }

    /// Every file in a tree, in path order.
    pub fn files(&self, tree: Oid) -> Result<Vec<(String, Entry)>> {
        Ok(self.changes(None, Some(tree), false)?.into_iter().filter_map(|c| Some((c.path, c.new?))).collect())
    }

    /// What differs between two trees, in path order. `None` stands for
    /// the empty tree, so `changes(None, Some(tree))` lists a whole tree
    /// as additions. With `renames`, a file deleted and added again under
    /// another name, mostly the same, is reported once, as a rename.
    ///
    /// The cost is proportional to what differs: subtrees with the same
    /// hash are never opened.
    pub fn changes(&self, from: Option<Oid>, to: Option<Oid>, renames: bool) -> Result<Vec<Change>> {
        if from == to {
            return Ok(Vec::new());
        }
        let old = from.map(|id| self.git.find_tree(id)).transpose()?;
        let new = to.map(|id| self.git.find_tree(id)).transpose()?;
        let mut options = git2::DiffOptions::new();
        options.ignore_submodules(true).skip_binary_check(true);
        let mut diff = self.git.diff_tree_to_tree(old.as_ref(), new.as_ref(), Some(&mut options))?;
        if renames {
            diff.find_similar(Some(git2::DiffFindOptions::new().renames(true)))?;
        }
        let entry = |file: git2::DiffFile<'_>| {
            let mode = u32::from(file.mode());
            (!file.id().is_zero() && mode != MODE_COMMIT && mode != 0).then_some(Entry { id: file.id(), mode })
        };
        let mut changes = Vec::new();
        for delta in diff.deltas() {
            let (old_file, new_file) = (delta.old_file(), delta.new_file());
            let path_of = |file: &git2::DiffFile<'_>| file.path().and_then(Path::to_str).map(str::to_owned);
            let Some(path) = path_of(&new_file).or_else(|| path_of(&old_file)) else { continue };
            let renamed_from = (delta.status() == git2::Delta::Renamed).then(|| path_of(&old_file)).flatten();
            let (old, new) = (entry(old_file), entry(new_file));
            if old.is_none() && new.is_none() {
                continue;
            }
            changes.push(Change { path, old, new, renamed_from });
        }
        Ok(changes)
    }

    // --- The working tree --------------------------------------------------

    /// The working tree as a git tree: HEAD's tree with every file that
    /// was added, changed or deleted since. `.gitignore` is honoured.
    ///
    /// Changed files' contents are written to the object store; the index
    /// and HEAD are not touched, so this can be called at any time — on
    /// every keystroke's save, to bring indices up to date — and the commit
    /// that follows reuses the same objects.
    pub fn snapshot(&self, options: &SnapshotOptions) -> Result<Snapshot> {
        let mut index = git2::Index::new()?;
        if let Some(tree) = self.head_tree()? {
            index.read_tree(&self.git.find_tree(tree)?)?;
        }
        let mut status = StatusOptions::new();
        status
            .include_untracked(true)
            .recurse_untracked_dirs(true)
            .include_ignored(false)
            .exclude_submodules(true)
            .renames_head_to_index(false)
            .renames_index_to_workdir(false)
            .update_index(!options.leave_index);
        let workdir = self.workdir().to_owned();
        let mut skipped = Vec::new();
        for entry in self.git.statuses(Some(&mut status))?.iter() {
            let Some(path) = entry.path() else { continue };
            if entry.status().is_empty() || entry.status() == git2::Status::IGNORED || is_excluded(path, &options.exclude) {
                continue;
            }
            let file = workdir.join(path);
            match std::fs::symlink_metadata(&file) {
                Ok(meta) if meta.file_type().is_symlink() => {
                    let target = std::fs::read_link(&file).map_err(Error::io(format!("reading the link {path}")))?;
                    let id = self.git.blob(target.to_string_lossy().as_bytes())?;
                    index.add(&index_entry(path, id, MODE_LINK))?;
                }
                Ok(meta) if meta.is_file() => {
                    if options.max_file_bytes.is_some_and(|max| meta.len() >= max) {
                        skipped.push((path.to_owned(), meta.len()));
                        continue;
                    }
                    let id = self.git.blob_path(&file)?;
                    index.add(&index_entry(path, id, file_mode(&meta)))?;
                }
                // A directory here is another repository's; not ours to take.
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    // Gone from the working tree. (`remove` of a path not
                    // in the index is no error.)
                    index.remove(Path::new(path), 0)?;
                }
                Err(e) => return Err(Error::io(format!("reading {path}"))(e)),
            }
        }
        Ok(Snapshot { tree: index.write_tree_to(&self.git)?, skipped })
    }

    /// The working tree as a git tree, for one who knows what changed:
    /// `base` as the tree it was, with each of `paths` as it is now on
    /// disk — written, changed, or gone.
    ///
    /// [`snapshot`](Self::snapshot) finds what changed by looking at
    /// every file, which costs what the graph holds. Whoever wrote the
    /// files knows which they were; this costs only them. Given every
    /// path that changed since `base` was the working tree, the tree
    /// answered is the one `snapshot` would answer. (Of the files left
    /// out for their size, only those among `paths` are listed.)
    ///
    /// `None` when that cannot be promised from the paths alone — one is
    /// a directory or a link, or is `.gitignore`, which changes what
    /// every other path means: take a full [`snapshot`](Self::snapshot)
    /// then. Nothing but the object store is written, not even git's
    /// index, so this never contends with a commit under way.
    pub fn snapshot_paths(&self, base: Oid, paths: &[String], options: &SnapshotOptions) -> Result<Option<Snapshot>> {
        let workdir = self.workdir().to_owned();
        let mut edits = Vec::new();
        let mut skipped = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for path in paths {
            if !seen.insert(path) {
                continue;
            }
            let parts: Vec<&str> = path.split('/').collect();
            let rules = matches!(parts.last(), Some(&".gitignore") | Some(&".gitattributes") | Some(&".gitmodules"));
            if rules || parts.iter().any(|part| part.is_empty() || *part == ".git" || *part == "." || *part == "..") {
                return Ok(None);
            }
            if is_excluded(path, &options.exclude) {
                continue;
            }
            let file = workdir.join(path);
            let entry = match std::fs::symlink_metadata(&file) {
                Ok(meta) if meta.is_file() => {
                    // A file git ignores stays out — unless it is tracked all the same.
                    if self.git.is_path_ignored(Path::new(path))? && self.entry(base, path)?.is_none() {
                        continue;
                    }
                    if options.max_file_bytes.is_some_and(|max| meta.len() >= max) {
                        skipped.push((path.clone(), meta.len()));
                        continue;
                    }
                    Some((self.git.blob_path(&file)?, file_mode(&meta)))
                }
                Ok(_) => return Ok(None),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
                // A path through a file: `a/b` where `a` is no directory.
                Err(e) if e.raw_os_error() == Some(20) => None,
                Err(e) => return Err(Error::io(format!("reading {path}"))(e)),
            };
            edits.push((parts, entry));
        }
        let edits: Vec<Edit<'_>> = edits.iter().map(|(parts, entry): &(Vec<&str>, _)| (parts.as_slice(), *entry)).collect();
        let tree = match self.splice(Some(base), &edits)? {
            Some(tree) => tree,
            None => self.git.treebuilder(None)?.write()?,
        };
        Ok(Some(Snapshot { tree, skipped }))
    }

    /// A tree with some paths set to files, or taken out. Each directory
    /// along those paths is rewritten once, however many of the paths
    /// are in it, and no other is opened. `None` for a tree left with
    /// nothing in it.
    fn splice(&self, tree: Option<Oid>, edits: &[Edit<'_>]) -> Result<Option<Oid>> {
        if edits.is_empty() {
            return Ok(tree);
        }
        let existing = match tree {
            Some(id) => Some(self.git.find_tree(id)?),
            None => None,
        };
        let mut builder = self.git.treebuilder(existing.as_ref())?;
        // What is under each name: the file itself, or paths further down.
        let mut under: std::collections::BTreeMap<&str, Vec<Edit<'_>>> = std::collections::BTreeMap::new();
        for (parts, entry) in edits {
            if let Some((name, rest)) = parts.split_first() {
                under.entry(name).or_default().push((rest, *entry));
            }
        }
        for (name, edits) in under {
            // The last word on the name itself, if any path ends at it.
            let replacement = match edits.iter().rev().find(|(rest, _)| rest.is_empty()) {
                Some((_, entry)) => entry.map(|(id, mode)| (id, mode as i32)),
                None => {
                    let child = builder.get(name)?.filter(|entry| entry.kind() == Some(ObjectType::Tree)).map(|entry| entry.id());
                    // Taking files out of a directory that is not there changes nothing.
                    if child.is_none() && edits.iter().all(|(_, entry)| entry.is_none()) {
                        continue;
                    }
                    self.splice(child, &edits)?.map(|id| (id, 0o040000))
                }
            };
            match replacement {
                Some((id, mode)) => {
                    builder.insert(name, id, mode)?;
                }
                None => {
                    if builder.get(name)?.is_some() {
                        builder.remove(name)?;
                    }
                }
            }
        }
        Ok(if builder.is_empty() { None } else { Some(builder.write()?) })
    }

    /// Commits a tree on the branch checked out, with HEAD as its parent,
    /// and brings the index into line. Returns the new commit.
    ///
    /// The tree is usually a [`snapshot`](Self::snapshot)'s, so the working
    /// tree already matches and is left alone.
    pub fn commit(&self, tree: Oid, message: &str, author: &Identity) -> Result<Oid> {
        let head = self.head();
        let old_tree = self.head_tree()?;
        let id = self.write_commit(tree, message, author, &head.into_iter().collect::<Vec<_>>())?;
        self.move_branch(id, "commit")?;
        self.update_index(&self.changes(old_tree, Some(tree), false)?)?;
        Ok(id)
    }

    /// Writes a commit object; moves nothing.
    pub(crate) fn write_commit(&self, tree: Oid, message: &str, author: &Identity, parents: &[Oid]) -> Result<Oid> {
        let signature = git2::Signature::now(&author.name, &author.email)?;
        let tree = self.git.find_tree(tree)?;
        let parents = parents.iter().map(|id| self.git.find_commit(*id)).collect::<Result<Vec<_>, _>>()?;
        Ok(self.git.commit(None, &signature, &signature, message, &tree, &parents.iter().collect::<Vec<_>>())?)
    }

    /// Points the branch checked out at a commit.
    pub(crate) fn move_branch(&self, commit: Oid, why: &str) -> Result<()> {
        let branch = self.branch()?.ok_or_else(|| Error::State("the repository is on a detached HEAD".into()))?;
        self.git.reference(&format!("refs/heads/{branch}"), commit, true, why)?;
        Ok(())
    }

    /// Makes the index say what the new tree says for the paths that
    /// changed, so that only what differs in the working tree shows as
    /// modified.
    fn update_index(&self, changes: &[Change]) -> Result<()> {
        if changes.is_empty() {
            return Ok(());
        }
        let mut index = self.git.index()?;
        for change in changes {
            match change.new {
                // Stat fields are left empty: git re-checks the file once,
                // then remembers it.
                Some(entry) => index.add(&index_entry(&change.path, entry.id, entry.mode))?,
                None => index.remove(Path::new(&change.path), 0)?,
            }
        }
        index.write()?;
        Ok(())
    }

    /// Moves the working tree from one tree to another: writes each file
    /// that differs between them, and deletes those that are gone.
    ///
    /// The working tree is expected to be at `from` — it was just
    /// snapshotted and committed — but someone may have typed since. A
    /// file found changed is **never overwritten**: what is on disk is
    /// merged with the incoming change, from the file as it was at `from`,
    /// and a conflict is left between markers for the next commit to
    /// carry. A file edited here and deleted there is kept.
    pub fn apply(&self, from: Option<Oid>, to: Oid, labels: Labels<'_>) -> Result<Applied> {
        let changes = self.changes(from, Some(to), false)?;
        let workdir = self.workdir().to_owned();
        let mut applied = Applied::default();
        for change in &changes {
            let file = workdir.join(&change.path);
            let on_disk = read_worktree_file(&file)?;
            let unchanged = match (&on_disk, &change.old) {
                (None, None) => true,
                (Some(bytes), Some(old)) => Oid::hash_object(ObjectType::Blob, bytes)? == old.id,
                _ => false,
            };
            match (&change.new, on_disk) {
                (Some(new), _) if unchanged => {
                    self.write_entry(&file, new)?;
                    applied.written.push(change.path.clone());
                }
                (None, _) if unchanged => {
                    remove_file_and_empty_parents(&file, &workdir)?;
                    applied.written.push(change.path.clone());
                }
                // Edited here since the snapshot, deleted there: kept.
                (None, _) => applied.merged_local_edits.push(change.path.clone()),
                // Deleted here since the snapshot, changed there: theirs.
                (Some(new), None) => {
                    self.write_entry(&file, new)?;
                    applied.written.push(change.path.clone());
                }
                (Some(new), Some(local)) => {
                    let theirs = self.blob(new.id)?;
                    if local == theirs {
                        continue;
                    }
                    let base = change.old.map(|old| self.blob(old.id)).transpose()?.unwrap_or_default();
                    match textmerge::merge_bytes(&base, &local, &theirs, labels) {
                        Some(merged) => {
                            write_atomically(&file, merged.text.as_bytes())?;
                            if merged.conflicted {
                                applied.conflicted.push(change.path.clone());
                            }
                        }
                        None => {
                            // Binary: ours stays, theirs goes beside it.
                            let copy = crate::conflict::copy_path(&change.path);
                            write_atomically(&workdir.join(&copy), &theirs)?;
                            applied.written.push(copy.clone());
                            applied.conflicted.extend([change.path.clone(), copy]);
                        }
                    }
                    applied.written.push(change.path.clone());
                    applied.merged_local_edits.push(change.path.clone());
                }
            }
        }
        self.update_index(&changes)?;
        Ok(applied)
    }

    fn write_entry(&self, file: &Path, entry: &Entry) -> Result<()> {
        let content = self.blob(entry.id)?;
        if entry.mode == MODE_LINK {
            return write_link(file, &content);
        }
        write_atomically(file, &content)?;
        set_executable(file, entry.mode == MODE_EXECUTABLE)
    }

    // --- References --------------------------------------------------------

    /// Points a reference at a commit, making it if need be.
    pub fn set_reference(&self, name: &str, commit: Oid) -> Result<()> {
        self.git.reference(name, commit, true, "prism")?;
        Ok(())
    }

    /// The references whose names start with a prefix, sorted.
    pub fn references(&self, prefix: &str) -> Result<Vec<String>> {
        let mut names: Vec<String> = self.git.references_glob(&format!("{prefix}*"))?.filter_map(|r| r.ok()?.name().map(str::to_owned)).collect();
        names.sort();
        Ok(names)
    }

    pub fn delete_reference(&self, name: &str) -> Result<()> {
        match self.git.find_reference(name) {
            Ok(mut reference) => Ok(reference.delete()?),
            Err(e) if e.code() == ErrorCode::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    /// The local branches, each with the commit it is at.
    pub fn branches(&self) -> Result<Vec<(String, Oid)>> {
        let mut branches = Vec::new();
        for branch in self.git.branches(Some(git2::BranchType::Local))? {
            let (branch, _) = branch?;
            if let (Some(name), Some(id)) = (branch.name()?, branch.get().target()) {
                branches.push((name.to_owned(), id));
            }
        }
        branches.sort();
        Ok(branches)
    }

    /// Puts HEAD on a branch, the branch at a commit, and leaves the index
    /// and the working tree as they are.
    pub fn attach_head(&self, branch: &str, commit: Oid) -> Result<()> {
        let name = format!("refs/heads/{branch}");
        self.git.reference(&name, commit, true, "prism: reattach HEAD")?;
        self.git.set_head(&name)?;
        Ok(())
    }

    /// Leaves whatever operation is in progress, as git's own `--abort`
    /// does for the repository's bookkeeping: the working tree is kept as
    /// it is, so nothing written is lost, and the index is put back to
    /// HEAD so the next snapshot sees the working tree for what it is.
    pub fn abandon_operation(&self) -> Result<()> {
        self.git.cleanup_state()?;
        // A rebase leaves its own directories behind.
        for directory in ["rebase-merge", "rebase-apply"] {
            let _ = std::fs::remove_dir_all(self.git_dir().join(directory));
        }
        if let Some(tree) = self.head_tree()? {
            let mut index = self.git.index()?;
            index.read_tree(&self.git.find_tree(tree)?)?;
            index.write()?;
        }
        Ok(())
    }

    // --- Remotes -----------------------------------------------------------

    pub fn has_remote(&self, name: &str) -> bool {
        self.git.find_remote(name).is_ok()
    }

    /// Where a remote is: the address it was added with.
    pub fn remote_url(&self, name: &str) -> Option<String> {
        self.git.find_remote(name).ok()?.url().map(str::to_owned)
    }

    /// Adds a remote, or changes where one is.
    pub fn set_remote(&self, name: &str, url: &str) -> Result<()> {
        if self.has_remote(name) {
            self.git.remote_set_url(name, url)?;
        } else {
            self.git.remote(name, url)?;
        }
        Ok(())
    }

    /// The reference that tracks a branch on a remote.
    pub fn tracking_ref(remote: &str, branch: &str) -> String {
        format!("refs/remotes/{remote}/{branch}")
    }

    /// Fetches a remote's branches.
    pub fn fetch(&self, remote: &str, auth: &Auth) -> Result<()> {
        let mut options = git2::FetchOptions::new();
        options.remote_callbacks(auth.callbacks()).prune(git2::FetchPrune::On).download_tags(git2::AutotagOption::None);
        let mut remote = self.git.find_remote(remote)?;
        remote.fetch(&[] as &[&str], Some(&mut options), None).map_err(|e| auth.explain(e, Error::Fetch))
    }

    /// Pushes a branch to the same branch on a remote. Never forces: a
    /// remote that has moved on answers [`PushOutcome::Behind`].
    pub fn push(&self, remote: &str, branch: &str, auth: &Auth) -> Result<PushOutcome> {
        let rejection = std::cell::RefCell::new(None::<String>);
        let mut callbacks = auth.callbacks();
        callbacks.push_update_reference(|_, status| {
            if let Some(status) = status {
                *rejection.borrow_mut() = Some(status.to_owned());
            }
            Ok(())
        });
        let mut options = git2::PushOptions::new();
        options.remote_callbacks(callbacks);
        let refspec = format!("refs/heads/{branch}:refs/heads/{branch}");
        let mut git_remote = self.git.find_remote(remote)?;
        let result = git_remote.push(&[&refspec], Some(&mut options));
        drop(options);
        let is_behind = |message: &str| {
            let message = message.to_lowercase();
            ["fast-forward", "fastforward", "fetch first", "stale", "behind"].iter().any(|hint| message.contains(hint))
        };
        match (result, rejection.into_inner()) {
            (Ok(()), None) => {
                // The remote now has what we have.
                if let Some(head) = self.resolve(&format!("refs/heads/{branch}")) {
                    self.set_reference(&Self::tracking_ref(remote, branch), head)?;
                }
                Ok(PushOutcome::Pushed)
            }
            (Ok(()), Some(message)) if is_behind(&message) => Ok(PushOutcome::Behind),
            (Ok(()), Some(message)) => Ok(PushOutcome::Rejected(message)),
            (Err(e), _) if e.code() == ErrorCode::NotFastForward || is_behind(e.message()) => Ok(PushOutcome::Behind),
            (Err(e), _) => Err(auth.explain(e, Error::Push)),
        }
    }

    /// The name and address git is configured to commit as, if both are set.
    pub fn configured_identity(&self) -> Option<Identity> {
        let config = self.git.config().ok()?;
        Some(Identity { name: config.get_string("user.name").ok()?, email: config.get_string("user.email").ok()? })
    }

    pub(crate) fn git(&self) -> &git2::Repository {
        &self.git
    }
}

/// Who commits are by.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    pub name: String,
    pub email: String,
}

impl Identity {
    pub fn new(name: impl Into<String>, email: impl Into<String>) -> Identity {
        Identity { name: name.into(), email: email.into() }
    }
}

fn is_excluded(path: &str, exclude: &[String]) -> bool {
    exclude.iter().any(|rule| match rule.strip_suffix('/') {
        Some(directory) => path.strip_prefix(directory).is_some_and(|rest| rest.starts_with('/')),
        None => path == rule,
    })
}

pub(crate) fn index_entry(path: &str, id: Oid, mode: u32) -> IndexEntry {
    IndexEntry {
        ctime: IndexTime::new(0, 0),
        mtime: IndexTime::new(0, 0),
        dev: 0,
        ino: 0,
        mode,
        uid: 0,
        gid: 0,
        file_size: 0,
        id,
        flags: 0,
        flags_extended: 0,
        path: path.as_bytes().to_vec(),
    }
}

#[cfg(unix)]
fn file_mode(meta: &std::fs::Metadata) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    if meta.permissions().mode() & 0o111 != 0 {
        MODE_EXECUTABLE
    } else {
        MODE_FILE
    }
}

#[cfg(not(unix))]
fn file_mode(_: &std::fs::Metadata) -> u32 {
    MODE_FILE
}

#[cfg(unix)]
fn set_executable(file: &Path, executable: bool) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mode = if executable { 0o755 } else { 0o644 };
    std::fs::set_permissions(file, std::fs::Permissions::from_mode(mode)).map_err(Error::io(format!("setting permissions on {}", file.display())))
}

#[cfg(not(unix))]
fn set_executable(_: &Path, _: bool) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn write_link(file: &Path, target: &[u8]) -> Result<()> {
    let context = || format!("writing the link {}", file.display());
    if let Some(parent) = file.parent() {
        std::fs::create_dir_all(parent).map_err(Error::io(context()))?;
    }
    let _ = std::fs::remove_file(file);
    std::os::unix::fs::symlink(String::from_utf8_lossy(target).as_ref(), file).map_err(Error::io(context()))
}

#[cfg(not(unix))]
fn write_link(file: &Path, target: &[u8]) -> Result<()> {
    write_atomically(file, target)
}

/// A regular file's bytes; `None` when there is no file there.
fn read_worktree_file(file: &Path) -> Result<Option<Vec<u8>>> {
    match std::fs::symlink_metadata(file) {
        Ok(meta) if meta.file_type().is_symlink() => Ok(std::fs::read_link(file).ok().map(|t| t.to_string_lossy().into_owned().into_bytes())),
        Ok(meta) if meta.is_file() => std::fs::read(file).map(Some).map_err(Error::io(format!("reading {}", file.display()))),
        Ok(_) => Ok(None),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(Error::io(format!("reading {}", file.display()))(e)),
    }
}

/// Writes a file whole or not at all: to a temporary beside it, then
/// renamed over it, so a reader never sees half of it.
pub(crate) fn write_atomically(file: &Path, content: &[u8]) -> Result<()> {
    let context = || format!("writing {}", file.display());
    let parent = file.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent).map_err(Error::io(context()))?;
    let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let temporary: PathBuf = parent.join(format!(".{name}.prism-{}", std::process::id()));
    std::fs::write(&temporary, content).map_err(Error::io(context()))?;
    std::fs::rename(&temporary, file).map_err(|e| {
        let _ = std::fs::remove_file(&temporary);
        Error::io(context())(e)
    })
}

fn remove_file_and_empty_parents(file: &Path, stop_at: &Path) -> Result<()> {
    match std::fs::remove_file(file) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(Error::io(format!("deleting {}", file.display()))(e)),
    }
    let mut directory = file.parent();
    while let Some(dir) = directory.filter(|d| *d != stop_at && d.starts_with(stop_at)) {
        // Fails, and stops the walk, at the first directory with anything in it.
        if std::fs::remove_dir(dir).is_err() {
            break;
        }
        directory = dir.parent();
    }
    Ok(())
}
