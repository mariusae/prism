import Foundation
import Observation
import Prism
import SwiftUI

/// Where some words are in a text: each place any of them is, case and accents aside, in order.
enum Marks {
    static func find(_ words: [String], in text: String) -> [NSRange] {
        let string = text as NSString
        var found: [NSRange] = []
        for word in words where !word.isEmpty {
            var from = 0
            while from < string.length {
                let at = string.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: string.length - from))
                guard at.location != NSNotFound, at.length > 0 else { break }
                found.append(at)
                from = NSMaxRange(at)
            }
        }
        return found.sorted { $0.location < $1.location }
    }
}

/// Finding in the river: what is typed, found in each card's note as the
/// card shows it, every place marked; one gone to at a time, the river
/// brought to it. A card folded away is opened to show what is found in
/// it, and folded again once the find has gone on — unless it was written
/// in, or done anything to, meanwhile: then it is left open.
@MainActor
@Observable
public final class RiverFind {
    public var isShown = false
    public var typed = "" { didSet { if typed != oldValue { search() } } }
    /// Each place found: its card, and where in what the card shows.
    public private(set) var hits: [(card: Card.ID, range: NSRange)] = []
    /// The place gone to now.
    public private(set) var current: Int?
    /// Moved each time the find goes somewhere: what brings it into sight.
    public private(set) var moves = 0

    @ObservationIgnored weak var store: GraphStore?
    /// The cards opened to show what was found, each with its note's
    /// revision when it was: one changed since was done something to.
    @ObservationIgnored private var opened: [Card.ID: Int] = [:]

    /// The places found in a card, while the find is shown; `nil`, none.
    func marks(of card: Card.ID) -> [NSRange]? {
        guard isShown else { return nil }
        let mine = hits.filter { $0.card == card }.map(\.range)
        return mine.isEmpty ? nil : mine
    }

    /// Which of a card's places is the one gone to, if one of its is.
    func at(_ card: Card.ID) -> Int? {
        guard isShown, let current, hits.indices.contains(current), hits[current].card == card else { return nil }
        return hits[..<current].filter { $0.card == card }.count
    }

    public func show() {
        isShown = true
        search()
    }

    /// Put away: the cards it opened folded again, as they were.
    public func close() {
        isShown = false
        refold(except: nil)
        hits = []
        current = nil
    }

    /// The text each card shows: what it shows of its note, or the note.
    private func text(of card: Card, in store: GraphStore) -> String {
        let draft = store.draft(path: card.path, title: card.title)
        return (draft.view(of: card) ?? draft.editor).text()
    }

    func search() {
        guard isShown, let store else { return }
        let words = typed.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else {
            hits = []
            current = nil
            return
        }
        hits = store.river.all.flatMap { card in Marks.find([words], in: text(of: card, in: store)).map { (card.id, $0) } }
        current = hits.isEmpty ? nil : 0
        go()
    }

    /// The next place found — or, `back`, the one before; round from the end to the start.
    public func step(back: Bool = false) {
        guard !hits.isEmpty else { return }
        let now = current ?? (back ? 0 : -1)
        current = (now + (back ? -1 : 1) + hits.count) % hits.count
        go()
    }

    private func go() {
        guard let store, let current, hits.indices.contains(current) else { return }
        let card = hits[current].card
        let river = store.river
        refold(except: card)
        if river.card(card)?.folded == true {
            river.toggleFold(card)
            if let shown = river.card(card) { opened[card] = store.draft(path: shown.path, title: shown.title).revision }
        }
        river.reveal(card, unfolding: false)
        moves += 1
    }

    /// Folds again the cards the find opened, but for `except` and those
    /// done anything to since: written in, or the note changed.
    private func refold(except keep: Card.ID?) {
        guard let store else { return }
        let river = store.river
        for (card, revision) in opened where card != keep {
            opened[card] = nil
            guard let shown = river.card(card), !shown.folded, river.writing != card else { continue }
            guard store.draft(path: shown.path, title: shown.title).revision == revision else { continue }
            river.toggleFold(card)
        }
    }
}

#if os(macOS)
/// The find bar: at the river's top right, as a document's is.
struct FindBar: View {
    @Bindable var find: RiverFind
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.inkSecondary)
            TextField("Find in River", text: $find.typed)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 180)
                .focused($focused)
                .onSubmit { find.step(back: NSEvent.modifierFlags.contains(.shift)) }
                .onKeyPress(.escape) {
                    find.close()
                    return .handled
                }
            Text(said).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Color.inkFaint).fixedSize()
            Divider().frame(height: 16)
            Button { find.step(back: true) } label: { Image(systemName: "chevron.up").frame(width: 20, height: 20).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(find.hits.isEmpty).help("Previous (⇧⌘G)")
            Button { find.step() } label: { Image(systemName: "chevron.down").frame(width: 20, height: 20).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(find.hits.isEmpty).help("Next (⌘G)")
            Button { find.close() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.inkFaint).frame(width: 20, height: 20).contentShape(Rectangle()) }
                .buttonStyle(.plain).help("Done (Esc)")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.inkSecondary)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.inkRule, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .onAppear { focused = true }
        .onChange(of: find.isShown) { _, shown in if shown { focused = true } }
    }

    private var said: String {
        guard !find.typed.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        guard let current = find.current else { return "Not found" }
        return "\(current + 1) of \(find.hits.count)"
    }
}
#endif
