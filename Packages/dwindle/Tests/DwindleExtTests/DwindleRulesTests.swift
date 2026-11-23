// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import XCTest
import RiskellKit
@testable import DwindleExt

private func state(_ windows: [(id: Int, workspace: String, floating: Bool)],
                   focused: String? = "1",
                   workspaces: [ManagedWorkspace] = []) -> ManagerState {
    ManagerState(windows: windows.map { ManagedWindow(id: $0.id, workspace: $0.workspace, floating: $0.floating) },
                 workspaces: workspaces,
                 focusedWindow: nil,
                 focusedWorkspace: focused)
}

private func workspace(_ name: String, landscape: Bool? = nil, root: String? = nil) -> ManagedWorkspace {
    ManagedWorkspace(name: name, rootLayout: root, landscape: landscape)
}

final class DwindleSplitTests: XCTestCase {
    func testTheScriptTestsTheParentLayoutAndJoinsOneWayOrTheOther() {
        XCTAssertEqual(AeroSpaceScripts.split,
                       "test %{window-parent-container-layout} = h_tiles && join-with left"
                       + " || test %{window-parent-container-layout} = v_tiles && join-with up")
    }

    func testNoSplitWhenTheWorkspaceHoldsAnotherTilingWindowOnly() {
        let s = state([(id: 1, workspace: "1", floating: false), (id: 9, workspace: "1", floating: false)])
        XCTAssertEqual(DwindleRules.split(window: 9, on: "1", in: s), [])
    }

    func testNoSplitWhenTheWindowIsAloneOnItsWorkspace() {
        let s = state([(id: 9, workspace: "1", floating: false)])
        XCTAssertEqual(DwindleRules.split(window: 9, on: "1", in: s), [])
    }

    func testOneCommandWithTwoOtherTilingWindows() {
        let s = state([(id: 1, workspace: "1", floating: false),
                       (id: 2, workspace: "1", floating: false),
                       (id: 9, workspace: "1", floating: false)])
        XCTAssertEqual(DwindleRules.split(window: 9, on: "1", in: s),
                       [ManagerCommand(AeroSpaceScripts.split, window: 9)])
    }

    func testOneCommandWithFiveOtherTilingWindows() {
        let s = state((1...5).map { (id: $0, workspace: "1", floating: false) } + [(id: 9, workspace: "1", floating: false)])
        XCTAssertEqual(DwindleRules.split(window: 9, on: "1", in: s),
                       [ManagerCommand(AeroSpaceScripts.split, window: 9)])
    }

    func testFloatingWindowsAreNotCounted() {
        let s = state([(id: 1, workspace: "1", floating: false),
                       (id: 2, workspace: "1", floating: true),
                       (id: 3, workspace: "1", floating: true),
                       (id: 9, workspace: "1", floating: false)])
        XCTAssertEqual(DwindleRules.split(window: 9, on: "1", in: s), [])
    }

    func testTheWindowItselfIsNotCountedWhenTheStateAlreadyHasIt() {
        let one = state([(id: 1, workspace: "1", floating: false), (id: 9, workspace: "1", floating: false)])
        XCTAssertEqual(DwindleRules.split(window: 9, on: "1", in: one), [])
        let two = state([(id: 1, workspace: "1", floating: false),
                         (id: 2, workspace: "1", floating: false),
                         (id: 9, workspace: "1", floating: false)])
        XCTAssertEqual(DwindleRules.split(window: 9, on: "1", in: two).count, 1)
    }

    func testWindowsOnAnotherWorkspaceAreNotCounted() {
        let s = state([(id: 1, workspace: "2", floating: false),
                       (id: 2, workspace: "2", floating: false),
                       (id: 9, workspace: "1", floating: false)])
        XCTAssertEqual(DwindleRules.split(window: 9, on: "1", in: s), [])
    }

    func testTheWorkspaceTheStateReportsWins() {
        // a window that has just moved: the event still names the workspace it came from
        let s = state([(id: 1, workspace: "1", floating: false),
                       (id: 2, workspace: "1", floating: false),
                       (id: 9, workspace: "1", floating: false)])
        XCTAssertEqual(DwindleRules.split(window: 9, on: "2", in: s).count, 1)
    }

    func testTheEventNamesTheWorkspaceOfAWindowTheStateHasNotSeen() {
        let s = state([(id: 1, workspace: "2", floating: false), (id: 2, workspace: "2", floating: false)])
        XCTAssertEqual(DwindleRules.split(window: 9, on: "2", in: s),
                       [ManagerCommand(AeroSpaceScripts.split, window: 9)])
    }

    func testNoWorkspaceAnywhereMeansNoSplit() {
        let s = state([(id: 1, workspace: "1", floating: false), (id: 2, workspace: "1", floating: false)])
        XCTAssertEqual(DwindleRules.split(window: 9, on: nil, in: s), [])
    }
}

final class DwindleTidyTests: XCTestCase {
    func testNoFocusedWorkspaceMeansNothing() {
        let s = state([(id: 1, workspace: "1", floating: false)], focused: nil, workspaces: [workspace("1")])
        XCTAssertEqual(DwindleRules.tidy(in: s), [])
    }

    func testNoTilingWindowMeansNothing() {
        let s = state([(id: 1, workspace: "1", floating: true)], workspaces: [workspace("1")])
        XCTAssertEqual(DwindleRules.tidy(in: s), [])
    }

    func testOneWindow() {
        XCTAssertEqual(tidy([5], landscape: true),
                       "flatten-workspace-tree --workspace 1; layout --workspace 1 --root h_tiles; balance-sizes --workspace 1")
    }

    func testOneWindowOnATallDisplay() {
        XCTAssertEqual(tidy([5], landscape: false),
                       "flatten-workspace-tree --workspace 1; layout --workspace 1 --root v_tiles; balance-sizes --workspace 1")
    }

    func testTwoWindowsArePutInOrder() {
        // no join (a pair cannot alternate), but the float-and-tile round trip is what puts the second window after the first
        XCTAssertEqual(tidy([5, 9], landscape: true),
                       "flatten-workspace-tree --workspace 1; layout --workspace 1 --root h_tiles"
                       + "; layout --window-id 9 floating; layout --window-id 9 tiling"
                       + "; balance-sizes --workspace 1")
    }

    func testTwoWindowsOnATallDisplay() {
        XCTAssertEqual(tidy([5, 9], landscape: false),
                       "flatten-workspace-tree --workspace 1; layout --workspace 1 --root v_tiles"
                       + "; layout --window-id 9 floating; layout --window-id 9 tiling"
                       + "; balance-sizes --workspace 1")
    }

    func testThreeWindows() {
        XCTAssertEqual(tidy([5, 7, 9], landscape: true),
                       "flatten-workspace-tree --workspace 1; layout --workspace 1 --root h_tiles"
                       + "; layout --window-id 7 floating; layout --window-id 9 floating"
                       + "; layout --window-id 7 tiling; layout --window-id 9 tiling; join-with --window-id 9 left"
                       + "; balance-sizes --workspace 1")
    }

    func testThreeWindowsOnATallDisplay() {
        XCTAssertEqual(tidy([5, 7, 9], landscape: false),
                       "flatten-workspace-tree --workspace 1; layout --workspace 1 --root v_tiles"
                       + "; layout --window-id 7 floating; layout --window-id 9 floating"
                       + "; layout --window-id 7 tiling; layout --window-id 9 tiling; join-with --window-id 9 up"
                       + "; balance-sizes --workspace 1")
    }

    func testFourWindows() {
        XCTAssertEqual(tidy([2, 4, 6, 8], landscape: true),
                       "flatten-workspace-tree --workspace 1; layout --workspace 1 --root h_tiles"
                       + "; layout --window-id 4 floating; layout --window-id 6 floating; layout --window-id 8 floating"
                       + "; layout --window-id 4 tiling"
                       + "; layout --window-id 6 tiling; join-with --window-id 6 left"
                       + "; layout --window-id 8 tiling; join-with --window-id 8 up"
                       + "; balance-sizes --workspace 1")
    }

    func testFourWindowsOnATallDisplay() {
        XCTAssertEqual(tidy([2, 4, 6, 8], landscape: false),
                       "flatten-workspace-tree --workspace 1; layout --workspace 1 --root v_tiles"
                       + "; layout --window-id 4 floating; layout --window-id 6 floating; layout --window-id 8 floating"
                       + "; layout --window-id 4 tiling"
                       + "; layout --window-id 6 tiling; join-with --window-id 6 up"
                       + "; layout --window-id 8 tiling; join-with --window-id 8 left"
                       + "; balance-sizes --workspace 1")
    }

    func testSevenWindows() {
        XCTAssertEqual(tidy(Array(1...7), landscape: true),
                       "flatten-workspace-tree --workspace 1; layout --workspace 1 --root h_tiles"
                       + "; layout --window-id 2 floating; layout --window-id 3 floating; layout --window-id 4 floating"
                       + "; layout --window-id 5 floating; layout --window-id 6 floating; layout --window-id 7 floating"
                       + "; layout --window-id 2 tiling"
                       + "; layout --window-id 3 tiling; join-with --window-id 3 left"
                       + "; layout --window-id 4 tiling; join-with --window-id 4 up"
                       + "; layout --window-id 5 tiling; join-with --window-id 5 left"
                       + "; layout --window-id 6 tiling; join-with --window-id 6 up"
                       + "; layout --window-id 7 tiling; join-with --window-id 7 left"
                       + "; balance-sizes --workspace 1")
    }

    func testSevenWindowsOnATallDisplay() {
        XCTAssertEqual(tidy(Array(1...7), landscape: false),
                       "flatten-workspace-tree --workspace 1; layout --workspace 1 --root v_tiles"
                       + "; layout --window-id 2 floating; layout --window-id 3 floating; layout --window-id 4 floating"
                       + "; layout --window-id 5 floating; layout --window-id 6 floating; layout --window-id 7 floating"
                       + "; layout --window-id 2 tiling"
                       + "; layout --window-id 3 tiling; join-with --window-id 3 up"
                       + "; layout --window-id 4 tiling; join-with --window-id 4 left"
                       + "; layout --window-id 5 tiling; join-with --window-id 5 up"
                       + "; layout --window-id 6 tiling; join-with --window-id 6 left"
                       + "; layout --window-id 7 tiling; join-with --window-id 7 up"
                       + "; balance-sizes --workspace 1")
    }

    func testTheTidyTargetsNoWindow() {
        let commands = DwindleRules.tidy(in: state([(id: 1, workspace: "1", floating: false)], workspaces: [workspace("1")]))
        XCTAssertEqual(commands.count, 1)
        XCTAssertNil(commands.first?.window)
    }

    func testTheDisplayDecidesTheRootEvenAgainstTheCurrentLayout() {
        let s = state([(id: 1, workspace: "1", floating: false)],
                      workspaces: [workspace("1", landscape: false, root: "h_tiles")])
        XCTAssertTrue(DwindleRules.tidy(in: s).first?.script.contains("--root v_tiles") == true)
    }

    func testTheCurrentLayoutDecidesTheRootWhenTheDisplayIsUnknown() {
        let portrait = state([(id: 1, workspace: "1", floating: false)],
                             workspaces: [workspace("1", landscape: nil, root: "v_accordion")])
        XCTAssertTrue(DwindleRules.tidy(in: portrait).first?.script.contains("--root v_tiles") == true)
        let row = state([(id: 1, workspace: "1", floating: false)],
                        workspaces: [workspace("1", landscape: nil, root: "h_accordion")])
        XCTAssertTrue(DwindleRules.tidy(in: row).first?.script.contains("--root h_tiles") == true)
    }

    func testSideBySideWhenNothingIsKnown() {
        let s = state([(id: 1, workspace: "1", floating: false)], workspaces: [workspace("1")])
        XCTAssertTrue(DwindleRules.tidy(in: s).first?.script.contains("--root h_tiles") == true)
        let unknown = state([(id: 1, workspace: "1", floating: false)])
        XCTAssertTrue(DwindleRules.tidy(in: unknown).first?.script.contains("--root h_tiles") == true)
    }

    func testTheChainFollowsTheWindowIds() {
        XCTAssertEqual(tidy([9, 5, 7], landscape: true),
                       "flatten-workspace-tree --workspace 1; layout --workspace 1 --root h_tiles"
                       + "; layout --window-id 7 floating; layout --window-id 9 floating"
                       + "; layout --window-id 7 tiling; layout --window-id 9 tiling; join-with --window-id 9 left"
                       + "; balance-sizes --workspace 1")
    }

    func testFloatingWindowsAndOtherWorkspacesAreLeftOut() {
        let s = state([(id: 1, workspace: "1", floating: false),
                       (id: 2, workspace: "1", floating: true),
                       (id: 3, workspace: "2", floating: false),
                       (id: 4, workspace: "1", floating: false)],
                      workspaces: [workspace("1", landscape: true)])
        // windows 1 and 4 tile, whatever the workspace holds: the floating one and the other workspace's are left out
        XCTAssertEqual(DwindleRules.tidy(in: s).first?.script,
                       "flatten-workspace-tree --workspace 1; layout --workspace 1 --root h_tiles"
                       + "; layout --window-id 4 floating; layout --window-id 4 tiling"
                       + "; balance-sizes --workspace 1")
    }

    private func tidy(_ ids: [Int], landscape: Bool) -> String? {
        let s = state(ids.map { (id: $0, workspace: "1", floating: false) },
                      workspaces: [workspace("1", landscape: landscape)])
        let commands = DwindleRules.tidy(in: s)
        XCTAssertEqual(commands.count, 1)
        return commands.first?.script
    }
}
