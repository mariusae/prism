#if os(iOS)
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Where a picture put into a note comes from.
public enum EditorPictureSource: CaseIterable, Sendable {
    case camera, library, scan

    var title: String {
        switch self {
        case .camera: "Take Photo"
        case .library: "Choose from Library"
        case .scan: "Scan Document"
        }
    }

    var symbol: String {
        switch self {
        case .camera: "camera"
        case .library: "photo.on.rectangle"
        case .scan: "doc.viewfinder"
        }
    }

    /// Whether this phone has it: there is no camera in the simulator.
    @MainActor var isAvailable: Bool {
        switch self {
        case .camera: UIImagePickerController.isSourceTypeAvailable(.camera)
        case .library: true
        case .scan: VNDocumentCameraViewController.isSupported
        }
    }
}

/// Takes a photo, or has some chosen, or a document scanned, over the app;
/// hands back what came in — nothing, when it was cancelled — once it is put away.
@MainActor
final class EditorPicturePicker: NSObject {
    private let done: ([EditorPastedPicture]) -> Void
    /// Each one keeps itself until it is done.
    private static var going: Set<EditorPicturePicker> = []

    private init(done: @escaping ([EditorPastedPicture]) -> Void) {
        self.done = done
    }

    static func pick(_ source: EditorPictureSource, from view: UIView, done: @escaping ([EditorPastedPicture]) -> Void) {
        guard source.isAvailable, var top = view.window?.rootViewController else { return }
        while let shown = top.presentedViewController { top = shown }
        let picker = EditorPicturePicker(done: done)
        let controller: UIViewController
        switch source {
        case .camera:
            let camera = UIImagePickerController()
            camera.sourceType = .camera
            camera.delegate = picker
            controller = camera
        case .library:
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 0
            configuration.selection = .ordered
            let library = PHPickerViewController(configuration: configuration)
            library.delegate = picker
            controller = library
        case .scan:
            let scanner = VNDocumentCameraViewController()
            scanner.delegate = picker
            controller = scanner
        }
        going.insert(picker)
        top.present(controller, animated: true)
    }

    private func finish(_ controller: UIViewController, with pictures: [EditorPastedPicture]) {
        controller.dismiss(animated: true) {
            self.done(pictures)
            Self.going.remove(self)
        }
    }

    static func jpeg(_ image: UIImage) -> EditorPastedPicture? {
        image.jpegData(compressionQuality: 0.85).map { EditorPastedPicture(data: $0, fileExtension: "jpg") }
    }
}

extension EditorPicturePicker: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    nonisolated func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        MainActor.assumeIsolated {
            let image = info[.originalImage] as? UIImage
            finish(picker, with: image.flatMap(Self.jpeg).map { [$0] } ?? [])
        }
    }

    nonisolated func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        MainActor.assumeIsolated { finish(picker, with: []) }
    }
}

extension EditorPicturePicker: PHPickerViewControllerDelegate {
    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let providers = results.map(\.itemProvider)
        Task { @MainActor in
            var pictures: [EditorPastedPicture] = []
            for provider in providers {
                if let picture = await Self.picture(from: provider) { pictures.append(picture) }
            }
            finish(picker, with: pictures)
        }
    }

    /// A picture's own bytes, in the kind it was kept as — a HEIC is made a JPEG when it is saved.
    private static func picture(from provider: NSItemProvider) async -> EditorPastedPicture? {
        let kind = provider.registeredTypeIdentifiers.compactMap(UTType.init).first { $0.conforms(to: .image) } ?? .image
        return await withCheckedContinuation { going in
            _ = provider.loadDataRepresentation(forTypeIdentifier: kind.identifier) { data, _ in
                going.resume(returning: data.map { EditorPastedPicture(data: $0, fileExtension: kind.preferredFilenameExtension ?? "jpg") })
            }
        }
    }
}

extension EditorPicturePicker: VNDocumentCameraViewControllerDelegate {
    nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        MainActor.assumeIsolated {
            let pages = (0..<scan.pageCount).compactMap { Self.jpeg(scan.imageOfPage(at: $0)) }
            finish(controller, with: pages)
        }
    }

    nonisolated func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        MainActor.assumeIsolated { finish(controller, with: []) }
    }

    nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(controller, with: []) }
    }
}
#endif
