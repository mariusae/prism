import AppIntents
import SwiftUI
import WeftShared
import WidgetKit

/// One of the rivers open in Weft, chosen when the widget is set up: its
/// cards, each a tap from being shown.
struct RiverWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Glance.Kind.river, intent: ChooseRiverIntent.self, provider: RiverProvider()) { entry in
            RiverWidgetView(entry: entry)
        }
        .configurationDisplayName("River")
        .description("The cards of one of your rivers.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// A river, as the widget is set up with it.
struct RiverChoice: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "River"
    static let defaultQuery = RiverChoices()

    var id: String
    var title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

/// The rivers to choose from: those open in Weft when it last ran.
struct RiverChoices: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [RiverChoice] {
        Glance.read().rivers.filter { identifiers.contains($0.id) }.map { RiverChoice(id: $0.id, title: $0.title) }
    }

    func suggestedEntities() async throws -> [RiverChoice] {
        Glance.read().rivers.map { RiverChoice(id: $0.id, title: $0.title) }
    }

    func defaultResult() async -> RiverChoice? {
        Glance.read().rivers.first.map { RiverChoice(id: $0.id, title: $0.title) }
    }
}

struct ChooseRiverIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose River"
    static let description = IntentDescription("The river whose cards the widget shows.")

    @Parameter(title: "River") var river: RiverChoice?
}

struct RiverEntry: TimelineEntry {
    var date: Date
    var river: Glance.River?
    var written: Bool
}

struct RiverProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RiverEntry {
        RiverEntry(date: Date(), river: GlanceEntry.sample.snapshot.rivers.first, written: true)
    }

    func snapshot(for configuration: ChooseRiverIntent, in context: Context) async -> RiverEntry {
        let entry = entry(for: configuration)
        return context.isPreview && entry.river == nil ? placeholder(in: context) : entry
    }

    func timeline(for configuration: ChooseRiverIntent, in context: Context) async -> Timeline<RiverEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: ChooseRiverIntent) -> RiverEntry {
        let snapshot = Glance.read()
        let river = configuration.river.flatMap { chosen in snapshot.rivers.first { $0.id == chosen.id } } ?? snapshot.rivers.first
        return RiverEntry(date: Date(), river: river, written: snapshot.written != .distantPast)
    }
}

private struct RiverWidgetView: View {
    var entry: RiverEntry
    @Environment(\.widgetFamily) private var family

    private var cardsShown: Int {
        switch family {
        case .systemSmall: return 4
        case .systemMedium: return 4
        default: return 5
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 5) {
            if let river = entry.river {
                Link(destination: Glance.Link.river(id: river.id)) {
                    HStack(spacing: 6) {
                        EmblemMark(symbol: river.symbol ?? "water.waves", color: river.color, size: 13).widgetAccentable()
                        Text(river.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                        Spacer(minLength: 4)
                        if river.cards.count > cardsShown { Text("\(river.cards.count)\(river.cards.count >= 10 ? "+" : "")").font(.system(size: 12)).foregroundStyle(Ink.secondary) }
                    }
                }
                if river.cards.isEmpty {
                    Text("Nothing open").font(.system(size: 13)).foregroundStyle(Ink.secondary)
                }
                let cards = Array(river.cards.prefix(cardsShown))
                // Where any card shown has an emblem, every one has its room: the titles at one edge.
                let marked = cards.contains { $0.symbol != nil || Ink.emblem($0.color) != nil }
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    Link(destination: Glance.Link.river(id: river.id, card: card.path)) { cardView(card, marked: marked) }
                }
            } else {
                Text(entry.written ? "Choose a river: hold the widget, then Edit Widget." : "Open Weft once to see your rivers.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(entry.river.map { Glance.Link.river(id: $0.id) })
        .paper()
    }

    @ViewBuilder
    private func cardView(_ card: Glance.Note, marked: Bool) -> some View {
        let title = HStack(alignment: .firstTextBaseline, spacing: 5) {
            if marked { EmblemMark(symbol: card.symbol, color: card.color, size: 11).frame(width: 14) }
            Text(card.title).font(.system(size: family == .systemSmall ? 12.5 : 13.5, weight: .medium)).foregroundStyle(Ink.text).lineLimit(1)
        }
        if family == .systemLarge {
            VStack(alignment: .leading, spacing: 2) {
                title
                ForEach(Array(card.rows.prefix(2).enumerated()), id: \.offset) { _, row in
                    RowLine(row: row, size: 12).padding(.leading, 4)
                }
            }
        } else {
            title
        }
    }
}
