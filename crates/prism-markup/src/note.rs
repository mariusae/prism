//! A note: one Markdown file of a graph, read whole.
//!
//! [`Note`] is a file's two parts — its [`Frontmatter`], when it has one,
//! and its body as a [`Document`] — and what the two say together: the
//! note's title and names, its tags, the notes it links to, its pictures
//! and its tasks. Where a note lives says what kind of page it is
//! ([`NoteKind`]): `daily/2026-10-31.md` is a day's page whatever is
//! written in it.

use crate::block::{Block, BlockKind, Document, Task};
use crate::date::{Day, Timestamp, Week};
use crate::frontmatter::Frontmatter;
use crate::inline::{self, SpanKind};

/// Where a graph keeps its pages.
pub const DAILY_DIR: &str = "daily";
pub const WEEKLY_DIR: &str = "weekly";
pub const NOTES_DIR: &str = "notes";
/// Where a graph keeps pictures and other files its pages show.
pub const ASSETS_DIR: &str = "assets";

/// What a page is, by where its file is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NoteKind {
    /// `daily/YYYY-MM-DD.md`.
    Day(Day),
    /// `weekly/YYYY-Www.md`.
    Week(Week),
    /// `notes/**/*.md`: every other page.
    Note,
}

impl NoteKind {
    /// The kind of page at a graph-relative path, or `None` for a file
    /// that is no page: a picture, a README, a note outside the folders.
    pub fn of(path: &str) -> Option<NoteKind> {
        let stem = path.strip_suffix(".md")?;
        if let Some(name) = stem.strip_prefix("daily/") {
            return Day::parse(name).map(NoteKind::Day);
        }
        if let Some(name) = stem.strip_prefix("weekly/") {
            return Week::parse(name).map(NoteKind::Week);
        }
        (stem.starts_with("notes/") && !stem.ends_with('/')).then_some(NoteKind::Note)
    }

    /// The path a day's page is kept at.
    pub fn day_path(day: Day) -> String {
        format!("{DAILY_DIR}/{day}.md")
    }

    /// The path a week's page is kept at.
    pub fn week_path(week: Week) -> String {
        format!("{WEEKLY_DIR}/{week}.md")
    }

    /// The title a page goes by when its file gives none: its day, its
    /// week, or its file's name — "Untitled" for a name that is only an id.
    pub fn fallback_title(path: &str) -> String {
        match NoteKind::of(path) {
            Some(NoteKind::Day(day)) => day.to_string(),
            Some(NoteKind::Week(week)) => week.to_string(),
            _ => {
                let name = path.rsplit('/').next().unwrap_or(path);
                let stem = name.strip_suffix(".md").unwrap_or(name);
                if is_ulid(stem) {
                    "Untitled".to_owned()
                } else {
                    stem.to_owned()
                }
            }
        }
    }

    /// Whether a page's title is its file's, whatever its text says: a
    /// day's is its date, a week's its week.
    pub fn has_fixed_title(self) -> bool {
        !matches!(self, NoteKind::Note)
    }
}

/// Whether text is a ULID: 26 characters of Crockford's base 32.
pub fn is_ulid(text: &str) -> bool {
    text.len() == 26
        && text.bytes().next().is_some_and(|b| (b'0'..=b'7').contains(&b))
        && text.bytes().all(|b| b.is_ascii_digit() || (b.is_ascii_alphabetic() && !matches!(b.to_ascii_lowercase(), b'i' | b'l' | b'o' | b'u')))
}

/// The key two names are compared by: links find pages "case aside", and
/// a run of spaces is one.
pub fn name_key(name: &str) -> String {
    name.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// A note, read.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Note {
    pub frontmatter: Option<Frontmatter>,
    pub body: Document,
}

/// A link from one note to another, by name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteLink {
    /// The name linked to, as written: a title, an alias, a date.
    pub target: String,
    /// What the link shows, when not its target.
    pub label: Option<String>,
    /// `![[target]]`: the page shown in place.
    pub embed: bool,
    /// Where the link is: the path of its block, or empty for one written
    /// in the frontmatter's `related`.
    pub block: Vec<usize>,
}

/// A link to the web.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebLink {
    pub url: String,
    pub block: Vec<usize>,
}

/// A picture a note shows.
#[derive(Debug, Clone, PartialEq)]
pub struct ImageRef {
    /// `assets/…` in the graph, or an address on the web.
    pub source: String,
    pub alt: String,
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub block: Vec<usize>,
}

/// A task: a list item with a checkbox.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskRef {
    pub block: Vec<usize>,
    /// The task's text, as Markdown.
    pub text: String,
    pub done: bool,
}

/// Everything a note's body refers to, gathered in one pass.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct References {
    /// `[[links]]` and `![[embeds]]`, in reading order, then `related`.
    pub links: Vec<NoteLink>,
    pub web_links: Vec<WebLink>,
    /// Inline `#tags`, without the `#`, as written, in reading order.
    pub tags: Vec<String>,
    pub images: Vec<ImageRef>,
    pub tasks: Vec<TaskRef>,
}

/// What a note says about itself.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Meta {
    pub title: String,
    /// The note's lasting identity: a ULID, which survives renames.
    pub id: Option<String>,
    /// Other names the note answers to.
    pub aliases: Vec<String>,
    /// The frontmatter's tags, then the body's inline ones, each once,
    /// compared without regard to case.
    pub tags: Vec<String>,
    pub created: Option<Timestamp>,
    pub modified: Option<Timestamp>,
    /// Never shown, or named in a commit.
    pub private: bool,
    /// Part of the wiki: canonical, kept up.
    pub wiki: bool,
}

impl Meta {
    /// Every name the note answers to: its title, its aliases, and each
    /// part of a title written `Project // Topic`.
    pub fn names(&self) -> Vec<String> {
        let mut names = vec![self.title.clone()];
        names.extend(self.aliases.iter().cloned());
        if self.title.contains("//") {
            names.extend(self.title.split("//").map(|part| part.trim().to_owned()).filter(|part| !part.is_empty()));
        }
        let mut seen = std::collections::HashSet::new();
        names.retain(|name| !name.is_empty() && seen.insert(name_key(name)));
        names
    }
}

impl Note {
    /// Reads a note's file. Never fails: see [`Document::parse`].
    pub fn parse(source: &str) -> Note {
        let (frontmatter, body) = Frontmatter::split(source);
        Note { frontmatter, body: Document::parse(body) }
    }

    /// Writes the note as it goes in its file. A note read and not
    /// changed writes the bytes it was read from.
    pub fn to_markdown(&self) -> String {
        match &self.frontmatter {
            Some(frontmatter) => format!("{frontmatter}{}", self.body.to_markdown()),
            None => self.body.to_markdown(),
        }
    }

    /// The frontmatter, made if the note had none.
    pub fn frontmatter_mut(&mut self) -> &mut Frontmatter {
        self.frontmatter.get_or_insert_with(Frontmatter::new)
    }

    /// A frontmatter key's text.
    pub fn field(&self, key: &str) -> Option<&str> {
        self.frontmatter.as_ref().and_then(|f| f.text(key))
    }

    /// Whether a frontmatter flag is set.
    pub fn flag(&self, key: &str) -> bool {
        self.frontmatter.as_ref().is_some_and(|f| f.flag(key))
    }

    /// The first `# Heading`, when the body opens with one: a note's
    /// title, when its frontmatter gives none.
    pub fn title_heading(&self) -> Option<&Block> {
        self.body.blocks.first().filter(|b| b.kind == BlockKind::Heading(1) && !b.text.trim().is_empty())
    }

    /// The note's title: the frontmatter's `title`, else its first
    /// `# Heading`, else what its file is called. A day's or a week's page
    /// is always titled by its date.
    pub fn title(&self, path: &str) -> String {
        if NoteKind::of(path).is_some_and(NoteKind::has_fixed_title) {
            return NoteKind::fallback_title(path);
        }
        if let Some(title) = self.field("title").map(str::trim).filter(|t| !t.is_empty()) {
            return title.to_owned();
        }
        match self.title_heading() {
            Some(heading) => inline::plain_text(heading.text.trim_end_matches('#')),
            None => NoteKind::fallback_title(path),
        }
    }

    /// What the note says about itself, for a note kept at `path`.
    pub fn meta(&self, path: &str) -> Meta {
        let front = self.frontmatter.as_ref();
        let mut tags: Vec<String> = front.map(|f| f.list("tags")).unwrap_or_default();
        tags.iter_mut().for_each(|tag| *tag = tag.trim_start_matches('#').to_owned());
        tags.extend(self.references().tags);
        let mut seen = std::collections::HashSet::new();
        tags.retain(|tag| !tag.is_empty() && seen.insert(tag.to_lowercase()));
        Meta {
            title: self.title(path),
            id: self.field("id").map(str::trim).filter(|id| !id.is_empty()).map(str::to_owned),
            aliases: front.map(|f| f.list("aliases")).unwrap_or_default(),
            tags,
            created: self.field("created").and_then(Timestamp::parse),
            modified: self.field("modified").and_then(Timestamp::parse),
            private: self.flag("private"),
            wiki: self.flag("wiki"),
        }
    }

    /// The names in the frontmatter's `related` list: plain, or written
    /// as `[[links]]`.
    pub fn related(&self) -> Vec<String> {
        let items = self.frontmatter.as_ref().map(|f| f.list("related")).unwrap_or_default();
        items
            .iter()
            .map(|item| {
                let item = item.trim();
                let inner = item.strip_prefix("[[").and_then(|i| i.strip_suffix("]]")).unwrap_or(item);
                inner.split('|').next().unwrap_or(inner).trim().to_owned()
            })
            .filter(|name| !name.is_empty())
            .collect()
    }

    /// Everything the note refers to: the notes it links to, web links,
    /// inline tags, pictures and tasks. Code is never searched.
    pub fn references(&self) -> References {
        let mut found = References::default();
        for row in self.body.rows() {
            let block = row.block;
            if let Some(task) = block.task_state() {
                found.tasks.push(TaskRef { block: row.path.clone(), text: block.text.clone(), done: task.is_done() });
            }
            if !block.has_inline_content() {
                continue;
            }
            let spans = inline::parse(&block.text);
            for span in inline::walk(&spans) {
                match &span.kind {
                    SpanKind::WikiLink { target, label, embed } => {
                        found.links.push(NoteLink { target: target.clone(), label: label.clone(), embed: *embed, block: row.path.clone() })
                    }
                    SpanKind::Link { target, .. } => found.web_links.push(WebLink { url: target.clone(), block: row.path.clone() }),
                    SpanKind::Autolink { url } => found.web_links.push(WebLink { url: url.clone(), block: row.path.clone() }),
                    SpanKind::Url => found.web_links.push(WebLink { url: block.text[span.range.clone()].to_owned(), block: row.path.clone() }),
                    SpanKind::Tag(name) => found.tags.push(name.clone()),
                    SpanKind::Image { source, alt, width, height } => {
                        found.images.push(ImageRef { source: source.clone(), alt: alt.clone(), width: *width, height: *height, block: row.path.clone() })
                    }
                    _ => {}
                }
            }
        }
        found.links.extend(self.related().into_iter().map(|target| NoteLink { target, label: None, embed: false, block: Vec::new() }));
        found
    }

    /// The note's text as it reads, a block a line, Markdown taken out:
    /// what a search looks through.
    pub fn plain_text(&self) -> String {
        let mut out = String::new();
        for block in self.body.walk() {
            let text = match block.kind {
                BlockKind::Rule => continue,
                BlockKind::Code => block.code_parts().map(|c| c.body.to_owned()).unwrap_or_default(),
                BlockKind::Raw => block.text.clone(),
                _ => block.text.lines().map(inline::plain_text).collect::<Vec<_>>().join("\n"),
            };
            if !text.trim().is_empty() {
                out.push_str(text.trim());
                out.push('\n');
            }
        }
        out
    }

    /// Sets a task's checkbox by its block's path.
    pub fn set_task(&mut self, path: &[usize], done: bool) -> bool {
        match self.body.get_mut(path).and_then(Block::item_mut) {
            Some(item) if item.task.is_some() => {
                item.task = Some(if done { Task::Done('x') } else { Task::Open });
                true
            }
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ATLAS: &str = "---\nid: 01jbxk3t6y8q2zp4m9v7c5r0wd\naliases: [Atlas]\ntags: [Projects, \"#Work\"]\nwiki: true\nstatus: active\nmodified: 2026-10-31T10:41:12Z\nrelated:\n  - Ada Lovelace\n  - \"[[Grace Hopper|Grace]]\"\n---\n# Project Atlas\n\n- Kick-off with [[Ada Lovelace]] on [[2026-10-31]] #planning #projects\n  + [ ] Book a room\n  + [x] Send invites to <https://cal.example/atlas>\n- ![[Embedded Page]] and ![diagram](assets/atlas.png)<!-- {\"width\":425} -->\n\n```\n[[not a link]] #nottag\n```\n";

    #[test]
    fn kinds_come_from_paths() {
        assert_eq!(NoteKind::of("daily/2026-10-31.md"), Some(NoteKind::Day(Day::parse("2026-10-31").unwrap())));
        assert_eq!(NoteKind::of("weekly/2026-W44.md"), Some(NoteKind::Week(Week::parse("2026-W44").unwrap())));
        assert_eq!(NoteKind::of("notes/project-atlas.md"), Some(NoteKind::Note));
        assert_eq!(NoteKind::of("notes/deep/er/note.md"), Some(NoteKind::Note));
        for other in ["daily/notes.md", "daily/2026-13-01.md", "assets/a.png", "README.md", "notes/a.txt", "weekly/2026-W99.md"] {
            assert_eq!(NoteKind::of(other), None, "{other}");
        }
        assert_eq!(NoteKind::day_path(Day::parse("2026-10-31").unwrap()), "daily/2026-10-31.md");
        assert_eq!(NoteKind::week_path(Week::parse("2026-W44").unwrap()), "weekly/2026-W44.md");
    }

    #[test]
    fn titles_fall_back_in_order() {
        let titled = Note::parse("---\ntitle: From Frontmatter\n---\n# From Heading\n");
        assert_eq!(titled.title("notes/x.md"), "From Frontmatter");
        assert_eq!(Note::parse("# From **Heading**\n").title("notes/x.md"), "From Heading");
        assert_eq!(Note::parse("- no heading\n").title("notes/my-file.md"), "my-file");
        assert_eq!(Note::parse("").title("notes/01JBXK3T6Y8Q2ZP4M9V7C5R0WD.md"), "Untitled");
        // A day is its date, whatever it says.
        assert_eq!(titled.title("daily/2026-10-31.md"), "2026-10-31");
        assert_eq!(titled.title("weekly/2026-W44.md"), "2026-W44");
    }

    #[test]
    fn meta_gathers_frontmatter_and_body() {
        let note = Note::parse(ATLAS);
        let meta = note.meta("notes/project-atlas.md");
        assert_eq!(meta.title, "Project Atlas");
        assert_eq!(meta.id.as_deref(), Some("01jbxk3t6y8q2zp4m9v7c5r0wd"));
        assert_eq!(meta.aliases, ["Atlas"]);
        // Frontmatter's first, then inline, each once whatever its case.
        assert_eq!(meta.tags, ["Projects", "Work", "planning"]);
        assert!(meta.wiki && !meta.private);
        assert_eq!(meta.modified, Timestamp::parse("2026-10-31T10:41:12Z"));
        assert_eq!(meta.created, None);
        assert_eq!(meta.names(), ["Project Atlas", "Atlas"]);
        assert_eq!(note.field("status"), Some("active"));
    }

    #[test]
    fn a_title_in_parts_answers_to_each() {
        let meta = Note::parse("# Project // Topic\n").meta("notes/x.md");
        assert_eq!(meta.names(), ["Project // Topic", "Project", "Topic"]);
    }

    #[test]
    fn references_are_gathered_outside_code() {
        let refs = Note::parse(ATLAS).references();
        let targets: Vec<_> = refs.links.iter().map(|l| (l.target.as_str(), l.embed, l.block.as_slice())).collect();
        assert_eq!(
            targets,
            [
                ("Ada Lovelace", false, &[1][..]),
                ("2026-10-31", false, &[1]),
                ("Embedded Page", true, &[2]),
                ("Ada Lovelace", false, &[]),
                ("Grace Hopper", false, &[]),
            ]
        );
        assert_eq!(refs.tags, ["planning", "projects"]);
        assert_eq!(refs.web_links, [WebLink { url: "https://cal.example/atlas".into(), block: vec![1, 1] }]);
        assert_eq!(refs.images.len(), 1);
        assert_eq!((refs.images[0].source.as_str(), refs.images[0].width), ("assets/atlas.png", Some(425.0)));
        let tasks: Vec<_> = refs.tasks.iter().map(|t| (t.text.as_str(), t.done)).collect();
        assert_eq!(tasks, [("Book a room", false), ("Send invites to <https://cal.example/atlas>", true)]);
    }

    #[test]
    fn a_note_writes_back_as_read_and_edits_in_place() {
        let mut note = Note::parse(ATLAS);
        assert_eq!(note.to_markdown(), ATLAS);
        assert!(note.set_task(&[1, 0], true));
        assert!(!note.set_task(&[1], true));
        note.frontmatter_mut().set("status", "done");
        let written = note.to_markdown();
        assert_eq!(written, ATLAS.replace("+ [ ] Book", "+ [x] Book").replace("status: active", "status: done"));
        // A note without frontmatter gets one when a field is set.
        let mut bare = Note::parse("# Bare\n");
        bare.frontmatter_mut().set("wiki", "true");
        assert_eq!(bare.to_markdown(), "---\nwiki: true\n---\n# Bare\n");
    }

    #[test]
    fn plain_text_reads_as_shown() {
        assert_eq!(
            Note::parse(ATLAS).plain_text(),
            "Project Atlas\nKick-off with Ada Lovelace on 2026-10-31 #planning #projects\nBook a room\nSend invites to https://cal.example/atlas\nEmbedded Page and\n[[not a link]] #nottag\n"
        );
    }

    #[test]
    fn names_compare_case_and_spacing_aside() {
        assert_eq!(name_key("  Ada   LOVELACE "), "ada lovelace");
        assert!(is_ulid("01JBXK3T6Y8Q2ZP4M9V7C5R0WD") && is_ulid("01jbxk3t6y8q2zp4m9v7c5r0wd"));
        assert!(!is_ulid("project-atlas") && !is_ulid("81JBXK3T6Y8Q2ZP4M9V7C5R0WD") && !is_ulid("01JBXK3T6Y8Q2ZP4M9V7C5R0WI"));
    }
}
