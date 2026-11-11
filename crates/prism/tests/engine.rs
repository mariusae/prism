//! The whole engine: two devices, each an `Engine`, sharing a remote.

// tungstenite's handshake callback fixes the error type.
#![allow(clippy::result_large_err)]

use prism::index::{Catalog, Links, Search, Tasks};
use prism::markup::LinkKind;
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

#[test]
fn renaming_a_page_relinks_the_graph_and_the_indices_follow() {
    let world = World::new();
    let a = world.first("a", Schedule::default());
    a.write("notes/atlas.md", "# Project Atlas\n").unwrap();
    a.write("notes/ada.md", "# Ada\n\nWorks on [[project atlas]].\n").unwrap();
    a.write("daily/2026-10-31.md", "- [[Project Atlas]] kick-off\n").unwrap();
    a.write("notes/taken.md", "# Taken\n").unwrap();

    // Its heading changes, and its file stays. What was written with its
    // old title is written with its file's name — which no rename changes.
    let renamed = a.rename_note("notes/atlas.md", "Atlas Reborn").unwrap();
    assert_eq!(renamed.rewritten, ["notes/atlas.md", "daily/2026-10-31.md", "notes/ada.md"]);
    assert_eq!(a.graph().read("notes/ada.md").unwrap().unwrap(), "# Ada\n\nWorks on [[atlas]].\n");
    a.settle();
    let db = a.index().unwrap();
    assert_eq!(Catalog::resolve(&db, "Atlas Reborn").unwrap().unwrap().path(), "notes/atlas.md");
    assert_eq!(Catalog::resolve(&db, "atlas").unwrap().unwrap().path(), "notes/atlas.md");
    assert_eq!(Catalog::resolve(&db, "Project Atlas").unwrap(), None);
    assert_eq!(Links::leading_to(&db, "notes/atlas.md").unwrap().len(), 2);
    assert!(Links::unresolved(&db).unwrap().is_empty());
    // The rename's rewrites are committed like any other writing.
    assert_eq!(a.sync_blocking(Mode::Full).unwrap().committed.as_deref(), Some("Add 4 notes"));
    // Renamed again, nothing else is touched: no link says its title.
    assert_eq!(a.rename_note("notes/atlas.md", "Atlas Again").unwrap().rewritten, ["notes/atlas.md"]);
    // A date is a day's page, and no note's title.
    assert!(matches!(a.rename_note("notes/atlas.md", "2026-10-31"), Err(prism::Error::TitleTaken(_))));
}

#[test]
fn two_pages_may_have_one_title_and_no_link_changes_where_it_leads() {
    let world = World::new();
    let a = world.first("a", Schedule::default());
    // A note renamed since it was made: its file does not say its title.
    a.write("notes/scratch.md", "# Manifold\n").unwrap();
    a.write("notes/log.md", "# Log\n\n[[Manifold]], and #manifold\n").unwrap();
    a.write("rivers/Deck.md", "- [[Manifold]]\n").unwrap();
    a.settle();
    // Pages are dated to the second: the second note is made after the first.
    std::thread::sleep(Duration::from_millis(1100));

    // A second note of that title is a new file, whose name no link already says.
    let second = a.create_note("Manifold").unwrap();
    assert_eq!(second, "notes/manifold-2.md");
    assert_eq!(a.graph().read(&second).unwrap().unwrap(), "# Manifold\n");
    // What was written with the title led to the first, and is now written with its file's name.
    assert_eq!(a.graph().read("notes/log.md").unwrap().unwrap(), "# Log\n\n[[scratch]], and #manifold\n");
    assert_eq!(a.graph().read("rivers/Deck.md").unwrap().unwrap(), "- [[scratch]]\n");
    a.settle();
    let db = a.index().unwrap();
    let sources = |path: &str| Links::leading_to(&db, path).unwrap().into_iter().map(|link| (link.source, link.kind)).collect::<Vec<_>>();
    assert_eq!(
        sources("notes/scratch.md"),
        [("notes/log.md".to_owned(), LinkKind::Link), ("notes/log.md".to_owned(), LinkKind::Tag), ("rivers/Deck.md".to_owned(), LinkKind::Link)]
    );
    assert!(sources(&second).is_empty(), "the new note has no backlinks of the old one's");
    assert_eq!(Catalog::resolve(&db, "manifold-2").unwrap().unwrap().path(), second);
    assert_eq!(Catalog::duplicates(&db).unwrap(), [("Manifold".to_owned(), vec![second.clone(), "notes/scratch.md".to_owned()])]);
    assert_eq!(a.query("links to: manifold-2", None).unwrap().pages.len(), 0);
    assert_eq!(a.query("links to: scratch", None).unwrap().pages.len(), 1);

    // Renaming a note to a title another has is the same: that title's links are pinned first.
    a.write("notes/plan.md", "# Plan\n").unwrap();
    a.write("notes/todo.md", "# Todo\n\n[[Plan]]\n").unwrap();
    a.settle();
    let renamed = a.rename_note(&second, "plan").unwrap();
    assert_eq!(renamed.rewritten, [second.as_str(), "notes/todo.md"]);
    assert_eq!(a.graph().read("notes/todo.md").unwrap().unwrap(), "# Todo\n\n[[plan]]\n");
    a.settle();
    let db = a.index().unwrap();
    assert_eq!(Links::leading_to(&db, "notes/plan.md").unwrap().len(), 1);
    assert!(Links::leading_to(&db, &second).unwrap().is_empty());

    // A link written exactly as a file's name is that file, whatever else is titled so;
    // written any other way, it is the page of that title, as it always was.
    a.write("notes/atlas.md", "# Something Else\n").unwrap();
    a.write("notes/project.md", "# Atlas\n").unwrap();
    a.write("notes/both.md", "# Both\n\n[[atlas]] and [[Atlas]]\n").unwrap();
    a.settle();
    let db = a.index().unwrap();
    assert_eq!(Catalog::resolve(&db, "atlas").unwrap().unwrap().path(), "notes/atlas.md");
    assert_eq!(Catalog::resolve(&db, "Atlas").unwrap().unwrap().path(), "notes/project.md");
    assert_eq!(Links::linked_pages(&db, "notes/both.md", None).unwrap(), ["notes/atlas.md", "notes/project.md"]);
    // A new file never takes a name that is another page's title.
    assert_eq!(a.path_for_title("Something else"), "notes/something-else.md");
    a.write("notes/x.md", "---\naliases: [fresh]\n---\n# X\n").unwrap();
    assert_eq!(a.path_for_title("Fresh"), "notes/fresh-2.md");
}

#[cfg(feature = "watch")]
#[test]
fn a_watched_graph_notices_what_is_written_around_the_engine() {
    let world = World::new();
    let schedule = Schedule { idle: Duration::from_millis(100), ..Schedule::default() };
    let a = world.first("a", schedule);
    a.settle();
    a.watch().unwrap();
    let events = a.subscribe();
    std::thread::sleep(Duration::from_millis(200)); // let the watch take hold
    std::fs::create_dir_all(a.graph().root().join("notes")).unwrap();
    std::fs::write(a.graph().root().join("notes/external.md"), "# Written elsewhere\n").unwrap();
    wait_for(&events, "the external write indexed", |e| {
        matches!(e, Event::IndexUpdated { changed, .. } if changed.contains(&"notes/external.md".to_owned())).then_some(())
    });
    assert_eq!(Catalog::resolve(&a.index().unwrap(), "Written elsewhere").unwrap().unwrap().path(), "notes/external.md");
    // And, writing having paused, it is pushed without anyone asking.
    let report = wait_for(&events, "the push", |e| match e {
        Event::SyncFinished(Ok(report)) => Some(report.clone()),
        _ => None,
    });
    assert_eq!(report.committed.as_deref(), Some("Add Written elsewhere"));
    // The sync's own bookkeeping in .git starts nothing more.
    std::thread::sleep(Duration::from_millis(600));
    assert!(events.try_iter().all(|event| !matches!(event, Event::SyncStarted(_))));
}

#[test]
fn every_way_a_page_is_pointed_at_follows_its_names() {
    let world = World::new();
    let a = world.first("a", Schedule::default());
    a.write("notes/person.md", "---\naliases:\n  - Human\n  - Somebody\n---\n# Person\n").unwrap();
    a.write("notes/ada.md", "---\ntags: [Person]\n---\n# Ada\n\nA #person, a [[human]], [[Somebody|someone]].\n").unwrap();
    a.write("notes/secret.md", "---\nprivate: true\nrelated:\n  - Person\n---\n# Secret\n").unwrap();
    a.write("rivers/People.md", "---\nfolded:\n  - Person\n---\n- [[Person]]\n- [[Ada]]\n\n```query\ntag: Person\n```\n").unwrap();

    // An alias changed, or taken away: links written with it are written with the page's own name.
    let renamed = a.rename_alias("notes/person.md", "human", "Mortal").unwrap();
    assert_eq!((renamed.old_title.as_str(), renamed.new_title.as_str()), ("human", "Mortal"));
    assert_eq!(renamed.rewritten, ["notes/person.md", "notes/ada.md"]);
    a.remove_alias("notes/person.md", "somebody").unwrap();
    assert_eq!(a.graph().read("notes/person.md").unwrap().unwrap(), "---\naliases:\n  - Mortal\n---\n# Person\n");
    assert!(a.graph().read("notes/ada.md").unwrap().unwrap().ends_with("A #person, a [[person]], [[person|someone]].\n"));
    assert!(matches!(a.remove_alias("notes/person.md", "Nobody"), Err(prism::Error::NoSuchAlias(_))));

    // The title changed. Every link that pointed at it by its title — in
    // a line, in a frontmatter, a private page's too, a river's card and
    // its folded list — is written with the file's name. Tags are words,
    // and say what they said: they still lead to the page, by its file.
    let renamed = a.rename_note("notes/person.md", "People").unwrap();
    assert_eq!(renamed.rewritten, ["notes/person.md", "notes/secret.md", "rivers/People.md"]);
    assert_eq!(a.graph().read("notes/ada.md").unwrap().unwrap(), "---\ntags: [Person]\n---\n# Ada\n\nA #person, a [[person]], [[person|someone]].\n");
    assert_eq!(a.graph().read("notes/secret.md").unwrap().unwrap(), "---\nprivate: true\nrelated:\n  - person\n---\n# Secret\n");
    assert_eq!(a.graph().read("rivers/People.md").unwrap().unwrap(), "---\nfolded:\n  - person\n---\n- [[person]]\n- [[Ada]]\n\n```query\ntag: Person\n```\n");
    a.settle();
    let db = a.index().unwrap();
    assert!(Links::unresolved(&db).unwrap().is_empty());
    assert_eq!(a.query("tag: Person", None).unwrap().pages.len(), 1);
    assert_eq!(Links::leading_to(&a.index_showing_private().unwrap(), "notes/person.md").unwrap().len(), 6);
    // The river still reads as a river, and orders a query by its cards.
    assert_eq!(a.graph().river("People").unwrap().unwrap().folded, ["person"]);
    assert_eq!(a.query("listed in: rivers/People", None).unwrap().pages.iter().map(|p| p.title.as_str()).collect::<Vec<_>>(), ["People", "Ada"]);
}

#[test]
fn what_an_index_listed_is_found_again_after_the_page_changed() {
    let world = World::new();
    let a = world.first("a", Schedule::default());
    a.write("notes/plan.md", "# Plan\n\n+ [ ] Book a room\n+ [ ] Call [[Ada]]\n").unwrap();
    a.write("notes/ada.md", "# Ada\n").unwrap();
    a.settle();
    let db = a.index().unwrap();
    let listed = Tasks::open(&db).unwrap();
    let call = listed.iter().find(|task| task.text == "Call [[Ada]]").unwrap().clone();
    // A backlink comes with the row it is in.
    let backlinks = Links::backlinks(&db, &["Ada".into()]).unwrap();
    assert_eq!((backlinks[0].block.as_slice(), backlinks[0].context.as_str()), (&[2][..], "Call [[Ada]]"));

    // The page changes — lines above, by another hand — and the list on screen is now stale.
    a.write("notes/plan.md", "# Plan\n\nSome thoughts first.\n\n+ [ ] Something new\n+ [ ] Book a room\n+ [ ] Call [[Ada]]\n").unwrap();
    assert_eq!(a.set_task("notes/plan.md", &call.block, &call.text, true).unwrap(), Some(vec![4]));
    assert!(a.graph().read("notes/plan.md").unwrap().unwrap().ends_with("+ [ ] Something new\n+ [ ] Book a room\n+ [x] Call [[Ada]]\n"));
    assert_eq!(a.set_task("notes/plan.md", &[1], "A task since deleted", true).unwrap(), None);
    a.settle();
    assert_eq!(Tasks::counts(&a.index().unwrap()).unwrap(), (2, 1));
}

#[test]
fn pages_are_dated_by_history_and_by_what_is_not_committed_yet() {
    let world = World::new();
    let a = world.first("a", Schedule::default());
    let before = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64 - 2;
    a.write("notes/one.md", "# One\n").unwrap();
    a.settle();
    // Not committed: its file's time.
    let row = Catalog::get(&a.index().unwrap(), "notes/one.md").unwrap().unwrap();
    assert!(row.modified.is_some_and(|at| at >= before) && row.created == row.modified, "{row:?}");
    assert_eq!(prism::index::Times::unsaved(&a.index().unwrap()).unwrap().len(), 1);

    a.sync_blocking(Mode::Full).unwrap();
    // A first commit: the history is read apart, and waited for here.
    a.settle();
    let db = a.index().unwrap();
    assert!(prism::index::Times::unsaved(&db).unwrap().is_empty());
    let committed = prism::index::Times::committed(&db, "notes/one.md").unwrap().unwrap();
    assert!(committed.0 >= before && committed.0 == committed.1);
    assert_eq!(Catalog::get(&db, "notes/one.md").unwrap().unwrap().modified, Some(committed.1));

    // Another device's page arrives dated when that device committed it.
    let b = world.second("b");
    b.settle();
    assert_eq!(prism::index::Times::committed(&b.index().unwrap(), "notes/one.md").unwrap(), Some(committed));
    // And the file was never touched to say so.
    assert_eq!(b.graph().read("notes/one.md").unwrap().unwrap(), "# One\n");
}

#[test]
fn a_river_saved_keeps_what_a_newer_app_wrote_in_it() {
    let world = World::new();
    let a = world.first("a", Schedule::default());
    a.write("rivers/Work.md", "---\nlayout: board\nicon: tray\n---\n- [[One]]\n").unwrap();
    // Read, changed and saved,
    let mut river = a.graph().river("Work").unwrap().unwrap();
    river.cards.push(prism::markup::river::Card::new("Two"));
    assert!(a.save_river("Work", &river).unwrap());
    assert_eq!(a.graph().read("rivers/Work.md").unwrap().unwrap(), "---\nlayout: board\nicon: tray\n---\n- [[One]]\n- [[Two]]\n");
    // or made anew by an app that holds only what it shows.
    let made = prism::markup::River { cards: vec![prism::markup::river::Card::new("Three")], ..Default::default() };
    assert!(a.save_river("Work", &made).unwrap());
    assert_eq!(a.graph().read("rivers/Work.md").unwrap().unwrap(), "---\nlayout: board\n---\n- [[Three]]\n");
    // Saved as it is: nothing is written.
    assert!(!a.save_river("Work", &a.graph().river("Work").unwrap().unwrap()).unwrap());
}

#[test]
fn indexing_and_naming_do_not_wait_for_a_sync_that_is_on_the_network() {
    // A remote that takes the call and says nothing for a while.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let slow = std::thread::spawn(move || {
        let held: Vec<_> = listener.incoming().take(1).collect();
        std::thread::sleep(Duration::from_millis(1500));
        drop(held);
    });
    let root = tempfile::tempdir().unwrap();
    Repository::init(root.path(), "main").unwrap().set_remote("origin", &format!("http://127.0.0.1:{port}/graph.git")).unwrap();
    let a = Engine::start(root.path(), World::config("a", Schedule::default())).unwrap();
    a.write("notes/one.md", "# One\n").unwrap();
    a.settle();
    let events = a.subscribe();
    a.sync();
    wait_for(&events, "the cycle to start", |event| matches!(event, Event::SyncStarted(_)).then_some(()));
    std::thread::sleep(Duration::from_millis(200)); // committed; now waiting on the remote

    // Meanwhile: written, indexed, named, renamed — none of it waits.
    let started = std::time::Instant::now();
    let two = a.create_note("Two").unwrap();
    a.write("notes/three.md", "# Three\n\n[[Two]]\n").unwrap();
    a.rename_note(&two, "Second").unwrap();
    a.settle();
    let db = a.index().unwrap();
    assert_eq!(Catalog::resolve(&db, "Second").unwrap().unwrap().path(), two);
    assert_eq!(a.graph().read("notes/three.md").unwrap().unwrap(), "# Three\n\n[[two]]\n");
    assert_eq!(Links::leading_to(&db, &two).unwrap().len(), 1);
    assert!(started.elapsed() < Duration::from_millis(900), "took {:?}", started.elapsed());
    assert_eq!(a.status(), Status::Syncing, "and the sync is still out");

    let outcome = wait_for(&events, "the cycle to end", |event| match event {
        Event::SyncFinished(outcome) => Some(outcome.clone()),
        _ => None,
    });
    assert!(outcome.is_err_and(|failure| failure.will_retry));
    slow.join().unwrap();
}

#[test]
fn what_the_engine_wrote_is_indexed_from_those_files_alone_and_comes_to_the_same() {
    let world = World::new();
    let a = world.first("a", Schedule::default());
    a.settle();
    let events = a.subscribe();
    a.write("notes/one.md", "# One\n\n[[Two]]\n").unwrap();
    a.write("notes/deep/two.md", "# Two\n").unwrap();
    a.add_asset("Picture.PNG", b"PNG").unwrap();
    a.write("notes/one.md", "# One\n\n[[Two]] ![](assets/picture.png)\n").unwrap();
    a.delete("notes/deep/two.md").unwrap();
    a.settle();
    let indexed = events.try_iter().filter_map(|event| match event {
        Event::IndexUpdated { tree, .. } => Some(tree),
        _ => None,
    });
    let last = indexed.last().expect("the writes were indexed");
    // Looking at every file finds the very tree the files written added up to.
    assert_eq!(Repository::open(a.graph().root()).unwrap().snapshot(&Default::default()).unwrap().tree, last);
    a.note_changed();
    a.settle();
    assert!(events.try_iter().all(|event| !matches!(event, Event::IndexUpdated { .. })), "nothing was missed");
    let db = a.index().unwrap();
    assert_eq!(Links::unresolved(&db).unwrap(), [("Two".to_owned(), 1)]);
    assert_eq!(prism::index::Assets::used_in(&db, "assets/picture.png").unwrap().len(), 1);

    // Written around the engine, by one who says what it wrote.
    std::fs::write(a.graph().root().join("notes/aside.md"), "# Aside\n").unwrap();
    a.paths_changed(&["notes/aside.md".to_owned()]);
    a.settle();
    assert!(Catalog::get(&a.index().unwrap(), "notes/aside.md").unwrap().is_some());
    // And it is all committed as what it is.
    assert_eq!(a.sync_blocking(Mode::Full).unwrap().committed.as_deref(), Some("Add 2 notes and 1 attachment"));
}
