#if os(iOS)
import Prism
import UIKit
import UIKit.UIGestureRecognizerSubclass

// What a finger does to a row of an outline, beyond tapping its mark:
//
// - **Held** — by its bullet while the note is written in, where holding
//   the words moves the caret; anywhere on it while the note is only
//   read — a row is picked up with the rows under it, carried, and put
//   down where the line shows: before a row, at a depth set by how far
//   across.
// - **Let go where it was picked up**, it shows what can be done to it:
//   folded, marked done, copied, moved, turned into another kind of row,
//   deleted.
// - **Select Rows**, there, begins choosing: each row tapped in or out,
//   tinted while chosen, and on glass at the foot what is done to them
//   all.
//
// All of it is the note's to do (`NoteEditor.performOn`, `moveRows`);
// this is only the finger's side of it.

/// A long press that is only ever where it is let begin: anywhere else it
/// fails as the finger comes down, and what waits on it goes on as if it
/// were not there.
final class RowHold: UILongPressGestureRecognizer {
    var begins: ((CGPoint) -> Bool)?

    /// The finger it follows: others that come down while it is held —
    /// another, scrolling — are not its.
    private weak var finger: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let finger, finger.phase != .ended, finger.phase != .cancelled {
            for touch in touches where touch !== finger { ignore(touch, for: event) }
            let own = touches.filter { $0 === finger }
            if !own.isEmpty { super.touchesBegan(own, with: event) }
            return
        }
        super.touchesBegan(touches, with: event)
        finger = touches.first
        if let touch = touches.first, begins?(touch.location(in: view)) != true { state = .failed }
    }

    override func reset() {
        super.reset()
        finger = nil
    }
}

@MainActor
final class RowHands: NSObject, UIGestureRecognizerDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    private weak var view: NoteTextView?
    private let hold = RowHold()
    /// While a row is carried: another finger scrolling the page under it.
    private let dragScroll = UIPanGestureRecognizer()
    private var menu: UIEditMenuInteraction?
    private var carried: Carried?
    private var choice: Choice?
    /// The row a menu is shown for, and where it was asked for, in the view.
    private var menuRow = 0
    private var menuPoint = CGPoint.zero

    /// A row being carried, with the rows under it.
    @MainActor
    private final class Carried {
        let rows: ClosedRange<Int>
        let lifted: UIView
        let line = UIView()
        var drop: (index: Int, depth: Int)?
        /// Where in what is lifted the finger has hold of it.
        let grab: CGPoint
        /// Where the finger was when the row was picked up, and where it is.
        let start: CGPoint
        var last: CGPoint
        var autoscroll: CADisplayLink?

        init(rows: ClosedRange<Int>, lifted: UIView, grab: CGPoint, start: CGPoint) {
            self.rows = rows
            self.lifted = lifted
            self.grab = grab
            self.start = start
            last = start
        }
    }

    /// Rows chosen together, by their places among the note's lines.
    @MainActor
    private final class Choice {
        var rows: Set<Int>
        let tints = UIView()
        let bar: UIVisualEffectView

        init(rows: Set<Int>) {
            self.rows = rows
            if #available(iOS 26.0, *) {
                bar = UIVisualEffectView(effect: UIGlassEffect())
                bar.cornerConfiguration = .capsule()
            } else {
                bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
                bar.clipsToBounds = true
            }
        }
    }

    init(_ view: NoteTextView) {
        self.view = view
        super.init()
        hold.minimumPressDuration = 0.4
        hold.begins = { [weak self] point in self?.canHold(at: point) == true }
        hold.addTarget(self, action: #selector(held(_:)))
        hold.delegate = self
        view.addGestureRecognizer(hold)
        let menu = UIEditMenuInteraction(delegate: self)
        view.addInteraction(menu)
        self.menu = menu
    }

    var isChoosing: Bool { choice != nil }
    var isCarrying: Bool { carried != nil }

    private var coordinator: NoteEditorView.Coordinator? { view?.coordinator }
    private var manager: BodyLayoutManager? { view?.layoutManager as? BodyLayoutManager }
    private var step: CGFloat { coordinator?.parent.theme.step ?? 24 }

    /// Lets go of everything: the note is another, or the view is gone.
    func letGo() {
        finishCarrying(dropping: false)
        endChoosing()
    }

    // MARK: Holding

    /// Whether a row can be picked up at a point: by its mark while the
    /// note is written in — holding the words there moves the caret —
    /// and anywhere on it otherwise; never by a link, the lead, or what
    /// an app draws in place of a block.
    private func canHold(at point: CGPoint) -> Bool {
        guard let view, let manager, let coordinator, coordinator.shownMode == .outline, !view.isComposing, choice == nil, carried == nil,
              view.row(at: point) != nil
        else { return false }
        let place = view.containerPoint(point)
        if manager.isLead(at: place) || manager.link(at: place, in: view.textContainer) != nil { return false }
        if manager.marker(at: place, in: view.textContainer) != nil { return true }
        return !view.isFirstResponder
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gesture === dragScroll { return carried != nil }
        return view?.isOverText(touch.view) == true
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        gesture === dragScroll ? carried != nil : true
    }

    /// The text view's own presses wait on this one, which lets go at once anywhere but on a row to be held.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gesture === hold, let view, let theirs = other.view else { return false }
        return theirs.isDescendant(of: view) && !view.isOwn(other) && other !== dragScroll
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture === dragScroll || other === dragScroll
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard let view else { return }
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            if !pickUp(at: point) { cancel(gesture) }
        case .changed:
            follow(to: point)
        case .ended:
            // Let go where it was picked up: what can be done to the row, not a move.
            if let state = carried, hypot(point.x - state.start.x, point.y - state.start.y) < 10 {
                finishCarrying(dropping: false)
                showMenu(forRow: state.rows.lowerBound, at: point)
                return
            }
            finishCarrying(dropping: true)
        default:
            finishCarrying(dropping: false)
        }
    }

    /// Picks up the row at a point of the view, with the rows under it:
    /// lifted, and carried from then on. Says whether there was one.
    func pickUp(at point: CGPoint) -> Bool {
        guard let view else { return false }
        guard let row = view.row(at: point), let info = coordinator?.editor.rowInfo(row: UInt32(row)) else { return false }
        let rows = row...(row + Int(info.shown))
        let frame = view.frame(ofRows: rows)
        guard frame.width > 0, frame.height > 0, let picture = view.resizableSnapshotView(from: frame, afterScreenUpdates: false, withCapInsets: .zero) else { return false }
        let lifted = UIView(frame: frame)
        lifted.isUserInteractionEnabled = false
        lifted.backgroundColor = coordinator?.parent.theme.background
        lifted.layer.cornerRadius = 8
        lifted.layer.shadowColor = UIColor.black.cgColor
        lifted.layer.shadowOpacity = 0.18
        lifted.layer.shadowRadius = 10
        lifted.layer.shadowOffset = CGSize(width: 0, height: 4)
        picture.frame = lifted.bounds
        lifted.addSubview(picture)
        view.addSubview(lifted)
        let state = Carried(rows: rows, lifted: lifted, grab: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), start: point)
        state.line.isUserInteractionEnabled = false
        state.line.backgroundColor = coordinator?.parent.theme.accent
        state.line.layer.cornerRadius = 1.5
        state.line.isHidden = true
        view.addSubview(state.line)
        carried = state
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIView.animate(withDuration: 0.15) { lifted.transform = CGAffineTransform(scaleX: 1.03, y: 1.03) }
        if view.isFirstResponder { _ = view.resignFirstResponder() }
        follow(to: point)
        let link = CADisplayLink(target: self, selector: #selector(autoscroll))
        link.add(to: .main, forMode: .common)
        state.autoscroll = link
        // Another finger, anywhere, scrolls the page under the row
        // carried: the one carrying it is already down, and not its.
        if dragScroll.delegate == nil {
            dragScroll.addTarget(self, action: #selector(scrolledWhileCarrying(_:)))
            dragScroll.delegate = self
            dragScroll.maximumNumberOfTouches = 1
        }
        view.window?.addGestureRecognizer(dragScroll)
        return true
    }

    private func cancel(_ gesture: UIGestureRecognizer) {
        gesture.isEnabled = false
        gesture.isEnabled = true
    }

    // MARK: Carrying

    /// Where rows would go, let go at a point: before which row — one
    /// past the last for the end — and how deep, which is where their
    /// bullet is, across, held to what can be there. `nil` among the rows
    /// carried themselves.
    private func place(at point: CGPoint, left: CGFloat, carrying rows: ClosedRange<Int>) -> (index: Int, depth: Int)? {
        guard let view, let manager, let editor = coordinator?.editor, !manager.lines.isEmpty else { return nil }
        let count = manager.lines.count
        let bottom = view.frame(ofRows: (count - 1)...(count - 1)).maxY
        // The row under the finger — or, between two, the nearer.
        let under = view.row(at: point) ?? (0..<count).first { view.frame(ofRows: $0...$0).maxY >= point.y } ?? count - 1
        var index = point.y > view.frame(ofRows: under...under).midY ? under + 1 : under
        if point.y > bottom { index = count }
        let pointed = max(Int((left / step).rounded()), 0)
        guard let depth = editor.dropDepth(rows: [UInt32(rows.lowerBound)], before: UInt32(index), depth: UInt32(pointed)) else { return nil }
        return (index, Int(depth))
    }

    /// The row carried, taken to where the finger is; the line shows where it would go.
    func follow(to point: CGPoint) {
        guard let view, let state = carried else { return }
        state.last = point
        let size = state.lifted.bounds.size
        state.lifted.center = CGPoint(x: point.x - state.grab.x + size.width / 2, y: point.y - state.grab.y + size.height / 2)
        let left = point.x - state.grab.x - view.textContainerInset.left
        guard let drop = place(at: point, left: left, carrying: state.rows) else {
            // Within what is carried: nowhere to go.
            state.drop = nil
            state.line.isHidden = true
            return
        }
        if state.drop.map({ $0 != drop }) ?? true { UISelectionFeedbackGenerator().selectionChanged() }
        state.drop = drop
        let count = (manager?.lines.count ?? 1)
        let y = drop.index < count ? view.frame(ofRows: drop.index...drop.index).minY : view.frame(ofRows: (count - 1)...(count - 1)).maxY
        let x = view.textContainerInset.left + step * CGFloat(drop.depth) + step / 2
        state.line.frame = CGRect(x: x, y: y - 1.5, width: max(20, view.bounds.width - x - 8), height: 3)
        state.line.isHidden = false
        view.bringSubviewToFront(state.lifted)
    }

    /// The page the view is on: what scrolls.
    private var page: UIScrollView? {
        var ancestor = view?.superview
        while let now = ancestor {
            if let scroll = now as? UIScrollView, !(scroll is UITextView) { return scroll }
            ancestor = now.superview
        }
        return nil
    }

    /// Scrolls the page by so much, as far as it goes, and keeps the row
    /// under the finger carrying it, over what has come under it.
    private func scroll(by delta: CGFloat) {
        guard let state = carried, let page, delta != 0 else { return }
        let top = -page.adjustedContentInset.top
        let bottom = max(top, page.contentSize.height - page.bounds.height + page.adjustedContentInset.bottom)
        let y = min(max(page.contentOffset.y + delta, top), bottom)
        let moved = y - page.contentOffset.y
        guard moved != 0 else { return }
        page.contentOffset.y = y
        follow(to: CGPoint(x: state.last.x, y: state.last.y + moved))
    }

    /// Near the top or bottom of the screen: the page scrolls along.
    @objc private func autoscroll() {
        guard let view, let state = carried, let page else { return }
        let inPage = view.convert(state.last, to: page)
        let visible = page.bounds.inset(by: page.adjustedContentInset)
        let edge: CGFloat = 70
        var delta: CGFloat = 0
        if inPage.y < visible.minY + edge { delta = -(visible.minY + edge - inPage.y) / 6 }
        if inPage.y > visible.maxY - edge { delta = (inPage.y - (visible.maxY - edge)) / 6 }
        scroll(by: delta)
    }

    @objc private func scrolledWhileCarrying(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed, carried != nil else { return }
        // In the window: the page's own measure moves as it scrolls.
        let step = gesture.translation(in: nil).y
        gesture.setTranslation(.zero, in: nil)
        scroll(by: -step)
    }

    /// The row carried, let go: put down where the line shows, or back where it was.
    func finishCarrying(dropping: Bool) {
        guard let state = carried else { return }
        carried = nil
        dragScroll.view?.removeGestureRecognizer(dragScroll)
        state.autoscroll?.invalidate()
        state.line.removeFromSuperview()
        UIView.animate(withDuration: 0.15, animations: { state.lifted.alpha = 0 }) { _ in state.lifted.removeFromSuperview() }
        guard dropping, let drop = state.drop else { return }
        if coordinator?.moveRows([state.rows.lowerBound], before: drop.index, depth: drop.depth) == true {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    // MARK: A row's menu

    /// A row held and let go in place: its menu.
    func showMenu(forRow row: Int, at point: CGPoint) {
        guard !actions(forRow: row).isEmpty else { return }
        menuRow = row
        menuPoint = point
        // After the finger is up: shown as it lifts, the menu goes with it.
        DispatchQueue.main.async { [weak self] in
            self?.menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: "row" as NSString, sourcePoint: point))
        }
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard configuration.identifier as? String == "row" else { return nil }
        let children = actions(forRow: menuRow)
        return children.isEmpty ? nil : UIMenu(children: children)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        CGRect(x: menuPoint.x - 12, y: menuPoint.y - 12, width: 24, height: 24)
    }

    /// What can be done to a row: folded or opened, all the way down
    /// too; marked done; a checklist's done items put to the bottom;
    /// copied, cut, taken to another note; moved among the rows beside
    /// it; chosen with others; turned into another kind; deleted.
    private func actions(forRow row: Int) -> [UIMenuElement] {
        guard let coordinator, let info = coordinator.editor.rowInfo(row: UInt32(row)) else { return [] }
        let action = { (title: String, symbol: String, attributes: UIMenuElement.Attributes, run: @escaping () -> Void) in
            UIAction(title: title, image: UIImage(systemName: symbol), attributes: attributes) { _ in run() }
        }
        let command = { [weak self] (title: String, symbol: String, command: EditCommand, possible: Bool, felt: Bool) in
            action(title, symbol, possible ? [] : .disabled) {
                guard self?.coordinator?.perform(command, onRows: [row]) == true else { return }
                if felt { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                self?.view?.noteSettled()
            }
        }
        var actions: [UIMenuElement] = []
        if info.isFolded {
            actions.append(command("Unfold", "rectangle.expand.vertical", .unfold, true, false))
        } else if info.hasChildren {
            actions.append(command("Fold", "rectangle.compress.vertical", .fold, true, false))
        }
        // Folded within, deeper down: all of it at once.
        if info.foldsInside { actions.append(command("Unfold Completely", "arrow.up.and.down", .unfoldCompletely, true, false)) }
        if info.openInside { actions.append(command("Fold Completely", "arrow.down.and.line.horizontal.and.arrow.up", .foldCompletely, true, false)) }
        if let done = info.done {
            actions.append(command(done ? "Mark Not Done" : "Mark Done", done ? "circle" : "checkmark.circle", .toggleCheckbox, true, false))
        }
        if info.hasChecklist { actions.append(command("Move Done to Bottom", "arrow.down.to.line", .moveDoneToBottom, info.doneToMove, true)) }
        actions.append(action("Copy", "doc.on.doc", []) { [weak self] in self?.copy([row]) })
        actions.append(action("Cut", "scissors", []) { [weak self] in
            guard let self, self.copy([row]) else { return }
            self.coordinator?.perform(.deleteRows, onRows: [row])
        })
        if coordinator.parent.onMoveRows != nil {
            actions.append(action("Move to…", "arrow.right.doc.on.clipboard", []) { [weak self] in self?.coordinator?.moveElsewhere([row]) })
        }
        // A row of a list, shown as a note of its own: here, or in a card beside this one.
        if coordinator.parent.onZoom != nil, coordinator.isListRow(row) {
            actions.append(action("Focus", "scope", []) { [weak self] in self?.coordinator?.zoom(row: row, apart: false) })
            actions.append(action("Open as Card", "rectangle.stack.badge.plus", []) { [weak self] in self?.coordinator?.zoom(row: row, apart: true) })
        }
        // Beside Move to…: where among its own rows, or elsewhere.
        let reorder = UIMenu(title: "Reorder", image: UIImage(systemName: "arrow.up.arrow.down"), children: [
            command("Move to Top", "arrow.up.to.line", .moveToTop, info.canMoveUp, true),
            command("Move Up", "arrow.up", .moveUp, info.canMoveUp, true),
            command("Move Down", "arrow.down", .moveDown, info.canMoveDown, true),
            command("Move to Bottom", "arrow.down.to.line", .moveToBottom, info.canMoveDown, true),
        ])
        if coordinator.parent.onMoveRows != nil { actions.append(reorder) }
        actions.append(action("Select Rows", "checklist", []) { [weak self] in self?.beginChoosing(with: row) })
        actions.append(action("Turn Into…", "arrow.triangle.2.circlepath", []) { [weak self] in self?.showTurnInto(forRow: row) })
        actions.append(command("Delete Row", "trash", .deleteRows, true, true).destructive)
        if coordinator.parent.onMoveRows == nil { actions.append(reorder) }
        return actions
    }

    /// Some rows, with those under them, put on the pasteboard as Markdown. Says whether there was anything to copy.
    @discardableResult
    private func copy(_ rows: [Int]) -> Bool {
        guard let markdown = coordinator?.editor.markdownOf(rows: rows.map { UInt32($0) }), !markdown.isEmpty else { return false }
        UIPasteboard.general.string = markdown
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return true
    }

    /// The kinds a row can be, to choose from, the one it is ticked.
    private func showTurnInto(forRow row: Int) {
        guard let view, let coordinator, coordinator.layout.lines.indices.contains(row) else { return }
        let kind = coordinator.layout.lines[row].kind
        var (number, done, bullet): (UInt32?, Bool?, String) = (nil, nil, "")
        var isItem = false
        if case .item(let itsNumber, let itsDone, let itsBullet) = kind { (number, done, bullet, isItem) = (itsNumber, itsDone, itsBullet, true) }
        let kinds: [(String, Bool, EditCommand)] = [
            ("Bullet", isItem && number == nil && done == nil, .turnBullet),
            ("Checkbox", isItem && number == nil && done != nil && bullet != "+", .turnCheckbox),
            ("Task", isItem && done != nil && bullet == "+", .turnTask),
            ("Numbered", number != nil, .turnNumbered),
            ("Heading 1", kind == .heading(level: 1), .turnHeading1),
            ("Heading 2", kind == .heading(level: 2), .turnHeading2),
            ("Heading 3", kind == .heading(level: 3), .turnHeading3),
            ("Quote", kind == .quote, .turnQuote),
            ("Paragraph", kind == .paragraph, .turnParagraph),
        ]
        let sheet = UIAlertController(title: "Turn Into", message: nil, preferredStyle: .actionSheet)
        for (title, current, command) in kinds {
            sheet.addAction(UIAlertAction(title: current ? "✓ " + title : title, style: .default) { [weak self] _ in
                self?.coordinator?.perform(command, onRows: [row])
                self?.view?.noteSettled()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(origin: menuPoint, size: .zero)
        var top = view.window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(sheet, animated: true)
    }

    // MARK: Rows chosen together

    /// Choosing begun, with a row chosen.
    func beginChoosing(with row: Int) {
        guard let view, choice == nil, coordinator?.layout.lines.indices.contains(row) == true else { return }
        if view.isFirstResponder { _ = view.resignFirstResponder() }
        let choice = Choice(rows: [row])
        choice.tints.isUserInteractionEnabled = false
        view.insertSubview(choice.tints, at: 0)
        self.choice = choice
        showBar(choice)
        showChosen()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A row tapped while choosing: in, or out.
    func toggleChosen(_ row: Int) {
        guard let choice else { return }
        if choice.rows.contains(row) { choice.rows.remove(row) } else { choice.rows.insert(row) }
        UISelectionFeedbackGenerator().selectionChanged()
        if choice.rows.isEmpty { return endChoosing() }
        showChosen()
    }

    private func endChoosing() {
        guard let choice else { return }
        self.choice = nil
        choice.tints.removeFromSuperview()
        UIView.animate(withDuration: 0.2) { choice.bar.alpha = 0 } completion: { _ in choice.bar.removeFromSuperview() }
    }

    /// The rows chosen, tinted — as they now lie.
    func showChosen() {
        guard let view, let choice, let coordinator else { return }
        choice.tints.subviews.forEach { $0.removeFromSuperview() }
        choice.tints.frame = view.bounds
        let lines = coordinator.layout.lines
        for row in choice.rows.sorted() where lines.indices.contains(row) {
            let tint = UIView(frame: view.frame(ofRows: row...row).insetBy(dx: -6, dy: -1))
            tint.backgroundColor = coordinator.parent.theme.accent.withAlphaComponent(0.12)
            tint.layer.cornerRadius = 8
            tint.layer.cornerCurve = .continuous
            choice.tints.addSubview(tint)
        }
    }

    private var chosen: [Int] { choice?.rows.sorted() ?? [] }

    private func showBar(_ choice: Choice) {
        guard let window = view?.window else { return }
        let symbols = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        var items: [(String, String, () -> Void)] = [
            ("checkmark.circle", "Done", { [weak self] in self?.markChosenDone() }),
            ("decrease.indent", "Outdent", { [weak self] in self?.shiftChosen(.outdent) }),
            ("increase.indent", "Indent", { [weak self] in self?.shiftChosen(.indent) }),
            ("doc.on.doc", "Copy", { [weak self] in
                guard let self else { return }
                self.copy(self.chosen)
                self.endChoosing()
            }),
        ]
        if coordinator?.parent.onMoveRows != nil {
            items.append(("arrow.right.doc.on.clipboard", "Move to…", { [weak self] in
                guard let self else { return }
                let rows = self.chosen
                self.endChoosing()
                self.coordinator?.moveElsewhere(rows)
            }))
        }
        items.append(("trash", "Delete", { [weak self] in self?.deleteChosen() }))
        items.append(("xmark", "Stop Choosing", { [weak self] in self?.endChoosing() }))
        let stack = UIStackView()
        stack.distribution = .fillEqually
        for (symbol, label, run) in items {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol, withConfiguration: symbols), for: .normal)
            button.tintColor = symbol == "trash" ? .systemRed : coordinator?.parent.theme.text ?? .label
            button.accessibilityLabel = label
            button.addAction(UIAction { _ in run() }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        choice.bar.contentView.addSubview(stack)
        let width = min(window.bounds.width - 32, 360), height: CGFloat = 52
        choice.bar.frame = CGRect(x: (window.bounds.width - width) / 2, y: window.bounds.height - window.safeAreaInsets.bottom - height - 84, width: width, height: height)
        if #unavailable(iOS 26.0) { choice.bar.layer.cornerRadius = height / 2 }
        stack.frame = choice.bar.bounds.insetBy(dx: 10, dy: 0)
        choice.bar.alpha = 0
        window.addSubview(choice.bar)
        UIView.animate(withDuration: 0.2) { choice.bar.alpha = 1 }
    }

    private func markChosenDone() {
        coordinator?.perform(.markDone, onRows: chosen)
        endChoosing()
        view?.noteSettled()
    }

    private func shiftChosen(_ command: EditCommand) {
        let count = coordinator?.layout.lines.count
        coordinator?.perform(command, onRows: chosen)
        // A row set in under a folded one unfolds it, and the rows are then other rows.
        if coordinator?.layout.lines.count != count { return endChoosing() }
        showChosen()
        view?.noteSettled()
    }

    private func deleteChosen() {
        let rows = chosen
        endChoosing()
        if coordinator?.perform(.deleteRows, onRows: rows) == true { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        view?.noteSettled()
    }
}

private extension UIAction {
    /// The same, marked as one that takes something away.
    var destructive: UIAction {
        attributes.insert(.destructive)
        return self
    }
}
#endif
