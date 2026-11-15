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
    /// How far in from its character the title is drawn: the room its page's icon takes first.
    let lead: CGFloat
    init(_ text: NSAttributedString, lead: CGFloat = 0) {
        self.text = text
        self.lead = lead
    }
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
    /// Whether the icon's room is the link's own — a link to a page, one character
    /// drawn as its title, the icon first in it — rather than before it.
    let iconInside: Bool
    init(symbol: String?, tint: EditorColor, isMissing: Bool, leaves: Bool = false, roomInside: Bool = false, iconInside: Bool = false) {
        self.symbol = symbol
        self.tint = tint
        self.isMissing = isMissing
        self.leaves = leaves
        self.roomInside = roomInside
        self.iconInside = iconInside
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
    /// Markdown that is never seen: the caret steps over it, Delete leaves it be.
    static let prismMarkup = NSAttributedString.Key("prism.markup")
}

/// Dresses what a note's editor shows as what it means.
///
/// The engine says what each line and run of the text *is*
/// (`NoteEditor.layout`); this turns that into fonts, colours, and the
/// marks the layout manager draws — pills, bullets, boxes. It knows no
/// Markdown: a line is a row and holds only its words, and what the row
/// is, is drawn in the margin beside it.
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
    /// Whether the note is shown as prose: every row a step further out,
    /// so its top-level rows stand at the margin, as paragraphs, apart.
    var prose = false
    /// A row's own Markdown, by its place among the lines: the view shows
    /// its words only.
    var rowMarkdown: (Int) -> String? = { _ in nil }
    /// The icon the page a link leads to was given: an SF Symbol's name.
    var linkIcon: (String) -> String? = { _ in nil }

    static let hiddenFont = EditorFont.systemFont(ofSize: 0.1)

    /// How far in a row's words begin. A row stands in from the margin by its
    /// depth, what it is drawn in the step before it; a typed row — a task, a
    /// number, a bulleted row — and a quote have their mark a step further in,
    /// after the handle, as Bike's list marks are. As prose, a step less: a
    /// top-level row is a paragraph, at the margin. An empty row's caret
    /// stands here too, with no character to carry it.
    static func wordsIndent(of line: BodyLine, step: CGFloat, prose: Bool) -> CGFloat {
        var steps = Int(line.depth) - (prose ? 1 : 0)
        switch line.kind {
        case .item(let number, let done, let bullet) where done != nil || number != nil || bullet != "-": steps += 1
        case .quote: steps += 1
        default: break
        }
        return CGFloat(steps) * step
    }
    /// A note's first heading is its own; those under it are structure, and read
    /// as a section's name — at the body's size, set apart by weight and room.
    static let headingScales: [CGFloat] = [1.3, 1.02, 1, 1, 0.95, 0.95]

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
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: whole)

        // Lines: indentation, and the fonts a whole line takes.
        for (index, line) in layout.lines.enumerated() {
            let range = NSRange(location: Int(line.start), length: Int(line.end - line.start))
            guard NSMaxRange(range) <= storage.length else { continue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            let indent = Self.wordsIndent(of: line, step: theme.step, prose: prose)
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
            paragraph.paragraphSpacing = (size * (prose && line.depth <= 1 ? 0.7 : 0.2)).rounded()
            switch line.kind {
            case .heading(let level):
                let scale = Self.headingScales[min(max(Int(level), 1), 6) - 1]
                storage.addAttribute(.font, value: theme.font(size * scale, weight: .semibold), range: range)
                paragraph.paragraphSpacingBefore += index == 0 ? 0 : (size * 0.5).rounded()
            case .item(_, let done, _):
                if done == true {
                    // Done, as Bike's: struck through, thick.
                    let words = NSRange(location: Int(line.content), length: max(Int(line.end) - Int(line.content), 0))
                    storage.addAttributes([.foregroundColor: theme.secondary, .strikethroughStyle: NSUnderlineStyle.thick.rawValue, .strikethroughColor: theme.secondary], range: words)
                }
            case .quote:
                // As Bike's: its words a step in (see `wordsIndent`), the bar in that step.
                storage.addAttribute(.prismQuote, value: true, range: range)
                storage.addAttribute(.foregroundColor, value: theme.secondary, range: range)
            case .code:
                // Only the code: its fences are Markdown, and never in the view. Room
                // above and below it, where its fences stood, sets it apart.
                storage.addAttribute(.font, value: theme.mono(size * 0.92), range: range)
                paragraph.paragraphSpacingBefore += (size * 0.5).rounded()
                paragraph.paragraphSpacing += (size * 0.3).rounded()
            case .rule:
                storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
            default:
                break
            }
            // The last row has nothing after it to be set apart from: no room after it,
            // which would only stand empty under the note.
            if index == layout.lines.count - 1 { paragraph.paragraphSpacing = 0 }
            // The paragraph's style covers its line break too.
            let paragraphRange = NSRange(location: range.location, length: min(range.length + 1, storage.length - range.location))
            if paragraphRange.length > 0 { storage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange) }
        }

        // Runs: emphasis, links, tags, and the markup around them.
        var lineIndex = 0
        var markupEnd: [Int: Int] = [:]
        for run in layout.runs where run.kind == .markup { markupEnd[Int(run.start)] = Int(run.end) }
        // Rows drawn as their link's card: their words are put away under the card, and
        // are given no link's look — its icon would stand out in the margin.
        let cardLines = Set(layout.lines.indices.filter { index in
            let line = layout.lines[index]
            let written = rowMarkdown(index) ?? ""
            return line.isCard && !revealed.contains(index) && EditorBlock.cardLink(written) != nil
        })
        for run in layout.runs {
            let range = NSRange(location: Int(run.start), length: Int(run.end - run.start))
            guard range.length > 0, NSMaxRange(range) <= storage.length, !layout.lines.isEmpty else { continue }
            while lineIndex + 1 < layout.lines.count, Int(layout.lines[lineIndex + 1].start) <= range.location { lineIndex += 1 }
            while lineIndex > 0, Int(layout.lines[lineIndex].start) > range.location { lineIndex -= 1 }
            let line = layout.lines[lineIndex]
            if cardLines.contains(lineIndex) { continue }
            switch run.kind {
            case .markup:
                hide(storage, range)
            case .strong:
                restyle(storage, range) { theme.font($0.pointSize, weight: .semibold, italic: $0.isItalic) }
            case .emphasis:
                restyle(storage, range) { theme.font($0.pointSize, weight: $0.isBold ? .semibold : .regular, italic: true) }
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .highlight:
                storage.addAttribute(.backgroundColor, value: theme.highlight, range: range)
            case .code:
                // Monospaced, and nothing behind it — as Bike's code in words.
                storage.addAttributes([.font: theme.mono(size * 0.92)], range: range)
            case .pageLink(let target, _):
                let isRiver = riverName(linkTarget: target) != nil
                let missing = !isRiver && !pageExists(target)
                // Its icon before it only where the page has one of its own — a day's is the calendar.
                let symbol = isRiver ? "square.stack" : (linkIcon(target) ?? (isDate(target) ? "calendar" : nil))
                link(storage, range, to: .page(target), symbol: symbol, missing: missing, line: line, markupEnd: markupEnd, faint: !isRiver && !missing && pageArchived(target))
                // A link written with its page's file's name shows the page's title — off the lines being written in.
                let words = (storage.string as NSString).substring(with: range)
                if words == "\u{FFFC}" {
                    // A link to a page is one character: drawn as its page's title, or its own name.
                    // Its icon in its own room, first: never out over what stands before the row's words.
                    relabel(storage, range, as: isRiver ? target : (linkLabel(target) ?? target), lead: symbol == nil ? 0 : leadWidth)
                } else if !isRiver, words == target, let label = linkLabel(target) {
                    relabel(storage, range, as: label)
                }
            case .webLink(let url):
                // An address shown as itself is cut to what says where it leads.
                let bare = (storage.string as NSString).substring(with: range) == url
                link(storage, range, to: .web(url), symbol: nil, missing: false, line: line, markupEnd: markupEnd, leaves: true)
                if bare { shorten(storage, range, address: url as NSString, lead: range.location == Int(line.start)) }
            case .tag(let name):
                link(storage, range, to: .tag(name), symbol: nil, missing: false, line: line, markupEnd: markupEnd)
            case .image:
                if (storage.string as NSString).substring(with: range) == "\u{FFFC}" {
                    // A picture, one character among the words: it takes no room; the picture is shown under them.
                    storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: EditorColor.clear], range: range)
                } else {
                    storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
                }
            case .bullet:
                if case .item(let number, let done, let bullet) = line.kind {
                    if number != nil {
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
                // With the space after it.
                let length = min(range.length + 1, Int(line.content) - range.location)
                storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: EditorColor.clear], range: NSRange(location: range.location, length: max(length, range.length)))
            case .quoteMark:
                let length = min(Int(line.content) - range.location, storage.length - range.location)
                hide(storage, NSRange(location: range.location, length: max(length, range.length)))
            case .callout:
                storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
            case .fenceInfo:
                break
            }
        }
        storage.endEditing()
    }

    private func hide(_ storage: NSTextStorage, _ range: NSRange) {
        storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: EditorColor.clear, .prismMarkup: true], range: range)
    }

    private func link(_ storage: NSTextStorage, _ range: NSRange, to target: EditorLink, symbol: String?, missing: Bool, line: BodyLine, markupEnd: [Int: Int], leaves: Bool = false, faint: Bool = false) {
        // A link to a page not written yet, or to one archived: in the secondary ink.
        let tint = missing || faint ? theme.secondary : theme.accent
        storage.addAttributes([.foregroundColor: tint, .prismLink: LinkBox(target)], range: range)
        if missing {
            restyle(storage, range) { theme.font($0.pointSize, weight: $0.isBold ? .semibold : .regular, italic: true) }
        }
        // In a heading, a link is only coloured.
        if case .heading = line.kind { return }
        let closes = markupEnd[NSMaxRange(range)].map { $0 > NSMaxRange(range) } ?? false
        // A link to a page shown as its title — one character — has its icon's room in it.
        let atom = (storage.string as NSString).substring(with: range) == "\u{FFFC}"
        storage.addAttribute(.prismPill, value: Pill(symbol: symbol, tint: tint, isMissing: missing, leaves: leaves, roomInside: leaves && !closes, iconInside: atom), range: range)
        // Room for the icon, on the last character of the markup before the words…
        if symbol != nil, !atom, range.location > Int(line.start) {
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
    private func relabel(_ storage: NSTextStorage, _ range: NSRange, as label: String, lead: CGFloat = 0) {
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
        // What the first character takes, as it is laid out: in its own font — and a link
        // to a page, one object-replacement character (U+FFFC) with nothing attached, none,
        // though a font may measure it a letter wide.
        let character = (storage.string as NSString).character(at: first.location)
        let own = character == 0xFFFC ? 0 : (storage.string as NSString).substring(with: first).size(withAttributes: [.font: font]).width
        storage.addAttributes([.foregroundColor: EditorColor.clear, .kern: max(lead + text.size().width.rounded(.up) - own, 0), .prismLabel: LinkLabel(text, lead: lead)], range: first)
        if range.length > 1 {
            storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: EditorColor.clear, .prismMarkup: true], range: NSRange(location: range.location + 1, length: range.length - 1))
        }
    }

    /// Hides what of a web address says nothing: its scheme, a leading
    /// `www.`, and everything from its query on. Off the lines being
    /// written in only; the address itself is not touched.
    private func shorten(_ storage: NSTextStorage, _ range: NSRange, address: NSString, lead: Bool) {
        let hidden: [NSAttributedString.Key: Any] = [.font: Self.hiddenFont, .foregroundColor: EditorColor.clear, .prismMarkup: true]
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
    /// Whether the note is shown as prose: rows a step further out, and
    /// the top-level ones — paragraphs — with no handle and no guide.
    var prose = false

    /// Whether a row is drawn with its handle: as prose, a paragraph is not.
    private func hasHandle(_ row: BodyLine) -> Bool {
        !(prose && row.depth <= 1)
    }

    /// The row whose mark — a bullet, a number, a ring — is at a point:
    /// its place among the lines. Not a task's box, which is ticked.
    func mark(at point: CGPoint) -> Int? {
        // Every row's handle, as Bike's — a task's too; its box is in the step after.
        for (index, row) in lines.enumerated() {
            guard let line = firstLine(of: row) else { continue }
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
        guard textStorage?.length == 0 else { return }
        if prose { return }
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

    /// Whether the note is being written in: an empty one being written in
    /// shows the bullet its first row will have.
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
        return CGRect(x: CGFloat(Int(row.depth) - 1 - (prose ? 1 : 0)) * step, y: line.rect.minY, width: step, height: line.rect.height)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let font = theme.body

        if let chosen {
            // Each row chosen, a band the width of the note — its mark's room with it.
            // As Bike's: each row's band from where its words begin to the note's edge, meeting the next.
            theme.accent.withAlphaComponent(0.18).setFill()
            for row in lines where Int(row.start) <= chosen.upperBound && Int(row.end) >= chosen.lowerBound && Int(row.start) >= chosen.lowerBound {
                let glyphs = glyphRange(forCharacterRange: NSRange(location: Int(row.start), length: max(Int(row.end) - Int(row.start), 0)), actualCharacterRange: nil)
                var rect = glyphs.length > 0 ? boundingRect(forGlyphRange: glyphs, in: container) : (firstLine(of: row)?.rect ?? .null)
                guard !rect.isNull else { continue }
                let left = max(CGFloat(Int(row.depth) - (prose ? 1 : 0)) * theme.step - 3, 0)
                rect.origin.x = left
                rect.size.width = container.size.width - left
                Self.roundedPath(rect.offsetBy(dx: origin.x, dy: origin.y), radius: 3).fill()
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

        // An outline's marks, beside the rows being drawn — as Bike 2's: every row
        // its handle, a triangle in the step before it (turned down when its rows are
        // shown; dark when they are folded away); a typed row its own mark too, in the
        // step after the handle — the box, the number, the dot.
        for row in rows where Int(row.start) <= NSMaxRange(characters) && Int(row.end) >= characters.location {
            guard let line = firstLine(of: row) else { continue }
            let box = markBox(of: row, on: line).offsetBy(dx: origin.x, dy: origin.y)
            let baseline = line.baseline + origin.y
            var number: UInt32?, done: Bool?, bullet = "-"
            if case .item(let n, let d, let b) = row.kind { (number, done, bullet) = (n, d, b) }
            if let lead, leadStart == Int(row.start), done == nil, number == nil {
                drawLead(lead, midX: box.midX, baseline: baseline, origin: origin)
                continue
            }
            // A plain row with nothing in it and nothing under it has no handle, as Bike's.
            let bare = row.end <= row.start && !row.hasChildren && done == nil && number == nil && bullet == "-"
            if !bare, hasHandle(row) { drawHandle(midX: box.midX, midY: baseline - font.xHeight / 2, expanded: row.hasChildren && !row.isFolded, dark: row.hasChildren && row.isFolded) }
            let mark = box.offsetBy(dx: theme.step, dy: 0)
            if let done {
                let side = (size * 0.95).rounded()
                let name = bullet == "+" ? (done ? "checkmark.circle.fill" : "circle") : (done ? "checkmark.square.fill" : "square")
                Self.draw(symbol: name, in: CGRect(x: mark.midX - side / 2, y: baseline - font.capHeight / 2 - side / 2, width: side, height: side), pointSize: side, weight: .regular, colors: done ? [.white, theme.accent] : [theme.secondary])
            } else if let number {
                let label = "\(number)\(bullet)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: EditorFont.monospacedDigitSystemFont(ofSize: size * 0.9, weight: .regular), .foregroundColor: theme.text]
                let width = label.size(withAttributes: attributes).width
                label.draw(at: CGPoint(x: mark.maxX - 6 - width, y: baseline - font.ascender * 0.9 - 1), withAttributes: attributes)
            } else if bullet != "-", case .item = row.kind {
                let diameter = max(4.5, (size * 0.3).rounded())
                theme.text.setFill()
                Self.ovalPath(CGRect(x: mark.midX - diameter / 2, y: baseline - font.xHeight / 2 - diameter / 2, width: diameter, height: diameter)).fill()
            }
        }
        // Guide lines, as Bike's: down from an expanded row's handle, the height of what it shows.
        for (index, row) in rows.enumerated() where row.hasChildren && !row.isFolded && hasHandle(row) {
            guard let first = firstLine(of: row) else { continue }
            var last = index
            while last + 1 < rows.count, rows[last + 1].depth > row.depth { last += 1 }
            guard last > index, let end = lastLine(of: rows[last]) else { continue }
            let x = markBox(of: row, on: first).midX + origin.x
            let top = first.rect.maxY + origin.y
            let bottom = end.rect.maxY + origin.y
            guard top < bottom else { continue }
            theme.text.withAlphaComponent(0.12).setFill()
            Self.roundedPath(CGRect(x: (x - 0.5).rounded(), y: top, width: 1, height: bottom - top), radius: 0).fill()
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
                // The icon's room is before the link's words — in a link to a page, its own first.
                // Nothing behind a link: its colour says it is one. Its page's icon before it…
                if first, let symbol = pill.symbol {
                    let x = pill.iconInside ? rect.minX : rect.minX - side - 5
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
            label.text.draw(at: CGPoint(x: fragment.minX + at.x + label.lead + origin.x, y: fragment.minY + at.y - font.ascender + origin.y))
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
            let bar = CGRect(x: max(left - theme.step / 2 - 2, 0), y: whole.minY, width: 4, height: whole.height)
            if let last = bars.last, abs(last.minX - bar.minX) < 1, bar.minY - last.maxY < size * 0.9 {
                bars[bars.count - 1] = last.union(bar)
            } else {
                bars.append(bar)
            }
        }
        theme.faint.setFill()
        for bar in bars {
            // Bike's quote: a faint, rounded box behind the words, the bar at its left edge.
            let block = CGRect(x: bar.minX - 1, y: bar.minY, width: container.size.width - bar.minX + 1, height: bar.height).offsetBy(dx: origin.x, dy: origin.y)
            theme.text.withAlphaComponent(0.025).setFill()
            Self.roundedPath(block, radius: 3).fill()
            theme.text.withAlphaComponent(0.06).setStroke()
            let outline = Self.roundedPath(block.insetBy(dx: 0.25, dy: 0.25), radius: 3)
            outline.lineWidth = 0.5
            outline.stroke()
            theme.secondary.setFill()
            let drawn = CGRect(x: bar.minX, y: bar.minY + 2, width: 4, height: max(bar.height - 4, 2)).offsetBy(dx: origin.x, dy: origin.y)
            Self.roundedPath(drawn, radius: 2).fill()
        }
    }

    /// A row's handle: a small triangle pointing at its words — down when its rows are shown.
    private func drawHandle(midX: CGFloat, midY: CGFloat, expanded: Bool, dark: Bool) {
        #if os(macOS)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        #else
        guard let context = UIGraphicsGetCurrentContext() else { return }
        #endif
        let side = (size * 0.42).rounded()
        let (x, y) = (midX.rounded(), midY.rounded())
        let points: [CGPoint] = expanded
            ? [CGPoint(x: x - side / 2, y: y - side * 0.3), CGPoint(x: x + side / 2, y: y - side * 0.3), CGPoint(x: x, y: y + side * 0.45)]
            : [CGPoint(x: x - side * 0.3, y: y - side / 2), CGPoint(x: x + side * 0.45, y: y), CGPoint(x: x - side * 0.3, y: y + side / 2)]
        context.saveGState()
        context.setFillColor((dark ? theme.secondary : theme.text.withAlphaComponent(0.22)).cgColor)
        context.addLines(between: points)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    /// Weft's pill on a folded row, with how many it hides: not drawn, as Bike shows a fold by its handle.
    static let drawsFoldPills = false

    /// Where a row's last line is.
    private func lastLine(of row: BodyLine) -> (rect: CGRect, baseline: CGFloat)? {
        guard let storage = textStorage, row.end > row.start, Int(row.end) <= storage.length else { return firstLine(of: row) }
        let glyph = glyphIndexForCharacter(at: Int(row.end) - 1)
        let rect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return (rect, rect.minY + location(forGlyphAt: glyph).y)
    }

    // MARK: An outline's rows, where a touch finds them

    /// How many rows a row is under: what its mark is set in by.
    func level(of row: BodyLine) -> Int {
        // Every row as a row: a top-level row of any kind is at depth 1 — as prose, a step further out.
        Int(row.depth) - 1 - (prose ? 1 : 0)
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
        let left = max(theme.step * CGFloat(level(of: lines[rows.lowerBound])), 0)
        rect.size.width = max(rect.maxX - left, 0)
        rect.origin.x = left
        return rect.integral
    }

    /// The row whose mark — its bullet, its number, its box — is at a
    /// point, if one is: the step before its words, on any of its lines.
    func marker(at point: CGPoint, in container: NSTextContainer) -> Int? {
        guard let index = row(at: point, in: container) else { return nil }
        guard hasHandle(lines[index]) else { return nil }
        let left = theme.step * CGFloat(level(of: lines[index]))
        return point.x > left - 6 && point.x < left + theme.step - 2 ? index : nil
    }

    /// Where a folded row's pill is, in the container: after the words of
    /// its last line, on the middle of their capitals.
    func foldPill(ofRow index: Int) -> CGRect? {
        // Bike shows a folded row by its dark handle, and no pill — but a paragraph, as prose, has no handle.
        guard lines.indices.contains(index), Self.drawsFoldPills || !hasHandle(lines[index]), lines[index].isFolded, let storage = textStorage else { return nil }
        let line = lines[index]
        let font = theme.body
        let height = (font.capHeight + 9).rounded()
        let size = CGSize(width: (height * 1.7).rounded(), height: height)
        guard line.end > line.start, Int(line.end) <= storage.length else {
            // No words: where they would begin.
            guard let first = firstLine(of: line) else { return nil }
            return CGRect(origin: CGPoint(x: CGFloat(Int(line.depth) - (prose ? 1 : 0)) * theme.step, y: (first.baseline - font.capHeight / 2 - height / 2).rounded()), size: size)
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
        // An outline's box is in the step after its row's handle.
        for row in rows {
            guard case .item(_, let done, _) = row.kind, done != nil, let line = firstLine(of: row) else { continue }
            if markBox(of: row, on: line).offsetBy(dx: theme.step, dy: 0).contains(point) { return Int(row.start) }
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
