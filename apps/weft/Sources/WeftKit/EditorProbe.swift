#if DEBUG && os(macOS)
import AppKit
import PrismEditor

/// A harness's way in, to drive the editor as Bike is driven and compare
/// the two. Asked by a distributed notification naming a JSON file:
///
///     {"cmd": "load", "markdown": "...", "row": "two", "offset": 1, "out": "/tmp/answer.json"}
///     {"cmd": "dump", "out": "/tmp/answer.json"}
///
/// `load` writes `notes/probe.md`, shows it alone in the river and puts
/// the caret in the row whose words are `row`, `offset` characters in (or
/// at its end, with none). `dump` writes what the editor shows and has
/// chosen. Only in a debug build, and only on a graph named with `-GraphPath`.
@MainActor
enum EditorProbe {
    static let name = Notification.Name("org.mutable.weft.probe")
    /// Each probe its own note: what the editor had of the last is never written over the next.
    private static var count = 0
    /// The editor showing the probe's note: not one of a card on its way out.
    private static weak var current: NoteTextView?
    private static var listening: NSObjectProtocol?

    static func listen(store: GraphStore) {
        guard listening == nil, ProcessInfo.processInfo.arguments.contains("-GraphPath") else { return }
        listening = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            guard let file = note.object as? String else { return }
            MainActor.assumeIsolated { answer(file, store: store) }
        }
    }

    private static func answer(_ file: String, store: GraphStore) {
        guard let data = FileManager.default.contents(atPath: file),
              let ask = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let out = ask["out"] as? String else { return }
        func reply(_ value: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])) ?? Data()
            FileManager.default.createFile(atPath: out, contents: data)
        }
        switch ask["cmd"] as? String {
        case "load":
            let markdown = ask["markdown"] as? String ?? ""
            count += 1
            let path = "notes/probe-\(ProcessInfo.processInfo.processIdentifier)-\(count).md"
            _ = try? store.engine.write(path: path, content: markdown)
            store.river.cards = [Card(path: path, title: "probe")]
            store.river.selected = store.river.cards.first?.id
            // Drawn — the editor showing this note, not the last — then the caret put where it was asked for.
            let words = ask["names"] as? [String] ?? []
            func place(_ tries: Int) {
                let shown = editors().first { view in
                    let rows = view.probeState["rows"] as? [[String: Any]] ?? []
                    return rows.map { $0["name"] as? String ?? "" } == words
                }
                current = shown
                guard let view = shown ?? (tries == 0 ? editor() : nil), let rows = view.probeState["rows"] as? [[String: Any]] else {
                    return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { place(tries - 1) }
                }
                guard let name = ask["row"] as? String, let row = rows.first(where: { $0["name"] as? String == name }),
                      let content = row["content"] as? Int, let end = row["end"] as? Int
                else { return reply(["error": "no row", "state": view.probeState]) }
                view.window?.makeKey()
                let offset = ask["offset"] as? Int
                let at = offset.map { content + $0 } ?? end
                view.probeCaret(at: at)
                // The card settles — chosen, put in writing — and may take the caret away: checked again, and again put back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard let now = editor() else { return reply(["error": "no editor"]) }
                    if now.selectedRange() != NSRange(location: at, length: 0) || now.window?.firstResponder !== now { now.probeCaret(at: at) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        let settled = editor()?.selectedRange() == NSRange(location: at, length: 0)
                        reply(settled ? ["ok": true] : ["error": "caret moved", "state": editor()?.probeState ?? [:]])
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { place(20) }
        case "keys":
            // Pressed here, in this app's own window: never anywhere else on the screen.
            let keys = ask["keys"] as? [String] ?? []
            press(keys) { reply(["ok": true]) }
        case "dump":
            guard let view = editor() else { return reply(["error": "no editor"]) }
            reply(view.probeState)
        default:
            reply(["error": "unknown"])
        }
    }

    /// Keys as the harness names them — "cmd+shift+left", "return", "type:words" —
    /// each sent to the window as the keyboard would, a moment apart.
    private static func press(_ keys: [String], done: @escaping () -> Void) {
        guard let key = keys.first else { return done() }
        guard let view = editor(), let window = view.window else { return done() }
        window.makeKey()
        if key.hasPrefix("type:") {
            for character in key.dropFirst(5) { send(String(character), code: 0, flags: [], to: window) }
        } else {
            var parts = key.split(separator: "+").map(String.init)
            let base = parts.removeLast()
            var flags: NSEvent.ModifierFlags = []
            for part in parts {
                switch part {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "opt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                default: break
                }
            }
            let special: [String: (String, UInt16)] = [
                "return": ("\r", 36), "tab": ("\t", 48), "space": (" ", 49), "delete": ("\u{7F}", 51), "escape": ("\u{1B}", 53),
                "fdelete": ("\u{F728}", 117), "left": ("\u{F702}", 123), "right": ("\u{F703}", 124), "down": ("\u{F701}", 125), "up": ("\u{F700}", 126),
                "home": ("\u{F729}", 115), "end": ("\u{F72B}", 119),
            ]
            if let (characters, code) = special[base] {
                if code >= 115 { flags.formUnion([.function, .numericPad]) }
                if base == "tab", flags.contains(.shift) { send("\u{19}", code: code, flags: flags, to: window) } else { send(characters, code: code, flags: flags, to: window) }
            } else {
                send(base, code: 0, flags: flags, to: window)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { press(Array(keys.dropFirst()), done: done) }
    }

    private static func send(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags, to window: NSWindow) {
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            // Through the app, as a key pressed goes: its menus' keys first, then the window's.
            if kind == .keyDown, !flags.intersection([.command, .control]).isEmpty, window.performKeyEquivalent(with: event) || NSApp.mainMenu?.performKeyEquivalent(with: event) == true { continue }
            window.sendEvent(event)
        }
    }

    /// The probe's note's editor, once found; else the first in the window.
    private static func editor() -> NoteTextView? {
        if let current, current.window != nil { return current }
        return editors().first
    }

    private static func editors() -> [NoteTextView] {
        func find(_ view: NSView) -> [NoteTextView] {
            (view as? NoteTextView).map { [$0] } ?? view.subviews.flatMap(find)
        }
        return NSApp.windows.filter(\.isVisible).flatMap { $0.contentView.map(find) ?? [] }
    }
}
#endif
