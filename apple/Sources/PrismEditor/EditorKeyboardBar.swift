#if os(iOS)
import Prism
import UIKit

/// The tools over the keys: undo and redo, out and in, up and down over
/// the main capsule — its tools (an outline's begin with Fold and end
/// with New Time Block), or Aa's formatting, or the pages offered for a
/// link being typed — with Aa before it and Done after.
///
/// Pieces of glass with nothing between them: a touch between two is the
/// note's, under them, not the bar's.
final class EditorKeyboardBar: UIInputView {
    /// What a button of the bar asks for.
    enum Tool {
        case undo, redo
        case command(EditCommand)
        /// `[[` at the caret, or around what is selected.
        case link
        /// The rows under the caret's row put out of sight, or shown again.
        case fold
        /// A time block from now, to name.
        case timeBlock
        /// The first line, made the title.
        case title
        /// What is said, written at the caret — or, being written, no more.
        case dictate
        /// The keys put away.
        case done
    }

    private static let small: CGFloat = 32
    private static let main: CGFloat = 46
    private static let gap: CGFloat = 8
    private static let height: CGFloat = small + gap + main + 6

    private let act: (Tool) -> Void
    /// One glass, its pieces near enough to run together as they move.
    private let container: UIVisualEffectView
    private let history = EditorKeyboardBar.piece()
    private let shift = EditorKeyboardBar.piece()
    private let move = EditorKeyboardBar.piece()
    private let words = EditorKeyboardBar.piece()
    private let capsule = EditorKeyboardBar.piece()
    private let away = EditorKeyboardBar.piece()
    private let wordsButton = UIButton(type: .system)
    private let tools = UIStackView()
    private let formatting = UIStackView()
    private let chips = UIScrollView()
    private let chipRow = UIStackView()
    private weak var undo: UIButton?
    private weak var redo: UIButton?
    private weak var titleButton: UIButton?
    private weak var foldButton: UIButton?
    private weak var micButton: UIButton?
    private weak var timeButton: UIButton?
    private let tick = UISelectionFeedbackGenerator()
    /// Whether Aa's tools are the capsule's, in place of its own.
    private var isFormatting = false

    /// The app's colour: Aa's while its tools show, and the first page offered.
    var tint: UIColor {
        didSet {
            guard tint != oldValue else { return }
            if isFormatting { words.effect = Self.glass(tint: tint) }
            (chipRow.arrangedSubviews.first as? UIButton)?.configuration?.baseBackgroundColor = tint
        }
    }

    /// Whether the note has no title, and so is offered its first line for one.
    var offersTitle = false {
        didSet {
            guard offersTitle != oldValue else { return }
            titleButton?.isHidden = !offersTitle
        }
    }

    /// Whether the note is shown as an outline: only then are there rows
    /// to fold, and time blocks among them to make.
    var isOutline = true {
        didSet {
            guard isOutline != oldValue else { return }
            foldButton?.isHidden = !isOutline
            timeButton?.isHidden = !isOutline
        }
    }

    init(tint: UIColor, act: @escaping (Tool) -> Void) {
        self.tint = tint
        self.act = act
        if #available(iOS 26.0, *) {
            let effect = UIGlassContainerEffect()
            effect.spacing = 12
            container = UIVisualEffectView(effect: effect)
        } else {
            container = UIVisualEffectView(effect: nil)
        }
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: Self.height), inputViewStyle: .default)
        backgroundColor = .clear
        allowsSelfSizing = false

        let undos = stack([("arrow.uturn.backward", .undo, "Undo"), ("arrow.uturn.forward", .redo, "Redo")], size: 14)
        let shifts = stack([("decrease.indent", .command(.outdent), "Outdent"), ("increase.indent", .command(.indent), "Indent")], size: 14)
        let moves = stack([("arrow.up", .command(.moveUp), "Move Up"), ("arrow.down", .command(.moveDown), "Move Down")], size: 14)
        history.contentView.addSubview(undos)
        shift.contentView.addSubview(shifts)
        move.contentView.addSubview(moves)
        undo = undos.arrangedSubviews.first as? UIButton
        redo = undos.arrangedSubviews.last as? UIButton

        fill(tools, [
            ("mic", .dictate, "Dictate"),
            ("rectangle.compress.vertical", .fold, "Fold"),
            ("checkmark.square", .command(.cycleChecklist), "Checklist"),
            ("checkmark.circle", .command(.toggleTask), "Task"),
            ("list.bullet", .command(.bullet), "Bullet"),
            ("link", .link, "Link"),
            ("clock", .timeBlock, "New Time Block"),
            ("textformat.size.larger", .title, "Title"),
        ], size: 17)
        micButton = tools.arrangedSubviews.first as? UIButton
        foldButton = tools.arrangedSubviews.dropFirst().first as? UIButton
        foldButton?.isEnabled = false
        timeButton = tools.arrangedSubviews.dropLast().last as? UIButton
        titleButton = tools.arrangedSubviews.last as? UIButton
        titleButton?.isHidden = true
        fill(formatting, [
            ("bold", .command(.bold), "Bold"),
            ("italic", .command(.italic), "Italic"),
            ("highlighter", .command(.highlight), "Highlight"),
            ("text.quote", .command(.quote), "Quote"),
        ], size: 17)
        capsule.contentView.addSubview(tools)
        capsule.contentView.addSubview(formatting)
        formatting.alpha = 0
        formatting.isHidden = true

        wordsButton.setImage(UIImage(systemName: "textformat", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        wordsButton.tintColor = .label
        wordsButton.accessibilityLabel = "Formatting"
        wordsButton.addAction(UIAction { [weak self] _ in self?.toggleWords() }, for: .touchUpInside)
        words.contentView.addSubview(wordsButton)
        away.contentView.addSubview(button("keyboard.chevron.compact.down", .done, "Done", size: 17))

        chips.showsHorizontalScrollIndicator = false
        chips.isHidden = true
        chipRow.axis = .horizontal
        chipRow.spacing = 6
        chips.addSubview(chipRow)
        capsule.contentView.addSubview(chips)

        for piece in [history, shift, move, words, capsule, away] { container.contentView.addSubview(piece) }
        addSubview(container)
        autoresizingMask = .flexibleHeight
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    // MARK: Glass

    /// Liquid Glass, which answers a touch; before there was any, the system's material.
    private static func glass(tint: UIColor? = nil) -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            effect.tintColor = tint
            return effect
        }
        return UIBlurEffect(style: .systemMaterial)
    }

    private static func piece() -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: glass())
        if #available(iOS 26.0, *) {
            view.cornerConfiguration = .capsule()
        } else {
            view.clipsToBounds = true
        }
        return view
    }

    /// A capsule's shape, where the system has none to give it: half as round as it is tall.
    private func round(_ piece: UIVisualEffectView) {
        if #available(iOS 26.0, *) { return }
        piece.layer.cornerRadius = piece.bounds.height / 2
        piece.layer.cornerCurve = .continuous
    }

    // MARK: Buttons

    private func button(_ symbol: String, _ tool: Tool, _ label: String, size: CGFloat) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular)), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = label
        button.addAction(UIAction { [weak self] _ in self?.press(tool) }, for: .touchUpInside)
        return button
    }

    private func fill(_ stack: UIStackView, _ items: [(String, Tool, String)], size: CGFloat) {
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        for (symbol, tool, label) in items { stack.addArrangedSubview(button(symbol, tool, label, size: size)) }
    }

    private func stack(_ items: [(String, Tool, String)], size: CGFloat) -> UIStackView {
        let stack = UIStackView()
        fill(stack, items, size: size)
        return stack
    }

    private func press(_ tool: Tool) {
        tick.selectionChanged()
        act(tool)
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        container.frame = bounds
        let left = max(12, safeAreaInsets.left + 8), right = bounds.width - max(12, safeAreaInsets.right + 8)
        let y = Self.small + Self.gap
        words.frame = CGRect(x: left, y: y, width: Self.main, height: Self.main)
        away.frame = CGRect(x: right - Self.main, y: y, width: Self.main, height: Self.main)
        capsule.frame = CGRect(x: words.frame.maxX + Self.gap, y: y, width: max(away.frame.minX - Self.gap - words.frame.maxX - Self.gap, 0), height: Self.main)
        wordsButton.frame = words.bounds
        away.contentView.subviews.first?.frame = away.bounds
        let inside = capsule.bounds.insetBy(dx: 8, dy: 0)
        tools.frame = inside
        formatting.frame = inside
        chips.frame = capsule.bounds
        let chipsWidth = chipRow.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        chipRow.frame = CGRect(x: 6, y: 6, width: chipsWidth, height: Self.main - 12)
        chips.contentSize = CGSize(width: chipsWidth + 12, height: Self.main)
        // The small ones over the middle of the main, side by side: undo, then the row's moves.
        let width: CGFloat = 88
        let middle = capsule.frame.midX
        history.frame = CGRect(x: middle - width * 1.5 - Self.gap, y: 0, width: width, height: Self.small)
        shift.frame = CGRect(x: middle - width / 2, y: 0, width: width, height: Self.small)
        move.frame = CGRect(x: middle + width / 2 + Self.gap, y: 0, width: width, height: Self.small)
        for piece in [history, shift, move] { piece.contentView.subviews.first?.frame = piece.bounds.insetBy(dx: 4, dy: 0) }
        for piece in [history, shift, move, words, capsule, away] { round(piece) }
        // The pages offered scroll within the capsule's shape.
        chips.layer.cornerRadius = Self.main / 2
        chips.layer.cornerCurve = .continuous
        chips.clipsToBounds = true
    }

    /// Touches between the pieces: the note's, under them, not the bar's.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === container || hit === container.contentView ? nil : hit
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        [history, shift, move, words, capsule, away].contains { $0.frame.contains(point) }
    }

    // MARK: What it shows

    /// Aa: the capsule to the words' tools, Aa lit while it is; again, back.
    private func toggleWords() {
        tick.selectionChanged()
        let toWords = !isFormatting
        isFormatting = toWords
        let effect = Self.glass(tint: toWords ? tint : nil)
        let (shown, hidden) = toWords ? (formatting, tools) : (tools, formatting)
        // Pages being offered: the tools turned to, under them, for after.
        shown.isHidden = !chips.isHidden
        let lit = toWords
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.words.effect = effect
            if #unavailable(iOS 26.0) { self.words.contentView.backgroundColor = lit ? self.tint : .clear }
            self.wordsButton.tintColor = lit ? .white : .label
            shown.alpha = 1
            hidden.alpha = 0
        } completion: { _ in
            // Unless turned back to, meanwhile.
            if hidden.alpha == 0 { hidden.isHidden = true }
        }
    }

    /// ↶ and ↷, dimmed when there is nothing to undo, or redo.
    func showUndo(canUndo: Bool, canRedo: Bool) {
        undo?.isEnabled = canUndo
        redo?.isEnabled = canRedo
    }

    /// The microphone, as it is: listening — red, and filled — or not.
    func showDictating(_ listening: Bool) {
        guard let micButton else { return }
        micButton.setImage(UIImage(systemName: listening ? "mic.fill" : "mic", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        micButton.tintColor = listening ? .systemRed : nil
        micButton.accessibilityLabel = listening ? "Stop Dictating" : "Dictate"
    }

    /// Fold, for a row with rows under it; Unfold, for one folded;
    /// dimmed, for a row that is neither.
    func showFold(folded: Bool, foldable: Bool) {
        guard let foldButton else { return }
        let label = folded ? "Unfold" : "Fold"
        if foldButton.accessibilityLabel != label {
            foldButton.setImage(UIImage(systemName: folded ? "rectangle.expand.vertical" : "rectangle.compress.vertical", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
            foldButton.accessibilityLabel = label
        }
        foldButton.isEnabled = foldable
    }

    /// Pages to choose from, each a title and its symbol, in the capsule
    /// in place of its tools — the first, which Return puts in, marked —
    /// or, with none, the tools again. Told which was chosen.
    func show(chips candidates: [(title: String, symbol: String)], choose: @escaping (Int) -> Void) {
        guard !candidates.isEmpty || !chips.isHidden else { return }
        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, candidate) in candidates.enumerated() {
            var configuration = UIButton.Configuration.filled()
            configuration.title = candidate.title
            configuration.image = UIImage(systemName: candidate.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            configuration.imagePadding = 5
            configuration.titleLineBreakMode = .byTruncatingTail
            configuration.cornerStyle = .capsule
            configuration.baseBackgroundColor = index == 0 ? tint : .tertiarySystemFill
            configuration.baseForegroundColor = index == 0 ? .white : .label
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.systemFont(ofSize: 15, weight: index == 0 ? .semibold : .regular)
                return attributes
            }
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.tick.selectionChanged()
                choose(index)
            })
            button.accessibilityLabel = "Link to " + candidate.title
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            chipRow.addArrangedSubview(button)
        }
        let choosing = !candidates.isEmpty
        chips.isHidden = !choosing
        let current = isFormatting ? formatting : tools
        current.isHidden = choosing
        chips.contentOffset = .zero
        setNeedsLayout()
    }
}
#endif
