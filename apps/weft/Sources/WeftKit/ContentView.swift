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
    /// Moved to show the river whole, its cards as tiles — or, shown so, the river again.
    public var overview = 0
    /// Moved to name the river shown — which saves it.
    public var saveRiver = 0
    /// Moved to find among the river's own notes: by name, or in what they say.
    public var findInRiver = 0
    public init() {}
}

/// A window on a graph: the river, and one bar to go anywhere from.
///
/// The window is the river. There is one bar over it, and one thing in
/// the middle of that bar: where you are, which is also where you go
/// from — a click on it, ⌘O, or simply starting to type, finds a page or
/// names a new one. The sidebar is there for who wants a list beside the
/// river, and out of the way until asked for.
/// Takes the window's own bar's line from under it, and lets the river
/// run up to the window's top: the bar is filled with the page's paper.
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
    /// Whether the river is shown whole: its cards as tiles.
    @State private var showsOverview = false
    /// Whether what is being found is found among the river's own notes only.
    @State private var findsInRiver = false
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
            RiverView(store: store, river: store.river, onQuickOpen: { show("") }, onOverview: { showsOverview = true })
                .id(store.river.id)
                // Pinched together, the river is seen whole; the river itself stays under it, where it was.
                .simultaneousGesture(MagnifyGesture().onEnded { if $0.magnification < 0.8 { showsOverview = true } })
                .overlay {
                    if showsOverview {
                        CardsOverview(store: store, river: store.river, isShown: $showsOverview)
                            .simultaneousGesture(MagnifyGesture().onEnded { if $0.magnification > 1.25 { showsOverview = false } })
                            .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    }
                }
                .animation(.easeOut(duration: 0.16), value: showsOverview)
                .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { detailWidth = $0 }
                .overlay(alignment: .top) {
                    if showsQuickOpen {
                        ZStack(alignment: .top) {
                            Color.black.opacity(0.06).ignoresSafeArea().onTapGesture { showsQuickOpen = false }
                            QuickOpen(store: store, isShown: $showsQuickOpen, seed: seed, inRiver: findsInRiver).padding(.top, 6)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                }
                .animation(.easeOut(duration: 0.12), value: showsQuickOpen)
                .overlay(alignment: .bottom) { UndoToast(store: store).padding(.bottom, 16) }
                // Finding in the river: at its top right, as a document's find is.
                .overlay(alignment: .topTrailing) {
                    if store.finding.isShown {
                        FindBar(find: store.finding).padding(.top, 10).padding(.trailing, 34)
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
                .animation(.easeOut(duration: 0.14), value: store.finding.isShown)
                // The bar's own fill is none: the river paints the page's paper under it (see RiverView).
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background(ClearTitleBar())
                .toolbar {
                    ToolbarItem(placement: .principal) { RiverBar(store: store, room: min(max(detailWidth - 330, 220), 860), saves: actions.saveRiver, onFind: { show("") }) }
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
        .onChange(of: actions.overview) { _, _ in showsOverview.toggle() }
        .onChange(of: store.currentRiver) { _, _ in
            showsOverview = false
            if store.finding.isShown { store.finding.close() }
        }
        .onChange(of: actions.findInRiver) { _, _ in
            if showsQuickOpen, findsInRiver { return showsQuickOpen = false }
            seed = actions.typed
            actions.typed = ""
            findsInRiver = true
            showsQuickOpen = true
        }
        .onChange(of: actions.sidebar) { _, _ in
            withAnimation(.snappy(duration: 0.2)) { columns = columns == .detailOnly ? .all : .detailOnly }
        }
    }

    private func show(_ typed: String) {
        findsInRiver = false
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
    /// Moved to name the river shown, which saves it.
    var saves = 0
    var onFind: () -> Void
    @State private var hovered: UUID?
    /// The river whose name, icon and colour are being chosen.
    @State private var styling: UUID?
    /// The tab held and carried along the bar, while it is.
    @State private var carried: River.ID?

    private static let plus: CGFloat = 26, small: CGFloat = 36

    /// How wide the tabs are: the one shown, the others, and whether the
    /// others are shrunk to their letters.
    private var widths: (current: CGFloat, other: CGFloat, shrunk: Bool) {
        let count = store.rivers.count
        // A card's title in the bar takes its room from the tabs'.
        let room = shownStuck == nil ? room : max(room - Self.stuckWidth - 8, 120)
        guard count > 1 else { return (min(240, room - Self.plus), 0, false) }
        let space = room - Self.plus - 8 - CGFloat(count - 1) * 2
        let others = CGFloat(count - 1)
        // Each with its name, as wide as there is room for…
        let even = space / CGFloat(count)
        if even >= 96 { return (min(even * 1.3, 220), min((space - min(even * 1.3, 220)) / others, 150), false) }
        // …or the others as letters, and the one shown with its name.
        return (max(min(space - others * Self.small, 220), Self.small), Self.small, true)
    }

    /// How wide a card's title, shown in the bar, may be.
    static let stuckWidth: CGFloat = 260

    /// The card whose title is shown in the bar: the river's current card —
    /// the one chosen — and only while its title has scrolled up under the
    /// bar. Another card's title there would say it was the current one.
    private var shownStuck: Card.ID? {
        let river = store.river
        return river.stuck != nil && river.stuck == river.selected ? river.stuck : nil
    }

    /// The card whose title has scrolled up under the bar: shown before
    /// the tabs, which move along to make room. Clicked, the card's top.
    @ViewBuilder private var stuckTitle: some View {
        let river = store.river
        if let id = shownStuck, let card = river.card(id) {
            let label = store.label(path: card.path, title: card.title)
            // As wide as its words, up to its room: the bar is laid out at its own size, and must be told.
            let words = ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width)
            HStack(spacing: 7) {
                EmblemView(store.emblem(path: card.path, title: card.title), size: 16, quiet: Color.inkSecondary)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 10).padding(.trailing, 12)
            .frame(width: min(words + 16 + 7 + 22, Self.stuckWidth), height: 28, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                river.selected = id
                river.scrollTarget = (id, (river.scrollTarget?.tick ?? 0) + 1)
            }
            .help("To the top of \(store.label(path: card.path, title: card.title))")
            .transition(.move(edge: .leading).combined(with: .opacity))
            .id(id)
            Rectangle().fill(Color.inkRule).frame(width: 1, height: 16).padding(.trailing, 4)
                .transition(.opacity)
        }
    }

    var body: some View {
        let widths = widths
        HStack(spacing: 2) {
            stuckTitle
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
                            // A river not saved is only passing through: its letter stands fainter.
                            .opacity(river.name == nil ? 0.5 : 1)
                    } else if river.icon != nil || river.color != nil {
                        // What it was given — and, clicked, where that is chosen.
                        Button { styling = river.id } label: {
                            EmblemView(Emblem(title: store.title(of: river), icon: river.icon, color: river.color, letter: false), size: 16, style: .plain, quiet: Color.inkSecondary).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Name this river, and choose its icon and colour")
                    }
                    if !shrunk {
                        // A saved river is called by its name, upright; one not saved — called,
                        // for now, by what is first in it — is in italics, as a thing in passing is.
                        Text(store.title(of: river))
                            .font(.system(size: 12.5, weight: current ? .semibold : .regular))
                            .italic(river.name == nil && !alone)
                            .foregroundStyle(current ? Color.inkText : (river.name == nil ? Color.inkFaint : Color.inkSecondary))
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
                // Held and carried along the bar, as Safari's tabs are: the others make room as it passes.
                .opacity(carried == river.id ? 0.45 : 1)
                .onDrag {
                    carried = river.id
                    return NSItemProvider(object: river.id.uuidString as NSString)
                } preview: {
                    Text(store.title(of: river)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(Color.inkCard))
                        .foregroundStyle(Color.inkText)
                }
                // A tab carried over this one takes its place; a card carried
                // here — from the river, or its overview — is sent to this river.
                .onDrop(of: [CardMove.type, .text], delegate: RiverCarry(target: river.id, store: store, carried: $carried) { info in
                    guard !current, river.query == nil, let provider = info.itemProviders(for: [CardMove.type]).first else { return false }
                    _ = provider.loadDataRepresentation(forTypeIdentifier: CardMove.type.identifier) { data, _ in
                        guard let data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return }
                        // Moved — or, with ⌥ held, shown in both rivers.
                        Task { @MainActor in
                            let copying = NSEvent.modifierFlags.contains(.option)
                            withAnimation(.snappy(duration: 0.24)) { store.send([id], from: store.river, to: river, copying: copying) }
                        }
                    }
                    return true
                })
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
                .help(current ? "Find a note, or name a new one (⌘O) — or just start typing" : (river.name == nil ? "\(store.title(of: river)) — not saved (⌘S names and saves it)" : store.title(of: river)))
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
        .animation(.snappy(duration: 0.22), value: store.rivers.map(\.id))
        // A tab let go of anywhere — off the bar, say — is no longer carried.
        .task(id: carried) {
            guard carried != nil else { return }
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 { try? await Task.sleep(for: .milliseconds(120)) }
            if !Task.isCancelled, carried != nil {
                carried = nil
                store.rememberRivers()
            }
        }
        .animation(.snappy(duration: 0.22), value: shownStuck)
        .animation(.snappy(duration: 0.2), value: store.rivers.count)
        .animation(.easeOut(duration: 0.12), value: CommandKey.shared.isHeld)
        .onChange(of: saves) { _, _ in styling = store.river.id }
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
