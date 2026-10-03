import CoreGraphics
import AppKit
import Darwin
import Dispatch

/// System double-click thresholds. Interval is public API; distance is read from
/// AppKit's `NSDoubleClickDistance()` (same value the Window Server uses).
private enum SystemClickMetrics {
    static var interval: TimeInterval { NSEvent.doubleClickInterval }

    static var distance: CGFloat {
        doubleClickDistanceFn?() ?? 4
    }

    private typealias DoubleClickDistanceFn = @convention(c) () -> CGFloat
    private static let doubleClickDistanceFn: DoubleClickDistanceFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY),
              let sym = dlsym(handle, "NSDoubleClickDistance") else { return nil }
        return unsafeBitCast(sym, to: DoubleClickDistanceFn.self)
    }()
}

/// Turns normalized touch coordinates from the phone into mouse events on a
/// target display. Touch semantics: finger down = left button down, finger
/// move = drag, finger up = button up — i.e. the phone acts as a touchscreen.
final class InputInjector {

    private let displayID: CGDirectDisplayID
    private var isDown = false
    private var penDown = false
    // A real event source (vs nil) plus non-zero clickState on down/up: menu
    // tracking treats sourceless/zero-click synthetic clicks as malformed — menus
    // open but their tracking session breaks, leaving zombie menu windows
    // composited on the display (visible in the stream, unclickable).
    private let source = CGEventSource(stateID: .hidSystemState)
    // Synthetic OpenAirDisplay tablet — conspicuous in logs; not Wacom (0x056A) or
    // typical small driver IDs (1, 2, …).
    private let tabletVendorID: Int64 = 0x0D15       // "ODIS"
    private let tabletProductID: Int64 = 0x0101
    private let deviceID: Int64 = 424242
    private let pointerID: Int64 = 0x0D02              // pen tip
    private let vendorPointerType: Int64 = 0x0802    // Grip Pen (what apps expect)
    private let capabilityMask: Int64 = 0x05C7       // pressure + tilt + rotation + buttons
    private var inRange = false
    // Space switching: one swipe per animation, see handleSpaceSwitch.
    private var lastSpaceSwitch: CFAbsoluteTime = 0
    private let spaceSwitchCooldown: CFTimeInterval = 0.6
    // Confirming a switch means reading the layout back after the animation,
    // which has no business happening on the control channel's thread.
    private let spaceVerifyQueue = DispatchQueue(label: "space-switch-verify")
    // Guards the cooldown clock, which the control channel and the switch
    // queue both touch.
    private let stateLock = NSLock()
    // A swipe the phone's fingers are still making: it arrives as a stream of
    // positions rather than one message. See handleSpaceDrag.
    private var dragTravel: Double?
    private var dragMethod: SpaceSwitchMethod = .dockSwipe
    private var dragPosted: Double = 0
    private var dragPostedAt: CFAbsoluteTime = 0
    private var dragLastStep: Double = 0
    private var dragSpeed: Double = 0
    private var dragSpaces = 2
    private var dragStart: (count: Int, current: Int)?
    // Bumped per gesture, so a verification that outlived its swipe knows not
    // to act on what the next one did.
    private var dragGeneration: UInt64 = 0
    // Whether a followed swipe has ever landed on this system, which is what
    // decides if the one-shot chain is still worth trying.
    private lazy var dragHasLanded = UserDefaults.standard.bool(forKey: Self.dragLandedKey)
    // Drag events go out in order and off the control channel's thread: the
    // Dock reads a swipe as a sequence, and a reordered one reads as two half
    // gestures.
    private let spaceDragQueue = DispatchQueue(label: "space-drag")

    // Pencil-only synthetic click counting — tablet events don't get click
    // state from the Window Server, so we mirror macOS double-click prefs here.
    private struct PenClickSession {
        let downLocation: CGPoint
        let clickState: Int
    }

    private struct PenCompletedClick {
        let upTime: CFAbsoluteTime
        let downLocation: CGPoint
        let clickState: Int
    }

    private var penClickSession: PenClickSession?
    private var penLastClick: PenCompletedClick?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    static func ensureAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            Log.info("Accessibility permission missing — prompt requested")
        }
        return trusted
    }

    /// x/y are normalized [0,1] in video space (origin top-left).
    func handleTouch(phase: String, x: Double, y: Double) {
        let bounds = CGDisplayBounds(displayID)   // global CG coords, y-down
        let point = CGPoint(
            x: bounds.origin.x + x * bounds.width,
            y: bounds.origin.y + y * bounds.height
        )

        let type: CGEventType
        // Click count on the release. A cancel means "a second finger joined,
        // this was a scroll, not a tap" — but there is no CGEvent for undoing a
        // press, and a plain up over the press point is indistinguishable from a
        // click, so every two-finger scroll opened whatever was under finger one.
        // Releasing with clickCount 0 keeps the button state honest while telling
        // AppKit and WebKit not to synthesize a click. Only the cancel path gets
        // 0: a zero-click *down* is what breaks menu tracking (see above).
        var clickState = 1
        switch phase {
        case "began":
            type = .leftMouseDown
            isDown = true
        case "moved":
            type = isDown ? .leftMouseDragged : .mouseMoved
        case "ended":
            guard isDown else { return }   // spurious up without a down
            type = .leftMouseUp
            isDown = false
        case "cancelled":
            guard isDown else { return }
            type = .leftMouseUp
            isDown = false
            clickState = 0
        default:
            return
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }

    /// dx/dy in display pixels, natural-scrolling sign from the phone.
    /// Scroll events take points, so convert via the display's pixel scale.
    func handleScroll(dx: Double, dy: Double) {
        let bounds = CGDisplayBounds(displayID)
        let scale = bounds.width > 0 ? Double(CGDisplayPixelsWide(displayID)) / bounds.width : 2
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32((dy / scale).rounded()),
                                  wheel2: Int32((dx / scale).rounded()),
                                  wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    // Which injection method is known to work on this machine, and whether it
    // reports swipe direction inverted. Both differ by macOS version and are
    // cheaper to discover at runtime than to predict.
    private static let preferredMethodKey = "spaceSwitchMethod"
    private static let flippedDirectionKey = "spaceSwitchDirectionFlipped"
    private static let dragLandedKey = "spaceDragLanded"
    /// Release speed, in spaces a second, that commits a swipe however short it
    /// was: the difference between letting go of a drag and flicking it.
    private static let flickSpeed = 1.5
    private lazy var preferredMethod = SpaceSwitchMethod(
        rawValue: UserDefaults.standard.string(forKey: Self.preferredMethodKey) ?? "")
    private lazy var directionIsFlipped =
        UserDefaults.standard.bool(forKey: Self.flippedDirectionKey)

    /// Switch the Space (virtual desktop) shown on *this* display, from the
    /// phone's three-finger swipe. direction is "left" or "right".
    ///
    /// There is no public per-display Spaces API, and the private one
    /// (SLSManagedDisplaySetCurrentSpace) only takes effect from inside Dock —
    /// that is what tiling window managers ship a scripting addition for, and
    /// it needs SIP partially disabled, which a display driver has no business
    /// requiring.
    ///
    /// What is left is replaying what a trackpad sends, with the cursor parked
    /// on our display so the system applies it here. Two mechanisms exist and
    /// which one works depends on the macOS version and on settings we do not
    /// control, so try them in turn and keep whichever lands:
    ///
    /// 1. A synthetic dock swipe (private CGS event type 30) — the gesture the
    ///    trackpad itself produces, so it depends on no shortcut being
    ///    assigned. It is sent as a gradual drag, which is what makes the
    ///    Dock animate the desktops sliding past; the instant form that
    ///    skips the animation is kept as a fallback. macOS 27 validates
    ///    these against a serialized IOHID queue payload, hence the
    ///    variants.
    /// 2. Control+Arrow, which is merely a Mission Control *shortcut*: when it
    ///    is unassigned or taken by another app nothing happens at all, which
    ///    is exactly what the first round of field logs showed.
    func handleSpaceSwitch(direction: String) {
        let right: Bool
        switch direction {
        case "left": right = false
        case "right": right = true
        default: return
        }
        // A swipe plays out over ~0.2s and the switch animates for another
        // ~0.4s, and queued repeats stack into a sprint across every space,
        // so swallow anything that close behind.
        // Attempts are serialized on one queue, which also keeps a slow
        // fallback chain from piling up behind a burst of swipes.
        let now = CFAbsoluteTimeGetCurrent()
        stateLock.lock()
        let tooSoon = now - lastSpaceSwitch <= spaceSwitchCooldown
        if !tooSoon { lastSpaceSwitch = now }
        stateLock.unlock()
        guard !tooSoon else { return }

        spaceVerifyQueue.async { [weak self] in
            self?.switchSpace(requestedRight: right, direction: direction)
        }
    }

    /// Which dock-swipe encoding can follow fingers, or nil when this system is
    /// known to need the one-shot path instead: a flick hands the whole swipe
    /// over at once and the keyboard shortcut has no notion of a gesture in
    /// progress, so neither can track anything.
    private var liveDragMethod: SpaceSwitchMethod? {
        switch preferredMethod {
        case .some(.dockSwipe): return .dockSwipe
        case .some(.dockSwipeWithPayload): return .dockSwipeWithPayload
        case .some(.dockSwipeFlick), .some(.dockSwipeWithPayloadFlick),
             .some(.missionControlShortcut):
            return nil
        case .none:
            return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
                ? .dockSwipeWithPayload : .dockSwipe
        }
    }

    /// A swipe in progress on the phone. `progress` is how far it has travelled
    /// in spaces (1 is a whole desktop), positive towards the space on the
    /// right; `phase` says whether the fingers just started moving, moved,
    /// lifted, or gave up.
    ///
    /// Streaming it is what makes the desktops follow the fingers: moving
    /// slowly slides slowly, reversing slides back, and lifting short of the
    /// commit distance snaps back without switching. macOS decides whether a
    /// release commits, exactly as it does for a trackpad — we only report the
    /// gesture it would have seen.
    func handleSpaceDrag(phase: String, progress: Double, velocity: Double) {
        let requested = max(-1.0, min(1.0, progress))
        let travel = directionIsFlipped ? -requested : requested
        let speed = directionIsFlipped ? -velocity : velocity
        switch phase {
        case "began":
            beginDrag()
        case "changed":
            updateDrag(travel: travel)
        case "ended", "cancelled":
            // A flick can be over before it has covered any distance, so where
            // it was heading comes from the speed when the travel says nothing.
            let wantsRight = abs(requested) >= 0.02 ? requested > 0 : velocity > 0
            endDrag(travel: travel, speed: speed, requestedRight: wantsRight,
                    cancelled: phase == "cancelled")
        default:
            return
        }
    }

    /// Three fingers swiped up, or down to leave again. Mission Control is one
    /// view of every display at once rather than something that happens on one
    /// of them, so this needs no pointer warp and no per-display scoping.
    func handleMissionControl(show: Bool) {
        guard show else {
            dismissOverlay("mission control")
            return
        }
        if DockOverlay.missionControl() {
            Log.info("mission control: opened through the Dock")
            return
        }
        // Mission Control answers to Control plus Up out of the box, so this
        // needs nothing assigned on most systems.
        postKey(virtualKey: 0x3B, keyDown: true, flags: .maskControl)
        postKey(virtualKey: 126, keyDown: true, flags: .maskControl)  // kVK_UpArrow
        postKey(virtualKey: 126, keyDown: false, flags: .maskControl)
        postKey(virtualKey: 0x3B, keyDown: false, flags: [])
        Log.info("mission control: the Dock entry point is unavailable, so posted"
                 + " Control+Up instead")
    }

    /// Three fingers pinched in, or spread back out to leave again.
    func handleLaunchpad(show: Bool) {
        guard show else {
            dismissOverlay("launchpad")
            return
        }
        if DockOverlay.launchpad() {
            Log.info("launchpad: opened through the Dock")
            return
        }
        Log.info("launchpad: the Dock entry point is unavailable, and Launchpad"
                 + " has no shortcut of its own to fall back on")
    }

    /// Escape leaves Mission Control and Launchpad alike. Asking the Dock to
    /// toggle them would be the tidier exit, but whether either is on screen is
    /// not readable from outside the Dock, so a toggle aimed at closing one
    /// would open it on any guess that was wrong. Escape can only ever close.
    private func dismissOverlay(_ what: String) {
        postKey(virtualKey: 0x35, keyDown: true, flags: [])   // kVK_Escape
        postKey(virtualKey: 0x35, keyDown: false, flags: [])
        Log.info("\(what): closed with Escape")
    }

    private func beginDrag() {
        guard dragTravel == nil, let method = liveDragMethod else { return }
        // A gesture can be the first thing a session sees, and the Window
        // Server applies a swipe to whichever display the cursor sits on.
        let bounds = CGDisplayBounds(displayID)
        if !bounds.contains(currentCursor()) {
            CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
            usleep(15_000)
        }
        let start = Spaces.layout(of: displayID)
        if let start, start.count < 2 {
            Log.info("space drag ignored: this display has one space. Add one in"
                     + " Mission Control (hover the top of this screen, then +).")
            return
        }
        dragStart = start
        dragMethod = method
        dragSpaces = start?.count ?? 2
        dragTravel = 0
        dragPosted = 0
        dragPostedAt = 0
        dragLastStep = 0
        dragSpeed = 0
        stateLock.lock()
        dragGeneration &+= 1
        stateLock.unlock()
        if let start {
            Log.info("space drag: space \(start.current) of \(start.count)")
        }
        postDrag(.began, travel: 0, lastStep: 0)
    }

    private func postDrag(_ phase: DockSwipe.Phase, travel: Double, lastStep: Double) {
        let spaces = dragSpaces
        let payload = dragMethod.carriesPayload
        spaceDragQueue.async {
            DockSwipe.drag(phase: phase, travel: travel, lastStep: lastStep,
                           spaces: spaces, withPayload: payload)
        }
    }

    /// Takes a released gesture the rest of the way rather than leaving the
    /// outcome to be inferred from the exit speed: a committed swipe slides out
    /// to a whole space and ends there, and one that is staying put slides back
    /// to where it started and is cancelled. Same gesture, same result, every
    /// time, and the slide keeps the animation the fingers were drawing.
    private func settleDrag(from travel: Double, committed: Bool, right: Bool) {
        let target = committed ? (right ? 1.0 : -1.0) : 0.0
        let spaces = dragSpaces
        let payload = dragMethod.carriesPayload
        spaceDragQueue.async {
            let steps = 4
            let increment = (target - travel) / Double(steps)
            for step in 1...steps {
                DockSwipe.drag(phase: .changed,
                               travel: travel + increment * Double(step),
                               lastStep: increment, spaces: spaces,
                               withPayload: payload)
                usleep(12_000)
            }
            DockSwipe.drag(phase: committed ? .ended : .cancelled, travel: target,
                           lastStep: committed ? increment : 0, spaces: spaces,
                           withPayload: payload)
        }
    }

    private func updateDrag(travel: Double) {
        guard dragTravel != nil else { return }
        dragTravel = travel
        // The phone reports every touch move, which can be twice a display
        // refresh, and the payload encoding rebuilds a serialized event each
        // time. A frame's worth of movement is as much as the Dock can draw,
        // and anything finer only costs the gesture latency.
        let now = CFAbsoluteTimeGetCurrent()
        let step = travel - dragPosted
        let minimumGap = dragMethod.carriesPayload ? 0.010 : 0.004
        guard now - dragPostedAt >= minimumGap, abs(step) >= 0.0005 else { return }
        if dragPostedAt > 0 { dragSpeed = step / (now - dragPostedAt) }
        dragPosted = travel
        dragPostedAt = now
        dragLastStep = step
        postDrag(.changed, travel: travel, lastStep: step)
    }

    /// The fingers lifted, or the gesture gave up. Two things commit the
    /// switch: letting go past half a desktop, or still moving faster than a
    /// flick, however short the swipe was. Anything else slides back.
    private func endDrag(travel: Double, speed: Double, requestedRight: Bool,
                         cancelled: Bool) {
        guard dragTravel != nil else { return }
        // A pause before the lift is a deliberate stop, so only a fresh sample
        // counts as the speed the fingers left with. A phone that reports none
        // leaves the stream itself to be measured.
        let stale = CFAbsoluteTimeGetCurrent() - dragPostedAt > 0.1
        let released = speed != 0 ? speed : (stale ? 0 : dragSpeed)
        let flicked = abs(released) >= Self.flickSpeed
        let committed = !cancelled && (abs(travel) >= 0.5 || flicked)
        let right = abs(travel) >= 0.02 ? travel > 0 : released > 0
        settleDrag(from: travel, committed: committed, right: right)
        let start = dragStart
        let method = dragMethod
        dragTravel = nil
        dragStart = nil
        // Count the gesture against the one-shot cooldown, so a stale
        // `spaceSwitch` for the same swipe cannot switch a second time.
        stateLock.lock()
        lastSpaceSwitch = CFAbsoluteTimeGetCurrent()
        let generation = dragGeneration
        stateLock.unlock()
        let distance = String(format: "%.2f", abs(travel))
        let pace = String(format: "%.1f", abs(released))
        guard committed else {
            if !cancelled {
                Log.info("space drag let go at \(distance) of a space at \(pace)"
                         + " spaces a second, so it slid back without switching")
            }
            return
        }
        guard let start else { return }
        // macOS does not wrap around, so a swipe off either end of the row did
        // nothing because there was nothing to do.
        if (right && start.current == start.count) || (!right && start.current == 1) {
            Log.info("space drag: already at the \(right ? "last" : "first") space on"
                     + " this display")
            return
        }
        Log.info("space drag committed at \(distance) of a space at \(pace) spaces a"
                 + " second\(flicked && abs(travel) < 0.5 ? ", as a flick" : "")")
        spaceVerifyQueue.async { [weak self] in
            self?.confirmDrag(from: start, requestedRight: requestedRight,
                              method: method, generation: generation)
        }
    }

    /// What a committed drag actually did. A system that has followed one
    /// before is not suddenly ignoring them, so the one-shot chain only steps
    /// in while nothing has ever landed: replaying a swipe that merely looked
    /// like it failed is what makes one gesture switch twice.
    private func confirmDrag(from start: (count: Int, current: Int),
                             requestedRight: Bool, method: SpaceSwitchMethod,
                             generation: UInt64) {
        if let after = settledLayout(differingFrom: start) {
            Log.info("space drag landed via \(method.summary): space"
                     + " \(after.current) of \(after.count)")
            remember(method)
            rememberDragFollows()
            calibrate(requestedRight: requestedRight, before: start, after: after)
            return
        }
        stateLock.lock()
        let followedBefore = dragHasLanded
        let superseded = dragGeneration != generation
        stateLock.unlock()
        guard !followedBefore, !superseded else {
            Log.info("space drag stayed put: still space \(start.current) of"
                     + " \(start.count)")
            return
        }
        Log.info("space drag had no effect: replaying it as a single swipe")
        switchSpace(requestedRight: requestedRight,
                    direction: requestedRight ? "right" : "left")
    }

    private func rememberDragFollows() {
        stateLock.lock()
        let known = dragHasLanded
        dragHasLanded = true
        stateLock.unlock()
        guard !known else { return }
        UserDefaults.standard.set(true, forKey: Self.dragLandedKey)
    }

    private func switchSpace(requestedRight: Bool, direction: String) {
        // During a touch gesture the cursor already sits on this display, but a
        // swipe can also be the first thing a session sees. The Window Server
        // needs a moment to register a warp before anything lands.
        let bounds = CGDisplayBounds(displayID)
        if !bounds.contains(currentCursor()) {
            CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
            usleep(15_000)
        }
        if SpacesSettings.spansDisplays {
            Log.info("space switch: \"Displays have separate Spaces\" is off, so one space"
                     + " spans every screen (System Settings > Desktop & Dock; the change"
                     + " needs a log out).")
        }

        let right = requestedRight != directionIsFlipped
        guard let before = Spaces.layout(of: displayID) else {
            // Without a layout there is nothing to verify against, so post the
            // most likely method and leave it at that.
            Log.info("space switch \(direction): space layout unavailable")
            if let method = methodOrder.first { post(method, right: right, spaces: 2) }
            return
        }
        Log.info("space switch \(direction): space \(before.current) of \(before.count)")
        // A display with a single space has nothing to switch to, which looks
        // exactly like a broken gesture. Say so instead of posting into a void.
        if before.count < 2 {
            Log.info("space switch ignored: this display has one space. Add one in"
                     + " Mission Control (hover the top of this screen, then +).")
            return
        }
        // macOS does not wrap around, so at either end there is nothing to do
        // and a silent no-op would read as a failure.
        if (right && before.current == before.count) || (!right && before.current == 1) {
            Log.info("space switch \(direction): already at the"
                     + " \(right ? "last" : "first") space on this display")
            return
        }

        for method in methodOrder {
            post(method, right: right, spaces: before.count)
            guard let after = settledLayout(differingFrom: before) else { continue }
            Log.info("space switch landed via \(method.summary): space \(after.current)"
                     + " of \(after.count)")
            remember(method)
            calibrate(requestedRight: requestedRight, before: before, after: after)
            return
        }
        Log.info("space switch had no effect: a dock swipe and the keyboard shortcut were"
                 + " both ignored. \(Hotkeys.spaceSwitchDiagnosis())")
    }

    /// The space counter flips partway through the switch, and a gradual swipe
    /// takes longer to play out than an instant one, so poll rather than bet on
    /// a single deadline.
    private func settledLayout(differingFrom before: (count: Int, current: Int))
        -> (count: Int, current: Int)? {
        for _ in 0..<8 {
            usleep(100_000)
            if let now = Spaces.layout(of: displayID), now.current != before.current {
                return now
            }
        }
        return nil
    }

    /// Methods to try, best bet first.
    private var methodOrder: [SpaceSwitchMethod] {
        // Both encodings are tried as a gradual drag before either is tried as
        // an instant flick, because a flick switches without animating.
        // macOS 27 rejects a dock swipe that carries no IOHID payload and
        // earlier versions do not expect one, so lead with whichever matches
        // this system.
        var order: [SpaceSwitchMethod] =
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
                ? [.dockSwipeWithPayload, .dockSwipe, .dockSwipeWithPayloadFlick,
                   .dockSwipeFlick, .missionControlShortcut]
                : [.dockSwipe, .dockSwipeWithPayload, .dockSwipeFlick,
                   .dockSwipeWithPayloadFlick, .missionControlShortcut]
        if let preferredMethod, let index = order.firstIndex(of: preferredMethod) {
            order.remove(at: index)
            order.insert(preferredMethod, at: 0)
        }
        return order
    }

    private func post(_ method: SpaceSwitchMethod, right: Bool, spaces: Int) {
        guard method != .missionControlShortcut else {
            postSpaceShortcut(right: right)
            return
        }
        DockSwipe.post(right: right, withPayload: method.carriesPayload,
                       flick: method.isFlick, spaces: spaces)
    }

    private func postSpaceShortcut(right: Bool) {
        // A real keyboard brackets the arrow with the modifier's own key
        // events. The Window Server's hotkey layer reads that live modifier
        // state, and an arrow carrying nothing but `flags` is the pattern that
        // Cmd-Tab and the Spaces shortcuts are known to ignore.
        let keyCode: CGKeyCode = right ? 124 : 123   // kVK_Right/LeftArrow
        postKey(virtualKey: 0x3B, keyDown: true, flags: .maskControl)   // kVK_Control
        postKey(virtualKey: keyCode, keyDown: true, flags: .maskControl)
        postKey(virtualKey: keyCode, keyDown: false, flags: .maskControl)
        postKey(virtualKey: 0x3B, keyDown: false, flags: [])
    }

    private func remember(_ method: SpaceSwitchMethod) {
        guard preferredMethod != method else { return }
        preferredMethod = method
        UserDefaults.standard.set(method.rawValue, forKey: Self.preferredMethodKey)
    }

    /// A swipe that moved the wrong way is a sign convention we guessed wrong,
    /// not a user error: flip it and remember, rather than asking anyone to
    /// live with inverted gestures.
    private func calibrate(requestedRight: Bool,
                           before: (count: Int, current: Int),
                           after: (count: Int, current: Int)) {
        guard (after.current > before.current) != requestedRight else { return }
        directionIsFlipped.toggle()
        UserDefaults.standard.set(directionIsFlipped, forKey: Self.flippedDirectionKey)
        Log.info("space switch: this system reports swipe direction inverted, flipping it"
                 + " from here on")
    }

    private func postKey(virtualKey: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: virtualKey, keyDown: keyDown) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    func handleProximity(entering: Bool, x: Double, y: Double) {
        setProximity(entering: entering, at: screenPoint(nx: x, ny: y))
    }

    func handlePencil(phase: String, x: Double, y: Double,
                      pressure: Double, azimuth: Double, altitude: Double,
                      rotation: Double) {
        // TODO: Wire Apple Pencil Pro barrel roll (UIKit rollAngle) once hardware
        // is available for testing. rotation on the wire is always 0 for now.
        _ = rotation
        let p = screenPoint(nx: x, ny: y)
        if phase == "down", !inRange {
            setProximity(entering: true, at: p)
        }
        let (tiltX, tiltY) = deriveTilt(azimuth: azimuth, altitude: altitude)

        switch phase {
        case "down":
            postTabletPoint(phase: .down, x: x, y: y, pressure: pressure,
                            tiltX: tiltX, tiltY: tiltY, rotation: 0)
            penDown = true
        case "move":
            if penDown {
                postTabletPoint(phase: .drag, x: x, y: y, pressure: pressure,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            } else {
                postTabletPoint(phase: .hover, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            }
        case "up":
            if penDown {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
                penDown = false
            }
        case "hover":
            if penDown {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
                penDown = false
            }
            postTabletPoint(phase: .hover, x: x, y: y, pressure: 0,
                            tiltX: tiltX, tiltY: tiltY, rotation: 0)
        default:
            return
        }
    }

    private func setProximity(entering: Bool, at p: CGPoint) {
        guard entering != inRange else { return }
        inRange = entering
        postProximityEvent(entering: entering, at: p)
    }

    private func postProximityEvent(entering: Bool, at p: CGPoint) {
        guard let ev = CGEvent(source: source) else { return }
        ev.type = .tabletProximity
        ev.location = p
        ev.setIntegerValueField(.tabletProximityEventVendorID, value: tabletVendorID)
        ev.setIntegerValueField(.tabletProximityEventTabletID, value: tabletProductID)
        ev.setIntegerValueField(.tabletProximityEventPointerID, value: pointerID)
        ev.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        ev.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        ev.setIntegerValueField(.tabletProximityEventPointerType, value: entering ? 1 : 0)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerType, value: vendorPointerType)
        ev.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
        ev.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        ev.flags = .maskNonCoalesced
        ev.post(tap: .cghidEventTap)
    }

    private enum PointPhase { case down, drag, up, hover }

    private func postTabletPoint(phase: PointPhase, x: Double?, y: Double?,
                                 pressure: Double, tiltX: Double, tiltY: Double,
                                 rotation: Double) {
        let p: CGPoint
        if let nx = x, let ny = y { p = screenPoint(nx: nx, ny: ny) }
        else { p = currentCursor() }

        let type: CGEventType
        switch phase {
        case .down:  type = .leftMouseDown
        case .drag:  type = .leftMouseDragged
        case .up:    type = .leftMouseUp
        case .hover: type = .mouseMoved
        }

        guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: p, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventDeltaX, value: 0)
        ev.setIntegerValueField(.mouseEventDeltaY, value: 0)
        ev.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        ev.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        ev.setDoubleValueField(.mouseEventPressure, value: pressure)
        ev.setIntegerValueField(.tabletEventPointPressure, value: Int64((pressure * 65535.0).rounded()))
        ev.setDoubleValueField(.tabletEventTiltX, value: tiltX)
        ev.setDoubleValueField(.tabletEventTiltY, value: tiltY)
        ev.setDoubleValueField(.tabletEventRotation, value: rotation)
        switch phase {
        case .down:
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(beginPenClickSession(at: p)))
        case .up:
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(finishPenClickSession(at: p)))
        case .drag, .hover:
            break
        }
        ev.flags = .maskNonCoalesced
        ev.post(tap: .cghidEventTap)
    }

    private func penClickStateForMouseDown(at point: CGPoint) -> Int {
        let now = CFAbsoluteTimeGetCurrent()
        guard let last = penLastClick,
              now - last.upTime <= SystemClickMetrics.interval else {
            return 1
        }
        let dx = point.x - last.downLocation.x
        let dy = point.y - last.downLocation.y
        guard hypot(dx, dy) <= SystemClickMetrics.distance else { return 1 }
        return last.clickState + 1
    }

    private func beginPenClickSession(at point: CGPoint) -> Int {
        let state = penClickStateForMouseDown(at: point)
        penClickSession = PenClickSession(downLocation: point, clickState: state)
        return state
    }

    /// Returns click state for the matching pen mouse-up. Extends the multi-click
    /// chain only when down→up displacement is within the system threshold.
    private func finishPenClickSession(at upLocation: CGPoint) -> Int {
        guard let session = penClickSession else { return 1 }
        penClickSession = nil

        let dx = upLocation.x - session.downLocation.x
        let dy = upLocation.y - session.downLocation.y
        if hypot(dx, dy) <= SystemClickMetrics.distance {
            penLastClick = PenCompletedClick(
                upTime: CFAbsoluteTimeGetCurrent(),
                downLocation: session.downLocation,
                clickState: session.clickState
            )
        } else {
            penLastClick = nil
        }
        return session.clickState
    }

    /// UIKit altitude is radians from the surface (pi/2 = upright); CGEvent tilt
    /// is a unit vector in -1...1, so normalize rather than pass radians through
    /// (unnormalized, a flat pen reads 1.57 and apps that scale tilt by 90 report
    /// impossible angles).
    private func deriveTilt(azimuth: Double, altitude: Double) -> (Double, Double) {
        let mag = min(max(0, Double.pi / 2 - altitude) / (Double.pi / 2), 1)
        return (sin(azimuth) * mag, cos(azimuth) * mag)
    }

    private func screenPoint(nx: Double, ny: Double) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(x: bounds.minX + nx * bounds.width,
                       y: bounds.minY + ny * bounds.height)
    }

    private func currentCursor() -> CGPoint {
        CGEvent(source: source)?.location ?? .zero
    }
}

/// Read-only Spaces lookup. Reading the layout needs nothing special — it is
/// only *changing* a space from outside Dock that requires a scripting
/// addition — so the SkyLight symbols are resolved lazily and every failure
/// degrades to "unknown" rather than to a crash on the next macOS.
/// Mission Control and Launchpad, through the notifications the Dock itself
/// listens for: the same path F3, F4 and the trackpad gestures end up taking,
/// and unlike a gesture they need nothing bound in Keyboard Shortcuts. Both
/// notifications toggle whatever they name, so they are only ever asked to
/// open; closing goes through Escape, which cannot open anything by mistake.
private enum DockOverlay {
    private typealias SendNotificationFn = @convention(c) (CFString, Int32) -> Void

    private static let handles = [
        dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks"
               + "/HIServices.framework/HIServices", RTLD_LAZY),
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
               RTLD_LAZY),
    ]

    private static let sendNotification: SendNotificationFn? = {
        for handle in handles {
            guard let handle, let address = dlsym(handle, "CoreDockSendNotification")
            else { continue }
            return unsafeBitCast(address, to: SendNotificationFn.self)
        }
        return nil
    }()

    static func missionControl() -> Bool { send("com.apple.expose.awake") }

    static func launchpad() -> Bool { send("com.apple.launchpad.toggle") }

    /// True once the request has gone out, which is as much as this entry point
    /// reports: it returns nothing, and what the Dock is showing is not
    /// readable from outside it.
    private static func send(_ name: String) -> Bool {
        guard let sendNotification else { return false }
        sendNotification(name as CFString, 0)
        return true
    }
}

private enum Spaces {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    private static let mainConnection = symbol("SLSMainConnectionID", as: MainConnectionFn.self)
    private static let copyDisplaySpaces = symbol("SLSCopyManagedDisplaySpaces",
                                                  as: CopyDisplaySpacesFn.self)

    private static func spaceID(_ space: [String: Any]) -> Int64? {
        (space["ManagedSpaceID"] as? NSNumber ?? space["id64"] as? NSNumber)?.int64Value
    }

    /// How many spaces a display holds and which one it is showing (1-based),
    /// or nil when the lookup is unavailable or the display is not listed.
    static func layout(of displayID: CGDirectDisplayID) -> (count: Int, current: Int)? {
        guard let mainConnection, let copyDisplaySpaces,
              let displays = copyDisplaySpaces(mainConnection())?.takeRetainedValue()
                  as? [[String: Any]],
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let uuidString = CFUUIDCreateString(nil, uuid)
        else { return nil }
        let identifier = uuidString as String
        // The main display is listed under a placeholder on some versions.
        let isMain = CGDisplayIsMain(displayID) != 0
        for display in displays {
            let name = display["Display Identifier"] as? String
            guard name == identifier || (isMain && name == "Main") else { continue }
            guard let spaces = display["Spaces"] as? [[String: Any]], !spaces.isEmpty
            else { return nil }
            let currentID = (display["Current Space"] as? [String: Any]).flatMap(spaceID)
            let index = spaces.firstIndex { spaceID($0) == currentID }
            return (spaces.count, (index ?? 0) + 1)
        }
        return nil
    }
}

/// The Spaces preference that decides whether a per-display switch is even a
/// coherent request. Read live: it is a setting the user can change under us.
private enum SpacesSettings {
    /// True when one space spans all displays, i.e. "Displays have separate
    /// Spaces" is off.
    static var spansDisplays: Bool {
        CFPreferencesAppSynchronize("com.apple.spaces" as CFString)
        let value = CFPreferencesCopyAppValue("spans-displays" as CFString,
                                              "com.apple.spaces" as CFString)
        return (value as? NSNumber)?.boolValue ?? false
    }
}

/// Why a posted ⌃← / ⌃→ might have gone nowhere, phrased for the log.
private enum Hotkeys {
    private static let controlMask = 0x04_0000
    private static let arrowKeys: Set<Int> = [123, 124]  // kVK_Left/RightArrow

    /// The published table of symbolic hotkey IDs shifts between releases, so
    /// this matches on what each entry is *bound to* instead: an entry on
    /// Control plus an arrow is a space switch whatever its ID happens to be.
    static func spaceSwitchDiagnosis() -> String {
        guard AXIsProcessTrusted() else {
            return "Accessibility access is not granted, so the Window Server drops our"
                + " keys (System Settings > Privacy & Security > Accessibility)."
        }
        // Another process owns this domain, so make sure we are not reading a
        // cached copy from before the user changed the setting.
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        guard let entries = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                      "com.apple.symbolichotkeys" as CFString)
                as? [String: Any]
        else { return "The keyboard shortcut settings could not be read." }

        var bound = false
        for case let entry as [String: Any] in entries.values {
            guard let parameters = (entry["value"] as? [String: Any])?["parameters"]
                      as? [NSNumber],
                  parameters.count >= 3,
                  arrowKeys.contains(parameters[1].intValue),
                  parameters[2].intValue & controlMask != 0
            else { continue }
            bound = true
            if (entry["enabled"] as? Bool) ?? true {
                return "The Mission Control shortcut is enabled, so the Window Server"
                    + " declined the synthetic keys — worth reporting with this log."
            }
        }
        return bound
            ? "Mission Control's \"Move left/right a space\" shortcut is turned off: switch"
                + " it on in System Settings > Keyboard > Keyboard Shortcuts > Mission Control."
            : "Nothing is bound to Control plus an arrow key: assign \"Move left/right a"
                + " space\" in System Settings > Keyboard > Keyboard Shortcuts > Mission Control."
    }
}

/// How a space switch can be delivered, in the order of how much of the system
/// has to cooperate. Raw values are persisted, so leave them alone.
private enum SpaceSwitchMethod: String {
    case dockSwipe = "dock-swipe"
    case dockSwipeFlick = "dock-swipe-flick"
    case dockSwipeWithPayload = "dock-swipe-payload"
    case dockSwipeWithPayloadFlick = "dock-swipe-payload-flick"
    case missionControlShortcut = "control-arrow"

    /// Whether the whole swipe is handed over at once, which switches
    /// immediately and so skips the transition animation.
    var isFlick: Bool { self == .dockSwipeFlick || self == .dockSwipeWithPayloadFlick }

    var carriesPayload: Bool {
        self == .dockSwipeWithPayload || self == .dockSwipeWithPayloadFlick
    }

    var summary: String {
        switch self {
        case .dockSwipe: return "a dock swipe"
        case .dockSwipeFlick: return "an instant dock swipe"
        case .dockSwipeWithPayload: return "a dock swipe with an IOHID payload"
        case .dockSwipeWithPayloadFlick:
            return "an instant dock swipe with an IOHID payload"
        case .missionControlShortcut: return "the Control+Arrow shortcut"
        }
    }
}

/// A synthetic trackpad dock swipe: the gesture a trackpad itself sends to the
/// Dock, which is what makes it independent of whatever the user has bound in
/// Keyboard Shortcuts. The field tags are the private CGS gesture tags that
/// yabai, FasterSwiper and InstantSpaceSwitcher all converged on.
///
/// The fields are set through dlsym'd CoreGraphics entry points rather than
/// `CGEvent.setIntegerValueField`, because these tag numbers have no
/// `CGEventField` case to name them and the Swift enum would have to be
/// force-unwrapped from a raw value.
private enum DockSwipe {
    private static let eventType: UInt32 = 55         // kCGSEventTypeField
    private static let hidType: UInt32 = 110          // kCGEventGestureHIDType
    private static let scrollY: UInt32 = 119
    private static let swipeMotion: UInt32 = 123      // horizontal vs vertical
    private static let swipeProgress: UInt32 = 124
    private static let positionX: UInt32 = 125
    private static let velocityX: UInt32 = 129
    private static let velocityY: UInt32 = 130
    private static let phaseField: UInt32 = 132
    private static let phaseAlias: UInt32 = 134
    private static let scrollFlagBits: UInt32 = 135
    private static let zoomDeltaY: UInt32 = 138
    private static let zoomDeltaX: UInt32 = 139       // required, reason unknown
    private static let sourceProcessAlias: UInt32 = 169
    private static let rawIOHIDPayload: UInt16 = 4205
    private static let gestureTag: UInt32 = 41        // 33231 on every gesture
    private static let inverted: UInt32 = 136         // natural direction flag
    private static let motionAlias: UInt32 = 165

    private static let dockControl: Int64 = 30        // kCGSEventDockControl
    private static let gesture: Int64 = 29            // kCGSEventGesture
    private static let dockSwipeType: Int64 = 23      // kIOHIDEventTypeDockSwipe
    private static let horizontal: Int64 = 1          // kCGGestureMotionHorizontal
    private static let began: Int64 = 1
    private static let changed: Int64 = 2
    private static let ended: Int64 = 4
    private static let cancelled: Int64 = 8
    private static let gestureTagValue: Int64 = 33231
    /// The axis, as the packed bits of the smallest float there is: 1 for
    /// horizontal, 2 for vertical. Fields 119 and 139 both carry it.
    private static let axisBits = Double(Float(bitPattern: 1))

    /// Which part of a swipe an event reports. A cancelled release is how a
    /// trackpad says the fingers gave up, which puts the desktops back.
    enum Phase {
        case began, changed, ended, cancelled

        fileprivate var field: Int64 {
            switch self {
            case .began: return DockSwipe.began
            case .changed: return DockSwipe.changed
            case .ended: return DockSwipe.ended
            case .cancelled: return DockSwipe.cancelled
            }
        }

        fileprivate var releasing: Bool {
            switch self {
            case .ended, .cancelled: return true
            case .began, .changed: return false
            }
        }
    }

    /// How much accumulated offset slides the desktops by one whole space. The
    /// Dock scales a swipe by how many spaces there are to slide past, so the
    /// same travel means more where there are fewer of them.
    private static func offsetForOneSpace(spaces: Int) -> Double {
        spaces <= 1 ? 2.0 : 1.0 + 1.0 / Double(spaces - 1)
    }

    /// Replays a whole swipe with no fingers behind it: began, a run of changed
    /// events, then ended. Each dock-control event travels with the companion
    /// gesture event a trackpad would pair it with.
    ///
    /// A trackpad reports where a swipe has got to and the Dock slides the
    /// desktops to match — that sliding *is* the transition animation. Handing
    /// over the whole distance in one event with a large release speed makes
    /// the switch happen at once instead, so ramp the gesture by default and
    /// keep the instant form for systems that ignore a gradual one.
    static func post(right: Bool, withPayload: Bool, flick: Bool, spaces: Int) {
        let sign: Double = right ? 1 : -1
        guard !flick else {
            // A flick needs a fling to carry it the whole way.
            let release = sign * (withPayload ? 9999.0 : 400.0)
            for phase in [Phase.began, .changed, .ended] {
                send(phase: phase, travel: sign, release: release, spaces: spaces,
                     withPayload: withPayload)
            }
            return
        }
        // Twelve steps over ~0.2s: about as long as a real three-finger swipe
        // takes, and slow enough for the slide to be visible.
        let steps = 12
        send(phase: .began, travel: 0, release: 0, spaces: spaces,
             withPayload: withPayload)
        for step in 1...steps {
            usleep(16_000)
            send(phase: .changed, travel: sign * Double(step) / Double(steps),
                 release: 0, spaces: spaces, withPayload: withPayload)
        }
        // A swipe that already covered a whole space only needs enough release
        // speed to settle in the direction it was going.
        send(phase: .ended, travel: sign,
             release: sign * (withPayload ? 300.0 : 90.0), spaces: spaces,
             withPayload: withPayload)
    }

    /// One event of a swipe that fingers are still making. `travel` is where it
    /// has got to, in spaces, and `lastStep` how far it moved since the event
    /// before, which a release turns into the speed the fingers left with.
    /// Pulling them back shrinks `travel`, so the desktops slide back with
    /// them, and a cancelled release returns them to where they were.
    static func drag(phase: Phase, travel: Double, lastStep: Double, spaces: Int,
                     withPayload: Bool) {
        var release = 0.0
        if phase.releasing {
            // A trackpad reports its exit speed as a hundred times the last
            // step it saw, which is what carries a short flick the rest of the
            // way. The macOS 27 encoding wants a much larger number, so give
            // it the direction and a fixed magnitude.
            release = withPayload
                ? (abs(lastStep) < 0.002 ? 0 : (lastStep < 0 ? -300.0 : 300.0))
                : lastStep * offsetForOneSpace(spaces: spaces) * 100
        }
        send(phase: phase, travel: travel, release: release, spaces: spaces,
             withPayload: withPayload)
    }

    private static func send(phase: Phase, travel: Double, release: Double,
                             spaces: Int, withPayload: Bool) {
        guard let event = make(phase: phase, travel: travel, release: release,
                               spaces: spaces, withPayload: withPayload)
        else { return }
        event.post(tap: .cgSessionEventTap)
        guard let companion = CGEvent(source: nil) else { return }
        setInt(companion, eventType, gesture)
        setInt(companion, gestureTag, gestureTagValue)
        companion.post(tap: .cgSessionEventTap)
    }

    /// `travel` is where the swipe has got to in spaces, positive towards the
    /// space on the right, and `release` the speed the fingers left with, which
    /// only a releasing phase carries.
    ///
    /// The legacy encoding reports the running offset twice over — as a double,
    /// and as the packed bits of the float of the same number — because that
    /// offset is what the Dock slides the desktops to. Reporting each step on
    /// its own instead leaves them sitting still until the release flings them,
    /// which is both invisible and a coin toss. The macOS 27 encoding counts in
    /// spaces, with the opposite sign.
    private static func make(phase: Phase, travel: Double, release: Double,
                             spaces: Int, withPayload: Bool) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        setInt(event, eventType, dockControl)
        setInt(event, hidType, dockSwipeType)
        setInt(event, phaseField, phase.field)
        setInt(event, phaseAlias, phase.field)
        setInt(event, swipeMotion, horizontal)

        guard withPayload else {
            let offset = travel * offsetForOneSpace(spaces: spaces)
            setInt(event, gestureTag, gestureTagValue)
            setInt(event, motionAlias, horizontal)
            setInt(event, inverted, 0)
            setDouble(event, swipeProgress, offset)
            setInt(event, scrollFlagBits,
                   Int64(Int32(bitPattern: Float(offset).bitPattern)))
            setDouble(event, scrollY, axisBits)
            setDouble(event, zoomDeltaX, axisBits)
            if phase.releasing {
                setDouble(event, velocityX, release)
                setDouble(event, velocityY, release)
            }
            return event
        }

        let carried = -travel
        let velocity = phase.releasing ? -release : 0
        setDouble(event, swipeProgress, carried)
        setDouble(event, zoomDeltaY, 3)
        setDouble(event, sourceProcessAlias, Double(mach_absolute_time()))
        setDouble(event, positionX, 0.1)
        if phase.releasing { setDouble(event, velocityX, velocity) }
        return withIOHIDPayload(event, phase: phase.field, progress: carried,
                                positionX: 0.1, velocityX: velocity)
    }

    /// macOS 27 checks a synthetic dock swipe against the serialized IOHID
    /// queue element the real gesture would have carried, in field 4205. That
    /// field cannot be set through any entry point, so append it to the event's
    /// own serialization and rebuild the event from the result.
    private static func withIOHIDPayload(_ event: CGEvent, phase: Int64, progress: Double,
                                         positionX: Double, velocityX: Double) -> CGEvent? {
        guard let cfData = event.data else { return nil }
        let serialized = cfData as Data
        // Only version 2 blobs carry the trailing tag-length-value section.
        guard serialized.count >= 4, serialized[0] == 0, serialized[1] == 0,
              serialized[2] == 0, serialized[3] == 2 else { return nil }
        let payload = iohidPayload(phase: phase, progress: progress, positionX: positionX,
                                   velocityX: velocityX, timestamp: event.timestamp)
        var blob = serialized
        blob.append(UInt8(truncatingIfNeeded: payload.count >> 8))
        blob.append(UInt8(truncatingIfNeeded: payload.count))
        blob.append(UInt8(truncatingIfNeeded: rawIOHIDPayload >> 8))
        blob.append(UInt8(truncatingIfNeeded: rawIOHIDPayload))
        blob.append(payload)
        return CGEvent(withDataAllocator: nil, data: blob as CFData)
    }

    /// One IOHID queue element: a fluid-touch gesture event, plus a velocity
    /// event on the phase that ends the swipe.
    private static func iohidPayload(phase: Int64, progress: Double, positionX: Double,
                                     velocityX: Double, timestamp: UInt64) -> Data {
        let withVelocity = velocityX != 0 || phase == ended
        var payload = Data()
        // Queue element header: timestamp, sender, options, attribute length,
        // event count.
        append(&payload, timestamp == 0 ? mach_absolute_time() : timestamp)
        append(&payload, UInt64(0))
        append(&payload, UInt32(0))
        append(&payload, UInt32(0))
        append(&payload, UInt32(withVelocity ? 2 : 1))
        // Fluid touch gesture: a 16-byte event base, then the gesture body.
        append(&payload, UInt32(40))
        append(&payload, UInt32(23))                  // kIOHIDEventTypeFluidTouchGesture
        append(&payload, UInt32(truncatingIfNeeded: phase) << 24)
        append(&payload, UInt32(0))                   // depth and reserved bytes
        append(&payload, fixed1616(positionX))
        append(&payload, fixed1616(0))
        append(&payload, fixed1616(0))
        append(&payload, UInt32(0))                   // swipe mask
        append(&payload, UInt16(truncatingIfNeeded: horizontal))
        append(&payload, UInt16(3))                   // dock primary flavor
        append(&payload, fixed1616(progress))
        if withVelocity {
            append(&payload, UInt32(28))
            append(&payload, UInt32(9))               // kIOHIDEventTypeVelocity
            append(&payload, UInt32(0))
            append(&payload, UInt32(1))               // depth 1, reserved zero
            append(&payload, fixed1616(velocityX))
            append(&payload, fixed1616(0))
            append(&payload, fixed1616(0))
        }
        return payload
    }

    private static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// IOHID carries these as 16.16 fixed point, and rounds a nonzero value to
    /// the smallest representable one rather than to nothing.
    private static func fixed1616(_ value: Double) -> Int32 {
        let scaled = (value * 65536).rounded(.towardZero)
        guard scaled.isFinite else { return 0 }
        let clamped = min(max(scaled, -2_147_483_648), 2_147_483_647)
        let fixed = Int32(clamped)
        if fixed == 0, value != 0 { return value > 0 ? 1 : -1 }
        return fixed
    }

    private typealias SetIntegerField =
        @convention(c) (UnsafeMutableRawPointer?, UInt32, Int64) -> Void
    private typealias SetDoubleField =
        @convention(c) (UnsafeMutableRawPointer?, UInt32, Double) -> Void

    private static let handle = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    private static let setIntegerValueField: SetIntegerField? =
        symbol("CGEventSetIntegerValueField")
    private static let setDoubleValueField: SetDoubleField? =
        symbol("CGEventSetDoubleValueField")

    private static func setInt(_ event: CGEvent, _ field: UInt32, _ value: Int64) {
        setIntegerValueField?(Unmanaged.passUnretained(event).toOpaque(), field, value)
    }

    private static func setDouble(_ event: CGEvent, _ field: UInt32, _ value: Double) {
        setDoubleValueField?(Unmanaged.passUnretained(event).toOpaque(), field, value)
    }
}
