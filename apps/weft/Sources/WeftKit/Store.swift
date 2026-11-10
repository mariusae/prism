import Foundation
import Observation
import Prism
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
        // A graph kept on GitHub, signed in to: hear of each push to it.
        if token != nil, let host, (try? engine.listen(relay: host)) != nil { relay = .connecting }
    }

    /// Lets go of the graph: before it is opened again, as another account.
    public func close() {
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
            indexRevision += 1
            refreshCounts()
            // A file written by another hand: a draft with nothing unsaved takes it.
            for path in paths { drafts[path]?.fileChanged() }
        case .filesChanged(let paths):
            for path in paths { drafts[path]?.fileChanged() }
        case .syncStarted:
            sync = .syncing
        case .syncFinished(let report):
            sync = engine.status()
            syncNote = report.summary
            needsSignIn = false
        case .syncFailed(let message, _, let needsSignIn):
            sync = engine.status()
            syncNote = message
            self.needsSignIn = needsSignIn
        case .relayConnected, .relayPush:
            relay = .listening
        case .relayDisconnected(let reason, _):
            relay = .waiting(reason)
        default:
            break
        }
    }

    private func refreshCounts() {
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
        return ((try? engine.page(path: path)) ?? nil)?.label ?? title
    }

    /// The pages offered for a link being typed: those whose names match
    /// what was typed, then those that say it, then a river or two — and,
    /// when nothing is called just that, a new note of that name.
    public func linkOffers(_ typed: String, this: String? = nil) -> [EditorOffer] {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        func offer(_ page: PageInfo, detail: String? = nil, found: Bool = false) -> EditorOffer {
            let symbol = found ? "text.magnifyingglass" : (emblem(page).symbol ?? "doc.text")
            return EditorOffer(name: page.title, title: Self.shown(page), detail: detail, symbol: symbol)
        }
        // Nothing typed yet: what was written last.
        guard !typed.isEmpty else {
            return ((try? engine.runQuery(body: "sort: -modified\nlimit: 7", this: nil).pages) ?? []).filter { $0.path != this }.map { offer($0) }
        }
        var offers: [EditorOffer] = []
        var seen = Set<String>()
        if let this { seen.insert(this) }
        for page in (try? engine.complete(typed: typed, limit: 6)) ?? [] where seen.insert(page.path).inserted { offers.append(offer(page)) }
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
        let key = nameKey(name: name)
        if let known = resolved[key] { return known }
        let found = try? engine.resolve(name: name)
        resolved[key] = .some(found)
        return found
    }

    /// The draft of a page: the one every card of it writes in.
    public func draft(path: String, title: String) -> PageDraft {
        if let open = drafts[path] { return open }
        let draft = PageDraft(store: self, path: path, title: title)
        drafts[path] = draft
        return draft
    }

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
    public func newNote() -> Card? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        let tail = String((0..<4).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement() ?? "x" })
        let name = "untitled-\(format.string(from: Date()))-\(tail)"
        let path = "notes/\(name).md"
        guard (try? engine.write(path: path, content: "")) != nil else { return nil }
        let card = Card(path: path, title: name)
        river.open(card, after: river.selected)
        river.writing = card.id
        rememberRivers()
        return card
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
        var saved = ((try? engine.river(name: name)) ?? nil) ?? SavedRiver(cards: [], query: nil, placed: [], folded: [], opened: [], hidden: [], icon: nil, color: nil, place: nil)
        let known = Dictionary(saved.cards.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        saved.cards = river.cards.map { known[$0.title] ?? RiverCard(title: $0.title, foldedRows: [], placeRank: nil, placeKey: nil) }
        saved.folded = river.cards.filter(\.folded).map(\.title)
        saved.icon = river.icon
        saved.color = river.color
        saved.query = river.query
        if river.query != nil {
            saved.hidden = river.hidden
            saved.opened = river.opened.sorted()
        }
        if (try? engine.saveRiver(name: name, river: saved)) == true { refreshSaved(name: name, river: river) }
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
        river.hidden = saved.hidden
        river.opened = Set(saved.opened)
        river.cards = saved.cards.map { card in
            let target = resolve(card.title)
            var made = Card(path: target?.path ?? engine.pathForTitle(title: card.title), title: card.title)
            made.folded = saved.folded.contains(card.title)
            return made
        }
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

    /// Takes a saved river out of the graph. A tab showing it stays, unsaved.
    public func deleteSaved(_ name: String) {
        _ = try? engine.deleteRiver(name: name)
        savedRivers.removeAll { $0.name == name }
        for river in rivers where river.name == name { river.name = nil }
        rememberRivers()
    }

    public func closeRiver(at index: Int) {
        guard rivers.indices.contains(index) else { return }
        rivers.remove(at: index)
        if rivers.isEmpty { rivers = [River()] }
        currentRiver = min(currentRiver, rivers.count - 1)
        rememberRivers()
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
        if rivers.isEmpty { rivers = [River()] }
        currentRiver = min(max(kept.current, 0), rivers.count - 1)
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

    public init(path: String, title: String) {
        self.path = path
        self.title = title
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

    var kept: Kept { Kept(id: id, name: name, cards: cards, icon: icon, color: color, query: query, hidden: hidden, opened: Array(opened)) }

    /// Takes what the query found: each a card, but for those held by
    /// hand already and those taken out. A card keeps its identity from
    /// one finding to the next, so that nothing jumps when the list is
    /// found again.
    func take(found pages: [(path: String, title: String)], total: Int) {
        let held = Set(cards.map(\.path))
        let out = Set(hidden)
        found = pages.filter { !held.contains($0.path) && !out.contains($0.title) }.map { page in
            var card = Card(path: page.path, title: page.title)
            card.id = foundIDs[page.path] ?? card.id
            foundIDs[page.path] = card.id
            card.folded = !opened.contains(page.title)
            return card
        }
        foundTotal = total
    }

    public func card(_ id: Card.ID) -> Card? { all.first { $0.id == id } }
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
        name ?? cards.first?.title ?? (query == nil ? "New River" : "Query")
    }

    /// Opens a card after another — or scrolls to it, if the page is open already.
    public func open(_ card: Card, after: Card.ID? = nil) {
        if let open = cards.first(where: { $0.path == card.path }) {
            reveal(open.id)
            return
        }
        // Found by the query already: opened out of its line, where it stands.
        if query != nil, let index = found.firstIndex(where: { $0.path == card.path }) {
            opened.insert(found[index].title)
            found[index].folded = false
            reveal(found[index].id)
            return
        }
        if let after, let index = cards.firstIndex(where: { $0.id == after }) {
            cards.insert(card, at: index + 1)
        } else {
            cards.insert(card, at: 0)
        }
        reveal(card.id)
    }

    public func reveal(_ id: Card.ID) {
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
            hidden.append(found[index].title)
            found.remove(at: index)
        }
        if writing == id { writing = nil }
        let left = all
        if selected == id { selected = left.indices.contains(place) ? left[place].id : left.last?.id }
    }

    public func toggleFold(_ id: Card.ID) {
        if let index = cards.firstIndex(where: { $0.id == id }) {
            cards[index].folded.toggle()
            if cards[index].folded, writing == id { writing = nil }
        } else if let index = found.firstIndex(where: { $0.id == id }) {
            found[index].folded.toggle()
            if found[index].folded { opened.remove(found[index].title) } else { opened.insert(found[index].title) }
            if found[index].folded, writing == id { writing = nil }
        }
    }

    public func setAllFolded(_ folded: Bool) {
        for index in cards.indices { cards[index].folded = folded }
        for index in found.indices { found[index].folded = folded }
        opened = folded ? [] : Set(found.map(\.title))
        if folded { writing = nil }
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
        reveal(cards[to].id)
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
        var lines = editor.text().split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" }).map { inlinePlainText(text: String($0)) }.filter { !$0.isEmpty }
        // An untitled note is called by its first words: they are not said twice.
        if isUntitled, !lines.isEmpty { lines.removeFirst() }
        return lines.prefix(3).joined(separator: "  ")
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

    /// Whether the note was never given a title: the engine's rule.
    public var isUntitled: Bool {
        _ = revision
        return editor.isUntitled(path: path)
    }

    /// What the note is called where it is shown: its title, or — never
    /// given one — its first words. The engine's rule.
    public var label: String {
        _ = revision
        return editor.title() == nil && !isUntitled ? title : editor.label(path: path)
    }

    public var markdown: String { editor.markdown() }

    public func rename(to newTitle: String) {
        let newTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !newTitle.isEmpty, newTitle != title else { return }
        saveNow()
        if exists, (try? store.engine.renameNote(path: path, newTitle: newTitle)) != nil {
            read()
        } else {
            editor.setTitle(title: newTitle)
            title = newTitle
            changed()
        }
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
            editor.setField(key: "done", value: QuickOpen.day(Date()))
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
        if !exists, editor.title() == nil, NotePath.isNote(path) {
            // A new note is titled by its first heading.
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
