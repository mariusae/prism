//! The sync relay.
//!
//! Git has no way to say "something was pushed". Without one, a device
//! learns of another's writing only when it next syncs. The relay closes
//! the gap: GitHub tells it of each push (a webhook), and it tells every
//! device that keeps that repository — a Mac over a WebSocket it holds
//! open, an iPhone by a silent push — so each syncs within seconds.
//!
//! ```text
//!  device A ──git push──▶ GitHub ──webhook──▶ relay ──WebSocket──▶ Mac     ──▶ sync
//!                                               └────APNs───────▶ iPhone  ──▶ sync
//! ```
//!
//! The relay carries no notes and no tokens: a message says only "this
//! repository is now at this commit". Devices fetch from GitHub as ever.
//!
//! # The pieces
//!
//! - [`relay`] — the relay itself, as pure functions: what to do about a
//!   webhook, a registration, a listener. No I/O, so it is tested here
//!   and hosted anywhere; `prism-relay-worker` hosts it on Cloudflare.
//! - [`apns`] — signing and sending silent pushes.
//! - [`client`] (feature `client`, on by default) — the device's side: a
//!   [`Listener`] that holds the socket and reconnects, and the requests
//!   that register a phone.
//!
//! # A device, listening
//!
//! ```no_run
//! use prism_relay::{Listener, ListenerConfig, ListenerEvent};
//!
//! let config = ListenerConfig::new("relay.example.workers.dev", "ada/notes");
//! let listener = Listener::spawn(config, || Ok("ghu_token".into()), |event| match event {
//!     // Opened (again): anything may have been missed meanwhile.
//!     ListenerEvent::Connected | ListenerEvent::Push { .. } => { /* ask for a full sync */ }
//!     ListenerEvent::Disconnected { reason, retry_in } => eprintln!("relay: {reason}; again in {retry_in:?}"),
//! });
//! // … later
//! listener.stop();
//! ```

pub mod apns;
pub mod relay;

#[cfg(feature = "client")]
pub mod client;

pub use apns::{Device, Environment};
pub use relay::{Message, Registration, Reply, Route, Told, WebhookAction};

#[cfg(feature = "client")]
pub use client::{Listener, ListenerConfig, ListenerEvent};
