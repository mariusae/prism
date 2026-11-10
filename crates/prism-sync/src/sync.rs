//! The sync cycle.
//!
//! One cycle of [`Syncer::sync`]:
//!
//! 1. **Repair** — put right what a crash or a killed process can leave:
//!    stale locks, an operation in the middle, HEAD off its branch.
//! 2. **Commit** — snapshot the working tree; if it differs from HEAD,
//!    commit it.
//! 3. **Fetch and merge** (a [`Mode::Full`] cycle) — take in what other
//!    devices pushed. Fast-forward when nothing was written here; else a
//!    merge that always finishes ([`crate::merge`]).
//! 4. **Push** — and when another device got there first, fetch and merge
//!    again, up to [`Config::max_push_attempts`] times.
//!
//! The rules are fixed and the same on every device, so two devices that
//! follow them converge. Three invariants hold at every step:
//!
//! - **Nothing written is lost.** Everything is committed before anything
//!   is merged; a merge keeps both sides of a conflict; a file edited
//!   while the cycle ran is merged with, never overwritten; and the branch
//!   as it was before each merge is kept under `refs/prism/backups/`.
//! - **The repository is never left mid-operation.** Merges are computed
//!   in memory and land as finished commits. A cycle can be interrupted
//!   anywhere — or [stopped](StopHandle) at a checkpoint — and the next
//!   one goes on.
//! - **Nothing is forced.** A push never overwrites the remote.

use crate::auth::Auth;
use crate::error::{Error, Result};
use crate::merge::{merge_commits, MergeDriver};
use crate::repo::{Change, Identity, Oid, PushOutcome, Repository, SnapshotOptions};
use crate::textmerge::Labels;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

/// A cycle's reach.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Commit and push what was written, without asking the remote for
    /// anything unless it has moved on. What runs after typing stops.
    Push,
    /// Also fetch and merge what other devices wrote. What runs at
    /// launch, on coming to the front, and when the remote says it moved.
    Full,
}

/// How a sync is to behave.
#[derive(Debug, Clone)]
pub struct Config {
    /// The remote synced with.
    pub remote: String,
    /// Who commits are by. `None`: git's configured `user.name` and
    /// `user.email`, else a plain default.
    pub identity: Option<Identity>,
    /// This device's name, noted in each commit's message as a
    /// `Device:` trailer, to tell which device wrote what.
    pub device: Option<String>,
    /// Files this large are not committed: a remote like GitHub refuses
    /// them, and one video must not stop the backup of everything else.
    pub max_file_bytes: u64,
    /// Paths never committed, beyond `.gitignore`: a file, or a directory
    /// with its `/`.
    pub exclude: Vec<String>,
    /// How many times a push turned away is tried again in one cycle.
    pub max_push_attempts: usize,
    /// How many backups of the branch, from before merges, are kept.
    pub backups_kept: usize,
    /// A git lock file older than this is left over from a process that
    /// is gone, and is removed.
    pub stale_lock_age: Duration,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            remote: "origin".into(),
            identity: None,
            device: None,
            max_file_bytes: 95 * 1024 * 1024,
            exclude: Vec::new(),
            max_push_attempts: 3,
            backups_kept: 30,
            stale_lock_age: Duration::from_secs(90),
        }
    }
}

/// Where backups of the branch are kept: references never pushed.
pub const BACKUP_PREFIX: &str = "refs/prism/backups/";

/// The trailer naming the device that made a commit.
pub const DEVICE_TRAILER: &str = "Device: ";

/// The device a commit's message names, if it names one.
pub fn device_in(message: &str) -> Option<&str> {
    message.lines().rev().find_map(|line| line.strip_prefix(DEVICE_TRAILER)).map(str::trim).filter(|d| !d.is_empty())
}

/// How the remote's commits were taken in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MergeKind {
    /// There was nothing to take in.
    #[default]
    UpToDate,
    /// Nothing was written here: the branch moved up to the remote's.
    FastForward,
    Merged,
    /// Merged, with files left for a person to settle.
    MergedWithConflicts,
}

/// What a cycle did.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Report {
    /// What was put right before the cycle began, in words.
    pub repairs: Vec<String>,
    /// The subject of the commit made, if one was.
    pub committed: Option<String>,
    /// How many of the remote's commits were taken in.
    pub pulled: usize,
    pub merge: MergeKind,
    /// Files the cycle wrote in the working tree: what is on screen may
    /// be out of date.
    pub changed: Vec<String>,
    /// Files left with conflict markers, or a conflict copy beside them.
    pub conflicted: Vec<String>,
    /// Files too large to commit, with their sizes.
    pub skipped_large_files: Vec<(String, u64)>,
    pub pushed: bool,
    /// The commit HEAD was at when the cycle ended.
    pub head: Option<Oid>,
    /// How long each step took, in order.
    pub timings: Vec<(&'static str, Duration)>,
}

impl Report {
    /// Whether the cycle did nothing at all.
    pub fn is_quiet(&self) -> bool {
        self.repairs.is_empty() && self.committed.is_none() && self.pulled == 0 && !self.pushed
    }

    pub fn duration(&self) -> Duration {
        self.timings.iter().map(|(_, d)| *d).sum()
    }
}

impl std::fmt::Display for Report {
    /// "committed “Update Atlas”, 2 changes pulled, pushed".
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut parts: Vec<String> = self.repairs.clone();
        if let Some(message) = &self.committed {
            parts.push(format!("committed “{message}”"));
        }
        if self.pulled > 0 {
            let conflicts = if self.merge == MergeKind::MergedWithConflicts { " with conflicts to review" } else { "" };
            parts.push(format!("{} {} pulled{conflicts}", self.pulled, if self.pulled == 1 { "change" } else { "changes" }));
        }
        if self.pushed {
            parts.push("pushed".into());
        }
        if parts.is_empty() {
            parts.push("nothing to do".into());
        }
        f.write_str(&parts.join(", "))
    }
}

/// What a commit is about to hold, for whoever words its message.
pub struct Pending<'a> {
    /// The paths the commit changes, renames found.
    pub changes: &'a [Change],
    repo: &'a Repository,
}

impl Pending<'_> {
    /// A changed file's text as it was before the commit; for a rename,
    /// the text at its old path.
    pub fn old_text(&self, change: &Change) -> Option<String> {
        change.old.and_then(|entry| self.repo.blob(entry.id).ok()).and_then(|bytes| String::from_utf8(bytes).ok())
    }

    /// A changed file's text as the commit has it.
    pub fn new_text(&self, change: &Change) -> Option<String> {
        change.new.and_then(|entry| self.repo.blob(entry.id).ok()).and_then(|bytes| String::from_utf8(bytes).ok())
    }
}

/// Words a commit's subject from what it changes.
pub trait Describe: Send + Sync {
    fn describe(&self, pending: &Pending<'_>) -> String;
}

/// "Update 3 files": the description of an engine that knows nothing of
/// what the files are.
pub struct PlainDescriber;

impl Describe for PlainDescriber {
    fn describe(&self, pending: &Pending<'_>) -> String {
        match pending.changes {
            [one] => format!("Update {}", one.path),
            many => format!("Update {} files", many.len()),
        }
    }
}

/// Asks a cycle under way to stop at its next checkpoint — between steps,
/// never within one — as when a phone takes an app's background time
/// back. What the cycle committed stays; the next cycle goes on.
#[derive(Clone, Default)]
pub struct StopHandle(Arc<AtomicBool>);

impl StopHandle {
    pub fn stop(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

/// Keeps one repository in step with its remote.
pub struct Syncer {
    repo: Repository,
    config: Config,
    auth: Auth,
    driver: Option<Box<dyn MergeDriver>>,
    describer: Box<dyn Describe>,
    stop: StopHandle,
}

impl Syncer {
    pub fn new(repo: Repository, config: Config) -> Syncer {
        Syncer { repo, config, auth: Auth::Default, driver: None, describer: Box::new(PlainDescriber), stop: StopHandle::default() }
    }

    /// How the remote is told who is syncing.
    pub fn with_auth(mut self, auth: Auth) -> Syncer {
        self.auth = auth;
        self
    }

    /// What merges files it knows the form of.
    pub fn with_merge_driver(mut self, driver: impl MergeDriver + 'static) -> Syncer {
        self.driver = Some(Box::new(driver));
        self
    }

    /// What words commit messages.
    pub fn with_describer(mut self, describer: impl Describe + 'static) -> Syncer {
        self.describer = Box::new(describer);
        self
    }

    pub fn repository(&self) -> &Repository {
        &self.repo
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    /// Uses a stop handle made beforehand, for whoever must hold one
    /// before the syncer exists.
    pub fn with_stop_handle(mut self, stop: StopHandle) -> Syncer {
        self.stop = stop;
        self
    }

    /// A handle to stop a cycle from another thread.
    pub fn stop_handle(&self) -> StopHandle {
        self.stop.clone()
    }

    /// One cycle. See the [module docs](self).
    pub fn sync(&mut self, mode: Mode) -> Result<Report> {
        self.stop.0.store(false, Ordering::SeqCst);
        let mut report = Report::default();
        let result = self.cycle(mode, &mut report);
        report.head = self.repo.head();
        result.map(|()| report)
    }

    fn checkpoint(&self) -> Result<()> {
        if self.stop.0.load(Ordering::SeqCst) {
            Err(Error::Stopped)
        } else {
            Ok(())
        }
    }

    fn cycle(&mut self, mode: Mode, report: &mut Report) -> Result<()> {
        fn timed<T>(report: &mut Report, step: &'static str, work: impl FnOnce(&mut Report) -> Result<T>) -> Result<T> {
            let start = Instant::now();
            let result = work(report);
            report.timings.push((step, start.elapsed()));
            result
        }
        timed(report, "checking the repository", |report| {
            report.repairs = self.repair()?;
            Ok(())
        })?;
        let committed = timed(report, "committing", |report| self.commit_all(report))?;
        let remote = self.config.remote.clone();
        if !self.repo.has_remote(&remote) {
            return Ok(()); // the commit is the whole cycle
        }
        let branch = self.branch()?;

        if mode == Mode::Push {
            // Nothing written and nothing waiting: no need to ask the remote.
            if !committed && self.ahead_behind(&branch)?.0 == 0 {
                return Ok(());
            }
        } else {
            self.checkpoint()?;
            timed(report, "fetching", |_| self.repo.fetch(&remote, &self.auth))?;
            self.checkpoint()?;
            let ahead = self.ahead_behind(&branch)?.0;
            let merged = timed(report, "merging", |report| self.merge_remote(&branch, report))?;
            if !committed && ahead == 0 && matches!(merged, MergeKind::UpToDate | MergeKind::FastForward) {
                return Ok(());
            }
        }
        for _ in 0..self.config.max_push_attempts.max(1) {
            self.checkpoint()?;
            match timed(report, "pushing", |_| self.repo.push(&remote, &branch, &self.auth))? {
                PushOutcome::Pushed => {
                    report.pushed = true;
                    return Ok(());
                }
                PushOutcome::Rejected(message) => return Err(Error::Rejected(message)),
                PushOutcome::Behind => {
                    // Another device pushed first: take its changes, try again.
                    timed(report, "fetching", |_| self.repo.fetch(&remote, &self.auth))?;
                    timed(report, "merging", |report| self.merge_remote(&branch, report))?;
                }
            }
        }
        Err(Error::Contended)
    }

    // --- Committing --------------------------------------------------------

    /// Commits the working tree if it differs from HEAD. Says whether it did.
    fn commit_all(&self, report: &mut Report) -> Result<bool> {
        self.branch()?;
        let options = SnapshotOptions { max_file_bytes: Some(self.config.max_file_bytes), exclude: self.config.exclude.clone(), leave_index: false };
        let snapshot = self.repo.snapshot(&options)?;
        report.skipped_large_files = snapshot.skipped;
        let head_tree = self.repo.head_tree()?;
        if head_tree == Some(snapshot.tree) {
            return Ok(false);
        }
        let changes = self.repo.changes(head_tree, Some(snapshot.tree), true)?;
        if changes.is_empty() {
            return Ok(false); // a first commit of nothing
        }
        let subject = self.describer.describe(&Pending { changes: &changes, repo: &self.repo });
        self.repo.commit(snapshot.tree, &self.stamped(&subject), &self.identity())?;
        report.committed = Some(subject);
        Ok(true)
    }

    fn stamped(&self, message: &str) -> String {
        match self.config.device.as_deref().map(str::trim).filter(|d| !d.is_empty()) {
            Some(device) => format!("{message}\n\n{DEVICE_TRAILER}{device}"),
            None => message.to_owned(),
        }
    }

    fn identity(&self) -> Identity {
        self.config
            .identity
            .clone()
            .or_else(|| self.repo.configured_identity())
            .unwrap_or_else(|| Identity::new(self.config.device.as_deref().unwrap_or("Prism"), "prism@localhost"))
    }

    fn branch(&self) -> Result<String> {
        self.repo.branch()?.ok_or_else(|| Error::State("the repository is on a detached HEAD; check out a branch first".into()))
    }

    /// How far this branch and the remote's copy of it have gone apart:
    /// commits only here, commits only there.
    fn ahead_behind(&self, branch: &str) -> Result<(usize, usize)> {
        let remote = self.repo.resolve(&Repository::tracking_ref(&self.config.remote, branch));
        match (self.repo.head(), remote) {
            (Some(head), Some(remote)) => self.repo.ahead_behind(head, remote),
            // Never pushed: everything here is ahead.
            (Some(_), None) => Ok((1, 0)),
            (None, Some(_)) => Ok((0, 1)),
            (None, None) => Ok((0, 0)),
        }
    }

    // --- Merging -----------------------------------------------------------

    /// Takes in the remote's copy of the branch. Everything here was
    /// committed first, so nothing unsaved is in the way.
    fn merge_remote(&self, branch: &str, report: &mut Report) -> Result<MergeKind> {
        // A new, empty remote has nothing to merge until the first push.
        let Some(theirs) = self.repo.resolve(&Repository::tracking_ref(&self.config.remote, branch)) else {
            return Ok(MergeKind::UpToDate);
        };
        let ours = self.repo.head();
        let (ahead, behind) = self.ahead_behind(branch)?;
        if behind == 0 {
            return Ok(MergeKind::UpToDate);
        }
        if let Some(ours) = ours {
            self.back_up(ours);
        }
        let our_tree = self.repo.head_tree()?;
        let labels = Labels::default();

        let (kind, commit, tree) = match ours {
            Some(ours) if ahead > 0 => {
                let merged = merge_commits(&self.repo, ours, theirs, self.driver.as_deref(), labels)?;
                let message =
                    if merged.conflicted.is_empty() { "Merge changes from other devices" } else { "Merge changes from other devices (conflicts to review)" };
                let commit = self.repo.write_commit(merged.tree, &self.stamped(message), &self.identity(), &[ours, theirs])?;
                let kind = if merged.conflicted.is_empty() { MergeKind::Merged } else { MergeKind::MergedWithConflicts };
                report.conflicted.extend(merged.conflicted);
                (kind, commit, merged.tree)
            }
            _ => (MergeKind::FastForward, theirs, self.repo.tree_of(theirs)?),
        };
        // The working tree first, then the branch: stopped between the
        // two, the next cycle finds the merged files as plain changes and
        // commits them — whereas a branch moved ahead of its working tree
        // would have the next cycle commit the old files over the new.
        let applied = self.repo.apply(our_tree, tree, labels)?;
        self.repo.move_branch(commit, "prism: merge")?;
        report.changed.extend(applied.written);
        report.conflicted.extend(applied.conflicted);
        report.conflicted.sort();
        report.conflicted.dedup();
        report.pulled += behind;
        report.merge = match (report.merge, kind) {
            (MergeKind::MergedWithConflicts, _) | (_, MergeKind::MergedWithConflicts) => MergeKind::MergedWithConflicts,
            (MergeKind::Merged, _) | (_, MergeKind::Merged) => MergeKind::Merged,
            (_, kind) => kind,
        };
        if !report.conflicted.is_empty() {
            report.merge = MergeKind::MergedWithConflicts;
        }
        Ok(kind)
    }

    // --- Putting things right ----------------------------------------------

    /// Puts right what a crash, a killed process or a system taking an
    /// app's time away can leave. A sync must never stop for good over
    /// something it can put right itself — on a phone there is no `git`
    /// to do it with. Says what it did.
    fn repair(&self) -> Result<Vec<String>> {
        let mut done = Vec::new();
        let removed = remove_stale_locks(self.repo.git_dir(), self.config.stale_lock_age);
        if !removed.is_empty() {
            done.push(format!("cleared {} stale {}", removed.len(), if removed.len() == 1 { "lock" } else { "locks" }));
        }
        if let Some(what) = self.repo.operation_in_progress() {
            // This engine never leaves one; another tool did. It is left
            // as its own `--abort` leaves it, nothing written lost.
            if let Some(head) = self.repo.head() {
                self.back_up(head);
            }
            self.repo.abandon_operation()?;
            if let Some(still) = self.repo.operation_in_progress() {
                return Err(Error::State(format!("the repository is in the middle of {still}, and it could not be left")));
            }
            done.push(format!("left {what} that was never finished"));
        }
        if self.repo.branch()?.is_none() {
            if let Some(head) = self.repo.head() {
                // A branch at HEAD, or one HEAD has gone on from: HEAD is
                // put back on it, nothing else moved. A branch that has
                // gone elsewhere is a person's doing, and theirs to settle.
                let branches = self.repo.branches()?;
                let preferred = |name: &str| (name != "main", name != "master", name.to_owned());
                let mut candidates: Vec<&(String, Oid)> = branches.iter().filter(|(_, at)| self.repo.is_ancestor(*at, head)).collect();
                candidates.sort_by_key(|(name, at)| (*at != head, preferred(name)));
                let Some((name, _)) = candidates.first() else {
                    return Err(Error::State("the repository is on a detached HEAD that no branch leads to; check out a branch first".into()));
                };
                self.back_up(head);
                self.repo.attach_head(name, head)?;
                done.push(format!("put HEAD back on {name}"));
            }
        }
        Ok(done)
    }

    /// Keeps the branch as it is now under a reference of its own, never
    /// pushed: whatever a merge then does can be undone. The oldest beyond
    /// [`Config::backups_kept`] are let go.
    fn back_up(&self, commit: Oid) {
        let millis = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
        // Best effort: a backup that cannot be made must not stop a sync.
        let _ = self.repo.set_reference(&format!("{BACKUP_PREFIX}{millis:013}"), commit);
        if let Ok(all) = self.repo.references(BACKUP_PREFIX) {
            let excess = all.len().saturating_sub(self.config.backups_kept);
            for old in &all[..excess] {
                let _ = self.repo.delete_reference(old);
            }
        }
    }

    /// The backups kept from before merges, newest first: each reference,
    /// and when it was made, in milliseconds since the Unix epoch.
    pub fn backups(&self) -> Vec<(String, u64)> {
        let mut backups: Vec<(String, u64)> = self
            .repo
            .references(BACKUP_PREFIX)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|name| name[BACKUP_PREFIX.len()..].parse().ok().map(|at| (name, at)))
            .collect();
        backups.reverse();
        backups
    }
}

/// Removes the lock files git leaves when it is stopped midway, once they
/// are old enough that no process can still hold them. Says which.
fn remove_stale_locks(git_dir: &std::path::Path, older_than: Duration) -> Vec<String> {
    fn collect(directory: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
        let Ok(entries) = std::fs::read_dir(directory) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                collect(&path, out);
            } else if path.extension().is_some_and(|e| e == "lock") {
                out.push(path);
            }
        }
    }
    let mut candidates: Vec<std::path::PathBuf> =
        ["index.lock", "HEAD.lock", "ORIG_HEAD.lock", "config.lock", "packed-refs.lock", "shallow.lock", "FETCH_HEAD.lock"]
            .iter()
            .map(|name| git_dir.join(name))
            .collect();
    collect(&git_dir.join("refs"), &mut candidates);
    let mut removed = Vec::new();
    for lock in candidates {
        let age = std::fs::metadata(&lock).and_then(|m| m.modified()).ok().and_then(|at| at.elapsed().ok());
        if age.is_some_and(|age| age > older_than) && std::fs::remove_file(&lock).is_ok() {
            removed.push(lock.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default());
        }
    }
    removed
}
