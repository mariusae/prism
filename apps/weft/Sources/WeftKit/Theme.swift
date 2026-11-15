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
    // Quiet, but never hard to see: a source's domain, a fold's handle.
    public static let faint = pair(0x2B2724, 0xECE6DC, alpha: 0.40)
    public static let rule = pair(0x2B2724, 0xECE6DC, alpha: 0.10)
    public static let hover = pair(0x2B2724, 0xECE6DC, alpha: 0.06)
    // A muted cobalt: a link's strong affordance, without a browser's blue in a warm page.
    public static let accent = pair(0x315DBB, 0x93ACDD)
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
    @MainActor static var editorTheme: EditorTheme {
        var theme = EditorTheme(text: text, secondary: secondary, faint: faint, accent: accent, codeBackground: hover, highlight: marked, size: TextSettings.size, face: TextSettings.face)
        // What a row lifted out of its outline is drawn on: the card's own colour.
        theme.background = card
        return theme
    }
}

/// Sizes and spaces. See docs/design.md.
public enum Measures {
    public static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 20
    public static let controlRadius: CGFloat = 6
    #if os(macOS)
    public static let cardRadius: CGFloat = 10
    /// Margin and gutter: a card's words start at their sum.
    public static let margin: CGFloat = 24, gutter: CGFloat = 24
    public static let cardTrailing: CGFloat = 20
    public static let cardGap: CGFloat = 12, foldedGap: CGFloat = 6
    /// The river's sides: room for the ticks at its right edge — widened
    /// as they are under the pointer — and air between them and the cards,
    /// however narrow the window; the same on the left, so the cards sit
    /// in the middle.
    public static let riverSides: CGFloat = 46, riverEnds: CGFloat = 16
    public static let partGap: CGFloat = 8
    #else
    public static let cardRadius: CGFloat = 11
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
    public static let defaultSize: CGFloat = 15, range: ClosedRange<CGFloat> = 11...22
    #else
    public static let defaultSize: CGFloat = 17, range: ClosedRange<CGFloat> = 14...24
    #endif

    /// What is chosen, kept in the app's defaults — under the names the
    /// app has always kept them by — and watched: a view that reads the
    /// size or the face is drawn again when either is changed.
    @MainActor
    @Observable
    final class Chosen {
        static let shared = Chosen()
        var size: CGFloat {
            didSet { Self.kept.set(Double(size), forKey: "WeftTextSize") }
        }
        var face: EditorFace {
            didSet { Self.kept.set(TextSettings.name(of: face), forKey: "Typeface") }
        }

        /// Where the choice is kept. On the phone, in the app group: Weft and
        /// Weft Reader read the same — the Reader follows what is chosen in Weft.
        private static let kept: UserDefaults = {
            #if os(iOS)
            guard let group = UserDefaults(suiteName: Setup.appGroup) else { return .standard }
            // Chosen before it was shared: carried over, once.
            for key in ["WeftTextSize", "Typeface"] where group.object(forKey: key) == nil {
                if let mine = UserDefaults.standard.object(forKey: key) { group.set(mine, forKey: key) }
            }
            return group
            #else
            return .standard
            #endif
        }()

        private init() {
            (size, face) = Self.read()
            #if os(iOS)
            // Changed in the other app while this one was away: taken up on coming back.
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let (size, face) = Chosen.read()
                    if size != Chosen.shared.size { Chosen.shared.size = size }
                    if face != Chosen.shared.face { Chosen.shared.face = face }
                }
            }
            #endif
        }

        private static func read() -> (CGFloat, EditorFace) {
            let size = kept.double(forKey: "WeftTextSize")
            let face: EditorFace = switch kept.string(forKey: "Typeface") {
            case "apple", "serif": .serif
            case "rounded": .rounded
            case "mono": .mono
            // Chosen where its fonts are, and read where they are not: its system analog.
            case "humanist": EditorFace.humanist.isAvailable ? .humanist : .serif
            default: .sans
            }
            return (size == 0 ? TextSettings.defaultSize : min(max(CGFloat(size), TextSettings.range.lowerBound), TextSettings.range.upperBound), face)
        }
    }

    /// A face's name in the defaults: the serif face has always been "apple".
    static func name(of face: EditorFace) -> String { face == .serif ? "apple" : face.rawValue }

    @MainActor public static var size: CGFloat {
        get { Chosen.shared.size }
        set { Chosen.shared.size = min(max(newValue.rounded(), range.lowerBound), range.upperBound) }
    }

    @MainActor public static var face: EditorFace {
        get { Chosen.shared.face }
        set { Chosen.shared.face = newValue }
    }

    @MainActor public static var isSerif: Bool { face == .serif || face == .humanist }

    /// What a set is called, where it is chosen.
    public static func name(for face: EditorFace) -> String {
        switch face {
        case .sans: "Sans"
        case .serif: "Serif"
        case .rounded: "Rounded"
        case .mono: "Mono"
        case .humanist: "Humanist"
        }
    }

    /// A font of the chosen set, for SwiftUI: what is written, by default; a
    /// title in its display face; what is said about a note in its label face.
    @MainActor public static func font(_ size: CGFloat, weight: Font.Weight = .regular, role: EditorFace.Role = .text) -> Font {
        let platform: PlatformFont.Weight = switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
        return Font(face.font(role, size: size, weight: platform))
    }
    @MainActor public static var design: Font.Design { face.fontDesign }

    @MainActor public static var titleSize: CGFloat {
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
