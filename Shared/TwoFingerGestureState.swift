// Shared by the iOS touch view and hostless macOS regression tests.
// UIKit recognizes a pinch while fingers are merely scrolling. Recognition
// alone must never disable scrolling or momentum: only a committed zoom can.
struct TwoFingerGestureState {
    private(set) var panActive = false
    private(set) var pinchActive = false
    private(set) var zoomCommitted = false

    var allowsScroll: Bool { !zoomCommitted }

    mutating func beginPan() {
        panActive = true
    }

    mutating func beginPinch() {
        pinchActive = true
    }

    mutating func commitZoom() {
        zoomCommitted = true
    }

    mutating func cancelForThreeFingerGesture() {
        // Three-finger Space gestures have their own mutually exclusive path.
        zoomCommitted = false
    }

    /// Returns whether pan release should launch kinetic scrolling. UIKit
    /// may deliver pinch.ended before *or* after pan.ended.
    mutating func endPan(coast: Bool) -> Bool {
        panActive = false
        let shouldCoast = coast && !zoomCommitted
        if !pinchActive { zoomCommitted = false }
        return shouldCoast
    }

    mutating func endPinch() {
        pinchActive = false
        if !panActive { zoomCommitted = false }
    }

    /// A lift may arrive after UIPan has started momentum. Only a new
    /// contact should stop it; ended/cancelled are not new contacts.
    static func touchShouldStopMomentum(_ phase: String) -> Bool {
        phase == "began"
    }
}
