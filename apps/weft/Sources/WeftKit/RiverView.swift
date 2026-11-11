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
    /// Each card's height as it was last laid out, and the cards that
    /// show: what the ticks at the river's edge are drawn from.
    @State private var heights: [Card.ID: CGFloat] = [:]
    @State private var showing: Set<Card.ID> = []
    /// The card picked up to be moved, while it is carried.
    @State private var carried: Card.ID?

    /// A card's size for its tick: its height, once it has been laid out;
    /// till then, a guess from how much its note holds.
    private func size(of card: Card) -> Double {
        if let known = heights[card.id] { return Double(known) }
        if card.folded { return 44 }
        let file = (try? store.engine.absolutePath(path: card.path)) ?? ""
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? NSNumber)?.doubleValue ?? 400
        return 90 + bytes / 70 * 22
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
                                .onScrollVisibilityChange(threshold: 0.001) { visible in
                                    if visible { showing.insert(card.id) } else { showing.remove(card.id) }
                                }
                                .opacity(carried == card.id ? 0.45 : 1)
                                // Picked up by anything of it that is not its words, and
                                // carried: the others make room as it passes over them.
                                .onDrag {
                                    carried = card.id
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
            // Cards pass straight behind the bar: nothing is dimmed or blurred at the top.
            .scrollEdgeEffectHidden(true, for: .top)
            .overlay(alignment: .trailing) {
                let cards = river.all
                if cards.count > 1 {
                    TickStrip(
                        sizes: cards.map { size(of: $0) },
                        lit: Set(cards.indices.filter { showing.contains(cards[$0].id) }),
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
                        preview: { index in cards.indices.contains(index) ? preview(of: cards[index]) : nil }
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
        .task(id: store.indexRevision) {
            recent = (try? store.engine.runQuery(body: "sort: -modified\nlimit: 10", this: nil).pages) ?? []
            pinned = (try? store.engine.runQuery(body: "is: pinned\nsort: pinned\nlimit: 8", this: nil).pages) ?? []
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
        guard let carried, carried != target, let place = river.all.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.snappy(duration: 0.22)) { river.move(carried, toPlace: place) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        carried = nil
        store.rememberRivers()
        return true
    }

    func dropExited(info: DropInfo) {}
}
#endif
