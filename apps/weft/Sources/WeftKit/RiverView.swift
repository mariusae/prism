import Prism
import PrismEmblem
import SwiftUI

/// The river: the open cards, one after another.
struct RiverView: View {
    let store: GraphStore
    let river: River
    var onQuickOpen: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if river.cards.isEmpty {
                    StartPage(store: store, onQuickOpen: onQuickOpen)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(river.cards) { card in
                            CardView(store: store, river: river, card: card)
                                .padding(.bottom, card.folded ? Measures.foldedGap : Measures.cardGap)
                                .id(card.id)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, Measures.riverSides)
                    .padding(.vertical, Measures.riverEnds)
                    .frame(maxWidth: Measures.cardMaxWidth + 2 * Measures.riverSides)
                    .frame(maxWidth: .infinity)
                    .animation(.snappy(duration: 0.28), value: river.cards.map(\.id))
                }
            }
            .background(Color.inkPage)
            .onChange(of: river.scrollTarget?.tick) { _, _ in
                guard let target = river.scrollTarget?.card else { return }
                DispatchQueue.main.async {
                    withAnimation(.snappy(duration: 0.24)) { proxy.scrollTo(target, anchor: .top) }
                }
            }
        }
    }
}

/// What an empty river shows: where to go from here.
struct StartPage: View {
    let store: GraphStore
    var onQuickOpen: () -> Void
    @State private var recent: [PageInfo] = []
    @State private var pinned: [PageInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button(action: onQuickOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.inkSecondary)
                    Text("Go to a page or a day").foregroundStyle(Color.inkFaint)
                    Spacer()
                    Text("⌘O").font(.system(size: 11.5)).foregroundStyle(Color.inkFaint)
                }
                .font(.system(size: 17))
                .padding(.horizontal, 18)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.inkPaper))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.inkRule))
            }
            .buttonStyle(.plain)
            if !pinned.isEmpty { list("Pinned", pinned) }
            if !recent.isEmpty { list("Recent", recent) }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .task(id: store.indexRevision) {
            recent = (try? store.engine.runQuery(body: "sort: -modified\nlimit: 10", this: nil).pages) ?? []
            pinned = (try? store.engine.runQuery(body: "is: pinned\nsort: pinned\nlimit: 8", this: nil).pages) ?? []
        }
    }

    private func list(_ title: String, _ pages: [PageInfo]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Color.inkSecondary).padding(.leading, 10).padding(.bottom, 4)
            ForEach(pages, id: \.path) { page in
                PageRow(store: store, page: page) { withAnimation(.snappy(duration: 0.28)) { store.open(page: page) } }
            }
        }
    }
}

/// A page in a list: its symbol, its title, when it was written.
struct PageRow: View {
    let store: GraphStore
    let page: PageInfo
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                EmblemView(store.emblem(page), size: 20, quiet: Color.inkSecondary)
                Text(store.emblem(page).caption(page.title)).font(.system(size: 14.5)).foregroundStyle(Color.inkText).lineLimit(1)
                Spacer(minLength: 12)
                if let modified = page.modified {
                    Text(Date(timeIntervalSince1970: TimeInterval(modified)), format: .relative(presentation: .named)).font(.system(size: 12)).foregroundStyle(Color.inkFaint)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovered ? Color.inkHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
