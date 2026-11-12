#if os(macOS)
import AppKit
import SwiftUI

/// A river's outline at its right edge, as Manifold has a view's: a
/// column of ticks, one a card, evenly spaced, in the middle of the
/// edge. A tick's height is how large its card is — four heights, against
/// the river's other cards, not any other's — and the ticks of the cards
/// that show are lit. When there are more than fit, the column scrolls, a
/// chevron at its top or bottom to go on. The pointer on it widens the
/// ticks around it, as the Dock does its icons, and brightens them; the
/// one under the pointer is previewed in a card beside it, and clicked,
/// gone to.
///
/// Unlike Manifold's it is always there, and it is the river's only
/// scroll bar: the lit ticks say where in the river one is.

/// The layout's arithmetic: Manifold's `StripLayout`, as it is there.
enum StripLayout {
    /// From one tick's middle to the next's.
    static let pitch: CGFloat = 12
    /// Above and below the column, when it scrolls: a chevron's room.
    static let pad: CGFloat = 14
    /// A tick's width at rest, and its heights.
    static let tickWidth: CGFloat = 12
    static let heights: [CGFloat] = [1.5, 3, 4.5, 6]
    /// How much wider the tick under the pointer is, and how far that
    /// reaches (the Dock's).
    static let swell: CGFloat = 2.2
    static let reach: CGFloat = 2 * pitch

    /// How many ticks a span holds.
    static func fits(_ height: CGFloat) -> Int { max(1, Int(height / pitch)) }

    /// Each tick's height (0…3): its item's size against the others'
    /// (logarithmically, from about the smallest to about the largest, so
    /// a stray one doesn't flatten the rest) — what's big here, not
    /// anywhere.
    static func heights(_ sizes: [Double]) -> [Int] {
        let logs = sizes.map { log(max($0, 1)) }
        let sorted = logs.sorted()
        guard sorted.count > 1 else { return sizes.map { _ in 1 } }
        let cut = sorted.count >= 10 ? sorted.count / 10 : 0
        let lo = sorted[cut], hi = sorted[sorted.count - 1 - cut]
        guard hi - lo > 1e-6 else { return sizes.map { _ in 1 } }
        return logs.map { min(3, max(0, Int((($0 - lo) / (hi - lo)) * 4))) }
    }

    /// The column: how many ticks it shows, and whether it scrolls (there
    /// being more than fit in `track`, the chevrons' room kept).
    static func column(count: Int, track: CGFloat) -> (shows: Int, scrolls: Bool) {
        if CGFloat(count) * pitch <= track { return (count, false) }
        return (max(1, Int((track - 2 * pad) / pitch)), true)
    }

    /// The first tick shown, moved as little as it takes to show `keep`
    /// (its start, if not all of it fits).
    static func follow(first: Int, keep: ClosedRange<Int>?, shows: Int, count: Int) -> Int {
        var f = first
        if let k = keep {
            if k.upperBound >= f + shows { f = k.upperBound - shows + 1 }
            if k.lowerBound < f { f = k.lowerBound }
        }
        return min(max(f, 0), max(count - shows, 0))
    }

    /// How much wider a tick is `d` from the pointer.
    static func swollen(_ d: CGFloat) -> CGFloat { 1 + (swell - 1) * exp(-(d * d) / (2 * reach * reach)) }
}

/// A tick placed: the card it stands for, its middle (from the view's
/// top), its height (0…3), and whether its card shows.
struct StripTick: Equatable {
    var index: Int
    var y: CGFloat
    var height: Int
    var lit: Bool
}

/// What a tick's card shows of its note, while the pointer is on the tick.
struct TickPreview {
    var title: String
    var detail: String
    var lines: [String]
}

/// The ticks, drawn and followed with the pointer.
final class TickStripView: NSView {
    /// The ticks' lane: what the strip takes of the river's width.
    static let lane: CGFloat = 16

    private var sizes: [Double] = []
    private var litCards: Set<Int> = []
    var onPick: (Int) -> Void = { _ in }
    /// A tick picked up and put down elsewhere in the column: its card
    /// moved from one place in the river to another.
    var onMove: (Int, Int) -> Void = { _, _ in }
    /// The tick being carried: which, where the pointer has it, and the
    /// place among the ticks shown it would be put down at.
    private var carried: (index: Int, y: CGFloat, slot: Int)?
    var preview: (Int) -> TickPreview? = { _ in nil }
    /// A lit tick's colour, and an unlit one's.
    var text = NSColor.labelColor
    var tertiary = NSColor.tertiaryLabelColor
    var panel = NSColor.windowBackgroundColor
    var panelBorder = NSColor.separatorColor

    private var chosenHeights: [Int] = []
    private var first = 0
    private var litSeen: ClosedRange<Int>?
    private(set) var ticks: [StripTick] = []
    private var more = (above: false, below: false)
    /// The ticks and chevrons.
    private let column = CALayer()
    private var pointer: CGFloat?
    private var hovered: Int?
    private var layers: [Int: CALayer] = [:]
    private let up = CAShapeLayer(), down = CAShapeLayer()
    private var onChevron: Chevron?
    enum Chevron { case up, down }
    private let card = StripCard()

    private static var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(column)
        for c in [up, down] {
            c.fillColor = nil
            c.lineWidth = 1.5
            c.lineCap = .round
            c.lineJoin = .round
            column.addSublayer(c)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The cards' sizes, one a card, and which of them show.
    /// The colour each card's note was given, by its place; none for a note given none.
    private var tints: [NSColor?] = []

    func set(sizes fresh: [Double], lit: Set<Int>, tints colours: [NSColor?] = []) {
        guard fresh != sizes || lit != litCards || colours != tints else { return }
        sizes = fresh
        litCards = lit
        tints = colours
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        draw(animated: false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { card.hide() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// The span the column may take: two thirds of the view's height, in
    /// its middle (a short view's 120 points, or all of one shorter).
    var track: (top: CGFloat, height: CGFloat) {
        let h = min(bounds.height, max(bounds.height * 2 / 3, 120))
        return (((bounds.height - h) / 2).rounded(), h)
    }

    /// The column's ticks' span, from the first's top to the last's bottom.
    private var block: (top: CGFloat, bottom: CGFloat) {
        let n = CGFloat(ticks.count)
        let top = ((bounds.height - n * StripLayout.pitch) / 2).rounded()
        return (top, top + n * StripLayout.pitch)
    }

    private func relayout() {
        let count = sizes.count
        chosenHeights = StripLayout.heights(sizes)
        let (shows, scrollsTicks) = StripLayout.column(count: count, track: track.height)
        let lit = litCards.filter { $0 < count }
        // The column follows what shows, when that changes; scrolled by
        // its chevrons, it stays till then.
        let range = lit.min().flatMap { lo in lit.max().map { lo...$0 } }
        if range != litSeen {
            first = StripLayout.follow(first: first, keep: range, shows: shows, count: count)
            litSeen = range
        }
        first = min(max(first, 0), max(count - shows, 0))
        let n = min(shows, count)
        let top = ((bounds.height - CGFloat(n) * StripLayout.pitch) / 2).rounded()
        ticks = (0..<n).map { k in
            StripTick(index: first + k, y: top + (CGFloat(k) + 0.5) * StripLayout.pitch, height: chosenHeights[first + k], lit: lit.contains(first + k))
        }
        more = (scrollsTicks && first > 0, scrollsTicks && first + n < count)
        draw(animated: pointer != nil)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Drawing

    /// The ticks' right edge.
    private var tickRight: CGFloat { Self.lane - 2 }

    private func draw(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated && !Self.reducedMotion ? 0.12 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if !animated { CATransaction.setDisableActions(true) }
        let keep = Set(ticks.map(\.index))
        for (i, l) in layers where !keep.contains(i) {
            l.removeFromSuperlayer()
            layers.removeValue(forKey: i)
        }
        // A tick being carried: the others close up where it was and part
        // where it would go, and it goes with the pointer.
        let top = block.top
        var slots: [Int: Int] = [:]
        if let carried, let from = ticks.firstIndex(where: { $0.index == carried.index }) {
            for (k, t) in ticks.enumerated() where k != from {
                let without = k > from ? k - 1 : k
                slots[t.index] = without >= carried.slot ? without + 1 : without
            }
        }
        for var t in ticks {
            if let carried {
                if t.index == carried.index { t.y = carried.y } else if let slot = slots[t.index] { t.y = top + (CGFloat(slot) + 0.5) * StripLayout.pitch }
            }
            let l = layers[t.index] ?? {
                let l = CALayer()
                column.insertSublayer(l, below: up)
                layers[t.index] = l
                return l
            }()
            // Wider and brighter near the pointer.
            let isCarried = carried?.index == t.index
            let swell = isCarried ? StripLayout.swell : (carried == nil ? pointer.map { StripLayout.swollen(abs($0 - t.y)) } ?? 1 : 1)
            let near = (swell - 1) / (StripLayout.swell - 1)
            let w = StripLayout.tickWidth * swell
            let h = StripLayout.heights[t.height]
            l.frame = NSRect(x: tickRight - w, y: t.y - h / 2, width: w, height: h)
            l.cornerRadius = min(min(h, w) / 2, 1.5)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                // A note given a colour is ticked in it: full where it shows, quieter where it does not.
                if tints.indices.contains(t.index), let tint = tints[t.index] {
                    l.backgroundColor = tint.withAlphaComponent(hovered == t.index || isCarried || t.lit ? 1 : 0.45 + 0.4 * near).cgColor
                    return
                }
                let base = hovered == t.index || isCarried ? text : (t.lit ? text : tertiary)
                l.backgroundColor = (base.blended(withFraction: near * 0.7, of: text) ?? base).cgColor
            }
        }
        drawChevrons()
        CATransaction.commit()
    }

    private func drawChevrons() {
        let x = tickRight - StripLayout.tickWidth / 2
        func path(_ y: CGFloat, pointingUp: Bool) -> CGPath {
            let p = CGMutablePath()
            let h: CGFloat = 3.5
            p.move(to: CGPoint(x: x - h, y: pointingUp ? y + h / 2 : y - h / 2))
            p.addLine(to: CGPoint(x: x, y: pointingUp ? y - h / 2 : y + h / 2))
            p.addLine(to: CGPoint(x: x + h, y: pointingUp ? y + h / 2 : y - h / 2))
            return p
        }
        let b = block
        up.path = path(b.top - StripLayout.pad / 2, pointingUp: true)
        down.path = path(b.bottom + StripLayout.pad / 2, pointingUp: false)
        up.isHidden = !more.above
        down.isHidden = !more.below
        effectiveAppearance.performAsCurrentDrawingAppearance {
            up.strokeColor = (onChevron == .up ? text : tertiary).cgColor
            down.strokeColor = (onChevron == .down ? text : tertiary).cgColor
        }
    }

    // MARK: The pointer

    private func chevron(at y: CGFloat) -> Chevron? {
        let b = block
        if more.above, y >= b.top - StripLayout.pad - 2, y < b.top { return .up }
        if more.below, y > b.bottom, y <= b.bottom + StripLayout.pad + 2 { return .down }
        return nil
    }

    /// A chevron clicked: the column scrolled by most of itself.
    private func go(_ c: Chevron) {
        let step = max(1, ticks.count - 2)
        first += c == .up ? -step : step
        first = min(max(first, 0), max(sizes.count - ticks.count, 0))
        card.hide()
        relayout()
    }

    private func onColumn(_ p: NSPoint) -> Bool {
        guard !ticks.isEmpty, p.x >= 0, p.x < Self.lane else { return false }
        let b = block
        return p.y >= b.top - (more.above ? StripLayout.pad : 2) && p.y <= b.bottom + (more.below ? StripLayout.pad : 2)
    }

    /// Off the column, the strip takes nothing from what is under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p), !isHidden else { return nil }
        return onColumn(p) ? self : nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        let b = block
        addCursorRect(NSRect(x: 0, y: b.top - StripLayout.pad, width: Self.lane, height: b.bottom - b.top + 2 * StripLayout.pad), cursor: .arrow)
    }

    /// The tick at a height, if there's one there.
    private func tick(near y: CGFloat) -> StripTick? {
        ticks.min { abs($0.y - y) < abs($1.y - y) }.flatMap { abs($0.y - y) <= StripLayout.pitch / 2 + 1 ? $0 : nil }
    }

    /// The pointer at a height on the column: the ticks around it widened,
    /// the one there previewed; nil, off it.
    private func hover(at y: CGFloat?) {
        if let y, let c = chevron(at: y) {
            onChevron = c
            pointer = nil
            hovered = nil
            card.hide()
            draw(animated: true)
            return
        }
        onChevron = nil
        let was = pointer
        pointer = y
        hovered = y.flatMap { tick(near: $0)?.index }
        if was == nil, y == nil { return }
        draw(animated: true)
        guard y != nil, let i = hovered, let t = ticks.first(where: { $0.index == i }), let shown = preview(i) else { return card.hide() }
        card.show(shown, beside: self, at: t.y, text: text, secondary: tertiary.withAlphaComponent(1), panel: panel, border: panelBorder)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover(at: onColumn(p) ? p.y : nil)
    }

    override func mouseExited(with event: NSEvent) { hover(at: nil) }

    private var pressed: (index: Int, at: NSPoint)?

    /// The ticks clicked twice: the river asked for whole.
    var onOverview: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        pressed = nil
        carried = nil
        if event.clickCount == 2 { return onOverview() }
        let p = convert(event.locationInWindow, from: nil)
        guard onColumn(p), chevron(at: p.y) == nil, let t = tick(near: p.y) else { return }
        pressed = (t.index, p)
    }

    /// A tick held and moved is picked up: it goes with the pointer, up
    /// and down the column, and the others make room where it would land.
    override func mouseDragged(with event: NSEvent) {
        guard let pressed, ticks.count > 1 else { return }
        let p = convert(event.locationInWindow, from: nil)
        if carried == nil, abs(p.y - pressed.at.y) <= 4 { return }
        let b = block
        let y = min(max(p.y, b.top + StripLayout.pitch / 2), b.bottom - StripLayout.pitch / 2)
        let slot = min(max(Int((y - b.top) / StripLayout.pitch), 0), ticks.count - 1)
        if carried == nil {
            card.hide()
            NSCursor.closedHand.push()
        }
        carried = (pressed.index, y, slot)
        pointer = nil
        hovered = nil
        draw(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        if let put = carried {
            // Put down: its card goes where it was put.
            carried = nil
            NSCursor.pop()
            let to = (ticks.first?.index ?? 0) + put.slot
            if to != put.index { onMove(put.index, to) } else { draw(animated: true) }
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        guard onColumn(p) else { return }
        if let c = chevron(at: p.y) { return go(c) }
        if let t = tick(near: p.y) {
            card.hide()
            onPick(t.index)
        }
    }
}

/// The card a tick's note is previewed in: a window of its own, left of
/// the strip, level with the tick. It comes and goes at once.
@MainActor
private final class StripCard {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let box = NSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private var isShown = false

    static let width: CGFloat = 280

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 0.5
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingTail
        body.font = .systemFont(ofSize: 13)
        body.maximumNumberOfLines = 6
        body.lineBreakMode = .byWordWrapping
        body.cell?.truncatesLastVisibleLine = true
        for v in [title, detail, body] { box.addSubview(v) }
        panel.contentView = box
    }

    func show(_ shown: TickPreview, beside strip: NSView, at y: CGFloat, text: NSColor, secondary: NSColor, panel fill: NSColor, border: NSColor) {
        guard let window = strip.window else { return hide() }
        let appearance = strip.effectiveAppearance
        panel.appearance = appearance
        appearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = fill.cgColor
            box.layer?.borderColor = border.cgColor
        }
        title.stringValue = shown.title
        title.textColor = text
        detail.stringValue = shown.detail
        detail.textColor = secondary
        detail.isHidden = shown.detail.isEmpty
        // Prose wraps, as a paragraph does.
        body.stringValue = shown.lines.joined(separator: " ")
        body.textColor = secondary
        body.isHidden = shown.lines.isEmpty
        let inner = Self.width - 24
        var h: CGFloat = 10
        let tH = ceil(title.sizeThatFits(NSSize(width: inner, height: 40)).height)
        let dH = shown.detail.isEmpty ? 0 : ceil(detail.sizeThatFits(NSSize(width: inner, height: 40)).height)
        body.preferredMaxLayoutWidth = inner
        let bH = shown.lines.isEmpty ? 0 : min(ceil(body.sizeThatFits(NSSize(width: inner, height: 400)).height), 112)
        h += tH + (dH > 0 ? dH + 2 : 0) + (bH > 0 ? bH + 6 : 0) + 10
        // Flipped by hand: the box isn't.
        var top = h - 10
        title.frame = NSRect(x: 12, y: top - tH, width: inner, height: tH)
        top -= tH
        if dH > 0 {
            detail.frame = NSRect(x: 12, y: top - dH - 2, width: inner, height: dH)
            top -= dH + 2
        }
        if bH > 0 { body.frame = NSRect(x: 12, y: top - bH - 6, width: inner, height: bH) }
        // Left of the ticks (widened as they are under the pointer), level
        // with the one it says, kept on the window.
        let inWindow = strip.convert(NSPoint(x: 0, y: y), to: nil)
        let screen = window.convertToScreen(NSRect(origin: inWindow, size: .zero)).origin
        let frame = window.frame
        var x = screen.x - Self.width - 18
        x = max(frame.minX + 4, x)
        var yTop = min(screen.y + 16, frame.maxY - 30)
        yTop = max(yTop, frame.minY + h + 4)
        panel.setFrame(NSRect(x: x, y: yTop - h, width: Self.width, height: h), display: true)
        if !isShown || panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            isShown = true
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// The ticks, in a SwiftUI river.
struct TickStrip: NSViewRepresentable {
    /// Each card's size, in the river's order.
    var sizes: [Double]
    /// The cards that show, by their place.
    var lit: Set<Int>
    /// The colour each card's note was given, if it was given one.
    var tints: [Color?] = []
    var onPick: (Int) -> Void
    var onMove: (Int, Int) -> Void = { _, _ in }
    var preview: (Int) -> TickPreview?
    /// The ticks clicked twice: the river asked for whole.
    var onOverview: () -> Void = {}

    func makeNSView(context: Context) -> TickStripView {
        let view = TickStripView(frame: NSRect(x: 0, y: 0, width: TickStripView.lane, height: 100))
        view.text = Ink.text
        view.tertiary = Ink.faint
        view.panel = Ink.card
        view.panelBorder = Ink.rule
        return view
    }

    func updateNSView(_ view: TickStripView, context: Context) {
        view.onPick = onPick
        view.onMove = onMove
        view.preview = preview
        view.onOverview = onOverview
        view.set(sizes: sizes, lit: lit, tints: tints.map { $0.map { NSColor($0) } })
    }
}
#endif
