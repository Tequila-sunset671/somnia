import SwiftUI
import AppKit
import WebKit

// MARK: - Search engine (configurable)

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, brave
    var id: String { rawValue }

    var label: String {
        switch self {
        case .google:     return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing:       return "Bing"
        case .brave:      return "Brave"
        }
    }

    /// URL prefix up to (and including) the query key; the percent-encoded query
    /// is appended directly. All four use a `q=` style parameter.
    var queryPrefix: String {
        switch self {
        case .google:     return "https://www.google.com/search?q="
        case .duckduckgo: return "https://duckduckgo.com/?q="
        case .bing:       return "https://www.bing.com/search?q="
        case .brave:      return "https://search.brave.com/search?q="
        }
    }
}

// MARK: - Content blocker (tracker/ad blocking via WKContentRuleList)

/// Compiles a small embedded blocklist into a native WKContentRuleList and
/// applies it to web views when enabled. Uses Apple's on-device content-blocker
/// engine (same as Safari), so blocking is fast and off the main thread.
final class ContentBlocker {
    static let shared = ContentBlocker()
    private(set) var ruleList: WKContentRuleList?
    private var compiling = false
    private var pending: [(WKContentRuleList?) -> Void] = []

    static let identifier = "somnia-blocklist-v1"

    /// Third-party trackers / ad networks. `url-filter` is a regex over the URL
    /// (a `\\.` in this Swift string is a literal `\.` = a literal dot in regex).
    private static let rulesJSON = """
    [
      {"trigger":{"url-filter":"doubleclick\\\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googlesyndication\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"google-analytics\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googletagmanager\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googletagservices\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"google\\\\.com/pagead"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"connect\\\\.facebook\\\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"facebook\\\\.com/tr"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"amazon-adsystem\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adnxs\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"criteo\\\\.(com|net)"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"taboola\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"outbrain\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"scorecardresearch\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"quantserve\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"hotjar\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"mixpanel\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"segment\\\\.(io|com)"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"moatads\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"doubleverify\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adservice\\\\.google\\\\."},"action":{"type":"block"}}
    ]
    """

    /// Compile once; `completion` fires with the (possibly cached) rule list.
    func prepare(_ completion: @escaping (WKContentRuleList?) -> Void = { _ in }) {
        if let ruleList { completion(ruleList); return }
        pending.append(completion)
        guard !compiling else { return }
        compiling = true
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.identifier, encodedContentRuleList: Self.rulesJSON
        ) { [weak self] list, error in
            guard let self else { return }
            self.compiling = false
            if let error { NSLog("Somnia: content blocker compile failed — \(error)") }
            self.ruleList = list
            let cbs = self.pending; self.pending = []
            cbs.forEach { $0(list) }
        }
    }
}

// MARK: - Browsing history (private, local, on disk)

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: String { url }        // url is the identity (deduped)
    var url: String
    var title: String
    var visitedAt: Date
}

/// Local visit log. Records http(s) navigations (never file:// or reader HTML),
/// deduped by URL (latest visit wins, moved to front), capped. Persisted to
/// `history.json` in Application Support. Feeds the command palette and the
/// address-bar autocomplete. Clearable from Customize.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
    private let cap = 3000
    private var saveTimer: Timer?

    init() {
        if let loaded = Store.load([HistoryEntry].self, from: "history.json") {
            entries = loaded
        }
    }

    /// Record a visit. No-ops for non-web schemes and blank/reader pages.
    func record(url: URL?, title: String?) {
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        let s = url.absoluteString
        guard !s.isEmpty else { return }
        let name = (title?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.host ?? s

        DispatchQueue.main.async {
            if let i = self.entries.firstIndex(where: { $0.url == s }) {
                self.entries.remove(at: i)
            }
            self.entries.insert(HistoryEntry(url: s, title: name, visitedAt: Date()), at: 0)
            if self.entries.count > self.cap { self.entries.removeLast(self.entries.count - self.cap) }
            self.scheduleSave()
        }
    }

    /// Most-recent-first matches on title or url. `limit` caps the result.
    func search(_ query: String, limit: Int = 6) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(entries.prefix(limit)) }
        var out: [HistoryEntry] = []
        for e in entries where e.title.lowercased().contains(q) || e.url.lowercased().contains(q) {
            out.append(e)
            if out.count >= limit { break }
        }
        return out
    }

    func clear() {
        entries = []
        Store.save(entries, to: "history.json")
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            Store.save(self.entries, to: "history.json")
        }
    }
}

// MARK: - Favicons (site-fetched, cached to disk — no third-party favicon service)

/// Per-host favicon cache. Downloads the site's own icon (parsed <link rel=icon>
/// href, or /favicon.ico fallback), stores a PNG in Application Support, and
/// keeps decoded NSImages in memory. Shared by tabs and bookmarks.
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    @Published private(set) var version = 0     // bump to nudge SwiftUI on new icons
    private var memory: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    private static let dir: URL = {
        let d = Store.dir.appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func fileURL(_ host: String) -> URL {
        Self.dir.appendingPathComponent(host.replacingOccurrences(of: ":", with: "_") + ".png")
    }

    /// Cached icon for a host, if we have one (memory → disk).
    func icon(forHost host: String?) -> NSImage? {
        guard let host, !host.isEmpty else { return nil }
        if let img = memory[host] { return img }
        let url = fileURL(host)
        if let img = NSImage(contentsOf: url) { memory[host] = img; return img }
        return nil
    }

    func icon(for pageURL: URL?) -> NSImage? { icon(forHost: pageURL?.host) }

    /// Ensure a favicon for the page is cached. `iconHref` is the page-declared
    /// icon URL (from JS); nil falls back to `<scheme>://<host>/favicon.ico`.
    func ensure(for pageURL: URL?, iconHref: String?) {
        guard let pageURL, let host = pageURL.host,
              let scheme = pageURL.scheme, scheme == "http" || scheme == "https" else { return }
        if memory[host] != nil || inFlight.contains(host) { return }
        if FileManager.default.fileExists(atPath: fileURL(host).path) { return }

        let candidate: URL? = {
            if let href = iconHref, let u = URL(string: href, relativeTo: pageURL) { return u.absoluteURL }
            var comps = URLComponents()
            comps.scheme = scheme; comps.host = host; comps.port = pageURL.port; comps.path = "/favicon.ico"
            return comps.url
        }()
        guard let iconURL = candidate else { return }
        inFlight.insert(host)

        var req = URLRequest(url: iconURL)
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.inFlight.remove(host) } }
            guard let data, !data.isEmpty,
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let img = NSImage(data: data), img.size.width > 0 else { return }
            // Normalize to a small PNG for cheap storage + crisp rendering.
            let png = Self.pngData(img, side: 32)
            try? png?.write(to: self.fileURL(host))
            DispatchQueue.main.async {
                self.memory[host] = img
                self.version &+= 1
            }
        }.resume()
    }

    private static func pngData(_ image: NSImage, side: CGFloat) -> Data? {
        let target = NSSize(width: side, height: side)
        let out = NSImage(size: target)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1)
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Downloads model (progress-tracked; drives the toolbar popover)

final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var filename: String
    @Published var fraction: Double = 0     // 0…1
    @Published var done = false
    @Published var failed = false
    var destination: URL?
    var progressObs: NSKeyValueObservation?

    init(filename: String) { self.filename = filename }
}

/// Observable list of downloads shown in the toolbar's downloads popover.
final class DownloadsModel: ObservableObject {
    static let shared = DownloadsModel()
    @Published private(set) var items: [DownloadItem] = []
    @Published var hasActive = false

    func add(_ item: DownloadItem) {
        DispatchQueue.main.async {
            self.items.insert(item, at: 0)
            self.refreshActive()
        }
    }

    func refreshActive() {
        hasActive = items.contains { !$0.done && !$0.failed }
    }

    func clearFinished() {
        items.removeAll { $0.done || $0.failed }
        refreshActive()
    }
}
