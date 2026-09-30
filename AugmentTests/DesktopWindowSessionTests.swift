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

extension DesktopWindowSessionTests {
    func testNewWindowMinimizesBeforeAnySavedWindowsRestore() {
        var session = DesktopWindowSession<Int>()
        var states = [1: false, 2: true]
        func toggle(visible: Bool, reject: Int? = nil) -> Bool {
            session.toggle(states.keys.sorted(), hasVisibleWindows: visible, isMinimized: { states[$0] }) { id, value in
                guard id != reject else { return false }
                states[id] = value
                return true
            }
        }
        XCTAssertFalse(toggle(visible: true))
        states[3] = false
        XCTAssertFalse(toggle(visible: true))
        XCTAssertEqual(states, [1: true, 2: true, 3: true])
        XCTAssertEqual(session.windows, [1, 3])
        XCTAssertTrue(toggle(visible: false))
        XCTAssertEqual(states, [1: false, 2: true, 3: false])
    }

    func testManuallyRestoredWindowIsMinimizedAgainWithoutDuplicates() {
        var session = DesktopWindowSession<Int>()
        var states = [1: false, 2: false]
        func toggle(visible: Bool) {
            session.toggle([1, 2], hasVisibleWindows: visible, isMinimized: { states[$0] }) { id, value in
                states[id] = value
                return true
            }
        }
        toggle(visible: true)
        states[1] = false
        toggle(visible: true)
        XCTAssertEqual(states, [1: true, 2: true])
        XCTAssertEqual(Set(session.windows), [1, 2])
        XCTAssertEqual(session.windows.count, 2)
        toggle(visible: false)
        XCTAssertEqual(states, [1: false, 2: false])
    }

    func testVisibleWindowThatCannotMinimizeDoesNotRestoreSavedGroup() {
        var session = DesktopWindowSession<Int>()
        var states = [1: false]
        session.toggle([1], hasVisibleWindows: true, isMinimized: { states[$0] }) { id, value in
            states[id] = value
            return true
        }
        states[2] = false
        let restored = session.toggle([1, 2], hasVisibleWindows: true, isMinimized: { states[$0] },
                                      setMinimized: { _, _ in false })
        XCTAssertFalse(restored)
        XCTAssertEqual(states, [1: true, 2: false])
        XCTAssertEqual(session.windows, [1])
    }

    func testEmptyDesktopWithoutSavedWindowsIsANoOp() {
        var session = DesktopWindowSession<Int>()
        XCTAssertFalse(session.toggle([], hasVisibleWindows: false, isMinimized: { _ in nil },
                                      setMinimized: { _, _ in XCTFail("Unexpected mutation"); return false }))
    }
}
