import Foundation

/// A post on a social site — X, Threads, Bluesky, Mastodon — or a video on
/// YouTube, read from the site's own embed or public API: who said it,
/// what they said, when. What a page shared or a link pasted is called by,
/// where the page itself would say only "X".
public struct SocialPost: Codable, Equatable, Sendable {
    public enum Site: String, Codable, Sendable {
        case x, threads, bluesky, mastodon, youtube

        public var name: String {
            switch self {
            case .x: "X"
            case .threads: "Threads"
            case .bluesky: "Bluesky"
            case .mastodon: "Mastodon"
            case .youtube: "YouTube"
            }
        }
    }

    public var site: Site
    /// Who: their name, and their handle on the site (`@who`), if it has one.
    public var author: String
    public var handle: String?
    /// What they said; for a video, its title.
    public var text: String
    public var date: Date?
    /// The post's first picture, or the video's: an address.
    public var image: String?

    /// What the post is called: its author and its first words — a
    /// video, its own title.
    public var title: String {
        if site == .youtube { return text }
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !words.isEmpty else { return "\(author) on \(site.name)" }
        // A hundred characters at most, the author's name and all.
        let room = max(100 - author.count - 2, 30)
        let cut = words.count > room ? String(words.prefix(room - 1)).trimmingCharacters(in: .whitespaces) + "…" : words
        return "\(author): \(cut)"
    }

    /// Who said it, as a note writes it: `Name (@who)`.
    public var byline: String {
        guard let handle, !handle.isEmpty, handle != author else { return author }
        return "\(author) (@\(handle))"
    }

    /// Whether an address is a post or video this can read.
    public static func recognizes(_ address: String) -> Bool { Source(address) != nil }

    /// The post an address is of, read; nil where it is no post, or the site would not say.
    public static func read(_ address: String) async -> SocialPost? {
        guard let source = Source(address) else { return nil }
        switch source {
        case .x(let id): return await x(id)
        case .threads(let path): return await threads(path)
        case .bluesky(let actor, let key): return await bluesky(actor, key)
        case .mastodon(let host, let id): return await mastodon(host, id)
        case .youtube(let address): return await youtube(address)
        }
    }

    // MARK: What an address is

    enum Source: Equatable {
        case x(String)
        case threads(String)
        case bluesky(String, String)
        case mastodon(String, String)
        case youtube(String)

        init?(_ address: String) {
            guard let url = URL(string: address), var host = url.host?.lowercased() else { return nil }
            for prefix in ["www.", "mobile.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
            let parts = url.path.split(separator: "/").map(String.init)
            switch host {
            case "x.com", "twitter.com", "fxtwitter.com", "vxtwitter.com", "fixupx.com", "fixvx.com":
                // `who/status/123`, `/i/web/status/123`, `/statuses/123`.
                guard let at = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }), at + 1 < parts.count,
                      !parts[at + 1].isEmpty, parts[at + 1].allSatisfy(\.isNumber) else { return nil }
                self = .x(parts[at + 1])
            case "threads.net", "threads.com":
                if parts.count >= 3, parts[0].hasPrefix("@"), parts[1] == "post" { self = .threads(parts[0...2].joined(separator: "/")) } else { return nil }
            case "bsky.app":
                // `profile/who/post/key`.
                if parts.count >= 4, parts[0] == "profile", parts[2] == "post" { self = .bluesky(parts[1], parts[3]) } else { return nil }
            case "youtube.com", "youtu.be", "music.youtube.com":
                let isVideo = host == "youtu.be" ? parts.count == 1 : (parts.first == "watch" || parts.first == "shorts" || parts.first == "live")
                if isVideo { self = .youtube(address) } else { return nil }
            default:
                // Mastodon, wherever it is kept: `/@who/123`.
                if parts.count == 2, parts[0].hasPrefix("@"), parts[1].count >= 6, parts[1].allSatisfy(\.isNumber) { self = .mastodon(host, parts[1]) } else { return nil }
            }
        }
    }

    // MARK: Reading each site

    private static func get(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func json(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func date(_ written: Any?) -> Date? {
        guard let written = written as? String else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: written) ?? ISO8601DateFormatter().date(from: written)
    }

    /// Words from HTML: its tags gone, its entities read, its breaks kept.
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p><p>", with: "\n\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&#064;", "@"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// X: its embed endpoint, which wants a token worked out from the id, as the embed code does.
    private static func x(_ id: String) async -> SocialPost? {
        guard let number = Double(id) else { return nil }
        let token = base36(number / 1e15 * Double.pi).filter { $0 != "0" && $0 != "." }
        guard let root = json(await get(URL(string: "https://cdn.syndication.twimg.com/tweet-result?id=\(id)&lang=en&token=\(token.isEmpty ? "a" : token)"))),
              var text = root["text"] as? String, let user = root["user"] as? [String: Any], let name = user["name"] as? String else { return nil }
        // The text runs past what is shown, to the links of its pictures.
        if let range = root["display_text_range"] as? [Int], range.count == 2 {
            let scalars = Array(text.unicodeScalars)
            let upper = min(range[1], scalars.count)
            if range[0] < upper { text = String(String.UnicodeScalarView(scalars[range[0]..<upper])) }
        }
        // Its short links, written out as they are shown.
        for link in ((root["entities"] as? [String: Any])?["urls"] as? [[String: Any]]) ?? [] {
            if let short = link["url"] as? String, let shown = link["expanded_url"] as? String ?? link["display_url"] as? String {
                text = text.replacingOccurrences(of: short, with: shown)
            }
        }
        let image = ((root["mediaDetails"] as? [[String: Any]])?.first?["media_url_https"] as? String) ?? (user["profile_image_url_https"] as? String)
        return SocialPost(site: .x, author: name, handle: user["screen_name"] as? String, text: plain(text), date: date(root["created_at"]), image: image)
    }

    private static func base36(_ value: Double) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var whole = UInt64(value), fraction = value - Double(UInt64(value))
        var text = ""
        repeat {
            text.insert(digits[Int(whole % 36)], at: text.startIndex)
            whole /= 36
        } while whole > 0
        text += "."
        for _ in 0..<11 {
            fraction *= 36
            let digit = Int(fraction)
            text.append(digits[digit])
            fraction -= Double(digit)
        }
        return text
    }

    /// Threads: its embed page, read for who, what and when.
    private static func threads(_ path: String) async -> SocialPost? {
        guard let data = await get(URL(string: "https://www.threads.net/\(path)/embed")), let html = String(data: data, encoding: .utf8) else { return nil }
        func first(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
        guard let name = first(#"class="HeaderLink"[^>]*><span>([^<]+)</span>"#).map(plain) else { return nil }
        let body = first(#"class="BodyTextContainer">(.*?)</span></span>"#).map(plain) ?? ""
        let handle = path.split(separator: "/").first.map { String($0.dropFirst()) }
        return SocialPost(site: .threads, author: name, handle: handle, text: body, date: nil, image: nil)
    }

    /// Bluesky: its public API, the post asked for by its at:// address.
    private static func bluesky(_ actor: String, _ key: String) async -> SocialPost? {
        let at = "at://\(actor)/app.bsky.feed.post/\(key)"
        var parts = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread")
        parts?.queryItems = [URLQueryItem(name: "uri", value: at), URLQueryItem(name: "depth", value: "0")]
        guard let post = (json(await get(parts?.url))?["thread"] as? [String: Any])?["post"] as? [String: Any],
              let record = post["record"] as? [String: Any], let author = post["author"] as? [String: Any] else { return nil }
        let handle = author["handle"] as? String
        let name = (author["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? handle ?? actor
        let images = (post["embed"] as? [String: Any])?["images"] as? [[String: Any]]
        return SocialPost(site: .bluesky, author: name, handle: handle, text: record["text"] as? String ?? "", date: date(record["createdAt"]),
                          image: images?.first?["thumb"] as? String ?? author["avatar"] as? String)
    }

    /// Mastodon, on whichever server: its public API for a status.
    private static func mastodon(_ host: String, _ id: String) async -> SocialPost? {
        guard let root = json(await get(URL(string: "https://\(host)/api/v1/statuses/\(id)"))), let account = root["account"] as? [String: Any],
              let content = root["content"] as? String else { return nil }
        let handle = account["acct"] as? String
        let name = (account["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? handle ?? host
        let image = ((root["media_attachments"] as? [[String: Any]])?.first?["preview_url"] as? String) ?? account["avatar"] as? String
        return SocialPost(site: .mastodon, author: name, handle: handle, text: plain(content), date: date(root["created_at"]), image: image)
    }

    /// YouTube: its oEmbed, for the video's title and who made it.
    private static func youtube(_ address: String) async -> SocialPost? {
        var parts = URLComponents(string: "https://www.youtube.com/oembed")
        parts?.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "url", value: address)]
        guard let root = json(await get(parts?.url)), let title = root["title"] as? String else { return nil }
        return SocialPost(site: .youtube, author: root["author_name"] as? String ?? "YouTube", handle: nil, text: title, date: nil, image: root["thumbnail_url"] as? String)
    }
}
