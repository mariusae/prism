import Prism
import PrismEmblem
import SwiftUI

/// What the app's menus, and its keys, ask of the window in front.
@MainActor
@Observable
public final class WindowActions {
    /// Moved to bring Quick Open up; `typed` is what brought it, if a key did.
    public var quickOpen = 0
    public var typed = ""
    public var sidebar = 0
    public init() {}
}

/// A window on a graph: the river, and one bar to go anywhere from.
///
/// The window is the river. There is one bar over it, and one thing in
/// the middle of that bar: where you are, which is also where you go
/// from — a click on it, ⌘O, or simply starting to type, finds a page or
/// names a new one. The sidebar is there for who wants a list beside the
/// river, and out of the way until asked for.
public struct ContentView: View {
    let store: GraphStore
    let actions: WindowActions
    @State private var showsQuickOpen = false
    @State private var seed = ""
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var searchFocus = 0

    public init(store: GraphStore, actions: WindowActions) {
        self.store = store
        self.actions = actions
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(store: store, searchFocus: $searchFocus)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
        } detail: {
            RiverView(store: store, river: store.river, onQuickOpen: { show("") })
                .id(store.river.id)
                .overlay(alignment: .top) {
                    if showsQuickOpen {
                        ZStack(alignment: .top) {
                            Color.black.opacity(0.06).ignoresSafeArea().onTapGesture { showsQuickOpen = false }
                            QuickOpen(store: store, isShown: $showsQuickOpen, seed: seed).padding(.top, 6)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                }
                .animation(.easeOut(duration: 0.12), value: showsQuickOpen)
                .toolbar {
                    ToolbarItem(placement: .principal) { RiverBar(store: store, onFind: { show("") }) }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !store.conflicted.isEmpty {
                            Button {
                                for page in store.conflicted { store.open(page: page) }
                            } label: { Label("\(store.conflicted.count) to Review", systemImage: "exclamationmark.triangle") }
                            .tint(.orange)
                        }
                        Button { withAnimation(.snappy(duration: 0.28)) { store.open(name: QuickOpen.day(Date()), after: store.river.selected) } } label: {
                            Label("Today", systemImage: "calendar")
                        }
                        .help("Today (⇧⌘D)")
                        Button { newPage() } label: { Label("New Page", systemImage: "square.and.pencil") }
                            .help("New Page (⌘N)")
                    }
                }
        }
        .navigationTitle(store.river.title)
        .toolbar(removing: .title)
        .foregroundStyle(Color.inkText)
        .tint(Color.inkAccent)
        .onChange(of: actions.quickOpen) { _, _ in
            if showsQuickOpen { showsQuickOpen = false } else { show(actions.typed) }
            actions.typed = ""
        }
        .onChange(of: actions.sidebar) { _, _ in
            withAnimation(.snappy(duration: 0.2)) { columns = columns == .detailOnly ? .all : .detailOnly }
        }
    }

    private func show(_ typed: String) {
        seed = typed
        showsQuickOpen = true
    }

    private func newPage() {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH.mm.ss"
        withAnimation(.snappy(duration: 0.28)) { _ = store.newPage(title: "Untitled \(format.string(from: Date()))") }
    }
}

/// The bar's middle: the rivers open, the one shown standing as where
/// you are — and, clicked, as where you go from.
struct RiverBar: View {
    let store: GraphStore
    var onFind: () -> Void
    @State private var hovered: UUID?
    /// The river whose name, icon and colour are being chosen.
    @State private var styling: UUID?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(store.rivers.enumerated()), id: \.element.id) { index, river in
                let current = index == store.currentRiver
                HStack(spacing: 6) {
                    // What stands for the river — and, clicked, where it is
                    // named and given an icon. One river with nothing of its
                    // own is simply the place to search from.
                    if store.rivers.count > 1 || river.isStyled {
                        Button { styling = river.id } label: { EmblemView(river.emblem, size: 18, quiet: Color.inkSecondary).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .help("Name this river, and choose its icon and colour")
                    } else {
                        Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkSecondary)
                    }
                    Text(store.rivers.count > 1 || river.isStyled ? river.emblem.caption(river.title) : river.title)
                        .font(.system(size: 12.5, weight: current ? .semibold : .regular))
                        .foregroundStyle(current ? Color.inkText : Color.inkSecondary)
                        .lineLimit(1)
                    if store.rivers.count > 1, hovered == river.id || current {
                        Button { withAnimation(.snappy(duration: 0.2)) { store.closeRiver(at: index) } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.inkSecondary).frame(width: 16, height: 16).contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .opacity(hovered == river.id ? 1 : 0)
                    }
                }
                .padding(.horizontal, 12)
                // A width of its own, not one to be stretched: the bar's glass
                // is fitted to what is in it, and must be told how much that is.
                .frame(width: current ? (store.rivers.count > 1 ? 200 : 240) : 120, height: 28)
                // The bar's own glass is the pill. With one river nothing is
                // drawn inside it; with several, the one shown is marked.
                .background(Capsule().fill(Color.inkText.opacity(store.rivers.count > 1 && current ? 0.08 : (hovered == river.id ? 0.04 : 0))))
                .contentShape(Capsule())
                .onTapGesture {
                    if current { onFind() } else { withAnimation(.snappy(duration: 0.2)) { store.currentRiver = index } }
                }
                .onHover { hovered = $0 ? river.id : (hovered == river.id ? nil : hovered) }
                .contextMenu {
                    Button(river.name == nil ? "Name and Save…" : "Rename…", systemImage: "character.cursor.ibeam") { styling = river.id }
                    Button("Icon and Colour…", systemImage: "paintpalette") { styling = river.id }
                    if let name = river.name { Button("Delete Saved River", systemImage: "trash", role: .destructive) { store.deleteSaved(name) } }
                    Divider()
                    Button("Close River", systemImage: "xmark") { withAnimation(.snappy(duration: 0.2)) { store.closeRiver(at: index) } }
                }
                .popover(isPresented: Binding(get: { styling == river.id }, set: { if !$0 { styling = nil } }), arrowEdge: .bottom) {
                    RiverLook(store: store, river: river)
                }
                .help(current ? "Find a page, or name a new one (⌘O) — or just start typing" : river.title)
            }
            Button { withAnimation(.snappy(duration: 0.2)) { store.newRiver() } } label: {
                Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.inkSecondary)
            .help("New River (⌘T)")
        }
        // Set in from the glass by the same on every side, so that what
        // is marked inside it sits concentric with it.
        .padding(.horizontal, 4)
        .fixedSize()
        .animation(.snappy(duration: 0.2), value: store.currentRiver)
    }
}

/// A river's name, icon and colour, chosen. Naming it saves it.
struct RiverLook: View {
    let store: GraphStore
    let river: River
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                EmblemView(Emblem(title: name.isEmpty ? river.title : name, icon: river.icon, color: river.color), size: 24)
                TextField("Name this river to save it", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .onSubmit { store.rename(river, to: name) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            EmblemPicker(
                title: name.isEmpty ? river.title : name,
                icon: Binding(get: { river.icon }, set: { river.icon = $0; store.rememberRivers() }),
                color: Binding(get: { river.color }, set: { river.color = $0; store.rememberRivers() })
            )
        }
        .onAppear { name = river.name ?? "" }
        .onDisappear { store.rename(river, to: name) }
    }
}
