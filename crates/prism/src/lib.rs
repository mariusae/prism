//! Prism's engine: a graph of notes, kept in git.
//!
//! This is the crate an app is built on. Everything hard is under it; an
//! app on top is views.
//!
//! ```text
//!                         ┌──────────────── prism ────────────────┐
//!                         │  Engine   two threads: index, sync;   │
//!        an app  ───────▶ │           events                      │
//!                         │  Graph    notes as files              │
//!                         └───┬───────────┬───────────┬───────────┘
//!                             │           │           │
//!                  ┌──────────▼──┐  ┌─────▼─────┐  ┌──▼───────────┐
//!                  │ prism-index │  │ prism-sync│  │ prism-relay  │
//!                  │ catalog,    │  │ snapshot, │  │ "the remote  │
//!                  │ backlinks,  │─▶│ commit,   │  │  moved"      │
//!                  │ search,     │  │ merge,    │  └──┬───────────┘
//!                  │ tasks       │  │ push      │     │
//!                  └──────┬──────┘  └───────────┘  ┌──▼───────────┐
//!                         │                        │ prism-github │
//!                  ┌──────▼──────┐                 │ sign-in, API,│
//!                  │ prism-markup│                 │ webhooks     │
//!                  │ notes as    │                 └──────────────┘
//!                  │ data        │
//!                  └─────────────┘
//! ```
//!
//! - **[`Graph`]** reads and writes notes where a graph keeps them, makes
//!   new ones, and stores assets. No state, any thread.
//! - **[`Engine`]** keeps a graph synced and indexed in the background,
//!   and says what it does as [`Event`]s.
//! - The layers beneath are re-exported whole: [`markup`] (a note as a
//!   tree editors can work on), [`sync`] (the git engine), [`index`]
//!   (incremental indices), [`github`], and [`relay`].
//!
//! What this crate adds to them is what makes files *notes*: commit
//! messages that name what was written ([`NoteDescriber`]), and merges
//! that understand frontmatter ([`NoteMergeDriver`]).
//!
//! # An app, in outline
//!
//! ```no_run
//! use prism::{index::{Catalog, Links, Search}, Engine, EngineConfig, Event};
//! use prism::sync::{Auth, Config};
//!
//! let engine = Engine::start("/path/to/graph", EngineConfig {
//!     sync: Config { device: Some("Ada's Mac".into()), ..Config::default() },
//!     auth: Auth::token("github_pat_…"),
//!     ..EngineConfig::default()
//! })?;
//! let events = engine.subscribe();
//! engine.sync();                                   // at launch
//! engine.listen("prism-relay.example.workers.dev").ok();   // hear of other devices' pushes
//!
//! // The editor saves; indexing and syncing follow on their own.
//! let path = engine.create_note("Project Atlas")?;
//! let mut note = engine.graph().note(&path)?.unwrap();
//! note.body.blocks.push(prism::markup::Block::bullet("Kick-off with [[Ada Lovelace]]"));
//! engine.write(&path, &note.to_markdown())?;
//!
//! // Views ask the indices, on their own thread.
//! let db = engine.index()?;
//! let hits = Search::search(&db, "kick-off", 20)?;
//! let linking_here = Links::backlinks(&db, &Catalog::names(&db, &path)?)?;
//!
//! // And redraw when told.
//! for event in events {
//!     match event {
//!         Event::FilesChanged(paths) => { /* reload what is on screen */ }
//!         Event::IndexUpdated { .. } => { /* refresh backlinks, search, tasks */ }
//!         Event::SyncFinished(outcome) => { /* show how it went */ }
//!         _ => {}
//!     }
//! }
//! # Ok::<(), prism::Error>(())
//! ```

mod commit_message;
mod engine;
mod graph;
mod local;
mod note_merge;

pub use commit_message::NoteDescriber;
pub use engine::{Engine, EngineConfig, Event, Status, SyncFailure};
pub use graph::{slug, Graph, Renamed, Saved};
pub use local::Local;
pub use note_merge::{merge_notes, NoteMergeDriver};

/// Notes as data: frontmatter, the block tree, inline spans.
pub use prism_markup as markup;

/// The git sync engine.
pub use prism_sync as sync;

/// Incremental indices: catalog, backlinks, search, tasks.
pub use prism_index as index;

/// GitHub: signing in, repositories, webhooks.
pub use prism_github as github;

/// The sync relay, and listening to it.
#[cfg(feature = "relay")]
pub use prism_relay as relay;

use std::path::PathBuf;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0} is not a folder")]
    NotAGraph(PathBuf),
    /// A path that could lead out of the graph, or names nothing.
    #[error("not a path in the graph: {0:?}")]
    BadPath(String),
    /// A day's or a week's page is named by its date, and cannot be
    /// renamed; nor can a file that is no page.
    #[error("{0} cannot be renamed")]
    NotRenamable(String),
    /// Another page already answers to the title.
    #[error("another page is already called {0:?}")]
    TitleTaken(String),
    #[error("the page has no alias {0:?}")]
    NoSuchAlias(String),
    #[error("watching the graph's folder: {0}")]
    Watch(String),
    #[error("the graph's remote is not a GitHub repository")]
    NotOnGitHub,
    #[error("{context}: {source}")]
    Io {
        context: String,
        #[source]
        source: std::io::Error,
    },
    #[error(transparent)]
    Sync(#[from] prism_sync::Error),
    #[error(transparent)]
    Index(#[from] prism_index::Error),
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

impl Error {
    pub(crate) fn io(context: impl Into<String>, source: std::io::Error) -> Error {
        Error::Io { context: context.into(), source }
    }
}
