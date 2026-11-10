//! Links between pages: who points where, and so who points here.

use crate::{column_exists, seen, File, Index, Result};
use prism_markup::{name_key, river, LinkKind, NoteKind};
use rusqlite::{params, params_from_iter, Connection, Transaction};

/// Every pointer from one file of the graph at a page, by the name it
/// points at: `[[links]]`, `![[embeds]]`, `#tags`, and the links in a
/// frontmatter (`tags`, `related`, `list`, a field written `[[so]]`).
/// One table, because they are one thing — see
/// [`NoteLink`](prism_markup::NoteLink).
///
/// A link holds a name, not a path: it is resolved when asked about, so
/// a page made or renamed later is linked to by links written before it.
///
/// Saved rivers are read too. A river's cards are links, so a river
/// holding a page is among that page's backlinks — which is how a rename
/// finds the rivers to rewrite, without opening them all.
pub struct Links;

/// A link, seen from the page it leads to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Backlink {
    /// The file the link is written in: a page, or a saved river.
    pub source: String,
    /// The name it points at, as written.
    pub target: String,
    pub kind: LinkKind,
    /// The frontmatter key it is written under; `None` for one in the body.
    pub field: Option<String>,
    /// Where in the source's body it is: its block's path, an index a
    /// level — empty for one in the frontmatter.
    pub block: Vec<usize>,
    /// The text of that block, as Markdown: the link's surroundings, to
    /// show beside it — and what the block is known by when its path has
    /// moved ([`Document::locate`](prism_markup::Document::locate)).
    /// Empty for one in the frontmatter.
    pub context: String,
}

impl Index for Links {
    fn name(&self) -> &'static str {
        "links"
    }

    fn version(&self) -> u32 {
        3
    }

    fn create(&self, tx: &Transaction<'_>) -> Result<()> {
        // Earlier versions' tables had other columns: a table is not
        // altered by `IF NOT EXISTS`, so the old one goes — it is
        // rebuilt anyway.
        if column_exists(tx, "links", "source")? && !column_exists(tx, "links", "kind")? {
            tx.execute_batch("DROP TABLE links;")?;
        }
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS links (
                 source TEXT NOT NULL, key TEXT NOT NULL, target TEXT NOT NULL,
                 kind TEXT NOT NULL, field TEXT NOT NULL, block TEXT NOT NULL, context TEXT NOT NULL
             );
             CREATE INDEX IF NOT EXISTS links_key ON links (key);
             CREATE INDEX IF NOT EXISTS links_source ON links (source);",
        )?;
        Ok(())
    }

    fn clear(&self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute("DELETE FROM links", [])?;
        Ok(())
    }

    /// Pages, and saved rivers.
    fn wants(&self, path: &str) -> bool {
        NoteKind::of(path).is_some() || river::is_river(path)
    }

    fn remove(&self, tx: &Transaction<'_>, path: &str) -> Result<()> {
        tx.execute("DELETE FROM links WHERE source = ?1", [path])?;
        Ok(())
    }

    fn put(&self, tx: &Transaction<'_>, file: &File<'_>) -> Result<()> {
        // A river's file is Markdown, and reads as a note does.
        let parsed;
        let note = match file.note() {
            Some(note) => note,
            None => match file.text() {
                Some(text) => {
                    parsed = prism_markup::Note::parse(text);
                    &parsed
                }
                None => return Ok(()),
            },
        };
        let mut insert = tx.prepare_cached("INSERT INTO links (source, key, target, kind, field, block, context) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")?;
        for link in note.references().links {
            let block = link.block.iter().map(usize::to_string).collect::<Vec<_>>().join(".");
            let context = if link.field.is_some() { "" } else { note.body.get(&link.block).map_or("", |block| block.text.as_str()) };
            insert.execute(params![
                file.path,
                name_key(&link.target),
                link.target,
                kind_name(link.kind),
                link.field.as_deref().unwrap_or(""),
                block,
                context
            ])?;
        }
        Ok(())
    }
}

fn kind_name(kind: LinkKind) -> &'static str {
    match kind {
        LinkKind::Link => "link",
        LinkKind::Embed => "embed",
        LinkKind::Tag => "tag",
    }
}

const COLUMNS: &str = "source, target, kind, field, block, context";

fn backlink(row: &rusqlite::Row<'_>) -> rusqlite::Result<Backlink> {
    let (kind, field, block): (String, String, String) = (row.get(2)?, row.get(3)?, row.get(4)?);
    Ok(Backlink {
        source: row.get(0)?,
        target: row.get(1)?,
        kind: match kind.as_str() {
            "embed" => LinkKind::Embed,
            "tag" => LinkKind::Tag,
            _ => LinkKind::Link,
        },
        field: (!field.is_empty()).then_some(field),
        block: block.split('.').filter_map(|part| part.parse().ok()).collect(),
        context: row.get(5)?,
    })
}

/// The page a link's name leads to, as SQL: its title's before an
/// alias's. (A date not written yet leads to no page there is.)
pub(crate) const LEADS_TO: &str = "(SELECT path FROM note_names WHERE note_names.key = links.key ORDER BY rank, path LIMIT 1)";

impl Links {
    /// Every pointer at a page — links, embeds and tags alike — given
    /// every name it answers to (see [`Catalog::names`](crate::Catalog::names);
    /// for a day, its date). By source, in reading order within each.
    pub fn backlinks(db: &Connection, names: &[String]) -> Result<Vec<Backlink>> {
        if names.is_empty() {
            return Ok(Vec::new());
        }
        let placeholders = vec!["?"; names.len()].join(", ");
        let seen = seen("links.source");
        let mut statement = db.prepare(&format!("SELECT {COLUMNS} FROM links WHERE key IN ({placeholders}) AND {seen} ORDER BY source, rowid"))?;
        let links = statement.query_map(params_from_iter(names.iter().map(|n| name_key(n))), backlink)?.collect::<rusqlite::Result<_>>()?;
        Ok(links)
    }

    /// The links written in a file, in reading order: its body's, then
    /// its frontmatter's.
    pub fn outgoing(db: &Connection, source: &str) -> Result<Vec<Backlink>> {
        let seen = seen("links.source");
        let mut statement = db.prepare(&format!("SELECT {COLUMNS} FROM links WHERE source = ?1 AND {seen} ORDER BY rowid"))?;
        let links = statement.query_map([source], backlink)?.collect::<rusqlite::Result<_>>()?;
        Ok(links)
    }

    /// The pages a file links to, in the order it names them, each once:
    /// those of one frontmatter field (`Some("list")`), of its body
    /// (`Some("")`), or all of them (`None`). Tags are left out. What a
    /// hand-set order is read from — a page's `list`, a river's cards.
    /// Needs the [`Catalog`](crate::Catalog) in the same database.
    pub fn linked_pages(db: &Connection, source: &str, field: Option<&str>) -> Result<Vec<String>> {
        let seen = seen("links.source");
        let mut statement =
            db.prepare(&format!("SELECT {LEADS_TO} FROM links WHERE source = ?1 AND kind != 'tag' AND (?2 IS NULL OR field = ?2) AND {seen} ORDER BY rowid"))?;
        let mut known = std::collections::HashSet::new();
        let mut pages = Vec::new();
        for path in statement.query_map(params![source, field], |r| r.get::<_, Option<String>>(0))? {
            if let Some(path) = path? {
                if known.insert(path.clone()) {
                    pages.push(path);
                }
            }
        }
        Ok(pages)
    }

    /// The names linked to that no page answers to — pages waiting to be
    /// written — with how many links each has, most wanted first. Left
    /// out: dates (a day's page is always there to be written), tags
    /// (which need no page) and saved rivers (which are files, not
    /// pages). Needs the [`Catalog`](crate::Catalog) in the same database.
    pub fn unresolved(db: &Connection) -> Result<Vec<(String, usize)>> {
        let seen = seen("links.source");
        let mut statement = db.prepare(&format!(
            "SELECT min(target), count(*) AS wanted FROM links
             WHERE kind != 'tag' AND {seen} AND NOT EXISTS (SELECT 1 FROM note_names WHERE note_names.key = links.key)
             GROUP BY key ORDER BY wanted DESC, key"
        ))?;
        let rows: Vec<(String, usize)> = statement.query_map([], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? as usize)))?.collect::<rusqlite::Result<_>>()?;
        let waiting = |name: &str| prism_markup::Day::parse(name).is_none() && prism_markup::Week::parse(name).is_none() && river::name_of(name).is_none();
        Ok(rows.into_iter().filter(|(name, _)| waiting(name)).collect())
    }
}
