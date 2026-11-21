import Foundation
import Prism
import XCTest
@testable import WeftKit

/// A link on the web made a page of its own: its link note made and
/// opened after the note, and the note's links to it made links to it.
@MainActor
final class LinkPageTests: XCTestCase {
    func testALinkBecomesALinkPageAndTheNoteLinksToIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("weft-linkpage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let address = "https://example.com/essay"
        try "# Reading\n\n- read [the essay](\(address)) today\n- again <\(address)>\n- and \(address)\n- not https://example.com/essay2\n"
            .write(to: folder.appendingPathComponent("notes/reading.md"), atomically: true, encoding: .utf8)
        let store = try GraphStore(root: folder)
        defer { store.close() }
        store.open(name: "Reading")
        let reading = try XCTUnwrap(store.river.cards.first)
        let draft = store.draft(path: reading.path, title: reading.title)

        XCTAssertTrue(store.makeLinkPage(address: address, in: draft))
        let page = try XCTUnwrap(store.river.cards.first { $0.path != reading.path })
        // Opened after the note, called by the link's words.
        XCTAssertEqual(store.river.cards.map(\.path), [reading.path, page.path])
        XCTAssertEqual(page.title, "the essay")
        let made = (try? String(contentsOf: folder.appendingPathComponent(page.path), encoding: .utf8)) ?? ""
        XCTAssert(made.contains("- URL: <\(address)>") && made.contains("icon: link"), made)
        // Every link to it in the note, a link to the page; another address left be.
        let name = try XCTUnwrap(Prism.linkName(path: page.path))
        let note = (try? String(contentsOf: folder.appendingPathComponent(reading.path), encoding: .utf8)) ?? ""
        XCTAssertEqual(note, "# Reading\n\n- read [[\(name)]] today\n- again [[\(name)]]\n- and [[\(name)]]\n- not https://example.com/essay2\n")
        XCTAssertEqual(draft.markdown, note)
    }
}
