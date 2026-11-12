//! Dictation's tokens.
//!
//! The apps have words spoken into them written down by ElevenLabs'
//! realtime transcription (Scribe), which a device reaches itself, over a
//! WebSocket, with a **single-use token** good for one dictation. The
//! relay is where that token comes from: it keeps the account's key — a
//! secret of the Worker's, never shipped in an app — and asks ElevenLabs
//! for a token on behalf of a device that shows it a GitHub token of
//! someone allowed to dictate.
//!
//! ```text
//! device ── POST /scribe-token, Authorization: Bearer <GitHub token> ──▶ relay
//!   relay ── GET /user ──▶ GitHub                  who is this?
//!   relay ── POST /v1/single-use-token/realtime_scribe ──▶ ElevenLabs
//! device ◀── {"token": "…"} ── relay
//! device ── wss://api.elevenlabs.io/v1/speech-to-text/realtime?token=… ──▶ ElevenLabs
//! ```
//!
//! As everywhere in this crate, the decisions are here and pure; the
//! Worker sends what these functions ask for.

use crate::relay::Reply;
use prism_github::api;
use prism_github::http::{hex, Request, Response};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Where ElevenLabs hands out a token for one realtime transcription.
const TOKENS: &str = "https://api.elevenlabs.io/v1/single-use-token/realtime_scribe";

/// What the relay answers a device with, and what ElevenLabs answers the
/// relay with: the token, good for one dictation, for fifteen minutes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Token {
    pub token: String,
}

/// Whether a GitHub user may dictate: one of the comma-separated logins
/// allowed, case aside. None allowed, no one may — the key is one
/// account's, and what is said through it is paid for by that account.
pub fn may_dictate(login: &str, allowed: &str) -> bool {
    allowed.split(',').map(str::trim).any(|one| !one.is_empty() && one.eq_ignore_ascii_case(login))
}

/// Asks GitHub who a device's token is.
pub fn who_request(github_token: &str) -> Request {
    api::user_request(github_token)
}

/// The login a token is, allowed to dictate — or the reply that turns
/// the device away: GitHub does not know the token, or its user is not
/// one of those `allowed`.
pub fn who(response: &Response, allowed: &str) -> Result<String, Reply> {
    let user = api::parse_user(response).map_err(|_| Reply::new(401, "GitHub does not know that token\n"))?;
    if may_dictate(&user.login, allowed) {
        Ok(user.login)
    } else {
        Err(Reply::new(403, "Dictation is not set up for this account\n"))
    }
}

/// A key to remember who a token is under for a few minutes
/// ([`crate::relay::ACCESS_CACHE_SECONDS`]), so each dictation does not
/// cost a call to GitHub. A hash of the token: the token is never kept.
pub fn who_cache_key(github_token: &str) -> String {
    format!("who/{}", hex(&Sha256::digest(github_token.as_bytes())))
}

/// Asks ElevenLabs for a token, with the account's key.
pub fn token_request(api_key: &str) -> Request {
    Request::post(TOKENS).header("xi-api-key", api_key)
}

/// The token ElevenLabs gave, as the relay hands it on — or the reply
/// that says it gave none.
pub fn token(response: &Response) -> Result<Token, Reply> {
    if !response.is_success() {
        return Err(Reply::new(502, "ElevenLabs refused a token\n"));
    }
    response.json::<Token>().ok().filter(|given| !given.token.is_empty()).ok_or_else(|| Reply::new(502, "ElevenLabs gave no token\n"))
}

/// The reply for a relay with no key: dictation is not set up on it.
pub fn no_key() -> Reply {
    Reply::new(503, "Dictation is not set up on this relay\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_those_allowed_may_dictate() {
        assert!(may_dictate("Ada", "grace, ada ,"));
        assert!(!may_dictate("ada", "") && !may_dictate("", "ada,") && !may_dictate("adal", "ada"));
        let ada = Response::new(200, r#"{"id":1,"login":"Ada"}"#);
        assert_eq!(who(&ada, "ada").as_deref(), Ok("Ada"));
        assert_eq!(who(&ada, "grace").unwrap_err().status, 403);
        assert_eq!(who(&Response::new(401, "{}"), "ada").unwrap_err().status, 401);
    }

    #[test]
    fn a_token_is_asked_for_with_the_key_and_handed_on() {
        let request = token_request("sk-test");
        assert_eq!((request.method, request.url.as_str(), request.header_value("xi-api-key")), ("POST", TOKENS, Some("sk-test")));
        assert_eq!(token(&Response::new(200, r#"{"token":"abc"}"#)), Ok(Token { token: "abc".into() }));
        assert_eq!(token(&Response::new(200, r#"{"token":""}"#)).unwrap_err().status, 502);
        assert_eq!(token(&Response::new(401, "no")).unwrap_err().status, 502);
        // Remembered under a hash, never the token itself.
        assert!(!who_cache_key("ghu_secret").contains("ghu_secret") && who_cache_key("a") != who_cache_key("b"));
    }
}
