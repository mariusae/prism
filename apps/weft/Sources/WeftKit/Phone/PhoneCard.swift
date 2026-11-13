#if os(iOS)
import Prism
import PrismEditor
import PrismEmblem
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct CarriedCardKey: EnvironmentKey { static let defaultValue: Binding<Card.ID?> = .constant(nil) }
extension EnvironmentValues {
    var carriedCard: Binding<Card.ID?> {
        get { self[CarriedCardKey.self] }
        set { self[CarriedCardKey.self] = newValue }
    }
}

/// One card of a river on the phone: a note, written in where it stands.
///
/// What is done to a card most is a swipe: right, to make it a to-do or
/// send it to the inbox; left, to close or delete it. Its title folds it;
/// held, it gives its menu, or is picked up to be moved. The card being
/// written in, or tapped last, has a strip of controls under it.
struct PhoneCard: View {
    let store: GraphStore
    let river: River
    let card: Card
    @State private var draft: PageDraft
    @State private var bodyHeight: CGFloat = 24
    @State private var isRenaming = false
    @State private var newTitle = ""
    @State private var choosesLook = false
    @State private var addsTag = false
    /// The link on the web whose card is shown.
    @State private var linkShown: PhoneLink?
    @State private var backlinks: [Source] = []
    @State private var tags: [String] = []
    @FocusState private var titleFocused: Bool
    @Environment(\.carriedCard) private var carried

    init(store: GraphStore, river: River, card: Card) {
        self.store = store
        self.river = river
        self.card = card
        _draft = State(initialValue: store.draft(path: card.path, title: card.title))
        // As it was when last seen: its height, and what stood at its foot.
        _bodyHeight = State(initialValue: store.cardHeights[card.spot] ?? 24)
        if let foot = store.cardFeet[Self.footKey(card, in: river)] as? Foot {
            _backlinks = State(initialValue: foot.backlinks)
            _tags = State(initialValue: foot.tags)
        }
    }

    private struct Foot {
        var backlinks: [Source]
        var tags: [String]
    }

    private static func footKey(_ card: Card, in river: River) -> String { "\(river.id)|\(card.path)" }

    private struct Source: Hashable {
        var path: String
        var name: String
        var title: String
        var emblem: Emblem
    }

    private var isSelected: Bool { river.selected == card.id }
    private var isWriting: Bool { river.writing == card.id }
    private var isDay: Bool { card.path.hasPrefix("daily/") || card.path.hasPrefix("weekly/") }
    private var isUntitled: Bool { !isDay && draft.isUntitled }
    private var showsHeader: Bool { card.viewKey != nil || !isUntitled || isRenaming }

    // MARK: A row, shown as a note of its own

    /// The note as this card writes in it, when it shows only one row of it.
    private var focused: NoteEditor? { draft.view(of: card) }

    /// Where the words the card was opened by are, in what it shows: marked.
    private func marks(in shown: NoteEditor, isFocus: Bool) -> [NSRange] {
        guard isFocus, case .words(let words) = card.lens else { return [] }
        return Marks.find(words, in: shown.text())
    }

    /// The way to the row shown, from the note's top: the note, then
    /// each row it is under. Each, tapped, is shown in its place.
    private func trail(_ view: NoteEditor) -> some View {
        let over = view.focusTrail()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Button { widen(view, to: 0, of: over.count) } label: {
                    HStack(spacing: 3) {
                        if emblem.isShown { EmblemView(emblem, size: 12, style: .plain, quiet: Color.inkSecondary) }
                        Text(emblem.caption(draft.label)).lineLimit(1)
                    }
                }
                ForEach(Array(over.enumerated()), id: \.offset) { index, crumb in
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.inkFaint)
                    Button(crumb.isEmpty ? "…" : Days.shown(crumb)) { widen(view, to: index + 1, of: over.count) }.lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, design: TextSettings.design))
            .foregroundStyle(Color.inkSecondary)
            .padding(.vertical, 4)
        }
    }

    private func focusLabel(_ view: NoteEditor) -> String {
        let _ = draft.revision
        // A row that is a link — a day's, say — is titled as the link reads.
        let label = store.titled(view.focusLabel() ?? "", written: view.focusTitle() ?? "")
        return label.isEmpty ? "Untitled" : label
    }

    private func focusHeader(_ view: NoteEditor) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            trail(view)
            if isRenaming {
                TextField("Row", text: $newTitle)
                    .font(titleFont)
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { finishRenaming() }
                    .onChange(of: titleFocused) { _, focused in if !focused { finishRenaming() } }
            } else {
                Text(focusLabel(view))
                    .font(titleFont)
                    .foregroundStyle(Color.inkText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startRenaming() }
                    .onTapGesture { fold() }
            }
        }
    }

    private func focusPeek(_ view: NoteEditor) -> some View {
        Text("\(Text(focusLabel(view)).bold().foregroundStyle(Color.inkText))  \(Text(([draft.label] + view.focusTrail().map(Days.shown)).joined(separator: " › ")).foregroundStyle(Color.inkSecondary))")
            .font(.system(size: TextSettings.size, design: TextSettings.design))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { fold() }
    }

    private func focusDrawer(_ view: NoteEditor) -> some View {
        HStack(spacing: 0) {
            drawerButton("arrow.down.right.and.arrow.up.left.circle", "Fold") { fold() }
            drawerButton("arrow.up.left.circle", "Show the Row Above") { widen(view) }
            drawerButton("arrow.up.left.and.arrow.down.right.circle", "Show the Whole Note") { widen(view, to: 0, of: 0) }
            drawerButton("xmark.circle", "Close") { withAnimation(.snappy(duration: 0.28)) { store.close(card.id, in: river) } }
        }
        .foregroundStyle(Color.inkAccent)
        .padding(.horizontal, 6)
        .frame(height: 46)
        .glassEffect(.regular.tint(Color.inkAccent.opacity(0.12)).interactive(), in: .capsule)
        // Glass comes and goes as glass does: it melts away with its card's choosing, and is not left behind.
        .glassEffectTransition(.materialize)
        .padding(.top, 12)
        .padding(.horizontal, 24)
    }

    /// Shows more than the row shown: the row at a place on the way to
    /// it — `0` the whole note, `count` the row right over it.
    private func widen(_ view: NoteEditor, to place: Int, of count: Int) {
        var name: String?
        if place > 0 {
            name = view.focusOut(levels: UInt32(count - place + 1))
            // The row over it may have been named just now: that is the note's to keep.
            draft.changed(from: card.id)
        }
        withAnimation(.snappy(duration: 0.22)) { river.setFocus(card.id, name) }
        store.rememberRivers()
    }

    /// One row out; from the outermost, the whole note.
    private func widen(_ view: NoteEditor) {
        let count = view.focusTrail().count
        widen(view, to: count, of: count)
    }

    /// Shows a row of what is shown as a note of its own: here, or in a card after this one.
    private func zoom(_ name: String, apart: Bool) {
        withAnimation(.snappy(duration: 0.24)) {
            if apart { river.openFocus(name, of: card.id) } else { river.setFocus(card.id, name) }
        }
        store.rememberRivers()
    }
    private var showsDrawer: Bool { isSelected && !card.folded }
    /// Its icon — or, holding a checklist and given none, how far along that is.
    private var emblem: Emblem {
        Emblem(title: draft.title, icon: draft.icon, color: draft.color, kindSymbol: isDay ? "calendar" : nil, letter: false, progress: draft.task == .none ? draft.checklist : nil)
    }
    private var titleFont: Font { .system(size: TextSettings.titleSize, weight: .semibold, design: TextSettings.design) }
    /// Whether the note has anything to read: a link note's address, a link, a PDF.
    private var canRead: Bool { draft.exists && ReaderSource.any(in: draft.markdown, root: store.root) }

    var body: some View {
        let _ = bodyHeight
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: card.folded ? 0 : Measures.partGap) {
                if let focused {
                    // One row of the note, as a note of its own: the way to it, its words, and what is under it.
                    if card.folded {
                        focusPeek(focused)
                    } else {
                        focusHeader(focused)
                        editor(focused, isFocus: true)
                    }
                } else if card.folded {
                    peek
                } else {
                    if showsHeader { header }
                    if draft.isConflicted { conflict }
                    editor(draft.editor, isFocus: false)
                    if !tags.isEmpty || !draft.related.isEmpty { foot }
                    if !backlinks.isEmpty { mentions }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, card.folded ? 12 : 16)
            .padding(.bottom, card.folded ? 12 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Measures.cardRadius, style: .continuous).fill(card.folded ? Color.inkPaper : Color.inkCard))
                        .overlay(
                RoundedRectangle(cornerRadius: Measures.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.inkAccent.opacity(0.5) : Color.inkRule, lineWidth: 1)
            )
            .shadow(color: .black.opacity(card.folded ? 0.03 : 0.07), radius: card.folded ? 4 : 10, y: card.folded ? 1 : 3)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { river.selected = card.id })
            .modifier(CardSwipe(leading: leadingActions, trailing: trailingActions, enabled: !isWriting && !isRenaming))
            if showsDrawer, let focused {
                focusDrawer(focused).transition(.scale(scale: 0.5, anchor: .top).combined(with: .opacity))
            } else if showsDrawer {
                drawer.transition(.scale(scale: 0.5, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: showsDrawer)
        .task(id: store.indexRevision) { refresh() }
        .onChange(of: bodyHeight) { _, height in store.cardHeights[card.spot] = height }
        // The row it showed is in the note no more: it shows the note.
        .task(id: "\(card.viewKey ?? "")|\(draft.revision)") {
            // The part it showed is in the note no more: it shows the note.
            if card.viewKey != nil, draft.view(of: card) == nil {
                river.setFocus(card.id, nil)
                store.rememberRivers()
            }
        }
        .fullScreenCover(item: $linkShown) { link in
            BottomCard { PhoneLinkSheet(link: link, draft: draft) }
        }
        .fullScreenCover(isPresented: $addsTag) {
            BottomCard { TagAdder(store: store, draft: draft) { addsTag = false; refresh() } }
        }
        .sheet(isPresented: $choosesLook) {
            EmblemPicker(
                title: draft.label,
                icon: Binding(get: { draft.icon }, set: { draft.setLook(icon: $0, color: draft.color) }),
                color: Binding(get: { draft.color }, set: { draft.setLook(icon: draft.icon, color: $0) }),
                kindSymbol: isDay ? "calendar" : nil
            )
            .presentationDetents([.medium])
        }
    }

    private func refresh() {
        var seen = Set<String>()
        backlinks = ((try? store.engine.backlinks(path: card.path)) ?? []).compactMap { link in
            guard link.source != card.path, seen.insert(link.source).inserted else { return nil }
            if let here = river.name, GraphStore.riverName(link.source) == here { return nil }
            let page = (try? store.engine.page(path: link.source)) ?? nil
            let name = page?.title ?? String(link.source.split(separator: "/").last ?? "").replacingOccurrences(of: ".md", with: "")
            return Source(path: link.source, name: name, title: page?.label ?? name, emblem: store.emblem(path: link.source, title: name))
        }
        tags = (try? store.engine.tagsOf(path: card.path)) ?? []
        store.cardFeet[Self.footKey(card, in: river)] = Foot(backlinks: backlinks, tags: tags)
    }

    // MARK: Parts

    /// What stands before the title, as its first character would: a to-do's ring, or the note's icon.
    @ViewBuilder private func lead(size: CGFloat) -> some View {
        switch draft.task {
        case .none:
            if emblem.isShown {
                EmblemView(emblem, size: size, style: .plain, quiet: Color.inkSecondary)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - size * 0.2 }
            }
        case .todo, .done:
            Button { withAnimation(.snappy(duration: 0.2)) { draft.setTask(draft.task == .done ? .todo : .done) } } label: {
                Image(systemName: draft.task == .done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: size * 0.95))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(draft.task == .done ? AnyShapeStyle(.white) : AnyShapeStyle(Color.inkSecondary), Color.inkAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: size * 1.4, height: size * 1.3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: draft.task == .done)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isRenaming {
                TextField(draft.editor.firstLine() ?? "Title", text: $newTitle)
                    .font(titleFont)
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { finishRenaming() }
                    .onChange(of: titleFocused) { _, focused in if !focused { finishRenaming() } }
            } else if let address = linkAddress, LinkNoteHeader.isAvailable(address, cover: linkCover) {
                // A link note: headed by the card of the page it keeps.
                LinkNoteHeader(address: address, title: draft.title, cover: linkCover, titleFont: titleFont)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startRenaming() }
                    .onTapGesture { fold() }
                    .contextMenu { holdMenu }
                    .onDrag { carry() } preview: { carriedLabel }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: TextSettings.titleSize * 0.3) {
                    lead(size: TextSettings.titleSize)
                    Text(emblem.caption(isDay ? draft.label : draft.title))
                        .font(titleFont)
                        .italic(!draft.exists)
                        .strikethrough(draft.task == .done, color: Color.inkSecondary)
                        .foregroundStyle(draft.task == .done ? Color.inkSecondary : Color.inkText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if !isDay { startRenaming() } }
                .onTapGesture { fold() }
                .contextMenu { holdMenu }
                .onDrag { carry() } preview: { carriedLabel }
                if draft.isMarked("pinned") { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.inkAccent) }
            }
        }
        .task(id: linkAddress) { if let linkAddress { WebCards.shared.look(linkAddress) } }
    }

    /// The page a link note keeps: its `URL:` row's address; nil for any other note.
    private var linkAddress: String? {
        _ = draft.revision
        return isDay ? nil : ReaderSource.ownAddress(in: draft.markdown)
    }

    /// The note's own picture for its page, `cover:`.
    private var linkCover: PlatformImage? {
        draft.editor.field(key: "cover").flatMap { Pictures.image(at: $0, in: store) }
    }

    private func editor(_ shown: NoteEditor, isFocus: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if isFocus ? shown.text().isEmpty : draft.isBlank, !isWriting {
                Text(isFocus ? "Nothing under this row yet. Write here." : isDay ? "Nothing written on this day yet." : (draft.exists ? "Write here." : "No note has this title yet. Write here to make it."))
                    .font(.system(size: TextSettings.size, design: TextSettings.design))
                    .foregroundStyle(Color.inkFaint)
                    .padding(.top, 2)
                    // Under a row, beside the bullet its empty row is shown with: where its words will be.
                    .padding(.leading, isFocus ? Ink.editorTheme.step : 0)
                    .allowsHitTesting(false)
            }
            NoteEditorView(
                editor: shown, theme: Ink.editorTheme, isWriting: isWriting, height: $bodyHeight,
                refresh: store.indexRevision,
                pageExists: { name in store.leadsSomewhere(name) },
                    linkLabel: { name in store.linkLabel(name) },
                    linkIcon: { name in store.linkIcon(name) },
                blockView: { block in
                    // One picture, or several side by side: a carousel.
                    if block.info == EditorBlock.picture, let line = PictureLine(line: block.source) {
                        return AnyView(PhonePictures(store: store, pictures: line.pictures, room: block.room))
                    }
                    // A link alone on its row, shown as its card.
                    if block.info == EditorBlock.card {
                        return AnyView(LinkCardBlock(store: store, source: block.source, open: { follow($0) }, showAsLink: block.showAsLink))
                    }
                    guard block.info == "query" else { return nil }
                    return AnyView(PhoneQuery(store: store, source: block.source, this: draft.title) { page in
                        withAnimation(.snappy(duration: 0.28)) { store.open(page: page, after: card.id) }
                    })
                },
                lead: isFocus ? nil : editorLead, onLead: { leadTapped() },
                offers: { found in store.linkOffers(found.typed, this: card.path) },
                offersTitle: !isFocus && isUntitled, onTitle: { withAnimation(.snappy(duration: 0.22)) { _ = draft.titleByFirstLine() } },
                    // Which rows are folded is the note's own to remember. What a river
                    // remembered of them, before notes did, is handed over once.
                    foldedRows: isFocus || card.folds == nil ? nil : card.foldedRows,
                    onFolds: { _ in
                        guard river.card(card.id)?.folds != nil else { return }
                        river.setFolds(card.id, [])
                        store.rememberRiversSoon()
                    },
                    onMoveRows: { markdown, moved in store.movingRows = GraphStore.MovingRows(markdown: markdown, from: card.path, moved: moved) },
                    savePictures: { pictures in pictures.compactMap { store.savePicture(data: $0.data, fileExtension: $0.fileExtension) } },
                onZoom: { name, apart in zoom(name, apart: apart) },
                onZoomOut: isFocus ? { widen(shown) } : nil,
                marks: marks(in: shown, isFocus: isFocus),
                onChange: { if isFocus { draft.changed(from: card.id) } else { draft.changed() } },
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
            .fixedSize(horizontal: false, vertical: true)
            .id(isFocus ? "focus" : "\(draft.mode)")
            .opacity(draft.task == .done ? 0.5 : 1)
        }
    }

    /// A note with no title has its ring or icon at the head of its first line, in place of the bullet.
    private var editorLead: EditorLead? {
        guard !showsHeader else { return nil }
        switch draft.task {
        case .todo: return EditorLead(symbol: "circle")
        case .done: return EditorLead(symbol: "checkmark.circle.fill", isDone: true)
        case .none:
            let tint = emblem.color.map { PlatformColor($0.color) }
            if let progress = emblem.progress { return EditorLead(symbol: "circle", tint: tint, progress: progress) }
            return emblem.symbol.map { EditorLead(symbol: $0, tint: tint) }
        }
    }

    private func isFrontTag(_ tag: String) -> Bool {
        draft.frontTags.contains { nameKey(name: $0) == nameKey(name: tag) }
    }

    private func removeTag(_ tag: String) {
        draft.removeTag(tag)
        withAnimation(.snappy(duration: 0.2)) { tags.removeAll { nameKey(name: $0) == nameKey(name: tag) } }
    }

    private func leadTapped() {
        if draft.task == .none { choosesLook = true } else { withAnimation(.snappy(duration: 0.2)) { draft.setTask(draft.task == .done ? .todo : .done) } }
    }

    private var foot: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                pill(tag, Emblem(symbol: "number"), Color.inkAccent) { store.open(name: tag, after: card.id, in: river) }
                    .contextMenu {
                        // A tag written in a line is its line's: only the note's own can be taken off it here.
                        if isFrontTag(tag) { Button("Remove Tag", systemImage: "minus.circle", role: .destructive) { removeTag(tag) } }
                        Button("Open Tag", systemImage: "number") { store.open(name: tag, after: card.id, in: river) }
                    }
            }
            // The pages it names as related — a day it was stamped with — beside its tags.
            ForEach(store.related(draft.related)) { page in
                pill(page.title, page.emblem, Color.inkAccent) { store.open(name: page.name, after: card.id, in: river) }
                    .contextMenu {
                        Button("Open", systemImage: "arrow.up.right") { store.open(name: page.name, after: card.id, in: river) }
                        Button("Remove", systemImage: "minus.circle", role: .destructive) { withAnimation(.snappy(duration: 0.2)) { draft.unrelate(page.written) } }
                    }
            }
            if draft.exists, !tags.isEmpty {
                pill("Tag", Emblem(symbol: "plus"), Color.inkSecondary) { addsTag = true }
            }
        }
        .padding(.top, 4)
    }

    /// The pages that link here: one line of quiet text, each name a way there.
    private var mentions: some View {
        MentionLine(titles: backlinks.map(\.title), open: { index in
            let source = backlinks[index]
            withAnimation(.snappy(duration: 0.28)) { store.openMention(in: source.path, title: source.name, of: card.path, after: card.id, in: river) }
        }, openAll: {
            withAnimation(.snappy(duration: 0.24)) { store.openMentions(of: card.path) }
        })
        .padding(.top, tags.isEmpty && draft.related.isEmpty ? 4 : 0)
    }

    private func pill(_ title: String, _ emblem: Emblem, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if emblem.isShown { EmblemView(emblem, size: 13, style: .plain, quiet: tint) }
                Text(emblem.caption(title)).font(.system(size: 13)).lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    private var conflict: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Two devices changed the same lines.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            HStack {
                Button("Keep This Device\u{2019}s") { draft.resolve(keeping: .ours) }
                Button("The Other\u{2019}s") { draft.resolve(keeping: .theirs) }
                Button("Both") { draft.resolve(keeping: .both) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// A folded card: its ring or icon, what it is called, and how it goes on — three lines of it.
    private var peek: some View {
        HStack(alignment: .firstTextBaseline, spacing: TextSettings.size * 0.35) {
            lead(size: TextSettings.size * 1.1)
            let thumb = draft.firstPicture.flatMap { Pictures.image(at: $0.address, in: store) }
            let named = !(thumb != nil && draft.isUntitled && draft.label == "Untitled")
            Text("\(Text(named ? emblem.caption(draft.label) : "").bold().foregroundStyle(draft.task == .done ? Color.inkSecondary : Color.inkText).strikethrough(draft.task == .done))\(named ? "  " : "")\(Text(draft.summary).foregroundStyle(Color.inkSecondary))")
                .font(.system(size: TextSettings.size, design: TextSettings.design))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let thumb {
                let side = (TextSettings.size * 1.3 * 3).rounded()
                Image(platform: thumb).resizable().aspectRatio(contentMode: .fill).frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .alignmentGuide(.firstTextBaseline) { $0[.top] + TextSettings.size }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            withAnimation(.snappy(duration: 0.22)) { river.toggleFold(card.id) }
            river.writing = card.id
        }
        .onTapGesture { fold() }
        .contextMenu { holdMenu }
        .onDrag { carry() } preview: { carriedLabel }
    }

    /// The strip under the card being written in, or tapped last.
    private var drawer: some View {
        HStack(spacing: 0) {
            drawerButton("arrow.down.right.and.arrow.up.left.circle", "Fold") { fold() }
            drawerButton(draft.mode == .outline ? "line.3.horizontal.circle" : "list.bullet.circle", draft.mode == .outline ? "Write as Text" : "Write as an Outline") {
                draft.setMode(draft.mode == .outline ? .text : .outline)
            }
            // Its pages to read: the reader, a tap away.
            if canRead { drawerButton("doc.richtext", "Read") { read() } }
            if isDay {
                drawerButton("chevron.backward.circle", "The Day Before") { step(-1) }
                drawerButton("chevron.forward.circle", "The Day After") { step(1) }
            }
            if river.query != nil {
                if river.isFound(card.id) {
                    drawerButton("pin.circle", "Keep at Top") { withAnimation(.snappy(duration: 0.28)) { river.hold(card.id) }; store.rememberRivers() }
                } else {
                    drawerButton("arrow.uturn.down.circle", "Release to Query") { withAnimation(.snappy(duration: 0.28)) { store.close(card.id, in: river) } }
                }
            }
            Menu { menuItems } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 22)).frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
            }
            drawerButton("xmark.circle", "Close") { withAnimation(.snappy(duration: 0.28)) { store.close(card.id, in: river) } }
        }
        .foregroundStyle(Color.inkAccent)
        .padding(.horizontal, 6)
        .frame(height: 46)
        .glassEffect(.regular.tint(Color.inkAccent.opacity(0.12)).interactive(), in: .capsule)
        // Glass comes and goes as glass does: it melts away with its card's choosing, and is not left behind.
        .glassEffectTransition(.materialize)
        .padding(.top, 12)
        .padding(.horizontal, 24)
    }

    private func drawerButton(_ symbol: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 22)).frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    // MARK: Swipes

    private var leadingActions: [SwipeAction] {
        guard draft.exists, !isDay else { return [] }
        let inbox = draft.isMarked("inbox")
            ? SwipeAction(name: "Out of Inbox", symbol: "tray.and.arrow.up", tint: .blue) { draft.toggleMark("inbox") }
            : SwipeAction(name: "Inbox", symbol: "tray.and.arrow.down", tint: .blue) { draft.toggleMark("inbox") }
        switch draft.task {
        case .todo: return [SwipeAction(name: "Done", symbol: "checkmark.circle.fill", tint: .green) { draft.setTask(.done) }, inbox]
        case .done: return [SwipeAction(name: "To Do", symbol: "circle", tint: .orange) { draft.setTask(.todo) }, inbox]
        case .none:
            let todo = SwipeAction(name: "To Do", symbol: "circle", tint: .orange) { draft.setTask(.todo) }
            return draft.isMarked("inbox") ? [inbox, todo] : [todo, inbox]
        }
    }

    private var trailingActions: [SwipeAction] {
        var actions: [SwipeAction] = []
        if draft.exists { actions.append(SwipeAction(name: "Delete", symbol: "trash", tint: .red) { withAnimation(.snappy(duration: 0.28)) { store.delete(card.id, in: river) } }) }
        actions.append(SwipeAction(name: river.isFound(card.id) ? "Remove" : "Close", symbol: "xmark", tint: .gray) { withAnimation(.snappy(duration: 0.28)) { store.close(card.id, in: river) } })
        // Outer first: a full swipe closes; deleting takes a tap.
        return actions.reversed()
    }

    // MARK: Menus

    /// What a hold on the title gives.
    @ViewBuilder private var holdMenu: some View {
        if !isDay { Button(isUntitled ? "Add Title…" : "Rename…", systemImage: "character.cursor.ibeam") { startRenaming() } }
        if draft.exists, !isDay {
            Button(draft.isMarked("pinned") ? "Unpin" : "Pin", systemImage: draft.isMarked("pinned") ? "pin.slash" : "pin") { draft.toggleMark("pinned") }
            Button(draft.isMarked("inbox") ? "Done with It" : "Add to Inbox", systemImage: draft.isMarked("inbox") ? "tray.and.arrow.up" : "tray.and.arrow.down") { draft.toggleMark("inbox") }
        }
        if draft.exists { Button("Choose Icon…", systemImage: draft.icon ?? "square.grid.3x3") { choosesLook = true } }
        if canRead { Button("Read", systemImage: "doc.richtext") { read() } }
        Button("Copy Link", systemImage: "link") { UIPasteboard.general.string = "[[\(store.linkName(path: card.path, title: draft.title))]]" }
        Button("Copy Contents", systemImage: "doc.on.doc") { UIPasteboard.general.string = draft.markdown }
        ShareLink(item: draft.markdown) { Label("Share", systemImage: "square.and.arrow.up") }
        Menu("More", systemImage: "ellipsis.circle") { menuItems }
    }

    /// Everything that can be done with a card.
    @ViewBuilder private var menuItems: some View {
        Section {
            if !isDay { Button(isUntitled ? "Add Title…" : "Rename…", systemImage: "character.cursor.ibeam") { startRenaming() } }
            if isUntitled, !draft.isBlank { Button("Make First Line the Title", systemImage: "arrow.up") { withAnimation(.snappy(duration: 0.22)) { _ = draft.titleByFirstLine() } } }
            if draft.exists { Button("Icon and Colour…", systemImage: "paintpalette") { choosesLook = true } }
            if draft.exists { Button("Add Tag…", systemImage: "number") { addsTag = true } }
            // Linked to today in its frontmatter: today's page lists it.
            if !isDay {
                let today = Days.name(Date())
                Button(draft.isStamped(today) ? "Stamped with Today" : "Stamp with Today", systemImage: "calendar.badge.plus") { draft.stamp(today) }
                    .disabled(draft.isStamped(today))
            }
        }
        if draft.exists, !isDay {
            Section {
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
        }
        Section {
            Button(card.folded ? "Unfold" : "Fold", systemImage: card.folded ? "chevron.down" : "chevron.right") { fold() }
            Picker("Write As", selection: Binding(get: { draft.mode }, set: { draft.setMode($0) })) {
                Label("Outline", systemImage: "list.bullet.indent").tag(EditorMode.outline)
                Label("Text", systemImage: "text.alignleft").tag(EditorMode.text)
            }
            if canRead { Button("Read", systemImage: "doc.richtext") { read() } }
            Button("Move to Top", systemImage: "arrow.up.to.line") {
                withAnimation(.snappy(duration: 0.28)) { river.move(card.id, toPlace: 0) }
                store.rememberRivers()
            }
            Button("Move to Bottom", systemImage: "arrow.down.to.line") {
                withAnimation(.snappy(duration: 0.28)) { river.move(card.id, toPlace: river.cards.count - 1) }
                store.rememberRivers()
            }
            Button("Close Others", systemImage: "rectangle.stack.badge.minus") { withAnimation(.snappy(duration: 0.28)) { store.closeAll(in: river, but: card.id) } }
            Button("Close", systemImage: "xmark") { withAnimation(.snappy(duration: 0.28)) { store.close(card.id, in: river) } }
        }
        Section {
            Button("Copy Link", systemImage: "link") { UIPasteboard.general.string = "[[\(store.linkName(path: card.path, title: draft.title))]]" }
            Button("Copy Contents", systemImage: "doc.on.doc") { UIPasteboard.general.string = draft.markdown }
        }
        if draft.exists {
            Button("Delete Note", systemImage: "trash", role: .destructive) { withAnimation(.snappy(duration: 0.28)) { store.delete(card.id, in: river) } }
        }
    }

    // MARK: What can be done

    private func fold() {
        river.selected = card.id
        withAnimation(.snappy(duration: 0.22)) { river.toggleFold(card.id) }
        store.rememberRivers()
    }

    /// The note's pages, read over the river.
    private func read() {
        draft.saveNow()
        river.writing = nil
        river.reading = River.Place(path: card.path, title: card.title)
    }

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
        newTitle = focused?.focusTitle() ?? (isUntitled ? "" : draft.title)
        isRenaming = true
        titleFocused = true
    }

    private func finishRenaming() {
        guard isRenaming else { return }
        isRenaming = false
        if let focused {
            // The row shown is rewritten, in the note.
            focused.setFocusTitle(title: newTitle)
            return draft.changed(from: card.id)
        }
        // An untitled note's field, left empty and submitted, takes its first line.
        if isUntitled, newTitle.trimmingCharacters(in: .whitespaces).isEmpty { return }
        draft.rename(to: newTitle)
        store.retitled(path: card.path, to: draft.title)
    }

    private func follow(_ target: EditorLink) {
        switch target {
        case .page(let name), .tag(let name):
            withAnimation(.snappy(duration: 0.28)) { store.open(name: name, after: card.id, in: river) }
        case .web(let address):
            // Its card first: what it is, before going there.
            linkShown = PhoneLink(address: address)
        }
    }

    private func carry() -> NSItemProvider {
        carried.wrappedValue = card.id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: PhoneCardMove.type.identifier, visibility: .ownProcess) { done in
            done(Data(card.id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    private var carriedLabel: some View {
        Text(draft.label).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.inkCard))
            .foregroundStyle(Color.inkText)
    }
}

/// A card carried over the river's others: each it passes over makes room.
struct PhoneCardMove: DropDelegate {
    static let type = UTType(exportedAs: "com.mariusae.weft.card")

    let target: Card.ID
    let river: River
    let store: GraphStore
    @Binding var carried: Card.ID?

    func dropEntered(info: DropInfo) {
        guard let carried, carried != target, let place = river.all.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.snappy(duration: 0.28)) { river.move(carried, toPlace: place) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        carried = nil
        store.rememberRivers()
        return true
    }
}

// MARK: - Swiping a card aside

/// Something a swipe does to a card.
struct SwipeAction {
    var name: String
    var symbol: String
    var tint: Color
    var run: () -> Void
}

/// A card swiped aside shows what the swipe would do: a little way, and
/// its actions wait to be tapped; far enough, and the outer one is done
/// on letting go. `leading` shows when swiped right, `trailing` when
/// swiped left; in each the outer action is first.
struct CardSwipe: ViewModifier {
    var leading: [SwipeAction]
    var trailing: [SwipeAction]
    var enabled: Bool
    @State private var offset: CGFloat = 0
    /// Where it rests, open: ± the width of the actions shown.
    @State private var rest: CGFloat = 0
    @State private var committing = false
    @State private var size: CGSize = .zero

    private static let button: CGFloat = 84, gap: CGFloat = 10

    private func open(_ actions: [SwipeAction]) -> CGFloat {
        actions.isEmpty ? 0 : Self.button * CGFloat(actions.count) + Self.gap * CGFloat(actions.count + 1)
    }

    private var side: [SwipeAction] { offset > 0 ? leading : trailing }
    private var threshold: CGFloat { max(open(side) + 40, size.width * 0.55) }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .background { if offset != 0 { actions } }
            .overlay {
                // Open, a tap anywhere on the card closes it.
                // Over the card where it now is — not over the actions beside it, which are for tapping.
                if rest != 0 { Color.clear.contentShape(Rectangle()).offset(x: offset).onTapGesture { settle(to: 0) } }
            }
            .gesture(SidewaysPan(enabled: enabled, changed: changed, ended: ended))
            .sensoryFeedback(.impact(weight: .medium), trigger: committing) { _, now in now }
            .onChange(of: enabled) { _, now in if !now { settle(to: 0) } }
    }

    private var actions: some View {
        let shown = side
        let pulled = abs(offset)
        return HStack(spacing: Self.gap) {
            // The outer action is at the screen's edge; past the threshold it takes all the room.
            ForEach(Array((offset > 0 ? shown : shown.reversed()).enumerated()), id: \.offset) { _, action in
                let isOuter = action.name == shown.first?.name
                if !committing || isOuter {
                    Button {
                        settle(to: 0)
                        action.run()
                    } label: {
                        Group {
                            if size.height < 80 {
                                // A short card: one capsule its height, the name beside the symbol.
                                HStack(spacing: 4) {
                                    Image(systemName: action.symbol).font(.system(size: 13, weight: .semibold))
                                    Text(action.name).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: committing ? .infinity : Self.button)
                                .frame(height: max(size.height, 30))
                                .background(Capsule().fill(action.tint))
                            } else {
                                // A capsule with its symbol, and under it what it does.
                                VStack(spacing: 4) {
                                    Image(systemName: action.symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                                        .frame(maxWidth: committing ? .infinity : Self.button)
                                        .frame(height: 46)
                                        .background(Capsule().fill(action.tint))
                                    Text(action.name).font(.caption.weight(.medium)).foregroundStyle(Color.inkSecondary).lineLimit(1).minimumScaleFactor(0.7)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Self.gap)
        .frame(width: max(pulled, 0), alignment: offset > 0 ? .leading : .trailing)
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: offset > 0 ? .leading : .trailing)
        .opacity(min(pulled / 40, 1))
    }

    private func changed(_ x: CGFloat) {
        var to = rest + x
        // A side with nothing to do gives a little, and no more.
        if (to > 0 && leading.isEmpty) || (to < 0 && trailing.isEmpty) { to *= 0.15 }
        offset = to
        let past = abs(to) > threshold && !side.isEmpty
        if past != committing { withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { committing = past } }
    }

    private func ended(_ x: CGFloat, _ velocity: CGFloat) {
        let shown = side
        if committing, let outer = shown.first {
            settle(to: 0)
            outer.run()
            return
        }
        let width = open(shown)
        if rest != 0 {
            // Open already: swiped back, it closes.
            let back = (rest > 0) != (x > 0)
            settle(to: back && (abs(x) > 24 || abs(velocity) > 300) ? 0 : rest)
        } else if !shown.isEmpty, abs(offset) > 40 || abs(velocity) > 600 {
            settle(to: offset > 0 ? width : -width)
        } else {
            settle(to: 0)
        }
    }

    private func settle(to: CGFloat) {
        rest = to
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            offset = to
            committing = false
        }
    }
}

/// A pan that begins only when it goes sideways: so that a river still
/// scrolls under a finger that goes down it.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    var enabled: Bool
    var changed: (CGFloat) -> Void
    var ended: (CGFloat, CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = true

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.4
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Beside taps, not beside other pans.
            !(other is UIPanGestureRecognizer)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            // A swipe that starts on a carousel of pictures turns it: the card stays where it is.
            other is CarouselSwipe.Pan
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.enabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let x = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed: changed(x)
        case .ended: ended(x, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }
}

// MARK: - What a note shows in place of its lines

/// What a query block finds, where the block is written.
struct PhoneQuery: View {
    let store: GraphStore
    let source: String
    let this: String
    var open: (PageInfo) -> Void
    @State private var found: QueryOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(source.split(whereSeparator: \.isNewline).first.map(String.init) ?? "query").lineLimit(1)
                Spacer()
                if let found { Text("\(found.total)") }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.inkSecondary)
            if let found, !found.pages.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(found.pages, id: \.path) { page in
                        Button { open(page) } label: {
                            Text(store.emblem(page).caption(page.label)).font(.system(size: TextSettings.size - 1, design: TextSettings.design)).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .foregroundStyle(Color.inkAccent)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.inkAccent.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.inkAccent.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.inkAccent.opacity(0.15)))
        .task(id: "\(store.indexRevision)|\(source)") { found = try? store.engine.runQuery(body: source, this: this) }
    }
}
/// A link on the web, to show the card of.
struct PhoneLink: Identifiable {
    var address: String
    var id: String { address }
}

/// The card of a page on the web, over the river: what it is, and what
/// can be done with its link — gone to, copied, or given its title.
struct PhoneLinkSheet: View {
    let link: PhoneLink
    let draft: PageDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var host: String { (URL(string: link.address)?.host ?? link.address).replacingOccurrences(of: "www.", with: "") }

    var body: some View {
        let found = WebCards.shared.found[link.address]
        let cover = found?.image.flatMap { $0.size.width >= 120 ? $0 : nil }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let cover {
                    Color.clear.frame(height: 170)
                        .overlay(Image(platform: cover).resizable().aspectRatio(contentMode: .fill))
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if cover == nil, let icon = found?.image {
                            Image(platform: icon).resizable().frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                        }
                        if let title = found?.title {
                            Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(3)
                        } else if found == nil {
                            ProgressView().controlSize(.small)
                            Text(host).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        } else {
                            Text(host).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        }
                    }
                    Text(link.address).font(.footnote).foregroundStyle(Color.inkSecondary).lineLimit(2).truncationMode(.middle)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.inkCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.inkRule, lineWidth: 0.5))

            VStack(spacing: 10) {
                Button {
                    if let url = URL(string: link.address) { openURL(url) }
                    dismiss()
                } label: {
                    Label("Open", systemImage: "safari")
                }
                .buttonStyle(SheetButton(isMain: true))
                if let title = found?.title, draft.hasBareLink(link.address) {
                    Button {
                        draft.titleLink(link.address, as: title)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        dismiss()
                    } label: {
                        Label("Replace Link with Its Title", systemImage: "textformat")
                    }
                    .buttonStyle(SheetButton())
                }
                // A link alone on its row: shown as its card, or as its words again.
                if let at = draft.cardRow(for: .web(link.address)) {
                    Button {
                        draft.toggleCard(row: at.row)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        dismiss()
                    } label: {
                        Label(at.isCard ? "Show as Link" : "Show as Card", systemImage: at.isCard ? "link" : "rectangle.on.rectangle")
                    }
                    .buttonStyle(SheetButton())
                }
                Button {
                    UIPasteboard.general.string = link.address
                    dismiss()
                } label: {
                    Label("Copy Link", systemImage: "doc.on.doc")
                }
                .buttonStyle(SheetButton())
            }
            .controlSize(.large)
            .padding(.top, 16)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .foregroundStyle(Color.inkText)
        .onAppear { WebCards.shared.look(link.address) }
    }
}
/// A sheet's button, the width of the sheet: the one most likely wanted
/// in the accent, its words dark on it; the others a quiet fill, their
/// words in the text's own colour. Told apart, and read, on glass.
struct SheetButton: ButtonStyle {
    var isMain = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isMain ? Color.black.opacity(0.85) : Color.inkText)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().fill(isMain ? AnyShapeStyle(Color.inkAccent) : AnyShapeStyle(Color.inkText.opacity(0.12))))
            .overlay(Capsule().strokeBorder(Color.inkText.opacity(isMain ? 0 : 0.14), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
/// A card that comes up from the foot of the screen and stands on it:
/// no gap under it. What is behind is dimmed; a touch there, or the card
/// drawn down, sends it away. Shown in a full-screen cover, whose own
/// ground it clears.
struct BottomCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var dimmed = false
    @State private var drawn: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(dimmed ? 0.4 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { leave() }
            VStack(spacing: 0) {
                Capsule().fill(Color.inkFaint.opacity(0.6)).frame(width: 38, height: 5).padding(.top, 8).padding(.bottom, 10)
                content()
            }
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                    .fill(Color.inkPaper)
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous).strokeBorder(Color.inkRule, lineWidth: 0.5))
                    // Down past the foot of the screen: it stands on the edge, and drawn up shows nothing under it.
                    .padding(.bottom, -400)
                    .ignoresSafeArea(edges: .bottom)
            )
            .offset(y: max(drawn, 0))
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { drawn = $0.translation.height }
                    .onEnded { drag in
                        if drag.translation.height > 90 || drag.predictedEndTranslation.height > 240 { leave() } else { withAnimation(.snappy(duration: 0.25)) { drawn = 0 } }
                    }
            )
        }
        .presentationBackground(.clear)
        .onAppear { withAnimation(.easeOut(duration: 0.25).delay(0.1)) { dimmed = true } }
    }

    private func leave() {
        withAnimation(.easeIn(duration: 0.12)) { dimmed = false }
        dismiss()
    }
}
/// A label with its icon after its words, small.
struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.font(.system(size: 8, weight: .bold))
        }
    }
}
#endif
