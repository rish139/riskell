import SwiftUI
import RiskellKit

/// The chat style of card (a bar's `spill` set to chat, see Layout.swift): a fully rounded card joined to the widget's island by a short
/// neck. Pill, neck and card read as one silhouette: the neck is as wide as the pill's straight bottom edge allows, and each of its ends
/// flares out in a concave fillet, into the pill's underside at the top and into the card's edge at the bottom. The bar around it does not fill in.
/// The silhouette is drawn once, in the popout panel, in "below" orientation (x along the bar, y away from it); the other three sides are
/// the same drawing flipped or transposed (`ChatShape.transform`).
enum ChatCard {
    static let neck: CGFloat = 18          // from the pill to the card (every chat card, one look)
    static let flare: CGFloat = 5          // radius of the concave fillets at both ends of the neck
    static let overlap: CGFloat = 2        // how far the panel reaches back into the pill, to hide the pill's hairline across the join
    static let lean: CGFloat = 0.94        // the card grows from this scale, about the side facing the bar
    static let level = 4                   // above the bars' own panels (the top bar sits 3 above the base level)

    static func horizontal(_ e: PopEdge) -> Bool { e == .below || e == .above }

    /// A card on the top or bottom bar: where it sits along the bar and which stretch of the island's edge the neck uses, all in one axis
    /// (increasing along the bar). The card goes where it is wanted, inside `bounds`; the neck is the part of the island's straight edge (less
    /// the pill's corners and the flare) that faces the card's straight edge (less its corners and the flare). If that is shorter than a minimum,
    /// the card moves toward the island just far enough, even out of `bounds`.
    static func fit(island: ClosedRange<CGFloat>, length: CGFloat, want: CGFloat, bounds: ClosedRange<CGFloat>)
        -> (start: CGFloat, neck: ClosedRange<CGFloat>) {
        let R = G.cardRadius, fl = flare, minNeck: CGFloat = 14
        var lo = island.lowerBound + G.radius + fl, hi = island.upperBound - G.radius - fl
        if hi - lo < minNeck { let m = (island.lowerBound + island.upperBound) / 2; lo = m - minNeck / 2; hi = m + minNeck / 2 }
        var c0 = min(max(want, bounds.lowerBound), max(bounds.lowerBound, bounds.upperBound - length))
        let lowest = lo + minNeck - length + R + fl, highest = hi - minNeck - R - fl         // the card starts that keep at least minNeck of neck
        c0 = lowest <= highest ? min(max(c0, lowest), highest) : (lowest + highest) / 2
        let a = max(lo, c0 + R + fl), b = min(hi, c0 + length - R - fl)
        return (c0, min(a, b)...max(a, b))
    }

    /// A card on a strip (axis measured down from the screen's top, as the shape draws it). The island stays where it is when it can. The card
    /// hangs from the island top-aligned or bottom-aligned, whichever needs the smaller push to fit `bounds`, and is pushed inside them. Only when
    /// the card and island overlap by less than the neck and its fillets (`neck + 2 * cardRadius`) does the island move: by the least that makes
    /// the overlap enough, and never out of `bounds`. The neck joins the island at the middle of the overlap. `shift` is how far the island moved.
    static func stripFit(island raw: ClosedRange<CGFloat>, length: CGFloat, bounds: ClosedRange<CGFloat>)
        -> (start: CGFloat, neck: ClosedRange<CGFloat>, shift: CGFloat) {
        let R = G.cardRadius, k = R + flare, minNeck: CGFloat = 14, need = neck + 2 * R
        let lo = bounds.lowerBound, hi = bounds.upperBound
        // The island first floats inward, by the least that puts it inside the margins (the same bounds the card keeps to); it never
        // travels to centre on its card.
        var inward: CGFloat = 0
        if raw.upperBound > hi { inward = hi - raw.upperBound }
        if raw.lowerBound + inward < lo { inward = lo - raw.lowerBound }
        let island = (raw.lowerBound + inward)...(raw.upperBound + inward)
        func inBounds(_ s: CGFloat) -> CGFloat { min(max(s, lo), max(lo, hi - length)) }
        let top = inBounds(island.lowerBound), bottom = inBounds(island.upperBound - length)
        let c = abs(top - island.lowerBound) <= abs(bottom - (island.upperBound - length)) ? top : bottom
        func overlap(_ s: CGFloat) -> CGFloat { min(c + length, island.upperBound + s) - max(c, island.lowerBound + s) }
        var shift: CGFloat = 0
        if overlap(0) < need {
            // the two moves that give exactly `need`: the island's foot to the card's start + need, or its head to the card's end - need
            let clampS = { (s: CGFloat) in min(max(s, lo - island.lowerBound), hi - island.upperBound) }
            let moves = [c + need - island.upperBound, c + length - need - island.lowerBound].map(clampS)
            let target = min(need, moves.map(overlap).max() ?? 0) - 0.01      // an island shorter than the need can only reach its own length
            shift = moves.filter { overlap($0) >= target }.min(by: { abs($0) < abs($1) }) ?? 0
        }
        let il = island.lowerBound + shift, iu = island.upperBound + shift
        let ovLo = max(c, il), ovHi = min(c + length, iu)
        let m = (ovLo + ovHi) / 2, half = max(minNeck, ovHi - ovLo - 2 * k) / 2
        return (c, (m - half)...(m + half), inward + shift)
    }
}

/// Where the neck sits along the card's edge: panel-local, measured along the bar from the panel's top (left) edge.
struct ChatGeo: Equatable { var neckLo: CGFloat, neckHi: CGFloat }

/// The outline of pill-join + neck + card. `size` is the card along the bar (width) and away from it (height); `fill` closes the part inside
/// the pill so it can be filled, the outline (`fill` false) is open there: the pill draws its own edge.
struct ChatShape: Shape {
    let size: CGSize
    let geo: ChatGeo
    let edge: PopEdge
    let fill: Bool

    func path(in rect: CGRect) -> Path {
        let n = ChatCard.neck, f = ChatCard.flare, o = ChatCard.overlap, R = G.cardRadius
        let W = size.width, y0 = o, yc = o + n, H = o + n + size.height
        let a = geo.neckLo, b = geo.neckHi
        var p = Path()
        p.move(to: CGPoint(x: a - f, y: y0))
        p.addArc(center: CGPoint(x: a - f, y: y0 + f), radius: f, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: a, y: yc - f))
        p.addArc(center: CGPoint(x: a - f, y: yc - f), radius: f, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: R, y: yc))
        p.addArc(center: CGPoint(x: R, y: yc + R), radius: R, startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
        p.addLine(to: CGPoint(x: 0, y: H - R))
        p.addArc(center: CGPoint(x: R, y: H - R), radius: R, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: W - R, y: H))
        p.addArc(center: CGPoint(x: W - R, y: H - R), radius: R, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: W, y: yc + R))
        p.addArc(center: CGPoint(x: W - R, y: yc + R), radius: R, startAngle: .degrees(0), endAngle: .degrees(270), clockwise: true)
        p.addLine(to: CGPoint(x: b + f, y: yc))
        p.addArc(center: CGPoint(x: b + f, y: yc - f), radius: f, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: b, y: y0 + f))
        p.addArc(center: CGPoint(x: b + f, y: y0 + f), radius: f, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        if fill {
            p.addLine(to: CGPoint(x: b + f, y: 0))
            p.addLine(to: CGPoint(x: a - f, y: 0))
            p.closeSubpath()
        }
        return p.applying(transform(total: H))
    }

    /// below: as drawn. above: flipped top to bottom. right (card to the right of a left strip): x and y swapped. left: swapped and mirrored.
    private func transform(total T: CGFloat) -> CGAffineTransform {
        switch edge {
        case .below: return .identity
        case .above: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: T)
        case .right: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: T, ty: 0)
        }
    }
}

/// The chat card as the popout panel draws it: the silhouette, the card's content, grown from the bar's side.
struct ChatPopRoot: View {
    @ObservedObject var pop: Popout
    let id: String
    var body: some View {
        let size = PopCard.size(id, stage: pop.stage), geo = pop.chatGeo, edge = pop.edge
        let n = ChatCard.neck, o = ChatCard.overlap, horiz = ChatCard.horizontal(edge)
        let shapeSize = horiz ? size : CGSize(width: size.height, height: size.width)       // along the bar, away from the bar
        let reach = o + n
        let panel = horiz ? CGSize(width: size.width, height: reach + size.height) : CGSize(width: reach + size.width, height: size.height)
        let at: CGSize = edge == .below ? CGSize(width: 0, height: reach) : edge == .right ? CGSize(width: reach, height: 0) : .zero
        let spring = Animation.spring(duration: 0.30, bounce: 0.05)
        let toward: UnitPoint = edge == .below ? .top : edge == .above ? .bottom : edge == .right ? .leading : .trailing
        let align: Alignment = edge == .below ? .top : edge == .above ? .bottom : edge == .right ? .topLeading : .topTrailing
        ZStack(alignment: .topLeading) {
            ChatShape(size: shapeSize, geo: geo, edge: edge, fill: true).fill(Pal.cardSolid)
            ChatShape(size: shapeSize, geo: geo, edge: edge, fill: false).stroke(Pal.warmEdge, lineWidth: 1)
            PopCard.content(id)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: G.cardRadius))
                .offset(at)
        }
        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
        .contentShape(ChatShape(size: shapeSize, geo: geo, edge: edge, fill: true))
        .onHover { pop.hoverCard($0) }
        .scaleEffect(pop.open ? 1 : ChatCard.lean, anchor: toward)
        .opacity(pop.open ? 1 : 0)
        .animation(spring, value: pop.open)
        .animation(spring, value: pop.stage)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
    }
}

// MARK: the island's rectangle

/// Lets the atoms inside an island read the island's rectangle (screen coordinates) when a card opens: the chat card joins the whole
/// pill, not the one atom. Like the atom's own anchor it reads on demand, so nothing is measured at rest.
struct IslandAnchor: ViewModifier {
    @State private var box = AnchorBox()
    func body(content: Content) -> some View {
        content.background(AnchorView(box: box)).environment(\.islandAnchor, box)
    }
}
