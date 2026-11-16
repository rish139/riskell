import AppKit
import SwiftUI
import RiskellKit

// The geometry the design was drawn at: strip/pill thickness 38, fillet 11, gap to the screen edge 8, side margin 17.
// These are DESIGN units: every SwiftUI view uses them as they are, and the window layer multiplies them by `Scale.factor` (Scale.swift).
// Any place that turns one of these into a screen position, a window frame, a gap for the window manager or a hit rectangle uses the
// `Real.*` accessor of the same name instead. A factor of 1 (the owner's display) makes the two identical.
extension G {
    static let bottomTuck: CGFloat = 3   // the bottom reservation is 3 px under the band: windows end 8 px above the bottom islands, as they start 8 px below the notch
    static let topShift: CGFloat = 4   // windows start 56 px down (OmniWM's outer top gap, see docs/COMPATIBILITY.md): centre the top islands in 0..56, not 0..48
    static let leftExtra: CGFloat = 1  // extra gap between the strip and tiled windows, on top of the user's own left_padding: strip-to-window = right screen-edge gap (right_padding + rightExtra)
    static let rightExtra: CGFloat = 1
    /// Bar to screen edge: `spacing.edgeGap` (Spacing.swift), 8 by default.
    static var edgeGap: CGFloat { Spacing.current.edge }
    static let sideMargin: CGFloat = 17
    static let islandGap: CGFloat = 8
    static let band: CGFloat = 48            // the bars' band (the notch's height)
    /// A strip's card (with its coves) stays inside the rectangle between the top and bottom bars: clear of their bands and of the fillets
    /// that join them to the strip. A bar that is off no longer holds anything back.
    static var safeTop: CGFloat { band + r + 2 }
    static var safeBottom: CGFloat { bottomIslandTop + r + 2 }
    static let topIslandBottom: CGFloat = band / 2 + topShift + pill / 2   // from the screen's top edge
    static let bottomIslandTop: CGFloat = band / 2 + pill / 2              // from the screen's bottom edge
}

/// One concave fillet in the r×r square `rect`; `corner` is the square's solid corner (0 TL, 1 TR, 2 BL, 3 BR, y down).
func ear(_ rect: CGRect, corner: Int) {
    let flipX = corner == 1 || corner == 3, flipY = corner == 2 || corner == 3, r = rect.width      // a square: its side is the fillet's radius
    func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
        CGPoint(x: flipX ? rect.maxX - u * r : rect.minX + u * r, y: flipY ? rect.maxY - v * r : rect.minY + v * r)
    }
    let k: CGFloat = 0.5522847498
    let p = NSBezierPath()
    p.move(to: pt(0, 0))
    p.line(to: pt(1, 0))
    p.curve(to: pt(0, 1), controlPoint1: pt(1 - k, 0), controlPoint2: pt(0, 1 - k))
    p.close()
    Pal.surfaceSolid.setFill(); p.fill()
}

/// A hug strip: flush to the screen edge, corner to corner, with a fillet at each end where it meets the top and bottom edge.
/// Pieces overlap by 1 px in one opaque colour so the fractional output scale leaves no hairline. The left strip's panel is the strip plus
/// `Real.r` of room for the fillets on its right; the right strip's panel is the mirror image (the strip is its right part).
/// It is a plain window view (real points), so it draws with `Real`, not `G`.
final class HugStrip: NSView {
    override var isFlipped: Bool { true }
    /// The fill is its own layer-backed view so it can fade: floating, the strip is empty until a card opens (then it fills in, so the card is welded to it).
    private final class Fill: NSView {
        let right: Bool
        init(right: Bool) {
            self.right = right; super.init(frame: .zero)
            NotificationCenter.default.addObserver(forName: ThemeState.didChange, object: nil, queue: .main) { [weak self] _ in self?.needsDisplay = true }
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func draw(_ dirty: NSRect) {
            Pal.surfaceSolid.setFill()
            let rr = Real.r, st = Real.strip
            if right {
                CGRect(x: rr, y: 0, width: st, height: bounds.height).fill()
                ear(CGRect(x: 1, y: 0, width: rr, height: rr), corner: 1)
                ear(CGRect(x: 1, y: bounds.height - rr, width: rr, height: rr), corner: 3)
            } else {
                CGRect(x: 0, y: 0, width: st, height: bounds.height).fill()
                ear(CGRect(x: st - 1, y: 0, width: rr, height: rr), corner: 0)
                ear(CGRect(x: st - 1, y: bounds.height - rr, width: rr, height: rr), corner: 2)
            }
        }
    }
    private let fill: Fill
    var hug = true { didSet { if hug != oldValue { NSAnimationContext.runAnimationGroup { $0.duration = 0.18; fill.animator().alphaValue = hug ? 1 : 0 } } } }
    init(right: Bool = false) {
        fill = Fill(right: right)
        super.init(frame: .zero)
        fill.wantsLayer = true; addSubview(fill)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); fill.frame = CGRect(origin: .zero, size: s) }
}

/// The island's swell on a strip, while the layout is being edited (the horizontal bars' `Pill` always has it; a strip's atoms carry their own
/// hover effects at rest, but in edit mode they are inert, so the island itself must answer the pointer).
struct EditSwell: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { if on { content.modifier(Swell()) } else { content } }
}

/// Hover contract of every atom: a spring swell about the centre, nothing moves in the layout.
struct Swell: ViewModifier {
    @State private var hot = false
    func body(content: Content) -> some View {
        content.scaleEffect(hot ? 1.06 : 1)
            .animation(.interpolatingSpring(stiffness: 260, damping: 14), value: hot)
            .onHover { hot = $0 }
    }
}

struct Pill<Content: View>: View {
    var lit = false          // the bar is filled in: the island dissolves into it (no body, no border)
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: T.gap) { content }
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(Pal.text1)
            .padding(.horizontal, 14).frame(height: G.pill)
            .background(RoundedRectangle(cornerRadius: G.radius).fill(lit ? Color.clear : Pal.surface))
            .overlay(RoundedRectangle(cornerRadius: G.radius).stroke(lit ? Color.clear : Pal.hairline, lineWidth: 1))
            .animation(.easeOut(duration: 0.18), value: lit)
            .modifier(Swell())
    }
}

/// The concave fillet of `ear()` as a SwiftUI shape: fills the corner `corner` (0 TL, 1 TR, 2 BL, 3 BR) of its square, bounded by a quarter arc.
struct EarShape: Shape {
    let corner: Int
    func path(in rect: CGRect) -> Path {
        let flipX = corner == 1 || corner == 3, flipY = corner == 2 || corner == 3
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: flipX ? rect.maxX - u * rect.width : rect.minX + u * rect.width, y: flipY ? rect.maxY - v * rect.height : rect.minY + v * rect.height)
        }
        let k: CGFloat = 0.5522847498
        var p = Path()
        p.move(to: pt(0, 0)); p.addLine(to: pt(1, 0))
        p.addCurve(to: pt(0, 1), control1: pt(1 - k, 0), control2: pt(0, 1 - k))
        p.closeSubpath()
        return p
    }
}

/// The bar's highlight band: solid across the whole bar while one of its widgets is lit, so a card can hang from it as one surface.
/// On the top bar it spreads out from the notch; at its ends it joins the hug strip with a fillet.
struct LitBand: View {
    let edge: PopEdge          // .below: a top bar (band at the top of the panel); .above: a bottom bar
    let bandH: CGFloat
    let notch: (l: CGFloat, r: CGFloat)?
    let lit: Bool
    var joinL = true, joinR = false          // a strip stands at that end of the bar: a fillet joins the band to it
    var body: some View {
        let top = edge == .below
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: top ? .topLeading : .bottomLeading) {
                BandShape(l: notch?.l ?? w / 2, r: notch?.r ?? w / 2, w: w, spread: top && notch != nil ? (lit ? 1 : 0) : 1)
                    .fill(Pal.cardSolid).frame(height: bandH)
                if joinL {
                    EarShape(corner: top ? 0 : 2).fill(Pal.cardSolid).frame(width: G.r, height: G.r)
                        .offset(x: -1, y: top ? bandH - 1 : 1 - bandH)
                }
                if joinR {
                    EarShape(corner: top ? 1 : 3).fill(Pal.cardSolid).frame(width: G.r, height: G.r)
                        .offset(x: w - G.r + 1, y: top ? bandH - 1 : 1 - bandH)
                }
            }
            .frame(width: w, height: g.size.height, alignment: top ? .topLeading : .bottomLeading)
            .opacity(lit ? 1 : 0)
            .animation(.spring(duration: 0.30, bounce: 0.05), value: lit)
        }
        .allowsHitTesting(false)
    }
}

private struct BandShape: Shape {
    var l: CGFloat, r: CGFloat, w: CGFloat, spread: CGFloat
    var animatableData: CGFloat { get { spread } set { spread = newValue } }
    func path(in rect: CGRect) -> Path {
        let a = l - (l + 1) * spread, b = r + (w - r) * spread
        return Path(CGRect(x: a, y: 0, width: b - a, height: rect.height))
    }
}
