#if os(macOS)
import AppKit
import Prism
import SwiftUI

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

    /// - Parameters:
    ///   - editor: the note. Give another to show another — or the same
    ///     note read again, after its file changed underneath.
    ///   - isWriting: whether the caret should be here.
    ///   - height: kept at the height the text needs at the width given.
    ///   - refresh: any value that changes when the look should be redone.
    public init(
        editor: NoteEditor, theme: EditorTheme, isWriting: Bool, height: Binding<CGFloat>, refresh: Int = 0,
        pageExists: @escaping (String) -> Bool = { _ in true },
        blockView: @escaping (EditorBlock) -> AnyView? = { _ in nil },
        linkPreview: @escaping (EditorLink) -> AnyView? = { _ in nil },
        lead: EditorLead? = nil, onLead: @escaping () -> Void = {},
        offers: @escaping (BodyCompletion) -> [EditorOffer] = { _ in [] },
        onChange: @escaping () -> Void = {}, onFocus: @escaping (Bool) -> Void = { _ in }, onFollow: @escaping (EditorLink) -> Void = { _ in }
    ) {
        self.editor = editor
        self.theme = theme
        self.isWriting = isWriting
        _height = height
        self.refresh = refresh
        self.pageExists = pageExists
        self.blockView = blockView
        self.linkPreview = linkPreview
        self.lead = lead
        self.onLead = onLead
        self.offers = offers
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
        context.coordinator.load()
        return view
    }

    public func updateNSView(_ view: NoteTextView, context: Context) {
        let coordinator = context.coordinator
        let other = coordinator.parent.editor !== editor
        let looks = coordinator.parent.refresh != refresh || coordinator.parent.theme.size != theme.size || coordinator.parent.theme.face != theme.face || coordinator.parent.lead != lead
        coordinator.parent = self
        if other || coordinator.shownMode != editor.mode() {
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

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditorView
        weak var view: NoteTextView?
        /// What the editor shows, as the view last agreed it with it.
        private var shown = ""
        fileprivate var shownMode: EditorMode = .text
        private var layout = BodyLayout(lines: [], runs: [], markersInText: true)
        private var revealed = Set<Int>()
        private var isApplying = false

        init(_ parent: NoteEditorView) { self.parent = parent }

        private var editor: NoteEditor { parent.editor }

        /// Shows the editor's note from scratch.
        func load() {
            guard let view, let storage = view.textStorage else { return }
            shown = editor.text()
            shownMode = editor.mode()
            if storage.string != shown {
                isApplying = true
                let caret = min(view.selectedRange().location, (shown as NSString).length)
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: shown)
                view.setSelectedRange(NSRange(location: caret, length: 0))
                isApplying = false
            }
            restyle()
        }

        /// Dresses the text again, as the editor reads it.
        func restyle() {
            guard let view, let storage = view.textStorage, let manager = view.layoutManager as? BodyLayoutManager else { return }
            let styler = BodyStyler(theme: parent.theme, pageExists: parent.pageExists)
            layout = editor.layout()
            let writing = view.window?.firstResponder === view
            revealed = writing ? BodyStyler.revealed(layout, selection: view.selectedRange()) : []
            isApplying = true
            manager.theme = parent.theme
            manager.lead = parent.lead
            if let first = layout.lines.first, case .item(let number, let done, _) = first.kind, number == nil, done == nil, first.depth <= 1 {
                manager.leadStart = Int(first.start)
            } else {
                manager.leadStart = nil
            }
            styler.style(storage, layout: layout, revealed: revealed)
            let replaced = placeBlocks(in: view, storage: storage)
            // A row an app's view stands in place of has no mark of its own to draw.
            manager.rows = layout.markersInText ? [] : layout.lines.enumerated().filter { !replaced.contains($0.offset) }.map(\.element)
            view.typingAttributes = typingAttributes(styler)
            isApplying = false
            view.needsDisplay = true
            reportHeight()
        }

        // MARK: Blocks drawn by the app

        private var hosts: [String: NSHostingView<AnyView>] = [:]

        /// The fenced blocks in what is shown: each with the lines it takes.
        private func blocks(in text: NSString) -> [(block: EditorBlock, lines: ClosedRange<Int>, range: NSRange)] {
            var found: [(EditorBlock, ClosedRange<Int>, NSRange)] = []
            let part = { (range: NSRange) in text.substring(with: range) }
            if layout.markersInText {
                var opened: Int?
                for (index, line) in layout.lines.enumerated() where line.kind == .fence {
                    guard let start = opened else {
                        opened = index
                        continue
                    }
                    opened = nil
                    let first = layout.lines[start]
                    let info = part(NSRange(location: Int(first.content), length: Int(first.end - first.content))).trimmingCharacters(in: CharacterSet(charactersIn: "`~ "))
                    let bodyStart = min(Int(first.end) + 1, Int(line.start))
                    let source = part(NSRange(location: bodyStart, length: max(Int(line.start) - bodyStart - 1, 0)))
                    found.append((EditorBlock(info: info, source: source), start...index, NSRange(location: Int(first.start), length: Int(line.end - first.start))))
                }
            } else {
                // In an outline a block of code is one row, its lines parted by U+2028.
                for (index, line) in layout.lines.enumerated() where line.kind == .code {
                    let range = NSRange(location: Int(line.start), length: Int(line.end - line.start))
                    let parts = part(range).components(separatedBy: "\u{2028}")
                    guard parts.count >= 2, let first = parts.first else { continue }
                    let info = first.trimmingCharacters(in: CharacterSet(charactersIn: "`~ "))
                    found.append((EditorBlock(info: info, source: parts.dropFirst().dropLast().joined(separator: "\n")), index...index, range))
                }
            }
            // A line that is only a picture, in either mode.
            for (index, line) in layout.lines.enumerated() where line.kind != .fence && line.kind != .code {
                let range = NSRange(location: Int(line.content), length: max(Int(line.end) - Int(line.content), 0))
                guard range.length > 4, NSMaxRange(range) <= text.length else { continue }
                let words = part(range)
                guard words.contains("!["), EditorPicture(line: words) != nil else { continue }
                let block = EditorBlock(info: EditorBlock.picture, source: words) { [weak self] rewritten in self?.rewrite(line: index, as: rewritten) }
                found.append((block, index...index, NSRange(location: Int(line.start), length: Int(line.end - line.start))))
            }
            return found
        }

        /// Writes other words on a line, in place of its own: a picture's new size.
        private func rewrite(line index: Int, as words: String) {
            guard layout.lines.indices.contains(index), let view, !view.hasMarkedText() else { return }
            let line = layout.lines[index]
            var edit = editor.replace(start: line.content, end: line.end, replacement: words)
            // The caret stays where it was: nothing was typed.
            let kept = view.selectedRange()
            edit.selectionStart = UInt32(kept.location)
            edit.selectionEnd = UInt32(NSMaxRange(kept))
            settle(edit)
        }

        /// Puts the app's views where the blocks they stand for are
        /// written, and folds those blocks' own lines away under them.
        @discardableResult
        private func placeBlocks(in view: NoteTextView, storage: NSTextStorage) -> Set<Int> {
            guard let manager = view.layoutManager, let container = view.textContainer else { return [] }
            var replaced = Set<Int>()
            var used = Set<String>()
            var placed: [(host: NSHostingView<AnyView>, range: NSRange)] = []
            let width = max(view.bounds.width - view.textContainerInset.width * 2, 120)
            for (index, found) in blocks(in: storage.string as NSString).enumerated() {
                var block = found.block
                block.room = width
                guard !found.lines.contains(where: revealed.contains), let content = parent.blockView(block) else { continue }
                let key = "\(index)|\(found.block.info)|\(found.block.info == EditorBlock.picture ? found.block.source : "")"
                used.insert(key)
                replaced.formUnion(found.lines)
                let host = hosts[key] ?? {
                    let host = NSHostingView(rootView: AnyView(EmptyView()))
                    view.addSubview(host)
                    hosts[key] = host
                    return host
                }()
                host.rootView = AnyView(content.frame(width: width, alignment: .leading))
                let height = host.fittingSize.height
                host.setFrameSize(CGSize(width: width, height: height))
                // The block's own lines are folded to nothing; the room it takes is left under them.
                let folded = NSMutableParagraphStyle()
                folded.maximumLineHeight = 0.5
                folded.minimumLineHeight = 0.5
                folded.lineSpacing = 0
                let last = NSMutableParagraphStyle()
                last.setParagraphStyle(folded)
                last.paragraphSpacing = height + 12
                storage.addAttributes([.font: BodyStyler.hiddenFont, .foregroundColor: EditorColor.clear, .paragraphStyle: folded], range: found.range)
                let text = storage.string as NSString
                let final = text.paragraphRange(for: NSRange(location: NSMaxRange(found.range), length: 0))
                storage.addAttribute(.paragraphStyle, value: last, range: final.length > 0 ? final : found.range)
                placed.append((host, found.range))
            }
            for (key, host) in hosts where !used.contains(key) {
                host.removeFromSuperview()
                hosts[key] = nil
            }
            guard !placed.isEmpty else {
                view.blocksBottom = 0
                return replaced
            }
            manager.ensureLayout(for: container)
            var bottom: CGFloat = 0
            for (host, range) in placed {
                let glyph = manager.glyphIndexForCharacter(at: max(NSMaxRange(range) - 1, range.location))
                let line = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                host.setFrameOrigin(CGPoint(x: view.textContainerOrigin.x, y: view.textContainerOrigin.y + line.maxY + 4))
                bottom = max(bottom, host.frame.maxY)
            }
            view.blocksBottom = bottom
            return replaced
        }

        /// What is typed next takes the look of the line it is typed on.
        private func typingAttributes(_ styler: BodyStyler) -> [NSAttributedString.Key: Any] {
            guard let view, let storage = view.textStorage else { return styler.baseAttributes }
            var attributes = styler.baseAttributes
            let caret = view.selectedRange().location
            if let line = layout.lines.first(where: { Int($0.start) <= caret && caret <= Int($0.end) }) {
                let at = min(Int(line.start), max(storage.length - 1, 0))
                if storage.length > 0, let style = storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) { attributes[.paragraphStyle] = style }
                if !layout.markersInText, case .item = line.kind, storage.length == Int(line.start) || line.start == line.end {
                    // An empty row has no character to carry its indentation.
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.lineSpacing = 3
                    paragraph.firstLineHeadIndent = CGFloat(line.depth) * parent.theme.step
                    paragraph.headIndent = paragraph.firstLineHeadIndent
                    attributes[.paragraphStyle] = paragraph
                }
            }
            return attributes
        }

        private func reportHeight() {
            guard let view, view.bounds.width > 0 else { return }
            let height = view.height(forWidth: view.bounds.width)
            if abs(height - parent.height) > 0.5 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = height }
            }
        }

        // What was typed is the note's to take.

        public func textDidChange(_ notification: Notification) {
            guard !isApplying, let view, !view.hasMarkedText() else { return }
            let now = view.string as NSString
            let was = shown as NSString
            guard !now.isEqual(to: shown) else { return }
            // What changed in the view, as one replacement of what was shown.
            var prefix = 0
            let limit = min(now.length, was.length)
            while prefix < limit, now.character(at: prefix) == was.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < limit - prefix, now.character(at: now.length - 1 - suffix) == was.character(at: was.length - 1 - suffix) { suffix += 1 }
            // Not through the middle of a pair of surrogates.
            if prefix > 0, UTF16.isLeadSurrogate(was.character(at: prefix - 1)) { prefix -= 1 }
            if suffix > 0, UTF16.isTrailSurrogate(was.character(at: was.length - suffix)) { suffix -= 1 }
            let typed = now.substring(with: NSRange(location: prefix, length: now.length - prefix - suffix))
            let edit = editor.replace(start: UInt32(prefix), end: UInt32(was.length - suffix), replacement: typed)
            settle(edit)
        }

        /// After the editor took a change: the view is made to show what
        /// the editor now does, which is usually what it already shows.
        private func settle(_ edit: BodyEdit?) {
            guard let view, let storage = view.textStorage else { return }
            let text = editor.text()
            if storage.string != text {
                // The editor made more of it than was typed — `- ` became a bullet.
                isApplying = true
                let now = storage.string as NSString
                let want = text as NSString
                var prefix = 0
                let limit = min(now.length, want.length)
                while prefix < limit, now.character(at: prefix) == want.character(at: prefix) { prefix += 1 }
                var suffix = 0
                while suffix < limit - prefix, now.character(at: now.length - 1 - suffix) == want.character(at: want.length - 1 - suffix) { suffix += 1 }
                storage.replaceCharacters(in: NSRange(location: prefix, length: now.length - prefix - suffix), with: want.substring(with: NSRange(location: prefix, length: want.length - prefix - suffix)))
                isApplying = false
            }
            shown = text
            if let edit {
                isApplying = true
                let length = (text as NSString).length
                let start = min(Int(edit.selectionStart), length)
                view.setSelectedRange(NSRange(location: start, length: min(Int(edit.selectionEnd), length) - start))
                isApplying = false
            }
            restyle()
            view.scrollRangeToVisible(view.selectedRange())
            parent.onChange()
            updateOffers()
        }

        // MARK: A link being typed, and the pages offered for it

        private var offering: (found: BodyCompletion, offers: [EditorOffer], chosen: Int)?
        private var offerList: OfferList?
        /// Where a link was being typed when its list was put away: not
        /// offered for again until another is begun.
        private var putAway: UInt32?

        var isOffering: Bool { offering != nil }

        /// Looks at what is being typed at the caret, and lists what the app offers for it.
        func updateOffers() {
            guard let view, let window = view.window, window.firstResponder === view, view.selectedRange().length == 0, !view.hasMarkedText(),
                  let found = completionAt(body: view.string, caret: UInt32(view.selectedRange().location)), found.kind != .tag
            else {
                putAway = nil
                return hideOffers()
            }
            guard putAway != found.start else { return hideOffers() }
            let offers = Array(parent.offers(found).prefix(8))
            guard !offers.isEmpty else { return hideOffers() }
            // The same one stays chosen while the list is the same.
            let chosen = offering.flatMap { was in was.offers == offers ? was.chosen : nil } ?? 0
            offering = (found, offers, chosen)
            showOffers(in: view, window: window)
        }

        private func showOffers(in view: NoteTextView, window: NSWindow) {
            guard let offering else { return }
            let caret = view.firstRect(forCharacterRange: NSRange(location: Int(offering.found.start), length: 0), actualRange: nil)
            let content = AnyView(OfferListView(offers: offering.offers, chosen: offering.chosen) { [weak self] index in
                self?.offering?.chosen = index
                self?.acceptOffer()
            })
            if let offerList { offerList.show(content, under: caret) } else { offerList = OfferList(content: content, under: caret, over: window) }
        }

        func hideOffers() {
            offering = nil
            offerList?.close()
            offerList = nil
        }

        func moveOffer(by step: Int) {
            guard var now = offering, let view, let window = view.window else { return }
            now.chosen = (now.chosen + step + now.offers.count) % now.offers.count
            offering = now
            showOffers(in: view, window: window)
        }

        /// Writes the link to the page chosen, in place of what was typed. Says whether there was one.
        @discardableResult
        func acceptOffer() -> Bool {
            guard let now = offering, now.offers.indices.contains(now.chosen) else { return false }
            hideOffers()
            let link = (now.found.kind == .embed ? "![[" : "[[") + now.offers[now.chosen].name + "]]"
            settle(editor.replace(start: now.found.start, end: now.found.end, replacement: link))
            return true
        }

        /// Puts the list away, until another link is begun.
        func dismissOffers() {
            putAway = offering?.found.start
            hideOffers()
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplying, let view, view.window?.firstResponder === view else { return }
            if BodyStyler.revealed(layout, selection: view.selectedRange()) != revealed { restyle() }
            // The caret gone elsewhere: what was being typed there is no longer being typed.
            if isOffering { updateOffers() }
        }

        func focusChanged(_ focused: Bool) {
            if !focused { hideOffers() }
            restyle()
            parent.onFocus(focused)
        }

        /// Carries out one of the editor's commands. Says whether it had
        /// anything to do.
        @discardableResult
        func perform(_ command: EditCommand, at place: Int? = nil) -> Bool {
            guard let view, !view.hasMarkedText() else { return false }
            let selection = place.map { NSRange(location: $0, length: 0) } ?? view.selectedRange()
            guard var edit = editor.perform(selectionStart: UInt32(selection.location), selectionEnd: UInt32(NSMaxRange(selection)), command: command) else { return false }
            if place != nil {
                // Done elsewhere than at the caret: the caret stays where it was.
                let kept = view.selectedRange()
                edit.selectionStart = UInt32(kept.location)
                edit.selectionEnd = UInt32(NSMaxRange(kept))
            }
            settle(edit)
            return true
        }

        func undo() {
            if let edit = editor.undo() { settle(edit) }
        }

        func redo() {
            if let edit = editor.redo() { settle(edit) }
        }
    }
}

/// A card that floats by the pointer while it rests on a link: a small
/// window of its own, so that it lies over whatever is there, takes no
/// clicks and no keys, and is gone the moment the pointer moves on.
@MainActor
final class HoverCard {
    private let panel: NSPanel
    private weak var parent: NSWindow?
    /// Where the pointer was, on the screen.
    private let pointer: CGPoint
    private var resized: NSObjectProtocol?

    init(content: AnyView, at pointer: CGPoint, over parent: NSWindow) {
        self.pointer = pointer
        self.parent = parent
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let host = NSHostingController(rootView: content.background(.regularMaterial).clipShape(shape).overlay(shape.strokeBorder(.separator, lineWidth: 0.5)))
        // It is as large as what it shows — which may grow, as a page's picture comes in.
        host.sizingOptions = [.preferredContentSize]
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.setContentSize(host.view.fittingSize)
        place()
        resized = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        parent.addChildWindow(panel, ordered: .above)
    }

    /// Under the pointer and a little to its right; over it, where there
    /// is no room under; and never off the screen's edge.
    private func place() {
        let size = panel.frame.size
        let screen = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame ?? CGRect(origin: .zero, size: size)
        var origin = CGPoint(x: pointer.x + 10, y: pointer.y - 18 - size.height)
        if origin.y < screen.minY + 6 { origin.y = pointer.y + 14 }
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

    // MARK: A link's card, while the pointer rests on it

    private var hovered: EditorLink?
    private var hoverWork: DispatchWorkItem?
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
        if manager.isLead(at: point) || manager.task(at: point, in: container) != nil { return .box }
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
            hideCard()
            return
        }
        let point = containerPoint(event)
        let link = manager.link(at: point, in: container)
        guard link != hovered else { return }
        hovered = link
        hideCard()
        guard let link else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovered == link, let window = self.window, let content = self.coordinator?.parent.linkPreview(link) else { return }
            // By the pointer, where it has come to rest.
            self.card = HoverCard(content: content, at: NSEvent.mouseLocation, over: window)
        }
        hoverWork = work
        // Long enough that passing over a link shows nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        under = .elsewhere
        hovered = nil
        hideCard()
    }

    public override func scrollWheel(with event: NSEvent) {
        hovered = nil
        hideCard()
        coordinator?.hideOffers()
        super.scrollWheel(with: event)
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hideCard() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func hideCard() {
        hoverWork?.cancel()
        hoverWork = nil
        card?.close()
        card = nil
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
        guard let command = Self.command(flags: flags, key: key, special: event.specialKey) else { return super.performKeyEquivalent(with: event) }
        _ = coordinator?.perform(command)
        return true
    }

    /// The editor's own keys.
    private static func command(flags: NSEvent.ModifierFlags, key: String, special: NSEvent.SpecialKey?) -> EditCommand? {
        switch (flags, key) {
        case ([.command], "b"): return .bold
        case ([.command], "i"): return .italic
        case ([.command, .shift], "h"): return .highlight
        case ([.command, .shift], "k"): return .deleteRows
        case ([.command, .shift], "d"): return .duplicateRows
        case ([.command, .shift], "8"), ([.command, .shift], "*"): return .bullet
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
#endif
