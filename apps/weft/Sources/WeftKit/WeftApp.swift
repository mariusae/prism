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
            do { opened = try GraphStore(root: url, token: Account.shared.tokenProvider, relay: Setup.relayHost) } catch let error { failure = "\(error)" }
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
                    Welcome(failure: failure, open: choose, opened: { open($0) })
                }
            }
            .frame(minWidth: 760, minHeight: 480)
            .onReceive(NotificationCenter.default.publisher(for: .weftSignedIn)) { _ in reopen() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in store?.saveAll() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store?.saveAll() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if Snapshot.path == nil { store?.engine.sync() } }
        }
        .defaultSize(width: 1240, height: 860)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Bigger Text") { TextSettings.size += 1 }.keyboardShortcut("+")
                Button("Smaller Text") { TextSettings.size -= 1 }.keyboardShortcut("-")
                Button("Actual Size") { TextSettings.size = TextSettings.defaultSize }.keyboardShortcut("0")
                Divider()
            }
            CommandGroup(replacing: .newItem) {
                Button("New Note") { newPage() }.keyboardShortcut("n")
                Button("New To-Do") { newToDo() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Tab") { store?.newRiver() }.keyboardShortcut("t")
                Button("New Query River…") { store?.queryAsk = .new }.keyboardShortcut("t", modifiers: [.command, .option])
                Button("Quick Open…") { actions.quickOpen += 1 }.keyboardShortcut("o")
                Divider()
                Button("Open Folder…") { choose() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Close") { closeFront() }.keyboardShortcut("w")
                Button("Close River") { closeTab() }.keyboardShortcut("w", modifiers: [.command, .option])
                Button("Sync Now") { store?.syncNow() }.keyboardShortcut("r")
                OpenDiagnostics()
                if Account.shared.isAvailable {
                    Divider()
                    if Account.shared.isSignedIn {
                        Button("Sign Out of GitHub\(Account.shared.login.map { " (\($0))" } ?? "")") {
                            Account.shared.signOut()
                            reopen()
                        }
                        if let install = Account.shared.installURL { Button("Choose Repositories on GitHub…") { NSWorkspace.shared.open(install) } }
                    } else {
                        Button("Sign In to GitHub…") { Account.shared.signIn { reopen() } }
                    }
                }
            }
            CommandGroup(replacing: .sidebar) {
                Button("Show or Hide the Sidebar") { actions.sidebar += 1 }.keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandMenu("Story") {
                Button("Today") { today() }.keyboardShortcut("d")
                Button("Go to Date…") { actions.calendar += 1 }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Close All Cards") { closeAll() }.keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Reopen Closed Note") { withAnimation(.snappy(duration: 0.28)) { _ = store?.reopenClosed() } }.keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Fold or Unfold Card") { toggleFold() }.keyboardShortcut(.return, modifiers: .control)
                Button("Fold Card") { fold(true) }.keyboardShortcut(.upArrow, modifiers: [.command, .control])
                Button("Unfold Card") { fold(false) }.keyboardShortcut(.downArrow, modifiers: [.command, .control])
                Button("Fold All Cards") { store?.river.setAllFolded(true) }.keyboardShortcut(.upArrow, modifiers: [.command, .control, .option])
                Button("Unfold All Cards") { store?.river.setAllFolded(false) }.keyboardShortcut(.downArrow, modifiers: [.command, .control, .option])
                Divider()
                Button("Previous Card") { store?.river.select(step: -1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Next Card") { store?.river.select(step: 1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Write in Selected Card") { write() }.keyboardShortcut(.return, modifiers: [.command, .option])
                Button("Make First Line the Title") { titleByFirstLine() }.keyboardShortcut("t", modifiers: [.command, .control])
                Button("Delete Note") { deleteCard() }.keyboardShortcut(.delete, modifiers: .command)
            }
            CommandGroup(before: .windowList) {
                Button("Show Previous Tab") { step(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Show Next Tab") { step(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            }
        }

        Window("Sync Diagnostics", id: "diagnostics") { DiagnosticsView(store: store) }
            .defaultSize(width: 760, height: 620)

        Settings { SettingsView() }
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
            store?.close()
            store = nil
            let opened = try GraphStore(root: url, token: Account.shared.tokenProvider, relay: Setup.relayHost)
            store = opened
            RiverKeys.install(store: opened, actions: actions)
            failure = nil
            UserDefaults.standard.set(url.path, forKey: "WeftGraphPath")
        } catch {
            failure = "\(error)"
        }
    }

    /// Opens the graph again: as the account just signed in to, or as none.
    private func reopen() {
        if let root = store?.root { open(root) }
    }

    private func newPage() {
        withAnimation(.snappy(duration: 0.28)) { _ = store?.newNote() }
    }

    /// A new note that is a thing to do: its ring before its first words.
    private func newToDo() {
        guard let store else { return }
        withAnimation(.snappy(duration: 0.28)) {
            if let card = store.newNote() { store.draft(path: card.path, title: card.title).setTask(.todo) }
        }
    }

    private func today() {
        guard let store else { return }
        withAnimation(.snappy(duration: 0.28)) { store.open(name: QuickOpen.day(Date()), after: store.river.selected) }
    }

    private func closeAll() {
        guard let store else { return }
        withAnimation(.snappy(duration: 0.28)) { store.closeAll(in: store.river) }
    }

    private func closeCard() {
        guard let store, let selected = store.river.selected else { return }
        withAnimation(.snappy(duration: 0.28)) { store.close(selected, in: store.river) }
    }

    /// ⌘W closes what is in front: the card chosen; with none, the river; with one river, the window.
    private func closeFront() {
        if store?.river.selected != nil { closeCard() } else { closeTab() }
    }

    private func deleteCard() {
        guard let store, let selected = store.river.selected else { return }
        withAnimation(.snappy(duration: 0.28)) { store.delete(selected, in: store.river) }
    }

    private func closeTab() {
        guard let store else { return NSApp.keyWindow?.performClose(nil) ?? () }
        if store.rivers.count > 1 { store.closeRiver(at: store.currentRiver) } else { NSApp.keyWindow?.performClose(nil) }
    }

    private func fold(_ folded: Bool) {
        guard let river = store?.river, let selected = river.selected, let card = river.card(selected), card.folded != folded else { return }
        withAnimation(.snappy(duration: 0.22)) { river.toggleFold(selected) }
    }

    /// The first line of the card chosen — the one being written in, if one is — made its title.
    private func titleByFirstLine() {
        guard let store, let chosen = store.river.writing ?? store.river.selected, let card = store.river.card(chosen) else { return }
        withAnimation(.snappy(duration: 0.22)) { _ = store.draft(path: card.path, title: card.title).titleByFirstLine() }
    }

    /// Folds the card chosen — the one being written in, if one is — or unfolds it.
    private func toggleFold() {
        guard let store, let river = Optional(store.river), let chosen = river.writing ?? river.selected else { return }
        river.selected = chosen
        withAnimation(.snappy(duration: 0.22)) { river.toggleFold(chosen) }
        store.rememberRivers()
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
    private static var flags: Any?
    private static weak var store: GraphStore?
    private static weak var actions: WindowActions?

    static func install(store: GraphStore, actions: WindowActions) {
        self.store = store
        self.actions = actions
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handle(event) ? nil : event }
        // ⌘ held, alone: the tabs say their numbers.
        flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            CommandKey.shared.changed(event.modifierFlags)
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CommandKey.shared.changed([]) }
        }
    }

    /// Whether a window is one that shows rivers: not the settings, the diagnostics, a popover.
    private static func isRiverWindow(_ window: NSWindow) -> Bool {
        let name = (window.identifier?.rawValue ?? "").lowercased()
        return window.styleMask.contains(.titled) && window.toolbar != nil && !name.contains("settings") && !name.contains("diagnostics")
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard let store, let actions, let window = event.window, window.isKeyWindow, window.attachedSheet == nil else { return false }
        // ⌘W closes the note in hand — the one being written in, else the
        // one chosen — whatever has the keys: heard here, ahead of the
        // window's own Close, which would take the window with it.
        let pressed = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if pressed == .command, event.charactersIgnoringModifiers == "w", isRiverWindow(window) {
            let river = store.river
            if let card = river.writing ?? river.selected, river.card(card) != nil {
                withAnimation(.snappy(duration: 0.28)) { store.close(card, in: river) }
                return true
            }
        }
        // ⌘1 to ⌘8: the river at that place among the tabs; ⌘9, the last —
        // but in a note being written, ⌘9 is the outline's, to fold a row.
        if pressed == .command, isRiverWindow(window), let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit) {
            let writing = window.firstResponder is NSText
            if digit < 9 || !writing {
                let index = digit == 9 ? store.rivers.count - 1 : digit - 1
                guard store.rivers.indices.contains(index) else { return digit < 9 }
                CommandKey.shared.used()
                withAnimation(.snappy(duration: 0.2)) { store.currentRiver = index }
                return true
            }
        }
        // Keys typed into a field, or a card, are that field's — ⌘⌫ too,
        // which there takes the line back to its start, and is not left
        // for the menu, where it deletes the note.
        if let text = window.firstResponder as? NSText {
            let isDelete = event.keyCode == 51 && event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
            if isDelete { text.doCommand(by: #selector(NSResponder.deleteToBeginningOfLine(_:))) }
            return isDelete
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        // ⌘Z, with nothing being written: what was just done to the river, undone.
        if flags == .command, event.charactersIgnoringModifiers == "z", !event.modifierFlags.contains(.shift) {
            return withAnimation(.snappy(duration: 0.28)) { store.takeUndo() }
        }
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
                if river.card(selected)?.folded == true { withAnimation(.snappy(duration: 0.22)) { river.toggleFold(selected) } }
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
    /// Opens the graph cloned into a folder.
    var opened: (URL) -> Void
    private let account = Account.shared
    @State private var repositories: [GitHubRepository]?
    @State private var cloning: String?
    @State private var progress: CloneProgress?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 44)).foregroundStyle(Color.inkAccent)
            Text("Weft").font(.system(size: 28, weight: .semibold))
            Text("A river of cards over your notes.").foregroundStyle(Color.inkSecondary)
            if account.isAvailable {
                if account.isSignedIn { chooser } else {
                    Button(account.isBusy ? "Signing In…" : "Sign In to GitHub…") { account.signIn { load() } }
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(account.isBusy)
                    Text("Your notes are kept in a repository of yours, and synced through it.").font(.callout).foregroundStyle(Color.inkSecondary)
                }
                // Not while a graph is on its way down: one thing at a time.
                if cloning == nil { Button("Use a Folder on This Mac…", action: open).buttonStyle(.link) }
            } else {
                Button("Use a Folder on This Mac…", action: open).controlSize(.large).keyboardShortcut(.defaultAction)
            }
            if let failure = problem ?? account.failure ?? failure { Text(failure).font(.callout).foregroundStyle(.red).frame(maxWidth: 420) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.inkPage)
        .foregroundStyle(Color.inkText)
        .task { load() }
        // Signed in from the menu, or out: the list follows.
        .onChange(of: account.isSignedIn) { _, signedIn in if signedIn { load() } else { repositories = nil } }
    }

    /// Signed in: the repositories the GitHub App was let into, to choose the graph's from.
    @ViewBuilder private var chooser: some View {
        if let cloning {
            VStack(spacing: 8) {
                Text("Bringing down \(cloning)").font(.callout.weight(.medium))
                // Until GitHub says how much there is, it is not known how far along this is.
                if let progress {
                    ProgressView(value: min(max(progress.fraction, 0), 1)).animation(.linear(duration: 0.15), value: progress.fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(Self.says(progress)).font(.caption).monospacedDigit().foregroundStyle(Color.inkSecondary)
            }
            .frame(width: 300)
        } else if let repositories {
            if repositories.isEmpty {
                Text("The GitHub App has not been let into any repository yet.").font(.callout).foregroundStyle(Color.inkSecondary)
            } else {
                Text("Choose the repository your notes are in.").font(.callout).foregroundStyle(Color.inkSecondary)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(repositories, id: \.fullName) { repository in
                            Button { bringDown(repository) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: repository.isPrivate ? "lock" : "book.closed").foregroundStyle(Color.inkSecondary).frame(width: 18)
                                    Text(repository.fullName)
                                    Spacer()
                                    if FileManager.default.fileExists(atPath: Self.folder(for: repository).appendingPathComponent(".git").path) {
                                        Text("on this Mac").font(.caption).foregroundStyle(Color.inkSecondary)
                                    }
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.inkFaint)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                .frame(width: 380)
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.inkCard))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.inkRule))
            }
            HStack(spacing: 14) {
                if let install = account.installURL { Button("Choose Repositories on GitHub…") { NSWorkspace.shared.open(install) }.buttonStyle(.link) }
                Button("Refresh") { load() }.buttonStyle(.link)
                Button("Sign Out") {
                    account.signOut()
                    self.repositories = nil
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// A clone's progress, in words.
    static func says(_ progress: CloneProgress?) -> String {
        guard let progress else { return "Reaching GitHub…" }
        switch progress.part {
        case .receiving:
            let size = ByteCountFormatter.string(fromByteCount: Int64(progress.bytes), countStyle: .file)
            return "Receiving: \(progress.done.formatted()) of \(progress.total.formatted()) objects, \(size)"
        case .resolving: return "Putting the history together…"
        case .checkingOut:
            return progress.done >= progress.total ? "Reading your notes…" : "Writing out \(progress.done.formatted()) of \(progress.total.formatted()) files"
        }
    }

    private final class Watcher: CloneWatcher, @unchecked Sendable {
        let heard: @MainActor (CloneProgress) -> Void
        init(heard: @escaping @MainActor (CloneProgress) -> Void) { self.heard = heard }
        func onProgress(progress: CloneProgress) {
            Task { @MainActor in heard(progress) }
        }
    }

    /// Where a repository's graph is kept on this Mac.
    static func folder(for repository: GitHubRepository) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Weft/Graphs", isDirectory: true).appendingPathComponent(repository.fullName.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    private func load() {
        guard account.isSignedIn, let github = account.github else { return }
        problem = nil
        Task {
            let found: Result<[GitHubRepository], Error> = await Task.detached { Result { try github.repositories() } }.value
            switch found {
            case .success(let repositories): self.repositories = repositories
            case .failure(let error):
                repositories = []
                problem = "\(error)"
            }
        }
    }

    /// Clones the repository — or, if it is on this Mac already, opens it.
    private func bringDown(_ repository: GitHubRepository) {
        let folder = Self.folder(for: repository)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return opened(folder) }
        guard let token = account.tokenProvider else { return }
        cloning = repository.fullName
        progress = nil
        problem = nil
        let options = GraphStore.options
        // Told on the cloning thread, shown on the main one — and never backwards.
        let watcher = Watcher { now in if now.fraction >= (progress?.fraction ?? 0) { progress = now } }
        Task {
            let outcome: Result<Void, Error> = await Task.detached {
                Result {
                    try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // The engine that clones is let go; the store opens its own.
                    _ = try PrismEngine.cloneRepository(url: repository.cloneUrl, root: folder.path, options: options, token: token, watcher: watcher)
                }
            }.value
            cloning = nil
            progress = nil
            switch outcome {
            case .success: opened(folder)
            case .failure(let error):
                problem = "\(error)"
                // What came down of it is no graph: cleared, so that it can be tried again.
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
/// Whether ⌘ is being held, alone, long enough to be asking what it
/// can do: when it is, the tabs say the numbers they are chosen by.
@MainActor
@Observable
final class CommandKey {
    static let shared = CommandKey()
    private(set) var isHeld = false
    @ObservationIgnored private var waiting: DispatchWorkItem?

    func changed(_ flags: NSEvent.ModifierFlags) {
        waiting?.cancel()
        waiting = nil
        guard flags.intersection([.command, .option, .control, .shift]) == .command else {
            if isHeld { isHeld = false }
            return
        }
        // Not at once: ⌘ goes down for every key it is pressed with.
        let work = DispatchWorkItem { [weak self] in self?.isHeld = true }
        waiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// A key was pressed with it: it was held for that, not to ask.
    func used() {
        waiting?.cancel()
        waiting = nil
    }
}
#endif
