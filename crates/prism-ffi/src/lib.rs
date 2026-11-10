//! Prism's engine, for Swift.
//!
//! The apps are Swift; the engine is Rust. This crate is the seam: the
//! part of [`prism`] an app needs, shaped so that [UniFFI] can generate
//! the Swift (or Kotlin) on the other side. It adds no behaviour — every
//! function here is a thin wrapper — only a boundary that crosses well:
//!
//! - **[`PrismEngine`]** — a graph kept synced and indexed: files, sync,
//!   the indices' questions, queries, rivers. Events come back through an
//!   [`EngineObserver`] the app implements; a GitHub token is asked of a
//!   [`TokenProvider`] the app implements.
//! - **[`NoteDocument`]** — one note being edited: rows, the outline's
//!   commands, frontmatter.
//! - Functions on text: the spans in a row ([`inline_spans`]), toggling
//!   a style, conflicts, merging.
//!
//! Three rules shape it. Text positions are **UTF-16** offsets, as
//! `NSString` and TextKit count. Rows are named by **path** (`[UInt32]`).
//! And nothing here blocks on the network except what says it waits
//! ([`PrismEngine::sync_now`]); the rest returns at once and reports
//! through the observer.
//!
//! # Building for Swift
//!
//! ```sh
//! crates/prism-ffi/build-swift.sh        # → crates/prism-ffi/swift/
//! ```
//!
//! makes the library, generates `prism_ffi.swift` with its C header and
//! module map, and runs the Swift test in `swift/Tests`. See the README
//! beside this crate for using the result from Xcode or SwiftPM.
//!
//! [UniFFI]: https://mozilla.github.io/uniffi-rs/

mod document;
mod editing;
mod engine;
mod github;

pub use document::*;
pub use editing::*;
pub use engine::*;
pub use github::*;

uniffi::setup_scaffolding!();

/// Anything that went wrong, with words to show.
#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum PrismError {
    /// Signing in again is what it takes.
    #[error("{0}")]
    SignedOut(String),
    /// It may work if tried again: the network was down, the remote busy.
    #[error("{0}")]
    Transient(String),
    #[error("{0}")]
    Failed(String),
}

impl From<prism::Error> for PrismError {
    fn from(error: prism::Error) -> Self {
        match &error {
            prism::Error::Sync(prism::sync::Error::Auth(_)) => PrismError::SignedOut(error.to_string()),
            prism::Error::Sync(sync) if sync.is_transient() => PrismError::Transient(error.to_string()),
            _ => PrismError::Failed(error.to_string()),
        }
    }
}

impl From<prism::index::Error> for PrismError {
    fn from(error: prism::index::Error) -> Self {
        PrismError::Failed(error.to_string())
    }
}

impl From<prism::SyncFailure> for PrismError {
    fn from(failure: prism::SyncFailure) -> Self {
        if failure.needs_sign_in {
            PrismError::SignedOut(failure.message)
        } else if failure.will_retry {
            PrismError::Transient(failure.message)
        } else {
            PrismError::Failed(failure.message)
        }
    }
}

/// A foreign callback that threw something unexpected.
impl From<uniffi::UnexpectedUniFFICallbackError> for PrismError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        PrismError::Failed(error.reason)
    }
}

/// Makes a bare repository — one with no working tree, to be pushed to:
/// a remote on a disk, or a test's stand-in for GitHub.
#[uniffi::export]
pub fn create_bare_repository(path: String, branch: String) -> Result<(), PrismError> {
    prism::sync::Repository::init_bare(&path, &branch).map_err(|error| PrismError::Failed(error.to_string()))
}

/// A title as a file's name: `Project Atlas` → `project-atlas`.
#[uniffi::export]
pub fn slug(title: String) -> String {
    prism::slug(&title)
}

/// The key two names are compared by: case and spacing aside.
#[uniffi::export]
pub fn name_key(name: String) -> String {
    prism::markup::name_key(&name)
}

/// The river a link's target names — `rivers/Work` is `Work` — if any.
#[uniffi::export]
pub fn river_name(link_target: String) -> Option<String> {
    prism::markup::river::name_of(&link_target).map(str::to_owned)
}
