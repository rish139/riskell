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

    func testARequestCanNameTheWindowItActsOn() throws {
        let f = AeroSpace.request(["eval", "join-with left"], window: 26049)
        var r = AeroSpace.FrameReader()
        let body = try XCTUnwrap(r.feed(f).first)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(o["windowId"] as? Int, 26049)
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
            .bindingTriggered(mode: "main", binding: "alt-h"),
        ])
        XCTAssertNil(AeroSpace.parse(event: Data(#"{"exitCode":0}"#.utf8)))
    }

    func testAnEventReachesAHookWithItsOwnFieldsAsText() throws {
        let fields = try XCTUnwrap(AeroSpace.parse(eventFields: Data(
            #"{"_event":"window-detected","windowId":1012,"workspace":"2","appBundleId":"com.example.terminal","appName":"Terminal"}"#.utf8)))
        XCTAssertEqual(fields.name, "window-detected")
        XCTAssertEqual(fields.fields, ["windowId": "1012", "workspace": "2", "appBundleId": "com.example.terminal", "appName": "Terminal"])
        // the reply that opens the stream, and a frame that is not an event, name nothing
        XCTAssertNil(AeroSpace.parse(eventFields: Data(#"{"exitCode":0}"#.utf8)))
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

    func testAWindowOnSevenShowsEveryWorkspaceUpToSeven() throws {
        let st = try XCTUnwrap(rows(windowOn: 7, focused: 1))
        XCTAssertEqual(st.spaces.map(\.id), Array(1...7))
        XCTAssertEqual(st.spaces.map(\.windows), [0, 0, 0, 0, 0, 0, 1])      // six is a dim bead between, not a gap
    }

    func testFocusOnEightShowsEveryWorkspaceUpToEight() throws {
        XCTAssertEqual(try XCTUnwrap(rows(windowOn: nil, focused: 8)).spaces.map(\.id), Array(1...8))
    }

    func testTheCapsuleGoesOneBeadAtATimeThroughEmptyWorkspaces() throws {
        // the capsule sits on the focused bead: through the empty workspaces 5 to 9 it must step by one, and the rail may only grow at its end
        var previous = 0
        for focused in 1...9 {
            let st = try XCTUnwrap(rows(windowOn: nil, focused: focused))
            XCTAssertEqual(st.spaces.map(\.id), Array(1...max(5, focused)), "focus on \(focused)")
            XCTAssertEqual(st.spaces.firstIndex { $0.focused }, focused - 1, "focus on \(focused)")
            XCTAssertGreaterThanOrEqual(st.spaces.count, previous - 4)
            previous = st.spaces.count
        }
    }

    func testTheNextWorkspaceIsOfferedOnlyWhenEveryOneOnTheRailIsInUse() throws {
        // windows on 1 to 7 and nothing else: the rail ends at an empty eighth; with a gap at four it does not
        func rail(_ spaces: [Int]) throws -> [Int] {
            let ws = (1...9).map { #"{"workspace":"\#($0)","workspace-is-focused":\#($0 == 1),"workspace-is-visible":\#($0 == 1)}"# }
            let wins = spaces.enumerated().map { #"{"window-id":\#($0.offset + 1),"workspace":"\#($0.element)"}"# }
            return try XCTUnwrap(AeroSpace.parse(workspaceRows: "[" + ws.joined(separator: ",") + "]",
                                                 windowRows: "[" + wins.joined(separator: ",") + "]")).spaces.map(\.id)
        }
        XCTAssertEqual(try rail(Array(1...7)), Array(1...8))
        XCTAssertEqual(try rail([1, 2, 3, 5, 6, 7]), Array(1...7))
        XCTAssertEqual(try rail(Array(1...9)), Array(1...9))
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
    // MARK: one request per refresh

    func testAnArgumentIsBareUnlessTheLexerWouldReadItAsSomethingElse() {
        XCTAssertEqual(AeroSpace.quoted("list-windows"), "list-windows")
        XCTAssertEqual(AeroSpace.quoted("%{workspace}%{monitor-id}"), "%{workspace}%{monitor-id}")
        XCTAssertEqual(AeroSpace.quoted("2"), "2")
        // whitespace, the reserved characters, and `;`, which ends a command
        XCTAssertEqual(AeroSpace.quoted("a b"), "'a b'")
        XCTAssertEqual(AeroSpace.quoted(""), "''")
        XCTAssertEqual(AeroSpace.quoted("a;b"), "'a;b'")
        XCTAssertEqual(AeroSpace.quoted("a#b"), "'a#b'")
        XCTAssertEqual(AeroSpace.quoted("a$b"), "'a$b'")
        XCTAssertEqual(AeroSpace.quoted("a|b"), "'a|b'")
        XCTAssertEqual(AeroSpace.quoted("it's"), "\"it's\"")            // a single quote goes inside double quotes
        XCTAssertEqual(AeroSpace.quoted("say \"hi\""), "'say \"hi\"'")  // and a double quote inside single ones
    }

    func testOneEvalCarriesTheCommandsAndTheQueriesInOrder() {
        XCTAssertEqual(AeroSpace.evalArgs([AeroSpace.workspaceQuery, AeroSpace.windowQuery]),
                       ["eval", AeroSpace.workspaceQuery.map(AeroSpace.quoted).joined(separator: " ") + "; "
                           + AeroSpace.windowQuery.map(AeroSpace.quoted).joined(separator: " ")])
        XCTAssertEqual(AeroSpace.evalArgs([["workspace", "3"], ["list-workspaces", "--focused"]]), ["eval", "workspace 3; list-workspaces --focused"])
    }

    func testAHookScriptGoesInAsItIsAndTheQueriesStayLast() {
        // a script is already AeroSpace's own language: quoting it would make it one bare word
        XCTAssertEqual(AeroSpace.evalArgs([], scripts: ["test x = h_tiles && join-with left"], queries: [["list-workspaces"]]),
                       ["eval", "test x = h_tiles && join-with left; list-workspaces"])
        XCTAssertEqual(AeroSpace.evalArgs([["move-node-to-workspace", "1", "2"]], scripts: ["join-with up"], queries: [["list-windows", "--all"]]),
                       ["eval", "move-node-to-workspace 1 2; join-with up; list-windows --all"])
    }

    func testAMonitorAeroSpaceCannotNameReadsAsNone() throws {
        // AeroSpace prints "NULL-MONITOR-ID" as a string when a workspace's monitor is not among the screens (a display just went away):
        // the rest of the answer is still good
        let ws = #"[{"workspace":"1","monitor-id":"NULL-MONITOR-ID","workspace-root-container-layout":"h_tiles"}]"#
        let wins = #"[{"window-id":10,"workspace":"1","monitor-id":"NULL-MONITOR-ID"}]"#
        let refresh = try XCTUnwrap(AeroSpace.parse(refresh: ws + "\n" + wins, seed: false))
        XCTAssertNil(refresh.rows.workspaces[0].monitor)
        XCTAssertNil(refresh.rows.windows[0].monitor)
        XCTAssertEqual(refresh.rows.workspaces[0].rootLayout, "h_tiles")
        XCTAssertEqual(refresh.rows.windows[0].windowId, 10)
    }

    func testAWorkspaceCarriesTheLayoutOfItsTopContainer() throws {
        let refresh = try XCTUnwrap(AeroSpace.parse(
            refresh: #"[{"workspace":"1","monitor-id":1,"workspace-root-container-layout":"v_tiles"}]"# + "\n[]", seed: false))
        XCTAssertEqual(refresh.rows.workspaces, [AeroSpace.WorkspaceRow(workspace: "1", monitor: 1, rootLayout: "v_tiles")])
        // a version that does not print the field leaves it unknown, and nothing else changes
        let older = try XCTUnwrap(AeroSpace.parse(refresh: #"[{"workspace":"1"}]"# + "\n[]", seed: false))
        XCTAssertNil(older.rows.workspaces[0].rootLayout)
    }
    func testTheAnswersOfAnEvalAreFoundInItsOutputOneAfterAnother() {
        XCTAssertEqual(AeroSpace.jsonValues("[]\n[]"), ["[]", "[]"])
        XCTAssertEqual(AeroSpace.jsonValues(""), [])
        XCTAssertEqual(AeroSpace.jsonValues("no answer"), [])
        // a bracket inside a title is part of the value, and the value after it is still found
        XCTAssertEqual(AeroSpace.jsonValues("[{\"t\":\"a ] \\\" [ b\"},[1]]"), ["[{\"t\":\"a ] \\\" [ b\"},[1]]"])
        // a command's own plain output is skipped up to the next value
        XCTAssertEqual(AeroSpace.jsonValues("some text\n{\"main\":{}}\n[]"), ["{\"main\":{}}", "[]"])
        // an answer the socket cut short is dropped, and nothing after it is read as a value
        XCTAssertEqual(AeroSpace.jsonValues("[{\"a\":1},[]"), [])
    }

    func testARefreshIsParsedFromTheLastTwoAnswers() throws {
        let ws = #"[{"workspace":"1","workspace-is-focused":true,"workspace-is-visible":true,"monitor-id":1}]"#
        let wins = #"[{"window-id":10,"workspace":"1","workspace-is-focused":true,"workspace-is-visible":true}]"#
        let refresh = try XCTUnwrap(AeroSpace.parse(refresh: ws + "\n" + wins, seed: false))
        XCTAssertEqual(refresh.rows, AeroSpace.Rows(workspaces: [AeroSpace.WorkspaceRow(workspace: "1", focused: true, visible: true, monitor: 1)],
                                                    windows: [AeroSpace.WindowRow(windowId: 10, workspace: "1", workspaceFocused: true,
                                                                                  workspaceVisible: true)]))
        XCTAssertNil(refresh.focusedWindow)
        XCTAssertNil(refresh.bindings)
        // the answer of a command that ran first does not hide them
        XCTAssertEqual(AeroSpace.parse(refresh: "[{\"window-id\":3}]\n" + ws + "\n" + wins, seed: false)?.rows, refresh.rows)
        XCTAssertNil(AeroSpace.parse(refresh: ws, seed: false))
        XCTAssertNil(AeroSpace.parse(refresh: "not json", seed: false))
    }

    func testTheFirstRefreshOfAConnectionAlsoReadsTheFocusAndTheBindings() throws {
        let config = #"{"main":{"binding":{"alt-h":"focus --direction left"}}}"#
        let refresh = try XCTUnwrap(AeroSpace.parse(refresh: config + "\n[{\"window-id\":10}]\n[]\n[]", seed: true))
        XCTAssertEqual(refresh.focusedWindow, 10)
        XCTAssertEqual(refresh.bindings, ["main": ["alt-h": "focus --direction left"]])
        // a seed whose own asks went unanswered still has its rows, and only those
        let bare = try XCTUnwrap(AeroSpace.parse(refresh: "[{\"window-id\":10}]\n[]\n[]", seed: true))
        XCTAssertEqual(bare.focusedWindow, 10)
        XCTAssertNil(bare.bindings)
        XCTAssertEqual(bare.rows, AeroSpace.Rows(workspaces: [], windows: []))
    }

    func testTheBindingTableIsModeThenNotationThenItsCommands() {
        XCTAssertEqual(AeroSpace.parse(bindings: #"{"main":{"binding":{"alt-h":"focus left"}},"resize":{"binding":{"h":"resize smart +50"}}}"#),
                       ["main": ["alt-h": "focus left"], "resize": ["h": "resize smart +50"]])
        // a mode with no bindings at all is an empty table, not a failure
        XCTAssertEqual(AeroSpace.parse(bindings: #"{"main":{}}"#), ["main": [:]])
        XCTAssertNil(AeroSpace.parse(bindings: "not json"))
    }
}
