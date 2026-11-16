import SwiftUI
import WeftShared
import WidgetKit

/// Something to put down, quickly: a new note, one said, today's note,
/// the to-dos. Each opens the app at it.
struct CaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Glance.Kind.capture, provider: GlanceProvider()) { entry in
            CaptureView(entry: entry)
        }
        .configurationDisplayName("Capture")
        .description("A new note, a dictated one, today's note, and your to-dos.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

private struct CaptureView: View {
    var entry: GlanceEntry
    @Environment(\.widgetFamily) private var family

    private struct Action: Identifiable {
        var id: String { name }
        var name: String
        var symbol: String
        var link: URL
    }

    private var actions: [Action] {
        [
            Action(name: "New", symbol: "square.and.pencil", link: Glance.Link.new),
            Action(name: "Dictate", symbol: "mic", link: Glance.Link.dictate),
            Action(name: "Today", symbol: "calendar", link: Glance.Link.today),
            Action(name: entry.snapshot.toDosOpen > 0 ? "\(entry.snapshot.toDosOpen) To-Do\(entry.snapshot.toDosOpen == 1 ? "" : "s")" : "To-Dos", symbol: "checklist", link: Glance.Link.toDos),
        ]
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil").font(.system(size: 20, weight: .medium))
            }
            .widgetURL(Glance.Link.new)
            .containerBackground(for: .widget) { Color.clear }
            .accessibilityLabel("New Note")
        case .systemMedium:
            HStack(spacing: 10) {
                ForEach(actions) { action in button(action, labelled: true) }
            }
            .paper()
        default:
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { button(actions[0], labelled: false); button(actions[1], labelled: false) }
                GridRow { button(actions[2], labelled: false); button(actions[3], labelled: false) }
            }
            .paper()
        }
    }

    private func button(_ action: Action, labelled: Bool) -> some View {
        Link(destination: action.link) {
            VStack(spacing: 6) {
                Image(systemName: action.symbol)
                    .font(.system(size: labelled ? 22 : 24, weight: .medium))
                    .foregroundStyle(Ink.accent)
                    .widgetAccentable()
                if labelled {
                    Text(action.name).font(.caption.weight(.medium)).foregroundStyle(Ink.text).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.rule))
        }
        .accessibilityLabel(action.name)
    }
}
