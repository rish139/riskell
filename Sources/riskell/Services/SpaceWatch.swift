import AppKit
import RiskellKit

/// The system's own "active Space changed" notification, read through SkyLight: no WM signal, no fork. Whether it beats the window
/// manager's own event on a 3-finger swipe is what `--trace` measures.
final class SpaceWatch {
    private let store: Store
    private let wm: WindowManager
    private var token: NSObjectProtocol?
    /// true when the active Space is a native full-screen one: the bars hide
    var onFullscreen: ((Bool) -> Void)?

    init(store: Store, wm: WindowManager) { self.store = store; self.wm = wm }

    func start() {
        if let sid = Sky.activeSpace() { onFullscreen?(Sky.isFullscreen(sid)) }
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let sid = Sky.activeSpace()
            tlog("NSWorkspace activeSpaceDidChange (sid \(sid.map(String.init) ?? "?"))")
            let old = self.store.focusedIndex
            if let sid, self.store.focusNow(sid: sid) { tlog("  -> capsule moved") }
            Touch.shared?.spaceChanged(from: old, to: self.store.focusedIndex)
            if let sid { self.onFullscreen?(Sky.isFullscreen(sid)) }
            self.wm.requestRefresh()
        }
    }
}
