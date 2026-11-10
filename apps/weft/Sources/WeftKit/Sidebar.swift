import Prism
import SwiftUI

/// The sidebar: search, and the graph through a few lenses.
struct Sidebar: View {
    let store: GraphStore
    @Binding var searchFocus: Int
    @State private var search = ""
    @State private var hits: [SearchHit] = []
    @AppStorage("WeftSidebarLens") private var lens = Lens.recent.rawValue
    @State private var pages: [PageInfo] = []
    @State private var tasks: [TaskInfo] = []
    @State private var tags: [TagCount] = []
    @FocusState private var searching: Bool

    enum Lens: String, CaseIterable {
        case recent, inbox, tasks, wiki, tags
        var symbol: String {
            switch self {
            case .recent: return "clock"
            case .inbox: return "tray"
            case .tasks: return "checklist"
            case .wiki: return "book.closed"
            case .tags: return "tag"
            }
        }
        var name: String {
            switch self {
            case .recent: return "Recent"
            case .inbox: return "Inbox and Pinned"
            case .tasks: return "Tasks"
            case .wiki: return "Wiki"
            case .tags: return "Tags"
            }
        }
    }

    private var chosen: Lens { Lens(rawValue: lens) ?? .recent }

    var body: some View {
        VStack(spacing: 0) {
            field
            if search.trimmingCharacters(in: .whitespaces).isEmpty {
                lensBar
                List { lensRows }.listStyle(.sidebar).scrollContentBackground(.hidden)
            } else {
                List { searchRows }.listStyle(.sidebar).scrollContentBackground(.hidden)
            }
            foot
        }
        .environment(\.defaultMinListRowHeight, 24)
        .task(id: "\(store.indexRevision)|\(lens)") { load() }
        .onChange(of: search) { _, typed in
            hits = typed.trimmingCharacters(in: .whitespaces).isEmpty ? [] : ((try? store.engine.search(typed: typed, limit: 20)) ?? [])
        }
        .onChange(of: searchFocus) { _, _ in searching = true }
        .background(Color.inkPaper)
    }

    private func load() {
        switch chosen {
        case .recent: pages = query("sort: -modified\nlimit: 60")
        case .inbox: pages = query("is: pinned\nsort: pinned") + query("is: inbox\nsort: -modified")
        case .wiki: pages = query("is: wiki")
        case .tasks: tasks = (try? store.engine.openTasks()) ?? []
        case .tags: tags = (try? store.engine.tags()) ?? []
        }
    }

    private func query(_ body: String) -> [PageInfo] {
        (try? store.engine.runQuery(body: body, this: nil).pages) ?? []
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .focused($searching)
                .onSubmit { if let first = hits.first { open(path: first.path, title: first.title) } }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var lensBar: some View {
        HStack(spacing: 2) {
            ForEach(Lens.allCases, id: \.self) { item in
                Button { lens = item.rawValue } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13, weight: chosen == item ? .semibold : .regular))
                        .foregroundStyle(chosen == item ? Color.inkAccent : Color.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(Capsule().fill(chosen == item ? Color.inkAccent.opacity(0.14) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.name)
            }
        }
        .padding(3)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var lensRows: some View {
        switch chosen {
        case .recent, .inbox, .wiki:
            ForEach(pages, id: \.path) { page in titleRow(page.title, symbol(forKind: page.kind)) { open(path: page.path, title: page.title) } }
        case .tasks:
            ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Button {
                        _ = try? store.engine.setTask(path: task.path, row: task.row, text: task.text, done: true)
                    } label: { Image(systemName: "circle").font(.callout).foregroundStyle(Color.inkSecondary) }
                    .buttonStyle(.plain)
                    Button { open(path: task.path, title: nil) } label: {
                        Text(inlinePlainText(text: task.text)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        case .tags:
            ForEach(tags, id: \.tag) { tag in
                Button { store.open(name: tag.tag) } label: {
                    HStack {
                        Text(tag.tag).font(.callout.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 2)
                            .foregroundStyle(Color.inkAccent).background(Capsule().fill(Color.inkAccent.opacity(0.12)))
                        Spacer()
                        Text("\(tag.pages)").font(.caption).foregroundStyle(Color.inkSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var searchRows: some View {
        ForEach(hits, id: \.path) { hit in
            Button { open(path: hit.path, title: hit.title) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title).lineLimit(1)
                    Text(hit.snippet.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        if hits.isEmpty { Text("Nothing found").foregroundStyle(Color.inkSecondary) }
    }

    private func titleRow(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.caption).foregroundStyle(Color.inkSecondary).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(path: String, title: String?) {
        let title = title ?? ((try? store.engine.page(path: path)) ?? nil)?.title ?? path
        withAnimation(.snappy(duration: 0.28)) { store.river.open(Card(path: path, title: title), after: store.river.selected) }
        store.rememberRivers()
    }

    private var foot: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack {
                Text("\(store.root.lastPathComponent) · \(store.pageCount) pages").font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { store.syncNow() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .rotationEffect(.degrees(store.isSyncing ? 360 : 0))
                        .animation(store.isSyncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.isSyncing)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.inkSecondary)
                .help(store.syncNote ?? "Sync Now")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}
