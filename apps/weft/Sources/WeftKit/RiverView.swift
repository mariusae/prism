#if os(macOS)
import Prism
import PrismEmblem
import SwiftUI
import UniformTypeIdentifiers

/// The river: the open cards, one after another.
struct RiverView: View {
    let store: GraphStore
    let river: River
    var onQuickOpen: () -> Void
    /// Asked to show the river whole.
    var onOverview: () -> Void = {}
    /// Each card's height as it was last laid out, and the cards that
    /// show: what the ticks at the river's edge are drawn from.
    @State private var heights: [Card.ID: CGFloat] = [:]
    @State private var showing: Set<Card.ID> = []
    /// How tall the river's view is: what of it is in sight.
    @State private var sightHeight: CGFloat = 0
    /// The card picked up to be moved, while it is carried.
    @State private var carried: Card.ID?
    /// How far down the window's bar reaches over the river.
    @State private var barDepth: CGFloat = 52
    /// Where each card is in the window: a click on any of it — its words, a link, a button — chooses it.
    @State private var touches = CardTouches()
    /// Where the river was read to, kept and gone back to.
    @State private var scroll = RiverScroll()
    @State private var position = ScrollPosition()

    /// How far into a card its title's line ends.
    private static let titleDepth: CGFloat = 46

    /// Whether a card, where it is in the river's sight — measured from
    /// the bar's lower edge — has its title up under the bar while enough
    /// of it is still there below: then the bar shows the title.
    private func place(_ id: Card.ID, at frame: CGRect) {
        let under = frame.minY + Self.titleDepth < 0 && frame.maxY > 36
        if under, river.stuck != id {
            withAnimation(.snappy(duration: 0.22)) { river.stuck = id }
        } else if !under, river.stuck == id {
            withAnimation(.snappy(duration: 0.22)) { river.stuck = nil }
        }
    }

    /// A card's size for its tick: its height, once it has been laid out;
    /// till then, a guess from how much its note holds.
    private func size(of card: Card) -> Double {
        // A folded card is ticked as long as its note is, not as its one line:
        // the ticks say what is in the river, however it is put away.
        if card.folded, let open = store.cardHeights[card.spot] { return Double(open) + 70 }
        if !card.folded, let known = heights[card.id] { return Double(known) }
        return 90 + store.bytes(of: card.path) / 70 * 22
    }

    /// What a tick's card shows of its note.
    private func preview(of card: Card) -> TickPreview {
        let draft = store.draft(path: card.path, title: card.title)
        let lines = draft.summary.isEmpty ? [] : [draft.summary]
        let page = (try? store.engine.page(path: card.path)) ?? nil
        let when = page?.modified.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(.relative(presentation: .named)) } ?? ""
        return TickPreview(title: draft.label, detail: when, lines: lines)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if river.all.isEmpty, river.query == nil {
                    StartPage(store: store, onQuickOpen: onQuickOpen)
                } else {
                    LazyVStack(spacing: 0) {
                        if river.query != nil {
                            QueryRiverHeader(store: store, river: river).padding(.bottom, Measures.foldedGap)
                        }
                        ForEach(river.all) { card in
                            CardView(store: store, river: river, card: card)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { heights[card.id] = $0 }
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { touches.frames[card.id] = $0 }
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
                                    place(card.id, at: frame)
                                    scroll.saw(card, at: frame, in: river)
                                    // In sight, its tick lit: from where it is, whenever it moves —
                                    // never from being told, which a card scrolled past may not be.
                                    let seen = frame.maxY > 0 && frame.minY < sightHeight
                                    if seen != showing.contains(card.id) {
                                        if seen { showing.insert(card.id) } else { showing.remove(card.id) }
                                    }
                                }
                                // Let go of by the lazy stack — scrolled far past, or jumped over —
                                // a card may never be told it is out of sight: gone, it is.
                                .onDisappear {
                                    showing.remove(card.id)
                                    touches.frames[card.id] = nil
                                }
                                .opacity(carried == card.id ? 0.45 : 1)
                                // Picked up by anything of it that is not its words, and
                                // carried: the others make room as it passes over them.
                                .onDrag {
                                    carried = card.id
                                    CardIntoNote.shared.begin(card, in: river)
                                    let provider = NSItemProvider()
                                    provider.registerDataRepresentation(forTypeIdentifier: CardMove.type.identifier, visibility: .ownProcess) { done in
                                        done(Data(card.id.uuidString.utf8), nil)
                                        return nil
                                    }
                                    return provider
                                } preview: {
                                    Text(store.label(path: card.path, title: card.title))
                                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                        .padding(.horizontal, 16).padding(.vertical, 10)
                                        .frame(maxWidth: 320, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.inkCard))
                                        .foregroundStyle(Color.inkText)
                                }
                                .onDrop(of: [CardMove.type], delegate: CardMove(target: card.id, river: river, store: store, carried: $carried))
                                .padding(.bottom, card.folded ? Measures.foldedGap : Measures.cardGap)
                                .id(card.id)
                                .transition(.poof)
                        }
                    }
                    .padding(.horizontal, Measures.riverSides)
                    .padding(.vertical, Measures.riverEnds)
                    .frame(maxWidth: Measures.cardMaxWidth + 2 * Measures.riverSides)
                    .frame(maxWidth: .infinity)
                    .animation(.snappy(duration: 0.28), value: river.all.map(\.id))
                }
            }
            .background(Color.inkPage)
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in sightHeight = height }
            .onScrollGeometryChange(for: CGPoint.self) { CGPoint(x: $0.contentInsets.top, y: $0.contentOffset.y) } action: { _, at in
                scroll.offset = at.y
                scroll.inset = at.x
            }
            // Shown again: back where it was read to. Let go of: remembered.
            .task {
                try? await Task.sleep(for: .milliseconds(40))
                scroll.restore(river, proxy: proxy, position: $position)
            }
            .onScrollPhaseChange { _, phase in if phase == .idle { store.rememberRiversSoon() } }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { barDepth = $0; touches.bar = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { touches.sight = $0 }
            .background(WindowCatcher { touches.window = $0 })
            .onAppear { touches.start { id in if river.selected != id { river.selected = id } } }
            .onDisappear { touches.stop() }
            // A card closed, or the river left: no card's title stays in the bar.
            .onChange(of: river.all.map(\.id)) { _, ids in
                if let stuck = river.stuck, !ids.contains(stuck) { river.stuck = nil }
            }
            // A card let go of anywhere — over no card, off the window — is
            // no longer carried: nothing says so but the button coming up.
            .task(id: carried) {
                guard carried != nil else { return }
                while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 { try? await Task.sleep(for: .milliseconds(120)) }
                if !Task.isCancelled {
                    carried = nil
                    store.rememberRivers()
                }
            }
            // The ticks are the river's scroll bar: its own is put away.
            .scrollIndicators(.hidden)
            // Cards pass under the bar: nothing is dimmed or blurred at the top…
            .scrollEdgeEffectHidden(true, for: .top)
            // …and the bar is of the page's own paper, opaque, so that what has
            // gone under it is gone — a card's title, then, shown in it.
            .overlay(alignment: .top) {
                Color.inkPage.frame(height: barDepth).ignoresSafeArea(edges: .top).allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                let cards = river.all
                if cards.count > 1 {
                    TickStrip(
                        sizes: cards.map { size(of: $0) },
                        lit: Set(cards.indices.filter { showing.contains(cards[$0].id) }),
                        tints: cards.map { store.emblem(path: $0.path, title: $0.title).color?.color },
                        days: Set(cards.indices.filter { cards[$0].path.hasPrefix("daily/") || cards[$0].path.hasPrefix("weekly/") }),
                        onPick: { index in
                            guard cards.indices.contains(index) else { return }
                            // Gone to at once, as Manifold goes: nothing slides.
                            river.selected = cards[index].id
                            proxy.scrollTo(cards[index].id, anchor: .top)
                        },
                        onMove: { from, to in
                            guard cards.indices.contains(from) else { return }
                            withAnimation(.snappy(duration: 0.24)) { river.move(cards[from].id, toPlace: to) }
                            store.rememberRivers()
                        },
                        preview: { index in cards.indices.contains(index) ? preview(of: cards[index]) : nil },
                        onOverview: onOverview
                    )
                    .frame(width: TickStripView.lane)
                    .padding(.trailing, 6)
                }
            }
            // A query river finds again whenever the graph moves, or it is asked something else.
            .task(id: "\(store.indexRevision)|\(river.query ?? "")|\(river.hidden.count)|\(river.cards.count)") { store.find(for: river) }
            // A card closed or folded: what is left is brought into sight, once it has settled.
            .onChange(of: river.settleTarget?.tick) { _, _ in
                guard let target = river.settleTarget?.card else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard river.card(target) != nil else { return }
                    withAnimation(.snappy(duration: 0.24)) { proxy.scrollTo(target) }
                }
            }
            .onChange(of: river.scrollTarget?.tick) { _, _ in
                guard let target = river.scrollTarget?.card else { return }
                DispatchQueue.main.async {
                    withAnimation(.snappy(duration: 0.24)) { proxy.scrollTo(target, anchor: .top) }
                }
            }
        }
    }
}

/// What an empty river shows: where to go from here.
struct StartPage: View {
    let store: GraphStore
    var onQuickOpen: () -> Void
    @State private var recent: [PageInfo] = []
    @State private var pinned: [PageInfo] = []
    /// The open river held and carried among the others, while it is.
    @State private var carried: River.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button(action: onQuickOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.inkSecondary)
                    Text("Go to a note or a day").foregroundStyle(Color.inkFaint)
                    Spacer()
                    Text("⌘O").font(.system(size: 11.5)).foregroundStyle(Color.inkFaint)
                }
                .font(.system(size: 17))
                .padding(.horizontal, 18)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.inkPaper))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.inkRule))
            }
            .buttonStyle(.plain)
            if !tiles.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        heading("Rivers")
                        Spacer()
                        Button { store.queryAsk = .new } label: { Label("New Query River…", systemImage: "line.3.horizontal.decrease.circle").font(.caption.weight(.medium)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.inkAccent)
                            .padding(.trailing, 10)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 136, maximum: 220), spacing: 16, alignment: .top)], alignment: .leading, spacing: 18) {
                        ForEach(tiles) { tile in
                            RiverTile(store: store, tile: tile) { withAnimation(.snappy(duration: 0.22)) { show(tile) } }
                                .contextMenu {
                                    if let index = tile.open { Button("Close River", systemImage: "xmark") { withAnimation(.snappy(duration: 0.2)) { store.closeRiver(at: index) } } }
                                    if let name = tile.saved { Button("Delete Saved River", systemImage: "trash", role: .destructive) { store.deleteSaved(name) } }
                                }
                                .modifier(Carried(store: store, river: tile.open.flatMap { store.rivers.indices.contains($0) ? store.rivers[$0] : nil }, carried: $carried))
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            if !pinned.isEmpty { list("Pinned", pinned) }
            if !recent.isEmpty { list("Recent", recent) }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 28)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .task(id: carried) {
            // Let go of anywhere: no longer carried.
            guard carried != nil else { return }
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 { try? await Task.sleep(for: .milliseconds(120)) }
            if !Task.isCancelled {
                carried = nil
                store.rememberRivers()
            }
        }
        .task(id: store.indexRevision) {
            recent = (try? store.engine.runQuery(body: "sort: -modified\nlimit: 10", this: nil).pages) ?? []
            pinned = (try? store.engine.runQuery(body: "in: Pinned\nlimit: 8", this: nil).pages) ?? []
        }
    }

    /// An open river's tile, held and carried among the others, as its
    /// tab is along the bar: the rivers put in that order as it passes.
    /// A saved river not open has no place among them to be carried to.
    private struct Carried: ViewModifier {
        let store: GraphStore
        let river: River?
        @Binding var carried: River.ID?

        func body(content: Content) -> some View {
            if let river {
                content
                    .opacity(carried == river.id ? 0.45 : 1)
                    .onDrag {
                        carried = river.id
                        return NSItemProvider(object: river.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: RiverCarry(target: river.id, store: store, carried: $carried))
            } else {
                content
            }
        }
    }

    /// The rivers there are to go to: those open in other tabs, then
    /// those saved in the graph that no tab has open.
    private var tiles: [RiverTile.Model] {
        var tiles: [RiverTile.Model] = []
        for (index, river) in store.rivers.enumerated() where index != store.currentRiver && (!river.all.isEmpty || river.isStyled || river.query != nil) {
            let cards = river.all.prefix(6).map { RiverTile.Line(title: store.label(path: $0.path, title: $0.title), emblem: store.emblem(path: $0.path, title: $0.title)) }
            tiles.append(RiverTile.Model(id: "open:\(river.id)", name: store.title(of: river), emblem: Emblem(title: store.title(of: river), icon: river.icon, color: river.color), lines: cards, count: river.cards.count, open: index, saved: river.name))
        }
        let open = Set(store.rivers.compactMap(\.name))
        for saved in store.savedRivers where !open.contains(saved.name) {
            let cards = saved.titles.map { title in
                let path = store.resolve(title)?.path ?? ""
                return RiverTile.Line(title: store.label(path: path, title: title), emblem: store.emblem(path: path, title: title))
            }
            tiles.append(RiverTile.Model(id: "saved:\(saved.name)", name: saved.name, emblem: saved.emblem, lines: cards, count: saved.cards, open: nil, saved: saved.name))
        }
        return tiles
    }

    private func show(_ tile: RiverTile.Model) {
        // This river has nothing in it: the one gone to takes its place.
        let here = store.currentRiver
        if tile.open != nil {
            if store.rivers.indices.contains(here), store.rivers[here].all.isEmpty, store.rivers[here].query == nil, !store.rivers[here].isStyled { store.closeRiver(at: here) }
            if let moved = store.rivers.firstIndex(where: { "open:\($0.id)" == tile.id }) { store.currentRiver = moved }
        } else if let name = tile.saved {
            store.openSaved(name)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Color.inkSecondary).padding(.leading, 10)
    }

    private func list(_ title: String, _ pages: [PageInfo]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            heading(title).padding(.bottom, 4)
            ForEach(pages, id: \.path) { page in
                PageRow(store: store, page: page) { withAnimation(.snappy(duration: 0.28)) { store.open(page: page) } }
            }
        }
    }
}

/// A page in a list: its symbol, its title, when it was written.
struct PageRow: View {
    let store: GraphStore
    let page: PageInfo
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                EmblemView(store.emblem(page), size: 20, quiet: Color.inkSecondary)
                Text(store.emblem(page).caption(page.label)).font(.system(size: 14.5)).foregroundStyle(Color.inkText).lineLimit(1)
                Spacer(minLength: 12)
                if let modified = page.modified {
                    Text(Date(timeIntervalSince1970: TimeInterval(modified)), format: .relative(presentation: .named)).font(.system(size: 12)).foregroundStyle(Color.inkFaint)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovered ? Color.inkHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// A river in the overview: a small picture of it — its first cards, one
/// under another, as the river itself has them — over its name.
struct RiverTile: View {
    struct Line: Hashable {
        var title: String
        var emblem: Emblem
    }

    struct Model: Identifiable {
        var id: String
        var name: String
        var emblem: Emblem
        var lines: [Line]
        var count: Int
        /// The tab that has it open, if one has.
        var open: Int?
        /// Its name in the graph, if it is saved.
        var saved: String?
    }

    let store: GraphStore
    let tile: Model
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                picture
                HStack(spacing: 6) {
                    EmblemView(tile.emblem, size: 18, quiet: Color.inkSecondary)
                    Text(tile.emblem.caption(tile.name)).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.inkText).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(tile.open != nil ? "open" : "\(tile.count)").font(.system(size: 11)).foregroundStyle(Color.inkFaint)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tile.open != nil ? "Go to this river" : "Open this river")
    }

    /// The river, small: a page with its first cards on it.
    private var picture: some View {
        VStack(alignment: .leading, spacing: 4) {
            if tile.lines.isEmpty {
                Text("No cards").font(.system(size: 10)).foregroundStyle(Color.inkFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(Array(tile.lines.enumerated()), id: \.offset) { index, line in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if line.emblem.isShown { EmblemView(line.emblem, size: 10, style: .plain, quiet: Color.inkSecondary) }
                        Text(line.emblem.caption(line.title)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.inkText).lineLimit(1)
                    }
                    // The first card stands open, as it would: a few lines of writing under its title.
                    if index == 0 {
                        ForEach(0..<3, id: \.self) { row in
                            Capsule().fill(Color.inkText.opacity(0.10)).frame(height: 3).frame(maxWidth: row == 2 ? 70 : .infinity, alignment: .leading).padding(.leading, 14)
                        }
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.inkCard))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.inkRule, lineWidth: 0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .frame(height: 124, alignment: .top)
        // What does not fit runs off the foot, as a river does.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.78), .init(color: .black.opacity(0.25), location: 1)], startPoint: .top, endPoint: .bottom))
        .background(Color.inkPaper)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isHovered ? (tile.emblem.color?.color ?? Color.inkAccent).opacity(0.8) : Color.inkRule, lineWidth: isHovered ? 1.5 : 1))
        .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 10 : 5, y: isHovered ? 4 : 2)
        .scaleEffect(isHovered ? 1.015 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// A card carried over the river's others: each it passes over makes
/// room, so that it is put down where it is seen to be.
struct CardMove: DropDelegate {
    /// What is carried: a card of this app's, and no one else's to take.
    static let type = UTType(exportedAs: "com.mariusae.weft.card")

    let target: Card.ID
    let river: River
    let store: GraphStore
    @Binding var carried: Card.ID?

    func dropEntered(info: DropInfo) {
        // Become a row of a note, it is carried over the cards, not among them.
        guard !CardIntoNote.shared.isRow else { return CardIntoNote.shared.moved(over: river.card(target), at: NSEvent.mouseLocation) }
        guard let carried, carried != target, let place = river.all.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.snappy(duration: 0.22)) { river.move(carried, toPlace: place) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        CardIntoNote.shared.moved(over: river.card(target), at: NSEvent.mouseLocation)
        return DropProposal(operation: CardIntoNote.shared.isRow && NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        carried = nil
        if CardIntoNote.shared.isRow {
            _ = CardIntoNote.shared.put(on: river.card(target), at: NSEvent.mouseLocation, copying: NSEvent.modifierFlags.contains(.option), store: store)
        }
        CardIntoNote.shared.end()
        store.rememberRivers()
        return true
    }

    func dropExited(info: DropInfo) { CardIntoNote.shared.left() }
}
/// Each card's place in the window, and a watch on the window's clicks:
/// one anywhere on a card — its words, a link, a box, a button, its menu —
/// makes it the card chosen, before whatever was clicked does its part.
@MainActor
final class CardTouches {
    var frames: [Card.ID: CGRect] = [:]
    /// The river's sight in the window, and how much of its top the bar covers.
    var sight: CGRect = .zero
    var bar: CGFloat = 0
    weak var window: NSWindow?
    private var monitor: Any?

    func start(_ choose: @escaping (Card.ID) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, let content = window.contentView else { return event }
            // From the window's foot, as AppKit counts, to its top, as the river's frames are.
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            guard self.sight.contains(point), point.y > self.sight.minY + self.bar else { return event }
            if let hit = self.frames.first(where: { $0.value.contains(point) })?.key { choose(hit) }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Says which window a view is in, once it is in one.
struct WindowCatcher: NSViewRepresentable {
    var found: (NSWindow?) -> Void

    final class Catcher: NSView {
        var found: (NSWindow?) -> Void = { _ in }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found(window)
        }
    }

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.found = found
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.found = found
    }
}

#endif
