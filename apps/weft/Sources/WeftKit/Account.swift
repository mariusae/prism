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

    /// Where GitHub sends the browser back to: the GitHub App's callback URL.
    static let callbackScheme = "com.mariusae.reflect"
    static var redirectURI: String { "\(callbackScheme)://oauth/callback" }
}

/// The keychain, as the engine's account keeps its tokens in it: one
/// opaque string. On the phone it can be read once the phone has been
/// unlocked, so that a sync in the background has its token.
final class KeychainVault: TokenVault, @unchecked Sendable {
    private let service = "\(Bundle.main.bundleIdentifier ?? "com.mariusae.weft").github"
    private let account = "tokens"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> String? {
        var found: AnyObject?
        var query = query
        query[kSecReturnData as String] = true
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(tokens: String?) {
        SecItemDelete(query as CFDictionary)
        guard let tokens else { return }
        var item = query
        item[kSecValueData as String] = Data(tokens.utf8)
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
