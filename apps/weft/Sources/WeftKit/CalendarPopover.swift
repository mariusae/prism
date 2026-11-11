import Prism
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A month of days, to go to one: a dot under each day with a note; for a
/// note with tasks, how far along, as a ring about its number. Before
/// each row, its week's number — in the weeks' ochre, a dot under it
/// where the week has a note. A day or a week clicked is gone to; the
/// arrows, the arrow keys, or a scroll, go a month along.
struct CalendarPopover: View {
    let store: GraphStore
    /// A day's or a week's title chosen: `2026-11-10`, `2026-W46`.
    var choose: (String) -> Void

    @State private var month = Month(Date())
    /// The days and weeks with something written in them, by title.
    @State private var written: Set<String> = []
    /// Tasks done of all, for the days read so far that have any.
    @State private var progress: [String: (done: Int, total: Int)] = [:]
    @State private var read: Set<String> = []
    @State private var hovered: String?
    @FocusState private var focused: Bool
    #if os(macOS)
    /// How far a swipe has gone, while it lasts.
    @State private var swiped: CGFloat = 0
    #endif

    #if os(macOS)
    private static let cell: CGFloat = 40
    private static let weekColumn: CGFloat = 30
    #else
    // A finger's width, each.
    private static let cell: CGFloat = 46
    private static let weekColumn: CGFloat = 34
    #endif
    /// The weeks' own colour.
    private static let ochre = Color(red: 0.80, green: 0.62, blue: 0.27)

    /// A month: its year and month, 1 to 12.
    struct Month: Hashable {
        var year: Int
        var month: Int

        init(_ date: Date) {
            let parts = Calendar.current.dateComponents([.year, .month], from: date)
            year = parts.year ?? 2000
            month = parts.month ?? 1
        }

        init(index: Int) {
            year = index / 12
            month = index % 12 + 1
        }

        func adding(_ months: Int) -> Month { Month(index: year * 12 + (month - 1) + months) }

        private var first: Date? { Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) }

        /// `November 2026`.
        var title: String {
            guard let first else { return "" }
            let format = DateFormatter()
            format.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            return format.string(from: first)
        }

        /// Its weeks, each seven days from the calendar's first weekday:
        /// nothing before the first and after the last.
        var weeks: [[Date?]] {
            let calendar = Calendar.current
            guard let first, let count = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
            let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
            var cells: [Date?] = Array(repeating: nil, count: lead)
            cells += (0..<count).map { calendar.date(byAdding: .day, value: $0, to: first) }
            while cells.count % 7 != 0 { cells.append(nil) }
            return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
        }
    }

    /// A day's title, as its note is named.
    private static func title(_ day: Date) -> String { Days.name(day) }

    /// The week a row stands for — its Monday's, or its first day's where
    /// the month has no Monday in the row — as its note is named, and its number.
    private static func week(ofRow row: [Date?]) -> (title: String, number: Int)? {
        let iso = Calendar(identifier: .iso8601)
        let days = row.compactMap { $0 }
        guard let day = days.first(where: { iso.component(.weekday, from: $0) == 2 }) ?? days.first else { return nil }
        let (year, week) = (iso.component(.yearForWeekOfYear, from: day), iso.component(.weekOfYear, from: day))
        return (String(format: "%04d-W%02d", year, week), week)
    }

    private var weekdays: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        let weeks = month.weeks
        let today = Self.title(Date())
        let thisWeek = Self.week(ofRow: [Date()])?.title
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text(month.title).font(.system(size: 16, weight: .bold, design: TextSettings.design)).foregroundStyle(Color.inkText)
                Spacer()
                step("chevron.left", "Previous Month", -1)
                step("chevron.right", "Next Month", 1)
            }
            .padding(.leading, 8)
            .frame(height: 30)
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.weekColumn)
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkSecondary).frame(width: Self.cell)
                }
            }
            .frame(height: 24)
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    if let week = Self.week(ofRow: row) {
                        weekCell(week.title, number: week.number, isCurrent: week.title == thisWeek)
                    } else {
                        Color.clear.frame(width: Self.weekColumn, height: Self.cell)
                    }
                    ForEach(Array(row.enumerated()), id: \.offset) { _, day in
                        if let day {
                            dayCell(Self.title(day), number: Calendar.current.component(.day, from: day), isToday: Self.title(day) == today)
                        } else {
                            Color.clear.frame(width: Self.cell, height: Self.cell)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        #if os(macOS)
        .frame(width: 338, height: 318, alignment: .top)
        .background(ScrollCatcher { delta, phase in scrolled(delta, phase) })
        #else
        .frame(width: 7 * Self.cell + Self.weekColumn + 28, height: 6 * Self.cell + 78, alignment: .top)
        .contentShape(Rectangle())
        // Swept sideways: a month along.
        .gesture(DragGesture(minimumDistance: 24).onEnded { drag in
            guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
            withAnimation(.snappy(duration: 0.2)) { month = month.adding(drag.translation.width < 0 ? 1 : -1) }
        })
        #endif
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { month = month.adding(-1); return .handled }
        .onKeyPress(.rightArrow) { month = month.adding(1); return .handled }
        .onAppear {
            focused = true
            let pages = (try? store.engine.allPages()) ?? []
            written = Set(pages.filter { ($0.kind == "day" || $0.kind == "week") && !$0.isBlank }.map(\.title))
            readProgress()
        }
        .onChange(of: month) { _, _ in readProgress() }
    }

    private func step(_ symbol: String, _ label: String, _ months: Int) -> some View {
        Button { month = month.adding(months) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.inkSecondary).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func dayCell(_ title: String, number: Int, isToday: Bool) -> some View {
        let has = written.contains(title)
        let done = progress[title]
        return Button { choose(title) } label: {
            ZStack {
                if hovered == title { Circle().fill(Color.inkHover).frame(width: 34, height: 34) }
                if let done {
                    // Its to-dos, how far along: a ring about the number.
                    Circle().stroke(Color.inkRule, lineWidth: 2).frame(width: 30, height: 30)
                    Circle().trim(from: 0, to: CGFloat(done.done) / CGFloat(max(done.total, 1)))
                        .stroke(Color.inkAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90)).frame(width: 30, height: 30)
                }
                Text("\(number)").font(.system(size: Self.cell * 0.33, weight: isToday || has ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(isToday ? Color.inkAccent : has ? Color.inkText : Color.inkFaint)
                // A note with nothing to tick off: a dot under the number.
                if has, done == nil { Circle().fill(isToday ? Color.inkAccent : Color.inkSecondary).frame(width: 4, height: 4).offset(y: 11) }
            }
            .frame(width: Self.cell, height: Self.cell)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? title : (hovered == title ? nil : hovered) }
        .accessibilityLabel(title)
        .accessibilityValue(done.map { "\($0.done) of \($0.total) tasks done" } ?? "")
    }

    private func weekCell(_ title: String, number: Int, isCurrent: Bool) -> some View {
        let has = written.contains(title)
        return Button { choose(title) } label: {
            ZStack {
                if hovered == title { Circle().fill(Color.inkHover).frame(width: 28, height: 28) }
                Text("\(number)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Self.ochre.opacity(has || isCurrent ? 1 : 0.4))
                if has { Circle().fill(Self.ochre).frame(width: 4, height: 4).offset(y: 11) }
            }
            .frame(width: Self.weekColumn, height: Self.cell)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? title : (hovered == title ? nil : hovered) }
        .help("Week \(number)")
        .accessibilityLabel("Week \(number)")
    }

    /// The tasks of the month's days that have notes: asked once a day.
    private func readProgress() {
        for day in month.weeks.flatMap({ $0 }).compactMap({ $0 }).map(Self.title) where written.contains(day) && read.insert(day).inserted {
            let tasks = (try? store.engine.tasksIn(path: "daily/\(day).md")) ?? []
            if !tasks.isEmpty { progress[day] = (tasks.filter(\.isDone).count, tasks.count) }
        }
    }

    #if os(macOS)
    /// A mouse's wheel: each notch a month. A trackpad's swipe: a month,
    /// once it ends, the way it went.
    private func scrolled(_ delta: CGFloat, _ phase: NSEvent.Phase) {
        if phase == [] {
            if delta > 0 { month = month.adding(-1) } else if delta < 0 { month = month.adding(1) }
            return
        }
        if phase == .began { swiped = 0 }
        swiped += delta
        if phase == .ended {
            if swiped > 20 { month = month.adding(-1) } else if swiped < -20 { month = month.adding(1) }
            swiped = 0
        }
    }
    #endif
}

#if os(macOS)
/// Hears the scroll wheel over what it lies behind: how far, and at what
/// phase of a swipe — nothing, for a mouse's wheel.
private struct ScrollCatcher: NSViewRepresentable {
    let scrolled: (CGFloat, NSEvent.Phase) -> Void

    final class Catcher: NSView {
        var scrolled: (CGFloat, NSEvent.Phase) -> Void = { _, _ in }

        override func scrollWheel(with event: NSEvent) {
            guard event.momentumPhase == [] else { return }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : event.scrollingDeltaY
            scrolled(delta, event.phase)
        }
    }

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.scrolled = scrolled
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) { view.scrolled = scrolled }
}

/// Lies over a control and hears only the secondary click: every other
/// click goes through to what is under it.
struct SecondaryClick: NSViewRepresentable {
    let action: () -> Void

    final class Catcher: NSView {
        var action: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown || event.type == .rightMouseUp || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { action() }
        override func mouseDown(with event: NSEvent) { action() }
    }

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.action = action
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) { view.action = action }
}
#endif
