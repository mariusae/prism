//! What this device alone keeps about a graph.
//!
//! Which rivers are open, which cards are in them and how they are
//! folded, what was looked at last: how this device *shows* the graph,
//! not what the graph says. It is kept out of the working tree — beside
//! the indices, inside `.git` — so it is never committed, never synced,
//! and each clone has its own.
//!
//! It is a small table of named values. The engine gives the names no
//! meaning: an app keeps what it needs under names of its own, and
//! values in whatever form it reads back (a saved river's Markdown, for
//! a river not yet saved, so one reader serves both).

use crate::Result;
use prism_index::rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use std::sync::Mutex;

/// A device's own notes about a graph: values by name.
pub struct Local {
    connection: Mutex<Connection>,
}

impl Local {
    /// Opens (or makes) the store at `path`.
    pub fn open(path: impl AsRef<Path>) -> Result<Local> {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| crate::Error::io(format!("making {}", parent.display()), e))?;
        }
        Local::with(Connection::open(path).map_err(prism_index::Error::from)?)
    }

    /// A store in memory: for tests.
    pub fn in_memory() -> Result<Local> {
        Local::with(Connection::open_in_memory().map_err(prism_index::Error::from)?)
    }

    fn with(connection: Connection) -> Result<Local> {
        let made = connection
            .pragma_update(None, "journal_mode", "WAL")
            .and_then(|()| connection.execute_batch("CREATE TABLE IF NOT EXISTS local (name TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;"));
        made.map_err(prism_index::Error::from)?;
        Ok(Local { connection: Mutex::new(connection) })
    }

    fn ask<T>(&self, ask: impl FnOnce(&Connection) -> prism_index::rusqlite::Result<T>) -> Result<T> {
        let connection = self.connection.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        Ok(ask(&connection).map_err(prism_index::Error::from)?)
    }

    /// The value kept under a name.
    pub fn get(&self, name: &str) -> Result<Option<String>> {
        self.ask(|db| db.query_row("SELECT value FROM local WHERE name = ?1", [name], |row| row.get(0)).optional())
    }

    /// Keeps a value under a name; `None` forgets it.
    pub fn set(&self, name: &str, value: Option<&str>) -> Result<()> {
        self.ask(|db| match value {
            Some(value) => db.execute("INSERT INTO local (name, value) VALUES (?1, ?2) ON CONFLICT(name) DO UPDATE SET value = ?2", params![name, value]),
            None => db.execute("DELETE FROM local WHERE name = ?1", [name]),
        })?;
        Ok(())
    }

    /// The names kept that start with a prefix, sorted.
    pub fn names(&self, prefix: &str) -> Result<Vec<String>> {
        self.ask(|db| {
            let mut statement = db.prepare("SELECT name FROM local WHERE name >= ?1 AND name < ?2 ORDER BY name")?;
            let names = statement.query_map(params![prefix, format!("{prefix}{}", char::MAX)], |row| row.get(0))?.collect();
            names
        })
    }

    /// Forgets everything: a clean slate.
    pub fn clear(&self) -> Result<()> {
        self.ask(|db| db.execute("DELETE FROM local", []))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values_are_kept_by_name_and_listed_by_prefix() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("deep/local.sqlite");
        {
            let local = Local::open(&path).unwrap();
            assert_eq!(local.get("river/1").unwrap(), None);
            local.set("river/1", Some("- [[Ada]]\n")).unwrap();
            local.set("river/2", Some("- [[Grace]]\n")).unwrap();
            local.set("window", Some("{}")).unwrap();
            local.set("river/1", Some("- [[Ada]]\n- [[Atlas]]\n")).unwrap();
            assert_eq!(local.names("river/").unwrap(), ["river/1", "river/2"]);
        }
        // It outlives the process that wrote it.
        let local = Local::open(&path).unwrap();
        assert_eq!(local.get("river/1").unwrap().as_deref(), Some("- [[Ada]]\n- [[Atlas]]\n"));
        local.set("river/2", None).unwrap();
        assert_eq!(local.names("").unwrap(), ["river/1", "window"]);
        local.clear().unwrap();
        assert!(local.names("").unwrap().is_empty());
    }
}
