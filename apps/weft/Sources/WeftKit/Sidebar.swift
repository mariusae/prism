#if os(macOS)
import Prism
import PrismEmblem
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
        case recent, inbox, tasks, tags, rivers
        var symbol: String {
            switch self {
            case .recent: return "clock"
            case .inbox: return "tray"
            case .tasks: return "checklist"
            case .tags: return "tag"
            case .rivers: return "square.stack"
            }
        }
        var name: String {
            switch self {
            case .recent: return "Recent"
            case .inbox: return "Inbox and Pinned"
            case .tasks: return "Tasks"
            case .tags: return "Tags"
            case .rivers: return "Saved Rivers"
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
        case .inbox: pages = query("in: Pinned") + query("in: Inbox")
        case .tasks: tasks = (try? store.engine.openTasks()) ?? []
        case .tags: tags = (try? store.engine.tags()) ?? []
        case .rivers: break
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
        case .recent, .inbox:
            ForEach(pages, id: \.path) { page in titleRow(page.label, store.emblem(page)) { open(path: page.path, title: page.title) } }
        case .rivers:
            ForEach(store.savedRivers) { saved in
                titleRow(saved.name, saved.emblem, detail: "\(saved.cards)") { withAnimation(.snappy(duration: 0.2)) { store.openSaved(saved.name) } }
                    .contextMenu { Button("Delete River", systemImage: "trash", role: .destructive) { store.deleteSaved(saved.name) } }
            }
            if store.savedRivers.isEmpty {
                Text("Name a river — click its tab's emblem — and it is saved here, on every device.").font(.callout).foregroundStyle(Color.inkSecondary)
            }
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

    private func titleRow(_ title: String, _ emblem: Emblem, detail: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                EmblemView(emblem, size: 18, quiet: Color.inkSecondary)
                Text(emblem.caption(title)).lineLimit(1)
                Spacer(minLength: 0)
                if let detail { Text(detail).font(.caption).foregroundStyle(Color.inkSecondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(path: String, title: String?) {
        let title = title ?? ((try? store.engine.page(path: path)) ?? nil)?.title ?? path
        withAnimation(.snappy(duration: 0.28)) { store.show(path: path, title: title, after: store.river.selected) }
    }

    private var foot: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack {
                Text("\(store.root.lastPathComponent) · \(store.pageCount) notes").font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if Account.shared.isAvailable, !Account.shared.isSignedIn || store.needsSignIn {
                    Button(Account.shared.isBusy ? "Signing In…" : "Sign In") { Account.shared.signIn { NotificationCenter.default.post(name: .weftSignedIn, object: nil) } }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.inkAccent)
                        .disabled(Account.shared.isBusy)
                        .help(Account.shared.failure ?? "Sign in to GitHub, to sync this graph")
                }
                // Whether other devices' writing comes in as it is pushed.
                switch store.relay {
                case .off: EmptyView()
                case .connecting: Circle().fill(Color.inkFaint).frame(width: 6, height: 6).help("Reaching the relay…")
                case .listening: Circle().fill(.green.opacity(0.8)).frame(width: 6, height: 6).help("Live: other devices' changes come in as they are made")
                case .waiting(let reason): Circle().fill(.orange.opacity(0.8)).frame(width: 6, height: 6).help("Not live just now (\(reason)); trying again. Changes still come in at each sync.")
                }
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

extension Notification.Name {
    /// The account was just signed in to: the graph is to be opened again as it.
    static let weftSignedIn = Notification.Name("WeftSignedIn")
}
#endif
