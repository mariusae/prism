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
        .executable(name: "WeftMac", targets: ["WeftMac"]),
    ],
    dependencies: [.package(path: "../../apple")],
    targets: [
        // The views and what they hold, for the Mac, the iPad and the iPhone.
        .target(name: "WeftKit", dependencies: [.product(name: "Prism", package: "apple"), .product(name: "PrismEditor", package: "apple"), .product(name: "PrismEmblem", package: "apple")]),
        // The Mac app around them. Wrapped as Weft.app by scripts/build-app.sh.
        .executableTarget(name: "WeftMac", dependencies: ["WeftKit"]),
    ],
    swiftLanguageModes: [.v5]
)
