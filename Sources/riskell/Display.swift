import AppKit
import RiskellKit

/// The screen the bars are laid out on. Every piece of bar geometry reads `Display.current` (never `NSScreen.main`), so a fake display
/// (RISKELL_FAKE_DISPLAY) lays everything out against another size. All values are real points, Cocoa coordinates.
///
/// Which screen: config `display` ("auto" by default = the screen with a notch if any, else the main screen; "main"; "primary" = the first
/// screen in the list). Fake, for tests: RISKELL_FAKE_DISPLAY="WIDTHxHEIGHT:notch=H,W" (notch height and width in real points, centred) or
/// "WIDTHxHEIGHT:menubar=H" (no notch), built at the real screen's origin.
struct Display {
    /// The screen's frame (real points, Cocoa coordinates).
    var frame: CGRect
    /// The notch's height in real points; 0 when the screen has no notch.
    var notchH: CGFloat
    /// The notch's left and right edges as absolute screen x (real points); nil when there is no notch.
    var notchEdges: (l: CGFloat, r: CGFloat)?
    /// The menu bar's thickness in real points.
    var menuBar: CGFloat

    /// The layout scale (Scale.swift's rule): notch / 48 with a notch, menu bar / 48 clamped without one.
    var scale: CGFloat { Scale.auto(for: self) }

    /// The top bar's centre gap (absolute screen x, real points): the notch's edges, or on a screen without one a stand-in the width of the
    /// owner's notch (278 design units), centred.
    var barNotch: (l: CGFloat, r: CGFloat) {
        if let e = notchEdges { return e }
        let half = 278 * Scale.factor / 2
        return (l: frame.midX - half, r: frame.midX + half)
    }

    /// How far the top bar sits below the screen's top: the menu bar's thickness without a notch (the bar must not cover the menu bar), 0 with one.
    var topInset: CGFloat { notchH > 0 ? 0 : menuBar }

    /// The display the bars use. Read once; `Display.refresh()` rebuilds it when the screens change.
    static var current: Display = read()

    /// Rebuilds `current` from the screens (or the fake). Called at launch and, later, on a screen change.
    @discardableResult
    static func refresh() -> Display { current = read(); return current }

    private static func read() -> Display {
        if let fake = ProcessInfo.processInfo.environment["RISKELL_FAKE_DISPLAY"].flatMap(parseFake) { return fake }
        guard let screen = chosenScreen() else {
            return Display(frame: .zero, notchH: 0, notchEdges: nil, menuBar: 24)      // no screen at all (should not happen)
        }
        let top = screen.safeAreaInsets.top
        let edges: (l: CGFloat, r: CGFloat)? = {
            guard let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else { return nil }
            return (l.maxX, r.minX)
        }()
        return Display(frame: screen.frame, notchH: max(0, top), notchEdges: edges, menuBar: NSStatusBar.system.thickness)
    }

    /// The real screen the bars go on, by the config key `display`.
    static func chosenScreen() -> NSScreen? {
        switch AppConfig.shared.display ?? "auto" {
        case "main": return NSScreen.main ?? NSScreen.screens.first
        case "primary": return NSScreen.screens.first
        default: return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        }
    }

    /// "1512x982:notch=32,185" or "1920x1080:menubar=24", at the real screen's origin.
    static func parseFake(_ spec: String) -> Display? {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let size = parts.first?.split(separator: "x").compactMap { Double($0) } ?? []
        guard size.count == 2 else { return nil }
        let origin = (NSScreen.screens.first ?? NSScreen.main)?.frame.origin ?? .zero
        let frame = CGRect(origin: origin, size: CGSize(width: size[0], height: size[1]))
        let menuBar = NSStatusBar.system.thickness
        guard parts.count == 2 else { return Display(frame: frame, notchH: 0, notchEdges: nil, menuBar: menuBar) }
        let kv = parts[1].split(separator: "=", maxSplits: 1).map(String.init)
        if kv.first == "notch", kv.count == 2 {
            let hw = kv[1].split(separator: ",").compactMap { Double($0) }
            guard hw.count == 2 else { return nil }
            let h = CGFloat(hw[0]), w = CGFloat(hw[1])
            return Display(frame: frame, notchH: h, notchEdges: (l: frame.midX - w / 2, r: frame.midX + w / 2), menuBar: menuBar)
        }
        if kv.first == "menubar", kv.count == 2, let m = Double(kv[1]) {
            return Display(frame: frame, notchH: 0, notchEdges: nil, menuBar: CGFloat(m))
        }
        return Display(frame: frame, notchH: 0, notchEdges: nil, menuBar: menuBar)
    }
}

/// The automatic scale is a pure function of the display (Scale.factor reads it through `Display.current`).
extension Scale {
    /// The bar's height over the 48 pt the design was made for. With a notch the band IS the notch (notch / 48, clamped 0.5...2 as before);
    /// without one, the menu bar sets it (clamped to 0.75...1.5, so a small menu bar does not shrink the text to nothing).
    static func auto(for d: Display) -> CGFloat {
        if d.notchH > 0 { return min(2, max(0.5, d.notchH / 48)) }
        return min(1.5, max(0.75, d.menuBar / 48))
    }
}
