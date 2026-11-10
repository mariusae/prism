import Prism
import SwiftUI

#if os(macOS)
import AppKit
public typealias EditorColor = NSColor
public typealias EditorFont = NSFont
public typealias EditorFontDescriptor = NSFontDescriptor
#else
import UIKit
public typealias EditorColor = UIColor
public typealias EditorFont = UIFont
public typealias EditorFontDescriptor = UIFontDescriptor
#endif

/// The faces text can be set in: the system's own, in its four designs.
public enum EditorFace: String, CaseIterable, Hashable, Sendable {
    case sans, serif, rounded, mono

    var design: EditorFontDescriptor.SystemDesign {
        switch self {
        case .sans: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .mono: return .monospaced
        }
    }

    public var fontDesign: Font.Design {
        switch self {
        case .sans: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .mono: return .monospaced
        }
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

    public func font(_ size: CGFloat, weight: EditorFont.Weight = .regular, italic: Bool = false) -> EditorFont {
        var font = EditorFont.systemFont(ofSize: size, weight: weight)
        var descriptor = font.fontDescriptor
        if face != .sans, let designed = descriptor.withDesign(face.design) { descriptor = designed }
        if italic {
            #if os(macOS)
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic))
            #else
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) ?? descriptor
            #endif
        }
        #if os(macOS)
        font = NSFont(descriptor: descriptor, size: size) ?? font
        #else
        font = UIFont(descriptor: descriptor, size: size)
        #endif
        return font
    }

    public func mono(_ size: CGFloat) -> EditorFont {
        EditorFont.monospacedSystemFont(ofSize: size, weight: .regular)
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

    public init(symbol: String, tint: EditorColor? = nil, isDone: Bool = false) {
        self.symbol = symbol
        self.tint = tint
        self.isDone = isDone
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

/// What a link in a note leads to: what the editor hands its app to follow.
public enum EditorLink: Hashable {
    case page(String)
    case tag(String)
    case web(String)
}

/// A part of a note an app may draw something in place of: a fenced
/// block — a query, shown as what it finds — or a line that is only a
/// picture, shown as the picture.
public struct EditorBlock: Hashable {
    /// What follows the opening fence: `query`. For a line that is only
    /// a picture, [`EditorBlock.picture`].
    public var info: String
    /// The lines between the fences; for a picture, its line as written:
    /// `![alt](assets/a.png)`, perhaps with its size after it.
    public var source: String
    /// Writes other words in the block's place: how a picture, resized,
    /// has its new size written beside it. Only a picture's line is
    /// rewritten so.
    public var rewrite: ((String) -> Void)?
    /// How wide the room it is drawn in is: so that what stands in its
    /// place knows its size at once, and need not measure and move.
    public var room: CGFloat = 0

    /// The `info` of a line that is only a picture.
    public static let picture = "picture"

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
    public static func measure(source: String, mode: EditorMode, theme: EditorTheme = .system(size: 14)) -> (open: Double, layout: Double, style: Double, replace: Double) {
        let clock = ContinuousClock()
        var editor: NoteEditor!
        let open = clock.measure { editor = NoteEditor.open(source: source, mode: mode) }
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
