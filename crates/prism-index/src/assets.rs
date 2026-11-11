//! Assets: the files pages show, and which pages show them.

use crate::{seen, File, Index, Result};
use prism_markup::note::ASSETS_DIR;
use prism_markup::NoteKind;
use rusqlite::{params, Connection, Transaction};

/// Every file in `assets/`, and every picture a page shows from there.
/// What answers "where is this picture used?" and "which files does
/// nothing show any more?" without reading a single note.
pub struct Assets;

/// A page showing an asset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssetUse {
    /// The asset: its path in the graph.
    pub asset: String,
    /// The page showing it.
    pub path: String,
    /// The block it is shown in: an index a level.
    pub block: Vec<usize>,
}

fn is_asset(path: &str) -> bool {
    path.strip_prefix(ASSETS_DIR).is_some_and(|rest| rest.starts_with('/'))
}

impl Index for Assets {
    fn name(&self) -> &'static str {
        "assets"
    }

    fn version(&self) -> u32 {
        1
    }

    fn create(&self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS asset_files (path TEXT PRIMARY KEY) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS asset_uses (asset TEXT NOT NULL, path TEXT NOT NULL, block TEXT NOT NULL);
             CREATE INDEX IF NOT EXISTS asset_uses_asset ON asset_uses (asset);
             CREATE INDEX IF NOT EXISTS asset_uses_path ON asset_uses (path);",
        )?;
        Ok(())
    }

    fn clear(&self, tx: &Transaction<'_>) -> Result<()> {
        tx.execute_batch("DELETE FROM asset_files; DELETE FROM asset_uses;")?;
        Ok(())
    }

    /// Pages, and the files in `assets/`.
    fn wants(&self, path: &str) -> bool {
        NoteKind::of(path).is_some() || is_asset(path)
    }

    fn remove(&self, tx: &Transaction<'_>, path: &str) -> Result<()> {
        tx.execute("DELETE FROM asset_files WHERE path = ?1", [path])?;
        tx.execute("DELETE FROM asset_uses WHERE path = ?1", [path])?;
        Ok(())
    }

    fn put(&self, tx: &Transaction<'_>, file: &File<'_>) -> Result<()> {
        if is_asset(file.path) {
            // Only that it is there: its bytes are never read.
            tx.execute("INSERT OR IGNORE INTO asset_files (path) VALUES (?1)", [file.path])?;
            return Ok(());
        }
        let Some(note) = file.note() else { return Ok(()) };
        let mut insert = tx.prepare_cached("INSERT INTO asset_uses (asset, path, block) VALUES (?1, ?2, ?3)")?;
        for image in note.references().images {
            // What is on the web is no file of the graph's.
            let source = image.source.trim().trim_start_matches("./");
            if source.contains("://") || !is_asset(source) {
                continue;
            }
            let block = image.block.iter().map(usize::to_string).collect::<Vec<_>>().join(".");
            insert.execute(params![source, file.path, block])?;
        }
        Ok(())
    }
}

impl Assets {
    /// Every file in `assets/`, sorted.
    pub fn all(db: &Connection) -> Result<Vec<String>> {
        let mut statement = db.prepare("SELECT path FROM asset_files ORDER BY path")?;
        let files = statement.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(files)
    }

    /// The files in `assets/` that some page shows, sorted — a private
    /// page counted, whoever asks.
    pub fn shown(db: &Connection) -> Result<Vec<String>> {
        let mut statement =
            db.prepare("SELECT path FROM asset_files WHERE EXISTS (SELECT 1 FROM asset_uses WHERE asset_uses.asset = asset_files.path) ORDER BY path")?;
        let files = statement.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(files)
    }

    /// The pages showing an asset, by page, in reading order.
    pub fn used_in(db: &Connection, asset: &str) -> Result<Vec<AssetUse>> {
        let mut statement =
            db.prepare(&format!("SELECT asset, path, block FROM asset_uses WHERE asset = ?1 AND {} ORDER BY path, rowid", seen("asset_uses.path")))?;
        let uses = statement.query_map([asset], used)?.collect::<rusqlite::Result<_>>()?;
        Ok(uses)
    }

    /// The assets a page shows, in reading order.
    pub fn shown_in(db: &Connection, path: &str) -> Result<Vec<AssetUse>> {
        let mut statement = db.prepare(&format!("SELECT asset, path, block FROM asset_uses WHERE path = ?1 AND {} ORDER BY rowid", seen("asset_uses.path")))?;
        let uses = statement.query_map([path], used)?.collect::<rusqlite::Result<_>>()?;
        Ok(uses)
    }

    /// The files in `assets/` that no page shows — private pages counted,
    /// whoever asks: a file a private page shows is not one to clear out.
    pub fn unused(db: &Connection) -> Result<Vec<String>> {
        let mut statement =
            db.prepare("SELECT path FROM asset_files WHERE NOT EXISTS (SELECT 1 FROM asset_uses WHERE asset_uses.asset = asset_files.path) ORDER BY path")?;
        let files = statement.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(files)
    }

    /// The pictures pages show that are not there: each with the pages
    /// showing it.
    pub fn missing(db: &Connection) -> Result<Vec<AssetUse>> {
        let mut statement = db.prepare(&format!(
            "SELECT asset, path, block FROM asset_uses WHERE NOT EXISTS (SELECT 1 FROM asset_files WHERE asset_files.path = asset_uses.asset) AND {}
             ORDER BY asset, path, rowid",
            seen("asset_uses.path")
        ))?;
        let uses = statement.query_map([], used)?.collect::<rusqlite::Result<_>>()?;
        Ok(uses)
    }
}

fn used(row: &rusqlite::Row<'_>) -> rusqlite::Result<AssetUse> {
    let block: String = row.get(2)?;
    Ok(AssetUse { asset: row.get(0)?, path: row.get(1)?, block: block.split('.').filter_map(|part| part.parse().ok()).collect() })
}
