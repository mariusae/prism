#if os(macOS)
import Prism
import SwiftUI

/// What the app is doing about syncing, and has done: where the graph
/// is and where it syncs to, who as, how the last sync went, whether the
/// relay is heard from — and a log of each thing as it happened. For when
/// something written elsewhere has not turned up, and one wants to know why.
public struct DiagnosticsView: View {
    let store: GraphStore?
    private let account = Account.shared
    @State private var onlyProblems = false

    public init(store: GraphStore?) { self.store = store }

    private static let clock: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "HH:mm:ss"
        return format
    }()

    public var body: some View {
        Group {
            if let store { panel(store) } else { Text("No graph is open.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private func panel(_ store: GraphStore) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                row("Graph") {
                    Text(store.root.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([store.root]) }.controlSize(.small)
                }
                row("Remote") { Text(store.remote ?? "None: this graph syncs nowhere").textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                row("Account") { Text(accountSaid).foregroundStyle(account.isSignedIn ? Color.primary : Color.orange) }
                row("Sync") {
                    Circle().fill(syncColor(store)).frame(width: 8, height: 8)
                    Text(syncSaid(store)).lineLimit(2)
                    Button("Sync Now") { store.syncNow() }.controlSize(.small).disabled(store.isSyncing)
                }
                row("Last sync") { Text(store.lastSync.map { "\($0.formatted(date: .omitted, time: .standard)) — \(store.syncNote ?? "")" } ?? (store.syncNote ?? "None since the graph was opened")).lineLimit(2) }
                row("Relay") {
                    Circle().fill(relayColor(store)).frame(width: 8, height: 8)
                    Text(relaySaid(store)).lineLimit(2)
                    Button("Reconnect") { store.reconnectRelay() }.controlSize(.small).disabled(store.relayHost == nil || !account.isSignedIn)
                }
                row("Last push heard") {
                    Text(store.lastPush.map { $0.formatted(date: .omitted, time: .standard) } ?? "None. The relay only hears of pushes once the GitHub App's webhook points at it.")
                        .foregroundStyle(store.lastPush == nil ? .secondary : .primary)
                        .lineLimit(2)
                }
            }
            .font(.callout)
            .padding(16)
            Divider()
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Toggle("Problems only", isOn: $onlyProblems).toggleStyle(.checkbox).controlSize(.small)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary(store) + "\n\n" + lines(store).map(written).joined(separator: "\n"), forType: .string)
                }
                .controlSize(.small)
                .help("Copy what is shown here, to send to whoever is looking into it")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(lines(store)) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Self.clock.string(from: line.at)).foregroundStyle(.tertiary)
                                Text(line.kind).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                Text(line.text).foregroundStyle(isProblem(line) ? Color.red : Color.primary).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 11.5, design: .monospaced))
                            .id(line.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .onChange(of: store.log.count) { _, _ in if let last = lines(store).last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onAppear { if let last = lines(store).last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
    }

    private func row<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            HStack(spacing: 8) { content() }
        }
    }

    private func isProblem(_ line: GraphStore.LogLine) -> Bool {
        line.text.contains("FAILED") || line.text.contains("disconnected") || line.text.contains("Could not") || line.text.contains("deleted elsewhere")
    }

    private func lines(_ store: GraphStore) -> [GraphStore.LogLine] {
        onlyProblems ? store.log.filter(isProblem) : store.log
    }

    private func written(_ line: GraphStore.LogLine) -> String {
        "\(Self.clock.string(from: line.at))  \(line.kind.padding(toLength: 7, withPad: " ", startingAt: 0)) \(line.text)"
    }

    private var accountSaid: String {
        if !account.isAvailable { return "This build names no GitHub App: it cannot sign in" }
        if !account.isSignedIn { return "Not signed in to GitHub" }
        return "Signed in to GitHub\(account.login.map { " as \($0)" } ?? "")"
    }

    private func syncSaid(_ store: GraphStore) -> String {
        switch store.sync {
        case .idle: return "Idle"
        case .syncing: return "Syncing…"
        case .synced(let at): return "In sync as of \(Date(timeIntervalSince1970: at).formatted(date: .omitted, time: .standard))"
        case .failed(let message, let willRetry, let needsSignIn): return "Failed: \(message)\(needsSignIn ? " — sign in again" : "")\(willRetry ? " — will retry" : "")"
        }
    }

    private func syncColor(_ store: GraphStore) -> Color {
        switch store.sync {
        case .idle: return .secondary
        case .syncing: return .blue
        case .synced: return .green
        case .failed: return .red
        }
    }

    private func relaySaid(_ store: GraphStore) -> String {
        let host = store.relayHost ?? "none in this build"
        switch store.relay {
        case .off: return "Not listening (\(host))"
        case .connecting: return "Connecting to \(host)…"
        case .listening: return "Listening to \(host)"
        case .waiting(let reason): return "Not connected to \(host): \(reason). Trying again."
        }
    }

    private func relayColor(_ store: GraphStore) -> Color {
        switch store.relay {
        case .off: return .secondary
        case .connecting: return .blue
        case .listening: return .green
        case .waiting: return .orange
        }
    }

    /// What the panel's head says, as text: what Copy puts before the log.
    private func summary(_ store: GraphStore) -> String {
        [
            "Graph: \(store.root.path)",
            "Remote: \(store.remote ?? "none")",
            "Account: \(accountSaid)",
            "Sync: \(syncSaid(store))",
            "Last sync: \(store.lastSync.map { $0.formatted(date: .omitted, time: .standard) } ?? "none") \(store.syncNote ?? "")",
            "Relay: \(relaySaid(store))",
            "Last push heard: \(store.lastPush.map { $0.formatted(date: .omitted, time: .standard) } ?? "none")",
        ].joined(separator: "\n")
    }
}

/// The menu's way to the diagnostics window.
struct OpenDiagnostics: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Sync Diagnostics…") { openWindow(id: "diagnostics") }.keyboardShortcut("d", modifiers: [.command, .option])
    }
}
#endif
