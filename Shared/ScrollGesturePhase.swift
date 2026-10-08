// Native NSEvent.Phase flags; shared for hostless regression tests.
enum ScrollGesturePhase: String {
    case began, changed, ended, cancelled
    var cgValue: Int64 {
        switch self {
        case .began: return 1
        case .changed: return 4
        case .ended: return 8
        case .cancelled: return 16
        }
    }
}
