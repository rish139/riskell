import SwiftUI
import RiskellKit

/// An island: the pill and its atoms, a "|" between modules. A hugged bar has no pills: its band is the surface.
struct IslandView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var pop = Popout.shared
    @ObservedObject private var cfg = Config.shared
    let island: Island
    let bar: BarKey
    var body: some View {
        // an island whose atoms all have nothing to show (no workspaces, no focused window) is not drawn: no empty pill
        if !cfg.editing, Registry.blank(island, store) { EmptyView() } else { pill }
    }
    private var pill: some View {
        // a flush card fills the bar in under it; a chat card leaves the bar alone and its island goes solid, as the card is
        let owner = pop.open && pop.chat && pop.edge == bar.edge && island.atoms.contains(where: { AtomCatalog.card($0) == pop.card })
        return Pill(lit: (pop.open && pop.edge == bar.edge && !pop.chat) || cfg.isHug(bar)) {
            ForEach(Array(Registry.shown(island.atoms, store, editing: cfg.editing).enumerated()), id: \.offset) { i, a in
                if i > 0 { Sep().padding(.horizontal, 6) }
                EditableAtom(bar: bar, id: a)
            }
        }
        .background { if owner { RoundedRectangle(cornerRadius: G.radius).fill(Pal.cardSolid) } }
        .modifier(IslandAnchor())
        .background(GeometryReader { Color.clear.preference(key: WingWidthKey.self, value: [island.id: $0.size.width]) })      // the wing fit's natural width (WingFit.swift)
        .reportFrame("isl:" + island.id, cfg.editing)
    }
}

/// A top or bottom bar: islands in start / centre / end zones, centred on the band (the notch's height).
struct HBar: View {
    @ObservedObject private var pop = Popout.shared
    @ObservedObject private var compat = Compat.shared
    @ObservedObject private var cfg = Config.shared
    let bar: BarKey                                // .top or .bottom
    let bandH: CGFloat                             // design units
    var shiftY: CGFloat = 0                       // islands lower by this much (the wings stay on the notch)
    var notchAbs: (l: CGFloat, r: CGFloat)? = nil  // the cutout's edges in screen x (real points), when the bar has the notch (wings)
    /// Each island's measured width (design units, without its margins), by island id. Reported by the islands when they draw; kept while hidden.
    @State private var widths: [String: CGFloat] = [:]
    @EnvironmentObject private var store: Store
    /// One wing's fit (WingFit.swift). Only measured, visible islands count.
    private func wing(_ isls: [Island], available: CGFloat) -> WingFit {
        let items: [WingItem] = isls.compactMap { (isl) -> WingItem? in
            guard isl.id != "compat" || !compat.notes.isEmpty, !Registry.blank(isl, store), let w = widths[isl.id] else { return nil }
            return WingItem(id: isl.id, width: w + 2 * G.sideMargin, priority: isl.atoms.compactMap { Registry.byID[$0]?.priority }.max() ?? 5,
                            droppable: isl.id != "compat" && !isl.atoms.contains("compat"))
        }
        return WingRule.fit(available: available, items: items, gap: cfg.gap)
    }
    var body: some View {
        let edge = bar.edge, spec = cfg.spec(bar)
        let originX = cfg.screenMinX + cfg.leftW       // this panel's left edge (real): it starts after the left strip, if there is one
        let notch = notchAbs.map { (l: ($0.l - originX) / Real.k, r: ($0.r - originX) / Real.k) }      // design units, from the panel's left edge
        // The top bar's wings: the start wing ends a gap before the notch, the end wing starts a gap after it. The row starts at the side margin.
        // Nil (no fit, everything shown as before) without a notch, in edit mode, or until the row is measured.
        // The bar's width (design units) is its panel's: the row is that less the side margins on each end.
        let panelW = (cfg.windows[bar]?.frame.width ?? 0) / Real.k
        let fitS: WingFit? = notch.flatMap { n in !cfg.editing && panelW > 0 ? wing(spec.start, available: n.l - G.sideMargin - cfg.gap) : nil }
        let fitE: WingFit? = notch.flatMap { n in !cfg.editing && panelW > 0 ? wing(spec.end, available: panelW - G.sideMargin - n.r - cfg.gap) : nil }
        let _ = CheckFit.report(fitS, "start", bar), _ = CheckFit.report(fitE, "end", bar)      // --check-fit children only (WingFit.swift)
        ZStack {
            HStack(spacing: cfg.gap) {
                HStack(spacing: cfg.gap) {
                    ForEach(spec.start) { isl in if (isl.id != "compat" || !compat.notes.isEmpty) && !(fitS?.dropped.contains(isl.id) ?? false) { IslandView(island: isl, bar: bar) } }
                }
                .scaleEffect(fitS?.scale ?? 1, anchor: .leading)
                .frame(width: (fitS?.scale ?? 1) < 1 ? fitS?.width : nil, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: cfg.gap) {
                    ForEach(spec.end) { isl in if !(fitE?.dropped.contains(isl.id) ?? false) { IslandView(island: isl, bar: bar) } }
                }
                .scaleEffect(fitE?.scale ?? 1, anchor: .trailing)
                .frame(width: (fitE?.scale ?? 1) < 1 ? fitE?.width : nil, alignment: .trailing)
            }
            HStack(spacing: cfg.gap) { ForEach(spec.center) { IslandView(island: $0, bar: bar) } }
        }
        .onPreferenceChange(WingWidthKey.self) { new in if new.contains(where: { widths[$0.key] != $0.value }) { widths.merge(new) { $1 } } }
        .offset(y: shiftY)
        .padding(.horizontal, G.sideMargin).frame(height: bandH)
        .overlay { if let n = notch { Wings(notchL: n.l, notchR: n.r, bandH: bandH) } }
        // room below (above) the band for the fillet that joins it to the hug strip; the band itself lights while a card is out (always, when hugged)
        .frame(height: bandH + G.r, alignment: edge == .below ? .top : .bottom)
        .background(LitBand(edge: edge, bandH: edge == .below ? bandH : G.bottomIslandTop, notch: notch, lit: (pop.open && pop.edge == edge && !pop.chat) || cfg.isHug(bar), joinL: cfg.on(.left), joinR: cfg.on(.right)))     // the bottom fill stops at the islands' top edge
        .overlay { HintView(bar: bar) }
        .overlay { if cfg.editing && cfg.isEmpty(bar) { EmptyBarHint().frame(width: 140, height: G.pill) } }
        .environment(\.popEdge, edge)
        .coordinateSpace(name: "bar")
        .onPreferenceChange(FrameKey.self) { cfg.frames[bar] = $0 }
    }
}

/// A strip's content (left or right): islands start at the top and end at the bottom. Hugged, the strip is the surface; floating, each island is a pill.
struct VBar: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var cfg = Config.shared
    @ObservedObject private var pop = Popout.shared
    let bar: BarKey                                  // .left or .right
    var body: some View {
        let spec = cfg.spec(bar)
        VStack(spacing: cfg.gap) {
            Color.clear.frame(height: G.sideMargin + cfg.menuDrop)
            ForEach(spec.start) { if cfg.editing || !Registry.blank($0, store) { island($0, pad: 10) } }
            Spacer(minLength: 0)
            ForEach(spec.end) { if cfg.editing || !Registry.blank($0, store) { island($0, pad: 20) } }
            Color.clear.frame(height: G.sideMargin)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(Pal.text1)
        .animation(.easeOut(duration: 0.18), value: cfg.menuDrop)
        .frame(width: G.strip)
        .overlay { HintView(bar: bar) }
        .overlay { if cfg.editing && cfg.isEmpty(bar) { EmptyBarHint().frame(width: G.pill, height: 120) } }
        .environment(\.popEdge, bar.edge)
        .coordinateSpace(name: "bar")
        .onPreferenceChange(FrameKey.self) { cfg.frames[bar] = $0 }
        .onPreferenceChange(StripIslandKey.self) { stripIslands[bar] = $0 }
    }

    private func island(_ isl: Island, pad: CGFloat) -> some View {
        let hug = cfg.isHug(bar), lit = hug || (pop.open && !pop.chat)      // a flush card out (from any bar) fills the strip in: its pills dissolve into it; a chat card leaves the strip alone
        // the island whose card is out floats clear of the top / bottom bar together with its card (see Popout.floatY)
        let ownsCard = pop.open && pop.edge == bar.edge && isl.atoms.contains(where: { AtomCatalog.card($0) == pop.card })
        let fy: CGFloat = ownsCard ? pop.floatY / Real.k : 0      // the popout keeps floatY in real points; SwiftUI offsets are design units
        let solid = ownsCard && pop.chat      // the island a chat card is joined to goes solid, as the card is
        return VStack(spacing: 0) {
            ForEach(Array(Registry.shown(isl.atoms, store, editing: cfg.editing).enumerated()), id: \.offset) { i, a in
                if i > 0 { Rectangle().fill(Pal.hairline).frame(width: 24, height: 1).padding(.vertical, pad) }
                EditableAtom(bar: bar, id: a)
            }
        }
        .padding(.vertical, hug ? 0 : 10)
        .frame(width: hug ? nil : G.strip - 10)
        .modifier(IslandAnchor())
        .background(RoundedRectangle(cornerRadius: G.radius).fill(lit ? Color.clear : solid ? Pal.cardSolid : Pal.surface))
        .overlay(RoundedRectangle(cornerRadius: G.radius).stroke(lit ? Color.clear : Pal.hairline, lineWidth: 1))
        .animation(.easeOut(duration: 0.18), value: lit)
        .modifier(EditSwell(on: cfg.editing))
        .reportFrame("isl:" + isl.id, cfg.editing)
        .offset(y: fy)
        .background(GeometryReader { g in Color.clear.preference(key: StripIslandKey.self, value: [g.frame(in: .named("bar"))]) })
        .animation(.spring(duration: 0.30, bounce: 0.05), value: fy)
    }
}

/// The drawn island rectangles of a strip, in the strip host's own coordinates (design units, top-left origin). Measured at rest: the
/// preference changes only when the layout does, and the window reads it to decide which parts of the strip take the pointer.
struct StripIslandKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
var stripIslands: [BarKey: [CGRect]] = [:]

/// An empty bar while editing: a dashed slot, so there is something to drop a pill on.
struct EmptyBarHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: G.radius).strokeBorder(Pal.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])).allowsHitTesting(false)
    }
}
