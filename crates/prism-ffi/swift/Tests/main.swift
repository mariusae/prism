// The engine, driven from Swift through the generated bindings: what an
// app does, end to end. Run by crates/prism-ffi/build-swift.sh.

import Foundation
#if canImport(Prism)
import Prism
#endif

var checks = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ what: String, line: UInt = #line) {
    checks += 1
    guard (try? condition()) == true else {
        print("FAILED (line \(line)): \(what)")
        exit(1)
    }
}

/// Collects what the engine says, from the engine's thread.
final class Recorder: EngineObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EngineEvent] = []
    func onEvent(event: EngineEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }
    func saw(_ matching: (EngineEvent) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains(where: matching)
    }
}

/// A token provider, as an app's sign-in would be.
final class Tokens: TokenProvider, @unchecked Sendable {
    func token() throws -> String { "a-token" }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("prism-swift-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
let graph = root.appendingPathComponent("graph").path
let remote = root.appendingPathComponent("remote.git").path
try createBareRepository(path: remote, branch: "main")

// --- A note open in an editor: the note is the engine's, the view only shows it

let open = NoteEditor.open(source: "# Atlas\n\n- one\n- two\n", mode: .outline)
expect(open.text() == "one\ntwo" && open.title() == "Atlas" && !open.layout().markersInText, "an outline shows a row a block, and only its words")
_ = open.replace(start: 3, end: 3, replacement: "!")
let indented = open.perform(selectionStart: 6, selectionEnd: 6, command: .indent)
expect(indented != nil && open.markdown() == "# Atlas\n\n- one!\n  - two\n", "typing and Tab change the note's tree")
_ = open.undo()
expect(open.markdown() == "# Atlas\n\n- one!\n- two\n" && open.canRedo(), "undo puts structure back")
open.setMode(mode: .text)
expect(open.text() == "- one!\n- two\n" && open.layout().markersInText, "the same note as text is its Markdown")

// Rows fold, are carried, and tell the time: an outline's own, wherever the caret is.
let outline = NoteEditor.open(source: "- one\n  - 9:00–9:30 two\n  - 10:00 three\n- last\n", mode: .outline)
let foldedRow = outline.performOn(rows: [0], selectionStart: 0, selectionEnd: 0, command: .fold)
expect(foldedRow != nil && outline.text() == "one\nlast" && outline.markdown().contains("three"), "a folded row shows none of what is under it, and the note keeps it")
expect(outline.layout().lines[0].isFolded && outline.foldedRows() == [RiverFoldedRow(index: 0, text: "one")], "a fold is told as a river keeps it")
expect(outline.rowInfo(row: 0)?.hidden == 2 && outline.setFoldedRows(rows: []) && !outline.setFoldedRows(rows: []), "and set as an app remembers it")
expect(outline.timeMarks(twelveHour: false).first?.head?.label == "9:00 – 9:30 · 30m", "a list of times is a timeline")
expect(outline.dropDepth(rows: [3], before: 1, depth: 9) == 1 && outline.moveRows(rows: [3], before: 1, depth: 9, selectionStart: 0, selectionEnd: 0) != nil, "a row is carried to a place and a depth")
expect(outline.markdown() == "- one\n  - last\n  - 9:00–9:30 two\n  - 10:00 three\n" && outline.markdownOf(rows: [1]) == "- last\n", "and copied as Markdown of its own")
expect(outline.newTimeBlock(selectionStart: 0, selectionEnd: 0, now: 615) != nil && outline.markdown().hasSuffix("  - 10:15–10:30 \n"), "a new time block goes where its time does")
expect(outline.link(selectionStart: 0, selectionEnd: 3, address: " https://example.com ") != nil && outline.text().hasPrefix("[one](https://example.com)"), "an address pasted on words links them")
expect(webAddress(text: "not one") == nil && outline.perform(selectionStart: 0, selectionEnd: 0, command: .turnTask) != nil && outline.markdown().hasPrefix("+ [ ] [one]"), "a row is turned into another kind")

// --- A document, edited ------------------------------------------------------

let source = "---\ntags: [Projects]\n---\n# Atlas 🚀\n\n*   Kick-off with [[Ada Lovelace]] #planning\n*   Budget 💰 and **scope**\n"
let document = NoteDocument.parse(source: source)
expect(document.markdown() == source, "a note reads and writes back byte for byte")
expect(document.title(path: "notes/atlas.md") == "Atlas 🚀", "title from the heading")
expect(document.meta(path: "notes/atlas.md").tags == ["Projects", "planning"], "tags from frontmatter and body")

var rows = document.rows()
expect(rows.count == 3 && rows[2].text == "Budget 💰 and **scope**", "rows in reading order")
expect(rows[1].kind == .bullet(marker: "*", task: .none), "a bullet keeps its marker")

// Offsets are UTF-16: the emoji is two units.
let spans = inlineSpans(text: rows[2].text)
let ns = rows[2].text as NSString
expect(spans.count == 1 && spans[0].kind == .strong, "one strong span")
expect(ns.substring(with: NSRange(location: Int(spans[0].contentStart), length: Int(spans[0].contentEnd - spans[0].contentStart))) == "scope", "span ranges are NSRanges")
let styled = toggleInlineStyle(text: "Budget 💰 here", start: 10, end: 14, style: .emphasis)
expect(styled.text == "Budget 💰 *here*", "a style goes on a UTF-16 range")
expect(inlinePlainText(text: "see [[Ada Lovelace|Ada]] **now**") == "see Ada now", "plain text")

// Indent "Budget" under "Kick-off"; split it after the emoji.
let moved = document.indent(path: [2])
expect(moved == [1, 0], "indent answers the new path")
let split = document.split(path: [1, 0], offset: 9)
expect(split == [1, 1], "split answers the new row")
expect(document.row(path: [1, 0])?.text == "Budget 💰" && document.row(path: [1, 1])?.text == " and **scope**", "split at a UTF-16 offset, never inside a character")
let joined = document.joinWithPrevious(path: [1, 1])
expect(joined == JoinPoint(path: [1, 0], offset: 9), "join answers where the caret goes")
expect(document.toggleTask(path: [1]) == .open, "a bullet becomes a task")
document.setField(key: "status", value: "active")
expect(document.markdown() == "---\ntags: [Projects]\nstatus: active\n---\n# Atlas 🚀\n\n*   [ ] Kick-off with [[Ada Lovelace]] #planning\n    *   Budget 💰 and **scope**\n", "only what was edited changed")
expect(document.references().links.first?.target == "Ada Lovelace", "links are found")

// --- An engine ---------------------------------------------------------------

let recorder = Recorder()
let engine = try PrismEngine.create(root: graph, remoteUrl: remote, options: EngineOptions(device: "Swift test", authorName: "Swift", authorEmail: "swift@example.com"), token: Tokens())
engine.setObserver(observer: recorder)

let atlas = try engine.createNote(title: "Project Atlas")
expect(atlas == "notes/project-atlas.md", "a new note gets its path")
let text = try engine.read(path: atlas)!
expect(try engine.write(path: atlas, content: text + "\n- Kick-off with [[Ada Lovelace]] #planning\n+ [ ] Book a room\n"), "a note is written")
expect(try engine.write(path: "notes/person.md", content: "---\nfields:\n  - birthday (date)\n  - status (active | paused)\n---\n# Person\n"), "a tag's page")
expect(try engine.write(path: "notes/ada.md", content: "---\ntags: [Person]\nbirthday: 1815-12-10\n---\n# Ada Lovelace\n\nWorks on [[project atlas]].\n"), "another")
engine.settle()

expect(try engine.resolve(name: "ada lovelace") == ResolvedPage(path: "notes/ada.md", exists: true), "names resolve, case aside")
expect(try engine.resolve(name: "2026-10-31") == ResolvedPage(path: "daily/2026-10-31.md", exists: false), "a date always leads somewhere")
expect(try engine.search(typed: "kick", limit: 5).first?.path == atlas, "search finds it")
expect(try engine.backlinks(path: atlas).map(\.source) == ["notes/ada.md"], "backlinks, by any name")
expect(try engine.openTasks().map(\.text) == ["Book a room"], "tasks")
expect(try engine.schema(path: "notes/ada.md") == [TypedField(name: "birthday", kind: .date), TypedField(name: "status", kind: .choice(options: ["active", "paused"]))], "typed fields from the tag's page")
let found = try engine.runQuery(body: "tag: Person\nshow: table", this: nil)
expect(found.pages.map(\.title) == ["Ada Lovelace"] && found.show == .table && found.columns == ["birthday", "status"], "a query runs")

// A rename relinks.
let renamed = try engine.renameNote(path: atlas, newTitle: "Atlas Reborn")
expect(renamed.rewritten == [atlas, "notes/ada.md"], "a rename rewrites the page and its backlinks")
expect(try engine.read(path: "notes/ada.md")!.hasSuffix("Works on [[\(linkName(path: atlas)!)]].\n"), "the link names the page's file, which no rename changes")
expect(try engine.backlinks(path: atlas).map(\.source) == ["notes/ada.md"], "and still leads to it")

// What an index listed is found again after the page changed.
engine.settle()
let listed = try engine.openTasks()[0]
let page = try engine.read(path: atlas)!
expect(try engine.write(path: atlas, content: page.replacingOccurrences(of: "+ [ ] Book", with: "- a line added above\n+ [ ] Book")), "the page changes under a list of tasks")
expect(try engine.setTask(path: atlas, row: listed.row, text: listed.text, done: true) != nil, "a task is found by its text")
expect(try engine.read(path: atlas)!.contains("+ [x] Book a room"), "and checked off")
engine.settle()
expect(try engine.backlinks(path: atlas).first?.context == "Works on [[\(linkName(path: atlas)!)]].", "a backlink comes with its row's text")

// An alias changed: its links are written with the page's own name. Two notes may have one title.
expect(try engine.write(path: "notes/ada.md", content: "---\ntags: [Person]\naliases: [Countess]\nbirthday: 1815-12-10\n---\n# Ada Lovelace\n\nWorks on [[Atlas Reborn]].\n"), "an alias")
expect(try engine.write(path: "notes/log.md", content: "# Log\n\n[[countess]] called.\n"), "a link by alias")
let realiased = try engine.renameAlias(path: "notes/ada.md", alias: "Countess", newAlias: "AAL")
expect(realiased.rewritten == ["notes/ada.md", "notes/log.md"], "an alias renamed rewrites its links")
expect(try engine.read(path: "notes/log.md")! == "# Log\n\n[[ada]] called.\n", "the link names the page's file")
engine.settle()
let twin = try engine.createNote(title: "Ada Lovelace")
expect(twin == "notes/ada-lovelace.md" && linkName(path: twin) == "ada-lovelace", "a new note of a title already taken is a new file")
engine.settle()
expect(try engine.duplicateNames().map(\.name) == ["Ada Lovelace"], "two notes of one title are told of")
expect(try engine.resolve(name: "ada")?.path == "notes/ada.md" && engine.resolve(name: "ada-lovelace")?.path == twin, "a file's name leads to its file")
expect(try engine.backlinks(path: twin).isEmpty && engine.backlinks(path: "notes/ada.md").contains { $0.source == "notes/log.md" }, "and the new note has none of the other's backlinks")
expect(try engine.delete(path: twin), "the second is deleted")
engine.settle()
expect(try engine.page(path: atlas)?.modified != nil, "a page is dated without saying so itself")

// A private page is seen only where it is asked for; a tag is a link.
expect(try engine.write(path: "notes/secret.md", content: "---\nprivate: true\n---\n# Secret\n\nA #person, about [[Ada Lovelace]].\n"), "a private page")
engine.settle()
expect(try engine.page(path: "notes/secret.md") == nil && engine.search(typed: "secret", limit: 5).isEmpty, "hidden from listings and search")
expect(try !engine.backlinks(path: "notes/ada.md").contains { $0.source == "notes/secret.md" }, "and from backlinks")
try engine.setShowsPrivate(show: true)
expect(try engine.page(path: "notes/secret.md")?.isPrivate == true, "shown when asked for")
expect(try engine.backlinks(path: "notes/person.md").contains { $0.source == "notes/secret.md" && $0.kind == .tag }, "a tag is a backlink of the tag's page")
try engine.setShowsPrivate(show: false)

// What is derived without reading a note: conflicts, blank pages, where a picture is shown.
let picture = try engine.addAsset(name: "Diagram.PNG", content: Data([0x50, 0x4E, 0x47]))
expect(try engine.write(path: "notes/clash.md", content: "# Clash\n\n![](\(picture))\n\n<<<<<<< this device\n- mine\n=======\n- yours\n>>>>>>> other device\n"), "a page left in conflict")
engine.settle()
expect(try engine.conflictedPages().map(\.path) == ["notes/clash.md"], "conflicts are listed")
expect(try engine.pagesShowing(asset: picture) == ["notes/clash.md"] && engine.unusedAssets().isEmpty, "an asset knows where it is shown")
expect(try engine.runQuery(body: "sort: -modified\nlimit: 1", this: nil).pages.count == 1, "the page changed last")

// A river.
let river = SavedRiver(cards: [RiverCard(title: "Atlas Reborn", focus: nil, foldedRows: [RiverFoldedRow(index: 2, text: "Book a room")], placeRank: nil, placeKey: nil)],
                       query: nil, placed: [], folded: ["Atlas Reborn"], opened: [], hidden: [], icon: "tray", color: nil, place: nil)
expect(try engine.saveRiver(name: "Work", river: river), "a river is saved")
expect(try engine.river(name: "Work") == river && engine.riverNames() == ["Work"], "and read back as it was")
expect(riverName(linkTarget: "rivers/Work") == "Work", "river links")

// Sync, waited for; errors are Swift errors.
let report = try engine.syncNow(full: true)
expect(report.pushed && report.committed != nil, "the first sync commits and pushes: \(report.summary)")
if case .synced = engine.status() {} else { expect(false, "status says synced") }
do {
    _ = try engine.write(path: "../outside.md", content: "x")
    expect(false, "a path out of the graph is refused")
} catch let error as PrismError {
    expect("\(error)".contains("not a path in the graph") || error.localizedDescription.count > 0, "errors carry words")
}
expect(recorder.saw { if case .indexUpdated = $0 { return true } else { return false } }, "the observer heard of indexing")
expect(recorder.saw { if case .syncFinished(let report) = $0 { return report.pushed } else { return false } }, "and of the sync")

// A draft saved over a file that changed underneath it is merged.
let base = try engine.read(path: "notes/ada.md")!
_ = try engine.write(path: "notes/ada.md", content: base.replacingOccurrences(of: "tags: [Person]", with: "tags: [Person, Pioneer]"))
let saved = try engine.saveMerging(path: "notes/ada.md", draft: base + "\nA new line.\n", base: base)
expect(saved.wasMerged && !saved.isConflicted && saved.content.contains("Pioneer") && saved.content.contains("A new line."), "both changes are kept")
expect(conflictCount(source: "a\n<<<<<<< this device\nx\n=======\ny\n>>>>>>> other device\n") == 1, "conflicts are counted")
expect(resolveConflicts(source: "<<<<<<< this device\nx\n=======\ny\n>>>>>>> other device\n", keep: .theirs) == "y\n", "and resolved")

print("Swift: \(checks) checks passed")
