import Foundation

/// A dedicated, high-priority thread whose run loop hosts Augment's
/// `CGEventTap`s. Active taps sit in the path of every event the user
/// produces: while a tap's callback hasn't returned, the whole system's
/// mouse or keyboard waits. On the main thread, any SwiftUI layout,
/// thumbnail capture or AppleScript call would stall everyone's input —
/// that's what made windows impossible to click while Augment ran.
final class EventTapThread: Thread {
    static let shared: EventTapThread = {
        let thread = EventTapThread()
        thread.name = "com.augment.event-taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        thread.ready.wait()
        return thread
    }()

    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A run loop with no sources exits immediately; keep one around.
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(runLoop, keepAlive, .commonModes)
        ready.signal()
        CFRunLoopRun()
    }

    func add(_ source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
    }

    func remove(_ source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
    }
}
