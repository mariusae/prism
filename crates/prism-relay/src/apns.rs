//! Apple's push service: waking an iPhone to sync.
//!
//! A device that cannot hold a socket open in the background is sent a
//! **silent push** — no alert, just a nudge that wakes the app for a few
//! seconds, in which it syncs. This module signs the token APNs takes in
//! place of a certificate, builds the push, and reads APNs' answer.

use prism_github::http::{base64url, Request, Response};
use serde::{Deserialize, Serialize};

/// The key APNs pushes are signed with, from Apple's developer site.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Key {
    /// The `.p8` file's contents, PEM and all.
    pub pem: String,
    pub key_id: String,
    pub team_id: String,
}

/// Which of Apple's services a device's token is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Environment {
    #[default]
    Production,
    /// An app signed for development.
    Sandbox,
}

/// A device to push to: beside its token, what APNs needs to reach it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Device {
    pub environment: Environment,
    /// The app's bundle identifier.
    pub topic: String,
}

/// How long a signed token is used for. Apple turns away one made more
/// often than every twenty minutes, and one older than an hour.
pub const TOKEN_LIFETIME_SECONDS: u64 = 40 * 60;

/// The token APNs takes in place of a certificate: a JWT signed with the
/// team's key, ES256. `now` is seconds since the Unix epoch.
pub fn provider_token(key: &Key, now: u64) -> Result<String, String> {
    use p256::ecdsa::{signature::Signer, Signature, SigningKey};
    use p256::pkcs8::DecodePrivateKey;
    let signing_key = SigningKey::from_pkcs8_pem(key.pem.trim()).map_err(|e| format!("the APNs key does not read: {e}"))?;
    let header = base64url(serde_json::json!({ "alg": "ES256", "kid": key.key_id }).to_string().as_bytes());
    let claims = base64url(serde_json::json!({ "iss": key.team_id, "iat": now }).to_string().as_bytes());
    let signed = format!("{header}.{claims}");
    // The signature is the raw r‖s a JWT wants, not DER.
    let signature: Signature = signing_key.sign(signed.as_bytes());
    Ok(format!("{signed}.{}", base64url(&signature.to_bytes())))
}

/// A silent push telling a device its repository moved to `after`.
pub fn push_request(device_token: &str, device: &Device, after: &str, provider_token: &str, now: u64) -> Request {
    let host = match device.environment {
        Environment::Production => "api.push.apple.com",
        Environment::Sandbox => "api.sandbox.push.apple.com",
    };
    Request::post(format!("https://{host}/3/device/{device_token}"))
        .header("authorization", format!("bearer {provider_token}"))
        .header("apns-topic", &device.topic)
        .header("apns-push-type", "background")
        // Background pushes must go at the lower priority.
        .header("apns-priority", "5")
        // Kept a few hours for a phone out of reach; pushes not yet
        // delivered fold into the latest.
        .header("apns-expiration", (now + 6 * 3600).to_string())
        .header("apns-collapse-id", "sync")
        .json(&serde_json::json!({ "aps": { "content-available": 1 }, "after": after }))
}

/// How APNs answered a push.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Delivery {
    Delivered,
    /// The token will never be good again: forget the device.
    Gone,
    /// Turned away for now, with APNs' reason.
    Failed(String),
}

pub fn delivery(response: &Response) -> Delivery {
    if response.is_success() {
        return Delivery::Delivered;
    }
    #[derive(Deserialize, Default)]
    struct Answer {
        #[serde(default)]
        reason: String,
    }
    let reason = serde_json::from_slice::<Answer>(&response.body).unwrap_or_default().reason;
    if response.status == 410 || matches!(reason.as_str(), "BadDeviceToken" | "Unregistered" | "DeviceTokenNotForTopic" | "ExpiredToken") {
        Delivery::Gone
    } else {
        Delivery::Failed(format!("{} {reason}", response.status))
    }
}

/// Whether text can be a device's push token: hex, of a sane length.
pub fn is_device_token(text: &str) -> bool {
    (32..=200).contains(&text.len()) && text.bytes().all(|b| b.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A P-256 key made for these tests, and used nowhere else.
    pub(crate) const TEST_KEY: &str = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgQoJzEyzQlnPo+v12\nJtNVPPKJriMCAZp0bGWMNtvUhcWhRANCAAQYNRcg6Cg+t/sY3vyIFGcR7eXtQJMS\nnN0Zj7h2eZYXeCK0vPs0hJ05St7p0E6rZciB4Ajq5fIYwGkjPjo5kn9v\n-----END PRIVATE KEY-----\n";

    fn unbase64url(text: &str) -> Vec<u8> {
        let value = |c: u8| b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".iter().position(|a| *a == c).unwrap() as u32;
        let mut out = Vec::new();
        for chunk in text.as_bytes().chunks(4) {
            let n = chunk.iter().fold(0, |n, c| n << 6 | value(*c)) << (6 * (4 - chunk.len()));
            out.extend_from_slice(&n.to_be_bytes()[1..chunk.len()]);
        }
        out
    }

    #[test]
    fn the_provider_token_is_a_jwt_the_key_verifies() {
        use p256::ecdsa::{signature::Verifier, Signature, SigningKey};
        use p256::pkcs8::DecodePrivateKey;
        let key = Key { pem: TEST_KEY.into(), key_id: "ABC123DEFG".into(), team_id: "TEAM123456".into() };
        let token = provider_token(&key, 1_700_000_000).unwrap();
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3);
        assert_eq!(String::from_utf8(unbase64url(parts[0])).unwrap(), r#"{"alg":"ES256","kid":"ABC123DEFG"}"#);
        assert_eq!(String::from_utf8(unbase64url(parts[1])).unwrap(), r#"{"iat":1700000000,"iss":"TEAM123456"}"#);
        let signature = Signature::from_slice(&unbase64url(parts[2])).unwrap();
        let verifying = *SigningKey::from_pkcs8_pem(TEST_KEY).unwrap().verifying_key();
        verifying.verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature).unwrap();
        assert!(provider_token(&Key { pem: "not a key".into(), ..key }, 0).is_err());
    }

    #[test]
    fn a_push_is_silent_low_priority_and_collapsing() {
        let device = Device { environment: Environment::Sandbox, topic: "org.mutable.prism".into() };
        let request = push_request("abcdef0123", &device, "c0ffee", "jwt", 1000);
        assert_eq!(request.url, "https://api.sandbox.push.apple.com/3/device/abcdef0123");
        assert_eq!(request.header_value("authorization"), Some("bearer jwt"));
        assert_eq!(request.header_value("apns-push-type"), Some("background"));
        assert_eq!(request.header_value("apns-priority"), Some("5"));
        assert_eq!(request.header_value("apns-expiration"), Some("22600"));
        assert_eq!(request.header_value("apns-topic"), Some("org.mutable.prism"));
        assert_eq!(String::from_utf8(request.body).unwrap(), r#"{"after":"c0ffee","aps":{"content-available":1}}"#);
        let production = Device { environment: Environment::Production, ..device };
        assert!(push_request("t", &production, "a", "j", 0).url.starts_with("https://api.push.apple.com/"));
    }

    #[test]
    fn answers_say_delivered_gone_or_failed() {
        assert_eq!(delivery(&Response::new(200, "")), Delivery::Delivered);
        assert_eq!(delivery(&Response::new(410, r#"{"reason":"Unregistered"}"#)), Delivery::Gone);
        assert_eq!(delivery(&Response::new(400, r#"{"reason":"BadDeviceToken"}"#)), Delivery::Gone);
        assert_eq!(delivery(&Response::new(429, r#"{"reason":"TooManyRequests"}"#)), Delivery::Failed("429 TooManyRequests".into()));
        assert_eq!(delivery(&Response::new(503, "")), Delivery::Failed("503 ".into()));
        assert!(is_device_token(&"a1".repeat(32)) && !is_device_token("short") && !is_device_token(&"zz".repeat(32)));
    }
}
