import Prism
import SwiftUI

#if os(macOS)
import AppKit
public typealias EditorColor = NSColor
public typealias EditorFont = NSFont
#else
import UIKit
public typealias EditorColor = UIColor
public typealias EditorFont = UIFont
#endif

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
    public var isSerif: Bool

    public init(text: EditorColor, secondary: EditorColor, faint: EditorColor, accent: EditorColor, codeBackground: EditorColor, highlight: EditorColor, size: CGFloat, isSerif: Bool = false) {
        self.text = text
        self.secondary = secondary
        self.faint = faint
        self.accent = accent
        self.codeBackground = codeBackground
        self.highlight = highlight
        self.size = size
        self.isSerif = isSerif
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
        if isSerif, let serif = descriptor.withDesign(.serif) { descriptor = serif }
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

/// What a link in a note leads to: what the editor hands its app to follow.
public enum EditorLink: Hashable {
    case page(String)
    case tag(String)
    case web(String)
}

/// A fenced block of a note: what an app may draw something in place of.
public struct EditorBlock: Hashable {
    /// What follows the opening fence: `query`.
    public var info: String
    /// The lines between the fences.
    public var source: String
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
