import Prism
import PrismEditor
import PrismEmblem
import SwiftUI

/// One card of a river: a page, written in where it stands.
///
/// What is done to a card most — fold it, check it off, pin it, close
/// it — is one click away on the card itself: its title folds it, and a
/// strip of actions stands at the end of its first line while the pointer
/// is over it or it is the card chosen. Everything else is in its menu.
struct CardView: View {
    let store: GraphStore
    let river: River
    let card: Card
    @State private var draft: PageDraft
    @State private var bodyHeight: CGFloat = 24
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var choosesLook = false
    @State private var newTitle = ""
    @State private var backlinks: [Source] = []
    @State private var tags: [String] = []
    @FocusState private var titleFocused: Bool

    init(store: GraphStore, river: River, card: Card) {
        self.store = store
        self.river = river
        self.card = card
        _draft = State(initialValue: store.draft(path: card.path, title: card.title))
    }

    private var emblem: Emblem { Emblem(title: draft.title, icon: draft.icon, color: draft.color, kindSymbol: isDay ? "calendar" : nil) }
    private var isSelected: Bool { river.selected == card.id }
    private var isWriting: Bool { river.writing == card.id }
    private var isDay: Bool { card.path.hasPrefix("daily/") || card.path.hasPrefix("weekly/") }
    private var showsActions: Bool { isHovered || isSelected }
    private var titleFont: Font { .system(size: TextSettings.titleSize, weight: .semibold, design: TextSettings.design) }

    var body: some View {
        VStack(alignment: .leading, spacing: card.folded ? 0 : Measures.partGap) {
            if card.folded {
                peek
            } else {
                header
                if draft.isConflicted { conflict }
                editor
                if !tags.isEmpty || !backlinks.isEmpty { foot }
            }
        }
        .padding(.trailing, Measures.cardTrailing)
        .padding(.top, card.folded ? 11 : 9)
        .padding(.bottom, card.folded ? 11 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Measures.cardRadius, style: .continuous).fill(card.folded ? Color.inkPaper : Color.inkCard))
        .overlay(
            RoundedRectangle(cornerRadius: Measures.cardRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.inkAccent.opacity(0.85) : Color.inkRule, lineWidth: isSelected ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(card.folded ? 0.03 : 0.07), radius: card.folded ? 4 : 10, y: card.folded ? 1 : 3)
        .contentShape(Rectangle())
        .onTapGesture { river.selected = card.id }
        .onHover { isHovered = $0 }
        .contextMenu { menu }
        .task(id: store.indexRevision) { refresh() }
    }

    private struct Source: Hashable {
        var path: String
        var title: String
        var emblem: Emblem
    }

    private func refresh() {
        var seen = Set<String>()
        backlinks = ((try? store.engine.backlinks(path: card.path)) ?? []).compactMap { link in
            guard link.source != card.path, seen.insert(link.source).inserted else { return nil }
            let page = (try? store.engine.page(path: link.source)) ?? nil
            let isRiver = link.source.hasPrefix("rivers/")
            let title = page?.title ?? String(link.source.split(separator: "/").last ?? "").replacingOccurrences(of: ".md", with: "")
            return Source(path: link.source, title: title, emblem: store.emblem(path: link.source, title: title))
        }
        tags = (try? store.engine.tagsOf(path: card.path)) ?? []
    }

    // MARK: Parts

    /// A row of the card: the mark in the gutter, then what it stands before.
    private func row<Mark: View, Content: View>(alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder mark: () -> Mark, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: alignment, spacing: 0) {
            mark().frame(width: Measures.margin + Measures.gutter, alignment: .trailing)
            content()
        }
    }

    /// The card's mark: a to-do's ring, which checks it off; else its icon, which opens its menu.
    @ViewBuilder private var mark: some View {
        switch draft.task {
        case .none:
            // Its emblem — its icon, or a letter of its title, in its
            // colour — which, clicked, is where those are chosen.
            Button { choosesLook = true } label: {
                EmblemView(emblem, size: 22, style: isDay && draft.icon == nil && draft.color == nil ? .plain : .tile, quiet: Color.inkSecondary)
                    .opacity(draft.color != nil || isHovered ? 1 : 0.8)
                    .frame(width: Measures.gutter + 4, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!draft.exists)
            .popover(isPresented: $choosesLook, arrowEdge: .bottom) {
                EmblemPicker(
                    title: draft.title,
                    icon: Binding(get: { draft.icon }, set: { draft.setLook(icon: $0, color: draft.color) }),
                    color: Binding(get: { draft.color }, set: { draft.setLook(icon: draft.icon, color: $0) }),
                    kindSymbol: isDay ? "calendar" : nil
                )
            }
            .help("Choose an icon and a colour")
        case .todo, .done:
            Button { withAnimation(.snappy(duration: 0.2)) { draft.setTask(draft.task == .done ? .todo : .done) } } label: {
                Image(systemName: draft.task == .done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: (TextSettings.size * 1.3).rounded()))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(draft.task == .done ? AnyShapeStyle(.white) : AnyShapeStyle(Color.inkSecondary), Color.inkAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: Measures.gutter + 4, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(draft.task == .done ? "Mark Not Done" : "Mark Done")
        }
    }

    private var header: some View {
        row(mark: { mark }) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if isRenaming {
                    TextField("Title", text: $newTitle)
                        .textFieldStyle(.plain)
                        .font(titleFont)
                        .focused($titleFocused)
                        .onSubmit { finishRenaming() }
                        .onExitCommand { isRenaming = false }
                        .onChange(of: titleFocused) { _, focused in if !focused { finishRenaming() } }
                } else {
                    Text(emblem.caption(draft.title))
                        .font(titleFont)
                        .italic(!draft.exists)
                        .strikethrough(draft.task == .done, color: Color.inkSecondary)
                        .foregroundStyle(draft.task == .done ? Color.inkSecondary : Color.inkText)
                        .lineLimit(1)
                        .onTapGesture(count: 2) { if !isDay { startRenaming() } }
                        .onTapGesture { fold() }
                        .help("Click to fold, double-click to rename")
                    if draft.isMarked("pinned") {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.inkAccent)
                    }
                }
                Spacer(minLength: 8)
                actions
            }
            .frame(minHeight: 30)
        }
    }

    /// The strip of what is done to a card most.
    private var actions: some View {
        HStack(spacing: 1) {
            if isDay {
                CardButton("chevron.left", help: "The Day Before") { step(-1) }
                CardButton("chevron.right", help: "The Day After") { step(1) }
            }
            if !card.folded {
                CardButton(draft.mode == .outline ? "text.alignleft" : "list.bullet.indent", help: draft.mode == .outline ? "Write as Text" : "Write as an Outline") {
                    draft.setMode(draft.mode == .outline ? .text : .outline)
                }
            }
            if draft.exists, !isDay {
                CardButton(draft.isMarked("pinned") ? "pin.fill" : "pin", help: draft.isMarked("pinned") ? "Unpin" : "Pin", isOn: draft.isMarked("pinned")) { draft.toggleMark("pinned") }
                CardButton(draft.isMarked("inbox") ? "tray.fill" : "tray.and.arrow.down", help: draft.isMarked("inbox") ? "Done with It" : "Add to Inbox", isOn: draft.isMarked("inbox")) {
                    draft.toggleMark("inbox")
                }
            }
            Menu { menu } label: { CardButtonFace(symbol: "ellipsis") }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            CardButton("xmark", help: "Close (⌘W)") { withAnimation(.snappy(duration: 0.28)) { close() } }
        }
        .opacity(showsActions ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: showsActions)
        .allowsHitTesting(showsActions)
    }

    private var editor: some View {
        row(mark: { Color.clear.frame(height: 1) }) {
            ZStack(alignment: .topLeading) {
                if draft.isBlank, !isWriting {
                    Text(isDay ? "Nothing written on this day yet." : (draft.exists ? "Write here." : "No page has this title yet. Write here to make it."))
                        .font(.system(size: TextSettings.size, design: TextSettings.design))
                        .foregroundStyle(Color.inkFaint)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
                // The editor is the engine's note, shown: the same component
                // in every app, as an outline or as text.
                NoteEditorView(
                    editor: draft.editor, theme: Ink.editorTheme, isWriting: isWriting, height: $bodyHeight,
                    refresh: store.indexRevision,
                    pageExists: { name in store.resolve(name)?.exists ?? false },
                    blockView: { block in
                        guard block.info == "query" else { return nil }
                        return AnyView(QueryView(store: store, source: block.source, this: draft.title) { page in
                            withAnimation(.snappy(duration: 0.28)) { store.open(page: page, after: card.id) }
                        })
                    },
                    onChange: { draft.changed() },
                    onFocus: { focused in
                        if focused {
                            river.selected = card.id
                            river.writing = card.id
                        } else if river.writing == card.id {
                            river.writing = nil
                            draft.saveNow()
                        }
                    },
                    onFollow: { follow($0) }
                )
                .frame(height: bodyHeight)
                .id(draft.mode)
            }
        }
    }

    /// What the page is tagged, and who links to it: a line of pills.
    private var foot: some View {
        row(mark: { Color.clear.frame(height: 1) }) {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    FootPill(title: tag, emblem: Emblem(symbol: "number"), tint: Color.inkAccent) { store.open(name: tag, after: card.id, in: river) }
                }
                if !backlinks.isEmpty {
                    Text(tags.isEmpty ? "Linked from" : "· linked from").font(.caption).foregroundStyle(Color.inkSecondary).padding(.vertical, 3)
                    ForEach(backlinks.prefix(6), id: \.self) { source in
                        FootPill(title: source.title, emblem: source.emblem, tint: Color.inkSecondary) {
                            withAnimation(.snappy(duration: 0.28)) { store.river.open(Card(path: source.path, title: source.title), after: card.id) }
                        }
                    }
                    if backlinks.count > 6 {
                        Menu("and \(backlinks.count - 6) more") {
                            ForEach(backlinks.dropFirst(6), id: \.self) { source in
                                Button(source.title) { store.river.open(Card(path: source.path, title: source.title), after: card.id) }
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                        .fixedSize()
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var conflict: some View {
        row(mark: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }) {
            HStack(spacing: 8) {
                Text("Two devices changed the same lines.").font(.callout).foregroundStyle(Color.inkSecondary)
                Button("Keep This Device's") { draft.resolve(keeping: .ours) }
                Button("Keep the Other's") { draft.resolve(keeping: .theirs) }
                Button("Keep Both") { draft.resolve(keeping: .both) }
            }
            .controlSize(.small)
        }
    }

    private var peek: some View {
        row(mark: { mark }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (Text(emblem.caption(draft.title)).bold().foregroundStyle(draft.task == .done ? Color.inkSecondary : Color.inkText).strikethrough(draft.task == .done)
                    + Text("  ") + Text(draft.summary).foregroundStyle(Color.inkSecondary))
                    .font(.system(size: TextSettings.size, design: TextSettings.design))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { fold() }
                actions
            }
        }
    }

    // MARK: What can be done

    @ViewBuilder private var menu: some View {
        Button(card.folded ? "Unfold" : "Fold", systemImage: card.folded ? "chevron.down" : "chevron.right") { fold() }
        if draft.exists, !isDay {
            switch draft.task {
            case .none: Button("Make a To-Do", systemImage: "circle") { draft.setTask(.todo) }
            case .todo: Button("Mark Done", systemImage: "checkmark.circle") { draft.setTask(.done) }
            case .done: Button("Mark Not Done", systemImage: "circle") { draft.setTask(.todo) }
            }
            if draft.task != .none { Button("No Longer a To-Do", systemImage: "circle.slash") { draft.setTask(.none) } }
            Button(draft.isMarked("pinned") ? "Unpin" : "Pin", systemImage: draft.isMarked("pinned") ? "pin.slash" : "pin") { draft.toggleMark("pinned") }
            Button(draft.isMarked("inbox") ? "Done with It" : "Add to Inbox", systemImage: draft.isMarked("inbox") ? "tray.and.arrow.up" : "tray.and.arrow.down") { draft.toggleMark("inbox") }
            Button(draft.isMarked("wiki") ? "Remove from Wiki" : "Add to Wiki", systemImage: "book.closed") { draft.toggleMark("wiki") }
        }
        Divider()
        if !isDay { Button("Rename…", systemImage: "character.cursor.ibeam") { startRenaming() } }
        if draft.exists { Button("Icon and Colour…", systemImage: "paintpalette") { choosesLook = true } }
        Picker("Write As", selection: Binding(get: { draft.mode }, set: { draft.setMode($0) })) {
            Label("Outline", systemImage: "list.bullet.indent").tag(EditorMode.outline)
            Label("Text", systemImage: "text.alignleft").tag(EditorMode.text)
        }
        Button("Copy Link", systemImage: "link") { copy("[[\(draft.title)]]") }
        Button("Copy Contents", systemImage: "doc.on.doc") { copy(draft.markdown) }
        #if os(macOS)
        Button("Show in Finder", systemImage: "folder") {
            if let file = try? store.engine.absolutePath(path: card.path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
        }
        #endif
        Divider()
        Button("Close Others", systemImage: "rectangle.stack.badge.minus") {
            store.saveAll()
            withAnimation(.snappy(duration: 0.28)) { river.cards.removeAll { $0.id != card.id } }
            store.rememberRivers()
        }
        Button("Close", systemImage: "xmark") { close() }
        if draft.exists {
            Button("Delete Page", systemImage: "trash", role: .destructive) {
                draft.delete()
                close()
            }
        }
    }

    private func fold() {
        river.selected = card.id
        withAnimation(.snappy(duration: 0.22)) { river.toggleFold(card.id) }
        store.rememberRivers()
    }

    private func close() {
        draft.saveNow()
        river.close(card.id)
        store.rememberRivers()
    }

    /// The day before or after a day's card, opened just after it.
    private func step(_ days: Int) {
        let name = card.path.replacingOccurrences(of: "daily/", with: "").replacingOccurrences(of: ".md", with: "")
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        guard let day = format.date(from: name), let next = format.calendar.date(byAdding: .day, value: days, to: day) else { return }
        withAnimation(.snappy(duration: 0.28)) { store.open(name: format.string(from: next), after: card.id, in: river) }
    }

    private func startRenaming() {
        if card.folded { river.toggleFold(card.id) }
        newTitle = draft.title
        isRenaming = true
        titleFocused = true
    }

    private func finishRenaming() {
        guard isRenaming else { return }
        isRenaming = false
        draft.rename(to: newTitle)
        if let index = river.cards.firstIndex(where: { $0.id == card.id }) { river.cards[index].title = draft.title }
        store.rememberRivers()
    }

    private func follow(_ target: EditorLink) {
        switch target {
        case .page(let name), .tag(let name):
            withAnimation(.snappy(duration: 0.28)) { store.open(name: name, after: card.id, in: river) }
        case .web(let address):
            guard let url = URL(string: address) else { return }
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// One of a card's actions: a symbol that lights under the pointer.
struct CardButton: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void

    init(_ symbol: String, help: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) { CardButtonFace(symbol: symbol, isOn: isOn) }
            .buttonStyle(.plain)
            .help(help)
    }
}

struct CardButtonFace: View {
    let symbol: String
    var isOn = false
    @State private var isHovered = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isOn ? Color.inkAccent : Color.inkSecondary)
            .frame(width: 26, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.inkText.opacity(isHovered ? 0.08 : 0)))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

/// A small pill at a card's foot: a tag, or a page that links here.
struct FootPill: View {
    let title: String
    let emblem: Emblem
    let tint: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                EmblemView(emblem, size: 12, style: .plain, quiet: tint)
                Text(emblem.caption(title)).font(.system(size: 12)).lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(isHovered ? 0.18 : 0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
