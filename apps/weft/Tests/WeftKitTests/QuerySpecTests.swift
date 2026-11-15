import XCTest
@testable import WeftKit

/// What the query builder writes, and what a river of it is called unnamed.
final class QuerySpecTests: XCTestCase {
    func testAnUnnamedRiverIsCalledWhatItAsksFor() {
        var spec = QuerySpec()
        // Asking for nothing in particular: what it is sorted by.
        XCTAssertEqual(spec.suggestedName, "Newest Changed")
        spec.kinds["task"] = .only
        XCTAssertEqual(spec.suggestedName, "To-Dos")
        spec.kinds["archived"] = .not
        spec.tags = ["work"]
        spec.saying = " launch "
        XCTAssertEqual(spec.suggestedName, "To-Dos, Not Archived, #work, “launch”")
        // And the query it writes is the one read back.
        XCTAssertEqual(QuerySpec(body: spec.body).body, spec.body)
        XCTAssertTrue(spec.body.contains("is: task") && spec.body.contains("is not: archived"))
    }
}
