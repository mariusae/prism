import Foundation
import Prism
import PrismEditor
import XCTest
@testable import WeftKit

/// What the phone's features rest on that needs no screen: pictures read
/// off a line and kept in the graph, the places a river was at, and the
/// reading queue.
@MainActor
final class PhoneFeaturesTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("weft-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ path: String, _ text: String) throws {
        let file = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: Pictures

    func testPictureLine() {
        XCTAssertEqual(PictureLine(line: "![](assets/a.png)")?.pictures.map(\.address), ["assets/a.png"])
        let two = PictureLine(line: "  ![one](assets/a.png) ![](assets/b%20c.jpg) <!-- {\"width\":320,\"height\":200} -->  ")
        XCTAssertEqual(two?.pictures.map(\.address), ["assets/a.png", "assets/b%20c.jpg"])
        XCTAssertEqual(two?.pictures[0].alt, "one")
        XCTAssertNil(two?.pictures[0].width)
        XCTAssertEqual(two?.pictures[1].width, 320)
        XCTAssertEqual(two?.pictures[1].height, 200)
        XCTAssertEqual(PictureLine(line: "![](a.png)![](b.png)![](c.png)")?.pictures.count, 3)
        XCTAssertEqual(PictureLine(line: "![](a.png) <!-- {\"width\":90} --> ![](b.png)")?.pictures.map(\.width), [90, nil])
        XCTAssertNil(PictureLine(line: "![](a.png) and ![](b.png)"))
        XCTAssertNil(PictureLine(line: "words ![](a.png)"))
        XCTAssertNil(PictureLine(line: "![](a.png) words"))
        XCTAssertNil(PictureLine(line: "no pictures"))
        XCTAssertNil(PictureLine(line: ""))
        // As the editor reads one alone, so does this.
        for line in ["![alt](assets/a.png)", "![](assets/a.png) <!-- {\"width\":120,\"height\":80} -->"] {
            XCTAssertEqual(PictureLine(line: line)?.pictures, EditorPicture(line: line).map { [$0] })
        }
        XCTAssertEqual(two?.line, "![one](assets/a.png) ![](assets/b%20c.jpg) <!-- {\"width\":320,\"height\":200} -->")
    }

    func testSavePicture() throws {
        let store = try GraphStore(root: folder)
        defer { store.close() }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let first = try XCTUnwrap(store.savePicture(data: png, fileExtension: "PNG"))
        XCTAssertNotNil(first.range(of: #"^assets/pasted-\d{13}\.png$"#, options: .regularExpression), first)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(first)), png)
        // A name that is taken: -2, -3.
        let stamp = first.dropFirst("assets/pasted-".count).dropLast(4)
        var taken = Set([first])
        for _ in 0..<40 { taken.insert(try XCTUnwrap(store.savePicture(data: png, fileExtension: "png"))) }
        XCTAssertEqual(taken.count, 41)
        XCTAssertTrue(taken.contains { $0.hasSuffix("-2.png") }, "\(taken.sorted())")
        _ = stamp
        // jpeg is jpg, its bytes its own; a gif too.
        let jpg = try XCTUnwrap(store.savePicture(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), fileExtension: ".jpeg"))
        XCTAssertTrue(jpg.hasSuffix(".jpg"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(jpg)), Data([0xFF, 0xD8, 0xFF, 0xD9]))
        XCTAssertTrue(try XCTUnwrap(store.savePicture(data: Data("GIF89a".utf8), fileExtension: "gif")).hasSuffix(".gif"))
        // Any other picture is written again (a PNG on the Mac, a JPEG on the phone); what is no picture is not kept.
        let other = try XCTUnwrap(store.savePicture(data: png, fileExtension: "tiff"))
        XCTAssertTrue(other.hasSuffix(".png") || other.hasSuffix(".jpg"))
        XCTAssertNil(store.savePicture(data: Data("not a picture".utf8), fileExtension: "heic"))
        // The engine knows of it: a note showing it is found.
        try write("notes/shows.md", "# Shows\n\n![](\(first))\n")
        store.engine.pathsChanged(paths: ["notes/shows.md"])
        store.engine.settle()
        XCTAssertEqual(try store.engine.pagesShowing(asset: first), ["notes/shows.md"])
    }

    // MARK: Back places

    func testRowsAtTheTopOfADay() {
        let rows = "- [Page](https://a.example)\n"
        // A day of rows: before them.
        XCTAssertEqual(LinkNote.atTop(rows, of: "- one\n- two\n"), "- [Page](https://a.example)\n- one\n- two\n")
        // Under frontmatter and a title.
        XCTAssertEqual(LinkNote.atTop(rows, of: "---\ntags: [a]\n---\n# Day\n\n- one\n"), "---\ntags: [a]\n---\n# Day\n\n- [Page](https://a.example)\n- one\n")
        // A day with nothing in it yet.
        XCTAssertEqual(LinkNote.atTop(rows, of: ""), rows)
    }

    func testOneCardOfANote() {
        let river = River()
        let whole = Card(path: "notes/cos.md", title: "Cos")
        river.open(whole)
        // Gone to again by where it speaks of a page: the card that is there, now showing where.
        river.open(Card(path: "notes/cos.md", title: "Cos", lens: .mentions("notes/zach.md")))
        XCTAssertEqual(river.cards.count, 1)
        XCTAssertEqual(river.cards[0].lens, .mentions("notes/zach.md"))
        // And by a plain link: whole again.
        river.open(whole)
        XCTAssertEqual(river.cards.count, 1)
        XCTAssertNil(river.cards[0].lens)
        // Opened first by where it speaks of a page, then again by another: one card, showing the latest.
        let other = River()
        let lensed = Card(path: "notes/cos.md", title: "Cos", lens: .mentions("notes/zach.md"))
        other.open(lensed)
        other.open(Card(path: "notes/cos.md", title: "Cos", lens: .mentions("notes/ada.md")))
        XCTAssertEqual(other.cards.count, 1)
        XCTAssertEqual(other.cards[0].lens, .mentions("notes/ada.md"))
        // A row of it shown as a card of its own stays apart.
        other.open(Card(path: "notes/cos.md", title: "Cos", focus: "x1"))
        XCTAssertEqual(other.cards.count, 2)
        // A lens that finds nothing gives way to the whole note — and, were the whole note there already, to it.
        let third = River()
        third.open(lensed)
        third.cards.append(Card(path: "notes/cos.md", title: "Cos"))
        third.setFocus(lensed.id, nil)
        XCTAssertEqual(third.cards.count, 1)
        // A query river's own card of it, gone to by a backlink: shows where — and still does when found again.
        let query = River()
        query.query = "tag: person"
        query.take(found: [("notes/zach.md", "Zach")], total: 1)
        query.open(Card(path: "notes/zach.md", title: "Zach", lens: .mentions("daily/2026-11-12.md")))
        XCTAssertEqual(query.all.count, 1)
        XCTAssertEqual(query.all[0].lens, .mentions("daily/2026-11-12.md"))
        query.take(found: [("notes/zach.md", "Zach")], total: 1)
        XCTAssertEqual(query.all[0].lens, .mentions("daily/2026-11-12.md"))
    }

    func testBackPlaces() {
        let river = River()
        let a = Card(path: "notes/a.md", title: "A"), b = Card(path: "notes/b.md", title: "B"), c = Card(path: "notes/c.md", title: "C")
        river.open(a)
        XCTAssertTrue(river.places.isEmpty)
        river.open(b, after: a.id)
        XCTAssertEqual(river.places.map(\.title), ["A"])
        river.open(c, after: b.id)
        XCTAssertEqual(river.places.map(\.title), ["B", "A"])
        XCTAssertEqual(river.cards.map(\.title), ["A", "B", "C"])
        // To a card open already: its place kept once, the nearest first.
        river.open(a, after: c.id)
        XCTAssertEqual(river.places.map(\.title), ["C", "B", "A"])
        // Back to B: what came after it is forward.
        river.goBack(to: River.Place(path: "notes/b.md", title: "B"))
        XCTAssertEqual(river.selected, b.id)
        XCTAssertEqual(river.places.map(\.title), ["A"])
        XCTAssertTrue(river.canGoForward)
        // Back to a card closed since: opened again.
        river.close(a.id)
        river.goBack()
        XCTAssertEqual(river.selected.flatMap(river.card)?.path, "notes/a.md")
        XCTAssertTrue(river.places.isEmpty)
        river.goForward()
        XCTAssertEqual(river.selected, b.id)
        // Renamed, and gone.
        river.retitled(path: "notes/a.md", to: "Alpha")
        XCTAssertEqual(river.places.map(\.title), ["Alpha"])
        river.forget(path: "notes/a.md")
        XCTAssertTrue(river.places.isEmpty)
        // No more than twelve are offered.
        let many = River()
        var last: Card?
        for index in 0..<20 {
            let card = Card(path: "notes/\(index).md", title: "\(index)")
            many.open(card, after: last?.id)
            last = card
        }
        XCTAssertEqual(many.places.count, 12)
        XCTAssertEqual(many.places.first?.title, "18")
    }

    // MARK: Reading

    private static let link = """
    ---
    id: "link-abc"
    icon: link
    inbox: true
    cover: assets/cover.jpg
    ---

    # A Page

    - URL: <https://example.com/a-page>
    - Description: What it says of itself.
    - Type: #link
    """

    func testReaderSources() {
        let root = URL(fileURLWithPath: "/nowhere")
        XCTAssertEqual(ReaderSource.ownAddress(in: Self.link), "https://example.com/a-page")
        XCTAssertEqual(ReaderSource.all(in: Self.link, root: root).map(\.address), ["https://example.com/a-page"])
        let note = "# Notes\n\n- See [this](https://one.example/x) and https://two.example/y.\n- A picture ![](https://three.example/p.png)\n- <https://arxiv.org/pdf/1234.5678>\n```\nhttps://code.example/not\n```\n- [this again](https://one.example/x)\n"
        let found = ReaderSource.all(in: note, root: root)
        XCTAssertEqual(found.map(\.address), ["https://one.example/x", "https://two.example/y", "https://arxiv.org/pdf/1234.5678"])
        XCTAssertEqual(found.map(\.isPDF), [false, false, true])
        XCTAssertTrue(ReaderSource.any(in: note, root: root))
        XCTAssertFalse(ReaderSource.any(in: "# Nothing\n\n- to read here\n", root: root))
        XCTAssertNil(ReaderSource.ownAddress(in: "- Said: the URL: is not here\n"))
    }

    func testHighlights() {
        let address = "https://example.com/a-page"
        var text = ReaderHighlights.adding("A passage\n  over two lines.", to: Self.link, of: address)
        XCTAssertTrue(text.hasSuffix("- Type: #link\n- Highlights\n  - A passage over two lines.\n"), text)
        text = ReaderHighlights.adding("Another.", to: text, of: address)
        text = ReaderHighlights.adding("Another.", to: text, of: address)
        XCTAssertEqual(ReaderHighlights.passages(in: text, of: address), ["A passage over two lines.", "Another."])
        // On another page: under the line that links to it, quoted.
        let note = "- First\n- Read [this](https://one.example/x)\n\t- a note of mine\n- Last\n"
        let marked = ReaderHighlights.adding("Said there.", to: note, of: "https://one.example/x")
        XCTAssertEqual(marked, "- First\n- Read [this](https://one.example/x)\n\t- a note of mine\n\t- > Said there.\n- Last\n")
        XCTAssertEqual(ReaderHighlights.passages(in: marked, of: "https://one.example/x"), ["a note of mine", "Said there."])
        XCTAssertEqual(ReaderHighlights.adding("Said there.", to: marked, of: "https://one.example/x"), marked)
        XCTAssertEqual(ReaderHighlights.adding("Said.", to: "- [x](https://one.example/x)\n", of: "https://one.example/x"), "- [x](https://one.example/x)\n  - > Said.\n")
        XCTAssertEqual(ReaderHighlights.adding("Said.", to: "Prose with https://one.example/x in it\nand more.\n\nNext.\n", of: "https://one.example/x"),
                       "Prose with https://one.example/x in it\nand more.\n\n> Said.\n\nNext.\n")
    }

    func testReadingQueue() throws {
        try write("notes/a-page.md", Self.link)
        try write("notes/older.md", "---\ninbox: true\n---\n\n# Older\n\n- [read me](https://example.com/older)\n")
        try write("notes/put-off.md", "---\ninbox: true\nsnoozed_until: 2999-01-01T08:00\n---\n\n# Put Off\n\n- https://example.com/later\n")
        try write("notes/came-back.md", "---\ninbox: true\nsnoozed_until: 2020-01-01T08:00\n---\n\n# Came Back\n\n- https://example.com/back\n")
        try write("notes/no-link.md", "---\ninbox: true\n---\n\n# No Link\n\n- nothing to read\n")
        try write("notes/not-inbox.md", "# Not Inbox\n\n- https://example.com/elsewhere\n")
        try write("daily/2020-05-05.md", "- [[Links]]\n  - [[Older]]\n")
        let store = try GraphStore(root: folder)
        defer { store.close() }
        var queue = store.readingQueue()
        XCTAssertEqual(Set(queue.pages.map(\.title)), ["A Page", "Older", "Came Back"])
        // Oldest first: the one a day long ago links to.
        XCTAssertEqual(queue.pages.first?.title, "Older")
        XCTAssertEqual(queue.next.map(ReadingQueue.written), "2999-01-01T08:00")
        XCTAssertEqual(store.sources(path: "notes/a-page.md").map(\.address), ["https://example.com/a-page"])

        // Done with: out of the inbox, and the file says so; undone, back.
        store.finishReading(path: "notes/a-page.md", title: "A Page")
        var file = try String(contentsOf: folder.appendingPathComponent("notes/a-page.md"), encoding: .utf8)
        XCTAssertFalse(file.contains("inbox"), file)
        XCTAssertTrue(file.contains("icon: link") && file.contains("- URL: <https://example.com/a-page>"), file)
        XCTAssertFalse(store.readingQueue().pages.contains { $0.title == "A Page" })
        XCTAssertTrue(store.takeUndo())
        file = try String(contentsOf: folder.appendingPathComponent("notes/a-page.md"), encoding: .utf8)
        XCTAssertTrue(file.contains("inbox: true"), file)
        XCTAssertTrue(store.readingQueue().pages.contains { $0.title == "A Page" })

        // Put off: still in the inbox, with when it comes back.
        store.finishReading(path: "notes/older.md", title: "Older", snooze: .tomorrow)
        file = try String(contentsOf: folder.appendingPathComponent("notes/older.md"), encoding: .utf8)
        XCTAssertTrue(file.contains("inbox: true"), file)
        XCTAssertNotNil(file.range(of: #"snoozed_until: "?\d{4}-\d\d-\d\dT08:00"#, options: .regularExpression), file)
        queue = store.readingQueue()
        XCTAssertFalse(queue.pages.contains { $0.title == "Older" })
        XCTAssertTrue(queue.next! < Date().addingTimeInterval(2 * 86400))
        // As the index has it too, once it has been read again.
        store.engine.settle()
        XCTAssertNotNil(ReadingQueue.until(try store.engine.fieldValues(key: ReadingQueue.snoozeKey)["notes/older.md"]))

        // A passage highlighted is written into the note.
        store.highlight("Worth keeping.", of: "https://example.com/a-page", in: "notes/a-page.md")
        XCTAssertEqual(store.highlights(in: "notes/a-page.md", of: "https://example.com/a-page"), ["Worth keeping."])
    }

    func testSnooze() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // A Tuesday, at noon.
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        let said = { (snooze: ReadingQueue.Snooze) -> DateComponents in calendar.dateComponents([.month, .day, .hour], from: snooze.until(from: now, calendar: calendar)) }
        XCTAssertEqual(said(.laterToday), DateComponents(month: 11, day: 10, hour: 15))
        XCTAssertEqual(said(.tomorrow), DateComponents(month: 11, day: 11, hour: 8))
        XCTAssertEqual(said(.weekend), DateComponents(month: 11, day: 14, hour: 9))
        XCTAssertEqual(said(.nextWeek), DateComponents(month: 11, day: 16, hour: 8))
        XCTAssertEqual(said(.nextMonth), DateComponents(month: 12, day: 10, hour: 8))
    }

    // MARK: Dictated notes

    func testDictatedNote() throws {
        let store = try GraphStore(root: folder)
        defer { store.close() }
        let card = try XCTUnwrap(store.newNote(saying: " Buy milk,\nand bread. "))
        XCTAssertEqual(try store.engine.read(path: card.path), "- Buy milk, and bread.\n")
        XCTAssertNil(store.river.writing)
        XCTAssertEqual(store.draft(path: card.path, title: card.title).label, "Buy milk, and bread.")
        // One typed is opened to be written in, as before.
        let typed = try XCTUnwrap(store.newNote())
        XCTAssertEqual(store.river.writing, typed.id)
    }
}
