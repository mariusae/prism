# prism-ffi

Prism's engine for Swift: [UniFFI](https://mozilla.github.io/uniffi-rs/)
bindings over the [`prism`](../prism) crate.

The apps are Swift; the engine is Rust. This crate is the seam between
them. It adds no behaviour — each function is a thin wrapper — only a
boundary shaped to cross well.

| In Swift | What it is |
|---|---|
| `PrismEngine` | A graph kept synced and indexed: files, sync, the indices' questions, queries, renaming, rivers. |
| `EngineObserver` | A protocol the app implements, told what the engine does. |
| `TokenProvider` | A protocol the app implements, asked for a GitHub token. |
| `NoteDocument` | One note being edited: rows, the outline's commands, frontmatter. |
| `inlineSpans(text:)`, `toggleInlineStyle(…)` | The spans in a row's text, and styling it. |
| `conflictSegments(source:)`, `resolveConflicts(…)`, `mergeNoteTexts(…)` | Conflicts, and merging. |

Three rules:

- **Text positions are UTF-16 offsets**, as `NSString`, `NSRange` and
  TextKit count them.
- **Rows are named by path** — `[UInt32]`, an index at each level — and a
  command answers with the path the row has afterwards.
- **Nothing blocks on the network** except what says it waits
  (`syncNow`, `settle`, `cloneRepository`): call those off the main
  thread. Everything else returns at once and reports through the
  observer, which is called on a thread of the engine's.

## Building

```sh
crates/prism-ffi/build-swift.sh
```

builds the library, generates the bindings into `swift/Generated/`
(`prism_ffi.swift`, `prism_ffiFFI.h`, `prism_ffiFFI.modulemap`), then
compiles and runs [`swift/Tests/main.swift`](swift/Tests/main.swift) —
a Swift program that creates a graph, edits a note, queries the indices,
renames a page, saves a river and syncs to a remote, all through the
bindings. The generated files are not checked in.

## In an app

Add `prism_ffi.swift` to the target, point the target at the header's
module map (`-fmodule-map-file=…/prism_ffiFFI.modulemap`, or wrap the
header and `libprism_ffi.a` in an XCFramework), and link the library.

```swift
final class Sync: EngineObserver {
    func onEvent(event: EngineEvent) {
        DispatchQueue.main.async { /* redraw what the event says changed */ }
    }
}

let engine = try PrismEngine.open(root: graphPath, options: EngineOptions(device: "Ada's Mac"), token: signIn)
engine.setObserver(observer: sync)
engine.sync()
try engine.watch()

let document = NoteDocument.parse(source: try engine.read(path: path) ?? "")
_ = document.indent(path: [2])
_ = try engine.saveMerging(path: path, draft: document.markdown(), base: lastSeen)
```

For iOS, build the static library for each target
(`aarch64-apple-ios`, `aarch64-apple-ios-sim`) and combine them with
`xcodebuild -create-xcframework`. That has not been done here yet.
