import CoreText
import Prism
import SwiftUI

#if os(macOS)
import AppKit
public typealias EditorColor = NSColor
typealias EditorPlatformView = NSView
public typealias EditorFont = NSFont
public typealias EditorFontDescriptor = NSFontDescriptor
#else
import UIKit
public typealias EditorColor = UIColor
typealias EditorPlatformView = UIView
public typealias EditorFont = UIFont
public typealias EditorFontDescriptor = UIFontDescriptor
#endif

/// The faces text can be set in: font sets, each a face for every part a
/// note is made of — what is written (`text`), titles and headings
/// (`display`), what is said about it (`label`: tags, dates, a property's
/// name) and code (`mono`). Four are the system's own designs; Humanist is
/// a typographer's set, offered where its families are installed.
public enum EditorFace: String, CaseIterable, Hashable, Sendable {
    case sans, serif, rounded, mono, humanist

    /// What a part of a note is, for the face it is set in.
    public enum Role: Sendable {
        case text, display, label, mono
    }

    var design: EditorFontDescriptor.SystemDesign {
        switch self {
        case .sans: return .default
        case .serif, .humanist: return .serif
        case .rounded: return .rounded
        case .mono: return .monospaced
        }
    }

    public var fontDesign: Font.Design {
        switch self {
        case .sans: return .default
        case .serif, .humanist: return .serif
        case .rounded: return .rounded
        case .mono: return .monospaced
        }
    }

    /// Whether the set can be used here: the system's always; Humanist on a
    /// Mac with Chronicle, Ideal Sans and Operator Mono installed.
    public var isAvailable: Bool {
        self != .humanist || Humanist.isInstalled
    }

    /// The sets that can be chosen here.
    public static var available: [EditorFace] { allCases.filter(\.isAvailable) }

    /// A font of the set, for a part of a note, at a size and weight. A set
    /// that cannot be used here sets text as Serif does — its system analog.
    public func font(_ role: Role, size: CGFloat, weight: EditorFont.Weight = .regular, italic: Bool = false) -> EditorFont {
        if self == .humanist, let font = Humanist.font(role, size: size, weight: weight, italic: italic) { return font }
        let face = self == .humanist ? EditorFace.serif : self
        switch role {
        case .mono:
            return italicised(EditorFont.monospacedSystemFont(ofSize: size, weight: weight), italic: italic, size: size)
        case .label:
            // What is said about a note, in the system's own sans: machinery, not thought.
            return italicised(EditorFont.systemFont(ofSize: size, weight: weight), italic: italic, size: size)
        case .text, .display:
            var descriptor = EditorFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            if face != .sans, let designed = descriptor.withDesign(face.design) { descriptor = designed }
            #if os(macOS)
            let font = NSFont(descriptor: descriptor, size: size) ?? EditorFont.systemFont(ofSize: size, weight: weight)
            #else
            let font = UIFont(descriptor: descriptor, size: size)
            #endif
            return italicised(font, italic: italic, size: size)
        }
    }

    private func italicised(_ font: EditorFont, italic: Bool, size: CGFloat) -> EditorFont {
        guard italic else { return font }
        #if os(macOS)
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)), size: size) ?? font
        #else
        return font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)).map { UIFont(descriptor: $0, size: size) } ?? font
        #endif
    }

    /// Whether a font of a set is set heavy — bold, or the weight that stands
    /// for it — where its family does not say so by its traits.
    public static func isHeavy(_ font: EditorFont) -> Bool? {
        Humanist.weight(ofCut: font.fontName).map { $0 >= .medium }
    }
}

/// Chronicle for what is written and its headings, Ideal Sans for what is
/// said about it, Operator Mono for code — Hoefler&Co.'s ScreenSmart cuts.
/// Their weights are not to be asked for by number: a family's own report
/// of them is uneven (Ideal Sans's Semibold says it is Book). Each weight
/// is a cut, named.
public enum Humanist {
    /// A family's cuts, from lightest: each with the weight it is taken for.
    private struct Family {
        let cuts: [(weight: EditorFont.Weight, roman: String, italic: String)]

        /// The cut for a weight: the heaviest no heavier than asked for, or the lightest.
        func cut(for weight: EditorFont.Weight) -> (roman: String, italic: String) {
            let fit = cuts.last { $0.weight <= weight } ?? cuts[0]
            return (fit.roman, fit.italic)
        }
    }

    // Chronicle has no Semibold: a heading's semibold is its Medium; a word set strong, its Bold.
    private static let chronicleDisplay = Family(cuts: [
        (.light, "ChronicleSSm-Light", "ChronicleSSm-LightItalic"),
        (.regular, "ChronicleSSm-Book", "ChronicleSSm-BookItalic"),
        (.medium, "ChronicleSSm-Medium", "ChronicleSSm-MediumItalic"),
        (.bold, "ChronicleSSm-Bold", "ChronicleSSm-BoldItalic"),
    ])
    private static let chronicleText = Family(cuts: [
        (.light, "ChronicleSSm-Light", "ChronicleSSm-LightItalic"),
        (.regular, "ChronicleSSm-Book", "ChronicleSSm-BookItalic"),
        (.medium, "ChronicleSSm-Medium", "ChronicleSSm-MediumItalic"),
        (.semibold, "ChronicleSSm-Bold", "ChronicleSSm-BoldItalic"),
    ])
    private static let idealSans = Family(cuts: [
        (.ultraLight, "IdealSansSSm-XLight", "IdealSansSSm-XLightItalic"),
        (.light, "IdealSansSSm-Light", "IdealSansSSm-LightItalic"),
        (.regular, "IdealSansSSm-Book", "IdealSansSSm-BookItalic"),
        (.medium, "IdealSansSSm-Medium", "IdealSansSSm-MediumItalic"),
        (.semibold, "IdealSansSSm-Semibold", "IdealSansSSm-SemiboldItalic"),
        (.bold, "IdealSansSSm-Bold", "IdealSansSSm-BoldItalic"),
    ])
    private static let operatorMono = Family(cuts: [
        (.light, "OperatorMonoSSm-Light", "OperatorMonoSSm-LightItalic"),
        (.regular, "OperatorMonoSSm-Book", "OperatorMonoSSm-BookItalic"),
        (.medium, "OperatorMonoSSm-Medium", "OperatorMonoSSm-MediumItalic"),
        (.bold, "OperatorMonoSSm-Bold", "OperatorMonoSSm-BoldItalic"),
    ])

    private static func family(_ role: EditorFace.Role) -> Family {
        switch role {
        case .text: return chronicleText
        case .display: return chronicleDisplay
        case .label: return idealSans
        case .mono: return operatorMono
        }
    }

    /// Whether all three families are here: installed on a Mac; on the
    /// phone, brought in the app by its build (`Fonts/`, from the Mac it was
    /// built on — never kept in the repository) and taken up as it starts.
    static let isInstalled: Bool = {
        #if os(macOS)
        return ["ChronicleSSm-Book", "IdealSansSSm-Book", "OperatorMonoSSm-Book"].allSatisfy { NSFont(name: $0, size: 12) != nil }
        #else
        if let folder = Bundle.main.url(forResource: "Fonts", withExtension: nil),
           let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "otf" {
                CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            }
        }
        return ["ChronicleSSm-Book", "IdealSansSSm-Book", "OperatorMonoSSm-Book"].allSatisfy { UIFont(name: $0, size: 12) != nil }
        #endif
    }()

    /// A bundled font's file, for what cannot see the fonts the app has taken
    /// up — a web view, in a process of its own.
    public static func file(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "otf", subdirectory: "Fonts")
    }

    static func font(_ role: EditorFace.Role, size: CGFloat, weight: EditorFont.Weight, italic: Bool) -> EditorFont? {
        guard isInstalled else { return nil }
        let cut = family(role).cut(for: weight)
        return EditorFont(name: italic ? cut.italic : cut.roman, size: size)
    }

    /// The weight a cut of the set is taken for, by its name: what its traits may not say.
    static func weight(ofCut name: String) -> EditorFont.Weight? {
        for family in [chronicleDisplay, idealSans, operatorMono] {
            if let cut = family.cuts.first(where: { $0.roman == name || $0.italic == name }) { return cut.weight }
        }
        return nil
    }
}

/// How an editor looks: the app's colours and the size and face it sets
/// text in. The editor has none of its own.
public struct EditorTheme {
    public var text: EditorColor
    public var secondary: EditorColor
    /// Markup on the lines being written in, bullets, placeholders.
    public var faint: EditorColor
    public var accent: EditorColor
    public var codeBackground: EditorColor
    public var highlight: EditorColor
    public var size: CGFloat
    public var face: EditorFace
    /// What the text stands on: what is put behind a row lifted to be
    /// carried, which would otherwise show the rows under it through.
    /// The system's own, unless the app sets another.
    public var background: EditorColor = EditorTheme.systemBackground

    static var systemBackground: EditorColor {
        #if os(macOS)
        return .textBackgroundColor
        #else
        return .systemBackground
        #endif
    }

    public init(text: EditorColor, secondary: EditorColor, faint: EditorColor, accent: EditorColor, codeBackground: EditorColor, highlight: EditorColor, size: CGFloat, face: EditorFace = .sans) {
        self.text = text
        self.secondary = secondary
        self.faint = faint
        self.accent = accent
        self.codeBackground = codeBackground
        self.highlight = highlight
        self.size = size
        self.face = face
    }

    /// The system's own colours, at a size.
    public static func system(size: CGFloat) -> EditorTheme {
        #if os(macOS)
        return EditorTheme(text: .labelColor, secondary: .secondaryLabelColor, faint: .tertiaryLabelColor, accent: .controlAccentColor, codeBackground: NSColor.labelColor.withAlphaComponent(0.06), highlight: NSColor.systemYellow.withAlphaComponent(0.4), size: size)
        #else
        return EditorTheme(text: .label, secondary: .secondaryLabel, faint: .tertiaryLabel, accent: .tintColor, codeBackground: UIColor.label.withAlphaComponent(0.06), highlight: UIColor.systemYellow.withAlphaComponent(0.4), size: size)
        #endif
    }

    /// What is written: the set's text face.
    public func font(_ size: CGFloat, weight: EditorFont.Weight = .regular, italic: Bool = false) -> EditorFont {
        face.font(.text, size: size, weight: weight, italic: italic)
    }

    /// A heading's face.
    public func display(_ size: CGFloat, weight: EditorFont.Weight = .semibold, italic: Bool = false) -> EditorFont {
        face.font(.display, size: size, weight: weight, italic: italic)
    }

    /// What is said about a note — tags, dates, a property's name — in the set's sans.
    public func label(_ size: CGFloat, weight: EditorFont.Weight = .regular) -> EditorFont {
        face.font(.label, size: size, weight: weight)
    }

    public func mono(_ size: CGFloat) -> EditorFont {
        face.font(.mono, size: size)
    }

    public var body: EditorFont { font(size) }
    /// How far each level of an outline is set in.
    public var step: CGFloat { (size * 1.6).rounded() }
}

/// What stands for a note at the head of its first line, in place of
/// that line's bullet: a to-do's ring, or the note's icon. For a note
/// shown without a title — there, its first line is where it begins.
public struct EditorLead: Equatable {
    /// An SF Symbol's name.
    public var symbol: String
    /// Its colour; the theme's quiet one when it has none.
    public var tint: EditorColor?
    /// Whether it is a filled mark on the accent: a to-do done.
    public var isDone: Bool
    /// A ring in place of the symbol: how far along a checklist is, from nothing to all.
    public var progress: Double?

    public init(symbol: String, tint: EditorColor? = nil, isDone: Bool = false, progress: Double? = nil) {
        self.symbol = symbol
        self.tint = tint
        self.isDone = isDone
        self.progress = progress
    }
}

/// A page offered while a link to one is being typed — after `[[`, or
/// after `@`: what the app found for what was typed so far.
public struct EditorOffer: Hashable {
    /// What the link will say: the page's name.
    public var name: String
    /// What the page is shown as called.
    public var title: String
    /// What else to say of it: where what was typed is found in it.
    public var detail: String?
    /// An SF Symbol's name.
    public var symbol: String

    public init(name: String, title: String, detail: String? = nil, symbol: String) {
        self.name = name
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }
}

/// A row folded in an outline — the rows under it not shown — as an app
/// keeps it: its place among all the note's rows, and its words, by which
/// it is found again after the note changed. The very form a saved river
/// keeps its cards' folded rows in (`RiverCard.foldedRows`).
public typealias EditorFoldedRow = RiverFoldedRow

/// A picture pasted or dropped into a note, for the app to keep: its
/// bytes, and the extension of the file they should be kept in — `png`,
/// `jpg`, `gif`.
public struct EditorPastedPicture: Hashable, Sendable {
    public var data: Data
    public var fileExtension: String

    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }
}

/// What a link in a note leads to: what the editor hands its app to follow.
public enum EditorLink: Hashable {
    case page(String)
    case tag(String)
    case web(String)
}

public extension EnvironmentValues {
    /// Whether the row a block stands in place of — a picture, a link's
    /// card — is chosen, as a thing and not as words: what is drawn in its
    /// place shows so, with a ring.
    @Entry var editorBlockChosen = false
    /// Chooses the row a block stands in place of: what a click on it does,
    /// where the editor chooses such rows by a click (the Mac). `nil`
    /// elsewhere, where a click on it is its own.
    @Entry var chooseEditorBlock: (() -> Void)? = nil
}

/// A part of a note an app may draw something in place of: a fenced
/// block — a query, shown as what it finds — or a line that is only
/// pictures, shown as the picture, or as several to turn through.
public struct EditorBlock: Hashable {
    /// What follows the opening fence: `query`. For a line that is only
    /// pictures, [`EditorBlock.picture`].
    public var info: String
    /// The lines between the fences; for pictures, their line as written:
    /// `![alt](assets/a.png)`, perhaps with its size after it — or
    /// several such, a space between them: see `EditorPicture.all(line:)`.
    public var source: String
    /// Writes other words in the block's place: how a picture, resized,
    /// has its new size written beside it. Only a picture's line is
    /// rewritten so.
    public var rewrite: ((String) -> Void)?
    /// How wide the room it is drawn in is: so that what stands in its
    /// place knows its size at once, and need not measure and move.
    public var room: CGFloat = 0
    /// Tells the editor that what stands in the block's place has changed
    /// its size, and the note is to be laid out around it again: how a
    /// picture being resized moves what is under it as it goes.
    public var resized: (() -> Void)?
    /// A card's row shown as its words again: what its menu's Show as
    /// Link does.
    public var showAsLink: (() -> Void)?

    /// The `info` of a line that is only pictures: one, or several.
    public static let picture = "picture"

    /// The `info` of a row shown as the card of its link (`<!-- card -->`
    /// in the note). Its `source` says what it links to: `web:` and an
    /// address, or `page:` and a page's name.
    public static let card = "card"

    /// What a row's words link to, if they are a link and nothing else —
    /// `[words](address)`, an address alone, `<address>`, `[[A page]]` —
    /// as a card's `source` says it; nil for any other words.
    public static func cardLink(_ words: String) -> String? {
        let words = words.trimmingCharacters(in: .whitespaces)
        func whole(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$"),
                  let match = regex.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)), match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: words) else { return nil }
            return String(words[range])
        }
        if let page = whole(#"\[\[([^\[\]|]+)(?:\|[^\[\]]*)?\]\]"#) { return "page:" + page }
        if let address = whole(#"\[[^\]]*\]\((https?://[^\s)]+)\)"#) ?? whole(#"<?(https?://[^\s>]+)>?"#) { return "web:" + address }
        return nil
    }

    public init(info: String, source: String, rewrite: ((String) -> Void)? = nil) {
        self.info = info
        self.source = source
        self.rewrite = rewrite
    }

    public static func == (a: EditorBlock, b: EditorBlock) -> Bool { a.info == b.info && a.source == b.source }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(info)
        hasher.combine(source)
    }
}

/// A picture as a note writes it: `![alt](address)`, and — when it has
/// been given a size — a comment after it that says so:
/// `<!-- {"width":425,"height":270} -->`.
public struct EditorPicture: Hashable {
    public var alt: String
    /// Where it is: a path in the graph, or an address on the web.
    public var address: String
    public var width: CGFloat?
    public var height: CGFloat?

    public init(alt: String = "", address: String, width: CGFloat? = nil, height: CGFloat? = nil) {
        self.alt = alt
        self.address = address
        self.width = width
        self.height = height
    }

    private static let pattern = try? NSRegularExpression(pattern: #"^\s*!\[([^\]]*)\]\(([^)\s]+)\)\s*(?:<!--\s*(\{[^>]*\})\s*-->)?\s*$"#)

    /// Reads a line that is only a picture; `nil` for any other line.
    public init?(line: String) {
        let whole = NSRange(location: 0, length: (line as NSString).length)
        guard let match = Self.pattern?.firstMatch(in: line, range: whole) else { return nil }
        let part = { (index: Int) -> String? in match.range(at: index).location == NSNotFound ? nil : (line as NSString).substring(with: match.range(at: index)) }
        guard let address = part(2), !address.isEmpty else { return nil }
        alt = part(1) ?? ""
        self.address = address
        if let size = part(3), let read = try? JSONSerialization.jsonObject(with: Data(size.utf8)) as? [String: Any] {
            width = (read["width"] as? NSNumber).map { CGFloat(truncating: $0) }
            height = (read["height"] as? NSNumber).map { CGFloat(truncating: $0) }
        }
    }

    private static let each = try? NSRegularExpression(pattern: #"\s*!\[([^\]]*)\]\(([^)\s]+)\)[ \t]*(?:<!--\s*(\{[^>]*\})\s*-->)?\s*"#)

    /// Reads a line that is only pictures — one, or several with spaces
    /// between them, each perhaps with its size after it — in the order
    /// written; `nil` for any other line. What an app shows several of as
    /// pictures to turn through.
    public static func all(line: String) -> [EditorPicture]? {
        guard let each else { return nil }
        let text = line as NSString
        var found: [EditorPicture] = []
        var at = 0
        // One after another, with nothing between them, to the line's end.
        while at < text.length {
            guard let match = each.firstMatch(in: line, options: .anchored, range: NSRange(location: at, length: text.length - at)), match.range.length > 0,
                  let picture = EditorPicture(line: text.substring(with: match.range))
            else { return nil }
            found.append(picture)
            at = NSMaxRange(match.range)
        }
        return found.isEmpty ? nil : found
    }

    /// The pictures written among a line's words, each with where it is
    /// written: what an app shows under the line they are in.
    public static func among(line: String) -> [(picture: EditorPicture, range: NSRange)] {
        guard let each else { return [] }
        let text = line as NSString
        return each.matches(in: line, range: NSRange(location: 0, length: text.length)).compactMap { match in
            guard match.range.length > 0, let picture = EditorPicture(line: text.substring(with: match.range)) else { return nil }
            // The spaces about it are the words': only what writes the picture is its own.
            let written = text.substring(with: match.range)
            let lead = written.prefix { $0 == " " || $0 == "\t" }.utf16.count
            let trail = written.reversed().prefix { $0 == " " || $0 == "\t" }.count
            return (picture, NSRange(location: match.range.location + lead, length: max(match.range.length - lead - trail, 0)))
        }
    }

    /// The line that writes it.
    public var line: String {
        guard let width else { return "![\(alt)](\(address))" }
        let size = height.map { #"{"width":\#(Int(width.rounded())),"height":\#(Int($0.rounded()))}"# } ?? #"{"width":\#(Int(width.rounded()))}"#
        return "![\(alt)](\(address)) <!-- \(size) -->"
    }
}

/// How long the editor's own work takes on a note, for an app's checks:
/// opening it, reading it for drawing, and dressing it — which is what
/// each keystroke costs. Seconds.
public enum EditorBench {
    public static func measure(source: String, theme: EditorTheme = .system(size: 14)) -> (open: Double, layout: Double, style: Double, replace: Double) {
        let clock = ContinuousClock()
        var editor: NoteEditor!
        let open = clock.measure { editor = NoteEditor.open(source: source) }
        var layout: BodyLayout!
        let read = clock.measure { layout = editor.layout() }
        let storage = NSTextStorage(string: editor.text())
        let style = clock.measure { BodyStyler(theme: theme).style(storage, layout: layout, revealed: []) }
        let end = UInt32((editor.text() as NSString).length)
        let replace = clock.measure { _ = editor.replace(start: end, end: end, replacement: "x") }
        let seconds = { (duration: Duration) in Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
        return (seconds(open), seconds(read), seconds(style), seconds(replace))
    }
}
