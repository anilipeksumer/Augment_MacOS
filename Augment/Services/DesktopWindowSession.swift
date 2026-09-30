/// Tracks only windows successfully minimized by this session. Windows already
/// minimized, closed, or restored by the user must not be restored again.
struct DesktopWindowSession<Window> {
    private(set) var windows: [Window] = []

    /// Current visibility wins over saved history: a newly opened window
    /// must be minimized before the desktop shortcut can restore anything.
    @discardableResult
    mutating func toggle(_ candidates: [Window], hasVisibleWindows: Bool,
                         isMinimized: (Window) -> Bool?, setMinimized: (Window, Bool) -> Bool) -> Bool {
        prune(isMinimized: isMinimized)
        if hasVisibleWindows {
            minimize(candidates, isMinimized: isMinimized, setMinimized: setMinimized)
            return false
        }
        guard !windows.isEmpty else { return false }
        restore(isMinimized: isMinimized, setMinimized: setMinimized)
        return true
    }

    mutating func prune(isMinimized: (Window) -> Bool?) {
        windows.removeAll { isMinimized($0) != true }
    }

    mutating func minimize(_ candidates: [Window], isMinimized: (Window) -> Bool?,
                           setMinimized: (Window, Bool) -> Bool) {
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
