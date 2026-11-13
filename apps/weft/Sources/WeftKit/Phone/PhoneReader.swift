#if os(iOS)
import CryptoKit
import Prism
import PrismEditor
import SwiftUI
import UIKit
import WebKit

/// A note's pages read: each address it has — a link note's own first,
/// then every other link and PDF — its words alone, set for reading, or
/// the site itself; where it was read to kept; a passage highlighted
/// written back into the note, under the link, and marked again whenever
/// the page is read. On the phone, over the river.
struct ReaderPanel: View {
    let store: GraphStore
    /// The river it is read over, closed back into; none in Weft Reader,
    /// where the reader is the whole app.
    var river: River?
    /// The note whose pages these are.
    let place: River.Place
    /// Done with, or put off, where there is no river to go on in: the
    /// app's to go on to the next.
    var onFinish: ((ReadingQueue.Snooze?) -> Void)?
    @State private var index = 0
    @State private var reading = true
    @State private var web = ReaderWeb()

    private var sources: [ReaderSource] {
        _ = store.indexRevision
        return store.sources(path: place.path)
    }

    private var label: String { store.label(path: place.path, title: place.title) }
    private var inInbox: Bool { store.draft(path: place.path, title: place.title).isMarked("inbox") }

    var body: some View {
        let sources = sources
        let source = sources.indices.contains(index) ? sources[index] : nil
        VStack(spacing: 0) {
            bar(sources, source)
            Divider()
            if let source {
                ReaderWebView(web: web)
                    .ignoresSafeArea(edges: .bottom)
                    .task(id: "\(source.url) \(reading) \(TextSettings.size) \(TextSettings.face.rawValue)") {
                        web.show(source, reading: reading && !source.isPDF, marks: store.highlights(in: place.path, of: source.address), root: store.root)
                    }
                    .overlay(alignment: .bottom) { if inInbox { queueBar } }
            } else {
                ContentUnavailableView("Nothing to Read", systemImage: "doc.richtext", description: Text("\u{201C}\(label)\u{201D} links to no page."))
                    .frame(maxHeight: .infinity)
            }
        }
        .background(Color.inkCard)
        .foregroundStyle(Color.inkText)
        .onAppear { reading = sources.first.map { ReaderPlace.reads($0.url) } ?? true }
    }

    private func bar(_ sources: [ReaderSource], _ source: ReaderSource?) -> some View {
        HStack(spacing: 14) {
            if let river {
                Button { river.reading = nil } label: { Image(systemName: "xmark").frame(minWidth: 28, minHeight: 32).contentShape(Rectangle()) }
                    .accessibilityLabel("Close the Reader")
            }
            if sources.count > 1 {
                Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.left").frame(minWidth: 24, minHeight: 32).contentShape(Rectangle()) }
                    .disabled(index == 0)
                    .accessibilityLabel("The page before")
                Button { index = min(sources.count - 1, index + 1) } label: { Image(systemName: "chevron.right").frame(minWidth: 24, minHeight: 32).contentShape(Rectangle()) }
                    .disabled(index >= sources.count - 1)
                    .accessibilityLabel("The next page")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(web.title ?? source?.name ?? label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.inkText)
                    .lineLimit(1)
                if let source {
                    Text(source.url.host() ?? source.name)
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let source {
                Button { highlight(source) } label: { Image(systemName: "highlighter").frame(minWidth: 28, minHeight: 32).contentShape(Rectangle()) }
                    .accessibilityLabel("Highlight the words chosen, into \u{201C}\(label)\u{201D}")
                if !source.isPDF {
                    Button {
                        reading.toggle()
                        ReaderPlace.setReads(reading, for: source.url)
                    } label: { Image(systemName: reading ? "doc.plaintext.fill" : "doc.plaintext").frame(minWidth: 28, minHeight: 32).contentShape(Rectangle()) }
                        .accessibilityLabel(reading ? "Show the Site" : "Show Its Words Alone")
                }
                if source.isOnline {
                    Link(destination: source.url) { Image(systemName: "safari").frame(minWidth: 28, minHeight: 32).contentShape(Rectangle()) }
                        .accessibilityLabel("Open in the Browser")
                }
            }
        }
        .font(.system(size: 17))
        .buttonStyle(.plain)
        .foregroundStyle(Color.inkAccent)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// A note saved to read: done with it, or put off — and the next in
    /// the queue read, if there is one.
    private var queueBar: some View {
        HStack(spacing: 18) {
            Menu {
                ForEach(ReadingQueue.Snooze.allCases, id: \.self) { snooze in
                    Button(snooze.title, systemImage: snooze.symbol) { finish(snooze) }
                }
            } label: {
                Label("Later", systemImage: "clock")
            }
            Divider().frame(height: 18)
            Button { finish(nil) } label: { Label("Done", systemImage: "checkmark") }
        }
        .font(.callout.weight(.medium))
        .buttonStyle(.plain)
        .foregroundStyle(Color.inkAccent)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.bottom, 18)
    }

    private func finish(_ snooze: ReadingQueue.Snooze?) {
        guard let river else { return onFinish?(snooze) ?? () }
        store.finishReading(path: place.path, title: place.title, snooze: snooze)
        if let next = store.readingQueue().pages.first(where: { $0.path != place.path }) {
            store.show(path: next.path, title: next.title, in: river)
            river.reading = River.Place(path: next.path, title: next.title)
        } else {
            river.reading = nil
        }
    }

    /// The words chosen, marked in the page and written into the note.
    private func highlight(_ source: ReaderSource) {
        web.highlight { passage in
            guard !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            store.highlight(passage, of: source.address, in: place.path)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

// MARK: - Where it was read to

/// How far down each page was read, by its address — as the site sets it,
/// and as the reader does — and which it was read in: kept across launches.
enum ReaderPlace {
    private static func key(_ url: URL, reading: Bool) -> String { (reading ? "Reader.place." : "Reader.webPlace.") + url.absoluteString }

    static func saved(_ url: URL, reading: Bool) -> Double { UserDefaults.standard.double(forKey: key(url, reading: reading)) }

    static func save(_ fraction: Double, for url: URL, reading: Bool) {
        UserDefaults.standard.set(max(0, min(1, fraction)), forKey: key(url, reading: reading))
    }

    /// Read in the reader, its words alone — as it is until the site is chosen — or as the site has it.
    static func reads(_ url: URL) -> Bool { UserDefaults.standard.object(forKey: "Reader.reads." + url.absoluteString) as? Bool ?? true }

    static func setReads(_ reads: Bool, for url: URL) { UserDefaults.standard.set(reads, forKey: "Reader.reads." + url.absoluteString) }
}

// MARK: - The article

/// A page's words, taken out of the page: its title, its site, its icon,
/// its body as plain HTML — kept on the phone, to read again at once.
struct ReaderArticle: Codable {
    var title: String
    var site: String
    var byline: String?
    var icon: String?
    var html: String
    var words: Int

    private static var folder: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Weft/Reader", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func file(_ url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(String(digest.prefix(32)) + ".json")
    }

    static func cached(_ url: URL) -> ReaderArticle? {
        guard let data = try? Data(contentsOf: file(url)) else { return nil }
        return try? JSONDecoder().decode(ReaderArticle.self, from: data)
    }

    private func keep(for url: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.file(url), options: .atomic) }
    }

    /// The page loaded, out of sight, as a browser would — its scripts run,
    /// for pages made by them — and its words taken out.
    @MainActor
    static func fetch(_ url: URL, done: @escaping @MainActor (ReaderArticle?) -> Void) {
        ReaderLoader(url: url) { article in
            article?.keep(for: url)
            done(article)
        }.start()
    }
}

/// A page loaded in a web view no one sees, its words taken out once it
/// has loaded — or given up on after a while.
@MainActor
private final class ReaderLoader: NSObject, WKNavigationDelegate {
    private let url: URL
    private var done: (@MainActor (ReaderArticle?) -> Void)?
    private let web: WKWebView
    private var finished = false
    /// Kept till done: nothing else holds it.
    private static var loading: Set<ReaderLoader> = []

    init(url: URL, done: @escaping @MainActor (ReaderArticle?) -> Void) {
        self.url = url
        self.done = done
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        web.navigationDelegate = self
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    }

    func start() {
        Self.loading.insert(self)
        web.load(URLRequest(url: url, timeoutInterval: 30))
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.extract() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A moment for what its scripts put in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.extract() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }

    private func extract() {
        guard !finished else { return }
        web.evaluateJavaScript(ReaderPage.extraction) { [weak self] value, _ in
            guard let self else { return }
            guard let json = value as? String, let data = json.data(using: .utf8),
                  let article = try? JSONDecoder().decode(ReaderArticle.self, from: data), article.words > 30 else { return self.finish(nil) }
            self.finish(article)
        }
    }

    private func finish(_ article: ReaderArticle?) {
        guard !finished else { return }
        finished = true
        done?(article)
        done = nil
        web.stopLoading()
        Self.loading.remove(self)
    }
}

// MARK: - The page, as read

enum ReaderPage {
    /// The passages highlighted before, marked again in the page shown.
    static func marking(_ passages: [String]) -> String? {
        guard !passages.isEmpty, let data = try? JSONEncoder().encode(passages), let list = String(data: data, encoding: .utf8) else { return nil }
        return "readerMarkAll(\(list))"
    }

    /// Takes a page's words out of it: the element with the most paragraph
    /// text in it — an article, the main part, else the body — its scripts,
    /// menus, forms and asides let go, only the plain marks of text kept.
    static let extraction = #"""
    (function() {
      function textOf(el) { return (el.innerText || '').replace(/\s+/g, ' ').trim(); }
      var candidates = Array.from(document.querySelectorAll('article, main, [role=main], .post, .entry-content, .article-body, .post-content, #content, .content'));
      candidates.push(document.body);
      var best = document.body, bestScore = 0;
      var pScore = function(el) { return Array.from(el.querySelectorAll('p')).reduce(function(n, p) { return n + textOf(p).length; }, 0); };
      // Any element holding many paragraphs, too: the closest such.
      Array.from(document.querySelectorAll('div, section')).forEach(function(el) {
        var direct = Array.from(el.children).filter(function(c) { return c.tagName === 'P'; }).length;
        if (direct >= 3) candidates.push(el);
      });
      candidates.forEach(function(el) {
        var score = pScore(el);
        // The tightest: a little less for a bigger box.
        score -= textOf(el).length * 0.05;
        if (score > bestScore) { bestScore = score; best = el; }
      });
      var root = best.cloneNode(true);
      root.querySelectorAll('script, style, noscript, nav, aside, footer, header, form, button, iframe, svg, input, select, textarea, [role=navigation], [aria-hidden=true], .share, .social, .newsletter, .subscribe, .related, .comments').forEach(function(el) { el.remove(); });
      var keep = {A:1, P:1, H1:1, H2:1, H3:1, H4:1, H5:1, H6:1, UL:1, OL:1, LI:1, BLOCKQUOTE:1, EM:1, I:1, STRONG:1, B:1, CODE:1, PRE:1, IMG:1, FIGURE:1, FIGCAPTION:1, BR:1, HR:1, SUP:1, SUB:1, TABLE:1, TR:1, TD:1, TH:1, TBODY:1, THEAD:1};
      function clean(el) {
        Array.from(el.children).forEach(function(child) {
          clean(child);
          if (!keep[child.tagName]) {
            while (child.firstChild) el.insertBefore(child.firstChild, child);
            child.remove();
            return;
          }
          var href = child.getAttribute('href'), src = child.getAttribute('src') || child.getAttribute('data-src'), alt = child.getAttribute('alt');
          Array.from(child.attributes).forEach(function(a) { child.removeAttribute(a.name); });
          if (child.tagName === 'A' && href) child.setAttribute('href', new URL(href, location.href).href);
          if (child.tagName === 'IMG') {
            if (!src) { child.remove(); return; }
            child.setAttribute('src', new URL(src, location.href).href);
            if (alt) child.setAttribute('alt', alt);
          }
        });
      }
      clean(root);
      // Its title, as the page says it; drop it from the body, if it begins with it.
      var meta = function(name) { var el = document.querySelector('meta[property="' + name + '"], meta[name="' + name + '"]'); return el ? el.getAttribute('content') : null; };
      var title = meta('og:title') || (document.querySelector('h1') ? textOf(document.querySelector('h1')) : document.title) || '';
      var first = root.querySelector('h1');
      if (first && textOf(first) === title.trim()) first.remove();
      var site = meta('og:site_name') || location.hostname.replace(/^www\./, '');
      var icon = document.querySelector('link[rel~="apple-touch-icon"], link[rel~="icon"]');
      var words = textOf(root).split(' ').length;
      return JSON.stringify({ title: title.trim(), site: site, byline: meta('author'), icon: icon ? new URL(icon.getAttribute('href'), location.href).href : null, html: root.innerHTML, words: words });
    })();
    """#

    /// Where it was read to, a passage highlighted, those before marked:
    /// in every page the view loads, the reader's own or the site's.
    static let script = #"""
var readerTimer = null;
// Highlights' yellow, the page's own or the reader's.
(function() {
  var style = document.createElement('style');
  style.textContent = 'mark.reader { background: rgba(255, 214, 10, .45); color: inherit; border-radius: 2px; } '
    + '@media (prefers-color-scheme: dark) { mark.reader { background: rgba(217, 179, 51, .40); } }';
  (document.head || document.documentElement).appendChild(style);
})();
function readerPlace() {
  var max = document.documentElement.scrollHeight - window.innerHeight;
  return max > 0 ? Math.max(0, Math.min(1, window.scrollY / max)) : 0;
}
// Whether the page pins something along its top — a header kept in
// sight as it is read — told to whoever listens, when it changes.
var readerPinnedLast = null;
function readerPinned() {
  for (var el = document.elementFromPoint(window.innerWidth / 2, 1); el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
    var position = getComputedStyle(el).position;
    if (position === 'fixed' || position === 'sticky') return true;
  }
  return false;
}
function readerTellPinned() {
  var pinned = window.webkit.messageHandlers.pinned;
  if (!pinned) return;
  var now = readerPinned();
  if (now !== readerPinnedLast) { readerPinnedLast = now; pinned.postMessage(now); }
}
window.addEventListener('load', function() { readerTellPinned(); setTimeout(readerTellPinned, 1000); });
window.addEventListener('scroll', function() {
  var moved = window.webkit.messageHandlers.moved;
  if (moved) moved.postMessage(window.scrollY);
  readerTellPinned();
  clearTimeout(readerTimer);
  readerTimer = setTimeout(function() { window.webkit.messageHandlers.scrolled.postMessage(readerPlace()); }, 250);
}, { passive: true });
function readerRestore(fraction) {
  var go = function() {
    var max = document.documentElement.scrollHeight - window.innerHeight;
    window.scrollTo(0, fraction * max);
  };
  go();
  // Again once its pictures are in, and the page longer.
  window.addEventListener('load', go);
  setTimeout(go, 400);
  setTimeout(go, 1500);
}
function readerWrap(range) {
  var nodes = [];
  var walker = document.createTreeWalker(range.commonAncestorContainer, NodeFilter.SHOW_TEXT, null);
  if (range.commonAncestorContainer.nodeType === Node.TEXT_NODE) nodes.push(range.commonAncestorContainer);
  while (walker.nextNode()) { if (range.intersectsNode(walker.currentNode)) nodes.push(walker.currentNode); }
  nodes.forEach(function(node) {
    var start = node === range.startContainer ? range.startOffset : 0;
    var end = node === range.endContainer ? range.endOffset : node.data.length;
    if (end <= start || !node.data.slice(start, end).trim()) return;
    var piece = node.splitText(start);
    piece.splitText(end - start);
    var mark = document.createElement('mark');
    mark.className = 'reader';
    piece.parentNode.insertBefore(mark, piece);
    mark.appendChild(piece);
  });
}
function readerStyle(face, size, leading) {
  var place = readerPlace();
  var root = document.documentElement.style;
  root.setProperty('--face', face);
  root.setProperty('--size', size + 'px');
  root.setProperty('--leading', leading);
  var max = document.documentElement.scrollHeight - window.innerHeight;
  window.scrollTo(0, place * max);
}
function readerHighlight() {
  var selection = window.getSelection();
  if (!selection.rangeCount) return '';
  var text = selection.toString();
  readerWrap(selection.getRangeAt(0));
  selection.removeAllRanges();
  return text;
}
function readerMarkAll(passages) {
  passages.forEach(function(passage) {
    var words = passage.replace(/\s+/g, ' ').trim();
    if (!words) return;
    window.getSelection().removeAllRanges();
    if (window.find(words, false, false, false, false, false, false)) {
      var selection = window.getSelection();
      if (selection.rangeCount) readerWrap(selection.getRangeAt(0));
    }
  });
  window.getSelection().removeAllRanges();
  window.scrollTo(0, window.scrollY);
}
"""#

    @MainActor
    static var userScript: WKUserScript { WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true) }

    /// The face notes are set in, as a page's CSS names it.
    @MainActor
    static var face: String {
        switch TextSettings.face {
        case .serif: return "ui-serif, 'New York', Georgia, serif"
        case .rounded: return "ui-rounded, -apple-system, system-ui, sans-serif"
        case .mono: return "ui-monospace, Menlo, monospace"
        default: return "-apple-system, system-ui, sans-serif"
        }
    }

    /// A page's words set to read: on Weft's paper, in its ink, light and
    /// dark, in the face and at the size notes are set in.
    @MainActor
    static func html(_ article: ReaderArticle) -> String {
        let title = article.title.replacingOccurrences(of: "<", with: "&lt;")
        let byline = article.byline.map { "<p class=\"byline\">" + $0.replacingOccurrences(of: "<", with: "&lt;") + "</p>" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
        :root { --face: \(face); --size: \(Int(TextSettings.size))px; --leading: 1.55; }
        :root { --paper: #fdfcf9; --ink: #2b2724; --soft: #6f665d; --rule: rgba(0,0,0,.12); color-scheme: light dark; }
        @media (prefers-color-scheme: dark) { :root { --paper: #23201d; --ink: #ece6dc; --soft: #a79e92; --rule: rgba(255,255,255,.14); } }
        html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; padding: 0 24px 96px; background: var(--paper); color: var(--ink);
               font-family: var(--face); font-weight: 400; font-size: var(--size); line-height: var(--leading); font-feature-settings: "kern" 1; hanging-punctuation: first;
               -webkit-hyphens: auto; hyphens: auto; word-wrap: break-word; }
        h1.title { font-family: var(--face); font-weight: 700; font-size: calc(var(--size) * 1.5); line-height: 1.15; margin: 20px 0 6px; letter-spacing: -0.01em; }
        .byline { color: var(--soft); font-size: 15px; margin: 0 0 28px; letter-spacing: .02em; }
        h2, h3, h4 { font-weight: 700; line-height: 1.25; margin: 1.6em 0 .5em; }
        h2 { font-size: calc(var(--size) * 1.4); } h3 { font-size: calc(var(--size) * 1.24); } h4 { font-size: calc(var(--size) * 1.12); }
        p { margin: 0 0 1em; }
        a { color: inherit; text-decoration-color: var(--soft); text-decoration-thickness: 1px; text-underline-offset: 3px; }
        img { max-width: 100%; height: auto; display: block; margin: 1.2em auto; border-radius: 6px; }
        figure { margin: 1.4em 0; } figcaption { color: var(--soft); font-size: 15px; line-height: 1.4; }
        blockquote { margin: 1.2em 0; padding-left: 18px; border-left: 2px solid var(--rule); color: var(--soft); font-style: italic; }
        pre, code { font-family: ui-monospace, Menlo, monospace; font-size: 15px; }
        pre { overflow-x: auto; padding: 12px; background: var(--rule); border-radius: 6px; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
        ul, ol { padding-left: 1.2em; } li { margin: .3em 0; }
        table { border-collapse: collapse; font-size: 16px; } td, th { border: 1px solid var(--rule); padding: 4px 8px; }
        #reader-column { max-width: 36em; margin: 0 auto; }
        </style></head><body>
        <div id="reader-column"><h1 class="title">\(title)</h1>\(byline)
        <div id="reader-article">\(article.html)</div></div>
        </body></html>
        """
    }
}

/// A message handler not keeping its controller: the web view's user content keeps it.
private final class WeakMessages: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// The reader's web view and what it does: kept by the panel, shown by `ReaderWebView`.
@MainActor
@Observable
final class ReaderWeb: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    /// The page's title, once its words are in.
    var title: String?
    @ObservationIgnored let view: WKWebView
    @ObservationIgnored private var shown: (url: URL, reading: Bool, set: String)?
    @ObservationIgnored private var marks: [String] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        let content = configuration.userContentController
        content.addUserScript(ReaderPage.userScript)
        for name in ["scrolled", "moved", "pinned"] { content.add(WeakMessages(self), name: name) }
        view.navigationDelegate = self
        view.isOpaque = false
        view.backgroundColor = .clear
    }

    /// A page shown: its words alone, fetched once and kept, or the site.
    /// A PDF in the graph is read where it is kept, under `root`.
    func show(_ source: ReaderSource, reading: Bool, marks: [String], root: URL) {
        // Set again when the face or the size notes are set in changes.
        let set = reading ? "\(ReaderPage.face) \(TextSettings.size)" : ""
        guard shown?.url != source.url || shown?.reading != reading || shown?.set != set else { return }
        shown = (source.url, reading, set)
        self.marks = marks
        title = nil
        guard reading else {
            if source.url.isFileURL { view.loadFileURL(source.url, allowingReadAccessTo: root) } else { view.load(URLRequest(url: source.url)) }
            return
        }
        let present: @MainActor (ReaderArticle?) -> Void = { [weak self] article in
            guard let self, self.shown?.url == source.url, self.shown?.reading == true else { return }
            guard let article else {
                // No words to take out: the site, then.
                self.view.load(URLRequest(url: source.url))
                return
            }
            self.title = article.title
            self.view.loadHTMLString(ReaderPage.html(article), baseURL: source.url)
        }
        if let cached = ReaderArticle.cached(source.url) { present(cached) } else { ReaderArticle.fetch(source.url, done: present) }
    }

    /// The words chosen in the page, marked there, and handed over.
    func highlight(_ done: @escaping @MainActor (String) -> Void) {
        view.evaluateJavaScript("readerHighlight()") { result, _ in
            if let passage = result as? String { done(passage) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let shown else { return }
        if title == nil { title = webView.title.flatMap { $0.isEmpty ? nil : $0 } }
        let place = ReaderPlace.saved(shown.url, reading: shown.reading)
        if place > 0 { webView.evaluateJavaScript("readerRestore(\(place))") }
        if let marking = ReaderPage.marking(marks) { webView.evaluateJavaScript(marking) }
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.name == "scrolled", let shown, let place = message.body as? Double else { return }
            ReaderPlace.save(place, for: shown.url, reading: shown.reading)
        }
    }
}

struct ReaderWebView: UIViewRepresentable {
    let web: ReaderWeb
    func makeUIView(context: Context) -> WKWebView { web.view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
