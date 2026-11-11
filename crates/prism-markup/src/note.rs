//! A note: one Markdown file of a graph, read whole.
//!
//! [`Note`] is a file's two parts — its [`Frontmatter`], when it has one,
//! and its body as a [`Document`] — and what the two say together: the
//! note's title and names, its tags, the notes it links to, its pictures
//! and its tasks. Where a note lives says what kind of page it is
//! ([`NoteKind`]): `daily/2026-10-31.md` is a day's page whatever is
//! written in it.

use crate::block::{Block, BlockKind, Document, Task};
use crate::date::{Day, Week};
use crate::fields::FieldSpec;
use crate::frontmatter::{Frontmatter, Value};
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

    /// What a link to the page at a path is written with: its file's name
    /// — `project-atlas` for `notes/project-atlas.md`, the date for a
    /// day's or a week's page. It is the page's own, as no title is: two
    /// pages may share a title, and a title may change. `None` for a file
    /// that is no page.
    pub fn link_name(path: &str) -> Option<&str> {
        NoteKind::of(path)?;
        let stem = path.strip_suffix(".md")?;
        ["notes/", "daily/", "weekly/"].iter().find_map(|folder| stem.strip_prefix(folder))
    }

    /// Whether a file's name is one a note is given when it is given no
    /// name: only an id, or `untitled`, or `untitled-` and a stamp. Such
    /// a name titles nothing: see [`Note::is_untitled`].
    pub fn is_unnamed(path: &str) -> bool {
        if NoteKind::of(path) != Some(NoteKind::Note) {
            return false;
        }
        let name = path.rsplit('/').next().unwrap_or(path);
        let stem = name.strip_suffix(".md").unwrap_or(name).to_lowercase();
        is_ulid(name.strip_suffix(".md").unwrap_or(name)) || stem == "untitled" || stem.starts_with("untitled-") || stem.starts_with("untitled ")
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

/// How many characters of its first words an untitled note is called by.
pub const LABEL_LENGTH: usize = 80;

/// What a note is called where it is shown — a row of a list, a folded
/// card, a link to it. A titled note's title; an untitled one's first
/// words: the first line of its body that says anything, its markup
/// taken out, cut to [`LABEL_LENGTH`] characters. "Untitled", for one
/// with nothing written in it.
///
/// `untitled_body` is the body of a note that has no title, `None` for
/// one that has; `title` is asked only for the latter.
pub fn label(untitled_body: Option<&Document>, title: impl FnOnce() -> String) -> String {
    let Some(body) = untitled_body else { return title() };
    match first_words(&body.blocks) {
        Some(words) if words.chars().count() > LABEL_LENGTH => format!("{}…", words.chars().take(LABEL_LENGTH).collect::<String>().trim_end()),
        Some(words) => words,
        None => "Untitled".to_owned(),
    }
}

/// The first line that says anything, in the order the blocks are read.
fn first_words(blocks: &[Block]) -> Option<String> {
    blocks.iter().find_map(|block| {
        let own = if block.kind == BlockKind::Code { None } else { block.text.lines().map(inline::plain_text).find(|line| !line.is_empty()) };
        own.or_else(|| first_words(&block.children))
    })
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

/// How one note points at another.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LinkKind {
    /// `[[target]]`, or a name in the frontmatter.
    Link,
    /// `![[target]]`: the page shown in place.
    Embed,
    /// `#target`, or an item of the frontmatter's `tags`.
    Tag,
}

/// The frontmatter lists whose items are pages' names, written plainly
/// or as `[[links]]`: `related`, and `list` — pages in an order set by
/// hand. In any other field, only a value written `[[so]]` is a link.
pub const NAME_LISTS: [&str; 2] = ["related", "list"];

/// One note pointing at another, by name.
///
/// There is one such thing, however it is written. `[[Ada]]` in a line,
/// `#person` in a line, `tags: [Person]`, `related: [Ada]` and
/// `company: "[[Acme]]"` in the frontmatter are all links: each names a
/// page, each is found from that page as a backlink, each is rewritten
/// when that page is renamed. They differ in [`kind`](Self::kind) and in
/// where they are written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteLink {
    /// The name pointed at, as written: a title, an alias, a date — for
    /// a tag, its name without the `#`.
    pub target: String,
    /// What the link shows, when not its target.
    pub label: Option<String>,
    pub kind: LinkKind,
    /// The frontmatter key it is written under; `None` for one in the body.
    pub field: Option<String>,
    /// Where in the body it is: the path of its block. Empty for one in
    /// the frontmatter.
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
    /// Every pointer at another note — links, embeds and tags — the
    /// body's in reading order, then the frontmatter's.
    pub links: Vec<NoteLink>,
    pub web_links: Vec<WebLink>,
    pub images: Vec<ImageRef>,
    pub tasks: Vec<TaskRef>,
}

/// What a note says about itself.
///
/// Little, on purpose. When it was made and changed is git's to say,
/// not the note's; what marks it — pinned, in the inbox — is a field
/// like any other, asked of the index.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Meta {
    pub title: String,
    /// Other names the note answers to.
    pub aliases: Vec<String>,
    /// The frontmatter's tags, then the body's inline ones, each once,
    /// compared as names are.
    pub tags: Vec<String>,
    /// Shown, searched, listed and named in a commit only where asked
    /// for outright.
    pub private: bool,
}

impl Meta {
    /// Every name the note answers to: its title, then its aliases.
    pub fn names(&self) -> Vec<String> {
        let mut names = vec![self.title.clone()];
        names.extend(self.aliases.iter().cloned());
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
    /// Whether the note was never given a title: it has no first
    /// heading, and its file's name says nothing either (see
    /// [`NoteKind::is_unnamed`]). Such a note is shown without a title,
    /// and called by its first words where it must be called something.
    pub fn is_untitled(&self, path: &str) -> bool {
        self.title_heading().is_none() && NoteKind::is_unnamed(path)
    }

    /// What the note is called where it is shown: its title — or, never
    /// having been given one, its first words. See [`label`].
    pub fn label(&self, path: &str) -> String {
        label(self.is_untitled(path).then_some(&self.body), || self.title(path))
    }

    pub fn flag(&self, key: &str) -> bool {
        self.frontmatter.as_ref().is_some_and(|f| f.flag(key))
    }

    /// The first `# Heading`, when the body opens with one: a note's title.
    pub fn title_heading(&self) -> Option<&Block> {
        self.body.blocks.first().filter(|b| b.kind == BlockKind::Heading(1) && !b.text.trim().is_empty())
    }

    /// The note's title: its first `# Heading`, else what its file is
    /// called. A day's or a week's page is always titled by its date.
    pub fn title(&self, path: &str) -> String {
        if NoteKind::of(path).is_some_and(NoteKind::has_fixed_title) {
            return NoteKind::fallback_title(path);
        }
        match self.title_heading() {
            Some(heading) => inline::plain_text(heading.text.trim_end_matches('#')),
            None => NoteKind::fallback_title(path),
        }
    }

    /// What the note says about itself, for a note kept at `path`.
    pub fn meta(&self, path: &str) -> Meta {
        let front = self.frontmatter.as_ref();
        let mut tags: Vec<String> = Vec::new();
        // The frontmatter's first, though they are gathered last.
        let links = self.references().links;
        let (in_front, in_body): (Vec<_>, Vec<_>) = links.into_iter().filter(|link| link.kind == LinkKind::Tag).partition(|link| link.field.is_some());
        let mut seen = std::collections::HashSet::new();
        for tag in in_front.into_iter().chain(in_body) {
            if seen.insert(name_key(&tag.target)) {
                tags.push(tag.target);
            }
        }
        Meta { title: self.title(path), aliases: front.map(|f| f.list("aliases")).unwrap_or_default(), tags, private: self.flag("private") }
    }

    /// Everything the note refers to: the notes it points at — by link,
    /// embed or tag, in its body or its frontmatter — web links, pictures
    /// and tasks. Code is never searched.
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
                    SpanKind::WikiLink { target, label, embed } => found.links.push(NoteLink {
                        target: target.clone(),
                        label: label.clone(),
                        kind: if *embed { LinkKind::Embed } else { LinkKind::Link },
                        field: None,
                        block: row.path.clone(),
                    }),
                    SpanKind::Link { target, .. } => found.web_links.push(WebLink { url: target.clone(), block: row.path.clone() }),
                    SpanKind::Autolink { url } => found.web_links.push(WebLink { url: url.clone(), block: row.path.clone() }),
                    SpanKind::Url => found.web_links.push(WebLink { url: block.text[span.range.clone()].to_owned(), block: row.path.clone() }),
                    SpanKind::Tag(name) => {
                        found.links.push(NoteLink { target: name.clone(), label: None, kind: LinkKind::Tag, field: None, block: row.path.clone() })
                    }
                    SpanKind::Image { source, alt, width, height } => {
                        found.images.push(ImageRef { source: source.clone(), alt: alt.clone(), width: *width, height: *height, block: row.path.clone() })
                    }
                    _ => {}
                }
            }
        }
        for (key, value) in self.frontmatter.iter().flat_map(Frontmatter::iter) {
            // What the page calls itself points nowhere.
            if key == "aliases" {
                continue;
            }
            for item in value.to_list() {
                let item = item.trim();
                let bracketed = item.strip_prefix("[[").and_then(|inner| inner.strip_suffix("]]"));
                let (target, label, kind) = match (key, bracketed) {
                    ("tags", _) => (item.trim_start_matches('#'), None, LinkKind::Tag),
                    (_, Some(inner)) => {
                        let (target, label) = inner.split_once('|').map_or((inner, None), |(target, label)| (target, Some(label)));
                        (target, label, LinkKind::Link)
                    }
                    (key, None) if NAME_LISTS.contains(&key) => (item, None, LinkKind::Link),
                    _ => continue,
                };
                if !target.trim().is_empty() {
                    found.links.push(NoteLink {
                        target: target.trim().to_owned(),
                        label: label.map(|label| label.trim().to_owned()),
                        kind,
                        field: Some(key.to_owned()),
                        block: Vec::new(),
                    });
                }
            }
        }
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

    /// The fields this page, as a tag's page, gives the pages tagged with
    /// it. See [`crate::fields`].
    pub fn field_specs(&self) -> Vec<FieldSpec> {
        self.frontmatter.as_ref().map(FieldSpec::of).unwrap_or_default()
    }

    /// Retitles the note: its first `# Heading`, which is made when the
    /// note has none.
    pub fn set_title(&mut self, title: &str) {
        let title = title.trim();
        if self.title_heading().is_some() {
            self.body.blocks[0].text = title.to_owned();
        } else {
            self.body.blocks.insert(0, Block::heading(1, title));
        }
    }

    /// Makes the note name `to` wherever it named `from`: what every
    /// other page needs when a page is renamed. Rewritten are
    ///
    /// - `[[from]]`, `[[from|shown]]` and `![[from]]` — in tables too,
    ///   their bars escaped — never inside code;
    /// - `#from`, where `to` can be written as a tag (one word); a tag
    ///   that cannot follow is left as it is;
    /// - the titles a query block asks for (`tag:`, `links to:`, …);
    /// - frontmatter: an item of any list, plain or as a `[[link]]`, and
    ///   a field holding just the title.
    ///
    /// Names are compared as links are resolved: case and spacing aside.
    /// Returns how many places were rewritten; only those lines change.
    pub fn relink(&mut self, from: &str, to: &str) -> usize {
        self.relink_where(from, to, None, true)
    }

    /// Writes every *link* to `from` as a link to `to`, and leaves tags
    /// as they are: how a link written with a title is pinned to its
    /// page's own name — its file's — when the title comes to mean
    /// something else. A tag is a word, not a pointer to a file: it goes
    /// on saying what it said. Left alone too is what is written exactly
    /// as `except`: another file's own name, which leads to that file
    /// whatever else is called the same (see `Catalog::resolve`).
    pub fn pin(&mut self, from: &str, to: &str, except: Option<&str>) -> usize {
        self.relink_where(from, to, except, false)
    }

    fn relink_where(&mut self, from: &str, to: &str, except: Option<&str>, tags: bool) -> usize {
        let key = name_key(from);
        let key = |written: &str| name_key(written) == key && except.is_none_or(|own| written.trim() != own);
        let mut count = 0;
        fn visit(blocks: &mut [Block], key: &dyn Fn(&str) -> bool, to: &str, tags: bool, count: &mut usize) {
            for block in blocks {
                if block.has_inline_content() {
                    let spans = inline::parse(&block.text);
                    let as_tag = tags && tag_writable(to);
                    let mut ranges: Vec<_> = inline::walk(&spans)
                        .filter_map(|span| match &span.kind {
                            SpanKind::WikiLink { target, .. } if key(target) => inline::wiki_target_range(&block.text, span),
                            // The name, after its `#`.
                            SpanKind::Tag(name) if as_tag && key(name) => Some(span.range.start + 1..span.range.end),
                            _ => None,
                        })
                        .collect();
                    // Last first, so the ranges before stay where they are.
                    ranges.sort_by_key(|range| std::cmp::Reverse(range.start));
                    for range in ranges {
                        block.text.replace_range(range, to);
                        *count += 1;
                    }
                } else if block.code_parts().is_some_and(|code| code.info == "query") {
                    let lines: Vec<String> = block
                        .text
                        .split('\n')
                        .map(|line| match line.split_once(':') {
                            Some((clause, value))
                                if key(value)
                                    && match clause.trim().to_ascii_lowercase().as_str() {
                                        "tag" | "not tag" => tags,
                                        "links to" | "linked from" | "listed in" => true,
                                        _ => false,
                                    } =>
                            {
                                *count += 1;
                                format!("{clause}: {to}")
                            }
                            _ => line.to_owned(),
                        })
                        .collect();
                    block.text = lines.join("\n");
                }
                visit(&mut block.children, key, to, tags, count);
            }
        }
        visit(&mut self.body.blocks, &key, to, tags, &mut count);

        if let Some(front) = &mut self.frontmatter {
            let rename = |item: &str| -> Option<String> {
                let trimmed = item.trim();
                match trimmed.strip_prefix("[[").and_then(|inner| inner.strip_suffix("]]")) {
                    Some(inner) => {
                        let (target, shown) = inner.split_once('|').map_or((inner, None), |(t, s)| (t, Some(s)));
                        key(target).then(|| match shown {
                            Some(shown) => format!("[[{to}|{shown}]]"),
                            None => format!("[[{to}]]"),
                        })
                    }
                    None => key(trimmed.trim_start_matches('#')).then(|| to.to_owned()),
                }
            };
            let entries: Vec<(String, Value)> = front.iter().map(|(k, v)| (k.to_owned(), v.clone())).collect();
            for (name, value) in entries {
                // What the page calls itself is not a link to another.
                if matches!(name.as_str(), "aliases" | "caption") || (!tags && name == "tags") {
                    continue;
                }
                let renamed = match &value {
                    Value::Text(text) => rename(text).map(Value::Text),
                    Value::List(items) => {
                        let hits = items.iter().filter(|item| rename(item).is_some()).count();
                        (hits > 0).then(|| Value::List(items.iter().map(|item| rename(item).unwrap_or_else(|| item.clone())).collect()))
                    }
                };
                if let Some(renamed) = renamed {
                    count += match (&value, &renamed) {
                        (Value::List(old), Value::List(new)) => old.iter().zip(new).filter(|(a, b)| a != b).count().max(1),
                        _ => 1,
                    };
                    front.set(&name, renamed);
                }
            }
        }
        count
    }

    /// Sets the checkbox of the task last seen at `hint` with this text,
    /// wherever it is now ([`Document::locate_where`]). Answers where it
    /// was found; `None` when the note has no such task any more.
    pub fn set_task_like(&mut self, hint: &[usize], text: &str, done: bool) -> Option<Vec<usize>> {
        let path = self.body.locate_where(hint, |block| block.task_state().is_some() && block.text == text)?;
        self.set_task(&path, done).then_some(path)
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

/// Whether a name can be written as a `#tag`: whether `#name` reads back
/// as that one tag.
fn tag_writable(name: &str) -> bool {
    let written = format!("#{name}");
    matches!(inline::parse(&written).as_slice(), [span] if span.range == (0..written.len()) && matches!(&span.kind, SpanKind::Tag(tag) if tag == name))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::date::Timestamp;

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
        assert_eq!(Note::parse("# From **Heading**\n").title("notes/x.md"), "From Heading");
        assert_eq!(Note::parse("- no heading\n").title("notes/my-file.md"), "my-file");
        assert_eq!(Note::parse("").title("notes/01JBXK3T6Y8Q2ZP4M9V7C5R0WD.md"), "Untitled");
    }

    #[test]
    fn an_untitled_note_is_called_by_its_first_words() {
        let path = "notes/untitled-2026-11-10-135831-jmgs.md";
        let note = Note::parse("---\npinned: true\n---\n- ![](assets/pasted.png)\n- [ ] And *also*: [[semantic search]]\n");
        assert!(note.is_untitled(path));
        assert_eq!(note.label(path), "And also: semantic search");
        // Still answered to by its file's name, which is what links to it say.
        assert_eq!(note.title(path), "untitled-2026-11-10-135831-jmgs");
        // A heading titles it, whatever its file is called; so does a name that says something.
        assert!(!Note::parse("# Plans\n\nwords\n").is_untitled(path));
        assert_eq!(Note::parse("# Plans\n\nwords\n").label(path), "Plans");
        assert!(!note.is_untitled("notes/semantic-search.md"));
        assert_eq!(note.label("notes/semantic-search.md"), "semantic-search");
        assert!(!note.is_untitled("daily/2026-11-10.md"));
        // Nothing written, or only a picture: nothing to call it by.
        assert_eq!(Note::parse("").label("notes/untitled.md"), "Untitled");
        assert_eq!(Note::parse("![](a.png)\n").label("notes/01JBXK3T6Y8Q2ZP4M9V7C5R0WD.md"), "Untitled");
        // Code is not words; long words are cut.
        assert_eq!(Note::parse("```\nlet x = 1;\n```\nafter\n").label(path), "after");
        let long = Note::parse(&"word ".repeat(40)).label(path);
        assert!(long.ends_with('…') && long.chars().count() <= LABEL_LENGTH + 1, "{long}");
        // A `title:` field is a field, and no title.
        let fielded = Note::parse("---\ntitle: A Field\n---\n# From Heading\n");
        assert_eq!(fielded.title("notes/x.md"), "From Heading");
        // A day is its date, whatever it says.
        assert_eq!(fielded.title("daily/2026-10-31.md"), "2026-10-31");
        assert_eq!(fielded.title("weekly/2026-W44.md"), "2026-W44");
    }

    #[test]
    fn meta_gathers_frontmatter_and_body() {
        let note = Note::parse(ATLAS);
        let meta = note.meta("notes/project-atlas.md");
        assert_eq!(meta.title, "Project Atlas");
        assert_eq!(meta.aliases, ["Atlas"]);
        // Frontmatter's first, then inline, each once whatever its case.
        assert_eq!(meta.tags, ["Projects", "Work", "planning"]);
        assert!(!meta.private);
        assert_eq!(meta.names(), ["Project Atlas", "Atlas"]);
        // Everything else is a field, read when asked for.
        assert_eq!(note.field("status"), Some("active"));
        assert!(note.flag("wiki") && !note.flag("private") && !note.flag("pinned"));
        assert_eq!(note.field("modified").and_then(Timestamp::parse), Timestamp::parse("2026-10-31T10:41:12Z"));
        // One reading of yes and no.
        let marked = Note::parse("---\npinned: 3\ninbox: no\ntopic: Maths\nempty:\nprivate: Y\n---\n");
        assert!(marked.flag("pinned") && marked.flag("topic") && marked.flag("private"));
        assert!(!marked.flag("inbox") && !marked.flag("empty") && !marked.flag("absent"));
    }

    #[test]
    fn references_are_gathered_outside_code() {
        let refs = Note::parse(ATLAS).references();
        let pointers: Vec<_> = refs.links.iter().map(|l| (l.target.as_str(), l.kind, l.field.as_deref(), l.block.as_slice())).collect();
        use LinkKind::{Embed, Link, Tag};
        assert_eq!(
            pointers,
            [
                ("Ada Lovelace", Link, None, &[1][..]),
                ("2026-10-31", Link, None, &[1]),
                ("planning", Tag, None, &[1]),
                ("projects", Tag, None, &[1]),
                ("Embedded Page", Embed, None, &[2]),
                // Then the frontmatter's: its tags, and the names in `related`.
                ("Projects", Tag, Some("tags"), &[]),
                ("Work", Tag, Some("tags"), &[]),
                ("Ada Lovelace", Link, Some("related"), &[]),
                ("Grace Hopper", Link, Some("related"), &[]),
            ]
        );
        assert_eq!(refs.links[8].label.as_deref(), Some("Grace"));
        // In any other field, only what is written as a link is one.
        let fielded = Note::parse("---\ncompany: \"[[Acme]]\"\nstatus: Acme\nlist:\n  - First\n  - \"[[Second]]\"\naliases: [Nobody]\n---\n").references();
        let fields: Vec<_> = fielded.links.iter().map(|l| (l.target.as_str(), l.field.as_deref().unwrap())).collect();
        assert_eq!(fields, [("Acme", "company"), ("First", "list"), ("Second", "list")]);
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
    fn a_task_is_found_again_after_the_note_changed_around_it() {
        let mut note = Note::parse("- intro\n+ [ ] Call Ada\n- middle\n  + [ ] Call Ada\n+ [ ] Book a room\n");
        // As an index saw it: [1] and [2, 0] are "Call Ada", [3] "Book a room".
        note.body.blocks.insert(0, Block::bullet("a line added above"));
        assert_eq!(note.body.locate(&[3], "Book a room"), Some(vec![4]));
        // Of two alike, the one nearest where it was.
        assert_eq!(note.set_task_like(&[2, 0], "Call Ada", true), Some(vec![3, 0]));
        assert_eq!(note.set_task_like(&[1], "Call Ada", true), Some(vec![2]));
        // Where nothing moved, the path itself.
        assert_eq!(note.set_task_like(&[4], "Book a room", true), Some(vec![4]));
        assert_eq!(note.to_markdown(), "- a line added above\n- intro\n+ [x] Call Ada\n- middle\n  + [x] Call Ada\n+ [x] Book a room\n");
        // Gone, or no task: nothing is touched.
        assert_eq!(note.set_task_like(&[0], "No such task", true), None);
        assert_eq!(note.set_task_like(&[1], "intro", true), None);
    }

    #[test]
    fn relinking_rewrites_every_way_a_page_is_named() {
        let source = "---\ntags: [Person, Project Atlas]\nrelated:\n  - \"[[project atlas|the project]]\"\n  - Grace Hopper\ncompany: Project Atlas\ncaption: Project Atlas\n---\n# Heading\n\n- See [[Project Atlas]], [[project  atlas|it]] and ![[PROJECT ATLAS]]; not [[Project Atlas 2]] or `[[Project Atlas]]`\n\n| a |\n|---|\n| [[Project Atlas\\|x]] |\n\n```query\ntag: Project Atlas\ntitle: Project Atlas\nlinks to: project atlas\n```\n\n```\n[[Project Atlas]]\n```\n";
        let mut note = Note::parse(source);
        assert_eq!(note.relink("Project Atlas", "Atlas Reborn"), 9);
        let expected = source
            .replace("tags: [Person, Project Atlas]", "tags: [Person, Atlas Reborn]")
            .replace("[[project atlas|the project]]", "[[Atlas Reborn|the project]]")
            .replace("company: Project Atlas", "company: Atlas Reborn")
            .replace("See [[Project Atlas]], [[project  atlas|it]] and ![[PROJECT ATLAS]]", "See [[Atlas Reborn]], [[Atlas Reborn|it]] and ![[Atlas Reborn]]")
            .replace("[[Project Atlas\\|x]]", "[[Atlas Reborn\\|x]]")
            .replace("tag: Project Atlas", "tag: Atlas Reborn")
            .replace("links to: project atlas", "links to: Atlas Reborn");
        assert_eq!(note.to_markdown(), expected);
        // Nothing names it now: nothing changes.
        assert_eq!(note.relink("Project Atlas", "Again"), 0);
        assert_eq!(note.to_markdown(), expected);
    }

    #[test]
    fn tags_follow_a_rename_where_they_can_be_written() {
        let source = "---\ntags: [person, \"#Other\"]\n---\n- Met #person and #Person/x at `#person`\n";
        let mut note = Note::parse(source);
        assert_eq!(note.relink("Person", "People"), 2);
        assert_eq!(note.to_markdown(), "---\ntags: [People, \"#Other\"]\n---\n- Met #People and #Person/x at `#person`\n");
        // A name of two words is no tag: the inline one is left, the frontmatter's follows.
        assert_eq!(note.relink("People", "Two Words"), 1);
        assert_eq!(note.to_markdown(), "---\ntags: [Two Words, \"#Other\"]\n---\n- Met #People and #Person/x at `#person`\n");
    }

    #[test]
    fn a_title_is_set_where_it_is_written() {
        let mut headed = Note::parse("---\ntitle: a field\n---\n#  Old\n\ntext\n");
        headed.set_title(" New ");
        assert_eq!(headed.to_markdown(), "---\ntitle: a field\n---\n#  New\n\ntext\n");
        let mut bare = Note::parse("- just a list\n");
        bare.set_title("New");
        assert_eq!(bare.to_markdown(), "# New\n- just a list\n");
        assert_eq!(bare.title("notes/x.md"), "New");
        let tag = Note::parse("---\nfields:\n  - birthday (date)\n---\n");
        assert_eq!(tag.field_specs()[0].to_string(), "birthday (date)");
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
