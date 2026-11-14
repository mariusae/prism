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

final class WebPageInfoTests: XCTestCase {
    func testBareAndSubstack() {
        XCTAssertTrue(WebPageInfo.isBare(title: "open.substack.com", url: "https://open.substack.com/pub/a/p/b"))
        XCTAssertTrue(WebPageInfo.isBare(title: "", url: "https://x.example/p"))
        XCTAssertFalse(WebPageInfo.isBare(title: "Stop Talking", url: "https://open.substack.com/pub/a/p/b"))
        XCTAssertEqual(WebPageInfo.substack(URL(string: "https://open.substack.com/pub/richardhanania/p/stop-talking")!)?.slug, "stop-talking")
        XCTAssertEqual(WebPageInfo.substack(URL(string: "https://noahpinion.substack.com/p/a-post")!)?.publication, "noahpinion")
        XCTAssertNil(WebPageInfo.substack(URL(string: "https://example.com/p/a")!))
        let page = WebPageInfo.parse(#"<html><head><title>T</title><meta property="og:title" content="Real &amp; Title"/><meta name="author" content="Ann"/></head>"#)
        XCTAssertEqual(page?.title, "Real & Title")
        XCTAssertEqual(page?.author, "Ann")
        XCTAssertNil(WebPageInfo.parse("<title>https://a.example/p</title>"))
    }

    func testSubstackLive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WEFT_LIVE"] != nil, "asks Substack; WEFT_LIVE=1 to")
        let page = await WebPageInfo.read("https://open.substack.com/pub/richardhanania/p/stop-talking-about-ai-job-loss-and")
        XCTAssertEqual(page?.title, "Stop Talking about AI Job Loss and Take Productivity Seriously")
        XCTAssertEqual(page?.author, "Richard Hanania")
    }
}
