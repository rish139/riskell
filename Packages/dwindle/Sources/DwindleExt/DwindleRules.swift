// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import RiskellKit

/// The dwindle rules, as plain functions of what riskell knows of the window manager: nothing is read, nothing is kept, so every
/// case can be tested without a window.
enum DwindleRules {
    /// The split for a window that has appeared on a workspace: one command when that workspace already holds two or more other
    /// tiling windows, nothing otherwise.
    ///
    /// A join makes a container of the window and its neighbour, and with only one other window that container is the whole
    /// workspace: two windows side by side would turn into two stacked. So the first window starts the workspace on its own.
    /// Whether the window may be joined at all is left to AeroSpace, which tests its parent layout: a floating window or an
    /// accordion fails both tests and stays where it is.
    static func split(window id: Int, on workspace: String?, in state: ManagerState) -> [ManagerCommand] {
        // the state knows where the window is now; the event names its workspace too
        guard let ws = state.windows.first(where: { $0.id == id })?.workspace ?? workspace else { return [] }
        let others = state.windows.filter { $0.workspace == ws && !$0.floating && $0.id != id }
        guard others.count >= 2 else { return [] }
        return [ManagerCommand(AeroSpaceScripts.split, window: id)]
    }

    /// The tidy: rebuild the focused workspace as a dwindle chain, its windows in the order they were made.
    static func tidy(in state: ManagerState) -> [ManagerCommand] {
        guard let ws = state.focusedWorkspace else { return [] }
        let windows = state.windows.filter { $0.workspace == ws && !$0.floating }.map(\.id).sorted()
        guard !windows.isEmpty else { return [] }
        let root = rootOrientation(of: state.workspaces.first { $0.name == ws })
        return [ManagerCommand(AeroSpaceScripts.tidy(workspace: ws, root: root, windows: windows))]
    }

    /// Which way the workspace's top container splits: what its display says, else the layout it has now, else side by side (the
    /// shape of every display by default).
    static func rootOrientation(of workspace: ManagedWorkspace?) -> RootOrientation {
        if let landscape = workspace?.landscape { return landscape ? .horizontal : .vertical }
        if let layout = workspace?.rootLayout, layout.hasPrefix("v") { return .vertical }
        return .horizontal
    }
}

/// Which way a workspace's root container splits. The tidy chain follows it: the container holding two windows splits across it,
/// and each later join alternates.
enum RootOrientation: String {
    case horizontal = "h"
    case vertical = "v"

    /// The root layout in AeroSpace's own words, for `layout --root`.
    var tiles: String { rawValue + "_tiles" }

    /// The direction the window at `index` (2 or more) is joined: `left` and `up` alternate, one per split direction. A window
    /// joined from the left sits in a column with the window before it, and one joined from above sits in a row.
    func joinDirection(_ index: Int) -> String {
        (index % 2 == 1) == (self == .horizontal) ? "left" : "up"
    }
}
