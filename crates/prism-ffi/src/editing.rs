//! A note open for writing, for Swift: `prism_markup::Session`, with
//! offsets in UTF-16 — a text view's own.
//!
//! [`NoteEditor`] is what an editor component holds. Its text view shows
//! what the session projects of the note's tree, and hands every change
//! made in it back to the session; the session, not the view, is the note.

use crate::document::{FrontmatterField, NoteMeta};
use prism::markup::editor::{self, Command, CompletionKind, Layout, LineKind, RunKind};
use prism::markup::{Mode, Note, Session, Style, Value};
use std::sync::{Arc, Mutex, MutexGuard};

/// Byte offsets of a text as UTF-16 offsets, and back, each in one pass.
struct Offsets {
    /// For each byte offset that starts a character (and the end): the
    /// UTF-16 units before it.
    utf16: Vec<u32>,
}

impl Offsets {
    fn of(text: &str) -> Offsets {
        let mut utf16 = vec![0u32; text.len() + 1];
        let mut units = 0u32;
        for (at, c) in text.char_indices() {
            for inside in 0..c.len_utf8() {
                utf16[at + inside] = units;
            }
            units += c.len_utf16() as u32;
        }
        utf16[text.len()] = units;
        Offsets { utf16 }
    }

    fn to16(&self, byte: usize) -> u32 {
        self.utf16[byte.min(self.utf16.len() - 1)]
    }

    /// The byte offset of a UTF-16 offset: the first byte at or past it.
    fn to8(&self, utf16: u32) -> usize {
        self.utf16.partition_point(|units| *units < utf16).min(self.utf16.len() - 1)
    }
}

/// What a line of a body is.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum BodyLineKind {
    Blank,
    Paragraph,
    Heading {
        level: u8,
    },
    /// A list item's first line: its number (for `1.`), its checkbox
    /// (open or done), and the bullet it is written with.
    Item {
        number: Option<u32>,
        done: Option<bool>,
        bullet: String,
    },
    Quote,
    /// A code fence's opening or closing line.
    Fence,
    /// A line inside a code fence.
    Code,
    Table,
    Rule,
}

/// One line of a body. Offsets are UTF-16.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BodyLine {
    pub start: u32,
    /// The line's end, before its line break.
    pub end: u32,
    pub kind: BodyLineKind,
    /// The spaces it is indented by.
    pub indent: u32,
    /// Where its words begin: after its indentation and marker.
    pub content: u32,
    /// How many list items it is inside.
    pub depth: u32,
}

/// What a stretch of a line means.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum BodyRunKind {
    /// Markup with nothing to show: hidden off the lines being written in.
    Markup,
    Strong,
    Emphasis,
    Strikethrough,
    Highlight,
    Code,
    /// A link to a page: its shown words.
    PageLink {
        target: String,
        is_embed: bool,
    },
    /// A link to the web: its shown words, or a bare address.
    WebLink {
        url: String,
    },
    Tag {
        name: String,
    },
    /// A picture: the whole of its markup.
    Image {
        source: String,
        alt: String,
        width: Option<f64>,
        height: Option<f64>,
    },
    /// A list item's bullet or number.
    Bullet,
    Checkbox {
        is_done: bool,
    },
    QuoteMark,
    Callout {
        kind: String,
    },
    /// A code fence's info string: `query`.
    FenceInfo {
        info: String,
    },
}

/// A stretch of a body, and what it means. Offsets are UTF-16.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BodyRun {
    pub start: u32,
    pub end: u32,
    pub kind: BodyRunKind,
}

/// A body, read for a text view.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BodyLayout {
    pub lines: Vec<BodyLine>,
    pub runs: Vec<BodyRun>,
    /// Whether each line's marker — its bullet, its hashes — is written
    /// in the text. In an outline it is not: a line's kind says what to
    /// draw beside it.
    pub markers_in_text: bool,
}

/// Reads a body for a text view: what each line is, and what each run
/// of it means.
#[uniffi::export]
pub fn body_layout(body: String) -> BodyLayout {
    layout_of(editor::layout(&body), &body)
}

fn layout_of(read: Layout, body: &str) -> BodyLayout {
    let offsets = Offsets::of(body);
    let markers_in_text = read.markers_in_text;
    let lines = read
        .lines
        .into_iter()
        .map(|line| BodyLine {
            start: offsets.to16(line.range.start),
            end: offsets.to16(line.range.end),
            kind: match line.kind {
                LineKind::Blank => BodyLineKind::Blank,
                LineKind::Paragraph => BodyLineKind::Paragraph,
                LineKind::Heading(level) => BodyLineKind::Heading { level },
                LineKind::Item { ordered, task, bullet } => BodyLineKind::Item { number: ordered, done: task, bullet: bullet.to_string() },
                LineKind::Quote => BodyLineKind::Quote,
                LineKind::Fence => BodyLineKind::Fence,
                LineKind::Code => BodyLineKind::Code,
                LineKind::Table => BodyLineKind::Table,
                LineKind::Rule => BodyLineKind::Rule,
            },
            indent: line.indent as u32,
            content: offsets.to16(line.content),
            depth: line.depth as u32,
        })
        .collect();
    let runs = read
        .runs
        .into_iter()
        .map(|run| BodyRun {
            start: offsets.to16(run.range.start),
            end: offsets.to16(run.range.end),
            kind: match run.kind {
                RunKind::Markup => BodyRunKind::Markup,
                RunKind::Strong => BodyRunKind::Strong,
                RunKind::Emphasis => BodyRunKind::Emphasis,
                RunKind::Strikethrough => BodyRunKind::Strikethrough,
                RunKind::Highlight => BodyRunKind::Highlight,
                RunKind::Code => BodyRunKind::Code,
                RunKind::PageLink { target, embed } => BodyRunKind::PageLink { target, is_embed: embed },
                RunKind::WebLink { url } => BodyRunKind::WebLink { url },
                RunKind::Tag { name } => BodyRunKind::Tag { name },
                RunKind::Image { source, alt, width, height } => BodyRunKind::Image { source, alt, width, height },
                RunKind::Bullet => BodyRunKind::Bullet,
                RunKind::Checkbox { done } => BodyRunKind::Checkbox { is_done: done },
                RunKind::QuoteMark => BodyRunKind::QuoteMark,
                RunKind::Callout { kind } => BodyRunKind::Callout { kind },
                RunKind::FenceInfo { info } => BodyRunKind::FenceInfo { info },
            },
        })
        .collect();
    BodyLayout { lines, runs, markers_in_text }
}

/// Something an editor does to a body beyond typing a character.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EditCommand {
    /// Return: a new line of the same sort.
    Newline,
    /// Delete at the start of a line's words: its marker is taken off.
    DeleteBackward,
    Indent,
    Outdent,
    MoveUp,
    MoveDown,
    DeleteRows,
    DuplicateRows,
    Bold,
    Italic,
    Strikethrough,
    Highlight,
    Code,
    /// A plain line → a checklist item → checked → a plain item.
    CycleChecklist,
    /// Made a task (`+ [ ]`), or a plain item again.
    ToggleTask,
    /// A click on a checkbox.
    ToggleCheckbox,
    Heading1,
    Heading2,
    Heading3,
    Bullet,
    Numbered,
    Quote,
}

/// What a command comes to: text to replace, and where the selection
/// then stands. Offsets are UTF-16; the range is of the body as it was,
/// the selection of the body as it then is.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BodyEdit {
    pub start: u32,
    pub end: u32,
    pub replacement: String,
    pub selection_start: u32,
    pub selection_end: u32,
}

fn command(command: EditCommand) -> Command {
    match command {
        EditCommand::Newline => Command::Newline,
        EditCommand::DeleteBackward => Command::DeleteBackward,
        EditCommand::Indent => Command::Indent,
        EditCommand::Outdent => Command::Outdent,
        EditCommand::MoveUp => Command::MoveUp,
        EditCommand::MoveDown => Command::MoveDown,
        EditCommand::DeleteRows => Command::DeleteRows,
        EditCommand::DuplicateRows => Command::DuplicateRows,
        EditCommand::Bold => Command::Toggle(Style::Strong),
        EditCommand::Italic => Command::Toggle(Style::Emphasis),
        EditCommand::Strikethrough => Command::Toggle(Style::Strikethrough),
        EditCommand::Highlight => Command::Toggle(Style::Highlight),
        EditCommand::Code => Command::Toggle(Style::Code),
        EditCommand::CycleChecklist => Command::CycleChecklist,
        EditCommand::ToggleTask => Command::ToggleTask,
        EditCommand::ToggleCheckbox => Command::ToggleCheckbox,
        EditCommand::Heading1 => Command::Heading(1),
        EditCommand::Heading2 => Command::Heading(2),
        EditCommand::Heading3 => Command::Heading(3),
        EditCommand::Bullet => Command::Bullet,
        EditCommand::Numbered => Command::Numbered,
        EditCommand::Quote => Command::Quote,
    }
}

/// How an editor shows a note's body.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EditorMode {
    /// The body's Markdown, as the file has it.
    Text,
    /// A row a block: its words, with what it is drawn beside them.
    Outline,
}

/// A note open for writing: what an editor holds.
///
/// The note is here — its frontmatter, its title, its body as a tree —
/// not in the text view. The view shows [`text`](Self::text), dressed by
/// [`layout`](Self::layout); tells the editor what was typed
/// ([`replace`](Self::replace)) and which command was given
/// ([`perform`](Self::perform)); and does what the answer says. The file
/// to save is [`markdown`](Self::markdown).
#[derive(uniffi::Object)]
pub struct NoteEditor {
    session: Mutex<Session>,
}

impl NoteEditor {
    fn session(&self) -> MutexGuard<'_, Session> {
        self.session.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// A change of the session's, in the view's own offsets: its range of
    /// the text as it was, its selection of the text as it now is.
    fn edit(before: &str, after: &str, change: prism::markup::session::Change) -> BodyEdit {
        let (was, is) = (Offsets::of(before), Offsets::of(after));
        BodyEdit {
            start: was.to16(change.range.start),
            end: was.to16(change.range.end),
            replacement: change.replacement,
            selection_start: is.to16(change.selection.start),
            selection_end: is.to16(change.selection.end),
        }
    }

    fn changing(&self, change: impl FnOnce(&mut Session, &Offsets) -> Option<prism::markup::session::Change>) -> Option<BodyEdit> {
        let mut session = self.session();
        let before = session.text().to_owned();
        let made = change(&mut session, &Offsets::of(&before))?;
        Some(NoteEditor::edit(&before, session.text(), made))
    }
}

#[uniffi::export]
impl NoteEditor {
    /// Opens a note's file.
    #[uniffi::constructor]
    pub fn open(source: String, mode: EditorMode) -> Arc<NoteEditor> {
        let mode = if mode == EditorMode::Outline { Mode::Outline } else { Mode::Text };
        Arc::new(NoteEditor { session: Mutex::new(Session::new(&source, mode)) })
    }

    /// The note's file, as it now is. What was not edited is as it was read.
    pub fn markdown(&self) -> String {
        self.session().markdown()
    }

    pub fn mode(&self) -> EditorMode {
        if self.session().mode() == Mode::Outline {
            EditorMode::Outline
        } else {
            EditorMode::Text
        }
    }

    /// Shows the body another way. The note is not changed.
    pub fn set_mode(&self, mode: EditorMode) {
        self.session().set_mode(if mode == EditorMode::Outline { Mode::Outline } else { Mode::Text });
    }

    /// What the view shows.
    pub fn text(&self) -> String {
        self.session().text().to_owned()
    }

    /// What the view shows, read for drawing.
    pub fn layout(&self) -> BodyLayout {
        let session = self.session();
        layout_of(session.layout(), session.text())
    }

    /// What was typed, pasted or deleted in the view: a range of what it
    /// showed, replaced. The answer is what the view should now do —
    /// which is not always what was typed.
    pub fn replace(&self, start: u32, end: u32, replacement: String) -> BodyEdit {
        let edit = self.changing(|session, offsets| Some(session.replace(offsets.to8(start)..offsets.to8(end.max(start)), &replacement)));
        edit.unwrap_or(BodyEdit { start, end, replacement: String::new(), selection_start: start, selection_end: start })
    }

    /// Carries out a command. `nil` when it has nothing to do there, and
    /// the view should do what it would have done.
    pub fn perform(&self, selection_start: u32, selection_end: u32, command: EditCommand) -> Option<BodyEdit> {
        self.changing(|session, offsets| session.perform(offsets.to8(selection_start)..offsets.to8(selection_end.max(selection_start)), self::command(command)))
    }

    /// Takes the last change back, structure and all.
    pub fn undo(&self) -> Option<BodyEdit> {
        self.changing(|session, _| session.undo())
    }

    pub fn redo(&self) -> Option<BodyEdit> {
        self.changing(|session, _| session.redo())
    }

    pub fn can_undo(&self) -> bool {
        self.session().can_undo()
    }

    pub fn can_redo(&self) -> bool {
        self.session().can_redo()
    }

    /// Whether nothing is written in the body.
    pub fn is_blank(&self) -> bool {
        self.session().body().is_blank()
    }

    /// The title the note's first heading gives.
    pub fn title(&self) -> Option<String> {
        self.session().title()
    }

    /// Titles the note: its first heading, made if it had none.
    pub fn set_title(&self, title: String) {
        self.session().set_title(&title);
    }

    /// What the note says about itself, for a note kept at `path`.
    pub fn meta(&self, path: String) -> NoteMeta {
        let meta = Note::parse(&self.session().markdown()).meta(&path);
        NoteMeta { names: meta.names(), title: meta.title, aliases: meta.aliases, tags: meta.tags, is_private: meta.private }
    }

    /// The frontmatter's entries, in the order written.
    pub fn fields(&self) -> Vec<FrontmatterField> {
        let session = self.session();
        let Some(front) = session.frontmatter() else { return Vec::new() };
        front.iter().map(|(key, value)| FrontmatterField { key: key.to_owned(), values: value.to_list(), is_list: matches!(value, Value::List(_)) }).collect()
    }

    /// Whether a field marks the note: it is there, with a value that
    /// does not say no. `pinned: 3` marks; `inbox: no` does not.
    pub fn is_marked(&self, key: String) -> bool {
        self.session().frontmatter().is_some_and(|front| front.flag(&key))
    }

    /// A field's first value, if it has one.
    pub fn field(&self, key: String) -> Option<String> {
        self.session().frontmatter().and_then(|front| front.list(&key).into_iter().next())
    }

    pub fn set_field(&self, key: String, value: String) {
        self.session().frontmatter_mut().set(&key, value);
    }

    /// Sets a field to a list, written an item a line.
    pub fn set_list_field(&self, key: String, values: Vec<String>) {
        self.session().frontmatter_mut().set_list_by_line(&key, values);
    }

    /// Takes a field out; and the frontmatter with it, if it was the last.
    pub fn remove_field(&self, key: String) -> bool {
        let mut session = self.session();
        let removed = session.frontmatter_mut().remove(&key);
        session.drop_empty_frontmatter();
        removed
    }
}

/// What is being typed that could be finished.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BodyCompletionKind {
    Link,
    Embed,
    Tag,
}

/// A name half-typed at the caret. Offsets are UTF-16.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BodyCompletion {
    pub kind: BodyCompletionKind,
    /// What has been typed of it, after the `[[` or the `#`.
    pub typed: String,
    /// All of it, markup included: what choosing a name replaces.
    pub start: u32,
    pub end: u32,
}

/// What is being typed at the caret that could be finished, if anything.
#[uniffi::export]
pub fn completion_at(body: String, caret: u32) -> Option<BodyCompletion> {
    let offsets = Offsets::of(&body);
    let found = editor::completion(&body, offsets.to8(caret))?;
    Some(BodyCompletion {
        kind: match found.kind {
            CompletionKind::Link => BodyCompletionKind::Link,
            CompletionKind::Embed => BodyCompletionKind::Embed,
            CompletionKind::Tag => BodyCompletionKind::Tag,
        },
        typed: found.typed,
        start: offsets.to16(found.range.start),
        end: offsets.to16(found.range.end),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offsets_cross_in_utf16() {
        let body = "- 🚀 **go** [[Café]]\n".to_owned();
        let layout = body_layout(body.clone());
        let units: Vec<u16> = body.encode_utf16().collect();
        let text = |run: &BodyRun| String::from_utf16(&units[run.start as usize..run.end as usize]).unwrap();
        assert!(layout.runs.iter().any(|run| run.kind == BodyRunKind::Strong && text(run) == "go"));
        assert!(layout.runs.iter().any(|run| matches!(&run.kind, BodyRunKind::PageLink { target, .. } if target == "Café") && text(run) == "Café"));
        assert_eq!((layout.lines[0].content, layout.lines[0].end), (2, units.len() as u32 - 1));
        let typed = completion_at("🚀 see [[Caf".into(), 12).unwrap();
        assert_eq!((typed.kind, typed.typed.as_str(), typed.start, typed.end), (BodyCompletionKind::Link, "Caf", 7, 12));
    }

    #[test]
    fn an_editor_is_the_note_and_the_view_follows_it() {
        let source = "---\ntags: [a]\n---\n# Atlas 🚀\n\n- one 🚀\n- two\n";
        let editor = NoteEditor::open(source.into(), EditorMode::Outline);
        assert_eq!((editor.text().as_str(), editor.title().as_deref()), ("one 🚀\ntwo", Some("Atlas 🚀")));
        assert!(!editor.layout().markers_in_text);
        // Typed after the rocket, in UTF-16 as a text view counts: "one 🚀" is 6 units.
        let edit = editor.replace(6, 6, "!".into());
        assert_eq!((edit.start, edit.end, edit.replacement.as_str(), edit.selection_start), (6, 6, "!", 7));
        // Return there: the view is told to put a line break in, and the note has a new row.
        let edit = editor.perform(7, 7, EditCommand::Newline).unwrap();
        assert_eq!((edit.start, edit.replacement.as_str(), edit.selection_start), (8, "\n", 8));
        assert_eq!(editor.markdown(), "---\ntags: [a]\n---\n# Atlas 🚀\n\n- one 🚀!\n- \n- two\n");
        // Indenting changes the note, and nothing the view shows.
        let edit = editor.perform(8, 8, EditCommand::Indent).unwrap();
        assert!(edit.start == edit.end && edit.replacement.is_empty() && edit.selection_start == 8);
        assert!(editor.undo().is_some() && editor.can_redo());
        // The same note as text: its Markdown, markers and all.
        editor.set_mode(EditorMode::Text);
        assert_eq!(editor.text(), "- one 🚀!\n- \n- two\n");
        assert!(editor.layout().markers_in_text);
        // Its title and fields are its own.
        editor.set_title("Atlas".into());
        editor.set_field("pinned".into(), "true".into());
        assert!(editor.remove_field("tags".into()));
        assert_eq!(editor.markdown(), "---\npinned: true\n---\n# Atlas\n\n- one 🚀!\n- \n- two\n");
        assert_eq!(editor.meta("notes/atlas.md".into()).title, "Atlas");
        assert_eq!(editor.fields().len(), 1);
    }
}
