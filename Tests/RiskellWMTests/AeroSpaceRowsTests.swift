import XCTest
import RiskellWM

// The rows are built here rather than recorded: what these tests are about is the edit an event makes to them, and every field it does
// not touch has to stay exactly as the query printed it.
final class AeroSpaceRowsTests: XCTestCase {
    /// Two workspaces on one monitor, one window on each: workspace 1 focused, one visible, the other hidden.
    private func oneMonitor() -> AeroSpace.Rows {
        AeroSpace.Rows(workspaces: [AeroSpace.WorkspaceRow(workspace: "1", focused: true, visible: true, monitor: 1),
                                    AeroSpace.WorkspaceRow(workspace: "2", focused: false, visible: false, monitor: 1)],
                       windows: [AeroSpace.WindowRow(windowId: 10, workspace: "1", workspaceFocused: true, workspaceVisible: true),
                                 AeroSpace.WindowRow(windowId: 20, workspace: "2", workspaceFocused: false, workspaceVisible: false)])
    }

    /// Two monitors, two workspaces each: workspace 1 (monitor 1) and workspace 3 (monitor 2) are showing.
    private func twoMonitors() -> AeroSpace.Rows {
        AeroSpace.Rows(workspaces: [AeroSpace.WorkspaceRow(workspace: "1", focused: true, visible: true, monitor: 1),
                                    AeroSpace.WorkspaceRow(workspace: "2", focused: false, visible: false, monitor: 1),
                                    AeroSpace.WorkspaceRow(workspace: "3", focused: false, visible: true, monitor: 2),
                                    AeroSpace.WorkspaceRow(workspace: "4", focused: false, visible: false, monitor: 2)],
                       windows: [AeroSpace.WindowRow(windowId: 10, workspace: "1", workspaceFocused: true, workspaceVisible: true),
                                 AeroSpace.WindowRow(windowId: 20, workspace: "2", workspaceFocused: false, workspaceVisible: false),
                                 AeroSpace.WindowRow(windowId: 30, workspace: "3", workspaceFocused: false, workspaceVisible: true),
                                 AeroSpace.WindowRow(windowId: 40, workspace: "4", workspaceFocused: false, workspaceVisible: false)])
    }

    // MARK: focus and workspace changes

    func testFocusingAKnownWindowOnAnotherWorkspaceEditsTheRowsInsteadOfAsking() {
        let next = AeroSpace.decide(.focus(windowId: 20, workspace: "2"), rows: oneMonitor(), bindings: nil, stale: false)
        let rows = AeroSpace.Rows(workspaces: [AeroSpace.WorkspaceRow(workspace: "1", focused: false, visible: false, monitor: 1),
                                              AeroSpace.WorkspaceRow(workspace: "2", focused: true, visible: true, monitor: 1)],
                                  windows: [AeroSpace.WindowRow(windowId: 10, workspace: "1", workspaceFocused: false, workspaceVisible: false),
                                            AeroSpace.WindowRow(windowId: 20, workspace: "2", workspaceFocused: true, workspaceVisible: true)])
        XCTAssertEqual(next, .apply(rows))
    }

    func testFocusingAWindowOnTheFocusedWorkspaceChangesNoFlag() {
        XCTAssertEqual(AeroSpace.decide(.focus(windowId: 10, workspace: "1"), rows: oneMonitor(), bindings: nil, stale: false),
                       .apply(oneMonitor()))
    }

    func testAnEmptyWorkspaceCanTakeTheFocus() {
        // focus-changed names no window when the focused workspace holds none
        let rows = AeroSpace.Rows(workspaces: [AeroSpace.WorkspaceRow(workspace: "1", focused: true, visible: true, monitor: 1),
                                               AeroSpace.WorkspaceRow(workspace: "2", focused: false, visible: false, monitor: 1)],
                                  windows: [])
        let next = AeroSpace.decide(.focus(windowId: nil, workspace: "2"), rows: rows, bindings: nil, stale: false)
        XCTAssertEqual(next, .apply(AeroSpace.Rows(workspaces: [AeroSpace.WorkspaceRow(workspace: "1", focused: false, visible: false, monitor: 1),
                                                                AeroSpace.WorkspaceRow(workspace: "2", focused: true, visible: true, monitor: 1)],
                                                    windows: [])))
    }

    func testAWindowRiskellDoesNotKnowAsksForTheRows() {
        XCTAssertEqual(AeroSpace.decide(.focus(windowId: 99, workspace: "2"), rows: oneMonitor(), bindings: nil, stale: false), .refresh)
    }

    func testAWindowNamedOnAnotherWorkspaceThanItsRowAsksForTheRows() {
        // the same window id, but the event puts it on the focused workspace: the rows are older than the event
        XCTAssertEqual(AeroSpace.decide(.focus(windowId: 20, workspace: "1"), rows: oneMonitor(), bindings: nil, stale: false), .refresh)
    }

    func testAWorkspaceRiskellDoesNotKnowAsksForTheRows() {
        XCTAssertEqual(AeroSpace.decide(.focus(windowId: nil, workspace: "7"), rows: oneMonitor(), bindings: nil, stale: false), .refresh)
        XCTAssertEqual(AeroSpace.decide(.focusedWorkspace("7"), rows: oneMonitor(), bindings: nil, stale: false), .refresh)
    }

    func testAnEventWithoutAWorkspaceAsksForTheRows() {
        XCTAssertEqual(AeroSpace.decide(.focus(windowId: 10, workspace: nil), rows: oneMonitor(), bindings: nil, stale: false), .refresh)
        XCTAssertEqual(AeroSpace.decide(.focus(windowId: nil, workspace: nil), rows: oneMonitor(), bindings: nil, stale: false), .refresh)
        XCTAssertEqual(AeroSpace.decide(.focusedWorkspace(nil), rows: oneMonitor(), bindings: nil, stale: false), .refresh)
    }

    func testStaleRowsAreNeverApplied() {
        XCTAssertEqual(AeroSpace.decide(.focus(windowId: 20, workspace: "2"), rows: oneMonitor(), bindings: nil, stale: true), .refresh)
        XCTAssertEqual(AeroSpace.decide(.focusedWorkspace("2"), rows: oneMonitor(), bindings: nil, stale: true), .refresh)
        XCTAssertEqual(AeroSpace.decide(.activation, rows: oneMonitor(), bindings: nil, stale: true), .refresh)
    }

    func testWithoutRowsEveryEventAsks() {
        XCTAssertEqual(AeroSpace.decide(.focus(windowId: 20, workspace: "2"), rows: nil, bindings: nil, stale: false), .refresh)
        XCTAssertEqual(AeroSpace.decide(.focusedWorkspace("2"), rows: nil, bindings: nil, stale: false), .refresh)
        XCTAssertEqual(AeroSpace.decide(.activation, rows: nil, bindings: nil, stale: false), .refresh)
        XCTAssertEqual(AeroSpace.decide(.refresh, rows: oneMonitor(), bindings: nil, stale: false), .refresh)
    }

    func testAWindowAppearingOrAMonitorChangeAsksForTheRows() {
        // only a query can say where a new window went, or what a new monitor shows
        XCTAssertEqual(AeroSpace.decide(.refresh, rows: oneMonitor(), bindings: nil, stale: false), .refresh)
    }

    // MARK: two monitors

    func testFocusingTheOtherMonitorsWorkspaceLeavesItsNeighbourShowing() {
        let next = AeroSpace.decide(.focusedWorkspace("3"), rows: twoMonitors(), bindings: nil, stale: false)
        let rows = AeroSpace.Rows(workspaces: [AeroSpace.WorkspaceRow(workspace: "1", focused: false, visible: true, monitor: 1),
                                              AeroSpace.WorkspaceRow(workspace: "2", focused: false, visible: false, monitor: 1),
                                              AeroSpace.WorkspaceRow(workspace: "3", focused: true, visible: true, monitor: 2),
                                              AeroSpace.WorkspaceRow(workspace: "4", focused: false, visible: false, monitor: 2)],
                                  windows: [AeroSpace.WindowRow(windowId: 10, workspace: "1", workspaceFocused: false, workspaceVisible: true),
                                            AeroSpace.WindowRow(windowId: 20, workspace: "2", workspaceFocused: false, workspaceVisible: false),
                                            AeroSpace.WindowRow(windowId: 30, workspace: "3", workspaceFocused: true, workspaceVisible: true),
                                            AeroSpace.WindowRow(windowId: 40, workspace: "4", workspaceFocused: false, workspaceVisible: false)])
        XCTAssertEqual(next, .apply(rows))
    }

    func testFocusingAWorkspaceHidesOnlyTheWorkspacesBesideIt() {
        // workspace 1 on monitor 1 is focused and showing; workspace 3 on monitor 2 shows. Focusing 2 hides 1 and leaves 3 alone.
        let next = AeroSpace.decide(.focusedWorkspace("2"), rows: twoMonitors(), bindings: nil, stale: false)
        guard case .apply(let rows) = next else { return XCTFail("expected a local apply, got \(next)") }
        XCTAssertEqual(rows.workspaces.map(\.focused), [false, true, false, false])
        XCTAssertEqual(rows.workspaces.map(\.visible), [false, true, true, false])
        XCTAssertEqual(rows.windows.map(\.workspaceVisible), [false, true, true, false])
        XCTAssertEqual(rows.windows.map(\.workspaceFocused), [false, true, false, false])
    }

    func testAWorkspaceWhoseMonitorIsUnknownHidesNothingElse() {
        // the query reported no monitor for workspace 4: whether it shares a monitor with 1 cannot be known, so no flag is guessed away
        let rows = AeroSpace.Rows(workspaces: [AeroSpace.WorkspaceRow(workspace: "1", focused: true, visible: true, monitor: 1),
                                               AeroSpace.WorkspaceRow(workspace: "4", focused: false, visible: true, monitor: nil)],
                                  windows: [])
        let next = AeroSpace.decide(.focusedWorkspace("4"), rows: rows, bindings: nil, stale: false)
        guard case .apply(let edited) = next else { return XCTFail("expected a local apply, got \(next)") }
        XCTAssertEqual(edited.workspaces.map(\.focused), [false, true])
        XCTAssertEqual(edited.workspaces.map(\.visible), [true, true])
    }

    // MARK: bindings

    private let navigationTable = ["main": ["alt-h": "focus --direction left",
                                           "alt-1": "workspace 1",
                                           "alt-tab": "workspace-back-and-forth",
                                           "alt-m": "focus-monitor 2",
                                           "alt-b": "focus-back-and-forth",
                                           "alt-r": "mode resize"],
                                  "resize": ["h": "resize smart +50", "escape": "mode main"]]

    func testANavigationBindingAppliesTheRowsItAlreadyHas() {
        for notation in ["alt-h", "alt-1", "alt-tab", "alt-m", "alt-b", "alt-r"] {
            XCTAssertEqual(AeroSpace.decide(.binding(mode: "main", binding: notation), rows: oneMonitor(), bindings: navigationTable, stale: false),
                           .apply(oneMonitor()), notation)
        }
    }

    func testANonNavigationBindingMarksTheRowsStale() {
        // a window made floating is in the rows (as floating), so the next answer has to be asked for
        let table: AeroSpace.Bindings = ["main": ["alt-f": "layout floating tiling"]]
        XCTAssertEqual(AeroSpace.decide(.binding(mode: "main", binding: "alt-f"), rows: oneMonitor(), bindings: table, stale: false),
                       .staleRefresh)
    }

    func testAResizeBindingAppliesTheRowsItAlreadyHas() {
        // sizes are in no row, and the frames the overview draws come from the window server when it opens, not from a query: asking the manager
        // after a resize would only make it lay the windows out again, once for every repeat of a held key
        XCTAssertEqual(AeroSpace.decide(.binding(mode: "resize", binding: "h"), rows: oneMonitor(), bindings: navigationTable, stale: false),
                       .apply(oneMonitor()))
    }

    func testABindingNotInTheTableReadsTheTableAgain() {
        // a binding added to the config since the table was read: one request for the table, one for the rows
        XCTAssertEqual(AeroSpace.decide(.binding(mode: "main", binding: "alt-z"), rows: oneMonitor(), bindings: navigationTable, stale: false),
                       .readBindings)
    }

    func testABindingInAModeTheTableDoesNotHoldReadsTheTableAgain() {
        XCTAssertEqual(AeroSpace.decide(.binding(mode: "service", binding: "r"), rows: oneMonitor(), bindings: navigationTable, stale: false),
                       .readBindings)
    }

    func testABindingWithoutATableReadsTheTable() {
        XCTAssertEqual(AeroSpace.decide(.binding(mode: "main", binding: "alt-h"), rows: oneMonitor(), bindings: nil, stale: false),
                       .readBindings)
    }

    func testABindingWithoutAModeOrNotationReadsTheTable() {
        XCTAssertEqual(AeroSpace.decide(.binding(mode: nil, binding: "alt-h"), rows: oneMonitor(), bindings: navigationTable, stale: false),
                       .readBindings)
        XCTAssertEqual(AeroSpace.decide(.binding(mode: "main", binding: nil), rows: oneMonitor(), bindings: navigationTable, stale: false),
                       .readBindings)
    }

    func testABindingWithoutRowsAsksForTheRowsAndNotTheTable() {
        XCTAssertEqual(AeroSpace.decide(.binding(mode: "main", binding: "alt-z"), rows: nil, bindings: nil, stale: false), .refresh)
    }

    // MARK: navigation bindings

    func testNavigationIsEveryCommandMovingTheFocusOrAWorkspace() {
        for script in ["focus --direction left", "workspace 2", "workspace prev", "workspace-back-and-forth", "focus-monitor 1",
                       "focus-monitor --wrap-around next", "focus-back-and-forth", "mode resize", "focus left; workspace 2",
                       "focus left;workspace 2"] {
            XCTAssertTrue(AeroSpace.isNavigation(script), script)
        }
    }

    func testAnotherCommandInABindingMakesItNoNavigation() {
        for script in ["resize smart +50", "fullscreen", "move-node-to-workspace 3", "balance-sizes", "layout tiles horizontal vertical",
                       "focus left; resize smart +50", "exec-and-forget open -a Safari", "", "   ", "focus left | cat",
                       "focus left && workspace 2", "(focus left)", "flatset smart"] {
            XCTAssertFalse(AeroSpace.isNavigation(script), script)
        }
    }

    func testACommandNameIsReadPastAQuotedArgument() {
        // the separator inside the quotes is the argument's, not the binding's
        XCTAssertTrue(AeroSpace.isNavigation("focus --window-id '1; 2'"))
        XCTAssertFalse(AeroSpace.isNavigation("exec-and-forget echo 'focus left'"))
    }

    // MARK: bindings that cannot change the rail

    func testBindingsThatCannotMoveAWindowOrAWorkspaceAskForNothing() {
        for script in ["volume up", "volume --gui set 40", "echo hello", "move-mouse window-lazy-center", "test %{workspace} = 1",
                       "true", "false", "exec-and-forget open -a Safari", "volume up; echo hello", "focus left; volume down",
                       // sizes and the fullscreen flag are in no row: a held resize key must not put a query behind every repeat
                       "resize smart +50", "resize smart -50", "resize width +20", "balance-sizes", "fullscreen",
                       "resize smart +50; focus left"] {
            XCTAssertTrue(AeroSpace.changesNothing(script), script)
        }
    }

    func testAResizeThatSitsBesideACommandThatCanMoveAWindowStillAsks() {
        XCTAssertFalse(AeroSpace.changesNothing("resize smart +50; move-node-to-workspace 3"))
        XCTAssertFalse(AeroSpace.changesNothing("fullscreen && layout floating"))
    }

    func testBindingsThatCanChangeTheRailStillAsk() {
        // reload-config and trigger-binding run something else that can move a window; enable changes what the manager does
        for script in ["reload-config", "trigger-binding alt-h", "enable off",
                       "move-node-to-workspace 3", "layout floating tiling", "layout tiles horizontal vertical", "move --window-id 10 --monitor 2",
                       "exec-and-forget echo x && focus left", "flatset smart", ""] {
            XCTAssertFalse(AeroSpace.changesNothing(script), script)
        }
    }

    func testAQuietBindingIsNotNavigation() {
        XCTAssertFalse(AeroSpace.isNavigation("exec-and-forget open -a Safari"))
        XCTAssertTrue(AeroSpace.changesNothing("exec-and-forget open -a Safari"))
        XCTAssertFalse(AeroSpace.changesNothing("volume up | cat"))
    }

    // MARK: an app coming forward

    func testAnAppComingForwardChangesNothingWhenTheRowsAreWhole() {
        // no request: the caller still asks the window server whether a window went away
        XCTAssertEqual(AeroSpace.decide(.activation, rows: oneMonitor(), bindings: nil, stale: false), .apply(oneMonitor()))
    }
}
