#if os(iOS)
import Prism
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A note's body, written in where it stands.
///
/// The same view as the Mac's, over a `UITextView`: the same note, the
/// same theme, the same things told to the app. What a pointer and a
/// keyboard do there, a finger does here — a tap follows a link or ticks
/// a box, or folds the rows under a bullet; a swipe along a row sets it
/// in or out; a row held is carried to another place, or, let go where it
/// was, shows what can be done to it (NoteEditorRows+iOS.swift) — and the
/// tools stand over the keys (`EditorKeyboardBar`), where the pages
/// offered for a link being typed are listed too. See NoteEditorView.swift
/// for what each part is; the work both share is in
/// NoteEditorCoordinator.swift.
public struct NoteEditorView: UIViewRepresentable {
    /// Posted by what a link's card offers, once it is done: the card goes.
    public static let hoverCardDone = Notification.Name("prism.editor.hoverCardDone")

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
    var refresh: Int
    var blockView: (EditorBlock) -> AnyView?
    /// Not shown here: there is no pointer to rest on a link.
    var linkPreview: (EditorLink) -> AnyView?
    var lead: EditorLead?
    var onLead: () -> Void
    /// The pages the app offers for a link being typed: after `[[`, and
    /// after `@`. Listed over the keys; a tap takes one, Return the first.
    var offers: (BodyCompletion) -> [EditorOffer]
    var offersTitle: Bool
    var onTitle: () -> Void
    /// The rows of the outline that are folded, which the app keeps, and
    /// what it is told when they change: see NoteEditorView.swift.
    var foldedRows: [EditorFoldedRow]?
    var onFolds: ([EditorFoldedRow]) -> Void
    /// Words found in the note, marked: where a find, or the words a card
    /// was opened by, are. `markAt`, the one gone to now, is marked more,
    /// and brought into sight.
    var marks: [NSRange]
    var markAt: Int?
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
    /// offered neither for a row held nor for rows chosen together.
    var onMoveRows: ((_ markdown: String, _ moved: @escaping () -> Void) -> Void)?
    /// Keeps pictures pasted, and says where: a path in the graph for
    /// each, in order. None, and what was pasted is the text view's.
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
        lead: EditorLead? = nil, onLead: @escaping () -> Void = {},
        offers: @escaping (BodyCompletion) -> [EditorOffer] = { _ in [] },
        offersTitle: Bool = false, onTitle: @escaping () -> Void = {},
        foldedRows: [EditorFoldedRow]? = nil, onFolds: @escaping ([EditorFoldedRow]) -> Void = { _ in },
        onMoveRows: ((_ markdown: String, _ moved: @escaping () -> Void) -> Void)? = nil,
        savePictures: @escaping ([EditorPastedPicture]) -> [String] = { _ in [] },
        onZoom: ((_ row: String, _ apart: Bool) -> Void)? = nil, onZoomOut: (() -> Void)? = nil,
        marks: [NSRange] = [], markAt: Int? = nil,
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
        self.lead = lead
        self.onLead = onLead
        self.offers = offers
        self.offersTitle = offersTitle
        self.onTitle = onTitle
        self.foldedRows = foldedRows
        self.onFolds = onFolds
        self.onZoom = onZoom
        self.marks = marks
        self.markAt = markAt
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

    public func makeUIView(context: Context) -> NoteTextView {
        let view = NoteTextView.make()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.tintColor = theme.accent
        context.coordinator.view = view
        view.enlist()
        _ = context.coordinator.takeFolds(anew: true)
        context.coordinator.load()
        context.coordinator.showMarks(goingTo: false)
        return view
    }

    public func updateUIView(_ view: NoteTextView, context: Context) {
        let coordinator = context.coordinator
        let other = coordinator.parent.editor !== editor
        let marked = coordinator.parent.marks != marks || coordinator.parent.markAt != markAt
        let folds = other || coordinator.parent.foldedRows != foldedRows
        let looks = coordinator.parent.refresh != refresh || coordinator.parent.theme.size != theme.size || coordinator.parent.theme.face != theme.face || coordinator.parent.lead != lead
        coordinator.parent = self
        defer { if marked || other { coordinator.showMarks(goingTo: coordinator.parent.markAt != nil && marked) } }
        if view.tintColor != theme.accent { view.tintColor = theme.accent }
        let refolded = folds && coordinator.takeFolds(anew: other)
        if other || refolded || coordinator.shownMode != editor.mode() || coordinator.shown != editor.text() {
            // …or the note was changed from outside the view: a link given its title, say.
            // Other rows than those that were chosen, or carried.
            view.hands?.letGo()
            coordinator.load()
        } else if looks {
            coordinator.restyle()
        }
        view.showTools()
        // While the app has yet to hear that the caret came or went, what
        // it says of where the caret should be is what it said before.
        guard view.focusReports == 0 else { return }
        if isWriting, !view.isFirstResponder {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window != nil, !view.isFirstResponder, view.focusReports == 0, view.coordinator?.parent.isWriting == true else { return }
                view.becomeFirstResponder()
            }
        } else if !isWriting, view.isFirstResponder {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isFirstResponder, view.focusReports == 0, view.coordinator?.parent.isWriting == false else { return }
                view.resignFirstResponder()
            }
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: NoteTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: uiView.height(forWidth: width))
    }
}

// What the text view tells the coordinator, and a phone's way of listing
// what is offered; the work itself is in NoteEditorCoordinator.swift.
extension NoteEditorView.Coordinator: UITextViewDelegate {
    public func textViewDidChange(_ textView: UITextView) {
        typed()
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        // Not while something is composed, which dressing the text again
        // would break off; and not between a change and the note's taking
        // it, when what the note says of the text is of the text before.
        guard let view, !view.isComposing, !isBehind else { return }
        selectionChanged()
        view.showFold()
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let view, !view.isComposing else { return true }
        // Delete at a row's start, should it come this way and not by `deleteBackward`.
        if text.isEmpty, range.length > 0, view.caret.length == 0, NSMaxRange(range) == view.caret.location {
            return !perform(.deleteBackward)
        }
        guard text == "\n" else { return true }
        // Return takes the first page offered, while pages are.
        if acceptOffer() { return false }
        // Return at the end of a first line written as a heading: that line, the title.
        if titlesByReturn() {
            parent.onTitle()
            return false
        }
        return !perform(.newline)
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        report(focused: true)
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        if let view, view.caret.length > 0 { view.caret = NSRange(location: view.caret.location, length: 0) }
        report(focused: false)
    }

    /// Tells the app the caret came or went — on the next turn, as on the
    /// Mac: never in the middle of the app's own drawing.
    private func report(focused: Bool) {
        view?.focusReports += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view?.focusReports -= 1
            self.focusChanged(focused)
            self.view?.noteSettled()
        }
    }

    func showOffers() {
        guard let offering else { return }
        view?.bar?.show(chips: offering.offers.map { ($0.title, $0.symbol) }) { [weak self] index in
            self?.acceptOffer(at: index)
        }
    }

    func closeOffers() {
        view?.bar?.show(chips: []) { _ in }
    }

    /// `[[` at the caret, for a link to be typed; around what is selected, a link to it.
    func insertLink() {
        guard let view, !view.isComposing else { return }
        let selection = view.caret
        let text = view.shownText as NSString
        guard NSMaxRange(selection) <= text.length else { return }
        let words = selection.length > 0 ? "[[" + text.substring(with: selection) + "]]" : "[["
        settle(editor.replace(start: UInt32(selection.location), end: UInt32(NSMaxRange(selection)), replacement: words))
    }

    /// How far in an outline's empty last row stands, if the caret at a
    /// place is on one: a row with no character to carry its indentation,
    /// and so nothing to say where its caret goes. A note with nothing in
    /// it yet is such a row: where its first words will be.
    func emptyRowIndent(at caret: Int) -> CGFloat? {
        guard shownMode == .outline else { return nil }
        if layout.lines.isEmpty { return parent.theme.step }
        guard let line = layout.lines.last(where: { Int($0.start) <= caret && caret <= Int($0.end) }), line.start == line.end else { return nil }
        return CGFloat(line.depth) * parent.theme.step
    }

    /// Sets the row at a place in or out, wherever the caret is. Says
    /// whether there was anything to do.
    func shiftRow(_ command: EditCommand, at place: Int) -> Bool {
        guard let view, !view.isComposing else { return false }
        let kept = view.caret
        // The caret's own row: as if by the key, and the note says where the caret then is.
        if let line = layout.lines.first(where: { Int($0.start) <= place && place <= Int($0.end) }),
           kept.location >= Int(line.start), NSMaxRange(kept) <= Int(line.end) {
            return perform(command)
        }
        guard var edit = editor.perform(selectionStart: UInt32(place), selectionEnd: UInt32(place), command: command) else { return false }
        // Another row: the caret stays with the words it was among.
        let (start, end, length) = (Int(edit.start), Int(edit.end), (edit.replacement as NSString).length)
        let moved = { (at: Int) -> Int in at >= end ? at + length - (end - start) : min(at, start + length) }
        edit.selectionStart = UInt32(max(moved(kept.location), 0))
        edit.selectionEnd = UInt32(max(moved(NSMaxRange(kept)), 0))
        settle(edit)
        return true
    }
}

/// One of the app's own views, standing in the text in place of a block.
@MainActor
final class BlockHost {
    /// What holds it: a view the text view knows as not its own text.
    final class Holder: UIView {}

    private let controller = UIHostingController(rootView: AnyView(EmptyView()))
    private let holder = Holder()

    init(in view: NoteTextView) {
        controller.view.backgroundColor = .clear
        // It stands in the text, wherever on the screen that is.
        controller.safeAreaRegions = []
        holder.addSubview(controller.view)
        view.addSubview(holder)
    }

    /// Shows this, at a width. Says how tall it is.
    func show(_ content: AnyView, width: CGFloat) -> CGFloat {
        // As tall as it is of itself, whatever height it is offered.
        controller.rootView = AnyView(content.fixedSize(horizontal: false, vertical: true))
        let height = controller.sizeThatFits(in: CGSize(width: width, height: 10_000)).height.rounded(.up)
        holder.frame.size = CGSize(width: width, height: height)
        controller.view.frame = holder.bounds
        return height
    }

    func move(to origin: CGPoint) {
        holder.frame.origin = origin
    }

    var bottom: CGFloat { holder.frame.maxY }

    func remove() {
        holder.removeFromSuperview()
    }
}

/// What the coordinator asks of the text view, under the names every
/// platform's answers to.
extension NoteTextView {
    var noteStorage: NSTextStorage? { textStorage }
    var noteLayout: NSLayoutManager? { layoutManager }
    var noteContainer: NSTextContainer? { textContainer }
    var caret: NSRange {
        get { selectedRange }
        set { if selectedRange != newValue { selectedRange = newValue } }
    }
    /// Whether the caret is here.
    var isWriting: Bool { isFirstResponder }
    /// Whether something is being composed: marked text, not yet the note's.
    var isComposing: Bool { markedTextRange != nil }
    var shownText: String { text ?? "" }
    var containerOrigin: CGPoint { CGPoint(x: textContainerInset.left, y: textContainerInset.top) }
    var sideInset: CGFloat { textContainerInset.left }
    /// The text is drawn in views within this one, which do not hear of
    /// it otherwise: each is told.
    func redraw() {
        func tell(_ view: UIView) {
            view.setNeedsDisplay()
            for inner in view.subviews where !(inner is BlockHost.Holder) && !(inner is UIControl) { tell(inner) }
        }
        tell(self)
    }
}

/// The text view: TextKit 1, so that the layout manager can draw.
public final class NoteTextView: UITextView {
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
    /// How many times the caret came or went that the app has yet to hear of.
    var focusReports = 0
    /// The text's storage, which nothing else keeps.
    private var kept: NSTextStorage?
    private var touches: Touches?
    /// What a finger does to a row: holds it, carries it, chooses it.
    var hands: RowHands?
    private var laidWidth: CGFloat = 0

    static func make() -> NoteTextView {
        let storage = NSTextStorage()
        let manager = BodyLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let view = NoteTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 20), textContainer: container)
        view.kept = storage
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.adjustsFontForContentSizeCategory = false
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        view.unbindContainer()
        let touches = Touches(view)
        view.touches = touches
        view.hands = RowHands(view)
        return view
    }

    /// Whether a recognizer is the view's own — its tap, its swipe — not the text view's.
    func isOwn(_ gesture: UIGestureRecognizer) -> Bool { gesture.delegate === touches }

    /// While rows are being chosen, there is no typing.
    public override var canBecomeFirstResponder: Bool { hands?.isChoosing != true && super.canBecomeFirstResponder }

    /// The text's room is as tall as the text needs, never as short as
    /// the view happens to be. A text view that does not scroll would have
    /// its container no taller than itself — and a view only as tall as an
    /// empty note then has no room for the first line typed in it, which
    /// is not laid out, and so never makes the view any taller.
    private func unbindContainer() {
        let container = textContainer
        if container.heightTracksTextView { container.heightTracksTextView = false }
        if container.size.height < 1e7 { container.size = CGSize(width: container.size.width, height: .greatestFiniteMagnitude) }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let (container, manager) = (textContainer, layoutManager)
        unbindContainer()
        if abs(container.size.width - width) > 0.5 {
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
        var used = manager.usedRect(for: container).height
        // An empty last line is the caret's to wait on.
        used = max(used, manager.extraLineFragmentRect.maxY)
        let size = (manager as? BodyLayoutManager)?.theme.size ?? 14
        return max((used + textContainerInset.top + textContainerInset.bottom).rounded(.up), (size * 1.5).rounded(.up), (blocksBottom + textContainerInset.bottom).rounded(.up))
    }

    // The view is as tall as its text and never scrolls within itself.
    // Left to, it would: a line typed makes the text taller a moment
    // before the app makes the view so, the caret is brought into view
    // by scrolling the text up a line — and there it stays, its first
    // line out of sight above the view, once the view has grown.

    public override var contentOffset: CGPoint {
        get { super.contentOffset }
        set { if super.contentOffset != .zero { super.contentOffset = .zero } }
    }

    public override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if super.contentOffset != .zero { super.setContentOffset(.zero, animated: false) }
    }

    /// What scrolls is the page the view is on: it is asked to show the caret.
    public override func scrollRangeToVisible(_ range: NSRange) {
        guard isFirstResponder, let start = position(from: beginningOfDocument, offset: min(NSMaxRange(range), textStorage.length)) else { return }
        var ancestor = superview
        while let now = ancestor, !(now is UIScrollView) { ancestor = now.superview }
        guard let page = ancestor as? UIScrollView else { return }
        let caret = caretRect(for: start).insetBy(dx: 0, dy: -8)
        page.scrollRectToVisible(convert(caret, to: page), animated: false)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        unbindContainer()
        // At another width the app's own views have other room, and the text another height.
        guard abs(bounds.width - laidWidth) > 0.5 else { return }
        laidWidth = bounds.width
        DispatchQueue.main.async { [weak self] in
            guard let self, self.coordinator?.isApplying == false, !self.isComposing else { return }
            self.coordinator?.restyle()
            self.hands?.showChosen()
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { hands?.letGo() }
        guard window != nil, coordinator?.parent.isWriting == true, !isFirstResponder, focusReports == 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.isFirstResponder, self.coordinator?.parent.isWriting == true else { return }
            self.becomeFirstResponder()
        }
    }

    // MARK: Words said into the note

    /// Whether the caret is put away: while words are said, a bar of light stands for it.
    var hidesCaret = false {
        didSet {
            guard hidesCaret != oldValue else { return }
            // Asked again where the caret is: nowhere, or where it was.
            let kept = selectedRange
            selectedRange = kept
            setNeedsLayout()
        }
    }

    var dictationAccent: UIColor { coordinator?.parent.theme.accent ?? tintColor }

    /// Where a caret before a character would stand, in the view.
    func caretBar(at location: Int) -> CGRect? {
        guard location <= textStorage.length, let place = position(from: beginningOfDocument, offset: location) else { return nil }
        return standingCaret(for: place)
    }

    public override func draw(_ rect: CGRect) {
        super.draw(rect)
        (layoutManager as? BodyLayoutManager)?.drawEmptyRow(at: CGPoint(x: textContainerInset.left, y: textContainerInset.top))
    }

    /// Writes words in place of some of the note's, as if typed: what is said, as it is heard.
    func write(_ words: String, in range: NSRange) {
        guard NSMaxRange(range) <= textStorage.length, let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length), let place = textRange(from: start, to: end) else { return }
        replace(place, withText: words)
    }

    public override func caretRect(for position: UITextPosition) -> CGRect {
        hidesCaret ? .zero : standingCaret(for: position)
    }

    /// The caret on an empty last row stands where that row's words will.
    private func standingCaret(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        let at = offset(from: beginningOfDocument, to: position)
        let text = textStorage.string as NSString
        guard at == text.length, at == 0 || text.character(at: at - 1) == 10, let indent = coordinator?.emptyRowIndent(at: at) else { return rect }
        rect.origin.x = textContainerInset.left + indent
        return rect
    }

    // MARK: "Title", at the first line's end

    private var titleChip: UIButton?

    func showTitleChip(after point: CGPoint) {
        let chip = titleChip ?? {
            // Quiet: a word at the line's end, not a button asking.
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            configuration.imagePadding = 3
            configuration.attributedTitle = AttributedString("Title", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13, weight: .medium)]))
            configuration.baseForegroundColor = .tertiaryLabel
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            let chip = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.coordinator?.parent.onTitle() })
            chip.accessibilityLabel = "Make this line the title"
            addSubview(chip)
            titleChip = chip
            return chip
        }()
        let size = chip.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        // The words begin where the Mac's do; the room to touch around them reaches back to the line.
        var x = point.x - 6
        if x + size.width > bounds.width { x = max(0, bounds.width - size.width) }
        let frame = CGRect(x: x.rounded(), y: (point.y - size.height / 2).rounded(), width: size.width, height: size.height)
        if chip.frame != frame { chip.frame = frame }
        if chip.isHidden { chip.isHidden = false }
    }

    func hideTitleChip() {
        if titleChip?.isHidden == false { titleChip?.isHidden = true }
    }

    // MARK: The tools over the keys

    private var madeBar: EditorKeyboardBar?

    /// The bar, if the keys have ever come up.
    var bar: EditorKeyboardBar? { madeBar }

    /// Made the first time the keys come up: a page has many editors, few
    /// ever typed in.
    public override var inputAccessoryView: UIView? {
        get {
            if madeBar == nil {
                madeBar = EditorKeyboardBar(tint: tintColor) { [weak self] tool in self?.use(tool) }
                // The microphone shows whether this note is being said into.
                NotificationCenter.default.addObserver(forName: NoteDictation.changed, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.madeBar?.showDictating(NoteDictation.isGoing(in: self))
                    }
                }
                showTools()
                noteSettled()
            }
            return madeBar
        }
        set {}
    }

    /// The bar as the app now has it: its colour, and whether a title is offered.
    func showTools() {
        guard let madeBar, let parent = coordinator?.parent else { return }
        madeBar.tint = parent.theme.accent
        madeBar.offersTitle = parent.offersTitle
    }

    /// After the note changed: whether there is anything to take back, or to do again.
    func noteSettled() {
        hands?.showChosen()
        guard let madeBar, let editor = coordinator?.parent.editor else { return }
        madeBar.showUndo(canUndo: editor.canUndo(), canRedo: editor.canRedo())
        showFold()
    }

    /// The bar's Fold, as the caret's row has it: Unfold for a row
    /// folded, dimmed for one with nothing under it; and no part of the
    /// bar for a note shown as text.
    func showFold() {
        guard let madeBar, let coordinator else { return }
        madeBar.isOutline = coordinator.shownMode == .outline
        let row = coordinator.caretRow.flatMap { coordinator.layout.lines.indices.contains($0) ? coordinator.layout.lines[$0] : nil }
        madeBar.showFold(folded: row?.isFolded == true, foldable: row?.hasChildren == true)
    }

    private func use(_ tool: EditorKeyboardBar.Tool) {
        guard let coordinator else { return }
        switch tool {
        case .undo: coordinator.undo()
        case .redo: coordinator.redo()
        case .command(let command): coordinator.perform(command)
        case .link: coordinator.insertLink()
        case .fold:
            if let row = coordinator.caretRow { coordinator.perform(.toggleFold, onRows: [row]) }
        case .title: coordinator.parent.onTitle()
        case .dictate:
            // Said where the caret is, until the microphone is tapped again.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if NoteDictation.isGoing(in: self) { await NoteDictation.stop() } else { await NoteDictation.start(in: self) }
            }
        case .done:
            if NoteDictation.isGoing(in: self) { Task { @MainActor in await NoteDictation.stop() } }
            resignFirstResponder()
        }
        noteSettled()
    }

    // MARK: Taps and swipes

    /// What a tap at a point of the view is on, that is not the text's to take.
    enum Target {
        case lead
        case task(Int)
        case link(EditorLink)
        /// A folded row's pill, or the bullet of a row with rows under
        /// it: the row, among the note's lines.
        case fold(Int)
        /// While rows are being chosen: any row.
        case choice(Int)
    }

    func containerPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
    }

    func target(at point: CGPoint) -> Target? {
        guard let manager = layoutManager as? BodyLayoutManager else { return nil }
        let place = containerPoint(point)
        // Choosing rows: a tap anywhere on a row takes it in, or out.
        if hands?.isChoosing == true { return manager.row(at: place, in: textContainer).map { .choice($0) } }
        if manager.isLead(at: place) { return .lead }
        if let task = manager.task(at: place, in: textContainer) { return .task(task) }
        if let row = manager.foldPill(at: place) { return .fold(row) }
        // A bullet with rows under it folds them; one with none does nothing, and is the text's.
        if let row = manager.marker(at: place, in: textContainer), manager.lines[row].hasChildren { return .fold(row) }
        if let link = manager.link(at: place, in: textContainer) { return .link(link) }
        return nil
    }

    /// The row of the outline at a point of the view: its place among
    /// the note's lines.
    func row(at point: CGPoint) -> Int? {
        (layoutManager as? BodyLayoutManager)?.row(at: containerPoint(point), in: textContainer)
    }

    /// The box some rows take, in the view.
    func frame(ofRows rows: ClosedRange<Int>) -> CGRect {
        guard let manager = layoutManager as? BodyLayoutManager else { return .zero }
        let frame = manager.frame(ofRows: rows)
        return frame.width > 0 ? frame.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top) : .zero
    }

    /// Where in the text the row under a point of the view is.
    func place(at point: CGPoint) -> Int? {
        guard textStorage.length > 0 else { return 0 }
        let inContainer = containerPoint(point)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// Whether a touch is on something laid over the text — the app's
    /// own view in place of a block, or a button — and so is not the text's.
    func isOverText(_ touched: UIView?) -> Bool {
        var view = touched
        while let now = view, now !== self {
            if now is BlockHost.Holder || now is UIControl { return false }
            view = now.superview
        }
        return true
    }

    /// Whether a point is where the caret is held to be dragged.
    func isByCaret(_ point: CGPoint) -> Bool {
        guard isFirstResponder, let range = selectedTextRange else { return false }
        return caretRect(for: range.start).insetBy(dx: -22, dy: -12).contains(point)
    }

    func tapped(at point: CGPoint) {
        guard let target = target(at: point) else { return }
        switch target {
        case .lead: coordinator?.parent.onLead()
        case .task(let place):
            coordinator?.perform(.toggleCheckbox, at: place)
            UISelectionFeedbackGenerator().selectionChanged()
        case .link(let link): coordinator?.parent.onFollow(link)
        case .fold(let row):
            coordinator?.perform(.toggleFold, onRows: [row])
            UISelectionFeedbackGenerator().selectionChanged()
        case .choice(let row): hands?.toggleChosen(row)
        }
        noteSettled()
    }

    // MARK: A link's card

    /// The card shown of a link held, as the Mac shows it of one the pointer rests on.
    private weak var linkCard: UIViewController?

    /// Shows a link's card, by it, if the app has one for it.
    func showCard(of link: EditorLink, at point: CGPoint) {
        guard let content = coordinator?.parent.linkPreview(link), let presenter = presenter() else { return }
        let card = UIHostingController(rootView: content.background(Color(uiColor: .secondarySystemBackground)))
        card.view.backgroundColor = .secondarySystemBackground
        card.modalPresentationStyle = .popover
        // Its size as it is drawn — and drawn again, as what is known of the page comes in.
        card.sizingOptions = .preferredContentSize
        if let popover = card.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = CGRect(x: point.x - 1, y: point.y - 12, width: 2, height: 24)
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = PopoverStaysSmall.shared
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        presenter.present(card, animated: true)
        linkCard = card
        NotificationCenter.default.addObserver(self, selector: #selector(cardDone(_:)), name: NoteEditorView.hoverCardDone, object: nil)
    }

    @objc private func cardDone(_ note: Notification) {
        NotificationCenter.default.removeObserver(self, name: NoteEditorView.hoverCardDone, object: nil)
        linkCard?.dismiss(animated: true)
    }

    /// What presents over the view: its window's topmost controller.
    private func presenter() -> UIViewController? {
        var top = window?.rootViewController
        while let shown = top?.presentedViewController, !shown.isBeingDismissed { top = shown }
        return top
    }

    // MARK: Pictures, and an address, pasted

    /// Paste offered for pictures too: a text view takes only text.
    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    /// An address pasted onto words links them; pictures pasted — when
    /// there is no text with them — are the app's to keep, and are
    /// written where the caret is; anything else is pasted as ever.
    public override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if selectedRange.length > 0, let words = board.string, coordinator?.link(to: words) == true { return }
        guard board.hasImages, !board.hasStrings, coordinator?.insert(pictures: Self.pictures(on: board)) == true else { return super.paste(sender) }
    }

    /// Each picture on the pasteboard, as its own bytes when they are of
    /// a kind a note keeps — PNG, JPEG, GIF — else made a JPEG: a photo's HEIC.
    private static func pictures(on board: UIPasteboard) -> [EditorPastedPicture] {
        let kept: [(UTType, String)] = [(.png, "png"), (.jpeg, "jpg"), (.gif, "gif")]
        return (0..<board.numberOfItems).compactMap { index in
            let item = IndexSet(integer: index)
            // The bytes as they are, not as UIKit hands pictures back.
            for (type, fileExtension) in kept {
                if let data = board.data(forPasteboardType: type.identifier, inItemSet: item)?.first { return EditorPastedPicture(data: data, fileExtension: fileExtension) }
            }
            for type in board.types(forItemSet: item)?.first ?? [] where UTType(type)?.conforms(to: .image) == true {
                if let data = board.data(forPasteboardType: type, inItemSet: item)?.first, let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) {
                    return EditorPastedPicture(data: jpeg, fileExtension: "jpg")
                }
            }
            return nil
        }
    }

    /// A row swiped right goes in a level; left, out.
    func swiped(from point: CGPoint, right: Bool) {
        guard let place = place(at: point), coordinator?.shiftRow(right ? .indent : .outdent, at: place) == true else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        noteSettled()
    }

    // MARK: Keys

    // What the keys do is the note's; what it has no part in is the text view's own.

    /// Undo is the note's own: it puts structure back, which text alone cannot.
    public override var undoManager: UndoManager? { nil }

    public override func deleteBackward() {
        if coordinator?.perform(.deleteBackward) != true { super.deleteBackward() }
    }

    private static let keys: [(input: String, flags: UIKeyModifierFlags, name: String)] = [
        ("\t", [], "tab"), ("\t", [.shift], "backtab"),
        ("z", [.command], "undo"), ("z", [.command, .shift], "redo"),
        ("b", [.command], "bold"), ("i", [.command], "italic"),
        ("h", [.command, .shift], "highlight"), ("k", [.command, .shift], "deleteRows"), ("d", [.command, .shift], "duplicateRows"),
        ("8", [.command, .shift], "bullet"), ("9", [.command], "fold"), ("0", [.command], "unfold"),
        ("\r", [.command], "cycleChecklist"), ("\r", [.command, .shift], "toggleTask"),
        (UIKeyCommand.inputUpArrow, [.command, .control], "moveUp"), (UIKeyCommand.inputDownArrow, [.command, .control], "moveDown"),
        (UIKeyCommand.inputRightArrow, [.command, .control], "indent"), (UIKeyCommand.inputLeftArrow, [.command, .control], "outdent"),
        (UIKeyCommand.inputEscape, [], "escape"),
    ]

    private static let commands: [String: EditCommand] = [
        "bold": .bold, "italic": .italic, "highlight": .highlight, "deleteRows": .deleteRows, "duplicateRows": .duplicateRows,
        "bullet": .bullet, "cycleChecklist": .cycleChecklist, "toggleTask": .toggleTask,
        "moveUp": .moveUp, "moveDown": .moveDown, "indent": .indent, "outdent": .outdent, "fold": .fold, "unfold": .unfold,
    ]

    private lazy var madeKeys: [UIKeyCommand] = Self.keys.map { key in
        let command = UIKeyCommand(title: "", action: #selector(keyed(_:)), input: key.input, modifierFlags: key.flags, propertyList: key.name)
        // Before the text view's own: Tab is a level, not a character; ⌘B the note's bold.
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    public override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + madeKeys
    }

    @objc private func keyed(_ key: UIKeyCommand) {
        guard let coordinator, let name = key.propertyList as? String else { return }
        switch name {
        case "tab":
            if coordinator.acceptOffer() { break }
            if !coordinator.perform(.indent) { insertText("\t") }
        case "backtab":
            coordinator.perform(.outdent)
        case "undo":
            coordinator.undo()
        case "redo":
            coordinator.redo()
        case "escape":
            if coordinator.isOffering { coordinator.dismissOffers() } else { resignFirstResponder() }
        default:
            if let command = Self.commands[name] { coordinator.perform(command) }
        }
        noteSettled()
    }
}

/// A popover kept a popover on a phone, not made a sheet.
@MainActor
private final class PopoverStaysSmall: NSObject, UIPopoverPresentationControllerDelegate {
    static let shared = PopoverStaysSmall()
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
}

/// The view's own touches: a tap on a link, a box, a bullet with rows
/// under it or the lead, and a swipe along a row. Apart from the text
/// view, which has touches of its own to answer for; a row held is
/// `RowHands`'.
@MainActor
private final class Touches: NSObject, UIGestureRecognizerDelegate {
    private weak var view: NoteTextView?
    private let tap = UITapGestureRecognizer()
    /// A link held: its card shown.
    private let hold = UILongPressGestureRecognizer()
    private let swipe = UIPanGestureRecognizer()
    private var swipeStart = CGPoint.zero
    private var swipeDone = false

    init(_ view: NoteTextView) {
        self.view = view
        super.init()
        tap.addTarget(self, action: #selector(tapped(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        hold.minimumPressDuration = 0.4
        hold.addTarget(self, action: #selector(held(_:)))
        hold.delegate = self
        view.addGestureRecognizer(hold)
        swipe.addTarget(self, action: #selector(swiped(_:)))
        swipe.maximumNumberOfTouches = 1
        swipe.delegate = self
        view.addGestureRecognizer(swipe)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let view else { return }
        view.tapped(at: gesture.location(in: view))
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let view else { return }
        let point = gesture.location(in: view)
        if case .link(let link) = view.target(at: point) { view.showCard(of: link, at: point) }
    }

    /// Whether a point is on a link, to be held.
    private func isLink(at point: CGPoint) -> Bool {
        guard let view, view.hands?.isChoosing != true, case .link = view.target(at: point) else { return false }
        return true
    }

    @objc private func swiped(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        let moved = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            let now = gesture.location(in: view)
            swipeStart = CGPoint(x: now.x - moved.x, y: now.y - moved.y)
            swipeDone = false
        case .changed, .ended:
            // Once, as it passes far enough along the row.
            guard !swipeDone, abs(moved.x) > abs(moved.y) * 1.4, abs(moved.x) > 36 else { return }
            swipeDone = true
            view.swiped(from: swipeStart, right: moved.x > 0)
        default:
            break
        }
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view, view.isOverText(touch.view) else { return false }
        let point = touch.location(in: view)
        // A tap is this one's only on a link, a box or the lead: any other is the text view's, at once.
        if gesture === tap { return view.target(at: point) != nil }
        if gesture === hold { return isLink(at: point) }
        // A row is swiped only while it is written in; elsewhere a swipe is the app's.
        return view.isFirstResponder && view.selectedRange.length == 0 && !view.isByCaret(point) && view.hands?.isCarrying != true
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let view else { return false }
        if gesture === tap { return view.target(at: gesture.location(in: view)) != nil }
        if gesture === hold { return isLink(at: gesture.location(in: view)) }
        guard view.isFirstResponder, !view.isComposing else { return false }
        // Along the row, not up or down the page: that is the page's to scroll.
        let speed = swipe.velocity(in: view)
        return abs(speed.x) > abs(speed.y) * 1.4
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard let view, other !== tap, other !== swipe, other !== hold, let theirs = other.view else { return false }
        // The text view's own presses — the loupe, choosing words — wait on a link's being held.
        if gesture === hold { return theirs.isDescendant(of: view) && !(other is RowHold) }
        // The text view's own wait for the tap: a link followed does not also take the caret.
        // (Not a row's being held: that begins while a tap could still come, and ends it.)
        if gesture === tap { return theirs.isDescendant(of: view) && !(other is RowHold) }
        // What scrolls the page waits to see that this is no swipe along a row — which it sees at once.
        return other is UIPanGestureRecognizer && theirs is UIScrollView && theirs !== view && view.isDescendant(of: theirs)
    }
}
#endif
