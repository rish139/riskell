import XCTest
import RiskellWM

// The settings.toml payloads in fixtures/ are synthetic: a trimmed `[gaps.outer]` section of the shape Gaps.swift rewrites, with the
// comments and neighbouring sections a real file has. None was copied from a user's file. Tests/wm/README.md says how to record one.

final class GapsRewriteTests: XCTestCase {
    func testOnlyTheValuesUnderGapsOuterChange() throws {
        let text = try Fixtures.text("gaps-settings.toml")
        // bottom 32 -> 0 and top 40 -> 32; left and right already hold 36; [gaps.inner]'s left is a different section
        let out = try XCTUnwrap(Gaps.rewrite(text: text, want: Gaps.Outer(left: 36, right: 36, bottom: 0, top: 32)))
        XCTAssertEqual(out, """
        # OmniWM settings. Kept by hand: the comments say why a value is what it is.
        [general]
        defaultLayout = "tiling"
        workspaceSwipeEnabled = false
        scrollEnabled = false

        [gaps]
        smart = true

        [gaps.outer]
        # the room the bars take, in points
        top = 32.0 # the notch bar
        bottom = 0.0 # the bottom bar
        left = 36.0
        right = 36.0

        [gaps.inner]
        left = 6.0
        right = 6.0

        [focus]
        followMouse = false

        """)
    }

    func testNothingChangesWhenEveryValueAlreadyMatches() throws {
        let text = try Fixtures.text("gaps-settings.toml")
        XCTAssertNil(Gaps.rewrite(text: text, want: Gaps.Outer(left: 36, right: 36, bottom: 32, top: 40)))
    }

    func testAMissingGapsOuterSectionLeavesTheTextAlone() throws {
        // no section, nothing to set: riskell must not append one
        let text = try Fixtures.text("gaps-settings-no-outer.toml")
        XCTAssertNil(Gaps.rewrite(text: text, want: Gaps.Outer(left: 36, right: 36, bottom: 0, top: 32)))
    }

    func testCrlfLineEndingsSurviveARewrite() throws {
        let text = try Fixtures.text("gaps-settings-crlf.toml")
        let want = Gaps.Outer(left: 36, right: 36, bottom: 0, top: 40)
        let out = try XCTUnwrap(Gaps.rewrite(text: text, want: want))
        XCTAssertEqual(out, "# OmniWM settings, saved by an editor on Windows\r\n[gaps.outer]\r\ntop = 40.0\r\n"
                       + "bottom = 0.0\r\nleft = 36.0\r\nright = 36.0\r\n")
        // and the values it just wrote read back as equal, so a second apply writes nothing
        XCTAssertNil(Gaps.rewrite(text: out, want: want))
    }

    func testEveryValueIsWrittenWithOneDecimalPlace() throws {
        let text = "[gaps.outer]\nleft = 0.0\nright = 0.0\nbottom = 0.0\ntop = 0.0\n"
        let out = try XCTUnwrap(Gaps.rewrite(text: text, want: Gaps.Outer(left: 36.04, right: 36.06, bottom: 0, top: 39.96)))
        XCTAssertEqual(out, "[gaps.outer]\nleft = 36.0\nright = 36.1\nbottom = 0.0\ntop = 40.0\n")
    }
}
