import Prism
import PrismEditor
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A card carried onto another card's note — held still over its rows a
/// moment — stops being a card among cards and becomes a row of that
/// note: its title, with all it says under it. From then on it is
/// carried as rows are, a line showing where it would go, from note to
/// note; let go of, it is put there and its own note is gone — or, on
/// the Mac with ⌥ held, copied, and the card stays where it was.
///
/// Where the pointer is, is told: on the Mac, on the screen; on the
/// phone, in the window.
@MainActor
final class CardIntoNote {
    static let shared = CardIntoNote()

    /// How long the pointer rests on a note before what is carried becomes a row.
    private static let rest: Duration = .milliseconds(450)

    private(set) var card: Card?
    private weak var river: River?
    /// Where the card was among the river's when picked up: where it goes back to.
    private var place: Int?
    /// Whether the card has become a row, carried over notes.
    private(set) var isRow = false
    /// The note showing where the row would go.
    private weak var note: NoteTextView?
    /// Where the pointer was last told to be.
    private var last = CGPoint.zero
    private var resting: (point: CGPoint, wait: Task<Void, Never>)?
    #if os(macOS)
    private var watch: Task<Void, Never>?
    #endif

    private static func note(at point: CGPoint) -> NoteTextView? {
        #if os(macOS)
        NoteTextView.at(screen: point)
        #else
        NoteTextView.at(point)
        #endif
    }

    /// A card picked up, to be carried.
    func begin(_ card: Card, in river: River) {
        end()
        self.card = card
        self.river = river
        place = river.all.firstIndex { $0.id == card.id }
        #if os(macOS)
        // Let go of anywhere, or the carrying given up: over.
        watch = Task { [weak self] in
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { self?.end() }
        }
        #endif
    }

    func end() {
        note?.hideRowsDrop()
        note = nil
        resting?.wait.cancel()
        resting = nil
        #if os(macOS)
        watch?.cancel()
        watch = nil
        #endif
        card = nil
        river = nil
        place = nil
        isRow = false
    }

    /// Whether a card is another's note to put what is carried in.
    private func takes(_ target: Card?) -> Bool {
        guard let card, let target else { return false }
        return target.id != card.id && target.path != card.path
    }

    /// The pointer over a card, the carried card over it: rested on its
    /// note, the card becomes a row; a row, the line follows the pointer.
    func moved(over target: Card?, at point: CGPoint) {
        guard card != nil else { return }
        last = point
        if isRow { return show(at: point, over: target) }
        guard takes(target), Self.note(at: point) != nil else {
            resting?.wait.cancel()
            resting = nil
            return
        }
        if let resting, hypot(resting.point.x - point.x, resting.point.y - point.y) < 6 { return }
        resting?.wait.cancel()
        let wait = Task { [weak self] in
            try? await Task.sleep(for: Self.rest)
            guard !Task.isCancelled, let self else { return }
            let now = self.last
            guard hypot(now.x - point.x, now.y - point.y) < 6, Self.note(at: now) != nil else { return }
            self.isRow = true
            #if os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            #else
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            self.show(at: now, over: target)
        }
        resting = (point, wait)
    }

    /// Off a card: no line shown, until the pointer is over another's note.
    func left() {
        note?.hideRowsDrop()
        note = nil
        if !isRow {
            resting?.wait.cancel()
            resting = nil
        }
    }

    private func show(at point: CGPoint, over target: Card?) {
        let under = takes(target) ? Self.note(at: point) : nil
        if under !== note { note?.hideRowsDrop() }
        note = under
        #if os(macOS)
        note?.showRowsDrop(atScreen: point)
        #else
        note?.showRowsDrop(at: point)
        #endif
    }

    /// Let go of over a card: the row put in its note, where the line
    /// showed. Says whether it was.
    func put(on target: Card?, at point: CGPoint, copying: Bool, store: GraphStore) -> Bool {
        defer { end() }
        guard isRow, let card, let river, let target, takes(target) else { return false }
        let draft = store.draft(path: card.path, title: card.title)
        draft.saveNow()
        guard let source = (try? store.engine.read(path: card.path)) ?? nil, let note = Self.note(at: point) else { return false }
        let row = noteAsRow(source: source, path: card.path)
        #if os(macOS)
        guard note.put(rows: row, atScreen: point) else { return false }
        #else
        guard note.put(rows: row, at: point) else { return false }
        #endif
        // In the river, the card goes back to where it was: copied, it stays there; moved, it is gone, and comes back there undone.
        if let place { river.move(card.id, toPlace: place) }
        if !copying {
            let said = "Moved “\(store.label(path: card.path, title: card.title))” into “\(store.label(path: target.path, title: target.title))”"
            store.delete(card.id, in: river, saying: said)
        }
        return true
    }
}
