// swift-tools-version: 6.0
// The Prism engine for Apple's platforms: the Rust core as a binary
// target, and the Swift API UniFFI generates over it. Both are built by
// apple/build.sh, which must be run first.
import PackageDescription

let package = Package(
    name: "Prism",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "Prism", targets: ["Prism"]),
        .library(name: "PrismEditor", targets: ["PrismEditor"]),
        .library(name: "PrismEmblem", targets: ["PrismEmblem"]),
        .library(name: "PrismDictation", targets: ["PrismDictation"]),
    ],
    targets: [
        .binaryTarget(name: "PrismFFI", path: "PrismFFI.xcframework"),
        .target(
            name: "Prism",
            dependencies: ["PrismFFI"],
            // What the Rust library asks of the system: libgit2's zlib,
            // iconv and Secure Transport; the file watcher's FSEvents.
            linkerSettings: [
                .linkedLibrary("z"), .linkedLibrary("iconv"),
                .linkedFramework("Security"), .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreServices", .when(platforms: [.macOS])),
            ]
        ),
        // The editor: one component for every app on the engine. It shows a
        // note the engine holds open (`NoteEditor`), as an outline or as
        // text, and knows nothing of the app around it.
        .target(name: "PrismEditor", dependencies: ["Prism", "PrismDictation"]),
        // Words spoken, written down: by ElevenLabs' realtime transcription
        // while there is a token for it, else by Apple's own recognition.
        // The microphone, the socket, and how what is heard is typed out —
        // nothing of where it goes, which is the editor's.
        .target(name: "PrismDictation"),
        // What stands for a page or a river wherever it is shown small: its
        // icon, or a letter of its name, in its colour. A decision about
        // looks, so not the engine's — but one every app should make the
        // same way, so it is made here, once.
        .target(name: "PrismEmblem"),
        .testTarget(name: "PrismEmblemTests", dependencies: ["PrismEmblem"]),
        // The engine driven end to end from Swift: `swift run PrismChecks`.
        .executableTarget(name: "PrismChecks", dependencies: ["Prism"]),
    ],
    swiftLanguageModes: [.v5]
)
