import Prism
import SwiftUI

/// A note two devices changed in the same places, settled a place at a
/// time. In the card, in place of its writing: each place shown as what
/// this device wrote and what the other did, the lines only one of them
/// has marked, and a line or two of what is around it for where it is.
/// Each is kept this device's way, the other's, or both, one after the
/// other; or every place one way at once. Or the note is written in as
/// it is, markers and all, to put it right by hand.
struct ConflictResolver: View {
    let draft: PageDraft
    /// Shown as text, to be written in by hand.
    @Binding var asText: Bool
    /// Whether there is room for each place's two sides side by side: the width the card gives, and nothing in it.
    @State private var wide = false

    var body: some View {
        let parts = draft.conflictParts
        let count = parts.filter(\.isConflict).count
        VStack(alignment: .leading, spacing: 14) {
            header(count)
            if !asText {
                ForEach(Array(Self.places(parts).enumerated()), id: \.offset) { _, place in
                    switch place {
                    case .context(let lines): context(lines)
                    case .gap: Text("⋯").font(.system(size: 13)).foregroundStyle(Color.inkFaint).padding(.leading, 4)
                    case .conflict(let index, let ours, let theirs): block(index, of: count, ours: ours, theirs: theirs)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .onGeometryChange(for: Bool.self) { $0.size.width >= 620 } action: { if wide != $0 { wide = $0 } }
    }

    private func header(_ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 1 ? "Changed on two devices at once, in one place" : "Changed on two devices at once, in \(count) places")
                    .font(.system(size: 13, weight: .semibold))
                Text(asText ? "Written in as it is: the markers show where each device's words start and end." : "Choose what to keep in each.")
                    .font(.system(size: 12)).foregroundStyle(Color.inkSecondary)
            }
            Spacer(minLength: 8)
            Menu("Keep All") {
                Button("This Device\u{2019}s") { withAnimation(.snappy(duration: 0.2)) { draft.resolve(keeping: .ours) } }
                Button("The Other Device\u{2019}s") { withAnimation(.snappy(duration: 0.2)) { draft.resolve(keeping: .theirs) } }
                Button("Both") { withAnimation(.snappy(duration: 0.2)) { draft.resolve(keeping: .both) } }
            }
            .fixedSize()
            Button(asText ? "Choose" : "Edit as Text") { withAnimation(.snappy(duration: 0.2)) { asText.toggle() } }
        }
        .controlSize(.small)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
    }

    /// A line or two the devices agree on: where a place is.
    private func context(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in ConflictLine(raw: line, mark: nil) }
        }
        .opacity(0.5)
    }

    /// One place: each device's lines, and what is kept.
    private func block(_ index: Int, of count: Int, ours: String, theirs: String) -> some View {
        let mine = Self.lines(ours)
        let other = Self.lines(theirs)
        // The lines only one side has: the rest both do.
        let difference = other.map(Self.key).difference(from: mine.map(Self.key))
        let onlyMine = Set(difference.removals.map(Self.offset))
        let onlyOther = Set(difference.insertions.map(Self.offset))
        return VStack(alignment: .leading, spacing: 8) {
            // Side by side where there is room for both; else one over the other.
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 10)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            layout {
                side("This Device", mine, only: onlyMine, tint: .orange) { keep(index, .ours) }
                side("Other Device", other, only: onlyOther, tint: .blue) { keep(index, .theirs) }
            }
            HStack {
                if count > 1 { Text("\(index + 1) of \(count)").font(.system(size: 11)).foregroundStyle(Color.inkFaint) }
                Spacer()
                Button("Keep Both") { keep(index, .both) }.help("This device's lines, then the other's")
            }
            .controlSize(.small)
        }
    }

    private func side(_ name: String, _ lines: [String], only: Set<Int>, tint: Color, keep: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                Spacer(minLength: 8)
                Button("Keep This", action: keep).controlSize(.small)
            }
            if lines.isEmpty {
                Text("Nothing: taken out here").font(.system(size: 13).italic()).foregroundStyle(Color.inkFaint)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                ConflictLine(raw: line, mark: only.contains(index) ? tint : nil)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.inkPage))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.35)))
    }

    private func keep(_ index: Int, _ keep: ConflictKeep) {
        withAnimation(.snappy(duration: 0.2)) { draft.resolve(conflict: index, keeping: keep) }
    }

    // MARK: What it shows

    enum Place {
        case context([String])
        case gap
        case conflict(Int, ours: String, theirs: String)
    }

    /// How many lines around a place are shown of what both agree on.
    static let around = 2

    /// The note as the resolver shows it: each place, with a line or two
    /// of what is before and after it; what is further off, a gap.
    static func places(_ parts: [ConflictSegment]) -> [Place] {
        var places: [Place] = []
        var index = 0
        for (at, part) in parts.enumerated() {
            switch part {
            case .conflict(_, let ours, _, let theirs):
                places.append(.conflict(index, ours: ours, theirs: theirs))
                index += 1
            case .text(let text):
                let lines = Self.lines(text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != "---" }
                let before = at > 0, after = at < parts.count - 1
                if before && after && lines.count <= around * 2 + 1 {
                    if !lines.isEmpty { places.append(.context(lines)) }
                    continue
                }
                if before, !lines.isEmpty { places.append(.context(Array(lines.prefix(around)))) }
                if lines.count > (before ? around : 0) + (after ? around : 0) { places.append(.gap) }
                if after, !lines.isEmpty { places.append(.context(Array(lines.suffix(around)))) }
            }
        }
        return places
    }

    static func lines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    static func offset(_ change: CollectionDifference<String>.Change) -> Int {
        switch change {
        case .insert(let offset, _, _), .remove(let offset, _, _): offset
        }
    }

    /// What two lines are compared by: their words, wherever they stand.
    static func key(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }
}

extension ConflictSegment {
    var isConflict: Bool { if case .conflict = self { true } else { false } }
}

/// One line of a note as Markdown, shown as it reads: at its depth, its
/// bullet or checkbox, its words without their marks. Marked, for a line
/// only one device has.
struct ConflictLine: View {
    let raw: String
    let mark: Color?

    var body: some View {
        let line = Self.read(raw)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                switch line.lead {
                case .bullet: Text("•")
                case .number(let n): Text(n)
                case .task(let done): Image(systemName: done ? "checkmark.square" : "square").font(.system(size: 11))
                case .quote: Rectangle().frame(width: 2, height: 13)
                case .none: EmptyView()
                }
            }
            .foregroundStyle(Color.inkSecondary)
            Text(line.text.isEmpty ? " " : line.text)
                .font(TextSettings.font(line.heading ? 15 : 14, weight: line.heading ? .semibold : .regular))
                .strikethrough(line.done)
                .foregroundStyle(line.done ? Color.inkSecondary : Color.inkText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(line.depth) * 16)
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(mark?.opacity(0.13) ?? .clear))
    }

    enum Lead: Equatable {
        case none, bullet, number(String), task(Bool), quote
    }

    struct Read: Equatable {
        var depth = 0
        var lead = Lead.none
        var text = ""
        var heading = false
        var done = false
    }

    /// A line's depth, mark and words.
    static func read(_ raw: String) -> Read {
        var read = Read()
        var rest = Substring(raw)
        var columns = 0
        while let first = rest.first, first == " " || first == "\t" {
            columns += first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        read.depth = columns / 2
        let string = String(rest)
        func after(_ prefix: String) -> String? { string.hasPrefix(prefix) ? String(string.dropFirst(prefix.count)) : nil }
        if let words = after("- [ ] ") ?? after("* [ ] ") ?? after("+ [ ] ") {
            read.lead = .task(false)
            rest = Substring(words)
        } else if let words = after("- [x] ") ?? after("- [X] ") ?? after("* [x] ") ?? after("+ [x] ") {
            read.lead = .task(true)
            read.done = true
            rest = Substring(words)
        } else if let words = after("- ") ?? after("* ") ?? after("+ ") {
            read.lead = .bullet
            rest = Substring(words)
        } else if string == "-" {
            read.lead = .bullet
            rest = ""
        } else if let words = after("> ") {
            read.lead = .quote
            rest = Substring(words)
        } else if let digits = Optional(string.prefix { $0.isASCII && $0.isNumber }), !digits.isEmpty,
                  let mark = string.dropFirst(digits.count).first, mark == "." || mark == ")",
                  string.dropFirst(digits.count + 1).first == " " {
            read.lead = .number(digits + String(mark))
            rest = string.dropFirst(digits.count + 2)
        } else if let hashes = Optional(string.prefix { $0 == "#" }), (1...6).contains(hashes.count), string.dropFirst(hashes.count).first == " " {
            read.heading = true
            rest = string.dropFirst(hashes.count + 1)
        }
        var words = String(rest)
        // Struck through as a whole: shown so.
        if words.hasPrefix("~~"), words.hasSuffix("~~"), words.count > 4 {
            read.done = true
            words = String(words.dropFirst(2).dropLast(2))
        }
        read.text = inlinePlainText(text: words)
        return read
    }
}
