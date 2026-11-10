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

/// The HTTPS address of a remote written for SSH: `git@github.com:o/r.git`
/// and `ssh://git@github.com/o/r.git` are `https://github.com/o/r.git`.
/// `None` for an address that is not SSH's.
///
/// A token is a thing given over HTTPS. A checkout made at a terminal
/// commonly names its remote the SSH way, with the keys kept by an agent
/// an app cannot reach — a phone has none at all. So where a token is
/// what there is, such a remote is asked at the same host over HTTPS, and
/// its configuration is left as it was.
pub fn https_for(url: &str) -> Option<String> {
    let (host, path) = match url.strip_prefix("ssh://") {
        Some(rest) => {
            let (authority, path) = rest.split_once('/')?;
            let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
            (host.split_once(':').map_or(host, |(host, _port)| host), path)
        }
        None => {
            // `user@host:path`, as scp writes it: no scheme, and no slash before the colon.
            let (authority, path) = url.split_once(':')?;
            let (_, host) = authority.split_once('@')?;
            if authority.contains('/') || path.starts_with("//") {
                return None;
            }
            (host, path)
        }
    };
    (!host.is_empty() && !path.is_empty()).then(|| format!("https://{host}/{}", path.trim_start_matches('/')))
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

    /// The address to ask a remote at, when it is not the one it is
    /// configured with: with a token, an SSH remote's HTTPS address.
    pub(crate) fn address_for(&self, configured: &str) -> Option<String> {
        match self {
            Auth::Token(_) => https_for(configured),
            Auth::Default => None,
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_ssh_remote_has_an_https_address() {
        assert_eq!(https_for("git@github.com:ada/notes.git").as_deref(), Some("https://github.com/ada/notes.git"));
        assert_eq!(https_for("ssh://git@github.com/ada/notes.git").as_deref(), Some("https://github.com/ada/notes.git"));
        assert_eq!(https_for("ssh://git@git.example.com:2222/team/graph").as_deref(), Some("https://git.example.com/team/graph"));
        for other in [
            "https://github.com/ada/notes.git",
            "/Users/ada/remote.git",
            "../remote.git",
            "file:///tmp/remote.git",
            "C:/remote",
            "http://x/y",
            "git@github.com:",
        ] {
            assert_eq!(https_for(other), None, "{other}");
        }
        // Only where a token is what there is.
        assert_eq!(Auth::token("t").address_for("git@github.com:a/b.git").as_deref(), Some("https://github.com/a/b.git"));
        assert_eq!(Auth::Default.address_for("git@github.com:a/b.git"), None);
    }
}
