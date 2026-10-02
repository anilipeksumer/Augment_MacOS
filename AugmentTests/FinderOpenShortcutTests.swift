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

@MainActor
final class FinderExtrasTests: XCTestCase {
    func testBackspaceAndF2AreOptInAndPreserveOtherModifiers() {
        for mode in FinderEnterBehavior.allCases {
            XCTAssertEqual(FinderOpenShortcutService.action(keyCode: Int64(kVK_Delete), flags: [], mode: mode, backspace: true), .parent)
            XCTAssertEqual(FinderOpenShortcutService.action(keyCode: Int64(kVK_F2), flags: [], mode: mode, f2: true), .rename)
            XCTAssertNil(FinderOpenShortcutService.action(keyCode: Int64(kVK_Delete), flags: .maskCommand, mode: mode, backspace: true))
            XCTAssertNil(FinderOpenShortcutService.action(keyCode: Int64(kVK_F2), flags: .maskShift, mode: mode, f2: true))
            XCTAssertNil(FinderOpenShortcutService.action(keyCode: Int64(kVK_Delete), flags: [], mode: mode))
            XCTAssertNil(FinderOpenShortcutService.action(keyCode: Int64(kVK_F2), flags: [], mode: mode))
        }
    }

    func testImagePasteDoesNotClaimHistoryOrMoveShortcuts() {
        XCTAssertEqual(FinderOpenShortcutService.action(keyCode: Int64(kVK_ANSI_V), flags: .maskCommand, mode: .system, pasteImage: true), .pasteImage)
        for flags: CGEventFlags in [[.maskCommand, .maskShift], [.maskCommand, .maskAlternate], [], .maskControl] {
            XCTAssertNil(FinderOpenShortcutService.action(keyCode: Int64(kVK_ANSI_V), flags: flags, mode: .system, pasteImage: true))
        }
    }

    func testPNGCreationNeverOverwritesAndStoreRejectsPathTraversal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try ClipboardImageStore.writePNG(Data("first".utf8), to: directory, baseName: "Image")
        let second = try ClipboardImageStore.writePNG(Data("second".utf8), to: directory, baseName: "Image")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        let store = ClipboardImageStore(directory: directory.appendingPathComponent("store"))
        XCTAssertNil(store.url(for: "../secret.png"))
        XCTAssertNil(ClipboardImageStore.pngData(Data("not an image".utf8)))
        let saved = try store.save(Data("image bytes".utf8))
        XCTAssertEqual(try store.save(Data("image bytes".utf8)), saved)
        store.prune(keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.url(for: saved)).path))
    }
}
