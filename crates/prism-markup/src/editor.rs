//! What an editor needs of a note's body while it is being written.
//!
//! An editor holds a body as its Markdown — the very text of the file —
//! in a text view. Everything it must know about that text beyond its
//! characters, and everything it does to it beyond typing them, is here,
//! so that every editor on every platform behaves alike and none of them
//! knows Markdown:
//!
//! - [`layout`] reads a body into [`Line`]s (what each line is, how deep,
//!   where its marker ends and its words begin) and [`Run`]s (emphasis,
//!   links, tags, the markup to hide). A text view turns these into
//!   fonts, colours and pills.
//! - [`perform`] carries out a [`Command`] — Return, Tab, move a row up,
//!   make it a task, embolden — as an [`Edit`]: a range of the text to
//!   replace, what with, and where the selection goes. The text view
//!   applies it, which is also what makes it undoable.
//! - [`completion`] says what is being typed at the caret that could be
//!   finished: a `[[link`, a `#tag`.
//!
//! All of it works on lines, never on a parse of the whole note, so its
//! cost is the lines touched; and since an edit is a replacement of text,
//! whatever it does not touch keeps every byte it had.
//!
//! Offsets are bytes of the body. (The Swift bindings give UTF-16.)

use crate::inline::{self, Span, SpanKind, Style};
use std::ops::Range;

/// What a line of a body is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LineKind {
    Blank,
    Paragraph,
    /// `## text`: the level, 1 to 6.
    Heading(u8),
    /// A list item's first line.
    Item {
        /// Its number, for `1.`; `None` for a bullet.
        ordered: Option<u32>,
        /// Its checkbox: open, or done. `None` for an item without one.
        task: Option<bool>,
        /// The bullet it is written with: `-`, `*` or `+`; `.` or `)`
        /// for a numbered one.
        bullet: char,
    },
    /// `> text`.
    Quote,
    /// A code fence's opening or closing line.
    Fence,
    /// A line inside a code fence.
    Code,
    /// A line of a pipe table.
    Table,
    /// `---`, `***` or `___`.
    Rule,
}

/// One line of a body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    /// The line, without its line break.
    pub range: Range<usize>,
    pub kind: LineKind,
    /// The spaces it is indented by.
    pub indent: usize,
    /// Where its words begin: after the indentation and its marker —
    /// bullet, number, checkbox, hashes, `>`.
    pub content: usize,
    /// How many list items it is inside: 0 for a top-level line, 1 for a
    /// top-level item's own line, and so on. A paragraph continuing an
    /// item is as deep as the item.
    pub depth: usize,
}

/// What a stretch of a line means.
#[derive(Debug, Clone, PartialEq)]
pub enum RunKind {
    /// Markup with nothing to show: `**`, `[[`, a link's address, a
    /// heading's hashes. Hidden off the lines being written in.
    Markup,
    Strong,
    Emphasis,
    Strikethrough,
    Highlight,
    Code,
    /// A link to a page: its shown words. `embed` for `![[…]]`.
    PageLink {
        target: String,
        embed: bool,
    },
    /// A link to the web: its shown words — or, for a bare address, the
    /// address itself.
    WebLink {
        url: String,
    },
    Tag {
        name: String,
    },
    /// A picture: the whole of its markup, which shows as the picture.
    Image {
        source: String,
        alt: String,
        width: Option<f64>,
        height: Option<f64>,
    },
    /// A list item's bullet or number.
    Bullet,
    /// A list item's checkbox: `[ ]` or `[x]`.
    Checkbox {
        done: bool,
    },
    /// A quote's `>`.
    QuoteMark,
    /// A callout's `[!KIND]`.
    Callout {
        kind: String,
    },
    /// A code fence's info string: `query`, `rust`.
    FenceInfo {
        info: String,
    },
}

/// A stretch of a body, and what it means.
#[derive(Debug, Clone, PartialEq)]
pub struct Run {
    pub range: Range<usize>,
    pub kind: RunKind,
}

/// A body, read for an editor.
#[derive(Debug, Clone, PartialEq)]
pub struct Layout {
    pub lines: Vec<Line>,
    /// In the order of the text; a run inside another comes after it.
    pub runs: Vec<Run>,
    /// Whether each line's marker — its bullet, its hashes — is written
    /// in the text. In an outline it is not: a line's kind says what to
    /// draw beside it. See [`crate::session`].
    pub markers_in_text: bool,
}

impl Layout {
    /// The index of the line an offset is on.
    pub fn line_at(&self, offset: usize) -> usize {
        match self.lines.binary_search_by(|line| {
            if offset < line.range.start {
                std::cmp::Ordering::Greater
            } else if offset > line.range.end {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Equal
            }
        }) {
            Ok(index) => index,
            Err(index) => index.min(self.lines.len().saturating_sub(1)),
        }
    }
}

// --- Reading -----------------------------------------------------------------

/// A list marker at the start of a line's words: its bullet, its number,
/// and the length of the marker with the spaces after it.
fn list_marker(text: &str) -> Option<(char, Option<u32>, usize)> {
    let bytes = text.as_bytes();
    let (bullet, ordered, width) = match bytes.first()? {
        b'-' | b'*' | b'+' => (bytes[0] as char, None, 1),
        b'0'..=b'9' => {
            let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
            let delimiter = *bytes.get(digits)?;
            if digits > 9 || !(delimiter == b'.' || delimiter == b')') {
                return None;
            }
            (delimiter as char, text[..digits].parse().ok(), digits + 1)
        }
        _ => return None,
    };
    let spaces = bytes[width..].iter().take_while(|b| **b == b' ').count();
    // A marker needs a space after it, unless the line ends there.
    (spaces > 0 || bytes.len() == width).then_some((bullet, ordered, width + spaces))
}

/// A checkbox at the start of an item's words: whether it is done, and
/// its length with the space after it.
fn checkbox(text: &str) -> Option<(bool, usize)> {
    let bytes = text.as_bytes();
    if bytes.len() < 3 || bytes[0] != b'[' || bytes[2] != b']' {
        return None;
    }
    let done = match bytes[1] {
        b' ' => false,
        b'x' | b'X' => true,
        _ => return None,
    };
    match bytes.get(3) {
        Some(b' ') => Some((done, 4)),
        None => Some((done, 3)),
        _ => None,
    }
}

fn is_rule(text: &str) -> bool {
    let marks: Vec<char> = text.chars().filter(|c| !c.is_whitespace()).collect();
    marks.len() >= 3 && matches!(marks[0], '-' | '*' | '_') && marks.iter().all(|c| *c == marks[0])
}

fn fence(text: &str) -> Option<(char, usize)> {
    let mark = text.chars().next().filter(|c| *c == '`' || *c == '~')?;
    let length = text.chars().take_while(|c| *c == mark).count();
    (length >= 3).then_some((mark, length))
}

/// Reads a body for an editor.
pub fn layout(body: &str) -> Layout {
    let mut layout = Layout { lines: Vec::new(), runs: Vec::new(), markers_in_text: true };
    // The indentation of each list item the line is inside, with where
    // that item's words begin: a line indented at least so far is in it.
    let mut items: Vec<usize> = Vec::new();
    let mut open_fence: Option<(char, usize)> = None;
    let mut start = 0;
    for raw in body.split('\n') {
        let text = raw.strip_suffix('\r').unwrap_or(raw);
        let range = start..start + text.len();
        start += raw.len() + 1;
        let indent = text.len() - text.trim_start_matches(' ').len();
        let words = &text[indent..];
        let at = range.start + indent;

        if let Some((mark, length)) = open_fence {
            let closes = fence(words).is_some_and(|(m, l)| m == mark && l >= length && words[l..].trim().is_empty());
            if closes {
                open_fence = None;
            }
            layout.lines.push(Line { range, kind: if closes { LineKind::Fence } else { LineKind::Code }, indent, content: at, depth: items.len() });
            continue;
        }
        if words.is_empty() {
            layout.lines.push(Line { range, kind: LineKind::Blank, indent, content: at, depth: items.len() });
            continue;
        }
        // A line indented less than an item's words is out of that item.
        while items.last().is_some_and(|content| indent < *content) {
            items.pop();
        }

        if let Some((mark, length)) = fence(words) {
            open_fence = Some((mark, length));
            let info = words[length..].trim();
            if !info.is_empty() {
                let info_at = at + length + (words[length..].len() - words[length..].trim_start().len());
                layout.runs.push(Run { range: info_at..info_at + info.len(), kind: RunKind::FenceInfo { info: info.to_owned() } });
            }
            layout.lines.push(Line { range, kind: LineKind::Fence, indent, content: at, depth: items.len() });
            continue;
        }
        if is_rule(words) && list_marker(words).is_none_or(|_| words.chars().filter(|c| !c.is_whitespace()).count() >= 3) {
            layout.lines.push(Line { range, kind: LineKind::Rule, indent, content: at, depth: items.len() });
            continue;
        }
        if let Some((bullet, ordered, width)) = list_marker(words) {
            // An item indented no further than the one before is its sibling.
            while items.last().is_some_and(|content| indent < *content) {
                items.pop();
            }
            let mut content = at + width;
            layout.runs.push(Run { range: at..at + width.min(words.trim_end().len()).max(1), kind: RunKind::Bullet });
            let task = checkbox(&text[indent + width..]).map(|(done, length)| {
                layout.runs.push(Run { range: content..content + 3, kind: RunKind::Checkbox { done } });
                content += length;
                done
            });
            let depth = items.len() + 1;
            items.push(indent + width);
            read_inline(body, content..range.end, &mut layout.runs);
            layout.lines.push(Line { range, kind: LineKind::Item { ordered, task, bullet }, indent, content, depth });
            continue;
        }
        let hashes = words.bytes().take_while(|b| *b == b'#').count();
        if (1..=6).contains(&hashes) && (words.len() == hashes || words.as_bytes()[hashes] == b' ') {
            let spaces = words[hashes..].len() - words[hashes..].trim_start_matches(' ').len();
            let content = at + hashes + spaces;
            layout.runs.push(Run { range: at..content, kind: RunKind::Markup });
            read_inline(body, content..range.end, &mut layout.runs);
            layout.lines.push(Line { range, kind: LineKind::Heading(hashes as u8), indent, content, depth: items.len() });
            continue;
        }
        if let Some(rest) = words.strip_prefix('>') {
            let content = at + 1 + usize::from(rest.starts_with(' '));
            layout.runs.push(Run { range: at..at + 1, kind: RunKind::QuoteMark });
            let quoted = &body[content..range.end];
            match quoted.strip_prefix("[!").and_then(|rest| rest.split_once(']')) {
                Some((kind, after)) if !kind.is_empty() && kind.chars().all(|c| c.is_ascii_alphabetic()) && after.trim().is_empty() => {
                    layout.runs.push(Run { range: content..content + kind.len() + 3, kind: RunKind::Callout { kind: kind.to_owned() } });
                }
                _ => read_inline(body, content..range.end, &mut layout.runs),
            }
            layout.lines.push(Line { range, kind: LineKind::Quote, indent, content, depth: items.len() });
            continue;
        }
        if words.starts_with('|') {
            read_inline(body, at..range.end, &mut layout.runs);
            layout.lines.push(Line { range, kind: LineKind::Table, indent, content: at, depth: items.len() });
            continue;
        }
        read_inline(body, at..range.end, &mut layout.runs);
        layout.lines.push(Line { range, kind: LineKind::Paragraph, indent, content: at, depth: items.len() });
    }
    // `split` gives one line more than there are for a body ending in a
    // line break: the empty line the caret can stand on. It is kept.
    layout
}

/// The inline runs of a line's words.
pub(crate) fn read_inline(body: &str, range: Range<usize>, runs: &mut Vec<Run>) {
    fn visit(text: &str, base: usize, spans: &[Span], runs: &mut Vec<Run>) {
        for span in spans {
            let whole = base + span.range.start..base + span.range.end;
            let shown = base + span.content.start..base + span.content.end;
            let markup = |runs: &mut Vec<Run>| {
                if whole.start < shown.start {
                    runs.push(Run { range: whole.start..shown.start, kind: RunKind::Markup });
                }
                if shown.end < whole.end {
                    runs.push(Run { range: shown.end..whole.end, kind: RunKind::Markup });
                }
            };
            let kind = match &span.kind {
                SpanKind::Strong => Some(RunKind::Strong),
                SpanKind::Emphasis => Some(RunKind::Emphasis),
                SpanKind::Strikethrough => Some(RunKind::Strikethrough),
                SpanKind::Highlight => Some(RunKind::Highlight),
                SpanKind::Code => Some(RunKind::Code),
                SpanKind::Link { target, .. } => Some(RunKind::WebLink { url: target.clone() }),
                SpanKind::Autolink { url } => Some(RunKind::WebLink { url: url.clone() }),
                SpanKind::WikiLink { target, embed, .. } => Some(RunKind::PageLink { target: target.clone(), embed: *embed }),
                SpanKind::Url => {
                    runs.push(Run { range: whole.clone(), kind: RunKind::WebLink { url: text[span.range.clone()].to_owned() } });
                    continue;
                }
                SpanKind::Tag(name) => {
                    runs.push(Run { range: whole.clone(), kind: RunKind::Tag { name: name.clone() } });
                    continue;
                }
                SpanKind::Image { source, alt, width, height } => {
                    runs.push(Run { range: whole.clone(), kind: RunKind::Image { source: source.clone(), alt: alt.clone(), width: *width, height: *height } });
                    continue;
                }
                SpanKind::Comment => {
                    runs.push(Run { range: whole.clone(), kind: RunKind::Markup });
                    continue;
                }
                SpanKind::Escape => {
                    // The backslash is markup; the character is itself.
                    runs.push(Run { range: whole.start..whole.start + 1, kind: RunKind::Markup });
                    continue;
                }
            };
            if let Some(kind) = kind {
                runs.push(Run { range: shown.clone(), kind });
            }
            markup(runs);
            visit(text, base, &span.children, runs);
        }
    }
    let text = &body[range.clone()];
    visit(text, range.start, &inline::parse(text), runs);
}

// --- Writing -----------------------------------------------------------------

/// Something an editor does to a body beyond typing a character.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    /// Return: a new line of the same sort — a bullet after a bullet, an
    /// open task after a task, the next number after a numbered item. On
    /// an item with nothing written, the item is taken out a level, or
    /// made a plain line.
    Newline,
    /// Delete at the start of a line's words: an item's marker is taken
    /// off, leaving its words a plain line. Delete just after a picture:
    /// the picture is taken out whole, with the size written after it.
    /// Anything else is left to the text view.
    DeleteBackward,
    /// Tab: the selected rows, with what is under them, a level deeper.
    Indent,
    /// ⇧Tab: a level out.
    Outdent,
    /// The selected rows, with what is under them, above the row before.
    MoveUp,
    MoveDown,
    /// The selected rows, and what is under them, taken out.
    DeleteRows,
    /// A copy of the selected rows, straight after them.
    DuplicateRows,
    /// Emboldens the selection, or takes the emboldening off.
    Toggle(Style),
    /// ⌘↩: a plain line or item is made a checklist item (`- [ ]`); an
    /// open one is checked; a checked one is made a plain item again.
    CycleChecklist,
    /// ⇧⌘↩: made a task (`+ [ ]`), or, being one, a plain item again.
    ToggleTask,
    /// A click on a checkbox: checked, or opened again. The selection
    /// is anywhere on the item's line, and is left where it was.
    ToggleCheckbox,
    /// Made a heading of this level — or, being one already, a plain line.
    Heading(u8),
    /// Made a bullet — or, being one, a plain line.
    Bullet,
    /// Made a numbered item — or, being one, a plain line.
    Numbered,
    /// Made a quote — or, being one, a plain line.
    Quote,
    /// The selected rows above every sibling before them. Like all the
    /// commands from here on, an outline's: as text, a note has no rows
    /// to give them to.
    MoveToTop,
    /// The selected rows below every sibling after them.
    MoveToBottom,
    /// The rows under each selected row put out of sight. See
    /// [`Session`](crate::Session) for what a fold is.
    Fold,
    Unfold,
    /// Folded, or — being folded — unfolded.
    ToggleFold,
    /// Each selected row folded, and every row under it that has rows
    /// under it.
    FoldCompletely,
    /// Each selected row unfolded, and every row under it.
    UnfoldCompletely,
    /// Every row of the note that has rows under it, folded.
    FoldAll,
    UnfoldAll,
    /// The open tasks and checklist items among the selected rows, checked.
    MarkDone,
    /// The checked items right under each selected row put after the
    /// rest, in their order.
    MoveDoneToBottom,
    /// Made a row of this kind, whatever it was.
    Turn(RowKind),
}

/// A kind a row can be turned into.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowKind {
    Paragraph,
    /// `- text`.
    Bullet,
    /// `- [ ] text`: a checklist item.
    Checkbox,
    /// `+ [ ] text`: a task.
    Task,
    /// `1. text`.
    Numbered,
    Heading(u8),
    Quote,
}

/// What a command comes to: text to replace, and where the selection
/// then stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Edit {
    /// The range of the body, as it was, to replace.
    pub range: Range<usize>,
    pub replacement: String,
    /// The selection after, in the body as it then is.
    pub selection: Range<usize>,
}

impl Edit {
    /// The body with the edit made.
    pub fn apply(&self, body: &str) -> String {
        format!("{}{}{}", &body[..self.range.start], self.replacement, &body[self.range.end..])
    }
}

/// The marker a line of a kind is written with, as a new line of that
/// sort would be: `- `, `+ [ ] `, `3. `.
fn marker_for(kind: &LineKind) -> String {
    match kind {
        LineKind::Item { ordered: Some(number), bullet, .. } => format!("{}{} ", number + 1, bullet),
        LineKind::Item { task: Some(_), bullet, .. } => format!("{bullet} [ ] "),
        LineKind::Item { bullet, .. } => format!("{bullet} "),
        LineKind::Quote => "> ".to_owned(),
        _ => String::new(),
    }
}

/// The lines a selection covers, each with the lines under it: whole
/// rows of an outline. The range is of lines, end exclusive.
fn rows(layout: &Layout, selection: &Range<usize>) -> Range<usize> {
    let first = layout.line_at(selection.start);
    // A selection ending at a line's very start does not take that line.
    let end = if selection.end > selection.start && layout.lines.get(layout.line_at(selection.end)).is_some_and(|line| line.range.start == selection.end) {
        selection.end - 1
    } else {
        selection.end
    };
    let last = layout.line_at(end).max(first);
    first..under(layout, last)
}

/// One past the last line under a line: what moves with it.
fn under(layout: &Layout, index: usize) -> usize {
    let Some(line) = layout.lines.get(index) else { return index };
    let mut end = index + 1;
    if !matches!(line.kind, LineKind::Item { .. }) {
        return end;
    }
    let inside = line.content - line.range.start;
    let mut blank = 0;
    while let Some(next) = layout.lines.get(end + blank) {
        if next.kind == LineKind::Blank {
            blank += 1;
        } else if next.indent >= inside.min(line.indent + 2) && next.indent > line.indent {
            end += blank + 1;
            blank = 0;
        } else {
            break;
        }
    }
    end
}

/// The text of some lines, each with its line break — the last too, if
/// the body gives it one.
fn text_of(body: &str, layout: &Layout, lines: &Range<usize>) -> Range<usize> {
    let start = layout.lines[lines.start].range.start;
    let end = match layout.lines.get(lines.end) {
        Some(next) => next.range.start,
        None => body.len(),
    };
    start..end
}

/// Carries out a command on a body with a selection. `None` when the
/// command has nothing to do there — Tab on a line that is no item — and
/// the text view should do what it would have done.
pub fn perform(body: &str, selection: Range<usize>, command: Command) -> Option<Edit> {
    let layout = layout(body);
    if layout.lines.is_empty() {
        return None;
    }
    let index = layout.line_at(selection.start);
    let line = &layout.lines[index];
    let caret = selection.start;
    let collapsed = selection.start == selection.end;
    match command {
        Command::Newline => {
            if !collapsed || matches!(line.kind, LineKind::Code | LineKind::Fence | LineKind::Table | LineKind::Rule | LineKind::Blank) {
                return None;
            }
            let marked = matches!(line.kind, LineKind::Item { .. } | LineKind::Quote);
            let words = &body[line.content.min(line.range.end)..line.range.end];
            if marked && words.trim().is_empty() {
                // Return on an item with nothing in it: out a level, or plain.
                return if line.indent > 0 && matches!(line.kind, LineKind::Item { .. }) {
                    perform(body, selection, Command::Outdent)
                } else {
                    Some(Edit { range: line.range.clone(), replacement: String::new(), selection: line.range.start..line.range.start })
                };
            }
            if caret < line.content {
                return None;
            }
            let prefix = format!("\n{}{}", " ".repeat(line.indent), marker_for(&line.kind));
            // A heading is followed by a plain line; so is a paragraph.
            let prefix = if marked { prefix } else { format!("\n{}", " ".repeat(if line.depth > 0 { line.indent } else { 0 })) };
            let at = caret + prefix.len();
            Some(Edit { range: caret..caret, replacement: prefix, selection: at..at })
        }
        Command::DeleteBackward => {
            // Just after a picture: the picture, whole.
            if collapsed && caret > line.content && !matches!(line.kind, LineKind::Code | LineKind::Fence) {
                let words = line.content..line.range.end;
                if let Some(picture) = inline::picture_before(&body[words.clone()], caret - words.start) {
                    let range = words.start + picture.start..words.start + picture.end;
                    return Some(Edit { selection: range.start..range.start, range, replacement: String::new() });
                }
            }
            if !collapsed || caret != line.content || line.content == line.range.start + line.indent {
                return None;
            }
            // The marker goes; the words stay, a plain line where they were.
            let from = line.range.start + line.indent;
            Some(Edit { range: from..line.content, replacement: String::new(), selection: from..from })
        }
        Command::Indent | Command::Outdent => {
            let lines = rows(&layout, &selection);
            let first = &layout.lines[lines.start];
            if !matches!(first.kind, LineKind::Item { .. }) {
                return None;
            }
            let shift: isize = if command == Command::Indent {
                // Under the item before, at its level: to where its words begin.
                let before = (0..lines.start).rev().map(|i| &layout.lines[i]).find(|l| l.kind != LineKind::Blank && l.indent <= first.indent)?;
                if !matches!(before.kind, LineKind::Item { .. }) || before.indent != first.indent {
                    return None;
                }
                // Its marker's width: the checkbox is not part of it.
                (before.content - before.range.start - before.indent - checkbox_width(body, before)) as isize
            } else {
                if first.indent == 0 {
                    return None;
                }
                // Out to the item it is under.
                let parent = (0..lines.start).rev().map(|i| &layout.lines[i]).find(|l| matches!(l.kind, LineKind::Item { .. }) && l.indent < first.indent);
                -((first.indent - parent.map_or(0, |parent| parent.indent)) as isize)
            };
            Some(shift_lines(body, &layout, lines, shift, selection))
        }
        Command::MoveUp | Command::MoveDown => {
            let lines = rows(&layout, &selection);
            let first = &layout.lines[lines.start];
            let (moving, other) = if command == Command::MoveUp {
                // The row before, at this level, with what is under it.
                let before = (0..lines.start).rev().find(|i| layout.lines[*i].kind != LineKind::Blank && layout.lines[*i].indent <= first.indent)?;
                if layout.lines[before].indent != first.indent {
                    return None;
                }
                (lines.clone(), before..lines.start)
            } else {
                let after = (lines.end..layout.lines.len()).find(|i| layout.lines[*i].kind != LineKind::Blank)?;
                if layout.lines[after].indent != first.indent || layout.lines[after].range.is_empty() {
                    return None;
                }
                (lines.clone(), lines.end..under(&layout, after))
            };
            let (moving_text, other_text) = (text_of(body, &layout, &moving), text_of(body, &layout, &other));
            let ended = |text: &str| if text.ends_with('\n') { text.to_owned() } else { format!("{text}\n") };
            let (a, b) = (ended(&body[moving_text.clone()]), ended(&body[other_text.clone()]));
            let whole = moving_text.start.min(other_text.start)..moving_text.end.max(other_text.end);
            let mut replacement = if command == Command::MoveUp { format!("{a}{b}") } else { format!("{b}{a}") };
            // The body's last line keeps having no line break, if it had none.
            if whole.end == body.len() && !body.ends_with('\n') {
                replacement.pop();
            }
            let moved: isize = if command == Command::MoveUp { -(b.len() as isize) } else { b.len() as isize };
            let place = |offset: usize| (offset as isize + moved) as usize;
            Some(Edit { range: whole, replacement, selection: place(selection.start)..place(selection.end) })
        }
        Command::DeleteRows => {
            let lines = rows(&layout, &selection);
            let mut range = text_of(body, &layout, &lines);
            // The last rows of a body: the line break before them goes instead.
            if range.end == body.len() && range.start > 0 && !body[range.clone()].ends_with('\n') {
                range.start -= 1;
            }
            let at = range.start.min(body.len() - (range.end - range.start));
            Some(Edit { range, replacement: String::new(), selection: at..at })
        }
        Command::DuplicateRows => {
            let lines = rows(&layout, &selection);
            let range = text_of(body, &layout, &lines);
            let text = &body[range.clone()];
            let (replacement, moved) = if text.ends_with('\n') { (text.to_owned(), text.len()) } else { (format!("\n{text}"), text.len() + 1) };
            Some(Edit { range: range.end..range.end, replacement, selection: selection.start + moved..selection.end + moved })
        }
        Command::Toggle(style) => {
            if matches!(line.kind, LineKind::Code | LineKind::Fence) || layout.line_at(selection.end) != index {
                return None;
            }
            // Asked of the line's words alone, so nothing else is read.
            let words = line.content..line.range.end;
            let (start, end) = (selection.start.max(words.start), selection.end.min(words.end).max(selection.start.max(words.start)));
            let (styled, range) = inline::toggle(&body[words.clone()], start - words.start..end - words.start, style);
            Some(Edit { range: words.clone(), replacement: styled, selection: words.start + range.start..words.start + range.end })
        }
        Command::CycleChecklist
        | Command::ToggleTask
        | Command::ToggleCheckbox
        | Command::Bullet
        | Command::Numbered
        | Command::Quote
        | Command::Heading(_) => {
            if matches!(line.kind, LineKind::Code | LineKind::Fence | LineKind::Table | LineKind::Rule) {
                return None;
            }
            let from = line.range.start + line.indent;
            let (bullet, task) = match &line.kind {
                LineKind::Item { bullet, task, ordered: None } => (Some(*bullet), *task),
                LineKind::Item { task, .. } => (None, *task),
                _ => (None, None),
            };
            let is_item = matches!(line.kind, LineKind::Item { .. });
            let dash = bullet.filter(|b| *b != '+').unwrap_or('-');
            let marker = match command {
                Command::CycleChecklist => match task {
                    None => format!("{dash} [ ] "),
                    Some(false) => format!("{} [x] ", bullet.unwrap_or('-')),
                    Some(true) => format!("{dash} "),
                },
                Command::ToggleTask => match (bullet, task) {
                    (Some('+'), Some(_)) => "- ".to_owned(),
                    _ => "+ [ ] ".to_owned(),
                },
                Command::ToggleCheckbox => match (&line.kind, task) {
                    (LineKind::Item { .. }, Some(done)) => {
                        // Only the box changes: the marker before it is kept as written.
                        let box_at = line.content - checkbox_width(body, line);
                        let mark = if done { " " } else { "x" };
                        return Some(Edit { range: box_at + 1..box_at + 2, replacement: mark.to_owned(), selection });
                    }
                    _ => return None,
                },
                Command::Bullet => {
                    if is_item && bullet.is_some() && task.is_none() {
                        String::new()
                    } else {
                        "- ".to_owned()
                    }
                }
                Command::Numbered => {
                    if matches!(line.kind, LineKind::Item { ordered: Some(_), .. }) {
                        String::new()
                    } else {
                        "1. ".to_owned()
                    }
                }
                Command::Quote => {
                    if line.kind == LineKind::Quote {
                        String::new()
                    } else {
                        "> ".to_owned()
                    }
                }
                Command::Heading(level) => {
                    if line.kind == LineKind::Heading(level) {
                        String::new()
                    } else {
                        format!("{} ", "#".repeat(level.clamp(1, 6) as usize))
                    }
                }
                _ => unreachable!("the commands matched above"),
            };
            let content = line.content.min(line.range.end).max(from);
            let moved = marker.len() as isize - (content - from) as isize;
            let place = |offset: usize| if offset <= from { offset } else { (offset.max(content) as isize + moved) as usize };
            Some(Edit { range: from..content, replacement: marker, selection: place(selection.start)..place(selection.end) })
        }
        // An outline's: text has no rows to fold, nor to carry about.
        Command::MoveToTop
        | Command::MoveToBottom
        | Command::Fold
        | Command::Unfold
        | Command::ToggleFold
        | Command::FoldCompletely
        | Command::UnfoldCompletely
        | Command::FoldAll
        | Command::UnfoldAll
        | Command::MarkDone
        | Command::MoveDoneToBottom
        | Command::Turn(_) => None,
    }
}

/// The width of an item's checkbox with the space after it.
fn checkbox_width(body: &str, line: &Line) -> usize {
    let words = &body[line.range.start + line.indent..line.range.end];
    list_marker(words).and_then(|(_, _, width)| checkbox(&words[width..])).map_or(0, |(_, length)| length)
}

/// Some lines, each indented further (or less) by so many spaces.
fn shift_lines(body: &str, layout: &Layout, lines: Range<usize>, shift: isize, selection: Range<usize>) -> Edit {
    let range = layout.lines[lines.start].range.start..layout.lines[lines.end - 1].range.end;
    let mut replacement = String::with_capacity(range.len() + lines.len() * 4);
    let place = |offset: usize, at: &mut Option<usize>, line: &Line, moved: isize, written: usize| {
        if at.is_none() && offset >= line.range.start && offset <= line.range.end {
            let within = (offset - line.range.start) as isize + moved;
            *at = Some(range.start + written + within.max(0) as usize);
        }
    };
    let (mut start, mut end) = (None, None);
    for (count, line) in layout.lines[lines.clone()].iter().enumerate() {
        if count > 0 {
            replacement.push('\n');
        }
        let text = &body[line.range.clone()];
        let moved = if line.kind == LineKind::Blank { 0 } else { shift.max(-(line.indent as isize)) };
        let written = replacement.len();
        if moved >= 0 {
            replacement.push_str(&" ".repeat(moved as usize));
            replacement.push_str(text);
        } else {
            replacement.push_str(&text[(-moved) as usize..]);
        }
        place(selection.start, &mut start, line, moved, written);
        place(selection.end, &mut end, line, moved, written);
    }
    let start = start.unwrap_or(range.start);
    Edit { range, replacement, selection: start..end.unwrap_or(start).max(start) }
}

// --- Finishing what is typed ---------------------------------------------------

/// What is being typed at the caret that an editor could finish.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompletionKind {
    /// `[[typed`: a page's name.
    Link,
    /// `![[typed`: a page to show in place.
    Embed,
    /// `#typed`: a tag.
    Tag,
    /// `@typed`: a page looked for, by its name or by what it says, to
    /// link to. What is chosen is written as a link; the `@` goes.
    Mention,
}

/// A name half-typed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Completion {
    pub kind: CompletionKind,
    /// What has been typed of it, after the `[[` or the `#`.
    pub typed: String,
    /// All of it, markup included: what choosing a name replaces.
    pub range: Range<usize>,
}

/// What is being typed at the caret that could be finished, if anything.
pub fn completion(body: &str, caret: usize) -> Option<Completion> {
    let caret = caret.min(body.len());
    let line_start = body[..caret].rfind('\n').map_or(0, |at| at + 1);
    let before = &body[line_start..caret];
    // A link not yet closed: the last `[[` with no `]]` after it.
    if let Some(open) = before.rfind("[[") {
        let typed = &before[open + 2..];
        if !typed.contains("]]") && !typed.contains('[') && !typed.contains('|') {
            let embed = before[..open].ends_with('!');
            let start = line_start + open - usize::from(embed);
            // A `]]` already after the caret is part of what is replaced.
            let end = caret + if body[caret..].starts_with("]]") { 2 } else { 0 };
            return Some(Completion { kind: if embed { CompletionKind::Embed } else { CompletionKind::Link }, typed: typed.to_owned(), range: start..end });
        }
    }
    // A page looked for: `@` starting a word, then its words — spaces and
    // all, for a name is often two — to the caret. Not in code.
    if let Some(at) = before.rfind('@') {
        let typed = &before[at + 1..];
        let starts_word = before[..at].chars().next_back().is_none_or(|c| c.is_whitespace() || c == '(');
        let is_words = typed.chars().count() <= 60
            && !typed.starts_with(' ')
            && !typed.contains("  ")
            && typed.chars().all(|c| c.is_alphanumeric() || matches!(c, ' ' | '-' | '_' | '\'' | '’' | '.' | '/'));
        if starts_word && is_words && before[..at].matches('`').count() % 2 == 0 {
            return Some(Completion { kind: CompletionKind::Mention, typed: typed.to_owned(), range: line_start + at..caret });
        }
    }
    // A tag: `#` starting a word, then letters, to the caret.
    let hash = before.rfind('#')?;
    let typed = &before[hash + 1..];
    let starts_word = before[..hash].chars().next_back().is_none_or(|c| c.is_whitespace() || c == '(');
    let is_name =
        !typed.is_empty() && typed.chars().all(|c| c.is_alphanumeric() || matches!(c, '_' | '-' | '/')) && !typed.starts_with(|c: char| c.is_ascii_digit());
    // A heading's hashes are no tag.
    let heading = before[..hash].trim().is_empty() && (typed.is_empty() || typed.starts_with('#'));
    (starts_word && is_name && !heading).then(|| Completion { kind: CompletionKind::Tag, typed: typed.to_owned(), range: line_start + hash..caret })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A body with `|` where the caret is — or two, around a selection.
    fn marked(text: &str) -> (String, Range<usize>) {
        let first = text.find('|').expect("a caret");
        let body = text.replacen('|', "", 2);
        let second = text[first + 1..].find('|').map_or(first, |at| first + at);
        (body, first..second)
    }

    /// The body after a command, with the selection marked the same way.
    fn after(text: &str, command: Command) -> Option<String> {
        let (body, selection) = marked(text);
        let edit = perform(&body, selection, command)?;
        let mut result = edit.apply(&body);
        if edit.selection.end > edit.selection.start {
            result.insert(edit.selection.end, '|');
        }
        result.insert(edit.selection.start, '|');
        Some(result)
    }

    #[test]
    fn a_page_is_looked_for_after_an_at() {
        let at = |text: &str| completion(text, text.len()).filter(|found| found.kind == CompletionKind::Mention).map(|found| (found.typed, found.range));
        assert_eq!(at("see @"), Some((String::new(), 4..5)));
        assert_eq!(at("see @acy watson"), Some(("acy watson".to_owned(), 4..15)));
        assert_eq!(at("- (@Ada"), Some(("Ada".to_owned(), 3..7)));
        // An address is no page looked for; nor is what is written in code, or after two spaces, or past a comma.
        assert_eq!(at("mail ada@example"), None);
        assert_eq!(at("`@decorator"), None);
        assert_eq!(at("@ada  and"), None);
        assert_eq!(at("@ada, and"), None);
        // A link being written is a link being written.
        assert_eq!(completion("@x [[Ad", 7).map(|found| found.kind), Some(CompletionKind::Link));
    }

    #[test]
    fn lines_know_what_they_are() {
        let body = "# Title\n\n- one\n  - [x] two\n    more of two\n1. three\n> [!TIP]\n> quoted\n\n```query\ntag: X\n```\n| a |\n---\nplain";
        let layout = layout(body);
        let kinds: Vec<_> = layout.lines.iter().map(|line| (&body[line.range.clone()], line.kind.clone(), line.depth)).collect();
        use LineKind::*;
        assert_eq!(
            kinds,
            [
                ("# Title", Heading(1), 0),
                ("", Blank, 0),
                ("- one", Item { ordered: None, task: None, bullet: '-' }, 1),
                ("  - [x] two", Item { ordered: None, task: Some(true), bullet: '-' }, 2),
                ("    more of two", Paragraph, 2),
                ("1. three", Item { ordered: Some(1), task: None, bullet: '.' }, 1),
                ("> [!TIP]", Quote, 0),
                ("> quoted", Quote, 0),
                ("", Blank, 0),
                ("```query", Fence, 0),
                ("tag: X", Code, 0),
                ("```", Fence, 0),
                ("| a |", Table, 0),
                ("---", Rule, 0),
                ("plain", Paragraph, 0),
            ]
        );
        // Where each line's words begin.
        assert_eq!(&body[layout.lines[0].content..layout.lines[0].range.end], "Title");
        assert_eq!(&body[layout.lines[3].content..layout.lines[3].range.end], "two");
        assert_eq!(&body[layout.lines[7].content..layout.lines[7].range.end], "quoted");
        assert_eq!(layout.line_at(0), 0);
        assert_eq!(layout.line_at(body.len()), 14);
    }

    #[test]
    fn runs_say_what_to_draw_and_what_to_hide() {
        let body =
            "- [ ] See **[[Ada Lovelace|Ada]]** and #person at <https://x.example> ![cat](assets/cat.png)<!-- {\"width\":40} -->\n## A `code` heading \\*";
        let layout = layout(body);
        let shown: Vec<_> = layout.runs.iter().map(|run| (&body[run.range.clone()], &run.kind)).collect();
        let has = |text: &str, kind: RunKind| assert!(shown.contains(&(text, &kind)), "{text:?} as {kind:?} in {shown:#?}");
        has("- ", RunKind::Bullet);
        has("[ ]", RunKind::Checkbox { done: false });
        has("[[Ada Lovelace|Ada]]", RunKind::Strong);
        has("Ada", RunKind::PageLink { target: "Ada Lovelace".into(), embed: false });
        has("[[Ada Lovelace|", RunKind::Markup);
        has("]]", RunKind::Markup);
        has("#person", RunKind::Tag { name: "person".into() });
        has("https://x.example", RunKind::WebLink { url: "https://x.example".into() });
        has(
            "![cat](assets/cat.png)<!-- {\"width\":40} -->",
            RunKind::Image { source: "assets/cat.png".into(), alt: "cat".into(), width: Some(40.0), height: None },
        );
        has("## ", RunKind::Markup);
        has("code", RunKind::Code);
        has("\\", RunKind::Markup);
        // Code is not read for markup.
        assert!(super::layout("```\n**not bold** [[not a link]]\n```").runs.is_empty());
    }

    #[test]
    fn return_makes_a_line_of_the_same_sort() {
        assert_eq!(after("- one|", Command::Newline).unwrap(), "- one\n- |");
        assert_eq!(after("- on|e", Command::Newline).unwrap(), "- on\n- |e");
        assert_eq!(after("  * [x] done|", Command::Newline).unwrap(), "  * [x] done\n  * [ ] |");
        assert_eq!(after("+ [ ] task|", Command::Newline).unwrap(), "+ [ ] task\n+ [ ] |");
        assert_eq!(after("9. nine|", Command::Newline).unwrap(), "9. nine\n10. |");
        assert_eq!(after("> quoted|", Command::Newline).unwrap(), "> quoted\n> |");
        assert_eq!(after("# Title|", Command::Newline).unwrap(), "# Title\n|");
        assert_eq!(after("plain|", Command::Newline).unwrap(), "plain\n|");
        // A line continuing an item keeps the item's indentation.
        assert_eq!(after("- one\n  more|", Command::Newline).unwrap(), "- one\n  more\n  |");
        // On an item with nothing written: out a level, then plain.
        assert_eq!(after("- one\n  - |", Command::Newline).unwrap(), "- one\n- |");
        assert_eq!(after("- one\n- |", Command::Newline).unwrap(), "- one\n|");
        assert_eq!(after("> |", Command::Newline).unwrap(), "|");
        // In code, and with a selection, the text view's own Return.
        assert_eq!(after("```\ncode|\n```", Command::Newline), None);
        assert_eq!(after("- |one|", Command::Newline), None);
    }

    #[test]
    fn delete_at_the_start_of_an_items_words_takes_its_marker() {
        assert_eq!(after("- |one", Command::DeleteBackward).unwrap(), "|one");
        assert_eq!(after("  + [ ] |task", Command::DeleteBackward).unwrap(), "  |task");
        assert_eq!(after("## |Title", Command::DeleteBackward).unwrap(), "|Title");
        assert_eq!(after("- o|ne", Command::DeleteBackward), None);
        assert_eq!(after("|plain", Command::DeleteBackward), None);
    }

    #[test]
    fn delete_after_a_picture_takes_the_whole_picture() {
        assert_eq!(after("- see ![cat](assets/cat.png)| there", Command::DeleteBackward).unwrap(), "- see | there");
        assert_eq!(after("![](a.png) ![](b.png)<!-- {\"width\":40} -->|", Command::DeleteBackward).unwrap(), "![](a.png) |");
        // The size, written a space after, goes with it.
        assert_eq!(after("![](a.png) <!-- {\"width\":40,\"height\":30} -->|", Command::DeleteBackward).unwrap(), "|");
        // Inside its markup, and after any other comment, a character is deleted as ever.
        assert_eq!(after("![](a.p|ng)", Command::DeleteBackward), None);
        assert_eq!(after("word <!-- note -->|", Command::DeleteBackward), None);
        assert_eq!(after("```\n![](a.png)|\n```", Command::DeleteBackward), None);
    }

    #[test]
    fn rows_are_indented_with_what_is_under_them() {
        assert_eq!(after("- one\n- t|wo\n  - three\n- four", Command::Indent).unwrap(), "- one\n  - t|wo\n    - three\n- four");
        assert_eq!(after("- one\n  - t|wo\n    - three\n- four", Command::Outdent).unwrap(), "- one\n- t|wo\n  - three\n- four");
        // Under an item written with a wider marker: to where its words begin.
        assert_eq!(after("*   one\n*   t|wo", Command::Indent).unwrap(), "*   one\n    *   t|wo");
        assert_eq!(after("1. one\n2. t|wo", Command::Indent).unwrap(), "1. one\n   2. t|wo");
        assert_eq!(after("+ [ ] one\n+ [ ] t|wo", Command::Indent).unwrap(), "+ [ ] one\n  + [ ] t|wo");
        // Several rows at once, the selection kept on the same words.
        assert_eq!(after("- one\n- |two\n- thr|ee", Command::Indent).unwrap(), "- one\n  - |two\n  - thr|ee");
        // The first item has nothing to go under; a top-level one nowhere to go out to.
        assert_eq!(after("- o|ne\n- two", Command::Indent), None);
        assert_eq!(after("- o|ne", Command::Outdent), None);
        assert_eq!(after("pla|in", Command::Indent), None);
    }

    #[test]
    fn rows_move_past_their_siblings_with_what_is_under_them() {
        assert_eq!(after("- one\n- t|wo\n  - under two\n- three\n", Command::MoveUp).unwrap(), "- t|wo\n  - under two\n- one\n- three\n");
        assert_eq!(after("- one\n  - under one\n- t|wo\n- three\n", Command::MoveUp).unwrap(), "- t|wo\n- one\n  - under one\n- three\n");
        assert_eq!(
            after("- o|ne\n  - under one\n- two\n  - under two\n- three", Command::MoveDown).unwrap(),
            "- two\n  - under two\n- o|ne\n  - under one\n- three"
        );
        // To the very end of a body with no line break there.
        assert_eq!(after("- o|ne\n- two", Command::MoveDown).unwrap(), "- two\n- o|ne");
        assert_eq!(after("- one\n- t|wo", Command::MoveUp).unwrap(), "- t|wo\n- one");
        // Not out of the item they are in; not past the ends.
        assert_eq!(after("- one\n  - t|wo", Command::MoveUp), None);
        assert_eq!(after("- o|ne", Command::MoveUp), None);
        assert_eq!(after("- one\n- t|wo", Command::MoveDown), None);
        // A paragraph is a row too.
        assert_eq!(after("first\nsec|ond\n", Command::MoveUp).unwrap(), "sec|ond\nfirst\n");
    }

    #[test]
    fn rows_are_deleted_and_duplicated_whole() {
        assert_eq!(after("- one\n- t|wo\n  - under\n- three", Command::DeleteRows).unwrap(), "- one\n|- three");
        assert_eq!(after("- one\n- t|wo", Command::DeleteRows).unwrap(), "- one|");
        assert_eq!(after("on|ly", Command::DeleteRows).unwrap(), "|");
        assert_eq!(after("- o|ne\n  - under\n- two", Command::DuplicateRows).unwrap(), "- one\n  - under\n- o|ne\n  - under\n- two");
        assert_eq!(after("- one\n- t|wo", Command::DuplicateRows).unwrap(), "- one\n- two\n- t|wo");
    }

    #[test]
    fn a_line_is_made_a_checklist_item_checked_and_plain_again() {
        assert_eq!(after("pla|in", Command::CycleChecklist).unwrap(), "- [ ] pla|in");
        assert_eq!(after("- it|em", Command::CycleChecklist).unwrap(), "- [ ] it|em");
        assert_eq!(after("  * [ ] it|em", Command::CycleChecklist).unwrap(), "  * [x] it|em");
        assert_eq!(after("- [x] it|em", Command::CycleChecklist).unwrap(), "- it|em");
        // A task, as Prism writes them; and back.
        assert_eq!(after("- it|em", Command::ToggleTask).unwrap(), "+ [ ] it|em");
        assert_eq!(after("pla|in", Command::ToggleTask).unwrap(), "+ [ ] pla|in");
        assert_eq!(after("+ [x] it|em", Command::ToggleTask).unwrap(), "- it|em");
        // A click on the box changes the box alone, wherever the caret is.
        assert_eq!(after("  +   [ ] it|em", Command::ToggleCheckbox).unwrap(), "  +   [x] it|em");
        assert_eq!(after("|- [X] item", Command::ToggleCheckbox).unwrap(), "|- [ ] item");
        assert_eq!(after("- it|em", Command::ToggleCheckbox), None);
    }

    #[test]
    fn a_line_is_made_a_heading_a_bullet_a_quote_and_plain_again() {
        assert_eq!(after("Tit|le", Command::Heading(2)).unwrap(), "## Tit|le");
        assert_eq!(after("## Tit|le", Command::Heading(2)).unwrap(), "Tit|le");
        assert_eq!(after("## Tit|le", Command::Heading(1)).unwrap(), "# Tit|le");
        assert_eq!(after("- it|em", Command::Heading(1)).unwrap(), "# it|em");
        assert_eq!(after("pla|in", Command::Bullet).unwrap(), "- pla|in");
        assert_eq!(after("- pla|in", Command::Bullet).unwrap(), "pla|in");
        assert_eq!(after("pla|in", Command::Numbered).unwrap(), "1. pla|in");
        assert_eq!(after("pla|in", Command::Quote).unwrap(), "> pla|in");
        assert_eq!(after("> pla|in", Command::Quote).unwrap(), "pla|in");
        assert_eq!(after("```\nco|de\n```", Command::Bullet), None);
    }

    #[test]
    fn a_selection_is_emboldened_within_its_line() {
        assert_eq!(after("- say |this| now", Command::Toggle(Style::Strong)).unwrap(), "- say **|this|** now");
        assert_eq!(after("- say **|this|** now", Command::Toggle(Style::Strong)).unwrap(), "- say |this| now");
        assert!(after("say |this", Command::Toggle(Style::Emphasis)).is_some());
        assert_eq!(after("on|e\ntw|o", Command::Toggle(Style::Strong)), None, "not across lines");
    }

    #[test]
    fn what_is_half_typed_can_be_finished() {
        let at = |text: &str| {
            let (body, selection) = marked(text);
            completion(&body, selection.start).map(|c| (c.kind, c.typed, body[c.range].to_owned()))
        };
        assert_eq!(at("see [[Ada Lo|"), Some((CompletionKind::Link, "Ada Lo".into(), "[[Ada Lo".into())));
        assert_eq!(at("see [[Ada Lo|]] and"), Some((CompletionKind::Link, "Ada Lo".into(), "[[Ada Lo]]".into())));
        assert_eq!(at("![[Eng|"), Some((CompletionKind::Embed, "Eng".into(), "![[Eng".into())));
        assert_eq!(at("[[|"), Some((CompletionKind::Link, String::new(), "[[".into())));
        assert_eq!(at("[[Done]] and |"), None);
        assert_eq!(at("a #per|"), Some((CompletionKind::Tag, "per".into(), "#per".into())));
        assert_eq!(at("(#work/de|"), Some((CompletionKind::Tag, "work/de".into(), "#work/de".into())));
        assert_eq!(at("a#b|"), None);
        assert_eq!(at("#|"), None);
        assert_eq!(at("## Head|"), None);
        assert_eq!(at("#1|"), None);
        // Only the caret's own line is read.
        assert_eq!(at("[[open\nnext|"), None);
    }

    #[test]
    fn an_edit_touches_only_what_it_says() {
        let (body, selection) = marked("# Title\n\n*   one\n*   t|wo\n\ntail  \n");
        let edit = perform(&body, selection, Command::Indent).unwrap();
        assert_eq!(&body[edit.range.clone()], "*   two");
        assert_eq!(edit.apply(&body), "# Title\n\n*   one\n    *   two\n\ntail  \n");
    }
}
