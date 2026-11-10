WEFT REWRITE SPEC: the phone/iPad shell and the card editor, taken from the source as it is now

Path abbreviations used in the citations below. All of these are absolute.
- WUI = /Users/marius/src/weft/Sources/WeftUI
- ED = /Users/marius/src/weft/Sources/WeftUI/Editor
- IOS = /Users/marius/src/weft/iOS/Weft
- GH = /Users/marius/src/weft/Sources/WeftGitHub
- PUI = /Users/marius/src/reflect-mac/Sources/PhoneUI (the phone outline editor and its keyboard bar)
- RUI = /Users/marius/src/reflect-mac/Sources/ReflectUI (the Mac outline editor)
- RC = /Users/marius/src/reflect-mac/Sources/ReflectCore
- PC = /Users/marius/src/reflect-mac/Sources/PrismCore

Read these points first. Several things the brief assumes are not in the code:
- **No glass controls at the top on iPhone.** At compact width the navigation bar is hidden (WUI/ContentView.swift:149-151). All the controls are in one glass bar at the foot, `PhoneBar`.
- **No Handoff.** The only `onContinueUserActivity` is for Spotlight results (WUI/Rivers.swift:593).
- **`showSidebar` is never called.** On iPhone it is passed down and used only to tell phone from iPad. No button calls it (grep finds no call sites).
- **The text-mode styler handles less than the brief lists.** It does not style `==highlight==` (⌘⇧H, the bar button and `wrap("==")` still insert the markers), tables, or horizontal rules. The phone outline editor does style highlight, rules and code blocks.
- **There is no `#` tag completion in either editor.** Tags are added in the card's "Add tag" field, which suggests tags already in use.
- **`FormattingButtons` is dead code.** It is defined in ED/TiddlerEditor.swift:1280 and never used.
- **The iOS text view has no hardware-keyboard shortcuts.** Only the phone outline editor defines `keyCommands`.

======================================================================
A. THE PHONE AND IPAD SHELL
======================================================================

A1. iPhone navigation structure

**Root**
- WUI/ContentView.swift:71: a `NavigationSplitView(preferredCompactColumn: $compactColumn)` with `Sidebar()` and `KeptRivers(...)`.
- On iPhone the sidebar and the river take turns. `compactColumn` starts as `.detail`, so the river shows first.
- The sidebar has a trailing toolbar button: the river's title then the `chevron.forward` symbol (semibold), labelled "Back to <river>". It sets `compactColumn = .detail` (ContentView.swift:77-89).
- Any card focus request also flips back to the river: `OnFocusRequest { compactColumn = .detail }` (line 247).
- Sidebar column width is min 220, ideal 270, max 400 (line 73).
- The phone sidebar has a search field and a horizontally scrolled row of capsule tabs: Open, Recent, Inbox, Reading, Tasks, Pinned, Wiki, Tags, Missing (ContentView.swift:666-727).
- The detail column has no title, an inline title display mode, and its navigation bar hidden at compact width (lines 149-151).

**The river itself on phone: `PhoneRivers`** (ContentView.swift:1090-1181)
- It is a ZStack of the current river plus its neighbours while swiping. They sit at `offset(x: place*(width+14) + rivers.swipe)`; the gutter is 14.
- Behind the rivers is `Color.river` with an 8% black overlay.
- Swiping past the last river shows a "New River" page: symbol `plus.square.on.square` at 34pt, then "New River" in headline style.
- The overview of all rivers ("rivers shown as Safari's tabs") opens with the river shrinking into its tile:
  - The `IntoTile` modifier scales to the tile, clips the top to the tile height, and rounds the corners to radius 18/fit.
  - Shadow is black at 0.18 opacity, radius 24·p, y 8·p.
  - Spring is response 0.42, dampingFraction 0.86. There is a 30 ms delay before it starts. The overview fades and blurs in (blur (1-p)*10).

**River column** (`RiverColumn`, ContentView.swift:1232-1472)
- A `LazyVStack` of cards. Gap between open cards is 22; between folded cards it is 11.
- Padding is horizontal 10 (compact) or 28 (regular), vertical 12 or 22. Max width is 820.
- Card insert/remove uses an opacity transition; removal is easeOut 0.12. The list animates with `.snappy(0.28)`.
- Pinch: magnification below 0.8 runs foldAll; above 1.25 runs unfoldAll (`.snappy(0.3)`) (lines 1342-1348).
- When a card gets focus it is scrolled to the top: `.snappy(0.24)` immediately, then again after 0.26 s with `.snappy(0.14)` (lines 1452-1469).
- Empty river on phone: `ContentUnavailableView` "Nothing Open" (symbol `rectangle.stack`), with the text "Tap the river's name below to find a page, or + to start one." (lines 1399-1404).

**Hiding on scroll ("tucked")**
- `ScrollFollower.follow(y)` (ContentView.swift:1477-1497):
  - If y < 40, the bar is not tucked and the travel count resets.
  - It only reacts while the user is scrolling by hand (scroll phase `.interacting` or `.decelerating`).
  - Travel accumulates while the direction stays the same. Above +24 (scrolled down) it tucks; below −12 it untucks.
- When tucked, the bar collapses to just the river name.

**Bottom inset** (`safeAreaInset(.bottom)`, lines 1423-1441)
- A VStack with spacing 8: `SyncNoticeView`, `UndoOfferView`, then — only if no card is being written in and the keyboard is down — `PhoneBar` on iPhone or `RiverSwitcher` on iPad. Bottom padding is 4.
- The keyboard state comes from `keyboardWillShow` and `keyboardWillHide` notifications.

**PhoneBar, the glass bar at the foot** (WUI/PhoneShell.swift:20-340)
- It sits inside `GlassEffectContainer(spacing: 8)` with a fixed height of 48. Horizontal padding is 14 and spacing is 8. Foreground is `Ink.accent`.
- Morph animation between states is `spring(duration: 0.38, bounce: 0.12)`.
- Buttons, left to right:
  1. **Find.** `magnifyingglass`, 18pt semibold, 48×48 glass circle. Sets `rivers.startTyping = true` and `river.quickOpenShown = true`, which opens the start page in "add" mode with the keyboard up (lines 126-137).
  2. **A single glass capsule** holding three things (lines 76-84):
     - The **More** menu: `ellipsis`, 18pt semibold, frame 46×48. When there are conflicts, an orange 7pt dot sits at the top trailing corner, offset (−8, 10). Contents are listed under "More menu" below.
     - The **river name**: the river's symbol (footnote semibold, in the river's colour or `Ink.secondary`), then the title in callout semibold. Max width fills the space, min height 48. Tapping opens the start page in browse mode (`startTyping = false`) (lines 187-206).
     - A clear 46×48 spacer, so the name sits centred.
  3. **New.** `plus`, 20pt medium, 48×48 glass circle (lines 142-184). It uses a UIKit `UILongPressGestureRecognizer` with minimumPressDuration 0 (`Press`, lines 1076-1106):
     - Tap (no hold, moved less than 20 in x and y): `river.newTiddler()`.
     - Hold for 0.2 s: dictation starts. The symbol changes to `mic.fill` in red, with a medium impact haptic.
     - Release: the dictated tiddler is kept.
     - Release after sliding up more than 80 (moved.height < −80): cancelled, with a warning haptic.
     - Success gives a success haptic.
     - If permission is missing, a `HeardBubble` shows for 3 s: "Weft can't listen: allow the microphone and speech recognition in Settings." It is a glass rounded rectangle, radius 22, positioned 48+12 above the bar.
- **Swipe gesture** on Find and on the name capsule (lines 265-298). It is a `DragGesture` with minimumDistance 12 in global coordinates.
  - The river follows the finger. Before the first river the drag is damped to /3.
  - On release, it slides to the next river if the drag exceeded width×0.4, or if the predicted end exceeded width×0.5 in the same direction.
  - Slide animation is `interpolatingSpring(stiffness: 260, damping: 30)` over a page of width+42. Snap-back uses damping 28.
  - Past the last river (if the current river is not empty), a new river is created (`add(browsing: true)`).
  - An upward drag of more than 24 that is more vertical than horizontal opens the all-rivers overview.
- **Tucked state** (lines 43-67): a single glass capsule with the river title (footnote medium), height 30, horizontal padding 16, max width 60% of the bar, drawn 14pt lower (`offset(y: 14)`).
  - Tap: untuck.
  - Drag down more than 18 (more vertical than horizontal): `foldAll` with `.snappy(0.3)`.
- **Haptic:** `.sensoryFeedback(.selection, trigger: rivers.currentIndex)` (line 110).

**More menu** (PhoneShell.swift:209-261), in this order:
1. "N to Review" (`exclamationmark.triangle`). Only when there are conflicts.
2. A "Back To" submenu (`chevron.backward`) listing up to 12 back places, each with its page symbol.
3. "All Rivers" (`square.on.square`). Only when there is more than one river.
4. A section:
   - "Today" (`calendar`)
   - "New To-Do" (`circle`)
   - "New Tiddler from Pasteboard" (`doc.on.clipboard`), disabled when the pasteboard is empty
   - "Unfold All" (`rectangle.expand.vertical`) or "Fold All" (`rectangle.compress.vertical`)
   - "Close All Cards" (`rectangle.stack.badge.minus`)
5. A "River" submenu (`square.stack`) containing `RiverSetMenu` (WUI/Rivers.swift:232-268):
   - A list of open rivers, with a checkmark on the current one.
   - A section: "New River" (`plus`); "Save River…" or "Rename River…" (`square.and.arrow.down`).
   - If the river is saved: "Choose River Icon…" (its icon or `square.grid.3x3`), "Copy Link to River" (`link`, copies `[[rivers/Name]]`), "Copy River Address" (`safari`, copies `weft://river/Name`).
   - "Saved Rivers…" (`tray.full`).
   - A section: "New Query River…" (`line.3.horizontal.decrease.circle`); "Edit River Query…" or "Fill from Query…" (`slider.horizontal.3`).
   - "Close River" (destructive). Only when there is more than one river.
6. A section: "Sync Now" (`arrow.triangle.2.circlepath`) plus a status text line, then "Recently Deleted…" (`trash`), then "Settings…" (`gearshape`, opens a sheet containing `SettingsForm`).
   - The status line reads "Not synced yet", "Syncing…", "Synced <relative time>", or "Last sync failed: <msg>" (PhoneShell.swift:332-339).

**Start page** (iPhone `fullScreenCover`; PhoneShell.swift:348-693; ContentView.swift:200-205)
- At the top: a glass capsule of six icon tabs. Each is 17pt, the selected one semibold on accent at 0.14 opacity, min height 40.
  - Order: Rivers `square.stack.3d.up`, Recent `clock`, Inbox and Pinned `tray`, Reading `eyeglasses`, Tasks `checklist`, Wiki `book.closed`.
- At the foot: a glass capsule field, height 48. The placeholder is "Find a page, or name a new one", or "Add a tiddler to <river>" in add mode. Next to it is an `xmark` close button, a 48pt glass circle.
- In add mode the keyboard comes up after 150 ms.
- Results while typing:
  - Name matches come first. A "New Tiddler "x"" row is added if nothing has exactly that name.
  - Then an "In Text" section, showing a 2-line snippet with leading padding 32.
  - Then "By Meaning".
  - Then "Search All Text for "x"" (footer: "Every page saying it, best first, as a river.").
- The Rivers tab is a 4-column grid of saved-river tiles:
  - Each tile is 64×64, radius 16, with the icon at 26pt on its colour at 0.14 opacity. A 9pt accent dot marks rivers that are open.
  - Tiles can be dragged to reorder.
  - Context menu: Open, Open in New River, Copy Link.
  - There is also a "Query River" new-tile.

**Overview of all rivers** (`RiverOverview`, PhoneShell.swift:796-934)
- A 2-column grid with spacing 14. Each tile is 190 tall, radius 18, and lists the first 5 cards plus "and N more".
- The current tile has a 2.5 accent border; the others a 1pt rule border.
- Each tile has an × close button: 22pt circle inside a 40pt hit area.
- Tiles can be dragged to reorder.
- At the foot: a `plus` glass circle, an "N Rivers" capsule, and a `checkmark` done button tinted accent.

**Pull to refresh:** `.refreshable { await store.syncPulled() }` (ContentView.swift:1351). It waits for the sync to finish, then `SyncNoticeView` shows the result:
- "Syncing…"
- "Up to date", "Sent your changes", "Brought in N changes", or "Brought in N changes, sent yours". This clears after 2.5 s.
- "Couldn't sync" with a Details link to an alert, which has Try Again and OK (WikiStore.swift:353-395; ContentView.swift:520-569).

**Haptics, complete list**
- River index change: `.selection` (PhoneShell.swift:110; Rivers.swift:334).
- Any fold change in the river (`foldsVersion`): `.impact(weight: .light)` (ContentView.swift:1349).
- `river.cards` reordered (same set): `.impact(.medium)`. A card closed (the count dropped): `.impact(.light)` (1353-1356).
- Card swipe crossing the commit threshold: `.impact(weight: .medium)` (CardSwipe.swift:66).
- Dictation: medium impact at start; success when it finishes; warning when cancelled (PhoneShell.swift:962, 1017, 1023).
- Phone outline editor:
  - `UISelectionFeedbackGenerator` on formatting toggles, fold toggles, checkbox and marker taps, and row-choice taps (PUI/OutlineEditor.swift:2381, 2459, 2582, 2594, 2599).
  - Light impact on row swipe indent/outdent and on reorder menu actions (3319, 2862).
  - Medium impact when a row is lifted for dragging (RowDrag.swift).
  - Selection haptic when the drop target changes.

A2. iPad differences
- **Size class.** `sideFits` is true when the horizontal size class is `.regular` (ContentView.swift:21-27). The split view shows the sidebar beside the river.
- **Side panel.** `.inspector(...)` shows `SidePanel` for related pages or reading. Column width is min 280, ideal 340, max 480; for reading it is 360/520/900 (98-106). Without room, reading opens as a `.large` sheet instead (110-124).
- **Toolbar.** The navigation bar is visible (`.automatic`), with the `RiverToolbar` primary-action group (ContentView.swift:277-359), in order:
  1. "N to Review" (orange). Only when there are conflicts.
  2. The `SyncButton`: `arrow.triangle.2.circlepath`, rotating while syncing, or `exclamationmark.arrow.trianglehead.2.clockwise.rotate.90` (orange) after a failure.
  3. "Quick Open" (`magnifyingglass`).
  4. "Today" (`calendar`).
  5. "New Tiddler" (`plus`). This is a Menu with a primary action of newTiddler; held, it offers "New To-Do" and "New Tiddler from Pasteboard".
  6. "Close All" (`rectangle.stack.badge.minus`).
  7. "Side" (`sidebar.trailing`, filled when shown). This is a Menu with toggles for Related and Reading; the primary action is `toggleSide()`.
- **Quick Open** is a sheet with detent `[.large]`, a visible drag indicator, and a paper background (ContentView.swift:206-213). The iPhone uses the full-screen start page instead.
- **The foot** has `RiverSwitcher` (Rivers.swift:273-337) instead of PhoneBar. It is a glass capsule with:
  - A `chevron.left` button (30×30), disabled on the first river.
  - A Menu (`RiverSetMenu`) whose label is the title in callout medium plus `chevron.up.chevron.down`, with page dots underneath (5pt, spacing 5). Min width 120, max 220.
  - A `chevron.right` button.
  - A horizontal drag of more than max(36, |dy|) steps between rivers.
  - When tucked ("small") it shows the title only, in footnote.
- **Per-window rivers.** `WindowRivers` (IOS/WeftApp.swift:77-100) uses `@SceneStorage("riverScene")`. The first window has an empty scene name. A second window that opens while that name is in use gets a fresh UUID.
  - `RiverSet.key` is `"Rivers:<root>"` plus `":<scene>"`, stored in UserDefaults as JSON `{rivers:[River.State], current:Int}` (Rivers.swift:71-94).
  - It is saved with a 0.3 s debounce, and also on `didEnterBackground` (Rivers.swift:204-225, 59-66).
- **Hardware keyboard shortcuts.** These are `PadCommands` in IOS/WeftApp.swift:104-157 and act on the focused window's river:

  | Shortcut | Action |
  |---|---|
  | ⌘N | New Tiddler |
  | ⌘O | Quick Open |
  | ⌘F | Find (in the card being written, else the sidebar search) |
  | ⌥⌘F | Find Tiddler (focuses the sidebar search) |
  | ⌘R | Sync Now |
  | ⇧⌘T | Today |
  | ⌘↩ | Switch Between Outline and Text |
  | ⇧⌘W | Close All Cards |
  | ⌃⌘↑ / ⌃⌘↓ | Fold / Unfold the selected card |
  | ⌃⌥⌘↑ / ⌃⌥⌘↓ | Fold All / Unfold All |
  | ⌘[ / ⌘] | Back / Forward |
  | ⌥⌘[ / ⌥⌘] | Previous / Next Day |
  | ⌥⌘↑ / ⌥⌘↓ | Previous / Next Card |

  Inside the outline editor its own `keyCommands` take priority (`wantsPriorityOverSystemBehavior`); see B3.
- **Card padding** is horizontal 28 at regular width (16 at compact). Top is 22 at regular width (16 compact); bottom is 24 (16 compact); folded cards use 12 (Card.swift:110-114).

A3. Card gestures on phone (WUI/Card.swift, WUI/CardSwipe.swift, WUI/CardDrag.swift)
- **Title row** (Card.swift:844-851): `TapGesture(count: 2)` (rename) takes priority over a single tap (`toggleFold`, `.snappy(0.22)`).
- **Folded card ("peek")** (191-193): a single tap toggles the fold; a double tap unfolds and edits (`writeAtOnce`).
  - The peek shows 3 lines with space reserved: bold title, then two spaces and a summary in secondary colour.
  - It starts with a ring (`circle` / `checkmark.circle.fill`) and the page icon. The ring has its own tap target, `TextSettings.size*1.4` × `*1.3`, that toggles done.
  - Up to 2 thumbnail pictures sit at the end, with side `round(size*1.3*3)` and radius 6.
- **Any tap on a card** selects it (`simultaneousGesture`, Card.swift:140-145).
- **Long-press menu** (`.contextMenu`, on the title row when not renaming and on the peek row; `longPressMenu`, Card.swift:294-324). In order:
  1. "Add Title…" if untitled, else "Rename…" (`character.cursor.ibeam`). Only if renamable (not a day, not a shadow tiddler).
  2. "Open in New River" (`plus.square.on.square`).
  3. "Pin" or "Unpin" (`pin` / `pin.slash`), then "Add to Inbox" or "Done with It" (`tray.and.arrow.down` / `tray.and.arrow.up`). Only for an existing non-day page.
  4. "Choose Icon…" (the current icon or `square.grid.3x3`).
  5. "Copy Link" (`link`; copies `[[title]]`).
  6. "Copy Contents" (`doc.on.doc`; copies the draft or saved text).
  7. A `ShareLink` "Share" (`square.and.arrow.up`).
  8. A "More" submenu (`ellipsis.circle`) containing `menuItems` (Card.swift:1095-1199), in four sections plus delete:
     - Rename / Remove Title / Choose Icon / Remove Icon / Add Tag / Add Field / Relate To… / the Home River submenu.
     - Make a To-Do, or Mark Done / Mark Not Done plus No Longer a To-Do; Pin; Inbox; Add to / Remove from Wiki.
     - Fold/Unfold; a "Write As" picker (Text `text.alignleft` / Outline `list.bullet.indent`); Read; Keep at Top / Release to Query (query rivers only); Close; Close Others.
     - Find in It; Insert Query…; Fields of Tiddlers Tagged…; History…; Copy Link; Copy Contents.
     - "Delete Tiddler" (destructive).
- **Drag to reorder** (CardDrag.swift):
  - `.onDrag` sits on the title row (disabled while renaming) and on the peek row. On phone the drag starts after the system long press, the same press that would show the context menu.
  - The payload is the title as UTType `com.mariusae.weft.card` (`.ownProcess` visibility).
  - The drag preview is the title at 17pt semibold, padding 16/10, on a card background with radius 10.
  - Drop target: the top half of a card means "before", the bottom half "after". A 3pt accent capsule line (horizontal padding 10) is drawn in the middle of the gap (offset ±gap/2).
  - The move animates with `.snappy(0.28)`.
- **Swipe actions** (CardSwipe.swift):
  - The pan begins only if |vx| > |vy|×1.4. It is a single touch. It does not run alongside other pans, but does run alongside taps (186-227).
  - Disabled while the card is being written in or renamed (Card.swift:132).
  - Sizes: action button width 84, gap 10, capsule height 46. The open width is 84×2 + 10×3 = 198.
  - Commit threshold: max(198 + 40, width × 0.55). Past it the outer action grows to fill and a medium haptic fires; on release it runs.
  - On release, if not committing:
    - Released past 40, or flung faster than 600 pt/s, the card opens to ±198 and the buttons can be tapped.
    - If the card was already open and is swiped back more than 24 (or velocity above 300), it closes.
    - A tap on an open card closes it.
  - A side with no actions moves at 0.15× (rubber band).
  - Settle animation: spring response 0.32, damping 0.86.
  - Look: a tinted capsule with a white 19pt semibold symbol, and the name underneath in caption medium. A folded card shorter than 80 shows a single capsule of the card's height containing a 13pt symbol and the name.
  - **Swipe right (leading side), outer action first** (Card.swift:331-350):
    - Task open: Done (`checkmark.circle.fill`, green); Inbox or Out of Inbox (blue).
    - Task done: To Do (`circle`, orange); Inbox.
    - Not a task: To Do then Inbox, or, if already in the inbox, Out of Inbox (`tray.and.arrow.up`) then To Do.
    - None for day pages, shadow tiddlers, or pages that do not exist.
  - **Swipe left (trailing side):** Close (`xmark`, gray; called "Remove" in a query river), then Delete (`trash`, red) if the page exists and is not a shadow (353-364).
- **The drawer** (Card.swift:935-979) is a strip of controls under the active card: the one being written in, or the last one tapped.
  - It is a capsule of colour `Ink.drawer` (light 0x6189e0, dark 0x4b6bb5), height 46, horizontal padding 6, top padding 12.
  - Icons are white, 22pt, 26–44 wide, 40 tall.
  - Order:
    1. Open / Peek: `arrow.up.left.and.arrow.down.right.circle` / `arrow.down.right.and.arrow.up.left.circle`.
    2. "Write as Outline/Text": `list.bullet.circle` / `line.3.horizontal.circle`.
    3. Read (`doc.richtext`).
    4. Day Before / After (`chevron.backward.circle` / `chevron.forward.circle`). Days only.
    5. Keep at Top (`pin.circle`) or Release to Query (`arrow.uturn.down.circle`). Query rivers only.
    6. More (`ellipsis.circle`; the menu items above).
    7. Close (`xmark.circle`).
  - It morphs in (scale 0.35×0.7, blur 6) with spring response 0.34, damping 0.82.
  - While the drawer is out, the card is tinted accent at 0.07 opacity.
- **Card look on phone** (Card.swift:118-129):
  - Radius 14. Fill is `Color.card`; folded cards use `Ink.paper`.
  - Border is a 1pt rule. A selected card gets a 1.5pt accent border at 0.85 opacity instead.
  - Shadow: black 0.07, radius 10, y 3. Folded: 0.03 / 4 / 1.
  - Title is 22pt semibold (`Measures.titleSize` on iOS = 22). The ring is 21pt (Measures.swift:75-76).

A4. Quick Open on phone and iPad
- iPhone: the full-screen start page described in A1. QuickOpen is not used there.
- iPad: `QuickOpen` in a sheet with detent `.large` and a drag indicator (ContentView.swift:206-213). The iOS layout is in WUI/QuickOpen.swift:248-321:
  - **Field row:** magnifying glass, then a TextField "Go to a page or a day" in the body face at 17pt, autocapitalisation off, submit label "go", and an xmark.circle.fill clear button. The field sits in a 40-tall capsule on `Ink.rule`, followed by a "Cancel" button in accent. Padding is horizontal 16, top 18, bottom 8. Focus is taken after 100 ms.
  - **Rows:** a plain list with clear row backgrounds. Each row has the kind symbol (17pt, 32×32 frame), then the name (17pt, semibold for the first row) and a detail line (14pt, secondary). Spacing 14, vertical padding 4.
  - **Detail text:** "Open · ", "Today/Yesterday/Tomorrow", "no page yet", the abbreviated relative modified date, "Saved river · N cards", "New page", "As a river".
  - **Results, empty query:** Today, then recent pages (up to 14).
  - **Results, typed:** search hits; saved rivers inserted at index 3; a day match at index 0 (or a natural-language day at index 1); then "New page "x"" if no exact match; then "Search all text for "x"" (WikiStore.swift:2015-2032; QuickOpen.swift:91-100).
  - Submit opens the first result.

A5. Onboarding and GitHub connect
- **Gating:** `WeftApp` shows `Onboarding(allowsFolder: false, ...)` until `store.onboarded` (UserDefaults "Onboarded") is set and there is a root (IOS/WeftApp.swift:40-47).
- **Steps:** welcome → place → github → ready, with dots (7pt, spacing 6). There is a Back button on place and github, and a Continue button (borderedProminent) on welcome. Pages slide in from trailing with opacity. Minimum frame 520×520 (GH/Onboarding.swift).
  1. **Welcome.** Symbol `rectangle.stack`, 54pt light, accent. "Welcome to Weft", with the subtitle "A wiki of small notes, kept in your Reflect graph." Three features:
     - `rectangle.stack` "Cards in a river": "Open a tiddler and its card joins the river; follow a link and the next opens beside it."
     - `link` "Links, tags and queries": "Link with [[ ]], tag freely, and let a query keep a list of what belongs together."
     - `arrow.triangle.2.circlepath` "One graph with Reflect": "Tiddlers sit in your graph's wiki/ folder, link to your notes and days, and sync as they do."
  2. **Place.** "Where is your graph?" / "Weft keeps its tiddlers beside your Reflect notes, in the same repository."
     - Choice card `icloud.and.arrow.down` "Connect to GitHub" with a "Recommended" badge: "Sign in, choose the repository your graph is kept in, and Weft brings it down into a folder of its own, kept in step with GitHub — instantly, through the sync relay."
     - On the Mac only, a second choice: "Use a Folder on This Mac".
  3. **GitHub.** `GitHubConnect` (GH/GitHubConnect.swift). It moves on to Ready after `openClone()`.
  4. **Ready.** `checkmark.circle` (green), "You're Set". Tips:
     - "Make a tiddler" — "⌘N, or the + above the river. A card is written as an outline; ⌘↩ switches it to text and back."
     - "Link as you write" — "Type [[ and choose a title — a tiddler, a note, or a day."
     - "Tag it" — "Tags are tiddlers too: a tag's card lists what it tags, and can give it fields."
     - "Ask a query" — "Insert Query keeps a live list, table or tree in a tiddler."
     - "Today" — "⌘T opens today's Reflect note beside your tiddlers."
     - Button "Start Writing" (calls `finishOnboarding`).
- **GitHubConnect states, in order:**
  - If the build has no GitHub App configured: "GitHub Is Not Set Up".
  - While cloning: a spinner, "Bringing down owner/repo…", and "All of its history comes too; a large graph takes a while."
  - Not signed in: "Sign In to GitHub" (`person.crop.circle.badge.checkmark`), "Weft signs in with the same GitHub App as Prism, and only sees the repositories you give it." Button "Sign In with GitHub".
    - Sign-in is OAuth with PKCE through `ASWebAuthenticationSession`, preferring the shared browser session.
    - Authorize URL: `https://github.com/login/oauth/authorize` with client_id, redirect_uri, state, and an S256 code_challenge.
    - A cancelled sign-in is ignored silently (RC/../ReflectGit2/GitHub.swift).
  - Signed in: a Form.
    - "Already Here" section if a clone exists ("Brought down before, and kept in step with GitHub.").
    - Otherwise "Choose Your Graph", listing repositories (`lock` for private, `book.closed` for public). Footer: "Weft has not been given any repositories yet." or "The graph comes down to this device, into weft's own folder, and is kept in step with GitHub."
    - Then "Signed in as <login>", "Choose Repositories on GitHub…" (the app install URL), and "Sign Out" (destructive).
    - Pull to refresh reloads the repository list.
- **Clone location:** `ApplicationSupport/Weft/Graph`. It is cloned first into `Graph.partial` with full history (depth 0), then moved into place (GH/GitHubGraph.swift:15-16; reflect-mac/Sources/ReflectGit2/GraphClone.swift:11-34).
- **Token storage:** Keychain generic password, service `com.mariusae.Reflect.github`, account `github.tokens`. The value is JSON `{access, accessExpires, refresh, refreshExpires}` with accessibility `AfterFirstUnlockThisDeviceOnly`. The user object goes in UserDefaults under `github.user` (reflect-mac/Sources/ReflectGit2/GitHub.swift:43-80, 272-300).
- **Commit identity:** name, and `<id>+<login>@users.noreply.github.com`.
- **Sync:** libgit2 with the token, refreshed before each cycle (GitHubGraph.sync).

A6. Background sync, push, URLs
- **Silent push registration:** `application.registerForRemoteNotifications()` with no permission prompt. Info.plist has `UIBackgroundModes: remote-notification`.
- **Registering the device token:** `Push.received` → `GitHubGraph.register(deviceToken:for:)` → `SyncRelay.register(deviceToken, repository "owner/name", topic: bundle id (default "org.mutable.weft"), sandbox, accessToken)`.
- **Handling a push:** `didReceiveRemoteNotification` opens the graph if needed, runs `sync.sync`, and calls completion with `.newData` or `.noData` (IOS/AppDelegate.swift).
- **Foreground relay:** a WebSocket `SyncRelayListener` (GH/Relay.swift). It is followed on root change and on sign-in change, and reconnects when the scene becomes active. On a push it runs `syncNow(announcing: false)`.
- **Becoming active:** `store.activated()` (throttled to 1.5 s) runs `timePassed` and a quiet sync. Leaving active runs `saveEditing()` (ContentView.swift:265-267; WikiStore.swift:318-323).
- **URL scheme `weft`** (iOS/Info.plist):
  - `weft://river/<percent-encoded name>` → `rivers.current.follow(river: name)`, applied once the graph is loaded (WUI/Rivers.swift:580-616; RC/RiverLink.swift:35-45).
  - River links in text are `[[rivers/Name]]`.
- **Spotlight:** `onContinueUserActivity(CSSearchableItemActionType)` opens the page in the current river.
- **Handoff:** none.

======================================================================
B. THE EDITOR
======================================================================

**Two editors per card, chosen per page** (WikiStore.swift:1521-1576):
- `EditorMode.text` uses `TiddlerEditor`; `EditorMode.outline` uses `OutlineCardEditor`. On iOS `OutlineCardEditor` wraps the PhoneUI `OutlineEditor`; on the Mac it wraps `PageOutlineEditor`.
- **Default:** outline if `OutlineMarkdown.serialize(parse(text)) == text` and the text has no U+2028; otherwise text. The decision is cached per title and does not flip while the page is being written in.
- **Manual choice:** `setEditorMode`. Choosing outline for text that cannot round-trip shows an error.
- **Deleting the outline's one empty bullet** (Backspace at 0) switches the card to text and edits it (`writeAsText`).

B1. Text mode (ED/TiddlerEditor.swift, ED/MarkdownStyler.swift, ED/LinkPills.swift, ED/EditorAttachments.swift)

**Storage and view setup**
- The storage holds the raw Markdown body (frontmatter is excluded; it lives in `Tiddler` fields). Nothing is rewritten for display; all styling is attributes and layout.
- The view is a `UITextView` (iOS) or `NSTextView` (Mac) on a custom `LiveLayoutManager` with a `LiveGlyphs` delegate.
- Settings: scrolling off on iOS; `lineFragmentPadding` 0; inset top/bottom 2; plain text (not rich); undo on; smart quotes and dashes off; text replacement off on the Mac; find interaction on; tint is accent (TiddlerEditor.swift:1120-1156, 702-751).
- Base attributes: `TextSettings.font(size)`; text size is 17 on iOS and 14 on the Mac by default; serif when the "apple" face is chosen. Colour `Palette.text`, `lineSpacing` 3 (MarkdownStyler.swift:182-186).

**"Revealed" lines**
- These are the paragraphs the selection touches, plus a whole ```` ```query ```` block if the caret is inside one. They exist only while the editor is focused (EditorAttachments.swift:243-353; MarkdownStyler.swift:156-180).
- On selection change, the old and new revealed ranges are restyled.
- On edit, the edited paragraphs are restyled, or the whole text if the number of fences changed.

**How markup is hidden off the revealed lines**
- Hidden attributes: `.font = systemFont(0.1)` and `.foregroundColor = .clear` (`MarkdownStyler.hidden`, line 136). It is a near-zero-width font, not attachments.
- On revealed lines, markup is drawn in `Palette.faint` (ink at 0.32 alpha).
- Spell-check is suppressed over hidden text, labels, links and pills (Mac coordinator, 886-898).

**Hiding a whole line** (`LineLook.hidden`)
- The line gets the hidden attributes plus a paragraph style with `maximumLineHeight` 0.5 and `lineSpacing` 0.
- Used for: a query fence block when not revealed; a line that is only pictures; a line that is a lone link card; a line that is a lone embed (list items excepted).

**Headings** (`#`–`######` then a space)
- Font is `TextSettings.font(size × scale, .semibold)` with scales `[1.45, 1.25, 1.12, 1.05, 1, 1]`.
- The `#…# ` prefix is markup.
- Also applies to a list item whose content is `## …`.

**Emphasis**
- Bold `**x**` and `__x__`: semibold.
- Italic `*x*` and `_x_`: italic face.
- Strike `~~x~~`: single strikethrough.
- Code `` `x` ``: monospaced at size×0.92, background `codeBackground` (ink at 0.06).
- Markers are markup.
- A backslash escape: the backslash is markup.
- Highlight `==x==`: **not styled** in text mode.

**Block quote `> `**
- The marker is markup.
- When not revealed: indent 14/14, colour `Palette.dim` (secondary), and the `.weftQuote` attribute.
- The layout manager draws a 3pt-wide bar, radius 1.5, in faint colour, at x = line.minX + 3. It runs from the first line's used top + 2 to the last line's bottom − 2 (LinkPills.swift:144-167).

**Callout `> [!KIND]`**
- Same as a quote, with `[!KIND]` always faint.
- The bar button inserts `"> [!NOTE]\n> "`.

**Lists** (regex `^([ \t]*)([-*+]|\d+[.)])\s(?:\[([ xX])\]\s)?`)
- The leading whitespace is hidden. Depth = (spaces + 2 per tab) / 2.
- `firstLineHeadIndent` = depth × 20. `headIndent` = depth × 20 + the marker's width, so wrapped lines hang.
- The marker is faint.
- When not revealed and the bullet is `-`, `*` or `+`: the character gets `.weftBullet`, and `LiveGlyphs` swaps its glyph for U+2022 "•" (EditorAttachments.swift:34-52).
- Numbered items keep their visible digits, faint.

**Tasks `- [ ]` / `+ [ ]`**
- Done (`x` or `X`): the rest of the line is dim with a strikethrough.
- **Revealed:** the open box's space is kerned to the width of "x", so the words do not move when checked.
- **Not revealed:**
  - The marker is hidden.
  - The bullet character is kerned so the box occupies `ceil(size × 1.5)`.
  - `.weftTask = TaskBox(done, round: bullet == "+", size)` is set over bullet…`]`.
  - The layout manager draws an SF Symbol at side `round(pointSize × 0.95)`, centred on the cap-height middle at the marker's x (LinkPills.swift:124-140): `circle` / `checkmark.circle.fill` (round, for `+`) or `square` / `checkmark.square.fill`. Done uses a white tick on accent (palette); open uses dim.
- **Toggling by click:**
  - iOS: a `UITapGestureRecognizer` (`LinkTap`) that begins only over a task or link. Other taps must wait for it to fail.
  - Mac: `mouseDown` with a move tolerance under 4.
  - `task(at:)` returns the range of the character inside the brackets (`NSMaxRange(box) − 2`). `toggleTask` replaces it with "x" or " " and restores the selection (TiddlerEditor.swift:308-313; LinkPills.swift:325-331).
  - It only works when the view is editable.

**Code fences**
- Fence state is computed by scanning for ```` ``` ```` at line starts.
- Fence lines are mono and faint. Lines inside are mono in text colour.
- ```` ```query ```` blocks:
  - When not revealed, every line of the block is hidden.
  - The closing fence line carries the attachment `.block(source of the whole block)`, rendered under it as SwiftUI `MarkdownView(blocks:, editable:false)` → `QueryView`.
  - `QueryView` is a box with padding 12, radius 8, accent at 0.04 fill and 0.15 stroke. Its header shows `line.3.horizontal.decrease.circle`, the summary, and the count; results are a list, links, table, cards, count, or tree.
  - When revealed, a query's source is shown mono in accent colour.

**Tables and horizontal rules:** not specially styled in text mode. They show as text. `MarkdownView` would render them if shown elsewhere.

**Images**
- `![alt](src)` and an optional size comment `<!-- {"width":425,"height":270} -->` are markup.
- The line gets attachment `.pictures([ImageReference])`. The line is hidden when it has no other words (list items keep their line).
- Pictures are drawn under the line by an `EditorAttachments` hosting view (`UIHostingController` or `NSHostingView`) at x = padding + headIndent and y = the line's used maxY + 4. The width is the text width minus the indent.
- The line keeps `paragraphSpacing` = the measured height + 10. Heights are reported by `onGeometryChange`; when a height changes, that line is restyled (EditorAttachments.swift:111-219; MarkdownStyler.swift:116-132).
- `PictureView` (WUI/Rich.swift:170-233):
  - Aspect fit. Max width is `reference.width`, else the natural width.
  - Radius 5, with a 0.5 rule stroke.
  - Placeholder: a rule at 0.3 opacity, aspect w/h or 4:3, max width 320.
  - Loaded at width (`reference.width` or 760) × screen scale.
  - Sources: `http(s)`, or a graph-relative file via `store.file`.
- There is no resizing in text mode.

**A link alone on its line:** attachment `.card(source, text)`, rendered as `LinkCardView`, a rich preview card. The line is hidden.

**Embed `![[Title]]` alone on its line:** attachment `.block("![[Title]]")`. `MarkdownView` renders it as `Embed` showing the page live, or as `RiverEmbed` for `rivers/X`. The line is hidden. The `!` counts as markup.

**Link and tag pills** (MarkdownStyler.swift:313-406; LinkPills.swift)
- Recognised spans: `[[Title]]` and `[[Title|label]]`, `[text](addr)`, `<https://…>`, bare URLs, and `#tag` (tag regex `(?<=^|\s)#\p{L}[\p{L}\p{N}/_-]*`).
- In headings, links are only coloured; there are no pills.
- **Kind:** tag; day (Day or Week title); river (`rivers/…`); page; web. `[words](Title)` with no colon in the target is treated as a page.
- **Colour:** words in accent. A missing page uses dim italic.
- **When not revealed:**
  - The last hidden character of the opening markup gets a kern of `leadWidth = 4 + iconSide + 3`, where `iconSide = round(pointSize × 0.72)`. Without an icon it is 3.
  - The last character of the closing markup gets a kern of max(0.5, 3 − the width already taken by hidden text).
  - `.weftPill = LinkPill` is set over the whole span.
- **Drawing** (`drawBackground`):
  - For each line piece of the shown glyphs, trimming hidden glyphs at both ends, a rounded rect is drawn: radius 5; x = rect.minX − pad and width + 2·pad, where pad is 1 with an icon and 3 without; y = baseline − ceil(ascender) − 2; height = ascent + descent + 4.
  - Fill is the tint at 0.12 alpha (0.10 when missing).
  - The icon is an SF Symbol at side × 0.9, medium weight, in the tint colour, centred in a box (first.minX + 4, side wide).
  - Icons: the target's own page or river icon if it has one; else `link` (web), `doc.text` (page), `calendar` (day), `square.stack` (river). Tags have no icon.
- **Web addresses** are shortened by `AddressShortening`: the scheme and prefix are hidden, the middle is hidden with an ellipsis "…" drawn in its kerned slot, and the rest is hidden.
- **Untitled targets** (`untitled-YYYY-…`): the first character becomes invisible and is kerned to the width of the page's first-line label (truncated to 48 characters with "…"). The rest of the name is hidden. The label is drawn at that position.
- **Click detection:**
  - `.weftLink = URL` is set over the words; when not revealed, over the whole span including the icon room.
  - `link(at:)` maps the point to a glyph and requires the glyph's bounding rect, inset by (−2, −3), to contain the point.
  - iOS: a tap follows the link (`LinkTap`), and other taps wait for it.
  - Mac: a hand cursor on hover; a click follows on mouse-up if moved less than 4; a context menu offers Open and Copy Link.
  - `follow()`: an internal title opens in the river after the current card (`.snappy(0.28)`); a URL opens externally (LinkPills.swift:366-376).

**Sizing**
- iOS: `sizeThatFits` = max(the text view's fit, the lowest attachment bottom + insets, ceil(size × 1.6)).
- Mac: the used rect, the attachment bottom, or ceil(size × 1.5).

B2. `[[` completion
- `linkPartialRange`: from just after the last `[[` on the caret's line up to the caret, provided the text between contains no `]` or `|` (TiddlerEditor.swift:186-195).
- **Suggestions** (`store.linkSuggestions`, limit 8; WikiStore.swift:1998-2011):
  - Empty text: recent pages.
  - Otherwise: wiki search hits (limit × 3) filtered to names or aliases containing the query. Untitled pages match by their shown name.
  - A day match (today, yesterday, tomorrow, or YYYY-MM-DD) goes first.
  - Up to 2 saved rivers go last among the matches.
  - "new" is appended if nothing matches exactly.
  - The list shows each item's symbol and label (Wiki, Note, Day, River, "New page").
- **Mac text view:**
  - Ghost completion: when the best item's title begins with what was typed, the rest is shown faint right after the caret, in an `NSTextField` label using the font of the previous character.
  - A popup list in a child `NSPanel` under the caret (above it if there is no room below): width 340, rows padded 8/5, radius 6, the selected row on accent, material background, radius 11 (TiddlerEditor.swift:270-304, 651-684).
  - Keys while it shows: ↑/↓ move, wrapping. Return or Tab accepts. → accepts only when the ghost is showing. Escape dismisses, and the same typed text is not offered again until it changes.
  - Accepting replaces the typed text with the title, then skips an existing `]]` or inserts one.
  - Scrolling hides it. ⌘K starts `[[` and opens the offers; with a selection it wraps the selection as `[[sel]]`.
- **iOS text view:**
  - No popup. The suggestions appear as chips in the keyboard bar's capsule: filled capsules, the first in accent with white semibold 15pt text, the others on `Ink.pill`; symbol 12pt medium; insets 6/12; spacing 6; scrolling horizontally (PUI/OutlineEditor.swift:3666-3696).
  - A "new" chip reads New "x".
  - Tapping a chip completes the link. There is no Return-to-accept in text mode on iOS.
- **Phone outline editor:**
  - Triggers are `@` at the start of a word and `[[` (not `[[[`), outside code.
  - Candidates come from `LinkSuggestions.candidates` against the `NoteIndex`: a day first, then topics marked `#`, then notes.
  - After `[[`, a New "x" item is appended when there is no exact match.
  - Chips work the same way. **Return accepts the first chip.** Accepted text is `[[Name]]`, replacing the trigger and what was typed.
  - The chip icons: `calendar`, `square.stack`, `plus`, `number` (topic), `doc.text` (PUI/OutlineEditor.swift:2127-2166, 3656-3661).
- **Mac outline:** an `[[`/`@` LinkCompletion panel. ↑/↓ choose; Tab or Return accept; Escape ends it (RUI/Editor/OutlineTextView.swift:1623-1660, 1740-1744, 1834-1862).
- **Card title field:** `@` or `[[` offers pages in a `SuggestionList` under the title. ↑/↓ choose; Tab or Return take one; Escape dismisses. The page's name is inserted as plain words (Card.swift:649-719, 784-812).
- **Tags:** there is no inline `#` completion. The tag field suggests up to 8 existing tags (prefix matches, then contains) as outlined capsules (CardEditor.swift:181-256).

B3. Keyboard shortcuts in the editor

**Text mode, Mac** (TiddlerEditor.swift:499-606; WUI/../WeftMac/RiverWindow.swift:193-211)

| Key | Action |
|---|---|
| ⌘B | `wrap("**")` |
| ⌘I | `wrap("*")` |
| ⌘K | `startLink()` |
| ⌘↩ | `cycleChecklist`, through the Format menu, while writing |
| ⇧⌘↩ | `cycleTask` |
| ⌃⌘T | Title Tiddler, by first line (`titleByFirstLine`), else edit the title |
| Escape | dismiss completions; otherwise `onEscape` → end editing (resign first responder) |
| Return at end of a `# ` first line of an untitled page | title it (see B6) |

**What the text-mode controller operations do** (TiddlerEditor.swift:15-182)
- `wrap(m)`: wraps the selection, or inserts a pair of markers with the caret between them.
- `prefixLines(p)`: toggles prefix `p` on every touched line (off only if all of them have it).
- `cycleHeading`: none → `#` → `##` → `###` → none, after any list marker.
- `cycleChecklist` / `cycleTask` (`cycleBox`):
  - `- [ ] ` becomes `- [x] `.
  - `- [x] ` becomes plain `- `.
  - Any other list item (`- [ ]`, `+ [ ]`, `- `, `* `, `+ `) becomes `<m> [ ] `.
  - Plain text becomes `<m> [ ] text`.
  - `m` is `-` for a checklist, `+` for a task.
- `shiftLines(±1)`: adds 2 spaces, or removes up to 2 spaces or one tab.
- `moveLines(±1)`: swaps the touched lines with the line above or below.
- `insertBlock`: inserts in its own paragraph with blank-line padding.

**Text mode, iOS:** no key commands. Formatting goes through the keyboard bar (B5).

**Phone outline editor `keyCommands`** (PUI/OutlineEditor.swift:2300-2322)

| Key | Action |
|---|---|
| Tab / ⇧Tab | Indent / Outdent |
| ⌃⌘↑ / ⌃⌘↓ | Move row up / down |
| ⌘B, ⌘I | Bold, Italic |
| ⇧⌘H | Highlight |
| ⌥⌘K | Link `[[]]` |
| ⌘↩ | Checklist item cycle |
| ⇧⌘↩ | Task cycle |
| ⌘9 / ⌘0 | Fold / Unfold the caret's row |
| ⌥⌘↩ | New Time Block |

- **Checklist/task cycle** (`OutlineEditing.cycle`, RC/OutlineEditing.swift:266-292). The first selected row decides for all of them:
  - If it is already this kind of checkbox: open → done (`x`); done → plain bullet `-`.
  - Otherwise it becomes an open box with marker `+` (task) or `-` (checklist; `*` is kept).
  - Headings, code and rules are skipped.
- **Mark toggles:** if the selection is already wrapped in `m`, the markers are removed. Otherwise `m…m` is inserted, with a space first if the caret directly follows a word. Selection haptic (2353-2382).

**Mac outline (`PageOutlineEditor` with `takesEditorKeys`)** (RUI/EditorMenus.swift:10-72)

| Key | Action |
|---|---|
| ⌘B, ⌘I | Bold, Italic |
| ⇧⌘` | Code |
| ⇧⌘- | Strikethrough |
| ⇧⌘H | Highlight |
| ⌥⌘K | Link… |
| ⇧⌘8 | Bullet |
| ⌘↩ / ⇧⌘↩ | Checklist / Task |
| ⌥⌘- | Horizontal Line |
| ⌥⌘C | Code Block |
| ⌥⌘↩ | Time Block |
| ⌃⌘→ / ⌃⌘← | Indent / Outdent |
| ⌃⌘↑ / ⌃⌘↓ | Move Up / Down |
| ⌃⇧⌘D | Move Done to Bottom |
| ⇧⌘D | Duplicate |
| ⇧⌘K | Delete Rows |
| ⌘0 / ⌘9 | Unfold / Fold |
| ⌃⌘0 / ⌃⌘9 | Unfold / Fold Completely |
| ⌥⌘0 / ⌥⌘9 | Unfold / Fold All |
| ⌥⌘→ / ⌥⌘← | Focus In / Out |
| ⇧⌘L | Select Paragraph |
| ⇧⌘B | Select Branch |
| ⌥⌘↑ / ⌥⌘↓ | Expand / Contract Selection |
| ⇧Return | line break within the row |
| Tab / ⇧Tab | indent / outdent (in code, Tab inserts 4 spaces) |

- **Escape:** first ends completion. Then, from text, it selects the caret's row as a row. From a row selection, Weft's `onEscapeFromRows` takes the caret out of the card entirely (OutlineCardEditor.swift:86; OutlineTextView.swift:1740-1756).

**Card level (both platforms)**
- In the iPad `PadCommands`, ⌘↩ switches between outline and text.
- In the Weft Mac menus, ⌘↩ is the Format checklist command.
- Weft Mac also has "Write in Selected Card" and the other river keys.

B4. Outline-mode behaviours a unified editor must reproduce

**Model**
- Rows (`Row`: kind = bullet, paragraph, heading(n), ordered, quote, code, rule; depth; marker `-` `*` `+` or `.`/`)`; number; task open or done; folded children; gap).
- Text storage on phone: one paragraph per row, holding the row's **text only**. The markers live in the `.outlineRow` `RowStyle` attribute and are drawn in the margin.
- Soft line breaks inside a row are U+2028.
- On save: `OutlineMarkdown.serialize`, written around the "shell" (frontmatter and similar).
- Folds are kept per river per card (`river.rowFolds` / `setRowFolds`), not in the text (PhoneOutlineEditor.swift:95-132).

**Inline markup in the outline**
- Hidden per *span*, not per line. A span is revealed when the caret is inside it or at its end (`revealed = NSLocationInRange(caret, span) || caret == max`).
- Hidden characters get null glyphs, or zero-advancement control glyphs at a row start (`.prismHidden`), from the layout delegate (PUI/OutlineEditor.swift:729-804).

**Return** (`OutlineKeys.split`, PC/OutlineKeys.swift:26-67)
- Splits the row at the caret.
- At offset 0 with text after it: a new empty row is inserted *above*, and the caret stays with the text.
- At the end of a row that has children: the new row becomes the first child, copying the child's kind and marker (number 1; task open).
- After a heading or a rule, the new row is a plain bullet.
- A checkbox row is followed by an open checkbox; an ordered row by number+1.
- Inside code, Return inserts a line; on the closing fence line it leaves the block.
- With an active completion, Return accepts the first suggestion.
- On a `# ` first row of an untitled page, Return titles the page.

**Backspace at a row's start**
- A typed row (task, heading, quote, ordered, code, and so on) first becomes a plain `-` bullet (`OutlineKeys.plain`). A task loses its checkbox first.
- Otherwise the row joins the row above (the normal text deletion of the line break). Row 0 does nothing.
- An outline of one empty bullet: `onDeleteInEmpty` switches the card to text mode.
- Deleting just after a picture deletes the whole picture span (OutlineEditor.swift:2029-2049).

**Smart typing at a row's start** (prefix of 6 characters or fewer, then a space)
- `#`…: heading of that level.
- `>`: quote.
- `[]`, `[ ]`, `[x]`, `-[]`: checklist item.
- `+`: task.
- `1.` / `1)`: ordered.
- `-`, `*` on a paragraph: bullet.

**Tab / ⇧Tab**
- `OutlineEditing.indent`: makes the rows children of the previous sibling. That sibling must be able to have children; if it is folded, it unfolds.
- `outdent`: depth − 1. The following siblings become its children.
- Both normalise: depth is at most previous + 1, and only under a list item.
- Phone: a swipe right or left on a row while typing indents or outdents it, with a light haptic (3309-3320).

**Move up / down:** swaps with the previous or next sibling at the same outline level, carrying the subtree. Blank-line gaps stay in place (RC/OutlineEditing.swift:123-149).

**Folding**
- On phone, tapping a bullet marker with children folds or unfolds it. Tapping a task marker toggles done.
- A folded row shows a pill after its last word: height `capHeight + 9`, width height×1.7, 6 after the words, ink at 0.07 alpha with three dots (PUI/OutlineEditor.swift:924-950). Tapping it unfolds.
- ⌘9 / ⌘0, and the bar's fold button.
- Fold state goes to the river.

**Row hold menu (phone)**
- Hold 0.4 s: on a marker while typing, anywhere while reading.
- Let go in place: a menu with Unfold/Fold, Unfold/Fold Completely, Mark Done/Not Done, Move Done to Bottom, Do Today / Later…, Copy, Cut, Move to…, the Reorder submenu (Move to Top, Up, Down, Bottom), Select Rows, Turn Into…, Delete Row.
- Hold and drag: the row is lifted (scaled 1.03, shadow 0.18 radius 10, medium haptic) and dropped before the row under the finger. Horizontal position sets the depth, clamped to the legal range (PUI/RowDrag.swift).

**Multi-row selection**
- Phone: "Select Rows" enters choosing mode. Taps toggle rows, tinted `Ink.pill` with radius 8. A glass bar of 52 height sits 84 above the bottom inset: Done `checkmark.circle`, Outdent, Indent, Copy `doc.on.doc`, Move to…, Delete `trash` (red), Stop `xmark` (PUI/RowSelection.swift).
- Mac: a text selection that crosses rows becomes a row selection. Escape selects the current row. ↑/↓ move the row selection; ⇧↑/⇧↓ extend it; ←/→ fold or unfold; Space toggles done; Return makes a new row after it; Delete deletes the rows; copy gives Markdown (OutlineTextView.swift:506-540, 1623-1700, 1769-1775, 1856-1861, 1892-1930, 1971-1999).

**Caret between rows**
- Normal text-view movement; the caret never rests inside hidden markup.
- Mac ←/→ step over hidden markup within the row (`stepOverMarkup`).
- ↑ on the first line or ↓ on the last line hands the caret to the neighbouring editor via `navigator.leaveThrough(.top/.bottom, x:)`.
- A selection touching a picture expands to cover the whole picture.

**Drawing (phone)** (PUI/OutlineEditor.swift:52-122, 322-356, 1191-1347; PUI/Typeface.swift:265-267)
- **Metrics.** Indent step = round(size × spacing.indent), with spacing.indent = 1.35, so 23 at size 17.
  - textIndent = step × (min(depth, 8) + 1).
  - The marker is centred at x = step × depth + step/2.
  - Line height is 1.36–1.42 em, depending on the face.
  - Row gap (paragraph spacing) = round(size × 0.30–0.32).
- **Spacing before.**
  - Headings: lineHeightMultiple 1.12, with room above of round(size × 1.25) for levels 1–2 and round(size × 0.9) otherwise.
  - Group starts: round(size × 0.6).
  - The room is split half above and half below between adjacent rows.
- **Heading sizes.** level 1 = round(size × headingScale) with headingScale 1.45–1.55; level 2 = 1 + (top − 1) × 0.55; level 3 = 1 + (top − 1) × 0.22; levels 4–6 = 1.0. Levels 1–2 are bold; 3 and below are semibold.
- **Bullet.** A filled dot, diameter max(4.5, round(pointSize × 0.3)), in secondary colour, at the x-height middle.
  - If checkboxes sit under the bullet, a progress ring of side round(pointSize × 0.95), lineWidth 1.6, is drawn around it.
- **Checkbox.** Side (pointSize × 0.82).
  - Round for `+` tasks; a rounded square (radius 3.5) for checklist items.
  - Open: stroke 1.4 in secondary.
  - Done: filled with accent, with a white tick drawn as a path (0.27,0.5) → (0.44,0.68) → (0.74,0.32), width 1.8, round caps.
  - Done rows use secondary text.
- **Ordered.** `"N."` in monospaced digits at 0.85 × pointSize, secondary, right-aligned 6 before the text indent.
- **Quote.** A 3-wide faint bar at the marker x.
- **Code block.** A `codeBack` rounded rect (radius 6) from textIndent − 8 to the right edge; code font is mono at 0.88.
- **Rule.** A 1pt `Ink.rule` line.
- **Inline code.** A rounded rect (radius 4) behind each line run.
- **Highlight.** `Ink.marked`, radius 3.
- **Pills.** `Ink.pill`, radius 5, outset 3, from capHeight + pad above the baseline to the descender + pad.
- **Link icons.** 0.72 × pointSize, drawn in a control-glyph slot of width 2 + side + 4.

**Mac outline indent:** `round(fontSize × 1.6) × (depth + 1)`. The font size is `TextSettings.size + 1` (RUI/Editor/OutlineStyler.swift:28, 78-80; OutlineCardEditor.swift:24).

B5. The phone keyboard accessory bar (`OutlineToolbar`, PUI/OutlineEditor.swift:3425-3697)

**Layout**
- A `UIInputView`, height 32 + 8 + 46 + 6 = 92, clear background.
- Its pieces sit in a `UIGlassContainerEffect` (spacing 12), each an interactive `UIGlassEffect` capsule.
- **Top row:** three small capsules, each 88 wide and 32 tall, centred over the main capsule and separated by gaps of 8. Their symbols are 14pt:
  - Undo `arrow.uturn.backward` / Redo `arrow.uturn.forward` (dimmed when unavailable)
  - Outdent `decrease.indent` / Indent `increase.indent`
  - Move Up `arrow.up` / Move Down `arrow.down`
- **Bottom row:**
  - Left: the **Aa** button, symbol `textformat`, 17pt, in a 46×46 capsule.
  - Middle: the main capsule of tools, 17pt symbols, distributed evenly.
  - Right: **Done**, `keyboard.chevron.compact.down`, which resigns first responder.
  - Side margins are max(12, safe area + 8).
- Touches between the pieces pass through to the text behind.

**Main capsule tools**
- Phone outline editor: Fold `rectangle.compress.vertical` (swaps to `rectangle.expand.vertical` "Unfold"; disabled when the row cannot fold); Checklist `checkmark.square`; Task `checkmark.circle`; Link `link`; New Time Block `clock`; Dictate `mic` (`mic.fill` red while listening, 45% red while connecting).
- Text editor (TiddlerEditor.swift:1011-1018): List `list.bullet` (prefix `- `); Checklist `checkmark.square`; Link `link`; Embed `square.on.square` (`![[`); Callout `lightbulb` (inserts `> [!NOTE]\n> `); Title `textformat.size.larger` (title by first line, or edit the title).

**Aa format menu** (`OutlineToolbar.formatting`)
- Bold `bold`, Italic `italic`, Strikethrough `strikethrough`, Highlight `highlighter`, Code `chevron.left.forwardslash.chevron.right`, Heading `number` (cycles), Quote `text.quote`.
- Toggling Aa crossfades the capsule between the tools and the formatting buttons with a spring (0.25 s, damping 0.85). The Aa glass is tinted accent with a white glyph while formatting shows.

**The completion "capsule"**
- While completing, the main capsule's tools are hidden and replaced by a horizontal scroll of chips (see B2).
- When completion ends, the tools come back.

B6. Saving

**Editor to store** (TiddlerEditor.swift:1160-1247; PhoneOutlineEditor.swift:79-132)
- Each keystroke cancels and reschedules a 0.15 s flush (`flushDelay`). The flush pushes the text into the `Binding` → `store.change(title){ $0.text = value }`. The outline serialises its rows at that point.
- A flush also happens on end-editing, on dismantle, and on the `.weftFlushEdits` notification.

**Store to disk** (WikiStore.swift:1112-1125, 1629-1695)
- The first `change` starts a draft. It copies the tiddler, adds it to `editing`, and records `draftBases[title] = wiki[title]` as the merge base.
- Each change restarts the autosave timer: 0.8 s, or 2.5 s for text over 30,000 UTF-8 bytes. Autosave writes the draft **under the original title**; a typed title is ignored until editing finishes.
- An untouched new page is never written: a new title with empty text and only default fields and tags.

**When a title change takes effect: `finishEditing`** (1699-1742)
- It runs when the caret leaves the card: `river.caretLeft` waits 0.25 s, checks that no part of the card regained the caret and that no other river is writing in it, then calls `store.finishEditing` (River.swift:685-705).
- It also runs on close (`cardClosed`) and when the app goes to the background (`saveEditing`), if the draft has a pending title change.
- An untouched page is dropped and its card closed quietly.
- An empty title becomes untitled again, under a new `untitled-<date>-<4 letters>` name.
- A clash with an existing title gives the error "There is already a tiddler called "X"; this one keeps its title."
- The page is written, and links are relinked from the old title to the new one if `relinkOnRename` is on (the default). The toggle "Update N tiddlers that refer to "X"" appears under the title while renaming.
- Every river is told `renamed`, and saved rivers are revised.
- The title is typed in the card's header `TextField` (`store.change { $0.title = value }`). Submitting a new tiddler moves the caret to the body; submitting a rename ends editing.

**Untitled pages titled by a `# ` first line** (ED/TitleChip.swift)
- `FirstLineTitle.heading`: the first non-blank line is `# ` followed by words.
- A quiet chip, "↑ Title", appears just after that line while the caret is in the editor. iOS: `arrow.up` 10pt, "Title" 13pt medium, tertiaryLabel, insets 6, placed 2 after the line end. Mac: 9pt, offset 8.
- Tapping the chip, or pressing Return at the very end of that heading line, runs `titleByFirstLine`:
  - `onTitle(Untitled.title(from: line))` strips the markdown marks and cuts after a word past 60 characters.
  - It then deletes that line and the blank lines after it, and puts the caret at 0.
- The phone outline does the same through `titlesByHeading` and `offersTitleChip`. Its chip is offered only while `store.offersTitle` (a fresh untitled page made here) is true.
- From the menu, `river.titleByFirstLine` uses `WikiStore.titledByFirstLine` and bumps `store.noteReplaced(title)`, which forces an outline that has the caret to reload (PhoneOutlineEditor.swift:211-215).
- An untitled page with no title row shows "Add Title…". In its title field, the placeholder is the suggested first-line name, and Return accepts that suggestion.

**File changed underneath**
- A pull reloads the changed pages (`pulled`); drafts are left as they are (WikiStore.swift:403-417).
- On write, if `draftBases[title] != wiki[title]` (the file changed since the draft began), it does a three-way merge: `TiddlerMerge.merge(draft:, base:, current:)`, where `TiddlerMerge` = `PageMerge` (WikiStore.swift:1750-1755; weft/Sources/WeftCore/Names.swift:7). The base is then reset to the saved version.
- An editor that is *not* focused takes the new text immediately: `updateUIView` replaces the view's text when it differs from what it was last given.
- The phone outline reloads only when it is not first responder, or when a replacement was forced.
- Files with conflict markers show `ConflictView` instead of the editor (`needsReview`).

**One page open in two rivers**
- Drafts are keyed by title in the single `WikiStore`, so every card for that title binds to the same `store.draft(title)`. Edits in one card reach the other through observation, as long as the other is not focused.
- `finishEditing` is skipped while any river still has the caret in that card (River.swift:702).
- The draft is dropped only when no river has the card open (`cardClosed`, WikiStore.swift:1151-1155).

B7. Pasting and dropping pictures

**Where files go:** the graph's `assets/`, named `pasted-<epoch milliseconds>.<ext>`. If the name exists, `-2`, `-3` and so on up to 1000, created with O_EXCL (RC/Assets.swift:19-21, 68-90).

**Kinds kept:**
- png, jpg and gif keep their own bytes.
- iOS: any other image becomes JPEG at quality 0.9 (HEIC photos included).
- Mac: any other image becomes PNG.

**Inserted Markdown:** `![](assets/pasted-….png)`. Several pictures are joined with a single space and inserted at the caret (ED/PastedPictures.swift:19-25).

**When it applies:**
- iOS text view: only when the pasteboard has images and **no strings**. Paste is enabled for images (TiddlerEditor.swift:968-982).
- Mac text view: file URLs of pictures (even with strings), or image data with no string. Dropping image files, PNG, TIFF or JPEG inserts at the drop point (TiddlerEditor.swift:366-387).
- Phone outline: the same rule (images and no strings). Pasting a URL onto selected words links them instead (PUI/OutlineEditor.swift:2636-2652).

**Display:**
- Text mode: under the line, as described in B1. No resizing.
- Phone outline: inline. The picture's `[` becomes a control glyph as wide as the line, and the line height becomes the image height + 2×6 margin.
  - Fitted to the line width, `reference.width` if given, and a maximum height of 420.
  - Two or more adjacent pictures form a carousel: tap the edges (30% each side) or swipe to turn; dots underneath (20 room).
  - Tapping a picture opens a QuickLook viewer. Holding it offers Copy and Share….
  - The markdown is revealed when the caret is inside the span (PUI/OutlineEditor.swift:504-536, 2600-2620; PUI/PhoneImages.swift:122-148).
- Mac outline: a resize grip (18pt) in the bottom-right corner on hover. Double-clicking the grip restores the natural size. The size is stored in the editor's per-device state, **not** in the Markdown (RUI/Editor/PictureResize.swift:1-15).
- The Markdown width hint `<!-- {"width":N,"height":M} -->` after an image is read as `ImageReference.width/height` (RC/InlineMarkup.swift:54-74, 84).
