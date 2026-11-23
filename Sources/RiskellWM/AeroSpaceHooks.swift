import CoreGraphics
import Foundation
import RiskellKit

/// What the backend needs to answer a manager hook, held apart from the socket so every rule here can be tested without a window: the
/// state built from the rows, the windows that have arrived, the screens, and the requests the hooks' commands travel in.
extension AeroSpace {
    /// The hooks' view of the manager, from the rows of the last query. Windows the window server says are gone are left out (`gone`),
    /// and so is the focused one when it is among them: a hook must not plan around a window that no longer exists.
    ///
    /// A window is `floating` when it is outside the tiling tree: a window the manager floats, and also a minimised one, a native-fullscreen
    /// one, a window of a hidden app and a popup. None of them takes part in a layout, so a hook that counts a workspace's windows must not
    /// see them.
    public static func managerState(rows: Rows, focusedWindow: Int?, landscape: [Int: Bool], gone: Set<Int>) -> ManagerState {
        let windows = rows.windows.filter { !gone.contains($0.windowId) }.sorted { $0.windowId < $1.windowId }
            .map { ManagedWindow(id: $0.windowId, workspace: $0.workspace, floating: !$0.tiling) }
        let workspaces = rows.workspaces.map { row in
            ManagedWorkspace(name: row.workspace, rootLayout: row.rootLayout, landscape: row.monitor.flatMap { landscape[$0] })
        }
        let focus = focusedWindow.flatMap { gone.contains($0) ? nil : $0 }
        return ManagerState(windows: windows, workspaces: workspaces, focusedWindow: focus,
                            focusedWorkspace: rows.workspaces.first { $0.focused ?? false }?.workspace)
    }

    /// The windows that have arrived between two query answers: present in both, tiling after, and either on another workspace or tiling
    /// for the first time (it was floating, minimised, in native fullscreen...). AeroSpace reports neither, so the comparison is the only
    /// word on it. `ignoring` leaves out one arrival riskell caused itself, which it announced when it sent the command.
    public static func arrivals(from before: Rows, to after: Rows, ignoring expected: (window: Int, workspace: String)? = nil) -> [ManagerEvent] {
        let was = Dictionary(before.windows.map { ($0.windowId, $0) }, uniquingKeysWith: { first, _ in first })
        return after.windows.sorted { $0.windowId < $1.windowId }.compactMap { window in
            guard window.tiling, let old = was[window.windowId], !old.tiling || old.workspace != window.workspace else { return nil }
            if let expected, expected.window == window.windowId, expected.workspace == window.workspace { return nil }
            return ManagerEvent(name: ManagerEvent.windowArrived, fields: ["windowId": String(window.windowId), "workspace": window.workspace])
        }
    }

    /// The state for a window riskell itself is about to move: as it is now, with that window counted on neither workspace, so the hooks
    /// see the workspace it arrives on as it will be without it.
    public static func without(_ window: Int, in state: ManagerState) -> ManagerState {
        ManagerState(windows: state.windows.filter { $0.id != window }, workspaces: state.workspaces,
                     focusedWindow: state.focusedWindow == window ? nil : state.focusedWindow, focusedWorkspace: state.focusedWorkspace)
    }

    /// One request to send for a set of hook commands: the target window they act on, and the `eval` arguments. Commands for the same
    /// window share one request, so the manager lays the windows out once instead of once per command.
    public struct HookRequest: Equatable {
        public let window: Int?
        public let args: [String]
        public init(window: Int?, args: [String]) { self.window = window; self.args = args }
    }

    /// The requests for a set of hook commands, grouped by the window each acts on and in the order they were returned. The queries go at
    /// the end of the last request, so its answer is the one that says what the commands left behind. `first` is a command of riskell's
    /// own to send in front of everything (its move, whose request carries the hooks' scripts).
    public static func hookRequests(_ commands: [ManagerCommand], queries: [[String]], first: [String]? = nil) -> [HookRequest] {
        var order: [Int?] = []
        var scripts: [Int?: [String]] = [:]
        for command in commands {
            if scripts[command.window] == nil { order.append(command.window); scripts[command.window] = [] }
            scripts[command.window]?.append(command.script)
        }
        if order.isEmpty {
            guard first != nil else { return [] }       // nothing to send: no request at all
            order = [nil]
        }
        return order.enumerated().map { i, window in
            var parts: [String] = []
            if i == 0, let first { parts.append(first.map(quoted).joined(separator: " ")) }
            parts += scripts[window] ?? []
            if i == order.count - 1 { parts += queries.map { $0.map(quoted).joined(separator: " ") } }
            return HookRequest(window: window, args: ["eval", parts.joined(separator: "; ")])
        }
    }

    /// Which monitor id each of `frames` is, by the rule AeroSpace numbers them with: the 1-based place of the screen in `sortedMonitors`,
    /// which is every screen sorted by the top-left corner of its frame, the y axis running down from the main screen's top. `frames` are
    /// the screens' frames as the system reports them (the origin at the main screen's bottom left), and `mainHeight` its height. A screen
    /// wider than it is tall is `true`.
    public static func landscape(frames: [CGRect], mainHeight: Double) -> [Int: Bool] {
        func corner(_ r: CGRect) -> (Double, Double) { (Double(r.minX), mainHeight - Double(r.maxY)) }
        let sorted = frames.sorted { a, b in corner(a) < corner(b) }
        var out: [Int: Bool] = [:]
        for (i, r) in sorted.enumerated() { out[i + 1] = r.width > r.height }
        return out
    }
}
