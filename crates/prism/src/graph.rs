//! A graph's files: reading and writing notes where the graph keeps them.
//!
//! [`Graph`] is a folder and the conventions for what goes where —
//! `daily/2026-10-31.md`, `notes/project-atlas.md`, `assets/…`. It reads
//! and writes; it does not sync, index or watch (the [`Engine`](crate::Engine)
//! does), so it is cheap, has no state, and can be used from any thread.
//!
//! Writing is careful in three ways: a file is written **atomically**
//! (never seen half-written by another app or a sync); **only when it
//! differs** (so nothing is touched, or committed, for a save that
//! changed nothing); and **never over what it has not seen** — a draft
//! saved over a file that changed underneath it is merged with it
//! ([`Graph::save_merging`]).

use crate::note_merge::merge_notes;
use crate::{Error, Result};
use prism_markup::{river, Block, Day, Note, NoteKind, River, Week};
use prism_sync::textmerge::{self, Labels};
use std::path::{Path, PathBuf};
use unicode_normalization::UnicodeNormalization;

/// A graph: a folder of notes.
#[derive(Debug, Clone)]
pub struct Graph {
    root: PathBuf,
}

/// What [`Graph::rename_note`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Renamed {
    pub old_title: String,
    pub new_title: String,
    /// Every file rewritten: the page itself, the pages that linked to
    /// it, the rivers that held it.
    pub rewritten: Vec<String>,
}

/// How [`Graph::save_merging`] ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Saved {
    /// What the file holds now: the draft, or the draft merged with what
    /// had changed on disk. The editor shows this, and takes it as the
    /// base of its next save.
    pub content: String,
    /// Whether the file had changed underneath the draft.
    pub merged: bool,
    /// Whether the merge left lines for a person to settle.
    pub conflicted: bool,
}

impl Graph {
    /// The graph in a folder, which must be there.
    pub fn open(root: impl Into<PathBuf>) -> Result<Graph> {
        let root = root.into();
        if !root.is_dir() {
            return Err(Error::NotAGraph(root));
        }
        Ok(Graph { root })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Where a graph-relative path is on disk. Refuses a path that could
    /// lead out of the graph, or into its `.git`.
    pub fn locate(&self, path: &str) -> Result<PathBuf> {
        let safe = !path.is_empty()
            && !path.starts_with('/')
            && !path.contains('\\')
            && path.split('/').all(|part| !part.is_empty() && part != "." && part != ".." && part != ".git");
        if safe {
            Ok(self.root.join(path))
        } else {
            Err(Error::BadPath(path.to_owned()))
        }
    }

    // --- Reading -----------------------------------------------------------

    /// A file's text; `None` when there is no such file.
    pub fn read(&self, path: &str) -> Result<Option<String>> {
        match std::fs::read_to_string(self.locate(path)?) {
            Ok(text) => Ok(Some(text)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(Error::io(format!("reading {path}"), e)),
        }
    }

    /// A note, read. `None` when there is no such file.
    pub fn note(&self, path: &str) -> Result<Option<Note>> {
        Ok(self.read(path)?.map(|text| Note::parse(&text)))
    }

    /// A day's page: empty, when nothing was written that day. A day is
    /// always there to be written in.
    pub fn day(&self, day: Day) -> Result<Note> {
        Ok(self.note(&NoteKind::day_path(day))?.unwrap_or_default())
    }

    /// A week's page: empty, when nothing was written.
    pub fn week(&self, week: Week) -> Result<Note> {
        Ok(self.note(&NoteKind::week_path(week))?.unwrap_or_default())
    }

    pub fn exists(&self, path: &str) -> bool {
        self.locate(path).is_ok_and(|file| file.is_file())
    }

    /// Every page's path, sorted: `daily/`, `weekly/` and `notes/`, as far
    /// down as they go. For a first look; once an [`Engine`](crate::Engine)
    /// runs, ask its catalog.
    pub fn note_paths(&self) -> Vec<String> {
        fn walk(directory: &Path, prefix: &str, out: &mut Vec<String>) {
            let Ok(entries) = std::fs::read_dir(directory) else { return };
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') {
                    continue;
                }
                let path = format!("{prefix}/{name}");
                if entry.path().is_dir() {
                    walk(&entry.path(), &path, out);
                } else if NoteKind::of(&path).is_some() {
                    out.push(path);
                }
            }
        }
        let mut paths = Vec::new();
        for directory in [prism_markup::note::DAILY_DIR, prism_markup::note::WEEKLY_DIR, prism_markup::note::NOTES_DIR] {
            walk(&self.root.join(directory), directory, &mut paths);
        }
        paths.sort();
        paths
    }

    // --- Writing -----------------------------------------------------------

    /// Writes a file — atomically, and only when what would be written
    /// differs from what is there. Says whether it wrote.
    pub fn write(&self, path: &str, content: &str) -> Result<bool> {
        if self.read(path)?.as_deref() == Some(content) {
            return Ok(false);
        }
        self.write_bytes(path, content.as_bytes())?;
        Ok(true)
    }

    fn write_bytes(&self, path: &str, content: &[u8]) -> Result<()> {
        let file = self.locate(path)?;
        let parent = file.parent().unwrap_or(&self.root);
        std::fs::create_dir_all(parent).map_err(|e| Error::io(format!("making the folder for {path}"), e))?;
        let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let temporary = parent.join(format!(".{name}.prism-{}", std::process::id()));
        std::fs::write(&temporary, content).and_then(|()| std::fs::rename(&temporary, &file)).map_err(|e| {
            let _ = std::fs::remove_file(&temporary);
            Error::io(format!("writing {path}"), e)
        })
    }

    /// Writes a note. See [`write`](Self::write).
    pub fn save(&self, path: &str, note: &Note) -> Result<bool> {
        self.write(path, &note.to_markdown())
    }

    /// Saves a draft over a file that may have changed since the draft
    /// was opened — by a sync, or another app. `base` is the file as the
    /// editor last saw it (`None`: it did not exist).
    ///
    /// When the file is still as the editor saw it, the draft is written.
    /// When it is not, nothing is overwritten: the draft and the file are
    /// merged from `base` — a note's frontmatter field by field, its body
    /// by lines — and where both changed the same lines, both are kept
    /// between conflict markers, the draft's first.
    pub fn save_merging(&self, path: &str, draft: &str, base: Option<&str>) -> Result<Saved> {
        let on_disk = self.read(path)?;
        if on_disk.as_deref() == base || on_disk.as_deref() == Some(draft) {
            self.write(path, draft)?;
            return Ok(Saved { content: draft.to_owned(), merged: false, conflicted: false });
        }
        // Deleted underneath a draft still being written: the draft stays.
        let Some(theirs) = on_disk else {
            self.write(path, draft)?;
            return Ok(Saved { content: draft.to_owned(), merged: true, conflicted: false });
        };
        let labels = Labels::default();
        let merged = merge_notes(base, draft, &theirs, labels).unwrap_or_else(|| textmerge::merge_lenient(base.unwrap_or(""), draft, &theirs, labels));
        self.write(path, &merged.text)?;
        Ok(Saved { content: merged.text, merged: true, conflicted: merged.conflicted })
    }

    /// Deletes a file. Says whether it was there.
    pub fn delete(&self, path: &str) -> Result<bool> {
        match std::fs::remove_file(self.locate(path)?) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(Error::io(format!("deleting {path}"), e)),
        }
    }

    // --- Renaming ----------------------------------------------------------

    /// Renames a page: retitles it where its title is written, and makes
    /// every page in `linking` — and every saved river — name the new
    /// title where it named the old. The page's file stays where it is;
    /// its `id` and its path are what do not change.
    ///
    /// `linking` is the pages that may link to it: its backlinks, from
    /// the index ([`Engine::rename_note`](crate::Engine::rename_note)
    /// finds them). A page listed that has no such link is left alone.
    pub fn rename_note(&self, path: &str, new_title: &str, linking: &[String]) -> Result<Renamed> {
        let new_title = new_title.trim();
        if NoteKind::of(path) != Some(NoteKind::Note) || new_title.is_empty() {
            return Err(Error::NotRenamable(path.to_owned()));
        }
        let mut note = self.note(path)?.ok_or_else(|| Error::NotRenamable(path.to_owned()))?;
        let old_title = note.title(path);
        let mut renamed = Renamed { old_title: old_title.clone(), new_title: new_title.to_owned(), rewritten: Vec::new() };
        if old_title == new_title {
            return Ok(renamed);
        }
        note.set_title(new_title);
        // A page may link to itself.
        note.relink(&old_title, new_title);
        self.save(path, &note)?;
        renamed.rewritten.push(path.to_owned());
        for source in linking.iter().filter(|source| source.as_str() != path) {
            let Some(mut linking_note) = self.note(source)? else { continue };
            if linking_note.relink(&old_title, new_title) > 0 && self.save(source, &linking_note)? {
                renamed.rewritten.push(source.clone());
            }
        }
        for name in self.river_names() {
            let Some(mut river) = self.river(&name)? else { continue };
            if river.rename(&old_title, new_title) && self.save_river(&name, &river)? {
                renamed.rewritten.push(river::path(&name));
            }
        }
        Ok(renamed)
    }

    // --- Rivers ------------------------------------------------------------

    /// The graph's saved rivers, by name, sorted.
    pub fn river_names(&self) -> Vec<String> {
        let Ok(entries) = std::fs::read_dir(self.root.join(river::RIVERS_DIR)) else { return Vec::new() };
        let mut names: Vec<String> = entries
            .flatten()
            .filter_map(|entry| entry.file_name().to_str().map(str::to_owned))
            .filter(|name| !name.starts_with('.'))
            .filter_map(|name| name.strip_suffix(".md").map(str::to_owned))
            .collect();
        names.sort_by_key(|name| name.to_lowercase());
        names
    }

    /// A saved river; `None` when none has the name.
    pub fn river(&self, name: &str) -> Result<Option<River>> {
        Ok(self.read(&river::path(name))?.map(|text| River::parse(&text)))
    }

    /// Saves a river under a name. Says whether its file changed.
    pub fn save_river(&self, name: &str, river: &River) -> Result<bool> {
        self.write(&river::path(name), &river.to_markdown())
    }

    pub fn delete_river(&self, name: &str) -> Result<bool> {
        self.delete(&river::path(name))
    }

    // --- New things --------------------------------------------------------

    /// The path a new page of this title takes: a date's, its day's; a
    /// week's, its week's; else `notes/<slug>.md` — or the first of
    /// `-2`, `-3`, … that no file has.
    pub fn path_for_title(&self, title: &str) -> String {
        let title = title.trim();
        if let Some(day) = Day::parse(title) {
            return NoteKind::day_path(day);
        }
        if let Some(week) = Week::parse(title) {
            return NoteKind::week_path(week);
        }
        let slug = slug(title);
        self.free_path(|attempt| match attempt {
            1 => format!("notes/{slug}.md"),
            n => format!("notes/{slug}-{n}.md"),
        })
    }

    fn free_path(&self, candidate: impl Fn(usize) -> String) -> String {
        (1..).map(candidate).find(|path| !self.root.join(path).exists()).unwrap_or_default()
    }

    /// Makes a new note with a title: `notes/<slug>.md`, with a ULID `id`
    /// and the title as its first heading. A day's or week's title makes
    /// that page, which is named by its file and needs neither. Returns
    /// the path; a page already there is left as it is.
    pub fn create_note(&self, title: &str) -> Result<String> {
        let path = self.path_for_title(title);
        if self.exists(&path) {
            return Ok(path);
        }
        let mut note = Note::default();
        note.body.final_newline = true;
        if NoteKind::of(&path) == Some(NoteKind::Note) {
            note.frontmatter_mut().set("id", ulid());
            note.body.blocks.push(Block::heading(1, title.trim()));
        } else {
            note.body.blocks.push(Block::bullet(""));
        }
        self.save(&path, &note)?;
        Ok(path)
    }

    /// Keeps a file in `assets/` under a readable form of its name
    /// (`Q3 Report (final).PDF` → `assets/q3-report-final.pdf`), or the
    /// first `-2`, `-3`, … variant no file has. Nothing already there is
    /// ever written over. Returns the path to link to.
    pub fn add_asset(&self, name: &str, content: &[u8]) -> Result<String> {
        let (stem, extension) = match name.rsplit_once('.') {
            Some((stem, extension)) if !stem.is_empty() && !extension.is_empty() && extension.chars().all(char::is_alphanumeric) => {
                (stem, format!(".{}", extension.to_lowercase()))
            }
            _ => (name, String::new()),
        };
        let slug = slug(stem);
        let path = self.free_path(|attempt| match attempt {
            1 => format!("assets/{slug}{extension}"),
            n => format!("assets/{slug}-{n}{extension}"),
        });
        self.write_bytes(&path, content)?;
        Ok(path)
    }
}

/// A title as a file's name: lowercase, letters and digits of any script
/// kept, runs of spaces and separators one dash, at most 60 characters,
/// never empty, never a name Windows reserves.
pub fn slug(title: &str) -> String {
    let mut result = String::new();
    let mut pending_dash = false;
    for c in title.nfc().flat_map(char::to_lowercase) {
        if c.is_whitespace() || c == '_' || c == '-' {
            pending_dash = true;
        } else if c.is_alphanumeric() {
            if pending_dash && !result.is_empty() {
                result.push('-');
            }
            pending_dash = false;
            result.push(c);
        }
        // Anything else is dropped, and does not end a run of separators.
    }
    let mut capped: String = result.chars().take(60).collect();
    while capped.ends_with('-') {
        capped.pop();
    }
    const RESERVED: [&str; 22] = [
        "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6",
        "lpt7", "lpt8", "lpt9",
    ];
    if capped.is_empty() {
        "untitled".into()
    } else if RESERVED.contains(&capped.as_str()) {
        format!("{capped}-note")
    } else {
        capped
    }
}

/// A new ULID, lowercase: 48 bits of the time, 80 of chance. A note's
/// lasting identity.
pub fn ulid() -> String {
    use std::hash::{BuildHasher, Hasher};
    const ALPHABET: &[u8; 32] = b"0123456789abcdefghjkmnpqrstvwxyz";
    let mut millis = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
    let mut text = [b'0'; 26];
    for slot in text[..10].iter_mut().rev() {
        *slot = ALPHABET[(millis % 32) as usize];
        millis /= 32;
    }
    // The standard library's hasher keys are the system's randomness.
    let random = || std::collections::hash_map::RandomState::new().build_hasher().finish();
    let (mut high, mut low) = (random(), random());
    for (index, slot) in text[10..].iter_mut().enumerate() {
        let source = if index < 8 { &mut high } else { &mut low };
        *slot = ALPHABET[(*source % 32) as usize];
        *source /= 32;
    }
    String::from_utf8_lossy(&text).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn graph() -> (tempfile::TempDir, Graph) {
        let dir = tempfile::tempdir().unwrap();
        let graph = Graph::open(dir.path()).unwrap();
        (dir, graph)
    }

    #[test]
    fn slugs() {
        assert_eq!(slug("Project Atlas"), "project-atlas");
        assert_eq!(slug("  Q3 Report (final)  "), "q3-report-final");
        assert_eq!(slug("snake_case -- and — dashes"), "snake-case-and-dashes");
        assert_eq!(slug("Café Ünïcode 日本語"), "café-ünïcode-日本語");
        assert_eq!(slug("e\u{301}"), "é", "composed, as a file system would name it");
        assert_eq!(slug("!!!"), "untitled");
        assert_eq!(slug("CON"), "con-note");
        assert_eq!(slug(&"long word ".repeat(20)).chars().count(), 59);
        assert!(!slug(&"ab ".repeat(40)).ends_with('-'));
    }

    #[test]
    fn ulids_are_ulids_and_sort_by_time() {
        let first = ulid();
        assert!(prism_markup::note::is_ulid(&first), "{first}");
        std::thread::sleep(std::time::Duration::from_millis(3));
        let second = ulid();
        assert!(second > first);
        assert_ne!(ulid()[10..], ulid()[10..]);
    }

    #[test]
    fn writes_only_what_differs_and_reads_it_back() {
        let (_dir, graph) = graph();
        assert_eq!(graph.read("notes/a.md").unwrap(), None);
        assert!(graph.write("notes/deep/a.md", "# A\n").unwrap());
        assert!(!graph.write("notes/deep/a.md", "# A\n").unwrap(), "the same text is not written again");
        assert_eq!(graph.note("notes/deep/a.md").unwrap().unwrap().title("notes/deep/a.md"), "A");
        assert!(graph.exists("notes/deep/a.md"));
        assert_eq!(graph.note_paths(), ["notes/deep/a.md"]);
        assert!(graph.delete("notes/deep/a.md").unwrap());
        assert!(!graph.delete("notes/deep/a.md").unwrap());
        // No temporary files are left behind.
        assert_eq!(std::fs::read_dir(graph.root().join("notes/deep")).unwrap().count(), 0);
    }

    #[test]
    fn paths_cannot_leave_the_graph() {
        let (_dir, graph) = graph();
        for path in ["../outside.md", "/etc/passwd", "notes/../../x.md", ".git/config", "notes//a.md", "", "notes\\a.md", "./a.md"] {
            assert!(matches!(graph.write(path, "x"), Err(Error::BadPath(_))), "{path}");
            assert!(graph.read(path).is_err(), "{path}");
        }
        assert!(Graph::open("/nonexistent/graph").is_err());
    }

    #[test]
    fn days_are_always_there() {
        let (_dir, graph) = graph();
        let day = Day::parse("2026-10-31").unwrap();
        assert!(graph.day(day).unwrap().body.is_blank());
        graph.write("daily/2026-10-31.md", "- written\n").unwrap();
        assert_eq!(graph.day(day).unwrap().body.blocks[0].text, "written");
        assert!(graph.week(day.week()).unwrap().body.is_blank());
    }

    #[test]
    fn new_notes_get_a_path_an_id_and_a_heading() {
        let (_dir, graph) = graph();
        let path = graph.create_note("Project Atlas").unwrap();
        assert_eq!(path, "notes/project-atlas.md");
        let text = graph.read(&path).unwrap().unwrap();
        let note = Note::parse(&text);
        assert!(prism_markup::note::is_ulid(note.field("id").unwrap()));
        assert_eq!(text, format!("---\nid: {}\n---\n# Project Atlas\n", note.field("id").unwrap()));
        // A page already there is left alone, and found again.
        assert_eq!(graph.create_note("2026-10-31").unwrap(), "daily/2026-10-31.md");
        assert_eq!(graph.read("daily/2026-10-31.md").unwrap().unwrap(), "- \n");
        graph.write("daily/2026-10-31.md", "- kept\n").unwrap();
        graph.create_note("2026-10-31").unwrap();
        assert_eq!(graph.read("daily/2026-10-31.md").unwrap().unwrap(), "- kept\n");
        assert_eq!(graph.create_note("2026-W44").unwrap(), "weekly/2026-W44.md");
        // A slug in use gets a number.
        assert_eq!(graph.path_for_title("project atlas!"), "notes/project-atlas-2.md");
        graph.write("notes/project-atlas-2.md", "x").unwrap();
        assert_eq!(graph.path_for_title("Project  Atlas"), "notes/project-atlas-3.md");
    }

    #[test]
    fn assets_are_named_readably_and_never_overwritten() {
        let (_dir, graph) = graph();
        assert_eq!(graph.add_asset("Q3 Report (final).PDF", b"one").unwrap(), "assets/q3-report-final.pdf");
        assert_eq!(graph.add_asset("Q3 Report (final).PDF", b"two").unwrap(), "assets/q3-report-final-2.pdf");
        assert_eq!(graph.add_asset("no extension", b"x").unwrap(), "assets/no-extension");
        assert_eq!(graph.add_asset(".hidden", b"x").unwrap(), "assets/hidden");
        assert_eq!(std::fs::read(graph.root().join("assets/q3-report-final.pdf")).unwrap(), b"one");
    }

    #[test]
    fn renaming_retitles_the_page_and_relinks_the_rest() {
        let (_dir, graph) = graph();
        graph.write("notes/atlas.md", "---\nid: 01jbxk3t6y8q2zp4m9v7c5r0wd\n---\n# Project Atlas\n\n- about [[Project Atlas]] itself\n").unwrap();
        graph.write("notes/ada.md", "# Ada\n\nWorks on [[project atlas|the project]].\n").unwrap();
        graph.write("notes/other.md", "# Other\n\nNo link here.\n").unwrap();
        graph.write("daily/2026-10-31.md", "- [[Project Atlas]] kick-off\n").unwrap();
        let mut river = River::default();
        river.cards = vec![prism_markup::river::Card::new("Project Atlas"), prism_markup::river::Card::new("Ada")];
        river.folded = vec!["Project Atlas".into()];
        assert!(graph.save_river("Work", &river).unwrap());
        assert_eq!(graph.river_names(), ["Work"]);

        let linking = vec!["notes/ada.md".to_owned(), "notes/other.md".to_owned(), "daily/2026-10-31.md".to_owned(), "notes/gone.md".to_owned()];
        let renamed = graph.rename_note("notes/atlas.md", " Atlas Reborn ", &linking).unwrap();
        assert_eq!(renamed.old_title, "Project Atlas");
        assert_eq!(renamed.rewritten, ["notes/atlas.md", "notes/ada.md", "daily/2026-10-31.md", "rivers/Work.md"]);
        assert_eq!(
            graph.read("notes/atlas.md").unwrap().unwrap(),
            "---\nid: 01jbxk3t6y8q2zp4m9v7c5r0wd\n---\n# Atlas Reborn\n\n- about [[Atlas Reborn]] itself\n"
        );
        assert_eq!(graph.read("notes/ada.md").unwrap().unwrap(), "# Ada\n\nWorks on [[Atlas Reborn|the project]].\n");
        assert_eq!(graph.read("daily/2026-10-31.md").unwrap().unwrap(), "- [[Atlas Reborn]] kick-off\n");
        assert_eq!(graph.read("rivers/Work.md").unwrap().unwrap(), "---\nfolded:\n  - Atlas Reborn\n---\n- [[Atlas Reborn]]\n- [[Ada]]\n");
        assert_eq!(graph.river("Work").unwrap().unwrap().titles().collect::<Vec<_>>(), ["Atlas Reborn", "Ada"]);

        // The same title again changes nothing; a day cannot be renamed.
        assert!(graph.rename_note("notes/atlas.md", "Atlas Reborn", &linking).unwrap().rewritten.is_empty());
        assert!(matches!(graph.rename_note("daily/2026-10-31.md", "Halloween", &[]), Err(Error::NotRenamable(_))));
        assert!(matches!(graph.rename_note("notes/missing.md", "X", &[]), Err(Error::NotRenamable(_))));
        assert!(graph.delete_river("Work").unwrap());
        assert!(graph.river("Work").unwrap().is_none() && graph.river_names().is_empty());
    }

    #[test]
    fn a_draft_is_merged_with_what_changed_underneath_it() {
        let (_dir, graph) = graph();
        let base = "---\ntags: [a]\n---\n- one\n- two\n";
        graph.write("notes/n.md", base).unwrap();
        // Nothing changed underneath: the draft is simply written.
        let draft = base.replace("- one", "- ONE");
        let saved = graph.save_merging("notes/n.md", &draft, Some(base)).unwrap();
        assert_eq!(saved, Saved { content: draft.clone(), merged: false, conflicted: false });

        // A sync writes the file while the editor holds a newer draft.
        let synced = draft.replace("[a]", "[a, b]").replace("- two", "- TWO");
        graph.write("notes/n.md", &synced).unwrap();
        let newer = draft.replace("- ONE", "- ONE!");
        let saved = graph.save_merging("notes/n.md", &newer, Some(&draft)).unwrap();
        assert_eq!(saved.content, "---\ntags: [a, b]\n---\n- ONE!\n- TWO\n");
        assert!(saved.merged && !saved.conflicted);
        assert_eq!(graph.read("notes/n.md").unwrap().unwrap(), saved.content);

        // Both changed the same line: both kept, to settle.
        graph.write("notes/n.md", &saved.content.replace("- TWO", "- theirs")).unwrap();
        let clash = graph.save_merging("notes/n.md", &saved.content.replace("- TWO", "- mine"), Some(&saved.content)).unwrap();
        assert!(clash.conflicted);
        assert!(clash.content.contains("<<<<<<< this device\n- mine\n=======\n- theirs\n>>>>>>> other device\n"));

        // Deleted underneath, or never there: the draft is kept.
        graph.delete("notes/n.md").unwrap();
        assert!(graph.save_merging("notes/n.md", "still here\n", Some("was\n")).unwrap().merged);
        assert_eq!(graph.read("notes/n.md").unwrap().unwrap(), "still here\n");
        assert!(!graph.save_merging("notes/new.md", "new\n", None).unwrap().merged);
        // Plain text, no frontmatter, merges by lines.
        graph.write("notes/p.md", "a\nb\nc changed\n").unwrap();
        assert_eq!(graph.save_merging("notes/p.md", "A\nb\nc\n", Some("a\nb\nc\n")).unwrap().content, "A\nb\nc changed\n");
    }
}
