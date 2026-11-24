import Foundation
import Prism
import XCTest
@testable import WeftKit

/// ⇧⌘N: a new row at the top of today, written in at once.
@MainActor
final class TodayRowTests: XCTestCase {
    func testANewRowGoesAtTheTopOfTodayAndIsWrittenIn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("weft-today-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try GraphStore(root: folder)
        defer { store.close() }
        let day = Days.name(Date())
        let path = store.engine.pathForTitle(title: day)
        let read = { (try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)) ?? "" }

        // No note for today yet: made, with a row to write in.
        XCTAssertTrue(store.writeAtTopOfToday())
        let card = try XCTUnwrap(store.river.all.first { $0.path == path })
        XCTAssertEqual(store.river.writing, card.id)
        XCTAssertEqual(store.river.goingTo?.card, card.id)
        XCTAssertEqual(GraphStore.firstBodyLine(of: read())?.trimmingCharacters(in: .whitespaces), "-", read())

        // Written in, then asked again: a new row above what was written.
        try "- first thought\n- second\n".write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
        store.draft(path: path, title: day).fileChanged()
        XCTAssertTrue(store.writeAtTopOfToday())
        XCTAssertEqual(read().components(separatedBy: "\n").prefix(3).map { $0.trimmingCharacters(in: .whitespaces) }, ["-", "- first thought", "- second"], read())
        // Asked again with that row still empty: no other made.
        XCTAssertTrue(store.writeAtTopOfToday())
        XCTAssertEqual(read().components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces) == "-" }.count, 1, read())
        XCTAssertEqual(store.river.all.filter { $0.path == path }.count, 1)
    }
}
