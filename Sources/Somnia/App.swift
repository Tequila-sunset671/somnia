import SwiftUI

@main
struct SomniaApp: App {
    @StateObject private var theme = Theme()
    @StateObject private var notes = NotesStore()
    @StateObject private var history = HistoryStore.shared
    @StateObject private var downloads = DownloadsModel.shared
    @StateObject private var favicons = FaviconStore.shared
    @FocusedValue(\.browserState) var focusedState: BrowserState?
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(theme)
                .environmentObject(notes)
                .environmentObject(history)
                .environmentObject(downloads)
                .environmentObject(favicons)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { focusedState?.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Private Tab") { focusedState?.newPrivateTab() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Window") { openWindow(id: "main") }
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
