import SwiftUI

/// Keeps where a river was read to, and takes it back there: the card at
/// the top of what shows, and how far into it. Each card says where it
/// stands as the river is scrolled; the one across the top is the place.
/// Shown again, the river is scrolled to that card, then down by as much.
@MainActor
final class RiverScroll {
    /// Where each card's top stands, in the scroll view's own space.
    private var tops: [Card.ID: CGFloat] = [:]
    /// Not taken down until the place is gone back to: the river is laid
    /// out at its top first, which is not where it was read to.
    private(set) var restoring = true
    /// How far the river is scrolled, as the scroll view says — counted
    /// from above the bar's room, which a scroll to a place is not.
    var offset: CGFloat = 0
    var inset: CGFloat = 0

    /// A card's frame as the river is scrolled: the place, if it is the one across the top.
    func saw(_ card: Card, at frame: CGRect, in river: River, top: CGFloat = 0) {
        tops[card.id] = frame.minY
        guard !restoring else { return }
        if frame.minY <= top + 0.5, frame.maxY > top {
            let place = River.ScrollPlace(spot: card.spot, offset: Double(top - frame.minY))
            if river.scrolled != place { river.scrolled = place }
        } else if river.all.first?.id == card.id, frame.minY > top {
            // Above the first card: the river's very top.
            if river.scrolled != nil { river.scrolled = nil }
        }
    }

    /// Back to where the river was read to: the card brought to the top,
    /// then the river moved down by how far into it the place was.
    func restore(_ river: River, proxy: ScrollViewProxy, position: Binding<ScrollPosition>, top: CGFloat = 0) {
        guard let place = river.scrolled, let card = river.card(spot: place.spot) else {
            restoring = false
            return
        }
        restoring = true
        proxy.scrollTo(card.id, anchor: .top)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            if let stands = self.tops[card.id] {
                position.wrappedValue.scrollTo(y: max(self.offset + self.inset + (stands - top) + CGFloat(place.offset), 0))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.restoring = false }
        }
    }
}
