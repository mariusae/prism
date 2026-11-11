#if os(macOS)
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
    /// Moved to bring the calendar up.
    public var calendar = 0
    public init() {}
}

/// A window on a graph: the river, and one bar to go anywhere from.
///
/// The window is the river. There is one bar over it, and one thing in
/// the middle of that bar: where you are, which is also where you go
/// from — a click on it, ⌘O, or simply starting to type, finds a page or
/// names a new one. The sidebar is there for who wants a list beside the
/// river, and out of the way until asked for.
/// Takes the window's own bar from behind its buttons: no fill, and no
/// line under it, so what scrolls passes straight behind.
private struct ClearTitleBar: NSViewRepresentable {
    final class Watcher: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
        }
    }

    func makeNSView(context: Context) -> Watcher { Watcher() }
    func updateNSView(_ view: Watcher, context: Context) {}
}

public struct ContentView: View {
    let store: GraphStore
    let actions: WindowActions
    @State private var showsQuickOpen = false
    @State private var showsCalendar = false
    @State private var seed = ""
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var searchFocus = 0
    /// How wide the river's side of the window is: what the bar is fitted to.
    @State private var detailWidth: CGFloat = 900

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
                .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { detailWidth = $0 }
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
                .overlay(alignment: .bottom) { UndoToast(store: store).padding(.bottom, 16) }
                // The bar is only its buttons: the river shows through behind them.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background(ClearTitleBar())
                .toolbar {
                    ToolbarItem(placement: .principal) { RiverBar(store: store, room: min(max(detailWidth - 330, 220), 860), onFind: { show("") }) }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !store.conflicted.isEmpty {
                            Button {
                                for page in store.conflicted { store.open(page: page) }
                            } label: { Label("\(store.conflicted.count) to Review", systemImage: "exclamationmark.triangle") }
                            .tint(.orange)
                        }
                        // Turning while a sync is under way; pressed, it syncs now.
                        Syncing(store: store) { syncing in
                            Button { store.syncNow() } label: {
                                Label(syncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: syncing)
                                    .foregroundStyle(syncing ? Color.inkAccent : Color.inkSecondary)
                            }
                            .help(syncing ? "Syncing…" : (store.syncNote.map { "\($0) — Sync Now (⌘R)" } ?? "Sync Now (⌘R)"))
                        }
                        // A month of days, to go to any of them, or to a week; with ⌘ held, straight to today.
                        Button {
                            if NSEvent.modifierFlags.contains(.command) {
                                withAnimation(.snappy(duration: 0.28)) { store.open(name: QuickOpen.day(Date()), after: store.river.selected) }
                            } else {
                                showsCalendar = true
                            }
                        } label: {
                            Label("Calendar", systemImage: "calendar")
                        }
                        .help("Go to a date (⇧⌘D) — ⌘-click for today (⌘D)")
                        .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                            CalendarPopover(store: store) { title in
                                showsCalendar = false
                                withAnimation(.snappy(duration: 0.28)) { store.open(name: title, after: store.river.selected) }
                            }
                        }
                        Button { newPage() } label: { Label("New Note", systemImage: "square.and.pencil") }
                            .help("New Note (⌘N)")
                    }
                }
        }
        .sheet(item: Binding(get: { store.queryAsk }, set: { store.queryAsk = $0 })) { ask in QueryRiverEditor(store: store, ask: ask) }
        .sheet(item: Binding(get: { store.movingRows }, set: { store.movingRows = $0 })) { moving in MoveRowsSheet(store: store, moving: moving) }
        .navigationTitle(store.title(of: store.river))
        .toolbar(removing: .title)

        .foregroundStyle(Color.inkText)
        .tint(Color.inkAccent)
        .onChange(of: actions.quickOpen) { _, _ in
            if showsQuickOpen { showsQuickOpen = false } else { show(actions.typed) }
            actions.typed = ""
        }
        .onChange(of: actions.calendar) { _, _ in showsCalendar = true }
        .onChange(of: actions.sidebar) { _, _ in
            withAnimation(.snappy(duration: 0.2)) { columns = columns == .detailOnly ? .all : .detailOnly }
        }
    }

    private func show(_ typed: String) {
        seed = typed
        showsQuickOpen = true
    }

    private func newPage() {
        withAnimation(.snappy(duration: 0.28)) { _ = store.newNote() }
    }
}

/// The bar's middle: the rivers open, the one shown standing as where
/// you are — and, clicked, as where you go from.
///
/// A tab says its river's name. Only when there are too many to name —
/// when a tab is shrunk as far as it goes — does a letter of the name
/// stand for it instead. An icon a river was given always shows.
struct RiverBar: View {
    let store: GraphStore
    /// How wide the bar may be.
    var room: CGFloat
    var onFind: () -> Void
    @State private var hovered: UUID?
    /// The river whose name, icon and colour are being chosen.
    @State private var styling: UUID?

    private static let plus: CGFloat = 26, small: CGFloat = 36

    /// How wide the tabs are: the one shown, the others, and whether the
    /// others are shrunk to their letters.
    private var widths: (current: CGFloat, other: CGFloat, shrunk: Bool) {
        let count = store.rivers.count
        guard count > 1 else { return (min(240, room - Self.plus), 0, false) }
        let space = room - Self.plus - 8 - CGFloat(count - 1) * 2
        let others = CGFloat(count - 1)
        // Each with its name, as wide as there is room for…
        let even = space / CGFloat(count)
        if even >= 96 { return (min(even * 1.3, 220), min((space - min(even * 1.3, 220)) / others, 150), false) }
        // …or the others as letters, and the one shown with its name.
        return (max(min(space - others * Self.small, 220), Self.small), Self.small, true)
    }

    var body: some View {
        let widths = widths
        HStack(spacing: 2) {
            ForEach(Array(store.rivers.enumerated()), id: \.element.id) { index, river in
                let current = index == store.currentRiver
                // The one shown keeps its name while there is room to say any of it.
                let shrunk = widths.shrunk && (!current || widths.current < 72)
                let alone = store.rivers.count == 1 && !river.isStyled
                // ⌘ held: the number that chooses it, in its icon's place. The first
                // eight by their places; ⌘9 is the last, wherever it is.
                let numbered = CommandKey.shared.isHeld && store.rivers.count > 1 && (index < 8 || index == store.rivers.count - 1)
                HStack(spacing: 6) {
                    if numbered {
                        Text(index < 8 ? "\(index + 1)" : "9")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.inkText)
                            .frame(width: shrunk ? 20 : 16, height: shrunk ? 20 : 16)
                            .background(Circle().fill(Color.inkText.opacity(0.14)))
                            .transition(.opacity)
                    } else if alone {
                        // One river with nothing of its own is simply the place to search from.
                        Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkSecondary)
                    } else if shrunk {
                        EmblemView(Emblem(title: store.title(of: river), icon: river.icon, color: river.color), size: 20, quiet: Color.inkSecondary)
                    } else if river.icon != nil || river.color != nil {
                        // What it was given — and, clicked, where that is chosen.
                        Button { styling = river.id } label: {
                            EmblemView(Emblem(title: store.title(of: river), icon: river.icon, color: river.color, letter: false), size: 16, style: .plain, quiet: Color.inkSecondary).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Name this river, and choose its icon and colour")
                    }
                    if !shrunk {
                        Text(store.title(of: river))
                            .font(.system(size: 12.5, weight: current ? .semibold : .regular))
                            .foregroundStyle(current ? Color.inkText : Color.inkSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, shrunk ? 0 : 12)
                // A width of its own, not one to be stretched: the bar's glass
                // is fitted to what is in it, and must be told how much that is.
                .frame(width: current ? widths.current : widths.other, height: 28)
                // The bar's own glass is the pill. With one river nothing is
                // drawn inside it; with several, the one shown is marked.
                .background(Capsule().fill(Color.inkText.opacity(store.rivers.count > 1 && current ? 0.08 : (hovered == river.id ? 0.04 : 0))))
                // Closing it is over its end while the pointer is on it:
                // laid over, so that nothing in the tab moves to make room.
                .overlay(alignment: .trailing) {
                    if store.rivers.count > 1, hovered == river.id, !shrunk {
                        Button { withAnimation(.snappy(duration: 0.2)) { store.closeRiver(at: index) } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.inkSecondary)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(.regularMaterial))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 5)
                        .help("Close River")
                    }
                }
                .contentShape(Capsule())
                .onTapGesture {
                    if current { onFind() } else { withAnimation(.snappy(duration: 0.2)) { store.currentRiver = index } }
                }
                .onHover { hovered = $0 ? river.id : (hovered == river.id ? nil : hovered) }
                .contextMenu {
                    Button(river.name == nil ? "Name and Save…" : "Rename…", systemImage: "character.cursor.ibeam") { styling = river.id }
                    Button("Icon and Colour…", systemImage: "paintpalette") { styling = river.id }
                    Button(river.query == nil ? "Fill from a Query…" : "Edit River Query…", systemImage: "slider.horizontal.3") { store.queryAsk = .edit(river) }
                    if let name = river.name { Button("Delete Saved River", systemImage: "trash", role: .destructive) { store.deleteSaved(name) } }
                    Divider()
                    Button("Close River", systemImage: "xmark") { withAnimation(.snappy(duration: 0.2)) { store.closeRiver(at: index) } }
                }
                .popover(isPresented: Binding(get: { styling == river.id }, set: { if !$0 { styling = nil } }), arrowEdge: .bottom) {
                    RiverLook(store: store, river: river)
                }
                .help(current ? "Find a note, or name a new one (⌘O) — or just start typing" : store.title(of: river))
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
        .animation(.snappy(duration: 0.2), value: store.rivers.count)
        .animation(.easeOut(duration: 0.12), value: CommandKey.shared.isHeld)
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

/// At the river's foot, a moment: what was just done, and Undo. Whatever
/// closes, removes or deletes is done at once, and taken back from here.
struct UndoToast: View {
    let store: GraphStore

    var body: some View {
        Group {
            if let offer = store.undoOffer {
                HStack(spacing: 12) {
                    Text(offer.said).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.inkSecondary)
                    Button("Undo") { withAnimation(.snappy(duration: 0.28)) { _ = store.takeUndo() } }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.inkAccent)
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: 420)
                .fixedSize()
                .glassEffect(.regular.interactive(), in: .capsule)
                .id(offer.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .help("Undo (⌘Z)")
            }
        }
        .animation(.snappy(duration: 0.25), value: store.undoOffer?.id)
    }
}
#endif
