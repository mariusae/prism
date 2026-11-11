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
use crate::editor::{self, Command, Layout, Line, LineKind, RowKind};
use crate::frontmatter::Frontmatter;
use crate::inline;
use crate::outline::{self, Path};
use crate::river::FoldedRow;
use crate::time::{self, TimeFoot, TimeHead, TimeMark};
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
        let line = self.heading.lines().find(|line| !line.trim().is_empty())?;
        let words = line.strip_prefix("# ")?.trim();
        (!words.is_empty()).then(|| inline::plain_text(words.trim_end_matches('#')))
    }

    /// Whether the note, kept at `path`, was never given a title: see
    /// [`Note::is_untitled`](crate::Note::is_untitled).
    pub fn is_untitled(&self, path: &str) -> bool {
        self.title().is_none() && crate::NoteKind::is_unnamed(path)
    }

    /// What the note, kept at `path`, is called where it is shown: its
    /// title, or its first words. See [`label`](crate::note::label).
    pub fn label(&self, path: &str) -> String {
        crate::note::label(self.is_untitled(path).then_some(&self.body), || {
            let fixed = crate::NoteKind::of(path).is_some_and(crate::NoteKind::has_fixed_title);
            self.title().filter(|_| !fixed).unwrap_or_else(|| crate::NoteKind::fallback_title(path))
        })
    }

    /// The words a note with no title could be titled by: its first
    /// line's, if that line is words — not code, not only a picture.
    pub fn first_line(&self) -> Option<String> {
        let block = self.body.blocks.first().filter(|block| block.kind != BlockKind::Code)?;
        let words = inline::plain_text(block.text.lines().next()?.trim().trim_end_matches('#').trim());
        (!words.is_empty()).then_some(words)
    }

    /// Takes the first line out of the body, and gives its words: the
    /// first step of making it the title, the second being to title the
    /// note by them. What that line held under it — an outline's rows —
    /// moves up into its place; what it went on to say on later lines
    /// stays, as the body's first words.
    pub fn take_first_line(&mut self) -> Option<String> {
        let words = self.first_line()?;
        self.remember(0..0);
        self.typing = None;
        let rest: Vec<&str> = self.body.blocks[0].text.lines().skip(1).collect();
        if rest.iter().any(|line| !line.trim().is_empty()) {
            self.body.blocks[0].text = rest.join("\n");
        } else {
            // Its rows, last first, each put after it at its own level: in their order.
            while self.body.blocks[0].children.last().is_some() {
                let last = self.body.blocks[0].children.len() - 1;
                if outline::outdent(&mut self.body, &[0, last]).is_none() {
                    break;
                }
            }
            if self.body.blocks[0].children.is_empty() {
                outline::remove(&mut self.body, &[0]);
            } else {
                self.body.blocks[0].text = String::new();
            }
        }
        self.project();
        Some(words)
    }

    /// Titles the note: its first heading, made if it had none.
    pub fn set_title(&mut self, title: &str) {
        let title = title.trim();
        if title.is_empty() {
            return;
        }
        // The blank lines a file has before its heading are kept.
        let blank = self.heading.len() - self.heading.trim_start_matches(['\n', '\r', ' ', '\t']).len();
        let (before, heading) = self.heading.split_at(blank);
        self.heading = match heading.split_once('\n') {
            Some((_, after)) => format!("{before}# {title}\n{after}"),
            None if heading.is_empty() => format!("{before}# {title}\n\n"),
            None => format!("{before}# {title}"),
        };
    }

    // --- Showing ---------------------------------------------------------------

    fn project(&mut self) {
        self.rows.clear();
        match self.mode {
            Mode::Text => self.text = self.body.to_markdown(),
            Mode::Outline => {
                // A row with nothing left under it has nothing folded.
                fn tidy(blocks: &mut [Block]) {
                    for block in blocks {
                        block.folded &= !block.children.is_empty();
                        tidy(&mut block.children);
                    }
                }
                tidy(&mut self.body.blocks);
                let mut text = String::new();
                for (index, path) in visible(&self.body).into_iter().enumerate() {
                    let Some(block) = self.body.get(&path) else { continue };
                    if index > 0 {
                        text.push('\n');
                    }
                    let start = text.len();
                    text.extend(block.text.chars().map(|c| if c == '\n' { SOFT_BREAK } else { c }));
                    self.rows.push(RowSpan { path, range: start..text.len() });
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
        // `->` and `<-`, as they are typed, are the arrows they draw.
        let arrow = arrow(&self.text, &range, replacement);
        let (range, replacement) = arrow.map_or((range, replacement), |(range, arrow)| (range, arrow));
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
                self.read(text);
                let caret = range.start + replacement.len();
                Change { range, replacement: replacement.to_owned(), selection: caret..caret }
            }
            Mode::Outline => self.replace_rows(range, replacement),
        }
    }

    /// As text: the body read again from what the view now shows. What
    /// was folded is folded still, for when it is shown as an outline.
    fn read(&mut self, text: String) {
        let folds = self.folded_rows();
        self.body = Document::parse(&text);
        self.text = text;
        self.fold(&folds);
    }

    /// Carries out a command. `None` when it has nothing to do there, and
    /// the view should do what it would have done.
    pub fn perform(&mut self, selection: Range<usize>, command: Command) -> Option<Change> {
        self.undoably(selection, |session, selection| session.perform_now(selection, None, command))
    }

    /// Carries out a command on some rows of an outline, wherever the
    /// caret is: the rows a finger is on, or those chosen together. `rows`
    /// counts the rows shown, from the first; each takes what is under it
    /// along. `selection` is the view's own, and the answer says where it
    /// then is — with the words it was among, if they are still shown.
    ///
    /// For the commands that are done to rows: moving, deleting, folding,
    /// turning into another kind. `None` for one that is done at the caret
    /// (Return, emphasis), and as text.
    pub fn perform_on(&mut self, rows: &[usize], selection: Range<usize>, command: Command) -> Option<Change> {
        self.undoably(selection, |session, selection| session.perform_now(selection, Some(rows), command))
    }

    /// Makes a change that Undo takes back — if it is one: a change that
    /// answers `None`, or leaves the body as it was, is none.
    fn undoably(&mut self, selection: Range<usize>, change: impl FnOnce(&mut Session, Range<usize>) -> Option<Change>) -> Option<Change> {
        let selection = clamp(&self.text, selection);
        self.remember(selection.clone());
        self.typing = None;
        let change = change(self, selection);
        if change.is_none() {
            self.undone.pop();
        }
        change
    }

    fn perform_now(&mut self, selection: Range<usize>, rows: Option<&[usize]>, command: Command) -> Option<Change> {
        match self.mode {
            Mode::Text => {
                if rows.is_some() {
                    return None;
                }
                let edit = editor::perform(&self.text, selection, command)?;
                self.read(edit.apply(&self.text));
                Some(Change { range: edit.range, replacement: edit.replacement, selection: edit.selection })
            }
            Mode::Outline => self.perform_rows(selection, rows, command),
        }
    }

    /// Links the words selected to an address — `[words](address)` — or,
    /// when they are a link's words already, points that link there: what
    /// pasting an address onto words does. `None` when nothing is
    /// selected, when the selection spans rows or lines, or when the
    /// address is none ([`inline::address`]).
    pub fn link(&mut self, selection: Range<usize>, address: &str) -> Option<Change> {
        let address = inline::address(address)?.to_owned();
        self.undoably(selection, |session, selection| {
            // The line of the view the selection is on, which is all that changes.
            let start = session.text[..selection.start].rfind('\n').map_or(0, |at| at + 1);
            let end = selection.start + session.text[selection.start..].find('\n').unwrap_or(session.text.len() - selection.start);
            if selection.end > end {
                return None;
            }
            if session.mode == Mode::Outline
                && !session.rows.get(session.row_at(selection.start)).and_then(|row| session.body.get(&row.path)).is_some_and(Block::has_inline_content)
            {
                return None;
            }
            let (linked, caret) = inline::link_to(&session.text[start..end], selection.start - start..selection.end - start, &address)?;
            let mut change = session.replace_now(start..end, &linked);
            change.selection = start + caret..start + caret;
            Some(change)
        })
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

    /// Unfolds whatever a block is folded away under: it is shown.
    fn reveal(&mut self, path: &[usize]) {
        for depth in 1..path.len() {
            if let Some(over) = self.body.get_mut(&path[..depth]) {
                over.folded = false;
            }
        }
    }

    /// After a change to the tree: shows it again, and says how the view
    /// gets from what it showed to what it should. The caret is never
    /// left out of sight: what it is folded away under is unfolded.
    fn changed(&mut self, before: String, caret: (Path, usize), anchor: Option<(Path, usize)>) -> Change {
        self.reveal(&caret.0);
        if let Some((path, _)) = &anchor {
            self.reveal(path);
        }
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
        for row in first + 1..=last {
            let shown = visible(&self.body);
            let Some(position) = shown.iter().position(|shown| *shown == path) else { break };
            let Some(next) = shown.get(position + 1).cloned() else { break };
            // A folded row taken whole takes with it what it hid.
            if row < last {
                if let Some(block) = self.body.get_mut(&next).filter(|block| block.folded) {
                    block.children.clear();
                }
            }
            if outline::join_onto(&mut self.body, &next, &path).is_none() {
                // A block that does not join — code, a table — is taken out whole.
                outline::remove(&mut self.body, &next);
            }
        }

        let splits = self.body.get(&path).is_some_and(Block::splits);
        let written = format!("{prefix}{replacement}{suffix}");
        // Inside a block that is one piece, a line break stays inside it.
        let pieces: Vec<&str> = if splits { written.split('\n').collect() } else { vec![written.as_str()] };
        let own = |piece: &str| piece.replace(SOFT_BREAK, "\n");
        if let Some(block) = self.body.get_mut(&path) {
            block.text = if splits { own(pieces[0]) } else { own(&written).replace('\r', "") };
        }
        for piece in &pieces[1..] {
            let end = self.body.get(&path).map_or(0, |block| block.text.len());
            // What a folded row hides stays under it: the row after it comes after them.
            let hidden = self.body.get_mut(&path).filter(|block| block.folded).map(|block| std::mem::take(&mut block.children));
            let next = outline::split(&mut self.body, &path, end);
            if let (Some(hidden), Some(block)) = (hidden, self.body.get_mut(&path)) {
                block.children = hidden;
            }
            let Some(next) = next else { break };
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
                // By characters: what was typed may end in any letter.
                let delimiter = numbered.chars().last().filter(|c| *c == '.' || *c == ')')?;
                let digits = &numbered[..numbered.len() - 1];
                let number = digits.parse().ok().filter(|_| digits.len() <= 9)?;
                item(Marker::Ordered { number, delimiter }, None)
            }
        }
    }

    fn perform_rows(&mut self, selection: Range<usize>, rows: Option<&[usize]>, command: Command) -> Option<Change> {
        let at_caret = matches!(command, Command::Newline | Command::DeleteBackward | Command::Toggle(_) | Command::NewTimeBlock { .. });
        if at_caret && rows.is_some() {
            return None;
        }
        let before = self.text.clone();
        if self.rows.is_empty() {
            // Nothing written yet: a time block makes the first row.
            if !matches!(command, Command::NewTimeBlock { .. }) {
                return None;
            }
            self.body.blocks.push(Block::bullet(""));
            self.project();
        }
        if at_caret {
            return self.perform_at_caret(before, selection, command);
        }
        let chosen = self.chosen(&selection, rows);
        let position = self.rows.iter().position(|row| Some(&row.path) == chosen.first())?;
        self.mark(&selection, &chosen);
        let done = self.rearrange(&command);
        self.rearranged(before, done, position, matches!(command, Command::Fold | Command::ToggleFold | Command::FoldCompletely | Command::FoldAll))
    }

    /// The commands given where the caret is.
    fn perform_at_caret(&mut self, before: String, selection: Range<usize>, command: Command) -> Option<Change> {
        let collapsed = selection.start == selection.end;
        let first = self.row_at(selection.start);
        let start = (self.rows[first].path.clone(), selection.start - self.rows[first].range.start);
        let end_row = self.row_at(selection.end);
        let end = (self.rows[end_row].path.clone(), selection.end - self.rows[end_row].range.start);
        let path = start.0.clone();
        let kind = self.body.get(&path)?.kind.clone();
        match command {
            Command::Newline => {
                if !collapsed {
                    return Some(self.replace_rows(selection, "\n"));
                }
                let block = self.body.get(&path)?;
                if !block.splits() {
                    // In code, a line of the same block.
                    return Some(self.replace_rows(selection, &SOFT_BREAK.to_string()));
                }
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
                let (at_end, folded) = (offset == block.text.len(), block.folded);
                if at_end {
                    // At a time block's end: the next, starting as it ends.
                    if let Some((next, caret)) = time::next_block(&mut self.body, &path) {
                        return Some(self.changed(before, (next, caret), None));
                    }
                }
                if offset == 0 && !at_end {
                    // At a row's start: an empty row above it, and the caret stays with the words.
                    let below = outline::open_above(&mut self.body, &path)?;
                    return Some(self.changed(before, (below, 0), None));
                }
                // What a folded row hides stays under it: the new row comes after them.
                let hidden = self.body.get_mut(&path).filter(|_| at_end && folded).map(|block| std::mem::take(&mut block.children));
                let next = outline::split(&mut self.body, &path, offset);
                if let (Some(hidden), Some(block)) = (hidden, self.body.get_mut(&path)) {
                    block.children = hidden;
                }
                Some(self.changed(before, (next?, 0), None))
            }
            Command::DeleteBackward => {
                if !collapsed {
                    return None;
                }
                if start.1 != 0 {
                    // Just after a picture: the picture, whole.
                    let row = self.rows[first].range.clone();
                    let picture =
                        inline::picture_before(&self.text[row.clone()], start.1).filter(|_| self.body.get(&path).is_some_and(Block::has_inline_content))?;
                    return Some(self.replace_rows(row.start + picture.start..row.start + picture.end, ""));
                }
                match kind {
                    // First its checkbox, then what makes it more than a line…
                    BlockKind::Item(Item { task: Some(_), marker }) => {
                        outline::set_kind(&mut self.body, &path, BlockKind::Item(Item { marker, task: None }));
                    }
                    BlockKind::Heading(_) | BlockKind::Quote | BlockKind::Item(Item { marker: Marker::Ordered { .. }, .. }) => {
                        outline::set_kind(&mut self.body, &path, BlockKind::Paragraph);
                    }
                    // …then it joins the row shown before it.
                    _ => {
                        let onto = self.rows.get(first.checked_sub(1)?)?.path.clone();
                        let (onto, offset) = outline::join_onto(&mut self.body, &path, &onto)?;
                        let offset = shown_offset(&self.body.get(&onto)?.text, offset);
                        return Some(self.changed(before, (onto, offset), None));
                    }
                }
                Some(self.changed(before, (path, 0), None))
            }
            Command::Toggle(style) => {
                if first != end_row || !self.body.get(&path)?.has_inline_content() {
                    return None;
                }
                let row = self.rows[first].range.clone();
                let (styled, range) = inline::toggle(&self.text[row.clone()], start.1..end.1, style);
                self.body.get_mut(&path)?.text = styled.replace(SOFT_BREAK, "\n");
                Some(self.changed(before, (path.clone(), range.end), Some((path, range.start))))
            }
            Command::NewTimeBlock { now } => {
                let (made, caret) = time::new_block(&mut self.body, &path, now)?;
                Some(self.changed(before, (made, caret), None))
            }
            _ => None,
        }
    }

    // --- Rows rearranged ---------------------------------------------------------
    //
    // A command done to rows moves blocks about the tree, and every move
    // changes the paths of others. So nothing is followed by its path:
    // the rows chosen, and the places of the selection's ends, are marked
    // in the blocks' own words — with characters no text has — and found
    // again by those marks when the tree has settled. A mark goes
    // wherever its block goes.

    /// The rows a command is for — those given, or those the selection
    /// touches — without any that is under another of them.
    fn chosen(&self, selection: &Range<usize>, rows: Option<&[usize]>) -> Vec<Path> {
        let indexes: Vec<usize> = match rows {
            Some(rows) => {
                let mut rows: Vec<usize> = rows.iter().copied().filter(|row| *row < self.rows.len()).collect();
                rows.sort_unstable();
                rows.dedup();
                rows
            }
            None => {
                let (first, mut last) = (self.row_at(selection.start), self.row_at(selection.end));
                // A selection ending at a row's very start does not take that row.
                if last > first && self.rows[last].range.start == selection.end {
                    last -= 1;
                }
                (first..=last).collect()
            }
        };
        let mut chosen: Vec<Path> = Vec::new();
        for index in indexes {
            let path = &self.rows[index].path;
            if !chosen.iter().any(|top| path.starts_with(top)) {
                chosen.push(path.clone());
            }
        }
        chosen
    }

    /// Marks the selection's ends, and the rows chosen.
    fn mark(&mut self, selection: &Range<usize>, chosen: &[Path]) {
        // The end first: a mark put in before it would move it.
        for (offset, mark) in [(selection.end, CARET), (selection.start, ANCHOR)] {
            let Some(row) = self.rows.get(self.row_at(offset)) else { continue };
            let at = own_offset(&self.text[row.range.clone()], offset - row.range.start);
            if let Some(block) = self.body.get_mut(&row.path.clone()) {
                block.text.insert(at.min(block.text.len()), mark);
            }
        }
        for path in chosen {
            if let Some(block) = self.body.get_mut(path) {
                block.text.insert(0, CHOSEN);
            }
        }
    }

    /// The first of the rows chosen that is still to be dealt with — or
    /// the last — its mark taken off.
    fn next_chosen(&mut self, last: bool) -> Option<Path> {
        let path = marked(&self.body, CHOSEN, last)?;
        unmark(&mut self.body, &path, CHOSEN);
        Some(path)
    }

    /// Where a mark is, taken out: its block, and the place in its words.
    fn take_mark(&mut self, mark: char) -> Option<(Path, usize)> {
        let path = marked(&self.body, mark, false)?;
        let at = unmark(&mut self.body, &path, mark)?;
        Some((path, at))
    }

    /// Does to each chosen row what a command says. `None` when there was
    /// nothing to do.
    fn rearrange(&mut self, command: &Command) -> Option<()> {
        let mut any = false;
        match command {
            Command::Indent | Command::Outdent | Command::MoveUp | Command::MoveDown => {
                // Moved down, the last goes first, so each has room.
                while let Some(at) = self.next_chosen(*command == Command::MoveDown) {
                    let moved = match command {
                        Command::Indent => {
                            let to = outline::indent(&mut self.body, &at);
                            // Under a folded row it would go out of sight: that row is unfolded.
                            if let Some(over) = to.as_ref().and_then(|to| self.body.get_mut(&to[..to.len() - 1])) {
                                over.folded = false;
                            }
                            to
                        }
                        Command::Outdent => {
                            // What followed it comes under it — and is not to go out of sight there.
                            let followed = self.body.get(&at[..at.len() - 1]).is_some_and(|over| at[at.len() - 1] + 1 < over.children.len());
                            let to = outline::outdent(&mut self.body, &at);
                            if let Some(block) = to.as_ref().and_then(|to| self.body.get_mut(to)).filter(|block| followed && block.can_have_children()) {
                                block.folded = false;
                            }
                            to
                        }
                        Command::MoveUp => outline::move_up(&mut self.body, &at),
                        _ => outline::move_down(&mut self.body, &at),
                    };
                    match moved {
                        Some(_) => any = true,
                        // The first could not go: none of them does.
                        None if !any => return None,
                        None => break,
                    }
                }
            }
            Command::MoveToTop | Command::MoveToBottom => {
                // To the top, the last goes first: the others come to stand above it, in their order.
                let up = *command == Command::MoveToTop;
                while let Some(mut at) = self.next_chosen(up) {
                    while let Some(to) = if up { outline::move_up(&mut self.body, &at) } else { outline::move_down(&mut self.body, &at) } {
                        at = to;
                        any = true;
                    }
                }
            }
            Command::DeleteRows => {
                while let Some(at) = self.next_chosen(true) {
                    any |= outline::remove(&mut self.body, &at).is_some();
                }
            }
            Command::DuplicateRows => {
                while let Some(at) = self.next_chosen(true) {
                    any |= outline::duplicate(&mut self.body, &at).is_some();
                    // The selection goes with the copy.
                    if let Some(original) = self.body.get_mut(&at) {
                        unmark_all(std::slice::from_mut(original), &[ANCHOR, CARET]);
                    }
                }
            }
            Command::CycleChecklist
            | Command::ToggleTask
            | Command::ToggleCheckbox
            | Command::MarkDone
            | Command::Heading(_)
            | Command::Bullet
            | Command::Numbered
            | Command::Quote
            | Command::Turn(_) => {
                while let Some(at) = self.next_chosen(false) {
                    let Some(kind) = self.body.get(&at).map(|block| block.kind.clone()) else { continue };
                    let Some(next) = turned(&kind, command) else { continue };
                    let numbered = matches!(next, BlockKind::Item(Item { marker: Marker::Ordered { .. }, .. }));
                    outline::set_kind(&mut self.body, &at, next);
                    // A row made a numbered one takes the number its place gives it.
                    if let Some(siblings) = self.body.siblings_mut(&at).filter(|_| numbered) {
                        outline::renumber(siblings);
                    }
                    any = true;
                }
            }
            Command::Fold | Command::Unfold | Command::ToggleFold | Command::FoldCompletely | Command::UnfoldCompletely => {
                while let Some(at) = self.next_chosen(false) {
                    let Some(block) = self.body.get_mut(&at) else { continue };
                    any |= match command {
                        Command::Fold => set_fold(block, true),
                        Command::Unfold => set_fold(block, false),
                        Command::ToggleFold => set_fold(block, !block.folded),
                        Command::FoldCompletely => fold_all(std::slice::from_mut(block), true),
                        _ => fold_all(std::slice::from_mut(block), false),
                    };
                }
            }
            Command::FoldAll => any = fold_all(&mut self.body.blocks, true),
            Command::UnfoldAll => any = fold_all(&mut self.body.blocks, false),
            Command::MoveDoneToBottom => {
                while let Some(at) = self.next_chosen(false) {
                    any |= self.body.get_mut(&at).is_some_and(|block| sink_done(&mut block.children));
                }
            }
            Command::Newline | Command::DeleteBackward | Command::Toggle(_) | Command::NewTimeBlock { .. } => {}
        }
        any.then_some(())
    }

    /// After rows were rearranged — or were not: takes the marks out,
    /// shows the tree again, and says how the view gets there. `position`
    /// is the first chosen row's, where the caret goes if its own row is
    /// gone. A caret that a fold put out of sight goes to the row that was
    /// `folding`; put out of sight any other way, it is shown again.
    fn rearranged(&mut self, before: String, done: Option<()>, position: usize, folding: bool) -> Option<Change> {
        unmark_all(&mut self.body.blocks, &[CHOSEN, ABOVE, BELOW]);
        let (anchor, caret) = (self.take_mark(ANCHOR), self.take_mark(CARET));
        done?;
        // Left as it was: nothing was done.
        if self.undone.last().is_some_and(|(body, _)| *body == self.body) {
            return None;
        }
        let mut shown = |place: Option<(Path, usize)>| {
            let (path, offset) = place?;
            let fold = (1..path.len()).find(|depth| self.body.get(&path[..*depth]).is_some_and(|over| over.folded));
            match fold {
                Some(depth) if folding => Some((path[..depth].to_vec(), 0)),
                _ => {
                    self.reveal(&path);
                    let offset = shown_offset(&self.body.get(&path)?.text, offset);
                    Some((path, offset))
                }
            }
        };
        let (anchor, caret) = (shown(anchor), shown(caret));
        self.project();
        let (range, replacement) = difference(&before, &self.text);
        let gone = self.rows.get(position.min(self.rows.len().saturating_sub(1))).map_or(0, |row| row.range.start);
        let end = caret.map_or(gone, |(path, offset)| self.place(&path, offset));
        let start = anchor.map_or(end, |(path, offset)| self.place(&path, offset));
        Some(Change { range, replacement, selection: start.min(end)..start.max(end) })
    }

    // --- Rows carried ------------------------------------------------------------

    /// Where rows carried would go, put down before a row: the row shown
    /// above that place and the one below it — the rows carried, and what
    /// is under them, passed over — and how deep, held to what can be
    /// there: no deeper than under the row above, if that row can hold
    /// rows and shows them; no shallower than the row below.
    fn drop_place(&self, chosen: &[Path], before: usize, depth: usize) -> Option<(Option<Path>, Option<Path>, usize)> {
        let before = before.min(self.rows.len());
        // Among the rows under one carried: nowhere to go.
        if self.rows.get(before).is_some_and(|row| chosen.iter().any(|top| row.path.len() > top.len() && row.path.starts_with(top))) {
            return None;
        }
        let stays = |row: &&RowSpan| !chosen.iter().any(|top| row.path.starts_with(top));
        let above = self.rows[..before].iter().rev().find(stays).map(|row| row.path.clone());
        let below = self.rows[before..].iter().find(stays).map(|row| row.path.clone());
        let deepest = above.as_ref().map_or(0, |path| {
            let holds = self.body.get(path).is_some_and(|block| block.can_have_children() && !block.folded);
            path.len() - 1 + usize::from(holds)
        });
        let shallowest = below.as_ref().map_or(0, |path| path.len() - 1).min(deepest);
        Some((above, below, depth.clamp(shallowest, deepest)))
    }

    /// How deep rows carried would lie, put down before a row at a depth
    /// asked for: the depth [`move_rows`](Self::move_rows) would give
    /// them, for a view to show where they will go. Depths count the rows
    /// a row is under: 0 at the top. `None` where they cannot be put
    /// down: among the rows under one of them.
    pub fn drop_depth(&self, rows: &[usize], before: usize, depth: usize) -> Option<usize> {
        if self.mode != Mode::Outline || self.rows.is_empty() {
            return None;
        }
        self.drop_place(&self.chosen(&(0..0), Some(rows)), before, depth).map(|place| place.2)
    }

    /// Puts rows of an outline, with what is under them, before another
    /// row — `before` counts the rows shown, and one past the last is the
    /// end — at a depth: what carrying a row with a finger and letting go
    /// does. The depth is held to what can be there
    /// ([`drop_depth`](Self::drop_depth)). The blank lines of the page
    /// stay where they were. `None` when that is where the rows already
    /// are, when it is among the rows under one of them, and as text.
    pub fn move_rows(&mut self, rows: &[usize], before: usize, depth: usize, selection: Range<usize>) -> Option<Change> {
        self.undoably(selection, |session, selection| {
            if session.mode != Mode::Outline || session.rows.is_empty() {
                return None;
            }
            let before_text = session.text.clone();
            let chosen = session.chosen(&selection, Some(rows));
            let position = session.rows.iter().position(|row| Some(&row.path) == chosen.first())?;
            let (above, below, depth) = session.drop_place(&chosen, before, depth)?;
            session.mark(&selection, &chosen);
            for (path, mark) in [(&above, ABOVE), (&below, BELOW)] {
                if let Some(block) = path.as_ref().and_then(|path| session.body.get_mut(path)) {
                    block.text.push(mark);
                }
            }
            // Taken out, the last first; the blank lines before each stay with the place.
            let mut carried: Vec<Block> = Vec::new();
            while let Some(at) = session.next_chosen(true) {
                let Some(mut block) = outline::remove(&mut session.body, &at) else { continue };
                if let Some(follower) = session.body.get_mut(&at).filter(|follower| follower.layout.gap.is_empty()) {
                    follower.layout.gap = std::mem::take(&mut block.layout.gap);
                }
                block.layout.gap.clear();
                carried.insert(0, block);
            }
            let (above, below) = (marked(&session.body, ABOVE, false), marked(&session.body, BELOW, false));
            let mut at = match &above {
                None => vec![0],
                // Under the row above: before its first row, or its only one.
                Some(above) if depth == above.len() => {
                    let first = below.as_ref().filter(|below| below.len() == above.len() + 1 && below.starts_with(above)).map(|below| below[above.len()]);
                    [above.as_slice(), &[first.unwrap_or(session.body.get(above).map_or(0, |block| block.children.len()))]].concat()
                }
                // After the row above, or after one it is under.
                Some(above) => {
                    let mut after = above[..=depth.min(above.len() - 1)].to_vec();
                    *after.last_mut()? += 1;
                    after
                }
            };
            for (index, mut block) in carried.into_iter().enumerate() {
                // At another depth, it is set in as that depth asks, and no further.
                if chosen.get(index).map_or(0, Vec::len) != at.len() {
                    block.layout.extra_indent = 0;
                }
                // Those where they go keep the blank lines before them, above.
                if index == 0 {
                    if let Some(follower) = session.body.get_mut(&at) {
                        block.layout.gap = std::mem::take(&mut follower.layout.gap);
                    }
                }
                outline::insert(&mut session.body, &at, block);
                *at.last_mut()? += 1;
            }
            session.rearranged(before_text, Some(()), position, false)
        })
    }

    // --- What a view asks of rows --------------------------------------------------

    /// For each row shown: whether it is folded, and whether it has rows
    /// under it — shown or not.
    pub fn row_folds(&self) -> Vec<(bool, bool)> {
        self.rows
            .iter()
            .map(|row| self.body.get(&row.path).map_or((false, false), |block| (block.folded && !block.children.is_empty(), !block.children.is_empty())))
            .collect()
    }

    /// What can be done to a row shown: what a menu for it offers.
    pub fn row_info(&self, row: usize) -> Option<RowInfo> {
        let path = &self.rows.get(row)?.path;
        let block = self.body.get(path)?;
        let (&index, _) = path.split_last()?;
        let siblings = match path.len() {
            1 => self.body.blocks.len(),
            _ => self.body.get(&path[..path.len() - 1])?.children.len(),
        };
        let under = || block.walk().skip(1);
        let folded = block.folded && !block.children.is_empty();
        let plain_bullet = matches!(block.kind, BlockKind::Item(Item { marker: Marker::Bullet(_), task: None }));
        Some(RowInfo {
            folded,
            has_children: !block.children.is_empty(),
            hidden: if folded { under().count() } else { 0 },
            shown: self.rows[row + 1..].iter().take_while(|below| below.path.starts_with(path)).count(),
            folds_inside: under().any(|inner| inner.folded && !inner.children.is_empty()),
            open_inside: !folded && under().any(|inner| !inner.folded && !inner.children.is_empty()),
            task: block.task_state().map(Task::is_done),
            has_checklist: plain_bullet && under().any(|inner| inner.task_state().is_some()),
            done_to_move: sink_done(&mut block.children.clone()),
            can_move_up: index > 0,
            can_move_down: index + 1 < siblings,
        })
    }

    /// Some rows shown, with what is under them, as Markdown of their
    /// own: what copying them puts on the pasteboard, and what goes with
    /// them to another note. A row under another of them is written once,
    /// under it.
    pub fn markdown_of(&self, rows: &[usize]) -> String {
        if self.mode != Mode::Outline {
            return String::new();
        }
        let mut blocks: Vec<Block> = self.chosen(&(0..0), Some(rows)).iter().filter_map(|path| self.body.get(path).cloned()).collect();
        for block in &mut blocks {
            block.layout.extra_indent = 0;
        }
        if let Some(first) = blocks.first_mut() {
            first.layout.gap.clear();
        }
        Document { blocks, final_newline: true, line_ending: self.body.line_ending, ..Document::default() }.to_markdown()
    }

    /// What an outline draws of its timelines, row by row: see
    /// [`crate::time`]. `twelve_hour` says how the labels tell the time:
    /// `1:30 PM`, or `13:30`. Empty as text.
    pub fn time_marks(&self, twelve_hour: bool) -> Vec<TimeMark> {
        let timelines = if self.mode == Mode::Outline { time::find(&self.body) } else { Vec::new() };
        let row = |path: &[usize]| self.rows.iter().position(|row| row.path == path);
        let mut marks: std::collections::BTreeMap<usize, TimeMark> = std::collections::BTreeMap::new();
        for (t, timeline) in timelines.iter().enumerate() {
            let within = |row: &&RowSpan| timeline.parent.as_ref().is_none_or(|parent| row.path.starts_with(parent));
            for (n, block) in timeline.blocks.iter().enumerate() {
                // Folded away: none of the timeline is shown.
                let (Some(head), Some(written)) = (row(&block.path), self.body.get(&block.path)) else { break };
                let next = timeline.blocks.get(n + 1).and_then(|next| row(&next.path));
                // Its last row: the one before the next block — an empty row after it is its own.
                let last = next.map_or_else(|| head + self.rows[head + 1..].iter().take_while(within).count(), |next| next - 1);
                // Starting before an earlier one ends: overlapping it.
                let overlap = timeline.blocks[..n].iter().max_by_key(|earlier| earlier.end).filter(|earlier| earlier.end > block.start()).map(|earlier| {
                    let minutes = time::length(earlier.end.min(block.end) - block.start());
                    let words = self.body.get(&earlier.path).map_or("", |block| block.text.get(earlier.stamp.full_len..).unwrap_or(""));
                    let name = words.lines().next().unwrap_or("").trim();
                    let name = if name.chars().count() > 24 {
                        format!("{}… ", name.chars().take(23).collect::<String>())
                    } else if name.is_empty() {
                        String::new()
                    } else {
                        format!("{name} ")
                    };
                    (format!("overlaps {name}{minutes}"), format!("{minutes} overlap"))
                });
                let start = self.rows[head].range.start;
                marks.entry(head).or_insert_with(|| TimeMark { row: head, ..TimeMark::default() }).head = Some(TimeHead {
                    timeline: t,
                    index: n,
                    level: timeline.level,
                    start: block.start(),
                    end: block.end,
                    label: format!("{} · {}", time::span(block.start(), block.end, twelve_hour), time::length(block.duration())),
                    overlap: overlap.as_ref().map(|(long, _)| long.clone()),
                    overlap_short: overlap.map(|(_, short)| short),
                    stamp: start..start + block.stamp.full_len.min(self.rows[head].range.len()),
                    last_row: last,
                    next_row: next,
                    done: written.task_state().is_some_and(Task::is_done),
                });
                let free = block.free();
                marks.entry(last).or_insert_with(|| TimeMark { row: last, ..TimeMark::default() }).feet.push(TimeFoot {
                    timeline: t,
                    index: n,
                    level: timeline.level,
                    length: time::length_room(block.duration()),
                    free,
                    free_length: time::free_room(free),
                    free_label: (free > 0).then(|| format!("{} free", time::length(free))),
                    is_last: n + 1 == timeline.blocks.len(),
                });
            }
        }
        let mut marks: Vec<TimeMark> = marks.into_values().collect();
        for mark in &mut marks {
            mark.feet.sort_by_key(|foot| std::cmp::Reverse(foot.level));
        }
        marks
    }

    // --- Folds ---------------------------------------------------------------------

    /// The rows folded: each by its place among all the body's rows —
    /// shown or not, counted from the first — and its words. The form a
    /// river keeps them in ([`crate::river::Card::folded_rows`]): what an
    /// app saves, and hands back with [`set_folded_rows`](Self::set_folded_rows).
    pub fn folded_rows(&self) -> Vec<FoldedRow> {
        let folded = |block: &Block| block.folded && !block.children.is_empty();
        if !self.body.walk().any(folded) {
            return Vec::new();
        }
        self.body.rows().iter().enumerate().filter(|(_, row)| folded(row.block)).map(|(index, row)| FoldedRow { index, text: row.block.text.clone() }).collect()
    }

    /// Folds these rows, and no others: as the app remembers them. A row
    /// is found by its words — at its place, or nearest to it, the note
    /// having perhaps changed since ([`Document::locate`] tells how a
    /// block is known again) — and one no longer there, or with nothing
    /// under it, is passed over. Says whether anything changed; if it
    /// did, the view shows other text ([`text`](Self::text)), and what was
    /// done before cannot be undone after.
    pub fn set_folded_rows(&mut self, rows: &[FoldedRow]) -> bool {
        let before = self.folded_rows();
        self.fold(rows);
        if self.folded_rows() == before {
            return false;
        }
        self.undone.clear();
        self.redone.clear();
        self.typing = None;
        self.project();
        true
    }

    /// Folds the rows that answer to these, and unfolds every other.
    fn fold(&mut self, rows: &[FoldedRow]) {
        if rows.is_empty() && !self.body.walk().any(|block| block.folded) {
            return;
        }
        let all = self.body.rows();
        let fits = |at: usize, row: &FoldedRow| all.get(at).is_some_and(|found| found.block.text == row.text && !found.block.children.is_empty());
        let paths: Vec<Path> = rows
            .iter()
            .filter_map(|row| {
                let at =
                    if fits(row.index, row) { Some(row.index) } else { (0..all.len()).filter(|at| fits(*at, row)).min_by_key(|at| at.abs_diff(row.index)) };
                at.map(|at| all[at].path.clone())
            })
            .collect();
        drop(all);
        fold_all(&mut self.body.blocks, false);
        for path in paths {
            if let Some(block) = self.body.get_mut(&path) {
                block.folded = true;
            }
        }
    }
}

/// What can be done to a row of an outline: see [`Session::row_info`].
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RowInfo {
    pub folded: bool,
    /// Whether it has rows under it, shown or folded away.
    pub has_children: bool,
    /// How many rows its fold hides.
    pub hidden: usize,
    /// How many rows are shown under it: those that go where it goes.
    pub shown: usize,
    /// Whether a row under it, however deep, is folded: Unfold Completely
    /// has something to do.
    pub folds_inside: bool,
    /// Whether it is unfolded and a row under it could be folded: Fold
    /// Completely has something to do.
    pub open_inside: bool,
    /// Its checkbox: open, or done. `None` for a row without one.
    pub task: Option<bool>,
    /// Whether it is a plain bullet with checkboxes among the rows under
    /// it: a checklist's head.
    pub has_checklist: bool,
    /// Whether a checked row right under it stands before an unchecked
    /// one: Move Done to Bottom has something to do.
    pub done_to_move: bool,
    /// Whether it has a row before it at its level to move above, and
    /// one after it to move below.
    pub can_move_up: bool,
    pub can_move_down: bool,
}

// Marks put in a block's words while rows are rearranged: noncharacters,
// which no text holds. See "Rows rearranged".
const ANCHOR: char = '\u{FDD0}';
const CARET: char = '\u{FDD1}';
const CHOSEN: char = '\u{FDD2}';
const ABOVE: char = '\u{FDD3}';
const BELOW: char = '\u{FDD4}';

/// The first block with a mark in its words, in reading order — or the last.
fn marked(document: &Document, mark: char, last: bool) -> Option<Path> {
    let rows = document.rows();
    let mut found = rows.iter().filter(|row| row.block.text.contains(mark)).map(|row| row.path.clone());
    if last {
        found.next_back()
    } else {
        found.next()
    }
}

/// Takes a mark out of a block's words; says where it was.
fn unmark(document: &mut Document, path: &[usize], mark: char) -> Option<usize> {
    let block = document.get_mut(path)?;
    let at = block.text.find(mark)?;
    block.text.remove(at);
    Some(at)
}

fn unmark_all(blocks: &mut [Block], marks: &[char]) {
    for block in blocks {
        if block.text.contains(marks) {
            block.text.retain(|c| !marks.contains(&c));
        }
        unmark_all(&mut block.children, marks);
    }
}

/// The rows an outline shows, in reading order: every block not under a
/// folded one.
fn visible(document: &Document) -> Vec<Path> {
    fn visit(blocks: &[Block], path: &mut Path, out: &mut Vec<Path>) {
        for (index, block) in blocks.iter().enumerate() {
            path.push(index);
            out.push(path.clone());
            if !block.folded {
                visit(&block.children, path, out);
            }
            path.pop();
        }
    }
    let mut out = Vec::new();
    visit(&document.blocks, &mut Vec::new(), &mut out);
    out
}

/// Folds a block, or unfolds it; a block with nothing under it is never
/// folded. Says whether that changed it.
fn set_fold(block: &mut Block, folded: bool) -> bool {
    let folded = folded && !block.children.is_empty();
    std::mem::replace(&mut block.folded, folded) != folded
}

/// Folds some blocks and every block under them, or unfolds them. Says
/// whether that changed any.
fn fold_all(blocks: &mut [Block], folded: bool) -> bool {
    let mut any = false;
    for block in blocks {
        any |= set_fold(block, folded);
        any |= fold_all(&mut block.children, folded);
    }
    any
}

/// Puts the checked items of a list after the rest, each kind in the
/// order it was in; the blank lines stay where they were on the page.
/// Says whether any moved.
fn sink_done(children: &mut Vec<Block>) -> bool {
    let done = |block: &Block| block.task_state().is_some_and(Task::is_done);
    if !children.iter().skip_while(|block| !done(block)).any(|block| !done(block)) {
        return false;
    }
    let gaps: Vec<Vec<String>> = children.iter_mut().map(|block| std::mem::take(&mut block.layout.gap)).collect();
    let (mut sorted, sunk): (Vec<Block>, Vec<Block>) = std::mem::take(children).into_iter().partition(|block| !done(block));
    sorted.extend(sunk);
    for (block, gap) in sorted.iter_mut().zip(gaps) {
        block.layout.gap = gap;
    }
    *children = sorted;
    true
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
        Command::MarkDone => match task {
            Some(Task::Open) => item(marker?, Some(Task::Done('x'))),
            _ => return None,
        },
        Command::Turn(to) => match to {
            RowKind::Paragraph => BlockKind::Paragraph,
            RowKind::Bullet => item(Marker::Bullet(dash), None),
            RowKind::Checkbox => item(Marker::Bullet(dash), Some(task.unwrap_or(Task::Open))),
            RowKind::Task => item(Marker::Bullet('+'), Some(task.unwrap_or(Task::Open))),
            RowKind::Numbered => {
                item(marker.filter(|marker| matches!(marker, Marker::Ordered { .. })).unwrap_or(Marker::Ordered { number: 1, delimiter: '.' }), None)
            }
            RowKind::Heading(level) => BlockKind::Heading((*level).clamp(1, 6)),
            RowKind::Quote => BlockKind::Quote,
        },
        _ => return None,
    })
}

/// The arrow that what is typed completes: `>` after `-` is →, `-` after
/// `<` is ←, and the two characters become the one. Not in code — there
/// they are what was meant — and not the `-->` that ends a comment.
fn arrow(text: &str, range: &Range<usize>, typed: &str) -> Option<(Range<usize>, &'static str)> {
    if !range.is_empty() {
        return None;
    }
    let before = &text[..range.start];
    let arrow = match typed {
        ">" if before.ends_with('-') && !before.ends_with("--") => "→",
        "-" if before.ends_with('<') => "←",
        _ => return None,
    };
    // Inside a code span or a fence, a backtick before here is still open.
    if before.matches('`').count() % 2 == 1 {
        return None;
    }
    Some((range.start - 1..range.start, arrow))
}

/// How much of a note's text after its frontmatter is its title: a first
/// line that is `# Title` — after blank lines, if the file has any there
/// — with the blank lines after it.
fn heading_len(rest: &str) -> usize {
    let blank: usize = rest.split_inclusive('\n').take_while(|line| line.trim().is_empty() && line.ends_with('\n')).map(str::len).sum();
    let first = rest[blank..].split_inclusive('\n').next().unwrap_or("");
    let words = first.trim_end_matches(['\n', '\r']);
    if words.strip_prefix("# ").is_none_or(|title| title.trim().is_empty()) {
        return 0;
    }
    let mut end = blank + first.len();
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
    fn a_first_line_is_taken_to_be_the_title() {
        let mut session = Session::new("- Plans for *spring*\n  - seeds\n  - beds\n- later\n", Mode::Outline);
        assert_eq!(session.first_line().as_deref(), Some("Plans for spring"));
        assert_eq!(session.take_first_line().as_deref(), Some("Plans for spring"));
        assert_eq!(session.text(), "seeds\nbeds\nlater");
        session.set_title("Plans for spring");
        assert_eq!(session.markdown(), "# Plans for spring\n\n- seeds\n- beds\n- later\n");

        // A line that goes on keeps what it went on to say; a heading gives its words.
        let mut text = Session::new("# A title typed\n\nAnd the rest.\n", Mode::Text);
        // Read as its title already: nothing left to take but the rest.
        assert_eq!(text.title().as_deref(), Some("A title typed"));
        let mut plain = Session::new("First words\nsecond line\n\nmore\n", Mode::Text);
        assert_eq!(plain.take_first_line().as_deref(), Some("First words"));
        assert_eq!(plain.text(), "second line\n\nmore\n");
        // Code and pictures title nothing.
        assert_eq!(Session::new("```\ncode\n```\n", Mode::Text).take_first_line(), None);
        assert_eq!(Session::new("![](a.png)\n", Mode::Outline).take_first_line(), None);
        assert_eq!(text.take_first_line().as_deref(), Some("And the rest."));
    }

    #[test]
    fn arrows_are_made_as_they_are_typed() {
        for mode in [Mode::Outline, Mode::Text] {
            let mut session = Session::new("", mode);
            let mut caret = 0;
            for typed in "a -> b <- c, `x -> y`, <!-- no -->".chars() {
                caret = session.replace(caret..caret, &typed.to_string()).selection.end;
            }
            assert_eq!(session.text(), "a → b ← c, `x -> y`, <!-- no -->", "{mode:?}");
        }
        // What is pasted is left as it is.
        let mut session = Session::new("", Mode::Text);
        session.replace(0..0, "a -> b");
        assert_eq!(session.text(), "a -> b");
    }

    #[test]
    fn a_heading_after_blank_lines_is_still_the_title() {
        let source = "---\nicon: link\n---\n\n# Cerebras on X\n\n- URL: <https://example.com>\n";
        let mut session = Session::new(source, Mode::Outline);
        assert_eq!(session.title().as_deref(), Some("Cerebras on X"));
        assert_eq!(session.text(), "URL: <https://example.com>");
        assert_eq!(session.markdown(), source);
        session.set_title("Cerebras");
        assert_eq!(session.markdown(), "---\nicon: link\n---\n\n# Cerebras\n\n- URL: <https://example.com>\n");
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
    const TREE: &str = "- one\n- two\n  - under two\n    - deep\n  - also under\n- three\n";

    /// The index of the row shown that starts with these words.
    fn row(session: &Session, words: &str) -> usize {
        session.text().split('\n').position(|line| line.starts_with(words)).unwrap_or_else(|| panic!("no row {words:?} in {:?}", session.text()))
    }

    /// Does a command to the rows that start with these words, the caret where it is.
    fn on(session: &mut Session, view: &mut String, rows: &[&str], caret: usize, command: Command) -> Option<Change> {
        let rows: Vec<usize> = rows.iter().map(|words| row(session, words)).collect();
        let change = session.perform_on(&rows, caret..caret, command)?;
        shown(view, &change);
        assert_eq!(view, session.text());
        Some(change)
    }

    #[test]
    fn a_folded_row_shows_none_of_what_is_under_it() {
        let (mut session, mut view) = outline(TREE);
        // The caret is under the row folded: it goes to that row.
        let caret = view.find("deep").unwrap() + 2;
        let change = on(&mut session, &mut view, &["two"], caret, Command::Fold).unwrap();
        assert_eq!(view, "one\ntwo\nthree");
        assert_eq!(change.selection, 4..4);
        assert_eq!(session.markdown(), TREE, "a fold is no part of the note");
        assert_eq!(session.row_folds(), [(false, false), (true, true), (false, false)]);
        assert_eq!(session.folded_rows(), [FoldedRow { index: 1, text: "two".into() }]);
        let info = session.row_info(1).unwrap();
        assert_eq!((info.folded, info.hidden, info.shown, info.has_children, info.can_move_up, info.can_move_down), (true, 3, 0, true, true, true));
        // A row with nothing under it does not fold; a fold is undone as any change is.
        assert_eq!(session.perform(0..0, Command::Fold), None);
        shown(&mut view, &session.undo().unwrap());
        assert_eq!((view.as_str(), session.folded_rows().len()), ("one\ntwo\nunder two\ndeep\nalso under\nthree", 0));
        shown(&mut view, &session.redo().unwrap());
        assert_eq!(view, "one\ntwo\nthree");
        // Unfolded by the same command given again, or by its own.
        on(&mut session, &mut view, &["two"], 0, Command::ToggleFold).unwrap();
        assert_eq!(view, "one\ntwo\nunder two\ndeep\nalso under\nthree");
        assert_eq!(session.perform(4..4, Command::Unfold), None);
    }

    #[test]
    fn rows_fold_completely_and_all_at_once() {
        let (mut session, mut view) = outline(TREE);
        let info = session.row_info(1).unwrap();
        assert!(info.open_inside && !info.folds_inside && info.shown == 3);
        on(&mut session, &mut view, &["two"], 0, Command::FoldCompletely).unwrap();
        assert_eq!(view, "one\ntwo\nthree");
        // Unfolded, the row under it that was folded with it still is.
        on(&mut session, &mut view, &["two"], 0, Command::Unfold).unwrap();
        assert_eq!(view, "one\ntwo\nunder two\nalso under\nthree");
        assert!(session.row_info(1).unwrap().folds_inside);
        on(&mut session, &mut view, &["two"], 0, Command::UnfoldCompletely).unwrap();
        assert_eq!(view, "one\ntwo\nunder two\ndeep\nalso under\nthree");
        shown(&mut view, &session.perform(0..0, Command::FoldAll).unwrap());
        assert_eq!((view.as_str(), session.folded_rows().len()), ("one\ntwo\nthree", 2));
        shown(&mut view, &session.perform(0..0, Command::UnfoldAll).unwrap());
        assert_eq!(view, "one\ntwo\nunder two\ndeep\nalso under\nthree");
        assert_eq!(session.perform(0..0, Command::UnfoldAll), None);
    }

    #[test]
    fn folds_are_kept_by_place_and_words_and_found_again() {
        let (mut session, _) = outline(TREE);
        assert!(session.set_folded_rows(&[FoldedRow { index: 1, text: "two".into() }]));
        assert_eq!(session.text(), "one\ntwo\nthree");
        // The same again changes nothing.
        assert!(!session.set_folded_rows(&[FoldedRow { index: 1, text: "two".into() }]));
        // The note changed underneath: a row added above. The row is known by its words.
        let mut moved = Session::new(&format!("- new\n{TREE}"), Mode::Outline);
        assert!(moved.set_folded_rows(&[FoldedRow { index: 1, text: "two".into() }, FoldedRow { index: 9, text: "gone".into() }]));
        assert_eq!(moved.text(), "new\none\ntwo\nthree");
        assert_eq!(moved.folded_rows(), [FoldedRow { index: 2, text: "two".into() }]);
        // Of two rows that say the same, the nearer; and a row with nothing under it is not folded.
        let mut twins = Session::new("- a\n  - x\n- b\n- a\n  - y\n", Mode::Outline);
        twins.set_folded_rows(&[FoldedRow { index: 2, text: "a".into() }, FoldedRow { index: 2, text: "b".into() }]);
        assert_eq!(twins.text(), "a\nx\nb\na");
        // None: all unfolded.
        assert!(twins.set_folded_rows(&[]));
        assert_eq!(twins.text(), "a\nx\nb\na\ny");
        // As text nothing is hidden, and what was folded is folded still when it is an outline again.
        session.set_mode(Mode::Text);
        assert_eq!(session.text(), TREE);
        session.replace(5..5, "!");
        session.set_mode(Mode::Outline);
        assert_eq!(session.text(), "one!\ntwo\nthree");
    }

    #[test]
    fn writing_goes_on_around_what_is_folded() {
        let (mut session, mut view) = outline(TREE);
        on(&mut session, &mut view, &["two"], 0, Command::Fold).unwrap();
        // Typed in the folded row: its words change, and nothing under it.
        let at = at_end_of(&view, "two");
        shown(&mut view, &session.replace(at..at, "!"));
        assert_eq!(session.markdown(), TREE.replace("- two", "- two!"));
        // Return at its end: the new row comes after all it hides, not among them.
        let change = session.perform(at + 1..at + 1, Command::Newline).unwrap();
        shown(&mut view, &change);
        assert_eq!((view.as_str(), change.selection), ("one\ntwo!\n\nthree", 9..9));
        assert_eq!(session.markdown(), "- one\n- two!\n  - under two\n    - deep\n  - also under\n- \n- three\n");
        shown(&mut view, &session.undo().unwrap());
        // Return in the middle of it: what it hides stays with its first half.
        shown(&mut view, &session.perform(at - 1..at - 1, Command::Newline).unwrap());
        assert_eq!(view, "one\ntw\no!\nthree");
        assert_eq!(session.markdown(), "- one\n- tw\n  - under two\n    - deep\n  - also under\n- o!\n- three\n");
        shown(&mut view, &session.undo().unwrap());
        assert_eq!(view, "one\ntwo!\nthree");
        // Lines pasted at its end are rows after it.
        shown(&mut view, &session.replace(at + 1..at + 1, "\npasted"));
        assert_eq!(view, "one\ntwo!\npasted\nthree");
        assert!(session.markdown().contains("  - also under\n- pasted\n- three\n"));
        shown(&mut view, &session.undo().unwrap());
        // Delete at the start of the row after it: joined onto the folded row, not onto a row out of sight.
        let three = view.find("three").unwrap();
        let change = session.perform(three..three, Command::DeleteBackward).unwrap();
        shown(&mut view, &change);
        assert_eq!((view.as_str(), change.selection), ("one\ntwo!three", 8..8));
        assert_eq!(session.markdown(), "- one\n- two!three\n  - under two\n    - deep\n  - also under\n");
    }

    #[test]
    fn return_at_a_rows_start_opens_a_row_above_it() {
        let (mut session, mut view) = outline("- one\n1. first\n   - under\n+ [x] done\n");
        let at = view.find("first").unwrap();
        let change = session.perform(at..at, Command::Newline).unwrap();
        shown(&mut view, &change);
        // The caret stays with the words, and what is under them with them.
        assert_eq!((view.as_str(), &view[change.selection.start..change.selection.start + 5]), ("one\n\nfirst\nunder\ndone", "first"));
        assert_eq!(session.markdown(), "- one\n1. \n2. first\n   - under\n+ [x] done\n");
        let at = view.find("done").unwrap();
        session.perform(at..at, Command::Newline).unwrap();
        assert!(session.markdown().ends_with("+ [ ]\n+ [x] done\n"), "{:?}", session.markdown());
    }

    #[test]
    fn a_folded_row_takes_what_it_hides_wherever_it_goes() {
        let (mut session, mut view) = outline(TREE);
        on(&mut session, &mut view, &["two"], 0, Command::Fold).unwrap();
        let caret = view.find("two").unwrap() + 1;
        // Down, in, out and up again: its rows go with it, and it stays folded.
        let change = session.perform(caret..caret, Command::MoveDown).unwrap();
        shown(&mut view, &change);
        assert_eq!(view, "one\nthree\ntwo");
        assert_eq!(session.markdown(), "- one\n- three\n- two\n  - under two\n    - deep\n  - also under\n");
        let caret = change.selection.start;
        shown(&mut view, &session.perform(caret..caret, Command::Indent).unwrap());
        assert_eq!(session.markdown(), "- one\n- three\n  - two\n    - under two\n      - deep\n    - also under\n");
        assert_eq!(view, "one\nthree\ntwo");
        shown(&mut view, &session.perform(caret..caret, Command::Outdent).unwrap());
        shown(&mut view, &session.perform(caret..caret, Command::MoveToTop).unwrap());
        assert_eq!(view, "two\none\nthree");
        assert_eq!(session.folded_rows(), [FoldedRow { index: 0, text: "two".into() }]);
        // A row set in under a folded row is not put out of sight: the row is unfolded.
        on(&mut session, &mut view, &["one"], 0, Command::Indent).unwrap();
        assert_eq!(view, "two\nunder two\ndeep\nalso under\none\nthree");
        shown(&mut view, &session.undo().unwrap());
        assert_eq!(view, "two\none\nthree");
        // Duplicated, and deleted, with all it hides.
        shown(&mut view, &session.perform(0..0, Command::DuplicateRows).unwrap());
        assert_eq!((view.as_str(), session.body().rows().len()), ("two\ntwo\none\nthree", 10));
        shown(&mut view, &session.perform(0..0, Command::DeleteRows).unwrap());
        shown(&mut view, &session.perform(0..0, Command::DeleteRows).unwrap());
        assert_eq!(session.markdown(), "- one\n- three\n");
    }

    #[test]
    fn a_selection_deleted_across_a_folded_row_takes_what_it_hid() {
        let (mut session, mut view) = outline(TREE);
        on(&mut session, &mut view, &["two"], 0, Command::Fold).unwrap();
        // From inside "one" to inside "three": "two" is taken whole.
        let end = view.len() - 3;
        shown(&mut view, &session.replace(2..end, ""));
        assert_eq!((view.as_str(), session.markdown().as_str()), ("onree", "- onree\n"));
        // Only into the folded row: it is joined, and what it hid is kept, in sight.
        let (mut session, mut view) = outline(TREE);
        on(&mut session, &mut view, &["two"], 0, Command::Fold).unwrap();
        shown(&mut view, &session.replace(2..5, ""));
        assert_eq!(view, "onwo\nunder two\ndeep\nalso under\nthree");
        assert_eq!(session.markdown(), "- onwo\n  - under two\n    - deep\n  - also under\n- three\n");
    }

    #[test]
    fn commands_are_done_to_rows_wherever_the_caret_is() {
        let (mut session, mut view) = outline("- one\n- two\n- three\n- four\n");
        // The caret is in "four"; the rows above it are set in, moved and taken out, and it stays in its word.
        let caret = |view: &str| view.find("four").unwrap() + 2;
        let stays = |view: &str, change: &Change| assert_eq!(&view[change.selection.start - 2..change.selection.start + 2], "four");
        let at = caret(&view);
        let change = on(&mut session, &mut view, &["two", "three"], at, Command::Indent).unwrap();
        assert_eq!(session.markdown(), "- one\n  - two\n  - three\n- four\n");
        stays(&view, &change);
        let at = caret(&view);
        let change = on(&mut session, &mut view, &["one"], at, Command::MoveDown).unwrap();
        assert_eq!(session.markdown(), "- four\n- one\n  - two\n  - three\n");
        stays(&view, &change);
        let at = caret(&view);
        let change = on(&mut session, &mut view, &["two", "three"], at, Command::Outdent).unwrap();
        assert_eq!(session.markdown(), "- four\n- one\n- two\n- three\n");
        stays(&view, &change);
        // Two rows not side by side, to the top and to the bottom, in their order.
        on(&mut session, &mut view, &["one", "three"], 0, Command::MoveToTop).unwrap();
        assert_eq!(view, "one\nthree\nfour\ntwo");
        on(&mut session, &mut view, &["one", "three"], 0, Command::MoveToBottom).unwrap();
        assert_eq!(view, "four\ntwo\none\nthree");
        assert_eq!(on(&mut session, &mut view, &["one", "three"], 0, Command::MoveToBottom), None);
        // Deleted: the caret, in a row that went, goes to where the first of them was.
        let at = view.find("two").unwrap() + 1;
        let change = on(&mut session, &mut view, &["two", "three"], at, Command::DeleteRows).unwrap();
        assert_eq!((view.as_str(), change.selection), ("four\none", 5..5));
        // At the caret's own commands, and as text, there are no rows to give.
        assert_eq!(session.perform_on(&[0], 0..0, Command::Newline), None);
        session.set_mode(Mode::Text);
        assert_eq!(session.perform_on(&[0], 0..0, Command::Indent), None);
        assert_eq!(session.perform(0..0, Command::Fold), None);
    }

    #[test]
    fn rows_are_turned_and_checked_together() {
        let (mut session, mut view) = outline("- plain\n+ [ ] task\n- [x] ticked\n## Head\n- list\n  - [x] a\n  - [ ] b\n\n  - [x] c\n  - d\n");
        on(&mut session, &mut view, &["plain", "task", "ticked"], 0, Command::MarkDone).unwrap();
        assert!(session.markdown().starts_with("- plain\n+ [x] task\n- [x] ticked\n"));
        assert_eq!(on(&mut session, &mut view, &["plain", "ticked"], 0, Command::MarkDone), None);
        // The checked rows under a row, below the rest: the blank line stays where it was.
        let info = session.row_info(row(&session, "list")).unwrap();
        assert!(info.has_checklist && info.done_to_move && info.task.is_none());
        on(&mut session, &mut view, &["list"], 0, Command::MoveDoneToBottom).unwrap();
        assert!(session.markdown().ends_with("- list\n  - [ ] b\n  - d\n\n  - [x] a\n  - [x] c\n"), "{:?}", session.markdown());
        assert!(!session.row_info(row(&session, "list")).unwrap().done_to_move);
        assert_eq!(on(&mut session, &mut view, &["list"], 0, Command::MoveDoneToBottom), None);
        // Turned into other kinds; a box keeps its tick, and numbers count on.
        on(&mut session, &mut view, &["task"], 0, Command::Turn(RowKind::Checkbox)).unwrap();
        on(&mut session, &mut view, &["ticked"], 0, Command::Turn(RowKind::Task)).unwrap();
        on(&mut session, &mut view, &["Head"], 0, Command::Turn(RowKind::Quote)).unwrap();
        assert!(session.markdown().starts_with("- plain\n- [x] task\n+ [x] ticked\n> Head\n"), "{:?}", session.markdown());
        on(&mut session, &mut view, &["plain", "task"], 0, Command::Turn(RowKind::Numbered)).unwrap();
        on(&mut session, &mut view, &["ticked"], 0, Command::Turn(RowKind::Heading(2))).unwrap();
        on(&mut session, &mut view, &["Head"], 0, Command::Turn(RowKind::Paragraph)).unwrap();
        assert!(session.markdown().starts_with("1. plain\n2. task\n## ticked\nHead\n"), "{:?}", session.markdown());
        // What it already is, is nothing to do.
        assert_eq!(on(&mut session, &mut view, &["plain"], 0, Command::Turn(RowKind::Numbered)), None);
        assert!(!session.can_redo());
    }

    #[test]
    fn rows_are_carried_and_put_down_at_a_depth() {
        let (mut session, mut view) = outline(TREE);
        let rows = |session: &Session, words: &str| vec![row(session, words)];
        let carry = |session: &mut Session, view: &mut String, words: &str, before: &str, depth: usize| {
            let (rows, before) = (rows(session, words), if before.is_empty() { session.layout().lines.len() } else { row(session, before) });
            let change = session.move_rows(&rows, before, depth, 0..0)?;
            shown(view, &change);
            assert_eq!(view, session.text());
            Some(session.markdown())
        };
        // "three", before "also under": no shallower than that row, no deeper than under the row above.
        let (three, also) = (row(&session, "three"), row(&session, "also under"));
        assert_eq!((session.drop_depth(&[three], also, 0), session.drop_depth(&[three], also, 9)), (Some(1), Some(3)));
        assert_eq!(carry(&mut session, &mut view, "three", "also under", 0).unwrap(), "- one\n- two\n  - under two\n    - deep\n  - three\n  - also under\n");
        // To the end: as deep as under the last row, or anywhere out to the margin.
        let (three, end) = (row(&session, "three"), session.layout().lines.len());
        assert_eq!((session.drop_depth(&[three], end, 9), session.drop_depth(&[three], end, 0)), (Some(2), Some(0)));
        assert_eq!(carry(&mut session, &mut view, "three", "", 2).unwrap(), "- one\n- two\n  - under two\n    - deep\n  - also under\n    - three\n");
        assert_eq!(carry(&mut session, &mut view, "three", "", 0).unwrap(), TREE);
        // A row with rows under it goes with them — and nowhere, put down among them or where it is.
        assert_eq!(session.drop_depth(&[row(&session, "two")], row(&session, "deep"), 1), None);
        assert_eq!(carry(&mut session, &mut view, "two", "deep", 1), None);
        assert_eq!(carry(&mut session, &mut view, "two", "three", 0), None);
        assert_eq!(carry(&mut session, &mut view, "two", "one", 0).unwrap(), "- two\n  - under two\n    - deep\n  - also under\n- one\n- three\n");
        // Under a row above it: its first row, when it has rows; and not under a folded one.
        assert_eq!(carry(&mut session, &mut view, "three", "under two", 5).unwrap(), "- two\n  - three\n  - under two\n    - deep\n  - also under\n- one\n");
        session.perform_on(&[0], 0..0, Command::Fold).unwrap();
        view = session.text().to_owned();
        assert_eq!(session.drop_depth(&[1], 2, 5), Some(0));
        assert_eq!(session.drop_depth(&[0], 9, 0), Some(0));
        assert_eq!(carry(&mut session, &mut view, "one", "", 5), None);
        assert_eq!(carry(&mut session, &mut view, "one", "two", 3).unwrap(), "- one\n- two\n  - three\n  - under two\n    - deep\n  - also under\n");
        // The blank lines of the page stay where they were; undone in one.
        let (mut gaps, mut view) = outline("- a\n\n- b\n- c\n");
        let change = gaps.move_rows(&[1], 3, 0, 2..2).unwrap();
        shown(&mut view, &change);
        assert_eq!((gaps.markdown().as_str(), &view[change.selection.start..]), ("- a\n\n- c\n- b\n", "b"));
        gaps.undo().unwrap();
        assert_eq!(gaps.markdown(), "- a\n\n- b\n- c\n");
    }

    #[test]
    fn rows_are_copied_as_markdown_of_their_own() {
        let (mut session, _) = outline(TREE);
        assert_eq!(session.markdown_of(&[2, 3, 5]), "- under two\n  - deep\n- three\n");
        // Folded, a row is copied with what it hides.
        session.perform_on(&[1], 0..0, Command::Fold).unwrap();
        assert_eq!(session.markdown_of(&[1]), "- two\n  - under two\n    - deep\n  - also under\n");
        assert_eq!(session.markdown_of(&[]), "");
    }

    #[test]
    fn time_blocks_are_made_and_marked() {
        let (mut session, mut view) = outline("- Today\n  - 9:00 Standup\n  - 9:30–11:00 Deep work\n    - notes\n  - 13:00 Lunch\n");
        let marks = session.time_marks(false);
        let heads: Vec<_> =
            marks.iter().filter_map(|mark| mark.head.as_ref().map(|head| (mark.row, head.label.as_str(), head.last_row, head.next_row))).collect();
        assert_eq!(heads, [(1, "9:00 – 9:30 · 30m", 1, Some(2)), (2, "9:30 – 11:00 · 1h 30m", 3, Some(4)), (4, "13:00 – 13:30 · 30m", 4, None)]);
        // Where a block's time is written, with the space after it; and the free time after the second.
        let stamp = marks[1].head.as_ref().unwrap().stamp.clone();
        assert_eq!(&view[stamp], "9:30–11:00 ");
        let foot = &marks.iter().find(|mark| mark.row == 3).unwrap().feet[0];
        assert_eq!((foot.free, foot.free_label.as_deref(), foot.is_last), (120, Some("2h free"), false));
        assert_eq!(session.time_marks(true)[0].head.as_ref().unwrap().label, "9 – 9:30 AM · 30m");
        // Return at a block's end makes the next, the caret after its time.
        let at = at_end_of(&view, "9:00 Standup");
        let change = session.perform(at..at, Command::Newline).unwrap();
        shown(&mut view, &change);
        assert_eq!(&view[..change.selection.start], "Today\n9:00 Standup\n9:30–10:00 ");
        // It starts before the one after it ends: said of that one.
        let overlapped = session.time_marks(false).into_iter().find_map(|mark| mark.head.filter(|head| head.overlap.is_some())).unwrap();
        assert_eq!((overlapped.overlap.as_deref(), overlapped.overlap_short.as_deref()), (Some("overlaps 30m"), Some("30m overlap")));
        shown(&mut view, &session.undo().unwrap());
        // A new block at a row among them: where its time puts it.
        let change = session.perform(at..at, Command::NewTimeBlock { now: 11 * 60 + 12 }).unwrap();
        shown(&mut view, &change);
        assert_eq!(session.markdown(), "- Today\n  - 9:00 Standup\n  - 9:30–11:00 Deep work\n    - notes\n  - 11:10–11:25 \n  - 13:00 Lunch\n");
        assert!(view[..change.selection.start].ends_with("11:10–11:25 "));
        // Folded away, a timeline has nothing to draw; in an empty note, a block is its first row.
        session.perform_on(&[0], 0..0, Command::Fold).unwrap();
        assert!(session.time_marks(false).is_empty());
        let (mut empty, _) = outline("");
        empty.perform(0..0, Command::NewTimeBlock { now: 600 }).unwrap();
        assert_eq!(empty.markdown(), "- 10:00–10:15 \n");
    }

    #[test]
    fn delete_after_a_picture_takes_it_whole_and_an_address_links_words() {
        let (mut session, mut view) = outline("- see ![cat](assets/cat.png) <!-- {\"width\":40} --> there\n- ![](a.png) ![](b.png)\n");
        let at = view.find(" there").unwrap();
        let change = session.perform(at..at, Command::DeleteBackward).unwrap();
        shown(&mut view, &change);
        assert_eq!((view.as_str(), change.selection), ("see  there\n![](a.png) ![](b.png)", 4..4));
        let end = view.len();
        shown(&mut view, &session.perform(end..end, Command::DeleteBackward).unwrap());
        assert_eq!(session.markdown(), "- see  there\n- ![](a.png) \n");
        assert_eq!(session.perform(2..2, Command::DeleteBackward), None);
        // An address, on words selected: they link to it; on a link's words, it goes there instead.
        let change = session.link(0..3, " https://example.com/a(b)\n").unwrap();
        shown(&mut view, &change);
        assert_eq!((view.lines().next().unwrap(), change.selection), ("[see](https://example.com/a%28b%29)  there", 35..35));
        shown(&mut view, &session.link(1..4, "mailto:ada@example.com").unwrap());
        assert!(view.starts_with("[see](mailto:ada@example.com)  there"));
        assert_eq!(session.link(0..view.len(), "https://example.com"), None, "not across rows");
        assert_eq!(session.link(0..2, "not an address"), None);
        assert_eq!(session.link(3..3, "https://example.com"), None);
        session.undo().unwrap();
        assert!(session.markdown().starts_with("- [see](https://example.com/a%28b%29)  there\n"));
    }
}
