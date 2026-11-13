#if os(iOS)
import Prism
import SwiftUI

/// Weft Reader: the inbox's links, read one at a time — the oldest first,
/// and nothing else. Done with, the next; put off, back later. Its graph
/// is its own copy of the same repository, synced as Weft's is; it signs
/// in with Weft's sign-in, which the two share.
public struct ReaderRoot: View {
    private let session = PhoneSession.shared
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        Group {
            if let store = session.store, session.onboarded || PhoneSession.isTrial {
                ReaderQueue(store: store)
            } else {
                ReaderWelcome()
            }
        }
        .tint(Color.inkAccent)
        .foregroundStyle(Color.inkText)
        .onAppear { session.open() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: session.activated()
            case .inactive, .background: session.resigned()
            @unknown default: break
            }
        }
    }
}

/// Before there is a graph: what the app is, and bringing the graph down —
/// signed in already, when Weft is.
struct ReaderWelcome: View {
    private let session = PhoneSession.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "book.pages").font(.system(size: 44, weight: .light)).foregroundStyle(Color.inkAccent)
                Text("Weft Reader").font(.largeTitle.weight(.semibold))
                Text("The links in your inbox, read one at a time — the oldest first.")
                    .foregroundStyle(Color.inkSecondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            .padding(.top, 48)
            .padding(.bottom, 12)
            GitHubConnect { session.onboarded = true }
                .frame(maxWidth: 560, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background(Color.inkPage.ignoresSafeArea())
    }
}

/// The queue: its first note in the reader, and nothing else. The one
/// begun stays in front till it is done with or put off — whatever older
/// comes back from being put off meanwhile — across launches too.
struct ReaderQueue: View {
    let store: GraphStore
    @State private var pages: [PageInfo] = []
    @State private var next: Date?
    @State private var loaded = false
    /// The note begun: this app's own, kept across launches.
    @AppStorage("Reader.begun") private var begun = ""

    private var current: PageInfo? { pages.first { $0.path == begun } ?? pages.first }

    var body: some View {
        Group {
            if let page = current {
                ReaderPanel(store: store, place: River.Place(path: page.path, title: page.title)) { snooze in finish(page, snooze) }
                    .id(page.path)
                    .onAppear { begun = page.path }
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            } else if loaded {
                rest
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.inkCard.ignoresSafeArea())
        .overlay(alignment: .bottom) { PhoneUndo(store: store).padding(.bottom, 84) }
        // Found again whenever the graph moves: a sync brought more, or a note was done with.
        .task(id: store.indexRevision) { refresh() }
        // Nothing to read, and something put off: shown again when it comes back.
        .task(id: next) {
            guard current == nil, let next, next > Date() else { return }
            try? await Task.sleep(for: .seconds(min(next.timeIntervalSinceNow + 1, 24 * 3600)))
            if !Task.isCancelled { refresh() }
        }
    }

    private var rest: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light)).foregroundStyle(Color.inkSecondary)
                .padding(.bottom, 6)
            Text("All Read").font(.title2.weight(.semibold))
            Text(ReadingQueue.restDetail(next: next))
                .font(.callout).foregroundStyle(Color.inkSecondary).multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }

    private func refresh() {
        let queue = store.readingQueue()
        withAnimation(.snappy(duration: 0.3)) {
            pages = queue.pages
            next = queue.next
            loaded = true
        }
    }

    /// Done with, or put off: out of the queue, and the next in front.
    private func finish(_ page: PageInfo, _ snooze: ReadingQueue.Snooze?) {
        store.finishReading(path: page.path, title: page.title, snooze: snooze)
        begun = ""
        // Out of the queue at once, ahead of the index catching up with the note.
        withAnimation(.snappy(duration: 0.3)) { pages.removeAll { $0.path == page.path } }
    }
}
#endif
