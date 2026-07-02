import SwiftUI
import WebKit

// MARK: - Note model (one markdown file with YAML-ish frontmatter)

final class Note: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    @Published var tags: [String]
    @Published var body: String
    let created: Date
    @Published var updated: Date

    init(id: UUID = UUID(), title: String, tags: [String] = [], body: String = "",
         created: Date = Date(), updated: Date = Date()) {
        self.id = id
        self.title = title
        self.tags = tags
        self.body = body
        self.created = created
        self.updated = updated
    }
}

enum VaultSource: String { case local, obsidian }
struct NotesConfig: Codable { var vaultPath: String?; var source: String }

// MARK: - Vault store

final class NotesStore: ObservableObject {
    @Published var notes: [Note] = []
    @Published var selectedID: UUID?

    @Published var source: VaultSource = .local
    @Published var vaultPath: String?            // external Obsidian vault (nil = not configured)
    var readOnly: Bool { source == .obsidian }

    private var currentDir: URL {
        if source == .obsidian, let p = vaultPath { return URL(fileURLWithPath: p) }
        return Store.vaultDir
    }

    private var saveTimers: [UUID: Timer] = [:]
    private static let iso = ISO8601DateFormatter()

    static var graphHTMLURL: URL { Store.dir.appendingPathComponent("graph.html") }

    init() {
        loadConfig()
        try? FileManager.default.createDirectory(at: Store.vaultDir, withIntermediateDirectories: true)
        ensureGraphHTML()
        reload()
    }

    func reload() {
        notes = []
        load()
        if notes.isEmpty && !readOnly { seed() }
        if !readOnly { dedupeTitles() }
        notes.sort { $0.updated > $1.updated }
        selectedID = notes.first?.id
        objectWillChange.send()
    }

    private func loadConfig() {
        if let c = Store.load(NotesConfig.self, from: "notes-config.json") {
            vaultPath = c.vaultPath
            source = VaultSource(rawValue: c.source) ?? .local
            if source == .obsidian, vaultPath == nil { source = .local }
        }
    }
    private func saveConfig() {
        Store.save(NotesConfig(vaultPath: vaultPath, source: source.rawValue), to: "notes-config.json")
    }

    /// Connect an external Obsidian vault (read-only) and switch to it.
    func connectVault(_ url: URL) {
        vaultPath = url.path
        source = .obsidian
        saveConfig()
        reload()
    }
    /// Forget the external vault and return to the internal local vault.
    func disconnectVault() {
        vaultPath = nil
        source = .local
        saveConfig()
        reload()
    }
    /// Switch between the configured sources (keeps `vaultPath`).
    func setSource(_ s: VaultSource) {
        guard s != source else { return }
        if s == .obsidian && vaultPath == nil { return }
        source = s
        saveConfig()
        reload()
    }

    var selected: Note? { notes.first { $0.id == selectedID } }

    func select(_ id: UUID) { selectedID = id }

    // MARK: CRUD

    @discardableResult
    func create(title: String = "Untitled") -> Note {
        let n = Note(title: uniqueTitle(title), body: "")
        notes.insert(n, at: 0)
        selectedID = n.id
        write(n)
        objectWillChange.send()
        return n
    }

    /// Open Notes with a brand-new blank document (empties are pruned first).
    func startFresh() {
        pruneEmpties()
        create()
    }

    // MARK: Duplicate-title protection

    /// Returns `base`, or `base 2`, `base 3`, … if the title is already taken.
    func uniqueTitle(_ base: String, excluding id: UUID? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let root = trimmed.isEmpty ? "Untitled" : trimmed
        func taken(_ t: String) -> Bool {
            notes.contains { $0.id != id && $0.title.caseInsensitiveCompare(t) == .orderedSame }
        }
        if !taken(root) { return root }
        var n = 2
        while taken("\(root) \(n)") { n += 1 }
        return "\(root) \(n)"
    }

    /// Enforce uniqueness for a note's current title (call on commit / blur).
    func dedupeTitle(_ note: Note) {
        guard !readOnly else { return }
        let fixed = uniqueTitle(note.title, excluding: note.id)
        if fixed != note.title { note.title = fixed; write(note); objectWillChange.send() }
    }

    private func dedupeTitles() {
        var seen = Set<String>()
        for n in notes {
            let key = n.title.lowercased()
            if seen.contains(key) {
                n.title = uniqueTitle(n.title, excluding: n.id)
                write(n)
            }
            seen.insert(n.title.lowercased())
        }
    }

    /// Remove blank "Untitled" notes (no title, no body) so quick-open doesn't accumulate clutter.
    func pruneEmpties() {
        guard !readOnly else { return }
        let empties = notes.filter {
            ($0.title.trimmingCharacters(in: .whitespaces).isEmpty || $0.title.hasPrefix("Untitled"))
            && $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !empties.isEmpty else { return }
        let ids = Set(empties.map { $0.id })
        for id in ids { cancelSave(id); try? FileManager.default.removeItem(at: fileURL(id)) }
        notes.removeAll { ids.contains($0.id) }
        if let sel = selectedID, ids.contains(sel) { selectedID = notes.first?.id }
        objectWillChange.send()
    }

    func delete(_ note: Note) {
        guard !readOnly else { return }
        cancelSave(note.id)
        try? FileManager.default.removeItem(at: fileURL(note.id))
        notes.removeAll { $0.id == note.id }
        if selectedID == note.id { selectedID = notes.first?.id }
        objectWillChange.send()
    }

    /// Debounced per-note save.
    func scheduleSave(_ note: Note) {
        guard !readOnly else { return }
        note.updated = Date()
        saveTimers[note.id]?.invalidate()
        saveTimers[note.id] = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self, weak note] _ in
            guard let self, let note else { return }
            self.write(note)
            self.objectWillChange.send()   // refresh links/backlinks/graph
        }
    }

    // MARK: Links / graph

    static func wikiLinks(in body: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: "\\[\\[([^\\]]+)\\]\\]") else { return [] }
        let ns = body as NSString
        let matches = rx.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>(), out: [String] = []
        for m in matches {
            let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let key = t.lowercased()
            if !t.isEmpty && !seen.contains(key) { seen.insert(key); out.append(t) }
        }
        return out
    }

    func resolve(_ title: String) -> Note? {
        notes.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    func outgoing(_ note: Note) -> [Note] {
        NotesStore.wikiLinks(in: note.body).compactMap { resolve($0) }.filter { $0.id != note.id }
    }

    func backlinks(_ note: Note) -> [Note] {
        notes.filter { other in
            other.id != note.id &&
            NotesStore.wikiLinks(in: other.body).contains { resolve($0)?.id == note.id }
        }
    }

    struct GNode: Encodable { let id: String; let title: String }
    struct GEdge: Encodable { let source: String; let target: String }
    struct GData: Encodable { let nodes: [GNode]; let edges: [GEdge] }

    func graphJSON() -> String {
        let nodes = notes.map { GNode(id: $0.id.uuidString, title: $0.title.isEmpty ? "Untitled" : $0.title) }
        var edges: [GEdge] = []
        for n in notes {
            for target in outgoing(n) {
                edges.append(GEdge(source: n.id.uuidString, target: target.id.uuidString))
            }
        }
        let data = GData(nodes: nodes, edges: edges)
        return (try? JSONEncoder().encode(data)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"nodes\":[],\"edges\":[]}"
    }

    // MARK: Persistence

    private func fileURL(_ id: UUID) -> URL { currentDir.appendingPathComponent("\(id.uuidString).md") }

    private func write(_ note: Note) {
        guard !readOnly else { return }
        let fm = """
        ---
        id: \(note.id.uuidString)
        title: \(note.title)
        tags: [\(note.tags.joined(separator: ", "))]
        created: \(NotesStore.iso.string(from: note.created))
        updated: \(NotesStore.iso.string(from: note.updated))
        ---
        \(note.body)
        """
        try? fm.write(to: fileURL(note.id), atomically: true, encoding: .utf8)
    }

    private func cancelSave(_ id: UUID) { saveTimers[id]?.invalidate(); saveTimers[id] = nil }

    private func load() {
        if source == .obsidian, let p = vaultPath {
            loadObsidian(URL(fileURLWithPath: p))
        } else {
            loadLocal()
        }
    }

    private func loadLocal() {
        let dir = Store.vaultDir
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "md" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fallback = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            notes.append(NotesStore.parse(content, fallbackID: fallback))
        }
    }

    /// Read-only recursive load of an Obsidian vault. Identity = filename (so
    /// [[wiki-links]] resolve); `.obsidian/` and other hidden dirs are skipped.
    private func loadObsidian(_ root: URL) {
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in en where url.pathExtension == "md" {
            let rel = url.path.hasPrefix(root.path + "/")
                ? String(url.path.dropFirst(root.path.count + 1)) : url.lastPathComponent
            let id = NotesStore.stableID(rel)
            let title = url.deletingPathExtension().lastPathComponent
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                // online-only iCloud placeholder: ask the system to download, skip this pass
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            let parsed = NotesStore.parse(content, fallbackID: id)
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            notes.append(Note(id: id, title: title, tags: parsed.tags, body: parsed.body, created: mod, updated: mod))
        }
    }

    /// Deterministic UUID from a string (FNV-1a ×2 → 16 bytes), so a vault file's
    /// graph-node id / selection stay stable across reloads. No crypto dependency.
    static func stableID(_ s: String) -> UUID {
        func fnv(_ bytes: [UInt8], _ seed: UInt64) -> UInt64 {
            var h = seed
            for b in bytes { h ^= UInt64(b); h = h &* 1099511628211 }
            return h
        }
        let bytes = Array(s.utf8)
        let a = fnv(bytes, 14695981039346656037).bigEndian
        let b = fnv(bytes, 1099511628211).bigEndian
        let x = withUnsafeBytes(of: a) { Array($0) }
        let y = withUnsafeBytes(of: b) { Array($0) }
        return UUID(uuid: (x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7],
                           y[0], y[1], y[2], y[3], y[4], y[5], y[6], y[7]))
    }

    private func seed() {
        let welcome = Note(title: "Welcome to Somnia", tags: ["intro"],
            body: "Это твой vault. Заметки связываются ссылками, как в Obsidian.\n\nПопробуй: [[Obsidian Graph]] и [[Spaces and Tabs]].")
        let graph = Note(title: "Obsidian Graph", tags: ["graph"],
            body: "Все заметки складываются в граф связей. Узлы можно тащить, клик открывает заметку.\n\nНазад: [[Welcome to Somnia]].")
        let spaces = Note(title: "Spaces and Tabs", tags: ["browser"],
            body: "Браузерная часть Somnia: спейсы, вкладки, закладки.\n\nСм. также [[Welcome to Somnia]].")
        notes = [welcome, graph, spaces]
        notes.forEach(write)
    }

    private static func parse(_ content: String, fallbackID: UUID) -> Note {
        var fm: [String: String] = [:]
        var body = content
        if content.hasPrefix("---") {
            let lines = content.components(separatedBy: "\n")
            var i = 1
            var fmLines: [String] = []
            while i < lines.count && lines[i] != "---" { fmLines.append(lines[i]); i += 1 }
            if i < lines.count {
                for l in fmLines {
                    if let r = l.range(of: ":") {
                        let k = String(l[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                        let v = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                        fm[k] = v
                    }
                }
                body = lines[(i + 1)...].joined(separator: "\n")
            }
        }
        let id = fm["id"].flatMap { UUID(uuidString: $0) } ?? fallbackID
        let title = unquote(fm["title"] ?? "Untitled")
        let tags = parseTags(fm["tags"] ?? "")
        let created = iso.date(from: fm["created"] ?? "") ?? Date()
        let updated = iso.date(from: fm["updated"] ?? "") ?? created
        return Note(id: id, title: title, tags: tags,
                    body: body.trimmingCharacters(in: .newlines),
                    created: created, updated: updated)
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, let l = t.last, f == l, f == "\"" || f == "'" {
            return String(t.dropFirst().dropLast())
        }
        return t
    }

    private static func parseTags(_ raw: String) -> [String] {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func ensureGraphHTML() {
        try? GraphWebView.graphHTML.write(to: NotesStore.graphHTMLURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Graph webview (the hybrid seam: native data → web render → native open)

struct GraphWebView: NSViewRepresentable {
    let json: String
    let accentHex: String
    let isDark: Bool
    var onOpen: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "somnia")
        cfg.userContentController = ucc
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")   // transparent → panel shows through
        context.coordinator.webView = wv
        wv.loadFileURL(NotesStore.graphHTMLURL, allowingReadAccessTo: Store.dir)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.latest = json
        context.coordinator.accent = accentHex
        context.coordinator.dark = isDark
        context.coordinator.push()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var loaded = false
        var latest = "{\"nodes\":[],\"edges\":[]}"
        var accent = "#9b8aae"
        var dark = true
        let onOpen: (UUID) -> Void
        init(onOpen: @escaping (UUID) -> Void) { self.onOpen = onOpen }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            push()
        }
        func push() {
            guard loaded, let wv = webView else { return }
            wv.evaluateJavaScript("setGraph(\(latest), {accent:'\(accent)', dark:\(dark)});")
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let dict = message.body as? [String: Any],
               let s = dict["id"] as? String, let id = UUID(uuidString: s) {
                onOpen(id)
            }
        }
    }

    static let graphHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <style>
      html,body{margin:0;height:100%;overflow:hidden;background:transparent;}
      #c{display:block;width:100%;height:100%;}
    </style></head><body><canvas id="c"></canvas><script>
    let nodes=[],edges=[],accent='#9b8aae',dark=true,dragging=null,moved=false;
    let scale=1,ox=0,oy=0,panning=false,lpx=0,lpy=0,running=false;
    const cv=document.getElementById('c'),ctx=cv.getContext('2d');let DPR=window.devicePixelRatio||1;
    // Restart the animation loop if it has parked itself. Called on any change
    // that needs a redraw (data, drag, pan, zoom, resize, tab visible again).
    function kick(){ if(!running&&!document.hidden){ running=true; requestAnimationFrame(step); } }
    function resize(){cv.width=innerWidth*DPR;cv.height=innerHeight*DPR;kick();}
    addEventListener('resize',resize);resize();
    addEventListener('visibilitychange',()=>{ if(!document.hidden) kick(); });
    function toWorld(x,y){return [(x-ox)/scale,(y-oy)/scale];}
    function setGraph(data,opts){
      if(opts){accent=opts.accent||accent;dark=!!opts.dark;}
      const old={};nodes.forEach(n=>old[n.id]=n);const byId={};
      nodes=(data.nodes||[]).map(n=>{const o=old[n.id];if(o){o.title=n.title;return o;}
        return {id:n.id,title:n.title,x:innerWidth/2+(Math.random()-.5)*220,y:innerHeight/2+(Math.random()-.5)*220,vx:0,vy:0};});
      nodes.forEach(n=>byId[n.id]=n);
      edges=(data.edges||[]).map(e=>({s:byId[e.source],t:byId[e.target]})).filter(e=>e.s&&e.t);
      kick();
    }
    window.setGraph=setGraph;
    function step(){
      // Parked while the panel/tab is hidden — no wasted frames in the background.
      if(document.hidden){ running=false; return; }
      let energy=0;
      for(let i=0;i<nodes.length;i++){const a=nodes[i];
        for(let j=i+1;j<nodes.length;j++){const b=nodes[j];let dx=a.x-b.x,dy=a.y-b.y,d2=dx*dx+dy*dy+.01,d=Math.sqrt(d2),f=2600/d2,fx=dx/d*f,fy=dy/d*f;a.vx+=fx;a.vy+=fy;b.vx-=fx;b.vy-=fy;}
        a.vx+=(innerWidth/2-a.x)*.0022;a.vy+=(innerHeight/2-a.y)*.0022;}
      edges.forEach(e=>{let dx=e.t.x-e.s.x,dy=e.t.y-e.s.y,d=Math.sqrt(dx*dx+dy*dy)||1,f=(d-92)*.012,fx=dx/d*f,fy=dy/d*f;e.s.vx+=fx;e.s.vy+=fy;e.t.vx-=fx;e.t.vy-=fy;});
      nodes.forEach(n=>{if(n===dragging)return;n.vx*=.86;n.vy*=.86;n.x+=n.vx;n.y+=n.vy;energy+=n.vx*n.vx+n.vy*n.vy;});
      draw();
      // Keep running while interacting or still visibly moving; otherwise park
      // the loop entirely (0% CPU) until the next kick().
      if(dragging||panning||energy>0.04){ requestAnimationFrame(step); } else { running=false; }
    }
    function draw(){
      ctx.setTransform(DPR,0,0,DPR,0,0);
      ctx.clearRect(0,0,innerWidth,innerHeight);
      ctx.setTransform(DPR*scale,0,0,DPR*scale,DPR*ox,DPR*oy);
      ctx.strokeStyle=dark?'rgba(255,255,255,.14)':'rgba(40,30,50,.16)';ctx.lineWidth=1/scale;
      edges.forEach(e=>{ctx.beginPath();ctx.moveTo(e.s.x,e.s.y);ctx.lineTo(e.t.x,e.t.y);ctx.stroke();});
      nodes.forEach(n=>{const deg=edges.filter(e=>e.s===n||e.t===n).length,r=6+Math.min(deg*1.6,9);
        ctx.beginPath();ctx.arc(n.x,n.y,r,0,7);ctx.fillStyle=accent;ctx.fill();
        ctx.fillStyle=dark?'rgba(232,226,242,.92)':'rgba(40,30,50,.9)';ctx.font='11px -apple-system,system-ui,sans-serif';ctx.textAlign='center';
        ctx.fillText(n.title,n.x,n.y+r+12);});
    }
    function at(wx,wy){let best=null,bd=400;nodes.forEach(n=>{let dx=n.x-wx,dy=n.y-wy,d=dx*dx+dy*dy;if(d<bd){bd=d;best=n;}});return best;}
    cv.addEventListener('mousedown',e=>{moved=false;const [wx,wy]=toWorld(e.clientX,e.clientY);dragging=at(wx,wy);if(!dragging){panning=true;lpx=e.clientX;lpy=e.clientY;}kick();});
    cv.addEventListener('mousemove',e=>{
      if(dragging){moved=true;const [wx,wy]=toWorld(e.clientX,e.clientY);dragging.x=wx;dragging.y=wy;dragging.vx=0;dragging.vy=0;}
      else if(panning){ox+=e.clientX-lpx;oy+=e.clientY-lpy;lpx=e.clientX;lpy=e.clientY;}
    });
    addEventListener('mouseup',()=>{if(dragging&&!moved&&window.webkit){window.webkit.messageHandlers.somnia.postMessage({id:dragging.id});}dragging=null;panning=false;kick();});
    cv.addEventListener('wheel',e=>{e.preventDefault();const f=Math.exp(-e.deltaY*0.0015);const ns=Math.min(3,Math.max(0.3,scale*f));const k=ns/scale;ox=e.clientX-(e.clientX-ox)*k;oy=e.clientY-(e.clientY-oy)*k;scale=ns;kick();},{passive:false});
    kick();
    </script></body></html>
    """
}
