//! Tasks: every checkbox in the graph.

use crate::{File, Index, Result};
use rusqlite::{params, Connection, Transaction};

/// Every list item with a checkbox, open or done, with where it is.
pub struct Tasks;

/// A task, as the index lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskRow {
    /// The page the task is in.
    pub path: String,
    /// The task's block in that page: an index a level.
    pub block: Vec<usize>,
    /// The task's text, as Markdown.
    pub text: String,
    pub done: bool,
}

impl Index for Tasks {
    fn name(&self) -> &'static str {
        "tasks"
    }

    fn version(&self) -> u32 {
        1
    }

    fn create(&self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS tasks (path TEXT NOT NULL, block TEXT NOT NULL, text TEXT NOT NULL, done INTEGER NOT NULL);
             CREATE INDEX IF NOT EXISTS tasks_path ON tasks (path);
             CREATE INDEX IF NOT EXISTS tasks_done ON tasks (done);",
        )?;
        Ok(())
    }

    fn clear(&self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute("DELETE FROM tasks", [])?;
        Ok(())
    }

    fn remove(&self, tx: &Transaction<'_>, path: &str) -> Result<()> {
        tx.execute("DELETE FROM tasks WHERE path = ?1", [path])?;
        Ok(())
    }

    fn put(&self, tx: &Transaction<'_>, file: &File<'_>) -> Result<()> {
        let Some(note) = file.note() else { return Ok(()) };
        let mut insert = tx.prepare_cached("INSERT INTO tasks (path, block, text, done) VALUES (?1, ?2, ?3, ?4)")?;
        for task in note.references().tasks {
            let block = task.block.iter().map(usize::to_string).collect::<Vec<_>>().join(".");
            insert.execute(params![file.path, block, task.text, task.done])?;
        }
        Ok(())
    }
}

fn task(row: &rusqlite::Row<'_>) -> rusqlite::Result<TaskRow> {
    let block: String = row.get(1)?;
    Ok(TaskRow { path: row.get(0)?, block: block.split('.').filter_map(|part| part.parse().ok()).collect(), text: row.get(2)?, done: row.get(3)? })
}

impl Tasks {
    /// Every open task: newest days' first, then other pages', each
    /// page's in reading order.
    pub fn open(db: &Connection) -> Result<Vec<TaskRow>> {
        let mut statement = db.prepare(
            "SELECT path, block, text, done FROM tasks WHERE done = 0
             ORDER BY path NOT LIKE 'daily/%', CASE WHEN path LIKE 'daily/%' THEN path END DESC, path, rowid",
        )?;
        let tasks = statement.query_map([], task)?.collect::<rusqlite::Result<_>>()?;
        Ok(tasks)
    }

    /// A page's tasks, open and done, in reading order.
    pub fn in_note(db: &Connection, path: &str) -> Result<Vec<TaskRow>> {
        let mut statement = db.prepare("SELECT path, block, text, done FROM tasks WHERE path = ?1 ORDER BY rowid")?;
        let tasks = statement.query_map([path], task)?.collect::<rusqlite::Result<_>>()?;
        Ok(tasks)
    }

    /// How many tasks are open, and how many done.
    pub fn counts(db: &Connection) -> Result<(usize, usize)> {
        Ok(db.query_row("SELECT coalesce(sum(done = 0), 0), coalesce(sum(done = 1), 0) FROM tasks", [], |r| {
            Ok((r.get::<_, i64>(0)? as usize, r.get::<_, i64>(1)? as usize))
        })?)
    }
}
