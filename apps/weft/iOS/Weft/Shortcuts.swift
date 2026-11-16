import AppIntents

/// What Siri, Spotlight and Shortcuts offer of Weft without being set up.
struct WeftShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewNoteIntent(), phrases: ["New note in \(.applicationName)", "Start a note in \(.applicationName)"], shortTitle: "New Note", systemImageName: "square.and.pencil")
        AppShortcut(intent: DictateNoteIntent(), phrases: ["Dictate a note in \(.applicationName)", "Take a note in \(.applicationName)"], shortTitle: "Dictate a Note", systemImageName: "mic")
        AppShortcut(intent: OpenTodayIntent(), phrases: ["Open today in \(.applicationName)", "Today's note in \(.applicationName)"], shortTitle: "Today", systemImageName: "calendar")
        AppShortcut(intent: OpenToDosIntent(), phrases: ["Show my to-dos in \(.applicationName)"], shortTitle: "To-Dos", systemImageName: "checklist")
    }
}
