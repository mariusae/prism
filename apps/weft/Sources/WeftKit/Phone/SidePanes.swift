#if os(iOS)
import SwiftUI

/// Two panes side by side, for a window wide enough: an iPhone Duo opened,
/// or an iPad. On the Duo they stand one on each side of the fold, as
/// `ArrangementView` splits the display; before iOS 27.1, they are halves.
struct SidePanes<Primary: View, Secondary: View>: View {
    private let primary: Primary
    private let secondary: Secondary

    init(@ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary) {
        self.primary = primary()
        self.secondary = secondary()
    }

    var body: some View {
        if #available(iOS 27.1, *) {
            ArrangementView { primary } secondary: { secondary }
                .arrangementViewStyle(.split)
        } else {
            HStack(spacing: 0) {
                primary.frame(maxWidth: .infinity)
                Rectangle().fill(Color.inkRule).frame(width: 1).ignoresSafeArea()
                secondary.frame(maxWidth: .infinity)
            }
        }
    }
}
#endif
