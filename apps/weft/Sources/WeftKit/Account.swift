import AuthenticationServices
import Prism
import Security
import SwiftUI

/// What the build was told about the world outside the graph: the GitHub
/// App to sign in through, and the relay that says when another device
/// has pushed. Put in Info.plist by scripts/build-app.sh on the Mac and
/// iOS/GitHub.xcconfig on the phone, from a file never committed.
public enum Setup {
    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    public static var clientID: String { info("GitHubClientID") }
    public static var clientSecret: String { info("GitHubClientSecret") }
    public static var appSlug: String { info("GitHubAppSlug") }
    /// The relay's host, if the build names one.
    public static var relayHost: String? {
        let host = info("SyncRelayHost")
        return host.isEmpty ? nil : host
    }

    public static var hasGitHub: Bool { !clientID.isEmpty }

    /// What the app is called, as the phone shows it: Weft, or Weft Reader.
    public static var appName: String {
        let shown = info("CFBundleDisplayName")
        return shown.isEmpty ? "Weft" : shown
    }

    /// Whether the app keeps its sign-in in the keychain group Weft and
    /// Weft Reader share (`SharesSignIn`), so that signing in to one signs
    /// in both. The Mac's does not.
    static var sharesSignIn: Bool { Bundle.main.object(forInfoDictionaryKey: "SharesSignIn") as? Bool == true }

    /// The app group they share, as the share extension does: what is
    /// passed between them is left there.
    public static let appGroup = "group.org.mutable.weft"

    /// Where GitHub sends the browser back to: the GitHub App's callback URL.
    static let callbackScheme = "com.mariusae.reflect"
    static var redirectURI: String { "\(callbackScheme)://oauth/callback" }
}

/// The keychain, as the engine's account keeps its tokens in it: one
/// opaque string. On the phone it can be read once the phone has been
/// unlocked, so that a sync in the background has its token.
///
/// With a keychain group (Weft and Weft Reader on the phone), the tokens
/// are one item in it, which both apps read: signed in to one, signed in
/// to both. Weft's own item, kept before there was a group, is found
/// where it is and moved into the group.
final class KeychainVault: TokenVault, @unchecked Sendable {
    private let group = Setup.sharesSignIn ? KeychainVault.defaultGroup : nil

    /// The group an item goes into when it is given none: the first of the
    /// app's `keychain-access-groups` — the shared one, `…org.mutable.weft.shared`
    /// with the team's prefix, which only the keychain knows whole. Asked of
    /// it once, by a moment's item.
    private static let defaultGroup: String? = {
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.mutable.weft.probe", kSecAttrAccount as String: "group"]
        SecItemDelete(probe as CFDictionary)
        var added = probe
        added[kSecValueData as String] = Data()
        added[kSecReturnAttributes as String] = true
        var found: AnyObject?
        guard SecItemAdd(added as CFDictionary, &found) == errSecSuccess else { return nil }
        SecItemDelete(probe as CFDictionary)
        return (found as? [String: Any])?[kSecAttrAccessGroup as String] as? String
    }()
    /// One name for both apps where they share — Weft's, as it always was.
    private var service: String { group != nil ? "org.mutable.weft.github" : "\(Bundle.main.bundleIdentifier ?? "com.mariusae.weft").github" }
    private let account = "tokens"

    /// The item, in whatever group it is in: the shared one, or the app's own.
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> String? {
        var found: AnyObject?
        var query = query
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        if SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let item = found as? [String: Any], let data = item[kSecValueData as String] as? Data,
           let tokens = String(data: data, encoding: .utf8) {
            // Kept before the group was: moved into it, for the other app to read —
            // put there first, and only then taken from where it was.
            if let group, let was = item[kSecAttrAccessGroup as String] as? String, was != group {
                var moved = self.query
                moved[kSecValueData as String] = data
                moved[kSecAttrAccessGroup as String] = group
                #if os(iOS)
                moved[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                #endif
                if SecItemAdd(moved as CFDictionary, nil) == errSecSuccess {
                    var old = self.query
                    old[kSecAttrAccessGroup as String] = was
                    SecItemDelete(old as CFDictionary)
                }
            }
            return tokens
        }
        #if os(iOS)
        // Nothing of this app's own: what the Weft it replaces kept, taken
        // over — so that an update over it is still signed in.
        if let taken = Self.inherited() {
            save(tokens: taken)
            return taken
        }
        #endif
        return nil
    }

    #if os(iOS)
    /// The tokens the earlier Weft kept, as the engine keeps them. That
    /// app is this one to the keychain — the same identifier, the same
    /// team — so what it stored can be read.
    private static func inherited() -> String? {
        struct Old: Decodable {
            var access: String
            var accessExpires: Date?
            var refresh: String?
            var refreshExpires: Date?
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.mariusae.Reflect.github",
            kSecAttrAccount as String: "github.tokens", kSecReturnData as String: true,
        ]
        var found: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data, let old = try? JSONDecoder().decode(Old.self, from: data) else { return nil }
        var kept: [String: Any] = ["access_token": old.access]
        if let at = old.accessExpires { kept["expires_at"] = UInt64(max(at.timeIntervalSince1970, 0)) }
        if let refresh = old.refresh { kept["refresh_token"] = refresh }
        if let at = old.refreshExpires { kept["refresh_expires_at"] = UInt64(max(at.timeIntervalSince1970, 0)) }
        return (try? JSONSerialization.data(withJSONObject: kept)).flatMap { String(data: $0, encoding: .utf8) }
    }
    #endif

    func save(tokens: String?) {
        SecItemDelete(query as CFDictionary)
        guard let tokens else { return }
        var item = query
        item[kSecValueData as String] = Data(tokens.utf8)
        if let group { item[kSecAttrAccessGroup as String] = group }
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// The GitHub account the graph is synced as. The account itself — its
/// tokens, their renewal, what it may reach — is the engine's; this is
/// the browser sheet to sign in through, and what the interface shows.
@MainActor
@Observable
public final class Account {
    public static let shared = Account()

    /// The engine's account; none in a build that names no GitHub App.
    @ObservationIgnored let github: GitHubAccount?
    public private(set) var isSignedIn = false
    public private(set) var login: String?
    public private(set) var isBusy = false
    public var failure: String?
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private let anchor = Anchor()

    private init() {
        // A headless run — a snapshot, a benchmark — leaves the keychain alone.
        let headless = ProcessInfo.processInfo.environment["WEFT_SNAPSHOT"] != nil || ProcessInfo.processInfo.environment["WEFT_BENCH"] != nil
        guard Setup.hasGitHub, !headless else {
            github = nil
            return
        }
        let github = GitHubAccount(clientId: Setup.clientID, clientSecret: Setup.clientSecret, vault: KeychainVault())
        self.github = github
        isSignedIn = github.isSignedIn()
        if isSignedIn { whoAmI() }
    }

    public var isAvailable: Bool { github != nil }

    /// The token the engine syncs with, and shows the relay: asked for on
    /// the engine's threads, renewed there when it is running out.
    public var tokenProvider: TokenProvider? {
        guard let github, isSignedIn else { return nil }
        return Provider(github: github)
    }

    private final class Provider: TokenProvider, @unchecked Sendable {
        let github: GitHubAccount
        init(github: GitHubAccount) { self.github = github }
        func token() throws -> String { try github.accessToken() }
    }

    private func whoAmI() {
        guard let github else { return }
        Task.detached {
            let user = try? github.user()
            await MainActor.run { self.login = user?.login }
        }
    }

    /// Signs in through GitHub's own pages, in the system's browser sheet.
    /// `done` is told once the account is in — the graph is then opened
    /// again, as that account.
    public func signIn(done: @escaping @MainActor () -> Void) {
        guard let github, !isBusy else { return }
        failure = nil
        guard let begun = try? github.beginSignIn(redirectUri: Setup.redirectURI), let url = URL(string: begun.url) else {
            failure = "Could not start signing in."
            return
        }
        isBusy = true
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme(Setup.callbackScheme)) { [weak self] back, error in
            Task { @MainActor in
                guard let self else { return }
                self.session = nil
                let items = back.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                let value = { (name: String) in items.first(where: { $0.name == name })?.value }
                guard let code = value("code"), value("state") == begun.state else {
                    // Closed by the person: nothing to say.
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { self.failure = value("error_description") ?? error?.localizedDescription ?? "GitHub did not sign you in." }
                    self.isBusy = false
                    return
                }
                // The exchange waits on GitHub: off the main thread.
                let outcome: Result<Void, Error> = await Task.detached { Result { try github.finishSignIn(code: code, redirectUri: Setup.redirectURI, verifier: begun.verifier) } }.value
                self.isBusy = false
                switch outcome {
                case .success:
                    self.isSignedIn = true
                    self.whoAmI()
                    done()
                case .failure(let error):
                    self.failure = "\(error)"
                }
            }
        }
        session.presentationContextProvider = anchor
        self.session = session
        if !session.start() {
            isBusy = false
            failure = "Could not open GitHub's sign-in page."
        }
    }

    public func signOut() {
        github?.signOut()
        isSignedIn = false
        login = nil
    }

    /// The page where the GitHub App is let into repositories.
    public var installURL: URL? { Setup.appSlug.isEmpty ? nil : URL(string: githubInstallUrl(appSlug: Setup.appSlug)) }

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            #if os(macOS)
            return MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
            #else
            return ASPresentationAnchor()
            #endif
        }
    }
}
