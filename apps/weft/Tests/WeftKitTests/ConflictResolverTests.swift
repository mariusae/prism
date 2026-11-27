import Foundation
import Prism
import XCTest
@testable import WeftKit

/// A note in conflict settled a place at a time.
@MainActor
final class ConflictResolverTests: XCTestCase {
    private let note = "# Packing\n\n- Costa Rica\n<<<<<<< this device\n- [x] Running belt\n=======\n- Running belt\n- Chalk bag\n>>>>>>> other device\n- Passport\n<<<<<<< this device\n- Book\n=======\n>>>>>>> other device\n- Snacks\n"

    func testEachPlaceIsSettledOnItsOwn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("weft-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try note.write(to: folder.appendingPathComponent("notes/packing.md"), atomically: true, encoding: .utf8)
        let store = try GraphStore(root: folder)
        defer { store.close() }
        let draft = store.draft(path: "notes/packing.md", title: "Packing")
        XCTAssertTrue(draft.isConflicted)
        XCTAssertEqual(draft.conflictParts.filter(\.isConflict).count, 2)

        // The second, kept as this device has it: the first is left to settle.
        draft.resolve(conflict: 1, keeping: .ours)
        XCTAssertTrue(draft.isConflicted)
        XCTAssertEqual(draft.conflictParts.filter(\.isConflict).count, 1)
        // Then the first, both: settled, and written so.
        draft.resolve(conflict: 0, keeping: .both)
        XCTAssertFalse(draft.isConflicted)
        let file = try String(contentsOf: folder.appendingPathComponent("notes/packing.md"), encoding: .utf8)
        XCTAssertEqual(file, "# Packing\n\n- Costa Rica\n- [x] Running belt\n- Running belt\n- Chalk bag\n- Passport\n- Book\n- Snacks\n")
    }

    func testAPlaceIsShownWithALineOrTwoAroundIt() {
        let parts: [ConflictSegment] = [
            .text(text: "- a\n- b\n- c\n- d"),
            .conflict(ourLabel: "this device", ours: "- x", theirLabel: "other device", theirs: "- y"),
            .text(text: "- e\n- f\n- g\n- h\n- i\n- j"),
        ]
        let places = ConflictResolver.places(parts)
        guard places.count == 5 else { return XCTFail("\(places)") }
        if case .gap = places[0] {} else { XCTFail("\(places[0])") }
        if case .context(let lines) = places[1] { XCTAssertEqual(lines, ["- c", "- d"]) } else { XCTFail() }
        if case .conflict(0, "- x", "- y") = places[2] {} else { XCTFail("\(places[2])") }
        if case .context(let lines) = places[3] { XCTAssertEqual(lines, ["- e", "- f"]) } else { XCTFail() }
        if case .gap = places[4] {} else { XCTFail() }
    }
}
