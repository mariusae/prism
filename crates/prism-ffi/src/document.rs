//! A note, for an editor: the block tree, the outline's commands, and the
//! spans in a row's text.
//!
//! Text positions cross this boundary as **UTF-16 offsets**, which is
//! what `NSString`, `NSRange` and TextKit count in. Inside, the engine
//! counts bytes; the conversion is done here, once.

use prism::markup::{self, inline, outline, Block, BlockKind, Item, Marker, Note, SpanKind, Task, Value};
use std::sync::{Arc, Mutex, MutexGuard};

/// A checkbox on a list item.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TaskState {
    /// No checkbox.
    None,
    Open,
    Done,
}

/// What a row is.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RowKind {
    Paragraph,
    Heading {
        level: u8,
    },
    /// `- text`, `* text`, `+ text`; with a checkbox, a task.
    Bullet {
        marker: String,
        task: TaskState,
    },
    /// `1. text` or `1) text`.
    Ordered {
        number: u32,
        delimiter: String,
        task: TaskState,
    },
    Quote,
    /// A fenced code block; its text is all of it, fences included.
    Code,
    Table,
    Rule,
    /// Lines kept exactly as they were, shown as plain text.
    Raw,
}

/// A block as an outline shows it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OutlineRow {
    /// The block's place: an index at each level, outermost first.
    pub path: Vec<u32>,
    /// How many list items it is nested in.
    pub depth: u32,
    pub kind: RowKind,
    /// The block's Markdown, without its marker.
    pub text: String,
    pub child_count: u32,
    /// Whether Markdown can nest rows under this one: only a list item.
    pub can_have_children: bool,
}

/// Where two rows' text met when one was joined onto the other.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct JoinPoint {
    /// The row joined onto.
    pub path: Vec<u32>,
    /// Where in its text the two meet, in UTF-16 units: the caret's place.
    pub offset: u32,
}

/// A fenced code block's parts.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CodeParts {
    /// What follows the opening fence: `swift`, `query`.
    pub info: String,
    pub body: String,
}

/// A callout: a quote whose first line is `[!TIP]`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CalloutParts {
    pub kind: String,
    pub body: String,
}

/// A pipe table's cells, each inline Markdown.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableCells {
    pub header: Vec<String>,
    pub rows: Vec<Vec<String>>,
}

/// What a note says about itself.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NoteMeta {
    pub title: String,
    pub id: Option<String>,
    pub aliases: Vec<String>,
    /// Frontmatter's tags, then the body's inline ones, each once.
    pub tags: Vec<String>,
    /// Seconds since the Unix epoch.
    pub created: Option<i64>,
    pub modified: Option<i64>,
    pub is_private: bool,
    pub is_wiki: bool,
    /// Every name the note answers to: title, aliases, a title's parts.
    pub names: Vec<String>,
}

/// A link from the note to another page.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LinkReference {
    pub target: String,
    pub label: Option<String>,
    pub is_embed: bool,
    /// The row it is in; empty for one in the frontmatter's `related`.
    pub row: Vec<u32>,
}

/// A picture the note shows.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImageReference {
    pub source: String,
    pub alt: String,
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub row: Vec<u32>,
}

/// A task in the note.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TaskReference {
    pub row: Vec<u32>,
    pub text: String,
    pub is_done: bool,
}

/// Everything a note refers to.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct NoteReferences {
    pub links: Vec<LinkReference>,
    pub web_links: Vec<String>,
    pub tags: Vec<String>,
    pub images: Vec<ImageReference>,
    pub tasks: Vec<TaskReference>,
}

/// A frontmatter entry: text is a list of one.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FrontmatterField {
    pub key: String,
    pub values: Vec<String>,
    pub is_list: bool,
}

fn to_path(path: &[u32]) -> Vec<usize> {
    path.iter().map(|index| *index as usize).collect()
}

fn from_path(path: Vec<usize>) -> Vec<u32> {
    path.into_iter().map(|index| index as u32).collect()
}

fn task_state(task: Option<Task>) -> TaskState {
    match task {
        None => TaskState::None,
        Some(Task::Open) => TaskState::Open,
        Some(Task::Done(_)) => TaskState::Done,
    }
}

fn to_task(state: TaskState) -> Option<Task> {
    match state {
        TaskState::None => None,
        TaskState::Open => Some(Task::Open),
        TaskState::Done => Some(Task::Done('x')),
    }
}

fn row_kind(block: &Block) -> RowKind {
    match &block.kind {
        BlockKind::Paragraph => RowKind::Paragraph,
        BlockKind::Heading(level) => RowKind::Heading { level: *level },
        BlockKind::Item(Item { marker: Marker::Bullet(marker), task }) => RowKind::Bullet { marker: marker.to_string(), task: task_state(*task) },
        BlockKind::Item(Item { marker: Marker::Ordered { number, delimiter }, task }) => {
            RowKind::Ordered { number: *number, delimiter: delimiter.to_string(), task: task_state(*task) }
        }
        BlockKind::Quote => RowKind::Quote,
        BlockKind::Code => RowKind::Code,
        BlockKind::Table => RowKind::Table,
        BlockKind::Rule => RowKind::Rule,
        BlockKind::Raw => RowKind::Raw,
    }
}

fn block_kind(kind: &RowKind) -> BlockKind {
    let first = |text: &str, default: char, allowed: &[char]| text.chars().next().filter(|c| allowed.contains(c)).unwrap_or(default);
    match kind {
        RowKind::Paragraph => BlockKind::Paragraph,
        RowKind::Heading { level } => BlockKind::Heading((*level).clamp(1, 6)),
        RowKind::Bullet { marker, task } => BlockKind::Item(Item { marker: Marker::Bullet(first(marker, '-', &['-', '*', '+'])), task: to_task(*task) }),
        RowKind::Ordered { number, delimiter, task } => {
            BlockKind::Item(Item { marker: Marker::Ordered { number: *number, delimiter: first(delimiter, '.', &['.', ')']) }, task: to_task(*task) })
        }
        RowKind::Quote => BlockKind::Quote,
        RowKind::Code => BlockKind::Code,
        RowKind::Table => BlockKind::Table,
        RowKind::Rule => BlockKind::Rule,
        RowKind::Raw => BlockKind::Raw,
    }
}

/// A UTF-16 offset as a byte offset, held to the text and to a character.
pub(crate) fn byte_offset(text: &str, utf16: u32) -> usize {
    let mut units = 0;
    for (at, c) in text.char_indices() {
        if units >= utf16 {
            return at;
        }
        units += c.len_utf16() as u32;
    }
    text.len()
}

/// A byte offset as a UTF-16 offset.
pub(crate) fn utf16_offset(text: &str, byte: usize) -> u32 {
    text[..byte.min(text.len())].encode_utf16().count() as u32
}

/// A note being edited: its frontmatter, and its body as rows.
///
/// Rows are named by path — an index at each level — as [`rows`](Self::rows)
/// gives them; a command answers with the path the row has afterwards, or
/// nothing when it could not be done. Reading a note and writing it back
/// unchanged gives the same bytes; an edit rewrites only its own lines.
/// Safe to use from any thread.
#[derive(uniffi::Object)]
pub struct NoteDocument {
    note: Mutex<Note>,
}

impl NoteDocument {
    fn lock(&self) -> MutexGuard<'_, Note> {
        // A panic while holding the lock leaves a note that is still a note.
        self.note.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[uniffi::export]
impl NoteDocument {
    /// Reads a note's file. Never fails: what is not understood is kept.
    #[uniffi::constructor]
    pub fn parse(source: String) -> Arc<NoteDocument> {
        Arc::new(NoteDocument { note: Mutex::new(Note::parse(&source)) })
    }

    /// The note as it goes in its file.
    pub fn markdown(&self) -> String {
        self.lock().to_markdown()
    }

    /// Whether nothing is written: no rows, or only empty bullets.
    pub fn is_blank(&self) -> bool {
        let note = self.lock();
        note.frontmatter.is_none() && note.body.is_blank()
    }

    // --- What it says ------------------------------------------------------

    /// The note's title, for a note kept at `path`.
    pub fn title(&self, path: String) -> String {
        self.lock().title(&path)
    }

    /// Retitles the note where its title is written.
    pub fn set_title(&self, title: String) {
        self.lock().set_title(&title);
    }

    pub fn meta(&self, path: String) -> NoteMeta {
        let meta = self.lock().meta(&path);
        NoteMeta {
            names: meta.names(),
            title: meta.title,
            id: meta.id,
            aliases: meta.aliases,
            tags: meta.tags,
            created: meta.created.map(|t| t.0),
            modified: meta.modified.map(|t| t.0),
            is_private: meta.private,
            is_wiki: meta.wiki,
        }
    }

    pub fn references(&self) -> NoteReferences {
        let found = self.lock().references();
        NoteReferences {
            links: found.links.into_iter().map(|l| LinkReference { target: l.target, label: l.label, is_embed: l.embed, row: from_path(l.block) }).collect(),
            web_links: found.web_links.into_iter().map(|l| l.url).collect(),
            tags: found.tags,
            images: found
                .images
                .into_iter()
                .map(|i| ImageReference { source: i.source, alt: i.alt, width: i.width, height: i.height, row: from_path(i.block) })
                .collect(),
            tasks: found.tasks.into_iter().map(|t| TaskReference { row: from_path(t.block), text: t.text, is_done: t.done }).collect(),
        }
    }

    /// The note's text as it reads, Markdown taken out.
    pub fn plain_text(&self) -> String {
        self.lock().plain_text()
    }

    /// Makes the note name `to` wherever it named `from`. Returns how
    /// many places were rewritten.
    pub fn relink(&self, from: String, to: String) -> u32 {
        self.lock().relink(&from, &to) as u32
    }

    // --- Frontmatter -------------------------------------------------------

    /// Every frontmatter entry, in the order written.
    pub fn fields(&self) -> Vec<FrontmatterField> {
        let note = self.lock();
        let Some(front) = &note.frontmatter else { return Vec::new() };
        front.iter().map(|(key, value)| FrontmatterField { key: key.to_owned(), values: value.to_list(), is_list: matches!(value, Value::List(_)) }).collect()
    }

    /// A frontmatter key's values; none when it is not there.
    pub fn field(&self, key: String) -> Option<Vec<String>> {
        self.lock().frontmatter.as_ref().and_then(|front| front.get(&key)).map(Value::to_list)
    }

    /// Sets a frontmatter key to text, making the frontmatter if need be.
    /// Only that entry's lines are rewritten.
    pub fn set_field(&self, key: String, value: String) {
        self.lock().frontmatter_mut().set(&key, value);
    }

    /// Sets a frontmatter key to a list.
    pub fn set_list_field(&self, key: String, values: Vec<String>) {
        self.lock().frontmatter_mut().set(&key, values);
    }

    /// Takes a frontmatter key out. Says whether it was there.
    pub fn remove_field(&self, key: String) -> bool {
        self.lock().frontmatter.as_mut().is_some_and(|front| front.remove(&key))
    }

    // --- Rows --------------------------------------------------------------

    /// Every block as a row, in reading order: the outline.
    pub fn rows(&self) -> Vec<OutlineRow> {
        self.lock()
            .body
            .rows()
            .into_iter()
            .map(|row| OutlineRow {
                depth: row.depth as u32,
                kind: row_kind(row.block),
                text: row.block.text.clone(),
                child_count: row.block.children.len() as u32,
                can_have_children: row.block.can_have_children(),
                path: from_path(row.path),
            })
            .collect()
    }

    /// How many top-level blocks there are: a prose editor's paragraphs.
    pub fn top_level_count(&self) -> u32 {
        self.lock().body.blocks.len() as u32
    }

    /// One row; nothing when the path leads nowhere.
    pub fn row(&self, path: Vec<u32>) -> Option<OutlineRow> {
        let note = self.lock();
        let block = note.body.get(&to_path(&path))?;
        Some(OutlineRow {
            depth: path.len().saturating_sub(1) as u32,
            kind: row_kind(block),
            text: block.text.clone(),
            child_count: block.children.len() as u32,
            can_have_children: block.can_have_children(),
            path,
        })
    }

    /// Sets a row's text. Says whether there was such a row.
    pub fn set_text(&self, path: Vec<u32>, text: String) -> bool {
        match self.lock().body.get_mut(&to_path(&path)) {
            Some(block) => {
                block.text = text;
                true
            }
            None => false,
        }
    }

    /// Makes a row another kind, keeping its text.
    pub fn set_kind(&self, path: Vec<u32>, kind: RowKind) -> bool {
        outline::set_kind(&mut self.lock().body, &to_path(&path), block_kind(&kind)).is_some()
    }

    /// Puts a new row in at a path, moving what was there down. A path
    /// one past a list's end appends.
    pub fn insert(&self, path: Vec<u32>, kind: RowKind, text: String) -> bool {
        outline::insert(&mut self.lock().body, &to_path(&path), Block::new(block_kind(&kind), text)).is_some()
    }

    /// Takes a row out, children and all.
    pub fn remove(&self, path: Vec<u32>) -> bool {
        outline::remove(&mut self.lock().body, &to_path(&path)).is_some()
    }

    /// Makes a row the last child of the row before it.
    pub fn indent(&self, path: Vec<u32>) -> Option<Vec<u32>> {
        outline::indent(&mut self.lock().body, &to_path(&path)).map(from_path)
    }

    /// Moves a row out a level, to just after its parent.
    pub fn outdent(&self, path: Vec<u32>) -> Option<Vec<u32>> {
        outline::outdent(&mut self.lock().body, &to_path(&path)).map(from_path)
    }

    pub fn move_up(&self, path: Vec<u32>) -> Option<Vec<u32>> {
        outline::move_up(&mut self.lock().body, &to_path(&path)).map(from_path)
    }

    pub fn move_down(&self, path: Vec<u32>) -> Option<Vec<u32>> {
        outline::move_down(&mut self.lock().body, &to_path(&path)).map(from_path)
    }

    /// Puts a copy of a row, children and all, straight after it.
    pub fn duplicate(&self, path: Vec<u32>) -> Option<Vec<u32>> {
        outline::duplicate(&mut self.lock().body, &to_path(&path)).map(from_path)
    }

    /// Splits a row's text at a UTF-16 offset — what Return does. Answers
    /// the new row's path.
    pub fn split(&self, path: Vec<u32>, offset: u32) -> Option<Vec<u32>> {
        let mut note = self.lock();
        let path = to_path(&path);
        let at = byte_offset(&note.body.get(&path)?.text, offset);
        outline::split(&mut note.body, &path, at).map(from_path)
    }

    /// Joins a row's text onto the row before it — what Delete does at a
    /// row's start.
    pub fn join_with_previous(&self, path: Vec<u32>) -> Option<JoinPoint> {
        let mut note = self.lock();
        let (onto, at) = outline::join_with_previous(&mut note.body, &to_path(&path))?;
        let offset = utf16_offset(&note.body.get(&onto)?.text, at);
        Some(JoinPoint { path: from_path(onto), offset })
    }

    /// Checks a task off, or opens it again; a list item with no
    /// checkbox gets an open one. Answers the new state.
    pub fn toggle_task(&self, path: Vec<u32>) -> TaskState {
        task_state(outline::toggle_task(&mut self.lock().body, &to_path(&path)))
    }

    /// How many top-level blocks a heading's section takes, the heading
    /// included.
    pub fn section_length(&self, index: u32) -> u32 {
        outline::section_len(&self.lock().body, index as usize) as u32
    }

    // --- Blocks with parts -------------------------------------------------

    /// A code block's info string and body.
    pub fn code(&self, path: Vec<u32>) -> Option<CodeParts> {
        let note = self.lock();
        let parts = note.body.get(&to_path(&path))?.code_parts()?;
        Some(CodeParts { info: parts.info.to_owned(), body: parts.body.to_owned() })
    }

    /// The callout a quote is, when its first line is `[!KIND]`.
    pub fn callout(&self, path: Vec<u32>) -> Option<CalloutParts> {
        let note = self.lock();
        let parts = note.body.get(&to_path(&path))?.callout()?;
        Some(CalloutParts { kind: parts.kind.to_owned(), body: parts.body.to_owned() })
    }

    /// A table block's cells.
    pub fn table(&self, path: Vec<u32>) -> Option<TableCells> {
        let note = self.lock();
        let block = note.body.get(&to_path(&path)).filter(|block| block.kind == BlockKind::Table)?;
        let table = markup::Table::parse(&block.text)?;
        Some(TableCells { header: table.header, rows: table.rows })
    }
}

// --- Inline ----------------------------------------------------------------

/// What a span of inline Markdown is.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum InlineKind {
    Strong,
    Emphasis,
    Strikethrough,
    Highlight,
    Code,
    Link {
        target: String,
        title: Option<String>,
    },
    Autolink {
        url: String,
    },
    /// A bare `https://…`.
    Url,
    WikiLink {
        target: String,
        label: Option<String>,
        is_embed: bool,
    },
    Image {
        source: String,
        alt: String,
        width: Option<f64>,
        height: Option<f64>,
    },
    Tag {
        name: String,
    },
    Comment,
    Escape,
}

/// A stretch of inline Markdown in a row's text. Ranges are UTF-16.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InlineSpan {
    pub kind: InlineKind,
    /// The whole span, markup included.
    pub start: u32,
    pub end: u32,
    /// What it shows: an editor hides `start..content_start` and
    /// `content_end..end`.
    pub content_start: u32,
    pub content_end: u32,
    /// How many spans it is nested in: 0 for an outermost one.
    pub depth: u32,
}

/// A style to put on, or take off, a range of text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum InlineStyle {
    Strong,
    Emphasis,
    Strikethrough,
    Highlight,
    Code,
}

/// A text after a style was toggled, and where the same words now are.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StyledText {
    pub text: String,
    pub start: u32,
    pub end: u32,
}

fn inline_kind(kind: &SpanKind) -> InlineKind {
    match kind {
        SpanKind::Strong => InlineKind::Strong,
        SpanKind::Emphasis => InlineKind::Emphasis,
        SpanKind::Strikethrough => InlineKind::Strikethrough,
        SpanKind::Highlight => InlineKind::Highlight,
        SpanKind::Code => InlineKind::Code,
        SpanKind::Link { target, title } => InlineKind::Link { target: target.clone(), title: title.clone() },
        SpanKind::Autolink { url } => InlineKind::Autolink { url: url.clone() },
        SpanKind::Url => InlineKind::Url,
        SpanKind::WikiLink { target, label, embed } => InlineKind::WikiLink { target: target.clone(), label: label.clone(), is_embed: *embed },
        SpanKind::Image { source, alt, width, height } => InlineKind::Image { source: source.clone(), alt: alt.clone(), width: *width, height: *height },
        SpanKind::Tag(name) => InlineKind::Tag { name: name.clone() },
        SpanKind::Comment => InlineKind::Comment,
        SpanKind::Escape => InlineKind::Escape,
    }
}

/// The spans in a row's text, outermost first, in order.
#[uniffi::export]
pub fn inline_spans(text: String) -> Vec<InlineSpan> {
    // Byte offsets to UTF-16, in one pass over the text.
    let mut units = Vec::with_capacity(text.len() + 1);
    let mut count = 0u32;
    for c in text.chars() {
        units.extend(std::iter::repeat_n(count, c.len_utf8()));
        count += c.len_utf16() as u32;
    }
    units.push(count);
    fn visit(spans: &[markup::Span], depth: u32, units: &[u32], out: &mut Vec<InlineSpan>) {
        for span in spans {
            out.push(InlineSpan {
                kind: inline_kind(&span.kind),
                start: units[span.range.start],
                end: units[span.range.end],
                content_start: units[span.content.start],
                content_end: units[span.content.end],
                depth,
            });
            visit(&span.children, depth + 1, units, out);
        }
    }
    let mut out = Vec::new();
    visit(&inline::parse(&text), 0, &units, &mut out);
    out
}

/// A text with its Markdown taken out: what it says, as it is shown.
#[uniffi::export]
pub fn inline_plain_text(text: String) -> String {
    inline::plain_text(&text)
}

/// Puts a style on a UTF-16 range of a text, or takes it off when the
/// range is exactly a span of that style.
#[uniffi::export]
pub fn toggle_inline_style(text: String, start: u32, end: u32, style: InlineStyle) -> StyledText {
    let style = match style {
        InlineStyle::Strong => markup::Style::Strong,
        InlineStyle::Emphasis => markup::Style::Emphasis,
        InlineStyle::Strikethrough => markup::Style::Strikethrough,
        InlineStyle::Highlight => markup::Style::Highlight,
        InlineStyle::Code => markup::Style::Code,
    };
    let range = byte_offset(&text, start)..byte_offset(&text, end.max(start));
    let (styled, range) = inline::toggle(&text, range, style);
    StyledText { start: utf16_offset(&styled, range.start), end: utf16_offset(&styled, range.end), text: styled }
}

// --- Conflicts -------------------------------------------------------------

/// Which side of each conflict to keep.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConflictKeep {
    Ours,
    Theirs,
    Both,
}

/// A run of plain text, or one whole conflict.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ConflictSegment {
    Text { text: String },
    Conflict { our_label: String, ours: String, their_label: String, theirs: String },
}

/// How many whole conflict blocks a note's text holds.
#[uniffi::export]
pub fn conflict_count(source: String) -> u32 {
    prism::sync::conflict::count(&source) as u32
}

/// Resolves every conflict by keeping the chosen side, or both.
#[uniffi::export]
pub fn resolve_conflicts(source: String, keep: ConflictKeep) -> String {
    use prism::sync::conflict::Keep;
    let keep = match keep {
        ConflictKeep::Ours => Keep::Ours,
        ConflictKeep::Theirs => Keep::Theirs,
        ConflictKeep::Both => Keep::Both,
    };
    prism::sync::conflict::resolve(&source, keep)
}

/// A note's text as runs of plain text and conflicts: a review screen.
#[uniffi::export]
pub fn conflict_segments(source: String) -> Vec<ConflictSegment> {
    use prism::sync::conflict::Segment;
    prism::sync::conflict::segments(&source)
        .into_iter()
        .map(|segment| match segment {
            Segment::Text(text) => ConflictSegment::Text { text },
            Segment::Conflict { ours, theirs } => {
                ConflictSegment::Conflict { our_label: ours.label, ours: ours.text, their_label: theirs.label, theirs: theirs.text }
            }
        })
        .collect()
}

/// Merges a draft with what changed underneath it, from the text both
/// came from — a note's frontmatter field by field, its body by lines.
#[uniffi::export]
pub fn merge_note_texts(base: Option<String>, ours: String, theirs: String) -> MergedText {
    let labels = prism::sync::Labels::default();
    let merged = prism::merge_notes(base.as_deref(), &ours, &theirs, labels)
        .unwrap_or_else(|| prism::sync::textmerge::merge_lenient(base.as_deref().unwrap_or(""), &ours, &theirs, labels));
    MergedText { text: merged.text, is_conflicted: merged.conflicted }
}

/// A merge's result.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MergedText {
    pub text: String,
    /// Whether lines both sides changed were left between markers.
    pub is_conflicted: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offsets_convert_between_bytes_and_utf16() {
        let text = "a💰é z"; // 1 + 4 + 2 + 1 + 1 bytes; 1 + 2 + 1 + 1 + 1 units
        assert_eq!([0, 1, 3, 4, 5, 6, 99].map(|units| byte_offset(text, units)), [0, 1, 5, 7, 8, 9, 9]);
        // An offset inside a surrogate pair lands after the character.
        assert_eq!(byte_offset(text, 2), 5);
        assert_eq!([0, 1, 5, 7, 9, 99].map(|byte| utf16_offset(text, byte)), [0, 1, 3, 4, 6, 6]);
    }

    #[test]
    fn spans_are_flat_nested_and_in_utf16() {
        let spans = inline_spans("💰 **bold [[Ada|a]]** #tag".into());
        let summary: Vec<_> = spans.iter().map(|s| (s.depth, s.start, s.end, s.content_start, s.content_end)).collect();
        assert_eq!(summary, [(0, 3, 21, 5, 19), (1, 10, 19, 16, 17), (0, 22, 26, 23, 26)]);
        assert_eq!(spans[1].kind, InlineKind::WikiLink { target: "Ada".into(), label: Some("a".into()), is_embed: false });
        assert!(inline_spans(String::new()).is_empty());
    }

    #[test]
    fn a_document_is_edited_by_path() {
        let document = NoteDocument::parse("- one\n- two\n".into());
        assert_eq!(document.indent(vec![1]), Some(vec![0, 0]));
        assert!(document.set_kind(vec![0], RowKind::Bullet { marker: "+".into(), task: TaskState::Open }));
        assert!(document.insert(vec![1], RowKind::Heading { level: 9 }, "End".into()));
        assert_eq!(document.markdown(), "+ [ ] one\n  - two\n###### End\n");
        assert_eq!(document.rows().iter().map(|r| r.depth).collect::<Vec<_>>(), [0, 1, 0]);
        assert!(!document.set_text(vec![7], "nowhere".into()));
        assert_eq!(document.toggle_task(vec![2]), TaskState::None);
    }
}
