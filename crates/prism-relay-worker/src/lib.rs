//! The sync relay, on Cloudflare Workers.
//!
//! This crate decides nothing: every decision is `prism-relay`'s, made by
//! pure functions tested natively. What is here is the plumbing between
//! those functions and the platform —
//!
//! - the Worker's `fetch` routes a request and answers it;
//! - one **Durable Object per repository** ([`RepoHub`]) keeps what the
//!   relay must remember: the iPhones' push tokens, in its storage, and
//!   the Macs' open WebSockets, which Cloudflare holds while the object
//!   sleeps;
//! - outbound calls — to GitHub, to check a device's access; to APNs, to
//!   wake a phone — go out through the platform's `fetch`.
//!
//! See the README beside this crate for setting it up and deploying it.

use prism_github::http as wire;
use prism_relay::apns::{self, Device};
use prism_relay::relay::{self, Message, Reply, Route, Told, WebhookAction, PING, PONG};
use std::cell::RefCell;
use std::collections::BTreeMap;
use worker::wasm_bindgen::JsValue;
use worker::*;

/// The binding the hubs are reached through (see `wrangler.toml`).
const HUBS: &str = "HUBS";
/// The storage key a hub keeps its devices under: push token → device.
const DEVICES: &str = "devices";

type Devices = BTreeMap<String, Device>;

#[event(fetch)]
async fn fetch(mut request: Request, env: Env, _ctx: Context) -> Result<Response> {
    let method = request.method().to_string();
    let answer = match relay::route(&method, &request.path()) {
        Route::Webhook => webhook(&mut request, &env).await,
        Route::Register => devices(&mut request, &env, false).await,
        Route::Unregister => devices(&mut request, &env, true).await,
        Route::Events => events(request, &env).await,
        Route::Root => Ok(Err(Reply::new(200, "prism-relay\n"))),
        Route::NotFound => Ok(Err(Reply::new(404, "Not found\n"))),
    };
    match answer {
        Ok(Ok(response)) => Ok(response),
        // Answered in a line: turned away with the reason, or simply done.
        Ok(Err(line)) => reply(line),
        Err(error) => {
            console_error!("{error}");
            reply(Reply::new(500, "Something went wrong\n"))
        }
    }
}

/// A handler's answer: a response of the platform's making, or a
/// [`Reply`] — a status and a line — to send; `Err` is the platform failing.
type Answer = Result<std::result::Result<Response, Reply>>;

fn reply(reply: Reply) -> Result<Response> {
    Ok(Response::builder().with_status(reply.status).fixed(reply.body.into_bytes()))
}

fn header(request: &Request, name: &str) -> Option<String> {
    request.headers().get(name).ok().flatten()
}

/// A repository's hub, by GitHub's id for it.
fn hub(env: &Env, repository_id: u64) -> Result<Stub> {
    env.durable_object(HUBS)?.id_from_name(&repository_id.to_string())?.get_stub()
}

/// Calls a hub with a JSON body. The address is only a name: the request
/// never leaves Cloudflare.
async fn tell_hub(env: &Env, repository_id: u64, action: &str, body: &serde_json::Value) -> Result<Response> {
    let mut init = RequestInit::new();
    init.with_method(Method::Post).with_body(Some(JsValue::from_str(&body.to_string())));
    hub(env, repository_id)?.fetch_with_request(Request::new_with_init(&format!("https://hub/{action}"), &init)?).await
}

// --- GitHub's webhook --------------------------------------------------------

async fn webhook(request: &mut Request, env: &Env) -> Answer {
    let body = request.bytes().await?;
    let secret = env.secret("GITHUB_WEBHOOK_SECRET").map(|s| s.to_string()).unwrap_or_default();
    let action = relay::webhook(&secret, header(request, "X-GitHub-Event").as_deref(), header(request, "X-Hub-Signature-256").as_deref(), &body);
    match action {
        WebhookAction::Answer(answer) => Ok(Err(answer)),
        WebhookAction::Notify { repository_id, after } => Ok(Ok(tell_hub(env, repository_id, "pushed", &serde_json::json!({ "after": after })).await?)),
    }
}

// --- Devices -----------------------------------------------------------------

/// Sends one of `prism-github`'s or `prism-relay`'s requests.
async fn send(request: wire::Request) -> Result<wire::Response> {
    let headers = Headers::new();
    for (name, value) in &request.headers {
        headers.set(name, value)?;
    }
    let mut init = RequestInit::new();
    init.with_method(Method::from(request.method.to_owned())).with_headers(headers);
    if !request.body.is_empty() {
        init.with_body(Some(JsValue::from_str(&String::from_utf8_lossy(&request.body))));
    }
    let mut response = Fetch::Request(Request::new_with_init(&request.url, &init)?).send().await?;
    Ok(wire::Response { status: response.status_code(), headers: Vec::new(), body: response.bytes().await? })
}

/// The id of the repository a device's GitHub token can read: asked of
/// GitHub, the answer remembered a few minutes under a hash of the token.
async fn repository_id(token: &str, full_name: &str) -> Result<std::result::Result<u64, Reply>> {
    let cache = Cache::default();
    let key = format!("https://access.cache/{}", relay::access_cache_key(token, full_name));
    if let Some(mut cached) = cache.get(key.as_str(), false).await? {
        if let Ok(id) = cached.text().await?.parse() {
            return Ok(Ok(id));
        }
    }
    let id = match relay::access(&send(relay::access_request(token, full_name)).await?) {
        Ok(id) => id,
        Err(turned_away) => return Ok(Err(turned_away)),
    };
    let remembered = Response::builder().with_header("Cache-Control", &format!("max-age={}", relay::ACCESS_CACHE_SECONDS))?.fixed(id.to_string().into_bytes());
    cache.put(key.as_str(), remembered).await?;
    Ok(Ok(id))
}

/// A turned-away request, out of a handler.
macro_rules! check {
    ($result:expr) => {
        match $result {
            Ok(value) => value,
            Err(turned_away) => return Ok(Err(turned_away)),
        }
    };
}

async fn devices(request: &mut Request, env: &Env, unregistering: bool) -> Answer {
    let body = request.bytes().await?;
    let topics: Vec<String> = env.var("APNS_TOPICS").map(|v| v.to_string()).unwrap_or_default().split(',').map(|t| t.trim().to_owned()).collect();
    let registration = check!(relay::registration(&body, &topics, unregistering));
    let authorization = header(request, "Authorization");
    let token = check!(relay::bearer(authorization.as_deref()));
    let id = check!(repository_id(token, &registration.repository).await?);
    let (action, body) = if unregistering {
        ("forget", serde_json::json!({ "token": registration.token }))
    } else {
        ("remember", serde_json::json!({ "token": registration.token, "device": registration.device() }))
    };
    tell_hub(env, id, action, &body).await?;
    Ok(Err(Reply::done()))
}

/// A device listening: its WebSocket is handed to its repository's hub.
async fn events(request: Request, env: &Env) -> Answer {
    if !header(&request, "Upgrade").is_some_and(|upgrade| upgrade.eq_ignore_ascii_case("websocket")) {
        return Ok(Err(Reply::new(426, "Expected a WebSocket\n")));
    }
    let url = request.url()?;
    let repository = check!(relay::events_repository(url.query().unwrap_or("")));
    let authorization = header(&request, "Authorization");
    let token = check!(relay::bearer(authorization.as_deref()));
    let id = check!(repository_id(token, &repository).await?);
    Ok(Ok(hub(env, id)?.fetch_with_request(request).await?))
}

// --- The hub -----------------------------------------------------------------

/// One repository's devices: push tokens in storage, sockets held open.
#[durable_object]
pub struct RepoHub {
    state: State,
    env: Env,
    /// The APNs provider token, signed once and used for most of an hour.
    provider_token: RefCell<Option<(String, u64)>>,
}

impl DurableObject for RepoHub {
    fn new(state: State, env: Env) -> Self {
        // A listener's keep-alive is answered without waking the hub.
        if let Ok(pair) = worker_sys::WebSocketRequestResponsePair::new(PING, PONG) {
            state.set_websocket_auto_response(&pair);
        }
        RepoHub { state, env, provider_token: RefCell::new(None) }
    }

    async fn fetch(&self, mut request: Request) -> Result<Response> {
        if header(&request, "Upgrade").is_some() {
            let pair = WebSocketPair::new()?;
            self.state.accept_web_socket(&pair.server);
            return Response::from_websocket(pair.client);
        }
        let body: serde_json::Value = request.json().await?;
        let text = |key: &str| body[key].as_str().unwrap_or_default().to_owned();
        match request.path().as_str() {
            "/pushed" => Response::from_json(&self.pushed(&text("after")).await?),
            "/remember" => {
                let device: Device = serde_json::from_value(body["device"].clone()).map_err(|e| Error::RustError(e.to_string()))?;
                let mut devices = self.devices().await;
                devices.insert(text("token"), device);
                self.state.storage().put(DEVICES, &devices).await?;
                Response::empty()
            }
            "/forget" => {
                let mut devices = self.devices().await;
                devices.remove(&text("token"));
                self.state.storage().put(DEVICES, &devices).await?;
                Response::empty()
            }
            _ => Response::error("Not found", 404),
        }
    }

    async fn websocket_message(&self, _socket: WebSocket, _message: WebSocketIncomingMessage) -> Result<()> {
        Ok(())
    }

    async fn websocket_close(&self, socket: WebSocket, code: usize, _reason: String, _was_clean: bool) -> Result<()> {
        let _ = socket.close(u16::try_from(code).ok(), Some("closing"));
        Ok(())
    }

    async fn websocket_error(&self, _socket: WebSocket, _error: Error) -> Result<()> {
        Ok(())
    }
}

impl RepoHub {
    async fn devices(&self) -> Devices {
        self.state.storage().get(DEVICES).await.ok().flatten().unwrap_or_default()
    }

    /// The repository was pushed to: every socket told, every phone sent
    /// a silent push, and the tokens APNs says are dead let go.
    async fn pushed(&self, after: &str) -> Result<Told> {
        let message = Message::Push { after: after.to_owned() }.to_json();
        let sockets = self.state.get_websockets();
        for socket in &sockets {
            let _ = socket.send_with_str(&message);
        }
        let mut told = Told { listening: sockets.len(), ..Told::default() };
        let mut devices = self.devices().await;
        let now = Date::now().as_millis() / 1000;
        let Some(provider_token) = self.provider_token(now) else { return Ok(told) };
        let mut gone = Vec::new();
        for (token, device) in &devices {
            match send(apns::push_request(token, device, after, &provider_token, now)).await {
                Ok(response) => {
                    let delivery = apns::delivery(&response);
                    if let apns::Delivery::Failed(why) = &delivery {
                        console_warn!("APNs turned a push away: {why}");
                    }
                    if told.record(&delivery) {
                        gone.push(token.clone());
                    }
                }
                Err(error) => console_warn!("APNs could not be reached: {error}"),
            }
        }
        if !gone.is_empty() {
            devices.retain(|token, _| !gone.contains(token));
            self.state.storage().put(DEVICES, &devices).await?;
        }
        Ok(told)
    }

    /// A provider token good for a while yet; `None` when the relay has
    /// no APNs key, and so pushes to no phones.
    fn provider_token(&self, now: u64) -> Option<String> {
        if let Some((token, signed_at)) = self.provider_token.borrow().as_ref() {
            if now.saturating_sub(*signed_at) < apns::TOKEN_LIFETIME_SECONDS {
                return Some(token.clone());
            }
        }
        let secret = |name: &str| self.env.secret(name).ok().map(|s| s.to_string()).filter(|s| !s.is_empty());
        let key = apns::Key { pem: secret("APNS_KEY")?, key_id: secret("APNS_KEY_ID")?, team_id: secret("APNS_TEAM_ID")? };
        match apns::provider_token(&key, now) {
            Ok(token) => {
                *self.provider_token.borrow_mut() = Some((token.clone(), now));
                Some(token)
            }
            Err(why) => {
                console_error!("{why}");
                None
            }
        }
    }
}
