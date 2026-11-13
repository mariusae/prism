import Prism
import PrismEditor
import PrismEmblem
import SwiftUI

/// A link alone on its row, shown as the card of what it links to
/// (`<!-- card -->` in the note): a page on the web — its picture, its
/// title, a line of what it is, its site — or a note of the graph — its
/// icon, its title, its first lines. Clicked, it is gone to; its menu
/// shows it as its words again.
struct LinkCardBlock: View {
    let store: GraphStore
    /// What it links to, as the editor says it: `web:` and an address, `page:` and a name.
    let source: String
    /// Gone to: the page opened, or the address in the browser.
    var open: (EditorLink) -> Void
    var showAsLink: (() -> Void)?

    private var link: EditorLink? {
        if source.hasPrefix("web:") { return .web(String(source.dropFirst(4))) }
        if source.hasPrefix("page:") { return .page(String(source.dropFirst(5))) }
        return nil
    }

    var body: some View {
        if let link {
            HStack(alignment: .top, spacing: 12) {
                switch link {
                case .web(let address): web(address)
                case .page(let name): page(name)
                case .tag: EmptyView()
                }
            }
            .padding(10)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.inkText.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.inkRule))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { open(link) }
            .contextMenu {
                Button("Open", systemImage: "arrow.up.right") { open(link) }
                if let showAsLink { Button("Show as Link", systemImage: "link") { showAsLink() } }
            }
            #if os(macOS)
            .pointerStyle(.link)
            #endif
        }
    }

    private static func host(_ address: String) -> String {
        (URL(string: address)?.host ?? address).replacingOccurrences(of: "www.", with: "")
    }

    /// A page on the web; `title` and `cover`, a note's kept of it, before what the page says.
    @ViewBuilder private func web(_ address: String, title: String? = nil, cover: PlatformImage? = nil, about: String? = nil) -> some View {
        let found = WebCards.shared.found[address]
        thumbnail((cover ?? found?.image).map { Image(platform: $0) }, symbol: "link")
        VStack(alignment: .leading, spacing: 3) {
            Text(title ?? found?.title ?? Self.host(address)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.inkText).lineLimit(2)
            if let detail = about ?? found?.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Color.inkSecondary).lineLimit(2)
            }
            Text(Self.host(address)).font(.caption).foregroundStyle(Color.inkFaint).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { WebCards.shared.look(address) }
    }

    @ViewBuilder private func page(_ name: String) -> some View {
        let found = store.resolve(name)
        let path = found?.path
        let source = path.flatMap { (try? store.engine.read(path: $0)) ?? nil }
        // As an outline: its rows' words, without their bullets.
        let editor = source.map { NoteEditor.open(source: $0, mode: .outline) }
        let label = path.map { store.label(path: $0, title: Days.shown(name)) } ?? Days.shown(name)
        let emblem = path.map { store.emblem(path: $0, title: label) } ?? Emblem(title: label)
        let cover = editor?.field(key: "cover").flatMap { Pictures.image(at: $0, in: store) }
        // A note kept of a page on the web: that page's card, called by the note's title.
        if let source, let address = ReaderSource.ownAddress(in: source) {
            let said = editor?.fields().first { $0.key.lowercased() == "description" }?.values.first
            web(address, title: label, cover: cover, about: said ?? Self.description(in: source))
        } else {
            note(label: label, emblem: emblem, cover: cover, editor: editor, exists: found?.exists == true)
        }
    }

    /// A link note's `Description:` row, if it says anything.
    private static func description(in source: String) -> String? {
        for line in source.components(separatedBy: "\n") {
            let words = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- Description:", "Description:"] where words.hasPrefix(marker) {
                let said = words.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                return said.isEmpty ? nil : said
            }
        }
        return nil
    }

    @ViewBuilder private func note(label: String, emblem: Emblem, cover: PlatformImage?, editor: NoteEditor?, exists: Bool) -> some View {
        if let cover {
            thumbnail(Image(platform: cover), symbol: "doc.text")
        } else {
            Group {
                if emblem.isShown { EmblemView(emblem, size: 28, quiet: Color.inkSecondary) } else {
                    Image(systemName: "doc.text").font(.system(size: 22)).foregroundStyle(Color.inkSecondary)
                }
            }
            .frame(width: 40, height: 40)
        }
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.inkText).lineLimit(2)
            let lines = editor.map { editor in
                editor.text().split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" }).map { inlinePlainText(text: String($0)) }.filter { !$0.isEmpty && $0 != label }
            } ?? []
            if !lines.isEmpty {
                Text(lines.prefix(3).joined(separator: " · ")).font(.system(size: 12.5)).foregroundStyle(Color.inkSecondary).lineLimit(2)
            } else if !exists {
                Text("No note has this title yet.").font(.system(size: 12.5)).foregroundStyle(Color.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func thumbnail(_ image: Image?, symbol: String) -> some View {
        Group {
            if let image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Color.inkFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.inkText.opacity(0.05))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A link note's heading, as the card of the page it keeps: the page's
/// picture, the note's title, what the page is, its site. Only how such
/// a note is shown — its file is as it was. Nil, and the heading is
/// plain, until something of the page is known: a picture or a line of
/// what it is.
struct LinkNoteHeader: View {
    let address: String
    let title: String
    /// The note's own `cover:`, before the page's picture.
    var cover: PlatformImage?
    var titleFont: Font

    /// Whether there is enough of the page known to show it as its card.
    static func isAvailable(_ address: String, cover: PlatformImage?) -> Bool {
        let found = WebCards.shared.found[address]
        return cover != nil || found?.image != nil || (found?.detail?.isEmpty == false)
    }

    private var host: String { (URL(string: address)?.host ?? address).replacingOccurrences(of: "www.", with: "") }

    var body: some View {
        let found = WebCards.shared.found[address]
        let picture = cover ?? found?.image
        HStack(alignment: .top, spacing: 14) {
            if let picture {
                Image(platform: picture).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(titleFont).foregroundStyle(Color.inkText).lineLimit(3)
                if let detail = found?.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 13.5)).foregroundStyle(Color.inkSecondary).lineLimit(3)
                }
                HStack(spacing: 4) {
                    Image(systemName: "link").font(.system(size: 10, weight: .semibold))
                    Text(host).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(Color.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
