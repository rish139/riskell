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

    /// How far two windows' edges may overlap, in points, and still count as apart: the window server rounds each frame to whole points.
    static let frameTolerance = 2.0

    /// What a move key asks for: the commands, and the window that they send to another workspace when they do (its arrival there is the
    /// behaviour's own doing).
    struct Move: Equatable {
        var commands: [ManagerCommand] = []
        var hop: Int?
    }

    /// The layout of the focused workspace as read from the windows' rectangles: the workspace, the focused window, the tree and the
    /// rectangles. Nothing when it cannot be read (a window is off screen, two overlap, the top container is an accordion, the focused window
    /// is floating or elsewhere).
    private static func layout(of state: ManagerState) -> (workspace: String, focused: Int, tree: Tile, slots: [Slot])? {
        guard let ws = state.focusedWorkspace, let focused = state.focusedWindow,
              let axis = rootAxis(of: state.workspaces.first { $0.name == ws }) else { return nil }
        let tiling = state.windows.filter { $0.workspace == ws && !$0.floating }
        guard tiling.contains(where: { $0.id == focused }) else { return nil }
        var slots: [Slot] = []
        for window in tiling {
            guard let frame = window.frame else { return nil }
            slots.append(Slot(id: window.id, x0: frame.minX, y0: frame.minY, x1: frame.maxX, y1: frame.maxY))
        }
        guard case .tree(let tree) = FrameTree.read(slots, rootAxis: axis, tolerance: frameTolerance) else { return nil }
        return (ws, focused, tree, slots)
    }

    /// The workspace next to `workspace` in `direction` (left is the one before, right the one after), taken as AeroSpace's own `next` and
    /// `prev` take it: all the workspaces of the same monitor, empty ones too, by name. Nil at the first and the last. A workspace whose
    /// monitor is not known counts as being on every monitor.
    private static func neighbour(of workspace: String, toward direction: Direction, in state: ManagerState) -> String? {
        let monitor = state.workspaces.first { $0.name == workspace }?.monitor
        let names = state.workspaces.filter { monitor == nil || $0.monitor == nil || $0.monitor == monitor }.map(\.name).sorted()
        guard let index = names.firstIndex(of: workspace) else { return nil }
        let other = index + direction.offset
        return names.indices.contains(other) ? names[other] : nil
    }

    /// Moving the focused window in `direction`: the AeroSpace commands that do it (see `DwindleMove`), read from where the windows are on
    /// screen. Nothing when the layout cannot be read or when there is nothing that way. The layout is never rebuilt: the rows and columns
    /// are left as they are.
    ///
    /// A column of its own at the edge of the workspace moves to the next workspace that way, when there is one.
    static func move(_ direction: Direction, in state: ManagerState) -> Move {
        guard let read = layout(of: state),
              let step = DwindleMove.step(in: read.tree, window: read.focused, toward: direction, slots: read.slots) else { return Move() }
        guard case .hop = step else { return Move(commands: [ManagerCommand(DwindleMove.script(step, window: read.focused))]) }
        guard let target = neighbour(of: read.workspace, toward: direction, in: state) else { return Move() }
        let there = state.windows.filter { $0.workspace == target && !$0.floating }.count
        let script = DwindleMove.script(step, window: read.focused, workspace: read.workspace, target: target, tilingWindows: there)
        return Move(commands: [ManagerCommand(script, window: read.focused)], hop: read.focused)
    }

    /// Focusing further than the edge of the workspace, left or right: the focus goes to the next workspace that way, to its window nearest
    /// the edge it came from (the first window when going right, the last when going left), or only to the workspace when it has no window.
    /// On a workspace with no window at all every press goes on, since AeroSpace's own `focus` has nowhere to go there. Where something is
    /// still beside the focused window, nothing is sent: AeroSpace's own `focus` does the move, and at the edge it does nothing, so the two
    /// never disagree. Nothing at the first and the last workspace.
    static func focus(_ direction: Direction, in state: ManagerState) -> [ManagerCommand] {
        guard direction.axis == .row, let workspace = state.focusedWorkspace else { return [] }
        if state.windows.contains(where: { $0.workspace == workspace }) {
            guard let read = layout(of: state), DwindleMove.isAtEdge(in: read.tree, window: read.focused, toward: direction) else { return [] }
        }
        guard let target = neighbour(of: workspace, toward: direction, in: state) else { return [] }
        let count = state.windows.filter { $0.workspace == target && !$0.floating }.count
        var lines = ["workspace \(target)"]
        if count > 0 { lines.append("focus --dfs-index \(direction == .right ? 0 : count - 1)") }
        return [ManagerCommand(lines.joined(separator: "; "))]
    }

    /// The axis of a workspace's top container when it tiles, nil for an accordion or when it is not known.
    static func rootAxis(of workspace: ManagedWorkspace?) -> Axis? {
        switch workspace?.rootLayout {
            case "h_tiles": return .row
            case "v_tiles": return .column
            default: return nil
        }
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
