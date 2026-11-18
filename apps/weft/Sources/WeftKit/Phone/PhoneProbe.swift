#if os(iOS) && DEBUG
import Foundation
import PrismEditor

/// A harness's way to carry rows, or a card, from note to note in the
/// river shown, as a finger would — what the simulator's own touches
/// cannot: hold, then move. Launched with `-ProbeCarry rows|card` and
/// `-ProbeOut <file>`, on a graph named with `-GraphPath`; the first card
/// shown is carried from, the second into.
@MainActor
enum PhoneProbe {
    static func run(_ store: GraphStore) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-GraphPath"), let at = arguments.firstIndex(of: "-ProbeCarry"), arguments.indices.contains(at + 1),
              let out = arguments.firstIndex(of: "-ProbeOut").map({ arguments[$0 + 1] }) else { return }
        let mode = arguments[at + 1]
        try? await Task.sleep(for: .seconds(2))
        let cards = store.river.all
        guard cards.count >= 2 else { return write(out, "fewer than two cards") }
        let (from, onto) = (cards[0], cards[1])
        let notes = NoteTextView.onScreen
        guard let source = notes.first(where: { $0.windowPoint(of: "Beta point") != nil }),
              let target = notes.first(where: { $0.windowPoint(of: "Third row here") != nil }),
              let grab = source.windowPoint(of: "Beta point"), var place = target.windowPoint(of: "Third row here")
        else { return write(out, "notes not found: \(notes.count)") }
        place.y -= 8
        var said = "mode=\(mode)\n"
        switch mode {
        case "rows":
            said += "carried=\(source.probeCarry(from: grab, to: place))\n"
        default:
            let carry = CardIntoNote.shared
            carry.begin(from, in: store.river)
            carry.moved(over: onto, at: place)
            try? await Task.sleep(for: .milliseconds(700))
            said += "isRow=\(carry.isRow)\n"
            said += "put=\(carry.put(on: onto, at: place, copying: false, store: store))\n"
        }
        try? await Task.sleep(for: .seconds(1.5))
        store.saveAll()
        try? await Task.sleep(for: .milliseconds(500))
        said += "onto:\n" + (((try? store.engine.read(path: onto.path)) ?? nil) ?? "(none)")
        said += "\nfrom:\n" + (((try? store.engine.read(path: from.path)) ?? nil) ?? "(gone)")
        write(out, said)
    }

    private static func write(_ file: String, _ text: String) {
        FileManager.default.createFile(atPath: file, contents: Data(text.utf8))
    }
}
#endif
