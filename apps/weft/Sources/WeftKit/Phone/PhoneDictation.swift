#if os(iOS)
import PrismDictation
import PrismEditor
import SwiftUI
import UIKit

/// + held: a new note at once, and what is said written straight into it
/// as it is heard — the same way words are said into any note, in place.
/// Let go, the note is kept; slid well up from the + first, or nothing
/// said, it is taken away again.
@MainActor
@Observable
final class HeldDictation {
    /// + held, as a microphone.
    private(set) var listening = false
    /// Why it can't listen, said for a moment.
    private(set) var problem: String?
    /// The note made to say into, and its river.
    @ObservationIgnored private var made: (card: Card.ID, river: River)?
    /// Whether the words are going into it yet.
    @ObservationIgnored private var started = false
    /// Let go before the words could go in: how — given up, or kept.
    @ObservationIgnored private var letGo: Bool?
    @ObservationIgnored private var asking = false

    func begin(store: GraphStore) {
        guard made == nil, !asking else { return }
        listening = true
        problem = nil
        letGo = nil
        started = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        asking = true
        Task { @MainActor in
            defer { asking = false }
            guard await Dictation.allowed() else {
                listening = false
                return say("Weft can\u{2019}t listen: allow the microphone in Settings.")
            }
            // Let go while being asked: nothing.
            guard listening else { return }
            guard let card = withAnimation(.snappy(duration: 0.28), { store.newNote(written: "") }) else {
                listening = false
                return
            }
            made = (card.id, store.river)
            // Its own view, once it is on screen: where the words go.
            let editor = store.draft(path: card.path, title: card.title).editor
            var view: NoteTextView?
            for _ in 0..<40 {
                view = NoteTextView.showing(editor)
                if view != nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let view, await NoteDictation.start(in: view) else {
                listening = false
                discard(store)
                return say("Dictation isn\u{2019}t available right now.")
            }
            started = true
            // Let go meanwhile: concluded now.
            if let letGo { await conclude(cancelled: letGo, store: store) }
        }
    }

    /// Let go: kept, or — `cancelled`, slid away first — given up.
    func end(cancelled: Bool, store: GraphStore) {
        listening = false
        guard made != nil || asking else { return }
        guard started else {
            letGo = cancelled
            return
        }
        Task { @MainActor in await conclude(cancelled: cancelled, store: store) }
    }

    private func conclude(cancelled: Bool, store: GraphStore) async {
        guard let made else { return }
        started = false
        letGo = nil
        if cancelled {
            NoteDictation.cancel()
            discard(store)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        let said = await NoteDictation.stop()
        // Nothing said: no note.
        guard !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return discard(store) }
        self.made = nil
        if let card = made.river.card(made.card) { store.draft(path: card.path, title: card.title).saveNow() }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func discard(_ store: GraphStore) {
        guard let made else { return }
        self.made = nil
        withAnimation(.snappy(duration: 0.28)) { store.discard(made.card, in: made.river) }
    }

    private func say(_ words: String) {
        problem = words
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if problem == words { problem = nil }
        }
    }
}

/// A finger on a view, as UIKit sees it: down the moment it lands, up with
/// how far it went, or taken away.
struct Press: UIGestureRecognizerRepresentable {
    enum Phase { case down, up(CGSize), taken }
    let phase: (Phase) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        return press
    }

    func handleUIGestureRecognizerAction(_ press: UILongPressGestureRecognizer, context: Context) {
        let at = press.location(in: press.view)
        switch press.state {
        case .began:
            context.coordinator.start = at
            phase(.down)
        case .ended:
            let start = context.coordinator.start
            phase(.up(CGSize(width: at.x - start.x, height: at.y - start.y)))
        case .cancelled, .failed:
            phase(.taken)
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator { var start = CGPoint.zero }
}

/// Over the bar while + is held: what is heard, as it comes — or, for a
/// moment, why it can't listen.
struct HeardBubble: View {
    let text: String
    /// Still waiting for words: said quietly.
    var quiet = false

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(quiet ? Color.inkSecondary : Color.inkText)
            .lineLimit(4)
            // The last of what was heard stays in sight.
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
            .allowsHitTesting(false)
    }
}
#endif
