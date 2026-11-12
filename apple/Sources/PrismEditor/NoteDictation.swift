import Foundation
import PrismDictation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Words said, written into a note where its caret is, as they are heard:
/// what was heard so far stands in place, replaced as more comes, and is
/// settled once listening stops. Typed out as it comes, each word lit as
/// it is written, the caret a bar of light meanwhile ([`DictationGlow`]).
///
/// Always in place: there is no other window, no bubble, nothing to move
/// what was said from afterwards. What is written goes through the note
/// as anything typed does — it is the note's at once, saved and undone
/// like the rest.
///
/// One at a time: starting another stops the one going.
@MainActor
public final class NoteDictation {
    /// The dictation going on, if one is: told of in `changed`.
    public private(set) static var current: NoteDictation?
    /// Posted when dictation starts, stops, or changes who is writing it down.
    public static let changed = Notification.Name("PrismNoteDictationChanged")
    /// The words to favour — names of notes, of people: the app's to give.
    public static var keyterms: @MainActor () -> [String] = { [] }

    /// Who is writing it down, once known.
    public private(set) var engine: Dictation.Engine?
    /// The note being said into.
    public private(set) weak var view: NoteTextView?

    private let dictation = Dictation()
    /// Where what is heard stands: at the caret, as long as what is heard so far.
    private var range: NSRange
    /// A space before it, after a word — and after it, before one.
    private let lead: String
    private let trail: String
    /// How much of its line follows it: where it ends is found from this.
    private let tail: Int
    private var typist: DictationTypist!
    private let glow: DictationGlow
    private var ended = false

    /// Whether dictation is going on — in a note, if one is given.
    public static func isGoing(in view: NoteTextView? = nil) -> Bool {
        guard let current else { return false }
        return view == nil || current.view === view
    }

    /// Starts listening, writing into a note at its caret — at its end,
    /// if it has no caret. Asks, the first time, to hear. Says whether it
    /// started; `false` when not allowed, or nothing can hear.
    @discardableResult
    public static func start(in view: NoteTextView) async -> Bool {
        if let current { await current.finish() }
        guard await Dictation.allowed(), view.window != nil else { return false }
        let dictation = NoteDictation(view: view)
        do {
            try dictation.begin()
        } catch {
            dictation.glow.end(keepingLight: false)
            return false
        }
        current = dictation
        NotificationCenter.default.post(name: changed, object: view)
        return true
    }

    /// Stops the dictation going on, keeping what was said. Answers what was written.
    @discardableResult
    public static func stop() async -> String {
        guard let current else { return "" }
        return await current.finish()
    }

    /// Stops the dictation going on, and takes back what it wrote.
    public static func cancel() {
        current?.giveUp()
    }

    /// Writes words into a note as if they were being said, with no one
    /// listening: each of `heard` in turn, as what has been heard so far.
    /// For seeing that words go in where they should, and are lit.
    public static func rehearse(in view: NoteTextView, heard: [String]) {
        let dictation = NoteDictation(view: view)
        for words in heard { dictation.typist.flush(words) }
    }

    private init(view: NoteTextView) {
        self.view = view
        let text = (view.noteStorage?.string ?? "") as NSString
        // Where the caret is — or, for a note not being written in, at its end.
        var at = view.caret
        if !view.isWriting { at = NSRange(location: text.length, length: 0) }
        at.location = min(at.location, text.length)
        at.length = min(at.length, text.length - at.location)
        range = at
        let before = at.location > 0 ? text.character(at: at.location - 1) : 32
        lead = before == 32 || before == 10 || before == 9 || before == 0x2028 ? "" : " "
        let after = NSMaxRange(at) < text.length ? text.character(at: NSMaxRange(at)) : 10
        trail = after == 32 || after == 10 || after == 9 || after == 0x2028 || CharacterSet.punctuationCharacters.contains(Unicode.Scalar(after) ?? " ") ? "" : " "
        tail = DictatedSpan.tail(after: at, in: text)
        glow = DictationGlow(on: view, accent: view.dictationAccent)
        typist = DictationTypist { [weak self] heard in self?.show(heard) }
        glow.listen(at: at.location)
    }

    private func begin() throws {
        dictation.onEngine = { [weak self] engine in
            self?.engine = engine
            NotificationCenter.default.post(name: Self.changed, object: self?.view)
        }
        try dictation.start(keyterms: Self.keyterms()) { [weak self] heard in self?.typist.type(heard) }
    }

    /// Stopped: the last of it written down, and put in its place.
    @discardableResult
    private func finish() async -> String {
        guard !ended else { return "" }
        ended = true
        if Self.current === self { Self.current = nil }
        NotificationCenter.default.post(name: Self.changed, object: view)
        let said = await dictation.stop()
        typist.flush(said)
        glow.end()
        settle()
        if let view, view.isWriting { view.caret = NSRange(location: max(NSMaxRange(range) - (trail as NSString).length, range.location), length: 0) }
        return said
    }

    /// Given up on: what was put in taken out again.
    private func giveUp() {
        guard !ended else { return }
        ended = true
        if Self.current === self { Self.current = nil }
        dictation.cancel()
        typist.flush("")
        glow.end(keepingLight: false)
        NotificationCenter.default.post(name: Self.changed, object: view)
    }

    /// Where what was said stands now: the note may have changed it since.
    private func settle() {
        guard let text = view?.noteStorage?.string else { return }
        range = DictatedSpan.span(from: range.location, tail: tail, in: text as NSString)
    }

    private func show(_ heard: String) {
        settle()
        guard let view, let storage = view.noteStorage, NSMaxRange(range) <= storage.length else { return }
        let text = heard.isEmpty ? "" : lead + heard + trail
        let was = (storage.string as NSString).substring(with: range)
        guard text != was else { return }
        view.write(text, in: range)
        settle()
        guard NSMaxRange(range) <= (view.noteStorage?.length ?? 0) else { return }
        let now = ((view.noteStorage?.string ?? "") as NSString).substring(with: range)
        let same = (was as NSString).commonPrefix(with: now, options: []).utf16.count
        let space = (trail as NSString).length
        glow.wrote(NSRange(location: range.location + same, length: max(range.length - same - space, 0)))
        glow.listen(at: max(NSMaxRange(range) - space, range.location))
    }
}
