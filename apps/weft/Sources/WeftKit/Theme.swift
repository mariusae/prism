import PrismEditor
import SwiftUI

#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
#else
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
#endif

/// Weft's colours: warm paper and ink, light and dark. See docs/design.md.
public enum Ink {
    public static let page = pair(0xF0ECE5, 0x161412)
    public static let paper = pair(0xFAF7F2, 0x1D1B18)
    public static let card = pair(0xFDFCF9, 0x23201D)
    public static let shelf = pair(0xF2EDE5, 0x262320)
    public static let text = pair(0x2B2724, 0xECE6DC)
    public static let secondary = pair(0x6F665D, 0xA79E92)
    public static let faint = pair(0x2B2724, 0xECE6DC, alpha: 0.32)
    public static let rule = pair(0x2B2724, 0xECE6DC, alpha: 0.10)
    public static let hover = pair(0x2B2724, 0xECE6DC, alpha: 0.06)
    public static let accent = pair(0x265CD1, 0x85ADFF)
    public static let marked = pair(0xF5D76E, 0x8A6D1A, alpha: 0.45)

    static func rgb(_ hex: UInt32, _ alpha: CGFloat) -> PlatformColor {
        PlatformColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func pair(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> PlatformColor {
        #if os(macOS)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark, alpha) : rgb(light, alpha)
        }
        #else
        return UIColor { traits in traits.userInterfaceStyle == .dark ? rgb(dark, alpha) : rgb(light, alpha) }
        #endif
    }
}

public extension Color {
    static let inkPage = Color(Ink.page)
    static let inkPaper = Color(Ink.paper)
    static let inkCard = Color(Ink.card)
    static let inkShelf = Color(Ink.shelf)
    static let inkText = Color(Ink.text)
    static let inkSecondary = Color(Ink.secondary)
    static let inkFaint = Color(Ink.faint)
    static let inkRule = Color(Ink.rule)
    static let inkHover = Color(Ink.hover)
    static let inkAccent = Color(Ink.accent)
}

public extension Ink {
    /// The editor, in Weft's colours and at the size cards are set in.
    static var editorTheme: EditorTheme {
        EditorTheme(text: text, secondary: secondary, faint: faint, accent: accent, codeBackground: hover, highlight: marked, size: TextSettings.size, isSerif: TextSettings.isSerif)
    }
}

/// Sizes and spaces. See docs/design.md.
public enum Measures {
    public static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 20
    public static let controlRadius: CGFloat = 6
    #if os(macOS)
    public static let cardRadius: CGFloat = 12
    /// Margin and gutter: a card's words start at their sum.
    public static let margin: CGFloat = 24, gutter: CGFloat = 24
    public static let cardTrailing: CGFloat = 20
    public static let cardGap: CGFloat = 12, foldedGap: CGFloat = 6
    public static let riverSides: CGFloat = 20, riverEnds: CGFloat = 16
    public static let partGap: CGFloat = 8
    #else
    public static let cardRadius: CGFloat = 14
    public static let margin: CGFloat = 0, gutter: CGFloat = 16
    public static let cardTrailing: CGFloat = 16
    public static let cardGap: CGFloat = 22, foldedGap: CGFloat = 11
    public static let riverSides: CGFloat = 10, riverEnds: CGFloat = 12
    public static let partGap: CGFloat = 14
    #endif
    public static let cardMaxWidth: CGFloat = 780
}

/// The size and face cards are set in.
public enum TextSettings {
    #if os(macOS)
    public static let defaultSize: CGFloat = 14, range: ClosedRange<CGFloat> = 11...22
    #else
    public static let defaultSize: CGFloat = 17, range: ClosedRange<CGFloat> = 14...24
    #endif

    public static var size: CGFloat {
        let kept = UserDefaults.standard.double(forKey: "WeftTextSize")
        return kept == 0 ? defaultSize : min(max(CGFloat(kept), range.lowerBound), range.upperBound)
    }

    public static var isSerif: Bool { UserDefaults.standard.string(forKey: "Typeface") == "apple" }
    public static var design: Font.Design { isSerif ? .serif : .default }

    public static func font(_ size: CGFloat, weight: PlatformFont.Weight = .regular, italic: Bool = false) -> PlatformFont {
        var font = PlatformFont.systemFont(ofSize: size, weight: weight)
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

    public static func mono(_ size: CGFloat) -> PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public static var titleSize: CGFloat {
        #if os(macOS)
        return (size * 1.35).rounded()
        #else
        return 22
        #endif
    }
}

/// The symbol a page of a kind is shown by.
public func symbol(forKind kind: String) -> String {
    switch kind {
    case "day", "week": return "calendar"
    default: return "doc.text"
    }
}
