import AppKit
import RiskellKit

/// riskell's own 3-finger gestures (the workspace swipe, the overview's swipe up; Extensions/Gestures/Touch.swift) and the scroll guard that
/// keeps trackpad scrolls from moving the window under the pointer during them (ScrollGuard.swift). Off by default ("gestures": "system"):
/// then nothing here runs, so there is no event tap, no MultitouchSupport registration and no Accessibility prompt. Turned on, it starts what
/// main.swift used to start at launch, and turning it off tears all of it down.
final class GesturesExtension: RiskellExtension {
    static let id = "gestures"
    private var touch: Touch?

    init() {}

    func start() {
        let t = Touch(store: store)      // Touch.init sets Touch.shared
        touch = t
        t.onFingers = { liftBars($0); Overview.shared.lift($0); ScrollGuard.blocking = $0 }      // the bars rise while three fingers are down
        t.start()
        // a snapshot or a dump runs no scroll guard (no tap, no Accessibility prompt)
        if !CommandLine.arguments.contains("--snap") && !CommandLine.arguments.contains("--dump") { ScrollGuard.start() }
    }

    func stop() {
        touch?.stop()      // a gesture in progress ends and the bars drop back; the trackpad is released
        touch = nil
        ScrollGuard.stop()
    }
}
