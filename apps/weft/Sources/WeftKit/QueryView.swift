import Prism
import PrismEmblem
import SwiftUI

/// What a query block finds, drawn where the block is written.
struct QueryView: View {
    let store: GraphStore
    let source: String
    /// The page the query is in: what `{this}` stands for.
    let this: String
    var open: (PageInfo) -> Void

    private var found: QueryOutcome? {
        _ = store.indexRevision
        return try? store.engine.runQuery(body: source, this: this)
    }

    private var summary: String {
        source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        let found = found
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(summary).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(found?.total ?? 0)").monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.inkSecondary)
            if let found, !found.pages.isEmpty {
                if found.show == .count {
                    EmptyView()
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(found.pages, id: \.path) { page in
                            Button { open(page) } label: {
                                HStack(spacing: 4) {
                                    if store.emblem(page).isShown { EmblemView(store.emblem(page), size: TextSettings.size * 0.95, style: .plain, quiet: Color.inkAccent) }
                                    Text(store.emblem(page).caption(page.label)).font(.system(size: TextSettings.size, design: TextSettings.design)).lineLimit(1)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(Color.inkAccent)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.inkAccent.opacity(0.12)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .pointerStyle(.link)
                        }
                    }
                    if Int(found.total) > found.pages.count {
                        Text("and \(Int(found.total) - found.pages.count) more").font(.caption).foregroundStyle(Color.inkFaint)
                    }
                }
            } else {
                Text("Nothing found").font(.callout).foregroundStyle(Color.inkFaint)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.inkAccent.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.inkAccent.opacity(0.15)))
    }
}
