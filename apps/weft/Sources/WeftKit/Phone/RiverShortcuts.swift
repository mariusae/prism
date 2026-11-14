#if os(iOS)
import SwiftUI
import UIKit

/// The rivers last looked at, three, offered when the app's icon is held
/// on the Home Screen: each a quick action that opens it. Only named
/// rivers — saved, and so found again by name.
@MainActor
public enum RiverShortcuts {
    /// What a river's quick action is known as.
    public static let type = "org.mutable.weft.river"
    private static let key = "RiverShortcuts.recent"
    private static let kept = 3

    private static var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// A river looked at: first among them now.
    static func looked(at river: River, in store: GraphStore) {
        guard let name = river.name, recent.first != name else { return }
        recent = Array(([name] + recent.filter { $0 != name }).prefix(kept))
        offer(store)
    }

    /// The quick actions set again: for rivers renamed or gone meanwhile.
    static func offer(_ store: GraphStore) {
        let saved = Dictionary(store.savedRivers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let names = recent.filter { saved[$0] != nil }
        if names != recent { recent = names }
        UIApplication.shared.shortcutItems = names.map { name in
            let icon = saved[name]?.icon.flatMap { UIImage(systemName: $0) != nil ? $0 : nil } ?? "water.waves"
            return UIApplicationShortcutItem(type: type, localizedTitle: name, localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: icon), userInfo: ["river": name as NSString])
        }
    }

    /// The river a quick action names, if it is one of these.
    public static func river(of item: UIApplicationShortcutItem) -> String? {
        item.type == type ? item.userInfo?["river"] as? String : nil
    }
}

extension PhoneSession {
    /// Shows a saved river, by its name: from a quick action, or a link.
    /// Opens the graph first, when the app is only now launched.
    public func openRiver(named name: String) {
        open()
        guard !name.isEmpty, let store else { return }
        store.openSaved(name)
    }
}
#endif
