//! The block tree: a note's body as editors hold it.
//!
//! A [`Document`] is a tree of [`Block`]s. Markdown's lists are its
//! nesting: a list item is a block, and what sits inside it — its sublist,
//! a paragraph after a blank line, a code block — is its children. Anything
//! else (a heading, a paragraph, a quote, a table) is a block wherever it
//! stands. This one tree serves both ways of editing:
//!
//! - an **outline** editor walks it as rows at depths ([`Document::rows`])
//!   and restructures it with [`crate::outline`];
//! - a **prose** editor walks the top-level blocks in order.
//!
//! A block's inline content — emphasis, links, tags — stays in its
//! [`text`](Block::text) as the Markdown it was written in; [`crate::inline`]
//! finds the spans in it. Text with ranges over it is what a text view
//! edits, and keeping the source is what keeps every byte.
//!
//! # Losslessness
//!
//! Reading a body and writing it back unchanged gives the same bytes, for
//! **every** input. Two things make that so:
//!
//! 1. Each block keeps the small facts of how it was written — which
//!    bullet, how many spaces, the blank lines before it ([`Layout`]) — and
//!    the writer follows them.
//! 2. Whatever part of a body would still not write back as it was read
//!    (tabs used as indentation, shapes this reader does not know) is kept
//!    whole as a [`BlockKind::Raw`] block: opaque, but never lost. This is
//!    checked at parse time, top-level block by top-level block, so one odd
//!    construct costs only itself.
//!
//! An edited or new block is written canonically.

/// How a document's lines end.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LineEnding {
    #[default]
    Lf,
    CrLf,
}

/// A note's body.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Document {
    /// The top-level blocks, in order.
    pub blocks: Vec<Block>,
    /// Blank lines after the last block, as written.
    pub trailing_blank: Vec<String>,
    /// Whether the last line ends in a line break.
    pub final_newline: bool,
    pub line_ending: LineEnding,
}

/// What a block is. The block's [`text`](Block::text) means what its kind
/// says it means.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlockKind {
    /// Text that is nothing else. `text` is its lines.
    Paragraph,
    /// `## text`; the level is 1 to 6. `text` is what follows the hashes.
    Heading(u8),
    /// A list item: `- text`, `1. text`, `+ [ ] text`. The only kind that
    /// has children.
    Item(Item),
    /// `> text`. `text` is the quoted lines without their `>`; see
    /// [`Block::callout`].
    Quote,
    /// A fenced code block. `text` is all of it, fences included; see
    /// [`Block::code`].
    Code,
    /// A pipe table. `text` is its lines; see [`crate::table`].
    Table,
    /// `---`, `***` or `___`. `text` is the rule as written.
    Rule,
    /// Lines kept exactly as they were, blank ones included, because they
    /// would not otherwise write back as read. Shown as plain text.
    Raw,
}

/// A list item's marker and checkbox.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Item {
    pub marker: Marker,
    pub task: Option<Task>,
}

/// What a list item starts with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Marker {
    /// `-`, `*` or `+`.
    Bullet(char),
    /// `1.` or `1)`: the number, and the delimiter after it.
    Ordered { number: u32, delimiter: char },
}

impl Marker {
    fn width(self) -> usize {
        match self {
            Marker::Bullet(_) => 1,
            Marker::Ordered { number, .. } => number.to_string().len() + 1,
        }
    }
}

/// A checkbox on a list item.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Task {
    Open,
    /// Done, with the letter it was checked with: `x` or `X`.
    Done(char),
}

impl Task {
    pub fn is_done(self) -> bool {
        matches!(self, Task::Done(_))
    }
}

/// How a block was written, beyond what it says: the facts the writer
/// needs to give back the same bytes. A new block's default layout writes
/// canonical Markdown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Layout {
    /// The blank lines before the block, as written.
    pub gap: Vec<String>,
    /// Spaces between the marker (or the hashes, or `>`) and the text.
    pub spacing: usize,
    /// Spaces of indentation beyond what the block's depth asks for.
    pub extra_indent: usize,
    /// How each line after the first was indented, when not the usual;
    /// `None` is the usual. See [`QUOTE_BARE`].
    continuation: Option<Vec<Option<isize>>>,
}

/// Among a quote's continuation facts: a line written `>` with no space.
const QUOTE_BARE: isize = -1;

impl Default for Layout {
    fn default() -> Self {
        Layout { gap: Vec::new(), spacing: 1, extra_indent: 0, continuation: None }
    }
}

/// One block of a document, with the blocks nested in it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Block {
    pub kind: BlockKind,
    /// The block's content, as Markdown, without its marker. Lines after
    /// the first are joined with `\n`, without the indentation that places
    /// them in the tree.
    pub text: String,
    /// The blocks inside this one. Only a list item's are written nested;
    /// Markdown has no other way to nest.
    pub children: Vec<Block>,
    pub layout: Layout,
    /// Whether an outline shows the block without what is under it. Not
    /// part of the note: never written, and never set by reading — it is
    /// an editing [`Session`](crate::Session)'s, which keeps it here so
    /// that a block moved takes its fold with it.
    pub folded: bool,
    /// What the block is known by, if it was given a name of its own: a
    /// few letters, written after its first line as a comment
    /// (`<!-- ^k3f9 -->`). Like `folded` it is an editing
    /// [`Session`](crate::Session)'s to read and write; held here so
    /// that a block moved, or written in, keeps its name.
    pub anchor: Option<String>,
}

/// A fenced code block's parts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Code<'a> {
    /// What follows the opening fence: `rust`, `query`.
    pub info: &'a str,
    /// The lines between the fences.
    pub body: &'a str,
}

/// A callout, as GitHub writes them: a quote whose first line is `[!TIP]`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Callout<'a> {
    /// The kind, as written: `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, `CAUTION`.
    pub kind: &'a str,
    /// The quoted text after the first line.
    pub body: &'a str,
}

impl Block {
    pub fn new(kind: BlockKind, text: impl Into<String>) -> Block {
        Block { kind, text: text.into(), children: Vec::new(), layout: Layout::default(), folded: false, anchor: None }
    }

    pub fn paragraph(text: impl Into<String>) -> Block {
        Block::new(BlockKind::Paragraph, text)
    }

    /// A heading; the level is held to 1–6.
    pub fn heading(level: u8, text: impl Into<String>) -> Block {
        Block::new(BlockKind::Heading(level.clamp(1, 6)), text)
    }

    /// `- text`.
    pub fn bullet(text: impl Into<String>) -> Block {
        Block::new(BlockKind::Item(Item { marker: Marker::Bullet('-'), task: None }), text)
    }

    /// `+ [ ] text`: a task, as Prism writes them.
    pub fn task(text: impl Into<String>) -> Block {
        Block::new(BlockKind::Item(Item { marker: Marker::Bullet('+'), task: Some(Task::Open) }), text)
    }

    /// `1. text`.
    pub fn ordered(number: u32, text: impl Into<String>) -> Block {
        Block::new(BlockKind::Item(Item { marker: Marker::Ordered { number, delimiter: '.' }, task: None }), text)
    }

    pub fn quote(text: impl Into<String>) -> Block {
        Block::new(BlockKind::Quote, text)
    }

    /// A fenced code block. The fence is made long enough to hold a body
    /// with fences of its own.
    pub fn code(info: &str, body: &str) -> Block {
        let longest = body.lines().map(|l| l.trim_start().chars().take_while(|c| *c == '`').count()).max().unwrap_or(0);
        let fence = "`".repeat(longest.max(2) + 1);
        let newline = if body.is_empty() || body.ends_with('\n') { "" } else { "\n" };
        Block::new(BlockKind::Code, format!("{fence}{info}\n{body}{newline}{fence}"))
    }

    pub fn rule() -> Block {
        Block::new(BlockKind::Rule, "---")
    }

    pub fn with_children(mut self, children: Vec<Block>) -> Block {
        self.children = children;
        self
    }

    /// The item's marker and checkbox, when the block is a list item.
    pub fn item(&self) -> Option<&Item> {
        match &self.kind {
            BlockKind::Item(item) => Some(item),
            _ => None,
        }
    }

    pub fn item_mut(&mut self) -> Option<&mut Item> {
        match &mut self.kind {
            BlockKind::Item(item) => Some(item),
            _ => None,
        }
    }

    pub fn is_item(&self) -> bool {
        matches!(self.kind, BlockKind::Item(_))
    }

    /// The checkbox, when the block is a list item with one.
    pub fn task_state(&self) -> Option<Task> {
        self.item().and_then(|i| i.task)
    }

    /// Whether Markdown can nest blocks under this one: only a list item.
    pub fn can_have_children(&self) -> bool {
        self.is_item()
    }

    /// Whether Return in the block's words makes two blocks of it: a
    /// paragraph, a heading, a list item, a quote. In any other — code, a
    /// table — a line break stays inside it.
    pub fn splits(&self) -> bool {
        matches!(self.kind, BlockKind::Paragraph | BlockKind::Heading(_) | BlockKind::Item(_) | BlockKind::Quote)
    }

    /// Whether the block has inline Markdown in its text: emphasis, links,
    /// tags. Code, tables' pipes, rules and raw lines are not.
    pub fn has_inline_content(&self) -> bool {
        matches!(self.kind, BlockKind::Paragraph | BlockKind::Heading(_) | BlockKind::Item(_) | BlockKind::Quote | BlockKind::Table)
    }

    /// A code block's info string and body.
    pub fn code_parts(&self) -> Option<Code<'_>> {
        if self.kind != BlockKind::Code {
            return None;
        }
        let (first, rest) = self.text.split_once('\n').unwrap_or((&self.text, ""));
        let fence_len = first.chars().take_while(|c| *c == '`' || *c == '~').count();
        let fence = &first[..fence_len];
        let info = first[fence_len..].trim();
        // The closing fence, when the block was closed.
        let body = match rest.rsplit_once('\n') {
            Some((body, last)) if is_closing_fence(last, fence) => body,
            None if is_closing_fence(rest, fence) => "",
            _ => rest,
        };
        Some(Code { info, body })
    }

    /// The callout a quote is, when its first line is `[!KIND]`.
    pub fn callout(&self) -> Option<Callout<'_>> {
        if self.kind != BlockKind::Quote {
            return None;
        }
        let (first, body) = self.text.split_once('\n').unwrap_or((&self.text, ""));
        let kind = first.trim().strip_prefix("[!")?.strip_suffix(']')?;
        (!kind.is_empty() && kind.chars().all(|c| c.is_ascii_alphabetic())).then_some(Callout { kind, body })
    }

    /// This block and every block under it, depth first.
    pub fn walk(&self) -> impl Iterator<Item = &Block> {
        let mut stack = vec![self];
        std::iter::from_fn(move || {
            let block = stack.pop()?;
            stack.extend(block.children.iter().rev());
            Some(block)
        })
    }
}

fn is_closing_fence(line: &str, fence: &str) -> bool {
    let trimmed = line.trim();
    !fence.is_empty() && trimmed.starts_with(fence) && trimmed.chars().all(|c| fence.starts_with(c))
}

/// A block as an outline shows it: where it is, and how deep.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row<'a> {
    /// The block's place: an index at each level, outermost first.
    pub path: Vec<usize>,
    /// How many list items it is nested in.
    pub depth: usize,
    pub block: &'a Block,
}

impl Document {
    /// Reads a note's body. Never fails: what is not understood is kept
    /// as [`BlockKind::Raw`].
    pub fn parse(source: &str) -> Document {
        parse(source)
    }

    /// Writes the body as Markdown.
    pub fn to_markdown(&self) -> String {
        let mut rows = Vec::new();
        flatten(&self.blocks, 0, &mut rows);
        write(&rows, &self.trailing_blank, self.final_newline, self.line_ending)
    }

    /// An empty document, as a new note starts.
    pub fn new() -> Document {
        Document { final_newline: true, ..Document::default() }
    }

    /// Every block as a row, in reading order: the outline.
    pub fn rows(&self) -> Vec<Row<'_>> {
        fn visit<'a>(blocks: &'a [Block], path: &mut Vec<usize>, out: &mut Vec<Row<'a>>) {
            for (index, block) in blocks.iter().enumerate() {
                path.push(index);
                out.push(Row { path: path.clone(), depth: path.len() - 1, block });
                visit(&block.children, path, out);
                path.pop();
            }
        }
        let mut out = Vec::new();
        visit(&self.blocks, &mut Vec::new(), &mut out);
        out
    }

    /// Every block, depth first.
    pub fn walk(&self) -> impl Iterator<Item = &Block> {
        self.blocks.iter().flat_map(Block::walk)
    }

    /// The block at a path, if there is one.
    pub fn get(&self, path: &[usize]) -> Option<&Block> {
        let (first, rest) = path.split_first()?;
        rest.iter().try_fold(self.blocks.get(*first)?, |block, index| block.children.get(*index))
    }

    pub fn get_mut(&mut self, path: &[usize]) -> Option<&mut Block> {
        let (first, rest) = path.split_first()?;
        rest.iter().try_fold(self.blocks.get_mut(*first)?, |block, index| block.children.get_mut(*index))
    }

    /// Finds a block again after the document changed around it: the
    /// block that `fits` at `hint`, or else the one that fits nearest to
    /// where `hint` would be, in reading order — one as deep as `hint`
    /// before any other.
    ///
    /// A block's path is its place, not its name — an index hands out
    /// paths as they were in the tree it read, and a line added above
    /// moves every one. Whoever holds such a path holds, with it,
    /// something to know the block by (its text); this is how the two
    /// find the block as it is now.
    pub fn locate_where(&self, hint: &[usize], fits: impl Fn(&Block) -> bool) -> Option<Vec<usize>> {
        if self.get(hint).is_some_and(&fits) {
            return Some(hint.to_vec());
        }
        let rows = self.rows();
        // Where the hint would stand among the rows as they are now.
        let stand = rows.iter().filter(|row| row.path.as_slice() < hint).count();
        rows.iter()
            .enumerate()
            .filter(|(_, row)| fits(row.block))
            .min_by_key(|(at, row)| (row.path.len() != hint.len(), at.abs_diff(stand)))
            .map(|(_, row)| row.path.clone())
    }

    /// Finds the block with this text: at `hint`, or nearest to it. See
    /// [`locate_where`](Self::locate_where).
    pub fn locate(&self, hint: &[usize], text: &str) -> Option<Vec<usize>> {
        self.locate_where(hint, |block| block.text == text)
    }

    /// The list a path's block is in: the document's own blocks for a path
    /// of one, else its parent's children.
    pub fn siblings_mut(&mut self, path: &[usize]) -> Option<&mut Vec<Block>> {
        match path.split_last()? {
            (_, []) => Some(&mut self.blocks),
            (_, parent) => self.get_mut(parent).map(|b| &mut b.children),
        }
    }

    /// Whether nothing is written: no blocks, or only empty bullets — how
    /// an untouched day looks.
    pub fn is_blank(&self) -> bool {
        self.walk().all(|b| matches!(b.kind, BlockKind::Item(Item { task: None, .. }) | BlockKind::Paragraph) && b.text.trim().is_empty())
    }
}

// --- Flat rows -------------------------------------------------------------
//
// The reader and the writer both work on a flat run of rows, each at a
// depth: Markdown is read a line at a time, and a line knows its
// indentation, not its parent.

#[derive(Debug, Clone)]
struct FlatRow {
    depth: usize,
    block: Block,
    /// The line of the body the row starts at, its gap included.
    start_line: usize,
}

fn flatten<'a>(blocks: &'a [Block], depth: usize, out: &mut Vec<(usize, &'a Block)>) {
    for block in blocks {
        out.push((depth, block));
        flatten(&block.children, depth + 1, out);
    }
}

/// Rows at depths, made a tree: a row's children are the deeper rows that
/// follow it.
fn build_tree(rows: Vec<FlatRow>) -> Vec<Block> {
    // A stack of open ancestors; `stack[d]` collects the blocks at depth d.
    let mut stack: Vec<Vec<Block>> = vec![Vec::new()];
    fn close(stack: &mut Vec<Vec<Block>>, to: usize) {
        while stack.len() > to + 1 {
            let children = stack.pop().unwrap_or_default();
            if let Some(parent) = stack.last_mut().and_then(|level| level.last_mut()) {
                parent.children = children;
            }
        }
    }
    for row in rows {
        // A row cannot be deeper than one below the row before it.
        let depth = row.depth.min(stack.len() - 1 + usize::from(stack.last().is_some_and(|l| !l.is_empty())));
        close(&mut stack, depth);
        while stack.len() < depth + 1 {
            stack.push(Vec::new());
        }
        stack[depth].push(row.block);
    }
    close(&mut stack, 0);
    stack.pop().unwrap_or_default()
}

// --- Reading ---------------------------------------------------------------

fn parse(source: &str) -> Document {
    // `\r\n` throughout is a Windows note; a stray `\r` is just a character.
    let crlf = source.contains("\r\n") && !source.replace("\r\n", "").contains('\n');
    let normalized;
    let body = if crlf {
        normalized = source.replace("\r\n", "\n");
        normalized.as_str()
    } else {
        source
    };
    let mut document = Document { final_newline: true, line_ending: if crlf { LineEnding::CrLf } else { LineEnding::Lf }, ..Document::default() };
    if body.is_empty() {
        return document;
    }
    let mut lines: Vec<&str> = body.split('\n').collect();
    if lines.last() == Some(&"") {
        lines.pop();
    } else {
        document.final_newline = false;
    }

    let mut parser = Parser::default();
    for (index, line) in lines.iter().enumerate() {
        parser.read(line, lines.get(index + 1).copied(), index);
    }
    let rows = parser.rows;
    document.trailing_blank = parser.pending_gap.iter().map(|l| (*l).to_owned()).collect();
    let content_end = lines.len() - document.trailing_blank.len();

    // Whatever would not be written back as it was read is kept raw, one
    // top-level block (with all that is nested in it) at a time.
    let mut starts: Vec<usize> = (0..rows.len()).filter(|&i| rows[i].depth == 0).collect();
    starts.push(rows.len());
    // Each chunk: how many rows it has, the lines it covers, and whether
    // those rows write back as those lines.
    let chunks: Vec<(usize, std::ops::Range<usize>, bool)> = starts
        .windows(2)
        .map(|bounds| {
            let (start, end) = (bounds[0], bounds[1]);
            let covered = rows[start].start_line..rows.get(end).map_or(content_end, |r| r.start_line);
            let chunk: Vec<(usize, &Block)> = rows[start..end].iter().map(|r| (r.depth, &r.block)).collect();
            let faithful = write(&chunk, &[], false, LineEnding::Lf) == lines[covered.clone()].join("\n");
            (end - start, covered, faithful)
        })
        .collect();
    let mut checked: Vec<FlatRow> = Vec::with_capacity(rows.len());
    let mut rows = rows.into_iter();
    for (count, covered, faithful) in chunks {
        let taken = rows.by_ref().take(count);
        if faithful {
            checked.extend(taken);
        } else {
            taken.for_each(drop);
            checked.push(FlatRow { depth: 0, block: raw(&lines[covered.clone()]), start_line: covered.start });
        }
    }
    document.blocks = build_tree(checked);

    // The last line of defence: a body that still does not round-trip is
    // one raw block.
    let normalized_back = write_document_lf(&document);
    if normalized_back != body {
        document.blocks = vec![raw(&lines[..content_end])];
    }
    document
}

fn write_document_lf(document: &Document) -> String {
    let mut rows = Vec::new();
    flatten(&document.blocks, 0, &mut rows);
    write(&rows, &document.trailing_blank, document.final_newline, LineEnding::Lf)
}

fn raw(lines: &[&str]) -> Block {
    Block::new(BlockKind::Raw, lines.join("\n"))
}

#[derive(Default)]
struct Parser<'a> {
    rows: Vec<FlatRow>,
    pending_gap: Vec<&'a str>,
    /// The content column of each open list item, outermost first.
    open: Vec<usize>,
    /// The fence that opened the code block being read.
    fence: Option<String>,
    /// The column the last row's continuation lines are measured from.
    last_content_column: usize,
    /// How many lines the last row's text takes.
    last_line_count: usize,
}

impl<'a> Parser<'a> {
    fn read(&mut self, line: &'a str, next: Option<&str>, index: usize) {
        if let Some(fence) = self.fence.clone() {
            return self.read_fenced(line, &fence, next, index);
        }
        if is_blank(line) {
            self.pending_gap.push(line);
            return;
        }
        let indent = indentation(line);
        let content = line.trim_start_matches([' ', '\t']);
        if self.pending_gap.is_empty() {
            if let Some(last) = self.rows.last() {
                // `>` straight after a quote, where it starts: its next line.
                if last.block.kind == BlockKind::Quote && content.starts_with('>') && indent == self.last_content_column {
                    return self.append_quote_line(content);
                }
                // A line straight after text, that starts nothing new, goes
                // on with that text — even when not indented to match.
                if continues(&last.block) && !starts_block(content, indent >= self.last_content_column) {
                    return self.append_continuation(line, indent);
                }
            }
        }
        while self.open.last().is_some_and(|column| indent < *column) {
            self.open.pop();
        }
        let depth = self.open.len();
        let base = self.open.last().copied().unwrap_or(0);
        let gap = std::mem::take(&mut self.pending_gap);
        let start_line = index - gap.len();
        let mut block = Block::paragraph("");
        block.layout.gap = gap.iter().map(|l| (*l).to_owned()).collect();
        block.layout.extra_indent = indent - base;
        self.last_content_column = indent;

        if let Some(item) = list_item(content) {
            block.kind = BlockKind::Item(Item { marker: item.marker, task: item.task });
            block.layout.spacing = item.spacing;
            block.text = item.text.to_owned();
            let column = indent + item.marker.width() + item.spacing.max(1);
            self.open.push(column);
            self.last_content_column = column;
        } else if let Some((level, spacing, text)) = heading(content) {
            block.kind = BlockKind::Heading(level);
            block.layout.spacing = spacing;
            block.text = text.to_owned();
        } else if let Some(marker) = fence_marker(content) {
            block.kind = BlockKind::Code;
            block.text = content.to_owned();
            self.fence = Some(marker.to_owned());
        } else if is_rule(content) {
            block.kind = BlockKind::Rule;
            block.text = content.to_owned();
        } else if let Some(rest) = content.strip_prefix('>') {
            block.kind = BlockKind::Quote;
            block.layout.spacing = usize::from(rest.starts_with(' '));
            block.text = rest[block.layout.spacing..].to_owned();
        } else {
            if content.starts_with('|') && next.is_some_and(crate::table::is_separator) {
                block.kind = BlockKind::Table;
            }
            block.text = content.to_owned();
        }
        self.rows.push(FlatRow { depth, block, start_line });
        self.last_line_count = 1;
    }

    fn read_fenced(&mut self, line: &'a str, fence: &str, next: Option<&str>, index: usize) {
        let indent = indentation(line);
        let content = line.trim_start_matches(' ');
        // A fence inside a list item is indented with it; a line indented
        // less has ended the block with the item.
        if !line.is_empty() && indent < self.last_content_column && !content.starts_with(fence) {
            self.fence = None;
            return self.read(line, next, index);
        }
        self.append_continuation(line, indent);
        let trimmed = content.trim();
        if trimmed.starts_with(fence) && trimmed.chars().all(|c| fence.starts_with(c)) {
            self.fence = None;
        }
    }

    /// A quote's next line, written with its `>`: in the text without it.
    fn append_quote_line(&mut self, content: &str) {
        let rest = &content[1..];
        match rest.strip_prefix(' ') {
            Some(text) => self.append_line(text, None),
            None => self.append_line(rest, Some(QUOTE_BARE)),
        }
    }

    fn append_continuation(&mut self, line: &str, indent: usize) {
        if is_blank(line) {
            // A blank line inside a block is kept as it was, spaces and all.
            return self.append_line(line, if line.is_empty() { None } else { Some(0) });
        }
        let strip = indent.min(self.last_content_column);
        let is_quote = self.rows.last().is_some_and(|r| r.block.kind == BlockKind::Quote);
        // Indented less than usual (a lazy continuation) is recorded; more
        // than usual keeps the extra in the text. A quote's line without
        // its `>` is always recorded: its usual has one.
        let fact = (indent < self.last_content_column || is_quote).then_some(strip as isize);
        self.append_line(&line[prefix_len(line, strip)..], fact);
    }

    fn append_line(&mut self, line: &str, fact: Option<isize>) {
        let count = self.last_line_count;
        let Some(row) = self.rows.last_mut() else { return };
        row.block.text.push('\n');
        row.block.text.push_str(line);
        match &mut row.block.layout.continuation {
            Some(facts) => facts.push(fact),
            None if fact.is_some() => {
                let mut facts = vec![None; count - 1];
                facts.push(fact);
                row.block.layout.continuation = Some(facts);
            }
            None => {}
        }
        self.last_line_count += 1;
    }
}

/// Whether a line straight after this block can go on with its text.
fn continues(block: &Block) -> bool {
    match &block.kind {
        BlockKind::Paragraph | BlockKind::Quote | BlockKind::Table => true,
        BlockKind::Item(item) => !(block.text.is_empty() && item.task.is_none()),
        BlockKind::Heading(_) | BlockKind::Code | BlockKind::Rule | BlockKind::Raw => false,
    }
}

// --- Writing ---------------------------------------------------------------

fn write(rows: &[(usize, &Block)], trailing: &[String], final_newline: bool, ending: LineEnding) -> String {
    let mut lines: Vec<String> = Vec::new();
    // The content column of the list item open at each depth.
    let mut columns: Vec<usize> = Vec::new();
    // When a line straight after the row before would go on with its text:
    // the column that text is measured from.
    let mut continuing: Option<usize> = None;
    for &(row_depth, block) in rows {
        if block.kind == BlockKind::Raw {
            lines.extend(block.text.split('\n').map(str::to_owned));
            columns.clear();
            continuing = None;
            continue;
        }
        lines.extend(block.layout.gap.iter().cloned());
        let depth = row_depth.min(columns.len());
        columns.truncate(depth);
        let base = columns.last().copied().unwrap_or(0);
        let indent = base + block.layout.extra_indent;
        let pad = " ".repeat(indent);
        let first_line = block.text.split('\n').next().unwrap_or("");
        let spaces = " ".repeat(block.layout.spacing);
        let mut continuation = indent;
        let first = match &block.kind {
            BlockKind::Item(item) => {
                let marker = match item.marker {
                    Marker::Bullet(c) => c.to_string(),
                    Marker::Ordered { number, delimiter } => format!("{number}{delimiter}"),
                };
                let mut head = format!("{pad}{marker}{spaces}");
                match item.task {
                    None => {}
                    Some(Task::Open) => head.push_str("[ ]"),
                    Some(Task::Done(letter)) => {
                        head.push('[');
                        head.push(letter);
                        head.push(']');
                    }
                }
                if item.task.is_some() && !block.text.is_empty() {
                    head.push(' ');
                }
                continuation = indent + marker.len() + block.layout.spacing.max(1);
                columns.push(continuation);
                head + first_line
            }
            BlockKind::Heading(level) => format!("{pad}{}{spaces}{first_line}", "#".repeat(usize::from(*level))),
            BlockKind::Quote => format!("{pad}>{spaces}{first_line}"),
            _ => format!("{pad}{first_line}"),
        };
        // A block made in an editor can sit straight after text it would be
        // read back as part of; a blank line keeps it a block.
        if block.layout.gap.is_empty() {
            if let Some(column) = continuing {
                if !starts_block(first.trim_start_matches(' '), indentation(&first) >= column) {
                    lines.push(String::new());
                }
            }
        }
        lines.push(first);
        continuing = continues(block).then_some(continuation);
        let facts = block.layout.continuation.as_deref().unwrap_or(&[]);
        for (offset, line) in block.text.split('\n').skip(1).enumerate() {
            let fact = facts.get(offset).copied().flatten();
            if block.kind == BlockKind::Quote && (fact.is_none() || fact == Some(QUOTE_BARE)) {
                // A quote's lines each with its `>`, as they were written.
                let space = if fact == Some(QUOTE_BARE) || line.is_empty() { "" } else { " " };
                lines.push(format!("{pad}>{space}{line}"));
            } else if let Some(written) = fact {
                lines.push(format!("{}{line}", " ".repeat(written.max(0) as usize)));
            } else if line.is_empty() {
                lines.push(String::new());
            } else {
                lines.push(format!("{}{line}", " ".repeat(continuation)));
            }
        }
    }
    lines.extend(trailing.iter().cloned());
    let newline = if ending == LineEnding::CrLf { "\r\n" } else { "\n" };
    let mut text = lines.join(newline);
    if final_newline && !lines.is_empty() {
        text.push_str(newline);
    }
    text
}

// --- Lines -----------------------------------------------------------------

fn is_blank(line: &str) -> bool {
    line.bytes().all(|b| b == b' ' || b == b'\t')
}

/// Columns of leading whitespace, a tab reaching the next stop of four.
fn indentation(line: &str) -> usize {
    let mut column = 0;
    for byte in line.bytes() {
        match byte {
            b' ' => column += 1,
            b'\t' => column += 4 - column % 4,
            _ => break,
        }
    }
    column
}

/// How many bytes of `line` make up its first `columns` columns of
/// indentation.
fn prefix_len(line: &str, columns: usize) -> usize {
    let (mut column, mut count) = (0, 0);
    for byte in line.bytes() {
        if column >= columns {
            break;
        }
        match byte {
            b' ' => column += 1,
            b'\t' => column += 4 - column % 4,
            _ => break,
        }
        count += 1;
    }
    count
}

struct ListItem<'a> {
    marker: Marker,
    spacing: usize,
    task: Option<Task>,
    text: &'a str,
}

fn list_item(content: &str) -> Option<ListItem<'_>> {
    let (marker, rest) = match content.chars().next()? {
        c @ ('-' | '*' | '+') => (Marker::Bullet(c), &content[1..]),
        _ => {
            let digits = content.bytes().take_while(u8::is_ascii_digit).count();
            if !(1..=9).contains(&digits) {
                return None;
            }
            let delimiter = content[digits..].chars().next().filter(|c| *c == '.' || *c == ')')?;
            (Marker::Ordered { number: content[..digits].parse().ok()?, delimiter }, &content[digits + 1..])
        }
    };
    if !(rest.is_empty() || rest.starts_with([' ', '\t'])) {
        return None;
    }
    let spacing = rest.bytes().take_while(|b| *b == b' ').count();
    let mut text = &rest[spacing..];
    if text.starts_with('\t') {
        return None;
    }
    let mut task = None;
    if spacing >= 1 {
        if let Some(found) = task_box(text) {
            let after = &text[3..];
            if after.is_empty() || after.starts_with(' ') {
                task = Some(found);
                text = after.strip_prefix(' ').unwrap_or(after);
            }
        }
    }
    Some(ListItem { marker, spacing, task, text })
}

fn task_box(text: &str) -> Option<Task> {
    match text.as_bytes() {
        [b'[', b' ', b']', ..] => Some(Task::Open),
        [b'[', letter @ (b'x' | b'X'), b']', ..] => Some(Task::Done(*letter as char)),
        _ => None,
    }
}

fn heading(content: &str) -> Option<(u8, usize, &str)> {
    let hashes = content.bytes().take_while(|b| *b == b'#').count();
    if !(1..=6).contains(&hashes) {
        return None;
    }
    let rest = &content[hashes..];
    if !(rest.is_empty() || rest.starts_with(' ')) {
        return None;
    }
    let spacing = rest.bytes().take_while(|b| *b == b' ').count();
    Some((hashes as u8, spacing, &rest[spacing..]))
}

/// The run of backticks or tildes that opens a fence.
fn fence_marker(content: &str) -> Option<&str> {
    let first = content.chars().next().filter(|c| *c == '`' || *c == '~')?;
    let run = content.bytes().take_while(|b| *b == first as u8).count();
    if run < 3 || (first == '`' && content[run..].contains('`')) {
        return None;
    }
    Some(&content[..run])
}

fn is_rule(content: &str) -> bool {
    let mut marks = content.chars().filter(|c| *c != ' ' && *c != '\t');
    let Some(first) = marks.next().filter(|c| matches!(c, '-' | '*' | '_')) else { return false };
    let mut count = 1;
    for mark in marks {
        if mark != first {
            return false;
        }
        count += 1;
    }
    count >= 3
}

/// Whether a line, stripped of its indentation, starts a block of its own
/// rather than going on with the text before it.
fn starts_block(content: &str, interrupting_paragraph: bool) -> bool {
    if heading(content).is_some() || fence_marker(content).is_some() || is_rule(content) || content.starts_with('>') {
        return true;
    }
    let Some(item) = list_item(content) else { return false };
    if interrupting_paragraph {
        // Markdown lets only a list item with something in it, and an
        // ordered one only when it counts from one, break into a paragraph.
        if item.text.is_empty() && item.task.is_none() {
            return false;
        }
        if matches!(item.marker, Marker::Ordered { number, .. } if number != 1) {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(source: &str) -> Document {
        let document = Document::parse(source);
        assert_eq!(document.to_markdown(), source, "round trip of {source:?}");
        document
    }

    fn kinds(document: &Document) -> Vec<(usize, &BlockKind, &str)> {
        document.rows().into_iter().map(|r| (r.depth, &r.block.kind, r.block.text.as_str())).collect()
    }

    #[test]
    fn lists_nest_by_indentation() {
        let document = round_trip("- one\n  - two\n    - three\n  - four\n- five\n");
        let depths: Vec<_> = document.rows().iter().map(|r| (r.depth, r.block.text.clone())).collect();
        assert_eq!(depths, [(0, "one".into()), (1, "two".into()), (2, "three".into()), (1, "four".into()), (0, "five".into())]);
        assert_eq!(document.blocks.len(), 2);
        assert_eq!(document.blocks[0].children.len(), 2);
        assert_eq!(document.get(&[0, 0, 0]).unwrap().text, "three");
        assert!(document.get(&[0, 5]).is_none());
        assert!(!document.rows().iter().any(|r| r.block.kind == BlockKind::Raw));
    }

    #[test]
    fn every_block_kind_is_read_for_what_it_is() {
        let source = "# Title\n\nA paragraph\nover two lines.\n\n> quoted\n> again\n\n```rust\nfn main() {}\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n\n1. first\n2) second\n+ [ ] task\n- [x] done\n* star\n";
        let document = round_trip(source);
        let got = kinds(&document);
        assert_eq!(got[0], (0, &BlockKind::Heading(1), "Title"));
        assert_eq!(got[1], (0, &BlockKind::Paragraph, "A paragraph\nover two lines."));
        assert_eq!(got[2], (0, &BlockKind::Quote, "quoted\nagain"));
        assert_eq!(got[3], (0, &BlockKind::Code, "```rust\nfn main() {}\n```"));
        assert_eq!(got[4], (0, &BlockKind::Table, "| a | b |\n|---|---|\n| 1 | 2 |"));
        assert_eq!(got[5], (0, &BlockKind::Rule, "---"));
        assert_eq!(got[6].1, &BlockKind::Item(Item { marker: Marker::Ordered { number: 1, delimiter: '.' }, task: None }));
        assert_eq!(got[7].1, &BlockKind::Item(Item { marker: Marker::Ordered { number: 2, delimiter: ')' }, task: None }));
        assert_eq!(got[8].1, &BlockKind::Item(Item { marker: Marker::Bullet('+'), task: Some(Task::Open) }));
        assert_eq!(got[9].1, &BlockKind::Item(Item { marker: Marker::Bullet('-'), task: Some(Task::Done('x')) }));
        assert_eq!(got[10], (0, &BlockKind::Item(Item { marker: Marker::Bullet('*'), task: None }), "star"));
        assert_eq!(document.blocks[3].code_parts(), Some(Code { info: "rust", body: "fn main() {}" }));
    }

    #[test]
    fn what_is_inside_a_list_item_is_its_children() {
        let source = "- item\n\n  A paragraph inside.\n\n  ```\n  code\n  ```\n  - nested\n- next\n";
        let document = round_trip(source);
        let item = &document.blocks[0];
        assert_eq!(item.children.len(), 3);
        assert_eq!(item.children[0].kind, BlockKind::Paragraph);
        assert_eq!(item.children[1].kind, BlockKind::Code);
        assert_eq!(item.children[1].code_parts().unwrap().body, "code");
        assert!(item.children[2].is_item());
    }

    #[test]
    fn odd_but_legal_shapes_round_trip() {
        for source in [
            "",
            "\n",
            "\n\n",
            "no newline at the end",
            "- a\n\n\n- b\n\n",
            "-   wide spacing\n   - odd indent\n",
            "-\n- \n-  \n",
            "* [X] Capital\n+ [ ]\n+ [ ] \n",
            "> quote\nlazy line\n>bare\n> \n> end\n",
            "paragraph\n  indented more\n continuation\n",
            "- item\ncontinues lazily\n  and properly\n",
            "10. ten\n    - under ten\n",
            "## \n#\n####### seven is no heading\n",
            "```\nunclosed fence\n\n- not a list\n",
            "~~~~ info\n```\n~~~~\nafter\n",
            "- ```\n  in item\n  ```\n",
            "text\n***\n___\n- - -\n",
            "line one\r\nline two\r\n\r\n- a\r\n  - b\r\n",
            "   \n\t\ntext\n  \n",
            "- a\n      deep continuation\n",
            "+ [ ] task\n  more of it\n\n  para child\n",
            "| a |\n|---|\n| b |\ntrailing text\n\nnext\n",
            "1. a\n2. b\n3. c\n   continuation\n",
            "# Heading #\n\nSetext\n======\n",
            "<div>\n  html\n</div>\n",
        ] {
            round_trip(source);
        }
    }

    #[test]
    fn what_cannot_be_written_back_is_kept_raw_block_by_block() {
        // A tab as a list's indentation is written back as spaces: kept raw.
        let source = "- fine\n\n- parent\n\t- tabbed child\n\n- also fine\n";
        let document = round_trip(source);
        assert_eq!(document.blocks.len(), 3);
        assert!(document.blocks[0].is_item());
        assert_eq!(document.blocks[1].kind, BlockKind::Raw);
        assert_eq!(document.blocks[1].text, "\n- parent\n\t- tabbed child");
        assert!(document.blocks[2].is_item());
        // Mixed line endings: the stray `\r` is kept.
        round_trip("unix\nwindows\r\nunix\n");
        round_trip("\tindented with a tab\n");
    }

    #[test]
    fn code_and_callouts_have_parts() {
        let document = Document::parse("> [!TIP]\n> Follow a link.\n\n> plain\n\n````md\n```\ninner\n```\n````\n\n```\n");
        assert_eq!(document.blocks[0].callout(), Some(Callout { kind: "TIP", body: "Follow a link." }));
        assert_eq!(document.blocks[1].callout(), None);
        assert_eq!(document.blocks[2].code_parts(), Some(Code { info: "md", body: "```\ninner\n```" }));
        assert_eq!(document.blocks[3].code_parts(), Some(Code { info: "", body: "" }));
        assert_eq!(Block::paragraph("x").code_parts(), None);
    }

    #[test]
    fn new_blocks_are_written_canonically() {
        let mut document = Document::new();
        document.blocks.push(Block::heading(2, "Plan"));
        document.blocks.push(Block::bullet("first").with_children(vec![Block::task("sub"), Block::paragraph("a note")]));
        document.blocks.push(Block::ordered(1, "numbered").with_children(vec![Block::bullet("under")]));
        document.blocks.push(Block::code("md", "```\ninner\n```"));
        document.blocks.push(Block::quote("said\ntwice"));
        document.blocks.push(Block::rule());
        let written = document.to_markdown();
        assert_eq!(written, "## Plan\n- first\n  + [ ] sub\n\n  a note\n1. numbered\n   - under\n````md\n```\ninner\n```\n````\n> said\n> twice\n---\n");
        // And what was written reads back as the same tree.
        let again = Document::parse(&written);
        assert_eq!(
            kinds(&again).iter().map(|k| (k.0, k.2.to_owned())).collect::<Vec<_>>(),
            kinds(&document).iter().map(|k| (k.0, k.2.to_owned())).collect::<Vec<_>>()
        );
    }

    #[test]
    fn a_paragraph_after_text_is_kept_apart() {
        // Written straight after one another, the second would be read as
        // the first's next line: a blank line keeps it a block.
        let mut document = Document::new();
        document.blocks = vec![Block::paragraph("one"), Block::paragraph("two"), Block::bullet("three"), Block::paragraph("four")];
        assert_eq!(document.to_markdown(), "one\n\ntwo\n- three\n\nfour\n");
        assert_eq!(Document::parse(&document.to_markdown()).blocks.len(), 4);
    }

    #[test]
    fn blank_documents_are_blank() {
        assert!(Document::parse("").is_blank());
        assert!(Document::parse("- \n").is_blank());
        assert!(!Document::parse("- [ ] \n").is_blank());
        assert!(!Document::parse("- a\n").is_blank());
        assert_eq!(Document::new().to_markdown(), "");
    }

    #[test]
    fn editing_a_block_changes_only_its_lines() {
        let source = "*   odd bullet\n\n\n1) keep\n   - [X] me\n";
        let mut document = Document::parse(source);
        document.get_mut(&[1, 0]).unwrap().text = "changed".into();
        assert_eq!(document.to_markdown(), "*   odd bullet\n\n\n1) keep\n   - [X] changed\n");
    }
}
