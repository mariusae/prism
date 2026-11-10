import SwiftUI

/// Choosing what stands for a page or a river: a colour, and an icon —
/// or none, and the letter of its name.
public struct EmblemPicker: View {
    let title: String
    @Binding var icon: String?
    @Binding var color: String?
    var kindSymbol: String?
    @State private var search = ""

    public init(title: String, icon: Binding<String?>, color: Binding<String?>, kindSymbol: String? = nil) {
        self.title = title
        _icon = icon
        _color = color
        self.kindSymbol = kindSymbol
    }

    private var chosenColor: EmblemColor? { EmblemColor(named: color) }

    private var symbols: [String] {
        let typed = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return Self.symbols.map(\.name) }
        let words = typed.split(separator: " ")
        return Self.symbols.filter { symbol in words.allSatisfy { symbol.name.contains($0) || symbol.words.contains($0) } }.map(\.name)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Colours: none, then each.
            // Spread over the width there is, never wider than it: thirteen
            // at a fixed gap would not fit, and would push everything aside.
            HStack(spacing: 0) {
                swatch(nil).frame(maxWidth: .infinity)
                ForEach(EmblemColor.allCases, id: \.self) { swatch($0).frame(maxWidth: .infinity) }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find an icon", text: $search).textFieldStyle(.plain)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 8), spacing: 6) {
                    // No icon: the letter of its name.
                    if search.isEmpty {
                        cell(isChosen: (icon ?? "").isEmpty) { icon = nil } label: {
                            EmblemView(Emblem(title: title, color: color, kindSymbol: kindSymbol), size: 24, style: .plain)
                        }
                        .help("No icon: the letter of its name")
                    }
                    ForEach(symbols, id: \.self) { name in
                        cell(isChosen: icon == name) { icon = name } label: {
                            Image(systemName: name).font(.system(size: 15, weight: .medium)).foregroundStyle(chosenColor?.color ?? .primary)
                        }
                        .help(name)
                    }
                }
                .padding(2)
            }
            .frame(height: 220)
        }
        .padding(14)
        .frame(width: 8 * 32 + 7 * 6 + 4 + 28)
    }

    private func swatch(_ value: EmblemColor?) -> some View {
        let isChosen = chosenColor == value
        return Button { color = value?.rawValue } label: {
            ZStack {
                if let value {
                    Circle().fill(value.color)
                } else {
                    Circle().strokeBorder(.secondary, lineWidth: 1.5)
                    Rectangle().fill(.secondary).frame(width: 1.5, height: 14).rotationEffect(.degrees(45))
                }
            }
            .frame(width: 16, height: 16)
            .padding(2.5)
            .overlay(Circle().strokeBorder(isChosen ? Color.primary.opacity(0.7) : .clear, lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(value?.rawValue.capitalized ?? "No colour")
    }

    private func cell<Label: View>(isChosen: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isChosen ? (chosenColor?.color ?? Color.accentColor).opacity(0.2) : Color.primary.opacity(0.04)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The icons offered: SF Symbols that say something about a note,
    /// each with the words it is found by.
    static let symbols: [(name: String, words: String)] = [
        ("star", "favourite favorite"), ("heart", "love like"), ("bookmark", "saved"), ("flag", "mark"), ("pin", "keep"), ("bolt", "fast energy"),
        ("flame", "fire hot"), ("sparkles", "new magic"), ("lightbulb", "idea"), ("target", "goal aim"), ("checkmark.seal", "done verified"), ("trophy", "win prize"),
        ("book", "read"), ("book.closed", "wiki read"), ("books.vertical", "library"), ("newspaper", "news article"), ("doc.text", "page note"), ("note.text", "note"),
        ("pencil", "write edit"), ("highlighter", "mark"), ("text.quote", "quote"), ("list.bullet", "list outline"), ("checklist", "tasks todo"), ("tray", "inbox"),
        ("folder", "files"), ("archivebox", "archive"), ("paperclip", "attach"), ("link", "url web"), ("tag", "label"), ("number", "hash tag"),
        ("calendar", "day date"), ("clock", "time recent"), ("hourglass", "wait time"), ("alarm", "wake time"), ("timer", "time"), ("bell", "alert remind"),
        ("person", "people contact"), ("person.2", "people team"), ("person.3", "people group team"), ("figure.walk", "walk health"), ("figure.run", "run exercise"), ("hand.raised", "stop"),
        ("house", "home"), ("building.2", "office work company"), ("briefcase", "work job"), ("graduationcap", "school study learn"), ("cart", "shop buy"), ("creditcard", "money pay"),
        ("dollarsign.circle", "money finance"), ("chart.bar", "data stats"), ("chart.line.uptrend.xyaxis", "growth data"), ("chart.pie", "data share"), ("function", "math"), ("sum", "math total"),
        ("hammer", "build tool"), ("wrench.and.screwdriver", "fix tools"), ("gearshape", "settings system"), ("cpu", "computer chip"), ("server.rack", "infrastructure"), ("terminal", "code shell"),
        ("chevron.left.forwardslash.chevron.right", "code programming"), ("curlybraces", "code"), ("ladybug", "bug"), ("shippingbox", "package release"), ("cube", "object model"), ("square.stack.3d.up", "layers rivers"),
        ("network", "graph connections"), ("point.3.connected.trianglepath.dotted", "graph related"), ("antenna.radiowaves.left.and.right", "signal radio"), ("wifi", "network"), ("cloud", "weather sync"), ("icloud", "sync"),
        ("globe", "world web"), ("map", "place travel"), ("mappin", "place location"), ("airplane", "travel flight"), ("car", "drive travel"), ("bicycle", "ride"),
        ("tram", "train transit"), ("sailboat", "boat sea"), ("mountain.2", "outdoors hike"), ("tree", "nature"), ("leaf", "nature plant"), ("sun.max", "weather day"),
        ("moon", "night sleep"), ("cloud.rain", "weather"), ("snowflake", "cold winter"), ("drop", "water"), ("pawprint", "animal pet"), ("fish", "animal"),
        ("fork.knife", "food eat"), ("cup.and.saucer", "coffee tea"), ("wineglass", "drink"), ("birthday.cake", "birthday party"), ("gift", "present"), ("party.popper", "celebrate"),
        ("music.note", "song audio"), ("headphones", "listen audio"), ("mic", "voice record"), ("film", "movie video"), ("tv", "watch show"), ("gamecontroller", "game play"),
        ("camera", "photo"), ("photo", "picture image"), ("paintbrush", "art design"), ("paintpalette", "art colour"), ("scissors", "cut"), ("ruler", "measure design"),
        ("envelope", "mail email"), ("message", "chat talk"), ("bubble.left.and.bubble.right", "conversation meeting"), ("phone", "call"), ("video", "call meeting"), ("megaphone", "announce"),
        ("cross.case", "health medical"), ("heart.text.square", "health"), ("pills", "medicine"), ("bed.double", "sleep"), ("dumbbell", "exercise gym"), ("brain.head.profile", "mind think"),
        ("atom", "science physics"), ("testtube.2", "science lab"), ("leaf.arrow.circlepath", "recycle"), ("lock", "private secure"), ("key", "access"), ("shield", "safe security"),
        ("questionmark.circle", "question"), ("exclamationmark.triangle", "warning"), ("info.circle", "information"), ("eyeglasses", "reading"), ("binoculars", "watch search"), ("magnifyingglass", "search find"),
    ]
}
