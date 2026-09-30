/// Tracks only windows successfully minimized by this session. Windows already
/// minimized, closed, or restored by the user must not be restored again.
struct DesktopWindowSession<Window> {
    private(set) var windows: [Window] = []

    mutating func prune(isMinimized: (Window) -> Bool?) {
        windows.removeAll { isMinimized($0) != true }
    }

    mutating func minimize(_ candidates: [Window], isMinimized: (Window) -> Bool?,
                           setMinimized: (Window, Bool) -> Bool) {
        guard windows.isEmpty else { return }
        for window in candidates where isMinimized(window) == false {
            if setMinimized(window, true) { windows.append(window) }
        }
    }

    mutating func restore(isMinimized: (Window) -> Bool?, setMinimized: (Window, Bool) -> Bool) {
        // Keep transient failures so another press can retry. A missing window
        // or one the user already restored no longer belongs to the session.
        windows = windows.filter { isMinimized($0) == true && !setMinimized($0, false) }
    }
}
