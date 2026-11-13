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
            guard let path = linkNote(for: page) else { continue }
            SharedPages.taken(file)
            river.open(Card(path: path, title: LinkNote.title(page.title, url: page.url)), after: river.selected)
            taken += 1
        }
        if taken > 0 { rememberRivers() }
        if taken > 0 { note("share", "Took in \(taken) shared page\(taken == 1 ? "" : "s")") }
        return taken
    }

    /// The link note for a page shared — made, or found and stamped. Its path.
    private func linkNote(for page: SharedPages.Page) -> String? {
        let day = Days.name(page.shared)
        let title = LinkNote.title(page.title, url: page.url)
        // A page shared again is the note it was given then: its file is called by the same title, and says the same address.
        let first = "notes/\(slug(title: title)).md"
        if let known = (try? engine.read(path: first)) ?? nil, known.contains(page.url) {
            let editor = NoteEditor.open(source: known, mode: .outline)
            let related = editor.fields().first { $0.key == "related" }?.values ?? []
            if !related.contains(where: { nameKey(name: $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) == nameKey(name: day) }) {
                editor.setListField(key: "related", values: related + [day])
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
            "- Type: #link",
        ]
        let selected = page.selection.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !selected.isEmpty {
            rows.append("- Highlights")
            rows.append("  - " + selected.joined(separator: " "))
        }
        let source = "---\nid: \"\(id(for: page.url))\"\nicon: link\n---\n\n# \(title)\n\n" + rows.joined(separator: "\n") + "\n"
        let editor = NoteEditor.open(source: source, mode: .outline)
        editor.setListField(key: "related", values: [day])
        return editor.markdown()
    }
}
