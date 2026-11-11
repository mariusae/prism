import Prism
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The editor's work, which is the same on every platform: what was typed
// is handed to the note, the view is made to show what the note then
// says, and it is dressed as what it means. What it asks of the text view
// — an `NSTextView` on the Mac, a `UITextView` on a phone — each
// `NoteTextView` answers under the same names (`noteStorage`, `caret`,
// `isWriting`, …), beside the view itself.
extension NoteEditorView {
    @MainActor
    public final class Coordinator: NSObject {
        var parent: NoteEditorView
        weak var view: NoteTextView?
        /// What the editor shows, as the view last agreed it with it.
        private(set) var shown = ""
        var shownMode: EditorMode = .text
        private(set) var layout = BodyLayout(lines: [], runs: [], markersInText: true)
        private var revealed = Set<Int>()
        private(set) var isApplying = false

        init(_ parent: NoteEditorView) { self.parent = parent }

        var editor: NoteEditor { parent.editor }

        /// Whether the view shows something the note has yet to take: so
        /// between a change in it and `typed`.
        var isBehind: Bool { view.map { $0.shownText != shown } ?? false }

        // MARK: Folds

        /// The rows folded, as the app last heard of them — or was last
        /// heard from.
        private var knownFolds: [EditorFoldedRow] = []
        /// What the app was told of the folds and has yet to say back:
        /// said back, it is no news.
        private var toldFolds: [[EditorFoldedRow]] = []

        /// Folds the rows the app says are folded. Says whether what the
        /// note shows changed, and so must be shown again. An app that
        /// only now says back what it was told a moment ago — the rows
        /// folded since, the words typed since — is not obeyed: the note
        /// is ahead of it.
        func takeFolds(anew: Bool) -> Bool {
            let rows = parent.foldedRows
            if !anew, let echo = toldFolds.firstIndex(of: rows) {
                toldFolds.removeFirst(echo + 1)
                return false
            }
            toldFolds.removeAll()
            let changed = editor.setFoldedRows(rows: rows)
            knownFolds = editor.foldedRows()
            return changed
        }

        /// Tells the app which rows are folded, when that is no longer
        /// what it knows: one was folded, or the note changed around one.
        private func tellFolds() {
            let now = editor.foldedRows()
            guard now != knownFolds else { return }
            knownFolds = now
            toldFolds.append(now)
            if toldFolds.count > 16 { toldFolds.removeFirst() }
            parent.onFolds(now)
        }

        /// Shows the editor's note from scratch.
        func load() {
            guard let view, let storage = view.noteStorage else { return }
            shown = editor.text()
            shownMode = editor.mode()
            if storage.string != shown {
                isApplying = true
                let caret = min(view.caret.location, (shown as NSString).length)
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: shown)
                view.caret = NSRange(location: caret, length: 0)
                isApplying = false
            }
            restyle()
        }

        /// Dresses the text again, as the editor reads it.
        func restyle() {
            guard let view, let storage = view.noteStorage, let manager = view.noteLayout as? BodyLayoutManager else { return }
            let styler = BodyStyler(theme: parent.theme, pageExists: parent.pageExists, linkLabel: parent.linkLabel)
            layout = editor.layout()
            let writing = view.isWriting
            revealed = writing ? BodyStyler.revealed(layout, selection: view.caret) : []
            let outline = !layout.markersInText
            let marks = outline ? editor.timeMarks(twelveHour: Self.clockIsTwelveHour) : []
            isApplying = true
            manager.theme = parent.theme
            manager.lines = outline ? layout.lines : []
            manager.marks = marks
            manager.written = revealed
            manager.isToday = parent.isToday
            manager.lead = parent.lead
            if let first = layout.lines.first, case .item(let number, let done, _) = first.kind, number == nil, done == nil, first.depth <= 1 {
                manager.leadStart = Int(first.start)
            } else {
                manager.leadStart = nil
            }
            styler.style(storage, layout: layout, revealed: revealed, marks: marks)
            let replaced = placeBlocks(in: view, storage: storage)
            // A row an app's view stands in place of has no mark of its own to draw.
            manager.rows = layout.markersInText ? [] : layout.lines.enumerated().filter { !replaced.contains($0.offset) }.map(\.element)
            view.typingAttributes = typingAttributes(styler)
            isApplying = false
            view.redraw()
            reportHeight()
            placeTitleChip()
        }

        /// Whether the clock here tells the time in twelve hours.
        private static var clockIsTwelveHour: Bool {
            (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
        }

        // MARK: The first line, offered as the title

        /// The first line with words, if the note is one to be titled by it.
        private var titleLine: BodyLine? {
            guard parent.offersTitle, editor.firstLine() != nil else { return nil }
            return layout.lines.first { $0.kind != .blank }
        }

        /// Whether Return here should make the first line the title: at
        /// the end of a first line written as a heading.
        func titlesByReturn() -> Bool {
            guard let view, let line = titleLine, case .heading(let level) = line.kind, level == 1 else { return false }
            let selection = view.caret
            return selection.length == 0 && selection.location == Int(line.end)
        }

        /// Shows "Title" at the first line's end while the caret is in
        /// that line, and puts it away otherwise.
        func placeTitleChip() {
            guard let view else { return }
            guard let line = titleLine, view.isWriting, line.end > line.start,
                  view.caret.length == 0, (Int(line.start)...Int(line.end)).contains(view.caret.location),
                  let manager = view.noteLayout, let container = view.noteContainer
            else { return view.hideTitleChip() }
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: Int(line.start), length: Int(line.end - line.start)), actualCharacterRange: nil)
            guard glyphs.length > 0 else { return view.hideTitleChip() }
            manager.ensureLayout(forGlyphRange: glyphs)
            let last = NSMaxRange(glyphs) - 1
            let used = manager.lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil)
            let end = manager.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: container)
            view.showTitleChip(after: CGPoint(x: end.maxX + view.containerOrigin.x + 8, y: used.midY + view.containerOrigin.y))
        }

        // MARK: Blocks drawn by the app

        private var hosts: [String: BlockHost] = [:]

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
            // A line that is only pictures — one, or several — in either mode.
            for (index, line) in layout.lines.enumerated() where line.kind != .fence && line.kind != .code {
                let range = NSRange(location: Int(line.content), length: max(Int(line.end) - Int(line.content), 0))
                guard range.length > 4, NSMaxRange(range) <= text.length else { continue }
                let words = part(range)
                guard words.contains("!["), EditorPicture.all(line: words) != nil else { continue }
                let block = EditorBlock(info: EditorBlock.picture, source: words) { [weak self] rewritten in self?.rewrite(line: index, as: rewritten) }
                found.append((block, index...index, NSRange(location: Int(line.start), length: Int(line.end - line.start))))
            }
            return found
        }

        /// Writes other words on a line, in place of its own: a picture's new size.
        private func rewrite(line index: Int, as words: String) {
            guard layout.lines.indices.contains(index), let view, !view.isComposing else { return }
            let line = layout.lines[index]
            var edit = editor.replace(start: line.content, end: line.end, replacement: words)
            // The caret stays where it was: nothing was typed.
            let kept = view.caret
            edit.selectionStart = UInt32(kept.location)
            edit.selectionEnd = UInt32(NSMaxRange(kept))
            settle(edit)
        }

        /// Puts the app's views where the blocks they stand for are
        /// written, and folds those blocks' own lines away under them.
        @discardableResult
        private func placeBlocks(in view: NoteTextView, storage: NSTextStorage) -> Set<Int> {
            guard let manager = view.noteLayout, let container = view.noteContainer else { return [] }
            var replaced = Set<Int>()
            var used = Set<String>()
            var placed: [(host: BlockHost, range: NSRange)] = []
            let width = max(view.bounds.width - view.sideInset * 2, 120)
            for (index, found) in blocks(in: storage.string as NSString).enumerated() {
                var block = found.block
                block.room = width
                block.resized = { [weak self] in self?.restyle() }
                guard !found.lines.contains(where: revealed.contains), let content = parent.blockView(block) else { continue }
                let key = "\(index)|\(found.block.info)|\(found.block.info == EditorBlock.picture ? found.block.source : "")"
                used.insert(key)
                replaced.formUnion(found.lines)
                let host = hosts[key] ?? {
                    let host = BlockHost(in: view)
                    hosts[key] = host
                    return host
                }()
                let height = host.show(AnyView(content.frame(width: width, alignment: .leading)), width: width)
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
                host.remove()
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
                host.move(to: CGPoint(x: view.containerOrigin.x, y: view.containerOrigin.y + line.maxY + 4))
                bottom = max(bottom, host.bottom)
            }
            view.blocksBottom = bottom
            return replaced
        }

        /// What is typed next takes the look of the line it is typed on.
        private func typingAttributes(_ styler: BodyStyler) -> [NSAttributedString.Key: Any] {
            guard let view, let storage = view.noteStorage else { return styler.baseAttributes }
            var attributes = styler.baseAttributes
            let caret = view.caret.location
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

        /// Takes what the view now shows that the note does not: called
        /// when the text view says its text changed.
        func typed() {
            guard !isApplying, let view, !view.isComposing else { return }
            let now = view.shownText as NSString
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
            // Something put in where the same could have been put in a little earlier — a line break
            // after a line break: where the caret is says which, for it stands just after what was put in.
            let added = now.length - was.length
            let caret = view.caret.location
            if added > 0, prefix + suffix == was.length, view.caret.length == 0, caret < prefix + added, caret >= added,
               was.isEqual(to: now.replacingCharacters(in: NSRange(location: caret - added, length: added), with: "")) {
                prefix = caret - added
                suffix = was.length - prefix
            }
            let typed = now.substring(with: NSRange(location: prefix, length: now.length - prefix - suffix))
            let edit = editor.replace(start: UInt32(prefix), end: UInt32(was.length - suffix), replacement: typed)
            settle(edit)
        }

        /// After the editor took a change: the view is made to show what
        /// the editor now does, which is usually what it already shows.
        func settle(_ edit: BodyEdit?) {
            guard let view, let storage = view.noteStorage else { return }
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
                view.caret = NSRange(location: start, length: min(Int(edit.selectionEnd), length) - start)
                isApplying = false
            }
            restyle()
            view.scrollRangeToVisible(view.caret)
            parent.onChange()
            tellFolds()
            updateOffers()
            #if os(iOS)
            view.noteSettled()
            #endif
        }

        // MARK: An outline's rows

        /// The row the caret is in: its place among the note's lines.
        /// `nil` for a note shown as text.
        var caretRow: Int? {
            guard let view, !layout.markersInText else { return nil }
            let caret = view.caret.location
            return layout.lines.lastIndex { Int($0.start) <= caret }
        }

        /// Carries out a command on some rows of an outline — lines of
        /// the note, counted from the first — wherever the caret is, which
        /// stays with its words. Says whether there was anything to do.
        @discardableResult
        func perform(_ command: EditCommand, onRows rows: [Int]) -> Bool {
            guard let view, !view.isComposing, !rows.isEmpty else { return false }
            let kept = view.caret
            guard let edit = editor.performOn(rows: rows.map { UInt32($0) }, selectionStart: UInt32(kept.location), selectionEnd: UInt32(NSMaxRange(kept)), command: command) else { return false }
            settle(edit)
            return true
        }

        /// Puts rows before another, at a depth: where they were carried
        /// to. Says whether that moved them.
        @discardableResult
        func moveRows(_ rows: [Int], before: Int, depth: Int) -> Bool {
            guard let view, !view.isComposing, !rows.isEmpty else { return false }
            let kept = view.caret
            guard let edit = editor.moveRows(rows: rows.map { UInt32($0) }, before: UInt32(before), depth: UInt32(depth), selectionStart: UInt32(kept.location), selectionEnd: UInt32(NSMaxRange(kept))) else { return false }
            settle(edit)
            return true
        }

        /// A time block from now, a quarter of an hour long, to name.
        @discardableResult
        func newTimeBlock() -> Bool {
            guard let view, !view.isComposing else { return false }
            let time = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let selection = view.caret
            guard let edit = editor.newTimeBlock(selectionStart: UInt32(selection.location), selectionEnd: UInt32(NSMaxRange(selection)), now: UInt32((time.hour ?? 0) * 60 + (time.minute ?? 0))) else { return false }
            settle(edit)
            return true
        }

        /// Hands some rows to the app to put in another note; taken out
        /// of this one when the app says it has them — if they are still
        /// as they were handed over.
        func moveElsewhere(_ rows: [Int]) {
            guard let move = parent.onMoveRows, !rows.isEmpty else { return }
            let markdown = editor.markdownOf(rows: rows.map { UInt32($0) })
            guard !markdown.isEmpty else { return }
            move(markdown) { [weak self] in
                guard let self, self.editor.markdownOf(rows: rows.map { UInt32($0) }) == markdown else { return }
                self.perform(.deleteRows, onRows: rows)
            }
        }

        // MARK: Pictures, and an address, pasted

        /// Has the app keep pictures pasted or dropped, and writes them
        /// where the caret is — or at a place: where they were let go.
        /// Says whether the app took them.
        @discardableResult
        func insert(pictures: [EditorPastedPicture], at place: Int? = nil) -> Bool {
            guard let view, !view.isComposing, !pictures.isEmpty else { return false }
            let paths = parent.savePictures(pictures)
            guard !paths.isEmpty else { return false }
            let written = paths.map { "![](\($0))" }.joined(separator: " ")
            let range = place.map { NSRange(location: $0, length: 0) } ?? view.caret
            settle(editor.replace(start: UInt32(range.location), end: UInt32(NSMaxRange(range)), replacement: written))
            return true
        }

        /// An address pasted onto the words selected: they link to it.
        /// Says whether it was an address, and words to link.
        func link(to pasted: String) -> Bool {
            guard let view, !view.isComposing, view.caret.length > 0, let address = webAddress(text: pasted) else { return false }
            let selection = view.caret
            guard let edit = editor.link(selectionStart: UInt32(selection.location), selectionEnd: UInt32(NSMaxRange(selection)), address: address) else { return false }
            settle(edit)
            return true
        }

        // MARK: A link being typed, and the pages offered for it

        private(set) var offering: (found: BodyCompletion, offers: [EditorOffer], chosen: Int)?
        #if os(macOS)
        /// The list under the caret: a window of its own.
        var offerList: OfferList?
        #endif
        /// Where a link was being typed when its list was put away: not
        /// offered for again until another is begun.
        private var putAway: UInt32?

        var isOffering: Bool { offering != nil }

        /// Looks at what is being typed at the caret, and lists what the app offers for it.
        func updateOffers() {
            guard let view, view.isWriting, view.caret.length == 0, !view.isComposing,
                  let found = completionAt(body: view.shownText, caret: UInt32(view.caret.location)), found.kind != .tag
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
            showOffers()
        }

        func hideOffers() {
            offering = nil
            closeOffers()
        }

        func moveOffer(by step: Int) {
            guard var now = offering, view?.window != nil else { return }
            now.chosen = (now.chosen + step + now.offers.count) % now.offers.count
            offering = now
            showOffers()
        }

        /// Takes the offer at a place in the list: the one clicked, or tapped.
        func acceptOffer(at index: Int) {
            offering?.chosen = index
            acceptOffer()
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

        /// The caret moved: the lines whose markup shows are those it is in.
        func selectionChanged() {
            guard !isApplying, let view, view.isWriting else { return }
            if BodyStyler.revealed(layout, selection: view.caret) != revealed { restyle() } else { placeTitleChip() }
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
            guard let view, !view.isComposing else { return false }
            let selection = place.map { NSRange(location: $0, length: 0) } ?? view.caret
            guard var edit = editor.perform(selectionStart: UInt32(selection.location), selectionEnd: UInt32(NSMaxRange(selection)), command: command) else { return false }
            if place != nil {
                // Done elsewhere than at the caret: the caret stays where it was.
                let kept = view.caret
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
