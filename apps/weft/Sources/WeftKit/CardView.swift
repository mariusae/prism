#if os(macOS)
import Prism
import PrismEditor
import PrismEmblem
import SwiftUI
import WeftShared

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
    @State private var addsTag = false
    @State private var newTitle = ""
    @State private var backlinks: [Source] = []
    @State private var tags: [String] = []
    /// The pointer over the strip of actions at an untitled note's corner.
    @State private var overCorner = false
    @FocusState private var titleFocused: Bool

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

    /// Its icon — or, holding a checklist and given none, how far along that is.
    private var emblem: Emblem {
        Emblem(title: draft.title, icon: draft.icon, color: draft.color, kindSymbol: isDay ? "calendar" : nil, letter: false, progress: draft.task == .none ? draft.checklist : nil)
    }
    private var isSelected: Bool { river.selected == card.id }
    private var isWriting: Bool { river.writing == card.id }
    private var isDay: Bool { card.path.hasPrefix("daily/") || card.path.hasPrefix("weekly/") }
    private var showsActions: Bool { isHovered || isSelected }
    private var titleFont: Font { .system(size: TextSettings.titleSize, weight: .semibold, design: TextSettings.design) }

    var body: some View {
        // Read, so that the card is laid out again when the text's height changes.
        let _ = bodyHeight
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
        .padding(.trailing, Measures.cardTrailing)
        .padding(.top, card.folded ? 11 : (showsHeader ? 9 : 14))
        // A note with no title has no line for what is done to it: that
        // stands over its corner while the pointer is on the card, and
        // its ring or icon, if it has one, in its margin.
        .overlay(alignment: .topTrailing) {
            if !card.folded, !showsHeader {
                // Over the first line's end, which may have words under it: shown only under
                // the pointer — and, while the note is written in, only over the strip itself.
                let shown = overCorner || (isHovered && !isWriting)
                strip(shown: shown)
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.inkCard).opacity(shown ? 0.94 : 0))
                    .contentShape(Rectangle())
                    .onHover { overCorner = $0 }
                    .padding(.top, 7)
                    .padding(.trailing, Measures.cardTrailing - 2)
            }
        }
        .overlay(alignment: .topLeading) {
            // Only for a note that opens with no bullet for it to stand in
            // place of: then small, in the margin beside its first line.
            if !card.folded, !showsHeader, editorLead != nil, !NoteEditorView.takesLead(draft.editor) {
                lead(size: TextSettings.size).opacity(0.85).frame(width: Measures.margin).padding(.top, 17)
            }
        }
        // Where the icon and the colour are chosen, from the icon or the menu.
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: Measures.margin * 2, height: 30).allowsHitTesting(false)
                // Where a tag is added: here whether or not the card has a line of tags yet.
                .popover(isPresented: $addsTag, arrowEdge: .bottom) {
                    TagAdder(store: store, draft: draft) { addsTag = false; refresh() }.frame(width: 300)
                }
                .popover(isPresented: $choosesLook, arrowEdge: .bottom) {
                    EmblemPicker(
                        title: draft.label,
                        icon: Binding(get: { draft.icon }, set: { draft.setLook(icon: $0, color: draft.color) }),
                        color: Binding(get: { draft.color }, set: { draft.setLook(icon: draft.icon, color: $0) }),
                        kindSymbol: isDay ? "calendar" : nil
                    )
                }
        }
        .padding(.bottom, card.folded ? 11 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Measures.cardRadius, style: .continuous).fill(card.folded ? Color.inkPaper : Color.inkCard))
        .overlay(
            RoundedRectangle(cornerRadius: Measures.cardRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.inkAccent.opacity(0.5) : Color.inkRule, lineWidth: 1)
        )
        .shadow(color: .black.opacity(card.folded ? 0.03 : 0.07), radius: card.folded ? 4 : 10, y: card.folded ? 1 : 3)
        .contentShape(Rectangle())
        .onTapGesture { river.selected = card.id }
        .onHover { isHovered = $0 }
        .contextMenu { menu }
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
    }

    private struct Source: Hashable {
        var path: String
        /// What a link to it says; and what it is shown as called.
        var name: String
        var title: String
        var emblem: Emblem
    }

    private func refresh() {
        var seen = Set<String>()
        backlinks = ((try? store.engine.backlinks(path: card.path)) ?? []).compactMap { link in
            guard link.source != card.path, seen.insert(link.source).inserted else { return nil }
            // The river this card is in is no news: it is where one is.
            if let here = river.name, GraphStore.riverName(link.source) == here { return nil }
            let page = (try? store.engine.page(path: link.source)) ?? nil
            let name = page?.title ?? String(link.source.split(separator: "/").last ?? "").replacingOccurrences(of: ".md", with: "")
            return Source(path: link.source, name: name, title: page?.label ?? name, emblem: store.emblem(path: link.source, title: name))
        }
        tags = (try? store.engine.tagsOf(path: card.path)) ?? []
        store.cardFeet[Self.footKey(card, in: river)] = Foot(backlinks: backlinks, tags: tags)
    }

    // MARK: Parts

    /// A row of the card: set in from its edge by the margin, and no
    /// more — the width is the words'.
    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(.leading, Measures.margin)
    }

    /// What stands before the title, as its first character would: a
    /// to-do's ring, which checks it off; or the note's icon, if it has
    /// one — a day's calendar, a link's, one it was given — which, clicked,
    /// is where it is chosen. A note with neither has nothing here.
    @ViewBuilder private func lead(size: CGFloat) -> some View {
        switch draft.task {
        case .none:
            if emblem.isShown {
                Button { choosesLook = true } label: { EmblemView(emblem, size: size, style: .plain, quiet: Color.inkSecondary).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .disabled(!draft.exists)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - size * 0.2 }
                    .help("Choose an icon and a colour")
            }
        case .todo, .done:
            Button { withAnimation(.snappy(duration: 0.2)) { draft.setTask(draft.task == .done ? .todo : .done) } } label: {
                Image(systemName: draft.task == .done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: size * 0.9))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(draft.task == .done ? AnyShapeStyle(.white) : AnyShapeStyle(Color.inkSecondary), Color.inkAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(draft.task == .done ? "Mark Not Done" : "Mark Done")
        }
    }

    /// What a note with no title has at the head of its first line, in
    /// place of that line's bullet: its ring, if it is a to-do; else its
    /// icon, if it has one. The editor draws it, as it draws the bullets.
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

    private func leadClicked() {
        if draft.task == .none { choosesLook = true } else { withAnimation(.snappy(duration: 0.2)) { draft.setTask(draft.task == .done ? .todo : .done) } }
    }

    /// Whether the card has no title to show: a note never given one.
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
    /// each row it is under. Each, clicked, is shown in its place.
    private func trail(_ view: NoteEditor) -> some View {
        let over = view.focusTrail()
        return HStack(spacing: 4) {
            Button { widen(view, to: 0, of: over.count) } label: {
                HStack(spacing: 3) {
                    if emblem.isShown { EmblemView(emblem, size: 11, style: .plain, quiet: Color.inkSecondary) }
                    Text(emblem.caption(draft.label)).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help("Show the Whole Note")
            ForEach(Array(over.enumerated()), id: \.offset) { index, crumb in
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.inkFaint)
                Button(crumb.isEmpty ? "…" : Days.shown(crumb)) { widen(view, to: index + 1, of: over.count) }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.system(size: 11.5, design: TextSettings.design))
        .foregroundStyle(Color.inkSecondary)
        .pointerStyle(.link)
    }

    private func focusHeader(_ view: NoteEditor) -> some View {
        row {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .center, spacing: 10) {
                    trail(view)
                    Spacer(minLength: 8)
                    focusActions(view)
                }
                .frame(minHeight: 24)
                if isRenaming {
                    TextField("Row", text: $newTitle)
                        .textFieldStyle(.plain)
                        .font(titleFont)
                        .focused($titleFocused)
                        .onSubmit { finishRenaming() }
                        .onExitCommand { isRenaming = false }
                        .onChange(of: titleFocused) { _, focused in if !focused { finishRenaming() } }
                } else {
                    Text(focusLabel(view))
                        .font(titleFont)
                        .foregroundStyle(Color.inkText)
                        .lineLimit(2)
                        .onTapGesture(count: 2) { startRenaming() }
                        .onTapGesture { fold() }
                        .help("Click to fold, double-click to rewrite")
                }
            }
        }
    }

    private func focusLabel(_ view: NoteEditor) -> String {
        let _ = draft.revision
        // A row that is a link — a day's, say — is titled as the link reads.
        let label = store.titled(view.focusLabel() ?? "", written: view.focusTitle() ?? "")
        return label.isEmpty ? "Untitled" : label
    }

    private func focusPeek(_ view: NoteEditor) -> some View {
        row {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Text(focusLabel(view)).bold().foregroundStyle(Color.inkText))  \(Text(([draft.label] + view.focusTrail().map(Days.shown)).joined(separator: " › ")).foregroundStyle(Color.inkSecondary))")
                    .font(.system(size: TextSettings.size, design: TextSettings.design))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { fold() }
                focusActions(view)
            }
        }
    }

    private func focusActions(_ view: NoteEditor) -> some View {
        HStack(spacing: 1) {
            if !card.folded {
                CardButton("arrow.up.left", help: "Show the Row Above (⌘[)") { widen(view) }
                CardButton("arrow.up.left.and.arrow.down.right", help: "Show the Whole Note") { widen(view, to: 0, of: 0) }
            }
            CardButton("xmark", help: "Close (⌘W)") { withAnimation(.snappy(duration: 0.28)) { close() } }
        }
        .opacity(showsActions ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: showsActions)
        .allowsHitTesting(showsActions)
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

    private var header: some View {
        row {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if isRenaming {
                    TextField("Title", text: $newTitle)
                        .textFieldStyle(.plain)
                        .font(titleFont)
                        .focused($titleFocused)
                        .onSubmit { finishRenaming() }
                        .onExitCommand { isRenaming = false }
                        .onChange(of: titleFocused) { _, focused in if !focused { finishRenaming() } }
                } else if let address = linkAddress, LinkNoteHeader.isAvailable(address, cover: linkCover) {
                    // A link note: headed by the card of the page it keeps.
                    LinkNoteHeader(address: address, title: draft.title, cover: linkCover, titleFont: titleFont)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { startRenaming() }
                        .onTapGesture { fold() }
                        .help("Click to fold, double-click to rename")
                } else {
                    // The icon is the title's first character: on its line, at its edge.
                    HStack(alignment: .firstTextBaseline, spacing: TextSettings.titleSize * 0.3) {
                        lead(size: TextSettings.titleSize)
                        Text(emblem.caption(isDay ? draft.label : draft.title))
                            .font(titleFont)
                            .italic(!draft.exists)
                            .strikethrough(draft.task == .done, color: Color.inkSecondary)
                            .foregroundStyle(draft.task == .done ? Color.inkSecondary : Color.inkText)
                            .lineLimit(1)
                            .onTapGesture(count: 2) { if !isDay { startRenaming() } }
                            .onTapGesture { fold() }
                            .help("Click to fold, double-click to rename")
                    }
                    if draft.isMarked("pinned") {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(Color.inkAccent)
                    }
                }
                Spacer(minLength: 8)
                actions
            }
            .frame(minHeight: 30)
            .task(id: linkAddress) {
            guard let linkAddress else { return }
            WebCards.shared.look(linkAddress)
            // Called by no more than its site's name: given what the page says of itself.
            if WebPageInfo.isBare(title: draft.title, url: linkAddress), let info = await WebPageInfo.read(linkAddress) {
                store.fillLinkNote(path: card.path, from: info)
            }
        }
        }
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

    /// The strip of what is done to a card most.
    private var actions: some View { strip(shown: showsActions) }

    private func strip(shown showsActions: Bool) -> some View {
        HStack(spacing: 1) {
            // A note with no title has no title to click, to fold it.
            if !showsHeader, !card.folded { CardButton("chevron.up", help: "Fold") { fold() } }
            if isDay {
                CardButton("chevron.left", help: "The Day Before") { step(-1) }
                CardButton("chevron.right", help: "The Day After") { step(1) }
            }
            // Few, and quiet: writing as text or an outline, pinning, the inbox and deleting are under "…".
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

    private func editor(_ shown: NoteEditor, isFocus: Bool) -> some View {
        row {
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
                // The editor is the engine's note, shown: the same component
                // in every app, as an outline or as text.
                NoteEditorView(
                    editor: shown, theme: Ink.editorTheme, isWriting: isWriting, height: $bodyHeight,
                    refresh: store.indexRevision,
                    pageExists: { name in store.leadsSomewhere(name) },
                    linkLabel: { name in store.linkLabel(name) },
                    linkIcon: { name in store.linkIcon(name) },
                    blockView: { block in
                        // A line that is only a picture is shown as the picture.
                        if block.info == EditorBlock.picture, let pictures = EditorPicture.all(line: block.source), let first = pictures.first {
                            // One picture can be resized; several on a line stand side by side.
                            if pictures.count == 1 { return AnyView(PictureView(store: store, picture: first, rewrite: block.rewrite, room: block.room, resized: block.resized)) }
                            let each = max((block.room - CGFloat(pictures.count - 1) * 8) / CGFloat(pictures.count), 60)
                            return AnyView(HStack(alignment: .top, spacing: 8) {
                                ForEach(Array(pictures.enumerated()), id: \.offset) { _, picture in PictureView(store: store, picture: picture, rewrite: nil, room: each) }
                            })
                        }
                        // A link alone on its row, shown as its card.
                        if block.info == EditorBlock.card {
                            return AnyView(LinkCardBlock(store: store, source: block.source, open: { follow($0) }, showAsLink: block.showAsLink))
                        }
                        guard block.info == "query" else { return nil }
                        return AnyView(QueryView(store: store, source: block.source, this: draft.title) { page in
                            withAnimation(.snappy(duration: 0.28)) { store.open(page: page, after: card.id) }
                        })
                    },
                    linkPreview: { link in LinkCard.shows(link, in: store) ? AnyView(LinkCard(store: store, link: link, draft: draft)) : nil },
                    webTitle: { address in
                        WebCards.shared.look(address)
                        return WebCards.shared.found[address]?.title
                    },
                    lead: isFocus ? nil : editorLead, onLead: { leadClicked() },
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
                    marks: store.finding.marks(of: card.id) ?? marks(in: shown, isFocus: isFocus), markAt: store.finding.at(card.id),
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
                // Its height is the text's own, asked of it as it is laid
                // out — not a number that arrives a frame later and moves
                // everything under it.
                .fixedSize(horizontal: false, vertical: true)
                .id(isFocus ? "focus" : "\(draft.mode)")
                // A to-do done is set back: there, and no longer asking.
                .opacity(draft.task == .done ? 0.5 : 1)
            }
        }
    }

    /// What the page is tagged, and who links to it: a line of pills.
    private var foot: some View {
        row {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    FootPill(title: tag, emblem: Emblem(symbol: "number"), tint: Color.inkAccent) { store.open(name: tag, after: card.id, in: river) }
                        .contextMenu {
                            // A tag written in a line is its line's: only the note's own can be taken off it here.
                            if isFrontTag(tag) { Button("Remove Tag", systemImage: "minus.circle") { removeTag(tag) } }
                            Button("Open Tag", systemImage: "number") { store.open(name: tag, after: card.id, in: river) }
                        }
                }
                // The pages it names as related — a day it was stamped with — beside its tags.
                ForEach(store.related(draft.related)) { page in
                    FootPill(title: page.title, emblem: page.emblem, tint: Color.inkAccent) { store.open(name: page.name, after: card.id, in: river) }
                        .help("Related: \(page.title)")
                        .contextMenu {
                            Button("Open", systemImage: "arrow.up.right") { store.open(name: page.name, after: card.id, in: river) }
                            Button("Remove", systemImage: "minus.circle") { withAnimation(.snappy(duration: 0.2)) { draft.unrelate(page.written) } }
                        }
                }
                // Another tag: beside those there are, and where one is being added.
                if draft.exists, !tags.isEmpty {
                    FootPill(title: "Tag", emblem: Emblem(symbol: "plus"), tint: Color.inkSecondary) { addsTag = true }
                        .help("Add a tag")
                }
            }
            .padding(.top, 4)
        }
    }

    /// The pages that link here: one line of quiet text, each name a way there.
    private var mentions: some View {
        row {
            MentionLine(titles: backlinks.map(\.title), open: { openMention(backlinks[$0]) }, openAll: {
                withAnimation(.snappy(duration: 0.24)) { store.openMentions(of: card.path) }
            })
            .padding(.top, tags.isEmpty && draft.related.isEmpty ? 4 : 0)
        }
    }

    /// A page that links here, opened after this card — showing where it does.
    private func openMention(_ source: Source) {
        withAnimation(.snappy(duration: 0.28)) { store.openMention(in: source.path, title: source.name, of: card.path, after: card.id, in: river) }
    }

    private var conflict: some View {
        row {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                Text("Two devices changed the same lines.").font(.callout).foregroundStyle(Color.inkSecondary)
                Button("Keep This Device's") { draft.resolve(keeping: .ours) }
                Button("Keep the Other's") { draft.resolve(keeping: .theirs) }
                Button("Keep Both") { draft.resolve(keeping: .both) }
            }
            .controlSize(.small)
        }
    }

    private var peek: some View {
        row {
            HStack(alignment: .firstTextBaseline, spacing: TextSettings.size * 0.35) {
                lead(size: TextSettings.size * 1.1)
                // Its pictures, small, at its end: often all there is to know it by.
                let thumbs = draft.pictures.compactMap { Pictures.image(at: $0.address, in: store) }
                let thumb = thumbs.first
                // Called by its title — or, never given one, by its first words;
                // a note that is only a picture is called nothing, and shown by it.
                let named = !(thumb != nil && draft.isUntitled && draft.label == "Untitled")
                Text("\(Text(named ? emblem.caption(draft.label) : "").bold().foregroundStyle(draft.task == .done ? Color.inkSecondary : Color.inkText).strikethrough(draft.task == .done))\(named ? "  " : "")\(Text(draft.summary).foregroundStyle(Color.inkSecondary))")
                    .font(.system(size: TextSettings.size, design: TextSettings.design))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { fold() }
                ForEach(Array(thumbs.enumerated()), id: \.offset) { _, picture in
                    // As tall as two lines and a bit, and as wide as that makes it — within reason.
                    let tall: CGFloat = 52
                    let wide = min(max(tall * picture.size.width / max(picture.size.height, 1), 24), 120)
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: wide, height: tall)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.inkRule, lineWidth: 0.5))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + TextSettings.size * 0.35 }
                        .onTapGesture { fold() }
                }
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
        if isUntitled, !draft.isBlank { Button("Make First Line the Title", systemImage: "arrow.up") { withAnimation(.snappy(duration: 0.22)) { _ = draft.titleByFirstLine() } } }
        if draft.exists { Button("Icon and Colour…", systemImage: "paintpalette") { choosesLook = true } }
        if draft.exists { Button("Add Tag…", systemImage: "number") { addsTag = true } }
        if river.query == nil || !river.isFound(card.id) { MoveToRiverMenu(store: store, river: river, ids: [card.id]) }
        if !isDay {
            let today = Days.name(Date())
            Button(draft.isStamped(today) ? "Stamped with Today" : "Stamp with Today", systemImage: "calendar.badge.plus") { draft.stamp(today) }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(draft.isStamped(today))
        }
        Picker("Write As", selection: Binding(get: { draft.mode }, set: { draft.setMode($0) })) {
            Label("Outline", systemImage: "list.bullet.indent").tag(EditorMode.outline)
            Label("Text", systemImage: "text.alignleft").tag(EditorMode.text)
        }
        Button("Copy Link", systemImage: "link") { copy("[[\(store.linkName(path: card.path, title: draft.title))]]") }
        Button("Copy Contents", systemImage: "doc.on.doc") { copy(draft.markdown) }
        #if os(macOS)
        Button("Show in Finder", systemImage: "folder") {
            if let file = try? store.engine.absolutePath(path: card.path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
        }
        #endif
        Divider()
        Button("Move to Top", systemImage: "arrow.up.to.line") {
            withAnimation(.snappy(duration: 0.28)) { river.move(card.id, toPlace: 0) }
            store.rememberRivers()
        }
        Button("Move to Bottom", systemImage: "arrow.down.to.line") {
            withAnimation(.snappy(duration: 0.28)) { river.move(card.id, toPlace: river.cards.count - 1) }
            store.rememberRivers()
        }
        Button("Close Others", systemImage: "rectangle.stack.badge.minus") {
            withAnimation(.snappy(duration: 0.28)) { store.closeAll(in: river, but: card.id) }
        }
        if river.query != nil {
            if river.isFound(card.id) {
                Button("Keep at Top", systemImage: "pin.circle") { withAnimation(.snappy(duration: 0.28)) { river.hold(card.id) }; store.rememberRivers() }
            } else {
                Button("Release to Query", systemImage: "arrow.uturn.down.circle") { withAnimation(.snappy(duration: 0.28)) { river.close(card.id) }; store.rememberRivers() }
            }
        }
        Button(river.isFound(card.id) ? "Remove from River" : "Close", systemImage: "xmark") { close() }
        if draft.exists {
            Button("Delete Note", systemImage: "trash", role: .destructive) { withAnimation(.snappy(duration: 0.28)) { store.delete(card.id, in: river) } }
        }
    }

    private func isFrontTag(_ tag: String) -> Bool {
        draft.frontTags.contains { nameKey(name: $0) == nameKey(name: tag) }
    }

    private func removeTag(_ tag: String) {
        draft.removeTag(tag)
        withAnimation(.snappy(duration: 0.2)) { tags.removeAll { nameKey(name: $0) == nameKey(name: tag) } }
    }

    private func fold() {
        river.selected = card.id
        withAnimation(.snappy(duration: 0.22)) { river.toggleFold(card.id) }
        store.rememberRivers()
    }

    private func close() {
        store.close(card.id, in: river)
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
            .hint(help)
            .accessibilityLabel(help)
    }
}

/// What a control does, said under it once the pointer has rested on it
/// a moment. The system's own tip is not shown over a card's text, whose
/// view takes the pointer for itself: this one is the app's, and is.
private struct Hint: ViewModifier {
    let text: String
    @State private var isShown = false
    @State private var waiting: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                waiting?.cancel()
                waiting = nil
                guard inside else { return isShown = false }
                let work = DispatchWorkItem { isShown = true }
                waiting = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            }
            .overlay(alignment: .bottom) {
                if isShown {
                    Text(text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.inkText)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.inkRule, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        // Under the control, and never under the pointer: it takes no clicks.
                        .alignmentGuide(.bottom) { $0[.top] - 6 }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isShown)
            .zIndex(isShown ? 10 : 0)
    }
}

extension View {
    /// Says what a control does, under it, once the pointer has rested on it.
    func hint(_ text: String) -> some View { modifier(Hint(text: text)) }
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
            // An arrow over a button, though the note's text lies under it.
            .onContinuousHover { phase in if case .active = phase { NSCursor.arrow.set() } }
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

/// A small pill at a card's foot: a tag, or a page that links here.
struct FootPill: View {
    let title: String
    let emblem: Emblem
    let tint: Color
    /// Drawn over something else — fanned out of a pile — and so not to be seen through.
    var solid = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if emblem.isShown { EmblemView(emblem, size: 12, style: .plain, quiet: tint) }
                Text(emblem.caption(title)).font(.system(size: 12)).lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(isHovered ? 0.18 : 0.10)))
            .background(Capsule().fill(solid ? Color.inkCard : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // It leads somewhere, as a link in the text does: a hand.
        .pointerStyle(.link)
        .onHover { isHovered = $0 }
    }
}
#endif
