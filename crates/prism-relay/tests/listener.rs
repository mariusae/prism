//! The listener against a relay's worth of WebSocket server, on localhost.

// tungstenite's handshake callback fixes the error type.
#![allow(clippy::result_large_err)]

use prism_relay::relay::{Message, PING, PONG};
use prism_relay::{Listener, ListenerConfig, ListenerEvent};
use std::net::TcpListener;
use std::sync::mpsc;
use std::time::Duration;
use tungstenite::handshake::server::{ErrorResponse, Request, Response};

/// What the server saw of a connection as it was opened.
#[derive(Debug, PartialEq)]
struct Opened {
    path: String,
    authorization: Option<String>,
}

fn config(port: u16) -> ListenerConfig {
    ListenerConfig {
        ping_every: Duration::from_millis(50),
        silence_limit: Duration::from_secs(5),
        min_backoff: Duration::from_millis(20),
        max_backoff: Duration::from_millis(80),
        ..ListenerConfig::new(format!("ws://127.0.0.1:{port}"), "ada/notes")
    }
}

fn next(events: &mpsc::Receiver<ListenerEvent>) -> ListenerEvent {
    events.recv_timeout(Duration::from_secs(10)).expect("an event from the listener")
}

#[test]
fn it_connects_hears_pushes_keeps_alive_and_comes_back() {
    let server = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = server.local_addr().unwrap().port();
    let (opened_tx, opened_rx) = mpsc::channel();
    let (pinged_tx, pinged_rx) = mpsc::channel();

    let serving = std::thread::spawn(move || {
        // Two connections: the first is dropped after a push, the second
        // stays until the listener leaves.
        for round in 0..2 {
            let (stream, _) = server.accept().unwrap();
            let opened_tx = opened_tx.clone();
            let mut socket = tungstenite::accept_hdr(stream, move |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
                let authorization = request.headers().get("Authorization").map(|v| v.to_str().unwrap().to_owned());
                opened_tx.send(Opened { path: request.uri().to_string(), authorization }).unwrap();
                Ok(response)
            })
            .unwrap();
            socket.send(tungstenite::Message::text(Message::Push { after: format!("commit{round}") }.to_json())).unwrap();
            // Things a listener must shrug off.
            socket.send(tungstenite::Message::text("not json")).unwrap();
            loop {
                match socket.read() {
                    Ok(message) if message.is_text() && message.to_text().unwrap() == PING => {
                        socket.send(tungstenite::Message::text(PONG)).unwrap();
                        let _ = pinged_tx.send(round);
                        if round == 0 {
                            break; // drop the first connection mid-flight
                        }
                    }
                    Ok(_) => {}
                    Err(_) => break, // the listener left
                }
            }
        }
    });

    let (events_tx, events) = mpsc::channel();
    let listener = Listener::spawn(
        config(port),
        || Ok("ghu_token".to_owned()),
        move |event| {
            let _ = events_tx.send(event);
        },
    );

    assert_eq!(next(&events), ListenerEvent::Connected);
    assert_eq!(opened_rx.recv().unwrap(), Opened { path: "/events?repository=ada/notes".into(), authorization: Some("Bearer ghu_token".into()) });
    assert_eq!(next(&events), ListenerEvent::Push { after: "commit0".into() });
    assert_eq!(pinged_rx.recv_timeout(Duration::from_secs(10)).unwrap(), 0, "a keep-alive was sent");

    // The server dropped it: the listener says so, and comes back.
    let ListenerEvent::Disconnected { retry_in, .. } = next(&events) else { panic!("expected a disconnect") };
    assert_eq!(retry_in, Duration::from_millis(20));
    assert_eq!(next(&events), ListenerEvent::Connected);
    assert_eq!(next(&events), ListenerEvent::Push { after: "commit1".into() });

    listener.stop();
    serving.join().unwrap();
}

#[test]
fn it_backs_off_while_the_relay_is_away_and_stops_when_told() {
    // A port nothing listens on.
    let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let (events_tx, events) = mpsc::channel();
    let listener = Listener::spawn(
        config(port),
        || Ok("t".to_owned()),
        move |event| {
            let _ = events_tx.send(event);
        },
    );
    let mut waits = Vec::new();
    for _ in 0..4 {
        let ListenerEvent::Disconnected { retry_in, .. } = next(&events) else { panic!("expected a disconnect") };
        waits.push(retry_in.as_millis());
    }
    assert_eq!(waits, [20, 40, 80, 80]);
    let started = std::time::Instant::now();
    listener.stop();
    assert!(started.elapsed() < Duration::from_secs(2), "stopping does not wait out a backoff");
}

#[test]
fn without_a_token_it_never_dials() {
    let server = TcpListener::bind("127.0.0.1:0").unwrap();
    server.set_nonblocking(true).unwrap();
    let port = server.local_addr().unwrap().port();
    let (events_tx, events) = mpsc::channel();
    let listener = Listener::spawn(
        config(port),
        || Err("signed out".to_owned()),
        move |event| {
            let _ = events_tx.send(event);
        },
    );
    let ListenerEvent::Disconnected { reason, .. } = next(&events) else { panic!("expected a disconnect") };
    assert_eq!(reason, "no GitHub token: signed out");
    assert!(server.accept().is_err(), "nothing connected");
    drop(listener); // dropping stops it, too
}
