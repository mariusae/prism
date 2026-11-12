import Foundation

/// What is heard, typed out rather than put down at once: each word comes
/// in a few letters at a time, quickly, so the eye can follow where the
/// words are going. Heard again differently, the letters no longer heard
/// go at once, and the rest is typed from there.
@MainActor
public final class DictationTypist {
    /// What is written so far.
    public private(set) var shown = ""
    private var target = ""
    private var timer: Timer?
    private let write: (String) -> Void

    /// `write`: what is to stand written now — called as each few letters come.
    public init(write: @escaping (String) -> Void) {
        self.write = write
    }

    /// What has been heard so far, to type out.
    public func type(_ text: String) {
        target = text
        guard timer == nil, shown != target else { return }
        let timer = Timer(timeInterval: 1.0 / 45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        step()
    }

    /// The rest written at once: when listening stops.
    public func flush(_ text: String? = nil) {
        if let text { target = text }
        stop()
        guard shown != target else { return }
        shown = target
        write(shown)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        let same = zip(shown, target).prefix { $0 == $1 }.count
        let left = target.count - same
        guard left > 0 || shown.count != same else { return stop() }
        // A fifth of what is left each time, so a long phrase catches up.
        shown = String(target.prefix(same + max(1, left / 5)))
        write(shown)
        if shown == target { stop() }
    }
}

/// Where words said at the caret stand in the note's text, found from
/// what follows them on their line rather than counted from what was
/// written: the text system may change what was written — `...` to `…`,
/// now or a moment later — and a span counted from what was meant reached
/// past the line's end, and took the next line's break with it.
public enum DictatedSpan {
    /// How much of the line follows `range`: kept, as words go in before it.
    public static func tail(after range: NSRange, in text: NSString) -> Int {
        lineEnd(from: NSMaxRange(range), in: text) - min(NSMaxRange(range), text.length)
    }

    /// The words said, from `location` to where the line's last `tail`
    /// characters begin — never past the line's end.
    public static func span(from location: Int, tail: Int, in text: NSString) -> NSRange {
        let location = min(location, text.length)
        let end = lineEnd(from: location, in: text)
        return NSRange(location: location, length: max(0, end - tail - location))
    }

    private static func lineEnd(from location: Int, in text: NSString) -> Int {
        var end = min(location, text.length)
        while end < text.length, !isBreak(text.character(at: end)) { end += 1 }
        return end
    }

    private static func isBreak(_ unit: unichar) -> Bool {
        unit == 10 || unit == 13 || unit == 0x2028 || unit == 0x2029
    }
}
