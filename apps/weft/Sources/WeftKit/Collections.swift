import Prism
import SwiftUI

/// How notes are sorted out, in three kinds, each its own question:
///
/// - **Tags** say what a note is, or is about: `#person`, `#link`.
/// - **Rivers** are what is being done with notes: working sets, held by
///   hand or found by a query. *Pinned* and *Inbox* are two such: saved
///   rivers, `rivers/Pinned.md` and `rivers/Inbox.md` — a note pinned is a
///   card of the one, a page shared to read a card of the other.
/// - **States** are where a note is in its life, and change how it is
///   treated everywhere: `task: todo | done`, `snoozed_until:`, and
///   `archived: true` — kept as it is, out of the way: dimmed, found
///   after the rest, left out of queries unless they ask.
extension GraphStore {
    /// The saved river a note is pinned by being in.
    public static let pinnedRiver = "Pinned"
    /// The saved river of what is waiting to be read.
    public static let inboxRiver = "Inbox"

    // MARK: Pinned and Inbox

    /// Whether a note is a card of a saved river — of the tab that has it
    /// open, if one does, as it is now.
    public func isIn(_ river: String, path: String) -> Bool {
        _ = indexRevision
        if let open = rivers.first(where: { $0.name == river }) { return open.cards.contains { $0.path == path && $0.focus == nil } }
        return members(of: river).contains(path)
    }

    public func isPinned(_ path: String) -> Bool { isIn(Self.pinnedRiver, path: path) }
    public func isInInbox(_ path: String) -> Bool { isIn(Self.inboxRiver, path: path) }

    /// The notes a saved river holds, as paths, in its order.
    func members(of river: String) -> [String] {
        let saved = (try? engine.river(name: river)) ?? nil
        return saved?.cards.filter { $0.focus == nil }.map { path(named: $0.title) } ?? []
    }

    /// A note put into a saved river — at its head, or its foot — or taken
    /// out of it: the tab that has it open, or its file. Made if there is
    /// none yet.
    public func setIn(_ river: String, path: String, title: String, _ isIn: Bool, atEnd: Bool = false) {
        guard self.isIn(river, path: path) != isIn else { return }
        if let open = rivers.first(where: { $0.name == river }) {
            if isIn {
                let card = Card(path: path, title: title)
                if atEnd { open.cards.append(card) } else { open.cards.insert(card, at: 0) }
            } else {
                open.cards.removeAll { $0.path == path && $0.focus == nil }
            }
            save(open)
            rememberRivers()
        } else {
            var saved = ((try? engine.river(name: river)) ?? nil)
                ?? SavedRiver(cards: [], query: nil, placed: [], folded: [], opened: [], hidden: [], icon: nil, color: nil, place: nil)
            let name = linkName(path: path, title: title)
            if isIn {
                let card = RiverCard(title: name, focus: nil, foldedRows: [], placeRank: nil, placeKey: nil)
                if atEnd { saved.cards.append(card) } else { saved.cards.insert(card, at: 0) }
            } else {
                saved.cards.removeAll { $0.focus == nil && self.path(named: $0.title) == path }
            }
            _ = try? engine.saveRiver(name: river, river: saved)
            noteSaved(river)
            if !savedRivers.contains(where: { $0.name == river }) { refreshSavedRivers() }
        }
        touchCollections()
    }

    public func togglePinned(path: String, title: String) {
        let now = !isPinned(path)
        setIn(Self.pinnedRiver, path: path, title: title, now, atEnd: true)
        undoable(now ? "Pinned" : "Unpinned") { [weak self] in self?.setIn(Self.pinnedRiver, path: path, title: title, !now, atEnd: true) }
    }

    public func toggleInbox(path: String, title: String) {
        let now = !isInInbox(path)
        setIn(Self.inboxRiver, path: path, title: title, now)
        undoable(now ? "Added to the Inbox" : "Out of the Inbox") { [weak self] in self?.setIn(Self.inboxRiver, path: path, title: title, !now) }
    }

    /// Moves the index's revision on, for what reads a river's membership.
    private func touchCollections() { collectionsRevision += 1 }

    // MARK: Archived

    /// Whether a note is archived: kept as it is, out of the way.
    public func isArchived(_ path: String) -> Bool {
        _ = collectionsRevision
        return archived.contains(path)
    }

    /// Archives a note, or brings it back; for a moment, undone as easily.
    public func toggleArchived(path: String, title: String) {
        guard !path.hasPrefix("daily/"), !path.hasPrefix("weekly/") else { return }
        let draft = draft(path: path, title: title)
        let now = !draft.isMarked("archived")
        draft.setField("archived", values: now ? ["true"] : [])
        draft.saveNow()
        if now { archived.insert(path) } else { archived.remove(path) }
        touchCollections()
        undoable(now ? "Archived “\(draft.label)”" : "Unarchived “\(draft.label)”") { [weak self] in
            guard let self else { return }
            let draft = self.draft(path: path, title: title)
            draft.setField("archived", values: now ? [] : ["true"])
            draft.saveNow()
            if now { self.archived.remove(path) } else { self.archived.insert(path) }
            self.touchCollections()
        }
    }

    // MARK: From the old marks

    /// Notes marked `pinned:` and `inbox:` in their frontmatter, as Reflect
    /// marked them, made cards of the Pinned and Inbox rivers — pinned in
    /// the order the marks gave, the inbox newest first — and the marks,
    /// and `wiki:`, taken out of the notes. Says how many notes it changed.
    @discardableResult
    public func convertOldMarks() -> Int {
        let ask = { (body: String) in (try? self.engine.runQuery(body: body + "\ninclude: archived\nlimit: 100000", this: nil).pages) ?? [] }
        let pinned = ask("is: pinned\nsort: pinned")
        let inbox = ask("is: inbox\nsort: -modified")
        let wiki = ask("is: wiki")
        // A river of these that found them by their marks — Inbox as `is: inbox` — holds them by hand from now on.
        for (river, mark) in [(Self.inboxRiver, "inbox"), (Self.pinnedRiver, "pinned")] {
            guard var saved = (try? engine.river(name: river)) ?? nil, let query = saved.query, query.contains("is: \(mark)") else { continue }
            saved.query = nil
            saved.hidden = []
            saved.opened = []
            _ = try? engine.saveRiver(name: river, river: saved)
            if let open = rivers.first(where: { $0.name == river }) { open.query = nil }
        }
        for page in pinned { setIn(Self.pinnedRiver, path: page.path, title: page.title, true, atEnd: true) }
        for page in inbox.reversed() { setIn(Self.inboxRiver, path: page.path, title: page.title, true) }
        var changed = Set<String>()
        for page in pinned + inbox + wiki where !changed.contains(page.path) {
            guard let text = (try? engine.read(path: page.path)) ?? nil else { continue }
            let editor = NoteEditor.open(source: text, mode: .text)
            for key in ["pinned", "inbox", "wiki"] { _ = editor.removeField(key: key) }
            let out = editor.markdown()
            if out != text, (try? engine.write(path: page.path, content: out)) != nil {
                changed.insert(page.path)
                openDraft(path: page.path)?.fileChanged()
            }
        }
        note("marks", "Made \(pinned.count) pinned and \(inbox.count) inbox notes cards of their rivers; \(changed.count) notes rewritten")
        touchCollections()
        return changed.count
    }
}

/// "Archived", small, beside an archived note's title.
struct ArchivedLabel: View {
    var body: some View {
        Label("Archived", systemImage: "archivebox")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.inkSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.inkText.opacity(0.07)))
            .fixedSize()
    }
}
