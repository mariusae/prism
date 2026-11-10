//! Typed fields: what a tag says the pages tagged with it hold.
//!
//! A tag's own page lists, in its frontmatter, the fields of the pages
//! tagged with it — a bare name for text:
//!
//! ```yaml
//! fields:
//!   - birthday (date)
//!   - company (link)
//!   - status (active | paused | done)
//!   - rating (number)
//!   - website (url)
//!   - met (yes/no)
//!   - notes
//! ```
//!
//! Values stay frontmatter text; a [`FieldKind`] says how to read one
//! ([`FieldKind::read`]) so an app can show a date picker for a date and
//! a menu for a choice.

use crate::date::Day;
use crate::frontmatter::Frontmatter;
use std::fmt;

/// The frontmatter key a tag's page keeps its field specs under.
pub const FIELDS_KEY: &str = "fields";

/// What kind of value a field holds.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum FieldKind {
    Text,
    Number,
    /// A day, `2026-10-31` — and so a link to that day's page.
    Date,
    /// A page's title.
    Link,
    /// A web address.
    Url,
    /// Yes or no.
    Flag,
    /// One of these options.
    Choice(Vec<String>),
}

/// A field a tag gives every page tagged with it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FieldSpec {
    pub name: String,
    pub kind: FieldKind,
}

/// A field's value, read as its kind.
#[derive(Debug, Clone, PartialEq)]
pub enum FieldValue {
    Text(String),
    Number(f64),
    Date(Day),
    /// The title linked to, without any `[[ ]]` it was written in.
    Link(String),
    Url(String),
    Flag(bool),
    /// The option chosen, spelled as the spec spells it.
    Choice(String),
}

impl FieldSpec {
    pub fn new(name: impl Into<String>, kind: FieldKind) -> FieldSpec {
        FieldSpec { name: name.into(), kind }
    }

    /// Reads a spec as a tag's page writes it: `birthday (date)`,
    /// `status (active | paused)`, or a bare name for text. A kind not
    /// known is text, so a newer app's kinds degrade rather than vanish.
    pub fn parse(item: &str) -> Option<FieldSpec> {
        let item = item.trim();
        if item.is_empty() {
            return None;
        }
        let Some((name, kind)) = item.strip_suffix(')').and_then(|rest| rest.rsplit_once('(')) else {
            return Some(FieldSpec::new(item, FieldKind::Text));
        };
        let (name, kind) = (name.trim(), kind.trim());
        if name.is_empty() {
            return None;
        }
        let kind = if kind.contains('|') {
            FieldKind::Choice(kind.split('|').map(|option| option.trim().to_owned()).filter(|option| !option.is_empty()).collect())
        } else {
            match kind.to_lowercase().as_str() {
                "date" | "day" => FieldKind::Date,
                "number" => FieldKind::Number,
                "link" | "page" | "tiddler" => FieldKind::Link,
                "url" | "web" | "web address" => FieldKind::Url,
                "yes/no" | "flag" | "bool" | "yes or no" => FieldKind::Flag,
                _ => FieldKind::Text,
            }
        };
        Some(FieldSpec::new(name, kind))
    }

    /// The specs a tag's page gives, from its frontmatter.
    pub fn of(frontmatter: &Frontmatter) -> Vec<FieldSpec> {
        frontmatter.list(FIELDS_KEY).iter().filter_map(|item| FieldSpec::parse(item)).collect()
    }
}

impl fmt::Display for FieldSpec {
    /// The spec as its line in the tag's `fields`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.kind {
            FieldKind::Text => write!(f, "{}", self.name),
            FieldKind::Number => write!(f, "{} (number)", self.name),
            FieldKind::Date => write!(f, "{} (date)", self.name),
            FieldKind::Link => write!(f, "{} (link)", self.name),
            FieldKind::Url => write!(f, "{} (url)", self.name),
            FieldKind::Flag => write!(f, "{} (yes/no)", self.name),
            FieldKind::Choice(options) => write!(f, "{} ({})", self.name, options.join(" | ")),
        }
    }
}

impl FieldKind {
    /// Reads a frontmatter value as this kind. `None` when the text is
    /// not a value of the kind — a date that is no date, a choice not
    /// among the options — which an app shows as the text it is.
    pub fn read(&self, text: &str) -> Option<FieldValue> {
        let text = text.trim();
        match self {
            FieldKind::Text => Some(FieldValue::Text(text.to_owned())),
            FieldKind::Number => text.parse().ok().filter(|n: &f64| n.is_finite()).map(FieldValue::Number),
            FieldKind::Date => Day::parse(unbracket(text)).map(FieldValue::Date),
            FieldKind::Link => Some(unbracket(text)).filter(|t| !t.is_empty()).map(|t| FieldValue::Link(t.to_owned())),
            FieldKind::Url => (text.starts_with("http://") || text.starts_with("https://")).then(|| FieldValue::Url(text.to_owned())),
            FieldKind::Flag => match text.to_lowercase().as_str() {
                "yes" | "true" | "on" | "1" | "y" => Some(FieldValue::Flag(true)),
                "no" | "false" | "off" | "0" | "n" => Some(FieldValue::Flag(false)),
                _ => None,
            },
            FieldKind::Choice(options) => options.iter().find(|option| option.eq_ignore_ascii_case(text)).map(|option| FieldValue::Choice(option.clone())),
        }
    }
}

impl FieldValue {
    /// The value as frontmatter text.
    pub fn to_text(&self) -> String {
        match self {
            FieldValue::Text(text) | FieldValue::Link(text) | FieldValue::Url(text) | FieldValue::Choice(text) => text.clone(),
            FieldValue::Number(n) if n.fract() == 0.0 && n.abs() < 1e15 => format!("{n:.0}"),
            FieldValue::Number(n) => n.to_string(),
            FieldValue::Date(day) => day.to_string(),
            FieldValue::Flag(true) => "yes".into(),
            FieldValue::Flag(false) => "no".into(),
        }
    }
}

/// `[[Title]]` or `[[Title|shown]]` as `Title`; anything else as it is.
fn unbracket(text: &str) -> &str {
    match text.strip_prefix("[[").and_then(|inner| inner.strip_suffix("]]")) {
        Some(inner) => inner.split('|').next().unwrap_or(inner).trim(),
        None => text,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn specs_read_and_write_back() {
        let source = "---\nfields:\n  - birthday (date)\n  - company (link)\n  - status (active | paused | done)\n  - rating (number)\n  - website (url)\n  - met (yes/no)\n  - notes\n  - odd (hologram)\n  - (nameless)\n---\n";
        let front = Frontmatter::split(source).0.unwrap();
        let specs = FieldSpec::of(&front);
        let lines: Vec<String> = specs.iter().map(FieldSpec::to_string).collect();
        assert_eq!(
            lines,
            ["birthday (date)", "company (link)", "status (active | paused | done)", "rating (number)", "website (url)", "met (yes/no)", "notes", "odd"]
        );
        assert_eq!(specs[2].kind, FieldKind::Choice(vec!["active".into(), "paused".into(), "done".into()]));
        assert_eq!(FieldSpec::parse("Has (parens) inside (Date)").unwrap(), FieldSpec::new("Has (parens) inside", FieldKind::Date));
        assert_eq!(FieldSpec::parse("  "), None);
    }

    #[test]
    fn values_are_read_as_their_kind() {
        assert_eq!(FieldKind::Date.read(" 2026-10-31 "), Some(FieldValue::Date(Day::parse("2026-10-31").unwrap())));
        assert_eq!(FieldKind::Date.read("[[2026-10-31]]"), Some(FieldValue::Date(Day::parse("2026-10-31").unwrap())));
        assert_eq!(FieldKind::Date.read("soon"), None);
        assert_eq!(FieldKind::Link.read("[[Ada Lovelace|Ada]]"), Some(FieldValue::Link("Ada Lovelace".into())));
        assert_eq!(FieldKind::Link.read("Ada Lovelace"), Some(FieldValue::Link("Ada Lovelace".into())));
        assert_eq!(FieldKind::Number.read("4.5"), Some(FieldValue::Number(4.5)));
        assert_eq!(FieldKind::Number.read("four"), None);
        assert_eq!(FieldKind::Number.read("NaN"), None);
        assert_eq!(FieldKind::Url.read("https://x.example"), Some(FieldValue::Url("https://x.example".into())));
        assert_eq!(FieldKind::Url.read("x.example"), None);
        assert_eq!(FieldKind::Flag.read("Yes"), Some(FieldValue::Flag(true)));
        assert_eq!(FieldKind::Flag.read("no"), Some(FieldValue::Flag(false)));
        assert_eq!(FieldKind::Flag.read("maybe"), None);
        let status = FieldKind::Choice(vec!["Active".into(), "Done".into()]);
        assert_eq!(status.read("active"), Some(FieldValue::Choice("Active".into())));
        assert_eq!(status.read("archived"), None);
        assert_eq!(FieldKind::Text.read(" anything "), Some(FieldValue::Text("anything".into())));
    }

    #[test]
    fn values_write_as_frontmatter_text() {
        assert_eq!(FieldValue::Number(4.0).to_text(), "4");
        assert_eq!(FieldValue::Number(4.5).to_text(), "4.5");
        assert_eq!(FieldValue::Flag(true).to_text(), "yes");
        assert_eq!(FieldValue::Date(Day::parse("2026-10-31").unwrap()).to_text(), "2026-10-31");
        assert_eq!(FieldValue::Link("Ada".into()).to_text(), "Ada");
    }
}
