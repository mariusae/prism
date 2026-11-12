//! The relay's decisions, with no I/O.
//!
//! The relay is three routes and a hub per repository:
//!
//! | Route | From | Does |
//! |---|---|---|
//! | `POST /github` | GitHub | A push webhook: tell the repository's devices. |
//! | `POST`, `DELETE /devices` | an iPhone | Register, or forget, its push token. |
//! | `GET /events?repository=o/n` | a Mac | A WebSocket, told of each push. |
//!
//! Devices prove they may hear about a repository with their GitHub
//! token, which is checked with GitHub and never stored. The hub is keyed
//! by GitHub's **id** for the repository, so a rename or a transfer
//! changes nothing.
//!
//! Everything here is a pure function from what arrived to what to do —
//! a [`Reply`], a [`Request`] to send, a decision — so the whole protocol
//! is tested natively, and a host (the Cloudflare Worker in
//! `prism-relay-worker`, or any server) only moves bytes: it routes with
//! [`route`], does what the functions say, and keeps two things per
//! repository — the registered [`Device`]s and the open sockets.

use crate::apns::{self, Delivery, Device, Environment};
use prism_github::http::{hex, Request, Response};
use prism_github::{api, webhook};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// An answer to send back: a status and a line of text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reply {
    pub status: u16,
    pub body: String,
}

impl Reply {
    pub fn new(status: u16, body: impl Into<String>) -> Reply {
        Reply { status, body: body.into() }
    }

    /// 204: done, with nothing to say.
    pub fn done() -> Reply {
        Reply::new(204, "")
    }
}

/// Where a request goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    /// GitHub's webhook.
    Webhook,
    /// A device registering its push token.
    Register,
    /// A device taking its push token back.
    Unregister,
    /// A device listening on a WebSocket.
    Events,
    /// A device asking for a token to dictate with: see [`crate::scribe`].
    ScribeToken,
    /// A hello, for whoever checks the relay is up.
    Root,
    NotFound,
}

pub fn route(method: &str, path: &str) -> Route {
    match (method, path) {
        ("POST", "/github") => Route::Webhook,
        ("POST", "/devices") => Route::Register,
        ("DELETE", "/devices") => Route::Unregister,
        ("GET", "/events") => Route::Events,
        ("POST", "/scribe-token") => Route::ScribeToken,
        ("GET", "/") => Route::Root,
        _ => Route::NotFound,
    }
}

/// What to do about a webhook.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WebhookAction {
    /// A push to a repository's default branch: tell its hub.
    Notify { repository_id: u64, after: String },
    /// Nothing to do; answer with this.
    Answer(Reply),
}

/// Reads GitHub's webhook: is it GitHub's, is it a push, is the push to
/// the branch devices keep.
pub fn webhook(secret: &str, event_header: Option<&str>, signature_header: Option<&str>, body: &[u8]) -> WebhookAction {
    if !webhook::verify_signature(secret, body, signature_header) {
        return WebhookAction::Answer(Reply::new(401, "Bad signature\n"));
    }
    match webhook::parse_event(event_header, body) {
        Ok(webhook::Event::Push(push)) if push.is_to_default_branch() => WebhookAction::Notify { repository_id: push.repository.id, after: push.after },
        Ok(webhook::Event::Push(_)) => WebhookAction::Answer(Reply::new(202, "Not the default branch\n")),
        Ok(webhook::Event::Ping) => WebhookAction::Answer(Reply::new(200, "pong\n")),
        Ok(webhook::Event::Other(name)) => WebhookAction::Answer(Reply::new(202, format!("Ignored {name}\n"))),
        Err(_) => WebhookAction::Answer(Reply::new(400, "Bad event\n")),
    }
}

/// The GitHub token a device sent, from its `Authorization` header.
pub fn bearer(authorization_header: Option<&str>) -> Result<&str, Reply> {
    authorization_header
        .and_then(|header| header.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|token| !token.is_empty())
        .ok_or_else(|| Reply::new(401, "Sign in to GitHub first\n"))
}

/// What a device sends to `/devices`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Registration {
    /// `owner/name`.
    pub repository: String,
    /// The device's push token, hex.
    pub token: String,
    #[serde(default)]
    pub environment: Environment,
    /// The app's bundle identifier. Not needed to unregister.
    #[serde(default)]
    pub topic: String,
}

impl Registration {
    pub fn device(&self) -> Device {
        Device { environment: self.environment, topic: self.topic.clone() }
    }
}

/// Reads and checks a `/devices` body. `topics` are the apps the relay
/// pushes for; an app not among them may not register.
pub fn registration(body: &[u8], topics: &[String], unregistering: bool) -> Result<Registration, Reply> {
    let registration: Registration = serde_json::from_slice(body).map_err(|_| Reply::new(400, "Bad device\n"))?;
    if !apns::is_device_token(&registration.token) {
        return Err(Reply::new(400, "Bad device\n"));
    }
    if !api::is_full_name(&registration.repository) {
        return Err(Reply::new(400, "Bad repository\n"));
    }
    if !unregistering && !topics.contains(&registration.topic) {
        return Err(Reply::new(400, "Unknown app\n"));
    }
    Ok(registration)
}

/// The repository a `/events` request names, from its query string.
pub fn events_repository(query: &str) -> Result<String, Reply> {
    query
        .split('&')
        .find_map(|pair| pair.strip_prefix("repository="))
        .map(|name| name.replace("%2F", "/").replace("%2f", "/"))
        .filter(|name| api::is_full_name(name))
        .ok_or_else(|| Reply::new(400, "Bad repository\n"))
}

/// Asks GitHub whether a token may read a repository — the answer also
/// carries the repository's id, which keys its hub. `full_name` must have
/// passed [`registration`] or [`events_repository`].
pub fn access_request(token: &str, full_name: &str) -> Request {
    api::repo_request(token, full_name)
}

/// The repository's id, or the reply that turns the device away.
pub fn access(response: &Response) -> Result<u64, Reply> {
    api::parse_repo(response).map(|repo| repo.id).map_err(|_| Reply::new(403, "No access to that repository\n"))
}

/// A key to remember an access check under for a few minutes, so a
/// reconnecting device does not cost a call to GitHub each time. Made
/// from a hash of the token: the token itself is never kept.
pub fn access_cache_key(token: &str, full_name: &str) -> String {
    format!("{}/{full_name}", hex(&Sha256::digest(token.as_bytes())))
}

/// How long an access check may be remembered.
pub const ACCESS_CACHE_SECONDS: u64 = 600;

/// What a listening device is sent, as JSON text.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Message {
    /// The repository was pushed to; `after` is the commit it is at.
    Push { after: String },
}

impl Message {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    pub fn from_json(text: &str) -> Option<Message> {
        serde_json::from_str(text).ok()
    }
}

/// What a listening device sends to keep its socket open, and the answer.
pub const PING: &str = "ping";
pub const PONG: &str = "pong";

/// What a hub did about a push: the webhook's answer, as JSON.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Told {
    /// Sockets told.
    pub listening: usize,
    /// Silent pushes APNs took.
    pub pushed: usize,
    /// Devices whose tokens APNs says are dead, now forgotten.
    pub forgotten: usize,
}

impl Told {
    /// Folds one device's delivery in. Says whether to forget the device.
    pub fn record(&mut self, delivery: &Delivery) -> bool {
        match delivery {
            Delivery::Delivered => self.pushed += 1,
            Delivery::Gone => self.forgotten += 1,
            Delivery::Failed(_) => {}
        }
        *delivery == Delivery::Gone
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PUSH: &[u8] = br#"{"ref":"refs/heads/main","after":"0123abcd","repository":{"id":42,"full_name":"ada/notes","default_branch":"main"}}"#;

    fn topics() -> Vec<String> {
        vec!["org.mutable.prism".into(), "org.mutable.weft".into()]
    }

    #[test]
    fn requests_are_routed() {
        assert_eq!(route("POST", "/github"), Route::Webhook);
        assert_eq!(route("POST", "/devices"), Route::Register);
        assert_eq!(route("POST", "/scribe-token"), Route::ScribeToken);
        assert_eq!(route("DELETE", "/devices"), Route::Unregister);
        assert_eq!(route("GET", "/events"), Route::Events);
        assert_eq!(route("GET", "/"), Route::Root);
        for (method, path) in [("GET", "/github"), ("PUT", "/devices"), ("POST", "/events"), ("GET", "/elsewhere")] {
            assert_eq!(route(method, path), Route::NotFound);
        }
    }

    #[test]
    fn a_signed_push_to_the_default_branch_notifies() {
        let signature = prism_github::webhook::sign("s3cret", PUSH);
        assert_eq!(webhook("s3cret", Some("push"), Some(&signature), PUSH), WebhookAction::Notify { repository_id: 42, after: "0123abcd".into() });
    }

    #[test]
    fn anything_else_is_answered_and_nothing_done() {
        let sign = |body: &[u8]| prism_github::webhook::sign("s3cret", body);
        let status = |action: WebhookAction| match action {
            WebhookAction::Answer(reply) => reply.status,
            WebhookAction::Notify { .. } => panic!("notified"),
        };
        // Unsigned, or signed with another secret: not GitHub.
        assert_eq!(status(webhook("s3cret", Some("push"), None, PUSH)), 401);
        assert_eq!(status(webhook("s3cret", Some("push"), Some(&prism_github::webhook::sign("other", PUSH)), PUSH)), 401);
        assert_eq!(status(webhook("", Some("push"), Some(&prism_github::webhook::sign("", PUSH)), PUSH)), 401);
        let branch = String::from_utf8_lossy(PUSH).replace("refs/heads/main", "refs/heads/feature");
        assert_eq!(status(webhook("s3cret", Some("push"), Some(&sign(branch.as_bytes())), branch.as_bytes())), 202);
        assert_eq!(status(webhook("s3cret", Some("ping"), Some(&sign(b"{}")), b"{}")), 200);
        assert_eq!(status(webhook("s3cret", Some("issues"), Some(&sign(b"{}")), b"{}")), 202);
        assert_eq!(status(webhook("s3cret", Some("push"), Some(&sign(b"{}")), b"{}")), 400);
    }

    #[test]
    fn registrations_are_checked() {
        let token = "ab".repeat(32);
        let body = |repository: &str, token: &str, topic: &str| {
            format!(r#"{{"repository":"{repository}","token":"{token}","environment":"sandbox","topic":"{topic}"}}"#)
        };
        let ok = registration(body("ada/notes", &token, "org.mutable.prism").as_bytes(), &topics(), false).unwrap();
        assert_eq!(ok.device(), Device { environment: Environment::Sandbox, topic: "org.mutable.prism".into() });
        let reject = |body: String, unregistering| registration(body.as_bytes(), &topics(), unregistering).unwrap_err().body;
        assert_eq!(reject(body("ada/notes", &token, "com.other.app"), false), "Unknown app\n");
        assert_eq!(reject(body("ada/notes", "nothex", "org.mutable.prism"), false), "Bad device\n");
        assert_eq!(reject(body("ada/../x", &token, "org.mutable.prism"), false), "Bad repository\n");
        assert_eq!(reject("not json".into(), false), "Bad device\n");
        // Unregistering needs no topic, and the environment defaults.
        let gone = registration(format!(r#"{{"repository":"ada/notes","token":"{token}"}}"#).as_bytes(), &topics(), true).unwrap();
        assert_eq!(gone.environment, Environment::Production);
    }

    #[test]
    fn devices_prove_access_with_a_github_token() {
        assert_eq!(bearer(Some("Bearer ghu_abc")).unwrap(), "ghu_abc");
        assert_eq!(bearer(None).unwrap_err().status, 401);
        assert_eq!(bearer(Some("Basic abc")).unwrap_err().status, 401);
        assert_eq!(bearer(Some("Bearer ")).unwrap_err().status, 401);

        assert_eq!(events_repository("repository=ada/notes").unwrap(), "ada/notes");
        assert_eq!(events_repository("x=1&repository=ada%2Fnotes").unwrap(), "ada/notes");
        assert_eq!(events_repository("repository=ada").unwrap_err().status, 400);
        assert_eq!(events_repository("").unwrap_err().status, 400);

        let request = access_request("ghu_abc", "ada/notes");
        assert_eq!((request.url.as_str(), request.header_value("Authorization")), ("https://api.github.com/repos/ada/notes", Some("Bearer ghu_abc")));
        assert_eq!(access(&Response::new(200, r#"{"id":42,"full_name":"ada/notes"}"#)).unwrap(), 42);
        assert_eq!(access(&Response::new(404, "{}")).unwrap_err().status, 403);
        // The cache key holds no token.
        let key = access_cache_key("ghu_abc", "ada/notes");
        assert!(key.ends_with("/ada/notes") && !key.contains("ghu_abc") && key.len() == 64 + 10);
        assert_ne!(key, access_cache_key("ghu_abd", "ada/notes"));
    }

    #[test]
    fn messages_and_tallies() {
        let message = Message::Push { after: "abc".into() };
        assert_eq!(message.to_json(), r#"{"type":"push","after":"abc"}"#);
        assert_eq!(Message::from_json(r#"{"type":"push","after":"abc","more":1}"#), Some(message));
        assert_eq!(Message::from_json("pong"), None);
        let mut told = Told { listening: 2, ..Told::default() };
        assert!(!told.record(&Delivery::Delivered));
        assert!(told.record(&Delivery::Gone));
        assert!(!told.record(&Delivery::Failed("503".into())));
        assert_eq!(serde_json::to_string(&told).unwrap(), r#"{"listening":2,"pushed":1,"forgotten":1}"#);
    }
}
