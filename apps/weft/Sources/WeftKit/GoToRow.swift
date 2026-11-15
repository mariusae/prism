#if os(macOS)
import Prism
import PrismEmblem
import SwiftUI

/// Go to a row of the river shown (⌥⌘P), as Bike goes to a row: every
/// card's outline, one under another, narrowed to the rows saying what is
/// typed — each with the rows it is under, quieter, so that the outline is
/// still seen. Chosen, the card is opened, the row unfolded into sight, and
/// the caret put at its words.
struct GoToRow: View {
    let store: GraphStore
    @Binding var isShown: Bool
    @State var typed = ""
    @State private var chosen = 0
    @State private var outlines: [Outline] = []
    @FocusState private var focused: Bool
    /// Where the pointer lay when the list was last drawn or arrowed through: until it moves from there, it chooses nothing.
    @State private var still = NSEvent.mouseLocation

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

    private var words: [String] {
        typed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The outlines, narrowed: the rows found, each under the rows it is under; a card with none found, left out.
    private var lines: [Line] {
        let words = words
        var lines: [Line] = []
        for outline in outlines {
            let says = { (text: String) in words.allSatisfy { text.lowercased().contains($0) } }
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

    var body: some View {
        let lines = lines
        let choosable = lines.indices.filter { lines[$0].isFound }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.indent").font(.system(size: 17, weight: .medium)).foregroundStyle(Color.inkSecondary)
                TextField("Go to a row in \(store.title(of: store.river))", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.inkText)
                    .focused($focused)
                    .onSubmit { go(lines, choosable) }
                    .onKeyPress(.downArrow) { move(1, choosable.count) }
                    .onKeyPress(.upArrow) { move(-1, choosable.count) }
                    .onKeyPress(.escape) {
                        isShown = false
                        return .handled
                    }
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            Rectangle().fill(Color.inkRule).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { at, line in
                            let place = choosable.firstIndex(of: at)
                            lineView(line, chosen: place == chosen)
                                .id(line.id)
                                .contentShape(Rectangle())
                                .onHover { if $0, let place, NSEvent.mouseLocation != still { chosen = place } }
                                .onTapGesture {
                                    guard let place else { return }
                                    chosen = place
                                    go(lines, choosable)
                                }
                        }
                        if choosable.isEmpty {
                            Text(outlines.isEmpty ? "No rows in this river" : "No row says that").font(.callout).foregroundStyle(Color.inkFaint).padding(14)
                        }
                    }
                    .padding(8)
                }
                .frame(height: min(CGFloat(max(lines.count, 1)) * 30 + 16, 480))
                .onChange(of: chosen) { _, place in
                    if choosable.indices.contains(place) { proxy.scrollTo(lines[choosable[place]].id) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.inkPaper))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.inkRule))
        .shadow(color: .black.opacity(0.20), radius: 24, y: 10)
        .frame(maxWidth: 620)
        .padding(.horizontal, 24)
        .onAppear {
            focused = true
            still = NSEvent.mouseLocation
            read()
        }
        .onChange(of: typed) { _, _ in chosen = 0 }
    }

    private func lineView(_ line: Line, chosen: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let emblem = line.emblem {
                EmblemView(emblem, size: 16, style: .plain, quiet: Color.inkSecondary)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            } else {
                Image(systemName: line.done == true ? "checkmark.square" : line.done == false ? "square" : "circle.fill")
                    .font(.system(size: line.done == nil ? 4.5 : 11))
                    .foregroundStyle(Color.inkFaint)
                    .frame(width: 12)
            }
            Text(line.words.isEmpty ? " " : line.words)
                .font(.system(size: line.row == nil ? 13.5 : 13.5, weight: line.row == nil || line.heading ? .semibold : .regular))
                .foregroundStyle(line.isFound ? (line.done == true ? Color.inkSecondary : Color.inkText) : Color.inkFaint)
                .strikethrough(line.done == true, color: Color.inkFaint)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12 + CGFloat(line.depth) * 18)
        .padding(.trailing, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chosen ? Color.inkHover : .clear))
    }

    /// Every card's outline, as its note now is.
    private func read() {
        outlines = store.river.all.map { card in
            let draft = store.draft(path: card.path, title: card.title)
            let editor = draft.view(of: card) ?? draft.editor
            // Its links by their pages' titles, as the card shows them — a card not yet drawn has not said.
            let targets = editor.linkTargets()
            if !targets.isEmpty {
                editor.setLinkLabels(labels: Dictionary(uniqueKeysWithValues: targets.map { ($0, riverName(linkTarget: $0) ?? store.linkLabel($0) ?? $0) }))
            }
            let title = store.label(path: card.path, title: card.title)
            return Outline(card: card.id, title: title, emblem: store.emblem(path: card.path, title: card.title), rows: editor.outline())
        }
    }

    private func move(_ step: Int, _ count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        still = NSEvent.mouseLocation
        chosen = (chosen + step + count) % count
        return .handled
    }

    private func go(_ lines: [Line], _ choosable: [Int]) {
        guard choosable.indices.contains(chosen) else { return }
        let line = lines[choosable[chosen]]
        isShown = false
        if let row = line.row {
            store.goToRow(card: line.card, index: row)
        } else {
            store.river.selected = line.card
            store.river.reveal(line.card)
        }
    }
}
#endif
