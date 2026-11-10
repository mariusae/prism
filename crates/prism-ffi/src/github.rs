//! A GitHub account, for Swift: signing in, the token a sync proves
//! itself with, and the repositories a graph can be kept in.
//!
//! All of it is the `prism-github` crate's; this gives it a shape an app
//! can hold. The app's own part is two things only: showing the sign-in
//! page (a web authentication session), and keeping the tokens where the
//! platform keeps secrets ([`TokenVault`] — the keychain).

use crate::PrismError;
use prism::github::{self, App, Client, Session, TokenStore, Tokens, UreqClient};
use std::sync::Arc;

type Result<T, E = PrismError> = std::result::Result<T, E>;

impl From<github::Error> for PrismError {
    fn from(error: github::Error) -> Self {
        match &error {
            github::Error::SignedOut | github::Error::Unauthorized => PrismError::SignedOut(error.to_string()),
            github::Error::Network(_) => PrismError::Transient(error.to_string()),
            _ => PrismError::Failed(error.to_string()),
        }
    }
}

/// Where the account's tokens are kept between runs: the keychain. What
/// is kept is one opaque string; `nil` forgets it, on signing out.
#[uniffi::export(with_foreign)]
pub trait TokenVault: Send + Sync {
    fn load(&self) -> Option<String>;
    fn save(&self, tokens: Option<String>);
}

struct Vault(Arc<dyn TokenVault>);

impl TokenStore for Vault {
    fn load(&self) -> Option<Tokens> {
        serde_json::from_str(&self.0.load()?).ok()
    }

    fn save(&self, tokens: Option<&Tokens>) {
        self.0.save(tokens.and_then(|tokens| serde_json::to_string(tokens).ok()));
    }
}

/// A sign-in begun: the page to show, and what to hand back with the
/// code the page ends on.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SignIn {
    /// The page to show the person, in a web authentication session.
    pub url: String,
    /// What the callback's `state` must be: anything else is not ours.
    pub state: String,
    /// Kept by the app until the callback, and given to `finish_sign_in`.
    pub verifier: String,
}

/// The account signed in.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GitHubUser {
    pub login: String,
    /// The name commits are made under.
    pub name: String,
    /// The address commits are made as: GitHub's private one for the account.
    pub email: String,
}

/// A repository a graph can be kept in.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GitHubRepository {
    /// `owner/name`.
    pub full_name: String,
    pub is_private: bool,
    pub default_branch: String,
    /// The address to clone it from.
    pub clone_url: String,
}

fn repository(repo: github::Repo) -> GitHubRepository {
    let clone_url = if repo.clone_url.is_empty() { github::clone_url(&repo.full_name) } else { repo.clone_url };
    GitHubRepository { full_name: repo.full_name, is_private: repo.private, default_branch: repo.default_branch, clone_url }
}

/// So many characters of the system's randomness, from an alphabet safe
/// in a URL.
fn random_text(length: usize) -> Result<String> {
    use std::io::Read;
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut bytes = vec![0u8; length];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut source| source.read_exact(&mut bytes))
        .map_err(|error| PrismError::Failed(format!("no randomness: {error}")))?;
    Ok(bytes.iter().map(|byte| ALPHABET[(byte & 63) as usize] as char).collect())
}

/// A GitHub account: signed in once, its token renewed as it runs out.
/// Safe to share; every caller that needs a token waits on the one
/// renewal.
#[derive(uniffi::Object)]
pub struct GitHubAccount {
    app: App,
    session: Session<UreqClient, Vault>,
}

#[uniffi::export]
impl GitHubAccount {
    /// The account of a GitHub App, by its client id (and secret, for an
    /// app whose browser flow needs one), its tokens kept in `vault`.
    #[uniffi::constructor]
    pub fn new(client_id: String, client_secret: Option<String>, vault: Arc<dyn TokenVault>) -> Arc<GitHubAccount> {
        let app = App { client_id, client_secret: client_secret.filter(|secret| !secret.is_empty()) };
        Arc::new(GitHubAccount { session: Session::new(app.clone(), UreqClient::default(), Vault(vault)), app })
    }

    pub fn is_signed_in(&self) -> bool {
        self.session.is_signed_in()
    }

    /// Begins signing in: the page to show, which ends by opening
    /// `redirect_uri` with a `code` and the `state` given here.
    pub fn begin_sign_in(&self, redirect_uri: String) -> Result<SignIn> {
        let (state, verifier) = (random_text(32)?, random_text(64)?);
        Ok(SignIn { url: github::auth::authorize_url(&self.app, &redirect_uri, &state, &verifier), state, verifier })
    }

    /// Finishes signing in, with the code the page ended on: the tokens
    /// are fetched, and kept in the vault.
    pub fn finish_sign_in(&self, code: String, redirect_uri: String, verifier: String) -> Result<()> {
        self.session.exchange_code(&code, &redirect_uri, &verifier)?;
        Ok(())
    }

    pub fn sign_out(&self) {
        self.session.sign_out();
    }

    /// A token good for a while yet, renewed first if it is running out:
    /// what a sync, or the relay, is given.
    pub fn access_token(&self) -> Result<String> {
        Ok(self.session.access_token()?)
    }

    /// Whose account it is.
    pub fn user(&self) -> Result<GitHubUser> {
        let http = UreqClient::default();
        let user = Client::new(&http, self.session.access_token()?).user()?;
        Ok(GitHubUser { name: user.display_name().to_owned(), email: user.noreply_email(), login: user.login })
    }

    /// The repositories the app has been let into: where a graph may be.
    pub fn repositories(&self) -> Result<Vec<GitHubRepository>> {
        let http = UreqClient::default();
        Ok(Client::new(&http, self.session.access_token()?).app_repositories()?.into_iter().map(repository).collect())
    }

    /// Makes a repository in the account, for a new graph.
    pub fn create_repository(&self, name: String, is_private: bool) -> Result<GitHubRepository> {
        let http = UreqClient::default();
        Ok(repository(Client::new(&http, self.session.access_token()?).create_repository(&name, is_private)?))
    }
}

/// The page where a person chooses which repositories an installed
/// GitHub App may use, by the app's slug.
#[uniffi::export]
pub fn github_install_url(app_slug: String) -> String {
    App::install_url(&app_slug)
}

/// `owner/name`, from a GitHub remote's address; `nil` for a remote that
/// is not on GitHub.
#[uniffi::export]
pub fn github_repository_of(remote_url: String) -> Option<String> {
    github::repository_from_remote(&remote_url)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[derive(Default)]
    struct Kept(Mutex<Option<String>>);

    impl TokenVault for Kept {
        fn load(&self) -> Option<String> {
            self.0.lock().unwrap().clone()
        }
        fn save(&self, tokens: Option<String>) {
            *self.0.lock().unwrap() = tokens;
        }
    }

    #[test]
    fn a_sign_in_is_begun_with_randomness_and_kept_in_the_vault() {
        let vault = Arc::new(Kept::default());
        let account = GitHubAccount::new("Iv1.abc".into(), Some(String::new()), vault.clone());
        assert!(!account.is_signed_in());
        assert!(matches!(account.access_token(), Err(PrismError::SignedOut(_))));
        let (one, two) = (account.begin_sign_in("weft://oauth".into()).unwrap(), account.begin_sign_in("weft://oauth".into()).unwrap());
        assert!(one.url.starts_with("https://github.com/login/oauth/authorize?client_id=Iv1.abc&redirect_uri=weft%3A%2F%2Foauth&state="));
        assert!(one.url.contains(&one.state) && one.verifier.len() == 64 && one.state != two.state && one.verifier != two.verifier);
        // Tokens that do not run out are handed over as they are, and survive in the vault.
        vault.save(Some(r#"{"access_token":"ghu_a","expires_at":null,"refresh_token":null,"refresh_expires_at":null}"#.into()));
        assert!(account.is_signed_in());
        assert_eq!(account.access_token().unwrap(), "ghu_a");
        account.sign_out();
        assert!(vault.load().is_none() && !account.is_signed_in());
        assert_eq!(github_repository_of("git@github.com:ada/notes.git".into()).as_deref(), Some("ada/notes"));
    }
}
