//! When each page was made and last changed, read off git's history.
//!
//! A graph's notes do not say when they were written: a `modified:` line
//! rewritten on every save would be noise in every diff and a conflict in
//! every merge. Git already knows. This keeps, for each page, the time of
//! the first commit that has it and of the last that changed it —
//! incrementally, as every index here is kept: its cursor is the
//! **commit** it was brought up to, and an update ingests only the
//! commits made since.
//!
//! Two refinements:
//!
//! - **A merge changes only what it settled.** A page is counted as
//!   changed by a merge only where it differs from *every* parent; what
//!   one device wrote keeps the time that device wrote it.
//! - **What is not committed yet** has no commit to date it. Those pages
//!   are kept apart, with their files' own times
//!   ([`Indexer::set_unsaved`]), and win over history until they are
//!   committed.
//!
//! # Three tables, one to ask
//!
//! `prism_times` is what history says and `prism_unsaved` what the
//! working tree adds. `prism_dates` is the two put together — the time
//! that *applies* to each page — kept in step with them and indexed, so
//! that "the ten pages changed last" is read off an index, not sorted
//! out of every page. It is what the [`Catalog`](crate::Catalog)'s rows
//! and a query's `sort: modified` read.
//!
//! # A history read apart
//!
//! Reading a long history takes seconds, once. [`Times::history`] does
//! the reading without touching the database, so it can run on a thread
//! of its own while the indices go on being updated;
//! [`Indexer::set_history`] then writes what it found, in a moment.

use crate::{Indexer, Result};
use prism_markup::NoteKind;
use prism_sync::{CommitNode, Oid, Repository};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use std::collections::{BTreeSet, HashMap};

/// The tables, made by the [`Indexer`] and by the catalog that reads them.
pub(crate) const TABLES: &str =
    "CREATE TABLE IF NOT EXISTS prism_times (path TEXT PRIMARY KEY, created INTEGER NOT NULL, modified INTEGER NOT NULL) WITHOUT ROWID;
     CREATE TABLE IF NOT EXISTS prism_unsaved (path TEXT PRIMARY KEY, modified INTEGER NOT NULL) WITHOUT ROWID;
     CREATE TABLE IF NOT EXISTS prism_dates (path TEXT PRIMARY KEY, created INTEGER, modified INTEGER) WITHOUT ROWID;
     CREATE INDEX IF NOT EXISTS prism_dates_modified ON prism_dates (modified);
     CREATE INDEX IF NOT EXISTS prism_dates_created ON prism_dates (created);";

const CURSOR: &str = "times";
const VERSION: u32 = 2;

/// Pages' times, as history has them.
pub struct Times;

/// A whole history, read: each page there is, with when it was first
/// committed and last changed. See [`Times::history`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct History {
    /// The commit read up to.
    pub head: Oid,
    pages: HashMap<String, (i64, i64)>,
}

impl History {
    /// How many pages it dates.
    pub fn len(&self) -> usize {
        self.pages.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pages.is_empty()
    }
}

/// What one commit did to the pages: each path it changed, with whether
/// the commit has the file. For a merge: only what differs from every
/// parent.
fn changed_by(repo: &Repository, commit: &CommitNode) -> Result<HashMap<String, bool>> {
    let mut changed: Option<HashMap<String, bool>> = None;
    let parents: Vec<Option<Oid>> = if commit.parent_trees.is_empty() { vec![None] } else { commit.parent_trees.iter().copied().map(Some).collect() };
    for parent in parents {
        let against: HashMap<String, bool> = repo
            .changes(parent, Some(commit.tree), false)?
            .into_iter()
            .filter(|change| NoteKind::of(&change.path).is_some())
            .map(|change| (change.path, change.new.is_some()))
            .collect();
        changed = Some(match changed {
            None => against,
            Some(so_far) => so_far.into_iter().filter(|(path, _)| against.contains_key(path)).collect(),
        });
    }
    Ok(changed.unwrap_or_default())
}

/// Brings `prism_dates` into line for some paths — or, with `None`, for
/// every page.
fn refresh_dates(tx: &Transaction<'_>, paths: Option<&BTreeSet<String>>) -> Result<()> {
    const APPLIES: &str = "coalesce((SELECT created FROM prism_times WHERE path = p.path), (SELECT modified FROM prism_unsaved WHERE path = p.path)),
         coalesce((SELECT modified FROM prism_unsaved WHERE path = p.path), (SELECT modified FROM prism_times WHERE path = p.path))";
    match paths {
        None => {
            tx.execute("DELETE FROM prism_dates", [])?;
            tx.execute(
                &format!("INSERT INTO prism_dates SELECT p.path, {APPLIES} FROM (SELECT path FROM prism_times UNION SELECT path FROM prism_unsaved) AS p"),
                [],
            )?;
        }
        Some(paths) => {
            let mut remove = tx.prepare_cached("DELETE FROM prism_dates WHERE path = ?1")?;
            let mut put = tx.prepare_cached(&format!(
                "INSERT INTO prism_dates SELECT p.path, {APPLIES} FROM (SELECT ?1 AS path) AS p
                 WHERE EXISTS (SELECT 1 FROM prism_times WHERE path = ?1) OR EXISTS (SELECT 1 FROM prism_unsaved WHERE path = ?1)"
            ))?;
            for path in paths {
                remove.execute([path])?;
                put.execute([path])?;
            }
        }
    }
    Ok(())
}

impl Times {
    /// Reads a whole history, up to `head`: every page there is, and when
    /// it was first committed and last changed. Touches no database, so
    /// it can be run apart from an [`Indexer`] — on another thread — and
    /// handed to [`Indexer::set_history`].
    pub fn history(repo: &Repository, head: Oid) -> Result<History> {
        let mut pages: HashMap<String, (i64, i64)> = HashMap::new();
        for commit in repo.commits_since(head, None)? {
            for (path, exists) in changed_by(repo, &commit)? {
                if exists {
                    let times = pages.entry(path).or_insert((commit.time, commit.time));
                    *times = (times.0.min(commit.time), times.1.max(commit.time));
                } else {
                    pages.remove(&path);
                }
            }
        }
        Ok(History { head, pages })
    }

    /// When a page was first committed and last changed by a commit, in
    /// seconds since the Unix epoch. `None` for a page never committed.
    pub fn committed(db: &Connection, path: &str) -> Result<Option<(i64, i64)>> {
        Ok(db.query_row("SELECT created, modified FROM prism_times WHERE path = ?1", [path], |r| Ok((r.get(0)?, r.get(1)?))).optional()?)
    }

    /// The pages written since the last commit, with their files' times.
    pub fn unsaved(db: &Connection) -> Result<Vec<(String, i64)>> {
        let mut statement = db.prepare("SELECT path, modified FROM prism_unsaved ORDER BY path")?;
        let rows = statement.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }
}

impl Indexer {
    /// The commit the times were last brought up to.
    pub fn times_cursor(&self) -> Result<Option<Oid>> {
        self.cursor(CURSOR)
    }

    /// The commit the times can be brought on from: the last one seen,
    /// when it is still part of `head`'s history.
    fn times_start(&self, repo: &Repository, head: Oid) -> Result<Option<Oid>> {
        Ok(match self.stored_cursor(CURSOR)? {
            Some((VERSION, Some(at))) if repo.contains(at) && repo.is_ancestor(at, head) => Some(at),
            _ => None,
        })
    }

    /// Whether bringing the times up to `head` means reading the whole
    /// history: on a first run, or when history was rewritten
    /// underneath. Worth doing apart ([`Times::history`]) when it does.
    pub fn times_need_history(&self, repo: &Repository, head: Oid) -> Result<bool> {
        Ok(self.times_start(repo, head)?.is_none())
    }

    /// Brings pages' times up to a commit — the branch's head — by
    /// ingesting the commits made since the last one seen. Returns how
    /// many were ingested. Everything is read again from the first commit
    /// when history was rewritten underneath: when the last commit seen
    /// is no ancestor of this one.
    pub fn update_times(&mut self, repo: &Repository, head: Option<Oid>) -> Result<usize> {
        let Some(head) = head else {
            // No commits: nothing is dated.
            if self.stored_cursor(CURSOR)?.is_some() {
                let tx = self.connection.transaction()?;
                tx.execute("DELETE FROM prism_times", [])?;
                tx.execute("DELETE FROM prism_cursors WHERE name = ?1", [CURSOR])?;
                refresh_dates(&tx, None)?;
                tx.commit()?;
            }
            return Ok(0);
        };
        let Some(start) = self.times_start(repo, head)? else {
            let history = Times::history(repo, head)?;
            let commits = repo.commits_since(head, None)?.len();
            self.set_history(history)?;
            return Ok(commits);
        };
        if start == head {
            return Ok(0);
        }
        let commits = repo.commits_since(head, Some(start))?;
        let tx = self.connection.transaction()?;
        let mut touched = BTreeSet::new();
        {
            let mut put = tx.prepare_cached(
                "INSERT INTO prism_times (path, created, modified) VALUES (?1, ?2, ?2)
                 ON CONFLICT(path) DO UPDATE SET created = min(created, ?2), modified = max(modified, ?2)",
            )?;
            let mut remove = tx.prepare_cached("DELETE FROM prism_times WHERE path = ?1")?;
            for commit in &commits {
                for (path, exists) in changed_by(repo, commit)? {
                    if exists {
                        put.execute(params![path, commit.time])?;
                    } else {
                        remove.execute([&path])?;
                    }
                    touched.insert(path);
                }
            }
        }
        refresh_dates(&tx, Some(&touched))?;
        set_cursor(&tx, head)?;
        tx.commit()?;
        Ok(commits.len())
    }

    /// Takes a history read apart ([`Times::history`]) as what history
    /// says: every page's times, as of its head.
    pub fn set_history(&mut self, history: History) -> Result<()> {
        let tx = self.connection.transaction()?;
        tx.execute("DELETE FROM prism_times", [])?;
        {
            let mut put = tx.prepare_cached("INSERT INTO prism_times (path, created, modified) VALUES (?1, ?2, ?3)")?;
            for (path, (created, modified)) in &history.pages {
                put.execute(params![path, created, modified])?;
            }
        }
        refresh_dates(&tx, None)?;
        set_cursor(&tx, history.head)?;
        tx.commit()?;
        Ok(())
    }

    /// Says which pages are written but not yet committed, each with its
    /// file's time: all of them, each time — what was said before is
    /// forgotten.
    pub fn set_unsaved(&mut self, unsaved: &[(String, i64)]) -> Result<()> {
        let before = Times::unsaved(&self.connection)?;
        if unsaved == before.as_slice() {
            return Ok(());
        }
        let tx = self.connection.transaction()?;
        tx.execute("DELETE FROM prism_unsaved", [])?;
        for (path, modified) in unsaved {
            tx.execute("INSERT OR REPLACE INTO prism_unsaved (path, modified) VALUES (?1, ?2)", params![path, modified])?;
        }
        let touched: BTreeSet<String> = before.into_iter().chain(unsaved.iter().cloned()).map(|(path, _)| path).collect();
        refresh_dates(&tx, Some(&touched))?;
        tx.commit()?;
        Ok(())
    }
}

fn set_cursor(tx: &Transaction<'_>, head: Oid) -> Result<()> {
    tx.execute(
        "INSERT INTO prism_cursors (name, version, tree) VALUES (?1, ?2, ?3) ON CONFLICT(name) DO UPDATE SET version = ?2, tree = ?3",
        params![CURSOR, VERSION, head.to_string()],
    )?;
    Ok(())
}
