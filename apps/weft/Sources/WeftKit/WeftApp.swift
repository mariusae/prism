#if os(macOS)
import AppKit
import Prism
import SwiftUI

/// Weft on the Mac.
public struct WeftMacApp: App {
    @State private var store: GraphStore?
    @State private var failure: String?
    @State private var actions: WindowActions

    public init() {
        // The graph is opened as the app starts, not when a window shows:
        // the engine is at work before there is anything to draw.
        // The window is the app's own to open: what an earlier run left
        // on screen is not brought back by the system.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        let actions = WindowActions()
        _actions = State(initialValue: actions)
        var opened: GraphStore?
        var failure: String?
        if let url = Self.rememberedGraph() {
            do { opened = try GraphStore(root: url) } catch let error { failure = "\(error)" }
        }
        _store = State(initialValue: opened)
        _failure = State(initialValue: failure)
        if let opened { RiverKeys.install(store: opened, actions: actions) }
        if let opened, Snapshot.path != nil || ProcessInfo.processInfo.environment["WEFT_BENCH"] != nil { Snapshot.run(store: opened, actions: actions) }
    }

    private static func rememberedGraph() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-GraphPath"), arguments.indices.contains(flag + 1) {
            return URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath)
        }
        if let kept = UserDefaults.standard.string(forKey: "WeftGraphPath"), FileManager.default.fileExists(atPath: kept) {
            return URL(fileURLWithPath: kept)
        }
        return nil
    }

    public var body: some Scene {
        Window("Weft", id: "main") {
            Group {
                if let store {
                    ContentView(store: store, actions: actions)
                } else {
                    Welcome(failure: failure, open: choose)
                }
            }
            .frame(minWidth: 760, minHeight: 480)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in store?.saveAll() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store?.saveAll() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if Snapshot.path == nil { store?.engine.sync() } }
        }
        .defaultSize(width: 1240, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Page") { newPage() }.keyboardShortcut("n")
                Button("New Tab") { store?.newRiver() }.keyboardShortcut("t")
                Button("Quick Open…") { actions.quickOpen += 1 }.keyboardShortcut("o")
                Divider()
                Button("Open Folder…") { choose() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Close") { closeFront() }.keyboardShortcut("w")
                Button("Close River") { closeTab() }.keyboardShortcut("w", modifiers: [.command, .option])
                Button("Sync Now") { store?.syncNow() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .sidebar) {
                Button("Show or Hide the Sidebar") { actions.sidebar += 1 }.keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandMenu("Story") {
                Button("Today") { today() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Close All Cards") { closeAll() }.keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("Fold Card") { fold(true) }.keyboardShortcut(.upArrow, modifiers: [.command, .control])
                Button("Unfold Card") { fold(false) }.keyboardShortcut(.downArrow, modifiers: [.command, .control])
                Button("Fold All Cards") { store?.river.setAllFolded(true) }.keyboardShortcut(.upArrow, modifiers: [.command, .control, .option])
                Button("Unfold All Cards") { store?.river.setAllFolded(false) }.keyboardShortcut(.downArrow, modifiers: [.command, .control, .option])
                Divider()
                Button("Previous Card") { store?.river.select(step: -1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Next Card") { store?.river.select(step: 1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Write in Selected Card") { write() }.keyboardShortcut(.return, modifiers: [.command, .option])
                Button("Delete Page") { deleteCard() }.keyboardShortcut(.delete, modifiers: [.command, .control])
            }
            CommandGroup(before: .windowList) {
                Button("Show Previous Tab") { step(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Show Next Tab") { step(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose the folder your notes are kept in."
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private func open(_ url: URL) {
        do {
            store?.saveAll()
            let opened = try GraphStore(root: url)
            store = opened
            RiverKeys.install(store: opened, actions: actions)
            failure = nil
            UserDefaults.standard.set(url.path, forKey: "WeftGraphPath")
        } catch {
            failure = "\(error)"
        }
    }

    private func newPage() {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH.mm.ss"
        withAnimation(.snappy(duration: 0.28)) { _ = store?.newPage(title: "Untitled \(format.string(from: Date()))") }
    }

    private func today() {
        guard let store else { return }
        withAnimation(.snappy(duration: 0.28)) { store.open(name: QuickOpen.day(Date()), after: store.river.selected) }
    }

    private func closeAll() {
        guard let store else { return }
        store.saveAll()
        withAnimation(.snappy(duration: 0.28)) { store.river.cards.removeAll() }
        store.rememberRivers()
    }

    private func closeCard() {
        guard let store, let selected = store.river.selected else { return }
        store.saveAll()
        withAnimation(.snappy(duration: 0.28)) { store.river.close(selected) }
        store.rememberRivers()
    }

    /// ⌘W closes what is in front: the card chosen; with none, the river; with one river, the window.
    private func closeFront() {
        if store?.river.selected != nil { closeCard() } else { closeTab() }
    }

    private func deleteCard() {
        guard let store, let selected = store.river.selected, let card = store.river.cards.first(where: { $0.id == selected }) else { return }
        store.draft(path: card.path, title: card.title).delete()
        withAnimation(.snappy(duration: 0.28)) { store.river.close(selected) }
        store.rememberRivers()
    }

    private func closeTab() {
        guard let store else { return NSApp.keyWindow?.performClose(nil) ?? () }
        if store.rivers.count > 1 { store.closeRiver(at: store.currentRiver) } else { NSApp.keyWindow?.performClose(nil) }
    }

    private func fold(_ folded: Bool) {
        guard let river = store?.river, let selected = river.selected, let card = river.cards.first(where: { $0.id == selected }), card.folded != folded else { return }
        withAnimation(.snappy(duration: 0.22)) { river.toggleFold(selected) }
    }

    private func write() {
        guard let river = store?.river, let selected = river.selected else { return }
        river.writing = river.writing == selected ? nil : selected
    }

    private func step(_ by: Int) {
        guard let store, !store.rivers.isEmpty else { return }
        store.currentRiver = (store.currentRiver + by + store.rivers.count) % store.rivers.count
    }
}

/// The river's own keys, when nothing is being written: the arrows go
/// between cards, Space folds, Return writes, ⌘⌫ deletes — and any letter
/// starts finding a page.
@MainActor
enum RiverKeys {
    private static var monitor: Any?
    private static weak var store: GraphStore?
    private static weak var actions: WindowActions?

    static func install(store: GraphStore, actions: WindowActions) {
        self.store = store
        self.actions = actions
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handle(event) ? nil : event }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard let store, let actions, let window = event.window, window.isKeyWindow, window.attachedSheet == nil else { return false }
        // Keys typed into a field, or a card, are that field's.
        if window.firstResponder is NSText { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        let river = store.river
        if flags.isEmpty {
            switch event.specialKey {
            case .upArrow:
                river.select(step: -1)
                return true
            case .downArrow:
                river.select(step: 1)
                return true
            case .carriageReturn, .enter:
                guard let selected = river.selected else { return false }
                if river.cards.first(where: { $0.id == selected })?.folded == true { withAnimation(.snappy(duration: 0.22)) { river.toggleFold(selected) } }
                river.writing = selected
                return true
            default:
                break
            }
            guard let typed = event.characters, let first = typed.unicodeScalars.first else { return false }
            if typed == " ", let selected = river.selected {
                withAnimation(.snappy(duration: 0.22)) { river.toggleFold(selected) }
                store.rememberRivers()
                return true
            }
            if typed == "\u{1B}" {
                river.selected = nil
                return true
            }
            // A letter or a digit: the start of a page's name.
            if CharacterSet.alphanumerics.contains(first) {
                actions.typed = typed
                actions.quickOpen += 1
                return true
            }
        }
        return false
    }
}

/// Before a graph is open: where the notes are.
struct Welcome: View {
    let failure: String?
    var open: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 44)).foregroundStyle(Color.inkAccent)
            Text("Weft").font(.system(size: 28, weight: .semibold))
            Text("A river of cards over your notes.").foregroundStyle(Color.inkSecondary)
            Button("Use a Folder on This Mac…", action: open).controlSize(.large).keyboardShortcut(.defaultAction)
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).frame(maxWidth: 420) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.inkPage)
        .foregroundStyle(Color.inkText)
    }
}
#endif
