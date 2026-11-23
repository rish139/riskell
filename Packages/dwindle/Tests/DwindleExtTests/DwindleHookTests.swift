// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import XCTest
import RiskellKit
@testable import DwindleExt

final class DwindleHookTests: XCTestCase {
    /// A workspace holding three tiling windows: 1 and 2 are there, 9 has just arrived.
    private var state = ManagerState(
        windows: [ManagedWindow(id: 1, workspace: "1", floating: false),
                  ManagedWindow(id: 2, workspace: "1", floating: false),
                  ManagedWindow(id: 9, workspace: "1", floating: false)],
        workspaces: [ManagedWorkspace(name: "1", rootLayout: "h_tiles", landscape: true)],
        focusedWindow: 9,
        focusedWorkspace: "1")

    private func dwindle(_ settings: [String: Any] = [:]) -> Dwindle {
        let d = Dwindle()
        _ = d.start(Env(id: "dwindle", prefs: Prefs(json: settings)))
        return d
    }

    func testItIsDwindleAndWorksWithAeroSpaceOnly() {
        XCTAssertEqual(Dwindle.id, "dwindle")
        XCTAssertEqual(Dwindle.manager, "aerospace")
        XCTAssertEqual(DwindlePackage.behaviours.map { $0.id }, ["dwindle"])
    }

    func testItAsksForArrivalsAndTheTidyBinding() {
        let events = Dwindle().events
        XCTAssertEqual(events, ["window-detected", "window-arrived", "binding-triggered"])
    }

    func testAnArrivalGivesTheSameCommandAsADetection() {
        let d = dwindle()
        let detected = d.commands(for: ManagerEvent(name: "window-detected", fields: ["windowId": "9", "workspace": "1"]), in: state)
        let arrived = d.commands(for: ManagerEvent(name: "window-arrived", fields: ["windowId": "9", "workspace": "1"]), in: state)
        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected, arrived)
        XCTAssertEqual(detected.first?.window, 9)
    }

    func testAnArrivalWithoutAWindowIdGivesNothing() {
        XCTAssertEqual(dwindle().commands(for: ManagerEvent(name: "window-arrived", fields: ["workspace": "1"]), in: state), [])
    }

    func testAnEventItDidNotAskForGivesNothing() {
        XCTAssertEqual(dwindle().commands(for: ManagerEvent(name: "focus-changed", fields: ["windowId": "9"]), in: state), [])
    }

    func testTheTidyKeyIsAltShiftTByDefault() {
        let d = dwindle()
        XCTAssertEqual(d.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-shift-t"]), in: state).count, 1)
        XCTAssertEqual(d.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-t"]), in: state), [])
    }

    func testAnotherBindingInTheSettingsIsTheTidyKey() {
        let d = dwindle(["tidyKey": "alt-ctrl-t"])
        XCTAssertEqual(d.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-ctrl-t"]), in: state).count, 1)
        XCTAssertEqual(d.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-shift-t"]), in: state), [])
    }

    func testABindingWithoutAKeyGivesNothing() {
        XCTAssertEqual(dwindle().commands(for: ManagerEvent(name: "binding-triggered", fields: [:]), in: state), [])
    }

    func testNothingHappensBeforeItStarts() {
        // riskell starts a behaviour before it registers it as a hook, so this is only the state it never runs in
        XCTAssertEqual(Dwindle().commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-shift-t"]), in: state), [])
    }

    func testTheKeyIsReadAgainWhenItStartsAgain() {
        let d = dwindle(["tidyKey": "alt-ctrl-t"])
        XCTAssertEqual(d.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-ctrl-t"]), in: state).count, 1)
        _ = d.start(Env(id: "dwindle", prefs: Prefs(json: ["tidyKey": "alt-shift-t"])))
        XCTAssertEqual(d.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-shift-t"]), in: state).count, 1)
        XCTAssertEqual(d.commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-ctrl-t"]), in: state), [])
    }

    func testTheTidyNeedsAFocusedWorkspace() {
        let s = ManagerState(windows: state.windows, workspaces: state.workspaces, focusedWindow: nil, focusedWorkspace: nil)
        XCTAssertEqual(dwindle().commands(for: ManagerEvent(name: "binding-triggered", fields: ["binding": "alt-shift-t"]), in: s), [])
    }
}
