import XCTest

final class TwoFingerGestureStateTests: XCTestCase {
    func testNormalPanScrollsAndCoasts() {
        var gesture = TwoFingerGestureState()
        gesture.beginPan()
        XCTAssertTrue(gesture.allowsScroll)
        XCTAssertTrue(gesture.endPan(coast: true))
    }

    func testUncommittedPinchRecognizerDoesNotDisableScrollOrMomentum() {
        var gesture = TwoFingerGestureState()
        gesture.beginPan()
        gesture.beginPinch() // UIKit can recognize this on an ordinary pan.
        XCTAssertTrue(gesture.allowsScroll)
        XCTAssertTrue(gesture.endPan(coast: true))
        gesture.endPinch()
        XCTAssertTrue(gesture.allowsScroll)
    }

    func testUncommittedPinchEndedBeforePanStillCoasts() {
        var gesture = TwoFingerGestureState()
        gesture.beginPinch()
        gesture.beginPan()
        gesture.endPinch()
        XCTAssertTrue(gesture.endPan(coast: true))
    }

    func testCommittedZoomSuppressesScrollAndCoastWithEitherCallbackOrder() {
        for pinchEndsFirst in [true, false] {
            var gesture = TwoFingerGestureState()
            gesture.beginPan()
            gesture.beginPinch()
            gesture.commitZoom()
            XCTAssertFalse(gesture.allowsScroll)
            if pinchEndsFirst { gesture.endPinch() }
            XCTAssertFalse(gesture.endPan(coast: true))
            if !pinchEndsFirst { gesture.endPinch() }
            XCTAssertTrue(gesture.allowsScroll)
        }
    }

    func testCancelledPanAndThreeFingerTransitionNeverCoast() {
        var gesture = TwoFingerGestureState()
        gesture.beginPinch()
        gesture.beginPan()
        gesture.commitZoom()
        gesture.cancelForThreeFingerGesture()
        XCTAssertTrue(gesture.allowsScroll)
        XCTAssertFalse(gesture.endPan(coast: false))
        gesture.endPinch()
        XCTAssertTrue(gesture.allowsScroll)
    }

    func testOnlyNewContactsStopExistingMomentum() {
        XCTAssertTrue(TwoFingerGestureState.touchShouldStopMomentum("began"))
        for phase in ["moved", "ended", "cancelled"] {
            XCTAssertFalse(TwoFingerGestureState.touchShouldStopMomentum(phase))
        }
    }

    func testStateIsReusableAfterBothRecognizersFinish() {
        var gesture = TwoFingerGestureState()
        gesture.beginPan()
        gesture.beginPinch()
        gesture.commitZoom()
        gesture.endPinch()
        XCTAssertFalse(gesture.endPan(coast: true))
        gesture.beginPan()
        gesture.beginPinch()
        XCTAssertTrue(gesture.allowsScroll)
        XCTAssertTrue(gesture.endPan(coast: true))
        gesture.endPinch()
    }
}
