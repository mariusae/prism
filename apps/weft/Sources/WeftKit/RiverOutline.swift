import Foundation
import Prism
import PrismEmblem

/// A river's cards as outlines, narrowed to the rows that say what is
/// typed — each with the rows it is under, so that the outline is still
/// seen: what Go to Row lists on the Mac, and the phone's overview once
/// something is typed into it.
@MainActor
enum RiverOutline {
    /// A card's note as an outline: its rows, folded away or not.
    struct Outline {
        var card: Card.ID
        var title: String
        var emblem: Emblem
        var rows: [BodyOutlineRow]
    }

    /// A line of the list: a card's title, or a row of its outline.
    struct Line: Identifiable {
        var id: String
        var card: Card.ID
        /// The row's place in its note; `nil` for the card's own title.
        var row: UInt32?
        var depth: Int
        var words: String
        var emblem: Emblem?
        var heading: Bool
        var done: Bool?
        /// Said by what was typed — or, nothing typed, every row: what can be chosen.
        var isFound: Bool
    }

    /// Every card's outline, as its note now is.
    static func read(_ river: River, in store: GraphStore) -> [Outline] {
        river.all.map { card in
            let draft = store.draft(path: card.path, title: card.title)
            let editor = draft.view(of: card) ?? draft.editor
            // Its links by their pages' titles, as the card shows them — a card not yet drawn has not said.
            let targets = editor.linkTargets()
            if !targets.isEmpty {
                editor.setLinkLabels(labels: Dictionary(uniqueKeysWithValues: targets.map { ($0, riverName(linkTarget: $0) ?? store.linkLabel($0) ?? $0) }))
            }
            return Outline(card: card.id, title: store.label(path: card.path, title: card.title), emblem: store.emblem(path: card.path, title: card.title), rows: editor.outline())
        }
    }

    /// The outlines, narrowed: the rows found, each under the rows it is
    /// under; a card with none found, and not called so, left out.
    static func lines(_ outlines: [Outline], typed: String) -> [Line] {
        let words = typed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let says = { (text: String) in words.allSatisfy { text.lowercased().contains($0) } }
        var lines: [Line] = []
        for outline in outlines {
            var shown = Set<Int>()
            var found = Set<Int>()
            for (index, row) in outline.rows.enumerated() where words.isEmpty || says(row.words) {
                found.insert(index)
                shown.insert(index)
                // The rows it is under: each the last before it that is less deep.
                var depth = row.depth
                var at = index - 1
                while at >= 0, depth > 0 {
                    if outline.rows[at].depth < depth {
                        shown.insert(at)
                        depth = outline.rows[at].depth
                    }
                    at -= 1
                }
            }
            let titled = !words.isEmpty && says(outline.title)
            guard !shown.isEmpty || titled || words.isEmpty else { continue }
            lines.append(Line(id: "\(outline.card)", card: outline.card, row: nil, depth: 0, words: outline.title, emblem: outline.emblem, heading: true, done: nil, isFound: words.isEmpty || titled))
            for index in shown.sorted() {
                let row = outline.rows[index]
                lines.append(Line(id: "\(outline.card):\(row.index)", card: outline.card, row: row.index, depth: Int(row.depth) + 1, words: row.words, emblem: nil, heading: row.heading != nil, done: row.done, isFound: found.contains(index)))
            }
        }
        return lines
    }
}
