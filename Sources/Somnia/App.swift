import SwiftUI
import AppKit

/// Adds a Dock right-click "New Window" item and reopens a window when the
/// Dock icon is clicked with none visible. Both bridge to SwiftUI's window
/// machinery via a notification (a live window opens the new one; with no
/// windows, returning true lets SwiftUI restore one).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc func newWindow(_ sender: Any?) {
        NotificationCenter.default.post(name: .somniaNewWindow, object: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .somniaNewWindow, object: nil) }
        return true
    }
}

@main
struct SomniaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var theme = Theme()
    @StateObject private var notes = NotesStore()
    @StateObject private var history = HistoryStore.shared
    @StateObject private var downloads = DownloadsModel.shared
    @StateObject private var favicons = FaviconStore.shared
    @StateObject private var proxy = ProxyStore.shared
    @FocusedValue(\.browserState) var focusedState: BrowserState?
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Value-based WindowGroup: opening with a fresh UUID each time reliably
        // spawns a NEW window (a dataless WindowGroup would just re-focus the
        // existing one, so a second window only appeared after closing the first).
        WindowGroup(id: "main", for: UUID.self) { _ in
            RootView()
                .environmentObject(theme)
                .environmentObject(notes)
                .environmentObject(history)
                .environmentObject(downloads)
                .environmentObject(favicons)
                .environmentObject(proxy)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { focusedState?.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Private Tab") { focusedState?.newPrivateTab() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Window") { openWindow(id: "main", value: UUID()) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open File…") { focusedState?.promptOpenFile() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Close Tab") { focusedState?.closeActiveTab() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("View") {
                Button("Reload") { focusedState?.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Reader Mode") { focusedState?.toggleReader() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Find on Page") { focusedState?.openFind() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Open Location") { focusedState?.pulseAddressFocus() }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Customize") { focusedState?.settingsOpen.toggle() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("History") {
                Button("Back") { focusedState?.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { focusedState?.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
            }
            CommandMenu("Tabs") {
                Button("Quick Open") { focusedState?.paletteOpen.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Next Tab") { focusedState?.cycleTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { focusedState?.cycleTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Tab \(n)") { focusedState?.selectTabByIndex(n == 9 ? 99 : n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
        }
    }
}
