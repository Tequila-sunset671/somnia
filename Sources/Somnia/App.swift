import SwiftUI

@main
struct SomniaApp: App {
    @StateObject private var state = BrowserState()
    @StateObject private var theme = Theme()
    @StateObject private var notes = NotesStore()
    @StateObject private var history = HistoryStore.shared
    @StateObject private var downloads = DownloadsModel.shared
    @StateObject private var favicons = FaviconStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
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
                Button("New Tab") { BrowserState.current?.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Private Tab") { BrowserState.current?.newPrivateTab() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open File…") { BrowserState.current?.promptOpenFile() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Close Tab") { BrowserState.current?.closeActiveTab() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("View") {
                Button("Reload") { BrowserState.current?.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Reader Mode") { BrowserState.current?.toggleReader() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Find on Page") { BrowserState.current?.openFind() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Open Location") { BrowserState.current?.pulseAddressFocus() }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Customize") { BrowserState.current?.settingsOpen.toggle() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("History") {
                Button("Back") { BrowserState.current?.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { BrowserState.current?.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
            }
            CommandMenu("Tabs") {
                Button("Quick Open") { BrowserState.current?.paletteOpen.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Next Tab") { BrowserState.current?.cycleTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { BrowserState.current?.cycleTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Tab \(n)") { BrowserState.current?.selectTabByIndex(n == 9 ? 99 : n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
        }
    }
}
