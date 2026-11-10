//! Saved rivers: a named run of cards, kept as a file.
//!
//! Weft shows pages as cards in a river; a river worth keeping is saved
//! in the graph's `rivers/` folder, so it syncs like anything else and
//! folds the same on every device:
//!
//! ```markdown
//! ---
//! folded:
//!   - Beta
//! ---
//! - [[Alpha]]
//!   - 4: Projects
//! - [[Beta]]
//! ```
//!
//! A card is a link a line. Under it, indented, the rows folded in it:
//! each row's place among the card's rows, and its text. The cards
//! showing only their titles are the frontmatter's `folded`.
//!
//! A **query river** also has a query: its cards are those the query
//! finds, after the cards before the block (put at its top by hand), with
//! the cards after it placed among what it finds:
//!
//! ````markdown
//! - [[Pinned]]
//!
//! ```query
//! sort: -modified
//! ```
//! - [[Kept Here]] @ 1000 2026-11-03T10:00:00.000Z
//! ````
//!
//! A river is not a page: nothing resolves to it as a title, and a link
//! to one is written to its file — `[[rivers/Work]]` — so it reads
//! plainly wherever the graph goes ([`name_of`], [`link`]).
//!
//! But its file is Markdown like any note's, and its cards are links
//! like any other. So a river needs no renaming of its own: read as a
//! [`Note`](crate::Note), [`Note::relink`](crate::Note::relink) rewrites
//! a renamed page's card, its place in `folded`, `opened` and `hidden`,
//! and its name in the river's query — the same lines, by the same rules,
//! as in a page.

use crate::frontmatter::Frontmatter;
use crate::query::Query;

/// The graph's folder of saved rivers.
pub const RIVERS_DIR: &str = "rivers";
/// The frontmatter key naming a page's home river: `river: Work`.
pub const HOME_KEY: &str = "river";

/// The river a link's target names — `rivers/Work` is `Work` — or `None`
/// for a target that is no river.
pub fn name_of(target: &str) -> Option<&str> {
    let target = target.trim();
    let prefix = target.get(..RIVERS_DIR.len() + 1)?;
    if !prefix.eq_ignore_ascii_case("rivers/") {
        return None;
    }
    let name = &target[prefix.len()..];
    let name = if name.len() > 3 && name[name.len() - 3..].eq_ignore_ascii_case(".md") { &name[..name.len() - 3] } else { name };
    (!name.is_empty() && !name.contains('/')).then_some(name)
}

/// A link's target for a river: `Work` is `rivers/Work`.
pub fn target(name: &str) -> String {
    format!("{RIVERS_DIR}/{name}")
}

/// Whether a graph-relative path is a saved river's file.
pub fn is_river(path: &str) -> bool {
    path.strip_suffix(".md").and_then(|stem| stem.strip_prefix("rivers/")).is_some_and(|name| !name.is_empty() && !name.contains('/'))
}

/// The link written for a river: `[[rivers/Work]]`.
pub fn link(name: &str) -> String {
    format!("[[{}]]", target(name))
}

/// A river's file in the graph.
pub fn path(name: &str) -> String {
    format!("{RIVERS_DIR}/{name}.md")
}

/// A row folded in a card: its place among the card's rows, and its
/// text — by which it is found again after the page changes elsewhere.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoldedRow {
    pub index: usize,
    pub text: String,
}

/// A card of a river.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Card {
    /// The page's title.
    pub title: String,
    /// The rows folded in it.
    pub folded_rows: Vec<FoldedRow>,
    /// For a card placed by hand among what a query finds: where — a
    /// rank, and the sort key it stood at. `None` for a card in the
    /// river's own order.
    pub place: Option<(i64, String)>,
}

impl Card {
    pub fn new(title: impl Into<String>) -> Card {
        Card { title: title.into(), ..Card::default() }
    }
}

/// A saved river, as its file has it.
///
/// **A river read and written back unchanged gives the bytes it was read
/// from**, whatever else the file holds. One that was changed is written
/// anew, in the one way a river is written — keeping the frontmatter it
/// was read with, so a key this reader does not know (a newer app's)
/// outlives the change; lines of the body that are no card, row or query
/// do not.
#[derive(Debug, Clone, Default)]
pub struct River {
    /// The cards held by hand, in order: those of a plain river, or those
    /// at the top of a query river.
    pub cards: Vec<Card>,
    /// What it finds, for a query river.
    pub query: Option<Query>,
    /// Cards put by hand among what the query finds.
    pub placed: Vec<Card>,
    /// The cards showing only their titles.
    pub folded: Vec<String>,
    /// Of what the query finds: those opened out of their peek.
    pub opened: Vec<String>,
    /// Of what the query finds: those taken out of the river.
    pub hidden: Vec<String>,
    /// How it shows among the rivers: an SF Symbol's name, a colour's.
    pub icon: Option<String>,
    pub color: Option<String>,
    /// Where it stands among the saved rivers, lower first.
    pub place: Option<f64>,
    /// The file it was read from; `None` for a river made anew. What
    /// [`to_markdown`](River::to_markdown) keeps faith with.
    pub source: Option<String>,
}

impl PartialEq for River {
    /// Two rivers are the same when they say the same, whatever files
    /// they were read from.
    fn eq(&self, other: &River) -> bool {
        self.cards == other.cards
            && self.query == other.query
            && self.placed == other.placed
            && self.folded == other.folded
            && self.opened == other.opened
            && self.hidden == other.hidden
            && self.icon == other.icon
            && self.color == other.color
            && self.place == other.place
    }
}

impl River {
    /// Reads a river's file. Lines that are no card, row or query are
    /// passed over.
    pub fn parse(source: &str) -> River {
        let (front, body) = Frontmatter::split(source);
        let mut river = River::default();
        if let Some(front) = &front {
            river.folded = front.list("folded");
            river.opened = front.list("opened");
            river.hidden = front.list("hidden");
            river.icon = front.text("icon").map(str::to_owned);
            river.color = front.text("color").map(str::to_owned);
            river.place = front.text("place").and_then(|p| p.trim().parse().ok());
        }
        let mut query_lines: Option<Vec<&str>> = None;
        let mut in_query = false;
        for line in body.lines().filter(|line| !line.is_empty()) {
            if line.starts_with("```") {
                if line.trim() == "```query" && query_lines.is_none() {
                    query_lines = Some(Vec::new());
                    in_query = true;
                } else {
                    in_query = false;
                }
                continue;
            }
            if in_query {
                if let Some(lines) = &mut query_lines {
                    lines.push(line);
                }
                continue;
            }
            let words = line.trim_start_matches([' ', '\t']);
            let after_query = query_lines.is_some();
            if words.len() < line.len() {
                // Indented: a row folded in the card above.
                let Some(card) = (if after_query { river.placed.last_mut() } else { river.cards.last_mut() }) else { continue };
                let Some((index, text)) = words.strip_prefix("- ").and_then(|row| row.split_once(':')) else { continue };
                if let Ok(index) = index.parse() {
                    card.folded_rows.push(FoldedRow { index, text: unescape(text.strip_prefix(' ').unwrap_or(text)) });
                }
            } else if let Some((title, rest)) = words.split_once("[[").and_then(|(_, rest)| rest.split_once("]]")) {
                if title.is_empty() {
                    continue;
                }
                let mut card = Card::new(title);
                if after_query {
                    // `- [[Title]] @ rank key`
                    let Some((rank, key)) = rest.strip_prefix(" @ ").map(|place| place.split_once(' ').unwrap_or((place, ""))) else { continue };
                    let Ok(rank) = rank.parse() else { continue };
                    card.place = Some((rank, key.to_owned()));
                    river.placed.push(card);
                } else {
                    river.cards.push(card);
                }
            }
        }
        river.query = query_lines.map(|lines| Query::parse(&lines.join("\n")));
        river.source = Some(source.to_owned());
        river
    }

    /// Whether the river was read from a file, rather than made.
    pub fn has_source(&self) -> bool {
        self.source.is_some()
    }

    /// The river, as if it had been read from this file and then changed
    /// to what it is: written back, it keeps what the file holds that a
    /// river does not read. For a river made anew that is saved over one
    /// already there.
    pub fn over(mut self, file: &str) -> River {
        self.source = Some(file.to_owned());
        self
    }

    /// The river as its file.
    pub fn to_markdown(&self) -> String {
        // Unchanged since it was read: the file as it was.
        if let Some(source) = &self.source {
            if River::parse(source) == *self {
                return source.clone();
            }
        }
        let mut front = self.source.as_deref().and_then(|source| Frontmatter::split(source).0).unwrap_or_default();
        let held: Vec<String> = self.titles().filter(|title| self.folded.iter().any(|f| f == title)).map(str::to_owned).collect();
        // Each an item a line, whatever its length: one device folding a
        // card and another folding a different one then merge.
        let mut list = |key: &str, items: Vec<String>| {
            if items.is_empty() {
                front.remove(key);
            } else {
                front.set_list_by_line(key, items);
            }
        };
        list("folded", held);
        let mut opened = self.opened.clone();
        opened.sort();
        list("opened", opened);
        list("hidden", self.hidden.clone());
        let place = self.place.map(|place| if place.fract() == 0.0 { format!("{place:.0}") } else { place.to_string() });
        for (key, value) in [("icon", self.icon.clone()), ("color", self.color.clone()), ("place", place)] {
            match value {
                Some(value) => front.set(key, value),
                None => {
                    front.remove(key);
                }
            }
        }
        let mut text = if front.is_empty() { String::new() } else { front.to_string() };
        let card_lines = |text: &mut String, card: &Card| {
            match &card.place {
                Some((rank, key)) => text.push_str(&format!("- [[{}]] @ {rank} {key}\n", card.title)),
                None => text.push_str(&format!("- [[{}]]\n", card.title)),
            }
            for row in &card.folded_rows {
                text.push_str(&format!("  - {}: {}\n", row.index, escape(&row.text)));
            }
        };
        for card in &self.cards {
            card_lines(&mut text, card);
        }
        if let Some(query) = &self.query {
            if !self.cards.is_empty() {
                text.push('\n');
            }
            let body = query.to_string();
            text.push_str(&format!("```query\n{body}{}```\n", if body.is_empty() { "" } else { "\n" }));
            for card in &self.placed {
                card_lines(&mut text, card);
            }
        }
        text
    }

    /// Every card held by hand, by title: at its top, then placed.
    pub fn titles(&self) -> impl Iterator<Item = &str> {
        self.cards.iter().chain(&self.placed).map(|card| card.title.as_str())
    }
}

/// A row's text on one line: line breaks and backslashes escaped.
fn escape(text: &str) -> String {
    text.replace('\\', "\\\\").replace('\n', "\\n")
}

fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        match (c, chars.clone().next()) {
            ('\\', Some('n')) => {
                chars.next();
                out.push('\n');
            }
            ('\\', Some('\\')) => {
                chars.next();
                out.push('\\');
            }
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn river_links_name_their_river() {
        assert_eq!(name_of("rivers/Work"), Some("Work"));
        assert_eq!(name_of(" Rivers/Deep Work.md "), Some("Deep Work"));
        for other in ["Work", "rivers/", "rivers/a/b", "riverside/Work", "rivers", "rivers/.md"] {
            assert_eq!(name_of(other).filter(|n| *n != ".md"), None, "{other}");
        }
        assert_eq!((target("Work"), link("Work"), path("Work")), ("rivers/Work".into(), "[[rivers/Work]]".into(), "rivers/Work.md".into()));
    }

    const PLAIN: &str = "---\nfolded:\n  - Beta\n---\n- [[Alpha]]\n  - 4: Projects\n  - 7: Two\\nlines \\\\ here\n- [[Beta]]\n";

    #[test]
    fn a_plain_river_reads_and_writes_back() {
        let river = River::parse(PLAIN);
        assert_eq!(river.titles().collect::<Vec<_>>(), ["Alpha", "Beta"]);
        assert_eq!(river.cards[0].folded_rows, [FoldedRow { index: 4, text: "Projects".into() }, FoldedRow { index: 7, text: "Two\nlines \\ here".into() }]);
        assert_eq!(river.folded, ["Beta"]);
        assert_eq!(river.query, None);
        assert_eq!(river.to_markdown(), PLAIN);
        assert_eq!(River::parse("- [[Only]]\n").to_markdown(), "- [[Only]]\n");
        assert_eq!(River::parse("").to_markdown(), "");
    }

    const QUERIED: &str = "---\nopened:\n  - Found One\nhidden:\n  - Old Notes\nicon: tray\ncolor: blue\nplace: 2.5\n---\n- [[Pinned]]\n\n```query\ntag: Project\nsort: -modified\n```\n- [[Kept Here]] @ 1000 2026-11-03T10:00:00.000Z\n  - 2: A row\n";

    #[test]
    fn a_query_river_keeps_its_query_and_what_was_placed() {
        let river = River::parse(QUERIED);
        assert_eq!(river.cards, [Card::new("Pinned")]);
        assert_eq!(river.query.as_ref().unwrap().clauses.len(), 2);
        assert_eq!(river.placed[0].place, Some((1000, "2026-11-03T10:00:00.000Z".into())));
        assert_eq!(river.placed[0].folded_rows[0].text, "A row");
        assert_eq!((river.hidden.as_slice(), river.icon.as_deref(), river.place), (&["Old Notes".to_owned()][..], Some("tray"), Some(2.5)));
        assert_eq!(river.to_markdown(), QUERIED);
    }

    #[test]
    fn folded_is_written_only_for_cards_it_holds_and_noise_is_passed_over() {
        const NOISY: &str = "---\nfolded: [Gone, Alpha]\n---\nsome prose\n- [[Alpha]]\n  not a row\n  - x: not numbered\n- no link here\n- [[]]\n";
        let mut river = River::parse(NOISY);
        assert_eq!(river.titles().collect::<Vec<_>>(), ["Alpha"]);
        // Untouched, it is the file it was; made anew, it is written the one way.
        assert_eq!(river.to_markdown(), NOISY);
        let anew = River { cards: river.cards.clone(), folded: river.folded.clone(), ..River::default() };
        assert_eq!(anew, river);
        assert_eq!(anew.to_markdown(), "---\nfolded:\n  - Alpha\n---\n- [[Alpha]]\n");
        river.cards[0].title = "Alef".into();
        river.folded = vec!["Alef".into()];
        assert_eq!(river.to_markdown(), "---\nfolded:\n  - Alef\n---\n- [[Alef]]\n");
    }

    #[test]
    fn a_river_changed_keeps_what_it_does_not_read() {
        const NEWER: &str = "---\n# kept by hand\nlayout: board\nfolded: [Alpha]\nicon: tray\n---\n-   [[Alpha]]\n- [[Beta]]\n";
        let mut river = River::parse(NEWER);
        assert_eq!(river.to_markdown(), NEWER, "odd spacing and all");
        river.cards.push(Card::new("Gamma"));
        river.icon = None;
        assert_eq!(river.to_markdown(), "---\n# kept by hand\nlayout: board\nfolded:\n  - Alpha\n---\n- [[Alpha]]\n- [[Beta]]\n- [[Gamma]]\n");
        // A river made anew, saved over that file, keeps it too.
        let made = River { cards: vec![Card::new("Only")], ..River::default() };
        assert!(!made.has_source());
        assert_eq!(made.clone().to_markdown(), "- [[Only]]\n");
        assert_eq!(made.over(NEWER).to_markdown(), "---\n# kept by hand\nlayout: board\n---\n- [[Only]]\n");
    }
}
