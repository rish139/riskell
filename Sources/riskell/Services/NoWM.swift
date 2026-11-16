import AppKit
import RiskellKit

/// No tiling window manager: riskell runs on plain macOS. There are no workspaces to show (the rail has nothing to draw), the app-icon atom
/// follows the frontmost app, and every window action is a no-op. Nothing reserves room for the bars, so windows can sit under them
/// (a tiling manager with gap support is what makes the bars "hug"); that is the price of having no manager.
final class NoWM: WindowManager {
    let name = "none"
    private let store: Store
    private var observer: NSObjectProtocol?

    init(store: Store) { self.store = store }

    func start() {
        publish(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            self?.publish(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }
    func stop() { if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o) }; observer = nil }

    /// One pseudo window for the frontmost regular app, so the app-icon atom has something to show; no spaces.
    private func publish(_ app: NSRunningApplication?) {
        guard let app, app.activationPolicy == .regular, app.processIdentifier != getpid() else { return }
        store.set(windows: [WinInfo(id: Int(app.processIdentifier), pid: Int(app.processIdentifier), app: app.localizedName ?? "", title: "", space: 0, focused: true)])
    }

    func requestRefresh() {}
    func focus(space: Int) {}
    func focus(window id: Int) {}
    func close(window id: Int) {}
    func move(window id: Int, toSpace space: Int) {}
    func moveToNewSpace(window id: Int, after count: Int) {}
}
