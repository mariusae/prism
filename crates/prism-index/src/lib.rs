//! Indices over a graph, kept in step with a git tree.
//!
//! An index is anything derived from the graph's files that would be slow
//! to derive each time it is asked for: which notes link here, which
//! mention a word, which tasks are open. This crate is the machinery that
//! keeps such things **incrementally** up to date, and four indices built
//! on it.
//!
//! # How an index stays current
//!
//! Every index records the git **tree** it was last brought up to — its
//! *cursor*. To update it to another tree, the [`Indexer`] asks git what
//! differs between the two ([`Repository::changes`], whose cost is the
//! size of the difference) and feeds the index only that: each path
//! [removed](Index::remove), each new or changed file [put](Index::put).
//! The changes and the new cursor are written in one transaction, so an
//! index is always exactly some tree's — never between two, whatever
//! interrupts it.
//!
//! The tree can be a commit's, or a [snapshot](Repository::snapshot) of
//! the working tree: indices follow what is being typed, not only what
//! was committed. Because trees are content hashes, a tree already seen
//! costs nothing, and the same content reached another way (typed here,
//! or pulled from another device) is the same tree.
//!
//! An index is rebuilt from nothing — by the same code path, as a diff
//! from the empty tree — when it is new, when its [`version`](Index::version)
//! changes, or when its cursor names a tree git no longer has.
//!
//! ```no_run
//! use prism_index::{Catalog, Indexer, Links, Search, Tasks};
//! use prism_sync::{Repository, SnapshotOptions};
//!
//! let repo = Repository::open("/path/to/graph")?;
//! let mut indexer = Indexer::open(repo.git_dir().join("prism/index.sqlite"), prism_index::standard())?;
//!
//! // Whenever something may have changed: after a save, after a sync.
//! let tree = repo.snapshot(&SnapshotOptions::default())?.tree;
//! let update = indexer.update(&repo, tree)?;
//! println!("{} files ingested", update.changed.len());
//!
//! let db = indexer.connection();
//! let atlas = Catalog::resolve(db, "Project Atlas")?;
//! let linking_here = Links::backlinks(db, &["Project Atlas".into(), "Atlas".into()])?;
//! let hits = Search::search(db, "kick-off", 20)?;
//! let todo = Tasks::open(db)?;
//! # Ok::<(), prism_index::Error>(())
//! ```
//!
//! # Writing an index
//!
//! Implement [`Index`]: name your tables, and say how one file is added
//! and one path removed. The framework owns the rest — cursors, diffs,
//! transactions, rebuilds — and hands each file over read and, for a
//! note, parsed once however many indices want it ([`File`]).
//!
//! # Times
//!
//! When a page was made and last changed is read off git's history, not
//! written in the page: see [`Times`], kept by [`Indexer::update_times`]
//! with a cursor of its own — a commit, where the others' are trees.
//!
//! Storage is SQLite: one database, many indices, each with tables of its
//! own, all moved together atomically. Keep the database outside the
//! working tree (inside `.git/` is a good place): it is derived, and
//! every device builds its own.

mod assets;
mod catalog;
mod links;
pub mod query;
mod search;
mod tasks;
mod times;

pub use assets::{AssetUse, Assets};
pub use catalog::{Catalog, NoteRow, Resolved};
pub use links::{Backlink, Links};
pub use prism_markup::LinkKind;
pub use query::{QueryOptions, QueryResult, Show};
pub use search::{Hit, Search};
pub use tasks::{TaskRow, Tasks};
pub use times::{History, Times};

use prism_markup::{Note, NoteKind};
use prism_sync::{Oid, Repository};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use std::cell::OnceCell;
use std::path::Path;

pub use rusqlite;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("index database: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error(transparent)]
    Repository(#[from] prism_sync::Error),
    #[error("{context}: {source}")]
    Io {
        context: String,
        #[source]
        source: std::io::Error,
    },
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

// --- What a connection may see ---------------------------------------------

/// Says whether this connection's questions see private pages.
///
/// **A private page is seen only where it is asked for outright.** Every
/// question in this crate — the catalog's listings and name lookups,
/// backlinks, search, tasks, queries — leaves out pages marked
/// `private`, and what is written in them, unless the connection asking
/// was told to show them. The choice is the connection's, so it is made
/// once, where a view is set up, and cannot be forgotten at one call
/// among many.
///
/// [`Indexer::reader`] hides them; [`Indexer::reader_showing_private`]
/// and the indexer's own connection show them.
pub fn show_private(db: &Connection, show: bool) -> Result<()> {
    db.execute_batch("CREATE TEMP TABLE IF NOT EXISTS prism_scope (shows_private INTEGER NOT NULL); DELETE FROM temp.prism_scope;")?;
    db.execute("INSERT INTO temp.prism_scope (shows_private) VALUES (?1)", [show])?;
    Ok(())
}

/// Whether this connection's questions see private pages.
pub fn shows_private(db: &Connection) -> Result<bool> {
    Ok(db.query_row("SELECT shows_private FROM temp.prism_scope", [], |r| r.get(0))?)
}

/// SQL for "this connection may see the file at `column`": it shows
/// private pages, or the file is no private page.
pub(crate) fn seen(column: &str) -> String {
    format!("((SELECT shows_private FROM temp.prism_scope) OR NOT EXISTS (SELECT 1 FROM notes AS hidden WHERE hidden.path = {column} AND hidden.private))")
}

/// Whether a table is there with a column: how an index tells a table an
/// earlier version of it left.
pub(crate) fn column_exists(tx: &Transaction<'_>, table: &str, column: &str) -> Result<bool> {
    Ok(tx.prepare("SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2")?.exists([table, column])?)
}

/// One file of the tree being indexed, read at most once and — when it is
/// a note — parsed at most once, however many indices look at it.
pub struct File<'a> {
    /// The path from the graph's top.
    pub path: &'a str,
    /// The content's hash.
    pub id: Oid,
    repo: &'a Repository,
    bytes: OnceCell<Vec<u8>>,
    note: OnceCell<Option<Note>>,
}

impl<'a> File<'a> {
    fn new(repo: &'a Repository, path: &'a str, id: Oid) -> File<'a> {
        File { path, id, repo, bytes: OnceCell::new(), note: OnceCell::new() }
    }

    /// The file's bytes. Empty for a blob that cannot be read.
    pub fn bytes(&self) -> &[u8] {
        self.bytes.get_or_init(|| self.repo.blob(self.id).unwrap_or_default())
    }

    /// The file's text, when it is UTF-8.
    pub fn text(&self) -> Option<&str> {
        std::str::from_utf8(self.bytes()).ok()
    }

    /// What kind of page the file is, when it is one.
    pub fn kind(&self) -> Option<NoteKind> {
        NoteKind::of(self.path)
    }

    /// The file as a note, when it is a page of the graph.
    pub fn note(&self) -> Option<&Note> {
        self.note.get_or_init(|| self.kind().and_then(|_| self.text()).map(Note::parse)).as_ref()
    }
}

/// Something derived from the graph's files, kept in tables of its own.
///
/// The contract: after any sequence of calls, the tables hold exactly
/// what `put` would have written for the files of the cursor's tree. So
/// `remove(path)` must undo everything `put` wrote for that path, and
/// `put` is only ever called for a path not currently in the index.
pub trait Index: Send {
    /// The index's name: its key among the cursors. Never change it.
    fn name(&self) -> &'static str;

    /// Bump when the tables or what goes in them change: the index is
    /// then emptied and rebuilt.
    fn version(&self) -> u32;

    /// Makes the tables, if they are not there. Called on every open.
    fn create(&self, tx: &Transaction<'_>) -> Result<()>;

    /// Empties the tables, before a rebuild.
    fn clear(&self, tx: &Transaction<'_>) -> Result<()>;

    /// Whether the index has anything to say about a path. The default:
    /// pages of the graph only.
    fn wants(&self, path: &str) -> bool {
        NoteKind::of(path).is_some()
    }

    /// Takes out everything the index holds for a path.
    fn remove(&self, tx: &Transaction<'_>, path: &str) -> Result<()>;

    /// Adds a file.
    fn put(&self, tx: &Transaction<'_>, file: &File<'_>) -> Result<()>;
}

/// The indices this crate provides.
pub fn standard() -> Vec<Box<dyn Index>> {
    vec![Box::new(Catalog), Box::new(Links), Box::new(Search), Box::new(Tasks), Box::new(Assets)]
}

/// What an [`Indexer::update`] did.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Update {
    /// The tree the indices are now at.
    pub tree: Option<Oid>,
    /// Every path that was ingested or removed, sorted, each once.
    pub changed: Vec<String>,
    /// The indices that were rebuilt from nothing.
    pub rebuilt: Vec<&'static str>,
}

impl Update {
    /// Whether every index was already at the tree.
    pub fn is_noop(&self) -> bool {
        self.changed.is_empty() && self.rebuilt.is_empty()
    }
}

/// A database of indices, and the means to bring them up to a tree.
pub struct Indexer {
    connection: Connection,
    indices: Vec<Box<dyn Index>>,
}

impl Indexer {
    /// Opens (or makes) the database at `path`, with these indices.
    pub fn open(path: impl AsRef<Path>, indices: Vec<Box<dyn Index>>) -> Result<Indexer> {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|source| Error::Io { context: format!("making {}", parent.display()), source })?;
        }
        let connection = Connection::open(path)?;
        // Readers on other connections are never blocked by an update.
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "synchronous", "NORMAL")?;
        Indexer::with_connection(connection, indices)
    }

    /// A database in memory: for tests, and indices cheap to rebuild.
    pub fn in_memory(indices: Vec<Box<dyn Index>>) -> Result<Indexer> {
        Indexer::with_connection(Connection::open_in_memory()?, indices)
    }

    fn with_connection(mut connection: Connection, indices: Vec<Box<dyn Index>>) -> Result<Indexer> {
        let tx = connection.transaction()?;
        tx.execute_batch("CREATE TABLE IF NOT EXISTS prism_cursors (name TEXT PRIMARY KEY, version INTEGER NOT NULL, tree TEXT) WITHOUT ROWID;")?;
        tx.execute_batch(times::TABLES)?;
        for index in &indices {
            index.create(&tx)?;
        }
        tx.commit()?;
        // The indexer's own connection sees everything.
        show_private(&connection, true)?;
        Ok(Indexer { connection, indices })
    }

    /// The database, to ask the indices' questions of.
    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    /// Another connection to a database on disk, for reading from another
    /// thread while this one updates. Private pages are hidden from it:
    /// see [`show_private`].
    pub fn reader(path: impl AsRef<Path>) -> Result<Connection> {
        let connection = Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        show_private(&connection, false)?;
        Ok(connection)
    }

    /// As [`reader`](Self::reader), for a view that shows private pages.
    pub fn reader_showing_private(path: impl AsRef<Path>) -> Result<Connection> {
        let connection = Indexer::reader(path)?;
        show_private(&connection, true)?;
        Ok(connection)
    }

    /// The tree an index is at, if it has been built.
    pub fn cursor(&self, name: &str) -> Result<Option<Oid>> {
        Ok(self.stored_cursor(name)?.and_then(|(_, tree)| tree))
    }

    fn stored_cursor(&self, name: &str) -> Result<Option<(u32, Option<Oid>)>> {
        let row: Option<(u32, Option<String>)> =
            self.connection.query_row("SELECT version, tree FROM prism_cursors WHERE name = ?1", [name], |row| Ok((row.get(0)?, row.get(1)?))).optional()?;
        Ok(row.map(|(version, tree)| (version, tree.and_then(|hex| Oid::from_str(&hex).ok()))))
    }

    /// Brings every index up to `tree`, ingesting only what differs from
    /// the tree each was at. All of it lands in one transaction, or none.
    pub fn update(&mut self, repo: &Repository, tree: Oid) -> Result<Update> {
        // Where each index starts from; `None` is a rebuild.
        let mut starts: Vec<Option<Oid>> = Vec::with_capacity(self.indices.len());
        let mut update = Update { tree: Some(tree), ..Update::default() };
        for index in &self.indices {
            let start = match self.stored_cursor(index.name())? {
                Some((version, Some(at))) if version == index.version() && repo.contains(at) => Some(at),
                _ => None,
            };
            if start.is_none() {
                update.rebuilt.push(index.name());
            }
            starts.push(start);
        }
        if starts.iter().all(|start| *start == Some(tree)) {
            return Ok(update);
        }

        let tx = self.connection.transaction()?;
        for (index, start) in self.indices.iter().zip(&starts) {
            if start.is_none() {
                index.clear(&tx)?;
            }
        }
        // Indices at the same tree share one diff, and each file is read
        // and parsed once for all of them.
        let mut distinct: Vec<Option<Oid>> = starts.clone();
        distinct.sort();
        distinct.dedup();
        for start in distinct {
            if start == Some(tree) {
                continue;
            }
            let group: Vec<&dyn Index> = self.indices.iter().zip(&starts).filter(|(_, s)| **s == start).map(|(i, _)| i.as_ref()).collect();
            for change in repo.changes(start, Some(tree), false)? {
                let wanted: Vec<&&dyn Index> = group.iter().filter(|index| index.wants(&change.path)).collect();
                if wanted.is_empty() {
                    continue;
                }
                if change.old.is_some() {
                    for index in &wanted {
                        index.remove(&tx, &change.path)?;
                    }
                }
                if let Some(entry) = change.new {
                    let file = File::new(repo, &change.path, entry.id);
                    for index in &wanted {
                        index.put(&tx, &file)?;
                    }
                }
                update.changed.push(change.path);
            }
        }
        // Two groups may have ingested the same path.
        update.changed.sort();
        update.changed.dedup();
        for index in &self.indices {
            tx.execute(
                "INSERT INTO prism_cursors (name, version, tree) VALUES (?1, ?2, ?3) ON CONFLICT(name) DO UPDATE SET version = ?2, tree = ?3",
                params![index.name(), index.version(), tree.to_string()],
            )?;
        }
        tx.commit()?;
        Ok(update)
    }

    /// Forgets where an index is, so the next update rebuilds it.
    pub fn invalidate(&mut self, name: &str) -> Result<()> {
        self.connection.execute("DELETE FROM prism_cursors WHERE name = ?1", [name])?;
        Ok(())
    }
}
