import SwiftUI

/// The colours a page or a river can be given, by the names they are
/// written with in a note's frontmatter: `color: teal`.
public enum EmblemColor: String, CaseIterable, Hashable, Sendable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown

    public var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .cyan: return .cyan
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .brown: return .brown
        }
    }

    /// The colour a name written in a file means, if it is one of these.
    public init?(named name: String?) {
        guard let name, let color = EmblemColor(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
        self = color
    }
}

/// What stands for a page or a river wherever it is shown small — a row
/// of a list, a tab, the corner of a card.
///
/// One rule, the same in every app:
///
/// 1. If it was given an icon, that icon.
/// 2. Otherwise the symbol of its kind, if its kind has one: a day is a
///    calendar.
/// 3. Otherwise — for a river — a letter of its name
///    ([`Emblem.letter(for:)`]). A note is not given a letter: a note
///    with no icon has none, and where it is shown its words have the
///    room. One given only a colour is a dot of that colour.
/// 4. In its colour if it was given one; else in whatever quiet colour
///    the place it is shown in uses.
///
/// What a page was given is in its frontmatter — `icon:` an SF Symbol's
/// name, `color:` one of [`EmblemColor`]'s — and a river's likewise.
public struct Emblem: Hashable, Sendable {
    public enum Glyph: Hashable, Sendable {
        /// An SF Symbol, by name.
        case symbol(String)
        /// A letter, a digit or an emoji of the name.
        case letter(String)
        /// Nothing: a note that was given no icon.
        case none
    }

    public var glyph: Glyph
    public var color: EmblemColor?

    /// What stands for something called `title`.
    /// - Parameters:
    ///   - icon: the icon it was given, an SF Symbol's name.
    ///   - color: the colour it was given, by name.
    ///   - kindSymbol: the symbol of its kind, when its kind is more
    ///     telling than a letter of its name: `calendar` for a day.
    ///   - letter: whether a letter of its name stands for it when
    ///     nothing else does: so for a river, not for a note.
    public init(title: String, icon: String? = nil, color: String? = nil, kindSymbol: String? = nil, letter: Bool = true) {
        let icon = icon?.trimmingCharacters(in: .whitespaces)
        if let icon, !icon.isEmpty {
            glyph = .symbol(icon)
        } else if let kindSymbol {
            glyph = .symbol(kindSymbol)
        } else if letter {
            glyph = .letter(Emblem.letter(for: title))
        } else {
            glyph = .none
        }
        self.color = EmblemColor(named: color)
    }

    /// A symbol standing for something that is no page: a command, a tag.
    public init(symbol: String, color: EmblemColor? = nil) {
        glyph = .symbol(symbol)
        self.color = color
    }

    /// Whether there is anything to draw: an icon, a letter, or — for a
    /// note given only a colour — a dot of it.
    public var isShown: Bool { glyph != .none || color != nil }

    /// The icon, when what stands for it is one.
    public var symbol: String? {
        if case .symbol(let name) = glyph { return name }
        return nil
    }

    /// A name as it is written beside this emblem: without the emoji it
    /// opens with, when that emoji is the emblem — said once, not twice.
    public func caption(_ title: String) -> String {
        guard case .letter(let letter) = glyph, title.hasPrefix(letter), !(letter.first?.isLetter ?? true), !(letter.first?.isNumber ?? true) else { return title }
        let rest = title.dropFirst(letter.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? title : rest
    }

    /// The letter that stands for a name: its first letter or digit, in
    /// upper case — or, for a name that opens with an emoji, the emoji.
    /// What comes before it — punctuation, a `#`, quotes — is passed over,
    /// and so are the words that say nothing: "The Engine" is E.
    public static func letter(for title: String) -> String {
        let words = title.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let skipped: Set<String> = ["the", "a", "an"]
        let telling = words.count > 1 && skipped.contains(words[0].lowercased()) ? Array(words.dropFirst()) : words
        for character in telling.joined(separator: " ") {
            if character.isLetter || character.isNumber { return String(character).uppercased() }
            if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }) { return String(character) }
        }
        return "·"
    }
}

/// How an emblem is drawn.
public enum EmblemStyle: Sendable {
    /// The glyph alone: beside a title.
    case plain
    /// The glyph on a tile of its colour: in a list, on a tab.
    case tile
}

/// An emblem, drawn.
public struct EmblemView: View {
    let emblem: Emblem
    let size: CGFloat
    let style: EmblemStyle
    /// The colour of an emblem that was given none.
    let quiet: Color

    public init(_ emblem: Emblem, size: CGFloat = 20, style: EmblemStyle = .tile, quiet: Color = .secondary) {
        self.emblem = emblem
        self.size = size
        self.style = style
        self.quiet = quiet
    }

    private var tint: Color { emblem.color?.color ?? quiet }

    public var body: some View {
        Group {
            switch emblem.glyph {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: size * (style == .tile ? 0.56 : 0.72), weight: .semibold))
                    .symbolRenderingMode(.monochrome)
            case .letter(let letter):
                Text(letter)
                    .font(.system(size: size * (style == .tile ? 0.6 : 0.74), weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            case .none:
                // Given only a colour: a dot of it. Given nothing: nothing.
                if emblem.color != nil { Circle().frame(width: size * 0.42, height: size * 0.42) }
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .background {
            if style == .tile, emblem.glyph != .none {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(tint.opacity(emblem.color == nil ? 0.12 : 0.18))
            }
        }
        .accessibilityHidden(true)
    }
}
