import SwiftUI
import WeftKit

/// Weft on the iPhone and the iPad. Everything it shows and does is
/// WeftKit's, over the Prism engine; this is only the app around it.
@main
struct WeftApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { PhoneRoot() }
    }
}
