import AppKit
import RiskellKit

/// The one scale factor. Every SwiftUI view lays out in design units (`G`, `T`, `Pal.font`, plain numbers) and never looks at it. Windows
/// get real points: a design length times `Scale.factor`. On the owner's display the factor is exactly 1, so nothing changes there.
///
/// Auto: the bar's height over the 48 pt the design was made for, where the bar is the notch when the screen has one (48 on the owner's
/// machine, 32 on the stock display mode of the same laptop, never clamped) and the menu bar otherwise (clamped to 0.75...1.5, so a
/// small menu bar on a monitor does not shrink the text to nothing). Override: `"scale"` in config.json, or the environment variable RISKELL_SCALE
/// (which wins; the tests use it). The automatic value follows the display (`Display.current`).
enum Scale {
    /// The override: config `scale` or RISKELL_SCALE (the environment wins; the tests use it). Read once.
    static let override: CGFloat? = {
        if let s = ProcessInfo.processInfo.environment["RISKELL_SCALE"].flatMap(Double.init) ?? AppConfig.shared.scale {
            return CGFloat(min(3, max(0.4, s)))
        }
        return nil
    }()
    /// The factor: the override, else the automatic rule for the display (`Scale.auto(for:)` in Display.swift).
    static var factor: CGFloat { override ?? Display.current.scale }
}

/// Real-point geometry for windows: the design value of each `G` constant times the factor. Use these wherever a number becomes a
/// window frame, a screen position, a gap handed to the window manager or a hit-test rectangle. Views keep using `G` (design units).
enum Real {
    static var k: CGFloat { Scale.factor }
    static var strip: CGFloat { G.strip * k }
    static var r: CGFloat { G.r * k }
    static var band: CGFloat { G.band * k }              // the bars' band, the height of the top and bottom bars (48 on the owner's display)
    static var sideMargin: CGFloat { G.sideMargin * k }
    static var edgeGap: CGFloat { G.edgeGap * k }
    static var cardRadius: CGFloat { G.cardRadius * k }
    static var safeTop: CGFloat { G.safeTop * k }
    static var safeBottom: CGFloat { G.safeBottom * k }
    static var bottomIslandTop: CGFloat { G.bottomIslandTop * k }
    /// OmniWM's outer gaps (Layout.swift): the margin beside a bar that is off, the bottom gap under the bottom bar, the top gap under the notch.
    static var margin: CGFloat { 6 * k }
    static var gapBottom: CGFloat { 50 * k }
    /// Without a notch the top bar sits below the menu bar, so the top gap grows by the menu bar's thickness (Display.topInset).
    static var gapTop: CGFloat { 56 * k + Display.current.topInset }
}

extension CGRect {
    /// The rectangle with every coordinate and length multiplied by `m` (about the screen's origin, so it maps design to real and back).
    func scaled(by m: CGFloat) -> CGRect { CGRect(x: minX * m, y: minY * m, width: width * m, height: height * m) }
}

extension CGSize {
    func times(_ m: CGFloat) -> CGSize { CGSize(width: width * m, height: height * m) }
}

extension NSView {
    /// A view that is `frame` points on screen lays out in design units: its bounds are the frame divided by the factor, so SwiftUI
    /// content sized in `G` fills it. Call again after any change of the frame (a window's setFrame resizes its content view).
    /// At factor 1 it changes nothing.
    func useDesignUnits() {
        let k = Scale.factor
        guard k != 1 else { return }
        setBoundsSize(CGSize(width: frame.width / k, height: frame.height / k))
    }
}
