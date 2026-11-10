// The engine, driven from Swift through the generated bindings: what an
// app does, end to end. Run by crates/prism-ffi/build-swift.sh.

import Foundation

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
try FileManager.default.createDirectory(atPath: remote, withIntermediateDirectories: true)
let git = Process()
git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
git.arguments = ["init", "--bare", "-q", "--initial-branch=main", remote]
try git.run(); git.waitUntilExit()

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
expect(try engine.read(path: "notes/ada.md")!.hasSuffix("Works on [[Atlas Reborn]].\n"), "the link names the new title")

// A river.
let river = SavedRiver(cards: [RiverCard(title: "Atlas Reborn", foldedRows: [RiverFoldedRow(index: 2, text: "Book a room")], placeRank: nil, placeKey: nil)],
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
