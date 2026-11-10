//! Links between pages: who links where, and so who links here.

use crate::{File, Index, Result};
use prism_markup::name_key;
use rusqlite::{params, params_from_iter, Connection, Transaction};

/// Every `[[link]]`, `![[embed]]` and `related:` entry in the graph, by
/// the name it links to. A link holds a name, not a path: it is resolved
/// when asked about, so a page made or renamed later is linked to by
/// links written before it.
pub struct Links;

/// A link, seen from the page it leads to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Backlink {
    /// The page the link is written in.
    pub source: String,
    /// The name it links to, as written.
    pub target: String,
    pub embed: bool,
    /// Where in the source the link is: its block's path, an index a
    /// level — empty for one in the frontmatter's `related`.
    pub block: Vec<usize>,
}

impl Index for Links {
    fn name(&self) -> &'static str {
        "links"
    }

    fn version(&self) -> u32 {
        1
    }

    fn create(&self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS links (source TEXT NOT NULL, key TEXT NOT NULL, target TEXT NOT NULL, embed INTEGER NOT NULL, block TEXT NOT NULL);
             CREATE INDEX IF NOT EXISTS links_key ON links (key);
             CREATE INDEX IF NOT EXISTS links_source ON links (source);",
        )?;
        Ok(())
    }

    fn clear(&self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute("DELETE FROM links", [])?;
        Ok(())
    }

    fn remove(&self, tx: &Transaction<'_>, path: &str) -> Result<()> {
        tx.execute("DELETE FROM links WHERE source = ?1", [path])?;
        Ok(())
    }

    fn put(&self, tx: &Transaction<'_>, file: &File<'_>) -> Result<()> {
        let Some(note) = file.note() else { return Ok(()) };
        let mut insert = tx.prepare_cached("INSERT INTO links (source, key, target, embed, block) VALUES (?1, ?2, ?3, ?4, ?5)")?;
        for link in note.references().links {
            let block = link.block.iter().map(usize::to_string).collect::<Vec<_>>().join(".");
            insert.execute(params![file.path, name_key(&link.target), link.target, link.embed, block])?;
        }
        Ok(())
    }
}

fn backlink(row: &rusqlite::Row<'_>) -> rusqlite::Result<Backlink> {
    let block: String = row.get(3)?;
    Ok(Backlink { source: row.get(0)?, target: row.get(1)?, embed: row.get(2)?, block: block.split('.').filter_map(|part| part.parse().ok()).collect() })
}

impl Links {
    /// The links to a page, given every name it answers to (see
    /// [`Catalog::names`](crate::Catalog::names); for a day, its date).
    /// By source, in reading order within each.
    pub fn backlinks(db: &Connection, names: &[String]) -> Result<Vec<Backlink>> {
        if names.is_empty() {
            return Ok(Vec::new());
        }
        let placeholders = vec!["?"; names.len()].join(", ");
        let mut statement = db.prepare(&format!("SELECT source, target, embed, block FROM links WHERE key IN ({placeholders}) ORDER BY source, rowid"))?;
        let links = statement.query_map(params_from_iter(names.iter().map(|n| name_key(n))), backlink)?.collect::<rusqlite::Result<_>>()?;
        Ok(links)
    }

    /// The links written in a page, in reading order.
    pub fn outgoing(db: &Connection, source: &str) -> Result<Vec<Backlink>> {
        let mut statement = db.prepare("SELECT source, target, embed, block FROM links WHERE source = ?1 ORDER BY rowid")?;
        let links = statement.query_map([source], backlink)?.collect::<rusqlite::Result<_>>()?;
        Ok(links)
    }

    /// The names linked to that no page answers to — pages waiting to be
    /// written — with how many links each has, most wanted first. Dates
    /// are left out: a day's page is always there to be written. Needs
    /// the [`Catalog`](crate::Catalog) in the same database.
    pub fn unresolved(db: &Connection) -> Result<Vec<(String, usize)>> {
        let mut statement = db.prepare(
            "SELECT min(target), count(*) AS wanted FROM links
             WHERE NOT EXISTS (SELECT 1 FROM note_names WHERE note_names.key = links.key)
             GROUP BY key ORDER BY wanted DESC, key",
        )?;
        let rows: Vec<(String, usize)> = statement.query_map([], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? as usize)))?.collect::<rusqlite::Result<_>>()?;
        Ok(rows.into_iter().filter(|(name, _)| prism_markup::Day::parse(name).is_none() && prism_markup::Week::parse(name).is_none()).collect())
    }
}
