import SwiftUI
import UIKit
import WeftShared
import WidgetKit

/// Weft's colours, as the app has them: warm paper and ink, light and dark.
enum Ink {
    static let paper = pair(0xFAF7F2, 0x1D1B18)
    static let text = pair(0x2B2724, 0xECE6DC)
    static let secondary = pair(0x6F665D, 0xA79E92)
    static let faint = pair(0x2B2724, 0xECE6DC, alpha: 0.40)
    static let rule = pair(0x2B2724, 0xECE6DC, alpha: 0.10)
    static let accent = pair(0x315DBB, 0x93ACDD)

    private static func pair(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        func color(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) })
    }

    /// One of the colours a note or a river can be given, by its name.
    static func emblem(_ name: String?) -> Color? {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        default: return nil
        }
    }
}

/// What every widget is drawn from: the snapshot the app last wrote.
struct GlanceEntry: TimelineEntry {
    var date: Date
    var snapshot: Glance.Snapshot

    /// Today's note, if the snapshot is of today — not of a day gone by.
    var today: Glance.Note? {
        Calendar.current.isDate(snapshot.day, inSameDayAs: date) ? snapshot.today : nil
    }

    static var sample: GlanceEntry {
        let rows = [
            Glance.Row(index: 0, depth: 0, words: "Walk before breakfast", heading: false, done: true),
            Glance.Row(index: 1, depth: 0, words: "Call about the roof", heading: false, done: false),
            Glance.Row(index: 2, depth: 0, words: "Notes from the planning meeting", heading: false, done: nil),
            Glance.Row(index: 3, depth: 1, words: "Ship the widgets first", heading: false, done: nil),
        ]
        let today = Glance.Note(path: "", title: "Today", symbol: "calendar", color: nil, rows: rows)
        let toDos = ["Call about the roof", "Book the ferry", "Reply to Ada", "Read the draft"].enumerated().map {
            Glance.ToDo(path: "\($0.offset)", row: [], text: $0.element, words: $0.element, note: "Errands")
        }
        let cards = ["Errands", "Reading list", "Garden", "Trip to the coast"].map { Glance.Note(path: $0, title: $0, symbol: nil, color: nil, rows: Array(rows.prefix(2))) }
        let river = Glance.River(id: "", title: "On Deck", symbol: "water.waves", color: nil, cards: cards)
        return GlanceEntry(date: Date(), snapshot: Glance.Snapshot(day: Calendar.current.startOfDay(for: Date()), today: today, toDos: toDos, toDosOpen: 7, rivers: [river]))
    }
}

/// The snapshot as it is now — and again at midnight, when today is another day.
struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        let snapshot = Glance.read()
        completion(context.isPreview && snapshot.written == .distantPast ? .sample : GlanceEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        completion(Self.timeline())
    }

    static func timeline() -> Timeline<GlanceEntry> {
        let now = Date()
        let snapshot = Glance.read()
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        return Timeline(entries: [GlanceEntry(date: now, snapshot: snapshot), GlanceEntry(date: midnight, snapshot: snapshot)], policy: .after(midnight.addingTimeInterval(60)))
    }
}

/// A note's emblem, small: its symbol, in its colour.
struct EmblemMark: View {
    var symbol: String?
    var color: String?
    var size: CGFloat = 12

    var body: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Ink.emblem(color) ?? Ink.secondary)
        } else if let color = Ink.emblem(color) {
            Circle().fill(color).frame(width: size * 0.6, height: size * 0.6)
        }
    }
}

/// A row of an outline, as a widget draws it: indented, a to-do's box before it.
struct RowLine: View {
    var row: Glance.Row
    var size: CGFloat = 13

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            // One width for a box and a dot: every row's words at one edge.
            Group {
                if let done = row.done {
                    Image(systemName: done ? "checkmark.square" : "square")
                        .font(.system(size: size - 2))
                        .foregroundStyle(Ink.secondary)
                } else {
                    Circle().fill(Ink.faint).frame(width: 3.5, height: 3.5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + size * 0.3 }
                }
            }
            .frame(width: size, alignment: .center)
            Text(row.words.isEmpty ? " " : row.words)
                .font(.system(size: size, weight: row.heading ? .semibold : .regular))
                .foregroundStyle(row.done == true ? Ink.secondary : Ink.text)
                .strikethrough(row.done == true, color: Ink.faint)
                .lineLimit(1)
        }
        .padding(.leading, CGFloat(min(row.depth, 4)) * 12)
    }
}

extension View {
    /// The widget's own paper.
    func paper() -> some View {
        containerBackground(for: .widget) { Ink.paper }
    }
}
