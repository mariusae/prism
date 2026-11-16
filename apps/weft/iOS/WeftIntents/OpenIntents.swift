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

/// Follows one of Weft's own links: in the app, at once; run anywhere
/// else — by a control, in the widgets' extension — by opening the app at
/// the link, so that it is done whichever process the system chose.
@MainActor
private func follow(_ url: URL) -> some IntentResult & OpensIntent {
    #if WIDGET_EXTENSION
    return .result(opensIntent: OpenURLIntent(url))
    #else
    PhoneSession.shared.follow(url)
    return .result()
    #endif
}

/// A new note, to be written in.
struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Starts a new note in Weft, to be written in.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        follow(Glance.Link.new)
    }
}

/// A new note, said: Weft listens until + is tapped.
struct DictateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate a Note"
    static let description = IntentDescription("Opens Weft listening: what you say becomes a new note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        follow(Glance.Link.dictate)
    }
}

/// Today's note.
struct OpenTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Today"
    static let description = IntentDescription("Opens today's note in Weft.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        follow(Glance.Link.today)
    }
}

/// The open to-dos, from every note.
struct OpenToDosIntent: AppIntent {
    static let title: LocalizedStringResource = "Open To-Dos"
    static let description = IntentDescription("Shows the open to-dos from all of Weft's notes.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        follow(Glance.Link.toDos)
    }
}
