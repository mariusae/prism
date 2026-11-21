import Foundation
import Prism
import XCTest
@testable import WeftKit

/// A topic note — `topic: true` — gone to as a river: the topic kept at
/// the top, and under it every note that links to it.
@MainActor
final class TopicTests: XCTestCase {
    private func graph() throws -> (URL, GraphStore) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("weft-topic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try "# Idle Thoughts\n\n- what these are\n".write(to: folder.appendingPathComponent("notes/idle-thoughts.md"), atomically: true, encoding: .utf8)
        try "# Walk\n\n- a thought on a walk [[Idle Thoughts]]\n".write(to: folder.appendingPathComponent("notes/walk.md"), atomically: true, encoding: .utf8)
        try "# Train\n\n- and on the train\n  - see [[Idle Thoughts]]\n".write(to: folder.appendingPathComponent("notes/train.md"), atomically: true, encoding: .utf8)
        try "# Other\n\n- nothing of it, but [[Walk]]\n".write(to: folder.appendingPathComponent("notes/other.md"), atomically: true, encoding: .utf8)
        return (folder, try GraphStore(root: folder))
    }

    private func file(_ folder: URL, _ path: String) -> String {
        (try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    func testMakingATopicGoesToItsRiverOfWhatLinksToIt() throws {
        let (folder, store) = try graph()
        defer { store.close(); try? FileManager.default.removeItem(at: folder) }
        store.open(name: "Other")
        let other = store.river
        let topic = "notes/idle-thoughts.md"
        store.open(name: "Idle Thoughts")
        XCTAssertFalse(store.isTopic(topic))

        store.toggleTopic(path: topic, title: "Idle Thoughts")
        XCTAssertTrue(store.isTopic(topic))
        XCTAssert(file(folder, topic).contains("topic: true"), file(folder, topic))
        let river = store.river
        XCTAssertFalse(river === other)
        XCTAssertEqual(store.topic(of: river), topic)
        XCTAssertEqual(store.title(of: river), "Idle Thoughts")
        // The topic at the top, kept there; under it what links to it, each where it does.
        XCTAssertEqual(river.cards.map(\.path), [topic])
        XCTAssertTrue(river.cards[0].pinned)
        XCTAssertEqual(Set(river.found.map(\.path)), ["notes/walk.md", "notes/train.md"])
        XCTAssert(river.found.allSatisfy { $0.lens == .mentions(topic) && !$0.folded })

        // Gone to again — by a link, from another river — it is the same river.
        store.currentRiver = store.rivers.firstIndex { $0 === other }!
        store.open(name: "Idle Thoughts", after: nil, in: other)
        XCTAssertTrue(store.river === river)
        XCTAssertEqual(store.rivers.filter { store.topic(of: $0) == topic }.count, 1)
        XCTAssertTrue(store.goToNote(path: topic, title: "Idle Thoughts"))
        XCTAssertTrue(store.river === river)

        // A note made in it is of the topic, and so found in it.
        let made = try XCTUnwrap(store.newNote(saying: "one more"))
        XCTAssert(file(folder, made.path).contains("- idle-thoughts"), file(folder, made.path))

        // Made a note again: it opens as any note does.
        store.toggleTopic(path: topic, title: "Idle Thoughts")
        XCTAssertFalse(store.isTopic(topic))
        XCTAssertNil(store.topic(of: river))
        XCTAssertFalse(file(folder, topic).contains("topic:"))
    }

    func testATopicsRiverNamedIsItsHomeAndIsOpenedAgain() throws {
        let (folder, store) = try graph()
        defer { store.close(); try? FileManager.default.removeItem(at: folder) }
        let topic = "notes/idle-thoughts.md"
        store.toggleTopic(path: topic, title: "Idle Thoughts")
        let river = store.river
        store.rename(river, to: "Thoughts")
        store.save(river)
        XCTAssertEqual(store.home(of: topic), "Thoughts")
        let saved = file(folder, "rivers/Thoughts.md")
        XCTAssert(saved.contains("links to: idle-thoughts") && saved.contains("pinned:"), saved)

        // Closed, and gone to again: its saved river, not a new one.
        store.newRiver()
        store.closeRiver(at: store.rivers.firstIndex { $0 === river }!)
        store.open(name: "Idle Thoughts")
        XCTAssertEqual(store.river.name, "Thoughts")
        XCTAssertEqual(store.river.cards.first?.path, topic)
        XCTAssertEqual(store.topic(of: store.river), topic)
        XCTAssertEqual(Set(store.river.found.map(\.path)), ["notes/walk.md", "notes/train.md"])
    }
}
