import SwiftUI
import WebKit
import AppKit

// MARK: - Navigation delegate (keeps the Tab model in sync)

final class TabNavDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var tab: Tab?
    weak var owner: BrowserState?
    private var observations: [NSKeyValueObservation] = []
    // URLs of the image / link under the cursor at the last right-click, captured
    // by the injected contextmenu script (see WebViewPool.contextCaptureJS).
    var lastContextImageURL: String?
    var lastContextLinkURL: String?
    init(tab: Tab) { self.tab = tab }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "somniaCtx", let body = message.body as? [String: Any] else { return }
        lastContextImageURL = body["img"] as? String
        lastContextLinkURL = body["link"] as? String
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab?.isLoading = true
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.isLoading = false
        if let t = webView.title, !t.isEmpty { tab?.title = t }
        tab?.url = webView.url
        let priv = tab?.isPrivate ?? false
        if !priv {
            HistoryStore.shared.record(url: webView.url, title: webView.title)
            fetchFavicon(webView)
            owner?.scheduleSave()   // persist updated title/url
        }
    }

    /// Read the page-declared favicon href (if any) and hand it to FaviconStore,
    /// which downloads + caches it. Falls back to /favicon.ico when none found.
    private func fetchFavicon(_ webView: WKWebView) {
        guard let pageURL = webView.url else { return }
        let js = "(function(){var ls=document.querySelectorAll('link[rel]');for(var i=0;i<ls.length;i++){var r=(ls[i].rel||'').toLowerCase();if(r.indexOf('icon')>=0)return ls[i].href;}return null;})()"
        webView.evaluateJavaScript(js) { result, _ in
            FaviconStore.shared.ensure(for: pageURL, iconHref: result as? String)
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab?.isLoading = false
        handleNavError(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab?.isLoading = false
        handleNavError(error)
    }

    /// When this window's proxy is on, map connection-ish NSURLError codes to a
    /// transient banner so the user knows the proxy (not the site) is at fault.
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

    // Cmd+click → open the link in a new BACKGROUND tab (stay on this page).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Links flagged for download (download attribute) → save to disk.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url {
            decisionHandler(.cancel)
            owner?.openInBackgroundTab(url)
            return
        }
        decisionHandler(.allow)
    }

    // Responses the web view can't render (zip, dmg, etc.) → download instead.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    // A navigation/response turned into a download → hand it to the coordinator.
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadCoordinator.begin(download)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadCoordinator.begin(download)
    }

    // target="_blank" / window.open → open in a new FOREGROUND tab.
    // WebKit only calls this when navigationAction.targetFrame == nil.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            owner?.openInNewTab(url, title: url.host ?? url.absoluteString)
        }
        return nil   // don't create a nested WKWebView
    }

    /// Observe url/title so SPA navigations (History API pushState — YouTube,
    /// etc.) that never fire didFinish still update the Tab and get persisted.
    func observe(_ webView: WKWebView) {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                guard let tab = self?.tab, let url = wv.url else { return }
                DispatchQueue.main.async {
                    tab.url = url
                    if !tab.isPrivate {
                        HistoryStore.shared.record(url: url, title: wv.title)
                        self?.owner?.scheduleSave()
                    }
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                guard let tab = self?.tab, let t = wv.title, !t.isEmpty else { return }
                DispatchQueue.main.async { tab.title = t }
            },
        ]
    }

    func invalidate() {
        observations.forEach { $0.invalidate() }
        observations = []
    }
}

// MARK: - WebView subclass with a reliable image/link save menu

/// WKWebView's built-in "Save Image to Downloads" doesn't route through our
/// download delegate and saves unreliably. We add our own menu items that go
/// through DownloadCoordinator (→ ~/Downloads, unique name, reveal in Finder).
final class TabWebView: WKWebView {
    weak var nav: TabNavDelegate?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        var idx = 0
        if let s = nav?.lastContextImageURL, let url = URL(string: s) {
            menu.insertItem(makeItem("Save Image", url), at: idx); idx += 1
        }
        if let s = nav?.lastContextLinkURL, let url = URL(string: s) {
            menu.insertItem(makeItem("Download Linked File", url), at: idx); idx += 1
        }
        if idx > 0 { menu.insertItem(.separator(), at: idx) }
    }

    private func makeItem(_ title: String, _ url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(saveContextURL(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        return item
    }

    @objc private func saveContextURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        startDownload(using: URLRequest(url: url)) { download in
            DownloadCoordinator.begin(download)
        }
    }
}

// MARK: - Downloads

/// Drives a single WKDownload to ~/Downloads. Retains itself in `active` for the
/// lifetime of the transfer (WKDownload.delegate is weak), then reveals the file.
final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    private static var active: [DownloadCoordinator] = []
    private var destination: URL?
    private let item = DownloadItem(filename: "download")

    static func begin(_ download: WKDownload) {
        let c = DownloadCoordinator()
        active.append(c)
        DownloadsModel.shared.add(c.item)
        download.delegate = c
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let fm = FileManager.default
        let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let dest = DownloadCoordinator.uniqueURL(in: dir, name: name)
        destination = dest
        DispatchQueue.main.async {
            self.item.filename = dest.lastPathComponent
            self.item.destination = dest
        }
        // Live progress → DownloadItem.fraction (drives the popover progress bar).
        item.progressObs = download.progress.observe(\.fractionCompleted) { [weak item] prog, _ in
            DispatchQueue.main.async { item?.fraction = prog.fractionCompleted }
        }
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        DispatchQueue.main.async {
            self.item.fraction = 1; self.item.done = true
            self.item.progressObs = nil
            DownloadsModel.shared.refreshActive()
        }
        if let dest = destination {
            NSWorkspace.shared.activateFileViewerSelecting([dest])   // reveal in Finder
        }
        finish()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DispatchQueue.main.async {
            self.item.failed = true
            self.item.progressObs = nil
            DownloadsModel.shared.refreshActive()
        }
        finish()
    }

    private func finish() {
        DownloadCoordinator.active.removeAll { $0 === self }
    }

    /// Append " 2", " 3", … before the extension to avoid clobbering existing files.
    private static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}

// MARK: - WebView pool
// One WKWebView per tab, created lazily and retained here. This is the seam
// where the "many tabs" optimisation will live (suspend / discard policy).

final class WebViewPool {
    static let shared = WebViewPool()
    /// Desktop Safari UA so sites (Google Images, etc.) serve their full pages.
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    private var views: [UUID: WKWebView] = [:]
    private var delegates: [UUID: TabNavDelegate] = [:]
    private var saved: [UUID: Any] = [:]   // interactionState of suspended tabs
    private var proxiedStore: WKWebsiteDataStore?

    /// The persistent WKWebsiteDataStore for a given profile kind. `.direct` is
    /// the standard default store; `.proxied` is one shared identified store
    /// (built lazily, cached) carrying the current proxyConfigurations so every
    /// proxied tab in every window shares cookies/cache and the same egress.
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
    /// Uses `teardown` (not `remove`) so the interactionState just stashed below
    /// isn't immediately wiped by `remove`'s own `saved[id] = nil`.
    func rebuild(_ tabID: UUID) {
        guard let wv = views[tabID] else { return }
        saved[tabID] = wv.interactionState
        teardown(tabID)   // KVO invalidate + delegate cleanup, without clearing `saved`
    }

    /// Records the image/link URL under the cursor on right-click so our custom
    /// "Save Image"/"Download Linked File" menu items know what to download.
    /// elementsFromPoint pierces overlays (Google Images stacks a div over <img>).
    static let contextCaptureJS = """
    (function(){
      document.addEventListener('contextmenu', function(e){
        var imgURL=null;
        var els=document.elementsFromPoint(e.clientX,e.clientY)||[];
        for (var i=0;i<els.length;i++){ if(els[i].tagName==='IMG'){ imgURL=els[i].currentSrc||els[i].src; break; } }
        if(!imgURL){ var im=e.target.closest&&e.target.closest('img'); if(im) imgURL=im.currentSrc||im.src; }
        var a=e.target.closest&&e.target.closest('a');
        var linkURL=a?a.href:null;
        try{ window.webkit.messageHandlers.somniaCtx.postMessage({img:imgURL,link:linkURL}); }catch(err){}
      }, true);
    })();
    """

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

    func webView(for tab: Tab, owner: BrowserState) -> WKWebView {
        if let v = views[tab.id] { return v }
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.preferences.isElementFullscreenEnabled = true
        // Private tabs get an ephemeral store (no cookies/cache written to disk).
        // Non-private tabs pick the direct or proxied persistent store per-window.
        if tab.isPrivate {
            cfg.websiteDataStore = .nonPersistent()
        } else {
            cfg.websiteDataStore = WebViewPool.shared.dataStore(for: dataStoreKind(proxyEnabled: owner.proxyEnabled))
        }
        let del = TabNavDelegate(tab: tab)
        del.owner = owner
        let ucc = cfg.userContentController
        ucc.add(del, name: "somniaCtx")
        ucc.addUserScript(WKUserScript(source: WebViewPool.contextCaptureJS,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if owner.proxyEnabled {
            ucc.addUserScript(WKUserScript(source: WebViewPool.webrtcBlockJS,
                                           injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        // Tracker/ad blocking: attach the compiled rule list if enabled.
        if Theme.current?.blockTrackers == true {
            if let list = ContentBlocker.shared.ruleList { ucc.add(list) }
            else { ContentBlocker.shared.prepare { list in if let list { ucc.add(list) } } }
        }
        let wv = TabWebView(frame: .zero, configuration: cfg)
        wv.nav = del
        wv.allowsBackForwardNavigationGestures = true
        // Full desktop Safari UA. WebKit's default UA omits the "Version/… Safari/…"
        // suffix, which makes Google (Images, etc.) serve a stripped-down page.
        wv.customUserAgent = WebViewPool.desktopUserAgent
        wv.navigationDelegate = del
        wv.uiDelegate = del
        del.observe(wv)
        delegates[tab.id] = del
        views[tab.id] = wv
        if let state = saved.removeValue(forKey: tab.id) {
            wv.interactionState = state          // restore history + scroll, no cold reload
        } else if let url = tab.url {
            if url.isFileURL {
                wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                wv.load(URLRequest(url: url))
            }
        }
        return wv
    }

    /// Async: true if the tab's live page has a non-paused <video>/<audio>.
    func isPlayingMedia(_ id: UUID, _ completion: @escaping (Bool) -> Void) {
        guard let wv = views[id] else { completion(false); return }
        let js = "Array.from(document.querySelectorAll('video,audio')).some(m=>!m.paused&&!m.ended&&m.currentTime>0)"
        wv.evaluateJavaScript(js) { result, _ in completion((result as? Bool) ?? false) }
    }

    /// Async: (hasMedia, playing) for the now-playing widget. hasMedia stays true
    /// for a paused track so the widget can keep its resume control.
    func mediaState(_ id: UUID, _ completion: @escaping (_ hasMedia: Bool, _ playing: Bool) -> Void) {
        guard let wv = views[id] else { completion(false, false); return }
        let js = """
        (function(){var m=Array.from(document.querySelectorAll('video,audio'));
        return JSON.stringify({has:m.some(x=>x.currentTime>0||!x.paused),
        playing:m.some(x=>!x.paused&&!x.ended&&x.currentTime>0)});})()
        """
        wv.evaluateJavaScript(js) { result, _ in
            guard let s = result as? String, let d = s.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                completion(false, false); return
            }
            completion((o["has"] as? Bool) ?? false, (o["playing"] as? Bool) ?? false)
        }
    }

    /// Pause or resume a tab's media (resume only restarts tracks already started,
    /// so it doesn't autoplay fresh elements).
    func setMediaPaused(_ id: UUID, _ paused: Bool) {
        guard let wv = views[id] else { return }
        let js = paused
            ? "document.querySelectorAll('video,audio').forEach(m=>m.pause());"
            : "document.querySelectorAll('video,audio').forEach(m=>{if(m.currentTime>0)m.play();});"
        wv.evaluateJavaScript(js)
    }

    /// Suspend a tab: free its WKWebView but remember session state to restore on wake.
    func sleep(_ id: UUID) {
        // Reader Mode tabs: their loadHTMLString document doesn't reconstruct from
        // interactionState on wake, so BrowserState caches the reader HTML and
        // re-loads it in wake() (see readerHTML). Regular pages restore normally.
        if let wv = views[id], let state = wv.interactionState { saved[id] = state }
        teardown(id)
    }

    /// Permanently drop a tab and forget its state.
    func remove(_ id: UUID) {
        saved[id] = nil
        teardown(id)
    }

    private func teardown(_ id: UUID) {
        if let wv = views[id] {
            wv.stopLoading()
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "somniaCtx")
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            wv.removeFromSuperview()
        }
        views[id] = nil
        delegates[id]?.invalidate()
        delegates[id] = nil
    }

    /// Add or remove the tracker blocklist on all live web views (called when the
    /// Customize toggle flips). Takes effect immediately for open pages on reload,
    /// and for subsequent requests.
    func applyContentRules(_ enabled: Bool) {
        for wv in views.values {
            let ucc = wv.configuration.userContentController
            if enabled { if let list = ContentBlocker.shared.ruleList { ucc.add(list) } }
            else { ucc.removeAllContentRuleLists() }
        }
    }

    /// Native in-page find (macOS 12+). Highlights + scrolls to the match.
    func find(_ id: UUID, _ text: String, forward: Bool, completion: @escaping (Bool) -> Void) {
        guard let wv = views[id] else { completion(false); return }
        let cfg = WKFindConfiguration()
        cfg.backwards = !forward
        cfg.caseSensitive = false
        cfg.wraps = true
        wv.find(text, configuration: cfg) { result in completion(result.matchFound) }
    }

    /// Drop the find selection/highlight when the find bar closes.
    func clearFind(_ id: UUID) {
        guard let wv = views[id] else { return }
        wv.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges();")
    }

    var liveIDs: Set<UUID> { Set(views.keys) }
    func has(_ id: UUID) -> Bool { views[id] != nil }
    var liveCount: Int { views.count }
}

// MARK: - Host view that swaps the active tab's WKWebView in place

final class WebHostView: NSView {
    private weak var current: WKWebView?
    func host(_ wv: WKWebView) {
        guard current !== wv else { return }
        current?.removeFromSuperview()
        wv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: topAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        current = wv
    }
}

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

// MARK: - Native blur (the fix for "blur the main background")

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}
