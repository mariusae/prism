import SwiftUI
import WeftShared
import WidgetKit

/// Today's note: its first rows, each a tap from where it is in the note.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Glance.Kind.today, provider: GlanceProvider()) { entry in
            TodayView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("The first rows of today's note.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

private struct TodayView: View {
    var entry: GlanceEntry
    @Environment(\.widgetFamily) private var family

    private var rowsShown: Int {
        switch family {
        case .systemSmall: return 5
        case .systemMedium: return 5
        case .accessoryRectangular: return 2
        default: return 13
        }
    }

    var body: some View {
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.date, format: .dateTime.weekday(.wide).day().month()).font(.headline).widgetAccentable()
                if let today = entry.today, !today.rows.isEmpty {
                    ForEach(Array(today.rows.prefix(rowsShown).enumerated()), id: \.offset) { _, row in
                        Text(row.words).font(.caption).lineLimit(1)
                    }
                } else {
                    Text("Nothing written yet").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(Glance.Link.today)
            .containerBackground(for: .widget) { Color.clear }
        } else {
            VStack(alignment: .leading, spacing: family == .systemLarge ? 6 : 4) {
                Link(destination: Glance.Link.today) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.accent).widgetAccentable()
                        Text(entry.date, format: family == .systemSmall ? .dateTime.weekday(.abbreviated).day().month(.abbreviated) : .dateTime.weekday(.wide).day().month())
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                    }
                }
                if let today = entry.today, !today.rows.isEmpty {
                    ForEach(Array(today.rows.prefix(rowsShown).enumerated()), id: \.offset) { _, row in
                        Link(destination: Glance.Link.note(today.path, row: row.index)) {
                            RowLine(row: row, size: family == .systemSmall ? 12.5 : 13.5)
                        }
                    }
                } else {
                    Text("Nothing written today yet").font(.system(size: 13)).foregroundStyle(Ink.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(Glance.Link.today)
            .paper()
        }
    }
}
