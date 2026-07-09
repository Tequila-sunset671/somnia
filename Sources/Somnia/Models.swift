import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

final class Tab: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    @Published var url: URL?
    @Published var isLoading = false
    @Published var isAsleep = false        // suspended: no live WKWebView, will restore on wake
    @Published var isReader = false        // showing themed Reader Mode page
    var isPlayingMedia = false      // cached media-playing state for sleep policy
    @Published var letter: String
    @Published var tintHex: String
    let isPrivate: Bool             // ephemeral: no history, no disk cache, not persisted
    var tint: Color { Color(hex: tintHex) }
    var lastActive = Date.distantPast

    init(id: UUID = UUID(), title: String, url: URL? = nil, letter: String = "•",
         tintHex: String = "#888888", isPrivate: Bool = false) {
        self.id = id
        self.title = title
        self.url = url
        self.letter = letter
        self.tintHex = tintHex
        self.isPrivate = isPrivate
    }
}

final class Space: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var accentHex: String
    @Published var tabs: [Tab]

    init(id: UUID = UUID(), name: String, accentHex: String, tabs: [Tab]) {
        self.id = id
        self.name = name
        self.accentHex = accentHex
        self.tabs = tabs
    }
}

final class BrowserState: ObservableObject {
    @Published var spaces: [Space]
    @Published var activeSpaceID: UUID
    @Published var activeTabID: UUID?
    @Published var notesOpen = false
    @Published var notesInitialGraph = false   // open Notes panel directly on the Graph segment
    @Published var bookmarksSpaceActive = false   // showing the Bookmarks pseudo-space
    @Published var settingsOpen = false
    @Published var paletteOpen = false
    @Published var sidebarCollapsed = false { didSet { scheduleSave() } }
    @Published var bookmarks: [Bookmark] = []
    @Published var addressFocusPulse = 0    // bump to request address-bar focus (⌘L)

    // --- find on page (⌘F) ---
    @Published var findOpen = false
    @Published var findText = ""
    @Published var findFocusPulse = 0       // bump to focus the find field

    // --- tab-optimisation policy ---
    @Published var maxLiveTabs = 6          // budget of simultaneously loaded WKWebViews
    @Published var liveCount = 0            // for UI feedback
    let idleLimit: TimeInterval = 15 * 60   // suspend tabs idle longer than this (skips playing media)
    private var idleTimer: Timer?
    private var saveTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var readerSnapshots: [UUID: Any] = [:]   // pre-reader interactionState
    private var readerHTML: [UUID: String] = [:]     // generated reader doc, re-loaded on wake

    let isPrimary: Bool
    private static var primaryClaimed = false

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

    /// Tears down this window's resources: every tab's pooled WKWebView/delegate
    /// (same per-tab teardown `closeTab` uses), the idle sweep timer, the debounced
    /// save timer, and the memory-pressure source. Without this, closing a window
    /// via its red button (⌘W only closes a tab) leaks all of it into the
    /// process-wide `WebViewPool.shared` and leaves the repeating Timer/dispatch
    /// source alive on the run loop forever.
    deinit {
        let ids = allTabs.map { $0.id }
        let timer = idleTimer
        let saver = saveTimer
        let pressureSource = memoryPressureSource
        let teardown = {
            for id in ids { WebViewPool.shared.remove(id) }
            timer?.invalidate()
            saver?.invalidate()
            pressureSource?.cancel()
        }
        if Thread.isMainThread { teardown() } else { DispatchQueue.main.async(execute: teardown) }
    }

    var activeSpace: Space? { spaces.first { $0.id == activeSpaceID } }
    var activeTab: Tab? { activeSpace?.tabs.first { $0.id == activeTabID } }
    var allTabs: [Tab] { spaces.flatMap { $0.tabs } }

    // MARK: - Selection / navigation

    func select(_ tab: Tab) {
        bookmarksSpaceActive = false
        activeTabID = tab.id
        wake(tab)
        enforceBudget()
        refreshLiveCount()
        scheduleSave()
    }

    func newTab() {
        bookmarksSpaceActive = false
        guard let space = activeSpace else { return }
        let t = Tab(title: "New Tab", url: nil, letter: "+", tintHex: "#888888")
        space.tabs.append(t)
        space.objectWillChange.send()
        activeTabID = t.id
        t.lastActive = Date()
        objectWillChange.send()
        refreshLiveCount()
        scheduleSave()
    }

    /// Open a private tab: ephemeral WKWebView data store, no history, no disk
    /// favicon cache, excluded from the persisted session.
    func newPrivateTab() {
        bookmarksSpaceActive = false
        guard let space = activeSpace else { return }
        let t = Tab(title: "Private Tab", url: nil, letter: "P", tintHex: "#9b8aae", isPrivate: true)
        space.tabs.append(t)
        space.objectWillChange.send()
        activeTabID = t.id
        t.lastActive = Date()
        objectWillChange.send()
        refreshLiveCount()
        // Note: deliberately no scheduleSave() — private tabs aren't persisted.
    }

    func closeTab(_ tab: Tab) {
        bookmarksSpaceActive = false
        guard let space = activeSpace, let idx = space.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        space.tabs.remove(at: idx)
        WebViewPool.shared.remove(tab.id)
        readerSnapshots[tab.id] = nil
        readerHTML[tab.id] = nil
        if activeTabID == tab.id {
            activeTabID = space.tabs.first?.id
            if let a = activeTab { wake(a) }
        }
        space.objectWillChange.send()
        objectWillChange.send()
        refreshLiveCount()
        scheduleSave()
    }

    func go(_ text: String) {
        guard let tab = activeTab else { return }
        exitReaderState(tab)
        let url = BrowserState.resolve(text)
        tab.url = url
        tab.title = url.host ?? (url.isFileURL ? url.lastPathComponent : text)
        tab.lastActive = Date()
        tab.isAsleep = false
        let wv = WebViewPool.shared.webView(for: tab, owner: self)
        if url.isFileURL { wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { wv.load(URLRequest(url: url)) }
        objectWillChange.send()
        refreshLiveCount()
        scheduleSave()
    }

    func goBack()    { if let t = activeTab { exitReaderState(t); WebViewPool.shared.webView(for: t, owner: self).goBack() } }
    func goForward() { if let t = activeTab { exitReaderState(t); WebViewPool.shared.webView(for: t, owner: self).goForward() } }
    func reload()    { if let t = activeTab { exitReaderState(t); WebViewPool.shared.webView(for: t, owner: self).reload() } }

    func openNotesGraph() {
        settingsOpen = false
        notesInitialGraph = true
        notesOpen = true
    }

    func pulseAddressFocus() { addressFocusPulse &+= 1 }

    // MARK: - Find on page

    func openFind() {
        guard let t = activeTab, t.url != nil, !t.isReader, WebViewPool.shared.has(t.id) else { return }
        findOpen = true
        findFocusPulse &+= 1
        if !findText.isEmpty { findNext(true) }
    }

    func closeFind() {
        findOpen = false
        if let t = activeTab, WebViewPool.shared.has(t.id) { WebViewPool.shared.clearFind(t.id) }
    }

    func findNext(_ forward: Bool = true, _ completion: @escaping (Bool) -> Void = { _ in }) {
        guard let t = activeTab, WebViewPool.shared.has(t.id), !findText.isEmpty else { completion(false); return }
        WebViewPool.shared.find(t.id, findText, forward: forward, completion: completion)
    }

    /// Select the i-th tab (0-based) of the active space; clamps to last.
    func selectTabByIndex(_ i: Int) {
        guard let space = activeSpace, !space.tabs.isEmpty else { return }
        let idx = min(max(i, 0), space.tabs.count - 1)
        select(space.tabs[idx])
    }

    /// Move active selection by ±1 within the active space, wrapping.
    func cycleTab(_ delta: Int) {
        guard let space = activeSpace, !space.tabs.isEmpty,
              let cur = space.tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        let n = space.tabs.count
        let next = ((cur + delta) % n + n) % n
        select(space.tabs[next])
    }

    func closeActiveTab() {
        if let t = activeTab { closeTab(t) }
    }

    /// Reorder `dragged` to the position of `target` within the active space
    /// (drag-reorder in the sidebar). No-op if they're the same tab or not found.
    func moveTab(_ dragged: Tab, over target: Tab) {
        guard dragged.id != target.id, let space = activeSpace,
              let from = space.tabs.firstIndex(where: { $0.id == dragged.id }),
              let to = space.tabs.firstIndex(where: { $0.id == target.id }) else { return }
        space.tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        space.objectWillChange.send()
        objectWillChange.send()
        scheduleSave()
    }

    /// Reader Mode applies only to live web pages (not PDFs / home).
    var canRead: Bool {
        guard let t = activeTab, let u = t.url, !u.isFileURL else { return false }
        return WebViewPool.shared.has(t.id)
    }

    func toggleReader() {
        bookmarksSpaceActive = false
        guard let tab = activeTab, WebViewPool.shared.has(tab.id) else { return }
        let wv = WebViewPool.shared.webView(for: tab, owner: self)
        if tab.isReader {
            if let snap = readerSnapshots.removeValue(forKey: tab.id) { wv.interactionState = snap }
            readerHTML[tab.id] = nil
            tab.isReader = false
        } else {
            guard canRead, let theme = Theme.current else { return }
            readerSnapshots[tab.id] = wv.interactionState
            ReaderMode.enter(wv, theme: theme) { [weak self, weak tab] html in
                guard let tab else { return }
                self?.readerHTML[tab.id] = html
            }
            tab.isReader = true
        }
        objectWillChange.send()
    }

    /// Leave Reader Mode state for a tab without restoring (used when the tab
    /// navigates elsewhere, so the reader flag/snapshot don't go stale).
    private func exitReaderState(_ tab: Tab) {
        tab.isReader = false
        readerSnapshots[tab.id] = nil
        readerHTML[tab.id] = nil
    }

    // MARK: - Spaces

    private static let spacePalette = ["#9b8aae", "#7c9b8a", "#ae8a8a", "#8a9bae", "#aea98a", "#8aae9b"]

    func addSpace() {
        bookmarksSpaceActive = false
        let accent = BrowserState.spacePalette[spaces.count % BrowserState.spacePalette.count]
        let home = Tab(title: "New Tab", url: nil, letter: "+", tintHex: "#888888")
        let space = Space(name: "Space \(spaces.count + 1)", accentHex: accent, tabs: [home])
        spaces.append(space)
        activeSpaceID = space.id
        activeTabID = home.id
        objectWillChange.send()
        refreshLiveCount()
        scheduleSave()
    }

    func selectSpace(_ space: Space) {
        bookmarksSpaceActive = false
        guard space.id != activeSpaceID else { return }
        activeSpaceID = space.id
        activeTabID = space.tabs.first?.id
        if let a = activeTab { wake(a); enforceBudget() }
        objectWillChange.send()
        refreshLiveCount()
        scheduleSave()
    }

    func renameSpace(_ space: Space, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        space.name = trimmed
        space.objectWillChange.send()
        objectWillChange.send()
        scheduleSave()
    }

    func deleteSpace(_ space: Space) {
        guard spaces.count > 1, let idx = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        for t in space.tabs { WebViewPool.shared.remove(t.id); readerSnapshots[t.id] = nil; readerHTML[t.id] = nil }
        spaces.remove(at: idx)
        if activeSpaceID == space.id {
            let next = spaces[max(0, idx - 1)]
            activeSpaceID = next.id
            activeTabID = next.tabs.first?.id
            if let a = activeTab { wake(a) }
        }
        objectWillChange.send()
        refreshLiveCount()
        scheduleSave()
    }

    // MARK: - Bookmarks

    func isActiveBookmarked() -> Bool {
        guard let u = activeTab?.url?.absoluteString else { return false }
        return bookmarks.contains { $0.url == u }
    }

    func toggleBookmark() {
        guard let tab = activeTab, let u = tab.url?.absoluteString else { return }
        if let i = bookmarks.firstIndex(where: { $0.url == u }) {
            bookmarks.remove(at: i)
        } else {
            bookmarks.append(Bookmark(title: tab.title, url: u, letter: tab.letter, tintHex: tab.tintHex))
        }
        objectWillChange.send()
        scheduleSave()
    }

    func removeBookmark(_ b: Bookmark) {
        bookmarks.removeAll { $0.id == b.id }
        if bookmarks.isEmpty { bookmarksSpaceActive = false }
        objectWillChange.send()
        scheduleSave()
    }

    func openBookmark(_ b: Bookmark) {
        bookmarksSpaceActive = false
        guard let space = activeSpace, let url = URL(string: b.url) else { return }
        let t = Tab(title: b.title, url: url, letter: b.letter, tintHex: b.tintHex)
        space.tabs.append(t)
        space.objectWillChange.send()
        activeTabID = t.id
        wake(t)
        enforceBudget()
        objectWillChange.send()
        refreshLiveCount()
        scheduleSave()
    }

    func setBudget(_ n: Int) {
        maxLiveTabs = n
        enforceBudget()
        refreshLiveCount()
        scheduleSave()
    }

    // MARK: - Search / new tab

    func search(_ query: String) {
        let url = BrowserState.resolve(query)
        openInNewTab(url, title: url.host ?? query)
    }

    func openInNewTab(_ url: URL, title: String) {
        bookmarksSpaceActive = false
        guard let space = activeSpace else { return }
        let letter = String((title.first.map(String.init) ?? "•")).uppercased()
        let t = Tab(title: title, url: url, letter: letter, tintHex: "#9b8aae")
        space.tabs.append(t)
        space.objectWillChange.send()
        activeTabID = t.id
        wake(t)
        enforceBudget()
        objectWillChange.send()
        refreshLiveCount()
        scheduleSave()
    }

    /// Open a URL in a new tab WITHOUT switching to it (Cmd+click). The new tab
    /// stays asleep and loads lazily on first activation, so it doesn't consume
    /// the live-tab budget or fetch in the background.
    func openInBackgroundTab(_ url: URL) {
        guard let space = activeSpace else { return }
        let title = url.host ?? url.absoluteString
        let letter = String((title.first.map(String.init) ?? "•")).uppercased()
        let t = Tab(title: title, url: url, letter: letter, tintHex: "#9b8aae")
        t.isAsleep = true                 // lazy: created on first activation
        t.lastActive = Date()             // consistent with newTab (avoids instant LRU eviction on wake)
        space.tabs.append(t)
        space.objectWillChange.send()
        objectWillChange.send()
        refreshLiveCount()
        scheduleSave()
    }

    /// Open a local file (pdf/html) in a new tab.
    func openFile(_ url: URL) {
        bookmarksSpaceActive = false
        guard let space = activeSpace else { return }
        let name = url.lastPathComponent
        let t = Tab(title: name, url: url,
                    letter: String((name.first.map(String.init) ?? "•")).uppercased(),
                    tintHex: "#9b8aae")
        space.tabs.append(t)
        space.objectWillChange.send()
        activeTabID = t.id
        wake(t)
        enforceBudget()
        objectWillChange.send()
        refreshLiveCount()
        scheduleSave()
    }

    /// Show an NSOpenPanel for pdf/html and open the chosen file.
    func promptOpenFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .html]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { openFile(url) }
    }

    // MARK: - Lifecycle policy

    private func configureInitialSleep() {
        for t in allTabs { t.isAsleep = (t.url != nil) }   // everything starts unloaded…
        if let a = activeTab {                              // …except the active tab
            a.isAsleep = false
            a.lastActive = Date()
        }
        refreshLiveCount()
    }

    private func wake(_ tab: Tab) {
        tab.lastActive = Date()
        if tab.url != nil {
            let wv = WebViewPool.shared.webView(for: tab, owner: self)
            tab.isAsleep = false
            // Re-render Reader Mode on wake: a slept reader tab's loadHTMLString
            // state doesn't reconstruct from interactionState, so reload the doc.
            if tab.isReader, let html = readerHTML[tab.id] {
                wv.loadHTMLString(html, baseURL: tab.url)
            }
        }
    }

    private func enforceBudget() {
        let live = WebViewPool.shared.liveIDs
        guard live.count > maxLiveTabs else { return }
        let victims = allTabs
            .filter { live.contains($0.id) && $0.id != activeTabID }
            .sorted { a, b in
                if a.isPlayingMedia != b.isPlayingMedia { return !a.isPlayingMedia } // non-playing first
                return a.lastActive < b.lastActive                                    // then LRU
            }
        var overflow = live.count - maxLiveTabs
        for t in victims where overflow > 0 {
            WebViewPool.shared.sleep(t.id)
            t.isAsleep = true
            overflow -= 1
        }
    }

    @objc private func sweepIdle() {
        let now = Date()
        for t in allTabs where t.id != activeTabID && WebViewPool.shared.has(t.id) {
            let idle = now.timeIntervalSince(t.lastActive) > idleLimit
            WebViewPool.shared.isPlayingMedia(t.id) { [weak self] playing in
                guard let self else { return }
                t.isPlayingMedia = playing
                guard idle, !playing, t.id != self.activeTabID, WebViewPool.shared.has(t.id) else { return }
                WebViewPool.shared.sleep(t.id)
                t.isAsleep = true
                self.refreshLiveCount()
            }
        }
    }

    private func startIdleSweep() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sweepIdle()
        }
    }

    /// Watch for system memory pressure and give memory back proactively.
    private func startMemoryPressureMonitor() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in self?.handleMemoryPressure() }
        src.resume()
        memoryPressureSource = src
    }

    /// Under memory pressure, free background WKWebViews immediately — keep only
    /// the active tab and anything known to be playing media. Each slept tab
    /// releases a web content process, so Somnia shrinks when the Mac is tight.
    private func handleMemoryPressure() {
        var freed = false
        for t in allTabs where t.id != activeTabID && !t.isPlayingMedia && WebViewPool.shared.has(t.id) {
            WebViewPool.shared.sleep(t.id)
            t.isAsleep = true
            freed = true
        }
        if freed { refreshLiveCount() }
    }

    private func refreshLiveCount() { liveCount = WebViewPool.shared.liveCount }

    // MARK: - Persistence

    /// Debounced session save (called from navigation/title updates too).
    func scheduleSave() {
        guard isPrimary else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.saveSession()
        }
    }

    func saveSession() {
        guard isPrimary else { return }
        let snapshot = PersistedSession(
            spaces: spaces.map { s in
                PersistedSpace(id: s.id, name: s.name, accentHex: s.accentHex,
                               tabs: s.tabs.filter { !$0.isPrivate }.map { t in
                                   PersistedTab(id: t.id, title: t.title, url: t.url?.absoluteString,
                                                letter: t.letter, tintHex: t.tintHex)
                               })
            },
            activeSpaceID: activeSpaceID,
            activeTabID: activeTabID,
            maxLiveTabs: maxLiveTabs,
            bookmarks: bookmarks,
            sidebarCollapsed: sidebarCollapsed)
        Store.save(snapshot, to: "session.json")
    }

    // MARK: - URL resolution

    static func resolve(_ text: String) -> URL {
        let t = text.trimmingCharacters(in: .whitespaces)
        // Local files: explicit file:// scheme, or an absolute / home-relative path.
        // (Checked before the search heuristic so paths with spaces still open.)
        if t.hasPrefix("file://") {
            let raw = String(t.dropFirst(7))               // strip "file://"
            let path = raw.removingPercentEncoding ?? raw
            return URL(fileURLWithPath: path)
        }
        if t.hasPrefix("/") || t.hasPrefix("~") {
            return URL(fileURLWithPath: (t as NSString).expandingTildeInPath)
        }
        // Local dev servers: localhost:3000, 127.0.0.1:8080, foo.local — open over
        // http (they rarely have TLS), and before the search heuristic so a
        // port-only "localhost:3000" (no dot) isn't treated as a search query.
        if isLocalAddress(t) {
            if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t)! }
            if let u = URL(string: "http://\(t)") { return u }
        }
        if t.contains(" ") || !t.contains(".") {
            let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let prefix = (Theme.current?.searchEngine ?? .google).queryPrefix
            return URL(string: "\(prefix)\(q)") ?? URL(string: "\(SearchEngine.google.queryPrefix)\(q)")!
        }
        if t.hasPrefix("http") { return URL(string: t) ?? URL(string: "https://\(t)")! }
        return URL(string: "https://\(t)")!
    }

    /// True if the input addresses the local machine (loopback / *.local), so it
    /// should load over plain http. Strips any scheme, path and port first.
    private static func isLocalAddress(_ text: String) -> Bool {
        var probe = text
        if let r = probe.range(of: "://") { probe = String(probe[r.upperBound...]) }
        let hostPort = probe.split(separator: "/", maxSplits: 1).first.map(String.init) ?? probe
        let host = (hostPort.split(separator: ":").first.map(String.init) ?? hostPort).lowercased()
        return host == "localhost" || host == "0.0.0.0" || host == "::1"
            || host.hasPrefix("127.") || host.hasSuffix(".local")
    }
}
