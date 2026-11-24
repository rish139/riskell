// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import CoreGraphics
import RiskellKit
import XCTest
@testable import DwindleAerospaceExt

/// Focusing on a workspace that has no window at all: AeroSpace's own `focus` has nowhere to go there, so every press goes on to the next
/// workspace that way.
final class DwindleEmptyWorkspaceTests: XCTestCase {
    private func state(windows: [ManagedWindow], focused: String, monitors: [Int?] = Array(repeating: 1, count: 9)) -> ManagerState {
        let spaces = monitors.enumerated().map { ManagedWorkspace(name: String($0.offset + 1), rootLayout: "h_tiles", landscape: true, monitor: $0.element) }
        return ManagerState(windows: windows, workspaces: spaces, focusedWindow: nil, focusedWorkspace: focused)
    }

    private func hidden(_ id: Int, on workspace: String, floating: Bool = false) -> ManagedWindow {
        ManagedWindow(id: id, workspace: workspace, floating: floating)
    }

    func testTheFocusGoesOnInBothDirectionsFromAnEmptyWorkspace() {
        let windows = [hidden(10, on: "4"), hidden(11, on: "4"), hidden(12, on: "4"), hidden(20, on: "6")]
        let s = state(windows: windows, focused: "5")
        XCTAssertEqual(DwindleRules.focus(.right, in: s), [ManagerCommand("workspace 6; focus --dfs-index 0")])
        XCTAssertEqual(DwindleRules.focus(.left, in: s), [ManagerCommand("workspace 4; focus --dfs-index 2")])
    }

    func testAnEmptyNeighbourIsOnlySwitchedTo() {
        let s = state(windows: [hidden(10, on: "3")], focused: "5")
        XCTAssertEqual(DwindleRules.focus(.right, in: s), [ManagerCommand("workspace 6")])
        XCTAssertEqual(DwindleRules.focus(.left, in: s), [ManagerCommand("workspace 4")])
    }

    func testNothingBeyondTheFirstAndTheLastWorkspace() {
        let s = state(windows: [], focused: "1")
        XCTAssertEqual(DwindleRules.focus(.left, in: s), [])
        XCTAssertEqual(DwindleRules.focus(.right, in: s), [ManagerCommand("workspace 2")])
        let last = state(windows: [], focused: "9")
        XCTAssertEqual(DwindleRules.focus(.right, in: last), [])
        XCTAssertEqual(DwindleRules.focus(.left, in: last), [ManagerCommand("workspace 8")])
    }

    func testUpAndDownAreLeftAlone() {
        let s = state(windows: [], focused: "5")
        XCTAssertEqual(DwindleRules.focus(.up, in: s), [])
        XCTAssertEqual(DwindleRules.focus(.down, in: s), [])
    }

    func testAWorkspaceWithOnlyAFloatingWindowIsNotEmpty() {
        // AeroSpace's `focus` may still move between floating windows there, so the two must not both act
        let s = state(windows: [hidden(10, on: "5", floating: true), hidden(20, on: "6")], focused: "5")
        XCTAssertEqual(DwindleRules.focus(.right, in: s), [])
    }

    func testTheNeighbourStaysOnTheMonitorOfTheWorkspace() {
        // workspaces 1, 2, 4 on monitor 1, and 3, 5 on monitor 2 (the rest too): from 5 going left is 3, never 4
        let monitors: [Int?] = [1, 1, 2, 1, 2, 1, 1, 1, 1]
        let s = state(windows: [hidden(20, on: "3")], focused: "5", monitors: monitors)
        XCTAssertEqual(DwindleRules.focus(.left, in: s), [ManagerCommand("workspace 3; focus --dfs-index 0")])
        XCTAssertEqual(DwindleRules.focus(.right, in: s), [])
    }
}
