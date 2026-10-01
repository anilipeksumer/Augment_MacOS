import XCTest
import Carbon
import CoreGraphics

@MainActor
final class FinderOpenShortcutTests: XCTestCase {
    func testSystemModeNeverRemapsReturn() {
        for key in [kVK_Return, kVK_ANSI_KeypadEnter] {
            for flags: CGEventFlags in [[], .maskShift, .maskCommand] {
                XCTAssertNil(FinderOpenShortcutService.action(keyCode: Int64(key), flags: flags, mode: .system))
            }
        }
    }
    func testModeTwoPreservesReturnAndOpensWithShift() {
        for key in [kVK_Return, kVK_ANSI_KeypadEnter] {
            XCTAssertNil(FinderOpenShortcutService.action(keyCode: Int64(key), flags: [], mode: .shiftEnterOpens))
            XCTAssertEqual(FinderOpenShortcutService.action(keyCode: Int64(key), flags: .maskShift, mode: .shiftEnterOpens), .open)
        }
    }
    func testModeThreeOpensWithReturnAndRenamesWithShift() {
        for key in [kVK_Return, kVK_ANSI_KeypadEnter] {
            XCTAssertEqual(FinderOpenShortcutService.action(keyCode: Int64(key), flags: [], mode: .enterOpens), .open)
            XCTAssertEqual(FinderOpenShortcutService.action(keyCode: Int64(key), flags: .maskShift, mode: .enterOpens), .rename)
        }
    }
    func testOtherShortcutsAreNeverRemapped() {
        for mode in FinderEnterBehavior.allCases {
            for flags: CGEventFlags in [.maskCommand, [.maskShift, .maskCommand], [.maskShift, .maskAlternate], [.maskShift, .maskControl]] {
                XCTAssertNil(FinderOpenShortcutService.action(keyCode: Int64(kVK_Return), flags: flags, mode: mode))
            }
            XCTAssertNil(FinderOpenShortcutService.action(keyCode: Int64(kVK_ANSI_V), flags: .maskShift, mode: mode))
        }
    }
    func testCapsLockAndKeypadFlagsDoNotChangeBehavior() {
        XCTAssertEqual(FinderOpenShortcutService.action(keyCode: Int64(kVK_ANSI_KeypadEnter), flags: [.maskShift, .maskNumericPad, .maskAlphaShift], mode: .shiftEnterOpens), .open)
    }
    func testDefaultIsNativeMacOSBehavior() {
        XCTAssertEqual(PreferenceDefaults.registrationValues[AppGroupKey.finderEnterBehavior] as? String, "system")
    }
}
