//! The engine: a graph kept synced and indexed, in the background.
//!
//! See [`Engine`].

use crate::commit_message::NoteDescriber;
use crate::graph::{Graph, Renamed, Saved};
use crate::note_merge::NoteMergeDriver;
use crate::{Error, Result};
use prism_index::{Catalog, Indexer, Links, Resolved};
use prism_sync::{Auth, Mode, Oid, Report, Repository, Schedule, Scheduler, SnapshotOptions, StopHandle, Syncer};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime};

/// How an engine is set up.
#[derive(Clone, Default)]
pub struct EngineConfig {
    /// How syncing behaves: the remote, who commits, this device's name.
    pub sync: prism_sync::Config,
    /// When syncing happens.
    pub schedule: Schedule,
    /// How the remote is told who is syncing.
    pub auth: Auth,
    /// Where the index database is kept. `None`: inside the repository's
    /// own `.git`, where it is never committed and each clone has its own.
    pub index_path: Option<PathBuf>,
}

/// Something the engine did, or found out.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// A sync cycle began.
    SyncStarted(Mode),
    /// A sync cycle ended: what it did, or why it failed.
    SyncFinished(std::result::Result<Report, SyncFailure>),
    /// A sync wrote these files: what is on screen may be out of date.
    /// (Their new contents are already indexed.)
    FilesChanged(Vec<String>),
    /// The indices were brought up to a tree: these paths were ingested.
    /// What an app showing backlinks, search results or tasks redraws on.
    IndexUpdated { tree: Oid, changed: Vec<String> },
    /// Indexing failed. Syncing goes on regardless.
    IndexFailed(String),
    /// The relay's socket opened, heard of a push, or dropped.
    #[cfg(feature = "relay")]
    Relay(prism_relay::ListenerEvent),
}

/// Why a sync cycle failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncFailure {
    pub message: String,
    /// Whether it will be tried again unasked: the network was down, the
    /// remote was busy. Otherwise someone has to do something — sign in,
    /// look at the repository.
    pub will_retry: bool,
    /// Whether signing in again is what it takes.
    pub needs_sign_in: bool,
}

/// How syncing stands.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Status {
    #[default]
    Idle,
    Syncing,
    /// The last cycle went well, then.
    Synced(SystemTime),
    Failed(SyncFailure),
}

enum Command {
    /// Something was written in the working tree.
    Changed,
    Sync(Mode),
    /// A cycle now, and its outcome sent back.
    SyncNow(Mode, mpsc::Sender<std::result::Result<Report, SyncFailure>>),
    /// Answered once everything asked before it is done.
    Settle(mpsc::Sender<()>),
    Stop,
}

#[derive(Default)]
struct Shared {
    status: Mutex<Status>,
    subscribers: Mutex<Vec<mpsc::Sender<Event>>>,
}

impl Shared {
    fn emit(&self, event: Event) {
        if let Ok(mut subscribers) = self.subscribers.lock() {
            subscribers.retain(|subscriber| subscriber.send(event.clone()).is_ok());
        }
    }

    fn set_status(&self, status: Status) {
        if let Ok(mut current) = self.status.lock() {
            *current = status;
        }
    }
}

/// A graph, kept synced and indexed, in the background.
///
/// An engine owns one thread. On it, in turn, it
///
/// - **indexes** — after anything is written, and after every sync, the
///   indices are brought up to the working tree ([`prism_index`]);
/// - **syncs** — on the [schedule](prism_sync::schedule): a while after
///   writing stops, and whenever asked;
/// - **tells** — everything it does is an [`Event`] to whoever
///   [subscribed](Engine::subscribe).
///
/// An app is then a view: it writes notes through the engine, asks the
/// indices its questions on its own thread ([`Engine::index`]), and
/// redraws when an event says something changed.
///
/// One thread means one thing at a time, in order — no locks around the
/// repository, no index half-way between two trees. The price: while a
/// sync is talking to the network, indexing waits for it.
pub struct Engine {
    graph: Graph,
    commands: mpsc::Sender<Command>,
    shared: Arc<Shared>,
    stop: StopHandle,
    index_path: PathBuf,
    auth: Auth,
    remote_url: Option<String>,
    thread: Option<std::thread::JoinHandle<()>>,
    #[cfg(feature = "relay")]
    listener: Mutex<Option<prism_relay::Listener>>,
    #[cfg(feature = "watch")]
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
}

/// Whether a path a watcher reports is one of the graph's own files:
/// not git's bookkeeping, and not a file half-written on its way in.
#[cfg(feature = "watch")]
fn is_graph_file(root: &Path, path: &Path) -> bool {
    let relative = path.strip_prefix(root).unwrap_or(path);
    let in_git = relative.components().any(|part| part.as_os_str() == ".git");
    let temporary = path.file_name().is_some_and(|name| name.to_string_lossy().contains(".prism-"));
    !in_git && !temporary
}

impl Engine {
    /// Starts an engine on the graph at `root`, which must be a git
    /// repository's working tree. The indices are brought up to date at
    /// once; syncing waits to be asked, or for something to be written.
    pub fn start(root: impl AsRef<Path>, config: EngineConfig) -> Result<Engine> {
        let graph = Graph::open(root.as_ref())?;
        let repo = Repository::open(root.as_ref())?;
        let index_path = config.index_path.clone().unwrap_or_else(|| repo.git_dir().join("prism").join("index.sqlite"));
        let indexer = Indexer::open(&index_path, prism_index::standard())?;
        let remote_url = repo.remote_url(&config.sync.remote);
        let stop = StopHandle::default();
        let snapshot = SnapshotOptions { max_file_bytes: Some(config.sync.max_file_bytes), exclude: config.sync.exclude.clone() };
        let syncer = Syncer::new(repo, config.sync)
            .with_auth(config.auth.clone())
            .with_merge_driver(NoteMergeDriver)
            .with_describer(NoteDescriber)
            .with_stop_handle(stop.clone());
        let shared = Arc::new(Shared::default());
        let (commands, inbox) = mpsc::channel();
        let worker = Worker { syncer, indexer, scheduler: Scheduler::new(config.schedule), shared: shared.clone(), snapshot };
        let thread = std::thread::Builder::new()
            .name("prism-engine".into())
            .spawn(move || worker.run(inbox))
            .map_err(|e| Error::io("starting the engine's thread", e))?;
        Ok(Engine {
            graph,
            commands,
            shared,
            stop,
            index_path,
            auth: config.auth,
            remote_url,
            thread: Some(thread),
            #[cfg(feature = "relay")]
            listener: Mutex::new(None),
            #[cfg(feature = "watch")]
            watcher: Mutex::new(None),
        })
    }

    /// Clones a repository into `root`, and starts an engine on it.
    pub fn clone_from(url: &str, root: impl AsRef<Path>, config: EngineConfig) -> Result<Engine> {
        Repository::clone(url, root.as_ref(), &config.auth)?;
        Engine::start(root, config)
    }

    /// The graph's files.
    pub fn graph(&self) -> &Graph {
        &self.graph
    }

    // --- Writing -----------------------------------------------------------

    /// Writes a file, and has it indexed and, in a while, synced. Says
    /// whether anything was written. See [`Graph::write`].
    pub fn write(&self, path: &str, content: &str) -> Result<bool> {
        let written = self.graph.write(path, content)?;
        if written {
            self.note_changed();
        }
        Ok(written)
    }

    /// Saves a draft without overwriting what changed underneath it. See
    /// [`Graph::save_merging`].
    pub fn save_merging(&self, path: &str, draft: &str, base: Option<&str>) -> Result<Saved> {
        let saved = self.graph.save_merging(path, draft, base)?;
        self.note_changed();
        Ok(saved)
    }

    /// Makes a new note. See [`Graph::create_note`].
    pub fn create_note(&self, title: &str) -> Result<String> {
        let path = self.graph.create_note(title)?;
        self.note_changed();
        Ok(path)
    }

    /// Keeps a file in `assets/`. See [`Graph::add_asset`].
    pub fn add_asset(&self, name: &str, content: &[u8]) -> Result<String> {
        let path = self.graph.add_asset(name, content)?;
        self.note_changed();
        Ok(path)
    }

    pub fn delete(&self, path: &str) -> Result<bool> {
        let deleted = self.graph.delete(path)?;
        if deleted {
            self.note_changed();
        }
        Ok(deleted)
    }

    /// Renames a page, and relinks the graph: every page that linked to
    /// the old title, and every saved river that held it, names the new
    /// one. The page's file and `id` stay as they are. See
    /// [`Graph::rename_note`].
    pub fn rename_note(&self, path: &str, new_title: &str) -> Result<Renamed> {
        // The index must have seen everything written so far.
        self.settle();
        let db = self.index()?;
        let old_title = match self.graph.note(path)? {
            Some(note) => note.title(path),
            None => return Err(Error::NotRenamable(path.to_owned())),
        };
        if let Some(Resolved::Note(other)) = Catalog::resolve(&db, new_title)? {
            if other != path {
                return Err(Error::TitleTaken(new_title.trim().to_owned()));
            }
        }
        let mut linking: Vec<String> = Links::backlinks(&db, &[old_title])?.into_iter().map(|link| link.source).collect();
        linking.dedup();
        let renamed = self.graph.rename_note(path, new_title, &linking)?;
        self.note_changed();
        Ok(renamed)
    }

    /// Saves a river. See [`Graph::save_river`].
    pub fn save_river(&self, name: &str, river: &prism_markup::River) -> Result<bool> {
        let written = self.graph.save_river(name, river)?;
        if written {
            self.note_changed();
        }
        Ok(written)
    }

    /// Runs a query block's body against the indices. `this` is the
    /// title of the page the query is in, for `{this}`.
    pub fn query(&self, body: &str, this: Option<&str>) -> Result<prism_index::QueryResult> {
        Ok(prism_index::query::run_text(&self.index()?, body, &prism_index::QueryOptions { this, include_private: false })?)
    }

    /// Something in the working tree changed, by whatever hand: index it
    /// now, and sync it once writing pauses. Call it for writes made
    /// around the engine — by a file watcher's say-so, by another app.
    pub fn note_changed(&self) {
        let _ = self.commands.send(Command::Changed);
    }

    // --- Syncing -----------------------------------------------------------

    /// Asks for a full sync — commit, fetch, merge, push — now, or
    /// straight after the cycle that is running. For launch, for coming
    /// to the front, for a pull-to-refresh.
    pub fn sync(&self) {
        let _ = self.commands.send(Command::Sync(Mode::Full));
    }

    /// Asks for what is written to be committed and pushed now, rather
    /// than when writing pauses. For going to the background.
    pub fn push(&self) {
        let _ = self.commands.send(Command::Sync(Mode::Push));
    }

    /// The remote moved — a relay said so, or a silent push did: sync.
    pub fn remote_changed(&self) {
        self.sync();
    }

    /// A cycle, now, waited for: its report, or why it failed. For a
    /// command line, a test, a background wake that must say when it is
    /// done.
    pub fn sync_blocking(&self, mode: Mode) -> std::result::Result<Report, SyncFailure> {
        let gone = || SyncFailure { message: "the engine has stopped".into(), will_retry: false, needs_sign_in: false };
        let (answer, outcome) = mpsc::channel();
        self.commands.send(Command::SyncNow(mode, answer)).map_err(|_| gone())?;
        outcome.recv().map_err(|_| gone())?
    }

    /// Asks a cycle under way to stop at its next safe point — the
    /// system is taking the app's time back. What it committed stays.
    pub fn stop_sync(&self) {
        self.stop.stop();
    }

    /// Waits until everything asked of the engine so far is done: what
    /// was written is indexed. (Not for a sync that is merely scheduled.)
    pub fn settle(&self) {
        let (answer, done) = mpsc::channel();
        if self.commands.send(Command::Settle(answer)).is_ok() {
            let _ = done.recv();
        }
    }

    pub fn status(&self) -> Status {
        self.shared.status.lock().map(|status| status.clone()).unwrap_or_default()
    }

    // --- Watching and asking -----------------------------------------------

    /// Everything the engine does from now on, as it happens.
    pub fn subscribe(&self) -> mpsc::Receiver<Event> {
        let (subscriber, events) = mpsc::channel();
        if let Ok(mut subscribers) = self.shared.subscribers.lock() {
            subscribers.push(subscriber);
        }
        events
    }

    /// A connection to the indices, to ask them questions on the caller's
    /// own thread: `Catalog::resolve(&db, "Atlas")`, `Links::backlinks`,
    /// `Search::search`, `Tasks::open`. Read-only; never blocked by, and
    /// never blocking, the engine. Keep it for as long as it is useful.
    pub fn index(&self) -> Result<prism_index::rusqlite::Connection> {
        Ok(Indexer::reader(&self.index_path)?)
    }

    /// Where the graph's remote is.
    pub fn remote_url(&self) -> Option<&str> {
        self.remote_url.as_deref()
    }

    /// Listens to a sync relay, and syncs when it says the repository
    /// was pushed to — and each time the socket opens, since anything
    /// may have been missed while it was not. The repository is the
    /// remote's, which must be on GitHub; the token is the sync's own.
    #[cfg(feature = "relay")]
    pub fn listen(&self, relay: &str) -> Result<()> {
        let repository = self.remote_url.as_deref().and_then(prism_github::repository_from_remote).ok_or(Error::NotOnGitHub)?;
        self.listen_for(relay, &repository);
        Ok(())
    }

    /// As [`listen`](Self::listen), for a repository named outright
    /// (`owner/name`) rather than read off the remote.
    #[cfg(feature = "relay")]
    pub fn listen_for(&self, relay: &str, repository: &str) {
        let auth = self.auth.clone();
        let (commands, shared) = (self.commands.clone(), self.shared.clone());
        let listener = prism_relay::Listener::spawn(
            prism_relay::ListenerConfig::new(relay, repository),
            move || auth.current_token().unwrap_or_else(|| Err("no GitHub token is set up".into())),
            move |event| {
                if !matches!(event, prism_relay::ListenerEvent::Disconnected { .. }) {
                    let _ = commands.send(Command::Sync(Mode::Full));
                }
                shared.emit(Event::Relay(event));
            },
        );
        if let Ok(mut current) = self.listener.lock() {
            *current = Some(listener);
        }
    }

    /// Watches the graph's folder, and takes any write made around the
    /// engine — by another app, by a person in a terminal — as
    /// [`note_changed`](Self::note_changed): indexed at once, synced in a
    /// while. What changed is told as [`Event::IndexUpdated`].
    #[cfg(feature = "watch")]
    pub fn watch(&self) -> Result<()> {
        use notify::Watcher;
        let commands = self.commands.clone();
        // Events name files as the system does, links resolved.
        let root = self.graph.root().canonicalize().unwrap_or_else(|_| self.graph.root().to_owned());
        let watched = root.clone();
        let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            let Ok(event) = event else { return };
            if !matches!(event.kind, notify::EventKind::Access(_)) && event.paths.iter().any(|path| is_graph_file(&root, path)) {
                let _ = commands.send(Command::Changed);
            }
        })
        .map_err(|e| Error::Watch(e.to_string()))?;
        watcher.watch(&watched, notify::RecursiveMode::Recursive).map_err(|e| Error::Watch(e.to_string()))?;
        if let Ok(mut current) = self.watcher.lock() {
            *current = Some(watcher);
        }
        Ok(())
    }

    /// Stops the engine: a cycle under way stops at its next safe point,
    /// and the thread ends. Dropping the engine does the same.
    pub fn shutdown(mut self) {
        self.shut_down();
    }

    fn shut_down(&mut self) {
        #[cfg(feature = "relay")]
        if let Ok(mut listener) = self.listener.lock() {
            listener.take();
        }
        #[cfg(feature = "watch")]
        if let Ok(mut watcher) = self.watcher.lock() {
            watcher.take();
        }
        self.stop.stop();
        let _ = self.commands.send(Command::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.shut_down();
    }
}

/// The engine's thread: the only place the repository and the indices
/// are written from.
struct Worker {
    syncer: Syncer,
    indexer: Indexer,
    scheduler: Scheduler,
    shared: Arc<Shared>,
    snapshot: SnapshotOptions,
}

impl Worker {
    fn run(mut self, inbox: mpsc::Receiver<Command>) {
        if self.reindex() {
            // Written while no engine ran: to be committed like anything else.
            self.scheduler.note_changed(Instant::now());
        }
        loop {
            if let Some(mode) = self.scheduler.poll(Instant::now()) {
                let _ = self.cycle(mode); // told to subscribers
                continue;
            }
            let command = match self.scheduler.next_wake() {
                Some(wake) => match inbox.recv_timeout(wake.saturating_duration_since(Instant::now())) {
                    Ok(command) => command,
                    Err(RecvTimeoutError::Timeout) => continue,
                    Err(RecvTimeoutError::Disconnected) => return,
                },
                None => match inbox.recv() {
                    Ok(command) => command,
                    Err(_) => return,
                },
            };
            // Everything already asked is taken together: ten saves in a
            // row are indexed once.
            let mut changed = false;
            let mut settled = Vec::new();
            for command in std::iter::once(command).chain(std::iter::from_fn(|| inbox.try_recv().ok())) {
                match command {
                    Command::Changed => changed = true,
                    Command::Sync(mode) => self.scheduler.request(mode),
                    Command::SyncNow(mode, answer) => {
                        self.scheduler.request(mode);
                        let outcome = match self.scheduler.poll(Instant::now()) {
                            Some(mode) => self.cycle(mode),
                            None => Err(SyncFailure { message: "a sync is already running".into(), will_retry: true, needs_sign_in: false }),
                        };
                        changed = false; // the cycle indexed
                        let _ = answer.send(outcome);
                    }
                    Command::Settle(answer) => settled.push(answer),
                    Command::Stop => return,
                }
            }
            // Indexed now; synced in a while — if there is anything to
            // commit. A file touched and left as it was, or a sync's own
            // writing seen by a watcher, asks nothing of the remote.
            if changed && self.reindex() {
                self.scheduler.note_changed(Instant::now());
            }
            for answer in settled {
                let _ = answer.send(());
            }
        }
    }

    /// Brings the indices up to the working tree as it is now. Says
    /// whether the working tree has anything not yet committed.
    fn reindex(&mut self) -> bool {
        let repo = self.syncer.repository();
        let snapshot = match repo.snapshot(&self.snapshot) {
            Ok(snapshot) => snapshot,
            Err(error) => {
                self.shared.emit(Event::IndexFailed(error.to_string()));
                return true; // unknown: let a sync find out
            }
        };
        match self.indexer.update(repo, snapshot.tree) {
            Ok(update) if update.is_noop() => {}
            Ok(update) => self.shared.emit(Event::IndexUpdated { tree: snapshot.tree, changed: update.changed }),
            Err(error) => self.shared.emit(Event::IndexFailed(error.to_string())),
        }
        repo.head_tree().map(|head| head != Some(snapshot.tree)).unwrap_or(true)
    }

    fn cycle(&mut self, mode: Mode) -> std::result::Result<Report, SyncFailure> {
        self.shared.set_status(Status::Syncing);
        self.shared.emit(Event::SyncStarted(mode));
        let result = self.syncer.sync(mode);
        // Whatever the cycle managed, the working tree is what it is now.
        self.reindex();
        let outcome = match result {
            Ok(report) => {
                self.scheduler.finished(Instant::now(), true);
                self.shared.set_status(Status::Synced(SystemTime::now()));
                if !report.changed.is_empty() {
                    self.shared.emit(Event::FilesChanged(report.changed.clone()));
                }
                Ok(report)
            }
            Err(prism_sync::Error::Stopped) => {
                // Asked to stop: no failure, and nothing to retry until
                // the app is back and asks.
                self.scheduler.finished(Instant::now(), true);
                self.shared.set_status(Status::Idle);
                Err(SyncFailure { message: prism_sync::Error::Stopped.to_string(), will_retry: false, needs_sign_in: false })
            }
            Err(error) => {
                let failure =
                    SyncFailure { message: error.to_string(), will_retry: error.is_transient(), needs_sign_in: matches!(error, prism_sync::Error::Auth(_)) };
                self.scheduler.finished_as(Instant::now(), if failure.will_retry { Err(mode) } else { Ok(()) });
                self.shared.set_status(Status::Failed(failure.clone()));
                Err(failure)
            }
        };
        self.shared.emit(Event::SyncFinished(outcome.clone()));
        outcome
    }
}
