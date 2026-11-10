//! Running queries: a query block's conditions, asked of the indices.
//!
//! [`prism_markup::Query`] is what a query block says; [`run`] is what it
//! finds — the pages that meet every condition, in the order asked for.
//! It needs the [`Catalog`], [`Links`] and [`Search`] indices in the
//! database.
//!
//! The order, when no `sort:` line gives one: the order of the list a
//! `listed in:` names; else the tag's own order — the `list` its page
//! keeps, those pages first — else by title.

use crate::catalog::{Catalog, NoteRow, Resolved};
use crate::links::Links;
use crate::search::Search;
use crate::Result;
use prism_markup::frontmatter::is_truthy;
use prism_markup::{Clause, Query};
use rusqlite::Connection;
use std::collections::{HashMap, HashSet};

/// How a query's pages are to be shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Show {
    #[default]
    List,
    Inline,
    Table,
    Cards,
    Count,
    Tree,
}

/// What a query is run with.
#[derive(Debug, Clone, Copy, Default)]
pub struct QueryOptions<'a> {
    /// The title of the page the query is written in: what `{this}`
    /// stands for.
    pub this: Option<&'a str>,
    /// Whether pages marked `private: true` may be found. They are not,
    /// unless asked for.
    pub include_private: bool,
}

/// What a query found.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct QueryResult {
    /// The pages, in order, cut to the query's `limit`.
    pub pages: Vec<NoteRow>,
    /// How many there were before the limit.
    pub total: usize,
    pub show: Show,
    /// A table's fields: the query's `columns`, else the typed fields of
    /// the tag it asks for.
    pub columns: Vec<String>,
}

/// Runs a query.
pub fn run(db: &Connection, query: &Query, options: &QueryOptions<'_>) -> Result<QueryResult> {
    let fill = |value: &str| value.replace("{this}", options.this.unwrap_or("{this}"));
    let resolve = |name: &str| -> Result<Option<String>> {
        Ok(match Catalog::resolve(db, name)? {
            Some(Resolved::Note(path)) => Some(path),
            _ => None,
        })
    };
    let mut pages: Vec<NoteRow> = Catalog::all(db)?.into_iter().filter(|page| options.include_private || !page.private).collect();
    // The order a list gives: path → place.
    let mut listed: Option<HashMap<String, usize>> = None;
    let mut first_tag: Option<String> = None;
    let mut result = QueryResult::default();
    let mut sort: Option<(String, bool)> = None;
    let mut limit = None;

    for clause in &query.clauses {
        match clause {
            Clause::Tag(tag) | Clause::NotTag(tag) => {
                let tag = fill(tag);
                let tagged: HashSet<String> = Catalog::tagged(db, &tag)?.into_iter().map(|page| page.path).collect();
                let wanted = matches!(clause, Clause::Tag(_));
                pages.retain(|page| tagged.contains(&page.path) == wanted);
                if wanted && first_tag.is_none() {
                    first_tag = Some(tag);
                }
            }
            Clause::Title(words) => {
                let words: Vec<String> = fill(words).to_lowercase().split_whitespace().map(str::to_owned).collect();
                pages.retain(|page| {
                    let title = page.title.to_lowercase();
                    words.iter().all(|word| title.contains(word))
                });
            }
            Clause::Text(words) => {
                let matching: HashSet<String> = Search::matching(db, &fill(words))?.into_iter().collect();
                pages.retain(|page| matching.contains(&page.path));
            }
            Clause::LinksTo(name) => {
                let name = fill(name);
                // Every name the page answers to; a page not written yet
                // is still linked to by the name asked for.
                let names = match resolve(&name)? {
                    Some(path) => Catalog::names(db, &path)?,
                    None => vec![name],
                };
                let sources: HashSet<String> = Links::backlinks(db, &names)?.into_iter().map(|link| link.source).collect();
                pages.retain(|page| sources.contains(&page.path));
            }
            Clause::LinkedFrom(name) => {
                let mut targets = HashSet::new();
                if let Some(path) = resolve(&fill(name))? {
                    for link in Links::outgoing(db, &path)? {
                        targets.extend(resolve(&link.target)?);
                    }
                }
                pages.retain(|page| targets.contains(&page.path));
            }
            Clause::ListedIn(name) => {
                let order = list_order(db, resolve(&fill(name))?.as_deref())?;
                pages.retain(|page| order.contains_key(&page.path));
                listed = Some(order);
            }
            Clause::Has(fields) => {
                for field in fields {
                    let having: HashSet<String> = Catalog::with_field(db, field, None)?.into_iter().map(|page| page.path).collect();
                    pages.retain(|page| having.contains(&page.path));
                }
            }
            Clause::Wiki(wanted) => pages.retain(|page| page.wiki == *wanted),
            Clause::Is(what) => match what.as_str() {
                "day" | "week" | "note" => pages.retain(|page| page.kind == *what),
                "wiki" => pages.retain(|page| page.wiki),
                flag => {
                    let flagged = flagged(db, flag)?;
                    pages.retain(|page| flagged.contains_key(&page.path));
                }
            },
            Clause::Sort { key, descending } => sort = Some((key.to_lowercase(), *descending)),
            Clause::Limit(n) => limit = Some(*n),
            Clause::Show(show) => {
                result.show = match show.as_str() {
                    "inline" => Show::Inline,
                    "table" => Show::Table,
                    "cards" => Show::Cards,
                    "count" => Show::Count,
                    "tree" => Show::Tree,
                    _ => Show::List,
                }
            }
            Clause::Columns(columns) => result.columns = columns.clone(),
            Clause::Unknown(_) => {}
        }
    }

    // `Catalog::all` gave them by title; every sort below is stable, so
    // title settles what the key does not.
    match sort {
        Some((key, descending)) => {
            match key.as_str() {
                "created" => sort_by_time(&mut pages, |page| page.created, descending),
                "modified" => sort_by_time(&mut pages, |page| page.modified, descending),
                "pinned" => {
                    // Those given a place, by it; then those merely pinned.
                    let pinned = flagged(db, "pinned")?;
                    pages.sort_by(|a, b| {
                        let place =
                            |page: &NoteRow| pinned.get(&page.path).map(|value| value.trim().parse::<f64>().unwrap_or(f64::INFINITY)).unwrap_or(f64::INFINITY);
                        let by_place = place(a).total_cmp(&place(b));
                        let by_pinned = pinned.contains_key(&b.path).cmp(&pinned.contains_key(&a.path));
                        let ordered = by_pinned.then(by_place);
                        if descending {
                            ordered.reverse()
                        } else {
                            ordered
                        }
                    });
                }
                // `title`, and anything not known.
                _ => {
                    if descending {
                        pages.reverse();
                    }
                }
            }
        }
        None => {
            let order = match (listed, &first_tag) {
                (Some(order), _) => Some(order),
                (None, Some(tag)) => Some(list_order(db, resolve(tag)?.as_deref())?),
                _ => None,
            };
            if let Some(order) = order {
                pages.sort_by_key(|page| order.get(&page.path).copied().unwrap_or(usize::MAX));
            }
        }
    }
    if result.columns.is_empty() {
        if let Some(tag) = &first_tag {
            result.columns = Catalog::field_specs(db, tag)?.into_iter().map(|spec| spec.name).collect();
        }
    }
    result.total = pages.len();
    pages.truncate(limit.unwrap_or(usize::MAX));
    result.pages = pages;
    Ok(result)
}

/// Runs a query block's body.
pub fn run_text(db: &Connection, body: &str, options: &QueryOptions<'_>) -> Result<QueryResult> {
    run(db, &Query::parse(body), options)
}

/// The pages a page's `list` field names, each with its place in it.
fn list_order(db: &Connection, path: Option<&str>) -> Result<HashMap<String, usize>> {
    let mut order = HashMap::new();
    let Some(path) = path else { return Ok(order) };
    let fields = Catalog::fields(db, path)?;
    let titles = fields.iter().find(|(key, _)| key == "list").map(|(_, values)| values.as_slice()).unwrap_or_default();
    for (place, title) in titles.iter().enumerate() {
        let title = title.trim().trim_start_matches("[[").trim_end_matches("]]");
        if let Some(Resolved::Note(listed)) = Catalog::resolve(db, title)? {
            order.entry(listed).or_insert(place);
        }
    }
    Ok(order)
}

/// The pages whose frontmatter sets a flag — `true`, `yes`, or, for
/// `pinned`, a number for its place — each with what it says.
fn flagged(db: &Connection, flag: &str) -> Result<HashMap<String, String>> {
    let mut statement = db.prepare("SELECT path, value FROM note_fields WHERE key = ?1 AND position = 0")?;
    let rows = statement.query_map([flag], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
    let mut flagged = HashMap::new();
    for row in rows {
        let (path, value) = row?;
        if is_truthy(&value) || value.trim().parse::<f64>().is_ok_and(|place| place != 0.0) {
            flagged.insert(path, value);
        }
    }
    Ok(flagged)
}

/// By a time; pages without one last, whichever way.
fn sort_by_time(pages: &mut [NoteRow], time: impl Fn(&NoteRow) -> Option<i64>, descending: bool) {
    pages.sort_by(|a, b| match (time(a), time(b)) {
        (Some(x), Some(y)) if descending => y.cmp(&x),
        (Some(x), Some(y)) => x.cmp(&y),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });
}
