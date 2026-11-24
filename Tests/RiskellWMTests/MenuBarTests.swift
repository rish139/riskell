import CoreGraphics
import XCTest
@testable import RiskellWM

/// The numbers are the ones a recording of a real session printed (the window server's list, every 40 ms, while the File menu, the Control
/// Center and the Apple menu were opened and closed with the menu bar set to hide itself; the display is 2268 x 1473 and its stripe 49 points).
final class MenuBarTests: XCTestCase {
    let display = CGRect(x: 0, y: 0, width: 2268, height: 1473)
    let stripe: CGFloat = 49

    func bar(y: CGFloat, onScreen: Bool = true) -> MenuBar.Sample {
        MenuBar.Sample(layer: 24, owner: "Window Server", name: "Menubar", bounds: CGRect(x: 0, y: y, width: 2268, height: 49), onScreen: onScreen, alpha: 1)
    }
    func menu(_ owner: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, alpha: Double = 1) -> MenuBar.Sample {
        MenuBar.Sample(layer: 101, owner: owner, name: owner, bounds: CGRect(x: x, y: y, width: w, height: h), onScreen: true, alpha: alpha)
    }

    // MARK: the menu bar itself

    func testTheMenuBarParkedAboveTheScreenIsNotShown() {
        XCTAssertFalse(MenuBar.isShown([bar(y: -49, onScreen: false)], on: display))
        XCTAssertFalse(MenuBar.isShown([], on: display), "the window server does not list it at all while it is off screen")
    }

    func testTheMenuBarIsShownThroughoutItsSlide() {
        for y in [CGFloat(0), -3, -10, -22, -31, -38, -45] {          // y values from the slides in and out of the recording
            XCTAssertTrue(MenuBar.isShown([bar(y: y)], on: display), "y \(y)")
        }
        // the last frame of the slide out is on screen a full height up: that is gone
        XCTAssertFalse(MenuBar.isShown([bar(y: -49)], on: display))
    }

    func testOnlyTheWindowServersMenubarWindowCounts() {
        // the layer-25 window that eats hover is not the menu bar, and neither is another app's window at layer 24
        let agent = MenuBar.Sample(layer: 25, owner: "MenuBarAgent", name: "", bounds: CGRect(x: 0, y: 0, width: 2268, height: 49), onScreen: true, alpha: 1)
        let other = MenuBar.Sample(layer: 24, owner: "SomeApp", name: "Menubar", bounds: CGRect(x: 0, y: 0, width: 2268, height: 49), onScreen: true, alpha: 1)
        XCTAssertFalse(MenuBar.isShown([agent, other], on: display))
    }

    func testAMenuBarOnAnotherDisplayIsNotThisOnes() {
        let away = MenuBar.Sample(layer: 24, owner: "Window Server", name: "Menubar", bounds: CGRect(x: 2268, y: 0, width: 1920, height: 49), onScreen: true, alpha: 1)
        XCTAssertFalse(MenuBar.isShown([away], on: display))
    }

    // MARK: menus

    func testTheFileMenuAndTheControlCenterAreMenus() {
        XCTAssertTrue(MenuBar.menuOpen([menu("Ghostty", x: 34, y: -25, w: 371, h: 422)], on: display, stripe: stripe))
        XCTAssertTrue(MenuBar.menuOpen([menu("Ghostty", x: 168, y: -25, w: 584, h: 837)], on: display, stripe: stripe), "a submenu opening")
        XCTAssertTrue(MenuBar.menuOpen([menu("Control Center", x: 1788, y: 0, w: 656, h: 983)], on: display, stripe: stripe))
        XCTAssertTrue(MenuBar.menuOpen([menu("Search", x: -70, y: -25, w: 447, h: 455)], on: display, stripe: stripe), "the Apple menu")
    }

    func testAMenuInTheLastFramesOfItsFadeIsClosed() {
        // alpha 0.75, 0.26, 0.08, 0.01 and 0.00 were listed in the 0.3 s it took to close
        XCTAssertTrue(MenuBar.menuOpen([menu("Ghostty", x: 168, y: -25, w: 584, h: 837, alpha: 0.75)], on: display, stripe: stripe))
        XCTAssertFalse(MenuBar.menuOpen([menu("Ghostty", x: 168, y: -25, w: 584, h: 837, alpha: 0.01)], on: display, stripe: stripe))
        XCTAssertFalse(MenuBar.menuOpen([menu("Ghostty", x: 168, y: -25, w: 584, h: 837, alpha: 0)], on: display, stripe: stripe))
    }

    func testAPopUpFurtherDownTheScreenIsNotAMenuOfTheMenuBar() {
        XCTAssertFalse(MenuBar.menuOpen([menu("Safari", x: 600, y: 400, w: 200, h: 300)], on: display, stripe: stripe))
    }

    func testAnInvisibleMenuWindowIsNotAMenu() {
        // the recording lists a second, off-screen window with every menu
        let ghost = MenuBar.Sample(layer: 101, owner: "Ghostty", name: "Ghostty", bounds: CGRect(x: 109, y: 50, width: 221, height: 272), onScreen: false, alpha: 1)
        XCTAssertFalse(MenuBar.menuOpen([ghost], on: display, stripe: stripe))
    }

    // MARK: the wait

    func testNoMenuNeverMeansANewWait() {
        // the pointer touched the edge and left again: the menu bar slides away by itself, and the top bar does not wait for it, as before
        let r = MenuBar.mustWait([bar(y: 0)], on: display, stripe: stripe, menuSeen: false)
        XCTAssertFalse(r.wait)
        XCTAssertFalse(r.menuSeen)
    }

    func testTheTopBarWaitsWhileAMenuIsOpenAndUntilTheMenuBarHasGone() {
        var seen = false
        // 1. the File menu is open and the pointer is far down in it
        var r = MenuBar.mustWait([bar(y: 0), menu("Ghostty", x: 34, y: -25, w: 371, h: 422)], on: display, stripe: stripe, menuSeen: seen)
        XCTAssertTrue(r.wait); seen = r.menuSeen; XCTAssertTrue(seen)
        // 2. the menu has closed and the menu bar has not started to slide yet (50 ms)
        r = MenuBar.mustWait([bar(y: 0)], on: display, stripe: stripe, menuSeen: seen)
        XCTAssertTrue(r.wait); seen = r.menuSeen
        // 3. sliding away
        for y in [CGFloat(-15), -31] {
            r = MenuBar.mustWait([bar(y: y)], on: display, stripe: stripe, menuSeen: seen)
            XCTAssertTrue(r.wait, "y \(y)"); seen = r.menuSeen
        }
        // 4. gone: the top bar returns, and the next time starts clean
        r = MenuBar.mustWait([bar(y: -49)], on: display, stripe: stripe, menuSeen: seen)
        XCTAssertFalse(r.wait)
        XCTAssertFalse(r.menuSeen)
    }

    func testAMenuOpenedAgainDuringTheSlideWaitsAgain() {
        let r = MenuBar.mustWait([bar(y: -10), menu("Search", x: -70, y: -25, w: 447, h: 455)], on: display, stripe: stripe, menuSeen: true)
        XCTAssertTrue(r.wait)
    }
}
