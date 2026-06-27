import XCTest

final class AXElementCoercionTests: XCTestCase {
    func testWrongTypesReturnNilInsteadOfCrashing() {
        let value = "not an AX value" as NSString

        XCTAssertNil(AXElementCoercion.element(value))
        XCTAssertNil(AXElementCoercion.value(value))
        XCTAssertNil(AXElementCoercion.point(from: value))
        XCTAssertNil(AXElementCoercion.size(from: value))
    }
}
