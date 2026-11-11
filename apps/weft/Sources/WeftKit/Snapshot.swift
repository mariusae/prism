#if os(macOS)
import AppKit
import Prism
import PrismEditor
import PrismEmblem
import SwiftUI

/// Draws the app's window to a PNG, for checking it without a person at
/// it — or a screen: the window is made off screen and never shown, so
/// this works with the Mac locked.
///
///     WEFT_SNAPSHOT=out.png WEFT_OPEN="A|B" WEFT_FOLD=B WEFT_EDIT=A
///     WEFT_TYPE="[[Ch" WEFT_QUICK_OPEN=1 WEFT_SIZE=1240x860 WEFT_DARK=1
///     WEFT_DELAY=2 Weft.app/Contents/MacOS/WeftMac -GraphPath <folder>
///
/// It never syncs.
@MainActor
enum Snapshot {
    static var path: String? { ProcessInfo.processInfo.environment["WEFT_SNAPSHOT"] }
    private static var window: NSWindow?

    /// `WEFT_BENCH=1`: how long the engine and the editor take on this
    /// graph, printed, and nothing drawn.
    static func bench(store: GraphStore) {
        let clock = ContinuousClock()
        let ms = { (duration: Duration) in String(format: "%.2f ms", (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000) }
        let pages = (try? store.engine.allPages()) ?? []
        var sources: [(path: String, text: String)] = []
        for page in pages { if let text = (try? store.engine.read(path: page.path)) ?? nil { sources.append((page.path, text)) } }
        sources.sort { $0.text.utf8.count > $1.text.utf8.count }
        print("\(pages.count) pages")
        guard let largest = sources.first, !sources.isEmpty else { return }
        let middle = sources[sources.count / 2]
        for (name, note) in [("the largest note", largest), ("a middling note", middle)] {
            for mode in [EditorMode.outline, .text] {
                let cost = EditorBench.measure(source: note.text, mode: mode, theme: Ink.editorTheme)
                print(String(format: "%@ (%d bytes) as %@: open %.2f ms, read %.2f ms, dress %.2f ms, a keystroke's change %.2f ms", name, note.text.utf8.count, mode == .outline ? "an outline" : "text", cost.open * 1000, cost.layout * 1000, cost.style * 1000, cost.replace * 1000))
            }
        }
        var card: Card?
        print("opening a card (read, parse, backlinks, tags):", ms(clock.measure {
            let draft = store.draft(path: largest.path, title: "x")
            _ = try? store.engine.backlinks(path: largest.path)
            _ = try? store.engine.tagsOf(path: largest.path)
            card = Card(path: largest.path, title: draft.title)
        }))
        _ = card
        print("Quick Open, nothing typed (30 recent):", ms(clock.measure { _ = try? store.engine.runQuery(body: "sort: -modified\nlimit: 30", this: nil) }))
        print("Quick Open, a letter typed (names + text):", ms(clock.measure {
            _ = try? store.engine.complete(typed: "p", limit: 8)
            _ = try? store.engine.search(typed: "p", limit: 12)
        }))
        print("resolving 200 links' names:", ms(clock.measure { for page in pages.prefix(200) { _ = try? store.engine.resolve(name: page.title) } }))
    }

    static func run(store: GraphStore, actions: WindowActions) {
        if ProcessInfo.processInfo.environment["WEFT_BENCH"] != nil {
            bench(store: store)
            exit(0)
        }
        guard let path else { return }
        let environment = ProcessInfo.processInfo.environment
        let names = { (key: String) in (environment[key] ?? "").split(separator: "|").map(String.init) }
        // WEFT_SAVED=Work: that saved river, shown as its file has it; else a river with nothing in it yet.
        if let saved = environment["WEFT_SAVED"] { store.openSaved(saved) } else { store.river.cards.removeAll() }
        for name in names("WEFT_OPEN").reversed() { store.open(name: name) }
        for name in names("WEFT_FOLD") {
            if let card = store.river.cards.first(where: { $0.title == name }) { store.river.toggleFold(card.id) }
        }
        // WEFT_RIVERS=3: so many rivers open, the first shown.
        if let count = Int(environment["WEFT_RIVERS"] ?? ""), count > 1 {
            for _ in 1..<count { store.newRiver() }
            store.currentRiver = 0
        }
        // WEFT_RIVER_LOOKS="Work:briefcase:blue|:star:|Reading::green": the
        // rivers' names, icons and colours, in order.
        for (index, look) in names("WEFT_RIVER_LOOKS").enumerated() where store.rivers.indices.contains(index) {
            let parts = look.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            store.rivers[index].name = parts.first.flatMap { $0.isEmpty ? nil : $0 }
            store.rivers[index].icon = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            store.rivers[index].color = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        }
        // WEFT_SHOW=2: the river shown, by its place among the tabs.
        if let shown = Int(environment["WEFT_SHOW"] ?? ""), store.rivers.indices.contains(shown) { store.currentRiver = shown }
        // WEFT_MODE=outline or text: every card open shown that way.
        if let mode = environment["WEFT_MODE"] {
            for card in store.river.cards { store.draft(path: card.path, title: card.title).setMode(mode == "outline" ? .outline : .text) }
        }
        store.river.selected = nil
        if let edit = environment["WEFT_EDIT"], let card = store.river.cards.first(where: { $0.title == edit }) {
            store.river.selected = card.id
            store.river.writing = card.id
        }

        let size = (environment["WEFT_SIZE"] ?? "1240x860").split(separator: "x").compactMap { Double($0) }
        let frame = CGRect(x: 0, y: 0, width: size.first ?? 1240, height: size.last ?? 860)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: environment["WEFT_DARK"] != nil ? .darkAqua : .aqua)
        if environment["WEFT_DIAGNOSTICS"] != nil {
            window.contentView = NSHostingView(rootView: DiagnosticsView(store: store))
        } else if environment["WEFT_QUERY_EDITOR"] != nil {
            // The query river editor alone, as its sheet shows it: for the river shown, if it has a query.
            window.contentView = NSHostingView(rootView: QueryRiverEditor(store: store, ask: store.river.query == nil ? .new : .edit(store.river)))
        } else if environment["WEFT_SETTINGS"] != nil {
            window.contentView = NSHostingView(rootView: SettingsView())
        } else if environment["WEFT_CALENDAR"] != nil {
            // The calendar alone, as its popover shows it.
            window.contentView = NSHostingView(rootView: CalendarPopover(store: store) { _ in }.background(Color.inkPaper))
        } else if environment["WEFT_PICKER"] != nil {
            // The icon and colour picker alone, as its popover shows it.
            window.contentView = NSHostingView(rootView: EmblemPicker(title: "Project Atlas", icon: .constant("map"), color: .constant("teal")).frame(width: frame.width, height: frame.height))
        } else {
            window.contentView = NSHostingView(rootView: ContentView(store: store, actions: actions).frame(width: frame.width, height: frame.height))
        }
        window.setFrame(frame, display: false)
        window.layoutIfNeeded()
        self.window = window
        // WEFT_NUMBERS: as with ⌘ held — the tabs say their numbers.
        if environment["WEFT_NUMBERS"] != nil { CommandKey.shared.changed(.command) }
        if let select = environment["WEFT_SELECT"], let card = store.river.cards.first(where: { $0.title == select }) { store.river.selected = card.id }
        // WEFT_READ_PICTURES: the pictures' words read first, as the app reads them in its own time.
        if environment["WEFT_READ_PICTURES"] != nil {
            let (engine, root) = (store.engine, store.root)
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let count = await PictureWords.readAll(engine: engine, root: root)
                FileHandle.standardError.write("read \(count) pictures\n".data(using: .utf8)!)
                done.signal()
            }
            done.wait()
        }
        if let typed = environment["WEFT_QUICK_OPEN"] {
            DispatchQueue.main.async {
                actions.typed = typed == "1" ? "" : typed
                actions.quickOpen += 1
            }
        }

        // WEFT_DELETE=Title: that card's note deleted, as its button does it — and the offer to undo shown.
        if let title = environment["WEFT_DELETE"], let card = store.river.cards.first(where: { $0.title == title }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { store.delete(card.id, in: store.river) }
        }
        let delay = Double(environment["WEFT_DELAY"] ?? "") ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let typed = environment["WEFT_TYPE"], let view = window.firstResponder as? NSTextView {
                view.insertText(typed.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: view.selectedRange())
            }
            // WEFT_KEYS="cancelOperation:|moveUpAndModifySelection:": those commands, as their keys give them.
            if let view = window.firstResponder as? NSTextView {
                for key in names("WEFT_KEYS") {
                    // "cmd+]", "cmd+shift+]": a key held with ⌘, as the keyboard sends it; else a command by its name.
                    let now = window.firstResponder as? NSTextView ?? view
                    guard key.hasPrefix("cmd+") else {
                        now.doCommand(by: Selector(key))
                        continue
                    }
                    let shifted = key.hasPrefix("cmd+shift+")
                    let character = String(key.suffix(1))
                    if let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: shifted ? [.command, .shift] : [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0
                    ) {
                        _ = now.performKeyEquivalent(with: event)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let view = window.contentView?.superview ?? window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(3) }
                window.layoutIfNeeded()
                view.cacheDisplay(in: view.bounds, to: bitmap)
                do {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                } catch {
                    try? "could not write: \(error)\n".write(toFile: path + ".log", atomically: true, encoding: .utf8)
                    exit(4)
                }
                exit(0)
            }
        }
    }
}
#endif
