//! What pictures say: the words read in them.

use crate::{search::fts_query, Assets, Hit, Result, Search};
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashSet;
use std::path::Path;

/// The words in the graph's pictures — a screenshot's text, a
/// photographed page's, a sign's — so that a page is found by what its
/// pictures say as by what it says itself.
///
/// The words are not this crate's to read: an app reads them, with
/// whatever its device has for it, and tells them here.
/// [`unread`](Self::unread) says which pictures are still to be read;
/// [`read`](Self::read) keeps what one said; [`search`](Self::search)
/// finds pages by both.
///
/// Kept in a database of its own, beside the indices': the indices are
/// rebuilt from the graph's files whenever they must be, and reading a
/// picture is too slow to do again each time. Like them it is derived,
/// never synced, and every device builds its own.
pub struct Pictures {
    connection: Connection,
}

/// The files that are pictures with words to read, by how their names end.
const KINDS: [&str; 10] = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"];

fn is_picture(path: &str) -> bool {
    path.rsplit_once('.').is_some_and(|(_, kind)| KINDS.iter().any(|known| kind.eq_ignore_ascii_case(known)))
}

impl Pictures {
    /// Opens (or makes) the database at `path`.
    pub fn open(path: impl AsRef<Path>) -> Result<Pictures> {
        let connection = Connection::open(path)?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "synchronous", "NORMAL")?;
        Pictures::with_connection(connection)
    }

    /// A database in memory: for tests.
    pub fn in_memory() -> Result<Pictures> {
        Pictures::with_connection(Connection::open_in_memory()?)
    }

    fn with_connection(connection: Connection) -> Result<Pictures> {
        connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS picture_words (asset TEXT PRIMARY KEY, words TEXT NOT NULL) WITHOUT ROWID;
             CREATE VIRTUAL TABLE IF NOT EXISTS picture_search USING fts5(asset UNINDEXED, words, tokenize = 'unicode61 remove_diacritics 2');",
        )?;
        Ok(Pictures { connection })
    }

    /// The pictures pages show that are there and have not been read:
    /// at most `limit` of them, sorted. `db` is the indices'.
    pub fn unread(&self, db: &Connection, limit: usize) -> Result<Vec<String>> {
        let mut known = self.connection.prepare("SELECT asset FROM picture_words")?;
        let known: HashSet<String> = known.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(Assets::shown(db)?.into_iter().filter(|asset| is_picture(asset) && !known.contains(asset)).take(limit).collect())
    }

    /// Keeps what a picture says — nothing, for one with no words in it:
    /// it has been read all the same, and is not asked for again.
    pub fn read(&mut self, asset: &str, words: &str) -> Result<()> {
        let words = words.split_whitespace().collect::<Vec<_>>().join(" ");
        let tx = self.connection.transaction()?;
        tx.execute("DELETE FROM picture_search WHERE asset = ?1", [asset])?;
        tx.execute("INSERT OR REPLACE INTO picture_words (asset, words) VALUES (?1, ?2)", params![asset, words])?;
        if !words.is_empty() {
            tx.execute("INSERT INTO picture_search (asset, words) VALUES (?1, ?2)", params![asset, words])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// What a picture was read to say, if it has been read.
    pub fn words(&self, asset: &str) -> Result<Option<String>> {
        Ok(self.connection.query_row("SELECT words FROM picture_words WHERE asset = ?1", [asset], |r| r.get(0)).optional()?)
    }

    /// The pictures saying every word typed, best first, each with the
    /// words around the first match — the matched ones between `[` and `]`.
    pub fn saying(&self, typed: &str, limit: usize) -> Result<Vec<(String, String)>> {
        let Some(query) = fts_query(typed) else { return Ok(Vec::new()) };
        let mut statement = self.connection.prepare(
            "SELECT asset, snippet(picture_search, 1, '[', ']', '…', 12) FROM picture_search WHERE picture_search MATCH ?1 ORDER BY bm25(picture_search), asset LIMIT ?2",
        )?;
        let found = statement.query_map(params![query, limit as i64], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?;
        Ok(found)
    }

    /// As [`Search::search`], and after the pages that say the words
    /// themselves, the pages showing a picture that says them: each
    /// once, its snippet the picture's words. `db` is the indices', and
    /// what it may see is what is found: a private page's pictures are
    /// as private as it is.
    pub fn search(&self, db: &Connection, typed: &str, limit: usize) -> Result<Vec<Hit>> {
        let mut hits = Search::search(db, typed, limit)?;
        if hits.len() >= limit {
            return Ok(hits);
        }
        let mut found: HashSet<String> = hits.iter().map(|hit| hit.path.clone()).collect();
        let mut title = db.prepare_cached("SELECT label FROM notes WHERE path = ?1")?;
        for (asset, snippet) in self.saying(typed, limit)? {
            for shown in Assets::used_in(db, &asset)? {
                if hits.len() >= limit {
                    return Ok(hits);
                }
                if !found.insert(shown.path.clone()) {
                    continue;
                }
                let Some(title) = title.query_row([&shown.path], |r| r.get(0)).optional()? else { continue };
                hits.push(Hit { path: shown.path, title, snippet: snippet.clone() });
            }
        }
        Ok(hits)
    }
}
