//! Notes as data.
//!
//! A graph is a folder of Markdown files. This crate is what those files
//! say: it reads a note into a representation editors can work on, and
//! writes that representation back as Markdown. It does no I/O and has no
//! dependencies; it is the same on a Mac, a phone and a Worker.
//!
//! # The representation
//!
//! ```text
//! Note
//! ├── Frontmatter      key: value lines, each kept as written
//! └── Document         the body
//!     └── Block*       a tree: list items nest; everything else is flat
//!         ├── kind     paragraph, heading, item, quote, code, table, rule, raw
//!         ├── text     the block's Markdown — inline markup stays in it
//!         ├── layout   how it was written: bullet, spacing, blank lines
//!         └── children
//! ```
//!
//! - [`Note`] reads a whole file and answers what it says about itself:
//!   its title, names, tags ([`Meta`]) and what it refers to — links,
//!   pictures, tasks ([`References`]).
//! - [`Document`] and [`Block`] are the body. An **outline** editor walks
//!   [`Document::rows`] and restructures with [`outline`]; a **prose**
//!   editor walks the top-level blocks.
//! - [`inline`] finds the spans in a block's text — emphasis, links,
//!   `[[wiki links]]`, `#tags`, pictures — as ranges over that text.
//! - [`Frontmatter`] reads and edits the header.
//! - [`table`] and [`query`] read the two block kinds with structure of
//!   their own.
//! - [`session`] is a note open for writing: what an editor holds. The
//!   editor's text view shows a projection of the tree — as an outline, or
//!   as Markdown — and every change in it is a change to the tree.
//!   [`editor`] is the reading of lines and runs under it.
//! - [`fields`] reads the typed fields a tag gives its pages, and
//!   [`river`] a saved river's file.
//!
//! # The one promise
//!
//! **Reading a note and writing it back unchanged gives the same bytes**,
//! whatever is in it; and an edit rewrites only what was edited. A note is
//! shared with other apps, other devices and git's line-by-line merges —
//! none of which forgive an editor that reformats what it did not touch.
//! See [`block`] for how the promise is kept.
//!
//! ```
//! use prism_markup::{Note, outline};
//!
//! let source = "---\ntags: [Projects]\n---\n# Atlas\n\n*   Kick-off with [[Ada]] #planning\n*   Budget\n";
//! let mut note = Note::parse(source);
//! assert_eq!(note.to_markdown(), source);
//!
//! let meta = note.meta("notes/atlas.md");
//! assert_eq!(meta.title, "Atlas");
//! assert_eq!(meta.tags, ["Projects", "planning"]);
//! assert_eq!(note.references().links[0].target, "Ada");
//!
//! // Indent "Budget" under "Kick-off": only that line changes.
//! outline::indent(&mut note.body, &[2]);
//! assert!(note.to_markdown().ends_with("*   Kick-off with [[Ada]] #planning\n    *   Budget\n"));
//! ```
//!
//! # The dialect
//!
//! CommonMark's and GitHub's blocks — headings, paragraphs, nested lists,
//! quotes, rules, pipe tables, fenced code — and these extensions, each of
//! which degrades to sensible text in any other Markdown viewer:
//!
//! | Written | Means |
//! |---|---|
//! | `[[Title]]`, `[[Title\|shown]]` | a link to a page by title or alias |
//! | `![[Title]]` | the page shown inside this one |
//! | `#tag` | a tag |
//! | `==text==` | highlighted |
//! | `+ [ ]` / `- [ ]` | a task / a checklist item |
//! | `> [!TIP]` | a callout |
//! | `![alt](src)<!-- {"width":425} -->` | a picture, at a size |
//! | ```` ```query ```` | a live list of pages |

pub mod block;
pub mod date;
pub mod editor;
pub mod fields;
pub mod frontmatter;
pub mod inline;
pub mod note;
pub mod outline;
pub mod query;
pub mod river;
pub mod session;
pub mod table;
pub mod time;

pub use block::{Block, BlockKind, Callout, Code, Document, Item, Layout, LineEnding, Marker, Row, Task};
pub use date::{Day, Timestamp, Week, Weekday};
pub use fields::{FieldKind, FieldSpec, FieldValue};
pub use frontmatter::{Frontmatter, Value};
pub use inline::{Span, SpanKind, Style};
pub use note::{name_key, ImageRef, LinkKind, Meta, Note, NoteKind, NoteLink, References, TaskRef, WebLink};
pub use query::{Clause, Query};
pub use river::River;
pub use session::{Mode, RowInfo, Session};
pub use table::Table;
