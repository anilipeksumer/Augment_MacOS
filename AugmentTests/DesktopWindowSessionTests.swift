import XCTest

final class DesktopWindowSessionTests: XCTestCase {
    func testRestoresOnlyWindowsMinimizedSuccessfullyByThisSession() {
        var session = DesktopWindowSession<Int>()
        var states = [1: false, 2: true, 3: false]
        session.minimize([1, 2, 3], isMinimized: { states[$0] }) { id, value in
            guard id != 3 else { return false }
            states[id] = value
            return true
        }
        XCTAssertEqual(session.windows, [1])
        session.restore(isMinimized: { states[$0] }) { id, value in
            states[id] = value
            return true
        }
        XCTAssertEqual(states, [1: false, 2: true, 3: false])
        XCTAssertTrue(session.windows.isEmpty)
    }

    func testClosedAndManuallyRestoredWindowsAreNotTouched() {
        var session = DesktopWindowSession<Int>()
        session.minimize([1, 2, 3], isMinimized: { _ in false }, setMinimized: { _, _ in true })
        var touched: [Int] = []
        session.restore(isMinimized: { [1: true, 2: false][$0] }) { id, _ in
            touched.append(id)
            return true
        }
        XCTAssertEqual(touched, [1])
        XCTAssertTrue(session.windows.isEmpty)
    }

    func testFailedRestorationCanBeRetried() {
        var session = DesktopWindowSession<Int>()
        session.minimize([1], isMinimized: { _ in false }, setMinimized: { _, _ in true })
        session.restore(isMinimized: { _ in true }, setMinimized: { _, _ in false })
        XCTAssertEqual(session.windows, [1])
        session.restore(isMinimized: { _ in true }, setMinimized: { _, _ in true })
        XCTAssertTrue(session.windows.isEmpty)
    }

    func testPruningUserRestorationsAllowsANewMinimizeSession() {
        var session = DesktopWindowSession<Int>()
        session.minimize([1], isMinimized: { _ in false }, setMinimized: { _, _ in true })
        session.prune(isMinimized: { _ in false })
        session.minimize([2], isMinimized: { _ in false }, setMinimized: { _, _ in true })
        XCTAssertEqual(session.windows, [2])
    }
}
