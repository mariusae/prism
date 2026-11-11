#if os(iOS)
import PrismEditor
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The pictures a line of a note is: one, as wide as it was given, or as
/// it is, or as there is room for, and no taller than `maxHeight`; or
/// several written side by side, shown one at a time — a carousel, turned
/// by a tap at either edge or a swipe, a dot for each under it. Tapped, a
/// picture is looked at over the app; held, it can be copied or shared.
struct PhonePictures: View {
    let store: GraphStore
    let pictures: [EditorPicture]
    var room: CGFloat
    @State private var index: Int

    static let maxHeight: CGFloat = 420
    /// Under a carousel's pictures: a dot for each.
    static let dotsRoom: CGFloat = 20

    init(store: GraphStore, pictures: [EditorPicture], room: CGFloat) {
        self.store = store
        self.pictures = pictures
        self.room = room
        _index = State(initialValue: PhoneCarousel.index(for: pictures))
    }

    var body: some View {
        if pictures.count > 1 { carousel } else if let picture = pictures.first { single(picture) }
    }

    /// A picture's size where there is so much room across: no wider than
    /// the room, no taller than `maxHeight`, its shape kept.
    static func fitted(_ natural: CGSize, width: CGFloat) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return .zero }
        var width = width
        var height = width * natural.height / natural.width
        if height > maxHeight {
            height = maxHeight
            width = height * natural.width / natural.height
        }
        return CGSize(width: floor(width), height: floor(height))
    }

    /// A carousel's size: as wide as there is room — or as its first
    /// picture was given to be — and as tall as the tallest of its
    /// pictures there, its dots under them.
    static func carouselSize(_ naturals: [CGSize], width: CGFloat?, room: CGFloat) -> CGSize {
        let width = min(width ?? room, max(room, 40))
        let height = naturals.map { fitted($0, width: width).height }.max() ?? 0
        return CGSize(width: floor(width), height: floor(height) + dotsRoom)
    }

    private func image(_ picture: EditorPicture) -> UIImage? {
        guard let image = Pictures.image(at: picture.address, in: store), image.size.width > 0 else { return nil }
        return image
    }

    /// A picture's own size: a file's; for one on the web, what was written, or a guess.
    private func natural(_ picture: EditorPicture) -> CGSize {
        if let image = image(picture) { return image.size }
        return CGSize(width: picture.width ?? 320, height: picture.height ?? ((picture.width ?? 320) * 0.75))
    }

    private func isRemote(_ picture: EditorPicture) -> Bool { picture.address.hasPrefix("http://") || picture.address.hasPrefix("https://") }

    /// Where a picture is kept, if it is a file in the graph: the engine says.
    private func file(_ picture: EditorPicture) -> URL? {
        guard !picture.address.contains("://") else { return nil }
        let path = picture.address.removingPercentEncoding ?? picture.address
        guard let place = try? store.engine.absolutePath(path: path), FileManager.default.fileExists(atPath: place) else { return nil }
        return URL(fileURLWithPath: place)
    }

    // MARK: One

    @ViewBuilder private func single(_ picture: EditorPicture) -> some View {
        if let image = image(picture) {
            let size = Self.fitted(image.size, width: min(picture.width ?? image.size.width, max(room, 40)))
            framed(Image(uiImage: image).resizable().frame(width: size.width, height: size.height))
                .contentShape(Rectangle())
                .onTapGesture { look(at: 0) }
                .contextMenu { held(picture) }
        } else if isRemote(picture), let url = URL(string: picture.address) {
            let size = Self.fitted(natural(picture), width: min(picture.width ?? 320, max(room, 40)))
            framed(AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fit) } placeholder: { Color.inkHover }
                .frame(width: size.width, height: size.height))
        } else {
            Label(picture.address, systemImage: "photo").font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1)
                .padding(8).frame(height: 30).background(RoundedRectangle(cornerRadius: 5).fill(Color.inkHover))
        }
    }

    private func framed<Content: View>(_ content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.inkRule, lineWidth: 1))
    }

    // MARK: Several

    private var carousel: some View {
        let size = Self.carouselSize(pictures.map(natural), width: pictures.first?.width, room: room)
        let shown = min(max(index, 0), pictures.count - 1)
        let picture = pictures[shown]
        return VStack(spacing: 0) {
            ZStack {
                // A quiet ground, which the picture is fitted and centred over.
                Color.inkHover
                Group {
                    if let image = image(picture) {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else if isRemote(picture), let url = URL(string: picture.address) {
                        AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fit) } placeholder: { Color.clear }
                    } else {
                        Label(picture.address, systemImage: "photo").font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1).padding(8)
                    }
                }
                .id(shown)
                .transition(.opacity)
            }
            .frame(width: size.width, height: size.height - Self.dotsRoom)
            // Which, of how many, at the top right.
            .overlay(alignment: .topTrailing) {
                Text("\(shown + 1)/\(pictures.count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.inkRule, lineWidth: 1))
            .contentShape(Rectangle())
            // Its edges turn it; anywhere else, its pictures are looked at.
            .gesture(SpatialTapGesture().onEnded { tap in
                let edge = size.width * 0.3
                if tap.location.x < edge { turn(-1) } else if tap.location.x > size.width - edge { turn(1) } else { look(at: shown) }
            })
            .gesture(CarouselSwipe { turn($0) })
            .contextMenu { held(picture) }
            // The dots, under it.
            HStack(spacing: 6) {
                ForEach(pictures.indices, id: \.self) { one in
                    Circle().fill(one == shown ? Color.inkText : Color.inkFaint).frame(width: 6, height: 6)
                }
            }
            .frame(width: size.width, height: Self.dotsRoom)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Picture \(shown + 1) of \(pictures.count)")
        .accessibilityAdjustableAction { direction in turn(direction == .increment ? 1 : -1) }
    }

    /// To the picture so many after the one shown — before, for fewer than
    /// none — faded across. At either end, it goes no further, and says so.
    private func turn(_ step: Int) {
        let next = min(max(index + step, 0), pictures.count - 1)
        guard next != index else {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { index = next }
        PhoneCarousel.set(next, for: pictures)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Looked at, copied, shared

    /// The pictures over the app, in Quick Look, from one of them: to zoom into and share.
    private func look(at shown: Int) {
        let kept = pictures.enumerated().compactMap { index, picture in file(picture).map { (index, $0) } }
        guard !kept.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        PictureViewer.show(kept.map(\.1), at: kept.firstIndex { $0.0 == shown } ?? 0)
    }

    @ViewBuilder private func held(_ picture: EditorPicture) -> some View {
        if let file = file(picture) {
            Button("Copy", systemImage: "doc.on.doc") {
                guard let data = try? Data(contentsOf: file) else { return }
                UIPasteboard.general.setItems([[(UTType(filenameExtension: file.pathExtension) ?? .image).identifier: data]])
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            Button("Share\u{2026}", systemImage: "square.and.arrow.up") { PictureViewer.share(file) }
        }
    }
}

/// Which picture each carousel shows, by its first picture's address: kept
/// as how this phone shows the notes.
@MainActor
enum PhoneCarousel {
    private static let key = "Carousels"
    private static var shown = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]

    static func index(for pictures: [EditorPicture]) -> Int {
        guard let first = pictures.first else { return 0 }
        return min(max(shown[first.address] ?? 0, 0), pictures.count - 1)
    }

    static func set(_ index: Int, for pictures: [EditorPicture]) {
        guard let first = pictures.first else { return }
        shown[first.address] = min(max(index, 0), pictures.count - 1)
        UserDefaults.standard.set(shown, forKey: key)
    }
}

/// A swipe across a carousel: left for the next picture, right for the one
/// before. A pan that begins only when it goes sideways, so that the river
/// still scrolls under a finger that goes down it; and one a card's own
/// sideways pan waits on, so that the swipe turns the carousel and does
/// not push the card aside.
struct CarouselSwipe: UIGestureRecognizerRepresentable {
    var turned: (Int) -> Void

    /// What a card's swipe knows a carousel's by.
    final class Pan: UIPanGestureRecognizer {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.4
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other is UIPanGestureRecognizer)
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> Pan {
        let pan = Pan()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: Pan, context: Context) {
        guard recognizer.state == .ended else { return }
        let moved = recognizer.translation(in: recognizer.view).x, velocity = recognizer.velocity(in: recognizer.view).x
        if moved < -24 || velocity < -300 { turned(1) } else if moved > 24 || velocity > 300 { turned(-1) }
    }
}

/// Pictures looked at over the app, in Quick Look; and one shared.
@MainActor
final class PictureViewer: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    /// Kept while it shows them: the viewer holds its source loosely.
    private static var showing: PictureViewer?
    private let files: [URL]

    private init(files: [URL]) { self.files = files }

    static func show(_ files: [URL], at index: Int) {
        guard !files.isEmpty, let presenter = top else { return }
        let viewer = PictureViewer(files: files)
        showing = viewer
        let preview = QLPreviewController()
        preview.dataSource = viewer
        preview.delegate = viewer
        preview.currentPreviewItemIndex = min(max(index, 0), files.count - 1)
        presenter.present(preview, animated: true)
    }

    static func share(_ file: URL) {
        guard let presenter = top else { return }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = presenter.view
        share.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        presenter.present(share, animated: true)
    }

    /// What is in front, to present over.
    private static var top: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow ?? scenes.first?.keyWindow
        var presenter = window?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        return presenter
    }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        MainActor.assumeIsolated { files.count }
    }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        MainActor.assumeIsolated { files[index] as NSURL }
    }

    nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
        MainActor.assumeIsolated { Self.showing = nil }
    }
}

#if DEBUG
/// A carousel on its own, to try it out before the editor hands one over:
/// `-PictureHarness "![](assets/a.png) ![](assets/b.png)"`. It stands in
/// a card that swipes aside, in a river that scrolls, as it will in a note.
struct PictureHarness: View {
    let store: GraphStore
    let line: String
    /// With `-PictureHarnessSave`: what keeping a picture in the graph said.
    @State private var saved: [String] = []

    static var line: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-PictureHarness"), arguments.indices.contains(flag + 1) else { return nil }
        return arguments[flag + 1]
    }

    var body: some View {
        GeometryReader { space in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(0..<3, id: \.self) { card in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(card == 0 ? "Pictures on a line" : "A card to scroll by").font(.system(size: 22, weight: .semibold))
                            if card == 0, let pictures = PictureLine(line: line) {
                                PhonePictures(store: store, pictures: pictures.pictures, room: space.size.width - 20 - 32)
                            } else {
                                Text(card == 0 ? "Not a line of pictures: \(line)" : String(repeating: "Words to make the card tall. ", count: 30))
                            }
                            if card == 0 { ForEach(saved, id: \.self) { Text($0).font(.caption.monospaced()) } }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Measures.cardRadius, style: .continuous).fill(Color.inkCard))
                        .modifier(CardSwipe(leading: [SwipeAction(name: "To Do", symbol: "circle", tint: .orange) {}], trailing: [SwipeAction(name: "Close", symbol: "xmark", tint: .gray) {}], enabled: true))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
        }
        .background(Color.inkPage.ignoresSafeArea())
        .foregroundStyle(Color.inkText)
        .task {
            // The first picture kept again: as a png, its bytes its own; as any other kind, a JPEG.
            guard ProcessInfo.processInfo.arguments.contains("-PictureHarnessSave"), saved.isEmpty,
                  let first = PictureLine(line: line)?.pictures.first, let place = try? store.engine.absolutePath(path: first.address),
                  let data = FileManager.default.contents(atPath: place) else { return }
            for kind in ["png", "heic"] {
                let path = store.savePicture(data: data, fileExtension: kind)
                let kept = path.flatMap { try? store.engine.absolutePath(path: $0) }.flatMap { FileManager.default.contents(atPath: $0) }
                saved.append("\(kind) → \(path ?? "nil") \(kept?.count ?? 0) bytes\(kept == data ? ", the same" : "") \(kept.map { $0.prefix(3) == Data([0xFF, 0xD8, 0xFF]) ? "JPEG" : "" } ?? "")")
            }
        }
    }
}
#endif
#endif
