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
    /// What a link's page is shown as called, where the link does not say it.
    var linkLabel: (String) -> String?
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
    /// What stands at the head of the note's first line in place of its
    /// bullet, and what clicking it does. Drawn only when the note opens
    /// with a plain bulleted line: see `takesLead`.
    var lead: EditorLead?
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
    var foldedRows: [EditorFoldedRow]
    var onFolds: ([EditorFoldedRow]) -> Void
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
    /// Whether the note is today's: its timelines show the time now.
    var isToday: Bool

    /// - Parameters:
    ///   - editor: the note. Give another to show another — or the same
    ///     note read again, after its file changed underneath.
    ///   - isWriting: whether the caret should be here.
    ///   - height: kept at the height the text needs at the width given.
    ///   - refresh: any value that changes when the look should be redone.
    public init(
        editor: NoteEditor, theme: EditorTheme, isWriting: Bool, height: Binding<CGFloat>, refresh: Int = 0,
        pageExists: @escaping (String) -> Bool = { _ in true },
        linkLabel: @escaping (String) -> String? = { _ in nil },
        blockView: @escaping (EditorBlock) -> AnyView? = { _ in nil },
        linkPreview: @escaping (EditorLink) -> AnyView? = { _ in nil },
        lead: EditorLead? = nil, onLead: @escaping () -> Void = {},
        offers: @escaping (BodyCompletion) -> [EditorOffer] = { _ in [] },
        offersTitle: Bool = false, onTitle: @escaping () -> Void = {},
        foldedRows: [EditorFoldedRow] = [], onFolds: @escaping ([EditorFoldedRow]) -> Void = { _ in },
        onMoveRows: ((_ markdown: String, _ moved: @escaping () -> Void) -> Void)? = nil,
        savePictures: @escaping ([EditorPastedPicture]) -> [String] = { _ in [] },
        isToday: Bool = false,
        onChange: @escaping () -> Void = {}, onFocus: @escaping (Bool) -> Void = { _ in }, onFollow: @escaping (EditorLink) -> Void = { _ in }
    ) {
        self.editor = editor
        self.theme = theme
        self.isWriting = isWriting
        _height = height
        self.refresh = refresh
        self.pageExists = pageExists
        self.linkLabel = linkLabel
        self.blockView = blockView
        self.linkPreview = linkPreview
        self.lead = lead
        self.onLead = onLead
        self.offers = offers
        self.offersTitle = offersTitle
        self.onTitle = onTitle
        self.foldedRows = foldedRows
        self.onFolds = onFolds
        self.onMoveRows = onMoveRows
        self.savePictures = savePictures
        self.isToday = isToday
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
        _ = context.coordinator.takeFolds(anew: true)
        context.coordinator.load()
        return view
    }

    public func updateNSView(_ view: NoteTextView, context: Context) {
        let coordinator = context.coordinator
        let other = coordinator.parent.editor !== editor
        let folds = other || coordinator.parent.foldedRows != foldedRows
        let looks = coordinator.parent.refresh != refresh || coordinator.parent.theme.size != theme.size || coordinator.parent.theme.face != theme.face || coordinator.parent.lead != lead
            || coordinator.parent.isToday != isToday
        coordinator.parent = self
        let refolded = folds && coordinator.takeFolds(anew: other)
        if other || refolded || coordinator.shownMode != editor.mode() || coordinator.shown != editor.text() {
            // …or the note was changed from outside the view: a link given its title, say.
            coordinator.load()
        } else if looks {
            coordinator.restyle()
        }
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
    private var resized: NSObjectProtocol?
    /// Whether the pointer is on the card: it stays while it is.
    private(set) var isPointed = false
    /// The pointer left the card.
    var onLeave: () -> Void = {}

    init(content: AnyView, at pointer: CGPoint, over parent: NSWindow) {
        self.pointer = pointer
        self.parent = parent
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        // It is as large as what it shows — which may grow, as a page's picture comes in.
        host.sizingOptions = [.preferredContentSize]
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The pointer may come onto it: what it offers can be clicked.
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        host.rootView = AnyView(
            content.background(.regularMaterial).clipShape(shape).overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
                .onHover { [weak self] inside in
                    guard let self else { return }
                    self.isPointed = inside
                    if !inside { self.onLeave() }
                }
        )
        panel.setContentSize(host.view.fittingSize)
        place()
        resized = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        parent.addChildWindow(panel, ordered: .above)
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
        if let resized { NotificationCenter.default.removeObserver(resized) }
        resized = nil
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
            chip.toolTip = "Make this line the title (⌃⌘T)"
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
        if manager.isLead(at: point) || manager.task(at: point, in: container) != nil || manager.foldPill(at: point) != nil { return .box }
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
        case .block, .elsewhere:
            // Theirs to shape from here on; an arrow as the pointer leaves the words.
            if under != now { NSCursor.arrow.set() }
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

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let manager = layoutManager else { return 20 }
        if abs(container.size.width - width) > 0.5 {
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
        var used = manager.usedRect(for: container).height
        // An empty last line is the caret's to wait on.
        used = max(used, manager.extraLineFragmentRect.maxY)
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
        guard let manager = layoutManager as? BodyLayoutManager, let container = textContainer else { return super.mouseDown(with: event) }
        let point = containerPoint(event)
        if manager.isLead(at: point) {
            coordinator?.parent.onLead()
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
        guard let pressed else { return super.mouseUp(with: event) }
        self.pressed = nil
        let point = containerPoint(event)
        guard hypot(point.x - pressed.point.x, point.y - pressed.point.y) < 4 else { return }
        if let task = pressed.task {
            coordinator?.perform(.toggleCheckbox, at: task)
        } else if let link = pressed.link {
            coordinator?.parent.onFollow(link)
        }
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
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            DispatchQueue.main.async { [weak self] in self?.coordinator?.focusChanged(false) }
        }
        return resigned
    }

    // What the keys do is the note's; what it has no part in is the text view's own.

    // While pages are offered for a link being typed, the keys that
    // choose among them are the list's.

    public override func insertNewline(_ sender: Any?) {
        if coordinator?.acceptOffer() == true { return }
        // Return at the end of a first line written as a heading: that line, the title.
        if coordinator?.titlesByReturn() == true { return coordinator?.parent.onTitle() ?? () }
        if coordinator?.perform(.newline) != true { super.insertNewline(sender) }
    }

    public override func insertTab(_ sender: Any?) {
        if coordinator?.acceptOffer() == true { return }
        if coordinator?.perform(.indent) != true { super.insertTab(sender) }
    }

    public override func moveUp(_ sender: Any?) {
        if coordinator?.isOffering == true { coordinator?.moveOffer(by: -1) } else { super.moveUp(sender) }
    }

    public override func moveDown(_ sender: Any?) {
        if coordinator?.isOffering == true { coordinator?.moveOffer(by: 1) } else { super.moveDown(sender) }
    }

    public override func insertBacktab(_ sender: Any?) {
        _ = coordinator?.perform(.outdent)
    }

    public override func deleteBackward(_ sender: Any?) {
        if coordinator?.perform(.deleteBackward) != true { super.deleteBackward(sender) }
    }

    public override func cancelOperation(_ sender: Any?) {
        if coordinator?.isOffering == true { return coordinator?.dismissOffers() ?? () }
        window?.makeFirstResponder(nil)
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
        if flags == [.command, .option], event.specialKey == .carriageReturn || event.specialKey == .enter || key == "\r" {
            // Nothing to do as text: the key is whoever's wants it.
            return coordinator?.newTimeBlock() == true || super.performKeyEquivalent(with: event)
        }
        if key == "k", flags == [.command, .option] {
            askLink()
            return true
        }
        guard let command = Self.command(flags: flags, key: key, special: event.specialKey) else { return super.performKeyEquivalent(with: event) }
        let done = coordinator?.perform(command) ?? false
        // A fold with nothing to fold leaves its key — ⌘0 is many an app's own — to whoever wants it.
        return done || !Self.outlineOnly.contains(command) || super.performKeyEquivalent(with: event)
    }

    /// The commands only an outline has, whose keys are let by when there is nothing for them to do.
    private static let outlineOnly: Set<EditCommand> = [.fold, .unfold, .foldCompletely, .unfoldCompletely, .foldAll, .unfoldAll, .moveDoneToBottom]

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

    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + Self.pictureTypes.filter { !super.acceptableDragTypes.contains($0) }
    }

    /// Pictures dropped: the app's to keep, and written where they were let go.
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        if coordinator?.insert(pictures: Self.pictures(on: sender.draggingPasteboard), at: at) == true { return true }
        return super.performDragOperation(sender)
    }

    /// The editor's own keys.
    // MARK: A link, asked for

    /// ⌥⌘K: asks where the words selected should lead, and links them
    /// there; with nothing selected, writes the address itself.
    func askLink() {
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

    private static func command(flags: NSEvent.ModifierFlags, key: String, special: NSEvent.SpecialKey?) -> EditCommand? {
        switch (flags, key) {
        case ([.command], "b"): return .bold
        case ([.command], "i"): return .italic
        case ([.command, .shift], "h"): return .highlight
        // With ⇧, the keys say what they say shifted: ` is ~, - is _.
        case ([.command, .shift], "`"), ([.command, .shift], "~"): return .code
        case ([.command, .shift], "-"), ([.command, .shift], "_"): return .strikethrough
        case ([.command, .shift], "k"): return .deleteRows
        case ([.command, .shift], "d"): return .duplicateRows
        case ([.command, .shift], "8"), ([.command, .shift], "*"): return .bullet
        case ([.command], "9"): return .fold
        case ([.command], "0"): return .unfold
        case ([.command, .control], "9"): return .foldCompletely
        case ([.command, .control], "0"): return .unfoldCompletely
        case ([.command, .option], "9"): return .foldAll
        case ([.command, .option], "0"): return .unfoldAll
        case ([.command, .control, .shift], "d"): return .moveDoneToBottom
        default: break
        }
        if special == .carriageReturn || special == .enter || key == "\r" {
            if flags == [.command] { return .cycleChecklist }
            if flags == [.command, .shift] { return .toggleTask }
        }
        if flags == [.command, .control] {
            switch special {
            case .upArrow: return .moveUp
            case .downArrow: return .moveDown
            case .rightArrow: return .indent
            case .leftArrow: return .outdent
            default: break
            }
        }
        return nil
    }
}
extension NoteTextView: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === linkPrompt { linkPrompt = nil }
    }
}
#endif
