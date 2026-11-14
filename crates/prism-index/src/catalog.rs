//! The catalog: every page, what it is called, and what its fields say.

use crate::{column_exists, File, Index, Result};
use prism_markup::{name_key, Day, FieldSpec, NoteKind, Week};
use rusqlite::{params, Connection, OptionalExtension, Transaction};

/// Every page of the graph: its title and names, and its frontmatter
/// fields. What a chooser searches, what a link resolves against, what a
/// query's conditions are asked of.
///
/// It keeps little of its own. A page's tags are links
/// ([`Links`](crate::Links)); when it was made and changed is history's
/// ([`Times`](crate::Times)); what marks it — pinned, in the inbox — is a
/// field. Only `private` is singled out, because it decides what every
/// other question may see.
pub struct Catalog;

/// A page, as the catalog lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteRow {
    pub path: String,
    pub title: String,
    /// `day`, `week` or `note`.
    pub kind: String,
    pub private: bool,
    /// Whether it holds a conflict two devices left for a person to
    /// settle: a block between conflict markers.
    pub conflicted: bool,
    /// Whether nothing is written in it: how an untouched day looks.
    pub blank: bool,
    /// When the page was made, in seconds since the Unix epoch: the first
    /// commit that has it, else — never committed — its file's time.
    pub created: Option<i64>,
    /// When it was last changed: its file's time while it holds something
    /// not yet committed, else the last commit that changed it.
    pub modified: Option<i64>,
    /// What it is shown as called: its title, or — for a note never
    /// given one — its first words. See `prism_markup::note::label`.
    pub label: String,
    /// Whether it was never given a title. Its `title` is then its
    /// file's name: what a link to it says, and nothing to show.
    pub untitled: bool,
}

/// The rank of a page's own name — its file's — among the names it
/// answers to: before its title (`0`) and its aliases (`1`).
pub const OWN: i64 = -1;

/// SQL: how well a row of `note_names` answers a name as it was written
/// (`written`: SQL for that text). A name written exactly as a file's
/// own leads to that file before anything; otherwise a title (`0`)
/// leads before an alias (`1`), and a file's name written some other
/// way — `Atlas` for `atlas.md` — comes last (`2`). So `[[atlas]]` is
/// the file `atlas.md`, and `[[Atlas]]` is the page titled Atlas where
/// there is one: links written before files' names were what links say
/// go on leading where they led. Of two pages that answer equally —
/// two with one title — the one made first is led to: a page made later
/// takes no link from the one that was there.
pub(crate) fn how(written: &str) -> String {
    format!("CASE WHEN rank = {OWN} AND name = {written} THEN {OWN} WHEN rank = {OWN} THEN 2 ELSE rank END")
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
        6
    }

    fn create(&self, tx: &Transaction<'_>) -> Result<()> {
        // Earlier versions' tables had other columns.
        if column_exists(tx, "notes", "path")? && !column_exists(tx, "notes", "label")? {
            tx.execute_batch("DROP TABLE notes; DROP TABLE IF EXISTS note_tags; DROP TABLE IF EXISTS note_fields;")?;
        }
        // Pages were once listed by their titles; they are listed by what they are shown as called.
        tx.execute_batch("DROP INDEX IF EXISTS notes_title;")?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS notes (
                 path TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL,
                 private INTEGER NOT NULL, conflicted INTEGER NOT NULL, blank INTEGER NOT NULL,
                 -- What it is shown as called: its title, or an untitled note's first words.
                 label TEXT NOT NULL, untitled INTEGER NOT NULL
             ) WITHOUT ROWID;
             -- Pages in the order they are listed in.
             CREATE INDEX IF NOT EXISTS notes_label ON notes (label COLLATE NOCASE, path);
             CREATE INDEX IF NOT EXISTS notes_conflicted ON notes (path) WHERE conflicted;
             -- Every name a page answers to. rank: -1 its file's name; 0 its title, or an untitled note's first words; 1 an alias.
             CREATE TABLE IF NOT EXISTS note_names (key TEXT NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL, rank INTEGER NOT NULL);
             CREATE INDEX IF NOT EXISTS note_names_key ON note_names (key);
             CREATE INDEX IF NOT EXISTS note_names_path ON note_names (path);
             -- Each name from each of its words on: 'ada lovelace' and 'lovelace'. What
             -- is typed is looked up as a prefix of these. score: lower is a better find.
             CREATE TABLE IF NOT EXISTS name_words (suffix TEXT NOT NULL, path TEXT NOT NULL, score INTEGER NOT NULL);
             CREATE INDEX IF NOT EXISTS name_words_suffix ON name_words (suffix);
             CREATE INDEX IF NOT EXISTS name_words_path ON name_words (path);
             -- Frontmatter, a row a value: a list's items in order. number: the value
             -- as a number, where it is one — what a sort by the field goes by first.
             CREATE TABLE IF NOT EXISTS note_fields (path TEXT NOT NULL, key TEXT NOT NULL, position INTEGER NOT NULL, value TEXT NOT NULL, number REAL);
             CREATE INDEX IF NOT EXISTS note_fields_path ON note_fields (path, key);
             CREATE INDEX IF NOT EXISTS note_fields_key ON note_fields (key, value);",
        )?;
        // The catalog's rows read pages' times from these.
        tx.execute_batch(crate::times::TABLES)?;
        Ok(())
    }

    fn clear(&self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute_batch("DELETE FROM notes; DELETE FROM note_names; DELETE FROM name_words; DELETE FROM note_fields;")?;
        Ok(())
    }

    fn remove(&self, tx: &Transaction<'_>, path: &str) -> Result<()> {
        for table in ["notes", "note_names", "name_words", "note_fields"] {
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
        let conflicted = file.text().is_some_and(prism_sync::conflict::detect);
        tx.execute(
            "INSERT INTO notes (path, title, kind, private, conflicted, blank, label, untitled) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![file.path, meta.title, kind, meta.private, conflicted, note.body.is_blank(), note.label(file.path), note.is_untitled(file.path)],
        )?;
        let mut insert_name = tx.prepare_cached("INSERT INTO note_names (key, name, path, rank) VALUES (?1, ?2, ?3, ?4)")?;
        let mut insert_word = tx.prepare_cached("INSERT INTO name_words (suffix, path, score) VALUES (?1, ?2, ?3)")?;
        // Its file's name: what a link to it is written with, and what leads to it before any title does.
        if let Some(own) = NoteKind::link_name(file.path) {
            insert_name.execute(params![name_key(own), own, file.path, OWN])?;
        }
        // What it is called: its title, or — never given one — its first words. Then its aliases.
        for (rank, name) in note.names(file.path).into_iter().enumerate() {
            let (key, rank) = (name_key(&name), rank.min(1) as i64);
            insert_name.execute(params![key, name, file.path, rank])?;
            // The name from each of its words on.
            let mut from = 0;
            loop {
                insert_word.execute(params![&key[from..], file.path, rank * 2 + i64::from(from > 0)])?;
                match key[from..].find(' ') {
                    Some(space) => from += space + 1,
                    None => break,
                }
            }
        }
        if let Some(frontmatter) = &note.frontmatter {
            let mut insert_field = tx.prepare_cached("INSERT INTO note_fields (path, key, position, value, number) VALUES (?1, ?2, ?3, ?4, ?5)")?;
            let mut known = std::collections::HashSet::new();
            for (key, value) in frontmatter.iter() {
                // A key written twice is read as its first.
                if !known.insert(key) {
                    continue;
                }
                for (position, item) in value.to_list().iter().enumerate() {
                    let number = item.trim().parse::<f64>().ok().filter(|number| number.is_finite());
                    insert_field.execute(params![file.path, key, position as i64, item, number])?;
                }
            }
        }
        Ok(())
    }
}

pub(crate) fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<NoteRow> {
    Ok(NoteRow {
        path: row.get(0)?,
        title: row.get(1)?,
        kind: row.get(2)?,
        private: row.get(3)?,
        conflicted: row.get(4)?,
        blank: row.get(5)?,
        created: row.get(6)?,
        modified: row.get(7)?,
        label: row.get(8)?,
        untitled: row.get(9)?,
    })
}

/// A page's row, with the times that apply to it.
pub(crate) const COLUMNS: &str = "notes.path, notes.title, notes.kind, notes.private, notes.conflicted, notes.blank,
     (SELECT created FROM prism_dates WHERE prism_dates.path = notes.path), (SELECT modified FROM prism_dates WHERE prism_dates.path = notes.path),
     notes.label, notes.untitled";

/// The pages this connection may see: see [`crate::show_private`].
pub(crate) const SEEN: &str = "(notes.private = 0 OR (SELECT shows_private FROM temp.prism_scope))";

impl Catalog {
    /// The page at a path.
    pub fn get(db: &Connection, path: &str) -> Result<Option<NoteRow>> {
        Ok(db.query_row(&format!("SELECT {COLUMNS} FROM notes WHERE path = ?1 AND {SEEN}"), [path], row).optional()?)
    }

    /// Every page, by title.
    pub fn all(db: &Connection) -> Result<Vec<NoteRow>> {
        let mut statement = db.prepare(&format!("SELECT {COLUMNS} FROM notes WHERE {SEEN} ORDER BY label COLLATE NOCASE, path"))?;
        let rows = statement.query_map([], row)?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    pub fn count(db: &Connection) -> Result<usize> {
        Ok(db.query_row(&format!("SELECT count(*) FROM notes WHERE {SEEN}"), [], |r| r.get::<_, i64>(0))? as usize)
    }

    /// What a link's name leads to, as links are resolved: a date first
    /// (a day's or a week's page, written yet or not), then a page by its
    /// title, then by an alias — case and spacing aside. `None`: a page
    /// waiting to be written.
    pub fn resolve(db: &Connection, name: &str) -> Result<Option<Resolved>> {
        let trimmed = name.trim();
        let dated = Day::parse(trimmed).map(NoteKind::day_path).or_else(|| Week::parse(trimmed).map(NoteKind::week_path));
        if let Some(path) = dated {
            let exists = Catalog::get(db, &path)?.is_some();
            return Ok(Some(if exists { Resolved::Note(path) } else { Resolved::Unwritten(path) }));
        }
        Ok(Catalog::answering(db, trimmed)?.into_iter().next().map(|(path, _)| Resolved::Note(path)))
    }

    /// Every page that answers to a name, each with how — `0` by its
    /// title, `1` by an alias — the one a link leads to first. More than
    /// one is a clash: see [`duplicates`](Self::duplicates).
    pub fn answering(db: &Connection, name: &str) -> Result<Vec<(String, i64)>> {
        Self::answering_as(db, name, name.trim())
    }

    /// As [`answering`](Self::answering), for the name written any way
    /// but exactly as a file's own: `Atlas`, `ATLAS`, where there is an
    /// `atlas.md`. Whom the name is *called* by, rather than which file
    /// it is.
    pub fn called(db: &Connection, name: &str) -> Result<Vec<(String, i64)>> {
        Self::answering_as(db, name, "")
    }

    fn answering_as(db: &Connection, name: &str, written: &str) -> Result<Vec<(String, i64)>> {
        let how = how("?2");
        let mut statement = db.prepare(&format!(
            "SELECT note_names.path, min({how}) AS how FROM note_names JOIN notes ON notes.path = note_names.path
             WHERE key = ?1 AND {SEEN} GROUP BY note_names.path
             ORDER BY how, coalesce((SELECT created FROM prism_dates WHERE prism_dates.path = note_names.path), 9223372036854775807), note_names.path"
        ))?;
        let pages = statement.query_map(params![name_key(name), written], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?;
        Ok(pages)
    }

    /// The names more than one page claims, each with the pages claiming
    /// it — the one links lead to first. Nothing stops two devices, or
    /// another app, from making two pages of one name; this is how an app
    /// finds them, to offer to merge or rename.
    pub fn duplicates(db: &Connection) -> Result<Vec<(String, Vec<String>)>> {
        let mut statement = db.prepare(&format!(
            "SELECT key, name, note_names.path, min(rank) AS how FROM note_names JOIN notes ON notes.path = note_names.path
             WHERE {SEEN} AND rank >= 0 AND key IN (SELECT key FROM note_names WHERE rank >= 0 GROUP BY key HAVING count(DISTINCT path) > 1)
             GROUP BY key, note_names.path ORDER BY key, how, note_names.path"
        ))?;
        let rows = statement.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)))?;
        let mut clashes: Vec<(String, String, Vec<String>)> = Vec::new();
        for row in rows {
            let (key, name, path) = row?;
            match clashes.last_mut() {
                Some((last, _, paths)) if *last == key => paths.push(path),
                _ => clashes.push((key, name, vec![path])),
            }
        }
        Ok(clashes.into_iter().filter(|(_, _, paths)| paths.len() > 1).map(|(_, name, paths)| (name, paths)).collect())
    }

    /// Every name a page is called by: its title first, then its aliases.
    /// Its file's name is not among them: see [`own_name`](Self::own_name).
    pub fn names(db: &Connection, path: &str) -> Result<Vec<String>> {
        let mut statement = db.prepare("SELECT name FROM note_names WHERE path = ?1 AND rank >= 0 ORDER BY rank, rowid")?;
        let names = statement.query_map([path], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(names)
    }

    /// A file's own name that has this key, written as it is: `atlas`
    /// for `Atlas`, where there is an `atlas.md`.
    pub fn own_name(db: &Connection, name: &str) -> Result<Option<(String, String)>> {
        Ok(db
            .query_row(&format!("SELECT name, path FROM note_names WHERE key = ?1 AND rank = {OWN} ORDER BY path LIMIT 1"), [name_key(name)], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .optional()?)
    }

    /// Pages whose title or alias starts with, or has a word starting
    /// with, what was typed: a chooser's first answer. Titles first, and
    /// a name's start before a word inside it; among those found alike,
    /// the page changed last comes first — what was worked on lately is
    /// what is most often looked for — and then by name. Looked up in
    /// an index of names' words, so it costs what it finds, not what
    /// there is.
    pub fn complete(db: &Connection, typed: &str, limit: usize) -> Result<Vec<NoteRow>> {
        let key = name_key(typed);
        let mut statement = db.prepare(&format!(
            "SELECT {COLUMNS} FROM notes JOIN (
                 SELECT path, min(score) AS score FROM name_words WHERE suffix >= ?1 AND suffix < ?2 GROUP BY path
             ) AS found ON found.path = notes.path
             WHERE {SEEN}
             ORDER BY notes.path IN (SELECT path FROM note_fields WHERE key = 'archived' AND position = 0
                   AND trim(value) != '' AND lower(trim(value)) NOT IN ('false', 'no', 'off', '0', 'n')),
               found.score, coalesce((SELECT modified FROM prism_dates WHERE prism_dates.path = notes.path), 0) DESC, notes.label COLLATE NOCASE, notes.path
             LIMIT ?3"
        ))?;
        let rows = statement.query_map(params![key, format!("{key}{}", char::MAX), limit as i64], row)?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// The pages left holding a conflict for a person to settle.
    pub fn conflicted(db: &Connection) -> Result<Vec<NoteRow>> {
        let mut statement =
            db.prepare(&format!("SELECT {COLUMNS} FROM notes INDEXED BY notes_conflicted WHERE conflicted AND {SEEN} ORDER BY label COLLATE NOCASE, path"))?;
        let rows = statement.query_map([], row)?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// The pages with a tag — in their text or their `tags` — by title.
    /// A tag is a link ([`Links`](crate::Links), which this asks).
    pub fn tagged(db: &Connection, tag: &str) -> Result<Vec<NoteRow>> {
        let mut statement = db.prepare(&format!(
            "SELECT {COLUMNS} FROM notes WHERE {SEEN} AND path IN (SELECT source FROM links WHERE kind = 'tag' AND key = ?1)
             ORDER BY notes.label COLLATE NOCASE, notes.path"
        ))?;
        let rows = statement.query_map([name_key(tag.trim().trim_start_matches('#'))], row)?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// Every tag, with how many pages have it, most used first.
    pub fn tags(db: &Connection) -> Result<Vec<(String, usize)>> {
        let seen = crate::seen("links.source");
        let mut statement = db.prepare(&format!(
            "SELECT min(target), count(DISTINCT source) AS uses FROM links WHERE kind = 'tag' AND {seen} GROUP BY key ORDER BY uses DESC, key"
        ))?;
        let tags = statement.query_map([], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? as usize)))?.collect::<rusqlite::Result<_>>()?;
        Ok(tags)
    }

    /// A page's tags, as written: its frontmatter's, then its text's,
    /// each once.
    pub fn tags_of(db: &Connection, path: &str) -> Result<Vec<String>> {
        let mut statement = db.prepare("SELECT target, key FROM links WHERE source = ?1 AND kind = 'tag' ORDER BY field = '', rowid")?;
        let mut seen = std::collections::HashSet::new();
        let mut tags = Vec::new();
        for pair in statement.query_map([path], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
            let (tag, key) = pair?;
            if seen.insert(key) {
                tags.push(tag);
            }
        }
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

    /// The typed fields a tag gives the pages tagged with it: the
    /// `fields` its own page lists. None, for a tag with no page.
    pub fn field_specs(db: &Connection, tag: &str) -> Result<Vec<FieldSpec>> {
        let Some(Resolved::Note(path)) = Catalog::resolve(db, tag.trim_start_matches('#'))? else { return Ok(Vec::new()) };
        let mut statement = db.prepare("SELECT value FROM note_fields WHERE path = ?1 AND key = ?2 ORDER BY position")?;
        let items: Vec<String> = statement.query_map(params![path, prism_markup::fields::FIELDS_KEY], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(items.iter().filter_map(|item| FieldSpec::parse(item)).collect())
    }

    /// The fields a page's tags give it, in the order of its tags, each
    /// once: the form an app shows for the page.
    pub fn schema(db: &Connection, path: &str) -> Result<Vec<FieldSpec>> {
        const OWN: [&str; 3] = ["tags", "aliases", "private"];
        let mut schema: Vec<FieldSpec> = Vec::new();
        for tag in Catalog::tags_of(db, path)? {
            for spec in Catalog::field_specs(db, &tag)? {
                if !OWN.contains(&spec.name.as_str()) && !schema.iter().any(|known| known.name == spec.name) {
                    schema.push(spec);
                }
            }
        }
        Ok(schema)
    }

    /// What every page that has a field says for it: each page's path
    /// with the field's first value. One read of the key's index, for
    /// what a list shows of each of its rows — a page's icon, its colour.
    pub fn field_values(db: &Connection, key: &str) -> Result<Vec<(String, String)>> {
        let mut statement = db.prepare(&format!(
            "SELECT f.path, f.value FROM note_fields f JOIN notes ON notes.path = f.path
             WHERE f.key = ?1 AND {SEEN} AND f.position = (SELECT min(position) FROM note_fields WHERE path = f.path AND key = f.key)
             ORDER BY f.path"
        ))?;
        let rows = statement.query_map([key], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// The pages whose frontmatter has a key — with a given value, when
    /// one is asked for.
    pub fn with_field(db: &Connection, key: &str, value: Option<&str>) -> Result<Vec<NoteRow>> {
        let mut statement = db.prepare(&format!(
            "SELECT {COLUMNS} FROM notes WHERE {SEEN} AND path IN (SELECT path FROM note_fields WHERE key = ?1 AND (?2 IS NULL OR value = ?2 COLLATE NOCASE))
             ORDER BY notes.label COLLATE NOCASE, notes.path"
        ))?;
        let rows = statement.query_map(params![key, value], row)?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }
}
