import Foundation

/// Web pages shared to Weft from other apps, waiting for Weft to make them
/// notes. The share extension leaves each here, in the folder the app and
/// the extension both reach; the app takes them in when it next comes to
/// the front. The extension never touches the graph — it could not sync,
/// and two writers to one repository is one too many.
public enum SharedPages {
    /// The app group the app and its share extension share.
    public static let group = "group.org.mutable.weft"

    /// A page as shared: what the page says of itself, where the sharing
    /// app could tell (Safari can), and what was selected on it.
    public struct Page: Codable, Equatable, Sendable {
        public var url: String
        public var title: String
        public var description: String
        public var selection: String
        public var shared: Date

        public init(url: String, title: String, description: String = "", selection: String = "", shared: Date = Date()) {
            self.url = url
            self.title = title
            self.description = description
            self.selection = selection
            self.shared = shared
        }
    }

    /// Where pages wait, or nil where the app group is not to be had.
    public static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("Shared", isDirectory: true)
    }

    /// Leaves a page for the app: a file of its own, written whole.
    public static func leave(_ page: Page) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(format: "%.0f-%@.json", page.shared.timeIntervalSince1970 * 1000, UUID().uuidString)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(page).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// The pages waiting, oldest first, each with the file it is in.
    public static func waiting() -> [(page: Page, file: URL)] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let page = try? decoder.decode(Page.self, from: data) else { return nil }
            return (page, file)
        }
    }

    /// A page taken in: gone from those waiting.
    public static func taken(_ file: URL) { try? FileManager.default.removeItem(at: file) }
}
