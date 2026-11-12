import PrismDictation
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// While words are said into a note: the caret a bar of light, glittering,
/// throwing off small stars back over what it writes, and each word as it
/// comes in lit, the light fading over a moment and a half — so it is
/// plain what is being written, and where. The same on the Mac and the
/// phone; only how it is laid over the text differs.
@MainActor
final class DictationGlow: EditorPlatformView {
    private weak var text: NoteTextView?
    /// What has come in lately, and when — in the text's own characters.
    private var lit: [(range: NSRange, at: CFTimeInterval)] = []
    /// Where the caret stands while listening: before this character.
    private var listening: Int?
    /// When words last came out of the caret.
    private var wroteAt: CFTimeInterval = 0
    /// When listening stopped: the stars left to go out.
    private var endedAt: CFTimeInterval?
    private var timer: Timer?
    private var pool: [CALayer] = []
    private let accent: CGColor
    private let bar: CALayer
    private let emitter: CAEmitterLayer
    /// The caret and its stars, over the words; the light is behind them.
    private let sparks: EditorPlatformView = Overlay()
    private static let fade: CFTimeInterval = 1.6

    init(on text: NoteTextView, accent color: EditorColor) {
        self.text = text
        #if os(macOS)
        var resolved = color
        text.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
        accent = resolved.cgColor
        #else
        accent = color.resolvedColor(with: text.traitCollection).cgColor
        #endif
        bar = Sparkles.bar(accent)
        emitter = Sparkles.emitter(accent)
        super.init(frame: text.bounds)
        bar.isHidden = true
        emitter.birthRate = 0
        #if os(macOS)
        wantsLayer = true
        sparks.wantsLayer = true
        sparks.layer?.addSublayer(emitter)
        sparks.layer?.addSublayer(bar)
        text.addSubview(self, positioned: .below, relativeTo: nil)
        text.addSubview(sparks)
        #else
        isUserInteractionEnabled = false
        sparks.isUserInteractionEnabled = false
        sparks.layer.addSublayer(emitter)
        sparks.layer.addSublayer(bar)
        text.insertSubview(self, at: 0)
        text.addSubview(sparks)
        #endif
        text.hidesCaret = true
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    /// Characters just written, to light.
    func wrote(_ range: NSRange) {
        guard range.length > 0 else { return }
        let now = CACurrentMediaTime()
        lit.append((range, now))
        wroteAt = now
        tick()
    }

    /// Where the words are going in: the caret before `location`; nil, none.
    func listen(at location: Int?) {
        listening = location
        tick()
    }

    /// Done listening: the caret as it was, its stars and the light let
    /// go out — or, what was written taken back, put out — then this gone.
    func end(keepingLight: Bool = true) {
        listening = nil
        endedAt = CACurrentMediaTime()
        text?.hidesCaret = false
        if !keepingLight {
            lit = []
            emitter.removeFromSuperlayer()
        }
        tick()
    }

    private func tick() {
        guard let text, let layout = text.noteLayout, let container = text.noteContainer else { return finish() }
        let now = CACurrentMediaTime()
        lit.removeAll { now - $0.at > Self.fade }
        let starsOut = endedAt.map { now - $0 > 1.4 || emitter.superlayer == nil } ?? false
        guard listening != nil || !lit.isEmpty || !starsOut else { return finish() }
        #if os(macOS)
        frame = text.bounds
        #else
        frame = CGRect(origin: .zero, size: CGSize(width: max(text.contentSize.width, text.bounds.width), height: max(text.contentSize.height, text.bounds.height)))
        #endif
        sparks.frame = frame
        let length = text.noteStorage?.length ?? 0
        let origin = text.containerOrigin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = sparks.bounds
        var used = 0
        for (range, at) in lit where NSMaxRange(range) <= length {
            let left = 1 - (now - at) / Self.fade
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                // Behind the words that came in, and no wider than them.
                let used_ = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndex(for: CGPoint(x: rect.midX, y: rect.midY), in: container), effectiveRange: nil)
                let (minX, maxX) = (max(rect.minX, used_.minX), min(rect.maxX, used_.maxX))
                guard maxX > minX else { return }
                let layer = self.lightLayer(used)
                used += 1
                layer.frame = CGRect(x: minX, y: rect.minY, width: maxX - minX, height: rect.height).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1.5, dy: 0)
                layer.opacity = Float(left * left)
            }
        }
        for layer in pool.dropFirst(used) { layer.isHidden = true }

        if let listening, let caret = text.caretBar(at: listening) {
            Sparkles.glint(bar, at: caret, now: now)
            Sparkles.place(emitter, at: caret, busy: now - wroteAt < 0.4)
            bar.isHidden = false
        } else {
            bar.isHidden = true
            emitter.birthRate = 0
        }
        CATransaction.commit()
    }

    private var lightHost: CALayer? {
        #if os(macOS)
        layer
        #else
        layer
        #endif
    }

    private func lightLayer(_ index: Int) -> CALayer {
        if index < pool.count {
            pool[index].isHidden = false
            return pool[index]
        }
        let layer = CALayer()
        layer.cornerRadius = 4
        layer.shadowRadius = 6
        layer.shadowOpacity = 0.5
        layer.shadowOffset = .zero
        layer.backgroundColor = accent.copy(alpha: 0.2)
        layer.shadowColor = accent
        lightHost?.addSublayer(layer)
        pool.append(layer)
        return layer
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        if endedAt == nil { text?.hidesCaret = false }
        sparks.removeFromSuperview()
        removeFromSuperview()
    }
}

/// A view laid over the text for what is drawn on it: counted from the top, as the text is, and never in the pointer's way.
private final class Overlay: EditorPlatformView {
    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif
}
