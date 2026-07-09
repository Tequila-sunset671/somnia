# Multi-window + Per-window Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add multiple browser windows and a per-window SOCKS5/HTTP proxy (with WebRTC leak block and failure banner) to normal browsing.

**Architecture:** `BrowserState` becomes per-window (owned by `RootView`); menu commands route to the focused window via SwiftUI `@FocusedValue`, while nav-delegate callbacks route to the owning window via a `weak owner` link. A proxy is a globally-configured endpoint (`ProxyStore`/`proxy.json`) that each window toggles on/off, switching its tabs between a shared **direct** data store and a shared **proxied** data store (separate cookie jar) carrying `WKWebsiteDataStore.proxyConfigurations`.

**Tech Stack:** Swift 6, SwiftUI, AppKit, WebKit, Network framework (all system; zero external deps). Build: `./build.sh` (swiftc). Tests: `./test.sh` (custom harness in `tests/main.swift`).

## Global Constraints

- Target `arm64-apple-macosx14.0`; `LSMinimumSystemVersion` 14.0. `WKWebsiteDataStore.proxyConfigurations` and `WKWebsiteDataStore(forIdentifier:)` require macOS 14+.
- Zero external dependencies — only Apple system frameworks. `Network` must be added to the linker flags in `build.sh` and `test.sh`.
- All persisted data lives under `Store.dir` = `~/Library/Application Support/Somnia/`.
- Build gate: `./build.sh` must succeed (clean). Unit tests: `./test.sh` must print `✓ all N assertions passed`.
- GUI/lifecycle behavior is not unit-testable under this harness — verify those via clean build + the manual smoke steps in each task.
- Proxy behavior: route + WebRTC/STUN block only. **No fail-closed** — on proxy failure pages fail to load and a banner shows; traffic is never sent direct.
- Proxied browsing uses a **separate cookie jar** (not logged into direct-profile accounts). This is intended.
- Proxy types: **SOCKS5 and HTTP CONNECT**, optional username/password.
- Window persistence: **only the primary window** persists `session.json`; extra windows are ephemeral.

---

## File Structure

- **New** `Sources/Somnia/Proxy.swift` — `ProxyType`, `ProxyConfig`, `ProxyStore` (config + `proxy.json`), `DataStoreKind` + `dataStoreKind(proxyEnabled:)`, proxied-store identifier, `makeProxyConfiguration()`.
- **New** `Sources/Somnia/Focus.swift` — `FocusedValueKey` exposing the focused window's `BrowserState`.
- **Modify** `Sources/Somnia/App.swift` — remove app-level `BrowserState`; add `ProxyStore` to env; New Window (⌘N); menu commands read `@FocusedValue(\.browserState)`.
- **Modify** `Sources/Somnia/UI.swift` — `RootView` owns per-window `BrowserState` (`@StateObject`), publishes focused value, renders proxy banner; `ContentArea`/`WebArea` pass owner; `CustomizePanel` proxy section; `ToolbarView` proxy button; replace `BrowserState.current?` at `UI.swift:644`.
- **Modify** `Sources/Somnia/Models.swift` — `BrowserState`: `isPrimary`, `proxyEnabled`, `proxyBanner`, `setProxyEnabled`, per-window init; remove `static weak var current`; `owner: self` at `webView(for:)` call sites; persist `proxyEnabled`.
- **Modify** `Sources/Somnia/Web.swift` — `TabNavDelegate.owner` (weak); `webView(for:owner:)`; store selection; WebRTC-block user script; proxy-error → banner; `WebArea` passes owner.
- **Modify** `Sources/Somnia/Store.swift` — `PersistedSession.proxyEnabled: Bool?`.
- **Modify** `build.sh`, `test.sh` — add `-framework Network`.
- **Modify** `tests/main.swift` — proxy-model + store-selection assertions.

---

## Task 1: Multi-window foundation

Make `BrowserState` per-window, route menu commands to the focused window and nav-delegate callbacks to the owning window, and add New Window. This lands as one deliverable because removing `BrowserState.current` requires fixing every call site together (Swift won't compile partial states).

**Files:**
- Create: `Sources/Somnia/Focus.swift`
- Modify: `Sources/Somnia/App.swift` (whole `body`/`commands`)
- Modify: `Sources/Somnia/UI.swift` (`RootView`, `WebArea` owner, `UI.swift:644`)
- Modify: `Sources/Somnia/Models.swift:46` (remove `current`), `:75-117` (init), `:108` (drop `current =`), `:187,195,196,197,267,470` (owner), `:544` (guard save)
- Modify: `Sources/Somnia/Web.swift:266` (`webView(for:owner:)`), `:420-430` (`WebArea` owner), `:33,65,91,105-106` (`owner` instead of `current`)

**Interfaces:**
- Produces:
  - `BrowserState.init(primary: Bool)` — primary restores/persists session; secondary seeds one empty tab, never persists.
  - `BrowserState.isPrimary: Bool`
  - `WebViewPool.webView(for tab: Tab, owner: BrowserState) -> WKWebView`
  - `TabNavDelegate.owner: BrowserState?` (weak)
  - `FocusedValues.browserState: BrowserState?`

- [ ] **Step 1: Add the focused-value key**

Create `Sources/Somnia/Focus.swift`:

```swift
import SwiftUI

struct BrowserStateFocusedKey: FocusedValueKey {
    typealias Value = BrowserState
}

extension FocusedValues {
    var browserState: BrowserState? {
        get { self[BrowserStateFocusedKey.self] }
        set { self[BrowserStateFocusedKey.self] = newValue }
    }
}
```

- [ ] **Step 2: Make `BrowserState` per-window (primary vs secondary)**

In `Sources/Somnia/Models.swift`, remove line 46 (`static weak var current: BrowserState?`) and add stored properties near the other `@Published`s:

```swift
    let isPrimary: Bool
    private static var primaryClaimed = false
```

Replace `init()` (line 75) with:

```swift
    init(primary: Bool = true) {
        self.isPrimary = primary && !BrowserState.primaryClaimed
        if self.isPrimary { BrowserState.primaryClaimed = true }

        if self.isPrimary,
           let ps = Store.load(PersistedSession.self, from: "session.json"), !ps.spaces.isEmpty {
            let restored = ps.spaces.map { sp in
                Space(id: sp.id, name: sp.name, accentHex: sp.accentHex,
                      tabs: sp.tabs.map { t in
                          Tab(id: t.id, title: t.title,
                              url: t.url.flatMap { URL(string: $0) },
                              letter: t.letter, tintHex: t.tintHex)
                      })
            }
            self.spaces = restored
            self.activeSpaceID = ps.activeSpaceID ?? restored[0].id
            self.activeTabID = ps.activeTabID ?? restored.first?.tabs.first?.id
            self.maxLiveTabs = ps.maxLiveTabs
            self.bookmarks = ps.bookmarks ?? []
            self.sidebarCollapsed = ps.sidebarCollapsed ?? false
        } else if self.isPrimary {
            // Primary window, first-ever launch: keep the original eight demo tabs.
            let tabs = [
                Tab(title: "YouTube",     url: URL(string: "https://www.youtube.com"),       letter: "Y", tintHex: "#ff3b30"),
                Tab(title: "Google",      url: URL(string: "https://www.google.com"),        letter: "G", tintHex: "#4285f4"),
                Tab(title: "GitHub",      url: URL(string: "https://github.com"),            letter: "G", tintHex: "#7c8a9b"),
                Tab(title: "Wikipedia",   url: URL(string: "https://en.wikipedia.org"),      letter: "W", tintHex: "#888888"),
                Tab(title: "Hacker News", url: URL(string: "https://news.ycombinator.com"),  letter: "H", tintHex: "#ff6600"),
                Tab(title: "MDN",         url: URL(string: "https://developer.mozilla.org"), letter: "M", tintHex: "#83d0f2"),
                Tab(title: "Apple",       url: URL(string: "https://www.apple.com"),         letter: "A", tintHex: "#b0b0b0"),
                Tab(title: "Reddit",      url: URL(string: "https://www.reddit.com"),        letter: "R", tintHex: "#ff4500"),
            ]
            let space = Space(name: "Personal", accentHex: "#9b8aae", tabs: tabs)
            self.spaces = [space]
            self.activeSpaceID = space.id
            self.activeTabID = tabs.first?.id
        } else {
            // Secondary window: a single empty tab.
            let space = Space(name: "Personal", accentHex: "#9b8aae",
                              tabs: [Tab(title: "New Tab", url: nil, letter: "N", tintHex: "#9b8aae")])
            self.spaces = [space]
            self.activeSpaceID = space.id
            self.activeTabID = space.tabs.first?.id
        }

        configureInitialSleep()
        startIdleSweep()
        startMemoryPressureMonitor()
        if isPrimary {
            saveSession()
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                self?.saveSession()
            }
        }
    }
```

- [ ] **Step 3: Guard persistence to the primary window**

In `Sources/Somnia/Models.swift`, at the start of `scheduleSave()` (line 544) and `saveSession()`, add:

```swift
        guard isPrimary else { return }
```

- [ ] **Step 4: Thread `owner` through the WebView pool**

In `Sources/Somnia/Web.swift`, change the signature (line 266) to:

```swift
    func webView(for tab: Tab, owner: BrowserState) -> WKWebView {
```

Inside, after creating `del` (line 273), set the owner:

```swift
        let del = TabNavDelegate(tab: tab)
        del.owner = owner
```

Add to `TabNavDelegate` (near its stored properties):

```swift
    weak var owner: BrowserState?
```

Replace `BrowserState.current?` in `TabNavDelegate` (lines 33, 65, 91, 106) with `owner?`. Line 105-106 `HistoryStore.shared.record(...)` stays; only the `BrowserState.current?.scheduleSave()` becomes `owner?.scheduleSave()`.

- [ ] **Step 5: Update `webView(for:)` call sites**

In `Sources/Somnia/Models.swift`, at lines 187, 195, 196, 197, 267, 470, pass `owner: self`:

```swift
        let wv = WebViewPool.shared.webView(for: tab, owner: self)
```

(and the one-liners, e.g. `WebViewPool.shared.webView(for: t, owner: self).goBack()`).

In `Sources/Somnia/Web.swift`, `WebArea` (lines 420-430), add the owner from the environment and pass it:

```swift
struct WebArea: NSViewRepresentable {
    @ObservedObject var tab: Tab
    @EnvironmentObject var state: BrowserState
    func makeNSView(context: Context) -> WebHostView {
        let h = WebHostView()
        h.host(WebViewPool.shared.webView(for: tab, owner: state))
        return h
    }
    func updateNSView(_ nsView: WebHostView, context: Context) {
        nsView.host(WebViewPool.shared.webView(for: tab, owner: state))
    }
}
```

- [ ] **Step 6: Own `BrowserState` in `RootView`; publish focused value**

In `Sources/Somnia/UI.swift`, `RootView`: change its `@EnvironmentObject var state` to an owned `@StateObject` and inject it into the environment for children, and publish the focused value. The top of `RootView`:

```swift
struct RootView: View {
    @StateObject private var state = BrowserState()
    // ...existing @EnvironmentObject theme/notes/etc stay...
```

Wrap the existing body content so `state` is injected and focused:

```swift
        existingBody
            .environmentObject(state)
            .focusedValue(\.browserState, state)
```

Replace `BrowserState.current?.openFile(url)` at `UI.swift:644` with `state.openFile(url)`.

- [ ] **Step 7: App-level wiring + New Window + focused menu commands**

In `Sources/Somnia/App.swift`: remove `@StateObject private var state = BrowserState()` and its `.environmentObject(state)`. Keep `theme/notes/history/downloads/favicons`. Add the New Window command and switch every `BrowserState.current?` in `.commands` to a focused binding:

```swift
    @FocusedValue(\.browserState) var focusedState: BrowserState?
```

Then in `.commands`, replace `BrowserState.current?` with `focusedState?`, and add to the `.newItem` group:

```swift
                Button("New Window") { openWindow(id: "main") }
                    .keyboardShortcut("n", modifiers: .command)
```

Add `@Environment(\.openWindow) private var openWindow` to the `App` struct and give the `WindowGroup` an id: `WindowGroup(id: "main") { RootView()... }`. `RootView` no longer needs `.environmentObject(state)` from `App` (it owns `state`); App still injects `theme/notes/history/downloads/favicons`.

- [ ] **Step 8: Build**

Run: `./build.sh`
Expected: builds `Somnia.app` with no errors.

- [ ] **Step 9: Manual smoke**

Run: `open Somnia.app`. Verify:
- ⌘N opens a second window with its own single "New Tab".
- Typing a URL and ⌘T/⌘W act on the **focused** window only.
- Clicking a link with ⌘ opens a background tab in the **same** window it was clicked in.
- Quit and relaunch: only one window returns, restored from `session.json`.

- [ ] **Step 10: Run existing tests (no regressions)**

Run: `./test.sh`
Expected: `✓ all N assertions passed` (existing suite still green; `BrowserState()` default `primary: true`).

- [ ] **Step 11: Commit**

```bash
git add Sources/Somnia/Focus.swift Sources/Somnia/App.swift Sources/Somnia/UI.swift Sources/Somnia/Models.swift Sources/Somnia/Web.swift
git commit -m "feat: multi-window support with per-window BrowserState"
```

---

## Task 2: Proxy config model (`Proxy.swift`)

Pure, TDD-first: the config type, validation, data-store-kind decision, and the Network-framework proxy builder. No UI, no window state.

**Files:**
- Create: `Sources/Somnia/Proxy.swift`
- Modify: `build.sh`, `test.sh` (add `-framework Network`)
- Test: `tests/main.swift` (append a `do { }` block)

**Interfaces:**
- Produces:
  - `enum ProxyType: String, Codable, CaseIterable { case socks5, http }`
  - `struct ProxyConfig: Codable, Equatable { var type: ProxyType; var host: String; var port: Int; var username: String?; var password: String? }`
  - `final class ProxyStore: ObservableObject` — `static let shared`, `@Published var config: ProxyConfig?`, `var isConfigured: Bool`, `func makeProxyConfiguration() -> ProxyConfiguration?`, `func persist()`; persisted file `proxy.json`.
  - `static let ProxyStore.proxiedStoreID: UUID`
  - `enum DataStoreKind { case direct, proxied }`
  - `func dataStoreKind(proxyEnabled: Bool) -> DataStoreKind`

- [ ] **Step 1: Add `-framework Network` to both scripts**

In `build.sh`, change the swiftc link line to end with:

```
  -framework SwiftUI -framework AppKit -framework WebKit -framework Network
```

In `test.sh`, likewise:

```
  -framework SwiftUI -framework AppKit -framework WebKit -framework Network
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/main.swift` (before the `// MARK: Report` block):

```swift
// MARK: Proxy config
do {
    // validation
    let ok = ProxyConfig(type: .socks5, host: "127.0.0.1", port: 9050, username: nil, password: nil)
    check(ProxyStore.validate(ok), "proxy: valid socks5 config")
    check(!ProxyStore.validate(ProxyConfig(type: .http, host: "", port: 8080, username: nil, password: nil)), "proxy: empty host invalid")
    check(!ProxyStore.validate(ProxyConfig(type: .http, host: "h", port: 0, username: nil, password: nil)), "proxy: port 0 invalid")
    check(!ProxyStore.validate(ProxyConfig(type: .http, host: "h", port: 70000, username: nil, password: nil)), "proxy: port >65535 invalid")

    // Codable round-trip
    let data = try! JSONEncoder().encode(ok)
    let back = try! JSONDecoder().decode(ProxyConfig.self, from: data)
    eq(back, ok, "proxy: Codable round-trip")

    // type rawValue
    eq(ProxyType(rawValue: "http"), .http, "proxy: ProxyType rawValue")
    eq(ProxyType.allCases.count, 2, "proxy: two types")

    // data store kind
    if case .direct = dataStoreKind(proxyEnabled: false) {} else { check(false, "proxy: off → direct") }
    if case .proxied = dataStoreKind(proxyEnabled: true) {} else { check(false, "proxy: on → proxied") }

    // makeProxyConfiguration nil vs non-nil
    let store = ProxyStore()
    store.config = nil
    check(store.makeProxyConfiguration() == nil, "proxy: unconfigured → nil ProxyConfiguration")
    store.config = ok
    check(store.makeProxyConfiguration() != nil, "proxy: configured → non-nil ProxyConfiguration")
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `./test.sh`
Expected: FAIL to compile — `cannot find 'ProxyConfig' in scope`.

- [ ] **Step 4: Implement `Proxy.swift`**

Create `Sources/Somnia/Proxy.swift`:

```swift
import Foundation
import Network
import WebKit
import Combine

enum ProxyType: String, Codable, CaseIterable { case socks5, http }

struct ProxyConfig: Codable, Equatable {
    var type: ProxyType
    var host: String
    var port: Int
    var username: String?
    var password: String?
}

enum DataStoreKind { case direct, proxied }

func dataStoreKind(proxyEnabled: Bool) -> DataStoreKind {
    proxyEnabled ? .proxied : .direct
}

final class ProxyStore: ObservableObject {
    static let shared = ProxyStore()
    static let proxiedStoreID = UUID(uuidString: "5F0C1B2E-8A44-4E2A-9C3D-7A1B2C3D4E5F")!

    @Published var config: ProxyConfig? { didSet { persist() } }
    private var ready = false

    init() {
        config = Store.load(ProxyConfig.self, from: "proxy.json")
        ready = true
    }

    static func validate(_ c: ProxyConfig) -> Bool {
        !c.host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(c.port)
    }

    var isConfigured: Bool {
        if let c = config { return ProxyStore.validate(c) }
        return false
    }

    func persist() {
        guard ready else { return }
        if let c = config { Store.save(c, to: "proxy.json") }
    }

    func makeProxyConfiguration() -> ProxyConfiguration? {
        guard let c = config, ProxyStore.validate(c) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(c.host),
                                           port: NWEndpoint.Port(rawValue: UInt16(c.port))!)
        let cfg: ProxyConfiguration
        switch c.type {
        case .socks5: cfg = ProxyConfiguration(socksv5Proxy: endpoint)
        case .http:   cfg = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        }
        if let u = c.username, let p = c.password, !u.isEmpty {
            cfg.applyCredential(username: u, password: p)
        }
        return cfg
    }
}
```

> If the installed SDK spells the credential API differently, set the username/password via the `ProxyConfiguration` initializer's credential parameter instead; keep the nil-vs-non-nil contract identical.

- [ ] **Step 5: Run tests to verify they pass**

Run: `./test.sh`
Expected: `✓ all N assertions passed` (new proxy assertions included).

- [ ] **Step 6: Commit**

```bash
git add Sources/Somnia/Proxy.swift build.sh test.sh tests/main.swift
git commit -m "feat: proxy config model (ProxyStore, proxy.json)"
```

---

## Task 3: Two-profile data store + per-window proxy toggle

Wire `proxyEnabled` into `BrowserState`, select the data store per window in the pool, and rebuild a window's webviews (preserving history/scroll) when toggled.

**Files:**
- Modify: `Sources/Somnia/Models.swift` (`proxyEnabled`, `proxyBanner`, `setProxyEnabled`, persist)
- Modify: `Sources/Somnia/Web.swift:266+` (store selection in `webView(for:owner:)`, `rebuild`)
- Modify: `Sources/Somnia/Store.swift:36-43` (`PersistedSession.proxyEnabled`)

**Interfaces:**
- Consumes: `dataStoreKind(proxyEnabled:)`, `ProxyStore.shared`, `ProxyStore.proxiedStoreID` (Task 2); `webView(for:owner:)`, `isPrimary` (Task 1).
- Produces:
  - `BrowserState.proxyEnabled: Bool`, `BrowserState.proxyBanner: String?`
  - `BrowserState.setProxyEnabled(_ on: Bool)`
  - `WebViewPool.dataStore(for kind: DataStoreKind) -> WKWebsiteDataStore`
  - `WebViewPool.rebuild(_ tabID: UUID)`

- [ ] **Step 1: Add `proxyEnabled` to persisted session (backward compatible)**

In `Sources/Somnia/Store.swift`, add to `PersistedSession` (after `sidebarCollapsed`):

```swift
    var proxyEnabled: Bool?        // per-window proxy toggle (nil = off; only primary persists)
```

- [ ] **Step 2: Add proxy state to `BrowserState`**

In `Sources/Somnia/Models.swift`, add near the other `@Published`s:

```swift
    @Published var proxyEnabled = false
    @Published var proxyBanner: String?
```

In the primary-restore branch of `init`, restore it:

```swift
            self.proxyEnabled = ps.proxyEnabled ?? false
```

In `saveSession()`'s `PersistedSession(...)` snapshot (around line 552), add:

```swift
            proxyEnabled: proxyEnabled,
```

- [ ] **Step 3: Add store selection + rebuild to the pool**

In `Sources/Somnia/Web.swift`, add to `WebViewPool`:

```swift
    private var proxiedStore: WKWebsiteDataStore?

    func dataStore(for kind: DataStoreKind) -> WKWebsiteDataStore {
        switch kind {
        case .direct:
            return .default()
        case .proxied:
            let store = proxiedStore ?? WKWebsiteDataStore(forIdentifier: ProxyStore.proxiedStoreID)
            proxiedStore = store
            if let cfg = ProxyStore.shared.makeProxyConfiguration() {
                store.proxyConfigurations = [cfg]
            }
            return store
        }
    }

    /// Tear a webview down and rebuild it lazily against the current store,
    /// preserving history + scroll via interactionState (same as reader round-trip).
    func rebuild(_ tabID: UUID) {
        guard let wv = views[tabID] else { return }
        saved[tabID] = wv.interactionState
        remove(tabID)   // existing teardown: KVO invalidate, delegate cleanup
    }
```

In `webView(for:owner:)`, set the store on the configuration before building the webview (after the existing `if tab.isPrivate { ... }` line at 272):

```swift
        if tab.isPrivate {
            cfg.websiteDataStore = .nonPersistent()
        } else {
            cfg.websiteDataStore = WebViewPool.shared.dataStore(for: dataStoreKind(proxyEnabled: owner.proxyEnabled))
        }
```

- [ ] **Step 4: Implement the toggle**

In `Sources/Somnia/Models.swift`, add to `BrowserState`:

```swift
    func setProxyEnabled(_ on: Bool) {
        guard proxyEnabled != on else { return }
        proxyEnabled = on
        // Rebuild every live tab against the newly selected store.
        for t in allTabs where WebViewPool.shared.has(t.id) {
            WebViewPool.shared.rebuild(t.id)
            t.isAsleep = true
        }
        // Wake the active tab immediately (reloads through the new store).
        if let a = activeTab { wake(a) }
        objectWillChange.send()
        refreshLiveCount()
        scheduleSave()   // no-op unless primary
    }
```

- [ ] **Step 5: Build**

Run: `./build.sh`
Expected: builds cleanly.

- [ ] **Step 6: Run tests**

Run: `./test.sh`
Expected: `✓ all N assertions passed` (Task 2's proxy assertions still green; no new pure logic added here beyond what Task 2 covers).

- [ ] **Step 7: Manual smoke**

Start a local SOCKS5 proxy (e.g. `tor` on `127.0.0.1:9050`, or `ssh -D 1080`). With the app running, set the proxy via a temporary edit to `proxy.json` (UI comes in Task 6) or defer this smoke until after Task 6. Minimum check now: `open Somnia.app`, force `proxyEnabled` on a window by editing session and confirm active tab reloads and an IP-echo site (`https://ifconfig.me`) shows the proxy exit IP; a second window without proxy shows the real IP.

> If setting the flag manually is impractical, mark this step verified-after-Task-6 and rely on the build gate here.

- [ ] **Step 8: Commit**

```bash
git add Sources/Somnia/Models.swift Sources/Somnia/Web.swift Sources/Somnia/Store.swift
git commit -m "feat: per-window proxy toggle with direct/proxied data stores"
```

---

## Task 4: WebRTC / STUN leak block

Inject a document-start user script that neutralizes WebRTC APIs in proxied windows, so STUN can't reveal the real IP.

**Files:**
- Modify: `Sources/Somnia/Web.swift` (add `webrtcBlockJS`, inject conditionally in `webView(for:owner:)`)

**Interfaces:**
- Consumes: `owner.proxyEnabled` (Task 3).
- Produces: `WebViewPool.webrtcBlockJS: String` (static).

- [ ] **Step 1: Add the block script**

In `Sources/Somnia/Web.swift`, add a static string on `WebViewPool` (next to `contextCaptureJS`):

```swift
    static let webrtcBlockJS = """
    (function () {
      const block = function () { throw new Error('WebRTC disabled'); };
      try {
        Object.defineProperty(window, 'RTCPeerConnection', { value: block, writable: false });
        Object.defineProperty(window, 'webkitRTCPeerConnection', { value: block, writable: false });
        Object.defineProperty(window, 'RTCDataChannel', { value: block, writable: false });
      } catch (e) {}
    })();
    """
```

- [ ] **Step 2: Inject it for proxied windows**

In `webView(for:owner:)`, after the existing `ucc.addUserScript(...contextCaptureJS...)` block (around line 276):

```swift
        if owner.proxyEnabled {
            ucc.addUserScript(WKUserScript(source: WebViewPool.webrtcBlockJS,
                                           injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
```

- [ ] **Step 3: Build**

Run: `./build.sh`
Expected: builds cleanly.

- [ ] **Step 4: Manual smoke**

With a proxied window (after Task 6, or via manual flag), open `https://browserleaks.com/webrtc`. Expected: no real local/public IP is exposed (WebRTC reports disabled/blocked). A direct window is unaffected.

- [ ] **Step 5: Commit**

```bash
git add Sources/Somnia/Web.swift
git commit -m "feat: block WebRTC/STUN in proxied windows"
```

---

## Task 5: Proxy-failure banner

Detect proxy/connection navigation failures in proxied windows and surface a small transient banner.

**Files:**
- Modify: `Sources/Somnia/Web.swift` (`TabNavDelegate` failure handlers → `owner.showProxyBanner`)
- Modify: `Sources/Somnia/Models.swift` (`showProxyBanner`)
- Modify: `Sources/Somnia/UI.swift` (`RootView` banner overlay)

**Interfaces:**
- Consumes: `owner` (Task 1), `proxyEnabled`/`proxyBanner` (Task 3).
- Produces: `BrowserState.showProxyBanner(_ message: String)`.

- [ ] **Step 1: Add the banner trigger to `BrowserState`**

In `Sources/Somnia/Models.swift`:

```swift
    private var proxyBannerClear: DispatchWorkItem?
    func showProxyBanner(_ message: String) {
        proxyBanner = message
        proxyBannerClear?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.proxyBanner = nil }
        proxyBannerClear = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }
```

- [ ] **Step 2: Detect proxy errors in the nav delegate**

In `Sources/Somnia/Web.swift`, add to `TabNavDelegate` (implement both provisional and general failure callbacks; if one already exists, extend it):

```swift
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavError(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavError(error)
    }
    private func handleNavError(_ error: Error) {
        guard owner?.proxyEnabled == true else { return }
        let ns = error as NSError
        let proxyish: Set<Int> = [NSURLErrorCannotConnectToHost, NSURLErrorTimedOut,
                                  NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost,
                                  NSURLErrorNotConnectedToInternet]
        if ns.domain == NSURLErrorDomain && proxyish.contains(ns.code) {
            owner?.showProxyBanner("Proxy connection failed — pages may not load. Check proxy settings.")
        }
    }
```

- [ ] **Step 3: Render the banner in `RootView`**

In `Sources/Somnia/UI.swift`, add an overlay to `RootView`'s content (reads the owned `state`):

```swift
        .overlay(alignment: .top) {
            if let msg = state.proxyBanner {
                Text(msg)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.red.opacity(0.9), in: Capsule())
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { state.proxyBanner = nil }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.proxyBanner)
```

- [ ] **Step 4: Build**

Run: `./build.sh`
Expected: builds cleanly.

- [ ] **Step 5: Manual smoke**

Turn a window's proxy on, point it at a dead proxy endpoint (wrong port), navigate: the banner appears and auto-hides after ~4s; tapping it dismisses immediately; pages do not load (no direct fallback).

- [ ] **Step 6: Commit**

```bash
git add Sources/Somnia/Web.swift Sources/Somnia/Models.swift Sources/Somnia/UI.swift
git commit -m "feat: proxy failure banner"
```

---

## Task 6: Proxy UI — Customize section + toolbar toggle

Let the user configure the endpoint and toggle the current window's proxy from Customize and the top bar.

**Files:**
- Modify: `Sources/Somnia/App.swift` (inject `ProxyStore.shared` into env)
- Modify: `Sources/Somnia/UI.swift` (`CustomizePanel` proxy section, `ToolbarView` button)

**Interfaces:**
- Consumes: `ProxyStore.shared`, `ProxyConfig`, `ProxyType`, `isConfigured` (Task 2); `state.proxyEnabled`, `state.setProxyEnabled` (Task 3).

- [ ] **Step 1: Provide `ProxyStore` to the environment**

In `Sources/Somnia/App.swift`, add:

```swift
    @StateObject private var proxy = ProxyStore.shared
```

and `.environmentObject(proxy)` alongside the other injections on `RootView`.

- [ ] **Step 2: Add the Customize proxy section**

In `Sources/Somnia/UI.swift`, in `CustomizePanel`, add `@EnvironmentObject var proxy: ProxyStore` and `@EnvironmentObject var state: BrowserState`, and a section. Bind fields through a helper that mutates `proxy.config` (creating a default when nil):

```swift
    private func bindProxy() -> Binding<ProxyConfig> {
        Binding(
            get: { proxy.config ?? ProxyConfig(type: .socks5, host: "", port: 1080, username: nil, password: nil) },
            set: { proxy.config = $0 }
        )
    }
```

Section UI (place with the other Customize rows):

```swift
        let p = bindProxy()
        Picker("Type", selection: p.type) {
            Text("SOCKS5").tag(ProxyType.socks5)
            Text("HTTP").tag(ProxyType.http)
        }
        TextField("Host", text: p.host)
        TextField("Port", value: p.port, format: .number)
        TextField("Username (optional)", text: Binding(get: { p.username.wrappedValue ?? "" }, set: { p.username.wrappedValue = $0.isEmpty ? nil : $0 }))
        SecureField("Password (optional)", text: Binding(get: { p.password.wrappedValue ?? "" }, set: { p.password.wrappedValue = $0.isEmpty ? nil : $0 }))
        Toggle("Use proxy in this window", isOn: Binding(
            get: { state.proxyEnabled },
            set: { state.setProxyEnabled($0) }))
            .disabled(!proxy.isConfigured)
        if !proxy.isConfigured { Text("Enter a host and port to enable.").font(.caption).foregroundStyle(.secondary) }
```

- [ ] **Step 3: Add the toolbar toggle**

In `Sources/Somnia/UI.swift`, `ToolbarView`, add `@EnvironmentObject var proxy: ProxyStore` (state is already available) and a button:

```swift
        Button {
            state.setProxyEnabled(!state.proxyEnabled)
        } label: {
            Image(systemName: state.proxyEnabled ? "shield.lefthalf.filled" : "shield")
                .foregroundStyle(state.proxyEnabled ? Color.green : p.faint)
        }
        .buttonStyle(.plain)
        .disabled(!proxy.isConfigured)
        .help(proxy.isConfigured ? (state.proxyEnabled ? "Proxy on for this window" : "Proxy off") : "Configure a proxy in Customize")
```

(`p` here is the existing palette local in `ToolbarView`; match the file's existing pattern for palette access.)

- [ ] **Step 4: Build**

Run: `./build.sh`
Expected: builds cleanly.

- [ ] **Step 5: Manual smoke (full end-to-end)**

`open Somnia.app`:
- Customize → Proxy: enter `127.0.0.1` / `9050` / SOCKS5 (with `tor` running). Toggle "Use proxy in this window" — active tab reloads; `https://ifconfig.me` shows the Tor exit IP.
- Toolbar shield reflects on/off and toggles the same state.
- Open a second window (⌘N) without proxy — it shows the real IP; the two windows are independent.
- Toggle off — window returns to the direct profile (own cookies) and reloads.

- [ ] **Step 6: Run tests**

Run: `./test.sh`
Expected: `✓ all N assertions passed`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Somnia/App.swift Sources/Somnia/UI.swift
git commit -m "feat: proxy settings UI and toolbar toggle"
```

---

## Verification summary
- Unit-tested (via `./test.sh`): `ProxyConfig` Codable, `ProxyStore.validate`/`isConfigured`, `ProxyType` raw values, `dataStoreKind`, `makeProxyConfiguration` nil-vs-non-nil.
- Build-gated (`./build.sh`): all multi-window, store-selection, WebRTC, banner, and UI wiring.
- Manual smoke (GUI): two-window independence + focus routing (Task 1), exit-IP change (Tasks 3/6), WebRTC leak absence (Task 4), failure banner (Task 5), full end-to-end (Task 6).
