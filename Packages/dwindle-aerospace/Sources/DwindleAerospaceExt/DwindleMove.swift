// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

/// A direction on the screen, as AeroSpace names them.
enum Direction: String {
    case left, right, up, down

    /// Left and right run along a row, up and down along a column.
    var axis: Axis { self == .left || self == .right ? .row : .column }
    /// Which way the index of a child moves: towards the first child (left, up) or the last (right, down).
    var offset: Int { self == .left || self == .up ? -1 : 1 }
}

/// What moving a window in a direction means for the layout, as the AeroSpace commands that do it.
enum MoveStep: Equatable {
    /// Something is beside the window that way, in the row or column it is in, and it is a single window: the two merge into one group, the
    /// window on the side it came from. The commands are `join-with`.
    case join(Direction)
    /// What is beside the window that way is a group of several windows: the window enters it, next to the member that is level with where it
    /// was, which is `via` (any window inside the member; when the member is itself a group the window becomes the first one in it). AeroSpace
    /// enters a group at the window that was used last, so `via` is focused first and the window focused again afterwards.
    case enter(Direction, via: Int)
    /// Nothing is beside the window that way in its own row or column: it leaves its group and becomes a row or column of its own beside
    /// the group. These are the commands of AeroSpace's own `move`, with the edge of the workspace left alone.
    case leave(Direction)
    /// The window is in the group that is the whole workspace, and that group runs across the direction (two windows stacked, say): it leaves
    /// by turning the workspace into a row or column along the direction, with the window as one side and the rest of the group as the other.
    /// AeroSpace's `move` does that at the edge of a workspace when it is asked to make a container.
    case wrap(Direction)
    /// The window is a column of its own at the left or right edge of the workspace (or the only window on it) and has nothing further that way:
    /// it moves to the next workspace in that direction, as the last column there when it went left and the first when it went right, and the
    /// focus goes with it.
    case hop(Direction)
}

enum DwindleMove {
    /// The step for `window` towards `direction` in `tree` (as read from the rectangles in `slots`), or nil when there is nothing that way:
    /// the window is not in the tree, or it is a row or column of its own at the edge of the workspace (or sits in a row of a stack that is the whole workspace, at the end of that row).
    ///
    /// The two moves of one direction are one after the other. A window that sits in a group running across the direction first leaves the
    /// group (`leave`); once it is a row or column of its own it merges with what is beside it (`join` or `enter`). AeroSpace's own `move`
    /// swaps with a single window beside it, and at the edge of the workspace wraps the whole layout in a new container; neither is wanted.
    static func step(in tree: Tile, window: Int, toward direction: Direction, slots: [Slot]) -> MoveStep? {
        var path: [(axis: Axis, index: Int, children: [Tile])] = []
        guard find(window, in: tree, path: &path) else { return nil }
        // the only window of the workspace is at both edges
        guard let parent = path.last else { return direction.axis == .row ? .hop(direction) : nil }
        let next = parent.index + direction.offset
        if parent.axis == direction.axis, next >= 0, next < parent.children.count {
            switch parent.children[next] {
                case .window:
                    return .join(direction)
                case .split(_, let members):
                    guard let own = slots.first(where: { $0.id == window }) else { return nil }
                    let level = members.max { overlap(own, with: $0, slots, across: direction) < overlap(own, with: $1, slots, across: direction) }
                    guard let via = level?.leaves.first else { return nil }
                    return .enter(direction, via: via)
            }
        }
        // the nearest group above the window whose own container runs along the direction is the one it steps out into
        for level in stride(from: path.count - 1, to: 0, by: -1) where path[level - 1].axis == direction.axis {
            return .leave(direction)
        }
        guard path.count == 1 else { return nil }
        // a window of the stack that is the whole workspace has no group above to step out into: the workspace itself is wrapped
        if parent.axis != direction.axis { return .wrap(direction) }
        // a column of the top row, at its end: nothing is left that way on this workspace
        return direction.axis == .row ? .hop(direction) : nil
    }

    /// True when nothing is left to the window in `direction` on its workspace: no group above it that runs that way has a member on that side.
    /// Only the left and right edges count for focus: a window in a column is at the edge when nothing is beside its column.
    static func isAtEdge(in tree: Tile, window: Int, toward direction: Direction) -> Bool {
        var path: [(axis: Axis, index: Int, children: [Tile])] = []
        guard find(window, in: tree, path: &path) else { return false }
        return !path.contains { $0.axis == direction.axis && $0.index + direction.offset >= 0 && $0.index + direction.offset < $0.children.count }
    }

    /// How far `member` and `own` overlap along the axis a group entered in `direction` stacks its members on (negative when they are apart,
    /// so the nearest member wins when none overlaps).
    private static func overlap(_ own: Slot, with member: Tile, _ slots: [Slot], across direction: Direction) -> Double {
        let ids = Set(member.leaves)
        let inside = slots.filter { ids.contains($0.id) }
        guard !inside.isEmpty else { return -.infinity }
        let low: Double, high: Double
        if direction.axis == .row {
            low = inside.map(\.y0).min() ?? 0; high = inside.map(\.y1).max() ?? 0
            return min(high, own.y1) - max(low, own.y0)
        }
        low = inside.map(\.x0).min() ?? 0; high = inside.map(\.x1).max() ?? 0
        return min(high, own.x1) - max(low, own.x0)
    }

    /// The containers from the top down to the window's own, each with the index of the branch that leads to the window.
    private static func find(_ id: Int, in tile: Tile, path: inout [(axis: Axis, index: Int, children: [Tile])]) -> Bool {
        switch tile {
            case .window(let found):
                return found == id
            case .split(let axis, let children):
                for (index, child) in children.enumerated() {
                    path.append((axis, index, children))
                    if find(id, in: child, path: &path) { return true }
                    path.removeLast()
                }
                return false
        }
    }

    /// The command line for a step, for the window it acts on. `workspace` is the one the window is on and `tilingWindows` how many tiling
    /// windows the workspace it goes to has, which only a hop needs.
    ///
    /// A hop goes to `target`, the workspace that AeroSpace's own `next` or `prev` would take it to (the caller works it out the same way, and
    /// there is none at the first and the last workspace). The window arrives as the last child
    /// of the top row of the other workspace. That is the right place for a hop to the left; for a hop to the right it is brought to the front
    /// by `move left` presses, one for a window and two for a column that it passes, so as many as the workspace has windows are enough, and
    /// once it is first the rest do nothing. A workspace whose top container is not a row gets a new row around it instead. The tests look at where
    /// the window is (`%{workspace}`) so that when the hop fails, because there is no workspace that way, nothing else is sent.
    static func script(_ step: MoveStep, window: Int, workspace: String = "", target: String = "", tilingWindows: Int = 0) -> String {
        switch step {
            case .join(let direction):
                return "join-with --window-id \(window) \(direction.rawValue)"
            case .enter(let direction, let via):
                return "focus --window-id \(via); move --window-id \(window) --boundaries-action stop \(direction.rawValue); focus --window-id \(window)"
            case .leave(let direction):
                return "move --window-id \(window) --boundaries-action stop \(direction.rawValue)"
            case .hop(let direction):
                let moved = "test-not %{workspace} = \(workspace)"
                // AeroSpace takes `--window-id` only with a workspace's name, not with `next` or `prev`
                var lines = ["move-node-to-workspace --window-id \(window) --focus-follows-window \(target)"]
                if direction == .right, tilingWindows > 0 {
                    let first = Array(repeating: "move --window-id \(window) --boundaries-action stop left", count: tilingWindows)
                    lines.append(([moved, "test %{workspace-root-container-layout} = h_tiles"] + first).joined(separator: " && "))
                }
                let around = "move --window-id \(window) --boundaries-action create-implicit-container \(direction == .right ? "left" : "right")"
                lines.append([moved, "test-not %{workspace-root-container-layout} = h_tiles", around].joined(separator: " && "))
                return lines.joined(separator: "; ")
            case .wrap(let direction):
                return "move --window-id \(window) --boundaries-action create-implicit-container \(direction.rawValue)"
        }
    }
}
