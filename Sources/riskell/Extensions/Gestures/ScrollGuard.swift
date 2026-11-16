import AppKit
import ApplicationServices
import RiskellKit

/// With the system's own 3-finger gestures off, macOS treats three fingers on the trackpad as a scroll and hands it to the app under the
/// pointer, and OmniWM / Touch only observe the contacts. While three fingers are down (and the 0.6 s after they lift, which is also when
/// momentum scrolling ends) trackpad scroll events are dropped here, so the window under the pointer stays put. Mouse-wheel events are
/// never touched. Needs Accessibility permission (macOS asks once); until it is granted nothing is blocked and the tap is retried.
enum ScrollGuard {
    /// Set on the main thread by Touch (`onFingers`); read by the tap, which runs on the main run loop too.
    static var blocking = false
    private static var tap: CFMachPort?
    private static var tapSource: CFRunLoopSource?
    private static var retry: Timer?
    private static var dropped = 0
    fileprivate static var lastHeal = 0.0

    static func start() {
        guard tap == nil else { return }
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            print("scroll guard: waiting for Accessibility permission"); fflush(stdout)
        }
        if install() { return }
        retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { t in if install() { t.invalidate(); retry = nil } }
        retry?.tolerance = 1
    }

    @discardableResult
    private static func install() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t = ScrollGuard.tap { CGEvent.tapEnable(tap: t, enable: true) }; return Unmanaged.passUnretained(event) }
            guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else { return Unmanaged.passUnretained(event) }
            guard ScrollGuard.blocking else {
                // A trackpad scroll while no touch frame has arrived for 2 s: the touch pipe is dead (it dies after sleep / lock, measured), so
                // Touch is attached again (at most every 20 s). The swipe that found it dead is lost; the next one works.
                let now = CACurrentMediaTime()
                if now - Touch.lastFrame > 2, now - ScrollGuard.lastHeal > 20 { ScrollGuard.lastHeal = now; DispatchQueue.main.async { Touch.shared?.reattachSoon("trackpad scrolls but no touch frames arrive") } }
                return Unmanaged.passUnretained(event)
            }
            ScrollGuard.dropped += 1
            return nil
        }, userInfo: nil) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        print("scroll guard: active"); fflush(stdout)
        return true
    }

    /// Takes the tap down: it is disabled, its run-loop source removed and the port invalidated, and the retry timer stops. Nothing is
    /// blocked afterwards. `start` can run again later (the extension is turned back on).
    static func stop() {
        retry?.invalidate(); retry = nil
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes); tapSource = nil }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t); tap = nil }
        blocking = false
        print("scroll guard: stopped"); fflush(stdout)
    }

    static var state: String { "tap=\(tap != nil) trusted=\(AXIsProcessTrusted()) blocking=\(blocking) dropped=\(dropped)" }
}
