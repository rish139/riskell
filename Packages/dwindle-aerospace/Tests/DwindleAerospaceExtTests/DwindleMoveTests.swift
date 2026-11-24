// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import XCTest
@testable import DwindleAerospaceExt

/// The move rule on the layout itself: a tree of rows and columns with any number of members per group, never rebuilt. A window either
/// merges with the single window beside it, enters the group beside it, leaves its own group for the group above, has the workspace wrapped
/// around it when its own group is the whole workspace and runs across the direction, or, when it is a column of its own at the edge of the
/// workspace, leaves the workspace for the next one that way. This is the source of truth for the tests: it answers with the tree the move
/// has to leave, and knows nothing of AeroSpace's commands.
private enum Rule {
    /// `nil` when the move changes nothing: nothing is beside the window that way in its own group, and there is no group above it to
    /// leave for because it is not in the group that is the whole workspace, or its own group runs along the direction.
    static func moved(_ tree: Tile, window: Int, toward direction: Direction, in slots: [Slot]) -> Tile? {
        let root = Member(tree)
        guard let top = root.axis, let own = root.member(window), let parent = own.parent else { return nil }
        let outward: Axis = direction.axis == .row ? .column : .row
        let beside = (own.index ?? 0) + direction.offset
        if parent.axis == direction.axis, parent.members.indices.contains(beside) {
            let neighbour = parent.members[beside]
            if neighbour.id != nil {
                // a group of the two takes the neighbour's place, the window on the side it came from
                let place = neighbour.index ?? 0
                let ownPlace = own.index ?? 0
                neighbour.detach()
                own.detach()
                let group = Member(group: outward)
                for member in direction.offset < 0 ? [neighbour, own] : [own, neighbour] {
                    group.append(member)
                }
                // the group goes where the neighbour was, one place earlier when the window itself was in front of it
                parent.add(group, at: ownPlace < place ? place - 1 : place)
            } else {
                // the window enters the group beside it, next to the member it is level with across that group's own axis
                guard let axis = neighbour.axis, let level = neighbour.level(with: own, along: axis, in: slots) else { return nil }
                own.detach()
                if level.id != nil {
                    level.parent?.add(own, at: (level.index ?? 0) + 1)
                } else {
                    level.add(own, at: 0)
                }
            }
        } else {
            // the innermost group from the window's own one up whose own group runs along the direction: the window leaves for that one
            var group: Member? = parent
            while let candidate = group, candidate.parent?.axis != direction.axis {
                group = candidate.parent
            }
            if let target = group, let above = target.parent {
                let place = target.index ?? 0
                own.detach()
                above.add(own, at: direction.offset > 0 ? place + 1 : place)
            } else {
                // the window sits in the group that is the whole workspace, and that group runs across the direction: the workspace
                // becomes a group along the direction, the window on the side it moves towards and the rest of the old group beside it
                guard parent.parent == nil, parent.axis != direction.axis else { return nil }
                own.detach()
                let wrapped = Member(group: direction.axis)
                for member in direction.offset < 0 ? [own, root] : [root, own] {
                    wrapped.append(member)
                }
                return settled(wrapped).tile()
            }
        }
        return settled(root).tile()
    }

    /// True when the window is a column of its own at the edge the direction goes towards, or the only window of the workspace and the
    /// direction is horizontal: the move then leaves the workspace, and where the layout says nothing about that, the tests do not run it.
    static func hops(_ tree: Tile, window: Int, toward direction: Direction) -> Bool {
        guard direction.axis == .row else { return false }
        let root = Member(tree)
        guard let own = root.member(window) else { return false }
        guard let parent = own.parent else { return true }
        return parent.parent == nil && parent.axis == direction.axis
            && !parent.members.indices.contains((own.index ?? 0) + direction.offset)
    }

    /// The top container keeps its own axis, and gives its place to the group it is left with, which keeps its axis in turn.
    private static func settled(_ root: Member) -> Member {
        guard let axis = root.axis else { return root }
        let kept = members(of: root, axis: axis)
        root.members = kept
        return kept.count == 1 ? kept[0] : root
    }

    /// A group left with one member is replaced by that member: it takes the group's place, so it takes the axis of that depth. A group
    /// left with no member goes.
    private static func normalised(_ member: Member, axis: Axis) -> Member {
        guard member.id == nil else { return member }
        member.axis = axis
        let kept = members(of: member, axis: axis)
        member.members = kept
        return kept.count == 1 ? normalised(kept[0], axis: axis) : member
    }

    private static func members(of member: Member, axis: Axis) -> [Member] {
        let inner: Axis = axis == .row ? .column : .row
        return member.members.map { normalised($0, axis: inner) }
    }
}

/// A member of the layout: a window, or a group of any number of members laid out along its axis. It is kept mutable so that a rule is
/// the little surgery it describes.
private final class Member {
    var axis: Axis?
    let id: Int?
    var members: [Member] = []
    weak var parent: Member?

    init(window id: Int) {
        self.axis = nil
        self.id = id
    }

    init(group axis: Axis) {
        self.axis = axis
        self.id = nil
    }

    convenience init(_ tile: Tile) {
        switch tile {
            case .window(let id):
                self.init(window: id)
            case .split(let axis, let children):
                self.init(group: axis)
                for child in children {
                    append(Member(child))
                }
        }
    }

    /// The windows below this, in screen order.
    var leaves: [Int] { id.map { [$0] } ?? members.flatMap(\.leaves) }

    var index: Int? { parent?.members.firstIndex { $0 === self } }

    func append(_ member: Member) { add(member, at: members.count) }

    func add(_ member: Member, at index: Int) {
        member.detach()
        members.insert(member, at: index)
        member.parent = self
    }

    func detach() {
        guard let parent, let index else { return }
        parent.members.remove(at: index)
        self.parent = nil
    }

    /// The window with that id, anywhere below this.
    func member(_ window: Int) -> Member? {
        if id == window { return self }
        for child in members {
            if let found = child.member(window) { return found }
        }
        return nil
    }

    /// The member that shares the most of `axis` with `own`, the first of them when two share as much.
    func level(with own: Member, along axis: Axis, in slots: [Slot]) -> Member? {
        var best: Member?
        var most = -Double.infinity
        for member in members {
            let shared = overlap(member, with: own, along: axis, in: slots)
            if shared > most {
                best = member
                most = shared
            }
        }
        return best
    }

    /// How far this member's rectangle and `own`'s reach over each other along `axis`.
    private func overlap(_ first: Member, with second: Member, along axis: Axis, in slots: [Slot]) -> Double {
        guard let mine = extent(first, along: axis, in: slots), let theirs = extent(second, along: axis, in: slots) else {
            return -.infinity
        }
        return min(mine.high, theirs.high) - max(mine.low, theirs.low)
    }

    private func extent(_ member: Member, along axis: Axis, in slots: [Slot]) -> (low: Double, high: Double)? {
        let ids = member.leaves
        let inside = slots.filter { ids.contains($0.id) }
        guard !inside.isEmpty else { return nil }
        switch axis {
            case .row:
                return (inside.map(\.x0).min() ?? 0, inside.map(\.x1).max() ?? 0)
            case .column:
                return (inside.map(\.y0).min() ?? 0, inside.map(\.y1).max() ?? 0)
        }
    }

    func tile() -> Tile {
        guard let id else { return .split(axis ?? .row, members.map { $0.tile() }) }
        return .window(id)
    }
}

final class DwindleMoveTests: XCTestCase {
    /// Every tree of rows and columns for 2 to 6 windows, on both top axes: for every window and every direction the step exists exactly
    /// when the rule has an answer or the window leaves the workspace, and the commands leave the model with the tree the rule names, the
    /// window focused, the same windows and none floating. A hop needs a workspace beside this one, so the model is left out of it.
    func testEveryTreeOfEveryWindowAndDirection() throws {
        var trees = 0
        var cases = 0
        var wraps = 0
        var hops = 0
        for count in 2 ... 6 {
            let leaves = Array(1 ... count)
            for axis in [Axis.row, .column] {
                for tree in alternatingTrees(leaves, rootAxis: axis) {
                    trees += 1
                    XCTAssertEqual(tree.leaves, leaves, "\(treeText(tree)) is not the windows in screen order")
                    let slots = rectangles(of: tree)
                    XCTAssertEqual(FrameTree.read(slots, rootAxis: axis, tolerance: DwindleRules.frameTolerance), .tree(tree),
                                   "\(treeText(tree)): the frames do not read back as the tree")
                    for window in leaves {
                        for direction in [Direction.left, .right, .up, .down] {
                            cases += 1
                            let label = "\(treeText(tree)), window \(window) \(direction.rawValue)"
                            let expected = Rule.moved(tree, window: window, toward: direction, in: slots)
                            let step = DwindleMove.step(in: tree, window: window, toward: direction, slots: slots)
                            if case .wrap = step { wraps += 1 }
                            if Rule.hops(tree, window: window, toward: direction) {
                                hops += 1
                                XCTAssertEqual(step, .hop(direction), "\(label): the rule says hop here")
                                XCTAssertNil(expected, "\(label): a hop is not a layout the rule can name")
                                continue
                            }
                            XCTAssertNotEqual(step, .hop(direction), "\(label): a hop where the rule has a layout")
                            guard let expected else {
                                XCTAssertNil(step, "\(label): the rule changes nothing here")
                                continue
                            }
                            XCTAssertNotNil(step, "\(label): the rule has an answer")
                            guard let step else { continue }
                            let model = try model(of: tree)
                            try model.focus(window)
                            XCTAssertEqual(try model.run(DwindleMove.script(step, window: window), on: window), 0, label)
                            XCTAssertEqual(model.focusedWindowId, window, "\(label): the window is not focused afterwards")
                            XCTAssertEqual(model.windowIds, leaves, "\(label): the windows are not the same afterwards")
                            for id in leaves {
                                XCTAssertFalse(model.isFloating(id), "\(label): window \(id) floats afterwards")
                            }
                            let printed = try XCTUnwrap(model.tree(of: "1"), label)
                            XCTAssertEqual(treeReading(printed), expected, "\(label): the model leaves \(printed)")
                        }
                    }
                }
            }
        }
        // 1 + 3 + 11 + 45 + 197 alternations under a row, each also under a column; and four windows and four directions of each. A
        // workspace that runs across the direction is wrapped, the window on the side it moves towards
        XCTAssertEqual(trees, 514)
        XCTAssertEqual(cases, 11_696)
        XCTAssertEqual(wraps, 1324)
        XCTAssertEqual(hops, 242)
        XCTAssertGreaterThan(cases, 1000)
    }

    /// The known cases of one real layout: a row of shells and documents, and a column of browser windows.
    func testTheNamedCasesOfTheRealLayout() throws {
        let start = real

        // window 4 leaves its column for the row above it: it lands right after the column, which keeps two windows
        let model = try model(of: start)
        try model.focus(4)
        let leaving = try XCTUnwrap(move(start, window: 4, toward: .left))
        XCTAssertEqual(treeText(leaving.tree), "h[1, 2, 4, v[3, 5]]")
        XCTAssertEqual(try model.run(leaving.script, on: 4), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, 2, 4, v[3, 5]]")
        // and again, on the layout that move left: the window beside it is a single window, so the two make a column in its place
        let now = try XCTUnwrap(treeReading("h[1, 2, 4, v[3, 5]]"), "the layout read back")
        let again = try XCTUnwrap(move(now, window: 4, toward: .left), "the move")
        XCTAssertEqual(treeText(again.tree), "h[1, v[2, 4], v[3, 5]]")
        XCTAssertEqual(try model.run(again.script, on: 4), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, 4], v[3, 5]]")
        XCTAssertEqual(model.focusedWindowId, 4)

        // window 4 up joins the window above it in its own column: a row of the two takes its place there
        XCTAssertEqual(try after(start, window: 4, toward: .up), "h[1, 2, v[h[3, 4], 5]]")
        // window 2 right enters the column beside it, level with the member that reaches over it most
        XCTAssertEqual(try after(start, window: 2, toward: .right), "h[1, v[3, 4, 5, 2]]")
        // window 4 right leaves its column for the row above it, after the column
        XCTAssertEqual(try after(start, window: 4, toward: .right), "h[1, 2, v[3, 5], 4]")

        // window 1 left is the first column of the row, so nothing is beside it and it leaves the workspace for the next one
        assertHop(start, window: 1, toward: .left)
        // window 5 down is at the bottom of its column, and its column is the whole workspace's row
        assertNothing(start, window: 5, toward: .down)
        // a window that is not there
        assertNothing(start, window: 9, toward: .left)
    }

    /// The known cases of a two-window workspace, a search and a terminal: a row to start with, then the same two windows stacked, and a
    /// stack of three.
    func testTheNamedCasesOfTwoWindows() throws {
        let start: Tile = .split(.row, [.window(1), .window(2)])
        let model = try model(of: start)
        try model.focus(2)

        // window 2 left has a single window beside it: the two make a column where the row was, the window after it
        let joined = try XCTUnwrap(move(start, window: 2, toward: .left), "the move")
        XCTAssertEqual(joined.script, "join-with --window-id 2 left")
        XCTAssertEqual(treeText(joined.tree), "v[1, 2]")
        XCTAssertEqual(try model.run(joined.script, on: 2), 0)
        XCTAssertEqual(model.tree(of: "1"), "v[1, 2]")

        // and again, on the column the model left: window 2 is in the group that is the whole workspace and that group runs across the
        // direction, so the workspace becomes a row with the window first
        let column = try XCTUnwrap(treeReading("v[1, 2]"), "the layout read back")
        let wrapped = try XCTUnwrap(move(column, window: 2, toward: .left), "the move")
        XCTAssertEqual(wrapped.script, "move --window-id 2 --boundaries-action create-implicit-container left")
        XCTAssertEqual(treeText(wrapped.tree), "h[2, 1]")
        XCTAssertEqual(try model.run(wrapped.script, on: 2), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[2, 1]")
        XCTAssertEqual(model.focusedWindowId, 2)

        // and back: window 2 right has a single window beside it, and the column it makes has the window after it
        let row = try XCTUnwrap(treeReading("h[2, 1]"), "the layout read back")
        let back = try XCTUnwrap(move(row, window: 2, toward: .right), "the move")
        XCTAssertEqual(back.script, "join-with --window-id 2 right")
        XCTAssertEqual(treeText(back.tree), "v[2, 1]")
        XCTAssertEqual(try model.run(back.script, on: 2), 0)
        XCTAssertEqual(model.tree(of: "1"), "v[2, 1]")

        // window 1 right on the column wraps it the other way round: the rest of the old group first, the window last
        let otherWay = try XCTUnwrap(move(column, window: 1, toward: .right), "the move")
        XCTAssertEqual(otherWay.script, "move --window-id 1 --boundaries-action create-implicit-container right")
        XCTAssertEqual(treeText(otherWay.tree), "h[2, 1]")
        XCTAssertEqual(try after(column, window: 1, toward: .right), "h[2, 1]")

        // a stack of three: window 2 leaves the workspace's column for a row, the rest of the column beside it, on the side it moved
        // away from
        XCTAssertEqual(try after(stack, window: 2, toward: .left), "h[2, v[1, 3]]")
        XCTAssertEqual(try after(stack, window: 2, toward: .right), "h[v[1, 3], 2]")
    }

    /// A row inside the stack that is the whole workspace: at the end of that row there is nothing beside the window and no group above
    /// it that runs along the direction, so neither end moves.
    func testNothingAtTheEndOfARowInsideAStack() {
        let tree: Tile = .split(.column, [.window(1), .split(.row, [.window(2), .window(3)])])
        XCTAssertEqual(treeText(tree), "v[1, h[2, 3]]")
        assertNothing(tree, window: 2, toward: .left)
        assertNothing(tree, window: 3, toward: .right)
    }

    /// The column of 1, 2 and 3 that the named cases stack.
    private var stack: Tile {
        .split(.column, [.window(1), .window(2), .window(3)])
    }

    /// The row of 1 and 2 and the column of 3, 4 and 5 that the named cases come from.
    private var real: Tile {
        .split(.row, [.window(1), .window(2), .split(.column, [.window(3), .window(4), .window(5)])])
    }

    /// The rule's tree for one move and the step's commands for it, both or neither.
    private func move(_ start: Tile, window: Int, toward direction: Direction, file: StaticString = #filePath,
                      line: UInt = #line) -> (script: String, tree: Tile)? {
        let slots = rectangles(of: start, file: file, line: line)
        let expected = Rule.moved(start, window: window, toward: direction, in: slots)
        let step = DwindleMove.step(in: start, window: window, toward: direction, slots: slots)
        let label = "\(treeText(start)), window \(window) \(direction.rawValue)"
        XCTAssertEqual(expected != nil, step != nil, "\(label): the rule and the step disagree", file: file, line: line)
        guard let expected, let step else { return nil }
        return (DwindleMove.script(step, window: window), expected)
    }

    /// The tree the model prints after one move, with the rule's tree and the step's commands asserted to be that move's.
    private func after(_ start: Tile, window: Int, toward direction: Direction, file: StaticString = #filePath,
                       line: UInt = #line) throws -> String {
        let next = try XCTUnwrap(move(start, window: window, toward: direction, file: file, line: line))
        let model = try model(of: start)
        try model.focus(window)
        XCTAssertEqual(try model.run(next.script, on: window), 0, file: file, line: line)
        let printed = try XCTUnwrap(model.tree(of: "1"), file: file, line: line)
        XCTAssertEqual(treeReading(printed), next.tree, "\(treeText(start)), window \(window) \(direction.rawValue)",
                       file: file, line: line)
        XCTAssertEqual(model.focusedWindowId, window, file: file, line: line)
        XCTAssertEqual(model.windowIds, start.leaves.sorted(), file: file, line: line)
        return printed
    }

    /// A move that changes nothing: the rule has no answer and there is no step.
    /// A move that leaves the workspace: the rule says hop and there is no tree for it.
    private func assertHop(_ start: Tile, window: Int, toward direction: Direction, file: StaticString = #filePath,
                           line: UInt = #line) {
        let slots = rectangles(of: start)
        let label = "\(treeText(start)), window \(window) \(direction.rawValue)"
        XCTAssertTrue(Rule.hops(start, window: window, toward: direction), "\(label): the rule says nothing beside it", file: file, line: line)
        XCTAssertNil(Rule.moved(start, window: window, toward: direction, in: slots), "\(label): the rule has a tree", file: file, line: line)
        XCTAssertEqual(DwindleMove.step(in: start, window: window, toward: direction, slots: slots), .hop(direction),
                       "\(label): there is no hop", file: file, line: line)
    }

    private func assertNothing(_ start: Tile, window: Int, toward direction: Direction, file: StaticString = #filePath,
                                  line: UInt = #line) {
        let slots = rectangles(of: start)
        let label = "\(treeText(start)), window \(window) \(direction.rawValue)"
        XCTAssertNil(Rule.moved(start, window: window, toward: direction, in: slots), "\(label): the rule has an answer", file: file, line: line)
        XCTAssertNil(DwindleMove.step(in: start, window: window, toward: direction, slots: slots), "\(label): there is a step", file: file, line: line)
    }

    func testTheCommandsOfEachStep() throws {
        XCTAssertEqual(DwindleMove.script(.join(.left), window: 7), "join-with --window-id 7 left")
        XCTAssertEqual(DwindleMove.script(.join(.down), window: 3), "join-with --window-id 3 down")
        XCTAssertEqual(DwindleMove.script(.enter(.right, via: 5), window: 2),
                       "focus --window-id 5; move --window-id 2 --boundaries-action stop right; focus --window-id 2")
        XCTAssertEqual(DwindleMove.script(.enter(.up, via: 9), window: 4),
                       "focus --window-id 9; move --window-id 4 --boundaries-action stop up; focus --window-id 4")
        XCTAssertEqual(DwindleMove.script(.leave(.left), window: 1), "move --window-id 1 --boundaries-action stop left")
        XCTAssertEqual(DwindleMove.script(.leave(.up), window: 8), "move --window-id 8 --boundaries-action stop up")
        XCTAssertEqual(DwindleMove.script(.wrap(.left), window: 2),
                       "move --window-id 2 --boundaries-action create-implicit-container left")
        XCTAssertEqual(DwindleMove.script(.wrap(.down), window: 6),
                       "move --window-id 6 --boundaries-action create-implicit-container down")
        // a hop to the right: to the workspace after this one, then as many `move left` presses as the other workspace has windows, then a
        // row around it when its top container is not one
        XCTAssertEqual(DwindleMove.script(.hop(.right), window: 7, workspace: "2", target: "3", tilingWindows: 2),
                       "move-node-to-workspace --window-id 7 --focus-follows-window 3"
                       + "; test-not %{workspace} = 2 && test %{workspace-root-container-layout} = h_tiles"
                       + " && move --window-id 7 --boundaries-action stop left && move --window-id 7 --boundaries-action stop left"
                       + "; test-not %{workspace} = 2 && test-not %{workspace-root-container-layout} = h_tiles"
                       + " && move --window-id 7 --boundaries-action create-implicit-container left")
        // an empty workspace needs no press at all, and a hop to the left needs none either: the window lands where it has to be
        XCTAssertEqual(DwindleMove.script(.hop(.right), window: 7, workspace: "2", target: "3", tilingWindows: 0),
                       "move-node-to-workspace --window-id 7 --focus-follows-window 3"
                       + "; test-not %{workspace} = 2 && test-not %{workspace-root-container-layout} = h_tiles"
                       + " && move --window-id 7 --boundaries-action create-implicit-container left")
        XCTAssertEqual(DwindleMove.script(.hop(.left), window: 3, workspace: "2", target: "1", tilingWindows: 4),
                       "move-node-to-workspace --window-id 3 --focus-follows-window 1"
                       + "; test-not %{workspace} = 2 && test-not %{workspace-root-container-layout} = h_tiles"
                       + " && move --window-id 3 --boundaries-action create-implicit-container right")
    }
}
