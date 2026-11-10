//! Signing in to GitHub, and staying signed in.
//!
//! A GitHub App's user tokens run out after eight hours and are renewed
//! with a refresh token that is good once. This module covers the three
//! exchanges — the browser's (with PKCE), the device flow's (for where
//! there is no browser to come back from), and the refresh — and
//! [`Session`], which keeps tokens in a [`TokenStore`] and hands out one
//! that is good for a while yet, refreshing first when it is running out.

use crate::http::{base64url, percent_encode, HttpClient, Request, Response};
use crate::Error;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::Mutex;

const AUTHORIZE: &str = "https://github.com/login/oauth/authorize";
const ACCESS_TOKEN: &str = "https://github.com/login/oauth/access_token";
const DEVICE_CODE: &str = "https://github.com/login/device/code";

/// The GitHub App (or OAuth app) signing in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct App {
    pub client_id: String,
    /// Needed by the browser flow of apps that have one; a GitHub App
    /// using PKCE or the device flow has none to keep.
    pub client_secret: Option<String>,
}

impl App {
    pub fn new(client_id: impl Into<String>) -> App {
        App { client_id: client_id.into(), client_secret: None }
    }

    /// The page where a person chooses which repositories an installed
    /// GitHub App may use, by the app's slug.
    pub fn install_url(slug: &str) -> String {
        format!("https://github.com/apps/{slug}/installations/new")
    }
}

/// What a sign-in gives: a token to act with, and the means to renew it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tokens {
    pub access_token: String,
    /// When the access token runs out, in seconds since the Unix epoch.
    /// `None`: it does not.
    pub expires_at: Option<u64>,
    pub refresh_token: Option<String>,
    pub refresh_expires_at: Option<u64>,
}

impl Tokens {
    /// Whether the access token is good for at least `margin` seconds more.
    pub fn is_fresh(&self, now: u64, margin: u64) -> bool {
        self.expires_at.is_none_or(|at| at > now + margin)
    }
}

/// The PKCE challenge for a verifier: its SHA-256, base64url. The
/// verifier is 43–128 characters of the caller's own randomness.
pub fn pkce_challenge(verifier: &str) -> String {
    base64url(&Sha256::digest(verifier.as_bytes()))
}

/// The page to send a browser to. GitHub sends it back to `redirect_uri`
/// with `code` and the same `state`.
pub fn authorize_url(app: &App, redirect_uri: &str, state: &str, pkce_verifier: &str) -> String {
    format!(
        "{AUTHORIZE}?client_id={}&redirect_uri={}&state={}&code_challenge={}&code_challenge_method=S256",
        percent_encode(&app.client_id),
        percent_encode(redirect_uri),
        percent_encode(state),
        pkce_challenge(pkce_verifier)
    )
}

fn token_request(app: &App, fields: &[(&str, &str)]) -> Request {
    let mut all = vec![("client_id", app.client_id.as_str())];
    if let Some(secret) = &app.client_secret {
        all.push(("client_secret", secret));
    }
    all.extend_from_slice(fields);
    Request::post(ACCESS_TOKEN).header("Accept", "application/json").header("User-Agent", "prism-sync").form(&all)
}

/// Trades the code the browser came back with for tokens.
pub fn exchange_code_request(app: &App, code: &str, redirect_uri: &str, pkce_verifier: &str) -> Request {
    token_request(app, &[("code", code), ("redirect_uri", redirect_uri), ("code_verifier", pkce_verifier)])
}

/// Trades a refresh token for new tokens. The refresh token is spent.
pub fn refresh_request(app: &App, refresh_token: &str) -> Request {
    token_request(app, &[("grant_type", "refresh_token"), ("refresh_token", refresh_token)])
}

/// Starts the device flow: asks for a code a person types in at GitHub.
pub fn device_code_request(app: &App) -> Request {
    Request::post(DEVICE_CODE).header("Accept", "application/json").header("User-Agent", "prism-sync").form(&[("client_id", &app.client_id)])
}

/// What to show a person signing in by the device flow.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct DeviceCode {
    pub device_code: String,
    /// The code to type in.
    pub user_code: String,
    /// Where to type it.
    pub verification_uri: String,
    /// Seconds until the code is no good.
    pub expires_in: u64,
    /// Seconds to wait between asks.
    #[serde(default = "five")]
    pub interval: u64,
}

fn five() -> u64 {
    5
}

pub fn parse_device_code(response: &Response) -> Result<DeviceCode, Error> {
    crate::api::expect_success(response)?.json()
}

/// Asks whether the person has typed the code in yet.
pub fn device_token_request(app: &App, device_code: &str) -> Request {
    token_request(app, &[("device_code", device_code), ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")])
}

/// How an ask for tokens was answered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenAnswer {
    Tokens(Tokens),
    /// The device flow's "not yet": ask again after the interval.
    Pending,
    /// The device flow's "too fast": wait longer between asks.
    SlowDown,
}

/// Reads the answer to any of the token requests. `now` is seconds since
/// the Unix epoch, to turn "expires in" into "expires at".
pub fn parse_token_answer(response: &Response, now: u64) -> Result<TokenAnswer, Error> {
    #[derive(Deserialize)]
    struct Answer {
        access_token: Option<String>,
        expires_in: Option<u64>,
        refresh_token: Option<String>,
        refresh_token_expires_in: Option<u64>,
        error: Option<String>,
        error_description: Option<String>,
    }
    // GitHub answers 200 even to say no; the body says which.
    let answer: Answer = response.json()?;
    match (answer.access_token, answer.error.as_deref()) {
        (Some(access_token), _) if !access_token.is_empty() => Ok(TokenAnswer::Tokens(Tokens {
            access_token,
            expires_at: answer.expires_in.map(|s| now + s),
            refresh_token: answer.refresh_token,
            refresh_expires_at: answer.refresh_token_expires_in.map(|s| now + s),
        })),
        (_, Some("authorization_pending")) => Ok(TokenAnswer::Pending),
        (_, Some("slow_down")) => Ok(TokenAnswer::SlowDown),
        // The refresh token was spent or revoked, or the code was no good:
        // only signing in again will do.
        (_, Some("bad_refresh_token" | "bad_verification_code" | "expired_token" | "access_denied" | "incorrect_client_credentials")) => Err(Error::SignedOut),
        (_, Some(error)) => Err(Error::Unexpected(format!("{error}: {}", answer.error_description.unwrap_or_default()))),
        _ => Err(Error::Unexpected("neither a token nor an error".into())),
    }
}

/// Where tokens are kept between runs: a keychain, a file.
pub trait TokenStore: Send + Sync {
    fn load(&self) -> Option<Tokens>;
    /// Keeps the tokens; `None` forgets them, on signing out.
    fn save(&self, tokens: Option<&Tokens>);
}

/// A [`TokenStore`] that forgets everything when the process ends.
#[derive(Default)]
pub struct MemoryStore(Mutex<Option<Tokens>>);

impl TokenStore for MemoryStore {
    fn load(&self) -> Option<Tokens> {
        self.0.lock().ok()?.clone()
    }

    fn save(&self, tokens: Option<&Tokens>) {
        if let Ok(mut kept) = self.0.lock() {
            *kept = tokens.cloned();
        }
    }
}

/// A sign-in that lasts: tokens kept in a store, renewed before they run
/// out. Safe to share between threads — and it must be: a refresh token
/// is good once, so two refreshes at a time would sign the app out. Every
/// caller waits on the one.
pub struct Session<H: HttpClient, S: TokenStore> {
    app: App,
    http: H,
    store: S,
    /// Held across a refresh.
    refreshing: Mutex<()>,
    clock: fn() -> u64,
}

fn system_clock() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl<H: HttpClient, S: TokenStore> Session<H, S> {
    /// An access token must be good for this much longer to be handed
    /// out: a sync started with it should finish with it.
    pub const MARGIN_SECONDS: u64 = 300;

    pub fn new(app: App, http: H, store: S) -> Self {
        Session { app, http, store, refreshing: Mutex::new(()), clock: system_clock }
    }

    /// Uses another clock: for tests.
    pub fn with_clock(mut self, clock: fn() -> u64) -> Self {
        self.clock = clock;
        self
    }

    pub fn is_signed_in(&self) -> bool {
        self.store.load().is_some()
    }

    /// Keeps the tokens a sign-in gave.
    pub fn signed_in(&self, tokens: &Tokens) {
        self.store.save(Some(tokens));
    }

    pub fn sign_out(&self) {
        self.store.save(None);
    }

    /// Finishes the browser's flow: trades its code for tokens, and keeps them.
    pub fn exchange_code(&self, code: &str, redirect_uri: &str, pkce_verifier: &str) -> Result<Tokens, Error> {
        let response = self.http.send(exchange_code_request(&self.app, code, redirect_uri, pkce_verifier)).map_err(Error::Network)?;
        match parse_token_answer(&response, (self.clock)())? {
            TokenAnswer::Tokens(tokens) => {
                self.store.save(Some(&tokens));
                Ok(tokens)
            }
            _ => Err(Error::Unexpected("the code exchange was left pending".into())),
        }
    }

    /// A token good for a while yet: renewed first when it is running
    /// out. [`Error::SignedOut`] when there is none and no way to get one.
    pub fn access_token(&self) -> Result<String, Error> {
        let guard = self.refreshing.lock().map_err(|_| Error::Unexpected("a refresh panicked".into()))?;
        let now = (self.clock)();
        let tokens = self.store.load().ok_or(Error::SignedOut)?;
        if tokens.is_fresh(now, Self::MARGIN_SECONDS) {
            return Ok(tokens.access_token);
        }
        let refresh = tokens.refresh_token.as_deref().ok_or(Error::SignedOut)?;
        let response = self.http.send(refresh_request(&self.app, refresh)).map_err(Error::Network)?;
        match parse_token_answer(&response, now) {
            Ok(TokenAnswer::Tokens(renewed)) => {
                self.store.save(Some(&renewed));
                drop(guard);
                Ok(renewed.access_token)
            }
            Err(Error::SignedOut) => {
                // The refresh token is spent: nothing kept is any good.
                self.store.save(None);
                Err(Error::SignedOut)
            }
            Ok(_) => Err(Error::Unexpected("a refresh was left pending".into())),
            // Offline, or GitHub is down: the tokens are kept for next time.
            Err(other) => Err(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn pkce_and_the_authorize_url() {
        // RFC 7636, appendix B.
        assert_eq!(pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
        let url = authorize_url(&App::new("Iv1.abc"), "prism://oauth/callback", "st ate", "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk");
        assert_eq!(url, "https://github.com/login/oauth/authorize?client_id=Iv1.abc&redirect_uri=prism%3A%2F%2Foauth%2Fcallback&state=st%20ate&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256");
        assert_eq!(App::install_url("prism-notes"), "https://github.com/apps/prism-notes/installations/new");
    }

    #[test]
    fn token_answers() {
        let answer = |body: &str| parse_token_answer(&Response::new(200, body), 1000);
        let TokenAnswer::Tokens(tokens) =
            answer(r#"{"access_token":"ghu_a","expires_in":28800,"refresh_token":"ghr_r","refresh_token_expires_in":15897600,"token_type":"bearer"}"#).unwrap()
        else {
            panic!()
        };
        assert_eq!(
            tokens,
            Tokens { access_token: "ghu_a".into(), expires_at: Some(29800), refresh_token: Some("ghr_r".into()), refresh_expires_at: Some(15898600) }
        );
        assert!(tokens.is_fresh(29000, 300) && !tokens.is_fresh(29600, 300));
        // A token that never runs out.
        let TokenAnswer::Tokens(forever) = answer(r#"{"access_token":"gho_a"}"#).unwrap() else { panic!() };
        assert!(forever.is_fresh(u64::MAX - 1000, 300));
        assert_eq!(answer(r#"{"error":"authorization_pending"}"#).unwrap(), TokenAnswer::Pending);
        assert_eq!(answer(r#"{"error":"slow_down"}"#).unwrap(), TokenAnswer::SlowDown);
        assert!(matches!(answer(r#"{"error":"bad_refresh_token"}"#), Err(Error::SignedOut)));
        assert!(matches!(answer(r#"{"error":"something_new","error_description":"x"}"#), Err(Error::Unexpected(_))));
        assert!(matches!(answer("<html>"), Err(Error::Unexpected(_))));
    }

    #[test]
    fn requests_carry_what_github_asks_for() {
        let app = App::new("Iv1.abc");
        let body = |r: &Request| String::from_utf8(r.body.clone()).unwrap();
        assert_eq!(
            body(&exchange_code_request(&app, "c0de", "prism://cb", "ver")),
            "client_id=Iv1.abc&code=c0de&redirect_uri=prism%3A%2F%2Fcb&code_verifier=ver"
        );
        assert_eq!(body(&refresh_request(&app, "ghr_r")), "client_id=Iv1.abc&grant_type=refresh_token&refresh_token=ghr_r");
        assert_eq!(body(&device_code_request(&app)), "client_id=Iv1.abc");
        assert!(body(&device_token_request(&app, "dc")).ends_with("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"));
        let with_secret = App { client_secret: Some("s3".into()), ..app };
        assert!(body(&refresh_request(&with_secret, "r")).starts_with("client_id=Iv1.abc&client_secret=s3&"));
        let code = parse_device_code(&Response::new(
            200,
            r#"{"device_code":"dc","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900}"#,
        ))
        .unwrap();
        assert_eq!((code.user_code.as_str(), code.interval), ("WDJB-MJHT", 5));
    }

    static REFRESHES: AtomicUsize = AtomicUsize::new(0);

    fn renewing_http(request: Request) -> Result<Response, String> {
        let n = REFRESHES.fetch_add(1, Ordering::SeqCst) + 1;
        assert!(String::from_utf8(request.body).unwrap().contains("refresh_token=ghr_"));
        Ok(Response::new(200, format!(r#"{{"access_token":"ghu_new{n}","expires_in":28800,"refresh_token":"ghr_new{n}"}}"#)))
    }

    #[test]
    fn a_session_renews_a_token_that_is_running_out_once() {
        let session = Session::new(App::new("id"), renewing_http, MemoryStore::default()).with_clock(|| 10_000);
        assert!(matches!(session.access_token(), Err(Error::SignedOut)));
        session.signed_in(&Tokens {
            access_token: "ghu_old".into(),
            expires_at: Some(20_000),
            refresh_token: Some("ghr_old".into()),
            refresh_expires_at: None,
        });
        // Good for long enough: handed out as it is, nothing asked.
        assert_eq!(session.access_token().unwrap(), "ghu_old");
        assert_eq!(REFRESHES.load(Ordering::SeqCst), 0);

        // Running out: renewed, kept, and the new one handed out after.
        session.signed_in(&Tokens {
            access_token: "ghu_old".into(),
            expires_at: Some(10_100),
            refresh_token: Some("ghr_old".into()),
            refresh_expires_at: None,
        });
        assert_eq!(session.access_token().unwrap(), "ghu_new1");
        assert_eq!(session.access_token().unwrap(), "ghu_new1");
        assert_eq!(REFRESHES.load(Ordering::SeqCst), 1);
        session.sign_out();
        assert!(!session.is_signed_in());
    }

    #[test]
    fn a_spent_refresh_token_signs_out_but_a_network_failure_does_not() {
        let stale = Tokens { access_token: "ghu_old".into(), expires_at: Some(5), refresh_token: Some("ghr_spent".into()), refresh_expires_at: None };
        let offline = Session::new(App::new("id"), |_: Request| Err::<Response, _>("offline".to_owned()), MemoryStore::default());
        offline.signed_in(&stale);
        assert!(matches!(offline.access_token(), Err(Error::Network(_))));
        assert!(offline.is_signed_in(), "being offline is no reason to forget the sign-in");

        let refused = Session::new(App::new("id"), |_: Request| Ok(Response::new(200, r#"{"error":"bad_refresh_token"}"#)), MemoryStore::default());
        refused.signed_in(&stale);
        assert!(matches!(refused.access_token(), Err(Error::SignedOut)));
        assert!(!refused.is_signed_in());
        // With no refresh token at all, a stale token is the end.
        refused.signed_in(&Tokens { refresh_token: None, ..stale });
        assert!(matches!(refused.access_token(), Err(Error::SignedOut)));
    }
}
