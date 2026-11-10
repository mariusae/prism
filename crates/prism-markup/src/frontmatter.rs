//! Frontmatter: the block of `key: value` lines a note may start with.
//!
//! Only YAML's plainest part is read: `key: value`, quoted or not; lists as
//! `[a, b]` or one `- item` a line; `|` and `>` blocks. Every value is text
//! or a list of text — no numbers, no nesting — which is all a note's
//! fields need, and small enough to write back exactly.
//!
//! **Lossless by construction.** Each entry keeps the lines it was read
//! from. Writing a [`Frontmatter`] back emits those lines untouched, so
//! comments, key order, quoting and spacing survive; only an entry that
//! was [`set`](Frontmatter::set) is written anew.

use std::fmt;

/// A frontmatter value: text, or a list of text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Text(String),
    List(Vec<String>),
}

impl Value {
    pub fn as_text(&self) -> Option<&str> {
        match self {
            Value::Text(text) => Some(text),
            Value::List(_) => None,
        }
    }

    pub fn as_list(&self) -> Option<&[String]> {
        match self {
            Value::List(items) => Some(items),
            Value::Text(_) => None,
        }
    }

    /// The value as a list: a list's items, or text as a list of one —
    /// `tags: Work` and `tags: [Work]` mean the same.
    pub fn to_list(&self) -> Vec<String> {
        match self {
            Value::List(items) => items.clone(),
            Value::Text(text) if text.trim().is_empty() => Vec::new(),
            Value::Text(text) => vec![text.clone()],
        }
    }
}

impl From<&str> for Value {
    fn from(text: &str) -> Value {
        Value::Text(text.to_owned())
    }
}

impl From<String> for Value {
    fn from(text: String) -> Value {
        Value::Text(text)
    }
}

impl From<Vec<String>> for Value {
    fn from(items: Vec<String>) -> Value {
        Value::List(items)
    }
}

/// One entry, or a line that is none (blank, a comment), with its lines as
/// written — line endings excluded.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Entry {
    key: Option<String>,
    lines: Vec<String>,
    value: Option<Value>,
}

/// A note's frontmatter, fences and all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frontmatter {
    /// The opening fence, as written (`---`, maybe with trailing spaces).
    open: String,
    entries: Vec<Entry>,
    /// The closing fence: `---` or `...`.
    close: String,
    /// `\n` or `\r\n`.
    newline: &'static str,
}

impl Default for Frontmatter {
    fn default() -> Self {
        Frontmatter::new()
    }
}

impl Frontmatter {
    /// An empty frontmatter, to be filled with [`set`](Self::set).
    pub fn new() -> Frontmatter {
        Frontmatter { open: "---".into(), entries: Vec::new(), close: "---".into(), newline: "\n" }
    }

    /// Splits a note's source into its frontmatter and its body.
    ///
    /// Frontmatter is there when the first line is `---` and a later line
    /// is `---` or `...`; otherwise the whole source is body. The two
    /// returned pieces always concatenate back to `source` when the
    /// frontmatter is written with `to_string`.
    pub fn split(source: &str) -> (Option<Frontmatter>, &str) {
        let mut lines = LineCursor::new(source);
        let Some((open, ending)) = lines.next() else { return (None, source) };
        if open.trim_end_matches([' ', '\t']) != "---" || ending.is_empty() {
            return (None, source);
        }
        let newline = if ending == "\r\n" { "\r\n" } else { "\n" };
        let mut body: Vec<&str> = Vec::new();
        while let Some((line, line_ending)) = lines.next() {
            let fence = line.trim_end_matches([' ', '\t']);
            if fence == "---" || fence == "..." {
                // A header whose lines end differently from its fence would
                // not write back the same: leave such a file all body.
                if (!line_ending.is_empty() && line_ending != newline) || body.iter().any(|l| l.ends_with('\r')) {
                    return (None, source);
                }
                let mut frontmatter = Frontmatter { open: open.to_owned(), entries: Vec::new(), close: line.to_owned(), newline };
                frontmatter.entries = parse_entries(&body);
                // A closing fence at the very end of the file, with no line
                // break after it, is the one shape `to_string` cannot give
                // back; such a note is rare enough to be read as all body.
                if line_ending.is_empty() {
                    return (None, source);
                }
                return (Some(frontmatter), &source[lines.offset..]);
            }
            if newline == "\n" && line_ending == "\r\n" {
                return (None, source);
            }
            body.push(line);
        }
        (None, source)
    }

    /// The value of a key, the first of that name.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries.iter().find(|e| e.key.as_deref() == Some(key)).and_then(|e| e.value.as_ref())
    }

    /// A key's text, when it holds text.
    pub fn text(&self, key: &str) -> Option<&str> {
        self.get(key).and_then(Value::as_text)
    }

    /// A key's items: a list's, or one for text; empty when there is none.
    pub fn list(&self, key: &str) -> Vec<String> {
        self.get(key).map(Value::to_list).unwrap_or_default()
    }

    /// Whether a key marks the note: it is there, with a value that
    /// does not say no ([`is_set`]). `private: true`, `pinned: 3` and
    /// `topic: Maths` all mark; `inbox: no` and a bare `inbox:` do not.
    pub fn flag(&self, key: &str) -> bool {
        self.get(key).is_some_and(|value| value.to_list().first().is_some_and(|first| is_set(first)))
    }

    pub fn contains(&self, key: &str) -> bool {
        self.entries.iter().any(|e| e.key.as_deref() == Some(key))
    }

    /// The keys, in the order written.
    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.entries.iter().filter_map(|e| e.key.as_deref())
    }

    /// Every entry, in the order written.
    pub fn iter(&self) -> impl Iterator<Item = (&str, &Value)> {
        self.entries.iter().filter_map(|e| Some((e.key.as_deref()?, e.value.as_ref()?)))
    }

    pub fn is_empty(&self) -> bool {
        self.entries.iter().all(|e| e.key.is_none())
    }

    /// Sets a key's value. An entry already holding exactly this value is
    /// left as it was written; one holding another is rewritten in place;
    /// a new key goes at the end.
    pub fn set(&mut self, key: &str, value: impl Into<Value>) {
        let value = value.into();
        if let Some(entry) = self.entries.iter_mut().find(|e| e.key.as_deref() == Some(key)) {
            if entry.value.as_ref() == Some(&value) {
                return;
            }
            // A list written an item a line stays so, whatever its length:
            // one line an item is what lets git merge two devices' changes.
            let was_block_list = matches!(entry.value, Some(Value::List(_))) && entry.lines.len() > 1;
            entry.lines = write_entry(key, &value, was_block_list);
            entry.value = Some(value);
        } else {
            self.entries.push(Entry { key: Some(key.to_owned()), lines: write_entry(key, &value, false), value: Some(value) });
        }
    }

    /// Sets a key to a list written an item a line, however short: for a
    /// list two devices may both add to, so that git merges the two.
    pub fn set_list_by_line(&mut self, key: &str, items: Vec<String>) {
        let value = Value::List(items);
        let lines = write_entry(key, &value, true);
        match self.entries.iter_mut().find(|e| e.key.as_deref() == Some(key)) {
            Some(entry) if entry.lines == lines => {}
            Some(entry) => {
                entry.lines = lines;
                entry.value = Some(value);
            }
            None => self.entries.push(Entry { key: Some(key.to_owned()), lines, value: Some(value) }),
        }
    }

    /// Takes a key out, with its lines. Says whether it was there.
    pub fn remove(&mut self, key: &str) -> bool {
        let before = self.entries.len();
        self.entries.retain(|e| e.key.as_deref() != Some(key));
        self.entries.len() != before
    }
}

impl fmt::Display for Frontmatter {
    /// The block as it goes in a file: both fences, each line ended.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}{}", self.open, self.newline)?;
        for line in self.entries.iter().flat_map(|e| &e.lines) {
            write!(f, "{line}{}", self.newline)?;
        }
        write!(f, "{}{}", self.close, self.newline)
    }
}

/// What a text says, read as yes or no: `true`, `yes`, `on`, `1`, `y` —
/// `false`, `no`, `off`, `0`, `n` — case aside. `None` for anything
/// else. The one reading of yes and no there is.
pub fn truth(text: &str) -> Option<bool> {
    match text.trim().to_ascii_lowercase().as_str() {
        "true" | "yes" | "on" | "1" | "y" => Some(true),
        "false" | "no" | "off" | "0" | "n" => Some(false),
        _ => None,
    }
}

/// Whether a field's value marks its note: anything but nothing, and
/// anything but no. What `is: pinned` asks, whether the page says
/// `pinned: true` or `pinned: 3`.
pub fn is_set(text: &str) -> bool {
    !text.trim().is_empty() && truth(text) != Some(false)
}

/// Walks a text's lines, giving each without its ending, and the ending.
struct LineCursor<'a> {
    source: &'a str,
    offset: usize,
}

impl<'a> LineCursor<'a> {
    fn new(source: &'a str) -> Self {
        LineCursor { source, offset: 0 }
    }

    fn next(&mut self) -> Option<(&'a str, &'a str)> {
        if self.offset >= self.source.len() {
            return None;
        }
        let rest = &self.source[self.offset..];
        let (line, ending) = match rest.find('\n') {
            Some(at) if at > 0 && rest.as_bytes()[at - 1] == b'\r' => (&rest[..at - 1], "\r\n"),
            Some(at) => (&rest[..at], "\n"),
            None => (rest, ""),
        };
        self.offset += line.len() + ending.len();
        Some((line, ending))
    }
}

// --- Reading ---------------------------------------------------------------

fn parse_entries(lines: &[&str]) -> Vec<Entry> {
    let mut entries = Vec::new();
    let mut index = 0;
    while index < lines.len() {
        let line = lines[index];
        index += 1;
        let first = line.chars().next();
        let colon = match first {
            Some(c) if c != '#' && !c.is_whitespace() && c != '-' => key_colon(line),
            _ => None,
        };
        let Some(colon) = colon else {
            entries.push(Entry { key: None, lines: vec![line.to_owned()], value: None });
            continue;
        };
        let start = index;
        // What follows the key and belongs to it: indented lines, or a
        // list's `- ` items at the left edge.
        while index < lines.len() && lines[index].starts_with([' ', '\t', '-']) {
            index += 1;
        }
        let rest = &lines[start..index];
        let key = unquote_key(line[..colon].trim());
        let value = parse_value(line[colon + 1..].trim(), rest);
        let mut entry_lines = vec![line.to_owned()];
        entry_lines.extend(rest.iter().map(|l| (*l).to_owned()));
        entries.push(Entry { key: Some(key), lines: entry_lines, value: Some(value) });
    }
    entries
}

/// The colon ending a key: the first followed by a space or the line's
/// end, outside a quote the line opens with.
fn key_colon(line: &str) -> Option<usize> {
    let mut quote: Option<char> = None;
    let mut chars = line.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        match quote {
            Some(open) => {
                if c == open {
                    quote = None;
                }
            }
            None if (c == '"' || c == '\'') && at == 0 => quote = Some(c),
            None if c == ':' && chars.peek().is_none_or(|&(_, next)| next == ' ' || next == '\t') => return Some(at),
            None => {}
        }
    }
    None
}

fn unquote_key(key: &str) -> String {
    let mut chars = key.chars();
    match (chars.next(), chars.next_back()) {
        (Some(first), Some(last)) if (first == '"' || first == '\'') && first == last => unquote(key),
        _ => key.to_owned(),
    }
}

fn parse_value(inline: &str, rest: &[&str]) -> Value {
    if inline.starts_with(['|', '>']) {
        return Value::Text(block_scalar(inline, rest));
    }
    if inline.starts_with('[') {
        return Value::List(flow_list(inline));
    }
    if inline.is_empty() && !rest.is_empty() && rest.iter().all(|l| l.trim().starts_with('-')) {
        return Value::List(rest.iter().map(|item| scalar(item.trim()[1..].trim())).collect());
    }
    let mut parts = vec![inline];
    parts.extend(rest.iter().map(|l| l.trim()));
    if inline.starts_with(['"', '\'']) {
        // A quoted value may run on over lines; they are joined by spaces.
        return Value::Text(unquote(&parts.join(" ")));
    }
    Value::Text(parts.into_iter().map(strip_comment).filter(|p| !p.is_empty()).collect::<Vec<_>>().join(" "))
}

fn scalar(text: &str) -> String {
    if text.starts_with(['"', '\'']) {
        unquote(text)
    } else {
        strip_comment(text).to_owned()
    }
}

fn strip_comment(text: &str) -> &str {
    match text.find(" #") {
        Some(at) => text[..at].trim(),
        None => text,
    }
}

/// `|`, `|-`, `|+` (and `>`, folded) with the lines under it, unindented.
fn block_scalar(indicator: &str, lines: &[&str]) -> String {
    let folded = indicator.starts_with('>');
    let indent = lines.iter().find(|l| !l.trim().is_empty()).map_or(0, |l| l.len() - l.trim_start_matches(' ').len());
    let mut body: Vec<&str> = lines.iter().map(|l| l.get(indent..).unwrap_or("")).collect();
    let mut trailing = 0;
    while body.last().is_some_and(|l| l.is_empty()) {
        body.pop();
        trailing += 1;
    }
    let mut text = body.join(if folded { " " } else { "\n" });
    if indicator.contains('+') {
        text.push_str(&"\n".repeat(trailing + 1));
    } else if !indicator.contains('-') {
        text.push('\n');
    }
    text
}

fn flow_list(text: &str) -> Vec<String> {
    let inner = &text[1..];
    let inner = inner.rfind(']').map_or(inner, |end| &inner[..end]);
    let mut items = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut escaped = false;
    for c in inner.chars() {
        if let Some(open) = quote {
            current.push(c);
            if open == '"' && c == '\\' && !escaped {
                escaped = true;
                continue;
            }
            if c == open && !escaped {
                quote = None;
            }
            escaped = false;
        } else if (c == '"' || c == '\'') && current.trim().is_empty() {
            quote = Some(c);
            current.push(c);
        } else if c == ',' {
            items.push(std::mem::take(&mut current));
        } else {
            current.push(c);
        }
    }
    items.push(current);
    // An empty item is a trailing comma's.
    items.iter().map(|i| i.trim()).filter(|i| !i.is_empty()).map(scalar).collect()
}

fn unquote(text: &str) -> String {
    let mut chars = text.chars();
    let Some(quote) = chars.next().filter(|c| *c == '"' || *c == '\'') else { return text.to_owned() };
    let mut body = chars.as_str();
    if body.ends_with(quote) {
        body = &body[..body.len() - 1];
    }
    if quote == '\'' {
        return body.replace("''", "'");
    }
    let mut result = String::with_capacity(body.len());
    let mut chars = body.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            result.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => result.push('\n'),
            Some('t') => result.push('\t'),
            Some('r') => result.push('\r'),
            Some('0') => result.push('\0'),
            Some(kind @ ('u' | 'x')) => {
                let hex: String = chars.by_ref().take(if kind == 'u' { 4 } else { 2 }).collect();
                if let Some(c) = u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32) {
                    result.push(c);
                }
            }
            Some(other) => result.push(other),
            None => result.push('\\'),
        }
    }
    result
}

// --- Writing ---------------------------------------------------------------

fn write_entry(key: &str, value: &Value, keep_block_list: bool) -> Vec<String> {
    let name = if is_plain(key, true) { key.to_owned() } else { quote(key) };
    match value {
        Value::Text(text) => {
            if text.contains('\n') {
                if let Some((indicator, lines)) = block_lines(text) {
                    let mut out = vec![format!("{name}: {indicator}")];
                    out.extend(lines);
                    return out;
                }
            }
            vec![format!("{name}: {}", scalar_text(text, false))]
        }
        Value::List(items) if items.is_empty() => vec![format!("{name}: []")],
        Value::List(items) => {
            let flow = format!("[{}]", items.iter().map(|i| scalar_text(i, true)).collect::<Vec<_>>().join(", "));
            // Short lists on one line; long ones an item a line, so that
            // git merges changes to different items.
            if !keep_block_list && items.len() <= 4 && flow.chars().count() <= 60 {
                return vec![format!("{name}: {flow}")];
            }
            let mut out = vec![format!("{name}:")];
            out.extend(items.iter().map(|i| format!("  - {}", scalar_text(i, false))));
            out
        }
    }
}

fn block_lines(text: &str) -> Option<(&'static str, Vec<String>)> {
    if text.contains(['\r', '\t']) || text.starts_with([' ', '\n']) {
        return None;
    }
    let body = text.trim_end_matches('\n');
    let trailing = text.len() - body.len();
    let indicator = match trailing {
        0 => "|-",
        1 => "|",
        _ => "|+",
    };
    let mut lines: Vec<String> = body.split('\n').map(|l| if l.is_empty() { String::new() } else { format!("  {l}") }).collect();
    lines.extend(std::iter::repeat_n(String::new(), trailing.saturating_sub(1)));
    Some((indicator, lines))
}

fn scalar_text(text: &str, in_flow: bool) -> String {
    if is_plain(text, in_flow) {
        text.to_owned()
    } else {
        quote(text)
    }
}

/// Whether text reads back as itself when written without quotes.
fn is_plain(text: &str, in_flow: bool) -> bool {
    let (Some(first), Some(last)) = (text.chars().next(), text.chars().next_back()) else { return false };
    if first.is_whitespace() || last.is_whitespace() || "-?:,[]{}#&*!|>'\"%@`".contains(first) {
        return false;
    }
    if text.contains(": ") || text.contains(" #") || last == ':' {
        return false;
    }
    if text.chars().any(|c| c.is_control()) {
        return false;
    }
    if in_flow && text.contains([',', '[', ']', '{', '}']) {
        return false;
    }
    // `true`, `yes`, `4` are written plain: flags and numbers as YAML reads
    // them, and text here, which every value is.
    !matches!(text.to_ascii_lowercase().as_str(), "null" | "~")
}

fn quote(text: &str) -> String {
    let mut result = String::with_capacity(text.len() + 2);
    result.push('"');
    for c in text.chars() {
        match c {
            '"' => result.push_str("\\\""),
            '\\' => result.push_str("\\\\"),
            '\n' => result.push_str("\\n"),
            '\t' => result.push_str("\\t"),
            '\r' => result.push_str("\\r"),
            c if (c as u32) < 0x20 => result.push_str(&format!("\\x{:02x}", c as u32)),
            c => result.push(c),
        }
    }
    result.push('"');
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE: &str = "---\nid: 01jbxk3t6y8q2zp4m9v7c5r0wd\naliases: [Atlas, \"A, B\"]\ntags: [Projects]\n# a comment\nwiki: true\nstatus:   active  # for now\nrelated:\n  - Ada Lovelace\n  - \"[[2026-10-31]]\"\nsummary: |\n  Two lines\n  of text\n---\n# Project Atlas\n";

    fn front(source: &str) -> Frontmatter {
        Frontmatter::split(source).0.expect("frontmatter")
    }

    #[test]
    fn reads_scalars_lists_and_blocks() {
        let (front, body) = Frontmatter::split(PAGE);
        let front = front.unwrap();
        assert_eq!(body, "# Project Atlas\n");
        assert_eq!(front.text("id"), Some("01jbxk3t6y8q2zp4m9v7c5r0wd"));
        assert_eq!(front.list("aliases"), ["Atlas", "A, B"]);
        assert_eq!(front.list("tags"), ["Projects"]);
        assert!(front.flag("wiki"));
        assert_eq!(front.text("status"), Some("active"));
        assert_eq!(front.list("related"), ["Ada Lovelace", "[[2026-10-31]]"]);
        assert_eq!(front.text("summary"), Some("Two lines\nof text\n"));
        assert_eq!(front.keys().collect::<Vec<_>>(), ["id", "aliases", "tags", "wiki", "status", "related", "summary"]);
        assert_eq!(front.get("missing"), None);
    }

    #[test]
    fn writes_back_what_it_read_byte_for_byte() {
        for source in [
            PAGE,
            "---\n---\nbody",
            "---  \ntitle: 'It''s'\n...\n",
            "---\r\ntitle: Windows\r\ntags:\r\n- a\r\n- b\r\n---\r\nbody\r\n",
            "---\nweird line without colon\n\nkey: value\n---\n",
        ] {
            let (front, body) = Frontmatter::split(source);
            assert_eq!(format!("{}{body}", front.expect(source)), source);
        }
    }

    #[test]
    fn a_file_without_a_closed_block_is_all_body() {
        for source in ["# Title\n", "---\nnever closed\n", "", "--- not a fence\n---\n", "text\n---\na: b\n---\n", "---\na: b\n---"] {
            let (front, body) = Frontmatter::split(source);
            assert!(front.is_none(), "{source:?}");
            assert_eq!(body, source);
        }
    }

    #[test]
    fn setting_rewrites_only_the_entry_set() {
        let mut front = front(PAGE);
        front.set("status", "done");
        front.set("wiki", "true"); // unchanged: its line is left alone
        front.set("rating", "5");
        let written = front.to_string();
        let header = PAGE.strip_suffix("# Project Atlas\n").unwrap();
        let expected = header.replace("status:   active  # for now", "status: done").replace("  of text\n---\n", "  of text\nrating: 5\n---\n");
        assert_eq!(written, expected);
        assert!(written.contains("# a comment\nwiki: true\n"));
    }

    #[test]
    fn lists_keep_their_shape_and_values_are_quoted_when_they_must_be() {
        let mut front = front(PAGE);
        front.set("related", vec!["Ada Lovelace".to_owned(), "Grace: Hopper".to_owned()]);
        front.set("tags", vec!["Projects".to_owned(), "a, b".to_owned(), "#x".to_owned()]);
        front.set("note", "line one\nline two");
        front.set("empty", Vec::<String>::new());
        front.set("odd key: here", " padded ");
        let written = front.to_string();
        assert!(written.contains("related:\n  - Ada Lovelace\n  - \"Grace: Hopper\"\n"), "{written}");
        assert!(written.contains("tags: [Projects, \"a, b\", \"#x\"]\n"), "{written}");
        assert!(written.contains("note: |-\n  line one\n  line two\n"), "{written}");
        assert!(written.contains("empty: []\n"));
        assert!(written.contains("\"odd key: here\": \" padded \"\n"));
        // And all of it reads back as it was set.
        let again = self::front(&written);
        assert_eq!(again.list("related"), ["Ada Lovelace", "Grace: Hopper"]);
        assert_eq!(again.list("tags"), ["Projects", "a, b", "#x"]);
        assert_eq!(again.text("note"), Some("line one\nline two"));
        assert_eq!(again.list("empty"), Vec::<String>::new());
        assert_eq!(again.text("odd key: here"), Some(" padded "));
    }

    #[test]
    fn long_lists_go_an_item_a_line() {
        let mut front = Frontmatter::new();
        front.set("tags", (1..=5).map(|n| format!("tag{n}")).collect::<Vec<_>>());
        assert_eq!(front.to_string(), "---\ntags:\n  - tag1\n  - tag2\n  - tag3\n  - tag4\n  - tag5\n---\n");
    }

    #[test]
    fn removing_takes_the_entrys_lines() {
        let mut front = front(PAGE);
        assert!(front.remove("related"));
        assert!(!front.remove("related"));
        assert!(!front.to_string().contains("Ada"));
        assert!(front.to_string().contains("status:   active  # for now\nsummary: |\n"));
    }

    #[test]
    fn escapes_read_as_yaml_reads_them() {
        let front = front("---\na: \"tab\\there \\u00e9 \\\"q\\\"\"\nb: 'single ''quoted'''\nc: \"runs\n  on\"\nd: >-\n  folded\n  text\n---\n");
        assert_eq!(front.text("a"), Some("tab\there é \"q\""));
        assert_eq!(front.text("b"), Some("single 'quoted'"));
        assert_eq!(front.text("c"), Some("runs on"));
        assert_eq!(front.text("d"), Some("folded text"));
    }
}
