import SwiftUI

/// How a note is shown, chosen from its card's menu: as it is written, or
/// always as an outline, or always as prose — on this device.
struct ShowAsMenu: View {
    let draft: PageDraft

    var body: some View {
        Picker(selection: Binding(get: { draft.shownAs }, set: { draft.show(as: $0) })) {
            Text(draft.shownAs == .automatic ? "Automatic (\(draft.isProse ? "Prose" : "Outline"))" : "Automatic").tag(PageDraft.ShownAs.automatic)
            Text("Outline").tag(PageDraft.ShownAs.outline)
            Text("Prose").tag(PageDraft.ShownAs.prose)
        } label: {
            Label("Show As", systemImage: draft.isProse ? "text.alignleft" : "list.bullet.indent")
        }
        .pickerStyle(.menu)
    }
}


/// What a view is made of, made only when it is shown: a card's menu, asked
/// for every card as the river is drawn, is made when it is opened.
struct Deferred<Content: View>: View {
    @ViewBuilder let make: () -> Content

    var body: some View { make() }
}
