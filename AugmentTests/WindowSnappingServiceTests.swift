import XCTest

final class WindowSnappingServiceTests: XCTestCase {
    func testEmptyShortcutJSONUsesDefaults() {
        let shortcuts = WindowSnappingService.shortcuts(from: "")

        XCTAssertEqual(shortcuts[.left]?.keyCode, SnapDirection.left.defaultKeyCode)
        XCTAssertEqual(shortcuts[.right]?.modifiers, SnapDirection.right.defaultModifiers.rawValue)
    }

    func testPartialShortcutJSONFillsMissingDirections() throws {
        let override = SnapShortcut(modifiers: 123, keyCode: 45)
        let data = try JSONEncoder().encode(["left": override])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        let shortcuts = WindowSnappingService.shortcuts(from: json)

        XCTAssertEqual(shortcuts[.left], override)
        XCTAssertEqual(shortcuts[.right]?.keyCode, SnapDirection.right.defaultKeyCode)
        XCTAssertEqual(shortcuts[.up]?.keyCode, SnapDirection.up.defaultKeyCode)
        XCTAssertEqual(shortcuts[.down]?.keyCode, SnapDirection.down.defaultKeyCode)
    }

    func testInvalidShortcutJSONFallsBackToDefaults() {
        let shortcuts = WindowSnappingService.shortcuts(from: "{not-json")

        XCTAssertEqual(shortcuts[.left]?.keyCode, SnapDirection.left.defaultKeyCode)
        XCTAssertEqual(shortcuts[.down]?.modifiers, SnapDirection.down.defaultModifiers.rawValue)
    }
}
