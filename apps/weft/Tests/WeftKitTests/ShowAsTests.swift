import Foundation
import XCTest
@testable import WeftKit

/// A note shown as written, or always as an outline or prose: said on this device, and taken back.
@MainActor
final class ShowAsTests: XCTestCase {
    func testShownAsIsSaidAndTakenBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("weft-showas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Essay\n\nA paragraph of words.\n\nAnother paragraph.\n".write(to: folder.appendingPathComponent("notes/essay.md"), atomically: true, encoding: .utf8)
        let store = try GraphStore(root: folder)
        defer { store.close() }
        let draft = store.draft(path: "notes/essay.md", title: "Essay")
        // Written as paragraphs: automatic, it reads as prose.
        XCTAssertEqual(draft.shownAs, .automatic)
        XCTAssertTrue(draft.isProse)
        draft.show(as: .outline)
        XCTAssertEqual(draft.shownAs, .outline)
        XCTAssertFalse(draft.isProse)
        // Said on this device: a draft read again has it.
        XCTAssertEqual(try store.engine.localValue(name: "weft/prose/notes/essay.md"), "outline")
        draft.show(as: .automatic)
        XCTAssertEqual(draft.shownAs, .automatic)
        XCTAssertTrue(draft.isProse)
        XCTAssertNil(try store.engine.localValue(name: "weft/prose/notes/essay.md"))
    }
}
