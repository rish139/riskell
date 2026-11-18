import CoreGraphics
import XCTest
import RiskellWM

// The OmniWM payloads in fixtures/ are synthetic: they follow the envelope and payload shape the backend in
// Sources/riskell/Services/Omni.swift reads, but no OmniWM reported them (the machine riskell is written on has none installed).
// Tests/wm/README.md has the command that records real lines over OmniWM's socket.

/// The state slices the fixtures hold, and the screen the frames are measured against.
enum OmniFixture {
    static let screen = CGSize(width: 1512, height: 982)

    static func payload(_ name: String) throws -> Omni.Payload {
        let message = Omni.parse(line: try Fixtures.data(name))
        guard case .event(_, let payload?) = message else {
            throw Fixtures.Error.unexpected("\(name) is not an event with a payload: \(message)")
        }
        return payload
    }

    /// Workspaces 1...6 on the main display, 7 naming no display at all, 9 on the other display.
    static func spaces() throws -> [Omni.Workspace] {
        guard case .workspaces(let spaces) = try payload("omni-workspaces.json") else {
            throw Fixtures.Error.unexpected("omni-workspaces.json is not a workspaces payload")
        }
        return spaces
    }

    /// A tiled window on space 2, a scratchpad, a window on the other display, one with no workspace, one parked off screen, one on space 7.
    static func windows() throws -> [Omni.Window] {
        guard case .windows(let windows) = try payload("omni-windows.json") else {
            throw Fixtures.Error.unexpected("omni-windows.json is not a windows payload")
        }
        return windows
    }
}

final class OmniEventTests: XCTestCase {
    func testAnEventLineCarriesThePayloadOfItsKind() throws {
        let message = Omni.parse(line: try Fixtures.data("omni-windows.json"))
        guard case .event(let kind, .windows(let windows)?) = message else {
            return XCTFail("not a windows event: \(message)")
        }
        XCTAssertEqual(kind, "windows")
        XCTAssertEqual(windows.count, 6)
        XCTAssertEqual(windows[0].windowId, 4212)
        XCTAssertEqual(windows[0].app?.name, "Safari")
        XCTAssertEqual(windows[0].workspace?.number, 2)
        XCTAssertEqual(windows[1].isScratchpad, true)
    }

    func testTheActiveWorkspaceEventCarriesItsNumber() throws {
        XCTAssertEqual(Omni.parse(line: try Fixtures.data("omni-active-workspace.json")), .event(kind: "active-workspace", payload: .activeWorkspace(3)))
    }

    func testTheFocusedWindowEventCarriesItsWindowId() throws {
        XCTAssertEqual(Omni.parse(line: try Fixtures.data("omni-focused-window.json")), .event(kind: "focused-window", payload: .focusedWindow(4212)))
    }

    func testAnEventWhosePayloadDoesNotDecodeStillNamesItsKind() throws {
        // the app raises the floating windows on a focus or workspace event whatever its payload turns out to be
        XCTAssertEqual(Omni.parse(line: try Fixtures.data("omni-windows-bad-payload.json")), .event(kind: "windows", payload: nil))
    }

    func testAFailedLineIsReportedWithItsStatus() throws {
        XCTAssertEqual(Omni.parse(line: try Fixtures.data("omni-failure.json")), .failure(status: "unknown-command"))
    }

    func testACommandReplyIsNotAnEvent() throws {
        // the command connection answers with replies; only the subscription's events are read
        XCTAssertEqual(Omni.parse(line: try Fixtures.data("omni-command-reply.json")), .ignored)
    }

    func testAMalformedLineIsIgnored() throws {
        XCTAssertEqual(Omni.parse(line: Data("omniwm is up".utf8)), .ignored)
    }
}

final class OmniRailTests: XCTestCase {
    func testScratchpadWindowsAndOtherDisplaysAreNotCounted() throws {
        let shown = Omni.shownWindows(try OmniFixture.windows())
        // 4213 is a scratchpad, 4214 is on the other display, 4215 has no workspace number
        XCTAssertEqual(shown.map(\.windowId), [4212, 4216, 4217])
    }

    func testAWorkspaceThatNamesNoDisplayCountsAsTheMainOne() throws {
        XCTAssertEqual(Omni.mainDisplayWorkspaces(try OmniFixture.spaces()).map(\.number), [1, 2, 3, 4, 5, 6, 7])
    }

    func testTheRailAlwaysShowsFiveWorkspacesAndGrowsWithALaterOne() throws {
        // no windows, so the floor is what is drawn
        XCTAssertEqual(Omni.rail(spaces: try OmniFixture.spaces(), windows: [], focus: 1).map(\.id), [1, 2, 3, 4, 5])

        let rail = Omni.rail(spaces: try OmniFixture.spaces(), windows: try OmniFixture.windows(), focus: 2)
        // space 7 holds a window, so it is shown too; space 9 belongs to the other display
        XCTAssertEqual(rail.map(\.id), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(rail.map(\.windows), [0, 1, 1, 0, 0, 0, 1])
        XCTAssertEqual(rail.filter(\.focused).map(\.id), [2])
        XCTAssertEqual(rail.filter(\.visible).map(\.id), [2])
    }

    func testTheActiveWorkspaceWinsOverTheFocusedFlag() throws {
        let spaces = try OmniFixture.spaces()
        XCTAssertEqual(Omni.focus(spaces, active: 3), 3)     // the workspaces payload still says workspace 2 is focused
        XCTAssertEqual(Omni.focus(spaces, active: nil), 2)   // with no active report the focused flag decides
    }

    func testAWindowIsFocusedOnlyWhenItsIdIsTheFocusedOne() throws {
        let windows = Omni.shownWindows(try OmniFixture.windows())
        let infos = Omni.windowInfos(windows, focused: 4212)
        XCTAssertEqual(infos.first, WinInfo(id: 4212, pid: 501, app: "Safari", title: "Start Page", space: 2, focused: true))
        XCTAssertEqual(infos.filter(\.focused).map(\.id), [4212])
        // with no focus report at all, each window's own flag is the answer
        XCTAssertEqual(Omni.windowInfos(windows, focused: nil).filter(\.focused).map(\.id), [4212])
    }

    func testAWindowParkedPastTheScreenEdgeIsNotAPlace() throws {
        let screen = OmniFixture.screen
        // OmniWM reports a hidden window at its parked position, below the screen once the bottom-left origin is flipped
        let parked = CGRect(x: 50, y: screen.height - 1200 - 900, width: 700, height: 900)
        XCTAssertFalse(Omni.mostlyOnScreen(parked, screen: screen))
        let showing = CGRect(x: 50, y: screen.height - 32 - 900, width: 700, height: 900)
        XCTAssertTrue(Omni.mostlyOnScreen(showing, screen: screen))
        // exactly half is still a place; a point less is not
        XCTAssertTrue(Omni.mostlyOnScreen(CGRect(x: 0, y: -450, width: 700, height: 900), screen: screen))
        XCTAssertFalse(Omni.mostlyOnScreen(CGRect(x: 0, y: -451, width: 700, height: 900), screen: screen))
    }
}
