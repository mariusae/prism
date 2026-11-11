import Foundation
import Prism
import SwiftUI

/// A day's name, as the graph writes it: 2026-11-10.
enum Days {
    static func name(_ date: Date) -> String {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }

    /// Whether the app is being run without a screen, to be pictured or measured.
    static var isHeadless: Bool {
        ProcessInfo.processInfo.environment["WEFT_SNAPSHOT"] != nil || ProcessInfo.processInfo.environment["WEFT_BENCH"] != nil
    }
}

/// Lays its children out in rows, wrapping.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var (x, y, rowHeight, widest): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, widest, y + rowHeight)
    }
}

/// Choosing the note that rows taken out of an outline go to: found as it
/// is typed, or one of those written last.
struct MoveRowsSheet: View {
    let store: GraphStore
    let moving: GraphStore.MovingRows
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var pages: [PageInfo] = []
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Move to…").font(.headline)
                Spacer()
                Button("Cancel") {
                    store.movingRows = nil
                    dismiss()
                }
            }
            .padding([.horizontal, .top], 16)
            TextField("Find a note", text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .padding(16)
            List(pages, id: \.path) { page in
                Button {
                    store.finishMove(to: page.path)
                    dismiss()
                } label: {
                    HStack {
                        Text(GraphStore.shown(page)).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        #if os(macOS)
        .frame(width: 420, height: 460)
        #endif
        .task(id: typed) {
            let asked = typed.trimmingCharacters(in: .whitespaces)
            let found = asked.isEmpty ? ((try? store.engine.runQuery(body: "sort: -modified\nlimit: 30", this: nil).pages) ?? []) : ((try? store.engine.complete(typed: asked, limit: 20)) ?? [])
            pages = found.filter { $0.path != moving.from }
        }
        .onAppear { typing = true }
    }
}

/// How a card goes when it is closed: a puff, and it is gone.
private struct Poof: ViewModifier {
    var gone: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(gone ? 1.06 : 1)
            .blur(radius: gone ? 18 : 0)
            .opacity(gone ? 0 : 1)
    }
}

extension AnyTransition {
    /// In quietly; out in a puff.
    static var poof: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .modifier(active: Poof(gone: true), identity: Poof(gone: false)))
    }
}

/// Says whether a sync is under way — and for a moment after it is
/// done, so that a quick one is still seen to have happened.
struct Syncing<Content: View>: View {
    let store: GraphStore
    @ViewBuilder var content: (Bool) -> Content
    @State private var shown = false
    @State private var began = Date.distantPast
    /// The least time it is shown for.
    private let least = 0.9

    var body: some View {
        content(shown)
            .onChange(of: store.isSyncing, initial: true) { _, syncing in
                if syncing {
                    shown = true
                    began = Date()
                } else if shown {
                    let left = max(0, least - Date().timeIntervalSince(began))
                    Task {
                        try? await Task.sleep(for: .seconds(left))
                        if !store.isSyncing { shown = false }
                    }
                }
            }
    }
}

/// Gives a note a tag: one typed, or one of those the graph already
/// has. The tag is written in the note's frontmatter.
struct TagAdder: View {
    let store: GraphStore
    let draft: PageDraft
    var done: () -> Void
    @State private var typed = ""
    @State private var all: [TagCount] = []
    @FocusState private var isTyping: Bool

    /// The graph's tags the note has not got, that what is typed is in: most used first.
    private var offers: [TagCount] {
        let has = Set(draft.frontTags.map { nameKey(name: $0) })
        let key = nameKey(name: typed.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
        return Array(all.filter { !has.contains(nameKey(name: $0.tag)) && (key.isEmpty || nameKey(name: $0.tag).contains(key)) }.prefix(14))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "number").foregroundStyle(Color.inkSecondary)
                field
                Button("Add") { add(typed) }
                    .disabled(typed.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            if !offers.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(offers, id: \.tag) { offer in
                        Button { add(offer.tag) } label: {
                            Text(offer.tag).font(.callout).lineLimit(1)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .foregroundStyle(Color.inkAccent)
                                .background(Capsule().fill(Color.inkAccent.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .foregroundStyle(Color.inkText)
        .onAppear {
            all = (try? store.engine.tags()) ?? []
            isTyping = true
        }
    }

    @ViewBuilder private var field: some View {
        #if os(iOS)
        TextField("Tag", text: $typed).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
            .focused($isTyping).onSubmit { add(typed) }
        #else
        TextField("Tag", text: $typed).textFieldStyle(.plain).focused($isTyping).onSubmit { add(typed) }
        #endif
    }

    private func add(_ tag: String) {
        guard draft.addTag(tag) else { return done() }
        done()
    }
}

