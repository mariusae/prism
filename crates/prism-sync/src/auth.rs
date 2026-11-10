//! Proving who is syncing.
//!
//! A remote over HTTPS is given a token — for GitHub, an app's user token
//! or a personal one — as the password of `x-access-token`. The token
//! comes from a [`TokenSource`], asked afresh for each operation, so one
//! that refreshes expiring tokens (as `prism-github`'s does) always hands
//! over a good one.

use crate::error::Error;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

/// Where a token comes from. Called on the sync's thread, each time a
/// remote asks who is there.
pub trait TokenSource: Send + Sync {
    /// A token good for a while yet, or why there is none.
    fn token(&self) -> Result<String, String>;
}

impl TokenSource for String {
    fn token(&self) -> Result<String, String> {
        Ok(self.clone())
    }
}

impl<F: Fn() -> Result<String, String> + Send + Sync> TokenSource for F {
    fn token(&self) -> Result<String, String> {
        self()
    }
}

/// How a remote is told who is syncing.
#[derive(Clone, Default)]
pub enum Auth {
    /// Whatever git would do unasked: a local path, a public repository,
    /// a credential helper.
    #[default]
    Default,
    /// A token, sent as the password of `x-access-token`.
    Token(Arc<dyn TokenSource>),
}

impl Auth {
    /// A fixed token.
    pub fn token(token: impl Into<String>) -> Auth {
        Auth::Token(Arc::new(token.into()))
    }

    /// A source asked each time.
    pub fn source(source: impl TokenSource + 'static) -> Auth {
        Auth::Token(Arc::new(source))
    }

    /// The token a remote would be given now; `None` when there is none
    /// to give. For whoever else must prove the same identity — a relay.
    pub fn current_token(&self) -> Option<Result<String, String>> {
        match self {
            Auth::Default => None,
            Auth::Token(source) => Some(source.token()),
        }
    }

    pub(crate) fn callbacks(&self) -> git2::RemoteCallbacks<'static> {
        let mut callbacks = git2::RemoteCallbacks::new();
        let auth = self.clone();
        // libgit2 asks again when turned away; a token that was refused
        // once will be refused again, so it is offered once.
        let asked = AtomicUsize::new(0);
        callbacks.credentials(move |_url, username, allowed| {
            if asked.fetch_add(1, Ordering::Relaxed) > 0 {
                return Err(git2::Error::from_str("the remote did not accept the credentials"));
            }
            match &auth {
                Auth::Token(source) if allowed.contains(git2::CredentialType::USER_PASS_PLAINTEXT) => {
                    let token = source.token().map_err(|why| git2::Error::from_str(&format!("no token: {why}")))?;
                    git2::Cred::userpass_plaintext("x-access-token", &token)
                }
                _ if allowed.contains(git2::CredentialType::USERNAME) => git2::Cred::username(username.unwrap_or("git")),
                _ => git2::Cred::default(),
            }
        });
        callbacks
    }

    /// A remote operation's failure, told apart: not signed in, or
    /// whatever `otherwise` makes of it.
    pub(crate) fn explain(&self, error: git2::Error, otherwise: impl FnOnce(String) -> Error) -> Error {
        let message = error.message().to_owned();
        if error.code() == git2::ErrorCode::Auth || message.contains("no token") || message.contains("did not accept the credentials") {
            Error::Auth(message)
        } else {
            otherwise(message)
        }
    }
}
