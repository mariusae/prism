#if os(iOS)
import Foundation
import Prism
import PrismEmblem
import WeftShared
import WidgetKit

/// The widgets, kept up: what they show written down for them, the to-dos
/// ticked on them checked off, and where they lead to gone to.
@MainActor
enum Glances {
    /// How many to-dos the widgets are told of: more than the largest shows.
    private static let toDosListed = 24
    /// How many of a river's cards, and of a card's rows.
    private static let cardsListed = 10
    private static let rowsListed = 4
    private static let todayRows = 14

    /// Writes down what the widgets show, as the graph now is — and has
    /// them drawn again, if it is other than it was.
    static func refresh(_ store: GraphStore) {
        // Not before the index is read: an empty graph would be written down for them.
        guard store.indexRevision > 0 else { return }
        let changed = Glance.write(snapshot(store))
        if changed { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// The to-dos ticked on a widget, checked off in their notes — what is
    /// written in the app saved first, so that the two are one.
    static func takeTicks(_ store: GraphStore) {
        let ticks = Glance.ticks()
        guard !ticks.isEmpty else { return }
        store.saveAll()
        for (tick, file) in ticks {
            _ = try? store.engine.setTask(path: tick.path, row: tick.row, text: tick.text, done: tick.done)
            Glance.taken(file)
        }
        store.note("widgets", "Checked off \(ticks.count) to-do\(ticks.count == 1 ? "" : "s") ticked on a widget")
    }

    private static func snapshot(_ store: GraphStore) -> Glance.Snapshot {
        let now = Date()
        // Today's note, once there is one.
        var today: Glance.Note?
        if let page = store.resolve(Days.name(now)), page.exists {
            let title = ((try? store.engine.page(path: page.path)) ?? nil)?.title ?? Days.name(now)
            today = note(store, path: page.path, title: title, rows: todayRows)
        }
        // The open to-dos, each with the name of the note it is in.
        let tasks = (try? store.engine.openTasks()) ?? []
        var names: [String: String] = [:]
        let toDos = tasks.prefix(toDosListed).map { task in
            let name = names[task.path] ?? {
                let title = ((try? store.engine.page(path: task.path)) ?? nil)?.title ?? task.path
                let label = store.label(path: task.path, title: title)
                names[task.path] = label
                return label
            }()
            return Glance.ToDo(path: task.path, row: task.row, text: task.text, words: words(task.text, store), note: name)
        }
        // Those ticked on a widget and not yet taken: still shown done.
        let ticked = Set(Glance.read().toDos.filter(\.done).map(\.id))
        let shown = toDos.map { toDo in
            var toDo = toDo
            toDo.done = ticked.contains(toDo.id)
            return toDo
        }
        // The rivers open, each with its first cards — but for those made and left empty.
        let rivers = store.rivers.filter { $0.name != nil || $0.query != nil || !$0.all.isEmpty }.map { river in
            let emblem = Emblem(title: store.title(of: river), icon: river.icon, color: river.color, letter: false)
            let cards = river.all.prefix(cardsListed).map { card in
                note(store, path: card.path, title: card.title, rows: rowsListed)
            }
            return Glance.River(id: river.id.uuidString, title: store.title(of: river), symbol: emblem.symbol, color: emblem.color?.rawValue, cards: Array(cards))
        }
        return Glance.Snapshot(written: now, day: Calendar.current.startOfDay(for: now), today: today, toDos: shown, toDosOpen: tasks.count - shown.filter(\.done).count, rivers: rivers)
    }

    private static let linked = try! NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#)

    /// A to-do's words, as read: its links by their pages' names, as a card shows them.
    private static func words(_ text: String, _ store: GraphStore) -> String {
        let source = text as NSString
        var named = ""
        var at = 0
        for match in linked.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            named += source.substring(with: NSRange(location: at, length: match.range.location - at))
            let target = source.substring(with: match.range(at: 1))
            let alias = match.range(at: 2).location == NSNotFound ? nil : source.substring(with: match.range(at: 2))
            named += alias ?? riverName(linkTarget: target) ?? store.linkLabel(target) ?? target
            at = match.range.location + match.range.length
        }
        named += source.substring(from: at)
        return inlinePlainText(text: named)
    }

    /// A note as the widgets show it: its name, its emblem, its first rows.
    private static func note(_ store: GraphStore, path: String, title: String, rows: Int) -> Glance.Note {
        let emblem = store.emblem(path: path, title: title)
        let editor = store.draft(path: path, title: title).editor
        let targets = editor.linkTargets()
        if !targets.isEmpty {
            editor.setLinkLabels(labels: Dictionary(uniqueKeysWithValues: targets.map { ($0, riverName(linkTarget: $0) ?? store.linkLabel($0) ?? $0) }))
        }
        let outline = editor.outline().prefix(rows).map { row in
            Glance.Row(index: row.index, depth: Int(row.depth), words: row.words, heading: row.heading != nil, done: row.done)
        }
        return Glance.Note(path: path, title: store.label(path: path, title: title), symbol: emblem.symbol, color: emblem.color?.rawValue, rows: Array(outline))
    }
}

/// What the app is asked to do by a link from a widget, a control, or a
/// shortcut, for the views to take up once they are there.
public enum PhoneAsk: Equatable {
    case dictate
    case toDos
}

extension PhoneSession {
    /// A `weft://` link followed: from a widget, a control, a shortcut.
    public func follow(_ url: URL) {
        guard url.scheme == "weft" else { return }
        open()
        guard let store else { return }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        switch url.host {
        case "river":
            // weft://river/<name>: that saved river, shown.
            openRiver(named: url.pathComponents.dropFirst().joined(separator: "/").removingPercentEncoding ?? "")
        case "open-river":
            guard let id = query["id"].flatMap(UUID.init(uuidString:)), let index = store.rivers.firstIndex(where: { $0.id == id }) else { return }
            store.currentRiver = index
            let river = store.rivers[index]
            if let path = query["card"], let card = river.all.first(where: { $0.path == path }) { river.reveal(card.id) }
        case "new":
            store.newNote()
        case "dictate":
            asked = .dictate
        case "today":
            store.open(name: Days.name(Date()), after: store.river.selected)
        case "todos":
            asked = .toDos
        case "note":
            guard let path = query["path"], !path.isEmpty else { return }
            let title = ((try? store.engine.page(path: path)) ?? nil)?.title ?? path
            let river = store.river
            if let card = river.all.first(where: { $0.path == path }) {
                river.reveal(card.id)
            } else {
                store.show(path: path, title: title, after: river.selected)
            }
            if let row = query["row"].flatMap(UInt32.init), let card = river.all.first(where: { $0.path == path }) {
                // Once the card is drawn: its row brought into sight.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    store.showRow(card: card.id, index: row)
                }
            }
        default:
            break
        }
    }
}
#endif
