//! The catalog: every page, what it is called, and what it says of itself.

use crate::{File, Index, Result};
use prism_markup::{name_key, Day, NoteKind, Week};
use rusqlite::{params, Connection, OptionalExtension, Transaction};

/// Every page of the graph: its title and names, its tags, its
/// frontmatter fields. What a chooser searches, what a link resolves
/// against, what a query's conditions are asked of.
pub struct Catalog;

/// A page, as the catalog lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteRow {
    pub path: String,
    pub title: String,
    /// The page's lasting identity, when it has one.
    pub id: Option<String>,
    /// `day`, `week` or `note`.
    pub kind: String,
    pub private: bool,
    pub wiki: bool,
    /// Seconds since the Unix epoch, as the page's frontmatter says.
    pub created: Option<i64>,
    pub modified: Option<i64>,
}

/// What a name leads to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolved {
    /// A page that is there.
    Note(String),
    /// A day's or a week's page not written yet: where it would be. A
    /// date always leads somewhere.
    Unwritten(String),
}

impl Resolved {
    pub fn path(&self) -> &str {
        match self {
            Resolved::Note(path) | Resolved::Unwritten(path) => path,
        }
    }
}

impl Index for Catalog {
    fn name(&self) -> &'static str {
        "catalog"
    }

    fn version(&self) -> u32 {
        1
    }

    fn create(&self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS notes (
                 path TEXT PRIMARY KEY, title TEXT NOT NULL, id TEXT, kind TEXT NOT NULL,
                 private INTEGER NOT NULL, wiki INTEGER NOT NULL, created INTEGER, modified INTEGER
             ) WITHOUT ROWID;
             CREATE INDEX IF NOT EXISTS notes_id ON notes (id);
             -- Every name a page answers to. rank: 0 its title, 1 an alias, 2 a part of its title.
             CREATE TABLE IF NOT EXISTS note_names (key TEXT NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL, rank INTEGER NOT NULL);
             CREATE INDEX IF NOT EXISTS note_names_key ON note_names (key);
             CREATE INDEX IF NOT EXISTS note_names_path ON note_names (path);
             CREATE TABLE IF NOT EXISTS note_tags (key TEXT NOT NULL, tag TEXT NOT NULL, path TEXT NOT NULL);
             CREATE INDEX IF NOT EXISTS note_tags_key ON note_tags (key);
             CREATE INDEX IF NOT EXISTS note_tags_path ON note_tags (path);
             -- Frontmatter, a row a value: a list's items in order.
             CREATE TABLE IF NOT EXISTS note_fields (path TEXT NOT NULL, key TEXT NOT NULL, position INTEGER NOT NULL, value TEXT NOT NULL);
             CREATE INDEX IF NOT EXISTS note_fields_path ON note_fields (path);
             CREATE INDEX IF NOT EXISTS note_fields_key ON note_fields (key, value);",
        )?;
        Ok(())
    }

    fn clear(&self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute_batch("DELETE FROM notes; DELETE FROM note_names; DELETE FROM note_tags; DELETE FROM note_fields;")?;
        Ok(())
    }

    fn remove(&self, tx: &Transaction<'_>, path: &str) -> Result<()> {
        for table in ["notes", "note_names", "note_tags", "note_fields"] {
            tx.execute(&format!("DELETE FROM {table} WHERE path = ?1"), [path])?;
        }
        Ok(())
    }

    fn put(&self, tx: &Transaction<'_>, file: &File<'_>) -> Result<()> {
        let (Some(note), Some(kind)) = (file.note(), file.kind()) else { return Ok(()) };
        let meta = note.meta(file.path);
        let kind = match kind {
            NoteKind::Day(_) => "day",
            NoteKind::Week(_) => "week",
            NoteKind::Note => "note",
        };
        tx.execute(
            "INSERT INTO notes (path, title, id, kind, private, wiki, created, modified) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![file.path, meta.title, meta.id, kind, meta.private, meta.wiki, meta.created.map(|t| t.0), meta.modified.map(|t| t.0)],
        )?;
        let mut insert_name = tx.prepare_cached("INSERT INTO note_names (key, name, path, rank) VALUES (?1, ?2, ?3, ?4)")?;
        for name in meta.names() {
            let rank = if name == meta.title {
                0
            } else if meta.aliases.contains(&name) {
                1
            } else {
                2
            };
            insert_name.execute(params![name_key(&name), name, file.path, rank])?;
        }
        let mut insert_tag = tx.prepare_cached("INSERT INTO note_tags (key, tag, path) VALUES (?1, ?2, ?3)")?;
        for tag in &meta.tags {
            insert_tag.execute(params![tag.to_lowercase(), tag, file.path])?;
        }
        if let Some(frontmatter) = &note.frontmatter {
            let mut insert_field = tx.prepare_cached("INSERT INTO note_fields (path, key, position, value) VALUES (?1, ?2, ?3, ?4)")?;
            for (key, value) in frontmatter.iter() {
                for (position, item) in value.to_list().iter().enumerate() {
                    insert_field.execute(params![file.path, key, position as i64, item])?;
                }
            }
        }
        Ok(())
    }
}

fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<NoteRow> {
    Ok(NoteRow {
        path: row.get(0)?,
        title: row.get(1)?,
        id: row.get(2)?,
        kind: row.get(3)?,
        private: row.get(4)?,
        wiki: row.get(5)?,
        created: row.get(6)?,
        modified: row.get(7)?,
    })
}

const COLUMNS: &str = "notes.path, notes.title, notes.id, notes.kind, notes.private, notes.wiki, notes.created, notes.modified";

impl Catalog {
    /// The page at a path.
    pub fn get(db: &Connection, path: &str) -> Result<Option<NoteRow>> {
        Ok(db.query_row(&format!("SELECT {COLUMNS} FROM notes WHERE path = ?1"), [path], row).optional()?)
    }

    /// The page with a lasting id, wherever it has been moved to.
    pub fn by_id(db: &Connection, id: &str) -> Result<Option<NoteRow>> {
        Ok(db.query_row(&format!("SELECT {COLUMNS} FROM notes WHERE lower(id) = lower(?1)"), [id], row).optional()?)
    }

    /// Every page, by title.
    pub fn all(db: &Connection) -> Result<Vec<NoteRow>> {
        let mut statement = db.prepare(&format!("SELECT {COLUMNS} FROM notes ORDER BY title COLLATE NOCASE, path"))?;
        let rows = statement.query_map([], row)?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    pub fn count(db: &Connection) -> Result<usize> {
        Ok(db.query_row("SELECT count(*) FROM notes", [], |r| r.get::<_, i64>(0))? as usize)
    }

    /// What a link's name leads to, as links are resolved: a date first
    /// (a day's or a week's page, written yet or not), then a page by its
    /// title, then by an alias, then by a part of its title — case aside.
    /// `None`: a page waiting to be written.
    pub fn resolve(db: &Connection, name: &str) -> Result<Option<Resolved>> {
        let trimmed = name.trim();
        let dated = Day::parse(trimmed).map(NoteKind::day_path).or_else(|| Week::parse(trimmed).map(NoteKind::week_path));
        if let Some(path) = dated {
            let exists = Catalog::get(db, &path)?.is_some();
            return Ok(Some(if exists { Resolved::Note(path) } else { Resolved::Unwritten(path) }));
        }
        let path: Option<String> =
            db.query_row("SELECT path FROM note_names WHERE key = ?1 ORDER BY rank, path LIMIT 1", [name_key(trimmed)], |r| r.get(0)).optional()?;
        Ok(path.map(Resolved::Note))
    }

    /// Every name a page answers to: its title first.
    pub fn names(db: &Connection, path: &str) -> Result<Vec<String>> {
        let mut statement = db.prepare("SELECT name FROM note_names WHERE path = ?1 ORDER BY rank, rowid")?;
        let names = statement.query_map([path], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(names)
    }

    /// Pages whose title or alias starts with, or has a word starting
    /// with, what was typed: a chooser's first answer. Titles first.
    pub fn complete(db: &Connection, typed: &str, limit: usize) -> Result<Vec<NoteRow>> {
        let key = name_key(typed).replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_");
        let mut statement = db.prepare(&format!(
            "SELECT {COLUMNS} FROM notes JOIN (
                 SELECT path, min(rank * 2 + (key NOT LIKE ?1 ESCAPE '\\')) AS score FROM note_names
                 WHERE key LIKE ?1 ESCAPE '\\' OR key LIKE ?2 ESCAPE '\\' GROUP BY path
             ) AS found ON found.path = notes.path
             ORDER BY found.score, notes.title COLLATE NOCASE LIMIT ?3"
        ))?;
        let rows = statement.query_map(params![format!("{key}%"), format!("% {key}%"), limit as i64], row)?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// The pages with a tag, case aside, by title.
    pub fn tagged(db: &Connection, tag: &str) -> Result<Vec<NoteRow>> {
        let mut statement = db.prepare(&format!(
            "SELECT {COLUMNS} FROM notes JOIN note_tags ON note_tags.path = notes.path WHERE note_tags.key = ?1 ORDER BY notes.title COLLATE NOCASE, notes.path"
        ))?;
        let rows = statement.query_map([tag.trim_start_matches('#').to_lowercase()], row)?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// Every tag, with how many pages have it, most used first.
    pub fn tags(db: &Connection) -> Result<Vec<(String, usize)>> {
        let mut statement = db.prepare("SELECT min(tag), count(DISTINCT path) AS uses FROM note_tags GROUP BY key ORDER BY uses DESC, key")?;
        let tags = statement.query_map([], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? as usize)))?.collect::<rusqlite::Result<_>>()?;
        Ok(tags)
    }

    /// A page's tags, as written.
    pub fn tags_of(db: &Connection, path: &str) -> Result<Vec<String>> {
        let mut statement = db.prepare("SELECT tag FROM note_tags WHERE path = ?1 ORDER BY rowid")?;
        let tags = statement.query_map([path], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(tags)
    }

    /// A page's frontmatter: each key with its values, in the order written.
    pub fn fields(db: &Connection, path: &str) -> Result<Vec<(String, Vec<String>)>> {
        let mut statement = db.prepare("SELECT key, value FROM note_fields WHERE path = ?1 ORDER BY rowid")?;
        let mut fields: Vec<(String, Vec<String>)> = Vec::new();
        for pair in statement.query_map([path], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
            let (key, value) = pair?;
            match fields.last_mut() {
                Some((last, values)) if *last == key => values.push(value),
                _ => fields.push((key, vec![value])),
            }
        }
        Ok(fields)
    }

    /// The pages whose frontmatter has a key — with a given value, when
    /// one is asked for.
    pub fn with_field(db: &Connection, key: &str, value: Option<&str>) -> Result<Vec<NoteRow>> {
        let mut statement = db.prepare(&format!(
            "SELECT DISTINCT {COLUMNS} FROM notes JOIN note_fields ON note_fields.path = notes.path
             WHERE note_fields.key = ?1 AND (?2 IS NULL OR note_fields.value = ?2 COLLATE NOCASE)
             ORDER BY notes.title COLLATE NOCASE, notes.path"
        ))?;
        let rows = statement.query_map(params![key, value], row)?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }
}
