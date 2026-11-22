#if os(macOS)
import Prism
import PrismEmblem
import SwiftUI

/// Every river at once (⌘\): the tabs open, each a tile of its first
/// cards, in their order along the bar — and after them the rivers saved
/// in the graph that no tab has open. To see what is open where, go to
/// any of it, close what is done with, and put the tabs in another order.
/// Typed words narrow it to the rivers called so, or holding a note called
/// so — that note brought to the top of its tile.
struct TabsOverview: View {
    let store: GraphStore
    @Binding var isShown: Bool
    @State private var typed = ""
    @State private var cursor: String?
    @State private var columns = 4
    /// The open river held and carried among the others, while it is.
    @State private var carried: River.ID?
    /// The tile under the pointer: its ✕ shown.
    @State private var hovered: String?
    @FocusState private var focused: Bool

    /// The least width of a tile: how many go across is the room over this.
    static let tileWidth: CGFloat = 200

    var body: some View {
        let tiles = tiles
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.inkSecondary)
                TextField("Rivers — type to narrow", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { if let tile = tiles.first(where: { $0.id == cursor }) ?? tiles.first { go(to: tile) } }
                    .onKeyPress(.leftArrow) { step(-1, in: tiles) }
                    .onKeyPress(.rightArrow) { step(1, in: tiles) }
                    .onKeyPress(.upArrow) { step(-columns, in: tiles) }
                    .onKeyPress(.downArrow) { step(columns, in: tiles) }
                    .onKeyPress(.escape) {
                        if !typed.isEmpty { typed = "" } else { isShown = false }
                        return .handled
                    }
                Text(count(tiles)).font(.system(size: 11.5)).foregroundStyle(Color.inkFaint)
                Button {
                    isShown = false
                    withAnimation(.snappy(duration: 0.2)) { store.newRiver() }
                } label: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.inkSecondary)
                    .help("New River (⌘T)")
            }
            .padding(.horizontal, 22)
            .frame(height: 44)
            Rectangle().fill(Color.inkRule).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    let open = tiles.filter { $0.open != nil }
                    let saved = tiles.filter { $0.open == nil }
                    VStack(alignment: .leading, spacing: 18) {
                        grid(open)
                        if !saved.isEmpty {
                            Text("Saved, Not Open").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkSecondary).textCase(.uppercase)
                                .padding(.top, 6)
                            grid(saved)
                        }
                        if tiles.isEmpty {
                            Text("No river is called that, or holds a note called that").font(.callout).foregroundStyle(Color.inkFaint)
                                .frame(maxWidth: .infinity).padding(40)
                        }
                    }
                    .padding(22)
                    .animation(.snappy(duration: 0.22), value: tiles.map(\.id))
                }
                .onChange(of: cursor) { _, at in if let at { proxy.scrollTo(at) } }
            }
        }
        .background(Color.inkPage)
        // It takes the room it is given, and asks for none (see CardsOverview).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onGeometryChange(for: Int.self) { max(Int(($0.size.width - 44 + 16) / (Self.tileWidth + 16)), 1) } action: { if columns != $0 { columns = $0 } }
        .onAppear {
            focused = true
            cursor = tiles.first { $0.open == store.currentRiver }?.id
        }
        .onChange(of: typed) { _, _ in
            // Narrowed: the keys' place is the first left, unless the one they were at is still there.
            let left = self.tiles
            if !left.contains(where: { $0.id == cursor }) { cursor = left.first?.id }
        }
        .task(id: carried) {
            // Let go of anywhere: no longer carried.
            guard carried != nil else { return }
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 { try? await Task.sleep(for: .milliseconds(120)) }
            if !Task.isCancelled {
                carried = nil
                store.rememberRivers()
            }
        }
    }

    private func grid(_ tiles: [RiverTile.Model]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: columns), alignment: .leading, spacing: 18) {
            ForEach(tiles) { tile in tileView(tile) }
        }
    }

    private func tileView(_ tile: RiverTile.Model) -> some View {
        let river = tile.open.flatMap { store.rivers.indices.contains($0) ? store.rivers[$0] : nil }
        let shown = tile.open == store.currentRiver
        return RiverTile(store: store, tile: tile, detail: shown ? "shown" : "\(tile.count)", isCursor: cursor == tile.id) { go(to: tile) }
            // The one shown, marked under its name as its tab is.
            .overlay(alignment: .bottom) {
                if shown { Capsule().fill(tile.emblem.color?.color ?? Color.inkAccent).frame(width: 28, height: 3).offset(y: 7) }
            }
            .overlay(alignment: .topLeading) { if let river, hovered == tile.id { CloseMark { close(river) } } }
            .onHover { hovered = $0 ? tile.id : (hovered == tile.id ? nil : hovered) }
            .contextMenu {
                if let river { Button("Close River", systemImage: "xmark") { close(river) } }
                if let name = tile.saved { Button("Delete Saved River", systemImage: "trash", role: .destructive) { store.deleteSaved(name) } }
            }
            .opacity(carried != nil && carried == river?.id ? 0.45 : 1)
            .modifier(Carry(store: store, river: river, carried: $carried))
            .id(tile.id)
    }

    /// An open river's tile, carried among the others as its tab is along the bar.
    private struct Carry: ViewModifier {
        let store: GraphStore
        let river: River?
        @Binding var carried: River.ID?

        func body(content: Content) -> some View {
            if let river {
                content
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

    /// The ✕ that closes an open river's tile, at its corner.
    private struct CloseMark: View {
        var action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.inkSecondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.regularMaterial))
                    .overlay(Circle().strokeBorder(Color.inkRule, lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: -6, y: -6)
            .help("Close River")
        }
    }

    // MARK: What it shows

    /// The rivers: open, in the bar's order, then saved and not open — those called what was typed,
    /// or holding a note called so.
    private var tiles: [RiverTile.Model] {
        let words = typed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let says = { (text: String) in let text = text.lowercased(); return words.allSatisfy { text.contains($0) } }
        var tiles: [RiverTile.Model] = []
        for (index, river) in store.rivers.enumerated() {
            let name = store.title(of: river)
            var lines = river.all.map { RiverTile.Line(title: store.label(path: $0.path, title: $0.title), emblem: store.emblem(path: $0.path, title: $0.title)) }
            if !words.isEmpty, !says(name) {
                // Kept for a note in it called so: those notes first.
                let held = lines.filter { says($0.title) }
                guard !held.isEmpty else { continue }
                lines = held + lines.filter { !says($0.title) }
            }
            tiles.append(RiverTile.Model(id: "open:\(river.id)", name: name, emblem: Emblem(title: name, icon: river.icon, color: river.color), lines: Array(lines.prefix(6)), count: river.all.count, open: index, saved: river.name))
        }
        let open = Set(store.rivers.compactMap(\.name))
        for saved in store.savedRivers where !open.contains(saved.name) {
            var titles = saved.titles
            if !words.isEmpty, !says(saved.name) {
                let held = titles.filter(says)
                guard !held.isEmpty else { continue }
                titles = held + titles.filter { !says($0) }
            }
            let lines = titles.map { title in
                let path = store.resolve(title)?.path ?? ""
                return RiverTile.Line(title: store.label(path: path, title: title), emblem: store.emblem(path: path, title: title))
            }
            tiles.append(RiverTile.Model(id: "saved:\(saved.name)", name: saved.name, emblem: saved.emblem, lines: lines, count: saved.cards, open: nil, saved: saved.name))
        }
        return tiles
    }

    private func count(_ tiles: [RiverTile.Model]) -> String {
        let open = tiles.filter { $0.open != nil }.count
        let saved = tiles.count - open
        return saved == 0 ? "\(open) open" : "\(open) open · \(saved) saved"
    }

    // MARK: What is done

    private func go(to tile: RiverTile.Model) {
        isShown = false
        store.leaving()
        if let index = tile.open, store.rivers.indices.contains(index) {
            store.currentRiver = index
        } else if let name = tile.saved {
            withAnimation(.snappy(duration: 0.22)) { store.openSaved(name) }
        }
        store.rememberRivers()
    }

    private func close(_ river: River) {
        guard let index = store.rivers.firstIndex(where: { $0 === river }) else { return }
        withAnimation(.snappy(duration: 0.2)) { store.closeRiver(at: index) }
        // The keys' place stays among what is left.
        let left = tiles
        if !left.contains(where: { $0.id == cursor }) { cursor = left[safe: min(index, left.count - 1)]?.id }
    }

    /// The keys' place moved: along a row, or a row up or down — kept among the tiles, as one grid.
    private func step(_ by: Int, in tiles: [RiverTile.Model]) -> KeyPress.Result {
        guard !tiles.isEmpty else { return .handled }
        let at = tiles.firstIndex { $0.id == cursor } ?? (by > 0 ? -1 : tiles.count)
        let to = at + by
        if tiles.indices.contains(to) { cursor = tiles[to].id } else if cursor == nil { cursor = tiles[by > 0 ? 0 : tiles.count - 1].id }
        return .handled
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
