//! A git sync engine.
//!
//! Keeps a folder of files in step across devices through an ordinary git
//! repository — on GitHub, or anywhere git can push. It knows nothing of
//! notes: it syncs files, and takes what it needs to know about them as
//! two small traits.
//!
//! # The pieces
//!
//! | | |
//! |---|---|
//! | [`Repository`] | The git operations a sync is made of: [snapshot](Repository::snapshot) the working tree, [diff](Repository::changes) two trees, commit, [apply](Repository::apply) a tree to the working tree, fetch, push. |
//! | [`Syncer`] | One sync cycle: repair, commit, fetch, merge, push. See [`sync`]. |
//! | [`merge`] | Merging two commits in memory, every conflict settled by rule, so a sync never stops. |
//! | [`textmerge`], [`conflict`] | Three-way text merge, and the markers a conflict is carried in. Useful on their own. |
//! | [`Scheduler`] | When to run a cycle: after typing pauses, on demand, with backoff. A pure state machine. |
//! | [`Auth`], [`TokenSource`] | Who is syncing. |
//!
//! What the engine does not know, it asks:
//!
//! - a [`MergeDriver`] merges files whose form it knows (a note's
//!   frontmatter, field by field);
//! - a [`Describe`] words commit messages ("Update daily note for …").
//!
//! # Snapshots
//!
//! The idea the rest is built on: [`Repository::snapshot`] hashes the
//! working tree into a git **tree** without committing, staging or moving
//! anything. A tree id is a content hash of the whole graph, so
//!
//! - *is there anything to commit?* is one comparison;
//! - *what changed between then and now?* is [`Repository::changes`],
//!   whose cost is the size of the difference, not of the graph;
//! - anything derived from the files — a search index, backlinks — can
//!   note the tree it was built from, and later be brought up to date by
//!   ingesting only the difference. That is `prism-index`.
//!
//! # Using it
//!
//! ```no_run
//! use prism_sync::{Auth, Config, Mode, Repository, Syncer};
//!
//! let repo = Repository::open("/path/to/graph")?;
//! let mut syncer = Syncer::new(repo, Config { device: Some("Ada's Mac".into()), ..Config::default() })
//!     .with_auth(Auth::token("github_pat_…"));
//! let report = syncer.sync(Mode::Full)?;
//! println!("{report}");               // committed “Update 2 files”, 3 changes pulled, pushed
//! for path in &report.changed { /* re-read what is on screen */ }
//! # Ok::<(), prism_sync::Error>(())
//! ```
//!
//! Git is libgit2, built in: there is no `git` to install, on a Mac or a
//! phone.

pub mod auth;
pub mod conflict;
pub mod error;
pub mod merge;
pub mod repo;
pub mod schedule;
pub mod sync;
pub mod textmerge;

pub use auth::{https_for, Auth, TokenSource};
pub use error::{Error, Result};
pub use merge::{FileMerge, MergeDriver, TreeMerge};
pub use repo::{
    Applied, Change, ChangeKind, ClonePart, CloneProgress, CommitNode, CommitSummary, Entry, Identity, Oid, PushOutcome, Repository, Snapshot, SnapshotOptions,
};
pub use schedule::{Schedule, Scheduler};
pub use sync::{Config, Describe, MergeKind, Mode, Pending, PlainDescriber, Report, StopHandle, Syncer};
pub use textmerge::{Labels, Merged};
