//! What can go wrong in a sync.

/// A sync's failure. Every variant leaves the repository in a state the
/// next cycle can go on from: nothing committed is lost, and no merge is
/// left half done.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// libgit2 said no.
    #[error("git: {0}")]
    Git(#[from] git2::Error),

    #[error("{context}: {source}")]
    Io {
        context: String,
        #[source]
        source: std::io::Error,
    },

    /// The repository is in a state the sync will not guess its way out
    /// of — a detached HEAD no branch leads to, an operation it could not
    /// leave. Someone has to look.
    #[error("{0}")]
    State(String),

    /// Fetching failed: offline, or not let in.
    #[error("fetching failed: {0}")]
    Fetch(String),

    /// Pushing failed before the remote had its say: offline, cut off.
    #[error("pushing failed: {0}")]
    Push(String),

    /// The remote refused the push for a reason other than being behind.
    #[error("the remote rejected the push: {0}")]
    Rejected(String),

    /// The remote kept moving: every push attempt found it changed again.
    /// The next cycle tries again.
    #[error("the remote kept changing while syncing; it will be tried again")]
    Contended,

    /// The cycle was asked to stop, and did, at a safe point. What it
    /// committed stays. Not a failure to show anyone.
    #[error("the sync stopped, to go on next time")]
    Stopped,

    /// No token, or the token source failed.
    #[error("not signed in: {0}")]
    Auth(String),
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

impl Error {
    pub(crate) fn io(context: impl Into<String>) -> impl FnOnce(std::io::Error) -> Error {
        let context = context.into();
        move |source| Error::Io { context, source }
    }

    /// Whether trying again later, with nothing changed, could work: the
    /// network was down, the remote was busy.
    pub fn is_transient(&self) -> bool {
        matches!(self, Error::Fetch(_) | Error::Push(_) | Error::Contended | Error::Stopped)
    }
}
