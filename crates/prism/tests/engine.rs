//! The whole engine: two devices, each an `Engine`, sharing a remote.

// tungstenite's handshake callback fixes the error type.
#![allow(clippy::result_large_err)]

use prism::index::{Catalog, Links, Search, Tasks};
use prism::sync::{Auth, Config, Identity, Mode, Repository, Schedule};
use prism::{Engine, EngineConfig, Event, Status};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Receiver;
use std::time::Duration;

struct World {
    root: tempfile::TempDir,
}

impl World {
    fn new() -> World {
        let root = tempfile::tempdir().unwrap();
        Repository::init_bare(root.path().join("remote.git"), "main").unwrap();
        World { root }
    }

    fn remote(&self) -> PathBuf {
        self.root.path().join("remote.git")
    }

    fn config(name: &str, schedule: Schedule) -> EngineConfig {
        EngineConfig {
            sync: Config { device: Some(name.to_owned()), identity: Some(Identity::new(name, format!("{name}@example.com"))), ..Config::default() },
            schedule,
            auth: Auth::token("a-token"),
            index_path: None,
        }
    }

    /// The first device: a new repository, pointed at the remote.
    fn first(&self, name: &str, schedule: Schedule) -> Engine {
        let dir = self.root.path().join(name);
        Repository::init(&dir, "main").unwrap().set_remote("origin", self.remote().to_str().unwrap()).unwrap();
        Engine::start(&dir, World::config(name, schedule)).unwrap()
    }

    /// Another device: a clone.
    fn second(&self, name: &str) -> Engine {
        Engine::clone_from(self.remote().to_str().unwrap(), self.root.path().join(name), World::config(name, Schedule::default())).unwrap()
    }
}

/// Waits for an event that fits, passing over the others.
fn wait_for<T>(events: &Receiver<Event>, what: &str, mut fits: impl FnMut(&Event) -> Option<T>) -> T {
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    loop {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        match events.recv_timeout(left) {
            Ok(event) => {
                if let Some(found) = fits(&event) {
                    return found;
                }
            }
            Err(_) => panic!("never saw {what}"),
        }
    }
}

fn head_subject(dir: &Path) -> String {
    let repo = Repository::open(dir).unwrap();
    repo.recent_commits("HEAD", 1).unwrap()[0].message.lines().next().unwrap().to_owned()
}

#[test]
fn what_is_written_is_indexed_at_once_and_reaches_the_other_device() {
    let world = World::new();
    let a = world.first("a", Schedule::default());
    let events = a.subscribe();

    let atlas = a.create_note("Project Atlas").unwrap();
    let mut note = a.graph().note(&atlas).unwrap().unwrap();
    note.frontmatter_mut().set("aliases", vec!["Atlas".to_owned()]);
    note.body.blocks.push(prism::markup::Block::bullet("Kick-off with [[Ada Lovelace]] #planning"));
    note.body.blocks.push(prism::markup::Block::task("Book a room"));
    assert!(a.write(&atlas, &note.to_markdown()).unwrap());
    assert!(!a.write(&atlas, &note.to_markdown()).unwrap(), "nothing new to write");
    a.write("daily/2026-10-31.md", "- Met about [[atlas]]\n").unwrap();

    // Indexed without any sync: the indices follow the working tree.
    a.settle();
    wait_for(&events, "the new note indexed", |e| matches!(e, Event::IndexUpdated { changed, .. } if changed.contains(&atlas)).then_some(()));
    let db = a.index().unwrap();
    assert_eq!(Search::search(&db, "kick", 5).unwrap()[0].path, atlas);
    assert_eq!(Links::backlinks(&db, &Catalog::names(&db, &atlas).unwrap()).unwrap()[0].source, "daily/2026-10-31.md");
    assert_eq!(Tasks::open(&db).unwrap()[0].text, "Book a room");
    assert_eq!(a.status(), Status::Idle);

    let report = a.sync_blocking(Mode::Full).unwrap();
    assert_eq!(report.committed.as_deref(), Some("Add 2 notes"));
    assert!(report.pushed);
    assert!(matches!(a.status(), Status::Synced(_)));

    // The other device clones, and its own indices are built.
    let b = world.second("b");
    b.settle();
    let db_b = b.index().unwrap();
    assert_eq!(Catalog::count(&db_b).unwrap(), 2);
    assert_eq!(Catalog::resolve(&db_b, "ATLAS").unwrap().unwrap().path(), atlas);

    // It writes; the first device hears of it on its next sync.
    b.write("notes/ada-lovelace.md", "# Ada Lovelace\n\nSee [[Project Atlas]].\n").unwrap();
    let report = b.sync_blocking(Mode::Push).unwrap();
    assert_eq!(report.committed.as_deref(), Some("Add Ada Lovelace"));

    let events = a.subscribe();
    let report = a.sync_blocking(Mode::Full).unwrap();
    assert_eq!(report.changed, ["notes/ada-lovelace.md"]);
    // The events say the same, in order: started, indexed, files changed, finished.
    assert_eq!(wait_for(&events, "the sync starting", |e| matches!(e, Event::SyncStarted(Mode::Full)).then_some(())), ());
    let indexed = wait_for(&events, "the pulled note indexed", |e| match e {
        Event::IndexUpdated { changed, .. } => Some(changed.clone()),
        _ => None,
    });
    assert_eq!(indexed, ["notes/ada-lovelace.md"]);
    let files = wait_for(&events, "the files changed", |e| match e {
        Event::FilesChanged(paths) => Some(paths.clone()),
        _ => None,
    });
    assert_eq!(files, ["notes/ada-lovelace.md"]);
    wait_for(&events, "the sync finishing", |e| matches!(e, Event::SyncFinished(Ok(_))).then_some(()));
    // By the time anyone is told, the index already answers.
    let backlinks = Links::backlinks(&db, &Catalog::names(&db, &atlas).unwrap()).unwrap();
    assert_eq!(backlinks.iter().map(|l| l.source.as_str()).collect::<Vec<_>>(), ["daily/2026-10-31.md", "notes/ada-lovelace.md"]);
    assert!(Links::unresolved(&db).unwrap().is_empty());
}

#[test]
fn two_devices_editing_one_note_merge_as_notes() {
    let world = World::new();
    let a = world.first("a", Schedule::default());
    let base = "---\ntags: [project]\nmodified: 2026-10-31T10:00:00Z\n---\n# Atlas\n\n- one\n- two\n";
    a.write("notes/atlas.md", base).unwrap();
    a.sync_blocking(Mode::Full).unwrap();
    let b = world.second("b");

    // Each adds a tag, stamps the note, and edits a neighbouring line.
    a.write("notes/atlas.md", &base.replace("[project]", "[project, mine]").replace("10:00:00", "11:00:00").replace("- one", "- ONE")).unwrap();
    b.write("notes/atlas.md", &base.replace("[project]", "[project, yours]").replace("10:00:00", "12:00:00").replace("- two", "- TWO")).unwrap();
    a.sync_blocking(Mode::Full).unwrap();
    let report = b.sync_blocking(Mode::Full).unwrap();
    assert!(report.conflicted.is_empty(), "{report:?}");
    let merged = "---\ntags: [project, yours, mine]\nmodified: 2026-10-31T12:00:00Z\n---\n# Atlas\n\n- ONE\n- TWO\n";
    assert_eq!(b.graph().read("notes/atlas.md").unwrap().unwrap(), merged);
    a.sync_blocking(Mode::Full).unwrap();
    assert_eq!(a.graph().read("notes/atlas.md").unwrap().unwrap(), merged);
    assert_eq!(head_subject(a.graph().root()), "Merge changes from other devices");

    // The catalog on both has the merged tags.
    for engine in [&a, &b] {
        engine.settle();
        assert_eq!(Catalog::tags_of(&engine.index().unwrap(), "notes/atlas.md").unwrap(), ["project", "yours", "mine"]);
    }
}

#[test]
fn writing_is_pushed_on_its_own_once_it_pauses() {
    let world = World::new();
    let schedule = Schedule { idle: Duration::from_millis(150), ..Schedule::default() };
    let a = world.first("a", schedule);
    let events = a.subscribe();
    a.write("daily/2026-10-31.md", "- one\n").unwrap();
    a.write("daily/2026-10-31.md", "- one\n- two\n").unwrap();
    let report = wait_for(&events, "the scheduled push", |e| match e {
        Event::SyncFinished(Ok(report)) => Some(report.clone()),
        _ => None,
    });
    assert_eq!(report.committed.as_deref(), Some("Add daily note for 2026-10-31"));
    assert!(report.pushed);
    // One commit for both saves, on the remote.
    let b = world.second("b");
    assert_eq!(b.graph().read("daily/2026-10-31.md").unwrap().unwrap(), "- one\n- two\n");
    assert_eq!(Repository::open(b.graph().root()).unwrap().recent_commits("HEAD", 10).unwrap().len(), 1);
    assert_eq!(head_subject(b.graph().root()), "Add daily note for 2026-10-31");
}

#[test]
fn a_remote_out_of_reach_is_tried_again_until_it_answers() {
    let world = World::new();
    let schedule = Schedule { min_backoff: Duration::from_millis(100), max_backoff: Duration::from_millis(200), ..Schedule::default() };
    let a = world.first("a", schedule);
    a.write("notes/n.md", "# N\n").unwrap();
    a.sync_blocking(Mode::Full).unwrap();

    // The remote goes away.
    let away = world.root.path().join("away.git");
    std::fs::rename(world.remote(), &away).unwrap();
    let events = a.subscribe();
    a.write("notes/n.md", "# N\n\nwritten offline\n").unwrap();
    let failure = a.sync_blocking(Mode::Full).unwrap_err();
    assert!(failure.will_retry && !failure.needs_sign_in, "{failure:?}");
    assert!(matches!(a.status(), Status::Failed(_)));
    // What was written is committed all the same, and indexed.
    assert_eq!(head_subject(a.graph().root()), "Update N");
    assert_eq!(Search::search(&a.index().unwrap(), "offline", 5).unwrap().len(), 1);
    // It tries again by itself, and fails again…
    wait_for(&events, "a retry", |e| matches!(e, Event::SyncFinished(Err(_))).then_some(()));
    wait_for(&events, "another retry", |e| matches!(e, Event::SyncFinished(Err(_))).then_some(()));

    // …until the remote is back.
    std::fs::rename(&away, world.remote()).unwrap();
    let report = wait_for(&events, "the retry that works", |e| match e {
        Event::SyncFinished(Ok(report)) => Some(report.clone()),
        _ => None,
    });
    assert!(report.pushed);
    assert!(matches!(a.status(), Status::Synced(_)));
}

#[test]
fn files_written_around_the_engine_are_picked_up_when_it_is_told() {
    let world = World::new();
    let a = world.first("a", Schedule::default());
    a.settle(); // the indices' first build is done
    std::fs::create_dir_all(a.graph().root().join("notes")).unwrap();
    std::fs::write(a.graph().root().join("notes/external.md"), "# Written by another app\n").unwrap();
    a.settle();
    assert_eq!(Catalog::count(&a.index().unwrap()).unwrap(), 0, "nobody said anything changed");
    a.note_changed();
    a.settle();
    assert_eq!(Catalog::resolve(&a.index().unwrap(), "written by another app").unwrap().unwrap().path(), "notes/external.md");
    assert!(a.delete("notes/external.md").unwrap());
    a.settle();
    assert_eq!(Catalog::count(&a.index().unwrap()).unwrap(), 0);
    // Assets are stored, linked by path, and synced like anything else.
    let picture = a.add_asset("Team Photo.PNG", b"PNG\0").unwrap();
    assert_eq!(picture, "assets/team-photo.png");
    assert_eq!(a.sync_blocking(Mode::Full).unwrap().committed.as_deref(), Some("Add 1 attachment"));
}

#[test]
fn an_engine_restarted_finds_its_indices_where_it_left_them() {
    let world = World::new();
    let dir = world.root.path().join("a");
    {
        let a = world.first("a", Schedule::default());
        a.write("notes/n.md", "# Kept\n").unwrap();
        a.settle();
    }
    let a = Engine::start(&dir, World::config("a", Schedule::default())).unwrap();
    let events = a.subscribe();
    a.settle();
    assert_eq!(Catalog::count(&a.index().unwrap()).unwrap(), 1);
    // Nothing changed while it was away: nothing is re-indexed.
    assert!(events.try_recv().is_err());
    assert!(Engine::start(world.root.path().join("nowhere"), EngineConfig::default()).is_err());
    assert!(Engine::start(world.root.path(), EngineConfig::default()).is_err(), "a folder that is no repository");
    a.shutdown();
}

#[cfg(feature = "relay")]
#[test]
fn a_relay_saying_the_remote_moved_starts_a_sync() {
    use prism::relay::{relay::Message, ListenerEvent};
    let world = World::new();
    let a = world.first("a", Schedule::default());
    a.write("notes/n.md", "# N\n").unwrap();
    a.sync_blocking(Mode::Full).unwrap();
    let b = world.second("b");

    // A relay's worth of WebSocket server: says "pushed" when told to.
    let server = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = server.local_addr().unwrap().port();
    let (say_pushed, told) = std::sync::mpsc::channel::<String>();
    let (saw_token, token_seen) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let (stream, _) = server.accept().unwrap();
        let mut socket = tungstenite_accept(stream, saw_token);
        while let Ok(after) = told.recv() {
            socket.send(tungstenite::Message::text(Message::Push { after }.to_json())).unwrap();
        }
    });

    let events = b.subscribe();
    b.listen_for(&format!("ws://127.0.0.1:{port}"), "ada/notes");
    assert_eq!(token_seen.recv_timeout(Duration::from_secs(10)).unwrap(), "Bearer a-token");
    wait_for(&events, "the relay connecting", |e| matches!(e, Event::Relay(ListenerEvent::Connected)).then_some(()));
    // Connecting itself asks for a sync, to catch up.
    wait_for(&events, "the catch-up sync", |e| matches!(e, Event::SyncFinished(Ok(_))).then_some(()));

    a.write("notes/n.md", "# N\n\nfrom a\n").unwrap();
    let pushed = a.sync_blocking(Mode::Push).unwrap();
    say_pushed.send(pushed.head.unwrap().to_string()).unwrap();

    wait_for(&events, "the relay's word", |e| matches!(e, Event::Relay(ListenerEvent::Push { .. })).then_some(()));
    let files = wait_for(&events, "the pulled file", |e| match e {
        Event::FilesChanged(paths) => Some(paths.clone()),
        _ => None,
    });
    assert_eq!(files, ["notes/n.md"]);
    assert_eq!(b.graph().read("notes/n.md").unwrap().unwrap(), "# N\n\nfrom a\n");
    // A remote on a disk is not GitHub: `listen` cannot name its repository.
    assert!(matches!(b.listen("relay.example"), Err(prism::Error::NotOnGitHub)));
}

#[cfg(feature = "relay")]
fn tungstenite_accept(stream: std::net::TcpStream, saw_token: std::sync::mpsc::Sender<String>) -> tungstenite::WebSocket<std::net::TcpStream> {
    use tungstenite::handshake::server::{ErrorResponse, Request, Response};
    tungstenite::accept_hdr(stream, move |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        let _ = saw_token.send(request.headers().get("Authorization").map(|v| v.to_str().unwrap().to_owned()).unwrap_or_default());
        Ok(response)
    })
    .unwrap()
}
