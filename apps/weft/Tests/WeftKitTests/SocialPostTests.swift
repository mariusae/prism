import XCTest
@testable import WeftShared

final class SocialPostTests: XCTestCase {
    func testWhatIsAPost() {
        XCTAssertTrue(SocialPost.recognizes("https://x.com/jack/status/20"))
        XCTAssertTrue(SocialPost.recognizes("https://twitter.com/jack/status/20?s=46"))
        XCTAssertTrue(SocialPost.recognizes("https://mobile.twitter.com/i/web/status/20"))
        XCTAssertFalse(SocialPost.recognizes("https://x.com/jack"))
        XCTAssertTrue(SocialPost.recognizes("https://bsky.app/profile/bsky.app/post/3l6oveex3ii2l"))
        XCTAssertTrue(SocialPost.recognizes("https://www.threads.net/@zuck/post/C1aB2cD3eF4"))
        XCTAssertTrue(SocialPost.recognizes("https://mastodon.social/@Gargron/109257264418787813"))
        XCTAssertTrue(SocialPost.recognizes("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertTrue(SocialPost.recognizes("https://youtu.be/dQw4w9WgXcQ"))
        XCTAssertFalse(SocialPost.recognizes("https://www.youtube.com/@someone"))
        XCTAssertFalse(SocialPost.recognizes("https://example.com/@who/notes"))
        XCTAssertFalse(SocialPost.recognizes("https://en.wikipedia.org/wiki/Comparative_advantage"))
    }

    func testTitles() {
        var post = SocialPost(site: .x, author: "jack", handle: "jack", text: "just setting up my\ntwttr", date: nil, image: nil)
        XCTAssertEqual(post.title, "jack: just setting up my twttr")
        XCTAssertEqual(post.byline, "jack")
        post.author = "Jack Dorsey"
        XCTAssertEqual(post.byline, "Jack Dorsey (@jack)")
        post.text = String(repeating: "word ", count: 40)
        XCTAssertTrue(post.title.hasSuffix("…") && post.title.count <= 100)
        post.text = ""
        XCTAssertEqual(post.title, "Jack Dorsey on X")
        XCTAssertEqual(SocialPost(site: .youtube, author: "Rick Astley", handle: nil, text: "Never Gonna Give You Up", date: nil, image: nil).title, "Never Gonna Give You Up")
        XCTAssertEqual(SocialPost.plain("Hello&nbsp;<a href=\"x\">world</a><br>again &amp; again"), "Hello world\nagain & again")
    }

    /// The sites themselves, asked: `WEFT_LIVE=1 swift test --filter SocialPostTests`.
    func testReadingLive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WEFT_LIVE"] != nil, "asks the sites; WEFT_LIVE=1 to")
        for address in ["https://x.com/jack/status/20", "https://bsky.app/profile/bsky.app/post/3l6oveex3ii2l",
                        "https://mastodon.social/@Gargron/1", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"] {
            let post = await SocialPost.read(address)
            print("\(address) → \(post.map { "\($0.title) | \($0.byline) | \(String(describing: $0.date))" } ?? "nil")")
        }
        let jack = await SocialPost.read("https://x.com/jack/status/20")
        XCTAssertEqual(jack?.title, "jack: just setting up my twttr")
    }
}
