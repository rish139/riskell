// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import XCTest
import RiskellKit
@testable import DwindleAerospaceExt

/// What riskell would report of the model: the windows in id order, the workspaces and where the focus is.
private func managerState(_ model: AeroSpaceModel, landscape: Bool) -> ManagerState {
    ManagerState(windows: model.windowIds.map {
                     ManagedWindow(id: $0, workspace: model.workspaceName(of: $0) ?? "", floating: model.isFloating($0))
                 },
                 workspaces: model.workspaceNames.map {
                     ManagedWorkspace(name: $0, rootLayout: model.rootLayout(of: $0), landscape: landscape,
                                      monitor: model.monitor(of: $0))
                 },
                 focusedWindow: model.focusedWindowId,
                 focusedWorkspace: model.focusedWorkspaceName)
}

/// A model whose windows arrive on workspace 1 in the order given, each one focused as it arrives.
private func tiles(_ ids: [Int], landscape: Bool = true) throws -> AeroSpaceModel {
    let model = AeroSpaceModel(landscape: landscape)
    for id in ids {
        try model.addWindow(id, to: "1")
        try model.focus(id)
    }
    return model
}

final class AeroSpaceModelTests: XCTestCase {
    func testThereIsNoWorkspaceUntilAWindowArrives() throws {
        let model = AeroSpaceModel()
        XCTAssertNil(model.tree(of: "1"))
        try model.addWindow(1, to: "1")
        XCTAssertEqual(model.tree(of: "1"), "h[1]")
        // a display that is taller than it is wide makes the workspace split into a column
        let tall = try tiles([1], landscape: false)
        XCTAssertEqual(tall.tree(of: "1"), "v[1]")
        XCTAssertEqual(tall.rootLayout(of: "1"), "v_tiles")
    }

    func testANewWindowLandsRightAfterTheMostRecentlyUsedOne() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(model.tree(of: "1"), "h[1, 2, 3]")
        try model.focus(1)
        try model.addWindow(4, to: "1")
        XCTAssertEqual(model.tree(of: "1"), "h[1, 4, 2, 3]")
    }

    func testAFloatingWindowIsLeftOutOfTheTilingTree() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("layout --window-id 2 floating", on: 2), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, 3] floating[2]")
        XCTAssertTrue(model.isFloating(2))
        XCTAssertFalse(model.isFloating(1))
        // a new window lands at the end when the most recently used window floats: AeroSpace takes the root then
        try model.addWindow(4, to: "1")
        XCTAssertEqual(model.tree(of: "1"), "h[1, 3, 4] floating[2]")
    }

    func testJoinWithLeftPutsTheWindowBesideItsNeighbour() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, 3]]")
    }

    func testJoinWithUpPutsTheWindowAboveItsNeighbour() throws {
        let model = try tiles([1, 2, 3], landscape: false)
        XCTAssertEqual(try model.run("join-with --window-id 3 up", on: 3), 0)
        XCTAssertEqual(model.tree(of: "1"), "v[1, h[2, 3]]")
    }

    func testAJoinWithNoNeighbourFailsAndLeavesTheTree() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("join-with --window-id 1 left", on: 1), 2)
        XCTAssertEqual(model.tree(of: "1"), "h[1, 2, 3]")
    }

    func testAJoinOfTwoWindowsLeavesTheirContainerAsTheRoot() throws {
        let model = try tiles([1, 2])
        XCTAssertEqual(try model.run("join-with --window-id 2 left", on: 2), 0)
        // the container of 1 and 2 is the root's only child, so normalization gives it the root's place
        XCTAssertEqual(model.tree(of: "1"), "v[1, 2]")
        XCTAssertEqual(model.rootLayout(of: "1"), "v_tiles")
    }

    func testSwapTradesTwoWindowsOfARow() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("swap --window-id 1 right", on: 1), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[2, 1, 3]")
        XCTAssertEqual(try model.run("swap --window-id 3 left", on: 3), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[2, 3, 1]")
    }

    func testSwapTakesTheWindowItReachesInsideANeighbouringContainer() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0) // h[1, v[2, 3]]
        XCTAssertEqual(try model.run("swap --window-id 1 right", on: 1), 0)
        // the neighbour is the column, and the window it reaches there is the last one it worked with
        XCTAssertEqual(model.tree(of: "1"), "h[3, v[2, 1]]")
    }

    func testMoveTradesPlacesWithANeighbourWindow() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("move --window-id 1 right", on: 1), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[2, 1, 3]")
    }

    func testMoveGoesIntoANeighbouringContainer() throws {
        let model = try tiles([1, 2, 3, 4])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, 3], 4]")
        XCTAssertEqual(try model.run("move --window-id 1 right", on: 1), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[v[2, 3, 1], 4]")
    }

    func testMoveComesOutIntoTheContainerAbove() throws {
        let model = try tiles([1, 2, 3, 4])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        XCTAssertEqual(try model.run("move --window-id 3 right", on: 3), 0)
        // the column it leaves is left with one window, and normalization flattens that away
        XCTAssertEqual(model.tree(of: "1"), "h[1, 2, 3, 4]")
    }

    func testMoveOverTheWorkspaceBoundaryMakesAContainer() throws {
        let model = try tiles([1, 2, 3, 4])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        XCTAssertEqual(try model.run("move --window-id 3 down", on: 3), 0)
        // a column around the old tree and the moved window, which comes last
        XCTAssertEqual(model.tree(of: "1"), "v[h[1, 2, 4], 3]")
    }

    func testMoveOverTheBoundaryCanStopOrFail() throws {
        let model = try tiles([1, 2, 3, 4])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        XCTAssertEqual(try model.run("move --window-id 3 down --boundaries-action stop", on: 3), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, 3], 4]")
        XCTAssertEqual(try model.run("move --window-id 3 down --boundaries-action fail", on: 3), 2)
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, 3], 4]")
        // the default action is the one that makes a container for the window past the edge of the workspace, and `--boundaries`
        // names the one display, so a move that names it goes the same way
        XCTAssertEqual(try model.run("move --window-id 3 down --boundaries workspace --boundaries-action create-implicit-container",
                                     on: 3), 0)
        XCTAssertEqual(model.tree(of: "1"), "v[h[1, 2, 4], 3]")
    }

    func testANewContainerInTheSameDirectionAsTheOldOneIsTurnedAround() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("move --window-id 3 right", on: 3), 0)
        // the root the boundary makes is a row and so was the old root, so normalization turns the old one into a column
        XCTAssertEqual(model.tree(of: "1"), "h[v[1, 2], 3]")
    }

    func testLayoutOnTheRootTurnsARowIntoAColumn() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("layout --workspace 1 --root v_tiles", on: 1), 0)
        XCTAssertEqual(model.tree(of: "1"), "v[1, 2, 3]")
        XCTAssertEqual(model.rootLayout(of: "1"), "v_tiles")
    }

    func testLayoutOnNestedContainerTurnsTheContainersAboveItToo() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        XCTAssertEqual(try model.run("layout --window-id 2 h_tiles", on: 2), 0)
        // the column becomes a row, and the row above it a column: nested containers keep opposite orientations
        XCTAssertEqual(model.tree(of: "1"), "v[1, h[2, 3]]")
    }

    func testLayoutTwiceIsNoOpAndCanBeAToldSo() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("layout --root h_tiles", on: 2), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, 2, 3]")
        XCTAssertEqual(try model.run("layout --root h_tiles --fail-if-noop", on: 2), 2)
    }

    func testLayoutFloatingAndTilingTakeAWindowOutAndBack() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("layout --window-id 2 floating", on: 2), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, 3] floating[2]")
        XCTAssertEqual(try model.run("layout --window-id 2 tiling", on: 2), 0)
        // it comes back at the end: the workspace's most recent child is the floating container, and it is empty now
        XCTAssertEqual(model.tree(of: "1"), "h[1, 3, 2]")
        XCTAssertFalse(model.isFloating(2))
    }

    func testNormalizationRunsBetweenTheCommandsOfOneLine() throws {
        let model = try tiles([1, 2, 3, 4])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, 3], 4]")
        XCTAssertEqual(try model.run("move --window-id 3 right; move --window-id 3 left", on: 3), 0)
        // the first move leaves a column holding one window, and the second command already sees it flattened away
        XCTAssertEqual(model.tree(of: "1"), "h[1, 3, 2, 4]")
    }

    func testFocusMakesTheWindowTheOneTheTreeUsedLast() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("focus --window-id 2", on: 1), 0)
        XCTAssertEqual(model.focusedWindowId, 2)
        XCTAssertEqual(model.focusedWorkspaceName, "1")
        // a new window lands right after the window the tree used last
        try model.addWindow(4, to: "1")
        XCTAssertEqual(model.tree(of: "1"), "h[1, 2, 4, 3]")
        // a window that is not there fails, and so does a focus that names a direction
        XCTAssertEqual(try model.run("focus --window-id 9", on: 2), 2)
        XCTAssertEqual(model.focusedWindowId, 2)
        XCTAssertThrowsError(try model.run("focus left", on: 2)) { error in
            XCTAssertEqual("\(error)", "the AeroSpace model does not support focus 'left' (only --window-id and --dfs-index)")
        }
    }

    func testFocusOnAWindowOfAnotherWorkspaceTakesTheFocusThere() throws {
        let model = try tiles([1, 2])
        XCTAssertEqual(try model.run("move-node-to-workspace 2 --window-id 2", on: 2), 0)
        XCTAssertEqual(model.workspaceName(of: 2), "2")
        // the focus stays on workspace 1 until a focus names the window on the other one
        XCTAssertEqual(model.focusedWorkspaceName, "1")
        XCTAssertEqual(try model.run("focus --window-id 1", on: 2), 0)
        XCTAssertEqual(model.focusedWorkspaceName, "1")
        XCTAssertEqual(try model.run("focus --window-id 2", on: 1), 0)
        XCTAssertEqual(model.focusedWorkspaceName, "2")
        XCTAssertEqual(model.focusedWindowId, 2)
    }

    func testMoveEntersANeighbouringContainerAfterTheWindowItUsedLast() throws {
        let model = AeroSpaceModel()
        try model.build(.split(.row, [.window(1), .split(.column, [.window(2), .window(3)])]), on: "1")
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, 3]]")
        // the column worked with 3 last, so 1 lands under it; the row it leaves is left with nothing and the column takes its place
        XCTAssertEqual(try model.run("move --window-id 1 right", on: 1), 0)
        XCTAssertEqual(model.tree(of: "1"), "v[2, 3, 1]")
    }

    func testMoveEntersANestedContainerAsItsFirstMember() throws {
        let model = AeroSpaceModel()
        try model.build(.split(.row, [.window(1), .split(.column, [.split(.row, [.window(2), .window(3)]), .window(4)])]), on: "1")
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[h[2, 3], 4]]")
        // the column used the row last, and the row is laid out the way the window goes, so it goes in front of the row's members
        try model.focus(3)
        XCTAssertEqual(try model.run("move --window-id 1 right", on: 1), 0)
        XCTAssertEqual(model.tree(of: "1"), "v[h[1, 2, 3], 4]")
    }

    func testMoveOutOfAGroupGoesToTheGroupAboveIt() throws {
        let model = AeroSpaceModel()
        try model.build(.split(.row, [.window(1), .split(.column, [.split(.row, [.window(2), .window(3)]), .window(4)])]), on: "1")
        // the row the window is in does not run up and down, so the window leaves it for the column above, before it
        XCTAssertEqual(try model.run("move --window-id 2 up", on: 2), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, 3, 4]]")
        // and a window beside another window of its own row trades places with it: that is AeroSpace's own move, which the step
        // names only when it wants the two merged
        let row = AeroSpaceModel()
        try row.build(.split(.row, [.window(1), .window(2), .window(3)]), on: "1")
        XCTAssertEqual(try row.run("move --window-id 1 right", on: 1), 0)
        XCTAssertEqual(row.tree(of: "1"), "h[2, 1, 3]")
    }

    func testMoveOfAFloatingWindowFails() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("layout --window-id 2 floating", on: 2), 0)
        XCTAssertEqual(try model.run("move --window-id 2 left", on: 2), 2)
        XCTAssertEqual(model.tree(of: "1"), "h[1, 3] floating[2]")
    }

    func testTheModelHoldsAnyTreeOfRowsAndColumns() throws {
        let model = AeroSpaceModel()
        let tree: Tile = .split(.row, [
            .window(1),
            .split(.column, [.window(2), .window(3), .split(.row, [.window(4), .window(5), .window(6)])]),
            .window(7),
        ])
        try model.build(tree, on: "1")
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, 3, h[4, 5, 6]], 7]")
        XCTAssertEqual(model.windowIds, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(model.rootLayout(of: "1"), "h_tiles")
        XCTAssertEqual(model.focusedWindowId, 1)
        XCTAssertFalse(model.isFloating(4))
        // a column takes the workspace's root container when it is the whole tree
        let tall = AeroSpaceModel()
        try tall.build(.split(.column, [.window(1), .window(2)]), on: "1")
        XCTAssertEqual(tall.tree(of: "1"), "v[1, 2]")
        XCTAssertEqual(tall.rootLayout(of: "1"), "v_tiles")
        XCTAssertThrowsError(try model.build(.split(.row, [.window(1), .window(8)]), on: "1")) { error in
            XCTAssertEqual("\(error)", "the AeroSpace model does not support window 1 is already there")
        }
    }

    func testFlattenPutsEveryWindowInTheRootInTreeOrder() throws {
        let model = try tiles([1, 2, 3, 4])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, 3], 4]")
        XCTAssertEqual(try model.run("flatten-workspace-tree --workspace 1", on: 1), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, 2, 3, 4]")
    }

    func testBalanceSizesChangesNoShapeOfTheTree() throws {
        let model = try tiles([1, 2, 3, 4])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        XCTAssertEqual(try model.run("balance-sizes --workspace 1", on: 1), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, 3], 4]")
    }

    func testTheWindowParentLayoutIsTheLayoutItsParentHas() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("test %{window-parent-container-layout} = h_tiles", on: 1), 0)
        XCTAssertEqual(try model.run("test %{window-parent-container-layout} = v_tiles", on: 1), 1)
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        XCTAssertEqual(try model.run("test %{window-parent-container-layout} = v_tiles", on: 3), 0)
        XCTAssertEqual(try model.run("layout --window-id 3 floating", on: 3), 0)
        XCTAssertEqual(try model.run("test %{window-parent-container-layout} = floating", on: 3), 0)
    }

    func testTheSplitLineJoinsOnlyWhereItsTestSaysYes() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run(AeroSpaceScripts.split, on: 3), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, 3]]")
        // the same line on a column joins upwards
        let column = try tiles([1, 2, 3], landscape: false)
        XCTAssertEqual(try column.run(AeroSpaceScripts.split, on: 3), 0)
        XCTAssertEqual(column.tree(of: "1"), "v[1, h[2, 3]]")
        // and a floating window joins nowhere: both tests are false, so the line ends on 1
        let floating = try tiles([1, 2, 3])
        XCTAssertEqual(try floating.run("layout --window-id 2 floating", on: 2), 0)
        XCTAssertEqual(try floating.run(AeroSpaceScripts.split, on: 2), 1)
        XCTAssertEqual(floating.tree(of: "1"), "h[1, 3] floating[2]")
    }

    func testCloseTakesTheWindowOutAndFlattensWhatItLeaves() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        XCTAssertEqual(try model.run("close --window-id 3", on: 3), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, 2]")
    }

    func testCloseFocusesTheMostRecentlyUsedWindowLeft() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        try model.close(3)
        XCTAssertEqual(model.focusedWindowId, 2)
        XCTAssertEqual(model.focusedWorkspaceName, "1")
    }

    func testCloseOfAWindowBesideAContainerLeavesTheContainerAsTheRoot() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("join-with --window-id 3 left", on: 3), 0)
        try model.close(1)
        XCTAssertEqual(model.tree(of: "1"), "v[2, 3]")
    }

    func testMoveToAnotherWorkspacePutsTheWindowAtTheEndOfItsTree() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertEqual(try model.run("move-node-to-workspace 2 --window-id 3", on: 3), 0)
        XCTAssertEqual(model.tree(of: "1"), "h[1, 2]")
        XCTAssertEqual(model.tree(of: "2"), "h[3]")
        XCTAssertEqual(model.workspaceName(of: 3), "2")
        XCTAssertEqual(try model.run("move-node-to-workspace 2 --window-id 3 --fail-if-noop", on: 3), 2)
        XCTAssertEqual(model.tree(of: "2"), "h[3]")
    }

    /// Several workspaces, empty ones among them, are what `next` and `prev` walk: the workspaces of one monitor, by name, and there is
    /// nothing beyond the last and the first (`getNextPrevWorkspace`, no wrap-around).
    func testNextAndPrevWalkTheWorkspacesOfTheMonitorByName() throws {
        let model = AeroSpaceModel()
        for name in ["2", "1", "3"] { model.addWorkspace(name) }
        try model.addWindow(1, to: "1")
        try model.addWindow(2, to: "2")
        // the model puts every workspace on the one monitor unless a test says otherwise
        XCTAssertEqual(model.workspaceNames, ["1", "2", "3"])
        XCTAssertEqual(model.workspaceNames.map { model.monitor(of: $0) }, [1, 1, 1])

        // next from 1 is the empty 2: the window lands at the end of its root and the focus goes with it
        XCTAssertEqual(try model.run("move-node-to-workspace next --focus-follows-window", on: 1), 0)
        XCTAssertEqual(model.workspaceName(of: 1), "2")
        XCTAssertEqual(model.tree(of: "2"), "h[2, 1]")
        XCTAssertEqual(model.focusedWindowId, 1)
        XCTAssertEqual(model.focusedWorkspaceName, "2")

        // prev brings it back to the end of the workspace before
        XCTAssertEqual(try model.run("move-node-to-workspace prev --focus-follows-window", on: 1), 0)
        XCTAssertEqual(model.workspaceName(of: 1), "1")
        XCTAssertEqual(model.tree(of: "1"), "h[1]")

        // nothing is before the first and nothing after the last
        XCTAssertEqual(try model.run("move-node-to-workspace prev", on: 1), 2)
        XCTAssertEqual(model.workspaceName(of: 1), "1")
        XCTAssertEqual(try model.run("move-node-to-workspace next", on: 1), 0)
        XCTAssertEqual(try model.run("move-node-to-workspace next", on: 1), 0)
        XCTAssertEqual(model.workspaceName(of: 1), "3")
        XCTAssertEqual(try model.run("move-node-to-workspace next", on: 1), 2)
        XCTAssertEqual(model.workspaceName(of: 1), "3")
    }

    /// Every workspace is assigned to a monitor, and `next` and `prev` only go between the workspaces of one: they never step over to
    /// the other monitor's workspaces, even the empty ones.
    func testNextAndPrevRefuseAWindowIdAsAeroSpacesParserDoes() throws {
        // AeroSpace: "--window-id is incompatible with (next|prev)", reported before anything of the expression runs
        let model = AeroSpaceModel()
        try model.addWindow(1, to: "1")
        try model.addWindow(2, to: "2")
        XCTAssertThrowsError(try model.run("move-node-to-workspace --window-id 1 next", on: 1))
        XCTAssertThrowsError(try model.run("move-node-to-workspace --window-id 1 --focus-follows-window prev", on: 1))
        // a workspace's name goes with it
        XCTAssertEqual(try model.run("move-node-to-workspace --window-id 1 --focus-follows-window 2", on: 1), 0)
        XCTAssertEqual(model.workspaceName(of: 1), "2")
    }

    func testNextAndPrevStayOnTheMonitorOfTheWorkspace() throws {
        let model = AeroSpaceModel()
        for name in ["1", "2", "4"] { model.addWorkspace(name, on: 1) }
        for name in ["3", "5"] { model.addWorkspace(name, on: 2) }
        try model.build(.split(.row, [.window(1), .window(2)]), on: "2")
        XCTAssertEqual(model.workspaceNames.map { model.monitor(of: $0) }, [1, 1, 2, 1, 2])

        // right from 2 is 4, past the empty 3 of the other monitor, and left from 4 is 2 again
        XCTAssertEqual(try model.run("move-node-to-workspace next --focus-follows-window", on: 2), 0)
        XCTAssertEqual(model.workspaceName(of: 2), "4")
        XCTAssertEqual(try model.run("move-node-to-workspace prev --focus-follows-window", on: 2), 0)
        XCTAssertEqual(model.workspaceName(of: 2), "2")

        // 4 is the last of its monitor and 1 the first, whatever the other monitor holds
        XCTAssertEqual(try model.run("move-node-to-workspace next", on: 2), 0) // 4
        XCTAssertEqual(try model.run("move-node-to-workspace next", on: 2), 2)
        XCTAssertEqual(model.workspaceName(of: 2), "4")
        XCTAssertEqual(try model.run("move-node-to-workspace prev", on: 2), 0) // 2
        XCTAssertEqual(try model.run("move-node-to-workspace prev", on: 2), 0) // 1
        XCTAssertEqual(try model.run("move-node-to-workspace prev", on: 2), 2)
        XCTAssertEqual(model.workspaceName(of: 2), "1")

        // the other monitor has its own list, 3 and 5, and its own ends

        let other = AeroSpaceModel()
        other.addWorkspace("3", on: 2)
        other.addWorkspace("5", on: 2)
        try other.addWindow(1, to: "3")
        XCTAssertEqual(try other.run("move-node-to-workspace next", on: 1), 0)
        XCTAssertEqual(other.workspaceName(of: 1), "5")
        XCTAssertEqual(try other.run("move-node-to-workspace next", on: 1), 2)
        XCTAssertEqual(try other.run("move-node-to-workspace prev --focus-follows-window", on: 1), 0)
        XCTAssertEqual(other.workspaceName(of: 1), "3")
        XCTAssertEqual(try other.run("move-node-to-workspace prev", on: 1), 2)
    }

    func testTestNotGivesTheOppositeOfTest() throws {
        let model = try tiles([1, 2])
        XCTAssertEqual(try model.run("test %{window-parent-container-layout} = h_tiles", on: 1), 0)
        XCTAssertEqual(try model.run("test-not %{window-parent-container-layout} = h_tiles", on: 1), 1)
        XCTAssertEqual(try model.run("test %{window-parent-container-layout} = v_tiles", on: 1), 1)
        XCTAssertEqual(try model.run("test-not %{window-parent-container-layout} = v_tiles", on: 1), 0)
        // a test that cannot be made is a failure either way round
        XCTAssertThrowsError(try model.run("test-not %{window-title} = x", on: 1)) { error in
            XCTAssertEqual("\(error)", "the AeroSpace model does not support interpolation '%{window-title}'")
        }
    }

    /// The two workspace variables are read when the command runs, for the window the line is run for: they follow that window to the
    /// workspace it has just moved to.
    func testTheWorkspaceVariablesFollowTheWindowTheLineIsRunFor() throws {
        let model = try tiles([1, 2, 3])
        try model.build(.split(.column, [.window(4), .window(5)]), on: "3")

        XCTAssertEqual(try model.run("test %{workspace} = 1", on: 2), 0)
        XCTAssertEqual(try model.run("test %{workspace-root-container-layout} = h_tiles", on: 2), 0)
        XCTAssertEqual(try model.run("test %{workspace} = 3", on: 4), 0)

        // moved to 2, the same lines read 2
        XCTAssertEqual(try model.run("move-node-to-workspace --window-id 2 2", on: 2), 0)
        XCTAssertEqual(try model.run("test %{workspace} = 2", on: 2), 0)
        XCTAssertEqual(try model.run("test-not %{workspace} = 1", on: 2), 0)
        // and moved on to the column that is 3, the layout it reads is the one there
        XCTAssertEqual(try model.run("move-node-to-workspace --window-id 2 3", on: 2), 0)
        XCTAssertEqual(try model.run("test %{workspace} = 3", on: 2), 0)
        XCTAssertEqual(try model.run("test %{workspace-root-container-layout} = v_tiles", on: 2), 0)
        XCTAssertEqual(model.tree(of: "3"), "v[4, 5, 2]")
    }

    func testWorkspaceTakesTheFocusToThatWorkspaceAndItsMostRecentlyUsedWindow() throws {
        let model = AeroSpaceModel()
        try model.build(.split(.row, [.window(1), .window(2)]), on: "1")
        try model.build(.split(.row, [.window(3), .window(4)]), on: "2")
        try model.focus(4)
        XCTAssertEqual(try model.run("workspace 1", on: 4), 0)
        XCTAssertEqual(model.focusedWorkspaceName, "1")
        XCTAssertEqual(model.focusedWindowId, 1)
        // an empty workspace takes the focus too, and there is no window to focus on it
        model.addWorkspace("3")
        XCTAssertEqual(try model.run("workspace 3", on: 1), 0)
        XCTAssertEqual(model.focusedWorkspaceName, "3")
        XCTAssertNil(model.focusedWindowId)
        XCTAssertEqual(model.tree(of: "3"), "h[]")
        // a workspace that is already focused is left as it is
        XCTAssertEqual(try model.run("workspace 3", on: 1), 0)
        XCTAssertEqual(model.focusedWorkspaceName, "3")
    }

    func testFocusGoesToTheWindowAtADepthFirstIndex() throws {
        let model = AeroSpaceModel()
        try model.build(.split(.row, [.window(1), .split(.column, [.window(2), .window(3)]), .window(4)]), on: "1")
        // the leaves of the row in tree order are 1, 2, 3 and 4
        XCTAssertEqual(try model.run("focus --dfs-index 2", on: 1), 0)
        XCTAssertEqual(model.focusedWindowId, 3)
        XCTAssertEqual(try model.run("focus --dfs-index 0", on: 3), 0)
        XCTAssertEqual(model.focusedWindowId, 1)
        // there is no fifth window, and an index that is not a number is refused
        XCTAssertEqual(try model.run("focus --dfs-index 4", on: 1), 2)
        XCTAssertEqual(model.focusedWindowId, 1)
        XCTAssertEqual(try model.run("focus --dfs-index next", on: 1), 2)
        // an empty focused workspace has no window at any index
        model.addWorkspace("2")
        XCTAssertEqual(try model.run("workspace 2", on: 1), 0)
        XCTAssertEqual(try model.run("focus --dfs-index 0", on: 1), 2)
    }

    func testTheModelRefusesWhatItDoesNotModel() throws {
        let model = try tiles([1, 2, 3])
        XCTAssertThrowsError(try model.run("rotate 90", on: 1)) { error in
            XCTAssertEqual("\(error)", "the AeroSpace model does not support command 'rotate'")
        }
        XCTAssertThrowsError(try model.run("join-with diagonal", on: 1)) { error in
            XCTAssertEqual("\(error)", "the AeroSpace model does not support direction 'diagonal'")
        }
        XCTAssertThrowsError(try model.run("layout --root h_accordion", on: 1)) { error in
            XCTAssertEqual("\(error)", "the AeroSpace model does not support layout 'h_accordion' (accordion is not modelled)")
        }
        XCTAssertThrowsError(try model.run("test %{window-title} = x", on: 1)) { error in
            XCTAssertEqual("\(error)", "the AeroSpace model does not support interpolation '%{window-title}'")
        }
        XCTAssertThrowsError(try model.run("move --window-id 1 right --boundaries all-monitors-outer-frame", on: 1)) { error in
            XCTAssertEqual("\(error)", "the AeroSpace model does not support --boundaries all-monitors-outer-frame (one display only)")
        }
        XCTAssertThrowsError(try model.run("move --window-id 1 right --wrap-around", on: 1)) { error in
            XCTAssertEqual("\(error)", "the AeroSpace model does not support flag '--wrap-around'")
        }
        XCTAssertThrowsError(try model.run("layout --window-id 1 --workspace 1 --root h_tiles", on: 1)) { error in
            XCTAssertEqual("\(error)", "the AeroSpace model does not support layout with both --window-id and --workspace")
        }
        XCTAssertThrowsError(try model.run("layout --workspace 1 h_tiles", on: 1)) { error in
            XCTAssertEqual("\(error)", "the AeroSpace model does not support layout --workspace without --root")
        }
    }
}

final class AeroSpaceModelScriptTests: XCTestCase {
    /// A window arrives: the model places it, then the rules' split script runs on it, as riskell sends it.
    private func arrive(_ id: Int, to model: AeroSpaceModel, landscape: Bool, workspace: String = "1") throws -> Int32 {
        try model.addWindow(id, to: workspace)
        try model.focus(id)
        var code: Int32 = 0
        for command in DwindleRules.split(window: id, on: workspace, in: managerState(model, landscape: landscape)) {
            code = try model.run(command.script, on: command.window ?? id)
        }
        return code
    }

    /// Windows arriving newest first: what the tree makes is nested, and in the reverse of the order the tidy puts it in.
    private func reverseArrivals(_ count: Int, landscape: Bool) throws -> AeroSpaceModel {
        let model = AeroSpaceModel(landscape: landscape)
        for id in stride(from: count, through: 1, by: -1) {
            XCTAssertEqual(try arrive(id, to: model, landscape: landscape), 0)
        }
        return model
    }

    private func tidy(_ model: AeroSpaceModel, landscape: Bool) throws {
        let commands = DwindleRules.tidy(in: managerState(model, landscape: landscape))
        XCTAssertEqual(commands.count, 1)
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(try model.run(command.script, on: try XCTUnwrap(model.focusedWindowId)), 0)
    }

    func testTheSplitScriptBuildsADwindleChainAsWindowsArriveWide() throws {
        let model = AeroSpaceModel(landscape: true)
        let trees = ["h[1]", "h[1, 2]", "h[1, v[2, 3]]", "h[1, v[2, h[3, 4]]]",
                     "h[1, v[2, h[3, v[4, 5]]]]", "h[1, v[2, h[3, v[4, h[5, 6]]]]]"]
        for (index, id) in (1 ... 6).enumerated() {
            _ = try arrive(id, to: model, landscape: true)
            XCTAssertEqual(model.tree(of: "1"), trees[index], "after window \(id) arrived")
        }
    }

    func testTheSplitScriptBuildsADwindleChainAsWindowsArriveTall() throws {
        let model = AeroSpaceModel(landscape: false)
        let trees = ["v[1]", "v[1, 2]", "v[1, h[2, 3]]", "v[1, h[2, v[3, 4]]]",
                     "v[1, h[2, v[3, h[4, 5]]]]", "v[1, h[2, v[3, h[4, v[5, 6]]]]]"]
        for (index, id) in (1 ... 6).enumerated() {
            _ = try arrive(id, to: model, landscape: false)
            XCTAssertEqual(model.tree(of: "1"), trees[index], "after window \(id) arrived")
        }
    }

    func testClosingFromTheMiddleAndTheEndKeepsTheChain() throws {
        let model = AeroSpaceModel(landscape: true)
        for id in 1 ... 6 {
            _ = try arrive(id, to: model, landscape: true)
        }
        try model.close(3)
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, h[4, v[5, 6]]]]")
        // the window it focuses is the most recently used one left, which was the last one made
        XCTAssertEqual(model.focusedWindowId, 6)
        try model.close(6)
        XCTAssertEqual(model.tree(of: "1"), "h[1, v[2, h[4, 5]]]")
    }

    func testTheTidyRebuildsTheChainInIdOrderWide() throws {
        let cases = [(count: 2, asTheyArrive: "h[2, 1]", tidy: "h[1, 2]"),
                     (count: 3, asTheyArrive: "h[3, v[2, 1]]", tidy: "h[1, v[2, 3]]"),
                     (count: 5, asTheyArrive: "h[5, v[4, h[3, v[2, 1]]]]", tidy: "h[1, v[2, h[3, v[4, 5]]]]")]
        for (count, asTheyArrive, expected) in cases {
            let model = try reverseArrivals(count, landscape: true)
            XCTAssertEqual(model.tree(of: "1"), asTheyArrive, "\(count) windows as they arrive")
            try tidy(model, landscape: true)
            XCTAssertEqual(model.tree(of: "1"), expected, "\(count) windows after the tidy")
        }
    }

    func testTheTidyRebuildsTheChainInIdOrderTall() throws {
        let cases = [(count: 2, asTheyArrive: "v[2, 1]", tidy: "v[1, 2]"),
                     (count: 3, asTheyArrive: "v[3, h[2, 1]]", tidy: "v[1, h[2, 3]]"),
                     (count: 5, asTheyArrive: "v[5, h[4, v[3, h[2, 1]]]]", tidy: "v[1, h[2, v[3, h[4, 5]]]]")]
        for (count, asTheyArrive, expected) in cases {
            let model = try reverseArrivals(count, landscape: false)
            XCTAssertEqual(model.tree(of: "1"), asTheyArrive, "\(count) windows as they arrive")
            try tidy(model, landscape: false)
            XCTAssertEqual(model.tree(of: "1"), expected, "\(count) windows after the tidy")
        }
    }
}
