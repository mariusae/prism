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
        onChange: @escaping () -> Void = {}, onFocus: @escaping (Bool) -> Void = { _ in }, onFollow: @escaping (EditorLink) -> Void = { _ in }
    ) {
        self.editor = editor
        self.theme = theme
        self.isWriting = isWriting
        _height = height
        self.refresh = refresh
        self.pageExists = pageExists
        self.blockView = blockView
        self.onChange = onChange
        self.onFocus = onFocus
        self.onFollow = onFollow
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
        let looks = coordinator.parent.refresh != refresh || coordinator.parent.theme.size != theme.size || coordinator.parent.theme.isSerif != theme.isSerif
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
            manager.rows = layout.markersInText ? [] : layout.lines
            styler.style(storage, layout: layout, revealed: revealed)
            placeBlocks(in: view, storage: storage)
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
            return found
        }

        /// Puts the app's views where the blocks they stand for are
        /// written, and folds those blocks' own lines away under them.
        private func placeBlocks(in view: NoteTextView, storage: NSTextStorage) {
            guard let manager = view.layoutManager, let container = view.textContainer else { return }
            var used = Set<String>()
            var placed: [(host: NSHostingView<AnyView>, range: NSRange)] = []
            let width = max(view.bounds.width - view.textContainerInset.width * 2, 120)
            for (index, found) in blocks(in: storage.string as NSString).enumerated() {
                guard !found.lines.contains(where: revealed.contains), let content = parent.blockView(found.block) else { continue }
                let key = "\(index)|\(found.block.info)"
                used.insert(key)
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
                return
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
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplying, let view, view.window?.firstResponder === view else { return }
            if BodyStyler.revealed(layout, selection: view.selectedRange()) != revealed { restyle() }
        }

        func focusChanged(_ focused: Bool) {
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

/// The text view: TextKit 1, so that the layout manager can draw.
public final class NoteTextView: NSTextView {
    weak var coordinator: NoteEditorView.Coordinator?
    /// How far down the app's own block views reach.
    var blocksBottom: CGFloat = 0
    private var pressed: (point: CGPoint, link: EditorLink?, task: Int?)?

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
        guard let manager = layoutManager as? BodyLayoutManager, let container = textContainer else { return super.mouseDown(with: event) }
        let point = containerPoint(event)
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

    public override func resetCursorRects() {
        super.resetCursorRects()
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { return }
        storage.enumerateAttribute(.prismLink, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                self.addCursorRect(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y), cursor: .pointingHand)
            }
        }
    }

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

    public override func insertNewline(_ sender: Any?) {
        if coordinator?.perform(.newline) != true { super.insertNewline(sender) }
    }

    public override func insertTab(_ sender: Any?) {
        if coordinator?.perform(.indent) != true { super.insertTab(sender) }
    }

    public override func insertBacktab(_ sender: Any?) {
        _ = coordinator?.perform(.outdent)
    }

    public override func deleteBackward(_ sender: Any?) {
        if coordinator?.perform(.deleteBackward) != true { super.deleteBackward(sender) }
    }

    public override func cancelOperation(_ sender: Any?) {
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
