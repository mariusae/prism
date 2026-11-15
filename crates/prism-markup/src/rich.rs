//! A row's words as rich text: what they show, and how they are marked.
//!
//! A block keeps its words as the Markdown they were written in, and is
//! written back as it was read unless it was edited. An editor shows them
//! as [`Rich`]: the words as they read — no `**`, no brackets — with
//! [`Run`]s saying which are strong, emphasised, struck, highlighted,
//! code, or a link's words. What is not words — a link to a page, a
//! picture, a comment — is one [`ATOM`] character, with its Markdown kept
//! to be written back as it was. Edits are made to the rich text, in what
//! it shows; the Markdown is made again from it ([`Rich::to_markdown`]),
//! escaping only what would otherwise be read as Markdown.

use std::ops::Range;

use crate::inline::{self, Span, SpanKind};

/// What stands in the words for something that is not words: a link to a
/// page, a picture, a comment. One character, drawn as what it is.
pub const ATOM: char = '\u{FFFC}';

/// How a stretch of the words is marked.
#[derive(Debug, Clone, PartialEq)]
pub enum Mark {
    Strong,
    /// With the character it was written with: `*` or `_`.
    Emphasis(char),
    Strikethrough,
    Highlight,
    /// Its words shown as written; with how many backticks were around them.
    Code(usize),
    /// `[words](target "title")`.
    Link {
        target: String,
        title: Option<String>,
    },
    /// `<https://…>`: the address is the words.
    Autolink,
    /// A bare address in the words: no Markdown of its own.
    Url,
    /// `#tag`: words, read as a tag.
    Tag(String),
    /// What an [`ATOM`] stands for: its Markdown, as written.
    Atom(Atom),
}

/// What an [`ATOM`] stands for.
#[derive(Debug, Clone, PartialEq)]
pub struct Atom {
    /// Its Markdown, written back as it was.
    pub source: String,
    pub kind: AtomKind,
}

#[derive(Debug, Clone, PartialEq)]
pub enum AtomKind {
    /// `[[target]]`, `[[target|label]]`, or — embedded — `![[target]]`.
    Page { target: String, label: Option<String>, embed: bool },
    /// `![alt](source)`, with any size noted after it.
    Picture { source: String, alt: String, width: Option<f64>, height: Option<f64> },
    /// `<!-- … -->`: nothing shown.
    Comment,
}

impl Mark {
    /// Whether it is a style that what is typed beside it takes on.
    fn carries(&self) -> bool {
        matches!(self, Mark::Strong | Mark::Emphasis(_) | Mark::Strikethrough | Mark::Highlight)
    }

    /// Whether it is written as Markdown around its words — as against
    /// words read as something (an address, a tag), or an atom.
    fn wraps(&self) -> bool {
        !matches!(self, Mark::Url | Mark::Tag(_) | Mark::Atom(_))
    }

    /// The same kind of mark, whatever it says — for toggling.
    fn same_kind(&self, other: &Mark) -> bool {
        std::mem::discriminant(self) == std::mem::discriminant(other)
    }
}

/// A stretch of the words, marked: byte offsets of [`Rich::text`].
#[derive(Debug, Clone, PartialEq)]
pub struct Run {
    pub range: Range<usize>,
    pub mark: Mark,
}

/// A row's words, as rich text.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Rich {
    /// The words as they read; an [`ATOM`] for each thing that is not words.
    pub text: String,
    /// The marks on them, in order of where they start.
    pub runs: Vec<Run>,
}

/// Where a part of the Markdown went in the words: `markdown` bytes are
/// shown as `shown` bytes (the same, for plain words; none, for markup;
/// one atom, for an atom's).
#[derive(Debug, Clone)]
struct Piece {
    markdown: Range<usize>,
    shown: Range<usize>,
    /// Plain words, shown byte for byte as written.
    plain: bool,
}

/// A row's words read from their Markdown, with where each part went.
fn read(markdown: &str) -> (Rich, Vec<Piece>) {
    let mut rich = Rich::default();
    let mut pieces = Vec::new();
    let spans = inline::parse(markdown);
    emit(markdown, 0..markdown.len(), &spans, &mut rich, &mut pieces);
    // One mark read in pieces — italics around bold — is one run.
    rich.tidy();
    (rich, pieces)
}

/// The references a space or a tab is written as where Markdown would
/// drop it — at a line's start or end — and what each stands for.
const KEPT_SPACES: [(&str, char); 2] = [("&#32;", ' '), ("&#9;", '\t')];

fn push_plain(markdown: &str, range: Range<usize>, rich: &mut Rich, pieces: &mut Vec<Piece>) {
    if range.is_empty() {
        return;
    }
    // Spaces at a line's start or end are no words — Markdown drops them — but markup.
    let blank = |b: u8| b == b' ' || b == b'\t';
    let bytes = markdown.as_bytes();
    let mut edge = None;
    let mut at = range.start;
    while at < range.end {
        if blank(bytes[at]) {
            let end = (at..range.end).find(|i| !blank(bytes[*i])).unwrap_or(range.end);
            let run_end = (at..bytes.len()).find(|i| !blank(bytes[*i])).unwrap_or(bytes.len());
            if (at == 0 || bytes[at - 1] == b'\n') || run_end == bytes.len() || bytes[run_end] == b'\n' {
                edge = Some(at..end);
                break;
            }
            at = end;
        } else {
            at += 1;
        }
    }
    if let Some(edge) = edge {
        push_plain(markdown, range.start..edge.start, rich, pieces);
        push_markup(edge.clone(), rich, pieces);
        return push_plain(markdown, edge.end..range.end, rich, pieces);
    }
    // A space kept by its reference is shown as the space; the reference is markup.
    let next = KEPT_SPACES
        .iter()
        .filter_map(|(written, c)| markdown[range.clone()].find(written).map(|at| (range.start + at, *written, *c)))
        .min_by_key(|found| found.0);
    if let Some((found, written, c)) = next {
        push_plain(markdown, range.start..found, rich, pieces);
        let at = rich.text.len();
        rich.text.push(c);
        pieces.push(Piece { markdown: found..found + written.len(), shown: at..rich.text.len(), plain: false });
        return push_plain(markdown, found + written.len()..range.end, rich, pieces);
    }
    let at = rich.text.len();
    rich.text.push_str(&markdown[range.clone()]);
    pieces.push(Piece { markdown: range, shown: at..rich.text.len(), plain: true });
}

/// Words written with the spaces at each line's ends kept: Markdown drops
/// them there — and two at an end would break the line — so the outermost
/// is written as its reference.
fn keep_spaces(written: String) -> String {
    let reference = |c: char| if c == '\t' { "&#9;" } else { "&#32;" };
    let lines: Vec<String> = written
        .split('\n')
        .map(|line| {
            let mut line = line.to_owned();
            if let Some(last) = line.chars().next_back().filter(|c| *c == ' ' || *c == '\t') {
                if line.len() > 1 || !line.starts_with(last) {
                    line.truncate(line.len() - 1);
                    line.push_str(reference(last));
                }
            }
            if let Some(first) = line.chars().next().filter(|c| *c == ' ' || *c == '\t') {
                line.replace_range(..1, reference(first));
            }
            line
        })
        .collect();
    lines.join("\n")
}

fn push_markup(range: Range<usize>, rich: &Rich, pieces: &mut Vec<Piece>) {
    if !range.is_empty() {
        let at = rich.text.len();
        pieces.push(Piece { markdown: range, shown: at..at, plain: false });
    }
}

fn emit(markdown: &str, range: Range<usize>, spans: &[Span], rich: &mut Rich, pieces: &mut Vec<Piece>) {
    let mut at = range.start;
    let mut skip = false;
    for (index, span) in spans.iter().enumerate() {
        if std::mem::take(&mut skip) {
            continue;
        }
        // A picture's size, noted in a comment a space after it, is the picture's: one atom.
        let sized = matches!(span.kind, SpanKind::Image { .. })
            && spans.get(index + 1).is_some_and(|next| {
                next.kind == SpanKind::Comment && markdown[next.range.clone()].contains('{') && markdown[span.range.end..next.range.start].trim().is_empty()
            });
        let span = &if sized {
            skip = true;
            Span { range: span.range.start..spans[index + 1].range.end, ..span.clone() }
        } else {
            span.clone()
        };
        push_plain(markdown, at..span.range.start, rich, pieces);
        let start = rich.text.len();
        let atom = |kind: AtomKind, rich: &mut Rich, pieces: &mut Vec<Piece>| {
            let at = rich.text.len();
            rich.text.push(ATOM);
            pieces.push(Piece { markdown: span.range.clone(), shown: at..rich.text.len(), plain: false });
            rich.runs.push(Run { range: at..rich.text.len(), mark: Mark::Atom(Atom { source: markdown[span.range.clone()].to_owned(), kind }) });
        };
        let mark = match &span.kind {
            SpanKind::WikiLink { target, label, embed } => {
                atom(AtomKind::Page { target: target.clone(), label: label.clone(), embed: *embed }, rich, pieces);
                at = span.range.end;
                continue;
            }
            SpanKind::Image { source, alt, width, height } => {
                atom(AtomKind::Picture { source: source.clone(), alt: alt.clone(), width: *width, height: *height }, rich, pieces);
                at = span.range.end;
                continue;
            }
            SpanKind::Comment => {
                atom(AtomKind::Comment, rich, pieces);
                at = span.range.end;
                continue;
            }
            SpanKind::Escape => {
                // The character, shown; the backslash, markup.
                push_markup(span.range.start..span.content.start, rich, pieces);
                push_plain(markdown, span.content.clone(), rich, pieces);
                at = span.range.end;
                continue;
            }
            SpanKind::Strong => Mark::Strong,
            SpanKind::Emphasis => Mark::Emphasis(markdown[span.range.start..].chars().next().unwrap_or('*')),
            SpanKind::Strikethrough => Mark::Strikethrough,
            SpanKind::Highlight => Mark::Highlight,
            SpanKind::Code => Mark::Code(span.content.start - span.range.start),
            SpanKind::Link { target, title } => Mark::Link { target: target.clone(), title: title.clone() },
            SpanKind::Autolink { .. } => Mark::Autolink,
            SpanKind::Url => Mark::Url,
            SpanKind::Tag(name) => Mark::Tag(name.clone()),
        };
        if matches!(mark, Mark::Tag(_) | Mark::Url) {
            // Words read as a tag or an address: all of them shown.
            push_plain(markdown, span.range.clone(), rich, pieces);
            rich.runs.push(Run { range: start..rich.text.len(), mark });
            at = span.range.end;
            continue;
        }
        push_markup(span.range.start..span.content.start, rich, pieces);
        if matches!(mark, Mark::Code(_)) {
            // Nothing in code is Markdown: its words, as written.
            push_plain(markdown, span.content.clone(), rich, pieces);
        } else {
            emit(markdown, span.content.clone(), &span.children, rich, pieces);
        }
        push_markup(span.content.end..span.range.end, rich, pieces);
        let end = rich.text.len();
        if end > start {
            rich.runs.push(Run { range: start..end, mark });
        }
        at = span.range.end;
    }
    push_plain(markdown, at..range.end, rich, pieces);
}

impl Rich {
    /// A row's words, read from their Markdown.
    pub fn parse(markdown: &str) -> Rich {
        read(markdown).0
    }

    /// Plain words, marked with nothing.
    pub fn plain(text: &str) -> Rich {
        Rich { text: text.to_owned(), runs: Vec::new() }
    }

    /// Where a place in the Markdown is shown: inside markup, where the
    /// markup is shown (nowhere — its edge); inside an atom, before it.
    pub fn shown_offset(markdown: &str, offset: usize) -> usize {
        let (rich, pieces) = read(markdown);
        for piece in &pieces {
            if offset < piece.markdown.start {
                return piece.shown.start;
            }
            if offset < piece.markdown.end || (offset == piece.markdown.end && piece.plain) {
                return if piece.plain { piece.shown.start + (offset - piece.markdown.start) } else { piece.shown.start };
            }
        }
        rich.text.len()
    }

    /// Where a place in the words is in the Markdown: at the edge of
    /// markup, after it when `inside` (in the run that markup opens),
    /// before it otherwise.
    pub fn markdown_offset(markdown: &str, offset: usize, inside: bool) -> usize {
        let (_, pieces) = read(markdown);
        let mut found = None;
        for piece in &pieces {
            if piece.plain && piece.shown.start <= offset && offset <= piece.shown.end {
                let at = piece.markdown.start + (offset - piece.shown.start);
                // At a plain piece's start, markup may come before it: after it when inside.
                if offset == piece.shown.start && !inside && found.is_some() {
                    return found.unwrap_or(at);
                }
                if offset < piece.shown.end || !inside {
                    return at;
                }
                found = Some(at);
            } else if !piece.plain && piece.shown.start == offset {
                if found.is_none() || inside {
                    found = Some(if inside { piece.markdown.end } else { piece.markdown.start });
                }
                if !inside {
                    return found.unwrap_or(piece.markdown.start);
                }
            } else if piece.shown.start > offset {
                break;
            }
        }
        found.unwrap_or(markdown.len())
    }

    /// The marks what is typed at a place takes on: the styles of the
    /// words before it (at a row's start, after it) — not a link's or
    /// code's at their ends, which typing beside them does not lengthen.
    pub fn marks_at(&self, at: usize) -> Vec<Mark> {
        let mut marks = Vec::new();
        for run in &self.runs {
            let inside = run.range.start < at && at < run.range.end;
            let touches = if at == 0 { run.range.start == 0 && !run.range.is_empty() } else { run.range.start < at && at <= run.range.end };
            let takes = match &run.mark {
                Mark::Link { .. } | Mark::Code(_) => inside,
                mark if mark.carries() => touches,
                _ => false,
            };
            if takes && !marks.contains(&run.mark) {
                marks.push(run.mark.clone());
            }
        }
        marks
    }

    /// The marks words put in place of a range take: those that cover the
    /// whole of it — a link's, renamed — or, for a place, those of the
    /// words they join ([`marks_at`](Self::marks_at)).
    pub fn marks_over(&self, range: Range<usize>) -> Vec<Mark> {
        if range.is_empty() {
            return self.marks_at(range.start);
        }
        let mut marks = Vec::new();
        for run in &self.runs {
            if run.range.start <= range.start && range.end <= run.range.end && run.mark.wraps() && !marks.contains(&run.mark) {
                marks.push(run.mark.clone());
            }
        }
        marks
    }

    /// The words of a range replaced with others — marked as `marks` says,
    /// or, with none, as the words they join ([`marks_at`](Self::marks_at)).
    pub fn replace(&mut self, range: Range<usize>, with: &Rich, marks: Option<Vec<Mark>>) {
        let (a, b) = (range.start.min(self.text.len()), range.end.min(self.text.len()));
        let marks = marks.unwrap_or_else(|| self.marks_at(a));
        let gone = b - a;
        // First what is taken out: runs closed up over it; an atom in it, gone.
        let mut runs: Vec<Run> = Vec::with_capacity(self.runs.len() + with.runs.len() + marks.len());
        for run in self.runs.drain(..) {
            let atom = matches!(run.mark, Mark::Atom(_));
            if atom && gone > 0 && run.range.start < b && run.range.end > a {
                continue;
            }
            let close = |o: usize| {
                if o <= a {
                    o
                } else if o >= b {
                    o - gone
                } else {
                    a
                }
            };
            let (start, end) = (close(run.range.start), close(run.range.end));
            if end > start || (atom && end == start + ATOM.len_utf8()) {
                runs.push(Run { range: start..end, mark: run.mark });
            }
        }
        self.text.replace_range(a..b, "");
        // Then what comes in, at `a`: runs that carry on take it; those it parts are parted.
        let added = with.text.len();
        let mut given: Vec<Mark> = Vec::new();
        let mut placed: Vec<Run> = Vec::with_capacity(runs.len() + 2);
        for run in runs {
            let (s, e) = (run.range.start, run.range.end);
            let carried = marks.contains(&run.mark) && !given.contains(&run.mark);
            if added == 0 || e < a || (e == a && !carried) {
                placed.push(run);
            } else if s > a || (s == a && !carried) {
                placed.push(Run { range: s + added..e + added, mark: run.mark });
            } else if carried {
                // It takes what came in.
                given.push(run.mark.clone());
                placed.push(Run { range: s..e + added, mark: run.mark });
            } else {
                // What came in parts it.
                placed.push(Run { range: s..a, mark: run.mark.clone() });
                placed.push(Run { range: a + added..e + added, mark: run.mark });
            }
        }
        if added > 0 {
            for mark in marks.into_iter().filter(|mark| !given.contains(mark)) {
                placed.push(Run { range: a..a + added, mark });
            }
            placed.extend(with.runs.iter().map(|run| Run { range: run.range.start + a..run.range.end + a, mark: run.mark.clone() }));
        }
        self.text.insert_str(a, &with.text);
        self.runs = placed;
        self.tidy();
    }

    /// Puts a style on a range, or — if every word of it has that style —
    /// takes it off. Code is alone: making words code takes the other
    /// styles off them.
    pub fn toggle(&mut self, range: Range<usize>, mark: Mark) {
        if range.is_empty() {
            return;
        }
        let covered = self.covered(&range, &mark);
        self.unmark(&range, &mark);
        if !covered {
            if matches!(mark, Mark::Code(_)) {
                for other in [Mark::Strong, Mark::Emphasis('*'), Mark::Strikethrough, Mark::Highlight] {
                    self.unmark(&range, &other);
                }
            }
            self.runs.push(Run { range, mark });
        }
        self.tidy();
    }

    /// Links a range to a target, or points the link already there at it.
    pub fn link(&mut self, range: Range<usize>, target: &str) {
        if range.is_empty() {
            return;
        }
        // Within a link's words already: only where it goes changes.
        if let Some(run) =
            self.runs.iter_mut().find(|run| matches!(run.mark, Mark::Link { .. }) && run.range.start <= range.start && range.end <= run.range.end)
        {
            if let Mark::Link { target: old, .. } = &mut run.mark {
                *old = target.to_owned();
            }
            return;
        }
        self.unmark(&range, &Mark::Link { target: String::new(), title: None });
        self.runs.push(Run { range, mark: Mark::Link { target: target.to_owned(), title: None } });
        self.tidy();
    }

    /// Whether every word of a range has a mark of this kind.
    fn covered(&self, range: &Range<usize>, mark: &Mark) -> bool {
        let mut at = range.start;
        let mut runs: Vec<&Run> = self.runs.iter().filter(|run| run.mark.same_kind(mark)).collect();
        runs.sort_by_key(|run| run.range.start);
        for run in runs {
            if run.range.start <= at && run.range.end > at {
                at = run.range.end;
            }
        }
        at >= range.end
    }

    /// A mark of this kind taken off a range: runs cut, or split around it.
    fn unmark(&mut self, range: &Range<usize>, mark: &Mark) {
        let mut runs = Vec::with_capacity(self.runs.len());
        for run in self.runs.drain(..) {
            if !run.mark.same_kind(mark) || run.range.end <= range.start || run.range.start >= range.end {
                runs.push(run);
                continue;
            }
            if run.range.start < range.start {
                runs.push(Run { range: run.range.start..range.start, mark: run.mark.clone() });
            }
            if run.range.end > range.end {
                runs.push(Run { range: range.end..run.range.end, mark: run.mark });
            }
        }
        self.runs = runs;
    }

    /// Runs merged where they meet or overlap with the same mark, empty
    /// ones taken out, all in order.
    fn tidy(&mut self) {
        self.runs.retain(|run| !run.range.is_empty() && run.range.end <= self.text.len());
        self.runs.sort_by(|a, b| a.range.start.cmp(&b.range.start).then(b.range.end.cmp(&a.range.end)));
        let mut merged: Vec<Run> = Vec::with_capacity(self.runs.len());
        for run in self.runs.drain(..) {
            let joins = |last: &Run| last.mark == run.mark && !matches!(run.mark, Mark::Atom(_)) && last.range.end >= run.range.start;
            if let Some(last) = merged.iter_mut().rev().find(|last| last.mark == run.mark) {
                if joins(last) {
                    last.range.end = last.range.end.max(run.range.end);
                    continue;
                }
            }
            merged.push(run);
        }
        merged.sort_by(|a, b| a.range.start.cmp(&b.range.start).then(b.range.end.cmp(&a.range.end)));
        self.runs = merged;
    }

    /// The words from a place on, split off: what Return leaves on the next row.
    pub fn split_off(&mut self, at: usize) -> Rich {
        let at = at.min(self.text.len());
        let tail_text = self.text.split_off(at);
        let mut tail = Rich { text: tail_text, runs: Vec::new() };
        let mut head = Vec::new();
        for run in self.runs.drain(..) {
            if run.range.end <= at {
                head.push(run);
            } else if run.range.start >= at {
                tail.runs.push(Run { range: run.range.start - at..run.range.end - at, mark: run.mark });
            } else {
                head.push(Run { range: run.range.start..at, mark: run.mark.clone() });
                tail.runs.push(Run { range: 0..run.range.end - at, mark: run.mark });
            }
        }
        self.runs = head;
        self.tidy();
        tail.tidy();
        tail
    }

    /// Other words put after these: what joining a row onto another does.
    pub fn append(&mut self, other: &Rich) {
        let at = self.text.len();
        self.text.push_str(&other.text);
        self.runs.extend(other.runs.iter().map(|run| Run { range: run.range.start + at..run.range.end + at, mark: run.mark.clone() }));
        self.tidy();
    }

    // --- Written as Markdown -------------------------------------------------

    /// The words as Markdown: marks around the words they mark, atoms as
    /// they were written, and only what would be read as Markdown escaped.
    /// Read back, it gives these words, marked as they are.
    pub fn to_markdown(&self) -> String {
        self.markdown(true)
    }

    /// As [`to_markdown`](Self::to_markdown); `guarded` false for words
    /// that cannot be read as another kind of row whatever they begin
    /// with — a heading's.
    pub fn markdown(&self, guarded: bool) -> String {
        let guard_start = |written: String| keep_spaces(if guarded { guard_start(written) } else { written });
        // Emphasis as it was written; else by `_`, which does not run into `**`.
        let underscored = Rich {
            text: self.text.clone(),
            runs: self
                .runs
                .iter()
                .map(|run| Run { range: run.range.clone(), mark: if matches!(run.mark, Mark::Emphasis(_)) { Mark::Emphasis('_') } else { run.mark.clone() } })
                .collect(),
        };
        for rich in [self, &underscored] {
            for escaping in [Escaping::None, Escaping::Least, Escaping::Underscores, Escaping::All] {
                let written = guard_start(rich.write(escaping));
                if Rich::parse(&written).same_as(self) {
                    return written;
                }
            }
        }
        guard_start(self.write(Escaping::Least))
    }

    /// Whether two rich texts read the same: their words, and which of
    /// them — spaces aside, which a mark cannot open or close on — carry
    /// each mark Markdown writes (an address or a tag is read from the words).
    fn same_as(&self, other: &Rich) -> bool {
        let marked = |rich: &Rich| {
            let mut marked: Vec<(String, usize)> = Vec::new();
            for run in rich.runs.iter().filter(|run| run.mark.wraps() || matches!(run.mark, Mark::Atom(_))) {
                let mark = format!("{:?}", normal(&run.mark));
                for (offset, c) in rich.text[run.range.clone()].char_indices() {
                    if !c.is_whitespace() {
                        marked.push((mark.clone(), run.range.start + offset));
                    }
                }
            }
            marked.sort();
            marked.dedup();
            marked
        };
        self.text == other.text && marked(self) == marked(other)
    }

    fn write(&self, escaping: Escaping) -> String {
        // The marks written around words, cut where words cannot be marked across:
        // a line break, and the leading and trailing spaces of a run, which Markdown
        // does not let a mark open or close on.
        let mut runs: Vec<Run> = Vec::new();
        for run in self.runs.iter().filter(|run| run.mark.wraps()) {
            let mut start = run.range.start;
            for (offset, _) in self.text[run.range.clone()].match_indices('\n') {
                runs.push(Run { range: start..run.range.start + offset, mark: run.mark.clone() });
                start = run.range.start + offset + 1;
            }
            runs.push(Run { range: start..run.range.end, mark: run.mark.clone() });
        }
        // Marks that cross — one opening inside another and closing past it — cannot be
        // written so: the later is cut where the earlier ends, so that every mark nests.
        // A link is not cut: what crosses it is.
        runs.sort_by(|a, b| a.range.start.cmp(&b.range.start).then(b.range.end.cmp(&a.range.end)));
        let link = |run: &Run| matches!(run.mark, Mark::Link { .. } | Mark::Autolink);
        let mut cut = true;
        while cut {
            cut = false;
            'pairs: for i in 0..runs.len() {
                for j in 0..runs.len() {
                    let (outer, inner) = (&runs[i], &runs[j]);
                    let crosses = inner.range.start > outer.range.start && inner.range.start < outer.range.end && inner.range.end > outer.range.end;
                    if !crosses {
                        continue;
                    }
                    // Cut the one that is no link: the inner at the outer's end, or the outer at the inner's start.
                    if link(inner) && !link(outer) {
                        let at = inner.range.start;
                        let rest = Run { range: at..runs[i].range.end, mark: runs[i].mark.clone() };
                        runs[i].range.end = at;
                        runs.push(rest);
                    } else {
                        let at = outer.range.end;
                        let rest = Run { range: at..runs[j].range.end, mark: runs[j].mark.clone() };
                        runs[j].range.end = at;
                        runs.push(rest);
                    }
                    cut = true;
                    break 'pairs;
                }
            }
            runs.retain(|run| !run.range.is_empty());
        }
        for run in &mut runs {
            if matches!(run.mark, Mark::Code(_) | Mark::Link { .. } | Mark::Autolink) {
                continue;
            }
            let words = &self.text[run.range.clone()];
            let leading = words.len() - words.trim_start().len();
            let trailing = words.len() - words.trim_end().len();
            run.range = run.range.start + leading..(run.range.end - trailing).max(run.range.start + leading);
        }
        runs.retain(|run| !run.range.is_empty());
        let atoms: Vec<&Run> = self.runs.iter().filter(|run| matches!(run.mark, Mark::Atom(_))).collect();
        let raw: Vec<&Run> = self.runs.iter().filter(|run| matches!(run.mark, Mark::Url | Mark::Tag(_))).collect();

        // Every place a mark opens or closes, in order.
        let mut cuts: Vec<usize> = runs.iter().flat_map(|run| [run.range.start, run.range.end]).collect();
        cuts.extend(atoms.iter().flat_map(|run| [run.range.start, run.range.end]));
        cuts.extend([0, self.text.len()]);
        cuts.sort_unstable();
        cuts.dedup();

        let mut out = String::with_capacity(self.text.len() + 16);
        let mut open: Vec<&Run> = Vec::new();
        for pair in cuts.windows(2) {
            let (start, end) = (pair[0], pair[1]);
            // Close what ends here, innermost first.
            while open.last().is_some_and(|run| run.range.end <= start) {
                if let Some(run) = open.pop() {
                    out.push_str(&closer(&run.mark));
                }
            }
            // Open what starts here: links outermost, then the longest.
            let mut opening: Vec<&Run> = runs.iter().filter(|run| run.range.start == start).collect();
            opening.sort_by(|a, b| link(b).cmp(&link(a)).then(b.range.end.cmp(&a.range.end)));
            for run in opening {
                out.push_str(&opener(&run.mark));
                open.push(run);
            }
            if let Some(atom) = atoms.iter().find(|run| run.range.start == start) {
                if let Mark::Atom(atom) = &atom.mark {
                    out.push_str(&atom.source);
                }
                continue;
            }
            let words = &self.text[start..end];
            let in_code = open.iter().any(|run| matches!(run.mark, Mark::Code(_)));
            let in_raw = raw.iter().any(|run| run.range.start <= start && end <= run.range.end);
            if in_code || in_raw || open.iter().any(|run| matches!(run.mark, Mark::Autolink)) {
                out.push_str(words);
            } else {
                escape(words, &self.text[..start], &mut out, escaping);
            }
        }
        for run in open.into_iter().rev() {
            out.push_str(&closer(&run.mark));
        }
        out
    }
}

/// A mark as Markdown reads it back: an emphasis by either character is
/// one emphasis; code with any number of backticks one code.
fn normal(mark: &Mark) -> Mark {
    match mark {
        Mark::Emphasis(_) => Mark::Emphasis('*'),
        Mark::Code(_) => Mark::Code(1),
        other => other.clone(),
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Escaping {
    /// Nothing: what reads back the same unescaped is best left so.
    None,
    /// Only what plainly starts Markdown.
    Least,
    /// And underscores.
    Underscores,
    /// Every punctuation mark.
    All,
}

fn escape(words: &str, before: &str, out: &mut String, escaping: Escaping) {
    let mut previous = before.chars().next_back();
    let mut chars = words.chars().peekable();
    while let Some(c) = chars.next() {
        let next = chars.peek().copied();
        let needs = match escaping {
            Escaping::None => false,
            Escaping::All => c.is_ascii_punctuation(),
            _ => {
                matches!(c, '\\' | '*' | '`')
                    || (c == '_' && escaping == Escaping::Underscores)
                    || (c == '[' || c == ']')
                    || (c == '<' && next.is_some_and(|n| n == '!' || n.is_ascii_alphabetic()))
                    || (c == '~' && next == Some('~'))
                    || (c == '=' && next == Some('='))
                    || (c == '&'
                        && KEPT_SPACES
                            .iter()
                            .any(|(written, _)| words[words.len() - chars.clone().map(char::len_utf8).sum::<usize>()..].starts_with(&written[1..])))
                    || (c == '!' && next == Some('['))
                    || (c == '#' && next.is_some_and(|n| !n.is_whitespace() && n != '#') && previous.is_none_or(char::is_whitespace) && false)
            }
        };
        if needs {
            out.push('\\');
        }
        out.push(c);
        previous = Some(c);
    }
}

/// A row's words written so that they cannot be read as the start of
/// another kind of row — a heading, a quote, a list, a task, a fence, a
/// rule: what begins them is escaped.
fn guard_start(written: String) -> String {
    let starts = |prefix: &str| written.starts_with(prefix);
    let spaced = |mark: &str| written.strip_prefix(mark).is_some_and(|rest| rest.is_empty() || rest.starts_with([' ', '\t']));
    let digits = written.bytes().take_while(u8::is_ascii_digit).count();
    let numbered = digits > 0 && digits <= 9 && {
        let rest = &written[digits..];
        (rest.starts_with('.') || rest.starts_with(')')) && (rest.len() == 1 || rest[1..].starts_with([' ', '\t']))
    };
    if numbered {
        return format!("{}\\{}", &written[..digits], &written[digits..]);
    }
    let block = (starts("#") && written.trim_start_matches('#').starts_with([' ', '\t']))
        || (!written.is_empty() && written.bytes().all(|b| b == b'#'))
        || starts(">")
        || spaced("-")
        || spaced("+")
        || spaced("*")
        || starts("```")
        || starts("~~~")
        || starts("---")
        || starts("[ ]")
        || starts("[x]")
        || starts("[X]");
    if block {
        format!("\\{written}")
    } else {
        written
    }
}

fn opener(mark: &Mark) -> String {
    match mark {
        Mark::Strong => "**".into(),
        Mark::Emphasis(c) => c.to_string(),
        Mark::Strikethrough => "~~".into(),
        Mark::Highlight => "==".into(),
        Mark::Code(ticks) => "`".repeat(*ticks.max(&1)),
        Mark::Link { .. } => "[".into(),
        Mark::Autolink => "<".into(),
        Mark::Url | Mark::Tag(_) | Mark::Atom(_) => String::new(),
    }
}

fn closer(mark: &Mark) -> String {
    match mark {
        Mark::Link { target, title } => match title {
            Some(title) => format!("]({target} \"{title}\")"),
            None => format!("]({target})"),
        },
        Mark::Autolink => ">".into(),
        other => opener(other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round(markdown: &str) -> String {
        Rich::parse(markdown).to_markdown()
    }

    #[test]
    fn words_are_shown_without_their_markdown() {
        let rich = Rich::parse("plain **bold** and *it* and `co*de` and [a link](https://x.org) and \\*star");
        assert_eq!(rich.text, "plain bold and it and co*de and a link and *star");
        let marks: Vec<_> = rich.runs.iter().map(|run| (&rich.text[run.range.clone()], run.mark.clone())).collect();
        assert!(marks.contains(&("bold", Mark::Strong)));
        assert!(marks.contains(&("it", Mark::Emphasis('*'))));
        assert!(marks.contains(&("co*de", Mark::Code(1))));
        assert!(marks.contains(&("a link", Mark::Link { target: "https://x.org".into(), title: None })));
    }

    #[test]
    fn what_is_not_words_is_one_atom() {
        let rich = Rich::parse("see [[Ada]] and ![pic](a.png) here");
        assert_eq!(rich.text, format!("see {ATOM} and {ATOM} here"));
        assert_eq!(rich.to_markdown(), "see [[Ada]] and ![pic](a.png) here");
    }

    #[test]
    fn markdown_written_back_reads_the_same() {
        for markdown in [
            "plain words",
            "**bold** and *it* and ***both***",
            "a [link **bold** inside](u) end",
            "`code` and ``co`de``",
            "==hi== and ~~gone~~",
            "snake_case and 2*3 and a * b",
            "<https://x.org> and https://bare.example/path_x",
            "#tag and #another",
            "line one\nline two",
            "_under_ score",
        ] {
            let rich = Rich::parse(markdown);
            assert_eq!(Rich::parse(&rich.to_markdown()), rich, "{markdown:?} → {:?}", rich.to_markdown());
        }
        // Words with what would be Markdown, escaped only where needed.
        assert_eq!(Rich::plain("2*3 and [x] and a_b").to_markdown(), "2*3 and [x] and a_b");
        assert_eq!(Rich::plain("a *b* c").to_markdown(), "a \\*b\\* c");
        // What would start another kind of row, escaped.
        assert_eq!(Rich::plain("1. one").to_markdown(), "1\\. one");
        assert_eq!(Rich::plain("# not a heading").to_markdown(), "\\# not a heading");
        assert_eq!(Rich::plain("- not a bullet").to_markdown(), "\\- not a bullet");
        assert_eq!(Rich::plain("#tag").to_markdown(), "#tag");
        assert_eq!(round("**bold**"), "**bold**");
        assert_eq!(round("_under_"), "_under_");
    }

    #[test]
    fn typing_takes_the_marks_of_the_words_it_joins() {
        let mut rich = Rich::parse("a **bold** b");
        // At the end of bold: bold. At a row's start: what follows.
        rich.replace(6..6, &Rich::plain("er"), None);
        assert_eq!(rich.to_markdown(), "a **bolder** b");
        let mut rich = Rich::parse("**bold** b");
        rich.replace(0..0, &Rich::plain("very "), None);
        assert_eq!(rich.to_markdown(), "**very bold** b");
        // After a link: not the link.
        let mut rich = Rich::parse("[link](u)");
        rich.replace(4..4, &Rich::plain(" more"), None);
        assert_eq!(rich.to_markdown(), "[link](u) more");
        // Asked for plain, plain.
        let mut rich = Rich::parse("a **bold** b");
        rich.replace(6..6, &Rich::plain("x"), Some(vec![]));
        assert_eq!(rich.to_markdown(), "a **bold**x b");
    }

    #[test]
    fn deleting_keeps_the_marks_around() {
        let mut rich = Rich::parse("a **bold** b");
        rich.replace(3..5, &Rich::default(), None);
        assert_eq!(rich.to_markdown(), "a **bd** b");
        let mut rich = Rich::parse("a **bold** b");
        rich.replace(2..6, &Rich::default(), None);
        assert_eq!(rich.to_markdown(), "a  b");
        // An atom goes whole.
        let mut rich = Rich::parse("x [[Ada]] y");
        rich.replace(2..2 + ATOM.len_utf8(), &Rich::default(), None);
        assert_eq!(rich.to_markdown(), "x  y");
    }

    #[test]
    fn styles_toggle_on_and_off() {
        let mut rich = Rich::plain("one two three");
        rich.toggle(4..7, Mark::Strong);
        assert_eq!(rich.to_markdown(), "one **two** three");
        rich.toggle(4..7, Mark::Strong);
        assert_eq!(rich.to_markdown(), "one two three");
        rich.toggle(0..7, Mark::Emphasis('*'));
        rich.toggle(4..13, Mark::Strong);
        assert!(Rich::parse(&rich.to_markdown()).same_as(&rich), "{:?}", rich.to_markdown());
        // A mark not on spaces at its ends.
        let mut rich = Rich::plain("one two three");
        rich.toggle(3..8, Mark::Strong);
        assert_eq!(rich.to_markdown(), "one **two** three");
    }

    #[test]
    fn split_and_join() {
        let mut rich = Rich::parse("a **bold** b");
        let tail = rich.split_off(4);
        assert_eq!(rich.to_markdown(), "a **bo**");
        assert_eq!(tail.to_markdown(), "**ld** b");
        rich.append(&tail);
        assert_eq!(rich.to_markdown(), "a **bold** b");
    }

    #[test]
    fn places_map_both_ways() {
        let md = "a **bold** b";
        // Shown "a bold b": the b of bold is at 2; in the Markdown, 4.
        assert_eq!(Rich::shown_offset(md, 4), 2);
        assert_eq!(Rich::markdown_offset(md, 2, true), 4);
        assert_eq!(Rich::markdown_offset(md, 2, false), 2);
        assert_eq!(Rich::shown_offset(md, 3), 2);
        assert_eq!(Rich::markdown_offset(md, 6, false), 8);
        assert_eq!(Rich::markdown_offset(md, 8, false), md.len());
    }
}

#[cfg(test)]
mod graph {
    use super::*;
    use crate::block::Document;

    /// Every row of a graph's notes, read and written back: `RICH_GRAPH=<folder> cargo test -- --ignored`.
    #[test]
    #[ignore]
    fn every_row_of_a_graph_reads_back_the_same() {
        let Ok(root) = std::env::var("RICH_GRAPH") else { return };
        let (mut rows, mut same_markdown, mut misread) = (0, 0, Vec::new());
        let mut stack = vec![std::path::PathBuf::from(root)];
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
                let path = entry.path();
                if path.file_name().is_some_and(|n| n == ".git") {
                    continue;
                }
                if path.is_dir() {
                    stack.push(path);
                } else if path.extension().is_some_and(|e| e == "md") {
                    let Ok(source) = std::fs::read_to_string(&path) else { continue };
                    let document = Document::parse(&source);
                    for row in document.rows() {
                        if !row.block.has_inline_content() {
                            continue;
                        }
                        rows += 1;
                        let rich = Rich::parse(&row.block.text);
                        let written = rich.to_markdown();
                        if written == row.block.text {
                            same_markdown += 1;
                        } else if std::env::var("RICH_SHOW").is_ok() && same_markdown % 37 == 0 {
                            eprintln!("DIFF {:?}\n  -> {:?}", row.block.text, written);
                        }
                        if !Rich::parse(&written).same_as(&rich) {
                            misread.push((row.block.text.clone(), written));
                        }
                    }
                }
            }
        }
        eprintln!("rows {rows}, written the same {same_markdown}, read back differently {}", misread.len());
        for (from, to) in misread.iter().take(15) {
            eprintln!("  {from:?}\n→ {to:?}");
        }
        assert!(misread.is_empty());
    }

    #[test]
    fn spaces_at_a_lines_ends_are_kept() {
        for words in [" lead", "  two lead", "trail ", "end  ", " ", "\tindent", "a\n  b ", "say &#32; literally"] {
            let written = Rich::plain(words).to_markdown();
            assert_eq!(Rich::parse(&written).text, words, "{words:?} written {written:?}");
        }
        // Only what Markdown would drop is written as a reference.
        assert_eq!(Rich::plain(" a  b ").to_markdown(), "&#32;a  b&#32;");
        assert_eq!(Rich::plain("a b").to_markdown(), "a b");
    }
}
