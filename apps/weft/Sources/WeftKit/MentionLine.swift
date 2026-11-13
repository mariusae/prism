import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The pages that link to a note, at its foot: one line of quiet text —
/// "Linked from Ada, Cosmo, and 7 more". Each name goes to where that page
/// speaks of the note; "Linked from" to a river of them all; "7 more" to
/// the rest, listed.
struct MentionLine: View {
    let titles: [String]
    var open: (Int) -> Void
    var openAll: () -> Void
    @State private var width: CGFloat = 320

    private static let size: CGFloat = {
        #if os(macOS)
        12
        #else
        13
        #endif
    }()

    private static func measure(_ words: String) -> CGFloat {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: size)
        #else
        let font = UIFont.systemFont(ofSize: size)
        #endif
        return ceil((words as NSString).size(withAttributes: [.font: font]).width)
    }

    /// How many names fit the line whole, with room left for "and N more".
    private func fitting() -> Int {
        var used = Self.measure("Linked from ") + 14
        for (index, title) in titles.enumerated() {
            let left = titles.count - index - 1
            let next = used + Self.measure(title + (left > 0 ? ", " : ""))
            let more = left > 0 ? Self.measure(" and \(left) more") : 0
            if next + more > width { return max(index, 1) }
            used = next
        }
        return titles.count
    }

    var body: some View {
        let shown = min(fitting(), titles.count)
        HStack(spacing: 0) {
            Button { openAll() } label: { Text("Linked from ").foregroundStyle(Color.inkFaint) }
                .buttonStyle(.plain)
                .help("Every Mention, as a River")
            ForEach(Array(titles.prefix(shown).enumerated()), id: \.offset) { index, title in
                Button { open(index) } label: { Text(title).foregroundStyle(Color.inkSecondary).lineLimit(1) }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .pointerStyle(.link)
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
        .font(.system(size: Self.size))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
    }
}
