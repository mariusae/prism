import Foundation
import Prism
import XCTest
@testable import WeftKit

/// A note's home river: `river:` in its frontmatter, given where it is
/// made or first saved, carried when it is moved, and gone to with ⌘.
@MainActor
final class HomeRiverTests: XCTestCase {
    private func graph() throws -> (URL, GraphStore) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("weft-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try "# Plan\n\n- one\n".write(to: folder.appendingPathComponent("notes/plan.md"), atomically: true, encoding: .utf8)
        try "# Other\n\n- two\n".write(to: folder.appendingPathComponent("notes/other.md"), atomically: true, encoding: .utf8)
        return (folder, try GraphStore(root: folder))
    }

    private func file(_ folder: URL, _ path: String) -> String {
        (try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    func testNamingARiverGivesItsNotesAHomeAndMovingCarriesIt() throws {
        let (folder, store) = try graph()
        defer { store.close(); try? FileManager.default.removeItem(at: folder) }
        store.open(name: "Plan")
        let plan = try XCTUnwrap(store.river.cards.first)
        XCTAssertNil(store.home(of: plan.path))
        store.rename(store.river, to: "Work")
        store.save(store.river)
        XCTAssertEqual(store.home(of: plan.path), "Work")
        XCTAssert(file(folder, plan.path).contains("river: Work"), file(folder, plan.path))

        // Moved to another saved river: its home goes with it.
        let work = store.river
        store.newRiver()
        let other = store.river
        store.rename(other, to: "Later")
        store.save(other)
        store.send([plan.id], from: work, to: other)
        XCTAssertEqual(store.home(of: plan.path), "Later")

        // Its river renamed: its home is called by the new name.
        store.rename(other, to: "Someday")
        XCTAssertEqual(store.home(of: plan.path), "Someday")
        XCTAssert(file(folder, plan.path).contains("river: Someday"), file(folder, plan.path))
    }

    func testANoteMadeInASavedRiverHasItAsHomeAndIsGoneToThere() throws {
        let (folder, store) = try graph()
        defer { store.close(); try? FileManager.default.removeItem(at: folder) }
        store.rename(store.river, to: "Inbox")
        store.save(store.river)
        let made = try XCTUnwrap(store.newNote(saying: "a thought"))
        XCTAssertEqual(store.home(of: made.path), "Inbox")
        XCTAssert(file(folder, made.path).contains("river: Inbox"), file(folder, made.path))

        // Closed, then gone to from another river: its home is opened, the note shown in it.
        let inbox = store.river
        inbox.close(made.id)
        store.save(inbox)
        store.newRiver()
        XCTAssertNil(store.openPlace(of: made.path))
        XCTAssertTrue(store.goToNote(path: made.path, title: made.title))
        XCTAssertEqual(store.river.name, "Inbox")
        XCTAssertNotNil(store.river.all.first { $0.path == made.path })
    }
}
