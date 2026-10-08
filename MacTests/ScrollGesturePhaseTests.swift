import XCTest
final class ScrollGesturePhaseTests: XCTestCase {
    func testNativeAppKitPhaseValues() {
        XCTAssertEqual(ScrollGesturePhase.began.cgValue, 1)
        XCTAssertEqual(ScrollGesturePhase.changed.cgValue, 4)
        XCTAssertEqual(ScrollGesturePhase.ended.cgValue, 8)
        XCTAssertEqual(ScrollGesturePhase.cancelled.cgValue, 16)
    }
    func testUnknownPhaseNotRecognized() {
        XCTAssertNil(ScrollGesturePhase(rawValue: "back"))
        XCTAssertNil(ScrollGesturePhase(rawValue: "momentum"))
    }
}
