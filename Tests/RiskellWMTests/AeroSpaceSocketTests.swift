import XCTest
import RiskellWM

// The two query payloads in fixtures/aerospace-socket-*.json were printed by AeroSpace and then scrubbed (titles, app names, bundle ids,
// pids and window ids replaced; one window made floating). The event and answer lines follow the shape the server sends.

final class AeroSpaceSocketTests: XCTestCase {
    func testTheHandshakeIsTheVersionInFourLittleEndianBytes() {
        XCTAssertEqual(AeroSpace.handshake, Data([1, 0, 0, 0]))
        XCTAssertTrue(AeroSpace.accepts(handshake: Data([1, 0, 0, 0])))
        XCTAssertFalse(AeroSpace.accepts(handshake: Data([2, 0, 0, 0])))
        XCTAssertFalse(AeroSpace.accepts(handshake: Data([1, 0])))
    }

    func testAFrameIsALittleEndianLengthThenThePayload() {
        let f = AeroSpace.frame(Data("hello".utf8))
        XCTAssertEqual(Array(f.prefix(4)), [5, 0, 0, 0])
        XCTAssertEqual(f.dropFirst(4), Data("hello".utf8))
        let big = AeroSpace.frame(Data(repeating: 0x61, count: 0x1_0102))
        XCTAssertEqual(Array(big.prefix(4)), [0x02, 0x01, 0x01, 0x00])
    }

    func testTheRequestCarriesTheArgumentsAndNothingElse() throws {
        let f = AeroSpace.request(["workspace", "3"])
        var r = AeroSpace.FrameReader()
        let body = try XCTUnwrap(r.feed(f).first)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(o["args"] as? [String], ["workspace", "3"])
        XCTAssertEqual(o["stdin"] as? String, "")
        XCTAssertTrue(o["windowId"] is NSNull)
        XCTAssertTrue(o["workspace"] is NSNull)
    }

    func testTheReaderSplitsFramesAndKeepsAPartialOne() {
        let a = AeroSpace.frame(Data("one".utf8)), b = AeroSpace.frame(Data("three".utf8))
        let all = a + b
        var r = AeroSpace.FrameReader()
        XCTAssertEqual(r.feed(all.prefix(2)), [])
        XCTAssertEqual(r.feed(all.dropFirst(2).prefix(a.count - 2 + 5)), [Data("one".utf8)])
        XCTAssertEqual(r.feed(all.dropFirst(a.count + 5)), [Data("three".utf8)])
        XCTAssertEqual(r.feed(a + b), [Data("one".utf8), Data("three".utf8)])
        XCTAssertFalse(r.broken)
    }

    func testALengthBeyondTheLimitBreaksTheReader() {
        var r = AeroSpace.FrameReader()
        XCTAssertEqual(r.feed(Data([0xff, 0xff, 0xff, 0xff])), [])
        XCTAssertTrue(r.broken)
    }

    func testAnAnswerCarriesTheExitCodeAndTheOutput() throws {
        let ok = try XCTUnwrap(AeroSpace.parse(answer: try Fixtures.data("aerospace-socket-answer.json")))
        XCTAssertEqual(ok, AeroSpace.Answer(exitCode: 0, stdout: "[]", stderr: ""))
        let bad = try XCTUnwrap(AeroSpace.parse(answer: try Fixtures.data("aerospace-socket-answer-error.json")))
        XCTAssertEqual(bad.exitCode, 1)
        XCTAssertEqual(bad.stderr, "Unknown command")
        XCTAssertNil(AeroSpace.parse(answer: Data("not json".utf8)))
        XCTAssertNil(AeroSpace.parse(answer: Data(#"{"_event":"focus-changed"}"#.utf8)))
    }

    func testEventsDecodeByName() throws {
        let lines = try Fixtures.text("aerospace-socket-events.jsonl").split(separator: "\n").map { Data($0.utf8) }
        let events = lines.compactMap { AeroSpace.parse(event: $0) }
        XCTAssertEqual(events, [
            .focusedWorkspaceChanged(workspace: "2", previous: "5"),
            .focusChanged(windowId: 1008, workspace: "2"),
            .windowDetected(windowId: 1012, workspace: "2", bundleId: "com.example.terminal", appName: "Terminal"),
            .focusedMonitorChanged,
            .other("mode-changed"),
            .focusChanged(windowId: nil, workspace: nil),
        ])
        XCTAssertNil(AeroSpace.parse(event: Data(#"{"exitCode":0}"#.utf8)))
    }

    private func state() throws -> AeroSpace.State {
        try XCTUnwrap(AeroSpace.parse(workspaceRows: try Fixtures.text("aerospace-socket-workspaces.json"),
                                      windowRows: try Fixtures.text("aerospace-socket-windows.json")))
    }

    func testTheRailComesFromTheNumberedWorkspaces() throws {
        let s = try state()
        XCTAssertEqual(s.spaces.map(\.id), Array(1...6))      // the fixture's windows fill 1 to 5, so the empty sixth follows
        XCTAssertEqual(s.spaces.filter(\.focused).map(\.id), [5])
        XCTAssertEqual(s.spaces.filter(\.visible).map(\.id), [5])
        XCTAssertEqual(s.spaces.first { $0.id == 2 }?.windows, 3)
    }

    private func rows(windowOn: Int?, focused: Int) -> AeroSpace.State? {
        let ws = (1...9).map { #"{"workspace":"\#($0)","workspace-is-focused":\#($0 == focused),"workspace-is-visible":\#($0 == focused)}"# }
        let wins = windowOn.map { #"{"window-id":1,"workspace":"\#($0)"}"# }
        return AeroSpace.parse(workspaceRows: "[" + ws.joined(separator: ",") + "]", windowRows: "[" + (wins ?? "") + "]")
    }

    func testAnEmptyRailStopsAtFive() throws {
        XCTAssertEqual(try XCTUnwrap(rows(windowOn: nil, focused: 1)).spaces.map(\.id), Array(1...5))
    }

    func testAllFiveInUseOffersAnEmptySixth() throws {
        let ws = (1...9).map { #"{"workspace":"\#($0)","workspace-is-focused":\#($0 == 1),"workspace-is-visible":\#($0 == 1)}"# }
        let wins = (1...5).map { #"{"window-id":\#($0),"workspace":"\#($0)"}"# }
        let st = try XCTUnwrap(AeroSpace.parse(workspaceRows: "[" + ws.joined(separator: ",") + "]", windowRows: "[" + wins.joined(separator: ",") + "]"))
        XCTAssertEqual(st.spaces.map(\.id), Array(1...6))
    }

    func testAWindowOnSevenShowsSevenWithoutSix() throws {
        XCTAssertEqual(try XCTUnwrap(rows(windowOn: 7, focused: 1)).spaces.map(\.id), [1, 2, 3, 4, 5, 7])
    }

    func testFocusOnEightShowsEightWithoutSixAndSeven() throws {
        XCTAssertEqual(try XCTUnwrap(rows(windowOn: nil, focused: 8)).spaces.map(\.id), [1, 2, 3, 4, 5, 8])
    }

    func testWindowsKeepTheirFieldsAndNeverCarryFocus() throws {
        let s = try state()
        XCTAssertEqual(s.windows.count, 12)
        XCTAssertEqual(s.windows.first, WinInfo(id: 1000, pid: s.windows[0].pid, app: s.windows[0].app, title: "\(s.windows[0].app) 1", space: 4, focused: false))
        XCTAssertTrue(s.windows.allSatisfy { !$0.focused })
    }

    func testAWindowWhoseParentContainerFloatsIsFloating() throws {
        let s = try state()
        XCTAssertEqual(s.items.filter(\.floating).map(\.id), [1011])
        XCTAssertEqual(s.items.first { $0.id == 1011 }?.space, 2)
    }

    func testAQueryThatIsNotJSONFailsTheWholeRefresh() throws {
        XCTAssertNil(AeroSpace.parse(workspaceRows: "Error", windowRows: try Fixtures.text("aerospace-socket-windows.json")))
    }

    func testTheFocusedWindowQueryAnswersWithAnIdOrNothing() {
        XCTAssertEqual(AeroSpace.parse(focusedWindow: #"[{"window-id":1010}]"#), 1010)
        XCTAssertNil(AeroSpace.parse(focusedWindow: "[]"))
        XCTAssertNil(AeroSpace.parse(focusedWindow: ""))
    }

    func testTheSocketIsNamedAfterTheUser() {
        XCTAssertEqual(AeroSpace.socketPath(user: "someone"), "/tmp/bobko.aerospace-someone.sock")
    }
}
