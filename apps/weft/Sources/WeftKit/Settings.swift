#if os(macOS)
import PrismEditor
import SwiftUI

/// The app's settings: the face and the size cards are set in. Changed
/// here, every card open is set anew at once.
public struct SettingsView: View {
    public init() {}

    private static let faces: [(face: EditorFace, name: String)] = [(.sans, "Sans"), (.serif, "Serif"), (.rounded, "Rounded"), (.mono, "Mono")]

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Typeface").font(.headline)
                HStack(spacing: 10) {
                    ForEach(Self.faces, id: \.face) { item in
                        let chosen = TextSettings.face == item.face
                        Button { TextSettings.face = item.face } label: {
                            VStack(spacing: 4) {
                                Text("Ag").font(.system(size: 26, weight: .medium, design: item.face.fontDesign)).foregroundStyle(Color.inkText)
                                Text(item.name).font(.caption).foregroundStyle(chosen ? Color.inkAccent : Color.inkSecondary)
                            }
                            .frame(width: 84, height: 70)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.inkCard))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(chosen ? Color.inkAccent : Color.inkRule, lineWidth: chosen ? 2 : 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.name)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Size").font(.headline)
                    Spacer()
                    Text("\(Int(TextSettings.size)) pt").monospacedDigit().foregroundStyle(Color.inkSecondary)
                    Button("Reset") { TextSettings.size = TextSettings.defaultSize }.controlSize(.small).disabled(TextSettings.size == TextSettings.defaultSize)
                }
                HStack(spacing: 10) {
                    Text("A").font(.system(size: 11, design: TextSettings.design)).foregroundStyle(Color.inkSecondary)
                    Slider(value: Binding(get: { Double(TextSettings.size) }, set: { TextSettings.size = CGFloat($0) }), in: Double(TextSettings.range.lowerBound)...Double(TextSettings.range.upperBound), step: 1)
                    Text("A").font(.system(size: 20, design: TextSettings.design)).foregroundStyle(Color.inkSecondary)
                }
            }
            // What a card will look like.
            VStack(alignment: .leading, spacing: 6) {
                Text("A note\u{2019}s title").font(.system(size: TextSettings.titleSize, weight: .semibold, design: TextSettings.design))
                Text("Notes are set like this: a line of writing, with a **bold** word and an *italic* one, long enough to wrap onto a second line.")
                    .font(.system(size: TextSettings.size, design: TextSettings.design))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color.inkText)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.inkCard))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.inkRule))
        }
        .padding(22)
        .frame(width: 430)
        .background(Color.inkPage)
    }
}
#endif
