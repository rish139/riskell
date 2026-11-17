import AppKit
import QuartzCore
import RiskellKit

/// 3-finger Space swipe, read from the trackpad (MultitouchSupport, private). macOS reports a Space change only when the swipe has
/// settled, so the workspace capsule follows the fingers instead: it is displaced by the swipe's travel and, when macOS commits the change,
/// that displacement is replaced by the real focus. A swipe macOS does not commit springs back.
/// The direction follows System Settings > Trackpad > Natural scrolling, read each time (the touch frames are raw finger positions, so the setting is
/// what says which way a swipe goes). It is not guessed from what the Space does afterwards: one Space change from another cause close to a swipe
/// used to teach it the wrong way and reverse every swipe until riskell restarted.
final class Touch {
    static weak var shared: Touch?
    private let store: Store
    /// "Natural scrolling" from the global preference; absent means macOS's default, which is on.
    private var natural: Bool {
        var valid: DarwinBoolean = false
        let v = CFPreferencesGetAppBooleanValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication, &valid)
        return valid.boolValue ? v : true
    }
    private var disagreements = 0
    private var active = false
    private var startX: Float = 0
    private var dx: Float = 0
    private var startY: Float = 0
    private var dy: Float = 0
    /// Which way this touch is going, fixed once it has moved a little: sideways drives the workspace capsule, up/down the overview.
    private enum Axis { case undecided, sideways, vertical }
    private var axis = Axis.undecided
    private let axisLock: Float = 0.025   // pad fraction of travel before the axis is decided
    private var lastDx: Float = 0
    private var lastTouchTime = Date.distantPast
    private var revert: DispatchWorkItem?
    /// true when three fingers land, false 0.6 s after they lift (the WM's slide has settled); a new touch cancels the false.
    var onFingers: ((Bool) -> Void)?
    private var settle: DispatchWorkItem?
    private var downAt = 0.0
    private let quickSwipe = 0.6          // s: a swipe shorter than this commits...
    private let minTravel: Float = 0.03   // ...if it moved at least this much (pad widths)
    private let longSwipe: Float = 0.2    // a slower swipe commits only past this travel
    private let span: Float = 0.30        // pad widths of travel for one full slot of capsule movement; tuned from --trace

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void

    init(store: Store) { self.store = store; Touch.shared = self }

    /// MTTouch is 96 bytes: state (Int32) at +20, normalized x, y (Float, y = 0 at the bottom) at +32, +36.
    private static let contactCallback: Callback = { _, touches, n, _, _ in
        var count = 0; var sx: Float = 0, sy: Float = 0
        if let t = touches {
            for i in 0..<Int(n) {
                let p = t + i * 96
                let state = p.load(fromByteOffset: 20, as: Int32.self)
                if state == 4 || state == 5 {
                    count += 1
                    sx += p.load(fromByteOffset: 32, as: Float.self); sy += p.load(fromByteOffset: 36, as: Float.self)
                }
            }
        }
        let cx = count > 0 ? sx / Float(count) : 0, cy = count > 0 ? sy / Float(count) : 0
        DispatchQueue.main.async { Touch.shared?.frame(count: count, cx: cx, cy: cy) }
        return 0
    }

    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private var devices: [UnsafeMutableRawPointer] = []
    private var deviceList: CFArray?
    private(set) var attachedAt = 0.0
    private var attaches = 0

    /// The trackpad's device handles stop delivering frames after sleep, a screen lock or the trackpad re-enumerating (measured: no frame
    /// for 17 minutes after an unlock while the app ran fine, so the swipe, its capsule and the scroll guard's finger count were all dead).
    /// So the registration is repeatable: the old handles are stopped, a fresh list is created, registered and started. It runs at launch
    /// and again after wake, screen wake and unlock (twice, a second apart then five, because the device may not be ready at once).
    /// The wake and unlock observers, kept so `stop` can remove them.
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var stopped = false
    private static let framework = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    func start() {
        stopped = false
        attach()
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append((ws, ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.reattachSoon("wake") }))
        }
        let dn = DistributedNotificationCenter.default()
        for n in ["com.apple.screenIsUnlocked", "com.apple.screensaver.didstop"] {
            observers.append((dn, dn.addObserver(forName: Notification.Name(n), object: nil, queue: .main) { [weak self] _ in self?.reattachSoon("unlock") }))
        }
    }

    /// Everything `start` and `attach` set up is taken down: the frame callbacks are unregistered, the devices stopped, the observers removed,
    /// a gesture in progress ends (the bars drop back) and `Touch.shared` is cleared. A pending re-attach does nothing.
    func stop() {
        stopped = true
        for o in observers { o.center.removeObserver(o.token) }
        observers = []
        revert?.cancel(); settle?.cancel()
        active = false
        onFingers?(false)
        onFingers = nil
        if let h = dlopen(Self.framework, RTLD_LAZY) {
            if let p = dlsym(h, "MTUnregisterContactFrameCallback") { let unregister = unsafeBitCast(p, to: Register.self); for d in devices { unregister(d, Touch.contactCallback) } }
            if let p = dlsym(h, "MTDeviceStop") { let stopDev = unsafeBitCast(p, to: Stop.self); for d in devices { stopDev(d) } }
        }
        devices = []
        deviceList = nil
        if Touch.shared === self { Touch.shared = nil }
        Self.glog("trackpad released")
    }

    func reattachSoon(_ why: String) {
        guard !stopped else { return }
        Self.glog("\(why): the trackpad is attached again in 1 s and 5 s")
        for d in [1.0, 5.0] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.attach() } }
    }

    func attach() {
        guard !stopped else { return }
        guard let h = dlopen(Self.framework, RTLD_LAZY),
              let pl = dlsym(h, "MTDeviceCreateList"), let pr = dlsym(h, "MTRegisterContactFrameCallback"), let ps = dlsym(h, "MTDeviceStart") else {
            print("touch: MultitouchSupport unavailable"); return
        }
        if let pstop = dlsym(h, "MTDeviceStop") { for d in devices { unsafeBitCast(pstop, to: Stop.self)(d) } }
        devices = []
        if active { active = false; onFingers?(false) }          // a gesture cannot survive its device being replaced
        guard let list = unsafeBitCast(pl, to: CreateList.self)()?.takeRetainedValue() else { print("touch: no device list"); return }
        deviceList = list
        let register = unsafeBitCast(pr, to: Register.self), startDev = unsafeBitCast(ps, to: Start.self)
        for i in 0..<CFArrayGetCount(list) {
            let dev = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i))!
            register(dev, Touch.contactCallback)
            startDev(dev, 0)
            devices.append(dev)
        }
        attaches += 1; attachedAt = CACurrentMediaTime()
        Self.glog("trackpad attached (\(devices.count) device(s), attach #\(attaches))")
    }

    /// Gesture diagnostics (always on, a few lines per gesture): where a swipe stops being a swipe.
    static var frames = 0, threeFrames = 0, lastFrame = 0.0
    static func glog(_ s: String) { print(String(format: "[touch %.1f] ", CACurrentMediaTime().truncatingRemainder(dividingBy: 10000)) + s); fflush(stdout) }
    static var state: String { String(format: "frames=%d three=%d lastFrame=%.1fs ago", frames, threeFrames, CACurrentMediaTime() - lastFrame) + (shared.map { String(format: " attachedAt=%.0fs ago", CACurrentMediaTime() - $0.attachedAt) } ?? "") }

    private func frame(count: Int, cx: Float, cy: Float) {
        Self.frames += 1; Self.lastFrame = CACurrentMediaTime(); if count == 3 { Self.threeFrames += 1 }
        if count == 3 {
            if !active {
                active = true; startX = cx; dx = 0; startY = cy; dy = 0; axis = .undecided
                downAt = CACurrentMediaTime(); revert?.cancel()
                settle?.cancel(); onFingers?(true)
                tlog("touch: 3 fingers down (\(store.pending) swipes still unconfirmed)")
                Self.glog("3 fingers down")
            }
            dx = cx - startX; dy = cy - startY
            if axis == .undecided {
                if abs(dy) > axisLock, abs(dy) > abs(dx) * 1.2 {
                    axis = .vertical; store.swipeMove(slots: 0)
                    Self.glog(String(format: "vertical (dy %.3f dx %.3f): overview gesture begins", dy, dx))
                    Overview.shared.gestureBegan()
                } else if abs(dx) > axisLock { axis = .sideways; Self.glog(String(format: "sideways (dx %.3f dy %.3f)", dx, dy)) }
            }
            if axis == .vertical { Overview.shared.gestureMoved(dy); return }
            lastDx = dx; lastTouchTime = Date()
            // measured from where the capsule is heading (focus + unconfirmed swipes), never past the first or last space
            let n = store.spaces.count, base = (store.focusedIndex ?? 0) + store.pending
            // the travel spent deciding the axis does not count, so the capsule starts moving from rest instead of jumping
            let eff = dx - max(-axisLock, min(axisLock, dx))
            let slots = Double((natural ? -eff : eff) / span)
            store.swipeMove(slots: max(Double(-base), min(Double(n - 1 - base), slots)))
        } else if active {
            active = false
            if axis == .undecided { Self.glog(String(format: "fingers up, axis never decided (dx %.3f dy %.3f)", dx, dy)) }
            let held = CACurrentMediaTime() - downAt
            if axis == .vertical {
                tlog(String(format: "touch: overview swipe up %.3f after %.0f ms", dy, held * 1000))
                Self.glog(String(format: "vertical ended: dy %.3f after %.0f ms (overview live=%@ p=%.2f)", dy, held * 1000, Overview.shared.live ? "yes" : "no", Overview.shared.progress))
                store.swipeRelease(commit: 0)
                Overview.shared.gestureEnded(dy: dy, held: held)
                let s = DispatchWorkItem { [weak self] in self?.onFingers?(false) }
                settle = s
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: s)
                return
            }
            let n = store.spaces.count, base = (store.focusedIndex ?? 0) + store.pending
            let dir = (natural ? -dx : dx) > 0 ? 1 : -1
            // Measured: macOS flips the Space ~960 ms after lift, whatever the swipe was, and nothing reports it earlier. So decide now.
            // Every swipe that was quick, or long, committed; only a slow, short one is let go of.
            let commits = (held < quickSwipe && abs(dx) >= minTravel) || abs(dx) >= longSwipe
            let target = commits && base + dir >= 0 && base + dir <= n - 1 ? dir : 0
            Self.glog(String(format: "fingers up after %.0f ms, travel %.3f, predicted %@", held * 1000, dx, target == 0 ? "cancel" : (target > 0 ? "+1" : "-1")))
            tlog(String(format: "touch: fingers up after %.0f ms, travel %.3f -> %@", held * 1000, dx, target == 0 ? "cancel" : "go \(target > 0 ? "+1" : "-1")"))
            if WM.shared?.ownsSwipe == true {
                // the swipe is ours: no prediction, the capsule goes where the focus is sent (and the WM follows)
                store.swipeRelease(commit: 0)
                if target != 0, let f = store.focusedIndex { WM.shared?.focus(space: store.spaces[f + target].id) }
            } else {
                store.swipeRelease(commit: target)
                armRevert()
            }
            let s = DispatchWorkItem { [weak self] in self?.onFingers?(false) }
            settle = s
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: s)
        }
    }

    /// OmniWM reports a committed swipe ~0.3 s after lift (measured, 14 swipes, on every channel); a prediction still open after this is wrong.
    private static let confirmWithin = 0.9

    /// If the WM never confirms what we predicted (it ignored a swipe), put the capsule back on the real focus.
    private func armRevert() {
        revert?.cancel()
        guard store.pending != 0 else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.store.pending != 0 else { return }
            tlog("touch: the WM did not confirm \(self.store.pending) swipe(s), springing back")
            self.store.swipeClear()
        }
        revert = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmWithin, execute: w)
    }

    /// Called when the system reports the active Space changed (from `old` to `new` focus index): it settles the prediction and notes a mismatch.
    func spaceChanged(from old: Int?, to new: Int?) {
        if !active { armRevert() }              // more swipes may still be waiting for their confirmation
        guard let old, let new, old != new, Date().timeIntervalSince(lastTouchTime) < 1.5, abs(lastDx) > 0.05 else { return }
        let expected = (natural ? -lastDx : lastDx) > 0 ? 1 : -1
        let actual = new > old ? 1 : -1
        // Only recorded (no guessing): a Space that moved against the swipe is usually another cause (a click, a key, the overview).
        if expected != actual { disagreements += 1; Self.glog("the space moved \(actual > 0 ? "+1" : "-1") after a swipe that meant \(expected > 0 ? "+1" : "-1") (natural scrolling is \(natural ? "on" : "off"); \(disagreements) so far)") }
        lastTouchTime = .distantPast
    }
}
