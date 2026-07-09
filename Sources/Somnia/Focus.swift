import SwiftUI

struct BrowserStateFocusedKey: FocusedValueKey {
    typealias Value = BrowserState
}

extension FocusedValues {
    var browserState: BrowserState? {
        get { self[BrowserStateFocusedKey.self] }
        set { self[BrowserStateFocusedKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Posted (by the Dock menu / reopen handler) to request a fresh browser window.
    static let somniaNewWindow = Notification.Name("somniaNewWindow")
}

/// Dedupes the `.somniaNewWindow` notification: every open window's RootView
/// receives it, but only the first to claim (within a short window, on the main
/// thread) actually opens a new window — otherwise N windows would each spawn one.
enum NewWindowCoordinator {
    private static var lastClaim = Date.distantPast
    static func claim() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastClaim) > 0.3 else { return false }
        lastClaim = now
        return true
    }
}
