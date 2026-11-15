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

    typealias Outline = RiverOutline.Outline
    typealias Line = RiverOutline.Line

    private var lines: [Line] { RiverOutline.lines(outlines, typed: typed) }

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
        outlines = RiverOutline.read(store.river, in: store)
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
