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
