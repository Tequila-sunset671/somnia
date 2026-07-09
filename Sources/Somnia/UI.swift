import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Small reusable controls

struct IconButton: View {
    let system: String
    var size: CGFloat = 16
    var active: Bool = false
    let action: () -> Void
    @EnvironmentObject var theme: Theme
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .medium))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(active || hover ? theme.palette.surface2 : .clear))
                .foregroundStyle(active ? theme.accent : theme.palette.dim)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Root layout

struct RootView: View {
    @StateObject private var state = BrowserState()
    @EnvironmentObject var theme: Theme
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let p = theme.palette
        ZStack {
            p.bg.ignoresSafeArea()
            if theme.direction == .aurora {
                AuroraGlow().ignoresSafeArea().allowsHitTesting(false)
            }

            HStack(spacing: theme.appGap) {
                SidebarView()
                MainArea()
            }
            .padding(theme.appGap)

            if state.notesOpen {
                HStack(spacing: 0) { Spacer(); NotesPanel() }
                    .padding(theme.appGap)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if state.settingsOpen {
                CustomizePanel().transition(.opacity)
            }
            if state.paletteOpen {
                CommandPalette().transition(.opacity).zIndex(10)
            }
        }
        .foregroundStyle(p.text)
        .animation(.easeOut(duration: 0.28), value: state.notesOpen)
        .animation(.easeOut(duration: 0.18), value: state.settingsOpen)
        .animation(.easeOut(duration: 0.15), value: state.paletteOpen)
        .overlay(alignment: .top) {
            if let msg = state.proxyBanner {
                Text(msg)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.red.opacity(0.9), in: Capsule())
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { state.dismissProxyBanner() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.proxyBanner)
        .environmentObject(state)
        .focusedValue(\.browserState, state)
        .onReceive(NotificationCenter.default.publisher(for: .somniaNewWindow)) { _ in
            if NewWindowCoordinator.claim() { openWindow(id: "main", value: UUID()) }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var notes: NotesStore
    @State private var dragDelta: CGFloat = 0
    @State private var handleHover = false
    private let collapsedW: CGFloat = 64

    func toggleNotes() {
        if state.notesOpen {
            state.notesOpen = false
        } else {
            if !notes.readOnly { notes.startFresh() }
            state.settingsOpen = false
            state.notesInitialGraph = false
            state.notesOpen = true
        }
    }

    var body: some View {
        let p = theme.palette
        let collapsed = state.sidebarCollapsed
        let base = collapsed ? collapsedW : theme.sideW
        let width = min(max(base + dragDelta, 56), 340)

        VStack(spacing: 0) {
            // top strip — symmetric with the bottom bar
            HStack(spacing: 6) {
                Spacer().frame(width: 52)   // room for traffic lights
                if !collapsed {
                    Spacer()
                    IconButton(system: "chevron.left")  { state.goBack() }
                    IconButton(system: "chevron.right") { state.goForward() }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)

            if !collapsed, let tab = state.activeTab {
                AddressBar(tab: tab).padding(.horizontal, 12).padding(.bottom, 10)
                    .transition(.opacity)
                    .zIndex(1)   // let the autocomplete dropdown float over the tab list
            }

            SpaceSwitcher()
            if !collapsed { SpaceHeader().transition(.opacity) }

            ScrollView {
                BookmarksSection()
                if let space = state.activeSpace { TabList(space: space) }
            }

            Spacer(minLength: 0)
            Divider().overlay(p.border)
            bottomBar(collapsed: collapsed)
        }
        .frame(width: width)
        .background(PanelBackground(radius: theme.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusPanel).strokeBorder(p.border))
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusPanel, style: .continuous))
        .overlay(alignment: .trailing) { resizeHandle(base: base) }
        .animation(.easeOut(duration: 0.22), value: state.sidebarCollapsed)
    }

    @ViewBuilder
    private func bottomBar(collapsed: Bool) -> some View {
        if collapsed {
            VStack(spacing: 4) {
                IconButton(system: "slider.horizontal.3", active: state.settingsOpen) { state.settingsOpen.toggle() }
                IconButton(system: "eye.slash") { state.newPrivateTab() }
                IconButton(system: state.isActiveBookmarked() ? "bookmark.fill" : "bookmark",
                           active: state.isActiveBookmarked()) { state.toggleBookmark() }
                IconButton(system: "pencil.line", active: state.notesOpen) { toggleNotes() }
            }
            .padding(.vertical, 7)
        } else {
            HStack {
                IconButton(system: "slider.horizontal.3", active: state.settingsOpen) { state.settingsOpen.toggle() }
                Spacer()
                IconButton(system: "eye.slash") { state.newPrivateTab() }
                    .help("New private tab (⌘⇧N)")
                IconButton(system: state.isActiveBookmarked() ? "bookmark.fill" : "bookmark",
                           active: state.isActiveBookmarked()) { state.toggleBookmark() }
                IconButton(system: "pencil.line", active: state.notesOpen) { toggleNotes() }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
    }

    private func resizeHandle(base: CGFloat) -> some View {
        let p = theme.palette
        return ZStack {
            Rectangle().fill(Color.clear)               // wide, invisible hit area
            Capsule()                                    // visible grip on hover / while dragging
                .fill(p.faint.opacity(handleHover || dragDelta != 0 ? 0.55 : 0))
                .frame(width: 3.5, height: 36)
                .animation(.easeOut(duration: 0.12), value: handleHover)
        }
        .frame(width: 22)                                // grab area: 10 → 22pt
        .contentShape(Rectangle())
        .onHover { inside in
            handleHover = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { dragDelta = $0.translation.width }
                .onEnded { v in
                    let final = base + v.translation.width
                    state.sidebarCollapsed = final < theme.sideW * 0.62
                    dragDelta = 0
                }
        )
        .onTapGesture(count: 2) { state.sidebarCollapsed.toggle() }
    }
}

struct SpaceSwitcher: View {
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    var body: some View {
        let collapsed = state.sidebarCollapsed
        HStack(spacing: collapsed ? 7 : 9) {
            if collapsed { Spacer(minLength: 0) }
            if !state.bookmarks.isEmpty {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(state.bookmarksSpaceActive ? theme.accent : theme.palette.faint)
                    .background(Circle().fill(theme.accent.opacity(state.bookmarksSpaceActive ? 0.16 : 0)).padding(-3))
                    .contentShape(Rectangle())
                    .onTapGesture { state.bookmarksSpaceActive = true }
                    .help("Bookmarks")
            }
            ForEach(state.spaces) { space in
                let active = space.id == state.activeSpaceID
                Circle()
                    .fill(Color(hex: space.accentHex))
                    .frame(width: active ? 11 : 9, height: active ? 11 : 9)
                    .overlay(
                        Circle().strokeBorder(theme.palette.text.opacity(active ? 0.45 : 0), lineWidth: 1.5)
                            .padding(-3)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { state.selectSpace(space) }
                    .help(space.name)
                    .contextMenu {
                        Button("New space") { state.addSpace() }
                        Divider()
                        Button("Delete “\(space.name)”", role: .destructive) { state.deleteSpace(space) }
                            .disabled(state.spaces.count <= 1)
                    }
            }
            if !collapsed {
                Button { state.addSpace() } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .foregroundStyle(theme.palette.faint)
                        .background(Circle().strokeBorder(theme.palette.border))
                }
                .buttonStyle(.plain)
                .help("New space")
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, collapsed ? 0 : 16).padding(.bottom, 8)
    }
}

struct SpaceHeader: View {
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        let p = theme.palette
        let space = state.activeSpace
        HStack(spacing: 8) {
            Circle().fill(Color(hex: space?.accentHex ?? "#9b8aae")).frame(width: 8, height: 8)
            if renaming, let space {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .focused($focused)
                    .onSubmit { commit(space) }
                    .onExitCommand { renaming = false }
            } else {
                Text(space?.name ?? "Space")
                    .font(.system(size: 12.5, weight: .semibold))
                    .onTapGesture(count: 2) { startRename(space) }
            }
            Spacer()
            Text("\(state.liveCount)/\(state.maxLiveTabs) live")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(theme.accent.opacity(0.16)))
                .foregroundStyle(theme.accent)
            Menu {
                Button("Rename") { startRename(space) }
                Button("New space") { state.addSpace() }
                Divider()
                Button("Delete space", role: .destructive) {
                    if let space { state.deleteSpace(space) }
                }
                .disabled(state.spaces.count <= 1)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(p.dim)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func startRename(_ space: Space?) {
        guard let space else { return }
        draft = space.name
        renaming = true
        DispatchQueue.main.async { focused = true }
    }
    private func commit(_ space: Space) {
        state.renameSpace(space, to: draft)
        renaming = false
    }
}

struct BookmarksSection: View {
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    var body: some View {
        if !state.bookmarks.isEmpty {
            VStack(spacing: theme.rowGap) {
                if !state.sidebarCollapsed {
                    HStack {
                        Text("BOOKMARKS").font(.system(size: 10, weight: .semibold)).tracking(1)
                            .foregroundStyle(theme.palette.faint)
                        Spacer()
                    }
                    .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 1)
                }
                ForEach(state.bookmarks) { b in BookmarkRow(b: b) }
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
            Divider().overlay(theme.palette.border).padding(.horizontal, 12).padding(.bottom, 4)
        }
    }
}

struct BookmarkRow: View {
    let b: Bookmark
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @State private var hover = false
    @ViewBuilder private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(hex: b.tintHex).opacity(0.18))
                .frame(width: 18, height: 18)
            Image(systemName: "bookmark.fill").font(.system(size: 8))
                .foregroundStyle(Color(hex: b.tintHex))
        }
    }

    var body: some View {
        let p = theme.palette
        Group {
            if state.sidebarCollapsed {
                icon
                    .frame(maxWidth: .infinity).frame(height: theme.tabH)
                    .background(RoundedRectangle(cornerRadius: 10).fill(hover ? p.surface2.opacity(0.6) : .clear))
                    .help(b.title)
                    .transition(.opacity)
            } else {
                HStack(spacing: 9) {
                    icon
                    Text(b.title).font(.system(size: theme.tabFont)).lineLimit(1)
                    Spacer(minLength: 0)
                    if hover {
                        Button { state.removeBookmark(b) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(p.faint)
                    }
                }
                .padding(.horizontal, 11).frame(height: theme.tabH)
                .background(RoundedRectangle(cornerRadius: 10).fill(hover ? p.surface2.opacity(0.6) : .clear))
                .foregroundStyle(p.dim)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { state.openBookmark(b) }
        .onHover { hover = $0 }
    }
}

struct AddrSuggestion: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let subtitle: String
    let value: String     // what to navigate to
}

struct AddressBar: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var history: HistoryStore
    @State private var text = ""
    @State private var suggestions: [AddrSuggestion] = []
    @FocusState private var focused: Bool
    var body: some View {
        let p = theme.palette
        HStack(spacing: 9) {
            Image(systemName: tab.url == nil ? "magnifyingglass" : "lock.fill")
                .font(.system(size: 10)).foregroundStyle(p.faint)
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(p.text)
                .focused($focused)
                .onSubmit { submit() }
            if tab.isLoading {
                ProgressView().controlSize(.mini)
            } else if tab.url != nil {
                Image(systemName: "arrow.clockwise").font(.system(size: 11)).foregroundStyle(p.faint)
                    .onTapGesture { state.reload() }
            }
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 11).fill(p.surface2))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(focused ? theme.accent.opacity(0.6) : p.border, lineWidth: focused ? 1.5 : 1))
        .overlay(alignment: .top) {
            if focused && !suggestions.isEmpty {
                suggestionList(p).offset(y: 44)
            }
        }
        .onAppear { text = display }
        .onChange(of: tab.id) { _, _ in text = display; suggestions = [] }
        .onChange(of: tab.url) { _, _ in if !focused { text = display } }
        .onChange(of: focused) { _, f in
            if !f { text = display; suggestions = [] } else { recompute() }
        }
        .onChange(of: text) { _, _ in recompute() }
        .onChange(of: state.addressFocusPulse) { _, _ in focused = true }
    }

    private var display: String { tab.url?.absoluteString ?? "" }

    private func submit() {
        let q = text.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { state.go(q) }
        suggestions = []
        focused = false
    }

    private func open(_ value: String) {
        state.go(value)
        suggestions = []
        focused = false
    }

    private func recompute() {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard focused, !q.isEmpty, q != display else { suggestions = []; return }
        let ql = q.lowercased()
        var seen = Set<String>()
        var out: [AddrSuggestion] = []
        for t in state.activeSpace?.tabs ?? [] {
            guard let u = t.url?.absoluteString, t.id != tab.id else { continue }
            if (t.title.lowercased().contains(ql) || u.lowercased().contains(ql)), seen.insert(u).inserted {
                out.append(AddrSuggestion(icon: "rectangle.on.rectangle", title: t.title, subtitle: u, value: u))
            }
        }
        for b in state.bookmarks where (b.title.lowercased().contains(ql) || b.url.lowercased().contains(ql)) {
            if seen.insert(b.url).inserted {
                out.append(AddrSuggestion(icon: "bookmark.fill", title: b.title, subtitle: b.url, value: b.url))
            }
        }
        for h in history.search(ql, limit: 8) where seen.insert(h.url).inserted {
            out.append(AddrSuggestion(icon: "clock.arrow.circlepath", title: h.title, subtitle: h.url, value: h.url))
        }
        suggestions = Array(out.prefix(6))
    }

    private func suggestionList(_ p: Palette) -> some View {
        VStack(spacing: 1) {
            ForEach(suggestions) { s in
                Button { open(s.value) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: s.icon).font(.system(size: 11)).foregroundStyle(p.dim).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.system(size: 12)).foregroundStyle(p.text).lineLimit(1)
                            Text(s.subtitle).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(p.faint).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.border))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
    }
}

struct TabList: View {
    @ObservedObject var space: Space
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @State private var dragging: Tab?
    var body: some View {
        LazyVStack(spacing: theme.rowGap) {
            ForEach(space.tabs) { tab in TabRow(tab: tab, dragging: $dragging) }
            Button { state.newTab() } label: {
                Group {
                    if state.sidebarCollapsed {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: theme.tabH)
                            .transition(.opacity)
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                            Text("New Tab").font(.system(size: theme.tabFont))
                            Spacer()
                        }
                        .padding(.horizontal, 11).frame(height: theme.tabH)
                        .transition(.opacity)
                    }
                }
                .foregroundStyle(theme.palette.dim)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.palette.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }
}

struct TabRow: View {
    @ObservedObject var tab: Tab
    @Binding var dragging: Tab?
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var favicons: FaviconStore
    @State private var hover = false
    @ViewBuilder
    private var favicon: some View {
        let p = theme.palette
        // Reference version so a freshly-downloaded icon re-renders the row.
        let icon = favicons.version >= 0 ? favicons.icon(for: tab.url) : nil
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(tab.tint.opacity(tab.isAsleep ? 0.10 : 0.18)).frame(width: 18, height: 18)
            if tab.isLoading {
                ProgressView().controlSize(.mini)
            } else if tab.isAsleep {
                Image(systemName: "moon.fill").font(.system(size: 8)).foregroundStyle(p.faint)
            } else if tab.isPrivate {
                Image(systemName: "eye.slash.fill").font(.system(size: 8.5)).foregroundStyle(theme.accent)
            } else if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Text(tab.letter).font(.system(size: 10, weight: .bold)).foregroundStyle(tab.tint)
            }
        }
    }

    var body: some View {
        let p = theme.palette
        let active = state.activeTabID == tab.id
        Group {
            if state.sidebarCollapsed {
                favicon
                    .frame(maxWidth: .infinity).frame(height: theme.tabH)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(active ? p.surface2 : (hover ? p.surface2.opacity(0.6) : .clear)))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(active ? theme.accent.opacity(0.6) : .clear, lineWidth: 1.5))
                    .help(tab.title)
                    .transition(.opacity)
            } else {
                HStack(spacing: 9) {
                    favicon
                    Text(tab.title).font(.system(size: theme.tabFont)).lineLimit(1)
                        .opacity(tab.isAsleep ? 0.55 : 1)
                    Spacer(minLength: 0)
                    if hover || active {
                        Button { state.closeTab(tab) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(p.faint)
                                .frame(width: 22, height: 22)        // larger hit target
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(hover ? p.surface2.opacity(0.8) : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Close tab")
                    }
                }
                .padding(.horizontal, 11).frame(height: theme.tabH)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(active ? p.surface2 : (hover ? p.surface2.opacity(0.6) : .clear)))
                .overlay(alignment: .leading) {
                    if active {
                        RoundedRectangle(cornerRadius: 2).fill(theme.accent)
                            .frame(width: 3, height: 16).padding(.leading, 2)
                    }
                }
                .foregroundStyle(active ? p.text : p.dim)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .opacity(dragging?.id == tab.id ? 0.45 : 1)
        .onTapGesture { state.select(tab) }
        .onHover { hover = $0 }
        .onDrag {
            dragging = tab
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, dragging: $dragging, state: state))
    }
}

/// Live drag-reorder of tabs within a space: reorders as the dragged row passes
/// over a target, commits (clears drag state) on drop.
struct TabDropDelegate: DropDelegate {
    let target: Tab
    @Binding var dragging: Tab?
    let state: BrowserState

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != target.id else { return }
        withAnimation(.easeInOut(duration: 0.18)) { state.moveTab(dragging, over: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

// MARK: - Main area (toolbar + content)

struct MainArea: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var state: BrowserState
    var body: some View {
        VStack(spacing: 0) {
            ToolbarView()
            Divider().overlay(theme.palette.border)
            ContentArea()
                .overlay(alignment: .topTrailing) {
                    if state.findOpen { FindBar().padding(12).transition(.opacity) }
                }
                .animation(.easeOut(duration: 0.14), value: state.findOpen)
        }
        .background(PanelBackground(radius: theme.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusPanel).strokeBorder(theme.palette.border))
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusPanel, style: .continuous))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    let ext = url.pathExtension.lowercased()
                    guard ["pdf", "html", "htm"].contains(ext) else { return }
                    DispatchQueue.main.async { state.openFile(url) }
                }
            }
            return true
        }
    }
}

/// Find-on-page bar (⌘F). Uses WKWebView's native find; ↑/↓ step matches.
struct FindBar: View {
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @FocusState private var focused: Bool
    @State private var noMatch = false
    var body: some View {
        let p = theme.palette
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(p.faint)
            TextField("Find on page", text: $state.findText)
                .textFieldStyle(.plain).font(.system(size: 12.5)).frame(width: 150)
                .foregroundStyle(noMatch ? .red : p.text)
                .focused($focused)
                .onSubmit { run(true) }
                .onChange(of: state.findText) { _, _ in run(true) }
            IconButton(system: "chevron.up", size: 11)   { run(false) }
            IconButton(system: "chevron.down", size: 11) { run(true) }
            IconButton(system: "xmark", size: 11)        { state.closeFind() }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow, blending: .withinWindow)
                p.surface
                Color.black.opacity(theme.isDark ? 0.22 : 0.07)   // darken a bit: readable over any page
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
        .onAppear { focused = true }
        .onChange(of: state.findFocusPulse) { _, _ in focused = true }
        .onExitCommand { state.closeFind() }
    }
    private func run(_ forward: Bool) {
        state.findNext(forward) { found in noMatch = !found && !state.findText.isEmpty }
    }
}

/// Live clock for the toolbar's empty left side.
struct ClockView: View {
    @EnvironmentObject var theme: Theme
    @State private var now = Date()
    // Only HH:MM is shown, so ticking every second is 60× wasted redraws — 10s
    // keeps the minute display effectively current at a fraction of the cost.
    private let tick = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    var body: some View {
        Text(now, format: .dateTime.hour().minute())
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(theme.palette.dim)
            .onReceive(tick) { now = $0 }
    }
}

/// "Now playing" widget: shows the tab currently playing audio/video with a
/// pause/resume toggle; clicking the title switches to that tab. Polls live tabs
/// every 2s and keeps a paused track visible so it can be resumed.
struct NowPlayingView: View {
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @State private var npTab: Tab?
    @State private var playing = false
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        let p = theme.palette
        Group {
            if let t = npTab {
                HStack(spacing: 7) {
                    Image(systemName: "music.note").font(.system(size: 10))
                        .foregroundStyle(playing ? theme.accent : p.faint)
                    Button { state.select(t) } label: {
                        Text(t.title).font(.system(size: 12)).lineLimit(1)
                            .frame(maxWidth: 160, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help(t.title)
                    Button {
                        WebViewPool.shared.setMediaPaused(t.id, playing)
                        playing.toggle()
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(p.dim)
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(p.surface2.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: npTab?.id)
        .onReceive(tick) { _ in scan() }
    }

    private func scan() {
        // Don't poll tabs while Somnia isn't visible (minimized / hidden / fully
        // covered): WebKit already throttles hidden pages, and this avoids running
        // JS across every live tab for a widget no one can see.
        guard NSApplication.shared.occlusionState.contains(.visible) else { return }
        let live = state.allTabs.filter { WebViewPool.shared.has($0.id) }
        guard !live.isEmpty else { if npTab != nil { npTab = nil; playing = false }; return }
        var foundPlaying: Tab?
        var keepPaused: Tab?
        let group = DispatchGroup()
        for t in live {
            group.enter()
            WebViewPool.shared.mediaState(t.id) { has, isPlaying in
                if isPlaying, foundPlaying == nil { foundPlaying = t }
                if has, t.id == npTab?.id { keepPaused = t }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if let pl = foundPlaying { npTab = pl; playing = true }
            else if let kp = keepPaused { npTab = kp; playing = false }
            else { npTab = nil; playing = false }
        }
    }
}

struct ToolbarView: View {
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var downloads: DownloadsModel
    @EnvironmentObject var proxy: ProxyStore
    @State private var copied = false
    @State private var downloadsOpen = false
    var body: some View {
        let p = theme.palette
        HStack(spacing: 12) {
            ClockView()
            NowPlayingView()
            Spacer()
            if !downloads.items.isEmpty {
                Button { downloadsOpen.toggle() } label: {
                    Image(systemName: downloads.hasActive ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 16, weight: .medium)).frame(width: 30, height: 30)
                        .foregroundStyle(downloads.hasActive ? theme.accent : p.dim)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $downloadsOpen, arrowEdge: .bottom) { DownloadsPopover() }
                .help("Downloads")
            }
            if state.activeTab?.url != nil {
                IconButton(system: copied ? "checkmark" : "doc.on.doc") {
                    if let u = state.activeTab?.url?.absoluteString {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(u, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
                    }
                }
                .help("Copy URL")
            }
            if state.activeTab?.url != nil {
                IconButton(system: state.isActiveBookmarked() ? "bookmark.fill" : "bookmark",
                           active: state.isActiveBookmarked()) {
                    state.toggleBookmark()
                }
            }
            if state.canRead || state.activeTab?.isReader == true {
                IconButton(system: "doc.plaintext",
                           active: state.activeTab?.isReader == true) {
                    state.toggleReader()
                }
            }
            IconButton(system: theme.isDark ? "sun.max" : "moon") {
                theme.appearance = theme.isDark ? .light : .dark
            }
            Button {
                state.setProxyEnabled(!state.proxyEnabled)
            } label: {
                Image(systemName: state.proxyEnabled ? "shield.lefthalf.filled" : "shield")
                    .font(.system(size: 16, weight: .medium)).frame(width: 30, height: 30)
                    .foregroundStyle(state.proxyEnabled ? Color.green : p.faint)
            }
            .buttonStyle(.plain)
            .disabled(!proxy.isConfigured)
            .help(proxy.isConfigured ? (state.proxyEnabled ? "Proxy on for this window" : "Proxy off") : "Configure a proxy in Customize")
            Button {
                if state.notesOpen { state.notesOpen = false }
                else { notes.startFresh(); state.settingsOpen = false; state.notesOpen = true }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "pencil.line")
                    Text("Notes").font(.system(size: 12.5))
                }
                .padding(.horizontal, 12).frame(height: 32)
                .foregroundStyle(state.notesOpen ? theme.accent : p.dim)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(p.border))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).frame(height: 40)
    }
}

struct DownloadsPopover: View {
    @EnvironmentObject var downloads: DownloadsModel
    @EnvironmentObject var theme: Theme
    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button("Clear") { downloads.clearFinished() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(theme.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider().overlay(p.border)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(downloads.items) { item in DownloadRow(item: item) }
                }
                .padding(8)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 320)
        .background(p.surface)
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject var theme: Theme
    var body: some View {
        let p = theme.palette
        HStack(spacing: 10) {
            Image(systemName: item.failed ? "exclamationmark.triangle"
                    : item.done ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.system(size: 14))
                .foregroundStyle(item.failed ? .red : item.done ? theme.accent : p.dim)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).font(.system(size: 12.5)).lineLimit(1).foregroundStyle(p.text)
                if !item.done && !item.failed {
                    ProgressView(value: item.fraction).tint(theme.accent).controlSize(.small)
                } else {
                    Text(item.failed ? "Failed" : "Completed")
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.faint)
                }
            }
            Spacer(minLength: 0)
            if item.done, let dest = item.destination {
                Button { NSWorkspace.shared.activateFileViewerSelecting([dest]) } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(p.faint).help("Show in Finder")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.surface2.opacity(0.5)))
    }
}

struct ContentArea: View {
    @EnvironmentObject var state: BrowserState
    var body: some View {
        Group {
            if state.bookmarksSpaceActive {
                BookmarksPage()
            } else if let tab = state.activeTab, tab.url != nil {
                WebArea(tab: tab)
            } else {
                HomeView()
            }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var notes: NotesStore
    @State private var query = ""
    @State private var now = Date()
    @State private var bgImage: NSImage?
    @State private var bgImagePath: String?
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let p = theme.palette
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            clockBlock(p)
            searchBlock(p)
            graphBlock(p)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        // Background image must NOT drive layout: as a .background it is sized to
        // the content (which fills the window) and clipped — the window drives the
        // image size, not the other way around.
        .background(backgroundLayer(p))
        .onReceive(clock) { now = $0 }
        .onAppear { loadBackground() }
        .onChange(of: theme.homeBgImage) { _ in loadBackground() }
    }

    @ViewBuilder private func backgroundLayer(_ p: Palette) -> some View {
        if let img = bgImage {
            ZStack {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                p.bg.opacity(0.30)   // light auto-scrim: keep clock/search/graph readable
            }
            .clipped()
        }
    }

    /// Load the background NSImage from disk once per filename (HomeView
    /// re-renders every second from the clock — don't re-read the file each tick).
    private func loadBackground() {
        if let url = theme.homeBackgroundURL {
            if bgImagePath != theme.homeBgImage {
                bgImage = NSImage(contentsOf: url)
                bgImagePath = theme.homeBgImage
            }
        } else {
            bgImage = nil
            bgImagePath = nil
        }
    }

    private func clockBlock(_ p: Palette) -> some View {
        VStack(spacing: 2) {
            Text(now, format: .dateTime.hour().minute().second())
                .font(.system(size: 44, weight: .thin, design: .rounded)).tracking(1)
            Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 13)).foregroundStyle(p.dim)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22)
        .background(PanelBackground(radius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(p.border))
    }

    private func searchBlock(_ p: Palette) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(p.faint)
            TextField("Search the web or your notes…", text: $query)
                .textFieldStyle(.plain).font(.system(size: 15))
                .onSubmit { if !query.isEmpty { state.go(query); query = "" } }
            Text("⌘K").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.faint)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
        }
        .padding(.horizontal, 16).frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 14).fill(p.surface2))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(p.border))
    }

    private func graphBlock(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("NOTES GRAPH").font(.system(size: 10, weight: .semibold)).tracking(1)
                    .foregroundStyle(p.faint)
                Spacer()
                Button { state.openNotesGraph() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11))
                        .foregroundStyle(p.dim)
                }
                .buttonStyle(.plain).help("Expand graph")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            GraphWebView(json: notes.graphJSON(), accentHex: theme.accentHex, isDark: theme.isDark) { id in
                notes.select(id)
                state.settingsOpen = false
                state.notesOpen = true
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .background(PanelBackground(radius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(p.border))
    }
}

struct BookmarksPage: View {
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    private let cols = [GridItem(.adaptive(minimum: 180), spacing: 14)]
    var body: some View {
        let p = theme.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Bookmarks").font(.system(size: 22, weight: .semibold))
                if state.bookmarks.isEmpty {
                    Text("No bookmarks yet — star a page to add one.")
                        .font(.system(size: 13)).foregroundStyle(p.dim)
                } else {
                    LazyVGrid(columns: cols, spacing: 14) {
                        ForEach(state.bookmarks) { b in BookmarkCard(b: b) }
                    }
                }
            }
            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BookmarkCard: View {
    let b: Bookmark
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @State private var hover = false
    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color(hex: b.tintHex).opacity(0.18))
                        .frame(width: 30, height: 30)
                    Text(b.letter).font(.system(size: 13, weight: .bold)).foregroundStyle(Color(hex: b.tintHex))
                }
                Spacer()
                if hover {
                    Button { state.removeBookmark(b) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(p.faint)
                }
            }
            Text(b.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
            Text(URL(string: b.url)?.host ?? b.url).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(p.faint).lineLimit(1)
        }
        .padding(14).frame(height: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(hover ? p.surface2 : p.surface2.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(p.border))
        .contentShape(Rectangle())
        .onTapGesture { state.openBookmark(b) }
        .onHover { hover = $0 }
    }
}

// MARK: - Notes panel (hybrid: native shell, React webview mounts here later)

private enum NotesMode { case editor, graph }

struct NotesPanel: View {
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var notes: NotesStore
    @State private var mode: NotesMode = .editor

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            // header: title + mode switch + close
            HStack(spacing: 10) {
                Text("Notes").font(.system(size: 13, weight: .semibold))
                if notes.readOnly {
                    Text("read-only").font(.system(size: 9, weight: .semibold)).tracking(0.5)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(p.faint.opacity(0.18))).foregroundStyle(p.dim)
                }
                Spacer()
                if notes.vaultPath != nil {
                    Picker("", selection: Binding(get: { notes.source }, set: { notes.setSource($0) })) {
                        Text("Local").tag(VaultSource.local)
                        Text("Obsidian").tag(VaultSource.obsidian)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 132)
                    IconButton(system: "arrow.clockwise", size: 12) { notes.reload() }
                }
                Picker("", selection: $mode) {
                    Image(systemName: "doc.text").tag(NotesMode.editor)
                    Image(systemName: "point.3.connected.trianglepath.dotted").tag(NotesMode.graph)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 92)
                IconButton(system: "xmark") { state.notesOpen = false }
            }
            .padding(.horizontal, 16).frame(height: 46)
            Divider().overlay(p.border)

            // note switcher + new
            HStack(spacing: 8) {
                Menu {
                    ForEach(notes.notes) { n in
                        Button(n.title.isEmpty ? "Untitled" : n.title) { notes.select(n.id); mode = .editor }
                    }
                    if !notes.readOnly {
                        Divider()
                        Button("New note") { notes.create(); mode = .editor }
                        if let sel = notes.selected {
                            Button("Delete note", role: .destructive) { notes.delete(sel) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(theme.accent).frame(width: 7, height: 7)
                        Text((notes.selected?.title.isEmpty == false) ? notes.selected!.title : "Untitled")
                            .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                    .foregroundStyle(p.text)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Spacer()
                if !notes.readOnly {
                    IconButton(system: "plus", size: 13) { notes.create(); mode = .editor }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider().overlay(p.border)

            // content
            if mode == .graph {
                NotesGraphView(mode: $mode)
            } else if let note = notes.selected {
                NoteEditorView(note: note)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Text("No notes yet").foregroundStyle(p.faint)
                    Button("New note") { notes.create() }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 440)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow, blending: .withinWindow)  // blurs the live page
                p.surface
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusPanel, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: theme.radiusPanel).strokeBorder(p.border))
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusPanel, style: .continuous))
        .onDisappear { notes.pruneEmpties() }
        .onAppear {
            if state.notesInitialGraph { mode = .graph; state.notesInitialGraph = false }
            if notes.source == .obsidian { notes.reload() }
        }
    }
}

struct NoteEditorView: View {
    @ObservedObject var note: Note
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var theme: Theme
    @State private var previewing = false
    @FocusState private var titleFocused: Bool
    var body: some View {
        let p = theme.palette
        let ro = notes.readOnly
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if ro {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(.system(size: 19, weight: .semibold))
                } else {
                    TextField("Title", text: $note.title)
                        .textFieldStyle(.plain).font(.system(size: 19, weight: .semibold))
                        .focused($titleFocused)
                        .onChange(of: note.title) { _, _ in notes.scheduleSave(note) }
                        .onChange(of: titleFocused) { _, f in if !f { notes.dedupeTitle(note) } }
                }

                if !note.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(note.tags, id: \.self) { t in
                            Text("#\(t)").font(.system(size: 11))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(theme.accent.opacity(0.16)))
                                .foregroundStyle(theme.accent)
                        }
                    }
                }

                if !ro {
                    TextField("tags, comma separated", text: Binding(
                        get: { note.tags.joined(separator: ", ") },
                        set: { note.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    ))
                    .textFieldStyle(.plain).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(p.dim)
                    .onChange(of: note.tags) { _, _ in notes.scheduleSave(note) }

                    HStack {
                        Spacer()
                        Picker("", selection: $previewing) {
                            Image(systemName: "pencil").tag(false)
                            Image(systemName: "eye").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 74)
                    }
                }
                Divider().overlay(p.border)

                if ro || previewing {
                    MarkdownView(text: note.body)
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "somnia", url.host == "note" else { return .systemAction }
                            let title = String(url.path.dropFirst()).removingPercentEncoding
                                ?? String(url.path.dropFirst())
                            if let target = notes.resolve(title) { notes.select(target.id) }
                            else if !notes.readOnly { notes.create(title: title) }
                            return .handled
                        })
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                } else {
                    TextEditor(text: $note.body)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 240)
                        .onChange(of: note.body) { _, _ in notes.scheduleSave(note) }
                }

                let out = notes.outgoing(note)
                if !out.isEmpty { LinkList(title: "LINKS", icon: "arrow.up.right", items: out) }
                let back = notes.backlinks(note)
                if !back.isEmpty { LinkList(title: "BACKLINKS", icon: "arrow.down.left", items: back) }

                Text(ro ? "Obsidian vault — read-only. [[Wiki-links]] are clickable."
                        : "Link notes with [[Title]]. Toggle ✎ / 👁 to preview.")
                    .font(.system(size: 11)).foregroundStyle(p.faint).padding(.top, 4)
            }
            .padding(16)
        }
    }
}

struct LinkList: View {
    let title: String
    let icon: String
    let items: [Note]
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var theme: Theme
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1)
                .foregroundStyle(theme.palette.faint)
            ForEach(items) { n in
                Button { notes.select(n.id) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: icon).font(.system(size: 9))
                        Text(n.title.isEmpty ? "Untitled" : n.title).font(.system(size: 12.5)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct NotesGraphView: View {
    @Binding fileprivate var mode: NotesMode
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var theme: Theme
    var body: some View {
        GraphWebView(json: notes.graphJSON(), accentHex: theme.accentHex, isDark: theme.isDark) { id in
            notes.select(id)
            mode = .editor
        }
    }
}

// MARK: - Customize panel (theme / layout / density / accent)

/// Measures the Customize panel's content height so the panel can size to its
/// content but cap at the available screen height and scroll beyond it.
private struct PanelContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct CustomizePanel: View {
    @EnvironmentObject var state: BrowserState
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var proxy: ProxyStore
    @State private var contentHeight: CGFloat = 0
    private let accents = ["#9b8aae", "#7c9b8a", "#ae8a8a", "#8a9bae", "#aea98a"]
    var body: some View {
        let p = theme.palette
        GeometryReader { geo in
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.001).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { state.settingsOpen = false }

            ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text("CUSTOMIZE").font(.system(size: 11, weight: .semibold)).tracking(2)
                    .foregroundStyle(p.faint)
                seg("Theme", ["Light", "Dark"], theme.appearance == .dark ? 1 : 0) { i in
                    theme.appearance = i == 0 ? .light : .dark
                }
                seg("Layout", ["Aurora", "Slate"], theme.direction == .slate ? 1 : 0) { i in
                    theme.direction = i == 0 ? .aurora : .slate
                }
                seg("Density", ["Compact", "Cozy", "Roomy"], densityIdx) { i in
                    theme.density = [.compact, .cozy, .roomy][i]
                }
                seg("Tab budget", ["4", "6", "10"], budgetIdx) { i in
                    state.setBudget([4, 6, 10][i])
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Transparency").font(.system(size: 12)).foregroundStyle(p.dim)
                        Spacer()
                        Text("\(Int((1 - theme.surfaceOpacity) * 100))%")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.faint)
                    }
                    Slider(value: $theme.surfaceOpacity, in: 0.3...1.0).tint(theme.accent)
                }
                HStack {
                    Text("Search engine").font(.system(size: 12)).foregroundStyle(p.dim)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { theme.searchEngine },
                        set: { theme.searchEngine = $0 })) {
                        ForEach(SearchEngine.allCases) { e in Text(e.label).tag(e) }
                    }
                    .labelsHidden().fixedSize()
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Block trackers").font(.system(size: 12)).foregroundStyle(p.dim)
                        Text("ads & analytics domains").font(.system(size: 10)).foregroundStyle(p.faint)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { theme.blockTrackers },
                                             set: { theme.blockTrackers = $0 }))
                        .labelsHidden().toggleStyle(.switch).tint(theme.accent)
                }
                colorRow("Background", theme.binding(for: .background))
                colorRow("Panel",      theme.binding(for: .surface))
                colorRow("Text",       theme.binding(for: .text))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Accent").font(.system(size: 12)).foregroundStyle(p.dim)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { theme.accent },
                            set: { theme.accentHex = $0.hexString ?? theme.accentHex }))
                            .labelsHidden().frame(width: 28)
                    }
                    HStack(spacing: 10) {
                        ForEach(accents, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(theme.accentHex == hex ? p.text : .clear, lineWidth: 2))
                                .onTapGesture { theme.accentHex = hex }
                        }
                    }
                }
                Button("Reset colors") { theme.resetCustomColors() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.accent)
                Divider().overlay(p.border).padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Obsidian vault").font(.system(size: 12)).foregroundStyle(p.dim)
                    Text(notes.vaultPath.map { ($0 as NSString).lastPathComponent } ?? "Not connected")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.faint).lineLimit(1)
                    HStack(spacing: 12) {
                        Button("Choose vault…") { chooseVault() }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.accent)
                        if notes.vaultPath != nil {
                            Button("Disconnect") { notes.disconnectVault() }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(p.dim)
                        }
                    }
                }
                Divider().overlay(p.border).padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Home background").font(.system(size: 12)).foregroundStyle(p.dim)
                    HStack(spacing: 12) {
                        Button("Choose image…") { chooseHomeBackground() }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.accent)
                        if theme.homeBgImage != nil {
                            Button("Remove") { theme.clearHomeBackground() }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(p.dim)
                        }
                    }
                }
                Divider().overlay(p.border).padding(.vertical, 2)
                proxySection(p)
                Divider().overlay(p.border).padding(.vertical, 2)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("History").font(.system(size: 12)).foregroundStyle(p.dim)
                        Text("\(history.entries.count) entries")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.faint)
                    }
                    Spacer()
                    Button("Clear history") { history.clear() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.accent)
                        .disabled(history.entries.isEmpty)
                }
            }
            .padding(18)
            .background(GeometryReader { g in
                Color.clear.preference(key: PanelContentHeight.self, value: g.size.height)
            })
            }
            .frame(width: 300,
                   height: min(contentHeight == 0 ? .infinity : contentHeight,
                               max(200, geo.size.height - (theme.appGap + 56) - 24)))
            .onPreferenceChange(PanelContentHeight.self) { contentHeight = $0 }
            .background(ZStack {
                VisualEffect(material: .hudWindow, blending: .withinWindow)
                p.surface
            }.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(p.border))
            .padding(.leading, theme.appGap + 12).padding(.bottom, theme.appGap + 56)
        }
        }
    }

    private var densityIdx: Int { theme.density == .compact ? 0 : theme.density == .roomy ? 2 : 1 }
    private var budgetIdx: Int { state.maxLiveTabs <= 4 ? 0 : state.maxLiveTabs >= 10 ? 2 : 1 }

    func seg(_ title: String, _ opts: [String], _ sel: Int, _ pick: @escaping (Int) -> Void) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(p.dim)
            HStack(spacing: 6) {
                ForEach(Array(opts.enumerated()), id: \.offset) { idx, o in
                    Button { pick(idx) } label: {
                        Text(o).font(.system(size: 12.5))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(sel == idx ? theme.accent.opacity(0.18) : p.surface2))
                            .foregroundStyle(sel == idx ? theme.accent : p.dim)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    func colorRow(_ title: String, _ binding: Binding<Color>) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(theme.palette.dim)
            Spacer()
            ColorPicker("", selection: binding).labelsHidden().frame(width: 28)
        }
    }

    private func bindProxy() -> Binding<ProxyConfig> {
        Binding(
            get: { proxy.config ?? ProxyConfig(type: .socks5, host: "", port: 1080, username: nil, password: nil) },
            set: { proxy.config = $0 }
        )
    }

    private func proxyField(_ placeholder: String, _ text: Binding<String>, secure: Bool = false) -> some View {
        let p = theme.palette
        return Group {
            if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
        }
        .textFieldStyle(.plain).font(.system(size: 12))
        .foregroundStyle(p.text)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
    }

    @ViewBuilder func proxySection(_ p: Palette) -> some View {
        let px = bindProxy()
        VStack(alignment: .leading, spacing: 8) {
            Text("Proxy").font(.system(size: 12)).foregroundStyle(p.dim)
            HStack {
                Text("Type").font(.system(size: 11)).foregroundStyle(p.faint)
                Spacer()
                Picker("", selection: px.type) {
                    Text("SOCKS5").tag(ProxyType.socks5)
                    Text("HTTP").tag(ProxyType.http)
                }
                .labelsHidden().fixedSize()
            }
            proxyField("Host", px.host)
            TextField("Port", value: px.port, format: .number)
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(p.text)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(p.surface2))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
            proxyField("Username (optional)", Binding(
                get: { px.username.wrappedValue ?? "" },
                set: { px.username.wrappedValue = $0.isEmpty ? nil : $0 }))
            proxyField("Password (optional)", Binding(
                get: { px.password.wrappedValue ?? "" },
                set: { px.password.wrappedValue = $0.isEmpty ? nil : $0 }), secure: true)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use proxy in this window").font(.system(size: 12)).foregroundStyle(p.dim)
                    if !proxy.isConfigured {
                        Text("Enter a host and port to enable.").font(.system(size: 10)).foregroundStyle(p.faint)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { state.proxyEnabled },
                    set: { state.setProxyEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(theme.accent)
                    .disabled(!proxy.isConfigured)
            }
        }
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { notes.connectVault(url) }
    }

    private func chooseHomeBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { theme.setHomeBackground(from: url) }
    }
}
