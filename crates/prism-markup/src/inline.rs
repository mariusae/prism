//! Inline Markdown: the spans in a block's text.
//!
//! A block keeps its text as the Markdown it was written in. [`parse`]
//! finds what that text means — emphasis, links, tags, pictures — as a
//! tree of [`Span`]s, each a byte range of the text with the range of what
//! it shows inside it. Nothing is rewritten: an editor draws the content,
//! hides the markup around it, and edits the text itself, so the file
//! keeps every byte it had.
//!
//! The dialect (see the crate docs): `**strong**`, `*emphasis*`,
//! `` `code` ``, `~~struck~~`, `==highlighted==`, `[text](url)`,
//! `<https://…>`, bare `https://…`, `[[Title]]`, `[[Title|shown]]`,
//! `![[Title]]`, `![alt](src)<!-- {"width":425} -->`, `#tag`,
//! `<!-- comments -->` and backslash escapes.
//!
//! Code comes first, since nothing inside it is Markdown; then links and
//! pictures, whose addresses are not either; then emphasis, which may hold
//! a link or sit inside a link's text, but never straddles its markup.

use std::ops::Range;

/// What a span is.
#[derive(Debug, Clone, PartialEq)]
pub enum SpanKind {
    Strong,
    Emphasis,
    Strikethrough,
    /// `==text==`: marked as with a highlighter.
    Highlight,
    /// `` `code` ``: its content is shown as written.
    Code,
    /// `[text](target)`, maybe with a title: `[text](target "title")`.
    Link {
        target: String,
        title: Option<String>,
    },
    /// `<https://…>`.
    Autolink {
        url: String,
    },
    /// A bare `https://…`; there is no markup to hide.
    Url,
    /// `[[target]]` or `[[target|label]]`; with `embed`, `![[target]]` —
    /// the page shown in place.
    WikiLink {
        target: String,
        label: Option<String>,
        embed: bool,
    },
    /// `![alt](source)`, and the size an editor may note in a comment
    /// straight after it: `<!-- {"width":425,"height":270} -->`.
    Image {
        source: String,
        alt: String,
        width: Option<f64>,
        height: Option<f64>,
    },
    /// `#tag`: the name, without its `#`.
    Tag(String),
    /// `<!-- … -->`: hidden whole.
    Comment,
    /// `\*`: the character, taken literally.
    Escape,
}

/// A stretch of inline Markdown.
#[derive(Debug, Clone, PartialEq)]
pub struct Span {
    pub kind: SpanKind,
    /// The whole span, markup included, as bytes of the text.
    pub range: Range<usize>,
    /// What it shows. Empty, at the span's start, for a picture or a
    /// comment, which show none of their text.
    pub content: Range<usize>,
    /// The spans within the content.
    pub children: Vec<Span>,
}

impl Span {
    /// The markup before and after the content: what an editor hides.
    pub fn markup(&self) -> [Range<usize>; 2] {
        [self.range.start..self.content.start, self.content.end..self.range.end]
    }

    /// This span and every span in it, outermost first.
    pub fn walk(&self) -> impl Iterator<Item = &Span> {
        let mut stack = vec![self];
        std::iter::from_fn(move || {
            let span = stack.pop()?;
            stack.extend(span.children.iter().rev());
            Some(span)
        })
    }
}

/// The spans in a text, in order; nested ones are their parents' children.
pub fn parse(text: &str) -> Vec<Span> {
    parse_range(text, 0, text.len())
}

/// Where a wiki link's target is written in the text: what a rename
/// rewrites. `None` for a span that is no wiki link.
pub fn wiki_target_range(text: &str, span: &Span) -> Option<Range<usize>> {
    let SpanKind::WikiLink { embed, .. } = &span.kind else { return None };
    let start = span.range.start + if *embed { 3 } else { 2 };
    let body = text.get(start..span.range.end.checked_sub(2)?)?;
    // `target`, `target|shown`, or `target\|shown` in a table.
    let written = &body[..body.find("\\|").or_else(|| body.find('|')).unwrap_or(body.len())];
    let leading = written.len() - written.trim_start().len();
    Some(start + leading..start + leading + written.trim().len())
}

/// Every span in a text, nested ones included, outermost first.
pub fn walk(spans: &[Span]) -> impl Iterator<Item = &Span> {
    spans.iter().flat_map(Span::walk)
}

/// A text with its Markdown taken out: what it says, as it is shown —
/// links by their text, emphasis without its marks, pictures and comments
/// left out.
pub fn plain_text(text: &str) -> String {
    fn emit(text: &str, range: Range<usize>, spans: &[Span], out: &mut String) {
        let mut at = range.start;
        for span in spans {
            out.push_str(&text[at..span.range.start]);
            match &span.kind {
                SpanKind::Image { .. } | SpanKind::Comment => {}
                SpanKind::WikiLink { target, label, .. } => out.push_str(label.as_deref().unwrap_or(target)),
                SpanKind::Tag(_) | SpanKind::Url => out.push_str(&text[span.range.clone()]),
                _ => emit(text, span.content.clone(), &span.children, out),
            }
            at = span.range.end;
        }
        out.push_str(&text[at..range.end]);
    }
    let mut out = String::with_capacity(text.len());
    emit(text, 0..text.len(), &parse(text), &mut out);
    out.trim().to_owned()
}

/// A style [`toggle`] puts on, or takes off.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Style {
    Strong,
    Emphasis,
    Strikethrough,
    Highlight,
    Code,
}

impl Style {
    fn delimiter(self) -> &'static str {
        match self {
            Style::Strong => "**",
            Style::Emphasis => "*",
            Style::Strikethrough => "~~",
            Style::Highlight => "==",
            Style::Code => "`",
        }
    }

    fn matches(self, kind: &SpanKind) -> bool {
        matches!(
            (self, kind),
            (Style::Strong, SpanKind::Strong)
                | (Style::Emphasis, SpanKind::Emphasis)
                | (Style::Strikethrough, SpanKind::Strikethrough)
                | (Style::Highlight, SpanKind::Highlight)
                | (Style::Code, SpanKind::Code)
        )
    }
}

/// Puts a style on a range of a text, or takes it off when the range is
/// exactly a span of that style (its content, or all of it). Gives the new
/// text, and the range the same words now have in it.
pub fn toggle(text: &str, range: Range<usize>, style: Style) -> (String, Range<usize>) {
    let spans = parse(text);
    if let Some(span) = walk(&spans).find(|s| style.matches(&s.kind) && (s.content == range || s.range == range)) {
        let mut out = String::with_capacity(text.len());
        out.push_str(&text[..span.range.start]);
        out.push_str(&text[span.content.clone()]);
        out.push_str(&text[span.range.end..]);
        return (out, span.range.start..span.range.start + span.content.len());
    }
    if range.is_empty() || range.end > text.len() || !text.is_char_boundary(range.start) || !text.is_char_boundary(range.end) {
        return (text.to_owned(), range);
    }
    let delimiter = style.delimiter();
    let out = format!("{}{delimiter}{}{delimiter}{}", &text[..range.start], &text[range.clone()], &text[range.end..]);
    (out, range.start + delimiter.len()..range.end + delimiter.len())
}

/// The picture that ends just before a place in a text, if one does: all
/// of its markup, with the size written after it — straight after, or a
/// space on, as an editor writes it. What Delete there takes out whole.
pub fn picture_before(text: &str, at: usize) -> Option<Range<usize>> {
    let spans = parse(text);
    let before = spans.iter().position(|span| span.range.end == at)?;
    match &spans[before].kind {
        SpanKind::Image { .. } => Some(spans[before].range.clone()),
        // A size parted from its picture by spaces is still the picture's.
        SpanKind::Comment if text[spans[before].range.clone()].contains('{') => {
            let picture = spans[..before].last().filter(|span| matches!(span.kind, SpanKind::Image { .. }))?;
            text[picture.range.end..spans[before].range.start].trim().is_empty().then_some(picture.range.start..at)
        }
        _ => None,
    }
}

/// A text that is a web or mail address and nothing else, trimmed: what,
/// pasted onto words, links them.
pub fn address(text: &str) -> Option<&str> {
    let text = text.trim();
    if text.is_empty() || text.contains(char::is_whitespace) {
        return None;
    }
    let (scheme, rest) = text.split_once(':')?;
    let host = |rest: &str| rest.strip_prefix("//").is_some_and(|after| !after.split(['/', '?', '#']).next().unwrap_or("").is_empty());
    match scheme.to_ascii_lowercase().as_str() {
        "http" | "https" if host(rest) => Some(text),
        "mailto" if !rest.is_empty() => Some(text),
        _ => None,
    }
}

/// Links a range of a text to an address: `[words](address)` — or, when
/// the words are a link's already, points that link there. Gives the new
/// text, and where the link ends in it. `None` when the range is empty,
/// spans lines, or is itself an address.
pub fn link_to(text: &str, range: Range<usize>, target: &str) -> Option<(String, usize)> {
    if range.is_empty() || range.end > text.len() || !text.is_char_boundary(range.start) || !text.is_char_boundary(range.end) {
        return None;
    }
    let words = &text[range.clone()];
    if words.contains(['\n', '\u{2028}']) || address(words).is_some() {
        return None;
    }
    // Brackets and spaces in an address would end its Markdown early.
    let target = target.trim().replace(' ', "%20").replace('(', "%28").replace(')', "%29");
    let spans = parse(text);
    let inside = |span: &&Span| matches!(span.kind, SpanKind::Link { .. }) && span.content.start <= range.start && range.end <= span.content.end;
    if let Some(span) = walk(&spans).find(inside) {
        // Already a link's words: only where it goes changes.
        let old = span.content.end + 2..span.range.end - 1;
        let end = span.range.end - old.len() + target.len();
        return Some((format!("{}{target}{}", &text[..old.start], &text[old.end..]), end));
    }
    let linked = format!("[{}]({target})", words.replace('[', "\\[").replace(']', "\\]"));
    let end = range.start + linked.len();
    Some((format!("{}{linked}{}", &text[..range.start], &text[range.end..]), end))
}

// --- The scanner -----------------------------------------------------------

fn parse_range(text: &str, start: usize, end: usize) -> Vec<Span> {
    let mut spans = Vec::new();
    let mut at = start;
    while at < end {
        if let Some(span) = atomic_at(text, at, start, end).or_else(|| delimited_at(text, at, start, end)) {
            at = span.range.end;
            spans.push(span);
        } else {
            at += char_len(text, at);
        }
    }
    spans
}

fn char_len(text: &str, at: usize) -> usize {
    text[at..].chars().next().map_or(1, char::len_utf8)
}

fn leaf(kind: SpanKind, range: Range<usize>, content: Range<usize>) -> Option<Span> {
    Some(Span { kind, range, content, children: Vec::new() })
}

/// A span that starts at `at` and whose inside is not searched for
/// emphasis delimiters: code, a comment, a picture, a link, a tag.
fn atomic_at(text: &str, at: usize, start: usize, end: usize) -> Option<Span> {
    let rest = &text[at..end];
    let bytes = rest.as_bytes();
    match bytes[0] {
        b'\\' => {
            let next = rest[1..].chars().next().filter(char::is_ascii_punctuation)?;
            leaf(SpanKind::Escape, at..at + 1 + next.len_utf8(), at + 1..at + 1 + next.len_utf8())
        }
        b'`' => {
            let run = bytes.iter().take_while(|b| **b == b'`').count();
            // The closing run: as many backticks, no more, on either side.
            let mut search = run;
            while let Some(found) = rest[search..].find('`') {
                let close = search + found;
                let close_run = bytes[close..].iter().take_while(|b| **b == b'`').count();
                if close_run == run && close > run {
                    return leaf(SpanKind::Code, at..at + close + run, at + run..at + close);
                }
                search = close + close_run;
            }
            None
        }
        b'<' => {
            if let Some(comment) = rest.strip_prefix("<!--") {
                let close = comment.find("-->")? + 4;
                return leaf(SpanKind::Comment, at..at + close + 3, at..at);
            }
            let inner = &rest[1..];
            if !(inner.starts_with("http://") || inner.starts_with("https://")) {
                return None;
            }
            let close = inner.find(|c: char| c.is_whitespace() || c == '<' || c == '>')?;
            if !inner[close..].starts_with('>') {
                return None;
            }
            leaf(SpanKind::Autolink { url: inner[..close].to_owned() }, at..at + close + 2, at + 1..at + 1 + close)
        }
        b'!' if rest.starts_with("![[") => wiki_link(text, at + 1, end).map(|mut span| {
            span.range.start = at;
            if let SpanKind::WikiLink { embed, .. } = &mut span.kind {
                *embed = true;
            }
            span
        }),
        b'!' if rest.starts_with("![") => image(text, at, end),
        b'[' if rest.starts_with("[[") => wiki_link(text, at, end).or_else(|| link(text, at, end)),
        b'[' => link(text, at, end),
        b'h' if rest.starts_with("http://") || rest.starts_with("https://") => {
            if text[start..at].chars().next_back().is_some_and(|c| c.is_alphanumeric() || c == '_') {
                return None;
            }
            let scheme = if rest.starts_with("https://") { 8 } else { 7 };
            let mut len = rest.find(|c: char| c.is_whitespace() || c == '<' || c == '>' || c == '\u{2028}').unwrap_or(rest.len());
            while len > scheme && rest[..len].ends_with(['.', ',', ';', ':', '!', '?', ')', ']', '\'', '"']) {
                len -= 1;
            }
            (len > scheme).then(|| leaf(SpanKind::Url, at..at + len, at..at + len)).flatten()
        }
        b'#' => {
            if text[start..at].chars().next_back().is_some_and(|c| !c.is_whitespace()) {
                return None;
            }
            let name = &rest[1..];
            if !name.chars().next()?.is_alphabetic() {
                return None;
            }
            let len = name.find(|c: char| !(c.is_alphanumeric() || matches!(c, '/' | '_' | '-'))).unwrap_or(name.len());
            leaf(SpanKind::Tag(name[..len].to_owned()), at..at + 1 + len, at + 1..at + 1 + len)
        }
        _ => None,
    }
}

/// `[[target]]` or `[[target|label]]`, starting at `at`.
fn wiki_link(text: &str, at: usize, end: usize) -> Option<Span> {
    let inner = &text[at + 2..end];
    let close = inner.find("]]")?;
    let body = &inner[..close];
    if body.contains(['[', ']', '\n']) {
        return None;
    }
    let (target, label) = match body.split_once('|') {
        // In a table a pipe is written `\|`.
        Some((target, label)) => (target.strip_suffix('\\').unwrap_or(target), Some(label)),
        None => (body, None),
    };
    if target.trim().is_empty() {
        return None;
    }
    let body_start = at + 2;
    let content = match label.filter(|l| !l.is_empty()) {
        Some(label) => body_start + body.len() - label.len()..body_start + body.len(),
        None => body_start..body_start + target.len(),
    };
    Some(Span {
        kind: SpanKind::WikiLink { target: target.trim().to_owned(), label: label.filter(|l| !l.is_empty()).map(str::to_owned), embed: false },
        range: at..body_start + close + 2,
        content,
        children: Vec::new(),
    })
}

/// `[text](target)` or `[text](target "title")`, starting at `at`.
fn link(text: &str, at: usize, end: usize) -> Option<Span> {
    let inner = &text[at + 1..end];
    let close = inner.find(['[', ']', '\n']).filter(|i| inner[*i..].starts_with("]("))?;
    if close == 0 {
        return None;
    }
    let (target, title, len) = link_destination(&inner[close + 2..], true)?;
    let content = at + 1..at + 1 + close;
    Some(Span {
        kind: SpanKind::Link { target: target.to_owned(), title: title.map(str::to_owned) },
        range: at..at + 1 + close + 2 + len,
        children: parse_range(text, content.start, content.end),
        content,
    })
}

/// What follows `](`: the address, a title when allowed, and how many
/// bytes they take, the closing `)` included.
fn link_destination(rest: &str, allow_title: bool) -> Option<(&str, Option<&str>, usize)> {
    let target_len = rest.find(|c: char| c == ')' || c.is_whitespace())?;
    let target = &rest[..target_len];
    let after = &rest[target_len..];
    if after.starts_with(')') {
        return Some((target, None, target_len + 1));
    }
    if !allow_title {
        return None;
    }
    let spaces = after.len() - after.trim_start_matches([' ', '\t']).len();
    let quoted = after[spaces..].strip_prefix('"')?;
    let title_len = quoted.find(['"', '\n']).filter(|i| quoted[*i..].starts_with("\")"))?;
    Some((target, Some(&quoted[..title_len]), target_len + spaces + 1 + title_len + 2))
}

/// `![alt](source)`, with the size comment that may follow it.
fn image(text: &str, at: usize, end: usize) -> Option<Span> {
    let inner = &text[at + 2..end];
    let close = inner.find(['[', ']', '\n']).filter(|i| inner[*i..].starts_with("]("))?;
    let (source, _, len) = link_destination(&inner[close + 2..], false)?;
    let mut range_end = at + 2 + close + 2 + len;
    let (mut width, mut height) = (None, None);
    // `<!-- {"width":425,"height":270} -->`, straight after.
    if let Some(comment) = text[range_end..end].strip_prefix("<!--") {
        if let Some(close) = comment.find("-->") {
            let json = comment[..close].trim();
            if json.starts_with('{') && json.ends_with('}') && !json[1..json.len() - 1].contains(['{', '}', '\n']) {
                width = json_number(json, "width");
                height = json_number(json, "height");
                range_end += 4 + close + 3;
            }
        }
    }
    leaf(SpanKind::Image { source: source.to_owned(), alt: inner[..close].to_owned(), width, height }, at..range_end, at..at)
}

/// A number under a key in a flat JSON object: all the size comment is.
fn json_number(json: &str, key: &str) -> Option<f64> {
    let after = &json[json.find(&format!("\"{key}\""))? + key.len() + 2..];
    let value = after.trim_start().strip_prefix(':')?.trim_start();
    let len = value.find(|c: char| !(c.is_ascii_digit() || matches!(c, '.' | '-' | '+' | 'e' | 'E'))).unwrap_or(value.len());
    value[..len].parse().ok()
}

/// Emphasis of some kind, opening at `at`.
fn delimited_at(text: &str, at: usize, start: usize, end: usize) -> Option<Span> {
    let rest = &text[at..end];
    let first = rest.as_bytes()[0];
    let before = text[start..at].chars().next_back();
    let try_delimiter = |delimiter: &str, kind: SpanKind| -> Option<Span> {
        if !rest.starts_with(delimiter) {
            return None;
        }
        let content_start = at + delimiter.len();
        let opens_on = text[content_start..end].chars().next()?;
        let mark = delimiter.as_bytes()[0] as char;
        let word_bound = kind == SpanKind::Emphasis;
        if opens_on.is_whitespace() || (delimiter.len() == 1 && opens_on == mark) || (kind == SpanKind::Highlight && opens_on == '=') {
            return None;
        }
        if word_bound && before.is_some_and(|c| c == '*' || c == '_' || c.is_alphanumeric()) {
            return None;
        }
        if kind == SpanKind::Highlight && before == Some('=') {
            return None;
        }
        // The closer: the first that can close, on the same line, outside
        // any code or link between.
        let mut search = content_start + opens_on.len_utf8();
        while search < end {
            if text.as_bytes()[search] == b'\n' {
                return None;
            }
            if let Some(skip) = atomic_at(text, search, start, end) {
                search = skip.range.end;
                continue;
            }
            if text[search..end].starts_with(delimiter) {
                let mut close = search;
                // In a longer run of the mark, the closer is its end:
                // `***both***` is strong around emphasis.
                while text[close + 1..end].starts_with(delimiter) {
                    close += 1;
                }
                let last = text[content_start..close].chars().next_back();
                let after = text[close + delimiter.len()..end].chars().next();
                let closes = last.is_some_and(|c| !c.is_whitespace() && !(delimiter.len() == 1 && c == mark))
                    && !(word_bound && after.is_some_and(|c| c == '*' || c == '_' || c.is_alphanumeric()))
                    && !(kind == SpanKind::Highlight && (after == Some('=') || last == Some('=')));
                if closes {
                    return Some(Span {
                        kind: kind.clone(),
                        range: at..close + delimiter.len(),
                        content: content_start..close,
                        children: parse_range(text, content_start, close),
                    });
                }
                search = close + delimiter.len();
                continue;
            }
            search += char_len(text, search);
        }
        None
    };
    match first {
        b'*' => try_delimiter("**", SpanKind::Strong).or_else(|| try_delimiter("*", SpanKind::Emphasis)),
        b'_' => try_delimiter("__", SpanKind::Strong).or_else(|| try_delimiter("_", SpanKind::Emphasis)),
        b'~' => try_delimiter("~~", SpanKind::Strikethrough),
        b'=' => try_delimiter("==", SpanKind::Highlight),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each top-level span as (kind, whole, content).
    fn spans(text: &str) -> Vec<(SpanKind, &str, &str)> {
        parse(text).into_iter().map(|s| (s.kind, &text[s.range], &text[s.content])).collect()
    }

    #[test]
    fn emphasis_of_every_kind() {
        assert_eq!(
            spans("**strong** *em* _em_ __strong__ ~~struck~~ ==marked== `code`"),
            [
                (SpanKind::Strong, "**strong**", "strong"),
                (SpanKind::Emphasis, "*em*", "em"),
                (SpanKind::Emphasis, "_em_", "em"),
                (SpanKind::Strong, "__strong__", "strong"),
                (SpanKind::Strikethrough, "~~struck~~", "struck"),
                (SpanKind::Highlight, "==marked==", "marked"),
                (SpanKind::Code, "`code`", "code"),
            ]
        );
    }

    #[test]
    fn what_is_not_emphasis_is_left_alone() {
        for text in [
            "a * b * c",
            "snake_case_name",
            "2 * 3 * 4",
            "** not strong **",
            "a == b == c",
            "=======",
            "<<<<<<< this device",
            "~~ no ~~",
            "*unclosed",
            "`unclosed",
            "5*3 and 4*2",
            "a*b*c",
        ] {
            assert_eq!(spans(text), [], "{text}");
        }
    }

    #[test]
    fn spans_nest() {
        let text = "***both*** and **a `code` and [link](u) in** it";
        let parsed = parse(text);
        assert_eq!(parsed[0].kind, SpanKind::Strong);
        assert_eq!(parsed[0].children[0].kind, SpanKind::Emphasis);
        assert_eq!(&text[parsed[0].children[0].content.clone()], "both");
        let kinds: Vec<_> = parsed[1].children.iter().map(|s| &s.kind).collect();
        assert_eq!(kinds, [&SpanKind::Code, &SpanKind::Link { target: "u".into(), title: None }]);
        assert_eq!(walk(&parsed).count(), 5);
    }

    #[test]
    fn code_hides_everything_in_it() {
        assert_eq!(spans("`**not** [[here]] #tag`"), [(SpanKind::Code, "`**not** [[here]] #tag`", "**not** [[here]] #tag")]);
        assert_eq!(spans("``a ` b``"), [(SpanKind::Code, "``a ` b``", "a ` b")]);
        // A delimiter cannot close inside code.
        assert_eq!(spans("*a `*` b*")[0].1, "*a `*` b*");
    }

    #[test]
    fn links_of_every_kind() {
        assert_eq!(
            spans("[text](https://a.example/x) <https://b.example> https://c.example/y. [t](u \"no card\")"),
            [
                (SpanKind::Link { target: "https://a.example/x".into(), title: None }, "[text](https://a.example/x)", "text"),
                (SpanKind::Autolink { url: "https://b.example".into() }, "<https://b.example>", "https://b.example"),
                (SpanKind::Url, "https://c.example/y", "https://c.example/y"),
                (SpanKind::Link { target: "u".into(), title: Some("no card".into()) }, "[t](u \"no card\")", "t"),
            ]
        );
        assert_eq!(spans("(see https://x.example/a_(b))"), [(SpanKind::Url, "https://x.example/a_(b", "https://x.example/a_(b")]);
        assert_eq!(spans("xhttps://no.example [broken](a b) [](empty)"), []);
    }

    #[test]
    fn wiki_links_and_embeds() {
        let wiki = |target: &str, label: Option<&str>, embed| SpanKind::WikiLink { target: target.into(), label: label.map(str::to_owned), embed };
        assert_eq!(
            spans("[[Ada Lovelace]] [[Project Atlas|the project]] ![[Embedded]] [[2026-10-31]] [[A\\|b]]"),
            [
                (wiki("Ada Lovelace", None, false), "[[Ada Lovelace]]", "Ada Lovelace"),
                (wiki("Project Atlas", Some("the project"), false), "[[Project Atlas|the project]]", "the project"),
                (wiki("Embedded", None, true), "![[Embedded]]", "Embedded"),
                (wiki("2026-10-31", None, false), "[[2026-10-31]]", "2026-10-31"),
                (wiki("A", Some("b"), false), "[[A\\|b]]", "b"),
            ]
        );
        assert_eq!(spans("[[]] [[ ]] [[a\nb]] [[unclosed"), []);
    }

    #[test]
    fn a_wiki_links_target_is_found_where_it_is_written() {
        let text = "[[ Ada ]] ![[Project Atlas|the project]] [[A\\|b]] **bold**";
        let spans = parse(text);
        let targets: Vec<_> = spans.iter().filter_map(|s| wiki_target_range(text, s)).map(|r| &text[r]).collect();
        assert_eq!(targets, ["Ada", "Project Atlas", "A"]);
    }

    #[test]
    fn images_take_their_size_comment() {
        let text = "![a cat](assets/cat.png)<!-- {\"width\":425,\"height\":270.5} --> ![](https://x.example/p.jpg) <!-- note -->";
        let parsed = parse(text);
        assert_eq!(parsed[0].kind, SpanKind::Image { source: "assets/cat.png".into(), alt: "a cat".into(), width: Some(425.0), height: Some(270.5) });
        assert_eq!(&text[parsed[0].range.clone()], "![a cat](assets/cat.png)<!-- {\"width\":425,\"height\":270.5} -->");
        assert!(parsed[0].content.is_empty());
        assert_eq!(parsed[1].kind, SpanKind::Image { source: "https://x.example/p.jpg".into(), alt: String::new(), width: None, height: None });
        assert_eq!(parsed[2].kind, SpanKind::Comment);
    }

    #[test]
    fn tags_start_a_word() {
        assert_eq!(
            spans("#planning and #work/deep-focus, not a#b or #1 or # x; #ünï"),
            [
                (SpanKind::Tag("planning".into()), "#planning", "planning"),
                (SpanKind::Tag("work/deep-focus".into()), "#work/deep-focus", "work/deep-focus"),
                (SpanKind::Tag("ünï".into()), "#ünï", "ünï"),
            ]
        );
    }

    #[test]
    fn escapes_are_literal() {
        assert_eq!(
            spans("\\*not em\\* \\[\\[no]]"),
            [(SpanKind::Escape, "\\*", "*"), (SpanKind::Escape, "\\*", "*"), (SpanKind::Escape, "\\[", "["), (SpanKind::Escape, "\\[", "["),]
        );
    }

    #[test]
    fn plain_text_is_what_is_shown() {
        assert_eq!(
            plain_text("Kick-off with [[Ada Lovelace|Ada]] on **[[2026-10-31]]** #planning ![x](a.png)<!-- {\"width\":1} --> see [the *docs*](https://d.example) \\* `code`<!-- hidden -->"),
            "Kick-off with Ada on 2026-10-31 #planning  see the docs * code"
        );
        assert_eq!(plain_text("  plain  "), "plain");
    }

    #[test]
    fn toggling_puts_a_style_on_and_takes_it_off() {
        let (bold, range) = toggle("make this bold", 5..9, Style::Strong);
        assert_eq!((bold.as_str(), &bold[range.clone()]), ("make **this** bold", "this"));
        let (plain, range) = toggle(&bold, range, Style::Strong);
        assert_eq!((plain.as_str(), &plain[range]), ("make this bold", "this"));
        // The whole span selected, markup and all, comes off too.
        assert_eq!(toggle("a `b` c", 2..5, Style::Code).0, "a b c");
        // A different style goes on around it.
        assert_eq!(toggle("a **b** c", 4..5, Style::Emphasis).0, "a ***b*** c");
        assert_eq!(toggle("abc", 1..1, Style::Strong).0, "abc");
    }

    #[test]
    fn multibyte_text_is_never_split() {
        for text in ["é*è*ü", "日本語 **太字** #タグ [[ノート]]", "🙂 ==🙃== `🙂`", "\\é *", "“[x](y)”"] {
            for span in walk(&parse(text)) {
                assert!(text.is_char_boundary(span.range.start) && text.is_char_boundary(span.range.end));
                assert!(text.is_char_boundary(span.content.start) && text.is_char_boundary(span.content.end));
            }
            let _ = plain_text(text);
        }
    }
}
