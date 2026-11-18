import CoreGraphics
import XCTest
import RiskellWM

// The yabai payloads in fixtures/ are synthetic: three `yabai -m query` streams of the shape Yabai.swift decodes, from a two-display
// arrangement (the second display at the global origin), not recorded from a running yabai. Tests/wm/README.md has the three commands
// that record real ones from the same moment.

final class YabaiQueryTests: XCTestCase {
    /// The three streams of one query round: displays 1 (left, negative origin) and 2 (at the global origin), spaces 1...3, five windows.
    private func snapshot() throws -> Yabai.Snapshot {
        try XCTUnwrap(Yabai.parse(displays: try Fixtures.data("yabai-displays.json"),
                                  spaces: try Fixtures.data("yabai-spaces.json"),
                                  windows: try Fixtures.data("yabai-windows.json")))
    }

    func testKebabCaseKeysAreDecoded() throws {
        let snapshot = try snapshot()
        // is-native-fullscreen, has-focus and is-visible
        XCTAssertEqual(snapshot.spaces.map(\.id), [2, 3])
        XCTAssertEqual(snapshot.spaces.map(\.fullscreen), [true, false])
        XCTAssertEqual(snapshot.spaces.map(\.focused), [true, false])
        XCTAssertEqual(snapshot.spaces.map(\.visible), [true, false])
        // is-minimized and is-floating
        XCTAssertEqual(snapshot.windows.map(\.id), [1001, 1002])
        XCTAssertEqual(snapshot.frames[1002]?.floating, true)
    }

    func testTheBarsLiveOnTheDisplayWhoseOriginIsTheGlobalOrigin() throws {
        let snapshot = try snapshot()
        // display 1 is listed first and numbered first, but it sits to the left: the bars are on display 2
        XCTAssertEqual(snapshot.display, 2)
        XCTAssertEqual(snapshot.spaces.map(\.id), [2, 3])
    }

    func testMinimizedWindowsAndTheOtherDisplayAreNotCounted() throws {
        let snapshot = try snapshot()
        // 1003 is minimized, 1004 sits on space 0, 1005 is on display 1
        XCTAssertEqual(snapshot.windows.map(\.id), [1001, 1002])
        XCTAssertEqual(snapshot.spaces.first { $0.id == 2 }?.windows, 2)
        XCTAssertEqual(snapshot.spaces.first { $0.id == 3 }?.windows, 0)
    }

    func testAWindowCarriesItsAppAndItsTitle() throws {
        let snapshot = try snapshot()
        XCTAssertEqual(snapshot.windows.first,
                       WinInfo(id: 1001, pid: 501, app: "Safari", title: "Start Page", space: 2, focused: true))
        // Terminal reports no title: an empty string, not a dropped window
        XCTAssertEqual(snapshot.windows.last?.title, "")
        XCTAssertEqual(snapshot.windows.last?.focused, false)
    }

    func testTheFocusedWindowRanksFirstAndEveryFrameIsPlaced() throws {
        let snapshot = try snapshot()
        XCTAssertEqual(snapshot.frames[1001],
                       WinFrame(rect: CGRect(x: 0, y: 32, width: 1512, height: 950), placed: true, floating: false, rank: 0))
        XCTAssertEqual(snapshot.frames[1002]?.rank, 99)
    }

    func testOneStreamThatIsNotJSONFailsTheWholeRound() throws {
        // the app prints one "query failed" and publishes nothing, rather than a rail from two of the three streams
        XCTAssertNil(Yabai.parse(displays: try Fixtures.data("yabai-displays.json"),
                                 spaces: Data("yabai: service not running".utf8),
                                 windows: try Fixtures.data("yabai-windows.json")))
    }
}
