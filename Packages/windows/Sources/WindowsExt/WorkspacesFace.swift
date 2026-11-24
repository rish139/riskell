// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// The workspace rail, standing on the hug strip: one bead per space on an even pitch (a bright bead when it holds windows, a dim one
/// when empty), and the accent capsule on the focused one. The capsule is ONE view that follows the focus (and the fingers of a swipe);
/// nothing re-lays-out on a switch. Hover swells the chain. While the card is out each space's bead floats down onto its row (the
/// windows themselves are listed in the card).
struct WorkspacesFace: View {
    @ObservedObject private var s = WindowsModel.shared
    @ObservedObject private var pop = PopState.shared
    @ObservedObject private var ws = WsState.shared
    @ObservedObject private var rail = RailState.shared
    @State private var hot = false
    let vertical: Bool

    static let pitch: CGFloat = 36          // one space's slot; the capsule (26) sits in it with 5 px each side
    static let cardDY: CGFloat = -6         // the card's top relative to the rail's top (Popout places it)
    /// The spring the capsule follows the focus with. The beads of a space that joins or leaves use it too; the island around the rail is
    /// given the same spring by the bar (Bars.swift), where its size is decided.
    static let growth = Animation.spring(duration: 0.26, bounce: 0.14)
    static let hPitch: CGFloat = 28         // horizontal: one space's slot along the 36 pt pill (the beads stay 9 pt, as on the rail)

    private func zone(_ i: Int) -> CGFloat { Self.pitch }
    private func geometry(_ spaces: [WorkspaceInfo]) -> ([CGFloat], CGFloat) {
        (spaces.indices.map { CGFloat($0) * Self.pitch }, CGFloat(spaces.count) * Self.pitch)
    }

    var body: some View {
        if vertical { verticalBody } else { horizontalBody }
    }

    /// The pill form: the same beads in a row, centred in the 36 pt pill, and the same capsule turned on its end (22 x 11 against the
    /// rail's 11 x 26). It follows the focus and the swipe along x. Nothing floats: the beads stay put while the card is out.
    private var horizontalBody: some View {
        let spaces = s.spaces, n = spaces.count
        let total = CGFloat(n) * Self.hPitch
        let centers = spaces.indices.map { CGFloat($0) * Self.hPitch + Self.hPitch / 2 }
        let focus = s.focusedIndex
        let pos = focus.map { min(max(Double($0) + rail.swipe, 0), Double(max(n - 1, 0))) }
        let capX: CGFloat? = pos.map { p in
            let i = Int(p.rounded(.down)), f = CGFloat(p - Double(i))
            let a = centers[i]
            return i + 1 < n ? a + (centers[i + 1] - a) * f : a
        }
        let hv: CGFloat = hot ? 1 : 0
        return ZStack(alignment: .leading) {
            ForEach(Array(spaces.enumerated()), id: \.element.id) { i, sp in
                let drop = ws.dropSpace == sp.id
                Circle().fill(drop ? Pal.accent : sp.windows > 0 ? Pal.text2 : Pal.text4.opacity(0.45))
                    .frame(width: 9, height: 9).scaleEffect((1 + 0.2 * hv) * (drop ? 1.5 : 1))
                    .frame(width: Self.hPitch, height: G.pill)
                    .contentShape(Rectangle())
                    .onTapGesture { KitHost.windows?.focus(space: sp.id) }
                    .offset(x: CGFloat(i) * Self.hPitch)
                    .transition(.opacity)
            }
            if let capX {
                Capsule().fill(Pal.accent).frame(width: 22, height: 11)
                    .scaleEffect(x: 1 + 0.1 * hv, y: 1 + 0.2 * hv)
                    .offset(x: capX - 11)
                    .animation(rail.live ? nil : Self.growth, value: pos)    // fingers down: 1:1, no easing
                    .allowsHitTesting(false)
            }
        }
        .frame(width: total, height: G.pill, alignment: .leading)
        .animation(Self.growth, value: n)      // the beads of a space that joins or leaves, on the capsule's own spring
        .animation(.spring(duration: 0.26, bounce: 0.18), value: hot)
        .popout("workspaces", edge: .right, hot: $hot)
    }

    @ViewBuilder private var verticalBody: some View {
        let spaces = s.spaces, n = spaces.count
        let floated = pop.open && pop.card == "workspaces" && !pop.chat      // a chat card leaves the rail a pill: the dots stay in it
        // rest geometry, relative to the rail's top
        let (tops, total) = geometry(spaces)
        let centers = spaces.indices.map { tops[$0] + zone($0) / 2 }
        let plan = floated ? WsLayout.current() : nil
        let lift: (Int) -> CGFloat = { i in
            guard let plan, i < plan.rowCenters.count else { return 0 }
            return Self.cardDY + plan.rowCenters[i] - centers[i]
        }
        let focus = s.focusedIndex
        let pos = focus.map { min(max(Double($0) + rail.swipe, 0), Double(max(n - 1, 0))) }
        let capY: CGFloat? = pos.map { p in
            let i = Int(p.rounded(.down)), f = CGFloat(p - Double(i))
            let a = centers[i] + lift(i)
            return i + 1 < n ? a + (centers[i + 1] + lift(i + 1) - a) * f : a
        }
        let hv: CGFloat = hot ? 1 : 0
        ZStack(alignment: .top) {
            ForEach(Array(spaces.enumerated()), id: \.element.id) { i, sp in
                let drop = ws.dropSpace == sp.id
                VStack(spacing: 0) {
                    ZStack {
                        Circle().fill(drop ? Pal.accent : sp.windows > 0 ? Pal.text2 : Pal.text4.opacity(0.45))
                            .frame(width: 9, height: 9).scaleEffect((1 + 0.2 * hv) * (drop ? 1.5 : 1))   // always drawn: the capsule covers it, and nothing is blank while the capsule is still on its way
                    }.frame(width: G.strip, height: zone(i))
                }
                .frame(height: Self.pitch, alignment: .top)
                .overlay(alignment: .top) {      // the click target of the bead itself
                    Color.clear.frame(width: G.strip, height: zone(i)).contentShape(Rectangle())
                        .onTapGesture { KitHost.windows?.focus(space: sp.id) }
                }
                .offset(y: tops[i] + (floated ? lift(i) : 0))
                .animation(.spring(duration: 0.30, bounce: 0.05).delay(floated ? 0.035 * Double(i) : 0.02 * Double(n - 1 - i)), value: floated)
                .transition(.opacity)
            }
            if let capY {
                Capsule().fill(Pal.accent).frame(width: 11, height: 26)
                    .scaleEffect(x: 1 + 0.2 * hv, y: 1 + 0.1 * hv)
                    .frame(width: G.strip).offset(y: capY - 13)
                    .animation(rail.live ? nil : Self.growth, value: pos)    // fingers down: 1:1, no easing
                    .animation(.spring(duration: 0.30, bounce: 0.05), value: floated)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: G.strip, height: total, alignment: .top)
        .animation(Self.growth, value: n)      // the beads of a space that joins or leaves, on the capsule's own spring
        .animation(.spring(duration: 0.26, bounce: 0.18), value: hot)
        .popout("workspaces", edge: .right, hot: $hot)
    }
}
