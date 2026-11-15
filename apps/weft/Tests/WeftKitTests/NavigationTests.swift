import Foundation
import Prism
import XCTest
@testable import WeftKit

/// Back and forward: where the reader has been, across rivers and cards.
@MainActor
final class NavigationTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("weft-nav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
        for name in ["Alpha", "Beta", "Gamma"] {
            try "# \(name)\n\nwords\n".write(to: folder.appendingPathComponent("notes/\(name.lowercased()).md"), atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testBackAndForwardGoWhereTheReaderWas() throws {
        let store = try GraphStore(root: folder)
        defer { store.close() }
        // A link followed to Alpha, then on to Beta: two steps, each back to the card it was followed from.
        store.open(name: "Alpha")
        let first = store.river
        let alpha = try XCTUnwrap(first.selected)
        store.open(name: "Beta", after: alpha)
        let beta = try XCTUnwrap(first.selected)
        XCTAssertNotEqual(alpha, beta)
        XCTAssertTrue(store.canGoBack)
        store.goBack()
        XCTAssertEqual(first.selected, alpha)
        XCTAssertTrue(store.canGoForward)
        // The cards opened stay in the river.
        XCTAssertEqual(first.cards.count, 2)
        store.goForward()
        XCTAssertEqual(first.selected, beta)
        XCTAssertFalse(store.canGoForward)

        // Another river is a step too; and back is back in the first, at the card it was at.
        store.newRiver()
        let second = store.river
        XCTAssertFalse(second === first)
        store.goBack()
        XCTAssertTrue(store.river === first)
        XCTAssertEqual(first.selected, beta)
        store.goForward()
        XCTAssertTrue(store.river === second)

        // Going somewhere new from a place gone back to: what was ahead is gone.
        store.goBack()
        store.open(name: "Gamma", after: beta)
        XCTAssertFalse(store.canGoForward)

        // Several back at once, as from the list of where the reader has been.
        store.goBack(2)
        XCTAssertEqual(first.selected, alpha)
    }

    func testAPlaceInAClosedRiverIsPassedOver() throws {
        let store = try GraphStore(root: folder)
        defer { store.close() }
        store.open(name: "Alpha")
        let first = store.river
        store.newRiver()
        store.open(name: "Beta")
        store.newRiver()
        // The river in between closed: back goes past it, to the first.
        let middle = store.rivers[store.rivers.count - 2]
        store.rivers.removeAll { $0 === middle }
        store.currentRiver = store.rivers.count - 1
        store.goBack()
        XCTAssertTrue(store.river === first)
    }
}
