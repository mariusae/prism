import Prism
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
    @State private var typed = ""
    @State private var sections: [Section] = []
    @State private var chosen = 0
    @AppStorage("WeftLens") private var lens = Lens.recent.rawValue
    @FocusState private var focused: Bool

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
                TextField("Find a page, or name a new one", text: $typed)
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
            if isBrowsing { lensBar }
            Rectangle().fill(Color.inkRule).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            if let title = section.title {
                                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(Color.inkFaint)
                                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                            }
                            ForEach(section.rows) { row in rowView(row) }
                        }
                        if rows.isEmpty {
                            Text(isBrowsing ? "Nothing here yet" : "Nothing found").font(.callout).foregroundStyle(Color.inkFaint).padding(14)
                        }
                    }
                    .padding(8)
                }
                .frame(height: min(listHeight, 440))
                .onChange(of: chosen) { _, index in
                    if rows.indices.contains(index) { proxy.scrollTo(rows[index].id) }
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

    private func rowView(_ row: Row) -> some View {
        let index = rows.firstIndex(where: { $0.id == row.id }) ?? -1
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: row.symbol).font(.system(size: 12)).foregroundStyle(Color.inkSecondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 14.5)).foregroundStyle(Color.inkText).lineLimit(1)
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
        .onHover { if $0 { chosen = index } }
        .onTapGesture {
            chosen = index
            go()
        }
        .id(row.id)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
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
        Row(id: "page:\(page.path)\(snippet == nil ? "" : ":text")", symbol: symbol(forKind: page.kind), name: page.title, detail: detail ?? when(page), snippet: snippet) {
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

    private func find() {
        let name = typed.trimmingCharacters(in: .whitespaces)
        var found: [Section] = []
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
                if !pages.isEmpty { found.append(Section(id: "todo", title: "To-Do Pages", rows: pages.map { page($0, detail: "To do") })) }
                let tasks = (try? store.engine.openTasks()) ?? []
                let rows = tasks.prefix(60).enumerated().map { index, task in
                    Row(id: "task:\(index)", symbol: "circle", name: inlinePlainText(text: task.text), detail: Self.pageName(task.path)) { store in
                        let title = ((try? store.engine.page(path: task.path)) ?? nil)?.title ?? task.path
                        store.river.open(Card(path: task.path, title: title), after: store.river.selected)
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
            if let day = Self.spoken(name) {
                top.append(Row(id: "day:\(day)", symbol: "calendar", name: day, detail: "Day") { $0.open(name: day, after: $0.river.selected) })
            }
            let pages = (try? store.engine.complete(typed: name, limit: 8)) ?? []
            top += pages.map { page($0) }
            let key = nameKey(name: name)
            if !pages.contains(where: { nameKey(name: $0.title) == key }), store.resolve(name)?.exists != true {
                top.append(Row(id: "new", symbol: "plus", name: "New page “\(name)”", detail: "↩") { _ = $0.newPage(title: name) })
            }
            found.append(Section(id: "names", title: nil, rows: top))
            // The pages saying it, after the pages named it.
            let named = Set(pages.map(\.path))
            let hits = ((try? store.engine.search(typed: name, limit: 12)) ?? []).filter { !named.contains($0.path) }
            if !hits.isEmpty {
                found.append(Section(id: "text", title: "In Text", rows: hits.map { hit in
                    Row(id: "text:\(hit.path)", symbol: "text.magnifyingglass", name: hit.title, snippet: hit.snippet.replacingOccurrences(of: "\n", with: " ")) { store in
                        store.river.open(Card(path: hit.path, title: hit.title), after: store.river.selected)
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

    /// A day by a few words: today, yesterday, tomorrow, or its date.
    static func spoken(_ words: String) -> String? {
        let calendar = Calendar.current
        switch words.lowercased() {
        case "today": return day(Date())
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: Date()).map(day)
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: Date()).map(day)
        default:
            let parts = words.split(separator: "-")
            return parts.count == 3 && parts[0].count == 4 && parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) ? words : nil
        }
    }
}
