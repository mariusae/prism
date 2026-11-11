#if os(iOS)
import Prism
import SwiftUI

/// The welcome: what Weft is, where the graph comes from, signing in and
/// bringing it down, and a few words to start by.
struct Onboarding: View {
    private enum Step: Int, CaseIterable { case welcome, place, github, ready }
    @State private var step = Step.welcome
    private let session = PhoneSession.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if step == .place || step == .github {
                    Button { go(Step(rawValue: step.rawValue - 1) ?? .welcome) } label: { Label("Back", systemImage: "chevron.backward").labelStyle(.titleAndIcon) }
                }
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 20)
            ZStack {
                switch step {
                case .welcome: welcome
                case .place: place
                case .github: GitHubConnect { go(.ready) }
                case .ready: ready
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(step)
            .frame(maxWidth: 560, maxHeight: .infinity)
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { one in
                    Circle().fill(one == step ? Color.inkAccent : Color.inkRule).frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.inkPage.ignoresSafeArea())
        .foregroundStyle(Color.inkText)
        .onAppear { if PhoneSession.hasClone, Account.shared.isSignedIn { step = .github } }
    }

    private func go(_ to: Step) {
        withAnimation(.snappy(duration: 0.3)) { step = to }
    }

    private func feature(_ symbol: String, _ title: String, _ said: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Color.inkAccent).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(said).font(.subheadline).foregroundStyle(Color.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "rectangle.stack").font(.system(size: 54, weight: .light)).foregroundStyle(Color.inkAccent)
            VStack(spacing: 6) {
                Text("Welcome to Weft").font(.largeTitle.weight(.semibold))
                Text("A river of small notes, kept in your own repository.").foregroundStyle(Color.inkSecondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 18) {
                feature("rectangle.stack", "Cards in a river", "Open a note and its card joins the river; follow a link and the next opens beside it.")
                feature("link", "Links, tags and queries", "Link with [[ ]] or @, tag freely, and let a query keep a list of what belongs together.")
                feature("arrow.triangle.2.circlepath", "One graph, every device", "Notes are files in a repository of yours, and are kept in step as you write.")
            }
            .padding(.horizontal, 28)
            Spacer()
            Button { go(.place) } label: { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 28)
                .padding(.bottom, 14)
        }
    }

    private var place: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Where is your graph?").font(.title.weight(.semibold))
            Text("Weft keeps your notes in a repository on GitHub, and a copy of it on this device.").foregroundStyle(Color.inkSecondary).multilineTextAlignment(.center).padding(.horizontal, 28)
            Button { go(.github) } label: {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "icloud.and.arrow.down").font(.system(size: 24)).foregroundStyle(Color.inkAccent).frame(width: 34)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Connect to GitHub").font(.headline)
                            Text("Recommended").font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                                .foregroundStyle(Color.inkAccent).background(Capsule().fill(Color.inkAccent.opacity(0.14)))
                        }
                        Text("Sign in, choose the repository your graph is kept in, and Weft brings it down into a folder of its own, kept in step with GitHub — instantly, through the sync relay.")
                            .font(.subheadline).foregroundStyle(Color.inkSecondary).multilineTextAlignment(.leading)
                    }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkFaint)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.inkCard))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.inkRule))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            Spacer()
            Spacer()
        }
    }

    private var ready: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle").font(.system(size: 54, weight: .light)).foregroundStyle(.green)
            Text("You\u{2019}re Set").font(.largeTitle.weight(.semibold))
            VStack(spacing: 16) {
                feature("plus", "Make a note", "Tap + below the river. A card is written as an outline; its menu switches it to text and back.")
                feature("link", "Link as you write", "Type [[ or @ and choose a note, a day, or a river.")
                feature("hand.draw", "Swipe a card", "Right, to make it a to-do or send it to the inbox. Left, to close or delete it.")
                feature("calendar", "Today", "The ⋯ menu opens today\u{2019}s note beside the others.")
            }
            .padding(.horizontal, 28)
            Spacer()
            Button {
                session.onboarded = true
                session.open()
            } label: { Text("Start Writing").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 28)
                .padding(.bottom, 14)
        }
    }
}

/// Signing in to GitHub, choosing the repository, and bringing it down.
struct GitHubConnect: View {
    var done: () -> Void
    private let account = Account.shared
    private let session = PhoneSession.shared
    @State private var repositories: [GitHubRepository]?
    @State private var cloning: String?
    @State private var progress: CloneProgress?
    @State private var problem: String?

    var body: some View {
        Group {
            if !account.isAvailable {
                ContentUnavailableView("GitHub Is Not Set Up", systemImage: "exclamationmark.triangle", description: Text("This build names no GitHub App, so it cannot sign in."))
            } else if let cloning {
                VStack(spacing: 14) {
                    Text("Bringing down \(cloning)").font(.headline)
                    if let progress { ProgressView(value: min(max(progress.fraction, 0), 1)) } else { ProgressView().progressViewStyle(.linear) }
                    Text(said(progress)).font(.footnote).monospacedDigit().foregroundStyle(Color.inkSecondary)
                    Text("All of its history comes too; a large graph takes a while.").font(.footnote).foregroundStyle(Color.inkFaint)
                }
                .padding(.horizontal, 36)
            } else if !account.isSignedIn {
                VStack(spacing: 18) {
                    Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 50, weight: .light)).foregroundStyle(Color.inkAccent)
                    Text("Sign In to GitHub").font(.title.weight(.semibold))
                    Text("Weft signs in with a GitHub App, and only sees the repositories you give it.").foregroundStyle(Color.inkSecondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                    Button(account.isBusy ? "Signing In…" : "Sign In with GitHub") { account.signIn { load() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(account.isBusy)
                    if let failure = account.failure { Text(failure).font(.footnote).foregroundStyle(.red).padding(.horizontal, 28) }
                }
            } else {
                Form {
                    if PhoneSession.hasClone {
                        Section {
                            Button { finish() } label: { Label("Open the Graph Here", systemImage: "folder") }
                        } header: { Text("Already Here") } footer: { Text("Brought down before, and kept in step with GitHub.") }
                    } else {
                        Section {
                            if let repositories {
                                ForEach(repositories, id: \.fullName) { repository in
                                    Button { bringDown(repository) } label: {
                                        HStack {
                                            Label(repository.fullName, systemImage: repository.isPrivate ? "lock" : "book.closed").foregroundStyle(Color.inkText)
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Color.inkFaint)
                                        }
                                    }
                                }
                            } else {
                                ProgressView()
                            }
                        } header: { Text("Choose Your Graph") } footer: {
                            Text(repositories?.isEmpty == true ? "Weft has not been given any repositories yet." : "The graph comes down to this device, into Weft's own folder, and is kept in step with GitHub.")
                        }
                    }
                    Section {
                        if let install = account.installURL { Link("Choose Repositories on GitHub…", destination: install) }
                        Button("Sign Out", role: .destructive) {
                            account.signOut()
                            repositories = nil
                        }
                    } header: { Text(account.login.map { "Signed in as \($0)" } ?? "Signed In") }
                    if let problem { Section { Text(problem).foregroundStyle(.red) } }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await reload() }
            }
        }
        .task { load() }
        .onChange(of: account.isSignedIn) { _, signedIn in if signedIn { load() } }
    }

    private func said(_ progress: CloneProgress?) -> String {
        guard let progress else { return "Reaching GitHub…" }
        switch progress.part {
        case .receiving: return "Receiving: \(progress.done.formatted()) of \(progress.total.formatted()) objects, \(ByteCountFormatter.string(fromByteCount: Int64(progress.bytes), countStyle: .file))"
        case .resolving: return "Putting the history together…"
        case .checkingOut: return progress.done >= progress.total ? "Reading your notes…" : "Writing out \(progress.done.formatted()) of \(progress.total.formatted()) files"
        }
    }

    private func load() {
        Task { await reload() }
    }

    private func reload() async {
        guard account.isSignedIn, let github = account.github else { return }
        let found: Result<[GitHubRepository], Error> = await Task.detached { Result { try github.repositories() } }.value
        switch found {
        case .success(let all): repositories = all
        case .failure(let error):
            repositories = []
            problem = "\(error)"
        }
    }

    private final class Watcher: CloneWatcher, @unchecked Sendable {
        let heard: @MainActor (CloneProgress) -> Void
        init(heard: @escaping @MainActor (CloneProgress) -> Void) { self.heard = heard }
        func onProgress(progress: CloneProgress) {
            Task { @MainActor in heard(progress) }
        }
    }

    private func finish() {
        session.open()
        done()
    }

    /// Clones into a folder beside where it is kept, and moves it into
    /// place whole: a clone cut short leaves nothing that looks like a graph.
    private func bringDown(_ repository: GitHubRepository) {
        guard let token = account.tokenProvider else { return }
        cloning = repository.fullName
        progress = nil
        problem = nil
        let folder = PhoneSession.cloneFolder
        let partial = folder.deletingLastPathComponent().appendingPathComponent("Graph.partial", isDirectory: true)
        let options = GraphStore.options
        let watcher = Watcher { now in if now.fraction >= (progress?.fraction ?? 0) { progress = now } }
        Task {
            let outcome: Result<Void, Error> = await Task.detached {
                Result {
                    let files = FileManager.default
                    try files.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? files.removeItem(at: partial)
                    // The engine that clones is let go; the store opens its own.
                    _ = try PrismEngine.cloneRepository(url: repository.cloneUrl, root: partial.path, options: options, token: token, watcher: watcher)
                    try? files.removeItem(at: folder)
                    try files.moveItem(at: partial, to: folder)
                }
            }.value
            cloning = nil
            progress = nil
            switch outcome {
            case .success: finish()
            case .failure(let error):
                problem = "\(error)"
                try? FileManager.default.removeItem(at: partial)
            }
        }
    }
}
#endif
