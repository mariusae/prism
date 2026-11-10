//! An editing session: a note being written, held as what it is.
//!
//! An editor does not edit text. It edits a note — its frontmatter, its
//! title, and its body as a tree of [`Block`]s — and a [`Session`] is that
//! note, open. A text view is only how the body is *shown* while it is
//! written: the session gives it a **projection** of the tree to display
//! ([`Session::text`], [`Session::layout`]), takes every change made in
//! the view as a change to the tree ([`Session::replace`],
//! [`Session::perform`]), and answers with what the view should then show
//! ([`Change`]).
//!
//! # Two ways of showing one tree
//!
//! - **[`Mode::Outline`]**: a row a block. The view holds each block's
//!   words and nothing else; what kind of block it is — a bullet, a task,
//!   a heading — and how deep, is for the view to draw beside them. Return
//!   splits a block, Tab puts it under the one before, and every such
//!   command is an operation on the tree ([`crate::outline`]).
//! - **[`Mode::Text`]**: the body as its Markdown. The view holds the
//!   text of the file; a change to it is read back into the tree.
//!
//! They are the same note, and going from one to the other changes no
//! byte of it: a session's [`markdown`](Session::markdown) is the file,
//! and what was not edited is written as it was read.
//!
//! Offsets are bytes of the projection. In an outline, a line break
//! *inside* a block — a paragraph of two lines, a code block — is shown
//! as U+2028, so that a row is always one line of the view.

use crate::block::{Block, BlockKind, Document, Item, Marker, Task};
use crate::editor::{self, Command, Layout, Line, LineKind};
use crate::frontmatter::Frontmatter;
use crate::inline;
use crate::outline::{self, Path};
use std::ops::Range;

/// How a session shows its body.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// The body's Markdown, as the file has it.
    Text,
    /// A row a block: its words, with what it is drawn beside them.
    Outline,
}

/// What a view should do after the session changed: replace a range of
/// what it shows, and put the selection somewhere.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Change {
    /// The range to replace, of the projection as it was.
    pub range: Range<usize>,
    pub replacement: String,
    /// The selection after, in the projection as it then is.
    pub selection: Range<usize>,
}

/// A line break inside a block, as an outline shows it.
pub const SOFT_BREAK: char = '\u{2028}';

#[derive(Debug, Clone, PartialEq, Eq)]
struct RowSpan {
    path: Path,
    range: Range<usize>,
}

/// A note, open for writing. See the [module docs](self).
#[derive(Debug, Clone)]
pub struct Session {
    frontmatter: Option<Frontmatter>,
    /// The line that titles the note, with the blank lines after it: kept
    /// apart, since a card shows the title on its own.
    heading: String,
    body: Document,
    mode: Mode,
    /// What the view shows.
    text: String,
    /// In an outline: each row's block, and where its words are.
    rows: Vec<RowSpan>,
    /// The body as it was before each change, newest last, with the
    /// selection there was: what Undo goes back to.
    undone: Vec<(Document, Range<usize>)>,
    redone: Vec<(Document, Range<usize>)>,
    /// Where the last typing left the caret: typing on from there is
    /// part of the same change.
    typing: Option<usize>,
}

impl Session {
    /// Opens a note's file.
    pub fn new(source: &str, mode: Mode) -> Session {
        let (frontmatter, rest) = Frontmatter::split(source);
        let heading_len = heading_len(rest);
        let mut session = Session {
            frontmatter,
            heading: rest[..heading_len].to_owned(),
            body: Document::parse(&rest[heading_len..]),
            mode,
            text: String::new(),
            rows: Vec::new(),
            undone: Vec::new(),
            redone: Vec::new(),
            typing: None,
        };
        session.project();
        session
    }

    /// The note's file, as it now is. What was not edited is as it was read.
    pub fn markdown(&self) -> String {
        let front = self.frontmatter.as_ref().map(ToString::to_string).unwrap_or_default();
        format!("{front}{}{}", self.heading, self.body.to_markdown())
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    /// Shows the body another way. The note is not changed. (What was
    /// done before cannot be undone after: its selections were of the
    /// other showing.)
    pub fn set_mode(&mut self, mode: Mode) {
        self.mode = mode;
        self.undone.clear();
        self.redone.clear();
        self.typing = None;
        self.project();
    }

    // --- Undoing ---------------------------------------------------------------

    /// Remembers the body as it is, before a change to it.
    fn remember(&mut self, selection: Range<usize>) {
        const KEPT: usize = 200;
        self.undone.push((self.body.clone(), selection));
        if self.undone.len() > KEPT {
            self.undone.remove(0);
        }
        self.redone.clear();
    }

    pub fn can_undo(&self) -> bool {
        !self.undone.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redone.is_empty()
    }

    /// Takes the last change back: the tree as it was, structure and all
    /// — an indent is undone though no word of the view moved. `None`
    /// when there is nothing to undo.
    pub fn undo(&mut self) -> Option<Change> {
        let (body, selection) = self.undone.pop()?;
        self.restore(body, selection, false)
    }

    /// Makes again a change that was undone.
    pub fn redo(&mut self) -> Option<Change> {
        let (body, selection) = self.redone.pop()?;
        self.restore(body, selection, true)
    }

    fn restore(&mut self, body: Document, selection: Range<usize>, redoing: bool) -> Option<Change> {
        let before = std::mem::take(&mut self.text);
        let now = (std::mem::replace(&mut self.body, body), selection.clone());
        if redoing { &mut self.undone } else { &mut self.redone }.push(now);
        self.typing = None;
        self.project();
        let (range, replacement) = difference(&before, &self.text);
        // Back where the change was made — or, made again, just after it.
        let selection = if redoing { range.start + replacement.len()..range.start + replacement.len() } else { clamp(&self.text, selection) };
        Some(Change { range, replacement, selection })
    }

    /// What the view shows.
    pub fn text(&self) -> &str {
        &self.text
    }

    /// The body, as a tree.
    pub fn body(&self) -> &Document {
        &self.body
    }

    pub fn frontmatter(&self) -> Option<&Frontmatter> {
        self.frontmatter.as_ref()
    }

    /// The frontmatter, made if the note had none.
    pub fn frontmatter_mut(&mut self) -> &mut Frontmatter {
        self.frontmatter.get_or_insert_with(Frontmatter::new)
    }

    /// Takes the frontmatter away, if nothing is left in it.
    pub fn drop_empty_frontmatter(&mut self) {
        if self.frontmatter.as_ref().is_some_and(Frontmatter::is_empty) {
            self.frontmatter = None;
        }
    }

    /// The title the note's first heading gives, its markup taken out.
    pub fn title(&self) -> Option<String> {
        let line = self.heading.lines().next()?;
        let words = line.strip_prefix("# ")?.trim();
        (!words.is_empty()).then(|| inline::plain_text(words.trim_end_matches('#')))
    }

    /// Titles the note: its first heading, made if it had none.
    pub fn set_title(&mut self, title: &str) {
        let title = title.trim();
        if title.is_empty() {
            return;
        }
        self.heading = match self.heading.split_once('\n') {
            Some((_, after)) => format!("# {title}\n{after}"),
            None if self.heading.is_empty() => format!("# {title}\n\n"),
            None => format!("# {title}"),
        };
    }

    // --- Showing ---------------------------------------------------------------

    fn project(&mut self) {
        self.rows.clear();
        match self.mode {
            Mode::Text => self.text = self.body.to_markdown(),
            Mode::Outline => {
                let mut text = String::new();
                for (index, row) in self.body.rows().into_iter().enumerate() {
                    if index > 0 {
                        text.push('\n');
                    }
                    let start = text.len();
                    text.extend(row.block.text.chars().map(|c| if c == '\n' { SOFT_BREAK } else { c }));
                    self.rows.push(RowSpan { path: row.path, range: start..text.len() });
                }
                self.text = text;
            }
        }
    }

    /// What the view shows, read for drawing: each line and what it is,
    /// each run and what it means. In an outline a line is a row, and its
    /// marker is not in the text: [`Layout::markers_in_text`] says which.
    pub fn layout(&self) -> Layout {
        match self.mode {
            Mode::Text => editor::layout(&self.text),
            Mode::Outline => {
                let mut layout = Layout { lines: Vec::with_capacity(self.rows.len()), runs: Vec::new(), markers_in_text: false };
                for row in &self.rows {
                    let Some(block) = self.body.get(&row.path) else { continue };
                    let (kind, depth) = match &block.kind {
                        BlockKind::Item(item) => {
                            let (ordered, bullet) = match item.marker {
                                Marker::Bullet(bullet) => (None, bullet),
                                Marker::Ordered { number, delimiter } => (Some(number), delimiter),
                            };
                            (LineKind::Item { ordered, task: item.task.map(Task::is_done), bullet }, row.path.len())
                        }
                        BlockKind::Paragraph | BlockKind::Raw => (LineKind::Paragraph, row.path.len() - 1),
                        BlockKind::Heading(level) => (LineKind::Heading(*level), row.path.len() - 1),
                        BlockKind::Quote => (LineKind::Quote, row.path.len() - 1),
                        BlockKind::Code => (LineKind::Code, row.path.len() - 1),
                        BlockKind::Table => (LineKind::Table, row.path.len() - 1),
                        BlockKind::Rule => (LineKind::Rule, row.path.len() - 1),
                    };
                    if block.has_inline_content() {
                        editor::read_inline(&self.text, row.range.clone(), &mut layout.runs);
                    }
                    layout.lines.push(Line { range: row.range.clone(), kind, indent: 0, content: row.range.start, depth });
                }
                layout
            }
        }
    }

    // --- Writing ---------------------------------------------------------------

    /// What was typed, pasted or deleted in the view: a range of what it
    /// shows, replaced. The note is changed to match, and the answer is
    /// what the view should then do — which is not always what was typed:
    /// in an outline, `- ` typed at the start of a line makes it a bullet.
    pub fn replace(&mut self, range: Range<usize>, replacement: &str) -> Change {
        let range = clamp(&self.text, range);
        // Typing on from where typing left off is one change to undo.
        let typing_on =
            range.is_empty() && self.typing == Some(range.start) && !replacement.contains('\n') && replacement != " " && replacement.chars().count() == 1;
        if !typing_on {
            self.remember(range.clone());
        }
        let change = self.replace_now(range, replacement);
        self.typing = (replacement.chars().count() == 1 && !replacement.contains('\n') && !replacement.contains(' ')).then_some(change.selection.end);
        change
    }

    fn replace_now(&mut self, range: Range<usize>, replacement: &str) -> Change {
        match self.mode {
            Mode::Text => {
                let mut text = self.text.clone();
                text.replace_range(range.clone(), replacement);
                self.body = Document::parse(&text);
                self.text = text;
                let caret = range.start + replacement.len();
                Change { range, replacement: replacement.to_owned(), selection: caret..caret }
            }
            Mode::Outline => self.replace_rows(range, replacement),
        }
    }

    /// Carries out a command. `None` when it has nothing to do there, and
    /// the view should do what it would have done.
    pub fn perform(&mut self, selection: Range<usize>, command: Command) -> Option<Change> {
        let selection = clamp(&self.text, selection);
        self.remember(selection.clone());
        self.typing = None;
        let change = self.perform_now(selection, command);
        if change.is_none() {
            // Nothing was done: nothing to undo.
            self.undone.pop();
        }
        change
    }

    fn perform_now(&mut self, selection: Range<usize>, command: Command) -> Option<Change> {
        match self.mode {
            Mode::Text => {
                let edit = editor::perform(&self.text, selection, command)?;
                self.text = edit.apply(&self.text);
                self.body = Document::parse(&self.text);
                Some(Change { range: edit.range, replacement: edit.replacement, selection: edit.selection })
            }
            Mode::Outline => self.perform_rows(selection, command),
        }
    }

    // --- An outline's rows -------------------------------------------------------

    /// The row an offset is in.
    fn row_at(&self, offset: usize) -> usize {
        self.rows.partition_point(|row| row.range.end < offset).min(self.rows.len().saturating_sub(1))
    }

    fn row_of(&self, path: &[usize]) -> Option<&RowSpan> {
        self.rows.iter().find(|row| row.path == path)
    }

    /// Where a place in a block's words is in the view.
    fn place(&self, path: &[usize], offset: usize) -> usize {
        self.row_of(path).map_or(self.text.len(), |row| (row.range.start + offset).min(row.range.end))
    }

    /// After a change to the tree: shows it again, and says how the view
    /// gets from what it showed to what it should.
    fn changed(&mut self, before: String, caret: (Path, usize), anchor: Option<(Path, usize)>) -> Change {
        self.project();
        let (range, replacement) = difference(&before, &self.text);
        let end = self.place(&caret.0, caret.1);
        let start = anchor.map_or(end, |(path, offset)| self.place(&path, offset));
        Change { range, replacement, selection: start.min(end)..start.max(end) }
    }

    fn replace_rows(&mut self, range: Range<usize>, replacement: &str) -> Change {
        let before = self.text.clone();
        if self.rows.is_empty() {
            // Nothing written yet: the first words make the first row.
            self.body.blocks.push(Block::bullet(""));
            self.project();
        }
        let (first, last) = (self.row_at(range.start), self.row_at(range.end));
        let prefix = self.text[self.rows[first].range.start..range.start].to_owned();
        let suffix = self.text[range.end..self.rows[last].range.end].to_owned();
        let mut path = self.rows[first].path.clone();

        // The rows after the first that the range reaches into are joined onto it.
        for _ in first..last {
            let rows = self.body.rows();
            let Some(position) = rows.iter().position(|row| row.path == path) else { break };
            let Some(next) = rows.get(position + 1).map(|row| row.path.clone()) else { break };
            drop(rows);
            if outline::join_with_previous(&mut self.body, &next).is_none() {
                // A block that does not join — code, a table — is taken out whole.
                outline::remove(&mut self.body, &next);
            }
        }

        let splits = self
            .body
            .get(&path)
            .is_some_and(|block| matches!(block.kind, BlockKind::Paragraph | BlockKind::Heading(_) | BlockKind::Item(_) | BlockKind::Quote));
        let written = format!("{prefix}{replacement}{suffix}");
        // Inside a block that is one piece, a line break stays inside it.
        let pieces: Vec<&str> = if splits { written.split('\n').collect() } else { vec![written.as_str()] };
        let own = |piece: &str| piece.replace(SOFT_BREAK, "\n");
        if let Some(block) = self.body.get_mut(&path) {
            block.text = if splits { own(pieces[0]) } else { own(&written).replace('\r', "") };
        }
        for piece in &pieces[1..] {
            let end = self.body.get(&path).map_or(0, |block| block.text.len());
            let Some(next) = outline::split(&mut self.body, &path, end) else { break };
            if let Some(block) = self.body.get_mut(&next) {
                block.text = own(piece);
            }
            path = next;
        }
        let last_piece = pieces.last().copied().unwrap_or("");
        let mut caret = (path.clone(), last_piece.len() - suffix.len().min(last_piece.len()));

        // A marker typed at a row's start makes the row that kind.
        if replacement == " " && pieces.len() == 1 && first == last {
            if let Some(kind) = self.typed_marker(&path, &prefix) {
                if let Some(block) = self.body.get_mut(&path) {
                    block.text = own(&suffix);
                }
                outline::set_kind(&mut self.body, &path, kind);
                caret = (path, 0);
            }
        }
        self.changed(before, caret, None)
    }

    /// The kind a row becomes when this was typed at its start, then a space.
    fn typed_marker(&self, path: &[usize], typed: &str) -> Option<BlockKind> {
        let block = self.body.get(path)?;
        let plain_item = matches!(&block.kind, BlockKind::Item(Item { task: None, marker: Marker::Bullet(_) }));
        if !(block.kind == BlockKind::Paragraph || plain_item) {
            return None;
        }
        let item = |marker: Marker, task: Option<Task>| Some(BlockKind::Item(Item { marker, task }));
        let bullet = match &block.kind {
            BlockKind::Item(Item { marker: Marker::Bullet(bullet), .. }) => *bullet,
            _ => '-',
        };
        match typed {
            "-" | "*" if !plain_item => item(Marker::Bullet(typed.chars().next()?), None),
            "+" => item(Marker::Bullet('+'), Some(Task::Open)),
            "[]" | "[ ]" | "-[]" => item(Marker::Bullet(bullet), Some(Task::Open)),
            "[x]" | "[X]" => item(Marker::Bullet(bullet), Some(Task::Done('x'))),
            ">" => Some(BlockKind::Quote),
            hashes if !hashes.is_empty() && hashes.len() <= 6 && hashes.bytes().all(|b| b == b'#') => Some(BlockKind::Heading(hashes.len() as u8)),
            numbered => {
                let (digits, delimiter) = numbered.split_at(numbered.len().checked_sub(1)?);
                let delimiter = delimiter.chars().next().filter(|c| *c == '.' || *c == ')')?;
                let number = digits.parse().ok().filter(|_| digits.len() <= 9)?;
                item(Marker::Ordered { number, delimiter }, None)
            }
        }
    }

    fn perform_rows(&mut self, selection: Range<usize>, command: Command) -> Option<Change> {
        if self.rows.is_empty() {
            return None;
        }
        let before = self.text.clone();
        let collapsed = selection.start == selection.end;
        let (first, mut last) = (self.row_at(selection.start), self.row_at(selection.end));
        // A selection ending at a row's very start does not take that row.
        if last > first && self.rows[last].range.start == selection.end {
            last -= 1;
        }
        let start = (self.rows[first].path.clone(), selection.start - self.rows[first].range.start);
        let end_row = self.row_at(selection.end);
        let end = (self.rows[end_row].path.clone(), selection.end - self.rows[end_row].range.start);
        // The rows chosen, without those under another that is chosen.
        let mut chosen: Vec<Path> = Vec::new();
        for row in &self.rows[first..=last] {
            if !chosen.iter().any(|top| row.path.starts_with(top)) {
                chosen.push(row.path.clone());
            }
        }
        let path = start.0.clone();
        let kind = self.body.get(&path)?.kind.clone();
        // A place in the tree, after a block and what is under it moved.
        let follow = |moves: &[(Path, Path)], place: &(Path, usize)| -> (Path, usize) {
            for (from, to) in moves {
                if place.0.starts_with(from) {
                    return ([to.as_slice(), &place.0[from.len()..]].concat(), place.1);
                }
            }
            place.clone()
        };

        match command {
            Command::Newline => {
                if !collapsed {
                    return Some(self.replace_rows(selection, "\n"));
                }
                if !matches!(kind, BlockKind::Paragraph | BlockKind::Heading(_) | BlockKind::Item(_) | BlockKind::Quote) {
                    // In code, a line of the same block.
                    return Some(self.replace_rows(selection, &SOFT_BREAK.to_string()));
                }
                let block = self.body.get(&path)?;
                if block.text.is_empty() && block.children.is_empty() && matches!(kind, BlockKind::Item(_) | BlockKind::Quote) {
                    // Return on a row with nothing in it: out a level, then plain.
                    if path.len() > 1 {
                        let out = outline::outdent(&mut self.body, &path)?;
                        return Some(self.changed(before, (out, 0), None));
                    }
                    outline::set_kind(&mut self.body, &path, BlockKind::Paragraph);
                    return Some(self.changed(before, (path, 0), None));
                }
                let offset = own_offset(&self.text[self.rows[first].range.clone()], start.1);
                let next = outline::split(&mut self.body, &path, offset)?;
                Some(self.changed(before, (next, 0), None))
            }
            Command::DeleteBackward => {
                if !collapsed || start.1 != 0 {
                    return None;
                }
                match kind {
                    // First its checkbox, then what makes it more than a line…
                    BlockKind::Item(Item { task: Some(_), marker }) => {
                        outline::set_kind(&mut self.body, &path, BlockKind::Item(Item { marker, task: None }));
                    }
                    BlockKind::Heading(_) | BlockKind::Quote | BlockKind::Item(Item { marker: Marker::Ordered { .. }, .. }) => {
                        outline::set_kind(&mut self.body, &path, BlockKind::Paragraph);
                    }
                    // …then it joins the row before.
                    _ => {
                        let (onto, offset) = outline::join_with_previous(&mut self.body, &path)?;
                        let offset = shown_offset(&self.body.get(&onto)?.text, offset);
                        return Some(self.changed(before, (onto, offset), None));
                    }
                }
                Some(self.changed(before, (path, 0), None))
            }
            Command::Indent | Command::Outdent | Command::MoveUp | Command::MoveDown => {
                let mut moves: Vec<(Path, Path)> = Vec::new();
                // Moved down, the last goes first, so each has room.
                let order: Vec<Path> = if command == Command::MoveDown { chosen.iter().rev().cloned().collect() } else { chosen.clone() };
                for from in order {
                    // Earlier moves may have moved this one's place.
                    let at = follow(&moves, &(from.clone(), 0)).0;
                    let to = match command {
                        Command::Indent => outline::indent(&mut self.body, &at),
                        Command::Outdent => outline::outdent(&mut self.body, &at),
                        Command::MoveUp => outline::move_up(&mut self.body, &at),
                        _ => outline::move_down(&mut self.body, &at),
                    };
                    match to {
                        Some(to) => moves.insert(0, (at, to)),
                        // The first could not go: none of them does.
                        None if moves.is_empty() => return None,
                        None => break,
                    }
                }
                // Each place followed through the moves, in the order they were made.
                let through = |place: &(Path, usize)| moves.iter().rev().fold(place.clone(), |place, step| follow(std::slice::from_ref(step), &place));
                let (caret, anchor) = (through(&end), through(&start));
                Some(self.changed(before, caret, Some(anchor)))
            }
            Command::DeleteRows => {
                let position = first;
                for path in chosen.iter().rev() {
                    outline::remove(&mut self.body, path);
                }
                self.project();
                let caret = self.rows.get(position.min(self.rows.len().saturating_sub(1))).map(|row| (row.path.clone(), 0)).unwrap_or((vec![0], 0));
                Some(self.changed(before, caret, None))
            }
            Command::DuplicateRows => {
                let mut moves = Vec::new();
                for path in chosen.iter().rev() {
                    if let Some(copy) = outline::duplicate(&mut self.body, path) {
                        moves.push((path.clone(), copy));
                    }
                }
                let caret = follow(&moves, &end);
                let anchor = follow(&moves, &start);
                Some(self.changed(before, caret, Some(anchor)))
            }
            Command::Toggle(style) => {
                if first != self.row_at(selection.end) || !self.body.get(&path)?.has_inline_content() {
                    return None;
                }
                let row = self.rows[first].range.clone();
                let (styled, range) = inline::toggle(&self.text[row.clone()], start.1..end.1, style);
                self.body.get_mut(&path)?.text = styled.replace(SOFT_BREAK, "\n");
                Some(self.changed(before, (path.clone(), range.end), Some((path, range.start))))
            }
            Command::CycleChecklist
            | Command::ToggleTask
            | Command::ToggleCheckbox
            | Command::Heading(_)
            | Command::Bullet
            | Command::Numbered
            | Command::Quote => {
                let mut any = false;
                for path in &chosen {
                    let Some(kind) = self.body.get(path).map(|block| block.kind.clone()) else { continue };
                    if let Some(next) = turned(&kind, &command) {
                        outline::set_kind(&mut self.body, path, next);
                        any = true;
                    }
                }
                any.then(|| self.changed(before, end, Some(start)))
            }
        }
    }
}

/// What a block of a kind becomes under a command; `None` when the
/// command has nothing to say to it.
fn turned(kind: &BlockKind, command: &Command) -> Option<BlockKind> {
    let item = |marker: Marker, task: Option<Task>| BlockKind::Item(Item { marker, task });
    let (marker, task) = match kind {
        BlockKind::Item(item) => (Some(item.marker), item.task),
        BlockKind::Paragraph | BlockKind::Heading(_) | BlockKind::Quote => (None, None),
        _ => return None,
    };
    let bullet = match marker {
        Some(Marker::Bullet(bullet)) => Some(bullet),
        _ => None,
    };
    let dash = bullet.filter(|b| *b != '+').unwrap_or('-');
    Some(match command {
        Command::CycleChecklist => match task {
            None => item(Marker::Bullet(dash), Some(Task::Open)),
            Some(Task::Open) => item(marker.unwrap_or(Marker::Bullet('-')), Some(Task::Done('x'))),
            Some(Task::Done(_)) => item(Marker::Bullet(dash), None),
        },
        Command::ToggleTask => match (bullet, task) {
            (Some('+'), Some(_)) => item(Marker::Bullet('-'), None),
            _ => item(Marker::Bullet('+'), Some(Task::Open)),
        },
        Command::ToggleCheckbox => match task {
            Some(Task::Open) => item(marker?, Some(Task::Done('x'))),
            Some(Task::Done(_)) => item(marker?, Some(Task::Open)),
            None => return None,
        },
        Command::Heading(level) => {
            if *kind == BlockKind::Heading(*level) {
                BlockKind::Paragraph
            } else {
                BlockKind::Heading((*level).clamp(1, 6))
            }
        }
        Command::Bullet => {
            if bullet.is_some() && task.is_none() {
                BlockKind::Paragraph
            } else {
                item(Marker::Bullet('-'), None)
            }
        }
        Command::Numbered => {
            if matches!(marker, Some(Marker::Ordered { .. })) {
                BlockKind::Paragraph
            } else {
                item(Marker::Ordered { number: 1, delimiter: '.' }, None)
            }
        }
        Command::Quote => {
            if *kind == BlockKind::Quote {
                BlockKind::Paragraph
            } else {
                BlockKind::Quote
            }
        }
        _ => return None,
    })
}

/// How much of a note's text after its frontmatter is its title: a first
/// line that is `# Title`, with the blank lines after it.
fn heading_len(rest: &str) -> usize {
    let first = rest.split_inclusive('\n').next().unwrap_or("");
    let words = first.trim_end_matches(['\n', '\r']);
    if words.strip_prefix("# ").is_none_or(|title| title.trim().is_empty()) {
        return 0;
    }
    let mut end = first.len();
    for line in rest[end..].split_inclusive('\n') {
        if !line.trim().is_empty() {
            break;
        }
        end += line.len();
    }
    end
}

fn clamp(text: &str, range: Range<usize>) -> Range<usize> {
    let floor = |mut at: usize| {
        at = at.min(text.len());
        while !text.is_char_boundary(at) {
            at -= 1;
        }
        at
    };
    let start = floor(range.start);
    start..floor(range.end).max(start)
}

/// An offset in a row as shown, as an offset in the block's own text:
/// a soft break is three bytes shown, one kept.
fn own_offset(shown: &str, offset: usize) -> usize {
    let offset = offset.min(shown.len());
    offset - shown[..offset].matches(SOFT_BREAK).count() * (SOFT_BREAK.len_utf8() - 1)
}

/// An offset in a block's own text, as an offset in the row as shown.
fn shown_offset(own: &str, offset: usize) -> usize {
    let offset = offset.min(own.len());
    offset + own[..offset].matches('\n').count() * (SOFT_BREAK.len_utf8() - 1)
}

/// The least that turns one text into another: a range of the first, and
/// what replaces it.
fn difference(before: &str, after: &str) -> (Range<usize>, String) {
    let mut start = before.bytes().zip(after.bytes()).take_while(|(a, b)| a == b).count();
    while !before.is_char_boundary(start) || !after.is_char_boundary(start) {
        start -= 1;
    }
    let (rest_before, rest_after) = (&before[start..], &after[start..]);
    let mut same = rest_before.bytes().rev().zip(rest_after.bytes().rev()).take_while(|(a, b)| a == b).count();
    while !rest_before.is_char_boundary(rest_before.len() - same) || !rest_after.is_char_boundary(rest_after.len() - same) {
        same -= 1;
    }
    (start..before.len() - same, rest_after[..rest_after.len() - same].to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inline::Style;

    const NOTE: &str = "---\ntags: [Projects]\n---\n# Project Atlas\n\nA paragraph\nof two lines.\n\n## Next\n\n*   Book a room\n    *   ask [[Grace]]\n+ [ ] Send invites\n1. First\n\n```query\ntag: Person\n```\n";

    /// Applies a change to what a view shows, as the view would.
    fn shown(view: &mut String, change: &Change) {
        view.replace_range(change.range.clone(), &change.replacement);
    }

    /// A session in an outline, and the view of it.
    fn outline(source: &str) -> (Session, String) {
        let session = Session::new(source, Mode::Outline);
        let view = session.text().to_owned();
        (session, view)
    }

    /// Types at the end of the view's line that starts with `line`.
    fn at_end_of(view: &str, line: &str) -> usize {
        let start = view.find(line).unwrap_or_else(|| panic!("no line {line:?} in {view:?}"));
        start + view[start..].find('\n').unwrap_or(view.len() - start)
    }

    #[test]
    fn a_note_opens_and_closes_as_it_was_in_either_mode() {
        for mode in [Mode::Text, Mode::Outline] {
            let mut session = Session::new(NOTE, mode);
            assert_eq!(session.markdown(), NOTE);
            assert_eq!(session.title().as_deref(), Some("Project Atlas"));
            // Shown the other way and back: not a byte changes.
            session.set_mode(if mode == Mode::Text { Mode::Outline } else { Mode::Text });
            session.set_mode(mode);
            assert_eq!(session.markdown(), NOTE);
        }
        assert_eq!(Session::new("", Mode::Outline).text(), "");
        assert_eq!(Session::new("", Mode::Outline).markdown(), "");
        assert_eq!(Session::new("- a day\n", Mode::Text).title(), None);
    }

    #[test]
    fn an_outline_shows_a_row_a_block_and_only_its_words() {
        let session = Session::new(NOTE, Mode::Outline);
        assert_eq!(
            session.text(),
            "A paragraph\u{2028}of two lines.\nNext\nBook a room\nask [[Grace]]\nSend invites\nFirst\n```query\u{2028}tag: Person\u{2028}```"
        );
        let layout = session.layout();
        assert!(!layout.markers_in_text);
        let lines: Vec<_> = layout.lines.iter().map(|line| (&session.text()[line.range.clone()], line.kind.clone(), line.depth)).collect();
        use LineKind::*;
        assert_eq!(lines[1], ("Next", Heading(2), 0));
        assert_eq!(lines[2], ("Book a room", Item { ordered: None, task: None, bullet: '*' }, 1));
        assert_eq!(lines[3], ("ask [[Grace]]", Item { ordered: None, task: None, bullet: '*' }, 2));
        assert_eq!(lines[4], ("Send invites", Item { ordered: None, task: Some(false), bullet: '+' }, 1));
        assert_eq!(lines[5], ("First", Item { ordered: Some(1), task: None, bullet: '.' }, 1));
        assert_eq!(lines[6].1, Code);
        // A link in a row is a run of the view's text.
        assert!(layout.runs.iter().any(|run| &session.text()[run.range.clone()] == "Grace"));
        // In text, the same note is its Markdown, markers and all.
        let text = Session::new(NOTE, Mode::Text);
        assert!(text.text().starts_with("A paragraph\nof two lines.\n\n## Next\n\n*   Book a room\n"));
        assert!(text.layout().markers_in_text);
    }

    #[test]
    fn typing_in_a_row_changes_that_block_and_no_other_byte() {
        let (mut session, mut view) = outline(NOTE);
        let at = at_end_of(&view, "Book a room");
        let change = session.replace(at..at, " today");
        shown(&mut view, &change);
        assert_eq!(view, session.text());
        assert_eq!(change.selection, at + 6..at + 6);
        assert_eq!(session.markdown(), NOTE.replace("*   Book a room", "*   Book a room today"));
        // Deleting within the row.
        let change = session.replace(at..at + 6, "");
        shown(&mut view, &change);
        assert_eq!((view.as_str(), session.markdown().as_str()), (session.text(), NOTE));
    }

    #[test]
    fn return_splits_a_row_into_two_of_its_sort() {
        let (mut session, mut view) = outline("- one\n- two\n  - under two\n+ [x] done\n");
        let at = at_end_of(&view, "one");
        let change = session.perform(at..at, Command::Newline).unwrap();
        shown(&mut view, &change);
        assert_eq!(view, "one\n\ntwo\nunder two\ndone");
        assert_eq!(change.selection, 4..4);
        assert_eq!(session.markdown(), "- one\n- \n- two\n  - under two\n+ [x] done\n");
        // Typed into, then Return in the middle of a word.
        let change = session.replace(4..4, "new");
        shown(&mut view, &change);
        let change = session.perform(5..5, Command::Newline).unwrap();
        shown(&mut view, &change);
        assert_eq!(session.markdown(), "- one\n- n\n- ew\n- two\n  - under two\n+ [x] done\n");
        // At the end of a row with rows under it: the new row is the first of them.
        let at = at_end_of(&view, "two");
        let change = session.perform(at..at, Command::Newline).unwrap();
        shown(&mut view, &change);
        // (Markdown wants a blank line before an empty item that opens a list inside another.)
        assert_eq!(session.markdown(), "- one\n- n\n- ew\n- two\n\n  - \n  - under two\n+ [x] done\n");
        // After a done task, an open one.
        let at = view.len();
        session.perform(at..at, Command::Newline).unwrap();
        let last = session.layout().lines.last().unwrap().kind.clone();
        assert_eq!(last, LineKind::Item { ordered: None, task: Some(false), bullet: '+' }, "{:?}", session.markdown());
        // A line break typed or pasted is the same thing.
        let (mut pasted, _) = outline("- one\n");
        pasted.replace(3..3, "\ntwo\nthree");
        assert_eq!(pasted.markdown(), "- one\n- two\n- three\n");
    }

    #[test]
    fn return_on_an_empty_row_takes_it_out_a_level_then_makes_it_plain() {
        let (mut session, _) = outline("- one\n\n  - \n");
        assert_eq!(session.text(), "one\n");
        let at = session.text().len();
        session.perform(at..at, Command::Newline).unwrap();
        // (It keeps the blank line it was written after.)
        assert_eq!(session.markdown(), "- one\n\n- \n");
        let at = session.text().len();
        session.perform(at..at, Command::Newline).unwrap();
        assert_eq!(session.layout().lines[1].kind, LineKind::Paragraph);
        // A row with words in it is split, however deep.
        let (mut deep, _) = outline("- one\n  - two\n");
        deep.perform(7..7, Command::Newline).unwrap();
        assert_eq!(deep.markdown(), "- one\n  - two\n  - \n");
    }

    #[test]
    fn delete_at_a_rows_start_unmakes_it_then_joins_it_to_the_row_before() {
        let (mut session, mut view) = outline("- one\n+ [ ] two\n  - under two\n");
        let at = view.find("two").unwrap();
        // First its checkbox…
        let change = session.perform(at..at, Command::DeleteBackward).unwrap();
        shown(&mut view, &change);
        assert_eq!(session.markdown(), "- one\n+ two\n  - under two\n");
        // …then it joins the row before, its own rows kept under that one.
        let change = session.perform(at..at, Command::DeleteBackward).unwrap();
        shown(&mut view, &change);
        assert_eq!((view.as_str(), change.selection.clone()), ("onetwo\nunder two", 3..3));
        assert_eq!(session.markdown(), "- onetwo\n  - under two\n");
        // Inside a row, and at the very start, it is the view's own to do.
        assert_eq!(session.perform(2..2, Command::DeleteBackward), None);
        assert_eq!(session.perform(0..0, Command::DeleteBackward), None);
        // A selection across rows, deleted, joins what is left of them.
        let (mut across, _) = outline("- alpha\n- beta\n- gamma\n");
        across.replace(3..13, "");
        assert_eq!(across.markdown(), "- alpmma\n");
    }

    #[test]
    fn rows_are_indented_moved_and_removed_as_blocks_of_the_tree() {
        let (mut session, mut view) = outline("- one\n- two\n  - under two\n- three\n");
        let at = view.find("two").unwrap() + 1;
        let change = session.perform(at..at, Command::Indent).unwrap();
        shown(&mut view, &change);
        assert_eq!(session.markdown(), "- one\n  - two\n    - under two\n- three\n");
        assert_eq!((view.as_str(), change.selection.clone()), (session.text(), at..at));
        session.perform(at..at, Command::Outdent).unwrap();
        assert_eq!(session.markdown(), "- one\n- two\n  - under two\n- three\n");
        // Up, with what is under it; the caret stays in its word.
        let change = session.perform(at..at, Command::MoveUp).unwrap();
        assert_eq!(session.markdown(), "- two\n  - under two\n- one\n- three\n");
        assert_eq!(&session.text()[change.selection.start - 1..change.selection.start + 2], "two");
        let at = change.selection.start;
        session.perform(at..at, Command::MoveDown).unwrap();
        session.perform(session.text().find("two").unwrap()..session.text().find("two").unwrap(), Command::MoveDown).unwrap();
        assert_eq!(session.markdown(), "- one\n- three\n- two\n  - under two\n");
        // The first has nothing to go under, nor above.
        assert_eq!(session.perform(0..0, Command::Indent), None);
        assert_eq!(session.perform(0..0, Command::MoveUp), None);
        // Two rows at once.
        let both = 0..session.text().find("three").unwrap() + 2;
        session.perform(both.clone(), Command::DuplicateRows).unwrap();
        assert_eq!(session.markdown(), "- one\n- one\n- three\n- three\n- two\n  - under two\n");
        session.perform(0..0, Command::DeleteRows).unwrap();
        assert_eq!(session.markdown(), "- one\n- three\n- three\n- two\n  - under two\n");
    }

    #[test]
    fn a_marker_typed_at_a_rows_start_makes_the_row_that_kind() {
        let typed = |source: &str, marker: &str| {
            let (mut session, mut view) = outline(source);
            let mut at = 0;
            for c in marker.chars().chain([' ']) {
                let change = session.replace(at..at, &c.to_string());
                shown(&mut view, &change);
                at = change.selection.end;
            }
            assert_eq!(view, session.text());
            session.markdown()
        };
        assert_eq!(typed("plain\n", "-"), "- plain\n");
        assert_eq!(typed("plain\n", "##"), "## plain\n");
        assert_eq!(typed("plain\n", ">"), "> plain\n");
        assert_eq!(typed("plain\n", "1."), "1. plain\n");
        assert_eq!(typed("- item\n", "[]"), "- [ ] item\n");
        assert_eq!(typed("- item\n", "+"), "+ [ ] item\n");
        assert_eq!(typed("- item\n", "[x]"), "- [x] item\n");
        // In a row that is already something, and inside a line, it is only typed.
        assert_eq!(typed("## Title\n", "-"), "## - Title\n");
        let (mut session, _) = outline("- ab\n");
        session.replace(1..1, " -");
        session.replace(3..3, " ");
        assert_eq!(session.markdown(), "- a - b\n");
    }

    #[test]
    fn commands_turn_rows_into_other_kinds_of_row() {
        let (mut session, _) = outline("plain\n- item\n");
        session.perform(0..0, Command::CycleChecklist).unwrap();
        assert_eq!(session.markdown(), "- [ ] plain\n- item\n");
        session.perform(0..0, Command::CycleChecklist).unwrap();
        session.perform(0..0, Command::CycleChecklist).unwrap();
        assert_eq!(session.markdown(), "- plain\n- item\n");
        session.perform(0..0, Command::ToggleTask).unwrap();
        assert_eq!(session.markdown(), "+ [ ] plain\n- item\n");
        session.perform(0..0, Command::ToggleCheckbox).unwrap();
        assert_eq!(session.markdown(), "+ [x] plain\n- item\n");
        // Both rows at once.
        session.perform(0..session.text().len(), Command::Heading(2)).unwrap();
        assert_eq!(session.markdown(), "## plain\n## item\n");
        session.perform(0..0, Command::Heading(2)).unwrap();
        assert_eq!(session.markdown(), "plain\n## item\n");
        // Words emboldened within their row.
        let change = session.perform(0..5, Command::Toggle(Style::Strong)).unwrap();
        assert_eq!((session.markdown().as_str(), change.selection), ("**plain**\n## item\n", 2..7));
    }

    #[test]
    fn code_is_one_row_and_a_line_break_in_it_stays_in_it() {
        let (mut session, mut view) = outline("- before\n\n```\nlet x = 1;\n```\n");
        let at = view.find("let x = 1;").unwrap() + "let x = 1;".len();
        let change = session.perform(at..at, Command::Newline).unwrap();
        shown(&mut view, &change);
        let change = session.replace(change.selection.clone(), "let y = 2;");
        shown(&mut view, &change);
        assert_eq!(view, session.text());
        assert_eq!(session.markdown(), "- before\n\n```\nlet x = 1;\nlet y = 2;\n```\n");
    }

    #[test]
    fn the_first_words_in_an_empty_note_make_its_first_row() {
        let (mut session, mut view) = outline("---\ntags: [a]\n---\n# Title\n\n");
        let change = session.replace(0..0, "hello");
        shown(&mut view, &change);
        assert_eq!((view.as_str(), change.selection), ("hello", 5..5));
        assert_eq!(session.markdown(), "---\ntags: [a]\n---\n# Title\n\n- hello\n");
    }

    #[test]
    fn text_mode_edits_the_same_tree_through_its_markdown() {
        let mut session = Session::new("- one\n- two\n", Mode::Text);
        let change = session.replace(5..5, " more");
        assert_eq!((change.range, change.replacement.as_str(), change.selection), (5..5, " more", 10..10));
        assert_eq!(session.body().blocks[0].text, "one more");
        let change = session.perform(10..10, Command::Newline).unwrap();
        assert_eq!(change.replacement, "\n- ");
        assert_eq!(session.body().blocks.len(), 3);
        // The same note, shown as an outline: three rows.
        session.set_mode(Mode::Outline);
        assert_eq!(session.text(), "one more\n\ntwo");
        session.replace(9..9, "between");
        session.set_mode(Mode::Text);
        assert_eq!(session.text(), "- one more\n- between\n- two\n");
    }

    #[test]
    fn a_title_and_fields_are_the_notes_own() {
        let mut session = Session::new("- no title yet\n", Mode::Outline);
        session.set_title("  Atlas ");
        session.frontmatter_mut().set("pinned", "true");
        assert_eq!(session.markdown(), "---\npinned: true\n---\n# Atlas\n\n- no title yet\n");
        session.set_title("Atlas Reborn");
        session.frontmatter_mut().remove("pinned");
        session.drop_empty_frontmatter();
        assert_eq!(session.markdown(), "# Atlas Reborn\n\n- no title yet\n");
        assert_eq!(session.title().as_deref(), Some("Atlas Reborn"));
    }

    #[test]
    fn the_least_change_is_what_a_view_is_asked_to_make() {
        assert_eq!(difference("one\ntwo", "one\nnew\ntwo"), (4..4, "new\n".into()));
        assert_eq!(difference("café au lait", "café noir"), (6..13, "noir".into()));
        assert_eq!(difference("same", "same"), (4..4, String::new()));
        assert_eq!(difference("", "all new"), (0..0, "all new".into()));
        assert_eq!(difference("é", "è"), (0..2, "è".into()));
    }

    #[test]
    fn undo_puts_the_tree_back_structure_and_all() {
        let (mut session, mut view) = outline("- one\n- two\n");
        // Indenting moves no word of the view, and is undone all the same.
        let change = session.perform(5..5, Command::Indent).unwrap();
        shown(&mut view, &change);
        assert_eq!(session.markdown(), "- one\n  - two\n");
        let change = session.undo().unwrap();
        shown(&mut view, &change);
        assert_eq!((session.markdown().as_str(), change.selection), ("- one\n- two\n", 5..5));
        let change = session.redo().unwrap();
        shown(&mut view, &change);
        assert_eq!(session.markdown(), "- one\n  - two\n");
        // A word typed is one change; the space before the next begins another.
        for (at, c) in "new".chars().enumerate() {
            let change = session.replace(3 + at..3 + at, &c.to_string());
            shown(&mut view, &change);
        }
        session.replace(6..6, " ");
        session.replace(7..7, "x");
        assert_eq!(session.text(), "onenew x\ntwo");
        session.undo();
        session.undo();
        assert_eq!(session.text(), "onenew\ntwo");
        session.undo();
        assert_eq!(session.text(), "one\ntwo");
        assert!(session.can_redo());
        // A command that does nothing leaves nothing to undo; a new change forgets what was undone.
        assert_eq!(session.perform(0..0, Command::Indent), None);
        session.replace(0..0, "z");
        assert!(!session.can_redo());
        while session.undo().is_some() {}
        assert_eq!(session.markdown(), "- one\n- two\n");
        // In text, the same.
        let mut text = Session::new("- one\n", Mode::Text);
        text.replace(5..5, "!");
        text.perform(6..6, Command::Newline).unwrap();
        text.undo();
        let back = text.undo().unwrap();
        assert_eq!((text.text(), back.selection), ("- one\n", 5..5));
    }
}
