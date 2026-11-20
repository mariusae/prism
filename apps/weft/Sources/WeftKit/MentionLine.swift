import SwiftUI
#if os(macOS)
import AppKit
import PrismEditor
#else
import UIKit
#endif

/// The pages that link to a note, at its foot: one line of quiet text —
/// "Linked from Ada, Cosmo, and 7 more". Each name goes to where that page
/// speaks of the note; "Linked from" to a river of them all; "7 more" to
/// the rest, listed.
struct MentionLine: View {
    let titles: [String]
    /// Beside each name, the icon it is shown with, if any: a river's.
    var icons: [String?] = []
    var open: (Int) -> Void
    var openAll: () -> Void
    /// What a name shows of its note — under the pointer a moment, on the
    /// Mac; held, on the phone — as a link does: where it speaks of this one.
    var preview: ((Int) -> AnyView?)?
    @State private var width: CGFloat = 320
    #if os(macOS)
    @State private var hover = MentionHover()
    #endif

    private static let size: CGFloat = {
        #if os(macOS)
        12
        #else
        13
        #endif
    }()

    /// How wide words are in the line's face: the set's label face — what is said about a note.
    @MainActor private static func measure(_ words: String) -> CGFloat {
        let font = TextSettings.face.font(.label, size: size)
        return ceil((words as NSString).size(withAttributes: [.font: font]).width)
    }

    /// How many names fit the line whole, with room left for "and N more".
    private func fitting() -> Int {
        var used = Self.measure("Linked from ") + 14
        for (index, title) in titles.enumerated() {
            let left = titles.count - index - 1
            let next = used + Self.measure(title + (left > 0 ? ", " : "")) + (icon(index) == nil ? 0 : Self.size + 3)
            let more = left > 0 ? Self.measure(" and \(left) more") : 0
            if next + more > width { return max(index, 1) }
            used = next
        }
        return titles.count
    }

    private func icon(_ index: Int) -> String? { icons.indices.contains(index) ? icons[index] : nil }

    var body: some View {
        let shown = min(fitting(), titles.count)
        HStack(spacing: 0) {
            Button { openAll() } label: { Text("Linked from ").foregroundStyle(Color.inkFaint) }
                .buttonStyle(.plain)
                .help("Every Mention, as a River")
            ForEach(Array(titles.prefix(shown).enumerated()), id: \.offset) { index, title in
                let name = Button { open(index) } label: {
                    HStack(spacing: 3) {
                        if let icon = icon(index) { Image(systemName: icon).font(.system(size: Self.size * 0.85)).foregroundStyle(Color.inkFaint) }
                        Text(title).foregroundStyle(Color.inkSecondary).lineLimit(1)
                    }
                }
                    .buttonStyle(.plain)
                #if os(macOS)
                name.pointerStyle(.link)
                    .onHover { inside in
                        if inside, let card = preview?(index) { hover.enter(index, showing: card) } else { hover.leave(index) }
                    }
                    .simultaneousGesture(TapGesture().onEnded { hover.close() })
                #else
                if let shown = preview?(index) {
                    name.contextMenu {
                        Button("Open", systemImage: "arrow.up.forward") { open(index) }
                    } preview: {
                        shown.frame(width: 300)
                    }
                } else {
                    name
                }
                #endif
                if index < shown - 1 || shown < titles.count {
                    Text(index < shown - 1 ? ", " : " ").foregroundStyle(Color.inkFaint)
                }
            }
            if shown < titles.count {
                Menu {
                    ForEach(Array(titles.enumerated().dropFirst(shown)), id: \.offset) { index, title in
                        Button(title) { open(index) }
                    }
                } label: {
                    Text("and \(titles.count - shown) more").foregroundStyle(Color.inkSecondary).underline(color: Color.inkRule)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                #if os(macOS)
                .menuIndicator(.hidden)
                .fixedSize()
                #endif
            }
            Spacer(minLength: 0)
        }
        .font(TextSettings.font(Self.size, role: .label))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
    }
}

#if os(macOS)
/// A name's card, by the pointer once it has rested on the name a moment —
/// as a link's in a note is — and gone once the pointer is off both.
@MainActor
final class MentionHover {
    private var on: Int?
    private var card: HoverCard?
    private var wait: Task<Void, Never>?

    func enter(_ index: Int, showing content: AnyView) {
        guard on != index else { return }
        on = index
        close()
        wait = Task { [weak self] in
            // Long enough that passing over a name shows nothing.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.on == index, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            let card = HoverCard(content: content, at: NSEvent.mouseLocation, over: window)
            card.onLeave = { [weak self] in self?.leaveSoon() }
            self.card = card
        }
    }

    func leave(_ index: Int) {
        guard on == index else { return }
        on = nil
        leaveSoon()
    }

    /// Gone unless, a moment on, the pointer is on the card — or back on a name.
    private func leaveSoon() {
        wait?.cancel()
        guard card != nil else { return }
        wait = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let card = self.card, !card.isPointed, self.on == nil else { return }
            self.close()
        }
    }

    func close() {
        wait?.cancel()
        wait = nil
        card?.close()
        card = nil
    }
}
#endif
