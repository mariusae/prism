//! Running queries: a query block's conditions, asked of the indices.
//!
//! [`prism_markup::Query`] is what a query block says; [`run`] is what it
//! finds — the pages that meet every condition, in the order asked for.
//! It needs the [`Catalog`], [`Links`](crate::Links) and [`Search`](crate::Search)
//! indices in the database.
//!
//! # A query is one statement
//!
//! A query is compiled to a single SQL statement — its conditions the
//! `WHERE`, its order the `ORDER BY`, its limit the `LIMIT` — and SQLite
//! runs it over the indices. Nothing is loaded to be thrown away: the
//! cost of a query is what it finds, not what the graph holds, and the
//! ten pages changed last are read off an index of when pages changed.
//!
//! **Order.** With a `sort:` line: by title, by `created` or `modified`,
//! or by any field — numbers before words, pages without it last. Without
//! one: an order set by hand, if the query names one — the list a
//! `listed in:` names, else the `list` of the first tag's page, those
//! pages first — else by title.
//!
//! **An order set by hand is a list of links**, wherever it is written:
//! `listed in: Reading` reads the page Reading's `list` field;
//! `listed in: rivers/Work` reads the river's cards.
//!
//! **Private pages** are found only on a connection that shows them
//! ([`show_private`](crate::show_private)), like everything else here.

use crate::catalog::{self, Catalog, NoteRow, Resolved};
use crate::links::LEADS_TO;
use crate::Result;
use prism_markup::{name_key, river, Clause, Query};
use rusqlite::types::Value;
use rusqlite::{params_from_iter, Connection};

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

/// A field marks its page: it is there, with a value that does not say
/// no. The SQL of [`prism_markup::frontmatter::is_set`]; its argument is
/// the field's name. Asked of the fields' index, so it costs the pages
/// that have the field, not the pages there are.
const MARKED: &str = "IN (SELECT path FROM note_fields WHERE key = ? AND position = 0
     AND trim(value) != '' AND lower(trim(value)) NOT IN ('false', 'no', 'off', '0', 'n'))";

/// The field that marks a page archived: kept as it is, out of the way —
/// left out of queries unless asked for, and found after the rest.
pub const ARCHIVED: &str = "archived";

/// A hand-set order: where a file links to pages, in the order it names
/// them. Two arguments: the file, and the field (`''` for its body).
fn listed() -> String {
    format!("SELECT {LEADS_TO} AS page, min(links.rowid) AS place FROM links WHERE source = ? AND kind != 'tag' AND field = ? GROUP BY page")
}

/// A statement being put together: its conditions, and the arguments of
/// each part, in the order the parts are written.
#[derive(Default)]
struct Statement {
    join: String,
    join_args: Vec<Value>,
    conditions: Vec<String>,
    condition_args: Vec<Value>,
}

impl Statement {
    fn condition(&mut self, sql: impl Into<String>, args: impl IntoIterator<Item = String>) {
        self.conditions.push(sql.into());
        self.condition_args.extend(args.into_iter().map(Value::Text));
    }

    fn filter(&self) -> String {
        std::iter::once(catalog::SEEN.to_owned()).chain(self.conditions.iter().cloned()).collect::<Vec<_>>().join(" AND ")
    }
}

/// How a query's pages are ordered.
enum Order {
    Title {
        descending: bool,
    },
    /// `created` or `modified`: a column of `prism_dates`.
    Time {
        column: &'static str,
        descending: bool,
    },
    Field {
        key: String,
        descending: bool,
    },
    /// By hand: a file's links, in a field of it.
    Listed {
        source: String,
        field: &'static str,
    },
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
    // The file and field a name's hand-set order is written in.
    let list_of = |name: &str| -> Result<Option<(String, &'static str)>> {
        Ok(match river::name_of(name) {
            Some(river) => Some((river::path(river), "")),
            None => resolve(name)?.map(|path| (path, "list")),
        })
    };
    let mut statement = Statement::default();
    let mut result = QueryResult::default();
    let mut order: Option<Order> = None;
    let mut listed_in: Option<(String, &'static str)> = None;
    let mut first_tag: Option<String> = None;
    let mut limit: Option<usize> = None;
    // An archived page is left out unless the query asks about archiving.
    let mut archived_asked = false;

    for clause in &query.clauses {
        match clause {
            Clause::Tag(tag) | Clause::NotTag(tag) => {
                let tag = fill(tag);
                let not = if matches!(clause, Clause::Tag(_)) { "" } else { "NOT " };
                statement.condition(
                    format!("notes.path {not}IN (SELECT source FROM links WHERE kind = 'tag' AND key = ?)"),
                    [name_key(tag.trim().trim_start_matches('#'))],
                );
                if not.is_empty() && first_tag.is_none() {
                    first_tag = Some(tag);
                }
            }
            Clause::Title(words) => {
                // Asked of the title's key, which is folded as names are.
                for word in name_key(&fill(words)).split(' ').filter(|word| !word.is_empty()) {
                    statement.condition(
                        "EXISTS (SELECT 1 FROM note_names AS named WHERE named.path = notes.path AND named.rank = 0 AND instr(named.key, ?) > 0)",
                        [word.to_owned()],
                    );
                }
            }
            Clause::Text(words) => match crate::search::fts_query(&fill(words)) {
                Some(matching) => statement.condition("notes.path IN (SELECT path FROM search WHERE search MATCH ?)", [matching]),
                None => statement.condition("0", []),
            },
            Clause::LinksTo(name) => {
                let name = fill(name);
                // The links that lead to the page; a page not written yet
                // is still linked to by the name asked for.
                match resolve(&name)? {
                    Some(path) => statement.condition(
                        format!("notes.path IN (SELECT source FROM links WHERE key IN (SELECT key FROM note_names WHERE path = ?) AND {LEADS_TO} = ?)"),
                        [path.clone(), path],
                    ),
                    None => statement.condition("notes.path IN (SELECT source FROM links WHERE key = ?)".to_owned(), [name_key(&name)]),
                }
            }
            Clause::LinkedFrom(name) => match resolve(&fill(name))? {
                Some(path) => statement.condition(format!("notes.path IN (SELECT {LEADS_TO} FROM links WHERE source = ? AND kind != 'tag')"), [path]),
                None => statement.condition("0", []),
            },
            Clause::ListedIn(name) => match list_of(&fill(name))? {
                Some((source, field)) => {
                    statement.condition(format!("notes.path IN (SELECT page FROM ({}))", listed()), [source.clone(), field.to_owned()]);
                    listed_in = Some((source, field));
                }
                None => statement.condition("0", []),
            },
            Clause::Has(fields) => {
                for field in fields {
                    statement.condition("notes.path IN (SELECT path FROM note_fields WHERE key = ?)", [field.clone()]);
                }
            }
            Clause::Include(what) => archived_asked |= what == ARCHIVED,
            Clause::Is(what) | Clause::IsNot(what) => {
                archived_asked |= what == ARCHIVED;
                let not = if matches!(clause, Clause::Is(_)) { "" } else { "NOT " };
                match what.as_str() {
                    "day" | "week" | "note" => statement.condition(format!("{not}notes.kind = ?"), [what.clone()]),
                    "conflicted" => statement.condition(format!("{not}notes.conflicted"), []),
                    "blank" => statement.condition(format!("{not}notes.blank"), []),
                    field => statement.condition(format!("notes.path {not}{MARKED}"), [field.to_owned()]),
                }
            }
            Clause::Sort { key, descending } => {
                let descending = *descending;
                order = Some(match key.to_lowercase().as_str() {
                    "title" => Order::Title { descending },
                    "created" => Order::Time { column: "created", descending },
                    "modified" => Order::Time { column: "modified", descending },
                    _ => Order::Field { key: key.clone(), descending },
                });
            }
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

    if !archived_asked {
        statement.condition(format!("notes.path NOT {MARKED}"), [ARCHIVED.to_owned()]);
    }

    // No `sort:` line: an order set by hand, if the query names one.
    let order = match order {
        Some(order) => order,
        None => match (listed_in, &first_tag) {
            (Some((source, field)), _) => Order::Listed { source, field },
            (None, Some(tag)) => match list_of(tag)? {
                Some((source, field)) => Order::Listed { source, field },
                None => Order::Title { descending: false },
            },
            _ => Order::Title { descending: false },
        },
    };
    if result.columns.is_empty() {
        if let Some(tag) = &first_tag {
            result.columns = Catalog::field_specs(db, tag)?.into_iter().map(|spec| spec.name).collect();
        }
    }

    const BY_TITLE: &str = "notes.label COLLATE NOCASE, notes.path";
    let way = |descending: bool| if descending { " DESC" } else { "" };
    let mut dated: Option<&'static str> = None;
    let order_by = match order {
        Order::Title { descending: false } => BY_TITLE.to_owned(),
        Order::Title { descending: true } => "notes.label COLLATE NOCASE DESC, notes.path DESC".to_owned(),
        Order::Time { column, descending } => {
            // Driven from the index of when pages changed; the pages
            // with no time are asked for after, if there is room.
            statement.join = "JOIN prism_dates AS dated ON dated.path = notes.path".to_owned();
            statement.conditions.push(format!("dated.{column} IS NOT NULL"));
            dated = Some(column);
            format!("dated.{column}{}, {BY_TITLE}", way(descending))
        }
        Order::Field { key, descending } => {
            statement.join = "LEFT JOIN note_fields AS sorted ON sorted.path = notes.path AND sorted.key = ? AND sorted.position = 0".to_owned();
            statement.join_args.push(Value::Text(key));
            let way = way(descending);
            format!("sorted.path IS NULL, (sorted.number IS NULL){way}, sorted.number{way}, sorted.value COLLATE NOCASE{way}, {BY_TITLE}")
        }
        Order::Listed { source, field } => {
            statement.join = format!("LEFT JOIN ({}) AS listed ON listed.page = notes.path", listed());
            statement.join_args.extend([Value::Text(source), Value::Text(field.to_owned())]);
            format!("listed.place IS NULL, listed.place, {BY_TITLE}")
        }
    };

    let select = |statement: &Statement, order_by: &str, limit: Option<usize>| -> Result<Vec<NoteRow>> {
        let sql = format!("SELECT {} FROM notes {} WHERE {} ORDER BY {order_by} LIMIT ?", catalog::COLUMNS, statement.join, statement.filter());
        let cut = Value::Integer(limit.map_or(-1, |limit| limit as i64));
        let args = statement.join_args.iter().chain(&statement.condition_args).chain([&cut]);
        let mut prepared = db.prepare(&sql)?;
        let rows = prepared.query_map(params_from_iter(args), catalog::row)?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    };
    let mut pages = select(&statement, &order_by, limit)?;
    if let Some(column) = dated {
        // The undated, last whichever way, by title.
        if limit.is_none_or(|limit| pages.len() < limit) {
            statement.join.clear();
            statement.conditions.pop();
            statement.conditions.push(format!("NOT EXISTS (SELECT 1 FROM prism_dates AS dated WHERE dated.path = notes.path AND dated.{column} IS NOT NULL)"));
            pages.extend(select(&statement, BY_TITLE, limit.map(|limit| limit - pages.len()))?);
        }
        statement.conditions.pop();
    }
    result.total = match limit {
        // Under the limit: all of them are here.
        Some(limit) if pages.len() >= limit => {
            let sql = format!("SELECT count(*) FROM notes WHERE {}", statement.filter());
            db.query_row(&sql, params_from_iter(statement.condition_args.iter()), |r| r.get::<_, i64>(0))? as usize
        }
        _ => pages.len(),
    };
    result.pages = pages;
    Ok(result)
}

/// Runs a query block's body.
pub fn run_text(db: &Connection, body: &str, options: &QueryOptions<'_>) -> Result<QueryResult> {
    run(db, &Query::parse(body), options)
}

/// The plan SQLite makes for a statement: for tests that an index is
/// used where one is meant to be.
#[doc(hidden)]
pub fn plan(db: &Connection, sql: &str) -> Result<String> {
    let mut statement = db.prepare(&format!("EXPLAIN QUERY PLAN {sql}"))?;
    let lines: Vec<String> = statement.query_map([], |r| r.get(3))?.collect::<rusqlite::Result<_>>()?;
    Ok(lines.join("\n"))
}
