#if os(iOS)
import Prism
import PrismEmblem
import SwiftUI
import UIKit

/// What the shell is showing over the river, if anything.
@MainActor
@Observable
final class PhoneState {
    enum Start: Identifiable {
        /// To look around: the rivers, what was written last.
        case browse
        /// To find a note or name a new one, the keyboard up at once.
        case add
        var id: Int { self == .browse ? 0 : 1 }
    }

    var start: Start?
    var showsOverview = false
    /// Whether the river shown is seen whole: its cards as tiles.
    var showsCards = false
    var showsSettings = false
    /// The bar drawn small, while the river is read down.
    var tucked = false
    var keyboardUp = false
    /// How far the river has been dragged aside, on its way to the next.
    var swipe: CGFloat = 0
    /// The river being named.
    var naming: River?
    var name = ""
}

/// Weft on the phone: one river at a time, the next a swipe of the bar
/// away, and everything else reached from the one glass bar at the foot.
struct PhoneShell: View {
    let store: GraphStore
    @State private var state = PhoneState()

    var body: some View {
        GeometryReader { room in
            let width = room.size.width
            ZStack {
                (Color.inkPage).overlay(Color.black.opacity(0.08)).ignoresSafeArea()
                // The river shown — and, while it is dragged aside, those beside it.
                ForEach(shown, id: \.river.id) { place, river in
                    RiverColumn(store: store, river: river, state: state, isCurrent: place == 0)
                        .frame(width: width)
                        .background(Color.inkPage)
                        .offset(x: CGFloat(place) * (width + 14) + state.swipe)
                        .zIndex(place == 0 ? 1 : 0)
                }
                // Past the last river: a new one, waiting.
                if state.swipe < 0, store.currentRiver == store.rivers.count - 1 {
                    VStack(spacing: 10) {
                        Image(systemName: "plus.square.on.square").font(.system(size: 34))
                        Text("New River").font(.headline)
                    }
                    .foregroundStyle(Color.inkSecondary)
                    .frame(width: width)
                    .offset(x: width + 14 + state.swipe)
                }
            }
            .environment(\.riverWidth, width)
        }
        .foregroundStyle(Color.inkText)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in state.keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in state.keyboardUp = false }
        .fullScreenCover(item: $state.start) { mode in StartPage(store: store, mode: mode, state: state) }
        .fullScreenCover(isPresented: $state.showsOverview) { RiverOverview(store: store, state: state) }
        .fullScreenCover(isPresented: $state.showsCards) { CardsOverview(store: store, river: store.river, isShown: $state.showsCards) }
        // Pinched together, the river is seen whole.
        .simultaneousGesture(MagnifyGesture().onEnded { if $0.magnification < 0.75, !store.river.all.isEmpty { state.showsCards = true } })
        .sheet(isPresented: $state.showsSettings) { PhoneSettings(store: store) }
        // A note's pages read, over the river.
        .sheet(isPresented: Binding(get: { store.river.reading != nil }, set: { if !$0 { store.river.reading = nil } })) {
            if let reading = store.river.reading {
                ReaderPanel(store: store, river: store.river, place: reading).id(reading.path).presentationDetents([.large])
            }
        }
        .sheet(item: Binding(get: { store.queryAsk }, set: { store.queryAsk = $0 })) { ask in QueryRiverEditor(store: store, ask: ask) }
        .sheet(item: Binding(get: { store.movingRows }, set: { store.movingRows = $0 })) { moving in MoveRowsSheet(store: store, moving: moving).presentationDetents([.medium, .large]) }
        .alert(state.naming?.name == nil ? "Save River" : "Rename River", isPresented: Binding(get: { state.naming != nil }, set: { if !$0 { state.naming = nil } })) {
            TextField("Name", text: $state.name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let river = state.naming { store.rename(river, to: state.name) } }
        } message: {
            Text("A named river is kept in the graph, on every device.")
        }
        .sensoryFeedback(.selection, trigger: store.currentRiver)
    }

    /// The rivers on screen, each with its place: 0 the one shown, ±1 its neighbours while it is dragged.
    private var shown: [(place: Int, river: River)] {
        let current = min(max(store.currentRiver, 0), store.rivers.count - 1)
        var all = [(0, store.rivers[current])]
        if state.swipe > 0, current > 0 { all.append((-1, store.rivers[current - 1])) }
        if state.swipe < 0, current + 1 < store.rivers.count { all.append((1, store.rivers[current + 1])) }
        return all
    }
}

private struct RiverWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 390 }
extension EnvironmentValues {
    var riverWidth: CGFloat {
        get { self[RiverWidthKey.self] }
        set { self[RiverWidthKey.self] = newValue }
    }
}

/// One river: its cards one after another, read down.
struct RiverColumn: View {
    let store: GraphStore
    let river: River
    let state: PhoneState
    let isCurrent: Bool
    @State private var travelled: CGFloat = 0
    @State private var lastY: CGFloat = 0
    @State private var byHand = false
    @State private var carried: Card.ID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if river.all.isEmpty, river.query == nil {
                    ContentUnavailableView("Nothing Open", systemImage: "rectangle.stack", description: Text("Tap the river\u{2019}s name below to find a note, or + to start one."))
                        .padding(.top, 120)
                } else {
                    LazyVStack(spacing: 0) {
                        if let query = river.query {
                            Button { store.queryAsk = .edit(river) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(river.emblem.color?.color ?? Color.inkSecondary)
                                    Text(QuerySpec(body: query).summary).font(.footnote).foregroundStyle(Color.inkSecondary).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text("Edit").font(.footnote.weight(.medium)).foregroundStyle(Color.inkAccent)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.inkPaper))
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, Measures.foldedGap)
                        }
                        ForEach(river.all) { card in
                            PhoneCard(store: store, river: river, card: card)
                                .opacity(carried == card.id ? 0.45 : 1)
                                .onDrop(of: [PhoneCardMove.type], delegate: PhoneCardMove(target: card.id, river: river, store: store, carried: $carried))
                                .environment(\.carriedCard, $carried)
                                .padding(.bottom, card.folded ? Measures.foldedGap : Measures.cardGap)
                                .id(card.id)
                                .transition(.poof)
                        }
                    }
                    .padding(.horizontal, Measures.riverSides)
                    .padding(.vertical, Measures.riverEnds)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                    .animation(.snappy(duration: 0.28), value: river.all.map(\.id))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { _ = await store.syncAndWait() }
            // Pinched together, every card folds; apart, every one opens.
            .simultaneousGesture(MagnifyGesture().onEnded { pinch in
                if pinch.magnification < 0.8 { withAnimation(.snappy(duration: 0.3)) { river.setAllFolded(true) } }
                if pinch.magnification > 1.25 { withAnimation(.snappy(duration: 0.3)) { river.setAllFolded(false) } }
                store.rememberRivers()
            })
            .onScrollPhaseChange { _, phase in byHand = phase == .interacting || phase == .decelerating }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in follow(y) }
            // A card closed or folded: what is left is brought into sight, once it has settled.
            .onChange(of: river.settleTarget?.tick) { _, _ in
                guard let target = river.settleTarget?.card else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard river.card(target) != nil else { return }
                    withAnimation(.snappy(duration: 0.24)) { proxy.scrollTo(target) }
                }
            }
            .onChange(of: river.scrollTarget?.tick) { _, _ in
                guard let target = river.scrollTarget?.card else { return }
                // To the top of what shows — under the clock, not behind it.
                let top = UnitPoint(x: 0.5, y: 0.08)
                withAnimation(.snappy(duration: 0.24)) { proxy.scrollTo(target, anchor: top) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { withAnimation(.snappy(duration: 0.14)) { proxy.scrollTo(target, anchor: top) } }
            }
            .task(id: "\(store.indexRevision)|\(river.query ?? "")|\(river.hidden.count)|\(river.cards.count)") { store.find(for: river) }
            .task(id: carried) {
                guard carried != nil else { return }
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { carried = nil }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: river.all.filter(\.folded).count)
            .sensoryFeedback(.impact(weight: .light), trigger: river.all.count)
            .safeAreaInset(edge: .bottom) {
                if isCurrent {
                    VStack(spacing: 8) {
                        SyncNotice(store: store)
                        PhoneUndo(store: store)
                        if !state.keyboardUp, river.writing == nil { PhoneBar(store: store, state: state) }
                    }
                    .padding(.bottom, 4)
                    .animation(.spring(duration: 0.38, bounce: 0.12), value: state.tucked)
                }
            }
        }
    }

    /// The bar tucks away as the river is read down by hand, and comes back as it is read up.
    private func follow(_ y: CGFloat) {
        defer { lastY = y }
        if y < 40 {
            travelled = 0
            if state.tucked { state.tucked = false }
            return
        }
        guard byHand else { return }
        let step = y - lastY
        travelled = (step > 0) == (travelled > 0) ? travelled + step : step
        if travelled > 24, !state.tucked { state.tucked = true }
        if travelled < -12, state.tucked { state.tucked = false }
    }
}

/// At the river's foot, a moment: syncing, then what the sync did.
struct SyncNotice: View {
    let store: GraphStore
    @State private var said: String?
    @State private var failed = false

    var body: some View {
        Syncing(store: store) { syncing in
            Group {
                if syncing, said == nil {
                    capsule {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: true)
                            .foregroundStyle(Color.inkAccent)
                        Text("Syncing…")
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let said {
                    capsule {
                        Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(failed ? .orange : .green)
                        Text(said).lineLimit(1)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: said)
            .animation(.snappy(duration: 0.25), value: syncing)
        }
        .onChange(of: store.lastSync) { _, _ in
            guard let report = store.lastReport, report.pulled > 0 || report.pushed else { return }
            show(report.pulled > 0 ? (report.pushed ? "Brought in \(report.pulled) changes, sent yours" : "Brought in \(report.pulled) changes") : "Sent your changes", failed: false)
        }
        .onChange(of: store.needsSignIn) { _, needs in if needs { show("Couldn\u{2019}t sync: sign in again", failed: true) } }
    }

    private func show(_ text: String, failed: Bool) {
        said = text
        self.failed = failed
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if said == text { said = nil }
        }
    }

    private func capsule<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(.footnote)
            .foregroundStyle(Color.inkSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// At the river's foot, a moment: what was just done, and Undo.
struct PhoneUndo: View {
    let store: GraphStore

    var body: some View {
        Group {
            if let offer = store.undoOffer {
                HStack(spacing: 12) {
                    Text(offer.said).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.inkSecondary)
                    Button("Undo") { withAnimation(.snappy) { _ = store.takeUndo() } }
                        .fontWeight(.semibold)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.inkAccent)
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
                .id(offer.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: store.undoOffer?.id)
    }
}

/// The glass bar at the foot: find, the river's name with everything
/// else behind its ⋯, and new. Dragged sideways it turns the river;
/// dragged up, it shows them all.
struct PhoneBar: View {
    let store: GraphStore
    let state: PhoneState
    @Environment(\.riverWidth) private var width
    @Namespace private var glass
    /// + held: what is said, into a new note.
    @State private var held = HeldDictation()
    /// + pressed, and since when: held long enough, dictating.
    @State private var pressed: Task<Void, Never>?
    /// + held long enough: let go, not a tap, even when it couldn't listen.
    @State private var wasHeld = false
    /// How long + is held, still, to be listening.
    private static let hold = 0.2
    /// A month of days, to go to one.
    @State private var showsCalendar = false
    /// The river's name held: its notes, to sweep to and let go on.
    @State private var jump: JumpList.Shown?
    /// The name was just held: its being let go is no tap.
    @State private var wasJumping = false
    /// Where the finger holding the name is, in the name's own room: nothing, once it is lifted.
    @GestureState private var sweepAt: CGPoint?

    private var river: River { store.river }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            if state.tucked {
                // Tucked: the river's name alone, small — tapped, the bar is back.
                Text(store.title(of: river))
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .frame(maxWidth: width * 0.6)
                    .fixedSize()
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("name", in: glass)
                    .offset(y: 14)
                    .onTapGesture { state.tucked = false }
                    .gesture(DragGesture(minimumDistance: 12).onEnded { drag in
                        if drag.translation.height > 18, abs(drag.translation.height) > abs(drag.translation.width) {
                            withAnimation(.snappy(duration: 0.3)) { river.setAllFolded(true) }
                            store.rememberRivers()
                        }
                    })
                    .foregroundStyle(Color.inkSecondary)
            } else {
                HStack(spacing: 8) {
                    Button { state.start = .add } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold)).frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("find", in: glass)
                    .highPriorityGesture(turning)
                    HStack(spacing: 0) {
                        more
                        Button { if !wasJumping { state.start = .browse } } label: {
                            HStack(spacing: 6) {
                                let emblem = Emblem(title: store.title(of: river), icon: river.icon, color: river.color, letter: false)
                                if emblem.isShown { EmblemView(emblem, size: 15, style: .plain, quiet: Color.inkSecondary) }
                                Text(store.title(of: river)).font(.callout.weight(.semibold)).lineLimit(1).foregroundStyle(Color.inkText)
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Color.clear.frame(width: 46, height: 48)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("name", in: glass)
                    // Before the taps on it: a drag turns the river, and opens nothing —
                    // but not while the name is held, when the finger's sweep is the list's.
                    .highPriorityGesture(turning, including: wasJumping ? .subviews : .all)
                    // Held still, then swept: the river's notes, and the one let go on.
                    .simultaneousGesture(holding)
                    .onChange(of: sweepAt) { before, now in
                        switch (before, now) {
                        case (nil, let at?): sweep(.began(at))
                        case (_?, let at?): sweep(.moved(at))
                        case (_?, nil): sweep(.ended)
                        case (nil, nil): break
                        }
                    }
                    new.glassEffectID("new", in: glass)
                }
                .frame(height: 48)
                .padding(.horizontal, 14)
                .foregroundStyle(Color.inkAccent)
            }
        }
        // Over it while + is held, what is heard as it comes; or, for a
        // moment, why it can't listen.
        .overlay(alignment: .bottom) {
            // What is said is written in the note itself: over the bar is only how to end it.
            if let said = held.problem ?? (held.listening ? "Let go to keep it, or slide up to give it up." : nil) {
                HeardBubble(text: said, quiet: held.problem == nil)
                    .padding(.horizontal, 14)
                    // Its foot a little above the bar's top.
                    .padding(.bottom, 48 + 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: held.problem != nil || held.listening)
        // Over it while the river's name is held: the river's notes.
        .overlay(alignment: .bottom) {
            if let jump {
                JumpList(shown: jump)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 48 + JumpList.gap)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .animation(.snappy(duration: 0.18), value: jump != nil)
        .fullScreenCover(isPresented: $showsCalendar) {
            BottomCard {
                CalendarPopover(store: store) { title in
                    showsCalendar = false
                    state.tucked = false
                    withAnimation(.snappy(duration: 0.28)) { store.open(name: title, after: river.selected) }
                }
            }
        }
        // Something came over the app — asked whether it may listen, a call — and the finger's lifting may never be told: given up.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            pressed?.cancel()
            pressed = nil
            if held.listening { held.end(cancelled: true, store: store) }
        }
    }

    /// A new note, at a tap. Held, a microphone: what is said is heard,
    /// and let go, kept as a new note — or, slid well up from the + first,
    /// given up.
    private var new: some View {
        Image(systemName: held.listening ? "mic.fill" : "plus")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(held.listening ? Color.red : Color.inkAccent)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 48, height: 48)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
            // UIKit's, not SwiftUI's: told the moment the finger lands, so
            // that the hold is as long as it says.
            .gesture(Press { phase in
                switch phase {
                case .down:
                    guard pressed == nil, !held.listening else { return }
                    wasHeld = false
                    // Held still a moment: listening.
                    pressed = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(Self.hold))
                        guard !Task.isCancelled else { return }
                        wasHeld = true
                        held.begin(store: store)
                    }
                case .up(let moved):
                    pressed?.cancel()
                    pressed = nil
                    if held.listening {
                        held.end(cancelled: moved.height < -80, store: store)
                    } else if !wasHeld, abs(moved.width) < 20, abs(moved.height) < 20 {
                        withAnimation(.snappy(duration: 0.28)) { _ = store.newNote() }
                    }
                case .taken:
                    // Taken away — an alert over it, a call: given up.
                    pressed?.cancel()
                    pressed = nil
                    if held.listening { held.end(cancelled: true, store: store) }
                }
            })
            .accessibilityElement()
            .accessibilityLabel("New Note")
            .accessibilityHint("Hold to dictate a new note")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation(.snappy(duration: 0.28)) { _ = store.newNote() } }
    }

    /// The name held still a moment, and then wherever the finger goes.
    private var holding: some Gesture {
        LongPressGesture(minimumDuration: 0.3, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .updating($sweepAt) { value, at, _ in
                if case .second(true, let drag) = value { at = drag?.location ?? CGPoint(x: 0, y: 24) }
            }
    }

    /// The river's name held, and the finger swept over its notes: let
    /// go on one, the river goes to it. `at` is in the name's own room:
    /// above it is less than nothing.
    private func sweep(_ phase: HoldSweep.Phase) {
        switch phase {
        case .began(let at):
            let cards = river.all
            guard !cards.isEmpty else { return }
            wasJumping = true
            state.swipe = 0
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let room = (UIScreen.main.bounds.height * 0.62 / JumpList.row).rounded(.down) * JumpList.row
            var shown = JumpList.Shown(
                rows: cards.map { JumpList.Row(id: $0.id, label: store.label(path: $0.path, title: $0.title), emblem: store.emblem(path: $0.path, title: $0.title)) },
                height: min(CGFloat(cards.count) * JumpList.row, room), here: river.selected
            )
            shown.point(at.y)
            jump = shown
        case .moved(let at):
            guard var shown = jump else { return }
            let before = shown.chosen
            shown.point(at.y)
            if shown.chosen != before, shown.chosen != nil { UISelectionFeedbackGenerator().selectionChanged() }
            jump = shown
        case .ended:
            if let shown = jump, let chosen = shown.chosen, shown.rows.indices.contains(chosen) {
                let id = shown.rows[chosen].id
                state.tucked = false
                withAnimation(.snappy(duration: 0.3)) { river.reveal(id) }
                store.rememberRivers()
            }
            jump = nil
            // The button under the finger hears of the lifting after this does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { wasJumping = false }
        case .taken:
            jump = nil
            wasJumping = false
        }
    }

    /// The bar dragged: the river follows the finger, and past the middle
    /// gives way to the next. Dragged up, the rivers are all shown.
    private var turning: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { drag in
                // The name is held, and its notes swept over: the river stays where it is.
                guard !wasJumping else { return }
                guard abs(drag.translation.width) >= abs(drag.translation.height) else { return }
                var x = drag.translation.width
                // Before the first river there is nothing: it gives a little, and no more.
                if x > 0, store.currentRiver == 0 { x /= 3 }
                if x < 0, store.currentRiver == store.rivers.count - 1, river.all.isEmpty, river.query == nil { x /= 3 }
                state.swipe = x
            }
            .onEnded { drag in
                guard !wasJumping else { return }
                if drag.translation.height < -24, abs(drag.translation.height) > abs(drag.translation.width) {
                    state.swipe = 0
                    state.showsOverview = true
                    return
                }
                let x = drag.translation.width, thrown = drag.predictedEndTranslation.width
                let step = x < 0 ? 1 : -1
                let past = abs(x) > width * 0.4 || (abs(thrown) > width * 0.5 && (thrown < 0) == (x < 0))
                let to = store.currentRiver + step
                guard past, abs(x) >= abs(drag.translation.height), to >= 0, to < store.rivers.count || !(river.all.isEmpty && river.query == nil) else {
                    withAnimation(.interpolatingSpring(stiffness: 260, damping: 28)) { state.swipe = 0 }
                    return
                }
                // The next river slides in the rest of the way: it is shown from where the finger left it.
                let page = width + 14
                if to >= store.rivers.count { store.newRiver() } else { store.currentRiver = to }
                state.swipe = x + CGFloat(step) * page
                withAnimation(.interpolatingSpring(stiffness: 260, damping: 30)) { state.swipe = 0 }
                state.tucked = false
            }
    }

    private var syncSaid: String {
        switch store.sync {
        case .idle: return "Not synced yet"
        case .syncing: return "Syncing…"
        case .synced(let at): return "Synced \(Date(timeIntervalSince1970: at).formatted(.relative(presentation: .named)))"
        case .failed(let message, _, _): return "Last sync failed: \(message)"
        }
    }

    private var more: some View {
        Menu {
            if !store.conflicted.isEmpty {
                Button("\(store.conflicted.count) to Review", systemImage: "exclamationmark.triangle") { for page in store.conflicted { store.open(page: page) } }
            }
            if !river.places.isEmpty {
                Menu("Back To", systemImage: "chevron.backward") {
                    ForEach(river.places) { place in
                        Button(store.label(path: place.path, title: place.title), systemImage: store.emblem(path: place.path, title: place.title).symbol ?? "doc.text") {
                            withAnimation(.snappy(duration: 0.28)) { store.goBack(to: place, in: river) }
                        }
                    }
                }
            }
            if !river.all.isEmpty { Button("Overview", systemImage: "square.grid.2x2") { state.showsCards = true } }
            if store.rivers.count > 1 { Button("All Rivers", systemImage: "square.on.square") { state.showsOverview = true } }
            Section {
                Button("Today", systemImage: "calendar") { withAnimation(.snappy(duration: 0.28)) { store.open(name: Days.name(Date()), after: river.selected) } }
                Button("Go to Date…", systemImage: "calendar.badge.clock") { showsCalendar = true }
                Button("New To-Do", systemImage: "circle") {
                    withAnimation(.snappy(duration: 0.28)) {
                        if let card = store.newNote() { store.draft(path: card.path, title: card.title).setTask(.todo) }
                    }
                }
                Button("New Note from Pasteboard", systemImage: "doc.on.clipboard") {
                    guard let text = UIPasteboard.general.string, let card = store.newNote() else { return }
                    _ = try? store.engine.write(path: card.path, content: text.hasSuffix("\n") ? text : text + "\n")
                }
                .disabled(!UIPasteboard.general.hasStrings)
                if river.all.contains(where: { !$0.folded }) {
                    Button("Fold All", systemImage: "rectangle.compress.vertical") { withAnimation(.snappy(duration: 0.3)) { river.setAllFolded(true) }; store.rememberRivers() }
                } else {
                    Button("Unfold All", systemImage: "rectangle.expand.vertical") { withAnimation(.snappy(duration: 0.3)) { river.setAllFolded(false) }; store.rememberRivers() }
                }
                Button("Close All Cards", systemImage: "rectangle.stack.badge.minus") { withAnimation(.snappy(duration: 0.28)) { store.closeAll(in: river) } }
            }
            Menu("River", systemImage: "square.stack") {
                ForEach(Array(store.rivers.enumerated()), id: \.element.id) { index, one in
                    Button { store.currentRiver = index } label: {
                        if index == store.currentRiver { Label(store.title(of: one), systemImage: "checkmark") } else { Text(store.title(of: one)) }
                    }
                }
                Section {
                    Button("New River", systemImage: "plus") { store.newRiver() }
                    Button(river.name == nil ? "Save River…" : "Rename River…", systemImage: "square.and.arrow.down") {
                        state.name = river.name ?? ""
                        state.naming = river
                    }
                    if let name = river.name {
                        Button("Copy Link to River", systemImage: "link") { UIPasteboard.general.string = "[[rivers/\(name)]]" }
                    }
                    Button("Saved Rivers…", systemImage: "tray.full") { state.start = .browse }
                }
                Section {
                    Button("New Query River…", systemImage: "line.3.horizontal.decrease.circle") { store.queryAsk = .new }
                    Button(river.query == nil ? "Fill from Query…" : "Edit River Query…", systemImage: "slider.horizontal.3") { store.queryAsk = .edit(river) }
                }
                if store.rivers.count > 1 {
                    Button("Close River", systemImage: "xmark", role: .destructive) { store.closeRiver(at: store.currentRiver) }
                }
            }
            Section {
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { store.syncNow() }
                Text(syncSaid)
                Button("Settings…", systemImage: "gearshape") { state.showsSettings = true }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).frame(width: 46, height: 48)
                .overlay(alignment: .topTrailing) {
                    if !store.conflicted.isEmpty { Circle().fill(.orange).frame(width: 7, height: 7).offset(x: -8, y: 10) }
                }
                .contentShape(Rectangle())
        }
    }
}
/// What a finger holding the river's name does.
enum HoldSweep {
    enum Phase { case began(CGPoint), moved(CGPoint), ended, taken }
}

/// A river's notes, over the bar while its name is held: the finger
/// sweeps up over them, and is let go on the one to go to. A river with
/// more notes than there is room for turns under the finger as it goes,
/// so that the whole of it is within a thumb's reach.
struct JumpList: View {
    struct Row: Identifiable, Equatable {
        var id: Card.ID
        var label: String
        var emblem: Emblem
    }

    struct Shown: Equatable {
        var rows: [Row]
        /// How tall the list is: all of its rows, or as many as there is room for.
        var height: CGFloat
        /// The card the river is at, marked.
        var here: Card.ID?
        /// The row under the finger.
        var chosen: Int?
        /// How far the rows are turned up under the list's top.
        var turned: CGFloat = 0

        /// The finger is here, measured from the top of the river's name:
        /// over the list, less than nothing by its gap and more.
        mutating func point(_ y: CGFloat) {
            let inside = y + JumpList.gap + height
            guard inside < height + JumpList.gap / 2 else {
                // Back down on the name: nothing chosen, and let go, nowhere gone.
                chosen = nil
                return
            }
            let at = min(max(inside, 0), height - 0.5)
            let whole = CGFloat(rows.count) * JumpList.row
            turned = (at / height) * max(whole - height, 0)
            chosen = min(max(Int((turned + at) / JumpList.row), 0), rows.count - 1)
        }
    }

    static let row: CGFloat = 40
    /// Between the list's foot and the bar.
    static let gap: CGFloat = 10

    let shown: Shown

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(shown.rows.enumerated()), id: \.element.id) { index, row in
                let chosen = shown.chosen == index
                HStack(spacing: 10) {
                    if row.emblem.isShown {
                        EmblemView(row.emblem, size: 15, style: .plain, quiet: chosen ? Color.white : Color.inkSecondary).frame(width: 18)
                    } else {
                        Circle().fill(row.id == shown.here ? Color.inkAccent : Color.clear).frame(width: 6, height: 6).frame(width: 18)
                    }
                    Text(row.emblem.caption(row.label)).font(.callout.weight(chosen ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                    if row.id == shown.here, row.emblem.isShown { Circle().fill(chosen ? Color.white : Color.inkAccent).frame(width: 6, height: 6) }
                }
                .padding(.horizontal, 14)
                .frame(height: Self.row)
                .foregroundStyle(chosen ? Color.white : Color.inkText)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(chosen ? Color.inkAccent : Color.clear).padding(.horizontal, 5).padding(.vertical, 2))
            }
        }
        .offset(y: -shown.turned)
        .frame(height: shown.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .allowsHitTesting(false)
    }
}
#endif
