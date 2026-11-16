import AppIntents
import SwiftUI
import WeftShared
import WidgetKit

/// The open to-dos, from every note: each ticked off where it stands.
struct ToDosWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Glance.Kind.toDos, provider: GlanceProvider()) { entry in
            ToDosView(entry: entry)
        }
        .configurationDisplayName("To-Dos")
        .description("Your open to-dos, from every note. Tick one off without opening Weft.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// A to-do ticked on the widget: shown done at once, checked off in its
/// note the next time Weft runs.
struct TickToDoIntent: AppIntent {
    static let title: LocalizedStringResource = "Tick To-Do"
    static let isDiscoverable = false

    @Parameter(title: "To-Do") var id: String

    init() {}
    init(id: String) { self.id = id }

    func perform() async throws -> some IntentResult {
        Glance.tick(id)
        return .result()
    }
}

private struct ToDosView: View {
    var entry: GlanceEntry
    @Environment(\.widgetFamily) private var family

    private var open: Int { entry.snapshot.toDosOpen }

    private var shown: Int {
        switch family {
        case .systemSmall: return 4
        case .systemMedium: return 3
        case .accessoryRectangular: return 2
        default: return 7
        }
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(open == 0 ? "Nothing to do" : "\(open) to-do\(open == 1 ? "" : "s")", systemImage: "checklist")
                .widgetURL(Glance.Link.toDos)
                .containerBackground(for: .widget) { Color.clear }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "checklist").font(.system(size: 12, weight: .semibold))
                    Text("\(open)").font(.system(size: 20, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6)
                }
            }
            .widgetURL(Glance.Link.toDos)
            .containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(open == 0 ? "Nothing to do" : "\(open) To-Do\(open == 1 ? "" : "s")").font(.headline).widgetAccentable()
                ForEach(entry.snapshot.toDos.filter { !$0.done }.prefix(shown)) { toDo in
                    Text(toDo.words).font(.caption).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(Glance.Link.toDos)
            .containerBackground(for: .widget) { Color.clear }
        default:
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 5 : 7) {
            Link(destination: Glance.Link.toDos) {
                HStack(spacing: 6) {
                    Image(systemName: "checklist").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.accent).widgetAccentable()
                    Text("To-Dos").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text)
                    Spacer(minLength: 4)
                    if open > 0 { Text("\(open)").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.secondary) }
                }
            }
            if entry.snapshot.toDos.isEmpty {
                Text(entry.snapshot.written == .distantPast ? "Open Weft once to see your to-dos" : "Nothing to do").font(.system(size: 13)).foregroundStyle(Ink.secondary)
            }
            ForEach(entry.snapshot.toDos.prefix(shown)) { toDo in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Button(intent: TickToDoIntent(id: toDo.id)) {
                        Image(systemName: toDo.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: family == .systemSmall ? 15 : 17))
                            .foregroundStyle(toDo.done ? Ink.accent : Ink.secondary)
                            .widgetAccentable()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(toDo.done ? "Mark not done" : "Mark done")
                    Link(destination: Glance.Link.note(toDo.path)) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(toDo.words)
                                .font(.system(size: family == .systemSmall ? 12.5 : 13.5))
                                .foregroundStyle(toDo.done ? Ink.secondary : Ink.text)
                                .strikethrough(toDo.done, color: Ink.faint)
                                .lineLimit(1)
                            if family != .systemSmall {
                                Text(toDo.note).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .paper()
    }
}
