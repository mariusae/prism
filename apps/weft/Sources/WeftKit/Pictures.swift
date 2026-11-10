#if os(macOS)
import LinkPresentation
import Prism
import PrismEditor
import SwiftUI

/// The graph's pictures, read once each.
@MainActor
enum Pictures {
    private static let kept = NSCache<NSString, NSImage>()

    /// A picture in the graph, by its path there; `nil` when there is none.
    static func image(at address: String, in store: GraphStore) -> NSImage? {
        let path = address.removingPercentEncoding ?? address
        let key = "\(store.root.path)|\(path)" as NSString
        if let known = kept.object(forKey: key) { return known }
        guard !path.contains("://"), let image = NSImage(contentsOf: store.root.appendingPathComponent(path)) else { return nil }
        kept.setObject(image, forKey: key)
        return image
    }
}

/// A picture in a note, shown where its line is written: as wide as it
/// was given, or as it is, or as there is room for. Its corner drags it
/// to another size, which is written beside it in the note.
struct PictureView: View {
    let store: GraphStore
    let picture: EditorPicture
    var rewrite: ((String) -> Void)?
    /// The width it is being dragged to.
    @State private var dragged: CGFloat?
    @State private var isHovered = false

    private var isRemote: Bool { picture.address.hasPrefix("http://") || picture.address.hasPrefix("https://") }

    /// How wide the room it is shown in is: the editor says.
    var room: CGFloat = 600

    var body: some View {
        // Its size is known before it is drawn: nothing is measured, and
        // nothing moves a moment after it appears.
        content(room: room).frame(height: height(room: room), alignment: .topLeading)
    }

    private var local: NSImage? { isRemote ? nil : Pictures.image(at: picture.address, in: store) }

    /// Its own size: a file's; for one on the web, what was written, or a guess.
    private var natural: CGSize {
        if let local, local.size.width > 0 { return local.size }
        // A file that is not there is a line saying so, not a picture's room.
        if !isRemote { return CGSize(width: 260, height: 30) }
        return CGSize(width: picture.width ?? 320, height: picture.height ?? ((picture.width ?? 320) * 0.75))
    }

    private func width(room: CGFloat) -> CGFloat {
        min(max(dragged ?? picture.width ?? natural.width, 40), max(room, 40))
    }

    private func height(room: CGFloat) -> CGFloat {
        // While it is dragged the room it was given stays as it was: the note is set anew when it is let go.
        let width = min(max(picture.width ?? natural.width, 40), max(room, 40))
        return (width * natural.height / max(natural.width, 1)).rounded()
    }

    @ViewBuilder private func content(room: CGFloat) -> some View {
        let width = width(room: room)
        let height = (width * natural.height / max(natural.width, 1)).rounded()
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let local {
                    Image(nsImage: local).resizable().interpolation(.high)
                } else if isRemote, let url = URL(string: picture.address) {
                    AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fit) } placeholder: { Color.inkRule }
                } else {
                    // No such file: said, rather than left blank.
                    ZStack {
                        Color.inkHover
                        Label(picture.address, systemImage: "photo").font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1).padding(8)
                    }
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(dragged != nil ? Color.inkAccent : Color.inkRule, lineWidth: dragged != nil ? 1.5 : 0.5))
            if rewrite != nil, isHovered || dragged != nil {
                // The corner it is resized by.
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .padding(6)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let from = picture.width ?? min(natural.width, room)
                                dragged = min(max(from + drag.translation.width, 60), room)
                            }
                            .onEnded { _ in
                                guard let to = dragged else { return }
                                dragged = nil
                                var sized = picture
                                sized.width = to.rounded()
                                sized.height = (to * natural.height / max(natural.width, 1)).rounded()
                                rewrite?(sized.line)
                            }
                    )
                    .help("Drag to resize")
                    .pointerStyle(.frameResize(position: .bottomTrailing))
            }
            if let dragged {
                Text("\(Int(dragged))").font(.caption2.monospacedDigit()).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55))).padding(.trailing, 32).padding(.bottom, 8)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .onHover { isHovered = $0 }
        .contextMenu {
            if rewrite != nil, picture.width != nil {
                Button("Actual Size") { rewrite?(EditorPicture(alt: picture.alt, address: picture.address).line) }
            }
            if !isRemote {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.root.appendingPathComponent(picture.address.removingPercentEncoding ?? picture.address)])
                }
            }
        }
    }
}

/// What is known of a page on the web: its title, its picture. Asked of
/// the page once, and kept while the app runs.
@MainActor
@Observable
final class WebCards {
    static let shared = WebCards()

    struct Found {
        var title: String?
        var image: NSImage?
    }

    private(set) var found: [String: Found] = [:]
    @ObservationIgnored private var asked = Set<String>()

    func look(_ address: String) {
        guard !asked.contains(address), let url = URL(string: address), url.scheme == "https" || url.scheme == "http" else { return }
        asked.insert(address)
        let provider = LPMetadataProvider()
        provider.timeout = 8
        provider.startFetchingMetadata(for: url) { metadata, _ in
            let title = metadata?.title
            let finish: @Sendable (NSImage?) -> Void = { image in
                Task { @MainActor in WebCards.shared.found[address] = Found(title: title, image: image) }
            }
            guard let pictures = metadata?.imageProvider ?? metadata?.iconProvider, pictures.canLoadObject(ofClass: NSImage.self) else { return finish(nil) }
            _ = pictures.loadObject(ofClass: NSImage.self) { image, _ in finish(image as? NSImage) }
        }
    }
}

/// The card shown of a link while the pointer rests on it.
struct LinkCard: View {
    let store: GraphStore
    let link: EditorLink

    var body: some View {
        Group {
            switch link {
            case .web(let address): web(address, title: nil, cover: nil)
            case .page(let name): note(name)
            case .tag: EmptyView()
            }
        }
        .frame(width: 300, alignment: .leading)
        .foregroundStyle(Color.inkText)
    }

    /// Whether there is anything to show of a link.
    static func shows(_ link: EditorLink, in store: GraphStore) -> Bool {
        switch link {
        case .web: return true
        case .page(let name): return store.resolve(name)?.exists == true
        case .tag: return false
        }
    }

    private static func host(_ address: String) -> String {
        (URL(string: address)?.host ?? address).replacingOccurrences(of: "www.", with: "")
    }

    @ViewBuilder private func web(_ address: String, title: String?, cover: NSImage?) -> some View {
        let found = WebCards.shared.found[address]
        VStack(alignment: .leading, spacing: 0) {
            if let image = cover ?? found?.image, image.size.width >= 120 {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 300, height: 150).clipped()
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let image = found?.image, cover == nil, image.size.width < 120 { Image(nsImage: image).resizable().frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3)) }
                    Text(title ?? found?.title ?? Self.host(address)).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                }
                Text(Self.host(address)).font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1)
            }
            .padding(12)
        }
        .onAppear { if title == nil || cover == nil { WebCards.shared.look(address) } }
    }

    /// A note: one kept of a page on the web as that page's card; any other as its first lines.
    @ViewBuilder private func note(_ name: String) -> some View {
        if let path = store.resolve(name)?.path, let source = (try? store.engine.read(path: path)) ?? nil {
            let editor = NoteEditor.open(source: source, mode: .text)
            let label = editor.label(path: path)
            if let address = Self.address(in: source), editor.field(key: "icon") == "link" || editor.field(key: "cover") != nil {
                web(address, title: label, cover: editor.field(key: "cover").flatMap { Pictures.image(at: $0, in: store) })
            } else {
                let lines = editor.text().split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" }).map { inlinePlainText(text: String($0)) }.filter { !$0.isEmpty && $0 != label }
                VStack(alignment: .leading, spacing: 5) {
                    Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    if !lines.isEmpty {
                        Text(lines.prefix(6).joined(separator: "\n")).font(.system(size: 12)).foregroundStyle(Color.inkSecondary).lineLimit(7)
                    }
                }
                .padding(12)
            }
        }
    }

    /// The first address on the web a note names.
    private static func address(in source: String) -> String? {
        guard let range = source.range(of: #"https?://[^\s<>)\]]+"#, options: .regularExpression) else { return nil }
        return String(source[range])
    }
}
#endif
