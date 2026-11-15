import Foundation
import XCTest
@testable import WeftKit

/// Archived from its card, a note's card goes: the offer to undo is made,
/// and ⇧⌘T — reopening what was closed — brings it back, out of the archive.
@MainActor
final class ArchiveUndoTests: XCTestCase {
    private func store() throws -> (GraphStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("weft-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
        for name in ["Alpha", "Beta"] {
            try "# \(name)\n\n- words\n".write(to: folder.appendingPathComponent("notes/\(name.lowercased()).md"), atomically: true, encoding: .utf8)
        }
        return (try GraphStore(root: folder), folder)
    }

    func testReopeningAnArchivedCardUnarchivesIt() throws {
        let (store, folder) = try store()
        defer { store.close(); try? FileManager.default.removeItem(at: folder) }
        store.open(name: "Alpha")
        store.open(name: "Beta")
        let river = store.river
        let card = try XCTUnwrap(river.cards.first { $0.title == "Beta" })
        store.toggleArchived(path: card.path, title: card.title, closing: card.id, in: river)
        XCTAssertTrue(store.isArchived(card.path))
        XCTAssertFalse(river.cards.contains { $0.path == card.path })
        XCTAssertNotNil(store.undoOffer)
        // ⇧⌘T.
        XCTAssertTrue(store.reopenClosed())
        XCTAssertTrue(river.cards.contains { $0.path == card.path })
        XCTAssertFalse(store.isArchived(card.path))
        XCTAssertNil(store.undoOffer)
    }

    func testUndoingTheArchiveLeavesNothingToReopen() throws {
        let (store, folder) = try store()
        defer { store.close(); try? FileManager.default.removeItem(at: folder) }
        store.open(name: "Alpha")
        let river = store.river
        let card = try XCTUnwrap(river.cards.first)
        store.toggleArchived(path: card.path, title: card.title, closing: card.id, in: river)
        XCTAssertTrue(store.takeUndo())
        XCTAssertFalse(store.isArchived(card.path))
        XCTAssertTrue(river.cards.contains { $0.path == card.path })
        XCTAssertFalse(store.reopenClosed())
    }
}
