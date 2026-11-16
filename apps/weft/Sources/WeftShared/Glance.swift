import Foundation

/// What the widgets show, and what is done on them, passed between the
/// app and its widget extension through the app group.
///
/// The extension never opens the graph — it has too little memory for
/// the engine, and two writers to one repository is one too many. The
/// app writes down what the widgets show (`Snapshot`) whenever it comes
/// and goes, or a push wakes it; a to-do ticked on a widget is left as a
/// `Tick`, marked done in the snapshot at once, and checked off in its
/// note the next time the app runs.
public enum Glance {
    /// What a widget is told to reload by: the widgets' kinds.
    public enum Kind {
        public static let capture = "Capture"
        public static let today = "Today"
        public static let toDos = "ToDos"
        public static let river = "River"
    }

    /// A row of a note's outline, as words.
    public struct Row: Codable, Hashable, Sendable {
        /// Its place in the note's outline, to go to it.
        public var index: UInt32
        public var depth: Int
        public var words: String
        public var heading: Bool
        /// A to-do's: done or not. Not a to-do: nil.
        public var done: Bool?

        public init(index: UInt32, depth: Int, words: String, heading: Bool, done: Bool?) {
            self.index = index
            self.depth = depth
            self.words = words
            self.heading = heading
            self.done = done
        }
    }

    /// A note, as a widget shows it: its name, its emblem, its first rows.
    public struct Note: Codable, Hashable, Sendable {
        public var path: String
        public var title: String
        /// An SF Symbol's name, and one of the emblem colours' names.
        public var symbol: String?
        public var color: String?
        public var rows: [Row]

        public init(path: String, title: String, symbol: String?, color: String?, rows: [Row]) {
            self.path = path
            self.title = title
            self.symbol = symbol
            self.color = color
            self.rows = rows
        }
    }

    /// An open to-do, from anywhere in the graph.
    public struct ToDo: Codable, Hashable, Identifiable, Sendable {
        public var id: String { "\(path)#\(row.map(String.init).joined(separator: "."))#\(text.hashValueStable)" }
        public var path: String
        /// Where it is in its note's tree, and its text as written: how the engine finds it again.
        public var row: [UInt32]
        public var text: String
        /// Its words, as read.
        public var words: String
        /// The note it is in, by name.
        public var note: String
        /// Ticked on a widget, and not yet checked off in its note.
        public var done: Bool

        public init(path: String, row: [UInt32], text: String, words: String, note: String, done: Bool = false) {
            self.path = path
            self.row = row
            self.text = text
            self.words = words
            self.note = note
            self.done = done
        }
    }

    /// A river, as a widget shows it: its name and its cards.
    public struct River: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var symbol: String?
        public var color: String?
        public var cards: [Note]

        public init(id: String, title: String, symbol: String?, color: String?, cards: [Note]) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.color = color
            self.cards = cards
        }
    }

    /// Everything the widgets show, as the app last saw it.
    public struct Snapshot: Codable, Hashable, Sendable {
        public var written: Date
        /// The day today's note is for, and the note, once something is written in it.
        public var day: Date
        public var today: Note?
        public var toDos: [ToDo]
        /// How many to-dos are open in all: more than are listed, maybe.
        public var toDosOpen: Int
        public var rivers: [River]

        public init(written: Date = Date(), day: Date, today: Note?, toDos: [ToDo], toDosOpen: Int, rivers: [River]) {
            self.written = written
            self.day = day
            self.today = today
            self.toDos = toDos
            self.toDosOpen = toDosOpen
            self.rivers = rivers
        }

        /// None yet: the app has not been opened since the widgets were put up.
        public static let empty = Snapshot(written: .distantPast, day: .distantPast, today: nil, toDos: [], toDosOpen: 0, rivers: [])
    }

    /// A to-do ticked on a widget, waiting for the app.
    public struct Tick: Codable, Hashable, Sendable {
        public var path: String
        public var row: [UInt32]
        public var text: String
        public var done: Bool
    }

    // MARK: Where they are kept

    private static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedPages.group)?.appendingPathComponent("Glance", isDirectory: true)
    }

    private static var snapshotFile: URL? { folder?.appendingPathComponent("snapshot.json") }
    private static var ticksFolder: URL? { folder?.appendingPathComponent("Ticks", isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// What the widgets show; `empty` before the app has written it.
    public static func read() -> Snapshot {
        guard let file = snapshotFile, let data = try? Data(contentsOf: file), let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return .empty }
        return snapshot
    }

    /// Writes what the widgets show. Says whether it is other than it was —
    /// and so whether the widgets need drawing again.
    @discardableResult
    public static func write(_ snapshot: Snapshot) -> Bool {
        guard let folder, let file = snapshotFile else { return false }
        var unstamped = snapshot
        unstamped.written = .distantPast
        var was = read()
        was.written = .distantPast
        guard was != unstamped else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(snapshot) else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// A to-do ticked on a widget: shown done at once, and left for the app to check off in its note.
    public static func tick(_ id: String) {
        var snapshot = read()
        guard let at = snapshot.toDos.firstIndex(where: { $0.id == id }), let ticks = ticksFolder, let file = snapshotFile else { return }
        let done = !snapshot.toDos[at].done
        snapshot.toDos[at].done = done
        snapshot.toDosOpen += done ? -1 : 1
        let toDo = snapshot.toDos[at]
        try? FileManager.default.createDirectory(at: ticks, withIntermediateDirectories: true)
        // Ticked twice — on and off again — the second wins: one file for each to-do.
        let name = String(toDo.id.hashValueStable, radix: 16) + ".json"
        if let data = try? encoder.encode(Tick(path: toDo.path, row: toDo.row, text: toDo.text, done: done)) {
            try? data.write(to: ticks.appendingPathComponent(name), options: .atomic)
        }
        if let data = try? encoder.encode(snapshot) { try? data.write(to: file, options: .atomic) }
    }

    /// The ticks waiting, each with the file it is in.
    public static func ticks() -> [(tick: Tick, file: URL)] {
        guard let ticks = ticksFolder, let files = try? FileManager.default.contentsOfDirectory(at: ticks, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let dated = files.filter { $0.pathExtension == "json" }.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        return dated.sorted { $0.1 < $1.1 }.compactMap { file, _ in
            guard let data = try? Data(contentsOf: file), let tick = try? decoder.decode(Tick.self, from: data) else { return nil }
            return (tick, file)
        }
    }

    /// A tick checked off in its note: gone from those waiting.
    public static func taken(_ file: URL) { try? FileManager.default.removeItem(at: file) }

    // MARK: Links into the app

    /// The links a widget opens the app with: `weft://…`.
    public enum Link {
        public static let new = URL(string: "weft://new")!
        public static let dictate = URL(string: "weft://dictate")!
        public static let today = URL(string: "weft://today")!
        public static let toDos = URL(string: "weft://todos")!

        /// A note, and — given — a row of it gone to.
        public static func note(_ path: String, row: UInt32? = nil) -> URL {
            var parts = URLComponents()
            parts.scheme = "weft"
            parts.host = "note"
            parts.queryItems = [URLQueryItem(name: "path", value: path)] + (row.map { [URLQueryItem(name: "row", value: String($0))] } ?? [])
            return parts.url ?? today
        }

        /// One of the rivers open in the app, and — given — a card of it.
        public static func river(id: String, card: String? = nil) -> URL {
            var parts = URLComponents()
            parts.scheme = "weft"
            parts.host = "open-river"
            parts.queryItems = [URLQueryItem(name: "id", value: id)] + (card.map { [URLQueryItem(name: "card", value: $0)] } ?? [])
            return parts.url ?? today
        }
    }
}

extension String {
    /// A hash that is the same from one launch to the next — Swift's own is not.
    var hashValueStable: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
