import SwiftUI
import WidgetKit

/// Weft's widgets and controls: what can be done and seen of it without
/// opening it. What they show the app writes down for them
/// (`Glance.Snapshot`); everything they do is done in the app.
@main
struct WeftWidgets: WidgetBundle {
    var body: some Widget {
        CaptureWidget()
        TodayWidget()
        ToDosWidget()
        RiverWidget()
        NewNoteControl()
        DictateControl()
        TodayControl()
    }
}

/// A new note, from Control Centre, the Lock Screen, or the Action button.
struct NewNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "org.mutable.weft.control.new") {
            ControlWidgetButton(action: NewNoteIntent()) { Label("New Note", systemImage: "square.and.pencil") }
        }
        .displayName("New Note")
        .description("Start a new note in Weft.")
    }
}

/// A note said: Weft opens listening.
struct DictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "org.mutable.weft.control.dictate") {
            ControlWidgetButton(action: DictateNoteIntent()) { Label("Dictate a Note", systemImage: "mic") }
        }
        .displayName("Dictate a Note")
        .description("Open Weft listening: what you say becomes a new note.")
    }
}

/// Today's note.
struct TodayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "org.mutable.weft.control.today") {
            ControlWidgetButton(action: OpenTodayIntent()) { Label("Today", systemImage: "calendar") }
        }
        .displayName("Today")
        .description("Open today's note in Weft.")
    }
}
