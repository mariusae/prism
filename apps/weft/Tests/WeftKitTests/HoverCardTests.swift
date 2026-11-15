#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import PrismEditor

/// A link's card: it opens, grows as its picture comes in, and settles.
@MainActor
final class HoverCardTests: XCTestCase {
    @Observable final class Late { var picture = false }

    func testACardThatGrowsSettles() throws {
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let late = Late()
        struct Content: View {
            let late: Late
            var body: some View {
                VStack(alignment: .leading, spacing: 0) {
                    if late.picture { Color.gray.frame(width: 300, height: 150) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("A page with a title long enough to wrap onto a second line, or more").font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text("example.com").font(.caption).lineLimit(1)
                        Button {} label: { Label("Show as Card", systemImage: "link").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                    }
                    .padding(12)
                }
                .frame(width: 300, alignment: .leading)
            }
        }
        let card = HoverCard(content: AnyView(Content(late: late)), at: CGPoint(x: 400, y: 400), over: window)
        defer { card.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let before = try XCTUnwrap(window.childWindows?.first).frame.size
        XCTAssertEqual(before.width, 300, accuracy: 1)
        late.picture = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let after = try XCTUnwrap(window.childWindows?.first).frame.size
        XCTAssertEqual(after.height, before.height + 150, accuracy: 1)
    }

    /// A note's card: its title and first lines, which wrap at the card's width.
    func testANotesCardOpens() throws {
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for words in [6, 13, 29, 57, 113] {
            let line = Array(repeating: "lorem ipsum dolor", count: words).joined(separator: " ")
            let content = VStack(alignment: .leading, spacing: 5) {
                Text("A note").font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text([line, line, "short", line].joined(separator: "\n")).font(.system(size: 12)).lineLimit(7)
                Button {} label: { Label("Show as Card", systemImage: "link").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)
            let card = HoverCard(content: AnyView(content), at: CGPoint(x: 400, y: 400), over: window)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(try XCTUnwrap(window.childWindows?.first).frame.width, 300, accuracy: 1)
            card.close()
        }
    }
}
#endif
