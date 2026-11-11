import Prism
import PrismEditor
import SwiftUI
import LinkPresentation
#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

/// The graph's pictures, read once each.
@MainActor
enum Pictures {
    private static let kept = NSCache<NSString, PlatformImage>()

    /// A picture in the graph, by its path there; `nil` when there is none.
    static func image(at address: String, in store: GraphStore) -> PlatformImage? {
        let path = address.removingPercentEncoding ?? address
        let key = "\(store.root.path)|\(path)" as NSString
        if let known = kept.object(forKey: key) { return known }
        guard !path.contains("://") else { return nil }
        let file = store.root.appendingPathComponent(path)
        #if os(macOS)
        let image = NSImage(contentsOf: file)
        #else
        let image = UIImage(contentsOfFile: file.path)
        #endif
        guard let image else { return nil }
        kept.setObject(image, forKey: key)
        return image
    }
}

/// A line that is only pictures: one, or several written side by side —
/// `![](a.png) ![](b.png)` — each perhaps with its size after it,
/// `<!-- {"width":320,"height":200} -->`. Several are shown one at a time,
/// as a carousel.
public struct PictureLine: Hashable {
    public var pictures: [EditorPicture]

    public init(pictures: [EditorPicture]) { self.pictures = pictures }

    private static let one = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)(?:\s*<!--\s*(\{[^>]*\})\s*-->)?"#)

    /// Reads a line that is only pictures, with nothing but space between
    /// them; `nil` for any other line.
    public init?(line: String) {
        let words = line as NSString
        var found: [EditorPicture] = []
        var at = 0
        for match in Self.one?.matches(in: line, range: NSRange(location: 0, length: words.length)) ?? [] {
            // Nothing but space before it, since the last.
            guard words.substring(with: NSRange(location: at, length: match.range.location - at)).allSatisfy(\.isWhitespace) else { return nil }
            at = NSMaxRange(match.range)
            let part = { (index: Int) -> String? in match.range(at: index).location == NSNotFound ? nil : words.substring(with: match.range(at: index)) }
            guard let address = part(2), !address.isEmpty else { return nil }
            var picture = EditorPicture(alt: part(1) ?? "", address: address)
            if let size = part(3), let read = try? JSONSerialization.jsonObject(with: Data(size.utf8)) as? [String: Any] {
                picture.width = (read["width"] as? NSNumber).map { CGFloat(truncating: $0) }
                picture.height = (read["height"] as? NSNumber).map { CGFloat(truncating: $0) }
            }
            found.append(picture)
        }
        guard !found.isEmpty, words.substring(from: at).allSatisfy(\.isWhitespace) else { return nil }
        pictures = found
    }

    /// The line that writes them: each as it is written, a space between.
    public var line: String { pictures.map(\.line).joined(separator: " ") }
}

extension GraphStore {
    /// Keeps a picture in the graph — one pasted, or dropped — and says
    /// where: `assets/pasted-<milliseconds>.<ext>`, with `-2`, `-3`… after
    /// the time when that name is taken. A png, a jpg and a gif keep their
    /// own bytes; any other picture is written again, as a JPEG on the
    /// phone and a PNG on the Mac. `nil` when it could not be read or kept.
    public func savePicture(data: Data, fileExtension: String) -> String? {
        var kind = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if kind == "jpeg" { kind = "jpg" }
        var bytes = data
        if !["png", "jpg", "gif"].contains(kind) {
            #if os(macOS)
            guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            (bytes, kind) = (png, "png")
            #else
            guard let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) else { return nil }
            (bytes, kind) = (jpeg, "jpg")
            #endif
        }
        guard !bytes.isEmpty, let folder = try? engine.absolutePath(path: "assets") else { return nil }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let stamp = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        for attempt in 1...1000 {
            let name = attempt == 1 ? "pasted-\(stamp).\(kind)" : "pasted-\(stamp)-\(attempt).\(kind)"
            // Made only if no file has the name: two pasted in the same moment are two files.
            let file = Darwin.open(folder + "/" + name, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if file < 0 {
                if errno == EEXIST { continue }
                return nil
            }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            guard (try? handle.write(contentsOf: bytes)) != nil else {
                try? handle.close()
                try? FileManager.default.removeItem(atPath: folder + "/" + name)
                return nil
            }
            try? handle.close()
            let path = "assets/" + name
            engine.pathsChanged(paths: [path])
            return path
        }
        return nil
    }
}

extension Image {
    /// A picture of either platform's, shown.
    init(platform image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

#if os(macOS)
/// A picture in a note, shown where its line is written: as wide as it
/// was given, or as it is, or as there is room for. Its corner drags it
/// to another size, which is written beside it in the note.
struct PictureView: View {
    let store: GraphStore
    let picture: EditorPicture
    var rewrite: ((String) -> Void)?
    /// How wide the room it is shown in is: the editor says.
    var room: CGFloat = 600
    /// Tells the editor its size changed, so the note is laid out around it again.
    var resized: (() -> Void)?
    /// The width it is being dragged to.
    @State private var dragged: CGFloat?
    @State private var isHovered = false

    /// What it is taken hold of by, to be resized.
    private enum Grip { case side, foot, corner }
    /// How far in from an edge it can be taken hold of.
    private static let reach: CGFloat = 12

    private var isRemote: Bool { picture.address.hasPrefix("http://") || picture.address.hasPrefix("https://") }
    private var local: NSImage? { isRemote ? nil : Pictures.image(at: picture.address, in: store) }

    /// Its own size: a file's; for one on the web, what was written, or a guess.
    private var natural: CGSize {
        if let local, local.size.width > 0 { return local.size }
        // A file that is not there is a line saying so, not a picture's room.
        if !isRemote { return CGSize(width: 260, height: 30) }
        return CGSize(width: picture.width ?? 320, height: picture.height ?? ((picture.width ?? 320) * 0.75))
    }

    /// How wide it is for every point it is tall.
    private var aspect: CGFloat { natural.width / max(natural.height, 1) }
    private var narrowest: CGFloat { min(60, max(room, 40)) }
    /// How wide it is written to be — or is, with nothing written.
    private var written: CGFloat { min(max(picture.width ?? natural.width, 40), max(room, 40)) }
    /// How wide it is now: as it is being dragged, as it goes.
    private var width: CGFloat { dragged ?? written }
    private var height: CGFloat { (width / aspect).rounded() }

    var body: some View {
        // Its size is known before it is drawn: nothing is measured, and
        // nothing moves a moment after it appears.
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let local {
                    Image(nsImage: local).resizable().interpolation(dragged == nil ? .high : .medium)
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
            if rewrite != nil {
                if isHovered || dragged != nil {
                    // Where it is taken hold of: shown, though all of both edges will do.
                    Capsule().fill(.white.opacity(0.9)).frame(width: 4, height: min(36, height * 0.5))
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .padding(.trailing, 4).frame(maxHeight: .infinity, alignment: .center)
                        .allowsHitTesting(false)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .padding(6)
                        .allowsHitTesting(false)
                }
                // The whole of its right edge, and of its foot, and the corner between.
                grip(.side).frame(width: Self.reach).frame(maxHeight: .infinity).padding(.bottom, Self.reach * 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                grip(.foot).frame(height: Self.reach).frame(maxWidth: .infinity).padding(.trailing, Self.reach * 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                grip(.corner).frame(width: Self.reach * 2, height: Self.reach * 2)
            }
            if let dragged {
                Text("\(Int(dragged))").font(.caption2.monospacedDigit()).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55))).padding(.trailing, 32).padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .onHover { isHovered = $0 }
        .contextMenu {
            if let local {
                Button("Copy Image", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([local])
                }
            } else if isRemote {
                Button("Copy Image Address", systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(picture.address, forType: .string)
                }
            }
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

    /// A part of it that resizes it when dragged: the note is laid out
    /// around it as it goes, and its size written when it is let go.
    private func grip(_ grip: Grip) -> some View {
        Color.clear.contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let wider: CGFloat = switch grip {
                        case .side: drag.translation.width
                        case .foot: drag.translation.height * aspect
                        case .corner: abs(drag.translation.width) > abs(drag.translation.height * aspect) ? drag.translation.width : drag.translation.height * aspect
                        }
                        let to = min(max(written + wider, narrowest), max(room, 40)).rounded()
                        guard to != dragged else { return }
                        dragged = to
                        // Once it has taken its new size.
                        DispatchQueue.main.async { resized?() }
                    }
                    .onEnded { _ in
                        guard let to = dragged else { return }
                        var sized = picture
                        sized.width = to
                        sized.height = (to / aspect).rounded()
                        // Written at the size it has: what replaces it is drawn as it was left.
                        rewrite?(sized.line)
                        dragged = nil
                    }
            )
            .help("Drag to resize")
            .pointerStyle(.frameResize(position: grip == .side ? .trailing : grip == .foot ? .bottom : .bottomTrailing))
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

/// What is known of a page on the web: its title, its picture. Asked of
/// the page once, and kept while the app runs.
@MainActor
@Observable
final class WebCards {
    static let shared = WebCards()

    struct Found {
        var title: String?
        var image: PlatformImage?
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
            let finish: @Sendable (PlatformImage?) -> Void = { image in
                Task { @MainActor in WebCards.shared.found[address] = Found(title: title, image: image) }
            }
            guard let pictures = metadata?.imageProvider ?? metadata?.iconProvider, pictures.canLoadObject(ofClass: PlatformImage.self) else { return finish(nil) }
            _ = pictures.loadObject(ofClass: PlatformImage.self) { image, _ in finish(image as? PlatformImage) }
        }
    }
}
