#if os(macOS)
import AppKit
import Prism
import SwiftUI
import UniformTypeIdentifiers

/// A note's body, written in where it stands.
///
/// The editor is a view of a note the engine holds open — a
/// [`NoteEditor`], which *is* the note: its tree of blocks, its title,
/// its fields. This view shows what that editor projects of the body, as
/// an outline or as text; hands back every change made in it; and does
/// what the editor answers. It keeps no note of its own, knows no
/// Markdown, and knows nothing of the app it is in: an app gives it a
/// theme, says which pages exist, and is told when the note changed, when
/// a link was followed, and when the caret came or went.
public struct NoteEditorView: NSViewRepresentable {
    let editor: NoteEditor
    let theme: EditorTheme
    let isWriting: Bool
    @Binding var height: CGFloat
    var pageExists: (String) -> Bool
    /// Whether the page a link leads to is archived.
    var pageArchived: (String) -> Bool = { _ in false }
    /// What a link's page is shown as called, where the link does not say it.
    var linkLabel: (String) -> String?
    /// The icon a link's page was given.
    var linkIcon: (String) -> String?
    var onChange: () -> Void
    var onFocus: (Bool) -> Void
    var onFollow: (EditorLink) -> Void
    /// Moved by the app when something about how the note should look
    /// changed without the note changing: a page it links to was made.
    var refresh: Int
    /// What the app draws in place of a fenced block — a query's results
    /// for a `query` block — when it is not being written in. `nil` for a
    /// block shown as the code it is.
    var blockView: (EditorBlock) -> AnyView?
    /// What the app shows of a link while the pointer rests on it: a
    /// card of the page on the web, or of the note. `nil` for nothing.
    var linkPreview: (EditorLink) -> AnyView?
    /// The title of the page at an address, if the app knows it — and,
    /// asked, goes to find it out. With this, a link on the web clicked
    /// is asked about — its words rewritten, its page's title taken for
    /// them, or it opened — and one clicked with ⌘ held is opened at once.
    /// `nil`, and a click opens it.
    var webTitle: ((String) -> String?)?
    /// What stands at the head of the note's first line in place of its
    /// bullet, and what clicking it does. Drawn only when the note opens
    /// with a plain bulleted line: see `takesLead`.
    var lead: EditorLead?
    /// Whether the note is shown as prose: its top-level rows as
    /// paragraphs — flush, apart, with no handle — and its headings as
    /// headings; what is under them as an outline still. Only the look:
    /// the rows, their keys and the note are the same.
    var prose = false
    var onLead: () -> Void
    /// The pages the app offers for a link being typed: after `[[`, and
    /// after `@`. Listed under the caret; ↑ ↓ choose, Return or Tab takes
    /// one, Escape puts the list away. None, and nothing is listed.
    var offers: (BodyCompletion) -> [EditorOffer]
    /// Whether the note has no title, and so is offered its first line
    /// for one: a quiet "Title" at that line's end while the caret is in
    /// it, and Return at the end of a first line written as a heading.
    var offersTitle: Bool
    /// The offer taken: the app makes the first line the title.
    var onTitle: () -> Void
    /// The rows of the outline that are folded: the rows under each are
    /// not shown. A fold is no part of the note — the app keeps it, where
    /// it likes: with the river the note's card is in — and so the app
    /// says here which rows are folded, and is told (`onFolds`) when that
    /// changes: a row was folded or unfolded, or the note changed around
    /// one, so that it is now known by another place or other words.
    var foldedRows: [EditorFoldedRow]?
    var onFolds: ([EditorFoldedRow]) -> Void
    /// Words found in the note, marked: where a find, or the words a card
    /// was opened by, are. `markAt`, the one gone to now, is marked more,
    /// and brought into sight.
    var marks: [NSRange]
    var markAt: Int?
    /// Where the app asks the caret to be — a row gone to — brought into
    /// sight; and told, once it is there, that it is taken.
    var caretAt: Int?
    var onCaretTaken: () -> Void
    /// Asked to show one row of the outline as a note of its own — only
    /// what is under it: handed the row's name in the note, for the app
    /// to have this card show it (`NoteEditor.setFocus`), or — `apart` —
    /// a card of its own. `nil`, and it is not offered.
    var onZoom: ((_ row: String, _ apart: Bool) -> Void)?
    /// Asked to show more than the row now shown: the row it is under.
    var onZoomOut: (() -> Void)?
    /// Takes rows to another note: handed their Markdown, the app asks
    /// where to, puts them there, and then calls what it was handed with
    /// it — which takes them out of this note. `nil`, and "Move to…" is
    /// not offered. (A phone's: the Mac has no menu of a row's yet.)
    var onMoveRows: ((_ markdown: String, _ moved: @escaping () -> Void) -> Void)?
    /// Keeps pictures pasted or dropped, and says where: a path in the
    /// graph for each, in order — `assets/pasted-….png`. They are then
    /// written where the caret is, `![](path)`, a space between them.
    /// None — as an app that does not take pictures answers — and what
    /// was pasted is pasted as the text view would.
    var savePictures: ([EditorPastedPicture]) -> [String]

    /// - Parameters:
    ///   - editor: the note. Give another to show another — or the same
    ///     note read again, after its file changed underneath.
    ///   - isWriting: whether the caret should be here.
    ///   - height: kept at the height the text needs at the width given.
    ///   - refresh: any value that changes when the look should be redone.
    public init(
        editor: NoteEditor, theme: EditorTheme, isWriting: Bool, height: Binding<CGFloat>, refresh: Int = 0,
        pageExists: @escaping (String) -> Bool = { _ in true },
        pageArchived: @escaping (String) -> Bool = { _ in false },
        linkLabel: @escaping (String) -> String? = { _ in nil },
        linkIcon: @escaping (String) -> String? = { _ in nil },
        blockView: @escaping (EditorBlock) -> AnyView? = { _ in nil },
        linkPreview: @escaping (EditorLink) -> AnyView? = { _ in nil },
        webTitle: ((String) -> String?)? = nil,
        lead: EditorLead? = nil, onLead: @escaping () -> Void = {}, prose: Bool = false,
        offers: @escaping (BodyCompletion) -> [EditorOffer] = { _ in [] },
        offersTitle: Bool = false, onTitle: @escaping () -> Void = {},
        foldedRows: [EditorFoldedRow]? = nil, onFolds: @escaping ([EditorFoldedRow]) -> Void = { _ in },
        onMoveRows: ((_ markdown: String, _ moved: @escaping () -> Void) -> Void)? = nil,
        savePictures: @escaping ([EditorPastedPicture]) -> [String] = { _ in [] },
        onZoom: ((_ row: String, _ apart: Bool) -> Void)? = nil, onZoomOut: (() -> Void)? = nil,
        marks: [NSRange] = [], markAt: Int? = nil, caretAt: Int? = nil, onCaretTaken: @escaping () -> Void = {},
        onChange: @escaping () -> Void = {}, onFocus: @escaping (Bool) -> Void = { _ in }, onFollow: @escaping (EditorLink) -> Void = { _ in }
    ) {
        self.editor = editor
        self.theme = theme
        self.isWriting = isWriting
        _height = height
        self.refresh = refresh
        self.pageExists = pageExists
        self.pageArchived = pageArchived
        self.linkLabel = linkLabel
        self.linkIcon = linkIcon
        self.blockView = blockView
        self.linkPreview = linkPreview
        self.webTitle = webTitle
        self.lead = lead
        self.prose = prose
        self.onLead = onLead
        self.offers = offers
        self.offersTitle = offersTitle
        self.onTitle = onTitle
        self.foldedRows = foldedRows
        self.onFolds = onFolds
        self.onZoom = onZoom
        self.marks = marks
        self.markAt = markAt
        self.caretAt = caretAt
        self.onCaretTaken = onCaretTaken
        self.onZoomOut = onZoomOut
        self.onMoveRows = onMoveRows
        self.savePictures = savePictures
        self.onChange = onChange
        self.onFocus = onFocus
        self.onFollow = onFollow
    }

    /// Whether a note opens with a plain bulleted line — one with no
    /// number and no box — which is the line a lead can stand at the head
    /// of. An app shows its ring or icon elsewhere when it does not.
    public static func takesLead(_ editor: NoteEditor) -> Bool {
        guard let first = editor.layout().lines.first, case .item(let number, let done, _) = first.kind else { return false }
        return number == nil && done == nil && first.depth <= 1
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NoteTextView {
        let view = NoteTextView.make()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        context.coordinator.view = view
        view.enlist()
        _ = context.coordinator.takeFolds(anew: true)
        context.coordinator.load()
        context.coordinator.showMarks(goingTo: false)
        return view
    }

    public func updateNSView(_ view: NoteTextView, context: Context) {
        let coordinator = context.coordinator
        let other = coordinator.parent.editor !== editor
        let marked = coordinator.parent.marks != marks || coordinator.parent.markAt != markAt
        let folds = other || coordinator.parent.foldedRows != foldedRows
        let looks = coordinator.parent.refresh != refresh || coordinator.parent.theme.size != theme.size || coordinator.parent.theme.face != theme.face || coordinator.parent.lead != lead
        coordinator.parent = self
        defer { if marked || other { coordinator.showMarks(goingTo: coordinator.parent.markAt != nil && marked) } }
        let refolded = folds && coordinator.takeFolds(anew: other)
        if other || refolded || coordinator.shown != editor.text() {
            // …or the note was changed from outside the view: a link given its title, say.
            coordinator.load()
        } else if looks {
            coordinator.restyle()
        }
        if let caretAt { coordinator.go(to: caretAt) }
        if isWriting, view.window?.firstResponder !== view {
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window, window.firstResponder !== view else { return }
                window.makeFirstResponder(view)
            }
        } else if !isWriting, view.window?.firstResponder === view {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window?.firstResponder === view else { return }
                view.window?.makeFirstResponder(nil)
            }
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NoteTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

// What the text view tells the coordinator, and the Mac's way of listing
// what is offered; the work itself is in NoteEditorCoordinator.swift.
extension NoteEditorView.Coordinator: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        typed()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        selectionChanged()
    }

    func showOffers() {
        guard let offering, let view, let window = view.window else { return }
        let caret = view.firstRect(forCharacterRange: NSRange(location: Int(offering.found.start), length: 0), actualRange: nil)
        let content = AnyView(OfferListView(offers: offering.offers, chosen: offering.chosen) { [weak self] index in
            self?.acceptOffer(at: index)
        })
        if let offerList { offerList.show(content, under: caret) } else { offerList = OfferList(content: content, under: caret, over: window) }
    }

    func closeOffers() {
        offerList?.close()
        offerList = nil
    }
}

/// One of the app's own views, standing in the text in place of a block.
@MainActor
final class BlockHost {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    init(in view: NoteTextView) {
        view.addSubview(host)
    }

    /// Shows this, at a width. Says how tall it is.
    func show(_ content: AnyView, width: CGFloat) -> CGFloat {
        host.rootView = content
        let height = host.fittingSize.height
        host.setFrameSize(CGSize(width: width, height: height))
        return height
    }

    func move(to origin: CGPoint) {
        host.setFrameOrigin(origin)
    }

    var bottom: CGFloat { host.frame.maxY }

    func remove() {
        host.removeFromSuperview()
    }
}

/// What the coordinator asks of the text view, under the names every
/// platform's answers to.
extension NoteTextView {
    var noteStorage: NSTextStorage? { textStorage }
    var noteLayout: NSLayoutManager? { layoutManager }
    var noteContainer: NSTextContainer? { textContainer }
    var caret: NSRange {
        get { selectedRange() }
        set { setSelectedRange(newValue) }
    }
    /// Whether the caret is here.
    var isWriting: Bool { window?.firstResponder === self }
    /// Whether something is being composed: marked text, not yet the note's.
    var isComposing: Bool { hasMarkedText() }
    var shownText: String { string }
    var containerOrigin: CGPoint { textContainerOrigin }
    var sideInset: CGFloat { textContainerInset.width }
    func redraw() { needsDisplay = true }
}

/// A card that floats by the pointer while it rests on a link: a small
/// window of its own, so that it lies over whatever is there, takes no
/// clicks and no keys, and is gone the moment the pointer moves on.
@MainActor
extension NoteEditorView {
    /// Posted by what an app shows in a link's card, when what it offered
    /// was done: the card goes.
    public static let hoverCardDone = Notification.Name("prism.editor.hoverCardDone")
}

final class HoverCard {
    private let panel: NSPanel
    private weak var parent: NSWindow?
    /// Where the pointer was, on the screen.
    private let pointer: CGPoint
    /// Whether the pointer is on the card: it stays while it is.
    private(set) var isPointed = false
    /// The pointer left the card.
    var onLeave: () -> Void = {}

    init(content: AnyView, at pointer: CGPoint, over parent: NSWindow) {
        self.pointer = pointer
        self.parent = parent
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        // The card sizes the panel itself, after its content has been laid out: a panel the
        // hosting view sized (`.preferredContentSize`) relaid the content while resizing the
        // window, which resized it again — without end, until the stack ran out.
        host.sizingOptions = []
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The pointer may come onto it: what it offers can be clicked.
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        host.rootView = AnyView(
            content.background(.regularMaterial).clipShape(shape).overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
                // As large as it would be, whatever the panel is now — it may grow, as a page's picture comes in.
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    // Not within this layout: the next turn of the run loop.
                    DispatchQueue.main.async { self?.resize(to: size) }
                }
                .onHover { [weak self] inside in
                    guard let self else { return }
                    self.isPointed = inside
                    if !inside { self.onLeave() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        resize(to: host.fittingSize)
        parent.addChildWindow(panel, ordered: .above)
    }

    private func resize(to size: CGSize) {
        let size = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard size.width > 0, size.height > 0 else { return }
        if panel.frame.size != size { panel.setContentSize(size) }
        place()
    }

/// Under the pointer and a little to its right — near enough to
    /// reach without leaving it far behind; over it, where there is no
    /// room under; and never off the screen's edge.
    private func place() {
        let size = panel.frame.size
        let screen = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame ?? CGRect(origin: .zero, size: size)
        var origin = CGPoint(x: pointer.x + 6, y: pointer.y - 12 - size.height)
        if origin.y < screen.minY + 6 { origin.y = pointer.y + 12 }
        origin.x = min(max(origin.x, screen.minX + 6), max(screen.maxX - size.width - 6, screen.minX + 6))
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    func close() {
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// The pages offered for a link being typed, one a row.
struct OfferListView: View {
    let offers: [EditorOffer]
    let chosen: Int
    var pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(offers.enumerated()), id: \.offset) { index, offer in
                HStack(spacing: 10) {
                    Image(systemName: offer.symbol).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(offer.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        if let detail = offer.detail, !detail.isEmpty {
                            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(index == chosen ? 0.09 : 0)))
                .contentShape(Rectangle())
                .onTapGesture { pick(index) }
            }
        }
        .padding(6)
        .frame(width: 400, alignment: .leading)
    }
}

/// The list of pages offered, floating under the caret: a window of its
/// own, which takes clicks and no keys — those stay the note's.
@MainActor
final class OfferList {
    private let panel: NSPanel
    private let host: NSHostingController<AnyView>
    private weak var parent: NSWindow?

    init(content: AnyView, under caret: CGRect, over parent: NSWindow) {
        self.parent = parent
        host = NSHostingController(rootView: Self.dressed(content))
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        place(under: caret)
        parent.addChildWindow(panel, ordered: .above)
    }

    private static func dressed(_ content: AnyView) -> AnyView {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return AnyView(content.background(.regularMaterial).clipShape(shape).overlay(shape.strokeBorder(.separator, lineWidth: 0.5)))
    }

    func show(_ content: AnyView, under caret: CGRect) {
        host.rootView = Self.dressed(content)
        place(under: caret)
    }

    /// Under the caret's line; over it, where there is no room under.
    private func place(under caret: CGRect) {
        let size = host.view.fittingSize
        let screen = (NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main)?.visibleFrame ?? CGRect(origin: .zero, size: size)
        var origin = CGPoint(x: caret.minX - 14, y: caret.minY - 6 - size.height)
        if origin.y < screen.minY + 6 { origin.y = caret.maxY + 6 }
        origin.x = min(max(origin.x, screen.minX + 6), max(screen.maxX - size.width - 6, screen.minX + 6))
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    func close() {
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// The text view: TextKit 1, so that the layout manager can draw.
public final class NoteTextView: NSTextView {
    /// The view showing a note, among those on screen: for what is done to a
    /// note from outside it — words said into one just made.
    public static func showing(_ editor: NoteEditor) -> NoteTextView? {
        live.allObjects.first { $0.window != nil && $0.coordinator?.parent.editor === editor }
    }

    private static let live = NSHashTable<NoteTextView>.weakObjects()

    /// Told once the view is the coordinator's: it is on screen from then.
    func enlist() { Self.live.add(self) }

    weak var coordinator: NoteEditorView.Coordinator?
    /// How far down the app's own block views reach.
    var blocksBottom: CGFloat = 0
    private var pressed: (point: CGPoint, link: EditorLink?, task: Int?)?
    /// The little window asking where a link should lead, and the words it is for.
    private var linkPrompt: NSPopover?
    private var linkRange = NSRange(location: 0, length: 0)

    // MARK: "Title", at the first line's end

    private var titleChip: NSButton?

    func showTitleChip(after point: CGPoint) {
        let chip = titleChip ?? {
            // Quiet: a word at the line's end, not a button asking.
            let chip = NSButton(title: "Title", target: self, action: #selector(titleChipClicked(_:)))
            chip.isBordered = false
            chip.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            chip.imagePosition = .imageLeading
            chip.imageHugsTitle = true
            chip.contentTintColor = .tertiaryLabelColor
            chip.attributedTitle = NSAttributedString(string: "Title", attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor])
            chip.toolTip = "Make this line the title (⌃⇧T)"
            chip.setAccessibilityLabel("Make this line the title")
            chip.refusesFirstResponder = true
            chip.sizeToFit()
            addSubview(chip)
            titleChip = chip
            return chip
        }()
        let size = chip.fittingSize
        var x = point.x
        if x + size.width > bounds.width { x = max(0, bounds.width - size.width) }
        let frame = CGRect(x: x.rounded(), y: (point.y - size.height / 2).rounded(), width: size.width, height: size.height)
        if chip.frame != frame { chip.frame = frame }
        if chip.isHidden { chip.isHidden = false }
    }

    func hideTitleChip() {
        if titleChip?.isHidden == false { titleChip?.isHidden = true }
    }

    @objc private func titleChipClicked(_ sender: Any?) {
        coordinator?.parent.onTitle()
    }

    // MARK: A link's card, while the pointer rests on it

    private var hovered: EditorLink?
    private var hoverWork: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var card: HoverCard?
    private var tracking: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// What the pointer is over, as far as its shape goes.
    private enum Under { case text, link, box, block, elsewhere }
    private var under: Under = .text

    /// Says what the pointer is over. The text view is told of every move
    /// across its frame — also of those over what lies on top of it, a
    /// card's buttons, and over the app's own views inside it, a picture
    /// or a query's results — and none of those is text.
    private func whatIsUnder(_ event: NSEvent) -> Under {
        guard let window, let content = window.contentView else { return .elsewhere }
        let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        guard let hit else { return .elsewhere }
        if hit !== self { return hit.isDescendant(of: self) ? .block : .elsewhere }
        guard let manager = layoutManager as? BodyLayoutManager, let container = textContainer else { return .text }
        let point = containerPoint(event)
        if manager.isLead(at: point) || manager.task(at: point, in: container) != nil || manager.foldPill(at: point) != nil || manager.mark(at: point) != nil { return .box }
        // Rows chosen are taken hold of, not written in: an arrow.
        if let chosen = rowsChosen, let row = manager.row(at: point, in: container), (min(chosen.anchor, chosen.head)...max(chosen.anchor, chosen.head)).contains(row) { return .box }
        return manager.link(at: point, in: container) != nil ? .link : .text
    }

    /// Sets the pointer's shape for what it is over: an I-beam over
    /// words, a hand over a link, an arrow over a box to tick and over
    /// anything that is not the text's. Says whether the text is under it.
    @discardableResult
    private func point(_ event: NSEvent) -> Bool {
        let now = whatIsUnder(event)
        defer { under = now }
        switch now {
        case .text:
            NSCursor.iBeam.set()
            return true
        case .link:
            NSCursor.pointingHand.set()
        case .box:
            NSCursor.arrow.set()
        case .block:
            // Theirs to shape from here on; an arrow as the pointer leaves the words.
            if under != now { NSCursor.arrow.set() }
        case .elsewhere:
            // Over what lies on the text — a card's buttons: an arrow, each time,
            // whatever the text view's own tracking would make of it.
            NSCursor.arrow.set()
        }
        return false
    }

    public override func cursorUpdate(with event: NSEvent) {
        if point(event) { super.cursorUpdate(with: event) }
    }

    public override func mouseMoved(with event: NSEvent) {
        // Only over its words is the pointer the text view's to make an I-beam.
        if point(event) { super.mouseMoved(with: event) }
        guard under == .text || under == .link, let manager = layoutManager as? BodyLayoutManager, let container = textContainer else {
            hovered = nil
            hideCardSoon()
            return
        }
        let point = containerPoint(event)
        let link = manager.link(at: point, in: container)
        guard link != hovered else { return }
        hovered = link
        // Off the link: its card waits a moment, for the pointer may be on its way to it.
        guard let link else { return hideCardSoon() }
        hideCard()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovered == link, let window = self.window, let content = self.coordinator?.parent.linkPreview(link) else { return }
            // By the pointer, where it has come to rest.
            let card = HoverCard(content: content, at: NSEvent.mouseLocation, over: window)
            card.onLeave = { [weak self] in self?.hideCardSoon() }
            self.card = card
        }
        hoverWork = work
        // Long enough that passing over a link shows nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Off the words: the pointer is no longer theirs to shape.
        if under == .text || under == .link { NSCursor.arrow.set() }
        under = .elsewhere
        hovered = nil
        // Onto the card, perhaps: it is over the text, and a window of its own.
        hideCardSoon()
    }

    public override func scrollWheel(with event: NSEvent) {
        hovered = nil
        hideCard()
        coordinator?.hideOffers()
        super.scrollWheel(with: event)
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self, name: NoteEditorView.hoverCardDone, object: nil)
        if newWindow != nil { NotificationCenter.default.addObserver(self, selector: #selector(cardDone(_:)), name: NoteEditorView.hoverCardDone, object: nil) }
        if newWindow == nil { hideCard() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func hideCard() {
        hoverWork?.cancel()
        hoverWork = nil
        leaveWork?.cancel()
        leaveWork = nil
        card?.close()
        card = nil
    }

    /// Hides the card unless, a moment on, the pointer is on it — or back on its link.
    private func hideCardSoon() {
        guard card != nil else { return hideCard() }
        leaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let card = self.card else { return }
            if !card.isPointed, self.hovered == nil { self.hideCard() }
        }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// What a card did is done: it goes. For what an app's card offers.
    @objc private func cardDone(_ note: Notification) {
        hovered = nil
        hideCard()
    }

    static func make() -> NoteTextView {
        let storage = NSTextStorage()
        let manager = BodyLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let view = NoteTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 20), textContainer: container)
        view.drawsBackground = false
        view.isRichText = false
        // Undo is the note's own: it puts structure back, which text alone cannot.
        view.allowsUndo = false
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        // Pictures taken when dropped, besides what a text view takes.
        view.registerForDraggedTypes(view.acceptableDragTypes)
        return view
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let coordinator, coordinator.hasBlocks, abs(newSize.width - coordinator.blocksPlacedFor) > 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let coordinator = self.coordinator, abs(self.bounds.width - coordinator.blocksPlacedFor) > 0.5 else { return }
            coordinator.restyle()
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let manager = layoutManager else { return 20 }
        if abs(container.size.width - width) > 0.5 {
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
        var used = manager.usedRect(for: container).height
        // An empty last line is the caret's to wait on.
        // …while it is written in: read, a last line put away takes no room — though what is
        // used counts it.
        if isWriting {
            used = max(used, manager.extraLineFragmentRect.maxY)
        } else if manager.extraLineFragmentRect.height > 0 {
            used = min(used, manager.extraLineFragmentRect.minY)
        }
        let size = (manager as? BodyLayoutManager)?.theme.size ?? 14
        return max((used + textContainerInset.height * 2).rounded(.up), (size * 1.5).rounded(.up), (blocksBottom + textContainerInset.height).rounded(.up))
    }

    private func containerPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    }

    public override func mouseDown(with event: NSEvent) {
        hovered = nil
        hideCard()
        rowPress = nil
        guard let manager = layoutManager as? BodyLayoutManager, let container = textContainer else {
            leaveRows()
            return super.mouseDown(with: event)
        }
        let point = containerPoint(event)
        // On rows chosen: they are taken hold of, to carry — or, let go where they are, let be.
        if let chosen = rowsChosen, let row = manager.row(at: point, in: container), (min(chosen.anchor, chosen.head)...max(chosen.anchor, chosen.head)).contains(row) {
            rowPress = (row, point, true)
            return
        }
        leaveRows()
        if manager.isLead(at: point) {
            coordinator?.parent.onLead()
            return
        }
        // A row's bullet: clicked, it folds the row or unfolds it; dragged, it carries the row.
        if let row = manager.mark(at: point) {
            rowPress = (row, point, false)
            return
        }
        // A folded row's pill: unfolded.
        if let row = manager.foldPill(at: point) {
            coordinator?.perform(.unfold, onRows: [row])
            return
        }
        let task = manager.task(at: point, in: container)
        let link = task == nil ? manager.link(at: point, in: container) : nil
        if task != nil || link != nil {
            // Followed on the way up, if the pointer has not gone anywhere.
            pressed = (point, link, task)
            return
        }
        pressed = nil
        super.mouseDown(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if let press = rowPress {
            rowPress = nil
            if press.chosen {
                leaveRows()
            } else if event.modifierFlags.contains(.option), outlineLines.indices.contains(press.row) {
                // ⌥-click: the row and everything under it, folded or shown — as Bike's handle.
                _ = coordinator?.perform(outlineLines[press.row].isFolded ? .unfoldCompletely : .foldCompletely, onRows: [press.row])
            } else {
                coordinator?.perform(.toggleFold, onRows: [press.row])
            }
            return
        }
        guard let pressed else { return super.mouseUp(with: event) }
        self.pressed = nil
        let point = containerPoint(event)
        guard hypot(point.x - pressed.point.x, point.y - pressed.point.y) < 4 else { return }
        if let task = pressed.task {
            coordinator?.perform(.toggleCheckbox, at: task)
        } else if let link = pressed.link {
            // A link on the web is asked about; with ⌘ held, opened.
            if case .web(let address) = link, !event.modifierFlags.contains(.command), coordinator?.parent.webTitle != nil, editLink(address, at: pressed.point) { return }
            coordinator?.parent.onFollow(link)
        }
    }

    // MARK: Words said into the note

    /// Whether the caret is put away: while words are said, a bar of light stands for it.
    var hidesCaret = false {
        didSet {
            guard hidesCaret != oldValue else { return }
            insertionPointColor = hidesCaret ? .clear : (coordinator?.parent.theme.accent ?? .controlAccentColor)
            needsDisplay = true
        }
    }

    var dictationAccent: NSColor { coordinator?.parent.theme.accent ?? .controlAccentColor }

    /// Where a caret before a character would stand, in the view: as tall as the words.
    func caretBar(at location: Int) -> CGRect? {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage, location <= storage.length else { return nil }
        let font = (location > 0 ? storage.attribute(.font, at: min(location, storage.length) - 1, effectiveRange: nil) as? NSFont : nil) ?? coordinator?.parent.theme.body ?? .systemFont(ofSize: 14)
        let tall = (font.ascender - font.descender).rounded(.up) + 2
        let origin = textContainerOrigin
        if storage.length == 0 || location == storage.length, manager.extraLineFragmentRect.height > 0 {
            let rect = manager.extraLineFragmentRect
            return CGRect(x: rect.minX + origin.x + container.lineFragmentPadding, y: rect.minY + origin.y, width: 2, height: min(rect.height, tall))
        }
        guard storage.length > 0 else { return CGRect(x: origin.x, y: origin.y, width: 2, height: tall) }
        // After the last character of a line, or before any other.
        let after = location == storage.length
        let glyph = manager.glyphIndexForCharacter(at: after ? location - 1 : location)
        let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        var x = manager.location(forGlyphAt: glyph).x
        if after { x += manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).width }
        return CGRect(x: fragment.minX + x + origin.x, y: fragment.minY + origin.y, width: 2, height: min(fragment.height, tall))
    }

    /// Writes words in place of some of the note's, as if typed: what is said, as it is heard.
    func write(_ words: String, in range: NSRange) {
        insertText(words, replacementRange: range)
    }

    /// ⌃⌥Space, held: what is said is written at the caret for as long as it is held.
    private var holdsToTalk = false

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // ⌃W, ⌃S: the word, the sentence.
        if flags == [.control], !outlineLines.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(), key == "w" || key == "s" {
            leaveRows()
            return key == "w" ? selectWord() : selectSentence()
        }
        // Bike's keys with ⌃⌥ and no ⌘ — the row alone, promote and demote — are no menu's: taken here.
        if !flags.contains(.command), flags.isSuperset(of: [.control, .option]), !outlineLines.isEmpty,
           let command = Self.command(flags: flags, key: event.charactersIgnoringModifiers?.lowercased() ?? "", special: event.specialKey) {
            if !perform(keyed: command) { NSSound.beep() }
            return
        }
        if event.keyCode == 49, flags == [.control, .option] {
            if !event.isARepeat, !holdsToTalk {
                holdsToTalk = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Let go before it could start: nothing.
                    if await NoteDictation.start(in: self), !self.holdsToTalk { await NoteDictation.stop() }
                }
            }
            return
        }
        super.keyDown(with: event)
    }

    public override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, holdsToTalk { return letGoOfTalk() }
        super.keyUp(with: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        // ⌃ or ⌥ let go first: let go all the same.
        if holdsToTalk, !event.modifierFlags.contains([.control, .option]) { letGoOfTalk() }
        super.flagsChanged(with: event)
    }

    private func letGoOfTalk() {
        holdsToTalk = false
        guard NoteDictation.isGoing(in: self) else { return }
        Task { @MainActor in await NoteDictation.stop() }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (layoutManager as? BodyLayoutManager)?.drawEmptyRow(at: textContainerOrigin)
        if let tail, showsCaret {
            indicator.color.setFill()
            NSBezierPath(rect: tail).fill()
        }
    }

    // MARK: The caret
    //
    // The system's own caret, as a text view of TextKit 2 has it — thicker,
    // in the accent, fading as it blinks — where this view's would be. The
    // text view still says where (`drawInsertionPoint`), and when there is
    // one at all (`updateInsertionPointStateAndRestartTimer`); it draws
    // nothing of its own.

    private lazy var indicator: NSTextInsertionIndicator = {
        let indicator = NSTextInsertionIndicator(frame: .zero)
        indicator.displayMode = .hidden
        addSubview(indicator)
        return indicator
    }()

    /// Where, beside the caret, a tail says which side's formatting what is typed joins.
    private var tail: NSRect?

    /// Whether there is a caret to show: the view writing in a window that is
    /// being written in, nothing selected, and the caret not put away.
    private var showsCaret: Bool {
        guard let window, window.isKeyWindow, window.firstResponder === self, isEditable else { return false }
        return selectedRange().length == 0 && (insertionPointColor?.alphaComponent ?? 0) > 0
    }

    private func showCaret() {
        let shown = showsCaret
        indicator.color = insertionPointColor.flatMap { $0.alphaComponent > 0 ? $0 : nil } ?? dictationAccent
        indicator.displayMode = shown ? .automatic : .hidden
        if !shown, let old = tail {
            tail = nil
            setNeedsDisplay(old)
        }
    }

    public override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        showCaret()
    }

    public override var insertionPointColor: NSColor? {
        didSet { if window != nil { showCaret() } }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: window)
        }
    }

    @objc private func keyChanged() { showCaret() }

    /// The caret is as tall as the words it stands among, and no taller:
    /// a line's box also holds the room left under it before the next,
    /// which a caret drawn the whole box's height would hang down into.
    public override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var rect = rect
        let font = (typingAttributes[.font] as? NSFont) ?? coordinator?.parent.theme.body ?? .systemFont(ofSize: NSFont.systemFontSize)
        let tall = (font.ascender - font.descender).rounded(.up) + 2
        if rect.height > tall { rect.size.height = tall }
        // The system's caret stands where this one would have, centred on its line.
        let width = max(indicator.intrinsicContentSize.width, 2)
        let frame = NSRect(x: (rect.minX + rect.width / 2 - width / 2).rounded(), y: rect.minY, width: width, height: rect.height)
        if indicator.frame != frame { indicator.frame = frame }
        showCaret()
        // At an edge of formatting, a tail toward the words what is typed joins — Bike's typing affinity.
        // Drawn steady, under the system's caret, which blinks on its own.
        let at = selectedRange().location
        var wanted: NSRect?
        if showsCaret, isMarkup(at - 1) != isMarkup(at) {
            let joinsAfter = isMarkup(at - 1)
            wanted = NSRect(x: joinsAfter ? frame.maxX : frame.minX - 3, y: frame.maxY - 2, width: 3, height: 2)
        }
        if wanted != tail {
            if let old = tail { setNeedsDisplay(old) }
            tail = wanted
            if let wanted { setNeedsDisplay(wanted) }
        }
    }

    public override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        // What a taller caret left behind is cleared with it.
        super.setNeedsDisplay(rect.insetBy(dx: -4, dy: -4), avoidAdditionalLayout: flag)
    }

    // MARK: Rows carried by the pointer
    //
    // A row is taken by its bullet — or its box, or, chosen with others
    // (Esc), anywhere on them — and carried: within the note, to another
    // place and depth in it; or to another note, any card showing an
    // outline. A line shows where it would go. Carried anywhere else — a
    // note shown as text, another app — it is its Markdown.

    /// What says rows are being carried, on the pasteboard, beside their Markdown.
    static let rowsType = NSPasteboard.PasteboardType("org.mutable.prism.rows")
    /// The rows being carried, and the view they are carried from.
    private static var carried: (rows: [Int], markdown: String)?
    private static weak var carriedFrom: NoteTextView?
    /// A press on a bullet, or on rows chosen: a click or a carry, by what comes next.
    private var rowPress: (row: Int, point: CGPoint, chosen: Bool)?

    public override func mouseDragged(with event: NSEvent) {
        let point = containerPoint(event)
        var row = rowPress?.row
        var from = rowPress?.point
        // A task is carried by its box, as a bullet's row by its bullet.
        if row == nil, let pressed, let task = pressed.task, let manager = layoutManager as? BodyLayoutManager {
            row = manager.lines.firstIndex { Int($0.start) == task }
            from = pressed.point
        }
        guard let row, let from else { return super.mouseDragged(with: event) }
        guard hypot(point.x - from.x, point.y - from.y) >= 4 else { return }
        rowPress = nil
        pressed = nil
        carry(row: row, with: event)
    }

    private func carry(row: Int, with event: NSEvent) {
        guard let coordinator, let manager = layoutManager as? BodyLayoutManager else { return }
        var rows = [row]
        if let chosen = rowsChosen, (min(chosen.anchor, chosen.head)...max(chosen.anchor, chosen.head)).contains(row) {
            rows = Array(min(chosen.anchor, chosen.head)...max(chosen.anchor, chosen.head))
        }
        let markdown = coordinator.editor.markdownOf(rows: rows.map { UInt32($0) })
        guard !markdown.isEmpty else { return }
        let item = NSPasteboardItem()
        item.setString(markdown, forType: .string)
        item.setString("rows", forType: Self.rowsType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        // What is carried is shown as it stands: the rows, and what is under the last of them.
        var rect = rows.reduce(CGRect.null) { $0.union(manager.rect(ofRow: $1)) }
        rect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).intersection(bounds)
        guard !rect.isEmpty else { return }
        let image = NSImage(size: rect.size)
        if let picture = bitmapImageRepForCachingDisplay(in: rect) {
            cacheDisplay(in: rect, to: picture)
            image.addRepresentation(picture)
        }
        dragging.setDraggingFrame(rect, contents: image)
        Self.carried = (rows, markdown)
        Self.carriedFrom = self
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    public override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.carriedFrom === self ? [.move, .copy] : super.draggingSession(session, sourceOperationMaskFor: context)
    }

    public override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if Self.carriedFrom === self {
            Self.carried = nil
            Self.carriedFrom = nil
            return
        }
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
    }

    /// Where rows carried over this note would be put down: before which
    /// row, how deep, and where the line that says so is drawn. Nothing,
    /// when none are carried.
    private func rowsDrop(_ sender: any NSDraggingInfo) -> (before: Int, depth: Int, y: CGFloat, x: CGFloat)? {
        guard sender.draggingPasteboard.availableType(from: [Self.rowsType]) != nil, let carried = Self.carried, let coordinator,
              let manager = layoutManager as? BodyLayoutManager else { return nil }
        let place = convert(sender.draggingLocation, from: nil)
        let point = CGPoint(x: place.x - textContainerOrigin.x, y: place.y - textContainerOrigin.y)
        let lines = manager.lines
        let step = max(manager.theme.step, 1)
        // Before the first row whose middle is under the pointer; after the last, past them all.
        let before = lines.indices.first { point.y < manager.rect(ofRow: $0).midY } ?? lines.count
        // As deep as the rows it comes between — or as the pointer says, by the column it is over:
        // further out, or one step in under the row above.
        let depthOf = { (index: Int) in lines.indices.contains(index) ? max(Int(lines[index].depth) - 1, 0) : 0 }
        let (above, beside) = (depthOf(before - 1), before < lines.count ? depthOf(before) : depthOf(before - 1))
        let column = max(Int(point.x / step), 0)
        var depth = column <= beside || (before > 0 && column == above + 1) ? column : beside
        let own = Self.carriedFrom === self
        if lines.isEmpty { depth = 0 } else {
            guard let held = coordinator.editor.dropDepth(rows: own ? carried.rows.map { UInt32($0) } : [], before: UInt32(before), depth: UInt32(depth)) else { return nil }
            depth = Int(held)
        }
        let y = before < lines.count ? manager.rect(ofRow: before).minY : (lines.isEmpty ? 0 : manager.rect(ofRow: lines.count - 1).maxY)
        return (before, depth, y, CGFloat(depth) * step)
    }

    private func showDrop(_ sender: any NSDraggingInfo) -> Bool {
        guard let manager = layoutManager as? BodyLayoutManager else { return false }
        let drop = rowsDrop(sender)
        manager.dropLine = drop.map { ($0.y, $0.x) }
        needsDisplay = true
        return drop != nil
    }

    private var carriesRows: Bool { Self.carried != nil }

    /// Rows carried are moved — or, with ⌥ held, copied: as the Finder does.
    private func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard carriesRows, coordinator != nil else { return super.draggingEntered(sender) }
        return showDrop(sender) ? operation(sender) : []
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard carriesRows, coordinator != nil else { return super.draggingUpdated(sender) }
        return showDrop(sender) ? operation(sender) : []
    }

    public override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // Rows are this view's to take, whatever the text system makes of what is carried.
        if carriesRows, coordinator != nil { return rowsDrop(sender) != nil }
        return super.prepareForDragOperation(sender)
    }

    public override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        if carriesRows { return }
        super.concludeDragOperation(sender)
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        (layoutManager as? BodyLayoutManager)?.dropLine = nil
        needsDisplay = true
        if !carriesRows { super.draggingExited(sender) }
    }

    public override func draggingEnded(_ sender: any NSDraggingInfo) {
        (layoutManager as? BodyLayoutManager)?.dropLine = nil
        needsDisplay = true
        super.draggingEnded(sender)
    }

    /// Puts rows carried down where the line was. From another note, they
    /// are written here and then taken out there; within this one, moved.
    private func drop(rows sender: any NSDraggingInfo) -> Bool? {
        guard carriesRows, coordinator != nil else { return nil }
        guard let drop = rowsDrop(sender), let carried = Self.carried else { return false }
        (layoutManager as? BodyLayoutManager)?.dropLine = nil
        needsDisplay = true
        return put(rows: carried.rows, of: Self.carriedFrom, before: drop.before, depth: drop.depth, copying: operation(sender) == .copy)
    }

    /// Puts rows of a note's — this one's, or another's — before a row
    /// here, at a depth: what letting go of rows carried does. Says
    /// whether they were put.
    @discardableResult
    public func put(rows: [Int], of source: NoteTextView?, before: Int, depth: Int, copying: Bool = false) -> Bool {
        guard let coordinator, let source, let from = source.coordinator, !rows.isEmpty else { return false }
        if source === self, !copying {
            leaveRows()
            return coordinator.moveRows(rows, before: before, depth: depth)
        }
        let markdown = from.editor.markdownOf(rows: rows.map { UInt32($0) })
        guard !markdown.isEmpty, coordinator.insertRows(markdown, before: before, depth: depth) else { return false }
        // Copied: where they came from, they stay.
        if copying { return true }
        // Taken out where they came from, once this note has them — and only if they
        // are still what was carried: a card of the same note is by then another's.
        DispatchQueue.main.async { [weak source] in
            guard let from = source?.coordinator, from.editor.markdownOf(rows: rows.map { UInt32($0) }) == markdown else { return }
            source?.leaveRows()
            from.perform(.deleteRows, onRows: rows)
        }
        window?.makeFirstResponder(self)
        return true
    }

    /// The pointer's shape is set as it moves (see `point`), from what is
    /// truly under it. Rectangles of the text view's own would know
    /// nothing of what lies over it, and make an I-beam of a card's buttons.
    public override func resetCursorRects() {}

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { DispatchQueue.main.async { [weak self] in self?.coordinator?.focusChanged(true) } }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            leaveRows()
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            DispatchQueue.main.async { [weak self] in self?.coordinator?.focusChanged(false) }
        }
        return resigned
    }

    // What the keys do is the note's; what it has no part in is the text view's own.

    // While pages are offered for a link being typed, the keys that
    // choose among them are the list's.

    // MARK: Rows chosen
    //
    // Esc, in an outline, chooses the row the caret is in: the whole row,
    // marked across the note's width. ↑ and ↓ then choose the row above
    // or below — with ⇧, more of them — and what is done is done to the
    // rows: Tab and ⇧Tab set them in and out, ⌫ deletes them, ⌃⌘↑ and
    // ⌃⌘↓ carry them, ⌘C copies them as Markdown. Return, a click, or
    // anything typed goes back to writing; Esc again leaves the note.

    /// The rows chosen, from the one first chosen to the one gone to
    /// since: lines of the outline, counted from the first. Nothing,
    /// while the note is written in.
    private var rowsChosen: (anchor: Int, head: Int)?
    /// Where the caret was when rows came to be chosen: where Esc goes back to.
    private var caretBeforeRows: Int?
    /// What Expand Selection went through, the last on top: what Contract Selection goes back to.
    private var expansions: [Chosen] = []

    /// A selection, as Expand Selection steps through them: words, or rows.
    enum Chosen: Equatable {
        case words(NSRange)
        case rows(Int, Int)
    }
    var isChoosingRows: Bool { rowsChosen != nil }

    private var outlineLines: [BodyLine] {
        coordinator?.layout.lines ?? []
    }

    /// Right-clicked: the text's own menu, and — on a link alone on its
    /// row — showing it as its card, or as its words again.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        let at = characterIndexForInsertion(at: point)
        guard let row = row(at: at), let isCard = coordinator?.linkRowIsCard(row) else { return menu }
        let item = NSMenuItem(title: isCard ? "Show as Link" : "Show as Card", action: #selector(toggleCardFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.tag = row
        item.image = NSImage(systemSymbolName: isCard ? "link" : "rectangle.on.rectangle", accessibilityDescription: nil)
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func toggleCardFromMenu(_ item: NSMenuItem) {
        coordinator?.toggleCard(row: item.tag)
    }

    private func row(at location: Int) -> Int? {
        let lines = outlineLines
        return lines.lastIndex { Int($0.start) <= location } ?? (lines.isEmpty ? nil : 0)
    }

    /// Chooses rows: the text they cover is what is selected, so that
    /// what is done to a selection is done to them.
    private func chooseRows(anchor: Int, head: Int) {
        let lines = outlineLines
        guard !lines.isEmpty else { return leaveRows() }
        let (anchor, head) = (min(max(anchor, 0), lines.count - 1), min(max(head, 0), lines.count - 1))
        rowsChosen = (anchor, head)
        let (first, last) = (lines[min(anchor, head)], lines[max(anchor, head)])
        setSelectedRange(NSRange(location: Int(first.start), length: Int(last.end) - Int(first.start)))
        // The rows are marked whole; the words in them are not marked again, and there is no caret.
        selectedTextAttributes = [:]
        insertionPointColor = .clear
        (layoutManager as? BodyLayoutManager)?.chosen = Int(first.start)...Int(last.end)
        scrollRangeToVisible(NSRange(location: Int(lines[head].start), length: 0))
        needsDisplay = true
    }

    /// The rows the selection covers now, chosen: after something was done to them.
    private func chooseSelectedRows() {
        let selection = selectedRange()
        guard rowsChosen != nil, let first = row(at: selection.location), let last = row(at: max(NSMaxRange(selection) - (selection.length > 0 ? 1 : 0), selection.location)) else { return }
        chooseRows(anchor: first, head: max(last, first))
    }

    /// Back to writing: the caret where `at` says, or left as it is.
    private func leaveRows(caretAt at: Int? = nil) {
        guard rowsChosen != nil else { return }
        rowsChosen = nil
        caretBeforeRows = nil
        (layoutManager as? BodyLayoutManager)?.chosen = nil
        selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        insertionPointColor = coordinator?.parent.theme.accent ?? .controlAccentColor
        if let at { setSelectedRange(NSRange(location: min(at, textStorage?.length ?? at), length: 0)) }
        needsDisplay = true
    }

    private func stepRows(_ step: Int, extending: Bool) {
        guard let chosen = rowsChosen else { return }
        let head = chosen.head + step
        chooseRows(anchor: extending ? chosen.anchor : head, head: head)
    }

    /// ⇧↑ and ⇧↓, as Bike 2's: words are chosen within a row only — to its
    /// start, or its end — then the row is chosen whole, then the rows
    /// before it, or after.
    public override func moveUpAndModifySelection(_ sender: Any?) {
        if isChoosingRows { return stepRows(-1, extending: true) }
        guard let (index, line) = selectionRow() else { return super.moveUpAndModifySelection(sender) }
        let selection = selectedRange()
        if selection.location > Int(line.content) {
            return setSelectedRange(NSRange(location: Int(line.content), length: NSMaxRange(selection) - Int(line.content)))
        }
        caretBeforeRows = caretBeforeRows ?? NSMaxRange(selection)
        chooseRows(anchor: index, head: index)
    }

    public override func moveDownAndModifySelection(_ sender: Any?) {
        if isChoosingRows { return stepRows(1, extending: true) }
        guard let (index, line) = selectionRow() else { return super.moveDownAndModifySelection(sender) }
        let selection = selectedRange()
        if NSMaxRange(selection) < Int(line.end) {
            return setSelectedRange(NSRange(location: selection.location, length: Int(line.end) - selection.location))
        }
        caretBeforeRows = caretBeforeRows ?? selection.location
        chooseRows(anchor: index, head: index)
    }

    /// ⇧← and ⇧→ go no further than the row's words.
    public override func moveLeftAndModifySelection(_ sender: Any?) {
        if isChoosingRows { return }
        if let (_, line) = selectionRow(), selectedRange().location <= Int(line.content) { return }
        super.moveLeftAndModifySelection(sender)
    }

    public override func moveRightAndModifySelection(_ sender: Any?) {
        if isChoosingRows { return }
        if let (_, line) = selectionRow(), NSMaxRange(selectedRange()) >= Int(line.end) { return }
        super.moveRightAndModifySelection(sender)
    }

    /// Whether a line is code, where what is typed is typed as it is.
    static func isCode(_ line: BodyLine) -> Bool {
        switch line.kind {
        case .code, .fence: return true
        default: return false
        }
    }

    /// The row the selection is in, in an outline — when it is all in one.
    private func selectionRow() -> (Int, BodyLine)? {
        let lines = outlineLines
        let selection = selectedRange()
        guard let index = row(at: selection.location), lines.indices.contains(index), NSMaxRange(selection) <= Int(lines[index].end) else { return nil }
        return (index, lines[index])
    }

    // MARK: Rows chosen, moved about by keys
    //
    // With rows chosen, ← → ⌥← ⌥→ ⌥↑ ⌥↓ go back to writing — at the first
    // row's start, or the last's end; ⌘↑ ⌘↓ choose the first or the last
    // row, ⇧⌘↑ ⇧⌘↓ the rows to there.

    private func leaveRows(atStart: Bool) {
        guard let chosen = rowsChosen else { return }
        let lines = outlineLines
        let (first, last) = (min(chosen.anchor, chosen.head), max(chosen.anchor, chosen.head))
        leaveRows(caretAt: atStart ? Int(lines[first].content) : Int(lines[last].end))
    }

    public override func moveLeft(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: true) } else { super.moveLeft(sender) } }
    public override func moveRight(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: false) } else { super.moveRight(sender) } }
    public override func moveWordLeft(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: true) } else { super.moveWordLeft(sender) } }
    public override func moveWordRight(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: false) } else { super.moveWordRight(sender) } }
    public override func moveToBeginningOfParagraph(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: true) } else { super.moveToBeginningOfParagraph(sender) } }
    public override func moveToEndOfParagraph(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: false) } else { super.moveToEndOfParagraph(sender) } }
    public override func moveParagraphBackwardAndModifySelection(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: true) } else { super.moveParagraphBackwardAndModifySelection(sender) } }
    public override func moveParagraphForwardAndModifySelection(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: false) } else { super.moveParagraphForwardAndModifySelection(sender) } }

    public override func moveToBeginningOfDocument(_ sender: Any?) {
        if isChoosingRows { return chooseRows(anchor: 0, head: 0) }
        super.moveToBeginningOfDocument(sender)
    }

    public override func moveToEndOfDocument(_ sender: Any?) {
        let last = outlineLines.count - 1
        if isChoosingRows { return chooseRows(anchor: last, head: last) }
        super.moveToEndOfDocument(sender)
    }

    public override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        if let chosen = rowsChosen { return chooseRows(anchor: chosen.anchor, head: 0) }
        super.moveToBeginningOfDocumentAndModifySelection(sender)
    }

    public override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        if let chosen = rowsChosen { return chooseRows(anchor: chosen.anchor, head: outlineLines.count - 1) }
        super.moveToEndOfDocumentAndModifySelection(sender)
    }

    /// ⌘A: every row, chosen as rows.
    public override func selectAll(_ sender: Any?) {
        let lines = outlineLines
        guard !lines.isEmpty else { return super.selectAll(sender) }
        if !isChoosingRows { caretBeforeRows = selectedRange().location }
        chooseRows(anchor: 0, head: lines.count - 1)
    }

    // MARK: Expand and contract selection
    //
    // ⌃⇧⌘→: the word, the sentence, the row's words, the row, its branch,
    // its parent's branch, and on out. ⌃⇧⌘← goes back a step.

    private var chosenNow: Chosen {
        if let chosen = rowsChosen { return .rows(min(chosen.anchor, chosen.head), max(chosen.anchor, chosen.head)) }
        return .words(selectedRange())
    }

    private func choose(_ chosen: Chosen) {
        switch chosen {
        case .words(let range):
            leaveRows()
            setSelectedRange(range)
        case .rows(let first, let last):
            if !isChoosingRows { caretBeforeRows = selectedRange().location }
            chooseRows(anchor: first, head: last)
        }
    }

    /// The rows a row's branch shows: it, and every row after it deeper than it.
    private func branch(of index: Int, in lines: [BodyLine]) -> ClosedRange<Int> {
        var last = index
        while last + 1 < lines.count, lines[last + 1].depth > lines[index].depth { last += 1 }
        return index...last
    }

    /// What Expand Selection goes to from a selection.
    private func expanded(from chosen: Chosen) -> Chosen? {
        let lines = outlineLines
        let text = string as NSString
        switch chosen {
        case .words(let range):
            guard let index = row(at: range.location), lines.indices.contains(index) else { return nil }
            let line = lines[index]
            let words = NSRange(location: Int(line.content), length: Int(line.end) - Int(line.content))
            // The word, then the sentence, then the row's words: each the first that holds more than is chosen.
            var steps: [NSRange] = [selectionRange(forProposedRange: NSRange(location: range.location, length: max(range.length, 0)), granularity: .selectByWord)]
            text.enumerateSubstrings(in: words, options: [.bySentences, .substringNotRequired]) { _, sentence, _, stop in
                if NSIntersectionRange(sentence, range).length > 0 || (range.length == 0 && NSLocationInRange(range.location, sentence)) {
                    steps.append(sentence)
                    stop.pointee = true
                }
            }
            steps.append(words)
            if let next = steps.first(where: { NSUnionRange($0, range) == $0 && $0 != range && NSIntersectionRange($0, words) == $0 }) { return .words(next) }
            return .rows(index, index)
        case .rows(let first, let last):
            let whole = branch(of: first, in: lines)
            if whole.upperBound > last || first != whole.lowerBound { return .rows(whole.lowerBound, max(whole.upperBound, last)) }
            // Out to the parent's branch.
            guard let parent = (0..<first).last(where: { lines[$0].depth < lines[first].depth }) else {
                return lines.isEmpty || (first == 0 && last == lines.count - 1) ? nil : .rows(0, lines.count - 1)
            }
            return .rows(parent, branch(of: parent, in: lines).upperBound)
        }
    }

    func expandSelection() {
        let now = chosenNow
        guard !outlineLines.isEmpty, let next = expanded(from: now) else { return NSSound.beep() }
        if expansions.last != now { expansions = [] }
        expansions.append(now)
        choose(next)
        expansions.append(next)
    }

    func contractSelection() {
        // Back a step only from where expanding left it.
        guard expansions.count >= 2, expansions.last == chosenNow else { return NSSound.beep() }
        expansions.removeLast()
        let back = expansions.removeLast()
        choose(back)
        if !expansions.isEmpty { expansions.append(back) }
    }

    /// ⌃W, ⌃S: the word, or the sentence, the caret is in.
    func selectWord() {
        setSelectedRange(selectionRange(forProposedRange: selectedRange(), granularity: .selectByWord))
    }

    func selectSentence() {
        guard let (_, line) = selectionRow() else { return }
        let words = NSRange(location: Int(line.content), length: Int(line.end) - Int(line.content))
        let at = selectedRange().location
        (string as NSString).enumerateSubstrings(in: words, options: [.bySentences, .substringNotRequired]) { _, sentence, _, stop in
            if NSLocationInRange(at, sentence) || NSMaxRange(sentence) == at {
                self.setSelectedRange(sentence)
                stop.pointee = true
            }
        }
    }

    public override func insertBacktab(_ sender: Any?) {
        _ = coordinator?.perform(.outdent)
        chooseSelectedRows()
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        // Typed with rows chosen: Space checks the tasks among them off, or opens them again; nothing else is typed.
        if let chosen = rowsChosen {
            guard (string as? String) == " " || (string as? NSAttributedString)?.string == " " else { return }
            let lines = outlineLines
            let tasks = (min(chosen.anchor, chosen.head)...max(chosen.anchor, chosen.head)).filter { index in
                guard lines.indices.contains(index), case .item(_, let done, _) = lines[index].kind else { return false }
                return done != nil
            }
            if tasks.isEmpty || coordinator?.perform(.toggleCheckbox, onRows: tasks) != true { return }
            chooseRows(anchor: chosen.anchor, head: chosen.head)
            return
        }
        if let typed = (string as? String) ?? (string as? NSAttributedString)?.string, let (_, line) = selectionRow(), !Self.isCode(line) {
            let selection = selectedRange()
            // ' " [ { ( typed over words chosen in a row: the words wrapped, and still chosen — as Bike's.
            let pairs: [String: String] = ["'": "'", "\"": "\"", "[": "]", "{": "}", "(": ")"]
            if selection.length > 0, let close = pairs[typed], replacementRange.location == NSNotFound || replacementRange == selection {
                let words = (self.string as NSString).substring(with: selection)
                super.insertText(typed + words + close, replacementRange: selection)
                setSelectedRange(NSRange(location: selection.location + (typed as NSString).length, length: selection.length))
                return
            }
            // A quote typed, curled: opening after a space or a row's start, else closing.
            if selection.length == 0, typed == "'" || typed == "\"" {
                let before = selection.location > Int(line.content) ? (self.string as NSString).substring(with: NSRange(location: selection.location - 1, length: 1)) : ""
                let opening = before.isEmpty || before.rangeOfCharacter(from: .whitespaces.union(CharacterSet(charactersIn: "([{“‘"))) != nil
                let curled = typed == "'" ? (opening ? "‘" : "’") : (opening ? "“" : "”")
                return super.insertText(curled, replacementRange: replacementRange)
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    public override func copy(_ sender: Any?) {
        // Rows chosen are copied as they are written: their bullets and boxes with them.
        if let chosen = rowsChosen, let markdown = coordinator?.markdown(ofRows: Array(min(chosen.anchor, chosen.head)...max(chosen.anchor, chosen.head))) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
            return
        }
        super.copy(sender)
    }

    /// Words chosen, copied, cut or dragged: as the Markdown they are, links
    /// and pictures and all — the view shows only their words.
    public override func writeSelection(to board: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let selection = selectedRange()
        guard !outlineLines.isEmpty, !isChoosingRows, selection.length > 0, let coordinator else { return super.writeSelection(to: board, types: types) }
        let markdown = coordinator.editor.markdownBetween(start: UInt32(selection.location), end: UInt32(NSMaxRange(selection)))
        board.declareTypes([.string], owner: nil)
        return board.setString(markdown, forType: .string)
    }

    public override func cut(_ sender: Any?) {
        guard isChoosingRows else { return super.cut(sender) }
        copy(sender)
        deleteBackward(sender)
    }

    public override func insertNewline(_ sender: Any?) {
        // Return, with rows chosen: a new row after them, as Return at the last one's end makes, written in.
        if let chosen = rowsChosen {
            let lines = outlineLines
            leaveRows(caretAt: lines.indices.contains(max(chosen.anchor, chosen.head)) ? Int(lines[max(chosen.anchor, chosen.head)].end) : nil)
            if coordinator?.perform(.newline) != true { NSSound.beep() }
            return
        }
        if coordinator?.acceptOffer() == true { return }
        // Return at the end of a first line written as a heading: that line, the title.
        if coordinator?.titlesByReturn() == true { return coordinator?.parent.onTitle() ?? () }
        if coordinator?.perform(.newline) != true { super.insertNewline(sender) }
    }

    public override func insertTab(_ sender: Any?) {
        if coordinator?.acceptOffer() == true { return }
        // In an outline Tab only ever indents: a row that cannot go in stays, and no tab is typed.
        if coordinator?.perform(.indent) != true, !isChoosingRows, outlineLines.isEmpty { super.insertTab(sender) }
        chooseSelectedRows()
    }

    /// ⇧↩ and ⌥↩ split a row as ↩ does — in an outline, which has no line breaks within rows.
    public override func insertLineBreak(_ sender: Any?) {
        if outlineLines.isEmpty { super.insertLineBreak(sender) } else { insertNewline(sender) }
    }

    public override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        if outlineLines.isEmpty { super.insertNewlineIgnoringFieldEditor(sender) } else { insertNewline(sender) }
    }

    public override func moveUp(_ sender: Any?) {
        if isChoosingRows { return stepRows(-1, extending: false) }
        if coordinator?.isOffering == true { coordinator?.moveOffer(by: -1) } else { super.moveUp(sender) }
    }

    public override func moveDown(_ sender: Any?) {
        if isChoosingRows { return stepRows(1, extending: false) }
        if coordinator?.isOffering == true { coordinator?.moveOffer(by: 1) } else { super.moveDown(sender) }
    }

    public override func deleteBackward(_ sender: Any?) {
        // Rows chosen are deleted whole; the row that takes their place is chosen.
        if let chosen = rowsChosen {
            let at = min(chosen.anchor, chosen.head)
            if coordinator?.perform(.deleteRows) == true {
                let left = outlineLines.count
                if left == 0 { leaveRows(caretAt: 0) } else { chooseRows(anchor: min(at, left - 1), head: min(at, left - 1)) }
            }
            return
        }
        if coordinator?.perform(.deleteBackward) == true { return }
        if deleteOverMarkup(forward: false) { return }
        super.deleteBackward(sender)
    }

    public override func deleteForward(_ sender: Any?) {
        if isChoosingRows { return deleteBackward(sender) }
        if deleteOverMarkup(forward: true) { return }
        super.deleteForward(sender)
    }

    // MARK: Markdown never seen
    //
    // In an outline a row's Markdown — `**`, a link's brackets and address —
    // is in the text but never seen, as Bike's rich text has none. The caret
    // never stops inside it: each run of it is a boundary, crossed with one
    // press, which is the caret's side — Bike's typing affinity: before it,
    // what is typed joins the words before; after it, the words after.
    // Delete steps over it; a link shown by its page's title goes whole.

    private func isMarkup(_ at: Int) -> Bool {
        guard let storage = textStorage, at >= 0, at < storage.length else { return false }
        return storage.attribute(.prismMarkup, at: at, effectiveRange: nil) != nil
    }

    /// The run of hidden Markdown a place is strictly inside of.
    private func markupRun(around at: Int) -> (start: Int, end: Int)? {
        guard isMarkup(at - 1), isMarkup(at) else { return nil }
        var (start, end) = (at - 1, at)
        while isMarkup(start - 1) { start -= 1 }
        while isMarkup(end) { end += 1 }
        return (start, end)
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let old = selectedRange()
        // Never inside a link shown as its page's title: it is one thing, before or after it.
        let ranges = ranges.map { value in NSValue(range: textStorage.map { BodyStyler.outsideWholes(in: $0, value.rangeValue, from: old) } ?? value.rangeValue) }
        guard !outlineLines.isEmpty, !isChoosingRows else { return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting) }
        let snapped = ranges.map { value -> NSValue in
            var range = value.rangeValue
            if range.length == 0 {
                // Out of hidden Markdown, the way the caret was going.
                if let run = markupRun(around: range.location) { range.location = range.location > old.location ? run.end : run.start }
            } else {
                if let run = markupRun(around: range.location) { range = NSRange(location: run.start, length: NSMaxRange(range) - run.start) }
                if let run = markupRun(around: NSMaxRange(range)) { range.length = run.end - range.location }
            }
            return NSValue(range: range)
        }
        super.setSelectedRanges(snapped, affinity: affinity, stillSelecting: stillSelecting)
        // What is typed takes the look of the words it joins, never the hidden Markdown's.
        let caret = selectedRange()
        if caret.length == 0, isMarkup(caret.location - 1), let storage = textStorage {
            let from = caret.location < storage.length && !isMarkup(caret.location) ? caret.location : nil
            var attributes = from.map { storage.attributes(at: $0, effectiveRange: nil) } ?? [:]
            attributes[.prismMarkup] = nil
            attributes[.prismLabel] = nil
            if from == nil, let style = coordinator.map({ BodyStyler(theme: $0.parent.theme).baseAttributes }) { attributes = style }
            typingAttributes = attributes
        }
    }

    /// Delete beside hidden Markdown: the character past it — or a link
    /// shown by its title, whole — and not the Markdown. Says whether it
    /// did anything.
    private func deleteOverMarkup(forward: Bool) -> Bool {
        let selection = selectedRange()
        guard !outlineLines.isEmpty, selection.length == 0, let storage = textStorage else { return false }
        var at = selection.location
        if forward { while isMarkup(at) { at += 1 } } else { while isMarkup(at - 1) { at -= 1 } }
        guard at != selection.location else { return false }
        let text = storage.string as NSString
        // At a row's start, past Markdown that begins it: what Delete does there.
        if !forward, let index = row(at: at), Int(outlineLines[index].content) == at {
            setSelectedRange(NSRange(location: at, length: 0))
            if coordinator?.perform(.deleteBackward) != true { super.deleteBackward(nil) }
            return true
        }
        let character = forward ? at : at - 1
        guard character >= 0, character < text.length, text.character(at: character) != 10 else { return false }
        var target = text.rangeOfComposedCharacterSequence(at: character)
        if storage.attribute(.prismLabel, at: character, effectiveRange: nil) != nil || (storage.attribute(.prismLink, at: character, effectiveRange: nil) != nil && isMarkup(character + 1) && storage.attribute(.prismLabel, at: character, effectiveRange: nil) != nil) {
            // A link shown by its title: the link, whole, with its brackets.
            var whole = NSRange()
            _ = storage.attribute(.prismLink, at: character, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length))
            var (start, end) = (whole.location, NSMaxRange(whole))
            while isMarkup(start - 1) { start -= 1 }
            while isMarkup(end) { end += 1 }
            target = NSRange(location: start, length: end - start)
        }
        guard shouldChangeText(in: target, replacementString: "") else { return true }
        insertText("", replacementRange: target)
        return true
    }

    public override func cancelOperation(_ sender: Any?) {
        if coordinator?.isOffering == true { return coordinator?.dismissOffers() ?? () }
        let lines = outlineLines
        // As text, a note has no rows: Esc leaves it.
        guard !lines.isEmpty, !hasMarkedText() else {
            leaveRows()
            window?.makeFirstResponder(nil)
            return
        }
        // Esc goes between writing and rows chosen, as Bike's does: back to the caret where it was.
        if let chosen = rowsChosen {
            let (first, last) = (lines[min(chosen.anchor, chosen.head)], lines[max(chosen.anchor, chosen.head)])
            let kept = caretBeforeRows.flatMap { $0 >= Int(first.start) && $0 <= Int(last.end) ? $0 : nil }
            let at = kept ?? Int(lines[chosen.head].end)
            return leaveRows(caretAt: at)
        }
        let selection = selectedRange()
        guard let first = row(at: selection.location), let last = row(at: max(NSMaxRange(selection) - (selection.length > 0 ? 1 : 0), selection.location)) else { return }
        caretBeforeRows = selection.location
        chooseRows(anchor: first, head: last)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "z", flags == [.command] {
            coordinator?.undo()
            return true
        }
        if key == "z", flags == [.command, .shift] {
            coordinator?.redo()
            return true
        }
        if key == "k", flags == [.command, .option] {
            askLink()
            return true
        }
        // ⌥⌘→ shows the caret's row as a note of its own — Bike's focus in; with ⇧, in a card of its
        // own. ⌥⌘← shows more again. (⌘[ ⌘] are the app's: back and forward.)
        if event.specialKey == .rightArrow, flags == [.command, .option] || flags == [.command, .option, .shift], coordinator?.parent.onZoom != nil {
            if coordinator?.zoom(apart: flags.contains(.shift)) != true { NSSound.beep() }
            return true
        }
        if event.specialKey == .leftArrow, flags == [.command, .option], let out = coordinator?.parent.onZoomOut {
            out()
            return true
        }
        // ⌘A in an outline: every row, chosen as rows.
        if key == "a", flags == [.command], !outlineLines.isEmpty {
            selectAll(nil)
            return true
        }
        if flags == [.command, .control, .shift], !outlineLines.isEmpty, event.specialKey == .rightArrow || event.specialKey == .leftArrow {
            if event.specialKey == .rightArrow { expandSelection() } else { contractSelection() }
            return true
        }
        guard let command = Self.command(flags: flags, key: key, special: event.specialKey) else { return super.performKeyEquivalent(with: event) }
        let done = perform(keyed: command)
        // A fold with nothing to fold leaves its key — ⌘0 is many an app's own — to whoever wants it.
        return done || !Self.outlineOnly.contains(command) || super.performKeyEquivalent(with: event)
    }

    /// A command its keys gave, and where the selection then is, as Bike has
    /// it: writing in a row put in, joined or grouped; the copy chosen as
    /// rows; after rows deleted, the next row chosen; else as it was.
    private func perform(keyed command: EditCommand) -> Bool {
        let done = coordinator?.perform(command) ?? false
        guard done else { return false }
        switch command {
        case .insertBelow, .insertAbove, .insertChild, .group, .joinRows:
            leaveRows()
        case .duplicateRows, .deleteRows:
            if let at = row(at: selectedRange().location) { chooseRows(anchor: at, head: at) }
        default:
            // Done to rows chosen: they are chosen still, wherever they went.
            chooseSelectedRows()
        }
        return true
    }

    /// The commands only an outline has, whose keys are let by when there is nothing for them to do.
    private static let outlineOnly: Set<EditCommand> = [.fold, .unfold, .foldCompletely, .unfoldCompletely, .foldAll, .unfoldAll, .foldByLevel, .unfoldByLevel, .foldAllByLevel, .unfoldAllByLevel, .moveDoneToBottom]

    // MARK: Pictures, and an address, pasted and dropped

    /// The kinds of picture a note keeps as they are; any other is made a PNG.
    private static let keptPictures: [(type: UTType, fileExtension: String)] = [(.png, "png"), (.jpeg, "jpg"), (.gif, "gif")]
    private static let pictureTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier)]

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Each picture a pasteboard holds: files of pictures, or a picture itself.
    private static func pictures(on board: NSPasteboard) -> [EditorPastedPicture] {
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            return files.compactMap { url in
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), let data = try? Data(contentsOf: url) else { return nil }
                if let kept = keptPictures.first(where: { type.conforms(to: $0.type) }) { return EditorPastedPicture(data: data, fileExtension: kept.fileExtension) }
                return NSImage(data: data).flatMap(png).map { EditorPastedPicture(data: $0, fileExtension: "png") }
            }
        }
        for kept in keptPictures {
            if let data = board.data(forType: NSPasteboard.PasteboardType(kept.type.identifier)) { return [EditorPastedPicture(data: data, fileExtension: kept.fileExtension)] }
        }
        if let data = board.data(forType: .tiff), let image = NSImage(data: data), let made = png(image) { return [EditorPastedPicture(data: made, fileExtension: "png")] }
        return []
    }

    /// What pasting from a pasteboard gives when it is pictures: files of
    /// pictures — whatever words come with them, as the Finder gives
    /// their names — else a picture that comes with no words. None, when
    /// what is pasted is words.
    private static func pasted(from board: NSPasteboard) -> [EditorPastedPicture] {
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !files.isEmpty || board.string(forType: .string) == nil else { return [] }
        return pictures(on: board)
    }

    /// An address pasted onto words links them; pictures pasted are the
    /// app's to keep, and are written where the caret is; anything else
    /// is pasted as ever.
    public override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if selectedRange().length > 0, let words = board.string(forType: .string), coordinator?.link(to: words) == true { return }
        if coordinator?.insert(pictures: Self.pasted(from: board)) == true { return }
        super.paste(sender)
    }

    /// A picture can be pasted, though the text view holds only words:
    /// said so, or Paste is greyed out — and ⌘V does nothing — whenever
    /// what was copied is a picture and nothing else.
    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + Self.pictureTypes.filter { !super.readablePasteboardTypes.contains($0) }
    }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, NSPasteboard.general.availableType(from: Self.pictureTypes) != nil { return true }
        return super.validateUserInterfaceItem(item)
    }

    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + ([Self.rowsType] + Self.pictureTypes).filter { !super.acceptableDragTypes.contains($0) }
    }

    /// Pictures dropped: the app's to keep, and written where they were let go.
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let dropped = drop(rows: sender) { return dropped }
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        if coordinator?.insert(pictures: Self.pictures(on: sender.draggingPasteboard), at: at) == true { return true }
        return super.performDragOperation(sender)
    }

    /// The editor's own keys.
    // MARK: A link, asked for

    // MARK: What a menu asks of the note being written in

    /// The note with the caret, in the key window: what a menu's command is done to.
    public static var writing: NoteTextView? { NSApp.keyWindow?.firstResponder as? NoteTextView }

    /// Does a command, as its keys would. Says whether there was anything to do.
    @discardableResult
    public func run(_ command: EditCommand) -> Bool {
        let done = perform(keyed: command)
        if !done { NSSound.beep() }
        return done
    }

    /// The caret's row as a note of its own: here, or (`apart`) in a card of its own.
    public func focusRow(apart: Bool) {
        if coordinator?.zoom(apart: apart) != true { NSSound.beep() }
    }

    /// More than the row now shown: the row it is under.
    public func showRowAbove() {
        if let out = coordinator?.parent.onZoomOut { out() } else { NSSound.beep() }
    }

    /// ⌥⌘K: asks where the words selected should lead, and links them
    /// there; with nothing selected, writes the address itself.
    public func askLink() {
        guard let window, linkPrompt == nil else { return }
        let range = selectedRange()
        var anchor = convert(window.convertFromScreen(firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
        anchor.size.width = max(anchor.width, 1)
        let field = NSTextField(frame: NSRect(x: 12, y: 10, width: 300, height: 24))
        field.placeholderString = "Link to — https://…"
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(linkEntered(_:))
        // An address already copied is most likely the one meant.
        if let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), webAddress(text: copied) != nil { field.stringValue = copied }
        let holder = NSViewController()
        holder.view = NSView(frame: NSRect(x: 0, y: 0, width: 324, height: 44))
        holder.view.addSubview(field)
        let prompt = NSPopover()
        prompt.contentViewController = holder
        prompt.behavior = .transient
        prompt.delegate = self
        linkPrompt = prompt
        linkRange = range
        prompt.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        prompt.contentViewController?.view.window?.makeFirstResponder(field)
    }

    @objc private func linkEntered(_ field: NSTextField) {
        var address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = linkRange
        linkPrompt?.close()
        guard !address.isEmpty else { return }
        // Written without its scheme, as addresses are said.
        if webAddress(text: address) == nil, !address.contains("://") { address = "https://" + address }
        window?.makeFirstResponder(self)
        setSelectedRange(range)
        if range.length > 0 {
            if coordinator?.link(to: address) != true { NSSound.beep() }
        } else {
            insertText("<\(address)>", replacementRange: range)
        }
    }

    /// Asks about a link on the web, under it: its words, to rewrite; its
    /// page's title, to take for them; and the way there. Says whether it asked.
    private func editLink(_ address: String, at point: CGPoint) -> Bool {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0, linkPrompt == nil, let coordinator else { return false }
        let character = manager.characterIndexForGlyph(at: manager.glyphIndex(for: point, in: container))
        var range = NSRange()
        guard character < storage.length, storage.attribute(.prismLink, at: character, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil else { return false }
        let text = storage.string as NSString
        let written = text.substring(with: range)
        // An address written bare is its own words; written `<so>`, its brackets go with it.
        let bare = written == address || address.hasSuffix(written)
        if bare, range.location > 0, NSMaxRange(range) < text.length, text.character(at: range.location - 1) == 60, text.character(at: NSMaxRange(range)) == 62 {
            range = NSRange(location: range.location - 1, length: range.length + 2)
        }
        let prompt = NSPopover()
        let known = coordinator.parent.webTitle
        let content = LinkEditor(
            address: address, words: bare ? "" : written, title: { known?(address) },
            apply: { [weak self, weak prompt] words in
                prompt?.close()
                let words = words.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
                guard let self, !words.isEmpty, words != written else { return }
                self.coordinator?.rewrite(range, as: bare ? "[\(words)](\(address))" : words)
            },
            open: { [weak self, weak prompt] in
                prompt?.close()
                self?.coordinator?.parent.onFollow(.web(address))
            }
        )
        prompt.contentViewController = NSHostingController(rootView: content)
        prompt.behavior = .transient
        prompt.delegate = self
        linkPrompt = prompt
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var anchor = manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        anchor.size.width = max(anchor.width, 1)
        prompt.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        return true
    }

    /// Bike 2's keys, as its menus and key maps have them (`docs/bike-parity.md`).
    static func command(flags: NSEvent.ModifierFlags, key: String, special: NSEvent.SpecialKey?) -> EditCommand? {
        switch (flags, key) {
        case ([.command], "b"): return .bold
        case ([.command], "i"): return .italic
        case ([.command, .shift], "h"): return .highlight
        case ([.command, .shift], "c"): return .code
        // With ⇧, the keys say what they say shifted: - is _.
        case ([.command, .shift], "-"), ([.command, .shift], "_"): return .strikethrough
        case ([.command, .shift], "k"): return .deleteRows
        case ([.control, .option], "k"): return .deleteRowOnly
        case ([.command], "d"): return .duplicateRows
        case ([.command, .option], "g"): return .group
        case ([.command, .shift], "8"), ([.command, .shift], "*"): return .bullet
        case ([.command], "9"): return .fold
        case ([.command], "0"): return .unfold
        case ([.command, .option], "9"): return .foldByLevel
        case ([.command, .option], "0"): return .unfoldByLevel
        case ([.command, .control, .option], "9"): return .foldAllByLevel
        case ([.command, .control, .option], "0"): return .unfoldAllByLevel
        case ([.command, .control], "9"): return .foldAll
        case ([.command, .control], "0"): return .unfoldAll
        case ([.command, .control, .shift], "d"): return .moveDoneToBottom
        default: break
        }
        if special == .carriageReturn || special == .enter || key == "\r" {
            if flags == [.command] { return .insertBelow }
            if flags == [.command, .shift] { return .insertAbove }
            if flags == [.command, .option] { return .insertChild }
        }
        if (special == .delete || special == .backspace || key == "\u{7F}" || key == "\u{8}"), flags == [.command, .control] { return .joinRows }
        let arrows: [NSEvent.SpecialKey: Int] = [.upArrow: 0, .downArrow: 1, .rightArrow: 2, .leftArrow: 3]
        guard let special, let arrow = arrows[special] else { return nil }
        switch flags {
        case [.command, .control]: return [EditCommand.moveUp, .moveDown, .indent, .outdent][arrow]
        case [.command, .control, .option]: return [EditCommand.moveUpKeepingLevel, .moveDownKeepingLevel, nil, nil][arrow]
        case [.control, .option]: return [EditCommand.moveUpRowOnly, .moveDownRowOnly, .indentRowOnly, .outdentRowOnly][arrow]
        case [.control, .option, .shift]: return [nil, nil, EditCommand.demoteSiblings, .promoteChildren][arrow]
        default: return nil
        }
    }
}
#if DEBUG
/// For a harness driving the editor as Bike is driven, to compare the two:
/// what is shown — each row's words, depth and fold — and what is chosen.
extension NoteTextView {
    public var probeState: [String: Any] {
        let text = string as NSString
        let rows: [[String: Any]] = outlineLines.map { line in
            let words = text.substring(with: NSRange(location: Int(line.content), length: max(Int(line.end) - Int(line.content), 0)))
            var kind = "body"
            switch line.kind {
            case .heading: kind = "heading"
            case .item(let number, let done, let bullet): kind = done != nil ? "task" : number != nil ? "ordered" : bullet == "-" ? "body" : "unordered"
            case .quote: kind = "quote"
            case .code, .fence: kind = "code"
            default: break
            }
            return ["name": words, "depth": Int(line.depth), "folded": line.isFolded, "children": line.hasChildren, "type": kind, "done": { if case .item(_, let done, _) = line.kind { return done == true } else { return false } }(), "start": Int(line.start), "end": Int(line.end), "content": Int(line.content)]
        }
        let range = selectedRange()
        var state: [String: Any] = ["rows": rows, "selection": [range.location, range.length], "selectedText": text.substring(with: range), "markdown": coordinator?.editor.markdown() ?? ""]
        if let chosen = rowsChosen { state["chosen"] = [min(chosen.anchor, chosen.head), max(chosen.anchor, chosen.head)] }
        state["focused"] = window?.firstResponder === self
        state["view"] = String(UInt(bitPattern: ObjectIdentifier(self).hashValue), radix: 16)
        state["responder"] = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        return state
    }

    /// The caret put at a place of the text, writing.
    public func probeCaret(at location: Int) {
        window?.makeFirstResponder(self)
        leaveRows()
        setSelectedRange(NSRange(location: min(location, (string as NSString).length), length: 0))
    }
}
#endif

extension NoteTextView: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === linkPrompt { linkPrompt = nil }
    }
}
#endif


#if os(macOS)
/// What is asked of a link on the web, clicked: the words it is shown
/// by, to write anew; its page's title, to take for them; the way there.
private struct LinkEditor: View {
    let address: String
    @State var words: String
    let title: () -> String?
    let apply: (String) -> Void
    let open: () -> Void
    @State private var known: String?
    @FocusState private var writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $words)
                .textFieldStyle(.roundedBorder)
                .focused($writing)
                .onSubmit { apply(words) }
            Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let known, known != words {
                Button { apply(known) } label: {
                    Label(known, systemImage: "textformat").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("Use the page's title")
            }
            HStack {
                Button("Open") { open() }
                Spacer()
                Button("Rename") { apply(words) }.keyboardShortcut(.defaultAction).disabled(words.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { writing = true }
        .task {
            // The page's title, as soon as the app has found it out.
            for _ in 0..<24 {
                known = title()
                if known != nil { return }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}
#endif
