// swift-tools-version: 6.0
// Weft: a river of cards over a graph of notes. The app is a view on the
// Prism engine (../../apple, built by ../../apple/build.sh): everything
// that reads, indexes, searches or syncs the graph is the engine's.
import PackageDescription

let package = Package(
    name: "Weft",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "WeftKit", targets: ["WeftKit"]),
        // What the share extension and the app pass between them; nothing more, so the extension stays small.
        .library(name: "WeftShared", targets: ["WeftShared"]),
        .executable(name: "WeftMac", targets: ["WeftMac"]),
    ],
    dependencies: [.package(path: "../../apple")],
    targets: [
        // The views and what they hold, for the Mac, the iPad and the iPhone.
        .target(name: "WeftShared"),
        .target(name: "WeftKit", dependencies: ["WeftShared", .product(name: "Prism", package: "apple"), .product(name: "PrismEditor", package: "apple"), .product(name: "PrismEmblem", package: "apple"), .product(name: "PrismDictation", package: "apple")]),
        // The Mac app around them. Wrapped as Weft.app by scripts/build-app.sh.
        .executableTarget(name: "WeftMac", dependencies: ["WeftKit"]),
        // What can be checked without a screen: `swift test`.
        .testTarget(name: "WeftKitTests", dependencies: ["WeftKit", "WeftShared", .product(name: "Prism", package: "apple"), .product(name: "PrismEditor", package: "apple")]),
    ],
    swiftLanguageModes: [.v5]
)
