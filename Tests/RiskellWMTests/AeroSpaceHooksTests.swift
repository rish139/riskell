import RiskellKit
import XCTest
import RiskellWM

// What the AeroSpace backend gives a manager hook: the state it plans from, the windows it hears about as having arrived, the screens, and
// the requests its commands travel in. Nothing here opens a socket or reads a screen.
final class AeroSpaceHooksTests: XCTestCase {
    /// A window in the tiling tree unless the test says otherwise: nearly every row here is one, and the state a hook is handed counts
    /// only those.
    private func window(_ id: Int, _ workspace: String, _ layout: String = "h_tiles") -> AeroSpace.WindowRow {
        AeroSpace.WindowRow(windowId: id, workspace: workspace, parentLayout: layout)
    }

    private func rows(_ windows: [AeroSpace.WindowRow], workspaces: [AeroSpace.WorkspaceRow] = []) -> AeroSpace.Rows {
        AeroSpace.Rows(workspaces: workspaces.isEmpty ? [AeroSpace.WorkspaceRow(workspace: "1", focused: true, visible: true, monitor: 1)]
                                                      : workspaces,
                       windows: windows)
    }

    // MARK: the state

    func testTheStateIsInWindowIdOrderWhateverTheQueryReturned() {
        let state = AeroSpace.managerState(rows: rows([window(30, "2"),
                                                       window(10, "1"),
                                                       window(20, "1", "floating")]),
                                           focusedWindow: 10, landscape: [1: true], gone: [])
        XCTAssertEqual(state.windows.map(\.id), [10, 20, 30])
        XCTAssertEqual(state.windows.map(\.floating), [false, true, false])
        XCTAssertEqual(state.focusedWindow, 10)
        XCTAssertEqual(state.focusedWorkspace, "1")
    }

    func testTheStateLeavesOutAWindowTheWindowServerSaysIsGone() {
        let state = AeroSpace.managerState(rows: rows([window(10, "1"),
                                                       window(20, "1")]),
                                           focusedWindow: 20, landscape: [:], gone: [20])
        XCTAssertEqual(state.windows.map(\.id), [10])
        XCTAssertNil(state.focusedWindow)
    }

    func testAWorkspaceCarriesItsRootLayoutAndItsScreenOrientation() {
        let state = AeroSpace.managerState(rows: rows([window(10, "1")],
                                                      workspaces: [AeroSpace.WorkspaceRow(workspace: "1", focused: true, visible: true, monitor: 2, rootLayout: "v_tiles"),
                                                                   AeroSpace.WorkspaceRow(workspace: "2", monitor: 3, rootLayout: "h_accordion")]),
                                           focusedWindow: nil, landscape: [2: false, 3: true], gone: [])
        XCTAssertEqual(state.workspaces, [ManagedWorkspace(name: "1", rootLayout: "v_tiles", landscape: false),
                                          ManagedWorkspace(name: "2", rootLayout: "h_accordion", landscape: true)])
        XCTAssertEqual(state.focusedWorkspace, "1")
    }

    func testEveryWindowOutsideTheTilingTreeIsFloatingInTheState() {
        // minimised, native fullscreen, a hidden app's, a popup and a floating window all count as outside: a hook that counts a
        // workspace's windows must not see them
        let outside = ["floating", "macos_native_minimized", "macos_native_fullscreen", "macos_native_window_of_hidden_app", "NULL-WINDOW-LAYOUT"]
        var windows = outside.enumerated().map { i, layout in window(10 + i, "1", layout) }
        windows += ["h_tiles", "v_tiles", "h_accordion", "v_accordion"].enumerated().map { i, layout in
            window(40 + i, "1", layout)
        }
        let state = AeroSpace.managerState(rows: rows(windows), focusedWindow: nil, landscape: [:], gone: [])
        XCTAssertEqual(state.windows.filter(\.floating).map(\.id), [10, 11, 12, 13, 14])
        XCTAssertEqual(state.windows.filter { !$0.floating }.map(\.id), [40, 41, 42, 43])
    }

    func testAWindowWithoutAKnownParentIsOutsideTheTilingTree() {
        // the query did not say where the window sits: it is not counted as one the manager lays out
        let state = AeroSpace.managerState(rows: rows([AeroSpace.WindowRow(windowId: 10, workspace: "1")]), focusedWindow: nil,
                                           landscape: [:], gone: [])
        XCTAssertTrue(state.windows[0].floating)
    }

    func testAMonitorTheScreensDoNotExplainHasNoOrientation() {
        let state = AeroSpace.managerState(rows: rows([], workspaces: [AeroSpace.WorkspaceRow(workspace: "1", monitor: 4)]),
                                           focusedWindow: nil, landscape: [1: true], gone: [])
        XCTAssertNil(state.workspaces[0].landscape)
        XCTAssertNil(state.workspaces[0].rootLayout)
    }

    // MARK: arrivals

    func testAWindowOnAnotherWorkspaceHasArrived() {
        let before = rows([window(10, "1"), window(20, "1")])
        let after = rows([window(10, "1"), window(20, "2")])
        XCTAssertEqual(AeroSpace.arrivals(from: before, to: after), [ManagerEvent(name: "window-arrived", fields: ["windowId": "20", "workspace": "2"])])
    }

    func testAWindowThatStoppedFloatingOnTheSameWorkspaceHasArrived() {
        let before = rows([window(10, "1"), window(20, "1", "floating")])
        let after = rows([window(10, "1"), window(20, "1")])
        XCTAssertEqual(AeroSpace.arrivals(from: before, to: after), [ManagerEvent(name: "window-arrived", fields: ["windowId": "20", "workspace": "1"])])
    }

    func testAWindowThatMovedAndStillFloatsHasNotArrived() {
        let before = rows([window(20, "1", "floating")])
        let after = rows([window(20, "2", "floating")])
        XCTAssertEqual(AeroSpace.arrivals(from: before, to: after), [])
    }

    func testAWindowOnlyInTheNewAnswerIsNotAnArrival() {
        // a window the manager has just opened is `window-detected`; it did not come from anywhere
        let before = rows([window(10, "1")])
        let after = rows([window(10, "1"), window(20, "1")])
        XCTAssertEqual(AeroSpace.arrivals(from: before, to: after), [])
    }

    func testAWindowOnlyInTheOldAnswerIsNotAnArrival() {
        let before = rows([window(10, "1"), window(20, "1")])
        let after = rows([window(10, "1")])
        XCTAssertEqual(AeroSpace.arrivals(from: before, to: after), [])
    }

    func testEveryArrivalIsReportedInWindowIdOrder() {
        let before = rows([window(30, "1"), window(10, "1")])
        let after = rows([window(30, "2"), window(10, "2")])
        XCTAssertEqual(AeroSpace.arrivals(from: before, to: after).map { $0.windowId }, [10, 30])
    }

    // MARK: the state for a move riskell sends

    func testTheWindowBeingMovedIsCountedOnNeitherWorkspace() {
        let state = AeroSpace.managerState(rows: rows([window(10, "1"),
                                                       window(20, "1"),
                                                       window(30, "2")]),
                                           focusedWindow: 20, landscape: [:], gone: [])
        let moved = AeroSpace.without(20, in: state)
        XCTAssertEqual(moved.windows.map(\.id), [10, 30])
        XCTAssertNil(moved.focusedWindow)
        XCTAssertEqual(moved.workspaces, state.workspaces)
    }

    // MARK: the arrival riskell causes itself

    func testTheOneArrivalRiskellMovedIsLeftOutOfTheComparison() {
        let before = rows([window(10, "1"), window(20, "1"),
                           window(30, "1")])
        let after = rows([window(10, "2"), window(20, "1"),
                          window(30, "2")])
        // 10 and 30 moved too: only the one riskell caused is left out
        XCTAssertEqual(AeroSpace.arrivals(from: before, to: after, ignoring: (window: 20, workspace: "2")).map(\.windowId), [10, 30])
    }

    func testAnArrivalOnAnotherWorkspaceThanTheExpectedOneIsStillReported() {
        // the move did not land where it was sent: whatever happened next is news
        let before = rows([window(20, "1")])
        let after = rows([window(20, "3")])
        XCTAssertEqual(AeroSpace.arrivals(from: before, to: after, ignoring: (window: 20, workspace: "2")),
                       [ManagerEvent(name: "window-arrived", fields: ["windowId": "20", "workspace": "3"])])
    }

    func testAWindowThatWasMinimisedOrInFullscreenHasArrivedWhenItTilesAgain() {
        for gone in ["macos_native_minimized", "macos_native_fullscreen", "macos_native_window_of_hidden_app"] {
            let before = rows([window(20, "1", gone)])
            let after = rows([window(20, "1")])
            XCTAssertEqual(AeroSpace.arrivals(from: before, to: after).map(\.windowId), [20], gone)
        }
    }

    func testAMinimisedWindowMovedToAnotherWorkspaceHasNotArrived() {
        // it is not in the tiling tree there either, so nothing was laid out
        let before = rows([window(20, "1", "macos_native_minimized")])
        let after = rows([window(20, "2", "macos_native_minimized")])
        XCTAssertEqual(AeroSpace.arrivals(from: before, to: after), [])
    }

    // MARK: the requests

    func testCommandsForOneWindowAreOneRequestWithTheQueriesAtTheEnd() {
        let commands = [ManagerCommand("join-with left", window: 20), ManagerCommand("join-with up", window: 20)]
        let requests = AeroSpace.hookRequests(commands, queries: [["list-workspaces"], ["list-windows", "--all"]])
        XCTAssertEqual(requests, [AeroSpace.HookRequest(window: 20, args: [
            "eval", "join-with left; join-with up; list-workspaces; list-windows --all"])])
    }

    func testCommandsForDifferentWindowsAreOneRequestEachAndOnlyTheLastAsks() {
        let commands = [ManagerCommand("layout --window-id 10 floating", window: 10),
                        ManagerCommand("layout --window-id 20 floating", window: 20)]
        let requests = AeroSpace.hookRequests(commands, queries: [["list-workspaces"]])
        XCTAssertEqual(requests.map(\.window), [10, 20])
        XCTAssertEqual(requests[0].args, ["eval", "layout --window-id 10 floating"])
        XCTAssertEqual(requests[1].args, ["eval", "layout --window-id 20 floating; list-workspaces"])
    }

    func testACommandWithNoTargetIsSentWithNoWindow() {
        let requests = AeroSpace.hookRequests([ManagerCommand("flatten-workspace-tree --workspace 1")], queries: [["list-workspaces"]])
        XCTAssertEqual(requests, [AeroSpace.HookRequest(window: nil, args: ["eval", "flatten-workspace-tree --workspace 1; list-workspaces"])])
    }

    func testTheCommandOfRiskellsOwnGoesInFrontOfTheHookScripts() {
        let requests = AeroSpace.hookRequests([ManagerCommand("join-with left", window: 20)], queries: [["list-workspaces"]],
                                              first: ["move-node-to-workspace", "--window-id", "20", "2"])
        XCTAssertEqual(requests, [AeroSpace.HookRequest(window: 20, args: [
            "eval", "move-node-to-workspace --window-id 20 2; join-with left; list-workspaces"])])
    }

    func testAMoveWithNoHookCommandsIsOneRequestWithTheQueries() {
        let requests = AeroSpace.hookRequests([], queries: [["list-workspaces"], ["list-windows"]],
                                              first: ["move-node-to-workspace", "--window-id", "20", "2"])
        XCTAssertEqual(requests, [AeroSpace.HookRequest(window: nil, args: [
            "eval", "move-node-to-workspace --window-id 20 2; list-workspaces; list-windows"])])
    }

    func testNoQueriesAndNoCommandsIsNoRequestAtAll() {
        XCTAssertEqual(AeroSpace.hookRequests([], queries: []), [])
    }

    // MARK: the screens

    func testMonitorIdsFollowTheSameSortAeroSpaceNumbersThemBy() {
        // a 1920x1080 screen at the origin, a portrait one to its left, one above it
        let frames = [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                      CGRect(x: -1080, y: 0, width: 1080, height: 1920),
                      CGRect(x: 0, y: 1080, width: 1920, height: 1080)]
        let landscape = AeroSpace.landscape(frames: frames, mainHeight: 1080)
        XCTAssertEqual(landscape, [1: false, 2: true, 3: true])      // sorted by x, then by the top corner from above
    }

    func testOneScreenIsItsOwnFirstMonitor() {
        XCTAssertEqual(AeroSpace.landscape(frames: [CGRect(x: 0, y: 0, width: 1512, height: 982)], mainHeight: 982), [1: true])
        XCTAssertEqual(AeroSpace.landscape(frames: [CGRect(x: 0, y: 0, width: 1080, height: 1920)], mainHeight: 1920), [1: false])
    }

    func testNoScreensTellNoOrientation() {
        XCTAssertEqual(AeroSpace.landscape(frames: [], mainHeight: 1080), [:])
    }
}
