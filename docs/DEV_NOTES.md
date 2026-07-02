# Somnia — developer notes

A personal browser built on **WebKit + Swift (SwiftUI)**, fused with an
**Obsidian-style** notes vault. Beyond ordinary browsing: markdown notes with a
connection graph, spaces (tab groups), bookmarks, theming, and a tab-optimization
policy for when you keep a lot of tabs open.

---

## Quick start

```bash
./build.sh            # builds Somnia.app (swiftc directly)
open Somnia.app
./test.sh             # pure-logic unit tests (resolve / wikiLinks / markdown / …)
```

Rebuild during development:
```bash
pkill -f "Somnia.app/Contents/MacOS/Somnia"; ./build.sh && open Somnia.app
```

### ⚠️ Toolchain notes
- The project builds with only the **Command Line Tools** — full Xcode is not
  required.
- **SwiftPM (`swift build`) does NOT work** here (the manifest doesn't link under
  CLT). `Package.swift` is kept for reference only; the real build goes through
  **`build.sh`**, which invokes `xcrun swiftc` directly and assembles the `.app`
  bundle.
- Known CLT bug: a duplicate modulemap (`module.modulemap` + `bridging.modulemap`
  both declaring `SwiftBridging`) can break even `import SwiftUI`. If a
  "redefinition of module 'SwiftBridging'" error appears after a CLT update:
  ```bash
  sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap{,.bak}
  ```

---

## Architecture

**Hybrid:** a native SwiftUI shell (window, sidebar, toolbar, notes editor) plus
`WKWebView` for web pages and for the notes graph. The web-tech seam is confined
to the graph (`GraphWebView`).

**Why:** the "blur the main background when Notes opens" effect from the mockup
isn't possible in the web layer (CSS `backdrop-filter` can't see the native
`WKWebView` content beneath it). It's done natively with `NSVisualEffectView`
(`blendingMode = .withinWindow`) over the web view.

### Source map (`Sources/Somnia/`)

| File | Responsibility |
|------|-----------------|
| `App.swift` | `@main`, `WindowGroup` (`.hiddenTitleBar`), injects `BrowserState` / `Theme` / `NotesStore` as environment objects. **macOS menu** (`.commands`): File/View/History/Tabs with standard shortcuts. |
| `Theme.swift` | Design tokens: Aurora/Slate palettes × light/dark, accent, density. Optional color overrides `bgHex/surfaceHex/textHex` over the presets (secondary tokens derived), `binding(for:)`, `Color.hexString`, `Theme.current`. `PanelBackground`, `AuroraGlow`. Loads/writes `settings.json`. |
| `Models.swift` | `Tab`, `Space`, **`BrowserState`** — browser core: tabs, spaces, bookmarks, navigation, the tab-optimization policy, session persistence, memory-pressure handling. |
| `Web.swift` | `WebViewPool` (one WKWebView per tab, lazy + sleep/remove via `interactionState`), `WebHostView`, `WebArea` (NSViewRepresentable), `VisualEffect` (native blur), `TabNavDelegate`, downloads, in-page find, content-rule application. |
| `Notes.swift` | `Note`, **`NotesStore`** (vault, CRUD, `[[wiki-link]]` parsing, backlinks, title dedupe, graphJSON), `GraphWebView` + the embedded `graph.html`. |
| `Markdown.swift` | `MarkdownView` — native block markdown render + clickable `[[links]]` via the `somnia://note/<title>` scheme. |
| `Reader.swift` | `ReaderMode` — a compact readability extractor (embedded JS) + themed HTML assembly for the reading view. |
| `Palette.swift` | `CommandPalette` (⌘K) — search across web / tabs / bookmarks / history / notes. |
| `Store.swift` | JSON store (`session.json`, `settings.json`), Codable DTOs (`PersistedSession`, `Bookmark`, …), `vaultDir` (Application Support) + `migrateLegacyVault`. |
| `Features.swift` | `SearchEngine` (Google/DDG/Bing/Brave), `HistoryStore`, `FaviconStore`, `DownloadsModel`/`DownloadItem`, `ContentBlocker` (`WKContentRuleList` — trackers/ads). |
| `UI.swift` | All SwiftUI layout: `RootView`, `SidebarView`, `AddressBar`, `TabRow`, `SpaceSwitcher`, `SpaceHeader`, `BookmarksSection`, `ToolbarView`, `HomeView`, `NotesPanel`, `NoteEditorView`, `CustomizePanel`, `FindBar`, downloads popover. |

### Where data lives
Everything is under `~/Library/Application Support/Somnia/` (`Store.dir`), so the
`.app` is self-contained and portable (a copy on another machine keeps its
notes/session):
- `Vault/<UUID>.md` — **notes** (YAML frontmatter `id/title/tags/created/updated`
  + markdown body). `Store.migrateLegacyVault` does a one-time copy from an old
  source-tree `Vault/` on first launch if present (never re-imports after edits).
- `session.json` — tabs, spaces, bookmarks, active tab, budget, sidebar state.
- `settings.json` — theme (appearance/direction/accent/density + custom colors +
  `homeBgImage` + `searchEngine` + `blockTrackers`).
- `history.json` — visit log (http(s), deduped by URL, capped at 3000; feeds ⌘K
  and address autocomplete; cleared from Customize).
- `favicons/<host>.png` — favicon cache (fetched from the sites themselves, not a
  third-party favicon service).
- `backgrounds/` — copies of chosen Home background images.
- `notes-config.json` — selected notes source (`local`/`obsidian`) and external
  Obsidian vault path.
- `graph.html` — the graph renderer (generated from `GraphWebView.graphHTML`).

An **external Obsidian vault (read-only)** can be any folder the user picks
(including cloud folders); it's read recursively and never modified.

---

## Key mechanics

- **Tab optimization** (`BrowserState` + `WebViewPool`): lazy WKWebView creation
  on first activation; a `maxLiveTabs` budget (default 6, configurable); LRU sleep
  on overflow and on idle (`idleLimit` **15 min**) via `sleep()`, preserving
  `interactionState`; waking restores history + scroll without a cold reload.
  Sleeping tabs are marked with a moon. **Tabs playing audio/video aren't slept**
  (async JS probe over `<video>/<audio>`; `Tab.isPlayingMedia` cached, refreshed
  by a 30s sweep). Under **system memory pressure** background tabs are slept
  immediately to free web-content processes.
- **Fullscreen**: `cfg.preferences.isElementFullscreenEnabled` — the fullscreen
  button on YouTube/Netflix works.
- **Spaces**: dot switcher + "+", rename (double-click / "⋯" menu), delete
  (also via right-click on a space dot).
- **Bookmarks**: star in the toolbar / button in the sidebar; a BOOKMARKS section;
  click opens a new tab. A bookmarks pseudo-space renders a card grid.
- **Notes**: editor (title/tags/body) ↔ preview (✎/👁); LINKS/BACKLINKS are
  clickable; the graph is a two-way Swift↔web bridge (click a node to open the
  note). Empty "Untitled" notes are pruned; titles are deduped. The graph supports
  wheel zoom (to cursor) and pan.
- **Two note sources** (`enum VaultSource { local, obsidian }`): **Local** =
  the internal vault (read-write); **Obsidian** = an external vault (**read-only**,
  recursive load, identity by filename so `[[links]]` resolve, `id` =
  deterministic `stableID` from the relative path). In read-only mode every
  mutating op is a no-op. Cloud folders (iCloud/Dropbox) are read as normal;
  online-only files are requested via `startDownloadingUbiquitousItem` and skipped
  without crashing.
- **Cmd-click a link** → new **background** tab (created asleep, loads lazily).
  `target="_blank"` / `window.open` → new **foreground** tab via
  `WKUIDelegate.createWebViewWith`.
- **Reliable current-URL persistence**: `TabNavDelegate` observes `WKWebView.url`
  / `.title` via KVO, so SPA navigations (History API `pushState`) that never fire
  `didFinish` still update the `Tab` and trigger `scheduleSave`.
- **Home screen** (`HomeView`, shown for a tab with no URL): live clock, search
  field, notes mini-graph, and an optional background image under a light
  auto-scrim.
- **Shortcuts + macOS menu** (`App.swift`, `.commands`): File — New Tab ⌘T, New
  Private Tab ⌘⇧N, Open File ⌘O, Close Tab ⌘W; View — Reload ⌘R, Reader ⌘⇧R,
  Find on Page ⌘F, Open Location ⌘L, Customize ⌘,; History — Back ⌘[, Forward ⌘];
  Tabs — Quick Open ⌘K, Next/Prev ⌘⇧]/⌘⇧[, Select Tab ⌘1–9.
- **Find on page** (⌘F): native `WKWebView.find`; the find bar steps matches with
  ↑/↓.
- **File reader**: ⌘O (`NSOpenPanel`, pdf/html) and drag-drop a file → new
  `file://` tab. A local path / `file://` URL typed in the address bar opens as a
  file too (`BrowserState.resolve` recognizes it before the search heuristic).
- **Reader Mode** (`Reader.swift`, ⌘⇧R): JS article extractor → themed HTML →
  `loadHTMLString`; the generated HTML is cached and re-loaded on wake so slept
  reader tabs restore correctly.
- **Customization** (Customize panel): Light/Dark, Aurora/Slate, Background/Panel/
  Text/Accent color pickers over presets + Reset, density, tab budget, panel
  transparency, search engine, tracker blocking, Home background, clear history.
- **Sidebar**: collapses to 64px (favicon-only) via a drag handle on the right
  edge (double-click toggles); state persisted; content cross-fades.
- **Icon**: `somnia_icon.png` → `AppIcon.icns` (build.sh regenerates on change).

---

## Possible next steps

- A React/d3 graph instead of the canvas one (full d3 simulation, clusters).
- Drag-reorder tabs and move tabs between spaces.
- A full-screen notes graph + tag filter.
- Cross-restart `interactionState` for slept tabs (currently restored by URL).
- **Inline clickable `[[links]]` + `[[` autocomplete in the notes editor** —
  needs replacing `TextEditor` with an `NSTextView` wrapper (caret position /
  attributes); best done with a live GUI.
- **Read-write for the external Obsidian vault** — currently strictly read-only;
  enabling it needs careful UX warnings (it mutates the user's files).
- A PDFKit viewer (thumbnails / search / page count) instead of the built-in
  WKWebView PDF.
- Full Mozilla Readability instead of the compact extractor (weigh ~100 KB of JS
  against the "zero dependencies" goal).

---

## Conventions

- Every UI change = `./build.sh && open Somnia.app` (after `pkill`). A clean build
  means it applied.
- The GUI can't be checked from the CLI — verify by compiling and by inspecting the
  files under `~/Library/Application Support/Somnia/`.
- `BrowserState.current` / `Theme.current` are `static weak` so `TabNavDelegate`
  and the macOS menu can reach them without extra DI.
- Custom colors: `nil` overrides mean "use the preset 1:1"; any override derives
  the secondary tokens (`dim/faint/border/edge/node`) from Background/Panel/Text.
- Graph bridge: Swift → `evaluateJavaScript("setGraph(...)")`, web →
  `messageHandlers.somnia.postMessage({id})`.
