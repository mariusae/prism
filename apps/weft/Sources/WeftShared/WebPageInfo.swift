import Foundation

/// What a web page says of itself — its title, a line of what it is, who
/// wrote it, its picture — read from the page: its Open Graph and other
/// meta tags, after redirects. For a page shared with no more than its
/// address (Substack's app shares `open.substack.com/pub/…`, which says
/// nothing of the post until it is followed).
public struct WebPageInfo: Equatable, Sendable {
    public var title: String
    public var description: String
    public var author: String?
    public var image: String?

    /// The page read; nil where it could not be, or says nothing.
    public static func read(_ address: String) async -> WebPageInfo? {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return nil }
        // A Substack post: its own API knows its title, subtitle and author, where its page first only points onward.
        if let post = substack(url), let read = await substack(post.publication, post.slug) { return read }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data.prefix(400_000), encoding: .utf8) ?? String(data: data.prefix(400_000), encoding: .isoLatin1) else { return nil }
        return parse(html)
    }

    /// A Substack post an address is of: `open.substack.com/pub/who/p/slug`,
    /// or `who.substack.com/p/slug`.
    static func substack(_ url: URL) -> (publication: String, slug: String)? {
        guard let host = url.host()?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "open.substack.com", parts.count >= 4, parts[0] == "pub", parts[2] == "p" { return (parts[1], parts[3]) }
        if host.hasSuffix(".substack.com"), host != "open.substack.com", parts.count >= 2, parts[0] == "p" {
            return (String(host.dropLast(".substack.com".count)), parts[1])
        }
        return nil
    }

    private static func substack(_ publication: String, _ slug: String) async -> WebPageInfo? {
        guard let url = URL(string: "https://\(publication).substack.com/api/v1/posts/\(slug)"),
              let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let title = root["title"] as? String, !title.isEmpty else { return nil }
        let authors = (root["publishedBylines"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        return WebPageInfo(title: title, description: root["subtitle"] as? String ?? root["description"] as? String ?? "",
                           author: authors.isEmpty ? nil : authors.joined(separator: ", "), image: root["cover_image"] as? String)
    }

    /// What a page's head says: `og:`, `twitter:` and plain meta tags, and `<title>`.
    static func parse(_ html: String) -> WebPageInfo? {
        var tags: [String: String] = [:]
        let meta = try? NSRegularExpression(pattern: #"<meta\s+[^>]*>"#, options: [.caseInsensitive])
        let attribute = try? NSRegularExpression(pattern: #"([a-zA-Z:-]+)\s*=\s*("([^"]*)"|'([^']*)')"#)
        let whole = NSRange(html.startIndex..., in: html)
        for match in meta?.matches(in: html, range: whole) ?? [] {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            var found: [String: String] = [:]
            for pair in attribute?.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) ?? [] {
                guard let key = Range(pair.range(at: 1), in: tag) else { continue }
                let value = Range(pair.range(at: 3), in: tag) ?? Range(pair.range(at: 4), in: tag)
                found[tag[key].lowercased()] = value.map { String(tag[$0]) } ?? ""
            }
            if let name = found["property"] ?? found["name"], let content = found["content"], !content.isEmpty, tags[name.lowercased()] == nil {
                tags[name.lowercased()] = SocialPost.plain(content)
            }
        }
        let plainTitle = (try? NSRegularExpression(pattern: #"<title[^>]*>([^<]*)</title>"#, options: [.caseInsensitive]))?
            .firstMatch(in: html, range: whole).flatMap { Range($0.range(at: 1), in: html) }.map { SocialPost.plain(String(html[$0])) }
        let title = tags["og:title"] ?? tags["twitter:title"] ?? plainTitle ?? ""
        // A page that only sends one onward is often called by its address: that is no title.
        guard !title.isEmpty, !title.hasPrefix("http://"), !title.hasPrefix("https://") else { return nil }
        let author = tags["author"] ?? tags["article:author"].flatMap { $0.hasPrefix("http") ? nil : $0 }
        return WebPageInfo(title: title, description: tags["og:description"] ?? tags["description"] ?? tags["twitter:description"] ?? "",
                        author: author, image: tags["og:image"] ?? tags["twitter:image"])
    }

    /// Whether what a page was shared with says nothing of it: no title, or only its site's name.
    public static func isBare(title: String, url: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty, let host = URL(string: url)?.host()?.lowercased() else { return true }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return title == host || title == site || title == url.lowercased()
    }
}
