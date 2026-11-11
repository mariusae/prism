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
    let symbol: String?
    let tint: EditorColor
    let isMissing: Bool
    init(symbol: String?, tint: EditorColor, isMissing: Bool) {
        self.symbol = symbol
        self.tint = tint
        self.isMissing = isMissing
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
    /// What a page is shown as called — its title, or its first words —
    /// when that is not the name a link to it is written with: `nil`
    /// where the link already says it, or leads nowhere.
    var linkLabel: (String) -> String? = { _ in nil }

    static let hiddenFont = EditorFont.systemFont(ofSize: 0.1)
    static let headingScales: [CGFloat] = [1.45, 1.25, 1.12, 1.05, 1, 1]
    /// How far each level of a list written as text is set in.
    static let levelIndent: CGFloat = 20

    var size: CGFloat { theme.size }
    var iconSide: CGFloat { (size * 0.72).rounded() }
    /// The room before a pill's words for its icon.
    var leadWidth: CGFloat { 4 + iconSide + 3 }
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

    /// What a timeline's drawing is measured by: a row's height, the room
    /// over a block's words for its time, that label's size, and the gap
    /// after a timeline's last block.
    struct TimeMeasures {
        var row: CGFloat
        var header: CGFloat
        var labelSize: CGFloat
        var pad: CGFloat

        /// The room a block ending at a row takes after it: a little for
        /// its length, its free time, and, its timeline's last, a gap.
        func extent(_ foot: BodyTimeFoot) -> CGFloat {
            ((foot.length + foot.freeLength) * row).rounded() + (foot.isLast ? pad : 0)
        }

        func footHeight(_ mark: BodyTimeMark) -> CGFloat {
            mark.feet.reduce(0) { $0 + extent($1) }
        }
    }

    var timeMeasures: TimeMeasures {
        let labelSize = (size * 0.7).rounded()
        return TimeMeasures(row: (theme.body.ascender - theme.body.descender + theme.body.leading).rounded(.up) + 3 + (size * 0.2).rounded(), header: (labelSize * 1.3).rounded(.up), labelSize: labelSize, pad: (size * 0.4).rounded())
    }

    /// Dresses a storage as a layout says. `revealed` is the lines being
    /// written in; empty when the text is only read. `marks` is what an
    /// outline's timelines draw at its rows: room is left for it.
    func style(_ storage: NSTextStorage, layout: BodyLayout, revealed: Set<Int>, marks: [BodyTimeMark] = []) {
        let whole = NSRange(location: 0, length: storage.length)
        let outline = !layout.markersInText
        let timed = Dictionary(marks.map { (Int($0.row), $0) }, uniquingKeysWith: { first, _ in first })
        let measures = timeMeasures
        var stamps: [NSRange] = []
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
                if let mark = timed[index] {
                    // Room over a block's words for its time and length, and after its last row for how long it lasts.
                    if let head = mark.head {
                        paragraph.paragraphSpacingBefore += measures.header
                        // Its time is drawn over its words, and written among them only where they are written in.
                        if !shown, head.stampEnd > head.stampStart, Int(head.stampEnd) <= storage.length {
                            stamps.append(NSRange(location: Int(head.stampStart), length: Int(head.stampEnd - head.stampStart)))
                        }
                    }
                    paragraph.paragraphSpacing += measures.footHeight(mark)
                }
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
                storage.addAttributes([.font: theme.mono(size * 0.92), .foregroundColor: theme.faint], range: range)
            case .code:
                storage.addAttribute(.font, value: theme.mono(size * 0.92), range: range)
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
        for run in layout.runs {
            let range = NSRange(location: Int(run.start), length: Int(run.end - run.start))
            guard range.length > 0, NSMaxRange(range) <= storage.length, !layout.lines.isEmpty else { continue }
            while lineIndex + 1 < layout.lines.count, Int(layout.lines[lineIndex + 1].start) <= range.location { lineIndex += 1 }
            while lineIndex > 0, Int(layout.lines[lineIndex].start) > range.location { lineIndex -= 1 }
            let line = layout.lines[lineIndex]
            let shown = revealed.contains(lineIndex)
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
                let symbol = isRiver ? "square.stack" : (isDate(target) ? "calendar" : "doc.text")
                link(storage, range, to: .page(target), symbol: symbol, missing: missing, line: line, shown: shown, markupEnd: markupEnd)
                // A link written with its page's file's name shows the page's title — off the lines being written in.
                if !shown, !isRiver, !missing, (storage.string as NSString).substring(with: range) == target, let label = linkLabel(target) {
                    relabel(storage, range, as: label)
                }
            case .webLink(let url):
                // An address shown as itself is cut to what says where it leads.
                let bare = (storage.string as NSString).substring(with: range) == url
                link(storage, range, to: .web(url), symbol: markupEnds.contains(range.location) || bare ? "link" : nil, missing: false, line: line, shown: shown, markupEnd: markupEnd)
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
        for stamp in stamps { storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: EditorColor.clear], range: stamp) }
        storage.endEditing()
    }

    private func hide(_ storage: NSTextStorage, _ range: NSRange, shown: Bool) {
        if shown {
            storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
        } else {
            storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: EditorColor.clear], range: range)
        }
    }

    private func link(_ storage: NSTextStorage, _ range: NSRange, to target: EditorLink, symbol: String?, missing: Bool, line: BodyLine, shown: Bool, markupEnd: [Int: Int]) {
        let tint = missing ? theme.secondary : theme.accent
        storage.addAttributes([.foregroundColor: tint, .prismLink: LinkBox(target)], range: range)
        if missing {
            restyle(storage, range) { theme.font($0.pointSize, weight: $0.isBold ? .semibold : .regular, italic: true) }
        }
        // In a heading, and on a line being written in, a link is only coloured.
        if case .heading = line.kind { return }
        guard !shown else { return }
        storage.addAttribute(.prismPill, value: Pill(symbol: symbol, tint: tint, isMissing: missing), range: range)
        // Room for the icon, on the last character of the markup before the words…
        if symbol != nil, range.location > Int(line.start) {
            storage.addAttribute(.kern, value: leadWidth, range: NSRange(location: range.location - 1, length: 1))
        }
        // …and a little after them, on the last of the markup that closes.
        if let end = markupEnd[NSMaxRange(range)], end > NSMaxRange(range) {
            storage.addAttribute(.kern, value: CGFloat(3), range: NSRange(location: end - 1, length: 1))
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
    /// What an outline's timelines draw at its rows.
    var marks: [BodyTimeMark] = []
    /// The rows being written in: a time block's label is not drawn over
    /// one, where its time is written out.
    var written = Set<Int>()
    /// Whether the note is today's: its timelines show the time now.
    var isToday = false
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
            let tint = lead.tint ?? theme.secondary
            let ring = box.insetBy(dx: side * 0.16, dy: side * 0.16), line = max(side * 0.11, 1.5)
            let track = EditorBezier(ovalIn: ring)
            track.lineWidth = line
            tint.withAlphaComponent(0.25).setStroke()
            track.stroke()
            if progress > 0 {
                let arc = EditorBezier.arc(center: CGPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2, fraction: min(progress, 1))
                arc.lineWidth = line
                tint.setStroke()
                arc.stroke()
            }
            leadBox = box.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -4, dy: -4)
            return
        }
        Self.draw(symbol: lead.symbol, in: box, pointSize: side * (lead.isDone ? 1 : 0.92), weight: .regular, colors: lead.isDone ? [.white, theme.accent] : [lead.tint ?? theme.secondary])
        leadBox = box.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -4, dy: -4)
    }

    /// Whether a point of the container is on the lead.
    func isLead(at point: CGPoint) -> Bool {
        lead != nil && leadBox?.contains(point) == true
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
            if row.end <= row.start { return (rect, rect.minY + theme.body.ascender + 1.5) }
            return (rect, rect.minY + location(forGlyphAt: glyph).y)
        }
        // The last row, with nothing in it yet: the line the caret waits on.
        let rect = extraLineFragmentRect
        guard rect.height > 0 else { return nil }
        return (rect, rect.minY + theme.body.ascender + 1.5)
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

        drawTimeMarks(at: origin, in: characters)
        for (index, line) in lines.enumerated() where line.isFolded && Int(line.start) <= NSMaxRange(characters) && Int(line.end) >= characters.location {
            if let pill = foldPill(ofRow: index) { drawFoldPill(in: pill.offsetBy(dx: origin.x, dy: origin.y)) }
        }

        // An outline's marks, beside the rows being drawn.
        let nodes = Set(marks.filter { $0.head != nil }.compactMap { lines.indices.contains(Int($0.row)) ? Int(lines[Int($0.row)].start) : nil })
        for row in rows where Int(row.start) <= NSMaxRange(characters) && Int(row.end) >= characters.location {
            guard case .item(let number, let done, let bullet) = row.kind, let line = firstLine(of: row) else { continue }
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
            } else if !nodes.contains(Int(row.start)) {
                // (A time block's bullet is its node on the timeline, drawn with the line.)
                let diameter = max(4.5, (size * 0.3).rounded())
                theme.secondary.setFill()
                Self.ovalPath(CGRect(x: box.midX - diameter / 2, y: baseline - font.xHeight / 2 - diameter / 2, width: diameter, height: diameter)).fill()
            }
        }

        storage.enumerateAttribute(.prismPill, in: characters) { value, range, _ in
            guard let pill = value as? Pill else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let pad: CGFloat = pill.symbol == nil ? 3 : 1
            let side = (size * 0.72).rounded()
            var first = true
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                // What of a link's hidden name fell onto another line is nothing to draw around.
                guard rect.width > 2 else { return }
                let fragment = self.lineFragmentRect(forGlyphAt: self.glyphIndex(for: CGPoint(x: rect.midX, y: rect.midY), in: container), effectiveRange: nil)
                let baseline = fragment.minY + self.location(forGlyphAt: glyphs.location).y
                let lead: CGFloat = first && pill.symbol != nil ? side + 6 : 0
                let box = CGRect(x: rect.minX - pad - lead, y: baseline - font.ascender.rounded(.up) - 2, width: rect.width + 2 * pad + lead, height: font.ascender.rounded(.up) + (-font.descender).rounded(.up) + 4)
                    .offsetBy(dx: origin.x, dy: origin.y)
                pill.tint.withAlphaComponent(pill.isMissing ? 0.10 : 0.12).setFill()
                Self.roundedPath(box, radius: 5).fill()
                if first, let symbol = pill.symbol {
                    let icon = CGRect(x: box.minX + 4, y: box.midY - side / 2, width: side, height: side)
                    Self.draw(symbol: symbol, in: icon, pointSize: side * 0.9, weight: .medium, colors: [pill.tint])
                }
                first = false
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

        storage.enumerateAttribute(.prismQuote, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var whole = CGRect.null
            var left = CGFloat.greatestFiniteMagnitude
            enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                whole = whole.union(used)
                left = min(left, used.minX)
            }
            guard !whole.isNull else { return }
            let bar = CGRect(x: max(left - 11, 0), y: whole.minY + 2, width: 3, height: max(whole.height - 4, 2)).offsetBy(dx: origin.x, dy: origin.y)
            theme.faint.setFill()
            Self.roundedPath(bar, radius: 1.5).fill()
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

    // MARK: Timelines

    /// A row's node on a timeline: where its bullet would be, on its
    /// first line — or, for a task, the middle of its box.
    private func node(of row: BodyLine) -> (point: CGPoint, baseline: CGFloat, isTask: Bool)? {
        guard let line = firstLine(of: row) else { return nil }
        var isTask = false
        if case .item(_, let done, _) = row.kind { isTask = done != nil }
        let font = theme.body
        let box = markBox(of: row, on: line)
        return (CGPoint(x: box.midX, y: line.baseline - (isTask ? font.capHeight : font.xHeight) / 2), line.baseline, isTask)
    }

    /// Draws the timelines: for each block a line down from its node,
    /// solid while it lasts and dashed while the time after it is free,
    /// its time and length over its words, and — in today's note — the
    /// time now, on the line it falls on.
    private func drawTimeMarks(at origin: CGPoint, in characters: NSRange) {
        guard !marks.isEmpty, !lines.isEmpty else { return }
        let measures = BodyStyler(theme: theme).timeMeasures
        let feet = Dictionary(marks.map { (Int($0.row), $0) }, uniquingKeysWith: { first, _ in first })
        let now: Int? = isToday ? {
            let time = Calendar.current.dateComponents([.hour, .minute], from: Date())
            return (time.hour ?? 0) * 60 + (time.minute ?? 0)
        }() : nil
        for mark in marks {
            guard let head = mark.head, lines.indices.contains(Int(mark.row)), lines.indices.contains(Int(head.lastRow)) else { continue }
            let row = lines[Int(mark.row)]
            // Only those that reach the lines being drawn: a block's line runs on to the next block's node.
            let reach = lines[min(Int(head.nextRow ?? head.lastRow), lines.count - 1)]
            guard Int(row.start) <= NSMaxRange(characters), Int(reach.end) >= characters.location, let node = node(of: row) else { continue }
            // Where the block ends: its last row's foot, after those of blocks nested in it that end there too.
            let foot = feet[Int(head.lastRow)]
            var cursor = rect(ofRow: Int(head.lastRow)).maxY - (foot.map(measures.footHeight) ?? 0)
            var end = cursor
            var free: ClosedRange<CGFloat>?
            var freeRoom: ClosedRange<CGFloat>?
            var freeLabel: String?
            let nextY = head.nextRow.flatMap { lines.indices.contains(Int($0)) ? self.node(of: lines[Int($0)])?.point.y : nil }
            for each in foot?.feet ?? [] {
                let rest = measures.extent(each)
                if each.timeline == head.timeline, each.index == head.index {
                    end = cursor + (each.length * measures.row).rounded()
                    if each.free > 0 {
                        free = end...max(end, (nextY ?? cursor + rest) - 6)
                        freeRoom = end...max(end, cursor + rest)
                        freeLabel = each.freeLabel
                    }
                    break
                }
                cursor += rest
            }
            if free == nil, let nextY { end = max(end, nextY - 6) }
            let color = head.isDone ? theme.faint : theme.accent
            let x = node.point.x + origin.x
            let top = node.point.y + (node.isTask ? size * 0.45 : 3.5) + 2 + origin.y
            let bottom = end + origin.y
            // The line: solid while the block lasts, dashed while free.
            if bottom > top {
                color.withAlphaComponent(head.level > 0 ? 0.45 : 0.6).setStroke()
                let solid = EditorPath()
                solid.move(to: CGPoint(x: x, y: top))
                solid.addLine(to: CGPoint(x: x, y: bottom))
                solid.lineWidth = 1.5
                solid.stroke()
            }
            if let free, free.upperBound > free.lowerBound {
                theme.faint.setStroke()
                let dashed = EditorPath()
                dashed.move(to: CGPoint(x: x, y: free.lowerBound + origin.y + 2))
                dashed.addLine(to: CGPoint(x: x, y: free.upperBound + origin.y))
                dashed.lineWidth = 1
                dashed.setLineDash([2, 3], count: 2, phase: 0)
                dashed.stroke()
            }
            let labelX = CGFloat(row.depth) * theme.step
            if let freeLabel, let freeRoom {
                let label = NSAttributedString(string: freeLabel, attributes: [.font: EditorFont.systemFont(ofSize: measures.labelSize), .foregroundColor: theme.faint])
                let height = label.size().height
                if freeRoom.upperBound - freeRoom.lowerBound >= height {
                    label.draw(at: CGPoint(x: labelX + origin.x, y: (freeRoom.lowerBound + freeRoom.upperBound) / 2 - height / 2 + origin.y))
                }
            }
            // The node: filled; hollow for a block nested in another's. A task's box is its node.
            if !node.isTask {
                let dot = CGRect(x: x - 3.5, y: node.point.y + origin.y - 3.5, width: 7, height: 7)
                if head.level > 0 {
                    let ring = Self.ovalPath(dot.insetBy(dx: 0.75, dy: 0.75))
                    ring.lineWidth = 1.5
                    color.setStroke()
                    ring.stroke()
                } else {
                    color.setFill()
                    Self.ovalPath(dot).fill()
                }
            }
            // The time and length over the words — but for the row whose time is written out, where it would say it twice.
            if !written.contains(Int(mark.row)) {
                let font = EditorFont.monospacedDigitSystemFont(ofSize: measures.labelSize, weight: .regular)
                let text = NSMutableAttributedString(string: head.label, attributes: [.font: font, .foregroundColor: theme.secondary])
                if let overlap = head.overlap {
                    // Named, when there is room for it.
                    let room = (textContainers.first?.size.width ?? 320) - labelX - 4
                    let full = NSAttributedString(string: head.label + " · " + overlap, attributes: [.font: font]).size().width
                    text.append(NSAttributedString(string: " · " + (full <= room ? overlap : head.overlapShort ?? overlap), attributes: [.font: font, .foregroundColor: EditorColor.systemOrange]))
                }
                text.draw(at: CGPoint(x: labelX + origin.x, y: node.baseline - theme.body.ascender - measures.header + origin.y))
            }
            // The time now, on the line, where it falls.
            if let now, Int(head.start) <= now, now < Int(head.end) {
                let share = CGFloat(now - Int(head.start)) / CGFloat(max(1, Int(head.end) - Int(head.start)))
                let y = top + (max(top, bottom) - top) * share
                EditorColor.systemRed.setFill()
                Self.ovalPath(CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)).fill()
            }
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
