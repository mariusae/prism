import Foundation
import Prism

/// Topic notes: a note whose work is to gather what links to it —
/// "Idle Thoughts", "Machine Learning" — marked `topic: true` in its
/// frontmatter. A topic is gone to as a river is: its river, the topic
/// kept at the top, and under it every note that links to it, each shown
/// where it speaks of it — a query river of `links to:` it. Unnamed, the
/// river is this device's own and called by the topic; named, it is saved
/// as any query river is, and is the topic's home.
extension GraphStore {
    /// The frontmatter field that makes a note a topic.
    static let topicKey = "topic"

    /// Whether a note is a topic.
    public func isTopic(_ path: String) -> Bool {
        _ = collectionsRevision
        if let draft = openDraft(path: path) { return draft.isMarked(Self.topicKey) }
        return topics.contains(path)
    }

    /// Makes a note a topic — and goes to its river — or makes it a note again.
    public func toggleTopic(path: String, title: String) {
        guard NotePath.isNote(path), !path.hasPrefix("daily/"), !path.hasPrefix("weekly/") else { return }
        let draft = draft(path: path, title: title)
        let now = !draft.isMarked(Self.topicKey)
        draft.setField(Self.topicKey, values: now ? ["true"] : [])
        draft.saveNow()
        if now { topics.insert(path) } else { topics.remove(path) }
        touchCollections()
        note("topic", now ? "Made “\(draft.label)” a topic" : "“\(draft.label)” is no longer a topic")
        if now { openTopic(path: path, title: title) }
    }

    /// The topic a river is of, if it is a topic's: one made of what links
    /// to the topic — by `links to:` in its query — that holds the topic.
    public func topic(of river: River) -> String? {
        let page = river.mentions ?? river.query.flatMap { linkedTo(by: $0) }
        guard let page, isTopic(page), river.mentions == page || river.cards.contains(where: { $0.path == page }) else { return nil }
        return page
    }

    /// The query of a topic's river.
    static func topicQuery(_ name: String) -> String { "links to: \(name)\nsort: -modified" }

    /// Goes to a topic's river — open already, saved as its home, or made —
    /// with the topic kept at its top, and shown.
    public func openTopic(path: String, title: String) {
        leaving()
        if let index = rivers.firstIndex(where: { topic(of: $0) == path || ($0.mentions == path && $0.name == nil) }) {
            currentRiver = index
        } else if let home = home(of: path), let saved = (try? engine.river(name: home)) ?? nil,
                  saved.query.flatMap({ linkedTo(by: $0) }) == path {
            openSaved(home)
        } else {
            let made = River()
            made.query = Self.topicQuery(Prism.linkName(path: path) ?? title)
            // A river made with nothing in it is taken over, not set beside.
            if river.cards.isEmpty, river.name == nil, river.query == nil, !river.isStyled { rivers[currentRiver] = made } else {
                rivers.append(made)
                currentRiver = rivers.count - 1
            }
        }
        let river = self.river
        // Each note in it shown where it speaks of the topic, and open to begin with.
        if river.mentions == nil { river.mentions = path }
        var top = Card(path: path, title: title)
        top.pinned = true
        if let index = river.cards.firstIndex(where: { $0.path == path && $0.focus == nil }) {
            if !river.cards[index].pinned { river.togglePin(river.cards[index].id) }
            river.cards[index].lens = nil
            river.reveal(river.cards[index].id)
        } else {
            river.open(top, after: nil)
        }
        find(for: river)
        rememberRivers()
    }

    /// What a query river finds, in a few words — a topic's river saying
    /// the topic by its title, not by the name its file has.
    public func querySummary(of river: River) -> String {
        var spec = QuerySpec(body: river.query ?? "")
        if let topic = topic(of: river) {
            spec.linksTo = label(path: topic, title: river.cards.first { $0.path == topic }?.title ?? Prism.linkName(path: topic) ?? topic)
        }
        return spec.summary
    }
}
