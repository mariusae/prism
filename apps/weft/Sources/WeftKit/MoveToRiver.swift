import Prism
import PrismEmblem
import SwiftUI

/// Where a card can be moved: a river open in another tab, a saved river
/// not open, or a new river made for it.
public enum RiverTarget: Hashable {
    case open(UUID)
    case saved(String)
    case new(String)
}

extension GraphStore {
    /// The rivers a card can go to from one: those open (but it, and any
    /// whose cards a query chooses), in their tabs' order; then the saved
    /// ones not open, by name.
    public func moveTargets(from river: River) -> (open: [River], saved: [SavedRiverInfo]) {
        let open = rivers.filter { $0 !== river && $0.query == nil }
        let names = Set(rivers.compactMap(\.name))
        let saved = savedRivers.filter { !names.contains($0.name) && !$0.isQuery }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return (open, saved)
    }

    /// What a target is called.
    public func name(of target: RiverTarget) -> String {
        switch target {
        case .open(let id): rivers.first { $0.id == id }.map { title(of: $0) } ?? "River"
        case .saved(let name), .new(let name): name
        }
    }

    /// Cards taken out of a river and put at the head of another — or,
    /// `copying`, put there and kept here too. The river shown stays as it
    /// is, but for the cards gone; undone, all is as it was.
    public func move(_ ids: [Card.ID], from river: River, to target: RiverTarget, copying: Bool = false) {
        let cards = ids.compactMap { river.card($0) }
        guard !cards.isEmpty else { return }
        for card in cards { draft(path: card.path, title: card.title).saveNow() }
        let here = river.cards
        let said = cards.count == 1 ? "“\(label(path: cards[0].path, title: cards[0].title))”" : "\(cards.count) cards"
        let verb = copying ? "Copied" : "Moved"
        switch target {
        case .open(let id):
            guard let other = rivers.first(where: { $0.id == id }), other !== river else { return }
            let there = other.cards
            withAnimation(.snappy(duration: 0.24)) { send(ids, from: river, to: other, copying: copying) }
            undoable("\(verb) \(said) to \(title(of: other))") { [weak self] in
                river.cards = here
                other.cards = there
                self?.rememberRivers()
            }
        case .saved(let name):
            guard var saved = (try? engine.river(name: name)) ?? nil else { return }
            let before = saved
            let known = Set(saved.cards.map { nameKey(name: $0.title) + "|" + ($0.focus ?? "") })
            let added = cards.filter { !known.contains(nameKey(name: self.name(of: $0)) + "|" + ($0.focus ?? "")) }
            saved.cards.insert(contentsOf: added.map { RiverCard(title: self.name(of: $0), focus: $0.focus, foldedRows: $0.foldedRows, placeRank: nil, placeKey: nil) }, at: 0)
            guard (try? engine.saveRiver(name: name, river: saved)) == true else { return }
            if !copying { withAnimation(.snappy(duration: 0.24)) { for card in cards { river.close(card.id) } } }
            noteSaved(name)
            rememberRivers()
            undoable("\(verb) \(said) to \(name)") { [weak self] in
                guard let self else { return }
                _ = try? self.engine.saveRiver(name: name, river: before)
                self.noteSaved(name)
                river.cards = here
                self.rememberRivers()
            }
        case .new(let name):
            let made = River()
            made.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name.trimmingCharacters(in: .whitespaces)
            made.cards = cards.map { card in
                var moved = Card(path: card.path, title: card.title, focus: card.focus, lens: card.lens)
                moved.folded = card.folded
                return moved
            }
            if !copying { withAnimation(.snappy(duration: 0.24)) { for card in cards { river.close(card.id) } } }
            // A tab of its own, after this one; this one stays shown.
            let shown = river.id
            rivers.insert(made, at: min(currentRiver + 1, rivers.count))
            currentRiver = rivers.firstIndex { $0.id == shown } ?? currentRiver
            if made.name != nil { save(made) }
            rememberRivers()
            undoable("\(verb) \(said) to \(made.name ?? "a new river")") { [weak self] in
                guard let self else { return }
                self.rivers.removeAll { $0 === made }
                if let name = made.name { _ = try? self.engine.deleteRiver(name: name) }
                self.currentRiver = self.rivers.firstIndex { $0.id == shown } ?? 0
                river.cards = here
                self.rememberRivers()
            }
        }
    }
}

/// Finds a river to move cards to, as ⌘O finds a note: the rivers open
/// first, then those saved and not open; a name no river has, a new one.
/// Return moves, ⌥Return copies, Esc goes.
struct RiverPicker: View {
    let store: GraphStore
    let river: River
    /// What is moved, as the heading says it.
    let what: String
    var choose: (RiverTarget, Bool) -> Void
    var cancel: () -> Void
    @State private var typed = ""
    @State private var chosen = 0
    @FocusState private var focused: Bool

    private struct Row: Identifiable {
        var target: RiverTarget
        var name: String
        var detail: String
        var emblem: Emblem
        var id: RiverTarget { target }
    }

    private var rows: [Row] {
        let (open, saved) = store.moveTargets(from: river)
        let words = typed.lowercased().split { !$0.isLetter && !$0.isNumber }
        let matches = { (name: String) in
            let known = name.lowercased().split { !$0.isLetter && !$0.isNumber }
            return words.allSatisfy { word in known.contains { $0.hasPrefix(word) } }
        }
        var rows = open.filter { matches(store.title(of: $0)) }.map {
            Row(target: .open($0.id), name: store.title(of: $0), detail: $0.all.isEmpty ? "Empty" : "\($0.all.count) \($0.all.count == 1 ? "card" : "cards")", emblem: Emblem(title: store.title(of: $0), icon: $0.icon, color: $0.color))
        }
        rows += saved.filter { matches($0.name) }.map {
            Row(target: .saved($0.name), name: $0.name, detail: "\($0.cards) \($0.cards == 1 ? "card" : "cards")", emblem: $0.emblem)
        }
        let name = typed.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !rows.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            rows.append(Row(target: .new(name), name: "New river “\(name)”", detail: "", emblem: Emblem(symbol: "plus")))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            Text("Move \(what) to…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkSecondary)
                .padding(.horizontal, 18).padding(.top, 14)
            TextField("Find a river, or name a new one", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($focused)
                .onSubmit { pick(rows, copying: false) }
                #if os(macOS)
                .onKeyPress(.downArrow) { step(1, in: rows) }
                .onKeyPress(.upArrow) { step(-1, in: rows) }
                .onKeyPress(.escape) { cancel(); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.option) else { return .ignored }
                    pick(rows, copying: true)
                    return .handled
                }
                #endif
                .padding(.horizontal, 18).padding(.vertical, 10)
            Rectangle().fill(Color.inkRule).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if let heading = heading(of: row.target, after: index > 0 ? rows[index - 1].target : nil) {
                            Text(heading).font(.system(size: 10.5, weight: .semibold)).kerning(0.6).foregroundStyle(Color.inkFaint)
                                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                        }
                        HStack(spacing: 10) {
                            EmblemView(row.emblem, size: 20, style: .plain, quiet: Color.inkSecondary)
                            Text(row.name).font(.system(size: 14.5)).foregroundStyle(Color.inkText).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(row.detail).font(.system(size: 12)).foregroundStyle(Color.inkFaint)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(index == chosen ? Color.inkHover : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { choose(row.target, false) }
                    }
                    if rows.isEmpty {
                        Text("No other river").font(.callout).foregroundStyle(Color.inkFaint).padding(14)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
        }
        .frame(maxWidth: 480)
        .onAppear { focused = true }
        .onChange(of: typed) { _, _ in chosen = 0 }
    }

    /// Each kind's heading, over its first row.
    private func heading(of target: RiverTarget, after before: RiverTarget?) -> String? {
        func kind(_ target: RiverTarget?) -> Int? {
            switch target {
            case .open: 0
            case .saved: 1
            case .new: 2
            case nil: nil
            }
        }
        guard kind(target) != kind(before) else { return nil }
        switch target {
        case .open: return "OPEN"
        case .saved: return "SAVED"
        case .new: return nil
        }
    }

    private func step(_ by: Int, in rows: [Row]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        chosen = (chosen + by + rows.count) % rows.count
        return .handled
    }

    /// The row chosen, of the rows as they are now — not as they were when the field was last drawn.
    private func pick(_ _: [Row], copying: Bool) {
        let rows = rows
        guard rows.indices.contains(chosen) else { return }
        choose(rows[chosen].target, copying)
    }
}

/// "Move to River": the rivers open, then those saved and not open, then
/// a river found by name or made anew. Chosen with ⌥ held, the cards are
/// copied there instead — kept here too.
struct MoveToRiverMenu: View {
    let store: GraphStore
    let river: River
    let ids: [Card.ID]

    private var copying: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option)
        #else
        false
        #endif
    }

    var body: some View {
        let (open, saved) = store.moveTargets(from: river)
        Menu("Move to River", systemImage: "arrow.right.square") {
            ForEach(open) { other in
                Button(store.title(of: other)) { store.move(ids, from: river, to: .open(other.id), copying: copying) }
            }
            if !open.isEmpty, !saved.isEmpty { Divider() }
            ForEach(saved) { one in
                Button(one.name) { store.move(ids, from: river, to: .saved(one.name), copying: copying) }
            }
            Divider()
            Button("Choose…") { store.movingCards = .init(ids: ids, river: river) }
        }
    }
}
