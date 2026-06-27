import XCTest

final class PreferenceDefaultsTests: XCTestCase {
    func testAppGroupUsesSingleDefaultSource() {
        XCTAssertEqual(
            NSDictionary(dictionary: AppGroup.suiteRegistrationDefaults),
            NSDictionary(dictionary: PreferenceDefaults.registrationValues)
        )
    }

    func testDefaultsIncludePreviouslyDriftProneKeys() {
        XCTAssertEqual(PreferenceDefaults.registrationValues[AppGroupKey.hoverOpenDelay] as? Double, 0.4)
        XCTAssertEqual(PreferenceDefaults.registrationValues[AppGroupKey.previewSize] as? String, "standard")
        XCTAssertEqual(PreferenceDefaults.registrationValues[AppGroupKey.trafficLightSide] as? String, "trailing")
        XCTAssertEqual(PreferenceDefaults.registrationValues[AppGroupKey.minimizeEffect] as? String, "system")
        XCTAssertEqual(PreferenceDefaults.registrationValues[AppGroupKey.windowSnappingShortcuts] as? String, "")
        XCTAssertEqual(PreferenceDefaults.registrationValues[AppGroupKey.notchCalendarStyle] as? String, "compact")
        XCTAssertEqual(PreferenceDefaults.registrationValues[AppGroupKey.notchBatteryStyle] as? String, "gauge")
    }
}
