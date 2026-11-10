# Prism for Apple's platforms

A Swift package around the Rust engine, for macOS, iOS and the iOS
Simulator (arm64). Built by `apple/build.sh`; nothing generated is
checked in.

| Product | What it is |
|---|---|
| `Prism` | The engine: `PrismEngine` (a graph, synced and indexed), `NoteEditor` (a note open for writing), `GitHubAccount`, and the rest of the UniFFI bindings. |
| `PrismEditor` | The editor: one component for every app on the engine. |

```sh
apple/build.sh          # the XCFramework and the Swift bindings
apple/build.sh check    # and the Swift checks, on this Mac and in a booted simulator
```

## The editor

`NoteEditorView` shows a note the engine holds open. It is the same
component in every app, and it is deliberately thin:

- **The note is the engine's.** A `NoteEditor` holds the note as what it
  is — its frontmatter, its title, its body as a tree of blocks. The text
  view is only how the body is shown while it is written. It keeps no
  note of its own, and knows no Markdown.
- **Outline and text are two ways of showing one note.** As an outline, a
  row is a block and holds only its words; what the row is — a bullet, a
  task, a heading — is drawn in the margin beside it. As text, the view
  holds the body's Markdown, its markup hidden except on the lines being
  written in. `editor.setMode` goes from one to the other and changes no
  byte of the note.
- **Every change goes through the note.** What is typed is handed to
  `editor.replace`; a key that means something — Return, Tab, ⌘↩ — to
  `editor.perform`; and the view does what the editor answers. So an
  editor on the Mac and one on a phone cannot behave differently, and
  Undo (`editor.undo`) puts back structure as well as words.
- **It knows nothing of its app.** An app gives it an `EditorTheme` (its
  colours, the size and face of its text), says which pages exist, and is
  told when the note changed, when a link was followed, and when the
  caret came or went. The file to save is `editor.markdown()`.

```swift
import Prism
import PrismEditor

let editor = NoteEditor.open(source: file, mode: .outline)

NoteEditorView(
    editor: editor, theme: .system(size: 14), isWriting: true, height: $height,
    pageExists: { name in (try? engine.resolve(name: name))??.exists ?? false },
    onChange: { save(editor.markdown()) },
    onFollow: { link in open(link) }
)
.frame(height: height)
```

The view is AppKit's on the Mac. The iPhone and iPad's is not written yet.
