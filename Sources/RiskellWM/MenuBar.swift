import CoreGraphics

/// What riskell reads of the macOS menu bar from the window server's list of windows, as plain values so that the decision can be tested with
/// the numbers a real session printed.
///
/// With the menu bar set to hide itself, its window ("Menubar", layer 24, owned by the window server) is parked above the screen and listed
/// as off screen. Touching the top edge slides it down to y = 0 in about 0.1 s. It stays there for as long as a menu of the menu bar, or the
/// panel of one of its extras (the Control Center), is open, however far the pointer has gone down into that menu, and it slides back up
/// about 50 ms after the menu closes, in about 0.15 s. A menu is a window at the pop-up menu level (layer 101) that starts at or above the
/// bottom of the menu bar and fades to alpha 0 before it goes.
public enum MenuBar {
    public static let menuBarLayer = 24
    public static let popUpMenuLayer = 101

    /// One window of the window server's list, in its coordinates (the origin at the top left of the main display).
    public struct Sample: Equatable {
        public let layer: Int
        public let owner: String
        public let name: String
        public let bounds: CGRect
        public let onScreen: Bool
        public let alpha: Double
        public init(layer: Int, owner: String, name: String, bounds: CGRect, onScreen: Bool, alpha: Double) {
            self.layer = layer; self.owner = owner; self.name = name; self.bounds = bounds; self.onScreen = onScreen; self.alpha = alpha
        }
    }

    private static func isOn(_ r: CGRect, _ display: CGRect) -> Bool { r.maxX > display.minX && r.minX < display.maxX }

    /// The menu bar is on screen, or still sliding away: its window is listed on screen and not yet back above the screen (the last frame of
    /// the slide is on screen at y = -49, a full height up).
    public static func isShown(_ samples: [Sample], on display: CGRect) -> Bool {
        samples.contains {
            $0.layer == menuBarLayer && $0.owner == "Window Server" && $0.name == "Menubar" && $0.onScreen && $0.bounds.maxY > 1
                && isOn($0.bounds, display)
        }
    }

    /// A menu of the menu bar, or the panel of one of its extras, is open: a pop-up menu window that is visible (not in the last frames of its
    /// fade) and starts at or above the bottom of the menu bar's stripe. A pop-up menu further down the screen belongs to something else.
    public static func menuOpen(_ samples: [Sample], on display: CGRect, stripe: CGFloat) -> Bool {
        samples.contains {
            $0.layer == popUpMenuLayer && $0.onScreen && $0.alpha > 0.02 && $0.bounds.minY <= stripe && isOn($0.bounds, display)
        }
    }

    /// Whether the top bar still has to wait, asked once the pointer is below the stripe and the hold-off is over. It waits while a menu is
    /// open, and, once one has been, until the menu bar has gone, so that the bar comes back when the menu bar is no longer there to be under.
    /// When no menu was ever open it does not wait: the pointer leaving the stripe is all it has ever needed. `menuSeen` is carried from one
    /// asking to the next and is false again once the wait is over.
    public static func mustWait(_ samples: [Sample], on display: CGRect, stripe: CGFloat, menuSeen: Bool) -> (wait: Bool, menuSeen: Bool) {
        if menuOpen(samples, on: display, stripe: stripe) { return (true, true) }
        if menuSeen, isShown(samples, on: display) { return (true, true) }
        return (false, false)
    }
}
