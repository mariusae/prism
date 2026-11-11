//! A note open for writing, for Swift: `prism_markup::Session`, with
//! offsets in UTF-16 — a text view's own.
//!
//! [`NoteEditor`] is what an editor component holds. Its text view shows
//! what the session projects of the note's tree, and hands every change
//! made in it back to the session; the session, not the view, is the note.

use crate::document::{FrontmatterField, NoteMeta};
use crate::engine::RiverFoldedRow;
use prism::markup::editor::{self, Command, CompletionKind, Layout, LineKind, RowKind, RunKind};
use prism::markup::river::FoldedRow;
use prism::markup::{inline, Mode, Note, Session, Style, Value};
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
    /// In an outline: whether the row is folded — the rows under it are
    /// not shown, and so are no lines of the body.
    pub is_folded: bool,
    /// In an outline: whether the row has rows under it, shown or not.
    pub has_children: bool,
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
    layout_of(editor::layout(&body), &body, &[])
}

/// A layout in the view's own offsets. `folds` says of each line of an
/// outline whether it is folded, and whether it has rows under it.
fn layout_of(read: Layout, body: &str, folds: &[(bool, bool)]) -> BodyLayout {
    let offsets = Offsets::of(body);
    let markers_in_text = read.markers_in_text;
    let lines = read
        .lines
        .into_iter()
        .enumerate()
        .map(|(index, line)| BodyLine {
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
            is_folded: folds.get(index).is_some_and(|fold| fold.0),
            has_children: folds.get(index).is_some_and(|fold| fold.1),
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
    /// The rows above every sibling before them; below every one after.
    /// These, and the commands after them, are an outline's.
    MoveToTop,
    MoveToBottom,
    /// The rows under each row put out of sight; shown again.
    Fold,
    Unfold,
    ToggleFold,
    /// Each row folded, with every row under it that has rows of its own.
    FoldCompletely,
    UnfoldCompletely,
    /// Every row of the note that has rows under it, folded.
    FoldAll,
    UnfoldAll,
    /// The open tasks and checklist items among the rows, checked.
    MarkDone,
    /// The checked rows right under each row, put after the rest.
    MoveDoneToBottom,
    /// Made a row of this kind, whatever it was.
    TurnParagraph,
    TurnBullet,
    /// `- [ ]`: a checklist item.
    TurnCheckbox,
    /// `+ [ ]`: a task.
    TurnTask,
    TurnNumbered,
    TurnHeading1,
    TurnHeading2,
    TurnHeading3,
    TurnQuote,
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
        EditCommand::MoveToTop => Command::MoveToTop,
        EditCommand::MoveToBottom => Command::MoveToBottom,
        EditCommand::Fold => Command::Fold,
        EditCommand::Unfold => Command::Unfold,
        EditCommand::ToggleFold => Command::ToggleFold,
        EditCommand::FoldCompletely => Command::FoldCompletely,
        EditCommand::UnfoldCompletely => Command::UnfoldCompletely,
        EditCommand::FoldAll => Command::FoldAll,
        EditCommand::UnfoldAll => Command::UnfoldAll,
        EditCommand::MarkDone => Command::MarkDone,
        EditCommand::MoveDoneToBottom => Command::MoveDoneToBottom,
        EditCommand::TurnParagraph => Command::Turn(RowKind::Paragraph),
        EditCommand::TurnBullet => Command::Turn(RowKind::Bullet),
        EditCommand::TurnCheckbox => Command::Turn(RowKind::Checkbox),
        EditCommand::TurnTask => Command::Turn(RowKind::Task),
        EditCommand::TurnNumbered => Command::Turn(RowKind::Numbered),
        EditCommand::TurnHeading1 => Command::Turn(RowKind::Heading(1)),
        EditCommand::TurnHeading2 => Command::Turn(RowKind::Heading(2)),
        EditCommand::TurnHeading3 => Command::Turn(RowKind::Heading(3)),
        EditCommand::TurnQuote => Command::Turn(RowKind::Quote),
    }
}

/// What can be done to a row of an outline: what a menu for it offers.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BodyRowInfo {
    pub is_folded: bool,
    /// Whether it has rows under it, shown or folded away.
    pub has_children: bool,
    /// How many rows its fold hides.
    pub hidden: u32,
    /// How many rows are shown under it: the lines after its own that go
    /// where it goes.
    pub shown: u32,
    /// Whether a row under it, however deep, is folded: Unfold
    /// Completely has something to do.
    pub folds_inside: bool,
    /// Whether it is unfolded and a row under it could be folded: Fold
    /// Completely has something to do.
    pub open_inside: bool,
    /// Its checkbox: open, or done. `nil` for a row without one.
    pub done: Option<bool>,
    /// Whether it is a plain bullet with checkboxes among the rows under it.
    pub has_checklist: bool,
    /// Whether Move Done to Bottom has something to do under it.
    pub done_to_move: bool,
    /// Whether it has a row before it at its level, and one after it.
    pub can_move_up: bool,
    pub can_move_down: bool,
}

/// A time block starting at a row of an outline: what is drawn there.
/// See `prism_markup::time`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BodyTimeHead {
    /// Which timeline, and which of its blocks.
    pub timeline: u32,
    pub index: u32,
    /// How deep its timeline is within others.
    pub level: u32,
    /// Minutes from midnight.
    pub start: u32,
    pub end: u32,
    /// `9:00 – 10:30 · 1h 30m`.
    pub label: String,
    /// `overlaps Offsite 30m`, when it starts before an earlier one
    /// ends; and, where that is too long, `30m overlap`.
    pub overlap: Option<String>,
    pub overlap_short: Option<String>,
    /// Where its time is written in what the view shows, with what
    /// parts it from the words, in UTF-16: hidden where the label is
    /// drawn instead.
    pub stamp_start: u32,
    pub stamp_end: u32,
    /// The block's last row, and the next block's first.
    pub last_row: u32,
    pub next_row: Option<u32>,
    pub is_done: bool,
}

/// A time block ending at a row: the room after it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BodyTimeFoot {
    pub timeline: u32,
    pub index: u32,
    pub level: u32,
    /// Room for its length, in rows.
    pub length: f64,
    /// Free time after it, before the next: its minutes, its room in
    /// rows, and what it says — `2h free`.
    pub free: u32,
    pub free_length: f64,
    pub free_label: Option<String>,
    /// Whether it is its timeline's last: there the line ends.
    pub is_last: bool,
}

/// What an outline draws of a timeline at one of its rows.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BodyTimeMark {
    /// The row, counted among the body's lines.
    pub row: u32,
    pub head: Option<BodyTimeHead>,
    /// Innermost first.
    pub feet: Vec<BodyTimeFoot>,
}

/// A text that is a web or mail address and nothing else, trimmed: what,
/// pasted onto words, links them. `nil` for any other text.
#[uniffi::export]
pub fn web_address(text: String) -> Option<String> {
    inline::address(&text).map(str::to_owned)
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
        layout_of(session.layout(), session.text(), &session.row_folds())
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

    /// Carries out a command on some rows of an outline — lines of the
    /// body, counted from the first — wherever the caret is: the rows a
    /// finger is on, or those chosen together. Each takes what is under
    /// it along. The selection given is the view's own, and the answer
    /// says where it then is. For the commands done to rows; `nil` for one
    /// done at the caret, and as text.
    pub fn perform_on(&self, rows: Vec<u32>, selection_start: u32, selection_end: u32, command: EditCommand) -> Option<BodyEdit> {
        let rows: Vec<usize> = rows.into_iter().map(|row| row as usize).collect();
        self.changing(|session, offsets| {
            session.perform_on(&rows, offsets.to8(selection_start)..offsets.to8(selection_end.max(selection_start)), self::command(command))
        })
    }

    /// Puts rows of an outline, with what is under them, before another
    /// row — one past the last for the end — at a depth: what carrying a
    /// row and letting go does. The depth counts the rows a row is under,
    /// and is held to what can be there (`drop_depth`). `nil` when that
    /// is where they already are.
    pub fn move_rows(&self, rows: Vec<u32>, before: u32, depth: u32, selection_start: u32, selection_end: u32) -> Option<BodyEdit> {
        let rows: Vec<usize> = rows.into_iter().map(|row| row as usize).collect();
        self.changing(|session, offsets| {
            session.move_rows(&rows, before as usize, depth as usize, offsets.to8(selection_start)..offsets.to8(selection_end.max(selection_start)))
        })
    }

    /// How deep rows carried would lie, put down before a row at a depth
    /// asked for: what `move_rows` would give them. `nil` where they
    /// cannot be put down: among the rows under one of them.
    pub fn drop_depth(&self, rows: Vec<u32>, before: u32, depth: u32) -> Option<u32> {
        let rows: Vec<usize> = rows.into_iter().map(|row| row as usize).collect();
        self.session().drop_depth(&rows, before as usize, depth as usize).map(|depth| depth as u32)
    }

    /// What can be done to a row of an outline. `nil` for no such row.
    pub fn row_info(&self, row: u32) -> Option<BodyRowInfo> {
        let info = self.session().row_info(row as usize)?;
        Some(BodyRowInfo {
            is_folded: info.folded,
            has_children: info.has_children,
            hidden: info.hidden as u32,
            shown: info.shown as u32,
            folds_inside: info.folds_inside,
            open_inside: info.open_inside,
            done: info.task,
            has_checklist: info.has_checklist,
            done_to_move: info.done_to_move,
            can_move_up: info.can_move_up,
            can_move_down: info.can_move_down,
        })
    }

    /// Some rows of an outline, with what is under them, as Markdown of
    /// their own: what copying them puts on the pasteboard, and what goes
    /// with them to another note.
    pub fn markdown_of(&self, rows: Vec<u32>) -> String {
        let rows: Vec<usize> = rows.into_iter().map(|row| row as usize).collect();
        self.session().markdown_of(&rows)
    }

    /// A new time block where the caret is: from `now` — minutes from
    /// midnight, on the clock of whoever asks — for a quarter of an hour,
    /// put where its time goes among those there. The caret is left after
    /// its time. `nil` as text.
    pub fn new_time_block(&self, selection_start: u32, selection_end: u32, now: u32) -> Option<BodyEdit> {
        self.changing(|session, offsets| {
            session.perform(offsets.to8(selection_start)..offsets.to8(selection_end.max(selection_start)), Command::NewTimeBlock { now: now % (24 * 60) })
        })
    }

    /// What an outline draws of its timelines — lists whose every item
    /// starts with a time — row by row. `twelve_hour` says how the labels
    /// tell the time. Empty as text.
    pub fn time_marks(&self, twelve_hour: bool) -> Vec<BodyTimeMark> {
        let session = self.session();
        let marks = session.time_marks(twelve_hour);
        if marks.is_empty() {
            return Vec::new();
        }
        let offsets = Offsets::of(session.text());
        marks
            .into_iter()
            .map(|mark| BodyTimeMark {
                row: mark.row as u32,
                head: mark.head.map(|head| BodyTimeHead {
                    timeline: head.timeline as u32,
                    index: head.index as u32,
                    level: head.level as u32,
                    start: head.start,
                    end: head.end,
                    label: head.label,
                    overlap: head.overlap,
                    overlap_short: head.overlap_short,
                    stamp_start: offsets.to16(head.stamp.start),
                    stamp_end: offsets.to16(head.stamp.end),
                    last_row: head.last_row as u32,
                    next_row: head.next_row.map(|row| row as u32),
                    is_done: head.done,
                }),
                feet: mark
                    .feet
                    .into_iter()
                    .map(|foot| BodyTimeFoot {
                        timeline: foot.timeline as u32,
                        index: foot.index as u32,
                        level: foot.level as u32,
                        length: foot.length,
                        free: foot.free,
                        free_length: foot.free_length,
                        free_label: foot.free_label,
                        is_last: foot.is_last,
                    })
                    .collect(),
            })
            .collect()
    }

    /// Links the words selected to an address — `[words](address)` — or
    /// points the link they are the words of there: what pasting an
    /// address onto words does. `nil` when nothing is selected, when the
    /// selection spans lines, or when the address is none (`web_address`).
    pub fn link(&self, selection_start: u32, selection_end: u32, address: String) -> Option<BodyEdit> {
        self.changing(|session, offsets| session.link(offsets.to8(selection_start)..offsets.to8(selection_end.max(selection_start)), &address))
    }

    /// The rows folded: each by its place among all the body's rows —
    /// shown or not — and its words. The form a river keeps them in, for
    /// an app to save and hand back.
    pub fn folded_rows(&self) -> Vec<RiverFoldedRow> {
        self.session().folded_rows().into_iter().map(|row| RiverFoldedRow { index: row.index as u32, text: row.text }).collect()
    }

    /// Folds these rows, and no others: as the app remembers them. A row
    /// is found by its words, at its place or nearest to it; one no
    /// longer there, or with nothing under it, is passed over. Says
    /// whether anything changed: if it did, the view shows other text,
    /// and what was done before cannot be undone after.
    pub fn set_folded_rows(&self, rows: Vec<RiverFoldedRow>) -> bool {
        let rows: Vec<FoldedRow> = rows.into_iter().map(|row| FoldedRow { index: row.index as usize, text: row.text }).collect();
        self.session().set_folded_rows(&rows)
    }

    // --- Focus: one row of the outline, shown as a note of its own ------------

    /// The name of a row shown — a line of the outline, counted from the
    /// first — given one now if it had none. A name is written in the
    /// note, after the row, where nothing shows it; it is what
    /// `set_focus` takes and what a river's card keeps. `nil` for a row
    /// that is no list's: only those can have rows under them.
    pub fn row_name(&self, row: u32) -> Option<String> {
        self.session().anchor_row(row as usize)
    }

    /// Shows only what is under the row of a name — or, given none, the
    /// whole note again. What is written is written in the note all the
    /// same, and `markdown` is the whole file. Says whether there is
    /// such a row; if not, the whole note is shown.
    pub fn set_focus(&self, name: Option<String>) -> bool {
        self.session().set_focus(name.as_deref())
    }

    /// The name of the row focused on, when one is.
    pub fn focus(&self) -> Option<String> {
        self.session().focus()
    }

    /// The words of the row focused on, as they are written: the title
    /// of what is shown.
    pub fn focus_title(&self) -> Option<String> {
        self.session().focus_title()
    }

    /// The row focused on as it reads, its Markdown taken out.
    pub fn focus_label(&self) -> Option<String> {
        self.session().focus_label()
    }

    /// Writes the row focused on anew.
    pub fn set_focus_title(&self, title: String) {
        self.session().set_focus_title(&title)
    }

    /// The rows the row focused on is under, outermost first, each as
    /// it reads: the way to it from the note's top.
    pub fn focus_trail(&self) -> Vec<String> {
        self.session().focus_trail()
    }

    /// The name of a row the row focused on is under — `levels` 1 the
    /// one right over it — given one now if it had none: what to focus
    /// on to see more. `nil` when that far out is the whole note.
    pub fn focus_out(&self, levels: u32) -> Option<String> {
        self.session().focus_out(levels as usize)
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

    /// Whether the note, kept at `path`, was never given a title: no
    /// first heading, and a file's name that says nothing.
    pub fn is_untitled(&self, path: String) -> bool {
        self.session().is_untitled(&path)
    }

    /// What the note, kept at `path`, is called where it is shown: its
    /// title, or — untitled — its first words.
    pub fn label(&self, path: String) -> String {
        let label = self.session().label(&path);
        crate::shown_label(&path, label)
    }

    /// The words an untitled note could be titled by: its first line's.
    pub fn first_line(&self) -> Option<String> {
        self.session().first_line()
    }

    /// Takes the first line out of the body and gives its words: to
    /// title the note by. What it held under it moves up into its place.
    pub fn take_first_line(&self) -> Option<String> {
        self.session().take_first_line()
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
    /// `@typed`: a page looked for, by name or by what it says, to link to.
    Mention,
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
            CompletionKind::Mention => BodyCompletionKind::Mention,
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

    #[test]
    fn rows_fold_move_and_tell_the_time_in_the_views_own_offsets() {
        let editor = NoteEditor::open("- 🚀 one\n  - 9:00–9:30 two\n  - 10:00 three\n- last\n".into(), EditorMode::Outline);
        // Folded from elsewhere: the caret, in "last", stays in its word.
        let caret = editor.text().encode_utf16().count() as u32 - 2;
        let edit = editor.perform_on(vec![0], caret, caret, EditCommand::Fold).unwrap();
        assert_eq!((editor.text().as_str(), edit.selection_start), ("🚀 one\nlast", caret - 26));
        let lines = editor.layout().lines;
        assert_eq!((lines[0].is_folded, lines[0].has_children, lines[1].is_folded), (true, true, false));
        assert_eq!(editor.folded_rows(), [RiverFoldedRow { index: 0, text: "🚀 one".into() }]);
        assert_eq!(editor.row_info(0).map(|info| (info.is_folded, info.hidden, info.can_move_down)), Some((true, 2, true)));
        assert!(!editor.set_folded_rows(editor.folded_rows()) && editor.set_folded_rows(Vec::new()));
        assert_eq!(editor.text().lines().count(), 4);
        // A timeline's marks, where the time is written in UTF-16: after the rocket's two units.
        let marks = editor.time_marks(false);
        let head = marks[0].head.clone().unwrap();
        assert_eq!((marks[0].row, head.label.as_str(), head.stamp_start, head.stamp_end), (1, "9:00 – 9:30 · 30m", 7, 17));
        // Carried to the top; copied; a time block made; an address pasted on a word.
        assert_eq!(editor.drop_depth(vec![3], 0, 4), Some(0));
        editor.move_rows(vec![3], 0, 0, 0, 0).unwrap();
        assert_eq!(editor.markdown_of(vec![0, 1]), "- last\n- 🚀 one\n  - 9:00–9:30 two\n  - 10:00 three\n");
        let end = editor.text().encode_utf16().count() as u32;
        editor.new_time_block(end, end, 12 * 60 + 3).unwrap();
        assert!(editor.markdown().ends_with("  - 10:00 three\n  - 12:00–12:15 \n"), "{}", editor.markdown());
        assert_eq!(web_address(" https://example.com ".into()).as_deref(), Some("https://example.com"));
        let edit = editor.link(0, 4, "https://example.com".into()).unwrap();
        assert!(editor.text().starts_with("[last](https://example.com)\n") && edit.selection_start == 27);
    }
}
