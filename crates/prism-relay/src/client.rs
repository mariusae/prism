//! The device's side of the relay.
//!
//! A device that can hold a socket open — a Mac — runs a [`Listener`]: a
//! WebSocket to the relay, kept alive, and opened again when it drops —
//! sooner after a moment's trouble, later after a long one. A device that
//! cannot — an iPhone in the background — registers its push token
//! ([`register_request`]) and is woken by a silent push instead.

use crate::relay::{Message, Registration, PING};
use prism_github::http::Request;
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tungstenite::client::IntoClientRequest;
use tungstenite::stream::MaybeTlsStream;

/// Registers a device's push token with a relay, for a repository.
pub fn register_request(relay: &str, github_token: &str, registration: &Registration) -> Request {
    Request::post(format!("{}/devices", base(relay))).bearer(github_token).json(registration)
}

/// Asks a relay for a token to dictate with: one transcription's worth,
/// from ElevenLabs, whose key the relay keeps. The answer is a
/// [`crate::scribe::Token`], as JSON.
pub fn scribe_token_request(relay: &str, github_token: &str) -> Request {
    Request::post(format!("{}/scribe-token", base(relay))).bearer(github_token)
}

/// Takes a device's push token back.
pub fn unregister_request(relay: &str, github_token: &str, registration: &Registration) -> Request {
    Request::new("DELETE", format!("{}/devices", base(relay))).bearer(github_token).json(registration)
}

/// `relay.example` → `https://relay.example`; an address with a scheme is
/// left as it is.
fn base(relay: &str) -> String {
    let relay = relay.trim_end_matches('/');
    if relay.contains("://") {
        relay.to_owned()
    } else {
        format!("https://{relay}")
    }
}

/// What a [`Listener`] has to tell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ListenerEvent {
    /// The socket is open. Pushes made while it was not were missed: a
    /// full sync now catches up.
    Connected,
    /// The repository was pushed to: sync.
    Push { after: String },
    /// The socket dropped, or the relay did not let it in; it is tried
    /// again after `retry_in`.
    Disconnected { reason: String, retry_in: Duration },
}

/// How a [`Listener`] is set up.
#[derive(Debug, Clone)]
pub struct ListenerConfig {
    /// The relay: a host (`relay.example.workers.dev`, reached over TLS)
    /// or a whole `ws://` or `wss://` address.
    pub relay: String,
    /// The repository to hear about: `owner/name`.
    pub repository: String,
    /// How often to send a keep-alive.
    pub ping_every: Duration,
    /// A socket that has said nothing for this long — not even an answer
    /// to a keep-alive — is taken for dead.
    pub silence_limit: Duration,
    /// The first wait before connecting again; each later one is twice
    /// the last, up to `max_backoff`. A connection that lasted puts the
    /// wait back.
    pub min_backoff: Duration,
    pub max_backoff: Duration,
}

impl ListenerConfig {
    pub fn new(relay: impl Into<String>, repository: impl Into<String>) -> ListenerConfig {
        ListenerConfig {
            relay: relay.into(),
            repository: repository.into(),
            ping_every: Duration::from_secs(30),
            silence_limit: Duration::from_secs(75),
            min_backoff: Duration::from_secs(1),
            max_backoff: Duration::from_secs(120),
        }
    }

    fn url(&self) -> String {
        let relay = self.relay.trim_end_matches('/');
        let base = if relay.contains("://") { relay.to_owned() } else { format!("wss://{relay}") };
        format!("{base}/events?repository={}", self.repository)
    }
}

/// A listener running on a thread of its own. Dropping it stops it.
pub struct Listener {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Listener {
    /// Starts listening. `token` gives a GitHub token good for a while
    /// yet, asked each time the socket is opened; `on_event` is told what
    /// happens, on the listener's thread.
    pub fn spawn(
        config: ListenerConfig,
        token: impl Fn() -> Result<String, String> + Send + 'static,
        on_event: impl Fn(ListenerEvent) + Send + 'static,
    ) -> Listener {
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let thread = std::thread::Builder::new().name("prism-relay-listener".into()).spawn(move || run(&config, &token, &on_event, &stopped)).ok();
        Listener { stop, thread }
    }

    /// Stops listening, and waits for the thread to end.
    pub fn stop(mut self) {
        self.shut_down();
    }

    fn shut_down(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.shut_down();
    }
}

/// How often the thread looks up from the socket: to send a keep-alive,
/// and to see whether it was asked to stop.
const TICK: Duration = Duration::from_millis(200);

fn run(config: &ListenerConfig, token: &dyn Fn() -> Result<String, String>, on_event: &dyn Fn(ListenerEvent), stop: &AtomicBool) {
    let mut backoff = config.min_backoff;
    while !stop.load(Ordering::SeqCst) {
        let opened = Instant::now();
        let reason = match session(config, token, on_event, stop) {
            Ok(()) => return, // asked to stop
            Err(reason) => reason,
        };
        // A connection that held for a while was a good one: start over.
        if opened.elapsed() > config.max_backoff {
            backoff = config.min_backoff;
        }
        on_event(ListenerEvent::Disconnected { reason, retry_in: backoff });
        let wake = Instant::now() + backoff;
        while Instant::now() < wake {
            if stop.load(Ordering::SeqCst) {
                return;
            }
            std::thread::sleep(TICK.min(wake - Instant::now()));
        }
        backoff = (backoff * 2).min(config.max_backoff);
    }
}

/// One connection, from opening to dropping. `Ok` when asked to stop.
fn session(config: &ListenerConfig, token: &dyn Fn() -> Result<String, String>, on_event: &dyn Fn(ListenerEvent), stop: &AtomicBool) -> Result<(), String> {
    let token = token().map_err(|why| format!("no GitHub token: {why}"))?;
    let mut request = config.url().into_client_request().map_err(|e| e.to_string())?;
    let bearer = format!("Bearer {token}").parse().map_err(|_| "the token cannot go in a header".to_owned())?;
    request.headers_mut().insert("Authorization", bearer);
    let (mut socket, _) = tungstenite::connect(request).map_err(|e| match e {
        tungstenite::Error::Http(response) => format!("the relay answered {}", response.status()),
        other => other.to_string(),
    })?;
    // Reads give up after a tick, so the loop can look up.
    let timeout = |stream: &TcpStream| stream.set_read_timeout(Some(TICK));
    match socket.get_ref() {
        MaybeTlsStream::Plain(stream) => timeout(stream),
        MaybeTlsStream::Rustls(stream) => timeout(stream.get_ref()),
        _ => Ok(()),
    }
    .map_err(|e| e.to_string())?;

    on_event(ListenerEvent::Connected);
    let (mut last_ping, mut last_heard) = (Instant::now(), Instant::now());
    loop {
        if stop.load(Ordering::SeqCst) {
            let _ = socket.close(None);
            return Ok(());
        }
        if last_ping.elapsed() >= config.ping_every {
            socket.send(tungstenite::Message::text(PING)).map_err(|e| e.to_string())?;
            last_ping = Instant::now();
        }
        if last_heard.elapsed() >= config.silence_limit {
            return Err("the relay went quiet".into());
        }
        match socket.read() {
            Ok(tungstenite::Message::Text(text)) => {
                last_heard = Instant::now();
                if let Some(Message::Push { after }) = Message::from_json(text.as_ref()) {
                    on_event(ListenerEvent::Push { after });
                }
            }
            Ok(tungstenite::Message::Close(_)) => return Err("the relay closed the socket".into()),
            Ok(_) => last_heard = Instant::now(),
            Err(tungstenite::Error::Io(e)) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {}
            Err(e) => return Err(e.to_string()),
        }
    }
}
