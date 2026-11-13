#if os(macOS)
import Prism
import PrismEmblem
import SwiftUI

/// Find a page, or name a new one: the one place everything is gone to
/// from. With nothing typed it is the graph through a few lenses — what
/// was written last, what is pinned, what is to do; with something typed,
/// the pages of that name, the pages saying it, and a new page so named.
struct QuickOpen: View {
    let store: GraphStore
    @Binding var isShown: Bool
    /// What was typed to bring it up, if a key brought it up.
    var seed: String = ""
    /// Whether only the river shown is looked in: its notes, by name and by what they say.
    var inRiver = false
    @State private var typed = ""
    @State private var sections: [Section] = []
    @State private var chosen = 0
    @AppStorage("WeftLens") private var lens = Lens.recent.rawValue
    @FocusState private var focused: Bool
    /// Where the pointer lay when the list was last drawn or arrowed through: until it moves from there, it chooses nothing.
    @State private var still = NSEvent.mouseLocation

    enum Lens: String, CaseIterable {
        case recent, pinned, tasks, tags
        var symbol: String {
            switch self {
            case .recent: return "clock"
            case .pinned: return "tray"
            case .tasks: return "checklist"
            case .tags: return "number"
            }
        }
        var name: String {
            switch self {
            case .recent: return "Recent"
            case .pinned: return "Pinned and Inbox"
            case .tasks: return "Tasks"
            case .tags: return "Tags"
            }
        }
    }

    struct Row: Identifiable {
        var id: String
        var symbol: String
        var name: String
        var detail: String = ""
        var snippet: String?
        /// For a page: what stands for it, in place of the symbol.
        var emblem: Emblem?
        var open: @MainActor (GraphStore) -> Void
    }

    struct Section: Identifiable {
        var id: String
        var title: String?
        var rows: [Row]
    }

    private var rows: [Row] { sections.flatMap(\.rows) }
    /// What the list needs: it is as tall as what it holds, to a limit.
    private var listHeight: CGFloat {
        let rows = sections.flatMap(\.rows)
        let tall = rows.reduce(CGFloat(0)) { $0 + ($1.snippet == nil ? 34 : 58) }
        return 16 + tall + CGFloat(sections.filter { $0.title != nil }.count) * 28 + (rows.isEmpty ? 46 : 0)
    }
    private var isBrowsing: Bool { typed.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(Color.inkSecondary)
                TextField(inRiver ? "Find in \(store.title(of: store.river))" : "Find a note, or name a new one", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.inkText)
                    .focused($focused)
                    .onSubmit { go() }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.tab) { cycleLens() }
                    .onKeyPress(.escape) {
                        isShown = false
                        return .handled
                    }
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            if isBrowsing, !inRiver { lensBar }
            Rectangle().fill(Color.inkRule).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: a few dozen rows at most, and a lazy stack keeps a row it has
                    // drawn as it was while the row's place in the list stays the same.
                    VStack(alignment: .leading, spacing: 0) {
                        // Each row is known by its place in the list — never by what it is of, which two rows may share.
                        ForEach(Array(sections.enumerated()), id: \.offset) { at, section in
                            let start = sections[..<at].reduce(0) { $0 + $1.rows.count }
                            if let title = section.title {
                                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(Color.inkFaint)
                                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                            }
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { offset, row in rowView(row, at: start + offset).id(start + offset) }
                        }
                        if rows.isEmpty {
                            Text(isBrowsing ? "Nothing here yet" : "Nothing found").font(.callout).foregroundStyle(Color.inkFaint).padding(14)
                        }
                    }
                    .padding(8)
                }
                .frame(height: min(listHeight, 440))
                .onChange(of: chosen) { _, index in
                    if rows.indices.contains(index) { proxy.scrollTo(index) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.inkPaper))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.inkRule))
        .shadow(color: .black.opacity(0.20), radius: 24, y: 10)
        .frame(maxWidth: 620)
        .padding(.horizontal, 24)
        .onAppear {
            focused = true
            still = NSEvent.mouseLocation
            find()
            // What was typed to bring it up goes in once the field has the
            // caret, so that the next key adds to it rather than replaces it.
            if !seed.isEmpty { DispatchQueue.main.async { typed = seed } }
        }
        .onChange(of: typed) { _, _ in find() }
        .onChange(of: lens) { _, _ in find() }
        .onChange(of: store.indexRevision) { _, _ in find() }
    }

    private var lensBar: some View {
        HStack(spacing: 4) {
            ForEach(Lens.allCases, id: \.self) { item in
                let on = lens == item.rawValue
                Button { lens = item.rawValue } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold))
                        Text(item.name).font(.system(size: 12, weight: on ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .foregroundStyle(on ? Color.inkAccent : Color.inkSecondary)
                    .background(Capsule().fill(on ? Color.inkAccent.opacity(0.14) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("⇥").font(.system(size: 11)).foregroundStyle(Color.inkFaint)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func rowView(_ row: Row, at index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            EmblemView(row.emblem ?? Emblem(symbol: row.symbol), size: 20, style: row.emblem == nil ? .plain : .tile, quiet: Color.inkSecondary)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.emblem?.caption(row.name) ?? row.name).font(.system(size: 14.5)).foregroundStyle(Color.inkText).lineLimit(1)
                if let snippet = row.snippet {
                    Text(snippet).font(.system(size: 12)).foregroundStyle(Color.inkSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            Text(row.detail).font(.system(size: 12)).foregroundStyle(Color.inkFaint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, row.snippet == nil ? 0 : 6)
        .frame(minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(index == chosen ? Color.inkHover : .clear))
        .contentShape(Rectangle())
        // The pointer chooses a row by moving onto it — not by lying where the list
        // happens to be drawn, or where it scrolls to under the arrow keys.
        .onHover { if $0, NSEvent.mouseLocation != still { chosen = index } }
        .onTapGesture {
            chosen = index
            go()
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        still = NSEvent.mouseLocation
        chosen = (chosen + step + rows.count) % rows.count
        return .handled
    }

    private func cycleLens() -> KeyPress.Result {
        guard isBrowsing, let index = Lens.allCases.firstIndex(where: { $0.rawValue == lens }) else { return .ignored }
        lens = Lens.allCases[(index + 1) % Lens.allCases.count].rawValue
        return .handled
    }

    private func go() {
        let rows = rows
        guard rows.indices.contains(chosen) else { return }
        isShown = false
        withAnimation(.snappy(duration: 0.28)) { rows[chosen].open(store) }
    }

    // MARK: What it finds

    private func page(_ page: PageInfo, detail: String? = nil, snippet: String? = nil) -> Row {
        Row(id: "page:\(page.path)\(snippet == nil ? "" : ":text")", symbol: symbol(forKind: page.kind), name: page.label, detail: detail ?? when(page), snippet: snippet, emblem: snippet == nil ? store.emblem(page) : nil) {
            $0.open(page: page, after: $0.river.selected)
        }
    }

    private func when(_ page: PageInfo) -> String {
        guard let modified = page.modified else { return "" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: Date(timeIntervalSince1970: TimeInterval(modified)), relativeTo: Date())
    }

    private func query(_ body: String) -> [PageInfo] {
        (try? store.engine.runQuery(body: body, this: nil).pages) ?? []
    }

    /// A card of the river shown, to go to where it stands.
    private func card(_ card: Card, snippet: String? = nil) -> Row {
        let label = store.label(path: card.path, title: card.title)
        return Row(id: "card:\(card.id)\(snippet == nil ? "" : ":text")", symbol: "doc.text", name: label, detail: snippet == nil ? "In this river" : "", snippet: snippet, emblem: snippet == nil ? store.emblem(path: card.path, title: card.title) : nil) { store in
            withAnimation(.snappy(duration: 0.24)) { store.river.reveal(card.id) }
        }
    }

    /// The rivers called what was typed: those open first — gone to in
    /// their tabs — then the saved ones that are not, opened in new tabs.
    private func rivers(named name: String) -> [Row] {
        var rows: [Row] = []
        var shown = Set<String>()
        for (index, river) in store.rivers.enumerated() where index != store.currentRiver {
            let title = store.title(of: river)
            guard Self.names(title, name) else { continue }
            if let saved = river.name { shown.insert(saved) }
            rows.append(Row(id: "river:\(river.id)", symbol: "square.stack", name: title, detail: "Open River",
                            emblem: Emblem(title: title, icon: river.icon, color: river.color)) { store in
                guard let index = store.rivers.firstIndex(where: { $0.id == river.id }) else { return }
                store.currentRiver = index
            })
        }
        if let current = store.river.name { shown.insert(current) }
        for saved in store.savedRivers where !shown.contains(saved.name) && Self.names(saved.name, name) {
            rows.append(Row(id: "saved:\(saved.name)", symbol: "square.stack", name: saved.name,
                            detail: saved.isQuery ? "Query River" : "River · \(saved.cards) \(saved.cards == 1 ? "card" : "cards")", emblem: saved.emblem) { store in
                store.openSaved(saved.name)
            })
        }
        return Array(rows.prefix(4))
    }

    /// Whether every word typed begins a word of a name.
    private static func names(_ label: String, _ typed: String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter && !$0.isNumber }
        return typed.lowercased().split { !$0.isLetter && !$0.isNumber }.allSatisfy { word in words.contains { $0.hasPrefix(word) } }
    }

    /// The river's own notes: all of them, or those named or saying what was typed.
    private func findInRiver(_ name: String) -> [Section] {
        let cards = store.river.all
        guard !name.isEmpty else { return [Section(id: "river", title: nil, rows: cards.map { card($0) })] }
        var found: [Section] = []
        let named = cards.filter { Self.names(store.label(path: $0.path, title: $0.title), name) }
        if !named.isEmpty { found.append(Section(id: "river", title: nil, rows: named.map { card($0) })) }
        // What they say: as written now, saved or not.
        let words = name.lowercased().split(separator: " ")
        let saying: [Row] = cards.compactMap { held in
            let text = store.draft(path: held.path, title: held.title).markdown
            let lines = text.split(separator: "\n").map(String.init)
            guard words.allSatisfy({ text.lowercased().contains($0) }), let line = lines.first(where: { line in words.contains { line.lowercased().contains($0) } }) else { return nil }
            // Its words, without the marks a line opens with.
            let words = line.replacingOccurrences(of: #"^\s*(#{1,6}\s+|>\s?|([-*+]|\d+[.)])\s+(\[.\]\s+)?)"#, with: "", options: .regularExpression)
            return card(held, snippet: inlinePlainText(text: words))
        }
        if !saying.isEmpty { found.append(Section(id: "text", title: "In Text", rows: saying)) }
        return found
    }

    /// Finds again — and, where that finds the same rows (the graph moved, and nothing here did), leaves the row chosen chosen.
    private func find() {
        let before = rows.map(\.id)
        let kept = chosen
        search()
        if rows.map(\.id) == before { chosen = min(kept, max(rows.count - 1, 0)) }
        still = NSEvent.mouseLocation
    }

    private func search() {
        let name = typed.trimmingCharacters(in: .whitespaces)
        var found: [Section] = []
        if inRiver {
            sections = findInRiver(name)
            chosen = 0
            return
        }
        if name.isEmpty {
            switch Lens(rawValue: lens) ?? .recent {
            case .recent:
                let today = Self.day(Date())
                let todayRow = Row(id: "today", symbol: "calendar", name: "Today", detail: today) { $0.open(name: today, after: $0.river.selected) }
                found.append(Section(id: "recent", title: nil, rows: [todayRow] + query("sort: -modified\nlimit: 30").map { page($0) }))
            case .pinned:
                let pinned = query("is: pinned\nsort: pinned")
                let inbox = query("is: inbox\nsort: -modified")
                if !pinned.isEmpty { found.append(Section(id: "pinned", title: "Pinned", rows: pinned.map { page($0) })) }
                if !inbox.isEmpty { found.append(Section(id: "inbox", title: "Inbox", rows: inbox.map { page($0, detail: "Inbox") })) }
            case .tasks:
                let pages = query("is: task\nsort: -modified").filter { ((try? store.engine.fields(path: $0.path)) ?? []).contains { $0.key == "task" && $0.values.first == "todo" } }
                if !pages.isEmpty { found.append(Section(id: "todo", title: "To-Do Notes", rows: pages.map { page($0, detail: "To do") })) }
                let tasks = (try? store.engine.openTasks()) ?? []
                let rows = tasks.prefix(60).enumerated().map { index, task in
                    Row(id: "task:\(index)", symbol: "circle", name: inlinePlainText(text: task.text), detail: Self.pageName(task.path)) { store in
                        let title = ((try? store.engine.page(path: task.path)) ?? nil)?.title ?? task.path
                        store.show(path: task.path, title: title, after: store.river.selected)
                        store.rememberRivers()
                    }
                }
                if !rows.isEmpty { found.append(Section(id: "tasks", title: "Tasks", rows: rows)) }
            case .tags:
                let tags = (try? store.engine.tags()) ?? []
                found.append(Section(id: "tags", title: nil, rows: tags.map { tag in
                    Row(id: "tag:\(tag.tag)", symbol: "number", name: tag.tag, detail: "\(tag.pages)") { $0.open(name: tag.tag, after: $0.river.selected) }
                }))
            }
        } else {
            var top: [Row] = []
            // A day or a week asked for in words: today, last tuesday, next week, Jan 3.
            if let when = store.spoken(name) {
                top.append(Row(id: "day:\(when.name)", symbol: "calendar", name: when.said, detail: when.name) { $0.open(name: when.name, after: $0.river.selected) })
            }
            // The river's own notes come first: what is open is what is most often meant.
            let here = store.river.all.filter { Self.names(store.label(path: $0.path, title: $0.title), name) }.prefix(4)
            top += here.map { card($0) }
            // Rivers called so: the tab that has one, or a saved one opened in a tab of its own.
            top += rivers(named: name)
            let open = Set(here.map(\.path))
            let pages = ((try? store.engine.complete(typed: name, limit: 8)) ?? []).filter { !open.contains($0.path) }
            // Notes of one title are told apart by their files' names.
            let shared = store.sharedLabels(among: pages)
            top += pages.map { found in
                page(found, detail: shared.contains(found.label) ? linkName(path: found.path).map { "\($0) · \(when(found))" } : nil)
            }
            let key = nameKey(name: name)
            if !pages.contains(where: { nameKey(name: $0.label) == key || nameKey(name: $0.title) == key }), !here.contains(where: { nameKey(name: store.label(path: $0.path, title: $0.title)) == key }), store.resolve(name)?.exists != true {
                top.append(Row(id: "new", symbol: "plus", name: "New note “\(name)”", detail: "↩") { _ = $0.newPage(title: name) })
            }
            found.append(Section(id: "names", title: nil, rows: top))
            // The pages saying it, after the pages named it.
            let named = Set(pages.map(\.path)).union(open)
            let hits = ((try? store.engine.search(typed: name, limit: 12)) ?? []).filter { !named.contains($0.path) }
            if !hits.isEmpty {
                found.append(Section(id: "text", title: "In Text", rows: hits.map { hit in
                    Row(id: "text:\(hit.path)", symbol: "text.magnifyingglass", name: hit.title, snippet: hit.snippet.replacingOccurrences(of: "\n", with: " ")) { store in
                        // Found by what it says: shown narrowed to where it says it, the words marked.
                        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                        let river = store.river
                        river.open(Card(path: hit.path, title: hit.title, lens: .words(words)), after: river.selected)
                        store.rememberRivers()
                    }
                }))
            }
        }
        sections = found
        chosen = 0
    }

    static func pageName(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "").replacingOccurrences(of: ".md", with: "")
    }

    static func day(_ date: Date) -> String {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }
}
#endif
