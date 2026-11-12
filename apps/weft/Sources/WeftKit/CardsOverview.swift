import Prism
import PrismEmblem
import SwiftUI

/// A river seen whole: every card of it small, side by side, in the
/// river's order — to see what is in it, go to any of it, and put it in
/// another order. Nothing is written here; a card is gone to, to write.
///
/// A tile is its card, kept abstract: the title with its icon and colour,
/// a line or two of the note as it reads, and the rest only as the shapes
/// of its lines; where the note has a picture, a blank that says so. Enough
/// to know a note by and find the way to it, and no more. A long note's
/// tile is taller than a short one's, within limits, so that length shows
/// without one note taking the page. How a card is put away in the river —
/// folded or not — is only a small mark: this is what the river holds.
struct CardTile: View {
    let store: GraphStore
    let river: River
    let card: Card
    var isChosen = false
    var isCursor = false

    /// A line of the note, as the tile shows it.
    struct Row: Hashable {
        var text: String
        var depth: Int
        /// A checkbox's state; `nil` for a line that is no task.
        var done: Bool?
        var isItem: Bool
        var isHeading: Bool
    }

    /// What a tile shows of its card.
    struct Model {
        var label: String
        var emblem: Emblem
        var trail: [String]
        var rows: [Row]
        var hasPicture: Bool
    }

    /// The most lines a tile shows — the first few as they read, the rest as their shapes.
    static let most = 9
    static let said = 2

    @MainActor
    static func model(of card: Card, in store: GraphStore) -> Model {
        let draft = store.draft(path: card.path, title: card.title)
        var emblem = store.emblem(path: card.path, title: card.title)
        var label = draft.label
        var trail: [String] = []
        var editor = draft.editor
        // A card of one row of its note is that row's: called by it, with the way to it above.
        if let focus = card.focus, let view = draft.view(for: card.id, focus: focus) {
            trail = [draft.label] + view.focusTrail().map(Days.shown)
            label = store.titled(view.focusLabel() ?? "", written: view.focusTitle() ?? "")
            if label.isEmpty { label = "Untitled" }
            emblem = Emblem(title: label, letter: false)
            editor = view
        }
        let text = editor.text() as NSString
        var rows: [Row] = []
        for line in editor.layout().lines {
            let range = NSRange(location: Int(line.content), length: max(Int(line.end) - Int(line.content), 0))
            guard NSMaxRange(range) <= text.length else { continue }
            // A row of several lines is told by its first.
            let written = text.substring(with: range).split(whereSeparator: { $0 == "\u{2028}" || $0 == "\n" }).first.map(String.init) ?? ""
            let words = inlinePlainText(text: written).trimmingCharacters(in: .whitespaces)
            // A line that is only a picture is shown by the picture, below.
            if written.contains("!["), words.isEmpty { continue }
            if case .blank = line.kind { continue }
            if words.isEmpty { continue }
            guard rows.count < most else { continue }
            switch line.kind {
            case .item(_, let done, _): rows.append(Row(text: words, depth: max(Int(line.depth) - 1, 0), done: done, isItem: true, isHeading: false))
            case .heading: rows.append(Row(text: words, depth: 0, done: nil, isItem: false, isHeading: true))
            default: rows.append(Row(text: words, depth: 0, done: nil, isItem: false, isHeading: false))
            }
        }
        // An untitled note is called by its first words: they are not said twice.
        if card.focus == nil, draft.isUntitled, let first = rows.first, label.hasPrefix(first.text.prefix(12)) { rows.removeFirst() }
        return Model(label: label, emblem: emblem, trail: trail, rows: rows, hasPicture: !draft.pictures.isEmpty)
    }

    var body: some View {
        let model = Self.model(of: card, in: store)
        let tint = model.emblem.color?.color
        VStack(alignment: .leading, spacing: 5) {
            if !model.trail.isEmpty {
                Text(model.trail.joined(separator: " › ")).font(.system(size: 9.5)).foregroundStyle(Color.inkFaint).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if model.emblem.isShown { EmblemView(model.emblem, size: 12, style: .plain, quiet: Color.inkSecondary) }
                Text(model.emblem.caption(model.label)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.inkText).lineLimit(2)
                Spacer(minLength: 0)
                // Put away in the river: said, small.
                if card.folded { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.inkFaint) }
            }
            // Its first lines as they read: enough to know it by.
            ForEach(Array(model.rows.prefix(Self.said).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let done = row.done {
                        Image(systemName: done ? "checkmark.square.fill" : "square").font(.system(size: 8.5)).foregroundStyle(done ? Color.inkAccent : Color.inkFaint)
                    } else if row.isItem {
                        Circle().fill(Color.inkFaint).frame(width: 3, height: 3).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                    }
                    Text(row.text)
                        .font(.system(size: 10.5, weight: row.isHeading ? .semibold : .regular))
                        .foregroundStyle(row.done == true ? Color.inkFaint : Color.inkSecondary)
                        .strikethrough(row.done == true, color: Color.inkFaint)
                        .lineLimit(1)
                }
                .padding(.leading, CGFloat(min(row.depth, 4)) * 9)
            }
            // The rest only as lines' shapes: how much there is, and how it is set in — not what it says.
            if model.rows.count > Self.said {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(model.rows.dropFirst(Self.said).enumerated()), id: \.offset) { _, row in
                        Capsule().fill(Color.inkText.opacity(row.isHeading ? 0.16 : 0.09))
                            .frame(height: 3.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .scaleEffect(x: min(max(CGFloat(row.text.count) / 34, 0.22), 1), y: 1, anchor: .leading)
                            .padding(.leading, CGFloat(min(row.depth, 4)) * 9)
                    }
                }
                .padding(.top, 2)
            }
            if model.rows.isEmpty, !model.hasPicture {
                Text("Nothing written").font(.system(size: 10.5)).foregroundStyle(Color.inkFaint)
            }
            // A picture in the note: that there is one, not which.
            if model.hasPicture {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.inkText.opacity(0.06))
                    .frame(height: 36)
                    .overlay(Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(Color.inkFaint))
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.inkCard))
        // A note given a colour wears it at its head, as its tick does at the river's edge.
        .overlay(alignment: .top) {
            if let tint { UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10).fill(tint.opacity(0.85)).frame(height: 3) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isChosen || isCursor ? Color.inkAccent.opacity(isChosen ? 0.95 : 0.6) : Color.inkRule, lineWidth: isChosen ? 2 : (isCursor ? 1.5 : 1))
        )
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.inkAccent.opacity(isChosen ? 0.10 : 0)))
        .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension GraphStore {
    /// The cards of a river that are named, or say, what was typed: all of them, for nothing typed.
    func cards(of river: River, saying typed: String) -> [Card] {
        let words = typed.lowercased().split(separator: " ")
        guard !words.isEmpty else { return river.all }
        return river.all.filter { card in
            let draft = draft(path: card.path, title: card.title)
            let text = (label(path: card.path, title: card.title) + "\n" + draft.markdown).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Takes cards out of one river and puts them at the head of another:
    /// a card the other already has is only taken out.
    func send(_ ids: [Card.ID], from river: River, to other: River) {
        guard river !== other else { return }
        let sent = ids.compactMap { river.card($0) }
        for card in sent.reversed() {
            draft(path: card.path, title: card.title).saveNow()
            river.close(card.id)
            if !other.cards.contains(where: { $0.spot == card.spot }) {
                var moved = Card(path: card.path, title: card.title, focus: card.focus)
                moved.folded = card.folded
                other.cards.insert(moved, at: 0)
            }
        }
        rememberRivers()
    }
}

#if os(macOS)
/// The Mac's overview of a river: its cards as tiles filling the window.
///
/// Click a tile — or Return on the one the arrows are at — and the river
/// is back, at that card. Typing narrows the tiles to those that are
/// named, or say, what is typed. Tiles are dragged into another order;
/// several, chosen with ⌘ or ⇧ held, are folded, closed or sent to
/// another river together. Esc goes back.
struct CardsOverview: View {
    let store: GraphStore
    let river: River
    @Binding var isShown: Bool
    @State private var typed = ""
    @State private var chosen: Set<Card.ID> = []
    @State private var cursor: Card.ID?
    @State private var carried: Card.ID?
    @State private var columns = 4
    @FocusState private var focused: Bool

    private var cards: [Card] { store.cards(of: river, saying: typed) }

    var body: some View {
        let cards = cards
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.inkSecondary)
                TextField("\(store.title(of: river)) — type to narrow", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { if let at = cursor ?? cards.first?.id { go(to: at) } }
                    .onKeyPress(.leftArrow) { step(-1, in: cards) }
                    .onKeyPress(.rightArrow) { step(1, in: cards) }
                    .onKeyPress(.upArrow) { step(-columns, in: cards) }
                    .onKeyPress(.downArrow) { step(columns, in: cards) }
                    .onKeyPress(.escape) {
                        if !chosen.isEmpty { chosen = [] } else if !typed.isEmpty { typed = "" } else { isShown = false }
                        return .handled
                    }
                Text(typed.isEmpty ? "\(cards.count) cards" : "\(cards.count) of \(river.all.count)").font(.system(size: 11.5)).foregroundStyle(Color.inkFaint)
            }
            .padding(.horizontal, 22)
            .frame(height: 44)
            Rectangle().fill(Color.inkRule).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 188, maximum: 280), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        ForEach(cards) { card in
                            CardTile(store: store, river: river, card: card, isChosen: chosen.contains(card.id), isCursor: cursor == card.id)
                                .opacity(carried == card.id ? 0.4 : 1)
                                .onTapGesture { tapped(card, in: cards) }
                                .contextMenu { menu(for: card) }
                                .onDrag {
                                    carried = card.id
                                    let provider = NSItemProvider()
                                    provider.registerDataRepresentation(forTypeIdentifier: CardMove.type.identifier, visibility: .ownProcess) { done in
                                        done(Data(card.id.uuidString.utf8), nil)
                                        return nil
                                    }
                                    return provider
                                }
                                .onDrop(of: [CardMove.type], delegate: CardMove(target: card.id, river: river, store: store, carried: $carried))
                                .id(card.id)
                        }
                    }
                    .padding(22)
                    .animation(.snappy(duration: 0.22), value: cards.map(\.id))
                    if cards.isEmpty {
                        Text(typed.isEmpty ? "Nothing in this river yet" : "No card says that").font(.callout).foregroundStyle(Color.inkFaint).padding(40)
                    }
                }
                .onGeometryChange(for: Int.self) { max(Int(($0.size.width - 44 + 14) / (188 + 14)), 1) } action: { columns = $0 }
                .onChange(of: cursor) { _, at in if let at { proxy.scrollTo(at) } }
            }
            if chosen.count > 1 { bar }
        }
        .background(Color.inkPage)
        .onAppear {
            focused = true
            cursor = river.selected ?? river.all.first?.id
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

    /// What is done to several chosen together.
    private var bar: some View {
        HStack(spacing: 14) {
            Text("\(chosen.count) chosen").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.inkSecondary)
            Spacer()
            Button("Fold") { act(on: Array(chosen)) { river.card($0)?.folded == false ? river.toggleFold($0) : () } }
            Button("Unfold") { act(on: Array(chosen)) { river.card($0)?.folded == true ? river.toggleFold($0) : () } }
            Menu("Send to") { rivers(for: Array(chosen)) }.fixedSize()
            Button("Close") {
                withAnimation(.snappy(duration: 0.24)) { for id in river.all.map(\.id) where chosen.contains(id) { store.close(id, in: river) } }
                chosen = []
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 22)
        .frame(height: 40)
        .background(Color.inkCard)
        .overlay(alignment: .top) { Rectangle().fill(Color.inkRule).frame(height: 1) }
    }

    private func act(on ids: [Card.ID], _ each: (Card.ID) -> Void) {
        withAnimation(.snappy(duration: 0.2)) { ids.forEach(each) }
        store.rememberRivers()
    }

    /// The other rivers open, to send cards to.
    @ViewBuilder private func rivers(for ids: [Card.ID]) -> some View {
        let others = store.rivers.filter { $0 !== river && $0.query == nil }
        if others.isEmpty { Text("No other river is open") }
        ForEach(others) { other in
            Button(store.title(of: other)) {
                withAnimation(.snappy(duration: 0.24)) { store.send(ids, from: river, to: other) }
                chosen.subtract(ids)
            }
        }
    }

    @ViewBuilder private func menu(for card: Card) -> some View {
        // Done to those chosen, if this is one of them; else to this one.
        let ids = chosen.contains(card.id) ? river.all.map(\.id).filter(chosen.contains) : [card.id]
        Button("Go to Card", systemImage: "arrow.right") { go(to: card.id) }
        Button(card.folded ? "Unfold" : "Fold", systemImage: "chevron.up.chevron.down") { act(on: ids) { river.toggleFold($0) } }
        Button("Move to Top", systemImage: "arrow.up.to.line") { act(on: ids.reversed()) { river.move($0, toPlace: 0) } }
        Button("Move to Bottom", systemImage: "arrow.down.to.line") { act(on: ids) { river.move($0, toPlace: river.cards.count - 1) } }
        Menu("Send to River") { rivers(for: ids) }
        Divider()
        Button(ids.count > 1 ? "Close \(ids.count) Cards" : "Close", systemImage: "xmark") {
            withAnimation(.snappy(duration: 0.24)) { for id in ids { store.close(id, in: river) } }
            chosen.subtract(ids)
        }
    }

    /// A click goes to the card; with ⌘ held it is chosen, or let go; with ⇧, all from the last to it.
    private func tapped(_ card: Card, in cards: [Card]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if chosen.contains(card.id) { chosen.remove(card.id) } else { chosen.insert(card.id) }
            cursor = card.id
        } else if flags.contains(.shift), let from = cards.firstIndex(where: { $0.id == cursor }), let to = cards.firstIndex(where: { $0.id == card.id }) {
            chosen.formUnion(cards[min(from, to)...max(from, to)].map(\.id))
        } else {
            go(to: card.id)
        }
    }

    private func step(_ by: Int, in cards: [Card]) -> KeyPress.Result {
        guard !cards.isEmpty else { return .handled }
        let at = cards.firstIndex { $0.id == cursor } ?? (by > 0 ? -1 : cards.count)
        let to = at + by
        // Off the end of a row or the grid: it stays where it is.
        if cards.indices.contains(to) { cursor = cards[to].id } else if cursor == nil { cursor = cards[by > 0 ? 0 : cards.count - 1].id }
        return .handled
    }

    private func go(to id: Card.ID) {
        isShown = false
        withAnimation(.snappy(duration: 0.24)) { river.reveal(id) }
        store.rememberRivers()
    }
}
#else
/// The phone's overview of a river: its cards as tiles, two across. A
/// tap goes to the card; held, a tile says what else can be done to it.
struct CardsOverview: View {
    let store: GraphStore
    let river: River
    @Binding var isShown: Bool
    @State private var typed = ""

    var body: some View {
        let cards = store.cards(of: river, saying: typed)
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(cards) { card in
                        CardTile(store: store, river: river, card: card, isCursor: river.selected == card.id)
                            .onTapGesture {
                                isShown = false
                                withAnimation(.snappy(duration: 0.24)) { river.reveal(card.id) }
                                store.rememberRivers()
                            }
                            .contextMenu {
                                Button(card.folded ? "Unfold" : "Fold", systemImage: "chevron.up.chevron.down") { act { river.toggleFold(card.id) } }
                                Button("Move to Top", systemImage: "arrow.up.to.line") { act { river.move(card.id, toPlace: 0) } }
                                Button("Move to Bottom", systemImage: "arrow.down.to.line") { act { river.move(card.id, toPlace: river.cards.count - 1) } }
                                let others = store.rivers.filter { $0 !== river && $0.query == nil }
                                if !others.isEmpty {
                                    Menu("Send to River") {
                                        ForEach(others) { other in
                                            Button(store.title(of: other)) { withAnimation(.snappy(duration: 0.24)) { store.send([card.id], from: river, to: other) } }
                                        }
                                    }
                                }
                                Button("Close", systemImage: "xmark", role: .destructive) { withAnimation(.snappy(duration: 0.24)) { store.close(card.id, in: river) } }
                            }
                    }
                }
                .padding(14)
                .animation(.snappy(duration: 0.22), value: cards.map(\.id))
                if cards.isEmpty {
                    Text(typed.isEmpty ? "Nothing in this river yet" : "No card says that").font(.callout).foregroundStyle(Color.inkFaint).padding(40)
                }
            }
            .background(Color.inkPage)
            .navigationTitle(store.title(of: river))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $typed, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Narrow these cards")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { isShown = false } } }
            // Pinched open again: back to the river.
            .simultaneousGesture(MagnifyGesture().onEnded { if $0.magnification > 1.25 { isShown = false } })
        }
    }

    private func act(_ change: () -> Void) {
        withAnimation(.snappy(duration: 0.22)) { change() }
        store.rememberRivers()
    }
}
#endif
