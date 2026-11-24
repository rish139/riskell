// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import CoreGraphics
import XCTest
import RiskellKit
@testable import DwindleAerospaceExt

final class DwindleMoveEndToEndTests: XCTestCase {
    /// What riskell would know of the workspace holding `tree`: every window at its rectangle, and the top container along the tree's own
    /// axis. Nothing floats.
    private func state(_ tree: Tile, focused: Int?) -> ManagerState {
        let slots = rectangles(of: tree)
        return ManagerState(
            windows: slots.sorted { $0.id < $1.id }.map { slot in
                ManagedWindow(id: slot.id, workspace: "1", floating: false,
                              frame: CGRect(x: slot.x0, y: slot.y0, width: slot.x1 - slot.x0, height: slot.y1 - slot.y0))
            },
            workspaces: [ManagedWorkspace(name: "1",
                                          rootLayout: topAxis(of: tree) == .row ? "h_tiles" : "v_tiles",
                                          landscape: topAxis(of: tree) == .row)],
            focusedWindow: focused,
            focusedWorkspace: "1")
    }

    /// One tiling window of workspace 1 with that rectangle.
    private func window(_ id: Int, x0: Double, y0: Double, x1: Double, y1: Double) -> ManagedWindow {
        ManagedWindow(id: id, workspace: "1", floating: false,
                      frame: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }

    /// Every tree of 2 to 4 windows as riskell sees it: for every window and direction the rule asks for exactly one line, the step's own,
    /// when there is a step, and for nothing when there is not. A hop needs a workspace beside this one, and this state has none, so the rule
    /// sends nothing for it either.
    func testTheRuleSpeaksExactlyWhenThereIsAStep() throws {
        var cases = 0
        var hops = 0
        for count in 2 ... 4 {
            let leaves = Array(1 ... count)
            for axis in [Axis.row, .column] {
                for tree in alternatingTrees(leaves, rootAxis: axis) {
                    let slots = rectangles(of: tree)
                    XCTAssertEqual(FrameTree.read(slots, rootAxis: axis, tolerance: DwindleRules.frameTolerance), .tree(tree),
                                   "\(treeText(tree)): the frames do not read back as the tree")
                    for window in leaves {
                        for direction in [Direction.left, .right, .up, .down] {
                            cases += 1
                            let label = "\(treeText(tree)), window \(window) \(direction.rawValue)"
                            let move = DwindleRules.move(direction, in: state(tree, focused: window))
                            guard let step = DwindleMove.step(in: tree, window: window, toward: direction, slots: slots) else {
                                XCTAssertEqual(move, DwindleRules.Move(), label)
                                continue
                            }
                            guard case .hop = step else {
                                XCTAssertEqual(move, DwindleRules.Move(commands: [ManagerCommand(DwindleMove.script(step, window: window))]), label)
                                continue
                            }
                            hops += 1
                            XCTAssertEqual(move, DwindleRules.Move(), label)
                        }
                    }
                }
            }
        }
        // every tree of 2 to 4 windows, both top axes, every window and every direction
        XCTAssertEqual(cases, 440)
        XCTAssertEqual(hops, 18)
    }

    /// Two windows stacked, the lower one moving left: the group that is the whole workspace runs across the direction, so the line asks
    /// for a container around it. A row inside that stack is the other side of the rule: at the end of it nothing happens.
    func testTheWrapOfAStackIsOneLine() throws {
        let stacked: Tile = .split(.column, [.window(1), .window(2)])
        let wrapped = state(stacked, focused: 2)
        XCTAssertEqual(DwindleRules.move(.left, in: wrapped),
                       DwindleRules.Move(commands: [ManagerCommand("move --window-id 2 --boundaries-action create-implicit-container left")]))
        XCTAssertEqual(DwindleRules.move(.right, in: wrapped),
                       DwindleRules.Move(commands: [ManagerCommand("move --window-id 2 --boundaries-action create-implicit-container right")]))

        let rowOfStack: Tile = .split(.column, [.window(1), .split(.row, [.window(2), .window(3)])])
        XCTAssertEqual(DwindleRules.move(.left, in: state(rowOfStack, focused: 2)), DwindleRules.Move())
        XCTAssertEqual(DwindleRules.move(.right, in: state(rowOfStack, focused: 3)), DwindleRules.Move())
    }

    /// The row of 1 and the column of 2 and 3 the fail-safes start from.
    private var start: Tile {
        .split(.row, [.window(1), .split(.column, [.window(2), .window(3)])])
    }

    func testNothingWhenTheFramesDoNotSayWhatTheLayoutIs() throws {
        let tree = start
        let slots = rectangles(of: tree)
        let down = ManagerCommand("join-with --window-id 2 down")
        let good = state(tree, focused: 2)
        XCTAssertEqual(DwindleRules.move(.down, in: good), DwindleRules.Move(commands: [down]))

        // a tiling window without a frame: a window of a hidden workspace is parked off screen and has none
        var missing = good
        missing.windows[2] = ManagedWindow(id: 3, workspace: "1", floating: false)
        XCTAssertEqual(DwindleRules.move(.down, in: missing), DwindleRules.Move())

        // two frames overlapping by more than the tolerance: the upper window of the column reaches into the lower one
        let upper = try XCTUnwrap(slots.first { $0.id == 2 })
        let height = upper.y1 - upper.y0
        var overlapping = good
        overlapping.windows[2] = window(3, x0: upper.x0, y0: upper.y1 - 3, x1: upper.x1, y1: upper.y1 - 3 + height)
        XCTAssertEqual(DwindleRules.move(.down, in: overlapping), DwindleRules.Move())
        // and two that reach into each other by the tolerance itself still read as a column
        var touching = good
        touching.windows[2] = window(3, x0: upper.x0, y0: upper.y1 - 2, x1: upper.x1, y1: upper.y1 - 2 + height)
        XCTAssertEqual(DwindleRules.move(.down, in: touching), DwindleRules.Move(commands: [down]))

        // a top container that is an accordion
        var accordion = good
        accordion.workspaces = [ManagedWorkspace(name: "1", rootLayout: "h_accordion", landscape: true)]
        XCTAssertEqual(DwindleRules.move(.down, in: accordion), DwindleRules.Move())

        // a window that floats, and one on another workspace, as the focused window
        var floating = good
        floating.windows[1] = ManagedWindow(id: 2, workspace: "1", floating: true, frame: good.windows[1].frame)
        XCTAssertEqual(DwindleRules.move(.down, in: floating), DwindleRules.Move())
        var elsewhere = good
        elsewhere.windows.append(ManagedWindow(id: 9, workspace: "2", floating: false,
                                               frame: CGRect(x: 0, y: 0, width: 10, height: 10)))
        elsewhere.focusedWindow = 9
        XCTAssertEqual(DwindleRules.move(.down, in: elsewhere), DwindleRules.Move())

        // no focused workspace, and no focused window at all
        var noWorkspace = good
        noWorkspace.focusedWorkspace = nil
        XCTAssertEqual(DwindleRules.move(.down, in: noWorkspace), DwindleRules.Move())
        var noWindow = good
        noWindow.focusedWindow = nil
        XCTAssertEqual(DwindleRules.move(.down, in: noWindow), DwindleRules.Move())

        // a floating window beside the tiling ones is none of the rule's business, and needs no frame
        var withFloat = good
        withFloat.windows.append(ManagedWindow(id: 9, workspace: "1", floating: true))
        XCTAssertEqual(DwindleRules.move(.down, in: withFloat), DwindleRules.Move(commands: [down]))
    }

    private func dwindle(_ settings: [String: Any] = [:]) -> DwindleAerospace {
        let dwindle = DwindleAerospace()
        _ = dwindle.start(Env(id: "dwindle-aerospace", prefs: Prefs(json: settings)))
        return dwindle
    }

    /// The layout the binding tests start from: the row of 1 and the column of 2 and 3, with window 2 focused.
    private var frames: ManagerState { state(start, focused: 2) }

    func testOnlyAMoveBindingAsksForFrames() throws {
        let behaviour = dwindle(["moveLeftKey": "alt-h", "tidyKey": "alt-shift-t"])
        let left = ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-h"])
        XCTAssertTrue(behaviour.needsFrames(for: left))
        XCTAssertFalse(behaviour.needsFrames(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-shift-t"])))
        XCTAssertFalse(behaviour.needsFrames(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-j"])))
        XCTAssertFalse(behaviour.needsFrames(for: ManagerEvent(name: "window-detected", fields: ["windowId": "2", "workspace": "1"])))
        XCTAssertFalse(behaviour.needsFrames(for: ManagerEvent(name: "binding-triggered")))
        // a behaviour that has not started has no settings to read
        XCTAssertFalse(DwindleAerospace().needsFrames(for: left))
    }

    func testTheMoveBindingSendsTheMoveAndTheTidyBindingTheTidy() throws {
        let state = frames
        let behaviour = dwindle(["moveLeftKey": "alt-h", "tidyKey": "alt-shift-t"])
        let left = behaviour.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-h"]), in: state)
        XCTAssertEqual(left, DwindleRules.move(.left, in: state).commands)
        XCTAssertEqual(left, [ManagerCommand("move --window-id 2 --boundaries-action stop left")])
        let tidy = behaviour.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-shift-t"]), in: state)
        XCTAssertEqual(tidy, DwindleRules.tidy(in: state))
        XCTAssertEqual(tidy.count, 1)
        XCTAssertEqual(behaviour.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-j"]), in: state), [])
        // each key means the direction it is set for
        let down = dwindle(["moveDownKey": "alt-j"])
        XCTAssertEqual(down.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-j"]), in: state),
                       [ManagerCommand("join-with --window-id 2 down")])
    }

    func testWithoutMoveKeysNoBindingMovesAnything() throws {
        let state = frames
        let behaviour = dwindle(["tidyKey": "alt-shift-t"])
        XCTAssertEqual(behaviour.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-h"]), in: state), [])
        XCTAssertFalse(behaviour.needsFrames(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-h"])))
        XCTAssertEqual(behaviour.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-shift-t"]), in: state),
                       DwindleRules.tidy(in: state))
    }
}
