//! The engine, for an app.

use crate::PrismError;
use prism::index::{rusqlite::Connection, Catalog, Links, NoteRow, Resolved, Search, Tasks};
use prism::markup::{river, FieldKind, NoteKind, River};
use prism::sync::{Auth, Config, Identity, Mode, Report, Schedule};
use prism::{Engine, EngineConfig, Event, Status};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, UNIX_EPOCH};

type Result<T, E = PrismError> = std::result::Result<T, E>;

/// Gives a GitHub token good for a while yet. Asked each time the engine
/// talks to the remote, on the engine's thread: refresh it here.
#[uniffi::export(with_foreign)]
pub trait TokenProvider: Send + Sync {
    fn token(&self) -> Result<String, PrismError>;
}

/// Told what the engine does, as it happens, on a thread of the
/// engine's: hop to the main thread before touching the interface.
#[uniffi::export(with_foreign)]
pub trait EngineObserver: Send + Sync {
    fn on_event(&self, event: EngineEvent);
}

/// How an engine is set up. Every field has a sensible nothing.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct EngineOptions {
    /// This device's name, noted in each commit.
    #[uniffi(default = None)]
    pub device: Option<String>,
    /// Who commits are by; both, or git's own configuration is used.
    #[uniffi(default = None)]
    pub author_name: Option<String>,
    #[uniffi(default = None)]
    pub author_email: Option<String>,
    /// Paths never committed, beyond `.gitignore`.
    #[uniffi(default = [])]
    pub exclude: Vec<String>,
    /// How long writing must pause before it is pushed. Thirty seconds,
    /// unless said.
    #[uniffi(default = None)]
    pub idle_seconds: Option<f64>,
    /// Where the index database is kept; inside `.git`, unless said.
    #[uniffi(default = None)]
    pub index_path: Option<String>,
}

/// What a sync cycle did.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SyncReport {
    /// In words: "committed “Update Atlas”, 2 changes pulled, pushed".
    pub summary: String,
    pub committed: Option<String>,
    pub pulled: u32,
    pub pushed: bool,
    /// Files the cycle wrote in the working tree.
    pub changed: Vec<String>,
    /// Files left with conflict markers, or a conflict copy beside them.
    pub conflicted: Vec<String>,
    /// Files too large to commit.
    pub skipped_large_files: Vec<String>,
    pub seconds: f64,
}

/// Something the engine did, or found out.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum EngineEvent {
    SyncStarted {
        is_full: bool,
    },
    SyncFinished {
        report: SyncReport,
    },
    SyncFailed {
        message: String,
        will_retry: bool,
        needs_sign_in: bool,
    },
    /// A sync wrote these files: what is on screen may be out of date.
    FilesChanged {
        paths: Vec<String>,
    },
    /// The indices took these paths in, whoever wrote them: refresh
    /// backlinks, search results, tasks.
    IndexUpdated {
        paths: Vec<String>,
    },
    IndexFailed {
        message: String,
    },
    RelayConnected,
    RelayPush {
        after: String,
    },
    RelayDisconnected {
        reason: String,
        retry_seconds: f64,
    },
}

/// How syncing stands.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SyncStatus {
    Idle,
    Syncing,
    /// The last cycle went well, at this time (seconds since 1970).
    Synced {
        at: f64,
    },
    Failed {
        message: String,
        will_retry: bool,
        needs_sign_in: bool,
    },
}

/// How a save over a file that may have changed ended.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SaveResult {
    /// What the file holds now: show it, and base the next save on it.
    pub content: String,
    /// Whether the file had changed underneath the draft.
    pub was_merged: bool,
    pub is_conflicted: bool,
}

/// What renaming a page did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RenameResult {
    pub old_title: String,
    pub new_title: String,
    /// Every file rewritten.
    pub rewritten: Vec<String>,
}

/// A page, as the catalog lists it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PageInfo {
    pub path: String,
    pub title: String,
    pub id: Option<String>,
    /// `day`, `week` or `note`.
    pub kind: String,
    pub is_private: bool,
    pub is_wiki: bool,
    pub created: Option<i64>,
    pub modified: Option<i64>,
}

/// What a name leads to.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ResolvedPage {
    pub path: String,
    /// False for a day's or week's page not written yet.
    pub exists: bool,
}

/// A link, seen from the page it leads to — or from the one it is in.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PageLink {
    /// The page the link is written in.
    pub source: String,
    /// The name it links to, as written.
    pub target: String,
    pub is_embed: bool,
    /// The row it is in; empty for one in the frontmatter's `related`.
    pub row: Vec<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SearchHit {
    pub path: String,
    pub title: String,
    /// The text around the match, matched words between `[` and `]`.
    pub snippet: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TaskInfo {
    pub path: String,
    pub row: Vec<u32>,
    pub text: String,
    pub is_done: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TagCount {
    pub tag: String,
    pub pages: u32,
}

/// A name linked to that no page answers to, and how many links want it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WantedPage {
    pub name: String,
    pub links: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PageField {
    pub key: String,
    pub values: Vec<String>,
}

/// What kind of value a typed field holds.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FieldType {
    Text,
    Number,
    Date,
    Link,
    Url,
    Flag,
    Choice { options: Vec<String> },
}

/// A field a tag gives the pages tagged with it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TypedField {
    pub name: String,
    pub kind: FieldType,
}

/// How a query's pages are to be shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum QueryShow {
    List,
    Inline,
    Table,
    Cards,
    Count,
    Tree,
}

/// What a query found.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QueryOutcome {
    pub pages: Vec<PageInfo>,
    /// How many there were before the query's `limit`.
    pub total: u32,
    pub show: QueryShow,
    pub columns: Vec<String>,
}

/// A row folded in a river's card.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RiverFoldedRow {
    pub index: u32,
    pub text: String,
}

/// A card of a saved river.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RiverCard {
    pub title: String,
    pub folded_rows: Vec<RiverFoldedRow>,
    /// For a card placed by hand among what a query finds.
    pub place_rank: Option<i64>,
    pub place_key: Option<String>,
}

/// A saved river.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SavedRiver {
    pub cards: Vec<RiverCard>,
    /// A query river's query: the body of its block.
    pub query: Option<String>,
    pub placed: Vec<RiverCard>,
    pub folded: Vec<String>,
    pub opened: Vec<String>,
    pub hidden: Vec<String>,
    pub icon: Option<String>,
    pub color: Option<String>,
    pub place: Option<f64>,
}

fn page(row: NoteRow) -> PageInfo {
    PageInfo {
        path: row.path,
        title: row.title,
        id: row.id,
        kind: row.kind,
        is_private: row.private,
        is_wiki: row.wiki,
        created: row.created,
        modified: row.modified,
    }
}

fn link(link: prism::index::Backlink) -> PageLink {
    PageLink { source: link.source, target: link.target, is_embed: link.embed, row: link.block.into_iter().map(|i| i as u32).collect() }
}

fn task(task: prism::index::TaskRow) -> TaskInfo {
    TaskInfo { path: task.path, row: task.block.into_iter().map(|i| i as u32).collect(), text: task.text, is_done: task.done }
}

fn typed_field(spec: prism::markup::FieldSpec) -> TypedField {
    let kind = match spec.kind {
        FieldKind::Text => FieldType::Text,
        FieldKind::Number => FieldType::Number,
        FieldKind::Date => FieldType::Date,
        FieldKind::Link => FieldType::Link,
        FieldKind::Url => FieldType::Url,
        FieldKind::Flag => FieldType::Flag,
        FieldKind::Choice(options) => FieldType::Choice { options },
    };
    TypedField { name: spec.name, kind }
}

fn report(report: Report) -> SyncReport {
    SyncReport {
        summary: report.to_string(),
        seconds: report.duration().as_secs_f64(),
        committed: report.committed,
        pulled: report.pulled as u32,
        pushed: report.pushed,
        changed: report.changed,
        conflicted: report.conflicted,
        skipped_large_files: report.skipped_large_files.into_iter().map(|(path, _)| path).collect(),
    }
}

fn event(event: Event) -> EngineEvent {
    match event {
        Event::SyncStarted(mode) => EngineEvent::SyncStarted { is_full: mode == Mode::Full },
        Event::SyncFinished(Ok(done)) => EngineEvent::SyncFinished { report: report(done) },
        Event::SyncFinished(Err(failure)) => {
            EngineEvent::SyncFailed { message: failure.message, will_retry: failure.will_retry, needs_sign_in: failure.needs_sign_in }
        }
        Event::FilesChanged(paths) => EngineEvent::FilesChanged { paths },
        Event::IndexUpdated { changed, .. } => EngineEvent::IndexUpdated { paths: changed },
        Event::IndexFailed(message) => EngineEvent::IndexFailed { message },
        Event::Relay(prism::relay::ListenerEvent::Connected) => EngineEvent::RelayConnected,
        Event::Relay(prism::relay::ListenerEvent::Push { after }) => EngineEvent::RelayPush { after },
        Event::Relay(prism::relay::ListenerEvent::Disconnected { reason, retry_in }) => {
            EngineEvent::RelayDisconnected { reason, retry_seconds: retry_in.as_secs_f64() }
        }
    }
}

fn card(card: &river::Card) -> RiverCard {
    RiverCard {
        title: card.title.clone(),
        folded_rows: card.folded_rows.iter().map(|row| RiverFoldedRow { index: row.index as u32, text: row.text.clone() }).collect(),
        place_rank: card.place.as_ref().map(|(rank, _)| *rank),
        place_key: card.place.as_ref().map(|(_, key)| key.clone()),
    }
}

fn to_card(card: RiverCard) -> river::Card {
    river::Card {
        title: card.title,
        folded_rows: card.folded_rows.into_iter().map(|row| river::FoldedRow { index: row.index as usize, text: row.text }).collect(),
        place: card.place_rank.map(|rank| (rank, card.place_key.unwrap_or_default())),
    }
}

/// A graph, kept synced and indexed in the background.
///
/// Make one per graph, keep it for as long as the graph is open, and
/// drop it to stop. Every method may be called from any thread.
#[derive(uniffi::Object)]
pub struct PrismEngine {
    engine: Engine,
    /// A connection of this object's own to the indices, to answer from.
    index: Mutex<Connection>,
    observer: Arc<Mutex<Option<Arc<dyn EngineObserver>>>>,
}

impl PrismEngine {
    fn make(engine: Engine) -> Result<Arc<PrismEngine>> {
        let index = Mutex::new(engine.index()?);
        let observer: Arc<Mutex<Option<Arc<dyn EngineObserver>>>> = Arc::default();
        // Events are passed on from a thread of their own, which ends
        // when the engine does.
        let (events, current) = (engine.subscribe(), observer.clone());
        std::thread::Builder::new()
            .name("prism-events".into())
            .spawn(move || {
                for engine_event in events {
                    let observer = current.lock().ok().and_then(|observer| observer.clone());
                    if let Some(observer) = observer {
                        observer.on_event(event(engine_event));
                    }
                }
            })
            .map_err(|e| PrismError::Failed(e.to_string()))?;
        Ok(Arc::new(PrismEngine { engine, index, observer }))
    }

    fn db(&self) -> MutexGuard<'_, Connection> {
        self.index.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn config(options: EngineOptions, token: Option<Arc<dyn TokenProvider>>) -> EngineConfig {
        let mut schedule = Schedule::default();
        if let Some(idle) = options.idle_seconds.filter(|s| s.is_finite() && *s >= 0.0) {
            schedule.idle = Duration::from_secs_f64(idle);
        }
        let identity = match (options.author_name, options.author_email) {
            (Some(name), Some(email)) => Some(Identity::new(name, email)),
            _ => None,
        };
        EngineConfig {
            sync: Config { device: options.device, identity, exclude: options.exclude, ..Config::default() },
            schedule,
            auth: match token {
                Some(provider) => Auth::source(move || provider.token().map_err(|e| e.to_string())),
                None => Auth::Default,
            },
            index_path: options.index_path.map(Into::into),
        }
    }
}

#[uniffi::export]
impl PrismEngine {
    /// Opens the graph at `root`, which must be a git repository's
    /// working tree. Its indices are brought up to date at once.
    #[uniffi::constructor(default(token = None))]
    pub fn open(root: String, options: EngineOptions, token: Option<Arc<dyn TokenProvider>>) -> Result<Arc<PrismEngine>> {
        PrismEngine::make(Engine::start(&root, PrismEngine::config(options, token))?)
    }

    /// Clones a repository into `root`, and opens it. Waits for the clone.
    #[uniffi::constructor(default(token = None))]
    pub fn clone_repository(url: String, root: String, options: EngineOptions, token: Option<Arc<dyn TokenProvider>>) -> Result<Arc<PrismEngine>> {
        PrismEngine::make(Engine::clone_from(&url, &root, PrismEngine::config(options, token))?)
    }

    /// Makes a new, empty graph at `root` — a repository with no commits
    /// yet, its remote `origin` at `remote_url` when one is given — and
    /// opens it.
    #[uniffi::constructor(default(remote_url = None, token = None))]
    pub fn create(root: String, remote_url: Option<String>, options: EngineOptions, token: Option<Arc<dyn TokenProvider>>) -> Result<Arc<PrismEngine>> {
        let repo = prism::sync::Repository::init(&root, "main").map_err(prism::Error::from)?;
        if let Some(url) = remote_url {
            repo.set_remote("origin", &url).map_err(prism::Error::from)?;
        }
        drop(repo);
        PrismEngine::make(Engine::start(&root, PrismEngine::config(options, token))?)
    }

    /// Who is told what the engine does; nobody, for `nil`.
    pub fn set_observer(&self, observer: Option<Arc<dyn EngineObserver>>) {
        if let Ok(mut current) = self.observer.lock() {
            *current = observer;
        }
    }

    // --- Files -------------------------------------------------------------

    /// A file's text; nothing when there is no such file.
    pub fn read(&self, path: String) -> Result<Option<String>> {
        Ok(self.engine.graph().read(&path)?)
    }

    /// Writes a file — atomically, and only when it differs — and has it
    /// indexed and, in a while, synced. Says whether anything was written.
    pub fn write(&self, path: String, content: String) -> Result<bool> {
        Ok(self.engine.write(&path, &content)?)
    }

    /// Saves a draft without overwriting what changed underneath it:
    /// `base` is the file as the editor last saw it.
    pub fn save_merging(&self, path: String, draft: String, base: Option<String>) -> Result<SaveResult> {
        let saved = self.engine.save_merging(&path, &draft, base.as_deref())?;
        Ok(SaveResult { content: saved.content, was_merged: saved.merged, is_conflicted: saved.conflicted })
    }

    /// Makes a new note with a title; answers its path. A page already
    /// there is left as it is.
    pub fn create_note(&self, title: String) -> Result<String> {
        Ok(self.engine.create_note(&title)?)
    }

    /// The path a new page of this title would take.
    pub fn path_for_title(&self, title: String) -> String {
        self.engine.graph().path_for_title(&title)
    }

    /// Keeps a file in `assets/` under a readable name, never over
    /// another. Answers the path to link to.
    pub fn add_asset(&self, name: String, content: Vec<u8>) -> Result<String> {
        Ok(self.engine.add_asset(&name, &content)?)
    }

    pub fn delete(&self, path: String) -> Result<bool> {
        Ok(self.engine.delete(&path)?)
    }

    /// Renames a page and relinks the graph: every page that linked to
    /// the old title, and every river that held it, names the new one.
    pub fn rename_note(&self, path: String, new_title: String) -> Result<RenameResult> {
        let renamed = self.engine.rename_note(&path, &new_title)?;
        Ok(RenameResult { old_title: renamed.old_title, new_title: renamed.new_title, rewritten: renamed.rewritten })
    }

    /// Something in the graph's folder changed, by another hand: index
    /// it now, and sync it once writing pauses.
    pub fn note_changed(&self) {
        self.engine.note_changed();
    }

    /// Where a graph-relative path is on disk: for showing a picture.
    pub fn absolute_path(&self, path: String) -> Result<String> {
        Ok(self.engine.graph().locate(&path)?.to_string_lossy().into_owned())
    }

    // --- Sync --------------------------------------------------------------

    /// Asks for a full sync, now: at launch, on coming to the front.
    pub fn sync(&self) {
        self.engine.sync();
    }

    /// Asks for what is written to be pushed now: on going to the background.
    pub fn push(&self) {
        self.engine.push();
    }

    /// The remote moved — a silent push said so: sync.
    pub fn remote_changed(&self) {
        self.engine.remote_changed();
    }

    /// A cycle, now, waited for. For a background wake that must say
    /// when it is done. Call it off the main thread.
    pub fn sync_now(&self, full: bool) -> Result<SyncReport> {
        Ok(report(self.engine.sync_blocking(if full { Mode::Full } else { Mode::Push })?))
    }

    /// Asks a cycle under way to stop at its next safe point: the system
    /// is taking the app's time back.
    pub fn stop_sync(&self) {
        self.engine.stop_sync();
    }

    /// Waits until everything asked so far is done: what was written is
    /// indexed. Call it off the main thread.
    pub fn settle(&self) {
        self.engine.settle();
    }

    pub fn status(&self) -> SyncStatus {
        match self.engine.status() {
            Status::Idle => SyncStatus::Idle,
            Status::Syncing => SyncStatus::Syncing,
            Status::Synced(at) => SyncStatus::Synced { at: at.duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0) },
            Status::Failed(failure) => SyncStatus::Failed { message: failure.message, will_retry: failure.will_retry, needs_sign_in: failure.needs_sign_in },
        }
    }

    /// Where the graph's remote is.
    pub fn remote_url(&self) -> Option<String> {
        self.engine.remote_url().map(str::to_owned)
    }

    /// Listens to a sync relay for pushes to the graph's repository,
    /// which must be on GitHub.
    pub fn listen(&self, relay: String) -> Result<()> {
        Ok(self.engine.listen(&relay)?)
    }

    /// Watches the graph's folder for writes made around the engine.
    pub fn watch(&self) -> Result<()> {
        Ok(self.engine.watch()?)
    }

    // --- Pages -------------------------------------------------------------

    /// What a link's name leads to: a date first, then a title, an
    /// alias, a part of a title. Nothing: a page waiting to be written.
    pub fn resolve(&self, name: String) -> Result<Option<ResolvedPage>> {
        Ok(Catalog::resolve(&self.db(), &name)?
            .map(|resolved| ResolvedPage { exists: matches!(resolved, Resolved::Note(_)), path: resolved.path().to_owned() }))
    }

    pub fn page(&self, path: String) -> Result<Option<PageInfo>> {
        Ok(Catalog::get(&self.db(), &path)?.map(page))
    }

    /// The page with a lasting id, wherever it is now.
    pub fn page_with_id(&self, id: String) -> Result<Option<PageInfo>> {
        Ok(Catalog::by_id(&self.db(), &id)?.map(page))
    }

    /// Every page, by title.
    pub fn all_pages(&self) -> Result<Vec<PageInfo>> {
        Ok(Catalog::all(&self.db())?.into_iter().map(page).collect())
    }

    /// Pages whose title or alias starts with, or has a word starting
    /// with, what was typed: a chooser's first answer.
    pub fn complete(&self, typed: String, limit: u32) -> Result<Vec<PageInfo>> {
        Ok(Catalog::complete(&self.db(), &typed, limit as usize)?.into_iter().map(page).collect())
    }

    /// Every name a page answers to, its title first.
    pub fn names(&self, path: String) -> Result<Vec<String>> {
        Ok(Catalog::names(&self.db(), &path)?)
    }

    /// Every tag, most used first.
    pub fn tags(&self) -> Result<Vec<TagCount>> {
        Ok(Catalog::tags(&self.db())?.into_iter().map(|(tag, pages)| TagCount { tag, pages: pages as u32 }).collect())
    }

    pub fn tags_of(&self, path: String) -> Result<Vec<String>> {
        Ok(Catalog::tags_of(&self.db(), &path)?)
    }

    pub fn tagged(&self, tag: String) -> Result<Vec<PageInfo>> {
        Ok(Catalog::tagged(&self.db(), &tag)?.into_iter().map(page).collect())
    }

    /// A page's frontmatter, as indexed.
    pub fn fields(&self, path: String) -> Result<Vec<PageField>> {
        Ok(Catalog::fields(&self.db(), &path)?.into_iter().map(|(key, values)| PageField { key, values }).collect())
    }

    /// The typed fields a page's tags give it: the form to show for it.
    pub fn schema(&self, path: String) -> Result<Vec<TypedField>> {
        Ok(Catalog::schema(&self.db(), &path)?.into_iter().map(typed_field).collect())
    }

    /// The typed fields a tag gives the pages tagged with it.
    pub fn field_specs(&self, tag: String) -> Result<Vec<TypedField>> {
        Ok(Catalog::field_specs(&self.db(), &tag)?.into_iter().map(typed_field).collect())
    }

    // --- Links, search, tasks ----------------------------------------------

    /// The links to a page, by every name it answers to.
    pub fn backlinks(&self, path: String) -> Result<Vec<PageLink>> {
        let db = self.db();
        let mut names = Catalog::names(&db, &path)?;
        if names.is_empty() {
            // Not written yet, or a day: linked to by what it would be called.
            names.push(NoteKind::fallback_title(&path));
        }
        Ok(Links::backlinks(&db, &names)?.into_iter().map(link).collect())
    }

    /// The links to a name, whether or not a page answers to it.
    pub fn links_to_name(&self, name: String) -> Result<Vec<PageLink>> {
        Ok(Links::backlinks(&self.db(), &[name])?.into_iter().map(link).collect())
    }

    /// The links written in a page.
    pub fn outgoing_links(&self, path: String) -> Result<Vec<PageLink>> {
        Ok(Links::outgoing(&self.db(), &path)?.into_iter().map(link).collect())
    }

    /// Names linked to that no page answers to, most wanted first.
    pub fn wanted_pages(&self) -> Result<Vec<WantedPage>> {
        Ok(Links::unresolved(&self.db())?.into_iter().map(|(name, links)| WantedPage { name, links: links as u32 }).collect())
    }

    /// The pages with every word typed, best first; the last word
    /// matches as a prefix.
    pub fn search(&self, typed: String, limit: u32) -> Result<Vec<SearchHit>> {
        Ok(Search::search(&self.db(), &typed, limit as usize)?
            .into_iter()
            .map(|hit| SearchHit { path: hit.path, title: hit.title, snippet: hit.snippet })
            .collect())
    }

    pub fn open_tasks(&self) -> Result<Vec<TaskInfo>> {
        Ok(Tasks::open(&self.db())?.into_iter().map(task).collect())
    }

    pub fn tasks_in(&self, path: String) -> Result<Vec<TaskInfo>> {
        Ok(Tasks::in_note(&self.db(), &path)?.into_iter().map(task).collect())
    }

    /// Runs a query block's body. `this` is the title of the page the
    /// query is in, for `{this}`.
    pub fn run_query(&self, body: String, this: Option<String>) -> Result<QueryOutcome> {
        use prism::index::Show;
        let options = prism::index::QueryOptions { this: this.as_deref(), include_private: false };
        let found = prism::index::query::run_text(&self.db(), &body, &options)?;
        Ok(QueryOutcome {
            total: found.total as u32,
            show: match found.show {
                Show::List => QueryShow::List,
                Show::Inline => QueryShow::Inline,
                Show::Table => QueryShow::Table,
                Show::Cards => QueryShow::Cards,
                Show::Count => QueryShow::Count,
                Show::Tree => QueryShow::Tree,
            },
            columns: found.columns,
            pages: found.pages.into_iter().map(page).collect(),
        })
    }

    // --- Rivers ------------------------------------------------------------

    /// The graph's saved rivers, by name.
    pub fn river_names(&self) -> Vec<String> {
        self.engine.graph().river_names()
    }

    pub fn river(&self, name: String) -> Result<Option<SavedRiver>> {
        Ok(self.engine.graph().river(&name)?.map(|river| SavedRiver {
            cards: river.cards.iter().map(card).collect(),
            query: river.query.as_ref().map(ToString::to_string),
            placed: river.placed.iter().map(card).collect(),
            folded: river.folded,
            opened: river.opened,
            hidden: river.hidden,
            icon: river.icon,
            color: river.color,
            place: river.place,
        }))
    }

    /// Saves a river under a name. Says whether its file changed.
    pub fn save_river(&self, name: String, river: SavedRiver) -> Result<bool> {
        let river = River {
            cards: river.cards.into_iter().map(to_card).collect(),
            query: river.query.map(|body| prism::markup::Query::parse(&body)),
            placed: river.placed.into_iter().map(to_card).collect(),
            folded: river.folded,
            opened: river.opened,
            hidden: river.hidden,
            icon: river.icon,
            color: river.color,
            place: river.place,
        };
        Ok(self.engine.save_river(&name, &river)?)
    }

    pub fn delete_river(&self, name: String) -> Result<bool> {
        Ok(self.engine.delete(&river::path(&name))?)
    }
}
