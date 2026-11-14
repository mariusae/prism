import Foundation
import Prism

/// What a note gives the reader: a page on the web it links to, a PDF on
/// the web it links to, or a PDF in the graph it shows — its own page
/// first, a link note's `URL:`, then each as the note goes down, once.
public struct ReaderSource: Hashable, Sendable {
    /// As the note writes it: the page's address, or the PDF's path in the graph.
    public let address: String
    /// The page, or the PDF: its file in the graph, or its address on the web.
    public let url: URL
    public let isPDF: Bool

    public var isOnline: Bool { !url.isFileURL }

    /// Its name, short: the site, or the PDF's file.
    public var name: String {
        isPDF ? url.deletingPathExtension().lastPathComponent : (url.host ?? address).replacingOccurrences(of: "www.", with: "")
    }

    /// Everything in a note to read, in order: none, a note with nothing.
    public static func all(in text: String, root: URL) -> [ReaderSource] {
        var found: [ReaderSource] = []
        each(in: text, root: root) { source in
            if !found.contains(where: { $0.address == source.address }) { found.append(source) }
            return true
        }
        return found
    }

    /// Whether a note has anything to read: as `all` would find, stopping at the first.
    public static func any(in text: String, root: URL) -> Bool {
        guard text.contains("http") || text.range(of: ".pdf", options: .caseInsensitive) != nil else { return false }
        var has = false
        each(in: text, root: root) { _ in
            has = true
            return false
        }
        return has
    }

    /// Each thing to read in a note, as it goes down, until told to stop.
    private static func each(in text: String, root: URL, _ take: (ReaderSource) -> Bool) {
        if let own = ownAddress(in: text), let source = source(own, root: root), !take(source) { return }
        var fenced = false
        for line in body(of: text) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle()
                continue
            }
            guard !fenced, line.contains("http") || line.range(of: ".pdf", options: .caseInsensitive) != nil else { continue }
            let words = line as NSString
            // The engine's reading of a line's links: the same as the editor shows.
            for span in inlineSpans(text: line) {
                let address: String?
                switch span.kind {
                case .link(let target, _): address = target
                case .autolink(let url): address = url
                case .url: address = Int(span.end) <= words.length && span.start < span.end ? words.substring(with: NSRange(location: Int(span.start), length: Int(span.end - span.start))) : nil
                case .image(let source, _, _, _): address = source.lowercased().hasSuffix(".pdf") ? source : nil
                default: address = nil
                }
                if let address, let source = source(address, root: root), !take(source) { return }
            }
        }
    }

    /// A note's lines, without its frontmatter.
    static func body(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...close) }
        return lines
    }

    /// The address a link note is of — its `URL:` line, at the top level —
    /// or nil for a note that is not one.
    public static func ownAddress(in text: String) -> String? {
        guard text.contains("URL:") else { return nil }
        for line in body(of: text) where line.contains("URL:") {
            guard let first = line.first, first != " ", first != "\t" else { continue }
            var words = Substring(line)
            for marker in ["- ", "* ", "+ "] where words.hasPrefix(marker) {
                words = words.dropFirst(2)
                break
            }
            let said = words.trimmingCharacters(in: .whitespaces)
            guard said.hasPrefix("URL:") else { continue }
            var address = said.dropFirst(4).trimmingCharacters(in: .whitespaces)
            if address.hasPrefix("<"), address.hasSuffix(">") { address = String(address.dropFirst().dropLast()) }
            // `[title](address)`, as some captures write it.
            if let open = address.range(of: "]("), address.hasSuffix(")") {
                address = String(address[open.upperBound..<address.index(before: address.endIndex)])
            }
            return address.hasPrefix("http") ? address : nil
        }
        return nil
    }

    /// A page on the web, a PDF there, or a PDF in the graph's assets: nil, anything else.
    static func source(_ address: String, root: URL) -> ReaderSource? {
        if address.hasPrefix("http://") || address.hasPrefix("https://") {
            // Not a picture, or a file to download.
            guard let url = URL(string: address) else { return nil }
            let last = url.path.lowercased()
            guard ![".png", ".jpg", ".jpeg", ".gif", ".webp", ".zip", ".mp4", ".mov"].contains(where: last.hasSuffix) else { return nil }
            let isPDF = last.hasSuffix(".pdf") || (url.host?.lowercased().hasSuffix("arxiv.org") == true && last.hasPrefix("/pdf/"))
            return ReaderSource(address: address, url: url, isPDF: isPDF)
        }
        // Inside `assets/`, and no `..` out of it.
        let path = address.removingPercentEncoding ?? address
        guard path.lowercased().hasSuffix(".pdf"), path.hasPrefix("assets/"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        let file = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return ReaderSource(address: address, url: file, isPDF: true)
    }
}

/// The reading queue: the inbox's notes with something to read, one at a
/// time, the oldest first — each done with, or put off, before the next.
///
/// Nothing of its own marks a note as in it. A note is in the queue while
/// it is in the inbox (`inbox: true`), has something to read — a page it
/// links to, a PDF it holds — and is not put off. Put off, its
/// frontmatter says till when: `snoozed_until: 2026-10-28T08:00`, this
/// device's own time.
public enum ReadingQueue {
    /// The frontmatter key a note is put off by: when it comes back.
    public static let snoozeKey = "snoozed_until"

    /// When a note is put off till, as its field says: nil, not put off.
    public static func until(_ written: String?) -> Date? {
        guard let written = written?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) else { return nil }
        return stamp.date(from: written) ?? day.date(from: written)
    }

    /// A time as the frontmatter has it.
    public static func written(_ date: Date) -> String { stamp.string(from: date) }

    /// When a note comes back, as said: "today at 18:00", "tomorrow at
    /// 8:00", "on Saturday at 9:00", "on November 27 at 8:00".
    public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow at \(time)" }
        if date.timeIntervalSince(now) < 6 * 86400 { return "on \(date.formatted(.dateTime.weekday(.wide))) at \(time)" }
        return "on \(date.formatted(.dateTime.month(.wide).day())) at \(time)"
    }

    /// What is said with nothing left to read.
    public static func restDetail(next: Date?) -> String {
        next.map { "Notes put off come back, the first \(when($0))." } ?? "The inbox has no links left to read."
    }

    private static let stamp = formatter("yyyy-MM-dd'T'HH:mm")
    private static let day = formatter("yyyy-MM-dd")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// How long it is put off for.
    public enum Snooze: CaseIterable, Sendable {
        case laterToday, tomorrow, weekend, nextWeek, nextMonth

        public var title: String {
            switch self {
            case .laterToday: return "Later Today"
            case .tomorrow: return "Tomorrow"
            case .weekend: return "This Weekend"
            case .nextWeek: return "Next Week"
            case .nextMonth: return "Next Month"
            }
        }

        public var symbol: String {
            switch self {
            case .laterToday: return "clock"
            case .tomorrow: return "sunrise"
            case .weekend: return "sofa"
            case .nextWeek: return "calendar"
            case .nextMonth: return "calendar.badge.clock"
            }
        }

        /// When it comes back: in three hours; the next morning; Saturday's,
        /// or Monday's, morning; a month on, in the morning.
        public func until(from now: Date, calendar: Calendar = .current) -> Date {
            func morning(_ date: Date, hour: Int = 8) -> Date { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date }
            func next(weekday: Int) -> Date { calendar.nextDate(after: now, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime) ?? now }
            switch self {
            case .laterToday: return now.addingTimeInterval(3 * 3600)
            case .tomorrow: return morning(calendar.date(byAdding: .day, value: 1, to: now) ?? now)
            case .weekend: return morning(next(weekday: 7), hour: 9)
            case .nextWeek: return morning(next(weekday: 2))
            case .nextMonth: return morning(calendar.date(byAdding: .month, value: 1, to: now) ?? now)
            }
        }
    }
}

/// Passages highlighted in what a note reads, kept in the note: on a link
/// note's own page, under its `Highlights`; on any other page, or a PDF,
/// under the line that links to it, each a bullet of its own quoted with `> `.
public enum ReaderHighlights {
    private static let marker = try? NSRegularExpression(pattern: #"^(\s*)(?:[-*+]|\d+[.)])\s+(?:\[.\]\s+)?"#)

    /// A line's indent, and its words without the marker a list's line opens with; whether it has one.
    private static func parts(_ line: String) -> (indent: String, words: String, isItem: Bool) {
        let whole = NSRange(location: 0, length: (line as NSString).length)
        if let match = marker?.firstMatch(in: line, range: whole) {
            return ((line as NSString).substring(with: match.range(at: 1)), (line as NSString).substring(from: NSMaxRange(match.range)), true)
        }
        return (String(line.prefix(while: { $0 == " " || $0 == "\t" })), line.trimmingCharacters(in: .whitespaces), false)
    }

    private static func width(_ indent: String) -> Int { indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func unquoted(_ words: String) -> String {
        oneLine(words.hasPrefix(">") ? String(words.dropFirst()) : words)
    }

    /// The line passages go under, and the lines under it: for a link
    /// note's own page its `Highlights`, else the first line naming the address.
    private static func place(in lines: [String], of address: String, own: Bool) -> (line: Int, end: Int)? {
        let found = lines.indices.first { index in
            let line = parts(lines[index])
            return own ? width(line.indent) == 0 && line.words.trimmingCharacters(in: .whitespaces) == "Highlights" : lines[index].contains(address)
        }
        guard let found else { return nil }
        let depth = width(parts(lines[found]).indent)
        var end = found + 1, at = found + 1
        // Everything further in than it; a blank line between does not end it.
        while at < lines.count {
            if lines[at].trimmingCharacters(in: .whitespaces).isEmpty {
                at += 1
                continue
            }
            guard width(parts(lines[at]).indent) > depth else { break }
            at += 1
            end = at
        }
        return (found, end)
    }

    /// The bullets right under a line: where each is, and what it says.
    private static func children(of place: (line: Int, end: Int), in lines: [String]) -> [(index: Int, indent: String, words: String)] {
        let under = (place.line + 1..<place.end).filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }.map { ($0, parts(lines[$0])) }
        guard let nearest = under.map({ width($0.1.indent) }).min() else { return [] }
        return under.filter { width($0.1.indent) == nearest && $0.1.isItem }.map { ($0.0, $0.1.indent, $0.1.words) }
    }

    /// The passages highlighted on what a note reads.
    public static func passages(in text: String, of address: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        let own = ReaderSource.ownAddress(in: text) == address
        guard let place = place(in: lines, of: address, own: own) else { return [] }
        return children(of: place, in: lines).map { unquoted($0.words) }.filter { !$0.isEmpty }
    }

    /// A note with a passage highlighted on what it reads, where
    /// `passages(in:of:)` finds them — unless it is there already.
    public static func adding(_ passage: String, to text: String, of address: String) -> String {
        let said = oneLine(passage)
        guard !said.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        let own = ReaderSource.ownAddress(in: text) == address
        guard let place = place(in: lines, of: address, own: own) else {
            guard own else { return text }
            // A link note with no Highlights yet: made, at its foot.
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            lines += ["- Highlights", "  - \(said)", ""]
            return lines.joined(separator: "\n")
        }
        let under = children(of: place, in: lines)
        guard !under.contains(where: { unquoted($0.words) == said }) else { return text }
        let parent = parts(lines[place.line])
        if !parent.isItem {
            // Prose, not a list: the passage a quote after its paragraph.
            var end = place.line + 1
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
            lines.insert(contentsOf: ["", "> \(said)"], at: end)
            return lines.joined(separator: "\n")
        }
        // Indented as those there already are.
        let indent = under.last?.indent ?? parent.indent + (parent.indent.contains("\t") ? "\t" : "  ")
        lines.insert(indent + "- " + (own ? said : "> " + said), at: place.end)
        return lines.joined(separator: "\n")
    }
}

extension GraphStore {
    /// What a note says now: as it is being written, if it is open; else its file.
    public func text(of path: String) -> String? {
        if let open = openDraft(path: path), open.exists || !open.isBlank { return open.markdown }
        return (try? engine.read(path: path)) ?? nil
    }

    /// Everything a note has to read.
    public func sources(path: String) -> [ReaderSource] {
        text(of: path).map { ReaderSource.all(in: $0, root: root) } ?? []
    }

    /// The notes saved to read — in the inbox, with something to read, not
    /// put off — oldest first; and when the next one put off comes back.
    /// A note's age is the day it was saved, the first day that links to
    /// it; else when it last changed.
    public func readingQueue(now: Date = Date()) -> (pages: [PageInfo], next: Date?) {
        let inbox = (try? engine.runQuery(body: "in: Inbox\nis not: day\nis not: week\nlimit: 1000", this: nil).pages) ?? []
        let snoozed = (try? engine.fieldValues(key: ReadingQueue.snoozeKey)) ?? [:]
        var items: [(page: PageInfo, saved: Date)] = []
        var next: Date?
        for page in inbox where GraphStore.riverName(page.path) == nil {
            let open = openDraft(path: page.path)
            // The note's own word, where it is open: one done with a moment ago is out.
            if !isInInbox(page.path) { continue }
            guard let text = text(of: page.path), ReaderSource.any(in: text, root: root) else { continue }
            let until = ReadingQueue.until(open.map { $0.editor.field(key: ReadingQueue.snoozeKey) } ?? snoozed[page.path])
            if let until, until > now {
                next = min(next ?? until, until)
                continue
            }
            let days = ((try? engine.backlinks(path: page.path)) ?? []).compactMap { link -> Date? in
                guard link.source.hasPrefix("daily/") else { return nil }
                return ReadingQueue.until(String(link.source.dropFirst(6).dropLast(3)))
            }
            items.append((page, days.min() ?? Date(timeIntervalSince1970: TimeInterval(page.modified ?? 0))))
        }
        items.sort { $0.saved != $1.saved ? $0.saved < $1.saved : $0.page.path < $1.page.path }
        return (items.map(\.page), next)
    }

    /// Read, or put off: out of the queue — out of the inbox — or back in
    /// it later. Done at once, and for a moment to be undone.
    public func finishReading(path: String, title: String, snooze: ReadingQueue.Snooze? = nil) {
        let draft = draft(path: path, title: title)
        let was = draft.editor.field(key: ReadingQueue.snoozeKey)
        if let snooze {
            draft.setField(ReadingQueue.snoozeKey, values: [ReadingQueue.written(snooze.until(from: Date()))])
        } else {
            setIn(Self.inboxRiver, path: path, title: title, false)
            draft.setField(ReadingQueue.snoozeKey, values: [])
        }
        draft.saveNow()
        undoable("\(snooze == nil ? "Done with" : "Put off") “\(draft.label)”") { [weak self] in
            guard let self else { return }
            let draft = self.draft(path: path, title: title)
            if snooze == nil { self.setIn(Self.inboxRiver, path: path, title: title, true) }
            draft.setField(ReadingQueue.snoozeKey, values: was.map { [$0] } ?? [])
            draft.saveNow()
        }
    }

    /// The passages highlighted before on a page a note reads.
    public func highlights(in path: String, of address: String) -> [String] {
        text(of: path).map { ReaderHighlights.passages(in: $0, of: address) } ?? []
    }

    /// A passage highlighted in a page a note reads, written into the note.
    public func highlight(_ passage: String, of address: String, in path: String) {
        // What is being written is written first: the file is what is added to.
        openDraft(path: path)?.saveNow()
        guard let text = (try? engine.read(path: path)) ?? nil else { return }
        let marked = ReaderHighlights.adding(passage, to: text, of: address)
        guard marked != text else { return }
        guard (try? engine.write(path: path, content: marked)) != nil else { return }
        // A card of it shows the passage at once, ahead of the engine saying the file changed.
        openDraft(path: path)?.fileChanged()
    }
}
