import CoreGraphics
import XCTest
import RiskellWM

// The AeroSpace payloads in fixtures/ are synthetic: the JSON the CLI prints for `list-workspaces --all --json` and
// `list-windows --all --json`, and the plain-text workspace names `list-workspaces --focused|--visible` print, as AeroSpace.swift reads
// them. No AeroSpace printed them. Tests/wm/README.md has the commands that record real ones.

final class AeroSpaceQueryTests: XCTestCase {
    /// One refresh: workspaces 1, 2, 3, T and mail, four windows, workspace 1 focused and 1 + 2 visible.
    private func snapshot(focusedWindow: Data? = nil, focusedWorkspace: [String]? = nil,
                          visibleWorkspaces: [String]? = nil) throws -> AeroSpace.Snapshot {
        let windowData = try focusedWindow ?? Fixtures.data("aerospace-focused-window.json")
        let focused = try focusedWorkspace ?? AeroSpace.lines(Fixtures.data("aerospace-focused-workspaces.txt")) ?? []
        let visible = try visibleWorkspaces ?? AeroSpace.lines(Fixtures.data("aerospace-visible-workspaces.txt")) ?? []
        return try XCTUnwrap(AeroSpace.parse(workspaces: try Fixtures.data("aerospace-workspaces.json"),
                                             windows: try Fixtures.data("aerospace-windows.json"),
                                             focusedWindow: windowData, focusedWorkspace: focused, visibleWorkspaces: visible))
    }

    func testPlainTextWorkspaceLinesAreTrimmedAndEmptyLinesDropped() throws {
        // a plain-text call, not JSON: names one per line, padded or empty lines included
        XCTAssertEqual(AeroSpace.lines(Data("  1 \n\n 2\r\n3\n  \n".utf8)), ["1", "2", "3"])
        XCTAssertEqual(AeroSpace.lines(try Fixtures.data("aerospace-focused-workspaces.txt")), ["1"])
    }

    func testOnlyNumericWorkspaceNamesAreRailEntries() throws {
        let snapshot = try snapshot()
        // "T" and "mail" are not workspaces the numbered rail can show
        XCTAssertEqual(snapshot.spaces.map(\.id), [1, 2, 3])
        XCTAssertEqual(snapshot.spaces.map(\.windows), [2, 0, 1])
    }

    func testTheFocusedAndVisibleWorkspacesAreSeparateFlags() throws {
        let snapshot = try snapshot()
        XCTAssertEqual(snapshot.spaces.filter(\.focused).map(\.id), [1])
        XCTAssertEqual(snapshot.spaces.filter(\.visible).map(\.id), [1, 2])
    }

    func testTheFocusedWorkspaceCountsAsVisibleEvenWhenTheVisibleListOmitsIt() throws {
        let snapshot = try snapshot(visibleWorkspaces: [])
        XCTAssertEqual(snapshot.spaces.filter(\.visible).map(\.id), [1])
    }

    func testAFocusedWindowMarksOnlyItsOwnEntry() throws {
        let snapshot = try snapshot()
        XCTAssertEqual(snapshot.windows.filter(\.focused).map(\.id), [2002])
        XCTAssertEqual(snapshot.windows.first,
                       WinInfo(id: 2001, pid: 501, app: "Safari", title: "Start Page", space: 1, focused: false))
    }

    func testAWindowOnANonNumericWorkspaceIsNotDrawn() throws {
        // 2004 lives on workspace "T"
        XCTAssertEqual((try snapshot()).windows.map(\.id), [2001, 2002, 2003])
    }

    func testNoFocusedWindowLeavesEveryWindowUnfocused() throws {
        // `list-windows --focused --json` prints nothing when no window has focus: the refresh still publishes
        let snapshot = try snapshot(focusedWindow: try Fixtures.data("aerospace-focused-window-none.txt"))
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertTrue(snapshot.windows.allSatisfy { !$0.focused })
        XCTAssertTrue(snapshot.spaces.contains { $0.focused })
    }

    func testAWorkspaceListThatIsNotJSONFailsTheWholeRefresh() throws {
        XCTAssertNil(AeroSpace.parse(workspaces: Data("aerospace: not running".utf8),
                                     windows: try Fixtures.data("aerospace-windows.json"),
                                     focusedWindow: nil, focusedWorkspace: [], visibleWorkspaces: []))
    }
}
