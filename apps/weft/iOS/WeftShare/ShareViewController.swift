import UIKit
import UniformTypeIdentifiers
import WeftShared

/// Share ▸ Weft: a web page kept as a link note — its title, its address,
/// what it says of itself, what was selected on it — stamped with today.
/// A card shows what will be kept, its title editable; Save leaves it for
/// Weft, which makes the note when it next comes to the front.
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let heading = UILabel()
    private let titleField = UITextField()
    private let address = UILabel()
    private let about = UILabel()
    private let status = UILabel()
    private let save = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private var page: SharedPages.Page?

    private static func color(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
    }

    // Weft's own paper and ink.
    private let paper = color(0xFAF7F2, 0x1D1B18)
    private let ink = color(0x2B2724, 0xECE6DC)
    private let secondary = color(0x6F665D, 0xA79E92)
    private let accent = color(0x265CD1, 0x85ADFF)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        card.backgroundColor = paper
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        view.addSubview(card)

        heading.text = "Save to Weft"
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = secondary
        titleField.font = .systemFont(ofSize: 20, weight: .bold)
        titleField.textColor = ink
        titleField.placeholder = "Title"
        titleField.clearButtonMode = .whileEditing
        titleField.returnKeyType = .done
        titleField.addAction(UIAction { [weak self] _ in self?.titleField.resignFirstResponder() }, for: .editingDidEndOnExit)
        address.font = .systemFont(ofSize: 14)
        address.textColor = accent
        address.lineBreakMode = .byTruncatingMiddle
        about.font = .systemFont(ofSize: 14)
        about.textColor = secondary
        about.numberOfLines = 3
        status.font = .systemFont(ofSize: 14)
        status.textColor = secondary
        status.numberOfLines = 0
        status.text = "Reading the page…"

        var saveStyle = UIButton.Configuration.filled()
        saveStyle.title = "Save"
        saveStyle.baseBackgroundColor = accent
        saveStyle.cornerStyle = .capsule
        save.configuration = saveStyle
        save.isEnabled = false
        save.addAction(UIAction { [weak self] _ in self?.keep() }, for: .touchUpInside)
        var cancelStyle = UIButton.Configuration.plain()
        cancelStyle.title = "Cancel"
        cancelStyle.baseForegroundColor = secondary
        cancel.configuration = cancelStyle
        cancel.addAction(UIAction { [weak self] _ in self?.close(cancelled: true) }, for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [cancel, UIView(), save])
        let stack = UIStackView(arrangedSubviews: [heading, titleField, address, about, status, buttons])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(18, after: status)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -60),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            save.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
        ])
        Task { await read() }
    }

    // MARK: What was shared

    private func read() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var found: SharedPages.Page?
        search: for item in items {
            for provider in item.attachments ?? [] {
                // Safari: the page as GetPageInfo.js read it.
                if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                   let dictionary = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? NSDictionary,
                   let read = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
                   let url = read["url"] as? String, !url.isEmpty {
                    found = SharedPages.Page(url: url, title: read["title"] as? String ?? "", description: read["description"] as? String ?? "",
                                             selection: (read["selection"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                    break search
                }
                // Any other app: an address, and its title where the item has one.
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                   url.scheme?.hasPrefix("http") == true {
                    found = SharedPages.Page(url: url.absoluteString, title: item.attributedContentText?.string ?? "")
                    break search
                }
            }
        }
        show(found)
    }

    private func show(_ found: SharedPages.Page?) {
        page = found
        guard let found else {
            status.text = "There is no web page here to save."
            titleField.isHidden = true
            address.isHidden = true
            about.isHidden = true
            return
        }
        titleField.text = found.title.trimmingCharacters(in: .whitespacesAndNewlines)
        address.text = found.url
        about.text = found.selection.isEmpty ? found.description : "“\(found.selection)”"
        about.isHidden = about.text?.isEmpty ?? true
        status.text = found.selection.isEmpty ? "Kept as a link note, stamped with today." : "Kept as a link note with this highlight, stamped with today."
        save.isEnabled = true
    }

    // MARK: Keeping it

    private func keep() {
        guard var page else { return }
        page.title = titleField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        page.shared = Date()
        do {
            try SharedPages.leave(page)
        } catch {
            status.text = "Couldn’t save: \(error.localizedDescription)"
            return
        }
        save.isEnabled = false
        status.text = "Saved. It will be in Weft when you next open it."
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.close(cancelled: false) }
    }

    private func close(cancelled: Bool) {
        if cancelled {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
