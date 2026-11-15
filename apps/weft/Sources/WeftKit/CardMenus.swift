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
