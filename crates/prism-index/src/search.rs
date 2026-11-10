//! Full-text search over what pages say.

use crate::{File, Index, Result};
use rusqlite::{params, Connection, Transaction};

/// The words of every page, as they read — Markdown taken out — in
/// SQLite's FTS5. Private pages are indexed like any other; whether to
/// show them is the asker's to decide (join the [`Catalog`](crate::Catalog)).
pub struct Search;

/// A page a search found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hit {
    pub path: String,
    pub title: String,
    /// The text around the first match, the matched words between `[`
    /// and `]`.
    pub snippet: String,
}

impl Index for Search {
    fn name(&self) -> &'static str {
        "search"
    }

    fn version(&self) -> u32 {
        1
    }

    fn create(&self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute_batch("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(path UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2');")?;
        Ok(())
    }

    fn clear(&self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute("DELETE FROM search", [])?;
        Ok(())
    }

    fn remove(&self, tx: &Transaction<'_>, path: &str) -> Result<()> {
        tx.execute("DELETE FROM search WHERE path = ?1", [path])?;
        Ok(())
    }

    fn put(&self, tx: &Transaction<'_>, file: &File<'_>) -> Result<()> {
        let Some(note) = file.note() else { return Ok(()) };
        tx.execute("INSERT INTO search (path, title, body) VALUES (?1, ?2, ?3)", params![file.path, note.title(file.path), note.plain_text()])?;
        Ok(())
    }
}

impl Search {
    /// The pages with every word typed, best first. The last word matches
    /// as a prefix, so results come as it is typed. A title match counts
    /// for more than one in the body.
    pub fn search(db: &Connection, typed: &str, limit: usize) -> Result<Vec<Hit>> {
        let Some(query) = fts_query(typed) else { return Ok(Vec::new()) };
        let mut statement = db.prepare(
            "SELECT path, title, snippet(search, 2, '[', ']', '…', 12) FROM search
             WHERE search MATCH ?1 ORDER BY bm25(search, 0.0, 8.0, 1.0), path LIMIT ?2",
        )?;
        let hits = statement
            .query_map(params![query, limit as i64], |r| Ok(Hit { path: r.get(0)?, title: r.get(1)?, snippet: r.get(2)? }))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(hits)
    }
}

impl Search {
    /// Every page with every word typed, in no order: for a query's
    /// `text:` condition.
    pub fn matching(db: &Connection, typed: &str) -> Result<Vec<String>> {
        let Some(query) = fts_query(typed) else { return Ok(Vec::new()) };
        let mut statement = db.prepare("SELECT path FROM search WHERE search MATCH ?1")?;
        let paths = statement.query_map([query], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(paths)
    }
}

/// What was typed, as an FTS5 query: each word quoted, so nothing typed
/// is taken for syntax, and the last one a prefix.
fn fts_query(typed: &str) -> Option<String> {
    let words: Vec<String> =
        typed.split(|c: char| !(c.is_alphanumeric() || c == '_')).filter(|word| !word.is_empty()).map(|word| format!("\"{word}\"")).collect();
    let (last, rest) = words.split_last()?;
    Some(rest.iter().cloned().chain([format!("{last}*")]).collect::<Vec<_>>().join(" "))
}

#[cfg(test)]
mod tests {
    #[test]
    fn typed_text_is_never_syntax() {
        assert_eq!(super::fts_query("kick-off NOT \"x\" (y)").as_deref(), Some("\"kick\" \"off\" \"NOT\" \"x\" \"y\"*"));
        assert_eq!(super::fts_query("  ").as_deref(), None);
        assert_eq!(super::fts_query("café").as_deref(), Some("\"café\"*"));
    }
}
