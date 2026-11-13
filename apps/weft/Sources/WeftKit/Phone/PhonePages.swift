#if os(iOS)
import Prism
import PrismEditor
import PrismEmblem
import SwiftUI
import UIKit

/// The start page: over the whole screen, the graph through a few
/// lenses, and at its foot — where the thumb is — the field that finds a
/// note or names a new one.
struct StartPage: View {
    let store: GraphStore
    let mode: PhoneState.Start
    let state: PhoneState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("WeftStartTab") private var tab = Tab.recent.rawValue
    @State private var typed = ""
    @State private var pages: [PageInfo] = []
    @State private var tasks: [TaskInfo] = []
    @State private var names: [PageInfo] = []
    @State private var hits: [SearchHit] = []
    /// When the next note put off from reading comes back.
    @State private var nextToRead: Date?
    @FocusState private var typing: Bool

    enum Tab: String, CaseIterable {
        case rivers, recent, inbox, reading, tasks, wiki
        var symbol: String {
            switch self {
            case .rivers: return "square.stack.3d.up"
            case .recent: return "clock"
            case .inbox: return "tray"
            case .reading: return "eyeglasses"
            case .tasks: return "checklist"
            case .wiki: return "book.closed"
            }
        }
        var name: String {
            switch self {
            case .rivers: return "Rivers"
            case .recent: return "Recent"
            case .inbox: return "Inbox and Pinned"
            case .reading: return "Reading"
            case .tasks: return "Tasks"
            case .wiki: return "Wiki"
            }
        }
    }

    private var chosen: Tab { Tab(rawValue: tab) ?? .recent }
    private var asked: String { typed.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            if asked.isEmpty { tabs }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if asked.isEmpty { browsing } else { finding }
                }
                // Each lens its own list: a row of one is never kept to stand for a row of another.
                .id(asked.isEmpty ? tab : "finding")
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) { field }
        .background(Color.inkPage.ignoresSafeArea())
        .foregroundStyle(Color.inkText)
        .task(id: "\(store.indexRevision)|\(tab)") { load() }
        .onChange(of: typed) { _, _ in find() }
        .onAppear {
            guard mode == .add else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { typing = true }
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { one in
                Button { tab = one.rawValue } label: {
                    Image(systemName: one.symbol)
                        .font(.system(size: 17, weight: chosen == one ? .semibold : .regular))
                        .foregroundStyle(chosen == one ? Color.inkAccent : Color.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Capsule().fill(Color.inkAccent.opacity(chosen == one ? 0.14 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(one.name)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var field: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.inkSecondary)
                TextField(mode == .add ? "Add a note to \(store.title(of: store.river))" : "Find a note, or name a new one", text: $typed)
                    .focused($typing)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { submit() }
                if !typed.isEmpty { Button { typed = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.inkFaint) }.buttonStyle(.plain) }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .glassEffect(.regular.interactive(), in: .capsule)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 48, height: 48) }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .foregroundStyle(Color.inkAccent)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    // MARK: Looking around

    @ViewBuilder private var browsing: some View {
        switch chosen {
        case .rivers: rivers
        case .recent, .inbox, .wiki:
            ForEach(pages, id: \.path) { page in pageRow(page) }
            if pages.isEmpty { empty("Nothing here yet") }
        case .reading:
            // The reading queue: the inbox's notes with a page to read, oldest first.
            ForEach(pages, id: \.path) { page in readingRow(page) }
            if pages.isEmpty {
                VStack(spacing: 4) {
                    Text("All read").foregroundStyle(Color.inkSecondary)
                    Text(ReadingQueue.restDetail(next: nextToRead)).font(.caption).foregroundStyle(Color.inkFaint).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            }
        case .tasks:
            ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button { _ = try? store.engine.setTask(path: task.path, row: task.row, text: task.text, done: true) } label: {
                        Image(systemName: "circle").font(.system(size: 19)).foregroundStyle(Color.inkSecondary)
                    }
                    .buttonStyle(.plain)
                    Button { open(path: task.path, title: nil) } label: {
                        Text(inlinePlainText(text: task.text)).font(.system(size: 17)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            if tasks.isEmpty { empty("Nothing to do") }
        }
    }

    private var rivers: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 18) {
            ForEach(store.savedRivers) { saved in
                let isOpen = store.rivers.contains { $0.name == saved.name }
                Button {
                    store.openSaved(saved.name)
                    dismiss()
                } label: {
                    VStack(spacing: 6) {
                        EmblemView(saved.emblem, size: 64, quiet: Color.inkSecondary)
                            .overlay(alignment: .topTrailing) { if isOpen { Circle().fill(Color.inkAccent).frame(width: 9, height: 9).offset(x: 2, y: -2) } }
                        Text(saved.name).font(.caption).lineLimit(1).truncationMode(.tail).foregroundStyle(Color.inkText)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open", systemImage: "arrow.up.forward.square") { store.openSaved(saved.name); dismiss() }
                    Button("Copy Link", systemImage: "link") { UIPasteboard.general.string = "[[rivers/\(saved.name)]]" }
                    Button("Delete River", systemImage: "trash", role: .destructive) { store.deleteSaved(saved.name) }
                }
            }
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { store.queryAsk = .new }
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 26)).foregroundStyle(Color.inkSecondary)
                        .frame(width: 64, height: 64)
                        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Color.inkRule, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    Text("Query River").font(.caption).foregroundStyle(Color.inkSecondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 10)
    }

    private func empty(_ said: String) -> some View {
        Text(said).foregroundStyle(Color.inkSecondary).frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func pageRow(_ page: PageInfo, snippet: String? = nil, named: Bool = false) -> some View {
        Button { open(path: page.path, title: page.title) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                EmblemView(snippet == nil || named ? store.emblem(page) : Emblem(symbol: "text.magnifyingglass"), size: 24, style: .plain, quiet: Color.inkSecondary)
                    .frame(width: 28)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.emblem(page).caption(GraphStore.shown(page))).font(.system(size: 17)).lineLimit(1)
                    if let snippet {
                        Text(snippet).font(.system(size: 14)).foregroundStyle(Color.inkSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if snippet == nil || named, let modified = page.modified {
                    Text(Date(timeIntervalSince1970: TimeInterval(modified)), format: .relative(presentation: .named)).font(.system(size: 13)).foregroundStyle(Color.inkFaint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A note saved to read: tapped, its card is opened and its page read
    /// over the river. Swiped aside, or held: done with, or put off.
    private func readingRow(_ page: PageInfo) -> some View {
        Button { read(page) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                EmblemView(Emblem(symbol: "doc.richtext"), size: 24, style: .plain, quiet: Color.inkSecondary)
                    .frame(width: 28)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                Text(GraphStore.shown(page)).font(.system(size: 17)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.inkPage)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Done", systemImage: "checkmark") { finish(page, nil) }
            Menu("Later", systemImage: "clock") {
                ForEach(ReadingQueue.Snooze.allCases, id: \.self) { snooze in
                    Button(snooze.title, systemImage: snooze.symbol) { finish(page, snooze) }
                }
            }
        }
        .modifier(CardSwipe(leading: [], trailing: [
            SwipeAction(name: "Done", symbol: "checkmark", tint: .green) { finish(page, nil) },
            SwipeAction(name: "Later", symbol: "clock", tint: .orange) { finish(page, .tomorrow) },
        ], enabled: true))
    }

    private func read(_ page: PageInfo) {
        let river = store.river
        withAnimation(.snappy(duration: 0.28)) { store.show(path: page.path, title: page.title, after: river.selected) }
        dismiss()
        // Once the start page has gone: one thing is shown over the river at a time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { river.reading = River.Place(path: page.path, title: page.title) }
    }

    private func finish(_ page: PageInfo, _ snooze: ReadingQueue.Snooze?) {
        withAnimation(.snappy(duration: 0.25)) {
            store.finishReading(path: page.path, title: page.title, snooze: snooze)
            load()
        }
    }

    // MARK: Finding

    @ViewBuilder private var finding: some View {
        // A day or a week asked for in words: today, last tuesday, next week, Jan 3.
        if let when = store.spoken(asked) {
            Button { open(name: when.name) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "calendar").font(.system(size: 17)).foregroundStyle(Color.inkSecondary).frame(width: 28)
                    Text(when.said).font(.system(size: 17)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(when.name).font(.system(size: 13)).foregroundStyle(Color.inkFaint)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        // Notes of one title are told apart by their files' names.
        let shared = store.sharedLabels(among: names)
        ForEach(names, id: \.path) { page in pageRow(page, snippet: shared.contains(page.label) ? linkName(path: page.path) : nil, named: true) }
        if !store.leadsSomewhere(asked) {
            Button {
                withAnimation(.snappy(duration: 0.28)) { _ = store.newPage(title: asked) }
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 17, weight: .medium)).foregroundStyle(Color.inkAccent).frame(width: 28)
                    Text("New Note “\(asked)”").font(.system(size: 17))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        let text = hits.filter { hit in !names.contains { $0.path == hit.path } }
        if !text.isEmpty {
            Text("IN TEXT").font(.caption.weight(.semibold)).foregroundStyle(Color.inkSecondary).padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 2)
            ForEach(text, id: \.path) { hit in
                if let page = (try? store.engine.page(path: hit.path)) ?? nil {
                    pageRow(page, snippet: hit.snippet.replacingOccurrences(of: "\n", with: " "))
                }
            }
        }
    }

    private func load() {
        let query = { (body: String) in (try? store.engine.runQuery(body: body, this: nil).pages) ?? [] }
        switch chosen {
        case .rivers: break
        case .recent: pages = query("sort: -modified\nlimit: 40")
        case .inbox: pages = query("is: pinned\nsort: pinned") + query("is: inbox\nsort: -modified")
        case .wiki: pages = query("is: wiki")
        case .reading: (pages, nextToRead) = store.readingQueue()
        case .tasks: tasks = (try? store.engine.openTasks()) ?? []
        }
    }

    private func find() {
        guard !asked.isEmpty else {
            names = []
            hits = []
            return
        }
        names = (try? store.engine.complete(typed: asked, limit: 8)) ?? []
        hits = (try? store.engine.search(typed: asked, limit: 12)) ?? []
    }

    private func submit() {
        guard !asked.isEmpty else { return }
        if let when = store.spoken(asked) { return open(name: when.name) }
        if let first = names.first { return open(path: first.path, title: first.title) }
        withAnimation(.snappy(duration: 0.28)) { store.open(name: asked, after: store.river.selected) }
        dismiss()
    }

    /// Goes to the page a name leads to: a day's, a week's.
    private func open(name: String) {
        withAnimation(.snappy(duration: 0.28)) { store.open(name: name, after: store.river.selected) }
        dismiss()
    }

    private func open(path: String, title: String?) {
        let title = title ?? ((try? store.engine.page(path: path)) ?? nil)?.title ?? path
        withAnimation(.snappy(duration: 0.28)) { store.show(path: path, title: title, after: store.river.selected) }
        dismiss()
    }
}

/// Every river open, as Safari shows its tabs: a tile each, with its first cards.
struct RiverOverview: View {
    let store: GraphStore
    let state: PhoneState
    @Environment(\.dismiss) private var dismiss
    /// The river held and carried, while it is.
    @State private var carried: River.ID?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(Array(store.rivers.enumerated()), id: \.element.id) { index, river in
                    let current = index == store.currentRiver
                    Button {
                        store.currentRiver = index
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                let emblem = Emblem(title: store.title(of: river), icon: river.icon, color: river.color, letter: false)
                                if emblem.isShown { EmblemView(emblem, size: 15, style: .plain, quiet: Color.inkSecondary) }
                                Text(store.title(of: river)).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 24)
                            }
                            ForEach(river.all.prefix(5)) { card in
                                Text(store.label(path: card.path, title: card.title)).font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.inkCard))
                            }
                            if river.all.count > 5 { Text("and \(river.all.count - 5) more").font(.caption2).foregroundStyle(Color.inkFaint).padding(.leading, 8) }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(height: 190, alignment: .top)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.inkPaper))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(current ? Color.inkAccent : Color.inkRule, lineWidth: current ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .opacity(carried == river.id ? 0.4 : 1)
                    // Held and carried, as Safari's tabs are: the others make room as it passes over them.
                    .onDrag {
                        carried = river.id
                        return NSItemProvider(object: river.id.uuidString as NSString)
                    } preview: {
                        Text(store.title(of: river)).font(.subheadline.weight(.semibold)).lineLimit(1)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.inkPaper))
                    }
                    .onDrop(of: [.text], delegate: RiverCarry(target: river.id, store: store, carried: $carried))
                    .overlay(alignment: .topTrailing) {
                        if store.rivers.count > 1 {
                            Button { withAnimation(.snappy(duration: 0.25)) { store.closeRiver(at: index) } } label: {
                                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.inkSecondary)
                                    .frame(width: 28, height: 28).background(Circle().fill(Color.inkHover))
                                    // A finger's width to press, all of it: not only the mark.
                                    .frame(width: 52, height: 52).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
            .animation(.snappy(duration: 0.22), value: store.rivers.map(\.id))
        }
        // Let go of anywhere — over no tile — the river is no longer carried.
        .onDrop(of: [.text], isTargeted: nil) { _ in
            carried = nil
            store.rememberRivers()
            return false
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    store.newRiver()
                    dismiss()
                } label: { Image(systemName: "plus").font(.system(size: 20, weight: .medium)).frame(width: 48, height: 48) }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                Text("\(store.rivers.count) \(store.rivers.count == 1 ? "River" : "Rivers")").font(.callout.weight(.semibold)).foregroundStyle(Color.inkText)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .glassEffect(.regular, in: .capsule)
                Button { dismiss() } label: { Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold)).frame(width: 48, height: 48) }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Color.inkAccent).interactive(), in: .circle)
                    .foregroundStyle(.white)
            }
            .foregroundStyle(Color.inkAccent)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
        .background(Color.inkPage.ignoresSafeArea())
        .foregroundStyle(Color.inkText)
    }
}

/// Settings: how notes are set, who is signed in, and what syncing has been doing.
struct PhoneSettings: View {
    let store: GraphStore
    private let account = Account.shared
    @Environment(\.dismiss) private var dismiss

    private static let faces: [(face: EditorFace, name: String)] = [(.sans, "Sans"), (.serif, "Serif"), (.rounded, "Rounded"), (.mono, "Mono")]
    private static let clock: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "HH:mm:ss"
        return format
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    Picker("Typeface", selection: Binding(get: { TextSettings.face }, set: { TextSettings.face = $0 })) {
                        ForEach(Self.faces, id: \.face) { Text($0.name).tag($0.face) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("A").font(.system(size: 13))
                        Slider(value: Binding(get: { Double(TextSettings.size) }, set: { TextSettings.size = CGFloat($0) }), in: Double(TextSettings.range.lowerBound)...Double(TextSettings.range.upperBound), step: 1)
                        Text("A").font(.system(size: 22))
                    }
                    Text("Notes are set like this, at \(Int(TextSettings.size)) points.").font(.system(size: TextSettings.size, design: TextSettings.design))
                }
                Section("Account") {
                    if account.isSignedIn {
                        LabeledContent("GitHub", value: account.login ?? "Signed in")
                        if let install = account.installURL { Link("Choose Repositories on GitHub…", destination: install) }
                        Button("Sign Out and Leave This Graph", role: .destructive) {
                            dismiss()
                            PhoneSession.shared.leave()
                        }
                    } else if account.isAvailable {
                        Button("Sign In to GitHub…") { account.signIn { PhoneSession.shared.reopen() } }
                    } else {
                        Text("This build names no GitHub App.").foregroundStyle(.secondary)
                    }
                }
                Section("Sync") {
                    LabeledContent("Graph", value: store.root.lastPathComponent)
                    LabeledContent("Remote", value: store.remote ?? "None")
                    LabeledContent("Last sync", value: store.lastSync.map { $0.formatted(date: .omitted, time: .standard) } ?? "None yet")
                    LabeledContent("Relay", value: relaySaid)
                    LabeledContent("Last push heard", value: store.lastPush.map { $0.formatted(date: .omitted, time: .standard) } ?? "None")
                    Button("Sync Now") { store.syncNow() }.disabled(store.isSyncing)
                    NavigationLink("Log") { log }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var relaySaid: String {
        switch store.relay {
        case .off: return "Not listening"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .waiting(let reason): return "Waiting: \(reason)"
        }
    }

    private var log: some View {
        List(store.log.reversed()) { line in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.clock.string(from: line.at))  \(line.kind)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Text(line.text).font(.caption.monospaced()).foregroundStyle(line.text.contains("FAILED") || line.text.contains("Could not") ? Color.red : Color.primary)
            }
        }
        .navigationTitle("Sync Log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Copy") { UIPasteboard.general.string = store.log.map { "\(Self.clock.string(from: $0.at)) \($0.kind) \($0.text)" }.joined(separator: "\n") }
            }
        }
    }
}
#endif
