//! GitHub, for a sync engine.
//!
//! Git itself needs nothing from this crate but a token: `prism-sync`
//! pushes to GitHub as it pushes anywhere. This is the rest of what makes
//! GitHub first-class:
//!
//! - **[`auth`]** — signing in as a GitHub App's user (browser flow with
//!   PKCE, or the device flow), and a [`Session`] that keeps the tokens
//!   and renews them before they run out, so a sync always has a good one.
//! - **[`api`]** — who the token is (and so who commits are by), the
//!   repositories it can reach, a repository's id.
//! - **[`webhook`]** — checking a webhook's signature and reading its
//!   push event: how a relay learns the remote moved.
//!
//! # No I/O
//!
//! Every exchange is a function that builds a [`Request`] and a function
//! that reads a [`Response`] — plain data, see [`http`]. The crate never
//! opens a connection, so the same code runs in a native app, behind an
//! FFI, and in a Cloudflare Worker. For platforms with a blocking client,
//! [`Client`] and [`Session`] do the sending through an [`HttpClient`]
//! (one over `ureq` comes with the `ureq` feature).
//!
//! ```
//! use prism_github::{api, webhook, Response};
//!
//! // In a Worker: build, `fetch`, read.
//! let request = api::repo_request("ghu_token", "ada/notes");
//! assert_eq!(request.url, "https://api.github.com/repos/ada/notes");
//! # let response = Response::new(200, r#"{"id": 42, "full_name": "ada/notes"}"#);
//! let repo = api::parse_repo(&response)?;
//! assert_eq!(repo.id, 42);
//!
//! // A webhook arrives.
//! let body = br#"{"ref":"refs/heads/main","after":"abc","repository":{"id":42,"full_name":"ada/notes","default_branch":"main"}}"#;
//! let signature = webhook::sign("secret", body);
//! assert!(webhook::verify_signature("secret", body, Some(&signature)));
//! # Ok::<(), prism_github::Error>(())
//! ```

pub mod api;
pub mod auth;
pub mod http;
pub mod webhook;

pub use api::{clone_url, repository_from_remote, Client, Repo, User};
pub use auth::{App, MemoryStore, Session, TokenAnswer, TokenStore, Tokens};
pub use http::{HttpClient, Request, Response};
pub use webhook::{Event, Push};

#[cfg(feature = "ureq")]
pub use http::UreqClient;

/// What GitHub, or the way to it, can answer instead of what was asked.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// There was no answer: offline, a timeout.
    #[error("could not reach GitHub: {0}")]
    Network(String),
    /// GitHub did not know the token.
    #[error("GitHub did not accept the token")]
    Unauthorized,
    /// The token is known, but may not see what was asked for — or it is
    /// not there; GitHub does not say which.
    #[error("no access to that on GitHub")]
    NoAccess,
    /// There is no sign-in, or it can no longer be renewed: the person
    /// has to sign in again.
    #[error("not signed in to GitHub")]
    SignedOut,
    #[error("GitHub answered {status}: {body}")]
    Status { status: u16, body: String },
    /// An answer that does not read as what GitHub documents.
    #[error("unexpected answer from GitHub: {0}")]
    Unexpected(String),
}
