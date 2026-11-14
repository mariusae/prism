import UIKit
import WeftKit

/// What UIKit tells the app that SwiftUI does not: its push token, and
/// the silent pushes the sync relay sends when another device pushed —
/// met with a sync, even with the app in the background.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Silent pushes need no permission asked of the person.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PhoneSession.shared.received(pushToken: deviceToken) }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void) {
        MainActor.assumeIsolated { PhoneSession.shared.pushed { pulled in completion(pulled ? .newData : .noData) } }
    }

    /// The window's scene, told of the quick actions the Home Screen offers.
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Launched by one: its river, shown as the app opens.
        if let item = options.shortcutItem, let river = RiverShortcuts.river(of: item) {
            MainActor.assumeIsolated { PhoneSession.shared.openRiver(named: river) }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// A quick action chosen while the app was running: its river, shown.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ scene: UIWindowScene, performActionFor item: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        guard let river = RiverShortcuts.river(of: item) else { return completionHandler(false) }
        MainActor.assumeIsolated { PhoneSession.shared.openRiver(named: river) }
        completionHandler(true)
    }
}
