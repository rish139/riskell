// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import CoreGraphics
import XCTest
import RiskellKit
@testable import DwindleAerospaceExt

// MARK: what riskell would know of a model

/// What riskell would report of the model: every window on the workspace it is on, with the frame `frames` gives it, and the focus where the
/// model has it. A window the model keeps on a hidden workspace has no frame, as a parked window has none.
private func reported(_ model: AeroSpaceModel, frames: [Slot]) -> ManagerState {
    ManagerState(windows: model.windowIds.map { id in
                     let slot = frames.first { $0.id == id }
                     return ManagedWindow(id: id, workspace: model.workspaceName(of: id) ?? "", floating: false,
                                          frame: slot.map { CGRect(x: $0.x0, y: $0.y0, width: $0.x1 - $0.x0, height: $0.y1 - $0.y0) })
                 },
                 workspaces: model.workspaceNames.map {
                     ManagedWorkspace(name: $0, rootLayout: model.rootLayout(of: $0),
                                      landscape: model.rootLayout(of: $0) == "h_tiles", monitor: model.monitor(of: $0))
                 },
                 focusedWindow: model.focusedWindowId,
                 focusedWorkspace: model.focusedWorkspaceName)
}

/// The window ids a tree keeps on the workspace it is put on by a test: apart from the ids of the other workspace's windows.
private func renumbered(_ tree: Tile, by offset: Int = 100) -> Tile {
    switch tree {
        case .window(let id):
            return .window(id + offset)
        case .split(let axis, let children):
            return .split(axis, children.map { renumbered($0, by: offset) })
    }
}

/// The members of a top container as the model prints them, so a new member can be put in front of them or after them.
private func inside(_ text: String) -> String {
    String(text.dropFirst(2).dropLast())
}

// MARK: the hop

/// The workspace trees a hop starts from: the window alone, or a window that is a child of the top row with nothing beside it on the side the
/// direction goes towards, and up to three other windows on the workspace. Windows are numbered in screen order, so the one that hops going
/// left is the first of them and the one that hops going right the last.
private func hopSources(toward direction: Direction) -> [(tree: Tile, window: Int)] {
    var sources: [(Tile, Int)] = []
    for count in 1 ... 4 {
        for tree in alternatingTrees(Array(1 ... count), rootAxis: .row) {
            if case .window(let only) = tree {
                sources.append((tree, only))
                continue
            }
            guard case .split(.row, let children) = tree,
                  let window = direction == .left ? tree.leaves.first : tree.leaves.last,
                  let index = children.firstIndex(of: .window(window)),
                  index == (direction == .left ? 0 : children.count - 1) else { continue }
            sources.append((tree, window))
        }
    }
    return sources
}

/// Every workspace a hop can land on: an empty one, one window, and every alternating tree of rows and columns for 2 to 6 windows, with the
/// windows renumbered away from the source's.
private func hopTargets() -> [(tree: Tile?, windows: Int)] {
    var targets: [(Tile?, Int)] = [(nil, 0), (renumbered(.window(1)), 1)]
    for count in 2 ... 6 {
        for axis in [Axis.row, .column] {
            for tree in alternatingTrees(Array(1 ... count), rootAxis: axis) {
                targets.append((renumbered(tree), count))
            }
        }
    }
    return targets
}

/// The tree the workspace a hop landed on prints: the window in front of the other columns going right and after them going left, and the
/// whole target wrapped in a row around the window when its top container is not a row.
private func landed(_ target: Tile?, window: Int, toward direction: Direction) -> String {
    guard let target else { return "h[\(window)]" }
    if case .window(let only) = target {
        return direction == .right ? "h[\(window), \(only)]" : "h[\(only), \(window)]"
    }
    if topAxis(of: target) == .row {
        let others = inside(treeText(target))
        return direction == .right ? "h[\(window), \(others)]" : "h[\(others), \(window)]"
    }
    return direction == .right ? "h[\(window), \(treeText(target))]" : "h[\(treeText(target)), \(window)]"
}

/// The tree the workspace a hop came from prints once the window has left it: it is unbound, a group left with one member gives that member
/// its place and a group left with none goes (`Workspace.normalizeContainers`).
private func removal(_ tree: Tile, _ window: Int) -> String {
    guard case .split(let axis, let children) = tree else { return "h[]" }
    let kept = children.filter { $0 != .window(window) }
    if case .split = kept.first, kept.count == 1 { return treeText(kept[0]) }
    return (axis == .row ? "h" : "v") + "[" + kept.map(treeText).joined(separator: ", ") + "]"
}

/// How many `move left` presses a script sends.
private func presses(_ script: String) -> Int {
    script.components(separatedBy: "--boundaries-action stop left").count - 1
}

final class DwindleHopTests: XCTestCase {
    /// Every tree a hop starts from on the workspace 2, against every workspace a hop can land on: 3 is the workspace that way, and the rule
    /// sends one line, for the window. The window ends up on 3 and focused, with 3 the focused workspace; going right it is the first column
    /// of 3's top row and the other columns are 3's own, in order and as they were, and going left it is the last; where 3's top container is
    /// a column, a row is made around it with the window as the column on the side it came from; 3 with no window has the window alone. The
    /// presses the script sends are as many as 3 has windows, and no more than that, and 2 loses the window exactly as a window leaving a
    /// workspace does.
    func testEveryHopLandsOnTheNeighbouringWorkspace() throws {
        var cases = 0
        for direction in [Direction.left, .right] {
            for (tree, window) in hopSources(toward: direction) {
                let frames = rectangles(of: tree)
                for (target, windows) in hopTargets() {
                    cases += 1
                    let label = "\(treeText(tree)), window \(window) \(direction.rawValue), "
                        + (target.map(treeText) ?? "an empty workspace")
                    let model = AeroSpaceModel()
                    // the workspace that way is 1 going left and 3 going right: next and prev take them by name
                    let there = direction == .right ? "3" : "1"
                    model.addWorkspace(there)
                    try model.build(tree, on: "2")
                    if let target { try model.build(target, on: there) }
                    try model.focus(window)

                    let move = DwindleRules.move(direction, in: reported(model, frames: frames))
                    XCTAssertEqual(move.hop, window, label)
                    XCTAssertEqual(move.commands.count, 1, label)
                    let command = try XCTUnwrap(move.commands.first, label)
                    XCTAssertEqual(command.window, window, label)
                    // a right hop presses as often as the workspace it goes to has windows, and a left hop does not need any
                    XCTAssertEqual(presses(command.script), direction == .right ? windows : 0, label)
                    try model.run(command.script, on: window)

                    XCTAssertEqual(model.workspaceName(of: window), there, label)
                    XCTAssertEqual(model.focusedWindowId, window, label)
                    XCTAssertEqual(model.focusedWorkspaceName, there, label)
                    XCTAssertEqual(model.tree(of: there), landed(target, window: window, toward: direction), label)
                    XCTAssertEqual(model.tree(of: "2"), removal(tree, window), label)
                }
            }
        }
        // the ten source trees of each direction, and 1 + 1 + 2 + 6 + 22 + 90 + 394 targets
        XCTAssertEqual(cases, 2 * 10 * 516)
    }

    /// At either end of the workspace list a hop has nowhere to go: the rule sends nothing, and the script it would have sent changes
    /// nothing, because the move to the next workspace fails and every later line tests the window's workspace first.
    func testAHopAtTheEndOfTheList() throws {
        for direction in [Direction.left, .right] {
            // the window is on the last workspace going right and on the first going left
            let source = direction == .right ? "3" : "1"
            let tree: Tile = .split(.row, [.window(1), .window(2), .window(3)])
            let window = direction == .right ? 3 : 1
            let model = AeroSpaceModel()
            model.addWorkspace(direction == .right ? "1" : "3")
            try model.build(tree, on: source)
            try model.focus(window)
            let label = "\(treeText(tree)), window \(window) \(direction.rawValue) at the end of the list"

            XCTAssertEqual(DwindleRules.move(direction, in: reported(model, frames: rectangles(of: tree))), DwindleRules.Move(), label)
            try model.run(DwindleMove.script(.hop(direction), window: window, workspace: source, tilingWindows: 3), on: window)
            XCTAssertEqual(model.tree(of: source), treeText(tree), label)
            XCTAssertEqual(model.workspaceName(of: window), source, label)
            XCTAssertEqual(model.focusedWindowId, window, label)
            XCTAssertEqual(model.focusedWorkspaceName, source, label)
        }
    }

    /// One press fewer than the workspace has windows is not enough: a row of two columns of two takes four, and with three the window
    /// stops in front of the first column instead of in front of the row.
    func testThePressesAreAsManyAsTheTargetNeeds() throws {
        let model = AeroSpaceModel()
        let row: Tile = .split(.row, [.window(1), .window(2), .window(3)])
        let target: Tile = .split(.row, [.split(.column, [.window(101), .window(102)]),
                                         .split(.column, [.window(103), .window(104)])])
        try model.build(row, on: "2")
        try model.build(target, on: "3")
        try model.focus(3)
        XCTAssertEqual(DwindleMove.script(.hop(.right), window: 3, workspace: "2", target: "3", tilingWindows: 4),
                       DwindleRules.move(.right, in: reported(model, frames: rectangles(of: row))).commands.first?.script)
        // three presses: the window is inside the first column, next to the window that column used last, and not in front of it
        try model.run(DwindleMove.script(.hop(.right), window: 3, workspace: "2", target: "3", tilingWindows: 3), on: 3)
        XCTAssertEqual(model.tree(of: "3"), "h[v[101, 3, 102], v[103, 104]]")
        XCTAssertEqual(model.workspaceName(of: 3), "3")

        // four, which is what the rule sends: in front of both columns
        let again = AeroSpaceModel()
        try again.build(row, on: "2")
        try again.build(target, on: "3")
        try again.focus(3)
        try again.run(DwindleMove.script(.hop(.right), window: 3, workspace: "2", target: "3", tilingWindows: 4), on: 3)
        XCTAssertEqual(again.tree(of: "3"), "h[3, v[101, 102], v[103, 104]]")
    }

    /// A hop stays on the workspace's own monitor, empty workspaces included: of 1, 2 and 4 on the first monitor and 3 and 5 on the second,
    /// a hop right from 2 lands on 4 and a hop left from 4 lands on 2, never on the empty 3.
    func testAHopStaysOnTheMonitorOfTheWorkspace() throws {
        let model = AeroSpaceModel()
        for name in ["1", "2", "4"] { model.addWorkspace(name, on: 1) }
        for name in ["3", "5"] { model.addWorkspace(name, on: 2) }
        let row: Tile = .split(.row, [.window(1), .window(2), .window(3)])
        try model.build(row, on: "2")
        try model.focus(3)

        let right = DwindleRules.move(.right, in: reported(model, frames: rectangles(of: row)))
        XCTAssertEqual(right.hop, 3)
        try model.run(try XCTUnwrap(right.commands.first).script, on: 3)
        XCTAssertEqual(model.workspaceName(of: 3), "4")
        XCTAssertEqual(model.tree(of: "4"), "h[3]")
        XCTAssertEqual(model.tree(of: "2"), "h[1, 2]")
        XCTAssertEqual(model.focusedWorkspaceName, "4")

        // and back: 4's left neighbour is 2, the workspace before it on the first monitor
        let left = DwindleRules.move(.left, in: reported(model, frames: rectangles(of: .window(3))))
        XCTAssertEqual(left.hop, 3)
        try model.run(try XCTUnwrap(left.commands.first).script, on: 3)
        XCTAssertEqual(model.workspaceName(of: 3), "2")
        XCTAssertEqual(model.tree(of: "2"), "h[1, 2, 3]")
        XCTAssertEqual(model.tree(of: "4"), "h[]")
    }

    /// A workspace whose monitor riskell does not know counts as every monitor's, and a focused workspace whose own is unknown goes by name
    /// alone, as it did before monitors were known.
    func testAnUnknownMonitorCountsAsEveryMonitor() throws {
        let row: Tile = .split(.row, [.window(1), .window(2), .window(3)])
        let model = AeroSpaceModel()
        try model.build(row, on: "2")
        try model.build(.split(.row, [.window(11), .window(12)]), on: "3")
        try model.focus(3)
        let unknown = reported(model, frames: rectangles(of: row))

        // every monitor unknown: the workspaces are taken by name, as before
        var allUnknown = unknown
        allUnknown.workspaces = allUnknown.workspaces.map {
            ManagedWorkspace(name: $0.name, rootLayout: $0.rootLayout, landscape: $0.landscape)
        }
        XCTAssertEqual(DwindleRules.move(.right, in: allUnknown).hop, 3)
        XCTAssertEqual(DwindleRules.focus(.right, in: allUnknown), [ManagerCommand("workspace 3; focus --dfs-index 0")])

        // the focused workspace's own monitor unknown: the next workspace by name, whatever monitor it has
        var ownUnknown = unknown
        ownUnknown.workspaces = ownUnknown.workspaces.map {
            ManagedWorkspace(name: $0.name, rootLayout: $0.rootLayout, landscape: $0.landscape,
                             monitor: $0.name == "2" ? nil : 2)
        }
        XCTAssertEqual(DwindleRules.move(.right, in: ownUnknown).hop, 3)
        XCTAssertEqual(DwindleRules.focus(.right, in: ownUnknown), [ManagerCommand("workspace 3; focus --dfs-index 0")])

        // a neighbour whose monitor is unknown is on every monitor, so it is the one next door
        var neighbourUnknown = unknown
        neighbourUnknown.workspaces = neighbourUnknown.workspaces.map {
            ManagedWorkspace(name: $0.name, rootLayout: $0.rootLayout, landscape: $0.landscape,
                             monitor: $0.name == "3" ? nil : 1)
        }
        XCTAssertEqual(DwindleRules.move(.right, in: neighbourUnknown).hop, 3)
        // and a neighbour on another monitor that is known is not
        var elsewhere = unknown
        elsewhere.workspaces = elsewhere.workspaces.map {
            ManagedWorkspace(name: $0.name, rootLayout: $0.rootLayout, landscape: $0.landscape,
                             monitor: $0.name == "3" ? 2 : 1)
        }
        XCTAssertEqual(DwindleRules.move(.right, in: elsewhere), DwindleRules.Move())
        XCTAssertEqual(DwindleRules.focus(.right, in: elsewhere), [])
    }
}

// MARK: the focus at the edge

/// Where the window sits: the axis of every group above it, the place of the branch that leads to it and how many members that group holds.
private func groups(_ window: Int, in tree: Tile) -> [(axis: Axis, index: Int, count: Int)] {
    var path: [(Axis, Int, Int)] = []
    _ = search(window, tree, &path)
    return path
}

private func search(_ window: Int, _ tile: Tile, _ path: inout [(Axis, Int, Int)]) -> Bool {
    switch tile {
        case .window(let id):
            return id == window
        case .split(let axis, let children):
            for (index, child) in children.enumerated() {
                path.append((axis, index, children.count))
                if search(window, child, &path) { return true }
                path.removeLast()
            }
            return false
    }
}

/// True when nothing is beside the window that way on any group above it: the edge of the workspace, as far as a focus is concerned.
private func nothingBeside(_ tree: Tile, window: Int, toward direction: Direction) -> Bool {
    groups(window, in: tree).allSatisfy { group in
        group.axis != direction.axis || !(0 ..< group.count).contains(group.index + direction.offset)
    }
}

/// A model with the workspace 2 holding `tree` and a workspace either side of it, and what riskell would know of that: the first window of
/// 3 in tree order is 11 and the last window of 1 is 23.
private func focusWorld(_ tree: Tile, window: Int) throws -> (model: AeroSpaceModel, state: ManagerState) {
    let model = AeroSpaceModel()
    try model.build(.split(.column, [.window(21), .split(.row, [.window(22), .window(23)])]), on: "1")
    try model.build(.split(.row, [.window(11), .split(.column, [.window(12), .window(13)])]), on: "3")
    try model.build(tree, on: "2")
    try model.focus(window)
    return (model, reported(model, frames: rectangles(of: tree)))
}

final class DwindleFocusTests: XCTestCase {
    /// Every tree of 1 to 4 windows, both top axes, every window and all four directions: the rule says nothing unless nothing is beside
    /// the window that way, and only left and right count. At the edge the line takes the focus to the workspace that way, to its first
    /// window going right and its last going left.
    func testFocusOnlyLeavesTheWorkspaceAtTheEdge() throws {
        var cases = 0
        var edges = 0
        for count in 1 ... 4 {
            let leaves = Array(1 ... count)
            for axis in [Axis.row, .column] {
                for tree in alternatingTrees(leaves, rootAxis: axis) {
                    for window in leaves {
                        for direction in [Direction.left, .right, .up, .down] {
                            cases += 1
                            let label = "\(treeText(tree)), window \(window) \(direction.rawValue)"
                            let edge = nothingBeside(tree, window: window, toward: direction)
                            XCTAssertEqual(edge, DwindleMove.isAtEdge(in: tree, window: window, toward: direction), label)
                            let world = try focusWorld(tree, window: window)
                            guard direction.axis == .row, edge else {
                                XCTAssertEqual(DwindleRules.focus(direction, in: world.state), [], label)
                                continue
                            }
                            edges += 1
                            let commands = DwindleRules.focus(direction, in: world.state)
                            XCTAssertEqual(commands.count, 1, label)
                            let command = try XCTUnwrap(commands.first, label)
                            XCTAssertNil(command.window, label)
                            try world.model.run(command.script, on: window)
                            if direction == .right {
                                XCTAssertEqual(command.script, "workspace 3; focus --dfs-index 0", label)
                                XCTAssertEqual(world.model.focusedWorkspaceName, "3", label)
                                XCTAssertEqual(world.model.focusedWindowId, 11, label)
                            } else {
                                XCTAssertEqual(command.script, "workspace 1; focus --dfs-index 2", label)
                                XCTAssertEqual(world.model.focusedWorkspaceName, "1", label)
                                XCTAssertEqual(world.model.focusedWindowId, 23, label)
                            }
                        }
                    }
                }
            }
        }
        // every tree of 1 to 4 windows, both top axes, every window and all four directions
        XCTAssertEqual(cases, 448)
        XCTAssertEqual(edges, 124)
    }

    /// A workspace with no window takes the focus and nothing else, and the ends of the list and the other directions send nothing at all.
    func testFocusOnAnEmptyNeighbourIsOnlyTheWorkspace() throws {
        let model = AeroSpaceModel()
        let row: Tile = .split(.row, [.window(1), .window(2)])
        try model.build(row, on: "1")
        model.addWorkspace("2")
        try model.focus(2)
        let commands = DwindleRules.focus(.right, in: reported(model, frames: rectangles(of: row)))
        XCTAssertEqual(commands, [ManagerCommand("workspace 2")])
        try model.run(try XCTUnwrap(commands.first).script, on: 2)
        XCTAssertEqual(model.focusedWorkspaceName, "2")
        XCTAssertNil(model.focusedWindowId)

        // the last workspace has nothing to its right, the first nothing to its left
        let last = AeroSpaceModel()
        try last.build(row, on: "2")
        try last.focus(2)
        XCTAssertEqual(DwindleRules.focus(.right, in: reported(last, frames: rectangles(of: row))), [])
        let first = AeroSpaceModel()
        try first.build(row, on: "1")
        try first.focus(1)
        XCTAssertEqual(DwindleRules.focus(.left, in: reported(first, frames: rectangles(of: row))), [])

        // up and down never leave the workspace, however little is above the window
        let tall: Tile = .split(.column, [.window(1), .window(2)])
        let up = AeroSpaceModel()
        try up.build(tall, on: "1")
        up.addWorkspace("2")
        try up.focus(1)
        XCTAssertEqual(DwindleRules.focus(.up, in: reported(up, frames: rectangles(of: tall))), [])

        // a window without a frame, and a layout that cannot be read
        var unreadable = reported(up, frames: rectangles(of: tall))
        unreadable.windows[0] = ManagedWindow(id: 1, workspace: "1", floating: false)
        XCTAssertEqual(DwindleRules.focus(.right, in: unreadable), [])
    }

    /// The focus goes to the workspace of the same monitor: from 2 to 4 and never to the empty 3 of the other monitor, from 4 nowhere
    /// because it is the last of its monitor, and from 3 to 5 on the second one.
    func testFocusStaysOnTheMonitorOfTheWorkspace() throws {
        let model = AeroSpaceModel()
        for name in ["1", "2", "4"] { model.addWorkspace(name, on: 1) }
        for name in ["3", "5"] { model.addWorkspace(name, on: 2) }
        let row2: Tile = .split(.row, [.window(1), .window(2), .window(3)])
        try model.build(row2, on: "2")
        try model.focus(3)

        // 4 is empty: the focus goes there and no further
        let toFour = DwindleRules.focus(.right, in: reported(model, frames: rectangles(of: row2)))
        XCTAssertEqual(toFour, [ManagerCommand("workspace 4")])
        try model.run(try XCTUnwrap(toFour.first).script, on: 3)
        XCTAssertEqual(model.focusedWorkspaceName, "4")
        XCTAssertNil(model.focusedWindowId)

        // 4 is the last of its monitor: with a window on it, its right edge has nowhere to go
        let row4: Tile = .split(.row, [.window(11), .window(12)])
        try model.build(row4, on: "4")
        try model.focus(12)
        XCTAssertEqual(DwindleRules.focus(.right, in: reported(model, frames: rectangles(of: row4))), [])

        // on the second monitor 3 goes to 5, never to 4
        let row3: Tile = .split(.row, [.window(21), .window(22)])
        try model.build(row3, on: "3")
        try model.build(.split(.row, [.window(31), .window(32)]), on: "5")
        try model.focus(22)
        let toFive = DwindleRules.focus(.right, in: reported(model, frames: rectangles(of: row3)))
        XCTAssertEqual(toFive, [ManagerCommand("workspace 5; focus --dfs-index 0")])
        try model.run(try XCTUnwrap(toFive.first).script, on: 22)
        XCTAssertEqual(model.focusedWorkspaceName, "5")
        XCTAssertEqual(model.focusedWindowId, 31)
    }
}

// MARK: the behaviour

final class DwindleHopHookTests: XCTestCase {
    private func dwindle(_ settings: [String: Any] = [:]) -> DwindleAerospace {
        let dwindle = DwindleAerospace()
        _ = dwindle.start(Env(id: "dwindle-aerospace", prefs: Prefs(json: settings)))
        return dwindle
    }

    /// The row of three windows on workspace 2 with the last one focused, and the two windows of workspace 3 beside it: the last column of
    /// the row hops to 3 when it is moved right.
    private func hopWorld() throws -> (model: AeroSpaceModel, state: ManagerState) {
        let model = AeroSpaceModel()
        let row: Tile = .split(.row, [.window(1), .window(2), .window(3)])
        try model.build(row, on: "2")
        try model.build(.split(.row, [.window(11), .window(12)]), on: "3")
        try model.focus(3)
        return (model, reported(model, frames: rectangles(of: row)))
    }

    /// The model and what riskell would know of it once the hop has run: window 3 is on workspace 3, beside the two windows there.
    private func afterHop() throws -> (model: AeroSpaceModel, state: ManagerState) {
        let world = try hopWorld()
        let move = DwindleRules.move(.right, in: world.state)
        try world.model.run(try XCTUnwrap(move.commands.first).script, on: 3)
        return (world.model, reported(world.model, frames: rectangles(of: .split(.row, [.window(11), .window(12), .window(3)]))))
    }

    private let key = ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-l"])

    func testAHopKeySendsItsCommandsAndItsArrivalIsIgnoredOnce() throws {
        let world = try hopWorld()
        let behaviour = dwindle(["moveRightKey": "alt-l"])
        let move = DwindleRules.move(.right, in: world.state)
        XCTAssertEqual(move.hop, 3)
        XCTAssertEqual(behaviour.commands(for: key, in: world.state), move.commands)

        // the arrival of the window the hop sent is the hop's own doing, so it is not placed like a new window
        let arrived = ManagerEvent(name: "window-arrived", fields: ["windowId": "3", "workspace": "3"])
        XCTAssertEqual(behaviour.commands(for: arrived, in: world.state), [])
        // a later arrival of the same window is placed as any arrival on that workspace
        let after = try afterHop()
        XCTAssertEqual(behaviour.commands(for: arrived, in: after.state),
                       DwindleRules.split(window: 3, on: "3", in: after.state))
        XCTAssertEqual(behaviour.commands(for: arrived, in: after.state).count, 1)
    }

    func testAKeyThatSendsNoHopSwallowsNoArrival() throws {
        let behaviour = dwindle(["moveRightKey": "alt-l"])
        // the window is the last column of the last workspace: the move has nowhere to go, so nothing is sent
        let model = AeroSpaceModel()
        let row: Tile = .split(.row, [.window(1), .window(2), .window(3)])
        try model.build(row, on: "2")
        try model.focus(3)
        let state = reported(model, frames: rectangles(of: row))
        XCTAssertEqual(DwindleRules.move(.right, in: state), DwindleRules.Move())
        XCTAssertEqual(behaviour.commands(for: key, in: state), [])
        let arrived = ManagerEvent(name: "window-arrived", fields: ["windowId": "3", "workspace": "2"])
        XCTAssertEqual(behaviour.commands(for: arrived, in: state), DwindleRules.split(window: 3, on: "2", in: state))
    }

    func testALaterBindingClearsAStaleHop() throws {
        let world = try hopWorld()
        let behaviour = dwindle(["moveRightKey": "alt-l", "tidyKey": "alt-shift-t"])
        XCTAssertEqual(behaviour.commands(for: key, in: world.state), DwindleRules.move(.right, in: world.state).commands)
        // a second binding comes before any arrival: the hop is stale and must not swallow a later one
        _ = behaviour.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-shift-t"]), in: world.state)
        let arrived = ManagerEvent(name: "window-arrived", fields: ["windowId": "3", "workspace": "3"])
        XCTAssertEqual(behaviour.commands(for: arrived, in: world.state),
                       DwindleRules.split(window: 3, on: "3", in: world.state))
    }

    func testAFocusKeySendsTheFocusCommands() throws {
        let world = try hopWorld()
        let behaviour = dwindle(["focusRightKey": "ctrl-alt-right"])
        let event = ManagerEvent(name: "binding-triggered", fields: ["binding": "ctrl-alt-right"])
        XCTAssertEqual(behaviour.commands(for: event, in: world.state), DwindleRules.focus(.right, in: world.state))
        XCTAssertEqual(behaviour.commands(for: event, in: world.state), [ManagerCommand("workspace 3; focus --dfs-index 0")])
    }

    func testOnlyTheMoveAndFocusKeysAskForFrames() throws {
        let behaviour = dwindle(["moveRightKey": "alt-l", "focusRightKey": "ctrl-alt-right", "tidyKey": "alt-shift-t"])
        let move = ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-l"])
        let focus = ManagerEvent(name: "binding-triggered", fields: ["binding": "ctrl-alt-right"])
        XCTAssertTrue(behaviour.needsFrames(for: move))
        XCTAssertTrue(behaviour.needsFrames(for: focus))
        XCTAssertFalse(behaviour.needsFrames(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-shift-t"])))
        XCTAssertFalse(behaviour.needsFrames(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-h"])))
        XCTAssertFalse(behaviour.needsFrames(for: ManagerEvent(name: "window-arrived", fields: ["windowId": "3"])))
        // a behaviour that has not started has no settings to read
        XCTAssertFalse(DwindleAerospace().needsFrames(for: move))
    }

    func testItWantsOnlyTheBindingsItActsOn() {
        let behaviour = dwindle(["moveRightKey": "alt-l", "focusRightKey": "ctrl-alt-right", "tidyKey": "alt-shift-t"])
        for binding in ["alt-l", "ctrl-alt-right", "alt-shift-t"] {
            XCTAssertTrue(behaviour.wants(ManagerEvent(name: "binding-triggered", fields: ["binding": binding])), binding)
        }
        for binding in ["alt-h", "alt-j", ""] {
            XCTAssertFalse(behaviour.wants(ManagerEvent(name: "binding-triggered", fields: ["binding": binding])), binding)
        }
        XCTAssertFalse(behaviour.wants(ManagerEvent(name: "binding-triggered")))
        // every other event is wanted: the tidying comes from its key, the placements from the two window events
        for name in [ManagerEvent.windowDetected, ManagerEvent.windowArrived, "focus-changed"] {
            XCTAssertTrue(behaviour.wants(ManagerEvent(name: name, fields: ["windowId": "3"])), name)
        }
        // before it starts it wants nothing
        XCTAssertFalse(DwindleAerospace().wants(ManagerEvent(name: ManagerEvent.windowDetected, fields: ["windowId": "3"])))
        XCTAssertFalse(DwindleAerospace().wants(ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-l"])))
    }
}
