import Foundation
import Prism
import XCTest
@testable import WeftKit

/// Go to Row: a row under a fold is unfolded into sight, and the caret asked for at its words.
@MainActor
final class GoToRowTests: XCTestCase {
    func testARowUnderAFoldIsBroughtIntoSight() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("weft-goto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Plan\n\n- one\n  - two\n    - three\n- four\n".write(to: folder.appendingPathComponent("notes/plan.md"), atomically: true, encoding: .utf8)
        let store = try GraphStore(root: folder)
        defer { store.close() }
        store.open(name: "Plan")
        let card = try XCTUnwrap(store.river.cards.first)
        let editor = store.draft(path: card.path, title: card.title).editor
        _ = editor.setFoldedRows(rows: [RiverFoldedRow(index: 0, text: "one")])
        XCTAssertEqual(editor.text(), "one\nfour")
        // Listed under the fold still.
        XCTAssertEqual(editor.outline().map(\.words), ["one", "two", "three", "four"])
        store.goToRow(card: card.id, index: 2)
        XCTAssertEqual(editor.text(), "one\ntwo\nthree\nfour")
        XCTAssertEqual(store.river.writing, card.id)
        let at = try XCTUnwrap(store.river.goingTo)
        XCTAssertEqual(at.card, card.id)
        XCTAssertEqual((editor.text() as NSString).substring(with: NSRange(location: at.at, length: 5)), "three")
    }
}
