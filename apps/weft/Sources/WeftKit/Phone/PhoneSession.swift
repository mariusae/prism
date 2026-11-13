#if os(iOS)
import Prism
import SwiftUI
import UIKit

/// The phone's one graph, held for the windows and for the pushes that
/// come when there is no window: where it is kept, whether it has been
/// brought down, and the store over it.
@MainActor
@Observable
public final class PhoneSession {
    public static let shared = PhoneSession()

    public private(set) var store: GraphStore?
    public private(set) var failure: String?
    /// Whether the welcome has been gone through.
    public var onboarded: Bool {
        didSet { UserDefaults.standard.set(onboarded, forKey: "Onboarded") }
    }

    @ObservationIgnored private var pushToken: Data?
    @ObservationIgnored private var registered: String?
    @ObservationIgnored private var lastActive = Date.distantPast

    private init() {
        onboarded = UserDefaults.standard.bool(forKey: "Onboarded")
    }

    /// Where the graph brought down from GitHub is kept: the app's own folder.
    public static var cloneFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Weft/Graph", isDirectory: true)
    }

    public static var hasClone: Bool {
        FileManager.default.fileExists(atPath: cloneFolder.appendingPathComponent(".git").path)
    }

    /// A graph named with `-GraphPath`, for trying the app out; else the clone.
    private static var folder: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-GraphPath"), arguments.indices.contains(flag + 1) { return URL(fileURLWithPath: arguments[flag + 1]) }
        return hasClone ? cloneFolder : nil
    }

    /// Where, in the app group, the repository the graph is kept in is noted.
    static let graphRemoteKey = "GraphRemote"

    /// The repository the other app's graph is kept in, if it has noted it.
    static var notedRemote: String? { UserDefaults(suiteName: Setup.appGroup)?.string(forKey: graphRemoteKey) }

    /// Whether the graph is one named to try the app out with: no welcome is shown for it.
    public static var isTrial: Bool { ProcessInfo.processInfo.arguments.contains("-GraphPath") }

    /// Opens the graph, if there is one and it is not open.
    public func open() {
        guard store == nil, let folder = Self.folder else { return }
        do {
            store = try GraphStore(root: folder, token: Account.shared.tokenProvider, relay: Setup.relayHost)
            failure = nil
            register()
            // Which repository the graph is, for the other app — Weft Reader — to bring down the same.
            if !Self.isTrial, let remote = store?.remote { UserDefaults(suiteName: Setup.appGroup)?.set(remote, forKey: Self.graphRemoteKey) }
            store?.takeSharedPages()
        } catch {
            failure = "\(error)"
        }
    }

    /// Opens the graph again: as the account just signed in to, or as none.
    public func reopen() {
        store?.close()
        store = nil
        open()
    }

    /// Signed out and the graph let go of: back to the welcome.
    public func leave() {
        store?.close()
        store = nil
        Account.shared.signOut()
        onboarded = false
    }

    // MARK: Coming and going

    /// The app came to the front: what other devices wrote meanwhile is fetched.
    public func activated() {
        // Pages shared from other apps meanwhile: their link notes, made and shown.
        store?.takeSharedPages()
        guard let store, Date().timeIntervalSince(lastActive) > 1.5 else { return }
        lastActive = Date()
        if store.relay != .listening { store.reconnectRelay() }
        store.engine.sync()
    }

    /// The app is leaving the front: what is written is saved, and sent.
    public func resigned() {
        guard let store else { return }
        store.saveAll()
        store.rememberRivers()
        store.engine.push()
    }

    // MARK: Pushes

    public func received(pushToken token: Data) {
        if token != pushToken { registered = nil }
        pushToken = token
        register()
    }

    /// Tells the relay this phone's token for the graph's repository, once
    /// there is a graph, a sign-in and a token.
    private func register() {
        guard let pushToken, let store, let host = Setup.relayHost, Account.shared.isSignedIn, let remote = store.remote, registered != remote else { return }
        registered = remote
        let hex = pushToken.map { String(format: "%02x", $0) }.joined()
        let topic = Bundle.main.bundleIdentifier ?? "org.mutable.weft"
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
        let engine = store.engine
        Task.detached { [weak self] in
            do {
                try engine.registerPhone(relay: host, pushToken: hex, topic: topic, sandbox: sandbox)
                await MainActor.run { store.note("relay", "Registered this phone with \(host) for silent pushes") }
            } catch {
                await MainActor.run {
                    self?.registered = nil
                    store.note("relay", "Could not register this phone with \(host): \(error)")
                }
            }
        }
    }

    /// Another device pushed: sync — opening the graph first, when the push
    /// woke the app with no window to have opened it. Says whether anything came in.
    public func pushed(_ done: @escaping (Bool) -> Void) {
        open()
        guard let store else { return done(false) }
        store.note("relay", "Woken by a silent push: syncing")
        Task { done(await store.syncAndWait()) }
    }
}

/// The app's root on the phone: the welcome until there is a graph, then its rivers.
public struct PhoneRoot: View {
    private let session = PhoneSession.shared
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        Group {
            if let store = session.store, session.onboarded || PhoneSession.isTrial {
                #if DEBUG
                if let line = PictureHarness.line { PictureHarness(store: store, line: line) } else { PhoneShell(store: store) }
                #else
                PhoneShell(store: store)
                #endif
            } else {
                Onboarding()
            }
        }
        .tint(Color.inkAccent)
        .onAppear { session.open() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: session.activated()
            case .inactive, .background: session.resigned()
            @unknown default: break
            }
        }
        .onOpenURL { url in
            // weft://river/<name>: that river, shown.
            guard url.scheme == "weft", url.host == "river", let store = session.store else { return }
            let name = url.pathComponents.dropFirst().joined(separator: "/").removingPercentEncoding ?? ""
            if !name.isEmpty { store.openSaved(name) }
        }
    }
}
#endif
