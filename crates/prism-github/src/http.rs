//! HTTP, as data.
//!
//! Everything in this crate that talks to GitHub is written as a pair:
//! a function that **builds a [`Request`]**, and one that **reads a
//! [`Response`]**. Nothing here opens a socket. Whoever uses the crate
//! sends the request however its platform does — `fetch` in a Worker,
//! `URLSession` behind an FFI, or the blocking [`HttpClient`] below — and
//! the logic is the same, and testable, everywhere.

/// An HTTP request, ready to send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub method: &'static str,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn new(method: &'static str, url: impl Into<String>) -> Request {
        Request { method, url: url.into(), headers: Vec::new(), body: Vec::new() }
    }

    pub fn get(url: impl Into<String>) -> Request {
        Request::new("GET", url)
    }

    pub fn post(url: impl Into<String>) -> Request {
        Request::new("POST", url)
    }

    pub fn header(mut self, name: &str, value: impl Into<String>) -> Request {
        self.headers.push((name.to_owned(), value.into()));
        self
    }

    pub fn bearer(self, token: &str) -> Request {
        self.header("Authorization", format!("Bearer {token}"))
    }

    pub fn json(mut self, body: &impl serde::Serialize) -> Request {
        self.body = serde_json::to_vec(body).unwrap_or_default();
        self.header("Content-Type", "application/json")
    }

    /// A body of `key=value&…`, percent-encoded.
    pub fn form(mut self, fields: &[(&str, &str)]) -> Request {
        self.body = fields.iter().map(|(k, v)| format!("{}={}", percent_encode(k), percent_encode(v))).collect::<Vec<_>>().join("&").into_bytes();
        self.header("Content-Type", "application/x-www-form-urlencoded")
    }

    /// The first header of a name, case aside.
    pub fn header_value(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
}

/// An HTTP response, as received.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn new(status: u16, body: impl Into<Vec<u8>>) -> Response {
        Response { status, headers: Vec::new(), body: body.into() }
    }

    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }

    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub fn json<T: serde::de::DeserializeOwned>(&self) -> Result<T, crate::Error> {
        serde_json::from_slice(&self.body).map_err(|e| crate::Error::Unexpected(format!("{e}: {}", self.text().chars().take(200).collect::<String>())))
    }
}

/// Sends a request and waits for its answer. The one thing this crate
/// asks of a platform, for the conveniences that do the sending
/// themselves ([`crate::Client`], [`crate::Session`]).
pub trait HttpClient: Send + Sync {
    /// The answer, whatever its status; `Err` only when there was none.
    fn send(&self, request: Request) -> Result<Response, String>;
}

impl<F: Fn(Request) -> Result<Response, String> + Send + Sync> HttpClient for F {
    fn send(&self, request: Request) -> Result<Response, String> {
        self(request)
    }
}

/// An [`HttpClient`] over `ureq`: blocking, with TLS, for native apps.
#[cfg(feature = "ureq")]
#[derive(Clone)]
pub struct UreqClient(ureq::Agent);

#[cfg(feature = "ureq")]
impl Default for UreqClient {
    fn default() -> Self {
        UreqClient(ureq::AgentBuilder::new().timeout(std::time::Duration::from_secs(30)).build())
    }
}

#[cfg(feature = "ureq")]
impl HttpClient for UreqClient {
    fn send(&self, request: Request) -> Result<Response, String> {
        let mut call = self.0.request(request.method, &request.url);
        for (name, value) in &request.headers {
            call = call.set(name, value);
        }
        let answer = match if request.body.is_empty() { call.call() } else { call.send_bytes(&request.body) } {
            Ok(answer) => answer,
            // A status that is not a success is still an answer.
            Err(ureq::Error::Status(_, answer)) => answer,
            Err(e) => return Err(e.to_string()),
        };
        let status = answer.status();
        let headers = answer.headers_names().into_iter().filter_map(|n| Some((n.clone(), answer.header(&n)?.to_owned()))).collect();
        let mut body = Vec::new();
        std::io::Read::read_to_end(&mut answer.into_reader(), &mut body).map_err(|e| e.to_string())?;
        Ok(Response { status, headers, body })
    }
}

/// Percent-encodes all but RFC 3986's unreserved characters.
pub fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// Bytes as lowercase hex.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Bytes as base64url, without padding: what JWTs and PKCE use.
pub fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = u32::from(chunk[0]) << 16 | u32::from(*chunk.get(1).unwrap_or(&0)) << 8 | u32::from(*chunk.get(2).unwrap_or(&0));
        for (index, shift) in [18, 12, 6, 0].into_iter().enumerate() {
            if index <= chunk.len() {
                out.push(ALPHABET[(n >> shift & 63) as usize] as char);
            }
        }
    }
    out
}

/// Two strings compared in time that does not depend on where they differ.
pub fn constant_time_eq(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0, |difference, (x, y)| difference | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codecs() {
        assert_eq!(hex(&[0, 15, 255]), "000fff");
        assert_eq!(base64url(b""), "");
        assert_eq!(base64url(b"f"), "Zg");
        assert_eq!(base64url(b"fo"), "Zm8");
        assert_eq!(base64url(b"foo"), "Zm9v");
        assert_eq!(base64url(&[0xfb, 0xff, 0xfe]), "-__-");
        assert_eq!(percent_encode("a b&c=d/é~"), "a%20b%26c%3Dd%2F%C3%A9~");
        assert!(constant_time_eq("abc", "abc"));
        assert!(!constant_time_eq("abc", "abd") && !constant_time_eq("abc", "ab"));
    }

    #[test]
    fn requests_are_built_up() {
        let request = Request::post("https://x.example/y").bearer("t0ken").form(&[("a", "1 2"), ("b", "&")]);
        assert_eq!(request.header_value("authorization"), Some("Bearer t0ken"));
        assert_eq!(request.body, b"a=1%202&b=%26");
        let request = Request::get("u").json(&serde_json::json!({"k": 1}));
        assert_eq!((request.body.as_slice(), request.header_value("Content-Type")), (&b"{\"k\":1}"[..], Some("application/json")));
        assert!(Response::new(204, "").is_success() && !Response::new(404, "").is_success());
        assert!(Response::new(200, "not json").json::<serde_json::Value>().is_err());
    }
}
