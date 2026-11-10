//! The engine: a graph kept synced and indexed, in the background.
//!
//! See [`Engine`].

use crate::commit_message::NoteDescriber;
use crate::graph::{Graph, Renamed, Saved};
use crate::note_merge::NoteMergeDriver;
use crate::{Error, Result};
use prism_index::{Catalog, History, Indexer, Links, Times};
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
    /// With no paths: only when pages were made and changed was brought
    /// up to date — a history read, on a first run.
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

/// What the indexing thread is asked.
enum IndexCommand {
    /// Files were written in the working tree: these, or — `None` —
    /// nobody knows which.
    Changed(Option<Vec<String>>),
    /// A sync has written the working tree: look at all of it again, and
    /// say when that is done.
    Reindex(mpsc::Sender<()>),
    /// The history read apart has been read.
    History(std::result::Result<History, String>),
    /// Answered once everything asked before it is done.
    Settle(mpsc::Sender<()>),
    Stop,
}

/// What the syncing thread is asked.
enum SyncCommand {
    /// The working tree, as this tree, holds something not yet
    /// committed (`None`: it may; nobody could tell) — as seen when so
    /// many cycles had run.
    Dirty {
        tree: Option<Oid>,
        as_of: u64,
    },
    Sync(Mode),
    /// A cycle now, and its outcome sent back.
    SyncNow(Mode, mpsc::Sender<std::result::Result<Report, SyncFailure>>),
    Stop,
}

#[derive(Default)]
struct Shared {
    status: Mutex<Status>,
    subscribers: Mutex<Vec<mpsc::Sender<Event>>>,
    /// How many sync cycles have run: what dates a thread's view of
    /// what is committed.
    cycles: std::sync::atomic::AtomicU64,
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
/// An engine owns two threads, each doing one thing at a time, in order:
///
/// - one **indexes** — after anything is written, and after every sync,
///   the indices are brought up to the working tree ([`prism_index`]);
/// - one **syncs** — on the [schedule](prism_sync::schedule): a while
///   after writing stops, and whenever asked.
///
/// And everything either does is an [`Event`] to whoever
/// [subscribed](Engine::subscribe).
///
/// An app is then a view: it writes notes through the engine, asks the
/// indices its questions on its own thread ([`Engine::index`]), and
/// redraws when an event says something changed.
///
/// **Indexing never waits for the network.** A sync may spend seconds
/// talking to a remote; what is typed meanwhile is indexed as it is
/// written, and making or renaming a page — which ask the index — answer
/// at once. The two threads share nothing but the repository's object
/// store, which git lets any number write to: the indexing thread only
/// reads the working tree and never touches git's index or its branches;
/// the indices' database has one writer, and it is that thread.
///
/// **Indexing costs what was written.** The engine knows which files it
/// wrote, so it hashes those and no others
/// ([`Repository::snapshot_paths`]); the working tree is looked at whole
/// only at start, and when told something changed without being told
/// what. After a sync it need not be: the sync looked at every file
/// itself, and committed what it found.
pub struct Engine {
    graph: Graph,
    indexing: mpsc::Sender<IndexCommand>,
    syncing: mpsc::Sender<SyncCommand>,
    shared: Arc<Shared>,
    stop: StopHandle,
    index_path: PathBuf,
    local: crate::Local,
    auth: Auth,
    remote_url: Option<String>,
    threads: Vec<std::thread::JoinHandle<()>>,
    #[cfg(feature = "relay")]
    listener: Mutex<Option<prism_relay::Listener>>,
    #[cfg(feature = "watch")]
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
}

/// The files that point at a page by one of its names — pages and saved
/// rivers — when that name leads to this page; `None` when it leads to
/// another (of two pages with one name, the links are the first's).
fn pointing_at(db: &prism_index::rusqlite::Connection, path: &str, name: &str) -> Result<Option<Vec<String>>> {
    if Catalog::answering(db, name)?.first().is_none_or(|(first, _)| first != path) {
        return Ok(None);
    }
    let mut sources: Vec<String> = Links::backlinks(db, &[name.to_owned()])?.into_iter().map(|link| link.source).collect();
    sources.dedup();
    Ok(Some(sources))
}

/// A path a watcher reports, as the graph's own: `None` for git's
/// bookkeeping, a file half-written on its way in, or a file outside.
#[cfg(feature = "watch")]
fn graph_path(root: &Path, path: &Path) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    let in_git = relative.components().any(|part| part.as_os_str() == ".git");
    let temporary = path.file_name().is_some_and(|name| name.to_string_lossy().contains(".prism-"));
    let parts: Option<Vec<&str>> = relative.components().map(|part| part.as_os_str().to_str()).collect();
    (!in_git && !temporary).then_some(parts?.join("/")).filter(|path| !path.is_empty())
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
        let local = crate::Local::open(index_path.with_file_name("local.sqlite"))?;
        let remote_url = repo.remote_url(&config.sync.remote);
        let stop = StopHandle::default();
        // The indexing thread's own handle; it leaves git's index to the sync.
        let options = SnapshotOptions { max_file_bytes: Some(config.sync.max_file_bytes), exclude: config.sync.exclude.clone(), leave_index: true };
        let index_repo = repo.reopen()?;
        let syncer = Syncer::new(repo, config.sync)
            .with_auth(config.auth.clone())
            .with_merge_driver(NoteMergeDriver)
            .with_describer(NoteDescriber)
            .with_stop_handle(stop.clone());
        let shared = Arc::new(Shared::default());
        let (indexing, index_inbox) = mpsc::channel();
        let (syncing, sync_inbox) = mpsc::channel();
        let index_worker = IndexWorker {
            repo: index_repo,
            indexer,
            options,
            shared: shared.clone(),
            tree: None,
            unsaved: Vec::new(),
            syncing: syncing.clone(),
            indexing: indexing.clone(),
            reading_history: false,
            waiting: Vec::new(),
        };
        let sync_worker = SyncWorker { syncer, scheduler: Scheduler::new(config.schedule), shared: shared.clone(), indexing: indexing.clone() };
        let spawn = |name: &str, work: Box<dyn FnOnce() + Send>| {
            std::thread::Builder::new().name(name.into()).spawn(work).map_err(|e| Error::io("starting the engine's threads", e))
        };
        let threads =
            vec![spawn("prism-index", Box::new(move || index_worker.run(index_inbox)))?, spawn("prism-sync", Box::new(move || sync_worker.run(sync_inbox)))?];
        Ok(Engine {
            graph,
            indexing,
            syncing,
            shared,
            stop,
            index_path,
            local,
            auth: config.auth,
            remote_url,
            threads,
            #[cfg(feature = "relay")]
            listener: Mutex::new(None),
            #[cfg(feature = "watch")]
            watcher: Mutex::new(None),
        })
    }

    /// Clones a repository into `root`, and starts an engine on it.
    pub fn clone_from(url: &str, root: impl AsRef<Path>, config: EngineConfig) -> Result<Engine> {
        Engine::clone_watched(url, root, config, |_| {})
    }

    /// As [`clone_from`](Self::clone_from), saying how far along the
    /// clone is as it goes. Once the clone is down the graph is indexed,
    /// which is not counted: that is the engine starting, as ever.
    pub fn clone_watched(url: &str, root: impl AsRef<Path>, config: EngineConfig, progress: impl FnMut(prism_sync::CloneProgress)) -> Result<Engine> {
        Repository::clone_watched(url, root.as_ref(), &config.auth, progress)?;
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
            self.wrote([path]);
        }
        Ok(written)
    }

    /// Saves a draft without overwriting what changed underneath it. See
    /// [`Graph::save_merging`].
    pub fn save_merging(&self, path: &str, draft: &str, base: Option<&str>) -> Result<Saved> {
        let saved = self.graph.save_merging(path, draft, base)?;
        self.wrote([path]);
        Ok(saved)
    }

    /// Makes a new note — or answers the page that already has the
    /// title, or answers to it as an alias: a graph is not given two
    /// pages of one name by asking twice. A new note is `notes/<slug>.md`
    /// with the title as its first heading; a date's or a week's title
    /// makes that day's or week's page.
    pub fn create_note(&self, title: &str) -> Result<String> {
        self.settle();
        if let Some((existing, _)) = Catalog::answering(&self.everything()?, title)?.into_iter().next() {
            return Ok(existing);
        }
        let path = self.graph.create_note(title)?;
        self.wrote([path.as_str()]);
        Ok(path)
    }

    /// Checks a task off, or opens it again, as a list of tasks shows it:
    /// by the page, the block and the text the index gave
    /// ([`TaskRow`](prism_index::TaskRow)). The task is found by its text
    /// where the page has changed since. See [`Graph::set_task`].
    pub fn set_task(&self, path: &str, block: &[usize], text: &str, done: bool) -> Result<Option<Vec<usize>>> {
        let found = self.graph.set_task(path, block, text, done)?;
        if found.is_some() {
            self.wrote([path]);
        }
        Ok(found)
    }

    /// Keeps a file in `assets/`. See [`Graph::add_asset`].
    pub fn add_asset(&self, name: &str, content: &[u8]) -> Result<String> {
        let path = self.graph.add_asset(name, content)?;
        self.wrote([path.as_str()]);
        Ok(path)
    }

    pub fn delete(&self, path: &str) -> Result<bool> {
        let deleted = self.graph.delete(path)?;
        if deleted {
            self.wrote([path]);
        }
        Ok(deleted)
    }

    /// Renames a page, and relinks the graph: every file that pointed at
    /// the old title — by link, embed or tag, in a page or as a card of a
    /// saved river — names the new one. The page's file stays where it
    /// is. See [`Note::relink`](prism_markup::Note::relink) for what is
    /// rewritten.
    ///
    /// Only links that led to *this* page are rewritten. Of two pages
    /// with one title, links lead to the first; renaming the other
    /// retitles it and touches nothing else.
    pub fn rename_note(&self, path: &str, new_title: &str) -> Result<Renamed> {
        // The index must have seen everything written so far.
        self.settle();
        let db = self.everything()?;
        let new_title = new_title.trim();
        let old_title = match self.graph.note(path)? {
            Some(note) => note.title(path),
            None => return Err(Error::NotRenamable(path.to_owned())),
        };
        let dated = prism_markup::Day::parse(new_title).is_some() || prism_markup::Week::parse(new_title).is_some();
        if dated || Catalog::answering(&db, new_title)?.iter().any(|(other, _)| other != path) {
            return Err(Error::TitleTaken(new_title.to_owned()));
        }
        let renamed = match pointing_at(&db, path, &old_title)? {
            Some(linking) => self.graph.rename_note(path, new_title, &linking)?,
            None => self.graph.retitle(path, new_title)?,
        };
        self.wrote(renamed.rewritten.iter().map(String::as_str));
        Ok(renamed)
    }

    /// Changes one of a page's aliases, and relinks the graph: every
    /// link written with the old alias is written with the new one. In
    /// the answer, the "titles" are the alias before and after.
    pub fn rename_alias(&self, path: &str, alias: &str, new_alias: &str) -> Result<Renamed> {
        self.change_alias(path, alias, Some(new_alias))
    }

    /// Takes one of a page's aliases away, and relinks the graph: every
    /// link written with it is written with the page's title, so none is
    /// left leading nowhere.
    pub fn remove_alias(&self, path: &str, alias: &str) -> Result<Renamed> {
        self.change_alias(path, alias, None)
    }

    fn change_alias(&self, path: &str, alias: &str, to: Option<&str>) -> Result<Renamed> {
        self.settle();
        let db = self.everything()?;
        if let Some(to) = to {
            if Catalog::answering(&db, to)?.iter().any(|(other, _)| other != path) {
                return Err(Error::TitleTaken(to.trim().to_owned()));
            }
        }
        let linking = pointing_at(&db, path, alias)?;
        let Some(now) = self.graph.change_alias(path, alias, to)? else { return Err(Error::NoSuchAlias(alias.to_owned())) };
        let mut renamed = Renamed { old_title: alias.to_owned(), new_title: now.clone(), rewritten: vec![path.to_owned()] };
        if let Some(linking) = linking.filter(|_| prism_markup::name_key(alias) != prism_markup::name_key(&now)) {
            for rewritten in self.graph.relink(alias, &now, &linking)? {
                if !renamed.rewritten.contains(&rewritten) {
                    renamed.rewritten.push(rewritten);
                }
            }
        }
        self.wrote(renamed.rewritten.iter().map(String::as_str));
        Ok(renamed)
    }

    /// Saves a river. See [`Graph::save_river`].
    pub fn save_river(&self, name: &str, river: &prism_markup::River) -> Result<bool> {
        let written = self.graph.save_river(name, river)?;
        if written {
            self.wrote([prism_markup::river::path(name).as_str()]);
        }
        Ok(written)
    }

    /// Runs a query block's body against the indices. `this` is the
    /// title of the page the query is in, for `{this}`. Private pages
    /// are not found: to find them, run it
    /// ([`prism_index::query::run_text`]) on
    /// [`index_showing_private`](Self::index_showing_private).
    pub fn query(&self, body: &str, this: Option<&str>) -> Result<prism_index::QueryResult> {
        Ok(prism_index::query::run_text(&self.index()?, body, &prism_index::QueryOptions { this })?)
    }

    /// What the engine itself wrote: indexed now — those files, and no
    /// others looked at — and synced once writing pauses.
    fn wrote<'a>(&self, paths: impl IntoIterator<Item = &'a str>) {
        let _ = self.indexing.send(IndexCommand::Changed(Some(paths.into_iter().map(str::to_owned).collect())));
    }

    /// These files in the working tree changed, by whatever hand: index
    /// them now, and sync them once writing pauses. For writes made
    /// around the engine by something that knows what it wrote. Paths
    /// are the graph's: `notes/atlas.md`.
    pub fn paths_changed(&self, paths: &[String]) {
        let _ = self.indexing.send(IndexCommand::Changed(Some(paths.to_vec())));
    }

    /// Something in the working tree changed, and nobody knows what:
    /// every file is looked at. Prefer [`paths_changed`](Self::paths_changed)
    /// where the paths are known, or [`watch`](Self::watch).
    pub fn note_changed(&self) {
        let _ = self.indexing.send(IndexCommand::Changed(None));
    }

    // --- Syncing -----------------------------------------------------------

    /// Asks for a full sync — commit, fetch, merge, push — now, or
    /// straight after the cycle that is running. For launch, for coming
    /// to the front, for a pull-to-refresh.
    pub fn sync(&self) {
        let _ = self.syncing.send(SyncCommand::Sync(Mode::Full));
    }

    /// Asks for what is written to be committed and pushed now, rather
    /// than when writing pauses. For going to the background.
    pub fn push(&self) {
        let _ = self.syncing.send(SyncCommand::Sync(Mode::Push));
    }

    /// The remote moved — a relay said so, or a silent push did: sync.
    pub fn remote_changed(&self) {
        self.sync();
    }

    /// A cycle, now, waited for: its report, or why it failed. For a
    /// command line, a test, a background wake that must say when it is
    /// done. What the cycle wrote is indexed by the time this answers.
    pub fn sync_blocking(&self, mode: Mode) -> std::result::Result<Report, SyncFailure> {
        let gone = || SyncFailure { message: "the engine has stopped".into(), will_retry: false, needs_sign_in: false };
        let (answer, outcome) = mpsc::channel();
        self.syncing.send(SyncCommand::SyncNow(mode, answer)).map_err(|_| gone())?;
        outcome.recv().map_err(|_| gone())?
    }

    /// Asks a cycle under way to stop at its next safe point — the
    /// system is taking the app's time back. What it committed stays.
    pub fn stop_sync(&self) {
        self.stop.stop();
    }

    /// Waits until what was written so far is indexed — and, on a first
    /// run, until the graph's history has been read for pages' times. It
    /// does not wait for a sync, running or due.
    pub fn settle(&self) {
        let (answer, done) = mpsc::channel();
        if self.indexing.send(IndexCommand::Settle(answer)).is_ok() {
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
    ///
    /// **Private pages are hidden from it** — from every question asked
    /// of it. For a view that shows them, ask for
    /// [`index_showing_private`](Self::index_showing_private).
    pub fn index(&self) -> Result<prism_index::rusqlite::Connection> {
        Ok(Indexer::reader(&self.index_path)?)
    }

    /// As [`index`](Self::index), with private pages shown: in listings,
    /// search, backlinks, tasks and queries alike.
    pub fn index_showing_private(&self) -> Result<prism_index::rusqlite::Connection> {
        Ok(Indexer::reader_showing_private(&self.index_path)?)
    }

    /// The engine's own view, for what it does to the graph: a rename
    /// must rewrite a private page's links too.
    fn everything(&self) -> Result<prism_index::rusqlite::Connection> {
        self.index_showing_private()
    }

    /// What this device alone keeps about the graph — which rivers are
    /// open, how they are folded: never committed, never synced. See
    /// [`Local`](crate::Local).
    pub fn local(&self) -> &crate::Local {
        &self.local
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
        let (syncing, shared) = (self.syncing.clone(), self.shared.clone());
        let listener = prism_relay::Listener::spawn(
            prism_relay::ListenerConfig::new(relay, repository),
            move || auth.current_token().unwrap_or_else(|| Err("no GitHub token is set up".into())),
            move |event| {
                if !matches!(event, prism_relay::ListenerEvent::Disconnected { .. }) {
                    let _ = syncing.send(SyncCommand::Sync(Mode::Full));
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
    /// [`paths_changed`](Self::paths_changed): indexed at once, synced in
    /// a while. What changed is told as [`Event::IndexUpdated`].
    #[cfg(feature = "watch")]
    pub fn watch(&self) -> Result<()> {
        use notify::Watcher;
        let indexing = self.indexing.clone();
        // Events name files as the system does, links resolved.
        let root = self.graph.root().canonicalize().unwrap_or_else(|_| self.graph.root().to_owned());
        let watched = root.clone();
        let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            let Ok(event) = event else { return };
            if matches!(event.kind, notify::EventKind::Access(_)) {
                return;
            }
            let paths: Vec<String> = event.paths.iter().filter_map(|path| graph_path(&root, path)).collect();
            if !paths.is_empty() {
                let _ = indexing.send(IndexCommand::Changed(Some(paths)));
            }
        })
        .map_err(|e| Error::Watch(e.to_string()))?;
        watcher.watch(&watched, notify::RecursiveMode::Recursive).map_err(|e| Error::Watch(e.to_string()))?;
        if let Ok(mut current) = self.watcher.lock() {
            *current = Some(watcher);
        }
        Ok(())
    }

    /// Stops listening to the relay, if it was.
    #[cfg(feature = "relay")]
    pub fn stop_listening(&self) {
        if let Ok(mut current) = self.listener.lock() {
            current.take();
        }
    }

    /// Tells a relay this phone's push token, for the graph's repository:
    /// a silent push then wakes the app when another device pushes, and
    /// the app answers it with [`remote_changed`](Self::remote_changed).
    /// For a device that cannot hold a socket open. Waits for the relay.
    ///
    /// `push_token` is the token Apple gave the app, in hex; `topic` the
    /// app's bundle identifier; `sandbox` whether the app is signed for
    /// development.
    #[cfg(feature = "relay")]
    pub fn register_phone(&self, relay: &str, push_token: &str, topic: &str, sandbox: bool) -> Result<()> {
        self.tell_relay(relay, push_token, topic, sandbox, true)
    }

    /// Takes this phone's push token back from a relay: on signing out,
    /// or leaving the graph.
    #[cfg(feature = "relay")]
    pub fn unregister_phone(&self, relay: &str, push_token: &str) -> Result<()> {
        self.tell_relay(relay, push_token, "", false, false)
    }

    #[cfg(feature = "relay")]
    fn tell_relay(&self, relay: &str, push_token: &str, topic: &str, sandbox: bool, registering: bool) -> Result<()> {
        use prism_github::http::HttpClient;
        use prism_relay::{apns::Environment, client, relay::Registration};
        let repository = self.remote_url.as_deref().and_then(prism_github::repository_from_remote).ok_or(Error::NotOnGitHub)?;
        let token = self.auth.current_token().unwrap_or_else(|| Err("no GitHub token is set up".into())).map_err(Error::Relay)?;
        let registration = Registration {
            repository,
            token: push_token.to_owned(),
            environment: if sandbox { Environment::Sandbox } else { Environment::Production },
            topic: topic.to_owned(),
        };
        let request =
            if registering { client::register_request(relay, &token, &registration) } else { client::unregister_request(relay, &token, &registration) };
        let answer = prism_github::UreqClient::default().send(request).map_err(Error::Relay)?;
        if (200..300).contains(&answer.status) {
            Ok(())
        } else {
            Err(Error::Relay(format!("answered {}: {}", answer.status, String::from_utf8_lossy(&answer.body).trim())))
        }
    }

    /// Stops the engine: a cycle under way stops at its next safe point,
    /// and the threads end. Dropping the engine does the same.
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
        let _ = self.syncing.send(SyncCommand::Stop);
        let _ = self.indexing.send(IndexCommand::Stop);
        for thread in self.threads.drain(..) {
            let _ = thread.join();
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.shut_down();
    }
}

/// How the indexing thread finds what the working tree now holds.
enum Look {
    /// At every file: at start, and when told something changed without
    /// being told what.
    Whole,
    /// At these files, written since the tree was last indexed.
    Written(Vec<String>),
    /// A sync has run. The working tree is what the sync committed —
    /// which looked at every file itself — but for what was not yet
    /// committed before, and these files, written since.
    Synced(Vec<String>),
}

/// The indexing thread: the only place the indices are written from.
/// Of the repository it reads the working tree and writes objects, and
/// nothing else.
struct IndexWorker {
    repo: Repository,
    indexer: Indexer,
    options: SnapshotOptions,
    shared: Arc<Shared>,
    /// The working tree as it was last indexed: what the next files
    /// written are added to.
    tree: Option<Oid>,
    /// The files in which it differed, then, from what was committed.
    unsaved: Vec<String>,
    syncing: mpsc::Sender<SyncCommand>,
    /// Its own inbox, for the history read apart to answer into.
    indexing: mpsc::Sender<IndexCommand>,
    reading_history: bool,
    /// Those waiting for everything to be done, the history included.
    waiting: Vec<mpsc::Sender<()>>,
}

impl IndexWorker {
    fn run(mut self, inbox: mpsc::Receiver<IndexCommand>) {
        // Written while no engine ran: to be committed like anything else.
        self.reindex(Look::Whole, true);
        while let Ok(command) = inbox.recv() {
            // Everything already asked is taken together: ten saves in a
            // row are indexed once.
            let mut paths: Option<Vec<String>> = Some(Vec::new());
            let (mut changed, mut synced) = (false, Vec::new());
            for command in std::iter::once(command).chain(std::iter::from_fn(|| inbox.try_recv().ok())) {
                match command {
                    IndexCommand::Changed(Some(written)) => {
                        changed = true;
                        if let Some(paths) = &mut paths {
                            paths.extend(written);
                        }
                    }
                    IndexCommand::Changed(None) => {
                        changed = true;
                        paths = None;
                    }
                    IndexCommand::Reindex(done) => synced.push(done),
                    IndexCommand::History(history) => self.take_history(history),
                    IndexCommand::Settle(done) => self.waiting.push(done),
                    IndexCommand::Stop => return,
                }
            }
            match paths {
                // A sync wrote the tree. Whether anything is left to
                // commit is the sync's own to know: it is not told.
                Some(paths) if !synced.is_empty() => self.reindex(Look::Synced(paths), false),
                Some(paths) if changed => self.reindex(Look::Written(paths), true),
                None => self.reindex(Look::Whole, synced.is_empty()),
                Some(_) => {}
            }
            for done in synced {
                let _ = done.send(());
            }
            if !self.reading_history {
                for done in self.waiting.drain(..) {
                    let _ = done.send(());
                }
            }
        }
    }

    /// The working tree as a tree: from the files known to have changed,
    /// where that is enough; else from all of them.
    fn snapshot(&self, look: Look) -> prism_sync::Result<Oid> {
        let from = match look {
            Look::Whole => None,
            Look::Written(paths) => self.tree.map(|tree| (tree, paths)),
            Look::Synced(mut paths) => {
                paths.extend(self.unsaved.iter().cloned());
                self.repo.head_tree()?.map(|committed| (committed, paths))
            }
        };
        if let Some((base, paths)) = from {
            if let Some(snapshot) = self.repo.snapshot_paths(base, &paths, &self.options)? {
                return Ok(snapshot.tree);
            }
        }
        Ok(self.repo.snapshot(&self.options)?.tree)
    }

    /// Brings the indices up to the working tree as it is now. When
    /// asked to, tells the sync if the tree holds something not yet
    /// committed.
    fn reindex(&mut self, look: Look, tell_sync: bool) {
        let as_of = self.shared.cycles.load(std::sync::atomic::Ordering::SeqCst);
        let tree = match self.snapshot(look) {
            Ok(tree) => tree,
            Err(error) => {
                self.shared.emit(Event::IndexFailed(error.to_string()));
                // Unknown: let a sync find out.
                if tell_sync {
                    let _ = self.syncing.send(SyncCommand::Dirty { tree: None, as_of });
                }
                return;
            }
        };
        match self.indexer.update(&self.repo, tree) {
            Ok(update) if update.is_noop() => {}
            Ok(update) => self.shared.emit(Event::IndexUpdated { tree, changed: update.changed }),
            Err(error) => self.shared.emit(Event::IndexFailed(error.to_string())),
        }
        self.tree = Some(tree);
        let head_tree = self.repo.head_tree().ok().flatten();
        let dirty = head_tree != Some(tree);
        if let Err(error) = self.date(head_tree, tree, dirty) {
            self.shared.emit(Event::IndexFailed(error.to_string()));
        }
        // A file touched and left as it was, or a sync's own writing seen
        // by a watcher, asks nothing of the remote.
        if dirty && tell_sync {
            let _ = self.syncing.send(SyncCommand::Dirty { tree: Some(tree), as_of });
        }
    }

    /// Brings pages' times up to date: history's, to the branch's head;
    /// and for what is written but not committed, each file's own.
    fn date(&mut self, head_tree: Option<Oid>, tree: Oid, dirty: bool) -> Result<()> {
        self.read_history()?;
        let mut unsaved = Vec::new();
        self.unsaved.clear();
        if dirty {
            for change in self.repo.changes(head_tree, Some(tree), false)? {
                self.unsaved.push(change.path.clone());
                if change.new.is_none() || prism_markup::NoteKind::of(&change.path).is_none() {
                    continue;
                }
                let written = std::fs::metadata(self.repo.workdir().join(&change.path)).and_then(|meta| meta.modified()).ok();
                let seconds = written.and_then(|time| time.duration_since(SystemTime::UNIX_EPOCH).ok()).map_or(0, |since| since.as_secs() as i64);
                unsaved.push((change.path, seconds));
            }
        }
        self.indexer.set_unsaved(&unsaved)?;
        Ok(())
    }

    /// Brings history's times up to the branch's head. The commits since
    /// the last one seen are read here. A whole history — on a first
    /// run — takes seconds, and is read on a thread of its own, so that
    /// what is written meanwhile goes on being indexed.
    fn read_history(&mut self) -> Result<()> {
        let head = self.repo.head();
        match head {
            Some(head) if self.indexer.times_need_history(&self.repo, head)? => {
                if !self.reading_history {
                    let (repo, answer) = (self.repo.reopen()?, self.indexing.clone());
                    let read = move || {
                        let _ = answer.send(IndexCommand::History(Times::history(&repo, head).map_err(|error| error.to_string())));
                    };
                    std::thread::Builder::new().name("prism-history".into()).spawn(read).map_err(|e| Error::io("starting to read the history", e))?;
                    self.reading_history = true;
                }
            }
            _ => {
                self.indexer.update_times(&self.repo, head)?;
            }
        }
        Ok(())
    }

    /// The history read apart has been read: it is what history says,
    /// brought on to wherever the branch has got to since.
    fn take_history(&mut self, history: std::result::Result<History, String>) {
        self.reading_history = false;
        let taken = match history {
            Ok(history) => self.indexer.set_history(history).map_err(Error::from).and_then(|()| self.read_history()),
            Err(message) => {
                self.shared.emit(Event::IndexFailed(message));
                return;
            }
        };
        match (taken, self.tree) {
            (Ok(()), Some(tree)) => self.shared.emit(Event::IndexUpdated { tree, changed: Vec::new() }),
            (Ok(()), None) => {}
            (Err(error), _) => self.shared.emit(Event::IndexFailed(error.to_string())),
        }
    }
}

/// The syncing thread: the only place commits are made, branches moved
/// and the working tree written from.
struct SyncWorker {
    syncer: Syncer,
    scheduler: Scheduler,
    shared: Arc<Shared>,
    indexing: mpsc::Sender<IndexCommand>,
}

impl SyncWorker {
    fn run(mut self, inbox: mpsc::Receiver<SyncCommand>) {
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
            for command in std::iter::once(command).chain(std::iter::from_fn(|| inbox.try_recv().ok())) {
                match command {
                    // Said on another thread, a moment ago. If a cycle has
                    // run since, it was said of a world that is gone: the
                    // indexing thread is asked to look again, and will say
                    // so afresh if it is still so.
                    SyncCommand::Dirty { tree, as_of } => {
                        if as_of < self.shared.cycles.load(std::sync::atomic::Ordering::SeqCst) {
                            let _ = self.indexing.send(IndexCommand::Changed(Some(Vec::new())));
                        } else if tree.is_none() || self.syncer.repository().head_tree().ok().flatten() != tree {
                            self.scheduler.note_changed(Instant::now());
                        }
                    }
                    SyncCommand::Sync(mode) => self.scheduler.request(mode),
                    SyncCommand::SyncNow(mode, answer) => {
                        self.scheduler.request(mode);
                        let outcome = match self.scheduler.poll(Instant::now()) {
                            Some(mode) => self.cycle(mode),
                            None => Err(SyncFailure { message: "a sync is already running".into(), will_retry: true, needs_sign_in: false }),
                        };
                        let _ = answer.send(outcome);
                    }
                    SyncCommand::Stop => return,
                }
            }
        }
    }

    fn cycle(&mut self, mode: Mode) -> std::result::Result<Report, SyncFailure> {
        self.shared.set_status(Status::Syncing);
        self.shared.emit(Event::SyncStarted(mode));
        let result = self.syncer.sync(mode);
        self.shared.cycles.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        // Whatever the cycle managed, the working tree is what it is
        // now: indexed before anyone is told what changed.
        let (done, indexed) = mpsc::channel();
        if self.indexing.send(IndexCommand::Reindex(done)).is_ok() {
            let _ = indexed.recv();
        }
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
