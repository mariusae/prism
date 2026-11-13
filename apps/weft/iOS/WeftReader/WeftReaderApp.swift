import SwiftUI
import WeftKit

/// Weft Reader: the inbox's links, read one at a time, the oldest first.
/// Everything it shows and does is WeftKit's, over the Prism engine; this
/// is only the app around it.
@main
struct WeftReaderApp: App {
    var body: some Scene {
        WindowGroup { ReaderRoot() }
    }
}
