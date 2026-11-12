import Foundation
import Observation
import Prism
import PrismDictation
import PrismEditor
import PrismEmblem

/// A graph, as the app holds it: the engine, and what of it is on screen.
///
/// The store keeps nothing the engine can tell it. Pages, links, search,
/// tasks, sync — all are asked of the engine when a view needs them; what
/// is here is only what is *open*: the drafts being written, the rivers
/// and their cards. Views redraw on two counters, which the engine's
/// events move: `indexRevision` (anything derived may differ) and each
/// draft's own text.
@MainActor
@Observable
public final class GraphStore {
    public let engine: PrismEngine
    public let root: URL

    /// Moves whenever the indices were brought up to date: what a view of
    /// backlinks, search, tasks or a query redraws on.
    public private(set) var indexRevision = 0
    public private(set) var sync: SyncStatus = .idle
    /// The last thing a sync said, for the sidebar's foot.
    public private(set) var syncNote: String?
    /// Whether the relay is being listened to: whether another device's
    /// writing comes in as it is pushed, or at the next sync.
    public enum RelayState: Equatable { case off, connecting, listening, waiting(String) }
    public private(set) var relay: RelayState = .off
    /// The last sync was turned away for want of a sign-in.
    public private(set) var needsSignIn = false
    public private(set) var pageCount = 0
    public private(set) var conflicted: [PageInfo] = []

    /// One draft a page, however many rivers show it.
    @ObservationIgnored private var drafts: [String: PageDraft] = [:]
    /// What names lead to, kept until the index next moves.
    @ObservationIgnored private var resolved: [String: ResolvedPage?] = [:]
    @ObservationIgnored private var labels: [String: String?] = [:]
    /// What a card last measured, and what stood at its foot: so that a
    /// card scrolled back into view comes as it was, at its full height,
    /// and the river does not shift under the finger while it finds out
    /// again. Never shown from: only where a card starts.
    @ObservationIgnored var cardHeights: [String: CGFloat] = [:]
    @ObservationIgnored var cardFeet: [String: Any] = [:]
    @ObservationIgnored private var observer: Observer?

    public var rivers: [River] = []
    public var currentRiver = 0

    /// What pages were given to be shown by — `icon:` and `color:` in
    /// their frontmatter — by path: read off the index in one go, so that
    /// a list of any length draws each row's emblem without a read a row.
    public private(set) var icons: [String: String] = [:]
    public private(set) var colors: [String: String] = [:]
    /// The rivers saved in the graph, as the sidebar lists them.
    public private(set) var savedRivers: [SavedRiverInfo] = []

    /// How this app has the engine run.
    public static var options: EngineOptions { EngineOptions(device: Host.deviceName, authorName: nil, authorEmail: nil, exclude: [], idleSeconds: nil, indexPath: nil) }

    /// Opens the graph in a folder. With a `token`, it syncs as that
    /// GitHub account; with a `relay` too, it listens there, and syncs
    /// the moment another device pushes.
    public init(root: URL, token: TokenProvider? = nil, relay host: String? = nil) throws {
        self.root = root
        let options = Self.options
        // A folder that is no repository yet becomes one: a graph can start anywhere.
        let isRepository = FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
        engine = isRepository ? try PrismEngine.open(root: root.path, options: options, token: token) : try PrismEngine.create(root: root.path, remoteUrl: nil, options: options, token: token)
        let observer = Observer(store: self)
        self.observer = observer
        engine.setObserver(observer: observer)
        engine.settle()
        refreshCounts()
        restoreRivers()
        try? engine.watch()
        note("account", "Opened \(root.path) — remote \(engine.remoteUrl() ?? "none") — \(token == nil ? "no GitHub token: syncing as git would unasked" : "syncing with a GitHub token")")
        // A graph kept on GitHub, signed in to: hear of each push to it.
        relayHost = host
        if token != nil, let host {
            do {
                try engine.listen(relay: host)
                relay = .connecting
                note("relay", "Listening to \(host)")
            } catch {
                note("relay", "Not listening to \(host): \(error)")
            }
        } else {
            note("relay", host == nil ? "No relay in this build" : "Not listening to the relay: not signed in")
        }
        if !Days.isHeadless { pollForChanges() }
        setUpDictation(token: token, relay: host)
    }

    // MARK: - Dictation

    /// Words said are written down by ElevenLabs, through the relay — which
    /// keeps the key, and hands out a token for each dictation to whoever
    /// is signed in and allowed — or, with no relay or no token, by Apple's
    /// own recognition. What is favoured: the names of notes lately written.
    private func setUpDictation(token: TokenProvider?, relay host: String?) {
        Dictation.log = { [weak self] words in self?.note("dictation", words) }
        NoteDictation.keyterms = { [weak self] in self?.dictationTerms() ?? [] }
        guard let token, let host, !Days.isHeadless else {
            Dictation.scribeToken = nil
            return
        }
        Dictation.scribeToken = {
            // The account's token is asked for off the main thread: it may be renewed on the way.
            let github = try await Task.detached { try token.token() }.value
            var request = URLRequest(url: URL(string: host.contains("://") ? "\(host)/scribe-token" : "https://\(host)/scribe-token")!, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("Bearer \(github)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), let given = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String, !given.isEmpty else {
                throw DictationRefused(said: "The relay answered \(status): \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return given
        }
        // One ready ahead of time, so that the first words go straight to it.
        Dictation.prepare()
    }

    private struct DictationRefused: LocalizedError {
        var said: String
        var errorDescription: String? { said }
    }

    /// The names dictation should know: of the notes pinned, and those written in lately.
    func dictationTerms() -> [String] {
        let pages = ((try? engine.runQuery(body: "is: pinned\nsort: pinned", this: nil).pages) ?? []) + ((try? engine.runQuery(body: "sort: -modified\nlimit: 80", this: nil).pages) ?? [])
        return Dictation.terms(from: pages.filter { !$0.path.hasPrefix("daily/") && !$0.path.hasPrefix("weekly/") && !$0.isUntitled }.map(\.label))
    }

    /// Takes a card away with its note, quietly: one made a moment ago, and nothing put in it.
    func discard(_ id: Card.ID, in river: River) {
        guard let card = river.card(id) else { return }
        river.close(id)
        _ = try? engine.delete(path: card.path)
        forget(path: card.path)
        rememberRivers()
    }

    /// Lets go of the graph: before it is opened again, as another account.
    public func close() {
        polling?.cancel()
        readingPictures?.cancel()
        saveAll()
        engine.stopListening()
        relay = .off
    }

    // MARK: - What the engine says

    private final class Observer: EngineObserver, @unchecked Sendable {
        weak var store: GraphStore?
        init(store: GraphStore) { self.store = store }
        func onEvent(event: EngineEvent) {
            Task { @MainActor [weak store] in store?.heard(event) }
        }
    }

    private func heard(_ event: EngineEvent) {
        switch event {
        case .indexUpdated(let paths):
            resolved.removeAll(keepingCapacity: true)
            labels.removeAll(keepingCapacity: true)
            indexRevision += 1
            refreshCounts()
            // A file written by another hand: a draft with nothing unsaved takes it.
            for path in paths { drafts[path]?.fileChanged() }
            riversChanged(in: paths)
            note("index", "Indexed \(paths.count) \(paths.count == 1 ? "file" : "files")\(Self.some(paths))")
        case .filesChanged(let paths):
            for path in paths { drafts[path]?.fileChanged() }
            riversChanged(in: paths)
            note("sync", "A sync wrote \(paths.count) \(paths.count == 1 ? "file" : "files")\(Self.some(paths))")
        case .syncStarted(let isFull):
            sync = .syncing
            note("sync", isFull ? "Sync started (fetch, merge, push)" : "Sync started (push only)")
        case .syncFinished(let report):
            sync = engine.status()
            syncNote = report.summary
            needsSignIn = false
            lastSync = Date()
            lastReport = report
            syncEnded(pulled: report.pulled > 0)
            var said = "Sync finished in \(String(format: "%.1f", report.seconds)) s: \(report.summary)"
            said += " — pulled \(report.pulled), \(report.pushed ? "pushed" : "nothing to push")"
            if let commit = report.committed { said += ", committed \(commit.prefix(8))" }
            if !report.conflicted.isEmpty { said += ", \(report.conflicted.count) in conflict" }
            note("sync", said)
        case .syncFailed(let message, let willRetry, let needsSignIn):
            sync = engine.status()
            syncNote = message
            self.needsSignIn = needsSignIn
            syncEnded(pulled: false)
            note("sync", "Sync FAILED: \(message)\(needsSignIn ? " — needs sign-in" : "")\(willRetry ? " — will retry" : "")")
        case .indexFailed(let message):
            note("index", "Indexing FAILED: \(message)")
        case .relayConnected:
            relay = .listening
            note("relay", "Relay connected: listening for pushes")
        case .relayPush(let after):
            relay = .listening
            lastPush = Date()
            note("relay", "Relay says the repository was pushed to (now at \(after.prefix(8))): syncing")
        case .relayDisconnected(let reason, let retry):
            relay = .waiting(reason)
            note("relay", "Relay disconnected: \(reason) — trying again in \(Int(retry)) s")
        default:
            break
        }
    }

    /// What the last sync that finished did.
    public private(set) var lastReport: SyncReport?
    @ObservationIgnored private var waiting: [CheckedContinuation<Bool, Never>] = []

    private func syncEnded(pulled: Bool) {
        let told = waiting
        waiting = []
        for one in told { one.resume(returning: pulled) }
    }

    /// Syncs, and waits for it: whether anything came in. For pulling to
    /// refresh, and for a push that woke the app and must say when it is done.
    public func syncAndWait(seconds: Double = 25) async -> Bool {
        saveAll()
        engine.sync()
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                // Not heard from in time: said to have brought nothing.
                self?.syncEnded(pulled: false)
            }
        }
    }

    /// A few of some paths, for a line of the log.
    private static func some(_ paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        return ": " + paths.prefix(3).joined(separator: ", ") + (paths.count > 3 ? ", …" : "")
    }

    /// Files changed, by a sync or another hand: the open rivers among them are read again.
    private func riversChanged(in paths: [String]) {
        let names = Set(paths.compactMap(Self.riverName))
        if !names.isEmpty { readRivers(named: names) }
    }

    // MARK: - What happened, for whoever needs to know why

    /// A line of the diagnostics log.
    public struct LogLine: Identifiable {
        public let id: Int
        public let at: Date
        /// `sync`, `relay`, `index`, `river`, `account`.
        public let kind: String
        public let text: String
    }

    /// What the engine and the app have done, newest last: the last few hundred.
    public private(set) var log: [LogLine] = []
    public private(set) var lastSync: Date?
    public private(set) var lastPush: Date?
    @ObservationIgnored private var logged = 0

    public func note(_ kind: String, _ text: String) {
        logged += 1
        log.append(LogLine(id: logged, at: Date(), kind: kind, text: text))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    /// Where the graph's remote is, if it has one.
    public var remote: String? { engine.remoteUrl() }

    /// Stops listening to the relay and starts again: for when it seems stuck.
    public func reconnectRelay() {
        guard let host = relayHost else { return }
        engine.stopListening()
        do {
            try engine.listen(relay: host)
            relay = .connecting
            note("relay", "Reconnecting to \(host)")
        } catch {
            relay = .off
            note("relay", "Could not listen to \(host): \(error)")
        }
    }

    @ObservationIgnored public private(set) var relayHost: String?
    @ObservationIgnored private var polling: Task<Void, Never>?

    /// Asks for a sync every so often, whatever else does: the relay says
    /// when another device pushes, but only once GitHub has been told to
    /// tell it — and a socket can be open and hear nothing.
    private func pollForChanges() {
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.relay == .listening ? 300 : 60))
                guard let self, !Task.isCancelled else { return }
                if !self.isSyncing { self.engine.sync() }
            }
        }
    }

    /// The reading of pictures' words, while it goes on.
    private var readingPictures: Task<Void, Never>?

    /// Has the pictures not yet read read, in the background: so that
    /// search finds a page by what its pictures say.
    private func readPictures() {
        guard !Days.isHeadless, readingPictures == nil else { return }
        let (engine, root) = (engine, root)
        readingPictures = Task { [weak self] in
            let count = await Task.detached(priority: .utility) { await PictureWords.readAll(engine: engine, root: root) }.value
            guard let self else { return }
            if count > 0 { self.note("pictures", "Read the words in \(count) picture\(count == 1 ? "" : "s")") }
            self.readingPictures = nil
        }
    }

    private func refreshCounts() {
        readPictures()
        pageCount = (try? engine.allPages().count) ?? pageCount
        conflicted = (try? engine.conflictedPages()) ?? []
        icons = (try? engine.fieldValues(key: "icon")) ?? icons
        colors = (try? engine.fieldValues(key: "color")) ?? colors
        savedRivers = engine.riverNames().map { name in
            let river = (try? engine.river(name: name)) ?? nil
            var titles = (river?.cards.prefix(6).map(\.title)) ?? []
            var count = river?.cards.count ?? 0
            // A query river is shown by what it finds.
            if let query = river?.query, let outcome = try? engine.runQuery(body: Self.limited(query, to: 6), this: nil) {
                titles += outcome.pages.map(\.title).filter { !titles.contains($0) }
                count = max(count, Int(outcome.total))
            }
            return SavedRiverInfo(name: name, icon: river?.icon, color: river?.color, cards: count, titles: Array(titles.prefix(6)), isQuery: river?.query != nil)
        }
    }

    // MARK: - Emblems

    /// What stands for a page wherever it is shown small: its icon, or a
    /// letter of its title, in its colour. The rule is PrismEmblem's; all
    /// this adds is where a page's icon and colour are found.
    public func emblem(path: String, title: String) -> Emblem {
        // A river is shown by its own icon, or a letter of its name.
        if let name = Self.riverName(path) { return savedRivers.first(where: { $0.name == name })?.emblem ?? Emblem(title: name) }
        let kind: String? = path.hasPrefix("daily/") || path.hasPrefix("weekly/") ? "calendar" : nil
        // A note is given no letter: with no icon of its own, it has none.
        return Emblem(title: title, icon: icons[path], color: colors[path], kindSymbol: kind, letter: false)
    }

    /// What a note is shown as called: its title, or — never given one —
    /// its first words, as the engine's index has them.
    public func label(path: String, title: String) -> String {
        if let open = drafts[path] { return open.label }
        return ((try? engine.page(path: path)) ?? nil)?.label ?? Days.shown(title)
    }

    /// The day or the week a few words ask for — "today", "last tuesday",
    /// "next week", "Jan 3" — by the name of its page, and said in full.
    /// The engine reads the words; today is the day it is here.
    public func spoken(_ typed: String) -> (name: String, said: String)? {
        guard let name = spokenDate(text: typed, today: Days.name(Date())) else { return nil }
        return (name, Self.said(name))
    }

    /// A day's or a week's page, said in full: "Wednesday, November 11, 2026"; "Week 47, 2026".
    static func said(_ name: String) -> String {
        let read = DateFormatter()
        read.calendar = Calendar(identifier: .gregorian)
        read.locale = Locale(identifier: "en_US_POSIX")
        read.dateFormat = "yyyy-MM-dd"
        if let day = read.date(from: name) { return day.formatted(date: .complete, time: .omitted) }
        let parts = name.split(separator: "-")
        if parts.count == 2, parts[1].hasPrefix("W"), let week = Int(parts[1].dropFirst()) { return "Week \(week), \(parts[0])" }
        return name
    }

    /// The pages offered for a link being typed: those whose names match
    /// what was typed, then those that say it, then a river or two — and,
    /// when nothing is called just that, a new note of that name.
    public func linkOffers(_ typed: String, this: String? = nil) -> [EditorOffer] {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        func offer(_ page: PageInfo, detail: String? = nil, found: Bool = false) -> EditorOffer {
            let symbol = found ? "text.magnifyingglass" : (emblem(page).symbol ?? "doc.text")
            return EditorOffer(name: Prism.linkName(path: page.path) ?? page.title, title: Self.shown(page), detail: detail, symbol: symbol)
        }
        // Nothing typed yet: what was written last.
        guard !typed.isEmpty else {
            return ((try? engine.runQuery(body: "sort: -modified\nlimit: 7", this: nil).pages) ?? []).filter { $0.path != this }.map { offer($0) }
        }
        var offers: [EditorOffer] = []
        var seen = Set<String>()
        if let this { seen.insert(this) }
        // A day or a week asked for in words: first, as what was meant.
        if let when = spoken(typed) {
            offers.append(EditorOffer(name: when.name, title: when.said, detail: when.name, symbol: "calendar"))
            if let page = resolve(when.name) { seen.insert(page.path) }
        }
        let named = (try? engine.complete(typed: typed, limit: 6)) ?? []
        // Notes of one title are told apart by their files' names.
        let shared = sharedLabels(among: named)
        for page in named where seen.insert(page.path).inserted {
            offers.append(offer(page, detail: shared.contains(page.label) ? Prism.linkName(path: page.path) : nil))
        }
        for hit in (try? engine.search(typed: typed, limit: 8)) ?? [] where seen.insert(hit.path).inserted && offers.count < 7 {
            guard let page = (try? engine.page(path: hit.path)) ?? nil else { continue }
            offers.append(offer(page, detail: hit.snippet.replacingOccurrences(of: "\n", with: " "), found: true))
        }
        let key = nameKey(name: typed)
        for river in savedRivers.filter({ nameKey(name: $0.name).contains(key) }).prefix(2) {
            offers.append(EditorOffer(name: river.name, title: river.name, detail: "River", symbol: river.icon ?? "square.stack"))
        }
        if !leadsSomewhere(typed) { offers.append(EditorOffer(name: typed, title: "New note “\(typed)”", symbol: "plus")) }
        return offers
    }

    /// The labels more than one of these pages is shown by: what a list
    /// must say more about, for its rows to be told apart.
    func sharedLabels(among pages: [PageInfo]) -> Set<String> {
        var once = Set<String>()
        var shared = Set<String>()
        for page in pages where !once.insert(page.label).inserted { shared.insert(page.label) }
        return shared
    }

    /// What a page is shown as called in a list: a day by its date in full.
    static func shown(_ page: PageInfo) -> String {
        guard page.kind == "day" else { return page.label }
        let read = DateFormatter()
        read.locale = Locale(identifier: "en_US_POSIX")
        read.dateFormat = "yyyy-MM-dd"
        guard let day = read.date(from: page.title) else { return page.label }
        return day.formatted(date: .complete, time: .omitted)
    }

    /// What a river is called on its tab: its name — or, having none,
    /// what its first card is shown as called.
    public func title(of river: River) -> String {
        river.name ?? river.cards.first.map { label(path: $0.path, title: $0.title) } ?? "New River"
    }

    /// A note was given another title: the cards of it say so.
    func retitled(path: String, to title: String) {
        for river in rivers {
            for index in river.cards.indices where river.cards[index].path == path { river.cards[index].title = title }
            river.retitled(path: path, to: title)
        }
        rememberRivers()
    }

    /// The river a file is, if it is one: `rivers/On Deck.md` is On Deck.
    static func riverName(_ path: String) -> String? {
        path.hasPrefix("rivers/") && path.hasSuffix(".md") ? String(path.dropFirst(7).dropLast(3)) : nil
    }

    /// The saved river a name leads to, when no note answers to it.
    func riverNamed(_ name: String) -> String? {
        let key = nameKey(name: name)
        return savedRivers.first(where: { nameKey(name: $0.name) == key })?.name
    }

    /// Whether a link's name leads anywhere: to a note, or to a river.
    public func leadsSomewhere(_ name: String) -> Bool {
        resolve(name)?.exists == true || riverNamed(name) != nil
    }

    public func emblem(_ page: PageInfo) -> Emblem { emblem(path: page.path, title: page.title) }

    /// A page's icon or colour was just chosen: shown at once, everywhere,
    /// ahead of the index hearing of it.
    func styled(path: String, icon: String?, color: String?) {
        icons[path] = icon
        colors[path] = color
    }

    // MARK: - Names and pages

    /// What a link's name leads to; `nil` for a page waiting to be written.
    public func resolve(_ name: String) -> ResolvedPage? {
        // As it is written: a file's own name, written exactly, is that file.
        let key = name.trimmingCharacters(in: .whitespaces)
        if let known = resolved[key] { return known }
        let found = try? engine.resolve(name: name)
        resolved[key] = .some(found)
        return found
    }

    /// What a link to a page is written with: its file's name, which is
    /// its own — two notes may have one title, and a title may change. A
    /// page not written yet has no file, and is linked to by its title.
    public func linkName(path: String, title: String) -> String {
        let there = drafts[path]?.exists ?? (((try? engine.page(path: path)) ?? nil) != nil)
        return there ? (Prism.linkName(path: path) ?? title) : title
    }

    func name(of card: Card) -> String { linkName(path: card.path, title: card.title) }

    /// The path a name in a river's file leads to — or, for a page not
    /// written yet, where it would be kept.
    private func path(named name: String) -> String {
        resolve(name)?.path ?? engine.pathForTitle(title: name)
    }

    /// A name as rivers keep it: the own name of the page it leads to. A
    /// river written before pages had their own names says titles.
    private func ownName(_ name: String) -> String {
        guard let found = resolve(name), found.exists else { return name }
        return Prism.linkName(path: found.path) ?? name
    }

    /// The icon the page a link leads to was given, if it was given one.
    public func linkIcon(_ name: String) -> String? {
        guard let found = resolve(name), found.exists else { return nil }
        return icons[found.path]
    }

    /// A row's words as a title shows them: as they read (`plain`), each
    /// page linked in them (`written`, the row's Markdown) called what a
    /// link to it shows — its title, or a day's date as it is read.
    public func titled(_ plain: String, written: String) -> String {
        var shown = plain
        guard written.contains("[["), let links = try? NSRegularExpression(pattern: #"\[\[([^\[\]|]+)\]\]"#) else { return shown }
        let text = written as NSString
        for match in links.matches(in: written, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1))
            if let label = linkLabel(name) { shown = shown.replacingOccurrences(of: name, with: label) }
        }
        return shown
    }

    /// What a link shows, where it is written with something other than
    /// what its page is called: the page's title, or its first words.
    public func linkLabel(_ name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespaces)
        if let known = labels[key] { return known }
        var label: String?
        // A day or a week, written or not, reads as its date does.
        if let dated = dateTitle(name: key) {
            label = dated
        } else if let found = resolve(name), found.exists {
            let shown = self.label(path: found.path, title: name)
            if shown != key { label = shown }
        }
        labels[key] = .some(label)
        return label
    }

    /// The draft of a page: the one every card of it writes in.
    public func draft(path: String, title: String) -> PageDraft {
        if let open = drafts[path] { return open }
        let draft = PageDraft(store: self, path: path, title: title)
        drafts[path] = draft
        return draft
    }

    /// The draft of a page, if one is open: nothing is read to answer.
    func openDraft(path: String) -> PageDraft? { drafts[path] }

    /// Writes everything not yet written: before a sync, before quitting.
    public func saveAll() {
        for draft in drafts.values { draft.saveNow() }
    }

    func forget(path: String) {
        drafts[path] = nil
    }

    // MARK: - Rivers

    public var river: River {
        if rivers.isEmpty { rivers = [River()] }
        currentRiver = min(max(currentRiver, 0), rivers.count - 1)
        return rivers[currentRiver]
    }

    /// Opens the page a name leads to in the river, after a card if one is given.
    public func open(name: String, after card: Card.ID? = nil, in river: River? = nil) {
        let target = resolve(name)
        // A river's name leads to the river — never to the file it is kept in.
        if target?.exists != true, let saved = riverNamed(name) { return openSaved(saved) }
        let river = river ?? self.river
        let path = target?.path ?? engine.pathForTitle(title: name)
        let title = target.flatMap { $0.exists ? (try? engine.page(path: $0.path))??.title : nil } ?? name
        river.open(Card(path: path, title: title), after: card)
        rememberRivers()
    }

    public func open(page: PageInfo, after card: Card.ID? = nil) {
        show(path: page.path, title: page.title, after: card)
    }

    /// Shows what a path is: a note as a card in the river — and a river
    /// as the river it is, never as the file it is kept in.
    public func show(path: String, title: String, after card: Card.ID? = nil, in river: River? = nil) {
        if let name = Self.riverName(path) { return openSaved(name) }
        (river ?? self.river).open(Card(path: path, title: title), after: card)
        rememberRivers()
    }

    /// Makes a note with no title — it is called by its first words —
    /// and opens it to be written in.
    @discardableResult
    public func newNote(saying words: String? = nil, written: String? = nil) -> Card? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        let tail = String((0..<4).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement() ?? "x" })
        let name = "untitled-\(format.string(from: Date()))-\(tail)"
        let path = "notes/\(name).md"
        // Words given it — dictated — are its first row, and it is not opened to be written in.
        let said = words.map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        // Or it is written already — pasted — and is as it was written.
        guard (try? engine.write(path: path, content: written ?? said.map { "- \($0)\n" } ?? "")) != nil else { return nil }
        let card = Card(path: path, title: name)
        river.open(card, after: river.selected)
        if said == nil, written == nil { river.writing = card.id }
        rememberRivers()
        return card
    }

    /// Back to a place the river was at before: its card shown — opened
    /// again, if it was closed since.
    public func goBack(to place: River.Place, in river: River) {
        river.goBack(to: place)
        rememberRivers()
    }

    public func newRiver() {
        rivers.append(River())
        currentRiver = rivers.count - 1
        rememberRivers()
    }

    // MARK: - Saved rivers

    /// Writes a named river into the graph, as `rivers/<name>.md`: what
    /// makes it a saved river, on every device. What the file holds that
    /// this app does not show — a query, cards placed by hand — is kept.
    public func save(_ river: River) {
        guard let name = river.name else { return }
        // Written only when it was changed here. A river as it was read
        // is never written back: that would undo what another device has
        // since done to it.
        guard known[river.id] != river.signature else { return }
        defer { known[river.id] = river.signature }
        note("river", "Saved river “\(name)” (\(river.cards.count) cards)")
        var saved = ((try? engine.river(name: name)) ?? nil) ?? SavedRiver(cards: [], query: nil, placed: [], folded: [], opened: [], hidden: [], icon: nil, color: nil, place: nil)
        // Cards are kept by their pages' own names; what the file said of each is found by where its name leads.
        let known = Dictionary(saved.cards.map { (path(named: $0.title), $0) }, uniquingKeysWith: { first, _ in first })
        saved.cards = river.cards.map { RiverCard(title: self.name(of: $0), focus: $0.focus, foldedRows: $0.foldedRows, placeRank: known[$0.path]?.placeRank, placeKey: known[$0.path]?.placeKey) }
        saved.folded = river.cards.filter(\.folded).map { self.name(of: $0) }
        saved.icon = river.icon
        saved.color = river.color
        saved.query = river.query
        if river.query != nil {
            saved.hidden = river.hidden
            saved.opened = river.opened.sorted()
        }
        if (try? engine.saveRiver(name: name, river: saved)) == true { refreshSaved(name: name, river: river) }
    }

    /// Each named river as the graph and this app last agreed it: what
    /// tells a change made here from one made on another device.
    @ObservationIgnored private var known: [UUID: River.Signature] = [:]

    /// Whether a river holds what is no longer there: a note never given
    /// a title, since deleted. A title with no note is a note to be
    /// written; a file's name with no file is nothing, and is not shown.
    /// The same, of a path. The file itself is asked, not the index:
    /// a note just made is there before it is indexed.
    private func isGone(path: String) -> Bool {
        NoteEditor.open(source: "", mode: .outline).isUntitled(path: path) && ((try? engine.read(path: path)) ?? nil) == nil
    }

    /// What a card is called until its note is read: the page's title —
    /// or, for a page not written yet, the name it was linked by.
    private func title(of path: String, named name: String) -> String {
        ((try? engine.page(path: path)) ?? nil)?.title ?? name
    }

    /// Makes a river what its file says: its cards, in order, and how it
    /// looks and what it asks. A card of a note already open keeps its
    /// identity, so nothing jumps.
    private func adopt(_ saved: SavedRiver, into river: River) {
        var open = Dictionary(river.cards.map { ($0.spot, $0) }, uniquingKeysWith: { first, _ in first })
        let folded = Set(saved.folded.map { path(named: $0) })
        river.cards = saved.cards.compactMap { held in
            let path = path(named: held.title)
            guard !isGone(path: path) else { return nil }
            // A page may have several cards, each of a row of its own: each is found by both.
            var card = open.removeValue(forKey: Card.spot(path: path, focus: held.focus)) ?? Card(path: path, title: title(of: path, named: held.title), focus: held.focus)
            card.folded = folded.contains(path)
            card.foldedRows = held.foldedRows
            return card
        }
        river.icon = saved.icon
        river.color = saved.color
        river.query = saved.query
        river.hidden = saved.hidden.map(ownName)
        river.opened = Set(saved.opened.map(ownName))
        if let selected = river.selected, river.card(selected) == nil { river.selected = nil }
        known[river.id] = river.signature
        if river.query != nil { find(for: river) }
    }

    /// The open rivers that are saved, read again from their files: at
    /// launch, and whenever a sync or another hand changes one. `names`
    /// limits it to those rivers; nil reads them all.
    private func readRivers(named names: Set<String>? = nil) {
        for river in rivers {
            guard let name = river.name, names?.contains(name) ?? true else { continue }
            guard let saved = (try? engine.river(name: name)) ?? nil else {
                // Its file is gone — deleted on another device: the tab stays, unsaved.
                if known[river.id] != nil {
                    known[river.id] = nil
                    river.name = nil
                    note("river", "River “\(name)” was deleted elsewhere; its tab is kept, unsaved")
                }
                continue
            }
            let before = river.signature
            adopt(saved, into: river)
            if river.signature != before { note("river", "Took river “\(name)” from its file (\(river.cards.count) cards)") }
        }
    }

    private func refreshSaved(name: String, river: River) {
        let info = SavedRiverInfo(name: name, icon: river.icon, color: river.color, cards: river.cards.count, titles: river.cards.prefix(6).map(\.title))
        if let index = savedRivers.firstIndex(where: { $0.name == name }) { savedRivers[index] = info } else {
            savedRivers.append(info)
            savedRivers.sort { $0.name.lowercased() < $1.name.lowercased() }
        }
    }

    /// Names a river — which saves it — or, with no name, makes it this
    /// device's own again. The file under its old name goes.
    public func rename(_ river: River, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let new: String? = name.isEmpty ? nil : name
        guard new != river.name else { return }
        if let old = river.name {
            // Carried over whole, so that what this app does not show of it is not lost.
            if let new, let kept = (try? engine.river(name: old)) ?? nil { _ = try? engine.saveRiver(name: new, river: kept) }
            _ = try? engine.deleteRiver(name: old)
            savedRivers.removeAll { $0.name == old }
        }
        river.name = new
        rememberRivers()
    }

    /// Shows a saved river: the tab that has it, or a new one.
    public func openSaved(_ name: String) {
        if let index = rivers.firstIndex(where: { $0.name == name }) {
            currentRiver = index
            return
        }
        guard let saved = (try? engine.river(name: name)) ?? nil else { return }
        let river = River()
        river.name = name
        river.icon = saved.icon
        river.color = saved.color
        river.query = saved.query
        river.hidden = saved.hidden.map(ownName)
        river.opened = Set(saved.opened.map(ownName))
        let folded = Set(saved.folded.map { path(named: $0) })
        river.cards = saved.cards.compactMap { card in
            let path = path(named: card.title)
            guard !isGone(path: path) else { return nil }
            var made = Card(path: path, title: title(of: path, named: card.title), focus: card.focus)
            made.folded = folded.contains(path)
            made.foldedRows = card.foldedRows
            return made
        }
        known[river.id] = river.signature
        // In place of a river with nothing in it, rather than beside it.
        if self.river.cards.isEmpty, self.river.name == nil { rivers[currentRiver] = river } else {
            rivers.append(river)
            currentRiver = rivers.count - 1
        }
        rememberRivers()
    }

    /// How many notes a query river shows when its query sets no limit.
    static let foundLimit = 60

    /// Runs a query river's query, and gives it what was found.
    public func find(for river: River) {
        guard let query = river.query else { return }
        let outcome = try? engine.runQuery(body: Self.limited(query), this: nil)
        river.take(found: (outcome?.pages ?? []).map { ($0.path, $0.title) }, total: Int(outcome?.total ?? 0))
    }

    static func limited(_ query: String, to limit: Int = foundLimit) -> String {
        query.lowercased().contains("limit:") ? query : query + "\nlimit: \(limit)"
    }

    /// How many notes a query finds.
    public func count(_ query: String) -> Int {
        Int((try? engine.runQuery(body: query + "\nlimit: 1", this: nil))?.total ?? 0)
    }

    /// Makes a river of what a query finds, named and so saved, and shows it.
    public func newQueryRiver(name: String, query: String, icon: String?, color: String?) {
        let made = River()
        made.name = name
        made.query = query
        made.icon = icon
        made.color = color
        if river.all.isEmpty, !river.isStyled, river.query == nil { rivers[currentRiver] = made } else {
            rivers.append(made)
            currentRiver = rivers.count - 1
        }
        rememberRivers()
    }

    /// What is asked of the query editor: a new river, or a river's own query.
    public enum QueryAsk: Identifiable {
        case new
        case edit(River)
        public var id: String {
            switch self {
            case .new: return "new"
            case .edit(let river): return river.id.uuidString
            }
        }
    }

    public var queryAsk: QueryAsk?

    // MARK: - Done, and undone

    /// What was just done that can be undone: said, a moment, at the
    /// river's foot. Nothing that closes, removes or deletes asks first;
    /// it is done, and for a few seconds can be taken back.
    public private(set) var undoOffer: (id: Int, said: String)?
    @ObservationIgnored private var undoing: (@MainActor () -> Void)?
    @ObservationIgnored private var offerClearing: Task<Void, Never>?
    @ObservationIgnored private var offers = 0
    /// How long an offer to undo stays.
    static let undoSeconds = 6.0

    /// Says something was done, and keeps how to undo it.
    public func undoable(_ said: String, undo: @escaping @MainActor () -> Void) {
        offerClearing?.cancel()
        offers += 1
        undoing = undo
        undoOffer = (offers, said)
        offerClearing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled else { return }
            self?.dismissUndo()
        }
    }

    /// The offer taken: what was just done, undone. Says whether there was one.
    @discardableResult
    public func takeUndo() -> Bool {
        guard let undo = undoing else { return false }
        dismissUndo()
        undo()
        return true
    }

    public func dismissUndo() {
        offerClearing?.cancel()
        undoing = nil
        undoOffer = nil
    }

    // MARK: Reopening what was closed

    /// A card closed, or a note deleted: enough of it to bring it back.
    private struct Shut {
        /// What was done that shut it: undone, it is no longer shut.
        var action: Int
        var card: Card
        /// Where it stood among the cards held in its river.
        var index: Int
        weak var river: River?
        /// Whether it was one a query found, and was taken out of the river.
        var wasFound: Bool
        /// What a deleted note said.
        var written: String?
    }

    @ObservationIgnored private var shut: [Shut] = []
    @ObservationIgnored private var actions = 0

    private func remember(shut cards: [(card: Card, index: Int, wasFound: Bool)], in river: River, written: String? = nil) -> Int {
        actions += 1
        shut.append(contentsOf: cards.map { Shut(action: actions, card: $0.card, index: $0.index, river: river, wasFound: $0.wasFound, written: written) })
        if shut.count > 100 { shut.removeFirst(shut.count - 100) }
        return actions
    }

    /// Brings back the card closed last, where it was — a note deleted
    /// is written again as it was. Again, the one before it; and so on.
    /// Says whether there was one.
    @discardableResult
    public func reopenClosed() -> Bool {
        while let last = shut.popLast() {
            let there = ((try? engine.read(path: last.card.path)) ?? nil) != nil
            if !there {
                if let written = last.written {
                    guard (try? engine.write(path: last.card.path, content: written)) != nil else { continue }
                    drafts[last.card.path] = nil
                } else if isGone(path: last.card.path) {
                    // Deleted since it was closed: nothing to open.
                    continue
                }
            }
            dismissUndo()
            let river = last.river.flatMap { river in rivers.contains { $0 === river } ? river : nil } ?? self.river
            if let index = rivers.firstIndex(where: { $0 === river }) { currentRiver = index }
            if last.wasFound {
                river.hidden.removeAll { $0 == last.card.name }
                find(for: river)
            }
            if let open = river.all.first(where: { $0.path == last.card.path }) {
                river.reveal(open.id)
            } else if !last.wasFound || river.query == nil {
                river.cards.insert(last.card, at: min(max(last.index, 0), river.cards.count))
                river.reveal(last.card.id)
            }
            rememberRivers()
            return true
        }
        return false
    }

    /// A river's cards as they stand, to put back.
    private struct Stood {
        var cards: [Card]
        var hidden: [String]
        var opened: Set<String>
        var selected: Card.ID?
    }

    private func stood(_ river: River) -> Stood { Stood(cards: river.cards, hidden: river.hidden, opened: river.opened, selected: river.selected) }

    private func restore(_ river: River, to stood: Stood) {
        river.cards = stood.cards
        river.hidden = stood.hidden
        river.opened = stood.opened
        river.selected = stood.selected
        find(for: river)
        rememberRivers()
    }

    /// Closes a card — or, of what a query found, takes it out of the river.
    public func close(_ id: Card.ID, in river: River) {
        guard let card = river.card(id) else { return }
        let before = stood(river)
        let found = river.isFound(id)
        draft(path: card.path, title: card.title).saveNow()
        let action = remember(shut: [(card, river.cards.firstIndex { $0.id == id } ?? 0, found)], in: river)
        river.close(id)
        rememberRivers()
        undoable("\(found ? "Removed" : "Closed") “\(label(path: card.path, title: card.title))”") { [weak self, weak river] in
            guard let self, let river else { return }
            self.shut.removeAll { $0.action == action }
            self.restore(river, to: before)
        }
    }

    /// Deletes a card's note, and closes the card. The note is kept, as
    /// it was written, for as long as the offer to undo stands.
    public func delete(_ id: Card.ID, in river: River) {
        guard let card = river.card(id) else { return }
        let before = stood(river)
        let draft = draft(path: card.path, title: card.title)
        let said = draft.label
        draft.saveNow()
        let written = (try? engine.read(path: card.path)) ?? nil
        draft.delete()
        for one in rivers { one.forget(path: card.path) }
        let action = remember(shut: [(card, river.cards.firstIndex { $0.id == id } ?? 0, river.isFound(id))], in: river, written: written)
        river.close(id)
        // Not taken out of what a query finds: it is gone, and will not be found.
        river.hidden = before.hidden
        rememberRivers()
        undoable("Deleted “\(said)”") { [weak self, weak river] in
            guard let self else { return }
            self.shut.removeAll { $0.action == action }
            if let written { _ = try? self.engine.write(path: card.path, content: written) }
            if let river { self.restore(river, to: before) }
        }
    }

    /// Closes every card of a river but one — or, with none kept, all of them.
    public func closeAll(in river: River, but kept: Card.ID? = nil) {
        let before = stood(river)
        let closing = river.cards.filter { $0.id != kept }
        guard !closing.isEmpty else { return }
        saveAll()
        let action = remember(shut: river.cards.enumerated().filter { $0.element.id != kept }.map { ($0.element, $0.offset, false) }, in: river)
        river.cards.removeAll { $0.id != kept }
        if river.writing.map({ $0 != kept }) ?? false { river.writing = nil }
        rememberRivers()
        undoable("Closed \(closing.count) \(closing.count == 1 ? "card" : "cards")") { [weak self, weak river] in
            guard let self, let river else { return }
            self.shut.removeAll { $0.action == action }
            self.restore(river, to: before)
        }
    }

    /// Takes a saved river out of the graph. A tab showing it stays, unsaved.
    public func deleteSaved(_ name: String) {
        let was = (try? engine.river(name: name)) ?? nil
        let named = rivers.filter { $0.name == name }
        _ = try? engine.deleteRiver(name: name)
        savedRivers.removeAll { $0.name == name }
        for river in named { river.name = nil }
        rememberRivers()
        guard let was else { return }
        undoable("Deleted river “\(name)”") { [weak self] in
            guard let self else { return }
            _ = try? self.engine.saveRiver(name: name, river: was)
            for river in named { river.name = name }
            self.rememberRivers()
            self.refreshCounts()
        }
    }

    public func closeRiver(at index: Int) {
        guard rivers.indices.contains(index) else { return }
        let closed = rivers.remove(at: index)
        let shown = currentRiver
        if rivers.isEmpty { rivers = [River()] }
        currentRiver = min(currentRiver, rivers.count - 1)
        rememberRivers()
        // A river with nothing in it is no loss.
        guard !closed.all.isEmpty || closed.isStyled || closed.query != nil else { return }
        undoable("Closed river “\(title(of: closed))”") { [weak self] in
            guard let self else { return }
            self.rivers.insert(closed, at: min(index, self.rivers.count))
            self.currentRiver = min(shown, self.rivers.count - 1)
            self.rememberRivers()
        }
    }

    /// Makes a new note of a title, and opens it to be written in.
    @discardableResult
    public func newPage(title: String) -> Card? {
        guard let path = try? engine.createNote(title: title) else { return nil }
        let card = Card(path: path, title: title)
        river.open(card, after: river.selected)
        river.writing = card.id
        rememberRivers()
        return card
    }

    // What is open is this device's own: kept by the engine, out of the graph.
    private struct Kept: Codable {
        var rivers: [River.Kept]
        var current: Int
    }

    @ObservationIgnored private var remembering: Task<Void, Never>?

    /// Remembers the rivers in a moment: for what changes as fast as it
    /// is typed — which rows of a card are folded — and need not be
    /// written each time.
    public func rememberRiversSoon() {
        remembering?.cancel()
        remembering = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.rememberRivers()
        }
    }

    // MARK: - Rows moved to another note

    /// Rows taken out of a note's outline, on their way to another note.
    public struct MovingRows: Identifiable {
        public let id = UUID()
        /// The rows, as Markdown.
        public var markdown: String
        /// The note they come from.
        public var from: String
        /// Told once they are placed: the editor then takes them out of where they were.
        var moved: () -> Void
    }

    /// The rows being moved, while where they go is being chosen.
    public var movingRows: MovingRows?

    /// Puts the rows being moved at the end of a note, and has them taken out of where they were.
    public func finishMove(to path: String) {
        guard let moving = movingRows else { return }
        movingRows = nil
        drafts[path]?.saveNow()
        var text = ((try? engine.read(path: path)) ?? nil) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += moving.markdown.hasSuffix("\n") ? moving.markdown : moving.markdown + "\n"
        guard (try? engine.write(path: path, content: text)) != nil else { return }
        drafts[path]?.fileChanged()
        moving.moved()
        note("river", "Moved rows from \(moving.from) to \(path)")
    }

    public func rememberRivers() {
        for river in rivers { save(river) }
        let kept = Kept(rivers: rivers.map(\.kept), current: currentRiver)
        if let data = try? JSONEncoder().encode(kept), let text = String(data: data, encoding: .utf8) {
            try? engine.setLocalValue(name: "weft/rivers", value: text)
        }
    }

    private func restoreRivers() {
        guard let text = (try? engine.localValue(name: "weft/rivers")) ?? nil, let kept = try? JSONDecoder().decode(Kept.self, from: Data(text.utf8)) else {
            rivers = [River()]
            return
        }
        rivers = kept.rivers.map(River.init(kept:))
        // A note never titled, deleted since — on another device, say — is not opened again.
        for river in rivers { river.cards.removeAll { isGone(path: $0.path) } }
        if rivers.isEmpty { rivers = [River()] }
        currentRiver = min(max(kept.current, 0), rivers.count - 1)
        // A saved river is what its file says, whatever this device remembers of it.
        readRivers()
    }

    // MARK: - Sync

    public func syncNow() {
        saveAll()
        engine.sync()
    }

    public var isSyncing: Bool {
        if case .syncing = sync { return true }
        return false
    }
}

enum Host {
    static var deviceName: String {
        #if os(macOS)
        return Foundation.Host.current().localizedName ?? "Mac"
        #else
        return "iPhone"
        #endif
    }
}

/// A river saved in the graph: what a list shows of it.
public struct SavedRiverInfo: Hashable, Identifiable {
    public var name: String
    public var icon: String?
    public var color: String?
    public var cards: Int
    /// Its first few cards' titles: what a preview of it shows.
    public var titles: [String] = []
    public var isQuery = false
    public var id: String { name }
    public var emblem: Emblem { Emblem(title: name, icon: icon, color: color) }
}

/// A card: a page open in a river.
public struct Card: Identifiable, Hashable, Codable {
    public var id = UUID()
    public var path: String
    public var title: String
    public var folded = false
    /// The rows of its outline folded away, in this river: each known by
    /// its place and its words, as the river's file keeps them.
    public var folds: [Fold]?
    /// The row of its page it shows, by the name the row has in the
    /// note, when it shows only what is under one: a note within the
    /// note, written in as one. `nil` for a card of the whole page.
    public var focus: String?

    public struct Fold: Hashable, Codable {
        public var index: Int
        public var text: String
    }

    public init(path: String, title: String, focus: String? = nil) {
        self.path = path
        self.title = title
        self.focus = focus
    }

    /// What it shows: its page, and the row of it if it shows only one.
    /// A river has one card of each.
    public var spot: String { Self.spot(path: path, focus: focus) }
    static func spot(path: String, focus: String?) -> String { focus.map { "\(path)^\($0)" } ?? path }

    /// What a river keeps it by: its page's own name — its file's.
    public var name: String { linkName(path: path) ?? title }

    /// Its folded rows, as the editor takes them.
    public var foldedRows: [RiverFoldedRow] {
        get { (folds ?? []).map { RiverFoldedRow(index: UInt32(max($0.index, 0)), text: $0.text) } }
        set { folds = newValue.isEmpty ? nil : newValue.map { Fold(index: Int($0.index), text: $0.text) } }
    }
}

/// One river: its cards, which is chosen, which is being written in.
@MainActor
@Observable
public final class River: Identifiable {
    public let id: UUID
    /// Its name, once it has been given one: a named river is a saved one.
    public var name: String?
    /// What it was given to be shown by: an SF Symbol's name, a colour's.
    public var icon: String?
    public var color: String?
    public var cards: [Card] = []
    /// What it finds, for a query river: a query's body. Its cards are
    /// then those held by hand (`cards`), and after them what the query
    /// finds (`found`), each folded to a line until it is opened.
    public var query: String?
    /// Of what the query finds: the notes taken out of the river, and
    /// those opened out of their line. By title.
    public var hidden: [String] = []
    public var opened: Set<String> = []
    /// What the query found, as cards; and how many it found in all.
    public private(set) var found: [Card] = []
    public private(set) var foundTotal = 0
    @ObservationIgnored private var foundIDs: [String: UUID] = [:]
    /// Every card shown: those held, then those found.
    public var all: [Card] { query == nil ? cards : cards + found }
    /// The card chosen: the one the keys go to.
    public var selected: Card.ID?
    /// The card with the caret in it.
    public var writing: Card.ID?
    /// Asks the river's view to scroll a card to the top; moved each time.
    public var scrollTarget: (card: Card.ID, tick: Int)?
    /// Asks the river's view to bring a card into sight, moving no more
    /// than that takes: after a card was closed or folded, so that what
    /// is left is not a stretch of nothing. Moved each time.
    public var settleTarget: (card: Card.ID, tick: Int)?

    func settle(on id: Card.ID?) {
        guard let id else { return }
        settleTarget = (id, (settleTarget?.tick ?? 0) + 1)
    }
    /// The note whose pages are being read, over the river.
    public var reading: Place?

    /// A note the river was at, or is reading: by its path, with the title its card had.
    public struct Place: Hashable, Identifiable, Sendable {
        public var path: String
        public var title: String
        public var id: String { path }

        public init(path: String, title: String) {
            self.path = path
            self.title = title
        }
    }

    // Back and forward. The cards the river was at before each jump to
    // another — a link followed, a card opened or stepped to — and those
    // gone back from. This device's, and this run's: not kept.
    private var backward: [Place] = []
    private var forward: [Place] = []
    @ObservationIgnored private var travelling = false

    /// Where going back would go, the nearest first, each once.
    public var places: [Place] {
        var seen = Set<String>()
        return Array(backward.reversed().filter { seen.insert($0.path).inserted }.prefix(12))
    }

    public var canGoBack: Bool { !backward.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// The river is about to show a card: where it was is kept to go back
    /// to — the card the jump was made from, else the one chosen — unless
    /// it is going back there, or is there already.
    private func leave(for id: Card.ID, from: Card.ID?) {
        guard !travelling, let from = (from ?? selected).flatMap(card), from.id != id, from.path != card(id)?.path else { return }
        let place = Place(path: from.path, title: from.title)
        if backward.last?.path != place.path { backward.append(place) }
        if backward.count > 50 { backward.removeFirst() }
        forward = []
    }

    /// Back to the card the river was at last.
    public func goBack() {
        guard let place = backward.popLast() else { return }
        if let here = selected.flatMap(card), here.path != place.path { forward.append(Place(path: here.path, title: here.title)) }
        travel(to: place)
    }

    /// Forward again.
    public func goForward() {
        guard let place = forward.popLast() else { return }
        if let here = selected.flatMap(card), here.path != place.path { backward.append(Place(path: here.path, title: here.title)) }
        travel(to: place)
    }

    /// Back to one of the places, those after it left to go forward to.
    public func goBack(to place: Place) {
        guard let index = backward.lastIndex(where: { $0.path == place.path }) else { return }
        while backward.count > index + 1 { forward.append(backward.removeLast()) }
        goBack()
    }

    private func travel(to place: Place) {
        travelling = true
        open(Card(path: place.path, title: place.title))
        travelling = false
    }

    /// A note was given another title: the places it is one of say so.
    func retitled(path: String, to title: String) {
        for index in backward.indices where backward[index].path == path { backward[index].title = title }
        for index in forward.indices where forward[index].path == path { forward[index].title = title }
        if reading?.path == path { reading?.title = title }
    }

    /// A note is gone: there is no going back to it.
    func forget(path: String) {
        backward.removeAll { $0.path == path }
        forward.removeAll { $0.path == path }
    }

    public init() { id = UUID() }

    struct Kept: Codable {
        var id: UUID
        var name: String?
        var cards: [Card]
        var icon: String?
        var color: String?
        var query: String?
        var hidden: [String]?
        var opened: [String]?
    }

    /// What of a river is saved in its file: what tells whether it was changed.
    struct Signature: Hashable {
        var folds: [[Card.Fold]] = []
        var cards: [String]
        var folded: Set<String>
        var icon: String?
        var color: String?
        var query: String?
        var hidden: [String]
        var opened: Set<String>
    }

    var signature: Signature {
        Signature(folds: cards.map { $0.folds ?? [] }, cards: cards.map { card in card.focus.map { "\(card.name)^\($0)" } ?? card.name }, folded: Set(cards.filter(\.folded).map(\.name)), icon: icon, color: color, query: query, hidden: query == nil ? [] : hidden, opened: query == nil ? [] : opened)
    }

    var kept: Kept { Kept(id: id, name: name, cards: cards, icon: icon, color: color, query: query, hidden: hidden, opened: Array(opened)) }

    /// Takes what the query found: each a card, but for those held by
    /// hand already and those taken out. A card keeps its identity from
    /// one finding to the next, so that nothing jumps when the list is
    /// found again.
    func take(found pages: [(path: String, title: String)], total: Int) {
        let held = Set(cards.map(\.path))
        let out = Set(hidden)
        found = pages.filter { !held.contains($0.path) && !out.contains(Prism.linkName(path: $0.path) ?? $0.title) }.map { page in
            var card = Card(path: page.path, title: page.title)
            card.id = foundIDs[page.path] ?? card.id
            foundIDs[page.path] = card.id
            card.folded = !opened.contains(card.name)
            return card
        }
        foundTotal = total
    }

    public func card(_ id: Card.ID) -> Card? { all.first { $0.id == id } }

    /// Has a card show only what is under a row of its page — the row of
    /// that name — or, given none, the whole page again.
    public func setFocus(_ id: Card.ID, _ focus: String?) {
        if let index = cards.firstIndex(where: { $0.id == id }) { cards[index].focus = focus } else if let index = found.firstIndex(where: { $0.id == id }) { found[index].focus = focus }
    }

    /// A card of its own for a row of a card's page, straight after that card.
    public func openFocus(_ focus: String, of id: Card.ID) {
        guard let from = card(id) else { return }
        open(Card(path: from.path, title: from.title, focus: focus), after: id)
    }

    /// A card's outline was folded or unfolded: which of its rows are folded now.
    public func setFolds(_ id: Card.ID, _ rows: [RiverFoldedRow]) {
        if let index = cards.firstIndex(where: { $0.id == id }) { cards[index].foldedRows = rows } else if let index = found.firstIndex(where: { $0.id == id }) { found[index].foldedRows = rows }
    }
    public func isFound(_ id: Card.ID) -> Bool { found.contains { $0.id == id } }

    /// Holds a found card by hand, at the head of the river: it stays
    /// whatever the query comes to find.
    public func hold(_ id: Card.ID) {
        guard let index = found.firstIndex(where: { $0.id == id }) else { return }
        let card = found.remove(at: index)
        cards.append(card)
    }

    /// What stands for it on its tab: its icon, or a letter of its name.
    public var emblem: Emblem { Emblem(title: title, icon: icon, color: color) }
    /// Whether it has anything of its own to be shown by.
    public var isStyled: Bool { name != nil || icon != nil || color != nil }

    init(kept: Kept) {
        id = kept.id
        name = kept.name
        cards = kept.cards
        icon = kept.icon
        color = kept.color
        query = kept.query
        hidden = kept.hidden ?? []
        opened = Set(kept.opened ?? [])
    }

    public var title: String {
        name ?? cards.first.map { Days.shown($0.title) } ?? (query == nil ? "New River" : "Query")
    }

    /// Opens a card after another — or scrolls to it, if the page is open already.
    public func open(_ card: Card, after: Card.ID? = nil) {
        if let open = cards.first(where: { $0.spot == card.spot }) {
            reveal(open.id, from: after)
            return
        }
        // Found by the query already: opened out of its line, where it stands.
        if card.focus == nil, query != nil, let index = found.firstIndex(where: { $0.path == card.path }) {
            opened.insert(found[index].name)
            found[index].folded = false
            reveal(found[index].id, from: after)
            return
        }
        if let after, let index = cards.firstIndex(where: { $0.id == after }) {
            cards.insert(card, at: index + 1)
        } else {
            cards.insert(card, at: 0)
        }
        reveal(card.id, from: after)
    }

    /// Shows a card, and chooses it. Where the river was — the card the
    /// jump was made `from`, else the one chosen — is kept to go back to.
    public func reveal(_ id: Card.ID, from: Card.ID? = nil, unfolding: Bool = true) {
        leave(for: id, from: from)
        // Gone to on purpose: opened out, if it was folded — but not when only
        // passed over, stepping through the river card by card.
        if unfolding, card(id)?.folded == true { toggleFold(id) }
        selected = id
        scrollTarget = (id, (scrollTarget?.tick ?? 0) + 1)
    }

    public func close(_ id: Card.ID) {
        let shown = all
        guard let place = shown.firstIndex(where: { $0.id == id }) else { return }
        if let index = cards.firstIndex(where: { $0.id == id }) {
            cards.remove(at: index)
        } else if let index = found.firstIndex(where: { $0.id == id }) {
            // Taken out of what the query finds: kept out, until brought back.
            hidden.append(found[index].name)
            found.remove(at: index)
        }
        // A note being written in stays where it is, whatever else is closed.
        let busy = writing != nil && writing != id
        if writing == id { writing = nil }
        let left = all
        if selected == id { selected = left.indices.contains(place) ? left[place].id : left.last?.id }
        if !busy { settle(on: left.indices.contains(place) ? left[place].id : left.last?.id) }
    }

    public func toggleFold(_ id: Card.ID) {
        let busy = writing != nil && writing != id
        defer { if card(id)?.folded == true, !busy { settle(on: id) } }
        if let index = cards.firstIndex(where: { $0.id == id }) {
            cards[index].folded.toggle()
            if cards[index].folded, writing == id { writing = nil }
        } else if let index = found.firstIndex(where: { $0.id == id }) {
            found[index].folded.toggle()
            if found[index].folded { opened.remove(found[index].name) } else { opened.insert(found[index].name) }
            if found[index].folded, writing == id { writing = nil }
        }
    }

    public func setAllFolded(_ folded: Bool) {
        for index in cards.indices { cards[index].folded = folded }
        for index in found.indices { found[index].folded = folded }
        opened = folded ? [] : Set(found.map(\.name))
        if folded { writing = nil }
    }

    /// Moves a card to a place among those shown: where it was dragged
    /// to. One the query found is held by hand from then on — it has been
    /// given a place of its own.
    public func move(_ id: Card.ID, toPlace place: Int) {
        if let index = found.firstIndex(where: { $0.id == id }) { cards.append(found.remove(at: index)) }
        guard let from = cards.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(place, 0), cards.count - 1)
        guard to != from else { return }
        cards.insert(cards.remove(at: from), at: to)
    }

    public func move(_ id: Card.ID, by step: Int) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let to = index + step
        guard cards.indices.contains(to) else { return }
        cards.swapAt(index, to)
    }

    public func select(step: Int) {
        let cards = all
        guard !cards.isEmpty else { return }
        let index = selected.flatMap { id in cards.firstIndex(where: { $0.id == id }) } ?? (step > 0 ? -1 : cards.count)
        let to = min(max(index + step, 0), cards.count - 1)
        // Stepped to, with the arrows: chosen and shown, and left folded if it is.
        reveal(cards[to].id, unfolding: false)
    }
}

/// A page being written: the one note every card of it shows.
///
/// The note is the engine's — a `NoteEditor`, which holds its tree of
/// blocks, its title and its fields. A draft is that editor with what an
/// app adds: when to save (a moment after writing pauses), and what to do
/// when the file changes underneath (take it, when nothing is unsaved;
/// otherwise the engine merges the two at the next save).
@MainActor
@Observable
public final class PageDraft {
    public let path: String
    public private(set) var exists = false
    /// The note. Another takes its place when the file is read again.
    public private(set) var editor: NoteEditor
    public private(set) var title: String
    /// Moves whenever the note changes, by any hand: what a view showing
    /// something of it — its summary, whether it is blank — redraws on.
    public private(set) var revision = 0
    public private(set) var isConflicted = false

    /// The note as cards that show one row of it have it: each a note
    /// of its own, read from this one and focused there, good for as
    /// long as nothing but that card has changed the note since.
    @ObservationIgnored private var views: [Card.ID: (editor: NoteEditor, revision: Int)] = [:]

    /// The note as a card showing only one of its rows writes in it —
    /// `nil` when the note has no row of that name any more.
    public func view(for card: Card.ID, focus: String) -> NoteEditor? {
        if let open = views[card], open.revision == revision, open.editor.focus() == focus { return open.editor }
        let made = NoteEditor.open(source: editor.markdown(), mode: .outline)
        guard made.setFocus(name: focus) else {
            views[card] = nil
            return nil
        }
        views[card] = (made, revision)
        return made
    }

    /// The note was changed in a card that shows one row of it: what
    /// that card's note now says is what the note says, in every card.
    public func changed(from card: Card.ID) {
        guard let view = views[card] else { return changed() }
        editor = NoteEditor.open(source: view.editor.markdown(), mode: editor.mode())
        revision += 1
        views[card] = (view.editor, revision)
        touch()
    }

    @ObservationIgnored private weak var store: GraphStore?
    /// The file as it was last read or written: what a save is merged from.
    @ObservationIgnored private var base: String?
    @ObservationIgnored private var unsaved = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private let fallbackTitle: String

    init(store: GraphStore, path: String, title: String) {
        self.store = store
        self.path = path
        self.title = title
        fallbackTitle = title
        editor = NoteEditor.open(source: "", mode: .outline)
        read()
    }

    public var mode: EditorMode { editor.mode() }

    private func read() {
        guard let store else { return }
        let file = (try? store.engine.read(path: path)) ?? nil
        exists = file != nil
        base = file
        take(file ?? "")
    }

    /// Takes a file's text as what the page says.
    private func take(_ file: String) {
        editor = NoteEditor.open(source: file, mode: chosenMode(for: file))
        title = editor.title() ?? ((try? store?.engine.page(path: path)) ?? nil)?.title ?? fallbackTitle
        isConflicted = conflictCount(source: file) > 0
        revision += 1
    }

    /// How the page is shown: as it was last chosen to be on this device;
    /// else as an outline if it opens with a list, as text if with prose.
    private func chosenMode(for file: String) -> EditorMode {
        switch (try? store?.engine.localValue(name: "weft/mode/\(path)")) ?? nil {
        case "text": return .text
        case "outline": return .outline
        default: break
        }
        let probe = NoteEditor.open(source: file, mode: .text)
        guard let first = probe.layout().lines.first(where: { $0.kind != .blank }) else { return .outline }
        if case .item = first.kind { return .outline }
        return .text
    }

    public func setMode(_ mode: EditorMode) {
        guard mode != editor.mode() else { return }
        editor.setMode(mode: mode)
        try? store?.engine.setLocalValue(name: "weft/mode/\(path)", value: mode == .outline ? "outline" : "text")
        revision += 1
    }

    /// The file changed underneath: taken at once when nothing is unsaved;
    /// otherwise merged with at the next save.
    func fileChanged() {
        guard !unsaved, let store else { return }
        let file = (try? store.engine.read(path: path)) ?? nil
        guard file != base else { return }
        exists = file != nil
        base = file
        take(file ?? "")
    }

    /// The note was changed in its editor.
    public func changed() {
        revision += 1
        touch()
    }

    public var isBlank: Bool {
        _ = revision
        return editor.isBlank()
    }

    /// The page's first words, for a card folded to its title.
    public var summary: String {
        _ = revision
        // Its words, without the marks a line of text opens with: `## `, `- `, `1. `, `> `, `- [ ] `.
        let marks = #"^\s*(#{1,6}\s+|>\s?|([-*+]|\d+[.)])\s+(\[.\]\s+)?)"#
        var lines = editor.text().split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" })
            .map { inlinePlainText(text: $0.replacingOccurrences(of: marks, with: "", options: .regularExpression)) }
            .filter { !$0.isEmpty }
        // An untitled note is called by its first words: they are not said twice.
        if isUntitled, !lines.isEmpty { lines.removeFirst() }
        return lines.prefix(3).joined(separator: "  ")
    }

    /// The note's first few pictures — those on lines of their own: what
    /// stands for it, small, at the end of its folded card.
    public var pictures: [EditorPicture] {
        _ = revision
        var found: [EditorPicture] = []
        for line in editor.text().split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" }) where line.contains("![") {
            let words = line.replacingOccurrences(of: #"^\s*([-*+]|\d+[.)])\s+(\[.\]\s+)?"#, with: "", options: .regularExpression)
            found += EditorPicture.all(line: words) ?? []
            if found.count >= 3 { break }
        }
        return Array(found.prefix(3))
    }

    /// The first picture in the note, if it has one on a line of its own:
    /// what stands for it, small, when its card is folded.
    public var firstPicture: EditorPicture? {
        _ = revision
        for line in editor.text().split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" }) where line.contains("![") {
            // Past the marker a line of text has, which an outline's row has not.
            let words = line.replacingOccurrences(of: #"^\s*([-*+]|\d+[.)])\s+(\[.\]\s+)?"#, with: "", options: .regularExpression)
            if let picture = EditorPicture(line: words) { return picture }
        }
        return nil
    }

    /// Makes the note's first line its title: taken out of what it says,
    /// and the note titled by it — every link to the note following, as
    /// when it is renamed. Says whether there was a line to title it by.
    @discardableResult
    public func titleByFirstLine() -> Bool {
        guard isUntitled, let words = editor.takeFirstLine() else { return false }
        changed()
        rename(to: words)
        store?.retitled(path: path, to: title)
        return true
    }

    /// Where an address on the web is written bare in the note: not
    /// already the address of a link with words of its own.
    private func bareLink(_ address: String) -> NSRange? {
        let text = editor.text() as NSString
        var from = 0
        while from < text.length {
            let found = text.range(of: address, range: NSRange(location: from, length: text.length - from))
            guard found.location != NSNotFound else { return nil }
            from = NSMaxRange(found)
            let before = found.location >= 2 ? text.substring(with: NSRange(location: found.location - 2, length: 2)) : ""
            let after = from < text.length ? text.substring(with: NSRange(location: from, length: 1)) : " "
            // The whole of an address, not the head of a longer one.
            guard before != "](", after.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || after == ">" else { continue }
            // Written between angle brackets, they go with it.
            if after == ">", found.location >= 1, text.character(at: found.location - 1) == 60 { return NSRange(location: found.location - 1, length: found.length + 2) }
            return after == ">" ? nil : found
        }
        return nil
    }

    /// Whether an address is written bare, and could be given a title.
    public func hasBareLink(_ address: String) -> Bool {
        _ = revision
        return bareLink(address) != nil
    }

    /// Writes a bare address as a link with its page's title for words.
    @discardableResult
    public func titleLink(_ address: String, as title: String) -> Bool {
        let words = title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            .components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, let range = bareLink(address) else { return false }
        _ = editor.replace(start: UInt32(range.location), end: UInt32(NSMaxRange(range)), replacement: "[\(words)](\(address))")
        changed()
        return true
    }

    /// Whether the note was never given a title: the engine's rule.
    public var isUntitled: Bool {
        _ = revision
        return editor.isUntitled(path: path)
    }

    /// What the note is called where it is shown: its title, or — never
    /// given one — its first words. The engine's rule.
    public var label: String {
        _ = revision
        return Days.shown(editor.title() == nil && !isUntitled ? title : editor.label(path: path))
    }

    public var markdown: String { editor.markdown() }

    public func rename(to newTitle: String) {
        let newTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !newTitle.isEmpty, newTitle != title else { return }
        saveNow()
        if exists {
            // The engine's to do: it sees to the links. Refused — a date is a day's page, not a title — nothing changes.
            if (try? store.engine.renameNote(path: path, newTitle: newTitle)) != nil { read() }
        } else {
            // Not written yet: it is made with this title.
            editor.setTitle(title: newTitle)
            title = newTitle
            changed()
        }
    }

    /// The tags the note is given in its frontmatter: `tags:`. A tag
    /// written in a line, `#so`, is its line's, and is not among them.
    public var frontTags: [String] {
        _ = revision
        return editor.fields().first { $0.key == "tags" }?.values ?? []
    }

    /// Gives the note a tag, in its frontmatter. Says whether it was new.
    @discardableResult
    public func addTag(_ tag: String) -> Bool {
        let tag = tag.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        let has = frontTags
        guard !tag.isEmpty, !has.contains(where: { nameKey(name: $0) == nameKey(name: tag) }) else { return false }
        setField("tags", values: has + [tag], asList: true)
        saveNow()
        return true
    }

    /// Takes a tag out of the note's frontmatter.
    public func removeTag(_ tag: String) {
        let key = nameKey(name: tag)
        setField("tags", values: frontTags.filter { nameKey(name: $0) != key }, asList: true)
        saveNow()
    }

    /// A frontmatter field set, or — with no values — taken out.
    public func setField(_ key: String, values: [String], asList: Bool = false) {
        if values.isEmpty {
            _ = editor.removeField(key: key)
        } else if asList || values.count > 1 {
            editor.setListField(key: key, values: values)
        } else {
            editor.setField(key: key, value: values[0])
        }
        changed()
    }

    /// What the page was given to be shown by: `icon:`, `color:`.
    public var icon: String? {
        _ = revision
        return editor.field(key: "icon")
    }

    public var color: String? {
        _ = revision
        return editor.field(key: "color")
    }

    public func setLook(icon: String?, color: String?) {
        if icon != self.icon { setField("icon", values: icon.map { [$0] } ?? []) }
        if color != self.color { setField("color", values: color.map { [$0] } ?? []) }
        store?.styled(path: path, icon: icon, color: color)
    }

    /// Whether a field marks the page: pinned, in the inbox.
    public func isMarked(_ key: String) -> Bool {
        _ = revision
        return editor.isMarked(key: key)
    }

    public func toggleMark(_ key: String) {
        setField(key, values: editor.isMarked(key: key) ? [] : ["true"])
    }

    /// A page that is itself a thing to do.
    public enum TaskState { case none, todo, done }

    /// The note's checklist, if it holds one: its boxes ticked, of all.
    public var checklist: (done: Int, total: Int)? {
        _ = revision
        var (done, total) = (0, 0)
        for line in editor.layout().lines {
            guard case .item(_, let ticked, _) = line.kind, let ticked else { continue }
            total += 1
            if ticked { done += 1 }
        }
        return total > 0 ? (done, total) : nil
    }

    public var task: TaskState {
        _ = revision
        switch editor.field(key: "task") {
        case "todo": return .todo
        case "done": return .done
        default: return .none
        }
    }

    public func setTask(_ task: TaskState) {
        switch task {
        case .none:
            _ = editor.removeField(key: "task")
            _ = editor.removeField(key: "done")
        case .todo:
            editor.setField(key: "task", value: "todo")
            _ = editor.removeField(key: "done")
        case .done:
            editor.setField(key: "task", value: "done")
            editor.setField(key: "done", value: Days.name(Date()))
        }
        changed()
    }

    public func fields() -> [FrontmatterField] {
        _ = revision
        return editor.fields()
    }

    private func touch() {
        unsaved = true
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes what is unsaved, now.
    public func saveNow() {
        pending?.cancel()
        pending = nil
        guard unsaved, let store else { return }
        unsaved = false
        // A page not yet written, left with nothing in it, is not made.
        if !exists, editor.isBlank(), editor.fields().isEmpty { return }
        if !exists, editor.title() == nil, NotePath.isNote(path), !editor.isUntitled(path: path) {
            // A new note is titled by its first heading — but never by a file's name that says nothing.
            editor.setTitle(title: title)
        }
        guard let saved = try? store.engine.saveMerging(path: path, draft: editor.markdown(), base: base) else {
            unsaved = true
            return
        }
        exists = true
        base = saved.content
        isConflicted = saved.isConflicted
        // Merged with what changed underneath: the note is what the file now says.
        if saved.wasMerged { take(saved.content) }
    }

    /// Settles every conflict in the page one way.
    public func resolve(keeping keep: ConflictKeep) {
        saveNow()
        guard let store, let file = (try? store.engine.read(path: path)) ?? nil else { return }
        let settled = resolveConflicts(source: file, keep: keep)
        _ = try? store.engine.write(path: path, content: settled)
        base = settled
        take(settled)
    }

    public func delete() {
        pending?.cancel()
        unsaved = false
        guard let store else { return }
        _ = try? store.engine.delete(path: path)
        exists = false
        store.forget(path: path)
    }
}

enum NotePath {
    static func isNote(_ path: String) -> Bool { path.hasPrefix("notes/") }
    static func isDay(_ path: String) -> Bool { path.hasPrefix("daily/") }
}
