# Multi-window + per-window proxy — design

**Date:** 2026-07-09
**Status:** approved (design), pending implementation plan
**Scope:** Add multiple browser windows and a per-window SOCKS5/HTTP proxy to the
**normal** browsing experience (not tied to any incognito mode).

---

## 1. Goals & non-goals

**Goals**
- Support multiple app windows (currently a single `WindowGroup` instance shared
  across windows). Each window has its own tabs/spaces/active tab.
- Per-window proxy: a globally-configured SOCKS5/HTTP endpoint that each window
  can turn on/off independently, from Customize and from the top bar.
- When proxy is ON: route HTTP(S) through the proxy, block WebRTC/STUN IP leaks,
  and show a small transient banner if the proxy connection fails.

**Non-goals (v1)**
- No incognito/hardened window in this spec (separate future work).
- No fail-closed guarantee (on proxy failure pages simply fail to load; we only
  notify via banner — traffic is never silently sent direct).
- No restoring multiple windows on relaunch — only the main window persists;
  extra windows are ephemeral.
- No anti-fingerprinting JS spoofing (out of scope; see prior analysis).
- No bundled proxy/Tor — the user supplies the endpoint.

---

## 2. Key decisions

| Topic | Decision |
|---|---|
| Proxy scope | Endpoint configured globally; **per-window** on/off toggle |
| Toggle surfaces | Customize panel **and** top toolbar button (both act on current window) |
| Leak protection | Route + WebRTC/STUN block. **No** fail-closed |
| Proxy failure | Small transient banner over content |
| Proxy types | SOCKS5 and HTTP CONNECT, optional username/password |
| Window persistence | Main window only; extra windows ephemeral |
| Cookie model | Two profiles: **direct** (`.default()`) and **proxied** (identified store). Proxied browsing has a **separate cookie jar** — not logged into normal accounts. Accepted. |
| Min OS | macOS 14+ (already the project minimum; `proxyConfigurations` and `WKWebsiteDataStore(forIdentifier:)` require it) |

---

## 3. Multi-window architecture

### 3.1 State ownership
- **Per-window (moves to `RootView` as `@StateObject`):** `BrowserState` — tabs,
  spaces, active tab, sidebar state, budget, session persistence, and the new
  `proxyEnabled` flag.
- **App-global (stay at `App` level; already singletons):** `Theme`,
  `NotesStore`, `HistoryStore.shared`, `DownloadsModel.shared`,
  `FaviconStore.shared`, `WebViewPool.shared`, `ContentBlocker.shared`, and the
  new `ProxyStore.shared`. Windows share one vault, history, downloads, theme,
  and proxy config.

Rationale: `@StateObject` declared in the `App` struct is instantiated once and
shared across all windows of a `WindowGroup`. Moving `BrowserState`'s creation
into the per-window view (`RootView`) gives each window its own instance while
the rest stay legitimately global.

### 3.2 Removing `BrowserState.current` (static weak)
Two distinct routings replace the single global:

1. **Menu commands** (⌘T/W/R/F/L/K, ⌘1–9, back/forward, Customize, etc.) must
   target the **focused** window. Use SwiftUI `@FocusedValue`:
   - Define `BrowserStateFocusedKey: FocusedValueKey`.
   - `RootView` publishes its `BrowserState` via `.focusedValue(\.browserState, state)`.
   - `.commands` in `App.swift` read `@FocusedValue(\.browserState)` and call the
     focused state. (Alternative — a window registry keyed off `NSApp.keyWindow`
     — rejected as fragile and non-idiomatic.)
2. **Nav-delegate callbacks** (`TabNavDelegate` → `openInBackgroundTab`,
   `openInNewTab`, `scheduleSave`) must target the **owning** window, not the
   focused one. `TabNavDelegate` gains `weak var owner: BrowserState`, set at
   webview creation; call sites switch from `BrowserState.current?` to `owner?`.

`Theme.current` (static weak) **stays** — theme is genuinely app-wide and its one
use in `Web.swift` (`blockTrackers`) is global.

### 3.3 WebViewPool ownership
- `WebViewPool.shared` stays global, keyed by `tab.id` (UUID, unique across
  windows).
- `webView(for:)` becomes `webView(for tab: Tab, owner: BrowserState)`. The owner
  supplies: the nav-delegate `owner` link, and the data store / proxy state used
  to build the configuration (see §4).
- Budget/idle sweep is already computed per `BrowserState` over its own
  `allTabs`, so each window enforces its own budget through the shared pool. Total
  live tabs = sum across windows — acceptable for v1 (documented limitation).

### 3.4 New Window
- Add **New Window** command on **⌘N** (currently unbound; private tab is ⌘⇧N).
- Opens a fresh window: new `BrowserState` with one empty tab, `proxyEnabled =
  false`, using the direct store.

### 3.5 Persistence
- The main window persists `session.json` exactly as today (including its
  `proxyEnabled`). Extra windows do not persist and are not restored on relaunch.
- "Main window" = the first window created at launch / the one that owns the
  restored session. Implementation detail: a single `isPrimary` flag on
  `BrowserState`, assigned to the first window; only the primary calls
  `scheduleSave()`. (Extra windows keep their existing no-op-save behavior like
  private tabs already do.)

---

## 4. Proxy architecture

### 4.1 Config storage — `ProxyStore` + `proxy.json`
Following the existing `notes-config.json` precedent (separate small config file
rather than bloating `settings.json`/`Theme`):

- New file `Proxy.swift` with:
  - `struct ProxyConfig: Codable, Equatable` — `type: ProxyType` (`.socks5` /
    `.http`), `host: String`, `port: Int`, `username: String?`,
    `password: String?`.
  - `enum ProxyType: String, Codable { case socks5, http }`.
  - `final class ProxyStore: ObservableObject` (`.shared`) — `@Published var
    config: ProxyConfig?`, loaded/saved to `proxy.json` in `Store.dir`
    (`~/Library/Application Support/Somnia/`). Debounced save on edit.
  - `var isConfigured: Bool` — host non-empty and port in 1…65535.
  - `func makeProxyConfiguration() -> ProxyConfiguration?` — builds a Network
    framework `ProxyConfiguration`:
    - `.socks5` → `ProxyConfiguration(socksv5Proxy: NWEndpoint.hostPort(...))`
    - `.http` → `ProxyConfiguration(httpCONNECTProxy: NWEndpoint.hostPort(...), tlsOptions: nil)`
    - Attach `username`/`password` via the config's credential API when present.
    - Both variants resolve DNS at the proxy (no separate DNS-leak mitigation
      needed).

> Password is stored in `proxy.json` in plaintext for v1 (consistent with the
> app's other local-first JSON stores). Keychain storage is a future hardening
> item, noted in §8.

### 4.2 Two data-store profiles
- **Direct** (proxy OFF): `WKWebsiteDataStore.default()` — shared persistent
  store, so ordinary windows share cookies/logins (standard browser behavior).
- **Proxied** (proxy ON): one dedicated **persistent identified** store,
  `WKWebsiteDataStore(forIdentifier: <fixed UUID>)`, carrying
  `store.proxyConfigurations = [ProxyStore.shared.makeProxyConfiguration()]`.
  All windows with proxy ON share this single "proxied profile" (its own cookie
  jar, persists across sessions).
- Accepted consequence: proxied browsing is **not** logged into the direct
  profile's accounts and vice-versa.

### 4.3 Toggling proxy on a window
`BrowserState.setProxyEnabled(_ on: Bool)`:
1. Set `proxyEnabled`, `objectWillChange`.
2. For each of the window's tabs: save `interactionState`, tear down the existing
   `WKWebView` (it is bound to a store at creation), and rebuild lazily against
   the newly-selected store on next activation — restoring `interactionState`
   (history + scroll), the same round-trip pattern Reader Mode already uses.
   Active tab reloads immediately; sleeping tabs rebuild on wake.
3. If primary window, `scheduleSave()`.
- If `ProxyStore` is not configured, the toggle is disabled (see §5) and cannot
  be turned on.
- `makeProxyConfiguration()` is applied to the proxied store at build time; if the
  user edits the endpoint while a window is proxied, changing it re-applies on the
  next toggle/reload (v1: no live hot-swap while ON — documented).

### 4.4 WebRTC / STUN leak block
- When a webview is built for a **proxied** window, inject a `WKUserScript` at
  `.atDocumentStart`, `forMainFrameOnly: false`, that neutralizes
  `RTCPeerConnection`, `webkitRTCPeerConnection`, and `RTCDataChannel` (define
  them as throwing/no-op constructors). This prevents STUN candidate gathering
  from revealing the real IP behind the proxy.
- Not injected for direct windows.

### 4.5 Proxy-failure banner
- In `TabNavDelegate`, when the owning window has `proxyEnabled == true` and a
  navigation fails with a proxy/connection error (`didFailProvisionalNavigation`
  / `didFail` with `NSURLErrorDomain` codes such as
  `NSURLErrorCannotConnectToHost`, `NSURLErrorTimedOut`,
  `NSURLErrorCannotFindHost`, `kCFURLErrorCannotConnectToHost`), signal the owning
  `BrowserState` to show a transient banner.
- `BrowserState` exposes `@Published var proxyBanner: String?`. `RootView`
  renders a small dismissible banner overlay (auto-hides after ~4s) with a message
  like "Proxy connection failed — pages may not load. Check proxy settings."
- Traffic is **not** redirected to direct (no fail-closed) — the banner is
  notification only.

---

## 5. UI

### 5.1 Customize → Proxy section (`UI.swift`, `CustomizePanel`)
- Type dropdown: SOCKS5 / HTTP.
- Host (text), Port (number), Username (text, optional), Password (secure field,
  optional). Bound to `ProxyStore.shared.config`.
- "Use proxy in this window" toggle — bound to the current window's
  `BrowserState.proxyEnabled` (Customize is shown inside a window, so this is the
  per-window toggle). Disabled with a hint when `!ProxyStore.shared.isConfigured`.

### 5.2 Top toolbar button (`UI.swift`, `ToolbarView`)
- A proxy toggle button showing ON/OFF state (distinct icon/tint when active).
- Click toggles the current window's `proxyEnabled` (same action as the Customize
  toggle).
- Greyed out with a tooltip ("Configure a proxy in Customize") when not
  configured.

---

## 6. File-level change map
- `App.swift` — move `BrowserState` out of app-level `@StateObject`; keep other
  stores global; add `ProxyStore` to the environment; add New Window (⌘N);
  rewrite `.commands` to use `@FocusedValue(\.browserState)`.
- New `Focus.swift` (or a small addition in `App.swift`) — `FocusedValueKey` for
  `browserState`.
- `Models.swift` — `BrowserState`: per-window instantiation, `isPrimary`,
  `proxyEnabled`, `proxyBanner`, `setProxyEnabled`, owner links; remove `current`
  static; guard `scheduleSave` on `isPrimary`.
- `Web.swift` — `TabNavDelegate.owner` (weak); `webView(for:owner:)`; store
  selection (direct vs proxied); conditional WebRTC-block user script; proxy-error
  detection → `owner.proxyBanner`.
- New `Proxy.swift` — `ProxyConfig`, `ProxyType`, `ProxyStore`,
  `makeProxyConfiguration()` (imports `Network`).
- `Store.swift` — `proxy.json` load/save helpers (reuse existing `Store.load/save`
  generics; no schema change to `PersistedSession`/`PersistedSettings` beyond
  adding `proxyEnabled` to the primary window's session).
- `UI.swift` — `RootView` publishes focused value + renders banner; `CustomizePanel`
  Proxy section; `ToolbarView` proxy button.
- `RootView` also becomes the per-window `BrowserState` owner (`@StateObject`).

Zero external dependencies preserved — `Network` and `WebKit` are system
frameworks.

---

## 7. Testing & verification
- **Unit tests (`test.sh`, pure logic):**
  - `ProxyConfig` Codable round-trip.
  - `ProxyStore.isConfigured` validation (empty host, port bounds 1…65535).
  - `makeProxyConfiguration()` returns nil when unconfigured, correct type when
    configured (assert on type/host/port where introspectable).
  - Store-selection helper: given `proxyEnabled`, returns the expected store
    identity (direct vs proxied) — extract this as a pure function for testability.
- **Manual smoke (GUI, not unit-testable):**
  - Open two windows; verify independent tabs; ⌘T/⌘W act on the focused window.
  - Configure a local SOCKS5 (e.g. Tor `127.0.0.1:9050`), toggle proxy per window;
    confirm exit IP changes in one window and not the other (via an IP-echo site).
  - Toggle proxy → tabs reload, proxied window has a separate login state.
  - Stop the proxy → banner appears; pages fail to load (no direct fallback).
  - WebRTC leak test (e.g. browserleaks WebRTC) shows no real IP when proxied.
- **Build:** clean `./build.sh` is the compile gate (project not testable from
  CLI GUI-side).

---

## 8. Future hardening (out of scope for v1)
- Fail-closed enforcement (block all direct traffic if proxy is down).
- Keychain storage for proxy credentials instead of plaintext `proxy.json`.
- Restore multiple windows on relaunch (per-window session files).
- Live hot-swap of proxy endpoint without a toggle/reload.
- Move tabs between windows; drag a tab out to spawn a window.
- Incognito/hardened window building on this proxy + store infrastructure.
