import AppIntents
import Foundation
import WeftShared
#if !WIDGET_EXTENSION
import WeftKit
#endif

// What Weft can be asked to do from outside it — a control in Control
// Centre, on the Lock Screen or the Action button; Siri; Shortcuts;
// Spotlight. Each opens the app and does it there: built into the app,
// where it is done, and into the widgets' extension, where the controls
// are, which only names it.

/// Follows one of Weft's own links, in the app.
@MainActor
private func follow(_ url: URL) {
    #if !WIDGET_EXTENSION
    PhoneSession.shared.follow(url)
    #endif
}

/// A new note, to be written in.
struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Starts a new note in Weft, to be written in.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        follow(Glance.Link.new)
        return .result()
    }
}

/// A new note, said: Weft listens until + is tapped.
struct DictateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate a Note"
    static let description = IntentDescription("Opens Weft listening: what you say becomes a new note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        follow(Glance.Link.dictate)
        return .result()
    }
}

/// Today's note.
struct OpenTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Today"
    static let description = IntentDescription("Opens today's note in Weft.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        follow(Glance.Link.today)
        return .result()
    }
}

/// The open to-dos, from every note.
struct OpenToDosIntent: AppIntent {
    static let title: LocalizedStringResource = "Open To-Dos"
    static let description = IntentDescription("Shows the open to-dos from all of Weft's notes.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        follow(Glance.Link.toDos)
        return .result()
    }
}
