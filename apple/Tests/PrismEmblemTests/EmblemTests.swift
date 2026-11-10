import Testing
@testable import PrismEmblem

@Test func aLetterStandsForAName() {
    #expect(Emblem.letter(for: "Project Atlas") == "P")
    #expect(Emblem.letter(for: "  ada lovelace") == "A")
    #expect(Emblem.letter(for: "The Analytical Engine") == "A")
    #expect(Emblem.letter(for: "A") == "A")
    #expect(Emblem.letter(for: "The") == "T")
    #expect(Emblem.letter(for: "#planning") == "P")
    #expect(Emblem.letter(for: "“Quoted” title") == "Q")
    #expect(Emblem.letter(for: "2026 goals") == "2")
    #expect(Emblem.letter(for: "🚀 Launch") == "🚀")
    #expect(Emblem.letter(for: "élan") == "É")
    #expect(Emblem.letter(for: "日本語") == "日")
    #expect(Emblem.letter(for: "") == "·")
    #expect(Emblem.letter(for: "—") == "·")
}

@Test func anIconComesBeforeAKindAndAKindBeforeALetter() {
    #expect(Emblem(title: "Atlas").glyph == .letter("A"))
    #expect(Emblem(title: "2026-10-31", kindSymbol: "calendar").glyph == .symbol("calendar"))
    #expect(Emblem(title: "2026-10-31", icon: "star", kindSymbol: "calendar").glyph == .symbol("star"))
    #expect(Emblem(title: "Atlas", icon: "  ").glyph == .letter("A"))
}

@Test func aNoteIsNotGivenALetter() {
    #expect(Emblem(title: "Atlas", letter: false).glyph == .none)
    #expect(!Emblem(title: "Atlas", letter: false).isShown)
    // Given a colour alone, it is a dot of it; given an icon or a kind, that.
    #expect(Emblem(title: "Atlas", color: "teal", letter: false).isShown)
    #expect(Emblem(title: "Atlas", icon: "map", letter: false).symbol == "map")
    #expect(Emblem(title: "2026-10-31", kindSymbol: "calendar", letter: false).symbol == "calendar")
}

@Test func anEmojiIsSaidOnce() {
    #expect(Emblem(title: "🚀 Launch").caption("🚀 Launch") == "Launch")
    #expect(Emblem(title: "🚀").caption("🚀") == "🚀")
    #expect(Emblem(title: "Atlas").caption("Atlas") == "Atlas")
    #expect(Emblem(title: "2026 goals").caption("2026 goals") == "2026 goals")
    #expect(Emblem(title: "🚀 Launch", icon: "star").caption("🚀 Launch") == "🚀 Launch")
}

@Test func aColourIsKnownByItsName() {
    #expect(Emblem(title: "Atlas", color: "teal").color == .teal)
    #expect(Emblem(title: "Atlas", color: " Teal ").color == .teal)
    #expect(Emblem(title: "Atlas", color: "chartreuse").color == nil)
    #expect(Emblem(title: "Atlas").color == nil)
    // A letter keeps its colour; so does an icon.
    #expect(Emblem(title: "Atlas", icon: "star", color: "red") == Emblem(symbol: "star", color: .red))
}
