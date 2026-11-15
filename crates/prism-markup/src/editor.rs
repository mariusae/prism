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
    let mut layout = Layout { lines: Vec::new(), runs: Vec::new() };
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
    /// Shown as the card of what it links to, or — being shown so — as
    /// its words again. Only a row that is a link alone is drawn as one.
    ToggleCard,
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
    /// ⌘↩: a new, empty row after the row's branch, not splitting it.
    InsertBelow,
    /// ⇧⌘↩: a new, empty row before the row.
    InsertAbove,
    /// ⌥⌘↩: a new, empty first child of the row.
    InsertChild,
    /// ⌃⌥⌘↑: the rows above the sibling before them, at their level.
    MoveUpKeepingLevel,
    MoveDownKeepingLevel,
    /// ⌃⌘⌫: the row after joined into the row, a space between.
    JoinRows,
    /// ⌃⌥⇧←: the row's children made the siblings after it.
    PromoteChildren,
    /// ⌃⌥⇧→: the siblings after the row made its children.
    DemoteSiblings,
    /// ⌥⌘G: the rows put under a new, empty row.
    Group,
    /// ⌃⌥K: the row taken out, its children taking its place.
    DeleteRowOnly,
    /// ⌃⌥→: the row a level deeper, its children staying where they are.
    IndentRowOnly,
    /// ⌃⌥←: the row a level out, the siblings after it coming under it.
    OutdentRowOnly,
    /// ⌥⌘9: within each row's branch, the deepest level shown folded.
    FoldByLevel,
    /// ⌥⌘0: within each row's branch, the shallowest level folded shown.
    UnfoldByLevel,
    /// ⌃⌥⌘9 / ⌃⌥⌘0: the same, over the whole note.
    FoldAllByLevel,
    UnfoldAllByLevel,
    /// ⌃⌥↑ ⌃⌥↓: the row alone a line up or down, keeping its level.
    MoveUpRowOnly,
    MoveDownRowOnly,
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
    fn what_is_half_typed_can_be_finished() {
        let at = |text: &str| {
            let caret = text.find('|').expect("a caret");
            let body = text.replacen('|', "", 1);
            completion(&body, caret).map(|c| (c.kind, c.typed, body[c.range].to_owned()))
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
}
