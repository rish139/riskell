// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

/// One tiling window's rectangle on its display. y grows downward; x1 > x0, y1 > y0.
struct Slot: Equatable {
    let id: Int
    let x0, y0, x1, y1: Double
}

enum Axis: Equatable {
    case row
    case column
}

indirect enum Tile: Equatable {
    case window(Int)
    case split(Axis, [Tile])

    /// Ids in screen order.
    var leaves: [Int] {
        switch self {
            case .window(let id):
                return [id]
            case .split(_, let children):
                return children.flatMap(\.leaves)
        }
    }

    /// Every split has exactly 2 children, recursively.
    var isBinary: Bool {
        switch self {
            case .window:
                return true
            case .split(_, let children):
                return children.count == 2 && children.allSatisfy(\.isBinary)
        }
    }
}

enum FrameReading: Equatable {
    case tree(Tile)
    case unreadable
}

enum FrameTree {
    /// `rootAxis` is the workspace's top container (from its layout name: h_tiles = row, v_tiles = column).
    static func read(_ slots: [Slot], rootAxis: Axis, tolerance: Double) -> FrameReading {
        guard !slots.isEmpty else { return .unreadable }
        let ids = slots.map(\.id)
        guard Set(ids).count == ids.count else { return .unreadable }
        guard let tile = make(slots, axis: rootAxis, tolerance: tolerance) else { return .unreadable }
        return .tree(tile)
    }

    /// The tree for `slots` split along `axis`, or nil when `slots` holds more than one window but no cut.
    private static func make(_ slots: [Slot], axis: Axis, tolerance: Double) -> Tile? {
        guard slots.count > 1 else { return .window(slots[0].id) }
        let sorted: [Slot]
        switch axis {
            case .row:
                sorted = slots.sorted { $0.x0 < $1.x0 }
            case .column:
                sorted = slots.sorted { $0.y0 < $1.y0 }
        }
        var runs: [[Slot]] = []
        var run: [Slot] = []
        var far = 0.0
        for slot in sorted {
            let near = axis == .row ? slot.x0 : slot.y0
            let edge = axis == .row ? slot.x1 : slot.y1
            if run.isEmpty {
                run = [slot]
                far = edge
            } else if far <= near + tolerance {
                runs.append(run)
                run = [slot]
                far = edge
            } else {
                run.append(slot)
                far = max(far, edge)
            }
        }
        runs.append(run)
        guard runs.count > 1 else { return nil }
        let next: Axis = axis == .row ? .column : .row
        var children: [Tile] = []
        for run in runs {
            if run.count == 1 {
                children.append(.window(run[0].id))
            } else {
                guard let child = make(run, axis: next, tolerance: tolerance) else { return nil }
                children.append(child)
            }
        }
        return .split(axis, children)
    }
}
