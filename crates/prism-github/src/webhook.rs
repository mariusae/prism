//! GitHub's webhooks: checking that one is GitHub's, and reading it.

use crate::http::{constant_time_eq, hex};
use crate::Error;
use hmac::{Hmac, Mac};
use serde::Deserialize;
use sha2::Sha256;

/// Whether a webhook's body is GitHub's: its `X-Hub-Signature-256` header
/// is `sha256=` and the body's HMAC under the webhook's secret. An empty
/// secret verifies nothing.
pub fn verify_signature(secret: &str, body: &[u8], signature_header: Option<&str>) -> bool {
    let Some(signature) = signature_header.and_then(|h| h.strip_prefix("sha256=")) else { return false };
    if secret.is_empty() {
        return false;
    }
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(secret.as_bytes()) else { return false };
    mac.update(body);
    constant_time_eq(&signature.to_ascii_lowercase(), &hex(&mac.finalize().into_bytes()))
}

/// The header a body would carry: for tests, and for whoever forwards.
pub fn sign(secret: &str, body: &[u8]) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC takes a key of any length");
    mac.update(body);
    format!("sha256={}", hex(&mac.finalize().into_bytes()))
}

/// The repository a webhook is about.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PushRepository {
    pub id: u64,
    pub full_name: String,
    pub default_branch: String,
}

/// A push to a repository.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Push {
    /// The reference pushed to: `refs/heads/main`.
    #[serde(rename = "ref")]
    pub reference: String,
    /// The commit the reference is at now.
    pub after: String,
    pub repository: PushRepository,
}

impl Push {
    /// Whether the push was to the branch devices keep.
    pub fn is_to_default_branch(&self) -> bool {
        self.reference.strip_prefix("refs/heads/") == Some(self.repository.default_branch.as_str())
    }
}

/// A webhook, read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Push(Push),
    /// GitHub's hello when a webhook is set up.
    Ping,
    /// An event this crate has nothing to say about, by its name.
    Other(String),
}

/// Reads a webhook from its `X-GitHub-Event` header and its body. Check
/// the body with [`verify_signature`] first.
pub fn parse_event(event_header: Option<&str>, body: &[u8]) -> Result<Event, Error> {
    match event_header {
        Some("push") => serde_json::from_slice(body).map(Event::Push).map_err(|e| Error::Unexpected(format!("a push event that does not read: {e}"))),
        Some("ping") => Ok(Event::Ping),
        Some(other) => Ok(Event::Other(other.to_owned())),
        None => Err(Error::Unexpected("no X-GitHub-Event header".into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PUSH: &str = r#"{"ref":"refs/heads/main","after":"0123abcd","repository":{"id":42,"full_name":"ada/notes","default_branch":"main","private":true},"pusher":{"name":"ada"}}"#;

    #[test]
    fn signatures_verify_only_with_the_secret() {
        // GitHub's documented example.
        let (secret, body) = ("It's a Secret to Everybody", b"Hello, World!");
        let header = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17";
        assert_eq!(sign(secret, body), header);
        assert!(verify_signature(secret, body, Some(header)));
        assert!(verify_signature(secret, body, Some(&header.to_uppercase().replace("SHA256=", "sha256="))));
        assert!(!verify_signature("another secret", body, Some(header)));
        assert!(!verify_signature(secret, b"Hello, World?", Some(header)));
        assert!(!verify_signature(secret, body, None));
        assert!(!verify_signature(secret, body, Some("sha1=757107ea")));
        assert!(!verify_signature("", body, Some(&sign("", body))));
    }

    #[test]
    fn events_are_read_by_their_header() {
        let Event::Push(push) = parse_event(Some("push"), PUSH.as_bytes()).unwrap() else { panic!("not a push") };
        assert_eq!((push.after.as_str(), push.repository.id, push.is_to_default_branch()), ("0123abcd", 42, true));
        let other_branch = PUSH.replace("refs/heads/main", "refs/heads/main-2");
        let Event::Push(push) = parse_event(Some("push"), other_branch.as_bytes()).unwrap() else { panic!() };
        assert!(!push.is_to_default_branch());
        assert_eq!(parse_event(Some("ping"), b"{}").unwrap(), Event::Ping);
        assert_eq!(parse_event(Some("issues"), b"{}").unwrap(), Event::Other("issues".into()));
        assert!(parse_event(Some("push"), b"{}").is_err());
        assert!(parse_event(None, b"{}").is_err());
    }
}
