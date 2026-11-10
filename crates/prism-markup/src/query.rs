//! Query blocks: a live list of pages, written a condition a line.
//!
//! ````markdown
//! ```query
//! tag: Person
//! not tag: Archived
//! sort: -modified
//! limit: 10
//! ```
//! ````
//!
//! This module reads the block's lines into typed [`Clause`]s and writes
//! them back. Running a query is the business of whoever holds an index.
//! A line not understood is kept as [`Clause::Unknown`] and written back
//! as it was, so a newer app's conditions survive an older one.

use std::fmt;

/// One line of a query.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Clause {
    /// `tag: X` — pages tagged X. Every `tag:` line must hold.
    Tag(String),
    /// `not tag: X`.
    NotTag(String),
    /// `title: words`.
    Title(String),
    /// `text: words`.
    Text(String),
    /// `links to: X` — pages linking to X.
    LinksTo(String),
    /// `linked from: X` — pages X links to.
    LinkedFrom(String),
    /// `listed in: X` — the titles in X's `list` field, in their order.
    ListedIn(String),
    /// `has: field, …` — pages with each field.
    Has(Vec<String>),
    /// `is: day`, `week` or `note` — the page's kind — or `is: pinned`,
    /// `is: inbox`, any field: pages the field marks (it is there, and
    /// does not say no).
    Is(String),
    /// `is not: …`: the pages `is:` would leave out.
    IsNot(String),
    /// `sort: title`, `created`, `modified`, or any field — by number
    /// where its values are numbers; `sort: -modified` for the reverse.
    Sort { key: String, descending: bool },
    /// `limit: n`.
    Limit(usize),
    /// `show: list` / `inline` / `table` / `cards` / `count` / `tree`.
    Show(String),
    /// `columns: a, b`.
    Columns(Vec<String>),
    /// A line not understood, as written.
    Unknown(String),
}

/// A query: its clauses, in the order written.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Query {
    pub clauses: Vec<Clause>,
}

impl Query {
    /// Reads a query block's body. `{this}` in a value stands for the page
    /// the query is in, and is left for whoever runs it to fill in.
    pub fn parse(body: &str) -> Query {
        Query { clauses: body.lines().filter(|l| !l.trim().is_empty()).map(parse_clause).collect() }
    }

    pub fn limit(&self) -> Option<usize> {
        self.clauses.iter().find_map(|c| match c {
            Clause::Limit(n) => Some(*n),
            _ => None,
        })
    }
}

fn parse_clause(line: &str) -> Clause {
    let unknown = || Clause::Unknown(line.to_owned());
    let Some((key, value)) = line.split_once(':') else { return unknown() };
    let value = value.trim();
    let list = || value.split(',').map(|v| v.trim().to_owned()).filter(|v| !v.is_empty()).collect::<Vec<_>>();
    let key = key.trim().to_ascii_lowercase();
    if value.is_empty() {
        return unknown();
    }
    match key.as_str() {
        "tag" => Clause::Tag(value.to_owned()),
        "not tag" => Clause::NotTag(value.to_owned()),
        "title" => Clause::Title(value.to_owned()),
        "text" => Clause::Text(value.to_owned()),
        "links to" => Clause::LinksTo(value.to_owned()),
        "linked from" => Clause::LinkedFrom(value.to_owned()),
        "listed in" => Clause::ListedIn(value.to_owned()),
        "has" => Clause::Has(list()),
        "is" => Clause::Is(value.to_ascii_lowercase()),
        "is not" => Clause::IsNot(value.to_ascii_lowercase()),
        "sort" => match value.strip_prefix('-') {
            Some(key) => Clause::Sort { key: key.trim().to_owned(), descending: true },
            None => Clause::Sort { key: value.to_owned(), descending: false },
        },
        "limit" => value.parse().map(Clause::Limit).unwrap_or_else(|_| unknown()),
        "show" => Clause::Show(value.to_ascii_lowercase()),
        "columns" => Clause::Columns(list()),
        _ => unknown(),
    }
}

impl fmt::Display for Clause {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Clause::Tag(v) => write!(f, "tag: {v}"),
            Clause::NotTag(v) => write!(f, "not tag: {v}"),
            Clause::Title(v) => write!(f, "title: {v}"),
            Clause::Text(v) => write!(f, "text: {v}"),
            Clause::LinksTo(v) => write!(f, "links to: {v}"),
            Clause::LinkedFrom(v) => write!(f, "linked from: {v}"),
            Clause::ListedIn(v) => write!(f, "listed in: {v}"),
            Clause::Has(v) => write!(f, "has: {}", v.join(", ")),
            Clause::Is(v) => write!(f, "is: {v}"),
            Clause::IsNot(v) => write!(f, "is not: {v}"),
            Clause::Sort { key, descending } => write!(f, "sort: {}{key}", if *descending { "-" } else { "" }),
            Clause::Limit(n) => write!(f, "limit: {n}"),
            Clause::Show(v) => write!(f, "show: {v}"),
            Clause::Columns(v) => write!(f, "columns: {}", v.join(", ")),
            Clause::Unknown(line) => f.write_str(line),
        }
    }
}

impl fmt::Display for Query {
    /// A clause a line, no line break at the end: a query block's body.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (index, clause) in self.clauses.iter().enumerate() {
            if index > 0 {
                f.write_str("\n")?;
            }
            write!(f, "{clause}")?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_every_clause_and_keeps_what_it_does_not_know() {
        let body = "tag: Person\nnot tag: Archived\ntitle: ada\ntext: engine\nlinks to: {this}\nlinked from: Index\nlisted in: Reading\nhas: birthday, company\nis not: Wiki\nis: Inbox\nsort: -modified\nlimit: 10\nshow: table\ncolumns: a, b\nfrobnicate: wildly\nno colon here\nlimit: many";
        let query = Query::parse(body);
        assert_eq!(
            query.clauses,
            [
                Clause::Tag("Person".into()),
                Clause::NotTag("Archived".into()),
                Clause::Title("ada".into()),
                Clause::Text("engine".into()),
                Clause::LinksTo("{this}".into()),
                Clause::LinkedFrom("Index".into()),
                Clause::ListedIn("Reading".into()),
                Clause::Has(vec!["birthday".into(), "company".into()]),
                Clause::IsNot("wiki".into()),
                Clause::Is("inbox".into()),
                Clause::Sort { key: "modified".into(), descending: true },
                Clause::Limit(10),
                Clause::Show("table".into()),
                Clause::Columns(vec!["a".into(), "b".into()]),
                Clause::Unknown("frobnicate: wildly".into()),
                Clause::Unknown("no colon here".into()),
                Clause::Unknown("limit: many".into()),
            ]
        );
        assert_eq!(query.limit(), Some(10));
        assert_eq!(query.to_string(), body.replace("is: Inbox", "is: inbox").replace("is not: Wiki", "is not: wiki"));
    }
}
