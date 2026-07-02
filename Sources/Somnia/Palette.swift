import SwiftUI

enum PaletteAction {
    case web(String)
    case openTab(Tab)
    case openNote(UUID)
    case openBookmark(Bookmark)
    case openURL(URL)
}

struct PaletteResult: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let subtitle: String
    let action: PaletteAction
}

struct CommandPalette: View {
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var history: HistoryStore
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        let p = theme.palette
        ZStack(alignment: .top) {
            Color.black.opacity(0.28).ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(p.faint)
                    TextField("Search the web or your notes…", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 16))
                        .focused($focused)
                        .onSubmit { runSelected() }
                        .onChange(of: query) { _, _ in selected = 0 }
                    Text("esc").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.faint)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(p.border))
                }
                .padding(.horizontal, 16).frame(height: 56)

                if !results.isEmpty {
                    Divider().overlay(p.border)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                                PaletteRow(result: r, active: i == selected)
                                    .onTapGesture { run(r) }
                                    .onHover { if $0 { selected = i } }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 360)
                }
            }
            .frame(width: 580)
            .background(ZStack {
                VisualEffect(material: .hudWindow, blending: .withinWindow)
                p.surface
            }.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(p.border))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 120)
        }
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow)   { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape)    { close(); return .handled }
    }

    private var results: [PaletteResult] {
        var out: [PaletteResult] = []
        let q = query.trimmingCharacters(in: .whitespaces)
        let ql = q.lowercased()

        if !q.isEmpty {
            let isURL = q.contains(".") && !q.contains(" ")
            out.append(PaletteResult(
                icon: isURL ? "globe" : "magnifyingglass",
                title: isURL ? "Open \(q)" : "Search the web: \(q)",
                subtitle: isURL ? "new tab" : "Google",
                action: .web(q)))
        }

        if let tabs = state.activeSpace?.tabs {
            for t in tabs where ql.isEmpty
                || t.title.lowercased().contains(ql)
                || (t.url?.absoluteString.lowercased().contains(ql) ?? false) {
                out.append(PaletteResult(icon: "rectangle.on.rectangle",
                                         title: t.title, subtitle: t.url?.host ?? "tab",
                                         action: .openTab(t)))
            }
        }

        for b in state.bookmarks where !ql.isEmpty
            && (b.title.lowercased().contains(ql) || b.url.lowercased().contains(ql)) {
            out.append(PaletteResult(icon: "bookmark.fill", title: b.title, subtitle: b.url,
                                     action: .openBookmark(b)))
        }

        // Recent history (skip URLs already surfaced as an open tab or bookmark).
        if !ql.isEmpty {
            let shown = Set(out.compactMap { r -> String? in
                if case .openTab(let t) = r.action { return t.url?.absoluteString }
                if case .openBookmark(let b) = r.action { return b.url }
                return nil
            })
            for h in history.search(ql, limit: 5) where !shown.contains(h.url) {
                if let u = URL(string: h.url) {
                    out.append(PaletteResult(icon: "clock.arrow.circlepath", title: h.title,
                                             subtitle: h.url, action: .openURL(u)))
                }
            }
        }

        let noteMatches = notes.notes.filter { n in
            ql.isEmpty || n.title.lowercased().contains(ql) || n.body.lowercased().contains(ql)
        }
        for n in noteMatches.prefix(6) {
            out.append(PaletteResult(icon: "doc.text",
                                     title: n.title.isEmpty ? "Untitled" : n.title,
                                     subtitle: "note", action: .openNote(n.id)))
        }
        return out
    }

    private func runSelected() {
        if results.indices.contains(selected) { run(results[selected]) }
        else if let f = results.first { run(f) }
    }

    private func run(_ r: PaletteResult) {
        close()
        switch r.action {
        case .web(let q):          state.search(q)
        case .openTab(let t):      state.select(t)
        case .openNote(let id):    state.notesOpen = true; notes.select(id)
        case .openBookmark(let b): state.openBookmark(b)
        case .openURL(let u):      state.openInNewTab(u, title: u.host ?? u.absoluteString)
        }
    }

    private func close() { state.paletteOpen = false }
}

struct PaletteRow: View {
    let result: PaletteResult
    let active: Bool
    @EnvironmentObject var theme: Theme
    var body: some View {
        let p = theme.palette
        HStack(spacing: 11) {
            Image(systemName: result.icon).font(.system(size: 13))
                .foregroundStyle(active ? theme.accent : p.dim).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).font(.system(size: 13.5)).foregroundStyle(p.text).lineLimit(1)
                Text(result.subtitle).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(p.faint).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(active ? theme.accent.opacity(0.14) : .clear))
        .contentShape(Rectangle())
    }
}
