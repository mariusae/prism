import CryptoKit
import Foundation
import Prism
import PrismEditor
import WeftShared

/// Pages shared to Weft from other apps — Safari's Share ▸ Weft — made
/// link notes: the page's title, its address, what it says of itself and
/// what was selected on it, as the graph's link notes are written, and
/// stamped with the day it was shared (`related:`), so that the day lists it.
extension GraphStore {
    /// Takes in the pages waiting: each a link note, opened in the river.
    /// A page shared before is its note again, stamped with this day too.
    /// Says how many were taken in.
    @discardableResult
    public func takeSharedPages() -> Int {
        var taken = 0
        for (page, file) in SharedPages.waiting() {
            if page.isPictures {
                guard takePictures(page) else { continue }
                SharedPages.taken(file, page: page)
                taken += 1
                continue
            }
            // Left with no more than its address: told what it is when the page has been read.
            if WebPageInfo.isBare(title: page.title, url: page.url) { Task { await self.readBare(page) } }
            if page.destination == .today {
                guard let day = addToDay(page) else { continue }
                SharedPages.taken(file)
                river.open(Card(path: day, title: Days.name(page.shared)), after: river.selected)
            } else {
                guard let path = linkNote(for: page) else { continue }
                // Saved to read: a card of the Inbox, where Weft Reader reads from.
                setIn(Self.inboxRiver, path: path, title: LinkNote.title(page.title, url: page.url), true)
                SharedPages.taken(file)
                river.open(Card(path: path, title: LinkNote.title(page.title, url: page.url)), after: river.selected)
            }
            taken += 1
        }
        if taken > 0 { rememberRivers() }
        if taken > 0 { note("share", "Took in \(taken) shared page\(taken == 1 ? "" : "s")") }
        return taken
    }

    /// Pictures shared, kept in the graph: a note of them, stamped with the
    /// day — titled, if they were given one — or a row of them at the top
    /// of the day's note — opened in the river. Says whether they were kept.
    private func takePictures(_ page: SharedPages.Page) -> Bool {
        let kept = (page.pictures ?? []).compactMap { name -> (data: Data, fileExtension: String)? in
            guard let file = SharedPages.picture(name), let data = try? Data(contentsOf: file) else { return nil }
            return (data, file.pathExtension)
        }
        guard let line = pictureNote(kept)?.trimmingCharacters(in: .newlines) else { return false }
        let day = Days.name(page.shared)
        let title = page.title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        if page.destination == .today {
            let path = engine.pathForTitle(title: day)
            openDraft(path: path)?.saveNow()
            let text = ((try? engine.read(path: path)) ?? nil) ?? ""
            let rows = title.isEmpty ? "- \(line)\n" : "- \(title)\n  - \(line)\n"
            guard (try? engine.write(path: path, content: LinkNote.atTop(rows, of: text))) != nil else { return false }
            openDraft(path: path)?.fileChanged()
            river.open(Card(path: path, title: day), after: river.selected)
            return true
        }
        // Made, and opened, as a note pasted is.
        let editor = NoteEditor.open(source: (title.isEmpty ? "" : "# \(title)\n\n") + line + "\n")
        editor.setListField(key: "related", values: [day])
        return newNote(written: editor.markdown()) != nil
    }

    /// A page shared to the day: a row linking to it at the top of the
    /// day's note — what was selected on it a row under it. The day's path.
    private func addToDay(_ page: SharedPages.Page) -> String? {
        let path = engine.pathForTitle(title: Days.name(page.shared))
        // What is being written in it is written first: the file is what is added to.
        openDraft(path: path)?.saveNow()
        let text = ((try? engine.read(path: path)) ?? nil) ?? ""
        let title = LinkNote.title(page.title, url: page.url)
        var rows = "- [\(title)](\(page.url))\n"
        let selected = page.selection.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !selected.isEmpty { rows += "  - " + selected.joined(separator: " ") + "\n" }
        guard (try? engine.write(path: path, content: LinkNote.atTop(rows, of: text))) != nil else { return nil }
        openDraft(path: path)?.fileChanged()
        return path
    }

    /// A page left with no more than its address, read: its link note
    /// given the page's own title, description and author.
    func readBare(_ page: SharedPages.Page) async {
        guard let info = await WebPageInfo.read(page.url) else { return }
        let path = "notes/\(slug(title: LinkNote.title(page.title, url: page.url))).md"
        fillLinkNote(path: path, from: info)
    }

    /// A link note that says nothing of its page — titled by its site, its
    /// description empty — given what the page says of itself.
    func fillLinkNote(path: String, from info: WebPageInfo) {
        let draft = draft(path: path, title: path)
        guard draft.exists, let text = (try? engine.read(path: path)) ?? nil, let address = ReaderSource.ownAddress(in: text) else { return }
        var lines = text.components(separatedBy: "\n")
        if !info.description.isEmpty, let at = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "- Description:" }) {
            lines[at] = "- Description: " + info.description.components(separatedBy: .newlines).joined(separator: " ")
        }
        if let author = info.author, !author.isEmpty, !lines.contains(where: { $0.hasPrefix("- Author:") }),
           let at = lines.firstIndex(where: { $0.hasPrefix("- Description:") }) {
            lines.insert("- Author: " + author, at: at + 1)
        }
        let filled = lines.joined(separator: "\n")
        if filled != text {
            draft.saveNow()
            _ = try? engine.write(path: path, content: filled)
            draft.fileChanged()
        }
        if WebPageInfo.isBare(title: draft.title, url: address) { draft.rename(to: LinkNote.title(info.title, url: address)) }
    }

    /// A link on the web in a note, made a page of its own: its link note —
    /// made, or the one there is of that address — opened in the river
    /// after the note, and the link in the note made a link to it.
    /// Says whether it was.
    @discardableResult
    public func makeLinkPage(address: String, in source: PageDraft) -> Bool {
        let known = WebCards.shared.found[address]?.title
        let words = source.linkWords(address)
        let title = LinkNote.title(known ?? words ?? "", url: address)
        guard let path = linkNote(for: SharedPages.Page(url: address, title: title)) else { return false }
        let name = Prism.linkName(path: path) ?? title
        source.saveNow()
        let text = source.markdown
        let linked = Self.linking(address, in: text, to: name)
        if linked != text, (try? engine.write(path: source.path, content: linked)) != nil { source.fileChanged() }
        // Known only by its address: told what it is once the page is read.
        if WebPageInfo.isBare(title: title, url: address) {
            Task { if let info = await WebPageInfo.read(address) { self.fillLinkNote(path: path, from: info) } }
        }
        let river = rivers.first { $0.all.contains { $0.path == source.path } } ?? self.river
        if let index = rivers.firstIndex(where: { $0 === river }) { currentRiver = index }
        river.open(Card(path: path, title: title), after: river.all.first { $0.path == source.path }?.id)
        rememberRivers()
        note("link", "Made a link page of \(address)")
        return true
    }

    /// A note's Markdown with every link to an address — `[words](address)`,
    /// `<address>`, the address bare — made a link to a page.
    static func linking(_ address: String, in text: String, to name: String) -> String {
        let at = NSRegularExpression.escapedPattern(for: address)
        let link = "[[\(name)]]"
        var text = text
        for pattern in [#"(?<!!)\[[^\]\n]*\]\(<?"# + at + #">?\)"#, "<" + at + ">", #"(?<![\S])"# + at + #"(?![^\s.,;:!?)])"#] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: link))
        }
        return text
    }

    /// The link note for a page shared — made, or found and stamped. Its path.
    private func linkNote(for page: SharedPages.Page) -> String? {
        let day = Days.name(page.shared)
        let title = LinkNote.title(page.title, url: page.url)
        // A page shared again is the note it was given then: its file is called by the same title, and says the same address.
        let first = "notes/\(slug(title: title)).md"
        if let known = (try? engine.read(path: first)) ?? nil, known.contains(page.url) {
            let editor = NoteEditor.open(source: known)
            let related = editor.fields().first { $0.key == "related" }?.values ?? []
            if !related.contains(where: { nameKey(name: $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) == nameKey(name: day) }) {
                editor.setListField(key: "related", values: related + [day])
            }
            if editor.markdown() != known {
                guard (try? engine.write(path: first, content: editor.markdown())) != nil else { return nil }
            }
            return first
        }
        let path = engine.pathForTitle(title: title)
        guard (try? engine.write(path: path, content: LinkNote.markdown(for: page, title: title, day: day))) != nil else { return nil }
        return path
    }
}

/// A web page's note, as the graph's link notes are written.
enum LinkNote {
    /// Rows put at the top of a note's body: under its frontmatter and its
    /// title, if it has them, and before what it says.
    static func atTop(_ rows: String, of text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var at = 0
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") { at = close + 1 }
        while at < lines.count, lines[at].trimmingCharacters(in: .whitespaces).isEmpty { at += 1 }
        if at < lines.count, lines[at].hasPrefix("# ") {
            at += 1
            while at < lines.count, lines[at].trimmingCharacters(in: .whitespaces).isEmpty { at += 1 }
        }
        if at >= lines.count || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let kept = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return kept.isEmpty ? rows : kept + "\n\n" + rows
        }
        lines.insert(contentsOf: rows.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init), at: at)
        return lines.joined(separator: "\n")
    }

    /// The note's id: `link-` and the SHA-256 of the address, as the
    /// graph's other link notes have it.
    static func id(for url: String) -> String {
        "link-" + SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A page's title as a note's: on one line, with nothing a `[[link]]`
    /// to it would trip on. The address's site, for a page with none.
    static func title(_ raw: String, url: String) -> String {
        var title = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        title = title.replacingOccurrences(of: "|", with: "｜").replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        if title.isEmpty { title = URL(string: url)?.host() ?? url }
        return title
    }

    /// The note, new: linked to the day it was shared in its frontmatter.
    static func markdown(for page: SharedPages.Page, title: String, day: String) -> String {
        let oneLine = { (words: String) in words.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ") }
        var rows = [
            "- URL: <\(page.url)>",
            "- Description:" + (page.description.isEmpty ? "" : " " + oneLine(page.description)),
        ]
        // A post's author, said: what it is by is what it is.
        if let author = page.author, !author.isEmpty { rows.append("- Author: " + oneLine(author)) }
        rows += [
            "- Type: #link",
        ]
        let selected = page.selection.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !selected.isEmpty {
            rows.append("- Highlights")
            rows.append("  - " + selected.joined(separator: " "))
        }
        let source = "---\nid: \"\(id(for: page.url))\"\nicon: link\n---\n\n# \(title)\n\n" + rows.joined(separator: "\n") + "\n"
        let editor = NoteEditor.open(source: source)
        editor.setListField(key: "related", values: [day])
        return editor.markdown()
    }
}
