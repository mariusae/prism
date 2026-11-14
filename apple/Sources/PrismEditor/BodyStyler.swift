import Foundation
import Prism

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A pill behind a link's words.
/// What a link shows in place of what is written: its page's title, where
/// the link is written with the page's file's name.
final class LinkLabel: NSObject {
    let text: NSAttributedString
    init(_ text: NSAttributedString) { self.text = text }
}

final class Pill: NSObject {
    /// An icon before the words: an internal link's page's own.
    let symbol: String?
    let tint: EditorColor
    let isMissing: Bool
    /// A small ↗ after the words: a link that leaves the graph.
    let leaves: Bool
    /// Whether the room for the ↗ is on the link's own last character — an
    /// address written bare — and so inside what its words take.
    let roomInside: Bool
    init(symbol: String?, tint: EditorColor, isMissing: Bool, leaves: Bool = false, roomInside: Bool = false) {
        self.symbol = symbol
        self.tint = tint
        self.isMissing = isMissing
        self.leaves = leaves
        self.roomInside = roomInside
    }
}

/// A task's box, drawn where its marker is written.
final class TaskBox: NSObject {
    let isDone: Bool
    let isRound: Bool
    init(isDone: Bool, isRound: Bool) {
        self.isDone = isDone
        self.isRound = isRound
    }
}

/// The link under some words: what a click follows.
final class LinkBox: NSObject {
    let target: EditorLink
    init(_ target: EditorLink) { self.target = target }
}

extension NSAttributedString.Key {
    static let prismPill = NSAttributedString.Key("prism.pill")
    static let prismLink = NSAttributedString.Key("prism.link")
    static let prismLabel = NSAttributedString.Key("prism.label")
    static let prismBullet = NSAttributedString.Key("prism.bullet")
    static let prismTask = NSAttributedString.Key("prism.task")
    static let prismQuote = NSAttributedString.Key("prism.quote")
    /// A code block's fence: its backticks drawn set down into their line.
    static let prismFence = NSAttributedString.Key("prism.fence")
}

/// Dresses what a note's editor shows as what it means.
///
/// The engine says what each line and run of the text *is*
/// (`NoteEditor.layout`); this turns that into fonts, colours, and the
/// marks the layout manager draws — pills, bullets, boxes. It knows no
/// Markdown, and it serves both ways the engine shows a note:
///
/// - as **text**, each line's marker is in the text: hidden, with a dot
///   or a box drawn in its place, except on the lines being written in,
///   where the markup shows faint;
/// - as an **outline**, a line is a row and holds only its words: what
///   the row is, is drawn in the margin beside it.
struct BodyStyler {
    var theme: EditorTheme
    /// Says whether a page of this name is there, for a link's look.
    var pageExists: (String) -> Bool = { _ in true }
    /// Whether the page a link leads to is archived: its link is drawn faint.
    var pageArchived: (String) -> Bool = { _ in false }
    /// What a page is shown as called — its title, or its first words —
    /// when that is not the name a link to it is written with: `nil`
    /// where the link already says it, or leads nowhere.
    var linkLabel: (String) -> String? = { _ in nil }
    /// The icon the page a link leads to was given: an SF Symbol's name.
    var linkIcon: (String) -> String? = { _ in nil }

    static let hiddenFont = EditorFont.systemFont(ofSize: 0.1)
    /// A note's first heading is its own; those under it are structure, and read
    /// as a section's name — at the body's size, set apart by weight and room.
    static let headingScales: [CGFloat] = [1.3, 1.02, 1, 1, 0.95, 0.95]
    /// How far each level of a list written as text is set in.
    static let levelIndent: CGFloat = 20

    var size: CGFloat { theme.size }
    var iconSide: CGFloat { (size * 0.72).rounded() }
    /// The room before a pill's words for its icon.
    var leadWidth: CGFloat { iconSide + 5 }
    /// The room a ↗ after a link takes, with the space before it.
    var arrowRoom: CGFloat { (size * 0.7).rounded() + 3 }
    var taskRoom: CGFloat { (size * 1.5).rounded(.up) }

    var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [.font: theme.body, .foregroundColor: theme.text, .paragraphStyle: paragraph]
    }

    /// The lines a selection touches: the ones whose markup shows.
    static func revealed(_ layout: BodyLayout, selection: NSRange) -> Set<Int> {
        var lines = Set<Int>()
        for (index, line) in layout.lines.enumerated() {
            let (start, end) = (Int(line.start), Int(line.end))
            if start > NSMaxRange(selection) { break }
            if end >= selection.location { lines.insert(index) }
        }
        return lines
    }

    /// Dresses a storage as a layout says. `revealed` is the lines being
    /// written in; empty when the text is only read.
    func style(_ storage: NSTextStorage, layout: BodyLayout, revealed: Set<Int>) {
        let whole = NSRange(location: 0, length: storage.length)
        let outline = !layout.markersInText
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: whole)

        // Lines: indentation, and the fonts a whole line takes.
        for (index, line) in layout.lines.enumerated() {
            let range = NSRange(location: Int(line.start), length: Int(line.end - line.start))
            guard NSMaxRange(range) <= storage.length else { continue }
            let shown = revealed.contains(index)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            if outline {
                // A row stands in from the margin by its depth; what it is, is drawn in the step before it.
                let indent = CGFloat(line.depth) * theme.step
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent
                paragraph.paragraphSpacing = (size * 0.2).rounded()
            } else if line.indent > 0 {
                // The spaces that place a line are the list's, not the reader's.
                storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: EditorColor.clear], range: NSRange(location: range.location, length: Int(line.indent)))
            }
            let depthIndent = CGFloat(max(Int(line.depth) - 1, 0)) * Self.levelIndent
            switch line.kind {
            case .heading(let level):
                let scale = Self.headingScales[min(max(Int(level), 1), 6) - 1]
                storage.addAttribute(.font, value: theme.font(size * scale, weight: .semibold), range: range)
                paragraph.paragraphSpacingBefore += index == 0 ? 0 : (size * 0.5).rounded()
            case .item(_, let done, _):
                if !outline {
                    let marker = done != nil && !shown ? taskRoom : width(of: storage, from: Int(line.start + line.indent), to: Int(line.content))
                    paragraph.firstLineHeadIndent = depthIndent
                    paragraph.headIndent = depthIndent + marker
                }
                if done == true {
                    let words = NSRange(location: Int(line.content), length: max(Int(line.end) - Int(line.content), 0))
                    storage.addAttributes([.foregroundColor: theme.secondary, .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: theme.secondary], range: words)
                }
            case .paragraph where line.depth > 0 && !outline:
                // A paragraph continuing an item stands under its words.
                let under = CGFloat(Int(line.depth) - 1) * Self.levelIndent + bulletWidth
                paragraph.firstLineHeadIndent = under
                paragraph.headIndent = under
            case .quote:
                if outline {
                    paragraph.firstLineHeadIndent += 14
                    paragraph.headIndent += 14
                    storage.addAttribute(.prismQuote, value: true, range: range)
                } else if !shown {
                    paragraph.firstLineHeadIndent = 14
                    paragraph.headIndent = 14
                    storage.addAttribute(.prismQuote, value: true, range: range)
                }
                storage.addAttribute(.foregroundColor, value: theme.secondary, range: range)
            case .fence:
                storage.addAttributes([.font: theme.mono(size * 0.92), .foregroundColor: EditorColor.clear, .prismFence: true], range: range)
            case .code:
                storage.addAttribute(.font, value: theme.mono(size * 0.92), range: range)
                // A row of code's fences, there to be edited and not read: faint,
                // and their backticks — which sit at the top of a line — set down
                // into it, so the fences stand evenly above and below the code.
                if outline { dimFences(storage, in: range) }
            case .rule:
                storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
            default:
                break
            }
            // The paragraph's style covers its line break too.
            let paragraphRange = NSRange(location: range.location, length: min(range.length + 1, storage.length - range.location))
            if paragraphRange.length > 0 { storage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange) }
        }

        // Runs: emphasis, links, tags, and the markup around them.
        var lineIndex = 0
        var markupEnd: [Int: Int] = [:]
        for run in layout.runs where run.kind == .markup { markupEnd[Int(run.start)] = Int(run.end) }
        let markupEnds = Set(markupEnd.values)
        // Rows drawn as their link's card: their words are put away under the card, and
        // are given no link's look — its icon would stand out in the margin.
        let text = storage.string as NSString
        let cardLines = Set(layout.lines.indices.filter { index in
            let line = layout.lines[index]
            let range = NSRange(location: Int(line.content), length: max(Int(line.end) - Int(line.content), 0))
            return line.isCard && !revealed.contains(index) && NSMaxRange(range) <= text.length && EditorBlock.cardLink(text.substring(with: range)) != nil
        })
        for run in layout.runs {
            let range = NSRange(location: Int(run.start), length: Int(run.end - run.start))
            guard range.length > 0, NSMaxRange(range) <= storage.length, !layout.lines.isEmpty else { continue }
            while lineIndex + 1 < layout.lines.count, Int(layout.lines[lineIndex + 1].start) <= range.location { lineIndex += 1 }
            while lineIndex > 0, Int(layout.lines[lineIndex].start) > range.location { lineIndex -= 1 }
            let line = layout.lines[lineIndex]
            let shown = revealed.contains(lineIndex)
            if cardLines.contains(lineIndex) { continue }
            switch run.kind {
            case .markup:
                hide(storage, range, shown: shown)
            case .strong:
                restyle(storage, range) { theme.font($0.pointSize, weight: .semibold, italic: $0.isItalic) }
            case .emphasis:
                restyle(storage, range) { theme.font($0.pointSize, weight: $0.isBold ? .semibold : .regular, italic: true) }
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .highlight:
                storage.addAttribute(.backgroundColor, value: theme.highlight, range: range)
            case .code:
                storage.addAttributes([.font: theme.mono(size * 0.92), .backgroundColor: theme.codeBackground], range: range)
            case .pageLink(let target, _):
                let isRiver = riverName(linkTarget: target) != nil
                let missing = !isRiver && !pageExists(target)
                // Its icon before it only where the page has one of its own — a day's is the calendar.
                let symbol = isRiver ? "square.stack" : (linkIcon(target) ?? (isDate(target) ? "calendar" : nil))
                link(storage, range, to: .page(target), symbol: symbol, missing: missing, line: line, shown: shown, markupEnd: markupEnd, faint: !isRiver && !missing && pageArchived(target))
                // A link written with its page's file's name shows the page's title — off the lines being written in.
                if !shown, !isRiver, (storage.string as NSString).substring(with: range) == target, let label = linkLabel(target) {
                    relabel(storage, range, as: label)
                }
            case .webLink(let url):
                // An address shown as itself is cut to what says where it leads.
                let bare = (storage.string as NSString).substring(with: range) == url
                link(storage, range, to: .web(url), symbol: nil, missing: false, line: line, shown: shown, markupEnd: markupEnd, leaves: true)
                if bare, !shown { shorten(storage, range, address: url as NSString, lead: range.location == Int(line.start)) }
            case .tag(let name):
                link(storage, range, to: .tag(name), symbol: nil, missing: false, line: line, shown: shown, markupEnd: markupEnd)
            case .image:
                storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
            case .bullet:
                if case .item(let number, let done, let bullet) = line.kind {
                    if shown || number != nil {
                        storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
                    } else if let done {
                        // The box stands where the marker is written, in room of its own.
                        let first = NSRange(location: range.location, length: 1)
                        let glyph = width(of: storage, from: first.location, to: first.location + 1)
                        storage.addAttributes([.foregroundColor: EditorColor.clear, .kern: max(taskRoom - glyph, 0), .prismTask: TaskBox(isDone: done, isRound: bullet == "+")], range: first)
                        if range.length > 1 {
                            storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: EditorColor.clear], range: NSRange(location: range.location + 1, length: range.length - 1))
                        }
                    } else {
                        storage.addAttribute(.foregroundColor, value: EditorColor.clear, range: range)
                        storage.addAttribute(.prismBullet, value: true, range: NSRange(location: range.location, length: 1))
                    }
                }
            case .checkbox:
                if shown {
                    storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
                } else {
                    // With the space after it.
                    let length = min(range.length + 1, Int(line.content) - range.location)
                    storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: EditorColor.clear], range: NSRange(location: range.location, length: max(length, range.length)))
                }
            case .quoteMark:
                let length = min(Int(line.content) - range.location, storage.length - range.location)
                hide(storage, NSRange(location: range.location, length: max(length, range.length)), shown: shown)
            case .callout:
                storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
            case .fenceInfo:
                break
            }
        }
        storage.endEditing()
    }

    /// The first and last lines of a row of code — its lines parted by
    /// U+2028 — when they are fences: faint, and set down in their lines.
    private func dimFences(_ storage: NSTextStorage, in row: NSRange) {
        let text = storage.string as NSString
        let parts = text.substring(with: row).components(separatedBy: "\u{2028}")
        guard parts.count >= 2 else { return }
        let isFence = { (line: String) in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
        }
        let fence: [NSAttributedString.Key: Any] = [.foregroundColor: EditorColor.clear, .prismFence: true]
        if let first = parts.first, isFence(first) {
            storage.addAttributes(fence, range: NSRange(location: row.location, length: (first as NSString).length))
        }
        if let last = parts.last, isFence(last) {
            let length = (last as NSString).length
            storage.addAttributes(fence, range: NSRange(location: NSMaxRange(row) - length, length: length))
        }
    }

    private func hide(_ storage: NSTextStorage, _ range: NSRange, shown: Bool) {
        if shown {
            storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
        } else {
            storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: EditorColor.clear], range: range)
        }
    }

    private func link(_ storage: NSTextStorage, _ range: NSRange, to target: EditorLink, symbol: String?, missing: Bool, line: BodyLine, shown: Bool, markupEnd: [Int: Int], leaves: Bool = false, faint: Bool = false) {
        // A link to a page not written yet, or to one archived: in the secondary ink.
        let tint = missing || faint ? theme.secondary : theme.accent
        storage.addAttributes([.foregroundColor: tint, .prismLink: LinkBox(target)], range: range)
        if missing {
            restyle(storage, range) { theme.font($0.pointSize, weight: $0.isBold ? .semibold : .regular, italic: true) }
        }
        // In a heading, and on a line being written in, a link is only coloured —
        // and, being written, set in the code face, its markup with it: written as it is stored.
        if case .heading = line.kind { return }
        guard !shown else {
            let mono = theme.mono(size * 0.92)
            storage.addAttribute(.font, value: mono, range: range)
            for (start, end) in markupEnd where end == range.location || start == NSMaxRange(range) {
                guard end <= storage.length, end > start else { continue }
                storage.addAttribute(.font, value: mono, range: NSRange(location: start, length: end - start))
            }
            return
        }
        let closes = markupEnd[NSMaxRange(range)].map { $0 > NSMaxRange(range) } ?? false
        storage.addAttribute(.prismPill, value: Pill(symbol: symbol, tint: tint, isMissing: missing, leaves: leaves, roomInside: leaves && !closes), range: range)
        // Room for the icon, on the last character of the markup before the words…
        if symbol != nil, range.location > Int(line.start) {
            storage.addAttribute(.kern, value: leadWidth, range: NSRange(location: range.location - 1, length: 1))
        }
        // …and after them, for the ↗ of a link that leaves: on the last of the
        // markup that closes, or — an address written bare — its own last character.
        let after = leaves ? arrowRoom : 0
        if let end = markupEnd[NSMaxRange(range)], end > NSMaxRange(range) {
            storage.addAttribute(.kern, value: after, range: NSRange(location: end - 1, length: 1))
        } else if leaves, range.length > 0 {
            storage.addAttribute(.kern, value: after, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
        }
    }

    /// Shows other words in a link's place: what is written is hidden,
    /// and room for the words is left after it, where they are drawn
    /// ([`BodyLayoutManager`]). What is written is not touched.
    private func relabel(_ storage: NSTextStorage, _ range: NSRange, as label: String) {
        guard range.length > 0 else { return }
        let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? EditorFont) ?? theme.body
        let color = (storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? EditorColor) ?? theme.accent
        // One line's worth: room left after a character cannot wrap.
        let words = label.count > 48 ? String(label.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" : label
        let text = NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: color])
        // The first character keeps its size — so the line keeps its
        // height — and is not seen: the words are drawn over it, and in
        // the room left after it. The rest takes no room: a line may
        // break in it, at a hyphen, and nothing shows that it did.
        let first = NSRange(location: range.location, length: 1)
        let own = width(of: storage, from: first.location, to: first.location + 1)
        storage.addAttributes([.foregroundColor: EditorColor.clear, .kern: max(text.size().width.rounded(.up) - own, 0), .prismLabel: LinkLabel(text)], range: first)
        if range.length > 1 {
            storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: EditorColor.clear], range: NSRange(location: range.location + 1, length: range.length - 1))
        }
    }

    /// Hides what of a web address says nothing: its scheme, a leading
    /// `www.`, and everything from its query on. Off the lines being
    /// written in only; the address itself is not touched.
    private func shorten(_ storage: NSTextStorage, _ range: NSRange, address: NSString, lead: Bool) {
        let hidden: [NSAttributedString.Key: Any] = [.font: Self.hiddenFont, .foregroundColor: EditorColor.clear]
        var start = 0
        let scheme = address.range(of: "://")
        if scheme.location != NSNotFound, scheme.location < 8 { start = NSMaxRange(scheme) }
        if address.length >= start + 4, address.substring(with: NSRange(location: start, length: 4)).lowercased() == "www." { start += 4 }
        var end = address.length
        for mark in ["?", "#"] {
            let at = address.range(of: mark)
            if at.location != NSNotFound { end = min(end, at.location) }
        }
        while end > start + 1, address.character(at: end - 1) == 47 { end -= 1 }
        guard end > start else { return }
        if start > 0 {
            storage.addAttributes(hidden, range: NSRange(location: range.location, length: start))
            // The icon's room, on the last of what is hidden before the words.
            if lead { storage.addAttribute(.kern, value: leadWidth, range: NSRange(location: range.location + start - 1, length: 1)) }
        }
        if end < address.length {
            storage.addAttributes(hidden, range: NSRange(location: range.location + end, length: address.length - end))
        }
    }

    private func restyle(_ storage: NSTextStorage, _ range: NSRange, _ change: (EditorFont) -> EditorFont) {
        storage.enumerateAttribute(.font, in: range) { value, part, _ in
            guard let font = value as? EditorFont, font.pointSize > 1 else { return }
            storage.addAttribute(.font, value: change(font), range: part)
        }
    }

    private var bulletWidth: CGFloat {
        ("- " as NSString).size(withAttributes: [.font: theme.body]).width
    }

    private func width(of storage: NSTextStorage, from: Int, to: Int) -> CGFloat {
        guard to > from, to <= storage.length else { return 0 }
        return (storage.string as NSString).substring(with: NSRange(location: from, length: to - from)).size(withAttributes: [.font: theme.body]).width
    }

    private func isDate(_ name: String) -> Bool {
        let parts = name.split(separator: "-")
        return (parts.count == 3 || (parts.count == 2 && parts[1].hasPrefix("W"))) && name.count <= 10 && name.first?.isNumber == true
    }
}

extension EditorFont {
    var isBold: Bool {
        #if os(macOS)
        return fontDescriptor.symbolicTraits.contains(.bold)
        #else
        return fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    var isItalic: Bool {
        #if os(macOS)
        return fontDescriptor.symbolicTraits.contains(.italic)
        #else
        return fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }
}

/// Draws what the styler marks — pills behind links, a dot for a bullet,
/// a box for a task, a bar beside a quote — and, for an outline, what
/// each row is, in the margin beside it.
final class BodyLayoutManager: NSLayoutManager {
    var theme = EditorTheme.system(size: 14)
    /// An outline's rows, whose marks are drawn beside them; empty for text.
    var rows: [BodyLine] = []
    /// Every row of an outline, as the note's layout counts them — those
    /// an app's view stands in place of too; empty for text. What a touch
    /// finds a row by, and where a folded row's pill is drawn.
    var lines: [BodyLine] = []
    /// The rows chosen whole, as the characters they cover: marked across the note's width.
    var chosen: ClosedRange<Int>?
    /// Words found, marked; and the one gone to now, marked more.
    var found: [NSRange] = []
    var foundAt: NSRange?

    /// Where rows being carried would be put down: a line across the
    /// note at a height, from how far in they would lie.
    var dropLine: (y: CGFloat, x: CGFloat)?

    /// The row whose mark — a bullet, a number, a ring — is at a point:
    /// its place among the lines. Not a task's box, which is ticked.
    func mark(at point: CGPoint) -> Int? {
        for (index, row) in lines.enumerated() {
            guard case .item(_, let done, _) = row.kind, done == nil, let line = firstLine(of: row) else { continue }
            if markBox(of: row, on: line).contains(point) { return index }
        }
        return nil
    }
    /// What is drawn in place of the first line's bullet, if anything is.
    var lead: EditorLead?
    /// Where the first line begins, when it is a plain bulleted one: the
    /// only line a lead can stand at the head of.
    var leadStart: Int?
    /// Where the lead was last drawn, in the container: where it is clicked.
    private(set) var leadBox: CGRect?

    private var size: CGFloat { theme.size }

    /// Draws the lead where a bullet would be: about `centre`, on the line.
    private func drawLead(_ lead: EditorLead, midX: CGFloat, baseline: CGFloat, origin: CGPoint) {
        let side = (size * 1.05).rounded()
        let box = CGRect(x: midX - side / 2, y: baseline - theme.body.capHeight / 2 - side / 2, width: side, height: side)
        if let progress = lead.progress {
            // A checklist's ring: as much of it drawn as is done.
            drawRing(in: box.insetBy(dx: side * 0.16, dy: side * 0.16), fraction: progress, tint: lead.tint ?? theme.secondary)
            leadBox = box.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -4, dy: -4)
            return
        }
        Self.draw(symbol: lead.symbol, in: box, pointSize: side * (lead.isDone ? 1 : 0.92), weight: .regular, colors: lead.isDone ? [.white, theme.accent] : [lead.tint ?? theme.secondary])
        leadBox = box.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -4, dy: -4)
    }

    /// A ring, as much of it drawn as is done: a quiet track, and over it the arc.
    private func drawRing(in ring: CGRect, fraction: Double, tint: EditorColor) {
        let line = max(ring.width * 0.15, 1.5)
        let track = EditorBezier(ovalIn: ring)
        track.lineWidth = line
        tint.withAlphaComponent(0.28).setStroke()
        track.stroke()
        guard fraction > 0 else { return }
        let arc = EditorBezier.arc(center: CGPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2, fraction: min(fraction, 1))
        arc.lineWidth = line
        tint.setStroke()
        arc.stroke()
    }

    /// How far along the checklist under a row is — every box in the
    /// rows set in under it, ticked of all: nothing for a row over none.
    private func progress(under row: BodyLine) -> Double? {
        guard let at = lines.firstIndex(where: { $0.start == row.start }) else { return nil }
        var (done, total) = (0, 0)
        for line in lines[(at + 1)...] {
            guard line.depth > row.depth else { break }
            if case .item(_, let ticked, _) = line.kind, let ticked {
                total += 1
                if ticked { done += 1 }
            }
        }
        return total > 0 ? Double(done) / Double(total) : nil
    }

    /// Draws the mark of an outline's only row when nothing is written in
    /// it yet: the text system draws nothing for no text — not even what
    /// stands beside it — so the bullet would come only with the first word.
    func drawEmptyRow(at origin: CGPoint) {
        guard textStorage?.length == 0, isOutline else { return }
        if !rows.isEmpty { return drawBackground(forGlyphRange: NSRange(location: 0, length: 0), at: origin) }
        // No row at all yet — a note just made: the bullet its first row will have, where the caret waits.
        guard isWriting else { return }
        let rect = extraLineFragmentRect.height > 0 ? extraLineFragmentRect : CGRect(x: 0, y: 0, width: 0, height: (theme.body.ascender - theme.body.descender).rounded(.up))
        let baseline = rect.minY + wordsBaseline
        let box = CGRect(x: 0, y: rect.minY, width: theme.step, height: rect.height)
        let diameter = max(4.5, (size * 0.3).rounded())
        theme.secondary.setFill()
        Self.ovalPath(CGRect(x: box.midX - diameter / 2, y: baseline - theme.body.xHeight / 2 - diameter / 2, width: diameter, height: diameter).offsetBy(dx: origin.x, dy: origin.y)).fill()
    }

    /// Whether the note is shown as an outline, and whether it is being written in: an empty
    /// outline being written in shows the bullet its first row will have.
    var isOutline = false
    var isWriting = false

    /// Whether a point of the container is on the lead.
    func isLead(at point: CGPoint) -> Bool {
        lead != nil && leadBox?.contains(point) == true
    }

    /// How far under a line's top words of the body stand: where an empty row's mark is to stand too.
    private var wordsBaseline: CGFloat {
        #if os(macOS)
        defaultBaselineOffset(for: theme.body)
        #else
        theme.body.ascender
        #endif
    }

    /// Where a row's first line is: its line's box, and its baseline.
    private func firstLine(of row: BodyLine) -> (rect: CGRect, baseline: CGFloat)? {
        guard let storage = textStorage else { return nil }
        let start = Int(row.start)
        if start < storage.length {
            let glyph = glyphIndexForCharacter(at: start)
            let rect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            // A row with nothing in it has only its line's end to ask, which
            // sits lower than words would: its mark stands where words will.
            if row.end <= row.start { return (rect, rect.minY + wordsBaseline) }
            return (rect, rect.minY + location(forGlyphAt: glyph).y)
        }
        // The last row, with nothing in it yet: the line the caret waits on.
        let rect = extraLineFragmentRect
        guard rect.height > 0 else { return nil }
        return (rect, rect.minY + wordsBaseline)
    }

    /// The box a row's mark is drawn in: the step before its words.
    private func markBox(of row: BodyLine, on line: (rect: CGRect, baseline: CGFloat)) -> CGRect {
        let step = theme.step
        return CGRect(x: CGFloat(max(Int(row.depth) - 1, 0)) * step, y: line.rect.minY, width: step, height: line.rect.height)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let font = theme.body

        if let chosen {
            // Each row chosen, a band the width of the note — its mark's room with it.
            var band = CGRect.null
            for row in lines where Int(row.start) <= chosen.upperBound && Int(row.end) >= chosen.lowerBound && Int(row.start) >= chosen.lowerBound {
                let glyphs = glyphRange(forCharacterRange: NSRange(location: Int(row.start), length: max(Int(row.end) - Int(row.start), 0)), actualCharacterRange: nil)
                var rect = glyphs.length > 0 ? boundingRect(forGlyphRange: glyphs, in: container) : (firstLine(of: row)?.rect ?? .null)
                guard !rect.isNull else { continue }
                rect.origin.x = 0
                rect.size.width = container.size.width
                band = band.union(rect)
            }
            if !band.isNull {
                theme.accent.withAlphaComponent(0.16).setFill()
                Self.roundedPath(band.insetBy(dx: -4, dy: -1).offsetBy(dx: origin.x, dy: origin.y), radius: 6).fill()
            }
        }
        // What a find found: a highlighter's yellow behind each, the one gone to brighter.
        for range in found where range.location <= NSMaxRange(characters) && NSMaxRange(range) >= characters.location {
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let current = range == foundAt
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                EditorColor.systemYellow.withAlphaComponent(current ? 0.75 : 0.32).setFill()
                Self.roundedPath(rect.insetBy(dx: -1.5, dy: 0).offsetBy(dx: origin.x, dy: origin.y), radius: 3).fill()
            }
        }
        if let dropLine {
            theme.accent.setFill()
            let line = CGRect(x: dropLine.x + origin.x, y: dropLine.y + origin.y - 1, width: max(container.size.width - dropLine.x, 20), height: 2)
            Self.roundedPath(line, radius: 1).fill()
            Self.ovalPath(CGRect(x: line.minX - 3, y: line.midY - 3, width: 6, height: 6)).fill()
        }
        for (index, line) in lines.enumerated() where line.isFolded && Int(line.start) <= NSMaxRange(characters) && Int(line.end) >= characters.location {
            if let pill = foldPill(ofRow: index) { drawFoldPill(in: pill.offsetBy(dx: origin.x, dy: origin.y)) }
        }

        // An outline's marks, beside the rows being drawn.
        for row in rows where Int(row.start) <= NSMaxRange(characters) && Int(row.end) >= characters.location {
            guard case .item(let number, let done, let bullet) = row.kind, let line = firstLine(of: row) else { continue }
            // A plain row with nothing in it is where words will go while the note is
            // written in; read, it is nothing — no bullet left standing on its own.
            if row.end <= row.start, done == nil, number == nil, !row.hasChildren, !isWriting, !(lead != nil && leadStart == Int(row.start)) { continue }
            let box = markBox(of: row, on: line).offsetBy(dx: origin.x, dy: origin.y)
            let baseline = line.baseline + origin.y
            if let lead, leadStart == Int(row.start), done == nil, number == nil {
                drawLead(lead, midX: box.midX, baseline: baseline, origin: origin)
            } else if let done {
                let side = (size * 0.95).rounded()
                let name = bullet == "+" ? (done ? "checkmark.circle.fill" : "circle") : (done ? "checkmark.square.fill" : "square")
                Self.draw(symbol: name, in: CGRect(x: box.midX - side / 2, y: baseline - font.capHeight / 2 - side / 2, width: side, height: side), pointSize: side, weight: .regular, colors: done ? [.white, theme.accent] : [theme.secondary])
            } else if let number {
                let label = "\(number)\(bullet)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: EditorFont.monospacedDigitSystemFont(ofSize: size * 0.85, weight: .regular), .foregroundColor: theme.secondary]
                let width = label.size(withAttributes: attributes).width
                label.draw(at: CGPoint(x: box.maxX - 6 - width, y: baseline - font.ascender * 0.85 - 1), withAttributes: attributes)
            } else if let progress = progress(under: row) {
                // A row over a checklist: how far along that is, where its bullet would be.
                let side = (size * 0.74).rounded()
                drawRing(in: CGRect(x: box.midX - side / 2, y: baseline - font.xHeight / 2 - side / 2, width: side, height: side), fraction: progress, tint: theme.secondary)
            } else {
                let diameter = max(4.5, (size * 0.3).rounded())
                theme.secondary.setFill()
                Self.ovalPath(CGRect(x: box.midX - diameter / 2, y: baseline - font.xHeight / 2 - diameter / 2, width: diameter, height: diameter)).fill()
            }
        }

        storage.enumerateAttribute(.prismPill, in: characters) { value, range, _ in
            guard let pill = value as? Pill else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let side = (size * 0.72).rounded()
            var first = true
            var last: (rect: CGRect, baseline: CGFloat)?
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { whole, _ in
                var rect = whole
                // What of a link's hidden name fell onto another line is nothing to draw around.
                guard rect.width > 2 else { return }
                let glyph = self.glyphIndex(for: CGPoint(x: rect.midX, y: rect.midY), in: container)
                let fragment = self.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                // Where a link runs on to another line, its pill is behind its words there and
                // no more: not out into the margin the line is set in from, nor on to the edge.
                let used = self.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                let (left, right) = (max(rect.minX, used.minX), min(rect.maxX, used.maxX))
                guard right - left > 2 else { return }
                rect.origin.x = left
                rect.size.width = right - left
                let baseline = fragment.minY + self.location(forGlyphAt: glyphs.location).y
                // The icon's room is before the link — but for one that opens its line, whose room is
                // its own first, hidden characters': there the pill begins where the line does.
                let opens = range.location == 0 || (storage.string as NSString).character(at: range.location - 1) == 10
                // Nothing behind a link: its colour says it is one. Its page's icon before it…
                if first, let symbol = pill.symbol {
                    let x = opens ? rect.minX - side - 5 : rect.minX - side - 5
                    let icon = CGRect(x: x, y: baseline - font.xHeight / 2 - side / 2, width: side, height: side).offsetBy(dx: origin.x, dy: origin.y)
                    Self.draw(symbol: symbol, in: icon, pointSize: side * 0.9, weight: .regular, colors: [pill.tint.withAlphaComponent(0.85)])
                }
                last = (rect, baseline)
                first = false
            }
            // …and after one that leaves the graph, a small ↗, faint.
            if pill.leaves, let last {
                let side = (size * 0.7).rounded()
                let x = (pill.roomInside ? last.rect.maxX - (side + 3) : last.rect.maxX) + 2
                // Its middle a little over the words' middle: raised, as a mark after a word is.
                let mark = CGRect(x: x, y: last.baseline - font.xHeight * 0.75 - side / 2, width: side, height: side).offsetBy(dx: origin.x, dy: origin.y)
                Self.draw(symbol: "arrow.up.right", in: mark, pointSize: side * 0.8, weight: .regular, colors: [pill.tint.withAlphaComponent(0.7)])
            }
        }

        // A link's title, in the room left for it after what is written.
        storage.enumerateAttribute(.prismLabel, in: characters) { value, range, _ in
            guard let label = value as? LinkLabel else { return }
            let glyph = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyph.length > 0 else { return }
            let fragment = lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
            let at = location(forGlyphAt: glyph.location)
            let font = (label.text.attribute(.font, at: 0, effectiveRange: nil) as? EditorFont) ?? font
            label.text.draw(at: CGPoint(x: fragment.minX + at.x + origin.x, y: fragment.minY + at.y - font.ascender + origin.y))
        }

        storage.enumerateAttribute(.prismBullet, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyph = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: glyph, in: container)
            let baseline = lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil).minY + location(forGlyphAt: glyph.location).y
            if let lead = self.lead, let start = self.leadStart, range.location >= start, range.location <= start + 1 {
                self.drawLead(lead, midX: rect.midX + origin.x, baseline: baseline + origin.y, origin: origin)
                return
            }
            let diameter = max(4.5, (size * 0.3).rounded())
            let dot = CGRect(x: rect.midX - diameter / 2, y: baseline - font.xHeight / 2 - diameter / 2, width: diameter, height: diameter).offsetBy(dx: origin.x, dy: origin.y)
            theme.secondary.setFill()
            Self.ovalPath(dot).fill()
        }

        storage.enumerateAttribute(.prismTask, in: characters) { value, range, _ in
            guard let task = value as? TaskBox else { return }
            let glyph = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let start = location(forGlyphAt: glyph.location)
            let fragment = lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
            let side = (size * 0.95).rounded()
            let baseline = fragment.minY + start.y
            let box = CGRect(x: fragment.minX + start.x, y: baseline - font.capHeight / 2 - side / 2, width: side, height: side).offsetBy(dx: origin.x, dy: origin.y)
            let name = task.isRound ? (task.isDone ? "checkmark.circle.fill" : "circle") : (task.isDone ? "checkmark.square.fill" : "square")
            Self.draw(symbol: name, in: box, pointSize: side, weight: .regular, colors: task.isDone ? [.white, theme.accent] : [theme.secondary])
        }

        // A quote's bar beside it: one for quotes that follow one another, as one quote is.
        var bars: [CGRect] = []
        storage.enumerateAttribute(.prismQuote, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var whole = CGRect.null
            var left = CGFloat.greatestFiniteMagnitude
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, _, _ in
                // The whole height of each line: so that the next quote's bar meets this one's.
                whole = whole.union(CGRect(x: used.minX, y: fragment.minY, width: used.width, height: fragment.height))
                left = min(left, used.minX)
            }
            guard !whole.isNull else { return }
            let bar = CGRect(x: max(left - 11, 0), y: whole.minY, width: 3, height: whole.height)
            if let last = bars.last, abs(last.minX - bar.minX) < 1, bar.minY - last.maxY < size * 0.9 {
                bars[bars.count - 1] = last.union(bar)
            } else {
                bars.append(bar)
            }
        }
        // A fence's backticks sit at the top of their line, leaving it looking
        // empty under them: they are drawn lower, faint, where the line's
        // middle is — and the fences stand evenly above and below the code.
        storage.enumerateAttribute(.prismFence, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let fragment = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let start = location(forGlyphAt: glyphs.location)
            let font = theme.mono(size * 0.92)
            let words = NSAttributedString(string: (storage.string as NSString).substring(with: range), attributes: [.font: font, .foregroundColor: theme.faint])
            let top = fragment.minY + start.y - font.ascender + (size * 0.3).rounded()
            words.draw(at: CGPoint(x: fragment.minX + start.x + origin.x, y: top + origin.y))
        }

        theme.faint.setFill()
        for bar in bars {
            let drawn = CGRect(x: bar.minX, y: bar.minY + 2, width: bar.width, height: max(bar.height - 4, 2)).offsetBy(dx: origin.x, dy: origin.y)
            Self.roundedPath(drawn, radius: 1.5).fill()
        }
    }

    // MARK: An outline's rows, where a touch finds them

    /// How many rows a row is under: what its mark is set in by.
    static func level(of row: BodyLine) -> Int {
        if case .item = row.kind { return max(Int(row.depth) - 1, 0) }
        return Int(row.depth)
    }

    /// The row of an outline at a point of the container: its place
    /// among the note's lines. `nil` between rows, and for text.
    func row(at point: CGPoint, in container: NSTextContainer) -> Int? {
        guard !lines.isEmpty, let storage = textStorage else { return nil }
        // The last row, with nothing in it yet: the line the caret waits on.
        let extra = extraLineFragmentRect
        if extra.height > 0, point.y >= extra.minY, point.y <= extra.maxY + 4 { return lines.count - 1 }
        guard storage.length > 0 else { return nil }
        let glyph = glyphIndex(for: point, in: container)
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard point.y >= fragment.minY - 4, point.y <= fragment.maxY + 4 else { return nil }
        let character = characterIndexForGlyph(at: glyph)
        return lines.lastIndex { Int($0.start) <= character }
    }

    /// All the lines a row takes, in the container.
    func rect(ofRow index: Int) -> CGRect {
        guard lines.indices.contains(index), let storage = textStorage else { return .null }
        let line = lines[index]
        let start = Int(line.start)
        guard start < storage.length else { return extraLineFragmentRect }
        // With its line break, which is all an empty row has.
        let range = NSRange(location: start, length: max(min(Int(line.end) + 1, storage.length) - start, 1))
        var rect = CGRect.null
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { fragment, _, _, _, _ in rect = rect.union(fragment) }
        return rect
    }

    /// The box some rows take, from the first one's mark to the right
    /// edge: what is lifted when they are carried, and tinted when chosen.
    func frame(ofRows rows: ClosedRange<Int>) -> CGRect {
        guard lines.indices.contains(rows.lowerBound), lines.indices.contains(rows.upperBound) else { return .zero }
        var rect = rows.reduce(CGRect.null) { $0.union(self.rect(ofRow: $1)) }
        guard !rect.isNull else { return .zero }
        let left = theme.step * CGFloat(Self.level(of: lines[rows.lowerBound]))
        rect.size.width = max(rect.maxX - left, 0)
        rect.origin.x = left
        return rect.integral
    }

    /// The row whose mark — its bullet, its number, its box — is at a
    /// point, if one is: the step before its words, on any of its lines.
    func marker(at point: CGPoint, in container: NSTextContainer) -> Int? {
        guard let index = row(at: point, in: container), case .item = lines[index].kind else { return nil }
        let left = theme.step * CGFloat(Self.level(of: lines[index]))
        return point.x > left - 6 && point.x < left + theme.step - 2 ? index : nil
    }

    /// Where a folded row's pill is, in the container: after the words of
    /// its last line, on the middle of their capitals.
    func foldPill(ofRow index: Int) -> CGRect? {
        guard lines.indices.contains(index), lines[index].isFolded, let storage = textStorage else { return nil }
        let line = lines[index]
        let font = theme.body
        let height = (font.capHeight + 9).rounded()
        let size = CGSize(width: (height * 1.7).rounded(), height: height)
        guard line.end > line.start, Int(line.end) <= storage.length else {
            // No words: where they would begin.
            guard let first = firstLine(of: line) else { return nil }
            return CGRect(origin: CGPoint(x: CGFloat(line.depth) * theme.step, y: (first.baseline - font.capHeight / 2 - height / 2).rounded()), size: size)
        }
        let last = glyphIndexForCharacter(at: Int(line.end) - 1)
        let fragment = lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
        let used = lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil)
        let baseline = fragment.minY + location(forGlyphAt: last).y
        return CGRect(origin: CGPoint(x: used.maxX + 6, y: (baseline - font.capHeight / 2 - height / 2).rounded()), size: size)
    }

    /// The folded row whose pill is at a point, if one is.
    func foldPill(at point: CGPoint) -> Int? {
        lines.indices.first { lines[$0].isFolded && foldPill(ofRow: $0)?.insetBy(dx: -8, dy: -8).contains(point) == true }
    }

    /// A pill with three dots in it, on their middle.
    private func drawFoldPill(in rect: CGRect) {
        theme.text.withAlphaComponent(0.07).setFill()
        Self.roundedPath(rect, radius: rect.height / 2).fill()
        theme.secondary.setFill()
        let dot = max(2.5, (rect.height * 0.16).rounded())
        let gap = dot * 1.1
        let total = 3 * dot + 2 * gap
        for index in 0..<3 {
            Self.ovalPath(CGRect(x: rect.midX - total / 2 + CGFloat(index) * (dot + gap), y: rect.midY - dot / 2, width: dot, height: dot)).fill()
        }
    }

    /// The link at a point of the text container, if a link's words are there.
    func link(at point: CGPoint, in container: NSTextContainer) -> EditorLink? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -2, dy: -3)
        guard rect.contains(point) else { return nil }
        let character = characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        return (storage.attribute(.prismLink, at: character, effectiveRange: nil) as? LinkBox)?.target
    }

    /// The place in the text of the task whose box is at a point, if one is.
    func task(at point: CGPoint, in container: NSTextContainer) -> Int? {
        // An outline's box is in the margin beside its row.
        for row in rows {
            guard case .item(_, let done, _) = row.kind, done != nil, let line = firstLine(of: row) else { continue }
            if markBox(of: row, on: line).contains(point) { return Int(row.start) }
        }
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let glyph = glyphIndex(for: point, in: container)
        let character = characterIndexForGlyph(at: glyph)
        guard character < storage.length, storage.attribute(.prismTask, at: character, effectiveRange: nil) != nil else { return nil }
        let start = location(forGlyphAt: glyph)
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let room = CGRect(x: fragment.minX + start.x - 3, y: fragment.minY, width: (size * 1.5).rounded(.up) + 3, height: fragment.height)
        return room.contains(point) ? character : nil
    }

    static func roundedPath(_ rect: CGRect, radius: CGFloat) -> EditorPath {
        #if os(macOS)
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        #else
        return UIBezierPath(roundedRect: rect, cornerRadius: radius)
        #endif
    }

    static func ovalPath(_ rect: CGRect) -> EditorPath {
        #if os(macOS)
        return NSBezierPath(ovalIn: rect)
        #else
        return UIBezierPath(ovalIn: rect)
        #endif
    }

    static func draw(symbol: String, in rect: CGRect, pointSize: CGFloat, weight: EditorFont.Weight, colors: [EditorColor]) {
        #if os(macOS)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight).applying(.init(paletteColors: colors))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let fitted = CGRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height)
        image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        #else
        // One colour is a tint, drawn as it is; more are the symbol's own layers'.
        let sized = UIImage.SymbolConfiguration(pointSize: pointSize, weight: UIImage.SymbolWeight(weight))
        let drawn = colors.count == 1
            ? UIImage(systemName: symbol, withConfiguration: sized)?.withTintColor(colors[0], renderingMode: .alwaysOriginal)
            : UIImage(systemName: symbol, withConfiguration: sized.applying(UIImage.SymbolConfiguration(paletteColors: colors)))
        guard let image = drawn else { return }
        image.draw(in: CGRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
        #endif
    }
}

#if os(macOS)
typealias EditorPath = NSBezierPath

extension NSBezierPath {
    func addLine(to point: CGPoint) { line(to: point) }
}
#else
typealias EditorPath = UIBezierPath

extension UIImage.SymbolWeight {
    init(_ weight: UIFont.Weight) {
        switch weight {
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        default: self = .regular
        }
    }
}
#endif

#if os(macOS)
typealias EditorBezier = NSBezierPath
#else
typealias EditorBezier = UIBezierPath
#endif

extension EditorBezier {
    /// An arc from the top of a circle, clockwise as it is seen, so much of the way round.
    static func arc(center: CGPoint, radius: CGFloat, fraction: Double) -> EditorBezier {
        #if os(macOS)
        // In a flipped view, angles run the other way: from the top is -90.
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: -90 + 360 * fraction, clockwise: false)
        path.lineCapStyle = .round
        return path
        #else
        let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * fraction, clockwise: true)
        path.lineCapStyle = .round
        return path
        #endif
    }
}
